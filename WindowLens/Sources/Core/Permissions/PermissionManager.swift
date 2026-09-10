import CoreGraphics
import AppKit
import ApplicationServices
import IOKit.hid

actor PermissionManager {
    static let shared = PermissionManager()

    private var hasRequestedScreenRecordingThisLaunch = false

    enum Permission: String, CaseIterable {
        case inputMonitoring = "Input Monitoring"
        case accessibility = "Accessibility"
        case screenRecording = "Screen Recording"
    }

    struct Status {
        var inputMonitoring: Bool
        var accessibility: Bool
        var screenRecording: Bool

        var allGranted: Bool {
            inputMonitoring && accessibility && screenRecording
        }

        /// Accessibility + Input Monitoring. Screen Recording is only needed for thumbnails.
        var coreGranted: Bool {
            inputMonitoring && accessibility
        }

        var description: String {
            """
            Input Monitoring: \(inputMonitoring ? "✓" : "✗")
            Accessibility: \(accessibility ? "✓" : "✗")
            Screen Recording: \(screenRecording ? "✓" : "✗")
            """
        }
    }

    func checkStatus() -> Status {
        Status(
            inputMonitoring: checkInputMonitoring(),
            accessibility: checkAccessibility(),
            screenRecording: checkScreenRecording()
        )
    }

    @discardableResult
    func request(_ permission: Permission) async -> Bool {
        switch permission {
        case .inputMonitoring:
            return requestInputMonitoring()
        case .accessibility:
            return await requestAccessibility()
        case .screenRecording:
            return await requestScreenRecording()
        }
    }

    // MARK: - Input Monitoring

    private func checkInputMonitoring() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    private func requestInputMonitoring() -> Bool {
        let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        WLLog.permissions.debug("Input Monitoring request result: \(granted)")
        return granted || checkInputMonitoring()
    }

    // MARK: - Accessibility

    private func checkAccessibility() -> Bool {
        return AXIsProcessTrusted()
    }

    @discardableResult
    private func requestAccessibility() async -> Bool {
        let trusted = await MainActor.run {
            // Create the prompt key string directly to avoid Swift 6 concurrency issues.
            let promptKey = "AXTrustedCheckOptionPrompt" as CFString
            let options = [promptKey: true] as CFDictionary
            let _ = AXIsProcessTrustedWithOptions(options)
            return AXIsProcessTrusted()
        }

        WLLog.permissions.debug("Accessibility permission requested")
        return trusted || checkAccessibility()
    }

    // MARK: - Screen Recording

    private func checkScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    private func requestScreenRecording() async -> Bool {
        let granted = await MainActor.run {
            CGRequestScreenCaptureAccess()
        }

        WLLog.permissions.debug("Screen Recording request result: \(granted)")
        return granted || checkScreenRecording()
    }

    func requestScreenRecordingIfNeeded() async -> Bool {
        if checkScreenRecording() {
            return true
        }

        guard !hasRequestedScreenRecordingThisLaunch else {
            return false
        }

        hasRequestedScreenRecordingThisLaunch = true
        return await requestScreenRecording()
    }

    // MARK: - Open System Preferences

    func openSystemPreferences(for permission: Permission) async {
        let urlString: String
        switch permission {
        case .inputMonitoring:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }

        await MainActor.run {
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
