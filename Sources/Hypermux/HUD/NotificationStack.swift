import AppKit
import HypermuxCore

/// Notifications in a corner of the work area (`hud:notifications:position`),
/// newest nearest the corner. They expire on a timer, stay open while the pointer
/// is over them, and close on click.
final class NotificationStack {
    private unowned let hud: HUD
    private var queue: NoticeQueue
    private var views: [Notice.ID: NotificationView] = [:]
    private var timer: DispatchWorkItem?

    init(hud: HUD) {
        self.hud = hud
        queue = NoticeQueue(maxVisible: hud.config.hud.maxNotifications)
    }

    private var now: Double { CACurrentMediaTime() }
    private var settings: HUDSettings { hud.config.hud }
    /// Notifications slide in from their nearest edge unless the config sets a layers style.
    private let defaultStyle = LayerAnimationStyle.slide(nil)

    /// Shows a notification. `sticky` ones stay until clicked (or dismissed by key).
    /// A `key` updates an existing notice in place instead of adding one.
    @discardableResult
    func post(_ level: NoticeLevel, title: String = "", _ body: String,
              sticky: Bool = false, key: String? = nil, source: ClientID? = nil) -> Notice.ID {
        let t = settings.notificationTimeout
        let n = Notice(level: level, title: title, body: body,
                       timeout: sticky || t <= 0 ? nil : t, key: key, source: source)
        let id = queue.post(n, now: now)
        log.info("notice \(level.rawValue, privacy: .public): \(title, privacy: .public) \(body, privacy: .public)")
        relayout(animated: true)
        return id
    }

    func dismiss(key: String) {
        guard queue.dismiss(key: key) else { return }
        relayout(animated: true)
    }

    func dismiss(_ id: Notice.ID) {
        guard queue.dismiss(id) else { return }
        relayout(animated: true)
    }

    /// Config reloaded: new limit, and redraw everything with the new theme.
    func reload() {
        queue.maxVisible = settings.maxNotifications
        // Rebuild so decoration, fonts, and colors all come from the new theme.
        for v in views.values {
            v.closing = true
            v.removeFromSuperview()
        }
        views.removeAll()
        relayout(animated: false)
    }

    /// Brings the views in line with the queue: new ones animate in, gone ones out,
    /// and the rest reflow.
    func relayout(animated: Bool) {
        let area = hud.workArea
        guard area.width > 0, area.height > 0 else { return }
        let position = settings.notificationPosition
        let width = min(CGFloat(settings.notificationWidth), area.width - 2 * hud.margin)
        let notices = queue.notices

        let live = Set(notices.map(\.id))
        for (id, v) in views where !live.contains(id) {
            v.closing = true
            views[id] = nil
            hud.animateOut(v, position: position, defaultStyle: defaultStyle)
        }

        var sizes: [CGSize] = []
        var fresh: Set<Notice.ID> = []
        for n in notices {
            let v: NotificationView
            if let existing = views[n.id] {
                v = existing
            } else {
                v = makeView(n)
                views[n.id] = v
                fresh.insert(n.id)
            }
            sizes.append(CGSize(width: width, height: v.update(n, theme: hud.theme, width: width)))
        }
        let frames = HUDLayout.stack(sizes, at: position, in: area, margin: hud.margin, spacing: hud.spacing)
        for (n, frame) in zip(notices, frames) {
            guard let v = views[n.id] else { continue }
            if fresh.contains(n.id) {
                if animated {
                    hud.animateIn(v, to: frame, position: position, defaultStyle: defaultStyle)
                } else {
                    hud.layer.addSubview(v)
                    v.move(to: frame, duration: 0, curve: .linear, animator: hud.animator)
                    v.alphaValue = 1
                }
            } else {
                hud.animateMove(v, to: frame, animated: animated)
            }
        }
        schedule()
    }

    private func makeView(_ n: Notice) -> NotificationView {
        let v = NotificationView(id: n.id, theme: hud.theme, level: n.level)
        let id = n.id
        v.onClick = { [weak self] in
            guard let self else { return }
            if let source = self.queue.notice(id)?.source { self.hud.onFocusClient?(source) }
            self.dismiss(id)
        }
        v.onHover = { [weak self] inside in
            guard let self else { return }
            if inside { self.queue.hold(id, now: self.now) } else { self.queue.release(id, now: self.now) }
            self.schedule()
        }
        return v
    }

    /// Wakes up at the next expiry.
    private func schedule() {
        timer?.cancel()
        timer = nil
        guard let deadline = queue.nextDeadline else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.queue.expire(now: self.now + 0.01).isEmpty { self.relayout(animated: true) } else { self.schedule() }
        }
        timer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, deadline - now), execute: item)
    }
}
