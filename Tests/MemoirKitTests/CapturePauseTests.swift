import Testing
import Foundation
@testable import MemoirKit

/// A pause that outlives the reason for it is the same silent gap as a revoked permission.
@Suite("Capture pause")
struct CapturePauseTests {

    private let noon = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A bare pause is an hour, not forever")
    func theDefaultHasAnEnd() {
        #expect(CapturePause.default.seconds == 3_600)
        let state = CapturePauseState.paused(.default, from: noon)
        #expect(state.expiresAt == noon.addingTimeInterval(3_600))
    }

    @Test("A pause holds for its length and then lets go by itself")
    func itExpires() {
        let state = CapturePauseState.paused(.oneHour, from: noon)
        #expect(state.isPaused(at: noon))
        #expect(state.isPaused(at: noon.addingTimeInterval(3_599)))
        #expect(state.isPaused(at: noon.addingTimeInterval(3_601)) == false)
        #expect(state.settled(at: noon.addingTimeInterval(3_601)) == .running)
    }

    @Test("An expiry that passed while Memoir was closed is honoured on the next launch")
    func itSurvivesBeingQuit() {
        // Paused for fifteen minutes, then the Mac is restarted and comes back a day later.
        let stored = CapturePauseState.paused(.fifteenMinutes, from: noon)
        let nextLaunch = noon.addingTimeInterval(86_400)
        #expect(stored.isPaused(at: nextLaunch) == false)
        #expect(stored.settled(at: nextLaunch) == .running)
        #expect(stored.label(at: nextLaunch) == nil)
    }

    @Test("An open-ended pause is honoured, because it was asked for on purpose")
    func indefiniteMeansIndefinite() {
        let state = CapturePauseState.paused(.indefinitely, from: noon)
        #expect(state.expiresAt == nil)
        #expect(state.isPaused(at: noon.addingTimeInterval(86_400 * 30)))
        #expect(state.label(at: noon) == "Paused")
    }

    @Test("The countdown says how long is left, and rounds up so it never reads zero")
    func theLabelCountsDown() {
        let state = CapturePauseState.paused(.fourHours, from: noon)
        #expect(state.label(at: noon) == "Paused · 4h")
        #expect(state.label(at: noon.addingTimeInterval(3 * 3_600 + 60)) == "Paused · 59m")
        #expect(state.label(at: noon.addingTimeInterval(4 * 3_600 - 1)) == "Paused · 1m")
    }

    @Test("Running capture is never labelled and never paused")
    func runningIsRunning() {
        #expect(CapturePauseState.running.isPaused(at: noon) == false)
        #expect(CapturePauseState.running.label(at: noon) == nil)
    }

    @Test("Every choice offers words for a menu, and only one of them lasts")
    func everyChoiceIsUsable() {
        let openEnded = CapturePause.allCases.filter { $0.seconds == nil }
        #expect(openEnded == [.indefinitely], "only one choice may be open-ended")
        for choice in CapturePause.allCases {
            #expect(choice.menuTitle.isEmpty == false)
        }
    }
}
