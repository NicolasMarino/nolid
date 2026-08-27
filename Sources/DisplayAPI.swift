//
//  DisplayAPI.swift
//  NoLid
//
//  Low-level layer for enabling and disabling displays on macOS.
//
//  Primary method: SkyLight.framework -> SLSConfigureDisplayEnabled
//  (historically CGSConfigureDisplayEnabled in CoreGraphics). It is private API:
//  it needs no SIP changes and no special entitlements, but Apple can change
//  it in any macOS release. That is why every access goes through dlsym and
//  fails cleanly if the symbol disappears.
//
//  Fallback method: public CoreGraphics API (mirroring). It does not
//  "disconnect" the display, but it stops being an independent desktop, which
//  is 90% of the annoyance. It also drops the brightness to 0.
//

import AppKit
import CoreGraphics
import Foundation

enum DisplayAPI {

    /// "No display" sentinel. Equivalent to `kCGNullDirectDisplay`, spelled out
    /// by hand so we don't depend on how the C importer surfaces that macro.
    static let nullDisplay: CGDirectDisplayID = 0

    // MARK: - Private symbol loading

    /// `(config, displayID, enabled) -> CGError`
    private typealias ConfigureDisplayEnabledFn =
        @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

    /// `(displayID, brightness 0.0...1.0) -> IOReturn`
    private typealias SetBrightnessFn =
        @convention(c) (CGDirectDisplayID, Float) -> Int32

    /// `(displayID, &brightness) -> IOReturn`
    private typealias GetBrightnessFn =
        @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private static let skyLight: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
        RTLD_LAZY
    )

    private static let displayServices: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices",
        RTLD_LAZY
    )

    private static let configureDisplayEnabled: ConfigureDisplayEnabledFn? = {
        // The symbol lives in SkyLight on modern macOS; older versions exposed
        // it through CoreGraphics. Try both names against both handles.
        let handles = [skyLight, dlopen(nil, RTLD_LAZY)].compactMap { $0 }
        for handle in handles {
            for name in ["SLSConfigureDisplayEnabled", "CGSConfigureDisplayEnabled"] {
                if let sym = dlsym(handle, name) {
                    return unsafeBitCast(sym, to: ConfigureDisplayEnabledFn.self)
                }
            }
        }
        return nil
    }()

    private static let setBrightnessFn: SetBrightnessFn? = {
        guard let handle = displayServices,
              let sym = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(sym, to: SetBrightnessFn.self)
    }()

    private static let getBrightnessFn: GetBrightnessFn? = {
        guard let handle = displayServices,
              let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: GetBrightnessFn.self)
    }()

    /// `true` when the strong method (hard disable) is available on this macOS.
    static var supportsHardDisable: Bool { configureDisplayEnabled != nil }

    /// `true` when brightness can be read and written through DisplayServices.
    static var supportsBrightness: Bool { setBrightnessFn != nil && getBrightnessFn != nil }

    // MARK: - Enumeration

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func isBuiltIn(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(id) != 0
    }

    static func builtInDisplay() -> CGDirectDisplayID? {
        onlineDisplays().first(where: isBuiltIn)
    }

    /// `true` when `id` is the *mirrored* display of a mirror set, not the master.
    static func isMirroringAnother(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayMirrorsDisplay(id) != nullDisplay
    }

    // MARK: - Stable identity

    /// Persistent UUID of the display.
    ///
    /// `CGDirectDisplayID` is reassigned on reconnect, so it cannot be used to
    /// remember preferences across sessions. The UUID can: it is stable for the
    /// same physical panel on the same port.
    static func uuid(_ id: CGDirectDisplayID) -> String? {
        guard let ref = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
        let cfuuid = ref.takeRetainedValue()
        guard let string = CFUUIDCreateString(nil, cfuuid) else { return nil }
        return string as String
    }

    /// Human-readable display name, as shown in System Settings.
    ///
    /// It comes from `NSScreen.localizedName`, so only active displays have a
    /// name. A disabled display gets a generic string, which is enough: we only
    /// ever name active externals.
    static func name(_ id: CGDirectDisplayID) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[key] as? NSNumber,
               number.uint32Value == id {
                return screen.localizedName
            }
        }
        return isBuiltIn(id) ? "Built-in display" : "Display \(id)"
    }

    // MARK: - Strong method: disconnect / reconnect

    /// Applies the change inside a display configuration transaction.
    /// - Parameter option: `.forSession` does not survive logout, which is safer.
    ///   `.permanently` would write it into the system preferences.
    @discardableResult
    static func setEnabled(_ id: CGDirectDisplayID,
                           _ enabled: Bool,
                           option: CGConfigureOption = .forSession) -> Bool {
        guard let configure = configureDisplayEnabled else { return false }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }

        let err = configure(config, id, enabled)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, option) == .success
    }

    // MARK: - Fallback method: mirroring (public API)

    /// Makes `id` mirror `master`, so it stops being a desktop of its own.
    /// Passing `nil` undoes the mirror.
    @discardableResult
    static func setMirror(_ id: CGDirectDisplayID, of master: CGDirectDisplayID?) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }

        guard CGConfigureDisplayMirrorOfDisplay(config, id, master ?? nullDisplay) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    // MARK: - Brightness (DisplayServices)

    @discardableResult
    static func setBrightness(_ id: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let fn = setBrightnessFn else { return false }
        return fn(id, max(0, min(1, value))) == 0
    }

    static func brightness(_ id: CGDirectDisplayID) -> Float? {
        guard let fn = getBrightnessFn else { return nil }
        var value: Float = 0
        return fn(id, &value) == 0 ? value : nil
    }
}
