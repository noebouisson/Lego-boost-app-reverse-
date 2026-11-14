import Foundation

/// Contenu d'un paramètre de bloc.
public indirect enum Value: Equatable, Sendable {
    /// Nombre saisi par l'utilisateur.
    case number(Double)
    /// Booléen fixe ; `false` représente un emplacement de condition vide.
    case bool(Bool)
    /// Choix dans une liste (port, couleur, son, opérateur…), par identifiant.
    case option(String)
    /// Nom d'une variable du projet.
    case variable(String)
    /// Bloc capteur ou opérateur emboîté dans le paramètre.
    case reporter(Block)
}

extension Value: Codable {
    private enum CodingKeys: String, CodingKey {
        case number = "n"
        case bool = "b"
        case option = "o"
        case variable = "v"
        case reporter = "r"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Double.self, forKey: .number) {
            self = .number(value)
        } else if let value = try container.decodeIfPresent(Bool.self, forKey: .bool) {
            self = .bool(value)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .option) {
            self = .option(value)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .variable) {
            self = .variable(value)
        } else if let value = try container.decodeIfPresent(Block.self, forKey: .reporter) {
            self = .reporter(value)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Valeur de bloc inconnue"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .number(let value): try container.encode(value, forKey: .number)
        case .bool(let value): try container.encode(value, forKey: .bool)
        case .option(let value): try container.encode(value, forKey: .option)
        case .variable(let value): try container.encode(value, forKey: .variable)
        case .reporter(let value): try container.encode(value, forKey: .reporter)
        }
    }
}

/// Nœud de l'arbre d'un programme.
public struct Block: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var opcode: Opcode
    /// Paramètres nommés ; les clés sont décrites par `BlockCatalog`.
    public var inputs: [String: Value]
    /// Sous-séquences : 1 pour une boucle, 2 pour si/sinon, aucune sinon.
    public var branches: [[Block]]

    public init(id: UUID = UUID(), opcode: Opcode, inputs: [String: Value] = [:], branches: [[Block]] = []) {
        self.id = id
        self.opcode = opcode
        self.inputs = inputs
        self.branches = branches
    }

    private enum CodingKeys: String, CodingKey {
        case id, opcode, inputs, branches
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        opcode = try container.decode(Opcode.self, forKey: .opcode)
        inputs = try container.decodeIfPresent([String: Value].self, forKey: .inputs) ?? [:]
        branches = try container.decodeIfPresent([[Block]].self, forKey: .branches) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(opcode, forKey: .opcode)
        if !inputs.isEmpty { try container.encode(inputs, forKey: .inputs) }
        if !branches.isEmpty { try container.encode(branches, forKey: .branches) }
    }

    /// Identifiant du choix d'un paramètre de type liste.
    public func option(_ key: String) -> String? {
        if case .option(let id)? = inputs[key] { return id }
        return nil
    }

    /// Nom de variable d'un paramètre de type variable.
    public func variableName(_ key: String) -> String? {
        if case .variable(let name)? = inputs[key] { return name }
        return nil
    }
}

/// Séquence horizontale de blocs posée sur le canvas.
/// Elle ne s'exécute que si son premier bloc est un déclencheur.
public struct Script: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var x: Double
    public var y: Double
    public var blocks: [Block]

    public init(id: UUID = UUID(), x: Double = 0, y: Double = 0, blocks: [Block] = []) {
        self.id = id
        self.x = x
        self.y = y
        self.blocks = blocks
    }

    public var isRunnable: Bool {
        guard let first = blocks.first else { return false }
        return BlockCatalog.spec(for: first.opcode).shape == .trigger
    }
}

public struct Project: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var modifiedAt: Date
    public var scripts: [Script]
    public var variables: [String]

    public init(id: UUID = UUID(), name: String, modifiedAt: Date = Date(),
                scripts: [Script] = [], variables: [String] = []) {
        self.id = id
        self.name = name
        self.modifiedAt = modifiedAt
        self.scripts = scripts
        self.variables = variables
    }
}
