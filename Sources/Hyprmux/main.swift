import AppKit
import ChromiumBridge
import GhosttyKit
import HyprmuxCore

// Point libghostty at our bundled resources (terminfo, shell integration, themes).
if let res = Bundle.main.resourceURL?.appendingPathComponent("ghostty").path,
   FileManager.default.fileExists(atPath: res) {
    setenv("GHOSTTY_RESOURCES_DIR", res, 1)
}

/// Chromium switches from the config: extensions and free-form flags.
func chromiumSwitches(_ c: HyprmuxConfig) -> [String] {
    var s = c.chromiumFlags
    let exts = c.chromiumExtensions.filter { FileManager.default.fileExists(atPath: $0 + "/manifest.json") }
    if !exts.isEmpty {
        s.append("load-extension=" + exts.joined(separator: ","))
        // Chrome 137+ ignores --load-extension unless this feature is off.
        s.append("disable-features=DisableLoadExtensionCommandLineSwitch")
    }
    return s
}

if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    fatalError("ghostty_init failed")
}

// CEF needs its NSApplication subclass; create it before anything touches NSApp.
let app = HMApplication.shared as! HMApplication
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

let startupConfig = AppDelegate.loadConfig()
let wantsChromium = startupConfig.webEngine == "chromium"
let cefFramework = Bundle.main.privateFrameworksURL?
    .appendingPathComponent("Chromium Embedded Framework.framework").path ?? ""
// Chromium allows one process per profile; HYPRMUX_CHROMIUM_PROFILE lets a second instance run.
let cefCache = ProcessInfo.processInfo.environment["HYPRMUX_CHROMIUM_PROFILE"]
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hyprmux/Chromium").path

if wantsChromium, FileManager.default.fileExists(atPath: cefFramework),
   HMChromium.start(withRootCachePath: cefCache, switches: chromiumSwitches(startupConfig)) {
    // Quit closes every browser first; the loop then returns and CEF shuts down.
    app.terminateHandler = {
        delegate.saveSessionBeforeQuit()
        HMChromium.closeAllAndQuit()
    }
    HMChromium.runMessageLoop()
    HMChromium.shutdown()
    exit(0)
} else {
    if wantsChromium {
        delegate.startupNotes.append("web:engine = chromium, but Chromium could not start (is it bundled?); using WebKit")
    }
    app.run()
}
