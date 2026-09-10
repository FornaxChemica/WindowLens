import Foundation
import OSLog

/// Shared OSLog loggers for WindowLens. Filter by subsystem in Console.app.
enum WLLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.windowlens.app"

    static let eventTap = Logger(subsystem: subsystem, category: "eventTap")
    static let preview = Logger(subsystem: subsystem, category: "preview")
    static let cache = Logger(subsystem: subsystem, category: "cache")
    static let app = Logger(subsystem: subsystem, category: "app")
    static let switcher = Logger(subsystem: subsystem, category: "switcher")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let general = Logger(subsystem: subsystem, category: "general")
}
