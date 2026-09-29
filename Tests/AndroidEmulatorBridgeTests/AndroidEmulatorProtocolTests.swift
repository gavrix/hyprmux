import XCTest
@testable import AndroidEmulatorBridge

final class AndroidEmulatorProtocolTests: XCTestCase {
    func testInputStreamUsesInstalledEmulatorServicePath() {
        XCTAssertEqual(
            Android_Emulation_Control_EmulatorControllerClientMetadata.Methods.streamInputEvent.path,
            "/android.emulation.control.EmulatorController/streamInputEvent"
        )
    }

    func testMMapScreenshotRequestKeepsInstalledWireFields() throws {
        var request = Android_Emulation_Control_ImageFormat()
        request.format = .rgba8888
        request.width = 720
        request.height = 1280
        request.transport.channel = .mmap
        request.transport.handle = "file:///tmp/x"

        XCTAssertEqual(
            Array(try request.serializedData()),
            [
                0x08, 0x01,
                0x18, 0xd0, 0x05,
                0x20, 0x80, 0x0a,
                0x32, 0x11, 0x08, 0x01, 0x12, 0x0d,
                0x66, 0x69, 0x6c, 0x65, 0x3a, 0x2f, 0x2f, 0x2f,
                0x74, 0x6d, 0x70, 0x2f, 0x78,
            ]
        )
    }

    func testHardwareButtonsUseEmulatorW3CKeyNames() {
        XCTAssertEqual(AndroidEmulatorHardwareButton.back.key, "GoBack")
        XCTAssertEqual(AndroidEmulatorHardwareButton.home.key, "GoHome")
        XCTAssertEqual(AndroidEmulatorHardwareButton.appSwitch.key, "AppSwitch")
    }

    func testHardwareButtonKeypressKeepsInstalledWireFields() throws {
        var key = Android_Emulation_Control_KeyboardEvent()
        key.eventType = .keypress
        key.key = AndroidEmulatorHardwareButton.home.key
        var input = Android_Emulation_Control_InputEvent()
        input.keyEvent = key

        XCTAssertEqual(
            Array(try input.serializedData()),
            [0x0a, 0x0a, 0x10, 0x02, 0x22, 0x06, 0x47, 0x6f, 0x48, 0x6f, 0x6d, 0x65]
        )
    }

    func testKeyboardInputEventKeepsInstalledWireFields() throws {
        var key = Android_Emulation_Control_KeyboardEvent()
        key.codeType = .mac
        key.eventType = .keyup
        key.keyCode = 11
        var input = Android_Emulation_Control_InputEvent()
        input.keyEvent = key

        XCTAssertEqual(
            Array(try input.serializedData()),
            [0x0a, 0x06, 0x08, 0x04, 0x10, 0x01, 0x18, 0x0b]
        )
    }

    func testTouchInputEventKeepsInstalledWireFields() throws {
        var touch = Android_Emulation_Control_Touch()
        touch.x = 100
        touch.y = 200
        touch.pressure = 1
        touch.expiration = .neverExpire
        var touchEvent = Android_Emulation_Control_TouchEvent()
        touchEvent.touches = [touch]
        var input = Android_Emulation_Control_InputEvent()
        input.touchEvent = touchEvent

        XCTAssertEqual(
            Array(try input.serializedData()),
            [0x12, 0x0b, 0x0a, 0x09, 0x08, 0x64, 0x10, 0xc8, 0x01, 0x20, 0x01, 0x38, 0x01]
        )
    }
}
