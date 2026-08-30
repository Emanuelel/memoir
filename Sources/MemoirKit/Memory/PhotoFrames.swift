#if canImport(AppKit)
import AppKit
#endif
import Foundation
import Photos

/// The one place in Memoir that asks the photo library for a picture.
///
/// ## What changed, and what did not
///
/// `PhotoImporter` reads dates and coordinates and nothing else, and it says at length that it
/// never calls `PHImageManager`, and that the absence of the call is the proof of the promise.
/// That is still true of the importer, and of everything that touches the database. It is no
/// longer true of the whole app, and pretending otherwise in a doc comment would be the worst
/// of both.
///
/// So the promise is restated here in the form it now takes, narrower and still checkable:
///
/// - **Nothing is stored.** No image, no thumbnail, no derived pixels reach the database, the
///   vault, the log, or any file Memoir writes. Everything this file returns lives in memory
///   for as long as a view is on screen and is dropped with it.
/// - **Nothing is sent.** This file opens no network connection of any kind, and there is no
///   path from a thumbnail to a brain. A picture is never part of a context packet, so no
///   model, local or cloud, is ever shown one. (Said without naming the type: the privacy
///   stage in `Scripts/verify.sh` greps for it, and a comment promising its absence would
///   read to that grep exactly like a violation.)
/// - **Nothing is written back.** Read-only against PhotoKit, like every other source.
/// - **Only the day you are looking at.** Frames are fetched for one day, capped, and only by
///   a surface the user opened. Nothing walks the library in the background.
///
/// What the user gives up by comparison with the old promise is real and worth stating plainly:
/// decoded image data now passes through Memoir's process. That is what showing you a
/// photograph means, and there is no version of it that does not.
///
/// ## Why it is worth it
///
/// The journal strip exists so the page is never blank. A row of small pictures of your own
/// afternoon is a better invitation to write than the sentence *"6 photos · Cala Piccola"*,
/// and it is not close. This is the one place in the product where the picture is the point.
///
/// ## Screenshots, still
///
/// Skipped here as in the importer. A screenshot is a picture of a screen (the same class of
/// content capture is careful about), and it is never what somebody means by a photograph of
/// their day.
public enum PhotoFrames {

    /// How many photographs a day is worth showing. Past four the strip stops being a glance.
    public static let maxPerDay = 4

    /// One photograph, as a reference and a time. Carries no pixels: the image is fetched
    /// separately, by a view, at the moment it is shown.
    public struct Frame: Sendable, Equatable, Identifiable {
        /// PhotoKit's `localIdentifier`. A reference into the user's own library, not content.
        public let id: String
        public let date: Date

        public init(id: String, date: Date) {
            self.id = id
            self.date = date
        }
    }

    /// The photographs taken on one day, oldest first, capped and screenshot-free.
    ///
    /// Returns nothing when the library is not readable, which is a smaller day rather than an
    /// error. Under limited access this is whatever slice macOS is handing over. See
    /// `PhotoImporter.access`.
    public static func frames(
        on day: Date,
        limit: Int = maxPerDay,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [Frame] {
        guard PhotoImporter.isAuthorized else { return [] }

        let start = calendar.startOfDay(for: day)
        // Never past the current moment: a photograph taken later this evening is not part of
        // the afternoon somebody is writing about.
        let end = min(calendar.date(byAdding: .day, value: 1, to: start) ?? day, now)
        guard end > start else { return [] }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@", start as NSDate, end as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        var out: [Frame] = []
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, stop in
            if out.count >= limit { stop.pointee = true; return }
            guard !asset.mediaSubtypes.contains(.photoScreenshot) else { return }
            guard let date = asset.creationDate else { return }
            out.append(Frame(id: asset.localIdentifier, date: date))
        }
        return out
    }

    #if canImport(AppKit)
    /// What the image is for. Both decode properly; they differ in how they meet the frame.
    ///
    /// There used to be a `.fast` case that took whatever PhotoKit had cached, on the argument
    /// that a grid of 72pt tiles cannot show the difference. It can: the cached representation
    /// is often 256px or less, and a tile is 192px of Retina, so the grid was drawing blurred
    /// thumbnails and the opened photograph was one of them scaled up.
    public enum Quality: Sendable {
        /// A tile in the day's grid. Filled, so it covers its cell without letterboxing.
        case tile
        /// A photograph somebody opened. Fitted, so nothing is cropped out of the picture
        /// they asked to see.
        case full
    }

    /// An image for one frame, or nil when the asset is gone or the library says no.
    ///
    /// `isNetworkAccessAllowed` is left **off** at both qualities, so an image that lives only
    /// in iCloud is simply not shown. Memoir will not start a download of somebody's photo
    /// library on their behalf, and that switch is how the network stays out of this file.
    /// Nothing returned here is cached, written, or held past the view that asked for it.
    public static func thumbnail(
        for frame: Frame, size: CGSize, quality: Quality = .tile
    ) async -> NSImage? {
        guard PhotoImporter.isAuthorized else { return nil }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [frame.id], options: nil)
        guard let asset = assets.firstObject else { return nil }

        let options = PHImageRequestOptions()
        // `.highQualityFormat` calls back exactly once, with the best it has, and never with
        // a degraded frame. `.exact` makes the returned size the size that was asked for
        // rather than approximately it.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false

        return await withCheckedContinuation { continuation in
            // PhotoKit calls back more than once for some delivery modes. `resume` may only
            // happen once, so the first non-degraded answer wins and the rest are dropped.
            let done = Resumed()
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: size,
                contentMode: quality == .full ? .aspectFit : .aspectFill,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                // No special case for full quality, on purpose: `.highQualityFormat` calls back
                // exactly once with the best it has, so waiting for a non-degraded frame here
                // would be waiting for a callback that never comes.
                guard !degraded || image != nil else { return }
                if done.claim() { continuation.resume(returning: image) }
            }
        }
    }

    /// One-shot latch, so a multi-callback PhotoKit request resumes its continuation once.
    private final class Resumed: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }
    #endif
}
