import Foundation

/// One-time scoped sudoers install for lid-closed stay awake (`pmset -a disablesleep` only).
enum PmsetPrivilegeInstaller {
    static let sudoersFilePath = "/etc/sudoers.d/windowlens-stayawake"

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedInstalled: Bool?
    nonisolated(unsafe) private static var lastCheckAt: Date?
    private static let checkTTL: TimeInterval = 2

    static var isInstalled: Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedInstalled,
           let last = lastCheckAt,
           Date().timeIntervalSince(last) < checkTTL {
            return cached
        }
        // Do NOT read the sudoers file — it's 440 root:wheel and unreadable to the app user.
        // The only reliable check is whether passwordless sudo actually works.
        let result = canRunPasswordlessDisableSleep()
        cachedInstalled = result
        lastCheckAt = Date()
        return result
    }

    static func invalidateCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedInstalled = nil
        lastCheckAt = nil
    }

    /// Installs a sudoers rule limited to exactly two pmset argv lines. Prompts for admin once.
    @discardableResult
    static func install() -> Bool {
        let username = NSUserName()
        // ALL=(ALL) is more compatible across macOS sudoers parsers than ALL=(root).
        let rule = """
        \(username) ALL=(ALL) NOPASSWD: /usr/bin/pmset -a disablesleep 1
        \(username) ALL=(ALL) NOPASSWD: /usr/bin/pmset -a disablesleep 0

        """

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("windowlens-stayawake-\(UUID().uuidString)")
        do {
            try rule.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            WLLog.general.error("Failed to write temp sudoers: \(error)")
            return false
        }

        let tempPath = tempURL.path
        // chmod 440 is correct for sudoers; never rely on reading this file back as the user.
        let shell = """
        /bin/cp '\(tempPath)' '\(sudoersFilePath)' && /bin/chmod 440 '\(sudoersFilePath)' && /usr/sbin/visudo -cf '\(sudoersFilePath)'
        """

        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let stderr = Pipe()
        let stdout = Pipe()
        process.standardError = stderr
        process.standardOutput = stdout

        // Keep temp file until elevated cp finishes.
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            invalidateCache()
            WLLog.general.error("Privilege install failed to launch osascript: \(error)")
            return false
        }

        try? FileManager.default.removeItem(at: tempURL)

        let status = process.terminationStatus
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let outText = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if status != 0 {
            invalidateCache()
            WLLog.general.error("Privilege install osascript failed (\(status)): \(errText) \(outText)")
            return false
        }

        // Give sudo a moment to pick up the new sudoers.d file.
        Thread.sleep(forTimeInterval: 0.15)
        invalidateCache()

        // Retry probe a few times — sudo can lag briefly after sudoers write.
        var sudoOK = false
        for _ in 0..<5 {
            if canRunPasswordlessDisableSleep() {
                sudoOK = true
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        if !sudoOK {
            WLLog.general.debug("Privilege install wrote sudoers but passwordless pmset still fails. stderr=\(errText)")
        }

        cacheLock.lock()
        cachedInstalled = sudoOK
        lastCheckAt = Date()
        cacheLock.unlock()
        return sudoOK
    }

    /// Probe whether our exact NOPASSWD pmset rule works. Safe no-op when already 0.
    static func canRunPasswordlessDisableSleep() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"]
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                if let message = String(data: data, encoding: .utf8), !message.isEmpty {
                    WLLog.general.error("sudo -n pmset probe failed: \(message)")
                }
            }
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
