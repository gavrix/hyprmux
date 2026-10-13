import AppKit
import HyprmuxCore

// Agent browser control's view of the compositor (AgentBrowserControl).
extension Compositor: AgentBrowserHost {
    var agentBrowserSurfaces: [ChromiumSurface] {
        views.keys.sorted { $0.raw < $1.raw }.compactMap { views[$0]?.surface as? ChromiumSurface }
    }

    func agentBrowserSurface(_ id: ClientID) -> ChromiumSurface? {
        views[id]?.surface as? ChromiumSurface
    }

    var agentBrowserPreferredTile: ClientID? {
        guard let id = wm.focused, views[id]?.surface is ChromiumSurface else { return nil }
        return id
    }

    /// A background tile on the focused window's workspace, as `new-surface --type web` opens one.
    func agentBrowserOpenTile(url: String) -> ClientID? {
        guard webEngine == "chromium" else { return nil }
        let web = makeWeb(url, focusStartPage: false)
        web.opensInBackground = true
        adopt(web)
        wm.addClient(web.clientID, focus: false)
        apply(animated: true)
        return web.clientID
    }

    func agentBrowserCloseTile(_ id: ClientID) {
        views[id]?.surface.requestClose()
    }
}
