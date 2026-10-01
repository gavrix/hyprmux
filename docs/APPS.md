# Apps

Hyprmux opens apps in tiles from inside Hyprmux. Press ⌘D (`picker, apps`) or
choose Hyprmux → Open App… for the launcher, type to filter, and press Enter.
The app opens in a new tile on the current workspace. Apps you start outside Hyprmux stay ordinary macOS apps.

The launcher lists only apps that can open. Everything it lists is a `.hmapp`: a
folder bundle that only Hyprmux understands. It isn't a macOS app, so Spotlight,
Launchpad, and the Dock never list it.

## The first launch

Apps in tiles reach Hyprmux through `hyprmux-broker`, a small helper that
macOS runs in the background. Hyprmux sets it up each time it starts, so
there's nothing to install. The first time, macOS shows a notification that
Hyprmux can run in the background. You can manage that in System Settings →
General → Login Items & Extensions.

If you turned Hyprmux off there, Hyprmux shows a notice: "Allow Hyprmux in
Login Items to open apps in tiles." Click it, turn Hyprmux on under Allow in
the Background, and switch back to Hyprmux. App tiles work from then on.

`hyprmuxctl broker status` says whether the helper runs. If you load the
broker yourself, set `misc:register_broker = false`
([CONFIGURATION.md](CONFIGURATION.md)).

## What a `.hmapp` is

```
Visual Studio Code.hmapp/
  Info.json
  icon.png          optional, 256 px
  …                 optional payload (an executable, say)
```

`Info.json`, format 1:

```json
{
  "format": 1,
  "id": "com.microsoft.VSCode",
  "name": "Visual Studio Code",
  "kind": "adapter",
  "adapter": "electron.vscode",
  "app": "/Applications/Visual Studio Code.app",
  "exec": "hyprmux-electron-bridge",
  "args": ["--adapter", "vscode", "{app}", "{args}"]
}
```

| Key | Required | Meaning |
|---|---|---|
| `format` | yes | `1`. |
| `id` | yes | Unique. Letters, digits, `.`, `_`, `-`. Generated apps use the target's bundle id. |
| `name` | yes | What the launcher shows. |
| `kind` | yes | `native` (the target speaks the [client protocol](CLIENT_PROTOCOL.md)) or `adapter` (an [adapter](ADAPTERS.md) lifts it). Informational: `exec` and `app` decide how it opens. |
| `adapter` | when `kind` is `adapter` | The adapter's id. `hyprmuxctl adapters` lists the processes it started. |
| `app` | no | Absolute path of the `.app` it opens or lifts. Gives the launcher its icon when there's no `icon.png`. |
| `version` | no | The target's version when Hyprmux generated it. |
| `exec` | no | The executable. An absolute path; a path relative to the `.hmapp` (it contains `/`, like `bin/zed`); or a bare name, looked up in the adapter bin directories, then in the `.hmapp`. |
| `args` | no | Default `["{args}"]`. `{app}` is `app`, `{bundle}` is the `.hmapp`'s path, and an `{args}` element is replaced by the arguments given at launch. |
| `generatedBy` | no | `"hyprmux"` on generated apps. Hyprmux only rewrites or deletes bundles that have it. |

With `exec`, Hyprmux runs the executable. Without it, Hyprmux opens the `.app`
named by `app`. One of the two is required. Unknown keys are errors, so a typo
can't change what runs.

## Where they live

| Folder | Source | Owner |
|---|---|---|
| `~/Library/Application Support/Hyprmux/Apps/` | Generated | Hyprmux. It regenerates them. |
| `apps/` next to the config file, normally `~/.config/hyprmux/apps/` | Installed | You, or whoever gave you the app. Hyprmux never changes them, except through `hyprmuxctl apps add`. |

An instance started with a `HYPRMUX_INSTANCE` other than `default` keeps its
generated apps in a subfolder named after it. When an installed app has the
same id as a generated one, the installed one wins.

## Generated apps

Hyprmux looks in these folders, and in one level of subfolders of the first and
third:

- `/Applications`
- `/Applications/Utilities`
- `~/Applications`
- `/System/Applications`
- `/System/Applications/Utilities`

It doesn't search with Spotlight, and it ignores running apps. For each app it
finds:

1. An app that speaks the client protocol (`HyprmuxClient` in its Info.plist)
   gets a `native` `.hmapp` that opens it.
2. Otherwise, the adapter that matches it decides. If that adapter has a probe,
   the probe runs once per app version. If it passes, the app gets an `adapter`
   `.hmapp`. If it fails, or nothing matches, the app gets nothing.

Hyprmux writes only the bundles that changed, with the app's icon as
`icon.png`. It deletes generated bundles whose app is gone or no longer
qualifies. It regenerates in the background at startup, on config reload, on
`hyprmuxctl apps refresh`, and when the launcher opens. The launcher shows the
apps as they are at that moment.

Why an app is missing isn't shown in the launcher. `hyprmuxctl adapters match
APP` explains it; see [Apps that don't appear](ADAPTERS.md#apps-that-dont-appear).

## Zed

Zed for Hyprmux is a build of Zed whose windows open as tiles. It's an
optional download, built from a fork:
[github.com/gavrix/zed](https://github.com/gavrix/zed/blob/hyprmux/HYPRMUX.md).

1. Download `Zed-for-Hyprmux-VERSION-aarch64.zip` from
   [its releases](https://github.com/gavrix/zed/releases) and unzip it.
2. Move `Zed.hmapp` into `~/.config/hyprmux/apps/`.
3. Run `hyprmuxctl apps refresh`, or open the launcher.

It's signed and notarized, so the [trust](#trust) check passes without asking.
It keeps its own Zed database and session, apart from a normal Zed, and
shares the settings in `~/.config/zed`. It doesn't update itself: replace
`Zed.hmapp` with a newer one.

## Customizing an app

Copy its generated `.hmapp` into the installed folder and edit `Info.json`:

```sh
cp -R ~/Library/Application\ Support/Hyprmux/Apps/Cursor.hmapp ~/.config/hyprmux/apps/
# change "name", add arguments to "args", remove "generatedBy"
hyprmuxctl apps refresh
```

Your copy keeps the id, so it replaces the generated one. Regeneration never
touches it. Remove `generatedBy`: it marks bundles Hyprmux owns.

## `hyprmuxctl apps`

```sh
hyprmuxctl apps                     # ID, NAME, KIND, SOURCE, ADAPTER, APP/EXEC; errors; folders
hyprmuxctl apps --json              # everything, plus the last generation's counts
hyprmuxctl apps refresh             # regenerate now; replies when done
hyprmuxctl apps add "VS Code" ~/Downloads/"Visual Studio Code.app"
hyprmuxctl apps add "Zed (dev)" ~/src/zed/target/release-fast/zed --foreground
hyprmuxctl launch "Zed (dev)" ~/src/project
hyprmuxctl launch --focus com.todesktop.230313mzl4w4u92
```

`apps add NAME PATH [ARGS...]` writes an installed `.hmapp`, and replies with it:

- **An `.app`:** classified like a generated app, with the probe. Its id is the
  app's bundle id. If Hyprmux can't open it, `apps add` says so and writes nothing.
- **Anything else:** an executable, run as `exec`. Its id is `user.` plus the
  name in lowercase, with dashes (`user.zed-dev`).

ARGS become default arguments; arguments given at launch follow them.

`launch NAME|ID [ARGS...]` opens an app in a new tile and replies with the
tile's JSON, like `new-surface`. It matches an id first, then a name, ignoring
case. The tile takes focus only with `--focus`.

## The launcher

`picker, apps` lists every app with its icon: the ones you launched recently
first, then the rest by name. Typing filters the names, fzf style. Enter opens
the selected app; Escape closes the launcher. With no apps at all, it shows one
row, "No apps".

The Hyprmux menu has **Open App…**, which opens the same launcher. Configs
written before the launcher existed have no bind for it; add
`bind = $mod, D, picker, apps`, or use the menu. The menu item has no
shortcut of its own, since binds own the keyboard.

The `launch` dispatcher opens one app directly, by name or id. Its text names an
app whole; failing that, the first word does and the rest are arguments:

```ini
bind = $mod, D, picker, apps
bind = $mod SHIFT, D, launch, Visual Studio Code
```

## Finder

A `.hmapp` shows as one item in Finder. Double-clicking it, or `open
App.hmapp`, opens it in a tile, from wherever the bundle is.
`hyprmuxctl new-surface --type app PATH.hmapp` does the same.

## Profiles

An app Hyprmux lifts through an adapter (VS Code, Cursor, Logseq, and other
Electron apps) runs with **its own profile**, apart from your normal copy of the
app. Expect it to start fresh:

- **Settings, sign-ins, and window state start empty.** So do VS Code's and
  Cursor's extensions. Set them up once inside Hyprmux, or copy them over.
- **It runs next to your own copy.** Electron apps allow one running instance
  per profile; on a shared profile, opening the app in Hyprmux while your own
  copy runs would just hand off to it and quit.
- **The profile lives in** `~/Library/Application Support/Hyprmux/electron-apps/APP/`
  (`userdata/`, and `extensions/` for VS Code and Cursor). Deleting that folder
  resets the app in Hyprmux; your own copy is untouched.
- **Only the app's own profile is separate.** Files an app keeps elsewhere are
  shared with your normal copy: the folders and files you open, Logseq's graphs,
  dotfiles like `~/.logseq`, and anything in the system keychain.

To use your real profile instead, copy the app's generated `.hmapp` into your
apps folder ([Customizing an app](#customizing-an-app)) and pass the profile
folder yourself, for example for VS Code:

```json
"args": ["--adapter", "vscode", "{app}", "--user-data-dir", "/Users/you/Library/Application Support/Code", "{args}"]
```

With your real profile, quit your normal copy of the app before opening it in
Hyprmux, or it quits right away. Not every app honors `--user-data-dir`; VS Code
and Cursor do.

## When an app doesn't open

Hyprmux says "Couldn't open NAME.", or "NAME didn't open." when no window
showed up within 20 seconds. The notice doesn't say why. For an app an
adapter lifts, `hyprmuxctl adapters` shows the reason as the instance's note,
and the path of its full log ([Runtime state](ADAPTERS.md#runtime-state)).
Other reasons go to the system log (subsystem `dev.gavrix.hyprmux`).

## Closing

Closing an app's last tile quits the app, after a 3-second grace period that
lets an app replace its window (VS Code reloading, say). On macOS many apps keep
running with no windows; in Hyprmux a windowless app would only linger. An app
that answers ⌘W by hiding its window instead of closing it (Logseq does) loses
the tile the same way.

## Sessions

App tiles opened from the catalog come back by id when Hyprmux restores a
session or a layout. The app's path or adapter can change in between. When
the id is gone, Hyprmux shows "Couldn't reopen NAME." and drops the tile.
A `.hmapp` opened by path comes back by that path.

## Trust

A `.hmapp` that carries its own executable is code. If it was downloaded (it
has the `com.apple.quarantine` attribute), Hyprmux checks the executable's
signature before running it. A valid signature from a certificate Apple issued
(Developer ID, or Apple Development) passes. Otherwise Hyprmux asks once,
naming the app, and remembers the answer in `trust.json` in the generated
folder. A changed executable asks again. Generated apps, and apps whose `exec`
is outside the bundle, skip the check.
