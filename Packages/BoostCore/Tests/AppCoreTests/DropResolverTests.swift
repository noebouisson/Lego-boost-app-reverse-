import BlockEngine
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import AppCore

final class DropResolverTests: XCTestCase {

    /// Script : [déclencheur][lumière][si (cond) {attendre} {}] posé en (0, 0), blocs de 100 × 50.
    private func scene() -> (Project, EditorLayout, ids: [String: UUID]) {
        let trigger = BlockCatalog.makeBlock(.whenStarted)
        let light = BlockCatalog.makeBlock(.setLight)
        let wait = BlockCatalog.makeBlock(.wait)
        var condition = BlockCatalog.makeBlock(.ifElse)
        condition.branches = [[wait], []]
        let script = Script(blocks: [trigger, light, condition])
        let loose = Script(x: 0, y: 300, blocks: [BlockCatalog.makeBlock(.playSound)])
        let project = Project(name: "scène", scripts: [script, loose])

        var layout = EditorLayout()
        layout.sequences[.script(script.id)] = CGRect(x: 0, y: 0, width: 600, height: 70)
        layout.blocks[trigger.id] = CGRect(x: 0, y: 10, width: 100, height: 50)
        layout.blocks[light.id] = CGRect(x: 100, y: 10, width: 100, height: 50)
        layout.blocks[condition.id] = CGRect(x: 200, y: 0, width: 400, height: 70)
        layout.slots[SlotRef(parent: condition.id, key: "condition")] = CGRect(x: 240, y: 20, width: 50, height: 30)
        layout.sequences[.branch(parent: condition.id, index: 0)] = CGRect(x: 300, y: 5, width: 130, height: 60)
        layout.blocks[wait.id] = CGRect(x: 305, y: 10, width: 120, height: 50)
        layout.slots[SlotRef(parent: wait.id, key: "seconds")] = CGRect(x: 380, y: 20, width: 30, height: 30)
        layout.sequences[.branch(parent: condition.id, index: 1)] = CGRect(x: 450, y: 5, width: 60, height: 60)
        layout.sequences[.script(loose.id)] = CGRect(x: 0, y: 300, width: 100, height: 50)
        layout.blocks[loose.blocks[0].id] = CGRect(x: 0, y: 300, width: 100, height: 50)

        return (project, layout, ["script": script.id, "loose": loose.id, "trigger": trigger.id, "light": light.id,
                                  "condition": condition.id, "wait": wait.id, "sound": loose.blocks[0].id])
    }

    func testNewBlockSnapsBetweenBlocks() {
        let (project, layout, ids) = scene()
        let new = [BlockCatalog.makeBlock(.motorStop)]
        let target = DropResolver.target(for: new, at: CGPoint(x: 160, y: 30), in: project, layout: layout)
        XCTAssertEqual(target?.location, .sequence(.script(ids["script"]!), index: 2))
        XCTAssertEqual(target?.indicator.minX, 195)

        // Devant le déclencheur : repoussé juste après lui.
        let front = DropResolver.target(for: new, at: CGPoint(x: -10, y: 30), in: project, layout: layout)
        XCTAssertEqual(front?.location, .sequence(.script(ids["script"]!), index: 1))

        // Loin de tout : pas de cible, donc nouveau script.
        XCTAssertNil(DropResolver.target(for: new, at: CGPoint(x: 900, y: 600), in: project, layout: layout))
    }

    func testDeepestSequenceWins() {
        let (project, layout, ids) = scene()
        let new = [BlockCatalog.makeBlock(.motorStop)]
        let inside = DropResolver.target(for: new, at: CGPoint(x: 310, y: 30), in: project, layout: layout)
        XCTAssertEqual(inside?.location, .sequence(.branch(parent: ids["condition"]!, index: 0), index: 0))
        let empty = DropResolver.target(for: new, at: CGPoint(x: 470, y: 30), in: project, layout: layout)
        XCTAssertEqual(empty?.location, .sequence(.branch(parent: ids["condition"]!, index: 1), index: 0))
        let after = DropResolver.target(for: new, at: CGPoint(x: 620, y: 30), in: project, layout: layout)
        XCTAssertEqual(after?.location, .sequence(.script(ids["script"]!), index: 3))
    }

    func testMovingExistingBlocks() {
        let (project, layout, ids) = scene()
        // « lumière » emporte le bloc « si » : seule reste la place après le déclencheur.
        let group = project.dragGroup(startingAt: ids["light"]!)
        XCTAssertEqual(group.count, 2)
        let back = DropResolver.target(for: group, at: CGPoint(x: 480, y: 30), in: project, layout: layout)
        XCTAssertEqual(back?.location, .sequence(.script(ids["script"]!), index: 1))

        // Un bloc ne se dépose pas dans lui-même.
        let self1 = DropResolver.target(for: project.dragGroup(startingAt: ids["condition"]!),
                                        at: CGPoint(x: 470, y: 30), in: project, layout: layout)
        XCTAssertEqual(self1?.location, .sequence(.script(ids["script"]!), index: 2))

        // Le script entier déplacé ne s'accroche pas à lui-même mais peut rejoindre l'autre… sauf déclencheur en queue.
        let whole = project.dragGroup(startingAt: ids["trigger"]!)
        XCTAssertNil(DropResolver.target(for: whole, at: CGPoint(x: 50, y: 30), in: project, layout: layout))
        let ontoLoose = DropResolver.target(for: whole, at: CGPoint(x: -5, y: 320), in: project, layout: layout)
        XCTAssertEqual(ontoLoose?.location, .sequence(.script(ids["loose"]!), index: 0))
        XCTAssertNil(DropResolver.target(for: whole, at: CGPoint(x: 90, y: 320), in: project, layout: layout))

        // Le bloc isolé rejoint le script principal.
        let sound = project.dragGroup(startingAt: ids["sound"]!)
        let joined = DropResolver.target(for: sound, at: CGPoint(x: 160, y: 80), in: project, layout: layout)
        XCTAssertEqual(joined?.location, .sequence(.script(ids["script"]!), index: 2))
    }

    func testReportersOnlyGoIntoMatchingSlots() {
        let (project, layout, ids) = scene()
        let number = [BlockCatalog.makeBlock(.distance)]
        let boolean = [BlockCatalog.makeBlock(.isButtonPressed)]
        let seconds = BlockLocation.slot(SlotRef(parent: ids["wait"]!, key: "seconds"))
        let condition = BlockLocation.slot(SlotRef(parent: ids["condition"]!, key: "condition"))

        XCTAssertEqual(DropResolver.target(for: number, at: CGPoint(x: 390, y: 30), in: project, layout: layout)?.location, seconds)
        XCTAssertNil(DropResolver.target(for: boolean, at: CGPoint(x: 390, y: 30), in: project, layout: layout))
        XCTAssertEqual(DropResolver.target(for: boolean, at: CGPoint(x: 250, y: 30), in: project, layout: layout)?.location, condition)
        XCTAssertNil(DropResolver.target(for: number, at: CGPoint(x: 250, y: 30), in: project, layout: layout))
        XCTAssertNil(DropResolver.target(for: number, at: CGPoint(x: 150, y: 30), in: project, layout: layout))
    }
}
