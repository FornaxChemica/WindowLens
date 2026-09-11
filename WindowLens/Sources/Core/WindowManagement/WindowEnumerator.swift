import CoreGraphics
import AppKit
import ApplicationServices

final class WindowEnumerator {
    private var hasLoggedMissingAccessibility = false

    struct EnumerationOptions {
        var includeMinimized: Bool = true
        var includeAllSpaces: Bool = true
        var hydratePreviewImages: Bool = false
        var minimumWidth: CGFloat = 50
        var minimumHeight: CGFloat = 50
        var excludedBundleIDs: Set<String> = []

        static let `default` = EnumerationOptions()
    }

    // Bundle IDs to skip
    private let skipBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.SystemUIServer"
    ]

    /// Enumerate windows using Accessibility API as the primary source
    /// This is more reliable for window switching since we use AX to raise windows
    func enumerateGroupedByApp(options: EnumerationOptions = .default) -> [ApplicationModel] {
        guard AXIsProcessTrusted() else {
            if !hasLoggedMissingAccessibility {
                WLLog.cache.error("Skipping window enumeration: Accessibility is not granted")
                hasLoggedMissingAccessibility = true
            }
            return []
        }

        let excludedBundleIDs = options.excludedBundleIDs
        let currentSpaceWindowIDs = Self.currentSpaceWindowIDs()

        // Get all running apps with regular activation policy (visible in Dock)
        let runningApps = NSWorkspace.shared.runningApplications.filter { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return app.activationPolicy == .regular
                && !skipBundleIDs.contains(bundleID)
                && !excludedBundleIDs.contains(bundleID)
        }

        var applications: [ApplicationModel] = []

        for app in runningApps {
            guard let name = app.localizedName,
                  let bundleIdentifier = app.bundleIdentifier else {
                continue
            }

            let pid = app.processIdentifier
            // processIdentifier returns -1 if the app has already terminated
            guard pid >= 0 else { continue }
            let axApp = AXUIElementCreateApplication(pid)

            // Get windows from Accessibility API
            var windowsRef: CFTypeRef?
            let axResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)

            // If AX fails or returns empty, include the app with a synthetic window
            // This handles apps like Steam/games that may not fully support Accessibility
            let axWindows = (axResult == .success) ? (windowsRef as? [AXUIElement]) ?? [] : []

            if axResult != .success {
                WLLog.cache.error("AX failed for \(name) (error: \(axResult.rawValue)), using synthetic window")
            } else if axWindows.isEmpty {
                WLLog.cache.debug("AX returned empty windows for \(name), using synthetic window")
            }

            var windows: [WindowInfo] = []
            var rejectedWindows: [String] = []

            for (axIndex, axWindow) in axWindows.enumerated() {
                // Get window ID
                var windowID: CGWindowID = 0
                let idResult = _AXUIElementGetWindow(axWindow, &windowID)

                // Get title
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
                let title = titleRef as? String

                // Get position and size
                var positionRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)
                AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)

                var position = CGPoint.zero
                var size = CGSize.zero

                if let posValue = positionRef {
                    AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
                }
                if let sizeValue = sizeRef {
                    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                }

                // Check if minimized
                var minimizedRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef)
                let isMinimized = (minimizedRef as? Bool) ?? false

                var hiddenRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXHiddenAttribute as CFString, &hiddenRef)
                let isHidden = (hiddenRef as? Bool) ?? false

                var mainRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXMainAttribute as CFString, &mainRef)
                let isMain = (mainRef as? Bool) ?? false

                if isMinimized && !options.includeMinimized {
                    rejectedWindows.append("#\(axIndex) minimized hidden title=\(title ?? "untitled")")
                    continue
                }

                // Reject collapsed AX geometry. Off-Space enumeration can report 0x0 or tiny
                // transient surfaces that duplicate a real on-screen window for a few seconds.
                if !isMinimized,
                   (size.width < options.minimumWidth || size.height < options.minimumHeight) {
                    rejectedWindows.append("#\(axIndex) tiny title=\(title ?? "untitled") size=\(Int(size.width))x\(Int(size.height))")
                    continue
                }

                // Get subrole to filter out non-standard windows
                var subroleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef)
                let subrole = subroleRef as? String

                // Skip known non-window subroles (like system overlays)
                // Be permissive - allow windows with no subrole or unknown subroles
                if let subrole = subrole {
                    let invalidSubroles = ["AXSystemDialog", "AXSheet", "AXDrawer", "AXUnknown"]
                    if invalidSubroles.contains(subrole) {
                        rejectedWindows.append("#\(axIndex) subrole=\(subrole) title=\(title ?? "untitled")")
                        continue
                    }
                }

                // Use a valid window ID, or generate a unique one based on index
                let finalWindowID: CGWindowID
                let hasReliableWindowID: Bool
                if idResult == .success && windowID != 0 {
                    finalWindowID = windowID
                    hasReliableWindowID = true
                } else {
                    finalWindowID = PreviewIdentity.pseudoWindowID(
                        ownerPID: pid,
                        axIndex: axIndex,
                        title: title ?? name,
                        bounds: CGRect(origin: position, size: size)
                    )
                    hasReliableWindowID = false
                    WLLog.preview.debug("missing AX CGWindowID for \(name) title=\(title ?? "untitled") axResult=\(idResult.rawValue); using pseudoID=\(finalWindowID)")
                }

                // Pseudo-ID windows lack CGWindowID for space lookup; AX geometry already validated above.
                let isOnCurrentSpace = hasReliableWindowID
                    ? currentSpaceWindowIDs?.contains(finalWindowID) ?? true
                    : true
                if !options.includeAllSpaces && !isMinimized && !isOnCurrentSpace {
                    rejectedWindows.append("#\(axIndex) off-space title=\(title ?? "untitled") id=\(finalWindowID)")
                    continue
                }

                windows.append(WindowInfo(
                    windowID: finalWindowID,
                    ownerPID: pid,
                    ownerBundleIdentifier: bundleIdentifier,
                    axIndex: axIndex,
                    ownerName: name,
                    windowName: title,
                    bounds: CGRect(origin: position, size: size),
                    isOnScreen: !isMinimized && isOnCurrentSpace,
                    isMinimized: isMinimized,
                    isHidden: isHidden,
                    isMain: isMain,
                    spaceID: nil,
                    hasReliableWindowID: hasReliableWindowID
                ))
            }

            let icon = app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()

            // AX often omits fullscreen / other-Space windows (Electron/Cursor). When the
            // user opts into all Spaces, supplement from CGWindowList (no onScreenOnly).
            if options.includeAllSpaces {
                let before = windows.count
                Self.appendCGDiscoveredWindows(
                    to: &windows,
                    pid: pid,
                    bundleIdentifier: bundleIdentifier,
                    ownerName: name,
                    options: options,
                    currentSpaceWindowIDs: currentSpaceWindowIDs
                )
                let added = windows.count - before
                if added > 0 {
                    rejectedWindows.append("cg-supplement +\(added)")
                }
            }

            // If still nothing, create a windowless placeholder so the switcher shows
            // "No Windows" instead of a blank preview card.
            if windows.isEmpty {
                let windowTitle = "No Windows"
                let syntheticWindow = WindowInfo(
                    windowID: PreviewIdentity.pseudoWindowID(
                        ownerPID: pid,
                        axIndex: 0,
                        title: windowTitle,
                        bounds: .zero
                    ),
                    ownerPID: pid,
                    ownerBundleIdentifier: bundleIdentifier,
                    axIndex: 0,
                    ownerName: name,
                    windowName: windowTitle,
                    bounds: .zero,
                    isOnScreen: false,
                    isMinimized: false,
                    isHidden: false,
                    isMain: false,
                    spaceID: nil,
                    hasReliableWindowID: false
                )
                windows.append(syntheticWindow)
            }

            let visibleCGWindowIDs = bundleIdentifier == Self.finderBundleIdentifier
                ? Self.visibleCGWindowIDs(forOwnerPID: pid)
                : nil
            let cgWindowNamesByID = bundleIdentifier == Self.finderBundleIdentifier
                ? Self.cgWindowNamesByID(forOwnerPID: pid)
                : nil
            let refinedWindows: [WindowInfo] = {
                let refined = Self.refinedWindowsForApplication(
                    windows,
                    bundleIdentifier: bundleIdentifier,
                    visibleCGWindowIDsForOwner: visibleCGWindowIDs,
                    cgWindowNamesByID: cgWindowNamesByID
                )
                // Match Mission Control left→right order when listing all Spaces
                // (e.g. WindowLens → Humanizer → .env.local instead of CG z-order).
                guard options.includeAllSpaces, refined.count > 1 else { return refined }
                return SpaceMissionOrder.sortedBySpaceOrder(refined) { $0.windowID }
            }()

            guard !refinedWindows.isEmpty else {
                continue
            }

            applications.append(ApplicationModel(
                pid: pid,
                bundleIdentifier: bundleIdentifier,
                name: name,
                icon: icon,
                windows: refinedWindows.map { info in
                    let previewIdentity = PreviewIdentity(
                        ownerPID: info.ownerPID,
                        bundleIdentifier: info.ownerBundleIdentifier,
                        cgWindowID: info.windowID,
                        axIndex: info.axIndex,
                        title: info.windowName ?? info.ownerName,
                        bounds: info.bounds,
                        hasReliableCGWindowID: info.hasReliableWindowID
                    )
                    var windowModel = WindowModel(from: info, previewImage: nil)
                    if windowModel.isWindowlessPlaceholder {
                        windowModel.subtitle = "No Windows"
                    } else if options.hydratePreviewImages,
                              let cachedPreview = WindowPreviewService.shared.cachedPreview(for: previewIdentity) {
                        windowModel.previewImage = cachedPreview
                    }
                    return windowModel
                },
                isActive: app.isActive
            ))

            logInventory(
                appName: name,
                axWindowCount: axWindows.count,
                acceptedWindows: refinedWindows,
                rejectedWindows: rejectedWindows
            )
        }

        // Sort: active app first, then alphabetically by name
        return applications.sorted { app1, app2 in
            if app1.isActive && !app2.isActive { return true }
            if !app1.isActive && app2.isActive { return false }
            return app1.name.localizedCaseInsensitiveCompare(app2.name) == .orderedAscending
        }
    }

    static let finderBundleIdentifier = "com.apple.finder"

    /// Applies generic dedupe, Finder shell suppression, then phantom filtering. Exposed for unit tests.
    static func refinedWindowsForApplication(
        _ windows: [WindowInfo],
        bundleIdentifier: String,
        visibleCGWindowIDsForOwner: Set<CGWindowID>? = nil,
        cgWindowNamesByID: [CGWindowID: String]? = nil
    ) -> [WindowInfo] {
        let deduplicated = deduplicatedWindows(windows)
        let afterShellSuppression = suppressingFinderDuplicateShells(
            deduplicated,
            bundleIdentifier: bundleIdentifier
        )
        return replacingFinderPhantomsWithPlaceholder(
            afterShellSuppression,
            bundleIdentifier: bundleIdentifier,
            visibleCGWindowIDsForOwner: visibleCGWindowIDsForOwner,
            cgWindowNamesByID: cgWindowNamesByID
        )
    }

    /// Finder exposes multiple AX surfaces for one desktop/browser view. Drop generic shells only
    /// when a real folder-titled browser window is also present.
    static func suppressingFinderDuplicateShells(
        _ windows: [WindowInfo],
        bundleIdentifier: String
    ) -> [WindowInfo] {
        guard bundleIdentifier == finderBundleIdentifier, windows.count > 1 else {
            return windows
        }

        let browserWindows = windows.filter(isSpecificFinderBrowserWindow)
        guard !browserWindows.isEmpty else {
            return windows
        }

        let kept = windows.filter { window in
            shouldKeepFinderWindow(window, browserWindows: browserWindows)
        }

        return collapseFinderWindowsSharingCaptureID(kept)
    }

    /// When Finder has no genuinely visible windows, emit the same "No Windows" row used elsewhere.
    static func replacingFinderPhantomsWithPlaceholder(
        _ windows: [WindowInfo],
        bundleIdentifier: String,
        visibleCGWindowIDsForOwner: Set<CGWindowID>? = nil,
        cgWindowNamesByID: [CGWindowID: String]? = nil
    ) -> [WindowInfo] {
        guard bundleIdentifier == finderBundleIdentifier, !windows.isEmpty else {
            return windows
        }

        if !finderHasMainWindow(
            among: windows,
            cgWindowNamesByID: cgWindowNamesByID ?? [:],
            visibleCGWindowIDsForOwner: visibleCGWindowIDsForOwner
        ) {
            return [finderWindowlessPlaceholder(from: windows[0])]
        }

        let genuine = windows.filter {
            !isFinderPhantomWindow(
                $0,
                visibleCGWindowIDs: visibleCGWindowIDsForOwner,
                cgWindowNamesByID: cgWindowNamesByID
            )
        }
        if !genuine.isEmpty {
            return genuine
        }

        return [finderWindowlessPlaceholder(from: windows[0])]
    }

    /// Returns true when Finder still has an AX restore row but no user-visible browser window.
    static func shouldSuppressFinderPreview(for window: WindowModel) -> Bool {
        guard !window.isWindowlessPlaceholder else { return false }

        let ownerPID = window.previewIdentity.ownerPID ?? 0
        guard ownerPID > 0,
              let runningApp = NSRunningApplication(processIdentifier: ownerPID),
              runningApp.bundleIdentifier == finderBundleIdentifier else {
            return false
        }

        // Live AX check: closed Finder keeps restore rows with AXMain == false.
        if !finderHasMainWindow(pid: ownerPID) {
            return true
        }

        let liveAttributes = liveFinderWindowAttributes(
            pid: ownerPID,
            windowID: window.windowID,
            axIndex: window.previewIdentity.axIndex,
            title: window.title
        )

        let info = WindowInfo(
            windowID: window.windowID,
            ownerPID: ownerPID,
            ownerBundleIdentifier: finderBundleIdentifier,
            axIndex: window.previewIdentity.axIndex,
            ownerName: "Finder",
            windowName: liveAttributes?.title ?? window.title,
            bounds: window.bounds,
            isOnScreen: window.isOnScreen,
            isMinimized: liveAttributes?.isMinimized ?? window.isMinimized,
            isHidden: liveAttributes?.isHidden ?? false,
            isMain: liveAttributes?.isMain ?? false,
            spaceID: window.spaceID,
            hasReliableWindowID: window.previewIdentity.hasReliableCGWindowID
        )

        return isFinderPhantomWindow(
            info,
            visibleCGWindowIDs: visibleCGWindowIDs(forOwnerPID: ownerPID),
            cgWindowNamesByID: cgWindowNamesByID(forOwnerPID: ownerPID)
        )
    }

    /// Finder restore rows remain in AX after "Close All". Frontmost Finder can mark them
    /// main without a matching compositor title, so verify CG names for browser windows.
    static func finderHasMainWindow(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return true }

        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            return true
        }

        let cgWindowNamesByID = cgWindowNamesByID(forOwnerPID: pid)
        if countsAsMultipleOpenFinderBrowsers(in: axWindows) {
            return true
        }

        return axWindows.contains { axWindow in
            axWindowCountsAsFinderMain(axWindow, cgWindowNamesByID: cgWindowNamesByID)
        }
    }

    private static func countsAsMultipleOpenFinderBrowsers(in axWindows: [AXUIElement]) -> Bool {
        let browserWindows = axWindows.filter { axWindow in
            guard !(boolAttribute(kAXMinimizedAttribute, on: axWindow) ?? false) else {
                return false
            }

            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
            return isSpecificFinderBrowserTitle(normalizedWindowTitle((titleRef as? String) ?? ""))
        }

        return browserWindows.count >= 2
    }

    private static func finderHasMainWindow(
        among windows: [WindowInfo],
        cgWindowNamesByID: [CGWindowID: String],
        visibleCGWindowIDsForOwner: Set<CGWindowID>? = nil
    ) -> Bool {
        let browserWindows = windows.filter(isSpecificFinderBrowserWindow)
        if browserWindows.count >= 2 {
            let visibleBrowsers = browserWindows.filter { window in
                !window.isMinimized && !window.isHidden && window.isOnScreen
            }
            if visibleBrowsers.count >= 2 {
                return true
            }
        }

        return windows.contains { window in
            windowCountsAsFinderMain(window, cgWindowNamesByID: cgWindowNamesByID)
        }
    }

    private static func windowCountsAsFinderMain(
        _ window: WindowInfo,
        cgWindowNamesByID: [CGWindowID: String]
    ) -> Bool {
        guard !window.isMinimized, window.isMain else { return false }

        let normalizedTitle = normalizedWindowTitle(window.windowName ?? "")
        if isSpecificFinderBrowserTitle(normalizedTitle) {
            guard window.hasReliableWindowID, window.windowID != 0 else { return false }
            return finderAXTitleMatchesCG(
                axTitle: window.windowName ?? "",
                cgTitle: cgWindowNamesByID[window.windowID]
            )
        }

        return normalizedTitle != "finder" && !normalizedTitle.isEmpty
    }

    private static func axWindowCountsAsFinderMain(
        _ axWindow: AXUIElement,
        cgWindowNamesByID: [CGWindowID: String]
    ) -> Bool {
        guard !(boolAttribute(kAXMinimizedAttribute, on: axWindow) ?? false),
              boolAttribute(kAXMainAttribute, on: axWindow) ?? false else {
            return false
        }

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
        let axTitle = (titleRef as? String) ?? ""
        let normalizedTitle = normalizedWindowTitle(axTitle)

        if isSpecificFinderBrowserTitle(normalizedTitle) {
            var windowID: CGWindowID = 0
            guard _AXUIElementGetWindow(axWindow, &windowID) == .success, windowID != 0 else {
                return false
            }
            return finderAXTitleMatchesCG(axTitle: axTitle, cgTitle: cgWindowNamesByID[windowID])
        }

        return normalizedTitle != "finder" && !normalizedTitle.isEmpty
    }

    private struct LiveFinderWindowAttributes {
        let title: String?
        let isHidden: Bool
        let isMain: Bool
        let isMinimized: Bool
    }

    private static func liveFinderWindowAttributes(
        pid: pid_t,
        windowID: CGWindowID,
        axIndex: Int?,
        title: String
    ) -> LiveFinderWindowAttributes? {
        guard AXIsProcessTrusted() else { return nil }

        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            return nil
        }

        let normalizedTarget = normalizedWindowTitle(title)

        for (index, axWindow) in axWindows.enumerated() {
            var matched = false
            if let axIndex, index == axIndex {
                matched = true
            } else {
                var axWindowID: CGWindowID = 0
                if _AXUIElementGetWindow(axWindow, &axWindowID) == .success,
                   axWindowID != 0,
                   axWindowID == windowID {
                    matched = true
                } else if !normalizedTarget.isEmpty {
                    var titleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
                    let axTitle = normalizedWindowTitle((titleRef as? String) ?? "")
                    matched = axTitle == normalizedTarget
                }
            }

            guard matched else { continue }

            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
            return LiveFinderWindowAttributes(
                title: titleRef as? String,
                isHidden: boolAttribute(kAXHiddenAttribute, on: axWindow) ?? false,
                isMain: boolAttribute(kAXMainAttribute, on: axWindow) ?? false,
                isMinimized: boolAttribute(kAXMinimizedAttribute, on: axWindow) ?? false
            )
        }

        return nil
    }

    private static func boolAttribute(_ attribute: String, on element: AXUIElement) -> Bool? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success else {
            return nil
        }
        return valueRef as? Bool
    }

    static func normalizeFinderApplicationIfNeeded(_ app: ApplicationModel) -> ApplicationModel {
        guard app.bundleIdentifier == finderBundleIdentifier else { return app }

        let realWindows = app.windows.filter { !$0.isWindowlessPlaceholder }
        if realWindows.count >= 2 {
            return app
        }

        guard !finderHasMainWindow(pid: app.pid) else {
            return app
        }

        var normalized = app
        normalized.windows = [finderWindowlessPlaceholderModel(pid: app.pid, ownerName: app.name)]
        return normalized
    }

    static func finderWindowlessPlaceholderModel(pid: pid_t, ownerName: String) -> WindowModel {
        let template = WindowInfo(
            windowID: 0,
            ownerPID: pid,
            ownerBundleIdentifier: finderBundleIdentifier,
            axIndex: 0,
            ownerName: ownerName,
            windowName: "Desktop — Local",
            bounds: CGRect(x: 40, y: 40, width: 900, height: 700),
            isOnScreen: true,
            isMinimized: false,
            isHidden: false,
            isMain: false,
            spaceID: nil,
            hasReliableWindowID: true
        )
        var model = WindowModel(from: finderWindowlessPlaceholder(from: template))
        model.subtitle = "No Windows"
        model.previewImage = nil
        return model
    }

    static func finderWindowlessPlaceholder(from template: WindowInfo) -> WindowInfo {
        let windowTitle = "No Windows"
        let windowID = PreviewIdentity.pseudoWindowID(
            ownerPID: template.ownerPID,
            axIndex: 0,
            title: windowTitle,
            bounds: .zero
        )
        return WindowInfo(
            windowID: windowID,
            ownerPID: template.ownerPID,
            ownerBundleIdentifier: template.ownerBundleIdentifier,
            axIndex: 0,
            ownerName: template.ownerName,
            windowName: windowTitle,
            bounds: .zero,
            isOnScreen: false,
            isMinimized: false,
            isHidden: false,
            isMain: false,
            spaceID: nil,
            hasReliableWindowID: false
        )
    }

    private static func isFinderPhantomWindow(
        _ window: WindowInfo,
        visibleCGWindowIDs: Set<CGWindowID>?,
        cgWindowNamesByID: [CGWindowID: String]?
    ) -> Bool {
        if window.isMinimized {
            return false
        }

        if isFinderWindowlessPlaceholderInfo(window) {
            return false
        }

        let normalizedTitle = normalizedWindowTitle(window.windowName ?? "")
        let isBrowser = isSpecificFinderBrowserWindow(window)
        let isGenericShell = normalizedTitle == "finder"
        guard isBrowser || isGenericShell else {
            return false
        }

        if window.isHidden {
            return true
        }

        if !window.isOnScreen {
            return true
        }

        if isOffScreenPhantomBounds(window.bounds) {
            return true
        }

        if window.hasReliableWindowID,
           window.windowID != 0,
           let visibleCGWindowIDs,
           !visibleCGWindowIDs.contains(window.windowID) {
            return true
        }

        if window.hasReliableWindowID,
           window.windowID != 0,
           isBrowser,
           let cgWindowNamesByID,
           !finderAXTitleMatchesCG(
               axTitle: window.windowName ?? "",
               cgTitle: cgWindowNamesByID[window.windowID]
           ) {
            return true
        }

        return false
    }

    /// Finder restore surfaces keep an AX folder title but expose a different (or empty) CG window name.
    private static func finderAXTitleMatchesCG(axTitle: String, cgTitle: String?) -> Bool {
        let normalizedAX = normalizedWindowTitle(axTitle)
        guard !normalizedAX.isEmpty else { return true }

        guard let cgTitle else { return false }

        let normalizedCG = normalizedWindowTitle(cgTitle)
        guard !normalizedCG.isEmpty else { return false }

        // macOS often reports the generic app name in CGWindowList for real Finder browsers.
        if normalizedCG == "finder", isSpecificFinderBrowserTitle(normalizedAX) {
            return true
        }

        return normalizedAX == normalizedCG
            || normalizedCG.contains(normalizedAX)
            || normalizedAX.contains(normalizedCG)
    }

    private static func isFinderWindowlessPlaceholderInfo(_ window: WindowInfo) -> Bool {
        !window.hasReliableWindowID
            && window.bounds == .zero
            && !window.isMinimized
            && !window.isOnScreen
            && normalizedWindowTitle(window.windowName ?? "") == "no windows"
    }

    private static func isOffScreenPhantomBounds(_ bounds: CGRect) -> Bool {
        guard bounds.width > 50, bounds.height > 50 else {
            return false
        }

        return bounds.maxX < -80
            || bounds.maxY < -80
            || bounds.minX > 12_000
            || bounds.minY > 12_000
    }

    private static func shouldKeepFinderWindow(
        _ candidate: WindowInfo,
        browserWindows: [WindowInfo]
    ) -> Bool {
        if isSpecificFinderBrowserWindow(candidate) {
            return true
        }

        let normalizedTitle = normalizedWindowTitle(candidate.windowName ?? "")

        if normalizedTitle == "finder" {
            return false
        }

        if normalizedTitle.isEmpty || normalizedTitle == "untitled" {
            if boundsOverlapSignificantly(candidate.bounds, anyOf: browserWindows) {
                return false
            }
        }

        if browserWindows.contains(where: { sharesFinderCaptureSurface(candidate, $0) }) {
            return false
        }

        return true
    }

    private static func isSpecificFinderBrowserWindow(_ window: WindowInfo) -> Bool {
        isSpecificFinderBrowserTitle(normalizedWindowTitle(window.windowName ?? ""))
    }

    private static func isSpecificFinderBrowserTitle(_ normalizedTitle: String) -> Bool {
        guard !normalizedTitle.isEmpty, normalizedTitle != "finder", normalizedTitle != "untitled" else {
            return false
        }
        return true
    }

    private static func sharesFinderCaptureSurface(_ lhs: WindowInfo, _ rhs: WindowInfo) -> Bool {
        if lhs.hasReliableWindowID,
           rhs.hasReliableWindowID,
           lhs.windowID != 0,
           lhs.windowID == rhs.windowID {
            return true
        }
        return boundsOverlapSignificantly(lhs.bounds, rhs.bounds)
    }

    private static func boundsOverlapSignificantly(_ lhs: CGRect, anyOf others: [WindowInfo]) -> Bool {
        others.contains { boundsOverlapSignificantly(lhs, $0.bounds) }
    }

    private static func boundsOverlapSignificantly(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        guard lhs.width > 50, lhs.height > 50, rhs.width > 50, rhs.height > 50 else {
            return false
        }

        let intersection = lhs.intersection(rhs)
        guard intersection.width > 1, intersection.height > 1 else {
            return false
        }

        let intersectionArea = intersection.width * intersection.height
        let smallerArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
        guard smallerArea > 0 else { return false }

        return intersectionArea / smallerArea >= 0.82
    }

    private static func collapseFinderWindowsSharingCaptureID(_ windows: [WindowInfo]) -> [WindowInfo] {
        var bestByWindowID: [CGWindowID: WindowInfo] = [:]
        var withoutReliableID: [WindowInfo] = []

        for window in windows {
            guard window.hasReliableWindowID, window.windowID != 0 else {
                withoutReliableID.append(window)
                continue
            }

            if let existing = bestByWindowID[window.windowID] {
                if prefersFinderWindowForCapture(window, over: existing) {
                    bestByWindowID[window.windowID] = window
                }
            } else {
                bestByWindowID[window.windowID] = window
            }
        }

        return withoutReliableID + bestByWindowID.values.sorted {
            ($0.axIndex ?? Int.max) < ($1.axIndex ?? Int.max)
        }
    }

    private static func prefersFinderWindowForCapture(_ candidate: WindowInfo, over incumbent: WindowInfo) -> Bool {
        let candidateScore = windowPreferenceScore(candidate)
        let incumbentScore = windowPreferenceScore(incumbent)

        if candidateScore != incumbentScore {
            return candidateScore > incumbentScore
        }

        if isSpecificFinderBrowserWindow(candidate) != isSpecificFinderBrowserWindow(incumbent) {
            return isSpecificFinderBrowserWindow(candidate)
        }

        return (candidate.axIndex ?? Int.max) < (incumbent.axIndex ?? Int.max)
    }

    private static func deduplicatedWindows(_ windows: [WindowInfo]) -> [WindowInfo] {
        var result: [WindowInfo] = []

        for window in windows {
            if let duplicateIndex = result.firstIndex(where: { existing in
                windowsRepresentSameSurface(existing, window)
            }) {
                if windowPreferenceScore(window) > windowPreferenceScore(result[duplicateIndex]) {
                    result[duplicateIndex] = window
                }
            } else {
                result.append(window)
            }
        }

        return result
    }

    private static func windowsRepresentSameSurface(_ lhs: WindowInfo, _ rhs: WindowInfo) -> Bool {
        let lhsIdentity = previewIdentity(for: lhs)
        let rhsIdentity = previewIdentity(for: rhs)

        if lhsIdentity.matches(rhsIdentity) {
            return true
        }

        if lhs.hasReliableWindowID,
           rhs.hasReliableWindowID,
           lhs.windowID != 0,
           rhs.windowID != 0,
           lhs.windowID != rhs.windowID {
            return false
        }

        if lhs.hasReliableWindowID,
           rhs.hasReliableWindowID,
           lhs.windowID != 0,
           rhs.windowID != 0,
           lhs.windowID == rhs.windowID {
            return true
        }

        return false
    }

    private static func previewIdentity(for window: WindowInfo) -> PreviewIdentity {
        PreviewIdentity(
            ownerPID: window.ownerPID,
            bundleIdentifier: window.ownerBundleIdentifier,
            cgWindowID: window.windowID,
            axIndex: window.axIndex,
            title: window.windowName ?? window.ownerName,
            bounds: window.bounds,
            hasReliableCGWindowID: window.hasReliableWindowID
        )
    }

    private static func normalizedWindowTitle(_ title: String) -> String {
        PreviewIdentity.normalizedTitle(title)
    }

    private static func windowPreferenceScore(_ window: WindowInfo) -> Int {
        var score = 0

        if window.hasReliableWindowID {
            score += 1_000
        }
        if window.isOnScreen {
            score += 200
        }
        if !window.isMinimized {
            score += 100
        }

        let area = Int(window.bounds.width * window.bounds.height)
        if area > 0 {
            score += min(area / 10_000, 150)
        }

        if let axIndex = window.axIndex {
            score += max(0, 20 - axIndex)
        }

        return score
    }

    private static func currentSpaceWindowIDs() -> Set<CGWindowID>? {
        Set(visibleCGWindowList().map(\.windowID))
    }

    private static func visibleCGWindowIDs(forOwnerPID pid: pid_t) -> Set<CGWindowID> {
        Set(
            visibleCGWindowList()
                .filter { $0.ownerPID == pid }
                .map(\.windowID)
        )
    }

    private static func cgWindowNamesByID(forOwnerPID pid: pid_t) -> [CGWindowID: String] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return [:]
        }

        var names: [CGWindowID: String] = [:]
        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid,
                  let number = info[kCGWindowNumber as String] as? NSNumber else {
                continue
            }

            let windowID = CGWindowID(number.uint32Value)
            names[windowID] = info[kCGWindowName as String] as? String ?? ""
        }

        return names
    }

    private struct VisibleCGWindow {
        let windowID: CGWindowID
        let ownerPID: pid_t
    }

    private static func visibleCGWindowList() -> [VisibleCGWindow] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return windowList.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? NSNumber else {
                return nil
            }

            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { return nil }

            if let alpha = info[kCGWindowAlpha as String] as? CGFloat, alpha < 0.05 {
                return nil
            }

            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32 else {
                return nil
            }

            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let width = boundsDict["Width"] as? CGFloat,
                  let height = boundsDict["Height"] as? CGFloat,
                  width >= 50,
                  height >= 50 else {
                return nil
            }

            return VisibleCGWindow(
                windowID: CGWindowID(number.uint32Value),
                ownerPID: pid_t(ownerPID)
            )
        }
    }

    /// Merge real layer-0 CG windows that AX did not return (typical for fullscreen
    /// Electron windows on other Spaces). Only used when `includeAllSpaces` is on.
    private static func appendCGDiscoveredWindows(
        to windows: inout [WindowInfo],
        pid: pid_t,
        bundleIdentifier: String,
        ownerName: String,
        options: EnumerationOptions,
        currentSpaceWindowIDs: Set<CGWindowID>?
    ) {
        let existingIDs = Set(windows.filter(\.hasReliableWindowID).map(\.windowID))
        let candidates = allLayerZeroWindows(forOwnerPID: pid)

        for candidate in candidates {
            guard !existingIDs.contains(candidate.windowID) else { continue }

            // Skip unnamed chrome / strips (Cursor logs: 1512x33 bars, 64x64 ornaments).
            // Real editor windows have a title and normal content size.
            let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            guard candidate.width >= options.minimumWidth,
                  candidate.height >= options.minimumHeight else { continue }
            // Title-bar-sized surfaces still clear 50pt; require a real content height.
            guard candidate.height >= 100 else { continue }

            let isOnCurrentSpace = currentSpaceWindowIDs?.contains(candidate.windowID) ?? false
            windows.append(
                WindowInfo(
                    windowID: candidate.windowID,
                    ownerPID: pid,
                    ownerBundleIdentifier: bundleIdentifier,
                    axIndex: nil,
                    ownerName: ownerName,
                    windowName: name,
                    bounds: CGRect(x: 0, y: 0, width: candidate.width, height: candidate.height),
                    isOnScreen: isOnCurrentSpace,
                    isMinimized: false,
                    isHidden: false,
                    isMain: false,
                    spaceID: nil,
                    hasReliableWindowID: true
                )
            )
        }
    }

    private func logInventory(
        appName: String,
        axWindowCount: Int,
        acceptedWindows: [WindowInfo],
        rejectedWindows: [String]
    ) {
        let accepted = acceptedWindows
            .map { "#\($0.axIndex.map(String.init) ?? "-") id=\($0.windowID) reliable=\($0.hasReliableWindowID) minimized=\($0.isMinimized) onScreen=\($0.isOnScreen) title=\($0.windowName ?? "untitled")" }
            .joined(separator: " | ")
        let rejected = rejectedWindows.isEmpty ? "none" : rejectedWindows.joined(separator: " | ")
        WLLog.cache.debug("\(appName): AX=\(axWindowCount) accepted=\(acceptedWindows.count) windows=\(accepted.isEmpty ? "none" : accepted) rejected=\(rejected)")
    }

    private struct CGWindowSnapshot {
        let windowID: CGWindowID
        let name: String
        let width: CGFloat
        let height: CGFloat
    }

    /// All layer-0 windows for a PID across Spaces (no onScreenOnly).
    private static func allLayerZeroWindows(forOwnerPID pid: pid_t) -> [CGWindowSnapshot] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return windowList.compactMap { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid,
                  let number = info[kCGWindowNumber as String] as? NSNumber else {
                return nil
            }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { return nil }
            if let alpha = info[kCGWindowAlpha as String] as? CGFloat, alpha < 0.05 {
                return nil
            }
            let bounds = info[kCGWindowBounds as String] as? [String: Any]
            let width = bounds?["Width"] as? CGFloat ?? 0
            let height = bounds?["Height"] as? CGFloat ?? 0
            return CGWindowSnapshot(
                windowID: CGWindowID(number.uint32Value),
                name: info[kCGWindowName as String] as? String ?? "",
                width: width,
                height: height
            )
        }
    }
}
