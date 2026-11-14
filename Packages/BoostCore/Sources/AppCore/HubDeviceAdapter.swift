import BlockEngine
import Foundation
import HubLink

/// Pont entre le moteur d'exécution et la couche BLE.
public final class HubDeviceAdapter: RobotDevice {
    private let session: HubSession
    private let sounds: SoundPlaying

    public init(session: HubSession, sounds: SoundPlaying) {
        self.session = session
        self.sounds = sounds
    }

    public func runMotor(_ target: MotorTarget, speed: Int, seconds: Double) async throws {
        try await session.run(Self.port(target), speed: speed, milliseconds: Self.milliseconds(seconds))
    }

    public func runMotor(_ target: MotorTarget, speed: Int, degrees: Int) async throws {
        try await session.run(Self.port(target), speed: speed, degrees: degrees)
    }

    public func runTank(left: Int, right: Int, seconds: Double) async throws {
        try await session.runTank(left: left, right: right, milliseconds: Self.milliseconds(seconds))
    }

    public func runTank(left: Int, right: Int, degrees: Int) async throws {
        try await session.runTank(left: left, right: right, degrees: degrees)
    }

    public func startMotor(_ target: MotorTarget, speed: Int) async throws {
        try await session.start(Self.port(target), speed: speed)
    }

    public func stopMotor(_ target: MotorTarget) async throws {
        try await session.stop(Self.port(target))
    }

    public func resetRotation(_ target: MotorTarget) async throws {
        try await session.resetRotation(Self.port(target))
    }

    public func setLight(_ color: LightColor) async throws {
        try await session.setLED(Self.led(color))
    }

    public func playSound(_ sound: SoundID) async throws {
        await sounds.play(sound)
        try Task.checkCancellation()
    }

    public func stopEverything() async {
        sounds.stopAll()
        await session.stopAllMotors()
    }

    public func sensors() async -> SensorSnapshot {
        Self.snapshot(from: await session.state)
    }

    // MARK: - Correspondances

    static func snapshot(from state: HubState) -> SensorSnapshot {
        var rotations: [MotorTarget: Double] = [:]
        for target in MotorTarget.allCases {
            if let position = state.motorPosition(port(target)) {
                rotations[target] = Double(position)
            }
        }
        return SensorSnapshot(color: state.color.map(detected), distance: state.distance.map(Double.init),
                              tiltX: Double(state.tiltX), tiltY: Double(state.tiltY),
                              shakeCount: state.shakeCount, buttonPressed: state.buttonPressed, rotations: rotations)
    }

    static func port(_ target: MotorTarget) -> LogicalPort {
        switch target {
        case .a: return .motorA
        case .b: return .motorB
        case .ab: return .motorAB
        case .external: return .motorExternal
        }
    }

    static func led(_ color: LightColor) -> LEDColor {
        switch color {
        case .off: return .off
        case .pink: return .pink
        case .purple: return .purple
        case .blue: return .blue
        case .lightBlue: return .lightBlue
        case .cyan: return .cyan
        case .green: return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .red: return .red
        case .white: return .white
        }
    }

    static func detected(_ color: SensorColor) -> DetectedColor {
        switch color {
        case .black: return .black
        case .blue: return .blue
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        case .white: return .white
        }
    }

    private static func milliseconds(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int(max(0, min(seconds, 86_400)) * 1000)
    }
}
