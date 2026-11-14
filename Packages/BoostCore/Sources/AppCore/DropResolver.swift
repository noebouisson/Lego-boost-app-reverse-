import BlockEngine
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Cadres des éléments affichés sur le canvas, en coordonnées du canvas.
public struct EditorLayout: Equatable, Sendable {
    public var blocks: [UUID: CGRect] = [:]
    public var sequences: [SequenceRef: CGRect] = [:]
    public var slots: [SlotRef: CGRect] = [:]

    public init() {}

    public mutating func merge(_ other: EditorLayout) {
        blocks.merge(other.blocks) { _, new in new }
        sequences.merge(other.sequences) { _, new in new }
        slots.merge(other.slots) { _, new in new }
    }
}

/// Endroit où un glisser-déposer aboutirait, et repère à dessiner.
public struct DropTarget: Equatable, Sendable {
    public var location: BlockLocation
    public var indicator: CGRect
}

/// Trouve où déposer des blocs à partir de la position du doigt.
public enum DropResolver {

    /// - Parameters:
    ///   - dragged: blocs déplacés ; s'ils viennent du projet, ils y sont encore.
    ///   - point: position de dépôt, en coordonnées du canvas.
    ///   - scriptMargin: tolérance autour d'un script pour s'y accrocher.
    public static func target(for dragged: [Block], at point: CGPoint, in project: Project,
                              layout: EditorLayout, scriptMargin: CGFloat = 28) -> DropTarget? {
        guard let first = dragged.first else { return nil }
        let draggedIDs = Project.allIDs(in: dragged)
        // Le projet tel qu'il sera une fois les blocs retirés de leur place d'origine.
        var remaining = project
        remaining.detach(first.id)

        let shape = BlockCatalog.spec(for: first.opcode).shape
        if !shape.isSequenceBlock {
            return slotTarget(for: dragged, at: point, in: remaining, layout: layout, draggedIDs: draggedIDs)
        }
        return sequenceTarget(for: dragged, at: point, in: remaining, layout: layout,
                              draggedIDs: draggedIDs, scriptMargin: scriptMargin)
    }

    private static func slotTarget(for dragged: [Block], at point: CGPoint, in project: Project,
                                   layout: EditorLayout, draggedIDs: Set<UUID>) -> DropTarget? {
        var best: (slot: SlotRef, frame: CGRect)?
        for (slot, frame) in layout.slots {
            guard !draggedIDs.contains(slot.parent),
                  frame.insetBy(dx: -10, dy: -10).contains(point),
                  project.canInsert(dragged, at: .slot(slot)) else { continue }
            if best == nil || area(frame) < area(best!.frame) {
                best = (slot, frame)
            }
        }
        return best.map { DropTarget(location: .slot($0.slot), indicator: $0.frame.insetBy(dx: -3, dy: -3)) }
    }

    private static func sequenceTarget(for dragged: [Block], at point: CGPoint, in project: Project,
                                       layout: EditorLayout, draggedIDs: Set<UUID>,
                                       scriptMargin: CGFloat) -> DropTarget? {
        var best: (target: DropTarget, area: CGFloat)?

        for (ref, frame) in layout.sequences {
            var margin: CGFloat = 4
            switch ref {
            case .branch(let parent, _):
                if draggedIDs.contains(parent) { continue }
            case .script:
                margin = scriptMargin
            }
            // Une séquence absente du projet « après retrait » est celle qu'on déplace.
            guard let blocks = project.blocks(in: ref),
                  frame.insetBy(dx: -margin, dy: -margin).contains(point) else { continue }

            var index = blocks.filter { (layout.blocks[$0.id]?.midX ?? .infinity) < point.x }.count
            if !project.canInsert(dragged, at: .sequence(ref, index: index)) {
                // Devant un déclencheur : on se place juste après.
                guard index == 0, project.canInsert(dragged, at: .sequence(ref, index: 1)) else { continue }
                index = 1
            }

            let x: CGFloat
            if index < blocks.count, let next = layout.blocks[blocks[index].id] {
                x = next.minX - 2
            } else if index > 0, let previous = layout.blocks[blocks[index - 1].id] {
                x = previous.maxX + 2
            } else {
                x = frame.minX + 4
            }
            let indicator = CGRect(x: x - 3, y: frame.minY, width: 6, height: frame.height)
            let candidate = DropTarget(location: .sequence(ref, index: index), indicator: indicator)
            if best == nil || area(frame) < best!.area {
                best = (candidate, area(frame))
            }
        }
        return best?.target
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }
}
