import Foundation

/// The background poller: it drives a ``CaptureSource`` on a timer, writes captures to the
/// ``Store``, and keeps the `sessions` table honest.
///
/// A session is a contiguous run in one app. It is closed and a new one opened when the frontmost
/// app changes, when idleness begins or ends, or when a gap appears in the timeline (a sleep, or
/// the loop being stopped and restarted). Sessions are *not* opened for excluded apps: Memoir records
/// neither the text nor the fact that you were in your password manager.
///
/// The loop never throws. A failed accessibility read, a locked database, a wedged app: all are
/// logged and the next tick proceeds. Losing capture because one read failed would be a worse bug
/// than any it could report.
public actor CaptureLoop {

    private let source: any CaptureSource
    private let store: Store
    private var config: CaptureConfig

    /// Where the frontmost app comes from. Injectable so session bookkeeping (CF-13) can be
    /// driven through a scripted A → B → A sequence; production always reads `NSWorkspace`.
    private let frontmostApp: @Sendable () -> FrontmostApp?

    /// Where idleness comes from. Injectable for the same reason; production always queries
    /// the window server's HID state.
    private let idleSecondsProvider: @Sendable () -> TimeInterval

    /// Seconds since the last key press. Injectable; production reads `CGEventSource`,
    /// which needs no event tap and no extra permission.
    private let keystrokeSecondsProvider: @Sendable () -> TimeInterval

    /// Focused window title. Injectable; production does one cheap accessibility read.
    private let windowTitleProvider: @Sendable () -> String?

    private var detector = TriggerDetector()
    private var sawFirstTick = false

    private var task: Task<Void, Never>?
    /// Bumped by every `start()` and `stop()`; a tick belonging to an older generation exits.
    private var generation: Int = 0

    private var currentSession: Session?
    private var lastPermissionLog: Date?

    /// Number of captures written since this loop was created. Handy for the settings UI.
    public private(set) var capturesWritten: Int = 0

    /// Creates a loop. Nothing runs until ``start()`` is called.
    /// - Parameters:
    ///   - source: usually an ``AccessibilityCapture``.
    ///   - store: the SQLite store captures and sessions are written to.
    ///   - config: polling interval, idle threshold and exclusions.
    public init(source: any CaptureSource, store: Store, config: CaptureConfig) {
        self.init(
            source: source,
            store: store,
            config: config,
            frontmostApp: { FrontmostApp.current() },
            idleSeconds: { IdleMonitor.idleSeconds() },
            keystrokeSeconds: { IdleMonitor.secondsSinceKeystroke() },
            windowTitle: { FrontmostApp.focusedWindowTitle() }
        )
    }

    /// Designated initialiser with the two environment reads injected.
    ///
    /// The public initialiser supplies the real `NSWorkspace` and HID-state readers. Tests
    /// supply a script, which is the only way session rotation can be asserted without
    /// actually switching applications on the machine running the suite.
    init(
        source: any CaptureSource,
        store: Store,
        config: CaptureConfig,
        frontmostApp: @escaping @Sendable () -> FrontmostApp?,
        idleSeconds: @escaping @Sendable () -> TimeInterval,
        keystrokeSeconds: @escaping @Sendable () -> TimeInterval = { .greatestFiniteMagnitude },
        windowTitle: @escaping @Sendable () -> String? = { nil }
    ) {
        self.source = source
        self.store = store
        self.config = config
        self.frontmostApp = frontmostApp
        self.idleSecondsProvider = idleSeconds
        self.keystrokeSecondsProvider = keystrokeSeconds
        self.windowTitleProvider = windowTitle
    }

    /// Whether the polling task is alive.
    public var isRunning: Bool { task != nil }

    /// Starts polling. Idempotent: calling it while running does nothing.
    public func start() async {
        guard task == nil else { return }
        generation &+= 1
        let myGeneration = generation
        Log.shared.info("capture loop starting, event-driven (poll \(config.pollIntervalSeconds)s)")
        task = Task { [weak self] in
            await self?.run(generation: myGeneration)
        }
    }

    /// Stops polling and closes any open session. Idempotent.
    ///
    /// - Parameter now: the instant the final session is stamped as ending. Defaults to the
    ///   wall clock; injected by the session tests so a duration assertion is exact.
    public func stop(now: Date = Date()) async {
        generation &+= 1
        task?.cancel()
        task = nil
        await closeSession(at: now, reason: "loop stopped")
        Log.shared.info("capture loop stopped")
    }

    /// Replaces the configuration. The new exclusions and trigger floors apply from the next tick.
    public func updateConfig(_ config: CaptureConfig) {
        self.config = config
    }

    // MARK: - The loop

    /// Poll, sleep, repeat. Exits on cancellation or when a newer generation supersedes this one.
    private func run(generation myGeneration: Int) async {
        while !Task.isCancelled && myGeneration == generation {
            await tick(now: Date(), generation: myGeneration)
            guard !Task.isCancelled && myGeneration == generation else { break }
            do {
                try await Task.sleep(for: .seconds(config.pollIntervalSeconds))
            } catch {
                break // cancelled
            }
        }
    }

    /// One poll: update the session, then (if active and allowed) capture and store text.
    ///
    /// Internal rather than private so the session flows can step the loop tick by tick with
    /// an injected clock instead of sleeping.
    ///
    /// - Parameters:
    ///   - now: the instant this tick is stamped with.
    ///   - generation: the loop generation this tick belongs to, or nil when a caller is
    ///     stepping the loop by hand. Reading the screen suspends, so `stop()` can land in
    ///     the middle of a tick; a tick whose generation has been superseded discards what
    ///     it read instead of writing it. Pause means paused (CF-23).
    func tick(now: Date, generation myGeneration: Int? = nil) async {
        let idleSeconds = idleSecondsProvider()
        let isIdle = idleSeconds >= config.effectiveIdleThreshold
        let front = frontmostApp()

        await updateSession(front: front, isIdle: isIdle, now: now)

        guard !isIdle else { return }
        guard let front, !config.isExcluded(front.bundleID) else { return }

        // Only the CHEAP signals have been read so far. Decide whether anything actually
        // changed before paying for a tree walk: this gate is the whole event-driven
        // rewrite. A caller stepping the loop by hand (generation == nil) always captures,
        // so the session and dedupe flows keep driving it directly.
        if myGeneration != nil {
            let signals = CaptureSignals(
                bundleID: front.bundleID,
                windowTitle: windowTitleProvider(),
                idleSeconds: idleSeconds,
                secondsSinceKeystroke: keystrokeSecondsProvider()
            )
            let isFirst = !sawFirstTick
            sawFirstTick = true
            var trigger = detector.evaluate(signals, config: config, now: now, isFirstTick: isFirst)
            if trigger == nil, detector.idleFallbackDue(now: now, config: config) {
                trigger = .idleFallback
                detector.noteCapture(at: now)
            }
            guard let trigger else { return }
            Log.shared.debug("capture trigger: \(trigger.rawValue) in \(front.bundleID)")
        }

        do {
            guard let event = try await source.snapshot() else { return }
            guard isCurrent(myGeneration) else {
                Log.shared.debug("capture discarded: loop was stopped while reading the screen")
                return
            }
            try await store.insert(capture: event)
            capturesWritten += 1
        } catch MemoirError.accessibilityPermissionDenied {
            logPermissionDenied(now: now)
        } catch {
            Log.shared.error("capture tick failed: \(error)")
        }
    }

    /// Whether a tick still belongs to the running loop.
    ///
    /// A nil generation means the caller is stepping the loop directly and owns the decision,
    /// so nothing is discarded.
    private func isCurrent(_ myGeneration: Int?) -> Bool {
        guard let myGeneration else { return true }
        return myGeneration == generation && !Task.isCancelled
    }

    /// Logs the permission problem at most once a minute so a denied grant cannot flood the log.
    private func logPermissionDenied(now: Date) {
        if let last = lastPermissionLog, now.timeIntervalSince(last) < 60 { return }
        lastPermissionLog = now
        Log.shared.warn("capture paused: Accessibility permission not granted")
    }

    // MARK: - Sessions

    /// Extends, rotates or closes the current session.
    ///
    /// A new session starts when the frontmost app changes, when the idle flag flips, or when the
    /// tick stream has a hole in it wider than ``CaptureConfig/sessionGapSeconds`` (sleep, or a
    /// stop/start cycle). Sessions are maintained on every tick, so this is independent of
    /// whether anything triggered a capture.
    private func updateSession(front: FrontmostApp?, isIdle: Bool, now: Date) async {
        guard let front, !config.isExcluded(front.bundleID) else {
            await closeSession(at: now, reason: front == nil ? "no frontmost app" : "excluded app")
            return
        }

        let maxGap = CaptureConfig.sessionGapSeconds

        if var session = currentSession {
            let sameApp = session.appBundleID == front.bundleID
            let sameIdleState = session.idle == isIdle
            let contiguous = now.timeIntervalSince(session.endedAt) <= maxGap

            if sameApp && sameIdleState && contiguous {
                session.endedAt = now
                currentSession = session
                await persist(session)
                return
            }
            await closeSession(at: contiguous ? now : session.endedAt, reason: "rotated")
        }

        let session = Session(
            appBundleID: front.bundleID,
            appName: front.name,
            startedAt: now,
            endedAt: now,
            idle: isIdle
        )
        currentSession = session
        await persist(session)
    }

    /// Closes the open session, stamping its end time, and writes it out.
    private func closeSession(at end: Date, reason: String) async {
        guard var session = currentSession else { return }
        currentSession = nil
        session.endedAt = max(end, session.startedAt)
        await persist(session)
        Log.shared.debug("session closed for \(session.appBundleID) (\(reason)), \(Int(session.duration))s")
    }

    /// Writes a session row, swallowing and logging storage errors: a failed session write must
    /// never take down capture.
    private func persist(_ session: Session) async {
        do {
            try await store.upsert(session: session)
        } catch {
            Log.shared.error("session write failed: \(error)")
        }
    }
}
