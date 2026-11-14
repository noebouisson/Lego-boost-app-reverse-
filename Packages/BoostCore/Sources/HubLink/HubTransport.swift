import Foundation

/// État du lien avec le hub.
public enum TransportState: Equatable, Sendable {
    case idle
    case unavailable(reason: String)
    case scanning
    case connecting
    case connected(name: String)
    case reconnecting

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Événements d'un transport, dans l'ordre où ils se produisent.
public enum TransportEvent: Sendable {
    case state(TransportState)
    case data(Data)
}

/// Canal d'octets vers un hub : Bluetooth réel ou simulation.
public protocol HubTransport: AnyObject, Sendable {
    /// Flux unique, à consommer par un seul lecteur (HubSession).
    var events: AsyncStream<TransportEvent> { get }
    /// Recherche un hub et s'y connecte. Se reconnecte seul après une coupure.
    func start()
    /// Coupe la connexion et arrête toute recherche.
    func stop()
    /// Envoie un message complet. Ignoré si le hub n'est pas connecté.
    func send(_ data: Data)
}

/// Diffuse des valeurs à plusieurs abonnés sous forme d'AsyncStream.
public final class Broadcaster<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    private var last: Value?
    private let replaysLast: Bool

    /// - Parameter replaysLast: si vrai, tout nouvel abonné reçoit d'abord la dernière valeur.
    public init(replaysLast: Bool = false) {
        self.replaysLast = replaysLast
    }

    public func stream() -> AsyncStream<Value> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Value>.makeStream()
        lock.lock()
        continuations[id] = continuation
        let replay = replaysLast ? last : nil
        lock.unlock()
        if let replay { continuation.yield(replay) }
        continuation.onTermination = { [weak self] _ in self?.remove(id) }
        return stream
    }

    public func send(_ value: Value) {
        lock.lock()
        if replaysLast { last = value }
        let targets = Array(continuations.values)
        lock.unlock()
        for target in targets { target.yield(value) }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}
