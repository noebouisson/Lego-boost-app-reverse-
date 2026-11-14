import BlockEngine
import HubLink
import XCTest
@testable import AppCore

final class AppCoreTests: XCTestCase {

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
    }

    func testStoreSavesLoadsDuplicatesAndDeletes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore(directory: directory)
        XCTAssertEqual(store.loadAll(), [])

        var first = try store.create(name: "Premier")
        XCTAssertEqual(first.scripts.first?.blocks.first?.opcode, .whenStarted)
        first.modifiedAt = Date(timeIntervalSince1970: 1_000)
        first.variables = ["score"]
        try store.save(first)

        var second = try store.duplicate(first)
        second.modifiedAt = Date(timeIntervalSince1970: 2_000)
        try store.save(second)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(second.name, "Premier (copie)")

        // Un fichier illisible est ignoré, pas fatal.
        try Data("pas du json".utf8).write(to: directory.appendingPathComponent("abime.json"))

        let loaded = ProjectStore(directory: directory).loadAll()
        XCTAssertEqual(loaded.map(\.id), [second.id, first.id])
        XCTAssertEqual(loaded.last, first)

        try store.delete(first.id)
        try store.delete(first.id)
        XCTAssertEqual(store.loadAll().map(\.id), [second.id])
    }

    /// Programme complet : interpréteur → adaptateur → session → faux hub.
    func testProgramDrivesSimulatedHubEndToEnd() async throws {
        var configuration = SimulatedTransport.Configuration()
        configuration.timeScale = 0.02
        let transport = SimulatedTransport(configuration: configuration)
        let lines = LineCollector(transport.commandLog.stream())
        let session = HubSession(transport: transport)
        await session.connect()
        try await eventually {
            let state = await session.state
            return state.motorPosition(.motorExternal) != nil && state.portID(for: .motorAB) != nil
        }

        func make(_ opcode: Opcode, _ inputs: [String: Value], _ branches: [[Block]] = []) -> Block {
            var block = BlockCatalog.makeBlock(opcode)
            for (key, value) in inputs { block.inputs[key] = value }
            if !branches.isEmpty { block.branches = branches }
            return block
        }
        let rotation = Value.reporter(make(.motorRotation, ["port": .option("EXT")]))
        let turned = Value.reporter(make(.compare, ["a": rotation, "op": .option(">"), "b": .number(170)]))
        let project = Project(name: "bout en bout", scripts: [
            Script(blocks: [
                BlockCatalog.makeBlock(.whenStarted),
                make(.setLight, ["color": .option("red")]),
                make(.motorRunForDegrees, ["port": .option("EXT"), "speed": .number(100), "degrees": .number(180)]),
                make(.ifElse, ["condition": turned], [
                    [make(.tankRunForSeconds, ["left": .number(40), "right": .number(-40), "seconds": .number(1)])],
                    [make(.setLight, ["color": .option("off")])],
                ]),
                make(.motorStart, ["port": .option("A"), "speed": .number(30)]),
            ]),
            Script(blocks: [
                make(.whenColor, ["color": .option("green")]),
                make(.setLight, ["color": .option("green")]),
                BlockCatalog.makeBlock(.stopProgram),
            ]),
        ])

        let interpreter = Interpreter(device: HubDeviceAdapter(session: session, sounds: SilentSoundPlayer()))
        await interpreter.start(project)
        try await eventually { lines.all.contains("Moteur A : vitesse 30 %") }
        var state = await interpreter.state
        XCTAssertTrue(state.isRunning)

        transport.inject(.color(SensorColor.green.rawValue))
        await interpreter.waitUntilFinished()
        state = await interpreter.state
        XCTAssertFalse(state.isRunning)
        XCTAssertNil(state.errorMessage)

        try await eventually { lines.all.contains("Moteur A : arrêt (frein)") }
        let expected = ["LED : couleur n° 9", "Moteur externe : vitesse 100 % sur 180°",
                        "Moteurs A+B : vitesses 40 % et -40 % pendant 1000 ms", "Moteur A : vitesse 30 %",
                        "LED : couleur n° 6", "Moteur A : arrêt (frein)"]
        var cursor = lines.all.startIndex
        for line in expected {
            guard let found = lines.all[cursor...].firstIndex(of: line) else {
                return XCTFail("ligne absente ou mal placée : \(line) dans \(lines.all)")
            }
            cursor = found + 1
        }
    }

    func testMissingHubSurfacesAsProgramError() async {
        let session = HubSession(transport: SimulatedTransport())
        let interpreter = Interpreter(device: HubDeviceAdapter(session: session, sounds: SilentSoundPlayer()))
        var light = BlockCatalog.makeBlock(.setLight)
        light.inputs["color"] = .option("blue")
        await interpreter.run(Project(name: "hors ligne", scripts: [
            Script(blocks: [BlockCatalog.makeBlock(.whenStarted), light]),
        ]))
        let state = await interpreter.state
        XCTAssertEqual(state.errorMessage, HubError.notConnected.errorDescription)
        XCTAssertEqual(state.failedBlock, light.id)
    }

    func testSnapshotMapping() {
        var state = HubState()
        state.devices = [0: AttachedDevice(port: 0, ioType: .internalMotorTacho),
                         1: AttachedDevice(port: 1, ioType: .internalMotorTacho)]
        state.motorPositions = [0: 100, 1: 300]
        state.color = .yellow
        state.distance = 7
        state.tiltX = -12
        state.shakeCount = 3
        let snapshot = HubDeviceAdapter.snapshot(from: state)
        XCTAssertEqual(snapshot.color, .yellow)
        XCTAssertEqual(snapshot.distance, 7)
        XCTAssertEqual(snapshot.tiltX, -12)
        XCTAssertEqual(snapshot.shakeCount, 3)
        XCTAssertEqual(snapshot.rotations, [.a: 100, .b: 300, .ab: 200])
    }

    private func eventually(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: @Sendable () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition non atteinte", file: file, line: line)
        throw CancellationError()
    }
}

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<String>) {
        task = Task { [weak self] in
            for await line in stream { self?.append(line) }
        }
    }

    deinit { task?.cancel() }

    private func append(_ line: String) {
        lock.lock(); storage.append(line); lock.unlock()
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
