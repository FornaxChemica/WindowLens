import AppKit
import Carbon.HIToolbox
import SwiftUI
import Combine
import QuartzCore

final class SwitcherPanel: NSPanel {
    private var hostingView: NSHostingView<AnyView>?
    private var cancellables = Set<AnyCancellable>()
    private var clickOutsideMonitor: Any?
    private let dismissalDuration: TimeInterval = 0.08
    private var presentationMode: SwitcherPresentationMode = .workspace
    private let nativePlacementMargin: CGFloat = 24
    private let nativeAnchorGap: CGFloat = 28
    private let minimumNativePreviewHeight: CGFloat = 280

    /// The Y position of the top of the app grid (used to anchor expansions)
    private var gridTopY: CGFloat = 0

    /// The screen this panel is associated with (for multi-screen support)
    private(set) var associatedScreen: NSScreen?
    private var pendingRecenterWorkItem: DispatchWorkItem?

    init(screen: NSScreen? = nil) {
        self.associatedScreen = screen
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configure()
        setupHostingView()
        setupNotifications()
        setupStateObservers()
    }

    /// Update the associated screen (used when screen configuration changes)
    func updateAssociatedScreen(_ screen: NSScreen) {
        self.associatedScreen = screen
    }

    private func configure() {
        // Workspace mode is a keyboard-owned surface; Cmd+Tab augmentation is raised when shown.
        level = .statusBar

        // Appearance
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        // Behavior
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false

        // Appear on all spaces
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient
        ]

        animationBehavior = .none
    }

    // Allow the panel to become key window (needed for TextField input)
    override var canBecomeKey: Bool { true }

    private func setupHostingView() {
        let switcherView = SwitcherView()
            .environmentObject(AppState.shared)

        hostingView = NSHostingView(rootView: AnyView(switcherView))

        // Critical: Disable Auto Layout constraints for the hosting view
        // This prevents conflicts between NSPanel's frame-based layout and SwiftUI's layout system
        hostingView?.translatesAutoresizingMaskIntoConstraints = true
        hostingView?.autoresizingMask = [.width, .height]
        hostingView?.wantsLayer = true

        contentView = hostingView
    }

    private func setupNotifications() {
        NotificationCenter.default.publisher(for: .confirmSwitcherSelection)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.confirmSelection()
            }
            .store(in: &cancellables)
    }

    private func setupStateObservers() {
        // Observe search state changes to re-center panel
        AppState.shared.$isSearchActive
            .dropFirst()  // Skip initial value
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recenterIfVisible()
            }
            .store(in: &cancellables)

        // Observe search query changes (for search results height)
        AppState.shared.$searchQuery
            .dropFirst()
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recenterIfVisible()
            }
            .store(in: &cancellables)

        // Observe selected app changes (for window list) - resize without animation
        AppState.shared.$selectedAppIndex
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.resizeForWindowList()
            }
            .store(in: &cancellables)

        // Re-size when the live window list changes (e.g. user closed windows while switcher is open).
        AppState.shared.$applications
            .dropFirst()
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard AppState.shared.presentationMode == .workspace,
                      AppState.shared.workspaceMode == .currentAppWindows else { return }
                self?.resizeForWindowList()
            }
            .store(in: &cancellables)

        // Observe resource monitor toggle to re-center panel
        AppState.shared.$isResourceMonitorActive
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recenterIfVisible()
            }
            .store(in: &cancellables)

        AppState.shared.$isUnusedWindowsActive
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recenterIfVisible()
            }
            .store(in: &cancellables)
    }

    // MARK: - Size Calculation (matches SwitcherView)

    private func calculateCurrentSize() -> CGSize {
        let appState = AppState.shared
        let appCount = appState.filteredApplications.count
        let isSearchActive = appState.isSearchActive
        let searchQuery = appState.searchQuery

        if appState.presentationMode == .nativePreview {
            let windowCount = appState.selectedApp?.openWindowCount ?? 1
            return CGSize(
                width: nativePreviewWidth(for: windowCount, on: associatedScreen ?? NSScreen.main),
                height: 424
            )
        }

        if appState.presentationMode == .workspace,
           appState.workspaceMode == .currentAppWindows {
            let width: CGFloat
            if appState.isUnusedWindowsActive {
                width = 640
            } else if appState.isResourceMonitorActive {
                width = 680
            } else {
                let windowCount = appState.selectedApp?.openWindowCount ?? 1
                width = nativePreviewWidth(for: windowCount, on: associatedScreen ?? NSScreen.main)
            }

            let height: CGFloat
            if appState.isUnusedWindowsActive {
                height = 500
            } else if appState.isResourceMonitorActive {
                let entryCount = min(appState.resourceEntries.count, 15)
                let chartHeight: CGFloat = 110
                let entriesHeight = entryCount == 0 ? 80 : CGFloat(entryCount) * 30 + 24
                let hintsHeight: CGFloat = 30
                height = chartHeight + entriesHeight + hintsHeight + 120
            } else {
                height = 536
            }

            return CGSize(width: width, height: height)
        }

        if appState.presentationMode == .workspace,
           appState.workspaceMode == .globalWindowSearch {
            // Extra height for the Settings-style frosted shell padding.
            return CGSize(width: 1040, height: 508)
        }

        // Check if showing search results
        let showSearchResults = isSearchActive && !searchQuery.isEmpty

        // The normal switcher keeps preview geometry reserved even while placeholders are shown.
        let showsPreviewStage = !showSearchResults
            && !appState.isResourceMonitorActive
            && !appState.isUnusedWindowsActive

        // Width calculation
        let width: CGFloat
        if showSearchResults {
            width = 1040
        } else if appState.isUnusedWindowsActive {
            width = 640
        } else if appState.isResourceMonitorActive {
            width = 680
        } else {
            let idealItemsPerRow = min(appCount, 10)
            let baseWidth = CGFloat(idealItemsPerRow) * 58 + 92
            width = min(max(baseWidth, 780), 1040)
        }

        // Height calculation
        let searchBarHeight: CGFloat = isSearchActive ? 54 : 0

        let contentHeight: CGFloat
        if showSearchResults {
            let resultCount = min(appState.searchResults.count, 10)
            let resultsHeight = resultCount == 0 ? 80 : CGFloat(resultCount) * 44 + 24
            contentHeight = max(416, resultsHeight + 80)
        } else if appState.isUnusedWindowsActive {
            contentHeight = 460
        } else if appState.isResourceMonitorActive {
            // Resource monitor: bar chart (~100) + header (~20) + entries + hints + padding
            let entryCount = min(appState.resourceEntries.count, 15)
            let chartHeight: CGFloat = 110  // Bar chart area
            let entriesHeight = entryCount == 0 ? 80 : CGFloat(entryCount) * 30 + 24
            let hintsHeight: CGFloat = 30
            contentHeight = chartHeight + entriesHeight + hintsHeight + 14
        } else {
            // Each tile: 58px icon area + label + compact padding.
            let itemsPerRow = max(1, Int((width - 32) / 80))
            let rows = appCount > 0 ? ceil(CGFloat(appCount) / CGFloat(itemsPerRow)) : 1
            let tileHeight: CGFloat = 86
            let gridSpacing: CGFloat = 8
            let gridHeight = rows * tileHeight + (rows - 1) * gridSpacing + 28  // +28 for vertical padding
            let hintsHeight: CGFloat = 30
            let previewStageHeight: CGFloat = showsPreviewStage ? 342 : 0
            contentHeight = gridHeight + hintsHeight + previewStageHeight + 42
        }

        // No extra padding needed - native NSPanel shadow extends beyond frame automatically
        return CGSize(width: width, height: searchBarHeight + contentHeight)
    }

    private func nativePreviewWidth(for windowCount: Int, on screen: NSScreen?) -> CGFloat {
        let screenWidth = screen?.visibleFrame.width ?? screen?.frame.width ?? 1440
        let maximumWidth = min(screenWidth * 0.92, 1320)

        let idealWidth: CGFloat
        switch windowCount {
        case 0...1:
            idealWidth = 620
        case 2:
            idealWidth = 900
        case 3:
            idealWidth = 1180
        default:
            idealWidth = 1240
        }

        let minimumWidth = min(620, maximumWidth)
        return max(minimumWidth, min(idealWidth, maximumWidth))
    }

    private func maximumPanelWidth(on screen: NSScreen, mode: SwitcherPresentationMode) -> CGFloat {
        switch mode {
        case .nativePreview:
            return min(screen.visibleFrame.width * 0.92, 1320)
        case .workspace:
            if AppState.shared.workspaceMode == .currentAppWindows {
                return min(screen.visibleFrame.width * 0.92, 1320)
            }
            return min(screen.frame.width * 0.88, 1040)
        }
    }

    private func constrainedPanelSize(
        fittingSize: CGSize,
        on screen: NSScreen,
        mode: SwitcherPresentationMode
    ) -> CGSize? {
        let maxWidth = maximumPanelWidth(on: screen, mode: mode)
        let maxHeight: CGFloat = min(screen.frame.height * 0.85, 800)
        var panelSize = CGSize(
            width: min(fittingSize.width, maxWidth),
            height: min(fittingSize.height, maxHeight)
        )

        guard mode == .nativePreview else { return panelSize }
        guard let switcherFrame = nativePlacementFrame(AppState.shared.nativeSwitcherFrame, on: screen) else {
            return nil
        }

        let availableBelow = switcherFrame.minY
            - screen.visibleFrame.minY
            - nativePlacementMargin
            - nativeAnchorGap

        guard availableBelow >= minimumNativePreviewHeight else {
            return nil
        }

        panelSize.height = min(panelSize.height, availableBelow)
        return panelSize
    }

    private func recenterIfVisible() {
        pendingRecenterWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.commitRecenterIfVisible()
        }
        pendingRecenterWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func commitRecenterIfVisible() {
        guard isVisible, let screen = associatedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        // Get the intrinsic size from SwiftUI content
        let fittingSize = presentationMode == .nativePreview ? calculateCurrentSize() : (hostingView?.fittingSize ?? calculateCurrentSize())

        // Apply screen bounds
        guard let panelSize = constrainedPanelSize(
            fittingSize: fittingSize,
            on: screen,
            mode: presentationMode
        ) else {
            hideNativePreviewForInvalidPlacementIfNeeded(mode: presentationMode)
            return
        }

        // Keep workspace growth anchored to the grid. Native Cmd+Tab previews follow
        // the currently selected Dock switcher item when AX exposes its frame.
        let origin: CGPoint
        if presentationMode == .nativePreview {
            guard let nativeOrigin = originForPanel(size: panelSize, on: screen, mode: presentationMode) else {
                hideNativePreviewForInvalidPlacementIfNeeded(mode: presentationMode)
                return
            }
            origin = nativeOrigin
        } else {
            origin = CGPoint(
                x: screen.frame.midX - panelSize.width / 2,
                y: gridTopY - panelSize.height
            )
        }

        let newFrame = CGRect(origin: origin, size: panelSize)
        let expectedNativeGeneration = presentationMode == .nativePreview ? AppState.shared.nativeSelectionGeneration : nil
        guard canCommitLayout(expectedNativeGeneration: expectedNativeGeneration) else { return }

        if presentationMode == .nativePreview {
            setFrame(newFrame, display: true)
            return
        }

        // Animate the frame change for search bar
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(newFrame, display: true)
        }
    }

    /// Resize panel for window list without animation - keeps top anchored, grows downward instantly
    private func resizeForWindowList() {
        guard isVisible, let screen = associatedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        // Get the intrinsic size from SwiftUI content
        let fittingSize = presentationMode == .nativePreview ? calculateCurrentSize() : (hostingView?.fittingSize ?? calculateCurrentSize())

        // Apply screen bounds
        guard let panelSize = constrainedPanelSize(
            fittingSize: fittingSize,
            on: screen,
            mode: presentationMode
        ) else {
            hideNativePreviewForInvalidPlacementIfNeeded(mode: presentationMode)
            return
        }

        // Keep workspace top anchored. Native Cmd+Tab previews follow the selected
        // native switcher item if the Dock exposes one.
        let currentTop = frame.origin.y + frame.size.height
        let origin: CGPoint
        if presentationMode == .nativePreview {
            guard let nativeOrigin = originForPanel(size: panelSize, on: screen, mode: presentationMode) else {
                hideNativePreviewForInvalidPlacementIfNeeded(mode: presentationMode)
                return
            }
            origin = nativeOrigin
        } else {
            origin = CGPoint(
                x: screen.frame.midX - panelSize.width / 2,
                y: currentTop - panelSize.height
            )
        }

        // Set frame instantly (no animation) - SwiftUI will animate the content
        setFrame(CGRect(origin: origin, size: panelSize), display: true)
    }

    private func applyWindowLevel(for mode: SwitcherPresentationMode) {
        level = mode == .nativePreview ? .screenSaver : .statusBar
    }

    private func verticalOffset(for mode: SwitcherPresentationMode) -> CGFloat {
        mode == .nativePreview ? 170 : 40
    }

    private func originForPanel(size panelSize: CGSize, on screen: NSScreen, mode: SwitcherPresentationMode) -> CGPoint? {
        if mode == .nativePreview {
            return nativeOriginForPanel(size: panelSize, on: screen)
        }

        return CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.midY - panelSize.height / 2 + verticalOffset(for: mode)
        )
    }

    private func nativeOriginForPanel(size panelSize: CGSize, on screen: NSScreen) -> CGPoint? {
        let appState = AppState.shared
        if appState.hasNativePlacementAnchor,
           let selectedItemFrame = nativePlacementFrame(appState.nativeSelectedItemFrame, on: screen),
           let switcherFrame = nativePlacementFrame(appState.nativeSwitcherFrame, on: screen) {
            return anchoredNativeOrigin(
                panelSize: panelSize,
                selectedItemFrame: selectedItemFrame,
                switcherFrame: switcherFrame,
                screen: screen
            )
        }

        // Fallback while Dock AX frames are missing — never return nil (nil used to hide the panel).
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - panelSize.width / 2
        let y = visibleFrame.maxY - panelSize.height - 180
        return CGPoint(
            x: clamped(x, min: visibleFrame.minX + nativePlacementMargin, max: visibleFrame.maxX - panelSize.width - nativePlacementMargin),
            y: clamped(y, min: visibleFrame.minY + nativePlacementMargin, max: visibleFrame.maxY - panelSize.height - nativePlacementMargin)
        )
    }

    private func nativePlacementFrame(_ frame: CGRect?, on screen: NSScreen) -> CGRect? {
        guard let frame,
              frame.width > 1,
              frame.height > 1 else {
            return nil
        }

        if screen.frame.intersects(frame) || screen.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) {
            return frame
        }

        return nil
    }

    private func anchoredNativeOrigin(
        panelSize: CGSize,
        selectedItemFrame: CGRect,
        switcherFrame: CGRect,
        screen: NSScreen
    ) -> CGPoint {
        let visibleFrame = screen.visibleFrame
        let minX = visibleFrame.minX + nativePlacementMargin
        let maxX = visibleFrame.maxX - panelSize.width - nativePlacementMargin
        let x = clamped(selectedItemFrame.midX - panelSize.width / 2, min: minX, max: maxX)

        let belowY = switcherFrame.minY - panelSize.height - nativeAnchorGap
        let minY = visibleFrame.minY + nativePlacementMargin
        let maxY = visibleFrame.maxY - panelSize.height - nativePlacementMargin

        return CGPoint(x: x, y: clamped(belowY, min: minY, max: maxY))
    }

    private func clamped(_ value: CGFloat, min lowerBound: CGFloat, max upperBound: CGFloat) -> CGFloat {
        guard lowerBound <= upperBound else { return lowerBound }
        return Swift.min(Swift.max(value, lowerBound), upperBound)
    }

    private func hideNativePreviewForInvalidPlacementIfNeeded(mode: SwitcherPresentationMode) {
        guard mode == .nativePreview, isVisible else { return }

        // Keep preview visible during an active native Cmd+Tab snapshot.
        if AppState.shared.isNativeTraversalSnapshotActive {
            recenterIfVisible()
            return
        }

        stopClickOutsideMonitor()
        alphaValue = 0
        orderOut(nil)
    }

    private func canCommitLayout(expectedNativeGeneration: UInt64?) -> Bool {
        guard let expectedNativeGeneration else { return true }
        return presentationMode == .nativePreview
            && AppState.shared.nativeSelectionGeneration == expectedNativeGeneration
    }

    // MARK: - Public Methods

    /// Show using already-cached data (called after quick-switch timeout)
    /// This is fully synchronous for maximum speed - uses lock-free cache read
    func showWithCachedData(mode: SwitcherPresentationMode = .workspace) {
        presentationMode = mode
        guard let screen = associatedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        let startTime = CFAbsoluteTimeGetCurrent()

        // Use lock-free cached data (prefetch may still be running, that's OK)
        let apps = WindowCache.shared.getCachedApplications()

        // If no cached data yet, do a quick sync fetch (fallback)
        let finalApps = apps.isEmpty ? WindowCache.shared.getApplicationsSync(forceRefresh: true) : apps

        AppState.shared.applications = finalApps
        // Select index 1 (previous app) by default, since index 0 is the current frontmost app
        AppState.shared.selectedAppIndex = finalApps.count > 1 ? 1 : 0
        AppState.shared.selectedWindowIndex = 0
        AppState.shared.prepareForPresentation(mode)
        applyWindowLevel(for: mode)

        // Get the intrinsic size from SwiftUI content
        let fittingSize = hostingView?.fittingSize ?? calculateCurrentSize()

        // Apply screen bounds
        guard let panelSize = constrainedPanelSize(
            fittingSize: fittingSize,
            on: screen,
            mode: mode
        ) else {
            hideNativePreviewForInvalidPlacementIfNeeded(mode: mode)
            return
        }

        guard let origin = originForPanel(size: panelSize, on: screen, mode: mode) else {
            hideNativePreviewForInvalidPlacementIfNeeded(mode: mode)
            return
        }
        setFrame(CGRect(origin: origin, size: panelSize), display: true)

        // Store the top of the grid as anchor point (top of panel since no search bar initially)
        gridTopY = origin.y + panelSize.height

        presentWithEntranceAnimation()

        // Start monitoring for clicks outside the panel
        startClickOutsideMonitor()

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        print("[SwitcherPanel] Shown in \(Int(elapsed))ms with \(finalApps.count) apps, size: \(Int(panelSize.width))x\(Int(panelSize.height))")
    }

    /// Legacy show method (forces refresh) - synchronous
    func show(mode: SwitcherPresentationMode = .workspace) {
        presentationMode = mode
        guard let screen = associatedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        let apps = WindowCache.shared.getApplicationsSync(forceRefresh: true)
        AppState.shared.applications = apps
        // Select index 1 (previous app) by default, since index 0 is the current frontmost app
        AppState.shared.selectedAppIndex = apps.count > 1 ? 1 : 0
        AppState.shared.selectedWindowIndex = 0
        AppState.shared.prepareForPresentation(mode)
        applyWindowLevel(for: mode)

        // Get the intrinsic size from SwiftUI content
        let fittingSize = hostingView?.fittingSize ?? calculateCurrentSize()

        // Apply screen bounds
        guard let panelSize = constrainedPanelSize(
            fittingSize: fittingSize,
            on: screen,
            mode: mode
        ) else {
            hideNativePreviewForInvalidPlacementIfNeeded(mode: mode)
            return
        }

        guard let origin = originForPanel(size: panelSize, on: screen, mode: mode) else {
            hideNativePreviewForInvalidPlacementIfNeeded(mode: mode)
            return
        }
        setFrame(CGRect(origin: origin, size: panelSize), display: true)

        // Store the top of the grid as anchor point (top of panel since no search bar initially)
        gridTopY = origin.y + panelSize.height

        presentWithEntranceAnimation()

        // Start monitoring for clicks outside the panel
        startClickOutsideMonitor()
        print("[SwitcherPanel] Shown with size: \(Int(panelSize.width))x\(Int(panelSize.height))")
    }

    /// Show panel on its associated screen (used by SwitcherPanelManager for multi-screen display)
    /// - Parameter skipStateUpdate: If true, assumes AppState is already updated by the manager
    func showOnScreen(mode: SwitcherPresentationMode = .workspace, skipStateUpdate: Bool = false) {
        presentationMode = mode
        applyWindowLevel(for: mode)
        guard let screen = associatedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        if !skipStateUpdate {
            let apps = WindowCache.shared.getCachedApplications()
            let finalApps = apps.isEmpty ? WindowCache.shared.getApplicationsSync(forceRefresh: true) : apps
            AppState.shared.applications = finalApps
            AppState.shared.selectedAppIndex = finalApps.count > 1 ? 1 : 0
            AppState.shared.selectedWindowIndex = 0
            AppState.shared.prepareForPresentation(mode)
        }

        // Get the intrinsic size from SwiftUI content
        let fittingSize = hostingView?.fittingSize ?? calculateCurrentSize()

        // Apply screen bounds
        guard let panelSize = constrainedPanelSize(
            fittingSize: fittingSize,
            on: screen,
            mode: mode
        ) else {
            hideNativePreviewForInvalidPlacementIfNeeded(mode: mode)
            return
        }

        guard let origin = originForPanel(size: panelSize, on: screen, mode: mode) else {
            hideNativePreviewForInvalidPlacementIfNeeded(mode: mode)
            return
        }
        setFrame(CGRect(origin: origin, size: panelSize), display: true)

        // Store the top of the grid as anchor point
        gridTopY = origin.y + panelSize.height

        presentWithEntranceAnimation()

        // Start monitoring for clicks outside (posts notification for manager to handle)
        startClickOutsideMonitor()
    }

    /// Recenter on the associated screen (called when screen configuration changes)
    func recenterOnAssociatedScreen() {
        recenterIfVisible()
    }

    /// Hide the panel without resetting AppState (used by manager)
    func hidePanel() {
        stopClickOutsideMonitor()
        dismissWithExitAnimation()
    }

    func hide() {
        // Stop monitoring clicks
        stopClickOutsideMonitor()

        dismissWithExitAnimation()
        AppState.shared.reset()
        SwitcherPanelManager.shared.scheduleIdlePreviewMemoryTrim(reason: "single panel hidden")

        print("[SwitcherPanel] Hidden")
    }

    private func presentWithEntranceAnimation() {
        hostingView?.layer?.removeAnimation(forKey: "switcherScaleOut")
        hostingView?.layer?.removeAnimation(forKey: "switcherScaleIn")
        hostingView?.layer?.setAffineTransform(.identity)
        // Instant keyboard show — match native Cmd+Tab (no fade/scale).
        alphaValue = 1
        if presentationMode == .workspace {
            makeKeyAndOrderFront(nil)
            makeFirstResponder(hostingView)
        } else {
            orderFrontRegardless()
        }
    }

    private func dismissWithExitAnimation() {
        guard isVisible else {
            alphaValue = 0
            orderOut(nil)
            return
        }

        hostingView?.layer?.removeAnimation(forKey: "switcherScaleIn")
        hostingView?.layer?.removeAnimation(forKey: "switcherScaleOut")

        // Native Cmd+Tab preview should vanish with the system switcher — no fade linger.
        if presentationMode == .nativePreview {
            alphaValue = 0
            orderOut(nil)
            hostingView?.layer?.setAffineTransform(.identity)
            return
        }

        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = 1.0
        scaleAnimation.toValue = 0.985
        scaleAnimation.duration = dismissalDuration
        scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        hostingView?.layer?.add(scaleAnimation, forKey: "switcherScaleOut")

        NSAnimationContext.runAnimationGroup { context in
            context.duration = dismissalDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.hostingView?.layer?.setAffineTransform(.identity)
                self?.orderOut(nil)
            }
        }
    }

    private func startClickOutsideMonitor() {
        // Monitor for mouse clicks outside the panel
        // Posts notification so SwitcherPanelManager can check ALL panels before dismissing
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isVisible else { return }

            let screenLocation = NSEvent.mouseLocation

            // Post notification with click location - manager will check all panels
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .clickOutsideDetected,
                    object: nil,
                    userInfo: ["location": screenLocation]
                )
            }
        }
    }

    private func stopClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    func selectNext() {
        AppState.shared.selectNextApp()
    }

    func selectPrevious() {
        AppState.shared.selectPreviousApp()
    }

    func selectNextWindow() {
        AppState.shared.selectNextWindow()
    }

    func selectPreviousWindow() {
        AppState.shared.selectPreviousWindow()
    }

    func activateSearch() {
        presentationMode = .workspace
        applyWindowLevel(for: .workspace)
        AppState.shared.isSearchActive = true
        // Make the panel key to receive keyboard input
        makeKeyAndOrderFront(nil)
    }

    func confirmSelection() {
        guard let app = AppState.shared.selectedApp else {
            hide()
            // Notify that we're done (so event tap updates its state)
            NotificationCenter.default.post(name: .switcherConfirmedByMouseClick, object: nil)
            return
        }

        let windowIndex = AppState.shared.selectedWindowIndex

        // Hide first for responsiveness
        hide()

        // Notify that we confirmed via mouse click (so event tap updates its state)
        // This prevents double-confirm when modifier is released after click
        NotificationCenter.default.post(name: .switcherConfirmedByMouseClick, object: nil)

        // Then switch synchronously
        if app.windows.indices.contains(windowIndex) {
            let window = app.windows[windowIndex]
            postWorkspaceWindowActivationIfNeeded(app: app, window: window, windowIndex: windowIndex)
            WindowSwitcher.shared.switchTo(window: window, in: app, windowIndex: windowIndex)
        } else {
            WindowSwitcher.shared.activate(app: app)
        }
    }

    private func postWorkspaceWindowActivationIfNeeded(
        app: ApplicationModel,
        window: WindowModel,
        windowIndex: Int
    ) {
        guard AppState.shared.presentationMode == .workspace,
              !window.isWindowlessPlaceholder else {
            return
        }

        NotificationCenter.default.post(
            name: .workspaceWindowActivated,
            object: nil,
            userInfo: [
                "pid": app.pid,
                "windowIndex": windowIndex
            ]
        )
    }

    override func keyDown(with event: NSEvent) {
        guard handleWorkspaceKeyDown(event) else {
            super.keyDown(with: event)
            return
        }
    }

    override func cancelOperation(_ sender: Any?) {
        SwitcherPanelManager.shared.hide()
    }

    private func handleWorkspaceKeyDown(_ event: NSEvent) -> Bool {
        guard AppState.shared.presentationMode == .workspace else { return false }

        let isShiftPressed = event.modifierFlags.contains(.shift)
        switch Int(event.keyCode) {
        case kVK_Escape:
            SwitcherPanelManager.shared.hide()
            return true
        case kVK_Return:
            if AppState.shared.isSearchActive {
                SwitcherPanelManager.shared.confirmSelection()
            } else {
                NotificationCenter.default.post(name: .activateSwitcherSearch, object: nil)
            }
            return true
        case kVK_Space, kVK_ANSI_Slash:
            guard !AppState.shared.isSearchActive else { return false }
            AppState.shared.pinWorkspaceSearch()
            SwitcherPanelManager.shared.activateSearch()
            return true
        case kVK_Tab:
            if AppState.shared.isSearchingWithQuery {
                isShiftPressed ? AppState.shared.selectPreviousWindow() : AppState.shared.selectNextWindow()
            } else if AppState.shared.workspaceMode == .currentAppWindows {
                isShiftPressed ? AppState.shared.selectPreviousWindow() : AppState.shared.selectNextWindow()
            } else {
                isShiftPressed ? AppState.shared.selectPreviousApp() : AppState.shared.selectNextApp()
            }
            return true
        case kVK_LeftArrow:
            if AppState.shared.isSearchingWithQuery {
                AppState.shared.selectPreviousApp()
            } else if AppState.shared.workspaceMode == .currentAppWindows {
                AppState.shared.selectPreviousWindow()
            } else {
                AppState.shared.selectPreviousApp()
            }
            return true
        case kVK_RightArrow:
            if AppState.shared.isSearchingWithQuery {
                AppState.shared.selectNextApp()
            } else if AppState.shared.workspaceMode == .currentAppWindows {
                AppState.shared.selectNextWindow()
            } else {
                AppState.shared.selectNextApp()
            }
            return true
        case kVK_UpArrow:
            if AppState.shared.isSearchingWithQuery || AppState.shared.workspaceMode == .globalWindowSearch {
                AppState.shared.selectPreviousApp()
            } else {
                AppState.shared.selectPreviousWindow()
            }
            return true
        case kVK_DownArrow:
            if AppState.shared.isSearchingWithQuery || AppState.shared.workspaceMode == .globalWindowSearch {
                AppState.shared.selectNextApp()
            } else {
                AppState.shared.selectNextWindow()
            }
            return true
        case kVK_ANSI_Grave:
            isShiftPressed ? AppState.shared.selectPreviousWindow() : AppState.shared.selectNextWindow()
            return true
        default:
            return false
        }
    }
}
