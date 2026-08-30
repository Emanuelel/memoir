import CoreLocation
import Foundation
import Photos

/// Reads the photo library's *metadata* (when, and roughly where) so the memory knows the
/// places a life keeps returning to.
///
/// ## Why this exists
///
/// Contacts gives the memory people and Calendar gives it dated events, but both are records of
/// what was *scheduled*. A photo library is a record of where somebody actually was, kept
/// faithfully for years by people who were not trying to keep a record at all. It is the only
/// source on the machine that can answer *"every autumn since 2023 you are in the same
/// neighbourhood"*, and that sentence is the product.
///
/// ## What is read, and what is refused
///
/// Three fields per photo: the date, the coordinate, and whether it is a screenshot. That is
/// all. In particular this file never calls `PHImageManager`, never requests image data of any
/// size, and never touches a thumbnail: the absence of that call is what makes it true that
/// no picture is ever *stored*, so it should stay absent.
///
/// Pictures are shown, in one place: `PhotoFrames` fetches thumbnails of today for the journal
/// composer, while that pane is open, and keeps none of them. That is a display path and this
/// is the storage path; nothing here should ever grow the ability to do both.
///
/// Two things the platform does not offer, recorded here so nobody goes looking:
///
/// - **Faces.** Photos' People album has no public API. Apple's own face recognition is not
///   readable by a third-party app, so who was in a photo cannot be known from here. People
///   come from Contacts and from calendar attendees instead.
/// - **Place names.** `PHAsset` carries a coordinate and nothing else. Turning 41.38, 2.17 into
///   a neighbourhood name means `CLGeocoder`, which is a network call, and this product does not
///   make one. So a place is identified by where it is, and named only if the user names it.
///
/// ## Why a grid and not real clustering
///
/// Coordinates are grouped by rounding them onto a fixed grid, roughly 150 m across, rather than
/// by any adaptive clustering. Adaptive clustering is better geography and the wrong engineering
/// here: adding one photo can re-shape the clusters around it, which changes their identity,
/// which changes every id derived from them. Re-running the import would then duplicate places
/// it had already imported instead of merging into them. A grid cell is the same cell forever,
/// which is what makes the whole pass idempotent.
///
/// The cost is honest and small: two photos either side of a cell boundary land in different
/// cells. For "which neighbourhood is this, and have I been here before" that does not matter.
public enum PhotoImporter {

    /// The pseudo-app these rows are recorded under, so an answer sourced from here says
    /// "Photos" and never "your screen".
    public static let bundleID = "sh.memoir.photos"
    public static let appName = "Photos"

    /// Grid step in degrees of latitude, about 150 m. Longitude is scaled by latitude so a
    /// cell stays roughly square instead of stretching towards the poles.
    static let latitudeStep = 0.00135

    /// How many *distinct days* a cell needs before it counts as a place in someone's life.
    ///
    /// One afternoon somewhere is a photograph. Three separate days is somewhere you go. Without
    /// this a decade of holidays mints hundreds of place entities that will never match anything
    /// a person says, and the memory browser becomes a gazetteer.
    static let minimumDaysForPlace = 3

    /// Ceiling on assets examined in one pass. A 200,000-photo library should not hold up
    /// first-run setup; the cap is generous enough that nobody real hits it.
    static let maxAssets = 200_000

    // MARK: - Permission

    /// Whether the library is readable right now. `limited` counts: the user chose a subset and
    /// that subset is what we may see, which is a smaller answer rather than a refusal.
    public static var isAuthorized: Bool {
        access != .none
    }

    /// How much of the library macOS will actually hand over.
    ///
    /// The distinction is load-bearing and used to be invisible. `.limited` reports itself as
    /// granted through every ordinary check, but PhotoKit then returns only the assets the
    /// user picked: measured on one real machine, 202 images out of 14,683, none of them
    /// carrying a location. Memoir imported that fraction and reported "27 days with
    /// photographs" in the same words it uses for a whole decade, which is a partial record
    /// presented as a complete one.
    public enum Access: Sendable, Equatable {
        /// Nothing. The library is not readable at all.
        case none
        /// Only the photographs the user selected, which is usually a tiny slice of the library.
        case limited
        /// The whole library.
        case full
    }

    public static var access: Access {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return .full
        case .limited: return .limited
        default: return .none
        }
    }

    /// Asks for the photo library, once. Returns false when the user says no, which is a normal
    /// answer and must leave the rest of setup working.
    ///
    /// `.readWrite` is requested because PhotoKit has no read-only level: the only alternative
    /// is `.addOnly`, which grants writing and forbids reading, the exact inverse of what this
    /// needs. So the system prompt asks for more than Memoir takes, and the onboarding copy has
    /// to say what is actually read. Nothing in this file writes to the library.
    public static func requestAccess() async -> Bool {
        if isAuthorized { return true }
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
        }
        return status == .authorized || status == .limited
    }

    // MARK: - What one photo contributes

    /// The three fields taken from an asset. Deliberately a value type with no PhotoKit in it,
    /// so everything below it is testable without a photo library or a permission.
    public struct Shot: Sendable, Equatable {
        public let date: Date
        /// Nil for a photo with no location: most screenshots, anything imported from a camera
        /// without GPS. It still counts as a day with photos in it.
        public let latitude: Double?
        public let longitude: Double?

        public init(date: Date, latitude: Double? = nil, longitude: Double? = nil) {
            self.date = date
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    /// A grid cell, and everything known about it. `id` is derived from the cell, not from its
    /// contents, so it survives re-import unchanged.
    public struct Place: Sendable, Equatable {
        public let cell: Cell
        /// Distinct days with at least one photo in this cell, oldest first.
        public let days: [Date]
        /// Photos in the cell, across all days.
        public let shots: Int

        /// What the user sees until they rename it. A coordinate is not a nice name, and it is
        /// the only name this product can produce without asking the network where you were.
        public var title: String {
            String(format: "%.4f, %.4f", cell.latitude, cell.longitude)
        }
    }

    /// One cell of the grid, identified by its integer indices so equality is exact rather
    /// than a float comparison.
    public struct Cell: Sendable, Equatable, Hashable {
        public let latIndex: Int
        public let lonIndex: Int

        /// The cell's own coordinate, its south-west-ish anchor, used for the title.
        public var latitude: Double { Double(latIndex) * latitudeStep }
        public var longitude: Double { Double(lonIndex) * PhotoImporter.longitudeStep(atLatitudeIndex: latIndex) }

        /// Stable across runs and across machines, which is what the capture and entity ids
        /// derived from it depend on.
        public var key: String { "\(latIndex):\(lonIndex)" }
    }

    /// Longitude degrees per grid step at a given latitude, so cells stay roughly square.
    ///
    /// Clamped near the poles, where the scaling factor runs away to infinity and a cell would
    /// otherwise wrap the whole world.
    static func longitudeStep(atLatitudeIndex index: Int) -> Double {
        let latitude = Double(index) * latitudeStep
        let cosine = cos(latitude * .pi / 180)
        return latitudeStep / max(cosine, 0.01)
    }

    /// Which cell a coordinate falls in.
    static func cell(latitude: Double, longitude: Double) -> Cell {
        let latIndex = Int((latitude / latitudeStep).rounded())
        let lonIndex = Int((longitude / longitudeStep(atLatitudeIndex: latIndex)).rounded())
        return Cell(latIndex: latIndex, lonIndex: lonIndex)
    }

    // MARK: - Grouping

    /// A day's photographs in one place: the row that becomes a capture.
    ///
    /// One row per day per place, never one per photo. A decade of a real library is hundreds of
    /// thousands of images; a row each would swamp the database, the session builder and the
    /// ten-year storage projection all at once, to say something no more useful than "you took
    /// eight photos in this place that day".
    public struct DayInPlace: Sendable, Equatable {
        public let day: Date
        public let cell: Cell?
        public let shots: Int

        /// What this row contributes as text. Read back to the user verbatim in answers, so it
        /// has to read like something a person would say.
        public func evidence(placeName: String?) -> String {
            let count = shots == 1 ? "1 photo" : "\(shots) photos"
            guard let placeName else { return count }
            return "\(count) · \(placeName)"
        }

        /// Reads the count back out of ``evidence(placeName:)``.
        ///
        /// Kept next to the writer on purpose: this is a private format between two parts of
        /// one product, and the only thing that makes parsing it safe is that the function
        /// producing it is four lines up. A reader anywhere else would be a guess about a
        /// string. Returns nil for anything that is not one of these rows.
        public static func photoCount(in text: String) -> Int? {
            let head = text.prefix(while: { $0.isNumber })
            guard !head.isEmpty, let n = Int(head) else { return nil }
            let rest = text.dropFirst(head.count)
            guard rest.hasPrefix(" photo") else { return nil }
            return n
        }
    }

    /// Groups shots into day-and-place rows, and works out which cells are places.
    ///
    /// Pure: no PhotoKit, no clock, no store. Every interesting rule in this file is decided
    /// here, which is what makes them testable.
    public static func group(
        shots: [Shot],
        calendar: Calendar = .current
    ) -> (days: [DayInPlace], places: [Place]) {

        // ---- fold into (day, cell) buckets ----
        struct Bucket: Hashable {
            let day: Date
            let cell: Cell?
        }
        var counts: [Bucket: Int] = [:]
        for shot in shots {
            let day = calendar.startOfDay(for: shot.date)
            var cell: Cell?
            if let latitude = shot.latitude, let longitude = shot.longitude {
                cell = self.cell(latitude: latitude, longitude: longitude)
            }
            counts[Bucket(day: day, cell: cell), default: 0] += 1
        }

        // ---- day rows, oldest first so the import reads chronologically ----
        let days = counts
            .map { DayInPlace(day: $0.key.day, cell: $0.key.cell, shots: $0.value) }
            .sorted { ($0.day, $0.cell?.key ?? "") < ($1.day, $1.cell?.key ?? "") }

        // ---- cells that clear the days bar become places ----
        var daysByCell: [Cell: [Date]] = [:]
        var shotsByCell: [Cell: Int] = [:]
        for row in days {
            guard let cell = row.cell else { continue }
            daysByCell[cell, default: []].append(row.day)
            shotsByCell[cell, default: 0] += row.shots
        }

        let places = daysByCell
            .filter { $0.value.count >= minimumDaysForPlace }
            .map { Place(cell: $0.key, days: $0.value.sorted(), shots: shotsByCell[$0.key] ?? 0) }
            .sorted { $0.days.count > $1.days.count }

        return (days, places)
    }

    // MARK: - Reading

    /// Every photo in the window, as ``Shot`` values.
    ///
    /// Screenshots are excluded. A Mac photo library is full of them and they are not places
    /// somebody was: a screenshot of a booking confirmation would otherwise put you in
    /// whatever city the phone had last fixed a location in.
    ///
    /// Returns an empty array rather than throwing when the library is not readable, so a
    /// declined permission contributes nothing and is not an error.
    static func readShots(from start: Date, to end: Date) -> [Shot] {
        guard isAuthorized else { return [] }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@", start as NSDate, end as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.fetchLimit = maxAssets

        var out: [Shot] = []
        // Counted because "1 place" is the same answer whether the grouping is wrong or the
        // library simply has no coordinates in it, and those need completely different fixes.
        // Found the hard way: a nine-year library returned one place, and only the raw tallies
        // showed that 97% of its photographs carry no location at all.
        var seen = 0, screenshots = 0, undated = 0, located = 0
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        assets.enumerateObjects { asset, _, stop in
            if out.count >= maxAssets { stop.pointee = true; return }
            seen += 1
            guard !asset.mediaSubtypes.contains(.photoScreenshot) else { screenshots += 1; return }
            guard let date = asset.creationDate else { undated += 1; return }
            let location = asset.location
            if location != nil { located += 1 }
            out.append(Shot(
                date: date,
                latitude: location?.coordinate.latitude,
                longitude: location?.coordinate.longitude
            ))
        }
        // One decimal place, because the interesting reading here was 0.77% and an integer
        // percentage printed it as "0%", indistinguishable from none at all.
        let share = seen > 0 ? (Double(located) / Double(seen)) * 100 : 0
        Log.shared.info(
            "photo scan (\(access == .limited ? "LIMITED access" : "full access")): \(seen) images, "
            + "\(screenshots) screenshots skipped, \(undated) undated, "
            + String(format: "%d with a location (%.1f%%)", located, share)
        )
        if access == .limited {
            Log.shared.info(
                "photo scan: macOS is only handing over the photographs you selected, so this "
                + "is a slice of the library and not the record. Privacy & Security > Photos."
            )
        }
        if seen > 0 && located == 0 {
            Log.shared.info(
                "photo scan: no image in the library carries a coordinate. Either the photos "
                + "were not taken on a device with location on, or this Mac holds copies that "
                + "arrived stripped of it, or Photos granted limited access."
            )
        }
        return out
    }
}
