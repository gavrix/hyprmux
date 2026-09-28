import CoreGraphics
import XCTest
@testable import HypermuxCore

final class HUDLayoutTests: XCTestCase {
    let area = CGRect(x: 0, y: 30, width: 1000, height: 600)

    func testPositionParsing() {
        XCTAssertEqual(HUDPosition(config: "top_right"), .topRight)
        XCTAssertEqual(HUDPosition(config: "top-right"), .topRight)
        XCTAssertEqual(HUDPosition(config: "BottomLeft"), .bottomLeft)
        XCTAssertEqual(HUDPosition(config: "center"), .center)
        XCTAssertNil(HUDPosition(config: "middle"))
    }

    func testPlaceCornersAndCenter() {
        let s = CGSize(width: 200, height: 100)
        XCTAssertEqual(HUDLayout.place(s, at: .topRight, in: area, margin: 10), CGRect(x: 790, y: 40, width: 200, height: 100))
        XCTAssertEqual(HUDLayout.place(s, at: .bottomLeft, in: area, margin: 10), CGRect(x: 10, y: 520, width: 200, height: 100))
        XCTAssertEqual(HUDLayout.place(s, at: .center, in: area, margin: 10), CGRect(x: 400, y: 280, width: 200, height: 100))
        XCTAssertEqual(HUDLayout.place(s, at: .top, in: area, margin: 10), CGRect(x: 400, y: 40, width: 200, height: 100))
    }

    func testPlaceShrinksToFit() {
        let r = HUDLayout.place(CGSize(width: 2000, height: 50), at: .topLeft, in: area, margin: 10)
        XCTAssertEqual(r, CGRect(x: 10, y: 40, width: 980, height: 50))
    }

    func testStackGrowsAwayFromEdge() {
        let sizes = [CGSize(width: 300, height: 60), CGSize(width: 300, height: 80)]
        let down = HUDLayout.stack(sizes, at: .topRight, in: area, margin: 10, spacing: 8)
        XCTAssertEqual(down, [CGRect(x: 690, y: 40, width: 300, height: 60), CGRect(x: 690, y: 108, width: 300, height: 80)])
        let up = HUDLayout.stack(sizes, at: .bottomRight, in: area, margin: 10, spacing: 8)
        XCTAssertEqual(up, [CGRect(x: 690, y: 560, width: 300, height: 60), CGRect(x: 690, y: 472, width: 300, height: 80)])
    }

    func testCenteredStackIsCenteredAsABlock() {
        let sizes = [CGSize(width: 200, height: 50), CGSize(width: 100, height: 50)]
        let frames = HUDLayout.stack(sizes, at: .center, in: area, margin: 0, spacing: 10)
        XCTAssertEqual(frames[0], CGRect(x: 400, y: 275, width: 200, height: 50))
        XCTAssertEqual(frames[1], CGRect(x: 450, y: 335, width: 100, height: 50))
    }

    func testAnchorAreas() {
        let monitor = CGRect(x: 0, y: 0, width: 1000, height: 630)
        let tile = CGRect(x: 100, y: 100, width: 300, height: 200)
        let lookup: (ClientID) -> CGRect? = { $0 == ClientID(1) ? tile : nil }
        XCTAssertEqual(HUDLayout.area(for: .monitor(.center), monitor: monitor, workArea: area, clientFrame: lookup), monitor)
        XCTAssertEqual(HUDLayout.area(for: .workArea(.top), monitor: monitor, workArea: area, clientFrame: lookup), area)
        XCTAssertEqual(HUDLayout.area(for: .client(ClientID(1), .center), monitor: monitor, workArea: area, clientFrame: lookup), tile)
        XCTAssertNil(HUDLayout.area(for: .client(ClientID(2), .center), monitor: monitor, workArea: area, clientFrame: lookup))
    }

    func testLayerAnimationStyles() {
        XCTAssertEqual(LayerAnimationStyle(nil), .slide(nil))
        XCTAssertEqual(LayerAnimationStyle("slide top"), .slide(.up))
        XCTAssertEqual(LayerAnimationStyle("popin 90%"), .popin(0.9))
        XCTAssertEqual(LayerAnimationStyle("popin"), .popin(0.8))
        XCTAssertEqual(LayerAnimationStyle("fade"), .fade)
        let f = CGRect(x: 700, y: 40, width: 300, height: 60)
        XCTAssertEqual(LayerAnimationStyle.slide(nil).offscreen(f, position: .topRight, distance: 50), f.offsetBy(dx: 50, dy: 0))
        XCTAssertEqual(LayerAnimationStyle.slide(nil).offscreen(f, position: .top, distance: 50), f.offsetBy(dx: 0, dy: -50))
        XCTAssertEqual(LayerAnimationStyle.slide(.down).offscreen(f, position: .topRight, distance: 50), f.offsetBy(dx: 0, dy: 50))
        XCTAssertEqual(LayerAnimationStyle.popin(0.5).offscreen(f, position: .center, distance: 0),
                       CGRect(x: 775, y: 55, width: 150, height: 30))
        XCTAssertEqual(LayerAnimationStyle.fade.offscreen(f, position: .center, distance: 50), f)
    }

    func testLayerAnimationTree() {
        let c = ConfigParser.parse("""
        animation = layers, 1, 3, default, popin 90%
        animation = fadeLayersIn, 1, 2, default
        animation = fade, 1, 5, default
        """)
        XCTAssertEqual(c.errors, [])
        XCTAssertEqual(c.animation("layersIn").duration, 0.3, accuracy: 1e-9)
        XCTAssertEqual(c.animation("layersIn").style, "popin 90%")
        XCTAssertEqual(c.animation("fadeLayersIn").duration, 0.2, accuracy: 1e-9)
        XCTAssertEqual(c.animation("fadeLayersOut").duration, 0.5, accuracy: 1e-9)
    }

    func testHUDConfig() {
        let c = ConfigParser.parse("""
        hud {
            font_family = Iosevka Term
            font_size = 14
            notifications {
                position = bottom-left
                timeout = 2500
                max_visible = 3
                width = 420
            }
            picker {
                width = 700
                max_rows = 8
            }
        }
        """)
        XCTAssertEqual(c.errors, [])
        XCTAssertEqual(c.hud.fontFamily, "Iosevka Term")
        XCTAssertEqual(c.hud.fontSize, 14)
        XCTAssertEqual(c.hud.notificationPosition, .bottomLeft)
        XCTAssertEqual(c.hud.notificationTimeout, 2.5)
        XCTAssertEqual(c.hud.maxNotifications, 3)
        XCTAssertEqual(c.hud.notificationWidth, 420)
        XCTAssertEqual(c.hud.pickerWidth, 700)
        XCTAssertEqual(c.hud.pickerMaxRows, 8)
        XCTAssertEqual(ConfigParser.parse("hud:notifications:position = nowhere").errors.count, 1)
        let defaults = ConfigParser.parse(defaultConfig).hud
        XCTAssertNil(defaults.fontFamily)
        XCTAssertEqual(defaults.notificationPosition, .topRight)
    }
}

final class NoticeQueueTests: XCTestCase {
    func testNewestFirstAndExpiry() {
        var q = NoticeQueue()
        let a = q.post(Notice(body: "a", timeout: 5), now: 0)
        let b = q.post(Notice(body: "b", timeout: 2), now: 1)
        XCTAssertEqual(q.notices.map(\.id), [b, a])
        XCTAssertEqual(q.nextDeadline, 3)
        XCTAssertEqual(q.expire(now: 3), [b])
        XCTAssertEqual(q.expire(now: 4), [])
        XCTAssertEqual(q.expire(now: 5), [a])
        XCTAssertTrue(q.notices.isEmpty)
    }

    func testStickyNeverExpires() {
        var q = NoticeQueue()
        q.post(Notice(body: "sticky", timeout: nil), now: 0)
        XCTAssertNil(q.nextDeadline)
        XCTAssertEqual(q.expire(now: 1e9), [])
    }

    func testDuplicatesCollapseAndRestartTheClock() {
        var q = NoticeQueue()
        let a = q.post(Notice(level: .warning, body: "no simulator", timeout: 5), now: 0)
        let again = q.post(Notice(level: .warning, body: "no simulator", timeout: 5), now: 4)
        XCTAssertEqual(a, again)
        XCTAssertEqual(q.notices.count, 1)
        XCTAssertEqual(q.notices[0].count, 2)
        XCTAssertEqual(q.notices[0].expires, 9)
        // A different level is a different notice.
        q.post(Notice(level: .error, body: "no simulator", timeout: 5), now: 4)
        XCTAssertEqual(q.notices.count, 2)
    }

    func testKeyUpdatesInPlace() {
        var q = NoticeQueue()
        let e = q.post(Notice(level: .error, body: "1 error", timeout: nil, key: "config"), now: 0)
        q.post(Notice(body: "other"), now: 0)
        let e2 = q.post(Notice(level: .error, body: "2 errors", timeout: nil, key: "config"), now: 1)
        XCTAssertEqual(e, e2)
        XCTAssertEqual(q.notices.map(\.body), ["other", "2 errors"])
        XCTAssertTrue(q.dismiss(key: "config"))
        XCTAssertFalse(q.dismiss(key: "config"))
        XCTAssertEqual(q.notices.map(\.body), ["other"])
    }

    func testMaxVisibleDropsOldestTimedFirst() {
        var q = NoticeQueue(maxVisible: 2)
        q.post(Notice(body: "sticky", timeout: nil), now: 0)
        q.post(Notice(body: "old"), now: 1)
        q.post(Notice(body: "new"), now: 2)
        XCTAssertEqual(q.notices.map(\.body), ["new", "sticky"])
        q.maxVisible = 1
        XCTAssertEqual(q.notices.map(\.body), ["sticky"])
    }

    func testHoldPausesTheClock() {
        var q = NoticeQueue()
        let a = q.post(Notice(body: "a", timeout: 5), now: 0)
        q.hold(a, now: 4)
        XCTAssertEqual(q.expire(now: 100), [])
        q.release(a, now: 100)
        XCTAssertEqual(q.notice(a)?.expires, 101.5)  // 1 s left, raised to the 1.5 s minimum
        let b = q.post(Notice(body: "b", timeout: 5), now: 0)
        q.hold(b, now: 1)
        q.release(b, now: 10)
        XCTAssertEqual(q.notice(b)?.expires, 14)
    }

    func testDismiss() {
        var q = NoticeQueue()
        let a = q.post(Notice(body: "a"), now: 0)
        XCTAssertTrue(q.dismiss(a))
        XCTAssertFalse(q.dismiss(a))
        q.post(Notice(body: "b"), now: 0)
        q.dismissAll()
        XCTAssertTrue(q.notices.isEmpty)
    }
}

final class GhosttyConfigScanTests: XCTestCase {
    func testFontFamilyFollowsGhosttyRules() {
        XCTAssertNil(GhosttyConfigScan.fontFamily(in: ["# font-family = Commented"]))
        XCTAssertEqual(GhosttyConfigScan.fontFamily(in: ["font-family = Iosevka\nfont-family = Symbols Nerd Font"]), "Iosevka")
        // A later file resets the list with an empty value, then sets its own.
        XCTAssertEqual(GhosttyConfigScan.fontFamily(in: ["font-family = A", "font-family =\nfont-family = \"Fira Code\""]), "Fira Code")
        XCTAssertNil(GhosttyConfigScan.fontFamily(in: ["font-family = A\nfont-family = "]))
    }
}
