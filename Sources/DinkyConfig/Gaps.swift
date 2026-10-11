// Gaps in points, the `[display.<pattern>]` tables that override them and the workspace count for one display,
// and the display patterns those tables and `[workspace-to-display]` use.

/// The gap between side-by-side windows (`horizontal`) and between stacked ones (`vertical`).
public struct Inner: Equatable {
    public var horizontal, vertical: Int

    public init(_ both: Int) { (horizontal, vertical) = (both, both) }
    public init(horizontal: Int, vertical: Int) { (self.horizontal, self.vertical) = (horizontal, vertical) }
}

/// The gaps between tiled windows and the screen edges.
public struct Sides: Equatable {
    public var top, bottom, left, right: Int

    public init(_ all: Int) { (top, bottom, left, right) = (all, all, all, all) }
    public init(top: Int, bottom: Int, left: Int, right: Int) {
        (self.top, self.bottom, self.left, self.right) = (top, bottom, left, right)
    }
}

public struct Gaps: Equatable {
    public var inner = Inner(8)
    public var outer = Sides(8)

    public init() {}
    public init(inner: Inner, outer: Sides) { (self.inner, self.outer) = (inner, outer) }

    /// These gaps with the patch's values in place of the matching ones.
    public func applying(_ patch: GapsPatch) -> Gaps {
        var gaps = self
        gaps.inner.horizontal = patch.horizontal ?? inner.horizontal
        gaps.inner.vertical = patch.vertical ?? inner.vertical
        gaps.outer.top = patch.top ?? outer.top
        gaps.outer.bottom = patch.bottom ?? outer.bottom
        gaps.outer.left = patch.left ?? outer.left
        gaps.outer.right = patch.right ?? outer.right
        return gaps
    }
}

/// A `[gaps]` table as written: `inner = 8` or `inner = { horizontal = 8, vertical = 6 }`, `outer = 8` or
/// `outer = { top = 44, left = 8 }`. A value left out is nil and keeps whatever it is applied to.
public struct GapsPatch: Equatable {
    public var horizontal, vertical, top, bottom, left, right: Int?

    public init() {}

    init(_ t: Table) throws {
        if t.isTable("inner") {
            let inner = try t.table("inner")!
            horizontal = try inner.int("horizontal")
            vertical = try inner.int("vertical")
            try inner.done()
        } else if let both = try t.int("inner") {
            (horizontal, vertical) = (both, both)
        }
        if t.isTable("outer") {
            let outer = try t.table("outer")!
            top = try outer.int("top")
            bottom = try outer.int("bottom")
            left = try outer.int("left")
            right = try outer.int("right")
            try outer.done()
        } else if let all = try t.int("outer") {
            (top, bottom, left, right) = (all, all, all, all)
        }
        try t.done()
    }
}

/// What a display pattern is matched against. dinky fills it in per display.
public struct Monitor: Equatable {
    /// The display's name, such as "Built-in Retina Display" or "DELL U2723QE".
    public var name: String
    /// Whether this is the main display (System Settings, Displays, "Use as: Main display").
    public var isMain: Bool
    /// How many displays there are.
    public var count: Int
    /// The display's number as `list-monitors` prints it: 1 for the leftmost display, and so on to the right.
    public var number: Int

    public init(name: String, isMain: Bool, count: Int, number: Int = 0) {
        self.name = name
        self.isMain = isMain
        self.count = count
        self.number = number
    }
}

/// `main`, `secondary` (the non-main display when there are exactly two), a display number as `list-monitors`
/// prints it, such as `2`, or a case-insensitive substring of the display's name, such as `built-in` or `dell`.
public enum MonitorPattern: Equatable {
    case main, secondary
    case number(Int)
    case name(String)

    init(_ text: String) {
        switch text {
        case "main": self = .main
        case "secondary": self = .secondary
        default: self = Int(text).flatMap { $0 >= 1 ? .number($0) : nil } ?? .name(text)
        }
    }

    public func matches(_ monitor: Monitor) -> Bool {
        switch self {
        case .main: monitor.isMain
        case .secondary: monitor.count == 2 && !monitor.isMain
        case .number(let n): monitor.number == n
        case .name(let text): monitor.name.localizedCaseInsensitiveContains(text)
        }
    }
}

/// One `[display.<pattern>]` table: settings that replace the general ones on the displays the pattern matches.
public struct DisplayOverride: Equatable {
    public var pattern: MonitorPattern
    public var gaps = GapsPatch()
    /// The display's own workspace count, in place of `workspaces`.
    public var workspaces: Int?

    init(_ pattern: String, _ t: Table) throws {
        guard !pattern.isEmpty else { throw ConfigError(path: t.path, "a display pattern can't be empty") }
        self.pattern = MonitorPattern(pattern)
        gaps = try t.table("gaps").map(GapsPatch.init) ?? gaps
        workspaces = try t.int("workspaces")
        if let workspaces, workspaces < 0 { throw ConfigError(path: t.path("workspaces"), "must be 0 or more") }
        try t.done()
    }
}

extension Config {
    /// The display tables matching `monitor`, least specific first: `main` and `secondary`, then numbers, then
    /// name patterns, shortest first, so applying them in order lets the most specific win.
    private func overrides(for monitor: Monitor) -> [DisplayOverride] {
        func rank(_ override: DisplayOverride) -> Int {
            switch override.pattern {
            case .main, .secondary: -1
            case .number: 0
            case .name(let text): text.count
            }
        }
        return displays.filter { $0.pattern.matches(monitor) }.sorted { rank($0) < rank($1) }
    }

    /// How many workspaces `monitor` has: the most specific `[display.<pattern>] workspaces`, else its count in
    /// `workspaces` by its number, the last count going on for every display past the list.
    public func workspaces(for monitor: Monitor) -> Int {
        if let own = overrides(for: monitor).last(where: { $0.workspaces != nil })?.workspaces { return own }
        return workspaces[min(max(monitor.number, 1), workspaces.count) - 1]
    }

    /// The gaps on `monitor`: the general ones, with the overrides of every matching display table applied.
    public func gaps(for monitor: Monitor) -> Gaps {
        overrides(for: monitor).reduce(gaps) { $0.applying($1.gaps) }
    }
}
