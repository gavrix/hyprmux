import Foundation
import HyprmuxCore
import HyprmuxTour

// hyprmux-tour: an interactive tour of Hyprmux that runs in one of its terminals.
// It only watches Hyprmux, through its event stream; the user does every step.

let usage = """
usage: hyprmux-tour [--restart | --step N | --welcome]
  Runs the Hyprmux tour in this terminal. Without options it picks up where you left off.
  --restart    start again from the beginning
  --step N     start at step N (0 is the welcome)
  --welcome    offer the tour, unless it was offered before (Hyprmux runs this on first launch)
"""

let env = ProcessInfo.processInfo.environment
var args = Array(CommandLine.arguments.dropFirst())
if args.contains("-h") || args.contains("--help") {
    print(usage)
    exit(0)
}
let welcomeMode = args.contains("--welcome")
let restart = args.contains("--restart")
var requestedStep: Int?
if let i = args.firstIndex(of: "--step") {
    guard i + 1 < args.count, let n = Int(args[i + 1]), n >= 0, n < Curriculum.count else {
        FileHandle.standardError.write("hyprmux-tour: --step expects 0 to \(Curriculum.count - 1)\n".data(using: .utf8)!)
        exit(2)
    }
    requestedStep = n
}

guard let tutorID = env["HYPRMUX_SURFACE_ID"].flatMap(UInt64.init), env["HYPRMUX_SOCKET"] != nil else {
    FileHandle.standardError.write("hyprmux-tour runs inside a Hyprmux terminal. Open Hyprmux and run it there.\n".data(using: .utf8)!)
    exit(1)
}
guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
    FileHandle.standardError.write("hyprmux-tour needs an interactive terminal.\n".data(using: .utf8)!)
    exit(1)
}

let socketPath = IPCPath.default
let configPath: String = {
    if let p = env["HYPRMUX_CONFIG"], !p.isEmpty { return (p as NSString).expandingTildeInPath }
    return ("~/.config/hyprmux/hyprmux.conf" as NSString).expandingTildeInPath
}()
let hyprmuxPID = env["HYPRMUX_PID"]

let saved = TourState.load()
// The first-launch offer happens once.
if welcomeMode, saved != nil { exit(0) }

// MARK: Watching Hyprmux

/// From `appactive` events; the subscription's first lines say where it starts.
var appActive: Bool?

func fetchWorld() throws -> TourWorld {
    let clients = try HyprmuxSocket.request("clients", path: socketPath)
    let workspaces = try HyprmuxSocket.request("workspaces", path: socketPath)
    return try TourWorld.decode(clients: clients, workspaces: workspaces, appActive: appActive)
}

func loadConfig() -> HyprmuxConfig { ConfigParser.load(path: configPath) }

func hyprmuxAlive() -> Bool {
    guard let pid = hyprmuxPID.flatMap(Int32.init) else { return true }
    return kill(pid, 0) == 0 || errno == EPERM
}

// Subscribe before the first look, so no change falls between the two.
var eventsFD: Int32 = -1
var firstWorld: TourWorld?
for _ in 0..<10 {
    if eventsFD < 0 { eventsFD = (try? HyprmuxSocket.subscribe(path: socketPath)) ?? -1 }
    if eventsFD >= 0, let w = try? fetchWorld() {
        firstWorld = w
        break
    }
    usleep(200_000)
}
guard let firstWorld else {
    FileHandle.standardError.write("hyprmux-tour: can't reach Hyprmux at \(socketPath)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: State

var state = saved ?? TourState()
if restart || state.completed { state = TourState() }
if let requestedStep { state.step = requestedStep }
if state.hyprmuxPID != hyprmuxPID || state.tourSurfaces.isEmpty || restart {
    state.hyprmuxPID = hyprmuxPID
    state.tourSurfaces = Array(firstWorld.ids).sorted()
}
state.save()

var engine = TourEngine(index: state.step, world: firstWorld, tutor: tutorID, tourSurfaces: Set(state.tourSurfaces),
                        config: loadConfig(), configPath: configPath)

// MARK: Signals

nonisolated(unsafe) var interrupted: sig_atomic_t = 0
for s in [SIGINT, SIGTERM, SIGHUP] {
    signal(s, { _ in interrupted = 1 })
}
nonisolated(unsafe) var resized: sig_atomic_t = 0
signal(SIGWINCH, { _ in resized = 1 })

// MARK: Drawing

let terminal = Terminal()

func paragraph(_ text: String, width: Int, tone: Terminal.Tone = .normal, base: TourStyle = .plain,
               marker: [TourSpan] = []) -> [String] {
    let markerWidth = marker.reduce(0) { $0 + $1.text.count }
    let line = marker + TourMarkup.parse(text, base: base)
    return TourWrap.wrap(line, width: width, indent: markerWidth).map { "  " + Terminal.render($0, tone: tone) }
}

var unreachable: String?
var message: String?
/// When the current return task started waiting with the tour out of focus.
var awaySince: Date?
/// The task that already got its notification.
var nudged: (step: Int, task: Int)?
let hintAfter: TimeInterval = 6
let nudgeAfter: TimeInterval = 20

func frame() -> [String] {
    let (columns, rows) = terminal.size
    let width = max(20, columns - 4)
    let step = engine.step

    var header: [String] = []
    var heading = "Hyprmux tour"
    if let (n, total) = Curriculum.number(engine.index) { heading += " · \(n) of \(total)" }
    header += paragraph(heading, width: width, tone: .dim)
    header.append("")
    header += paragraph("*\(step.title)*", width: width)
    header.append("")

    var body: [String] = []
    for p in step.body {
        body += paragraph(p, width: width)
        body.append("")
    }

    var tasks: [String] = []
    for (i, task) in step.tasks.enumerated() {
        if i < engine.taskIndex {
            tasks += paragraph(task.text, width: width, tone: .dim, marker: [TourSpan("✓ ", .success)])
        } else if i == engine.taskIndex {
            tasks += paragraph(task.text, width: width, marker: [TourSpan("▸ ", .accent)])
            if let p = task.progress?(engine.input) {
                tasks += paragraph(p, width: width, base: .accent, marker: [TourSpan("  ")])
            }
        } else {
            tasks += paragraph(task.text, width: width, tone: .dim, marker: [TourSpan("· ")])
        }
    }
    // Give the taught way a moment before suggesting the quickest one.
    // Only when it names a key: the mouse is in the task text already.
    if let way = engine.wayBack, TourMarkup.hasKey(way), let since = awaySince, Date().timeIntervalSince(since) > hintAfter {
        tasks.append("")
        tasks += paragraph("From where you are: " + way, width: width, base: .accent)
    }
    if !tasks.isEmpty { tasks.append("") }

    var notes: [String] = []
    for n in step.notes {
        notes += paragraph(n, width: width, tone: .dim)
        notes.append("")
    }

    var status: [String] = []
    if let unreachable {
        status += paragraph(unreachable, width: width, base: .warning)
    } else if let message {
        status += paragraph(message, width: width, base: .warning)
    } else if engine.index == 0 {
        status += paragraph("Press Return to start.", width: width, base: .success)
    } else if engine.isLastStep {
        status += paragraph("Press Return to finish.", width: width, base: .success)
    } else if engine.isStepDone {
        status += paragraph("✓ Done. Press Return for the next step.", width: width, base: .success)
    }

    let keys = engine.index == 0 ? "Return start · q not now"
        : engine.isLastStep ? "Return finish · b back"
        : "Return next · b back · s skip · r redo · q quit"
    let footer = paragraph(keys, width: width, tone: .dim)

    // Too tall for the tile: drop the notes, then the body, then cut.
    var sections = [header, body, tasks, notes, status]
    func height() -> Int { sections.reduce(0) { $0 + $1.count } + 1 + footer.count }
    if height() > rows { sections[3] = [] }
    if height() > rows { sections[1] = [] }
    var lines = Array(sections.joined())
    let room = max(0, rows - footer.count - 1)
    if lines.count > room { lines = Array(lines.prefix(room)) }
    lines += Array(repeating: "", count: max(0, rows - footer.count - lines.count))
    return lines + footer
}

func setTitle() {
    if let (n, total) = Curriculum.number(engine.index) {
        terminal.setTitle("Hyprmux tour · \(n)/\(total)")
    } else {
        terminal.setTitle("Hyprmux tour")
    }
}

// MARK: The loop

enum Ending { case finished, quit, gone }

func go(to index: Int) {
    let world = (try? fetchWorld()) ?? engine.world
    engine.begin(index, world: world, config: loadConfig())
    state.step = engine.index
    state.save()
    message = nil
    setTitle()
}


func run() -> Ending {
    terminal.enter()
    defer { terminal.leave() }
    setTitle()
    engine.update(engine.world)

    var pending = ""
    /// Events a failed look at Hyprmux couldn't use yet.
    var carried: [HyprmuxEvent] = []
    while interrupted == 0 {
        if resized != 0 {
            resized = 0
            terminal.invalidate()
        }
        terminal.draw(frame())

        // Wait for a key or an event. The timeout only keeps the hint and nudge timers going.
        var fds = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: eventsFD, events: Int16(POLLIN), revents: 0)]
        guard poll(&fds, 2, 500) >= 0 || errno == EINTR else { return .gone }
        let keys = fds[0].revents & Int16(POLLIN) != 0 ? terminal.readInput() : []

        var events = carried
        carried = []
        if fds[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let n = read(eventsFD, &buffer, buffer.count)
            if n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN) { return .gone }
            if n > 0 {
                pending += String(decoding: buffer[0..<n], as: UTF8.self)
                while let newline = pending.firstIndex(of: "\n") {
                    if let e = HyprmuxEvent.parse(String(pending[..<newline])) { events.append(e) }
                    pending = String(pending[pending.index(after: newline)...])
                }
            }
        }
        for e in events where e.name == "appactive" { appActive = e.data == "1" }

        for byte in keys {
            switch byte {
            case 0x0D, 0x0A:
                if engine.isLastStep {
                    state.completed = true
                    state.step = 0
                    state.save()
                    return .finished
                }
                if engine.isStepDone || engine.index == 0 {
                    go(to: engine.index + 1)
                } else {
                    message = "Finish the step first, or press s to skip it."
                }
            case UInt8(ascii: "s"):
                if engine.isLastStep { return .finished }
                go(to: engine.index + 1)
            case UInt8(ascii: "b"):
                if engine.index > 0 { go(to: engine.index - 1) }
            case UInt8(ascii: "r"):
                go(to: engine.index)
            case UInt8(ascii: "q"):
                return .quit
            default:
                break
            }
        }

        if !events.isEmpty || !keys.isEmpty || unreachable != nil {
            do {
                let world = try fetchWorld()
                unreachable = nil
                if engine.update(world, events: events) > 0 { message = nil }
            } catch {
                if !hyprmuxAlive() { return .gone }
                carried = events
                unreachable = "Can't reach Hyprmux right now. Retrying…"
            }
        }

        // Lost? After a while away, a notification says how to get back. Clicking it
        // focuses this tile, too.
        if let task = engine.currentTask, task.isReturn, let way = engine.wayBack {
            let since = awaySince ?? Date()
            awaySince = since
            if Date().timeIntervalSince(since) > nudgeAfter, nudged?.step != engine.index || nudged?.task != engine.taskIndex {
                nudged = (engine.index, engine.taskIndex)
                terminal.notify("Hyprmux tour: " + TourMarkup.plain(way))
            }
        } else {
            awaySince = nil
        }
    }
    return .quit
}

let ending = run()
switch ending {
case .finished:
    print("Tour finished. Run hyprmux-tour --restart to take it again.")
case .quit:
    state.save()
    if engine.index == 0 {
        print("Run hyprmux-tour any time to take the tour.")
    } else {
        print("Tour paused. Run hyprmux-tour to continue.")
    }
case .gone:
    print("Hyprmux quit. Run hyprmux-tour to continue.")
}
terminal.setTitle("")
