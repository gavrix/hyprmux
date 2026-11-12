import AppKit
import HyprmuxCore

/// Importing cmux's workspaces as layouts. The first launch that finds a cmux session
/// asks once; `picker, importcmux` imports any time after.
enum CmuxImportStore {
    /// HYPRMUX_CMUX_DIR points at another cmux folder (a test instance uses fixtures).
    static var cmuxDirectory: String {
        if let d = ProcessInfo.processInfo.environment["HYPRMUX_CMUX_DIR"], !d.isEmpty { return d }
        return CmuxImport.defaultDirectory
    }

    /// Records the answer next to the session file, so a test instance with its own
    /// session (HYPRMUX_SESSION) has its own answer too.
    static var markerPath: String {
        ((SessionStore.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("cmux-import.json")
    }

    static var answered: Bool { FileManager.default.fileExists(atPath: markerPath) }

    /// A test instance (its own HYPRMUX_SESSION) doesn't ask unless it's given a cmux
    /// folder: the question would take its keys in the middle of a test.
    static var mayAsk: Bool {
        let env = ProcessInfo.processInfo.environment
        return (env["HYPRMUX_SESSION"] ?? "").isEmpty || !(env["HYPRMUX_CMUX_DIR"] ?? "").isEmpty
    }

    static func record(_ answer: String, source: String?) {
        var json: [String: Any] = ["answer": answer, "date": ISO8601DateFormatter().string(from: Date())]
        if let source { json["source"] = source }
        do {
            let dir = (markerPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: markerPath), options: .atomic)
        } catch {
            log.error("cmux import: can't write \(markerPath, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// A snapshot with what it would import. Unreadable ones are left out.
    struct Candidate {
        let source: CmuxImport.Source
        let result: CmuxImport.Result
    }

    static func candidates() -> [Candidate] {
        CmuxImport.sources(in: cmuxDirectory).compactMap { s in
            do {
                let r = try CmuxImport.convert(try Data(contentsOf: URL(fileURLWithPath: s.path)))
                return r.workspaces.isEmpty ? nil : Candidate(source: s, result: r)
            } catch {
                log.error("cmux import: skipping \(s.path, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        }
    }

    /// Writes one layout per workspace. A workspace already imported unchanged is skipped;
    /// one whose name a different layout has gets " (cmux)" added. Returns the files written.
    static func write(_ r: CmuxImport.Result) throws -> Int {
        var written = 0
        for var w in r.workspaces {
            let base = w.name ?? "cmux"
            var name = base
            var n = 1
            while true {
                var file = SessionState()
                w.name = name
                file.workspaces = [w]
                let path = LayoutStore.path(for: name)
                if let existing = try? LayoutStore.load(path) {
                    if existing == file { break }
                    n += 1
                    name = n == 2 ? "\(base) (cmux)" : "\(base) (cmux \(n - 1))"
                    continue
                }
                try LayoutStore.save(file, name: name)
                written += 1
                break
            }
        }
        return written
    }
}

extension Compositor {
    /// Startup: asks once, on the first launch that finds a cmux session. Any answer,
    /// Escape included, is final; `picker, importcmux` still imports later.
    func offerCmuxImport() {
        guard CmuxImportStore.mayAsk, !CmuxImportStore.answered else { return }
        // After the restored tiles have settled, so the question isn't drawn over a layout pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !CmuxImportStore.answered, !self.hud.picker.isOpen else { return }
            let found = CmuxImportStore.candidates()
            guard !found.isEmpty else { return }
            self.presentCmuxImport(found, asking: true)
        }
    }

    /// `picker, importcmux`.
    func presentCmuxImportPicker() {
        let found = CmuxImportStore.candidates()
        guard !found.isEmpty else {
            flash("No cmux session found in \(CmuxImportStore.cmuxDirectory)")
            return
        }
        presentCmuxImport(found, asking: false)
    }

    private static let declineRow = "\u{1}decline"

    private func presentCmuxImport(_ found: [CmuxImportStore.Candidate], asking: Bool) {
        let date = DateFormatter()
        date.setLocalizedDateFormatFromTemplate("MMMd")
        var items = found.map { c -> PickerItem in
            let n = c.result.workspaces.count
            var detail = "as layouts · saved \(date.string(from: c.source.modified))"
            if c.result.agents > 0 { detail += " · \(c.result.agents) agent\(c.result.agents == 1 ? "" : "s")" }
            return PickerItem(id: c.source.path, title: "Import \(n) workspace\(n == 1 ? "" : "s") from \(c.source.label)",
                              detail: detail)
        }
        if asking { items.append(PickerItem(id: Self.declineRow, title: "Don't import", detail: "Hyprmux won't ask again")) }
        var picker = Picker(title: "cmux", items: items, searchesDetail: false, maxVisible: config.hud.pickerMaxRows)
        picker.placeholder = asking ? "found a cmux session; esc won't ask again" : "type to filter"
        hud.picker.present(picker) { [weak self] r in
            guard case .item(let id)? = r, let c = found.first(where: { $0.source.path == id }) else {
                if asking { CmuxImportStore.record("declined", source: nil) }
                return
            }
            self?.importCmux(c)
        }
    }

    private func importCmux(_ c: CmuxImportStore.Candidate) {
        do {
            let written = try CmuxImportStore.write(c.result)
            CmuxImportStore.record("imported", source: c.source.path)
            let n = c.result.workspaces.count
            let body = written == n
                ? "\(n) layouts in \(LayoutStore.directory). Pick one to open it."
                : "\(written) new layouts, \(n - written) already imported. Pick one to open it."
            hud.notifications.post(.success, title: "Imported from \(c.source.label)", body)
            // Opening all of them at once would start every agent at once: let the user choose.
            DispatchQueue.main.async { [weak self] in self?.presentLayoutPicker() }
        } catch {
            hud.notifications.post(.error, title: "Can't import from \(c.source.label)", error.localizedDescription)
        }
    }
}
