import Foundation

/// Where the tour stopped, so `hyprmux-tour` picks up again after a quit or a closed tile.
struct TourState: Codable, Equatable {
    var step = 0
    var completed = false
    /// The Hyprmux process the tour ran in. Surface ids only mean something inside one run.
    var hyprmuxPID: String?
    /// Surfaces that existed before the tour began; the rest are practice tiles.
    var tourSurfaces: [UInt64] = []

    /// `~/Library/Application Support/Hyprmux/Tour/<instance>.json`, or `$HYPRMUX_TOUR_STATE`.
    static var path: String {
        let env = ProcessInfo.processInfo.environment
        if let p = env["HYPRMUX_TOUR_STATE"], !p.isEmpty { return (p as NSString).expandingTildeInPath }
        let instance = env["HYPRMUX_INSTANCE"].flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Hyprmux/Tour/\(instance).json").path
    }

    static func load() -> TourState? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(TourState.self, from: data)
    }

    func save() {
        let url = URL(fileURLWithPath: Self.path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: url, options: .atomic)
    }
}
