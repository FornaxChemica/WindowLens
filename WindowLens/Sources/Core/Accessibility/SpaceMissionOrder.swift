import CoreGraphics
import Darwin
import Foundation

/// Mission Control left→right Space order via SkyLight (no SIP).
enum SpaceMissionOrder {
    typealias CGSConnectionID = Int32
    typealias CGSSpaceID = UInt64

    private typealias CGSMainConnectionIDFn = @convention(c) () -> CGSConnectionID
    private typealias CGSCopySpacesForWindowsFn = @convention(c) (
        CGSConnectionID,
        UInt32,
        CFArray
    ) -> Unmanaged<CFArray>?
    private typealias CGSCopyManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
    private typealias CGSGetActiveSpaceFn = @convention(c) (CGSConnectionID) -> CGSSpaceID

    /// includesCurrent | includesOthers | includesUser
    private static let allSpacesMask: UInt32 = (1 << 0) | (1 << 1) | (1 << 2)

    private nonisolated(unsafe) static let skyLightHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    }()

    private static let mainConnectionFn: CGSMainConnectionIDFn? = { symbol("CGSMainConnectionID") }()
    private static let copySpacesFn: CGSCopySpacesForWindowsFn? = { symbol("CGSCopySpacesForWindows") }()
    private static let copyManagedSpacesFn: CGSCopyManagedDisplaySpacesFn? = {
        symbol("CGSCopyManagedDisplaySpaces")
    }()
    private static let activeSpaceFn: CGSGetActiveSpaceFn? = { symbol("CGSGetActiveSpace") }()

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle = skyLightHandle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    /// Sort items to match Mission Control order (Desktop 1 → fullscreen apps → …).
    static func sortedBySpaceOrder<T>(
        _ items: [T],
        windowID: (T) -> CGWindowID
    ) -> [T] {
        let ranks = spaceRanks()
        guard !ranks.isEmpty else { return items }

        return items.enumerated().sorted { lhs, rhs in
            let leftID = windowID(lhs.element)
            let rightID = windowID(rhs.element)
            let leftRank = primarySpace(for: leftID).flatMap { ranks[$0] } ?? Int.max
            let rightRank = primarySpace(for: rightID).flatMap { ranks[$0] } ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func spaceRanks() -> [CGSSpaceID: Int] {
        let ordered = orderedSpaceIDs()
        guard !ordered.isEmpty else { return [:] }
        var ranks: [CGSSpaceID: Int] = [:]
        for (index, spaceID) in ordered.enumerated() {
            ranks[spaceID] = index
        }
        return ranks
    }

    private static func orderedSpaceIDs() -> [CGSSpaceID] {
        guard let cid = mainConnectionFn?(),
              let copyManaged = copyManagedSpacesFn,
              let unmanaged = copyManaged(cid) else { return [] }
        let displays = unmanaged.takeRetainedValue() as? [[String: Any]] ?? []
        let active = activeSpaceFn?(cid) ?? 0

        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            let ids: [CGSSpaceID] = spaces.compactMap { space in
                (space["ManagedSpaceID"] as? NSNumber)?.uint64Value
            }
            if active == 0 || ids.contains(active) {
                return ids
            }
        }

        return (displays.first?["Spaces"] as? [[String: Any]])?.compactMap { space in
            (space["ManagedSpaceID"] as? NSNumber)?.uint64Value
        } ?? []
    }

    private static func primarySpace(for windowID: CGWindowID) -> CGSSpaceID? {
        guard windowID != 0,
              let cid = mainConnectionFn?(),
              let copySpaces = copySpacesFn else { return nil }
        let array = [NSNumber(value: windowID)] as CFArray
        guard let unmanaged = copySpaces(cid, allSpacesMask, array) else { return nil }
        let values = unmanaged.takeRetainedValue() as? [NSNumber] ?? []
        return values.map(\.uint64Value).first { $0 != 0 }
    }
}
