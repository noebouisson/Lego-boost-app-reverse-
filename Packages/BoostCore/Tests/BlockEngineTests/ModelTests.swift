import XCTest
@testable import BlockEngine

final class ModelTests: XCTestCase {

    func testCatalogCoversEveryOpcode() {
        for opcode in Opcode.allCases {
            let spec = BlockCatalog.spec(for: opcode)
            XCTAssertEqual(spec.opcode, opcode)
            XCTAssertFalse(spec.name.isEmpty)
            // Chaque paramètre affiché est déclaré, et inversement.
            let shown = spec.layout.compactMap { piece -> String? in
                if case .input(let key) = piece { return key }
                return nil
            }
            XCTAssertEqual(Set(shown), Set(spec.inputs.map(\.key)), "\(opcode)")
            XCTAssertEqual(spec.shape == .container, !spec.branchLabels.isEmpty, "\(opcode)")

            let block = BlockCatalog.makeBlock(opcode)
            XCTAssertEqual(Set(block.inputs.keys), Set(spec.inputs.map(\.key)), "\(opcode)")
            XCTAssertEqual(block.branches.count, spec.branchLabels.count, "\(opcode)")
        }
        let listed = BlockCategory.allCases.flatMap(BlockCatalog.opcodes(in:))
        XCTAssertEqual(listed.count, Opcode.allCases.count)
        XCTAssertEqual(Set(listed), Set(Opcode.allCases))
    }

    func testDefaultOptionsAreValidChoices() {
        for opcode in Opcode.allCases {
            for input in BlockCatalog.spec(for: opcode).inputs {
                if case .option(let options, let defaultID) = input.kind {
                    XCTAssertTrue(options.contains { $0.id == defaultID }, "\(opcode).\(input.key)")
                }
            }
        }
    }

    func testOptionListsMatchEnums() {
        XCTAssertEqual(Set(BlockCatalog.motorOptions.map(\.id)), Set(MotorTarget.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(BlockCatalog.detectedColorOptions.map(\.id)), Set(DetectedColor.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(BlockCatalog.lightColorOptions.map(\.id)), Set(LightColor.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(BlockCatalog.soundOptions.map(\.id)), Set(SoundID.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(BlockCatalog.tiltDirectionOptions.map(\.id)), Set(TiltDirection.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(BlockCatalog.tiltAxisOptions.map(\.id)), Set(TiltAxis.allCases.map(\.rawValue)))
    }

    func testProjectRoundTripsThroughJSON() throws {
        let condition = compare(variable("n"), ">", math(.number(2), "*", .reporter(block(.distance))))
        let original = Project(name: "Mon robot", scripts: [
            Script(x: 120, y: 80, blocks: [
                block(.whenColor, ["color": .option("green")]),
                block(.repeatTimes, ["times": .number(4)], [[
                    block(.ifElse, ["condition": condition], [[runBlock(.ab, seconds: 1.5)], [light(.off)]]),
                ]]),
            ]),
            Script(x: 40, y: 300, blocks: [waitBlock(2)]),
        ], variables: ["n"])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var expected = original
        // L'ISO 8601 ne garde pas les fractions de seconde.
        expected.modifiedAt = Date(timeIntervalSince1970: original.modifiedAt.timeIntervalSince1970.rounded(FloatingPointRoundingRule.down))
        var rounded = original
        rounded.modifiedAt = expected.modifiedAt

        let decoded = try decoder.decode(Project.self, from: try encoder.encode(rounded))
        XCTAssertEqual(decoded, expected)
        XCTAssertTrue(decoded.scripts[0].isRunnable)
        XCTAssertFalse(decoded.scripts[1].isRunnable)
    }

    func testBlockDecodesWithoutOptionalFields() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","opcode":"whenStarted"}"#
        let decoded = try JSONDecoder().decode(Block.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.opcode, .whenStarted)
        XCTAssertTrue(decoded.inputs.isEmpty)
        XCTAssertTrue(decoded.branches.isEmpty)
    }

    func testValueEncodingIsCompact() throws {
        let encoder = JSONEncoder()
        XCTAssertEqual(String(decoding: try encoder.encode(Value.number(3)), as: UTF8.self), #"{"n":3}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(Value.option("AB")), as: UTF8.self), #"{"o":"AB"}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(Value.variable("n")), as: UTF8.self), #"{"v":"n"}"#)
        XCTAssertEqual(String(decoding: try encoder.encode(Value.bool(true)), as: UTF8.self), #"{"b":true}"#)
    }
}
