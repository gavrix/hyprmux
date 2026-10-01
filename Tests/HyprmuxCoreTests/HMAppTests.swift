import Foundation
import XCTest
@testable import HyprmuxCore

final class HMAppTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hmapp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func parse(_ json: String) -> Result<HMAppManifest, ParseError> { HMAppManifest.parse(Data(json.utf8)) }

    private func error(_ json: String) -> String? {
        if case .failure(let e) = parse(json) { return e.message }
        return nil
    }

    private func executable(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    }

    func testParsesAManifest() throws {
        let m = try parse(#"""
        {"format": 1, "id": "com.microsoft.VSCode", "name": "Visual Studio Code", "kind": "adapter",
         "adapter": "electron.vscode", "app": "/Applications/Visual Studio Code.app", "version": "1.2",
         "exec": "hyprmux-electron-bridge", "args": ["--adapter", "vscode", "{app}", "{args}"], "generatedBy": "hyprmux"}
        """#).get()
        XCTAssertEqual(m.id, "com.microsoft.VSCode")
        XCTAssertEqual(m.kind, .adapter)
        XCTAssertEqual(m.adapter, "electron.vscode")
        XCTAssertEqual(m.version, "1.2")
        XCTAssertTrue(m.isGenerated)
        let native = try parse(#"{"format":1,"id":"dev.zed","name":"Zed","kind":"native","app":"/Applications/Zed.app"}"#).get()
        XCTAssertEqual(native.args, ["{args}"])
        XCTAssertNil(native.exec)
        XCTAssertFalse(native.isGenerated)
    }

    func testRejectsBadManifests() {
        XCTAssertEqual(error("[]"), "not a JSON object")
        XCTAssertEqual(error(#"{"id":"a","name":"A","kind":"native","app":"/x"}"#), "\"format\" is required")
        XCTAssertEqual(error(#"{"format":2,"id":"a","name":"A","kind":"native","app":"/x"}"#), "\"format\" must be 1")
        XCTAssertEqual(error(#"{"format":true,"id":"a","name":"A","kind":"native","app":"/x"}"#), "\"format\" must be 1")
        XCTAssertEqual(error(#"{"format":1,"name":"A","kind":"native","app":"/x"}"#), "\"id\" is required")
        XCTAssertEqual(error(#"{"format":1,"id":"a b","name":"A","kind":"native","app":"/x"}"#), "\"id\" must use letters, digits, . _ -")
        XCTAssertEqual(error(#"{"format":1,"id":"a","kind":"native","app":"/x"}"#), "\"name\" is required")
        XCTAssertEqual(error(#"{"format":1,"id":"a","name":"","kind":"native","app":"/x"}"#), "\"name\" must not be empty")
        XCTAssertEqual(error(#"{"format":1,"id":"a","name":"A","kind":"magic","app":"/x"}"#), "\"kind\" must be native or adapter")
        XCTAssertEqual(error(#"{"format":1,"id":"a","name":"A","kind":"adapter","app":"/x","exec":"b"}"#),
                       "\"adapter\" is required when \"kind\" is adapter")
        XCTAssertEqual(error(#"{"format":1,"id":"a","name":"A","kind":"native"}"#), "needs \"exec\" or \"app\"")
        XCTAssertEqual(error(#"{"format":1,"id":"a","name":"A","kind":"native","app":"Zed.app"}"#), "\"app\" must be an absolute path")
        XCTAssertEqual(error(#"{"format":1,"id":"a","name":"A","kind":"native","exec":"x","args":"--x"}"#),
                       "\"args\" must be an array of strings")
        XCTAssertEqual(error(#"{"format":1,"id":"a","name":7,"kind":"native","exec":"x"}"#), "\"name\" must be a string")
    }

    func testUnknownKeysAreErrors() {
        XCTAssertEqual(error(#"{"format":1,"id":"a","name":"A","kind":"native","exec":"x","arg":["y"]}"#), "unknown key \"arg\"")
    }

    func testEncodingRoundTripsAndIsStable() throws {
        let m = HMAppManifest(id: "com.reactotron.app", name: "Reactotron", kind: .adapter, adapter: "electron",
                              app: "/Applications/Reactotron.app", version: "3.7.7", exec: "hyprmux-electron-bridge",
                              args: ["--adapter", "generic", "{app}", "{args}"], generatedBy: HMAppManifest.generator)
        XCTAssertEqual(try HMAppManifest.parse(m.encoded()).get(), m)
        XCTAssertEqual(m.encoded(), m.encoded())
        // Paths stay readable: no escaped slashes.
        XCTAssertTrue(String(decoding: m.encoded(), as: UTF8.self).contains("/Applications/Reactotron.app"))
        // Default args are left out.
        let native = HMAppManifest(id: "a", name: "A", kind: .native, exec: "/bin/a")
        XCTAssertFalse(String(decoding: native.encoded(), as: UTF8.self).contains("args"))
    }

    func testWriteReportsChanges() throws {
        let path = root.appendingPathComponent("A.hmapp").path
        let m = HMAppManifest(id: "a", name: "A", kind: .native, exec: "/bin/a")
        XCTAssertTrue(try HMApp.write(m, to: path))
        XCTAssertFalse(try HMApp.write(m, to: path))
        var changed = m
        changed.version = "2"
        XCTAssertTrue(try HMApp.write(changed, to: path))
        XCTAssertEqual(try HMApp.load(path, source: .installed).get().manifest, changed)
    }

    func testResolvesExecutables() throws {
        let bundle = root.appendingPathComponent("Zed.hmapp").path
        let bin = root.appendingPathComponent("bin").path
        try executable((bundle as NSString).appendingPathComponent("bin/zed"))
        try executable((bin as NSString).appendingPathComponent("bridge"))
        try executable((bundle as NSString).appendingPathComponent("local"))
        let abs = root.appendingPathComponent("abs").path
        try executable(abs)
        func resolve(_ exec: String) -> String? {
            HMAppManifest(id: "a", name: "A", kind: .native, exec: exec).resolveExecutable(bundle: bundle, binDirectories: [bin])
        }
        XCTAssertEqual(resolve(abs), abs)
        XCTAssertEqual(resolve("bin/zed"), (bundle as NSString).appendingPathComponent("bin/zed"))
        XCTAssertEqual(resolve("bridge"), (bin as NSString).appendingPathComponent("bridge"))
        // A bare name falls back to the bundle itself.
        XCTAssertEqual(resolve("local"), (bundle as NSString).appendingPathComponent("local"))
        XCTAssertNil(resolve("missing"))
        let app = HMApp(manifest: HMAppManifest(id: "a", name: "A", kind: .native, exec: "bin/zed"), path: bundle, source: .installed)
        XCTAssertTrue(app.carriesExecutable((bundle as NSString).appendingPathComponent("bin/zed")))
        XCTAssertFalse(app.carriesExecutable(abs))
    }

    func testExpandsPlaceholders() {
        XCTAssertEqual(
            HMAppManifest.expand(["--adapter", "vscode", "{app}", "--icon={bundle}/icon.png", "{args}", "--end"],
                                 app: "/Applications/Code.app", bundle: "/x/Code.hmapp", args: ["a b", "c"]),
            ["--adapter", "vscode", "/Applications/Code.app", "--icon=/x/Code.hmapp/icon.png", "a b", "c", "--end"])
        XCTAssertEqual(HMAppManifest.expand(["{args}"], app: nil, bundle: "/b", args: []), [])
    }

    func testCommands() throws {
        let bundle = root.appendingPathComponent("Zed.hmapp").path
        try executable((bundle as NSString).appendingPathComponent("bin/zed"))
        let exec = HMApp(manifest: HMAppManifest(id: "a", name: "Zed", kind: .native, exec: "bin/zed", args: ["--fg", "{args}"]),
                         path: bundle, source: .installed)
        XCTAssertEqual(try exec.command(args: ["/tmp"], binDirectories: []).get(),
                       HMApp.Command(executable: (bundle as NSString).appendingPathComponent("bin/zed"), app: nil, arguments: ["--fg", "/tmp"]))
        let open = HMApp(manifest: HMAppManifest(id: "a", name: "Root", kind: .native, app: root.path), path: bundle, source: .installed)
        XCTAssertEqual(try open.command(args: ["x"], binDirectories: []).get(),
                       HMApp.Command(executable: nil, app: root.path, arguments: ["x"]))
        let missing = HMApp(manifest: HMAppManifest(id: "a", name: "Gone", kind: .native, exec: "nope"), path: bundle, source: .installed)
        if case .success = missing.command(args: [], binDirectories: []) { XCTFail("expected an error") }
    }

    func testSlugs() {
        XCTAssertEqual(HMApp.slug("Zed (dev)"), "zed-dev")
        XCTAssertEqual(HMApp.slug("  My  Tool!! "), "my-tool")
        XCTAssertEqual(HMApp.slug("✨"), "app")
        XCTAssertEqual(HMApp.folderName("a/b:c"), "a-b-c.hmapp")
    }
}
