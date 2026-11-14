import Foundation

/// Faux hub : répond avec de vrais octets du protocole et journalise les commandes.
/// Sert au simulateur Xcode et aux tests unitaires.
public final class SimulatedTransport: HubTransport, @unchecked Sendable {

    public struct Configuration: Sendable {
        /// Facteur appliqué aux durées réelles (0.01 = cent fois plus vite, pour les tests).
        public var timeScale: Double = 1.0
        /// Vitesse simulée d'un moteur à 100 %, en degrés par seconde.
        public var fullSpeedDegreesPerSecond: Double = 900
        public var hasVisionSensor = true
        public var hasExternalMotor = true
        public var name = "Hub simulé"
        public init() {}
    }

    /// Valeurs de capteur injectées à la main depuis l'interface ou les tests.
    public enum Injection: Sendable {
        /// Numéro de couleur brut, nil = aucune couleur.
        case color(UInt8?)
        /// Distance brute 0 à 10, nil = rien en vue.
        case distance(UInt8?)
        case tilt(x: Int, y: Int)
        case button(Bool)
        case battery(Int)
    }

    public let events: AsyncStream<TransportEvent>
    /// Journal lisible des commandes reçues par le faux hub.
    public let commandLog = Broadcaster<String>()

    private let mailbox: AsyncStream<SimulatedHub.Mail>.Continuation
    private let worker: Task<Void, Never>

    public init(configuration: Configuration = Configuration()) {
        let (events, eventContinuation) = AsyncStream<TransportEvent>.makeStream()
        let (mails, mailContinuation) = AsyncStream<SimulatedHub.Mail>.makeStream()
        self.events = events
        self.mailbox = mailContinuation
        let hub = SimulatedHub(configuration: configuration, output: eventContinuation, log: commandLog)
        // Un seul lecteur : les messages sont traités dans l'ordre d'envoi.
        self.worker = Task {
            for await mail in mails {
                await hub.handle(mail)
            }
        }
    }

    deinit {
        mailbox.finish()
    }

    public func start() { mailbox.yield(.start) }
    public func stop() { mailbox.yield(.stop) }
    public func send(_ data: Data) { mailbox.yield(.data(data)) }

    /// Modifie une valeur de capteur du faux hub.
    public func inject(_ injection: Injection) { mailbox.yield(.inject(injection)) }
}

// MARK: - Faux hub

actor SimulatedHub {
    enum Mail: Sendable {
        case start
        case stop
        case data(Data)
        case inject(SimulatedTransport.Injection)
    }

    private enum Limit {
        case indefinite
        case seconds(Double)
        case degrees(Double)
    }

    private struct InputFormat {
        var mode: UInt8
        var delta: UInt32
        var notify: Bool
    }

    private struct Running {
        var id: UUID
        var task: Task<Void, Never>
    }

    // Numéros de port du faux hub. Ils n'ont de sens que pour la simulation :
    // la session lit les ports dans les messages Hub Attached I/O.
    static let portA: UInt8 = 0x00
    static let portB: UInt8 = 0x01
    static let portVision: UInt8 = 0x02
    static let portExternal: UInt8 = 0x03
    static let portAB: UInt8 = 0x10
    static let portLED: UInt8 = 0x32
    static let portTilt: UInt8 = 0x3A

    private let configuration: SimulatedTransport.Configuration
    private let output: AsyncStream<TransportEvent>.Continuation
    private let log: Broadcaster<String>

    private var connected = false
    private var formats: [UInt8: InputFormat] = [:]
    private var positions: [UInt8: Double] = [:]
    private var lastReported: [UInt8: Int32] = [:]
    private var running: [UInt8: Running] = [:]

    private var color: UInt8?
    private var distance: UInt8?
    private var tiltX: Int8 = 0
    private var tiltY: Int8 = 0
    private var button = false
    private var battery: UInt8 = 100
    private var batteryUpdates = false
    private var buttonUpdates = false

    init(configuration: SimulatedTransport.Configuration,
         output: AsyncStream<TransportEvent>.Continuation,
         log: Broadcaster<String>) {
        self.configuration = configuration
        self.output = output
        self.log = log
    }

    // MARK: - Boîte aux lettres

    func handle(_ mail: Mail) async {
        switch mail {
        case .start:
            await connect()
        case .stop:
            disconnect()
        case .data(let data):
            guard connected else { return }
            receive([UInt8](data))
        case .inject(let injection):
            apply(injection)
        }
    }

    private func connect() async {
        guard !connected else { return }
        output.yield(.state(.scanning))
        output.yield(.state(.connecting))
        try? await Task.sleep(nanoseconds: nanoseconds(0.2))
        connected = true
        output.yield(.state(.connected(name: configuration.name)))
        log.send("Connexion au faux hub")

        attach(Self.portA, .internalMotorTacho)
        attach(Self.portB, .internalMotorTacho)
        emit(.hubAttachedIO, [Self.portAB, 0x02, 0x27, 0x00, Self.portA, Self.portB])
        attach(Self.portLED, .rgbLight)
        attach(Self.portTilt, .internalTilt)
        if configuration.hasVisionSensor { attach(Self.portVision, .visionSensor) }
        if configuration.hasExternalMotor { attach(Self.portExternal, .externalMotorTacho) }
    }

    private func disconnect() {
        for entry in running.values { entry.task.cancel() }
        running.removeAll()
        formats.removeAll()
        lastReported.removeAll()
        batteryUpdates = false
        buttonUpdates = false
        if connected { log.send("Déconnexion du faux hub") }
        connected = false
        output.yield(.state(.idle))
    }

    private func apply(_ injection: SimulatedTransport.Injection) {
        switch injection {
        case .color(let value):
            color = value
            if connected { reportValue(Self.portVision) }
        case .distance(let value):
            distance = value
            if connected { reportValue(Self.portVision) }
        case .tilt(let x, let y):
            tiltX = Int8(clamping: x)
            tiltY = Int8(clamping: y)
            if connected { reportValue(Self.portTilt) }
        case .button(let pressed):
            button = pressed
            if connected, buttonUpdates { sendProperty(.button) }
        case .battery(let percent):
            battery = UInt8(clamping: max(0, min(100, percent)))
            if connected, batteryUpdates { sendProperty(.batteryVoltage) }
        }
    }

    // MARK: - Messages descendants

    private func receive(_ bytes: [UInt8]) {
        guard bytes.count >= 3, Int(bytes[0]) == bytes.count else { return }
        let type = bytes[2]
        let body = Array(bytes.dropFirst(3))

        switch MessageType(rawValue: type) {
        case .hubProperties:
            guard body.count >= 2, let property = HubProperty(rawValue: body[0]) else { return sendError(type, 0x06) }
            switch HubPropertyOperation(rawValue: body[1]) {
            case .enableUpdates:
                if property == .batteryVoltage { batteryUpdates = true }
                if property == .button { buttonUpdates = true }
                sendProperty(property)
            case .disableUpdates:
                if property == .batteryVoltage { batteryUpdates = false }
                if property == .button { buttonUpdates = false }
            case .requestUpdate:
                sendProperty(property)
            default:
                sendError(type, 0x06)
            }

        case .hubActions:
            guard let action = body.first else { return sendError(type, 0x06) }
            if action == HubAction.switchOff.rawValue {
                emit(.hubActions, [HubAction.willSwitchOff.rawValue])
                disconnect()
            } else if action == HubAction.disconnect.rawValue {
                emit(.hubActions, [HubAction.willDisconnect.rawValue])
                disconnect()
            }

        case .portInformationRequest:
            guard body.count >= 2 else { return sendError(type, 0x06) }
            if body[1] == PortInformationType.portValue.rawValue {
                reportValue(body[0], force: true)
            } else if body[1] == PortInformationType.modeInfo.rawValue {
                let names = modeNames(for: body[0])
                let mask = names.isEmpty ? UInt16(0) : UInt16((1 << names.count) - 1)
                emit(.portInformation, [body[0], 0x01, 0x03, UInt8(names.count),
                                        UInt8(mask & 0xFF), UInt8(mask >> 8), UInt8(mask & 0xFF), UInt8(mask >> 8)])
            } else {
                sendError(type, 0x06)
            }

        case .portModeInformationRequest:
            guard body.count >= 3 else { return sendError(type, 0x06) }
            let names = modeNames(for: body[0])
            guard body[2] == ModeInformationType.name.rawValue, Int(body[1]) < names.count else {
                return sendError(type, 0x06)
            }
            emit(.portModeInformation, [body[0], body[1], 0x00] + Array(names[Int(body[1])].utf8))

        case .portInputFormatSetupSingle:
            guard body.count >= 7 else { return sendError(type, 0x06) }
            let delta = UInt32(body[2]) | (UInt32(body[3]) << 8) | (UInt32(body[4]) << 16) | (UInt32(body[5]) << 24)
            formats[body[0]] = InputFormat(mode: body[1], delta: delta, notify: body[6] != 0)
            emit(.portInputFormatSingle, Array(body.prefix(7)))
            reportValue(body[0], force: true)

        case .portOutputCommand:
            guard body.count >= 3 else { return sendError(type, 0x06) }
            handleOutput(port: body[0], subCommand: body[2], payload: Array(body.dropFirst(3)))

        default:
            sendError(type, 0x05)
        }
    }

    // MARK: - Commandes de sortie

    private func handleOutput(port: UInt8, subCommand: UInt8, payload: [UInt8]) {
        if port == Self.portLED {
            guard subCommand == OutputSubCommand.writeDirectModeData.rawValue, payload.count >= 2 else {
                return sendError(MessageType.portOutputCommand.rawValue, 0x06)
            }
            if payload[0] == 0 {
                log.send("LED : couleur n° \(payload[1])")
            } else {
                log.send("LED : données mode \(payload[0]) = \(Data(payload.dropFirst()).hexString)")
            }
            feedback(port, [.completed, .idle])
            return
        }

        guard motorMembers(of: port) != nil else {
            return sendError(MessageType.portOutputCommand.rawValue, 0x06)
        }
        let name = portName(port)
        let dual = port == Self.portAB

        func s8(_ index: Int) -> Double { Double(Int8(bitPattern: payload[index])) }
        func u16(_ index: Int) -> Double { Double(UInt16(payload[index]) | (UInt16(payload[index + 1]) << 8)) }
        func i32(_ index: Int) -> Int32 {
            Int32(bitPattern: UInt32(payload[index]) | (UInt32(payload[index + 1]) << 8)
                  | (UInt32(payload[index + 2]) << 16) | (UInt32(payload[index + 3]) << 24))
        }

        switch OutputSubCommand(rawValue: subCommand) {
        case .writeDirectModeData where payload.count >= 2 && payload[0] == 0:
            let power = Int8(bitPattern: payload[1])
            if power == MotorPower.brake || power == MotorPower.float {
                log.send("\(name) : arrêt (\(power == MotorPower.brake ? "frein" : "roue libre"))")
                startMotion(port: port, left: 0, right: 0, limit: .indefinite)
            } else {
                log.send("\(name) : puissance \(power) %")
                startMotion(port: port, left: Double(power), right: Double(power), limit: .indefinite)
            }

        case .writeDirectModeData where payload.count >= 5 && payload[0] == DefaultMode.motorPosition:
            let value = i32(1)
            log.send("\(name) : position remise à \(value)°")
            startMotion(port: port, left: 0, right: 0, limit: .indefinite)
            for member in motorMembers(of: port) ?? [] {
                positions[member] = Double(value)
                reportValue(member, force: true)
            }

        case .startSpeed where payload.count >= 3 && !dual:
            log.send("\(name) : vitesse \(Int(s8(0))) %")
            startMotion(port: port, left: s8(0), right: s8(0), limit: .indefinite)

        case .startSpeedDual where payload.count >= 4 && dual:
            log.send("\(name) : vitesses \(Int(s8(0))) % et \(Int(s8(1))) %")
            startMotion(port: port, left: s8(0), right: s8(1), limit: .indefinite)

        case .startSpeedForTime where payload.count >= 6 && !dual:
            log.send("\(name) : vitesse \(Int(s8(2))) % pendant \(Int(u16(0))) ms")
            startMotion(port: port, left: s8(2), right: s8(2), limit: .seconds(u16(0) / 1000))

        case .startSpeedForTimeDual where payload.count >= 7 && dual:
            log.send("\(name) : vitesses \(Int(s8(2))) % et \(Int(s8(3))) % pendant \(Int(u16(0))) ms")
            startMotion(port: port, left: s8(2), right: s8(3), limit: .seconds(u16(0) / 1000))

        case .startSpeedForDegrees where payload.count >= 8 && !dual:
            log.send("\(name) : vitesse \(Int(s8(4))) % sur \(i32(0))°")
            startMotion(port: port, left: s8(4), right: s8(4), limit: .degrees(Double(i32(0))))

        case .startSpeedForDegreesDual where payload.count >= 9 && dual:
            log.send("\(name) : vitesses \(Int(s8(4))) % et \(Int(s8(5))) % sur \(i32(0))°")
            startMotion(port: port, left: s8(4), right: s8(5), limit: .degrees(Double(i32(0))))

        case .gotoAbsolutePosition where payload.count >= 8 && !dual:
            let target = Double(i32(0))
            let current = positions[port] ?? 0
            let speed = abs(s8(4)) * (target >= current ? 1 : -1)
            log.send("\(name) : aller à \(Int(target))° à \(Int(abs(s8(4)))) %")
            startMotion(port: port, left: speed, right: speed, limit: .degrees(abs(target - current)))

        default:
            sendError(MessageType.portOutputCommand.rawValue, 0x06)
        }
    }

    /// Applique la machine à états de la doc §4 pour une commande immédiate.
    private func startMotion(port: UInt8, left: Double, right: Double, limit: Limit) {
        // Une commande sur un moteur interrompt le port virtuel qui le contient, et inversement.
        let members = Set(motorMembers(of: port) ?? [])
        for (otherPort, entry) in running where otherPort != port {
            guard !members.isDisjoint(with: motorMembers(of: otherPort) ?? []) else { continue }
            entry.task.cancel()
            running[otherPort] = nil
            feedback(otherPort, [.idle, .discarded])
        }

        let replaced = running[port] != nil
        running[port]?.task.cancel()
        running[port] = nil

        let fullSpeed = max(1, configuration.fullSpeedDegreesPerSecond)
        let fastest = max(abs(left), abs(right)) / 100
        var duration: Double?
        switch limit {
        case .indefinite:
            duration = nil
        case .seconds(let seconds):
            duration = seconds
        case .degrees(let degrees):
            duration = fastest > 0 ? degrees / (fastest * fullSpeed) : 0
        }

        let stopsNow = (left == 0 && right == 0 && duration == nil) || duration == 0
        if stopsNow {
            feedback(port, replaced ? [.idle, .completed, .discarded] : [.idle, .completed])
            return
        }

        feedback(port, replaced ? [.inProgress, .discarded] : [.inProgress])
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runMotion(id: id, port: port, left: left, right: right, duration: duration)
        }
        running[port] = Running(id: id, task: task)
    }

    private func runMotion(id: UUID, port: UInt8, left: Double, right: Double, duration: Double?) async {
        let tick = 0.05
        let fullSpeed = configuration.fullSpeedDegreesPerSecond
        let members = motorMembers(of: port) ?? []
        var elapsed = 0.0

        while duration == nil || elapsed < duration! {
            let step = duration.map { min(tick, $0 - elapsed) } ?? tick
            do {
                try await Task.sleep(nanoseconds: nanoseconds(step))
            } catch {
                return
            }
            guard running[port]?.id == id else { return }
            for (index, member) in members.enumerated() {
                let speed = (members.count > 1 && index == 1) ? right : left
                positions[member, default: 0] += speed / 100 * fullSpeed * step
                reportValue(member)
            }
            elapsed += step
        }

        guard running[port]?.id == id else { return }
        running[port] = nil
        feedback(port, [.idle, .completed])
    }

    // MARK: - Valeurs de capteur

    /// Envoie la valeur d'un port s'il est abonné (ou si `force`), en respectant son delta.
    private func reportValue(_ port: UInt8, force: Bool = false) {
        guard let format = formats[port], format.notify || force else { return }

        switch port {
        case Self.portVision where configuration.hasVisionSensor:
            guard format.mode == DefaultMode.visionCombined else { return }
            emit(.portValueSingle, [port, color ?? 0xFF, distance ?? 0xFF, 0x00, 0x00])

        case Self.portTilt:
            guard format.mode == DefaultMode.tiltAngle else { return }
            emit(.portValueSingle, [port, UInt8(bitPattern: tiltX), UInt8(bitPattern: tiltY)])

        case Self.portA, Self.portB, Self.portExternal:
            guard format.mode == DefaultMode.motorPosition else { return }
            let value = Int32((positions[port] ?? 0).rounded())
            if !force, let last = lastReported[port],
               abs(Int64(value) - Int64(last)) < Int64(max(1, format.delta)) {
                return
            }
            lastReported[port] = value
            let raw = UInt32(bitPattern: value)
            emit(.portValueSingle, [port, UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF),
                                    UInt8((raw >> 16) & 0xFF), UInt8(raw >> 24)])

        default:
            return
        }
    }

    // MARK: - Émission

    private func attach(_ port: UInt8, _ type: IOType) {
        emit(.hubAttachedIO, [port, 0x01, UInt8(type.rawValue & 0xFF), UInt8(type.rawValue >> 8),
                              0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x10])
    }

    private func sendProperty(_ property: HubProperty) {
        let update = HubPropertyOperation.update.rawValue
        switch property {
        case .batteryVoltage:
            emit(.hubProperties, [property.rawValue, update, battery])
        case .button:
            emit(.hubProperties, [property.rawValue, update, button ? 1 : 0])
        case .advertisingName:
            emit(.hubProperties, [property.rawValue, update] + Array("Sim Hub".utf8))
        case .firmwareVersion:
            emit(.hubProperties, [property.rawValue, update, 0x00, 0x00, 0x00, 0x10])
        }
    }

    private func feedback(_ port: UInt8, _ flags: FeedbackFlags) {
        emit(.portOutputCommandFeedback, [port, flags.rawValue])
    }

    private func sendError(_ commandType: UInt8, _ code: UInt8) {
        emit(.genericError, [commandType, code])
    }

    private func emit(_ type: MessageType, _ body: [UInt8]) {
        output.yield(.data(LWPEncoder.frame(type, body)))
    }

    // MARK: - Description des ports

    private func motorMembers(of port: UInt8) -> [UInt8]? {
        switch port {
        case Self.portA, Self.portB:
            return [port]
        case Self.portExternal where configuration.hasExternalMotor:
            return [port]
        case Self.portAB:
            return [Self.portA, Self.portB]
        default:
            return nil
        }
    }

    private func portName(_ port: UInt8) -> String {
        switch port {
        case Self.portA: return "Moteur A"
        case Self.portB: return "Moteur B"
        case Self.portAB: return "Moteurs A+B"
        case Self.portExternal: return "Moteur externe"
        default: return "Port \(port)"
        }
    }

    /// Noms de mode renvoyés par le faux hub (NON DOCUMENTÉ : noms communautaires).
    private func modeNames(for port: UInt8) -> [String] {
        switch port {
        case Self.portA, Self.portB, Self.portExternal:
            return ["POWER", "SPEED", "POS"]
        case Self.portVision:
            return ["COLOR", "PROX", "COUNT", "REFLT", "AMBI", "COL O", "RGB I", "IR Tx", "SPEC 1"]
        case Self.portTilt:
            return ["ANGLE", "TILT", "ORINT", "IMPCT"]
        case Self.portLED:
            return ["COL O", "RGB O"]
        default:
            return []
        }
    }

    private func nanoseconds(_ seconds: Double) -> UInt64 {
        UInt64(max(0, seconds * configuration.timeScale) * 1_000_000_000)
    }
}
