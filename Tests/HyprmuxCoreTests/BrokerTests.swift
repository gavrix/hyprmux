import XCTest
@testable import HyprmuxCore

final class BrokerTests: XCTestCase {
    /// Trimmed from a real `launchctl print gui/501/dev.gavrix.hyprmux.broker` with the dev broker.
    let devBroker = """
    gui/501/dev.gavrix.hyprmux.broker = {
    \tactive count = 3
    \tpath = /Users/me/Library/Caches/dev.gavrix.hyprmux/dev.gavrix.hyprmux.broker.plist
    \ttype = LaunchAgent
    \tstate = running

    \tprogram = /tmp/HyprmuxTest.app/Contents/MacOS/hyprmux-broker
    \targuments = {
    \t\t/tmp/HyprmuxTest.app/Contents/MacOS/hyprmux-broker
    \t}

    \tenvironment = {
    \t\tXPC_SERVICE_NAME => dev.gavrix.hyprmux.broker
    \t}

    \tpid = 56703
    \tendpoints = {
    \t\t"dev.gavrix.hyprmux.compositor" = {
    \t\t\tstate = active
    \t\t}
    \t}
    }
    """

    func testParsesDevBrokerJob() {
        let job = LaunchdJob.parse(devBroker)
        XCTAssertEqual(job.path, "/Users/me/Library/Caches/dev.gavrix.hyprmux/dev.gavrix.hyprmux.broker.plist")
        XCTAssertEqual(job.program, "/tmp/HyprmuxTest.app/Contents/MacOS/hyprmux-broker")
        XCTAssertEqual(job.state, "running")
        XCTAssertEqual(job.pid, 56703)
        XCTAssertEqual(job.origin(home: "/Users/me"), .devBroker)
        XCTAssertEqual(job.origin(home: "/Users/someone-else"), .other)
    }

    /// Trimmed from a real `launchctl print` of the agent SMAppService registered.
    let registered = """
    gui/501/dev.gavrix.hyprmux.broker = {
    \tactive count = 3
    \tpath = (submitted by smd.7578)
    \ttype = Submitted
    \tmanaged_by = com.apple.xpc.ServiceManagement
    \tstate = running

    \tprogram identifier = Contents/MacOS/hyprmux-broker (mode: 2)
    \tparent bundle identifier = dev.gavrix.hyprmux
    \tparent bundle version = 1
    \tpid = 29333
    }
    """

    func testParsesRegisteredAgentJob() {
        let job = LaunchdJob.parse(registered)
        XCTAssertEqual(job.program, "Contents/MacOS/hyprmux-broker")
        XCTAssertEqual(job.parentBundle, "dev.gavrix.hyprmux")
        XCTAssertEqual(job.pid, 29333)
        XCTAssertEqual(job.origin(home: "/Users/me"), .app)
        XCTAssertNil(LaunchdJob().origin(home: "/Users/me"))
    }
}
