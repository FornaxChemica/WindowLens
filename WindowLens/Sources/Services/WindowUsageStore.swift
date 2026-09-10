import Foundation

struct WindowUsageRecord: Codable, Equatable {
    var surfaceID: String
    var lastAccessedAt: Date
    var accessCount: Int
    var lastAppName: String
    var lastWindowTitle: String
    var firstSeenAt: Date
}

@MainActor
final class WindowUsageStore {
    static let shared = WindowUsageStore()

    static let defaultPersistenceKey = "com.chakshujain.windowlens.usagestore.v1"

    private var records: [String: WindowUsageRecord] = [:]
    private let persistenceKey: String
    private let maxEntries: Int
    private let pruneBatchSize: Int
    private let saveDebounceInterval: TimeInterval
    private let userDefaults: UserDefaults
    private var pendingSaveWorkItem: DispatchWorkItem?

    private init(
        persistenceKey: String = WindowUsageStore.defaultPersistenceKey,
        maxEntries: Int = 500,
        pruneBatchSize: Int = 50,
        saveDebounceInterval: TimeInterval = 2,
        userDefaults: UserDefaults = .standard,
        loadPersistedData: Bool = true
    ) {
        self.persistenceKey = persistenceKey
        self.maxEntries = maxEntries
        self.pruneBatchSize = pruneBatchSize
        self.saveDebounceInterval = saveDebounceInterval
        self.userDefaults = userDefaults
        if loadPersistedData {
            loadFromDisk()
        }
    }

    /// Isolated instance for unit tests (unique persistence key, optional UserDefaults suite).
    internal init(
        forTestingWithMaxEntries maxEntries: Int,
        pruneBatchSize: Int = 50,
        persistenceKey: String = UUID().uuidString,
        userDefaults: UserDefaults = .standard,
        loadPersistedData: Bool = false
    ) {
        self.persistenceKey = persistenceKey
        self.maxEntries = maxEntries
        self.pruneBatchSize = pruneBatchSize
        self.saveDebounceInterval = 2
        self.userDefaults = userDefaults
        if loadPersistedData {
            loadFromDisk()
        }
    }

    /// Writes pending changes immediately (unit tests only).
    internal func persistImmediatelyForTesting() {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        saveToDisk()
    }

    internal var recordCountForTesting: Int {
        records.count
    }

    func recordAccess(identity: PreviewIdentity, appName: String, windowTitle: String) {
        guard shouldRecord(identity: identity) else { return }

        let key = identity.stableKey
        let now = Date()

        if var existing = records[key] {
            existing.accessCount += 1
            existing.lastAccessedAt = now
            existing.lastAppName = appName
            existing.lastWindowTitle = windowTitle
            records[key] = existing
        } else {
            records[key] = WindowUsageRecord(
                surfaceID: key,
                lastAccessedAt: now,
                accessCount: 1,
                lastAppName: appName,
                lastWindowTitle: windowTitle,
                firstSeenAt: now
            )
        }

        pruneIfNeeded()
        scheduleDebouncedSave()

        #if DEBUG
        WLLog.general.debug("recordAccess surfaceID=\(key) records=\(self.records.count)")
        #endif
    }

    func windowsNotAccessedSince(_ date: Date) -> [WindowUsageRecord] {
        records.values
            .filter { $0.lastAccessedAt < date }
            .sorted { $0.lastAccessedAt < $1.lastAccessedAt }
    }

    func clearAll() {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        records.removeAll()
        userDefaults.removeObject(forKey: persistenceKey)
    }

    private func shouldRecord(identity: PreviewIdentity) -> Bool {
        if identity.bundleIdentifier == Bundle.main.bundleIdentifier {
            return false
        }

        let key = identity.stableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            return false
        }

        if !identity.hasReliableCGWindowID, identity.cgWindowID == 0 {
            return false
        }

        return true
    }

    private func pruneIfNeeded() {
        guard records.count > maxEntries else { return }

        let sortedKeys = records.values
            .sorted { $0.lastAccessedAt < $1.lastAccessedAt }
            .prefix(pruneBatchSize)
            .map(\.surfaceID)

        for key in sortedKeys {
            records.removeValue(forKey: key)
        }
    }

    private func scheduleDebouncedSave() {
        pendingSaveWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.saveToDisk()
        }
        pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: workItem)
    }

    private func saveToDisk() {
        pendingSaveWorkItem = nil

        do {
            let data = try JSONEncoder().encode(records)
            userDefaults.set(data, forKey: persistenceKey)
        } catch {
            WLLog.general.error("Failed to encode usage records: \(error)")
        }
    }

    private func loadFromDisk() {
        guard let data = userDefaults.data(forKey: persistenceKey) else {
            records = [:]
            return
        }

        do {
            records = try JSONDecoder().decode([String: WindowUsageRecord].self, from: data)
        } catch {
            WLLog.general.error("Failed to decode usage records, starting fresh: \(error)")
            records = [:]
            userDefaults.removeObject(forKey: persistenceKey)
        }
    }
}
