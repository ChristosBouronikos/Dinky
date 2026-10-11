import Testing
@testable import DinkyConfig

struct GapsTests {
    private let builtIn = Monitor(name: "Built-in Retina Display", isMain: false, count: 2)
    private let dell = Monitor(name: "DELL U2723QE", isMain: true, count: 2)

    @Test func `Numbers and tables`() throws {
        let gaps = try Config.parse("[gaps]\ninner = 6\nouter = 4\n").gaps
        #expect(gaps.inner == Inner(6))
        #expect(gaps.outer == Sides(4))
        let split = try Config.parse("[gaps]\ninner = { horizontal = 8, vertical = 6 }\nouter = { top = 44, left = 2 }\n").gaps
        #expect(split.inner == Inner(horizontal: 8, vertical: 6))
        #expect(split.outer == Sides(top: 44, bottom: 8, left: 2, right: 8), "sides left out keep the default")
        let dotted = try Config.parse("[gaps]\ninner.vertical = 0\nouter.top = 44\n").gaps
        #expect(dotted.inner == Inner(horizontal: 8, vertical: 0))
        #expect(dotted.outer.top == 44)
    }

    @Test func `Display overrides`() throws {
        let config = try Config.parse("""
        [gaps]
        inner = 12
        outer = 8

        [display.main]
        gaps.outer.top = 44

        [display.built-in]
        gaps.outer.top = 10
        gaps.inner = 6
        """)
        #expect(config.displays.count == 2)
        #expect(config.gaps(for: dell) == Gaps(inner: Inner(12), outer: Sides(top: 44, bottom: 8, left: 8, right: 8)))
        #expect(config.gaps(for: builtIn) == Gaps(inner: Inner(6), outer: Sides(top: 10, bottom: 8, left: 8, right: 8)))
        #expect(config.gaps(for: Monitor(name: "LG", isMain: false, count: 3)) == config.gaps, "no match, no change")
    }

    @Test func `Name pattern beats main and longer name beats shorter`() throws {
        let config = try Config.parse("""
        [display.main]
        gaps.outer.top = 1
        gaps.outer.bottom = 1
        [display.dell]
        gaps.outer.top = 2
        [display."dell u2723"]
        gaps.outer.top = 3
        """)
        let gaps = config.gaps(for: dell)
        #expect(gaps.outer.top == 3)
        #expect(gaps.outer.bottom == 1, "the overrides layer, each one only changes what it sets")
    }

    @Test func `Workspace to display`() throws {
        let config = try Config.parse("""
        workspaces = 4
        [workspace-to-display]
        4 = 'secondary'
        2 = ['dell', 'main']
        """)
        #expect(config.workspaceDisplays == [4: [.secondary], 2: [.name("dell"), .main]])
        #expect(try Config.parse("").workspaceDisplays == [:])
        #expect(try Config.parse("[workspace-to-display]\n12 = 'main'\n").workspaceDisplays == [12: [.main]],
                "numbers past the first display's run are fine")
        assertError("[workspace-to-display]\n0 = 'main'\n", path: "workspace-to-display.0", line: 2, contains: "not a workspace number")
        assertError("[workspace-to-display]\nfive = 'main'\n", path: "workspace-to-display.five", line: 2, contains: "not a workspace number")
        assertError("[workspace-to-display]\n1 = ''\n", path: "workspace-to-display.1", line: 2, contains: "can't be empty")
        assertError("[workspace-to-display]\n1 = 2\n", path: "workspace-to-display.1", line: 2, contains: "string")
    }

    @Test func `Workspaces per display`() throws {
        let config = try Config.parse("""
        workspaces = 5
        [display.2]
        workspaces = 4
        [display.main]
        workspaces = 6
        [display.lg]
        workspaces = 0
        """)
        #expect(config.workspaces(for: Monitor(name: "Built-in Retina Display", isMain: false, count: 2, number: 2)) == 4)
        #expect(config.workspaces(for: Monitor(name: "DELL U2723QE", isMain: true, count: 2, number: 1)) == 6)
        #expect(config.workspaces(for: Monitor(name: "Built-in Retina Display", isMain: false, count: 3, number: 3)) == 5)
        #expect(config.workspaces(for: Monitor(name: "LG UltraFine", isMain: false, count: 2, number: 2)) == 0,
                "a name beats a number")
        #expect(config.workspaces(for: Monitor(name: "DELL U2723QE", isMain: true, count: 2, number: 2)) == 4,
                "a number beats main")
        assertError("[display.main]\nworkspaces = -1\n", path: "display.main.workspaces", line: 2, contains: "0 or more")
    }

    @Test func `Workspaces by display number, the last count going on`() throws {
        func counts(_ config: Config, displays: Int) -> [Int] {
            (1...displays).map { config.workspaces(for: Monitor(name: "x", isMain: $0 == 1, count: displays, number: $0)) }
        }
        #expect(counts(try Config.parse(""), displays: 4) == [5, 4, 4, 4], "the default")
        #expect(counts(try Config.parse("workspaces = [7, 3]\n"), displays: 3) == [7, 3, 3])
        #expect(counts(try Config.parse("workspaces = [5, 4, 2]\n"), displays: 4) == [5, 4, 2, 2])
        #expect(counts(try Config.parse("workspaces = 6\n"), displays: 3) == [6, 6, 6])
        #expect(counts(try Config.parse("workspaces = [7, 3]\n[display.3]\nworkspaces = 1\n"), displays: 3) == [7, 3, 1],
                "a display table beats the list")
        #expect(try Config.parse("workspaces = [5, 0]\n").workspaces == [5, 0])
        for bad in ["workspaces = []\n", "workspaces = [0, 3]\n", "workspaces = [5, -1]\n"] {
            assertError(bad, path: "workspaces", line: 1, contains: "at least 1 on the first display")
        }
        assertError("workspaces = ['five']\n", path: "workspaces", line: 1, contains: "a list of them")
    }

    @Test func patterns() {
        #expect(MonitorPattern.main.matches(dell))
        #expect(!MonitorPattern.main.matches(builtIn))
        #expect(MonitorPattern.secondary.matches(builtIn))
        #expect(!MonitorPattern.secondary.matches(Monitor(name: "x", isMain: false, count: 3)))
        #expect(MonitorPattern.name("built-in").matches(builtIn))
        #expect(MonitorPattern.name("dell").matches(dell), "case-insensitive substring")
        #expect(!MonitorPattern.name("built-in").matches(Monitor(name: "Apple Virtual Display", isMain: true, count: 1)))
        #expect(MonitorPattern("2") == .number(2))
        #expect(MonitorPattern("0") == .name("0"))
        #expect(MonitorPattern.number(2).matches(Monitor(name: "x", isMain: false, count: 2, number: 2)))
        #expect(!MonitorPattern.number(2).matches(Monitor(name: "DELL S2722QC", isMain: true, count: 2, number: 1)),
                "a number is the display's place, not part of its name")
    }

    @Test func `Bad gaps fail`() {
        assertError("[gaps]\nouter.top = 'wide'\n", path: "gaps.outer.top", line: 2, contains: "expected an integer")
        assertError("[gaps]\nouter.top = [{ monitor.main = 44 }, 8]\n", path: "gaps.outer.top", line: 2, contains: "expected an integer")
        assertError("[gaps]\ninner.diagonal = 3\n", path: "gaps.inner.diagonal", line: 2, contains: "unknown key")
        assertError("[display.main]\nborders.width = 2\n", path: "display.main.borders", line: 2, contains: "unknown key")
        assertError("[display.main]\ngaps.outer.tpo = 2\n", path: "display.main.gaps.outer.tpo", line: 2, contains: "unknown key")
        assertError("[display]\ngaps.outer.top = 2\n", path: "display.gaps.outer", line: 2, contains: "unknown key")
    }
}
