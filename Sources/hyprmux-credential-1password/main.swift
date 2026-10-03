import Foundation
import HyprmuxCore
import OnePasswordCredentialProvider

private struct ItemsResponse: Encodable { let items: [CredentialItemSummary] }
private struct ItemResponse: Encodable { let item: CredentialItemSummary }
private struct ValueResponse: Encodable { let value: String }
private struct ErrorResponse: Encodable { let error: CredentialProtocolError }

private func readRequest() throws -> CredentialRequest {
    let handle = FileHandle.standardInput
    var data = Data()
    while true {
        let chunk = handle.readData(ofLength: 64 * 1024)
        guard !chunk.isEmpty else { break }
        guard data.count + chunk.count <= 1024 * 1024 else {
            throw OnePasswordProviderFailure.protocolError(.failed, "The credential request is too large.")
        }
        data.append(chunk)
    }
    defer { data.resetBytes(in: data.indices) }
    let request: CredentialRequest
    do { request = try JSONDecoder().decode(CredentialRequest.self, from: data) }
    catch { throw OnePasswordProviderFailure.protocolError(.failed, "The credential request is malformed.") }
    guard request.protocolVersion == 1 else {
        throw OnePasswordProviderFailure.protocolError(.unsupported, "Credential protocol version 1 is required.")
    }
    return request
}

private func write<T: Encodable>(_ value: T) throws {
    var data = try JSONEncoder().encode(value)
    data.append(0x0a)
    FileHandle.standardOutput.write(data)
    data.resetBytes(in: data.indices)
}

let signalForwarder = OnePasswordSignalForwarder()

do {
    let request = try readRequest()
    let executable = try OnePasswordCredentialProvider.resolveExecutable(signalForwarder: signalForwarder)
    let provider = OnePasswordCredentialProvider(executable: executable, signalForwarder: signalForwarder)
    switch request.op {
    case "list":
        guard request.context != nil, request.id == nil, request.field == nil else {
            throw OnePasswordProviderFailure.protocolError(.failed, "The list request is malformed.")
        }
        try write(ItemsResponse(items: try provider.list()))
    case "metadata":
        guard let id = request.id, request.context == nil, request.field == nil else {
            throw OnePasswordProviderFailure.protocolError(.failed, "The metadata request is malformed.")
        }
        try write(ItemResponse(item: try provider.metadata(id: id)))
    case "reveal":
        guard let id = request.id, let field = request.field, request.context == nil else {
            throw OnePasswordProviderFailure.protocolError(.failed, "The reveal request is malformed.")
        }
        var secret = try provider.reveal(id: id, field: field)
        try write(ValueResponse(value: secret))
        secret = ""
    default:
        throw OnePasswordProviderFailure.protocolError(.unsupported, "The requested credential operation is unsupported.")
    }
} catch let failure as OnePasswordProviderFailure {
    try? write(ErrorResponse(error: failure.response))
} catch {
    try? write(ErrorResponse(error: .init(code: .failed, message: "The credential provider failed.")))
}
