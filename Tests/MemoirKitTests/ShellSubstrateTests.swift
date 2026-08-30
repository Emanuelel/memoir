//  Unit tests for the band's pure substrate: notch geometry, layout math, and the
//  deterministic chat commands. No workspace, no store, no clock: just arithmetic.

import CoreGraphics
import Foundation
import Testing

@testable import MemoirKit

@Suite("Band geometry")
struct BandGeometryTests {

    // A 14" MacBook Pro-shaped screen: 1512pt wide, 32pt safe-area strip, auxiliary
    // areas flanking a ~196pt camera housing.
    private let notched = NotchGeometry(
        screenWidth: 1512,
        safeAreaTopInset: 32,
        auxiliaryLeftWidth: 658,
        auxiliaryRightWidth: 658,
        menuBarHeight: 24
    )

    // An external display: no housing, ordinary 24pt menu bar.
    private let synthetic = NotchGeometry(
        screenWidth: 2560,
        safeAreaTopInset: 0,
        auxiliaryLeftWidth: nil,
        auxiliaryRightWidth: nil,
        menuBarHeight: 24
    )

    @Test("a notched screen derives the camera dead zone from the auxiliary areas")
    func notchedScreenDerivesCutout() {
        #expect(notched.hasNotch)
        #expect(notched.notchWidth == CGFloat(1512 - 658 - 658))
        #expect(notched.stripHeight == 32, "the strip is the safe-area band")
        #expect(notched.topOffset == 0, "the band grows out of the bezel itself")
    }

    @Test("a screen without a housing gets the synthetic tab under the menu bar")
    func syntheticScreenHangsBelowMenuBar() {
        #expect(!synthetic.hasNotch)
        #expect(synthetic.notchWidth == 0, "no camera, no dead zone")
        #expect(synthetic.stripHeight == NotchGeometry.syntheticStripHeight)
        #expect(synthetic.topOffset == 24, "the tab hangs below the menu bar")
    }

    @Test("missing auxiliary areas fall back to a sane cutout instead of zero")
    func degenerateAuxiliaryAreasFallBack() {
        let odd = NotchGeometry(
            screenWidth: 1512, safeAreaTopInset: 32,
            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menuBarHeight: 24
        )
        #expect(odd.notchWidth == NotchGeometry.fallbackNotchWidth,
                "a zero-width dead zone would put content over the camera")
    }

    @Test("the collapsed band vanishes into a bare notch when there is nothing to say")
    func collapsedBareNotchIsInvisible() {
        let bare = BandLayout.collapsedSize(geometry: notched, hasLeftContent: false, hasRightContent: false)
        #expect(bare.width == notched.notchWidth, "black on black: exactly the housing, nothing more")
        #expect(bare.height == notched.stripHeight)

        let speaking = BandLayout.collapsedSize(geometry: notched, hasLeftContent: true, hasRightContent: true)
        #expect(speaking.width == notched.notchWidth + 2 * BandLayout.wingWidth)
    }

    @Test("the synthetic tab never collapses below its click target")
    func syntheticTabStaysClickable() {
        let bare = BandLayout.collapsedSize(geometry: synthetic, hasLeftContent: false, hasRightContent: false)
        #expect(bare.width >= BandLayout.syntheticTabWidth,
                "with no bezel to hide in, the tab must stay visible")
    }

    @Test("the open band is content-sized and clamped, never a near-full-width banner")
    func openBandAdaptsToContent() {
        let open = BandLayout.openSize(geometry: notched, screenWidth: 1512)
        #expect(open.width <= 1512 * 0.92)
        #expect(open.width >= BandLayout.paneWidth, "the pane must fit")
        #expect(open.height == notched.stripHeight + BandLayout.openBodyHeight)

        // On a small screen the clamp wins.
        let small = BandLayout.openSize(geometry: notched, screenWidth: 800)
        #expect(small.width == 800 * 0.92)
    }

    @Test("the open band is always wide enough for the tab row")
    func openBandFitsTheTabs() {
        // The bug this pins: the open width is what feeds the strip, and the strip is what
        // draws the tabs. Narrowing the band, which is what dropping the context column did,
        // truncated them to "Cal… J… Ask P…" with nothing in the layout to object.
        for width in [1512.0, 1728.0, 2560.0] as [CGFloat] {
            let open = BandLayout.openSize(geometry: notched, screenWidth: width)
            let wing = (open.width - notched.notchWidth) / 2
            #expect(wing >= BandLayout.openWingWidth, "the tabs truncate at \(width)pt")
        }
    }

    @Test("the resident panel frame is top-centred and wide enough for every state")
    func panelFrameCoversEveryState() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let frame = BandLayout.panelFrame(on: screen, geometry: notched)

        #expect(frame.midX == screen.midX)
        #expect(frame.maxY == screen.maxY, "the panel touches the top of the screen")
        #expect(frame.width >= BandLayout.openSize(geometry: notched, screenWidth: 1512).width)
        #expect(frame.width >= BandLayout.momentSize(geometry: notched).width,
                "a moment must never be clipped by the panel")
        #expect(frame.width <= screen.width)
    }
}

@Suite("Chat commands")
struct ChatCommandTests {

    @Test("navigation is a sentence")
    func navigationSentences() {
        #expect(ChatCommand.detect("what's on my list") == .navigate(.todos))
        #expect(ChatCommand.detect("what's overdue") == .navigate(.todos))
        #expect(ChatCommand.detect("show my day") == .navigate(.today))
        #expect(ChatCommand.detect("show my notes") == .navigate(.notes))
    }

    @Test("real questions are never swallowed as commands")
    func questionsPassThrough() {
        #expect(ChatCommand.detect("did I promise marco anything") == nil)
        #expect(ChatCommand.detect("how long was I in chrome") == nil)
        #expect(ChatCommand.detect("what was that repo about screen memory") == nil)
        #expect(ChatCommand.detect("remind me to send the invoice friday") == nil,
                "push phrases belong to the router, not the command layer")
        #expect(ChatCommand.detect("") == nil)
    }
}
