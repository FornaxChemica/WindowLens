import AppKit
import ApplicationServices

struct DockProcessSwitcherSelection {
    let pid: pid_t?
    let bundleIdentifier: String?
    let title: String?
    let bundleURL: URL?
    let frame: CGRect?
    let switcherFrame: CGRect?
}

final class DockProcessSwitcherObserver: NSObject {
    var onSelectionChanged: ((DockProcessSwitcherSelection) -> Void)?
    var onSwitcherDestroyed: (() -> Void)?

    private var observer: AXObserver?
    private var dockElement: AXUIElement?
    private var switcherListElement: AXUIElement?
    private var discoveryTimer: Timer?
    private var loggedDiscoveryMiss = false
    private let discoveryInterval: TimeInterval = 0.035

    private(set) var hasDeliveredSelection = false
    private(set) var selectionVersion: UInt64 = 0
    private var lastEmittedSelectionKey: String?

    func start() {
        stop()
        hasDeliveredSelection = false
        lastEmittedSelectionKey = nil

        guard AXIsProcessTrusted() else {
            WLLog.app.error("Accessibility is not trusted")
            return
        }

        guard let dock = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else {
            WLLog.app.error("Dock process not found")
            return
        }

        let dockPID = dock.processIdentifier
        dockElement = AXUIElementCreateApplication(dockPID)

        var createdObserver: AXObserver?
        let createResult = AXObserverCreate(
            dockPID,
            { _, element, notification, refcon in
                guard let refcon else { return }
                let observer = Unmanaged<DockProcessSwitcherObserver>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                observer.handleAXNotification(notification as String, element: element)
            },
            &createdObserver
        )

        guard createResult == .success, let createdObserver else {
            WLLog.app.error("AXObserverCreate failed: \(createResult.rawValue)")
            return
        }

        observer = createdObserver
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(createdObserver),
            .commonModes
        )

        discoverSwitcherListOrRetry()
    }

    func stop() {
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        loggedDiscoveryMiss = false
        hasDeliveredSelection = false
        lastEmittedSelectionKey = nil

        if let observer, let switcherListElement {
            AXObserverRemoveNotification(
                observer,
                switcherListElement,
                kAXSelectedChildrenChangedNotification as CFString
            )
            AXObserverRemoveNotification(
                observer,
                switcherListElement,
                kAXUIElementDestroyedNotification as CFString
            )
        }

        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }

        observer = nil
        dockElement = nil
        switcherListElement = nil
    }

    private func discoverSwitcherListOrRetry() {
        _ = installOnCurrentSwitcherList()

        discoveryTimer?.invalidate()
        discoveryTimer = Timer(
            timeInterval: discoveryInterval,
            target: self,
            selector: #selector(handleDiscoveryTimer(_:)),
            userInfo: nil,
            repeats: true
        )
        if let discoveryTimer {
            RunLoop.main.add(discoveryTimer, forMode: .common)
        }
    }

    @objc private func handleDiscoveryTimer(_ timer: Timer) {
        if installOnCurrentSwitcherList() {
            return
        }

        if !loggedDiscoveryMiss {
            loggedDiscoveryMiss = true
            WLLog.app.debug("Waiting for Dock AXProcessSwitcherList during Cmd+Tab session")
        }
    }

    private func installOnCurrentSwitcherList() -> Bool {
        guard let observer, let dockElement else { return false }
        if switcherListElement != nil {
            return true
        }

        guard let switcherList = findProcessSwitcherList(in: dockElement, remainingDepth: 9) else { return false }

        if let existing = switcherListElement {
            if CFEqual(existing, switcherList) {
                return true
            }

            AXObserverRemoveNotification(
                observer,
                existing,
                kAXSelectedChildrenChangedNotification as CFString
            )
            AXObserverRemoveNotification(
                observer,
                existing,
                kAXUIElementDestroyedNotification as CFString
            )
        }

        switcherListElement = switcherList
        let selectionResult = AXObserverAddNotification(
            observer,
            switcherList,
            kAXSelectedChildrenChangedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )
        let destroyedResult = AXObserverAddNotification(
            observer,
            switcherList,
            kAXUIElementDestroyedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )

        guard notificationResultIsUsable(selectionResult),
              notificationResultIsUsable(destroyedResult) else {
            WLLog.app.error("AXObserverAddNotification failed: selected=\(selectionResult.rawValue) destroyed=\(destroyedResult.rawValue)")
            return false
        }

        loggedDiscoveryMiss = false
        WLLog.app.debug("Observing Dock AXProcessSwitcherList")
        emitCurrentSelection(from: switcherList)
        return true
    }

    private func notificationResultIsUsable(_ result: AXError) -> Bool {
        result == .success || result == .notificationAlreadyRegistered
    }

    private func handleAXNotification(_ notification: String, element: AXUIElement) {
        switch notification {
        case kAXSelectedChildrenChangedNotification:
            emitCurrentSelection(from: element)
        case kAXUIElementDestroyedNotification:
            switcherListElement = nil
            onSwitcherDestroyed?()
        default:
            return
        }
    }

    private func emitCurrentSelection(from switcherList: AXUIElement) {
        guard let selectedChild = selectedChild(in: switcherList) else { return }
        let selection = selection(
            from: selectedChild,
            switcherFrame: frame(for: switcherList)
        )

        let selectionKey = "\(selection.pid.map(String.init) ?? "nil")|\(selection.bundleIdentifier ?? "")"
        if hasDeliveredSelection, selectionKey == lastEmittedSelectionKey {
            return
        }
        lastEmittedSelectionKey = selectionKey

        hasDeliveredSelection = true
        selectionVersion &+= 1
        onSelectionChanged?(selection)
    }

    private func selectedChild(in switcherList: AXUIElement) -> AXUIElement? {
        guard let selectedChildren = elementArrayAttribute(kAXSelectedChildrenAttribute, from: switcherList) else {
            return nil
        }

        return selectedChildren.first
    }

    private func selection(from element: AXUIElement, switcherFrame: CGRect?) -> DockProcessSwitcherSelection {
        let title = directTitle(for: element) ?? bestTitle(for: element, remainingDepth: 2)
        let bundleURL = urlAttribute(kAXURLAttribute, from: element) ?? bestURL(for: element, remainingDepth: 2)
        let bundleIdentifier = bundleURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        let pid = resolveRunningApplicationPID(
            title: title,
            bundleIdentifier: bundleIdentifier,
            bundleURL: bundleURL
        )

        return DockProcessSwitcherSelection(
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            title: title,
            bundleURL: bundleURL,
            frame: frame(for: element),
            switcherFrame: switcherFrame
        )
    }

    private func findProcessSwitcherList(in element: AXUIElement, remainingDepth: Int) -> AXUIElement? {
        if stringAttribute(kAXSubroleAttribute, from: element) == "AXProcessSwitcherList" {
            return element
        }

        guard remainingDepth > 0 else { return nil }

        for attribute in [kAXVisibleChildrenAttribute, kAXChildrenAttribute, kAXContentsAttribute] {
            guard let children = elementArrayAttribute(attribute, from: element) else { continue }
            for child in children {
                if let match = findProcessSwitcherList(in: child, remainingDepth: remainingDepth - 1) {
                    return match
                }
            }
        }

        return nil
    }

    private func directTitle(for element: AXUIElement) -> String? {
        if let title = stringAttribute(kAXTitleAttribute, from: element), !title.isEmpty {
            return title
        }

        if let description = stringAttribute(kAXDescriptionAttribute, from: element), !description.isEmpty {
            return description
        }

        return nil
    }

    private func bestTitle(for element: AXUIElement, remainingDepth: Int) -> String? {
        guard remainingDepth > 0 else { return nil }

        if let directTitle = directTitle(for: element) {
            return directTitle
        }

        for attribute in [kAXChildrenAttribute, kAXVisibleChildrenAttribute, kAXContentsAttribute] {
            guard let children = elementArrayAttribute(attribute, from: element) else { continue }
            for child in children {
                if let title = bestTitle(for: child, remainingDepth: remainingDepth - 1), !title.isEmpty {
                    return title
                }
            }
        }

        return nil
    }

    private func bestURL(for element: AXUIElement, remainingDepth: Int) -> URL? {
        guard remainingDepth > 0 else { return nil }

        if let url = urlAttribute(kAXURLAttribute, from: element) {
            return url
        }

        for attribute in [kAXChildrenAttribute, kAXVisibleChildrenAttribute, kAXContentsAttribute] {
            guard let children = elementArrayAttribute(attribute, from: element) else { continue }
            for child in children {
                if let url = bestURL(for: child, remainingDepth: remainingDepth - 1) {
                    return url
                }
            }
        }

        return nil
    }

    private func resolveRunningApplicationPID(
        title: String?,
        bundleIdentifier: String?,
        bundleURL: URL?
    ) -> pid_t? {
        let runningApplications = NSWorkspace.shared.runningApplications

        if let bundleIdentifier,
           let app = runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return app.processIdentifier
        }

        if let bundleURL {
            let standardizedURL = bundleURL.standardizedFileURL
            if let app = runningApplications.first(where: { $0.bundleURL?.standardizedFileURL == standardizedURL }) {
                return app.processIdentifier
            }
        }

        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }

        let normalizedTitle = normalized(title)
        if let exactMatch = runningApplications.first(where: { normalized($0.localizedName ?? "") == normalizedTitle }) {
            return exactMatch.processIdentifier
        }

        return runningApplications.first { app in
            let appName = normalized(app.localizedName ?? "")
            return !appName.isEmpty && (normalizedTitle.contains(appName) || appName.contains(normalizedTitle))
        }?.processIdentifier
    }

    private func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func frame(for element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute, from: element),
              let size = sizeAttribute(kAXSizeAttribute, from: element) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func copyAttribute(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        copyAttribute(attribute, from: element) as? String
    }

    private func urlAttribute(_ attribute: String, from element: AXUIElement) -> URL? {
        if let url = copyAttribute(attribute, from: element) as? URL {
            return url
        }

        if let string = copyAttribute(attribute, from: element) as? String {
            if let url = URL(string: string), url.isFileURL {
                return url
            }
            return URL(fileURLWithPath: string)
        }

        return nil
    }

    private func elementArrayAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement]? {
        copyAttribute(attribute, from: element) as? [AXUIElement]
    }

    private func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        AXValueGetValue(axValue, .cgPoint, &point)
        return point
    }

    private func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        AXValueGetValue(axValue, .cgSize, &size)
        return size
    }
}
