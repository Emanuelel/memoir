import Foundation

/// Rejects answers that assert things the context never said.
///
/// Small on-device models pattern-complete. Asked "what do I owe anyone" with an empty
/// commitments list and an explicit "none recorded" at the top of the context, a 3B model
/// still answered **"You owe someone $100."** Prompt instructions do not fix this; the model
/// is not disobeying so much as failing to represent the instruction at all.
///
/// So it is enforced instead of requested. Every number an answer states must literally
/// appear in the evidence it was given. A number that does not is fabricated by definition,
/// and a memory that invents figures is worse than one that says nothing.
public enum Grounding: Sendable {

    /// Numbers that carry no claim and are not worth grounding: small counts, list markers,
    /// and the ordinals a model uses to structure prose ("the first thing", "two apps").
    private static let freeNumbers: Set<String> = [
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10",
    ]

    /// Digit runs, carrying any adjacent currency marker into the token.
    ///
    /// The marker matters. "You owe someone $100" was allowed through because the page in
    /// context said "100% local, 100% private": a bare digit match found `100` and called
    /// it grounded. A monetary claim is only grounded by monetary evidence, so `$100` and
    /// `100` are deliberately different tokens.
    private static let numberPattern = try! NSRegularExpression(
        pattern: "([$€£¥]\\s?)?(\\d[\\d,.]*)\\s?(%|EUR|USD|GBP|eur|usd|gbp|dollars?|euros?|pounds?)?")

    /// Clock times, matched before bare digits so they stay one token.
    ///
    /// "16:00" was being split into `16` and `00`, and then rejected because neither half
    /// appeared in the evidence, which is both wrong in detail (a bare `00` is not a claim
    /// anyone makes) and wrong in principle: a time is a single fact. A time is grounded
    /// when that time was on the timeline, and not otherwise.
    private static let clockPattern = try! NSRegularExpression(pattern: "\\b([0-2]?\\d:[0-5]\\d)\\b")

    /// Every numeric token in a string, normalised so "1,200" and "1200" compare equal.
    static func numbers(in text: String) -> [String] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var times: [String] = []
        var masked = text
        for match in clockPattern.matches(in: text, options: [], range: range).reversed() {
            let time = (text as NSString).substring(with: match.range(at: 1))
            times.append("t|" + time)
            // Blank the time out so the digit scanner below cannot see its halves.
            masked = (masked as NSString).replacingCharacters(
                in: match.range(at: 1),
                with: String(repeating: " ", count: match.range(at: 1).length))
        }
        return times + digits(in: masked)
    }

    private static func digits(in text: String) -> [String] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return numberPattern.matches(in: text, options: [], range: range).compactMap { match in
            let digits = normalize(ns.substring(with: match.range(at: 2)))
            guard !digits.isEmpty else { return nil }
            var unit = ""
            if match.range(at: 1).location != NSNotFound {
                unit = ns.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespaces)
            } else if match.range(at: 3).location != NSNotFound {
                unit = ns.substring(with: match.range(at: 3))
                    .trimmingCharacters(in: .whitespaces).uppercased()
                if unit.hasPrefix("DOLLAR") { unit = "$" }
                if unit.hasPrefix("EURO") { unit = "EUR" }
                if unit.hasPrefix("POUND") { unit = "GBP" }
            }
            return unit.isEmpty ? digits : unit + "|" + digits
        }
    }

    private static func normalize(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: ",", with: "")
        while s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Numbers the answer asserts that the evidence does not contain.
    ///
    /// - Parameters:
    ///   - answer: what the model produced.
    ///   - evidence: the context it was given, plus the question itself: a figure the user
    ///     supplied is grounded even when the memory has never seen it.
    public static func ungroundedNumbers(in answer: String, evidence: String) -> [String] {
        let allowed = Set(numbers(in: evidence)).union(freeNumbers)
        var seen = Set<String>()
        return numbers(in: answer).filter { token in
            guard !allowed.contains(token) else { return false }
            // A year or a clock time is almost always structural rather than a claim.
            if token.count == 4, let year = Int(token), (1900...2100).contains(year) { return false }
            return seen.insert(token).inserted
        }
    }

    /// True when the answer states a figure its evidence never mentioned.
    public static func isUngrounded(answer: String, evidence: String) -> Bool {
        !ungroundedNumbers(in: answer, evidence: evidence).isEmpty
    }

    // MARK: - Invented durations

    /// Why the number guard cannot protect accounting, and what does instead.
    ///
    /// ``freeNumbers`` exempts 0–10 because that is how a model says "two things". But every
    /// duration is written in small integers, so **"2 hours and 5 minutes" tokenises to `2`
    /// and `5` and is waved straight through**. The one guard covering accounting has never
    /// been able to see a wrong duration.
    ///
    /// Measured, against a context that stated `- Claude: 2h 4m` under the literal
    /// instruction *"use these figures exactly and never estimate your own"*:
    ///
    ///     "You spent 2 hours and 5 minutes on the laptop today"   ← Claude's figure, relabelled
    ///     "You spent 1 minute on Claude"                          ← invented outright
    ///
    /// Accounting is the one category where the legitimate answers are known exactly: they
    /// were computed from session rows before the model ever ran. So the durations an answer
    /// states are checked against that table rather than against loose digits.
    struct TimeTable: Sendable {
        var perApp: [(app: String, minutes: Int)]
        /// Total tracked, which is what a duration with no app beside it must mean.
        var total: Int { perApp.reduce(0) { $0 + $1.minutes } }
    }

    /// Parses the computed time section back out of a context packet.
    ///
    /// Reads the section `MemoryService` itself writes, whose lines are `- App: 2h 4m` or
    /// `- App: 59 min`. Parsing our own output is not elegant, but it keeps the guard honest:
    /// it validates against exactly the text the model was shown, not a parallel calculation
    /// that could drift away from it.
    static func timeTable(in evidence: String) -> TimeTable? {
        guard let header = evidence.range(of: "Time today, measured from session records") else {
            return nil
        }
        var rows: [(String, Int)] = []
        for raw in evidence[header.upperBound...].split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") else {
                // The section ends at the first line that is not a row.
                if !rows.isEmpty { break } else { continue }
            }
            let body = line.dropFirst(2)
            guard let colon = body.lastIndex(of: ":") else { continue }
            let app = body[..<colon].trimmingCharacters(in: .whitespaces)
            guard let minutes = minutes(in: String(body[body.index(after: colon)...])) else { continue }
            rows.append((app, minutes))
        }
        return rows.isEmpty ? nil : TimeTable(perApp: rows)
    }

    private static let durationPattern = try! NSRegularExpression(
        pattern: "(\\d+)\\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\\b",
        options: [.caseInsensitive])

    /// Total minutes expressed by the first duration phrase in `text`, or nil.
    ///
    /// Handles "2h 4m", "2 hours and 5 minutes", "59 min" and "1 minute 43 seconds" alike,
    /// because a model will write any of them and they are the same claim.
    static func minutes(in text: String) -> Int? {
        let ns = text as NSString
        let all = durationPattern.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !all.isEmpty else { return nil }
        var total = 0
        var sawAny = false
        for m in all {
            guard let value = Int(ns.substring(with: m.range(at: 1))) else { continue }
            let unit = ns.substring(with: m.range(at: 2)).lowercased()
            if unit.hasPrefix("h") { total += value * 60 }
            else if unit.hasPrefix("m") { total += value }
            else { total += value / 60 }          // seconds contribute, but round to minutes
            sawAny = true
        }
        return sawAny ? total : nil
    }

    /// Durations an accounting answer states that the computed table does not support.
    ///
    /// Each duration is attributed by looking for an app name in the same sentence. A
    /// duration beside an app must equal that app's measured time; a bare duration is a
    /// claim about the total. One minute of tolerance absorbs the rounding in "2h 4m".
    ///
    /// - Returns: human-readable descriptions of each unsupported claim, for the log.
    public static func unsupportedDurations(in answer: String, evidence: String) -> [String] {
        guard let table = timeTable(in: evidence) else { return [] }
        var problems: [String] = []
        // Per PHRASE, not per sentence. "You spent 2h 4m in Claude and 59 min in Chrome" is
        // one sentence carrying two independent claims; summing it to 183m and blaming
        // Claude was this guard's own first bug.
        for phrase in durationPhrases(in: answer) {
            let named = nearestApp(to: phrase.range, in: answer, from: table)
            if let named {
                if abs(phrase.minutes - named.minutes) > 1 {
                    problems.append("\(named.app) \(phrase.minutes)m stated vs \(named.minutes)m measured")
                }
            } else if abs(phrase.minutes - table.total) > 1 {
                // Not attributed to an app, so it is a claim about the whole day. Letting it
                // match any single app is what allowed Claude's figure to be reported as the
                // laptop total.
                problems.append("unattributed \(phrase.minutes)m vs \(table.total)m tracked")
            }
        }
        return problems
    }

    /// Adjacent duration matches merged into single claims, with where they sit.
    ///
    /// "2 hours and 5 minutes" is one claim of 125 minutes, not a claim of 2 and a claim of
    /// 5. Matches are joined while only whitespace and joining words separate them.
    static func durationPhrases(in text: String) -> [(minutes: Int, range: NSRange)] {
        let ns = text as NSString
        let matches = durationPattern.matches(
            in: text, options: [], range: NSRange(location: 0, length: ns.length))
        var out: [(minutes: Int, range: NSRange)] = []
        for m in matches {
            guard let value = Int(ns.substring(with: m.range(at: 1))) else { continue }
            let unit = ns.substring(with: m.range(at: 2)).lowercased()
            let mins = unit.hasPrefix("h") ? value * 60 : (unit.hasPrefix("m") ? value : value / 60)
            if var last = out.last {
                let gapStart = last.range.location + last.range.length
                let gap = ns.substring(with: NSRange(location: gapStart, length: m.range.location - gapStart))
                    .trimmingCharacters(in: .whitespaces).lowercased()
                if gap.isEmpty || gap == "and" || gap == "," || gap == ", and" {
                    last.minutes += mins
                    last.range = NSRange(location: last.range.location,
                                         length: m.range.location + m.range.length - last.range.location)
                    out[out.count - 1] = last
                    continue
                }
            }
            out.append((mins, m.range))
        }
        return out
    }

    /// The app named closest to a duration, within the same clause.
    ///
    /// Proximity, not sentence membership: "2h 4m in Claude and 59 min in Chrome" needs each
    /// figure bound to the name beside it. Bounded to 40 characters either side so a name
    /// from an adjacent clause cannot vouch for the wrong figure.
    private static func nearestApp(
        to range: NSRange, in answer: String, from table: TimeTable
    ) -> (app: String, minutes: Int)? {
        let ns = answer as NSString
        let lo = max(0, range.location - 40)
        let hi = min(ns.length, range.location + range.length + 40)
        let window = ns.substring(with: NSRange(location: lo, length: hi - lo)).lowercased()
        var best: (app: String, minutes: Int)? = nil
        var bestDistance = Int.max
        for row in table.perApp where !row.app.isEmpty {
            guard let found = window.range(of: row.app.lowercased()) else { continue }
            let offset = window.distance(from: window.startIndex, to: found.lowerBound)
            let distance = abs(offset - (range.location - lo))
            if distance < bestDistance { bestDistance = distance; best = row }
        }
        return best
    }

    // MARK: - Invented URLs

    /// Domains and URLs the answer states.
    ///
    /// Matches bare domains as well as full URLs, because "you were on lumenfield.ai" is
    /// the same claim as "you were on https://lumenfield.ai".
    private static let urlPattern = try! NSRegularExpression(
        pattern: "(?:https?://)?([a-z0-9][a-z0-9-]{1,62}(?:\\.[a-z0-9-]{2,})+)",
        options: [.caseInsensitive])

    /// Every host mentioned, lowercased and stripped of scheme and "www.".
    static func hosts(in text: String) -> [String] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return urlPattern.matches(in: text, options: [], range: range).compactMap { match in
            var host = ns.substring(with: match.range(at: 1)).lowercased()
            if host.hasPrefix("www.") { host.removeFirst(4) }
            // Filenames and version strings look like hosts; require a plausible TLD.
            guard let tld = host.split(separator: ".").last, tld.count >= 2,
                  tld.allSatisfy({ $0.isLetter }) else { return nil }
            return host
        }
    }

    /// Hosts the answer asserts that never appear in the evidence.
    ///
    /// A misspelled question is the dangerous case: asked about "lmuendeild", the model
    /// answered "You were on https://lmuendeild.ai", inventing a domain by echoing the
    /// typo back as fact. The evidence is the CONTEXT ONLY for exactly this reason: a
    /// hostname the user typed is not proof the host exists.
    public static func unsupportedHosts(in answer: String, evidence: String) -> [String] {
        let known = Set(hosts(in: evidence))
        var seen = Set<String>()
        return hosts(in: answer).filter { host in
            guard !known.contains(host) else { return false }
            // A known host's subdomain or parent is still grounded.
            if known.contains(where: { $0.hasSuffix("." + host) || host.hasSuffix("." + $0) }) {
                return false
            }
            return seen.insert(host).inserted
        }
    }

    // MARK: - Invented actions

    /// Verbs that assert the user DID something, as opposed to describing what was on
    /// screen.
    ///
    /// Memoir records what was visible, never what was done. Given an Obsidian note title it
    /// has no way to know whether the user wrote it, edited it or merely read it, so when
    /// the model said "you created a note" about a note being read, and "you searched for
    /// https://motionvane.ai" about a page being visited, it was inventing the verb.
    /// A memory that misreports what you did is worse than one that says less.
    static let assertedActions: [String] = [
        "created", "wrote", "authored", "drafted", "edited", "updated", "modified",
        "deleted", "removed", "added", "saved", "renamed",
        "sent", "replied", "posted", "published", "shared", "submitted", "commented",
        "shipped", "committed", "pushed", "merged", "deployed", "released",
        "installed", "uninstalled", "bought", "purchased", "paid", "searched",
        "downloaded", "uploaded", "booked", "scheduled", "cancelled",
        "signed in", "logged in", "logged into", "signed up", "subscribed", "generated",
        // Communication is invisible to a screen reader, and inventing it is the most
        // personal kind of false memory. Asked "who called me today" the model answered
        // "someone@example.com called you today", a fabricated event about a real person,
        // assembled from an address that happened to be on screen.
        "called", "phoned", "rang", "dialed", "dialled", "messaged", "emailed", "texted",
        "spoke", "talked", "met with", "video called",
    ]

    /// Neutral alternatives the model is free to use, listed in the prompt.
    public static let observationVerbs = "was on, had open, was viewing, was reading, was looking at"

    /// Action verbs the answer asserts that the evidence never mentions.
    ///
    /// Matching is on the stem so "create/created/creating" all resolve together, and the
    /// evidence is checked for the same stem: if the screen genuinely said "Note created",
    /// reporting it is grounded.
    public static func unsupportedActions(in answer: String, evidence: String) -> [String] {
        let haystack = evidence.lowercased()
        let text = answer.lowercased()
        var found: [String] = []
        for verb in assertedActions {
            guard text.contains(verb) else { continue }
            // The verb must be ATTRIBUTED, not merely present.
            //
            // Exact-form matching was still too weak: a lone "Created" from a Finder
            // "Date Created" column grounded "you created a note" about a note that was
            // only read. Screen text is full of such words as labels and column headers.
            //
            // Memoir records what was on screen, never what was done, so an action ascribed
            // to the user needs evidence that ascribes it to the user: "you created",
            // "I sent", "created by". Bare occurrences are chrome until proven otherwise.
            let attributions = ["you \(verb)", "i \(verb)", "\(verb) by", "\(verb) on ", "have \(verb)"]
            if attributions.contains(where: haystack.contains) { continue }
            found.append(verb)
        }
        return found
    }

    // MARK: - Parroting

    /// True when the answer is just the question handed back.
    ///
    /// Small models sometimes echo the prompt verbatim: asked "ok gotcha and what about my
    /// last page visited on chrome?" the reply was that exact sentence. It is not wrong so
    /// much as empty, and it reads as broken.
    public static func isEcho(answer: String, question: String) -> Bool {
        func squash(_ s: String) -> String {
            s.lowercased()
                .filter { $0.isLetter || $0.isNumber || $0 == " " }
                .split(separator: " ")
                .joined(separator: " ")
        }
        let a = squash(answer), q = squash(question)
        guard !a.isEmpty, !q.isEmpty else { return false }
        if a == q { return true }
        // An answer that is mostly the question with a few words bolted on is still an echo.
        if a.count < q.count * 3 / 2 && a.contains(q) { return true }
        return isTautology(answer: a, question: q)
    }

    /// Words that carry no content, so reusing them says nothing.
    private static let emptyWords: Set<String> = [
        "a", "an", "the", "was", "were", "is", "are", "be", "been", "am", "do", "did", "does",
        "i", "me", "my", "you", "your", "it", "that", "this", "those", "these", "there",
        "what", "which", "who", "when", "where", "how", "why", "whats",
        "about", "on", "in", "at", "to", "of", "for", "with", "from", "by", "as",
        "and", "or", "but", "so", "then", "last", "and", "any", "anything", "some",
        "ok", "okay", "please", "tell", "show", "again", "still", "just", "also",
    ]

    /// True when the answer only repeats words the question already supplied.
    ///
    /// The failure this catches: asked *"what was that repo about screen memory"* the model
    /// answered **"The repo was about screen memory."** Every guard passed: nothing was
    /// fabricated, no figure was invented, and it is not a literal echo because the word
    /// order differs. It is simply, perfectly, empty.
    ///
    /// A memory that restates the question in the indicative is not answering it. If the
    /// reply introduces no word the asker did not already have, it carries no information,
    /// and saying so honestly is better than pretending.
    ///
    /// Bounded to short replies: a long answer that happens to reuse the question's nouns is
    /// usually elaborating on them, which is exactly what it should do.
    static func isTautology(answer: String, question: String) -> Bool {
        func content(_ s: String) -> Set<String> {
            Set(s.split(separator: " ").map(String.init).filter {
                !emptyWords.contains($0) && $0.count > 1
            })
        }
        let a = content(answer)
        guard !a.isEmpty, answer.split(separator: " ").count <= 12 else { return false }
        return a.isSubset(of: content(question))
    }

    /// The model declining in its own words, rather than answering.
    ///
    /// "I cannot answer that question." is not Memoir's voice and not Memoir's reason: the model
    /// is refusing on its own behalf, having been handed a context that genuinely contained
    /// the answer. Treated as a rejection so the question falls to the floor, which reads the
    /// store directly and usually can answer it.
    static let modelRefusals: [String] = [
        "i cannot answer", "i can't answer", "i am unable to", "i'm unable to",
        "i cannot provide", "i can't provide", "i cannot determine", "i can't determine",
        "as an ai", "i do not have access", "i don't have access",
        "there is no information", "no information is provided", "not enough information",
        "the context does not", "the provided context",
    ]

    /// True when the answer is the model declining rather than Memoir refusing.
    public static func isModelRefusal(_ answer: String) -> Bool {
        let a = answer.lowercased()
        return modelRefusals.contains(where: a.contains)
    }

    /// What to say instead of a fabricated answer.
    ///
    /// Deliberately plain and slightly self-deprecating: the honest failure of a memory is
    /// "I do not have that", and pretending otherwise is the one thing that destroys trust
    /// in it permanently.
    public static let refusal = "I do not have anything recorded about that."

    /// Used when a question asks about something Memoir structurally cannot know.
    ///
    /// Distinct from ``refusal``, which means "I have no record of that". This means "that
    /// is not a thing I record at all", which is a different and more useful admission.
    ///
    /// It names the LIMIT, not a list of topics. The old wording ended "…anything about
    /// money, purchases or calls", which was three of the families and therefore wrong for
    /// the fourth: asked what they had for lunch, the user was told nothing was recorded
    /// about money. An enumeration has to be exhaustive to be honest, and this one cannot
    /// be: the set of things that happen away from a screen is not a list.
    public static let outOfScopeRefusal =
        "I only record what is on your screen, so I have no record of anything that happened "
        + "away from it. That is not something I can know."

    /// Used when the model asserted an action the evidence cannot support.
    ///
    /// States the actual limit rather than pretending ignorance: Memoir records what was on
    /// screen, and inferring intent from that is exactly where it starts making things up.
    public static let actionRefusal =
        "I can see what was on your screen, but not what you did with it, so I can't say that for sure."

    // MARK: - Questions that must never reach a model

    /// A credential must never be repeated, whatever happens to be in the corpus.
    ///
    /// Secure fields are never read and anything that looks like a secret is dropped at
    /// capture, but "never captured" is not the same as "never answered". Asked
    /// "what is my password for github", the model produced
    /// **"Your password for github is \"login\"."**, a confident, wrong, and utterly
    /// unacceptable answer assembled from a login page's surrounding text.
    ///
    /// The defence cannot be a grounding guard, because a guard only asks whether the claim
    /// appears in the evidence; if a credential ever did reach the corpus the guard would
    /// wave it through. So the question is refused before any retrieval happens at all.
    public static let credentialRefusal =
        "I won't repeat passwords, keys or codes, not even if one crossed the screen. Use your password manager."

    /// Private browsing is never captured (CF-8), so the honest answer is structural.
    public static let privateBrowsingRefusal =
        "I don't record private or incognito windows at all, so I have no record of that."

    /// Memoir is a memory. It has no information about what has not happened yet.
    public static let predictionRefusal =
        "I only have a record of what has already happened, so I don't know what you will do."

    /// Calls and messages never touch the screen reader, so any answer is invention.
    ///
    /// The action guard catches "you emailed Marco" after the fact, but a question that can
    /// only be answered by inventing should never reach a model at all. Asked "who called me
    /// today" it produced **"someone@example.com called you today"**, a fabricated event
    /// about a real person, assembled from an address that happened to be on screen.
    public static let communicationRefusal =
        "I don't have anything about calls or messages. I only see what is on your screen."

    /// Question classes that are refused deterministically, before any model runs.
    ///
    /// These are not routing decisions, they are guarantees. A probabilistic classifier is
    /// the wrong mechanism for "never reveal a credential": it is right most of the time,
    /// and most of the time is not a security property. Matching is on possessive and
    /// interrogative forms so that recall still works: "that article about password
    /// managers" is a legitimate memory question and stays answerable, while
    /// "what is my password" and "every password you have seen" do not.
    ///
    /// - Returns: the refusal to give, or nil to let the question proceed normally.
    public static func hardRefusal(for question: String) -> String? {
        let q = " " + question.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: " ") + " "

        let credential = [
            "my password", "my passwords", "my passcode", "my pin", "my api key",
            "my secret", "my secrets", "my token", "my credentials", "my 2fa", "my otp",
            "password for", "passwords for", "credentials for", "api key for",
            "the password", "password you", "passwords you", "secrets you",
            "what is my login", "my recovery code", "my seed phrase",
        ]
        if credential.contains(where: { q.contains(" " + $0 + " ") || q.contains(" " + $0) }) {
            return credentialRefusal
        }

        let priv = ["incognito", "private browsing", "private window", "private windows",
                    "private tab", "private tabs", "private session"]
        if priv.contains(where: { q.contains(" " + $0 + " ") }) { return privateBrowsingRefusal }

        // Incoming communication only. "Who did I email about X" is also unanswerable, but
        // the action guard already handles the outgoing case after generation, and being
        // narrow here keeps ordinary recall about an inbox on screen working.
        let comms = ["who called", "who phoned", "who rang", "who messaged", "who texted",
                     "who emailed me", "who called me", "any calls", "any missed calls",
                     "my call log", "my calls", "who tried to reach",
                     // Asked "what's the latest email I've checked", Memoir answered with the
                     // user's OWN address, lifted off a screen and asserted as an inbox fact.
                     // There were zero mail captures in the whole database, so there was
                     // nothing it could have been right about.
                     //
                     // "the latest email" claims an inbox Memoir does not have. Reading Gmail in a
                     // browser is different and still answerable: "what was on gmail" is a page
                     // that was genuinely on screen, and is not caught here.
                     "latest email", "last email", "recent email", "my emails", "my inbox",
                     "email i checked", "email ive checked", "unread email"]
        if comms.contains(where: q.contains) { return communicationRefusal }

        // Future tense only. "What do I have due tomorrow" is a real commitments question
        // and must NOT be caught here: the trigger is the future-action phrasing, never
        // the word "tomorrow" on its own.
        let future = ["what will i", "what am i going to", "what are you predicting",
                      "predict what", "what would i do tomorrow", "what will happen"]
        if future.contains(where: q.contains) { return predictionRefusal }

        return nil
    }

    // MARK: - Challenges

    // Pushing back is not a new question, and agreeing with it is not an answer.
    //
    // Observed live, three consecutive turns:
    //
    //     Memoir:  "You spent 1 minute and 43 seconds on Claude."   ← wrong, it was 2h 10m
    //     User: "mmm I do not think I have only spent 1 minute on claude"
    //     Memoir:  "You spent 1 minute on Claude."                  ← agreed, changed nothing
    //
    // Capitulating is worse than the original error. It turns a wrong answer into a
    // CONFIRMED wrong answer, and it teaches the user that pushing back does nothing,
    // after which they stop pushing back, and every remaining error goes unreported.
    //
    // Two things have to be detectable: that the user disputed the last answer, and that
    // the reply caved rather than went back to the data.

    /// Contractions expanded to the two words they stand for.
    ///
    /// Expansion rather than contraction, because the same person writes "thats wrong" and
    /// "that is wrong" in consecutive turns and both are the same dispute. Matching one form
    /// misses half of them, and the half it misses is the half typed in irritation.
    private static let expansions: [String: [String]] = [
        "dont": ["do", "not"], "doesnt": ["does", "not"], "didnt": ["did", "not"],
        "isnt": ["is", "not"], "wasnt": ["was", "not"], "werent": ["were", "not"],
        "arent": ["are", "not"], "aint": ["is", "not"],
        "havent": ["have", "not"], "hasnt": ["has", "not"], "hadnt": ["had", "not"],
        "cant": ["can", "not"], "cannot": ["can", "not"], "couldnt": ["could", "not"],
        "wouldnt": ["would", "not"], "shouldnt": ["should", "not"], "wont": ["will", "not"],
        "thats": ["that", "is"], "youre": ["you", "are"], "theres": ["there", "is"],
        "whats": ["what", "is"], "ive": ["i", "have"], "im": ["i", "am"],
    ]

    /// The message as lowercase words, apostrophes dropped and contractions expanded.
    private static func words(in message: String) -> [String] {
        message.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .flatMap { expansions[$0] ?? [$0] }
    }

    /// One word matched against a pattern word, tolerating the typos people actually make.
    ///
    /// The transcript above was typed fast, unpunctuated and lowercase. A detector that only
    /// fires on correct spelling misses exactly the messages people send when they are
    /// annoyed, which is precisely when they are challenging something.
    ///
    /// Short words are matched exactly and deliberately: "not" and "now" are one edit apart
    /// and confusing them inverts the sentence, which is the one error this must never make.
    /// The distance is Damerau, so a transposition ("worng", "rigth") costs one, and
    /// transposition is most of real typing.
    private static func tokenMatches(_ word: String, _ pattern: String) -> Bool {
        if word == pattern { return true }
        guard pattern.count >= 4 else { return false }
        let budget = pattern.count >= 8 ? 2 : 1
        return MemoryService.editDistance(word, pattern, max: budget) <= budget
    }

    /// Words that sit INSIDE a dispute far more often than anywhere else.
    ///
    /// "that seems low" arrives as "that seems way low" and "that seems really low" about as
    /// often as it arrives plain, because people intensify when they disagree. Skipping one
    /// of these keeps the phrase list from doubling for every adverb an irritated user
    /// reaches for.
    private static let intensifiers: Set<String> = [
        "really", "very", "way", "so", "quite", "pretty", "totally",
        "completely", "definitely", "much", "far", "actually",
    ]

    private static func phraseMatches(_ phrase: [String], at start: Int, in words: [String]) -> Bool {
        var index = start
        var skipped = false
        for expected in phrase {
            guard index < words.count else { return false }
            if !tokenMatches(words[index], expected) {
                // One intensifier may sit inside a phrase, never two: at two skips the
                // phrase stops being adjacent and starts matching unrelated sentences.
                guard !skipped, intensifiers.contains(words[index]), index + 1 < words.count,
                      tokenMatches(words[index + 1], expected)
                else { return false }
                skipped = true
                index += 1
            }
            index += 1
        }
        return true
    }

    /// Phrases that dispute the previous answer, written in expanded form.
    ///
    /// Every one is at least two words. Single words are far too cheap: "wrong" appears in
    /// "what was wrong with the build", and one false positive here makes Memoir argue with a
    /// user who was only asking a follow-up.
    private static let disputePhrases: [[String]] = [
        // Direct disagreement.
        "i do not think", "i do not believe", "i do not buy", "i do not agree", "i doubt",
        "that is wrong", "you are wrong", "that is incorrect", "that is not right",
        "that is not correct", "that is not true", "that is false", "that is not what",
        "that is off", "that is way off", "that is impossible", "that is not possible",
        "can not be right", "can not be correct", "can not be true", "that can not be",
        "does not seem right", "does not sound right", "does not look right",
        "does not add up", "that does not seem", "i never",
        // Asking it to check, which is a dispute phrased politely.
        "are you sure", "are you certain", "are you positive", "sure about that",
        "is that right", "is that correct", "is that accurate",
        "check again", "double check", "can you check", "look again", "count again",
        "where did you get that", "how did you get that",
        // Contradicting a specific claim.
        "no it was not", "no it is not", "no i did not", "no i have not", "no i was not",
        "no that is not", "no that was not", "no it does not", "surely not", "no way",
        // Disputing the magnitude, which is how a wrong duration gets challenged.
        "seems low", "seems high", "seems short", "seems too", "seems off", "seems wrong",
        "sounds low", "sounds high", "sounds too", "sounds off", "sounds wrong",
        "too low", "too high", "way more", "way less", "more than that", "less than that",
        "more like",
    ].map { $0.split(separator: " ").map(String.init) }

    /// Bare noises of doubt, which only count as a challenge on their own.
    private static let doubtInterjections: Set<String> = [
        "mmm", "mm", "mmmm", "hmm", "hm", "hmmm", "really", "seriously",
        "nope", "no", "wrong", "impossible", "doubtful",
    ]

    /// True when the user's message disputes the previous answer rather than asking
    /// something new.
    ///
    /// Ordinary follow-ups have to survive this untouched. "and before that?" and "what about
    /// chrome" are the two most common things a user says after a GOOD answer, and reading
    /// either as a challenge would make Memoir defensive about answers nobody questioned.
    public static func isChallenge(_ message: String) -> Bool {
        let tokens = words(in: message)
        guard !tokens.isEmpty else { return false }
        for phrase in disputePhrases where tokens.count >= phrase.count {
            for start in 0...(tokens.count - phrase.count)
            where phraseMatches(phrase, at: start, in: tokens) {
                return true
            }
        }
        // A bare interjection counts only when it is essentially the whole message. "mmm" on
        // its own is doubt; "hmm what did I have open on chrome" is thinking out loud before
        // an ordinary question, and the user who typed the transcript above writes both.
        guard tokens.count <= 3 else { return false }
        return tokens.contains { word in doubtInterjections.contains { tokenMatches(word, $0) } }
    }

    /// Social filler that cannot make a repeated figure new.
    ///
    /// "You are right" in front of an unchanged number IS the capitulation, so counting it
    /// as fresh content would exempt the exact reply this is meant to catch.
    private static let concessions: [String] = [
        "you are right", "youre right", "you are correct", "youre correct",
        "my mistake", "my apologies", "i apologise", "i apologize",
        "i am sorry", "im sorry", "sorry about that", "sorry", "i was wrong",
        "good catch", "let me correct that", "correction",
    ]

    /// Words that carry content, with concessions and grammatical plurals removed.
    private static func contentWords(in text: String) -> Set<String> {
        var lowered = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "'", with: "")
        for phrase in concessions {
            lowered = lowered.replacingOccurrences(of: phrase, with: " ")
        }
        var out = Set<String>()
        for raw in lowered.components(separatedBy: CharacterSet.alphanumerics.inverted) {
            guard raw.count > 1, !emptyWords.contains(raw) else { continue }
            // "10 minutes" and "10 minute" are one claim. Treating them as different words
            // would manufacture new information out of grammar alone.
            var word = raw
            if word.count >= 4, word.hasSuffix("s") { word.removeLast() }
            out.insert(word)
        }
        return out
    }

    /// Every figure a text asserts: whole duration phrases, plus the bare numeric tokens.
    ///
    /// A duration is kept as its own token because "43 minutes" and "1 minute and 43 seconds"
    /// share their digits and agree about nothing. Without it, dropping the seconds off a
    /// wrong answer would look like restating the same digits, which is how the reply in the
    /// transcript above would have escaped.
    private static func statedFigures(in text: String) -> Set<String> {
        var figures = Set(numbers(in: text))
        for phrase in durationPhrases(in: text) { figures.insert("dur|\(phrase.minutes)") }
        return figures
    }

    /// True when a reply merely restates a figure the user just disputed.
    ///
    /// Two conditions, both required.
    ///
    /// The reply states no figure the previous answer did not already state. A different
    /// figure means it went back to the session rows, which is the entire point of being
    /// challenged, and it is allowed even when it turns out to be wrong again.
    ///
    /// And it introduces no words the previous answer and the challenge did not already
    /// supply (the same test ``isTautology`` applies to a first answer, for the same reason).
    /// A reply built only from words the user already had carries no evidence, only assent.
    ///
    /// So "I checked the session records and it is still 2h 10m" passes: it says where the
    /// number came from, which is what a challenge is supposed to provoke. "You spent 1
    /// minute on Claude" does not.
    public static func capitulates(
        answer: String, toChallenge challenge: String, previousAnswer: String
    ) -> Bool {
        // Capitulation only exists in reply to a challenge. Anything else is a new question,
        // and repeating a figure is a perfectly good answer to someone who asked for it again.
        guard isChallenge(challenge) else { return false }
        let stated = statedFigures(in: answer)
        guard !stated.isEmpty, stated.isSubset(of: statedFigures(in: previousAnswer)) else {
            return false
        }
        let known = contentWords(in: previousAnswer).union(contentWords(in: challenge))
        // Two words rather than one: "only", or "today", bolted onto the same sentence is a
        // hedge, not a re-derivation, and one hedge should not buy an unchanged number a pass.
        return contentWords(in: answer).subtracting(known).count < 2
    }

    /// True when a reply to a challenge asserts confidence and nothing else.
    ///
    /// The sharper half of capitulation, and the one that got through. ``capitulates``
    /// compares figures, so it catches a reply that repeats the disputed number. It cannot
    /// see this, observed live:
    ///
    ///     Memoir:  "You spent 2 minutes on Claude today."
    ///     User: "are you sure ?"
    ///     Memoir:  "Yes, I am sure."
    ///
    /// There is no figure to compare, because there is no content at all. The user asked Memoir
    /// to check and Memoir asserted instead, which is worse than repeating the number: it spends
    /// the trust that a re-derivation would have earned, and it teaches the user that
    /// doubting Memoir achieves nothing.
    ///
    /// A challenge has exactly two honest answers: here is the figure again and here is where
    /// it comes from, or I was wrong. "Yes" is neither.
    public static func assertsWithoutEvidence(_ answer: String) -> Bool {
        let a = answer.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.!?"))
        // Anything carrying a figure, a duration or a name is at least attempting an answer,
        // whether or not it is right. Only the contentless replies are caught here.
        guard numbers(in: answer).isEmpty, durationPhrases(in: answer).isEmpty else { return false }
        let bare = [
            "yes", "yes i am sure", "yes im sure", "i am sure", "im sure", "yes i am certain",
            "correct", "yes that is correct", "yes thats correct", "that is correct",
            "yes it is", "it is", "confirmed", "yes confirmed", "absolutely", "definitely",
            "yes definitely", "indeed", "yes indeed", "affirmative", "of course",
        ]
        if bare.contains(a) { return true }
        // Short and opening with a bare affirmation is the same move with a few words on it:
        // "Yes, I am sure about that." Bounded so a real short answer survives.
        let words = a.split(separator: " ").count
        return words <= 8 && bare.contains { a.hasPrefix($0 + " ") || a.hasPrefix($0 + ",") }
    }

    /// True when the message rejects the last answer rather than asking anything.
    ///
    /// A complaint has no subject, and treating it as a query is how this happened:
    ///
    ///     User: "so what ? this is not what I have asked"
    ///     Memoir:  "Google Chrome was the frontmost app. I don't have any records of the URL
    ///           https://t.co/ybIpXhYSsj"
    ///
    /// The words of the complaint were searched, matched noise, and the model dressed the
    /// noise up as an answer. Telling someone who just said "that is not what I asked" about
    /// a URL they never mentioned is the least useful thing the product can do: it proves it
    /// was not listening, twice.
    ///
    /// Kept separate from ``isChallenge``. A challenge disputes the ANSWER and is repaired by
    /// checking again. A complaint says the whole question was misunderstood, and the only
    /// honest repair is to admit that and ask.
    public static func isComplaint(_ message: String) -> Bool {
        let q = " " + message.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: " ") + " "
        let phrases = [
            "not what i asked", "not what i have asked", "not what i was asking",
            "not what i meant", "thats not what i", "that is not what i",
            "doesnt answer", "does not answer", "didnt answer", "did not answer",
            "not answering", "you didnt understand", "you did not understand",
            "not my question", "wrong answer", "makes no sense", "doesnt make sense",
            "does not make sense", "so what", "irrelevant", "not helpful", "useless",
        ]
        return phrases.contains { q.contains(" " + $0 + " ") || q.contains(" " + $0) }
    }

    /// Said to a complaint, instead of searching its words.
    ///
    /// Admits the miss and asks, because after two wrong answers guessing a third time is
    /// worse than saying "I do not know what you meant".
    public static let complaintRepair =
        "That missed what you asked. Tell me the thing you want and I will look again: a page you saw, what you were doing, time spent, or what is on your list."

    /// Said when a phrase routed as a push could not be parsed.
    ///
    /// The user said something. Dropping it silently is the one unacceptable outcome, so the
    /// failure is reported rather than swallowed.
    public static let unparsedPush =
        "I did not catch what to save. Try starting with \"remind me to\" or \"remember that\"."
}
