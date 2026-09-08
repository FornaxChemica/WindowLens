import AppKit
import Foundation
import IOKit.pwr_mgt
import UserNotifications

/// Central Stay Awake session controller: IOPM assertions, timers, lid-closed, agents.
@MainActor
final class KeepAwakeManager: ObservableObject {
    static let shared = KeepAwakeManager()

    @Published private(set) var isActive = false
    @Published private(set) var activeDuration: KeepAwakeDuration?
    @Published private(set) var selectedDuration: KeepAwakeDuration = .hour1
    @Published private(set) var endsAt: Date?
    @Published private(set) var countdownText = "—"
    @Published private(set) var lidClosedStayAwakeEnabled = false
    @Published private(set) var keepScreenOn = false
    @Published private(set) var pauseWhenHot = true
    @Published private(set) var isPausedForHeat = false
    @Published private(set) var statusMessage = "Off"
    @Published private(set) var lastEndReason: String?
    @Published private(set) var isInstallingLidPrivilege = false
    @Published private(set) var lidPrivilegeError: String?
    @Published private(set) var thermalPauseMessage: String?

    private var systemAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var hasSystemAssertion = false
    private var hasDisplayAssertion = false
    private var endTimer: Timer?
    private var tickTimer: Timer?
    private var agentPollTimer: Timer?
    private var lidClosedArmedByUs = false

    private let safety = KeepAwakeSafetyMonitor.shared
    private let agents = AgentActivityWatcher.shared

    private static let armedFlagName = "stayawake-bag-armed"
    private static let prefsKey = "WindowLensStayAwakeState"

    var bagModeEnabled: Bool { lidClosedStayAwakeEnabled }

    private init() {
        loadPersistedToggles()
        refreshCountdown()
    }

    // MARK: - Lifecycle

    func reconcileOnLaunch() {
        if Self.readArmedFlag() {
            if PrivilegedPmsetRunner.isSleepDisabled() {
                try? PrivilegedPmsetRunner.setSleepDisabled(false)
            }
            Self.clearArmedFlag()
            print("[StayAwake] Reconciled leftover lid-closed sleep disable on launch")
        }
        refreshStatusMessage()
    }

    func prepareForTerminate() {
        endSession(reason: nil, notify: false)
        if lidClosedStayAwakeEnabled {
            clearLidClosedIfArmed()
        }
    }

    // MARK: - Derived

    var remainingDescription: String? {
        guard isActive else { return nil }
        if isPausedForHeat { return "Paused · hot" }
        if activeDuration == .whileAgentsActive {
            if agents.isAnyAgentActive {
                return agents.activeAgents.first?.displayName ?? "AI working"
            }
            return "Waiting for AI"
        }
        if activeDuration == .indefinitely { return "Forever" }
        return countdownText == "—" ? activeDuration?.shortLabel : countdownText
    }

    var commandPreviewLines: [String] {
        var lines: [String] = []
        if isActive {
            var flags = "-i"
            if keepScreenOn { flags += "d" }
            if let interval = activeDuration?.timeInterval {
                lines.append("awake \(flags) · \(Int(interval))s")
            } else if activeDuration?.followsAgents == true {
                lines.append("awake \(flags) · until agents finish")
            } else {
                lines.append("awake \(flags) · until stopped")
            }
        } else {
            lines.append("awake · idle")
        }
        lines.append(
            lidClosedStayAwakeEnabled
                ? "lid · disablesleep 1"
                : "lid · disablesleep 0"
        )
        if pauseWhenHot {
            lines.append(isPausedForHeat ? "thermal · paused" : "thermal · pause when hot")
        }
        return lines
    }

    // MARK: - Public controls

    func selectDuration(_ duration: KeepAwakeDuration) {
        selectedDuration = duration
        if duration != .whileAgentsActive {
            saveDefaultDuration(duration)
        }
        startSession(duration: duration)
    }

    func toggleHero() {
        if isActive {
            endSession(reason: "Stay Awake turned off")
        } else {
            startSession(duration: selectedDuration)
        }
    }

    func startSession(duration: KeepAwakeDuration) {
        guard UserPreferences.load().modules.stayAwakeEnabled else { return }

        endTimer?.invalidate()
        endTimer = nil
        agentPollTimer?.invalidate()
        agentPollTimer = nil
        lastEndReason = nil
        lidPrivilegeError = nil
        isPausedForHeat = false
        thermalPauseMessage = nil

        selectedDuration = duration
        activeDuration = duration
        isActive = true

        if duration.followsAgents {
            endsAt = nil
            ensureWatchAgentsRunning()
        } else if let interval = duration.timeInterval {
            endsAt = Date().addingTimeInterval(interval)
            scheduleEndTimer(at: endsAt!)
            agents.stop()
        } else {
            endsAt = nil
            agents.stop()
        }

        takeAssertions()
        applyLidClosedIfNeeded()
        startSafetyIfNeeded()
        startTickTimer()
        refreshCountdown()
        refreshStatusMessage()
        persistToggles()
        if duration != .whileAgentsActive {
            saveDefaultDuration(duration)
        }
    }

    func endSession(reason: String? = "Stay Awake ended", notify: Bool = true) {
        endTimer?.invalidate()
        endTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
        agentPollTimer?.invalidate()
        agentPollTimer = nil
        agents.stop()
        safety.stop()

        releaseAssertions()
        // Lid setting is independent — only cleared on explicit toggle off or quit.
        // Session end does not clear disablesleep (matches dedicated lid apps).

        let wasActive = isActive
        isActive = false
        activeDuration = nil
        endsAt = nil
        isPausedForHeat = false
        thermalPauseMessage = nil
        lastEndReason = reason
        refreshCountdown()
        refreshStatusMessage()

        if notify, wasActive, reason != nil, !safety.isLidClosed {
            postLocalNotification(title: "Stay Awake", body: reason!)
        }
    }

    func toggleWithDefaultDuration() {
        toggleHero()
    }

    func setKeepScreenOn(_ enabled: Bool) {
        keepScreenOn = enabled
        persistToggles()
        if isActive, !isPausedForHeat {
            takeAssertions()
        }
        refreshStatusMessage()
    }

    func setPauseWhenHot(_ enabled: Bool) {
        pauseWhenHot = enabled
        persistToggles()
        if !enabled, isPausedForHeat, isActive {
            isPausedForHeat = false
            thermalPauseMessage = nil
            takeAssertions()
            applyLidClosedIfNeeded()
        }
        refreshStatusMessage()
    }

    func setLidClosedStayAwakeEnabled(_ enabled: Bool) {
        lidPrivilegeError = nil

        if !enabled {
            lidClosedStayAwakeEnabled = false
            persistToggles()
            clearLidClosedIfArmed()
            refreshStatusMessage()
            return
        }

        if PmsetPrivilegeInstaller.isInstalled {
            finishEnablingLidClosed()
            return
        }

        isInstallingLidPrivilege = true
        Task.detached(priority: .userInitiated) {
            let ok = PmsetPrivilegeInstaller.install()
            await MainActor.run {
                self.isInstallingLidPrivilege = false
                if ok {
                    self.finishEnablingLidClosed()
                } else {
                    self.lidClosedStayAwakeEnabled = false
                    self.lidPrivilegeError = "Couldn’t enable lid-closed stay awake. Enter your Mac password when asked, then try again."
                    self.persistToggles()
                    self.refreshStatusMessage()
                }
            }
        }
    }

    private func finishEnablingLidClosed() {
        lidClosedStayAwakeEnabled = true
        lidPrivilegeError = nil
        persistToggles()
        applyLidClosedIfNeeded()
        if isActive {
            startSafetyIfNeeded()
        }
        refreshStatusMessage()
    }

    func setBagModeEnabled(_ enabled: Bool) {
        setLidClosedStayAwakeEnabled(enabled)
    }

    func installBagModePrivilege() -> Bool {
        PmsetPrivilegeInstaller.install()
    }

    // MARK: - Assertions

    private func takeAssertions() {
        releaseAssertions()
        guard !isPausedForHeat else { return }

        var systemID: IOPMAssertionID = 0
        let systemResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "WindowLens Stay Awake" as CFString,
            &systemID
        )
        if systemResult == kIOReturnSuccess {
            systemAssertionID = systemID
            hasSystemAssertion = true
        }

        if keepScreenOn {
            var displayID: IOPMAssertionID = 0
            let displayResult = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "WindowLens Stay Awake Display" as CFString,
                &displayID
            )
            if displayResult == kIOReturnSuccess {
                displayAssertionID = displayID
                hasDisplayAssertion = true
            }
        }
    }

    private func releaseAssertions() {
        if hasSystemAssertion {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = 0
            hasSystemAssertion = false
        }
        if hasDisplayAssertion {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
            hasDisplayAssertion = false
        }
    }

    // MARK: - Lid closed

    private func applyLidClosedIfNeeded() {
        guard lidClosedStayAwakeEnabled, !isPausedForHeat else { return }
        guard PmsetPrivilegeInstaller.isInstalled else {
            lidClosedStayAwakeEnabled = false
            lidPrivilegeError = "Admin approval is needed to stay awake with the lid closed."
            return
        }
        do {
            try PrivilegedPmsetRunner.setSleepDisabled(true)
            lidClosedArmedByUs = true
            Self.writeArmedFlag()
        } catch {
            print("[StayAwake] Lid-closed enable failed: \(error.localizedDescription)")
            lidClosedStayAwakeEnabled = false
            lidPrivilegeError = error.localizedDescription
        }
    }

    private func clearLidClosedIfArmed() {
        guard lidClosedArmedByUs || Self.readArmedFlag() else { return }
        if PmsetPrivilegeInstaller.isInstalled {
            try? PrivilegedPmsetRunner.setSleepDisabled(false)
        }
        lidClosedArmedByUs = false
        Self.clearArmedFlag()
    }

    private func startSafetyIfNeeded() {
        safety.start(
            onLidClosed: { [weak self] in
                guard let self, self.lidClosedStayAwakeEnabled else { return }
                // When lid closes, blank display unless user asked to keep screen on.
                if !self.keepScreenOn {
                    PrivilegedPmsetRunner.sleepDisplayNow()
                }
            },
            onBatteryUnsafe: { [weak self] reason in
                self?.endSession(reason: reason)
            },
            onThermalChanged: { [weak self] isHot, message in
                self?.handleThermalChange(isHot: isHot, message: message)
            }
        )
    }

    private func handleThermalChange(isHot: Bool, message: String?) {
        guard isActive else { return }
        guard pauseWhenHot else {
            // Legacy hard-stop only on critical if pause is off — still protect.
            if isHot, let message, message.contains("°C"), safety.cpuTemperatureC ?? 0 >= 100 {
                endSession(reason: "\(message) Stay Awake ended to cool down.")
            }
            return
        }

        if isHot {
            guard !isPausedForHeat else {
                thermalPauseMessage = message
                refreshStatusMessage()
                return
            }
            isPausedForHeat = true
            thermalPauseMessage = message.map { "\($0) Paused until cooler." } ?? "Paused until cooler."
            releaseAssertions()
            if lidClosedArmedByUs {
                try? PrivilegedPmsetRunner.setSleepDisabled(false)
                // Keep armed flag so we can re-enable when cool.
            }
            refreshStatusMessage()
        } else if isPausedForHeat {
            isPausedForHeat = false
            thermalPauseMessage = nil
            takeAssertions()
            applyLidClosedIfNeeded()
            refreshStatusMessage()
        }
    }

    // MARK: - Agents

    private func ensureWatchAgentsRunning() {
        // Fresh scan picks up agents already mid-turn when this mode is enabled.
        agents.start()
        agents.scanNow()
        agentPollTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateAgentHold()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        agentPollTimer = timer
        evaluateAgentHold()
    }

    private func evaluateAgentHold() {
        guard isActive, activeDuration?.followsAgents == true else { return }
        refreshCountdown()
        refreshStatusMessage()

        if agents.isAnyAgentActive {
            if !isPausedForHeat, !hasSystemAssertion {
                takeAssertions()
            }
            if lidClosedStayAwakeEnabled, !isPausedForHeat {
                applyLidClosedIfNeeded()
            }
        } else {
            releaseAssertions()
            refreshStatusMessage()
        }
    }

    private func scheduleEndTimer(at date: Date) {
        endTimer?.invalidate()
        let interval = max(date.timeIntervalSinceNow, 0.5)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.endSession(reason: "Stay Awake timer finished")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        endTimer = timer
    }

    private func startTickTimer() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCountdown()
                self?.objectWillChange.send()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func refreshCountdown() {
        guard isActive else {
            countdownText = "—"
            return
        }
        if isPausedForHeat {
            countdownText = "paused"
            return
        }
        if activeDuration == .indefinitely {
            countdownText = "∞"
            return
        }
        if activeDuration == .whileAgentsActive {
            if let agent = agents.activeAgents.first {
                countdownText = agent.elapsedDescription
            } else {
                countdownText = "…"
            }
            return
        }
        guard let endsAt else {
            countdownText = "—"
            return
        }
        let remaining = max(0, endsAt.timeIntervalSinceNow)
        let total = Int(remaining.rounded())
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        countdownText = String(format: "%d:%02d:%02d", hours, mins, secs)
    }

    private func refreshStatusMessage() {
        if !isActive {
            statusMessage = "Off"
            return
        }
        if isPausedForHeat {
            statusMessage = "Paused · hot"
            return
        }
        var parts: [String] = ["On"]
        if let remaining = remainingDescription {
            parts.append(remaining)
        }
        if lidClosedStayAwakeEnabled {
            parts.append("Lid")
        }
        if keepScreenOn {
            parts.append("Screen")
        }
        statusMessage = parts.joined(separator: " · ")
    }

    // MARK: - Persistence

    private struct PersistedToggles: Codable {
        var bagModeEnabled: Bool
        var watchAgentsEnabled: Bool
        var defaultDuration: KeepAwakeDuration
        var keepScreenOn: Bool
        var pauseWhenHot: Bool

        enum CodingKeys: String, CodingKey {
            case bagModeEnabled, watchAgentsEnabled, defaultDuration, keepScreenOn, pauseWhenHot
        }

        init(
            bagModeEnabled: Bool,
            watchAgentsEnabled: Bool,
            defaultDuration: KeepAwakeDuration,
            keepScreenOn: Bool,
            pauseWhenHot: Bool
        ) {
            self.bagModeEnabled = bagModeEnabled
            self.watchAgentsEnabled = watchAgentsEnabled
            self.defaultDuration = defaultDuration
            self.keepScreenOn = keepScreenOn
            self.pauseWhenHot = pauseWhenHot
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bagModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .bagModeEnabled) ?? false
            watchAgentsEnabled = try c.decodeIfPresent(Bool.self, forKey: .watchAgentsEnabled) ?? true
            defaultDuration = try c.decodeIfPresent(KeepAwakeDuration.self, forKey: .defaultDuration) ?? .hour1
            keepScreenOn = try c.decodeIfPresent(Bool.self, forKey: .keepScreenOn) ?? false
            pauseWhenHot = try c.decodeIfPresent(Bool.self, forKey: .pauseWhenHot) ?? true
        }
    }

    private func loadPersistedToggles() {
        let prefs = loadStayAwakePrefs()
        lidClosedStayAwakeEnabled = prefs.bagModeEnabled && PmsetPrivilegeInstaller.isInstalled
        keepScreenOn = prefs.keepScreenOn
        pauseWhenHot = prefs.pauseWhenHot
        selectedDuration = prefs.defaultDuration == .whileAgentsActive ? .hour1 : prefs.defaultDuration
    }

    private func persistToggles() {
        var prefs = loadStayAwakePrefs()
        prefs.bagModeEnabled = lidClosedStayAwakeEnabled
        prefs.defaultDuration = selectedDuration == .whileAgentsActive ? prefs.defaultDuration : selectedDuration
        prefs.keepScreenOn = keepScreenOn
        prefs.pauseWhenHot = pauseWhenHot
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: Self.prefsKey)
        }
    }

    private func saveDefaultDuration(_ duration: KeepAwakeDuration) {
        selectedDuration = duration
        persistToggles()
    }

    private func loadStayAwakePrefs() -> PersistedToggles {
        if let data = UserDefaults.standard.data(forKey: Self.prefsKey),
           let prefs = try? JSONDecoder().decode(PersistedToggles.self, from: data) {
            return prefs
        }
        return PersistedToggles(
            bagModeEnabled: false,
            watchAgentsEnabled: true,
            defaultDuration: .hour1,
            keepScreenOn: false,
            pauseWhenHot: true
        )
    }

    private static func armedFlagURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("WindowLens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(armedFlagName)
    }

    private static func writeArmedFlag() {
        try? "1".write(to: armedFlagURL(), atomically: true, encoding: .utf8)
    }

    private static func clearArmedFlag() {
        try? FileManager.default.removeItem(at: armedFlagURL())
    }

    private static func readArmedFlag() -> Bool {
        FileManager.default.fileExists(atPath: armedFlagURL().path)
    }

    private func postLocalNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(
                identifier: "stayawake-ended-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}
