import Foundation
import HyprmuxClientProtocol
import HyprmuxCore

/// One launch of an app (docs/CLIENT_PROTOCOL.md, section 10). Hyprmux doesn't reserve a
/// tile for it: the app answers with a window, or offers windows to pick from. The record
/// lives as long as the app's connection, so every window of the launch is stamped with
/// what ran, for the session.
final class AppLaunch {
    enum State: String {
        /// Nothing came back yet.
        case waiting
        /// The app offered several windows; the user is picking.
        case picking
        /// A window was asked for (`launch.open`) and hasn't come yet.
        case opening
        /// A window came, or the launch ended. Later windows are the app's own.
        case settled
    }

    /// How a launch ended, for the caller that waits on it (`hyprmuxctl launch`).
    enum Outcome {
        case window(ClientSurface)
        /// Several windows, and nobody to pick one: the caller gets the list.
        case offer([HMWindowOffer])
        /// The app said it opens nothing (`launch.done`).
        case nothing
        case failed(String)
    }

    let token = UUID().uuidString
    let label: String
    /// `new-surface --type app` text, for tiles not launched from the catalog.
    let argument: String
    /// The `.hmapp` id and the user's arguments, when launched from the catalog.
    let entry: String?
    /// Also the `launch` message's arguments.
    let entryArgs: [String]
    /// A single-instance app's id: the launch may go to its running process.
    let singleApp: String?

    /// Where its window goes, recorded when it started.
    var workspace: WorkspaceID?
    var focus = true
    var floating = false
    /// A person launched it: an offer opens the picker. Otherwise the offer goes back to
    /// the caller.
    var interactive = false
    /// The offered window to open without asking (`hyprmuxctl launch --window ID`).
    var window: String?
    /// Restored tiles waiting with their restore tokens. Their placement is the session's.
    var reserved: [ClientSurface] = []
    var restoring = false

    var state = State.waiting
    var offer: [HMWindowOffer] = []
    weak var connection: ClientConnection?
    /// The process Hyprmux started for it, if any.
    var process: Process?
    var startedAt = Date()
    /// Bumped to cancel a pending timeout check.
    var timerGeneration = 0
    /// The picker showing "Opening NAME…" or the offer.
    var pickerRequest: UUID?
    /// Escape in the picker returns here (the launcher).
    var back: (() -> Void)?
    var completion: ((Outcome) -> Void)?

    init(label: String, argument: String, entry: String?, entryArgs: [String], singleApp: String?) {
        self.label = label
        self.argument = argument
        self.entry = entry
        self.entryArgs = entryArgs
        self.singleApp = singleApp
    }

    var pending: Bool { state != .settled }

    /// Marks a tile as coming from this launch, so the session can relaunch it.
    func stamp(_ tile: ClientSurface) {
        tile.appEntry = entry
        tile.entryArgs = entryArgs
        tile.launchArgument = entry == nil ? argument : nil
    }

    /// The tile a toplevel fills: the restored one with its restore token, else the first
    /// still waiting. Nil when none waits.
    func takeReserved(restore: String?) -> ClientSurface? {
        guard !reserved.isEmpty else { return nil }
        let index = restore.flatMap { r in reserved.firstIndex { $0.restoreToken == r } } ?? 0
        return reserved.remove(at: index)
    }

    /// Calls the completion once.
    func finish(_ outcome: Outcome) {
        state = .settled
        timerGeneration += 1
        let done = completion
        completion = nil
        done?(outcome)
    }

    func sendLaunch(on connection: ClientConnection) {
        self.connection = connection
        connection.send(HMOp.launch, ["launch_token": token, "args": entryArgs,
                                      "restore_tokens": reserved.compactMap(\.restoreToken)])
    }
}
