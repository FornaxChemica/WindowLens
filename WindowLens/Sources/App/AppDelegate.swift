import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var eventTap: KeyboardEventTap?
    private var panelManager: SwitcherPanelManager { SwitcherPanelManager.shared }
    private var settingsWindow: NSWindow?
    private var heatmapWindow: NSWindow?
    private var deadWindowsWindow: NSWindow?
    private var suppressSettingsOnNextActivation = false
    private var cancellables = Set<AnyCancellable>()
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var windowSlotObserverTokens: [NSObjectProtocol] = []
    private var isNativeCommandTabSessionActive = false
    private var nativeFallbackWorkItem: DispatchWorkItem?
    /// After Dock tears down AXProcessSwitcherList while Cmd is still held (Escape),
    /// cancel our preview if the switcher never comes back.
    private var nativeSwitcherGoneWorkItem: DispatchWorkItem?
    private let nativeSwitcherGoneTimeoutSeconds: TimeInterval = 0.2
    private var nativeWindowSelectionWasAdjusted = false
    private var lastNativePreviewRefreshPID: pid_t?
    private var lastDockSelectionKey: String?
    private var lastWorkspaceWindowIndexByPID: [pid_t: Int] = [:]
    private var hasStartedWindowCache = false
    private var onboardingWindow: NSWindow?
    private var permissionReadyWindow: NSWindow?
    private var permissionMonitorTimer: Timer?
    private var hasCompletedPermissionGate = false
    private var isEventTapSuspendedForMissingInput = false
    private var hasShownReadyWindowThisLaunch = false
    private var lastPermissionAllGranted: Bool?
    private var lastLoggedPermissionStatusDescription: String?
    private let dockProcessSwitcherObserver = DockProcessSwitcherObserver()
    /// Cooldown so activate → showSettings → activate doesn't loop.
    private var lastPrimaryWindowPresentAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        setupEventTap()
        setupWorkspaceRecoveryObservers()
        setupWindowSlotObservers()
        startPermissionMonitoring()
        eventTap?.logStartupDiagnostics(context: "applicationDidFinishLaunching")

        Task { @MainActor in
            await refreshPermissionGate(context: "launch")
            KeepAwakeManager.shared.reconcileOnLaunch()
        }

        // Panel manager is a lazy singleton - will create panels on first show.
        print("[WindowLens] App initialized successfully")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Dock click. MenuBarExtra keeps hasVisibleWindows unreliable — always restore Settings.
        presentPrimaryWindowIfNeeded(reason: "reopen hasVisibleWindows=\(hasVisibleWindows)")
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        for token in workspaceObserverTokens {
            workspaceNotificationCenter.removeObserver(token)
        }
        workspaceObserverTokens.removeAll()

        for token in windowSlotObserverTokens {
            workspaceNotificationCenter.removeObserver(token)
        }
        windowSlotObserverTokens.removeAll()

        WindowNumberRegistry.shared.clearPersistedAssignments()

        dockProcessSwitcherObserver.stop()
        eventTap?.disable()
        permissionMonitorTimer?.invalidate()
        permissionMonitorTimer = nil
        KeepAwakeManager.shared.prepareForTerminate()
        print("[WindowLens] App terminating")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        eventTap?.resetShortcutState(reason: "application did become active")
        Task { @MainActor in
            await refreshPermissionGate(context: "application active")
        }
        presentPrimaryWindowIfNeeded(reason: "applicationDidBecomeActive")
    }

    func applicationDidUnhide(_ notification: Notification) {
        presentPrimaryWindowIfNeeded(reason: "applicationDidUnhide")
    }

    func applicationWillResignActive(_ notification: Notification) {
        eventTap?.resetShortcutState(reason: "application will resign active")
    }

    deinit {
        print("[WindowLens] AppDelegate deinit")
    }

    private func logLaunchDiagnostics(status: PermissionManager.Status, context: String) {
        let bundle = Bundle.main
        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "unknown"
        let executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "unknown"
        let bundleIdentifier = bundle.bundleIdentifier ?? "unknown"
        print("[WindowLens][\(context)] displayName=\(displayName) executable=\(executableName) bundleID=\(bundleIdentifier)")
        print("[WindowLens][\(context)] AXIsProcessTrusted=\(status.accessibility)")
        print("[WindowLens][\(context)] IOHIDCheckAccess.listenEvent=\(status.inputMonitoring)")
        print("[WindowLens][\(context)] CGPreflightScreenCaptureAccess=\(status.screenRecording)")
    }

    private func startPermissionMonitoring() {
        guard permissionMonitorTimer == nil else { return }

        permissionMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshPermissionGate(context: "permission monitor")
            }
        }

        print("[WindowLens] Permission monitor started")
    }

    private func refreshPermissionGate(context: String) async {
        let status = await PermissionManager.shared.checkStatus()
        let previousAllGranted = lastPermissionAllGranted
        let didTransitionToMissing = previousAllGranted == true && !status.allGranted
        let didTransitionToGranted = previousAllGranted == false && status.allGranted
        let statusDescription = status.description
        let shouldLogStatus = context != "permission monitor"
            || didTransitionToMissing
            || didTransitionToGranted
            || lastLoggedPermissionStatusDescription != statusDescription

        lastPermissionAllGranted = status.allGranted

        if shouldLogStatus {
            logLaunchDiagnostics(status: status, context: context)
            lastLoggedPermissionStatusDescription = statusDescription
        }

        guard status.allGranted else {
            hasCompletedPermissionGate = false

            if didTransitionToMissing {
                if AppState.shared.isVisible {
                    panelManager.hide()
                } else {
                    panelManager.scheduleIdlePreviewMemoryTrim(reason: "permission loss")
                }
            }

            if !status.accessibility, hasStartedWindowCache {
                WindowCache.shared.stopMonitoring()
                hasStartedWindowCache = false
                WindowVisitHistory.shared.stopMonitoring()
                print("[WindowLens] WindowCache monitoring stopped: Accessibility permission is missing")
            }

            if !status.inputMonitoring {
                if !isEventTapSuspendedForMissingInput {
                    eventTap?.suspend(reason: "Input Monitoring permission missing")
                    isEventTapSuspendedForMissingInput = true
                } else {
                    eventTap?.resetShortcutState(reason: "Input Monitoring permission still missing")
                }
            } else {
                isEventTapSuspendedForMissingInput = false
            }

            if shouldLogStatus {
                print("[WindowLens] Permission gate blocked context=\(context):\n\(status.description)")
            }

            closePermissionReadyWindow()
            showPermissionOnboardingWindow(
                activate: shouldActivatePermissionWindow(context: context) || didTransitionToMissing
            )
            return
        }

        isEventTapSuspendedForMissingInput = false
        guard !hasCompletedPermissionGate
            || didTransitionToGranted
            || context != "permission monitor" else {
            return
        }

        proceedAfterPermissions(status: status, context: context)
    }

    private func shouldActivatePermissionWindow(context: String) -> Bool {
        context == "launch" || context == "application active"
    }

    private func showPermissionOnboardingWindow(activate: Bool) {
        // Always rebuild so auto-dismiss vs manual Done matches the current gate state.
        closePermissionOnboardingWindow()

        // After the required gate is done, keep the window open so optional
        // privileges (lid-closed stay awake) can be granted without auto-dismiss.
        let autoDismiss = !hasCompletedPermissionGate

        let view = PermissionOnboardingView(autoDismissWhenReady: autoDismiss) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let status = await PermissionManager.shared.checkStatus()
                guard status.allGranted else {
                    self.closePermissionOnboardingWindow()
                    self.showPermissionOnboardingWindow(activate: true)
                    return
                }

                self.closePermissionOnboardingWindow()
                self.proceedAfterPermissions(status: status, context: "onboarding complete")
            }
        }

        let window = makePermissionGlassWindow(
            title: autoDismiss ? "Welcome to WindowLens" : "Permissions",
            styleMask: [.titled, .closable, .fullSizeContentView],
            rootView: view
        )
        window.center()

        onboardingWindow = window
        if activate {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderFront(nil)
        }
        print("[WindowLens] Permission onboarding window shown (autoDismiss=\(autoDismiss))")
    }

    private func closePermissionOnboardingWindow() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    private func showPermissionReadyWindow() {
        guard !hasShownReadyWindowThisLaunch else { return }
        hasShownReadyWindowThisLaunch = true

        if let window = permissionReadyWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = PermissionReadyView { [weak self] in
            self?.closePermissionReadyWindow()
        }
        let window = makePermissionGlassWindow(
            title: "WindowLens is Ready",
            styleMask: [.titled, .closable, .fullSizeContentView],
            rootView: view
        )
        window.center()

        permissionReadyWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("[WindowLens] Permission ready window shown")
    }

    private func closePermissionReadyWindow() {
        permissionReadyWindow?.close()
        permissionReadyWindow = nil
    }

    private func makePermissionGlassWindow<Content: View>(
        title: String,
        styleMask: NSWindow.StyleMask,
        rootView: Content
    ) -> NSWindow {
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = title
        window.styleMask = styleMask
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        return window
    }

    private func proceedAfterPermissions(status: PermissionManager.Status, context: String) {
        guard status.allGranted else {
            hasCompletedPermissionGate = false
            showPermissionOnboardingWindow(activate: shouldActivatePermissionWindow(context: context))
            return
        }

        if !hasCompletedPermissionGate {
            print("[WindowLens] Permission gate completed context=\(context)")
        }
        hasCompletedPermissionGate = true

        startWindowCacheIfAccessibilityTrusted(status: status, context: context)
        WindowVisitHistory.shared.startMonitoring()

        if eventTap?.isInstalled == true {
            eventTap?.verifyOrRebuild(reason: "permissions confirmed \(context)")
        } else {
            eventTap?.scheduleInstall(reason: "permissions confirmed \(context)", delay: 0.5)
        }

        if context == "launch" || context == "onboarding complete" {
            showSettingsWindow()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }

        if window === onboardingWindow {
            onboardingWindow = nil
        } else if window === permissionReadyWindow {
            permissionReadyWindow = nil
        } else if window === heatmapWindow {
            heatmapWindow = nil
        } else if window === deadWindowsWindow {
            deadWindowsWindow = nil
        }

        let closedPrimary =
            window === settingsWindow
            || window === heatmapWindow
            || window === deadWindowsWindow
            || window.identifier == SettingsWindowConfigurator.windowIdentifier
            || window.identifier == HeatmapWindowConfigurator.windowIdentifier
            || window.identifier == DeadWindowsWindowConfigurator.windowIdentifier

        // MenuBarExtra apps can stay "frontmost" with no key window after Settings is
        // closed, so Cmd-Tab back does nothing. Hide so the next Dock/Cmd-Tab is a
        // real activation that restores Settings.
        if closedPrimary {
            DispatchQueue.main.async { [weak self] in
                self?.yieldFrontmostIfNoPrimaryWindow()
            }
        }
    }

    private func startWindowCacheIfAccessibilityTrusted(
        status: PermissionManager.Status,
        context: String
    ) {
        guard status.accessibility else {
            print("[WindowLens] WindowCache startup skipped: Accessibility is not granted context=\(context)")
            return
        }

        guard !hasStartedWindowCache else { return }
        hasStartedWindowCache = true
        WindowCache.shared.startMonitoring()
        WindowCache.shared.prefetchAsync()
        print("[WindowLens] WindowCache monitoring started context=\(context)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            WindowNumberRegistry.shared.initializeFromCache()
        }
    }

    private func setupEventTap() {
        print("[WindowLens] Creating KeyboardEventTap manager")
        eventTap = KeyboardEventTap()

        eventTap?.onShortcutTriggered
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleShortcutEvent(event)
                }
            }
            .store(in: &cancellables)

        // Listen for click-outside-to-dismiss notifications
        NotificationCenter.default.publisher(for: .switcherDismissedByClickOutside)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.eventTap?.setSwitcherVisible(false)
                }
            }
            .store(in: &cancellables)

        // Listen for mouse-click confirmation notifications
        // This prevents double-confirm when modifier is released after clicking
        NotificationCenter.default.publisher(for: .switcherConfirmedByMouseClick)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.eventTap?.setSwitcherVisible(false)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .workspaceWindowActivated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let pid = notification.userInfo?["pid"] as? pid_t,
                          let windowIndex = notification.userInfo?["windowIndex"] as? Int else {
                        return
                    }
                    self?.recordWorkspaceWindowActivation(pid: pid, windowIndex: windowIndex)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .reinstallEventTap)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                _ = Task<Void, Never> { @MainActor [weak self] in
                    guard let self else { return }
                    let status = await PermissionManager.shared.checkStatus()
                    if status.allGranted {
                        self.eventTap?.verifyOrRebuild(reason: "manual menu action")
                    } else {
                        self.showPermissionOnboardingWindow(activate: true)
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openPermissions)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.showPermissionOnboardingWindow(activate: true)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .activateSwitcherSearch)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.panelManager.activateSearch()
                    self?.eventTap?.setSearchModeActive(true)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .workspaceSearchKeyboardCaptureEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.eventTap?.setSearchModeActive(true)
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(
            AppState.shared.$isSearchActive,
            AppState.shared.$searchQuery,
            AppState.shared.$workspaceMode
        )
        .map { isActive, query, workspaceMode in
            workspaceMode == .globalWindowSearch
                || (isActive && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] isSearchingWithQuery in
            MainActor.assumeIsolated {
                self?.eventTap?.setSearchingWithQuery(isSearchingWithQuery)
            }
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .workspaceActiveApplicationDidReconcile)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self,
                          let pid = notification.userInfo?["pid"] as? pid_t,
                          let applications = notification.userInfo?["applications"] as? [ApplicationModel] else {
                        return
                    }

                    guard !self.isNativeCommandTabSessionActive else {
                        print("[WindowLens] Live MRU updated during native Cmd+Tab; visible snapshot remains frozen")
                        return
                    }

                    self.panelManager.reconcileSystemActivation(
                        applications: applications,
                        activePID: pid
                    )

                    if AppState.shared.isVisible,
                       AppState.shared.presentationMode == .workspace,
                       AppState.shared.workspaceMode == .currentAppWindows {
                        self.panelManager.showCurrentAppWindowSwitcher()
                    }
                }
            }
            .store(in: &cancellables)

        dockProcessSwitcherObserver.onSelectionChanged = { [weak self] selection in
            MainActor.assumeIsolated {
                self?.handleDockProcessSwitcherSelection(selection)
            }
        }
        dockProcessSwitcherObserver.onSwitcherDestroyed = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Dock tears down/recreates AXProcessSwitcherList during hopping and on
                // dismiss (Escape). Keep rediscovering while hopping; if the list never
                // returns while Cmd is held, treat it as cancel (Escape).
                if self.isNativeCommandTabSessionActive {
                    let commandDown = NSEvent.modifierFlags.contains(.command)
                    self.dockProcessSwitcherObserver.start()
                    if commandDown {
                        self.scheduleNativeSwitcherGoneCancelIfNeeded()
                    }
                    return
                }
            }
        }

        // Load shortcut bindings from preferences.
        eventTap?.reloadShortcutBindings(from: AppState.shared.preferences)
        print("[WindowLens] Loaded workspace activation shortcut: \(AppState.shared.preferences.shortcuts.workspaceOpen.displayString)")

        NotificationCenter.default.publisher(for: .openSettings)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.showSettingsWindow()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openHeatmap)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.showHeatmapWindow()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openDeadWindows)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.showDeadWindowsWindow()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openStayAwake)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                // Stay Awake lives in the menu bar panel — nudge the user via activation.
                NSApp.activate(ignoringOtherApps: true)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .shortcutsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.eventTap?.reloadShortcutBindings(from: AppState.shared.preferences)
                }
            }
            .store(in: &cancellables)

        print("[WindowLens] Event tap configured")
        eventTap?.logStartupDiagnostics(context: "setupEventTap complete")
    }

    private func setupWorkspaceRecoveryObservers() {
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter

        let sessionToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[WindowLens] NSWorkspace session became active; refreshing permission gate")
            Task { @MainActor [weak self] in
                await self?.refreshPermissionGate(context: "workspace session became active")
            }
        }

        let wakeToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[WindowLens] NSWorkspace did wake; refreshing permission gate")
            Task { @MainActor [weak self] in
                await self?.refreshPermissionGate(context: "workspace did wake")
            }
        }

        // Cmd-Tab often leaves MenuBarExtra apps "frontmost" without NSApp.isActive /
        // applicationDidBecomeActive. Workspace activation is the reliable signal.
        let activateToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Bundle.main.bundleIdentifier else {
                return
            }
            Task { @MainActor [weak self] in
                self?.presentPrimaryWindowIfNeeded(reason: "workspace didActivateApplication")
            }
        }

        workspaceObserverTokens = [sessionToken, wakeToken, activateToken]
        print("[WindowLens] Workspace recovery observers installed")
    }

    private func setupWindowSlotObservers() {
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter

        let terminateToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor in
                WindowNumberRegistry.shared.markAssignmentsForTerminatedPID(app.processIdentifier)
            }
        }

        let launchToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Task { @MainActor in
                    WindowNumberRegistry.shared.attemptResurrect(for: app)
                }
            }
        }

        windowSlotObserverTokens = [terminateToken, launchToken]
        print("[WindowLens] Window slot observers installed")
    }

    /// True when Settings / Heatmap / Unused Windows / onboarding is actually on-screen.
    /// Ignores MenuBarExtra and switcher panels — those are not primary app windows.
    private var hasVisiblePrimaryWindow: Bool {
        let identifiers: Set<NSUserInterfaceItemIdentifier> = [
            SettingsWindowConfigurator.windowIdentifier,
            HeatmapWindowConfigurator.windowIdentifier,
            DeadWindowsWindowConfigurator.windowIdentifier
        ]

        if let settingsWindow, settingsWindow.isVisible, !settingsWindow.isMiniaturized { return true }
        if let heatmapWindow, heatmapWindow.isVisible, !heatmapWindow.isMiniaturized { return true }
        if let deadWindowsWindow, deadWindowsWindow.isVisible, !deadWindowsWindow.isMiniaturized { return true }
        if let onboardingWindow, onboardingWindow.isVisible { return true }
        if let permissionReadyWindow, permissionReadyWindow.isVisible { return true }

        return NSApp.windows.contains { window in
            guard window.isVisible, !window.isMiniaturized else { return false }
            guard let id = window.identifier else { return false }
            return identifiers.contains(id)
        }
    }

    /// Restore Settings when the app is brought forward with no primary UI.
    private func presentPrimaryWindowIfNeeded(reason: String) {
        guard hasCompletedPermissionGate else { return }
        if onboardingWindow?.isVisible == true || permissionReadyWindow?.isVisible == true { return }
        guard !AppState.shared.isVisible else { return }

        if hasVisiblePrimaryWindow {
            if let settingsWindow, settingsWindow.isVisible {
                settingsWindow.makeKeyAndOrderFront(nil)
            }
            return
        }

        if suppressSettingsOnNextActivation {
            suppressSettingsOnNextActivation = false
            return
        }

        if let last = lastPrimaryWindowPresentAt, Date().timeIntervalSince(last) < 0.35 {
            return
        }
        lastPrimaryWindowPresentAt = Date()

        print("[WindowLens] Presenting Settings (\(reason)) active=\(NSApp.isActive) hidden=\(NSApp.isHidden)")
        showSettingsWindow()
    }

    /// After the last primary window closes, yield frontmost so Cmd-Tab/Dock can
    /// re-activate us. Without this, MenuBarExtra leaves a zombie frontmost+inactive state.
    private func yieldFrontmostIfNoPrimaryWindow() {
        guard !hasVisiblePrimaryWindow else { return }
        guard onboardingWindow?.isVisible != true else { return }
        guard permissionReadyWindow?.isVisible != true else { return }

        // Closing the last key window often leaves us frontmost but inactive — Cmd-Tab
        // then no-ops. Drop frontmost ownership so the next Dock click / Cmd-Tab is real.
        print("[WindowLens] No primary window — yielding frontmost so next activation restores Settings")
        NSApp.hide(nil)
        NSApp.deactivate()

        // MenuBarExtra can ignore hide; bounce policy to release frontmost.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
            }
        }
    }

    private func showSettingsWindow() {
        // Reuse only if currently visible; closed windows often fail to come back
        // reliably with makeKeyAndOrderFront alone.
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            suppressSettingsOnNextActivation = true
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if let stale = settingsWindow {
            stale.delegate = nil
            stale.orderOut(nil)
            settingsWindow = nil
        }
        for window in NSApp.windows where window.identifier == SettingsWindowConfigurator.windowIdentifier {
            window.delegate = nil
            window.orderOut(nil)
        }

        let rootView = SettingsRootView()
            .environmentObject(AppState.shared)

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        SettingsWindowConfigurator.configure(window)
        window.setContentSize(NSSize(width: 720, height: 520))
        window.center()
        window.delegate = self

        settingsWindow = window
        suppressSettingsOnNextActivation = true
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        DispatchQueue.main.async {
            SettingsWindowConfigurator.applyPostLayoutChrome(to: window)
        }
        NSApp.activate(ignoringOtherApps: true)

        print("[WindowLens] Settings window shown")
    }

    private func showHeatmapWindow() {
        guard UserPreferences.load().modules.usageHeatmapEnabled else { return }

        if heatmapWindow == nil {
            heatmapWindow = NSApp.windows.first { $0.identifier == HeatmapWindowConfigurator.windowIdentifier }
        }

        if let window = heatmapWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: HeatmapView()
                .environmentObject(AppState.shared)
        )
        let window = NSWindow(contentViewController: hostingController)
        HeatmapWindowConfigurator.configure(window)
        window.setContentSize(NSSize(width: 900, height: 560))
        window.center()
        window.delegate = self

        heatmapWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("[WindowLens] Heatmap window shown")
    }

    private func showDeadWindowsWindow() {
        if deadWindowsWindow == nil {
            deadWindowsWindow = NSApp.windows.first { $0.identifier == DeadWindowsWindowConfigurator.windowIdentifier }
        }

        if let window = deadWindowsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: DeadWindowsView())
        let window = NSWindow(contentViewController: hostingController)
        DeadWindowsWindowConfigurator.configure(window)
        window.setContentSize(NSSize(width: 800, height: 560))
        window.center()
        window.delegate = self

        deadWindowsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("[WindowLens] Unused Windows window shown")
    }

    private func findExistingSettingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier == SettingsWindowConfigurator.windowIdentifier }
    }

    private func closeDuplicateSettingsWindows(keeping preferred: NSWindow?) {
        for window in NSApp.windows where window.identifier == SettingsWindowConfigurator.windowIdentifier {
            guard window !== preferred else { continue }
            window.close()
        }
    }

    private func handleShortcutEvent(_ event: ShortcutEvent) {
        print("[WindowLens] Shortcut event: \(event)")

        switch event {
        case .activationStarted:
            WindowCache.shared.prefetchAsync()
        case .showSwitcher:
            startWorkspaceWindowSession(showImmediately: true)
            eventTap?.setSwitcherVisible(true)
        case .cycleNext:
            if AppState.shared.presentationMode == .workspace,
               AppState.shared.workspaceMode == .currentAppWindows {
                panelManager.selectNextWindow()
            } else {
                panelManager.selectNext()
            }
        case .cyclePrevious:
            if AppState.shared.presentationMode == .workspace,
               AppState.shared.workspaceMode == .currentAppWindows {
                panelManager.selectPreviousWindow()
            } else {
                panelManager.selectPrevious()
            }
        case .cycleWindowNext:
            panelManager.selectNextWindow()
        case .cycleWindowPrevious:
            panelManager.selectPreviousWindow()
        case .activateSearch:
            pinWorkspaceSearch()
        case .pinWorkspaceSearch:
            pinWorkspaceSearch()
        case .workspaceSearchScopeCurrentApp:
            AppState.shared.setWorkspaceSearchScope(.currentApp)
        case .workspaceSearchScopeAllWindows:
            AppState.shared.setWorkspaceSearchScope(.allWindows)
        case .confirm:
            panelManager.confirmSelection()
            eventTap?.setSwitcherVisible(false)
        case .dismiss:
            panelManager.hide()
            eventTap?.setSwitcherVisible(false)
        case .navigateUp:
            // Navigate up in search results (same as selectPrevious)
            panelManager.selectPrevious()
        case .navigateDown:
            // Navigate down in search results (same as selectNext)
            panelManager.selectNext()
        case .navigateRowUp:
            AppState.shared.selectPreviousWindow()
        case .navigateRowDown:
            AppState.shared.selectNextWindow()
        case .quickSwitch:
            // Quick Option+Tab switches within the frontmost app, never across apps.
            eventTap?.setSwitcherVisible(false)
            performCurrentAppWindowQuickSwitch()
        case .quitHoldStarted:
            AppState.shared.startQuitHold()
        case .quitHoldCancelled:
            AppState.shared.cancelQuitHold()
        case .toggleResourceMonitor:
            guard UserPreferences.load().modules.resourceMonitorEnabled else { return }
            AppState.shared.cancelEHold(triggeredAI: false)
            AppState.shared.toggleResourceMonitor()
        case .toggleUnusedWindows:
            AppState.shared.toggleUnusedWindows()
        case .toggleHeatmap:
            guard UserPreferences.load().modules.usageHeatmapEnabled else { return }
            panelManager.hide()
            eventTap?.setSwitcherVisible(false)
            showHeatmapWindow()
        case .eHoldStarted:
            guard UserPreferences.load().modules.resourceMonitorEnabled else { return }
            AppState.shared.startEHold()
        case .aiInsightRequested:
            guard UserPreferences.load().modules.resourceMonitorEnabled else { return }
            AppState.shared.cancelEHold(triggeredAI: true)
            AppState.shared.requestAIInsightWithOllama()
        case .aiInsightCancelled:
            guard UserPreferences.load().modules.resourceMonitorEnabled else { return }
            AppState.shared.cancelEHold(triggeredAI: false)
        case .toggleProcessGrouping:
            guard UserPreferences.load().modules.resourceMonitorEnabled else { return }
            AppState.shared.isProcessGroupingEnabled.toggle()
        case .nativeSwitchStarted(let reverse):
            startNativeCommandTabSession(reverse: reverse)
        case .nativeSwitchCycleNext:
            // Resync if Dock destroy / race ended AppDelegate session while tap still active.
            if !isNativeCommandTabSessionActive {
                startNativeCommandTabSession(reverse: false)
            } else {
                scheduleProvisionalNativeFallback()
            }
        case .nativeSwitchCyclePrevious:
            if !isNativeCommandTabSessionActive {
                startNativeCommandTabSession(reverse: true)
            } else {
                scheduleProvisionalNativeFallback()
            }
        case .nativeSwitchWindowNext:
            selectNativeWindow(reverse: false)
        case .nativeSwitchWindowPrevious:
            selectNativeWindow(reverse: true)
        case .nativeSwitchEnded:
            endNativeCommandTabSession(applySelectedWindow: true)
        case .nativeSwitchCancelled:
            endNativeCommandTabSession(applySelectedWindow: false)
        case .windowHistoryUndo:
            performWindowHistoryUndo()
        case .windowHistoryRedo:
            performWindowHistoryRedo()
        case .activateWindowSlot(let slot):
            if AppState.shared.isVisible {
                panelManager.hide()
                eventTap?.setSwitcherVisible(false)
            }
            let outcome = WindowNumberRegistry.shared.activate(slot: slot)
            WindowSlotHUD.shared.present(outcome: outcome)
        case .openUsageHeatmap:
            guard UserPreferences.load().modules.usageHeatmapEnabled else { return }
            showHeatmapWindow()
        case .toggleStayAwake:
            guard UserPreferences.load().modules.stayAwakeEnabled else { return }
            KeepAwakeManager.shared.toggleWithDefaultDuration()
        }
    }

    private func performWindowHistoryUndo() {
        guard UserPreferences.load().modules.windowHistoryEnabled else { return }
        guard !AppState.shared.isVisible else { return }
        let outcome = WindowVisitHistory.shared.undo()
        WindowHistoryHUD.shared.present(outcome: outcome)
    }

    private func performWindowHistoryRedo() {
        guard UserPreferences.load().modules.windowHistoryEnabled else { return }
        guard !AppState.shared.isVisible else { return }
        let outcome = WindowVisitHistory.shared.redo()
        WindowHistoryHUD.shared.present(outcome: outcome)
    }

    private func startWorkspaceWindowSession(showImmediately: Bool) {
        var snapshot = hydratingWorkspaceSnapshot(
            WindowCache.shared.getApplicationsForWorkspaceSwitching(forceRefresh: false)
        )
        let frontmost = frontmostApplicationForWorkspace()
        if let frontmost,
           !snapshot.contains(where: { $0.pid == frontmost.processIdentifier || $0.bundleIdentifier == frontmost.bundleIdentifier }) {
            snapshot.insert(workspacePlaceholderApplication(for: frontmost), at: 0)
        }
        let frontmostApp = frontmost.flatMap { runningApp in
            snapshot.first {
                $0.pid == runningApp.processIdentifier
                    || $0.bundleIdentifier == runningApp.bundleIdentifier
            }
        }
        let initialWindowIndex = frontmostApp.flatMap { nextWindowIndexForWorkspaceSession(in: $0) }

        AppState.shared.beginWorkspaceWindowSession(
            snapshot: snapshot,
            frontmostPID: frontmost?.processIdentifier,
            visible: showImmediately,
            initialWindowIndex: initialWindowIndex
        )

        WindowCache.shared.prefetchAsync {
            guard AppState.shared.isVisible,
                  AppState.shared.presentationMode == .workspace else {
                return
            }
            AppState.shared.refreshWorkspaceWindowsForSelectedApp(forceRefresh: true)
        }

        guard showImmediately else { return }
        panelManager.showCurrentAppWindowSwitcher()
    }

    private func hydratingWorkspaceSnapshot(_ snapshot: [ApplicationModel]) -> [ApplicationModel] {
        snapshot.map { app in
            var hydratedApp = app
            hydratedApp.windows = WindowModel.mergedPreservingPreviews(
                fresh: hydratedApp.windows,
                existing: hydratedApp.windows
            )
            return hydratedApp
        }
    }

    private func pinWorkspaceSearch() {
        AppState.shared.pinWorkspaceSearch()
        panelManager.activateSearch()
        eventTap?.setSearchModeActive(true)
    }

    private func frontmostApplicationForWorkspace() -> NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.activationPolicy == .regular {
            return frontmost
        }

        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.isActive
        }
    }

    private func performCurrentAppWindowQuickSwitch() {
        let snapshot = WindowCache.shared.getApplicationsForWorkspaceSwitching()
        guard let frontmost = frontmostApplicationForWorkspace(),
              let app = snapshot.first(where: {
                  $0.pid == frontmost.processIdentifier
                      || $0.bundleIdentifier == frontmost.bundleIdentifier
              }) else {
            WindowCache.shared.prefetchAsync()
            return
        }

        let realWindowIndices = realWindowIndices(in: app)
        guard realWindowIndices.count > 1,
              let targetIndex = nextWindowIndexForWorkspaceSession(in: app) else {
            WindowCache.shared.prefetchAsync()
            return
        }

        recordWorkspaceWindowActivation(pid: app.pid, windowIndex: targetIndex)
        WindowSwitcher.shared.switchTo(
            window: app.windows[targetIndex],
            in: app,
            windowIndex: targetIndex
        )
    }

    private func recordWorkspaceWindowActivation(pid: pid_t, windowIndex: Int) {
        lastWorkspaceWindowIndexByPID[pid] = windowIndex
    }

    private func nextWindowIndexForWorkspaceSession(in app: ApplicationModel) -> Int? {
        let realIndices = realWindowIndices(in: app)
        guard !realIndices.isEmpty else { return nil }
        guard realIndices.count > 1 else { return realIndices[0] }

        let currentIndex = focusedWindowIndex(in: app)
            ?? validLastWorkspaceWindowIndex(for: app, realIndices: realIndices)
            ?? realIndices[0]

        guard let position = realIndices.firstIndex(of: currentIndex) else {
            return realIndices[0]
        }

        return realIndices[(position + 1) % realIndices.count]
    }

    private func realWindowIndices(in app: ApplicationModel) -> [Int] {
        app.windows.indices.filter { !app.windows[$0].isWindowlessPlaceholder }
    }

    private func validLastWorkspaceWindowIndex(for app: ApplicationModel, realIndices: [Int]) -> Int? {
        guard let lastIndex = lastWorkspaceWindowIndexByPID[app.pid],
              realIndices.contains(lastIndex) else {
            return nil
        }
        return lastIndex
    }

    private func focusedWindowIndex(in app: ApplicationModel) -> Int? {
        guard let focusedWindow = AXWindowHelper.focusedWindowSnapshot(for: app.pid) else {
            return nil
        }

        if focusedWindow.hasReliableWindowID,
           let index = app.windows.firstIndex(where: {
               !$0.isWindowlessPlaceholder
                   && $0.previewIdentity.hasReliableCGWindowID
                   && $0.windowID == focusedWindow.windowID
           }) {
            return index
        }

        let focusedIdentity = PreviewIdentity(
            ownerPID: app.pid,
            bundleIdentifier: app.bundleIdentifier,
            cgWindowID: focusedWindow.windowID,
            title: focusedWindow.title,
            bounds: focusedWindow.bounds,
            hasReliableCGWindowID: focusedWindow.hasReliableWindowID
        )

        if let index = app.windows.firstIndex(where: {
            !$0.isWindowlessPlaceholder && $0.previewIdentity.matches(focusedIdentity)
        }) {
            return index
        }

        return fuzzyFocusedWindowIndex(focusedWindow, in: app)
    }

    private func fuzzyFocusedWindowIndex(
        _ focusedWindow: AXWindowHelper.FocusedWindowSnapshot,
        in app: ApplicationModel
    ) -> Int? {
        let focusedTitle = PreviewIdentity.normalizedTitle(focusedWindow.title)
        let hasFocusedTitle = !focusedTitle.isEmpty

        let candidates = app.windows.indices
            .filter { !app.windows[$0].isWindowlessPlaceholder }
            .map { index -> (index: Int, score: CGFloat) in
                let window = app.windows[index]
                let windowTitle = PreviewIdentity.normalizedTitle(window.title)
                var score: CGFloat = 0

                if hasFocusedTitle && !windowTitle.isEmpty {
                    if windowTitle == focusedTitle {
                        score += 0
                    } else if windowTitle.contains(focusedTitle) || focusedTitle.contains(windowTitle) {
                        score += 8
                    } else {
                        score += 42
                    }
                } else {
                    score += 12
                }

                if focusedWindow.bounds.width > 1, focusedWindow.bounds.height > 1,
                   window.bounds.width > 1, window.bounds.height > 1 {
                    score += min(abs(window.bounds.width - focusedWindow.bounds.width) / 12, 32)
                    score += min(abs(window.bounds.height - focusedWindow.bounds.height) / 12, 32)
                    score += min(abs(window.bounds.minX - focusedWindow.bounds.minX) / 80, 16)
                    score += min(abs(window.bounds.minY - focusedWindow.bounds.minY) / 80, 16)
                }

                return (index, score)
            }
            .sorted { lhs, rhs in lhs.score < rhs.score }

        guard let best = candidates.first, best.score <= 48 else { return nil }
        return best.index
    }

    private func workspacePlaceholderApplication(for runningApplication: NSRunningApplication) -> ApplicationModel {
        let pid = runningApplication.processIdentifier
        let bundleIdentifier = runningApplication.bundleIdentifier ?? "windowlens.workspace.placeholder.\(pid)"
        let appName = runningApplication.localizedName ?? "Current App"
        let icon = runningApplication.icon
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage()
        let windowTitle = "No Windows"
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
            isActive: runningApplication.isActive
        )
    }

    private func startNativeCommandTabSession(reverse: Bool) {
        _ = reverse
        isNativeCommandTabSessionActive = true
        nativeWindowSelectionWasAdjusted = false
        lastNativePreviewRefreshPID = nil
        lastDockSelectionKey = nil
        nativeFallbackWorkItem?.cancel()
        nativeFallbackWorkItem = nil
        cancelNativeSwitcherGoneTimeout()

        dockProcessSwitcherObserver.start()

        let applications = WindowCache.shared.getApplicationsForNativePreview(forceRefresh: false)
        panelManager.showNativePreview(applications: applications, showImmediately: true)
        prewarmPreviews(for: applications)
        WindowCache.shared.prefetchAsync()

        scheduleProvisionalNativeFallback(delay: 0.14)
    }

    private func handleDockProcessSwitcherSelection(_ selection: DockProcessSwitcherSelection) {
        guard isNativeCommandTabSessionActive else { return }

        let selectionKey = "\(selection.pid.map(String.init) ?? "nil")|\(selection.bundleIdentifier ?? "")"
        if selectionKey == lastDockSelectionKey {
            return
        }
        lastDockSelectionKey = selectionKey

        nativeFallbackWorkItem?.cancel()
        nativeFallbackWorkItem = nil
        cancelNativeSwitcherGoneTimeout()

        guard panelManager.selectNativeDockSelection(selection) else {
            return
        }

        if let selectedApp = AppState.shared.selectedApp {
            requestSelectedNativeAppPreviews(selectedApp)
        }
    }

    private func scheduleProvisionalNativeFallback(delay: TimeInterval = 0.14) {
        guard isNativeCommandTabSessionActive else { return }

        nativeFallbackWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.isNativeCommandTabSessionActive,
                      !self.dockProcessSwitcherObserver.hasDeliveredSelection else {
                    return
                }

                // Show the preview panel without advancing selection — Dock AX owns highlight.
                if let selectedApp = AppState.shared.selectedApp {
                    self.requestSelectedNativeAppPreviews(selectedApp)
                }
                self.panelManager.showNativeFallbackPreviewPanel()
            }
        }
        nativeFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func selectNativeWindow(reverse: Bool) {
        guard isNativeCommandTabSessionActive else { return }

        let previousIndex = AppState.shared.selectedWindowIndex
        if reverse {
            panelManager.selectPreviousWindow()
        } else {
            panelManager.selectNextWindow()
        }
        nativeWindowSelectionWasAdjusted = nativeWindowSelectionWasAdjusted
            || AppState.shared.selectedWindowIndex != previousIndex

        if let selectedApp = AppState.shared.selectedApp {
            requestSelectedNativeAppPreviews(selectedApp)
        }
    }

    private func requestSelectedNativeAppPreviews(_ app: ApplicationModel) {
        if lastNativePreviewRefreshPID != app.pid {
            lastNativePreviewRefreshPID = app.pid
            AppState.shared.refreshNativeWindowsForSelectedApp()
        }
        AppState.shared.hydrateCachedPreviews(for: app.pid)

        guard let hydratedApp = AppState.shared.applications.first(where: { $0.pid == app.pid }),
              !hydratedApp.windows.isEmpty else {
            return
        }

        let selectedIndex = AppState.shared.selectedWindowIndex
        let neighborIndices = [selectedIndex - 1, selectedIndex, selectedIndex + 1]
            .filter { hydratedApp.windows.indices.contains($0) }
        let windowsNearSelection = neighborIndices.map { hydratedApp.windows[$0] }
            .filter { !$0.isWindowlessPlaceholder }

        guard !windowsNearSelection.isEmpty else { return }

        WindowPreviewService.shared.requestPreviews(
            for: windowsNearSelection,
            ownerPID: hydratedApp.pid,
            appName: hydratedApp.name,
            selectionGeneration: AppState.shared.currentNativePreviewGeneration
        )
    }

    private func prewarmPreviews(for applications: [ApplicationModel]) {
        // Hydrate from memory/disk after first paint opportunity; defer SCK capture to selection.
        DispatchQueue.main.async {
            guard AppState.shared.presentationMode == .nativePreview else { return }
            for app in applications.prefix(8) {
                AppState.shared.hydrateCachedPreviews(for: app.pid)
            }
        }
    }

    private func reconcileNativeCommandTabRelease() {
        panelManager.finishNativeTraversalAndReconcileFrontmost()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            MainActor.assumeIsolated {
                self?.panelManager.reconcileFrontmostApplication()
            }
        }
    }

    private func scheduleNativeSwitcherGoneCancelIfNeeded() {
        cancelNativeSwitcherGoneTimeout()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isNativeCommandTabSessionActive else { return }
                // Switcher never reappeared — Escape (or Dock cancel) while Cmd held.
                self.eventTap?.cancelNativeCommandTabSessionFromApp()
                self.endNativeCommandTabSession(applySelectedWindow: false)
            }
        }
        nativeSwitcherGoneWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + nativeSwitcherGoneTimeoutSeconds,
            execute: workItem
        )
    }

    private func cancelNativeSwitcherGoneTimeout() {
        nativeSwitcherGoneWorkItem?.cancel()
        nativeSwitcherGoneWorkItem = nil
    }

    private func endNativeCommandTabSession(applySelectedWindow: Bool) {
        guard isNativeCommandTabSessionActive else { return }

        let currentSelectedWindow = AppState.shared.selectedNativeWindowSelection()
        let shouldApplySelectedWindow = applySelectedWindow
            && (nativeWindowSelectionWasAdjusted || currentSelectedWindow?.window.isMinimized == true)
        let selectedWindow = shouldApplySelectedWindow ? currentSelectedWindow : nil

        isNativeCommandTabSessionActive = false
        nativeFallbackWorkItem?.cancel()
        nativeFallbackWorkItem = nil
        cancelNativeSwitcherGoneTimeout()
        nativeWindowSelectionWasAdjusted = false
        lastDockSelectionKey = nil
        dockProcessSwitcherObserver.stop()
        if applySelectedWindow {
            reconcileNativeCommandTabRelease()
        }
        panelManager.hide()
        eventTap?.setSwitcherVisible(false)

        if let selectedWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                WindowSwitcher.shared.switchTo(
                    window: selectedWindow.window,
                    in: selectedWindow.app,
                    windowIndex: selectedWindow.index
                )
            }
        }
    }

    private func performQuickSwitch() {
        // Use cached data (lock-free read) - don't wait for any prefetch
        let apps = WindowCache.shared.getCachedApplications()

        guard apps.count > 1 else {
            print("[WindowLens] Quick switch: Not enough apps (have \(apps.count))")
            return
        }

        // Get the ACTUAL current frontmost app to ensure we switch to something different
        // This is critical because the cache MRU order might be slightly stale
        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // Find the first app in the MRU list that is NOT the current frontmost app
        var targetApp: ApplicationModel?
        for app in apps {
            if app.pid != frontmostPid {
                targetApp = app
                break
            }
        }

        guard let previousApp = targetApp else {
            print("[WindowLens] Quick switch: No different app to switch to")
            return
        }

        print("[WindowLens] Quick switch to: \(previousApp.name)")

        // Activate synchronously for speed
        WindowSwitcher.shared.activate(app: previousApp)
    }
}
