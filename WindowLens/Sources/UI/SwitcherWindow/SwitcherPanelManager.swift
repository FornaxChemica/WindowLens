import AppKit
import Combine

/// Manages multiple SwitcherPanel instances for multi-screen display
@MainActor
final class SwitcherPanelManager {
    static let shared = SwitcherPanelManager()

    /// Active panels keyed by screen identifier
    private var panels: [String: SwitcherPanel] = [:]

    /// Cancellables for Combine subscriptions
    private var cancellables = Set<AnyCancellable>()
    private var idlePreviewTrimWorkItem: DispatchWorkItem?

    private init() {
        setupScreenObserver()
        setupClickOutsideHandler()
    }

    // MARK: - Screen Observation

    private func setupScreenObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenConfigurationChange()
            }
        }
    }

    private func handleScreenConfigurationChange() {
        let currentScreenIds = Set(NSScreen.screens.compactMap { screenIdentifier(for: $0) })
        let existingIds = Set(panels.keys)

        // Remove panels for disconnected screens
        let removedIds = existingIds.subtracting(currentScreenIds)
        for id in removedIds {
            panels[id]?.orderOut(nil)
            panels.removeValue(forKey: id)
            WLLog.switcher.debug("Removed panel for disconnected screen: \(id)")
        }

        // If panels are currently visible, add panels for new screens
        if AppState.shared.isVisible {
            let addedIds = currentScreenIds.subtracting(existingIds)
            for screen in NSScreen.screens {
                if let id = screenIdentifier(for: screen), addedIds.contains(id) {
                    let panel = createPanel(for: screen)
                    panels[id] = panel
                    panel.showOnScreen(mode: AppState.shared.presentationMode, skipStateUpdate: true)
                    WLLog.switcher.debug("Added panel for new screen: \(id)")
                }
            }
        }

        // Recenter existing panels (screen bounds may have changed)
        for panel in panels.values where panel.isVisible {
            panel.recenterOnAssociatedScreen()
        }
    }

    private func screenIdentifier(for screen: NSScreen) -> String? {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            return "\(number)"
        }
        // Fallback to frame origin
        return "\(Int(screen.frame.origin.x))_\(Int(screen.frame.origin.y))"
    }

    // MARK: - Panel Creation

    private func createPanel(for screen: NSScreen) -> SwitcherPanel {
        return SwitcherPanel(screen: screen)
    }

    private func ensurePanelsExist() {
        for screen in NSScreen.screens {
            guard let id = screenIdentifier(for: screen) else { continue }
            if panels[id] == nil {
                panels[id] = createPanel(for: screen)
            } else {
                // Update the screen reference in case it changed
                panels[id]?.updateAssociatedScreen(screen)
            }
        }
    }

    private func ensurePanelExists(for screen: NSScreen) -> SwitcherPanel? {
        guard let id = screenIdentifier(for: screen) else { return nil }
        if let panel = panels[id] {
            panel.updateAssociatedScreen(screen)
            return panel
        }

        let panel = createPanel(for: screen)
        panels[id] = panel
        return panel
    }

    // MARK: - Show/Hide

    func showWithCachedData(mode: SwitcherPresentationMode = .workspace) {
        let startTime = CFAbsoluteTimeGetCurrent()

        ensurePanelsExist()

        // Update AppState ONCE
        let apps = WindowCache.shared.getCachedApplications()
        let finalApps = apps.isEmpty ? WindowCache.shared.getApplicationsSync(forceRefresh: true) : apps
        AppState.shared.applications = finalApps
        AppState.shared.selectedAppIndex = finalApps.count > 1 ? 1 : 0
        AppState.shared.selectedWindowIndex = 0
        AppState.shared.prepareForPresentation(mode)

        // Show all panels (without re-updating state)
        for panel in panels.values {
            panel.showOnScreen(mode: mode, skipStateUpdate: true)
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        WLLog.switcher.debug("Shown \(self.panels.count) panels in \(Int(elapsed))ms with \(finalApps.count) apps")
    }

    func show(mode: SwitcherPresentationMode = .workspace) {
        ensurePanelsExist()

        let apps = WindowCache.shared.getApplicationsSync(forceRefresh: true)
        AppState.shared.applications = apps
        AppState.shared.selectedAppIndex = apps.count > 1 ? 1 : 0
        AppState.shared.selectedWindowIndex = 0
        AppState.shared.prepareForPresentation(mode)

        for panel in panels.values {
            panel.showOnScreen(mode: mode, skipStateUpdate: true)
        }

        WLLog.switcher.debug("Shown \(self.panels.count) panels")
    }

    func showNativePreview(applications: [ApplicationModel], showImmediately: Bool = true) {
        AppState.shared.beginNativePreviewSession(applications)
        if showImmediately {
            showNativePanelOnTargetScreen()
        }
        WLLog.switcher.debug("Shown native preview session with \(applications.count) apps")
    }

    func showNativeFallbackPreviewPanel() {
        guard AppState.shared.hasNativeSelection else { return }
        showNativePanelOnTargetScreen()
    }

    /// Show the native preview panel even before Dock AX has delivered a selection.
    func showNativePreviewPanelPendingSelection() {
        guard AppState.shared.presentationMode == .nativePreview else { return }
        showNativePanelOnTargetScreen()
    }

    func showNativeTraversalSnapshot(applications: [ApplicationModel], reverse: Bool) {
        AppState.shared.beginNativeTraversalSnapshot(applications, reverse: reverse)
        showNativePanelOnTargetScreen()
        WLLog.switcher.debug("Shown frozen native traversal snapshot with \(applications.count) apps")
    }

    func showCurrentAppWindowSwitcher() {
        AppState.shared.startWorkspaceWindowListRefreshTimerIfNeeded()

        guard let targetScreen = workspaceSwitcherScreen(),
              let targetPanel = ensurePanelExists(for: targetScreen) else { return }

        for panel in panels.values where panel !== targetPanel {
            if panel.isVisible {
                panel.hidePanel()
            }
        }

        targetPanel.showOnScreen(mode: .workspace, skipStateUpdate: true)
        WLLog.switcher.debug("Shown current-app window switcher")
    }

    private func showNativePanelOnTargetScreen() {
        let targetScreen = nativePreviewScreen()
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let targetScreen,
              let targetPanel = ensurePanelExists(for: targetScreen) else { return }

        for panel in panels.values where panel !== targetPanel {
            if panel.isVisible {
                panel.hidePanel()
            }
        }

        if targetPanel.isVisible {
            targetPanel.recenterOnAssociatedScreen()
        } else {
            targetPanel.showOnScreen(mode: .nativePreview, skipStateUpdate: true)
        }
    }

    private func hideVisibleNativePreviewPanels() {
        guard AppState.shared.presentationMode == .nativePreview else { return }

        for panel in panels.values where panel.isVisible {
            panel.hidePanel()
        }
    }

    private func workspaceSwitcherScreen() -> NSScreen? {
        if let app = AppState.shared.selectedApp,
           let window = app.windows.first(where: { window in
               !window.isWindowlessPlaceholder && window.bounds.width > 16 && window.bounds.height > 16
           }),
           let screen = screenContaining(CGRect(
               x: window.bounds.minX,
               y: window.bounds.minY,
               width: window.bounds.width,
               height: window.bounds.height
           )) {
            return screen
        }

        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let screen = screenContainingFrontmostWindow(for: frontmost.processIdentifier) {
            return screen
        }

        return nativePreviewScreen()
    }

    private func screenContainingFrontmostWindow(for pid: pid_t) -> NSScreen? {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in windowInfo {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"],
                  width > 16,
                  height > 16,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0 else {
                continue
            }

            let frame = CGRect(x: x, y: y, width: width, height: height)
            if let screen = screenContaining(frame) {
                return screen
            }
        }

        return nil
    }

    private func screenContaining(_ frame: CGRect) -> NSScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    private func nativePreviewScreen() -> NSScreen? {
        if let anchorFrame = AppState.shared.nativeSelectedItemFrame {
            let center = CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                return screen
            }
        }

        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return screen
        }

        return NSScreen.main ?? NSScreen.screens.first
    }

    func hide() {
        for panel in panels.values {
            panel.hidePanel()
        }
        AppState.shared.reset()
        scheduleIdlePreviewMemoryTrim(reason: "switcher hidden")
        WLLog.switcher.debug("Hidden all \(self.panels.count) panels")
    }

    func scheduleIdlePreviewMemoryTrim(reason: String) {
        idlePreviewTrimWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            Task { @MainActor in
                guard !AppState.shared.isVisible else {
                    WLLog.switcher.error("Idle preview trim skipped because switcher reopened: \(reason)")
                    return
                }

                AppState.shared.clearPreviewImages(reason: "idle after \(reason)")
                WindowCache.shared.clearPreviewImages(reason: "idle after \(reason)")
                WindowPreviewService.shared.trimVolatileMemory(reason: "idle after \(reason)")
                WLLog.switcher.debug("Idle preview memory trim completed after \(reason)")
            }
        }

        idlePreviewTrimWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 45.0, execute: workItem)
    }

    func reconcileSystemActivation(
        applications: [ApplicationModel],
        activePID: pid_t?,
        preserveCurrentSelection: Bool = false
    ) {
        guard !AppState.shared.isNativeTraversalSnapshotActive else {
            WLLog.switcher.debug("Deferred visible MRU reconciliation during native Cmd+Tab snapshot")
            return
        }

        AppState.shared.reconcileApplications(
            applications,
            selectedPID: activePID,
            preserveCurrentSelection: preserveCurrentSelection
        )

        for panel in panels.values where panel.isVisible {
            panel.recenterOnAssociatedScreen()
        }
    }

    func reconcileFrontmostApplication(preserveCurrentSelection: Bool = false) {
        let applications = WindowCache.shared.reconcileFrontmostApplication()
        let activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        reconcileSystemActivation(
            applications: applications,
            activePID: activePID,
            preserveCurrentSelection: preserveCurrentSelection
        )
    }

    func finishNativeTraversalAndReconcileFrontmost() {
        AppState.shared.endNativeTraversalSnapshot()
        reconcileFrontmostApplication()
    }

    @discardableResult
    func selectNativeDockSelection(_ selection: DockProcessSwitcherSelection) -> Bool {
        // Match against the frozen Cmd+Tab session snapshot — never re-enumerate on highlight.
        let resolvedApplication = WindowCache.shared.applicationMatchingForNativePreview(
            pid: selection.pid,
            bundleIdentifier: selection.bundleIdentifier,
            in: AppState.shared.applications
        ) ?? AppState.shared.applications.first { app in
            if let pid = selection.pid, app.pid == pid {
                return true
            }
            if let bundleIdentifier = selection.bundleIdentifier, app.bundleIdentifier == bundleIdentifier {
                return true
            }
            return false
        }.map(WindowEnumerator.normalizeFinderApplicationIfNeeded)
        ?? nativePlaceholderApplication(for: selection)

        let didSelect = AppState.shared.selectNativeApplication(
            pid: resolvedApplication.pid,
            bundleIdentifier: resolvedApplication.bundleIdentifier,
            title: resolvedApplication.name,
            anchorFrame: selection.frame,
            switcherFrame: selection.switcherFrame,
            resolvedApplication: resolvedApplication
        )

        if didSelect {
            showNativePanelOnTargetScreen()
        }

        return didSelect
    }

    private func nativePlaceholderApplication(for selection: DockProcessSwitcherSelection) -> ApplicationModel {
        let runningApplication = runningApplication(for: selection)
        let pid = runningApplication?.processIdentifier ?? selection.pid ?? -1
        let bundleIdentifier = runningApplication?.bundleIdentifier
            ?? selection.bundleIdentifier
            ?? "native.placeholder.\(pid)"
        let appName = runningApplication?.localizedName
            ?? selection.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "No Windows"
        let icon = runningApplication?.icon
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage()
        let windowTitle = runningApplication == nil ? appName : "No Windows"
        let windowID = PreviewIdentity.pseudoWindowID(
            ownerPID: pid,
            axIndex: 0,
            title: windowTitle,
            bounds: .zero
        )
        let placeholderWindow = WindowModel(
            windowID: windowID,
            title: windowTitle,
            bounds: .zero,
            isMinimized: false,
            isOnScreen: false,
            ownerPID: pid,
            bundleIdentifier: bundleIdentifier,
            axIndex: 0,
            hasReliableWindowID: false,
            previewImage: nil,
            subtitle: "No Windows"
        )

        return ApplicationModel(
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            name: appName,
            icon: icon,
            windows: [placeholderWindow],
            isActive: runningApplication?.isActive ?? false
        )
    }

    private func runningApplication(for selection: DockProcessSwitcherSelection) -> NSRunningApplication? {
        if let pid = selection.pid,
           let app = NSRunningApplication(processIdentifier: pid),
           app.activationPolicy == .regular {
            return app
        }

        if let bundleIdentifier = selection.bundleIdentifier,
           let app = NSWorkspace.shared.runningApplications.first(where: {
               $0.activationPolicy == .regular && $0.bundleIdentifier == bundleIdentifier
           }) {
            return app
        }

        guard let title = selection.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }

        let normalizedTitle = PreviewIdentity.normalizedTitle(title)
        return NSWorkspace.shared.runningApplications.first { app in
            guard app.activationPolicy == .regular,
                  let localizedName = app.localizedName else {
                return false
            }

            let appName = PreviewIdentity.normalizedTitle(localizedName)
            return appName == normalizedTitle
                || normalizedTitle.contains(appName)
                || appName.contains(normalizedTitle)
        }
    }

    // MARK: - Navigation (state is shared via AppState)

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
        AppState.shared.presentationMode = .workspace
        AppState.shared.isSearchActive = true
        NotificationCenter.default.post(name: .workspaceSearchKeyboardCaptureEnabled, object: nil)

        let visiblePanels = panels.values.filter(\.isVisible)
        let keyPanel = visiblePanels.first ?? panels.values.first
        for panel in visiblePanels {
            panel.activateSearch()
        }

        // Make panel key after the resize/layout settles so focus isn't lost.
        keyPanel?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            keyPanel?.makeKeyAndOrderFront(nil)
        }
    }

    func confirmSelection() {
        guard let app = AppState.shared.selectedApp else {
            hide()
            NotificationCenter.default.post(name: .switcherConfirmedByMouseClick, object: nil)
            return
        }

        let windowIndex = AppState.shared.selectedWindowIndex

        // Hide first for responsiveness
        hide()

        // Notify that we confirmed
        NotificationCenter.default.post(name: .switcherConfirmedByMouseClick, object: nil)

        // Then switch
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

    // MARK: - Click Outside Detection

    private func setupClickOutsideHandler() {
        NotificationCenter.default.publisher(for: .clickOutsideDetected)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                guard let location = notification.userInfo?["location"] as? NSPoint else { return }

                // Check if click is inside ANY panel
                let clickInsideAnyPanel = self.panels.values.contains { panel in
                    panel.isVisible && panel.frame.contains(location)
                }

                if !clickInsideAnyPanel {
                    WLLog.switcher.debug("Click outside all panels, dismissing")
                    NotificationCenter.default.post(name: .switcherDismissedByClickOutside, object: nil)
                    self.hide()
                }
            }
            .store(in: &cancellables)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let clickOutsideDetected = Notification.Name("clickOutsideDetected")
}
