import Foundation
import Testing
import MemoirKit
@testable import MemoirApp

// CF-103: first run is a sequence, and it ends with the user set up.
//
// The old onboarding was one screen that destroyed itself the moment Accessibility arrived,
// so there was no order to get wrong. There is now, and the ordering rules are the part a
// reader cannot check by looking at the window: which button is emphasised, what it says when
// pressing it would skip something, and where the flow starts.

@Suite("CF-103 first run is a sequence, and it ends with the user set up")
@MainActor
struct OnboardingFlowTests {

    /// Counts the two things the flow can do to the world outside itself.
    private final class Box {
        var askedForAccessibility = 0
        var finished = 0
    }

    /// Builds a flow against a throwaway support directory.
    ///
    /// The binding has to be in place around the *initialiser*, not just around the body:
    /// `OnboardingFlow` builds an `IdentityStep`, which loads the config to pre-fill the name
    /// field. Without the override that read reaches the real
    /// `~/Library/Application Support/Memoir/config.json`, and the assertion about an empty
    /// identity step passes or fails depending on whether whoever ran the suite happens to
    /// have told Memoir their name. It failed exactly that way the first time it was run.
    private func withFlow(
        granted: Bool = false,
        _ body: (OnboardingFlow, Box) -> Void
    ) {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoir-onboarding-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // `UserNames` is a process-wide global, not a task local: `AppConfig.setOwnNames`
        // publishes to it deliberately, because the extractor has no other way to hear about
        // a name the user just typed. The support-directory override does not contain it, so
        // a test that adds a name here leaves it installed for whatever runs next, which is
        // how adding these tests broke CF-61, a suite two targets away whose whole contract is
        // the answer given when no names are set.
        let savedNames = UserNames.current
        defer { UserNames.install(savedNames) }

        Paths.$supportDirectoryOverride.withValue(temp) {
            let box = Box()
            let flow = OnboardingFlow(
                accessibilityGranted: granted,
                hotkeyLabel: "⌥Space",
                requestAccessibility: { box.askedForAccessibility += 1 },
                finish: { box.finished += 1 }
            )
            body(flow, box)
        }
    }

    // MARK: - Order

    @Test("CF-103 the flow starts at the welcome, not part-way through")
    func startsAtTheBeginning() {
        withFlow { flow, _ in
            #expect(flow.step == .welcome)
            #expect(flow.isFirst)
            #expect(!flow.isLast)
        }
    }

    @Test("CF-103 every step is reachable in order, and the last one finishes")
    func walksTheWholeSequence() {
        withFlow(granted: true) { flow, box in
            for step in flow.applicableSteps {
                #expect(flow.step == step)
                flow.forward()
            }
            // Forward from the last step is the finish, and it does not wrap around.
            #expect(flow.step == .ready)
            #expect(box.finished == 1)
        }
    }

    @Test("first run is four screens, and the spare key is not one of them")
    func firstRunIsFourScreens() {
        withFlow { flow, _ in
            // The history step is in first run and not in Settings-only exile: a memory that
            // starts empty is the failure this product is for, and the import is offered while
            // the user is already answering permission dialogs.
            #expect(flow.applicableSteps == [.welcome, .permission, .history, .ready])
            // A key protecting a database with nothing in it is homework handed out before
            // anything has happened, so it is asked for on a later launch instead.
            #expect(!flow.applicableSteps.contains(.recovery))
            flow.forward()
            #expect(flow.step == .permission)
        }
    }

    @Test("the history step's button is the import, not a way past it")
    func historyButtonIsTheImport() {
        withFlow(granted: true) { flow, _ in
            flow.step = .history
            // Before anything has run, the emphasised button reads as the action and the
            // escape is the quiet link beside it, never the other way around.
            #expect(flow.forwardTitle == "Read them")
            #expect(flow.declineTitle == "Not now")
            #expect(flow.forwardIsPrimary)

            // No memory service is wired in this test, so `run()` is a no-op and the step
            // stays put. The button must not have advanced on its own.
            flow.primaryAction()
            #expect(flow.step == .history, "the primary action imports, it does not skip")

            // The decline is always available: it is a link in the footer that calls forward.
            flow.forward()
            #expect(flow.step == .ready)
        }
    }

    @Test("the spare-key launch shows the key and then the end, in that order")
    func recoveryOnlyLaunchIsOrdered() {
        withFlow { flow, _ in
            flow.recoveryOnly = true
            flow.step = .recovery
            #expect(flow.applicableSteps == [.recovery, .ready],
                    "the key comes before 'you're set', not after it")
            flow.forward()
            #expect(flow.step == .ready)
        }
    }

    @Test("copying the spare key is not the same as keeping it")
    func copyingIsNotKeeping() {
        withFlow { flow, _ in
            flow.recoveryOnly = true
            flow.step = .recovery
            flow.recovery.adopt("A1B2-C3D4")

            flow.recovery.copyToClipboard()
            #expect(
                !flow.recovery.saved,
                """
                A clipboard is not somewhere a key is kept. Copy anything else and it is \
                gone. Counting it as kept retires the offer for good and can leave somebody \
                holding nothing.
                """
            )
            #expect(
                !AppConfig.load().recoveryKeyAcknowledged,
                "and it must not write the acknowledgement that stops the key being offered again"
            )
        }
    }

    @Test("skipping backwards steps over what was skipped forwards")
    func backSkipsInactiveSteps() {
        withFlow { flow, _ in
            flow.forward()
            #expect(flow.step == .permission)
            flow.back()
            #expect(flow.step == .welcome, "back must not land on a step that was never shown")
        }
    }

    @Test("CF-103 back reaches the start and stops there")
    func backStopsAtTheStart() {
        withFlow { flow, _ in
            flow.forward()
            #expect(flow.step == .permission)
            for _ in OnboardingFlow.Step.allCases.indices { flow.back() }
            #expect(flow.step == .welcome, "there is nothing before the welcome to fall off into")
        }
    }

    @Test("CF-103 walking through the middle of the flow is not completing it")
    func onlyTheEndFinishes() {
        withFlow(granted: true) { flow, box in
            // Every step but the last, one at a time. None of them may finish the flow.
            for _ in 1..<flow.applicableSteps.count {
                flow.forward()
                #expect(box.finished == 0)
            }
            flow.forward()
            #expect(box.finished == 1)
        }
    }

    // MARK: - Saying what pressing the button will actually do

    @Test("CF-103 an ungranted permission is never dressed up as a completed one")
    func skippingThePermissionSaysSo() {
        withFlow(granted: false) { flow, _ in
            flow.forward()
            #expect(flow.step == .permission)
            // The rule this has always protected is unchanged: pressing past an ungranted
            // permission must never look like meeting it. What changed is where the honesty
            // lives. It used to be in the primary button, which renamed itself to "Continue
            // without it", so the largest control on the screen described a failure and the
            // good path had no button at all. Now the primary is the action, and declining is
            // a quiet link beside it.
            #expect(flow.forwardTitle == "Open Settings")
            #expect(flow.declineTitle == "Not now", "the way past must be offered, and be quiet")
        }
    }

    @Test("CF-103 once the grant arrives there is nothing left to decline")
    func grantRemovesTheEscape() {
        withFlow(granted: false) { flow, _ in
            flow.forward()
            flow.accessibilityGranted = true
            #expect(flow.declineTitle == nil, "nothing to skip once it is granted")
            #expect(flow.forwardIsPrimary)
        }
    }

    @Test("the primary button never describes what the user failed to do")
    func primaryIsAlwaysTheAction() {
        withFlow(granted: false) { flow, _ in
            for step in [OnboardingFlow.Step.welcome, .permission, .ready, .recovery] {
                flow.step = step
                let title = flow.forwardTitle.lowercased()
                #expect(
                    !title.contains("without") && !title.contains("skip") && !title.contains("instead"),
                    "the primary button said '\(flow.forwardTitle)' on \(step)"
                )
                #expect(flow.forwardIsPrimary)
            }
        }
    }

    @Test("the permission button opens Settings rather than stepping over the permission")
    func permissionPrimaryAsks() {
        withFlow(granted: false) { flow, box in
            flow.forward()
            #expect(flow.step == .permission)
            flow.primaryAction()
            #expect(box.askedForAccessibility == 1, "the button's whole job is to open the pane")
            #expect(flow.step == .permission, "and to stay put until the grant actually lands")
        }
    }

    @Test("CF-103 the same name twice is still one name")
    func namesDoNotDuplicate() {
        withFlow { flow, _ in
            flow.identity.draft = "Ada"
            flow.identity.add()
            flow.identity.draft = "ada"
            #expect(!flow.identity.canAdd, "case is not a difference worth storing twice")
            flow.identity.add()
            #expect(flow.identity.names.count == 1)
        }
    }

    // MARK: - Side effects

    @Test("CF-103 nothing prompts for a permission on its own")
    func askingIsExplicit() {
        withFlow(granted: false) { flow, box in
            #expect(box.askedForAccessibility == 0)
            flow.askForAccessibility()
            #expect(box.askedForAccessibility == 1)
        }
    }

    @Test("CF-103 skip goes to the end rather than out of the flow")
    func skipLandsOnReady() {
        withFlow(granted: true) { flow, box in
            flow.skipToEnd()
            // Deliberately not the same as finishing: the last step is where the user is told
            // the hotkey and where Memoir lives, which is the one thing they cannot discover
            // on their own once the window is gone.
            #expect(flow.step == .ready)
            #expect(box.finished == 0)
        }
    }

    @Test("CF-103 every step has a title and a state of the mark")
    func everyStepIsPresentable() {
        for step in OnboardingFlow.Step.allCases {
            #expect(!step.title.isEmpty)
            // Traits interpolate, so a missing state would silently render as the previous
            // step's mark rather than fail.
            _ = step.expression.fold
        }
        // A ceiling now, not a floor. The floor was guarding against a step losing its title
        // when the flow was seven screens long and growing; the pressure since has been the
        // other way, and the thing worth defending is that first run stays short.
        //
        // Raised from four to five, deliberately and once, to let the history import back in.
        // It is the one screen that is not a gate: it fills the memory instead of standing in
        // front of it, and skipping it costs one click. Four screens plus the spare key, which
        // is not part of first run at all. Anything past this is a settings pane in a costume.
        #expect(
            OnboardingFlow.Step.allCases.count <= 5,
            "first run grew back. Every added screen is a gate in front of an unseen app."
        )
        #expect(Set(OnboardingFlow.Step.allCases.map(\.title)).count == OnboardingFlow.Step.allCases.count,
                "two steps sharing a title means one of them was copied and not renamed")
    }
}
