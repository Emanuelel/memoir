import Foundation

/// The four ceilings that stop a text walk, plus the clock it consults.
///
/// ``standard(maxCharacters:isOutOfTime:)`` is the only thing the accessibility walk ever
/// builds, so the constants in ``CaptureLimits`` are the ones actually enforced. A test can
/// therefore assert on `CaptureLimits` and know it is asserting on the real walk.
struct TextWalkLimits {

    /// Deepest level that is still allowed to have its children pushed.
    var maxDepth: Int

    /// Hard cap on elements visited.
    var maxNodes: Int

    /// Hard cap on characters collected.
    var maxCharacters: Int

    /// Consulted once per node. Returning true stops the walk immediately.
    ///
    /// A closure rather than a deadline instant so the walk itself never reads a clock and a
    /// test can drive the time limit without one.
    var isOutOfTime: () -> Bool

    /// The production limits: ``CaptureLimits/maxDepth`` and ``CaptureLimits/maxNodes``,
    /// with the per-snapshot character ceiling and time budget supplied by the caller.
    static func standard(maxCharacters: Int, isOutOfTime: @escaping () -> Bool) -> TextWalkLimits {
        TextWalkLimits(
            maxDepth: CaptureLimits.maxDepth,
            maxNodes: CaptureLimits.maxNodes,
            maxCharacters: maxCharacters,
            isOutOfTime: isOutOfTime
        )
    }
}

/// The bounded, pre-order, iterative tree walk that collects on-screen text.
///
/// It is generic over the node type for one reason: **the limits have to be testable.** The
/// accessibility tree cannot be driven in a test process, because it needs a granted
/// Accessibility permission and a live window server, so the traversal and its four ceilings
/// live here, where a synthetic tree can exercise them, and the accessibility-specific
/// attribute reads stay in `AXScraper`, which supplies them as closures.
///
/// This split exists because of a shipped bug: the walk was once depth-limited to 12, which
/// is far too shallow for a Chromium or Electron accessibility tree. It came back with almost
/// no text, that near-empty text hashed identically on every poll, and the dedupe gate threw
/// away ~98% of captures. The capture count froze. See CF-11.
enum BoundedTextWalk {

    /// What one walk produced.
    struct Outcome {
        /// Collected strings, in reading order, already de-duplicated within this walk.
        let pieces: [String]
        /// The subset of ``pieces`` that was long enough to be worth locating and was inside
        /// the window's bounds. Empty when nothing qualified or no geometry was available.
        let visiblePieces: [String]
        /// How many elements were visited.
        let nodesVisited: Int
        /// The deepest level actually visited. `0` when only the roots were seen.
        let deepestVisited: Int
        /// True when a depth, node, character or time ceiling stopped the walk early.
        let hitLimit: Bool
        /// True when the geometry budget ran out and later blocks went unlocated.
        let geometryExhausted: Bool

        /// The collected strings as one blob, exactly as a capture stores them.
        ///
        /// Newline separated: the walk is pre-order, so this is roughly reading order, and a
        /// newline is what keeps two unrelated labels from being glued into a word that
        /// appears in neither.
        var text: String { pieces.joined(separator: "\n") }

        /// The on-screen blocks as one blob, joined exactly as ``text`` is.
        var visibleText: String { visiblePieces.joined(separator: "\n") }
    }

    /// Below this, a string is a label, a button or a counter, and locating it is not worth
    /// an accessibility round trip.
    ///
    /// This constant is what keeps the geometry affordable. `isOnScreen` is only consulted
    /// for strings at least this long, so a LinkedIn feed costs a handful of position reads
    /// for the post bodies rather than one for every item in its navigation. And the answer
    /// to "what was on screen" is the prose that was on screen, not a list of menu labels
    /// that happened to be in frame.
    static let visibleTextMinimum = 80

    /// Most elements one walk will ask for geometry.
    ///
    /// The length gate alone is not a bound: a source file or a long document can hold
    /// hundreds of blocks over ``visibleTextMinimum``, and each probe is two blocking
    /// accessibility calls against a 400 ms deadline. This is the ceiling that stops the
    /// viewport question from eating the walk that answers the more important one.
    ///
    /// Running out can only omit, never invent (everything already recorded was genuinely
    /// in frame), so an exhausted budget yields a partial view of the screen rather than a
    /// wrong one. `geometryExhausted` says when that happened, so a thin visible slice can be
    /// told from a thin screen.
    static let maxGeometryProbes = 150

    /// Walks `roots` depth-first in reading order, collecting text within `limits`.
    ///
    /// - Parameters:
    ///   - roots: starting elements, walked in order.
    ///   - limits: the four ceilings.
    ///   - isSecure: true for an element whose value must never be read. Such an element
    ///     contributes no text **and is not descended into**: a password field's subtree is
    ///     invisible to the walk (CF-6).
    ///   - texts: the readable strings of one element, in the order they should be appended.
    ///     Must already be trimmed and non-empty.
    ///   - children: the element's children, in reading order.
    ///   - isOnScreen: whether this element lies within the window's bounds. Consulted **only**
    ///     for strings of at least ``visibleTextMinimum`` characters, so an implementation is
    ///     free to be expensive. Defaults to "unknown", which records nothing.
    static func run<Node>(
        roots: [Node],
        limits: TextWalkLimits,
        isSecure: (Node) -> Bool,
        texts: (Node) -> [String],
        children: (Node) -> [Node],
        isOnScreen: (Node) -> Bool = { _ in false }
    ) -> Outcome {
        var collected: [String] = []
        var visible: [String] = []
        var seen = Set<String>()
        var characters = 0
        var nodes = 0
        var deepest = 0
        var hitLimit = false
        var probes = 0
        var geometryExhausted = false

        // Explicit stack, pre-order, pushed reversed so the first child pops first and
        // reading order is roughly preserved.
        var stack: [(element: Node, depth: Int)] = roots.reversed().map { ($0, 0) }

        walk: while let (node, depth) = stack.popLast() {
            if nodes >= limits.maxNodes || characters >= limits.maxCharacters {
                hitLimit = true
                break walk
            }
            if limits.isOutOfTime() {
                hitLimit = true
                break walk
            }
            nodes += 1
            deepest = max(deepest, depth)

            // Never read a password field, and never descend into one.
            if isSecure(node) { continue }

            for value in texts(node) {
                let key = value.lowercased()
                // One sighting per string, and CF-100 is the record of why it stays that way.
                //
                // It was raised to two so an assistant's open conversation, named in the
                // sidebar and again as the heading, could be told apart from the forty that
                // were merely listed. Measured after CF-102 gave the walk the window as an
                // extra root, that no longer distinguishes anything: the window re-walks
                // what the web areas already returned, so "twice" means walked twice. It
                // cost 27% of a capture that was already truncated at the ceiling: real
                // content pushed out to make room for a second copy of a menu.
                guard !seen.contains(key) else { continue }
                seen.insert(key)

                // The separator counts. `text` is these pieces joined with a newline, so a
                // budget that only sums their lengths overshoots the ceiling by one character
                // per piece (44 pieces, 44 characters over), and the ceiling is then enforced
                // downstream by truncating the joined string instead.
                //
                // That is how a piece could end up in `visibleText` and not in `text` at all:
                // the visible slice is well under the limit and keeps what the truncation cut
                // off the end of the full one. Only `text` is indexed for search, so quoting
                // it would have cited words the capture does not contain. Counting the
                // separator here means the join lands on the ceiling rather than past it, and
                // nothing downstream has to cut.
                let separator = collected.isEmpty ? 0 : 1
                let remaining = limits.maxCharacters - characters - separator
                if remaining <= 0 {
                    hitLimit = true
                    break walk
                }
                let piece = value.count > remaining ? String(value.prefix(remaining)) : value
                collected.append(piece)
                characters += piece.count + separator
                // The length gate comes first, and short-circuits: it is what bounds the
                // number of accessibility round trips this walk makes.
                if piece.count >= visibleTextMinimum {
                    if probes < maxGeometryProbes {
                        probes += 1
                        if isOnScreen(node) { visible.append(piece) }
                    } else {
                        geometryExhausted = true
                    }
                }
                if piece.count < value.count {
                    hitLimit = true
                    break walk
                }
            }

            guard depth < limits.maxDepth else {
                hitLimit = true
                continue
            }
            let kids = children(node)
            if kids.isEmpty { continue }
            for child in kids.reversed() {
                stack.append((child, depth + 1))
            }
        }

        return Outcome(
            pieces: collected,
            visiblePieces: visible,
            nodesVisited: nodes,
            deepestVisited: deepest,
            hitLimit: hitLimit,
            geometryExhausted: geometryExhausted
        )
    }
}
