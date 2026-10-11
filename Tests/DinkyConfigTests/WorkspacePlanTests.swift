import Testing
@testable import DinkyConfig

/// Runs plans against a simulated WindowServer: displays with Spaces, and windows per Space.
struct WorkspacePlanTests {
    private struct World {
        var displays: [PlanDisplay]
        var windows: [UInt64: Int] = [:]  // count per Space
        var binding: [Int: UInt64] = [:]
        var nextSpace: UInt64 = 1000
        var actions: [PlanAction] = []

        /// Steps until the plan is done, applying each action as WindowServer would.
        mutating func settle(_ plan: WorkspacePlan = WorkspacePlan(), limit: Int = 50) {
            for _ in 0..<limit {
                let step = plan.step(displays, binding: binding, occupied: Set(windows.filter { $0.value > 0 }.keys))
                binding = step.binding
                guard let action = step.action else { return }
                actions.append(action)
                switch action {
                case .create(let uuid):
                    let i = displays.firstIndex { $0.uuid == uuid }!
                    displays[i].spaces.append(nextSpace)
                    nextSpace += 1
                case .move(let from, let to):
                    windows[to, default: 0] += windows[from, default: 0]
                    windows[from] = 0
                case .remove(let space):
                    let i = displays.firstIndex { $0.spaces.contains(space) }!
                    displays[i].spaces.removeAll { $0 == space }
                    if displays[i].current == space { displays[i].current = displays[i].spaces[0] }
                }
            }
            Issue.record("no fixed point after \(limit) steps: \(actions)")
        }

        func spaces(_ uuid: String) -> [UInt64] { displays.first { $0.uuid == uuid }!.spaces }
        func numbers(on uuid: String) -> [Int] { spaces(uuid).compactMap { s in binding.first { $0.value == s }?.key } }
        /// The windows on workspace `n`'s Space.
        func windows(of n: Int) -> Int { binding[n].map { windows[$0, default: 0] } ?? 0 }
    }

    /// A display as the plan sees it; `count` is how many displays there are, `number` its place from the left.
    private static func display(_ uuid: String, _ name: String, main: Bool, count: Int = 1, number: Int = 1,
                                workspaces: Int = 5, _ spaces: [UInt64]) -> PlanDisplay {
        PlanDisplay(uuid: uuid, monitor: Monitor(name: name, isMain: main, count: count, number: number),
                    spaces: spaces, current: spaces[0], workspaces: workspaces)
    }

    @Test func `Startup binds workspaces to Spaces in order`() {
        var world = World(displays: [Self.display("L", "Built-in", main: true, [1, 2, 3])])
        world.windows = [1: 2, 3: 1]
        world.settle()
        #expect(world.actions == [.create(display: "L"), .create(display: "L")])
        #expect(world.numbers(on: "L") == [1, 2, 3, 4, 5])
        #expect(world.binding[1] == 1)
        #expect(world.binding[3] == 3)
    }

    @Test func `Each display has its own run of workspaces, left to right`() {
        let plan = WorkspacePlan()
        let two = [Self.display("D", "DELL S2722QC", main: true, count: 2, number: 1, [1]),
                   Self.display("B", "Built-in Display", main: false, count: 2, number: 2, workspaces: 4, [2])]
        #expect(plan.homes(two) == [1: "D", 2: "D", 3: "D", 4: "D", 5: "D", 6: "B", 7: "B", 8: "B", 9: "B"])
        // The main display needn't be first, and a display can have none.
        let three = [Self.display("L", "LG", main: false, count: 3, number: 1, workspaces: 2, [1]),
                     Self.display("P", "Projector", main: false, count: 3, number: 2, workspaces: 0, [2]),
                     Self.display("D", "DELL", main: true, count: 3, number: 3, workspaces: 3, [3])]
        #expect(plan.homes(three) == [1: "L", 2: "L", 3: "D", 4: "D", 5: "D"])
    }

    @Test func `Workspace to display moves a workspace off its display's run`() {
        let plan = WorkspacePlan(assignments: [2: [.name("lg")], 7: [.name("lenovo"), .main], 12: [.main]])
        let displays = [Self.display("D", "DELL", main: true, count: 2, number: 1, [1]),
                        Self.display("G", "LG UltraFine", main: false, count: 2, number: 2, [2])]
        #expect(plan.homes(displays) == [1: "D", 2: "G", 3: "D", 4: "D", 5: "D", 6: "G", 7: "D", 8: "G", 9: "G", 10: "G"],
                "7 falls back to its second pattern; 12 is no workspace with these displays")
    }

    /// The laptop alone has 1 to 5. Docked, the DELL to its left is display 1 and takes 1 to 5, windows and all; the
    /// laptop is display 2, with four workspaces of its own (the default `workspaces = [5, 4]`).
    private static func docked(laptop: [UInt64], dell: [UInt64]) -> [PlanDisplay] {
        [Self.display("D", "DELL S2722QC", main: true, count: 2, number: 1, dell),
         Self.display("L", "Built-in Display", main: false, count: 2, number: 2, workspaces: 4, laptop)]
    }

    @Test func `Docking hands the laptop's workspaces to the display on its left`() {
        var world = World(displays: [Self.display("L", "Built-in Display", main: true, [1, 2, 3, 4, 5])])
        world.windows = [1: 1, 5: 2]
        world.settle()
        #expect(world.actions == [])

        world.displays = Self.docked(laptop: [1, 2, 3, 4, 5], dell: [9])
        world.settle()
        #expect(world.numbers(on: "D") == [1, 2, 3, 4, 5])
        #expect(world.numbers(on: "L") == [6, 7, 8, 9])
        #expect(world.windows(of: 1) == 1)
        #expect(world.windows(of: 5) == 2)
        #expect(world.spaces("L") == [1, 2, 3, 4], "the Space workspace 5 left is removed")
    }

    @Test func `Undocking keeps the gone display's workspaces that have windows, and redocking puts them back`() {
        var world = World(displays: Self.docked(laptop: [1, 2, 3, 4], dell: [11, 12, 13, 14, 15]))
        world.windows = [11: 1, 15: 2, 2: 1]  // workspaces 1, 5 and 7
        world.settle()
        #expect(world.actions == [])
        #expect(world.numbers(on: "L") == [6, 7, 8, 9])

        for _ in 0..<3 {
            // Undocked, macOS moves the DELL's Spaces to the end of the laptop's, and the laptop is display 1.
            world.actions = []
            world.displays = [Self.display("L", "Built-in Display", main: true, world.spaces("L") + world.spaces("D"))]
            world.settle()
            #expect(world.numbers(on: "L") == [1, 2, 3, 4, 5, 7], "7 keeps its number while it has a window; 6, 8 and 9 go")
            #expect(world.windows(of: 1) == 1)
            #expect(world.windows(of: 5) == 2)
            #expect(world.windows(of: 7) == 1)

            // Docked again, the DELL comes back with a Space of its own.
            world.displays = Self.docked(laptop: world.spaces("L"), dell: [world.nextSpace])
            world.nextSpace += 1
            world.settle()
            #expect(world.numbers(on: "D") == [1, 2, 3, 4, 5])
            #expect(world.numbers(on: "L") == [6, 7, 8, 9])
            #expect(world.windows(of: 1) == 1)
            #expect(world.windows(of: 5) == 2)
            #expect(world.windows(of: 7) == 1)
        }
    }

    @Test func `Undocking keeps the merged Space and puts it back in order`() {
        let side = [Self.display("P", "PG27UCDM", main: true, count: 2, number: 1, workspaces: 4, [1, 2, 3, 4]),
                    Self.display("S", "LS24D60xU", main: false, count: 2, number: 2, workspaces: 1, [9])]
        var world = World(displays: side)
        world.windows = [9: 2]
        world.settle()
        #expect(world.numbers(on: "S") == [5])

        // macOS merges the side display's Space onto the laptop, not necessarily at the end.
        world.actions = []
        world.displays = [Self.display("L", "Built-in", main: true, [1, 9, 2, 3, 4])]
        world.settle()
        #expect(world.actions == [.create(display: "L"), .move(from: 9, to: 1000), .remove(space: 9)])
        #expect(world.numbers(on: "L") == [1, 2, 3, 4, 5])
        #expect(world.windows[1000] == 2)
    }

    @Test func `Windows never move onto a leftover Space with windows`() {
        var world = World(displays: [Self.display("P", "PG27UCDM", main: true, count: 2, number: 1, workspaces: 4, [1, 2, 3, 4]),
                                     Self.display("S", "LS24D60xU", main: false, count: 2, number: 2, workspaces: 1, [9])])
        world.windows = [9: 2]
        world.settle()
        // A leftover Space with windows (X = 50) sits on the laptop when workspace 5's Space merges mid-list.
        world.actions = []
        world.displays = [Self.display("L", "Built-in", main: true, [1, 9, 2, 3, 4, 50])]
        world.windows[50] = 1
        world.settle()
        #expect(world.actions == [.create(display: "L"), .move(from: 9, to: 1000), .remove(space: 9)])
        #expect(world.windows[50] == 1, "the leftover keeps its own window")
        #expect(world.windows[1000] == 2)
        #expect(world.numbers(on: "L") == [1, 2, 3, 4, 5])
    }

    @Test func `Undocking with the merged Space at the end moves nothing`() {
        var world = World(displays: [Self.display("P", "PG27UCDM", main: true, count: 2, number: 1, workspaces: 4, [1, 2, 3, 4]),
                                     Self.display("S", "LS24D60xU", main: false, count: 2, number: 2, workspaces: 1, [9])])
        world.settle()
        world.actions = []
        world.displays = [Self.display("L", "Built-in", main: true, [1, 2, 3, 4, 9])]
        world.settle()
        #expect(world.actions == [])
        #expect(world.binding[5] == 9)
    }

    @Test func `Display without workspaces keeps one Space`() {
        var world = World(displays: [Self.display("M", "Built-in", main: true, count: 2, number: 1, workspaces: 2, [1, 2]),
                                     Self.display("T", "Projector", main: false, count: 2, number: 2, workspaces: 0, [7, 8, 9])])
        world.displays[1].current = 8
        world.windows = [9: 1]
        world.settle()
        #expect(world.actions == [.remove(space: 7)], "the current Space stays, the one with windows is left alone")
        #expect(world.spaces("T") == [8, 9])
        #expect(world.numbers(on: "T") == [])
    }

    @Test func `Fewer workspaces removes empty Spaces and keeps one with windows until it empties`() {
        var world = World(displays: [Self.display("L", "Built-in", main: true, [1, 2, 3, 4, 5])])
        world.windows = [4: 1]
        world.settle()
        world.displays[0].workspaces = 3
        world.settle()
        #expect(world.actions == [.remove(space: 5)])
        #expect(world.numbers(on: "L") == [1, 2, 3, 4])
        world.windows[4] = 0
        world.settle()
        #expect(world.actions == [.remove(space: 5), .remove(space: 4)])
        #expect(world.numbers(on: "L") == [1, 2, 3])
    }

    @Test func `A lower count keeps a workspace with windows on its own display`() {
        var world = World(displays: Self.docked(laptop: [1, 2, 3, 4], dell: [11, 12, 13, 14, 15]))
        world.windows = [3: 1, 4: 2]  // workspaces 8 and 9, on the laptop
        world.settle()
        world.actions = []
        world.displays[1].workspaces = 2
        world.settle()
        #expect(world.numbers(on: "L") == [6, 7, 8, 9], "nothing moves to the DELL")
        #expect(world.actions == [])
    }

    @Test func `Stale and duplicate bindings are dropped`() {
        let displays = [Self.display("L", "Built-in", main: true, workspaces: 2, [1, 2])]
        let step = WorkspacePlan().step(displays, binding: [1: 2, 2: 2, 7: 1, 3: 99], occupied: [])
        #expect(step.binding == [1: 2], "workspace 2 must get a Space after workspace 1's; there is none yet")
        #expect(step.action == .create(display: "L"))
    }

    @Test func `No workspaces plans nothing`() {
        let displays = [Self.display("L", "Built-in", main: true, workspaces: 0, [1])]
        #expect(WorkspacePlan().homes(displays).isEmpty)
        #expect(WorkspacePlan().step(displays, binding: [1: 1], occupied: []) == PlanStep(binding: [:], action: nil))
    }
}
