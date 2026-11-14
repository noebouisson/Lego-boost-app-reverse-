import BlockEngine
import Foundation

/// Lecteur de sons fourni par l'app (synthèse sur l'iPad).
public protocol SoundPlaying: Sendable {
    /// Joue un son et rend la main à la fin, ou dès l'annulation de la tâche.
    func play(_ sound: SoundID) async
    func stopAll()
}

/// Lecteur muet : journalise seulement. Utile pour les tests.
public final class SilentSoundPlayer: SoundPlaying {
    public init() {}
    public func play(_ sound: SoundID) async {}
    public func stopAll() {}
}
