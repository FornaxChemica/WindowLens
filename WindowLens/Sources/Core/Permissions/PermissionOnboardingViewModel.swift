import Foundation
import SwiftUI

@MainActor
final class PermissionOnboardingViewModel: ObservableObject {
    enum PermissionRowState: Equatable {
        case idle
        case waiting
        case granted
    }

    struct PermissionItem: Identifiable, Equatable {
        let permission: PermissionManager.Permission
        let title: String
        let description: String
        let systemImage: String
        var state: PermissionRowState

        var id: PermissionManager.Permission { permission }
    }

    @Published private(set) var items: [PermissionItem]
    @Published private(set) var bagModePrivilegeState: PermissionRowState = .idle

    private let manager: PermissionManager
    private var pollingTask: Task<Void, Never>?

    var allGranted: Bool {
        items.allSatisfy { $0.state == .granted }
    }

    /// Accessibility + Input Monitoring — enough to dismiss the launch gate.
    var coreGranted: Bool {
        items
            .filter { $0.permission != .screenRecording }
            .allSatisfy { $0.state == .granted }
    }

    var grantedCount: Int {
        items.filter { $0.state == .granted }.count
    }

    var requiredCount: Int {
        items.count
    }

    init(manager: PermissionManager = .shared) {
        self.manager = manager
        self.items = [
            PermissionItem(
                permission: .accessibility,
                title: "Accessibility",
                description: "Lets WindowLens inspect and raise app windows.",
                systemImage: "accessibility",
                state: .idle
            ),
            PermissionItem(
                permission: .inputMonitoring,
                title: "Input Monitoring",
                description: "Lets WindowLens detect Option-Tab and preview Cmd-Tab.",
                systemImage: "keyboard",
                state: .idle
            ),
            PermissionItem(
                permission: .screenRecording,
                title: "Screen Recording",
                description: "Needed for window thumbnails (optional for core switching).",
                systemImage: "rectangle.on.rectangle",
                state: .idle
            )
        ]

        startPolling()
    }

    deinit {
        pollingTask?.cancel()
    }

    func grant(_ permission: PermissionManager.Permission) {
        updateState(for: permission, state: .waiting)

        Task { [manager] in
            _ = await manager.request(permission)
            await manager.openSystemPreferences(for: permission)
            await refresh()
        }
    }

    func grantBagModePrivilege() {
        bagModePrivilegeState = .waiting
        Task.detached(priority: .userInitiated) {
            let ok = PmsetPrivilegeInstaller.install()
            await MainActor.run {
                PmsetPrivilegeInstaller.invalidateCache()
                self.bagModePrivilegeState = ok ? .granted : .idle
                if ok {
                    KeepAwakeManager.shared.setLidClosedStayAwakeEnabled(true)
                }
            }
        }
    }

    func refreshNow() async {
        await refresh()
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func refresh() async {
        let status = await manager.checkStatus()
        apply(status: status)
        refreshBagModePrivilege()
    }

    private func refreshBagModePrivilege() {
        if PmsetPrivilegeInstaller.isInstalled {
            bagModePrivilegeState = .granted
        } else if bagModePrivilegeState != .waiting {
            bagModePrivilegeState = .idle
        }
    }

    private func apply(status: PermissionManager.Status) {
        items = items.map { item in
            var updated = item
            let isGranted = isPermissionGranted(item.permission, in: status)

            if isGranted {
                updated.state = .granted
            } else if item.state == .waiting {
                updated.state = .waiting
            } else {
                updated.state = .idle
            }

            return updated
        }
    }

    private func updateState(for permission: PermissionManager.Permission, state: PermissionRowState) {
        items = items.map { item in
            guard item.permission == permission else { return item }
            var updated = item
            updated.state = state
            return updated
        }
    }

    private func isPermissionGranted(
        _ permission: PermissionManager.Permission,
        in status: PermissionManager.Status
    ) -> Bool {
        switch permission {
        case .accessibility:
            return status.accessibility
        case .inputMonitoring:
            return status.inputMonitoring
        case .screenRecording:
            return status.screenRecording
        }
    }
}
