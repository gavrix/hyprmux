import XCTest
@testable import HyprmuxCore

final class CredentialsTests: XCTestCase {
    func testManifestParsingDefaultsUnknownKeysAndBadIDs() throws {
        let valid = try CredentialProviderManifest.parse(Data(#"{"id":"vault.test","name":"Vault","exec":"provider"}"#.utf8)).get()
        XCTAssertEqual(valid, CredentialProviderManifest(id: "vault.test", name: "Vault", exec: "provider"))
        XCTAssertEqual(valid.timeout, 300)
        XCTAssertEqual(try CredentialProviderManifest.parse(Data(#"{"id":"vault.test","disabled":true}"#.utf8)).get().disabled, true)
        XCTAssertEqual(CredentialProviderManifest.parse(Data(#"{"id":"vault","exec":"x","typo":true}"#.utf8)),
                       .failure(ParseError("unknown key \"typo\"")))
        XCTAssertEqual(CredentialProviderManifest.parse(Data(#"{"id":"vault","exec":"x"}"#.utf8)),
                       .failure(ParseError("\"name\" is required")))
        for id in ["1vault", "bad/id", "bad id", ""] {
            guard case .failure = CredentialProviderManifest.parse(Data("{\"id\":\"\(id)\",\"exec\":\"x\"}".utf8)) else {
                return XCTFail("accepted bad id \(id)")
            }
        }
    }

    func testRequestEncodingUsesProtocolV1Shapes() throws {
        let context = CredentialContext(origin: "https://example.com", host: "example.com", field: .password)
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: CredentialRequest.list(context).encoded())
            as? [String: Any])
        XCTAssertEqual(Set(list.keys), ["protocol", "op", "context"])
        XCTAssertEqual(list["protocol"] as? Int, 1)
        XCTAssertEqual(list["op"] as? String, "list")
        XCTAssertEqual((list["context"] as? [String: Any])?["host"] as? String, "example.com")

        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(
            with: CredentialRequest.metadata(id: "item.1").encoded()) as? [String: Any])
        XCTAssertEqual(Set(metadata.keys), ["protocol", "op", "id"])
        XCTAssertEqual(metadata["op"] as? String, "metadata")
        XCTAssertEqual(metadata["id"] as? String, "item.1")

        let revealData = try CredentialRequest.reveal(id: "item.1", field: .username).encoded()
        let reveal = try XCTUnwrap(JSONSerialization.jsonObject(with: revealData) as? [String: Any])
        XCTAssertEqual(Set(reveal.keys), ["protocol", "op", "id", "field"])
        XCTAssertEqual(reveal["op"] as? String, "reveal")
        XCTAssertEqual(reveal["id"] as? String, "item.1")
        XCTAssertEqual(reveal["field"] as? String, "username")
        XCTAssertEqual(try JSONDecoder().decode(CredentialRequest.self, from: revealData),
                       .reveal(id: "item.1", field: .username))
    }

    func testListContextShapesForWebAndTerminal() throws {
        func context(_ c: CredentialContext) throws -> [String: Any] {
            let raw = try JSONSerialization.jsonObject(with: CredentialRequest.list(c).encoded()) as? [String: Any]
            return try XCTUnwrap(raw?["context"] as? [String: Any])
        }
        let web = try context(CredentialContext(origin: "https://example.com", host: "example.com", field: .username))
        XCTAssertEqual(Set(web.keys), ["kind", "origin", "host", "field"])
        XCTAssertEqual(web["kind"] as? String, "web")

        let long = String(repeating: "t", count: 300)
        let terminal = try context(.terminal(process: " sudo \n", title: long))
        XCTAssertEqual(Set(terminal.keys), ["kind", "field", "process", "title"])
        XCTAssertEqual(terminal["kind"] as? String, "terminal")
        XCTAssertEqual(terminal["field"] as? String, "password")
        XCTAssertEqual(terminal["process"] as? String, "sudo")
        XCTAssertEqual((terminal["title"] as? String)?.count, CredentialContext.maxHintLength)
        XCTAssertEqual(Set(try context(.terminal(process: nil, title: "  ")).keys), ["kind", "field"])

        let decode = { (json: String) in try JSONDecoder().decode(CredentialContext.self, from: Data(json.utf8)) }
        XCTAssertEqual(try decode(#"{"origin":"https://a.test","host":"a.test","field":"password"}"#).kind, .web)
        XCTAssertEqual(try decode(#"{"kind":"terminal","field":"password","process":"ssh"}"#),
                       .terminal(process: "ssh", title: nil))
        XCTAssertThrowsError(try decode(#"{"kind":"web","field":"password"}"#))
    }

    func testTerminalCredentialPolicy() {
        let ready = TerminalCredentialState(focused: true, passwordInput: true, foregroundPID: 42)
        XCTAssertNil(TerminalCredentialPolicy.captureRefusal(ready))
        var state = ready
        state.focused = false
        XCTAssertEqual(TerminalCredentialPolicy.captureRefusal(state), .notFocused)
        state = ready; state.passwordInput = false
        XCTAssertEqual(TerminalCredentialPolicy.captureRefusal(state), .noPasswordPrompt)
        state = ready; state.foregroundPID = 0
        XCTAssertEqual(TerminalCredentialPolicy.captureRefusal(state), .unknownProgram)

        XCTAssertNil(TerminalCredentialPolicy.fillRefusal(capturedPID: 42, ready))
        state = ready; state.foregroundPID = 43
        XCTAssertEqual(TerminalCredentialPolicy.fillRefusal(capturedPID: 42, state), .programChanged)
        state = ready; state.passwordInput = false
        XCTAssertEqual(TerminalCredentialPolicy.fillRefusal(capturedPID: 42, state), .noPasswordPrompt)
        state = ready; state.focused = false
        XCTAssertEqual(TerminalCredentialPolicy.fillRefusal(capturedPID: 42, state), .notFocused)
        XCTAssertGreaterThan(TerminalCredentialPolicy.settleInterval, 0.2, "must exceed Ghostty's termios poll")
    }

    func testProtocolResponseDecodingAndInvalidListRows() throws {
        let list = try CredentialResponse.decode(Data(#"{"items":[{"id":"good.1","title":"Example","websites":["https://example.com"]},{"id":"bad/id","title":"Bad"},{"id":"missing"}]}"#.utf8))
        XCTAssertEqual(list, .list([CredentialItemSummary(id: "good.1", title: "Example", websites: ["https://example.com"])]))
        XCTAssertEqual(try CredentialResponse.decode(Data(#"{"item":{"id":"item-1","title":"Example"}}"#.utf8)),
                       .metadata(CredentialItemSummary(id: "item-1", title: "Example")))
        XCTAssertEqual(try CredentialResponse.decode(Data(#"{"value":"secret"}"#.utf8)), .reveal("secret"))
        XCTAssertEqual(try CredentialResponse.decode(Data(#"{"error":{"code":"locked","message":"Unlock it."}}"#.utf8)),
                       .error(.init(code: .locked, message: "Unlock it.")))
        for malformed in [#"[]"#, #"{"items":"bad"}"#, #"{"item":{"id":"bad/id","title":"X"}}"#,
                          #"{"value":1}"#, #"{"value":"x","items":[]}"#, #"{"wat":1}"#] {
            XCTAssertThrowsError(try CredentialResponse.decode(Data(malformed.utf8)), malformed)
        }
    }

    func testMultiProviderFailureFilteringPolicy() {
        let failures: [CredentialListFailureKind] = [.notInstalled, .locked, .unauthorized, .other]
        XCTAssertEqual(CredentialFailurePolicy.visibleFailureIndices(failures, providerCount: 5,
                                                                     explicitProvider: false), [1, 2, 3])
        XCTAssertEqual(CredentialFailurePolicy.visibleFailureIndices(failures, providerCount: 4,
                                                                     explicitProvider: false), [0, 1, 2, 3])
        XCTAssertEqual(CredentialFailurePolicy.visibleFailureIndices([.notInstalled], providerCount: 3,
                                                                     explicitProvider: true), [0])
    }

    func testProviderOrderingResolution() {
        let available = [
            CredentialProviderAvailability(id: "zeta", usable: true),
            CredentialProviderAvailability(id: "broken", usable: false),
            CredentialProviderAvailability(id: "alpha", usable: true),
        ]
        XCTAssertEqual(CredentialProviderOrdering.resolve(configuredIDs: nil, available: available),
                       .init(providerIDs: ["alpha", "zeta"], skippedIDs: []))
        XCTAssertEqual(CredentialProviderOrdering.resolve(
            configuredIDs: ["zeta", "missing", "broken", "alpha", "zeta"], available: available),
            .init(providerIDs: ["zeta", "alpha"], skippedIDs: ["missing", "broken"]))
        XCTAssertEqual(CredentialProviderOrdering.resolve(configuredIDs: [], available: available),
                       .init(providerIDs: [], skippedIDs: []))
    }

    func testItemIDValidationUsesProtocolRegex() {
        for id in ["a", "A_1.-z", String(repeating: "x", count: 128)] {
            XCTAssertTrue(CredentialSecurity.isValidItemID(id))
        }
        for id in ["", "-start", "bad/id", "bad id", "é", String(repeating: "x", count: 129)] {
            XCTAssertFalse(CredentialSecurity.isValidItemID(id))
        }
    }

    func testPickerRowFormattingOptionalPartsAndProviders() {
        let full = CredentialItemSummary(id: "a", title: "Example", account: "me@example.com",
                                         websites: ["https://Login.Example.com/path"],
                                         container: "Personal", containerLabel: "vault")
        XCTAssertEqual(full.pickerItem(), PickerItem(id: "a", title: "Example · me@example.com",
                                                      detail: "login.example.com · vault: Personal"))
        XCTAssertEqual(full.pickerItem(pickerID: "p:a", providerName: "Provider", includeProvider: true),
                       PickerItem(id: "p:a", title: "Example · me@example.com",
                                  detail: "login.example.com · vault: Personal · Provider"))
        XCTAssertEqual(CredentialItemSummary(id: "a", title: "Example").pickerItem(),
                       PickerItem(id: "a", title: "Example"))
        XCTAssertEqual(CredentialItemSummary(id: "a", title: "Example", container: "Folder").pickerItem(),
                       PickerItem(id: "a", title: "Example", detail: "Folder"))
    }

    func testWebsiteHostNormalizationAndExactMatching() {
        XCTAssertEqual(CredentialSecurity.normalizeWebsiteHost(" HTTPS://Login.Example.COM./path "), "login.example.com")
        XCTAssertEqual(CredentialSecurity.normalizeWebsiteHost("::1"), "::1")
        XCTAssertNil(CredentialSecurity.normalizeWebsiteHost("file:///tmp/x"))
        XCTAssertNil(CredentialSecurity.normalizeWebsiteHost("not a url"))
        XCTAssertTrue(CredentialSecurity.hostsMatch(pageHost: "EXAMPLE.com", savedWebsites: ["https://example.com/login"]))
        XCTAssertFalse(CredentialSecurity.hostsMatch(pageHost: "login.example.com", savedWebsites: ["example.com"]))
    }

    func testCredentialOriginRulesAndEffectivePorts() {
        for origin in ["https://example.com", "http://localhost:3000", "http://app.localhost",
                       "http://127.255.255.255", "http://[::1]:8080"] {
            XCTAssertTrue(CredentialSecurity.isAllowedCredentialOrigin(origin), origin)
        }
        for origin in ["http://example.com", "http://127.example.com", "http://127.0.0.999", "http://[::2]", "file:///tmp/x"] {
            XCTAssertFalse(CredentialSecurity.isAllowedCredentialOrigin(origin), origin)
        }
        XCTAssertTrue(CredentialSecurity.sameOrigin(URL(string: "https://example.com/path")!, "https://example.com:443"))
        XCTAssertFalse(CredentialSecurity.sameOrigin(URL(string: "https://example.com:444/path")!, "https://example.com"))
    }

    func testChromiumCredentialDebuggingSwitchPolicy() {
        XCTAssertNil(ChromiumCredentialPolicy.refusingSwitch(in: [
            "disable-gpu", "load-extension=/tmp/example", "remote-allow-origins=*",
        ]))
        XCTAssertEqual(ChromiumCredentialPolicy.refusingSwitch(in: ["remote-debugging-port=9333"]),
                       "remote-debugging-port")
        XCTAssertEqual(ChromiumCredentialPolicy.refusingSwitch(in: ["--remote-debugging-pipe"]),
                       "remote-debugging-pipe")
        XCTAssertEqual(ChromiumCredentialPolicy.refusingSwitch(in: ["DEVTOOLS-PROTOCOL-LOG-FILE=/tmp/devtools.log"]),
                       "devtools-protocol-log-file")
    }

    func testDispatcherParsingTargetingAndEffect() {
        XCTAssertEqual(try? Dispatcher.parse("fillcredential", "").get(), .fillCredential(nil))
        XCTAssertEqual(try? Dispatcher.parse("fillcredential", "vault.test").get(), .fillCredential("vault.test"))
        XCTAssertNil(try? Dispatcher.parse("onepassword", "").get())
        XCTAssertTrue(Dispatcher.fillCredential(nil).targetsWindow)
        XCTAssertEqual(Dispatcher.fillCredential(nil).label, "Fill credential")
        XCTAssertEqual(try? IPCRequest.parse("dispatch --surface surface:7 fillcredential vault.test").get(),
                       .dispatch(.fillCredential("vault.test"), surface: SurfaceReference(7)))

        let wm = WindowManager(monitor: CGRect(x: 0, y: 0, width: 800, height: 600))
        var effects: [Effect] = []
        wm.perform = { effects.append($0) }
        wm.addClient(ClientID(1))
        wm.addClient(ClientID(2))
        wm.dispatch(.fillCredential("vault.test"), target: ClientID(1))
        XCTAssertEqual(effects, [.credentialFill(ClientID(1), "vault.test")])
        XCTAssertEqual(wm.focused, ClientID(2))
    }
}
