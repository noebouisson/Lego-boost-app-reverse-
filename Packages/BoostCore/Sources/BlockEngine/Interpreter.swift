import Foundation

/// Exécute un projet : un script par tâche, tous en parallèle.
///
/// Toute l'exécution est isolée sur cet acteur : les scripts s'entrelacent aux
/// points d'attente (moteur, pause, capteur) et partagent les variables sans verrou.
public actor Interpreter {

    public struct Options: Sendable {
        /// Période de lecture des capteurs pour les déclencheurs et « attendre jusqu'à ».
        public var pollInterval: TimeInterval = 0.02
        /// Pause entre deux tours d'une boucle infinie, pour ne pas monopoliser le processeur.
        public var foreverPause: TimeInterval = 0.005
        /// Angle en degrés à partir duquel le hub est considéré penché.
        public var tiltThreshold: Double = 20
        /// Valeur du bloc « distance » quand rien n'est en vue.
        public var distanceWhenNothing: Double = 10
        public init() {}
    }

    /// Fin d'un script.
    private enum ScriptOutcome {
        case finished
        case cancelled
        case stopRequested
        case failed(blockID: UUID?, message: String)
    }

    /// Erreur rattachée au bloc qui l'a provoquée.
    private struct BlockFailure: Error {
        var blockID: UUID
        var underlying: Error
    }

    /// Levée par le bloc « tout arrêter ».
    private struct StopSignal: Error {}

    public private(set) var state = ExecutionState()

    let device: RobotDevice
    let options: Options
    var variables: [String: Double] = [:]

    private let onStateChange: (@Sendable (ExecutionState) -> Void)?
    private var runTask: Task<Void, Never>?
    private var activeCounts: [UUID: Int] = [:]

    /// - Parameter onStateChange: appelé à chaque changement d'état, depuis l'acteur.
    public init(device: RobotDevice, options: Options = Options(),
                onStateChange: (@Sendable (ExecutionState) -> Void)? = nil) {
        self.device = device
        self.options = options
        self.onStateChange = onStateChange
    }

    // MARK: - Pilotage

    /// Lance le projet, après avoir arrêté une exécution en cours.
    public func start(_ project: Project) async {
        await stop()
        variables = Dictionary(project.variables.map { ($0, 0.0) }, uniquingKeysWith: { first, _ in first })
        activeCounts.removeAll()
        state = ExecutionState()
        state.isRunning = true
        state.variables = variables
        publish()
        runTask = Task { await self.execute(project) }
    }

    /// Annule tous les scripts, arrête le matériel et attend la fin effective.
    public func stop() async {
        guard let task = runTask else { return }
        task.cancel()
        await task.value
    }

    /// Attend la fin naturelle du programme (ou son arrêt).
    public func waitUntilFinished() async {
        await runTask?.value
    }

    /// Lance le projet et attend sa fin. Ne revient pas tant qu'un script à
    /// déclencheur d'événement est actif : il faut alors appeler `stop()`.
    public func run(_ project: Project) async {
        await start(project)
        await waitUntilFinished()
    }

    // MARK: - Exécution

    private func execute(_ project: Project) async {
        let scripts = project.scripts.filter(\.isRunnable)
        var failure: (blockID: UUID?, message: String)?

        await withTaskGroup(of: ScriptOutcome.self) { group in
            for script in scripts {
                group.addTask { await self.runScript(script) }
            }
            for await outcome in group {
                switch outcome {
                case .finished, .cancelled:
                    break
                case .stopRequested:
                    group.cancelAll()
                case .failed(let blockID, let message):
                    if failure == nil { failure = (blockID, message) }
                    group.cancelAll()
                }
            }
        }

        await device.stopEverything()
        activeCounts.removeAll()
        state.activeBlocks = []
        state.isRunning = false
        state.errorMessage = failure?.message
        state.failedBlock = failure?.blockID
        publish()
        runTask = nil
    }

    private func runScript(_ script: Script) async -> ScriptOutcome {
        guard let trigger = script.blocks.first else { return .finished }
        let body = Array(script.blocks.dropFirst())
        do {
            if trigger.opcode == .whenStarted {
                enter(trigger.id)
                defer { leave(trigger.id) }
                try await runSequence(body)
            } else {
                try await watch(trigger: trigger, body: body)
            }
            return .finished
        } catch is CancellationError {
            return .cancelled
        } catch is StopSignal {
            return .stopRequested
        } catch let failure as BlockFailure {
            if failure.underlying is CancellationError { return .cancelled }
            return .failed(blockID: failure.blockID, message: Self.describe(failure.underlying))
        } catch {
            return .failed(blockID: nil, message: Self.describe(error))
        }
    }

    func runSequence(_ blocks: [Block]) async throws {
        for block in blocks {
            try Task.checkCancellation()
            try await runStatement(block)
        }
    }

    private func runStatement(_ block: Block) async throws {
        enter(block.id)
        defer { leave(block.id) }
        do {
            try await perform(block)
        } catch let error as BlockFailure {
            throw error
        } catch let error as StopSignal {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch {
            throw BlockFailure(blockID: block.id, underlying: error)
        }
    }

    private func perform(_ block: Block) async throws {
        switch block.opcode {
        // Actions
        case .motorRunForSeconds:
            let seconds = try await number(block, "seconds")
            let speed = try await integer(block, "speed")
            guard seconds > 0 else { return }
            try await device.runMotor(try motor(block), speed: speed, seconds: seconds)

        case .motorRunForDegrees:
            let degrees = try await integer(block, "degrees")
            let speed = try await integer(block, "speed")
            guard degrees != 0, speed != 0 else { return }
            try await device.runMotor(try motor(block), speed: speed, degrees: degrees)

        case .motorStart:
            try await device.startMotor(try motor(block), speed: try await integer(block, "speed"))

        case .motorStop:
            try await device.stopMotor(try motor(block))

        case .tankRunForSeconds:
            let seconds = try await number(block, "seconds")
            let left = try await integer(block, "left")
            let right = try await integer(block, "right")
            guard seconds > 0 else { return }
            try await device.runTank(left: left, right: right, seconds: seconds)

        case .tankRunForDegrees:
            let degrees = try await integer(block, "degrees")
            let left = try await integer(block, "left")
            let right = try await integer(block, "right")
            guard degrees != 0, left != 0 || right != 0 else { return }
            try await device.runTank(left: left, right: right, degrees: degrees)

        case .resetRotation:
            try await device.resetRotation(try motor(block))

        case .setLight:
            guard let color = block.option("color").flatMap(LightColor.init(rawValue:)) else {
                throw EngineError.missingInput(block.opcode, "color")
            }
            try await device.setLight(color)

        case .playSound:
            guard let sound = block.option("sound").flatMap(SoundID.init(rawValue:)) else {
                throw EngineError.missingInput(block.opcode, "sound")
            }
            try await device.playSound(sound)

        // Contrôle
        case .wait:
            try await pause(try await number(block, "seconds"))

        case .repeatTimes:
            let times = try await integer(block, "times")
            let body = block.branches.first ?? []
            guard times > 0 else { return }
            for _ in 0..<times {
                try Task.checkCancellation()
                try await runSequence(body)
                await Task.yield()
            }

        case .forever:
            let body = block.branches.first ?? []
            while true {
                try await runSequence(body)
                try await pause(options.foreverPause)
            }

        case .ifElse:
            let branch = try await truth(block.inputs["condition"]) ? 0 : 1
            if block.branches.indices.contains(branch) {
                try await runSequence(block.branches[branch])
            }

        case .waitUntil:
            while !(try await truth(block.inputs["condition"])) {
                try await pause(options.pollInterval)
            }

        case .stopProgram:
            throw StopSignal()

        // Données
        case .setVariable:
            guard let name = block.variableName("name") else { throw EngineError.missingInput(block.opcode, "name") }
            setVariable(name, try await number(block, "value"))

        case .changeVariable:
            guard let name = block.variableName("name") else { throw EngineError.missingInput(block.opcode, "name") }
            setVariable(name, (variables[name] ?? 0) + (try await number(block, "value")))

        // Blocs qui ne sont pas des instructions
        case .whenStarted, .whenColor, .whenDistanceBelow, .whenTilted, .whenShaken, .whenButton,
             .colorIs, .distance, .tiltAngle, .isTilted, .isButtonPressed, .motorRotation,
             .variableValue, .math, .random, .compare, .and, .or, .not:
            throw EngineError.misplacedBlock(block.opcode)
        }
    }

    // MARK: - Aides

    func motor(_ block: Block) throws -> MotorTarget {
        guard let target = block.option("port").flatMap(MotorTarget.init(rawValue:)) else {
            throw EngineError.missingInput(block.opcode, "port")
        }
        return target
    }

    func pause(_ seconds: Double) async throws {
        guard seconds.isFinite, seconds > 0 else {
            try Task.checkCancellation()
            await Task.yield()
            return
        }
        try await Task.sleep(nanoseconds: UInt64(min(seconds, 86_400) * 1_000_000_000))
    }

    private func setVariable(_ name: String, _ value: Double) {
        variables[name] = value.isFinite ? value : 0
        state.variables = variables
        publish()
    }

    func enter(_ id: UUID) {
        activeCounts[id, default: 0] += 1
        if state.activeBlocks.insert(id).inserted { publish() }
    }

    func leave(_ id: UUID) {
        let remaining = (activeCounts[id] ?? 1) - 1
        if remaining > 0 {
            activeCounts[id] = remaining
        } else {
            activeCounts[id] = nil
            if state.activeBlocks.remove(id) != nil, state.isRunning { publish() }
        }
    }

    private func publish() {
        onStateChange?(state)
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
