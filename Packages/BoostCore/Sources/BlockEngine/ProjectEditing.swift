import Foundation

/// Séquence de blocs : un script du canvas ou une branche d'un conteneur.
public enum SequenceRef: Hashable, Sendable {
    case script(UUID)
    case branch(parent: UUID, index: Int)
}

/// Emplacement de paramètre d'un bloc.
public struct SlotRef: Hashable, Sendable {
    public var parent: UUID
    public var key: String

    public init(parent: UUID, key: String) {
        self.parent = parent
        self.key = key
    }
}

/// Endroit où déposer des blocs.
public enum BlockLocation: Equatable, Sendable {
    case sequence(SequenceRef, index: Int)
    case slot(SlotRef)
}

// Opérations d'édition de l'arbre, utilisées par l'éditeur.
extension Project {

    // MARK: - Lecture

    public func findBlock(_ id: UUID) -> Block? {
        for script in scripts {
            if let found = Self.find(id, in: script.blocks) { return found }
        }
        return nil
    }

    public func blocks(in ref: SequenceRef) -> [Block]? {
        switch ref {
        case .script(let id):
            return scripts.first { $0.id == id }?.blocks
        case .branch(let parent, let index):
            guard let block = findBlock(parent), block.branches.indices.contains(index) else { return nil }
            return block.branches[index]
        }
    }

    /// Blocs emportés quand on saisit `id` : le bloc et ceux qui le suivent dans
    /// sa séquence, ou le bloc seul s'il est dans un paramètre.
    public func dragGroup(startingAt id: UUID) -> [Block] {
        var copy = self
        return copy.detach(id)
    }

    /// Identifiants de tous les blocs d'une liste, descendants compris.
    public static func allIDs(in blocks: [Block]) -> Set<UUID> {
        var result: Set<UUID> = []
        func visit(_ block: Block) {
            result.insert(block.id)
            for value in block.inputs.values {
                if case .reporter(let child) = value { visit(child) }
            }
            for branch in block.branches { branch.forEach(visit) }
        }
        blocks.forEach(visit)
        return result
    }

    // MARK: - Modification

    /// Modifie un bloc en place. Renvoie faux s'il est introuvable.
    @discardableResult
    public mutating func updateBlock(_ id: UUID, _ transform: (inout Block) -> Void) -> Bool {
        for index in scripts.indices {
            if Self.update(id, in: &scripts[index].blocks, transform) { return true }
        }
        return false
    }

    /// Retire le groupe saisi par `id` et le renvoie. Les scripts vidés sont supprimés ;
    /// un paramètre libéré reprend sa valeur par défaut.
    @discardableResult
    public mutating func detach(_ id: UUID) -> [Block] {
        for index in scripts.indices {
            if let removed = Self.detach(id, from: &scripts[index].blocks) {
                scripts.removeAll { $0.blocks.isEmpty }
                return removed
            }
        }
        return []
    }

    /// Vrai si ces blocs peuvent être déposés à cet endroit.
    public func canInsert(_ blocks: [Block], at location: BlockLocation) -> Bool {
        guard let first = blocks.first else { return false }
        let shapes = blocks.map { BlockCatalog.spec(for: $0.opcode).shape }

        switch location {
        case .slot(let slot):
            guard blocks.count == 1, let parent = findBlock(slot.parent),
                  let input = BlockCatalog.spec(for: parent.opcode).input(slot.key) else { return false }
            return BlockCatalog.accepts(input.kind, shape: shapes[0])

        case .sequence(let ref, let index):
            guard shapes.allSatisfy(\.isSequenceBlock), let existing = self.blocks(in: ref),
                  index >= 0, index <= existing.count else { return false }
            // Un déclencheur ne peut être qu'en tête du groupe…
            guard !shapes.dropFirst().contains(.trigger) else { return false }
            let startsWithTrigger = BlockCatalog.spec(for: first.opcode).shape == .trigger
            let existingHasTrigger = existing.first.map { BlockCatalog.spec(for: $0.opcode).shape == .trigger } ?? false
            if startsWithTrigger {
                // … et en tête d'un script qui n'en a pas déjà.
                guard case .script = ref, index == 0, !existingHasTrigger else { return false }
            } else if existingHasTrigger, index == 0 {
                return false
            }
            return true
        }
    }

    /// Dépose des blocs. `displaced` est le bloc qui occupait le paramètre visé, s'il y en avait un.
    @discardableResult
    public mutating func insert(_ blocks: [Block], at location: BlockLocation) -> (inserted: Bool, displaced: Block?) {
        guard canInsert(blocks, at: location) else { return (false, nil) }
        switch location {
        case .slot(let slot):
            var displaced: Block?
            let done = updateBlock(slot.parent) { parent in
                if case .reporter(let old)? = parent.inputs[slot.key] { displaced = old }
                parent.inputs[slot.key] = .reporter(blocks[0])
            }
            return (done, displaced)

        case .sequence(.script(let id), let index):
            guard let scriptIndex = scripts.firstIndex(where: { $0.id == id }) else { return (false, nil) }
            scripts[scriptIndex].blocks.insert(contentsOf: blocks, at: index)
            return (true, nil)

        case .sequence(.branch(let parent, let branch), let index):
            let done = updateBlock(parent) { block in
                block.branches[branch].insert(contentsOf: blocks, at: index)
            }
            return (done, nil)
        }
    }

    /// Ajoute une variable si elle n'existe pas. Renvoie le nom retenu, nil s'il est vide.
    @discardableResult
    public mutating func addVariable(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if !variables.contains(name) { variables.append(name) }
        return name
    }

    // MARK: - Parcours récursifs

    private static func find(_ id: UUID, in blocks: [Block]) -> Block? {
        for block in blocks {
            if block.id == id { return block }
            for value in block.inputs.values {
                if case .reporter(let child) = value, let found = find(id, in: [child]) { return found }
            }
            for branch in block.branches {
                if let found = find(id, in: branch) { return found }
            }
        }
        return nil
    }

    private static func update(_ id: UUID, in blocks: inout [Block], _ transform: (inout Block) -> Void) -> Bool {
        for index in blocks.indices {
            if update(id, in: &blocks[index], transform) { return true }
        }
        return false
    }

    private static func update(_ id: UUID, in block: inout Block, _ transform: (inout Block) -> Void) -> Bool {
        if block.id == id {
            transform(&block)
            return true
        }
        for key in block.inputs.keys {
            if case .reporter(var child)? = block.inputs[key], update(id, in: &child, transform) {
                block.inputs[key] = .reporter(child)
                return true
            }
        }
        for index in block.branches.indices {
            if update(id, in: &block.branches[index], transform) { return true }
        }
        return false
    }

    private static func detach(_ id: UUID, from blocks: inout [Block]) -> [Block]? {
        if let index = blocks.firstIndex(where: { $0.id == id }) {
            let removed = Array(blocks[index...])
            blocks.removeSubrange(index...)
            return removed
        }
        for index in blocks.indices {
            if let removed = detach(id, from: &blocks[index]) { return removed }
        }
        return nil
    }

    private static func detach(_ id: UUID, from block: inout Block) -> [Block]? {
        let spec = BlockCatalog.spec(for: block.opcode)
        for key in block.inputs.keys {
            guard case .reporter(var child)? = block.inputs[key] else { continue }
            if child.id == id {
                block.inputs[key] = spec.input(key).map { BlockCatalog.defaultValue(for: $0.kind) } ?? .number(0)
                return [child]
            }
            if let removed = detach(id, from: &child) {
                block.inputs[key] = .reporter(child)
                return removed
            }
        }
        for index in block.branches.indices {
            if let removed = detach(id, from: &block.branches[index]) { return removed }
        }
        return nil
    }
}
