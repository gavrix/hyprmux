import AppKit
import HyprmuxClientProtocol
import UniformTypeIdentifiers

/// Native UI a client asks for (docs/CLIENT_PROTOCOL.md, section 7). A client has
/// no visible window, and it isn't the active app, so its own panels would open
/// out of sight. Hyprmux shows them instead: dialogs as sheets on the monitor
/// window, menus as pop-ups over the tile.
extension ClientSurface {
    // MARK: Dialogs

    /// One sheet at a time per window; later requests wait their turn.
    private static var sheetQueue: [(NSWindow) -> Void] = []
    private static var sheetOpen = false

    private static func enqueueSheet(on window: NSWindow, _ show: @escaping (NSWindow, @escaping () -> Void) -> Void) {
        sheetQueue.append { w in show(w) { sheetOpen = false; runNextSheet(on: w) } }
        runNextSheet(on: window)
    }

    private static func runNextSheet(on window: NSWindow) {
        guard !sheetOpen, !sheetQueue.isEmpty else { return }
        sheetOpen = true
        sheetQueue.removeFirst()(window)
    }

    func showDialog(kind: String, options o: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let window else {
            reply(kind == HMDialogKind.message ? ["response": o["cancelId"] as? Int ?? 0, "checkboxChecked": false] : ["canceled": true])
            return
        }
        switch kind {
        case HMDialogKind.open, HMDialogKind.save:
            Self.enqueueSheet(on: window) { w, done in
                let panel = kind == HMDialogKind.open ? Self.openPanel(o) : Self.savePanel(o)
                panel.beginSheetModal(for: w) { response in
                    let ok = response == .OK
                    if let open = panel as? NSOpenPanel {
                        reply(["canceled": !ok, "filePaths": ok ? open.urls.map(\.path) : []])
                    } else {
                        reply(ok ? ["canceled": false, "filePath": panel.url?.path ?? ""] : ["canceled": true])
                    }
                    done()
                }
            }
        case HMDialogKind.message:
            Self.enqueueSheet(on: window) { w, done in
                let (alert, cancelIndex) = Self.alert(o)
                alert.beginSheetModal(for: w) { response in
                    let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                    let valid = index >= 0 && index < alert.buttons.count
                    reply(["response": valid ? index : cancelIndex, "checkboxChecked": alert.suppressionButton?.state == .on])
                    done()
                }
            }
        default:
            reply(["canceled": true])
        }
    }

    private static func properties(_ o: [String: Any]) -> Set<String> { Set(o["properties"] as? [String] ?? []) }

    private static func configure(_ panel: NSSavePanel, _ o: [String: Any], defaultIsDirectory: Bool) {
        if let t = o["title"] as? String { panel.title = t }
        if let m = o["message"] as? String { panel.message = m }
        if let b = o["buttonLabel"] as? String, !b.isEmpty { panel.prompt = b }
        let props = properties(o)
        panel.showsHiddenFiles = props.contains("showHiddenFiles")
        panel.canCreateDirectories = props.contains("createDirectory") || panel is NSSavePanel && !(panel is NSOpenPanel)
        panel.treatsFilePackagesAsDirectories = props.contains("treatPackageAsDirectory")
        if let path = (o["defaultPath"] as? String).map({ ($0 as NSString).expandingTildeInPath }), !path.isEmpty {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue || defaultIsDirectory {
                panel.directoryURL = URL(fileURLWithPath: path)
            } else {
                panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
                panel.nameFieldStringValue = (path as NSString).lastPathComponent
            }
        }
        let extensions = (o["filters"] as? [[String: Any]] ?? []).flatMap { $0["extensions"] as? [String] ?? [] }
        if !extensions.isEmpty, !extensions.contains("*") {
            panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        }
    }

    private static func openPanel(_ o: [String: Any]) -> NSOpenPanel {
        let p = NSOpenPanel()
        let props = properties(o)
        let dirs = props.contains("openDirectory")
        p.canChooseDirectories = dirs
        p.canChooseFiles = props.contains("openFile") || !dirs
        p.allowsMultipleSelection = props.contains("multiSelections")
        configure(p, o, defaultIsDirectory: true)
        return p
    }

    private static func savePanel(_ o: [String: Any]) -> NSSavePanel {
        let p = NSSavePanel()
        if let n = o["nameFieldLabel"] as? String { p.nameFieldLabel = n }
        configure(p, o, defaultIsDirectory: false)
        return p
    }

    /// An `NSAlert` for Electron-style message box options, and the response to report
    /// when it's dismissed without a button.
    private static func alert(_ o: [String: Any]) -> (NSAlert, Int) {
        let a = NSAlert()
        let message = o["message"] as? String ?? ""
        let title = o["title"] as? String ?? ""
        a.messageText = message.isEmpty ? title : message
        a.informativeText = o["detail"] as? String ?? ""
        switch o["type"] as? String {
        case "error", "warning": a.alertStyle = .critical
        default: a.alertStyle = .informational
        }
        var buttons = o["buttons"] as? [String] ?? []
        if buttons.isEmpty { buttons = ["OK"] }
        for b in buttons { a.addButton(withTitle: b) }
        let defaultId = o["defaultId"] as? Int ?? 0
        let cancelId = o["cancelId"] as? Int ?? buttons.firstIndex { ["cancel", "no"].contains($0.lowercased()) } ?? 0
        // AppKit makes the first button the default; follow the client's choice instead.
        for (i, button) in a.buttons.enumerated() {
            button.keyEquivalent = i == defaultId ? "\r" : i == cancelId ? "\u{1b}" : ""
        }
        if let label = o["checkboxLabel"] as? String, !label.isEmpty {
            a.showsSuppressionButton = true
            a.suppressionButton?.title = label
            a.suppressionButton?.state = (o["checkboxChecked"] as? Bool ?? false) ? .on : .off
        }
        return (a, cancelId)
    }

    // MARK: Menus

    private final class MenuTarget: NSObject {
        var picked: String?
        @objc func pick(_ sender: NSMenuItem) { picked = sender.representedObject as? String }
    }

    func showMenu(items: [[String: Any]], at point: CGPoint, reply: @escaping (String?) -> Void) {
        let target = MenuTarget()
        let menu = Self.menu(items, target: target)
        // Tracking runs a nested run loop. Starting it from a run-loop source rather
        // than a GCD block keeps the main queue draining, so the client keeps drawing
        // and its messages keep arriving while the menu is open.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self, self.window != nil else { reply(nil); return }
            menu.popUp(positioning: nil, at: point, in: self)
            // The picked item's action has run by the time tracking returns.
            reply(target.picked)
        }
    }

    private static func menu(_ items: [[String: Any]], target: MenuTarget) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            let type = item["type"] as? String ?? "normal"
            if type == HMMenuItemType.separator { menu.addItem(.separator()); continue }
            let mi = NSMenuItem(title: item["label"] as? String ?? "", action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            mi.target = target
            mi.representedObject = item["id"] as? String
            mi.isEnabled = item["enabled"] as? Bool ?? true
            if (item["checked"] as? Bool) == true { mi.state = .on }
            if let accel = item["accelerator"] as? String { applyAccelerator(accel, to: mi) }
            if let sub = item["submenu"] as? [[String: Any]], !sub.isEmpty {
                mi.submenu = Self.menu(sub, target: target)
                mi.action = nil
            }
            menu.addItem(mi)
        }
        return menu
    }

    /// Shows an Electron accelerator such as `CmdOrCtrl+Shift+P` next to the item.
    private static func applyAccelerator(_ accel: String, to item: NSMenuItem) {
        var mask: NSEvent.ModifierFlags = []
        var key = ""
        for part in accel.split(separator: "+").map({ $0.lowercased() }) {
            switch part {
            case "cmd", "command", "cmdorctrl", "commandorcontrol", "super", "meta": mask.insert(.command)
            case "ctrl", "control": mask.insert(.control)
            case "alt", "option": mask.insert(.option)
            case "shift": mask.insert(.shift)
            case "enter", "return": key = "\r"
            case "tab": key = "\t"
            case "space": key = " "
            case "backspace": key = "\u{8}"
            case "delete": key = "\u{7f}"
            case "esc", "escape": key = "\u{1b}"
            case "plus": key = "+"
            default: key = part.count == 1 ? part : ""
            }
        }
        guard !key.isEmpty else { return }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = mask
    }
}
