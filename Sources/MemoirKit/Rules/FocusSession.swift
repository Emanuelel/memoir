import Foundation

/// The shape of a focus-timer row, kept after the feature was removed.
///
/// Memoir had a pomodoro timer. It is gone: it was a productivity feature in a product about
/// a life, it competed for the one column the band has, and the whole of it (a ring, a
/// countdown, two chat verbs, a stat) served a thing no memory needs.
///
/// What stays is the **recognition**, because the rows are still in people's databases. A focus
/// run was recorded as an ordinary `Session` under a synthetic bundle id, and every path that
/// sums app time asks this type to exclude them. Delete it and three sessions on the database
/// this was written against stop being a timer and start being an app called Focus that
/// somebody apparently used for an hour.
///
/// Nothing writes one of these any more. Nothing should.
public enum FocusSession {

    /// The synthetic bundle id focus rows were recorded under.
    public static let bundleID = "sh.memoir.focus"

    /// The bundle id focus rows were written under before the app was renamed.
    ///
    /// Not a leftover: it names session rows **already in people's databases**. Deleting it
    /// does not remove a reference to an old name, it silently drops sessions out of their day.
    public static let legacyBundleID = "sh.pip.focus"

    /// The app name focus rows were recorded under.
    public static let appName = "Focus"

    /// True when a session row is one of Memoir's own focus runs, whichever name it
    /// was recorded under.
    public static func isFocusRow(_ session: Session) -> Bool {
        session.appBundleID == bundleID || session.appBundleID == legacyBundleID
    }
}
