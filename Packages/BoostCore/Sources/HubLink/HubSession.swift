import Foundation

/// Point d'entrée de la couche BLE : suit l'état du hub, configure les capteurs
/// et envoie les commandes en attendant leur fin réelle (Port Output Command Feedback).
public actor HubSession {

    public struct Tuning: Sendable {
        /// Écart en degrés entre deux notifications de position d'un moteur.
        public var motorPositionDelta: UInt32 = 2
        /// Marge ajoutée à la durée prévue avant de renoncer à attendre un Feedback.
        public var feedbackMargin: TimeInterval = 3
        /// Vitesse minimale supposée, en degrés par seconde pour 1 % de vitesse,
        /// pour borner l'attente d'une commande en degrés.
        public var slowestDegreesPerSecondPerPercent: Double = 2
        /// Variation d'inclinaison, en degrés entre deux mesures rapprochées, comptée comme une secousse.
        public var shakeThreshold = 25
        /// Intervalle maximal entre ces deux mesures.
        public var shakeWindow: TimeInterval = 0.35
        public init() {}
    }

    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<CommandOutcome, Error>
        var timeoutTask: Task<Void, Never>
        /// Vrai si la commande en a remplacé une autre : on attend alors de voir
        /// « en cours » avant d'accepter une fin, pour ignorer le Feedback tardif de l'ancienne.
        var needsInProgress: Bool
        var sawInProgress = false
    }

    /// Durée maximale de StartSpeedForTime (Int16, doc §3.27.7).
    private static let longestTimedRun = 30_000

    public private(set) var state = HubState()
    /// Journal des messages émis et reçus.
    public nonisolated let log = Broadcaster<HubLogEntry>()

    private let transport: HubTransport
    private let tuning: Tuning
    private let stateBroadcaster = Broadcaster<HubState>(replaysLast: true)
    private var pump: Task<Void, Never>?
    private var waiters: [UInt8: Waiter] = [:]
    private var inputModes: [UInt8: UInt8] = [:]
    private var lastTilt: (x: Int, y: Int, date: Date)?

    public init(transport: HubTransport, tuning: Tuning = Tuning()) {
        self.transport = transport
        self.tuning = tuning
        stateBroadcaster.send(HubState())
    }

    // MARK: - Connexion

    /// Flux de l'état du hub ; la dernière valeur connue est livrée d'abord.
    public nonisolated func states() -> AsyncStream<HubState> {
        stateBroadcaster.stream()
    }

    public func connect() {
        if pump == nil {
            let events = transport.events
            pump = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    await self.handle(event)
                }
            }
        }
        transport.start()
    }

    public func disconnect() {
        transport.stop()
    }

    // MARK: - Moteurs, commandes attendues

    /// Fait tourner un moteur pendant une durée, puis rend la main quand le hub signale la fin.
    @discardableResult
    public func run(_ port: LogicalPort, speed: Int, milliseconds: Int,
                    endState: MotorEndState = .brake) async throws -> CommandOutcome {
        if port == .motorAB {
            return try await runTank(left: speed, right: speed, milliseconds: milliseconds, endState: endState)
        }
        try requireConnection()
        guard milliseconds > 0 else { return .completed }
        let id = try require(port)
        let clamped = Self.clampSpeed(speed)

        if milliseconds > Self.longestTimedRun {
            return try await longRun(milliseconds: milliseconds, endState: endState, ports: [port]) {
                self.transmit(LWPEncoder.startSpeed(port: id, speed: clamped), preempting: id)
            }
        }
        let data = LWPEncoder.startSpeedForTime(port: id, milliseconds: UInt16(milliseconds), speed: clamped, endState: endState)
        return try await sendAndAwait(port: id, data: data, timeout: Double(milliseconds) / 1000 + tuning.feedbackMargin)
    }

    /// Fait tourner un moteur d'un angle donné. Un angle négatif inverse le sens.
    @discardableResult
    public func run(_ port: LogicalPort, speed: Int, degrees: Int,
                    endState: MotorEndState = .brake) async throws -> CommandOutcome {
        if port == .motorAB {
            return try await runTank(left: speed, right: speed, degrees: degrees, endState: endState)
        }
        try requireConnection()
        let id = try require(port)
        // La doc impose un angle positif : le sens vient du signe de la vitesse.
        let signedSpeed = degrees < 0 ? -speed : speed
        let clamped = Self.clampSpeed(signedSpeed)
        let angle = abs(degrees)
        guard angle > 0, clamped != 0 else { return .completed }

        let data = LWPEncoder.startSpeedForDegrees(port: id, degrees: UInt32(angle), speed: clamped, endState: endState)
        return try await sendAndAwait(port: id, data: data, timeout: degreesTimeout(angle, speed: Int(clamped)))
    }

    /// Fait tourner A et B ensemble pendant une durée, avec une vitesse par moteur.
    @discardableResult
    public func runTank(left: Int, right: Int, milliseconds: Int,
                        endState: MotorEndState = .brake) async throws -> CommandOutcome {
        try requireConnection()
        guard milliseconds > 0 else { return .completed }
        let l = Self.clampSpeed(left)
        let r = Self.clampSpeed(right)

        guard let virtual = state.portID(for: .motorAB) else {
            warn("Port virtuel A+B absent : commandes envoyées séparément à A et B.")
            return try await both({ try await self.run(.motorA, speed: left, milliseconds: milliseconds, endState: endState) },
                                  { try await self.run(.motorB, speed: right, milliseconds: milliseconds, endState: endState) })
        }
        if milliseconds > Self.longestTimedRun {
            return try await longRun(milliseconds: milliseconds, endState: endState, ports: [.motorAB]) {
                self.transmit(LWPEncoder.startSpeedDual(port: virtual, speedLeft: l, speedRight: r), preempting: virtual)
            }
        }
        let data = LWPEncoder.startSpeedForTimeDual(port: virtual, milliseconds: UInt16(milliseconds),
                                                    speedLeft: l, speedRight: r, endState: endState)
        return try await sendAndAwait(port: virtual, data: data, timeout: Double(milliseconds) / 1000 + tuning.feedbackMargin)
    }

    /// Fait tourner A et B ensemble d'un angle donné (moyenne des deux moteurs, doc §3.31).
    @discardableResult
    public func runTank(left: Int, right: Int, degrees: Int,
                        endState: MotorEndState = .brake) async throws -> CommandOutcome {
        try requireConnection()
        let sign = degrees < 0 ? -1 : 1
        let l = Self.clampSpeed(left * sign)
        let r = Self.clampSpeed(right * sign)
        let angle = abs(degrees)
        guard angle > 0, l != 0 || r != 0 else { return .completed }

        guard let virtual = state.portID(for: .motorAB) else {
            warn("Port virtuel A+B absent : commandes envoyées séparément à A et B.")
            return try await both({ try await self.run(.motorA, speed: Int(l), degrees: angle, endState: endState) },
                                  { try await self.run(.motorB, speed: Int(r), degrees: angle, endState: endState) })
        }
        let data = LWPEncoder.startSpeedForDegreesDual(port: virtual, degrees: UInt32(angle),
                                                       speedLeft: l, speedRight: r, endState: endState)
        // L'angle demandé est la moyenne des deux moteurs.
        let average = max(1, (abs(Int(l)) + abs(Int(r))) / 2)
        return try await sendAndAwait(port: virtual, data: data, timeout: degreesTimeout(angle, speed: average))
    }

    // MARK: - Moteurs, commandes immédiates

    /// Démarre un moteur sans limite de durée et rend la main aussitôt.
    public func start(_ port: LogicalPort, speed: Int) throws {
        if port == .motorAB {
            try startTank(left: speed, right: speed)
            return
        }
        try requireConnection()
        let id = try require(port)
        transmit(LWPEncoder.startSpeed(port: id, speed: Self.clampSpeed(speed)), preempting: id)
    }

    /// Démarre A et B sans limite de durée.
    public func startTank(left: Int, right: Int) throws {
        try requireConnection()
        if let virtual = state.portID(for: .motorAB) {
            transmit(LWPEncoder.startSpeedDual(port: virtual, speedLeft: Self.clampSpeed(left),
                                               speedRight: Self.clampSpeed(right)), preempting: virtual)
        } else {
            try start(.motorA, speed: left)
            try start(.motorB, speed: right)
        }
    }

    /// Arrête un moteur. Pour A+B, chaque moteur est arrêté séparément, ce qui
    /// interrompt aussi une commande en cours sur le port virtuel (doc §4).
    public func stop(_ port: LogicalPort, endState: MotorEndState = .brake) throws {
        try requireConnection()
        let targets: [LogicalPort] = port == .motorAB ? [.motorA, .motorB] : [port]
        for target in targets {
            let id = try require(target)
            switch endState {
            case .brake:
                transmit(LWPEncoder.startPower(port: id, power: MotorPower.brake), preempting: id)
            case .float:
                transmit(LWPEncoder.startPower(port: id, power: MotorPower.float), preempting: id)
            case .hold:
                transmit(LWPEncoder.startSpeed(port: id, speed: 0), preempting: id)
            }
        }
    }

    /// Freine tous les moteurs présents. Sans effet si le hub n'est pas connecté.
    public func stopAllMotors() {
        guard state.isConnected else { return }
        for device in state.devices.values.sorted(by: { $0.port < $1.port })
        where device.ioType.isTachoMotor && device.members == nil {
            transmit(LWPEncoder.startPower(port: device.port, power: MotorPower.brake), preempting: device.port)
        }
        // Les commandes sur port virtuel sont interrompues par l'arrêt de leurs moteurs.
        for port in Array(waiters.keys) {
            resolve(port: port, id: nil, with: .success(.discarded))
        }
    }

    /// Remet à zéro le compteur de rotation d'un moteur (arrête aussi ce moteur).
    public func resetRotation(_ port: LogicalPort) throws {
        try requireConnection()
        let targets: [LogicalPort] = port == .motorAB ? [.motorA, .motorB] : [port]
        for target in targets {
            let id = try require(target)
            transmit(LWPEncoder.presetEncoder(port: id, position: 0), preempting: id)
            state.motorPositions[id] = 0
        }
        publish()
    }

    // MARK: - LED et hub

    public func setLED(_ color: LEDColor) throws {
        try requireConnection()
        let id = try require(.led)
        transmit(LWPEncoder.setLEDColor(port: id, colorIndex: color.rawValue))
    }

    /// Demande au hub de s'éteindre.
    public func switchOffHub() {
        guard state.isConnected else { return }
        transmit(LWPEncoder.hubAction(.switchOff))
    }

    // MARK: - Attente des Feedback

    private func sendAndAwait(port: UInt8, data: Data, timeout: TimeInterval) async throws -> CommandOutcome {
        let id = UUID()
        let replacing = waiters[port] != nil
        resolve(port: port, id: nil, with: .success(.discarded))

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandOutcome, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    } catch {
                        return
                    }
                    await self?.timeOut(port: port, id: id)
                }
                waiters[port] = Waiter(id: id, continuation: continuation, timeoutTask: timeoutTask,
                                       needsInProgress: replacing)
                transmit(data)
            }
        } onCancel: {
            Task { await self.resolve(port: port, id: id, with: .failure(CancellationError())) }
        }
    }

    /// Termine l'attente sur un port. `id` nil = quel que soit l'attendeur.
    private func resolve(port: UInt8, id: UUID?, with result: Result<CommandOutcome, Error>) {
        guard let waiter = waiters[port], id == nil || waiter.id == id else { return }
        waiters[port] = nil
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(with: result)
    }

    private func timeOut(port: UInt8, id: UUID) {
        guard waiters[port]?.id == id else { return }
        warn("Aucun Feedback du port \(port) dans le délai prévu : la commande est considérée terminée.")
        resolve(port: port, id: id, with: .success(.timedOut))
    }

    private func handleFeedback(_ feedback: PortFeedback) {
        guard var waiter = waiters[feedback.port] else { return }
        let flags = feedback.flags
        if flags.contains(.inProgress) {
            waiter.sawInProgress = true
            waiters[feedback.port] = waiter
        }
        guard flags.contains(.completed) || flags.contains(.idle) else { return }
        if waiter.needsInProgress && !waiter.sawInProgress {
            // Fin tardive de la commande précédente : la nôtre n'a pas encore démarré.
            return
        }
        let interrupted = flags.contains(.discarded) && !flags.contains(.completed)
        resolve(port: feedback.port, id: waiter.id, with: .success(interrupted ? .discarded : .completed))
    }

    /// Commande plus longue que la limite du protocole : démarrage, attente locale, arrêt.
    private func longRun(milliseconds: Int, endState: MotorEndState, ports: [LogicalPort],
                         start: () -> Void) async throws -> CommandOutcome {
        start()
        do {
            try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
        } catch {
            for port in ports { try? stop(port, endState: .brake) }
            throw error
        }
        for port in ports { try stop(port, endState: endState) }
        return .completed
    }

    /// Lance deux commandes en parallèle et combine leurs issues.
    private func both(_ first: @escaping @Sendable () async throws -> CommandOutcome,
                      _ second: @escaping @Sendable () async throws -> CommandOutcome) async throws -> CommandOutcome {
        try await withThrowingTaskGroup(of: CommandOutcome.self) { group in
            group.addTask { try await first() }
            group.addTask { try await second() }
            var combined = CommandOutcome.completed
            for try await outcome in group where outcome != .completed {
                combined = outcome
            }
            return combined
        }
    }

    private func degreesTimeout(_ degrees: Int, speed: Int) -> TimeInterval {
        let rate = max(1, Double(abs(speed)) * tuning.slowestDegreesPerSecondPerPercent)
        return Double(degrees) / rate + tuning.feedbackMargin
    }

    // MARK: - Événements du transport

    private func handle(_ event: TransportEvent) {
        switch event {
        case .state(let connection):
            handleConnection(connection)
        case .data(let data):
            log.send(HubLogEntry(kind: .received, text: data.hexString))
            do {
                handleMessage(try LWPDecoder.decode(data))
            } catch {
                warn("Message illisible (\(error)) : \(data.hexString)")
            }
        }
    }

    private func handleConnection(_ connection: TransportState) {
        let wasConnected = state.isConnected
        state.connection = connection

        if connection.isConnected {
            info("Connecté au hub.")
            // Abonnements aux propriétés du hub (doc §3.5).
            transmit(LWPEncoder.hubProperty(.batteryVoltage, .enableUpdates))
            transmit(LWPEncoder.hubProperty(.button, .enableUpdates))
        } else {
            if wasConnected { info("Hub déconnecté.") }
            state.devices.removeAll()
            state.motorPositions.removeAll()
            state.color = nil
            state.distance = nil
            state.tiltX = 0
            state.tiltY = 0
            state.buttonPressed = false
            state.batteryPercent = nil
            inputModes.removeAll()
            lastTilt = nil
            for port in Array(waiters.keys) {
                resolve(port: port, id: nil, with: .failure(HubError.notConnected))
            }
        }
        publish()
    }

    private func handleMessage(_ message: LWPMessage) {
        switch message {
        case .hubProperty(let update):
            guard update.operation == HubPropertyOperation.update.rawValue else { return }
            if let battery = update.batteryPercent {
                state.batteryPercent = battery
                publish()
            } else if let pressed = update.buttonPressed {
                state.buttonPressed = pressed
                publish()
            }

        case .hubAction(let action):
            if action == HubAction.willSwitchOff.rawValue { info("Le hub s'éteint.") }
            if action == HubAction.willDisconnect.rawValue { info("Le hub se déconnecte.") }

        case .hubAlert(let type, _, let payload):
            if payload == 0xFF { warn("Alerte du hub, type \(type).") }

        case .attachedIO(let event):
            handleAttachedIO(event)

        case .error(let commandType, let code):
            // 0x01 et 0x02 sont des accusés de réception (doc §3.9.2).
            if code > 0x02 {
                warn(String(format: "Erreur du hub : commande 0x%02X, code 0x%02X.", commandType, code))
            }

        case .portInformation(let information):
            guard information.informationType == PortInformationType.modeInfo.rawValue else { return }
            for mode in 0..<information.modeCount {
                transmit(LWPEncoder.portModeInformationRequest(port: information.port, mode: mode, type: .name))
            }

        case .portModeInformation(let information):
            guard let name = information.name else { return }
            info("Port \(information.port), mode \(information.mode) : « \(name) »")
            checkModeName(information, name: name)

        case .portValue(let port, let payload):
            handleValue(port: port, payload: payload)

        case .portInputFormat(let format):
            inputModes[format.port] = format.mode

        case .outputFeedback(let feedbacks):
            for feedback in feedbacks { handleFeedback(feedback) }

        case .unknown(let type, _):
            info(String(format: "Message ignoré, type 0x%02X.", type))
        }
    }

    private func handleAttachedIO(_ event: AttachedIOEvent) {
        switch event {
        case .detached(let port):
            let removed = state.devices.removeValue(forKey: port)
            state.motorPositions[port] = nil
            inputModes[port] = nil
            if removed?.ioType == .visionSensor {
                state.color = nil
                state.distance = nil
            }
            resolve(port: port, id: nil, with: .success(.discarded))
            info("Port \(port) : appareil débranché.")

        case .attached(let port, let ioType):
            state.devices[port] = AttachedDevice(port: port, ioType: ioType)
            info("Port \(port) : \(ioType).")
            if let mode = inputMode(for: ioType) {
                let delta = ioType.isTachoMotor ? tuning.motorPositionDelta : 1
                inputModes[port] = mode
                transmit(LWPEncoder.portInputFormatSetup(port: port, mode: mode, deltaInterval: delta, notify: true))
                // Sert à vérifier les numéros de mode non documentés.
                transmit(LWPEncoder.portInformationRequest(port: port, type: .modeInfo))
            }

        case .attachedVirtual(let port, let ioType, let portA, let portB):
            state.devices[port] = AttachedDevice(port: port, ioType: ioType, members: [portA, portB])
            info("Port virtuel \(port) : ports \(portA) et \(portB).")
        }
        publish()
    }

    private func inputMode(for ioType: IOType) -> UInt8? {
        if ioType.isTachoMotor { return DefaultMode.motorPosition }
        if ioType == .visionSensor { return DefaultMode.visionCombined }
        if ioType == .internalTilt { return DefaultMode.tiltAngle }
        return nil
    }

    private func expectedModeName(for ioType: IOType) -> String? {
        if ioType.isTachoMotor { return DefaultMode.motorPositionName }
        if ioType == .visionSensor { return DefaultMode.visionCombinedName }
        if ioType == .internalTilt { return DefaultMode.tiltAngleName }
        return nil
    }

    private func checkModeName(_ information: PortModeInformation, name: String) {
        guard let device = state.devices[information.port],
              let mode = inputMode(for: device.ioType), mode == information.mode,
              let expected = expectedModeName(for: device.ioType) else { return }
        if name.trimmingCharacters(in: .whitespaces) != expected {
            warn("Port \(information.port) : le mode \(mode) s'appelle « \(name) » au lieu de « \(expected) ». "
                 + "Les valeurs de ce capteur risquent d'être mal interprétées.")
        }
    }

    private func handleValue(port: UInt8, payload: Data) {
        guard let device = state.devices[port], let mode = inputModes[port] else { return }

        if device.ioType.isTachoMotor, mode == DefaultMode.motorPosition {
            guard let position = payload.int32LE(at: 0) else { return }
            state.motorPositions[port] = Int(position)

        } else if device.ioType == .visionSensor, mode == DefaultMode.visionCombined {
            guard payload.count >= 2 else { return }
            let bytes = [UInt8](payload)
            state.color = SensorColor(rawValue: bytes[0])
            state.distance = bytes[1] <= 10 ? Int(bytes[1]) : nil

        } else if device.ioType == .internalTilt, mode == DefaultMode.tiltAngle {
            guard let x = payload.int8(at: 0), let y = payload.int8(at: 1) else { return }
            let now = Date()
            if let last = lastTilt, now.timeIntervalSince(last.date) <= tuning.shakeWindow,
               abs(Int(x) - last.x) + abs(Int(y) - last.y) >= tuning.shakeThreshold {
                state.shakeCount += 1
            }
            lastTilt = (Int(x), Int(y), now)
            state.tiltX = Int(x)
            state.tiltY = Int(y)

        } else {
            return
        }
        publish()
    }

    // MARK: - Utilitaires

    private func requireConnection() throws {
        guard state.isConnected else { throw HubError.notConnected }
    }

    private func require(_ port: LogicalPort) throws -> UInt8 {
        guard let id = state.portID(for: port) else { throw HubError.deviceMissing(port) }
        return id
    }

    /// Envoie un message. `preempting` : port dont l'attente en cours est abandonnée.
    private func transmit(_ data: Data, preempting port: UInt8? = nil) {
        if let port {
            resolve(port: port, id: nil, with: .success(.discarded))
        }
        log.send(HubLogEntry(kind: .sent, text: data.hexString))
        transport.send(data)
    }

    private func publish() {
        stateBroadcaster.send(state)
    }

    private func info(_ text: String) {
        log.send(HubLogEntry(kind: .info, text: text))
    }

    private func warn(_ text: String) {
        log.send(HubLogEntry(kind: .warning, text: text))
    }

    private static func clampSpeed(_ speed: Int) -> Int8 {
        Int8(max(-100, min(100, speed)))
    }
}
