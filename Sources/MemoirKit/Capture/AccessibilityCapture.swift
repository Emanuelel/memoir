import Foundation
import ApplicationServices
import CoreGraphics
import CryptoKit

/// Reads on-screen *text* through the macOS accessibility API.
///
/// One `snapshot()` does this, in order:
/// 1. Verifies Accessibility trust. Without it, throws ``MemoirError/accessibilityPermissionDenied``.
/// 2. Finds the frontmost app (`NSWorkspace`, no permission needed).
/// 3. Bails out for Memoir itself and for any bundle identifier in ``CaptureConfig/excludedBundleIDs``.
/// 4. Walks the accessibility tree from the system-wide focused element and the focused window,
///    collecting `AXValue` / `AXTitle` / `AXDescription` / `AXSelectedText` strings.
/// 5. Deduplicates against the previous capture by SHA-256 of the normalised text.
///
/// The walk is bounded four ways (depth 12, 2000 nodes, 20 000 characters, and a 400 ms
/// wall-clock deadline), with a 600 ms watchdog behind all of it. It runs on a private dispatch
/// queue, never on the cooperative thread pool and never on the main actor, so a wedged app can
/// slow a snapshot but can never stall the UI or the Swift concurrency runtime.
///
/// Secure text fields (`AXSecureTextField`) are skipped along with their subtrees. Text is never
/// sent anywhere: it goes to the local SQLite file and nowhere else.
public actor AccessibilityCapture: CaptureSource {

    /// Current tuning. Mutable so Settings can change the interval or exclusions live.
    private var config: CaptureConfig

    /// Hash of the last capture that was returned, for dedupe.
    private var lastHash: String?

    /// Bundle identifier of the host process, so Memoir never reads its own windows.
    private let ownBundleID: String?

    /// Creates a capture source with the given configuration.
    public init(config: CaptureConfig) {
        self.config = config
        self.ownBundleID = Bundle.main.bundleIdentifier
    }

    /// Replaces the configuration. Takes effect on the next snapshot.
    public func updateConfig(_ config: CaptureConfig) {
        self.config = config
    }

    /// The configuration currently in force.
    public func currentConfig() -> CaptureConfig { config }

    /// Forgets the dedupe hash, so the next identical screen is captured again.
    public func resetDedupe() {
        lastHash = nil
    }

    /// Reads the screen once.
    ///
    /// - Returns: a ``CaptureEvent``, or `nil` when there is nothing worth storing:
    ///   no frontmost app, an excluded app, empty text, or text identical to the last capture.
    /// - Throws: ``MemoirError/accessibilityPermissionDenied`` when the process is not trusted.
    ///   Nothing else is ever thrown: a failed accessibility read degrades to `nil`.
    public func snapshot() async throws -> CaptureEvent? {
        guard Permissions.hasAccessibility() else {
            throw MemoirError.accessibilityPermissionDenied
        }
        guard let front = FrontmostApp.current() else { return nil }
        if let ownBundleID, front.bundleID == ownBundleID { return nil }
        guard !config.isExcluded(front.bundleID) else {
            Log.shared.debug("capture skipped, excluded app \(front.bundleID)")
            return nil
        }

        let wantsTitle = config.captureWindowTitles
        let maxChars = config.effectiveMaxTextLength
        let scrape = await Self.scrape(pid: front.pid, maxCharacters: maxChars, wantsWindowTitle: wantsTitle)

        let event = admit(rawText: scrape.text, rawVisibleText: scrape.visibleText, app: front, now: Date()) {
            scrape.windowTitle ?? Self.windowTitleFromWindowList(pid: front.pid)
        }

        if event != nil, scrape.hitLimit {
            Log.shared.debug("capture hit a walk limit in \(front.bundleID) after \(scrape.nodesVisited) nodes")
        }

        return event
    }

    /// Everything that happens *after* the accessibility boundary: trim, truncate, hash,
    /// dedupe against the previous capture, and build the row.
    ///
    /// ``snapshot()`` is exactly this plus the tree walk that produces `rawText`, so driving
    /// this directly exercises the real dedupe gate, the part that once froze the capture
    /// count (CF-11), without needing a granted Accessibility permission or a window server.
    ///
    /// - Parameters:
    ///   - rawText: the strings the walk collected, joined. May be empty.
    ///   - app: the app the text was read from.
    ///   - now: the capture timestamp. Injected so it is never the wall clock in a test.
    ///   - windowTitle: resolved lazily, and only when ``CaptureConfig/captureWindowTitles``
    ///     is on **and** the text survived the dedupe gate: the fallback behind it can be an
    ///     expensive window-server call, and it must not run on every poll.
    /// - Returns: a ``CaptureEvent``, or `nil` when the text is empty or identical to the
    ///   previous capture's.
    /// The subject, chosen from labelled controls and where they sit.
    ///
    /// Split out from the accessibility reads for the reason `BoundedTextWalk` is generic
    /// over its node type: the tree cannot be built in a test process, and the part worth
    /// pinning is the choice, not the plumbing.
    ///
    /// Topmost wins. "The first named control inside the main landmark" read back "Bypass
    /// permissions (Opus 5)": the composer's mode and model pickers, reached before the
    /// header because tree order is not screen order. A document's name sits at the top of
    /// its pane and the controls for typing sit at the bottom, which geometry knows and the
    /// tree's shape does not.
    static func paneSubject(from candidates: [(label: String, x: CGFloat, y: CGFloat)]) -> String? {
        guard let header = candidates.min(by: { ($0.y, $0.x) < ($1.y, $1.x) }) else { return nil }

        // Anything else the user named on the same row: in Claude that is the project the
        // conversation belongs to. Same row means within a line's height of the title.
        let sameRow = candidates
            .filter { $0.label != header.label && abs($0.y - header.y) <= 12 && $0.x > header.x }
            .min { $0.x < $1.x }
        return sameRow.map { "\(header.label) (\($0.label))" } ?? header.label
    }

    /// Whether a window title marks a private-browsing session.
    ///
    /// Every major browser advertises this in the window title, in the user's own language.
    /// Matching the title is cruder than asking the browser, but it needs no per-browser
    /// integration and it fails safe: an unrecognised phrase means we capture, so this can
    /// only ever be extended, never silently break capture.
    static func isPrivateBrowsing(_ title: String) -> Bool {
        let t = title.lowercased()
        return [
            "incognito",            // Chrome, Brave, Edge (en)
            "private browsing",     // Firefox, Safari
            "(private)",            // Safari window suffix
            "inprivate",            // Edge
            "navigazione in incognito", "navigazione privata",   // it
            "navigation privée", "navigation privee",            // fr
            "modo incógnito", "modo incognito", "ventana privada", // es
            "privates fenster", "inkognito",                     // de
            "privé-venster", "incognitovenster",                 // nl
        ].contains { t.contains($0) }
    }

    /// True when the text almost certainly contains a login / verification / OTP code.
    ///
    /// Deliberately errs toward dropping: a false positive costs one skipped capture, a
    /// false negative stores a security code forever. Matches the common phrasings in
    /// English and Italian (the user's SMS were Italian) plus a bare code near "code".
    static func looksLikeSecret(_ text: String) -> Bool {
        let lower = text.lowercased()
        let phrases = [
            "verification code", "verify code", "one-time", "one time code", "otp",
            "security code", "2fa", "two-factor", "authentication code", "login code",
            "codice di verifica", "codice di sicurezza", "codice di accesso",
            "codice otp", "inserisci il codice", "non condividere questo codice",
            "do not share this code", "your code is",
        ]
        if phrases.contains(where: lower.contains) { return true }
        // "code" / "codice" within ~20 chars of a 4–8 digit number.
        if Self.secretCodeRegex.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)) != nil { return true }
        return false
    }

    private static let secretCodeRegex = try! NSRegularExpression(
        pattern: "(?i)(code|codice|pin)\\D{0,20}\\b\\d{4,8}\\b|\\b\\d{4,8}\\b\\D{0,20}(code|codice)")

    /// Any run of 4–8 digits, which is the shape of every code this guard exists for.
    private static let codeShapedDigits = try! NSRegularExpression(pattern: "\\b\\d{4,8}\\b")

    /// Below this, a screen that mentions a code is assumed to BE the code: an SMS, a banner,
    /// an OTP page. Above it, the code is one line on a screen full of other work.
    private static let codeScreenCharacters = 400

    /// The text with any code-shaped number removed, or nil when the screen is only a code.
    ///
    /// Blunt on purpose. Once a screen has said "code" next to a number, every 4–8 digit run
    /// on it is suspect, and the cost of over-redacting is a lost figure while the cost of
    /// under-redacting is a stored credential. It costs nothing on screens that never
    /// mention a code, which is nearly all of them.
    static func withoutSecrets(_ text: String) -> String? {
        guard looksLikeSecret(text) else { return text }
        guard text.count > codeScreenCharacters else { return nil }
        return redactingCodes(text)
    }

    /// The visible slice with any line that is not in `text` removed.
    ///
    /// ``CaptureEvent/visibleText`` promises to be a subset, and only `text` is indexed for
    /// search, so a line here that is not there is a citation to something the memory cannot
    /// find and does not contain. Enforced at construction rather than assumed, because the
    /// first thing that broke it was arithmetic two files away: the walk budgeted its
    /// character ceiling by summing piece lengths while `text` was those pieces joined with
    /// newlines, so the join overshot, the tail was truncated off `text`, and the visible
    /// slice (comfortably under the limit) kept it. That is fixed where it happened, and
    /// this is here so the guarantee does not depend on it staying fixed.
    static func onlyWhatSurvivedIn(_ text: String, _ visible: String) -> String {
        guard !visible.isEmpty, !text.contains(visible) else { return visible }
        return visible
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.isEmpty || text.contains($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every code-shaped run of digits replaced, unconditionally.
    ///
    /// Split out of ``withoutSecrets(_:)`` so the on-screen slice can be put through the same
    /// blunt instrument. It is a subset of text that has already been judged to be about a
    /// code, so it inherits the judgement rather than being re-tested: on its own it can be
    /// short enough to look like a code-only screen, and re-running the whole rule would
    /// throw away the visible text of a perfectly storable capture.
    static func redactingCodes(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return codeShapedDigits.stringByReplacingMatches(
            in: text, range: range, withTemplate: "[redacted]"
        )
    }

    func admit(
        rawText: String,
        rawVisibleText: String? = nil,
        app: FrontmostApp,
        now: Date,
        windowTitle: @Sendable () -> String?
    ) -> CaptureEvent? {
        let text = Self.trimmed(rawText, limit: config.effectiveMaxTextLength)
        guard !text.isEmpty else { return nil }

        // Private browsing is an explicit request not to be remembered. Honour it.
        //
        // The browser only stops recording its OWN history; nothing stops an accessibility
        // reader. Screenpipe documents this and records incognito anyway. Memoir should not:
        // a memory that quietly keeps what you deliberately browsed in private is a
        // liability, and it is the single clearest signal a user can give about intent.
        if let title = windowTitle(), Self.isPrivateBrowsing(title) {
            Log.shared.debug("capture dropped, private browsing window in \(app.bundleID)")
            return nil
        }

        // Never store a one-time code. Do not throw away the screen it appeared on (CF-101).
        //
        // The rule is right and stays: a memory that has read your 2FA codes is a liability.
        // Dropping the whole capture to enforce it was the disproportionate part, and it was
        // invisible only because it never fired on anything that mattered, until the walk
        // started returning real screens. On a developer's machine "code" sits within twenty
        // characters of a four-digit number more or less permanently, so every rich capture
        // of an editor or an assistant was being discarded whole: 20,366 characters of work
        // thrown away because the text said "code" near "1485".
        //
        // So the digits go and the screen stays. A screen that is nothing BUT a code (a
        // short banner, an SMS, an OTP page) is still dropped outright, because there is
        // nothing else on it worth keeping and a redacted husk is not worth storing.
        // Whether the redaction below fired, so the same can be done to the visible slice.
        // A subset of a screen that has been judged to be about a code carries the same
        // digits, and storing it unredacted would put back exactly what was just removed.
        let carriedSecrets = Self.looksLikeSecret(text)
        guard let text = Self.withoutSecrets(text) else {
            Log.shared.debug("capture dropped, the screen is a verification code in \(app.bundleID)")
            return nil
        }

        let hash = Self.textHash(text)
        guard hash != lastHash else { return nil }
        lastHash = hash

        let visible = rawVisibleText
            .map { Self.trimmed($0, limit: config.effectiveMaxTextLength) }
            .map { carriedSecrets ? Self.redactingCodes($0) : $0 }
            .map { Self.onlyWhatSurvivedIn(text, $0) }

        return CaptureEvent(
            ts: now,
            appBundleID: app.bundleID,
            appName: app.name,
            windowTitle: config.captureWindowTitles ? windowTitle() : nil,
            text: text,
            textHash: hash,
            visibleText: visible
        )
    }

    // MARK: - Hashing

    /// SHA-256, hex encoded, of the whitespace-normalised lowercased text. This is the dedupe key.
    public nonisolated static func textHash(_ text: String) -> String {
        let normalized = text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Trims and hard-truncates collected text to the configured ceiling.
    private nonisolated static func trimmed(_ text: String, limit: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > limit else { return t }
        return String(t.prefix(limit))
    }

    // MARK: - Window title fallback

    /// Window title via the window server, used only when the accessibility read came back empty.
    ///
    /// `kCGWindowName` is only populated for processes holding Screen Recording permission;
    /// without it this returns `nil` and the capture simply has no window title.
    private nonisolated static func windowTitleFromWindowList(pid: pid_t) -> String? {
        guard Permissions.hasScreenRecording() else { return nil }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in raw {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner == pid else { continue }
            if let layer = window[kCGWindowLayer as String] as? Int, layer != 0 { continue }
            if let name = window[kCGWindowName as String] as? String,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return name
            }
        }
        return nil
    }

    // MARK: - Off-thread scrape

    /// Runs the bounded accessibility walk on a private queue and returns plain `Sendable` values.
    ///
    /// A watchdog resumes the caller after ``CaptureLimits/watchdogSeconds`` even if the walk is
    /// still blocked inside an accessibility message, so a snapshot can never hang.
    private nonisolated static func scrape(
        pid: pid_t,
        maxCharacters: Int,
        wantsWindowTitle: Bool
    ) async -> AXScrapeResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<AXScrapeResult, Never>) in
            let box = ContinuationBox(continuation)
            axScrapeQueue.async {
                let result = AXScraper.run(
                    pid: pid,
                    maxCharacters: maxCharacters,
                    wantsWindowTitle: wantsWindowTitle
                )
                box.resume(result)
            }
            axScrapeQueue.asyncAfter(deadline: .now() + CaptureLimits.watchdogSeconds) {
                box.resume(
                    AXScrapeResult(
                        text: "", visibleText: nil, windowTitle: nil, nodesVisited: 0, hitLimit: true
                    )
                )
            }
        }
    }
}

// MARK: - Scrape plumbing

/// Concurrent queue for accessibility work. Concurrent so a wedged app cannot back up the next
/// snapshot behind it. Accessibility reads are blocking C calls and must stay off the
/// cooperative thread pool.
private let axScrapeQueue = DispatchQueue(
    label: "sh.memoir.capture.accessibility",
    qos: .utility,
    attributes: .concurrent
)

/// Result of one accessibility walk. Plain values only, so it crosses back to the actor freely.
private struct AXScrapeResult: Sendable {
    /// Collected on-screen text, newline separated, already deduplicated within the snapshot.
    let text: String
    /// The substantial blocks of `text` that were inside the window's frame, or nil when the
    /// frame could not be resolved and the question was never asked.
    let visibleText: String?
    /// Focused window title, if the accessibility API gave one up.
    let windowTitle: String?
    /// How many elements the walk touched.
    let nodesVisited: Int
    /// True when a depth / node / character / time limit stopped the walk early.
    let hitLimit: Bool
}

/// One-shot, thread-safe holder that guarantees a continuation is resumed exactly once,
/// no matter whether the walk or the watchdog gets there first.
private final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// The bounded accessibility-tree walk. Pure synchronous C calls; no shared mutable state.
private enum AXScraper {

    /// Walks the focused element and focused window of `pid`, collecting text within all limits.
    static func run(pid: pid_t, maxCharacters: Int, wantsWindowTitle: Bool) -> AXScrapeResult {
        let deadline = CFAbsoluteTimeGetCurrent() + CaptureLimits.deadlineSeconds

        let systemWide = AXUIElementCreateSystemWide()
        // Setting the timeout on the system-wide element makes it the default for every element
        // this process creates, which is what keeps one unresponsive app from stalling the walk.
        _ = AXUIElementSetMessagingTimeout(systemWide, CaptureLimits.messagingTimeoutSeconds)

        // Electron apps expose nothing until asked. Cached per process, so this is a no-op
        // on the overwhelming majority of walks.
        requestManualAccessibility(pid: pid)

        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, CaptureLimits.messagingTimeoutSeconds)

        // The focused window is not always the window with the content in it.
        //
        // A browser extension's popup — 174 characters, no page in it — held
        // `AXFocusedWindow` for twenty-four minutes on a real machine. The title never
        // changed, so no capture triggered; the idle fallback fired and the walk returned the
        // same popup, which the dedupe correctly threw away. Twenty-four minutes of browsing
        // recorded as one sighting of an extension menu. Measured across the clean corpus:
        // 1.45 hours over eight days, in sessions of 25, 22 and 18 minutes holding two or
        // three captures each.
        //
        // Exactly the shape of the composer bug fixed above it: the walk was handed a small
        // true thing and finished, while the screen sat unread in the same process. Popups,
        // permission bubbles, find bars and tooltips are all focusable and none of them is
        // what the user was looking at.
        //
        // So the main window is consulted too. When the focused window has no document in it
        // and the main window does, the main window IS the content window — for the title as
        // well as for the text, because the title is what the matcher reads first, and the
        // popup's own title would otherwise name the hour.
        let focused = element(app, kAXFocusedWindowAttribute)
        let main = element(app, kAXMainWindowAttribute)
        let focusedWebAreas = focused.map { findWebAreas(in: $0) } ?? []
        let mainWebAreas = (main != nil && !sameElement(main, focused))
            ? findWebAreas(in: main!) : []
        let preferMain = focusedWebAreas.isEmpty && !mainWebAreas.isEmpty

        let focusedWindow = preferMain ? main : (focused ?? main)
        let webAreas = preferMain ? mainWebAreas : focusedWebAreas

        var windowTitle: String? = nil
        if wantsWindowTitle, let focusedWindow {
            windowTitle = nonEmpty(string(focusedWindow, kAXTitleAttribute))
        }

        var roots: [AXUIElement] = []
        if let focused = element(systemWide, kAXFocusedUIElementAttribute) { roots.append(focused) }

        // Prefer the web page over the browser wrapped around it.
        //
        // Walking a browser window from the top collects the whole of its furniture first:
        // "Back Forward Reload View site information ... LastPass Has access to this site".
        // That filled most of every capture before any actual page text. Chromium and
        // WebKit both expose the document under an AXWebArea node; starting there skips the
        // chrome entirely and gets what the user was actually reading.
        // The richest web areas first, and then the window regardless.
        //
        // Finding a web area used to mean the window was never walked at all, so one unlucky
        // pick made the whole screen invisible: 1,344 captures of the Claude desktop app,
        // almost all of them 26 characters of composer placeholder, while the conversation
        // sat unread in the same tree. No limit was hit and nothing failed: the walk was
        // handed a text box and finished.
        //
        // The window is a safety net rather than a cost. It goes last, so a browser still
        // gets its document before its furniture, and the walk's own dedupe collapses
        // everything the web area already returned.
        if let focusedWindow {
            for web in webAreas.reversed() {
                roots.insert(web, at: 0)
            }
            roots.append(focusedWindow)
            // And the other window last, as a further safety net. If the chosen window already
            // filled the walk's budget this contributes nothing; if the choice above was wrong
            // in the other direction, the screen is still recorded.
            if let other = preferMain ? focused : main, !sameElement(other, focusedWindow) {
                roots.append(other)
            }
        }
        if roots.isEmpty, let focusedApp = element(systemWide, kAXFocusedApplicationAttribute) {
            roots.append(focusedApp)
        }

        // What the walk was actually given, before it walks it.
        //
        // The Claude desktop app returned 26-character captures ("Type / for commands", the
        // composer placeholder) while the conversation heading sat in its tree the whole
        // time, an `AXValue` on a Static Text this walk reads. Nothing in the log explained
        // it: no limit was hit, so the walk was not being truncated, it was finishing because
        // the subtree it was handed was tiny.
        //
        // Two rounds of that were spent inferring the traversal from its output, and one of
        // the inferences was wrong. A capture that cannot say what it looked at cannot be
        // debugged from the outside, so it says.
        Log.shared.debug(
            "capture roots for pid \(pid): "
                + roots.map { "\(string($0, kAXRoleAttribute) ?? "?")(\(children($0).count) children)" }
                    .joined(separator: " + ")
        )

        dumpTreeIfRequested(roots: roots, pid: pid)

        // A title bar that only repeats the application's name has told us nothing, and some
        // apps never put anything else there. Ask the main landmark what it is showing
        // instead (CF-111). Only then, so the cost falls on the apps that need it.
        if wantsWindowTitle,
           windowTitle == nil
            || windowTitle?.caseInsensitiveCompare(string(app, kAXTitleAttribute) ?? "\u{0}") == .orderedSame {
            if let subject = mainPaneSubject(roots: roots) {
                windowTitle = subject
            }
        }

        // What "on screen" means for this snapshot.
        //
        // A capture is the accessibility tree, and the tree is not the screen. A virtualised
        // feed keeps a band of mounted cells around the viewport (LinkedIn was holding four
        // scrolled-past posts above the one being read), and a document holds every page of
        // itself no matter where it is scrolled to. Flattened into one blob none of that can
        // be told apart, which is how a memory that had the post ended up unable to say which
        // post it was.
        //
        // Geometry is the signal the tree's shape does not carry, and it is the same argument
        // `mainPaneSubject` makes for reading a heading off position instead of tree order.
        // The document's own frame is preferred over the window's so a browser's toolbar and
        // tab strip fall outside the viewport rather than counting as on screen.
        let viewport = roots.first.flatMap { root -> CGRect? in
            string(root, kAXRoleAttribute) == "AXWebArea" ? frame(root) : nil
        } ?? focusedWindow.flatMap { frame($0) }

        // The traversal and all four ceilings live in `BoundedTextWalk`, which is generic over
        // the node type so the limits can be exercised against a synthetic tree. Only the
        // accessibility-specific reads are supplied here.
        let outcome = BoundedTextWalk.run(
            roots: roots,
            limits: TextWalkLimits.standard(
                maxCharacters: maxCharacters,
                isOutOfTime: { CFAbsoluteTimeGetCurrent() >= deadline }
            ),
            isSecure: { node in
                string(node, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
            },
            texts: { node in
                // Furniture carries text too: button labels, menu items, extension names.
                // It is navigation, not something the user read, and it used to dominate
                // every browser capture. Skip the node's own text but keep descending, since
                // a container's children can still hold real content.
                if let role = string(node, kAXRoleAttribute), chromeRoles.contains(role) {
                    return []
                }
                return textAttributes.compactMap { nonEmpty(string(node, $0)) }
            },
            children: { node in
                children(node)
            },
            isOnScreen: { node in
                guard let viewport else { return false }
                guard let frame = frame(node) else { return false }
                return frame.intersects(viewport)
            }
        )

        // And what it found, so a thin capture can be told from a thin screen.
        Log.shared.debug(
            "capture walk for pid \(pid): \(outcome.nodesVisited) nodes, depth \(outcome.deepestVisited), "
                + "\(outcome.text.count) chars\(outcome.hitLimit ? ", hit a limit" : "")"
                + ", \(outcome.visibleText.count) on screen"
                + (viewport == nil ? " (no viewport)" : "")
                + (outcome.geometryExhausted ? ", geometry budget spent" : "")
        )

        // No viewport means the question was never asked, which is not the same as an answer
        // of "nothing". Only a resolved frame can report an empty screen.
        return AXScrapeResult(
            text: outcome.text,
            visibleText: viewport == nil ? nil : outcome.visibleText,
            windowTitle: windowTitle,
            nodesVisited: outcome.nodesVisited,
            hitLimit: outcome.hitLimit
        )
    }

    /// Attributes read from every visited element, in the order they are appended.
    /// Processes already asked to materialise their accessibility tree, with the time we
    /// asked. Chromium rebuilds the whole tree when this is set and keeps it in lockstep
    /// with the DOM, which is expensive: Screenpipe measured it pegging WindowServer when
    /// set on every walk. Assert once per process and leave it alone.
    private static let manualAccessibilityLock = NSLock()
    nonisolated(unsafe) private static var manualAccessibilityAsserted: [pid_t: CFAbsoluteTime] = [:]
    private static let manualAccessibilityTTL: CFAbsoluteTime = 300

    /// Asks an Electron or Chromium process to build a real accessibility tree.
    ///
    /// Electron apps ship an empty tree until an assistive technology announces itself.
    /// Without this, Claude Desktop yielded **6 characters** and Obsidian about 40 (just
    /// the window title), because the renderer had never materialised its DOM into native
    /// accessibility nodes. `AXManualAccessibility` is the switch that makes them do it.
    static func requestManualAccessibility(pid: pid_t) {
        let now = CFAbsoluteTimeGetCurrent()
        manualAccessibilityLock.lock()
        let last = manualAccessibilityAsserted[pid]
        let due = last == nil || now - last! > manualAccessibilityTTL
        if due { manualAccessibilityAsserted[pid] = now }
        manualAccessibilityLock.unlock()
        guard due else { return }

        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, CaptureLimits.messagingTimeoutSeconds)
        // Both switches exist; different Electron versions honour different ones.
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// Whether two accessibility references point at the same element.
    ///
    /// `AXUIElement` is a CFType with value semantics for equality, so `CFEqual` is the
    /// correct test and `===` is not available. Used to avoid walking one window twice when
    /// the focused window and the main window are the same window, which is the ordinary case.
    static func sameElement(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        guard let a, let b else { return false }
        return CFEqual(a, b)
    }

    /// Breadth-first hunt for the document node inside a browser window.
    ///
    /// Deliberately shallow and cheap: the web area sits a handful of levels below the
    /// window, so a bounded search finds it in microseconds or gives up. Returns nil for
    /// non-browser windows, which then walk normally.
    /// Every web area in the window, richest first.
    ///
    /// This used to return the first one breadth-first, which is correct for a browser:
    /// there is one document and the furniture around it is worth skipping. An Electron app
    /// has several, and the first one the search meets is whichever webview happens to sit
    /// earliest in the tree. In the Claude desktop app that is the composer: a web area with
    /// one child, six nodes deep in total, whose entire text is "Type / for commands".
    ///
    /// Ordering by subtree size picks the document instead of the text box. Ties keep tree
    /// order, so a browser behaves exactly as it did.
    static func findWebAreas(in window: AXUIElement, maxNodes: Int = 250) -> [AXUIElement] {
        var queue: [AXUIElement] = [window]
        var visited = 0
        var found: [(element: AXUIElement, weight: Int)] = []
        while !queue.isEmpty, visited < maxNodes {
            let node = queue.removeFirst()
            visited += 1
            let kids = children(node)
            if let role = string(node, kAXRoleAttribute), role == "AXWebArea" {
                // Children of children: a webview wrapping one container reports one child
                // whichever document is inside it, so one level is not enough to rank on.
                let weight = kids.reduce(kids.count) { $0 + children($1).count }
                found.append((node, weight))
                continue
            }
            queue.append(contentsOf: kids)
        }
        return found
            .enumerated()
            .sorted { ($0.element.weight, -$0.offset) > ($1.element.weight, -$1.offset) }
            .map(\.element.element)
    }

    /// Roles that are browser or window furniture rather than content.
    ///
    /// Text carried by these is navigation, not something the user was reading. Skipping
    /// them keeps extension names, zoom levels and toolbar labels out of the memory.
    static let chromeRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenu", "AXMenuBar", "AXMenuBarItem",
        "AXToolbar", "AXTabGroup", "AXPopUpButton", "AXRadioButton",
        "AXCheckBox", "AXIncrementor", "AXScrollBar", "AXSplitter", "AXDisclosureTriangle",
    ]

    private static let textAttributes: [String] = [
        kAXTitleAttribute,
        kAXValueAttribute,
        kAXSelectedTextAttribute,
        kAXDescriptionAttribute,
    ]

    // MARK: - Typed accessibility reads

    /// Raw attribute read. Returns `nil` on any accessibility error, including timeouts.
    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value
    }

    /// Reads an attribute only if it is genuinely a string. `AXValue`, numbers and booleans are ignored.
    /// Controls that sit beside a document's name and are not its name.
    ///
    /// Short and exact on purpose. Everything here is a fixed piece of application chrome;
    /// anything user-named (a project, a repository, a workspace) must fall through.
    private static let paneControlNames: Set<String> = [
        "remote control", "session actions", "filter", "move", "more navigation items",
        "terminal", "diff", "browser", "new", "search", "home", "code", "share",
    ]

    /// What the main pane of a window says it is showing.
    ///
    /// Some applications put nothing in the title bar. The Claude desktop app reports the
    /// window title "Claude" and never the conversation, so an hour of work could be
    /// measured and never named, and reading it out of the collected text was hopeless,
    /// because the walk flattens the tree and the heading becomes indistinguishable from the
    /// forty sidebar rows listing every other conversation.
    ///
    /// The structure keeps them apart even though the text does not. A sidebar is
    /// `AXLandmarkComplementary` and the content is `AXLandmarkMain` (both web standards,
    /// not anything specific to one app), so the open document is simply the first named
    /// control inside the main landmark, and anything the user named beside it (in Claude's
    /// case the project) follows in the same header row.
    ///
    /// Bounded hard: this runs on every capture of an app whose title bar is unhelpful.
    static func mainPaneSubject(roots: [AXUIElement], maxNodes: Int = 400) -> String? {
        var main: AXUIElement?
        var queue = roots
        var visited = 0
        while !queue.isEmpty, visited < maxNodes, main == nil {
            let node = queue.removeFirst()
            visited += 1
            if string(node, kAXSubroleAttribute) == "AXLandmarkMain" { main = node; break }
            queue.append(contentsOf: children(node))
        }
        guard let main else { return nil }

        // Topmost, not first.
        //
        // "The first named control inside the main landmark" read back "Bypass permissions
        // (Opus 5)": the composer's mode and model pickers, which the search reaches before the
        // header because tree order is not screen order. What actually distinguishes a
        // document's name is where it sits (at the top of its pane, with the controls for
        // typing at the bottom), so the geometry decides and no denylist has to keep up with
        // whatever the next button is called.
        var candidates: [(label: String, x: CGFloat, y: CGFloat)] = []
        queue = [main]
        visited = 0
        while !queue.isEmpty, visited < maxNodes {
            let node = queue.removeFirst()
            visited += 1
            let role = string(node, kAXRoleAttribute)
            if role == kAXButtonRole || role == kAXPopUpButtonRole,
               let label = nonEmpty(string(node, kAXTitleAttribute) ?? string(node, kAXDescriptionAttribute)),
               label.count <= 80,
               !paneControlNames.contains(label.lowercased()),
               !label.lowercased().hasPrefix("more options for"),
               !label.lowercased().hasPrefix("new session in"),
               let origin = point(node, kAXPositionAttribute) {
                candidates.append((label, origin.x, origin.y))
            }
            // Stop at the messages: everything past the header is content, not its name.
            if string(node, kAXSubroleAttribute) == "AXApplicationGroup" { continue }
            queue.append(contentsOf: children(node))
        }
        return AccessibilityCapture.paneSubject(from: candidates)
    }

    /// Dumps the shape of the tree, not just the words in it.
    ///
    /// Three attempts at naming the open conversation failed for the same reason: the walk
    /// flattens the tree into a blob, and by the time anything reads it, the heading and the
    /// forty sidebar rows are indistinguishable strings. Position was the only signal and it
    /// is discarded at the door.
    ///
    /// Off unless `~/Library/Application Support/Memoir/ax-dump` exists, so it costs a file
    /// check per capture and nothing else. Deliberately a file rather than an environment
    /// variable: the app is launched by Finder, where there is nowhere to set one.
    ///
    /// **Shape only, never the words.** This ran once with the node's text attached, and the
    /// log became the one place in Memoir where raw screen text lands in plaintext: it is
    /// called from ``scrape(pid:maxCharacters:wantsWindowTitle:)``, which is upstream of
    /// ``admit(_:windowTitle:)``, so a private-browsing window that never reaches the database
    /// had already been written to `memoir.log`, a 0644 file with no rotation that "Delete
    /// everything" did not touch. It also read straight past the secure-field skip that
    /// ``BoundedTextWalk`` enforces. Position is what this was built for and text was never
    /// needed for it, so the words are gone and geometry took their place.
    static func dumpTreeIfRequested(roots: [AXUIElement], pid: pid_t) {
        let marker = Paths.supportDirectory().appendingPathComponent("ax-dump")
        guard FileManager.default.fileExists(atPath: marker.path) else { return }

        var lines: [String] = ["--- ax dump, pid \(pid) ---"]
        var stack: [(AXUIElement, Int, Int)] = roots.enumerated().map { ($0.element, 0, $0.offset) }.reversed()
        var visited = 0
        while let (node, depth, rootIndex) = stack.popLast(), visited < 1500 {
            visited += 1
            let role = string(node, kAXRoleAttribute) ?? "?"
            let sub = string(node, kAXSubroleAttribute).map { " \($0)" } ?? ""
            // How much text is here, not what it says. A blob's size distinguishes a heading
            // from a message list just as well as its contents, and cannot leak.
            let chars = textAttributes
                .compactMap { nonEmpty(string(node, $0)) }
                .first
                .map { " \($0.count)ch" } ?? ""
            let at = point(node, kAXPositionAttribute)
                .map { String(format: " @%.0f,%.0f", $0.x, $0.y) } ?? ""
            let selected = (copy(node, kAXSelectedAttribute) as? Bool) == true ? " SELECTED" : ""
            lines.append("r\(rootIndex) \(String(repeating: "·", count: depth))\(role)\(sub)\(selected)\(at)\(chars)")
            let kids = children(node)
            for child in kids.reversed() { stack.append((child, depth + 1, rootIndex)) }
        }
        Log.shared.debug(lines.joined(separator: "\n"))
    }

    /// An element's screen position, when it has one.
    ///
    /// Screen geometry rather than tree order is what tells a document's heading from the
    /// controls for typing into it: one is at the top of the pane, the other at the bottom,
    /// and nothing in the tree's shape says so.
    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var out = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &out) else { return nil }
        return out
    }

    /// An element's screen rectangle, when it reports both a position and a size.
    ///
    /// Two accessibility round trips, which is why ``BoundedTextWalk/visibleTextMinimum``
    /// gates who gets asked. An element with no geometry (many web nodes have none) returns
    /// nil and is treated as off screen, so this can only ever narrow what is claimed to have
    /// been visible, never invent it.
    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = point(element, kAXPositionAttribute) else { return nil }
        guard let value = copy(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copy(element, attribute) else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as? String)
    }

    /// Reads an attribute that is itself an accessibility element.
    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Children of an element, or an empty array if it has none or the read failed.
    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = copy(element, kAXChildrenAttribute) else { return [] }
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    /// Trims a string and returns `nil` if nothing is left.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
