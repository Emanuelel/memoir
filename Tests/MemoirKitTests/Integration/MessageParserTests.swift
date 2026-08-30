//  CF-60: a chat capture is recoverable as messages.
//
//  Every fixture here reproduces the SHAPE of a real capture and none of its content: the
//  people, groups, subjects and messages are invented, and must stay invented. What is
//  copied is the structure, and that matters more than usual: WhatsApp Web renders each chat row
//  twice (a compact "Chat Timestamp Sender :  text" line, then the same content re-broken
//  across lines and split at every emoji), Gmail renders each inbox row as a comma
//  packed line followed by four echoes of it, and a parser that only ever met tidy input
//  will double every message the moment it meets the real thing.
//
//  No clock, no store, no network: the parser is pure functions and so are the tests.

import Foundation
import Testing

import MemoirFixtures
@testable import MemoirKit

@Suite("CF-60 · a chat capture is recoverable as messages")
struct MessageParserTests {

    // MARK: - Surface detection

    @Test("CF-60 WhatsApp Web in a browser is a messaging surface")
    func whatsAppWebIsMessaging() {
        #expect(MessageParser.isMessagingSurface(
            appBundleID: "com.google.Chrome",
            windowTitle: "(3) WhatsApp - Google Chrome"
        ))
    }

    @Test("CF-60 native Slack is a messaging surface even without a title")
    func nativeSlackIsMessaging() {
        #expect(MessageParser.isMessagingSurface(
            appBundleID: "com.tinyspeck.slackmacgap",
            windowTitle: nil
        ))
    }

    @Test("CF-60 Gmail in Italian Chrome is a messaging surface")
    func gmailIsMessaging() {
        #expect(MessageParser.isMessagingSurface(
            appBundleID: "com.google.Chrome",
            windowTitle: "Posta in arrivo (854) - marco.verdi@example.com - Gmail - Google Chrome"
        ))
    }

    @Test("CF-60 an ordinary page is not a messaging surface")
    func ordinaryPageIsNot() {
        #expect(!MessageParser.isMessagingSurface(
            appBundleID: "com.google.Chrome",
            windowTitle: "Serie A results and standings - Google Chrome"
        ))
        #expect(!MessageParser.isMessagingSurface(
            appBundleID: "com.apple.Notes",
            windowTitle: nil
        ))
    }

    // MARK: - WhatsApp Web

    /// The chat-list capture. Every structural quirk below was observed on a real capture;
    /// every name and message is invented. The shape:
    /// header furniture, then compact rows each followed by their re-broken echo. Includes
    /// a reaction row, a group row with "Sender :", direct chats, an emoji-only message,
    /// an unread-badge prefix, a draft, WhatsApp's own broadcast row, a "(You)" self chat,
    /// a deleted message and a phone-number sender.
    private static let whatsAppCapture = """
        (1) WhatsApp
        1
        3
        Updates in Status
        WhatsApp
        wa-wordmark
        Search or start a new chat
        All
        Unread
        Favorites
        Groups
        Message notifications are off.
        Chat list
        Marco Bruni Friday Reacted ❤️ to:   " tuttobene"
        Marco Bruni
        Friday
        Reacted
        ❤️
        to:
        "
        tuttobene"
        Sofia Llorente 10:06 PM https://youtu.be/dQw4w9WgXcQ I think we should swap the base too, number 4
        Sofia Llorente
        10:06 PM
        https://youtu.be/dQw4w9WgXcQ I think we should swap the base too, number 4
        Renée Friday Che spettacolo... è uscito benissimo ❤️ 😘
        Che spettacolo... è uscito benissimo
        😘
        Padel Thursday Teo :  He's got the derby and the cup but it's not enough
        Padel
        Thursday
        Teo
        He's got the derby and the cup but it's not enough
        Rafa Thursday 🤟
        Rafa
        🤟
        Cineclub Wednesday Bruno :  Ma secondo me non ha letto niente
        Cineclub
        Wednesday
        Bruno
        :
        Ma secondo me non ha letto niente
        3 unread messages La Piazza 6:49 PM Bruno :  Sta a piove da du ore
        3 unread messages
        La Piazza
        6:49 PM
        Sta a piove da du ore
        Bea, Iker , Laia, Ximena, ~Sergi, ~Alba & ~Ámbar 9:18 PM ~Alba :  Nuria y yo subimos con Adrián cuando salga de trabajar
        Bea, Iker , Laia, Ximena, ~Sergi, ~Alba & ~Ámbar
        9:18 PM
        ~Alba
        Nuria y yo subimos con Adrián cuando salga de trabajar
        Casa del Sol 7/26/2026 Yaiza :  Sisi todo bien, solo que no me apuntaba
        Casa del Sol
        7/26/2026
        Yaiza
        Sisi todo bien, solo que no me apuntaba
        Cena di Fine Anno 7/25/2026 Draft:  EH perché no. New messages will disappear from this chat 90 days after they're sent, except when kept.
        Cena di Fine Anno
        7/25/2026
        Draft
        EH perché no.
        New messages will disappear from this chat 90 days after they're sent, except when kept.
        WhatsApp 7/24/2026 *New: Use two accounts on the same phone* Now you can switch between two WhatsApp accounts
        *New: Use two accounts on the same phone* Now you can switch between two WhatsApp accounts
        Davide  Sartori (You) 7/20/2026 https://www.reddit.com/r/swift/s/aB3xKq9Lm2
        Davide  Sartori
        (You)
        7/20/2026
        https://www.reddit.com/r/swift/s/aB3xKq9Lm2
        Beatrice 7/16/2026 You deleted this message
        Beatrice
        7/16/2026
        You deleted this message
        +34 600 11 22 33 5:34 PM Hola!Los horarios dependen del día que quieras venir
        +34 600 11 22 33
        5:34 PM
        Hola!Los horarios dependen del día que quieras venir
        """

    private static let whatsAppTitle = "(1) WhatsApp - Google Chrome"

    @Test("CF-60 the chat list comes back as one message per row, echoes dropped")
    func whatsAppChatList() {
        let messages = MessageParser.messages(in: Self.whatsAppCapture, windowTitle: Self.whatsAppTitle)
        #expect(messages == [
            ChatMessage(sender: "Sofia Llorente", text: "https://youtu.be/dQw4w9WgXcQ I think we should swap the base too, number 4"),
            ChatMessage(sender: "Renée", text: "Che spettacolo... è uscito benissimo ❤️ 😘"),
            ChatMessage(sender: "Teo", text: "He's got the derby and the cup but it's not enough"),
            ChatMessage(sender: "Rafa", text: "🤟"),
            ChatMessage(sender: "Bruno", text: "Ma secondo me non ha letto niente"),
            ChatMessage(sender: "Bruno", text: "Sta a piove da du ore"),
            ChatMessage(sender: "~Alba", text: "Nuria y yo subimos con Adrián cuando salga de trabajar"),
            ChatMessage(sender: "Yaiza", text: "Sisi todo bien, solo que no me apuntaba"),
            ChatMessage(sender: "Davide Sartori", text: "https://www.reddit.com/r/swift/s/aB3xKq9Lm2"),
            ChatMessage(sender: "+34 600 11 22 33", text: "Hola!Los horarios dependen del día que quieras venir"),
        ])
    }

    @Test("CF-60 group names and weekday stamps are furniture, not senders")
    func groupNamesAreFurniture() {
        let messages = MessageParser.messages(in: Self.whatsAppCapture, windowTitle: Self.whatsAppTitle)
        let senders = Set(messages.compactMap(\.sender))
        // The group is "Padel"; the sender is Teo. If "Padel" or a
        // weekday ever shows up as a sender, the parser has promoted furniture to a person.
        #expect(!senders.contains("Padel"))
        #expect(!senders.contains("Cineclub"))
        #expect(!senders.contains("La Piazza"))
        #expect(senders.isDisjoint(with: ["Thursday", "Friday", "Wednesday", "Yesterday"]))
    }

    @Test("CF-60 reactions, drafts, deletions and WhatsApp broadcasts never become messages")
    func whatsAppFurnitureRows() {
        let messages = MessageParser.messages(in: Self.whatsAppCapture, windowTitle: Self.whatsAppTitle)
        for m in messages {
            #expect(m.sender != "WhatsApp")
            #expect(m.sender != "Beatrice")   // their only row is "You deleted this message"
            #expect(m.sender != "Marco Bruni")   // their only row is a reaction notice
            #expect(!m.text.contains("Draft"))
            #expect(!m.text.contains("Reacted"))
        }
    }

    @Test("CF-60 the colon-less duplicate preview line is one message, not two")
    func colonlessDuplicateIsDropped() {
        // The other duplication WhatsApp produces: the compact row again, glued on one
        // line, with the " : " removed. Same sender and text must come back once.
        let capture = """
            Padel Thursday Teo :  He's got the derby and the cup but it's not enough
            Padel Thursday Teo He's got the derby and the cup but it's not enough
            Rafa Thursday 🤟
            Rafa
            🤟
            """
        let messages = MessageParser.messages(in: capture, windowTitle: Self.whatsAppTitle)
        #expect(messages == [
            ChatMessage(sender: "Teo", text: "He's got the derby and the cup but it's not enough"),
            ChatMessage(sender: "Rafa", text: "🤟"),
        ])
    }

    @Test("CF-60 an emoji-split echo does not resurrect fragments as messages")
    func emojiSplitEchoIsDropped() {
        // The long-message shape, as observed on a real capture: the compact row, then the echo
        // re-broken at every emoji into its own line.
        let capture = """
            Elena Rastrelli 12:20 PM Hi! 👋 We wanted to share a very special property in Viladrau, one hour from Barcelona. 🌿 A beautiful villa with a large private garden
            Elena Rastrelli
            12:20 PM
            Hi!
            👋
            We wanted to share a very special property in Viladrau, one hour from Barcelona.
            🌿
            A beautiful villa with a large private garden
            """
        let messages = MessageParser.messages(in: capture, windowTitle: Self.whatsAppTitle)
        #expect(messages.count == 1)
        #expect(messages[0].sender == "Elena Rastrelli")
        #expect(messages[0].text.hasPrefix("Hi! 👋 We wanted"))
    }

    // MARK: - Gmail

    /// The Italian inbox capture: label rail, category teasers, then conversation rows as
    /// comma-packed lines each followed by their multi-line echo. Structure from the live
    /// database, senders and subjects swapped.
    private static let gmailCapture = """
        Posta in arrivo (854) - marco.verdi@example.com - Gmail
        Nessun elemento selezionato
        Vai ai contenuti
        Gmail
        Ricerca
        Cerca nella posta
        Etichette
        Posta in arrivo 854 da leggere
        Posta in arrivo
        854
        Speciali
        Posticipati
        Inviati
        Bozze 73 da leggere
        Bozze
        73
        Promozioni 35997 da leggere ha un menu
        Promozioni
        35.997
        1
        –
        50
        di
        18.317
        Conversazioni
        Principale
        1 nuova
        Promozioni, 50 nuovi messaggi,
        50 nuove
        Solaris - Gafas Eclipse - ¡ÚLTIMAS HORAS!
        Social, 10 nuovi messaggi,
        10 nuove
        LinkedIn - Marco, your posts got 207 impressions last week
        Vitalgym , Cambio de contraseña , 14:42 , *|MC_PREVIEW_TEXT|* Ver email en el navegador ¡Hola, Marco Verdi! Te enviamos este correo porque has solicitado recordar tu contraseña.
        Vitalgym
        Cambio de contraseña  -  *|MC_PREVIEW_TEXT|* Ver email en el navegador ¡Hola, Marco Verdi! Te enviamos este correo porque has solicitado recordar tu contraseña
        Cambio de contraseña
        -
        *|MC_PREVIEW_TEXT|* Ver email en el navegador ¡Hola, Marco Verdi! Te enviamos este correo porque has solicitado recordar tu contraseña
        mar 4 ago 2026, 14:42
        14:42
        da leggere, Fatture Cloud Srl , Your receipt from Fatture Cloud #2381-8975 , contiene un allegato, 11:49 , Your receipt from Fatture Cloud #2381-8975 ͏ ͏ ͏ ͏ ͏
        Fatture Cloud Srl
        Your receipt from Fatture Cloud #2381-8975  -  Your receipt from Fatture Cloud #2381-8975 ͏ ͏ ͏ ͏ ͏
        Your receipt from Fatture Cloud #2381-8975
        Receipt-2381-8975.pdf
        mar 4 ago 2026, 11:49
        11:49
        INFO ATC , Ticket n.°100000000000 (#100000000000) , 10:56 , Buenos días Marco, Hemos comprobado que has sido socio anteriormente.
        INFO ATC
        Ticket n.°100000000000 (#100000000000)  -  Buenos días Marco, Hemos comprobado que has sido socio anteriormente
        Ticket n.°100000000000 (#100000000000)
        10:56
        """

    private static let gmailTitle = "Posta in arrivo (854) - marco.verdi@example.com - Gmail - Google Chrome"

    @Test("CF-60 Gmail list rows come back as sender + subject, echoes and rail dropped")
    func gmailInbox() {
        let messages = MessageParser.messages(in: Self.gmailCapture, windowTitle: Self.gmailTitle)
        #expect(messages == [
            ChatMessage(sender: "Vitalgym", text: "Cambio de contraseña"),
            ChatMessage(sender: "Fatture Cloud Srl", text: "Your receipt from Fatture Cloud #2381-8975"),
            ChatMessage(sender: "INFO ATC", text: "Ticket n.°100000000000 (#100000000000)"),
        ])
    }

    @Test("CF-60 Gmail furniture never becomes a sender")
    func gmailFurnitureIsNotASender() {
        let messages = MessageParser.messages(in: Self.gmailCapture, windowTitle: Self.gmailTitle)
        let senders = Set(messages.compactMap(\.sender))
        // "da leggere" and "contiene un allegato" are row flags; "Promozioni" is a
        // category tab; "Posta in arrivo" is the label rail.
        #expect(senders.isDisjoint(with: ["da leggere", "contiene un allegato", "Promozioni", "Posta in arrivo", "Bozze"]))
    }

    // MARK: - Slack and Telegram shapes

    @Test("CF-60 a native client is parsed by its bundle id, not only by its title")
    func nativeClientDispatchesOnBundleID() {
        // The hole this closes: a native chat client titles its window after the channel,
        // never after itself. Slack's real window title is "#fatturazione - Acme", so a
        // dispatcher reading only the title fell through to the whole-text fallback, and
        // because that fallback has no sender, CF-61's "only the user's messages" filter
        // dropped every native message without a word.
        let slack = Fixtures.capture(
            text: """
                #fatturazione
                Sofia Llorente 10:45 AM
                I'll push the new logo tonight
                """,
            app: "Slack",
            bundleID: "com.tinyspeck.slackmacgap",
            windowTitle: "#fatturazione - Acme",
            at: TestClock.reference,
            name: "parser-native-slack"
        )

        // The guard already recognised it by bundle id; the shape dispatch now agrees.
        #expect(MessageParser.isMessagingSurface(
            appBundleID: slack.appBundleID, windowTitle: slack.windowTitle))
        #expect(MessageParser.shape(
            appBundleID: slack.appBundleID, windowTitle: slack.windowTitle) == .generic)

        let messages = MessageParser.messages(in: slack)
        #expect(messages == [ChatMessage(sender: "Sofia Llorente", text: "I'll push the new logo tonight")])
        #expect(messages.first?.sender != nil, "a nil sender is what silently lost these messages")

        // Text alone still cannot know, and still degrades honestly rather than guessing.
        let blind = MessageParser.messages(in: slack.text, windowTitle: slack.windowTitle)
        #expect(blind.count == 1)
        #expect(blind.first?.sender == nil)

        // The title still wins where it is the more specific signal: Chrome's bundle id
        // says nothing, its title says which web app is loaded.
        #expect(MessageParser.shape(
            appBundleID: "com.google.Chrome",
            windowTitle: "Padel - WhatsApp") == .whatsApp)
    }

    @Test("CF-60 Slack header lines carry their following text lines")
    func slackHeadersAndBodies() {
        let capture = """
            #fatturazione
            Marco Bruni 10:42 AM
            looks good, ship it
            Sofia Llorente 10:45 AM
            I'll send the invoice Friday
            then we're done for the quarter
            """
        let messages = MessageParser.messages(in: capture, windowTitle: "Slack | fatturazione | Acme")
        #expect(messages == [
            ChatMessage(sender: "Marco Bruni", text: "looks good, ship it"),
            ChatMessage(sender: "Sofia Llorente", text: "I'll send the invoice Friday then we're done for the quarter"),
        ])
    }

    @Test("CF-60 Telegram inline 'Sender: text' lines are one message each")
    func telegramInlineSenders() {
        let capture = """
            Telegram
            Saved Messages
            Marco: dai ci vediamo alle 9
            Sofia: perfetto, porto io il vino
            """
        let messages = MessageParser.messages(in: capture, windowTitle: "Telegram Web - Google Chrome")
        #expect(messages == [
            ChatMessage(sender: "Marco", text: "dai ci vediamo alle 9"),
            ChatMessage(sender: "Sofia", text: "perfetto, porto io il vino"),
        ])
    }

    @Test("CF-60 a Discord handle header is a sender, a prose colon is not")
    func discordHandlesButNotProse() {
        // The separator is Discord's own em dash, written as an escape so it survives a
        // sweep of the prose: `MessageParser` peels exactly this character off the header.
        let capture = """
            marco_92 \u{2014} Today at 1:52 AM
            anyone up for ranked
            Note: server maintenance tonight
            """
        let messages = MessageParser.messages(in: capture, windowTitle: "Discord | #general")
        // "Note:" opens prose, not a person. It must fold into marco_92's text or vanish,
        // never mint a sender called "Note".
        #expect(messages.first == ChatMessage(sender: "marco_92", text: "anyone up for ranked Note: server maintenance tonight"))
        #expect(!messages.contains { $0.sender == "Note" })
    }

    // MARK: - Degradation

    @Test("CF-60 garbage on a chat surface degrades to the whole text with no sender")
    func garbageDegrades() {
        let garbage = "x9 !!zz 0-4-4 ,,,, plork ~~ 77"
        let messages = MessageParser.messages(in: garbage, windowTitle: Self.whatsAppTitle)
        #expect(messages == [ChatMessage(sender: nil, text: garbage)])
    }

    @Test("CF-60 a non-chat page degrades to the whole text with no sender")
    func nonChatPageDegrades() {
        // A news page mentions people followed by colons in exactly the way that would
        // tempt a naive parser into inventing senders.
        let article = """
            Il Corriere - Ultime notizie
            Allegri: la squadra ha dato tutto
            Il tecnico ha parlato dopo la partita di giovedì alle 20:45.
            """
        let messages = MessageParser.messages(in: article, windowTitle: "Il Corriere - Ultime notizie - Google Chrome")
        #expect(messages.count == 1)
        #expect(messages[0].sender == nil)
        #expect(messages[0].text.contains("Allegri"))
    }

    @Test("CF-60 a missing window title degrades rather than guessing a surface")
    func missingTitleDegrades() {
        let messages = MessageParser.messages(in: "Marco: ciao", windowTitle: nil)
        #expect(messages == [ChatMessage(sender: nil, text: "Marco: ciao")])
    }

    @Test("CF-60 empty input yields no messages at all")
    func emptyInput() {
        #expect(MessageParser.messages(in: "", windowTitle: Self.whatsAppTitle).isEmpty)
        #expect(MessageParser.messages(in: "  \n \n ", windowTitle: Self.whatsAppTitle).isEmpty)
    }

    @Test("CF-60 no parse ever invents a sender missing from the capture")
    func sendersComeFromTheCapture() {
        let messages = MessageParser.messages(in: Self.whatsAppCapture, windowTitle: Self.whatsAppTitle)
        for m in messages {
            guard let sender = m.sender else { continue }
            // Every sender string must appear verbatim in the capture (modulo the
            // collapsed double space in "Davide  Sartori"): attribution is read, not made.
            let squeezed = Self.whatsAppCapture.replacingOccurrences(of: "  ", with: " ")
            #expect(squeezed.contains(sender), "invented sender: \(sender)")
        }
    }
}
