import AppCore
import BlockEngine
import SwiftUI

/// Écran d'accueil : liste des projets.
struct HomeView: View {
    let store: ProjectStore

    @State private var projects: [Project] = []
    @State private var opened: Project?
    @State private var renaming: Project?
    @State private var deleting: Project?
    @State private var nameDraft = ""
    @State private var showsHub = false
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 20)]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    newProjectCard
                    ForEach(projects) { project in
                        card(for: project)
                    }
                }
                .padding(24)
            }
        }
        .background(Theme.canvasBackground.ignoresSafeArea())
        .onAppear(perform: reload)
        .fullScreenCover(item: $opened, onDismiss: reload) { project in
            EditorView(project: project, store: store)
        }
        .sheet(isPresented: $showsHub) {
            ConnectionSheet()
        }
        .alert("Renommer le projet", isPresented: renamingBinding) {
            TextField("Nom", text: $nameDraft)
            Button("Renommer") { commitRename() }
            Button("Annuler", role: .cancel) { renaming = nil }
        }
        .alert("Supprimer ce projet ?", isPresented: deletingBinding) {
            Button("Supprimer", role: .destructive) { commitDelete() }
            Button("Annuler", role: .cancel) { deleting = nil }
        } message: {
            Text("« \(deleting?.name ?? "") » sera supprimé définitivement.")
        }
        .alert("Erreur", isPresented: errorBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text("Mes projets")
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            HubStatusButton {
                showsHub = true
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var newProjectCard: some View {
        Button {
            createProject()
        } label: {
            VStack(spacing: 12) {
                Image(systemName: "plus.circle.fill").font(.system(size: 44))
                Text("Nouveau projet").font(.system(size: 18, weight: .bold, design: .rounded))
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 170)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            )
        }
        .buttonStyle(.plain)
    }

    private func card(for project: Project) -> some View {
        Button {
            opened = project
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(BlockCategory.allCases, id: \.self) { category in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Theme.color(for: category))
                            .frame(width: 30, height: 18)
                    }
                }
                Spacer(minLength: 0)
                Text(project.name)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(summary(of: project))
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(project.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20).fill(Theme.panelBackground))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                nameDraft = project.name
                renaming = project
            } label: {
                Label("Renommer", systemImage: "pencil")
            }
            Button {
                perform { _ = try store.duplicate(project) }
            } label: {
                Label("Dupliquer", systemImage: "plus.square.on.square")
            }
            Button(role: .destructive) {
                deleting = project
            } label: {
                Label("Supprimer", systemImage: "trash")
            }
        }
    }

    private func summary(of project: Project) -> String {
        let scripts = project.scripts.filter(\.isRunnable).count
        let blocks = project.scripts.reduce(0) { $0 + Project.allIDs(in: $1.blocks).count }
        return "\(scripts) script\(scripts > 1 ? "s" : "") · \(blocks) bloc\(blocks > 1 ? "s" : "")"
    }

    // MARK: - Actions

    private func reload() {
        projects = store.loadAll()
    }

    private func createProject() {
        perform {
            let project = try store.create(name: "Projet \(projects.count + 1)")
            opened = project
        }
    }

    private func commitRename() {
        guard var project = renaming else { return }
        renaming = nil
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        project.name = name
        project.modifiedAt = Date()
        perform { try store.save(project) }
    }

    private func commitDelete() {
        guard let project = deleting else { return }
        deleting = nil
        perform { try store.delete(project.id) }
    }

    /// Exécute une opération sur le stockage, affiche l'erreur éventuelle, puis recharge la liste.
    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}
