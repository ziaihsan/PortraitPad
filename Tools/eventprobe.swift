// eventprobe: records every input event Sidecar delivers for finger / Pencil gestures, so PortraitPad's
// gesture mapping can be based on what actually arrives. Shows step-by-step instructions on the iPad,
// drawn rotated to read upright on an iPad held in portrait. Run it with PortraitPad quit.
//
//   swiftc -O Tools/eventprobe.swift -o build/eventprobe && build/eventprobe > probe.log

import AppKit

let passive = CommandLine.arguments.contains("--passive") || CommandLine.arguments.contains("--cursortest")   // non-activating, never key (like PortraitPad)
let allSteps: [(text: String, secs: Double)] = [
    ("1/6  Tap ONCE with 1 finger.\nDo it 3 times, slowly.", 12),
    ("2/6  Put 1 finger down, then drag\nUP and DOWN a few times.", 12),
    ("3/6  Drag UP and DOWN with 2 fingers.", 12),
    ("4/6  Press and hold 1 finger (about 1 s).\nDo it twice.", 12),
    ("5/6  Tap with 2 fingers, 3 times.", 10),
    ("6/6  Apple Pencil: tap 3 times, then draw a line.\n(Skip this if you have no Pencil.)", 12),
]
let cursorTest = CommandLine.arguments.contains("--cursortest")
let cursorSteps: [(text: String, secs: Double)] = [
    ("1/3  Tap with 1 finger, 3 times.\n(the pointer is on the Mac on purpose)", 12),
    ("2/3  Tap with 1 finger, 3 more times.\n(the pointer is now on the iPad)", 12),
    ("3/3  Put 1 finger down, drag\nUP and DOWN slowly a few times.", 15),
]
let steps: [(text: String, secs: Double)] = cursorTest ? cursorSteps : passive
    ? [("1/2  Tap ONCE with 1 finger.\nDo it 3 times, slowly.", 12), ("2/2  Put 1 finger down, then drag\nUP and DOWN a few times.", 12)]
    : allSteps

let typeNames: [UInt: String] = [
    1: "leftMouseDown", 2: "leftMouseUp", 3: "rightMouseDown", 4: "rightMouseUp", 5: "mouseMoved",
    6: "leftMouseDragged", 7: "rightMouseDragged", 8: "mouseEntered", 9: "mouseExited",
    13: "appKitDefined", 14: "systemDefined", 17: "cursorUpdate", 18: "rotate", 19: "beginGesture",
    20: "endGesture", 22: "scrollWheel", 23: "tabletPoint", 24: "tabletProximity", 25: "otherMouseDown",
    26: "otherMouseUp", 27: "otherMouseDragged", 29: "gesture", 30: "magnify", 31: "swipe",
    32: "smartMagnify", 33: "quickLook", 34: "pressure", 37: "directTouch", 38: "changeMode",
]
let phaseTypes: Set<UInt> = [18, 22, 29, 30, 31, 32, 34]

let launched = Date()
var stepIndex = -1                 // -1: waiting for the first touch
var stepStarted = Date()

func out(_ s: String) {
    print(String(format: "%8.3f ", Date().timeIntervalSince(launched)) + s)
    fflush(stdout)
}

func describe(_ e: NSEvent, _ origin: String) -> String {
    let raw = e.type.rawValue
    var s = "\(origin) \(typeNames[raw] ?? "type\(raw)")"
    if let cg = e.cgEvent {
        let p = cg.location
        s += " at=(\(Int(p.x)),\(Int(p.y)))"
        s += " sub=\(cg.getIntegerValueField(.mouseEventSubtype))"
        s += " btn=\(cg.getIntegerValueField(.mouseEventButtonNumber))"
        s += " clicks=\(cg.getIntegerValueField(.mouseEventClickState))"
        s += String(format: " press=%.2f", cg.getDoubleValueField(.mouseEventPressure))
        s += " d=(\(cg.getIntegerValueField(.mouseEventDeltaX)),\(cg.getIntegerValueField(.mouseEventDeltaY)))"
        if raw == 22 {
            s += " scroll=(v \(cg.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)), h \(cg.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)))"
            s += " continuous=\(cg.getIntegerValueField(.scrollWheelEventIsContinuous))"
            s += " cgPhase=\(cg.getIntegerValueField(.scrollWheelEventScrollPhase))"
            s += " momentum=\(cg.getIntegerValueField(.scrollWheelEventMomentumPhase))"
        }
    }
    if phaseTypes.contains(raw) { s += " phase=\(e.phase.rawValue) mphase=\(e.momentumPhase.rawValue)" }
    if raw == 13 || raw == 14 { s += " subtype=\(e.subtype.rawValue) data1=\(e.data1) data2=\(e.data2)" }
    if raw == 30 { s += String(format: " magnification=%.3f", e.magnification) }
    s += e.window == nil ? " win=other" : " win=probe"
    return s
}

class ProbeView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let text: String
        if stepIndex < 0 {
            text = "GESTURE TEST\n\nTap this screen once to start."
        } else if stepIndex < steps.count {
            let left = max(0, Int(steps[stepIndex].secs - Date().timeIntervalSince(stepStarted)))
            text = steps[stepIndex].text + "\n\nsisa \(left) detik"
        } else {
            text = "Done. Thank you!"
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 42, weight: .semibold),
            .foregroundColor: NSColor.white, .paragraphStyle: style,
        ]
        // Rotate +90° so the text reads upright on an iPad held in portrait (same as PortraitPad).
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: bounds.midX, y: bounds.midY)
        ctx.rotate(by: .pi / 2)
        let portrait = NSRect(x: -bounds.height / 2 + 40, y: -bounds.width / 2, width: bounds.height - 80, height: bounds.width * 0.6)
        (text as NSString).draw(in: portrait, withAttributes: attrs)
        ctx.restoreGState()
    }

    // Touch delivery (if Sidecar sends real touches rather than mouse events).
    func logTouches(_ e: NSEvent, _ label: String) {
        for t in e.touches(matching: .any, in: self) {
            let pos = t.type == .direct ? "loc=\(t.location(in: self))" : "norm=\(t.normalizedPosition)"
            out("TOUCH \(label) type=\(t.type == .direct ? "direct" : "indirect") phase=\(t.phase.rawValue) \(pos)")
        }
    }
    override func touchesBegan(with e: NSEvent) { logTouches(e, "began"); begin("touch") }
    override func touchesMoved(with e: NSEvent) { logTouches(e, "moved") }
    override func touchesEnded(with e: NSEvent) { logTouches(e, "ended") }
    override func touchesCancelled(with e: NSEvent) { logTouches(e, "cancelled") }
}

guard let sidecar = NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains("Sidecar") }) else {
    out("no Sidecar screen; connect the iPad first")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Key-capable and activated: tests whether Sidecar delivers finger touches only to the key window.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
let panel = passive
    ? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    : KeyPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
// --level=N overrides the window level (default: shielding level, as PortraitPad uses).
let levelArg = CommandLine.arguments.first { $0.hasPrefix("--level=") }.flatMap { Int($0.dropFirst(8)) }
panel.level = NSWindow.Level(rawValue: levelArg ?? Int(CGShieldingWindowLevel()))
panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
panel.acceptsMouseMovedEvents = true
panel.isOpaque = true
panel.backgroundColor = .black
panel.setFrame(sidecar.frame, display: false)
// Overlay with the instructions; it never takes hits, so touches reach the scroll view underneath.
final class OverlayView: ProbeView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// A real scroll view under the finger: tests whether macOS turns Sidecar finger drags into scroll
// events only when something scrollable is under the touch.
final class ProbeScrollView: NSScrollView {
    override func scrollWheel(with e: NSEvent) {
        out("SCROLLVIEW " + describe(e, "S") + String(format: " precise=(%.1f,%.1f)", e.scrollingDeltaX, e.scrollingDeltaY))
        super.scrollWheel(with: e)
    }
}

final class GestureLogger: NSObject {
    @objc func click(_ g: NSClickGestureRecognizer) { out("GESTURE click state=\(g.state.rawValue) at=\(g.location(in: g.view))"); begin("click gesture") }
    @objc func press(_ g: NSPressGestureRecognizer) { out("GESTURE press state=\(g.state.rawValue) at=\(g.location(in: g.view))") }
    @objc func pan(_ g: NSPanGestureRecognizer) {
        out("GESTURE pan state=\(g.state.rawValue) at=\(g.location(in: g.view)) t=\(g.translation(in: g.view))")
        // Does a gesture keep arriving after the pointer leaves the Sidecar screen mid-gesture?
        if cursorTest, g.state == .began { warp(toSidecar: false); out("warped pointer to laptop mid-pan") }
    }
}

let container = NSView(frame: NSRect(origin: .zero, size: sidecar.frame.size))
let scroll = ProbeScrollView(frame: container.bounds)
scroll.autoresizingMask = [.width, .height]
scroll.hasVerticalScroller = true
scroll.hasHorizontalScroller = true
scroll.drawsBackground = false
let doc = NSView(frame: NSRect(x: 0, y: 0, width: sidecar.frame.width * 4, height: sidecar.frame.height * 4))
scroll.documentView = doc
doc.scroll(NSPoint(x: sidecar.frame.width * 1.5, y: sidecar.frame.height * 1.5))
let logger = GestureLogger()
scroll.addGestureRecognizer(NSClickGestureRecognizer(target: logger, action: #selector(GestureLogger.click(_:))))
scroll.addGestureRecognizer(NSPressGestureRecognizer(target: logger, action: #selector(GestureLogger.press(_:))))
scroll.addGestureRecognizer(NSPanGestureRecognizer(target: logger, action: #selector(GestureLogger.pan(_:))))
scroll.allowedTouchTypes = [.direct, .indirect]
container.addSubview(scroll)
let view = OverlayView(frame: container.bounds)
view.autoresizingMask = [.width, .height]
container.addSubview(view)
panel.contentView = container
if passive {
    panel.orderFrontRegardless()
} else {
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(scroll)
}
out("mode: \(passive ? "passive" : "key window")")
out("probe on Sidecar \(sidecar.frame), waiting for first touch")

func warp(toSidecar: Bool) {
    let sc = NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("Sidecar") }
    let id = toSidecar && sc != nil
        ? CGDirectDisplayID(truncating: sc!.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber)
        : CGMainDisplayID()
    let b = CGDisplayBounds(id)
    CGWarpMouseCursorPosition(CGPoint(x: b.midX, y: b.midY))
    CGAssociateMouseAndMouseCursorPosition(1)
    out("pointer -> \(toSidecar ? "sidecar" : "laptop")")
}

func onStep(_ i: Int) {
    guard cursorTest, i < steps.count else { return }
    warp(toSidecar: i >= 1)
}

func begin(_ why: String) {
    guard stepIndex < 0 else { return }
    stepIndex = 0
    stepStarted = Date()
    out("started by \(why)")
    out("=== STEP \(steps[0].text.replacingOccurrences(of: "\n", with: " ")) ===")
    onStep(0)
    view.needsDisplay = true
}

_ = NSEvent.addLocalMonitorForEvents(matching: .any) { e in
    out(describe(e, "L"))
    if e.type.rawValue == 13, e.subtype.rawValue == 18 {
        // Private subtype seen once per finger tap: dump every non-zero CGEvent field.
        if let cg = e.cgEvent {
            var fields: [String] = []
            for f in 0..<256 {
                guard let field = CGEventField(rawValue: UInt32(f)) else { continue }
                let i = cg.getIntegerValueField(field), d = cg.getDoubleValueField(field)
                if i != 0 || d != 0 { fields.append("\(f)=\(i)/\(String(format: "%.2f", d))") }
            }
            out("   fields: " + fields.joined(separator: " "))
        }
        out("   key=\(panel.isKeyWindow) active=\(NSApp.isActive)")
        begin("appKitDefined 18")
    }
    // Start on a real touch/click/scroll, not on the pointer merely resting over the Sidecar screen.
    let starters: Set<UInt> = [1, 3, 5, 6, 22, 23, 25, 37]
    if e.window === panel, starters.contains(e.type.rawValue) { begin("event \(e.type.rawValue)") }
    return e
}

// Pointer position, polled: a Sidecar finger tap may warp the pointer without posting any event.
var lastPointer = CGPoint(x: -1, y: -1)
Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { _ in
    guard let p = CGEvent(source: nil)?.location, p != lastPointer else { return }
    lastPointer = p
    let onSidecar = NSScreen.screens.contains { $0 == sidecar && CGDisplayBounds(CGDirectDisplayID(truncating: $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber)).contains(p) }
    out("POINTER at=(\(Int(p.x)),\(Int(p.y)))\(onSidecar ? " on=sidecar" : "")")
    if onSidecar, !cursorTest { begin("pointer on Sidecar") }
}

// Session-level listen-only tap: sees events even if they never reach a window.
let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type.rawValue != 5 {   // plain mouse moves are already covered by the pointer poll
        out("TAP type=\(type.rawValue) at=(\(Int(event.location.x)),\(Int(event.location.y))) sub=\(event.getIntegerValueField(.mouseEventSubtype)) clicks=\(event.getIntegerValueField(.mouseEventClickState)) scroll=(\(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)),\(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))) src=\(event.getIntegerValueField(.eventSourceUnixProcessID))")
    }
    return Unmanaged.passUnretained(event)
}
if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                               eventsOfInterest: CGEventMask.max, callback: tapCallback, userInfo: nil) {
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    out("event tap active")
} else {
    out("event tap unavailable")
}
if cursorTest { _ = NSEvent.addGlobalMonitorForEvents(matching: [.gesture]) { _ in begin("trackpad touch") } }
_ = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                                 .rightMouseDown, .rightMouseUp, .scrollWheel, .tabletPoint,
                                                 .magnify, .gesture, .pressure]) { e in out(describe(e, "G")) }

// Common modes: keeps the countdown running while AppKit tracks a gesture (event-tracking run loop mode).
let stepTimer = Timer(timeInterval: 0.25, repeats: true) { _ in
    if stepIndex < 0 {
        if Date().timeIntervalSince(launched) > 900 { out("timeout waiting"); exit(2) }
        return
    }
    if stepIndex < steps.count, Date().timeIntervalSince(stepStarted) >= steps[stepIndex].secs {
        stepIndex += 1
        stepStarted = Date()
        if stepIndex < steps.count {
            out("=== STEP \(steps[stepIndex].text.replacingOccurrences(of: "\n", with: " ")) ===")
            onStep(stepIndex)
        } else {
            out("=== DONE ===")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
        }
    }
    view.needsDisplay = true
}
RunLoop.main.add(stepTimer, forMode: .common)
out("window level \(panel.level.rawValue)")

app.run()
