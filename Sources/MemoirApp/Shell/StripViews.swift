import SwiftUI
import MemoirKit

/// The face in the strip. Clicking it opens straight to Todos (the glance you want
/// most often), or collapses the band if it is already open.
struct StripFace: View {
    @ObservedObject var character: CharacterModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            FoldMark(
                traits: character.traits,
                gaze: character.gaze,
                blink: character.blink
            )
            .frame(width: 19, height: 21)
            .animation(.easeInOut(duration: 0.18), value: character.expression)
            .animation(.easeInOut(duration: 0.18), value: character.blink)
            .animation(.easeInOut(duration: 0.25), value: character.health)
            // The recording dot. The fold already says this in shape and colour, but the
            // shape is a thing you have to learn and a green dot is a thing everyone
            // already knows.
            //
            // It is always there, and it is red the moment the memory is not being written.
            // An absent dot was the first version of this and it was the wrong one: nothing
            // on screen is easy to miss and impossible to ask about, and "is it off, or did
            // I imagine there being a dot?" is exactly the doubt this is here to end.
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(character.health.isHealthy ? Theme.good : Theme.bad)
                    .frame(width: 5, height: 5)
                    // A ring of the band's own black, so the dot reads as separate
                    // from the mark rather than as a piece of it.
                    .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 1.2).frame(width: 7.4, height: 7.4))
                    .offset(x: 1.5, y: -0.5)
            }
            .animation(.easeInOut(duration: 0.25), value: character.health.isHealthy)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The tooltip is the third redundant channel, after the colour and the movement,
        // and the only one a screen reader can use.
        .help(character.health.isHealthy ? "Memoir: recording" : "Memoir: \(character.health.shortLabel)")
        .accessibilityLabel("Memoir: \(character.health.shortLabel)")
    }
}

/// One tab pill in the strip. Selected is white-on-black inverted; the rest are
/// tile-grey ghosts.
struct TabPill: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(selected ? Theme.bg : Theme.faint)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(selected ? Theme.ink : Theme.tile))
        }
        .buttonStyle(.plain)
    }
}

/// The ONE thing the collapsed strip says, and it is always about **capture health**:
/// stopped, paused, or nothing at all. A bare notch means the memory is being written.
///
/// Counts used to share this slot: an overdue pill, then a due-today line. Both are gone.
/// The strip is not a to-do list and a number sitting in the corner of the screen all day
/// is a nag nobody asked for; the commitments are still in the app, on the pane that is
/// about them, where somebody goes when they want them.
///
/// A focus countdown used to sit here too. The timer is gone.
struct StripStatusSlot: View {
    /// What capture is doing. The only thing this slot ever reports.
    var health: CaptureHealth = .capturing
    /// The pause countdown, when one is running down.
    var pauseLabel: String?

    var body: some View {
        Group {
            if !health.isHealthy {
                HealthChip(health: health, label: pauseLabel)
            }
        }
        // The slot never wraps: a clock split across two lines is a broken clock.
        .lineLimit(1)
        .fixedSize()
    }
}

/// The one thing in the strip that says the memory has stopped, in words.
///
/// It sits where the numbers sit, and while it is on screen the numbers do not appear at
/// all. That is the point: there is no arrangement of this strip in which a broken memory
/// is competing for space with a todo count.
struct HealthChip: View {
    let health: CaptureHealth
    /// Overrides the label when there is something better to say, such as a pause's countdown.
    var label: String?

    private var tint: Color { health.isFault ? Theme.bad : Theme.warn }
    private var text: String { label ?? health.shortLabel }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(tint.opacity(0.14)))
        .accessibilityLabel("Memoir is \(text.lowercased())")
    }
}

/// A transient message riding in the collapsed band: speech beside the face, a nudge
/// with its ✕, or a save receipt. Tapping the text acts on it; only ✕ records a
/// dismissal.
struct MomentView: View {
    let moment: ShellModel.BandMoment
    let onActivate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onActivate) {
                label
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if case .nudge = moment {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
                .help("Not now")
                .accessibilityLabel("Dismiss")
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        switch moment {
        case .speech(let text, _):
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.dim)

        case .nudge(let nudge):
            Text(nudgeCopy(nudge))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.ink)

        case .saved(let title, let due):
            HStack(spacing: 5) {
                Text("✓").foregroundStyle(Theme.good)
                Text(savedCopy(title: title, due: due)).foregroundStyle(Theme.dim)
            }
            .font(.system(size: 11.5, weight: .medium))

        case .health(let health, let text):
            HStack(spacing: 6) {
                Circle()
                    .fill(health.isHealthy ? Theme.good : (health.isFault ? Theme.bad : Theme.warn))
                    .frame(width: 6, height: 6)
                Text(text)
                    .foregroundStyle(health.isHealthy ? Theme.dim : Theme.ink)
            }
            .font(.system(size: 11.5, weight: .semibold))

        case .update(let release):
            HStack(spacing: 5) {
                Text("Memoir \(release.version) is out").foregroundStyle(Theme.ink)
                Text("click to download").foregroundStyle(Theme.dim)
            }
            .font(.system(size: 11.5, weight: .medium))
        }
    }

    /// Presentation copy for a nudge. `Nudge.summary` is diagnostics, not voice.
    private func nudgeCopy(_ nudge: Nudge) -> String {
        switch nudge {
        case .distraction(let appName, let minutes):
            return "\(minutes) min in \(appName). Still on purpose?"
        case .idleReturn:
            return "Welcome back. Want to pick up where you left off?"
        case .dailySummaryReady:
            return "Your day's summary is ready"
        }
    }

    private func savedCopy(title: String, due: Date?) -> String {
        guard let due else { return "Saved · \(title)" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return "Saved · \(title) · \(formatter.string(from: due))"
    }
}
