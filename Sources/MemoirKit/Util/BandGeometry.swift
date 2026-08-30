import CoreGraphics
import Foundation

/// The notch, as numbers. Computed from raw screen measurements so the math is
/// unit-testable without AppKit; the app layer feeds it `NSScreen` values.
///
/// One code path for every Mac: a screen with a camera housing gets the real cutout
/// (the strip *is* the safe-area band, the wings are the auxiliary areas beside the
/// camera); a screen without one gets a synthetic tab hanging under the menu bar,
/// same shape language, so nothing above this struct ever branches on hardware.
public struct NotchGeometry: Sendable, Equatable {

    /// True when the screen has a physical camera housing.
    public let hasNotch: Bool
    /// Width of the camera dead zone. Zero on synthetic screens: there is no camera
    /// to avoid, so the strip runs uninterrupted.
    public let notchWidth: CGFloat
    /// Height of the strip row: the safe-area inset on a notched screen, the
    /// synthetic default elsewhere.
    public let stripHeight: CGFloat
    /// Distance from the top of the screen to the top of the band. Zero on a notched
    /// screen (the band grows out of the bezel); the menu bar height on a synthetic
    /// screen (the tab hangs below the menu bar).
    public let topOffset: CGFloat

    /// Strip height used for synthetic (non-notch) screens.
    public static let syntheticStripHeight: CGFloat = 34
    /// Camera dead-zone width used when a notched screen reports no auxiliary areas.
    public static let fallbackNotchWidth: CGFloat = 180

    /// Derives the geometry for one screen.
    ///
    /// - Parameters:
    ///   - screenWidth: full screen width in points.
    ///   - safeAreaTopInset: `NSScreen.safeAreaInsets.top`, zero on screens without
    ///     a camera housing.
    ///   - auxiliaryLeftWidth: width of `auxiliaryTopLeftArea`, or nil.
    ///   - auxiliaryRightWidth: width of `auxiliaryTopRightArea`, or nil.
    ///   - menuBarHeight: the visible menu bar height, used to hang the synthetic tab.
    public init(
        screenWidth: CGFloat,
        safeAreaTopInset: CGFloat,
        auxiliaryLeftWidth: CGFloat?,
        auxiliaryRightWidth: CGFloat?,
        menuBarHeight: CGFloat
    ) {
        if safeAreaTopInset > 0 {
            hasNotch = true
            stripHeight = safeAreaTopInset
            topOffset = 0
            if let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth,
               left + right < screenWidth, left > 0, right > 0 {
                notchWidth = screenWidth - left - right
            } else {
                notchWidth = Self.fallbackNotchWidth
            }
        } else {
            hasNotch = false
            stripHeight = Self.syntheticStripHeight
            topOffset = max(0, menuBarHeight)
            notchWidth = 0
        }
    }
}

/// Every size and frame the band can take, in one place.
///
/// The panel itself never resizes: it spans ``panelFrame(on:)`` permanently and the
/// SwiftUI shape inside springs between these sizes. Keeping the numbers here, pure
/// and tested, is what lets the controller stay a thin AppKit shim.
public enum BandLayout {

    /// Rounded bottom corner radius of the open band.
    public static let openCornerRadius: CGFloat = 22
    /// Rounded bottom corner radius of the collapsed band / synthetic tab.
    public static let collapsedCornerRadius: CGFloat = 12

    /// Width of one collapsed wing when it has content to show (face on the left,
    /// the one status slot on the right). Sized for the widest slot, a "88:88"
    /// countdown with its dot, because a wrapped timer is a broken clock.
    public static let wingWidth: CGFloat = 96
    /// Width of a wing while a moment is showing: speech and nudges need a sentence.
    public static let momentWingWidth: CGFloat = 230

    /// Content pane width inside the open band. The band holds one column: the pane the
    /// selected tab names, and nothing beside it.
    public static let paneWidth: CGFloat = 480

    /// What one strip wing must hold while the band is open. The left wing is the binding
    /// side: the face, then the four tab pills.
    ///
    /// Measured, not guessed. At `.system(size: 11.5, weight: .medium)` the pills for
    /// Calendar · Journal · Ask · People come to 230.5pt, plus 20pt of spacing, the 22pt face
    /// and 13pt of leading padding: 285.5pt, rounded up here for slack. Drop below it and the
    /// tabs render as "Cal… J… Ask P…", which is how this constant came to exist: dropping the
    /// context column shrank the band, and the band's width is what feeds the tab row.
    public static let openWingWidth: CGFloat = 296
    /// Open band body height (below the strip).
    public static let openBodyHeight: CGFloat = 380
    /// Vertical room reserved under the band for the coach-mark hint line.
    public static let hintHeight: CGFloat = 26

    /// Minimum width of the collapsed band on a synthetic (non-notch) screen: there
    /// is no bezel to hide in, so the tab stays visible as the click target.
    public static let syntheticTabWidth: CGFloat = 150

    /// The collapsed band size.
    ///
    /// - Parameters:
    ///   - geometry: the screen's notch numbers.
    ///   - hasLeftContent: the face is showing (it always is once Memoir runs).
    ///   - hasRightContent: the one status slot has something to say.
    public static func collapsedSize(
        geometry: NotchGeometry,
        hasLeftContent: Bool,
        hasRightContent: Bool
    ) -> CGSize {
        let left = hasLeftContent ? wingWidth : 0
        let right = hasRightContent ? wingWidth : 0
        if geometry.hasNotch {
            // Bare notch when there is nothing to say: the band vanishes into the bezel.
            return CGSize(width: geometry.notchWidth + left + right, height: geometry.stripHeight)
        }
        return CGSize(
            width: max(syntheticTabWidth, syntheticTabWidth + left + right - wingWidth),
            height: geometry.stripHeight
        )
    }

    /// The band size while a moment (speech, nudge, saved) is showing.
    public static func momentSize(geometry: NotchGeometry) -> CGSize {
        CGSize(
            width: geometry.notchWidth + momentWingWidth * 2,
            height: geometry.stripHeight
        )
    }

    /// The open band size. Width adapts to the screen but is content-driven, never a
    /// near-full-width banner: the wider of the pane and the two strip wings, clamped to 92%
    /// of the screen on small displays.
    public static func openSize(geometry: NotchGeometry, screenWidth: CGFloat) -> CGSize {
        let content = paneWidth + 56
        let strip = geometry.notchWidth + 2 * openWingWidth
        let width = min(max(content, strip), screenWidth * 0.92)
        return CGSize(width: width, height: geometry.stripHeight + openBodyHeight)
    }

    /// The resident panel frame on a screen: the maximum footprint any state can
    /// need, top-centred. AppKit coordinates (origin bottom-left).
    ///
    /// - Parameters:
    ///   - screenFrame: `NSScreen.frame`.
    ///   - geometry: the screen's notch numbers.
    public static func panelFrame(on screenFrame: CGRect, geometry: NotchGeometry) -> CGRect {
        let open = openSize(geometry: geometry, screenWidth: screenFrame.width)
        let width = min(screenFrame.width, max(open.width, momentSize(geometry: geometry).width))
        let height = geometry.topOffset + open.height + hintHeight
        return CGRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }
}
