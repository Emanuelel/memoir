//
//  Fixtures.swift
//  Realistic on-screen text, and the world it makes.
//

import Foundation
import MemoirKit

// MARK: - Fixtures

/// Realistic on-screen text, not lorem ipsum.
///
/// Every builder returns a `CaptureEvent` whose
/// - `id` is derived from the fixture name and timestamp, so it is stable across runs;
/// - `ts` is whatever you inject, defaulting to ``TestClock/reference``;
/// - `textHash` is the real `AccessibilityCapture.textHash` of the text, so dedupe behaves
///   exactly as it does in production (CF-11, CF-12).
///
/// What each one is *for*:
///
/// | fixture           | contains                                                        |
/// |-------------------|-----------------------------------------------------------------|
/// | `slackThread`     | 4 people, 2+ commitments, "by Friday" and "tomorrow morning", a decision, `#eng-platform` |
/// | `email`           | From/To/Cc/Subject headers, an "Action item", `ACME-418`          |
/// | `standupNotes`    | owner bullets, `ACME-412` / `ACME-418` / `ACME-431`, a TODO       |
/// | `terminalSession` | build and shell noise, deliberately entity-free                   |
/// | `codeReview`      | PR discussion, `acme-corp/platform`, an agreement, a Friday cut   |
public enum Fixtures {

    // MARK: Builders

    /// The generic builder every fixture goes through. Use it for one-off text.
    ///
    /// - Parameters:
    ///   - text: the on-screen text.
    ///   - app: display name of the app.
    ///   - bundleID: bundle identifier.
    ///   - windowTitle: focused window title, or nil.
    ///   - at: the capture timestamp. Always injected.
    ///   - name: seeds the stable id. Give distinct names to distinct fixtures.
    public static func capture(
        text: String,
        app: String,
        bundleID: String,
        windowTitle: String?,
        at ts: Date,
        name: String,
        visibleText: String? = nil
    ) -> CaptureEvent {
        CaptureEvent(
            id: TestID.stable("capture", name, String(ts.timeIntervalSince1970)),
            ts: ts,
            appBundleID: bundleID,
            appName: app,
            windowTitle: windowTitle,
            text: text,
            textHash: AccessibilityCapture.textHash(text),
            visibleText: visibleText
        )
    }

    /// A multi-person Slack conversation carrying two clear commitments in two different
    /// date forms ("by Friday" and "tomorrow morning") plus a decision and a channel.
    public static func slackThread(at ts: Date = TestClock.reference) -> CaptureEvent {
        capture(
            text: slackThreadText,
            app: "Slack",
            bundleID: "com.tinyspeck.slackmacgap",
            windowTitle: "#eng-platform - Acme",
            at: ts,
            name: "slackThread"
        )
    }

    /// An email with real headers and an explicit action item.
    public static func email(at ts: Date = TestClock.reference) -> CaptureEvent {
        capture(
            text: emailText,
            app: "Mail",
            bundleID: "com.apple.mail",
            windowTitle: "Q2 platform review agenda",
            at: ts,
            name: "email"
        )
    }

    /// Standup bullets with named owners and ticket keys.
    public static func standupNotes(at ts: Date = TestClock.reference) -> CaptureEvent {
        capture(
            text: standupNotesText,
            app: "Notes",
            bundleID: "com.apple.Notes",
            windowTitle: "Standup 16 March",
            at: ts,
            name: "standupNotes"
        )
    }

    /// Shell output. Mostly noise on purpose: it proves extraction does not invent people
    /// or commitments out of build logs and directory listings.
    public static func terminalSession(at ts: Date = TestClock.reference) -> CaptureEvent {
        capture(
            text: terminalSessionText,
            app: "Terminal",
            bundleID: "com.apple.Terminal",
            windowTitle: "zsh",
            at: ts,
            name: "terminalSession"
        )
    }

    /// A pull request discussion: a review request, a promise, an agreement, a release cut.
    public static func codeReview(at ts: Date = TestClock.reference) -> CaptureEvent {
        capture(
            text: codeReviewText,
            app: "Google Chrome",
            bundleID: "com.google.Chrome",
            windowTitle: "Add rate limiter backoff by priya-r - Pull Request #482 - acme-corp/platform",
            at: ts,
            name: "codeReview"
        )
    }

    /// All five fixtures, six minutes apart, oldest first, starting at `start`.
    ///
    /// Order: slack, email, standup, terminal, code review.
    public static func all(startingAt start: Date = TestClock.reference) -> [CaptureEvent] {
        [
            slackThread(at: start),
            email(at: TestClock.minutes(6, from: start)),
            standupNotes(at: TestClock.minutes(12, from: start)),
            terminalSession(at: TestClock.minutes(18, from: start)),
            codeReview(at: TestClock.minutes(24, from: start)),
        ]
    }

    // MARK: Text

    public static let slackThreadText = """
    Priya Raman  10:04
    Heads up, the staging deploy is blocked on the new rate limiter. I'll have the fix merged and deployed by Friday so QA gets a clean build.

    Marco Bianchi  10:06
    Thanks Priya. Can you also drop the migration notes in here once it lands?

    Priya Raman  10:07
    Yes. I will write up the migration notes tomorrow morning and post them in this channel.

    Tom Okafor  10:11
    We decided to hold the pricing page rollout until the rate limiter is stable in staging.

    Marco Bianchi  10:13
    Works for me. Let's walk through it together at the Thursday sync.
    """

    public static let emailText = """
    From: Elena Rossi
    To: Marco Bianchi
    Cc: Priya Raman
    Subject: Q2 platform review agenda

    Hi Marco,

    Quick one ahead of the review. I'll circulate the updated agenda by Wednesday so nobody is reading it cold in the room.

    Action item for you: confirm the final headcount numbers for the platform team before the review. Finance is holding ACME-418 open until they land.

    Thanks,
    Elena
    """

    public static let standupNotesText = """
    Standup notes

    Priya
    - Rate limiter shipped behind a flag, ACME-412 moves to review.
    - Finishing the migration script, will hand it over by Thursday.

    Marco
    - ACME-418 headcount rollup is still blocked on Finance.
    - TODO: chase Elena for the final numbers before the review.

    Tom
    - Pricing page rollout paused, tracked in ACME-431.
    - I'll write the rollback runbook tomorrow.
    """

    public static let terminalSessionText = """
    $ swift build
    [3/12] Compiling MemoirKit Store.swift
    [7/12] Compiling MemoirKit RuleExtractor.swift
    Build complete! (4.11s)
    $ swift test 2>&1 | tail -4
    Test Suite 'All tests' passed at 11:02:44.118
    Executed 41 tests, with 0 failures (0 unexpected) in 2.317 seconds
    $ du -sh .build
    612M    .build
    $ ls -la
    total 96
    drwxr-xr-x  14 user  staff   448 10:58 .
    -rw-r--r--   1 user  staff  8196 09:01 .DS_Store
    $ echo $?
    0
    """

    public static let codeReviewText = """
    acme-corp/platform #482
    Add rate limiter backoff

    marco-b commented 2 hours ago
    Nice. One thing, the retry budget is per process, so a burst across three workers still gets through. Can you make the budget shared before we merge this?

    priya-r commented 1 hour ago
    Good catch. I'll move the budget into Redis and push an update tomorrow.

    tom-okafor commented 44 minutes ago
    We agreed to keep the flag default off until ACME-412 is verified in staging.

    marco-b commented 20 minutes ago
    Approving once the shared budget lands. Let's not ship this before the release cut on Friday.
    """
}
