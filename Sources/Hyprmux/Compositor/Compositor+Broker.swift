import AppKit
import HyprmuxClientProtocol
import HyprmuxCore
import ServiceManagement

/// The broker agent app tiles connect through (BrokerRegistration): registering it on
/// launch, guiding the user through Login Items, and `hyprmuxctl broker`.
extension Compositor {
    static let brokerNoticeKey = "broker"

    func startBrokerRegistration() {
        broker.onChange = { [weak self] old, new in self?.brokerChanged(from: old, to: new) }
        broker.update(setting: config.registerBroker)
    }

    private func brokerChanged(from old: BrokerRegistration.Outcome, to new: BrokerRegistration.Outcome) {
        switch new {
        case .enabled:
            hud.notifications.dismiss(key: Self.brokerNoticeKey)
            clientServer.retryNow()
            if old == .requiresApproval { hud.notifications.post(.success, "App tiles are ready.") }
        case .requiresApproval:
            if !brokerApprovalShown { showBrokerNotice() }
        case .failed, .notFound:
            showBrokerNotice()
        case .notChecked, .notBundled, .disabled, .otherBroker:
            hud.notifications.dismiss(key: Self.brokerNoticeKey)
        }
    }

    /// The notice for the current outcome, when there is something the user can do.
    /// Returns false when the outcome has no notice.
    @discardableResult
    private func showBrokerNotice() -> Bool {
        let openLoginItems = { SMAppService.openSystemSettingsLoginItems() }
        switch broker.outcome {
        case .requiresApproval:
            brokerApprovalShown = true
            hud.notifications.post(.warning, "Allow Hyprmux in Login Items to open apps in tiles.\nClick to open Login Items.",
                                   sticky: true, key: Self.brokerNoticeKey, action: openLoginItems)
        case .failed(let why):
            hud.notifications.post(.error, title: "App tiles can't connect",
                                   "macOS didn't let Hyprmux start its helper for app tiles: \(why)\nClick to open Login Items.",
                                   sticky: true, key: Self.brokerNoticeKey, action: openLoginItems)
        case .notFound:
            hud.notifications.post(.error, title: "App tiles can't connect",
                                   "This copy of Hyprmux has no hyprmux-broker launch agent. Rebuild it with scripts/bundle.sh.",
                                   sticky: true, key: Self.brokerNoticeKey)
        default:
            return false
        }
        return true
    }

    /// An app tile is waiting, but Hyprmux isn't registered with the broker.
    func explainBrokerUnavailable() {
        if showBrokerNotice() { return }
        switch broker.outcome {
        case .notBundled:
            flash("Client apps need hyprmux-broker. Run scripts/dev-broker.sh load.")
        case .disabled:
            flash("Apps can't open in tiles while misc:register_broker is off. Turn it on, or start the helper yourself.")
        case .otherBroker:
            flash("Apps can't open in tiles right now. hyprmuxctl broker status says why.")
        default:
            flash("Hyprmux is still connecting to its helper for app tiles. Try again in a moment.")
        }
    }

    // MARK: hyprmuxctl broker

    /// `broker status|register|unregister`. Pings the broker and asks launchd, so it
    /// replies off the main thread.
    func brokerReply(_ action: BrokerAction) -> IPCReply {
        .background { [weak self] in
            if action != .status {
                guard BrokerRegistration.isBundled else {
                    return "error: broker \(action.rawValue): Hyprmux isn't running from an app bundle"
                }
                let service = BrokerRegistration.service
                var problem: String?
                do {
                    if action == .register { try service.register() } else { try service.unregister() }
                } catch {
                    problem = error.localizedDescription
                }
                let status = service.status
                DispatchQueue.main.sync { self?.broker.adopt(status) }
                if let problem {
                    return "error: broker \(action.rawValue): \(problem) (agent: \(BrokerRegistration.statusName(status)))"
                }
            }
            var text = "error: not ready"
            let probed = Self.brokerProbe()
            DispatchQueue.main.sync {
                guard let self else { return }
                text = self.jsonText(self.brokerJSON(probed))
            }
            return text
        }
    }

    /// What only a background thread may ask: SMAppService, the lookup ping, launchd.
    private static func brokerProbe() -> [String: Any] {
        var o: [String: Any] = [:]
        o["agent"] = BrokerRegistration.isBundled ? BrokerRegistration.statusName(BrokerRegistration.service.status) : "not-bundled"
        o["lookup"] = BrokerRegistration.lookupServiceExists()
        if let job = BrokerRegistration.launchdJob() { o["launchd"] = job } else { o["launchd"] = NSNull() }
        return o
    }

    private func brokerJSON(_ probed: [String: Any]) -> [String: Any] {
        var o = probed
        o["bundle"] = Bundle.main.bundlePath
        if BrokerRegistration.isBundled { o["plist"] = BrokerRegistration.plistURL.path } else { o["plist"] = NSNull() }
        o["setting"] = config.registerBroker
        o["outcome"] = broker.outcome.name
        if case .failed(let why) = broker.outcome { o["failure"] = why }
        o["instance"] = clientServer.instance
        o["registered"] = clientServer.registered
        o["clients"] = clientServer.clientCount
        return o
    }
}
