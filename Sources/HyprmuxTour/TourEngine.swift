import Foundation
import HyprmuxCore

/// The tour's progress: which step, which task, and what Hyprmux looked like when
/// they began. It only reads worlds; it never acts on Hyprmux.
public struct TourEngine: Sendable {
    public let tutor: UInt64
    public let tourSurfaces: Set<UInt64>
    public let configPath: String
    public private(set) var index: Int
    public private(set) var step: TourStep
    /// The current task. Equal to `step.tasks.count` once the step is done.
    public private(set) var taskIndex = 0
    public private(set) var start: TourWorld
    public private(set) var mark: TourWorld
    public private(set) var world: TourWorld
    public private(set) var previous: TourWorld
    public private(set) var keys: TourKeys
    public private(set) var followsMouse: Bool
    /// Focused surfaces as the tour saw them, oldest first, without repeats in a row.
    /// ⌘` goes to the one before the current, like Hyprmux's own recency.
    public private(set) var focusHistory: [UInt64] = []
    /// Events since the current task began.
    public private(set) var events: [HyprmuxEvent] = []

    public init(index: Int, world: TourWorld, tutor: UInt64, tourSurfaces: Set<UInt64>,
                config: HyprmuxConfig, configPath: String) {
        self.tutor = tutor
        self.tourSurfaces = tourSurfaces
        self.configPath = configPath
        self.index = max(0, min(index, Curriculum.count - 1))
        self.start = world
        self.mark = world
        self.world = world
        self.previous = world
        self.keys = TourKeys(config: config)
        self.followsMouse = config.followMouse != 0
        self.step = Curriculum.step(self.index, TourContext(config: config, configPath: configPath, world: world,
                                                            tutor: tutor, tourSurfaces: tourSurfaces))
    }

    public var isStepDone: Bool { taskIndex >= step.tasks.count }
    public var isLastStep: Bool { index == Curriculum.count - 1 }
    public var currentTask: TourTask? { isStepDone ? nil : step.tasks[taskIndex] }

    public var input: TaskInput {
        TaskInput(world: world, start: start, mark: mark, previous: previous, tutor: tutor, tourSurfaces: tourSurfaces,
                  events: events)
    }

    /// Starts step `index` from scratch. The config is read again, since the user may
    /// have changed their keys.
    public mutating func begin(_ index: Int, world: TourWorld, config: HyprmuxConfig) {
        self.index = max(0, min(index, Curriculum.count - 1))
        self.world = world
        previous = world
        start = world
        mark = world
        taskIndex = 0
        events = []
        keys = TourKeys(config: config)
        followsMouse = config.followMouse != 0
        step = Curriculum.step(self.index, TourContext(config: config, configPath: configPath, world: world,
                                                       tutor: tutor, tourSurfaces: tourSurfaces))
    }

    /// Takes a new look at Hyprmux, with the events that led to it, and finishes every
    /// task it satisfies, in order. Returns how many tasks finished.
    @discardableResult
    public mutating func update(_ world: TourWorld, events new: [HyprmuxEvent] = []) -> Int {
        previous = self.world
        self.world = world
        events += new
        if let f = world.focused?.id, focusHistory.last != f {
            focusHistory.removeAll { $0 == f }
            focusHistory.append(f)
            if focusHistory.count > 32 { focusHistory.removeFirst() }
        }
        var finished = 0
        while let task = currentTask, task.check(input) {
            taskIndex += 1
            mark = world
            events = []
            finished += 1
        }
        return finished
    }

    /// The way back to the tour from wherever the user is, while a return task waits.
    public var wayBack: String? {
        guard currentTask?.isReturn == true else { return nil }
        let previous = focusHistory.count > 1 ? focusHistory[focusHistory.count - 2] : nil
        return TourWayBack.hint(world, tutor: tutor, keys: keys, followsMouse: followsMouse, step: index,
                                lastLeadsBack: previous == tutor)
    }
}
