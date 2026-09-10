import AppKit
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers

struct AppUsageSummary: Identifiable, Hashable {
    let id: String
    let appName: String
    let totalMinutes: Int
    let windowCount: Int
    let lastAccessed: Date
    let isStale: Bool
}

struct HeatmapLiveWindow: Equatable {
    let surfaceID: String
    let pid: pid_t
    let bundleIdentifier: String
    let appName: String
    let windowTitle: String
    let windowID: CGWindowID
    let isMinimized: Bool
}

enum HeatmapTimeRange: String, CaseIterable, Identifiable {
    case today = "Today"
    case thisWeek = "This week"
    case thisMonth = "This month"

    var id: String { rawValue }
}

enum HeatmapWindowBadge {
    case active
    case unused
    case stale
}

private enum HeatmapAX {
    static func minimize(_ live: HeatmapLiveWindow) -> Bool {
        guard let axWindow = axWindow(for: live) else { return false }
        return AXUIElementSetAttributeValue(
            axWindow,
            kAXMinimizedAttribute as CFString,
            true as CFTypeRef
        ) == .success
    }

    static func close(_ live: HeatmapLiveWindow) -> Bool {
        guard let axWindow = axWindow(for: live) else { return false }
        return AXWindowHelper.closeWindow(axWindow, pid: live.pid, windowID: live.windowID)
    }

    static func axWindow(for live: HeatmapLiveWindow) -> AXUIElement? {
        if let matched = AXWindowHelper.getAXWindow(for: live.windowID, pid: live.pid) {
            return matched
        }
        guard !live.windowTitle.isEmpty else { return nil }
        for axWindow in AXWindowHelper.getOrderedAXWindows(for: live.pid) {
            let title = copyTitle(from: axWindow)
            if titlesMatch(stored: live.windowTitle, live: title) {
                return axWindow
            }
        }
        return nil
    }

    static func titlesMatch(stored: String, live: String) -> Bool {
        let storedNorm = PreviewIdentity.normalizedTitle(stored)
        let liveNorm = PreviewIdentity.normalizedTitle(live)
        if storedNorm.isEmpty || liveNorm.isEmpty {
            return false
        }
        if storedNorm == liveNorm {
            return true
        }
        let prefixLength = min(36, min(storedNorm.count, liveNorm.count))
        guard prefixLength >= 12 else { return false }
        let storedPrefix = String(storedNorm.prefix(prefixLength))
        let livePrefix = String(liveNorm.prefix(prefixLength))
        return liveNorm.hasPrefix(storedPrefix) || storedNorm.hasPrefix(livePrefix)
    }

    private static func copyTitle(from axWindow: AXUIElement) -> String {
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else {
            return ""
        }
        return title
    }

}

private extension UserPreferences.HeatmapDefaultTimeRange {
    var asHeatmapTimeRange: HeatmapTimeRange {
        switch self {
        case .today: return .today
        case .thisWeek: return .thisWeek
        case .thisMonth: return .thisMonth
        }
    }
}

@MainActor
struct HeatmapView: View {
    @EnvironmentObject var appState: AppState
    @State private var allRecords: [WindowUsageRecord] = []
    @State private var liveLookup: [String: HeatmapLiveWindow] = [:]
    @State private var summaries: [AppUsageSummary] = []
    @State private var selectedAppID: String?
    @State private var timeRange: HeatmapTimeRange = .thisWeek
    @State private var isLoading = true
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var iconByAppName: [String: NSImage] = [:]
    @State private var iconByBundleID: [String: NSImage] = [:]
    @State private var actionMessage: String?
    @State private var actionMessageDismissTask: Task<Void, Never>?
    @State private var runningAppNames: Set<String> = []
    @State private var liveRefreshTask: Task<Void, Never>?
    @State private var liveRefreshEpoch = 0
    @State private var isPerformingWindowAction = false

    private static let hourBuckets = [6, 8, 10, 12, 14, 16, 18, 20, 22]
    private static let liveRefreshDebounce: Duration = .milliseconds(350)
    private static let liveRefreshPollInterval: Duration = .seconds(3)
    private static let weekdayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let staleThreshold: TimeInterval = 5 * 86_400
    private static let unusedThreshold: TimeInterval = 3 * 86_400
    private static let badgeStaleThreshold: TimeInterval = 7 * 86_400

    private var visibleSummaries: [AppUsageSummary] {
        summaries
            .filter { runningAppNames.contains($0.appName) }
            .sorted { $0.totalMinutes > $1.totalMinutes }
    }

    private var selectedSummary: AppUsageSummary? {
        guard let selectedAppID else { return visibleSummaries.first }
        return visibleSummaries.first { $0.id == selectedAppID }
    }

    var body: some View {
        NavigationStack {
            heatmapRoot
                .navigationTitle("Usage Heatmap")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            HeatmapWindowConfigurator.closeWindow()
                        }
                        .keyboardShortcut("w", modifiers: .command)
                    }
                }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            applyDefaultTimeRange()
        }
        .onChange(of: appState.preferences.heatmap.defaultTimeRange) { _, _ in
            applyDefaultTimeRange()
        }
        .task {
            await loadData()
            await liveRefreshLoop()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in
            scheduleLiveRefresh(force: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            scheduleLiveRefresh(force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            scheduleLiveRefresh(force: true)
        }
        .onDisappear {
            liveRefreshTask?.cancel()
            liveRefreshTask = nil
        }
        .animation(.easeInOut(duration: 0.18), value: actionMessage)
    }

    private var heatmapRoot: some View {
        ZStack(alignment: .bottom) {
            NavigationSplitView {
                appSidebar
                    .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            } content: {
                heatmapColumn
                    .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 480)
            } detail: {
                windowDetailColumn
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            }

            if let actionMessage {
                heatmapActionToast(message: actionMessage)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func applyDefaultTimeRange() {
        timeRange = appState.preferences.heatmap.defaultTimeRange.asHeatmapTimeRange
    }

    private func liveRefreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.liveRefreshPollInterval)
            scheduleLiveRefresh(force: false, debounce: false)
        }
    }

    /// Coalesces workspace events, polling, and post-action updates into one background enumeration.
    private func scheduleLiveRefresh(force: Bool, debounce: Bool = true) {
        liveRefreshEpoch += 1
        let epoch = liveRefreshEpoch
        liveRefreshTask?.cancel()
        liveRefreshTask = Task {
            if debounce {
                try? await Task.sleep(for: Self.liveRefreshDebounce)
            }
            guard !Task.isCancelled, epoch == liveRefreshEpoch else { return }
            await fetchAndApplyLiveState(force: force, epoch: epoch)
        }
    }

    private func fetchAndApplyLiveState(force: Bool, epoch: Int) async {
        let applications = await Task.detached(priority: .userInitiated) {
            WindowCache.shared.getApplicationsSync(forceRefresh: force)
        }.value
        guard !Task.isCancelled, epoch == liveRefreshEpoch else { return }
        applyLiveState(from: applications)
    }

    private func applyLiveState(from applications: [ApplicationModel]) {
        liveLookup = Self.buildLiveLookup(from: applications)
        summaries = Self.buildSummaries(
            from: allRecords,
            applications: applications,
            lookup: liveLookup,
            now: Date()
        )
        runningAppNames = Set(applications.map(\.name))
        let icons = Self.buildIconLookup(from: applications)
        iconByAppName = icons.byName
        iconByBundleID = icons.byBundleID
        accessibilityGranted = AXIsProcessTrusted()
        if let selectedAppID,
           !visibleSummaries.contains(where: { $0.id == selectedAppID }) {
            self.selectedAppID = visibleSummaries.first?.id
        }
    }

    private func heatmapActionToast(message: String) -> some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 0)
            Button("OK") {
                self.actionMessage = nil
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    @ViewBuilder
    private var appSidebar: some View {
        let list = List(selection: $selectedAppID) {
            if visibleSummaries.isEmpty {
                Text("No open apps with usage data")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visibleSummaries) { summary in
                    appSidebarRow(summary: summary)
                        .tag(summary.id as String?)
                }
            }
        }

        list.listStyle(.sidebar)
    }

    private func appSidebarRow(summary: AppUsageSummary) -> some View {
        let hasOpenWindows = openWindowCount(for: summary.appName) > 0

        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(usageIntensityColor(minutes: summary.totalMinutes))
                .frame(width: 4)
                .frame(maxHeight: .infinity)

            Image(nsImage: appIcon(for: summary))
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.appName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(appSidebarSubtitle(for: summary, hasOpenWindows: hasOpenWindows))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if !hasOpenWindows && canQuitApp(summary) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.orange.opacity(0.85))
                    .help("Running with no open windows")
            }
        }
        .padding(.vertical, 4)
    }

    private func appSidebarSubtitle(for summary: AppUsageSummary, hasOpenWindows: Bool) -> String {
        let duration = formatDuration(minutes: summary.totalMinutes)
        guard !hasOpenWindows else { return duration }
        return duration == "0m" ? "No windows" : "No windows · \(duration)"
    }

    private func openWindowCount(for appName: String) -> Int {
        windowRows(for: appName).count
    }

    private var heatmapColumn: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let summary = selectedSummary {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.appName)
                            .font(.system(size: 16, weight: .medium))
                        Text("This week: \(formatDuration(minutes: weekMinutes(for: summary.appName)))")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Picker("Range", selection: $timeRange) {
                        ForEach(HeatmapTimeRange.allCases) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    heatmapGrid(for: summary)
                    heatmapLegend(intensityMinutes: summary.totalMinutes)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text("No usage data yet")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func heatmapGrid(for summary: AppUsageSummary) -> some View {
        let cells = heatmapCellCounts(appName: summary.appName, range: timeRange)
        let fillColor = usageIntensityColor(minutes: summary.totalMinutes)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Color.clear.frame(width: 28, height: 1)
                ForEach(0..<7, id: \.self) { dayIndex in
                    Text(Self.weekdayLabels[dayIndex])
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            ForEach(Self.hourBuckets, id: \.self) { hour in
                HStack(spacing: 4) {
                    Text(hourLabel(hour))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, alignment: .trailing)

                    ForEach(0..<7, id: \.self) { dayIndex in
                        let count = cells[dayIndex][hour] ?? 0
                        RoundedRectangle(cornerRadius: 3)
                            .fill(fillColor.opacity(opacityForAccessCount(count)))
                            .frame(height: 18)
                            .frame(maxWidth: .infinity)
                            .help(heatmapCellHelp(dayIndex: dayIndex, hour: hour, count: count))
                    }
                }
            }
        }
    }

    private func heatmapLegend(intensityMinutes: Int) -> some View {
        let fillColor = usageIntensityColor(minutes: intensityMinutes)
        let items: [(String, Int)] = [
            ("No activity", 0),
            ("Light", 2),
            ("Moderate", 6),
            ("Heavy", 16)
        ]

        return HStack(spacing: 16) {
            ForEach(items, id: \.0) { label, sampleCount in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fillColor.opacity(opacityForAccessCount(sampleCount)))
                        .frame(width: 14, height: 14)
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.top, 4)
    }

    private var windowDetailColumn: some View {
        Group {
            if let summary = selectedSummary {
                VStack(spacing: 0) {
                    if !accessibilityGranted {
                        accessibilityBanner
                    }

                    let windows = windowRows(for: summary.appName)
                    if windows.isEmpty {
                        HeatmapNoWindowsPanel(
                            summary: summary,
                            appIcon: appIcon(for: summary),
                            canQuit: canQuitApp(summary),
                            isPerformingAction: isPerformingWindowAction,
                            onQuit: { quitApp(summary) }
                        )
                    } else {
                        List {
                            ForEach(windows) { item in
                                HeatmapWindowRowView(
                                    record: item.record,
                                    live: item.live,
                                    maxAccessCount: item.maxAccessCount,
                                    intensityMinutes: summary.totalMinutes,
                                    badge: item.badge,
                                    accessibilityGranted: accessibilityGranted,
                                    windowActionsEnabled: !isPerformingWindowAction,
                                    onMinimize: {
                                        minimizeWindow(record: item.record, live: item.live)
                                    },
                                    onClose: {
                                        closeWindow(record: item.record, live: item.live)
                                    }
                                )
                            }
                        }
                        .listStyle(.inset)
                    }
                }
            } else {
                Text("Select an app")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var accessibilityBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            Text("Accessibility permission is required to minimize or close windows.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open Settings") {
                NotificationCenter.default.post(name: .openPermissions, object: nil)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }

    private func resolveLive(for record: WindowUsageRecord) -> HeatmapLiveWindow? {
        if let exact = liveLookup[record.surfaceID] {
            return exact
        }
        let storedTitle = record.lastWindowTitle
        let matches = liveLookup.values.filter { live in
            guard live.appName == record.lastAppName else { return false }
            return HeatmapAX.titlesMatch(stored: storedTitle, live: live.windowTitle)
        }
        if matches.count == 1 {
            return matches[0]
        }
        return matches.max(by: { $0.windowTitle.count < $1.windowTitle.count })
    }

    private func presentActionMessage(_ message: String, autoDismiss: Bool = true) {
        actionMessage = message
        actionMessageDismissTask?.cancel()
        guard autoDismiss else { return }
        actionMessageDismissTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            actionMessage = nil
        }
    }

    private func minimizeWindow(record: WindowUsageRecord, live: HeatmapLiveWindow) {
        guard accessibilityGranted else {
            presentActionMessage("Accessibility permission is required to minimize windows.")
            return
        }
        performWindowAction(record: record, live: live, action: .minimize)
    }

    private func closeWindow(record: WindowUsageRecord, live: HeatmapLiveWindow) {
        guard accessibilityGranted else {
            presentActionMessage("Accessibility permission is required to close windows.")
            return
        }
        performWindowAction(record: record, live: live, action: .close)
    }

    private static let nonQuittableBundleIDs: Set<String> = [
        "com.apple.finder"
    ]

    private func canQuitApp(_ summary: AppUsageSummary) -> Bool {
        guard runningAppNames.contains(summary.appName) else { return false }
        if summary.id == Bundle.main.bundleIdentifier { return false }
        if Self.nonQuittableBundleIDs.contains(summary.id) { return false }
        return resolveRunningApp(for: summary) != nil
    }

    private func resolveRunningApp(for summary: AppUsageSummary) -> NSRunningApplication? {
        if summary.id.contains("."),
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: summary.id).first {
            return app
        }
        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName == summary.appName && $0.activationPolicy == .regular
        }
    }

    private func quitApp(_ summary: AppUsageSummary) {
        guard canQuitApp(summary) else { return }
        guard !isPerformingWindowAction else { return }

        guard let runningApp = resolveRunningApp(for: summary) else {
            presentActionMessage("\(summary.appName) is no longer running.")
            scheduleLiveRefresh(force: true)
            return
        }

        isPerformingWindowAction = true
        let appName = summary.appName
        let quittedAppID = summary.id

        Task {
            let success = await Task.detached(priority: .userInitiated) {
                if runningApp.terminate() {
                    return true
                }
                return runningApp.forceTerminate()
            }.value

            WindowCache.shared.invalidate()
            scheduleLiveRefresh(force: true)
            isPerformingWindowAction = false

            if success {
                if selectedAppID == quittedAppID {
                    selectedAppID = visibleSummaries.first(where: { $0.id != quittedAppID })?.id
                }
                presentActionMessage("Quit \(appName)")
            } else {
                presentActionMessage("Couldn't quit \(appName)")
            }
        }
    }

    private enum HeatmapWindowAction {
        case minimize
        case close
    }

    private func performWindowAction(
        record: WindowUsageRecord,
        live: HeatmapLiveWindow,
        action: HeatmapWindowAction
    ) {
        guard !isPerformingWindowAction else { return }
        isPerformingWindowAction = true

        Task {
            let success = await Task.detached(priority: .userInitiated) {
                switch action {
                case .minimize:
                    return HeatmapAX.minimize(live)
                case .close:
                    return HeatmapAX.close(live)
                }
            }.value

            WindowCache.shared.invalidate()
            scheduleLiveRefresh(force: true)
            isPerformingWindowAction = false

            let windowLabel = record.lastWindowTitle.isEmpty ? record.lastAppName : record.lastWindowTitle
            if success {
                switch action {
                case .close:
                    presentActionMessage("Closed \"\(windowLabel)\"")
                case .minimize:
                    presentActionMessage("Minimized \"\(windowLabel)\"")
                }
                return
            }

            switch action {
            case .minimize:
                presentActionMessage("Couldn't minimize \"\(windowLabel)\"")
                WLLog.general.error("minimize failed surfaceID=\(record.surfaceID)")
            case .close:
                if live.isMinimized {
                    presentActionMessage("Couldn't close \"\(windowLabel)\" — try restoring it from the Dock first.")
                } else {
                    presentActionMessage("Couldn't close \"\(windowLabel)\"")
                }
                WLLog.general.error("close failed surfaceID=\(record.surfaceID) windowID=\(live.windowID) minimized=\(live.isMinimized)")
            }
        }
    }

    private func loadData() async {
        isLoading = true
        let records = WindowUsageStore.shared.windowsNotAccessedSince(.distantFuture)
        let applications = await Task.detached(priority: .userInitiated) {
            WindowCache.shared.getApplicationsSync(forceRefresh: true)
        }.value
        applyLoadedSnapshot(records: records, applications: applications)
        isLoading = false
        WLLog.general.debug("loaded \(records.count) records, \(self.summaries.count) apps, \(self.runningAppNames.count) running")
    }

    private func applyLoadedSnapshot(records: [WindowUsageRecord], applications: [ApplicationModel]) {
        let lookup = Self.buildLiveLookup(from: applications)
        allRecords = records
        liveLookup = lookup
        summaries = Self.buildSummaries(from: records, applications: applications, lookup: lookup, now: Date())
        runningAppNames = Set(applications.map(\.name))
        let icons = Self.buildIconLookup(from: applications)
        iconByAppName = icons.byName
        iconByBundleID = icons.byBundleID
        accessibilityGranted = AXIsProcessTrusted()
        if selectedAppID == nil {
            selectedAppID = visibleSummaries.first?.id
        }
    }

    private struct WindowRowItem: Identifiable {
        let id: String
        let record: WindowUsageRecord
        let live: HeatmapLiveWindow
        let maxAccessCount: Int
        let badge: HeatmapWindowBadge?
    }

    private func liveWindowDedupKey(_ live: HeatmapLiveWindow) -> String {
        if live.windowID != 0 {
            return "pid:\(live.pid):wid:\(live.windowID)"
        }
        return "surface:\(live.surfaceID)"
    }

    private func isOwnAppName(_ appName: String) -> Bool {
        liveLookup.values.contains {
            $0.appName == appName && $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
    }

    private func windowRows(for appName: String) -> [WindowRowItem] {
        let records = allRecords
            .filter { $0.lastAppName == appName }
            .sorted { $0.lastAccessedAt > $1.lastAccessedAt }
        let maxCount = max(records.map(\.accessCount).max() ?? 1, 1)
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var seenLiveKeys = Set<String>()
        var items: [WindowRowItem] = []

        for record in records {
            guard let live = resolveLive(for: record) else { continue }
            let dedupKey = liveWindowDedupKey(live)
            guard seenLiveKeys.insert(dedupKey).inserted else { continue }
            let badge = windowBadge(for: record, live: live, frontmostPID: frontmostPID)
            items.append(
                WindowRowItem(
                    id: dedupKey,
                    record: record,
                    live: live,
                    maxAccessCount: maxCount,
                    badge: badge
                )
            )
        }

        guard isOwnAppName(appName) else { return items }

        let ownLiveWindows = liveLookup.values
            .filter { $0.appName == appName }
            .sorted { $0.windowTitle.localizedCaseInsensitiveCompare($1.windowTitle) == .orderedAscending }

        for live in ownLiveWindows {
            let dedupKey = liveWindowDedupKey(live)
            guard seenLiveKeys.insert(dedupKey).inserted else { continue }
            let syntheticRecord = WindowUsageRecord(
                surfaceID: live.surfaceID,
                lastAccessedAt: Date(),
                accessCount: 0,
                lastAppName: appName,
                lastWindowTitle: live.windowTitle,
                firstSeenAt: Date()
            )
            items.append(
                WindowRowItem(
                    id: dedupKey,
                    record: syntheticRecord,
                    live: live,
                    maxAccessCount: maxCount,
                    badge: ownAppLiveBadge(for: live, frontmostPID: frontmostPID)
                )
            )
        }

        return items
    }

    private func ownAppLiveBadge(
        for live: HeatmapLiveWindow,
        frontmostPID: pid_t?
    ) -> HeatmapWindowBadge? {
        if live.isMinimized {
            return nil
        }
        if let frontmostPID, live.pid == frontmostPID {
            return .active
        }
        return nil
    }

    private func windowBadge(
        for record: WindowUsageRecord,
        live: HeatmapLiveWindow?,
        frontmostPID: pid_t?
    ) -> HeatmapWindowBadge? {
        let now = Date()
        let age = now.timeIntervalSince(record.lastAccessedAt)
        if age > Self.badgeStaleThreshold {
            return .stale
        }
        if age > Self.unusedThreshold {
            return .unused
        }
        if let live, live.isMinimized {
            return nil
        }
        if let live, let frontmostPID, live.pid == frontmostPID {
            return .active
        }
        return nil
    }

    private func weekMinutes(for appName: String) -> Int {
        let start = Date().addingTimeInterval(-7 * 86_400)
        return allRecords
            .filter { $0.lastAppName == appName && $0.lastAccessedAt >= start }
            .reduce(0) { $0 + $1.accessCount }
    }

    private func heatmapCellCounts(appName: String, range: HeatmapTimeRange) -> [[Int: Int]] {
        var grid = Array(repeating: [Int: Int](), count: 7)
        let interval = dateInterval(for: range)
        let filtered = allRecords.filter { record in
            record.lastAppName == appName
                && record.lastAccessedAt >= interval.start
                && record.lastAccessedAt <= interval.end
        }

        for record in filtered {
            guard let hour = hourBucket(for: record.lastAccessedAt) else { continue }
            let dayIndex = weekdayIndex(for: record.lastAccessedAt)
            grid[dayIndex][hour, default: 0] += record.accessCount
        }
        return grid
    }

    private func heatmapCellHelp(dayIndex: Int, hour: Int, count: Int) -> String {
        let dayName = fullWeekdayName(dayIndex)
        let endHour = min(hour + 2, 24)
        return "\(dayName) \(hourRangeLabel(start: hour, end: endHour)) - \(count) accesses"
    }

    private func hourRangeLabel(start: Int, end: Int) -> String {
        "\(hourLabel(start))-\(hourLabel(end))"
    }

    private func hourLabel(_ hour: Int) -> String {
        if hour == 0 || hour == 24 { return "12a" }
        if hour < 12 { return "\(hour)a" }
        if hour == 12 { return "12p" }
        return "\(hour - 12)p"
    }

    private func fullWeekdayName(_ dayIndex: Int) -> String {
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        guard dayIndex >= 0, dayIndex < names.count else { return "Day" }
        return names[dayIndex]
    }

    private func appIcon(for summary: AppUsageSummary) -> NSImage {
        Self.resolveAppIcon(
            appName: summary.appName,
            bundleIdentifier: summary.id,
            iconByAppName: iconByAppName,
            iconByBundleID: iconByBundleID
        )
    }

    private func dateInterval(for range: HeatmapTimeRange) -> DateInterval {
        let now = Date()
        let calendar = Calendar.current
        switch range {
        case .today:
            let start = calendar.startOfDay(for: now)
            return DateInterval(start: start, end: now)
        case .thisWeek:
            let start = now.addingTimeInterval(-7 * 86_400)
            return DateInterval(start: start, end: now)
        case .thisMonth:
            let start = now.addingTimeInterval(-30 * 86_400)
            return DateInterval(start: start, end: now)
        }
    }

    private func hourBucket(for date: Date) -> Int? {
        let hour = Calendar.current.component(.hour, from: date)
        guard hour >= 6 else { return nil }
        for bucket in Self.hourBuckets.reversed() {
            if hour >= bucket {
                return bucket
            }
        }
        return nil
    }

    private func weekdayIndex(for date: Date) -> Int {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let weekday = calendar.component(.weekday, from: date)
        return (weekday + 5) % 7
    }
}

private struct HeatmapNoWindowsPanel: View {
    let summary: AppUsageSummary
    let appIcon: NSImage
    let canQuit: Bool
    let isPerformingAction: Bool
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)

            VStack(spacing: 6) {
                Text("No open windows")
                    .font(.system(size: 14, weight: .medium))
                Text("\(summary.appName) is still running in the background.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if canQuit {
                Button(action: onQuit) {
                    Label("Quit \(summary.appName)", systemImage: "power")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.regular)
                .disabled(isPerformingAction)
            } else {
                Text("This app can't be quit from here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct HeatmapWindowRowView: View {
    let record: WindowUsageRecord
    let live: HeatmapLiveWindow
    let maxAccessCount: Int
    let intensityMinutes: Int
    let badge: HeatmapWindowBadge?
    let accessibilityGranted: Bool
    var windowActionsEnabled: Bool = true
    let onMinimize: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(usageIntensityColor(minutes: intensityMinutes))
                .frame(width: 4, height: barHeight)
                .opacity(live.isMinimized ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.lastWindowTitle.isEmpty ? record.lastAppName : record.lastWindowTitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if live.isMinimized {
                Image(systemName: "minus.rectangle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("Minimized")
            }

            if let badge {
                badgeView(badge)
            }

            if isHovered {
                HStack(spacing: 6) {
                    Button(action: onMinimize) {
                        Image(systemName: "minus")
                    }
                    .help(accessibilityGranted ? "Minimize" : "Minimize (requires Accessibility)")
                    .disabled(!windowActionsEnabled || !accessibilityGranted || live.isMinimized)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .help(accessibilityGranted ? "Close" : "Close (requires Accessibility)")
                    .disabled(!windowActionsEnabled || !accessibilityGranted)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
        .opacity(live.isMinimized ? 0.72 : 1)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var barHeight: CGFloat {
        let ratio = CGFloat(record.accessCount) / CGFloat(max(maxAccessCount, 1))
        return min(40, max(12, 12 + 28 * ratio))
    }

    private var subtitle: String {
        let relative = RelativeDateTimeFormatter().localizedString(
            for: record.lastAccessedAt,
            relativeTo: Date()
        )
        return "\(record.lastAppName) · \(relative)"
    }

    @ViewBuilder
    private func badgeView(_ badge: HeatmapWindowBadge) -> some View {
        switch badge {
        case .active:
            Text("Active")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.green.opacity(0.25)))
        case .unused:
            Text("Unused")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.orange.opacity(0.25)))
        case .stale:
            Text("Stale")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.red.opacity(0.22)))
        }
    }
}

private struct HeatmapIconLookup {
    let byName: [String: NSImage]
    let byBundleID: [String: NSImage]
}

private extension HeatmapView {
    static func buildIconLookup(from applications: [ApplicationModel]) -> HeatmapIconLookup {
        var byName: [String: NSImage] = [:]
        var byBundleID: [String: NSImage] = [:]

        for app in applications where !app.bundleIdentifier.isEmpty {
            byName[app.name] = app.icon
            byBundleID[app.bundleIdentifier] = app.icon
        }

        for running in NSWorkspace.shared.runningApplications {
            guard let name = running.localizedName,
                  let bundleID = running.bundleIdentifier,
                  !bundleID.isEmpty else { continue }
            guard let icon = icon(forRunning: running, bundleIdentifier: bundleID) else { continue }
            if byName[name] == nil {
                byName[name] = icon
            }
            if byBundleID[bundleID] == nil {
                byBundleID[bundleID] = icon
            }
        }

        return HeatmapIconLookup(byName: byName, byBundleID: byBundleID)
    }

    static func resolveAppIcon(
        appName: String,
        bundleIdentifier: String,
        iconByAppName: [String: NSImage],
        iconByBundleID: [String: NSImage]
    ) -> NSImage {
        if let cached = iconByAppName[appName] {
            return cached
        }

        if bundleIdentifier.contains("."),
           let cached = iconByBundleID[bundleIdentifier] {
            return cached
        }

        if bundleIdentifier.contains("."),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }

        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }),
           let bundleID = running.bundleIdentifier,
           let icon = icon(forRunning: running, bundleIdentifier: bundleID) {
            return icon
        }

        if bundleIdentifier.contains("."),
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
           let bundleID = running.bundleIdentifier,
           let icon = icon(forRunning: running, bundleIdentifier: bundleID) {
            return icon
        }

        return genericAppIcon()
    }

    static func icon(forRunning app: NSRunningApplication, bundleIdentifier: String) -> NSImage? {
        if let icon = app.icon {
            return icon
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func genericAppIcon() -> NSImage {
        if let cached = genericAppIconCache {
            return cached
        }
        let icon = NSWorkspace.shared.icon(for: .application)
        genericAppIconCache = icon
        return icon
    }

    private static var genericAppIconCache: NSImage?

    static func buildLiveLookup(from applications: [ApplicationModel]) -> [String: HeatmapLiveWindow] {
        var lookup: [String: HeatmapLiveWindow] = [:]

        for app in applications {
            for window in app.windows where !window.isWindowlessPlaceholder {
                let surfaceID = window.previewIdentity.stableKey
                guard !surfaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                lookup[surfaceID] = HeatmapLiveWindow(
                    surfaceID: surfaceID,
                    pid: app.pid,
                    bundleIdentifier: app.bundleIdentifier,
                    appName: app.name,
                    windowTitle: window.title,
                    windowID: window.windowID,
                    isMinimized: window.isMinimized
                )
            }
        }

        return lookup
    }

    static func buildSummaries(
        from records: [WindowUsageRecord],
        applications: [ApplicationModel],
        lookup: [String: HeatmapLiveWindow],
        now: Date
    ) -> [AppUsageSummary] {
        let grouped = Dictionary(grouping: records, by: \.lastAppName)
        var summariesByAppName: [String: AppUsageSummary] = [:]

        for (appName, appRecords) in grouped {
            let bundleFromLookup = lookup.values.first(where: { $0.appName == appName })?.bundleIdentifier
            let bundleFromRunning = NSWorkspace.shared.runningApplications
                .first(where: { $0.localizedName == appName })?
                .bundleIdentifier
            let bundleID = [bundleFromLookup, bundleFromRunning]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .first
            let id = bundleID ?? appName
            let totalMinutes = appRecords.reduce(0) { $0 + $1.accessCount }
            let lastAccessed = appRecords.map(\.lastAccessedAt).max() ?? .distantPast
            let isStale = now.timeIntervalSince(lastAccessed) > staleThreshold

            summariesByAppName[appName] = AppUsageSummary(
                id: id,
                appName: appName,
                totalMinutes: totalMinutes,
                windowCount: appRecords.count,
                lastAccessed: lastAccessed,
                isStale: isStale
            )
        }

        for app in applications {
            guard summariesByAppName[app.name] == nil else { continue }
            let openWindows = app.windows.filter { !$0.isWindowlessPlaceholder }
            guard !openWindows.isEmpty else { continue }

            summariesByAppName[app.name] = AppUsageSummary(
                id: app.bundleIdentifier.isEmpty ? app.name : app.bundleIdentifier,
                appName: app.name,
                totalMinutes: 0,
                windowCount: openWindows.count,
                lastAccessed: .distantPast,
                isStale: true
            )
        }

        return summariesByAppName.values.sorted { $0.totalMinutes > $1.totalMinutes }
    }
}

private func usageIntensityColor(minutes: Int) -> Color {
    switch minutes {
    case 0..<30:
        return Color(hue: 0.0, saturation: 0.0, brightness: 0.5, opacity: 0.3)
    case 30..<120:
        return Color(hue: 0.22, saturation: 0.7, brightness: 0.85, opacity: 0.7)
    case 120..<300:
        return Color(hue: 0.35, saturation: 0.65, brightness: 0.75, opacity: 0.8)
    default:
        return Color(hue: 0.58, saturation: 0.7, brightness: 0.9, opacity: 0.9)
    }
}

private func opacityForAccessCount(_ count: Int) -> Double {
    switch count {
    case 0: return 0.05
    case 1...3: return 0.25
    case 4...8: return 0.5
    case 9...15: return 0.72
    default: return 0.95
    }
}

private func formatDuration(minutes: Int) -> String {
    guard minutes > 0 else { return "0m" }
    if minutes < 60 {
        return "\(minutes)m"
    }
    let hours = minutes / 60
    let remainder = minutes % 60
    if remainder == 0 {
        return "\(hours)h"
    }
    return "\(hours)h \(remainder)m"
}
