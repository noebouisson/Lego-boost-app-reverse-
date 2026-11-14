import AppCore
import BlockEngine
import HubLink
import Observation
import SwiftUI

/// État partagé de l'app : connexion au hub (réel ou simulé) et exécution des programmes.
@MainActor
@Observable
final class AppModel {

    enum HubMode: String, CaseIterable, Identifiable {
        case real
        case simulated

        var id: String { rawValue }
        var title: String { self == .real ? "Hub réel" : "Simulation" }
    }

    private(set) var mode: HubMode
    private(set) var hub = HubState()
    private(set) var execution = ExecutionState()
    private(set) var log: [HubLogEntry] = []
    private(set) var simulatorLog: [String] = []

    @ObservationIgnored private var session: HubSession!
    @ObservationIgnored private var interpreter: Interpreter!
    @ObservationIgnored private var simulated: SimulatedTransport?
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private let sounds = SoundPlayer()

    init() {
        #if targetEnvironment(simulator)
        mode = .simulated
        #else
        mode = .real
        #endif
        rebuild()
    }

    // MARK: - Connexion

    func setMode(_ newMode: HubMode) {
        guard newMode != mode else { return }
        let oldSession = session
        let oldInterpreter = interpreter
        mode = newMode
        rebuild()
        Task {
            await oldInterpreter?.stop()
            await oldSession?.disconnect()
        }
    }

    func connect() {
        let session = session
        Task { await session?.connect() }
    }

    func disconnect() {
        let session = session
        Task { await session?.disconnect() }
    }

    /// Vrai pendant la recherche ou la connexion.
    var isConnecting: Bool {
        switch hub.connection {
        case .scanning, .connecting, .reconnecting: return true
        case .idle, .unavailable, .connected: return false
        }
    }

    var connectionText: String {
        switch hub.connection {
        case .idle: return "Non connecté"
        case .unavailable(let reason): return reason
        case .scanning: return "Recherche du hub…"
        case .connecting: return "Connexion…"
        case .connected(let name): return name
        case .reconnecting: return "Reconnexion…"
        }
    }

    // MARK: - Exécution

    func run(_ project: Project) {
        let interpreter = interpreter
        Task { await interpreter?.start(project) }
    }

    func stop() {
        let interpreter = interpreter
        Task { await interpreter?.stop() }
    }

    // MARK: - Simulation

    func inject(_ injection: SimulatedTransport.Injection) {
        simulated?.inject(injection)
    }

    /// Simule une secousse : un aller-retour brusque de l'inclinaison.
    func simulateShake(restingX: Int, restingY: Int) {
        guard let simulated else { return }
        simulated.inject(.tilt(x: restingX + 45, y: restingY))
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            simulated.inject(.tilt(x: restingX, y: restingY))
        }
    }

    /// Simule un appui bref sur le bouton du hub.
    func simulateButtonPress() {
        guard let simulated else { return }
        simulated.inject(.button(true))
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            simulated.inject(.button(false))
        }
    }

    func clearLogs() {
        log.removeAll()
        simulatorLog.removeAll()
    }

    // MARK: - Construction

    /// Crée transport, session et interpréteur pour le mode courant.
    private func rebuild() {
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        hub = HubState()
        execution = ExecutionState()

        let transport: HubTransport
        switch mode {
        case .simulated:
            let fake = SimulatedTransport()
            simulated = fake
            transport = fake
        case .real:
            simulated = nil
            transport = BLETransport()
        }

        let session = HubSession(transport: transport)
        self.session = session

        // Les états d'exécution passent par un flux pour arriver dans l'ordre.
        let (executionStates, continuation) = AsyncStream<ExecutionState>.makeStream()
        interpreter = Interpreter(device: HubDeviceAdapter(session: session, sounds: sounds)) { state in
            continuation.yield(state)
        }

        let hubStates = session.states()
        let entries = session.log.stream()
        listeners.append(Task { [weak self] in
            for await state in hubStates { self?.hub = state }
        })
        listeners.append(Task { [weak self] in
            for await state in executionStates { self?.execution = state }
        })
        listeners.append(Task { [weak self] in
            for await entry in entries { self?.append(entry) }
        })
        if let simulated {
            let lines = simulated.commandLog.stream()
            listeners.append(Task { [weak self] in
                for await line in lines { self?.appendSimulator(line) }
            })
        }
    }

    private func append(_ entry: HubLogEntry) {
        log.append(entry)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func appendSimulator(_ line: String) {
        simulatorLog.append(line)
        if simulatorLog.count > 200 { simulatorLog.removeFirst(simulatorLog.count - 200) }
    }
}
