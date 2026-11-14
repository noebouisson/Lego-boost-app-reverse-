import Foundation

public enum BlockCategory: String, CaseIterable, Sendable {
    case triggers
    case actions
    case control
    case sensors
    case data

    public var title: String {
        switch self {
        case .triggers: return "Déclencheurs"
        case .actions: return "Actions"
        case .control: return "Contrôle"
        case .sensors: return "Capteurs"
        case .data: return "Données"
        }
    }
}

/// Forme d'un bloc, qui dit où il peut se placer.
public enum BlockShape: Sendable {
    /// En tête de séquence uniquement.
    case trigger
    /// Maillon d'une séquence.
    case statement
    /// Maillon qui contient une ou plusieurs sous-séquences.
    case container
    /// Valeur numérique, à déposer dans un paramètre.
    case number
    /// Condition, à déposer dans un paramètre booléen.
    case boolean

    /// Vrai si le bloc se place dans une séquence (et non dans un paramètre).
    public var isSequenceBlock: Bool {
        switch self {
        case .trigger, .statement, .container: return true
        case .number, .boolean: return false
        }
    }
}

public struct BlockOption: Equatable, Sendable {
    public var id: String
    public var label: String

    public init(_ id: String, _ label: String) {
        self.id = id
        self.label = label
    }
}

public enum InputKind: Equatable, Sendable {
    /// Nombre ; accepte un bloc de forme `number`.
    case number(defaultValue: Double, min: Double?, max: Double?)
    /// Condition ; accepte un bloc de forme `boolean`.
    case boolean
    /// Choix dans une liste fixe.
    case option([BlockOption], defaultID: String)
    /// Nom d'une variable du projet.
    case variable
}

public struct InputSpec: Equatable, Sendable {
    public var key: String
    public var kind: InputKind
}

/// Élément de l'étiquette d'un bloc : texte fixe ou paramètre.
public enum LayoutPiece: Equatable, Sendable {
    case text(String)
    case input(String)
}

public struct BlockSpec: Sendable {
    public var opcode: Opcode
    public var name: String
    public var category: BlockCategory
    public var shape: BlockShape
    /// Nom d'un symbole SF Symbols.
    public var symbol: String
    public var layout: [LayoutPiece]
    public var inputs: [InputSpec]
    /// Une étiquette par sous-séquence.
    public var branchLabels: [String]

    public func input(_ key: String) -> InputSpec? {
        inputs.first { $0.key == key }
    }
}

/// Description de tous les blocs : palette, rendu, valeurs par défaut.
public enum BlockCatalog {

    public static func spec(for opcode: Opcode) -> BlockSpec {
        // Le dictionnaire couvre tous les cas : vérifié par les tests.
        specs[opcode]!
    }

    /// Blocs d'une catégorie, dans l'ordre de la palette.
    public static func opcodes(in category: BlockCategory) -> [Opcode] {
        ordered.filter { specs[$0]?.category == category }
    }

    /// Crée un bloc avec ses paramètres par défaut.
    public static func makeBlock(_ opcode: Opcode, variable: String = defaultVariableName) -> Block {
        let spec = spec(for: opcode)
        var inputs: [String: Value] = [:]
        for input in spec.inputs {
            inputs[input.key] = defaultValue(for: input.kind, variable: variable)
        }
        return Block(opcode: opcode, inputs: inputs, branches: Array(repeating: [], count: spec.branchLabels.count))
    }

    public static func defaultValue(for kind: InputKind, variable: String = defaultVariableName) -> Value {
        switch kind {
        case .number(let defaultValue, _, _): return .number(defaultValue)
        case .boolean: return .bool(false)
        case .option(_, let defaultID): return .option(defaultID)
        case .variable: return .variable(variable)
        }
    }

    /// Vrai si un bloc de cette forme peut être déposé dans un paramètre de ce type.
    public static func accepts(_ kind: InputKind, shape: BlockShape) -> Bool {
        switch (kind, shape) {
        case (.number, .number), (.boolean, .boolean): return true
        default: return false
        }
    }

    public static let defaultVariableName = "compteur"

    // MARK: - Listes de choix

    public static let motorOptions = [
        BlockOption(MotorTarget.a.rawValue, "A"),
        BlockOption(MotorTarget.b.rawValue, "B"),
        BlockOption(MotorTarget.ab.rawValue, "A+B"),
        BlockOption(MotorTarget.external.rawValue, "externe"),
    ]

    public static let detectedColorOptions = [
        BlockOption(DetectedColor.red.rawValue, "rouge"),
        BlockOption(DetectedColor.yellow.rawValue, "jaune"),
        BlockOption(DetectedColor.green.rawValue, "vert"),
        BlockOption(DetectedColor.blue.rawValue, "bleu"),
        BlockOption(DetectedColor.white.rawValue, "blanc"),
        BlockOption(DetectedColor.black.rawValue, "noir"),
    ]

    public static let lightColorOptions = [
        BlockOption(LightColor.red.rawValue, "rouge"),
        BlockOption(LightColor.orange.rawValue, "orange"),
        BlockOption(LightColor.yellow.rawValue, "jaune"),
        BlockOption(LightColor.green.rawValue, "vert"),
        BlockOption(LightColor.cyan.rawValue, "turquoise"),
        BlockOption(LightColor.lightBlue.rawValue, "bleu clair"),
        BlockOption(LightColor.blue.rawValue, "bleu"),
        BlockOption(LightColor.purple.rawValue, "violet"),
        BlockOption(LightColor.pink.rawValue, "rose"),
        BlockOption(LightColor.white.rawValue, "blanc"),
        BlockOption(LightColor.off.rawValue, "éteinte"),
    ]

    public static let soundOptions = [
        BlockOption(SoundID.beep.rawValue, "bip"),
        BlockOption(SoundID.doubleBeep.rawValue, "double bip"),
        BlockOption(SoundID.rise.rawValue, "montée"),
        BlockOption(SoundID.fall.rawValue, "descente"),
        BlockOption(SoundID.success.rawValue, "réussite"),
        BlockOption(SoundID.error.rawValue, "erreur"),
        BlockOption(SoundID.laser.rawValue, "laser"),
        BlockOption(SoundID.robot.rawValue, "robot"),
    ]

    public static let tiltDirectionOptions = [
        BlockOption(TiltDirection.any.rawValue, "n'importe où"),
        BlockOption(TiltDirection.forward.rawValue, "vers l'avant"),
        BlockOption(TiltDirection.backward.rawValue, "vers l'arrière"),
        BlockOption(TiltDirection.left.rawValue, "à gauche"),
        BlockOption(TiltDirection.right.rawValue, "à droite"),
    ]

    public static let tiltAxisOptions = [
        BlockOption(TiltAxis.x.rawValue, "gauche-droite"),
        BlockOption(TiltAxis.y.rawValue, "avant-arrière"),
    ]

    public static let mathOptions = [
        BlockOption("+", "+"), BlockOption("-", "−"), BlockOption("*", "×"),
        BlockOption("/", "÷"), BlockOption("mod", "modulo"),
    ]

    public static let compareOptions = [
        BlockOption("<", "<"), BlockOption("=", "="), BlockOption(">", ">"),
    ]

    // MARK: - Définitions

    private static func number(_ key: String, _ value: Double, min: Double? = nil, max: Double? = nil) -> InputSpec {
        InputSpec(key: key, kind: .number(defaultValue: value, min: min, max: max))
    }

    private static func option(_ key: String, _ options: [BlockOption], _ defaultID: String) -> InputSpec {
        InputSpec(key: key, kind: .option(options, defaultID: defaultID))
    }

    private static func speed(_ key: String = "speed", _ value: Double = 50) -> InputSpec {
        number(key, value, min: -100, max: 100)
    }

    private static let motor = option("port", motorOptions, MotorTarget.a.rawValue)
    private static let condition = InputSpec(key: "condition", kind: .boolean)

    private static let definitions: [BlockSpec] = [
        // Déclencheurs
        BlockSpec(opcode: .whenStarted, name: "Au démarrage", category: .triggers, shape: .trigger, symbol: "play.fill",
                  layout: [.text("au démarrage")], inputs: [], branchLabels: []),
        BlockSpec(opcode: .whenColor, name: "Couleur détectée", category: .triggers, shape: .trigger, symbol: "eyedropper.halffull",
                  layout: [.text("quand la couleur est"), .input("color")],
                  inputs: [option("color", detectedColorOptions, DetectedColor.red.rawValue)], branchLabels: []),
        BlockSpec(opcode: .whenDistanceBelow, name: "Distance inférieure", category: .triggers, shape: .trigger,
                  symbol: "ruler", layout: [.text("quand la distance <"), .input("distance")],
                  inputs: [number("distance", 5, min: 0, max: 10)], branchLabels: []),
        BlockSpec(opcode: .whenTilted, name: "Hub incliné", category: .triggers, shape: .trigger, symbol: "rotate.3d",
                  layout: [.text("quand le hub penche"), .input("direction")],
                  inputs: [option("direction", tiltDirectionOptions, TiltDirection.any.rawValue)], branchLabels: []),
        BlockSpec(opcode: .whenShaken, name: "Hub secoué", category: .triggers, shape: .trigger, symbol: "waveform.path",
                  layout: [.text("quand le hub est secoué")], inputs: [], branchLabels: []),
        BlockSpec(opcode: .whenButton, name: "Bouton du hub", category: .triggers, shape: .trigger, symbol: "button.programmable",
                  layout: [.text("quand le bouton est pressé")], inputs: [], branchLabels: []),

        // Actions
        BlockSpec(opcode: .motorRunForSeconds, name: "Moteur pendant", category: .actions, shape: .statement, symbol: "timer",
                  layout: [.text("moteur"), .input("port"), .text("vitesse"), .input("speed"), .text("pendant"), .input("seconds"), .text("s")],
                  inputs: [motor, speed(), number("seconds", 1, min: 0)], branchLabels: []),
        BlockSpec(opcode: .motorRunForDegrees, name: "Moteur sur un angle", category: .actions, shape: .statement, symbol: "angle",
                  layout: [.text("moteur"), .input("port"), .text("vitesse"), .input("speed"), .text("sur"), .input("degrees"), .text("°")],
                  inputs: [motor, speed(), number("degrees", 360)], branchLabels: []),
        BlockSpec(opcode: .motorStart, name: "Démarrer le moteur", category: .actions, shape: .statement, symbol: "gearshape.fill",
                  layout: [.text("démarrer moteur"), .input("port"), .text("vitesse"), .input("speed")],
                  inputs: [motor, speed()], branchLabels: []),
        BlockSpec(opcode: .motorStop, name: "Arrêter le moteur", category: .actions, shape: .statement, symbol: "stop.fill",
                  layout: [.text("arrêter moteur"), .input("port")], inputs: [motor], branchLabels: []),
        BlockSpec(opcode: .tankRunForSeconds, name: "Rouler pendant", category: .actions, shape: .statement,
                  symbol: "arrow.triangle.branch",
                  layout: [.text("rouler A"), .input("left"), .text("B"), .input("right"), .text("pendant"), .input("seconds"), .text("s")],
                  inputs: [speed("left"), speed("right"), number("seconds", 1, min: 0)], branchLabels: []),
        BlockSpec(opcode: .tankRunForDegrees, name: "Rouler sur un angle", category: .actions, shape: .statement,
                  symbol: "arrow.triangle.turn.up.right.circle",
                  layout: [.text("rouler A"), .input("left"), .text("B"), .input("right"), .text("sur"), .input("degrees"), .text("°")],
                  inputs: [speed("left"), speed("right"), number("degrees", 360)], branchLabels: []),
        BlockSpec(opcode: .resetRotation, name: "Remettre la rotation à zéro", category: .actions, shape: .statement,
                  symbol: "gobackward", layout: [.text("rotation à zéro, moteur"), .input("port")],
                  inputs: [motor], branchLabels: []),
        BlockSpec(opcode: .setLight, name: "Couleur de la lumière", category: .actions, shape: .statement, symbol: "lightbulb.fill",
                  layout: [.text("lumière"), .input("color")],
                  inputs: [option("color", lightColorOptions, LightColor.green.rawValue)], branchLabels: []),
        BlockSpec(opcode: .playSound, name: "Jouer un son", category: .actions, shape: .statement, symbol: "speaker.wave.2.fill",
                  layout: [.text("jouer le son"), .input("sound")],
                  inputs: [option("sound", soundOptions, SoundID.beep.rawValue)], branchLabels: []),

        // Contrôle
        BlockSpec(opcode: .wait, name: "Attendre", category: .control, shape: .statement, symbol: "hourglass",
                  layout: [.text("attendre"), .input("seconds"), .text("s")],
                  inputs: [number("seconds", 1, min: 0)], branchLabels: []),
        BlockSpec(opcode: .repeatTimes, name: "Répéter", category: .control, shape: .container, symbol: "repeat",
                  layout: [.text("répéter"), .input("times"), .text("fois")],
                  inputs: [number("times", 3, min: 0)], branchLabels: [""]),
        BlockSpec(opcode: .forever, name: "Répéter indéfiniment", category: .control, shape: .container, symbol: "infinity",
                  layout: [.text("répéter indéfiniment")], inputs: [], branchLabels: [""]),
        BlockSpec(opcode: .ifElse, name: "Si / sinon", category: .control, shape: .container, symbol: "arrow.triangle.branch",
                  layout: [.text("si"), .input("condition")], inputs: [condition], branchLabels: ["alors", "sinon"]),
        BlockSpec(opcode: .waitUntil, name: "Attendre jusqu'à", category: .control, shape: .statement, symbol: "pause.circle",
                  layout: [.text("attendre jusqu'à"), .input("condition")], inputs: [condition], branchLabels: []),
        BlockSpec(opcode: .stopProgram, name: "Tout arrêter", category: .control, shape: .statement, symbol: "octagon.fill",
                  layout: [.text("tout arrêter")], inputs: [], branchLabels: []),

        // Capteurs
        BlockSpec(opcode: .colorIs, name: "Couleur vue", category: .sensors, shape: .boolean, symbol: "eyedropper.halffull",
                  layout: [.text("couleur ="), .input("color")],
                  inputs: [option("color", detectedColorOptions, DetectedColor.red.rawValue)], branchLabels: []),
        BlockSpec(opcode: .distance, name: "Distance", category: .sensors, shape: .number, symbol: "ruler",
                  layout: [.text("distance")], inputs: [], branchLabels: []),
        BlockSpec(opcode: .tiltAngle, name: "Inclinaison", category: .sensors, shape: .number, symbol: "rotate.3d",
                  layout: [.text("inclinaison"), .input("axis")],
                  inputs: [option("axis", tiltAxisOptions, TiltAxis.x.rawValue)], branchLabels: []),
        BlockSpec(opcode: .isTilted, name: "Hub penché", category: .sensors, shape: .boolean, symbol: "rotate.3d",
                  layout: [.text("hub penché"), .input("direction")],
                  inputs: [option("direction", tiltDirectionOptions, TiltDirection.any.rawValue)], branchLabels: []),
        BlockSpec(opcode: .isButtonPressed, name: "Bouton pressé", category: .sensors, shape: .boolean,
                  symbol: "button.programmable", layout: [.text("bouton pressé")], inputs: [], branchLabels: []),
        BlockSpec(opcode: .motorRotation, name: "Rotation du moteur", category: .sensors, shape: .number, symbol: "gearshape.2",
                  layout: [.text("rotation moteur"), .input("port")], inputs: [motor], branchLabels: []),

        // Données
        BlockSpec(opcode: .setVariable, name: "Donner une valeur", category: .data, shape: .statement, symbol: "equal.square",
                  layout: [.text("mettre"), .input("name"), .text("à"), .input("value")],
                  inputs: [InputSpec(key: "name", kind: .variable), number("value", 0)], branchLabels: []),
        BlockSpec(opcode: .changeVariable, name: "Ajouter à une variable", category: .data, shape: .statement,
                  symbol: "plus.square", layout: [.text("ajouter"), .input("value"), .text("à"), .input("name")],
                  inputs: [number("value", 1), InputSpec(key: "name", kind: .variable)], branchLabels: []),
        BlockSpec(opcode: .variableValue, name: "Variable", category: .data, shape: .number, symbol: "shippingbox",
                  layout: [.input("name")], inputs: [InputSpec(key: "name", kind: .variable)], branchLabels: []),
        BlockSpec(opcode: .math, name: "Calcul", category: .data, shape: .number, symbol: "plus.forwardslash.minus",
                  layout: [.input("a"), .input("op"), .input("b")],
                  inputs: [number("a", 1), option("op", mathOptions, "+"), number("b", 1)], branchLabels: []),
        BlockSpec(opcode: .random, name: "Nombre au hasard", category: .data, shape: .number, symbol: "dice",
                  layout: [.text("hasard entre"), .input("from"), .text("et"), .input("to")],
                  inputs: [number("from", 1), number("to", 10)], branchLabels: []),
        BlockSpec(opcode: .compare, name: "Comparaison", category: .data, shape: .boolean, symbol: "lessthan",
                  layout: [.input("a"), .input("op"), .input("b")],
                  inputs: [number("a", 0), option("op", compareOptions, "<"), number("b", 5)], branchLabels: []),
        BlockSpec(opcode: .and, name: "Et", category: .data, shape: .boolean, symbol: "square.on.square",
                  layout: [.input("a"), .text("et"), .input("b")],
                  inputs: [InputSpec(key: "a", kind: .boolean), InputSpec(key: "b", kind: .boolean)], branchLabels: []),
        BlockSpec(opcode: .or, name: "Ou", category: .data, shape: .boolean, symbol: "square.split.2x1",
                  layout: [.input("a"), .text("ou"), .input("b")],
                  inputs: [InputSpec(key: "a", kind: .boolean), InputSpec(key: "b", kind: .boolean)], branchLabels: []),
        BlockSpec(opcode: .not, name: "Non", category: .data, shape: .boolean, symbol: "exclamationmark.square",
                  layout: [.text("non"), .input("a")], inputs: [InputSpec(key: "a", kind: .boolean)], branchLabels: []),
    ]

    private static let ordered: [Opcode] = definitions.map(\.opcode)

    private static let specs: [Opcode: BlockSpec] = Dictionary(
        definitions.map { ($0.opcode, $0) }, uniquingKeysWith: { first, _ in first })
}
