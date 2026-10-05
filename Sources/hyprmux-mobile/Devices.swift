import AndroidEmulatorBridge
import Foundation
import HyprmuxClientKit
import SimulatorBridge

/// A device Mobile can show: a booted iOS Simulator or a running Android Emulator.
/// Its id is the window id Mobile offers and the restore token of its window.
struct Device: Equatable {
    enum Kind: Equatable {
        case ios(udid: String)
        case android(AndroidEmulatorEndpoint)
    }

    let kind: Kind
    let name: String
    let detail: String

    var id: String {
        switch kind {
        case .ios(let udid): "ios:\(udid)"
        case .android(let e): "android:\(e.avdID)"
        }
    }

    var offer: HMWindowOffer { HMWindowOffer(id: id, title: name, detail: detail) }

    /// What a user may type to name it: the window id, the UDID or AVD id, or its name.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        var names = [id, name]
        switch kind {
        case .ios(let udid): names.append(udid)
        case .android(let e): names.append(e.avdID)
        }
        return names.contains { $0.caseInsensitiveCompare(q) == .orderedSame }
    }
}

enum Devices {
    /// Booted simulators, then running emulators. A missing Xcode or Android SDK just
    /// means none of that kind.
    static func running() -> (devices: [Device], problems: [String]) {
        var devices: [Device] = []
        var problems: [String] = []
        do {
            for d in try HMSimulator.devices() where d.booted {
                devices.append(Device(kind: .ios(udid: d.udid), name: d.name, detail: runtimeName(d.runtime)))
            }
        } catch {
            problems.append("iOS Simulator: \(error.localizedDescription)")
        }
        for e in AndroidEmulatorDiscovery.running() {
            let detail = e.avdID == e.name ? "Android" : "Android · \(e.avdID)"
            devices.append(Device(kind: .android(e), name: e.name, detail: detail))
        }
        return (devices, problems)
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-0" → "iOS 27.0".
    static func runtimeName(_ id: String) -> String {
        guard let last = id.split(separator: ".").last else { return id }
        let parts = last.split(separator: "-")
        guard let os = parts.first else { return String(last) }
        return os + " " + parts.dropFirst().joined(separator: ".")
    }
}
