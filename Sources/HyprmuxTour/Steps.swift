import Foundation
import HyprmuxCore

/// What a task's check sees.
public struct TaskInput: Sendable {
    /// Hyprmux now.
    public var world: TourWorld
    /// Hyprmux when the step began.
    public var start: TourWorld
    /// Hyprmux when the previous task finished (the step start, for the first task).
    public var mark: TourWorld
    /// Hyprmux at the look before this one: what the latest events changed.
    public var previous: TourWorld
    /// The tour's own surface.
    public var tutor: UInt64
    /// Surfaces that existed before the tour began. Everything else is a practice tile.
    public var tourSurfaces: Set<UInt64>
    /// Hyprmux's events since the previous task finished, oldest first.
    public var events: [HyprmuxEvent]

    public init(world: TourWorld, start: TourWorld, mark: TourWorld, previous: TourWorld? = nil, tutor: UInt64,
                tourSurfaces: Set<UInt64>, events: [HyprmuxEvent] = []) {
        self.world = world
        self.start = start
        self.mark = mark
        self.previous = previous ?? mark
        self.tutor = tutor
        self.tourSurfaces = tourSurfaces
        self.events = events
    }

    /// Whether a dispatcher ran since the previous task, optionally from one source
    /// (`key`, `mouse`, ...).
    public func dispatched(_ name: String, from source: String? = nil) -> Bool {
        events.contains { e in
            guard let d = e.dispatched else { return false }
            return d.name == name && (source == nil || d.source == source)
        }
    }

    public func saw(_ name: String, where match: (String) -> Bool = { _ in true }) -> Bool {
        events.contains { $0.name == name && match($0.data) }
    }

    /// Whether focus last arrived at `id` through one of these dispatchers, pressed as a
    /// key. A click or the pointer moves focus with no dispatch at all.
    public func focusArrived(at id: UInt64, by names: Set<String>) -> Bool {
        guard let i = events.lastIndex(where: { $0.name == "activewindowv2" && $0.data == "\(id)" }) else { return false }
        // Events one dispatch causes, emitted between it and the focus change.
        let sideEffects: Set<String> = ["activewindow", "workspace", "workspacev2", "activespecial", "createworkspace",
                                        "destroyworkspace", "windowtitle", "windowtitlev2"]
        for e in events[..<i].reversed() {
            if sideEffects.contains(e.name) { continue }
            guard let d = e.dispatched else { return false }
            return d.source == "key" && names.contains(d.name)
        }
        return false
    }

    public var tutorSurface: TourSurface? { world.surface(tutor) }
    public var tutorFocused: Bool { world.focused?.id == tutor }
    /// The tour tile moved, or changed size, at the latest look.
    public var tutorMoved: Bool { TourGeometry.moved(previous.surface(tutor)?.frame, tutorSurface?.frame) }
    public var tutorResized: Bool { TourGeometry.resized(previous.surface(tutor)?.frame, tutorSurface?.frame) }

    /// Tiles opened during the tour, other than the tour itself.
    public var practice: [TourSurface] {
        world.surfaces.filter { !tourSurfaces.contains($0.id) && $0.id != tutor }
    }

    /// Tiles that appeared since the previous task finished.
    public var newSinceMark: [TourSurface] {
        let before = mark.ids
        return world.surfaces.filter { !before.contains($0.id) }
    }
}

/// One thing to do inside a step. Tasks finish in order; a finished task stays finished.
public struct TourTask: Sendable {
    /// Markup (see `TourMarkup`).
    public var text: String
    /// "Come back to the tour": the task that teaches a way back.
    public var isReturn: Bool
    public var check: @Sendable (TaskInput) -> Bool
    /// Live progress shown under the task while it's current ("3 left").
    public var progress: (@Sendable (TaskInput) -> String?)?

    public init(_ text: String, isReturn: Bool = false, progress: (@Sendable (TaskInput) -> String?)? = nil,
                check: @escaping @Sendable (TaskInput) -> Bool) {
        self.text = text
        self.isReturn = isReturn
        self.progress = progress
        self.check = check
    }

    /// The task that ends most steps: the tour tile has the keyboard again.
    public static func back(_ text: String) -> TourTask {
        TourTask(text, isReturn: true) { $0.tutorFocused }
    }
}

public struct TourStep: Sendable {
    public var id: String
    public var title: String
    /// Paragraphs, in markup.
    public var body: [String]
    public var tasks: [TourTask]
    /// Paragraphs after the tasks, dimmed.
    public var notes: [String]

    public init(id: String, title: String, body: [String], tasks: [TourTask] = [], notes: [String] = []) {
        self.id = id
        self.title = title
        self.body = body
        self.tasks = tasks
        self.notes = notes
    }
}

/// What a step is built from: the user's keys and config, and Hyprmux as the step begins.
public struct TourContext: Sendable {
    public var keys: TourKeys
    public var config: HyprmuxConfig
    public var configPath: String
    public var world: TourWorld
    public var tutor: UInt64
    public var tourSurfaces: Set<UInt64>

    public init(config: HyprmuxConfig, configPath: String, world: TourWorld, tutor: UInt64,
                tourSurfaces: Set<UInt64>) {
        self.keys = TourKeys(config: config)
        self.config = config
        self.configPath = configPath
        self.world = world
        self.tutor = tutor
        self.tourSurfaces = tourSurfaces
    }

    public var tutorSurface: TourSurface? { world.surface(tutor) }
    /// The workspace the tour lives on.
    public var home: Int { tutorSurface?.workspaceNumber ?? world.activeWorkspace ?? 1 }
    public var followsMouse: Bool { config.followMouse != 0 }
}

// MARK: Geometry

public enum TourGeometry {
    /// The direction to press to get from one tile to another.
    public static func direction(from a: TourRect, to b: TourRect) -> Direction {
        let dx = b.midX - a.midX, dy = b.midY - a.midY
        if abs(dx) >= abs(dy) { return dx < 0 ? .left : .right }
        return dy < 0 ? .up : .down
    }

    public static func word(_ d: Direction) -> String {
        switch d {
        case .left: "left"
        case .right: "right"
        case .up: "above"
        case .down: "below"
        }
    }

    public static func opposite(_ d: Direction) -> Direction {
        switch d {
        case .left: .right
        case .right: .left
        case .up: .down
        case .down: .up
        }
    }

    static func moved(_ a: TourRect?, _ b: TourRect?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.midX - b.midX) > 0.5 || abs(a.midY - b.midY) > 0.5
    }

    static func resized(_ a: TourRect?, _ b: TourRect?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.width - b.width) > 0.5 || abs(a.height - b.height) > 0.5
    }
}

// MARK: Ways back

public enum TourWayBack {
    /// The quickest way from wherever the user is back to the tour, in markup.
    /// Nil while the tour has the keyboard. `step` is the curriculum index: directional
    /// focus and ⌘` are only suggested once a step has taught them. Places only one key
    /// leaves (another workspace, the scratchpad, a hidden tab) always name it.
    /// `lastLeadsBack` says whether ⌘` (the previously focused tile) is the tour.
    public static func hint(_ world: TourWorld, tutor: UInt64, keys: TourKeys, followsMouse: Bool,
                            step: Int = Curriculum.count, lastLeadsBack: Bool = true) -> String? {
        guard let t = world.surface(tutor) else { return nil }
        if world.appActive == false { return "Switch back to Hyprmux with \(k("⌘Tab"))." }
        guard world.focused?.id != tutor else { return nil }
        if world.scratchpadVisible, !t.inScratchpad {
            return "Press \(TourMarkup.key(keys.scratchpad, unbound: "togglespecialworkspace")) to hide the scratchpad."
        }
        if let n = t.workspaceNumber, world.activeWorkspace != n {
            if let key = keys.workspace(n) { return "Press \(k(key)) to go back to workspace \(n)." }
            return "Click workspace \(n) in the bar."
        }
        if let g = t.group, g.active != tutor {
            return "Press \(TourMarkup.key(keys.nextTab, unbound: "changegroupactive")) to show the tour's tab."
        }
        if let f = world.focused, f.fullscreen != nil {
            return "Press \(TourMarkup.key(f.fullscreen == 1 ? keys.maximize : keys.fullscreen, unbound: "fullscreen")) to shrink this tile first."
        }
        var ways: [String] = []
        if step >= Curriculum.index("focus"), let f = world.focused, f.workspace == t.workspace,
           let key = keys.focus(TourGeometry.direction(from: f.frame, to: t.frame)) {
            ways.append(k(key))
        }
        if step > Curriculum.index("dwindle"), lastLeadsBack, let last = keys.last { ways.append(k(last)) }
        if !ways.isEmpty { return "Press \(ways.joined(separator: " or "))." }
        return followsMouse ? "Point at the tour tile." : "Click the tour tile."
    }

    static func k(_ chord: String) -> String { TourMarkup.key(chord, unbound: "") }
}
