// Shared names for the client protocol (docs/CLIENT_PROTOCOL.md): mach service
// names, message ops, and small XPC helpers. Used by the app, the broker, and
// the client kit.
import Foundation
import XPC

public enum HMProtocol {
    public static let version: UInt64 = 0

    /// Any client may connect here to look up a compositor's endpoint.
    public static let lookupService = "dev.gavrix.hyprmux.compositor"
    /// Only Hyprmux may connect here (the broker checks its code signature) to
    /// register its endpoint.
    public static let registrarService = "dev.gavrix.hyprmux.registrar"
    public static let brokerLabel = "dev.gavrix.hyprmux.broker"

    /// Several Hyprmux instances (a test copy next to the user's) register under
    /// different names. Clients Hyprmux starts inherit the name in this variable.
    public static let instanceVariable = "HYPRMUX_INSTANCE"
    public static let defaultInstance = "default"
    /// Binds a launched client's first toplevel to the tile reserved for it.
    public static let launchTokenVariable = "HYPRMUX_LAUNCH_TOKEN"

    public static var currentInstance: String {
        let v = ProcessInfo.processInfo.environment[instanceVariable] ?? ""
        return v.isEmpty ? defaultInstance : v
    }
}

/// Message `op` values. Client-to-compositor and compositor-to-client share one space.
public enum HMOp {
    // broker
    public static let register = "register"
    public static let lookup = "lookup"
    // handshake
    public static let hello = "hello"
    public static let error = "error"
    // buffer
    public static let bufferCreateIOSurface = "buffer.create_iosurface"
    public static let bufferDestroy = "buffer.destroy"
    public static let bufferRelease = "buffer.release"
    // surface
    public static let surfaceCreate = "surface.create"
    public static let surfaceAttach = "surface.attach"
    public static let surfaceDamage = "surface.damage"
    public static let surfaceSetScale = "surface.set_scale"
    public static let surfaceSetOpaque = "surface.set_opaque"
    public static let surfaceFrame = "surface.frame"
    public static let surfaceCommit = "surface.commit"
    public static let surfaceDestroy = "surface.destroy"
    public static let surfaceFrameDone = "surface.frame_done"
    // subsurface: a child surface drawn above its parent, scaled to a rect
    public static let subsurfaceCreate = "subsurface.create"
    public static let subsurfaceSetRect = "subsurface.set_rect"
    public static let subsurfaceDestroy = "subsurface.destroy"
    // launches: Hyprmux asks for windows, the app opens or offers them
    public static let launch = "launch"
    public static let launchOffer = "launch.offer"
    public static let launchOpen = "launch.open"
    public static let launchCancel = "launch.cancel"
    public static let launchDone = "launch.done"
    // toplevel
    public static let toplevelCreate = "toplevel.create"
    public static let toplevelSetTitle = "toplevel.set_title"
    public static let toplevelSetRestoreToken = "toplevel.set_restore_token"
    public static let toplevelAckConfigure = "toplevel.ack_configure"
    public static let toplevelDestroy = "toplevel.destroy"
    public static let toplevelConfigure = "toplevel.configure"
    public static let toplevelCloseRequested = "toplevel.close_requested"
    // input
    public static let pointerEnter = "pointer.enter"
    public static let pointerLeave = "pointer.leave"
    public static let pointerMotion = "pointer.motion"
    public static let pointerButton = "pointer.button"
    public static let pointerScroll = "pointer.scroll"
    public static let pointerSetCursor = "pointer.set_cursor"
    public static let keyboardEnter = "keyboard.enter"
    public static let keyboardLeave = "keyboard.leave"
    public static let keyboardKey = "keyboard.key"
    public static let keyboardModifiers = "keyboard.modifiers"
    // text input (IME), after Wayland's text-input-v3
    public static let textInputEnable = "text_input.enable"
    public static let textInputDisable = "text_input.disable"
    public static let textInputSetCursorRect = "text_input.set_cursor_rect"
    public static let textInputPreedit = "text_input.preedit"
    public static let textInputCommit = "text_input.commit"
    public static let textInputDeleteSurrounding = "text_input.delete_surrounding"
    public static let textInputDone = "text_input.done"
    // window UI through the compositor
    public static let dialogOpen = "dialog.open"
    public static let dialogResult = "dialog.result"
    public static let menuPopup = "menu.popup"
    public static let menuSelected = "menu.selected"
}

/// `dialog.open` kinds. Options and results travel as JSON (`options_json`,
/// `result_json`) in Electron's `dialog` shapes, which map onto AppKit's panels:
///
/// - `open`: options `title`, `message`, `defaultPath`, `buttonLabel`, `filters`
///   (`[{name, extensions}]`), `properties` (`openFile`, `openDirectory`,
///   `multiSelections`, `showHiddenFiles`, `createDirectory`, `treatPackageAsDirectory`).
///   Result `{canceled, filePaths}`.
/// - `save`: options `title`, `message`, `defaultPath`, `buttonLabel`, `nameFieldLabel`,
///   `filters`, `properties` (`showHiddenFiles`, `createDirectory`). Result `{canceled, filePath}`.
/// - `message`: options `type` (`none`, `info`, `error`, `question`, `warning`), `title`,
///   `message`, `detail`, `buttons`, `defaultId`, `cancelId`, `checkboxLabel`,
///   `checkboxChecked`. Result `{response, checkboxChecked}`.
public enum HMDialogKind {
    public static let open = "open"
    public static let save = "save"
    public static let message = "message"
}

/// `menu.popup` items, as JSON (`items_json`): `[{id, label, type, enabled, checked,
/// accelerator, submenu}]`. `type` is `normal`, `separator`, `checkbox`, `radio`, or
/// `submenu`. `id` is a string the client picks; `menu.selected` returns it, or
/// omits `item` when the menu was dismissed.
public enum HMMenuItemType {
    public static let separator = "separator"
    public static let submenu = "submenu"
    public static let checkbox = "checkbox"
    public static let radio = "radio"
}

/// One window a launch offers (`launch.offer`). It travels as JSON (`windows_json`):
/// `[{id, title, detail}]`. `id` is a string the client picks; `launch.open` returns it.
/// `detail` is optional.
public struct HMWindowOffer: Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String

    public init(id: String, title: String, detail: String = "") {
        self.id = id
        self.title = title
        self.detail = detail
    }

    public static func encode(_ windows: [HMWindowOffer]) -> String {
        let list = windows.map { w -> [String: String] in
            var o = ["id": w.id, "title": w.title]
            if !w.detail.isEmpty { o["detail"] = w.detail }
            return o
        }
        return (try? JSONSerialization.data(withJSONObject: list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// Entries without an id are skipped. A missing title shows the id.
    public static func decode(_ json: String?) -> [HMWindowOffer] {
        guard let data = json?.data(using: .utf8),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { o in
            guard let id = o["id"] as? String, !id.isEmpty else { return nil }
            let title = (o["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return HMWindowOffer(id: id, title: title, detail: o["detail"] as? String ?? "")
        }
    }
}

/// `toplevel.configure` states.
public enum HMToplevelState {
    public static let activated = "activated"
    public static let occluded = "occluded"
    public static let fullscreen = "fullscreen"
    public static let floating = "floating"
}

/// Cursor names for `pointer.set_cursor`.
public enum HMCursor {
    public static let all = ["arrow", "ibeam", "pointing_hand", "crosshair", "open_hand", "closed_hand",
                             "resize_left_right", "resize_up_down", "not_allowed", "hidden"]
}

// MARK: XPC helpers

public typealias XPCDict = xpc_object_t

public func xpcMessage(_ op: String, _ fields: [String: Any] = [:]) -> XPCDict {
    let d = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_string(d, "op", op)
    for (key, value) in fields { xpcSet(d, key, value) }
    return d
}

/// Sets a Swift value on an XPC dictionary. Supports the types the protocol uses.
public func xpcSet(_ d: XPCDict, _ key: String, _ value: Any) {
    switch value {
    case let v as String: xpc_dictionary_set_string(d, key, v)
    case let v as Bool: xpc_dictionary_set_bool(d, key, v)
    case let v as UInt64: xpc_dictionary_set_uint64(d, key, v)
    case let v as Int: xpc_dictionary_set_int64(d, key, Int64(v))
    case let v as Int64: xpc_dictionary_set_int64(d, key, v)
    case let v as Double: xpc_dictionary_set_double(d, key, v)
    case let v as CGFloat: xpc_dictionary_set_double(d, key, Double(v))
    case let v as [String]:
        let a = xpc_array_create(nil, 0)
        for s in v { xpc_array_append_value(a, xpc_string_create(s)) }
        xpc_dictionary_set_value(d, key, a)
    default:
        // xpc_object_t values (IOSurface objects, endpoints, arrays) pass through.
        xpc_dictionary_set_value(d, key, value as! xpc_object_t)
    }
}

public extension xpc_object_t {
    var isDictionary: Bool { xpc_get_type(self) == XPC_TYPE_DICTIONARY }
    var isError: Bool { xpc_get_type(self) == XPC_TYPE_ERROR }
    var op: String? { string("op") }
    func string(_ key: String) -> String? { xpc_dictionary_get_string(self, key).map { String(cString: $0) } }
    func uint(_ key: String) -> UInt64 { xpc_dictionary_get_uint64(self, key) }
    func int(_ key: String) -> Int64 { xpc_dictionary_get_int64(self, key) }
    func double(_ key: String) -> Double { xpc_dictionary_get_double(self, key) }
    func bool(_ key: String) -> Bool { xpc_dictionary_get_bool(self, key) }
    func value(_ key: String) -> xpc_object_t? { xpc_dictionary_get_value(self, key) }
    func strings(_ key: String) -> [String] {
        guard let a = xpc_dictionary_get_value(self, key), xpc_get_type(a) == XPC_TYPE_ARRAY else { return [] }
        return (0..<xpc_array_get_count(a)).compactMap { i in xpc_array_get_string(a, i).map { String(cString: $0) } }
    }
}
