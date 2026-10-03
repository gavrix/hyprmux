# Credential providers

## Goal

Make browser credential filling provider-neutral. Hyprmux owns the flow and
every security rule. Password managers plug in through a formal, documented
extension point: a JSON manifest plus an executable that speaks a small JSON
protocol over stdin and stdout.

Hyprmux contains no password-manager-specific code. 1Password becomes the
first provider: a bundled adapter executable, like `hyprmux-electron-bridge`
is for apps. Third parties and users can add providers the same way, including
as shell scripts.

This replaces the 1Password-only design in the earlier plan. The security
behavior proven there stays the same.

## Layers

1. **Credential flow (Hyprmux core and app).** Capture the focused field, list
   items, show the picker, check hosts, confirm mismatches, reveal one field,
   revalidate, and fill.
2. **Provider (extension point).** Lists items, returns non-secret metadata,
   and reveals one field. Out of process, always.
3. **Target.** Where the value goes. WebKit today. Chromium and terminals later.

## Provider manifest

Hyprmux loads `*.json` from, in order:

1. Built-in: `Hyprmux.app/Contents/Resources/credential-providers/`, from
   `Resources/credential-providers/` in the repo.
2. User: `credential-providers/` next to the config file, normally
   `~/.config/hyprmux/credential-providers/`.

A user manifest with a built-in's `id` replaces it. A manifest with only an
`id` and `"disabled": true` turns a built-in off. Hyprmux rescans on launch and
on config reload. This mirrors app adapters (docs/ADAPTERS.md).

```json
{
  "id": "1password",
  "name": "1Password",
  "description": "Logins from the 1Password app through the op CLI.",
  "exec": "hyprmux-credential-1password",
  "args": [],
  "timeout": 300,
  "disabled": false
}
```

| Key | Meaning |
|---|---|
| `id` | Required. Starts with a letter or digit. ASCII letters, digits, `.`, `_`, `-`. |
| `name` | Required. Shown in the picker and notices. |
| `description` | Optional. For listings. |
| `exec` | Required. Absolute path, path relative to the manifest (contains `/`), or bare name. Bare names resolve in the bundle's executable directory, then the manifest's directory. |
| `args` | Optional extra arguments. Never contains secrets. |
| `timeout` | Seconds per request. Default 300, because desktop authorization prompts wait for the user. |
| `disabled` | Default false. |

Unknown keys are errors. A manifest with errors is skipped and reported.

### Trust checks

A provider is trusted code that handles secrets. Hyprmux refuses to run a user
provider when the manifest or the resolved executable is group- or
world-writable, or not owned by the current user. Built-in providers come from
the signed bundle.

## Protocol, version 1

One process per request. Hyprmux writes one JSON object to stdin, then closes
it. The provider writes one JSON object to stdout and exits. Hyprmux never
logs or displays stderr. Hyprmux sets `HYPRMUX_CREDENTIAL_PROTOCOL=1` in the
environment and passes no secrets in arguments or environment variables.

### Requests

```json
{"protocol": 1, "op": "list", "context": {"kind": "web", "origin": "https://github.com", "host": "github.com", "field": "password"}}
{"protocol": 1, "op": "list", "context": {"kind": "terminal", "field": "password", "process": "sudo", "title": "~/src"}}
{"protocol": 1, "op": "metadata", "id": "ITEM_ID"}
{"protocol": 1, "op": "reveal", "id": "ITEM_ID", "field": "password"}
```

`field` is `username` or `password`. `context` lets a provider rank or filter
items. Its `kind` is `web` or `terminal` (see docs/CREDENTIALS.md). Hyprmux still performs every security check itself.

### Responses

```json
{"items": [{"id": "ITEM_ID", "title": "GitHub", "account": "me@example.com",
            "websites": ["https://github.com/login"], "container": "Personal",
            "containerLabel": "vault"}]}
{"item": {"id": "ITEM_ID", "title": "GitHub", "websites": ["https://github.com"]}}
{"value": "the secret"}
{"error": {"code": "locked", "message": "Unlock 1Password and try again."}}
```

- `items` entries: `id` and `title` required; `account`, `websites`,
  `container`, `containerLabel` optional. Items never carry secret values.
- `metadata` returns the same shape as one list item, fetched fresh.
- `reveal` returns exactly one field value.
- Error codes: `notInstalled`, `locked`, `unauthorized`, `notFound`,
  `unsupported`, `timeout`, `failed`. `message` is shown to the user, so it must
  not contain secrets.
- A nonzero exit without a valid error object counts as `failed`.

### Hyprmux validation

- Item IDs match `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`. This blocks option
  injection when a provider passes the ID to a CLI.
- Output is capped (16 MiB stdout, 1 MiB stderr). Excess fails the request.
- Each request has the manifest timeout. Hyprmux terminates, then kills, a
  provider that exceeds it.
- Malformed items are dropped. Malformed responses fail the request.
- Revealed output buffers are zeroed after decoding where Swift allows.

## Flow

1. `fillcredential [provider-id]` targets one window. Without an argument it
   uses every enabled provider.
2. Capture the exact focused eligible input in a WebKit tile. Same rules as
   before: HTTPS or loopback HTTP, visible, enabled, editable, same-origin
   frames only, conservative username detection.
3. Send `list` to each selected provider in parallel. Merge results. A failed
   provider posts a notice; the picker still opens with the others.
4. Show the stacked picker titled with the page host. Rows:
   - line 1: `title · account`
   - line 2: `website · <containerLabel>: <container>`, plus the provider name
     when more than one provider contributed.
5. Send `metadata` for the selected item. Validate the returned ID.
6. Exact host match proceeds. Otherwise show the `Fill anyway` confirmation.
7. Send `reveal` for the one needed field.
8. Revalidate surface, origin, and element token, then fill. No UI appears
   after reveal.

## Code layout

- `Sources/HyprmuxCore/Credentials.swift`: manifest parsing, protocol message
  encoding and decoding, item summaries, ID validation, host normalization and
  exact matching, origin rules, picker row formatting. No AppKit, no Process.
- `Sources/Hyprmux/Credentials/CredentialProviderRegistry.swift`: manifest
  loading, executable resolution, trust checks.
- `Sources/Hyprmux/Credentials/CredentialProcess.swift`: generic bounded,
  timed process runner (from the current `OnePasswordService.run`).
- `Sources/Hyprmux/Compositor/Compositor+Credentials.swift`: the generic flow
  (from the current `Compositor+OnePassword.swift`).
- `Sources/hyprmux-credential-1password/`: bundled 1Password adapter. All `op`
  knowledge lives here: executable resolution, version check, `OP_*`
  stripping, JSON decoding, field selection.
- `Resources/credential-providers/1password.json`: built-in manifest.
- `docs/CREDENTIALS.md`: the formal extension-point documentation, with a
  shell-script example and its safety rules.

`Sources/HyprmuxCore/OnePassword.swift` and
`Sources/Hyprmux/Compositor/Compositor+OnePassword.swift` go away. The
`onepassword` dispatcher is replaced by `fillcredential`; it was never released.

## Tests

- Manifest parsing: valid, unknown keys, bad ids, disabled override.
- Protocol decoding: valid list, metadata, reveal, error objects, malformed
  responses, invalid IDs dropped.
- Row formatting with and without optional parts, and with several providers.
- Host and origin rules (moved from the current tests).
- 1Password adapter: list, metadata, and revealed-item decoding; field
  selection; never emitting secrets in list or metadata output.
- Process runner: timeout, output cap, nonzero exit, stderr not surfaced.
  Use a small fixture shell script.
- Registry: user override, disabled built-in, untrusted file rejection.

## Manual acceptance

In a separate test instance:

- 1Password authorization still works with `op` launched by the adapter.
  Note which app name the prompt shows.
- Picker rows, mismatch confirmation, and fill behave as before.
- A fixture shell provider in the test config directory appears and fills.
- A provider that hangs times out without freezing Hyprmux.
- A group-writable user provider is refused with a notice.

## Chromium target

Chromium tiles get the same capture and fill behavior as WebKit tiles. The
credential flow stops caring about the engine.

### Mechanism

Use the DevTools protocol from the browser process through
`CefBrowserHost::ExecuteDevToolsMethod` and `AddDevToolsMessageObserver`.
This needs no remote-debugging port and no renderer-process code.

For each capture or fill:

1. `Page.getFrameTree` returns the main frame id.
2. `Page.createIsolatedWorld` creates a fresh isolated world in that frame. Page
   scripts cannot see or patch its globals, matching WebKit's
   `WKContentWorld.defaultClient`.
3. `Runtime.callFunctionOn` runs the shared capture or fill function in that
   world, with `executionContextId`, `returnByValue`, `awaitPromise`, and
   `silent`. Values travel in the structured `arguments` array, never in
   function source.

Each call has a timeout and is cancelled when the browser closes. Results are
matched to requests by message id.

### Shared scripts

Capture and fill become two JavaScript functions that each take one argument
object. Both engines run the same source.

- WebKit calls them through `callAsyncJavaScript` with the argument object in
  `arguments`.
- Chromium calls them through `Runtime.callFunctionOn`.

`BrowserSurface` implements `captureCredentialTarget` and
`fillCredentialTarget` once. Each engine supplies only one primitive: run this
function with this argument object and return a JSON-like value.

### Chromium-specific rules

- Refuse to fill when `remote-debugging-port`, `remote-debugging-pipe`, or
  `devtools-protocol-log-file` is among the Chromium switches. The first two
  let other local processes read filled values. The last writes protocol
  messages, including secrets, to disk.
- Cross-origin iframes run in other processes (site isolation). Their
  `contentDocument` is null, so the shared script already rejects them.
- Loaded Chromium extensions can read the DOM, like page scripts. Document it.

## Later
- OTP field.
- A Bitwarden or KeePassXC example adapter.
- `hyprmuxctl credential-providers` listing for debugging.
