import SwiftUI

/// Settings tab: live TCC status overview with grant actions.
struct PermissionsSettingsView: View {
    @StateObject private var viewModel = PermissionOnboardingViewModel()

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                summaryStrip
                requiredGrid
                optionalSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await viewModel.refreshNow()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Permissions")
                .font(.title2.weight(.semibold))
            Text("WindowLens needs these to switch windows and show previews.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summaryStrip: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Status")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(summaryTitle)
                    .font(.headline)
                    .animation(.spring(response: 0.32, dampingFraction: 0.84), value: viewModel.grantedCount)
            }

            Spacer(minLength: 8)

            PermissionsProgressRing(
                progress: CGFloat(viewModel.grantedCount) / CGFloat(max(viewModel.requiredCount, 1)),
                label: "\(viewModel.grantedCount) of \(viewModel.requiredCount)"
            )
            .animation(.spring(response: 0.36, dampingFraction: 0.82), value: viewModel.grantedCount)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var summaryTitle: String {
        if viewModel.allGranted {
            return "All required permissions are ready"
        }
        let remaining = viewModel.requiredCount - viewModel.grantedCount
        return remaining == 1
            ? "1 permission still needed"
            : "\(remaining) permissions still needed"
    }

    private var requiredGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(viewModel.items) { item in
                PermissionStatusTile(
                    title: item.title,
                    description: item.description,
                    systemImage: item.systemImage,
                    state: item.state,
                    grantTitle: "Grant"
                ) {
                    viewModel.grant(item.permission)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: viewModel.items)
    }

    private var optionalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Optional")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            PermissionStatusTile(
                title: "Stay awake with lid closed",
                description: "One-time admin approval so Stay Awake keeps working after you close the lid.",
                systemImage: "laptopcomputer.and.arrow.down",
                state: viewModel.bagModePrivilegeState,
                grantTitle: "Enable"
            ) {
                viewModel.grantBagModePrivilege()
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: viewModel.bagModePrivilegeState)
        }
    }
}

// MARK: - Tile

private struct PermissionStatusTile: View {
    let title: String
    let description: String
    let systemImage: String
    let state: PermissionOnboardingViewModel.PermissionRowState
    let grantTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(state == .granted ? Color.green : Color.accentColor)
                    .frame(width: 28, height: 28)
                    .animation(.easeInOut(duration: 0.2), value: state)

                Spacer(minLength: 8)

                statusControl
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusControl: some View {
        switch state {
        case .idle:
            Button(grantTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .waiting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        case .granted:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: state)
                Text("Granted")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Progress

private struct PermissionsProgressRing: View {
    let progress: CGFloat
    let label: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: 4)

            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(
                    Color.accentColor.opacity(0.9),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(width: 58, height: 58)
        .accessibilityLabel(label)
    }
}
