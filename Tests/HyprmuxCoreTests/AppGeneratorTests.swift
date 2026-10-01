import Foundation
import XCTest
@testable import HyprmuxCore

final class AppGeneratorTests: XCTestCase {
    private var root: URL!
    private var apps: String { root.appendingPathComponent("Applications").path }
    private var out: String { root.appendingPathComponent("Apps").path }
    private var registry = AdapterRegistry()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("generator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let adapters = root.appendingPathComponent("adapters").path
        let bin = root.appendingPathComponent("bin").path
        try FileManager.default.createDirectory(atPath: adapters, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: (bin as NSString).appendingPathComponent("bridge"),
                                       contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        try #"{"id":"electron","match":{"bundleFiles":["Contents/Frameworks/Electron Framework.framework"]},"exec":"bridge","args":["--adapter","generic","{app}","{args}"],"probe":["probe","{app}"]}"#
            .write(toFile: (adapters as NSString).appendingPathComponent("electron.json"), atomically: true, encoding: .utf8)
        registry = AdapterRegistry.load(directories: [(.builtin, adapters)], binDirectories: [bin])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A fake `.app`: an Info.plist, and optionally the Electron framework.
    @discardableResult
    private func makeApp(_ file: String, in dir: String? = nil, id: String?, name: String? = nil, displayName: String? = nil,
                         version: String = "1.0", client: Bool = false, electron: Bool = false) throws -> String {
        let path = ((dir ?? apps) as NSString).appendingPathComponent(file)
        let contents = (path as NSString).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleShortVersionString": version]
        if let id { info["CFBundleIdentifier"] = id }
        if let name { info["CFBundleName"] = name }
        if let displayName { info["CFBundleDisplayName"] = displayName }
        if client { info["HyprmuxClient"] = true }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: (contents as NSString).appendingPathComponent("Info.plist")))
        if electron {
            try FileManager.default.createDirectory(atPath: (contents as NSString).appendingPathComponent("Frameworks/Electron Framework.framework"),
                                                    withIntermediateDirectories: true)
        }
        return path
    }

    private var probes: [String] = []
    private var failing: Set<String> = []

    private func generate() -> AppGenerator.Report {
        AppGenerator.generate(apps: AppScanner.scan([AppScanner.Folder(apps, subfolders: true)]), registry: registry, directory: out,
                              probe: { _, app in
                                  self.probes.append(app.name)
                                  return self.failing.contains(app.name) ? .init(ok: false, reason: "fuse off") : .init(ok: true)
                              },
                              icon: { _ in Data("png".utf8) })
    }

    private func catalog() -> AppCatalog { AppCatalog.load(directories: [(.generated, out)]) }

    // MARK: Scanning

    func testScansFoldersOneLevelDeep() throws {
        try makeApp("Zed.app", id: "dev.zed.Zed", name: "Zed", client: true)
        try makeApp("Code.app", id: "com.microsoft.VSCode", name: "Code", displayName: "Visual Studio Code", version: "1.9")
        let sub = (apps as NSString).appendingPathComponent("Google Meet")
        try makeApp("Meet.app", in: sub, id: "com.google.meet", name: nil)
        try makeApp("Deep.app", in: (sub as NSString).appendingPathComponent("nested"), id: "com.deep")
        // An app bundle without an Info.plist is skipped.
        try FileManager.default.createDirectory(atPath: (apps as NSString).appendingPathComponent("Broken.app"), withIntermediateDirectories: true)
        let found = AppScanner.scan([AppScanner.Folder(apps, subfolders: true), AppScanner.Folder(sub)])
        XCTAssertEqual(found.map(\.name), ["Visual Studio Code", "Meet", "Zed"])
        XCTAssertEqual(found[0].version, "1.9")
        XCTAssertEqual(found[0].bundleID, "com.microsoft.VSCode")
        XCTAssertTrue(found[2].isClient)
        XCTAssertFalse(found[0].isClient)
        // Without subfolders, only the top level.
        XCTAssertEqual(AppScanner.scan([AppScanner.Folder(apps)]).map(\.name), ["Visual Studio Code", "Zed"])
    }

    func testDefaultFolders() {
        let f = AppScanner.defaultFolders(home: "/Users/me")
        XCTAssertEqual(f.map(\.path), ["/Applications", "/Applications/Utilities", "/Users/me/Applications",
                                      "/System/Applications", "/System/Applications/Utilities"])
        XCTAssertEqual(f.filter(\.subfolders).map(\.path), ["/Applications", "/Users/me/Applications"])
    }

    // MARK: Generating

    func testGeneratesNativeAndAdapterApps() throws {
        let zed = try makeApp("Zed.app", id: "dev.zed.Zed", name: "Zed", client: true)
        let cursor = try makeApp("Cursor.app", id: "com.cursor", name: "Cursor", electron: true)
        try makeApp("Notes.app", id: "com.apple.Notes", name: "Notes")
        try makeApp("Slack.app", id: "com.slack", name: "Slack", electron: true)
        failing = ["Slack"]
        let report = generate()
        XCTAssertEqual(Set(report.apps), ["dev.zed.Zed", "com.cursor"])
        XCTAssertEqual(Set(report.skipped.map { ($0.app as NSString).lastPathComponent }), ["Notes.app", "Slack.app"])
        XCTAssertEqual(probes.sorted(), ["Cursor", "Slack"])
        let c = catalog()
        XCTAssertEqual(c.apps.map(\.name), ["Cursor", "Zed"])
        let z = try XCTUnwrap(c.app(id: "dev.zed.Zed"))
        XCTAssertEqual(z.manifest, HMAppManifest(id: "dev.zed.Zed", name: "Zed", kind: .native, app: zed, version: "1.0",
                                                 generatedBy: "hyprmux"))
        let cur = try XCTUnwrap(c.app(id: "com.cursor"))
        XCTAssertEqual(cur.manifest.kind, .adapter)
        XCTAssertEqual(cur.manifest.adapter, "electron")
        XCTAssertEqual(cur.manifest.exec, "bridge")
        XCTAssertEqual(cur.manifest.args, ["--adapter", "generic", "{app}", "{args}"])
        XCTAssertEqual(cur.manifest.app, cursor)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cur.iconPath))
        XCTAssertTrue(c.errors.isEmpty)
    }

    func testProbesOncePerVersionAndUpdates() throws {
        try makeApp("Cursor.app", id: "com.cursor", name: "Cursor", version: "1.0", electron: true)
        _ = generate()
        let again = generate()
        XCTAssertEqual(probes, ["Cursor"])
        XCTAssertEqual(again.written, [])
        XCTAssertEqual(again.probed, 0)
        try makeApp("Cursor.app", id: "com.cursor", name: "Cursor", version: "2.0", electron: true)
        let updated = generate()
        XCTAssertEqual(probes, ["Cursor", "Cursor"])
        XCTAssertEqual(updated.written, ["com.cursor"])
        XCTAssertEqual(catalog().app(id: "com.cursor")?.manifest.version, "2.0")
    }

    func testProbeFailureRemovesAnApp() throws {
        try makeApp("Cursor.app", id: "com.cursor", name: "Cursor", version: "1.0", electron: true)
        _ = generate()
        XCTAssertNotNil(catalog().app(id: "com.cursor"))
        failing = ["Cursor"]
        try makeApp("Cursor.app", id: "com.cursor", name: "Cursor", version: "1.1", electron: true)
        let r = generate()
        XCTAssertEqual(r.deleted.count, 1)
        XCTAssertNil(catalog().app(id: "com.cursor"))
    }

    func testDeletesVanishedAndRenamedApps() throws {
        let zed = try makeApp("Zed.app", id: "dev.zed.Zed", name: "Zed", client: true)
        try makeApp("Tool.app", id: "com.tool", name: "Tool", client: true)
        _ = generate()
        try FileManager.default.removeItem(atPath: zed)
        try makeApp("Tool.app", id: "com.tool", name: "Tool Pro", client: true)
        let r = generate()
        XCTAssertEqual(Set(r.deleted.map { ($0 as NSString).lastPathComponent }), ["Zed.hmapp", "Tool.hmapp"])
        let names = try FileManager.default.contentsOfDirectory(atPath: out).filter { $0.hasSuffix(".hmapp") }
        XCTAssertEqual(names, ["Tool Pro.hmapp"])
    }

    func testNeverTouchesOtherBundles() throws {
        try makeApp("Zed.app", id: "dev.zed.Zed", name: "Zed", client: true)
        // Someone else's bundle with the same folder name, and a broken one.
        let mine = HMAppManifest(id: "user.zed", name: "Zed", kind: .native, exec: "/bin/zed")
        try HMApp.write(mine, to: (out as NSString).appendingPathComponent("Zed.hmapp"))
        let broken = (out as NSString).appendingPathComponent("Broken.hmapp")
        try FileManager.default.createDirectory(atPath: broken, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: URL(fileURLWithPath: (broken as NSString).appendingPathComponent("Info.json")))
        try Data("notes".utf8).write(to: URL(fileURLWithPath: (out as NSString).appendingPathComponent("notes.txt")))
        let r = generate()
        XCTAssertTrue(r.deleted.isEmpty)
        XCTAssertEqual(try HMApp.load((out as NSString).appendingPathComponent("Zed.hmapp"), source: .generated).get().manifest, mine)
        XCTAssertTrue(FileManager.default.fileExists(atPath: (out as NSString).appendingPathComponent("Zed (dev.zed.Zed).hmapp/Info.json")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (broken as NSString).appendingPathComponent("Info.json")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (out as NSString).appendingPathComponent("notes.txt")))
    }
}
