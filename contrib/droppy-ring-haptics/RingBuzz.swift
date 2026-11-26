// RingBuzz: plays a haptic tick each time the cursor moves onto a different
// slot of Droppy's Action Ring. Droppy publishes the ring through
// accessibility (an "Action Ring" group with one element per slot), so the
// slot layout is read from Droppy itself, never guessed.
//
// Usage: ring-buzz [command ...]   (default: openlogi haptic play tick)

import Cocoa
import ApplicationServices

let droppyBundle = "iordv.Droppy"
let ringLabel = "Action Ring"
let command = CommandLine.arguments.count > 1
    ? Array(CommandLine.arguments.dropFirst())
    : ["/opt/homebrew/bin/openlogi", "haptic", "play", "tick"]
let verbose = ProcessInfo.processInfo.environment["RING_BUZZ_DEBUG"] != nil

// MARK: accessibility reads

func axAttr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}

func axFrame(_ e: AXUIElement) -> CGRect? {
    guard let pv = axAttr(e, kAXPositionAttribute), let sv = axAttr(e, kAXSizeAttribute) else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    // swiftlint:disable force_cast — AX guarantees these attribute types.
    AXValueGetValue(pv as! AXValue, .cgPoint, &p)
    AXValueGetValue(sv as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}

func axChildren(_ e: AXUIElement) -> [AXUIElement] {
    (axAttr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func findRing(in e: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if (axAttr(e, kAXDescriptionAttribute) as? String) == ringLabel { return e }
    guard depth < 4 else { return nil }
    for c in axChildren(e) { if let r = findRing(in: c, depth: depth + 1) { return r } }
    return nil
}

// MARK: geometry

struct Slot { let name: String; let angle: Double; let radius: Double }

/// A slot layout normalised to the ring's own size, so it holds while the
/// ring's open animation scales it about its centre.
struct Layout {
    let slots: [Slot]
    /// Radii (as a fraction of the ring's width) separating the dead centre,
    /// the inner band and the outer band.
    let bandEdges: [Double]

    init?(ring: CGRect, labels: [(String, CGRect)]) {
        guard ring.width > 0, !labels.isEmpty else { return nil }
        let c = CGPoint(x: ring.midX, y: ring.midY)
        slots = labels.map { name, f in
            let dx = f.midX - c.x, dy = f.midY - c.y
            return Slot(name: name, angle: atan2(dy, dx), radius: hypot(dx, dy) / ring.width)
        }
        // Group labels into bands by radius: a jump of more than 0.05 of the
        // ring's width between sorted radii starts a new band.
        let radii = slots.map(\.radius).sorted()
        var bands: [[Double]] = [[radii[0]]]
        for r in radii.dropFirst() {
            if r - bands[bands.count - 1].last! > 0.05 { bands.append([r]) } else { bands[bands.count - 1].append(r) }
        }
        let means = bands.map { $0.reduce(0, +) / Double($0.count) }
        // Dead centre ends as far inside the innermost band as the gap to the
        // next band; bands meet halfway between their label radii.
        var edges = [means[0] - (means.count > 1 ? (means[1] - means[0]) / 2 : means[0] / 2)]
        for i in 1..<means.count { edges.append((means[i - 1] + means[i]) / 2) }
        bandEdges = edges
    }

    /// The slot under `p`, or nil in the dead centre.
    func slot(at p: CGPoint, ring: CGRect) -> Int? {
        let dx = p.x - ring.midX, dy = p.y - ring.midY
        let r = hypot(dx, dy) / ring.width
        guard r >= bandEdges[0] else { return nil }
        let band = bandEdges.lastIndex { r >= $0 }!
        let bandLo = bandEdges[band], bandHi = band + 1 < bandEdges.count ? bandEdges[band + 1] : .infinity
        let a = atan2(dy, dx)
        var best: (Int, Double)?
        for (i, s) in slots.enumerated() where s.radius >= bandLo && s.radius < bandHi {
            var d = abs(s.angle - a).truncatingRemainder(dividingBy: 2 * .pi)
            if d > .pi { d = 2 * .pi - d }
            if best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }
}

// MARK: haptic output

/// Runs the haptic command; a crossing that arrives while one is still in
/// flight is played once that one exits, so fast sweeps never queue up.
final class Buzzer {
    private var running = false
    private var pending = false

    func buzz() {
        if running { pending = true; return }
        running = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command[0])
        p.arguments = Array(command.dropFirst())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                self.running = false
                if self.pending { self.pending = false; self.buzz() }
            }
        }
        do { try p.run() } catch {
            running = false
            FileHandle.standardError.write("ring-buzz: cannot run \(command[0]): \(error)\n".data(using: .utf8)!)
        }
    }
}

// MARK: ring tracking

final class Tracker {
    private var app: AXUIElement?
    private var ring: AXUIElement?
    private var layout: Layout?
    private var frame: CGRect?
    private var current: Int?
    private var lastCheck = Date.distantPast
    private var lastWindowCount = -1
    private let buzzer = Buzzer()

    private func droppy() -> AXUIElement? {
        if let app { return app }
        guard let a = NSRunningApplication.runningApplications(withBundleIdentifier: droppyBundle).first else { return nil }
        app = AXUIElementCreateApplication(a.processIdentifier)
        return app
    }

    func appTerminated() { app = nil; closeRing() }

    private func closeRing() { ring = nil; layout = nil; frame = nil; current = nil }

    /// Look for the ring at most every 100 ms, and only while the pointer
    /// moves, so an idle Mac costs nothing.
    private func refreshRing() {
        let now = Date()
        guard now.timeIntervalSince(lastCheck) > 0.1 else { return }
        lastCheck = now
        if let ring {
            // A vanished element has no frame: the ring closed.
            frame = axFrame(ring)
            if frame == nil { closeRing() } else if layout == nil { readLayout() }
            return
        }
        guard let app = droppy() else { if verbose { print("droppy not running") }; return }
        let windows = (axAttr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        if verbose && windows.count != lastWindowCount { print("droppy windows: \(windows.count)"); lastWindowCount = windows.count }
        for w in (axAttr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            if let r = findRing(in: w) { ring = r; readLayout(); return }
        }
    }

    private func readLayout() {
        guard let ring, let frame = axFrame(ring) else { return }
        self.frame = frame
        let labels = axChildren(ring).compactMap { e -> (String, CGRect)? in
            guard let f = axFrame(e) else { return nil }
            return ((axAttr(e, kAXDescriptionAttribute) as? String) ?? "", f)
        }
        layout = Layout(ring: frame, labels: labels)
        if verbose, let layout {
            print("ring open: \(layout.slots.count) slots, band edges \(layout.bandEdges.map { String(format: "%.3f", $0) })")
        }
    }

    private var events = 0
    func pointerMoved(to p: CGPoint) {
        events += 1
        if verbose && events % 200 == 1 { print("pointer events: \(events) at \(p), ring: \(ring != nil)") }
        refreshRing()
        guard let layout, let frame else { return }
        let slot = layout.slot(at: p, ring: frame)
        guard slot != current else { return }
        current = slot
        if let slot {
            if verbose { print("hover \(layout.slots[slot].name)") }
            buzzer.buzz()
        }
    }
}

// MARK: self-check

func selfCheck() {
    // A two-band ring 400 wide at the origin: 4 inner slots at r=90, 4 outer at r=150.
    let ring = CGRect(x: 0, y: 0, width: 400, height: 400)
    func label(_ name: String, _ deg: Double, _ r: Double) -> (String, CGRect) {
        let a = deg * .pi / 180
        return (name, CGRect(x: 200 + r * cos(a) - 10, y: 200 + r * sin(a) - 10, width: 20, height: 20))
    }
    let labels = [0.0, 90, 180, 270].flatMap { [label("in\(Int($0))", $0, 90), label("out\(Int($0))", $0, 150)] }
    let l = Layout(ring: ring, labels: labels)!
    func name(_ x: Double, _ y: Double) -> String? { l.slot(at: CGPoint(x: x, y: y), ring: ring).map { l.slots[$0].name } }
    precondition(name(200, 200) == nil, "dead centre")
    precondition(name(290, 200) == "in0")
    precondition(name(350, 200) == "out0")
    precondition(name(200, 345) == "out90")
    precondition(name(200 - 85, 200 + 10) == "in180")
    precondition(name(390, 200) == "out0", "past the rim still picks the outer slot")
}

// MARK: main

if CommandLine.arguments.contains("--self-check") { selfCheck(); print("self-check ok"); exit(0) }

guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
    FileHandle.standardError.write("ring-buzz: needs Accessibility permission (System Settings › Privacy & Security › Accessibility)\n".data(using: .utf8)!)
    exit(1)
}

setvbuf(stdout, nil, _IOLBF, 0)  // line-buffer so a log file survives a kill
let tracker = Tracker()
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { e in
    // CGEvent coordinates share accessibility's top-left global origin.
    if let p = e.cgEvent?.location { tracker.pointerMoved(to: p) }
}
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
    if (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == droppyBundle { tracker.appTerminated() }
}
if verbose { print("ring-buzz: watching Droppy, command: \(command.joined(separator: " "))") }
app.run()
