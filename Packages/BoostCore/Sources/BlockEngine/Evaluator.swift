import Foundation

// Évaluation des paramètres : nombres, conditions et blocs emboîtés.
extension Interpreter {

    /// Valeur numérique du paramètre `key` d'un bloc.
    func number(_ block: Block, _ key: String) async throws -> Double {
        guard let value = block.inputs[key] else { throw EngineError.missingInput(block.opcode, key) }
        return try await number(value)
    }

    /// Valeur entière du paramètre `key`, bornée pour rester convertible.
    func integer(_ block: Block, _ key: String) async throws -> Int {
        let value = try await number(block, key)
        guard value.isFinite else { return 0 }
        return Int(max(-1_000_000_000, min(1_000_000_000, value.rounded())))
    }

    func number(_ value: Value) async throws -> Double {
        switch value {
        case .number(let number):
            return number.isFinite ? number : 0
        case .bool(let flag):
            return flag ? 1 : 0
        case .variable(let name):
            return variables[name] ?? 0
        case .option:
            return 0
        case .reporter(let block):
            return try await evaluate(block)
        }
    }

    /// Valeur de vérité d'un paramètre ; un emplacement vide vaut faux.
    func truth(_ value: Value?) async throws -> Bool {
        guard let value else { return false }
        if case .bool(let flag) = value { return flag }
        return try await number(value) != 0
    }

    /// Évalue un bloc capteur ou opérateur. Les conditions valent 1 (vrai) ou 0 (faux).
    func evaluate(_ block: Block) async throws -> Double {
        switch block.opcode {
        case .colorIs:
            let wanted = block.option("color").flatMap(DetectedColor.init(rawValue:))
            let seen = await device.sensors().color
            return (wanted != nil && seen == wanted) ? 1 : 0

        case .distance:
            return await device.sensors().distance ?? options.distanceWhenNothing

        case .tiltAngle:
            let sensors = await device.sensors()
            return block.option("axis") == TiltAxis.y.rawValue ? sensors.tiltY : sensors.tiltX

        case .isTilted:
            let direction = block.option("direction").flatMap(TiltDirection.init(rawValue:)) ?? .any
            return isTilted(await device.sensors(), direction) ? 1 : 0

        case .isButtonPressed:
            return await device.sensors().buttonPressed ? 1 : 0

        case .motorRotation:
            return await device.sensors().rotations[try motor(block)] ?? 0

        case .variableValue:
            guard let name = block.variableName("name") else { throw EngineError.missingInput(block.opcode, "name") }
            return variables[name] ?? 0

        case .math:
            let a = try await number(block, "a")
            let b = try await number(block, "b")
            let result: Double
            switch block.option("op") {
            case "+": result = a + b
            case "-": result = a - b
            case "*": result = a * b
            case "/": result = b == 0 ? 0 : a / b
            case "mod": result = b == 0 ? 0 : a - b * (a / b).rounded(.down)
            default: throw EngineError.missingInput(block.opcode, "op")
            }
            return result.isFinite ? result : 0

        case .random:
            let from = try await number(block, "from")
            let to = try await number(block, "to")
            let low = min(from, to)
            let high = max(from, to)
            if low == low.rounded(), high == high.rounded(), abs(low) < 1e9, abs(high) < 1e9 {
                return Double(Int.random(in: Int(low)...Int(high)))
            }
            return Double.random(in: low...high)

        case .compare:
            let a = try await number(block, "a")
            let b = try await number(block, "b")
            switch block.option("op") {
            case "<": return a < b ? 1 : 0
            case ">": return a > b ? 1 : 0
            case "=": return abs(a - b) < 1e-9 ? 1 : 0
            default: throw EngineError.missingInput(block.opcode, "op")
            }

        case .and:
            // Les deux côtés sont évalués l'un après l'autre, le second seulement si utile.
            guard try await truth(block.inputs["a"]) else { return 0 }
            return try await truth(block.inputs["b"]) ? 1 : 0

        case .or:
            if try await truth(block.inputs["a"]) { return 1 }
            return try await truth(block.inputs["b"]) ? 1 : 0

        case .not:
            return try await truth(block.inputs["a"]) ? 0 : 1

        case .whenStarted, .whenColor, .whenDistanceBelow, .whenTilted, .whenShaken, .whenButton,
             .motorRunForSeconds, .motorRunForDegrees, .motorStart, .motorStop, .tankRunForSeconds,
             .tankRunForDegrees, .resetRotation, .setLight, .playSound,
             .wait, .repeatTimes, .forever, .ifElse, .waitUntil, .stopProgram,
             .setVariable, .changeVariable:
            throw EngineError.misplacedBlock(block.opcode)
        }
    }

    /// Correspondance axes → directions.
    /// NON VÉRIFIÉ sur le matériel : le sens des axes X et Y du hub reste à confirmer.
    func isTilted(_ sensors: SensorSnapshot, _ direction: TiltDirection) -> Bool {
        let threshold = options.tiltThreshold
        switch direction {
        case .any: return abs(sensors.tiltX) >= threshold || abs(sensors.tiltY) >= threshold
        case .right: return sensors.tiltX >= threshold
        case .left: return sensors.tiltX <= -threshold
        case .forward: return sensors.tiltY >= threshold
        case .backward: return sensors.tiltY <= -threshold
        }
    }
}
