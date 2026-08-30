import Foundation

/// Deterministic, zero-cost extraction. Always runs, uses no model, never touches
/// the network, and produces the same entities for the same text every time.
///
/// What it finds:
/// - **commitments**: "I'll ...", "I will ...", "can you ...", "could you ...",
///   "let's ...", "TODO", "action item", "by <date>", "before <event>", "due <date>"
/// - **dates**: today / tonight / tomorrow, weekday names, "next week", ISO dates,
///   `DD/MM`, `MMM D`, all resolved against the capture timestamp
/// - **people**: `@mentions`, "Hi <Name>", "thanks <Name>", "From: <Name>", and
///   capitalised names that recur three or more times with a person cue nearby
/// - **projects**: ticket keys such as `ABC-123`, repository slugs, repeated Title
///   Case phrases
/// - **threads**: subject lines and `#channel` names
/// - **decisions**: "we decided", "we agreed", "going with" (a small bonus over the
///   contract's list, kept deliberately high precision)
///
/// Every entity it produces carries at least one `Provenance` row pointing at the
/// capture ID and the exact snippet it was read from.
///
/// Bare URLs are detected but do **not** become standalone entities: they are used
/// to derive repository projects (`github.com/owner/repo`) instead. A memory full of
/// link rows would be noise, and the design biases toward silence.
public struct RuleExtractor: Extractor {

    /// Upper bound on captures inspected in a single pass, to keep consolidation bounded.
    public static let maxCaptures = 2_000
    /// Upper bound on commitments taken from a single capture.
    public static let maxCommitmentsPerCapture = 8
    /// How many times a capitalised phrase must recur before it becomes an entity.
    public static let repetitionThreshold = 3

    /// The names the user is labelled by, or nil to follow whatever the process has installed.
    ///
    /// An explicit list wins, so a caller can extract against a known identity without
    /// touching shared state. Nil is the app's case: the extractor is built at launch and the
    /// names can arrive later, so the value is read again on every pass.
    private let ownNames: UserNames?

    /// Creates a rule extractor. It holds no state beyond the names it was handed.
    public init(ownNames: UserNames? = nil) {
        self.ownNames = ownNames
    }

    /// Runs every rule over the batch.
    ///
    /// - Parameter captures: captures to read.
    /// - Returns: entities plus their provenance. Never throws in practice: a
    ///   malformed pattern or unreadable capture is skipped, not raised.
    public func extract(from captures: [CaptureEvent]) async throws -> ExtractionResult {
        guard !captures.isEmpty else { return .empty }

        let patterns = RulePatterns()
        let dates = MemoryDateResolver()
        // Resolved once per pass rather than once per extractor: the app builds this object
        // at launch and asks the user what they are called during onboarding, which happens
        // afterwards. Reading it here is what makes a name typed then count on the very next
        // consolidation instead of the next launch.
        let names = ownNames ?? .current
        var builder = ExtractionBuilder()
        builder.extractor = .rule
        var nouns = ProperNounCounter()

        for capture in captures.prefix(Self.maxCaptures) {
            let text = Self.scannableText(for: capture)
            guard text.count >= 4 else { continue }
            let ns = text as NSString
            let index = SegmentIndex(text: text)

            extractSegmentEntities(
                capture: capture, text: text, ns: ns, index: index,
                patterns: patterns, dates: dates, ownNames: names, into: &builder
            )
            extractPeople(capture: capture, text: text, ns: ns, index: index, patterns: patterns, into: &builder)
            extractProjects(capture: capture, text: text, ns: ns, index: index, patterns: patterns, into: &builder)
            extractThreads(capture: capture, text: text, ns: ns, index: index, patterns: patterns, into: &builder)

            nouns.ingest(capture: capture, text: text, ns: ns, index: index, patterns: patterns)
        }

        nouns.emit(into: &builder)
        return builder.build()
    }

    // MARK: - Input

    /// The text a capture contributes: window title first (it is usually the subject
    /// line or document name), then the body.
    static func scannableText(for capture: CaptureEvent) -> String {
        let title = capture.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return body }
        if body.isEmpty { return title }
        return title + "\n" + body
    }

    // MARK: - Commitments and decisions

    private func extractSegmentEntities(
        capture: CaptureEvent,
        text: String,
        ns: NSString,
        index: SegmentIndex,
        patterns: RulePatterns,
        dates: MemoryDateResolver,
        ownNames: UserNames,
        into builder: inout ExtractionBuilder
    ) {
        var taken = 0
        for range in index.ranges {
            guard taken < Self.maxCommitmentsPerCapture else { break }
            let raw = ns.substring(with: range)
            var segment = MemoryText.clean(raw)
            guard segment.count >= 12, segment.count <= 400 else { continue }
            guard segment.split(separator: " ").count >= 3 else { continue }
            var segmentRange = NSRange(location: 0, length: (segment as NSString).length)

            // Decisions first: they are rarer and more valuable than commitments.
            if patterns.decision.firstMatch(in: segment, options: [], range: segmentRange) != nil {
                builder.add(
                    kind: .decision,
                    title: MemoryText.truncate(segment, max: 140),
                    detail: "Seen in \(capture.appName)",
                    confidence: 0.55,
                    capture: capture,
                    snippet: segment
                )
                taken += 1
                continue
            }

            // CF-62: the user's own label is stripped, not merely exempted.
            //
            // Chat apps label EVERY message, the user's own included, so exempting the label
            // from the attribution guard (CF-14) was only half the fix: "Emanuele: I'll send
            // the invoice Friday" survived, but it survived label and all. The label rode
            // into the stored title, and any phrasing that keeps its pronoun inside the label
            // ("Emanuele: will send it Friday") still died on the personal-voice floor,
            // because the only subject in the sentence was the name in front of it. When the
            // label names the user, the remainder IS a first-person sentence: strip it and
            // read what they actually typed. "Marco: I'll send the invoice Friday" strips
            // nothing and falls to the attribution guard below, exactly as before.
            var spokenByUser = false
            if let remainder = Self.strippingOwnSpeakerLabel(from: segment, ownNames: ownNames) {
                segment = remainder
                segmentRange = NSRange(location: 0, length: (segment as NSString).length)
                spokenByUser = true
            }

            var best: (confidence: Double, label: String)?
            // Tracked separately from the winning label, because the highest-confidence rule
            // is not always the one that says what KIND of sentence this is: "Marco: can you
            // drop the migration notes before the review?" scores as a Deadline, and reading
            // only the winner made it look like a statement rather than a question.
            var asksRatherThanPromises = false
            for rule in patterns.commitments {
                guard rule.regex.firstMatch(in: segment, options: [], range: segmentRange) != nil else { continue }
                if rule.label == "Request" { asksRatherThanPromises = true }
                if best == nil || rule.confidence > best!.confidence {
                    best = (rule.confidence, rule.label)
                }
            }
            guard var candidate = best else { continue }

            let due = dates.first(in: segment, reference: capture.ts)

            // Commitment phrasing is indistinguishable from ordinary conversation, so the
            // surface it appeared on decides whether it counts.
            //
            // "Can you also drop the migration notes" in Slack is a real request. The same
            // words typed into an AI chat are a prompt to a model. Nobody owes anybody
            // anything. Memoir stored "ok let's do it" and "can you give me the prompt u used"
            // as commitments, and the user rightly did not recognise them.
            //
            // On a conversational-AI surface a commitment therefore needs harder evidence:
            // a real deadline or an explicit task marker.
            // A page's own title is never a commitment. GitHub's description of Afterglance,
            // "…lets you search/chat your screen history", matched the "let's" pattern
            // and was stored as something the user owed someone. Marketing prose is not a
            // promise, and the window title is the reliable signal that it is a heading
            // rather than a message.
            if let title = capture.windowTitle, !title.isEmpty {
                let head = String(segment.prefix(60)).lowercased()
                if !head.isEmpty, title.lowercased().contains(head) { continue }
            }

            // Reject everything somebody else wrote, or a machine did.
            //
            // One call, one list, and the same list the sweep replays over rows written
            // before these guards existed. Each entry in it names a class of text that was
            // actually shown to the user as an open commitment; see
            // `readsAsSomebodyElsesWords`.
            if Self.readsAsSomebodyElsesWords(segment) { continue }

            // A speaker label disqualifies a PROMISE, not a question. "Marco: can you review
            // this by Friday?" carries someone else's name and is still addressed to
            // whoever is reading it, which in a transcript on the user's screen is usually
            // them. Only the first-person shapes are claims about who owes what.
            //
            // Unless the label is the user's own: a group chat labels every message,
            // including theirs.
            if !asksRatherThanPromises, Self.isAttributedToSomeoneElse(segment, ownNames: ownNames) { continue }

            // Whatever survives has to plausibly involve the user. A promise-shaped verb
            // inside a sentence about other people is a sentence about other people.
            //
            // Three ways to qualify. The user said it ("I'll", "we're"); it was said to them
            // ("can you"); or it is their own note, where the subject is dropped precisely
            // because it is theirs: a bullet ("- Finishing the migration script, will hand
            // it over by Thursday"), a bare imperative ("Send the signed lease scan to Elena
            // by Friday") or an explicit task marker, none of which leaves a grammatical
            // subject to read.
            // A stripped speaker label is the strongest first-person evidence there is: the
            // chat client itself wrote the user's name in front of the line (CF-62).
            let isTaskMarker = candidate.label == "TODO" || candidate.label == "Action item"
                || candidate.label == "Task box"
            if !isTaskMarker, !spokenByUser, !Self.startsWithBullet(raw), !Self.startsWithTaskVerb(segment),
               !Self.readsAsFirstPersonOrAddressed(segment) {
                continue
            }

            // A prompt is an instruction to a machine, not a promise to a person.
            //
            // This used to be a downgrade: on an assistant surface a commitment needed a
            // real date or an explicit task label, and anything with one was kept. Far too
            // weak. "ok now let's package all this homepage new addition fo rclaude coce.
            // BE explicit NOT to touch the existin" is the user briefing a coding agent, and
            // "can you qccess localhost:4611/ui.html" is the same sentence pointed at a
            // machine. Nobody is owed anything by either, and both were listed as things the
            // user had promised.
            //
            // Only the SURFACE is read here, never the capture's text. The text half of
            // ``isConversationalAI(_:)`` scans the whole capture, and a whole capture is a
            // whole Slack thread: one colleague writing "want me to take the migration?"
            // used to delete every commitment in the conversation underneath it. Measured on
            // 35 genuine commitments, that one line alone cost two of them. The register
            // test still runs, per segment, inside ``readsAsSomebodyElsesWords(_:)``, where
            // its blast radius is the sentence that actually reads as an assistant's.
            //
            // Nothing is lost that cannot be recovered: PUSH exists, so a real commitment
            // mentioned in a chat with a model can be told to Memoir in one sentence.
            if Self.isAssistantSurface(capture) { continue }

            if due != nil { candidate.confidence = min(0.9, candidate.confidence + 0.1) }

            // Read off a page rather than written by the user: keep it, never assert it.
            let provisional = Self.isReadingSurface(capture)

            let id = builder.add(
                kind: .commitment,
                title: MemoryText.truncate(segment, max: 140),
                detail: "\(candidate.label) in \(capture.appName)",
                dueAt: due?.date,
                confidence: candidate.confidence,
                capture: capture,
                snippet: segment,
                provisional: provisional
            )
            if let id, let due {
                builder.addProvenance(
                    entityID: id,
                    capture: capture,
                    field: "dueAt",
                    snippet: due.snippet,
                    extra: "resolved"
                )
            }
            taken += 1
        }
    }

    /// Surfaces where the user is talking to a model rather than to a person.
    ///
    /// Their content is prompts and generated replies, not work artefacts, and treating it
    /// as commitments produced entities the user could not recognise.
    static func isConversationalAI(_ capture: CaptureEvent) -> Bool {
        // Text is the only reliable signal when the assistant runs in a browser tab.
        //
        // Bundle ID says "Google Chrome" and the window title says whatever the
        // conversation is called, and neither mentions the assistant at all. So every reply
        // Claude wrote to me today ("Say which one(s) and I'll build out the full state
        // set…") was stored as something I owed someone. The register is the giveaway:
        // an assistant offering to do work phrases it in a very particular way.
        //
        // Whole-capture on purpose HERE and only here: the callers are grounding and the
        // semantic index, which ask "is this whole capture a conversation with a model",
        // and one assistant turn in it is enough to answer yes. The commitment path asks a
        // different question about one sentence, and uses the two halves separately.
        if Self.readsAsAssistantReply(capture.text) { return true }
        return Self.isAssistantSurface(capture)
    }

    /// Browsers. Reading surfaces by default, whatever happens to be in the tab.
    public static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari",
        "com.apple.SafariTechnologyPreview", "org.mozilla.firefox", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// True when the capture is a page the user was *reading* rather than text they wrote.
    ///
    /// This is the distinction the commitment extractor could not previously make, and it
    /// is the one that matters most. A browser shows you other people's first-person
    /// sentences all day: a tweet ("I will fight anyone who…"), a LinkedIn reply ("I'll
    /// have to check out your post"), an AI-drafted email ("Sounds great, Thursday works,
    /// I'll…"), your own landing-page copy ("Memoir is a macOS app that…"). By text alone
    /// none of those is distinguishable from a promise the user made.
    ///
    /// Measured on a real database: 25 stored commitments, 17 of them somebody else's
    /// words read off a web page, 78 of the commitment provenance rows from Chrome alone.
    ///
    /// The rule that follows is the mirror of the one grounding already applies to
    /// assistant chat: *what you saw is not what you said*. Commitments from here are
    /// kept and never surfaced, rather than dropped: the text is real, the ownership is
    /// not established, and inventing an obligation is the worse error by far.
    static func isReadingSurface(_ capture: CaptureEvent) -> Bool {
        // Assistant tabs are already handled, more strictly, upstream.
        guard !isAssistantSurface(capture) else { return false }
        let name = capture.appName.lowercased()
        let isBrowser = browserBundleIDs.contains(capture.appBundleID)
            // Bundle IDs drift and Electron wrappers lie; the name is a cheap second look.
            || ["chrome", "safari", "firefox", "arc", "edge", "brave", "vivaldi", "opera"]
                .contains { name == $0 || name.hasPrefix($0 + " ") }
        // Every tab, including the ones people write in.
        //
        // There used to be an allowlist here — a pull request, an inbox, a chat — on the
        // reasoning that half the tools people write in are web apps and a promise typed into
        // one is as real as a promise typed into Notes. The reasoning is sound and the
        // inference is not: being somewhere you COULD have written a sentence is not evidence
        // that you did. You read a pull request far more often than you write one, and an
        // inbox is other people's words by construction.
        //
        // Measured on a real memory: 308 open commitments came from a browser and only 59
        // carried the flag, because the rest were on allowlisted hosts. Against one — one —
        // commitment the user actually authored in seventy-five days. The three loudest were a
        // marketing email about a workshop and two sentences lifted out of the user's own
        // essay, each given a due date and shown back as a debt.
        //
        // `provisional` does not delete anything. The row is kept, searchable and citable; it
        // is only barred from being ASSERTED as something the user owes. A missed promise is
        // recoverable — PUSH exists, and one sentence restores it — and an invented one is
        // not. That asymmetry is the whole argument, and the allowlist was on the wrong side
        // of it.
        return isBrowser
    }

    /// Web apps whose content the user composes rather than consumes.
    ///
    /// An allowlist rather than a blocklist, because the default has to be safe: the open
    /// web is overwhelmingly other people's words, and a missed commitment is recoverable
    /// (PUSH exists, and corroboration clears the flag) where an invented one is not.
    static func isWritingHost(_ capture: CaptureEvent) -> Bool {
        let haystack = (capture.windowTitle ?? "").lowercased()
        let hosts = [
            "github.com", "gitlab.com", "bitbucket.org",
            "linear.app", "jira", "atlassian.net", "asana.com", "trello.com",
            "height.app", "shortcut.com", "basecamp.com", "clickup.com",
            "mail.google.com", "gmail", "outlook.", "superhuman", "hey.com", "fastmail",
            "notion.so", "coda.io", "slack.com", "discord.com/channels",
            // A chat you type into is a place you make promises, whatever the wrapper.
            //
            // Slack and Discord were already here; the browser versions of the messengers
            // were not, so a promise typed into WhatsApp Web was read off a "page" and
            // demoted by CF-79: extracted, marked provisional, and never shown. On a
            // machine where WhatsApp *is* a Chrome tab, that hides the commitments most
            // worth keeping. The same judgement already made for a pull request: half the
            // tools people write in are web apps.
            //
            // These surfaces carry other people's words too, which is exactly true of Slack
            // and is what the speaker-label and attribution guards are for.
            "web.whatsapp.com", "whatsapp", "web.telegram.org", "telegram",
            "messenger.com", "messages.google.com",
            "pull request", "issue #", "merge request",
        ]
        return hosts.contains { haystack.contains($0) }
    }

    /// Whether the capture was taken on a surface where the other party is a model.
    ///
    /// The half of ``isConversationalAI(_:)`` that reads only where the text came from.
    /// Markers that put a capture on somebody else's feed.
    ///
    /// Read off the window title, because that is what a browser gives us and a feed always
    /// says which one it is. `r/` catches Reddit both as a title suffix and mid-sentence.
    static let socialFeedMarkers: [String] = [
        " / x", " on x:", "x.com", "twitter", "linkedin", "instagram", "facebook",
        "reddit", "r/", "tiktok", "threads.net", "bsky", "mastodon", "hacker news",
    ]

    /// Places inside those sites where the user is a participant rather than an audience.
    static let conversationMarkers: [String] = ["messag", "/dm", "inbox", "chat"]

    /// Whether this capture is a social feed: somebody else's world, scrolling past.
    ///
    /// A feed is the one surface where repetition means the opposite of what it usually
    /// means. "Jorge Martín" was a person at 99% confidence with twelve mentions, and every
    /// one of them was X's trending sidebar: "Trending in Spain · Jorge Messi · Trending
    /// with Jorge Martín". A colleague mentioned twelve times is somebody you work with; a
    /// name mentioned twelve times on a timeline is a name the timeline is promoting.
    ///
    /// Direct messages on the same sites are excluded, because there the user IS the other
    /// participant. CF-91's invoice promise was typed into exactly such a thread.
    static func isSocialFeed(_ capture: CaptureEvent) -> Bool {
        let haystack = ((capture.windowTitle ?? "") + " " + capture.appName).lowercased()
        guard socialFeedMarkers.contains(where: haystack.contains) else { return false }
        return !conversationMarkers.contains(where: haystack.contains)
    }

    /// Pages that are a list of other people's names, in every language the browser says it in.
    ///
    /// Read off the window title, like the feed markers, and for the same reason: a browser
    /// tells you what kind of page it is and nothing else does.
    static let searchResultMarkers: [String] = [
        " - google search", " - cerca con google", " - búsqueda de google", " - recherche google",
        " - google suche", " - pesquisa google", " - google zoeken", "search results",
        "risultati di ricerca", "resultados de", "duckduckgo", " - bing", " - ecosia",
        "yelp", "tripadvisor", "yellow pages", "páginas amarillas", "directory",
    ]

    /// Whether this capture is a page of names the user was shopping through.
    ///
    /// The sibling of ``isSocialFeed(_:)``, and it exists because the feed rule could not
    /// catch what the record actually filled up with. Measured on a real database: 254 of 260
    /// "people" came from Google Chrome, and the ones that were checked came from an image
    /// search and a venue directory. `Vector Art` and `nordlysfoto` are not somebody's
    /// contacts. They are the contents of a results page.
    ///
    /// Repetition means the opposite of the usual thing here too: a name that appears eleven
    /// times across a search session is a listing the page kept showing, not a person the user
    /// keeps dealing with.
    static func isSearchResults(_ capture: CaptureEvent) -> Bool {
        let haystack = ((capture.windowTitle ?? "") + " " + capture.appName).lowercased()
        guard searchResultMarkers.contains(where: haystack.contains) else { return false }
        // A results page the user is talking in is a conversation, same carve-out as feeds.
        return !conversationMarkers.contains(where: haystack.contains)
    }

    /// Whether a captured name is just the application the capture came from.
    ///
    /// "Google Chrome" was a person, at 55% confidence, because every window title on the
    /// machine ends in " - Google Chrome" and the repetition path reads repetition as
    /// evidence. So were "Quote Machina Verified" and "Clearer Responses Trending", read off
    /// X's own furniture. An app's name is the one string guaranteed to appear beside
    /// everything the user ever looked at, which makes it the strongest possible signal by
    /// repetition and the weakest possible evidence of a person.
    ///
    /// Answered from the capture rather than from a list of app names, because Memoir
    /// already knows what it was looking at and a list would go stale the day the user
    /// installs something.
    static func namesTheCapturingApplication(_ name: String, capture: CaptureEvent) -> Bool {
        let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !candidate.isEmpty else { return false }
        return candidate == capture.appName.lowercased()
    }

    static func isAssistantSurface(_ capture: CaptureEvent) -> Bool {
        let bundles: Set<String> = [
            "com.anthropic.claudefordesktop", "com.openai.chat", "com.google.gemini",
            "com.perplexity.desktop", "com.microsoft.copilot",
        ]
        if bundles.contains(capture.appBundleID) { return true }
        let haystack = ((capture.windowTitle ?? "") + " " + capture.appName).lowercased()
        return ["claude.ai", "chatgpt.com", "chat.openai.com", "gemini.google.com",
                "perplexity.ai", "copilot.microsoft.com"]
            .contains { haystack.contains($0) }
    }

    // MARK: - People

    private func extractPeople(
        capture: CaptureEvent,
        text: String,
        ns: NSString,
        index: SegmentIndex,
        patterns: RulePatterns,
        into builder: inout ExtractionBuilder
    ) {
        let full = NSRange(location: 0, length: ns.length)

        func addPerson(_ rawName: String, at location: Int, confidence: Double, source: String) {
            let name = RulePatterns.cleanName(rawName)
            guard RulePatterns.isPlausiblePersonName(name) else { return }
            guard !Self.namesTheCapturingApplication(name, capture: capture) else { return }
            // A feed is somebody else's world. The names on it are the ones an algorithm
            // chose to show, and filing them as people the user knows is how a trending
            // footballer and a perfume brand's founder ended up in `who_is` (CF-97).
            guard !Self.isSocialFeed(capture) else { return }
            builder.add(
                kind: .person,
                title: name,
                detail: source,
                confidence: confidence,
                capture: capture,
                snippet: index.snippet(for: location, in: ns)
            )
        }

        for m in patterns.mention.matches(in: text, options: [], range: full) where m.numberOfRanges > 1 {
            let handle = ns.substring(with: m.range(at: 1))
            guard handle.count >= 2 else { continue }
            // An @ is only a person on a social surface. On a developer's screen it is
            // overwhelmingly syntax: today's own captures produced "@Generable" and
            // "@Guide", Swift macros from this very file, as people, alongside the
            // domain "@northvale.co". Code is not a conversation.
            guard !Self.isCodeHandle(handle) else { continue }
            addPerson(handle, at: m.range.location, confidence: 0.6, source: "Mentioned as @\(handle)")
        }

        for m in patterns.greeting.matches(in: text, options: [], range: full) where m.numberOfRanges > 1 {
            addPerson(ns.substring(with: m.range(at: 1)), at: m.range.location, confidence: 0.6, source: "Addressed directly")
        }

        for m in patterns.thanks.matches(in: text, options: [], range: full) where m.numberOfRanges > 1 {
            addPerson(ns.substring(with: m.range(at: 1)), at: m.range.location, confidence: 0.55, source: "Thanked by name")
        }

        for m in patterns.header.matches(in: text, options: [], range: full) where m.numberOfRanges > 2 {
            let field = ns.substring(with: m.range(at: 1))
            addPerson(
                ns.substring(with: m.range(at: 2)),
                at: m.range.location,
                confidence: 0.65,
                source: "Message header (\(field))"
            )
        }
    }

    /// Whether one title is a growing prefix of another.
    ///
    /// Typing produces a capture per pause, each holding a slightly longer version of the
    /// same sentence, so "LEt's explore some more creative alternatives…" was stored four
    /// times at four lengths. Exact-match dedup cannot see these as the same thing; a
    /// prefix comparison can. The longest form wins, since it is the finished thought.
    static func isPrefixDuplicate(_ a: String, _ b: String) -> Bool {
        let x = MemoryText.collapseWhitespace(a).lowercased()
        let y = MemoryText.collapseWhitespace(b).lowercased()
        guard x != y else { return true }
        let (shorter, longer) = x.count < y.count ? (x, y) : (y, x)
        // Needs enough shared text to be meaningful rather than coincidence.
        guard shorter.count >= 25 else { return false }
        return longer.hasPrefix(shorter)
    }

    /// Whether text reads as an AI assistant's reply.
    ///
    /// Assistants offer to do things in a stereotyped way: "say the word and I'll…",
    /// "tell me which and I'll…", "if you want, I can…". Real commitments between people
    /// are rarely phrased as a conditional offer to perform work on request.
    ///
    /// Every phrase here has to carry the OFFER, not the work. The list used to include
    /// "and i'll build", "and i'll draft", "and i'll write" and four more of that family,
    /// which is a conjunction plus an ordinary verb: "I'll review the deck and I'll write
    /// the summary by Friday" is a person, twice. The antecedent phrases ("say which", "say
    /// the word", "tell me which") already catch the sentence those were added for, so the
    /// bare "and i'll …" forms were removed. "i can also" and "here's what i" went with
    /// them for the same reason: both are ordinary English with an assistant's accent.
    static func readsAsAssistantReply(_ text: String) -> Bool {
        let t = text.lowercased()
        let offers = [
            "say which", "say the word", "tell me which", "let me know which",
            "if you want, i can", "if you'd like, i can", "want me to",
            "i'll go ahead and", "would you like me to", "shall i",
        ]
        return offers.contains(where: t.contains)
    }

    /// Prefixes that look like ticket keys but name a format, codec or standard.
    ///
    /// Closed list by necessity: no regex distinguishes MPEG-4 from ACME-412, because there
    /// is no structural difference between them. Extend it when a new false positive shows
    /// up rather than trying to be clever about the shape.
    static let technicalIdentifiers: Set<String> = [
        "MPEG", "MP", "H", "AVC", "HEVC", "UTF", "ISO", "IEC", "RFC", "ANSI",
        "IEEE", "USB", "HDMI", "VGA", "DVI", "AES", "SHA", "MD", "RGB", "CMYK",
        "IPV", "HTTP", "TLS", "SSL", "WPA", "GPT", "CVE", "PEP", "JPEG", "PNG",
        "AAC", "FLAC", "WAV", "AV", "VP", "WEBM", "DDR", "PCIE", "SATA", "NVME",
    ]

    // MARK: - Refusals

    /// Every reason a promise-shaped segment is not something the user owes anybody.
    ///
    /// One predicate, consulted from two places on purpose: the extractor asks it before
    /// writing, and ``isJunkEntity(_:)`` asks it when retiring rows that were written before
    /// these guards existed. A guard that only ran at write time would leave the list the
    /// user is actually looking at exactly as it was.
    ///
    /// Every entry below was taken from that list. Twenty-three of the twenty-four rows Memoir
    /// was showing under "open commitments" were junk, and each guard names one class of it:
    ///
    /// | guard                        | what it refuses                                  |
    /// |------------------------------|--------------------------------------------------|
    /// | `looksLikePublishedCopy`     | headlines, page titles, site furniture           |
    /// | `carriesTimelineFurniture`   | posts scraped off a social timeline              |
    /// | `carriesCodeHostChrome`      | GitHub's buttons, a repo heading, a Q&A title    |
    /// | `readsAsPromptToAssistant`   | the user's own prompts, typed at a model         |
    /// | `readsAsProductTour`         | a product's chatbot describing itself            |
    /// | `readsAsBroadcastPost`       | LinkedIn announcements                           |
    /// | `promisesOnlyASentiment`     | "I'll be there", "I'll stay connected"           |
    /// | `readsAsMarketingPitch`      | ad copy                                          |
    /// | `isAllCapsBanner`            | a shouted banner                                 |
    /// | `carriesSiteNameFurniture`   | a listing title with its source site appended    |
    /// | `readsAsMemoirsOwnInterface`    | Memoir's own words, read off Memoir's own screen       |
    /// | `readsAsForeignProse`        | article prose in a language these rules cannot judge |
    /// | `readsAsAssistantReply`      | a model offering to do work, one sentence at a time |
    /// | `describesACapability`       | documentation: "X lets Y do Z"                   |
    /// | `solicitsAnAudience`         | "Follow for posts", "Subscribe for top posts"    |
    ///
    /// The bias is one-directional. A missed commitment is a disappointment the user already
    /// knows about, and one sentence of PUSH fixes it. An invented one is a claim about what
    /// they promised, complete with a due date, and they cannot tell it is wrong without
    /// going and checking.
    ///
    /// But one-directional is not free, and the first cut of these guards was measured and
    /// found to cost far too much: over 35 genuine commitments it kept 7, against 28 for the
    /// branch it replaced, and it retired 24 already-stored real ones on sweep. A memory that
    /// refuses four fifths of your promises fails as badly as one full of junk, and it fails
    /// silently. Every guard below was rewritten to the same principle afterwards:
    ///
    /// **Fire on the SHAPE of the junk, never on a word the junk happens to contain.**
    ///
    /// A guard keyed to one common token always takes real sentences with it. A minimal-pair
    /// test, the same sentence with only the trigger token removed, showed 14 of 15 losses
    /// were caused by the guards and not by the sentences being marginal. Where a guard could
    /// not be made precise it was narrowed or dropped, and the reason is recorded on it.
    static func readsAsSomebodyElsesWords(_ segment: String) -> Bool {
        looksLikePublishedCopy(segment)
            || carriesTimelineFurniture(segment)
            || carriesCodeHostChrome(segment)
            || readsAsPromptToAssistant(segment)
            || readsAsProductTour(segment)
            || readsAsBroadcastPost(segment)
            || promisesOnlyASentiment(segment)
            || readsAsMarketingPitch(segment)
            || isAllCapsBanner(segment)
            || carriesSiteNameFurniture(segment)
            || readsAsMemoirsOwnInterface(segment)
            || readsAsForeignProse(segment)
            || readsAsAssistantReply(segment)
            || describesACapability(segment)
            || solicitsAnAudience(segment)
    }

    // MARK: - Shape tests shared by the guards

    /// Pronouns that put a person in the subject or object seat of the sentence.
    ///
    /// Tighter than ``personalPronouns`` on purpose: "your" is missing, because "Ask Memoir
    /// about your work" is interface copy addressed at nobody in particular, while "can you
    /// tell me what's due" has a real speaker and a real addressee. Possessives describe a
    /// thing; these name a participant.
    static let actorPronouns: Set<String> = [
        "i", "i'll", "i'm", "i've", "i'd", "me", "my", "myself",
        "we", "we'll", "we're", "we've", "us", "let's", "lets",
        "you", "you'll", "you're", "you've",
    ]

    /// Whether somebody is speaking or being spoken to in this segment.
    ///
    /// The single most useful shape signal in this file. A rendered page, a button bar, a
    /// banner and an app's own interface copy have no participants; a message, a request and
    /// a note to self always do. Three guards use it to keep their vocabulary from firing on
    /// a sentence somebody actually said.
    static func namesAParticipant(_ segment: String) -> Bool {
        let tokens = segment.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
        return tokens.contains { Self.actorPronouns.contains(String($0)) }
    }

    /// Words that name a moment. Not a date parser: this only has to answer "does this
    /// sentence say WHEN", which is the difference between a promise that can be finished
    /// and a feeling that cannot.
    static let timeExpressions: Set<String> = [
        "today", "tonight", "tomorrow", "yesterday", "monday", "tuesday", "wednesday",
        "thursday", "friday", "saturday", "sunday", "mon", "tue", "tues", "wed", "weds",
        "thu", "thur", "thurs", "fri", "sat", "sun",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "morning", "afternoon", "evening", "noon", "midnight", "midday",
        "week", "weeks", "weekend", "month", "months", "quarter", "deadline",
        "eod", "eow", "asap",
    ]

    /// Whether the segment says when. A digit counts: dates, times and quantities of days
    /// all arrive as numerals, and none of them appears in a sentence about a feeling.
    static func carriesATimeExpression(_ segment: String) -> Bool {
        for token in segment.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }) {
            if Self.timeExpressions.contains(String(token)) { return true }
            if token.contains(where: \.isNumber) { return true }
        }
        return false
    }

    /// Whether any word from `start` onward is a task verb, in the forms a verb takes.
    ///
    /// The stem list is written in the infinitive, and real sentences conjugate: "writing
    /// the release notes", "sending the invoice", "signed the lease". Without this,
    /// "I'll support the launch by writing the release notes on Thursday" reads as a
    /// promise with nothing in it to do.
    static func carriesATaskVerb(_ words: [String], from start: Int) -> Bool {
        guard start < words.count else { return false }
        for word in words[start...] {
            if Self.taskVerbs.contains(word) { return true }
            for suffix in ["s", "ing", "ed", "d"] where word.count > suffix.count + 2 {
                guard word.hasSuffix(suffix) else { continue }
                let stem = String(word.dropLast(suffix.count))
                if Self.taskVerbs.contains(stem) { return true }
                // "writing" → "writ" → "write"; "scheduled" → "schedul" → "schedule".
                if Self.taskVerbs.contains(stem + "e") { return true }
            }
        }
        return false
    }

    /// Labels people put in front of a line to mark it as a job to do.
    static let taskMarkers: Set<String> = [
        "todo", "to-do", "task", "tasks", "action", "fixme", "next",
    ]

    /// Whether the segment is an instruction the writer left themselves: an explicit task
    /// marker in front of a task verb, or a bare leading imperative.
    ///
    /// Language-independent, which is the point. A marker plus a verb is evidence a human
    /// wrote a to-do, and it stays evidence when the rest of the line is in Italian.
    static func carriesATaskInstruction(_ segment: String) -> Bool {
        var words = segment
            .split(whereSeparator: { $0.isWhitespace })
            .map { Self.trimPunctuation(String($0)).lowercased() }
        if let first = words.first, Self.taskMarkers.contains(first) { words.removeFirst() }
        guard let head = words.first else { return false }
        return Self.taskVerbs.contains(head)
    }

    /// Whether the segment opens with an explicit task marker: "TODO:", "Task:", "[ ]".
    static func opensWithATaskMarker(_ segment: String) -> Bool {
        let trimmed = segment.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[ ]") || trimmed.hasPrefix("[]") { return true }
        guard let first = trimmed.split(whereSeparator: { $0.isWhitespace }).first else { return false }
        return Self.taskMarkers.contains(Self.trimPunctuation(String(first)).lowercased())
    }

    /// Whether a segment reads as published copy rather than something the user said.
    ///
    /// Marketing and headlines are written to sound like commitments (that is their job),
    /// so phrasing alone cannot separate them. These are the structural tells instead.
    ///
    /// A screen is mostly other people's words: video titles, ad copy, product marketing.
    /// "Give Me Just a Few Days And I'll Show You…" (a YouTube title) and "Go outside with
    /// your Tamagotchi Uni device! Let's TAMA SEARCH!" (a product page) both became things
    /// the user owed.
    static func looksLikePublishedCopy(_ segment: String) -> Bool {
        let t = segment.trimmingCharacters(in: .whitespacesAndNewlines)

        // Title Case Across Most Words is a headline, not a sentence someone typed.
        //
        // ALL-CAPS words are excluded from both halves of the ratio. Title Case means a
        // capital followed by lowercase; a word with no lowercase in it is shouting, and
        // shouting is ``isAllCapsBanner(_:)``'s question, not this one. Counting them here
        // made "TODO: SEND THE SIGNED LEASE SCAN TO ELENA", the user's own note, in caps,
        // a 100% Title Case headline.
        let words = t.split(separator: " ").filter { $0.count > 3 && $0.contains(where: \.isLowercase) }
        if words.count >= 5 {
            let capitalised = words.filter { $0.first?.isUppercase == true }.count
            if Double(capitalised) / Double(words.count) > 0.7 { return true }
        }

        // Pipe-separated breadcrumbs are page titles: "… | News | Tamagotchi Uni | Official Site".
        if t.components(separatedBy: " | ").count >= 3 { return true }

        // Site furniture that only ever appears in published pages.
        //
        // Five entries were removed after measurement: "privacy policy", "cookie",
        // "subscribe", "learn more" and "read more". Every one of them names real work a
        // person does: "I'll draft the privacy policy update before Friday" and "I need to
        // fix the cookie banner before the launch" were both refused, and not one of them
        // was needed by any of the 23 junk rows. What is left is chrome that no message
        // ever contains.
        let furniture = ["official site", "sign up now", "watch now", "shop now",
                         "click here", "all rights reserved"]
        let lower = t.lowercased()
        if furniture.contains(where: lower.contains) { return true }

        return false
    }

    /// Words that only a social timeline renders around a post.
    ///
    /// A closed list for the same reason `technicalIdentifiers` is one: "likes" and
    /// "replies" are ordinary English, and nothing structural separates a counter from a
    /// verb. They only count when a handle sits in the same line, which is what makes the
    /// pair a post header rather than a sentence.
    static let timelineWords: Set<String> = [
        "followers", "unfollow", "repost", "reposts", "reposted", "retweet", "retweets",
        "retweeted", "replies", "likes", "liked", "views", "verified",
    ]

    /// Whether a segment carries the furniture of a social timeline.
    ///
    /// A timeline is a wall of other people's sentences, and they are first-person
    /// sentences, so the words alone can never say whose they are. What can say it is
    /// everything rendered *around* the post: the author's handle, the Follow button,
    /// the engagement counts, the timestamp footer, all of which land in the same
    /// captured line as the post itself.
    ///
    /// This is the worst class of false memory, because it invents an obligation. Memoir showed
    /// "i will tell my kids that arden built this in a cave with a box of scraps" as an OPEN
    /// COMMITMENT: a stranger's joke on X, presented to the user as something they owed. The
    /// words are first person and the promise is real; it just is not theirs.
    static func carriesTimelineFurniture(_ segment: String) -> Bool {
        let words = segment.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        // "5/30/26, 8:01 PM" is the footer a post carries and a message never does. All
        // three parts are required: a bare date, or a bare time, is just a date or a time.
        for i in words.indices where i + 2 < words.count {
            guard Self.isSlashDate(Self.trimPunctuation(words[i])),
                  Self.isClockTime(Self.trimPunctuation(words[i + 1]))
            else { continue }
            let meridiem = Self.trimPunctuation(words[i + 2]).lowercased()
            if meridiem == "am" || meridiem == "pm" { return true }
        }

        // Chrome no message ever contains, whoever wrote the post.
        let lower = segment.lowercased()
        let chrome = ["show this thread", "view replies", "view more replies",
                      "show more replies", "translate post", "quote post"]
        if chrome.contains(where: lower.contains) { return true }

        // A handle plus a timeline verb. Either alone is ordinary work: "@marco can you
        // review this by Friday" is a genuine request, and "I'll follow up tomorrow" is a
        // genuine promise. Together they are a post header.
        guard words.contains(where: Self.isSocialHandle) else { return false }
        for (i, word) in words.enumerated() {
            let token = Self.trimPunctuation(word).lowercased()
            if token == "follow" {
                let next = i + 1 < words.count ? Self.trimPunctuation(words[i + 1]).lowercased() : ""
                if next != "up" { return true }
                continue
            }
            if Self.timelineWords.contains(token) { return true }
        }
        return false
    }

    /// GitHub's own interface, flattened into a line of text.
    ///
    /// A closed list for the same reason `timelineWords` is one, and a deliberately high
    /// bar: every item is also ordinary developer work. "Can you clone the repo and update
    /// the readme before standup?" is a real request and reaches two of them, so three are
    /// required before a line counts as a rendered page rather than a sentence.
    static let codeHostChrome: [String] = [
        "go to file", "add file", "folders and files", "latest commit", "code owners",
        "branch", "tags", "repositor", "commits", "pull requests", "contributors",
        "watchers", "forks", "readme", "clone",
    ]

    /// Sites whose name a page title carries as its last breadcrumb.
    static let developerSiteBreadcrumbs: [String] = [
        "ask different", "stack overflow", "stack exchange", "super user", "ask ubuntu",
        "server fault", "github", "gitlab", "bitbucket", "hacker news", "reddit",
    ]

    /// Whether a segment is a code-hosting page rather than a message.
    ///
    /// "main branch 1 Branch 2 Tags Go to file Add file Add file Code Folders and files
    /// Folders and files Reposit" was an open commitment. It is a repository page with its
    /// buttons flattened into one line: nobody wrote it and there is nothing in it to do.
    /// So was "macos - The status menu/icon is/are missing in menu bar on M2 MacBook Air due
    /// to notch - Ask Different Ap", where the whole deadline is the preposition in "due to".
    static func carriesCodeHostChrome(_ segment: String) -> Bool {
        let lower = segment.lowercased()

        // "n1ghtjar/Afterglance: AI-powered screen memory…". A repository's heading is its
        // slug and its pitch, and the pitch is written to persuade, which is what made it
        // match in the first place.
        if let first = segment.split(whereSeparator: { $0.isWhitespace }).first,
           first.hasSuffix(":") {
            let slug = first.dropLast()
            if slug.contains("/"), slug.allSatisfy({ $0.isLetter || $0.isNumber || "/_.-".contains($0) }) {
                // Unless a to-do follows it. "src/auth: fix the token refresh before the
                // demo" is a developer labelling their own line with the path they are in,
                // and it is the same shape to the character.
                //
                // The verb is read as a whole word rather than through
                // `startsWithTaskVerb`, which splits on hyphens: "expo/expo-router:
                // file-based routing…" is a repository description, and "file-based" is not
                // anybody filing anything.
                //
                // A pronoun in that same first position counts too. "src/auth: I'll fix the
                // token refresh before the demo" is a developer labelling their own promise
                // with the path they are in, and requiring an imperative refused it. A
                // repository heading is a description and never opens with "I'll": it is
                // exactly one word of evidence, in exactly one position.
                let rest = segment.dropFirst(first.count).split(whereSeparator: { $0.isWhitespace }).first
                let head = rest.map { Self.trimPunctuation(String($0)).lowercased() } ?? ""
                if !Self.taskVerbs.contains(head), !Self.actorPronouns.contains(head) { return true }
            }
        }

        // Three pieces of GitHub's vocabulary, and nobody speaking.
        //
        // The count alone was not enough: "Can you clone the repo, update the readme and cut
        // a release branch before standup?" reaches three, and so does "I'll squash the
        // commits on the release branch and open the pull requests tomorrow". Both are
        // ordinary developer work and both were refused. A flattened repository page is a
        // wall of button labels with no speaker and no addressee, which is what actually
        // separates it from a sentence about the same repository.
        if !Self.namesAParticipant(segment) {
            var hits = 0
            for token in Self.codeHostChrome where lower.contains(token) {
                hits += 1
                if hits >= 3 { return true }
            }
        }

        // The site's name in breadcrumb position. Position is the whole signal: "I'll push
        // the fix to GitHub tomorrow" says the same word inside a genuine promise.
        for separator in [" - ", " | ", " \u{00B7} ", " \u{2014} ", " \u{2013} "] {
            let parts = segment.components(separatedBy: separator)
            guard parts.count >= 2 else { continue }
            for part in parts.dropFirst() {
                let head = part.lowercased()
                if Self.developerSiteBreadcrumbs.contains(where: head.hasPrefix) { return true }
            }
        }
        return false
    }

    /// Words people SHOUT at a model.
    ///
    /// Ordinary English in lowercase, and nobody capitalises them this way in a message to a
    /// person. They are how a prompt marks a constraint it does not want ignored.
    static let shoutedInstructions: Set<String> = [
        "NOT", "DO", "DON'T", "DONT", "NEVER", "ALWAYS", "MUST", "ONLY", "BE", "MAKE",
        "KEEP", "USE", "EXACTLY", "IMPORTANT", "CRITICAL", "EVERY", "STOP", "IGNORE",
    ]

    /// Product names that only ever appear in a sentence aimed at a machine.
    ///
    /// Short on purpose. The *surface* guard already covers text captured inside an
    /// assistant, so this list only has to carry the sweep, where all that survives is a
    /// stored title.
    ///
    /// "claude code" was removed: no junk row ever matched it (the row it was added for
    /// reads "fo rclaude coce", a typo), and the user builds software with a coding agent
    /// daily, so "I'll get Claude Code to do the migration tomorrow" is a sentence they
    /// will really write. What is left is gated on the segment naming no moment, below.
    static let machineAddressees: [String] = ["coding-agent", "coding agent"]

    /// Whether the segment points at a network address rather than mentioning one.
    ///
    /// "can you qccess localhost:4611/ui.html" is a place to go. "I'll fix the localhost
    /// redirect bug before the demo tomorrow" is a bug to fix, and matching the bare word
    /// refused it. The port or the path is the difference between an address and a topic.
    static func namesAMachineAddress(_ segment: String) -> Bool {
        for token in segment.lowercased().split(whereSeparator: { $0.isWhitespace }) {
            guard token.contains("localhost") || token.contains("127.0.0.1") else { continue }
            if token.contains(":") || token.contains("/") { return true }
        }
        return false
    }

    /// Whether the segment is a prompt the user typed at an assistant.
    ///
    /// ``isConversationalAI(_:)`` catches these by their surface, which is the reliable
    /// route when the surface is known. This catches the same sentence by its own words,
    /// which is the only route left once it is sitting in the database as a row.
    ///
    /// All three of these were shown as open commitments:
    ///
    ///     "ok now let's package all this homepage new addition fo rclaude coce.
    ///      BE explicit NOT to touch the existin"
    ///     "can you qccess localhost:4611/ui.html"
    ///     ", then lets plugins turn it into a focus buddy, reminder system, tiny game,
    ///      launcher, or coding-agent ..."
    ///
    /// An instruction to a machine is discharged the moment it is sent. There is nothing
    /// left over for the user to owe.
    static func readsAsPromptToAssistant(_ segment: String) -> Bool {
        if Self.namesAMachineAddress(segment) { return true }

        // A machine's name, in a sentence that never says when. Briefing an agent is
        // discharged on send and carries no deadline; a promise about work an agent will do
        // for you carries one, and this is what keeps "I'll get the coding agent to run the
        // migration tomorrow" out of the refusal.
        let lower = segment.lowercased()
        if Self.machineAddressees.contains(where: lower.contains),
           !Self.carriesATimeExpression(segment) {
            return true
        }

        // TWO shouted constraints, not one.
        //
        // One is how a person marks a line: "IMPORTANT: I need to send the signed NDA to
        // legal by Monday" and "It MUST be filed before Friday" are both things somebody
        // typed to somebody, and both were refused. Two in the same breath is the register
        // of a prompt leaning on a model, "BE explicit NOT to touch the existin", and it
        // is what the junk row that motivated this guard actually does.
        var shouts = Set<String>()
        for word in segment.split(whereSeparator: { $0.isWhitespace }) {
            let raw = String(word)
            // Uppercase in the original, not merely uppercased by us: "not" and "Not" are
            // ordinary words, "NOT" is somebody leaning on a model.
            guard raw == raw.uppercased() else { continue }
            let token = Self.trimPunctuation(raw).uppercased()
            guard token.count >= 2, Self.shoutedInstructions.contains(token) else { continue }
            shouts.insert(token)
            if shouts.count >= 2 { return true }
        }
        return false
    }

    /// The register a product's own assistant uses to describe itself.
    ///
    /// "Let's proceed! You will be able to see the model presented in your TaxDown app." and
    /// "If you're comfortable with that (which I'll expand upon in a bit), you'll be able to
    /// see the date and any" were both filed as things the user had promised. They are a tax
    /// app's chatbot narrating its own flow. Nobody made a promise; a product described
    /// itself, in the first person, the way products do.
    /// "you'll be able to" is deliberately absent. It refused "Can you confirm you'll be
    /// able to join the Q3 review on Thursday?", which is one colleague asking another a
    /// completely ordinary question, and it was carrying nothing: both junk rows that
    /// contain it are already caught by "presented in your", "if you're comfortable",
    /// "i'll expand upon" and the "Let's proceed!" test below.
    static let productTourPhrases: [String] = [
        "if you're comfortable", "i'll expand upon", "presented in your",
        "your free trial", "tap continue", "click continue",
    ]

    /// Whether the segment is a product talking about itself.
    static func readsAsProductTour(_ segment: String) -> Bool {
        let lower = segment.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        if Self.productTourPhrases.contains(where: lower.contains) { return true }

        // "Let's proceed!" is a whole utterance, which is what makes it a flow-control
        // button rather than a sentence. "Let's proceed with the Friday deploy, I'll prepare
        // the release notes" is the same two words carrying an object, and matching them
        // bare refused it. What comes next is the entire signal.
        for opener in ["let's proceed", "lets proceed"] {
            guard let r = lower.range(of: opener) else { continue }
            let tail = lower[r.upperBound...].drop(while: { $0 == " " })
            if tail.isEmpty || "!.?".contains(tail.first!) { return true }
        }
        return false
    }

    /// Openers and sign-offs that only appear in a post written for an audience.
    ///
    /// The *announce* family and the *audience* family only. Five entries were removed after
    /// measurement ("happy to share", "excited to share", "delighted to share", "check out
    /// my", "check out our", "join me in"), because sharing a draft and looking at a build
    /// are what colleagues do all day: "I'm happy to share the draft with legal, I'll send it
    /// Monday" and "Can you check out our staging build before the demo tomorrow?" were both
    /// refused, and neither of the two junk posts needed them. Announcing is different: it
    /// presupposes a crowd.
    static let broadcastOpeners: [String] = [
        "excited to announce", "thrilled to announce", "proud to announce",
        "pleased to announce", "delighted to announce",
        "honoured to", "honored to", "taking on the role of", "in my new role",
        "link in the comments", "link in comments", "in the comments below",
        "dm me", "follow me", "grateful to everyone", "thank you to everyone",
        "catch the linkedin live",
    ]

    /// Whether the segment is somebody's announcement to a feed.
    ///
    /// "I'm incredibly excited to announce that I will be taking on the role of CEO
    /// (Director) of Uber Payments E" was an open commitment. It is a stranger's LinkedIn
    /// post. The promise inside it is real and completely genuine. It is simply somebody
    /// else's career, addressed to several thousand people who are not the user.
    ///
    /// ``carriesTimelineFurniture(_:)`` needs the chrome rendered around a post to see it.
    /// A post pasted or scrolled without its counters has none, so this reads the register
    /// instead: nobody announces a Tuesday errand to an audience.
    static func readsAsBroadcastPost(_ segment: String) -> Bool {
        let lower = segment.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return Self.broadcastOpeners.contains(where: lower.contains)
    }

    /// Pronouns that put the *user* in the sentence, as speaker rather than as audience.
    ///
    /// ``actorPronouns`` cannot be used by the two guards below, for one specific reason:
    /// it contains "lets", as the contracted "let's". The capability shape is keyed on that
    /// exact word, so a sentence would exempt itself from its own guard.
    ///
    /// Second person is deliberately absent. "Lets you browse your notes" is not a sentence
    /// with an addressee, it is the register documentation is written in, and counting "you"
    /// as a participant is what would blind the guard to the commonest shape it exists for.
    /// A genuine request to a second person opens with one of ``requestOpeners`` instead.
    static let firstPersonPronouns: Set<String> = [
        "i", "i'll", "i'm", "i've", "i'd", "me", "my", "mine", "myself",
        "we", "we'll", "we're", "we've", "our", "ours", "us",
    ]

    /// The openings that turn a sentence about a capability into a question about one.
    static let requestOpeners: [String] = [
        "can you", "could you", "would you", "will you", "can we", "could we", "please",
    ]

    /// Whether this sentence belongs to somebody rather than to a page.
    ///
    /// The exemption shared by the two guards below. A promise has a speaker, a request has
    /// an addressee, and a to-do leads with its verb; copy has none of the three.
    ///
    /// ``carriesATaskInstruction(_:)`` rather than ``startsWithTaskVerb(_:)`` on purpose: it
    /// steps over a "TODO:" before looking for the verb, so "TODO: check whether the vendor
    /// allows weekend delivery" is still recognisably a job somebody wrote down. Keyed to the
    /// bare verb alone, the marker would hide it and the guard would refuse a real task.
    static func readsAsSomebodysOwnSentence(_ segment: String) -> Bool {
        let lower = segment.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        if Self.requestOpeners.contains(where: lower.contains) { return true }
        if Self.carriesATaskInstruction(segment) { return true }
        // The marker alone is enough here, without the known verb `carriesATaskInstruction`
        // also wants. "TODO: subscribe to the status page" is plainly a job somebody wrote
        // down, and "subscribe" is deliberately absent from `taskVerbs` so that "Subscribe by
        // Friday and get 20% off" never reads as one. Without this the audience guard refused
        // the to-do and kept the advert, which is precisely backwards.
        if Self.opensWithATaskMarker(segment) { return true }
        let tokens = lower.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
        return tokens.contains { Self.firstPersonPronouns.contains(String($0)) }
    }


    /// Verbs that say what a thing makes possible, rather than what anybody will do.
    static let capabilityVerbs: Set<String> = [
        "lets", "allows", "enables", "supports", "powers",
    ]

    /// Whether the segment describes a capability instead of promising anything.
    ///
    /// "MCP lets Claude read and write vault notes directly.", "By default you paste sources
    /// in. MCP lets Claude read and write vault notes" and "Someone is building an
    /// open-source WebXR app that lets you browse your notes" were all open commitments.
    /// They are documentation. The reason they read as promises is that the capability verb
    /// takes a bare infinitive after it: "lets Claude *read*" has exactly the shape of
    /// "asks Claude to read", so a pattern looking for a future-tense verb finds one.
    ///
    /// What separates them from work is that nobody is in them. The exemptions carry the
    /// whole guard: "I'll ask if he lets us use the room" has a speaker, "Can you confirm
    /// the vendor allows weekend delivery?" has an addressee, and "Check whether the licence
    /// allows redistribution" leads with its verb. Each of those is real, and each survives.
    static func describesACapability(_ segment: String) -> Bool {
        let lower = segment.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let tokens = lower.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
        guard tokens.contains(where: { Self.capabilityVerbs.contains(String($0)) }) else { return false }
        return !Self.readsAsSomebodysOwnSentence(segment)
    }

    /// Calls to action aimed at a readership, which is nobody the user owes anything.
    static let audienceSolicitations: [String] = [
        "follow for", "subscribe for", "subscribe to", "like and subscribe",
        "hit the bell", "link in bio", "join our newsletter", "sign up for the newsletter",
    ]

    /// Whether the segment is soliciting an audience.
    ///
    /// "Follow for posts about GitHub repos, DSPy, and agents Subscribe for top posts" was
    /// an open commitment: two imperatives with no subject, which is the same shape a to-do
    /// has. The difference is who they are addressed to: a feed, not a person. The
    /// user cannot discharge them.
    ///
    /// Shares ``readsAsSomebodysOwnSentence(_:)`` for the same reason: "I'll subscribe to
    /// the alerts" and "Can you sign up for the newsletter before Friday?" are both work.
    static func solicitsAnAudience(_ segment: String) -> Bool {
        let lower = segment.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        guard Self.audienceSolicitations.contains(where: lower.contains) else { return false }
        return !Self.readsAsSomebodysOwnSentence(segment)
    }

    /// Verbs that finish a promise without leaving anything to do.
    ///
    /// "Stay connected", "be there", "keep in touch" are feelings in the shape of plans.
    /// Deliberately excludes every auxiliary that fronts real work ("have", "get", "go"),
    /// because "I'll have the fix merged by Friday" is exactly what this must not touch.
    static let sentimentVerbs: Set<String> = [
        "be", "stay", "remain", "continue", "keep", "miss", "cherish", "treasure",
        "forever", "root", "cheer", "support", "try", "hope", "love", "remember",
    ]

    /// Adverbs that stand between a promise and its verb without changing either.
    ///
    /// "definitely", "certainly", "absolutely", "probably" and "always" used to sit in
    /// `sentimentVerbs`, which is why "I'll definitely send the signed contract before
    /// Friday" read as a feeling: the guard looked at exactly one word after "I'll" and
    /// found an adverb. They belong here, to be stepped over on the way to the real verb.
    static let promiseAdverbs: Set<String> = [
        "definitely", "certainly", "absolutely", "probably", "possibly", "surely",
        "hopefully", "honestly", "personally", "gladly", "happily", "quickly",
        "just", "also", "then", "still", "always", "never", "totally", "already",
        "soon", "shortly", "immediately", "finally", "actually", "really", "likely",
        "obviously", "quietly", "simply",
    ]

    /// Whether a first-person promise commits to a feeling rather than to a task.
    ///
    /// "While my role is changing, I know I'll stay closely connected to the legal team."
    /// and "Thanks, Marco! I'll be there." were both open commitments. Grammatically they
    /// are indistinguishable from "I'll send the invoice Friday": first person, future
    /// tense, a promise. What separates them is that nothing was ever going to be finished:
    /// there is no state of the world in which "stay closely connected" is done, so a row
    /// carrying it can only ever sit in the list looking overdue.
    ///
    /// That last sentence is also the repair. The first cut read the ONE word after "I'll"
    /// and refused on it, which cost six of the 35 measured commitments, every one of them
    /// a real task wearing an adverb or an auxiliary:
    ///
    ///     "I'll definitely send the signed contract before Friday."
    ///     "I'll try to have the design review notes over by Thursday."
    ///     "I'll keep the staging environment up until the client demo on Friday."
    ///     "I'll support the launch by writing the release notes on Thursday."
    ///     "I'll be at the vendor office Thursday to sign the lease."
    ///     "I'll remember to bring the signed W-8 to the meeting tomorrow."
    ///
    /// So the guard now asks the question its own reasoning implies: is there anything here
    /// that could be DONE? A moment to do it by, or a task verb after the sentiment verb,
    /// and there is. "Stay closely connected to the legal team", "be there" and "keep in
    /// touch" have neither, and they never will.
    static func promisesOnlyASentiment(_ segment: String) -> Bool {
        let words = segment.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !($0.isLetter || $0 == "'") })
            .map(String.init)

        for (i, word) in words.enumerated() {
            var next = i + 1
            switch word {
            case "i'll", "we'll":
                break
            case "i", "we":
                guard next < words.count, words[next] == "will" || words[next] == "shall" else { continue }
                next += 1
            default:
                continue
            }
            // Step over the adverbs to reach the verb the promise is actually about.
            while next < words.count, Self.promiseAdverbs.contains(words[next]) { next += 1 }
            guard next < words.count, Self.sentimentVerbs.contains(words[next]) else { continue }
            // "I'll be sending the invoice on Friday" is real work wearing an auxiliary.
            if words[next] == "be", next + 1 < words.count, words[next + 1].hasSuffix("ing") { continue }
            // A feeling has no deadline and nothing to hand over.
            if Self.carriesATimeExpression(segment) { continue }
            if Self.carriesATaskVerb(words, from: next + 1) { continue }
            return true
        }
        return false
    }

    /// Claims a product makes about itself, and an advert's call to action.
    static let pitchPhrases: [String] = [
        "the only option", "the only app", "the only tool", "the only one that",
        "one of the most", "the most useful", "the world's",
        "this app turns", "this app is", "this app lets", "hiding a secret",
        "free forever", "no subscription", "limited time", "sign up today",
        "try it free", "money-back", "for just $", "starting at $",
    ]

    /// Whether the segment is advertising something.
    ///
    /// "Your MacBook notch is hiding a secret [emoji], This app turns it into one of the most
    /// useful features on your M" was an open commitment. It is an advert. It reads as a
    /// promise because that is what an advert is, and the second person in it ("your M") is
    /// what got it past the personal-voice floor: an advert is written *to* the reader.
    static func readsAsMarketingPitch(_ segment: String) -> Bool {
        let lower = segment.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return Self.pitchPhrases.contains(where: lower.contains)
    }

    /// Whether the segment is shouted from end to end.
    ///
    /// "SIN PERMANENCIA - TODO INCLUIDO" was an open commitment, because `TODO` is also the
    /// Spanish for "everything" and this is a phone tariff. Nobody types a whole sentence in
    /// capitals to another person; a banner does it constantly.
    static func isAllCapsBanner(_ segment: String) -> Bool {
        let letters = segment.filter(\.isLetter)
        guard letters.count >= 8, letters.allSatisfy(\.isUppercase) else { return false }
        guard segment.split(whereSeparator: { $0.isWhitespace }).count >= 2 else { return false }
        // A shouted to-do is still a to-do. "TODO: SEND THE SIGNED LEASE SCAN TO ELENA" is
        // the user's own note with caps lock on, and refusing it cost a real commitment.
        // A banner sells; it never leaves an instruction addressed to whoever wrote it.
        return !Self.carriesATaskInstruction(segment)
    }

    /// Platforms whose name gets appended to a scraped card or listing title.
    static let siteNames: Set<String> = [
        "pinterest", "fiverr", "etsy", "youtube", "instagram", "tiktok", "linkedin",
        "reddit", "facebook", "twitter", "medium", "behance", "dribbble", "upwork",
        "amazon", "ebay", "shopify", "substack", "quora", "producthunt",
    ]

    /// Prepositions that attach a site name to the sentence instead of trailing it.
    static let attachingPrepositions: Set<String> = [
        "on", "in", "to", "from", "at", "via", "with", "for", "about", "through", "onto",
    ]

    /// Whether a trailing site name marks the segment as a scraped listing.
    ///
    /// "I will design simple cute 2d cartoon characters Pinterest" was an open commitment:
    /// a freelance gig listing, where "I will …" is the seller's own sales pitch and
    /// "Pinterest" is the site the card was lifted from. The site name in final position,
    /// grammatically attached to nothing, is what marks the whole line as furniture.
    ///
    /// A preposition in front of it means the opposite: "I'll post the update on LinkedIn"
    /// is a genuine promise about a real place.
    static func carriesSiteNameFurniture(_ segment: String) -> Bool {
        let words = segment
            .split(whereSeparator: { $0.isWhitespace })
            .map { Self.trimPunctuation(String($0)).lowercased() }
        guard words.count >= 3, let last = words.last, Self.siteNames.contains(last) else { return false }
        return !Self.attachingPrepositions.contains(words[words.count - 2])
    }

    /// Memoir's own interface copy, and its own example questions.
    static let ownVocabulary: [String] = [
        "nudge", "due soon", "what's due", "whats due", "ask memoir", "open commitments",
        "memoir is listening", "listening, on this mac", "return to send", "escape to close",
        "memory browser", "what was that thing",
    ]

    /// Whether the segment is Memoir quoting itself.
    ///
    /// The sharpest lesson in this file. Three of the user's open commitments were
    ///
    ///     "a nudge, or due soon"
    ///     "a nudge, or something due soon"
    ///     "what's due tomorrow"
    ///
    /// which is this app's own interface copy and its own example question, read off its own
    /// screen while it was being built and handed back as work the user owed. An app that
    /// cannot tell its vocabulary from its user's obligations has no business keeping a
    /// to-do list, so its vocabulary is refused outright.
    ///
    /// The cost was measured and it was not acceptable. "nudge" as a bare substring refused
    /// "I'll nudge Marco about the unpaid invoice tomorrow", "due soon" refused "The domain
    /// renewal is due soon, I'll pay it before Friday", and "what's due" refused "Can you
    /// tell me what's due tomorrow on the Rossi account?": three real commitments for three
    /// pieces of vocabulary, and "nudge" is an ordinary English verb.
    ///
    /// The shape is what makes the junk junk, and it is right there in all three rows: they
    /// are fragments with nobody in them. Interface copy has no speaker and no addressee.
    /// The moment somebody is in the sentence ("I'll nudge", "can you tell me"), it is a
    /// sentence, whatever words it happens to reuse.
    static func readsAsMemoirsOwnInterface(_ segment: String) -> Bool {
        let lower = segment.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        guard Self.ownVocabulary.contains(where: lower.contains) else { return false }
        return !Self.namesAParticipant(segment)
    }

    /// Grammar words that no English sentence carries.
    ///
    /// Function words rather than content words on purpose: content is borrowed across
    /// languages constantly, grammar is not. Three distinct hits are required, because a
    /// few of these ("die", "hay", "este") are also ordinary English.
    static let nonEnglishFunctionWords: Set<String> = [
        // Italian
        "il", "lo", "la", "le", "gli", "che", "non", "di", "del", "della", "dei", "delle",
        "ma", "però", "perché", "quando", "sono", "questa", "questo", "cioè", "uno",
        "ha", "hanno", "tra", "fra", "nel", "nella", "una",
        // Spanish
        "el", "los", "las", "que", "por", "para", "con", "sin", "pero", "esta", "este",
        "más", "muy", "también", "hay",
        // French
        "les", "des", "est", "dans", "pour", "avec", "mais", "cette", "vous", "sur",
        // German
        "der", "die", "das", "und", "nicht", "ist", "mit", "auch", "eine", "einen",
        // Portuguese
        "não", "uma", "está", "isso",
    ]

    /// Whether the segment is prose in a language these rules cannot read.
    ///
    /// Two rows of an Italian newspaper article were open commitments, both on the word
    /// "due", which is English for a deadline and Italian for "two":
    ///
    ///     "La distanza tra le due colonne ha un nome: cuneo fiscale e contributivo…"
    ///     "Il cuneo ha però due facce: ciò che non arriva in busta finanzia pensioni…"
    ///
    /// Every rule in this file is a claim about English. Pointed at another language they
    /// are not weaker, they are meaningless, and the honest answer to PROSE they cannot read
    /// is to decline to judge it.
    ///
    /// Prose, and only prose. Refusing the language outright meant an Italian or German
    /// to-do could never be extracted at all, and the user works in Italian:
    ///
    ///     "TODO: mandare la fattura che ho promesso a Marco, non oltre venerdi"
    ///     "TODO: die Rechnung bis Freitag an Marco senden und das Angebot nicht vergessen"
    ///
    /// A task marker is not a claim about English. Somebody typed "TODO:" in front of a line
    /// on purpose, and that is evidence of a to-do in any language: the marker is what is
    /// being read, not the sentence. Both newspaper rows above have no marker, which is
    /// exactly what makes them prose.
    static func readsAsForeignProse(_ segment: String) -> Bool {
        if Self.opensWithATaskMarker(segment) { return false }
        let tokens = segment.lowercased().split(whereSeparator: { !($0.isLetter || $0 == "'") })
        var seen = Set<String>()
        for token in tokens where Self.nonEnglishFunctionWords.contains(String(token)) {
            seen.insert(String(token))
            if seen.count >= 3 { return true }
        }
        return false
    }

    /// Whether the text asks the reader to do something rather than reporting a promise.
    ///
    /// The plain-text twin of the `Request` rule, for the sweep, which sees a stored title
    /// and never the rules that matched it.
    static func readsAsRequest(_ segment: String) -> Bool {
        let lower = segment.lowercased()
        return ["can you", "could you", "would you"].contains(where: lower.contains)
    }

    /// Whether a named third party is the one speaking.
    ///
    /// "The Product Circle 7/13/2026 Community Chat ~Pawel : Thanks, Marco! I'll be there."
    /// became an open commitment. The "I" is Pawel's, and the only thing in the line that
    /// says so is the speaker label a chat transcript renders in front of every message.
    ///
    /// In front of *every* message, including the user's own, which is what this cost them.
    /// Slack, Discord and any group chat label both sides, so "Sofia: I'll send the invoice
    /// Friday" was thrown away with Pawel's, and a promise the user made themselves is the
    /// most valuable commitment there is. A label matching one of `ownNames` is therefore the
    /// user speaking, and their promise counts.
    ///
    /// - Parameters:
    ///   - segment: one line of captured text.
    ///   - ownNames: what the user is called. Empty is the default and takes exactly the path
    ///     this function took before names existed, so nobody who leaves it blank sees any
    ///     change: a missed commitment is a gap, an invented one is a lie about what they
    ///     promised, and that trade has not moved.
    static func isAttributedToSomeoneElse(_ segment: String, ownNames: UserNames = .none) -> Bool {
        let words = segment.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return false }

        // "~Pawel :". Community chats prefix a sender's display name with a tilde, and it
        // can appear anywhere in the line because the group and channel headers precede it.
        for (i, word) in words.enumerated() where word.hasPrefix("~") {
            let name = String(word.dropFirst())
            if name.hasSuffix(":"), Self.isCapitalisedName(String(name.dropLast())) {
                if ownNames.matches(speakerLabel: name) { continue }
                return true
            }
            guard Self.isCapitalisedName(name), i + 1 < words.count else { continue }
            if words[i + 1].hasPrefix(":") {
                if ownNames.matches(speakerLabel: name) { continue }
                return true
            }
        }

        // "Marco:" or "Elena Rossi:" at the head of the line is a chat transcript's speaker.
        // Two denylists, because a labelled line is the same shape as a spoken one and is
        // usually the user's own: "From:" and "Subject:" head a mail header, "Reminder:"
        // and "Deadline:" head a note the user wrote to themselves.
        //
        // The label can run to more than one word, so it is collected rather than tested a
        // word at a time: "Elena Rossi:" has to be compared whole against the user's names,
        // or a user called Elena would inherit every Elena in the company.
        var label: [String] = []
        for word in words.prefix(3) {
            let stem = word.hasSuffix(":") ? String(word.dropLast()) : word
            guard Self.isCapitalisedName(stem),
                  !RulePatterns.capitalisedStopwords.contains(stem),
                  !Self.lineLabels.contains(stem)
            else { break }
            label.append(stem)
            if word.hasSuffix(":") {
                // Their own name in front of their own words. Stop reading it as a speaker,
                // but keep going: a quoted third party further along the line still counts.
                if ownNames.matches(speakerLabel: label.joined(separator: " ")) { break }
                return true
            }
        }

        // "Marco said:", "Priya wrote:" are reported speech, quoted verbatim.
        for (i, word) in words.enumerated() where i + 1 < words.count {
            guard Self.isCapitalisedName(word), !RulePatterns.capitalisedStopwords.contains(word) else { continue }
            let next = words[i + 1].lowercased()
            guard next.hasSuffix(":") else { continue }
            if Self.speechVerbs.contains(String(next.dropLast())) {
                if ownNames.matches(speakerLabel: word) { continue }
                return true
            }
        }
        return false
    }

    /// The segment with the user's own speaker label removed from the front, or nil when
    /// the segment does not open with one.
    ///
    /// CF-62. The attribution guard above learned to *exempt* the user's label; commitments
    /// need one step more. "Emanuele: I'll send the invoice Friday" kept its label in the
    /// stored title, and a labelled line whose only pronoun sits inside the label had no
    /// first-person evidence left for the personal-voice floor to find. The label is the
    /// chat client saying "the user wrote this", so the honest reading is the remainder,
    /// as the first-person sentence they typed.
    ///
    /// Deliberately the same label shape the head scan in ``isAttributedToSomeoneElse``
    /// recognises (capitalised words, first three, colon attached, stopwords and line
    /// labels refused), because a stripper and a guard that disagree about what a label is
    /// would strip one line and reject its twin.
    static func strippingOwnSpeakerLabel(from segment: String, ownNames: UserNames) -> String? {
        guard !ownNames.isEmpty else { return nil }
        let words = segment.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var label: [String] = []
        for (i, word) in words.prefix(3).enumerated() {
            let stem = word.hasSuffix(":") ? String(word.dropLast()) : word
            guard Self.isCapitalisedName(stem),
                  !RulePatterns.capitalisedStopwords.contains(stem),
                  !Self.lineLabels.contains(stem)
            else { return nil }
            label.append(stem)
            guard word.hasSuffix(":") else { continue }
            guard ownNames.matches(speakerLabel: label.joined(separator: " ")),
                  i + 1 < words.count
            else { return nil }
            return words[(i + 1)...].joined(separator: " ")
        }
        return nil
    }

    /// Words that head a labelled line rather than name a speaker.
    ///
    /// "Reminder: I'll send the invoice Friday" is a note the user wrote to themselves, and
    /// it is character for character the shape of "Marco: I'll send the invoice Friday",
    /// which is not. `capitalisedStopwords` already covers the mail headers and the UI
    /// chrome; these are the ones people label their own lines with.
    /// The urgency words at the end were added after the minimal-pair test: "IMPORTANT:" in
    /// capitals is safe here only because `isCapitalisedName` rejects all-caps, so the same
    /// note typed as "Important: I need to send the signed NDA to legal by Monday" was read
    /// as a person called Important and thrown away. A label is a label in either case.
    static let lineLabels: Set<String> = [
        "Reminder", "Deadline", "Due", "Task", "Tasks", "Todo", "Action", "Actions",
        "Agenda", "Goal", "Goals", "Priority", "Owner", "Status", "Summary", "Context",
        "Background", "Decision", "Decisions", "Question", "Questions", "Answer",
        "Blocked", "Blocker", "Blockers", "Risk", "Risks", "Recap", "Plan", "Plans",
        "Idea", "Ideas", "Meeting", "Standup", "Retro", "Draft", "Milestone", "Scope",
        "Timeline", "Budget", "Issue", "Follow-up", "Followup", "Deliverable",
        "Important", "Urgent", "Critical", "Notice", "Heads-up", "Nb",
    ]

    /// Verbs that introduce someone else's words. Only counted with a colon after them, so
    /// "Marco asked how we unblock the import" stays an ordinary sentence.
    static let speechVerbs: Set<String> = [
        "said", "says", "wrote", "writes", "replied", "replies", "commented",
        "comments", "posted", "posts", "added", "notes",
    ]

    /// Pronouns that put the user in the sentence, as speaker or as addressee.
    static let personalPronouns: Set<String> = [
        "i", "i'll", "i'm", "i've", "i'd", "me", "my", "mine", "myself",
        "we", "we'll", "we're", "we've", "our", "ours", "us", "let's", "lets",
        "you", "you'll", "you're", "you've", "your", "yours", "yourself",
    ]

    /// Whether the segment reads as something the user said or was told.
    ///
    /// Deliberately generous: it is a floor, not a classifier. Its job is only to drop
    /// promise-shaped sentences that mention nobody the user is: a deadline lifted off a
    /// web page, or a third party's arrangement with a fourth.
    static func readsAsFirstPersonOrAddressed(_ segment: String) -> Bool {
        let tokens = segment.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
        return tokens.contains { Self.personalPronouns.contains(String($0)) }
    }

    /// Whether the raw line is a bullet in someone's own notes.
    ///
    /// Read from the raw line, because `MemoryText.clean` strips the marker before anything
    /// else sees it. Notes drop the subject exactly when it is the writer, so a bullet is
    /// the evidence that the missing "I" was theirs.
    static func startsWithBullet(_ raw: String) -> Bool {
        let trimmed = raw.drop(while: { $0 == " " || $0 == "\t" })
        guard let marker = trimmed.first, "-*\u{2022}\u{00B7}\u{2013}\u{2014}".contains(marker) else { return false }
        // "- item", never "-5 degrees" or "--force".
        let next = trimmed.dropFirst().first
        return next == " " || next == "\t"
    }

    /// Verbs a to-do starts with.
    ///
    /// Closed list, and deliberately excludes the marketing imperatives ("subscribe",
    /// "get", "buy", "download", "watch"), because a page that opens with one of those is
    /// selling, not reminding. Extend it when a real task goes missing.
    static let taskVerbs: Set<String> = [
        "send", "chase", "call", "email", "book", "draft", "review", "ship", "finish",
        "write", "prepare", "confirm", "check", "reply", "respond", "submit", "file",
        "renew", "cancel", "reschedule", "schedule", "remind", "pay", "sign", "scan",
        "upload", "fix", "merge", "deploy", "refactor", "rewrite", "remove", "delete",
        "create", "collect", "arrange", "organise", "organize", "sort", "publish",
        "close", "reopen", "ping", "forward", "invite", "return", "print",
        "update", "migrate", "verify", "validate", "measure", "profile", "benchmark",
    ]

    /// Whether the segment opens with a bare imperative, the way a to-do is written.
    ///
    /// The first cut of the personal-voice guard threw away "Send the signed lease scan to
    /// Elena by Friday", the user's own note, and the sentence CF-54 is built on. A to-do
    /// has no subject for the same reason a bullet has none: it is understood to be yours.
    /// The verb has to lead, so "Registration due by Friday for the Barcelona marathon"
    /// stays out.
    static func startsWithTaskVerb(_ segment: String) -> Bool {
        guard let first = segment.split(whereSeparator: { !($0.isLetter || $0 == "'") }).first else {
            return false
        }
        return Self.taskVerbs.contains(first.lowercased())
    }

    /// Trims surrounding punctuation from a whitespace-delimited token, keeping the leading
    /// `@` and `~` that carry meaning on a timeline.
    static func trimPunctuation(_ word: String) -> String {
        var out = Substring(word)
        while let f = out.first, !(f.isLetter || f.isNumber || f == "@" || f == "~") { out = out.dropFirst() }
        while let l = out.last, !(l.isLetter || l.isNumber) { out = out.dropLast() }
        return String(out)
    }

    /// `5/30/26`: a numeric date in the form a post footer uses.
    static func isSlashDate(_ token: String) -> Bool {
        let parts = token.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isNumber) }
    }

    /// `8:01`: a clock time.
    static func isClockTime(_ token: String) -> Bool {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// `@0xquillvox`: an at-prefixed screen name. Digits are allowed anywhere, unlike the
    /// `mention` pattern, because this only has to recognise the handle, not name a person.
    static func isSocialHandle(_ word: String) -> Bool {
        let token = Self.trimPunctuation(word)
        guard token.hasPrefix("@") else { return false }
        let handle = token.dropFirst()
        guard handle.count >= 2, handle.count <= 32 else { return false }
        return handle.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
    }

    /// A single capitalised word that could be a first name: "Pawel", "O'Neill", "Jean-Luc".
    ///
    /// Rest-must-be-lowercase is what keeps "TODO:" and "ACME:" out, and they are exactly
    /// the shapes that would otherwise read as a speaker label.
    static func isCapitalisedName(_ word: String) -> Bool {
        guard word.count >= 2, word.count <= 24, word.first?.isUppercase == true else { return false }
        return word.dropFirst().allSatisfy { $0.isLowercase || $0 == "'" || $0 == "\u{2019}" || $0 == "-" }
    }

    /// CSS properties and values. They arrive hyphenated, which is what let them clear the
    /// "a repository name joins its words with a hyphen" test in `isPlausibleSlug`.
    static let styleTokens: Set<String> = [
        "border-radius", "border-box", "box-shadow", "drop-shadow", "text-shadow",
        "font-family", "font-weight", "font-size", "font-style", "line-height",
        "letter-spacing", "text-align", "text-transform", "sans-serif", "monospace",
        "flex-start", "flex-end", "space-between", "space-around", "min-width",
        "max-width", "min-height", "max-height", "background-color", "object-fit",
        "z-index", "border-width", "stroke-width", "fill-rule",
    ]

    /// Adjectives that describe how a thing should look. On their own they are ordinary
    /// words; a slash between two of them is a designer weighing options.
    static let styleAdjectives: Set<String> = [
        "gentler", "softer", "harder", "bolder", "lighter", "darker", "warmer", "cooler",
        "rounder", "sharper", "cleaner", "simpler", "denser", "looser", "tighter",
        "hand-drawn", "hand-written", "hand-made", "single-stroke", "off-white",
        "high-contrast", "low-contrast", "rounded", "squared", "muted", "desaturated",
        "saturated", "minimal", "minimalist", "playful", "serious", "sketchy", "sketched",
        "outline", "outlined", "filled", "flat", "glossy", "matte", "subtle", "bold",
        "italic", "modern", "retro", "vintage", "organic", "geometric", "angular",
        "curved", "textured", "smooth", "grainy", "hand", "drawn", "written", "stroke",
    ]

    /// Whether a would-be project title is really design vocabulary.
    ///
    /// "gentler/hand-drawn" was filed as a PROJECT. It is two adjectives from a note about
    /// how an icon should look, and it survived every slug guard already in place: the
    /// prose test only fires when NEITHER side is hyphenated, and "hand-drawn" is. A style
    /// token names a look, never a piece of work.
    static func looksLikeStyleToken(_ title: String) -> Bool {
        let parts = title.lowercased().split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return false }
        // One side is enough for a CSS token: "border-radius" is nobody's repository.
        if parts.contains(where: { Self.styleTokens.contains($0) }) { return true }
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            Self.styleAdjectives.contains(part)
                || part.split(separator: "-").allSatisfy { Self.styleAdjectives.contains(String($0)) }
        }
    }

    /// Whether an @-token is code syntax rather than someone's name.
    ///
    /// Deliberately errs toward rejecting. A missed mention costs one entity; a false one
    /// puts a macro in the list of people you spoke to, which is the kind of wrongness that
    /// makes the whole memory feel untrustworthy.
    static func isCodeHandle(_ handle: String) -> Bool {
        // A domain, not a handle: "@northvale.co", "@example.com".
        if let dot = handle.lastIndex(of: "."), handle.distance(from: dot, to: handle.endIndex) - 1 >= 2,
           handle[handle.index(after: dot)...].allSatisfy({ $0.isLetter }) {
            return true
        }
        // UpperCamelCase is a type or macro, never a username: @Generable, @MainActor.
        if let first = handle.first, first.isUppercase,
           handle.dropFirst().contains(where: { $0.isUppercase }) || handle.count > 4,
           !handle.contains(where: { $0 == "_" || $0 == "-" || $0 == "." }) {
            return true
        }
        // Known language and framework attributes, which recur constantly on a dev screen.
        let known: Set<String> = [
            "generable", "guide", "mainactor", "available", "objc", "escaping", "sendable",
            "published", "state", "binding", "environment", "observable", "test", "suite",
            "discardableresult", "inlinable", "testable", "unchecked", "autoclosure",
            "param", "returns", "throws", "media", "import", "override", "property",
            "interface", "component", "injectable", "input", "output", "nullable",
        ]
        return known.contains(handle.lowercased())
    }

    // MARK: - Projects

    private func extractProjects(
        capture: CaptureEvent,
        text: String,
        ns: NSString,
        index: SegmentIndex,
        patterns: RulePatterns,
        into builder: inout ExtractionBuilder
    ) {
        let full = NSRange(location: 0, length: ns.length)

        for m in patterns.ticket.matches(in: text, options: [], range: full) where m.numberOfRanges > 1 {
            let key = ns.substring(with: m.range(at: 1)).uppercased()
            guard let dash = key.firstIndex(of: "-") else { continue }
            // A ticket key and a codec name are the same shape: MPEG-4 and ACME-412 are
            // indistinguishable by pattern, and tightening the regex only caught UTF-8 as
            // well. The difference is not structural, it is vocabulary, so it needs a list.
            guard !Self.technicalIdentifiers.contains(String(key[key.startIndex..<dash])) else { continue }
            let prefix = String(key[key.startIndex..<dash])
            guard !RulePatterns.ticketPrefixDenylist.contains(prefix) else { continue }
            builder.add(
                kind: .project,
                title: key,
                detail: "Ticket key seen in \(capture.appName)",
                confidence: 0.7,
                capture: capture,
                snippet: index.snippet(for: m.range.location, in: ns)
            )
        }

        for m in patterns.repoURL.matches(in: text, options: [], range: full) where m.numberOfRanges > 2 {
            let owner = ns.substring(with: m.range(at: 1))
            let repo = ns.substring(with: m.range(at: 2))
            guard !owner.isEmpty, !repo.isEmpty else { continue }
            builder.add(
                kind: .project,
                title: "\(owner)/\(repo)",
                detail: "Repository",
                confidence: 0.7,
                capture: capture,
                snippet: index.snippet(for: m.range.location, in: ns)
            )
        }

        for m in patterns.repoSlug.matches(in: text, options: [], range: full) where m.numberOfRanges > 2 {
            let owner = ns.substring(with: m.range(at: 1))
            let repo = ns.substring(with: m.range(at: 2))
            guard RulePatterns.isPlausibleSlug(owner: owner, repo: repo) else { continue }
            builder.add(
                kind: .project,
                title: "\(owner)/\(repo)",
                detail: "Repository style name seen in \(capture.appName)",
                confidence: 0.45,
                capture: capture,
                snippet: index.snippet(for: m.range.location, in: ns)
            )
        }
    }

    // MARK: - Threads

    private func extractThreads(
        capture: CaptureEvent,
        text: String,
        ns: NSString,
        index: SegmentIndex,
        patterns: RulePatterns,
        into builder: inout ExtractionBuilder
    ) {
        let full = NSRange(location: 0, length: ns.length)

        for m in patterns.subject.matches(in: text, options: [], range: full) where m.numberOfRanges > 1 {
            let subject = RulePatterns.stripReplyPrefixes(ns.substring(with: m.range(at: 1)))
            guard subject.count >= 4, subject.split(separator: " ").count >= 2 else { continue }
            builder.add(
                kind: .thread,
                title: MemoryText.truncate(subject, max: 120),
                detail: "Subject line in \(capture.appName)",
                confidence: 0.6,
                capture: capture,
                snippet: index.snippet(for: m.range.location, in: ns)
            )
        }

        for m in patterns.channel.matches(in: text, options: [], range: full) where m.numberOfRanges > 1 {
            let channel = ns.substring(with: m.range(at: 1))
            guard channel.count >= 3, !RulePatterns.channelDenylist.contains(channel.lowercased()) else { continue }
            builder.add(
                kind: .thread,
                title: "#\(channel)",
                detail: "Channel in \(capture.appName)",
                confidence: 0.55,
                capture: capture,
                snippet: index.snippet(for: m.range.location, in: ns)
            )
        }
    }

    /// True when an already-stored entity would be refused by today's guards.
    ///
    /// The same judgements the extractor makes at write time, applied to a title that was
    /// written before those judgements existed. Kept next to the guards deliberately: if one
    /// of them changes, this changes with it, and a sweep that disagreed with the extractor
    /// would be its own bug.
    ///
    /// One judgement is deliberately **not** replayed here: the personal-voice floor that
    /// makes the extractor demand a pronoun, a bullet or a leading task verb. A stored title
    /// has been through `MemoryText.clean`, which strips the bullet that qualified it, so
    /// replaying the floor would retire the user's own standup notes: "Finishing the
    /// migration script, will hand it over by Thursday" has no pronoun left to find. The
    /// sweep only ever retires text a *named* guard recognises.
    ///
    /// `ownNames` defaults to the installed identity rather than to nothing for the same
    /// reason: once the extractor is allowed to keep "Sofia: I'll send the invoice Friday",
    /// a sweep that did not know who Sofia is would delete it again on its next run. The
    /// extractor and the sweep have to agree about who the user is, or they fight.
    public static func isJunkEntity(_ entity: Entity, ownNames: UserNames = .current) -> Bool {
        let title = entity.title
        switch entity.kind {
        case .commitment:
            if readsAsSomebodyElsesWords(title) { return true }
            // The same exemption the extractor makes, for the same reason: a speaker label
            // disqualifies a PROMISE, not a question. "Marco: can you drop the migration
            // notes before the review?" is stored on purpose, and a sweep that read the
            // label the other way would delete live work every time it ran.
            if !readsAsRequest(title), isAttributedToSomeoneElse(title, ownNames: ownNames) { return true }
            return false
        case .project:
            return looksLikeStyleToken(title)
        case .person:
            // The same test the extractor applies before writing one (CF-89).
            //
            // Adding it there and not here is the mistake this file has now made three
            // times: a guard only ever protects what has not been written yet, and "Vercel
            // Inc" was already a person at 99% confidence with 24 mentions behind it. The
            // extractor stopped making new ones and `who_is` went on answering about the
            // old one as though it were a colleague.
            return !RulePatterns.isPlausiblePersonName(title)
        default:
            return false
        }
    }
}

// MARK: - The user's own names

/// What the user is called in the apps they read.
///
/// A list, never one string: people are labelled differently in different places, a full
/// name in Slack, a handle in Discord, a first name in iMessage, and only the user knows
/// which. Empty by default, and empty has to behave exactly as the speaker-label guard did
/// before this type existed. Nobody who never fills it in may see a single entity change.
///
/// The type lives here rather than in the app's config because MemoirKit cannot see the app at
/// all, and the guard that needs the names is in this file. The app writes them to
/// `config.json` and hands them over through ``install(_:)``.
public struct UserNames: Sendable, Equatable {

    /// Nobody. Every speaker label is somebody else's, which is where this started.
    public static let none = UserNames([])

    /// What the user typed, in their own capitalisation, for round-tripping to the config
    /// file and back into the field they typed it in.
    public let entered: [String]

    /// Each name reduced to lowercase, accent-free words. Every comparison happens on these
    /// and nowhere else.
    private let words: [[String]]

    /// Builds a set of names, dropping blanks and duplicates.
    ///
    /// Duplicates are compared after normalisation, so "Sofia" and "sofia " are one name.
    public init(_ names: [String]) {
        var entered: [String] = []
        var words: [[String]] = []
        for name in names {
            let parts = Self.tokens(name)
            guard !parts.isEmpty, !words.contains(parts) else { continue }
            entered.append(name.trimmingCharacters(in: .whitespacesAndNewlines))
            words.append(parts)
        }
        self.entered = entered
        self.words = words
    }

    /// True when the user has given no usable name at all.
    public var isEmpty: Bool { words.isEmpty }

    /// Whether a chat client's speaker label names the user.
    ///
    /// Case and accents are folded: a display name arrives however the client renders it, and
    /// nobody retypes "Bosković" with the diacritic when asked what they are called.
    ///
    /// A trailing surname is tolerated in either direction, because the same person is
    /// "Sofia" in one app and "Sofia Marchetti" in the next. Words are compared whole and in
    /// order, never by character prefix, which is what stops a user called "Marc" from
    /// inheriting every promise Marco makes.
    ///
    /// The cost of that tolerance: a user who enters only "Sofia" also claims Sofia Bianchi's
    /// lines, because a first name genuinely cannot tell two people apart. Refusing to
    /// tolerate the surname would be worse, since it would drop the user's own messages in
    /// every client that renders one. The onboarding field opens pre-filled with the account's
    /// full name for exactly this reason.
    public func matches(speakerLabel label: String) -> Bool {
        guard !words.isEmpty else { return false }
        let candidate = Self.tokens(label)
        guard !candidate.isEmpty else { return false }
        return words.contains { Self.leads($0, candidate) || Self.leads(candidate, $0) }
    }

    /// Whether `a` is the opening run of words of `b`, or the whole of it.
    private static func leads(_ a: [String], _ b: [String]) -> Bool {
        a.count <= b.count && zip(a, b).allSatisfy { $0 == $1 }
    }

    /// Lowercased, accent-folded words. Everything that is not a letter or a digit separates,
    /// so "Marco:", "~Marco" and "marco" reduce to the same token, and the handle
    /// "sofia.marchetti" reduces to the same two words as the display name it was made from.
    private static func tokens(_ raw: String) -> [String] {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    // MARK: The value in force for this process

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = UserNames.none

    /// The names in force right now, or ``none`` when nothing has installed any.
    public static var current: UserNames { lock.withLock { installed } }

    /// Publishes the user's names for the whole process.
    ///
    /// Shared mutable state, deliberately, and the only piece in this file. The extractor is
    /// built once at launch and lives for the rest of the session, while the answer to "what
    /// do people call you" arrives afterwards, from an onboarding window running alongside a
    /// pipeline that has already started. The alternative is a name that does nothing until
    /// the user quits and reopens Memoir, which is indistinguishable from a field that was
    /// ignored.
    ///
    /// Nothing installs anything in the test suite, so every test that does not ask for names
    /// reads ``none`` and sees the behaviour that shipped before this existed.
    public static func install(_ names: UserNames) {
        lock.withLock { installed = names }
    }
}

// MARK: - Compiled patterns

/// Every regular expression the rule extractor uses, compiled once per pass.
///
/// `NSRegularExpression` is not `Sendable`, so this type is created inside the
/// extraction call rather than stored on the extractor.
struct RulePatterns {

    /// A commitment trigger and how much it is trusted.
    struct CommitmentRule {
        let regex: NSRegularExpression
        let confidence: Double
        let label: String
    }

    let commitments: [CommitmentRule]
    let decision: NSRegularExpression
    let mention: NSRegularExpression
    let greeting: NSRegularExpression
    let thanks: NSRegularExpression
    let header: NSRegularExpression
    let ticket: NSRegularExpression
    let repoURL: NSRegularExpression
    let repoSlug: NSRegularExpression
    let subject: NSRegularExpression
    let channel: NSRegularExpression
    let properNoun: NSRegularExpression

    init() {
        func re(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
            // Every pattern here is a literal checked at build time. The fallback keeps
            // the extractor alive rather than crashing a background consolidation.
            (try? NSRegularExpression(pattern: pattern, options: options))
                ?? (try! NSRegularExpression(pattern: "(?!)", options: []))
        }

        commitments = [
            CommitmentRule(
                regex: re("\\b(?:i['\u{2019}]ll|i will|i'?m going to|i am going to|i shall)\\b"),
                confidence: 0.7, label: "Commitment"
            ),
            CommitmentRule(
                regex: re("\\b(?:can|could|would) you\\b"),
                confidence: 0.5, label: "Request"
            ),
            CommitmentRule(
                regex: re("\\blet['\u{2019}]?s\\b"),
                confidence: 0.45, label: "Proposal"
            ),
            CommitmentRule(
                regex: re("\\bTODO\\b|\\bto-?do\\s*:", []),
                confidence: 0.75, label: "TODO"
            ),
            CommitmentRule(
                regex: re("\\baction item"),
                confidence: 0.75, label: "Action item"
            ),
            // An unticked checkbox is the least ambiguous task marker there is: someone drew
            // a box specifically so they could tick it later. A ticked one is finished work
            // and must not match. Read after `MemoryText.clean`, which has already removed
            // the list bullet in front of it.
            CommitmentRule(
                regex: re("^\\[\\s*\\]\\s*\\S", []),
                confidence: 0.8, label: "Task box"
            ),
            // First-person obligation. "I'll" covers what the user offered to do; this
            // covers what they say they are on the hook for, which is the same commitment
            // written from the other side. The subject is required, so a page's "you'll
            // have to renew before Friday" stays out.
            CommitmentRule(
                regex: re("\\b(?:i|we)\\s+(?:need|have|had)\\s+to\\b|\\bi\\s+must\\b|\\bi['\u{2019}]ve\\s+got\\s+to\\b"),
                confidence: 0.65, label: "Commitment"
            ),
            // "due" needs a date behind it, not just a word.
            //
            // The old rule accepted anything at all after "due", which made a preposition
            // into a deadline ("…missing in menu bar due to notch"), an adverb into one
            // ("a nudge, or due soon", Memoir's own interface copy), and, twice, the Italian
            // for "two" ("le due colonne", "due facce", a newspaper article).
            //
            // Two forms were missing from the first cut and cost two real deadlines:
            // "Signed contract due at 5pm on Friday" (the preposition "at" was not in the
            // list) and "Q3 taxes due in two weeks" (a relative interval is a date too).
            // Neither re-admits "due to": "to" is not a preposition here, and "to notch"
            // does not spell a month.
            CommitmentRule(
                regex: re(
                    "\\bdue\\s*(?:on|by|at|date)?\\s*:?\\s*(?:the\\s+)?"
                        + "(?:today|tonight|tomorrow|yesterday|next\\s|this\\s|end\\s+of|eod|eow"
                        + "|mon|tue|wed|thur|thu|fri|sat|sun"
                        + "|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|\\d"
                        + "|in\\s+(?:an?|one|two|three|four|five|six|seven|eight|nine|ten|a\\s+few|\\d+)"
                        + "\\s+(?:hour|day|week|month|working\\s+day|business\\s+day))"
                ),
                confidence: 0.65, label: "Due"
            ),
            CommitmentRule(
                regex: re("\\bby\\s+(?:mon|tues?|weds?|thur?s?|fri|sat|sun|today|tonight|tomorrow|next week|eod|eow|the end of|end of)"),
                confidence: 0.6, label: "Deadline"
            ),
            CommitmentRule(
                regex: re("\\bbefore\\s+(?:the\\s+)?(?:call|meeting|standup|stand-up|demo|review|launch|deadline|sync|retro|release|deploy|interview|session|workshop)"),
                confidence: 0.6, label: "Deadline"
            ),
            CommitmentRule(
                regex: re("\\bdeadline\\b"),
                confidence: 0.6, label: "Deadline"
            ),
        ]

        decision = re("\\b(?:we (?:have )?decided|we've decided|decision\\s*:|we agreed|agreed to|we are going with|we're going with|going with)\\b")
        mention = re("(?<![A-Za-z0-9_@.])@([A-Za-z][A-Za-z0-9._-]{1,30})", [])
        greeting = re("\\b(?:hi|hey|hello|dear|morning)\\b[,!\\s]+([A-Z][\\p{Ll}'\u{2019}-]{1,20}(?:\\s+[A-Z][\\p{Ll}'\u{2019}-]{1,20})?)", [])
        thanks = re("\\b(?:[Tt]hanks|[Tt]hank you|[Tt]hx|[Cc]heers)\\b[,!\\s]+([A-Z][\\p{Ll}'\u{2019}-]{1,20})", [])
        // Horizontal whitespace only. `\s` would match the newline at the end of the value
        // and swallow the *next* header's field name into the name, turning
        // "From: Elena Rossi\nTo: Marco Bianchi" into the person "Elena Rossi To" and
        // hiding Marco entirely. Header values never wrap in the text we capture.
        header = re("(?m)^[ \\t]*(From|To|Cc|CC|Bcc|Reporter|Assignee|Author)[ \\t]*:[ \\t]*([A-Z][\\p{L}'\u{2019}.-]+(?:[ \\t]+[A-Z][\\p{L}'\u{2019}.-]+){0,2})", [])
        ticket = re("(?<![A-Za-z0-9-])([A-Z][A-Z0-9]{1,9}-\\d{1,6})(?![A-Za-z0-9-])", [])
        repoURL = re("(?:github|gitlab|bitbucket)\\.com/([A-Za-z0-9_.-]{2,39})/([A-Za-z0-9_.-]{2,60})")
        repoSlug = re("(?<![\\w/.@-])([a-z][a-z0-9_.-]{2,30})/([a-z][a-z0-9_.-]{2,30})(?![\\w/.-])", [])
        subject = re("(?m)^\\s*(?:subject|re|fwd|fw)\\s*:\\s*(.{4,140})$")
        channel = re("(?<![\\w#/])#([A-Za-z][A-Za-z0-9_-]{2,40})\\b", [])
        properNoun = re("\\b[A-Z][\\p{Ll}][\\p{Ll}'\u{2019}-]{1,22}\\b", [])
    }

    // MARK: Filters

    /// Ticket-shaped strings that are never project keys.
    static let ticketPrefixDenylist: Set<String> = [
        "COVID", "ISO", "UTF", "RFC", "IPV", "SHA", "MD", "AES", "RSA", "HTTP", "HTTPS",
        "GPT", "CVE", "USB", "PDF", "MP", "H", "X", "S", "A", "B", "C", "T",
    ]

    /// Channel-shaped strings that are almost always hashtags or markup.
    static let channelDenylist: Set<String> = [
        "include", "define", "ifdef", "endif", "pragma", "import", "todo", "swift", "hashtag",
    ]

    /// Capitalised words that are never people or projects: sentence starters, UI chrome,
    /// weekday and month names.
    static let capitalisedStopwords: Set<String> = [
        "The", "This", "That", "These", "Those", "There", "Their", "They", "Them", "Then",
        "Than", "Thus", "When", "What", "Where", "Which", "While", "Who", "Whom", "Whose",
        "Why", "How", "With", "Will", "Would", "Could", "Should", "Shall", "You", "Your",
        "Yours", "Our", "Ours", "His", "Her", "Hers", "Him", "She", "And", "But", "For",
        "From", "Not", "Now", "Here", "Have", "Has", "Had", "Been", "Being", "Are", "Was",
        "Were", "Yes", "Please", "Thanks", "Thank", "Hi", "Hey", "Hello", "Dear", "Sent",
        "Subject", "Reply", "Forward", "Inbox", "Search", "Settings", "Menu", "File", "Edit",
        "View", "Window", "Help", "Open", "Close", "Save", "New", "All", "Today", "Tomorrow",
        "Yesterday", "Tonight", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday",
        "Saturday", "Sunday", "January", "February", "March", "April", "June", "July",
        "August", "September", "October", "November", "December", "Also", "Just", "Let",
        "Lets", "Can", "Did", "Does", "Get", "Got", "Make", "Made", "Need", "Want", "Like",
        "Look", "See", "Some", "Any", "One", "Two", "Three", "Add", "Set", "Use", "Try",
        "Run", "Send", "Show", "Hide", "Next", "Back", "Done", "More", "Less", "Best",
        "Good", "Great", "Sure", "Okay", "Well", "Very", "Only", "Even", "Still", "Both",
        "Each", "Most", "Much", "Many", "Every", "Other", "Same", "Such", "Type", "Name",
        "Email", "Message", "Note", "Notes", "Page", "Home", "About", "Cancel", "Delete",
        "Update", "Create", "Select", "Copy", "Paste", "Undo", "Redo", "Print", "Export",
        "Import", "Share", "Download", "Upload", "Sign", "Log", "Password", "Username",
        "Error", "Warning", "Info", "Details", "Options", "Preferences", "Account", "Profile",
        "Dashboard", "Loading", "Search", "Filter", "Sort", "Apply", "Reset", "Continue",
        "Submit", "Confirm", "Accept", "Decline", "Skip", "Start", "Stop", "Pause", "Play",
        // A social timeline's own furniture. "Quote Machina Verified" and "Clearer
        // Responses Trending" were both people at 55% confidence: the words around a post
        // repeat on every post, which is what this path mistakes for a name recurring.
        // None of these is ever part of somebody's name.
        "Verified", "Trending", "Quote", "Retweet", "Repost", "Reposts", "Following",
        "Followers", "Replies", "Likes", "Views", "Subscribe", "Subscribed", "Premium",
        "Sponsored", "Promoted", "Suggested", "Recommended", "Responses", "Notifications",
        "Bookmarks", "Explore", "Feed", "Timeline", "Stories", "Shorts", "Live",
    ]

    /// Words that suggest the capitalised phrase around them names a project.
    static let projectCueWords: Set<String> = [
        "project", "sprint", "release", "migration", "platform", "dashboard", "launch",
        "roadmap", "initiative", "redesign", "beta", "alpha", "app", "service", "api",
        "portal", "pipeline", "rollout", "integration", "engine", "program", "phase",
        "epic", "feature", "backend", "frontend", "website", "server", "client", "mobile",
        "studio", "kit", "suite", "console", "tracker", "sync", "milestone", "campaign",
        "rewrite", "refactor", "prototype", "proposal", "audit", "rebrand",
    ]

    /// Words that, next to a capitalised phrase, suggest it names a person.
    static let personCueBefore: Set<String> = [
        "hi", "hey", "hello", "dear", "thanks", "thank", "cheers", "from", "to", "cc",
        "with", "asked", "ask", "told", "met", "meeting", "call", "spoke", "ping", "pinged",
        "and", "for",
    ]

    /// Verbs that, immediately after a capitalised phrase, suggest it names a person.
    static let personCueAfter: Set<String> = [
        "said", "says", "asked", "asks", "wrote", "writes", "mentioned", "replied",
        "thinks", "wants", "needs", "will", "sent", "shared", "added", "commented",
        "suggested", "confirmed", "approved", "joined", "left",
    ]

    /// Trims punctuation and possessives from a captured name.
    static func cleanName(_ raw: String) -> String {
        var name = MemoryText.clean(raw)
        while let last = name.last, !(last.isLetter || last.isNumber) { name.removeLast() }
        if name.lowercased().hasSuffix("'s") || name.lowercased().hasSuffix("\u{2019}s") {
            name = String(name.dropLast(2))
        }
        return name
    }

    /// Rejects obvious non-names: stopwords, single letters, all-caps shouting.
    /// The words a company puts after its name and a person never does.
    ///
    /// "Vercel Inc" was filed as a person, at 75% confidence, and `who_is` answered about it
    /// as though it were a colleague. It arrived the way most of them will: a bot's display
    /// name in an email header, which is exactly the pattern that is otherwise the most
    /// reliable person signal on the screen.
    ///
    /// This is a fact rather than a heuristic, which is why it sits in the plausibility test
    /// and not among the shape guards: whatever else "Acme Ltd" is, it is not somebody the
    /// user can owe an answer to.
    static let organisationSuffixes: Set<String> = [
        "inc", "inc.", "incorporated", "llc", "l.l.c.", "ltd", "ltd.", "limited", "plc",
        "corp", "corp.",
        "corporation", "gmbh", "ag", "sa", "s.a.", "sas", "srl", "s.r.l.", "spa", "s.p.a.",
        "bv", "b.v.", "nv", "n.v.", "oy", "ab", "as", "aps", "pty", "co", "co.", "company",
        "holdings", "group", "labs", "technologies", "systems", "solutions", "ventures",
        "partners", "associates", "foundation", "institute", "bot",
    ]

    static func isPlausiblePersonName(_ name: String) -> Bool {
        guard name.count >= 2, name.count <= 48 else { return false }
        guard name.rangeOfCharacter(from: .letters) != nil else { return false }
        let words = name.split(separator: " ").map(String.init)
        guard words.count <= 3 else { return false }
        for word in words where capitalisedStopwords.contains(word.capitalized) { return false }
        if name.uppercased() == name, name.count > 4 { return false }
        // Only the trailing word counts. A person really can be called Ivy Labs, and the
        // suffix is a suffix: "Labs Ivy" is not a company and should not be refused as one.
        if words.count >= 2, let last = words.last?.lowercased(),
           organisationSuffixes.contains(last) {
            return false
        }
        return true
    }

    /// Guards the bare `owner/repo` pattern against paths, fractions and phrases
    /// like "and/or" or "read/write".
    static func isPlausibleSlug(owner: String, repo: String) -> Bool {
        guard owner.count >= 3, repo.count >= 3 else { return false }

        // Design vocabulary, which the hyphen test below waves through: "hand-drawn" is
        // shaped exactly like a repository name and means nothing of the kind.
        guard !RuleExtractor.looksLikeStyleToken("\(owner)/\(repo)") else { return false }

        // A slash between two ordinary English words is usually prose, not a repository:
        // "single-stroke outline face, gentler/hand-drawn" was filed as a project purely on
        // shape. But real repos are often ordinary words too ("acme-corp/platform"), so the
        // spell checker alone is too blunt: it rejected a genuine repository.
        //
        // The separator is the better signal. Repository names lean on hyphens and
        // underscores as word joiners; prose that happens to contain a slash does not have
        // both sides shaped that way.
        if MemoryService.isOrdinaryWord(owner), MemoryService.isOrdinaryWord(repo),
           !owner.contains("-"), !owner.contains("_"),
           !repo.contains("-"), !repo.contains("_") {
            return false
        }
        let combined = owner + repo
        guard combined.contains("-") || combined.contains("_") else { return false }
        let banned: Set<String> = ["and", "or", "not", "input", "output", "read", "write", "yes", "no", "km", "he", "she", "his", "her", "w", "n"]
        if banned.contains(owner) || banned.contains(repo) { return false }
        if owner.hasSuffix(".") || repo.hasSuffix(".") { return false }
        return true
    }

    /// Removes stacked "Re:" / "Fwd:" prefixes from a subject line.
    static func stripReplyPrefixes(_ raw: String) -> String {
        var subject = MemoryText.clean(raw)
        var changed = true
        while changed {
            changed = false
            for prefix in ["re:", "fwd:", "fw:", "re :", "fwd :"] where subject.lowercased().hasPrefix(prefix) {
                subject = String(subject.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return subject
    }
}

// MARK: - Repeated proper nouns

/// Counts capitalised words and phrases across the whole batch so that names which
/// recur three or more times become entities, while one-off capitalisation (menu
/// items, sentence starts) is ignored.
struct ProperNounCounter {

    /// Everything known about one capitalised phrase in this batch.
    struct Stat {
        var display: String
        var wordCount: Int
        var count = 0
        var midSentence = 0
        var personCue = 0
        var projectCue = false
        var samples: [(capture: CaptureEvent, snippet: String)] = []
    }

    private var stats: [String: Stat] = [:]

    /// Reads one capture and folds its capitalised phrases into the running counts.
    mutating func ingest(
        capture: CaptureEvent,
        text: String,
        ns: NSString,
        index: SegmentIndex,
        patterns: RulePatterns
    ) {
        let full = NSRange(location: 0, length: ns.length)
        let matches = patterns.properNoun.matches(in: text, options: [], range: full)
        guard !matches.isEmpty else { return }

        var i = 0
        while i < matches.count {
            let start = matches[i]
            let word = ns.substring(with: start.range)
            guard !RulePatterns.capitalisedStopwords.contains(word) else { i += 1; continue }

            // Build a run of adjacent capitalised words: "Project Falcon Two".
            var run: [NSTextCheckingResult] = [start]
            var j = i + 1
            while j < matches.count, run.count < 3 {
                let previous = run[run.count - 1].range
                let next = matches[j].range
                let gap = next.location - (previous.location + previous.length)
                guard gap == 1, ns.substring(with: NSRange(location: previous.location + previous.length, length: 1)) == " " else { break }
                let nextWord = ns.substring(with: next)
                guard !RulePatterns.capitalisedStopwords.contains(nextWord) else { break }
                run.append(matches[j])
                j += 1
            }

            let runRange = NSRange(
                location: start.range.location,
                length: run[run.count - 1].range.location + run[run.count - 1].range.length - start.range.location
            )
            let phrase = ns.substring(with: runRange)
            let snippet = index.snippet(for: runRange.location, in: ns)
            record(
                phrase: phrase,
                wordCount: run.count,
                midSentence: Self.isMidSentence(ns: ns, location: runRange.location),
                personCue: Self.hasPersonCue(ns: ns, range: runRange),
                projectCue: Self.hasProjectCue(phrase: phrase),
                capture: capture,
                snippet: snippet
            )

            // Also count the single leading word, so "Sarah Chen" and a later bare
            // "Sarah" reinforce each other.
            if run.count > 1 {
                record(
                    phrase: word,
                    wordCount: 1,
                    midSentence: Self.isMidSentence(ns: ns, location: start.range.location),
                    personCue: Self.hasPersonCue(ns: ns, range: start.range),
                    projectCue: false,
                    capture: capture,
                    snippet: snippet
                )
            }

            i = max(i + 1, j)
        }
    }

    private mutating func record(
        phrase: String,
        wordCount: Int,
        midSentence: Bool,
        personCue: Bool,
        projectCue: Bool,
        capture: CaptureEvent,
        snippet: String
    ) {
        let key = MemoryText.normalizedTitle(phrase)
        guard key.count >= 3 else { return }
        var stat = stats[key] ?? Stat(display: phrase, wordCount: wordCount)
        stat.count += 1
        if midSentence { stat.midSentence += 1 }
        if personCue { stat.personCue += 1 }
        if projectCue { stat.projectCue = true }
        if stat.samples.count < 3 {
            stat.samples.append((capture, snippet))
        }
        stats[key] = stat
    }

    /// Emits the phrases that cleared the repetition threshold.
    ///
    /// Multi-word phrases become projects when they contain a project cue word,
    /// people when a person cue sits next to them, and low-confidence projects
    /// otherwise. Single words are only emitted when a person cue backs them up:
    /// a bare repeated capitalised word is too weak a signal to spend the user's
    /// attention on.
    func emit(into builder: inout ExtractionBuilder) {
        let qualifying = stats
            .filter { $0.value.count >= RuleExtractor.repetitionThreshold && $0.value.midSentence >= 1 }
            .sorted { $0.value.count > $1.value.count }
            .prefix(60)

        var phraseWords = Set<String>()
        for (_, stat) in qualifying where stat.wordCount > 1 {
            for word in MemoryText.normalizedTitle(stat.display).split(separator: " ") {
                phraseWords.insert(String(word))
            }
        }

        for (_, stat) in qualifying {
            let kind: EntityKind
            let confidence: Double
            let detail: String

            if stat.wordCount > 1 {
                if stat.projectCue {
                    kind = .project
                    confidence = 0.5
                    detail = "Recurring project name (\(stat.count) mentions)"
                } else if stat.personCue > 0 {
                    kind = .person
                    confidence = 0.55
                    detail = "Recurring name (\(stat.count) mentions)"
                } else {
                    // A repeated capitalised phrase with NO project cue is almost always
                    // browser/tab-group chrome ("Official Premium", "Prompting Method
                    // Behind", "Carta Identità Elettronica"), not a project. Repetition in
                    // page furniture is not evidence of work. Dropped for precision.
                    continue
                }
            } else {
                // Single capitalised words are NEVER promoted to people from repetition
                // alone. The cue words ("with", "from", "to") occur constantly in browser
                // and menu chrome, so this path produced Top, Bottom, Restart, Previous,
                // Desktop, Google and Barcelona as "people". Real single names arrive
                // through the explicit @mention / "Hi X" / "thanks X" / "From: X" patterns,
                // which carry actual evidence rather than mere repetition.
                _ = phraseWords
                continue
            }

            guard let sample = stat.samples.first else { continue }
            // Repetition is this path's only evidence, and an app's own name repeats beside
            // literally everything the user looks at. "Google Chrome" cleared the bar on
            // every capture ever taken.
            if kind == .person, RuleExtractor.namesTheCapturingApplication(stat.display, capture: sample.capture) {
                continue
            }
            // Repetition is this path's only evidence, and on a feed repetition is the
            // product: a trending panel repeats a name precisely because the user has no
            // relationship with it (CF-97).
            if kind == .person, stat.samples.allSatisfy({ RuleExtractor.isSocialFeed($0.capture) }) {
                continue
            }
            let id = builder.add(
                kind: kind,
                title: stat.display,
                detail: detail,
                confidence: confidence,
                capture: sample.capture,
                snippet: sample.snippet
            )
            guard let id else { continue }
            for extra in stat.samples.dropFirst() {
                builder.addProvenance(entityID: id, capture: extra.capture, field: "title", snippet: extra.snippet)
            }
        }
    }

    // MARK: Signals

    /// True when the word is not the first thing on its line or sentence, which is
    /// what separates a real proper noun from ordinary sentence capitalisation.
    static func isMidSentence(ns: NSString, location: Int) -> Bool {
        var i = location - 1
        while i >= 0 {
            let ch = ns.substring(with: NSRange(location: i, length: 1))
            if ch == "\n" || ch == "\r" { return false }
            if ch == " " || ch == "\t" { i -= 1; continue }
            if [".", "!", "?", ":", ";", "•", "-", "*", "|", ">", "(", "[", "\"", "\u{201C}"].contains(ch) { return false }
            return true
        }
        return false
    }

    /// True when a person-indicating word sits immediately before or after the phrase.
    static func hasPersonCue(ns: NSString, range: NSRange) -> Bool {
        if range.location > 0, ns.substring(with: NSRange(location: range.location - 1, length: 1)) == "@" { return true }

        let beforeStart = max(0, range.location - 24)
        if range.location > beforeStart {
            let before = ns.substring(with: NSRange(location: beforeStart, length: range.location - beforeStart))
            if let word = before.split(whereSeparator: { !$0.isLetter }).last,
               RulePatterns.personCueBefore.contains(word.lowercased()) {
                return true
            }
        }

        let afterStart = range.location + range.length
        let afterLength = min(24, ns.length - afterStart)
        if afterLength > 0 {
            let after = ns.substring(with: NSRange(location: afterStart, length: afterLength))
            if after.hasPrefix("'s") || after.hasPrefix("\u{2019}s") { return true }
            if let word = after.split(whereSeparator: { !$0.isLetter }).first,
               RulePatterns.personCueAfter.contains(word.lowercased()) {
                return true
            }
        }
        return false
    }

    /// True when the phrase itself contains a project-ish word.
    static func hasProjectCue(phrase: String) -> Bool {
        for word in phrase.lowercased().split(whereSeparator: { !$0.isLetter })
        where RulePatterns.projectCueWords.contains(String(word)) {
            return true
        }
        return false
    }
    }
