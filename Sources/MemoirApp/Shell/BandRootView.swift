import SwiftUI
import MemoirKit

/// Publishes the current screen's notch numbers to the SwiftUI tree, so the panel can
/// re-anchor to another display without rebuilding the view.
@MainActor
final class GeometryHolder: ObservableObject {
    @Published var geometry: NotchGeometry
    @Published var screenWidth: CGFloat

    init(geometry: NotchGeometry, screenWidth: CGFloat) {
        self.geometry = geometry
        self.screenWidth = screenWidth
    }
}

/// The whole band: one black shape that springs between a collapsed strip, a widened
/// moment, and the open panel. It is the same object as the notch: it widens and
/// drops, it never becomes a window.
struct BandRootView: View {
    @ObservedObject var shell: ShellModel
    @ObservedObject var character: CharacterModel
    @ObservedObject var holder: GeometryHolder
    let chat: ChatController
    /// Hovering the collapsed band grows it a touch: a peek that says "I open",
    /// borrowed from every good notch app, without committing to anything.
    @State private var hovering = false

    var body: some View {
        let geometry = holder.geometry
        let base = bandSize(geometry: geometry)
        let size = (hovering && shell.mode == .collapsed)
            ? CGSize(width: base.width + 18, height: base.height + 3)
            : base

        VStack(spacing: 0) {
            // On screens without a housing the band hangs below the menu bar.
            if geometry.topOffset > 0 {
                Color.clear.frame(height: geometry.topOffset)
            }

            ZStack(alignment: .top) {
                bandShape
                    .fill(Theme.bg)
                    .shadow(
                        color: .black.opacity(shell.isOpen ? 0.55 : 0),
                        radius: shell.isOpen ? 34 : 0, y: shell.isOpen ? 16 : 0
                    )
                    // The whole collapsed band opens it, not just the face.
                    //
                    // It grows on hover. It says, in the only language a black bar has, that it
                    // is a thing you click. Then only nineteen points by twenty-one of it
                    // answered, and every other click on it did nothing at all.
                    //
                    // On the background layer rather than the ZStack on purpose: the controls
                    // drawn above keep the click when a click lands on one, and this catches
                    // what falls through. An open band is left alone: a stray click must not
                    // eat a half-typed question.
                    .onTapGesture { openFromBand() }

                VStack(spacing: 0) {
                    strip(geometry: geometry)
                        .frame(height: geometry.stripHeight)
                    if shell.isOpen {
                        bandBody
                            .frame(height: BandLayout.openBodyHeight)
                            .transition(.opacity)
                    }
                }
                .clipShape(bandShape)
            }
            .frame(width: size.width, height: size.height)
            .onHover { inside in
                withAnimation(ShellModel.spring) { hovering = inside }
            }
            .contextMenu { appMenu }

            if shell.isOpen, shell.showsCoachMark {
                Text("⌥Space closes · click a tab to switch")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.faint)
                    .shadow(color: .black.opacity(0.6), radius: 3)
                    .padding(.top, 7)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// What a click on the band itself means, by mode. Open is deliberately absent.
    private func openFromBand() {
        switch shell.mode {
        case .collapsed: shell.open(pane: shell.pane)
        case .moment: shell.activateCurrentMoment()
        case .open: break
        }
    }

    // MARK: - Shape and size

    private var bandShape: UnevenRoundedRectangle {
        let radius = shell.isOpen ? Theme.rBandOpen : Theme.rBandCollapsed
        return UnevenRoundedRectangle(
            cornerRadii: .init(bottomLeading: radius, bottomTrailing: radius),
            style: .continuous
        )
    }

    /// The rect the band occupies for a mode, also used by the panel's hit test.
    static func bandSize(
        mode: ShellModel.Mode,
        geometry: NotchGeometry,
        screenWidth: CGFloat,
        health: CaptureHealth = .capturing
    ) -> CGSize {
        switch mode {
        case .collapsed:
            return BandLayout.collapsedSize(
                geometry: geometry,
                hasLeftContent: true,
                // The wing exists for the health chip and nothing else now. No chip, no
                // wing: a healthy Memoir is a bare notch.
                hasRightContent: !health.isHealthy
            )
        case .moment:
            return BandLayout.momentSize(geometry: geometry)
        case .open:
            return BandLayout.openSize(geometry: geometry, screenWidth: screenWidth)
        }
    }

    private func bandSize(geometry: NotchGeometry) -> CGSize {
        Self.bandSize(
            mode: shell.mode, geometry: geometry,
            screenWidth: holder.screenWidth, health: shell.health
        )
    }

    // MARK: - Strip

    /// The 34px chrome row, split around the camera dead zone. Nothing is ever drawn
    /// over the cutout; on synthetic screens the row runs uninterrupted.
    private func strip(geometry: NotchGeometry) -> some View {
        HStack(spacing: 0) {
            leftWing
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 13)
            if geometry.hasNotch {
                Color.clear.frame(width: geometry.notchWidth)
            }
            rightWing
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 13)
        }
    }

    @ViewBuilder
    private var leftWing: some View {
        switch shell.mode {
        case .collapsed:
            // Where you left off, exactly as ⌥Space does. It used to force People, and
            // because selecting a pane persists it, every click of the face also *wrote*
            // People back, so a remembered tab could never survive being opened by hand.
            StripFace(character: character) { shell.open(pane: shell.pane) }

        case .moment(let moment):
            HStack(spacing: 8) {
                StripFace(character: character) { shell.activateCurrentMoment() }
                MomentView(
                    moment: moment,
                    onActivate: { shell.activateCurrentMoment() },
                    onDismiss: { shell.dismissCurrentMoment() }
                )
            }

        case .open:
            HStack(spacing: 5) {
                StripFace(character: character) { shell.collapse() }
                    .padding(.trailing, 3)
                ForEach(ShellModel.PaneID.bandTabs, id: \.self) { pane in
                    TabPill(title: pane.title, selected: shell.pane == pane) {
                        shell.open(pane: pane)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var rightWing: some View {
        switch shell.mode {
        case .collapsed, .moment:
            StripStatusSlot(
                health: shell.health,
                pauseLabel: shell.pauseLabel
            )

        case .open:
            HStack(spacing: 9) {
                // Even with the whole band open and every pane to compete with, a stopped
                // memory keeps the first position. There is no screen of this app on which
                // it is not visible.
                if !shell.health.isHealthy {
                    HealthChip(health: shell.health, label: shell.pauseLabel)
                }
                Button {
                    if shell.isPromoted { shell.onDemote?() } else { shell.onPromote?(shell.pane) }
                } label: {
                    Image(systemName: shell.isPromoted
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(shell.isPromoted ? "Back to the notch" : "Open as a window")
                Button { shell.onPromote?(.settings) } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.faint)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
        }
    }

    // MARK: - Body

    /// The open band's content: the pane, and nothing else.
    ///
    /// There used to be a second column here (next thing due, tracked today, mostly in,
    /// a focus ring), always on screen whichever tab was in front. Four numbers competing
    /// with the tab somebody actually chose. The tab is the answer; the pane gets the width.
    private var bandBody: some View {
        paneHost
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            .environment(\.memoirSurface, .band)
    }

    @ViewBuilder
    private var paneHost: some View {
        switch shell.pane {
        case .portrait:
            PortraitPane(model: shell.portrait)
        case .calendar:
            CalendarPane(model: shell.calendar)
        case .ask:
            ChatPane(chat: chat)
        case .journal, .memories, .settings:
            // Window-only panes can never be selected while the band is open.
            EmptyView()
        }
    }

    // MARK: - Right-click menu

    /// The old status-item menu, rehomed onto the band itself.
    @ViewBuilder
    private var appMenu: some View {
        // The menu opens with the answer to the only question that matters, so a right-click
        // is always enough to find out whether the memory is being written.
        Text(shell.health.isHealthy ? "Recording" : (shell.pauseLabel ?? shell.health.shortLabel))
        Divider()
        if !shell.hasAccessibility {
            Button("Grant Accessibility Permission…") { shell.onGrantPermission?() }
        }
        // Pausing is a question of *how long*, never just off. A pause with no end is the same
        // silent gap as a revoked permission, arrived at by being helpful. So the durations
        // are the menu and the open-ended one has to be picked on purpose.
        if shell.capturePaused {
            Button("Resume capture") { shell.onResume?() }
        } else {
            Menu("Pause capture") {
                ForEach(CapturePause.allCases, id: \.self) { choice in
                    Button(choice.menuTitle) { shell.onPauseFor?(choice) }
                }
            }
        }
        Divider()
        Button("Memory…") { shell.onPromote?(.memories) }
        Button("Settings…") { shell.onPromote?(.settings) }
        Divider()
        Button("Quit Memoir") { NSApp.terminate(nil) }
    }
}
