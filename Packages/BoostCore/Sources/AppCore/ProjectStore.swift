import BlockEngine
import Foundation

/// Sauvegarde des projets : un fichier JSON par projet dans un dossier.
public final class ProjectStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Dossier « Projets » dans les documents de l'app.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Projets", isDirectory: true)
    }

    /// Tous les projets lisibles, du plus récent au plus ancien.
    public func loadAll() -> [Project] {
        lock.lock(); defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = Self.makeDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Project.self, from: $0) } }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func save(_ project: Project) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try Self.makeEncoder().encode(project)
        try data.write(to: url(for: project.id), options: .atomic)
    }

    public func delete(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let target = url(for: id)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    /// Crée et enregistre un projet avec un script de départ.
    public func create(name: String) throws -> Project {
        let project = Project(name: name, scripts: [
            Script(x: 80, y: 120, blocks: [BlockCatalog.makeBlock(.whenStarted)]),
        ])
        try save(project)
        return project
    }

    /// Copie un projet sous un nouvel identifiant.
    public func duplicate(_ project: Project) throws -> Project {
        var copy = project
        copy.id = UUID()
        copy.name = project.name + " (copie)"
        copy.modifiedAt = Date()
        try save(copy)
        return copy
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
