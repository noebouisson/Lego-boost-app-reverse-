import XCTest
@testable import BlockEngine

final class ProjectEditingTests: XCTestCase {

    private func sample() -> (Project, ids: [String: UUID]) {
        let trigger = block(.whenStarted)
        let first = light(.red)
        let inner = light(.blue)
        let sensor = block(.distance)
        let comparison = block(.compare, ["a": .reporter(sensor), "op": .option("<"), "b": .number(5)])
        let condition = block(.ifElse, ["condition": .reporter(comparison)], [[inner], []])
        let last = waitBlock(1)
        let main = Script(blocks: [trigger, first, condition, last])
        let loose = Script(x: 300, y: 300, blocks: [light(.green)])
        let project = Project(name: "édition", scripts: [main, loose])
        return (project, ["main": main.id, "loose": loose.id, "trigger": trigger.id, "first": first.id,
                          "inner": inner.id, "sensor": sensor.id, "comparison": comparison.id,
                          "condition": condition.id, "last": last.id, "green": loose.blocks[0].id])
    }

    func testFindAndUpdateNestedBlocks() {
        var (project, ids) = sample()
        XCTAssertEqual(project.findBlock(ids["sensor"]!)?.opcode, .distance)
        XCTAssertEqual(project.findBlock(ids["inner"]!)?.option("color"), "blue")
        XCTAssertNil(project.findBlock(UUID()))

        XCTAssertTrue(project.updateBlock(ids["inner"]!) { $0.inputs["color"] = .option("pink") })
        XCTAssertEqual(project.findBlock(ids["inner"]!)?.option("color"), "pink")
        XCTAssertTrue(project.updateBlock(ids["comparison"]!) { $0.inputs["b"] = .number(8) })
        XCTAssertEqual(project.findBlock(ids["comparison"]!)?.inputs["b"], .number(8))
        XCTAssertFalse(project.updateBlock(UUID()) { _ in })
    }

    func testDetachTakesFollowingBlocks() {
        var (project, ids) = sample()
        XCTAssertEqual(project.dragGroup(startingAt: ids["condition"]!).map(\.id), [ids["condition"]!, ids["last"]!])
        let removed = project.detach(ids["condition"]!)
        XCTAssertEqual(removed.map(\.id), [ids["condition"]!, ids["last"]!])
        XCTAssertEqual(project.scripts[0].blocks.map(\.id), [ids["trigger"]!, ids["first"]!])
        XCTAssertNil(project.findBlock(ids["inner"]!))
    }

    func testDetachReporterRestoresDefaultAndEmptyScriptsDisappear() {
        var (project, ids) = sample()
        XCTAssertEqual(project.detach(ids["sensor"]!).map(\.id), [ids["sensor"]!])
        XCTAssertEqual(project.findBlock(ids["comparison"]!)?.inputs["a"], .number(0))

        XCTAssertEqual(project.detach(ids["comparison"]!).count, 1)
        XCTAssertEqual(project.findBlock(ids["condition"]!)?.inputs["condition"], .bool(false))

        XCTAssertEqual(project.detach(ids["green"]!).count, 1)
        XCTAssertEqual(project.scripts.map(\.id), [ids["main"]!])
        XCTAssertEqual(project.detach(UUID()), [])
    }

    func testInsertIntoSequencesAndBranches() {
        var (project, ids) = sample()
        let moved = project.detach(ids["green"]!)
        XCTAssertTrue(project.insert(moved, at: .sequence(.branch(parent: ids["condition"]!, index: 1), index: 0)).inserted)
        XCTAssertEqual(project.blocks(in: .branch(parent: ids["condition"]!, index: 1))?.map(\.id), [ids["green"]!])

        let added = [waitBlock(2), waitBlock(3)]
        XCTAssertTrue(project.insert(added, at: .sequence(.script(ids["main"]!), index: 1)).inserted)
        XCTAssertEqual(project.scripts[0].blocks.count, 6)
        XCTAssertEqual(project.scripts[0].blocks[1].id, added[0].id)
        XCTAssertFalse(project.insert([waitBlock(1)], at: .sequence(.script(ids["main"]!), index: 99)).inserted)
        XCTAssertFalse(project.insert([waitBlock(1)], at: .sequence(.script(UUID()), index: 0)).inserted)
    }

    func testTriggerPlacementRules() {
        let (project, ids) = sample()
        let trigger = block(.whenButton)
        // Pas avant un déclencheur existant, ni dans une branche, ni au milieu.
        XCTAssertFalse(project.canInsert([waitBlock(1)], at: .sequence(.script(ids["main"]!), index: 0)))
        XCTAssertFalse(project.canInsert([trigger], at: .sequence(.script(ids["main"]!), index: 0)))
        XCTAssertFalse(project.canInsert([trigger], at: .sequence(.script(ids["loose"]!), index: 1)))
        XCTAssertFalse(project.canInsert([trigger], at: .sequence(.branch(parent: ids["condition"]!, index: 0), index: 0)))
        XCTAssertFalse(project.canInsert([waitBlock(1), trigger], at: .sequence(.script(ids["loose"]!), index: 0)))
        // En tête d'un script sans déclencheur : oui.
        XCTAssertTrue(project.canInsert([trigger, waitBlock(1)], at: .sequence(.script(ids["loose"]!), index: 0)))
        XCTAssertTrue(project.canInsert([waitBlock(1)], at: .sequence(.script(ids["loose"]!), index: 0)))
    }

    func testSlotRulesAndDisplacement() {
        var (project, ids) = sample()
        let number = block(.random)
        let boolean = block(.isButtonPressed)
        let conditionSlot = SlotRef(parent: ids["condition"]!, key: "condition")
        let numberSlot = SlotRef(parent: ids["comparison"]!, key: "b")

        XCTAssertFalse(project.canInsert([number], at: .slot(conditionSlot)))
        XCTAssertFalse(project.canInsert([boolean], at: .slot(numberSlot)))
        XCTAssertFalse(project.canInsert([waitBlock(1)], at: .slot(numberSlot)))
        XCTAssertFalse(project.canInsert([number], at: .slot(SlotRef(parent: ids["comparison"]!, key: "op"))))
        XCTAssertFalse(project.canInsert([number], at: .sequence(.script(ids["loose"]!), index: 0)))

        XCTAssertTrue(project.insert([number], at: .slot(numberSlot)).inserted)
        XCTAssertEqual(project.findBlock(number.id)?.opcode, .random)

        let result = project.insert([boolean], at: .slot(conditionSlot))
        XCTAssertTrue(result.inserted)
        XCTAssertEqual(result.displaced?.id, ids["comparison"]!)
        XCTAssertNil(project.findBlock(ids["sensor"]!))
    }

    func testAllIDsAndVariables() {
        var (project, ids) = sample()
        let all = Project.allIDs(in: project.scripts[0].blocks)
        XCTAssertEqual(all.count, 7)
        XCTAssertTrue(all.contains(ids["sensor"]!))
        XCTAssertFalse(all.contains(ids["green"]!))

        XCTAssertEqual(project.addVariable("  score "), "score")
        XCTAssertEqual(project.addVariable("score"), "score")
        XCTAssertNil(project.addVariable("   "))
        XCTAssertEqual(project.variables, ["score"])
    }
}
