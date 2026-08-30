import SwiftUI

/// The whole surface vocabulary, in one place.
///
/// Black, white, and almost nothing else. The panel is pure black against the bezel,
/// tiles are `tile` fills with no borders, structure is a single hairline, selection
/// is white. The only colour that ever appears is the tongue/overdue pink, the good
/// green, and a warning amber, each with exactly one meaning.
enum Theme {

    // MARK: - Palette

    /// The panel and the window. Pure black, so the band fuses with the bezel.
    static let bg = Color(hex: 0x000000)
    /// The window-scale card surface (sidebar hover, grouped regions).
    static let card = Color(hex: 0x0C0C0D)
    /// The tile fill: chips, confirm cards, inactive pills. No borders, ever.
    static let tile = Color(hex: 0x141417)
    /// The one hairline rule.
    static let line = Color(hex: 0x1E1E21)
    /// The slightly stronger hairline, for the rare emphasised divider.
    static let line2 = Color(hex: 0x2A2A2E)
    /// Primary ink. Also the selection fill (white pill, black text).
    static let ink = Color(hex: 0xFFFFFF)
    /// Secondary text.
    static let dim = Color(hex: 0x9B9BA0)
    /// Tertiary text: hints, timestamps, the coach mark.
    static let faint = Color(hex: 0x65656B)
    /// Quieter than faint: ghost text that should barely register.
    static let ghost = Color(hex: 0x4E4E54)
    /// Good news: the running timer dot, a completed tick, "on this Mac".
    static let good = Color(hex: 0x3ECF7E)
    /// Caution. Used sparingly: almost everything cautionary is just dim text.
    static let warn = Color(hex: 0xF5C451)
    /// The one alarm colour, and it means exactly one thing: the memory is not being written.
    ///
    /// It is the pink this palette used to spend on overdue counts, freed when the accent
    /// became the mark's own violet. Nothing else in the app is allowed to use it, because an
    /// alarm colour that also decorates a badge is not an alarm colour.
    static let bad = Color(hex: 0xF2637F)
    /// The tongue, the overdue count, the one accent. Same pink everywhere.
    /// The two halves of `Assets/memoir-mark.svg`, exactly as the mark is drawn.
    ///
    /// Cream is what you wrote; violet is what it saw. These are the brand, and every other
    /// colour in the app answers to them.
    static let markPaper = Color(hex: 0xF2EFE8)
    /// The violet half of the mark. Also the accent, so the icon and the interface agree.
    static let markInk = Color(hex: 0x8F7FD6)

    /// Was `0xF2637F`, a pink that appears nowhere in the mark: the disconnect between the
    /// logo and the interface, in one line. Now the mark's own violet.
    static let accent = markInk

    /// Chat: what the user said. White bubble, black text.
    static let meBubble = Color(hex: 0xFFFFFF)
    /// Chat: Memoir's reply ink. Plain text on black, no bubble.
    static let memoirInk = Color(hex: 0xE4E4E7)

    // MARK: - Radii

    /// Bottom corners of the open band.
    static let rBandOpen: CGFloat = 22
    /// Bottom corners of the collapsed band / synthetic tab.
    static let rBandCollapsed: CGFloat = 12
    /// Tiles and cards.
    static let rTile: CGFloat = 16
    /// Confirm chips and moment cards.
    static let rChip: CGFloat = 14
    /// The todo tick box.
    static let rTick: CGFloat = 7
    /// The user's chat bubble.
    static let rBubble: CGFloat = 18

    // MARK: - Hairline

    /// A 1px rule in the standard line colour.
    static var hairline: some View {
        Rectangle().fill(line).frame(height: 1)
    }

    /// A 1px vertical rule, for the band's column split.
    static var vHairline: some View {
        Rectangle().fill(line).frame(width: 1)
    }
}

extension Color {
    /// `Color(hex: 0x141417)`. The palette above is authored as hex to stay
    /// byte-identical with Docs/ui.html.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Surface environment

/// Which shell a pane is rendering inside. The same pane views serve both; padding,
/// type size and section depth adapt to the surface rather than forking the view.
enum MemoirSurface {
    /// The notch band: compact, wide-not-tall, inner scroll.
    case band
    /// The promoted window: roomier metrics, full-height lists.
    case window
}

private struct MemoirSurfaceKey: EnvironmentKey {
    static let defaultValue: MemoirSurface = .band
}

extension EnvironmentValues {
    var memoirSurface: MemoirSurface {
        get { self[MemoirSurfaceKey.self] }
        set { self[MemoirSurfaceKey.self] = newValue }
    }
}
