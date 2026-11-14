import Foundation

/// Rôle d'un port, indépendant de son numéro : les numéros sont lus dans
/// les messages Hub Attached I/O, jamais codés en dur.
public enum LogicalPort: String, Codable, Sendable, CaseIterable {
    case motorA
    case motorB
    case motorAB
    case motorExternal
    case led
    case visionSensor
    case tilt
}

/// Appareil annoncé par le hub sur un port.
public struct AttachedDevice: Equatable, Sendable {
    public var port: UInt8
    public var ioType: IOType
    /// Ports réels qui composent un port virtuel, sinon nil.
    public var members: [UInt8]?

    public init(port: UInt8, ioType: IOType, members: [UInt8]? = nil) {
        self.port = port
        self.ioType = ioType
        self.members = members
    }
}

/// Photographie de l'état du hub, publiée à chaque changement.
public struct HubState: Equatable, Sendable {
    public var connection: TransportState = .idle
    public var batteryPercent: Int?
    public var buttonPressed = false
    public var devices: [UInt8: AttachedDevice] = [:]

    /// Couleur vue par le capteur, nil si aucune.
    public var color: SensorColor?
    /// Distance brute du capteur, 0 (contact) à 10 (loin), nil si rien en vue.
    /// NON DOCUMENTÉ : l'unité n'est pas précisée par la doc officielle.
    public var distance: Int?
    /// Angles d'inclinaison en degrés.
    public var tiltX = 0
    public var tiltY = 0
    /// Augmente de 1 à chaque secousse détectée.
    public var shakeCount = 0
    /// Position de chaque moteur en degrés, par numéro de port.
    public var motorPositions: [UInt8: Int] = [:]

    public init() {}

    public var isConnected: Bool { connection.isConnected }

    /// Numéro de port réel d'un rôle, nil si l'appareil est absent.
    public func portID(for logical: LogicalPort) -> UInt8? {
        let internalMotors = devices.values
            .filter { $0.ioType == .internalMotorTacho && $0.members == nil }
            .map(\.port)
            .sorted()
        switch logical {
        case .motorA:
            return internalMotors.first
        case .motorB:
            return internalMotors.count > 1 ? internalMotors[1] : nil
        case .motorAB:
            guard internalMotors.count > 1 else { return nil }
            let pair = Set(internalMotors.prefix(2))
            return devices.values.first { device in
                guard let members = device.members else { return false }
                return Set(members) == pair
            }?.port
        case .motorExternal:
            return firstPort(of: .externalMotorTacho)
        case .led:
            return firstPort(of: .rgbLight)
        case .visionSensor:
            return firstPort(of: .visionSensor)
        case .tilt:
            return firstPort(of: .internalTilt)
        }
    }

    /// Position d'un moteur en degrés. Pour A+B, moyenne des deux moteurs.
    public func motorPosition(_ logical: LogicalPort) -> Int? {
        if logical == .motorAB {
            guard let a = motorPosition(.motorA), let b = motorPosition(.motorB) else { return nil }
            return (a + b) / 2
        }
        guard let port = portID(for: logical) else { return nil }
        return motorPositions[port]
    }

    private func firstPort(of type: IOType) -> UInt8? {
        devices.values.filter { $0.ioType == type && $0.members == nil }.map(\.port).min()
    }
}

/// Issue d'une commande moteur attendue jusqu'à son terme.
public enum CommandOutcome: Equatable, Sendable {
    /// Le hub a signalé la fin de la commande.
    case completed
    /// La commande a été remplacée ou interrompue avant sa fin.
    case discarded
    /// Aucun retour du hub dans le délai prévu.
    case timedOut
}

public enum HubError: Error, Equatable, LocalizedError {
    case notConnected
    case deviceMissing(LogicalPort)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Le hub n'est pas connecté."
        case .deviceMissing(let port):
            return "Aucun appareil pour « \(port.rawValue) » sur le hub."
        }
    }
}

/// Ligne du journal de la couche BLE.
public struct HubLogEntry: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable {
        case sent
        case received
        case info
        case warning
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String, date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.kind = kind
        self.text = text
    }
}
