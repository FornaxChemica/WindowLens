import AppKit
import Foundation

/// Locates local WindowLens crash reports for optional sharing (no cloud upload).
enum CrashReportStore {
    private static let reportPrefix = "WindowLens"
    private static let reportExtensions: Set<String> = ["ips", "crash"]

    private static var userReportsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    private static var systemReportsDirectory: URL {
        URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true)
    }

    static func recentReportURLs(limit: Int = 20) -> [URL] {
        guard limit > 0 else { return [] }

        let fm = FileManager.default
        var candidates: [(url: URL, date: Date)] = []

        for directory in [userReportsDirectory, systemReportsDirectory] {
            guard let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for url in entries {
                guard isWindowLensReport(url) else { continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                guard values?.isRegularFile == true else { continue }
                let date = values?.contentModificationDate ?? .distantPast
                candidates.append((url, date))
            }
        }

        return candidates
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map(\.url)
    }

    static func latestReportURL() -> URL? {
        recentReportURLs(limit: 1).first
    }

    /// Filename plus relative time, e.g. `WindowLens-2026-03-28-123456.ips (2 hours ago)`.
    static func latestReportSummary() -> String? {
        guard let url = latestReportURL() else { return nil }
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        guard let date = values?.contentModificationDate else {
            return name
        }
        return "\(name) (\(relativeDateString(from: date)))"
    }

    /// Copies the latest report **file contents** (not just the path) to the pasteboard.
    static func copyLatestReportToPasteboard() throws {
        guard let url = latestReportURL() else {
            throw CrashReportError.noReportsFound
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16) else {
            throw CrashReportError.unreadableReport(url.lastPathComponent)
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            throw CrashReportError.copyFailed
        }
    }

    /// Reveals the latest report in Finder, or opens the user DiagnosticReports folder if none exist.
    static func revealLatestInFinder() {
        if let url = latestReportURL() {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let fm = FileManager.default
        let folder = userReportsDirectory
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: - Private

    private static func isWindowLensReport(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        guard reportExtensions.contains(ext) else { return false }
        return name.hasPrefix(reportPrefix)
    }

    private static func relativeDateString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

enum CrashReportError: LocalizedError {
    case noReportsFound
    case unreadableReport(String)
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .noReportsFound:
            return "No WindowLens crash reports found on this Mac."
        case .unreadableReport(let name):
            return "Couldn’t read crash report “\(name)”."
        case .copyFailed:
            return "Couldn’t copy the crash report to the clipboard."
        }
    }
}
