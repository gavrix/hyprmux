import AppKit
import HyprmuxCore
import HyprmuxCredentialSupport

final class CredentialProviderRuntime {
    private(set) var registry = CredentialProviderRegistry()

    static var directories: [(CredentialProviderSource, String)] {
        var result: [(CredentialProviderSource, String)] = []
        if let builtIn = Bundle.main.resourceURL?.appendingPathComponent("credential-providers").path {
            result.append((.builtin, builtIn))
        }
        let configDirectory = (AppDelegate.configPath as NSString).deletingLastPathComponent
        result.append((.user, (configDirectory as NSString).appendingPathComponent("credential-providers")))
        return result
    }

    /// Development overrides, then bundled executables. The manifest directory is checked last.
    static var binDirectories: [String] {
        var result = (ProcessInfo.processInfo.environment["HYPRMUX_CREDENTIAL_BIN"] ?? "")
            .split(separator: ":").map { (String($0) as NSString).expandingTildeInPath }
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent().path {
            result.append(executableDirectory)
        }
        return result
    }

    func reload() {
        registry = .load(directories: Self.directories, binDirectories: Self.binDirectories)
        for error in registry.errors {
            log.warning("credential provider \(error.path, privacy: .public): \(error.message, privacy: .public)")
        }
        for entry in registry.entries where entry.problem != nil {
            log.warning("credential provider \(entry.path, privacy: .public): \(entry.problem!, privacy: .public)")
        }
    }
}

/// The tile a credential request fills. The references are weak so a slow provider
/// does not keep a closed tile alive.
private struct CredentialFill {
    enum Target {
        case browser(CredentialTarget)
        /// The foreground process group that showed the password prompt.
        case terminal(pid: Int32)
    }

    let target: Target
    let context: CredentialContext
    let pickerTitle: String
    weak var browser: BrowserSurface?
    weak var terminal: TerminalView?

    var surface: AnyObject? { browser ?? terminal }
    var field: CredentialField { context.field }
}

private struct ProviderCredentialItem {
    let pickerID: String
    let provider: CredentialProviderEntry
    let item: CredentialItemSummary
}

private final class CredentialListState {
    let providers: [CredentialProviderEntry]
    let explicitProvider: Bool
    var results: [[CredentialItemSummary]?]
    var failures: [CredentialProcessError?]
    var active = true

    init(providers: [CredentialProviderEntry], explicitProvider: Bool) {
        self.providers = providers
        self.explicitProvider = explicitProvider
        results = Array(repeating: nil, count: providers.count)
        failures = Array(repeating: nil, count: providers.count)
    }

    var isComplete: Bool {
        providers.indices.allSatisfy { results[$0] != nil || failures[$0] != nil }
    }

    var pendingProvider: CredentialProviderEntry? {
        providers.indices.first(where: { results[$0] == nil && failures[$0] == nil }).map { providers[$0] }
    }

    var rows: [ProviderCredentialItem] {
        providers.indices.flatMap { providerIndex in
            (results[providerIndex] ?? []).enumerated().map { itemIndex, item in
                ProviderCredentialItem(pickerID: "\(providerIndex):\(itemIndex):\(item.id)",
                                       provider: providers[providerIndex], item: item)
            }
        }
    }

    func stop() {
        active = false
        results = Array(repeating: nil, count: providers.count)
        failures = Array(repeating: nil, count: providers.count)
    }
}

extension Compositor {
    func loadCredentialProviders() {
        credentialProviders.reload()
        for error in credentialProviders.registry.errors {
            let name = (error.path as NSString).lastPathComponent
            hud.notifications.post(.error, title: "Credential provider skipped", "\(name): \(error.message)")
        }
        for entry in credentialProviders.registry.entries where entry.problem != nil {
            hud.notifications.post(.error, title: "Credential provider unavailable",
                                   "\(entry.manifest.name): \(entry.problem!)")
        }
        for id in credentialProviderOrder().skippedIDs {
            hud.notifications.post(.error, title: "Credential provider unavailable",
                                   "\(id) from credentials:providers was not found or is unusable.")
        }
    }

    private func credentialProviderOrder() -> CredentialProviderOrderResolution {
        let available = credentialProviders.registry.entries.map {
            CredentialProviderAvailability(id: $0.id, usable: $0.usable)
        }
        return CredentialProviderOrdering.resolve(configuredIDs: config.credentialProviders, available: available)
    }

    func credentialFill(_ id: ClientID, providerID: String?) {
        guard credentialRequest == nil else {
            credentialNotice(.error, "Another credential request is already active.")
            return
        }
        let entries: [CredentialProviderEntry]
        if let providerID {
            guard let entry = credentialProviders.registry.entry(providerID) else {
                credentialNotice(.error, "Credential provider \"\(providerID)\" was not found.")
                return
            }
            guard entry.usable else {
                credentialNotice(.error, "Credential provider \"\(providerID)\" is unavailable.")
                return
            }
            entries = [entry]
        } else {
            entries = credentialProviderOrder().providerIDs.compactMap(credentialProviders.registry.entry)
        }
        guard !entries.isEmpty else {
            credentialNotice(.error, "No credential providers are enabled.")
            return
        }
        switch views[id]?.surface {
        case let surface as BrowserSurface:
            beginBrowserCredentialFill(id: id, surface: surface, providers: entries,
                                       explicitProvider: providerID != nil)
        case let terminal as TerminalView:
            beginTerminalCredentialFill(id: id, terminal: terminal, providers: entries,
                                        explicitProvider: providerID != nil)
        default:
            credentialNotice(.error, "Credential fill works only in browser and terminal tiles.")
        }
    }

    private func beginBrowserCredentialFill(id: ClientID, surface: BrowserSurface,
                                            providers: [CredentialProviderEntry], explicitProvider: Bool) {
        if surface is ChromiumSurface,
           let unsafeSwitch = ChromiumCredentialPolicy.refusingSwitch(in: config.chromiumFlags)
                ?? startupChromiumCredentialRefusingSwitch {
            credentialNotice(.error,
                             "Chromium credential fill is disabled while \(unsafeSwitch) is configured because it can expose filled values.")
            return
        }

        let requestID = UUID()
        credentialRequest = requestID
        surface.captureCredentialTarget { [weak self, weak surface] result in
            guard let self, let surface, self.credentialRequest == requestID else { return }
            guard self.views[id]?.surface === surface else {
                self.cancelCredential(requestID, message: "The target tile closed before filling.")
                return
            }
            switch result {
            case .failure(let error): self.cancelCredential(requestID, message: error.localizedDescription)
            case .success(let target):
                let fill = CredentialFill(
                    target: .browser(target),
                    context: CredentialContext(origin: target.origin, host: target.host, field: target.field),
                    pickerTitle: "Credentials for \(target.host)", browser: surface)
                self.listCredentials(requestID: requestID, id: id, fill: fill, providers: providers,
                                     explicitProvider: explicitProvider)
            }
        }
    }

    /// A terminal has no origin to check, so the gate is Ghostty's password-prompt state,
    /// and the same foreground program must still be asking when the password is typed.
    private func beginTerminalCredentialFill(id: ClientID, terminal: TerminalView,
                                             providers: [CredentialProviderEntry], explicitProvider: Bool) {
        let state = terminal.credentialState
        if let refusal = TerminalCredentialPolicy.captureRefusal(state) {
            credentialNotice(.error, refusal.message)
            return
        }
        let process = terminal.foregroundProcessName
        let fill = CredentialFill(target: .terminal(pid: state.foregroundPID),
                                  context: .terminal(process: process, title: terminal.title),
                                  pickerTitle: "Password for \(process ?? "terminal")", terminal: terminal)
        let requestID = UUID()
        credentialRequest = requestID
        listCredentials(requestID: requestID, id: id, fill: fill, providers: providers,
                        explicitProvider: explicitProvider)
    }

    /// True while the tile that started the request is still the one at `id`.
    private func credentialTileIsCurrent(_ id: ClientID, _ fill: CredentialFill) -> Bool {
        guard let surface = fill.surface else { return false }
        return views[id]?.surface === surface
    }

    private func listCredentials(requestID: UUID, id: ClientID, fill: CredentialFill,
                                 providers: [CredentialProviderEntry], explicitProvider: Bool) {
        let state = CredentialListState(providers: providers, explicitProvider: explicitProvider)
        let context = fill.context
        var picker = Picker(title: fill.pickerTitle, maxVisible: config.hud.pickerMaxRows,
                            rowLayout: .stacked, status: credentialPickerStatus(state))
        picker.placeholder = "type to filter credentials"
        picker.emptyText = "Loading credentials…"
        hud.picker.present(picker, anchor: .client(id, .center), requestID: requestID) { [weak self] result in
            guard let self, fill.surface != nil, self.credentialRequest == requestID else {
                state.stop()
                return
            }
            guard state.active else { return }
            let rows = state.rows
            state.stop()
            guard case .item(let pickerID)? = result,
                  let selected = rows.first(where: { $0.pickerID == pickerID }) else {
                self.credentialRequest = nil
                return
            }
            switch fill.target {
            case .browser(let target):
                self.fetchCredentialMetadata(requestID: requestID, id: id, fill: fill, target: target,
                                             provider: selected.provider, selectedID: selected.item.id)
            case .terminal:
                // No website to compare: choosing the item is the confirmation.
                self.revealCredential(requestID: requestID, id: id, fill: fill,
                                      provider: selected.provider, selectedID: selected.item.id)
            }
        }

        for (index, provider) in providers.enumerated() {
            DispatchQueue.global(qos: .userInitiated).async {
                let result: Result<[CredentialItemSummary], CredentialProcessError>
                do {
                    let response = try CredentialProcess.request(.list(context), provider: provider)
                    guard case .list(let items) = response else { throw CredentialProcessError.malformedResponse }
                    result = .success(items)
                } catch let error as CredentialProcessError { result = .failure(error) }
                catch { result = .failure(.malformedResponse) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, fill.surface != nil else { return }
                    self.updateCredentialList(result, providerIndex: index, state: state, requestID: requestID,
                                              id: id, fill: fill)
                }
            }
        }
    }

    private func updateCredentialList(_ result: Result<[CredentialItemSummary], CredentialProcessError>,
                                      providerIndex: Int, state: CredentialListState, requestID: UUID,
                                      id: ClientID, fill: CredentialFill) {
        guard state.active, credentialRequest == requestID else { return }
        guard credentialTileIsCurrent(id, fill) else {
            state.stop()
            credentialRequest = nil
            hud.picker.cancel()
            credentialNotice(.error, "The target tile closed before filling.")
            return
        }
        switch result {
        case .success(let items): state.results[providerIndex] = items
        case .failure(let error): state.failures[providerIndex] = error
        }

        let rows = state.rows
        if state.isComplete {
            let visibleFailures = postCredentialListFailures(state)
            guard !rows.isEmpty else {
                state.stop()
                credentialRequest = nil
                hud.picker.cancel()
                if visibleFailures == 0 { credentialNotice(.error, "No credential items are available.") }
                return
            }
        }
        let includeProvider = state.results.compactMap { $0 }.filter { !$0.isEmpty }.count > 1
        let items = rows.map {
            $0.item.pickerItem(pickerID: $0.pickerID, providerName: $0.provider.manifest.name,
                               includeProvider: includeProvider)
        }
        hud.picker.update(items: items, status: credentialPickerStatus(state),
                          icons: credentialPickerIcons(rows), requestID: requestID)
    }

    private func credentialPickerStatus(_ state: CredentialListState) -> String? {
        state.pendingProvider.map { "loading \($0.manifest.name)…" }
    }

    private func credentialPickerIcons(_ rows: [ProviderCredentialItem]) -> [String: NSImage] {
        guard let symbol = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Credential") else { return [:] }
        let icon = symbol.withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor])) ?? symbol
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.pickerID, icon) })
    }

    @discardableResult
    private func postCredentialListFailures(_ state: CredentialListState) -> Int {
        let failures = state.providers.indices.compactMap { index -> (CredentialProviderEntry, CredentialProcessError)? in
            state.failures[index].map { (state.providers[index], $0) }
        }
        let kinds = failures.map { credentialListFailureKind($0.1) }
        let visible = Set(CredentialFailurePolicy.visibleFailureIndices(
            kinds, providerCount: state.providers.count, explicitProvider: state.explicitProvider))
        for (index, failure) in failures.enumerated() {
            if visible.contains(index) {
                credentialNotice(.error, "\(failure.0.manifest.name): \(failure.1.userMessage)")
            } else {
                log.debug("credential provider \(failure.0.id, privacy: .public) is not installed")
            }
        }
        return visible.count
    }

    private func credentialListFailureKind(_ error: CredentialProcessError) -> CredentialListFailureKind {
        guard case .provider(let providerError) = error else { return .other }
        switch providerError.code {
        case .notInstalled: return .notInstalled
        case .locked: return .locked
        case .unauthorized: return .unauthorized
        default: return .other
        }
    }

    private func fetchCredentialMetadata(requestID: UUID, id: ClientID, fill: CredentialFill,
                                         target: CredentialTarget, provider: CredentialProviderEntry,
                                         selectedID: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<CredentialItemSummary, CredentialProcessError>
            do {
                let response = try CredentialProcess.request(.metadata(id: selectedID), provider: provider)
                guard case .metadata(let item) = response else { throw CredentialProcessError.malformedResponse }
                result = .success(item)
            } catch let error as CredentialProcessError { result = .failure(error) }
            catch { result = .failure(.malformedResponse) }
            DispatchQueue.main.async { [weak self] in
                guard let self, fill.surface != nil, self.credentialRequest == requestID else { return }
                guard self.credentialTileIsCurrent(id, fill) else {
                    self.cancelCredential(requestID, message: "The target tile closed before filling.")
                    return
                }
                switch result {
                case .failure(let error): self.cancelCredential(requestID, message: error.userMessage)
                case .success(let metadata):
                    guard CredentialSecurity.isValidItemID(metadata.id) else {
                        self.cancelCredential(requestID, message: "The provider returned an invalid credential item ID.")
                        return
                    }
                    guard metadata.id == selectedID else {
                        self.cancelCredential(requestID, message: "The provider returned a different credential item.")
                        return
                    }
                    if CredentialSecurity.hostsMatch(pageHost: target.host, savedWebsites: metadata.websites) {
                        self.revealCredential(requestID: requestID, id: id, fill: fill,
                                              provider: provider, selectedID: selectedID)
                    } else {
                        self.confirmCredentialMismatch(requestID: requestID, id: id, fill: fill, target: target,
                                                       provider: provider, selectedID: selectedID,
                                                       savedWebsites: metadata.websites)
                    }
                }
            }
        }
    }

    private func confirmCredentialMismatch(requestID: UUID, id: ClientID, fill: CredentialFill,
                                           target: CredentialTarget, provider: CredentialProviderEntry,
                                           selectedID: String, savedWebsites: [String]) {
        let hosts = savedWebsites.compactMap(CredentialSecurity.normalizeWebsiteHost)
        let saved = hosts.isEmpty ? "no saved website" : "saved: " + hosts.joined(separator: ", ")
        var picker = Picker(title: "Website check for \(target.host)",
                            items: [PickerItem(id: "fill", title: "Fill anyway", detail: saved)], maxVisible: 1)
        picker.placeholder = "Escape cancels"
        hud.picker.present(picker, anchor: .client(id, .center)) { [weak self] result in
            guard let self, fill.surface != nil, self.credentialRequest == requestID else { return }
            guard case .item("fill")? = result else { self.credentialRequest = nil; return }
            self.revealCredential(requestID: requestID, id: id, fill: fill,
                                  provider: provider, selectedID: selectedID)
        }
    }

    private func revealCredential(requestID: UUID, id: ClientID, fill: CredentialFill,
                                  provider: CredentialProviderEntry, selectedID: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<String, CredentialProcessError>
            do {
                let response = try CredentialProcess.request(.reveal(id: selectedID, field: fill.field), provider: provider)
                guard case .reveal(let value) = response else { throw CredentialProcessError.malformedResponse }
                result = .success(value)
            } catch let error as CredentialProcessError { result = .failure(error) }
            catch { result = .failure(.malformedResponse) }
            DispatchQueue.main.async { [weak self] in
                guard let self, fill.surface != nil, self.credentialRequest == requestID else { return }
                guard self.credentialTileIsCurrent(id, fill) else {
                    self.cancelCredential(requestID, message: "The target tile closed before filling.")
                    return
                }
                switch result {
                case .failure(let error): self.cancelCredential(requestID, message: error.userMessage)
                case .success(let value):
                    switch fill.target {
                    case .browser(let target):
                        guard let surface = fill.browser else { return }
                        // The browser revalidates the origin, focused element, token, eligibility, and field kind.
                        surface.fillCredentialTarget(target, value: value) { [weak self] fillResult in
                            guard let self, self.credentialRequest == requestID else { return }
                            switch fillResult {
                            case .success:
                                self.credentialRequest = nil
                                self.credentialNotice(.success, "Filled the focused field.")
                            case .failure(let error):
                                self.cancelCredential(requestID, message: error.localizedDescription)
                            }
                        }
                    case .terminal(let pid):
                        self.typeTerminalCredential(requestID: requestID, id: id, fill: fill,
                                                    capturedPID: pid, value: value)
                    }
                }
            }
        }
    }

    /// Types the password as keyboard input: no bracketed paste, no Return. Ghostty stops
    /// refreshing the prompt state while the picker holds focus, so this waits until the
    /// terminal has been focused for `settleInterval` and then checks the state again.
    private func typeTerminalCredential(requestID: UUID, id: ClientID, fill: CredentialFill,
                                        capturedPID: Int32, value: String) {
        guard credentialRequest == requestID else { return }
        guard let terminal = fill.terminal, credentialTileIsCurrent(id, fill) else {
            cancelCredential(requestID, message: "The target tile closed before filling.")
            return
        }
        let state = terminal.credentialState
        if state.focused {
            let focusedFor = ProcessInfo.processInfo.systemUptime - terminal.focusedSince
            let wait = TerminalCredentialPolicy.settleInterval - focusedFor
            if wait > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    self?.typeTerminalCredential(requestID: requestID, id: id, fill: fill,
                                                 capturedPID: capturedPID, value: value)
                }
                return
            }
        }
        if let refusal = TerminalCredentialPolicy.fillRefusal(capturedPID: capturedPID, state) {
            cancelCredential(requestID, message: refusal.message)
            return
        }
        terminal.sendText(value)
        credentialRequest = nil
        credentialNotice(.success, "Typed the password into the terminal.")
    }

    private func cancelCredential(_ requestID: UUID, message: String) {
        guard credentialRequest == requestID else { return }
        credentialRequest = nil
        credentialNotice(.error, message)
    }

    private func credentialNotice(_ level: NoticeLevel, _ message: String) {
        hud.notifications.post(level, title: "Credentials", message)
    }
}
