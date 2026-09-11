import AppKit
import CoreGraphics
import ScreenCaptureKit

final class WindowPreviewUpdate {
    let windowID: CGWindowID
    let ownerPID: pid_t?
    let previewIdentity: PreviewIdentity
    let title: String
    let bounds: CGRect
    let image: NSImage
    let selectionGeneration: UInt64?

    init(
        windowID: CGWindowID,
        ownerPID: pid_t?,
        previewIdentity: PreviewIdentity,
        title: String,
        bounds: CGRect,
        image: NSImage,
        selectionGeneration: UInt64? = nil
    ) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.previewIdentity = previewIdentity
        self.title = title
        self.bounds = bounds
        self.image = image
        self.selectionGeneration = selectionGeneration
    }
}

/// Captures and caches lightweight window thumbnails keyed by PID, CGWindowID, title, and bounds.
final class WindowPreviewService: @unchecked Sendable {
    static let shared = WindowPreviewService()

    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    private var inFlightPreviewKeys = Set<String>()
    private var lastSuccessfulCaptureDatesByKey: [String: Date] = [:]
    private var successfulPreviewStoreCountSinceCleanup = 0
    private var lastDiskCleanupDate = Date()
    private var isDiskCleanupInProgress = false
    private var volatileMemoryGeneration: UInt64 = 0
    private let previewImageStore = PreviewImageStore()
    private let captureLimiter = CaptureLimiter(limit: 2)

    private let freshCaptureThrottleInterval: TimeInterval = 1.2
    private let diskCleanupStoreInterval = 25
    private let diskCleanupTimeInterval: TimeInterval = 10 * 60
    private let diskCleanupMaximumImageCount = 200
    private let diskCleanupMaximumAge: TimeInterval = 7 * 24 * 60 * 60
    private static let maximumPixelSize = CGSize(width: 1400, height: 900)

    private struct PreviewRequest: Sendable {
        let windowID: CGWindowID
        let ownerPID: pid_t?
        let previewIdentity: PreviewIdentity
        let appName: String?
        let title: String
        let bounds: CGRect
        let inFlightKey: String
        let selectionGeneration: UInt64?
        let volatileMemoryGeneration: UInt64

        var sourceSize: CGSize { bounds.size }
    }

    private init() {
        cache.countLimit = 80
        cache.totalCostLimit = 64 * 1024 * 1024
        _ = previewImageStore.cleanup(
            maximumImageCount: diskCleanupMaximumImageCount,
            maximumAge: diskCleanupMaximumAge
        )
    }

    func trimVolatileMemory(reason: String) {
        cache.removeAllObjects()

        lock.lock()
        volatileMemoryGeneration &+= 1
        lastSuccessfulCaptureDatesByKey.removeAll(keepingCapacity: false)
        lock.unlock()

        WLLog.preview.debug("Volatile preview memory trimmed: \(reason)")
    }

    func cachedPreview(
        for identity: PreviewIdentity
    ) -> NSImage? {
        cachedPreview(for: identity, storeDiskResultInMemory: true)
    }

    private func cachedPreview(
        for identity: PreviewIdentity,
        storeDiskResultInMemory: Bool
    ) -> NSImage? {
        let (strongKeys, weakKeys) = Self.partitionCacheKeys(identity.cacheKeys)

        for key in strongKeys {
            if let image = cache.object(forKey: key as NSString) {
                WLLog.preview.debug("memory cache hit key=\(key)")
                return image
            }
        }

        if strongKeys.isEmpty {
            for key in weakKeys {
                if let image = cache.object(forKey: key as NSString) {
                    WLLog.preview.debug("memory cache hit key=\(key)")
                    return image
                }
            }
        }

        if let image = previewImageStore.image(for: identity) {
            WLLog.preview.debug("disk cache hit key=\(identity.stableKey)")
            if storeDiskResultInMemory {
                storeInMemory(image, for: identity)
            }
            return image
        }

        return nil
    }

    func cachedPreview(
        for windowID: CGWindowID,
        ownerPID: pid_t? = nil,
        title: String? = nil,
        bounds: CGRect = .zero
    ) -> NSImage? {
        cachedPreview(
            for: PreviewIdentity(
                ownerPID: ownerPID,
                bundleIdentifier: nil,
                cgWindowID: windowID,
                title: title ?? "",
                bounds: bounds
            )
        )
    }

    func cachedPreview(
        for windowID: CGWindowID,
        ownerPID: pid_t? = nil,
        bundleIdentifier: String?,
        title: String? = nil,
        bounds: CGRect = .zero,
        axIndex: Int? = nil,
        hasReliableWindowID: Bool = true
    ) -> NSImage? {
        cachedPreview(
            for: PreviewIdentity(
                ownerPID: ownerPID,
                bundleIdentifier: bundleIdentifier,
                cgWindowID: windowID,
                axIndex: axIndex,
                title: title ?? "",
                bounds: bounds,
                hasReliableCGWindowID: hasReliableWindowID
            )
        )
    }

    func requestPreview(
        for window: WindowModel,
        ownerPID: pid_t? = nil,
        appName: String? = nil,
        selectionGeneration: UInt64? = nil
    ) {
        requestPreviews(
            for: [window],
            ownerPID: ownerPID,
            appName: appName,
            selectionGeneration: selectionGeneration
        )
    }

    func requestPreviews(
        for windows: [WindowModel],
        ownerPID: pid_t? = nil,
        appName: String? = nil,
        selectionGeneration: UInt64? = nil
    ) {
        var requests: [PreviewRequest] = []

        for window in windows {
            guard !window.isWindowlessPlaceholder else { continue }
            if WindowEnumerator.shouldSuppressFinderPreview(for: window) {
                WLLog.preview.debug("skip Finder restore preview id=\(window.windowID) title=\(window.title)")
                continue
            }

            let windowID = window.windowID
            let identity = requestIdentity(for: window, ownerPID: ownerPID)
            let resolvedOwnerPID = ownerPID ?? identity.ownerPID
            let inFlightKey = inFlightKey(for: identity)
            let volatileMemoryGeneration = currentVolatileMemoryGeneration()

            if let cachedImage = cachedPreview(for: identity) {
                WLLog.preview.debug("posting cached preview id=\(windowID) title=\(window.title)")
                postPreview(cachedImage, for: PreviewRequest(
                    windowID: windowID,
                    ownerPID: resolvedOwnerPID,
                    previewIdentity: identity,
                    appName: appName,
                    title: window.title,
                    bounds: window.bounds,
                    inFlightKey: inFlightKey,
                    selectionGeneration: selectionGeneration,
                    volatileMemoryGeneration: volatileMemoryGeneration
                ))

                if !window.canCapturePreview {
                    continue
                }

                if isFreshCaptureThrottled(inFlightKey) {
                    WLLog.preview.debug("skip fresh capture throttle id=\(windowID) title=\(window.title)")
                    continue
                }
            }

            if window.previewImage != nil {
                WLLog.preview.debug("recapturing existing preview without keyed cache id=\(windowID) pid=\(ownerPID.map(String.init) ?? "unknown") title=\(window.title)")
            }

            WLLog.preview.debug("cache miss id=\(windowID) pid=\(ownerPID.map(String.init) ?? "unknown") app=\(appName ?? "unknown") title=\(window.title) capture=\(window.canCapturePreview) bounds=\(Self.describe(window.bounds))")

            guard window.canCapturePreview else { continue }
            guard markInFlight(inFlightKey) else {
                WLLog.preview.debug("skip in-flight id=\(windowID) title=\(window.title) generation=\(selectionGeneration.map(String.init) ?? "none")")
                continue
            }

            requests.append(PreviewRequest(
                windowID: windowID,
                ownerPID: resolvedOwnerPID,
                previewIdentity: identity,
                appName: appName,
                title: window.title,
                bounds: window.bounds,
                inFlightKey: inFlightKey,
                selectionGeneration: selectionGeneration,
                volatileMemoryGeneration: volatileMemoryGeneration
            ))
        }

        guard !requests.isEmpty else { return }

        WLLog.preview.debug("queued \(requests.count) preview request(s): \(requests.map { String($0.windowID) }.joined(separator: ","))")
        let priority: TaskPriority = selectionGeneration == nil ? .utility : .userInitiated
        Task.detached(priority: priority) {
            await self.captureLimiter.acquire()
            await self.capturePreviews(for: requests)
            await self.captureLimiter.release()
        }
    }

    private func capturePreviews(for requests: [PreviewRequest]) async {
        guard await PermissionManager.shared.requestScreenRecordingIfNeeded() else {
            for request in requests {
                clearInFlight(request.inFlightKey)
            }
            WLLog.preview.debug("Screen Recording permission is required for window previews")
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let windowsByID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
            WLLog.preview.debug("ScreenCaptureKit returned \(content.windows.count) window(s), \(content.displays.count) display(s), \(content.applications.count) app(s)")

            var assignedSCWindowIDs = Set<CGWindowID>()

            for request in requests {
                defer { clearInFlight(request.inFlightKey) }

                guard let window = matchWindow(
                    for: request,
                    windowsByID: windowsByID,
                    allWindows: content.windows,
                    assignedSCWindowIDs: assignedSCWindowIDs
                ) else {
                    WLLog.preview.debug("no SCWindow match for AX id=\(request.windowID) pid=\(request.ownerPID.map(String.init) ?? "unknown") app=\(request.appName ?? "unknown") title=\(request.title) bounds=\(Self.describe(request.bounds)); candidates=\(self.candidateSummary(for: request, in: content.windows))")
                    continue
                }

                do {
                    guard let image = try await Self.captureWindowImage(window, sourceSize: request.sourceSize) else {
                        WLLog.preview.debug("capture returned no image for AX id=\(request.windowID) matchedSC id=\(window.windowID) title=\(window.title ?? "untitled")")
                        continue
                    }

                    let quality = Self.previewQuality(for: image)
                    let cachedImage = cachedPreview(
                        for: request.previewIdentity,
                        storeDiskResultInMemory: shouldStoreVolatileMemory(for: request.volatileMemoryGeneration)
                    )
                    let cachedQuality = cachedImage.map { Self.previewQuality(for: $0) }
                    if let rejectionReason = Self.previewRejectionReason(
                        quality: quality,
                        cachedQuality: cachedQuality,
                        appName: request.appName
                    ) {
                        WLLog.preview.debug("rejected preview AX id=\(request.windowID) SC id=\(window.windowID) reason=\(rejectionReason) metrics=\(quality.debugSummary) title=\(request.title)")
                        // Don't resurrect a similarly-broken cached half-panel frame.
                        let cachedAlsoBad = cachedQuality.map {
                            Self.previewRejectionReason(quality: $0, cachedQuality: nil, appName: request.appName) != nil
                        } ?? true
                        if let cachedImage, !cachedAlsoBad {
                            WLLog.preview.debug("posting cached preview after rejected capture id=\(request.windowID) title=\(request.title) cachedMetrics=\(cachedQuality?.debugSummary ?? "unknown")")
                            postPreview(cachedImage, for: request)
                        }
                        continue
                    }

                    WLLog.preview.debug("captured preview AX id=\(request.windowID) SC id=\(window.windowID) image=\(Int(image.size.width))x\(Int(image.size.height)) metrics=\(quality.debugSummary) title=\(request.title)")
                    storePreview(
                        image,
                        for: request.previewIdentity,
                        storeInVolatileMemory: shouldStoreVolatileMemory(for: request.volatileMemoryGeneration)
                    )
                    markSuccessfulCapture(request.inFlightKey)
                    assignedSCWindowIDs.insert(window.windowID)
                    postPreview(image, for: request)
                } catch {
                    WLLog.preview.debug("capture failed AX id=\(request.windowID) matchedSC id=\(window.windowID) title=\(request.title): \(error)")
                }
            }
        } catch {
            for request in requests {
                clearInFlight(request.inFlightKey)
            }
            WLLog.preview.debug("failed to fetch shareable content: \(error)")
        }
    }

    private func matchWindow(
        for request: PreviewRequest,
        windowsByID: [CGWindowID: SCWindow],
        allWindows: [SCWindow],
        assignedSCWindowIDs: Set<CGWindowID> = []
    ) -> SCWindow? {
        if request.previewIdentity.hasReliableCGWindowID,
           let directMatch = windowsByID[request.windowID],
           !assignedSCWindowIDs.contains(directMatch.windowID) {
            let directPID = directMatch.owningApplication?.processID
            if request.ownerPID == nil || directPID == request.ownerPID {
                if Self.titleMatches(window: directMatch, request: request) {
                    WLLog.preview.debug("matched by CGWindowID AX id=\(request.windowID) SC id=\(directMatch.windowID) pid=\(directPID.map(String.init) ?? "unknown") title=\(directMatch.title ?? "untitled")")
                } else {
                    WLLog.preview.debug("matched by CGWindowID despite title mismatch AX id=\(request.windowID) SC id=\(directMatch.windowID) requestedTitle=\(request.title) scTitle=\(directMatch.title ?? "untitled") requestedBounds=\(Self.describe(request.bounds)) scFrame=\(Self.describe(directMatch.frame))")
                }
                return directMatch
            }

            WLLog.preview.debug("ignored CGWindowID match with wrong pid AX id=\(request.windowID) requestedPID=\(request.ownerPID.map(String.init) ?? "unknown") scPID=\(directPID.map(String.init) ?? "unknown") title=\(directMatch.title ?? "untitled")")
        }

        guard let ownerPID = request.ownerPID else { return nil }

        let pidCandidates = allWindows.filter { window in
            window.owningApplication?.processID == ownerPID
        }
        let layerCandidates = pidCandidates.filter { $0.windowLayer == 0 }
        let candidates = layerCandidates.isEmpty ? pidCandidates : layerCandidates
        guard !candidates.isEmpty else { return nil }

        let rankedCandidates = candidates
            .filter { !assignedSCWindowIDs.contains($0.windowID) }
            .map { window in (window, Self.matchScore(window: window, request: request)) }
            .sorted { lhs, rhs in lhs.1 < rhs.1 }

        guard let bestMatch = rankedCandidates.first else { return nil }
        let hasUsableGeometry = request.bounds.width > 1 && request.bounds.height > 1
        let maximumAcceptableScore: CGFloat = hasUsableGeometry ? 80 : 45
        guard bestMatch.1 <= maximumAcceptableScore else {
            WLLog.preview.debug("rejected weak fallback match AX id=\(request.windowID) bestSC id=\(bestMatch.0.windowID) score=\(Int(bestMatch.1)) pid=\(ownerPID) title=\(bestMatch.0.title ?? "untitled")")
            return nil
        }

        WLLog.preview.debug("fallback matched AX id=\(request.windowID) to SC id=\(bestMatch.0.windowID) score=\(Int(bestMatch.1)) pid=\(ownerPID) title=\(bestMatch.0.title ?? "untitled")")
        return bestMatch.0
    }

    private static func titleMatches(window: SCWindow, request: PreviewRequest) -> Bool {
        let requestTitle = normalizedTitle(request.title)
        let windowTitle = normalizedTitle(window.title ?? "")
        guard !requestTitle.isEmpty, !windowTitle.isEmpty else {
            return true
        }

        return requestTitle == windowTitle
            || windowTitle.contains(requestTitle)
            || requestTitle.contains(windowTitle)
    }

    private func candidateSummary(for request: PreviewRequest, in windows: [SCWindow]) -> String {
        let candidates = windows
            .filter { window in
                guard let ownerPID = request.ownerPID else { return true }
                return window.owningApplication?.processID == ownerPID
            }
            .prefix(6)
            .map { window in
                "id=\(window.windowID) layer=\(window.windowLayer) onScreen=\(window.isOnScreen) title=\(window.title ?? "untitled") frame=\(Self.describe(window.frame))"
            }

        let summary = candidates.joined(separator: " | ")
        return summary.isEmpty ? "none" : summary
    }

    private static func matchScore(window: SCWindow, request: PreviewRequest) -> CGFloat {
        var score: CGFloat = 0

        let requestTitle = normalizedTitle(request.title)
        let windowTitle = normalizedTitle(window.title ?? "")
        if !requestTitle.isEmpty {
            if windowTitle == requestTitle {
                score += 0
            } else if windowTitle.contains(requestTitle) || requestTitle.contains(windowTitle) {
                score += 4
            } else {
                score += 25
            }
        }

        let frame = window.frame
        if hasReliableBounds(request.bounds) {
            score += min(abs(frame.width - request.bounds.width) / 10, 40)
            score += min(abs(frame.height - request.bounds.height) / 10, 40)
            score += min(abs(frame.minX - request.bounds.minX) / 80, 20)
            score += min(abs(frame.minY - request.bounds.minY) / 80, 20)
        }
        score += CGFloat(abs(window.windowLayer)) * 20

        return score
    }

    private static func partitionCacheKeys(_ keys: [String]) -> (strong: [String], weak: [String]) {
        var strong: [String] = []
        var weak: [String] = []
        for key in keys {
            if key.contains(":wid:") || key.hasPrefix("wid:") {
                strong.append(key)
            } else {
                weak.append(key)
            }
        }
        return (strong, weak)
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func hasReliableBounds(_ bounds: CGRect) -> Bool {
        bounds.width > 16 && bounds.height > 16
    }

    private static func describe(_ rect: CGRect) -> String {
        "x=\(Int(rect.origin.x)) y=\(Int(rect.origin.y)) w=\(Int(rect.width)) h=\(Int(rect.height))"
    }


    private func markInFlight(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !inFlightPreviewKeys.contains(key) else { return false }
        inFlightPreviewKeys.insert(key)
        return true
    }

    private func isFreshCaptureThrottled(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let lastCaptureDate = lastSuccessfulCaptureDatesByKey[key] else {
            return false
        }

        return Date().timeIntervalSince(lastCaptureDate) < freshCaptureThrottleInterval
    }

    private func currentVolatileMemoryGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return volatileMemoryGeneration
    }

    private func shouldStoreVolatileMemory(for requestGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestGeneration == volatileMemoryGeneration
    }

    private func requestIdentity(for window: WindowModel, ownerPID: pid_t?) -> PreviewIdentity {
        PreviewIdentity(
            ownerPID: ownerPID ?? window.previewIdentity.ownerPID,
            bundleIdentifier: window.previewIdentity.bundleIdentifier,
            cgWindowID: window.windowID,
            axIndex: window.previewIdentity.axIndex,
            title: window.title,
            bounds: window.bounds,
            hasReliableCGWindowID: window.previewIdentity.hasReliableCGWindowID
        )
    }

    private func clearInFlight(_ key: String) {
        lock.lock()
        inFlightPreviewKeys.remove(key)
        lock.unlock()
    }

    private func markSuccessfulCapture(_ key: String) {
        lock.lock()
        let now = Date()
        lastSuccessfulCaptureDatesByKey[key] = now
        pruneSuccessfulCaptureDates(now: now)
        lock.unlock()
    }

    private func pruneSuccessfulCaptureDates(now: Date) {
        let cutoff = now.addingTimeInterval(-60)
        lastSuccessfulCaptureDatesByKey = lastSuccessfulCaptureDatesByKey.filter { _, date in
            date >= cutoff
        }

        guard lastSuccessfulCaptureDatesByKey.count > 300 else { return }

        let newestEntries = lastSuccessfulCaptureDatesByKey
            .sorted { lhs, rhs in lhs.value > rhs.value }
            .prefix(300)
            .map { ($0.key, $0.value) }

        lastSuccessfulCaptureDatesByKey = Dictionary(uniqueKeysWithValues: newestEntries)
    }

    private func inFlightKey(for identity: PreviewIdentity) -> String {
        identity.stableKey
    }

    private func postPreview(_ image: NSImage, for request: PreviewRequest) {
        DispatchQueue.main.async(execute: {
            NotificationCenter.default.post(
                name: .windowPreviewDidLoad,
                object: WindowPreviewUpdate(
                    windowID: request.windowID,
                    ownerPID: request.ownerPID,
                    previewIdentity: request.previewIdentity,
                    title: request.title,
                    bounds: request.bounds,
                    image: image,
                    selectionGeneration: request.selectionGeneration
                )
            )
        })
    }

    private func storePreview(
        _ image: NSImage,
        for identity: PreviewIdentity,
        storeInVolatileMemory: Bool
    ) {
        if storeInVolatileMemory {
            storeInMemory(image, for: identity)
        }
        previewImageStore.store(image, for: identity)
        scheduleDiskCleanupIfNeeded()
    }

    private func scheduleDiskCleanupIfNeeded() {
        lock.lock()
        successfulPreviewStoreCountSinceCleanup += 1

        let now = Date()
        let shouldCleanup = successfulPreviewStoreCountSinceCleanup >= diskCleanupStoreInterval
            || now.timeIntervalSince(lastDiskCleanupDate) >= diskCleanupTimeInterval

        guard shouldCleanup, !isDiskCleanupInProgress else {
            lock.unlock()
            return
        }

        successfulPreviewStoreCountSinceCleanup = 0
        lastDiskCleanupDate = now
        isDiskCleanupInProgress = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            let removedCount = self.previewImageStore.cleanup(
                maximumImageCount: self.diskCleanupMaximumImageCount,
                maximumAge: self.diskCleanupMaximumAge
            )

            self.lock.lock()
            self.isDiskCleanupInProgress = false
            self.lock.unlock()

            WLLog.preview.debug("Disk preview cache cleanup completed, removed \(removedCount) file(s)")
        }
    }

    private func storeInMemory(_ image: NSImage, for identity: PreviewIdentity) {
        let cost = Self.cacheCost(for: image)
        for key in identity.cacheKeys {
            cache.setObject(image, forKey: key as NSString, cost: cost)
        }
    }

    private static func cacheCost(for image: NSImage) -> Int {
        max(1, Int(image.size.width * image.size.height * 4))
    }

    private static func captureWindowImage(_ window: SCWindow, sourceSize: CGSize) async throws -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCScreenshotConfiguration()
        let outputSize = pixelSize(for: sourceSize)
        configuration.width = outputSize.width
        configuration.height = outputSize.height
        configuration.ignoreShadows = true
        // Electron (Cursor) often composites a blank child surface that shows up as a
        // solid white half-panel when included — capture the top-level window only.
        configuration.includeChildWindows = false
        configuration.showsCursor = false

        let output = try await SCScreenshotManager.captureScreenshot(
            contentFilter: filter,
            configuration: configuration
        )

        guard let image = output.sdrImage ?? output.hdrImage else { return nil }
        let thumbnail = downsample(image) ?? image
        return NSImage(
            cgImage: thumbnail,
            size: NSSize(width: CGFloat(thumbnail.width), height: CGFloat(thumbnail.height))
        )
    }

    private struct PreviewQuality {
        let averageLuma: Double
        let variance: Double
        let whitePixelRatio: Double
        let blackPixelRatio: Double
        let transparentPixelRatio: Double
        let averageAlpha: Double
        let edgeScore: Double
        /// Absolute difference between left-half and right-half white ratios (0…1).
        let whiteAsymmetry: Double

        var score: Double {
            let structure = min(1.0, variance * 42 + edgeScore * 9)
            let solidSurfacePenalty = max(whitePixelRatio, blackPixelRatio) * 0.18
            let alphaPenalty = transparentPixelRatio * 0.32
            let halfPanelPenalty = whiteAsymmetry > 0.35 ? whiteAsymmetry * 0.22 : 0
            return max(0.0, min(1.0, structure + 0.08 - solidSurfacePenalty - alphaPenalty - halfPanelPenalty))
        }

        var debugSummary: String {
            String(
                format: "luma=%.3f var=%.6f white=%.2f black=%.2f transparent=%.2f alpha=%.3f edge=%.4f asym=%.2f score=%.3f",
                averageLuma,
                variance,
                whitePixelRatio,
                blackPixelRatio,
                transparentPixelRatio,
                averageAlpha,
                edgeScore,
                whiteAsymmetry,
                score
            )
        }
    }

    private static func previewQuality(for image: NSImage) -> PreviewQuality {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return PreviewQuality(
                averageLuma: 1,
                variance: 0,
                whitePixelRatio: 1,
                blackPixelRatio: 0,
                transparentPixelRatio: 1,
                averageAlpha: 0,
                edgeScore: 0,
                whiteAsymmetry: 0
            )
        }

        let sampleWidth = 32
        let sampleHeight = 32
        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return PreviewQuality(
                averageLuma: 0,
                variance: 0,
                whitePixelRatio: 0,
                blackPixelRatio: 1,
                transparentPixelRatio: 1,
                averageAlpha: 0,
                edgeScore: 0,
                whiteAsymmetry: 0
            )
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        let pixelCount = sampleWidth * sampleHeight
        var lumaValues = [Double]()
        lumaValues.reserveCapacity(pixelCount)
        var alphaTotal = 0.0
        var whitePixels = 0
        var blackPixels = 0
        var transparentPixels = 0
        var leftWhite = 0
        var rightWhite = 0
        var leftCount = 0
        var rightCount = 0
        let midX = sampleWidth / 2

        for y in 0..<sampleHeight {
            for x in 0..<sampleWidth {
                let byteIndex = (y * sampleWidth + x) * bytesPerPixel
                let red = Double(pixels[byteIndex]) / 255.0
                let green = Double(pixels[byteIndex + 1]) / 255.0
                let blue = Double(pixels[byteIndex + 2]) / 255.0
                let alpha = Double(pixels[byteIndex + 3]) / 255.0
                let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                lumaValues.append(luma)
                alphaTotal += alpha

                let isWhite = alpha >= 0.05 && luma > 0.94
                if alpha < 0.05 {
                    transparentPixels += 1
                } else if isWhite {
                    whitePixels += 1
                } else if luma < 0.06 {
                    blackPixels += 1
                }

                if x < midX {
                    leftCount += 1
                    if isWhite { leftWhite += 1 }
                } else {
                    rightCount += 1
                    if isWhite { rightWhite += 1 }
                }
            }
        }

        var edgeTotal = 0.0
        var edgeCount = 0
        for y in 0..<sampleHeight {
            for x in 0..<sampleWidth {
                let index = y * sampleWidth + x
                let luma = lumaValues[index]
                if x + 1 < sampleWidth {
                    edgeTotal += abs(luma - lumaValues[index + 1])
                    edgeCount += 1
                }
                if y + 1 < sampleHeight {
                    edgeTotal += abs(luma - lumaValues[index + sampleWidth])
                    edgeCount += 1
                }
            }
        }

        let leftWhiteRatio = leftCount == 0 ? 0 : Double(leftWhite) / Double(leftCount)
        let rightWhiteRatio = rightCount == 0 ? 0 : Double(rightWhite) / Double(rightCount)
        let averageAlpha = alphaTotal / Double(pixelCount)
        let averageLuma = lumaValues.reduce(0, +) / Double(pixelCount)
        let variance = lumaValues.reduce(0.0) { partial, luma in
            let delta = luma - averageLuma
            return partial + delta * delta
        } / Double(pixelCount)

        return PreviewQuality(
            averageLuma: averageLuma,
            variance: variance,
            whitePixelRatio: Double(whitePixels) / Double(pixelCount),
            blackPixelRatio: Double(blackPixels) / Double(pixelCount),
            transparentPixelRatio: Double(transparentPixels) / Double(pixelCount),
            averageAlpha: averageAlpha,
            edgeScore: edgeCount == 0 ? 0 : edgeTotal / Double(edgeCount),
            whiteAsymmetry: abs(leftWhiteRatio - rightWhiteRatio)
        )
    }

    private static func previewRejectionReason(
        quality: PreviewQuality,
        cachedQuality: PreviewQuality?,
        appName: String?
    ) -> String? {
        let isFinder = appName?.localizedCaseInsensitiveCompare("Finder") == .orderedSame
        let whiteRatioThreshold = isFinder ? 0.76 : 0.88
        let lowVarianceThreshold = isFinder ? 0.00034 : 0.00018
        let lowEdgeThreshold = isFinder ? 0.018 : 0.010

        if quality.averageAlpha < 0.04 || quality.transparentPixelRatio > 0.92 {
            return String(format: "transparent alpha=%.3f transparent=%.2f", quality.averageAlpha, quality.transparentPixelRatio)
        }

        // Cursor/Electron sometimes composites a blank child into one half of the frame.
        if quality.whiteAsymmetry > 0.38, max(quality.whitePixelRatio, 1 - quality.whitePixelRatio) > 0.28 {
            return String(format: "half-panel-white asym=%.2f white=%.2f", quality.whiteAsymmetry, quality.whitePixelRatio)
        }

        if quality.whitePixelRatio > whiteRatioThreshold && quality.edgeScore < (isFinder ? 0.030 : 0.018) {
            return String(format: "mostly-white white=%.2f edge=%.4f", quality.whitePixelRatio, quality.edgeScore)
        }

        if quality.blackPixelRatio > 0.92 && quality.edgeScore < 0.016 {
            return String(format: "mostly-black black=%.2f edge=%.4f", quality.blackPixelRatio, quality.edgeScore)
        }

        if quality.variance < lowVarianceThreshold && quality.edgeScore < lowEdgeThreshold {
            return String(format: "low-detail variance=%.6f edge=%.4f", quality.variance, quality.edgeScore)
        }

        if let cachedQuality, cachedQuality.score > 0.08 {
            let worseThanCache = quality.score < cachedQuality.score * (isFinder ? 0.56 : 0.38)
            let lostDetail = quality.edgeScore < cachedQuality.edgeScore * 0.55
                && quality.variance < cachedQuality.variance * 0.62
            let finderWhiteRegression = isFinder
                && quality.whitePixelRatio > 0.58
                && quality.whitePixelRatio > cachedQuality.whitePixelRatio + 0.28

            if worseThanCache && (lostDetail || finderWhiteRegression) {
                return String(
                    format: "worse-than-cache score=%.3f cached=%.3f edge=%.4f cachedEdge=%.4f",
                    quality.score,
                    cachedQuality.score,
                    quality.edgeScore,
                    cachedQuality.edgeScore
                )
            }
        }

        return nil
    }

    private static func pixelSize(for sourceSize: CGSize) -> (width: Int, height: Int) {
        guard sourceSize.width > 1, sourceSize.height > 1 else {
            return (Int(maximumPixelSize.width), Int(maximumPixelSize.height))
        }

        let backingScale = max(NSScreen.screens.map(\.backingScaleFactor).max() ?? 2.0, 1.0)
        let scale = min(
            maximumPixelSize.width / sourceSize.width,
            maximumPixelSize.height / sourceSize.height,
            backingScale
        )

        return (
            max(1, Int((sourceSize.width * scale).rounded(.up))),
            max(1, Int((sourceSize.height * scale).rounded(.up)))
        )
    }

    private static func downsample(_ image: CGImage) -> CGImage? {
        let sourceSize = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        guard sourceSize.width > maximumPixelSize.width || sourceSize.height > maximumPixelSize.height else {
            return image
        }

        let scale = min(
            maximumPixelSize.width / sourceSize.width,
            maximumPixelSize.height / sourceSize.height
        )
        let pixelWidth = max(1, Int(sourceSize.width * scale))
        let pixelHeight = max(1, Int(sourceSize.height * scale))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return context.makeImage()
    }
}

private final class PreviewImageStore: @unchecked Sendable {
    private let directoryURL: URL
    private let legacyDirectoryURL: URL
    private let fileManager: FileManager

    init() {
        let fileManager = FileManager.default
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.directoryURL = applicationSupport
            .appendingPathComponent("WindowLens", isDirectory: true)
            .appendingPathComponent("PreviewCache", isDirectory: true)
        self.legacyDirectoryURL = applicationSupport
            .appendingPathComponent("BetterTabbing", isDirectory: true)
            .appendingPathComponent("PreviewCache", isDirectory: true)

        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        migrateLegacyCacheIfNeeded()
    }

    func image(for identity: PreviewIdentity) -> NSImage? {
        for key in identity.cacheKeys {
            let url = fileURL(forKey: key)
            guard fileManager.fileExists(atPath: url.path) else { continue }

            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let modificationDate = attributes[FileAttributeKey.modificationDate] as? Date else {
                return NSImage(contentsOf: url)
            }

            if Date().timeIntervalSince(modificationDate) > 7 * 24 * 60 * 60 {
                try? fileManager.removeItem(at: url)
                continue
            }

            guard let image = NSImage(contentsOf: url) else { continue }
            touchFiles(for: identity)
            return image
        }

        return nil
    }

    func store(_ image: NSImage, for identity: PreviewIdentity) {
        guard let data = jpegData(for: image) else { return }
        for key in identity.cacheKeys {
            try? data.write(to: fileURL(forKey: key), options: .atomic)
        }
    }

    func cleanup(maximumImageCount: Int, maximumAge: TimeInterval) -> Int {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        let now = Date()
        let entries = files.compactMap { url -> (url: URL, date: Date)? in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let date = values?.contentModificationDate else { return nil }
            return (url, date)
        }

        var removedCount = 0
        for entry in entries where now.timeIntervalSince(entry.date) > maximumAge {
            if (try? fileManager.removeItem(at: entry.url)) != nil {
                removedCount += 1
            }
        }

        let remaining = entries
            .filter { now.timeIntervalSince($0.date) <= maximumAge }
            .sorted { $0.date > $1.date }

        for entry in remaining.dropFirst(maximumImageCount) {
            if (try? fileManager.removeItem(at: entry.url)) != nil {
                removedCount += 1
            }
        }

        return removedCount
    }

    private func touchFiles(for identity: PreviewIdentity) {
        let now = Date()
        for key in identity.cacheKeys {
            let url = fileURL(forKey: key)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try? fileManager.setAttributes([FileAttributeKey.modificationDate: now], ofItemAtPath: url.path)
        }
    }

    private func fileURL(forKey key: String) -> URL {
        let fileName = "\(PreviewIdentity.stableHashHex(key)).jpg"
        return directoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    private func migrateLegacyCacheIfNeeded() {
        guard legacyDirectoryURL != directoryURL,
              fileManager.fileExists(atPath: legacyDirectoryURL.path),
              let legacyFiles = try? fileManager.contentsOfDirectory(
                at: legacyDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return
        }

        for legacyFile in legacyFiles where legacyFile.pathExtension.lowercased() == "jpg" {
            let destination = directoryURL.appendingPathComponent(legacyFile.lastPathComponent, isDirectory: false)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.copyItem(at: legacyFile, to: destination)
        }
    }

    private func jpegData(for image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.82]
        )
    }
}

private actor CaptureLimiter {
    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        availablePermits = max(1, limit)
    }

    func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            availablePermits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

extension Notification.Name {
    static let windowPreviewDidLoad = Notification.Name("windowPreviewDidLoad")
}
