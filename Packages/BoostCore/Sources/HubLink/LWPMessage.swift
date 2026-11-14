import Foundation

/// Message montant (hub → app) décodé.
public enum LWPMessage: Equatable, Sendable {
    case hubProperty(HubPropertyUpdate)
    case hubAction(UInt8)
    case hubAlert(type: UInt8, operation: UInt8, payload: UInt8?)
    case attachedIO(AttachedIOEvent)
    case error(commandType: UInt8, code: UInt8)
    case portInformation(PortInformation)
    case portModeInformation(PortModeInformation)
    case portValue(port: UInt8, payload: Data)
    case portInputFormat(PortInputFormat)
    case outputFeedback([PortFeedback])
    case unknown(type: UInt8, payload: Data)
}

/// Hub Properties, opération Update (doc §3.5).
public struct HubPropertyUpdate: Equatable, Sendable {
    public var property: UInt8
    public var operation: UInt8
    public var payload: Data

    public init(property: UInt8, operation: UInt8, payload: Data) {
        self.property = property
        self.operation = operation
        self.payload = payload
    }

    /// Niveau de batterie en pourcentage (propriété 0x06).
    public var batteryPercent: Int? {
        guard property == HubProperty.batteryVoltage.rawValue, let first = payload.first else { return nil }
        return Int(first)
    }

    /// État du bouton (propriété 0x02).
    public var buttonPressed: Bool? {
        guard property == HubProperty.button.rawValue, let first = payload.first else { return nil }
        return first != 0
    }

    /// Nom publicitaire (propriété 0x01).
    public var advertisingName: String? {
        guard property == HubProperty.advertisingName.rawValue else { return nil }
        return String(data: payload, encoding: .utf8)
    }
}

/// Hub Attached I/O (doc §3.8).
public enum AttachedIOEvent: Equatable, Sendable {
    case detached(port: UInt8)
    case attached(port: UInt8, ioType: IOType)
    case attachedVirtual(port: UInt8, ioType: IOType, portA: UInt8, portB: UInt8)

    public var port: UInt8 {
        switch self {
        case .detached(let port): return port
        case .attached(let port, _): return port
        case .attachedVirtual(let port, _, _, _): return port
        }
    }
}

/// Port Information, type « Mode Info » (doc §3.19).
public struct PortInformation: Equatable, Sendable {
    public var port: UInt8
    public var informationType: UInt8
    public var capabilities: UInt8
    public var modeCount: UInt8
    public var inputModes: UInt16
    public var outputModes: UInt16
    /// Octets bruts pour le type « combinaisons possibles ».
    public var raw: Data
}

/// Port Mode Information (doc §3.20).
public struct PortModeInformation: Equatable, Sendable {
    public var port: UInt8
    public var mode: UInt8
    public var informationType: UInt8
    public var payload: Data

    /// Nom du mode (type 0x00), jusqu'à 11 caractères ASCII.
    public var name: String? {
        guard informationType == ModeInformationType.name.rawValue else { return nil }
        let bytes = payload.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Port Input Format (Single), accusé de réception de la configuration (doc §3.23).
public struct PortInputFormat: Equatable, Sendable {
    public var port: UInt8
    public var mode: UInt8
    public var deltaInterval: UInt32
    public var notificationEnabled: Bool
}

/// Un couple port / état dans Port Output Command Feedback (doc §3.32).
public struct PortFeedback: Equatable, Sendable {
    public var port: UInt8
    public var flags: FeedbackFlags

    public init(port: UInt8, flags: FeedbackFlags) {
        self.port = port
        self.flags = flags
    }
}

// MARK: - Lecture little-endian

extension Data {
    /// Octets en hexadécimal, pour le journal.
    public var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    func int8(at offset: Int) -> Int8? {
        guard offset >= 0, offset < count else { return nil }
        return Int8(bitPattern: self[startIndex + offset])
    }

    func uint16LE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let base = startIndex + offset
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func int32LE(at offset: Int) -> Int32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let base = startIndex + offset
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(self[base + index]) << (8 * UInt32(index))
        }
        return Int32(bitPattern: value)
    }
}
