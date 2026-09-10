import AppKit
import CoreGraphics
import Foundation

struct WindowAssignment: Codable, Sendable, Equatable {
    let slot: Int
    let windowID: CGWindowID
    let pid: pid_t
    var bundleIdentifier: String
    var appName: String
    var windowTitle: String
    var isAlive: Bool
}

@MainActor
final class WindowNumberRegistry: ObservableObject {
    static let shared = WindowNumberRegistry()

    @Published private(set) var revision: UInt64 = 0

    private var assignments: [Int: WindowAssignment] = [:]
    private var windowToSlot: [CGWindowID: Int] = [:]
    private var initializeRetryCount = 0
    private var didCompleteInitialAssignment = false

    private static let assignmentsKey = "WindowNumberAssignments"
    private static let needsRestoreKey = "WindowNumberRegistryNeedsRestore"

    private init() {}

    func assignedSlot(for windowID: CGWindowID) -> Int? {
        windowToSlot[windowID]
    }

    func assignment(for slot: Int) -> WindowAssignment? {
        assignments[slot]
    }

    func allAssignments() -> [Int: WindowAssignment] {
        assignments
    }

    func initializeFromCache() {
        guard !didCompleteInitialAssignment else { return }

        let apps = WindowCache.shared.getCachedApplications()
        let hasWindows = apps.contains { app in
            app.windows.contains { !$0.isMinimized && !$0.isWindowlessPlaceholder }
        }

        if !hasWindows {
            if initializeRetryCount < 3 {
                initializeRetryCount += 1
                WLLog.switcher.debug("Cache empty, retry \(self.initializeRetryCount)/3 in 0.5s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.initializeFromCache()
                }
            } else {
                WLLog.switcher.error("Cache still empty after retries, skipping assignment")
            }
            return
        }

        initializeRetryCount = 0

        if UserDefaults.standard.bool(forKey: Self.needsRestoreKey),
           let restored = loadSavedAssignments(),
           !restored.isEmpty {
            applyRestoredAssignments(restored)
            WLLog.switcher.debug("Restored \(restored.count) slot assignments from crash recovery")
        } else {
            assignFromMRU(apps: apps)
            WLLog.switcher.debug("Assigned slots from MRU cache order")
        }

        didCompleteInitialAssignment = true
        UserDefaults.standard.set(true, forKey: Self.needsRestoreKey)
        persist()
        bumpRevision()
    }

    func reassign(
        slot: Int,
        to windowID: CGWindowID,
        pid: pid_t,
        appName: String,
        windowTitle: String,
        bundleIdentifier: String = ""
    ) {
        guard (1...9).contains(slot) else { return }

        if let previousSlot = windowToSlot[windowID] {
            assignments.removeValue(forKey: previousSlot)
        }

        if let existing = assignments[slot] {
            windowToSlot.removeValue(forKey: existing.windowID)
        }

        let resolvedBundleID: String
        if bundleIdentifier.isEmpty {
            resolvedBundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        } else {
            resolvedBundleID = bundleIdentifier
        }

        let assignment = WindowAssignment(
            slot: slot,
            windowID: windowID,
            pid: pid,
            bundleIdentifier: resolvedBundleID,
            appName: appName,
            windowTitle: windowTitle,
            isAlive: true
        )
        assignments[slot] = assignment
        windowToSlot[windowID] = slot
        didCompleteInitialAssignment = true
        persist()
        bumpRevision()
        WLLog.switcher.debug("Reassigned slot \(slot) to \(appName): \(windowTitle)")
    }

    func clearSlot(_ slot: Int) {
        guard let existing = assignments[slot] else { return }
        windowToSlot.removeValue(forKey: existing.windowID)
        assignments.removeValue(forKey: slot)
        didCompleteInitialAssignment = true
        persist()
        bumpRevision()
        WLLog.switcher.debug("Cleared slot \(slot)")
    }

    func markDead(windowID: CGWindowID) {
        guard let slot = windowToSlot[windowID],
              var assignment = assignments[slot] else {
            return
        }
        assignment.isAlive = false
        assignments[slot] = assignment
        persist()
        bumpRevision()
        WLLog.switcher.debug("Marked slot \(slot) dead (windowID \(windowID))")
    }

    func updateMetadata(windowID: CGWindowID, appName: String, windowTitle: String) {
        guard let slot = windowToSlot[windowID],
              var assignment = assignments[slot] else {
            return
        }
        assignment.appName = appName
        assignment.windowTitle = windowTitle
        assignments[slot] = assignment
        persist()
        bumpRevision()
    }

    func activate(slot: Int) -> WindowSlotOutcome {
        guard UserPreferences.load().modules.windowSlotsEnabled else {
            return .moduleDisabled
        }

        ensureInitialized()

        guard let assignment = assignments[slot] else {
            WLLog.switcher.error("Slot \(slot) is vacant")
            return .slotVacant(slot)
        }

        guard assignment.isAlive else {
            WLLog.switcher.error("Slot \(slot) window is dead")
            return .windowUnavailable(slot)
        }

        if let resolved = resolveAssignment(assignment) {
            WindowSwitcher.shared.switchTo(
                window: resolved.window,
                in: resolved.app,
                windowIndex: resolved.windowIndex
            )
            WLLog.switcher.debug("Activated slot \(slot): \(assignment.appName): \(assignment.windowTitle)")
            return .activated(
                slot: slot,
                appName: assignment.appName,
                windowTitle: assignment.windowTitle
            )
        }

        markDead(windowID: assignment.windowID)
        WLLog.switcher.error("Slot \(slot) window not found in cache")
        return .windowUnavailable(slot)
    }

    private struct ResolvedWindow {
        let app: ApplicationModel
        let window: WindowModel
        let windowIndex: Int
    }

    private func resolveAssignment(_ assignment: WindowAssignment) -> ResolvedWindow? {
        var apps = WindowCache.shared.getCachedApplications()

        if let resolved = matchAssignment(assignment, in: apps) {
            return resolved
        }

        apps = WindowCache.shared.getApplicationsSync(forceRefresh: true)
        if let resolved = matchAssignment(assignment, in: apps) {
            refreshAssignmentMetadata(resolved, slot: assignment.slot)
            return resolved
        }

        return nil
    }

    private func matchAssignment(_ assignment: WindowAssignment, in apps: [ApplicationModel]) -> ResolvedWindow? {
        if let app = apps.first(where: { $0.pid == assignment.pid }),
           let windowIndex = app.windows.firstIndex(where: { $0.windowID == assignment.windowID }) {
            return ResolvedWindow(
                app: app,
                window: app.windows[windowIndex],
                windowIndex: windowIndex
            )
        }

        if let app = apps.first(where: { $0.bundleIdentifier == assignment.bundleIdentifier }),
           let windowIndex = app.windows.firstIndex(where: {
               !$0.isWindowlessPlaceholder &&
               ($0.title == assignment.windowTitle || assignment.windowTitle.isEmpty)
           }) {
            refreshAssignmentBinding(
                slot: assignment.slot,
                windowID: app.windows[windowIndex].windowID,
                pid: app.pid,
                app: app,
                window: app.windows[windowIndex]
            )
            return ResolvedWindow(
                app: app,
                window: app.windows[windowIndex],
                windowIndex: windowIndex
            )
        }

        return nil
    }

    private func refreshAssignmentMetadata(_ resolved: ResolvedWindow, slot: Int) {
        updateMetadata(
            windowID: resolved.window.windowID,
            appName: resolved.app.name,
            windowTitle: resolved.window.title
        )
    }

    private func refreshAssignmentBinding(
        slot: Int,
        windowID: CGWindowID,
        pid: pid_t,
        app: ApplicationModel,
        window: WindowModel
    ) {
        if let old = assignments[slot] {
            windowToSlot.removeValue(forKey: old.windowID)
        }
        windowToSlot.removeValue(forKey: windowID)

        let updated = WindowAssignment(
            slot: slot,
            windowID: windowID,
            pid: pid,
            bundleIdentifier: app.bundleIdentifier,
            appName: app.name,
            windowTitle: window.title,
            isAlive: true
        )
        assignments[slot] = updated
        windowToSlot[windowID] = slot
        persist()
        bumpRevision()
    }

    private func ensureInitialized() {
        guard !didCompleteInitialAssignment else { return }
        if initializeRetryCount >= 3 {
            initializeRetryCount = 0
        }
        initializeFromCache()
    }

    func markAssignmentsForTerminatedPID(_ pid: pid_t) {
        for (windowID, slot) in windowToSlot where assignments[slot]?.pid == pid {
            markDead(windowID: windowID)
        }
    }

    func attemptResurrect(for app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }

        let deadAssignments = assignments.values.filter {
            !$0.isAlive && $0.bundleIdentifier == bundleID
        }
        guard !deadAssignments.isEmpty else { return }

        let apps = WindowCache.shared.getCachedApplications()
        guard let appModel = apps.first(where: { $0.pid == app.processIdentifier }) else { return }

        for dead in deadAssignments {
            guard let matchIndex = appModel.windows.firstIndex(where: {
                !$0.isWindowlessPlaceholder && $0.title == dead.windowTitle
            }) else {
                continue
            }

            let window = appModel.windows[matchIndex]
            assignments.removeValue(forKey: dead.slot)
            windowToSlot.removeValue(forKey: dead.windowID)

            let resurrected = WindowAssignment(
                slot: dead.slot,
                windowID: window.windowID,
                pid: app.processIdentifier,
                bundleIdentifier: bundleID,
                appName: appModel.name,
                windowTitle: window.title,
                isAlive: true
            )

            assignments[dead.slot] = resurrected
            windowToSlot[window.windowID] = dead.slot
            WLLog.switcher.debug("Resurrected slot \(dead.slot) for relaunched \(appModel.name): \(window.title)")
        }

        persist()
        bumpRevision()
    }

    func clearPersistedAssignments() {
        UserDefaults.standard.removeObject(forKey: Self.assignmentsKey)
        UserDefaults.standard.set(false, forKey: Self.needsRestoreKey)
    }

    func slotNumbers(for pid: pid_t) -> [Int] {
        assignments.values
            .filter { $0.pid == pid && $0.isAlive }
            .map(\.slot)
            .sorted()
    }

    private func assignFromMRU(apps: [ApplicationModel]) {
        assignments.removeAll()
        windowToSlot.removeAll()

        var slot = 1
        for app in apps {
            for window in app.windows where !window.isMinimized && !window.isWindowlessPlaceholder {
                guard slot <= 9 else { return }

                let assignment = WindowAssignment(
                    slot: slot,
                    windowID: window.windowID,
                    pid: app.pid,
                    bundleIdentifier: app.bundleIdentifier,
                    appName: app.name,
                    windowTitle: window.title,
                    isAlive: true
                )
                assignments[slot] = assignment
                windowToSlot[window.windowID] = slot
                slot += 1
            }
        }
    }

    private func applyRestoredAssignments(_ restored: [Int: WindowAssignment]) {
        assignments = restored
        windowToSlot.removeAll()
        for (slot, assignment) in restored {
            windowToSlot[assignment.windowID] = slot
            if assignment.isAlive {
                validateAssignmentStillExists(slot: slot)
            }
        }
    }

    private func validateAssignmentStillExists(slot: Int) {
        guard var assignment = assignments[slot] else { return }

        let apps = WindowCache.shared.getCachedApplications()
        let exists = apps.contains { app in
            app.pid == assignment.pid &&
            app.windows.contains { $0.windowID == assignment.windowID }
        }

        if !exists {
            assignment.isAlive = false
            assignments[slot] = assignment
            WLLog.switcher.debug("Restored slot \(slot) window no longer exists, marked dead")
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(Array(assignments.values)) else {
            WLLog.switcher.error("Failed to encode assignments")
            return
        }
        UserDefaults.standard.set(data, forKey: Self.assignmentsKey)
    }

    private func loadSavedAssignments() -> [Int: WindowAssignment]? {
        guard let data = UserDefaults.standard.data(forKey: Self.assignmentsKey) else {
            return nil
        }
        let decoder = JSONDecoder()
        guard let values = try? decoder.decode([WindowAssignment].self, from: data) else {
            return nil
        }
        var result: [Int: WindowAssignment] = [:]
        for assignment in values {
            result[assignment.slot] = assignment
        }
        return result.isEmpty ? nil : result
    }

    private func bumpRevision() {
        revision &+= 1
    }
}
