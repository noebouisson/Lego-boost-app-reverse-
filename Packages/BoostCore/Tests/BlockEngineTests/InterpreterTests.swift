import XCTest
@testable import BlockEngine

final class InterpreterTests: XCTestCase {

    private func project(_ scripts: Script..., variables: [String] = []) -> Project {
        Project(name: "test", scripts: scripts, variables: variables)
    }

    private func eventually(timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: @Sendable () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition non atteinte", file: file, line: line)
        throw CancellationError()
    }

    // MARK: - Séquences et attente des commandes

    func testSequenceWaitsForEachMotorCommand() async {
        let device = MockDevice()
        let interpreter = Interpreter(device: device)
        await interpreter.run(project(script(
            block(.whenStarted),
            runBlock(.a, seconds: 1),
            block(.motorRunForDegrees, ["port": .option("B"), "speed": .number(-30), "degrees": .number(90)]),
            light(.red),
            block(.playSound, ["sound": .option(SoundID.laser.rawValue)])
        )))
        let calls = await device.calls
        XCTAssertEqual(calls, ["run A 50 1.0s", "done A", "run B -30 90°", "done B", "light red", "sound laser"])
        let stops = await device.stopCount
        XCTAssertEqual(stops, 1)
        let state = await interpreter.state
        XCTAssertFalse(state.isRunning)
        XCTAssertNil(state.errorMessage)
    }

    func testScriptsRunInParallel() async {
        let device = MockDevice(timeScale: 0.1)
        let interpreter = Interpreter(device: device)
        let start = Date()
        await interpreter.run(project(
            script(block(.whenStarted), runBlock(.a, seconds: 2)),
            script(block(.whenStarted), runBlock(.b, seconds: 2)),
            script(block(.whenStarted), runBlock(.external, seconds: 2))
        ))
        let elapsed = Date().timeIntervalSince(start)
        // Trois mouvements de 0,2 s réelles : en parallèle, bien moins de 0,6 s.
        XCTAssertGreaterThan(elapsed, 0.19)
        XCTAssertLessThan(elapsed, 0.45)
        let calls = await device.calls
        XCTAssertEqual(Set(calls.prefix(3)), ["run A 50 2.0s", "run B 50 2.0s", "run EXT 50 2.0s"])
    }

    func testScriptWithoutTriggerDoesNotRun() async {
        let device = MockDevice()
        let interpreter = Interpreter(device: device)
        await interpreter.run(project(script(light(.blue)), script(block(.whenStarted), light(.green))))
        let calls = await device.calls
        XCTAssertEqual(calls, ["light green"])
    }

    // MARK: - Contrôle et données

    func testRepeatAndVariables() async {
        let device = MockDevice()
        let interpreter = Interpreter(device: device)
        await interpreter.run(project(script(
            block(.whenStarted),
            block(.setVariable, ["name": .variable("n"), "value": .number(10)]),
            block(.repeatTimes, ["times": .number(3)], [[
                block(.changeVariable, ["name": .variable("n"), "value": .number(5)]),
                block(.motorStart, ["port": .option("A"), "speed": variable("n")]),
            ]])
        ), variables: ["n"]))
        let calls = await device.calls
        XCTAssertEqual(calls, ["start A 15", "start A 20", "start A 25"])
        let variables = await interpreter.state.variables
        XCTAssertEqual(variables["n"], 25)
    }

    func testIfElseWithMathAndLogic() async {
        let device = MockDevice()
        let interpreter = Interpreter(device: device)
        // (2 × 3 + 1 = 7) et non (7 < 5)  → alors
        let seven = math(math(.number(2), "*", .number(3)), "+", .number(1))
        let condition = Value.reporter(block(.and, [
            "a": compare(seven, "=", .number(7)),
            "b": .reporter(block(.not, ["a": compare(seven, "<", .number(5))])),
        ]))
        await interpreter.run(project(script(
            block(.whenStarted),
            block(.ifElse, ["condition": condition], [[light(.green)], [light(.red)]]),
            block(.ifElse, ["condition": compare(math(.number(7), "mod", .number(4)), ">", .number(3))],
                  [[light(.yellow)], [light(.blue)]]),
            block(.ifElse, ["condition": .bool(false)], [[light(.white)], []]),
            block(.motorStart, ["port": .option("A"), "speed": math(.number(10), "/", .number(0))])
        )))
        let calls = await device.calls
        XCTAssertEqual(calls, ["light green", "light blue", "start A 0"])
    }

    func testRandomStaysInRange() async {
        let device = MockDevice()
        let interpreter = Interpreter(device: device)
        let random = Value.reporter(block(.random, ["from": .number(3), "to": .number(6)]))
        await interpreter.run(project(script(
            block(.whenStarted),
            block(.repeatTimes, ["times": .number(40)], [[block(.motorStart, ["port": .option("A"), "speed": random])]])
        )))
        let calls = await device.calls
        XCTAssertEqual(calls.count, 40)
        XCTAssertTrue(Set(calls).isSubset(of: ["start A 3", "start A 4", "start A 5", "start A 6"]))
    }

    func testSensorReporters() async {
        let device = MockDevice()
        await device.set { $0.color = .blue; $0.distance = 3; $0.tiltX = 30; $0.rotations[.external] = 123 }
        let interpreter = Interpreter(device: device)
        let rotation = Value.reporter(block(.motorRotation, ["port": .option("EXT")]))
        let tilted = Value.reporter(block(.isTilted, ["direction": .option(TiltDirection.right.rawValue)]))
        let blue = Value.reporter(block(.colorIs, ["color": .option("blue")]))
        await interpreter.run(project(script(
            block(.whenStarted),
            block(.motorStart, ["port": .option("A"), "speed": rotation]),
            block(.motorStart, ["port": .option("B"), "speed": .reporter(block(.distance))]),
            block(.ifElse, ["condition": .reporter(block(.and, ["a": tilted, "b": blue]))], [[light(.green)], [light(.red)]])
        )))
        let calls = await device.calls
        XCTAssertEqual(calls, ["start A 123", "start B 3", "light green"])
    }

    func testWaitUntil() async throws {
        let device = MockDevice()
        let interpreter = Interpreter(device: device)
        await interpreter.start(project(script(
            block(.whenStarted),
            block(.waitUntil, ["condition": .reporter(block(.isButtonPressed))]),
            light(.green)
        )))
        try await Task.sleep(nanoseconds: 80_000_000)
        let before = await device.calls
        XCTAssertEqual(before, [])
        await device.set { $0.buttonPressed = true }
        await interpreter.waitUntilFinished()
        let after = await device.calls
        XCTAssertEqual(after, ["light green"])
    }

    // MARK: - Arrêt

    func testStopCancelsEverything() async throws {
        let device = MockDevice(timeScale: 1)
        let interpreter = Interpreter(device: device)
        await interpreter.start(project(
            script(block(.whenStarted), block(.forever, [:], [[light(.red), waitBlock(0.01)]])),
            script(block(.whenStarted), runBlock(.a, seconds: 30), light(.white))
        ))
        try await eventually { await device.calls.contains("light red") }
        let running = await interpreter.state
        XCTAssertTrue(running.isRunning)
        XCTAssertFalse(running.activeBlocks.isEmpty)

        let start = Date()
        await interpreter.stop()
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)

        let state = await interpreter.state
        XCTAssertFalse(state.isRunning)
        XCTAssertTrue(state.activeBlocks.isEmpty)
        XCTAssertNil(state.errorMessage)
        let stops = await device.stopCount
        XCTAssertEqual(stops, 1)
        let calls = await device.calls
        XCTAssertFalse(calls.contains("done A"))
        XCTAssertFalse(calls.contains("light white"))

        // Plus rien ne s'exécute après l'arrêt.
        let count = calls.count
        try await Task.sleep(nanoseconds: 60_000_000)
        let later = await device.calls.count
        XCTAssertEqual(later, count)
    }

    func testStopProgramBlock() async {
        let device = MockDevice(timeScale: 1)
        let interpreter = Interpreter(device: device)
        await interpreter.run(project(
            script(block(.whenStarted), waitBlock(0.05), block(.stopProgram), light(.red)),
            script(block(.whenStarted), block(.forever, [:], [[waitBlock(0.01)]])),
            script(block(.whenButton), light(.blue))
        ))
        let calls = await device.calls
        XCTAssertEqual(calls, [])
        let state = await interpreter.state
        XCTAssertFalse(state.isRunning)
        XCTAssertNil(state.errorMessage)
    }

    func testRestartReplacesRunningProgram() async throws {
        let device = MockDevice(timeScale: 1)
        let interpreter = Interpreter(device: device)
        await interpreter.start(project(script(block(.whenStarted), runBlock(.a, seconds: 30))))
        try await eventually { await device.calls.count == 1 }
        await interpreter.run(project(script(block(.whenStarted), light(.pink))))
        let calls = await device.calls
        XCTAssertEqual(calls, ["run A 50 30.0s", "light pink"])
        let stops = await device.stopCount
        XCTAssertEqual(stops, 2)
    }

    // MARK: - Erreurs

    func testDeviceErrorStopsProgramAndNamesBlock() async {
        let device = MockDevice(timeScale: 1)
        await device.failOn(.external)
        let interpreter = Interpreter(device: device)
        let failing = runBlock(.external, seconds: 1)
        await interpreter.run(project(
            script(block(.whenStarted), waitBlock(0.03), block(.repeatTimes, ["times": .number(1)], [[failing]]), light(.red)),
            script(block(.whenStarted), runBlock(.a, seconds: 30))
        ))
        let state = await interpreter.state
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.errorMessage, "panne simulée")
        XCTAssertEqual(state.failedBlock, failing.id)
        let calls = await device.calls
        XCTAssertEqual(calls, ["run A 50 30.0s"])
    }

    func testMisplacedBlockIsReported() async {
        let device = MockDevice()
        let interpreter = Interpreter(device: device)
        let misplaced = block(.distance)
        await interpreter.run(project(script(block(.whenStarted), misplaced)))
        let state = await interpreter.state
        XCTAssertEqual(state.failedBlock, misplaced.id)
        XCTAssertEqual(state.errorMessage, EngineError.misplacedBlock(.distance).errorDescription)
    }

    // MARK: - Déclencheurs

    func testColorTriggerFiresOncePerRisingEdge() async throws {
        let device = MockDevice()
        let interpreter = Interpreter(device: device)
        await interpreter.start(project(script(
            block(.whenColor, ["color": .option("red")]), light(.red)
        )))
        try await Task.sleep(nanoseconds: 60_000_000)
        var calls = await device.calls
        XCTAssertEqual(calls, [])

        await device.set { $0.color = .red }
        try await eventually { await device.calls.count == 1 }
        // La couleur reste rouge : pas de nouveau départ.
        try await Task.sleep(nanoseconds: 100_000_000)
        calls = await device.calls
        XCTAssertEqual(calls, ["light red"])

        await device.set { $0.color = .blue }
        try await Task.sleep(nanoseconds: 60_000_000)
        await device.set { $0.color = .red }
        try await eventually { await device.calls.count == 2 }

        let state = await interpreter.state
        XCTAssertTrue(state.isRunning)
        await interpreter.stop()
    }

    func testDistanceTiltButtonAndShakeTriggers() async throws {
        let device = MockDevice()
        let interpreter = Interpreter(device: device)
        await interpreter.start(project(
            script(block(.whenDistanceBelow, ["distance": .number(4)]), light(.yellow)),
            script(block(.whenTilted, ["direction": .option(TiltDirection.left.rawValue)]), light(.purple)),
            script(block(.whenButton), light(.white)),
            script(block(.whenShaken), light(.orange))
        ))
        try await Task.sleep(nanoseconds: 60_000_000)
        let none = await device.calls
        XCTAssertEqual(none, [])

        await device.set { $0.distance = 6 }
        await device.set { $0.tiltX = 40 }
        try await Task.sleep(nanoseconds: 60_000_000)
        let stillNone = await device.calls
        XCTAssertEqual(stillNone, [])

        await device.set { $0.distance = 2 }
        try await eventually { await device.calls == ["light yellow"] }
        await device.set { $0.tiltX = -40 }
        try await eventually { await device.calls == ["light yellow", "light purple"] }
        await device.set { $0.buttonPressed = true }
        try await eventually { await device.calls.last == "light white" }
        await device.set { $0.shakeCount += 1 }
        try await eventually { await device.calls.last == "light orange" }
        let calls = await device.calls
        XCTAssertEqual(calls.count, 4)
        await interpreter.stop()
    }

    // MARK: - Surbrillance

    func testActiveBlocksFollowExecution() async {
        let device = MockDevice(timeScale: 0.05)
        let recorder = StateRecorder()
        let interpreter = Interpreter(device: device) { recorder.record($0) }
        let trigger = block(.whenStarted)
        let first = runBlock(.a, seconds: 1)
        let inner = runBlock(.b, seconds: 1)
        let loop = block(.repeatTimes, ["times": .number(1)], [[inner]])
        await interpreter.run(project(script(trigger, first, loop)))

        let states = recorder.states
        XCTAssertEqual(states.first?.isRunning, true)
        XCTAssertEqual(states.last?.isRunning, false)
        XCTAssertEqual(states.last?.activeBlocks, [])
        XCTAssertTrue(states.contains { $0.activeBlocks == [trigger.id, first.id] })
        XCTAssertTrue(states.contains { $0.activeBlocks == [trigger.id, loop.id, inner.id] })
        XCTAssertFalse(states.contains { $0.activeBlocks.contains(first.id) && $0.activeBlocks.contains(inner.id) })
    }
}
