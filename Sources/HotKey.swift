//
//  HotKey.swift
//  NoLid
//
//  Global hotkey through Carbon (RegisterEventHotKey). It is the only way to
//  register a system-wide shortcut without asking for Accessibility access.
//

import AppKit
import Carbon.HIToolbox

/// Action to run when the hotkey fires. Global because the Carbon callback is
/// a C function and cannot capture context.
private var hotKeyAction: (() -> Void)?

// MARK: - Persisted configuration

/// Key combination chosen by the user.
///
/// The readable label (`⌃⌥⌘L`) is stored too instead of being recomputed from
/// the `keyCode`: translating a key code into the character it prints depends
/// on the active keyboard layout, and `NSEvent` already hands us the right
/// character at the moment the hotkey is recorded.
struct HotKeyConfig: Codable, Equatable {

    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    static let `default` = HotKeyConfig(
        keyCode: UInt32(kVK_ANSI_L),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        label: "⌃⌥⌘L"
    )

    // MARK: Conversion from NSEvent

    /// Translates the keyboard event into a Carbon configuration.
    /// - Returns: `nil` when the combination cannot serve as a global hotkey.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }

        // Without at least one modifier we would hijack a plain key across the
        // whole system. Shift alone is not enough either: ⇧A is just "A".
        let meaningful: NSEvent.ModifierFlags = [.control, .option, .command]
        guard !flags.intersection(meaningful).isEmpty else { return nil }

        let code = UInt32(event.keyCode)
        guard let name = HotKeyConfig.keyName(event: event) else { return nil }

        self.keyCode = code
        self.modifiers = carbon
        self.label = HotKeyConfig.symbols(for: flags) + name
    }

    private init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    // MARK: Labels

    private static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option)  { out += "⌥" }
        if flags.contains(.shift)   { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out
    }

    /// Keys with no printable character. Everything else comes from `NSEvent`.
    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func keyName(event: NSEvent) -> String? {
        if let named = namedKeys[Int(event.keyCode)] { return named }

        // `charactersIgnoringModifiers` gives the physical key for the active
        // layout without applying ⌥, which on many layouts yields odd symbols.
        guard let raw = event.charactersIgnoringModifiers, let first = raw.first,
              !first.isWhitespace, first.isLetter || first.isNumber || first.isPunctuation
                || first.isSymbol else { return nil }
        return String(first).uppercased()
    }

    // MARK: Persistence

    private static let key = "hotKeyConfig"

    static func load(from defaults: UserDefaults = .standard) -> HotKeyConfig {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(HotKeyConfig.self, from: data)
        else { return .default }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: HotKeyConfig.key)
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

// MARK: - Carbon registration

final class HotKey {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Configuration the currently active hotkey was registered with.
    private(set) var config: HotKeyConfig = .default

    /// - Returns: `false` when the hotkey is already taken by another app.
    @discardableResult
    func register(_ config: HotKeyConfig, action: @escaping () -> Void) -> Bool {
        unregister()
        hotKeyAction = action
        self.config = config

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            hotKeyAction?()
            return noErr
        }, 1, &eventType, nil, &handlerRef)

        guard installed == noErr else {
            unregister()
            return false
        }

        let id = EventHotKeyID(signature: OSType(0x4E4C4944), id: 1) // 'NLID'
        let registered = RegisterEventHotKey(config.keyCode, config.modifiers, id,
                                             GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
        hotKeyAction = nil
    }

    deinit { unregister() }
}
