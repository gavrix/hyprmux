import Foundation
import HyprmuxClientKit
import SimulatorBridge

/// Mobile.hmapp: one process for every device window (`"instances": "single"`). Each
/// launch Hyprmux sends gets an answer:
///
/// - restore tokens: the devices that are still running come back; the rest don't.
/// - arguments: the device they name opens without asking.
/// - otherwise: the running devices are offered, and Hyprmux opens the one picked.
///   With none running, a window says so.
///
/// It quits when its last window closes and no launch waits.
final class Mobile {
    let client: HMClient
    private var windows: [MobileWindow] = []
    /// Launches offered and not yet answered.
    private var offered: [String: HMLaunch] = [:]
    private var quitScheduled = false

    init(client: HMClient) {
        self.client = client
        client.onLaunch = { [weak self] launch in self?.handle(launch) }
    }

    private func handle(_ launch: HMLaunch) {
        let (devices, problems) = Devices.running()

        if !launch.restoreTokens.isEmpty {
            for token in launch.restoreTokens {
                if let d = devices.first(where: { $0.id == token }) { open(d, restoreToken: token, launch: launch) }
            }
            launch.done()
            quitIfIdle()
            return
        }

        let query = launch.args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            let named = devices.filter { $0.matches(query) }
            if named.count == 1 {
                open(named[0], launch: launch)
                launch.done()
                return
            }
            if named.isEmpty {
                show(message: "No running device matches “\(query)”", detail: hint(problems), launch: launch)
                return
            }
            offer(named, for: launch)
            return
        }

        if devices.isEmpty {
            show(message: "No devices available", detail: hint(problems), launch: launch)
            return
        }
        offer(devices, for: launch)
    }

    private func hint(_ problems: [String]) -> String {
        (["Boot an iOS Simulator or start an Android Virtual Device, then open Mobile again."] + problems)
            .joined(separator: "\n")
    }

    private func offer(_ devices: [Device], for launch: HMLaunch) {
        offered[launch.token] = launch
        launch.onOpen = { [weak self, weak launch] id in
            guard let self, let launch else { return }
            self.offered[launch.token] = nil
            // Look again: the list may be stale by the time someone picks.
            if let d = Devices.running().devices.first(where: { $0.id == id }) ?? devices.first(where: { $0.id == id }) {
                self.open(d, launch: launch)
            } else {
                self.show(message: "That device isn't running anymore", detail: "", launch: launch)
                return
            }
            launch.done()
        }
        launch.onCancel = { [weak self, weak launch] in
            guard let self, let launch else { return }
            self.offered[launch.token] = nil
            self.quitIfIdle()
        }
        launch.offer(devices.map(\.offer))
    }

    private func show(message: String, detail: String, launch: HMLaunch) {
        windows.append(MessageWindow(mobile: self, message: message, detail: detail, launch: launch))
        launch.done()
    }

    /// Opens a window for `device`. A device that fails to open shows why in the window.
    private func open(_ device: Device, restoreToken: String? = nil, launch: HMLaunch) {
        let token = restoreToken ?? device.id
        switch device.kind {
        case .ios(let udid):
            do {
                let display = try HMSimDisplay(query: udid)
                windows.append(IOSWindow(mobile: self, display: display, restoreToken: token, launch: launch))
            } catch {
                windows.append(MessageWindow(mobile: self, message: "Couldn't show \(device.name)",
                                             detail: error.localizedDescription, launch: launch))
            }
        case .android(let endpoint):
            do {
                windows.append(try AndroidWindow(mobile: self, endpoint: endpoint, restoreToken: token, launch: launch))
            } catch {
                windows.append(MessageWindow(mobile: self, message: "Couldn't show \(device.name)",
                                             detail: error.localizedDescription, launch: launch))
            }
        }
    }

    func windowClosed(_ w: MobileWindow) {
        windows.removeAll { $0 === w }
        quitIfIdle()
    }

    /// Quits once nothing is open or waiting, after a moment: a launch may be on its way.
    func quitIfIdle() {
        guard windows.isEmpty, offered.isEmpty, !quitScheduled else { return }
        quitScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.quitScheduled = false
            if self.windows.isEmpty, self.offered.isEmpty { exit(0) }
        }
    }
}
