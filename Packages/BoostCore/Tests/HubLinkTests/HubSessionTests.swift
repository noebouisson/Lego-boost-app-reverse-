import XCTest
@testable import HubLink

final class HubSessionTests: XCTestCase {

    /// Faux hub accéléré : 1 s simulée = 20 ms réelles.
    private func makeSession(configure: (inout SimulatedTransport.Configuration) -> Void = { _ in })
        async throws -> (HubSession, SimulatedTransport, LogCollector) {
        var configuration = SimulatedTransport.Configuration()
        configuration.timeScale = 0.02
        configure(&configuration)
        let transport = SimulatedTransport(configuration: configuration)
        let collector = LogCollector(transport.commandLog.stream())
        let session = HubSession(transport: transport)
        await session.connect()
        let expectsVision = configuration.hasVisionSensor
        try await waitFor(session) { state in
            state.isConnected && state.batteryPercent != nil && state.portID(for: .motorAB) != nil
                && state.portID(for: .tilt) != nil && state.motorPosition(.motorB) != nil
                && (!expectsVision || state.portID(for: .visionSensor) != nil)
        }
        return (session, transport, collector)
    }

    private func waitFor(_ session: HubSession, timeout: TimeInterval = 5,
                         file: StaticString = #filePath, line: UInt = #line,
                         _ condition: @escaping @Sendable (HubState) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(await session.state) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition non atteinte", file: file, line: line)
        throw CancellationError()
    }

    func testDiscoversPortsFromAttachedIO() async throws {
        let (session, _, _) = try await makeSession()
        let state = await session.state
        XCTAssertEqual(state.portID(for: .motorA), 0x00)
        XCTAssertEqual(state.portID(for: .motorB), 0x01)
        XCTAssertEqual(state.portID(for: .motorAB), 0x10)
        XCTAssertEqual(state.portID(for: .motorExternal), 0x03)
        XCTAssertEqual(state.portID(for: .led), 0x32)
        XCTAssertEqual(state.batteryPercent, 100)
    }

    func testRunForTimeWaitsForCompletion() async throws {
        let (session, _, collector) = try await makeSession()
        let start = Date()
        let outcome = try await session.run(.motorA, speed: 50, milliseconds: 2000)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(outcome, .completed)
        // 2 s simulées = 40 ms réelles au minimum.
        XCTAssertGreaterThan(elapsed, 0.035)
        XCTAssertLessThan(elapsed, 2.0)
        XCTAssertTrue(collector.lines.contains("Moteur A : vitesse 50 % pendant 2000 ms"))
        // 2 s à 50 % de 900°/s = 900°.
        try await waitFor(session) { abs(($0.motorPosition(.motorA) ?? 0) - 900) <= 2 }
    }

    func testRunForDegreesMovesMotorAndHandlesNegativeAngle() async throws {
        let (session, _, collector) = try await makeSession()
        let forward = try await session.run(.motorExternal, speed: 100, degrees: 360)
        XCTAssertEqual(forward, .completed)
        try await waitFor(session) { abs(($0.motorPosition(.motorExternal) ?? 0) - 360) <= 2 }

        let backward = try await session.run(.motorExternal, speed: 100, degrees: -360)
        XCTAssertEqual(backward, .completed)
        try await waitFor(session) { abs($0.motorPosition(.motorExternal) ?? 99) <= 2 }
        XCTAssertTrue(collector.lines.contains("Moteur externe : vitesse -100 % sur 360°"))
    }

    func testTankUsesVirtualPort() async throws {
        let (session, _, collector) = try await makeSession()
        let outcome = try await session.runTank(left: 50, right: -50, milliseconds: 1000)
        XCTAssertEqual(outcome, .completed)
        XCTAssertTrue(collector.lines.contains("Moteurs A+B : vitesses 50 % et -50 % pendant 1000 ms"))
        try await waitFor(session) { state in
            abs((state.motorPosition(.motorA) ?? 0) - 450) <= 2 && abs((state.motorPosition(.motorB) ?? 0) + 450) <= 2
        }
    }

    func testNewCommandDiscardsPreviousOne() async throws {
        let (session, _, _) = try await makeSession()
        async let first = session.run(.motorA, speed: 20, milliseconds: 20_000)
        try await Task.sleep(nanoseconds: 50_000_000)
        let second = try await session.run(.motorA, speed: 80, milliseconds: 500)
        let firstOutcome = try await first
        XCTAssertEqual(firstOutcome, .discarded)
        XCTAssertEqual(second, .completed)
    }

    func testStoppingMembersInterruptsVirtualPort() async throws {
        let (session, _, _) = try await makeSession()
        async let tank = session.runTank(left: 30, right: 30, milliseconds: 20_000)
        try await Task.sleep(nanoseconds: 50_000_000)
        try await session.stop(.motorAB)
        let outcome = try await tank
        XCTAssertEqual(outcome, .discarded)
    }

    func testCancellationThrowsAndStopAllMotors() async throws {
        let (session, _, collector) = try await makeSession()
        let task = Task { try await session.run(.motorB, speed: 40, milliseconds: 25_000) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("la commande aurait dû être annulée")
        } catch is CancellationError {
        }
        await session.stopAllMotors()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(collector.lines.contains("Moteur B : arrêt (frein)"))
    }

    func testLongRunFallsBackToStartThenStop() async throws {
        // 40 s dépasse la limite Int16 du protocole ; ici l'attente locale est réelle,
        // on vérifie donc seulement l'annulation et l'arrêt qui suit.
        let (session, _, collector) = try await makeSession()
        let task = Task { try await session.run(.motorA, speed: 60, milliseconds: 40_000) }
        try await Task.sleep(nanoseconds: 80_000_000)
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(collector.lines.contains("Moteur A : vitesse 60 %"))
        XCTAssertTrue(collector.lines.contains("Moteur A : arrêt (frein)"))
    }

    func testSensorsLEDAndButton() async throws {
        let (session, transport, collector) = try await makeSession()
        transport.inject(.color(SensorColor.red.rawValue))
        transport.inject(.distance(4))
        try await waitFor(session) { $0.color == .red && $0.distance == 4 }

        transport.inject(.color(nil))
        transport.inject(.distance(nil))
        try await waitFor(session) { $0.color == nil && $0.distance == nil }

        transport.inject(.button(true))
        try await waitFor(session) { $0.buttonPressed }
        transport.inject(.battery(42))
        try await waitFor(session) { $0.batteryPercent == 42 }

        try await session.setLED(.green)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(collector.lines.contains("LED : couleur n° 6"))
    }

    func testTiltAndShakeDetection() async throws {
        let (session, transport, _) = try await makeSession()
        transport.inject(.tilt(x: 10, y: -5))
        try await waitFor(session) { $0.tiltX == 10 && $0.tiltY == -5 }
        let before = await session.state.shakeCount
        transport.inject(.tilt(x: -30, y: 20))
        try await waitFor(session) { $0.shakeCount == before + 1 }
    }

    func testResetRotation() async throws {
        let (session, _, _) = try await makeSession()
        _ = try await session.run(.motorA, speed: 100, degrees: 180)
        try await session.resetRotation(.motorA)
        try await Task.sleep(nanoseconds: 50_000_000)
        let position = await session.state.motorPosition(.motorA)
        XCTAssertEqual(position, 0)
    }

    func testMissingDeviceAndDisconnection() async throws {
        let (session, _, _) = try await makeSession { $0.hasExternalMotor = false; $0.hasVisionSensor = false }
        do {
            _ = try await session.run(.motorExternal, speed: 50, milliseconds: 100)
            XCTFail("une erreur était attendue")
        } catch let error as HubError {
            XCTAssertEqual(error, .deviceMissing(.motorExternal))
        }

        async let pending = session.run(.motorA, speed: 50, milliseconds: 20_000)
        try await Task.sleep(nanoseconds: 50_000_000)
        await session.disconnect()
        do {
            _ = try await pending
            XCTFail("une erreur était attendue")
        } catch let error as HubError {
            XCTAssertEqual(error, .notConnected)
        }
        let state = await session.state
        XCTAssertFalse(state.isConnected)
        XCTAssertTrue(state.devices.isEmpty)
    }

    func testModeNamesAreCheckedWithoutWarning() async throws {
        var configuration = SimulatedTransport.Configuration()
        configuration.timeScale = 0.02
        let transport = SimulatedTransport(configuration: configuration)
        let session = HubSession(transport: transport)
        let entries = EntryCollector(session.log.stream())
        await session.connect()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(entries.all.contains { $0.kind == .info && $0.text.contains("« SPEC 1 »") })
        XCTAssertFalse(entries.all.contains { $0.kind == .warning })
    }
}

/// Accumule les lignes du journal du faux hub.
final class LogCollector: @unchecked Sendable {
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

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

final class EntryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HubLogEntry] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<HubLogEntry>) {
        task = Task { [weak self] in
            for await entry in stream { self?.append(entry) }
        }
    }

    deinit { task?.cancel() }

    private func append(_ entry: HubLogEntry) {
        lock.lock(); storage.append(entry); lock.unlock()
    }

    var all: [HubLogEntry] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
