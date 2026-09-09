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
    // Fast Cmd+Tab re-presses often land ~100–250ms after release. Ending at 80ms
    // blanked the preview before the next hop could cancel; keep the session warm.
    private let nativeSessionEndDebounceSeconds: TimeInterval = 0.28
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

    // Keep disabled by default. Printing from a CGEventTap callback can cause timeouts.
    private let isKeyboardDebugLoggingEnabled = false
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

    init() {
        cachedShortcuts = UserPreferences.load().shortcuts
        print("[KeyboardEventTap] init")
        logStartupDiagnostics(context: "init")
        startHealthMonitoring()
    }

    deinit {
        print("[KeyboardEventTap] deinit")
        disable()
    }

    var isInstalled: Bool {
        eventTap != nil
    }

    func logStartupDiagnostics(context: String) {
        print("[KeyboardEventTap][\(context)] AXIsProcessTrusted=\(AXIsProcessTrusted())")
        print("[KeyboardEventTap][\(context)] IOHIDCheckAccess.listenEvent=\(hasInputMonitoringAccess())")
        print("[KeyboardEventTap][\(context)] CGPreflightScreenCaptureAccess=\(CGPreflightScreenCaptureAccess())")
        print("[KeyboardEventTap][\(context)] bundleID=\(Bundle.main.bundleIdentifier ?? "unknown")")
        logTapState(context: context)
    }

    func scheduleInstall(reason: String, delay: TimeInterval = 1.0) {
        installRetryWorkItem?.cancel()
        guard hasInputMonitoringAccess() else {
            print("[KeyboardEventTap] Install not scheduled: Input Monitoring is not granted reason=\(reason)")
            return
        }

        print("[KeyboardEventTap] Scheduling install in \(String(format: "%.1f", delay))s reason=\(reason)")

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
            print("[KeyboardEventTap] Event tap install skipped: Input Monitoring is not granted reason=\(reason)")
            logTapState(context: "install skipped \(reason)")
            return false
        }

        if let tap = eventTap {
            if runLoopSource == nil {
                print("[KeyboardEventTap] Event tap exists without run loop source; rebuilding")
                rebuildEventTap(reason: "missing run loop source")
                return eventTap != nil && runLoopSource != nil
            }

            let isEnabled = CGEvent.tapIsEnabled(tap: tap)
            print("[KeyboardEventTap] Event tap already exists reason=\(reason) enabled=\(isEnabled)")
            if !isEnabled {
                print("[KeyboardEventTap] Existing tap disabled; re-enabling")
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
                print("[KeyboardEventTap] Health check skipped install: Input Monitoring is not granted reason=\(reason)")
                logStartupDiagnostics(context: "health skipped \(reason)")
                hasLoggedMissingInputMonitoringForHealth = true
            }
            return
        }

        hasLoggedMissingInputMonitoringForHealth = false
        print("[KeyboardEventTap] Health check reason=\(reason)")
        logStartupDiagnostics(context: "health \(reason)")

        guard let tap = eventTap else {
            print("[KeyboardEventTap] Health check found no tap; scheduling install")
            scheduleInstall(reason: "health check missing tap", delay: 0.2)
            return
        }

        guard runLoopSource != nil else {
            print("[KeyboardEventTap] Health check found missing run loop source; rebuilding tap")
            rebuildEventTap(reason: "missing run loop source")
            return
        }

        if CGEvent.tapIsEnabled(tap: tap) {
            print("[KeyboardEventTap] Health check OK: tap enabled")
            return
        }

        print("[KeyboardEventTap] Health check found disabled tap; re-enabling")
        resetShortcutState(reason: "health re-enable disabled tap")
        CGEvent.tapEnable(tap: tap, enable: true)

        if CGEvent.tapIsEnabled(tap: tap) {
            print("[KeyboardEventTap] Health check recovered disabled tap")
            return
        }

        print("[KeyboardEventTap] Re-enable failed; recreating event tap")
        rebuildEventTap(reason: reason)
    }

    func disable() {
        installRetryWorkItem?.cancel()
        installRetryWorkItem = nil
        healthTimer?.invalidate()
        healthTimer = nil
        healthTimerTarget = nil
        tearDownEventTap(reason: "disable")
        print("[KeyboardEventTap] Disabled")
    }

    func suspend(reason: String) {
        installRetryWorkItem?.cancel()
        installRetryWorkItem = nil
        tearDownEventTap(reason: "suspend \(reason)")
    }

    private func tearDownEventTap(reason: String) {
        print("[KeyboardEventTap] Tearing down event tap reason=\(reason)")
        resetShortcutState(reason: "tearDown \(reason)")
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
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
        pendingActivation = false
        activeActivationShortcut = nil
        switcherVisible = false
        searchModeActive = false
        hadInteractionSinceActivation = false
        isHoldingQuit = false
        isHoldingE = false
        print("[KeyboardEventTap] Shortcut state reset reason=\(reason)")
    }

    func setSearchModeActive(_ active: Bool) {
        searchModeActive = active
        print("[KeyboardEventTap] Search mode: \(active)")
    }

    func setSearchingWithQuery(_ active: Bool) {
        searchingWithQuery = active
    }

    func setActivationModifier(_ modifier: ModifierKey) {
        if modifier == .command && !isCommandTabHandlingEnabled {
            activationModifier = .option
            print("[KeyboardEventTap] Command+Tab handling is temporarily disabled; using Option+Tab fallback. Debug shortcut also active: \(debugActivationShortcut.name)")
            return
        }

        activationModifier = modifier
        print("[KeyboardEventTap] Activation modifier set to \(modifier.symbol); debug shortcut also active: \(debugActivationShortcut.name)")
    }

    func reloadShortcutBindings(from preferences: UserPreferences) {
        cachedShortcuts = preferences.shortcuts
        if let modifier = cachedShortcuts.workspaceOpen.primaryModifier {
            setActivationModifier(modifier)
        }
        print("[KeyboardEventTap] Reloaded shortcut bindings")
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
            print("[KeyboardEventTap] CGEventTap creation skipped: Input Monitoring is not granted reason=\(reason)")
            return false
        }

        print("[KeyboardEventTap] Creating CGEventTap reason=\(reason) tap=.cgSessionEventTap place=.headInsertEventTap options=.defaultTap")

        // Events to monitor: key down, key up, flags changed (modifiers)
        let eventMask: CGEventMask = (
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        )
        print("[KeyboardEventTap] Event mask=\(eventMask)")

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
            print("[KeyboardEventTap] CGEventTap creation FAILED. AXTrusted=\(AXIsProcessTrusted()) inputMonitoring=\(hasInputMonitoringAccess())")
            return false
        }
        print("[KeyboardEventTap] CGEventTap creation succeeded")

        eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            print("[KeyboardEventTap] CFMachPortCreateRunLoopSource FAILED")
            eventTap = nil
            return false
        }

        runLoopSource = source
        print("[KeyboardEventTap] RunLoop source created; adding to main run loop common modes")
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[KeyboardEventTap] CGEventTap enabled=\(CGEvent.tapIsEnabled(tap: tap))")
        hasLoggedFirstCallback = false

        logTapState(context: "post-create \(reason)")
        print("[KeyboardEventTap] Successfully created and enabled; test shortcut: \(debugActivationShortcut.name)")
        return true
    }

    private func rebuildEventTap(reason: String) {
        resetShortcutState(reason: "rebuild \(reason)")
        tearDownEventTap(reason: "rebuild \(reason)")
        _ = createEventTap(reason: "rebuild \(reason)")
    }

    private func scheduleRetry(afterFailureReason reason: String) {
        guard hasInputMonitoringAccess() else {
            print("[KeyboardEventTap] Install retry skipped: Input Monitoring is not granted after reason=\(reason)")
            return
        }

        guard installRetryCount < maxInstallRetryCount else {
            print("[KeyboardEventTap] Install retry limit reached after reason=\(reason)")
            return
        }

        installRetryCount += 1
        let delay = min(5.0, Double(installRetryCount))
        print("[KeyboardEventTap] Scheduling retry #\(installRetryCount) in \(String(format: "%.1f", delay))s after failure reason=\(reason)")
        scheduleInstall(reason: "retry #\(installRetryCount) after \(reason)", delay: delay)
    }

    private func startHealthMonitoring() {
        guard healthTimer == nil else { return }
        print("[KeyboardEventTap] Starting health monitor interval=\(healthCheckInterval)s")

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
            print("[KeyboardEventTap][\(context)] tapExists=true tapEnabled=\(CGEvent.tapIsEnabled(tap: tap)) runLoopSourceExists=\(runLoopSource != nil)")
        } else {
            print("[KeyboardEventTap][\(context)] tapExists=false tapEnabled=false runLoopSourceExists=\(runLoopSource != nil)")
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
                debugLog("Observed native Cmd+Shift+Tab cycle")
                onShortcutTriggered.send(.nativeSwitchCyclePrevious)
            } else {
                debugLog("Observed native Cmd+Tab cycle")
                onShortcutTriggered.send(.nativeSwitchCycleNext)
            }
        } else {
            nativeCommandTabSessionActive = true
            debugLog("Observed native Cmd+Tab session start")
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
            // Live modifier check — ignore transient flagsChanged blips while Cmd is still held.
            if NSEvent.modifierFlags.contains(.command) {
                return
            }
            guard self.nativeCommandTabSessionActive else { return }
            self.nativeCommandTabSessionActive = false
            self.debugLog("Observed native Cmd+Tab session end")
            self.onShortcutTriggered.send(.nativeSwitchEnded)
        }
        pendingNativeSessionEndWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + nativeSessionEndDebounceSeconds,
            execute: workItem
        )
    }

    private func debugLog(_ message: String) {
        guard isKeyboardDebugLoggingEnabled else { return }
        print("[KeyboardEventTap][debug] \(message)")
    }

    private func logKeyboardEvent(type: CGEventType, keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool) {
        guard isKeyboardDebugLoggingEnabled else { return }

        let typeName: String
        switch type {
        case .keyDown:
            typeName = "keyDown"
        case .keyUp:
            typeName = "keyUp"
        case .flagsChanged:
            typeName = "flagsChanged"
        default:
            typeName = "event(\(type.rawValue))"
        }

        print("[KeyboardEventTap][debug] Received key event \(typeName) key=\(keyName(for: keyCode)) code=\(keyCode) flags=\(modifierDescription(from: flags)) tracker=\(modifierDescription(from: modifierTracker.currentModifierSet())) repeat=\(isRepeat)")
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
            print("[KeyboardEventTap] \(reason) received; re-enabling tap")
            resetShortcutState(reason: reason)
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                print("[KeyboardEventTap] Re-enable requested; enabled=\(CGEvent.tapIsEnabled(tap: tap))")
            } else {
                print("[KeyboardEventTap] Disable event received but eventTap is nil; scheduling install")
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
            print("[KeyboardEventTap] First key event callback received type=\(type.rawValue) key=\(keyName(for: keyCode)) flags=\(modifierDescription(from: flags))")
        }

        if type != .flagsChanged {
            logKeyboardEvent(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
        }

        if isSystemCommandTabKeyEvent(type: type, keyCode: keyCode, flags: flags) {
            if pendingActivation || activeActivationShortcut != nil {
                resetShortcutState(reason: "clearing stale workspace state before Cmd+Tab pass-through")
            }
            observeSystemCommandTabEvent(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
            // Always pass Tab through (including autorepeat) so hold-Tab keeps cycling in Dock.
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
            logKeyboardEvent(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)

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
                    debugLog("Quick switch detected (\(Int(elapsed * 1000))ms)")
                    onShortcutTriggered.send(.quickSwitch)
                    return nil
                }

                // Normal release while switcher visible (not in search mode)
                if switcherVisible && !searchModeActive {
                    pendingActivation = false
                    activeActivationShortcut = nil
                    debugLog("Modifier released, confirming selection")
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
                debugLog("Q released, cancel quit hold")
                onShortcutTriggered.send(.quitHoldCancelled)
                return nil
            }
            if isHoldingE,
               keyCode == cachedShortcuts.resourceMonitorToggle.keyCode,
               UserPreferences.load().modules.resourceMonitorEnabled {
                let holdDuration = CFAbsoluteTimeGetCurrent() - eKeyDownTime
                isHoldingE = false
                if holdDuration < eHoldThreshold {
                    // Short tap → toggle resource monitor
                    debugLog("Monitor key tapped (\(Int(holdDuration * 1000))ms), toggle monitor")
                    onShortcutTriggered.send(.toggleResourceMonitor)
                } else {
                    // Long hold → AI insight requested
                    debugLog("Monitor key held (\(Int(holdDuration * 1000))ms), AI insight")
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
           UserPreferences.load().modules.windowHistoryEnabled {
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
           UserPreferences.load().modules.usageHeatmapEnabled,
           cachedShortcuts.usageHeatmapOpen.matches(keyCode: keyCode, flags: flags) {
            onShortcutTriggered.send(.openUsageHeatmap)
            return nil
        }

        if !switcherVisible && !pendingActivation && !nativeCommandTabSessionActive && !isRepeat,
           UserPreferences.load().modules.stayAwakeEnabled,
           cachedShortcuts.stayAwakeToggle.matches(keyCode: keyCode, flags: flags) {
            onShortcutTriggered.send(.toggleStayAwake)
            return nil
        }

        // Global window slot activation
        if !isRepeat,
           UserPreferences.load().modules.windowSlotsEnabled,
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
                    debugLog("Tab+Shift in search = previous window")
                    onShortcutTriggered.send(.cycleWindowPrevious)
                } else {
                    debugLog("Tab in search = next window")
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
                    debugLog("Second activation key pressed (\(shortcut.name)), showing switcher immediately")
                    onShortcutTriggered.send(.showSwitcher)
                    // Don't cycle yet - first show, next activation key will cycle
                    return nil
                }

                if shortcut.usesShiftForReverse && modifierTracker.isShiftPressed {
                    debugLog("Cycle previous")
                    onShortcutTriggered.send(.cyclePrevious)
                } else {
                    debugLog("Cycle next")
                    onShortcutTriggered.send(.cycleNext)
                }
                return nil
            }

            // Backtick (`) = cycle windows within app (with or without modifier held)
            if keyCode == UInt16(kVK_ANSI_Grave) {
                hadInteractionSinceActivation = true
                if modifierTracker.isShiftPressed {
                    debugLog("Cycle window previous")
                    onShortcutTriggered.send(.cycleWindowPrevious)
                } else {
                    debugLog("Cycle window next")
                    onShortcutTriggered.send(.cycleWindowNext)
                }
                return nil
            }

            if switcherVisible && !searchModeActive && (keyCode == UInt16(kVK_Space) || keyCode == UInt16(kVK_ANSI_Slash)) {
                hadInteractionSinceActivation = true
                searchModeActive = true
                debugLog("Pin workspace search")
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
                        debugLog("Q pressed, start quit hold")
                        onShortcutTriggered.send(.quitHoldStarted)
                    }
                    return nil
                }

                // E = tap to toggle monitor, hold for AI insight
                if cachedShortcuts.resourceMonitorToggle.matches(keyCode: keyCode, flags: flags),
                   UserPreferences.load().modules.resourceMonitorEnabled {
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
                   UserPreferences.load().modules.resourceMonitorEnabled {
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
                    debugLog("Confirm search selection")
                    onShortcutTriggered.send(.confirm)
                } else {
                    debugLog("Activate search")
                    onShortcutTriggered.send(.activateSearch)
                }
                return nil
            }

            // Escape = dismiss
            if keyCode == UInt16(kVK_Escape) {
                debugLog("Dismiss")
                onShortcutTriggered.send(.dismiss)
                return nil
            }

            // Typed search with results: arrows move the results list, Tab cycles windows.
            if searchingWithQuery {
                if keyCode == UInt16(kVK_UpArrow) || keyCode == UInt16(kVK_LeftArrow) {
                    hadInteractionSinceActivation = true
                    debugLog("Navigate up (search results)")
                    onShortcutTriggered.send(.navigateUp)
                    return nil
                }

                if keyCode == UInt16(kVK_DownArrow) || keyCode == UInt16(kVK_RightArrow) {
                    hadInteractionSinceActivation = true
                    debugLog("Navigate down (search results)")
                    onShortcutTriggered.send(.navigateDown)
                    return nil
                }

                if keyCode == activationKeyCode {
                    hadInteractionSinceActivation = true
                    if modifierTracker.isShiftPressed {
                        debugLog("Tab+Shift in search = previous window")
                        onShortcutTriggered.send(.cycleWindowPrevious)
                    } else {
                        debugLog("Tab in search = next window")
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
                    debugLog("Left/A = previous app")
                    onShortcutTriggered.send(.cyclePrevious)
                    return nil
                }

                if keyCode == UInt16(kVK_RightArrow) || keyCode == UInt16(kVK_ANSI_D) {
                    hadInteractionSinceActivation = true
                    debugLog("Right/D = next app")
                    onShortcutTriggered.send(.cycleNext)
                    return nil
                }

                // Up/Down (W/S) = cycle windows in the selected app.
                if keyCode == UInt16(kVK_UpArrow) || keyCode == UInt16(kVK_ANSI_W) {
                    hadInteractionSinceActivation = true
                    debugLog("Up/W = previous window")
                    onShortcutTriggered.send(.navigateRowUp)
                    return nil
                }

                if keyCode == UInt16(kVK_DownArrow) || keyCode == UInt16(kVK_ANSI_S) {
                    hadInteractionSinceActivation = true
                    debugLog("Down/S = next window")
                    onShortcutTriggered.send(.navigateRowDown)
                    return nil
                }
            }

            // Pass through other keys
            return Unmanaged.passUnretained(event)
        }

        // Check for activation shortcut only when switcher is not visible.
        if UserPreferences.load().modules.workspaceSwitcherEnabled,
           let shortcut = matchingActivationShortcut(for: keyCode, flags: flags),
           !pendingActivation {
            debugLog("Activation started via \(shortcut.name) (switcherVisible=\(switcherVisible))")
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
                debugLog("Showing switcher immediately via \(shortcut.name)")
                onShortcutTriggered.send(.showSwitcher)
                return nil
            }

            // Start timer to show switcher if not released quickly
            let timer = DispatchWorkItem { [weak self] in
                guard let self = self, self.pendingActivation else { return }
                self.pendingActivation = false
                self.switcherVisible = true
                self.debugLog("Timer fired, showing switcher via \(self.activeActivationShortcut?.name ?? "unknown shortcut")")
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
