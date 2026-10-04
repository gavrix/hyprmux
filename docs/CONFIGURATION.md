# Configuration

Hyprmux reads `~/.config/hyprmux/hyprmux.conf`, or the file named by
`$HYPRMUX_CONFIG`. On first launch, it creates the selected path with the full
default from [`config/hyprmux.conf`](../config/hyprmux.conf). The same default
is compiled into the app as a fallback when file creation or reading fails.
**Hyprmux → Open Config…** (⌘,) opens the generated file.

The file reloads when you save it, whether your editor writes in place or
replaces the file. ⇧⌘R or `hyprmuxctl reload` force a reload. Mistakes show in
a red bar at the top of the screen; the rest of the file still applies. The one
setting that needs a restart is `web:engine`.

Apps you install for the launcher live in `apps/` next to the config file. See
[Apps](APPS.md). Adapter manifests, which decide how apps that aren't Hyprmux
clients open in tiles, live in `adapters/`. See [Adapters](ADAPTERS.md).

## Syntax

The syntax follows Hyprland's `hyprland.conf` (hyprlang):

```ini
# comment ("##" is a literal "#")
$mod = SUPER                  # variable, used as $mod
general {                     # sections nest; keys become general:gaps_in
    gaps_in = 5
}
general:gaps_out = 14         # the flat form works too
source = ~/.config/hyprmux/binds.conf   # include another file
```

**Values:**

- **Numbers:** `5`, `0.7`.
- **Booleans:** `true`/`false`, `yes`/`no`, `on`/`off`, `1`/`0`.
- **Insets** (gaps): one value for all sides, two for vertical and horizontal,
  or four for top, right, bottom, left.
- **Colors:** `rgba(33ccffee)`, `rgba(51,204,255,0.9)`, `rgb(33ccff)`,
  `0xAARRGGBB`, or `##RRGGBB` (a single `#` starts a comment).
- **Gradients:** one or more colors plus an optional angle:
  `rgba(33ccffee) rgba(00ff99ee) 45deg`.

## Options

Defaults below are the values built into the code. The shipped default config
overrides a few of them (for example `gaps_out = 14`).

### `general`

| Option | Default | Meaning |
|---|---|---|
| `gaps_in` | 5 | Gap around each window where it meets another window (so 10 between two). |
| `gaps_out` | 20 | Gap between windows and the screen edges. |
| `border_size` | 2 | Border width, in points. |
| `col.active_border` | cyan→green 45° | Border of the focused window (gradient). |
| `col.inactive_border` | grey | Border of other windows. |
| `layout` | `dwindle` | The only layout so far. |

### `decoration`

| Option | Default | Meaning |
|---|---|---|
| `rounding` | 10 | Corner radius, in points. |
| `rounding_power` | 2 | Corner curve: 2 = circle, 4 = squircle, higher = squarer (1–10). |
| `active_opacity` | 1 | Opacity of the focused window's content. |
| `inactive_opacity` | 1 | Opacity of other windows' content (e.g. 0.7). |
| `dim_inactive` | false | Darken unfocused windows. |
| `dim_strength` | 0.5 | How much to darken them. |
| `dim_special` | 0.2 | Darkening behind an open scratchpad. |
| `blur:enabled` | false | Frosted-glass blur behind translucent windows. |
| `shadow:enabled` | true | Drop shadow outside each window. |
| `shadow:range` | 4 | Shadow size. |
| `shadow:color` | dark grey | Shadow color. |

Hyprland's blur tuning keys (`blur:size`, `blur:passes`, and similar) are
accepted and ignored.

### `animations`

```ini
animations {
    enabled = yes
    bezier = easeOutQuint, 0.23, 1, 0.32, 1
    animation = windows, 1, 4.79, easeOutQuint             # name, on/off, speed, curve
    animation = windowsIn, 1, 4.1, easeOutQuint, popin 87%  # optional style
    animation = workspaces, 1, 3.5, easeOutQuint, slide
}
```

Speed is in tenths of a second: `4.79` means 479 ms. Built-in curves are
`default` and `linear`. An animation you don't set inherits from its parent:

```
global
├── windows ── windowsIn, windowsOut, windowsMove
├── fade ── fadeIn, fadeOut, fadeSwitch, fadeShadow, fadeDim
├── border ── borderangle
├── workspaces ── workspacesIn, workspacesOut, specialWorkspace ── In, Out
├── fade ── fadeLayers ── fadeLayersIn, fadeLayersOut
└── layers ── layersIn, layersOut
```

**What each animation drives:**

- **windowsIn / windowsOut:** opening and closing windows.
- **windowsMove:** layout changes.
- **fadeSwitch:** the active/inactive opacity change on focus.
- **border:** border color changes.
- **workspaces:** switching workspaces.
- **specialWorkspace:** the scratchpad.
- **layersIn / layersOut:** Hyprmux's own UI (notifications, pickers) appearing and
  going away. **fadeLayersIn / fadeLayersOut** fade it at the same time.
- **layers:** a notification stack moving up or down when one comes or goes.

**Styles:**

- **windows:** `popin N%` or `slide`.
- **workspaces:** `slide`, `slidevert`, or `fade`.
- **layers:** `slide [top|bottom|left|right]`, `popin N%`, or `fade`. A plain
  `slide` uses the nearest edge. With no style set, notifications slide in
  from the side they sit on, and pickers pop in (`popin 90%`).

### `input`

| Option | Default | Meaning |
|---|---|---|
| `follow_mouse` | 1 | 1 = focus follows the pointer (only while Hyprmux is active), 0 = click to focus. |

### `app`

App tiles are macOS apps opened in Hyprmux, such as VS Code or Zed (see
[Apps](APPS.md)). Hyprmux's binds win in every tile, so tiles can always be
closed, moved, and resized from the keyboard. Apps get every chord Hyprmux
doesn't bind. When an app shortcut clashes with a bind, rebind it inside the app
(VS Code: `keybindings.json`; Zed: the keymap), or hand the chord to that one
app with its pass list:

```ini
app:com.microsoft.VSCode {
    pass = SUPER P, SUPER SHIFT P
}
```

The app id is the one `hyprmuxctl apps` shows. While that app's tile has the
keyboard, the listed chords go to the app; everywhere else, and inside a submap,
they stay binds.

### `dwindle`

| Option | Default | Meaning |
|---|---|---|
| `preserve_split` | false | Keep each split's direction instead of recomputing it from its shape. |
| `force_split` | 0 | Where a new window goes: 0 = toward the pointer, 1 = left/top, 2 = right/bottom. |
| `split_width_multiplier` | 1.0 | A split goes side by side when width × this > height. |
| `default_split_ratio` | 1.0 | 1.0 = even split (range 0.1–1.9). |

### `binds`

| Option | Default | Meaning |
|---|---|---|
| `workspace_back_and_forth` | false | Switching to the current workspace goes back to the previous one. |

### `group`

Groups hold several windows as tabs in one tile.

| Option | Default | Meaning |
|---|---|---|
| `auto_group` | true | Windows opened while a group is focused join it as tabs. |
| `border_size` | (general) | Border width for grouped windows. |
| `col.border_active` / `col.border_inactive` | orange / brown | Group border colors. |
| `groupbar:enabled` | true | Show the tab strip. |
| `groupbar:height` | 20 | Tab strip height. |
| `groupbar:font_size` | 11 | Tab title size. |
| `groupbar:col.active` / `col.inactive` | cyan / dark | Tab colors. |
| `groupbar:text_color` | white | Tab title color. |

### `misc`

| Option | Default | Meaning |
|---|---|---|
| `background_color` | transparent | Behind the windows. An alpha below 1 makes Hyprmux see-through; `rgba(00000000)` shows the desktop in the gaps. |
| `fullscreen_style` | `fill` | `fill`: full screen on the normal desktop, so the wallpaper stays visible. `native`: macOS full screen on its own Space. |
| `register_broker` | `true` | App tiles connect through `hyprmux-broker`, a small helper macOS runs for Hyprmux. `true`: Hyprmux registers it on launch, and macOS may ask you to allow Hyprmux in Login Items. `false`: Hyprmux leaves it alone, for people who load the broker themselves. Turning it off doesn't remove a registered helper; `hyprmuxctl broker unregister` does. |

### `web`

| Option | Default | Meaning |
|---|---|---|
| `engine` | `webkit` | `webkit` (light, no passkeys) or `chromium` (bundled CEF; passkeys from a phone or security key). Needs a restart. |
| `home` | DuckDuckGo | Page for `webnav home`. |
| `new_tab` | — | Page for a new empty web tile, like a browser's New Tab page. Unset: a built-in start page. A URL, including an extension page such as `chrome-extension://ID/index.html` (Chromium, with the extension in `chromium_extensions`). The address bar stays empty on it. |
| `search` | DuckDuckGo | Search URL for address-bar text that isn't a URL; `%s` is the query. |
| `open_terminal_links` | true | ⌘-click on a link in a terminal opens a web tile instead of your browser. Over a link, ⌘-click opens it even when `$mod` + click is bound to `movewindow`. |
| `address_bar` | true | Show the address bar, with back, forward, and reload buttons. |
| `chromium_extensions` | — | Comma-separated unpacked extension folders to load into Chromium. Extensions that need tabs (like 1Password) don't work in tiles. Loaded extensions can read page DOM values, including filled credentials, like page scripts. |
| `chromium_flags` | — | Space-separated Chromium switches. Credential fill is refused with `remote-debugging-port`, `remote-debugging-pipe`, or `devtools-protocol-log-file` because those switches can expose filled values. |

### `credentials`

| Option | Default | Meaning |
|---|---|---|
| `providers` | every usable provider, sorted by id | Comma-separated provider ids to query, in picker order. Only listed providers participate. Unknown or unusable ids are skipped and reported when providers load. |

```ini
credentials {
    providers = 1password, work-vault
}
```

#### Credential browser fill

`fillcredential [provider-id]` opens a native picker from the configured providers,
or only the named provider. An explicit provider id ignores `credentials:providers`.
Providers answer progressively, so one locked provider does not delay results from
another provider. It fills the focused field in WebKit and Chromium tiles, including
same-origin child frames. Cross-origin frames are not supported.

The bundled `1password` provider requires 1Password CLI version 2 at
`/opt/homebrew/bin/op` or `/usr/local/bin/op`, with desktop-app integration enabled.
Other password managers can supply out-of-process providers. See
[CREDENTIALS.md](CREDENTIALS.md) for provider manifests, trust checks, the protocol,
and security rules.

Only HTTPS pages are eligible, except HTTP loopback development sites. Focus a
visible, enabled, editable password or email input before running the dispatcher.
A text input also works when its autocomplete, id, or name identifies it as a
username, login, or email field. Hyprmux captures that exact input before opening
the picker. It validates fresh metadata and requires an exact saved-host match,
or an explicit `Fill anyway` choice. Navigation, origin changes, focus changes,
or element replacement cancel the fill. Filling dispatches bubbling `input` and
`change` events, but never submits the form.

#### Credential terminal fill

In a terminal tile, `fillcredential` types a password into a password prompt,
such as `sudo`, `ssh`, or `read -s`. Hyprmux uses Ghostty's prompt detection:
the terminal must have line input on and echo off. A plain shell prompt is refused,
so a secret never lands in scrollback or shell history.

The terminal must be focused when the dispatcher runs. Hyprmux records the
foreground program, and that same program must still be asking for a password
when Hyprmux types it. A terminal has no website to check, so picking the item
is the confirmation. Hyprmux types the password as keyboard input, without
bracketed paste, and never presses Return.

Programs that read a password in raw mode and draw their own masked prompt
are not detected and get refused.

### `ghostty`

Anything in a `ghostty { }` block goes to libghostty as Ghostty config, after
your normal `~/.config/ghostty/config`:

```ini
ghostty {
    window-padding-x = 12
    font-size = 14
    background = 1e1e2e      # no "#": that starts a comment here (or write ##1e1e2e)
}
```

### `hud`

Hyprmux's own UI: notifications and pickers. It takes its font, text colors, and
palette from your Ghostty config, and its border, rounding, shadow, and blur
from `general` and `decoration`, so a notification looks like a focused tile.

```ini
hud {
    font_family = JetBrains Mono
    notifications {
        position = top_right
        timeout = 5000
    }
}
```

| Option | Default | Meaning |
|---|---|---|
| `font_family` | Ghostty's `font-family` | Font for all HUD text. Falls back to the system monospaced font. |
| `font_size` | Ghostty's `font-size` | Text size in points. |
| `notifications:position` | `top_right` | `top_right`, `top_left`, `bottom_right`, `bottom_left`, `top`, `bottom`, or `center`. Inside the work area, `gaps_out` from its edges. |
| `notifications:timeout` | 5000 | Milliseconds on screen. 0 keeps them until clicked. Hovering keeps one open. |
| `notifications:max_visible` | 5 | More than this drops the oldest. |
| `notifications:width` | 380 | Width in points. |
| `picker:width` | 600 | Width of pickers in points. They open centered in the window. |
| `picker:max_rows` | 10 | Rows shown at once. Longer lists scroll. |
| `keycast` | false | Show each shortcut Hyprmux acts on at the bottom of the window, with what it did: **⌘↩** New terminal. Quick repeats count up (×3). Plain typing never shows. For screen sharing and recordings. |

**What shows up:**

- **Config errors:** one red notice that updates on every save and goes away
  once the config is clean.
- **Warnings:** such as "no booted simulator" or "no running Android emulator".
- **Terminal notifications:** a program can send one with OSC 9
  (`printf '\e]9;Build done\a'`) or OSC 777
  (`printf '\e]777;notify;Title;Body\a'`). Clicking it focuses that terminal.

Clicking any notification closes it. The same message posted again counts up
(`×3`) instead of stacking.

**Pickers** list things to choose from, such as workspaces and running devices. Typing filters
the list, fzf-style: letters match in order, and words separated by spaces match
anywhere. While a picker is open, binds are off and the keyboard belongs to it:

| Keys | Action |
|---|---|
| typing, ⌘V, ⌥⌫ | edit the filter |
| ↑ ↓, ⌃P ⌃N, ⇧Tab Tab | move the selection |
| Page Up, Page Down | move a page |
| Return | choose |
| Escape, ⌃C, ⌃G, click outside | cancel |

The mouse works too: hover selects a row, a click chooses it, and the wheel scrolls.

### `hyprmux`

| Option | Default | Meaning |
|---|---|---|
| `float_size` | 0.6 | Size of a window floated for the first time, as a fraction of the screen. |
| `confirm_quit` | true | ⌘Q quits only when pressed twice within two seconds; the first press shows "Press ⌘Q again to quit". Quitting from the Dock, logging out, and the `exit` dispatcher don't ask. |
| `bar_backdrop` | true | A frosted capsule behind the workspace pills, so they stay readable over any wallpaper. Liquid Glass on macOS 26; a vibrancy blur on older systems. |

### Workspaces

Workspaces are numbered, and ⌘1…9 always reach them by number. A workspace can
also have a name, shown after its number in the bar (`2 mail`).

- **Name the current one:** ⌘N (`picker, renameworkspace`) opens a prompt with
  the current name. An empty name clears it.
- **Go to one:** ⌘P (`picker, workspace`) lists workspaces with windows, a name,
  or focus. Type to filter by number or name. A number or name that isn't listed
  goes there; a new name makes a workspace with that name on the first free number.
- **Move the window to one:** ⇧⌘P (`picker, movetoworkspace`) works the same and
  also lists the scratchpads your binds use. `movetoworkspacesilent` stays behind.
- **Names in the config:** Hyprland workspace rules set default names:

```ini
workspace = 1, defaultName:main
workspace = 2, defaultName:mail
```

A name you set with ⌘N wins over the rule's until you clear it. Names stay when a
workspace empties. Other workspace-rule keys are accepted and ignored.

### Session restore

When Hyprmux quits, it saves the session, and the next launch brings it back:
workspaces and their names, the split layout, floating windows, groups, focus,
and what each tile showed. It also saves every 30 seconds and shortly after any
layout change, so a crash loses little. The file is
`~/Library/Application Support/Hyprmux/session.json` (the environment variable
`HYPRMUX_SESSION` moves it). The session from the launch before is kept next to
it as `session-previous.json`.

What comes back:

- **Terminals:** a new shell in the same directory. If a program on the
  `programs` list was running in the foreground, it starts again, typed into the
  shell, so the shell stays when it exits. Hyprmux prefers the command line you
  typed, which Ghostty's shell integration reports as the terminal title, over
  the process it became: `tool release` runs as `ruby …/tool release`,
  and wrappers often exec something else. Compound lines (`cd x && make`) don't
  match an entry; then the foreground process's own arguments are used.
- **Agent sessions:** an agent that reported its session (below) resumes with the
  command from `resume`.
- **Web tiles:** the page they were on.
- **Simulators:** the same device, if it's still booted. If not, the tile is
  skipped and a warning says so.
- **Android emulators:** the same stable AVD id, with its name as a fallback.
  The AVD must already be running. Otherwise, Hyprmux skips it and shows a warning.

Anything else comes back as an empty terminal or a start page. A restored launch
skips `exec-once` and `exec`, so startup terminals don't appear twice.

```ini
session {
    restore = true
    programs = nvim, vim, lazygit, htop, btop, less, man
    # programs = *          # any program…
    # deny = ssh, make      # …except these
    resume {
        pi = mywrapper pi --session {id}
        codex = codex resume {id}
    }
}
```

| Option | Default | Meaning |
|---|---|---|
| `restore` | true | Restore the last session on launch. |
| `programs` | `nvim, vim, lazygit, htop, btop, less, man` | Foreground programs that start again. `*` allows any. Only these re-run: a restart must not repeat a deploy. An entry can be several words: `tool release` allows that command and not `tool deploy`. |
| `deny` | — | Programs never re-run, even with `programs = *`. Entries work the same way. |
| `resume:KIND` | `pi`, `codex` | The command that resumes an agent session of that kind. `{id}` is the session id. |
| `start:KIND` | `pi`, `codex` | The command that starts a new session of that kind. Layouts use it. |

**Agent sessions.** An agent tells Hyprmux which session its terminal holds with
one line on the control socket (`hyprmuxctl resume '{…}'` works too):

```json
resume {"client": 12, "pid": 4711, "kind": "pi", "session": "01a0…", "cwd": "/src/app", "file": "/…/session.jsonl"}
```

`client` is the terminal's `HYPRMUX_CLIENT`, and `pid` is the agent's process.
The report counts only while that process runs in the terminal's foreground, and,
when `file` is given, while that file exists. So an agent you exited comes back as
a plain shell. For pi, `~/.pi/agent/extensions/hyprmux-session.ts` sends the
report on every session start (launch, `/new`, `/resume`, fork).

### Layouts

A layout is a workspace template: a saved arrangement of windows you can summon
again later. Layouts live in `~/.config/hyprmux/layouts/NAME.json`, in the same
format as the session file.

- **Save one:** arrange a workspace, then press ⇧⌘U (`picker, savelayout`) and
  give it a name. The workspace takes the name too.
- **Summon one:** press ⌘U (`picker, layout`) and choose it. If a workspace with
  that name already has windows, Hyprmux just goes there. Otherwise it builds
  the workspace on the empty workspace with that name, or the first free number.
  Summoning twice never opens a second copy.

What a layout keeps: the split tree, floating windows, groups, each terminal's
directory, programs from `session:programs`, web pages, simulators, and Android AVDs. An agent
is kept by kind only, so summoning starts a new session with `session:start:KIND`
instead of reopening the one it was saved from.

Layouts are easy to write by hand. A single tile is an object with a `kind`; a
split has `split` (`h` side by side, `v` stacked), an optional `ratio` (1 is
even), and two `children`; `tabs` makes a group:

```json
{
  "workspaces": [{
    "name": "dev",
    "tiled": {"split": "h", "ratio": 1.2, "children": [
      {"kind": "terminal", "cwd": "~/src/app", "agent": {"kind": "pi"}},
      {"split": "v", "children": [
        {"kind": "terminal", "cwd": "~/src/app", "command": "nvim ."},
        {"tabs": [{"kind": "web", "url": "http://localhost:3000"},
                  {"kind": "terminal", "cwd": "~/src/app", "command": "npm run dev"}]}
      ]}
    ]}
  }]
}
```

An Android tile uses `{"kind":"android","avd":"stable-id","avdName":"Display name"}`.
Hyprmux only restores it when that AVD is already running.

A `command` in a layout you wrote runs as written (the `programs` list only
applies to what Hyprmux records). A file can hold several workspaces, each with
its own `name`; summoning it opens all of them and shows the first.

### Startup programs

```ini
exec-once = htop     # run in a new terminal at startup
exec = btop          # also run on every config reload
```

Without any `exec-once`, Hyprmux opens one terminal at startup. A
[terminal hook](HOOKS.md#hooks) on `launch` or `firstlaunch` replaces it too.

## Binds

```ini
bind  = MODS, key, dispatcher, args
binde = $mod CTRL, L, resizeactive, 40 0      # e = repeats while held
bindm = $mod, mouse:272, movewindow           # m = mouse drag (272 left, 273 right)
bindn = ...                                   # n = the key also reaches the app
bindd = $mod, Return, Open a shell, exec,     # d = with a description (the keycast shows it)
```

- **Modifiers:** `SUPER` (also `CMD`) is ⌘. The others are `SHIFT`, `CTRL`, and
  `ALT` (also `OPT`). Combine them with spaces or `_`. An empty field means no
  modifier.
- **Keys:** physical positions named like on a US keyboard, so binds keep
  working with other layouts: `A`–`Z`, `0`–`9`, `Return`, `space`, `Tab`,
  `escape`, `left`/`right`/`up`/`down`, `grave`, `minus`, `equal`,
  `bracketleft`, `bracketright`, `comma`, `period`, `slash`, `F1`–`F12`, or
  `code:NN` for a raw macOS key code.
- **Precedence:** keys that no bind claims go to the focused window, so ⌘C and
  ⌘V still copy and paste in terminals.

**Submaps** are modes with their own binds:

```ini
bind = $mod, R, submap, resize
submap = resize
binde = , L, resizeactive, 30 0
bind = , escape, submap, reset
submap = reset
```

## Dispatchers

These names work in `bind` lines and with `hyprmuxctl dispatch`.

| Dispatcher | Arguments | Action |
|---|---|---|
| `exec` | [command] | New terminal, optionally running a command. |
| `web` / `openurl` | [url or search] | New web tile. Empty: a start page with the address bar focused. |
| `webnav` | `back` `forward` `reload` `stop` `home` `focusurl` `inspect` | Navigation in the focused web tile. |
| `fillcredential` | [provider id] | Choose a credential and fill the exact focused field in a WebKit or Chromium tile, or type a password into a terminal's password prompt. Empty queries the configured providers. |
| `sim` / `simulator` | [udid, name, or `booted`] | Show an iOS Simulator. Empty: attach the only running iOS or Android device, or show a combined picker. |
| `android` / `avd` | [AVD id or name] | Attach a running Android AVD. Empty: the sole running AVD, or a picker when several are running. Never boots an AVD. |
| `launch` | [name or id, then arguments] | Open an [app](APPS.md) in a new tile. The text names an app whole, or its first word does and the rest are arguments. Empty: the launcher. |
| `simbutton` | `home` `lock` | Press a simulator hardware button. |
| `killactive` | | Close the focused window. |
| `movefocus` | `l` `r` `u` `d` | Focus the neighbor in that direction. |
| `movewindow` | `l` `r` `u` `d` | Move the window in the layout (or to the screen edge if floating). |
| `swapwindow` | `l` `r` `u` `d` | Swap with the neighbor. |
| `resizeactive` | `dx dy` | Grow or shrink the focused window. |
| `moveactive` | `dx dy` | Move a floating window. |
| `workspace` | `N`, `+1`/`-1`, `e+1`/`e-1`, `previous`, `empty`, `special[:name]`, `name:NAME` | Switch workspace. `e±1` skips empty workspaces. `name:` finds the workspace with that name, or names the first free number. |
| `movetoworkspace` / `movetoworkspacesilent` | same | Move the focused window there (and follow it, or stay). |
| `renameworkspace` | `N [name]` | Name workspace N. No name clears it. |
| `picker` | `workspace`, `movetoworkspace`, `movetoworkspacesilent`, `renameworkspace`, `layout`, `savelayout`, `apps` | Hyprmux's own pickers: go to a workspace, move the window to one, name the current one, summon or save a layout, or open an app (the launcher). See [Workspaces](#workspaces), [Layouts](#layouts), and [Apps](APPS.md). |
| `togglespecialworkspace` | [name] | Show or hide a scratchpad. |
| `togglefloating` | | Float or re-tile. A first float centers the window; re-tiling returns it to its old slot. |
| `fullscreen` | `0` or `1` | 0 = cover the screen, 1 = maximize within gaps. |
| `monitorfullscreen` | | Toggle the whole Hyprmux window full screen (see `misc:fullscreen_style`). |
| `togglesplit` / `swapsplit` | | Flip or swap the split holding the focused window. |
| `splitratio` | `±x` or `exact x` | Change that split's ratio. |
| `cyclenext` | [`prev`] | Focus the next window on the workspace. |
| `focuscurrentorlast` | | Focus the previously focused window. |
| `centerwindow` | | Center a floating window. |
| `togglegroup` | | Make the focused window a group, or dissolve its group. |
| `changegroupactive` | `f`, `b`, or `N` | Switch tabs. |
| `moveintogroup` | `l` `r` `u` `d` | Move the window into the neighboring group (makes one if needed). |
| `moveoutofgroup` | | Take the window out of its group. |
| `movegroupwindow` | `f` or `b` | Reorder the active tab. |
| `submap` | name or `reset` | Enter or leave a submap. |
| `reload` | | Reload the config. |
| `exit` | | Quit Hyprmux. |

A bind applies window dispatchers to the focused window. They are `killactive`,
`movefocus`, `movewindow`, `swapwindow`, `resizeactive`, `moveactive`,
`movetoworkspace`, `movetoworkspacesilent`, `togglefloating`, `fullscreen`,
`togglesplit`, `swapsplit`, `splitratio`, `cyclenext`, `centerwindow`, `webnav`,
`fillcredential`, `simbutton`, and the group dispatchers.
`hyprmuxctl dispatch --surface N` applies them to another window without focusing it.
Only dispatchers about focus (`movefocus`, `cyclenext`) or following a window
(`movetoworkspace`) move focus. A layout dispatcher on a hidden group tab acts on its
group's slot. `moveintogroup` on an unfocused window adds it as a background tab.

## IPC: `hyprmuxctl`

Shells inside Hyprmux get `HYPRMUX_SOCKET`, `HYPRMUX_SURFACE_ID`,
`HYPRMUX_CLIENT`, and `HYPRMUX_PID` in their environment. The two surface
variables identify the terminal; `HYPRMUX_CLIENT` remains for compatibility.
The PID identifies its Hyprmux app instance.

The distributed app ships `hyprmuxctl` and adds its directory to terminal `PATH`.
`HYPRMUXCTL_PATH` names that exact client, and `HYPRMUX_SKILL_PATH` names the bundled
agent skill. `hyprmuxctl` talks to the instance socket, which defaults to
`/tmp/hyprmux-<uid>/hyprmux.sock`. Development builds can build the client with
`swift build --product hyprmuxctl`.

Commands that accept `--surface` take either a number or `surface:N`. Without
that option, they target `HYPRMUX_SURFACE_ID`, then `HYPRMUX_CLIENT`, then the
focused surface. `dispatch` is the exception: it acts on the focused window unless
`--surface` is given. Explicit targets can be hidden group tabs or live on another
workspace. Reading, sending input, opening, and moving never focus a surface unless
the command has `--focus`.

Surface IDs increase across all surface kinds and are not reused during one app run.
They do not encode workspace membership and can change after session restoration.
Right-click a surface and choose **Copy Surface ID** to copy its `surface:N` reference.
See [Terminal automation](AUTOMATION.md) for workflows, limits, and agent skill installation.

| Command | Reply |
|---|---|
| `skill install\|status\|path\|source\|uninstall [--force]` | Manages the bundled agent skill under `~/.agents/skills`. This command is local and needs no socket. |
| `dispatch [--surface ID] <dispatcher> [args]` | Runs a dispatcher. With `--surface`, a window dispatcher acts on that surface instead of the focused one; other dispatchers reject it. |
| `new-surface [--type terminal\|web\|sim\|android] [--workspace WS] [--focus] [--floating] [--cwd DIR] [--input TEXT] [ARG...]` | Opens a surface and replies with its JSON entry. `WS` uses workspace syntax (`3`, `name:NAME`, `special:NAME`, `empty`). ARG is a terminal command (default: the shell), a URL, or a device. `--input` types into the new shell. |
| `close-surface [--surface ID]` | Closes a surface, like `killactive`. |
| `focus-surface [--surface ID]` | Focuses a surface, switching to its workspace and showing a hidden tab. |
| `move-surface [--surface ID] --workspace WS [--focus]` | Moves a surface and its group to a workspace, and replies with its JSON entry. `--focus` follows it. |
| `clients`, `surfaces` | JSON for every surface: id, `surface:N` ref, capabilities, kind, workspace, frame, focus, group, URL or pwd. |
| `identify [--surface ID]` | JSON for the caller, explicit target, or focused surface. |
| `read-screen [--surface ID] [--scrollback] [--lines N] [--json]` | Reads rendered terminal text. `--lines` implies scrollback. |
| `read-selection [--surface ID] [--json]` | Reads the terminal's most recent mouse selection without using the clipboard. |
| `send [--surface ID] TEXT` | Types text into a terminal. Reads stdin when text is omitted; arguments decode `\n`, `\t`, and `\\`. |
| `send-key [--surface ID] KEY` | Sends a terminal key such as `ctrl+c`, `enter`, `tab`, or `escape`. |
| `workspaces`, `activewindow`, `version` | JSON or text. |
| `events` | Keeps the connection open and streams one `NAME>>DATA` line per event, Hyprland's `socket2` format. See [Events and hooks](HOOKS.md). |
| `reload` | Reloads the config. |
| `apps [list\|refresh] [--json]` | The [apps](APPS.md) Hyprmux can open: id, name, kind, source, adapter, and target, plus load errors and both folders. `refresh` regenerates the generated apps and replies when done. |
| `apps add NAME PATH [ARGS...]` | Writes an installed `.hmapp` for an `.app` (checked like a generated one) or an executable, and replies with it. |
| `launch [--focus] NAME\|ID [ARGS...]` | Opens an app in a new tile and replies with its JSON entry, like `new-surface`. |
| `adapters [list\|match APP\|reload] [--json]` | The adapter registry: loaded adapters, manifest errors, and launched instances. `match` shows which adapter would lift an `.app` or bundle id, and runs its probe. See [Adapters](ADAPTERS.md). |
| `broker [status\|register\|unregister] [--json]` | The helper app tiles connect through. `status`: whether macOS runs this copy's agent or waits for approval, what Hyprmux did on launch, whether the lookup service answers, which program launchd runs and who loaded it, and this instance's registration. `register` and `unregister` change the agent with macOS, for testing and support. See [Client protocol](CLIENT_PROTOCOL.md#3-transport). |
| `sendtext <text>` | Legacy command that types into the focused terminal (`\n` = Enter). |
| `sendkey <MODS>, <key>` | Legacy test command that injects a key through the normal application path. |
| `sendmouse down\|drag\|up\|move <MODS>, <button>, <x y>` | Injects one mouse event (holds, hand-timed gestures). Buttons: 272 left, 273 right, 274 middle. |
| `senddrag <MODS>, <button>, <x1 y1>, <x2 y2>` | Injects a paced drag (about 16 ms per step). |
| `snapshot [--surface ID] FILE.png` | Writes an app tile's current frame to a PNG. |
| `sendscroll <MODS>, <lines>, <x y>` | Injects a notched mouse-wheel scroll. Positive lines scroll up. |
| `hittest <x y>` | Which views a click at that point reaches. |
| `sendmenu <title>` | Performs a menu bar item by title, as a click would (`sendmenu Open App...`). Case doesn't matter, and `...` matches `…`. |
| `debug` | Focus internals: app active, key window, first responder, and which window holds the keyboard. |
| `resume {json}` | An agent reports how to bring its terminal back. See [Session restore](#session-restore). |
| `caption [Title \| subtitle]` | A caption panel at the top of the window, for demo recordings. No text hides it. |

Coordinates are in the Hyprmux window's space, from the top-left.
