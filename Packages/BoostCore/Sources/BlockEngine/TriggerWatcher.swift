import Foundation

// Déclencheurs d'événement : la séquence démarre à chaque front montant de la condition.
extension Interpreter {

    /// Surveille un déclencheur jusqu'à l'annulation du programme.
    ///
    /// Pendant que la séquence s'exécute, le déclencheur est ignoré ; il faut
    /// ensuite que la condition retombe avant de pouvoir repartir.
    func watch(trigger: Block, body: [Block]) async throws {
        var shakeBaseline = await device.sensors().shakeCount
        var wasTrue = false

        while true {
            try Task.checkCancellation()
            let isTrue = try await condition(of: trigger, shakeBaseline: &shakeBaseline)
            if isTrue && !wasTrue {
                enter(trigger.id)
                do {
                    try await runSequence(body)
                } catch {
                    leave(trigger.id)
                    throw error
                }
                leave(trigger.id)
                // Les secousses survenues pendant la séquence ne comptent pas.
                shakeBaseline = await device.sensors().shakeCount
                wasTrue = true
            } else {
                wasTrue = isTrue
            }
            try await pause(options.pollInterval)
        }
    }

    private func condition(of trigger: Block, shakeBaseline: inout Int) async throws -> Bool {
        switch trigger.opcode {
        case .whenColor:
            guard let wanted = trigger.option("color").flatMap(DetectedColor.init(rawValue:)) else {
                throw EngineError.missingInput(trigger.opcode, "color")
            }
            return await device.sensors().color == wanted

        case .whenDistanceBelow:
            let limit = try await number(trigger, "distance")
            guard let distance = await device.sensors().distance else { return false }
            return distance < limit

        case .whenTilted:
            let direction = trigger.option("direction").flatMap(TiltDirection.init(rawValue:)) ?? .any
            return isTilted(await device.sensors(), direction)

        case .whenShaken:
            let count = await device.sensors().shakeCount
            defer { shakeBaseline = count }
            return count != shakeBaseline

        case .whenButton:
            return await device.sensors().buttonPressed

        default:
            throw EngineError.misplacedBlock(trigger.opcode)
        }
    }
}
