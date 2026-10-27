import HyprmuxCore
import XCTest

final class PluginTests: XCTestCase {
    func testManifest() throws {
        let m = try PluginManifest.parse(Data(#"{"id": "dev.x.load", "name": "Load", "permissions": ["tiles"]}"#.utf8)).get()
        XCTAssertEqual(m, PluginManifest(id: "dev.x.load", name: "Load", permissions: ["tiles"]))
        XCTAssertEqual(try PluginManifest.parse(Data(#"{"id": "dev.x.load"}"#.utf8)).get().name, "dev.x.load")
        XCTAssertThrowsError(try PluginManifest.parse(Data(#"{"name": "no id"}"#.utf8)).get())
        XCTAssertThrowsError(try PluginManifest.parse(Data("[]".utf8)).get())
    }

    func testBareNamesLookInPluginsThenBuiltIn() {
        let config = "/u/.config/hyprmux", builtin = "/App/Resources/plugins"
        func dir(_ spec: String, existing: Set<String>) -> String {
            PluginLocation.directory(for: spec, configDir: config, builtinDir: builtin) { existing.contains($0) }
        }
        // The user's folder wins over the built-in one of the same name.
        XCTAssertEqual(dir("sysload", existing: ["/u/.config/hyprmux/plugins/sysload/plugin.json",
                                                 "/App/Resources/plugins/sysload/plugin.json"]),
                       "/u/.config/hyprmux/plugins/sysload")
        XCTAssertEqual(dir("sysload", existing: ["/App/Resources/plugins/sysload/plugin.json"]),
                       "/App/Resources/plugins/sysload")
        // Neither: the user's folder, so the error says where it looked.
        XCTAssertEqual(dir("nope", existing: []), "/u/.config/hyprmux/plugins/nope")
    }

    func testPathsAreTakenAsWritten() {
        let config = "/u/.config/hyprmux"
        XCTAssertEqual(PluginLocation.directory(for: "/opt/p/x", configDir: config, builtinDir: nil), "/opt/p/x")
        XCTAssertEqual(PluginLocation.directory(for: "dev/x", configDir: config, builtinDir: nil), "/u/.config/hyprmux/dev/x")
        XCTAssertEqual(PluginLocation.directory(for: "../shared/x", configDir: config, builtinDir: nil), "/u/.config/shared/x")
        XCTAssertTrue(PluginLocation.directory(for: "~/src/x", configDir: config, builtinDir: nil).hasSuffix("/src/x"))
    }
}
