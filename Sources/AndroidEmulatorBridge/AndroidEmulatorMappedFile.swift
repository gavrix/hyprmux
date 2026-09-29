import Darwin
import Foundation

/// A client-owned file mapping used by the emulator's screenshot side channel.
/// The mapping stays alive until the corresponding gRPC call has completed.
final class AndroidEmulatorMappedFile: @unchecked Sendable {
    let url: URL
    let capacity: Int

    private let pointer: UnsafeMutableRawPointer

    init(capacity: Int) throws {
        guard capacity > 0 else { throw POSIXError(.EINVAL) }

        var template = Array("/tmp/hyprmux-android-XXXXXX".utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw Self.posixError() }

        let path = String(cString: template)
        guard ftruncate(descriptor, off_t(capacity)) == 0 else {
            let error = Self.posixError()
            close(descriptor)
            unlink(path)
            throw error
        }

        let mapping = mmap(nil, capacity, PROT_READ, MAP_SHARED, descriptor, 0)
        let mappingError = errno
        close(descriptor)
        guard mapping != MAP_FAILED, let mapping else {
            unlink(path)
            throw POSIXError(POSIXErrorCode(rawValue: mappingError) ?? .EIO)
        }

        self.url = URL(fileURLWithPath: path)
        self.capacity = capacity
        self.pointer = mapping
    }

    func snapshot(byteCount: Int) -> Data? {
        guard byteCount > 0, byteCount <= capacity else { return nil }
        return Data(bytes: pointer, count: byteCount)
    }

    deinit {
        munmap(pointer, capacity)
        unlink(url.path)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
