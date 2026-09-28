import CoreGraphics
import Foundation
import XCTest
@testable import HyprmuxCore

final class ConfigTests: XCTestCase {
    func testDefaultConfigParsesCleanly() {
        let c = ConfigParser.parse(defaultConfig)
        XCTAssertEqual(c.errors, [])
        XCTAssertGreaterThan(c.binds.count, 40)
        XCTAssertEqual(c.wm.gapsOut, Insets(all: 14))
        XCTAssertEqual(c.activeBorder.colors.count, 2)
        XCTAssertEqual(c.activeBorder.angle, 45)
        XCTAssertTrue(c.ghostty.contains("window-padding-x = 8"))
    }

    func testConfirmQuit() {
        XCTAssertTrue(ConfigParser.parse(defaultConfig).confirmQuit)
        XCTAssertTrue(HyprmuxConfig().confirmQuit)
        XCTAssertFalse(ConfigParser.parse("hyprmux:confirm_quit = false").confirmQuit)
    }

    func testEmbeddedDefaultMatchesRepoFile() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config/hyprmux.conf")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines),
                       defaultConfig.trimmingCharacters(in: .whitespacesAndNewlines),
                       "run scripts/gen-default-config.sh")
    }

    func testVariablesSectionsAndBinds() {
        let c = ConfigParser.parse("""
        $mod = SUPER
        $step = 25
        general {
            gaps_in = 3 # comment
            gaps_out = 1 2 3 4
        }
        bind = $mod SHIFT, H, movewindow, l
        binde = $mod, right, resizeactive, $step 0
        bind = $mod, Return, exec, htop, --tree
        """)
        XCTAssertEqual(c.errors, [])
        XCTAssertEqual(c.wm.gapsIn, Insets(all: 3))
        XCTAssertEqual(c.wm.gapsOut, Insets(top: 1, right: 2, bottom: 3, left: 4))
        XCTAssertEqual(c.binds[0].mods, [.super, .shift])
        XCTAssertEqual(c.binds[0].trigger, .key(0x04))
        XCTAssertEqual(c.binds[0].dispatcher, .moveWindow(.left))
        XCTAssertEqual(c.binds[1].dispatcher, .resizeActive(dx: 25, dy: 0))
        XCTAssertTrue(c.binds[1].flags.contains("e"))
        XCTAssertEqual(c.binds[2].dispatcher, .exec("htop, --tree"))
    }

    func testSubmaps() {
        let c = ConfigParser.parse("""
        bind = SUPER, R, submap, resize
        submap = resize
        binde = , L, resizeactive, 10 0
        bind = , escape, submap, reset
        submap = reset
        bind = SUPER, Q, killactive
        """)
        XCTAssertEqual(c.binds.map(\.submap), ["reset", "resize", "resize", "reset"])
        XCTAssertEqual(c.binds[1].mods, [])
    }

    func testErrorsAreCollected() {
        let c = ConfigParser.parse("""
        bind = SUPER, nokey, killactive
        general {
            gaps_in = abc
        }
        what = 1
        """)
        XCTAssertEqual(c.errors.count, 3)
    }

    func testTransparencyOptions() {
        let c = ConfigParser.parse("""
        decoration {
            inactive_opacity = 0.7
            blur {
                enabled = true
                size = 8
                passes = 2
            }
        }
        misc {
            background_color = rgba(00000000)
        }
        """)
        XCTAssertEqual(c.errors, [])
        XCTAssertEqual(c.inactiveOpacity, 0.7)
        XCTAssertTrue(c.blurEnabled)
        XCTAssertEqual(c.backgroundColor.a, 0)
    }

    func testWebAddress() {
        let search = "https://duckduckgo.com/?q=%s"
        XCTAssertEqual(WebAddress.resolve("https://example.com/a?b=1", search: search)?.absoluteString, "https://example.com/a?b=1")
        XCTAssertEqual(WebAddress.resolve("github.com/gavrix", search: search)?.absoluteString, "https://github.com/gavrix")
        XCTAssertEqual(WebAddress.resolve("localhost:3000/x", search: search)?.absoluteString, "http://localhost:3000/x")
        XCTAssertEqual(WebAddress.resolve("swift concurrency", search: search)?.absoluteString,
                       "https://duckduckgo.com/?q=swift%20concurrency")
        XCTAssertEqual(WebAddress.resolve("c++ & rust", search: search)?.absoluteString,
                       "https://duckduckgo.com/?q=c%2B%2B%20%26%20rust")
        XCTAssertEqual(WebAddress.resolve("hello", search: search)?.host, "duckduckgo.com")
        XCTAssertEqual(WebAddress.resolve("/tmp/a.html", search: search)?.isFileURL, true)
        XCTAssertNil(WebAddress.resolve("  ", search: search))
        XCTAssertEqual(WebAddress.resolve("chrome-extension://abc/popup/index.html", search: search)?.scheme, "chrome-extension")
    }

    func testWebEngine() {
        XCTAssertEqual(ConfigParser.parse("").webEngine, "webkit")
        let c = ConfigParser.parse("web {\n    engine = chromium\n}")
        XCTAssertEqual(c.errors, [])
        XCTAssertEqual(c.webEngine, "chromium")
        XCTAssertEqual(ConfigParser.parse("web:engine = gecko").errors.count, 1)
    }

    func testGroupBorderSize() {
        XCTAssertNil(ConfigParser.parse("").groupBorderSize)
        let c = ConfigParser.parse("group {\n    border_size = 4\n}")
        XCTAssertEqual(c.errors, [])
        XCTAssertEqual(c.groupBorderSize, 4)
    }

    func testFullscreenStyle() {
        XCTAssertEqual(ConfigParser.parse("").fullscreenStyle, "fill")
        XCTAssertEqual(ConfigParser.parse("misc {\n    fullscreen_style = native\n}").fullscreenStyle, "native")
        XCTAssertEqual(try? Dispatcher.parse("monitorfullscreen", "").get(), .monitorFullscreen)
    }

    func testSimDispatcher() {
        XCTAssertEqual(try? Dispatcher.parse("sim", "").get(), .sim(""))
        XCTAssertEqual(try? Dispatcher.parse("simbutton", "Home").get(), .simButton("home"))
        XCTAssertNil(try? Dispatcher.parse("simbutton", "power").get())
        XCTAssertEqual(try? Dispatcher.parse("sim", "iPhone 17 Pro").get(), .sim("iPhone 17 Pro"))
    }

    func testWebDispatchers() {
        XCTAssertEqual(try? Dispatcher.parse("web", "github.com").get(), .web("github.com"))
        XCTAssertEqual(try? Dispatcher.parse("webnav", "back").get(), .webNav(.back))
        XCTAssertNil(try? Dispatcher.parse("webnav", "sideways").get())
    }

    func testIPCParsing() {
        XCTAssertEqual(try? IPCRequest.parse("sendkey , g").get(), .sendKey([], 0x05))
        XCTAssertEqual(try? IPCRequest.parse("sendkey SUPER SHIFT, Return").get(), .sendKey([.super, .shift], 0x24))
        XCTAssertEqual(try? IPCRequest.parse("dispatch workspace 3").get(), .dispatch(.workspace(.id(3))))
        XCTAssertEqual(try? IPCRequest.parse("sendmouse down , 272, 10 20").get(),
                       .sendMouse(phase: "down", [], button: 272, at: CGPoint(x: 10, y: 20)))
        XCTAssertEqual(try? IPCRequest.parse("senddrag , 272, 1 2, 3 4").get(),
                       .sendDrag([], button: 272, from: CGPoint(x: 1, y: 2), to: CGPoint(x: 3, y: 4)))
    }

    func testColors() {
        XCTAssertEqual(Color.parse("rgba(ff000080)"), Color(r: 1, g: 0, b: 0, a: 128.0 / 255))
        XCTAssertEqual(Color.parse("rgb(0, 255, 0)"), Color(r: 0, g: 1, b: 0))
        XCTAssertEqual(Color.parse("0xff0000ff"), Color(r: 0, g: 0, b: 1, a: 1))
        let g = Gradient.parse("rgba(33ccffee) rgba(0, 255, 153, 0.9) 45deg")
        XCTAssertEqual(g?.colors.count, 2)
        XCTAssertEqual(g?.angle, 45)
    }

    func testAnimationInheritance() {
        let c = ConfigParser.parse("""
        animations {
            bezier = snappy, 0.1, 1, 0.1, 1
            animation = windows, 1, 5, snappy, slide
            animation = windowsIn, 1, 2, default
        }
        """)
        XCTAssertEqual(c.errors, [])
        let win = c.animation("windowsMove")
        XCTAssertEqual(win.duration, 0.5, accuracy: 1e-9)
        XCTAssertEqual(win.curve, Bezier(0.1, 1, 0.1, 1))
        let wIn = c.animation("windowsIn")
        XCTAssertEqual(wIn.duration, 0.2, accuracy: 1e-9)
        XCTAssertEqual(wIn.style, "slide", "style inherits from parent")
        XCTAssertEqual(c.animation("workspaces").duration, 0.8, accuracy: 1e-9)
    }

    func testBezier() {
        XCTAssertEqual(Bezier.linear.value(at: 0.3), 0.3, accuracy: 1e-4)
        let b = Bezier.hyprDefault
        XCTAssertEqual(b.value(at: 0), 0)
        XCTAssertEqual(b.value(at: 1), 1)
        XCTAssertGreaterThan(b.value(at: 0.2), 0.5, "ease-out front-loads progress")
    }

    func testDispatcherParsing() {
        XCTAssertEqual(try? Dispatcher.parse("workspace", "e+1").get(), .workspace(.relativeExisting(1)))
        XCTAssertEqual(try? Dispatcher.parse("workspace", "-1").get(), .workspace(.relative(-1)))
        XCTAssertEqual(try? Dispatcher.parse("movetoworkspacesilent", "special:term").get(),
                       .moveToWorkspace(.special("term"), silent: true))
        XCTAssertEqual(try? Dispatcher.parse("splitratio", "exact 1.2").get(), .splitRatio(1.2, exact: true))
        XCTAssertNil(try? Dispatcher.parse("movefocus", "sideways").get())
    }
}
