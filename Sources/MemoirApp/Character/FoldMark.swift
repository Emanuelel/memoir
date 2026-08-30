import SwiftUI

/// The mark, alive.
///
/// `Assets/memoir-mark.svg` is called *the fold*: a disc split into two halves with a gap
/// down the middle, cream on the left and violet on the right. This draws the same shape and
/// lets it move, so the thing in the notch and the thing on the icon are one object rather
/// than two unrelated pieces of art.
///
/// ## What the halves mean
///
/// **Left, cream: what you wrote.** The journal, corrections, anything authored.
/// **Right, violet: what it saw.** Capture.
/// **The gap:** what capture can never reach, which is why the mark is not a whole circle.
///
/// That gives every state an honest reading. When capture stops, the violet half goes dark:
/// half the memory is visibly missing, at 19 points, without a word of text. The README admits
/// that today the band "still looks healthy" while capture is dead and every answer quietly
/// describes yesterday. This is the fix.
///
/// ## Why not a face
///
/// A face has to be told never to emote (a smile over somebody's worst day would undo the
/// whole product), and a face told never to emote is fighting itself. An abstract mark reports
/// state without ever appearing to judge. It also cannot be mistaken for a mascot, and a brain
/// would have said "second brain", which is the one thing the positioning refuses to be.
struct FoldMark: View, Animatable {

    var traits: FoldTraits
    /// Kept for call-site compatibility with the face this replaces. The mark does not look
    /// anywhere, so gaze leans the halves a hair instead: presence, not attention.
    var gaze: CGPoint
    /// The breath. 0 is fully open, 1 fully drawn in. Driven by the same timer that used to
    /// blink, so nothing new has to tick.
    var blink: Double

    /// Lets SwiftUI interpolate every value, which is what makes states blend rather than cut.
    ///
    /// `nonisolated` because SwiftUI drives interpolation off the main actor; this is a value
    /// type with no shared state.
    nonisolated var animatableData: AnimatablePair<
        AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>,
        AnimatablePair<AnimatablePair<Double, Double>, Double>
    > {
        get {
            .init(
                .init(.init(traits.gap, traits.left), .init(traits.right, traits.turn)),
                .init(.init(traits.glow, blink), traits.alarm)
            )
        }
        set {
            traits.gap = newValue.first.first.first
            traits.left = newValue.first.first.second
            traits.right = newValue.first.second.first
            traits.turn = newValue.first.second.second
            traits.glow = newValue.second.first.first
            blink = newValue.second.first.second
            traits.alarm = newValue.second.second
        }
    }

    /// The design box, unchanged from the face so every existing frame still fits.
    private static let designSize = CGSize(width: 100, height: 110)

    /// Radius of each half-disc, and the gap at rest.
    ///
    /// The SVG's halves sit 18 units apart on a 240-unit diameter (7.5%). Rendered at 20
    /// points that slit closes to under half a pixel and the fold stops being a fold, so the
    /// gap is opened to 12% here. The mark is the identity; the gap is the *meaning*, and a
    /// meaning that vanishes at the size it is seen most is not worth being faithful about.
    private static let radius: CGFloat = 43
    private static let restingGap: CGFloat = radius * 2 * 0.12

    var body: some View {
        Canvas { ctx, size in
            let scale = min(size.width / Self.designSize.width, size.height / Self.designSize.height)
            ctx.translateBy(
                x: (size.width - Self.designSize.width * scale) / 2,
                y: (size.height - Self.designSize.height * scale) / 2
            )
            ctx.scaleBy(x: scale, y: scale)

            let centre = CGPoint(x: 50, y: 55)

            // The breath draws the whole mark in very slightly. Small on purpose: at 19 points
            // anything larger reads as a glitch rather than as something alive.
            let breath = 1 - CGFloat(blink) * 0.05
            ctx.translateBy(x: centre.x, y: centre.y)
            ctx.rotate(by: .radians(traits.turn + Double(gaze.x) * 0.03))
            ctx.scaleBy(x: breath, y: breath)
            ctx.translateBy(x: -centre.x, y: -centre.y)

            let half = Self.restingGap * CGFloat(max(0, traits.gap)) / 2

            // A dimmed half also pulls in a little. Opacity alone survives 200 points and
            // disappears at 19, where this has to work hardest.
            drawHalf(&ctx, centre: centre, gap: half, side: .left,
                     presence: traits.left, colour: Theme.markPaper)

            // The alarm repaints the violet half red rather than removing it, so the
            // silhouette is unchanged and only the *meaning* moves. A shape that vanishes
            // can be read as a rendering glitch; a shape that turns red and breathes cannot.
            // `alarm` is driven as a pulse by ``CharacterModel``, so this is the one thing
            // in the strip that moves when the memory has stopped, and the only thing that
            // moves when it has not is the slow breath, which is an order of magnitude
            // quieter. Still means dead is the rule the whole indicator rests on.
            let right = traits.alarm > 0.01
                ? Theme.markInk.mix(with: Theme.bad, by: min(1, traits.alarm))
                : Theme.markInk
            drawHalf(&ctx, centre: centre, gap: half, side: .right,
                     presence: traits.right, colour: right)

            if traits.glow > 0.01 {
                // Something is waiting on the user. The gap itself lights, because the gap is
                // where anything the product will not decide for itself lives. Lit in white
                // rather than in either half's colour: it has to read as a third thing, not
                // as one side bleeding into the other.
                let rect = CGRect(
                    x: centre.x - half * 0.72, y: centre.y - Self.radius * 0.80,
                    width: half * 1.44, height: Self.radius * 1.60
                )
                ctx.fill(
                    Path(roundedRect: rect, cornerRadius: half * 0.72),
                    with: .color(.white.opacity(traits.glow * 0.92))
                )
            }
        }
        .accessibilityHidden(true)
    }

    private enum Side { case left, right }

    /// One half-disc: a full circle whose centre sits on its own flat edge, clipped to that
    /// side. Built by intersection rather than by arc angles, because arc winding in a flipped
    /// coordinate space is the kind of thing that silently draws the wrong half and nobody
    /// notices until it ships.
    private func drawHalf(
        _ ctx: inout GraphicsContext,
        centre: CGPoint,
        gap: CGFloat,
        side: Side,
        presence: Double,
        colour: Color
    ) {
        let visible = max(0, min(1, presence))
        guard visible > 0.01 else { return }

        let radius = Self.radius * (0.82 + 0.18 * CGFloat(visible))
        let edge = side == .left ? centre.x - gap : centre.x + gap

        let disc = Path(ellipseIn: CGRect(
            x: edge - radius, y: centre.y - radius,
            width: radius * 2, height: radius * 2
        ))
        let mask = Path(CGRect(
            x: side == .left ? 0 : edge,
            y: 0,
            width: side == .left ? edge : Self.designSize.width - edge,
            height: Self.designSize.height
        ))

        ctx.fill(disc.intersection(mask), with: .color(colour.opacity(visible)))
    }
}

/// The interpolatable shape of the mark. Every property is a number so states can blend.
///
/// Deliberately not an emotional vocabulary. Each value answers a question about the memory:
/// is capture landing, is anything waiting, is the machine working right now.
struct FoldTraits: Equatable, Sendable {
    /// Multiplier on the resting gap. 1 is the mark as drawn.
    var gap: Double
    /// Presence of the cream half: what you wrote. 0 gone, 1 whole.
    var left: Double
    /// Presence of the violet half: what it saw. 0 gone, 1 whole.
    var right: Double
    /// Rotation of the whole mark, in radians.
    var turn: Double
    /// Light in the gap, for when something is waiting on the user. 0…1.
    var glow: Double
    /// How hard the mark is shouting that capture has stopped. 0 silent, 1 full alarm.
    ///
    /// Separate from every other trait because it is not an expression: it reports a fact
    /// about the pipeline, it outranks whatever mood the app is in, and it is the only
    /// value here that is allowed to animate forever.
    var alarm: Double = 0
}

#Preview("Every state the memory can be in") {
    HStack(spacing: 20) {
        ForEach(Expression.allCases, id: \.self) { state in
            VStack(spacing: 10) {
                FoldMark(traits: state.fold, gaze: .zero, blink: 0)
                    .frame(width: 64, height: 70)
                Text(state.rawValue).font(.caption2).foregroundStyle(Theme.faint)
            }
        }
    }
    .padding(30)
    .background(Theme.bg)
}

#Preview("Every size the shell uses") {
    HStack(alignment: .center, spacing: 26) {
        // 20pt: the collapsed band. 28pt: the sidebar. 74pt and up: opened.
        FoldMark(traits: Expression.idle.fold, gaze: .zero, blink: 0)
            .frame(width: 20, height: 22)
        FoldMark(traits: Expression.thinking.fold, gaze: .zero, blink: 0)
            .frame(width: 28, height: 30)
        FoldMark(traits: Expression.concerned.fold, gaze: .zero, blink: 0)
            .frame(width: 74, height: 80)
        FoldMark(traits: Expression.alert.fold, gaze: .zero, blink: 0)
            .frame(width: 200, height: 220)
    }
    .padding(28)
    .background(Theme.bg)
}
