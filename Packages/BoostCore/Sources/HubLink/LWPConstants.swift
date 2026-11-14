import Foundation

// Constantes du protocole public « LEGO Wireless Protocol 3.0 ».
// Source : https://lego.github.io/lego-ble-wireless-protocol-docs/
// Tout ce qui ne vient PAS de cette documentation est marqué « NON DOCUMENTÉ ».

/// Identifiants GATT et publicité (doc §2 et §3).
public enum LWP {
    public static let serviceUUID = "00001623-1212-EFDE-1623-785FEABCD123"
    public static let characteristicUUID = "00001624-1212-EFDE-1623-785FEABCD123"
    /// Identifiant fabricant présent dans les données de publicité (doc §2).
    public static let manufacturerID: UInt16 = 0x0397
    /// Octet « System Type and Device Number » du hub visé : 010 00000 (doc §2.1).
    public static let moveHubSystemType: UInt8 = 0x40
}

/// Types de message (doc §3.3).
public enum MessageType: UInt8, Sendable {
    case hubProperties = 0x01
    case hubActions = 0x02
    case hubAlerts = 0x03
    case hubAttachedIO = 0x04
    case genericError = 0x05
    case portInformationRequest = 0x21
    case portModeInformationRequest = 0x22
    case portInputFormatSetupSingle = 0x41
    case portInformation = 0x43
    case portModeInformation = 0x44
    case portValueSingle = 0x45
    case portValueCombined = 0x46
    case portInputFormatSingle = 0x47
    case portOutputCommand = 0x81
    case portOutputCommandFeedback = 0x82
}

/// Propriétés du hub (doc §3.5.3). Seules celles utilisées par l'app sont nommées.
public enum HubProperty: UInt8, Sendable {
    case advertisingName = 0x01
    case button = 0x02
    case firmwareVersion = 0x03
    case batteryVoltage = 0x06
}

/// Opérations sur une propriété (doc §3.5.4).
public enum HubPropertyOperation: UInt8, Sendable {
    case set = 0x01
    case enableUpdates = 0x02
    case disableUpdates = 0x03
    case reset = 0x04
    case requestUpdate = 0x05
    case update = 0x06
}

/// Actions du hub (doc §3.6.2).
public enum HubAction: UInt8, Sendable {
    case switchOff = 0x01
    case disconnect = 0x02
    case willSwitchOff = 0x30
    case willDisconnect = 0x31
}

/// Type d'appareil branché sur un port (doc §3.8.4, liste « non garantie à jour »).
public struct IOType: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let voltage = IOType(rawValue: 0x0014)
    public static let current = IOType(rawValue: 0x0015)
    public static let rgbLight = IOType(rawValue: 0x0017)
    public static let visionSensor = IOType(rawValue: 0x0025)
    public static let externalMotorTacho = IOType(rawValue: 0x0026)
    public static let internalMotorTacho = IOType(rawValue: 0x0027)
    public static let internalTilt = IOType(rawValue: 0x0028)

    public var isTachoMotor: Bool { self == .externalMotorTacho || self == .internalMotorTacho }

    public var description: String {
        switch self {
        case .voltage: return "tension"
        case .current: return "courant"
        case .rgbLight: return "LED RVB"
        case .visionSensor: return "capteur couleur/distance"
        case .externalMotorTacho: return "moteur externe"
        case .internalMotorTacho: return "moteur interne"
        case .internalTilt: return "capteur d'inclinaison"
        default: return String(format: "type 0x%04X", rawValue)
        }
    }
}

/// Sous-commandes de Port Output Command (doc §3.27 à §3.29).
public enum OutputSubCommand: UInt8, Sendable {
    case startSpeed = 0x07
    case startSpeedDual = 0x08
    case startSpeedForTime = 0x09
    case startSpeedForTimeDual = 0x0A
    case startSpeedForDegrees = 0x0B
    case startSpeedForDegreesDual = 0x0C
    case gotoAbsolutePosition = 0x0D
    case writeDirectModeData = 0x51
}

/// État du moteur en fin de commande (doc §3.27.7).
public enum MotorEndState: UInt8, Sendable, Codable {
    case float = 0
    case hold = 126
    case brake = 127
}

/// Valeurs spéciales de StartPower (doc §3.27.1).
public enum MotorPower {
    public static let float: Int8 = 0
    public static let brake: Int8 = 127
}

/// Champ de bits de Port Output Command Feedback (doc §3.32.1).
public struct FeedbackFlags: OptionSet, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let inProgress = FeedbackFlags(rawValue: 0x01)
    public static let completed = FeedbackFlags(rawValue: 0x02)
    public static let discarded = FeedbackFlags(rawValue: 0x04)
    public static let idle = FeedbackFlags(rawValue: 0x08)
    public static let busyFull = FeedbackFlags(rawValue: 0x10)

    public var description: String {
        var parts: [String] = []
        if contains(.inProgress) { parts.append("en cours") }
        if contains(.completed) { parts.append("terminé") }
        if contains(.discarded) { parts.append("abandonné") }
        if contains(.idle) { parts.append("repos") }
        if contains(.busyFull) { parts.append("tampon plein") }
        return parts.isEmpty ? "aucun" : parts.joined(separator: "+")
    }
}

/// Octet « Startup and Completion » (doc §3.26.2).
public enum StartupCompletion {
    /// Exécution immédiate (0001) + retour d'état demandé (0001).
    public static let immediateWithFeedback: UInt8 = 0x11
    /// Exécution immédiate, sans retour d'état.
    public static let immediateNoFeedback: UInt8 = 0x10
}

/// Types d'information de Port Information Request (doc §3.15.2).
public enum PortInformationType: UInt8, Sendable {
    case portValue = 0x00
    case modeInfo = 0x01
    case modeCombinations = 0x02
}

/// Types d'information de Port Mode Information Request (doc §3.16.2).
public enum ModeInformationType: UInt8, Sendable {
    case name = 0x00
    case valueFormat = 0x80
}

/// Modes d'entrée utilisés par l'app.
///
/// La documentation ne liste pas les modes de chaque capteur : elle demande de
/// les interroger (Port Mode Information). Les numéros ci-dessous sont donc
/// des valeurs par défaut, vérifiées à la connexion grâce au nom du mode.
public enum DefaultMode {
    /// Position du moteur en degrés, Int32. Documenté indirectement : PresetEncoder
    /// écrit la position en mode 2 (doc §6.1).
    public static let motorPosition: UInt8 = 2
    public static let motorPositionName = "POS"

    /// NON DOCUMENTÉ (connaissance communautaire) : mode 8 du capteur couleur/distance,
    /// 4 octets = couleur, distance, état LED, lumière réfléchie.
    public static let visionCombined: UInt8 = 8
    public static let visionCombinedName = "SPEC 1"

    /// NON DOCUMENTÉ (connaissance communautaire) : mode 0 du capteur d'inclinaison
    /// interne, 2 octets signés = angles X et Y en degrés.
    public static let tiltAngle: UInt8 = 0
    public static let tiltAngleName = "ANGLE"

    /// Mode 0 de la LED : couleur par numéro (doc §6.1, SetRgbColorNo).
    public static let ledColorIndex: UInt8 = 0
}

/// Couleurs prédéfinies de la LED du hub, numéros 0 à 10 (doc §3.27.20).
/// NON DOCUMENTÉ : la correspondance numéro → teinte vient de la communauté.
public enum LEDColor: UInt8, CaseIterable, Sendable, Codable {
    case off = 0
    case pink = 1
    case purple = 2
    case blue = 3
    case lightBlue = 4
    case cyan = 5
    case green = 6
    case yellow = 7
    case orange = 8
    case red = 9
    case white = 10
}

/// Couleur vue par le capteur.
/// NON DOCUMENTÉ : numéros issus de la communauté (0 noir, 3 bleu, 5 vert,
/// 7 jaune, 9 rouge, 10 blanc ; 0xFF = aucune couleur).
public enum SensorColor: UInt8, CaseIterable, Sendable, Codable {
    case black = 0
    case blue = 3
    case green = 5
    case yellow = 7
    case red = 9
    case white = 10
}
