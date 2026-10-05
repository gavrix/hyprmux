import Foundation
import XCTest
@testable import HyprmuxCore

/// `hyprmuxctl apps` and `launch` requests, the `launch` and `picker, apps` dispatchers,
/// and app tiles in the session.
final class AppRequestTests: XCTestCase {
    private func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    func testParsesAppsRequests() throws {
        XCTAssertEqual(try IPCRequest.parse("apps").get(), .apps)
        XCTAssertEqual(try IPCRequest.parse("apps list").get(), .apps)
        XCTAssertEqual(try IPCRequest.parse("apps refresh").get(), .appsRefresh)
        let add = "'Zed (dev)' /Users/me/zed/target/release-fast/zed --foreground"
        XCTAssertEqual(try IPCRequest.parse("apps add --base64 \(b64(add))").get(),
                       .appsAdd(["Zed (dev)", "/Users/me/zed/target/release-fast/zed", "--foreground"]))
        XCTAssertThrowsError(try IPCRequest.parse("apps add --base64 \(b64("Zed"))").get())
        XCTAssertThrowsError(try IPCRequest.parse("apps add Zed /bin/zed").get())
        XCTAssertThrowsError(try IPCRequest.parse("apps refresh now").get())
        XCTAssertThrowsError(try IPCRequest.parse("apps frobnicate").get())
    }

    func testParsesLaunchRequests() throws {
        XCTAssertEqual(try IPCRequest.parse("launch Reactotron").get(), .launch(["Reactotron"], focus: false, window: nil))
        XCTAssertEqual(try IPCRequest.parse("launch --focus --base64 \(b64("'Zed (dev)' /tmp/zedtest"))").get(),
                       .launch(["Zed (dev)", "/tmp/zedtest"], focus: true, window: nil))
        XCTAssertEqual(try IPCRequest.parse("launch --window ios:ABC --base64 \(b64("Mobile"))").get(),
                       .launch(["Mobile"], focus: false, window: "ios:ABC"))
        XCTAssertThrowsError(try IPCRequest.parse("launch --window").get())
        XCTAssertThrowsError(try IPCRequest.parse("launch").get())
        XCTAssertThrowsError(try IPCRequest.parse("launch --base64 \(b64("'unbalanced"))").get())
    }

    func testDispatchers() throws {
        XCTAssertEqual(try Dispatcher.parse("launch", " Visual Studio Code ").get(), .launch("Visual Studio Code"))
        XCTAssertEqual(try Dispatcher.parse("picker", "apps").get(), .picker(.apps))
        XCTAssertFalse(Dispatcher.launch("x").targetsWindow)
        XCTAssertEqual(Dispatcher.launch("Zed").label, "Open Zed")
        XCTAssertEqual(Dispatcher.picker(.apps).label, "Apps")
        // The model hands both to the app.
        let wm = WindowManager(monitor: CGRect(x: 0, y: 0, width: 800, height: 600), settings: WMSettings())
        var effects: [Effect] = []
        wm.perform = { effects.append($0) }
        wm.dispatch(.launch("Zed"))
        wm.dispatch(.picker(.apps))
        XCTAssertEqual(effects, [.launch("Zed"), .picker(.apps)])
    }

    func testConfigBinds() {
        let c = ConfigParser.parse("bind = SUPER, D, picker, apps\nbind = SUPER SHIFT, D, launch, Reactotron")
        XCTAssertTrue(c.errors.isEmpty, "\(c.errors)")
        XCTAssertEqual(c.binds.map(\.dispatcher), [.picker(.apps), .launch("Reactotron")])
        XCTAssertTrue(ConfigParser.parse(defaultConfig).binds.contains { $0.dispatcher == .picker(.apps) })
    }

    func testSessionKeepsAppEntries() throws {
        let tile = SessionTile(kind: "app", title: "Zed", restoreToken: "r1", appEntry: "user.zed-dev", appArgs: ["/tmp/zedtest"])
        let data = try JSONEncoder().encode(tile)
        XCTAssertEqual(try JSONDecoder().decode(SessionTile.self, from: data), tile)
        // Tiles saved before apps had ids still load.
        let old = try JSONDecoder().decode(SessionTile.self, from: Data(#"{"kind":"app","app":"/Applications/Cursor.app"}"#.utf8))
        XCTAssertEqual(old.app, "/Applications/Cursor.app")
        XCTAssertNil(old.appEntry)
    }

    func testPickerEmptyText() {
        var p = Picker(title: "apps")
        p.emptyText = "No apps"
        XCTAssertNil(p.result)
        XCTAssertEqual(p.rows.count, 0)
    }
}
