import AppKit
import ChromiumBridge
import GhosttyKit
import HypermuxCore

// Point libghostty at our bundled resources (terminfo, shell integration, themes).
if let res = Bundle.main.resourceURL?.appendingPathComponent("ghostty").path,
   FileManager.default.fileExists(atPath: res) {
    setenv("GHOSTTY_RESOURCES_DIR", res, 1)
}

if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    fatalError("ghostty_init failed")
}

// CEF needs its NSApplication subclass; create it before anything touches NSApp.
let app = HMApplication.shared as! HMApplication
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

let wantsChromium = AppDelegate.loadConfig().webEngine == "chromium"
let cefFramework = Bundle.main.privateFrameworksURL?
    .appendingPathComponent("Chromium Embedded Framework.framework").path ?? ""
// Chromium allows one process per profile; HYPERMUX_CHROMIUM_PROFILE lets a second instance run.
let cefCache = ProcessInfo.processInfo.environment["HYPERMUX_CHROMIUM_PROFILE"]
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hypermux/Chromium").path

if wantsChromium, FileManager.default.fileExists(atPath: cefFramework),
   HMChromium.start(withRootCachePath: cefCache) {
    // Quit closes every browser first; the loop then returns and CEF shuts down.
    app.terminateHandler = { HMChromium.closeAllAndQuit() }
    HMChromium.runMessageLoop()
    HMChromium.shutdown()
    exit(0)
} else {
    if wantsChromium {
        delegate.startupNotes.append("web:engine = chromium, but Chromium could not start (is it bundled?); using WebKit")
    }
    app.run()
}
