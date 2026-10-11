import AppKit
import DinkyCommands
import DinkyConfig
import DinkyLayout
import DinkyPrivate

// The scratchpad: floating windows kept out of sight on a Space of their own, which no workspace number names and
// the workspace plan leaves alone. `scratchpad show` moves them onto the focused display's current Space, laid out
// together in the middle of the display (`[scratchpad]`), and `hide` moves them back. Moving windows between Spaces
// switches none. With `slide`, windows on screen glide in from an edge of the display and back out to it, hanging
// off it with a sliver on (as the scrolling layout parks columns) before they go. The Space is made on first use, at
// the end of the main display's Spaces. A window that is closed, tiled or moved to a workspace leaves the scratchpad.
// Quitting and `enable off` put its windows back where they were before dinky touched them, as Recovery does every
// window. Main thread only.
final class ScratchpadManager {
    /// The scratchpad's Space, once made.
    private(set) var space: UInt64?
    /// Its windows, in the order they were added.
    private var windows: [WindowID] = []
    /// Windows on their way to the scratchpad's Space, and where those sliding out are headed.
    private var stowing: Set<WindowID> = []
    private var parking: [WindowID: CGRect] = [:]

    /// The animator pass every scratchpad glide shares, so a new one retargets the last; no Space has this ID.
    private let glideKey = UInt64.max
    /// How much of a window sliding out stays on screen, as the scrolling layout parks columns.
    private let peek: CGFloat = 25

    /// Takes a window out of the scratchpad, wherever it is now.
    func forget(_ id: WindowID) {
        windows.removeAll { $0 == id }
        stowing.remove(id)
        parking[id] = nil
    }

    /// Forgets the windows and the Space, once Recovery has put the windows back. The next arrangement removes
    /// the Space, now empty.
    func reset() {
        windows = []
        stowing = []
        parking = [:]
        space = nil
    }

    /// Floats the window and hides it in the scratchpad.
    func add(_ id: WindowID) -> Reply {
        guard let coordinator = AppState.shared.coordinator else { return .error("tiling is not running") }
        guard id != 0, coordinator.isFloating(id) != nil else {
            return .error("move-window-to-scratchpad: no window dinky manages is focused")
        }
        guard makeSpace() != nil else { return .error("move-window-to-scratchpad: could not make the scratchpad's Space") }
        let display = AppState.shared.displays.focusedDisplay()
        if !windows.contains(id) { windows.append(id) }
        coordinator.setFloating(id, true)
        if let error = stow([id], from: display) { return .error("move-window-to-scratchpad: \(error)") }
        return .ok("moved window \(id) to the scratchpad")
    }

    func run(_ action: ScratchpadAction) -> Reply {
        switch action {
        case .show: return show()
        case .hide: return hide()
        case .toggle:
            // Windows sliding out are as good as hidden: toggling again brings them back.
            let here = AppState.shared.displays.focusedDisplay()?.currentSpaceID
            return live.contains { !stowing.contains($0) && dinky_window_space_id($0) == here } ? hide() : show()
        }
    }

    /// Moves every scratchpad window onto the focused display's current Space and lays them out there, the last
    /// one added in front and focused. With `slide`, they glide in from the display's edge; windows still sliding
    /// out turn back from where they are.
    private func show() -> Reply {
        guard let coordinator = AppState.shared.coordinator else { return .error("tiling is not running") }
        let model = AppState.shared.displays
        model.reconcile()
        let ids = live
        guard let front = ids.last else { return .error("scratchpad: it is empty") }
        guard let display = model.focusedDisplay(), display.userSpaces.contains(display.currentSpaceID),
              display.currentSpaceID != space else { return .error("scratchpad: not on a workspace") }
        // Showing replaces the glide out, and the move that was to follow it.
        stowing = []
        parking = [:]
        guard move(ids, to: display.currentSpaceID) else { return .error("scratchpad: its windows did not all arrive") }
        let layout = layout(ids, on: display)
        let pids = Dictionary(uniqueKeysWithValues: ids.compactMap { id in coordinator.model.windows[id].map { (id, $0.pid) } })
        let write = { coordinator.applier.apply(layout, pids: pids, front: front) }
        if let starts = parked(layout.frames, on: display) {
            // Stacking first, so they slide in over the tiles.
            coordinator.applier.raiseIntoOrder(layout, pids: pids, front: front)
            if !coordinator.glide(glideKey, from: starts, to: layout.frames, then: write) { write() }
        } else {
            write()
        }
        coordinator.focus(front)
        return .ok("showed \(ids.count) scratchpad window\(ids.count == 1 ? "" : "s")")
    }

    /// Moves every scratchpad window back to its Space.
    private func hide() -> Reply {
        let ids = live
        guard !ids.isEmpty else { return .error("scratchpad: it is empty") }
        if let error = stow(ids, from: AppState.shared.displays.focusedDisplay()) { return .error("scratchpad: \(error)") }
        return .ok("hid \(ids.count) scratchpad window\(ids.count == 1 ? "" : "s")")
    }

    /// Moves windows to the scratchpad's Space. With `slide`, the ones on the display's current Space glide out to
    /// its edge first and go once there. Nil once moved or on their way, else the error.
    private func stow(_ ids: [WindowID], from display: Display?) -> String? {
        stowing.formUnion(ids)
        let here = ids.filter { dinky_window_space_id($0) == display?.currentSpaceID }
        let starts = Dictionary(uniqueKeysWithValues: here.map { ($0, dinky_window_info($0).frame) })
        if let display, !here.isEmpty, let coordinator = AppState.shared.coordinator, let parked = parked(starts, on: display) {
            parking.merge(parked) { _, new in new }
            // Every window still on its way is in the pass, so this one does not stop the others.
            if coordinator.glide(glideKey, from: starts, to: parking, then: { [weak self] in
                if let error = self?.finishStowing(display) { fputs("scratchpad: \(error)\n", stderr) }
            }) { return nil }
        }
        return finishStowing(display)
    }

    /// Moves the windows on their way to the scratchpad's Space there, and gives focus back to the display's
    /// workspace. Nil once moved, else the error.
    private func finishStowing(_ display: Display?) -> String? {
        let ids = live.filter(stowing.contains)
        stowing = []
        parking = [:]
        guard !ids.isEmpty else { return nil }
        guard let space = makeSpace() else { return "could not make the scratchpad's Space" }
        guard move(ids, to: space) else { return "its windows did not all arrive" }
        refocus(display)
        return nil
    }

    /// The frames hung off the display's `slide` edge with a sliver on; nil without a slide, or with another
    /// display beyond that edge, which the windows would show on.
    private func parked(_ frames: [WindowID: CGRect], on display: Display) -> [WindowID: CGRect]? {
        let edge = AppState.shared.config.scratchpad.slide
        let d = display.frame
        let beyond = AppState.shared.displays.displays.contains { other in
            let o = other.frame
            guard other.uuid != display.uuid else { return false }
            let acrossX = min(o.maxX, d.maxX) > max(o.minX, d.minX), acrossY = min(o.maxY, d.maxY) > max(o.minY, d.minY)
            return switch edge {
            case .none: false
            case .bottom: abs(o.minY - d.maxY) < 1 && acrossX
            case .left: abs(o.maxX - d.minX) < 1 && acrossY
            case .right: abs(o.minX - d.maxX) < 1 && acrossY
            }
        }
        guard edge != .none, !beyond else { return nil }
        return frames.mapValues { f in
            switch edge {
            case .none: f
            case .bottom: CGRect(x: f.minX, y: d.maxY - peek, width: f.width, height: f.height)
            case .left: CGRect(x: d.minX - f.width + peek, y: f.minY, width: f.width, height: f.height)
            case .right: CGRect(x: d.maxX - peek, y: f.minY, width: f.width, height: f.height)
            }
        }
    }

    /// The windows that still exist.
    private var live: [WindowID] {
        let known = AppState.shared.coordinator?.model.windows ?? [:]
        return windows.filter { known[$0] != nil }
    }

    /// The scratchpad's Space, made at the end of the main display's Spaces when there is none: on first use, or
    /// after it went away (removed in Mission Control), when macOS put its windows elsewhere.
    private func makeSpace() -> UInt64? {
        let model = AppState.shared.displays
        model.reconcile()
        if let space, model.display(containingSpace: space) != nil { return space }
        space = nil
        guard let main = model.displays.first(where: \.isMain) ?? model.displays.first else { return nil }
        let made = dinky_create_space(main.uuid as CFString)
        guard made != 0, waitUntil(2, { model.reconcile(); return model.display(containingSpace: made) != nil }) else {
            fputs("scratchpad: could not make a Space on \(main.name)\n", stderr)
            return nil
        }
        print("scratchpad: made Space \(made) on \(main.name)")
        fflush(stdout)
        space = made
        return made
    }

    /// Moves windows to a Space and waits for them to arrive: the bridged move is asynchronous. Whether they all did.
    private func move(_ ids: [WindowID], to space: UInt64) -> Bool {
        var moving = ids.filter { dinky_window_space_id($0) != space }
        guard !moving.isEmpty else { return true }
        guard dinky_move_windows_to_space(&moving, Int32(moving.count), space) else { return false }
        let arrived = waitUntil(1) { moving.allSatisfy { dinky_window_space_id($0) == space } }
        // So the model, and the trees, know where they are now rather than on the next event.
        for id in moving { AppState.shared.coordinator?.model.refresh(id) }
        return arrived
    }

    /// The windows tiled together in a rectangle `[scratchpad]`'s share of the display, centred inside its outer
    /// gaps, with its inner gaps between them.
    private func layout(_ ids: [WindowID], on display: Display) -> Layout {
        let config = AppState.shared.config
        let gaps = DinkyLayout.Gaps(config.gaps(for: AppState.shared.displays.monitor(display)))
        let area = gaps.inset(display.visibleArea)
        let width = area.width * config.scratchpad.width, height = area.height * config.scratchpad.height
        var workspace = Workspace(bounds: CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height),
                                  gaps: DinkyLayout.Gaps(horizontal: gaps.horizontal, vertical: gaps.vertical,
                                                         top: 0, bottom: 0, left: 0, right: 0))
        for id in ids { workspace.insert(id) }
        return workspace.layout()
    }

    /// Focuses the window the display's workspace had focused, so macOS does not hand focus to an app on another
    /// Space, and switch there, once the focused window has gone.
    private func refocus(_ display: Display?) {
        guard let display, let shown = AppState.shared.displays.displays.first(where: { $0.uuid == display.uuid }) else { return }
        _ = Dispatcher.focus(shown, window: AppState.shared.coordinator?.workspace(on: shown)?.focused)
    }
}
