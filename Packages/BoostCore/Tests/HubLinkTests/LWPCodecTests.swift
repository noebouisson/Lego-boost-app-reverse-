import XCTest
@testable import HubLink

final class LWPCodecTests: XCTestCase {

    // MARK: - Encodage

    func testHubPropertyEnableBatteryUpdates() {
        XCTAssertEqual([UInt8](LWPEncoder.hubProperty(.batteryVoltage, .enableUpdates)), [0x05, 0x00, 0x01, 0x06, 0x02])
    }

    func testHubActionSwitchOff() {
        XCTAssertEqual([UInt8](LWPEncoder.hubAction(.switchOff)), [0x04, 0x00, 0x02, 0x01])
    }

    func testPortInputFormatSetup() {
        let data = LWPEncoder.portInputFormatSetup(port: 0x02, mode: 8, deltaInterval: 1, notify: true)
        XCTAssertEqual([UInt8](data), [0x0A, 0x00, 0x41, 0x02, 0x08, 0x01, 0x00, 0x00, 0x00, 0x01])
    }

    func testPortInformationRequests() {
        XCTAssertEqual([UInt8](LWPEncoder.portInformationRequest(port: 1, type: .modeInfo)), [0x05, 0x00, 0x21, 0x01, 0x01])
        XCTAssertEqual([UInt8](LWPEncoder.portModeInformationRequest(port: 1, mode: 2, type: .name)),
                       [0x06, 0x00, 0x22, 0x01, 0x02, 0x00])
    }

    func testStartSpeedForDegrees() {
        let data = LWPEncoder.startSpeedForDegrees(port: 0x00, degrees: 360, speed: 50)
        XCTAssertEqual([UInt8](data), [0x0E, 0x00, 0x81, 0x00, 0x11, 0x0B, 0x68, 0x01, 0x00, 0x00, 0x32, 0x64, 0x7F, 0x00])
    }

    func testStartSpeedForTimeWithNegativeSpeed() {
        let data = LWPEncoder.startSpeedForTime(port: 0x01, milliseconds: 1000, speed: -100, endState: .float)
        XCTAssertEqual([UInt8](data), [0x0C, 0x00, 0x81, 0x01, 0x11, 0x09, 0xE8, 0x03, 0x9C, 0x64, 0x00, 0x00])
    }

    func testDualCommands() {
        XCTAssertEqual([UInt8](LWPEncoder.startSpeedDual(port: 0x10, speedLeft: 30, speedRight: -30)),
                       [0x0A, 0x00, 0x81, 0x10, 0x11, 0x08, 0x1E, 0xE2, 0x64, 0x00])
        XCTAssertEqual([UInt8](LWPEncoder.startSpeedForTimeDual(port: 0x10, milliseconds: 500, speedLeft: 10, speedRight: 20)),
                       [0x0D, 0x00, 0x81, 0x10, 0x11, 0x0A, 0xF4, 0x01, 0x0A, 0x14, 0x64, 0x7F, 0x00])
        XCTAssertEqual([UInt8](LWPEncoder.startSpeedForDegreesDual(port: 0x10, degrees: 90, speedLeft: 10, speedRight: 20)),
                       [0x0F, 0x00, 0x81, 0x10, 0x11, 0x0C, 0x5A, 0x00, 0x00, 0x00, 0x0A, 0x14, 0x64, 0x7F, 0x00])
    }

    func testWriteDirectModeDataCommands() {
        XCTAssertEqual([UInt8](LWPEncoder.startPower(port: 0x00, power: MotorPower.brake)),
                       [0x08, 0x00, 0x81, 0x00, 0x11, 0x51, 0x00, 0x7F])
        XCTAssertEqual([UInt8](LWPEncoder.setLEDColor(port: 0x32, colorIndex: LEDColor.red.rawValue)),
                       [0x08, 0x00, 0x81, 0x32, 0x11, 0x51, 0x00, 0x09])
        XCTAssertEqual([UInt8](LWPEncoder.presetEncoder(port: 0x00, position: -2)),
                       [0x0B, 0x00, 0x81, 0x00, 0x11, 0x51, 0x02, 0xFE, 0xFF, 0xFF, 0xFF])
    }

    func testLongMessageUsesTwoLengthBytes() throws {
        let data = LWPEncoder.frame(.hubProperties, [UInt8](repeating: 0xAA, count: 130))
        XCTAssertEqual(data.count, 134)
        XCTAssertEqual(data[0], 0x86)
        XCTAssertEqual(data[1], 0x01)
        guard case .hubProperty(let update) = try LWPDecoder.decode(data) else { return XCTFail("type inattendu") }
        XCTAssertEqual(update.payload.count, 128)
    }

    // MARK: - Décodage

    func testDecodeAttachedIO() throws {
        let attached = Data([0x0F, 0x00, 0x04, 0x02, 0x01, 0x25, 0x00, 0, 0, 0, 0x10, 0, 0, 0, 0x10])
        XCTAssertEqual(try LWPDecoder.decode(attached), .attachedIO(.attached(port: 2, ioType: .visionSensor)))

        let virtual = Data([0x09, 0x00, 0x04, 0x10, 0x02, 0x27, 0x00, 0x00, 0x01])
        XCTAssertEqual(try LWPDecoder.decode(virtual),
                       .attachedIO(.attachedVirtual(port: 0x10, ioType: .internalMotorTacho, portA: 0, portB: 1)))

        let detached = Data([0x05, 0x00, 0x04, 0x02, 0x00])
        XCTAssertEqual(try LWPDecoder.decode(detached), .attachedIO(.detached(port: 2)))
    }

    func testDecodeFeedbackWithSeveralPorts() throws {
        let data = Data([0x07, 0x00, 0x82, 0x00, 0x0A, 0x01, 0x01])
        XCTAssertEqual(try LWPDecoder.decode(data), .outputFeedback([
            PortFeedback(port: 0, flags: [.completed, .idle]),
            PortFeedback(port: 1, flags: [.inProgress]),
        ]))
    }

    func testDecodeHubProperties() throws {
        guard case .hubProperty(let battery) = try LWPDecoder.decode(Data([0x06, 0x00, 0x01, 0x06, 0x06, 0x57])) else {
            return XCTFail("type inattendu")
        }
        XCTAssertEqual(battery.batteryPercent, 87)
        XCTAssertNil(battery.buttonPressed)

        guard case .hubProperty(let button) = try LWPDecoder.decode(Data([0x06, 0x00, 0x01, 0x02, 0x06, 0x01])) else {
            return XCTFail("type inattendu")
        }
        XCTAssertEqual(button.buttonPressed, true)
    }

    func testDecodePortValueAndInputFormat() throws {
        guard case .portValue(let port, let payload) = try LWPDecoder.decode(Data([0x08, 0x00, 0x45, 0x00, 0x98, 0xFF, 0xFF, 0xFF])) else {
            return XCTFail("type inattendu")
        }
        XCTAssertEqual(port, 0)
        XCTAssertEqual(payload.int32LE(at: 0), -104)

        let format = Data([0x0A, 0x00, 0x47, 0x02, 0x08, 0x01, 0x00, 0x00, 0x00, 0x01])
        XCTAssertEqual(try LWPDecoder.decode(format),
                       .portInputFormat(PortInputFormat(port: 2, mode: 8, deltaInterval: 1, notificationEnabled: true)))
    }

    func testDecodeModeName() throws {
        let data = Data([0x09, 0x00, 0x44, 0x00, 0x02, 0x00]) + Data("POS".utf8)
        guard case .portModeInformation(let information) = try LWPDecoder.decode(data) else { return XCTFail("type inattendu") }
        XCTAssertEqual(information.name, "POS")
    }

    func testDecodeErrorsAndUnknown() throws {
        XCTAssertEqual(try LWPDecoder.decode(Data([0x05, 0x00, 0x05, 0x81, 0x06])), .error(commandType: 0x81, code: 0x06))
        XCTAssertEqual(try LWPDecoder.decode(Data([0x04, 0x00, 0x7E, 0x01])), .unknown(type: 0x7E, payload: Data([0x01])))
        XCTAssertThrowsError(try LWPDecoder.decode(Data([0x05, 0x00])))
        XCTAssertThrowsError(try LWPDecoder.decode(Data([0x09, 0x00, 0x04, 0x10])))
        XCTAssertThrowsError(try LWPDecoder.decode(Data([0x04, 0x00, 0x82, 0x00])))
    }
}
