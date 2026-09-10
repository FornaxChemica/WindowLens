import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import CoreGraphics
import Foundation
import IOKit.hid

enum ShortcutEvent {
    case activationStarted   // Modifier+Tab pressed - start timer, don't show UI yet
    case showSwitcher        // Timer expired without release - show UI now
    case cycleNext
    case cyclePrevious
    case cycleWindowNext
    case cycleWindowPrevious
    case activateSearch
    case pinWorkspaceSearch
    case workspaceSearchScopeCurrentApp
    case workspaceSearchScopeAllWindows
    case confirm
    case dismiss
    case navigateUp      // Arrow up in search mode
    case navigateDown    // Arrow down in search mode
    case navigateRowUp   // Arrow up in workspace mode - previous window surface
    case navigateRowDown // Arrow down in workspace mode - next window surface
    case quickSwitch     // Quick Option+Tab current-app window switch (no UI)
    case quitHoldStarted   // Q key held down - start quit progress
    case quitHoldCancelled // Q key released - cancel quit
    case toggleResourceMonitor // E key tap - toggle mini activity monitor
    case toggleUnusedWindows
    case toggleHeatmap
    case eHoldStarted          // E key pressed - start charging animation
    case aiInsightRequested    // E key held - start ollama + query
    case aiInsightCancelled    // E key released after hold
    case toggleProcessGrouping // F key tap - toggle process grouping in monitor
    case nativeSwitchStarted(reverse: Bool)   // Passive Cmd+Tab observation - never consumes Dock-owned events
    case nativeSwitchCycleNext
    case nativeSwitchCyclePrevious
    case nativeSwitchWindowNext
    case nativeSwitchWindowPrevious
    case nativeSwitchEnded
    /// Cmd+Tab cancelled (Escape / Dock dismissed) — hide preview without activating selection.
    case nativeSwitchCancelled
    case windowHistoryUndo
    case windowHistoryRedo
    case activateWindowSlot(Int)
    case openUsageHeatmap
    case toggleStayAwake
}

private final class KeyboardEventTapHealthTarget: NSObject {
    weak var eventTap: KeyboardEventTap?

    init(eventTap: KeyboardEventTap) {
        self.eventTap = eventTap
    }

    @objc func healthTimerFired(_ timer: Timer) {
        eventTap?.verifyOrRebuild(reason: "periodic")
    }
}

final class KeyboardEventTap {
    let onShortcutTriggered = PassthroughSubject<ShortcutEvent, Never>()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Runloop the tap source is registered on (main — dedicated thread delivered 0 callbacks).
    private var tapRunLoop: CFRunLoop?
    private var healthTimer: Timer?
    private var healthTimerTarget: KeyboardEventTapHealthTarget?
    private var installRetryWorkItem: DispatchWorkItem?
    private let modifierTracker = ModifierKeyTracker()
    private var previousFlags: CGEventFlags = []
    private var switcherVisible = false
    private var searchModeActive = false  // When true, don't auto-confirm on modifier release
    private var searchingWithQuery = false
    private var nativeCommandTabSessionActive = false
    private var pendingNativeSessionEndWorkItem: DispatchWorkItem?
    // Short debounce only filters flagsChanged blips; Dock-destroy ends the session
    // immediately when Command is already up so the preview doesn't linger.
    private let nativeSessionEndDebounceSeconds: TimeInterval = 0.08
    private var callbackCount = 0
    private var hasLoggedFirstCallback = false
    private var hasLoggedMissingInputMonitoringForHealth = false

    private struct ActivationShortcut {
        let name: String
        let keyCode: UInt16
        let modifiers: Set<ModifierKey>
        let usesShiftForReverse: Bool
        let showsImmediately: Bool
    }

    // Logging from a CGEventTap callback can be costly; OSLog filters debug in release.
    private let debugActivationShortcut = ActivationShortcut(
        name: "Control+Shift+Space",
        keyCode: UInt16(kVK_Space),
        modifiers: [.control, .shift],
        usesShiftForReverse: false,
        showsImmediately: true
    )
    private var activeActivationShortcut: ActivationShortcut?

    // Quick-switch detection
    private var activationTime: CFAbsoluteTime = 0
    private var hadInteractionSinceActivation = false
    private let quickSwitchThreshold: CFAbsoluteTime = 0.12  // 120ms - faster detection
    private var showSwitcherTimer: DispatchWorkItem?
    private var pendingActivation = false  // True between activation and timer/release

    // Quit hold detection
    private var isHoldingQuit = false

    // E key hold detection for AI insight
    private var isHoldingE = false
    private var eKeyDownTime: CFAbsoluteTime = 0
    /// Threshold: hold > 400ms = AI insight request, shorter = toggle monitor
    private let eHoldThreshold: CFAbsoluteTime = 0.4
    private let healthCheckInterval: TimeInterval = 5.0
    private let maxInstallRetryCount = 6
    private var installRetryCount = 0

    // Configuration
    private var activationModifier: ModifierKey = .option
    private let activationKeyCode: UInt16 = UInt16(kVK_Tab)
    private let isCommandTabHandlingEnabled = false
    private var cachedShortcuts = ShortcutPreferences()
    /// Never call UserPreferences.load() inside the CGEventTap callback.
    private var cachedModules = UserPreferences.ModuleSettings()

    init() {
        let prefs = UserPreferences.load()
        cachedShortcuts = prefs.shortcuts
        cachedModules = prefs.modules
        WLLog.eventTap.debug("init")
        logStartupDiagnostics(context: "init")
        startHealthMonitoring()
    }

    deinit {
        WLLog.eventTap.debug("deinit")
        disable()
    }

    var isInstalled: Bool {
        eventTap != nil
    }

    func logStartupDiagnostics(context: String) {
        WLLog.eventTap.debug("[\(context)] AXIsProcessTrusted=\(AXIsProcessTrusted())")
        WLLog.eventTap.debug("[\(context)] IOHIDCheckAccess.listenEvent=\(self.hasInputMonitoringAccess())")
        WLLog.eventTap.debug("[\(context)] CGPreflightScreenCaptureAccess=\(CGPreflightScreenCaptureAccess())")
        WLLog.eventTap.debug("[\(context)] bundleID=\(Bundle.main.bundleIdentifier ?? "unknown")")
        logTapState(context: context)
    }

    func scheduleInstall(reason: String, delay: TimeInterval = 1.0) {
        installRetryWorkItem?.cancel()
        guard hasInputMonitoringAccess() else {
            WLLog.eventTap.error("Install not scheduled: Input Monitoring is not granted reason=\(reason)")
            return
        }

        WLLog.eventTap.debug("Scheduling install in \(String(format: "%.1f", delay))s reason=\(reason)")

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let didInstall = self.installIfNeeded(reason: reason)
            if didInstall {
                self.installRetryCount = 0
            } else {
                self.scheduleRetry(afterFailureReason: reason)
            }
        }

        installRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    @discardableResult
    func installIfNeeded(reason: String = "manual") -> Bool {
        guard hasInputMonitoringAccess() else {
            WLLog.eventTap.error("Event tap install skipped: Input Monitoring is not granted reason=\(reason)")
            logTapState(context: "install skipped \(reason)")
            return false
        }

        if let tap = eventTap {
            if runLoopSource == nil {
                WLLog.eventTap.debug("Event tap exists without run loop source; rebuilding")
                rebuildEventTap(reason: "missing run loop source")
                return eventTap != nil && runLoopSource != nil
            }

            let isEnabled = CGEvent.tapIsEnabled(tap: tap)
            WLLog.eventTap.debug("Event tap already exists reason=\(reason) enabled=\(isEnabled)")
            if !isEnabled {
                WLLog.eventTap.debug("Existing tap disabled; re-enabling")
                resetShortcutState(reason: "re-enabling existing tap")
                CGEvent.tapEnable(tap: tap, enable: true)
                logTapState(context: "installIfNeeded re-enable")
            }
            return CGEvent.tapIsEnabled(tap: tap)
        }

        return createEventTap(reason: reason)
    }

    func verifyOrRebuild(reason: String) {
        guard hasInputMonitoringAccess() else {
            if reason != "periodic" || !hasLoggedMissingInputMonitoringForHealth {
                WLLog.eventTap.error("Health check skipped install: Input Monitoring is not granted reason=\(reason)")
                logStartupDiagnostics(context: "health skipped \(reason)")
                hasLoggedMissingInputMonitoringForHealth = true
            }
            return
        }

        hasLoggedMissingInputMonitoringForHealth = false
        WLLog.eventTap.debug("Health check reason=\(reason)")
        logStartupDiagnostics(context: "health \(reason)")

        guard let tap = eventTap else {
            WLLog.eventTap.debug("Health check found no tap; scheduling install")
            scheduleInstall(reason: "health check missing tap", delay: 0.2)
            return
        }

        guard runLoopSource != nil else {
            WLLog.eventTap.debug("Health check found missing run loop source; rebuilding tap")
            rebuildEventTap(reason: "missing run loop source")
            return
        }

        if CGEvent.tapIsEnabled(tap: tap) {
            WLLog.eventTap.debug("Health check OK: tap enabled")
            return
        }

        WLLog.eventTap.debug("Health check found disabled tap; re-enabling")
        resetShortcutState(reason: "health re-enable disabled tap")
        CGEvent.tapEnable(tap: tap, enable: true)

        if CGEvent.tapIsEnabled(tap: tap) {
            WLLog.eventTap.debug("Health check recovered disabled tap")
            return
        }

        WLLog.eventTap.error("Re-enable failed; recreating event tap")
        rebuildEventTap(reason: reason)
    }

    func disable() {
        installRetryWorkItem?.cancel()
        installRetryWorkItem = nil
        healthTimer?.invalidate()
        healthTimer = nil
        healthTimerTarget = nil
        tearDownEventTap(reason: "disable")
        WLLog.eventTap.debug("Disabled")
    }

    func suspend(reason: String) {
        installRetryWorkItem?.cancel()
        installRetryWorkItem = nil
        tearDownEventTap(reason: "suspend \(reason)")
    }

    private func tearDownEventTap(reason: String) {
        WLLog.eventTap.debug("Tearing down event tap reason=\(reason)")
        resetShortcutState(reason: "tearDown \(reason)")
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            // Tap is always on the main runloop (dedicated-thread delivery was dead — 0 callbacks).
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    func setSwitcherVisible(_ visible: Bool) {
        switcherVisible = visible
        if !visible {
            resetShortcutState(reason: "switcher hidden")
        }
    }

    /// AppDelegate cancelled the native session (Escape / Dock gone); keep tap state in sync.
    func cancelNativeCommandTabSessionFromApp() {
        cancelPendingNativeSessionEnd()
        nativeCommandTabSessionActive = false
    }

    func resetShortcutState(reason: String) {
        showSwitcherTimer?.cancel()
        showSwitcherTimer = nil
        cancelPendingNativeSessionEnd()
        nativeCommandTabSessionActive = false
        pendingActivation = false
        activeActivationShortcut = nil
        switcherVisible = false
        searchModeActive = false
        hadInteractionSinceActivation = false
        isHoldingQuit = false
        isHoldingE = false
        WLLog.eventTap.debug("Shortcut state reset reason=\(reason)")
    }

    func setSearchModeActive(_ active: Bool) {
        searchModeActive = active
        WLLog.eventTap.debug("Search mode: \(active)")
    }

    func setSearchingWithQuery(_ active: Bool) {
        searchingWithQuery = active
    }

    func setActivationModifier(_ modifier: ModifierKey) {
        if modifier == .command && !isCommandTabHandlingEnabled {
            activationModifier = .option
            WLLog.eventTap.debug("Command+Tab handling is temporarily disabled; using Option+Tab fallback. Debug shortcut also active: \(self.debugActivationShortcut.name)")
            return
        }

        activationModifier = modifier
        WLLog.eventTap.debug("Activation modifier set to \(modifier.symbol); debug shortcut also active: \(self.debugActivationShortcut.name)")
    }

    func reloadShortcutBindings(from preferences: UserPreferences) {
        cachedShortcuts = preferences.shortcuts
        cachedModules = preferences.modules
        if let modifier = cachedShortcuts.workspaceOpen.primaryModifier {
            setActivationModifier(modifier)
        }
        WLLog.eventTap.debug("Reloaded shortcut bindings")
    }

    private var configuredActivationShortcut: ActivationShortcut {
        let workspace = cachedShortcuts.workspaceOpen
        let modifiers = workspace.modifiers.isEmpty ? Set([activationModifier]) : workspace.modifiers
        let name = workspace.displayString
        return ActivationShortcut(
            name: name,
            keyCode: workspace.keyCode,
            modifiers: modifiers,
            usesShiftForReverse: true,
            showsImmediately: false
        )
    }

    private func shortcut(_ shortcut: ActivationShortcut, isPressedIn flags: CGEventFlags?) -> Bool {
        if let flags {
            return shortcut.modifiers.allSatisfy { flags.contains($0.cgFlag) }
        }
        return modifierTracker.contains(shortcut.modifiers)
    }

    private func matchingActivationShortcut(for keyCode: UInt16, flags: CGEventFlags? = nil) -> ActivationShortcut? {
        if keyCode == debugActivationShortcut.keyCode,
           shortcut(debugActivationShortcut, isPressedIn: flags) {
            return debugActivationShortcut
        }

        let configuredShortcut = configuredActivationShortcut
        if keyCode == configuredShortcut.keyCode,
           shortcut(configuredShortcut, isPressedIn: flags) {
            if configuredShortcut.modifiers.contains(.command) && !isCommandTabHandlingEnabled {
                return nil
            }
            return configuredShortcut
        }

        return nil
    }

    private func activeShortcutMatches(keyCode: UInt16, flags: CGEventFlags? = nil) -> ActivationShortcut? {
        if let activeActivationShortcut,
           keyCode == activeActivationShortcut.keyCode,
           shortcut(activeActivationShortcut, isPressedIn: flags) {
            return activeActivationShortcut
        }

        return matchingActivationShortcut(for: keyCode, flags: flags)
    }

    private func wasActiveActivationModifierReleased(oldFlags: CGEventFlags, newFlags: CGEventFlags) -> Bool {
        guard let shortcut = activeActivationShortcut else { return false }
        return shortcut.modifiers.contains { modifier in
            modifierTracker.wasModifierReleased(oldFlags: oldFlags, newFlags: newFlags, modifier: modifier)
        }
    }

    private func createEventTap(reason: String) -> Bool {
        logStartupDiagnostics(context: "pre-create \(reason)")
        guard hasInputMonitoringAccess() else {
            WLLog.eventTap.error("CGEventTap creation skipped: Input Monitoring is not granted reason=\(reason)")
            return false
        }

        WLLog.eventTap.debug("Creating CGEventTap reason=\(reason) tap=.cgSessionEventTap place=.headInsertEventTap options=.defaultTap")

        // Events to monitor: key down, key up, flags changed (modifiers)
        let eventMask: CGEventMask = (
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        )
        WLLog.eventTap.debug("Event mask=\(eventMask)")

        // Store self reference for callback
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, userInfo in
                guard let userInfo = userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let eventTap = Unmanaged<KeyboardEventTap>.fromOpaque(userInfo).takeUnretainedValue()
                return eventTap.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            WLLog.eventTap.fault("CGEventTap creation FAILED. AXTrusted=\(AXIsProcessTrusted()) inputMonitoring=\(self.hasInputMonitoringAccess())")
            return false
        }
        WLLog.eventTap.debug("CGEventTap creation succeeded")

        eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            WLLog.eventTap.fault("CFMachPortCreateRunLoopSource FAILED")
            eventTap = nil
            return false
        }

        runLoopSource = source
        // Attach to the main runloop. A dedicated EventTap thread could report
        // "installed"/enabled while delivering zero callbacks; the system then
        // times the tap out and stalls Cmd-Tab / typing.
        let mainLoop = CFRunLoopGetMain()
        tapRunLoop = mainLoop
        WLLog.eventTap.debug("RunLoop source created; adding to main runloop")
        CFRunLoopAddSource(mainLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        WLLog.eventTap.debug("CGEventTap enabled=\(CGEvent.tapIsEnabled(tap: tap))")
        hasLoggedFirstCallback = false

        logTapState(context: "post-create \(reason)")
        WLLog.eventTap.debug("Successfully created and enabled; test shortcut: \(self.debugActivationShortcut.name)")
        return true
    }

    private func rebuildEventTap(reason: String) {
        resetShortcutState(reason: "rebuild \(reason)")
        tearDownEventTap(reason: "rebuild \(reason)")
        _ = createEventTap(reason: "rebuild \(reason)")
    }

    private func scheduleRetry(afterFailureReason reason: String) {
        guard hasInputMonitoringAccess() else {
            WLLog.eventTap.error("Install retry skipped: Input Monitoring is not granted after reason=\(reason)")
            return
        }

        guard installRetryCount < maxInstallRetryCount else {
            WLLog.eventTap.error("Install retry limit reached after reason=\(reason)")
            return
        }

        installRetryCount += 1
        let delay = min(5.0, Double(installRetryCount))
        WLLog.eventTap.debug("Scheduling retry #\(self.installRetryCount) in \(String(format: "%.1f", delay))s after failure reason=\(reason)")
        scheduleInstall(reason: "retry #\(installRetryCount) after \(reason)", delay: delay)
    }

    private func startHealthMonitoring() {
        guard healthTimer == nil else { return }
        WLLog.eventTap.debug("Starting health monitor interval=\(self.healthCheckInterval)s")

        let target = KeyboardEventTapHealthTarget(eventTap: self)
        healthTimerTarget = target
        let timer = Timer(
            timeInterval: healthCheckInterval,
            target: target,
            selector: #selector(KeyboardEventTapHealthTarget.healthTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func logTapState(context: String) {
        if let tap = eventTap {
            WLLog.eventTap.debug("[\(context)] tapExists=true tapEnabled=\(CGEvent.tapIsEnabled(tap: tap)) runLoopSourceExists=\(self.runLoopSource != nil)")
        } else {
            WLLog.eventTap.debug("[\(context)] tapExists=false tapEnabled=false runLoopSourceExists=\(self.runLoopSource != nil)")
        }
    }

    private func hasInputMonitoringAccess() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    private func isSystemCommandTabKeyEvent(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> Bool {
        (type == .keyDown || type == .keyUp)
            && keyCode == activationKeyCode
            && flags.contains(.maskCommand)
    }

    private func observeSystemCommandTabEvent(
        type: CGEventType,
        keyCode: UInt16,
        flags: CGEventFlags,
        isRepeat: Bool
    ) {
        guard type == .keyDown, keyCode == activationKeyCode, flags.contains(.maskCommand) else { return }

        // A Tab while Command is down cancels any deferred session-end (false release blips).
        cancelPendingNativeSessionEnd()

        // Autorepeat Tabs still reach Dock (event is passed through), but WindowLens
        // must not schedule provisional cycles — selection tracks via Dock AX only.
        if isRepeat {
            return
        }

        if nativeCommandTabSessionActive {
            if flags.contains(.maskShift) {
                WLLog.eventTap.debug("Observed native Cmd+Shift+Tab cycle")
                onShortcutTriggered.send(.nativeSwitchCyclePrevious)
            } else {
                WLLog.eventTap.debug("Observed native Cmd+Tab cycle")
                onShortcutTriggered.send(.nativeSwitchCycleNext)
            }
        } else {
            nativeCommandTabSessionActive = true
            WLLog.eventTap.debug("Observed native Cmd+Tab session start")
            onShortcutTriggered.send(.nativeSwitchStarted(reverse: flags.contains(.maskShift)))
        }
    }

    private func cancelPendingNativeSessionEnd() {
        pendingNativeSessionEndWorkItem?.cancel()
        pendingNativeSessionEndWorkItem = nil
    }

    private func scheduleNativeSessionEndIfNeeded(callbackCountAtDetect: Int) {
        cancelPendingNativeSessionEnd()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingNativeSessionEndWorkItem = nil
            // Live modifier check — ignore transient flagsChanged blips while Cmd is still held.
            if NSEvent.modifierFlags.contains(.command) {
                return
            }
            guard self.nativeCommandTabSessionActive else { return }
            self.nativeCommandTabSessionActive = false
            WLLog.eventTap.debug("Observed native Cmd+Tab session end")
            self.onShortcutTriggered.send(.nativeSwitchEnded)
        }
        pendingNativeSessionEndWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + nativeSessionEndDebounceSeconds,
            execute: workItem
        )
    }

    private func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Tab:
            return "Tab"
        case kVK_Space:
            return "Space"
        case kVK_ANSI_Slash:
            return "Slash"
        case kVK_ANSI_Grave:
            return "Grave"
        case kVK_ANSI_Z:
            return "Z"
        case kVK_Return:
            return "Return"
        case kVK_Escape:
            return "Escape"
        case kVK_LeftArrow:
            return "LeftArrow"
        case kVK_RightArrow:
            return "RightArrow"
        case kVK_UpArrow:
            return "UpArrow"
        case kVK_DownArrow:
            return "DownArrow"
        default:
            return "Unknown"
        }
    }

    private func modifierDescription(from flags: CGEventFlags) -> String {
        modifierDescription(from: ModifierKey.allCases.filter { flags.contains($0.cgFlag) })
    }

    private func modifierDescription(from modifiers: some Sequence<ModifierKey>) -> String {
        let symbols = modifiers.map(\.symbol).joined()
        return symbols.isEmpty ? "none" : symbols
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Handle tap disabled events
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = type == .tapDisabledByTimeout ? "tapDisabledByTimeout" : "tapDisabledByUserInput"
            WLLog.eventTap.debug("\(reason) received; re-enabling tap")
            resetShortcutState(reason: reason)
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                WLLog.eventTap.debug("Re-enable requested; enabled=\(CGEvent.tapIsEnabled(tap: tap))")
            } else {
                WLLog.eventTap.debug("Disable event received but eventTap is nil; scheduling install")
                scheduleInstall(reason: reason, delay: 0.2)
            }
            return Unmanaged.passUnretained(event)
        }

        callbackCount += 1
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if !hasLoggedFirstCallback {
            hasLoggedFirstCallback = true
            WLLog.eventTap.debug("First key event callback received type=\(type.rawValue) key=\(self.keyName(for: keyCode)) flags=\(self.modifierDescription(from: flags))")
        }

        // Hot path: no UserDefaults / file I/O (stalls the whole keyboard + Dock Tab).

        if isSystemCommandTabKeyEvent(type: type, keyCode: keyCode, flags: flags) {
            if pendingActivation || activeActivationShortcut != nil || switcherVisible {
                showSwitcherTimer?.cancel()
                showSwitcherTimer = nil
                pendingActivation = false
                activeActivationShortcut = nil
                hadInteractionSinceActivation = false
                switcherVisible = false
                searchModeActive = false
            }
            observeSystemCommandTabEvent(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
            // Pass Tab (including autorepeat) through to Dock so Cmd+Tab hold-to-cycle works.
            // WindowLens ignores repeats in observeSystemCommandTabEvent and tracks via Dock AX.
            return Unmanaged.passUnretained(event)
        }

        // Escape cancels the system Cmd+Tab UI; keep our preview in sync.
        if type == .keyDown,
           keyCode == UInt16(kVK_Escape),
           nativeCommandTabSessionActive || pendingNativeSessionEndWorkItem != nil {
            cancelPendingNativeSessionEnd()
            if nativeCommandTabSessionActive {
                nativeCommandTabSessionActive = false
                onShortcutTriggered.send(.nativeSwitchCancelled)
            }
            return Unmanaged.passUnretained(event)
        }

        // Handle modifier changes
        if type == .flagsChanged {
            let oldFlags = previousFlags
            previousFlags = flags
            modifierTracker.update(flags: flags)

            if nativeCommandTabSessionActive,
               modifierTracker.wasModifierReleased(oldFlags: oldFlags, newFlags: flags, modifier: .command) {
                scheduleNativeSessionEndIfNeeded(callbackCountAtDetect: callbackCount)
                return Unmanaged.passUnretained(event)
            }

            // Command pressed again before debounced end fired.
            if pendingNativeSessionEndWorkItem != nil,
               flags.contains(.maskCommand) {
                cancelPendingNativeSessionEnd()
            }

            // Check if the active activation shortcut was released
            if wasActiveActivationModifierReleased(oldFlags: oldFlags, newFlags: flags) {
                let elapsed = CFAbsoluteTimeGetCurrent() - activationTime

                // Cancel the show timer if pending
                showSwitcherTimer?.cancel()
                showSwitcherTimer = nil

                // Quick switch: released before timer fired (UI never shown)
                if pendingActivation && !hadInteractionSinceActivation {
                    pendingActivation = false
                    activeActivationShortcut = nil
                    WLLog.eventTap.debug("Quick switch detected (\(Int(elapsed * 1000))ms)")
                    onShortcutTriggered.send(.quickSwitch)
                    return nil
                }

                // Normal release while switcher visible (not in search mode)
                if switcherVisible && !searchModeActive {
                    pendingActivation = false
                    activeActivationShortcut = nil
                    WLLog.eventTap.debug("Modifier released, confirming selection")
                    onShortcutTriggered.send(.confirm)
                    return nil
                }

                pendingActivation = false
                activeActivationShortcut = nil
            }

            return Unmanaged.passUnretained(event)
        }

        // Handle key-up events
        if type == .keyUp {
            if keyCode == UInt16(kVK_ANSI_Q) && isHoldingQuit {
                isHoldingQuit = false
                WLLog.eventTap.debug("Q released, cancel quit hold")
                onShortcutTriggered.send(.quitHoldCancelled)
                return nil
            }
            if isHoldingE,
               keyCode == cachedShortcuts.resourceMonitorToggle.keyCode,
               cachedModules.resourceMonitorEnabled {
                let holdDuration = CFAbsoluteTimeGetCurrent() - eKeyDownTime
                isHoldingE = false
                if holdDuration < eHoldThreshold {
                    // Short tap → toggle resource monitor
                    WLLog.eventTap.debug("Monitor key tapped (\(Int(holdDuration * 1000))ms), toggle monitor")
                    onShortcutTriggered.send(.toggleResourceMonitor)
                } else {
                    // Long hold → AI insight requested
                    WLLog.eventTap.debug("Monitor key held (\(Int(holdDuration * 1000))ms), AI insight")
                    onShortcutTriggered.send(.aiInsightRequested)
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // Only handle key down events for shortcuts
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        if nativeCommandTabSessionActive,
           flags.contains(.maskCommand),
           keyCode == UInt16(kVK_ANSI_Grave) {
            if flags.contains(.maskShift) {
                onShortcutTriggered.send(.nativeSwitchWindowPrevious)
            } else {
                onShortcutTriggered.send(.nativeSwitchWindowNext)
            }
            return nil
        }

        // Window visit history undo/redo (global, only when switcher is inactive)
        if !switcherVisible && !pendingActivation && !nativeCommandTabSessionActive && !isRepeat,
           cachedModules.windowHistoryEnabled {
            if cachedShortcuts.windowHistoryBack.matches(keyCode: keyCode, flags: flags) {
                onShortcutTriggered.send(.windowHistoryUndo)
                return nil
            }
            if cachedShortcuts.windowHistoryForward.matches(keyCode: keyCode, flags: flags) {
                onShortcutTriggered.send(.windowHistoryRedo)
                return nil
            }
        }

        if !switcherVisible && !pendingActivation && !nativeCommandTabSessionActive && !isRepeat,
           cachedModules.usageHeatmapEnabled,
           cachedShortcuts.usageHeatmapOpen.matches(keyCode: keyCode, flags: flags) {
            onShortcutTriggered.send(.openUsageHeatmap)
            return nil
        }

        if !switcherVisible && !pendingActivation && !nativeCommandTabSessionActive && !isRepeat,
           cachedModules.stayAwakeEnabled,
           cachedShortcuts.stayAwakeToggle.matches(keyCode: keyCode, flags: flags) {
            onShortcutTriggered.send(.toggleStayAwake)
            return nil
        }

        // Global window slot activation
        if !isRepeat,
           cachedModules.windowSlotsEnabled,
           let slot = cachedShortcuts.matchesWindowSlotDigit(keyCode: keyCode, flags: flags) {
            if !Self.isTerminalFrontmost() {
                onShortcutTriggered.send(.activateWindowSlot(slot))
                return nil
            }
        }

        // Handle shortcuts while switcher is visible OR pending (check this FIRST)
        if switcherVisible || pendingActivation {
            // In search mode, Tab cycles windows — not apps — even while Option (etc.) is still held.
            if (searchModeActive || searchingWithQuery), keyCode == activationKeyCode {
                hadInteractionSinceActivation = true
                if modifierTracker.isShiftPressed {
                    WLLog.eventTap.debug("Tab+Shift in search = previous window")
                    onShortcutTriggered.send(.cycleWindowPrevious)
                } else {
                    WLLog.eventTap.debug("Tab in search = next window")
                    onShortcutTriggered.send(.cycleWindowNext)
                }
                return nil
            }

            // Activation key = cycle through apps while holding the active shortcut modifiers.
            // If pending, this cancels quick-switch and shows the panel.
            if let shortcut = activeShortcutMatches(keyCode: keyCode, flags: flags) {
                hadInteractionSinceActivation = true

                // If still pending, cancel timer and show panel now
                if pendingActivation {
                    showSwitcherTimer?.cancel()
                    showSwitcherTimer = nil
                    pendingActivation = false
                    switcherVisible = true
                    WLLog.eventTap.debug("Second activation key pressed (\(shortcut.name)), showing switcher immediately")
                    onShortcutTriggered.send(.showSwitcher)
                    // Don't cycle yet - first show, next activation key will cycle
                    return nil
                }

                if shortcut.usesShiftForReverse && modifierTracker.isShiftPressed {
                    WLLog.eventTap.debug("Cycle previous")
                    onShortcutTriggered.send(.cyclePrevious)
                } else {
                    WLLog.eventTap.debug("Cycle next")
                    onShortcutTriggered.send(.cycleNext)
                }
                return nil
            }

            // Backtick (`) = cycle windows within app (with or without modifier held)
            if keyCode == UInt16(kVK_ANSI_Grave) {
                hadInteractionSinceActivation = true
                if modifierTracker.isShiftPressed {
                    WLLog.eventTap.debug("Cycle window previous")
                    onShortcutTriggered.send(.cycleWindowPrevious)
                } else {
                    WLLog.eventTap.debug("Cycle window next")
                    onShortcutTriggered.send(.cycleWindowNext)
                }
                return nil
            }

            if switcherVisible && !searchModeActive && (keyCode == UInt16(kVK_Space) || keyCode == UInt16(kVK_ANSI_Slash)) {
                hadInteractionSinceActivation = true
                searchModeActive = true
                WLLog.eventTap.debug("Pin workspace search")
                onShortcutTriggered.send(.pinWorkspaceSearch)
                return nil
            }

            // Q = hold to quit selected app (only when not in search mode)
            if !searchModeActive {
                if keyCode == UInt16(kVK_ANSI_Q) {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    if isRepeat {
                        return nil
                    }
                    if !isHoldingQuit {
                        isHoldingQuit = true
                        hadInteractionSinceActivation = true
                        WLLog.eventTap.debug("Q pressed, start quit hold")
                        onShortcutTriggered.send(.quitHoldStarted)
                    }
                    return nil
                }

                // E = tap to toggle monitor, hold for AI insight
                if cachedShortcuts.resourceMonitorToggle.matches(keyCode: keyCode, flags: flags),
                   cachedModules.resourceMonitorEnabled {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    if isRepeat { return nil }
                    if !isHoldingE {
                        isHoldingE = true
                        eKeyDownTime = CFAbsoluteTimeGetCurrent()
                        hadInteractionSinceActivation = true
                        // Send hold-started so UI can show charging animation
                        onShortcutTriggered.send(.eHoldStarted)
                    }
                    return nil
                }

                // F = toggle process grouping in resource monitor
                if keyCode == UInt16(kVK_ANSI_F),
                   cachedModules.resourceMonitorEnabled {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    if isRepeat { return nil }
                    hadInteractionSinceActivation = true
                    onShortcutTriggered.send(.toggleProcessGrouping)
                    return nil
                }
            }

            if keyCode == UInt16(kVK_ANSI_U) {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if isRepeat { return nil }
                hadInteractionSinceActivation = true
                onShortcutTriggered.send(.toggleUnusedWindows)
                return nil
            }

            if keyCode == UInt16(kVK_ANSI_H) {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if isRepeat { return nil }
                hadInteractionSinceActivation = true
                onShortcutTriggered.send(.toggleHeatmap)
                return nil
            }

            // Enter = activate search OR confirm selection (in search mode)
            if keyCode == UInt16(kVK_Return) {
                hadInteractionSinceActivation = true
                if searchModeActive {
                    WLLog.eventTap.debug("Confirm search selection")
                    onShortcutTriggered.send(.confirm)
                } else {
                    WLLog.eventTap.debug("Activate search")
                    onShortcutTriggered.send(.activateSearch)
                }
                return nil
            }

            // Escape = dismiss
            if keyCode == UInt16(kVK_Escape) {
                WLLog.eventTap.debug("Dismiss")
                onShortcutTriggered.send(.dismiss)
                return nil
            }

            // Typed search with results: arrows move the results list, Tab cycles windows.
            if searchingWithQuery {
                if keyCode == UInt16(kVK_UpArrow) || keyCode == UInt16(kVK_LeftArrow) {
                    hadInteractionSinceActivation = true
                    WLLog.eventTap.debug("Navigate up (search results)")
                    onShortcutTriggered.send(.navigateUp)
                    return nil
                }

                if keyCode == UInt16(kVK_DownArrow) || keyCode == UInt16(kVK_RightArrow) {
                    hadInteractionSinceActivation = true
                    WLLog.eventTap.debug("Navigate down (search results)")
                    onShortcutTriggered.send(.navigateDown)
                    return nil
                }

                if keyCode == activationKeyCode {
                    hadInteractionSinceActivation = true
                    if modifierTracker.isShiftPressed {
                        WLLog.eventTap.debug("Tab+Shift in search = previous window")
                        onShortcutTriggered.send(.cycleWindowPrevious)
                    } else {
                        WLLog.eventTap.debug("Tab in search = next window")
                        onShortcutTriggered.send(.cycleWindowNext)
                    }
                    return nil
                }
            } else if searchModeActive {
                // Search field focused but no query yet — pass arrow keys through for typing.
            } else {
                // In normal mode: arrows and WSAD navigate the spatial workspace.
                // Left/Right (A/D) = cycle through apps (linear)
                if keyCode == UInt16(kVK_LeftArrow) || keyCode == UInt16(kVK_ANSI_A) {
                    hadInteractionSinceActivation = true
                    WLLog.eventTap.debug("Left/A = previous app")
                    onShortcutTriggered.send(.cyclePrevious)
                    return nil
                }

                if keyCode == UInt16(kVK_RightArrow) || keyCode == UInt16(kVK_ANSI_D) {
                    hadInteractionSinceActivation = true
                    WLLog.eventTap.debug("Right/D = next app")
                    onShortcutTriggered.send(.cycleNext)
                    return nil
                }

                // Up/Down (W/S) = cycle windows in the selected app.
                if keyCode == UInt16(kVK_UpArrow) || keyCode == UInt16(kVK_ANSI_W) {
                    hadInteractionSinceActivation = true
                    WLLog.eventTap.debug("Up/W = previous window")
                    onShortcutTriggered.send(.navigateRowUp)
                    return nil
                }

                if keyCode == UInt16(kVK_DownArrow) || keyCode == UInt16(kVK_ANSI_S) {
                    hadInteractionSinceActivation = true
                    WLLog.eventTap.debug("Down/S = next window")
                    onShortcutTriggered.send(.navigateRowDown)
                    return nil
                }
            }

            // Pass through other keys
            return Unmanaged.passUnretained(event)
        }

        // Check for activation shortcut only when switcher is not visible.
        if cachedModules.workspaceSwitcherEnabled,
           let shortcut = matchingActivationShortcut(for: keyCode, flags: flags),
           !pendingActivation {
            WLLog.eventTap.debug("Activation started via \(shortcut.name) (switcherVisible=\(self.switcherVisible))")
            previousFlags = flags
            modifierTracker.update(flags: flags)
            activationTime = CFAbsoluteTimeGetCurrent()
            hadInteractionSinceActivation = false
            pendingActivation = true
            activeActivationShortcut = shortcut

            // Notify that activation started (for pre-caching)
            onShortcutTriggered.send(.activationStarted)

            // The temporary diagnostic shortcut should prove the event path immediately.
            showSwitcherTimer?.cancel()
            if shortcut.showsImmediately {
                pendingActivation = false
                switcherVisible = true
                activeActivationShortcut = nil
                WLLog.eventTap.debug("Showing switcher immediately via \(shortcut.name)")
                onShortcutTriggered.send(.showSwitcher)
                return nil
            }

            // Start timer to show switcher if not released quickly
            let timer = DispatchWorkItem { [weak self] in
                guard let self = self, self.pendingActivation else { return }
                self.pendingActivation = false
                self.switcherVisible = true
                WLLog.eventTap.debug("Timer fired, showing switcher via \(self.activeActivationShortcut?.name ?? "unknown shortcut")")
                self.onShortcutTriggered.send(.showSwitcher)
            }
            showSwitcherTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + quickSwitchThreshold, execute: timer)

            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.desktop",
        "com.github.warp"
    ]

    private static func isTerminalFrontmost() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return terminalBundleIdentifiers.contains(bundleID)
    }
}
