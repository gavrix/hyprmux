# Credential providers

Hyprmux fills focused browser fields and terminal password prompts through out-of-process credential providers.
A provider is a JSON manifest and an executable that speaks protocol version 1.
Hyprmux owns target capture, origin and prompt checks, host confirmation, fresh metadata validation, and filling.
Providers only list items, return metadata, and reveal one requested field.

The bundled `1password` provider uses the 1Password `op` CLI.
Hyprmux core and the application contain no password-manager-specific code.

## Use

Focus a visible, editable username, email, or password field in a WebKit or Chromium tile.
Or focus a terminal that shows a password prompt.
Then run the dispatcher:

```ini
bind = SUPER, backslash, fillcredential
# Restrict the request to one provider:
bind = SUPER SHIFT, backslash, fillcredential, 1password
```

The 1Password app's default Autofill shortcut is also ⌘\\.
It is a global hotkey, so Hyprmux never sees the key while it is set.
Clear or change it in 1Password Settings > General, or bind another key.

Without an argument, `fillcredential` queries the providers selected by
`credentials:providers`. When that option is unset, it uses every usable provider,
sorted by id. Providers run in parallel and appear in configured order as each one
answers, so a locked provider does not delay another provider's results. An explicit
provider id ignores the configured list. In a multi-provider request, an unavailable
installation stays quiet when another provider answers. Locked and unauthorized
providers are always reported. A named provider always reports its failure.

Hyprmux refuses Chromium fills when `web:chromium_flags` contains
`remote-debugging-port`, `remote-debugging-pipe`, or `devtools-protocol-log-file`.
The first two can expose filled DOM values to another local process.
The last can write the DevTools messages carrying those values to disk.
Loaded Chromium extensions can read filled DOM values, just like scripts from the page.

Hyprmux permits HTTPS origins and HTTP loopback development origins.
It only accepts an exact normalized host match automatically.
A missing or different saved host requires an explicit **Fill anyway** confirmation.
The page, origin, focused element, element token, and field type are checked again before filling.
Hyprmux shows no interactive UI after it reveals a field. It only posts a non-secret fill result notice.

### Terminals

A terminal has no origin, so Hyprmux checks the prompt instead.
Ghostty reports a password prompt when the terminal has canonical (line) input on and echo off.
Hyprmux refuses the request when the terminal is not focused or shows no password prompt.
It records the foreground process group, and only asks for the `password` field.
There is no saved-host check: choosing the item is the confirmation.

Before typing, Hyprmux checks again. The terminal must be focused, the same process group must be in
the foreground, and the prompt must still have echo off. Ghostty only refreshes the prompt state while
the terminal is focused, and the picker takes focus. So Hyprmux waits until the terminal has been focused
for 0.3 seconds, longer than Ghostty's 200 ms poll, before it checks.
The value is typed as keyboard input, without bracketed paste, and Return is never pressed.

## Locations and overrides

Hyprmux scans `*.json` files in this order:

1. `Hyprmux.app/Contents/Resources/credential-providers/`
2. `credential-providers/` next to the config file, normally `~/.config/hyprmux/credential-providers/`

A user manifest replaces a built-in manifest with the same `id`.
An id-only disabled manifest turns a built-in provider off:

```json
{"id":"1password","disabled":true}
```

Hyprmux rescans at launch and on config reload.

Provider selection and order are optional:

```ini
credentials {
    providers = 1password, work-vault
}
```

When set, only listed providers participate in an unqualified `fillcredential`.
Unknown or unusable ids are skipped and reported after each provider scan.

## Manifest

```json
{
  "id": "example",
  "name": "Example Vault",
  "description": "Logins from Example Vault.",
  "exec": "./example-provider.sh",
  "args": [],
  "timeout": 300,
  "disabled": false
}
```

| Key | Meaning |
|---|---|
| `id` | Required. Starts with a letter or digit and uses ASCII letters, digits, `.`, `_`, or `-`. |
| `name` | Required for enabled providers. Shown in notices and multi-provider picker rows. |
| `description` | Optional description. |
| `exec` | Required. Absolute, relative to the manifest when it contains `/`, or a bare name. |
| `args` | Optional arguments. They must never contain secrets. Default `[]`. |
| `timeout` | Seconds for each request. Default `300`. |
| `disabled` | Default `false`. An id-only disabled override needs no other keys. |

Unknown keys are errors.
A bare executable name resolves in `HYPRMUX_CREDENTIAL_BIN`, then the app bundle's `Contents/MacOS`, then the manifest directory.
`HYPRMUX_CREDENTIAL_BIN` is colon-separated and intended for development builds.

## Trust checks

A provider is trusted code that handles secrets.
Hyprmux resolves symlinks before checking provider files.
User manifests, the user provider directory, and their parent directories must belong to the current user or root.
They must not be group- or world-writable.
The same rules cover each resolved executable and its parent directory.
Executables inside the resolved application bundle are exempt.
Every executable outside that bundle is checked, including built-in manifests resolved through `HYPRMUX_CREDENTIAL_BIN`.
Hyprmux repeats the executable check immediately before each request.

## Protocol version 1

Hyprmux starts one fresh process per request.
It writes one JSON object to standard input and closes the pipe.
The provider writes one JSON object to standard output and exits.
Hyprmux sets `HYPRMUX_CREDENTIAL_PROTOCOL=1` and otherwise inherits its environment.
It passes no secret in arguments or environment variables.

### Requests

```json
{"protocol":1,"op":"list","context":{"kind":"web","origin":"https://github.com","host":"github.com","field":"password"}}
{"protocol":1,"op":"list","context":{"kind":"terminal","field":"password","process":"sudo","title":"~/src"}}
{"protocol":1,"op":"metadata","id":"ITEM_ID"}
{"protocol":1,"op":"reveal","id":"ITEM_ID","field":"password"}
```

`field` is `username` or `password`.
The list context `kind` is `web` or `terminal`. A missing `kind` means `web`.
A web context has `origin` and `host`.
A terminal context has optional `process` and `title` hints, each at most 256 characters.
`process` is the foreground program name. `title` is the terminal title, which may contain any text.
The list context is a ranking hint only.
Hyprmux still enforces every security decision.

### Responses

List returns non-secret summaries:

```json
{"items":[{"id":"ITEM_ID","title":"GitHub","account":"me@example.com","websites":["https://github.com/login"],"container":"Personal","containerLabel":"vault"}]}
```

Metadata returns one freshly fetched non-secret summary:

```json
{"item":{"id":"ITEM_ID","title":"GitHub","websites":["https://github.com"]}}
```

Reveal returns exactly one requested value:

```json
{"value":"the secret"}
```

A safe provider failure is a protocol error:

```json
{"error":{"code":"locked","message":"Unlock the password manager and try again."}}
```

Valid codes are `notInstalled`, `locked`, `unauthorized`, `notFound`, `unsupported`, `timeout`, and `failed`.
Messages appear to the user and must not contain secrets.
A nonzero exit without a valid error object becomes `failed`.

Item `id` values must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`.
Hyprmux drops malformed list items and rejects malformed metadata.
It caps standard output at 16 MiB and standard error at 1 MiB.
It terminates a timed-out provider, then sends `SIGKILL` if needed.
Providers must exit promptly on `SIGTERM` and stop any child processes they started.
Hyprmux never logs or displays provider standard error.

## Safe shell provider example

This example stores non-secret metadata in `items.json` and delegates secret lookup to `vault-cli`.
It uses `jq` to parse and build JSON.
Replace the absolute executable paths for your installation.

```sh
#!/bin/sh
set -eu
PATH=/usr/bin:/bin
export PATH

request=$(/usr/bin/jq -c .)
op=$(printf '%s' "$request" | /usr/bin/jq -r '.op // empty')

case "$op" in
  list)
    /bin/cat /Users/me/.config/example/items.json \
      | /usr/bin/jq '{items: [.[] | {id, title, account, websites, container, containerLabel}]}'
    ;;
  metadata)
    id=$(printf '%s' "$request" | /usr/bin/jq -er '.id | select(test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))')
    /bin/cat /Users/me/.config/example/items.json \
      | /usr/bin/jq --arg id "$id" '{item: (.[] | select(.id == $id) | {id, title, account, websites, container, containerLabel})}'
    ;;
  reveal)
    id=$(printf '%s' "$request" | /usr/bin/jq -er '.id | select(test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))')
    field=$(printf '%s' "$request" | /usr/bin/jq -er '.field | select(. == "username" or . == "password")')
    /usr/local/bin/vault-cli read --id "$id" --field "$field" \
      | /usr/bin/jq -Rs '{value: rtrimstr("\n")}'
    ;;
  *)
    /usr/bin/jq -n '{error:{code:"unsupported",message:"Unsupported credential operation."}}'
    ;;
esac
```

### Common mistakes

- Use `printf '%s'`, not `echo`, for data that may contain backslashes or options.
- Never pass secrets through `sh -c`.
- Never enable `set -x` or another command tracer.
- Never write secrets to temporary files.

Follow these rules for every provider:

- Read requests from standard input.
- Return responses through standard output.
- Never put secrets in arguments, environment variables, logs, errors, or temporary files.
- Build JSON with `jq`; never interpolate a secret into JSON text.
- Pipe a secret directly from its source into `jq`.
- Set an absolute, minimal `PATH`, and use absolute executable paths.
- Validate item IDs before passing them to another command.
- Keep list and metadata responses free of field values.
- Emit only the requested field from reveal.
- Treat standard error as private diagnostics, not a user message.
