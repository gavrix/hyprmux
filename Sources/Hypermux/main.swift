import AppKit
import GhosttyKit

// Point libghostty at our bundled resources (terminfo, shell integration, themes).
if let res = Bundle.main.resourceURL?.appendingPathComponent("ghostty").path,
   FileManager.default.fileExists(atPath: res) {
    setenv("GHOSTTY_RESOURCES_DIR", res, 1)
}

if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    fatalError("ghostty_init failed")
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
