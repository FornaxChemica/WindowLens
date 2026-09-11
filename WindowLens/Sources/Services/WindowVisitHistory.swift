import AppKit
import Combine
import CoreGraphics
import Foundation

struct WindowVisit: Equatable, Identifiable {
    let id: String
    let previewIdentity: PreviewIdentity
    let pid: pid_t
    let bundleIdentifier: String
    let appName: String
    let windowTitle: String
    let windowID: CGWindowID
    let windowIndex: Int?

    static func make(
        app: ApplicationModel,
        window: WindowModel,
        windowIndex: Int?
    ) -> WindowVisit {
        WindowVisit(
            id: window.previewIdentity.surfaceID,
            previewIdentity: window.previewIdentity,
            pid: app.pid,
            bundleIdentifier: app.bundleIdentifier,
            appName: app.name,
            windowTitle: window.title,
            windowID: window.windowID,
            windowIndex: windowIndex
        )
    }

    var menuLabel: String {
        if windowTitle.isEmpty || windowTitle == appName {
            return appName
        }
        return "\(appName) · \(windowTitle)"
    }

    func matchesIdentity(_ other: WindowVisit?) -> Bool {
        guard let other else { return false }
        return previewIdentity.matches(other.previewIdentity)
    }
}

enum WindowHistoryOutcome: Equatable {
    case navigatedBack(WindowVisit, earlierCount: Int, maxCount: Int)
    case navigatedForward(WindowVisit, forwardCount: Int)
    case noEarlierWindows
    case nothingToRedo
    case skippedClosedWindows(skipped: Int, landedOn: WindowVisit?, earlierCount: Int)
    case windowUnavailable

    var hudTitle: String {
        switch self {
        case .navigatedBack(let visit, _, _):
            return "Back to \(visit.menuLabel)"
        case .navigatedForward(let visit, _):
            return "Forward to \(visit.menuLabel)"
        case .noEarlierWindows:
            return "No earlier windows"
        case .nothingToRedo:
            return "Nothing to redo"
        case .skippedClosedWindows(_, let landedOn, _):
            if let landedOn {
                return "Back to \(landedOn.menuLabel)"
            }
            return "No earlier windows"
        case .windowUnavailable:
            return "Window no longer available"
        }
    }

    var hudDetail: String? {
        switch self {
        case .navigatedBack(_, let earlierCount, let maxCount):
            guard earlierCount > 0 else { return nil }
            return "\(earlierCount) earlier · up to \(maxCount)"
        case .navigatedForward(_, let forwardCount):
            guard forwardCount > 0 else { return nil }
            return "\(forwardCount) forward"
        case .skippedClosedWindows(let skipped, _, let earlierCount):
            if skipped > 0 {
                let skippedLabel = skipped == 1 ? "1 closed window skipped" : "\(skipped) closed windows skipped"
                if earlierCount > 0 {
                    return "\(skippedLabel) · \(earlierCount) earlier"
                }
                return skippedLabel
            }
            return nil
        case .noEarlierWindows, .nothingToRedo, .windowUnavailable:
            return nil
        }
    }

    var systemImageName: String {
        switch self {
        case .navigatedBack, .skippedClosedWindows:
            return "arrow.uturn.backward"
        case .navigatedForward:
            return "arrow.uturn.forward"
        case .noEarlierWindows, .nothingToRedo, .windowUnavailable:
            return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        }
    }
}

@MainActor
final class WindowVisitHistory: ObservableObject {
    static let shared = WindowVisitHistory()

    @Published private(set) var menuRevision: UInt64 = 0

    private(set) var past: [WindowVisit] = []
    private(set) var current: WindowVisit?
    private(set) var future: [WindowVisit] = []

    private var isApplyingHistoryNavigation = false
    private var debounceWorkItem: DispatchWorkItem?
    private var workspaceObserver: NSObjectProtocol?
    private let maxPastCount = 10
    private let debounceInterval: TimeInterval = 0.25

    private init() {}

    var isHistoryNavigationInProgress: Bool {
        isApplyingHistoryNavigation
    }

    func startMonitoring() {
        guard workspaceObserver == nil else { return }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor [weak self] in
                self?.scheduleRecordFromFrontmost(triggerApp: app)
            }
        }

        seedFromFrontmostIfNeeded()
        WLLog.general.debug("Monitoring started")
    }

    func stopMonitoring() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    func seedFromFrontmostIfNeeded() {
        guard current == nil else { return }
        recordFrontmostIfChanged(force: true)
    }

    func recordVisit(app: ApplicationModel, window: WindowModel, windowIndex: Int?) {
        guard !isApplyingHistoryNavigation else { return }
        guard !window.isWindowlessPlaceholder else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        guard app.pid != ProcessInfo.processInfo.processIdentifier else { return }

        let visit = WindowVisit.make(app: app, window: window, windowIndex: windowIndex)
        commitVisitTransition(to: visit)
    }

    func jumpToVisit(_ visit: WindowVisit) {
        guard let resolved = resolve(visit) else {
            WindowHistoryHUD.shared.present(outcome: .windowUnavailable)
            return
        }

        WindowSwitcher.shared.switchTo(
            window: resolved.window,
            in: resolved.app,
            windowIndex: resolved.windowIndex
        )
    }

    /// Window Dock/Cmd-Tab is most likely to activate — last focused visit for this app.
    func preferredWindowIndex(in app: ApplicationModel) -> Int? {
        let candidates: [WindowVisit] = {
            var list: [WindowVisit] = []
            if let current { list.append(current) }
            list.append(contentsOf: past.reversed())
            return list
        }()

        for visit in candidates where visit.pid == app.pid
            || (!visit.bundleIdentifier.isEmpty && visit.bundleIdentifier == app.bundleIdentifier) {
            if let index = app.windows.firstIndex(where: {
                !$0.isWindowlessPlaceholder && $0.previewIdentity.matches(visit.previewIdentity)
            }) {
                return index
            }
            if visit.windowID != 0,
               let index = app.windows.firstIndex(where: {
                   !$0.isWindowlessPlaceholder
                       && $0.previewIdentity.hasReliableCGWindowID
                       && $0.windowID == visit.windowID
               }) {
                return index
            }
            if !visit.windowTitle.isEmpty,
               let index = app.windows.firstIndex(where: {
                   !$0.isWindowlessPlaceholder && $0.title == visit.windowTitle
               }) {
                return index
            }
        }
        return nil
    }

    @discardableResult
    func undo() -> WindowHistoryOutcome {
        guard !past.isEmpty else {
            return .noEarlierWindows
        }

        var skipped = 0
        var target: WindowVisit?

        while let candidate = past.last {
            if resolve(candidate) != nil {
                target = candidate
                break
            }
            past.removeLast()
            skipped += 1
        }

        guard let target else {
            bumpMenuRevision()
            if skipped > 0 {
                return .skippedClosedWindows(skipped: skipped, landedOn: nil, earlierCount: 0)
            }
            return .noEarlierWindows
        }

        _ = past.popLast()

        if let current {
            future.insert(current, at: 0)
        }

        current = target
        bumpMenuRevision()

        let earlierCount = past.count
        let outcome: WindowHistoryOutcome
        if skipped > 0 {
            outcome = .skippedClosedWindows(skipped: skipped, landedOn: target, earlierCount: earlierCount)
        } else {
            outcome = .navigatedBack(target, earlierCount: earlierCount, maxCount: maxPastCount)
        }

        applyResolvedVisit(target)
        return outcome
    }

    @discardableResult
    func redo() -> WindowHistoryOutcome {
        guard let target = future.first else {
            return .nothingToRedo
        }

        guard resolve(target) != nil else {
            future.removeFirst()
            bumpMenuRevision()
            return redo()
        }

        future.removeFirst()

        if let current {
            past.append(current)
            trimPast()
        }

        current = target
        bumpMenuRevision()

        let outcome = WindowHistoryOutcome.navigatedForward(target, forwardCount: future.count)
        applyResolvedVisit(target)
        return outcome
    }

    /// MRU list of distinct windows for the menu bar — not a raw visit stack.
    /// Switching between A and B should show each once, most recent first.
    func recentVisitsForMenu(limit: Int = 8) -> [WindowVisit] {
        var newestFirst: [WindowVisit] = []
        if let current {
            newestFirst.append(current)
        }
        newestFirst.append(contentsOf: past.reversed())

        var seen = Set<String>()
        var unique: [WindowVisit] = []

        for visit in newestFirst {
            let key = visit.previewIdentity.surfaceID
            guard seen.insert(key).inserted else { continue }
            guard resolve(visit) != nil else { continue }
            unique.append(visit)
            if unique.count >= limit { break }
        }

        return unique
    }

    func resolve(_ visit: WindowVisit) -> (app: ApplicationModel, window: WindowModel, windowIndex: Int)? {
        let applications = WindowCache.shared.getApplicationsSync(forceRefresh: false)

        guard let app = applications.first(where: {
            $0.pid == visit.pid || $0.bundleIdentifier == visit.bundleIdentifier
        }) else {
            return nil
        }

        if let windowIndex = visit.windowIndex,
           app.windows.indices.contains(windowIndex),
           !app.windows[windowIndex].isWindowlessPlaceholder,
           app.windows[windowIndex].previewIdentity.matches(visit.previewIdentity) {
            return (app, app.windows[windowIndex], windowIndex)
        }

        if let windowIndex = app.windows.firstIndex(where: {
            !$0.isWindowlessPlaceholder && $0.previewIdentity.matches(visit.previewIdentity)
        }) {
            return (app, app.windows[windowIndex], windowIndex)
        }

        if visit.windowID != 0,
           let windowIndex = app.windows.firstIndex(where: {
               !$0.isWindowlessPlaceholder && $0.windowID == visit.windowID
           }) {
            return (app, app.windows[windowIndex], windowIndex)
        }

        let normalizedTarget = PreviewIdentity.normalizedTitle(visit.windowTitle)
        if !normalizedTarget.isEmpty,
           let windowIndex = app.windows.firstIndex(where: {
               !$0.isWindowlessPlaceholder
                   && PreviewIdentity.normalizedTitle($0.title) == normalizedTarget
           }) {
            return (app, app.windows[windowIndex], windowIndex)
        }

        return nil
    }

    private func scheduleRecordFromFrontmost(triggerApp: NSRunningApplication) {
        guard triggerApp.activationPolicy == .regular else { return }
        guard triggerApp.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.recordFrontmostIfChanged(force: false)
            }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func recordFrontmostIfChanged(force: Bool) {
        guard !isApplyingHistoryNavigation else { return }
        guard AXIsProcessTrusted() else { return }

        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.activationPolicy == .regular,
              frontmost.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }

        let pid = frontmost.processIdentifier
        guard pid >= 0 else { return }

        guard let snapshot = AXWindowHelper.focusedWindowSnapshot(for: pid) else {
            if force, let app = matchingApplication(for: frontmost) {
                if let window = app.windows.first(where: { !$0.isWindowlessPlaceholder }) {
                    recordVisit(app: app, window: window, windowIndex: app.windows.firstIndex(where: { $0.id == window.id }))
                }
            }
            return
        }

        guard let app = matchingApplication(for: frontmost) else { return }

        let focusedIdentity = PreviewIdentity(
            ownerPID: pid,
            bundleIdentifier: app.bundleIdentifier,
            cgWindowID: snapshot.windowID,
            title: snapshot.title,
            bounds: snapshot.bounds,
            hasReliableCGWindowID: snapshot.hasReliableWindowID
        )

        if !force,
           let current,
           current.pid == pid,
           current.previewIdentity.matches(focusedIdentity) {
            return
        }

        if let windowIndex = app.windows.firstIndex(where: {
            !$0.isWindowlessPlaceholder && $0.previewIdentity.matches(focusedIdentity)
        }) {
            recordVisit(app: app, window: app.windows[windowIndex], windowIndex: windowIndex)
            return
        }

        if let windowIndex = app.windows.firstIndex(where: {
            !$0.isWindowlessPlaceholder && $0.windowID == snapshot.windowID && snapshot.windowID != 0
        }) {
            recordVisit(app: app, window: app.windows[windowIndex], windowIndex: windowIndex)
            return
        }

        let syntheticWindow = WindowModel(
            windowID: snapshot.windowID,
            title: snapshot.title.isEmpty ? app.name : snapshot.title,
            bounds: snapshot.bounds,
            isMinimized: false,
            isOnScreen: true,
            ownerPID: pid,
            bundleIdentifier: app.bundleIdentifier,
            hasReliableWindowID: snapshot.hasReliableWindowID
        )
        recordVisit(app: app, window: syntheticWindow, windowIndex: nil)
    }

    private func matchingApplication(for runningApp: NSRunningApplication) -> ApplicationModel? {
        let pid = runningApp.processIdentifier
        let bundleIdentifier = runningApp.bundleIdentifier

        if let cached = WindowCache.shared.applicationMatching(
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            forceRefreshIfMissing: false
        ) {
            return cached
        }

        return WindowCache.shared.applicationMatching(
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            forceRefreshIfMissing: true
        )
    }

    private func commitVisitTransition(to visit: WindowVisit) {
        if visit.matchesIdentity(current) {
            return
        }

        if let current {
            past.append(current)
            trimPast()
        }

        current = visit
        future.removeAll()
        bumpMenuRevision()

        WindowUsageStore.shared.recordAccess(
            identity: visit.previewIdentity,
            appName: visit.appName,
            windowTitle: visit.windowTitle
        )
    }

    private func trimPast() {
        if past.count > maxPastCount {
            past.removeFirst(past.count - maxPastCount)
        }
    }

    private func applyResolvedVisit(_ visit: WindowVisit) {
        guard let resolved = resolve(visit) else { return }

        isApplyingHistoryNavigation = true
        WindowSwitcher.shared.switchTo(
            window: resolved.window,
            in: resolved.app,
            windowIndex: resolved.windowIndex
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.isApplyingHistoryNavigation = false
        }
    }

    private func bumpMenuRevision() {
        menuRevision &+= 1
    }
}
