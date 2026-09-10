import AppKit
import SwiftUI

/// Stay Awake controls embedded in the menu-bar panel.
struct StayAwakeControlsView: View {
    @ObservedObject private var manager = KeepAwakeManager.shared
    @ObservedObject private var agents = AgentActivityWatcher.shared
    @ObservedObject private var safety = KeepAwakeSafetyMonitor.shared
    var compact: Bool = false
    var showsChrome: Bool = true

    private var isAgentMode: Bool {
        manager.isActive && manager.activeDuration == .whileAgentsActive
    }

    private var heroDuration: KeepAwakeDuration {
        manager.activeDuration ?? manager.selectedDuration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsChrome {
                header
            }
            heroButton
            durationRow
            divider
            toggleRows
            if let error = manager.lidPrivilegeError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if manager.isPausedForHeat, let msg = manager.thermalPauseMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if shouldShowAgentCards {
                agentCards
            }
            if showsChrome {
                commandPreview
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            Text("stay awake")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 6, height: 6)
                Text(manager.isActive ? manager.countdownText : "idle")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(manager.isActive ? Color.primary.opacity(0.9) : .secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(manager.isActive ? 0.12 : 0.06))
            )
        }
    }

    private var statusDotColor: Color {
        if manager.isPausedForHeat { return .orange }
        if manager.isActive { return Color.accentColor }
        return Color.secondary.opacity(0.45)
    }

    // MARK: - Hero — duration icon + remaining time

    private var heroButton: some View {
        Button {
            manager.toggleHero()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.primary.opacity(manager.isActive ? 0.07 : 0.03))
                    )

                VStack(spacing: 10) {
                    Image(systemName: heroSymbol)
                        .font(.system(size: 36, weight: .ultraLight))
                        .foregroundStyle(manager.isActive ? Color.primary : Color.secondary.opacity(0.75))
                        .symbolEffect(.pulse, isActive: manager.isActive && !manager.isPausedForHeat)

                    Text(heroCaption)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(manager.isActive ? Color.primary.opacity(0.9) : .secondary)
                        .monospacedDigit()

                    Text(heroSubcaption)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 118)
        }
        .buttonStyle(.plain)
        .help(manager.isActive ? "Stop Stay Awake" : "Start Stay Awake")
    }

    private var heroSymbol: String {
        if manager.isPausedForHeat { return "thermometer.medium" }
        if manager.isActive {
            if manager.lidClosedStayAwakeEnabled { return "laptopcomputer" }
            return heroDuration.symbolName
        }
        return "moon.zzz"
    }

    private var heroCaption: String {
        if manager.isPausedForHeat { return "Paused" }
        if manager.isActive {
            return manager.countdownText
        }
        return heroDuration.shortLabel
    }

    private var heroSubcaption: String {
        if manager.isPausedForHeat { return "Cooling down" }
        if manager.isActive {
            return heroDuration.displayName
        }
        return "Tap to start · \(heroDuration.displayName)"
    }

    // MARK: - Durations with icons

    private var durationRow: some View {
        HStack(spacing: 5) {
            ForEach(KeepAwakeDuration.timedPresets) { duration in
                durationChip(duration)
            }
            durationChip(.whileAgentsActive)
        }
    }

    private func durationChip(_ duration: KeepAwakeDuration) -> some View {
        let selectedActive = manager.isActive && manager.activeDuration == duration
        let selectedIdle = !manager.isActive && manager.selectedDuration == duration

        return Button {
            manager.selectDuration(duration)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: duration.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text(duration.shortLabel)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        selectedActive
                            ? Color.primary.opacity(0.85)
                            : Color.primary.opacity(selectedIdle ? 0.14 : 0.05)
                    )
            )
            .foregroundStyle(
                selectedActive
                    ? Color(nsColor: .windowBackgroundColor)
                    : Color.primary.opacity(0.78)
            )
        }
        .buttonStyle(.plain)
        .help(duration.displayName)
    }

    // MARK: - Toggles

    private var toggleRows: some View {
        VStack(spacing: 0) {
            stayAwakeToggleRow(
                title: "Also keep screen on",
                subtitle: "Display stays awake",
                systemImage: "sun.max",
                isOn: manager.keepScreenOn
            ) {
                manager.setKeepScreenOn(!manager.keepScreenOn)
            }

            thinDivider

            stayAwakeToggleRow(
                title: "Stay awake with lid closed",
                subtitle: manager.isInstallingLidPrivilege
                    ? "Waiting for admin…"
                    : "Turns off when you quit WindowLens",
                systemImage: "laptopcomputer",
                isOn: manager.lidClosedStayAwakeEnabled,
                disabled: manager.isInstallingLidPrivilege
            ) {
                manager.setLidClosedStayAwakeEnabled(!manager.lidClosedStayAwakeEnabled)
            }

            thinDivider

            stayAwakeToggleRow(
                title: "Pause when running hot",
                subtitle: safety.cpuTemperatureC.map { "CPU \(Int($0))° · resumes when cooler" } ?? "Protects the Mac under load",
                systemImage: "thermometer.medium",
                isOn: manager.pauseWhenHot
            ) {
                manager.setPauseWhenHot(!manager.pauseWhenHot)
            }
        }
    }

    private func stayAwakeToggleRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isOn: Bool,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                StayAwakePillToggle(isOn: isOn)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .menuBarHoverBackground()
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }

    // MARK: - Agent cards

    private var shouldShowAgentCards: Bool {
        isAgentMode || (manager.isActive && !agents.activeAgents.isEmpty)
    }

    private var agentCards: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isAgentMode && agents.activeAgents.isEmpty {
                StayAwakeAgentCard(
                    title: "Waiting for AI",
                    subtitle: "Open Cursor, Claude, Codex…",
                    elapsed: "—",
                    icon: nil
                )
            }
            ForEach(agents.activeAgents.prefix(6)) { agent in
                StayAwakeAgentCard(
                    title: agent.displayName,
                    subtitle: agent.statusHint,
                    elapsed: agent.elapsedDescription,
                    icon: agents.icon(for: agent)
                )
            }
            if agents.activeAgents.count > 6 {
                Text("+\(agents.activeAgents.count - 6) more agents")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var commandPreview: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(manager.commandPreviewLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }

    private var thinDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
    }
}

private struct StayAwakePillToggle: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule(style: .continuous)
                .fill(isOn ? Color.primary.opacity(0.85) : Color.primary.opacity(0.12))
                .frame(width: 36, height: 22)
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: 18, height: 18)
                .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                .padding(2)
        }
        .animation(.easeInOut(duration: 0.16), value: isOn)
    }
}

struct StayAwakeAgentCard: View {
    let title: String
    let subtitle: String
    let elapsed: String
    let icon: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 22, height: 22)
                        .cornerRadius(5)
                } else {
                    Circle()
                        .fill(Color.orange.opacity(0.85))
                        .frame(width: 10, height: 10)
                        .padding(.top, 5)
                        .frame(width: 22)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(elapsed)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.6)
        )
    }
}
