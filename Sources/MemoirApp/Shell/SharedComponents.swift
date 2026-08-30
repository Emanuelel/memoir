import SwiftUI
import MemoirKit

/// Thirteen bars, 09:00 to 21:00, white where the hour was hot. Hours are facts;
/// there is no invented productivity score anywhere in this view.
struct HourBars: View {
    /// Minutes of non-idle activity per hour slot, 09...21.
    let minutesByHour: [Int]
    var height: CGFloat = 56

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(minutesByHour.enumerated()), id: \.offset) { _, minutes in
                    let fraction = max(0.06, min(1, Double(minutes) / 60))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(fraction > 0.8 ? Theme.ink : Color(hex: 0x232327))
                        .frame(height: height * fraction)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: height, alignment: .bottom)

            HStack {
                Text("09"); Spacer(); Text("12"); Spacer(); Text("15"); Spacer(); Text("18"); Spacer(); Text("21")
            }
            .font(.system(size: 10))
            .foregroundStyle(Theme.faint)
        }
    }
}

/// A big number over a tiny label: the Tracked / Focused / Mostly-in stats.
struct StatBlock: View {
    let label: String
    let value: String
    var valueSize: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.faint)
            Text(value)
                .font(.system(size: valueSize, weight: .bold))
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
        }
    }

    /// Minutes as "2h 05m": the one duration format any of these blocks ever shows.
    static func hm(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
    }
}

// MARK: - Photographs

/// One photograph, loaded when it appears and dropped when it goes.
///
/// Shared by the journal, which offers today's as something to write about, and the calendar,
/// which shows any day's as part of reading it back.
///
/// Held in view state and nowhere else: not in the model, not in a cache, not on disk. A
/// thumbnail that outlived the pane would be Memoir keeping a copy of a picture, which is the
/// thing `PhotoFrames` promises it does not do.
struct Thumbnail: View {
    let frame: PhotoFrames.Frame
    /// How large a copy to ask PhotoKit for, in pixels. A 96pt tile is 192px of Retina, so
    /// the default has room to spare; the viewer asks for the same picture again, much bigger.
    /// Either way nothing is kept once the view goes.
    var size: CGFloat = 512
    /// Fill for a tile that has to cover its cell, fit for the viewer, which must not crop.
    var fit: Bool = false
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            // The empty state is a tile, not a spinner. Most thumbnails arrive in a frame or
            // two from PhotoKit's own cache, and a spinner that flashes is worse than a shape
            // that fills.
            if !fit { Rectangle().fill(Theme.tile) }
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fit ? .fit : .fill)
            }
        }
        .task(id: "\(frame.id)-\(Int(size))") {
            image = await PhotoFrames.thumbnail(
                for: frame, size: CGSize(width: size, height: size),
                quality: fit ? .full : .tile
            )
        }
    }
}
