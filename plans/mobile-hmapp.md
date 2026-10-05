# Plan: launches that offer windows, single-instance apps, and Mobile.hmapp

Status: implemented, uncommitted. Input on devices is untested (needs a throwaway simulator and AVD).

## Goal

Move the iOS Simulator and Android Emulator tiles out of Hyprmux into a first-party
app, `Mobile.hmapp`, bundled with Hyprmux. Mobile is one process. It connects to
simulators and emulators and shows each device as an ordinary client toplevel. The
pieces it needs are general `.hmapp` and client protocol features, not Mobile special
cases.

## Decisions the user made (do not revisit)

1. **No tile before a window.** A launch no longer reserves a tile. Hyprmux records a
   pending launch and waits for the app to answer.
2. **Windows are a runtime offer.** The app answers a launch by creating a toplevel,
   or by offering windows. One offered window opens at once. Several show a picker.
   Nothing about windows goes in `Info.json`.
3. **Process policy is static.** `Info.json` says whether the app wants one process
   per launch (the default) or a single process. A launch of a running single-instance
   app goes to that process over its connection.
4. **No empty-list text in Hyprmux.** With no devices, Mobile opens a window that says
   so. It doesn't turn into a device later; the user launches again.
5. **Copies of a window are allowed.** Picking the same device twice opens two tiles.
6. **No binds into app actions.** `simbutton`, `sim`, and `android` dispatchers go
   away, and so does `new-surface --type sim|android`.
7. **Errors draw inside the window.** No notice API for clients yet.
8. **Zero-copy pixels where possible.** The simulator's framebuffer IOSurface is shown
   by reference. Android frames are written once into an IOSurface.
9. **First-party apps are first class.** A `builtin` catalog source in the app bundle.
10. **No legacy sessions.** `sim` and `android` session tiles are dropped, with no
    migration.
11. **Session restore is best effort.** The launch carries restore tokens; an app may
    ignore them.
12. **The launcher shows "Opening NAME…"** until the app answers, then the window
    picker. The window lands on the workspace recorded at launch.
13. **`hyprmuxctl launch` replies with the offer** when there are several windows;
    `--window ID` picks one.

## Design

### `Info.json`

`"instances": "multiple" | "single"`. Default `multiple`.

### Catalog

Sources, lowest precedence first: `builtin` (`Hyprmux.app/Contents/Resources/apps`),
`generated`, `installed`. A later source with the same id wins. Builtin apps skip the
trust check. Their executables live in `Contents/MacOS` and resolve by bare name.

### Client protocol

- `launch { launch_token, args, restore_tokens }`, compositor to client. Hyprmux sends
  one for every launch, the first one included, right after `welcome`.
- `toplevel.create { …, launch_token }`. Without one, the toplevel belongs to the
  connection's `hello` token (clients written before this change).
- `launch.offer { launch_token, windows_json }`, client to compositor:
  `[{id, title, detail}]`. Sending it again replaces the list.
- `launch.open { launch_token, window }` and `launch.cancel { launch_token }`,
  compositor to client.
- `launch.done { launch_token }`, client to compositor: no more windows for this
  launch. Hyprmux drops what still waits (restored tiles, the pending launch).
- `subsurface.create { id, surface, parent }`, `subsurface.set_rect { id, x, y, w, h }`
  (applied at the parent's next commit), `subsurface.destroy { id }`. A subsurface
  is drawn above its parent, scaled to its rect.
- Re-attaching and committing the buffer on screen means its pixels changed.

### Launch flow

1. Resolve the app. Single and running: send `launch` on its connection. Single and
   starting: queue it. Otherwise: start a process.
2. Pending launch: token, workspace, focus, interactive or not, the IPC reply.
3. First answer:
   - a toplevel: a new tile on the launch's workspace.
   - an offer: one window opens; several open the picker (interactive) or reply with
     the list (IPC, then cancel). `--window ID` opens that one.
   - `launch.done` with nothing: end quietly.
4. Timeouts: 20 s to the first answer (longer while the process runs), paused while
   the picker is open, again after a pick.

### Mobile

`Sources/hyprmux-mobile`, single instance. Window ids `ios:UDID` and
`android:AVD_ID`. Restore token = window id. Arguments name a device (UDID, AVD id, or
name) and open it without an offer. iOS: the framebuffer is a subsurface by reference,
the Home bar is the main surface. Android: frames go into a three-buffer subsurface
swapchain. Quits when its last window closes and no launch is pending.

## Order

1. Protocol names, kit API.
2. `Info.json` key, builtin source.
3. Hyprmux launch rework, subsurfaces, recommit.
4. Mobile.
5. Remove the in-process surfaces, dispatchers, and session kinds.
6. Bundle, tests, docs.
