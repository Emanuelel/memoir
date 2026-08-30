import Foundation

/// A tally of what the model pass actually did, kept beside the extraction itself.
///
/// ``Extractor/extract(from:)`` returns entities, which is the right shape for the pipeline and
/// the wrong shape for the question "did the model run?". Zero entities is produced by a model
/// that found nothing, a model that was never asked, and a model that failed on every window,
/// and those are three different situations wearing the same number. The batch pass has to be
/// able to tell them apart or its report is worthless: a nightly job against a sleeping Mac
/// mini writes an honest-looking "0 new memories" every night forever.
///
/// An actor because the extractor is `Sendable` and the tally is mutable. Optional on the
/// extractor because the live path has nothing to report to.
public actor ExtractionTelemetry {

    /// Windows the extractor tried.
    public private(set) var windowsAsked = 0
    /// Windows the configured brain answered, parseably.
    public private(set) var windowsByBrain = 0
    /// Windows the on-device guided path answered after the brain did not.
    public private(set) var windowsByGuided = 0
    /// Windows neither could answer.
    public private(set) var windowsFailed = 0

    public init() {}

    /// How the model was reached, if it was.
    public enum Outcome: Sendable {
        case brain
        case guided
        case failed
    }

    func record(_ outcome: Outcome) {
        windowsAsked += 1
        switch outcome {
        case .brain: windowsByBrain += 1
        case .guided: windowsByGuided += 1
        case .failed: windowsFailed += 1
        }
    }

    /// True when at least one window was answered by a model of any kind.
    ///
    /// The single question the run record needs: did anything other than the rules contribute?
    public var reachedModel: Bool { windowsByBrain + windowsByGuided > 0 }

    /// A snapshot, for callers that want the numbers without awaiting four properties.
    public var counts: (asked: Int, brain: Int, guided: Int, failed: Int) {
        (windowsAsked, windowsByBrain, windowsByGuided, windowsFailed)
    }
}
