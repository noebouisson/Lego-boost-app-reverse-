import AppCore
import BlockEngine
import SwiftUI

/// Grand plan de travail : déplacement à un doigt, zoom par pincement.
struct CanvasView: View {
    @Environment(EditorViewModel.self) private var editor

    @State private var panStart: CGSize?
    @State private var scaleStart: CGFloat?

    var body: some View {
        let geometry = editor.geometry
        ZStack(alignment: .topLeading) {
            grid
                .contentShape(Rectangle())
                .gesture(panGesture)
                .simultaneousGesture(zoomGesture)

            content(geometry)
                .scaleEffect(editor.scale, anchor: .topLeading)
                .offset(editor.pan)
        }
        .clipped()
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            geometry.canvasFrame = frame
        }
    }

    /// Scripts du projet, en coordonnées du canvas.
    private func content(_ geometry: EditorGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(editor.project.scripts) { script in
                SequenceView(ref: .script(script.id), blocks: script.blocks)
                    .fixedSize()
                    .opacity(script.isRunnable || !startsSequence(script) ? 1 : 0.75)
                    .offset(x: script.x, y: script.y)
            }
            if let indicator = editor.drag?.target?.indicator {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white, lineWidth: 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.35)))
                    .frame(width: indicator.width, height: indicator.height)
                    .offset(x: indicator.minX, y: indicator.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: Theme.canvasSpace)
        .onPreferenceChange(LayoutPreferenceKey.self) { layout in
            geometry.layout = layout
        }
    }

    /// Vrai si le script commence par un bloc de séquence (et non par une valeur isolée).
    private func startsSequence(_ script: Script) -> Bool {
        guard let first = script.blocks.first else { return false }
        return BlockCatalog.spec(for: first.opcode).shape.isSequenceBlock
    }

    /// Fond à points qui suit le déplacement et le zoom.
    private var grid: some View {
        let scale = editor.scale
        let pan = editor.pan
        return Canvas { context, size in
            let spacing = 40 * scale
            guard spacing > 8 else { return }
            let startX = pan.width.truncatingRemainder(dividingBy: spacing)
            let startY = pan.height.truncatingRemainder(dividingBy: spacing)
            var path = Path()
            var y = startY
            while y < size.height {
                var x = startX
                while x < size.width {
                    path.addEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
                    x += spacing
                }
                y += spacing
            }
            context.fill(path, with: .color(.white.opacity(0.10)))
        }
        .background(Theme.canvasBackground)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let start = panStart ?? editor.pan
                panStart = start
                editor.pan = CGSize(width: start.width + value.translation.width,
                                    height: start.height + value.translation.height)
            }
            .onEnded { _ in
                panStart = nil
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = scaleStart ?? editor.scale
                scaleStart = start
                editor.setScale(start * value.magnification)
            }
            .onEnded { _ in
                scaleStart = nil
            }
    }
}
