import Foundation

/// Valeurs des capteurs à un instant donné.
public struct SensorSnapshot: Equatable, Sendable {
    /// Couleur vue par le capteur, nil si aucune.
    public var color: DetectedColor?
    /// Distance sur l'échelle brute du capteur (0 = contact, 10 = loin), nil si rien en vue.
    public var distance: Double?
    /// Angles d'inclinaison en degrés.
    public var tiltX: Double
    public var tiltY: Double
    /// Compteur qui augmente à chaque secousse.
    public var shakeCount: Int
    public var buttonPressed: Bool
    /// Rotation de chaque moteur en degrés.
    public var rotations: [MotorTarget: Double]

    public init(color: DetectedColor? = nil, distance: Double? = nil, tiltX: Double = 0, tiltY: Double = 0,
                shakeCount: Int = 0, buttonPressed: Bool = false, rotations: [MotorTarget: Double] = [:]) {
        self.color = color
        self.distance = distance
        self.tiltX = tiltX
        self.tiltY = tiltY
        self.shakeCount = shakeCount
        self.buttonPressed = buttonPressed
        self.rotations = rotations
    }
}

/// Matériel piloté par l'interpréteur. Le moteur d'exécution ne connaît que ce
/// protocole : l'app en fournit une implémentation branchée sur la couche BLE.
public protocol RobotDevice: Sendable {
    /// Les fonctions `run…` ne rendent la main qu'à la fin réelle du mouvement.
    func runMotor(_ target: MotorTarget, speed: Int, seconds: Double) async throws
    func runMotor(_ target: MotorTarget, speed: Int, degrees: Int) async throws
    func runTank(left: Int, right: Int, seconds: Double) async throws
    func runTank(left: Int, right: Int, degrees: Int) async throws
    /// Démarre sans limite de durée et rend la main aussitôt.
    func startMotor(_ target: MotorTarget, speed: Int) async throws
    func stopMotor(_ target: MotorTarget) async throws
    func resetRotation(_ target: MotorTarget) async throws
    func setLight(_ color: LightColor) async throws
    /// Rend la main à la fin du son.
    func playSound(_ sound: SoundID) async throws
    /// Arrête moteurs et sons. Appelé à la fin ou à l'arrêt d'un programme.
    func stopEverything() async
    func sensors() async -> SensorSnapshot
}
