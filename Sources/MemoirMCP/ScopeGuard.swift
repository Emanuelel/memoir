import Foundation
import MemoirKit

/// What this server refuses to look up, decided before any SQL runs.
///
/// The app refuses a question about a password, a phone call or yesterday's lunch before
/// it retrieves anything. This server did not. Measured on the real database:
///
///     recall("github password")        ran the search and returned rows
///     recall("what did I have for lunch")   returned two commitments about Live Mode and
///                                           a page redesign, under the heading
///                                           "What Memoir knows"
///
/// Nothing sensitive came back from the first one, because that corpus happens to be clean.
/// That is the corpus being lucky, not a guard holding. The second is the exact failure the
/// honesty group exists to catch, on the surface agents actually read from.
///
/// **Why these guards and not the others.** Memoir's guards divide by when they run, and
/// only one half can live here. The grounding guards (invented figures, unsupported
/// actions, fabricated hostnames) inspect an ANSWER, and this server never sees one. It
/// returns rows and its turn ends; the prose is written afterwards, in a client, with no
/// return path. Anything called a guard here would be checking text that does not exist yet.
///
/// What does port is the half that decides what is allowed to LEAVE the database. That half
/// matters more over MCP than it does in the app, because locally the material is shown to
/// the person whose screen it came from, and here it is transmitted.
///
/// **Why this one shares code when ``MemoirMemory/isAssistantConversation(_:)`` duplicates
/// it.** That convention is about not coupling to the writer's internals, so this server can
/// read a database it did not create. And it is right, because that guard knows the shape
/// of a capture. ``Grounding/hardRefusal(for:)`` and ``QuestionRouter/isStructurallyUnknowable(_:)``
/// are pure `String` predicates with no schema, no store and no model behind them, so
/// sharing them costs none of that independence. And a refusal is the wrong thing to keep
/// two copies of: copies drift, and the copy that drifts is the one that stops refusing.
enum ScopeGuard {

    /// The refusal to return instead of running the lookup, or nil to proceed.
    ///
    /// - Parameter text: the free-text argument the caller supplied (a query, a topic or a
    ///   claim). A tool with no free text (`today`, `working_set`, `timesheet`) has nothing
    ///   to guard: it cannot be pointed at anything.
    static func refusal(for text: String) -> String? {
        // Credentials, private browsing, incoming calls and messages, and predictions about
        // the future. Deterministic on purpose: "never reveal a credential" is a guarantee,
        // and a classifier that is right most of the time is not a guarantee.
        if let hard = Grounding.hardRefusal(for: text) { return hard }

        // …and then a stricter credential rule, because the app's is not enough HERE.
        //
        // `hardRefusal` matches question shapes: "my password", "password for", "what is my
        // login". That is right for the ask bar, where the input is a sentence. An MCP
        // argument is a SEARCH KEY. Measured against the real database after the port,
        // `recall("github password")` still ran and returned rows: it names a service and a
        // credential and contains no interrogative at all, so not one of those phrases fires.
        // Porting a guard is not the same as making it hold.
        if namesACredential(text) { return Grounding.credentialRefusal }

        // Money moved, food eaten, the body, the world outside the window. A screen-reading
        // memory has no record of any of it, and a keyword search will always find SOMETHING
        // to return, which is how a question about lunch came back with two commitments
        // about Live Mode.
        if QuestionRouter.isStructurallyUnknowable(text) { return Grounding.outOfScopeRefusal }

        return nil
    }

    /// True when a search key names a credential rather than a subject.
    ///
    /// Stricter than the app deliberately, and the asymmetry is the argument. In the ask bar
    /// a missed refusal shows the material to the person whose screen it came from; here it
    /// transmits it to whatever the connector is pointed at. Refusing "that article about
    /// password rotation" costs one rephrase and says why. The other error has no upper
    /// bound and cannot be taken back.
    ///
    /// So the noun decides, and only a phrase that makes the credential a TOPIC rescues it.
    /// That exception is short and closed on purpose: it exists for the handful of genuine
    /// memories about password hygiene, not to reopen the door by degrees.
    private static func namesACredential(_ text: String) -> Bool {
        let q = " " + text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: " ") + " "
        func says(_ phrases: [String]) -> Bool { phrases.contains { q.contains(" " + $0 + " ") } }

        let secrets = [
            "password", "passwords", "passcode", "passphrase", "credential", "credentials",
            "api key", "api keys", "apikey", "secret key", "private key", "access token",
            "auth token", "bearer token", "seed phrase", "recovery code", "recovery codes",
            "2fa code", "otp", "one time code", "pin code",
        ]
        guard says(secrets) else { return false }

        // A memory ABOUT credentials, rather than a credential. "The 1Password migration" and
        // "our password rotation policy" are things that were genuinely on screen and are
        // perfectly good things to remember.
        let asATopic = [
            "manager", "managers", "management", "policy", "policies", "rotation", "hygiene",
            "article", "blog", "post", "docs", "documentation", "guide", "talk", "thread",
            "1password", "bitwarden", "lastpass", "dashlane", "keychain", "vault ui",
            "migration", "reset flow", "strength", "breach",
        ]
        return !says(asATopic)
    }

    /// Wraps a refusal so the calling agent knows the tool declined rather than found
    /// nothing. "No results" invites a rephrase and a second attempt at the same lookup;
    /// naming the limit ends the line of enquiry, which is the point of refusing.
    static func message(_ refusal: String) -> String {
        """
        \(refusal)

        _Memoir declined this lookup rather than searching. This is a limit of what a \
        screen-reading memory can know, not an empty result. Rephrasing will not help._
        """
    }
}
