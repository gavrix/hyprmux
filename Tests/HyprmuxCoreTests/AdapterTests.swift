import Foundation
import XCTest
@testable import HyprmuxCore

final class AdapterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("adapters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func dir(_ name: String) throws -> String {
        let d = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.path
    }

    private func write(_ json: String, _ name: String, in dir: String) throws {
        try json.write(toFile: (dir as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func executable(_ name: String, in dir: String) throws {
        let path = (dir as NSString).appendingPathComponent(name)
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    }

    private func parse(_ json: String) -> Result<AdapterManifest, ParseError> { AdapterManifest.parse(Data(json.utf8)) }

    private let electron = #"{"id":"electron","match":{"bundleFiles":["Contents/Frameworks/Electron Framework.framework"]},"exec":"bridge"}"#
    private let vscode = #"{"id":"electron.vscode","priority":10,"match":{"bundleIds":["com.microsoft.VSCode*"],"bundleFiles":["Contents/Frameworks/Electron Framework.framework"]},"exec":"bridge","args":["--adapter","vscode","{app}","{args}"]}"#

    // MARK: Manifests

    func testParsesAManifest() throws {
        let m = try parse(vscode).get()
        XCTAssertEqual(m.id, "electron.vscode")
        XCTAssertEqual(m.name, "electron.vscode")
        XCTAssertEqual(m.priority, 10)
        XCTAssertEqual(m.bundleIDs, ["com.microsoft.VSCode*"])
        XCTAssertEqual(m.args, ["--adapter", "vscode", "{app}", "{args}"])
        XCTAssertNil(m.probe)
        XCTAssertEqual(try parse(electron).get().args, ["{app}", "{args}"])
    }

    func testRejectsBadManifests() {
        func error(_ json: String) -> String? {
            if case .failure(let e) = parse(json) { return e.message }
            return nil
        }
        XCTAssertEqual(error("[]"), "not a JSON object")
        XCTAssertEqual(error(#"{"match":{"bundleIds":["a"]},"exec":"x"}"#), "\"id\" is required")
        XCTAssertNotNil(error(#"{"id":"9lives","match":{"bundleIds":["a"]},"exec":"x"}"#))
        XCTAssertEqual(error(#"{"id":"a","match":{"bundleIds":["a"]}}"#), "\"exec\" is required")
        XCTAssertEqual(error(#"{"id":"a","exec":"x"}"#), "\"match\" is required")
        XCTAssertEqual(error(#"{"id":"a","exec":"x","match":{}}"#), "\"match\" needs bundleIds or bundleFiles")
        XCTAssertEqual(error(#"{"id":"a","exec":"x","match":{"bundleIDs":["a"]}}"#), "unknown key \"match.bundleIDs\"")
        XCTAssertEqual(error(#"{"id":"a","exec":"x","match":{"bundleIds":["a"]},"prio":1}"#), "unknown key \"prio\"")
        XCTAssertEqual(error(#"{"id":"a","exec":"x","match":{"bundleIds":["a"]},"priority":true}"#), "\"priority\" must be an integer")
        XCTAssertEqual(error(#"{"id":"a","exec":"x","match":{"bundleIds":"a"}}"#), "\"match.bundleIds\" must be an array of strings")
    }

    func testNumbersAndBooleansStayApart() throws {
        XCTAssertEqual(try parse(#"{"id":"a","exec":"x","match":{"bundleIds":["a"]},"priority":0}"#).get().priority, 0)
        XCTAssertEqual(try parse(#"{"id":"a","exec":"x","match":{"bundleIds":["a"]},"priority":1}"#).get().priority, 1)
        XCTAssertThrowsError(try parse(#"{"id":"a","exec":"x","match":{"bundleIds":["a"]},"priority":false}"#).get())
        XCTAssertThrowsError(try parse(#"{"id":"a","disabled":1}"#).get())
    }

    func testDisableOnlyManifestNeedsNothingElse() throws {
        let m = try parse(#"{"id":"electron","disabled":true}"#).get()
        XCTAssertTrue(m.disabled)
        XCTAssertEqual(m.exec, "")
    }

    func testMatching() throws {
        let m = try parse(vscode).get()
        let has: (String) -> Bool = { $0 == "Contents/Frameworks/Electron Framework.framework" }
        XCTAssertTrue(m.matches(bundleID: "com.microsoft.VSCode", fileExists: has).0)
        XCTAssertTrue(m.matches(bundleID: "com.microsoft.vscodeinsiders", fileExists: has).0, "prefix, any case")
        XCTAssertFalse(m.matches(bundleID: "com.microsoft.VSCode", fileExists: { _ in false }).0)
        let (ok, why) = m.matches(bundleID: "com.tinyspeck.slackmacgap", fileExists: has)
        XCTAssertFalse(ok)
        XCTAssertTrue(why.contains("com.tinyspeck.slackmacgap"))
        XCTAssertFalse(m.matches(bundleID: nil, fileExists: has).0)
    }

    func testExpand() {
        XCTAssertEqual(AdapterManifest.expand(["--adapter", "vscode", "{app}", "{args}"], app: "/A.app", args: ["x", "y z"]),
                       ["--adapter", "vscode", "/A.app", "x", "y z"])
        XCTAssertEqual(AdapterManifest.expand(["--app={app}", "{args}"], app: "/A b.app", args: []), ["--app=/A b.app"])
    }

    // MARK: Registry

    func testPriorityPicksTheSpecificAdapter() throws {
        let builtin = try dir("builtin"), bin = try dir("bin")
        try executable("bridge", in: bin)
        try write(electron, "electron.json", in: builtin)
        try write(vscode, "vscode.json", in: builtin)
        let r = AdapterRegistry.load(directories: [(.builtin, builtin)], binDirectories: [bin])
        XCTAssertEqual(r.entries.map(\.id), ["electron.vscode", "electron"])
        XCTAssertTrue(r.errors.isEmpty)
        XCTAssertEqual(r.entries.first?.executable, (bin as NSString).appendingPathComponent("bridge"))

        let electronFile: (String) -> Bool = { $0.hasSuffix("Electron Framework.framework") }
        XCTAssertEqual(r.match(bundleID: "com.microsoft.VSCode", fileExists: electronFile).selected?.id, "electron.vscode")
        XCTAssertEqual(r.match(bundleID: "com.reactotron.app", fileExists: electronFile).selected?.id, "electron")
        let calculator = r.match(bundleID: "com.apple.calculator", fileExists: { _ in false })
        XCTAssertNil(calculator.selected)
        XCTAssertEqual(calculator.candidates.filter(\.matched).count, 0)
    }

    func testMissingExecutableIsAnErrorAndFallsThrough() throws {
        let builtin = try dir("builtin"), bin = try dir("bin")
        try executable("bridge", in: bin)
        try write(electron, "electron.json", in: builtin)
        try write(vscode.replacingOccurrences(of: #""exec":"bridge""#, with: #""exec":"nope""#), "vscode.json", in: builtin)
        let r = AdapterRegistry.load(directories: [(.builtin, builtin)], binDirectories: [bin])
        XCTAssertEqual(r.entry("electron.vscode")?.state, "error")
        XCTAssertEqual(r.entry("electron.vscode")?.problem, "executable nope not found")
        let m = r.match(bundleID: "com.microsoft.VSCode", fileExists: { _ in true })
        XCTAssertEqual(m.selected?.id, "electron", "an unusable match falls through to the next")
        XCTAssertTrue(m.candidates[0].matched)
        XCTAssertTrue(m.candidates[0].reason.contains("not found"))
    }

    func testUserManifestsOverrideAndDisableBuiltins() throws {
        let builtin = try dir("builtin"), user = try dir("user"), bin = try dir("bin")
        try executable("bridge", in: bin)
        try executable("my-bridge", in: user)
        try write(electron, "electron.json", in: builtin)
        try write(vscode, "vscode.json", in: builtin)
        try write(#"{"id":"electron.vscode","disabled":true}"#, "off.json", in: user)
        try write(electron.replacingOccurrences(of: #""exec":"bridge""#, with: #""exec":"./my-bridge""#), "mine.json", in: user)
        let r = AdapterRegistry.load(directories: [(.builtin, builtin), (.user, user)], binDirectories: [bin])
        XCTAssertEqual(r.entry("electron.vscode")?.state, "disabled")
        XCTAssertEqual(r.entry("electron.vscode")?.manifest.priority, 10, "keeps the built-in's details")
        XCTAssertEqual(r.entry("electron")?.source, .user)
        XCTAssertEqual(r.entry("electron")?.executable, (user as NSString).appendingPathComponent("my-bridge"))
        XCTAssertNotNil(r.entry("electron")?.overrides)
        XCTAssertEqual(r.overridden.count, 2)
        XCTAssertEqual(r.match(bundleID: "com.microsoft.VSCode", fileExists: { _ in true }).selected?.id, "electron")
    }

    func testBadFilesAndDuplicatesAreReported() throws {
        let builtin = try dir("builtin")
        try write("{", "broken.json", in: builtin)
        try write(electron, "a.json", in: builtin)
        try write(electron, "b.json", in: builtin)
        try write("not json at all", "notes.txt", in: builtin)
        let r = AdapterRegistry.load(directories: [(.builtin, builtin), (.user, root.appendingPathComponent("absent").path)],
                                     binDirectories: [])
        XCTAssertEqual(r.entries.map(\.id), ["electron"])
        XCTAssertEqual(r.errors.count, 2)
        XCTAssertTrue(r.errors.contains { $0.path.hasSuffix("broken.json") })
        XCTAssertTrue(r.errors.contains { $0.message.hasPrefix("duplicate id") })
        XCTAssertEqual(r.directories.map(\.exists), [true, false])
    }

    // MARK: IPC

    func testParsesSnapshot() {
        let path = "/tmp/a tile.png"
        let encoded = Data(path.utf8).base64EncodedString()
        XCTAssertEqual(try IPCRequest.parse("snapshot --surface 3 --base64 \(encoded)").get(), .snapshot(surface: SurfaceReference(3), path: path))
        XCTAssertEqual(try IPCRequest.parse("snapshot --base64 \(encoded)").get(), .snapshot(surface: nil, path: path))
        let relative = Data("a.png".utf8).base64EncodedString()
        XCTAssertThrowsError(try IPCRequest.parse("snapshot --base64 \(relative)").get())
    }

    func testParsesSendScroll() {
        XCTAssertEqual(try IPCRequest.parse("sendscroll , -3, 100 200").get(), .sendScroll([], lines: -3, at: CGPoint(x: 100, y: 200)))
        XCTAssertThrowsError(try IPCRequest.parse("sendscroll , lots, 100 200").get())
    }

    func testParsesAdapterRequests() {
        XCTAssertEqual(try IPCRequest.parse("adapters").get(), .adapters)
        XCTAssertEqual(try IPCRequest.parse("adapters list").get(), .adapters)
        XCTAssertEqual(try IPCRequest.parse("adapters reload").get(), .adaptersReload)
        XCTAssertEqual(try IPCRequest.parse("adapters match com.microsoft.VSCode").get(), .adaptersMatch("com.microsoft.VSCode"))
        let path = "/Applications/Visual Studio Code.app"
        let encoded = Data(path.utf8).base64EncodedString()
        XCTAssertEqual(try IPCRequest.parse("adapters match --base64 \(encoded)").get(), .adaptersMatch(path))
        XCTAssertThrowsError(try IPCRequest.parse("adapters frobnicate").get())
        XCTAssertThrowsError(try IPCRequest.parse("adapters match").get())
    }
}
