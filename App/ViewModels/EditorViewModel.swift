import AppCore
import BlockEngine
import Observation
import SwiftUI

/// Cadres mesurés par les vues, lus pendant un glisser-déposer.
/// Hors de l'acteur principal pour pouvoir être écrits depuis les rappels de mise en page.
final class EditorGeometry: @unchecked Sendable {
    var layout = EditorLayout()
    var canvasFrame: CGRect = .zero
    var trashFrame: CGRect = .zero
    var paletteFrame: CGRect = .zero
}

/// État de l'éditeur : projet ouvert, zoom, glisser-déposer, sauvegarde automatique.
@MainActor
@Observable
final class EditorViewModel {

    struct DragSession {
        var blocks: [Block]
        /// Bloc d'origine dans le projet, nil si les blocs viennent de la palette.
        var sourceID: UUID?
        /// Position du doigt, en coordonnées globales.
        var location: CGPoint
        /// Écart entre le doigt et le coin haut gauche de l'aperçu.
        var grabOffset: CGSize
        var overTrash = false
        var target: DropTarget?

        var topLevelIDs: Set<UUID> {
            sourceID == nil ? [] : Set(blocks.map(\.id))
        }
    }

    struct VariablePrompt: Identifiable {
        let id = UUID()
        var blockID: UUID
        var key: String
    }

    private(set) var project: Project
    private(set) var drag: DragSession?
    var scale: CGFloat = 1
    var pan = CGSize(width: 40, height: 90)
    var variablePrompt: VariablePrompt?

    @ObservationIgnored nonisolated let geometry = EditorGeometry()

    @ObservationIgnored private let store: ProjectStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var paletteGestureIgnored = false

    static let scaleRange: ClosedRange<CGFloat> = 0.4...2

    init(project: Project, store: ProjectStore) {
        self.project = project
        self.store = store
    }

    // MARK: - Modifications du projet

    private func commit(_ newProject: Project) {
        guard newProject != project else { return }
        project = newProject
        scheduleSave()
    }

    func rename(_ name: String) {
        var copy = project
        copy.name = name
        commit(copy)
    }

    func setInput(_ blockID: UUID, _ key: String, _ value: Value) {
        var copy = project
        copy.updateBlock(blockID) { $0.inputs[key] = value }
        commit(copy)
    }

    /// Crée la variable si besoin et l'affecte au paramètre demandé.
    func chooseVariable(_ rawName: String, for blockID: UUID, key: String) {
        var copy = project
        guard let name = copy.addVariable(rawName) else { return }
        copy.updateBlock(blockID) { $0.inputs[key] = .variable(name) }
        commit(copy)
    }

    /// Ajoute un bloc de la palette au milieu de la partie visible du canvas.
    func addFromPalette(_ opcode: Opcode) {
        var copy = project
        let blocks = [makeBlock(opcode)]
        registerVariables(of: blocks, in: &copy)
        let frame = geometry.canvasFrame
        let center = canvasPoint(fromGlobal: CGPoint(x: frame.midX, y: frame.midY))
        let jitter = CGFloat(copy.scripts.count % 6) * 24
        copy.scripts.append(Script(x: max(0, center.x - 120 + jitter), y: max(0, center.y - 80 + jitter), blocks: blocks))
        commit(copy)
    }

    private func makeBlock(_ opcode: Opcode) -> Block {
        BlockCatalog.makeBlock(opcode, variable: project.variables.first ?? BlockCatalog.defaultVariableName)
    }

    /// Déclare dans le projet les variables citées par des blocs.
    private func registerVariables(of blocks: [Block], in project: inout Project) {
        for block in blocks {
            for value in block.inputs.values {
                switch value {
                case .variable(let name):
                    project.addVariable(name)
                case .reporter(let child):
                    registerVariables(of: [child], in: &project)
                case .number, .bool, .option:
                    break
                }
            }
            for branch in block.branches {
                registerVariables(of: branch, in: &project)
            }
        }
    }

    // MARK: - Sauvegarde

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        project.modifiedAt = Date()
        try? store.save(project)
    }

    // MARK: - Coordonnées et zoom

    func canvasPoint(fromGlobal point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - geometry.canvasFrame.minX - pan.width) / scale,
                y: (point.y - geometry.canvasFrame.minY - pan.height) / scale)
    }

    func globalPoint(fromCanvas point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale + pan.width + geometry.canvasFrame.minX,
                y: point.y * scale + pan.height + geometry.canvasFrame.minY)
    }

    /// Change le zoom en gardant fixe le centre de la zone visible.
    func setScale(_ newScale: CGFloat) {
        let clamped = min(max(newScale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        let center = CGPoint(x: geometry.canvasFrame.width / 2, y: geometry.canvasFrame.height / 2)
        let ratio = clamped / scale
        pan = CGSize(width: center.x - (center.x - pan.width) * ratio,
                     height: center.y - (center.y - pan.height) * ratio)
        scale = clamped
    }

    func resetView() {
        scale = 1
        pan = CGSize(width: 40, height: 90)
    }

    // MARK: - Glisser-déposer

    /// Mouvement du doigt sur un bloc du canvas.
    func blockDragChanged(_ blockID: UUID, to location: CGPoint) {
        if drag == nil {
            let blocks = project.dragGroup(startingAt: blockID)
            guard !blocks.isEmpty else { return }
            let origin = geometry.layout.blocks[blockID].map { globalPoint(fromCanvas: $0.origin) } ?? location
            drag = DragSession(blocks: blocks, sourceID: blockID, location: location,
                               grabOffset: CGSize(width: location.x - origin.x, height: location.y - origin.y))
        }
        guard drag?.sourceID == blockID else { return }
        updateDrag(to: location)
    }

    /// Mouvement du doigt sur un bloc de la palette. Un geste d'abord horizontal
    /// fait défiler la palette et ne sort pas de bloc.
    func paletteDragChanged(_ opcode: Opcode, to location: CGPoint, translation: CGSize) {
        if drag == nil {
            guard !paletteGestureIgnored else { return }
            if abs(translation.width) > abs(translation.height) {
                paletteGestureIgnored = true
                return
            }
            drag = DragSession(blocks: [makeBlock(opcode)], sourceID: nil, location: location,
                               grabOffset: CGSize(width: 40 * scale, height: 26 * scale))
        }
        guard drag?.sourceID == nil else { return }
        updateDrag(to: location)
    }

    private func updateDrag(to location: CGPoint) {
        guard var session = drag else { return }
        session.location = location
        session.overTrash = geometry.trashFrame.contains(location) || geometry.paletteFrame.contains(location)
        if session.overTrash {
            session.target = nil
        } else {
            let origin = canvasPoint(fromGlobal: previewOrigin(of: session))
            let probe = CGPoint(x: origin.x + 8, y: origin.y + Theme.blockHeight / 2)
            session.target = DropResolver.target(for: session.blocks, at: probe, in: project, layout: geometry.layout)
        }
        drag = session
    }

    /// Coin haut gauche de l'aperçu, en coordonnées globales.
    func previewOrigin(of session: DragSession) -> CGPoint {
        CGPoint(x: session.location.x - session.grabOffset.width, y: session.location.y - session.grabOffset.height)
    }

    /// Fin du geste : dépose, crée un nouveau script, ou supprime.
    func endDrag() {
        paletteGestureIgnored = false
        guard let session = drag else { return }
        drag = nil

        var copy = project
        if let sourceID = session.sourceID {
            copy.detach(sourceID)
        }
        if session.overTrash {
            commit(copy)
            return
        }

        let origin = canvasPoint(fromGlobal: previewOrigin(of: session))
        var placed = false
        if let target = session.target {
            let result = copy.insert(session.blocks, at: target.location)
            placed = result.inserted
            if let displaced = result.displaced {
                // Le bloc chassé d'un paramètre est reposé juste en dessous.
                copy.scripts.append(Script(x: max(0, origin.x), y: max(0, origin.y + 90), blocks: [displaced]))
            }
        }
        if !placed {
            copy.scripts.append(Script(x: max(0, origin.x), y: max(0, origin.y), blocks: session.blocks))
        }
        registerVariables(of: session.blocks, in: &copy)
        commit(copy)
    }

    func cancelDrag() {
        paletteGestureIgnored = false
        drag = nil
    }
}
