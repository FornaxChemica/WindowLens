import SwiftUI
import AppKit
import Combine

enum SwitcherPresentationMode: Equatable {
    case nativePreview
    case workspace
}

enum WorkspaceInteractionMode: Equatable {
    case currentAppWindows
    case globalWindowSearch
}

enum WorkspaceSearchScope: Equatable {
    case currentApp
    case allWindows
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: - Switcher State

    @Published var isVisible = false
    @Published var presentationMode: SwitcherPresentationMode = .workspace
    @Published var applications: [ApplicationModel] = []
    @Published var selectedAppIndex = 0
    @Published var selectedWindowIndex = 0
    @Published var isSearchActive = false
    @Published var searchQuery = ""
    @Published var selectedSearchIndex = 0  // Index into search results
    @Published var workspaceMode: WorkspaceInteractionMode = .currentAppWindows
    @Published var workspaceSearchScope: WorkspaceSearchScope = .allWindows
    @Published var isKeyboardNavigating = false  // When true, ignore mouse hover
    @Published var hasMouseMoved = false  // Whether mouse has actually moved since panel appeared
    @Published private(set) var hasNativeSelection = false
    @Published private(set) var nativeSelectedItemFrame: CGRect?
    @Published private(set) var nativeSwitcherFrame: CGRect?
    private(set) var nativeSelectionGeneration: UInt64 = 0
    var lastMousePosition: CGPoint? = nil  // Track last mouse position to detect actual movement
    private var nativeTraversalSnapshot: [ApplicationModel]?
    private var workspaceSessionSnapshot: [ApplicationModel]?
    private var workspaceFrontmostPID: pid_t?
    private var latestLiveMRUApplications: [ApplicationModel] = []

    // MARK: - Resource Monitor State

    @Published var isResourceMonitorActive = false
    @Published var isUnusedWindowsActive: Bool = false
    @Published var isProcessGroupingEnabled = true
    @Published var resourceEntries: [ProcessResourceMonitor.ProcessResourceEntry] = []
    @Published var systemMemory: ProcessResourceMonitor.SystemMemory?
    @Published var systemCPU: ProcessResourceMonitor.SystemCPU?
    @Published var cpuTemperature: Double?
    @Published var thermalState: ProcessInfo.ThermalState = .nominal

    /// History of system CPU usage for the live graph (most recent last)
    @Published var cpuHistory: [Double] = []
    /// History of system memory usage fraction for the live graph
    @Published var memoryHistory: [Double] = []

    // MARK: - AI Insight State

    @Published var aiInsight: String?
    @Published var aiInsightLoading = false
    /// Whether Ollama is reachable (checked once per monitor open)
    @Published var ollamaAvailable = false
    /// Prevents re-querying every poll; only once per monitor session
    private var hasRequestedInsight = false
    /// Timer that clears the AI insight after it becomes stale
    private var aiInsightCooldownTimer: Timer?
    /// Seconds before the AI insight auto-clears (processes change, old summary is irrelevant)
    private let aiInsightCooldown: TimeInterval = 30

    /// Maximum number of history points to keep (at 1s intervals = 60s of data)
    private let maxHistoryPoints = 60

    private var resourceTimer: Timer?
    private var workspaceWindowListRefreshTimer: AnyCancellable?

    // MARK: - E Hold (Charging Animation) State

    @Published var isEHoldActive = false
    @Published var eHoldProgress: CGFloat = 0.0
    private var eHoldTimer: Timer?
    private var eHoldStartTime: Date?
    /// Duration for the charging bar to fill (visual only; actual threshold is in KeyboardEventTap)
    private let eHoldAnimationDuration: TimeInterval = 0.5

    // MARK: - Quit Hold State

    @Published var isQuitHoldActive = false
    @Published var quitHoldProgress: CGFloat = 0.0
    @Published var quitTargetAppIndex: Int? = nil
    private var quitHoldTimer: Timer?
    private var quitHoldStartTime: Date?
    private var quitHoldDuration: TimeInterval { TimeInterval(preferences.quitHoldDuration) }

    // MARK: - Preferences

    @Published var preferences = UserPreferences.load() {
        didSet {
            handleWindowEnumerationPreferenceChange(from: oldValue)
            if oldValue.shortcuts != preferences.shortcuts {
                NotificationCenter.default.post(name: .shortcutsDidChange, object: nil)
            }
            if oldValue.modules.stayAwakeEnabled && !preferences.modules.stayAwakeEnabled {
                KeepAwakeManager.shared.endSession(reason: nil, notify: false)
            }
            preferences.save()
        }
    }

    // MARK: - Computed Properties

    /// Whether the search results list drives selection (pinned global search or typed query).
    var isSearchingWithQuery: Bool {
        presentationMode == .workspace && workspaceMode == .globalWindowSearch
            || (isSearchActive && !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Search results when searching - includes both apps and specific windows
    var searchResults: [SearchResult] {
        return FuzzyMatcher.search(searchableApplications, query: searchQuery)
    }

    /// Selected search result
    var selectedSearchResult: SearchResult? {
        guard searchResults.indices.contains(selectedSearchIndex) else { return nil }
        return searchResults[selectedSearchIndex]
    }

    var selectedApp: ApplicationModel? {
        if presentationMode == .nativePreview && !hasNativeSelection {
            return nil
        }

        if isSearchingWithQuery {
            return selectedSearchResult?.app ?? searchResults.first?.app
        }
        // Otherwise use the app grid
        return appAtSelectedIndex(in: filteredApplications)
    }

    private var searchableApplications: [ApplicationModel] {
        guard presentationMode == .workspace,
              workspaceMode == .globalWindowSearch,
              workspaceSearchScope == .currentApp,
              let currentApp = currentWorkspaceApp else {
            return applications
        }

        return [currentApp]
    }

    var currentWorkspaceApp: ApplicationModel? {
        if let workspaceFrontmostPID,
           let app = applications.first(where: { $0.pid == workspaceFrontmostPID }) {
            return app
        }

        return appAtSelectedIndex(in: applications)
    }

    private func appAtSelectedIndex(in applications: [ApplicationModel]) -> ApplicationModel? {
        if applications.indices.contains(selectedAppIndex) {
            return applications[selectedAppIndex]
        }

        return applications.first
    }

    private func handleWindowEnumerationPreferenceChange(from oldPreferences: UserPreferences) {
        let affectsWindowEnumeration = oldPreferences.showAllSpaces != preferences.showAllSpaces
            || oldPreferences.showMinimizedWindows != preferences.showMinimizedWindows
            || oldPreferences.excludedBundleIDs != preferences.excludedBundleIDs

        guard affectsWindowEnumeration else { return }

        WindowCache.shared.invalidate()

        if isVisible, presentationMode == .workspace {
            let selectedPID = selectedApp?.pid
            let refreshedApplications = WindowCache.shared.getApplicationsSync(forceRefresh: true)
            reconcileApplications(
                refreshedApplications,
                selectedPID: selectedPID,
                preserveCurrentSelection: true
            )
        } else {
            WindowCache.shared.prefetchAsync()
        }
    }

    var filteredApplications: [ApplicationModel] {
        if presentationMode == .workspace,
           workspaceMode == .currentAppWindows,
           let currentWorkspaceApp {
            return [currentWorkspaceApp]
        }

        guard !searchQuery.isEmpty else { return applications }
        return FuzzyMatcher.filter(applications, query: searchQuery)
    }

    var isNativeTraversalSnapshotActive: Bool {
        nativeTraversalSnapshot != nil
    }

    var currentNativePreviewGeneration: UInt64? {
        isNativeTraversalSnapshotActive ? nativeSelectionGeneration : nil
    }

    var hasNativePlacementAnchor: Bool {
        guard let nativeSelectedItemFrame,
              let nativeSwitcherFrame else {
            return false
        }

        return nativeSelectedItemFrame.width > 1
            && nativeSelectedItemFrame.height > 1
            && nativeSwitcherFrame.width > 1
            && nativeSwitcherFrame.height > 1
    }

    func previewRequestGeneration(for mode: SwitcherPresentationMode) -> UInt64? {
        mode == .nativePreview ? currentNativePreviewGeneration : nil
    }

    func setWindowPreview(_ update: WindowPreviewUpdate) {
        guard isVisible else {
            print("[AppState][preview] dropped preview while switcher hidden for windowID=\(update.windowID) pid=\(update.ownerPID.map(String.init) ?? "unknown")")
            return
        }

        var bestMatch: (appIndex: Int, windowIndex: Int, score: Int)?

        for appIndex in applications.indices {
            if let ownerPID = update.ownerPID, applications[appIndex].pid != ownerPID {
                continue
            }

            for windowIndex in applications[appIndex].windows.indices {
                let window = applications[appIndex].windows[windowIndex]
                guard let score = previewMatchScore(update: update, for: window) else { continue }

                if let currentBest = bestMatch {
                    if score > currentBest.score {
                        bestMatch = (appIndex, windowIndex, score)
                    }
                } else {
                    bestMatch = (appIndex, windowIndex, score)
                }
            }
        }

        guard let match = bestMatch else {
            print("[AppState][preview] dropped preview; no matching windowID=\(update.windowID) pid=\(update.ownerPID.map(String.init) ?? "unknown")")
            return
        }

        var updatedApplications = applications
        updatedApplications[match.appIndex].windows[match.windowIndex].previewImage = update.image
        applications = updatedApplications
        print("[AppState][preview] applied preview for windowID=\(update.windowID) pid=\(update.ownerPID.map(String.init) ?? "unknown")")
    }

    private func previewMatchScore(update: WindowPreviewUpdate, for window: WindowModel) -> Int? {
        let updateIdentity = update.previewIdentity
        let windowIdentity = window.previewIdentity
        guard windowIdentity.matches(updateIdentity) else { return nil }

        if windowIdentity.hasReliableCGWindowID,
           updateIdentity.hasReliableCGWindowID,
           windowIdentity.cgWindowID != 0,
           windowIdentity.cgWindowID == updateIdentity.cgWindowID {
            return 100
        }

        if let windowAxIndex = windowIdentity.axIndex,
           let updateAxIndex = updateIdentity.axIndex,
           windowAxIndex == updateAxIndex {
            return 50
        }

        return 10
    }

    // MARK: - Navigation Methods

    /// Call this when keyboard navigation is used
    func markKeyboardNavigation() {
        isKeyboardNavigating = true
    }

    /// Call this when mouse moves to re-enable hover
    /// Only marks mouse navigation if the mouse has actually moved from its last position
    func markMouseNavigation(at position: CGPoint? = nil) {
        // If position provided, check if mouse actually moved
        if let position = position {
            if let lastPos = lastMousePosition {
                // Only consider it a move if position changed by more than 2 pixels
                let dx = abs(position.x - lastPos.x)
                let dy = abs(position.y - lastPos.y)
                if dx > 2 || dy > 2 {
                    hasMouseMoved = true
                    isKeyboardNavigating = false
                    lastMousePosition = position
                }
            } else {
                // First position recorded, don't count as movement yet
                lastMousePosition = position
            }
        } else {
            // No position provided, only enable if mouse has already moved
            if hasMouseMoved {
                isKeyboardNavigating = false
            }
        }
    }

    /// Check if mouse input should be processed (mouse has moved since panel appeared)
    var shouldProcessMouseInput: Bool {
        return hasMouseMoved && !isKeyboardNavigating
    }

    func prepareForPresentation(_ mode: SwitcherPresentationMode) {
        presentationMode = mode
        isVisible = true
        hasMouseMoved = false
        isKeyboardNavigating = false
        lastMousePosition = nil
        nativeSelectedItemFrame = nil
        nativeSwitcherFrame = nil
        if mode == .nativePreview {
            hasNativeSelection = false
        }

        if mode == .nativePreview {
            isSearchActive = false
            searchQuery = ""
            selectedSearchIndex = 0
            isResourceMonitorActive = false
            isUnusedWindowsActive = false
            stopResourcePolling()
            stopWorkspaceWindowListRefreshTimer()
        } else if workspaceMode == .currentAppWindows {
            refreshWorkspaceWindowsForSelectedApp(forceRefresh: false)
            startWorkspaceWindowListRefreshTimer()
        }
    }

    func beginWorkspaceWindowSession(
        snapshot: [ApplicationModel],
        frontmostPID: pid_t?,
        visible: Bool,
        initialWindowIndex: Int?
    ) {
        workspaceSessionSnapshot = snapshot
        workspaceFrontmostPID = frontmostPID
        applications = snapshot
        presentationMode = .workspace
        workspaceMode = .currentAppWindows
        workspaceSearchScope = .allWindows
        isSearchActive = false
        searchQuery = ""
        selectedSearchIndex = 0
        isResourceMonitorActive = false
        isUnusedWindowsActive = false
        stopResourcePolling()

        if let frontmostPID,
           let appIndex = applications.firstIndex(where: { $0.pid == frontmostPID }) {
            selectedAppIndex = appIndex
        } else {
            selectedAppIndex = 0
        }

        if let selectedApp,
           let initialWindowIndex,
           selectedApp.windows.indices.contains(initialWindowIndex),
           !selectedApp.windows[initialWindowIndex].isWindowlessPlaceholder {
            selectedWindowIndex = initialWindowIndex
        } else if let selectedApp,
                  let firstRealWindowIndex = selectedApp.windows.indices.first(where: { !selectedApp.windows[$0].isWindowlessPlaceholder }) {
            selectedWindowIndex = firstRealWindowIndex
        } else {
            selectedWindowIndex = 0
        }

        if visible {
            prepareForPresentation(.workspace)
        } else {
            isVisible = false
        }
    }

    func refreshWorkspaceWindowsForSelectedApp(forceRefresh: Bool = false) {
        guard presentationMode == .workspace,
              workspaceMode == .currentAppWindows,
              let selectedPID = selectedApp?.pid,
              let appIndex = applications.firstIndex(where: { $0.pid == selectedPID }),
              let freshApp = WindowCache.shared.getApplicationsForWorkspaceSwitching(forceRefresh: forceRefresh)
                .first(where: { $0.pid == selectedPID }) else {
            return
        }

        let existingWindows = applications[appIndex].windows
        let existingCarouselIDs = Set(existingWindows.map(\.carouselItemID))

        var mergedWindows = WindowModel.mergedPreservingPreviews(
            fresh: freshApp.windows,
            existing: existingWindows
        )

        // Newly opened windows must not inherit a sibling's cached thumbnail.
        for windowIndex in mergedWindows.indices {
            let carouselID = mergedWindows[windowIndex].carouselItemID
            guard !existingCarouselIDs.contains(carouselID) else { continue }
            mergedWindows[windowIndex].previewImage = nil
        }

        let mergedCarouselIDs = Set(mergedWindows.map(\.carouselItemID))
        let existingOpenCount = existingWindows.filter { !$0.isWindowlessPlaceholder }.count
        let mergedOpenCount = mergedWindows.filter { !$0.isWindowlessPlaceholder }.count

        guard existingCarouselIDs != mergedCarouselIDs || existingOpenCount != mergedOpenCount else { return }

        let previousWindow = existingWindows.indices.contains(selectedWindowIndex)
            ? existingWindows[selectedWindowIndex]
            : nil

        var updatedApplications = applications
        var updatedApp = freshApp
        updatedApp.windows = mergedWindows
        updatedApplications[appIndex] = updatedApp
        applications = updatedApplications

        requestWorkspacePreviews(for: updatedApp)

        if let previousWindow,
           let matchingIndex = mergedWindows.firstIndex(where: { window in
               window.previewIdentity.matches(previousWindow.previewIdentity)
           }) {
            selectedWindowIndex = matchingIndex
            return
        }

        if let firstRealIndex = mergedWindows.indices.first(where: { index in
            !mergedWindows[index].isWindowlessPlaceholder
        }) {
            selectedWindowIndex = firstRealIndex
        } else {
            selectedWindowIndex = 0
        }
    }

    private func requestWorkspacePreviews(for app: ApplicationModel) {
        let selectedIndex = selectedWindowIndex
        let neighborIndices = [selectedIndex - 1, selectedIndex, selectedIndex + 1]
            .filter { app.windows.indices.contains($0) }

        let windowsNeedingPreview = neighborIndices.compactMap { index -> WindowModel? in
            let window = app.windows[index]
            guard !window.isWindowlessPlaceholder,
                  !WindowEnumerator.shouldSuppressFinderPreview(for: window),
                  window.previewImage == nil,
                  window.canCapturePreview else {
                return nil
            }
            return window
        }
        guard !windowsNeedingPreview.isEmpty else { return }

        WindowPreviewService.shared.requestPreviews(
            for: windowsNeedingPreview,
            ownerPID: app.pid,
            appName: app.name
        )
    }

    private func refreshWorkspaceWindowsIfNeeded() {
        guard presentationMode == .workspace, workspaceMode == .currentAppWindows else { return }
        refreshWorkspaceWindowsForSelectedApp()
    }

    func startWorkspaceWindowListRefreshTimerIfNeeded() {
        guard presentationMode == .workspace, workspaceMode == .currentAppWindows, isVisible else { return }
        startWorkspaceWindowListRefreshTimer()
    }

    private func startWorkspaceWindowListRefreshTimer() {
        workspaceWindowListRefreshTimer?.cancel()
        workspaceWindowListRefreshTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.isVisible,
                      self.presentationMode == .workspace,
                      self.workspaceMode == .currentAppWindows else {
                    self.stopWorkspaceWindowListRefreshTimer()
                    return
                }
                self.refreshWorkspaceWindowsForSelectedApp(forceRefresh: false)
            }
    }

    private func stopWorkspaceWindowListRefreshTimer() {
        workspaceWindowListRefreshTimer?.cancel()
        workspaceWindowListRefreshTimer = nil
    }

    /// Re-enumerate the selected app using workspace-style window discovery before native previews.
    /// Cmd+Tab keeps a frozen all-spaces snapshot; apps like Messages need live on-screen geometry/titles.
    func refreshNativeWindowsForSelectedApp(forceRefresh: Bool = true) {
        guard presentationMode == .nativePreview,
              let selectedPID = selectedApp?.pid,
              let appIndex = applications.firstIndex(where: { $0.pid == selectedPID }),
              let freshApp = WindowCache.shared.getApplicationsForWorkspaceSwitching(forceRefresh: forceRefresh)
                .first(where: { $0.pid == selectedPID }) else {
            return
        }

        let normalizedFresh = WindowEnumerator.normalizeFinderApplicationIfNeeded(freshApp)
        let existingWindows = applications[appIndex].windows
        var mergedWindows = WindowModel.mergedPreservingPreviews(
            fresh: normalizedFresh.windows,
            existing: existingWindows
        )

        for windowIndex in mergedWindows.indices {
            if mergedWindows[windowIndex].isWindowlessPlaceholder
                || WindowEnumerator.shouldSuppressFinderPreview(for: mergedWindows[windowIndex]) {
                mergedWindows[windowIndex].previewImage = nil
            }
        }

        mergedWindows = WindowEnumerator.normalizeFinderApplicationIfNeeded(
            ApplicationModel(
                pid: normalizedFresh.pid,
                bundleIdentifier: normalizedFresh.bundleIdentifier,
                name: normalizedFresh.name,
                icon: normalizedFresh.icon,
                windows: mergedWindows,
                isActive: normalizedFresh.isActive
            )
        ).windows

        guard nativeWindowListNeedsRefresh(existing: existingWindows, merged: mergedWindows) else {
            return
        }

        let previousWindow = existingWindows.indices.contains(selectedWindowIndex)
            ? existingWindows[selectedWindowIndex]
            : nil

        var updatedApplications = applications
        updatedApplications[appIndex].windows = mergedWindows
        applications = updatedApplications
        nativeTraversalSnapshot = applications

        if let previousWindow,
           let matchingIndex = mergedWindows.firstIndex(where: { window in
               window.previewIdentity.matches(previousWindow.previewIdentity)
           }) {
            selectedWindowIndex = matchingIndex
            return
        }

        if let firstRealIndex = mergedWindows.indices.first(where: { index in
            !mergedWindows[index].isWindowlessPlaceholder
        }) {
            selectedWindowIndex = firstRealIndex
        } else {
            selectedWindowIndex = 0
        }
    }

    private func nativeWindowListNeedsRefresh(existing: [WindowModel], merged: [WindowModel]) -> Bool {
        if Set(existing.map(\.carouselItemID)) != Set(merged.map(\.carouselItemID)) {
            return true
        }

        for window in merged where !window.isWindowlessPlaceholder {
            guard let existingWindow = existing.first(where: { $0.previewIdentity.matches(window.previewIdentity) }) else {
                return true
            }

            if existingWindow.title != window.title
                || existingWindow.bounds != window.bounds
                || existingWindow.windowID != window.windowID
                || existingWindow.isMinimized != window.isMinimized {
                return true
            }
        }

        return false
    }

    func pinWorkspaceSearch() {
        workspaceMode = .globalWindowSearch
        workspaceSearchScope = .allWindows
        isSearchActive = true
        searchQuery = ""
        selectedSearchIndex = 0
        isVisible = true
    }

    func setWorkspaceSearchScope(_ scope: WorkspaceSearchScope) {
        workspaceSearchScope = scope
        selectedSearchIndex = 0
    }

    func beginNativePreviewSession(_ snapshot: [ApplicationModel]) {
        advanceNativeSelectionGeneration(clearAnchor: true)
        latestLiveMRUApplications = snapshot
        nativeTraversalSnapshot = snapshot
        applications = snapshot
        prepareForPresentation(.nativePreview)
        selectedAppIndex = 0
        selectedWindowIndex = 0
    }

    func beginNativeTraversalSnapshot(_ snapshot: [ApplicationModel], reverse: Bool) {
        advanceNativeSelectionGeneration(clearAnchor: true)
        latestLiveMRUApplications = snapshot
        nativeTraversalSnapshot = snapshot
        applications = snapshot
        prepareForPresentation(.nativePreview)

        if snapshot.isEmpty {
            selectedAppIndex = 0
        } else if reverse {
            selectedAppIndex = max(snapshot.count - 1, 0)
        } else {
            selectedAppIndex = snapshot.count > 1 ? 1 : 0
        }
        selectedWindowIndex = 0
    }

    func endNativeTraversalSnapshot() {
        advanceNativeSelectionGeneration(clearAnchor: true)
        nativeTraversalSnapshot = nil
        nativeSelectedItemFrame = nil
        nativeSwitcherFrame = nil
    }

    @discardableResult
    func selectNativeApplication(
        pid: pid_t?,
        bundleIdentifier: String?,
        title: String?,
        anchorFrame: CGRect?,
        switcherFrame: CGRect?,
        resolvedApplication: ApplicationModel? = nil
    ) -> Bool {
        if let resolvedApplication {
            upsertNativeApplication(resolvedApplication)
        }

        guard let index = indexOfApplication(pid: pid, bundleIdentifier: bundleIdentifier, title: title) else {
            print("[AppState] Could not resolve native Cmd+Tab selection pid=\(pid.map(String.init) ?? "unknown") bundle=\(bundleIdentifier ?? "unknown") title=\(title ?? "unknown")")
            return false
        }

        if let anchorFrame, anchorFrame.width > 1, anchorFrame.height > 1 {
            nativeSelectedItemFrame = normalizedNativeAnchorFrame(anchorFrame)
        }
        // Keep the previous item anchor when Dock AX briefly omits frames mid-hop.
        // Clearing here forces hasNativePlacementAnchor=false and hides the preview panel.

        if let switcherFrame, switcherFrame.width > 1, switcherFrame.height > 1 {
            nativeSwitcherFrame = normalizedNativeAnchorFrame(switcherFrame)
        }
        // Same sticky behavior for the Dock switcher strip frame.

        let previousSelectedAppPID = selectedApp?.pid
        selectedAppIndex = index
        hasNativeSelection = true
        if previousSelectedAppPID != selectedApp?.pid {
            advanceNativeSelectionGeneration(clearAnchor: false)
            selectedWindowIndex = 0
        }
        return true
    }

    func selectedNativeWindowSelection() -> (app: ApplicationModel, window: WindowModel, index: Int)? {
        guard presentationMode == .nativePreview,
              let app = selectedApp,
              app.windows.indices.contains(selectedWindowIndex) else {
            return nil
        }

        return (app, app.windows[selectedWindowIndex], selectedWindowIndex)
    }

    private func advanceNativeSelectionGeneration(clearAnchor: Bool) {
        nativeSelectionGeneration &+= 1
        if clearAnchor {
            nativeSelectedItemFrame = nil
            nativeSwitcherFrame = nil
        }
    }

    private func upsertNativeApplication(_ app: ApplicationModel) {
        let app = WindowEnumerator.normalizeFinderApplicationIfNeeded(app)

        if let index = applications.firstIndex(where: { $0.pid == app.pid || $0.bundleIdentifier == app.bundleIdentifier }) {
            var mergedApplication = app
            for windowIndex in mergedApplication.windows.indices {
                let window = mergedApplication.windows[windowIndex]
                if window.isWindowlessPlaceholder
                    || WindowEnumerator.shouldSuppressFinderPreview(for: window) {
                    mergedApplication.windows[windowIndex].previewImage = nil
                    continue
                }

                guard mergedApplication.windows[windowIndex].previewImage == nil else { continue }

                let identity = mergedApplication.windows[windowIndex].previewIdentity
                if let existingWindow = applications[index].windows.first(where: {
                    !$0.isWindowlessPlaceholder && $0.previewIdentity.matches(identity)
                }),
                   let previewImage = existingWindow.previewImage,
                   !WindowEnumerator.shouldSuppressFinderPreview(for: existingWindow) {
                    mergedApplication.windows[windowIndex].previewImage = previewImage
                }
            }
            mergedApplication = WindowEnumerator.normalizeFinderApplicationIfNeeded(mergedApplication)
            applications[index] = mergedApplication
        } else {
            applications.append(app)
        }
        nativeTraversalSnapshot = applications
    }

    func hydrateCachedPreviews(for pid: pid_t) {
        guard let appIndex = applications.firstIndex(where: { $0.pid == pid }) else { return }

        var app = applications[appIndex]
        var didUpdate = false

        for windowIndex in app.windows.indices {
            guard app.windows[windowIndex].previewImage == nil else { continue }
            guard !app.windows[windowIndex].isWindowlessPlaceholder else { continue }
            guard !WindowEnumerator.shouldSuppressFinderPreview(for: app.windows[windowIndex]) else { continue }

            if let image = WindowPreviewService.shared.cachedPreview(for: app.windows[windowIndex].previewIdentity) {
                app.windows[windowIndex].previewImage = image
                didUpdate = true
            }
        }

        guard didUpdate else { return }

        applications[appIndex] = app
        nativeTraversalSnapshot = applications
    }

    private func normalizedNativeAnchorFrame(_ frame: CGRect) -> CGRect {
        let candidates = nativeAnchorCandidates(for: frame)
        guard let bestCandidate = candidates.min(by: { lhs, rhs in lhs.score < rhs.score }) else {
            return frame
        }

        return bestCandidate.frame
    }

    private func nativeAnchorCandidates(for frame: CGRect) -> [(frame: CGRect, score: CGFloat)] {
        var candidates: [(CGRect, CGFloat)] = []

        for screen in NSScreen.screens {
            let rawScore = nativeAnchorScore(frame, on: screen)
            if rawScore < .greatestFiniteMagnitude {
                candidates.append((frame, rawScore))
            }

            let flippedFrame = CGRect(
                x: frame.origin.x,
                y: screen.frame.maxY - (frame.origin.y - screen.frame.minY) - frame.height,
                width: frame.width,
                height: frame.height
            )
            let flippedScore = nativeAnchorScore(flippedFrame, on: screen)
            if flippedScore < .greatestFiniteMagnitude {
                candidates.append((flippedFrame, flippedScore))
            }
        }

        return candidates
    }

    private func nativeAnchorScore(_ frame: CGRect, on screen: NSScreen) -> CGFloat {
        guard frame.width > 1, frame.height > 1 else { return .greatestFiniteMagnitude }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard screen.frame.contains(center) else { return .greatestFiniteMagnitude }

        let normalizedHorizontalDistance = abs(center.x - screen.frame.midX) / max(screen.frame.width, 1)
        let normalizedVerticalDistance = abs(center.y - screen.frame.midY) / max(screen.frame.height, 1)
        return normalizedHorizontalDistance + normalizedVerticalDistance
    }

    private func indexOfApplication(pid: pid_t?, bundleIdentifier: String?, title: String?) -> Int? {
        if let pid, let index = filteredApplications.firstIndex(where: { $0.pid == pid }) {
            return index
        }

        if let bundleIdentifier,
           let index = filteredApplications.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return index
        }

        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }

        let normalizedTitle = normalizedPreviewTitle(title)
        if let index = filteredApplications.firstIndex(where: { normalizedPreviewTitle($0.name) == normalizedTitle }) {
            return index
        }

        return filteredApplications.firstIndex { app in
            let appName = normalizedPreviewTitle(app.name)
            return !appName.isEmpty && (normalizedTitle.contains(appName) || appName.contains(normalizedTitle))
        }
    }

    private func normalizedPreviewTitle(_ title: String) -> String {
        PreviewIdentity.normalizedTitle(title)
    }

    func reconcileApplications(
        _ newApplications: [ApplicationModel],
        selectedPID: pid_t?,
        preserveCurrentSelection: Bool = false
    ) {
        latestLiveMRUApplications = newApplications

        guard !isNativeTraversalSnapshotActive else {
            print("[AppState] Ignored live MRU reorder while native Cmd+Tab snapshot is frozen")
            return
        }

        if presentationMode == .workspace, workspaceSessionSnapshot != nil {
            print("[AppState] Ignored live MRU reorder while WindowLens workspace snapshot is frozen")
            return
        }

        let previousSelectedPID = selectedApp?.pid
        let targetPID = preserveCurrentSelection ? previousSelectedPID : selectedPID
        let previousWindowIndex = selectedWindowIndex

        applications = newApplications

        if let targetPID,
           let targetIndex = filteredApplications.firstIndex(where: { $0.pid == targetPID }) {
            selectedAppIndex = targetIndex
        } else {
            selectedAppIndex = min(selectedAppIndex, max(filteredApplications.count - 1, 0))
        }

        if preserveCurrentSelection,
           let selectedApp,
           selectedApp.windows.indices.contains(previousWindowIndex) {
            selectedWindowIndex = previousWindowIndex
        } else {
            selectedWindowIndex = 0
        }

        if isSearchingWithQuery {
            selectedSearchIndex = min(selectedSearchIndex, max(searchResults.count - 1, 0))
        }
    }

    func selectNextApp() {
        markKeyboardNavigation()
        if isSearchingWithQuery {
            let count = searchResults.count
            guard count > 0 else { return }
            selectedSearchIndex = (selectedSearchIndex + 1) % count
            if let result = selectedSearchResult, let windowIndex = result.targetWindowIndex {
                selectedWindowIndex = windowIndex
            } else {
                selectedWindowIndex = 0
            }
        } else {
            let count = filteredApplications.count
            guard count > 0 else { return }
            if isNativeTraversalSnapshotActive {
                advanceNativeSelectionGeneration(clearAnchor: false)
                hasNativeSelection = true
            }
            selectedAppIndex = (selectedAppIndex + 1) % count
            selectedWindowIndex = 0
        }
    }

    func selectPreviousApp() {
        markKeyboardNavigation()
        if isSearchingWithQuery {
            let count = searchResults.count
            guard count > 0 else { return }
            selectedSearchIndex = (selectedSearchIndex - 1 + count) % count
            if let result = selectedSearchResult, let windowIndex = result.targetWindowIndex {
                selectedWindowIndex = windowIndex
            } else {
                selectedWindowIndex = 0
            }
        } else {
            let count = filteredApplications.count
            guard count > 0 else { return }
            if isNativeTraversalSnapshotActive {
                advanceNativeSelectionGeneration(clearAnchor: false)
                hasNativeSelection = true
            }
            selectedAppIndex = (selectedAppIndex - 1 + count) % count
            selectedWindowIndex = 0
        }
    }

    func selectNextWindow() {
        markKeyboardNavigation()
        refreshWorkspaceWindowsIfNeeded()
        guard let app = selectedApp else { return }
        let indices = selectableWindowIndices(in: app)
        let count = indices.count
        guard count > 0 else { return }
        guard let currentPosition = indices.firstIndex(of: selectedWindowIndex) else {
            selectedWindowIndex = indices[0]
            return
        }
        selectedWindowIndex = indices[(currentPosition + 1) % count]
    }

    func selectPreviousWindow() {
        markKeyboardNavigation()
        refreshWorkspaceWindowsIfNeeded()
        guard let app = selectedApp else { return }
        let indices = selectableWindowIndices(in: app)
        let count = indices.count
        guard count > 0 else { return }
        guard let currentPosition = indices.firstIndex(of: selectedWindowIndex) else {
            selectedWindowIndex = indices[0]
            return
        }
        selectedWindowIndex = indices[(currentPosition - 1 + count) % count]
    }

    private func selectableWindowIndices(in app: ApplicationModel) -> [Int] {
        let realWindowIndices = app.windows.indices.filter { !app.windows[$0].isWindowlessPlaceholder }
        if !realWindowIndices.isEmpty {
            return realWindowIndices
        }
        return Array(app.windows.indices)
    }

    /// Move selection to the row above in the grid
    func selectAppInRowAbove() {
        markKeyboardNavigation()
        let count = filteredApplications.count
        guard count > 0 else { return }

        let itemsPerRow = calculateItemsPerRow()
        let newIndex = selectedAppIndex - itemsPerRow

        if newIndex >= 0 {
            if isNativeTraversalSnapshotActive {
                advanceNativeSelectionGeneration(clearAnchor: false)
                hasNativeSelection = true
            }
            selectedAppIndex = newIndex
            selectedWindowIndex = 0
        }
    }

    /// Move selection to the row below in the grid
    func selectAppInRowBelow() {
        markKeyboardNavigation()
        let count = filteredApplications.count
        guard count > 0 else { return }

        let itemsPerRow = calculateItemsPerRow()
        let newIndex = selectedAppIndex + itemsPerRow

        if newIndex < count {
            if isNativeTraversalSnapshotActive {
                advanceNativeSelectionGeneration(clearAnchor: false)
                hasNativeSelection = true
            }
            selectedAppIndex = newIndex
            selectedWindowIndex = 0
        } else {
            let lastIndex = count - 1
            if selectedAppIndex != lastIndex {
                if isNativeTraversalSnapshotActive {
                    advanceNativeSelectionGeneration(clearAnchor: false)
                    hasNativeSelection = true
                }
                selectedAppIndex = lastIndex
                selectedWindowIndex = 0
            }
        }
    }

    private func calculateItemsPerRow() -> Int {
        let appCount = filteredApplications.count
        let itemWidth: CGFloat = 82

        let idealItemsPerRow = min(appCount, 8)
        let baseWidth = CGFloat(idealItemsPerRow) * 92 + 32
        let contentWidth = min(max(baseWidth, 400), 750) - 32

        return max(1, Int(contentWidth / itemWidth))
    }

    // MARK: - Resource Monitor Methods

    func toggleResourceMonitor() {
        isUnusedWindowsActive = false
        isResourceMonitorActive.toggle()
        if isResourceMonitorActive {
            startResourcePolling()
        } else {
            stopResourcePolling()
        }
    }

    func toggleUnusedWindows() {
        isUnusedWindowsActive.toggle()
        if isUnusedWindowsActive {
            isResourceMonitorActive = false
            stopResourcePolling()
        }
    }

    private func startResourcePolling() {
        // Prime the CPU delta sampler (need fresh baseline for accurate %)
        ProcessResourceMonitor.shared.resetSamples()
        // Keep cpuHistory/memoryHistory across toggles so the graph persists
        hasRequestedInsight = false

        // Quick reachability check (non-blocking, 2s timeout)
        // Used to show the right hint text; hold-E will start Ollama regardless
        Task {
            let available = await OllamaClient.shared.isAvailable()
            await MainActor.run { self.ollamaAvailable = available }
        }

        // Initial "priming" fetch; CPU% will be 0 on first call (no delta yet)
        refreshResourceData()

        // Poll every 1.5 seconds for smooth updates
        resourceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshResourceData()
            }
        }
    }

    private func stopResourcePolling() {
        resourceTimer?.invalidate()
        resourceTimer = nil
        resourceEntries = []
        systemMemory = nil
        systemCPU = nil
        cpuTemperature = nil
        // Intentionally keep cpuHistory & memoryHistory; 960 bytes in RAM,
        // lets the graph show prior context when reopened.
        aiInsightCooldownTimer?.invalidate()
        aiInsightCooldownTimer = nil
        hasRequestedInsight = false
        ProcessResourceMonitor.shared.resetSamples()

        // Kill Ollama if we started it; don't leave it running
        Task { await OllamaClient.shared.shutdownIfWeStarted() }
    }

    private func refreshResourceData() {
        let monitor = ProcessResourceMonitor.shared
        resourceEntries = monitor.systemSnapshot()
        systemMemory = monitor.systemMemory()
        systemCPU = monitor.systemCPU()

        // Temperature: exact °C on Intel, thermal state fallback on Apple Silicon
        let thermal = monitor.thermalInfo()
        cpuTemperature = thermal.temperature
        thermalState = thermal.state

        // Append to history
        if let cpu = systemCPU {
            cpuHistory.append(cpu.usagePercent)
            if cpuHistory.count > maxHistoryPoints {
                cpuHistory.removeFirst(cpuHistory.count - maxHistoryPoints)
            }
        }
        if let mem = systemMemory {
            memoryHistory.append(mem.usedFraction * 100)
            if memoryHistory.count > maxHistoryPoints {
                memoryHistory.removeFirst(memoryHistory.count - maxHistoryPoints)
            }
        }

    }

    // MARK: - AI Insight (Hold E)

    /// Called when user holds E; starts Ollama if needed, queries, then shuts down.
    func requestAIInsightWithOllama() {
        guard !aiInsightLoading else { return }

        // Ensure resource monitor is showing
        if !isResourceMonitorActive {
            isResourceMonitorActive = true
            startResourcePolling()
        }

        aiInsightLoading = true

        Task {
            // Start Ollama if not running (will track if we started it)
            let ready = await OllamaClient.shared.ensureRunning()
            await MainActor.run { self.ollamaAvailable = ready }

            guard ready else {
                await MainActor.run {
                    self.aiInsightLoading = false
                    self.aiInsight = "Could not start Ollama. Install from ollama.com"
                }
                return
            }

            // Wait for at least 2 data points if we don't have them yet
            for _ in 0..<6 {
                let count = await MainActor.run { self.cpuHistory.count }
                if count >= 2 { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            let snapshot = await MainActor.run { self.buildSnapshot() }
            let result = await OllamaClient.shared.summarizeProcesses(snapshot)

            await MainActor.run {
                self.setAIInsight(result ?? "No response from model")
                self.aiInsightLoading = false
            }
        }
    }

    /// Manually refresh the AI insight (e.g. user taps refresh button)
    func refreshAIInsight() {
        guard ollamaAvailable, !aiInsightLoading else { return }
        aiInsightLoading = true
        let snapshot = buildSnapshot()
        Task {
            let result = await OllamaClient.shared.summarizeProcesses(snapshot)
            await MainActor.run {
                self.setAIInsight(result)
                self.aiInsightLoading = false
            }
        }
    }

    /// Set the AI insight and start the cooldown timer to auto-clear it
    private func setAIInsight(_ text: String?) {
        aiInsightCooldownTimer?.invalidate()
        aiInsight = text

        guard text != nil else { return }
        aiInsightCooldownTimer = Timer.scheduledTimer(withTimeInterval: aiInsightCooldown, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.aiInsight = nil
            }
        }
    }

    private func buildSnapshot() -> ProcessSnapshot {
        ProcessSnapshot(
            processes: resourceEntries.prefix(8).map { entry in
                ProcessSnapshot.Process(
                    name: entry.name,
                    cpuPercent: entry.cpuPercent,
                    memMB: Int(entry.memoryBytes / (1024 * 1024))
                )
            },
            cpuUsagePercent: Int(systemCPU?.usagePercent ?? 0),
            memUsedGB: systemMemory?.formattedUsed ?? "?",
            memTotalGB: systemMemory?.formattedTotal ?? "?",
            tempC: cpuTemperature
        )
    }

    // MARK: - E Hold Methods (Charging Animation)

    func startEHold() {
        guard !isEHoldActive else { return }
        isEHoldActive = true
        eHoldProgress = 0.0
        eHoldStartTime = Date()

        eHoldTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateEHoldProgress()
            }
        }
    }

    func cancelEHold(triggeredAI: Bool) {
        eHoldTimer?.invalidate()
        eHoldTimer = nil
        eHoldStartTime = nil

        if triggeredAI {
            // Keep progress full briefly to show completion
            eHoldProgress = 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.isEHoldActive = false
                self?.eHoldProgress = 0.0
            }
        } else {
            isEHoldActive = false
            eHoldProgress = 0.0
        }
    }

    private func updateEHoldProgress() {
        guard let start = eHoldStartTime else { return }
        let elapsed = Date().timeIntervalSince(start)
        eHoldProgress = min(CGFloat(elapsed / eHoldAnimationDuration), 1.0)
    }

    // MARK: - Quit Hold Methods

    func startQuitHold() {
        guard selectedApp != nil else { return }
        isQuitHoldActive = true
        quitHoldProgress = 0.0
        quitTargetAppIndex = selectedAppIndex
        quitHoldStartTime = Date()

        quitHoldTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateQuitHoldProgress()
            }
        }
    }

    func cancelQuitHold() {
        quitHoldTimer?.invalidate()
        quitHoldTimer = nil
        quitHoldStartTime = nil
        isQuitHoldActive = false
        quitHoldProgress = 0.0
        quitTargetAppIndex = nil
    }

    private func updateQuitHoldProgress() {
        guard let startTime = quitHoldStartTime else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let fraction = min(elapsed / quitHoldDuration, 1.0)
        quitHoldProgress = CGFloat(fraction)

        if fraction >= 1.0 {
            executeQuit()
        }
    }

    private func executeQuit() {
        quitHoldTimer?.invalidate()
        quitHoldTimer = nil

        guard let app = selectedApp else {
            cancelQuitHold()
            return
        }

        if let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).first {
            runningApp.terminate()
            print("[AppState] Quit app: \(app.name)")
        }

        if let index = applications.firstIndex(where: { $0.pid == app.pid }) {
            applications.remove(at: index)
            if selectedAppIndex >= applications.count {
                selectedAppIndex = max(0, applications.count - 1)
            }
        }

        isQuitHoldActive = false
        quitHoldProgress = 0.0
        quitTargetAppIndex = nil
        quitHoldStartTime = nil
    }

    func clearPreviewImages(reason: String) {
        guard !isVisible else {
            print("[AppState] Skipped preview image clearing while switcher is visible: \(reason)")
            return
        }

        applications = applications.strippingPreviewImages()
        nativeTraversalSnapshot = nativeTraversalSnapshot?.strippingPreviewImages()
        workspaceSessionSnapshot = workspaceSessionSnapshot?.strippingPreviewImages()
        latestLiveMRUApplications = latestLiveMRUApplications.strippingPreviewImages()

        print("[AppState] Preview image references cleared: \(reason)")
    }

    func reset() {
        cancelEHold(triggeredAI: false)
        cancelQuitHold()
        stopResourcePolling()
        stopWorkspaceWindowListRefreshTimer()
        advanceNativeSelectionGeneration(clearAnchor: true)
        isVisible = false
        presentationMode = .workspace
        nativeTraversalSnapshot = nil
        workspaceSessionSnapshot = nil
        workspaceFrontmostPID = nil
        workspaceMode = .currentAppWindows
        workspaceSearchScope = .allWindows
        hasNativeSelection = false
        selectedAppIndex = 0
        selectedWindowIndex = 0
        selectedSearchIndex = 0
        isSearchActive = false
        searchQuery = ""
        isKeyboardNavigating = false
        hasMouseMoved = false
        lastMousePosition = nil
        isResourceMonitorActive = false
        isUnusedWindowsActive = false
    }

    private init() {}
}

private extension Array where Element == ApplicationModel {
    func strippingPreviewImages() -> [ApplicationModel] {
        var strippedApplications = self

        for appIndex in strippedApplications.indices {
            for windowIndex in strippedApplications[appIndex].windows.indices {
                strippedApplications[appIndex].windows[windowIndex].previewImage = nil
            }
        }

        return strippedApplications
    }
}
