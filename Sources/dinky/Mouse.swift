import AppKit
import DinkyCommands
import DinkyConfig
import DinkyLayout
import DinkyPrivate

// The mouse. With `[mouse]`'s modifiers held, the left button drags a window from anywhere in it and the right
// button resizes it from the corner nearest where the drag started. A mouse button bound in the current mode runs
// its commands on the window under the pointer, focusing it first. dinky takes these presses whole, release and
// drags included, so the app under the pointer sees none of them; every other click passes untouched. A floating
// window goes where it is dragged. A tiled one follows the pointer and is dropped as a title-bar drag is
// (Drag.swift): moved, it swaps with the tile under the pointer, or goes back; resized, its tile takes the size.
//
// The tap sees every click, so it runs on a thread of its own and only decides, from a snapshot of the config,
// whether a press is dinky's: a click is never held up by the main thread being busy. Everything else happens on
// the main thread, in the order the events came.
final class MouseActions {
    private enum Gesture { case move, resize }

    private struct Press: Hashable {
        let button: Int64
        let modifiers: KeyCombo.Modifiers
    }

    /// What the tap decides with. Under `lock`.
    private struct Rules {
        var move: KeyCombo.Modifiers?
        var resize: KeyCombo.Modifiers?
        var sides = ModifierSides()
        /// By mode, the commands bound to each button and modifiers.
        var bindings: [String: [Press: [String]]] = [:]
        var enabled = true
    }

    /// The window being dragged, from where, and how. Main thread.
    private struct Grab {
        let id: WindowID
        let pid: pid_t
        let gesture: Gesture
        let tiled: Bool
        let start: CGPoint
        let frame: CGRect
        /// The edges a resize moves: the horizontal and vertical ones nearest where it started.
        let edges: Set<Direction>
        /// The frame last written.
        var current: CGRect
    }

    private let lock = NSLock()
    private var rules = Rules()
    private var tap: CFMachPort?
    private var started = false
    /// The button whose press dinky took, so its drags and release are taken too. Tap thread.
    private var taken: Int64?
    private var grab: Grab?

    /// A window is never resized below this, either way.
    private let minimumSide: CGFloat = 100

    /// Takes the config's mouse settings and bindings, starting the tap the first time they ask for it.
    func update(config: Config) {
        let bindings = config.modes.mapValues { mode in
            Dictionary(uniqueKeysWithValues: mode.bindings.compactMap { combo, commands in
                combo.mouseButton.map { (Press(button: $0, modifiers: combo.modifiers), commands) }
            })
        }
        lock.withLock {
            rules.move = config.mouse.move
            rules.resize = config.mouse.resize
            rules.sides = config.modifiers
            rules.bindings = bindings
        }
        let wanted = config.mouse.move != nil || config.mouse.resize != nil || bindings.values.contains { !$0.isEmpty }
        if wanted, !started {
            started = true
            let thread = Thread { [weak self] in self?.runTap() }
            thread.name = "dinky.mouse"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    /// Off, every click passes.
    func setEnabled(_ enabled: Bool) {
        lock.withLock { rules.enabled = enabled }
        if !enabled { release() }
    }

    /// Runs the tap on this thread for good. With nothing configured it passes every click.
    private func runTap() {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged,
                                    .rightMouseUp, .otherMouseDown, .otherMouseDragged, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: mouseCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            fputs("mouse: could not create event tap (Accessibility?)\n", stderr)
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }

    // MARK: Tap thread

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let point = event.location
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // A release may have gone by meanwhile; drop the grab rather than keep dragging.
            if taken != nil { letGo() }
            return pass
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A press while one is taken means its release never came.
            if taken != nil { letGo() }
            return take(event, at: point) ? nil : pass
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard taken != nil else { return pass }
            DispatchQueue.main.async { self.dragged(to: point) }
            return nil
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard taken == event.getIntegerValueField(.mouseEventButtonNumber) else { return pass }
            letGo()
            return nil
        default:
            return pass
        }
    }

    /// Takes a press that runs a binding, or starts a drag on a window. Whether it did.
    private func take(_ event: CGEvent, at point: CGPoint) -> Bool {
        let rules = lock.withLock { self.rules }
        guard rules.enabled, let modifiers = KeyPress(event, sides: rules.sides)?.modifiers else { return false }
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let commands = rules.bindings[AppState.shared.hotkeys.currentMode]?[Press(button: button, modifiers: modifiers)]
        let gesture: Gesture? = button == 0 && modifiers == rules.move ? .move
            : button == 1 && modifiers == rules.resize ? .resize : nil
        guard commands != nil || gesture != nil else { return false }
        let window = Self.window(at: point)
        // Option-click on the menu bar, the Dock or a menu goes to them, not to a drag.
        guard commands != nil || window != nil else { return false }
        taken = button
        DispatchQueue.main.async { self.pressed(window, commands: commands, gesture: gesture, at: point) }
        return true
    }

    private func letGo() {
        taken = nil
        DispatchQueue.main.async { self.release() }
    }

    /// The frontmost window at the point, if it is another app's normal-level window; nil while a menu or modal panel
    /// is open, or a floating panel is in front. As for hover, windows above those levels are passed over: the Dock and
    /// Notification Center keep transparent ones over the whole screen. So are dinky's own, its borders among them.
    private static func window(at point: CGPoint) -> WindowID? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let modalLevel = Int(CGWindowLevelForKey(.modalPanelWindow))
        let own = getpid()
        for w in info {
            guard let layer = w[kCGWindowLayer as String] as? Int else { continue }
            if layer == menuLevel || layer == modalLevel { return nil }
            guard (0...modalLevel).contains(layer), w[kCGWindowOwnerPID as String] as? pid_t != own,
                  (w[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point) else { continue }
            return layer == 0 ? w[kCGWindowNumber as String] as? WindowID : nil
        }
        return nil
    }

    // MARK: Main thread

    /// Runs the binding's commands, or starts dragging the window if dinky manages it.
    private func pressed(_ window: WindowID?, commands: [String]?, gesture: Gesture?, at point: CGPoint) {
        guard let coordinator = AppState.shared.coordinator else { return }
        let managed = window.flatMap { coordinator.isFloating($0) != nil ? $0 : nil }
        if let commands { return Self.run(commands, on: managed) }
        guard let gesture, let id = managed, let pid = coordinator.model.windows[id]?.pid else { return }
        let frame = dinky_window_info(id).frame
        let edges: Set<Direction> = [point.x < frame.midX ? .left : .right, point.y < frame.midY ? .up : .down]
        let tiled = coordinator.isFloating(id) == false
        grab = Grab(id: id, pid: pid, gesture: gesture, tiled: tiled, start: point, frame: frame, edges: edges, current: frame)
        if tiled { coordinator.beginMouseDrag(id) }
        if id != coordinator.focusedWindow { coordinator.focus(id) }
    }

    /// Moves or resizes the grabbed window after the pointer.
    private func dragged(to point: CGPoint) {
        guard var grab, let coordinator = AppState.shared.coordinator else { return }
        let dx = point.x - grab.start.x, dy = point.y - grab.start.y
        let start = grab.frame
        var frame = start
        switch grab.gesture {
        case .move:
            frame.origin = CGPoint(x: start.minX + dx, y: start.minY + dy)
        case .resize:
            if grab.edges.contains(.left) {
                frame.origin.x = min(start.minX + dx, start.maxX - minimumSide)
                frame.size.width = start.maxX - frame.minX
            } else {
                frame.size.width = max(minimumSide, start.width + dx)
            }
            if grab.edges.contains(.up) {
                frame.origin.y = min(start.minY + dy, start.maxY - minimumSide)
                frame.size.height = start.maxY - frame.minY
            } else {
                frame.size.height = max(minimumSide, start.height + dy)
            }
        }
        grab.current = frame
        self.grab = grab
        coordinator.applier.step([FrameJob(pid: grab.pid, id: grab.id, frame: frame)])
    }

    /// Ends a drag: a tiled window is dropped.
    private func release() {
        guard let grab else { return }
        self.grab = nil
        if grab.tiled { AppState.shared.coordinator?.endMouseDrag(grab.id, at: grab.current) }
    }

    /// Runs a binding's commands on the window under the pointer, focused first, or on the focused one without one.
    private static func run(_ commands: [String], on id: WindowID?) {
        if let id, let coordinator = AppState.shared.coordinator, id != coordinator.focusedWindow { coordinator.focus(id) }
        for text in commands {
            let reply: Reply
            do {
                reply = Dispatcher.run(try Command.parse(text), window: id)
            } catch {
                reply = .error(error.description)
            }
            if !reply.ok { fputs("\(text): \(reply.text)\n", stderr) }
        }
    }
}

private func mouseCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                           refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<MouseActions>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
