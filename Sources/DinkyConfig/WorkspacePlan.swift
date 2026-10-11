// Which native Space each workspace is, and the one step that brings the Spaces closer to the config: a
// workspace per Space, each display with its own run of them numbered on from the display to its left (or where
// `[workspace-to-display]` moves one), in number order on each display, and no empty Space left over. The app
// runs the step, re-reads the Spaces and asks again, so a change macOS makes halfway (a display coming or going)
// is planned around rather than fought.
// Pure: no AppKit, no WindowServer. The app supplies the Spaces and carries out the steps.

/// A display as the plan sees it.
public struct PlanDisplay: Equatable {
    public var uuid: String
    public var monitor: Monitor
    /// User Spaces in Mission Control order; full-screen Spaces are left out.
    public var spaces: [UInt64]
    public var current: UInt64
    /// How many workspaces the display has (`Config.workspaces(for:)`).
    public var workspaces: Int

    public init(uuid: String, monitor: Monitor, spaces: [UInt64], current: UInt64, workspaces: Int) {
        self.uuid = uuid
        self.monitor = monitor
        self.spaces = spaces
        self.current = current
        self.workspaces = workspaces
    }
}

public enum PlanAction: Equatable {
    /// Create a user Space at the end of the display's strip.
    case create(display: String)
    /// Move every window on one Space to another.
    case move(from: UInt64, to: UInt64)
    /// Remove an empty Space no workspace is on.
    case remove(space: UInt64)
}

public struct PlanStep: Equatable {
    /// Workspace number to Space, updated for this step. The app keeps it for the next one. It assumes the
    /// action succeeds; the app reverts it when the action fails.
    public var binding: [Int: UInt64]
    /// What to do next, nil when the Spaces match the config.
    public var action: PlanAction?
}

public struct WorkspacePlan {
    public let assignments: [Int: [MonitorPattern]]

    public init(assignments: [Int: [MonitorPattern]] = [:]) {
        self.assignments = assignments
    }

    public init(_ config: Config) {
        self.init(assignments: config.workspaceDisplays)
    }

    /// The display each workspace lives on. Each display has a run of numbers as long as its `workspaces`, the
    /// displays taking theirs in `displays` order, left to right: with five each, 1 to 5 on the first and 6 to 10 on
    /// the second. `[workspace-to-display]` moves one of them to the first connected display its patterns match.
    /// `leftBehind` are workspaces past those, kept for their windows, by the Space each is on: one left by a
    /// display that went away lives on the main display, one left by a lower count stays on its display.
    public func homes(_ displays: [PlanDisplay], leftBehind: [Int: UInt64] = [:]) -> [Int: String] {
        var homes: [Int: String] = [:]
        var n = 1
        for display in displays {
            for _ in 0..<max(display.workspaces, 0) {
                homes[n] = display.uuid
                n += 1
            }
        }
        for (n, patterns) in assignments where homes[n] != nil {
            if let display = patterns.lazy.compactMap({ pattern in displays.first { pattern.matches($0.monitor) } }).first {
                homes[n] = display.uuid
            }
        }
        if let main = displays.first(where: \.monitor.isMain) ?? displays.first {
            for (n, space) in leftBehind where homes[n] == nil {
                homes[n] = (displays.first { $0.spaces.contains(space) } ?? main).uuid
            }
        }
        return homes
    }

    /// The next step from where things stand. `binding` is the previous step's; `occupied` is the Spaces that
    /// have windows on them. Workspaces are placed display by display, in number order, each on the first free
    /// Space after the previous one's (a new Space when there is none), moving its windows along when it
    /// changes Space; windows only ever go to an empty Space, so two sets never mix. Then empty Spaces no
    /// workspace is on are removed; one is kept on a display with no workspace, which macOS requires anyway.
    /// A leftover Space with windows is left alone.
    public func step(_ displays: [PlanDisplay], binding: [Int: UInt64], occupied: Set<UInt64>) -> PlanStep {
        let all = Set(displays.flatMap(\.spaces))
        let total = displays.reduce(0) { $0 + max($1.workspaces, 0) }
        // Forget Spaces that are gone; one workspace per Space. A workspace past the displays' runs, which a display
        // that went away left behind (or a lower count), stays while its Space has windows, so they keep their number.
        var binding = binding.filter { n, space in n >= 1 && all.contains(space) && (n <= total || occupied.contains(space)) }
        for n in binding.keys.sorted() where binding.contains(where: { $0.key < n && $0.value == binding[n] }) {
            binding[n] = nil
        }
        let homes = homes(displays, leftBehind: binding.filter { $0.key > total })

        for display in displays {
            var last = -1  // position of the previous workspace's Space on this display
            for n in homes.keys.sorted() where homes[n] == display.uuid {
                if let space = binding[n], let at = display.spaces.firstIndex(of: space), at > last {
                    last = at
                    continue
                }
                let bound = Set(binding.values)
                let old = binding[n].flatMap { occupied.contains($0) ? $0 : nil }
                guard let at = display.spaces.indices.first(where: { i in
                    i > last && !bound.contains(display.spaces[i]) && (old == nil || !occupied.contains(display.spaces[i]))
                }) else {
                    return PlanStep(binding: binding, action: .create(display: display.uuid))
                }
                binding[n] = display.spaces[at]
                last = at
                if let old { return PlanStep(binding: binding, action: .move(from: old, to: display.spaces[at])) }
            }
        }

        let bound = Set(binding.values)
        for display in displays {
            let hasWorkspace = display.spaces.contains(where: bound.contains)
            let keep = hasWorkspace ? nil : (display.spaces.contains(display.current) ? display.current : display.spaces.first)
            if let space = display.spaces.first(where: { !bound.contains($0) && $0 != keep && !occupied.contains($0) }) {
                return PlanStep(binding: binding, action: .remove(space: space))
            }
        }
        return PlanStep(binding: binding, action: nil)
    }
}
