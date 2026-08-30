//  CF-60: a chat capture is recoverable as messages.
//
//  WhatsApp Web is the richest surface Memoir captures: 61 captures averaging 8,352 characters
//  on the live database, actual messages with names and timestamps, ahead of every other
//  app. Gmail averages 4,891. Capture was never the problem. The problem is that a capture
//  arrives as one wall of text, so "Teo :  He's got the derby" is a substring rather than
//  a message with a sender, and "what did I write on whatsapp" has nothing to stand on.
//
//  This file turns that wall back into (sender, text) pairs. It is deliberately dumb:
//  pure functions over the accessibility text, no clock, no store, no model. Sender
//  attribution downstream must be able to trust that every sender here was *read off the
//  screen*, never guessed, so the one hard rule is that unrecognised structure degrades
//  to the whole text with a nil sender. A wrong message boundary loses a little context;
//  an invented sender poisons identity work (CF-61/62) at the root.

import Foundation

/// One message recovered from a chat capture.
///
/// `sender` is nil when the capture did not say who wrote it. It is never inferred.
public struct ChatMessage: Sendable, Equatable {
    public let sender: String?
    public let text: String

    public init(sender: String?, text: String) {
        self.sender = sender
        self.text = text
    }
}

/// Splits captured accessibility text from messaging apps into individual messages.
///
/// Stateless by design: the capture pipeline calls this on every packet it labels as a
/// messaging surface, and nothing here may remember the last capture or read the clock.
public enum MessageParser {

    // MARK: - Surface detection

    /// True for surfaces that carry conversations: WhatsApp/Telegram/Slack/Discord/Gmail,
    /// web or native, decided from bundle id + window title.
    ///
    /// The title check is deliberately loose: a Chrome window titled "(3) WhatsApp" and a
    /// native Slack both count. A news article with "slack" in its headline will slip
    /// through, and that is fine: `messages(in:windowTitle:)` finds no chat structure in it
    /// and degrades to the nil-sender whole text, which is exactly what a non-chat capture
    /// produced before this file existed.
    public static func isMessagingSurface(appBundleID: String, windowTitle: String?) -> Bool {
        let bundle = appBundleID.lowercased()
        for token in surfaceTokens where bundle.contains(token) { return true }
        if let title = windowTitle?.lowercased() {
            for token in surfaceTokens where title.contains(token) { return true }
            // Italian Gmail titles its inbox tab "Posta in arrivo (854) - … - Gmail", but a
            // pinned tab can truncate away the trailing "Gmail".
            if title.contains("posta in arrivo") { return true }
        }
        return false
    }

    /// Substrings that identify a conversation surface in a bundle id or window title.
    /// Native ids all contain their product name (net.whatsapp.WhatsApp,
    /// ru.keepcoder.Telegram, com.tinyspeck.slackmacgap, com.hnc.Discord), so substring
    /// matching covers web and native in one pass.
    private static let surfaceTokens = ["whatsapp", "telegram", "slack", "discord", "gmail"]

    // MARK: - Segmentation

    /// Segments a chat capture into messages. Unrecognised structure degrades to
    /// [ChatMessage(sender: nil, text: whole)]. NEVER invented senders.
    ///
    /// Routing is by window title because that is the only label the capture carries.
    /// A title that names none of the known surfaces goes straight to the fallback:
    /// guessing a parser for arbitrary pages is how senders get invented.
    ///
    /// Empty input returns an empty array: there is nothing to recover, and a nil-sender
    /// message with no text is exactly the kind of junk entity CF-14 exists to refuse.
    public static func messages(in text: String, windowTitle: String?) -> [ChatMessage] {
        messages(in: text, shape: shape(appBundleID: nil, windowTitle: windowTitle))
    }

    /// The messages in a capture, dispatched on the app it came from as well as its title.
    ///
    /// This is the overload every caller with a `CaptureEvent` should use, and the reason
    /// it exists is a real hole: a native chat client titles its window after the channel,
    /// not after itself. Slack's window is "#fatturazione - Acme", so the title carries no
    /// "slack" token at all. ``isMessagingSurface(appBundleID:windowTitle:)`` recognised
    /// the capture as a chat by its **bundle id** while the shape dispatch, which read only
    /// the title, fell through to the whole-text fallback. Every native Slack, Telegram and
    /// Discord message therefore came back with `sender == nil`, and CF-61's "only the
    /// user's messages" filter (which matches on sender) dropped all of them silently.
    /// The guard and the dispatcher now read the same two fields.
    public static func messages(in capture: CaptureEvent) -> [ChatMessage] {
        messages(
            in: capture.text,
            shape: shape(appBundleID: capture.appBundleID, windowTitle: capture.windowTitle)
        )
    }

    /// The parseable shapes. A surface can be a chat (``isMessagingSurface``) and still have
    /// no shape here: a client nobody has written a parser for degrades to the whole text
    /// with no sender, which is CF-60's promise and never an invented sender.
    enum Shape {
        case whatsApp
        case gmail
        /// Telegram, Slack, Discord: a sender-and-timestamp header line, then its text.
        case generic
    }

    /// Which shape a surface renders, from either identifier.
    ///
    /// The title is consulted first, because it says which *web* app is loaded: Chrome's
    /// bundle id tells you nothing, while its title says WhatsApp. The bundle id then
    /// covers the native clients whose titles name only a channel.
    static func shape(appBundleID: String?, windowTitle: String?) -> Shape? {
        for haystack in [windowTitle?.lowercased(), appBundleID?.lowercased()].compactMap({ $0 }) {
            if haystack.contains("whatsapp") { return .whatsApp }
            if haystack.contains("gmail") || haystack.contains("posta in arrivo") { return .gmail }
            if haystack.contains("telegram") || haystack.contains("slack") || haystack.contains("discord") {
                return .generic
            }
        }
        return nil
    }

    private static func messages(in text: String, shape: Shape?) -> [ChatMessage] {
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.isEmpty else { return [] }
        let fallback = [ChatMessage(sender: nil, text: whole)]
        guard let shape else { return fallback }

        let parsed: [ChatMessage]
        switch shape {
        case .whatsApp: parsed = whatsAppMessages(in: text)
        case .gmail: parsed = gmailMessages(in: text)
        case .generic: parsed = genericChatMessages(in: text)
        }
        return parsed.isEmpty ? fallback : dedupeAdjacent(parsed)
    }

    // MARK: - WhatsApp Web chat list

    /// WhatsApp Web renders every chat row twice: one compact line
    ///
    ///     Padel Thursday Teo :  He's got the derby and the cup but it's not enough
    ///
    /// followed immediately by the same content re-broken across lines (chat name, weekday,
    /// sender, a lone ":", the text; sometimes further split at every emoji), and sometimes
    /// by a second compact preview line with the colon dropped. Measured on the live
    /// database, that duplication is universal; a parser that does not drop it doubles every
    /// message it recovers.
    ///
    /// Only compact rows (lines with a timestamp token *after* a chat name) produce
    /// messages. Everything a compact row already contains is skipped as its echo, and
    /// everything else (the "Chat list" / "Updates in Status" header furniture) is dropped.
    private static func whatsAppMessages(in text: String) -> [ChatMessage] {
        var out: [ChatMessage] = []
        var lastCompact: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var tokens = rawLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard !tokens.isEmpty else { continue }

            // The echo of the previous compact row: chat name, weekday stamp, sender, lone
            // colon, text, or any emoji-split fragment of the text. All of them are
            // substrings of the row they duplicate.
            if let last = lastCompact, last.contains(tokens.joined(separator: " ")) { continue }

            // "3 unread messages" glues itself onto the front of the row it announces.
            stripUnreadPrefix(&tokens)

            // A compact row has a timestamp after at least one chat-name token.
            guard let stamp = timestampRange(in: tokens),
                  stamp.lowerBound >= 1,
                  stamp.upperBound < tokens.count
            else { continue }

            // The colon-less duplicate preview: same row again with " : " removed. Compare
            // both sides with lone colons stripped so either form matches the other.
            let decolonised = tokens.filter { $0 != ":" }.joined(separator: " ")
            if let last = lastCompact,
               last.split(separator: " ").filter({ $0 != ":" }).joined(separator: " ") == decolonised {
                continue
            }
            lastCompact = tokens.joined(separator: " ")

            let chatName = Array(tokens[0..<stamp.lowerBound])
            let rest = Array(tokens[stamp.upperBound...])
            guard !chatName.isEmpty, !rest.isEmpty, !isWhatsAppFurniture(chatName: chatName, rest: rest) else { continue }

            // "Sender :  text": the colon stands alone between spaces, which is what
            // separates it from a colon inside the message. The sender must look like a
            // label (short, starting with a capital, a digit, "+" or "~"; group chats
            // label unsaved numbers "+34 600 11 22 33" and saved ones "~Alba"), otherwise
            // the colon belongs to the text and the row is a direct chat.
            if let k = rest.firstIndex(of: ":"), k >= 1, k + 1 < rest.count,
               k <= 5, looksLikeSenderLabel(Array(rest[0..<k])) {
                out.append(ChatMessage(
                    sender: rest[0..<k].joined(separator: " "),
                    text: rest[(k + 1)...].joined(separator: " ")
                ))
            } else {
                // No sender prefix means a direct chat, where the chat name *is* the other
                // person. A group name would only land here for a row WhatsApp chose not to
                // label, and WhatsApp labels every group message including the user's own.
                // The chat name still has to look like a sender label before it becomes
                // one: garbage that happens to contain a time token must not mint a sender
                // out of whatever preceded it.
                let sender = chatName.filter { $0 != "(You)" && $0 != "(Tu)" }
                guard !sender.isEmpty, sender.count <= 6, looksLikeSenderLabel(sender) else { continue }
                out.append(ChatMessage(
                    sender: sender.joined(separator: " "),
                    text: rest.joined(separator: " ")
                ))
            }
        }
        return out
    }

    /// Rows that look like messages but are WhatsApp talking to itself: reaction notices,
    /// drafts, deletions, the retention banner, and WhatsApp's own broadcast channel. Each
    /// shape is taken from the live database, not imagined.
    private static func isWhatsAppFurniture(chatName: [String], rest: [String]) -> Bool {
        let chat = fold(chatName.joined(separator: " "))
        if chat == "whatsapp" || chat == "archived" || chat == "archiviate" { return true }

        let restText = fold(rest.joined(separator: " "))
        // '<name> Friday Reacted [emoji] to: "…"' is a reaction, not a message. Both words are
        // required: "reacted" alone would eat a real sentence like "I reacted badly".
        if restText.contains("reacted") && restText.contains("to:") { return true }
        if restText.contains("reagito") && restText.contains(":") { return true }

        let first = fold(rest[0])
        if first == "draft" || first == "draft:" || first == "bozza" || first == "bozza:" { return true }

        if restText.hasPrefix("you deleted this message") { return true }
        if restText.hasPrefix("this message was deleted") { return true }
        if restText.hasPrefix("hai eliminato questo messaggio") { return true }
        if restText.hasPrefix("questo messaggio e stato eliminato") { return true }
        if restText.contains("will disappear from this chat") { return true }
        return false
    }

    /// "1 unread message" / "3 unread messages" / "2 messaggi non letti" glued to the front
    /// of a chat row, exactly as the accessibility tree renders the badge.
    private static func stripUnreadPrefix(_ tokens: inout [String]) {
        guard tokens.count >= 3, !tokens[0].isEmpty, tokens[0].allSatisfy(\.isNumber) else { return }
        let second = fold(tokens[1])
        let third = fold(tokens[2])
        if second == "unread" && (third == "message" || third == "messages") {
            tokens.removeFirst(3)
        } else if tokens.count >= 4 && second.hasPrefix("messagg") && third == "non" {
            // The Italian badge is one word longer: "2 messaggi non letti".
            tokens.removeFirst(4)
        }
    }

    /// The token range of the first timestamp in a compact row: a weekday or relative-day
    /// word ("Thursday", "Yesterday", "ieri"), a numeric date ("7/26/2026"), or a clock time
    /// with an optional meridiem ("6:49 PM", "14:42"). One or two tokens.
    private static func timestampRange(in tokens: [String]) -> Range<Int>? {
        for i in tokens.indices {
            let token = tokens[i]
            if dayWords.contains(fold(token)) || isDateToken(token) {
                return i..<(i + 1)
            }
            if isClockToken(token) {
                if i + 1 < tokens.count, isMeridiem(tokens[i + 1]) { return i..<(i + 2) }
                return i..<(i + 1)
            }
        }
        return nil
    }

    /// A sender label as WhatsApp renders one: at most a few short words, opening with a
    /// capital, a digit, "+" (phone numbers) or "~" (group members without a saved
    /// contact). This is what stops "ok : )" from minting a sender called "ok".
    private static func looksLikeSenderLabel(_ tokens: [String]) -> Bool {
        guard let first = tokens.first?.unicodeScalars.first else { return false }
        let c = Character(first)
        guard c.isUppercase || c.isNumber || c == "+" || c == "~" else { return false }
        return tokens.allSatisfy { $0.count <= 24 && !$0.contains("://") }
    }

    // MARK: - Gmail list view

    /// A Gmail inbox row arrives comma-separated, straight from the accessibility tree:
    ///
    ///     da leggere, Lovable Labs Incorp. , Your receipt #2381-8975 , contiene un allegato, 11:49 , Your receipt …
    ///
    /// flag parts ("da leggere", "contiene un allegato") before and among the real ones,
    /// then sender, subject, a time, and the preview. Gmail also re-renders every row
    /// across several lines (sender alone, "subject  -  preview", the subject alone…), but
    /// none of those echoes carries the comma-and-time shape, so emitting only from
    /// qualifying comma rows deduplicates for free. The preview is dropped: the flow asks
    /// for sender + subject, and previews are where "*|MC_PREVIEW_TEXT|*" template junk lives.
    private static func gmailMessages(in text: String) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var parts = rawLine.split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            parts.removeAll { gmailFlags.contains(fold($0)) }
            guard parts.count >= 3,
                  let timeIndex = parts.firstIndex(where: isGmailTimestamp),
                  timeIndex >= 2
            else { continue }
            let sender = parts[0]
            // A comma inside the subject splits it across parts; everything between the
            // sender and the time is the subject, stitched back together.
            let subject = parts[1..<timeIndex].joined(separator: ", ")
            out.append(ChatMessage(sender: sender, text: subject))
        }
        return out
    }

    /// Row state Gmail interleaves with the content parts, in the locales this database
    /// has actually seen plus their English equivalents.
    private static let gmailFlags: Set<String> = [
        "da leggere", "unread", "contiene un allegato", "has attachment",
        "importante", "important", "speciali", "starred",
    ]

    /// "14:42", "2:42 PM", "4 ago", "Jun 30", "4 ago 2026": the shapes Gmail stamps on a
    /// list row. Month names are not enumerated (the live database alone mixes Italian,
    /// Spanish and English); a short alphabetic token next to a day number is enough.
    private static func isGmailTimestamp(_ part: String) -> Bool {
        let tokens = part.split(separator: " ").map(String.init)
        if tokens.count == 1 { return isClockToken(tokens[0]) }
        if tokens.count == 2, isClockToken(tokens[0]), isMeridiem(tokens[1]) { return true }
        guard (2...3).contains(tokens.count) else { return false }
        let dayNumbers = tokens.filter { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
        let words = tokens.filter { $0.count >= 3 && $0.count <= 4 && $0.allSatisfy(\.isLetter) }
        let years = tokens.filter { $0.count == 4 && $0.allSatisfy(\.isNumber) }
        return dayNumbers.count == 1 && words.count == 1 && dayNumbers.count + words.count + years.count == tokens.count
    }

    // MARK: - Telegram / Slack / Discord

    /// The two shapes shared by the remaining chat surfaces: an inline "Sender: text" line,
    /// and a Slack-style header ("Marco Rossi 10:42 AM", or Discord's "marco" followed by an
    /// em dash and "Today at 1:52 AM") whose message body follows on the next lines. Anything
    /// before the first recognised sender is furniture; anything after one is that sender's
    /// text.
    private static func genericChatMessages(in text: String) -> [ChatMessage] {
        var out: [ChatMessage] = []
        var currentSender: String?
        var currentText: [String] = []

        func flush() {
            if let sender = currentSender, !currentText.isEmpty {
                out.append(ChatMessage(sender: sender, text: currentText.joined(separator: " ")))
            }
            currentSender = nil
            currentText = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let tokens = rawLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard !tokens.isEmpty else { continue }

            if let name = headerSender(tokens) {
                flush()
                currentSender = name
                continue
            }
            if let (name, body) = inlineSender(tokens) {
                flush()
                out.append(ChatMessage(sender: name, text: body))
                continue
            }
            if currentSender != nil { currentText.append(tokens.joined(separator: " ")) }
        }
        flush()
        return out
    }

    /// "Marco Rossi 10:42 AM", or "marco_92" followed by an em dash and "Today at 1:52 AM":
    /// trailing time furniture peeled off the end, a plausible name left over. A clock time
    /// must have been peeled, not merely a day word: "I'll send the invoice Friday" ends in a
    /// day word and is a message, and a parser that reads it as a header mints a sender called
    /// "I'll send the invoice", which is precisely the commitment sentence CF-62 must
    /// attribute right.
    private static func headerSender(_ tokens: [String]) -> String? {
        var name = tokens
        var peeledClock = false
        while let last = name.last {
            if isClockToken(last) {
                peeledClock = true
                name.removeLast()
            } else if isMeridiem(last) || isDateToken(last) || dayWords.contains(fold(last))
                || fold(last) == "at" || last == "\u{2014}" || last == "-" {
                name.removeLast()
            } else {
                break
            }
        }
        guard peeledClock, (1...4).contains(name.count), isPlausibleName(name) else { return nil }
        return name.joined(separator: " ")
    }

    /// "Marco: dai ci vediamo alle 9": the colon ends one of the first few tokens. The
    /// name must pass the plausibility gate, which is what keeps "Note: buy milk" from
    /// minting a sender called "Note" on a page that merely mentions Telegram.
    private static func inlineSender(_ tokens: [String]) -> (String, String)? {
        for k in tokens.indices.prefix(4) {
            let token = tokens[k]
            guard token.hasSuffix(":"), token.count >= 2, k + 1 < tokens.count else { continue }
            var name = Array(tokens[0...k])
            name[k] = String(token.dropLast())
            guard !name[k].contains(":"), isPlausibleName(name) else { return nil }
            return (name.joined(separator: " "), tokens[(k + 1)...].joined(separator: " "))
        }
        return nil
    }

    /// Short, no URLs, not a stop word, and every word either capitalised or handle-shaped
    /// (digits, "_", "~", "@"; Discord's lowercase handles are real senders). Every word,
    /// not just the first: "Meeting moved to 15:00" opens with a capital and is a message,
    /// and only the all-words rule keeps "Meeting moved to" from becoming its sender.
    private static func isPlausibleName(_ tokens: [String]) -> Bool {
        guard (1...4).contains(tokens.count),
              tokens.allSatisfy({ !$0.isEmpty && $0.count <= 24 && !$0.contains("://") }),
              !nameStopWords.contains(fold(tokens.joined(separator: " ")))
        else { return false }
        return tokens.allSatisfy { token in
            (token.first?.isUppercase ?? false)
                || token.contains { $0.isNumber || $0 == "_" || $0 == "~" || $0 == "@" }
        }
    }

    /// Words that open ordinary prose with a colon and are never anyone's name.
    private static let nameStopWords: Set<String> = [
        "note", "nota", "warning", "subject", "draft", "bozza", "re", "fwd", "ps",
        "tip", "edit", "reply", "today", "yesterday", "error", "http", "https",
    ]

    // MARK: - Shared token helpers

    /// WhatsApp renders everything twice; even after structural dedup, keep two identical
    /// adjacent (sender, text) pairs from ever reaching the store.
    private static func dedupeAdjacent(_ messages: [ChatMessage]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for m in messages where m != out.last { out.append(m) }
        return out
    }

    private static let dayWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "yesterday", "today",
        "lunedi", "martedi", "mercoledi", "giovedi", "venerdi", "sabato", "domenica",
        "ieri", "oggi",
        "lunes", "martes", "miercoles", "jueves", "viernes", "sabado", "domingo",
        "ayer", "hoy",
    ]

    /// "6:49", "14:42": digits, one colon, plausible clock fields. "0:08" also passes,
    /// which is correct: WhatsApp shows voice-note durations as message text, and a
    /// duration in the text slot is harmless where a fake sender is not.
    private static func isClockToken(_ token: String) -> Bool {
        let parts = token.split(separator: ":")
        guard parts.count == 2,
              parts[0].count <= 2, parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let h = Int(parts[0]), h <= 23,
              let m = Int(parts[1]), m <= 59
        else { return false }
        return true
    }

    private static func isMeridiem(_ token: String) -> Bool {
        let f = fold(token)
        return f == "am" || f == "pm"
    }

    /// "7/26/2026" and friends. All-numeric fields split by one separator style. Dashes
    /// are deliberately not a date separator: WhatsApp and Gmail never stamp rows with
    /// them, and accepting them let junk like "0-4-4" pass for a date and drag whatever
    /// preceded it into a chat-name slot.
    private static func isDateToken(_ token: String) -> Bool {
        for separator: Character in ["/", "."] {
            let parts = token.split(separator: separator)
            if parts.count == 3,
               parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isNumber) }) {
                return true
            }
        }
        return false
    }

    /// Lowercased and accent-folded, the same normalisation UserNames applies, so
    /// "giovedì" and "Giovedi" are one word here too.
    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
