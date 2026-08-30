import Foundation

/// Labels raw captures with the names the memory already knows.
///
/// This is the payoff of authored entities: once the user's own ontology is in the
/// store (project names, aliases, ticket keys), the capture stream stops being
/// "time in Chrome" and becomes "time on the Fenwick migration", which is the thing
/// no per-app tracker can compute.
///
/// Pure and deterministic. Built once from a list of entities, then applied to any
/// number of captures. No store access, no clock, no model.
public struct Ontology: Sendable {

    /// One name the matcher can recognise, pointing back at the entity it names.
    struct Label: Sendable {
        let entityID: ID
        let title: String
        let kind: EntityKind
        let source: EntitySource
        /// The padded, normalised needle searched for, e.g. `" fenwick migration "`.
        /// Padding gives word-boundary semantics on a space-normalised haystack.
        let needle: String
    }

    let labels: [Label]

    /// A successful match: which entity, and by which of its names.
    public struct Match: Sendable, Equatable {
        public let entityID: ID
        public let title: String
        public let matchedName: String
        public let kind: EntityKind
    }

    // MARK: - Building

    /// Which kinds may label a span of work.
    ///
    /// Projects only, and now whoever wrote them. Threads were here once and it showed
    /// immediately on real data: an email subject line, extracted as a thread, became a
    /// bolded "project" in a timesheet, as "**lunch thursday, works for me**, 24m". A
    /// billable line named after someone's lunch plans is worse than an honest "Mail, 24m".
    ///
    /// Authored entities used to skip this set entirely — anything the user had written
    /// could name an hour, whatever its kind, on the reasoning that they chose to write it.
    /// Writing something down is not the same as working on it, and on the real vault the
    /// hatch proved it: the user's own Contacts card labelled 756 captures, another contact
    /// in the address book laid claim to 968, and Obsidian note filenames were billing too —
    /// "Competitive Landscape" 687, "Context" 241, "Architecture" 206. A note called
    /// "Context" is not a project, and a person's name in Contacts is not a claim on the
    /// afternoon. Source now decides which of two entities wins a tie (see the sort below);
    /// kind decides whether an entity may label at all.
    ///
    /// Measured on the real vault before removing it, over 45.9 hours of tracked active time
    /// across 23 days: named time falls from 47.8% to 37.1%, so roughly 4.9 hours stop
    /// carrying a name. Almost all of it was named *wrongly* — of the 21.9 hours named under
    /// the hatch, only 9.2 came from a project entity, 7.9 from Obsidian filenames and 4.8
    /// from Contacts cards. Time named by an actual project rises 9.2h -> 17.0h, +84%. The
    /// honest summary: coverage down 10.7 points, correct coverage up from 20.1% to 37.1%.
    static let labelKinds: Set<EntityKind> = [.project]

    /// Builds the matcher from stored entities.
    ///
    /// Included: non-deleted entities of a labelling kind, authored or inferred. A vault
    /// note titled "Fenwick Migration" no longer labels anything; the project called
    /// "Fenwick Migration" does, and that is the entity a timesheet line should name.
    /// Names shorter than three characters are dropped: "go" as a project alias would
    /// label half the screen. Everything is matched case-insensitively on normalised
    /// text, so "FEN-42", "fen 42" and "fen_42" all hit the same alias.
    public static func build(from entities: [Entity]) -> Ontology {
        var labels: [Label] = []
        for entity in entities where !entity.deleted {
            // A commitment is a TASK, never a topic. "Send the invoice" is not what an
            // hour of work was about, and on the real database a stray todo typed into the
            // push bar, "what was the last message I sent on whatdsapp", became the name
            // of an hour's work in the working set. Exactly the failure recorded above for
            // threads. It reached the matcher through the authored escape hatch, which is
            // now gone, so `labelKinds` alone would keep it out today. The guard stays as a
            // standing rule: whatever kind is added to `labelKinds` next, a todo is still
            // not a topic, and this line says so where somebody editing that set will see it.
            guard entity.kind != .commitment else { continue }
            guard labelKinds.contains(entity.kind) else { continue }
            var names = [entity.title]
            names.append(contentsOf: entity.aliases)
            for name in names {
                let normalized = MemoryText.normalizedTitle(name)
                guard normalized.count >= 3 else { continue }
                labels.append(Label(
                    entityID: entity.id,
                    title: entity.title,
                    kind: entity.kind,
                    source: entity.source,
                    needle: " " + normalized + " "
                ))
            }
        }
        // Longest needle first, authored before inferred on ties: when both "fenwick"
        // and "fenwick migration" match, the more specific name wins; when two entities
        // share a name, the one the user wrote wins.
        labels.sort { a, b in
            if a.needle.count != b.needle.count { return a.needle.count > b.needle.count }
            if (a.source == .authored) != (b.source == .authored) { return a.source == .authored }
            return a.title < b.title
        }
        return Ontology(labels: labels)
    }

    // MARK: - Matching

    /// The label for a capture, or nil when nothing known appears in it.
    ///
    /// The window title is weighed before body text: a title names what the window
    /// *is*, body text merely mentions things. Body text is capped so one giant page
    /// cannot make matching quadratic.
    public func match(windowTitle: String?, text: String, appName: String? = nil) -> Match? {
        let hit: Match?
        if let title = windowTitle, !title.isEmpty, let found = match(in: title) {
            hit = found
        } else {
            hit = match(in: String(text.prefix(Self.bodyPrefix)))
        }
        guard let hit else { return nil }

        // An application may not name the work done inside it.
        //
        // Every Chrome window title ends "— Google Chrome", so the moment an entity called
        // "Google Chrome" existed it matched every Chrome capture there was. On the real vault
        // one such row, minted from a single title-only sighting, matched 47.3% of the whole
        // corpus and inflated every coverage number the product reported by about 13.6 points
        // of the clock.
        //
        // Checked here rather than filtered at build time, and against the capture's own app
        // rather than a list of known applications, because a list ages and this does not: the
        // question "is this label just the name of the window frame it was read from" has a
        // correct answer at every match, for an app nobody has heard of yet.
        //
        // "Just the app" is exact-match only. A project genuinely called "Notes for Chrome"
        // still labels, because it is not what the frame is called.
        if let appName, MemoryText.normalizedTitle(appName) == MemoryText.normalizedTitle(hit.title) {
            return nil
        }
        return hit
    }

    /// How much of a capture's body the matcher reads when the window title says nothing.
    ///
    /// Was 600 characters, and on the post-fix corpus that left 4.1 of the 7.2 readable but
    /// unlabelled hours sitting behind the cutoff: Memoir had stored the text, the name was
    /// quite possibly in it, and the matcher stopped a paragraph in. The screen reader used to
    /// return so little that 600 was never the binding limit; once it started returning ten
    /// thousand characters, it was.
    ///
    /// Sized against what a capture actually holds rather than by round number. The cost is
    /// linear in this value and the whole match is a substring scan over normalised text, so
    /// the ceiling that matters is the per-capture text cap (``CaptureLimits/maxCharacters``),
    /// not this.
    static let bodyPrefix = 6_000

    /// The label for one piece of text.
    func match(in raw: String) -> Match? {
        guard !labels.isEmpty else { return nil }
        let haystack = " " + MemoryText.normalizedTitle(Self.camelSplit(raw)) + " "
        guard haystack.count > 2 else { return nil }
        for label in labels where haystack.contains(label.needle) {
            return Match(
                entityID: label.entityID,
                title: label.title,
                matchedName: label.needle.trimmingCharacters(in: .whitespaces),
                kind: label.kind
            )
        }
        return nil
    }

    /// True when the matcher has nothing to match against: a cold-start memory.
    public var isEmpty: Bool { labels.isEmpty }

    /// Splits camelCase humps so identifiers match their words: `FenwickImporter.swift`
    /// becomes `Fenwick Importer.swift` and the needle `" fenwick "` can hit it. Applied
    /// to the haystack only, since entity names are already words. A screen full of code is
    /// the majority case for the people this product is for; without this, exactly the
    /// captures that most clearly name a project would never label it.
    static func camelSplit(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        var previous: Character?
        for ch in s {
            if let p = previous, p.isLowercase || p.isNumber, ch.isUppercase {
                out.append(" ")
            }
            out.append(ch)
            previous = ch
        }
        return out
    }
}
