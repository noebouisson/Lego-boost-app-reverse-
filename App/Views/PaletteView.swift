import BlockEngine
import SwiftUI

/// Palette en bas de l'écran : catégories, puis blocs à faire glisser vers le canvas.
struct PaletteView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var category: BlockCategory = .triggers

    /// Un exemplaire de chaque bloc, créé une seule fois.
    private static let templates: [Opcode: Block] = Dictionary(
        Opcode.allCases.map { ($0, BlockCatalog.makeBlock($0)) }, uniquingKeysWith: { first, _ in first })

    var body: some View {
        let geometry = editor.geometry
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(BlockCategory.allCases, id: \.self) { item in
                    Button {
                        category = item
                    } label: {
                        Label(item.title, systemImage: Theme.symbol(for: item))
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .foregroundStyle(.white)
                            .background(Capsule().fill(Theme.color(for: item).opacity(item == category ? 1 : 0.35)))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("Glisse un bloc vers le haut, ou touche-le pour l'ajouter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 14) {
                    ForEach(BlockCatalog.opcodes(in: category), id: \.self) { opcode in
                        template(opcode)
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 96)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.panelBackground)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            geometry.paletteFrame = frame
        }
    }

    @ViewBuilder
    private func template(_ opcode: Opcode) -> some View {
        if let block = Self.templates[opcode] {
            BlockView(block: block, isTemplate: true)
                .fixedSize()
                .onTapGesture {
                    editor.addFromPalette(opcode)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .global)
                        .onChanged { value in
                            editor.paletteDragChanged(opcode, to: value.location, translation: value.translation)
                        }
                        .onEnded { _ in
                            editor.endDrag()
                        }
                )
        }
    }
}

/// Corbeille : y déposer des blocs les supprime.
struct TrashZone: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        let geometry = editor.geometry
        let isActive = editor.drag?.overTrash ?? false
        Image(systemName: isActive ? "trash.fill" : "trash")
            .font(.system(size: isActive ? 34 : 26, weight: .semibold))
            .foregroundStyle(isActive ? Color.red : Color.white.opacity(0.7))
            .frame(width: 84, height: 84)
            .background(Circle().fill(isActive ? Color.red.opacity(0.25) : Color.white.opacity(0.08)))
            .overlay(Circle().stroke(isActive ? Color.red : Color.white.opacity(0.2), lineWidth: 2))
            .animation(.easeOut(duration: 0.15), value: isActive)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                geometry.trashFrame = frame
            }
    }
}
