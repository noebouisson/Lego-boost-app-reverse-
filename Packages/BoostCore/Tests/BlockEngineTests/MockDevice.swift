import Foundation
@testable import BlockEngine

/// Faux matériel : note chaque appel et simule la durée des mouvements.
actor MockDevice: RobotDevice {
    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "panne simulée" }
    }

    private(set) var calls: [String] = []
    private(set) var stopCount = 0
    private var snapshot = SensorSnapshot()
    private var failingTarget: MotorTarget?
    /// Durée réelle d'un mouvement, en secondes par seconde demandée.
    private let timeScale: Double
    /// Durée réelle d'un mouvement en degrés ou d'un son.
    private let fixedDuration: Double

    init(timeScale: Double = 0.05, fixedDuration: Double = 0.02) {
        self.timeScale = timeScale
        self.fixedDuration = fixedDuration
    }

    func set(_ change: @Sendable (inout SensorSnapshot) -> Void) {
        change(&snapshot)
    }

    func failOn(_ target: MotorTarget) {
        failingTarget = target
    }

    private func record(_ call: String) {
        calls.append(call)
    }

    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    func runMotor(_ target: MotorTarget, speed: Int, seconds: Double) async throws {
        if target == failingTarget { throw Failure() }
        record("run \(target.rawValue) \(speed) \(seconds)s")
        try await sleep(seconds * timeScale)
        record("done \(target.rawValue)")
    }

    func runMotor(_ target: MotorTarget, speed: Int, degrees: Int) async throws {
        if target == failingTarget { throw Failure() }
        record("run \(target.rawValue) \(speed) \(degrees)°")
        try await sleep(fixedDuration)
        snapshot.rotations[target, default: 0] += Double(speed < 0 ? -degrees : degrees)
        record("done \(target.rawValue)")
    }

    func runTank(left: Int, right: Int, seconds: Double) async throws {
        record("tank \(left) \(right) \(seconds)s")
        try await sleep(seconds * timeScale)
    }

    func runTank(left: Int, right: Int, degrees: Int) async throws {
        record("tank \(left) \(right) \(degrees)°")
        try await sleep(fixedDuration)
    }

    func startMotor(_ target: MotorTarget, speed: Int) async throws {
        record("start \(target.rawValue) \(speed)")
    }

    func stopMotor(_ target: MotorTarget) async throws {
        record("stop \(target.rawValue)")
    }

    func resetRotation(_ target: MotorTarget) async throws {
        snapshot.rotations[target] = 0
        record("reset \(target.rawValue)")
    }

    func setLight(_ color: LightColor) async throws {
        record("light \(color.rawValue)")
    }

    func playSound(_ sound: SoundID) async throws {
        record("sound \(sound.rawValue)")
        try await sleep(fixedDuration)
    }

    func stopEverything() async {
        stopCount += 1
    }

    func sensors() async -> SensorSnapshot {
        snapshot
    }
}

/// Accumule les états publiés par l'interpréteur.
final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ExecutionState] = []

    func record(_ state: ExecutionState) {
        lock.lock(); storage.append(state); lock.unlock()
    }

    var states: [ExecutionState] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

// MARK: - Construction de blocs pour les tests

func block(_ opcode: Opcode, _ inputs: [String: Value] = [:], _ branches: [[Block]] = []) -> Block {
    var result = BlockCatalog.makeBlock(opcode)
    for (key, value) in inputs { result.inputs[key] = value }
    if !branches.isEmpty { result.branches = branches }
    return result
}

func script(_ blocks: Block...) -> Script {
    Script(blocks: blocks)
}

func runBlock(_ target: MotorTarget, speed: Double = 50, seconds: Double) -> Block {
    block(.motorRunForSeconds, ["port": .option(target.rawValue), "speed": .number(speed), "seconds": .number(seconds)])
}

func light(_ color: LightColor) -> Block {
    block(.setLight, ["color": .option(color.rawValue)])
}

func waitBlock(_ seconds: Double) -> Block {
    block(.wait, ["seconds": .number(seconds)])
}

func variable(_ name: String) -> Value {
    .reporter(block(.variableValue, ["name": .variable(name)]))
}

func compare(_ a: Value, _ op: String, _ b: Value) -> Value {
    .reporter(block(.compare, ["a": a, "op": .option(op), "b": b]))
}

func math(_ a: Value, _ op: String, _ b: Value) -> Value {
    .reporter(block(.math, ["a": a, "op": .option(op), "b": b]))
}
