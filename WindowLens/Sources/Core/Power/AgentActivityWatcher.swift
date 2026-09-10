import AppKit
import ApplicationServices
import Darwin
import Foundation

/// A detected AI agent / host app that may be keeping work alive.
struct ActiveAgent: Identifiable, Equatable {
    let id: String
    let displayName: String
    let bundleIdentifier: String?
    let statusHint: String
    let activeSince: Date
    let pid: pid_t
    /// When true, Stay Awake should hold sleep for this agent.
    let isBusy: Bool

    var elapsedDescription: String {
        let elapsed = max(0, Int(Date().timeIntervalSince(activeSince)))
        let mins = elapsed / 60
        let secs = elapsed % 60
        if mins >= 60 {
            let hours = mins / 60
            let rem = mins % 60
            return String(format: "%dh %02dm", hours, rem)
        }
        return String(format: "%dm %02ds", mins, secs)
    }

    static func == (lhs: ActiveAgent, rhs: ActiveAgent) -> Bool {
        lhs.id == rhs.id
            && lhs.displayName == rhs.displayName
            && lhs.statusHint == rhs.statusHint
            && lhs.pid == rhs.pid
            && lhs.isBusy == rhs.isBusy
    }
}

/// Lightweight multi-agent activity detector.
/// IDE hosts like Cursor are detected via helper-tree CPU and UI status text — not merely “app is open”.
@MainActor
final class AgentActivityWatcher: ObservableObject {
    static let shared = AgentActivityWatcher()

    @Published private(set) var isAnyAgentActive = false
    @Published private(set) var activeAgents: [ActiveAgent] = []
    @Published private(set) var activeAgentNames: [String] = []

    private var timer: Timer?
    private var workingUntil: Date?
    private var previousCPU: [pid_t: (time: UInt64, stamp: CFAbsoluteTime)] = [:]
    private var firstSeen: [String: Date] = [:]
    private var lastUIStatus: [String: (text: String, stamp: Date)] = [:]

    private struct HostSpec {
        let bundleID: String
        let pathHints: [String]
        /// Main-process CPU alone is unreliable for Electron; tree CPU matters more.
        let treeBusyThreshold: Double
        /// When true, scrape AX / window titles for live agent status strings.
        let readsUIStatus: Bool
    }

    private let hosts: [HostSpec] = [
        HostSpec(
            bundleID: "com.todesktop.230313mzl4w4u92",
            pathHints: ["Cursor.app", "Cursor Helper"],
            treeBusyThreshold: 4,
            readsUIStatus: true
        ),
        HostSpec(
            bundleID: "com.microsoft.VSCode",
            pathHints: ["Visual Studio Code.app", "Code Helper"],
            treeBusyThreshold: 5,
            readsUIStatus: false
        ),
        HostSpec(
            bundleID: "com.microsoft.VSCodeInsiders",
            pathHints: ["Visual Studio Code - Insiders.app", "Code - Insiders Helper"],
            treeBusyThreshold: 5,
            readsUIStatus: false
        ),
        HostSpec(
            bundleID: "com.openai.chat",
            pathHints: ["ChatGPT.app"],
            treeBusyThreshold: 3,
            readsUIStatus: false
        ),
        HostSpec(
            bundleID: "com.anthropic.claudefordesktop",
            pathHints: ["Claude.app"],
            treeBusyThreshold: 3,
            readsUIStatus: false
        ),
        HostSpec(
            bundleID: "com.github.CopilotForXcode",
            pathHints: ["Copilot"],
            treeBusyThreshold: 3,
            readsUIStatus: false
        ),
    ]

    /// Hold sleep briefly between tool-call CPU spikes — not after transcript turns end.
    private let debounceSeconds: TimeInterval = 25
    private let cliCPUBusyThreshold = 3.0
    private let uiStatusCacheSeconds: TimeInterval = 8

    /// Set each sample: transcript open-turn busy vs CPU/UI/CLI heuristic busy.
    private var lastSampleHadTranscriptBusy = false
    private var lastSampleHadHeuristicBusy = false
    private var wasTranscriptBusy = false
    /// Require two idle transcript samples before treating Cursor turns as finished
    /// (partial JSONL tails can briefly look idle mid-write).
    private var consecutiveTranscriptIdleSamples = 0

    private init() {}

    func start() {
        if timer == nil {
            let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.tick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        // Always scan immediately so enabling mid-session picks up an in-progress agent.
        tick()
    }

    /// Force a fresh sample (e.g. when Stay Awake switches to “Until AI agents finish”).
    func scanNow() {
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isAnyAgentActive = false
        activeAgents = []
        activeAgentNames = []
        workingUntil = nil
        previousCPU.removeAll()
        firstSeen.removeAll()
        lastUIStatus.removeAll()
        lastSampleHadTranscriptBusy = false
        lastSampleHadHeuristicBusy = false
        wasTranscriptBusy = false
        consecutiveTranscriptIdleSamples = 0
    }

    func icon(for agent: ActiveAgent) -> NSImage? {
        if agent.pid > 0,
           let app = NSRunningApplication(processIdentifier: agent.pid),
           let icon = app.icon {
            return icon
        }
        if let bid = agent.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    private func tick() {
        let sample = sampleAgents()
        let busyHits = sample.filter(\.isBusy)

        // Debounce only covers CPU/UI/CLI gaps between tool calls.
        if lastSampleHadHeuristicBusy {
            workingUntil = Date().addingTimeInterval(debounceSeconds)
        }
        // Cursor abort/finish writes turn_ended — drop any leftover hold immediately.
        if wasTranscriptBusy, !lastSampleHadTranscriptBusy, !lastSampleHadHeuristicBusy {
            workingUntil = nil
        }
        wasTranscriptBusy = lastSampleHadTranscriptBusy

        let inDebounce = workingUntil.map { Date() < $0 } ?? false
        // Keep hold through one missed transcript sample so mid-write JSONL tails don't drop sleep.
        isAnyAgentActive = !busyHits.isEmpty || inDebounce || lastSampleHadTranscriptBusy

        var display = busyHits
        if display.isEmpty, (inDebounce || lastSampleHadTranscriptBusy), !activeAgents.isEmpty {
            display = activeAgents.map { previous in
                ActiveAgent(
                    id: previous.id,
                    displayName: previous.displayName,
                    bundleIdentifier: previous.bundleIdentifier,
                    statusHint: "Between steps…",
                    activeSince: firstSeen[previous.id] ?? previous.activeSince,
                    pid: previous.pid,
                    isBusy: true
                )
            }
        }

        let ids = Set(display.map(\.id))
        firstSeen = firstSeen.filter { ids.contains($0.key) }
        for agent in display where firstSeen[agent.id] == nil {
            // Prefer transcript turn start so enabling mid-session shows real elapsed time.
            firstSeen[agent.id] = agent.activeSince
        }

        activeAgents = display.map { agent in
            ActiveAgent(
                id: agent.id,
                displayName: agent.displayName,
                bundleIdentifier: agent.bundleIdentifier,
                statusHint: agent.statusHint,
                activeSince: firstSeen[agent.id] ?? agent.activeSince,
                pid: agent.pid,
                isBusy: agent.isBusy
            )
        }
        activeAgentNames = activeAgents.map(\.displayName)

        if !isAnyAgentActive {
            workingUntil = nil
        }
    }

    private func sampleAgents() -> [ActiveAgent] {
        var agents: [ActiveAgent] = []
        let processSnapshot = Self.listAllProcesses()
        var transcriptBusy = false
        var heuristicBusy = false

        for host in hosts {
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == host.bundleID && !$0.isTerminated
            }) else { continue }

            let treeCPU = treeCPU(for: host, appPID: app.processIdentifier, processes: processSnapshot)
            let openTurns = host.bundleID == "com.todesktop.230313mzl4w4u92"
                ? Self.probeAllCursorOpenTurns()
                : []
            let uiStatus = host.readsUIStatus
                ? cachedUIStatus(for: host.bundleID, pid: app.processIdentifier)
                : nil
            let busyFromCPU = treeCPU >= host.treeBusyThreshold
            let busyFromUI = uiStatus.map { Self.uiStatusImpliesBusy($0) } ?? false
            let busyFromTranscript = !openTurns.isEmpty

            if busyFromTranscript { transcriptBusy = true }
            if busyFromCPU || busyFromUI { heuristicBusy = true }

            if !openTurns.isEmpty {
                // One card per in-progress Cursor chat / subagent turn.
                for turn in openTurns {
                    agents.append(
                        ActiveAgent(
                            id: turn.id,
                            displayName: turn.displayName,
                            bundleIdentifier: host.bundleID,
                            statusHint: turn.statusHint,
                            activeSince: turn.activeSince,
                            pid: app.processIdentifier,
                            isBusy: true
                        )
                    )
                }
                continue
            }

            let busy = busyFromCPU || busyFromUI
            guard busy else { continue }

            let label = app.localizedName ?? host.bundleID
            let hint: String
            if let uiStatus, Self.uiStatusImpliesBusy(uiStatus) {
                hint = uiStatus
            } else {
                hint = statusHint(forCPU: treeCPU, kind: .ide)
            }

            agents.append(
                ActiveAgent(
                    id: "app:\(host.bundleID)",
                    displayName: label,
                    bundleIdentifier: host.bundleID,
                    statusHint: hint,
                    activeSince: Date(),
                    pid: app.processIdentifier,
                    isBusy: true
                )
            )
        }

        for entry in processSnapshot where Self.isCLIAgentName(entry.baseName) {
            let cpu = cpuPercent(for: entry.pid)
            let busy = cpu >= cliCPUBusyThreshold
            guard busy else { continue }
            heuristicBusy = true
            agents.append(
                ActiveAgent(
                    id: "cli:\(entry.baseName):\(entry.pid)",
                    displayName: Self.prettyCLIName(entry.baseName),
                    bundleIdentifier: Self.bundleHint(forCLI: entry.baseName),
                    statusHint: statusHint(forCPU: cpu, kind: .cli),
                    activeSince: Date(),
                    pid: entry.pid,
                    isBusy: true
                )
            )
        }

        if transcriptBusy {
            consecutiveTranscriptIdleSamples = 0
            lastSampleHadTranscriptBusy = true
        } else {
            consecutiveTranscriptIdleSamples += 1
            // Hold transcript-busy for one extra tick after the last open turn disappears.
            lastSampleHadTranscriptBusy = consecutiveTranscriptIdleSamples < 2 && wasTranscriptBusy
        }
        lastSampleHadHeuristicBusy = heuristicBusy

        var seen = Set<String>()
        return agents.filter { seen.insert($0.id).inserted }
            .sorted {
                if $0.isBusy != $1.isBusy { return $0.isBusy && !$1.isBusy }
                if $0.activeSince != $1.activeSince { return $0.activeSince < $1.activeSince }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    private func treeCPU(for host: HostSpec, appPID: pid_t, processes: [ProcEntry]) -> Double {
        var total = cpuPercent(for: appPID)
        for entry in processes {
            let pathMatch = host.pathHints.contains { hint in
                entry.path.localizedCaseInsensitiveContains(hint)
            }
            guard pathMatch, entry.pid != appPID else { continue }
            total += cpuPercent(for: entry.pid)
        }
        return total
    }

    private enum AgentKind { case ide, cli }

    private func statusHint(forCPU cpu: Double, kind: AgentKind) -> String {
        if cpu >= 35 { return kind == .cli ? "Running tools" : "Heavy agent work" }
        if cpu >= 10 { return "Working…" }
        if cpu >= 4 { return "Agent activity" }
        return "Active"
    }

    // MARK: - Cursor transcript probe
    // Cursor agent turns often sit near-idle on CPU while waiting on the model.
    // Open agent-transcript jsonl files (no trailing turn_ended) are a reliable busy signal.

    private struct CursorTranscriptHit {
        let id: String
        let displayName: String
        let statusHint: String
        let activeSince: Date
        let mtime: Date
    }

    /// Every in-progress Cursor chat / subagent turn under ~/.cursor/projects.
    private static func probeAllCursorOpenTurns() -> [CursorTranscriptHit] {
        let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/projects", isDirectory: true)
        guard FileManager.default.fileExists(atPath: projectsRoot.path) else { return [] }

        let maxAge: TimeInterval = 3 * 60 * 60 // ignore stale abandoned turns
        let cutoff = Date().addingTimeInterval(-maxAge)
        var hits: [CursorTranscriptHit] = []

        let projectDirs = (try? FileManager.default.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for projectDir in projectDirs {
            let transcriptsRoot = projectDir.appendingPathComponent("agent-transcripts", isDirectory: true)
            guard FileManager.default.fileExists(atPath: transcriptsRoot.path) else { continue }

            guard let enumerator = FileManager.default.enumerator(
                at: transcriptsRoot,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            let projectLabel = friendlyProjectLabel(from: projectDir.lastPathComponent)

            while let item = enumerator.nextObject() as? URL {
                guard item.pathExtension == "jsonl" else { continue }

                let values = try? item.resourceValues(forKeys: [
                    .contentModificationDateKey, .isRegularFileKey, .fileSizeKey,
                ])
                guard values?.isRegularFile == true,
                      let mtime = values?.contentModificationDate,
                      mtime >= cutoff,
                      (values?.fileSize ?? 0) > 0 else { continue }

                guard let openTurn = readOpenTurn(from: item) else { continue }

                let isSubagent = item.path.contains("/subagents/")
                let shortID = String(item.deletingPathExtension().lastPathComponent.prefix(8))
                let displayName: String
                if isSubagent {
                    displayName = "Cursor subagent · \(shortID)"
                } else if projectLabel.isEmpty {
                    displayName = "Cursor · \(shortID)"
                } else {
                    displayName = "Cursor · \(projectLabel)"
                }

                // Stable id from path so concurrent chats don't collapse together.
                let relative = item.path.replacingOccurrences(of: projectsRoot.path + "/", with: "")
                hits.append(
                    CursorTranscriptHit(
                        id: "cursor-turn:\(relative)",
                        displayName: displayName,
                        statusHint: openTurn.hint,
                        activeSince: openTurn.startedAt,
                        mtime: mtime
                    )
                )
            }
        }

        // Disambiguate multiple chats that share a display name (same project / subagent label).
        var indicesByName: [String: [Int]] = [:]
        for (index, hit) in hits.enumerated() {
            indicesByName[hit.displayName, default: []].append(index)
        }
        for (_, indices) in indicesByName where indices.count > 1 {
            for index in indices {
                let hit = hits[index]
                let uuidPart = hit.id.split(separator: "/").last?
                    .replacingOccurrences(of: ".jsonl", with: "")
                    .prefix(8) ?? "agent"
                hits[index] = CursorTranscriptHit(
                    id: hit.id,
                    displayName: "\(hit.displayName) · \(uuidPart)",
                    statusHint: hit.statusHint,
                    activeSince: hit.activeSince,
                    mtime: hit.mtime
                )
            }
        }

        return hits.sorted { $0.mtime > $1.mtime }
    }

    private static func friendlyProjectLabel(from folderName: String) -> String {
        // "Users-chakshu-Code-WindowLens" → "WindowLens"
        let parts = folderName.split(separator: "-")
        if let last = parts.last, last.count >= 2 {
            return String(last)
        }
        return folderName
    }

    private struct OpenTurn {
        let hint: String
        let startedAt: Date
    }

    /// Returns stage + start time for an in-progress turn (last *parsed* line is not turn_ended).
    private static func readOpenTurn(from url: URL) -> OpenTurn? {
        guard let text = readTailText(of: url, maxBytes: 48_000) else { return nil }
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // Use the last successfully decoded JSON line — a partial trailing write must not
        // make an open turn look finished.
        var lastPayload: [String: Any]?
        var lastPayloadIndex: Int?
        for (idx, line) in lines.enumerated().reversed() {
            if let payload = decodeJSONObject(line) {
                lastPayload = payload
                lastPayloadIndex = idx
                break
            }
        }
        guard let lastPayload, let lastPayloadIndex else { return nil }
        if (lastPayload["type"] as? String) == "turn_ended" {
            return nil
        }

        let hint = statusHint(fromTranscriptPayload: lastPayload, fileURL: url)

        // Walk back to the start of this open turn (first event after prior turn_ended).
        var turnStartIndex = 0
        for idx in stride(from: lastPayloadIndex, through: 0, by: -1) {
            guard let payload = decodeJSONObject(lines[idx]) else { continue }
            if (payload["type"] as? String) == "turn_ended" {
                turnStartIndex = idx + 1
                break
            }
        }

        var startedAt: Date?
        if turnStartIndex < lines.count {
            for line in lines[turnStartIndex...] {
                guard let payload = decodeJSONObject(line),
                      (payload["role"] as? String) == "user",
                      let message = payload["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]],
                      let text = content.compactMap({ $0["text"] as? String }).first,
                      let parsed = parseEmbeddedTimestamp(in: text) else {
                    continue
                }
                startedAt = parsed
                break
            }
        }

        if startedAt == nil {
            startedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }

        return OpenTurn(hint: hint, startedAt: min(startedAt ?? Date(), Date()))
    }

    private static func parseEmbeddedTimestamp(in raw: String) -> Date? {
        guard let start = raw.range(of: "<timestamp>"),
              let end = raw.range(of: "</timestamp>", range: start.upperBound..<raw.endIndex) else {
            return nil
        }
        let stamp = raw[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // "Monday, Sep 7, 2026, 7:12 PM (UTC-7)" → strip zone, parse local wall time.
        let trimmed = stamp.replacingOccurrences(
            of: #"\s*\(UTC[^)]*\)\s*$"#,
            with: "",
            options: .regularExpression
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMM d, yyyy, h:mm a"
        return formatter.date(from: trimmed)
    }

    private static func statusHint(fromTranscriptPayload payload: [String: Any], fileURL: URL) -> String {
        let isSubagent = fileURL.path.contains("/subagents/")
        let role = payload["role"] as? String

        if role == "assistant", let message = payload["message"] as? [String: Any] {
            let content = message["content"] as? [[String: Any]] ?? []
            let toolNames = content.compactMap { block -> String? in
                guard (block["type"] as? String) == "tool_use" else { return nil }
                return block["name"] as? String
            }
            if !toolNames.isEmpty {
                return stageLabel(forTools: toolNames, isSubagent: isSubagent)
            }
            // Streaming assistant text — show stage, not the draft reply.
            return isSubagent ? "Subagent working…" : "Working…"
        }

        if role == "user" {
            // Open turn waiting on the model — never echo the user prompt.
            return isSubagent ? "Subagent thinking…" : "Thinking…"
        }

        return isSubagent ? "Subagent working…" : "Working…"
    }

    private static func stageLabel(forTools toolNames: [String], isSubagent: Bool) -> String {
        let lower = toolNames.map { $0.lowercased() }
        if lower.contains(where: { $0.contains("await") }) {
            return "Waiting…"
        }
        if lower.contains("task") {
            return "Waiting for subagent"
        }
        if lower.contains(where: { $0.contains("shell") || $0.contains("bash") || $0.contains("terminal") }) {
            return "Running terminal"
        }
        if lower.contains(where: { $0.contains("edit") || $0.contains("write") || $0.contains("replace") }) {
            return "Editing files"
        }
        if lower.contains(where: { $0.contains("read") || $0.contains("grep") || $0.contains("glob") || $0.contains("search") }) {
            return "Reading code"
        }
        if lower.contains(where: { $0.contains("browser") || $0.contains("web") }) {
            return "Browsing"
        }
        if isSubagent {
            return "Subagent running tools"
        }
        if toolNames.count == 1, let only = toolNames.first {
            return truncateStatus("Running \(only)")
        }
        return "Running tools"
    }

    private static func readTailText(of url: URL, maxBytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return nil }

        let window = min(size, maxBytes)
        let offset = size - window
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.readToEnd(), !data.isEmpty else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func decodeJSONObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    // MARK: - UI status (Cursor / Electron AX + window titles)

    private func cachedUIStatus(for bundleID: String, pid: pid_t) -> String? {
        if let cached = lastUIStatus[bundleID],
           Date().timeIntervalSince(cached.stamp) < uiStatusCacheSeconds {
            return cached.text
        }
        let text = Self.probeUIStatus(pid: pid)
        if let text, !text.isEmpty {
            lastUIStatus[bundleID] = (text, Date())
            return text
        }
        // Keep a short stale status so brief AX misses don't flicker.
        if let cached = lastUIStatus[bundleID],
           Date().timeIntervalSince(cached.stamp) < 20 {
            return cached.text
        }
        return nil
    }

    /// Prefer concrete agent/status strings over generic chrome.
    private static func uiStatusImpliesBusy(_ text: String) -> Bool {
        let lower = text.lowercased()
        let idleMarkers = [
            "ready when you are",
            "ask anything",
            "plan, search, build",
            "what do you want to",
            "start a new chat",
            "no agent",
            "agents idle",
        ]
        if idleMarkers.contains(where: { lower.contains($0) }) {
            return false
        }

        // Only explicit agent-activity phrases — not arbitrary sidebar chrome.
        let busyMarkers = [
            "waiting for",
            "subagent",
            "generating",
            "thinking",
            "exploring",
            "planning next",
            "running tool",
            "tool call",
            "calling tool",
            "reading file",
            "editing file",
            "searching codebase",
            "agent mode",
            "cloud agent",
            "background agent",
            "in progress",
            "streaming",
            "working…",
            "working...",
        ]
        return busyMarkers.contains(where: { lower.contains($0) })
    }

    private static func probeUIStatus(pid: pid_t) -> String? {
        if let fromWindows = bestWindowTitleStatus(pid: pid) {
            return fromWindows
        }
        return bestAccessibilityStatus(pid: pid)
    }

    private static func bestWindowTitleStatus(pid: pid_t) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var candidates: [String] = []
        for entry in info {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let title = entry[kCGWindowName as String] as? String else { continue }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if uiStatusImpliesBusy(trimmed) {
                candidates.append(trimmed)
            }
        }
        return pickBestStatus(from: candidates)
    }

    private static func bestAccessibilityStatus(pid: pid_t) -> String? {
        let axApp = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, true as CFTypeRef)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        var candidates: [String] = []
        var nodesVisited = 0
        let nodeBudget = 220

        for window in windows.prefix(4) {
            collectStatusTexts(
                from: window,
                depth: 0,
                maxDepth: 8,
                nodesVisited: &nodesVisited,
                nodeBudget: nodeBudget,
                into: &candidates
            )
            if nodesVisited >= nodeBudget { break }
        }

        return pickBestStatus(from: candidates)
    }

    private static func collectStatusTexts(
        from element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        nodesVisited: inout Int,
        nodeBudget: Int,
        into candidates: inout [String]
    ) {
        guard depth <= maxDepth, nodesVisited < nodeBudget else { return }
        nodesVisited += 1

        if let title = stringAttribute(kAXTitleAttribute, from: element) {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if uiStatusImpliesBusy(trimmed) {
                candidates.append(trimmed)
            }
        }
        if let value = stringAttribute(kAXValueAttribute, from: element) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count <= 100, uiStatusImpliesBusy(trimmed) {
                candidates.append(trimmed)
            }
        }
        if let desc = stringAttribute(kAXDescriptionAttribute, from: element) {
            let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count <= 100, uiStatusImpliesBusy(trimmed) {
                candidates.append(trimmed)
            }
        }

        guard let children = elementArrayAttribute(kAXChildrenAttribute, from: element) else { return }
        for child in children.prefix(24) {
            collectStatusTexts(
                from: child,
                depth: depth + 1,
                maxDepth: maxDepth,
                nodesVisited: &nodesVisited,
                nodeBudget: nodeBudget,
                into: &candidates
            )
            if nodesVisited >= nodeBudget { return }
        }
    }

    private static func pickBestStatus(from candidates: [String]) -> String? {
        guard !candidates.isEmpty else { return nil }

        let ranked = candidates
            .map { ($0, statusRank($0)) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.count < rhs.0.count
            }

        guard let best = ranked.first, best.1 > 0 else { return nil }
        return truncateStatus(best.0)
    }

    private static func statusRank(_ text: String) -> Int {
        let lower = text.lowercased()
        if lower.contains("waiting for") || lower.contains("subagent") { return 100 }
        if lower.contains("generating") || lower.contains("thinking") { return 90 }
        if lower.contains("exploring") || lower.contains("planning next") { return 80 }
        if lower.contains("agent mode") || lower.contains("cloud agent") { return 70 }
        if lower.contains("tool") || lower.contains("editing file") || lower.contains("searching") { return 60 }
        if lower.contains("working") || lower.contains("streaming") || lower.contains("in progress") { return 50 }
        return 10
    }

    private static func truncateStatus(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 72 { return trimmed }
        let index = trimmed.index(trimmed.startIndex, offsetBy: 69)
        return String(trimmed[..<index]) + "…"
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func elementArrayAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }

    private static func isCLIAgentName(_ base: String) -> Bool {
        base == "claude" || base == "codex" || base == "aider"
            || base == "ollama" || base == "gemini" || base.hasPrefix("copilot")
            || base == "cursor-agent"
    }

    private static func prettyCLIName(_ base: String) -> String {
        switch base {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "aider": return "Aider"
        case "ollama": return "Ollama"
        case "gemini": return "Gemini CLI"
        case "cursor-agent": return "Cursor Agent"
        default:
            if base.hasPrefix("copilot") { return "Copilot" }
            return base.capitalized
        }
    }

    private static func bundleHint(forCLI base: String) -> String? {
        switch base {
        case "claude": return "com.anthropic.claudefordesktop"
        case "codex": return "com.openai.chat"
        case "cursor-agent": return "com.todesktop.230313mzl4w4u92"
        default: return nil
        }
    }

    private func cpuPercent(for pid: pid_t) -> Double {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard result == size else { return 0 }

        let total = info.pti_total_user + info.pti_total_system
        let now = CFAbsoluteTimeGetCurrent()
        defer { previousCPU[pid] = (total, now) }

        guard let prev = previousCPU[pid] else { return 0 }
        let dt = now - prev.stamp
        guard dt > 0.2 else { return 0 }
        let delta = total &- prev.time
        return Double(delta) / (dt * 1_000_000_000.0) * 100.0
    }

    private struct ProcEntry {
        let pid: pid_t
        let path: String
        var baseName: String { (path as NSString).lastPathComponent.lowercased() }
    }

    private static func listAllProcesses() -> [ProcEntry] {
        var count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.stride + 16)
        count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(MemoryLayout<pid_t>.stride * pids.count))
        let n = Int(count) / MemoryLayout<pid_t>.stride

        var result: [ProcEntry] = []
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))

        for i in 0..<n {
            let pid = pids[i]
            guard pid > 0 else { continue }
            let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard pathLen > 0 else { continue }
            let path = String(decoding: pathBuffer.prefix(Int(pathLen)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result.append(ProcEntry(pid: pid, path: path))
        }
        return result
    }
}
