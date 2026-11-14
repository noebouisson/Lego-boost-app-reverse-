import AppCore
import BlockEngine
import SwiftUI

/// Éditeur plein écran d'un projet.
struct EditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var editor: EditorViewModel
    @State private var showsHub = false
    @State private var newVariableName = ""
    @State private var projectName: String

    init(project: Project, store: ProjectStore) {
        _editor = State(initialValue: EditorViewModel(project: project, store: store))
        _projectName = State(initialValue: project.name)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                CanvasView()
                    .overlay(alignment: .top) { topBar }
                    .overlay(alignment: .topLeading) { variablesPanel }
                    .overlay(alignment: .bottomTrailing) { TrashZone().padding(18) }
                    .overlay(alignment: .bottomLeading) { zoomControls.padding(18) }
                PaletteView()
            }
            dragPreview
        }
        .background(Theme.canvasBackground)
        .ignoresSafeArea(.keyboard)
        .environment(editor)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showsHub) {
            ConnectionSheet()
        }
        .alert("Nouvelle variable", isPresented: variablePromptBinding) {
            TextField("Nom", text: $newVariableName)
            Button("Créer") {
                if let prompt = editor.variablePrompt {
                    editor.chooseVariable(newVariableName, for: prompt.blockID, key: prompt.key)
                }
                editor.variablePrompt = nil
                newVariableName = ""
            }
            Button("Annuler", role: .cancel) {
                editor.variablePrompt = nil
                newVariableName = ""
            }
        }
        .onChange(of: projectName) { _, name in
            editor.rename(name)
        }
        .onDisappear {
            app.stop()
            editor.saveNow()
        }
    }

    private var variablePromptBinding: Binding<Bool> {
        Binding(get: { editor.variablePrompt != nil },
                set: { if !$0 { editor.variablePrompt = nil } })
    }

    // MARK: - Barre du haut

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                app.stop()
                editor.saveNow()
                dismiss()
            } label: {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Theme.panelBackground))
            }
            .buttonStyle(.plain)

            TextField("Nom du projet", text: $projectName)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .frame(width: 260, height: 48)
                .background(Capsule().fill(Theme.panelBackground))

            Spacer()

            if let message = app.execution.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: 360, minHeight: 48)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
            }

            HubStatusButton {
                showsHub = true
            }

            runButton
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var runButton: some View {
        let isRunning = app.execution.isRunning
        return Button {
            if isRunning {
                app.stop()
            } else if app.hub.isConnected {
                app.run(editor.project)
            } else {
                showsHub = true
            }
        } label: {
            Label(isRunning ? "Arrêter" : "Lancer", systemImage: isRunning ? "stop.fill" : "play.fill")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 48)
                .background(Capsule().fill(isRunning ? Color.red : Color(red: 0.18, green: 0.70, blue: 0.35)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Panneaux flottants

    /// Valeurs des variables pendant l'exécution.
    @ViewBuilder
    private var variablesPanel: some View {
        let variables = app.execution.variables
        if app.execution.isRunning, !variables.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(variables.keys.sorted(), id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer(minLength: 16)
                        Text(Theme.format(variables[name] ?? 0)).fontWeight(.bold)
                    }
                }
            }
            .font(.system(size: 14, design: .rounded))
            .foregroundStyle(.white)
            .padding(12)
            .frame(width: 200)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.color(for: .data).opacity(0.9)))
            .padding(.leading, 16)
            .padding(.top, 76)
            .allowsHitTesting(false)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            zoomButton("minus") { editor.setScale(editor.scale - 0.2) }
            Button {
                editor.resetView()
            } label: {
                Text("\(Int((editor.scale * 100).rounded())) %")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .frame(width: 60, height: 44)
            }
            .buttonStyle(.plain)
            zoomButton("plus") { editor.setScale(editor.scale + 0.2) }
        }
        .foregroundStyle(.white)
        .background(Capsule().fill(Theme.panelBackground))
    }

    private func zoomButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Aperçu de déplacement

    /// Blocs qui suivent le doigt pendant un glisser-déposer.
    private var dragPreview: some View {
        GeometryReader { proxy in
            if let session = editor.drag {
                let origin = editor.previewOrigin(of: session)
                let frame = proxy.frame(in: .global)
                SequenceView(ref: .script(session.blocks.first?.id ?? UUID()), blocks: session.blocks, isTemplate: true)
                    .fixedSize()
                    .scaleEffect(editor.scale, anchor: .topLeading)
                    .opacity(session.overTrash ? 0.45 : 0.92)
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
                    .offset(x: origin.x - frame.minX, y: origin.y - frame.minY)
            }
        }
        .allowsHitTesting(false)
    }
}
