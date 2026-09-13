import AppKit
import Combine
import Foundation
import Sparkle
import UserNotifications

private let updateNotificationIdentifier = "windowlens.update-available"
private let lastCheckDefaultsKey = "SULastCheckTime"

/// Sparkle-backed software updates with gentle (non-focus-stealing) reminders.
///
/// Settings and shortcuts are unaffected by updates: Sparkle replaces only the
/// `.app` bundle. Preferences live in `UserDefaults` under this bundle ID.
///
/// Automatic checks run on Sparkle’s schedule (default: daily). When an update is
/// found in the background, WindowLens shows a menubar indicator and optional
/// notification — no manual “Check for Updates” required.
@MainActor
final class SoftwareUpdateController: NSObject, ObservableObject {
    static let shared = SoftwareUpdateController()

    enum Status: Equatable {
        case waitingForFirstCheck
        case checking
        case upToDate
        case updateAvailable(version: String)
        case failed(message: String)

        var title: String {
            switch self {
            case .waitingForFirstCheck: return "Waiting for first check"
            case .checking: return "Checking for updates…"
            case .upToDate: return "Up to date"
            case .updateAvailable(let version): return "Update available — \(version)"
            case .failed: return "Couldn’t check for updates"
            }
        }
    }

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var availableUpdateVersion: String?
    @Published private(set) var status: Status = .waitingForFirstCheck
    @Published private(set) var lastCheckedAt: Date?

    var updateAvailable: Bool { availableUpdateVersion != nil }

    private let updaterController: SPUStandardUpdaterController
    private var cancellables = Set<AnyCancellable>()
    private let bridge: SparkleDelegateBridge

    private override init() {
        let bridge = SparkleDelegateBridge()
        self.bridge = bridge
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: bridge,
            userDriverDelegate: bridge
        )
        super.init()
        bridge.owner = self

        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
            .store(in: &cancellables)

        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
        refreshLastCheckedFromDefaults()
        if lastCheckedAt != nil {
            status = .upToDate
        }

        do {
            try updaterController.updater.start()
        } catch {
            status = .failed(message: error.localizedDescription)
            WLLog.app.error("Sparkle updater failed to start: \(error.localizedDescription)")
        }
    }

    var currentVersionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short) (\(build))"
    }

    var marketingVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var lastCheckedDescription: String? {
        guard let lastCheckedAt else { return nil }
        return Self.relativeFormatter.localizedString(for: lastCheckedAt, relativeTo: Date())
    }

    func checkForUpdates() {
        status = .checking
        updaterController.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updaterController.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
        if enabled {
            updaterController.updater.resetUpdateCycleAfterShortDelay()
        }
    }

    fileprivate func markChecking() {
        if case .updateAvailable = status { return }
        status = .checking
    }

    fileprivate func markUpToDate() {
        availableUpdateVersion = nil
        status = .upToDate
        refreshLastCheckedFromDefaults()
    }

    fileprivate func markUpdateAvailable(version: String) {
        let isNew = availableUpdateVersion != version
        availableUpdateVersion = version
        status = .updateAvailable(version: version)
        refreshLastCheckedFromDefaults()
        if isNew {
            postUpdateNotification(version: version)
        }
    }

    fileprivate func markFailed(message: String) {
        guard availableUpdateVersion == nil else { return }
        status = .failed(message: message)
        refreshLastCheckedFromDefaults()
    }

    fileprivate func requestNotificationAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    fileprivate func dismissUpdateNotifications() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [updateNotificationIdentifier])
    }

    private func refreshLastCheckedFromDefaults() {
        lastCheckedAt = UserDefaults.standard.object(forKey: lastCheckDefaultsKey) as? Date
    }

    private func postUpdateNotification(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "Update Available"
        content.body = "WindowLens \(version) is ready to install."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: updateNotificationIdentifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

// MARK: - Sparkle bridges (nonisolated NSObject for ObjC delegate callbacks)

/// Owns Sparkle delegate conformance off the main-actor-isolated controller.
private final class SparkleDelegateBridge: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate, UNUserNotificationCenterDelegate {
    /// Stored without MainActor isolation so ObjC delegate callbacks stay nonisolated.
    nonisolated(unsafe) weak var owner: SoftwareUpdateController?

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Task { @MainActor in
            self.owner?.markChecking()
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        // Sparkle always passes an error here with a "no update found" reason,
        // including when the user is already on the latest version.
        Task { @MainActor in
            self.owner?.markUpToDate()
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            self.owner?.markUpdateAvailable(version: version)
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.owner?.markFailed(message: message)
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        guard let error else { return }
        let message = error.localizedDescription
        Task { @MainActor in
            // Avoid clobbering a known available update with a later cycle error.
            if self.owner?.updateAvailable != true {
                self.owner?.markFailed(message: message)
            }
        }
    }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Near launch / focused moments: let Sparkle show its alert.
        // Otherwise we show menubar / Settings / notification indicators.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        Task { @MainActor in
            self.owner?.markUpdateAvailable(version: version)
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in
            self.owner?.dismissUpdateNotifications()
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in
            self.owner?.dismissUpdateNotifications()
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        Task { @MainActor in
            self.owner?.requestNotificationAuthorizationIfNeeded()
        }
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier == updateNotificationIdentifier,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in
                self.owner?.checkForUpdates()
            }
        }
        completionHandler()
    }
}
