# Configuration

Hypermux reads `~/.config/hypermux/hypermux.conf`, or the file named by
`$HYPERMUX_CONFIG`. If neither exists, it uses the built-in default, which is
[`config/hypermux.conf`](../config/hypermux.conf) compiled into the app.
**Hypermux → Open Config…** (⌘,) writes that default to your config path the
first time and opens it.

The file reloads when you save it, whether your editor writes in place or
replaces the file. ⇧⌘R or `hypermuxctl reload` force a reload. Mistakes show in
a red bar at the top of the screen; the rest of the file still applies. The one
setting that needs a restart is `web:engine`.

## Syntax

The syntax follows Hyprland's `hyprland.conf` (hyprlang):

```ini
# comment ("##" is a literal "#")
$mod = SUPER                  # variable, used as $mod
general {                     # sections nest; keys become general:gaps_in
    gaps_in = 5
}
general:gaps_out = 14         # the flat form works too
source = ~/.config/hypermux/binds.conf   # include another file
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
- **layersIn / layersOut:** Hypermux's own UI (notifications, pickers) appearing and
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
| `follow_mouse` | 1 | 1 = focus follows the pointer (only while Hypermux is active), 0 = click to focus. |

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
| `background_color` | near black | Behind the windows. An alpha below 1 makes Hypermux see-through; `rgba(00000000)` shows the desktop in the gaps. |
| `fullscreen_style` | `fill` | `fill`: full screen on the normal desktop, so the wallpaper stays visible. `native`: macOS full screen on its own Space. |

### `web`

| Option | Default | Meaning |
|---|---|---|
| `engine` | `webkit` | `webkit` (light, no passkeys) or `chromium` (bundled CEF; passkeys from a phone or security key). Needs a restart. |
| `home` | DuckDuckGo | Page for `webnav home`. |
| `search` | DuckDuckGo | Search URL for address-bar text that isn't a URL; `%s` is the query. |
| `open_terminal_links` | true | ⌘-click on a link in a terminal opens a web tile instead of your browser. |
| `address_bar` | true | Show the address bar. |
| `chromium_extensions` | — | Comma-separated unpacked extension folders to load into Chromium. Extensions that need tabs (like 1Password) don't work in tiles. |
| `chromium_flags` | — | Space-separated Chromium switches, e.g. `remote-debugging-port=9333`. |

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

Hypermux's own UI: notifications and pickers. It takes its font, text colors, and
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

**What shows up:**

- **Config errors:** one red notice that updates on every save and goes away
  once the config is clean.
- **Warnings:** such as "no booted simulator".
- **Terminal notifications:** a program can send one with OSC 9
  (`printf '\e]9;Build done\a'`) or OSC 777
  (`printf '\e]777;notify;Title;Body\a'`). Clicking it focuses that terminal.

Clicking any notification closes it. The same message posted again counts up
(`×3`) instead of stacking.

**Pickers** list things to choose from, such as booted simulators. Typing filters
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

### `hypermux`

| Option | Default | Meaning |
|---|---|---|
| `float_size` | 0.6 | Size of a window floated for the first time, as a fraction of the screen. |

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

When Hypermux quits, it saves the session, and the next launch brings it back:
workspaces and their names, the split layout, floating windows, groups, focus,
and what each tile showed. It also saves every 30 seconds and shortly after any
layout change, so a crash loses little. The file is
`~/Library/Application Support/Hypermux/session.json` (the environment variable
`HYPERMUX_SESSION` moves it). The session from the launch before is kept next to
it as `session-previous.json`.

What comes back:

- **Terminals:** a new shell in the same directory. If a program on the
  `programs` list was running in the foreground, it starts again with the same
  arguments, typed into the shell, so the shell stays when it exits.
- **Agent sessions:** an agent that reported its session (below) resumes with the
  command from `resume`.
- **Web tiles:** the page they were on.
- **Simulators:** the same device, if it's still booted. If not, the tile is
  skipped and a warning says so.

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
| `programs` | `nvim, vim, lazygit, htop, btop, less, man` | Foreground programs that start again. `*` allows any. Only these re-run: a restart must not repeat a deploy. |
| `deny` | — | Programs never re-run, even with `programs = *`. |
| `resume:KIND` | `pi`, `codex` | The command that resumes an agent session of that kind. `{id}` is the session id. |
| `start:KIND` | `pi`, `codex` | The command that starts a new session of that kind. Layouts use it. |

**Agent sessions.** An agent tells Hypermux which session its terminal holds with
one line on the control socket (`hypermuxctl resume '{…}'` works too):

```json
resume {"client": 12, "pid": 4711, "kind": "pi", "session": "01a0…", "cwd": "/src/app", "file": "/…/session.jsonl"}
```

`client` is the terminal's `HYPERMUX_CLIENT`, and `pid` is the agent's process.
The report counts only while that process runs in the terminal's foreground, and,
when `file` is given, while that file exists. So an agent you exited comes back as
a plain shell. For pi, `~/.pi/agent/extensions/hypermux-session.ts` sends the
report on every session start (launch, `/new`, `/resume`, fork).

### Layouts

A layout is a workspace template: a saved arrangement of windows you can summon
again later. Layouts live in `~/.config/hypermux/layouts/NAME.json`, in the same
format as the session file.

- **Save one:** arrange a workspace, then press ⇧⌘U (`picker, savelayout`) and
  give it a name. The workspace takes the name too.
- **Summon one:** press ⌘U (`picker, layout`) and choose it. If a workspace with
  that name already has windows, Hypermux just goes there. Otherwise it builds
  the workspace on the empty workspace with that name, or the first free number.
  Summoning twice never opens a second copy.

What a layout keeps: the split tree, floating windows, groups, each terminal's
directory, programs from `session:programs`, web pages, and simulators. An agent
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

A `command` in a layout you wrote runs as written (the `programs` list only
applies to what Hypermux records). A file can hold several workspaces, each with
its own `name`; summoning it opens all of them and shows the first.

### Startup programs

```ini
exec-once = htop     # run in a new terminal at startup
exec = btop          # also run on every config reload
```

Without any `exec-once`, Hypermux opens one terminal at startup.

## Binds

```ini
bind  = MODS, key, dispatcher, args
binde = $mod CTRL, L, resizeactive, 40 0      # e = repeats while held
bindm = $mod, mouse:272, movewindow           # m = mouse drag (272 left, 273 right)
bindn = ...                                   # n = the key also reaches the app
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

These names work in `bind` lines and with `hypermuxctl dispatch`.

| Dispatcher | Arguments | Action |
|---|---|---|
| `exec` | [command] | New terminal, optionally running a command. |
| `web` / `openurl` | [url or search] | New web tile. Empty: a start page with the address bar focused. |
| `webnav` | `back` `forward` `reload` `stop` `home` `focusurl` `inspect` | Navigation in the focused web tile. |
| `sim` / `simulator` | [udid, name, or `booted`] | Show an iOS Simulator in a tile. Empty: the only booted one, or a picker when several are booted. |
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
| `picker` | `workspace`, `movetoworkspace`, `movetoworkspacesilent`, `renameworkspace`, `layout`, `savelayout` | Hypermux's own pickers: go to a workspace, move the window to one, name the current one, or summon or save a layout. See [Workspaces](#workspaces) and [Layouts](#layouts). |
| `togglespecialworkspace` | [name] | Show or hide a scratchpad. |
| `togglefloating` | | Float or re-tile. A first float centers the window; re-tiling returns it to its old slot. |
| `fullscreen` | `0` or `1` | 0 = cover the screen, 1 = maximize within gaps. |
| `monitorfullscreen` | | Toggle the whole Hypermux window full screen (see `misc:fullscreen_style`). |
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
| `exit` | | Quit Hypermux. |

## IPC: `hypermuxctl`

Shells inside Hypermux get `HYPERMUX_SOCKET` and `HYPERMUX_CLIENT` in their
environment. `hypermuxctl` talks to that socket (default
`/tmp/hypermux-<uid>/hypermux.sock`). Build it with
`swift build --product hypermuxctl`.

| Command | Reply |
|---|---|
| `dispatch <dispatcher> [args]` | Runs a dispatcher. |
| `clients` | JSON for every window: id, kind, workspace, frame, focus, floating, group, URL or pwd. |
| `workspaces`, `activewindow`, `version` | JSON or text. |
| `reload` | Reloads the config. |
| `sendtext <text>` | Types text into the focused terminal (`\n` = Enter). |
| `sendkey <MODS>, <key>` | Injects a key press through the normal key path. |
| `sendmouse down\|drag\|up\|move <MODS>, <button>, <x y>` | Injects one mouse event (holds, hand-timed gestures). |
| `senddrag <MODS>, <button>, <x1 y1>, <x2 y2>` | Injects a paced drag (about 16 ms per step). |
| `hittest <x y>` | Which views a click at that point reaches. |
| `debug` | Focus internals: app active, key window, first responder, and which window holds the keyboard. |
| `resume {json}` | An agent reports how to bring its terminal back. See [Session restore](#session-restore). |

Coordinates are in the Hypermux window's space, from the top-left.
