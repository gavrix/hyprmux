import Darwin
import XCTest
@testable import HyprmuxCore
@testable import HyprmuxCredentialSupport
@testable import OnePasswordCredentialProvider

final class CredentialProviderTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    /// Every manifest shipped in Resources/credential-providers must parse.
    func testBundledManifestsParse() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/credential-providers")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }
        XCTAssertFalse(names.isEmpty)
        for name in names {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            guard case .success(let manifest) = CredentialProviderManifest.parse(data) else {
                return XCTFail("\(name) does not parse")
            }
            XCTAssertTrue(CredentialProviderManifest.isValidIdentifier(manifest.id))
            XCTAssertEqual(try? Dispatcher.parse("fillcredential", manifest.id).get(), .fillCredential(manifest.id))
        }
    }

    func testRegistryUserOverrideAndDisable() throws {
        let builtIn = temporary.appendingPathComponent("builtin")
        let user = temporary.appendingPathComponent("user")
        let bin = temporary.appendingPathComponent("bin")
        for directory in [builtIn, user, bin] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let executable = bin.appendingPathComponent("provider")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try #"{"id":"same","name":"Built in","exec":"provider"}"#.write(
            to: builtIn.appendingPathComponent("one.json"), atomically: true, encoding: .utf8)
        try #"{"id":"same","name":"User","exec":"provider"}"#.write(
            to: user.appendingPathComponent("one.json"), atomically: true, encoding: .utf8)

        var registry = CredentialProviderRegistry.load(directories: [(.builtin, builtIn.path), (.user, user.path)],
                                                         binDirectories: [bin.path])
        XCTAssertEqual(registry.entries.count, 1)
        XCTAssertEqual(registry.entries[0].manifest.name, "User")
        XCTAssertEqual(registry.overridden.count, 1)
        XCTAssertTrue(registry.entries[0].usable)

        try #"{"id":"same","disabled":true}"#.write(
            to: user.appendingPathComponent("one.json"), atomically: true, encoding: .utf8)
        registry = .load(directories: [(.builtin, builtIn.path), (.user, user.path)], binDirectories: [bin.path])
        XCTAssertTrue(registry.entries[0].manifest.disabled)
        XCTAssertFalse(registry.entries[0].usable)
    }

    func testRegistryRejectsUntrustedUserManifestAndExecutable() throws {
        let user = temporary.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        let executable = user.appendingPathComponent("provider.sh")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let manifest = user.appendingPathComponent("provider.json")
        try #"{"id":"test","name":"Test","exec":"./provider.sh"}"#.write(to: manifest, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: manifest.path)
        var registry = CredentialProviderRegistry.load(directories: [(.user, user.path)], binDirectories: [])
        XCTAssertTrue(registry.entries.isEmpty)
        XCTAssertTrue(registry.errors[0].message.contains("writable"))

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o722], ofItemAtPath: executable.path)
        registry = .load(directories: [(.user, user.path)], binDirectories: [])
        XCTAssertEqual(registry.entries.count, 1)
        XCTAssertTrue(registry.entries[0].problem?.contains("writable") == true)
    }

    func testRegistryRejectsSymlinkTargetWritableParentAndExternalBuiltin() throws {
        let user = temporary.appendingPathComponent("user")
        let targets = temporary.appendingPathComponent("targets")
        let builtIn = temporary.appendingPathComponent("builtin")
        for directory in [user, targets, builtIn] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let writableTarget = targets.appendingPathComponent("writable-provider")
        try "#!/bin/sh\necho '{\"items\":[]}'\n".write(to: writableTarget, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o722], ofItemAtPath: writableTarget.path)
        let link = user.appendingPathComponent("provider-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: writableTarget)
        try #"{"id":"linked","name":"Linked","exec":"./provider-link"}"#.write(
            to: user.appendingPathComponent("linked.json"), atomically: true, encoding: .utf8)

        var registry = CredentialProviderRegistry.load(directories: [(.user, user.path)], binDirectories: [])
        XCTAssertEqual(registry.entries.count, 1)
        XCTAssertTrue(registry.entries[0].problem?.contains("writable") == true)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: writableTarget.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o722], ofItemAtPath: targets.path)
        registry = CredentialProviderRegistry.load(directories: [(.user, user.path)], binDirectories: [])
        XCTAssertTrue(registry.entries[0].problem?.contains("parent directory") == true)

        try #"{"id":"builtin","name":"Built in","exec":"writable-provider"}"#.write(
            to: builtIn.appendingPathComponent("builtin.json"), atomically: true, encoding: .utf8)
        registry = CredentialProviderRegistry.load(directories: [(.builtin, builtIn.path)],
                                                     binDirectories: [targets.path])
        XCTAssertTrue(registry.entries[0].problem?.contains("untrusted executable") == true)
    }

    func testRegistryRejectsWritableUserProviderDirectory() throws {
        let user = temporary.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o722], ofItemAtPath: user.path)
        try #"{"id":"test","disabled":true}"#.write(
            to: user.appendingPathComponent("provider.json"), atomically: true, encoding: .utf8)

        let registry = CredentialProviderRegistry.load(directories: [(.user, user.path)], binDirectories: [])
        XCTAssertTrue(registry.entries.isEmpty)
        XCTAssertTrue(registry.errors.contains { $0.message.contains("untrusted provider directory") })
    }

    func testRequestRechecksExecutableTrust() throws {
        let user = temporary.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        let executable = user.appendingPathComponent("provider.sh")
        try "#!/bin/sh\ncat >/dev/null\necho '{\"items\":[]}'\n".write(
            to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try #"{"id":"test","name":"Test","exec":"./provider.sh"}"#.write(
            to: user.appendingPathComponent("provider.json"), atomically: true, encoding: .utf8)
        let registry = CredentialProviderRegistry.load(directories: [(.user, user.path)], binDirectories: [])
        let provider = try XCTUnwrap(registry.entry("test"))
        XCTAssertTrue(provider.usable)

        try FileManager.default.setAttributes([.posixPermissions: 0o722], ofItemAtPath: executable.path)
        let request = CredentialRequest.list(.init(origin: "https://example.com", host: "example.com", field: .password))
        XCTAssertThrowsError(try CredentialProcess.request(request, provider: provider)) {
            XCTAssertTrue(($0 as? CredentialProcessError)?.userMessage.contains("no longer trusted") == true)
        }
    }

    func testProcessRunnerTimeoutOutputCapNonzeroAndStderrPrivacy() throws {
        let fixture = temporary.appendingPathComponent("provider.sh")
        try #"""
        #!/bin/sh
        cat >/dev/null
        case "$1" in
          ok) echo '{"items":[]}' ;;
          timeout) sleep 5 ;;
          cap) head -c 17000000 /dev/zero | tr '\0' x ;;
          nonzero) echo 'stderr-secret' >&2; exit 9 ;;
          safe-error) echo 'stderr-secret' >&2; echo '{"error":{"code":"locked","message":"Unlock it."}}' ;;
          env) [ "$HYPRMUX_CREDENTIAL_PROTOCOL" = 1 ] && echo '{"items":[]}' || exit 7 ;;
          no-stdin) exec 0<&-; echo '{"items":[]}' ;;
        esac
        """#.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let request = CredentialRequest.list(.init(origin: "https://example.com", host: "example.com", field: .password))
        XCTAssertEqual(try CredentialProcess.run(executable: fixture.path, arguments: ["ok"], request: request, timeout: 2), .list([]))
        XCTAssertEqual(try CredentialProcess.run(executable: fixture.path, arguments: ["env"], request: request, timeout: 2), .list([]))
        let largeRequest = CredentialRequest.list(.init(origin: String(repeating: "x", count: 256 * 1024),
                                                        host: "example.com", field: .password))
        XCTAssertEqual(try CredentialProcess.run(executable: fixture.path, arguments: ["no-stdin"],
                                                 request: largeRequest, timeout: 2), .list([]))
        XCTAssertThrowsError(try CredentialProcess.run(executable: fixture.path, arguments: ["timeout"], request: request, timeout: 0.05)) {
            XCTAssertEqual($0 as? CredentialProcessError, .timedOut)
        }
        XCTAssertThrowsError(try CredentialProcess.run(executable: fixture.path, arguments: ["cap"], request: request, timeout: 5)) {
            XCTAssertEqual($0 as? CredentialProcessError, .outputTooLarge)
        }
        XCTAssertThrowsError(try CredentialProcess.run(executable: fixture.path, arguments: ["nonzero"], request: request, timeout: 2)) {
            let error = $0 as? CredentialProcessError
            XCTAssertEqual(error, .nonzeroExit)
            XCTAssertFalse(error?.userMessage.contains("stderr-secret") == true)
        }
        XCTAssertThrowsError(try CredentialProcess.run(executable: fixture.path, arguments: ["safe-error"], request: request, timeout: 2)) {
            let error = $0 as? CredentialProcessError
            XCTAssertEqual(error, .provider(.init(code: .locked, message: "Unlock it.")))
            XCTAssertFalse(error?.userMessage.contains("stderr-secret") == true)
        }
    }

    func testOnePasswordListMetadataAndRevealDecodingDoesNotLeakListSecrets() throws {
        let listData = Data(#"""
        [{"id":"item1","title":"Example","category":"LOGIN","vault":{"name":"Personal"},
          "additional_information":"me@example.com","urls":[{"href":"https://example.com/login","primary":true}],
          "fields":[{"purpose":"PASSWORD","value":"list-secret"}],"password":"other-secret"}]
        """#.utf8)
        let items = try OnePasswordCredentialProvider.decodeList(listData)
        XCTAssertEqual(items, [CredentialItemSummary(id: "item1", title: "Example", account: "me@example.com",
                                                      websites: ["https://example.com/login"],
                                                      container: "Personal", containerLabel: "vault")])
        let encodedList = String(data: try JSONEncoder().encode(items), encoding: .utf8)!
        XCTAssertFalse(encodedList.contains("list-secret"))
        XCTAssertFalse(encodedList.contains("other-secret"))

        let itemData = Data(#"""
        {"id":"item1","title":"Example","category":"LOGIN","urls":[{"href":"https://example.com"}],
         "fields":[{"purpose":"USERNAME","value":"person"},{"purpose":"PASSWORD","value":"correct-secret"}]}
        """#.utf8)
        let metadata = try OnePasswordCredentialProvider.decodeMetadata(itemData)
        XCTAssertEqual(metadata, CredentialItemSummary(id: "item1", title: "Example", websites: ["https://example.com"]))
        let encodedMetadata = String(data: try JSONEncoder().encode(metadata), encoding: .utf8)!
        XCTAssertFalse(encodedMetadata.contains("correct-secret"))
        XCTAssertEqual(try OnePasswordCredentialProvider.decodeRevealedField(itemData, field: .username), "person")
        XCTAssertEqual(try OnePasswordCredentialProvider.decodeRevealedField(itemData, field: .password), "correct-secret")
    }

    func testOnePasswordFieldFallbackAndVersion() throws {
        let data = Data(#"{"id":"item1","fields":[{"id":"username","value":"person"},{"id":"password","value":"secret"}]}"#.utf8)
        XCTAssertEqual(try OnePasswordCredentialProvider.decodeRevealedField(data, field: .username), "person")
        XCTAssertEqual(try OnePasswordCredentialProvider.decodeRevealedField(data, field: .password), "secret")
        XCTAssertEqual(OnePasswordCredentialProvider.majorVersion("2.31.1"), 2)
        XCTAssertEqual(OnePasswordCredentialProvider.majorVersion("v2.31.1\n"), 2)
        XCTAssertNil(OnePasswordCredentialProvider.majorVersion("version 2"))
    }
}
