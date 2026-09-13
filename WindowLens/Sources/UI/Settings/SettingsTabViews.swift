import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $appState.preferences.launchAtLogin)
            }

            Section("Interaction Systems") {
                KeyboardShortcutRow(
                    title: "Native preview sync",
                    shortcut: "⌘ TAB"
                )
                KeyboardShortcutRow(
                    title: "Workspace mode",
                    shortcut: appState.preferences.shortcuts.workspaceOpen.displayString
                )

                Text("Command-Tab remains native. Your workspace shortcut opens WindowLens with focused navigation and search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Quit Hold Duration") {
                HStack {
                    Text(String(format: "%.1fs", appState.preferences.quitHoldDuration))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)

                    Slider(value: $appState.preferences.quitHoldDuration, in: 0.5...5.0, step: 0.5)
                }

                Text("How long to hold Q in the switcher to quit an app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Windows") {
                Toggle("Show windows from all Spaces", isOn: $appState.preferences.showAllSpaces)
                Toggle("Show minimized windows", isOn: $appState.preferences.showMinimizedWindows)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

struct ShortcutSettingsView: View {
    @EnvironmentObject var appState: AppState

    private var shortcuts: ShortcutPreferences {
        appState.preferences.shortcuts
    }

    var body: some View {
        Form {
            Section("Window History") {
                KeyboardShortcutRow(
                    title: "Back to previous window",
                    shortcut: shortcuts.windowHistoryBack.displayString
                )
                KeyboardShortcutRow(
                    title: "Forward in history",
                    shortcut: shortcuts.windowHistoryForward.displayString
                )
                Text("WindowLens remembers your last 10 window visits. Change these in Features.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Window Slots") {
                KeyboardShortcutRow(
                    title: "Jump to slot 1-9",
                    shortcut: shortcuts.windowSlotDisplayString
                )
                Text("Works globally, even when the switcher is closed. Passed through when a terminal is frontmost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Usage Heatmap") {
                KeyboardShortcutRow(
                    title: "Open heatmap",
                    shortcut: shortcuts.usageHeatmapOpen.displayString
                )
                Text("Works globally when the switcher is closed. Change this in Features.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Stay Awake") {
                KeyboardShortcutRow(
                    title: "Toggle Stay Awake",
                    shortcut: shortcuts.stayAwakeToggle.displayString
                )
                Text("Works globally when the switcher is closed. Change this in Features.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("While Switcher is Open") {
                KeyboardShortcutRow(title: "Next application", shortcut: "TAB")
                KeyboardShortcutRow(title: "Previous application", shortcut: "⇧ TAB")
                KeyboardShortcutRow(title: "Next window", shortcut: "`")
                KeyboardShortcutRow(title: "Previous window", shortcut: "⇧ `")
                KeyboardShortcutRow(title: "Quit app", shortcut: "Hold Q")
                KeyboardShortcutRow(title: "Search", shortcut: "Return")
                KeyboardShortcutRow(
                    title: "Toggle resource monitor",
                    shortcut: shortcuts.resourceMonitorToggle.displayString
                )
                KeyboardShortcutRow(title: "Confirm", shortcut: "Release modifier")
                KeyboardShortcutRow(title: "Cancel", shortcut: "Escape")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shortcuts")
    }
}

struct KeyboardShortcutRow: View {
    let title: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(shortcut)
                .foregroundStyle(.secondary)
                .font(.system(.body, design: .monospaced))
        }
    }
}

struct ExcludedAppsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var runningApps: [(name: String, bundleID: String, icon: NSImage)] = []

    var body: some View {
        Form {
            Section {
                ForEach(runningApps, id: \.bundleID) { app in
                    let isExcluded = appState.preferences.excludedBundleIDs.contains(app.bundleID)
                    HStack(spacing: 10) {
                        Image(nsImage: app.icon)
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(app.name)
                            .lineLimit(1)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { isExcluded },
                            set: { exclude in
                                if exclude {
                                    appState.preferences.excludedBundleIDs.append(app.bundleID)
                                } else {
                                    appState.preferences.excludedBundleIDs.removeAll { $0 == app.bundleID }
                                }
                                WindowCache.shared.invalidate()
                                WindowCache.shared.prefetchAsync()
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            } footer: {
                Text("Excluded apps will not appear in the switcher.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Excluded Apps")
        .onAppear {
            loadRunningApps()
        }
    }

    private func loadRunningApps() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app -> (name: String, bundleID: String, icon: NSImage)? in
                guard let name = app.localizedName,
                      let bundleID = app.bundleIdentifier else { return nil }
                let icon = app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
                return (name: name, bundleID: bundleID, icon: icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        var result = apps
        for bundleID in appState.preferences.excludedBundleIDs {
            if !result.contains(where: { $0.bundleID == bundleID }) {
                let name = bundleID.components(separatedBy: ".").last ?? bundleID
                result.append((name: name, bundleID: bundleID, icon: NSImage(named: NSImage.applicationIconName) ?? NSImage()))
            }
        }

        runningApps = result
    }
}

struct WindowSlotsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var registry = WindowNumberRegistry.shared
    @State private var assignmentSelection: SlotAssignmentSelection?

    private var slotPrefix: String {
        appState.preferences.shortcuts.windowSlotModifier.symbol
    }

    var body: some View {
        Form {
            Section {
                ForEach(1...9, id: \.self) { slot in
                    WindowSlotSettingsRow(
                        slot: slot,
                        slotPrefix: slotPrefix,
                        assignment: registry.assignment(for: slot),
                        onAssign: { assignmentSelection = SlotAssignmentSelection(slot: slot) },
                        onClear: { registry.clearSlot(slot) }
                    )
                }
            } footer: {
                Text("Slots auto-fill from recent windows at launch. Use Assign to pick any open window for a slot.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Window Slots")
        .sheet(item: $assignmentSelection) { selection in
            WindowSlotAssignmentSheet(slot: selection.slot)
        }
    }
}

private struct SlotAssignmentSelection: Identifiable {
    let slot: Int
    var id: Int { slot }
}

private struct WindowSlotSettingsRow: View {
    let slot: Int
    let slotPrefix: String
    let assignment: WindowAssignment?
    let onAssign: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(slotPrefix)\(slot)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)

            if let assignment, assignment.isAlive {
                if let runningApp = NSRunningApplication(processIdentifier: assignment.pid),
                   let icon = runningApp.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app")
                        .frame(width: 20, height: 20)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(assignment.appName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(assignment.windowTitle.isEmpty ? "Untitled window" : assignment.windowTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button("Reassign") {
                    onAssign()
                }
                .buttonStyle(.borderless)

                Button("Clear", role: .destructive) {
                    onClear()
                }
                .buttonStyle(.borderless)
            } else {
                Text("Vacant")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)

                Spacer()

                Button("Assign") {
                    onAssign()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .opacity(assignment?.isAlive == true ? 1 : 0.72)
    }
}

struct AboutView: View {
    @ObservedObject private var updates = SoftwareUpdateController.shared
    @State private var crashSummary: String?
    @State private var copyConfirmation: String?
    @State private var copyError: String?

    var body: some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    Image("AboutLogo")
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 72)

                    Text("WindowLens")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Version \(updates.currentVersionString)")
                        .foregroundStyle(.secondary)

                    Text("macOS window switching and native Cmd-Tab preview augmentation")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }

            if case .updateAvailable(let version) = updates.status {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Update available", systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text("WindowLens \(version) is ready to install. Your settings and shortcuts are kept across updates.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Download Update…") {
                            updates.checkForUpdates()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!updates.canCheckForUpdates)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Updates") {
                statusRow

                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticallyChecksForUpdates($0) }
                    )
                )

                Button("Check for Updates…") {
                    updates.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)
            }

            Section {
                Text(crashSummary.map { "Latest: \($0)" } ?? "No crash reports found")
                    .foregroundStyle(.secondary)

                Button("Copy Latest Crash Report") {
                    copyLatestCrashReport()
                }
                .disabled(crashSummary == nil)

                if let copyConfirmation {
                    Text(copyConfirmation)
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                if let copyError {
                    Text(copyError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Button("Show in Finder") {
                    CrashReportStore.revealLatestInFinder()
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Reports stay on this Mac until you share them.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
        .onAppear {
            refreshCrashSummary()
        }
    }

    private func refreshCrashSummary() {
        crashSummary = CrashReportStore.latestReportSummary()
    }

    private func copyLatestCrashReport() {
        copyConfirmation = nil
        copyError = nil
        do {
            try CrashReportStore.copyLatestReportToPasteboard()
            copyConfirmation = "Copied"
            refreshCrashSummary()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if copyConfirmation == "Copied" {
                    copyConfirmation = nil
                }
            }
        } catch {
            copyError = error.localizedDescription
        }
    }

    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(updates.status.title)
                    .font(.body.weight(.medium))

                if case .failed(let message) = updates.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else if let checked = updates.lastCheckedDescription {
                    Text("Last checked \(checked)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusSymbol: String {
        switch updates.status {
        case .waitingForFirstCheck: return "clock"
        case .checking: return "arrow.triangle.2.circlepath"
        case .upToDate: return "checkmark.circle.fill"
        case .updateAvailable: return "arrow.down.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch updates.status {
        case .waitingForFirstCheck, .checking: return .secondary
        case .upToDate: return .green
        case .updateAvailable: return .orange
        case .failed: return .orange
        }
    }
}
