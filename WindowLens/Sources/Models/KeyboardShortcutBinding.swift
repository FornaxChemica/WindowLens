import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct KeyboardShortcutBinding: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: Set<ModifierKey>

    init(keyCode: UInt16, modifiers: Set<ModifierKey> = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var displayString: String {
        let modifierText = ModifierKey.displayOrder
            .filter { modifiers.contains($0) }
            .map(\.symbol)
            .joined(separator: " ")
        let keyText = Self.keyDisplayName(for: keyCode)
        if modifierText.isEmpty {
            return keyText
        }
        return "\(modifierText) \(keyText)"
    }

    var primaryModifier: ModifierKey? {
        ModifierKey.displayOrder.first { modifiers.contains($0) }
    }

    func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard keyCode == self.keyCode else { return false }
        return Self.activeModifiers(from: flags) == modifiers
    }

    func matchesModifierOnly(_ flags: CGEventFlags, expected: ModifierKey) -> Bool {
        Self.activeModifiers(from: flags) == [expected]
    }

    static func activeModifiers(from flags: CGEventFlags) -> Set<ModifierKey> {
        var result = Set<ModifierKey>()
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        return result
    }

    static func keyDisplayName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Tab: return "TAB"
        case kVK_Space: return "Space"
        case kVK_Return, kVK_ANSI_KeypadEnter: return "Return"
        case kVK_Escape: return "Escape"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Fwd Del"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            if let translated = translateKeyCode(keyCode) {
                return translated
            }
            return "Key \(keyCode)"
        }
    }

    /// Layout-aware letter/digit/punctuation for the current keyboard.
    private static func translateKeyCode(_ keyCode: UInt16) -> String? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length: Int = 0

        let keyboard = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let layoutData = keyboard.flatMap {
            TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData)
        }.map { Unmanaged<CFData>.fromOpaque($0).takeUnretainedValue() as Data }

        guard let layoutData else { return ansiFallbackName(for: keyCode) }

        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }

        guard status == noErr, length > 0 else {
            return ansiFallbackName(for: keyCode)
        }

        let raw = String(utf16CodeUnits: chars, count: length)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return ansiFallbackName(for: keyCode) }
        return raw.uppercased()
    }

    private static func ansiFallbackName(for keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Grave: return "`"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        default: return nil
        }
    }
}

enum ShortcutAction: String, CaseIterable, Codable {
    case windowHistoryBack
    case windowHistoryForward
    case windowSlotModifier
    case workspaceOpen
    case resourceMonitorToggle
    case usageHeatmapOpen
    case stayAwakeToggle

    var defaultBinding: KeyboardShortcutBinding {
        switch self {
        case .windowHistoryBack:
            return KeyboardShortcutBinding(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command, .shift])
        case .windowHistoryForward:
            return KeyboardShortcutBinding(keyCode: UInt16(kVK_ANSI_Grave), modifiers: [.command, .shift])
        case .windowSlotModifier:
            return KeyboardShortcutBinding(keyCode: UInt16(kVK_ANSI_1), modifiers: [.control])
        case .workspaceOpen:
            return KeyboardShortcutBinding(keyCode: UInt16(kVK_Tab), modifiers: [.option])
        case .resourceMonitorToggle:
            return KeyboardShortcutBinding(keyCode: UInt16(kVK_ANSI_E), modifiers: [])
        case .usageHeatmapOpen:
            return KeyboardShortcutBinding(keyCode: UInt16(kVK_ANSI_U), modifiers: [.command, .shift])
        case .stayAwakeToggle:
            return KeyboardShortcutBinding(keyCode: UInt16(kVK_ANSI_A), modifiers: [.control, .option])
        }
    }

    var requiresModifier: Bool {
        switch self {
        case .resourceMonitorToggle:
            return false
        default:
            return true
        }
    }

    var allowsDigitKey: Bool {
        self == .windowSlotModifier
    }
}

struct ShortcutPreferences: Codable, Equatable {
    var windowHistoryBack: KeyboardShortcutBinding = ShortcutAction.windowHistoryBack.defaultBinding
    var windowHistoryForward: KeyboardShortcutBinding = ShortcutAction.windowHistoryForward.defaultBinding
    var windowSlotModifier: ModifierKey = .control
    var workspaceOpen: KeyboardShortcutBinding = ShortcutAction.workspaceOpen.defaultBinding
    var resourceMonitorToggle: KeyboardShortcutBinding = ShortcutAction.resourceMonitorToggle.defaultBinding
    var usageHeatmapOpen: KeyboardShortcutBinding = ShortcutAction.usageHeatmapOpen.defaultBinding
    var stayAwakeToggle: KeyboardShortcutBinding = ShortcutAction.stayAwakeToggle.defaultBinding

    enum CodingKeys: String, CodingKey {
        case windowHistoryBack
        case windowHistoryForward
        case windowSlotModifier
        case workspaceOpen
        case resourceMonitorToggle
        case usageHeatmapOpen
        case stayAwakeToggle
    }

    init(
        windowHistoryBack: KeyboardShortcutBinding = ShortcutAction.windowHistoryBack.defaultBinding,
        windowHistoryForward: KeyboardShortcutBinding = ShortcutAction.windowHistoryForward.defaultBinding,
        windowSlotModifier: ModifierKey = .control,
        workspaceOpen: KeyboardShortcutBinding = ShortcutAction.workspaceOpen.defaultBinding,
        resourceMonitorToggle: KeyboardShortcutBinding = ShortcutAction.resourceMonitorToggle.defaultBinding,
        usageHeatmapOpen: KeyboardShortcutBinding = ShortcutAction.usageHeatmapOpen.defaultBinding,
        stayAwakeToggle: KeyboardShortcutBinding = ShortcutAction.stayAwakeToggle.defaultBinding
    ) {
        self.windowHistoryBack = windowHistoryBack
        self.windowHistoryForward = windowHistoryForward
        self.windowSlotModifier = windowSlotModifier
        self.workspaceOpen = workspaceOpen
        self.resourceMonitorToggle = resourceMonitorToggle
        self.usageHeatmapOpen = usageHeatmapOpen
        self.stayAwakeToggle = stayAwakeToggle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windowHistoryBack = try container.decodeIfPresent(KeyboardShortcutBinding.self, forKey: .windowHistoryBack)
            ?? ShortcutAction.windowHistoryBack.defaultBinding
        windowHistoryForward = try container.decodeIfPresent(KeyboardShortcutBinding.self, forKey: .windowHistoryForward)
            ?? ShortcutAction.windowHistoryForward.defaultBinding
        windowSlotModifier = try container.decodeIfPresent(ModifierKey.self, forKey: .windowSlotModifier) ?? .control
        workspaceOpen = try container.decodeIfPresent(KeyboardShortcutBinding.self, forKey: .workspaceOpen)
            ?? ShortcutAction.workspaceOpen.defaultBinding
        resourceMonitorToggle = try container.decodeIfPresent(KeyboardShortcutBinding.self, forKey: .resourceMonitorToggle)
            ?? ShortcutAction.resourceMonitorToggle.defaultBinding
        usageHeatmapOpen = try container.decodeIfPresent(KeyboardShortcutBinding.self, forKey: .usageHeatmapOpen)
            ?? ShortcutAction.usageHeatmapOpen.defaultBinding
        stayAwakeToggle = try container.decodeIfPresent(KeyboardShortcutBinding.self, forKey: .stayAwakeToggle)
            ?? ShortcutAction.stayAwakeToggle.defaultBinding
    }

    func binding(for action: ShortcutAction) -> KeyboardShortcutBinding {
        switch action {
        case .windowHistoryBack: return windowHistoryBack
        case .windowHistoryForward: return windowHistoryForward
        case .windowSlotModifier:
            return KeyboardShortcutBinding(keyCode: UInt16(kVK_ANSI_1), modifiers: [windowSlotModifier])
        case .workspaceOpen: return workspaceOpen
        case .resourceMonitorToggle: return resourceMonitorToggle
        case .usageHeatmapOpen: return usageHeatmapOpen
        case .stayAwakeToggle: return stayAwakeToggle
        }
    }

    mutating func setBinding(_ binding: KeyboardShortcutBinding, for action: ShortcutAction) {
        switch action {
        case .windowHistoryBack:
            windowHistoryBack = binding
        case .windowHistoryForward:
            windowHistoryForward = binding
        case .windowSlotModifier:
            if let modifier = binding.primaryModifier {
                windowSlotModifier = modifier
            }
        case .workspaceOpen:
            workspaceOpen = binding
        case .resourceMonitorToggle:
            resourceMonitorToggle = binding
        case .usageHeatmapOpen:
            usageHeatmapOpen = binding
        case .stayAwakeToggle:
            stayAwakeToggle = binding
        }
    }

    var windowSlotDisplayString: String {
        "\(windowSlotModifier.symbol) 1-9"
    }

    func matchesWindowSlotDigit(keyCode: UInt16, flags: CGEventFlags) -> Int? {
        guard let slot = Self.digitFromKeyCode(keyCode) else { return nil }
        guard KeyboardShortcutBinding.activeModifiers(from: flags) == [windowSlotModifier] else { return nil }
        return slot
    }

    static func digitFromKeyCode(_ keyCode: UInt16) -> Int? {
        switch Int(keyCode) {
        case kVK_ANSI_1: return 1
        case kVK_ANSI_2: return 2
        case kVK_ANSI_3: return 3
        case kVK_ANSI_4: return 4
        case kVK_ANSI_5: return 5
        case kVK_ANSI_6: return 6
        case kVK_ANSI_7: return 7
        case kVK_ANSI_8: return 8
        case kVK_ANSI_9: return 9
        default: return nil
        }
    }
}

enum ShortcutBindingValidator {
    static func validate(
        _ binding: KeyboardShortcutBinding,
        for action: ShortcutAction,
        in preferences: ShortcutPreferences
    ) -> String? {
        if action.requiresModifier, binding.modifiers.isEmpty {
            return "Add at least one modifier key."
        }

        if action == .workspaceOpen, binding.keyCode != UInt16(kVK_Tab) {
            return "Workspace activation must use Tab."
        }

        if action == .windowSlotModifier {
            guard binding.primaryModifier != nil,
                  ShortcutPreferences.digitFromKeyCode(binding.keyCode) != nil else {
                return "Press a modifier and a digit from 1-9."
            }
        }

        if isReserved(binding) {
            return "That shortcut is reserved by macOS."
        }

        if hasConflict(binding, for: action, in: preferences) {
            return "That shortcut is already assigned."
        }

        return nil
    }

    static func hasConflict(
        _ binding: KeyboardShortcutBinding,
        for action: ShortcutAction,
        in preferences: ShortcutPreferences
    ) -> Bool {
        for other in ShortcutAction.allCases where other != action {
            if preferences.binding(for: other) == binding {
                return true
            }
        }
        return false
    }

    static func isReserved(_ binding: KeyboardShortcutBinding) -> Bool {
        let reserved: [KeyboardShortcutBinding] = [
            KeyboardShortcutBinding(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.command]),
            KeyboardShortcutBinding(keyCode: UInt16(kVK_ANSI_W), modifiers: [.command]),
            KeyboardShortcutBinding(keyCode: UInt16(kVK_Tab), modifiers: [.command]),
            KeyboardShortcutBinding(keyCode: UInt16(kVK_ANSI_Comma), modifiers: [.command]),
        ]
        return reserved.contains(binding)
    }
}

private extension ModifierKey {
    static let displayOrder: [ModifierKey] = [.command, .shift, .option, .control]
}
