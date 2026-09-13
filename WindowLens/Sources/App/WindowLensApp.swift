import AppKit
import SwiftUI

@main
struct WindowLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    @ObservedObject private var updates = SoftwareUpdateController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            MenuBarIconLabel()
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updates.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)
            }
        }
    }
}

struct MenuBarIconLabel: View {
    @ObservedObject private var keepAwake = KeepAwakeManager.shared
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var updates = SoftwareUpdateController.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if keepAwake.isActive, appState.preferences.modules.stayAwakeEnabled {
                    Image(systemName: menuSymbol)
                        .symbolRenderingMode(.monochrome)
                } else if let icon = Self.templateMenuBarImage() {
                    Image(nsImage: icon)
                        .renderingMode(.template)
                } else {
                    Image(systemName: "rectangle.on.rectangle")
                }
            }

            if updates.updateAvailable {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .offset(x: 2, y: -1)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(updates.updateAvailable ? "WindowLens, update available" : "WindowLens")
    }

    private var menuSymbol: String {
        if keepAwake.isPausedForHeat { return "thermometer.medium" }
        if keepAwake.activeDuration == .whileAgentsActive {
            return keepAwake.activeDuration?.symbolName ?? "brain.head.profile"
        }
        if let duration = keepAwake.activeDuration {
            return duration.symbolName
        }
        if keepAwake.lidClosedStayAwakeEnabled { return "laptopcomputer" }
        return "cup.and.saucer.fill"
    }

    private static func templateMenuBarImage() -> NSImage? {
        guard let image = NSImage(named: "MenuBarIcon")?.copy() as? NSImage else {
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var visitHistory = WindowVisitHistory.shared
    @ObservedObject private var updates = SoftwareUpdateController.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let version = updates.availableUpdateVersion {
                updateBanner(version: version)
            }

            if appState.preferences.modules.stayAwakeEnabled {
                StayAwakeControlsView(compact: true, showsChrome: true)
            }

            recentWindowsSection

            footerActions
        }
        .padding(14)
        .frame(width: 340)
        // Critical for MenuBarExtra(.window): size to content instead of collapsing.
        .fixedSize(horizontal: true, vertical: true)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("WindowLens")
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 8)
            Text(appState.preferences.shortcuts.workspaceOpen.displayString)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }

    private func updateBanner(version: String) -> some View {
        MenuBarHoverButton {
            updates.checkForUpdates()
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available")
                        .font(.system(size: 12, weight: .semibold))
                    Text("WindowLens \(version)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var recentWindowsSection: some View {
        let recentVisits = visitHistory.recentVisitsForMenu(limit: 5)
        if !recentVisits.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 8)

                ForEach(recentVisits) { visit in
                    MenuBarHoverButton {
                        visitHistory.jumpToVisit(visit)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            if let icon = Self.appIcon(for: visit) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 16, height: 16)
                                    .cornerRadius(3)
                            }
                            Text(visit.menuLabel)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private var footerActions: some View {
        VStack(spacing: 2) {
            footerButton("Settings…", systemImage: "gearshape") {
                NotificationCenter.default.post(name: .openSettings, object: nil)
                dismiss()
            }
            footerButton("Permissions", systemImage: "lock.shield") {
                NotificationCenter.default.post(name: .openPermissions, object: nil)
                dismiss()
            }
            footerButton("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") {
                updates.checkForUpdates()
                dismiss()
            }
            footerButton("Reinstall Event Tap", systemImage: "keyboard") {
                NotificationCenter.default.post(name: .reinstallEventTap, object: nil)
            }
            Divider().padding(.vertical, 4)
            footerButton("Quit WindowLens", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func footerButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        MenuBarHoverButton(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
        }
    }

    private static func appIcon(for visit: WindowVisit) -> NSImage? {
        if let app = NSRunningApplication(processIdentifier: visit.pid), let icon = app.icon {
            icon.size = NSSize(width: 16, height: 16)
            return icon
        }
        if !visit.bundleIdentifier.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: visit.bundleIdentifier) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            return icon
        }
        return nil
    }
}
