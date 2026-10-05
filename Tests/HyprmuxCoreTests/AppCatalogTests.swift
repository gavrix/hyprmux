import Foundation
import XCTest
@testable import HyprmuxCore

final class AppCatalogTests: XCTestCase {
    private var root: URL!
    private var generated: String { root.appendingPathComponent("generated").path }
    private var installed: String { root.appendingPathComponent("installed").path }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func app(_ id: String, _ name: String, in dir: String, folder: String? = nil, generated: Bool = false) throws {
        let m = HMAppManifest(id: id, name: name, kind: .native, exec: "/bin/echo",
                              generatedBy: generated ? HMAppManifest.generator : nil)
        try HMApp.write(m, to: (dir as NSString).appendingPathComponent(folder ?? HMApp.folderName(name)))
    }

    private func load() -> AppCatalog { AppCatalog.load(directories: [(.generated, generated), (.installed, installed)]) }

    func testLoadsBothFoldersAndInstalledWins() throws {
        try app("com.a", "Alpha", in: generated, generated: true)
        try app("com.b", "Beta", in: generated, generated: true)
        try app("com.b", "Beta (mine)", in: installed)
        try app("user.tool", "Tool", in: installed)
        let c = load()
        XCTAssertEqual(c.apps.map(\.id), ["com.a", "com.b", "user.tool"])
        XCTAssertEqual(c.app(id: "com.b")?.name, "Beta (mine)")
        XCTAssertEqual(c.app(id: "com.b")?.source, .installed)
        XCTAssertEqual(c.app(id: "com.b")?.overrides, (generated as NSString).appendingPathComponent("Beta.hmapp"))
        XCTAssertEqual(c.overridden.map(\.id), ["com.b"])
        XCTAssertTrue(c.errors.isEmpty)
        XCTAssertEqual(c.directories.map(\.exists), [true, true])
    }

    func testBuiltinAppsLoseToTheOthers() throws {
        let builtin = root.appendingPathComponent("builtin").path
        try app("dev.mobile", "Mobile", in: builtin)
        try app("dev.other", "Other", in: builtin)
        try app("dev.other", "Other (mine)", in: installed)
        let c = AppCatalog.load(directories: [(.builtin, builtin), (.generated, generated), (.installed, installed)])
        XCTAssertEqual(c.app(id: "dev.mobile")?.source, .builtin)
        XCTAssertEqual(c.app(id: "dev.other")?.source, .installed)
        XCTAssertEqual(c.overridden.map(\.id), ["dev.other"])
    }

    func testReportsErrorsPerFile() throws {
        try app("com.a", "Alpha", in: generated)
        let broken = (installed as NSString).appendingPathComponent("Broken.hmapp")
        try FileManager.default.createDirectory(atPath: broken, withIntermediateDirectories: true)
        try Data(#"{"format":1,"id":"x","name":"X","kind":"native","exec":"/bin/x","typo":1}"#.utf8)
            .write(to: URL(fileURLWithPath: (broken as NSString).appendingPathComponent("Info.json")))
        let empty = (installed as NSString).appendingPathComponent("Empty.hmapp")
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        try app("com.a", "Alpha again", in: generated, folder: "Other.hmapp")
        // Other files are ignored.
        try Data().write(to: URL(fileURLWithPath: (installed as NSString).appendingPathComponent("notes.txt")))
        let c = load()
        XCTAssertEqual(c.apps.map(\.id), ["com.a"])
        XCTAssertEqual(c.errors.map { ($0.path as NSString).lastPathComponent }, ["Other.hmapp", "Broken.hmapp", "Empty.hmapp"])
        XCTAssertEqual(c.errors[1].message, "unknown key \"typo\"")
        XCTAssertEqual(c.errors[2].message, "no Info.json")
        XCTAssertTrue(c.errors[0].message.hasPrefix("duplicate id"))
    }

    func testMissingFolders() {
        let c = load()
        XCTAssertTrue(c.apps.isEmpty)
        XCTAssertEqual(c.directories.map(\.exists), [false, false])
    }

    func testFindAndLauncherOrder() throws {
        try app("com.a", "Alpha", in: generated)
        try app("com.b", "beta", in: generated)
        try app("com.c", "Gamma", in: installed)
        let c = load()
        XCTAssertEqual(c.find("com.b")?.name, "beta")
        XCTAssertEqual(c.find("BETA")?.id, "com.b")
        XCTAssertEqual(c.find("COM.C")?.id, "com.c")
        XCTAssertNil(c.find("delta"))
        let now = Date()
        XCTAssertEqual(c.launcherOrder(recent: [:]).map(\.id), ["com.a", "com.b", "com.c"])
        XCTAssertEqual(c.launcherOrder(recent: ["com.c": now, "com.b": now.addingTimeInterval(-60)]).map(\.id),
                       ["com.c", "com.b", "com.a"])
    }
}
