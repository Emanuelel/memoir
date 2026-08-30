import Foundation

/// The pseudo-apps that imported history is recorded under, and the one rule that applies to all
/// of them: **time-based retention does not touch them.**
///
/// ## Why they are exempt
///
/// Retention exists because captured screen text accumulates without anyone deciding it should.
/// A window you glanced at in 2019 is not something you chose to keep, so a user who sets a
/// ninety-day window is asking for the incidental record of their screen to expire.
///
/// Imported rows are the opposite of incidental. They are the decade: the whole reason the
/// import exists is to reach back further than capture can, and they are dated by when the thing
/// *happened*, not by when Memoir read it. Sweeping by timestamp therefore deletes exactly the
/// history that was just imported, and it does it the first time anybody sets a window at all.
///
/// The second argument is the one that settles it: deleting them protects nothing. The contact is
/// still in Contacts, the event is still in the calendar, the photograph is still in the library,
/// the note is still in the vault. Memoir's copy expiring reduces no exposure that the original
/// does not already carry. So the sweep costs the user their decade and buys them nothing.
///
/// ## What this is not
///
/// Not a way to keep things the user asked to be rid of. Deleting a memory in the Memories
/// browser still deletes it, excluding an app still purges what it recorded
/// (`purge(fromBundleIDs:)`), and "delete everything" still means everything. This
/// exemption is specific to the *time* sweep, which is a housekeeping rule about accumulation,
/// not a deletion the user asked for.
public enum ImportedSource {

    /// Every pseudo-app whose rows are imported history rather than captured screen text.
    ///
    /// Adding an import source means adding it here. The consequence of forgetting is silent and
    /// slow: the source works, and then a user sets a retention window months later and loses
    /// that history alone while the others survive.
    public static let bundleIDs: Set<String> = [
        LifeImporter.contactsBundleID,
        LifeImporter.calendarBundleID,
        PhotoImporter.bundleID,
        VaultImporter.bundleID,
    ]

    /// True when this capture came from an import rather than from the screen.
    public static func isImported(bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }
}
