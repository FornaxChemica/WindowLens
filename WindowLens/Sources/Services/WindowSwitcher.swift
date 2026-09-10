import AppKit
import ApplicationServices

private final class BoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    func set(_ newValue: Bool) {
        lock.lock()
        storedValue = newValue
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

/// Fast window switcher - no actor overhead
final class WindowSwitcher: @unchecked Sendable {
    static let shared = WindowSwitcher()

    private init() {}

    /// Activate an app (bring to front)
    func activate(app: ApplicationModel) {
        guard let runningApp = NSRunningApplication(processIdentifier: app.pid) else {
            WLLog.switcher.error("Could not find running app for PID: \(app.pid)")
            return
        }

        // Check current frontmost app - if it's a "sticky" app like Warp, we may need to hide it first
        let currentFrontmost = NSWorkspace.shared.frontmostApplication
        let currentFrontmostName = currentFrontmost?.localizedName ?? "unknown"

        // Use Accessibility API to raise the window first
        let axApp = AXUIElementCreateApplication(app.pid)
        var windowsRef: CFTypeRef?
        var firstWindow: AXUIElement?
        let axResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        let axWindows = (axResult == .success) ? (windowsRef as? [AXUIElement]) ?? [] : []

        // If app has no windows, open a new one instead of just activating
        if axWindows.isEmpty, let bundleURL = runningApp.bundleURL {
            WLLog.switcher.debug("App \(app.name) has no windows, opening new window")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.createsNewApplicationInstance = false

            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, error in
                if let error = error {
                    WLLog.switcher.error("Failed to open new window for \(app.name): \(error)")
                } else {
                    WLLog.switcher.debug("Successfully opened new window for \(app.name)")
                }
            }
            WindowCache.shared.moveAppToFront(pid: app.pid, fromOurSwitch: true)
            return
        }

        if let window = axWindows.first {
            firstWindow = window
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }

        // Try activation
        var success = runningApp.activate()

        // If standard activate fails, try hiding the current app first then activating
        if !success {
            WLLog.switcher.error("Standard activate failed (from \(currentFrontmostName)), hiding frontmost and retrying")
            currentFrontmost?.hide()
            usleep(10000)  // 10ms for hide to take effect
            success = runningApp.activate()
        }

        // If still failing, try NSWorkspace.open()
        if !success, let bundleURL = runningApp.bundleURL {
            WLLog.switcher.error("Hide+activate failed, trying NSWorkspace.open()")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.createsNewApplicationInstance = false

            let semaphore = DispatchSemaphore(value: 0)
            let openSuccess = BoolBox()

            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { app, error in
                openSuccess.set(error == nil && app != nil)
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + 0.1)
            success = openSuccess.get()
        }

        // Last resort: AX focus
        if !success {
            WLLog.switcher.error("All methods failed, using AX focus as last resort")
            let systemWide = AXUIElementCreateSystemWide()
            AXUIElementSetAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, axApp)
            if let window = firstWindow {
                AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window)
            }
            success = true  // Assume it worked
        }

        WLLog.switcher.debug("Activated \(app.name): \(success)")

        // Update cache order
        WindowCache.shared.moveAppToFront(pid: app.pid, fromOurSwitch: true)

        if success, let window = app.windows.first(where: { !$0.isWindowlessPlaceholder }) {
            let index = app.windows.firstIndex(where: { $0.id == window.id })
            recordWindowVisit(app: app, window: window, windowIndex: index)
        }
    }

    /// Switch to a specific window within an app
    /// windowIndex is the index in the app.windows array for fallback matching
    func switchTo(window: WindowModel, in app: ApplicationModel, windowIndex: Int? = nil) {
        guard let runningApp = NSRunningApplication(processIdentifier: app.pid) else {
            WLLog.switcher.error("Could not find running app for PID: \(app.pid)")
            return
        }

        let axWindows = AXWindowHelper.getOrderedAXWindows(for: app.pid)

        // If app has no windows, open a new one instead of trying to switch
        if axWindows.isEmpty, let bundleURL = runningApp.bundleURL {
            WLLog.switcher.debug("App \(app.name) has no windows, opening new window")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.createsNewApplicationInstance = false

            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, error in
                if let error = error {
                    WLLog.switcher.error("Failed to open new window for \(app.name): \(error)")
                } else {
                    WLLog.switcher.debug("Successfully opened new window for \(app.name)")
                }
            }
            WindowCache.shared.moveAppToFront(pid: app.pid, fromOurSwitch: true)
            return
        }

        // Strategy 1: Match by CGWindowID when available (stable across AX ordering differences)
        if window.previewIdentity.hasReliableCGWindowID,
           window.windowID != 0,
           let axWindow = AXWindowHelper.getAXWindow(for: window.windowID, pid: app.pid) {
            WLLog.switcher.debug("Found window by ID \(window.windowID)")
            raiseAndActivate(axWindow: axWindow, window: window, runningApp: runningApp, app: app, windowIndex: windowIndex)
            return
        }

        // Strategy 2: Try to find by window index (fallback when CGWindowID is unavailable)
        if let index = windowIndex, index < axWindows.count {
            let axWindow = axWindows[index]
            WLLog.switcher.debug("Using window index \(index)")
            raiseAndActivate(axWindow: axWindow, window: window, runningApp: runningApp, app: app, windowIndex: index)
            return
        }

        WLLog.switcher.error("Could not find window by ID \(window.windowID), trying title match")

        // Strategy 3: Fall back to title matching
        for axWindow in axWindows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)

            if let title = titleRef as? String, title == window.title {
                raiseAndActivate(axWindow: axWindow, window: window, runningApp: runningApp, app: app, windowIndex: windowIndex)
                return
            }
        }

        // Strategy 4: Try partial title match (for truncated titles)
        for axWindow in axWindows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)

            if let title = titleRef as? String, !title.isEmpty, !window.title.isEmpty,
               (title.hasPrefix(window.title) || window.title.hasPrefix(title) ||
                title.contains(window.title) || window.title.contains(title)) {
                WLLog.switcher.debug("Found window by partial title match: '\(title)'")
                raiseAndActivate(axWindow: axWindow, window: window, runningApp: runningApp, app: app, windowIndex: windowIndex)
                return
            }
        }

        WLLog.switcher.error("Window not found by ID or title, activating first window")

        // Strategy 5: Just activate the first window
        if let firstWindow = axWindows.first {
            AXUIElementPerformAction(firstWindow, kAXRaiseAction as CFString)
        }

        let activated = activateWithFallbacks(runningApp: runningApp, focusAXWindow: axWindows.first)
        WLLog.switcher.debug("Activated \(app.name): \(activated)")

        if activated {
            WindowCache.shared.moveAppToFront(pid: app.pid, fromOurSwitch: true)
            recordWindowVisit(app: app, window: window, windowIndex: windowIndex)
        }
    }

    /// Activate a running app, falling back through hide/retry, NSWorkspace.open, and AX focus.
    private func activateWithFallbacks(
        runningApp: NSRunningApplication,
        focusAXWindow axWindow: AXUIElement?
    ) -> Bool {
        let axApp = AXUIElementCreateApplication(runningApp.processIdentifier)
        let currentFrontmost = NSWorkspace.shared.frontmostApplication
        let currentFrontmostName = currentFrontmost?.localizedName ?? "unknown"

        var success = runningApp.activate()

        if !success {
            WLLog.switcher.error("Standard activate failed (from \(currentFrontmostName)), hiding frontmost and retrying")
            currentFrontmost?.hide()
            usleep(10000)
            success = runningApp.activate()
        }

        if !success, let bundleURL = runningApp.bundleURL {
            WLLog.switcher.error("Hide+activate failed, trying NSWorkspace.open()")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.createsNewApplicationInstance = false

            let semaphore = DispatchSemaphore(value: 0)
            let openSuccess = BoolBox()

            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { app, error in
                openSuccess.set(error == nil && app != nil)
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + 0.1)
            success = openSuccess.get()
        }

        if !success {
            WLLog.switcher.error("All methods failed, using AX focus as last resort")
            let systemWide = AXUIElementCreateSystemWide()
            AXUIElementSetAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, axApp)
            if let axWindow {
                AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, axWindow)
            }
            success = true
        }

        return success
    }

    /// Helper to raise a window and activate the app
    private func raiseAndActivate(
        axWindow: AXUIElement,
        window: WindowModel,
        runningApp: NSRunningApplication,
        app: ApplicationModel,
        windowIndex: Int?
    ) {
        // Unminimize if needed
        if window.isMinimized {
            var minimizedRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef)
            if let isMinimized = minimizedRef as? Bool, isMinimized {
                AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            }
        }

        // Raise the window
        let raiseResult = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        WLLog.switcher.debug("Raised window '\(window.title)': \(raiseResult == .success)")

        // Activate the app (with fallbacks for sticky frontmost apps)
        let activated = activateWithFallbacks(runningApp: runningApp, focusAXWindow: axWindow)
        WLLog.switcher.debug("Activated \(app.name): \(activated)")

        // Update cache order
        if activated {
            WindowCache.shared.moveAppToFront(pid: app.pid, fromOurSwitch: true)
            recordWindowVisit(app: app, window: window, windowIndex: windowIndex)
        }
    }

    private func recordWindowVisit(app: ApplicationModel, window: WindowModel, windowIndex: Int?) {
        Task { @MainActor in
            WindowVisitHistory.shared.recordVisit(app: app, window: window, windowIndex: windowIndex)
        }
    }

    func switchToWindow(byID windowID: CGWindowID, pid: pid_t) {
        guard let runningApp = NSRunningApplication(processIdentifier: pid) else {
            WLLog.switcher.error("Could not find running app for PID: \(pid)")
            return
        }

        let axApp = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let firstWindow = windows.first else {
            runningApp.activate()
            return
        }

        // Raise the first window (ideally we'd match by CGWindowID but that requires private API)
        AXUIElementPerformAction(firstWindow, kAXRaiseAction as CFString)
        runningApp.activate()
    }
}
