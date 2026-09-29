import Foundation
import XCTest
@testable import AndroidEmulatorBridge

final class AndroidEmulatorDiscoveryTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func runningDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyprmux-android-discovery-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        let directory = root.appendingPathComponent("avd/running", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func advertise(_ contents: String, pid: Int32, infoSuffix: Bool = true, in directory: URL) throws -> URL {
        let suffix = infoSuffix ? "_info.ini" : ".ini"
        let file = directory.appendingPathComponent("pid_\(pid)\(suffix)")
        try Data(contents.utf8).write(to: file)
        return file
    }

    func testMacOSRunningDirectories() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let temporary = URL(fileURLWithPath: "/private/var/folders/test/T", isDirectory: true)
        XCTAssertEqual(AndroidEmulatorDiscovery.runningDirectories(homeDirectory: home, temporaryDirectory: temporary), [
            URL(fileURLWithPath: "/Users/tester/Library/Caches/TemporaryItems/avd/running", isDirectory: true),
            URL(fileURLWithPath: "/private/var/folders/test/T/avd/running", isDirectory: true),
        ])
    }

    func testDiscoversOnlyLiveValidLocalAdvertisements() throws {
        let directory = try runningDirectory()
        try advertise("""
        avd.name = Pixel API 36
        avd.id=Pixel_API_36
        grpc.address=localhost
        grpc.port=8554
        grpc.token=secret=value
        emulator.version=37.3.2.0
        """, pid: 101, in: directory)
        try advertise("avd.name=Stale\navd.id=Stale\ngrpc.port=8555\ngrpc.token=stale", pid: 102, in: directory)
        try advertise("avd.name=Remote\navd.id=Remote\ngrpc.address=example.com\ngrpc.port=8556", pid: 103, in: directory)
        try advertise("avd.name=Bad port\navd.id=Bad\ngrpc.port=70000", pid: 104, in: directory)
        try Data("avd.name=Wrong filename\ngrpc.port=8557".utf8)
            .write(to: directory.appendingPathComponent("emulator.ini"))

        let endpoints = AndroidEmulatorDiscovery.discover(in: [directory]) { $0 != 102 }
        let endpoint = try XCTUnwrap(endpoints.first)
        XCTAssertEqual(endpoints.count, 1)
        XCTAssertEqual(endpoint.avdID, "Pixel_API_36")
        XCTAssertEqual(endpoint.name, "Pixel API 36")
        XCTAssertEqual(endpoint.pid, 101)
        XCTAssertEqual(endpoint.host, "localhost")
        XCTAssertEqual(endpoint.port, 8554)
        XCTAssertEqual(endpoint.emulatorVersion, "37.3.2.0")
        XCTAssertTrue(endpoint.supportsSharedMemoryScreenshots)
        XCTAssertEqual(endpoint.bearerToken, "secret=value")
        XCTAssertFalse(endpoint.description.contains("secret=value"))
        XCTAssertTrue(endpoint.description.contains("<redacted>"))
    }

    func testDiscoversCurrentPlainIniFilename() throws {
        let directory = try runningDirectory()
        try advertise("avd.name=Pixel 9\navd.id=Pixel_9\ngrpc.port=8554\n", pid: 151,
                      infoSuffix: false, in: directory)

        let endpoints = AndroidEmulatorDiscovery.discover(in: [directory]) { _ in true }
        XCTAssertEqual(endpoints.map(\.avdID), ["Pixel_9"])
    }

    func testIgnoresSymlinksAndDeduplicatesPIDs() throws {
        let first = try runningDirectory()
        let second = try runningDirectory()
        let contents = "avd.name=First\navd.id=stable\ngrpc.port=8554\n"
        let original = try advertise(contents, pid: 201, in: first)
        try advertise("avd.name=Second\navd.id=other\ngrpc.port=8555\n", pid: 201, in: second)
        try FileManager.default.createSymbolicLink(
            at: second.appendingPathComponent("pid_202_info.ini"),
            withDestinationURL: original
        )

        let endpoints = AndroidEmulatorDiscovery.discover(in: [first, second]) { _ in true }
        XCTAssertEqual(endpoints.map(\.name), ["First"])
    }

    func testRequiresFixedEmulatorVersionForSharedMemoryScreenshots() {
        func endpoint(version: String?) -> AndroidEmulatorEndpoint {
            AndroidEmulatorEndpoint(
                avdID: "test",
                name: "Test",
                pid: 1,
                host: "127.0.0.1",
                port: 8554,
                emulatorVersion: version,
                bearerToken: nil
            )
        }

        XCTAssertFalse(endpoint(version: nil).supportsSharedMemoryScreenshots)
        XCTAssertFalse(endpoint(version: "37.2.2.0").supportsSharedMemoryScreenshots)
        XCTAssertTrue(endpoint(version: "37.2.3.0").supportsSharedMemoryScreenshots)
        XCTAssertTrue(endpoint(version: "37.3.2.0").supportsSharedMemoryScreenshots)
        XCTAssertFalse(endpoint(version: "invalid").supportsSharedMemoryScreenshots)
    }

    func testMatchesStableIDOrNameOnlyWhenUnambiguous() {
        let first = AndroidEmulatorEndpoint(avdID: "pixel_8", name: "Pixel 8", pid: 1,
                                            host: "127.0.0.1", port: 8554, bearerToken: nil)
        let second = AndroidEmulatorEndpoint(avdID: "tablet", name: "Tablet", pid: 2,
                                             host: "127.0.0.1", port: 8555, bearerToken: nil)
        XCTAssertEqual(AndroidEmulatorDiscovery.match("PIXEL_8", in: [first, second]), first)
        XCTAssertEqual(AndroidEmulatorDiscovery.match("tablet", in: [first, second]), second)
        XCTAssertNil(AndroidEmulatorDiscovery.match("Pixel", in: [first, second]))
        XCTAssertEqual(AndroidEmulatorDiscovery.match("", in: [first]), first)
        XCTAssertNil(AndroidEmulatorDiscovery.match("", in: [first, second]))
    }
}
