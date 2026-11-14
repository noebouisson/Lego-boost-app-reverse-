import Foundation

/// Type d'un bloc. La valeur brute est celle écrite dans les fichiers de projet.
public enum Opcode: String, Codable, CaseIterable, Sendable {
    // Déclencheurs
    case whenStarted
    case whenColor
    case whenDistanceBelow
    case whenTilted
    case whenShaken
    case whenButton

    // Actions
    case motorRunForSeconds
    case motorRunForDegrees
    case motorStart
    case motorStop
    case tankRunForSeconds
    case tankRunForDegrees
    case resetRotation
    case setLight
    case playSound

    // Contrôle
    case wait
    case repeatTimes
    case forever
    case ifElse
    case waitUntil
    case stopProgram

    // Capteurs
    case colorIs
    case distance
    case tiltAngle
    case isTilted
    case isButtonPressed
    case motorRotation

    // Données
    case setVariable
    case changeVariable
    case variableValue
    case math
    case random
    case compare
    case and
    case or
    case not
}

/// Moteur ou paire de moteurs visé par un bloc.
public enum MotorTarget: String, Codable, CaseIterable, Sendable {
    case a = "A"
    case b = "B"
    case ab = "AB"
    case external = "EXT"
}

/// Couleurs reconnues par le capteur.
public enum DetectedColor: String, Codable, CaseIterable, Sendable {
    case black, blue, green, yellow, red, white
}

/// Couleurs de la lumière du hub.
public enum LightColor: String, Codable, CaseIterable, Sendable {
    case off, pink, purple, blue, lightBlue, cyan, green, yellow, orange, red, white
}

/// Sons synthétisés par l'iPad.
public enum SoundID: String, Codable, CaseIterable, Sendable {
    case beep, doubleBeep, rise, fall, success, error, laser, robot
}

/// Sens d'inclinaison du hub.
public enum TiltDirection: String, Codable, CaseIterable, Sendable {
    case any, forward, backward, left, right
}

/// Axe d'inclinaison du hub.
public enum TiltAxis: String, Codable, CaseIterable, Sendable {
    case x, y
}
