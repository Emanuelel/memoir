import Foundation

/// What the journal offers you instead of a blank page.
///
/// ## Why this is not in the view
///
/// It started in `JournalModel`, where it could not be tested and where the rule it enforces was
/// invisible: **the invitation may never disclose.** The band says the general form of this out
/// loud, possibly in a room with other people in it, so the exact words are a product decision
/// with a test on them rather than a string literal in a SwiftUI file.
///
/// The specific prompt is the advantage this product has over every other journalling app: it
/// already knows what the day looked like, so it can name the thing and leave the person to say
/// what it meant. The general one is what keeps the promise on a day it knows nothing.
public enum JournalPrompt {

    /// The invitation. Shown in the composer on a quiet day, and the only form the band is ever
    /// allowed to speak.
    ///
    /// Every word here is deliberate:
    ///
    /// - **No disclosure.** It carries no information about the user at all. *"You were on the
    ///   listings again"* is true, is far more compelling, and is a sentence that must wait until
    ///   the user has opened the app themselves.
    /// - **No count and no streak.** It does not know or care whether anything was written
    ///   yesterday, and it reads identically after a year of silence. Streak mechanics are how
    ///   journalling apps turn into guilt, and guilt is catastrophic in a product about somebody's
    ///   own life.
    /// - **"Anything"**, not "what". A question that can be answered with nothing.
    public static let invitation = "Anything you want to keep from today?"

    /// Turns the day into something worth answering.
    ///
    /// Never "how was your day". Falls back to ``invitation`` rather than to nothing: it used to
    /// return nil whenever no single stretch passed fifteen minutes, so a day off, a day of short
    /// scattered work, or any day before capture had warmed up showed an empty composer, on the
    /// one surface whose entire claim is that the page is never blank.
    public static func forToday(spans: [WorkSpan]) -> String {
        guard let longest = spans.max(by: { $0.seconds < $1.seconds }), longest.seconds > 900 else {
            return invitation
        }
        let minutes = Int(longest.seconds / 60)
        let howLong = minutes >= 60
            ? "\(minutes / 60)h\(String(format: "%02d", minutes % 60))"
            : "\(minutes) minutes"
        return "\(howLong) on \(longest.label) today. Anything worth keeping about it?"
    }
}
