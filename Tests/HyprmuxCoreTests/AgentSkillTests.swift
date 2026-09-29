import Foundation
import XCTest
@testable import HyprmuxCore

final class AgentSkillTests: XCTestCase {
    func testInstallStatusUpdateAndUninstall() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bundled/SKILL.md")
        let destination = AgentSkillInstaller.destination(homeDirectory: root)
        try writeSkill("version one", to: source)

        XCTAssertEqual(
            try AgentSkillInstaller.status(source: source, destination: destination),
            .notInstalled
        )
        XCTAssertTrue(try AgentSkillInstaller.install(source: source, destination: destination))
        XCTAssertEqual(try AgentSkillInstaller.status(source: source, destination: destination), .current)
        XCTAssertFalse(try AgentSkillInstaller.install(source: source, destination: destination))

        try writeSkill("version two", to: source)
        XCTAssertEqual(try AgentSkillInstaller.status(source: source, destination: destination), .outdated)
        XCTAssertTrue(try AgentSkillInstaller.install(source: source, destination: destination))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), skill("version two"))

        XCTAssertTrue(try AgentSkillInstaller.uninstall(destination: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try AgentSkillInstaller.uninstall(destination: destination))
    }

    func testUnmanagedSkillRequiresForce() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bundled/SKILL.md")
        let destination = AgentSkillInstaller.destination(homeDirectory: root)
        try writeSkill("bundled", to: source)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "user skill".write(to: destination, atomically: true, encoding: .utf8)

        XCTAssertEqual(try AgentSkillInstaller.status(source: source, destination: destination), .unmanaged)
        XCTAssertThrowsError(try AgentSkillInstaller.install(source: source, destination: destination)) { error in
            XCTAssertEqual(error as? AgentSkillError, .unmanagedDestination(destination.path))
        }
        XCTAssertThrowsError(try AgentSkillInstaller.uninstall(destination: destination)) { error in
            XCTAssertEqual(error as? AgentSkillError, .unmanagedDestination(destination.path))
        }

        XCTAssertTrue(try AgentSkillInstaller.install(source: source, destination: destination, force: true))
        try "user skill again".write(to: destination, atomically: true, encoding: .utf8)
        XCTAssertTrue(try AgentSkillInstaller.uninstall(destination: destination, force: true))
    }

    func testDestinationDirectoryIsRejected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bundled/SKILL.md")
        let destination = AgentSkillInstaller.destination(homeDirectory: root)
        try writeSkill("bundled", to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        XCTAssertThrowsError(try AgentSkillInstaller.status(source: source, destination: destination)) { error in
            XCTAssertEqual(error as? AgentSkillError, .destinationIsDirectory(destination.path))
        }
        XCTAssertThrowsError(try AgentSkillInstaller.install(source: source, destination: destination)) { error in
            XCTAssertEqual(error as? AgentSkillError, .destinationIsDirectory(destination.path))
        }
        XCTAssertThrowsError(try AgentSkillInstaller.uninstall(destination: destination)) { error in
            XCTAssertEqual(error as? AgentSkillError, .destinationIsDirectory(destination.path))
        }
    }

    func testSourceMustExistAndContainManagedMarker() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("SKILL.md")
        let destination = AgentSkillInstaller.destination(homeDirectory: root)

        XCTAssertThrowsError(try AgentSkillInstaller.install(source: source, destination: destination)) { error in
            XCTAssertEqual(error as? AgentSkillError, .sourceMissing(source.path))
        }
        try "unmanaged".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AgentSkillInstaller.install(source: source, destination: destination)) { error in
            XCTAssertEqual(error as? AgentSkillError, .sourceUnmanaged(source.path))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyprmux-agent-skill-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSkill(_ body: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try skill(body).write(to: url, atomically: true, encoding: .utf8)
    }

    private func skill(_ body: String) -> String {
        "\(AgentSkillInstaller.managedMarker)\n\(body)\n"
    }
}
