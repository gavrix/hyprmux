import Darwin
import Foundation
import XCTest
@testable import AndroidEmulatorBridge

final class AndroidEmulatorMappedFileTests: XCTestCase {
    func testRGBAByteCountRejectsInvalidAndOversizedFrames() {
        XCTAssertEqual(AndroidEmulatorClient.rgbaByteCount(width: 720, height: 1280), 3_686_400)
        XCTAssertNil(AndroidEmulatorClient.rgbaByteCount(width: 0, height: 1280))
        XCTAssertNil(AndroidEmulatorClient.rgbaByteCount(width: Int.max, height: 2))
        XCTAssertNil(AndroidEmulatorClient.rgbaByteCount(width: 32_768, height: 32_768))
    }

    func testSnapshotsBytesWrittenThroughTheSharedFile() throws {
        let mapping = try AndroidEmulatorMappedFile(capacity: 8)
        XCTAssertEqual(mapping.url.scheme, "file")
        let attributes = try FileManager.default.attributesOfItem(atPath: mapping.url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))

        let descriptor = open(mapping.url.path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { close(descriptor) } }

        let bytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        XCTAssertEqual(bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }, bytes.count)
        XCTAssertEqual(mapping.snapshot(byteCount: bytes.count), Data(bytes))
        XCTAssertNil(mapping.snapshot(byteCount: 0))
        XCTAssertNil(mapping.snapshot(byteCount: bytes.count + 1))
    }

    func testRemovesBackingFileAfterRelease() throws {
        var mapping: AndroidEmulatorMappedFile? = try AndroidEmulatorMappedFile(capacity: 8)
        let path = try XCTUnwrap(mapping?.url.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        mapping = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
