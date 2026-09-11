import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Focus a specific window by `CGWindowID`, including windows on other Spaces.
///
/// Proven sequence on this machine:
/// 1. `CGSManagedDisplaySetCurrentSpace` for the window's Space
/// 2. `_SLPSSetFrontProcessWithOptions` + Hammerspoon make-key events
///
/// Synthetic Dock-swipe was tried for a native slide but does not move Spaces
/// here; keep Space hops on CGS until a working gesture path is verified.
enum WindowFocusBridge {
    typealias CGSConnectionID = Int32
    typealias CGSSpaceID = UInt64

    private typealias SLPSPostEventRecordToFn = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>,
        UnsafeMutableRawPointer
    ) -> Int32

    private typealias SLPSSetFrontProcessWithOptionsFn = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>,
        UInt32,
        UInt32
    ) -> Int32

    private typealias CGSMainConnectionIDFn = @convention(c) () -> CGSConnectionID
    private typealias CGSGetActiveSpaceFn = @convention(c) (CGSConnectionID) -> CGSSpaceID
    private typealias CGSCopySpacesForWindowsFn = @convention(c) (
        CGSConnectionID,
        UInt32,
        CFArray
    ) -> Unmanaged<CFArray>?
    private typealias CGSManagedDisplaySetCurrentSpaceFn = @convention(c) (
        CGSConnectionID,
        CFString,
        CGSSpaceID
    ) -> Void
    private typealias GetProcessForPIDFn = @convention(c) (
        pid_t,
        UnsafeMutablePointer<ProcessSerialNumber>
    ) -> OSStatus

    private static let cpsUserGenerated: UInt32 = 0x200
    private static let allSpacesMask: UInt32 = (1 << 0) | (1 << 1) | (1 << 2)

    private nonisolated(unsafe) static let skyLightHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    }()

    private static let postEventFn: SLPSPostEventRecordToFn? = { symbol("SLPSPostEventRecordTo") }()
    private static let setFrontFn: SLPSSetFrontProcessWithOptionsFn? = {
        symbol("_SLPSSetFrontProcessWithOptions")
    }()
    private static let mainConnectionFn: CGSMainConnectionIDFn? = { symbol("CGSMainConnectionID") }()
    private static let activeSpaceFn: CGSGetActiveSpaceFn? = { symbol("CGSGetActiveSpace") }()
    private static let copySpacesFn: CGSCopySpacesForWindowsFn? = { symbol("CGSCopySpacesForWindows") }()
    private static let setCurrentSpaceFn: CGSManagedDisplaySetCurrentSpaceFn? = {
        symbol("CGSManagedDisplaySetCurrentSpace")
    }()
    private static let getProcessForPIDFn: GetProcessForPIDFn? = {
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID") {
            return unsafeBitCast(sym, to: GetProcessForPIDFn.self)
        }
        return nil
    }()

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle = skyLightHandle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    /// Switch to the window's Space (CGS) then SLPS-focus. Completion runs on the calling
    /// queue after the hop (main if called from main).
    static func focusWindow(
        pid: pid_t,
        windowID: CGWindowID,
        completion: @escaping @Sendable (_ ok: Bool) -> Void
    ) {
        let ok = focusWindowSync(pid: pid, windowID: windowID)
        DispatchQueue.main.async { completion(ok) }
    }

    @discardableResult
    static func focusWindowSync(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard windowID != 0, pid > 0 else { return false }

        let cid = mainConnectionFn?() ?? 0
        let activeBefore = cid != 0 ? activeSpaceFn?(cid) ?? 0 : 0
        let windowSpaces = spaces(for: windowID, connection: cid)
        _ = switchToSpaceCGS(
            windowSpaces: windowSpaces,
            activeSpace: activeBefore,
            connection: cid
        )

        return focusWindowOnCurrentSpace(pid: pid, windowID: windowID)
    }

    /// SLPS make-key only.
    @discardableResult
    static func focusWindowOnCurrentSpace(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard windowID != 0, pid > 0 else { return false }
        guard let setFront = setFrontFn,
              let postEvent = postEventFn,
              let getPSN = getProcessForPIDFn else {
            WLLog.switcher.error("WindowFocusBridge: SkyLight SLPS symbols unavailable")
            return false
        }

        _ = mainConnectionFn?()

        var psn = ProcessSerialNumber()
        let psnStatus = getPSN(pid, &psn)
        guard psnStatus == noErr, psn.lowLongOfPSN != 0 || psn.highLongOfPSN != 0 else {
            WLLog.switcher.error("WindowFocusBridge: GetProcessForPID failed pid=\(pid) status=\(psnStatus)")
            return false
        }

        let frontStatus = setFront(&psn, windowID, cpsUserGenerated)
        postMakeKeyEvent(postEvent: postEvent, psn: &psn, windowID: windowID, code: 0x01)
        postMakeKeyEvent(postEvent: postEvent, psn: &psn, windowID: windowID, code: 0x02)
        return frontStatus == 0
    }

    @discardableResult
    private static func switchToSpaceCGS(
        windowSpaces: [CGSSpaceID],
        activeSpace: CGSSpaceID,
        connection: CGSConnectionID
    ) -> Bool {
        guard connection != 0,
              let setCurrentSpace = setCurrentSpaceFn,
              let target = windowSpaces.first(where: { $0 != 0 && $0 != activeSpace })
                ?? windowSpaces.first,
              target != 0,
              target != activeSpace,
              let displayUUID = mainDisplayUUIDString() else {
            return false
        }

        setCurrentSpace(connection, displayUUID, target)
        return true
    }

    private static func spaces(for windowID: CGWindowID, connection: CGSConnectionID) -> [CGSSpaceID] {
        guard connection != 0, let copySpaces = copySpacesFn else { return [] }
        let array = [NSNumber(value: windowID)] as CFArray
        guard let unmanaged = copySpaces(connection, allSpacesMask, array) else { return [] }
        let values = unmanaged.takeRetainedValue() as? [NSNumber] ?? []
        return values.map(\.uint64Value)
    }

    private static func mainDisplayUUIDString() -> CFString? {
        let displayID = CGMainDisplayID()
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid)
    }

    private static func postMakeKeyEvent(
        postEvent: SLPSPostEventRecordToFn,
        psn: inout ProcessSerialNumber,
        windowID: CGWindowID,
        code: UInt8
    ) {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x08] = code
        bytes[0x3a] = 0x10
        for i in 0x20..<0x30 {
            bytes[i] = 0xff
        }
        var wid = windowID
        withUnsafeBytes(of: &wid) { source in
            bytes.withUnsafeMutableBytes { destination in
                guard let src = source.baseAddress,
                      let dst = destination.baseAddress else { return }
                dst.advanced(by: 0x3c).copyMemory(from: src, byteCount: MemoryLayout<CGWindowID>.size)
            }
        }
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = postEvent(&psn, base)
        }
    }
}
