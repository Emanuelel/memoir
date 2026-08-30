import Foundation

/// How well one app's screen text is actually being read.
///
/// The README has admitted "you cannot currently tell which apps are being captured
/// well" since day one. For a product whose whole pitch is provenance, silent partial
/// coverage is the worst failure available: the user assumes the Slack thread was
/// seen, and it wasn't. This type makes the coverage visible, computed from the same
/// tables everything else already trusts, with no new capture-path bookkeeping.
public struct AppCaptureQuality: Sendable, Equatable, Identifiable {
    public var id: String { bundleID }
    public let bundleID: String
    public let appName: String
    /// Non-idle frontmost time over the window.
    public let activeSeconds: TimeInterval
    /// Captures stored over the window.
    public let captureCount: Int
    /// Total captured characters over the window.
    public let capturedChars: Int
    /// Share of captures that carried a window title, 0...1.
    public let titledShare: Double
    /// The most recent capture, if any.
    public let lastCapture: Date?

    public init(
        bundleID: String, appName: String, activeSeconds: TimeInterval,
        captureCount: Int, capturedChars: Int, titledShare: Double, lastCapture: Date?
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.activeSeconds = activeSeconds
        self.captureCount = captureCount
        self.capturedChars = capturedChars
        self.titledShare = titledShare
        self.lastCapture = lastCapture
    }

    /// Captured characters per minute of active use. The load-bearing signal: a native
    /// app yields thousands, an Electron app hundreds, a canvas app close to zero.
    public var charsPerActiveMinute: Double {
        let minutes = max(activeSeconds / 60, 1)
        return Double(capturedChars) / minutes
    }

    /// The honest one-word verdict.
    public var grade: CaptureGrade {
        if captureCount == 0 {
            // Real use with nothing read at all: either excluded, a canvas app, or a
            // permissions problem. Brief use with nothing read is just not enough data.
            return activeSeconds >= 300 ? .nothing : .unknown
        }
        switch charsPerActiveMinute {
        case ..<40: return .poor
        case ..<400: return .partial
        default: return .good
        }
    }
}

/// The four honest verdicts, worst first.
public enum CaptureGrade: String, Sendable, CaseIterable {
    /// Real use, zero text. The app is effectively invisible to Memoir.
    case nothing
    /// A trickle: usually window titles and little else.
    case poor
    /// Some text, far less than the time spent suggests. Electron territory.
    case partial
    /// Text volume in line with use. What a native app looks like.
    case good
    /// Not enough use to judge.
    case unknown

    public var label: String {
        switch self {
        case .good: return "Reading well"
        case .partial: return "Partial text"
        case .poor: return "Titles only"
        case .nothing: return "Nothing readable"
        case .unknown: return "Too little use to judge"
        }
    }
}

// The query that produces these lives in `Store.captureQuality(since:)`, computed
// from `sessions` and `captures` at read time, deliberately not a new table: the
// honest number should never be able to drift from the data it describes.
