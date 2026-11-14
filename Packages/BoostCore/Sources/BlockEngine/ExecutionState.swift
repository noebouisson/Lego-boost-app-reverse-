import Foundation

/// État d'exécution publié par l'interpréteur, pour la surbrillance et l'affichage.
public struct ExecutionState: Equatable, Sendable {
    public var isRunning = false
    /// Blocs en cours d'exécution (un conteneur reste actif pendant son contenu).
    public var activeBlocks: Set<UUID> = []
    public var variables: [String: Double] = [:]
    /// Message de l'erreur qui a arrêté le programme, nil sinon.
    public var errorMessage: String?
    /// Bloc sur lequel l'erreur s'est produite.
    public var failedBlock: UUID?

    public init() {}
}

public enum EngineError: Error, Equatable, LocalizedError {
    /// Un bloc est utilisé à une place qui ne lui convient pas.
    case misplacedBlock(Opcode)
    case missingInput(Opcode, String)

    public var errorDescription: String? {
        switch self {
        case .misplacedBlock(let opcode):
            return "Le bloc « \(BlockCatalog.spec(for: opcode).name) » n'est pas à sa place."
        case .missingInput(let opcode, let key):
            return "Le bloc « \(BlockCatalog.spec(for: opcode).name) » n'a pas de valeur pour « \(key) »."
        }
    }
}
