import AppKit
import HyprmuxCore

/// Layout files: workspace templates in `layouts/` next to the config
/// (`~/.config/hyprmux/layouts/NAME.json`). Same schema as the session.
enum LayoutStore {
    static var directory: String {
        ((AppDelegate.configPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("layouts")
    }

    struct Entry {
        let name: String
        let path: String
        /// Tiles in the file, for the picker.
        let tiles: Int
    }

    static func list() -> [Entry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        return files.filter { $0.hasSuffix(".json") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { f in
            let path = (directory as NSString).appendingPathComponent(f)
            let tiles = (try? load(path)).map(count) ?? 0
            return Entry(name: String(f.dropLast(".json".count)), path: path, tiles: tiles)
        }
    }

    static func load(_ path: String) throws -> SessionState {
        try SessionState.decode(try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// Writes `NAME.json`. Returns whether it replaced an existing file.
    @discardableResult
    static func save(_ s: SessionState, name: String) throws -> Bool {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = self.path(for: name)
        let existed = FileManager.default.fileExists(atPath: path)
        try s.encoded().write(to: URL(fileURLWithPath: path), options: .atomic)
        return existed
    }

    static func path(for name: String) -> String {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return (directory as NSString).appendingPathComponent(safe + ".json")
    }

    static func count(_ s: SessionState) -> Int {
        func tiles(_ n: SessionNode?) -> Int {
            switch n {
            case .none: return 0
            case .slot(let sl)?: return sl.tabs.count
            case .split(_, _, let a, let b)?: return tiles(a) + tiles(b)
            }
        }
        return s.workspaces.reduce(0) { $0 + tiles($1.tiled) + $1.floating.reduce(0) { $0 + $1.slot.tabs.count } }
    }
}

extension Compositor {
    /// Row id for "save this workspace" at the end of the layout picker.
    private static let saveRow = "\u{1}save"

    func presentLayoutPicker() {
        var items = LayoutStore.list().map { e -> PickerItem in
            var detail = e.tiles == 1 ? "1 window" : "\(e.tiles) windows"
            if let n = wm.workspace(named: e.name), wm.snapshot().workspaces.contains(n) { detail += " · open on \(n)" }
            return PickerItem(id: e.path, title: e.name, detail: detail)
        }
        let current = wm.activeWorkspace
        items.append(PickerItem(id: Self.saveRow, title: "save workspace \(current) as a layout…",
                                detail: wm.name(of: current) ?? ""))
        var picker = Picker(title: "layout", items: items, searchesDetail: false, maxVisible: config.hud.pickerMaxRows)
        picker.placeholder = items.count == 1 ? "no layouts yet: save this workspace" : "type to filter"
        hud.picker.present(picker) { [weak self] r in
            guard let self, case .item(let id)? = r else { return }
            if id == Self.saveRow {
                DispatchQueue.main.async { self.presentSaveLayoutPrompt() }
            } else {
                self.loadLayout(at: id)
            }
        }
    }

    func presentSaveLayoutPrompt() {
        let n = wm.activeWorkspace
        guard wm.snapshot().placements.contains(where: { $0.workspace == .regular(n) }) else {
            flash("Workspace \(n) has no windows to save")
            return
        }
        var picker = Picker(title: "save \(n) as", mode: .prompt, query: wm.name(of: n) ?? "")
        picker.placeholder = "layout name"
        hud.picker.present(picker) { [weak self] r in
            guard let self, case .text(let raw)? = r else { return }
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            self.saveLayout(workspace: n, name: name)
        }
    }

    private func saveLayout(workspace n: Int, name: String) {
        guard var w = wm.exportWorkspace(.regular(n), tile: { [weak self] id in self?.sessionTile(id, forLayout: true) }) else { return }
        w.id = ""
        w.name = name
        var file = SessionState()
        file.workspaces = [w]
        do {
            let replaced = try LayoutStore.save(file, name: name)
            // The workspace takes the name, so loading the layout later finds it instead of duplicating it.
            if wm.name(of: n) != name { dispatch(.renameWorkspace(n, name)) }
            hud.notifications.post(.success, title: replaced ? "Layout updated" : "Layout saved",
                                   "\(name): \(LayoutStore.count(file)) windows, \(LayoutStore.path(for: name))")
        } catch {
            hud.notifications.post(.error, title: "Can't save layout", error.localizedDescription)
        }
    }

    func loadLayout(at path: String) {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let layout: SessionState
        do {
            layout = try LayoutStore.load(path)
        } catch {
            hud.notifications.post(.error, title: "Can't read layout \(name)", String(describing: error))
            return
        }
        let touched = wm.loadLayout(layout, defaultName: name) { [weak self] t in self?.restoreTile(t) }
        apply(animated: true)
        if touched.isEmpty { flash("Layout \(name) has nothing to open") }
    }
}
