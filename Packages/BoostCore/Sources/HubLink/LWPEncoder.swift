import Foundation

/// Encodage des messages descendants (app → hub).
public enum LWPEncoder {

    // MARK: - En-tête

    /// Ajoute l'en-tête commun : longueur, identifiant de hub (toujours 0), type (doc §3.1).
    public static func frame(_ type: MessageType, _ body: [UInt8]) -> Data {
        var total = body.count + 3
        var bytes: [UInt8] = []
        if total > 127 {
            // Longueur sur 2 octets (doc §3.2).
            total += 1
            bytes.append(UInt8(total & 0x7F) | 0x80)
            bytes.append(UInt8(total >> 7))
        } else {
            bytes.append(UInt8(total))
        }
        bytes.append(0x00)
        bytes.append(type.rawValue)
        bytes.append(contentsOf: body)
        return Data(bytes)
    }

    // MARK: - Hub

    public static func hubProperty(_ property: HubProperty, _ operation: HubPropertyOperation) -> Data {
        frame(.hubProperties, [property.rawValue, operation.rawValue])
    }

    public static func hubAction(_ action: HubAction) -> Data {
        frame(.hubActions, [action.rawValue])
    }

    // MARK: - Informations et entrées

    public static func portInformationRequest(port: UInt8, type: PortInformationType) -> Data {
        frame(.portInformationRequest, [port, type.rawValue])
    }

    public static func portModeInformationRequest(port: UInt8, mode: UInt8, type: ModeInformationType) -> Data {
        frame(.portModeInformationRequest, [port, mode, type.rawValue])
    }

    /// Port Input Format Setup (Single) (doc §3.17).
    public static func portInputFormatSetup(port: UInt8, mode: UInt8, deltaInterval: UInt32, notify: Bool) -> Data {
        frame(.portInputFormatSetupSingle, [port, mode] + le32(deltaInterval) + [notify ? 1 : 0])
    }

    // MARK: - Port Output Command

    /// Forme générale (doc §3.26.1).
    public static func portOutputCommand(port: UInt8,
                                         startupCompletion: UInt8 = StartupCompletion.immediateWithFeedback,
                                         subCommand: OutputSubCommand,
                                         payload: [UInt8]) -> Data {
        frame(.portOutputCommand, [port, startupCompletion, subCommand.rawValue] + payload)
    }

    /// StartPower : puissance brute, 0 = roue libre, 127 = frein (doc §3.27.1 et §6.1).
    public static func startPower(port: UInt8, power: Int8) -> Data {
        portOutputCommand(port: port, subCommand: .writeDirectModeData, payload: [0x00, u8(power)])
    }

    /// StartSpeed, sans limite de durée (doc §3.27.5).
    public static func startSpeed(port: UInt8, speed: Int8, maxPower: UInt8 = 100, useProfile: UInt8 = 0) -> Data {
        portOutputCommand(port: port, subCommand: .startSpeed, payload: [u8(speed), maxPower, useProfile])
    }

    /// StartSpeed sur port virtuel, une vitesse par moteur (doc §3.27.6).
    public static func startSpeedDual(port: UInt8, speedLeft: Int8, speedRight: Int8,
                                      maxPower: UInt8 = 100, useProfile: UInt8 = 0) -> Data {
        portOutputCommand(port: port, subCommand: .startSpeedDual,
                          payload: [u8(speedLeft), u8(speedRight), maxPower, useProfile])
    }

    /// StartSpeedForTime (doc §3.27.7). La durée est un Int16 : 32 767 ms au maximum.
    public static func startSpeedForTime(port: UInt8, milliseconds: UInt16, speed: Int8, maxPower: UInt8 = 100,
                                         endState: MotorEndState = .brake, useProfile: UInt8 = 0) -> Data {
        portOutputCommand(port: port, subCommand: .startSpeedForTime,
                          payload: le16(milliseconds) + [u8(speed), maxPower, endState.rawValue, useProfile])
    }

    /// StartSpeedForTime sur port virtuel (doc §3.27.8).
    public static func startSpeedForTimeDual(port: UInt8, milliseconds: UInt16, speedLeft: Int8, speedRight: Int8,
                                             maxPower: UInt8 = 100, endState: MotorEndState = .brake,
                                             useProfile: UInt8 = 0) -> Data {
        portOutputCommand(port: port, subCommand: .startSpeedForTimeDual,
                          payload: le16(milliseconds) + [u8(speedLeft), u8(speedRight), maxPower, endState.rawValue, useProfile])
    }

    /// StartSpeedForDegrees (doc §3.27.9). Le sens est donné par le signe de la vitesse.
    public static func startSpeedForDegrees(port: UInt8, degrees: UInt32, speed: Int8, maxPower: UInt8 = 100,
                                            endState: MotorEndState = .brake, useProfile: UInt8 = 0) -> Data {
        portOutputCommand(port: port, subCommand: .startSpeedForDegrees,
                          payload: le32(degrees) + [u8(speed), maxPower, endState.rawValue, useProfile])
    }

    /// StartSpeedForDegrees sur port virtuel (doc §3.27.10).
    public static func startSpeedForDegreesDual(port: UInt8, degrees: UInt32, speedLeft: Int8, speedRight: Int8,
                                                maxPower: UInt8 = 100, endState: MotorEndState = .brake,
                                                useProfile: UInt8 = 0) -> Data {
        portOutputCommand(port: port, subCommand: .startSpeedForDegreesDual,
                          payload: le32(degrees) + [u8(speedLeft), u8(speedRight), maxPower, endState.rawValue, useProfile])
    }

    /// GotoAbsolutePosition (doc §3.27.11).
    public static func gotoAbsolutePosition(port: UInt8, position: Int32, speed: Int8, maxPower: UInt8 = 100,
                                            endState: MotorEndState = .brake, useProfile: UInt8 = 0) -> Data {
        portOutputCommand(port: port, subCommand: .gotoAbsolutePosition,
                          payload: le32(UInt32(bitPattern: position)) + [u8(speed), maxPower, endState.rawValue, useProfile])
    }

    /// PresetEncoder : écrit la position du moteur, 0 = remise à zéro (doc §6.1).
    public static func presetEncoder(port: UInt8, position: Int32) -> Data {
        portOutputCommand(port: port, subCommand: .writeDirectModeData,
                          payload: [DefaultMode.motorPosition] + le32(UInt32(bitPattern: position)))
    }

    /// SetRgbColorNo : couleur prédéfinie 0 à 10 (doc §6.1).
    public static func setLEDColor(port: UInt8, colorIndex: UInt8) -> Data {
        portOutputCommand(port: port, subCommand: .writeDirectModeData,
                          payload: [DefaultMode.ledColorIndex, colorIndex])
    }

    // MARK: - Utilitaires

    private static func u8(_ value: Int8) -> UInt8 { UInt8(bitPattern: value) }

    private static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
    }
}
