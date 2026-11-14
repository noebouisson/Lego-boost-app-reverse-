import AppCore
import BlockEngine
import SwiftUI

/// Collecte les cadres des blocs, séquences et paramètres affichés sur le canvas.
struct LayoutPreferenceKey: PreferenceKey {
    static var defaultValue = EditorLayout()

    static func reduce(value: inout EditorLayout, nextValue: () -> EditorLayout) {
        value.merge(nextValue())
    }
}

extension View {
    /// Publie le cadre de la vue, en coordonnées du canvas, dans `EditorLayout`.
    @ViewBuilder
    func reportFrame(enabled: Bool, _ assign: @escaping (inout EditorLayout, CGRect) -> Void) -> some View {
        if enabled {
            background(
                GeometryReader { proxy in
                    Color.clear.preference(key: LayoutPreferenceKey.self, value: {
                        var layout = EditorLayout()
                        assign(&layout, proxy.frame(in: .named(Theme.canvasSpace)))
                        return layout
                    }())
                }
            )
        } else {
            self
        }
    }
}

/// Suite horizontale de blocs emboîtés.
struct SequenceView: View {
    let ref: SequenceRef
    let blocks: [Block]
    var isTemplate = false

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(blocks) { block in
                BlockView(block: block, isTemplate: isTemplate)
            }
        }
        .reportFrame(enabled: !isTemplate) { layout, frame in
            layout.sequences[ref] = frame
        }
    }
}

/// Un bloc, avec ses paramètres et ses sous-séquences.
struct BlockView: View {
    let block: Block
    /// Vrai dans la palette et l'aperçu de déplacement : aucun geste, aucun cadre publié.
    var isTemplate = false

    @Environment(EditorViewModel.self) private var editor
    @Environment(AppModel.self) private var app

    var body: some View {
        let spec = BlockCatalog.spec(for: block.opcode)
        let outline = spec.shape.outline
        let color = Theme.color(for: spec.category)

        content(spec)
            .padding(.leading, spec.shape == .trigger ? 16 : 10)
            .padding(.trailing, 10)
            .padding(.vertical, spec.shape.isSequenceBlock ? 6 : 4)
            .frame(minHeight: spec.shape.isSequenceBlock ? Theme.blockHeight : 34)
            .background(outline.fill(color))
            .overlay(outline.stroke(Color.black.opacity(0.25), lineWidth: 1))
            .overlay(highlight(outline))
            .contentShape(outline)
            .opacity(isBeingDragged ? 0.3 : 1)
            .reportFrame(enabled: !isTemplate) { layout, frame in
                layout.blocks[block.id] = frame
            }
            .gesture(isTemplate ? nil : dragGesture)
    }

    @ViewBuilder
    private func content(_ spec: BlockSpec) -> some View {
        HStack(alignment: .center, spacing: 6) {
            if spec.shape.isSequenceBlock {
                Image(systemName: spec.symbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            ForEach(Array(spec.layout.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .text(let text):
                    label(text)
                case .input(let key):
                    InputView(block: block, key: key, isTemplate: isTemplate)
                }
            }
            ForEach(Array(spec.branchLabels.enumerated()), id: \.offset) { index, title in
                if !title.isEmpty {
                    label(title)
                }
                SequenceView(ref: .branch(parent: block.id, index: index),
                             blocks: block.branches.indices.contains(index) ? block.branches[index] : [],
                             isTemplate: isTemplate)
                    .padding(5)
                    .frame(minWidth: 64, minHeight: Theme.blockHeight + 10, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.28)))
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder
    private func highlight(_ outline: AnyShape) -> some View {
        if !isTemplate {
            if app.execution.failedBlock == block.id {
                outline.stroke(Color.red, lineWidth: 4)
            } else if app.execution.activeBlocks.contains(block.id) {
                outline.stroke(Color.white, lineWidth: 3)
                    .shadow(color: .white.opacity(0.8), radius: 6)
            }
        }
    }

    private var isBeingDragged: Bool {
        !isTemplate && (editor.drag?.topLevelIDs.contains(block.id) ?? false)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                editor.blockDragChanged(block.id, to: value.location)
            }
            .onEnded { _ in
                editor.endDrag()
            }
    }
}
