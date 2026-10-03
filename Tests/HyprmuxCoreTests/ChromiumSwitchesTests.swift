import HyprmuxCore
import XCTest

final class ChromiumSwitchesTests: XCTestCase {
    func testEnablesResizeThrottleByDefault() {
        XCTAssertEqual(ChromiumSwitches.build(flags: [], extensions: []),
                       ["enable-features=ThrottleResizeIpc"])
    }

    func testKeepsOtherFlagsAsGiven() {
        XCTAssertEqual(ChromiumSwitches.build(flags: ["disable-gpu", "lang=en-US"], extensions: []),
                       ["disable-gpu", "lang=en-US", "enable-features=ThrottleResizeIpc"])
    }

    func testMergesUserFeaturesIntoOneSwitch() {
        let s = ChromiumSwitches.build(
            flags: ["enable-features=Foo", "--enable-features=Bar:p/1,Foo", "disable-features=Baz"],
            extensions: ["/ext/a", "/ext/b"])
        XCTAssertEqual(s, [
            "load-extension=/ext/a,/ext/b",
            "enable-features=Foo,Bar:p/1,ThrottleResizeIpc",
            "disable-features=Baz,DisableLoadExtensionCommandLineSwitch",
        ])
    }

    func testUserCanDisableADefaultFeature() {
        XCTAssertEqual(ChromiumSwitches.build(flags: ["disable-features=ThrottleResizeIpc"], extensions: []),
                       ["disable-features=ThrottleResizeIpc"])
    }

    func testUserEnabledDefaultIsNotDuplicated() {
        XCTAssertEqual(ChromiumSwitches.build(flags: ["enable-features=ThrottleResizeIpc"], extensions: []),
                       ["enable-features=ThrottleResizeIpc"])
    }
}
