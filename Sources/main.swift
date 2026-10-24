// PortraitPad: show a portrait virtual display on a landscape Sidecar iPad.
//
// Pipeline: virtual display (984x1312 pt, HiDPI, 60 Hz)
//   -> ScreenCaptureKit (IOSurface frames, only delivered when content changes)
//   -> CALayer rotated 90° in a shield-level window covering the Sidecar screen.
// No CPU pixel copies: each frame's IOSurface is handed straight to Core Animation.

import AppKit
import CoreMedia
import ScreenCaptureKit

let pointsW = 984, pointsH = 1312          // portrait size in points (3:4, matches iPad 2628x1970 px)
let pixelsW = pointsW * 2, pixelsH = pointsH * 2
let fps: Int32 = 60                         // Sidecar's ceiling
let rotation = CGFloat.pi / 2               // +90° (CCW): top of portrait image -> left edge of Sidecar
let vdOriginKey = "portraitOrigin"

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PortraitPad.log")
let logFile: FileHandle? = {
    if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
    let h = try? FileHandle(forWritingTo: logURL)
    h?.seekToEndOfFile()
    return h
}()

// `defaults write local.z.PortraitPad debugInput -bool true` logs each touch update (for gesture work).
let debugInput = UserDefaults.standard.bool(forKey: "debugInput")

// A background app normally can't hide the pointer; this connection property (private SkyLight API,
// verified on macOS 27) lets PortraitPad hide it while a scroll borrows it.
@_silgen_name("_CGSDefaultConnection") func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty")
func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

func log(_ s: String) {
    let line = String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + "[PortraitPad] \(s)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    logFile?.write(line.data(using: .utf8)!)
}

func displayID(of screen: NSScreen) -> CGDirectDisplayID {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}

func sidecarScreen() -> NSScreen? {
    NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("Sidecar") }
}

// Finger touches that Sidecar delivers to its own (covered) screen, re-posted at the matching spot on
// the portrait display. Needs Accessibility permission to post events.
//
// Sidecar hands finger touches to AppKit gesture recognizers (as direct-touch events), not as mouse
// events. A zero-delay press recognizer follows one-finger touches: a short still touch clicks, a drag
// scrolls the content under the finger (with momentum on release). A two-finger pan recognizer handles
// one gesture only: a sideways swipe switches Spaces / full-screen apps (Ctrl-arrow) once the fingers
// lift. Everything else is left alone, including mouse/trackpad events on this hidden screen, so the
// real pointer is never thrown around.
final class InputView: NSView, NSGestureRecognizerDelegate {
    var toPortrait: ((NSPoint) -> CGPoint?)?

    static let tapSlop: CGFloat = 10            // movement (pt) before a touch becomes a scroll
    static let tapMaxDuration = 0.5             // longer still touches are ignored, not clicked
    static let momentumDecay: CGFloat = 0.965   // per frame at 60 Hz
    static let momentumMinSpeed: CGFloat = 150  // pt/s to start a fling; it stops below 20 pt/s
    static let spaceSwipeDistance: CGFloat = 60 // pt sideways for a two-finger swipe to switch Spaces
    static let pointerParkTime = 0.15           // s the lent pointer stays on the iPad for a Space switch

    private let source = CGEventSource(stateID: .hidSystemState)
    private var touchStart = NSPoint.zero, touchStartTime = Date(), lastPoint = NSPoint.zero
    private var ignoring = false, scrolling = false, verticalLock = true
    private var remainder = CGVector.zero                       // sub-point scroll left to post
    private var samples: [(t: TimeInterval, d: CGVector)] = []  // recent scroll deltas, for fling speed
    private var momentum: Timer?
    private var lent: (home: CGPoint, spot: CGPoint, since: Date)?   // pointer lent to a scroll (see lendCursor)
    private var lentWatch: Timer?
    private var swiping = false                                 // a two-finger touch is being followed

    override init(frame: NSRect) {
        super.init(frame: frame)
        let touch = NSPressGestureRecognizer(target: self, action: #selector(track(_:)))
        touch.minimumPressDuration = 0
        touch.allowableMovement = .greatestFiniteMagnitude
        touch.delegate = self
        addGestureRecognizer(touch)
        let twoFingers = NSPanGestureRecognizer(target: self, action: #selector(trackTwoFingers(_:)))
        twoFingers.numberOfTouchesRequired = 2
        twoFingers.delegate = self
        addGestureRecognizer(twoFingers)
    }

    func gestureRecognizer(_ g: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool {
        true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: touch tracking

    @objc private func track(_ g: NSPressGestureRecognizer) {
        let p = g.location(in: self)
        if debugInput { log("touch state=\(g.state.rawValue) at=(\(Int(p.x)),\(Int(p.y))) " + describeCurrentEvent()) }
        switch g.state {
        case .began:
            stopMomentum(returnAfter: 0)
            ignoring = !isOneFinger()
            touchStart = p
            lastPoint = p
            touchStartTime = Date()
            scrolling = false
            remainder = .zero
            samples = []
        case .changed:
            if ignoring { return }
            if !isOneFinger() {                     // a second finger: stop here, do nothing more
                endScroll(fling: false)
                ignoring = true
                return
            }
            if !scrolling, hypot(p.x - touchStart.x, p.y - touchStart.y) > Self.tapSlop {
                scrolling = true
                let d = contentDelta(from: touchStart, to: p)
                verticalLock = abs(d.dy) >= abs(d.dx)
                // Scroll events go to the window under the pointer: lend it unless it is over that window.
                lendCursor(to: touchStart) { [weak self] spot, home in
                    guard let self, let w = self.windowNumber(at: spot) else { return false }
                    return w == self.windowNumber(at: home)
                }
                postScroll(.zero, phase: 1)         // began
                lastPoint = touchStart              // the slop distance scrolls too, so nothing jumps
            }
            if scrolling {
                let d = contentDelta(from: lastPoint, to: p)
                postScroll(d, phase: 2)             // changed
                samples.append((ProcessInfo.processInfo.systemUptime, d))
                lastPoint = p
            }
        case .ended:
            if ignoring {
                // nothing
            } else if scrolling {
                endScroll(fling: true)
            } else if Date().timeIntervalSince(touchStartTime) <= Self.tapMaxDuration {
                click(at: touchStart)
            }
            ignoring = false
        case .cancelled:                            // e.g. a second finger landed
            if !ignoring { endScroll(fling: false) }
            ignoring = false
        default:
            break
        }
    }

    // Two fingers: only a sideways swipe does something, and only after the fingers lift (switching
    // Spaces mid-touch once left the touch unfinished and froze all touch input).
    @objc private func trackTwoFingers(_ g: NSPanGestureRecognizer) {
        if debugInput { log("two fingers state=\(g.state.rawValue) t=\(g.translation(in: self)) " + describeCurrentEvent()) }
        switch g.state {
        case .began:
            swiping = NSApp.currentEvent?.type == .directTouch   // fingers only, never a mouse
        case .ended:
            guard swiping else { break }
            swiping = false
            let t = g.translation(in: self)
            let sideways = t.y, vertical = t.x                  // portrait axes (see contentDelta)
            guard abs(sideways) > Self.spaceSwipeDistance, abs(sideways) > abs(vertical) * 1.5 else { break }
            // Like the trackpad's "swipe between full-screen applications": fingers left shows the Space
            // on the right (Ctrl-→), fingers right the one on the left (Ctrl-←).
            switchSpace(sideways < 0 ? 124 : 123, at: g.location(in: self))
        case .cancelled, .failed:
            swiping = false
        default:
            break
        }
    }

    // Space hotkeys act on the display under the pointer (a key event's own location is ignored), so if
    // the pointer is elsewhere it is lent to the iPad for a moment, hidden, the same way a scroll lends it.
    private func switchSpace(_ key: CGKeyCode, at viewPoint: NSPoint) {
        lendCursor(to: viewPoint) { [weak self] _, home in self?.portraitBounds()?.contains(home) == true }
        pressControlArrow(key)
        giveCursorBack(after: Self.pointerParkTime)
        if debugInput { log("space switch key=\(key)") }
    }

    private func portraitBounds() -> CGRect? {
        guard let a = toPortrait?(.zero), let b = toPortrait?(NSPoint(x: bounds.width, y: bounds.height)) else { return nil }
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    private func isOneFinger() -> Bool {
        guard let e = NSApp.currentEvent, e.type == .directTouch else { return false }   // not a finger
        return e.allTouches().count == 1
    }

    private func endScroll(fling: Bool) {
        guard scrolling else { return }
        scrolling = false
        postScroll(.zero, phase: 4)                 // ended
        if fling { startMomentum(flingVelocity()) }
        if momentum == nil { giveCursorBack(after: 0.05) }
    }

    // Finger movement in this (landscape, y-up) view -> content movement on the portrait display.
    // The image is rotated +90°: portrait "down" is view +x, portrait "right" is view +y. Content follows
    // the finger; CGEvent scroll axis 1 is vertical (+ moves content down), axis 2 horizontal (+ right).
    private func contentDelta(from a: NSPoint, to b: NSPoint) -> CGVector {
        let d = CGVector(dx: b.y - a.y, dy: b.x - a.x)
        guard scrolling else { return d }
        return verticalLock ? CGVector(dx: 0, dy: d.dy) : CGVector(dx: d.dx, dy: 0)
    }

    // MARK: posting

    // Pressed like a real keyboard: Control down, arrow down/up, Control up. Flagging only the arrow left
    // Control "held" in the event source and turned later taps into right-clicks. Arrow keys carry the fn
    // and numeric-pad flags on a real keyboard; the Mission Control hotkeys match on them.
    private func pressControlArrow(_ keyCode: CGKeyCode) {
        let control: CGKeyCode = 59
        let arrowFlags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        for (key, down, flags) in [(control, true, CGEventFlags.maskControl), (keyCode, true, arrowFlags),
                                   (keyCode, false, arrowFlags), (control, false, [])] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    // Modifier keys really held on the keyboard (Cmd-tap still works), nothing else.
    private func heldModifiers() -> CGEventFlags {
        CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
    }

    // MARK: lending the pointer

    // macOS sends scroll events to the window under the pointer (apps like Claude, on Electron, ignore
    // scrolls posted to them directly) and switches Spaces on the display under it. So when a touch needs
    // the pointer and `keep` says it can't stay where it is, it is lent: hidden, put under the finger, and
    // given back when the scroll and its momentum (or the Space switch) end. On screen it never leaves
    // where you had it. Moving the trackpad or mouse meanwhile takes it back at once (a scroll stops), so
    // it is never dragged away from you; after 6 s it is returned regardless.
    private func lendCursor(to viewPoint: NSPoint, keep: (_ spot: CGPoint, _ home: CGPoint) -> Bool) {
        guard lent == nil, let spot = toPortrait?(viewPoint), let home = CGEvent(source: nil)?.location else { return }
        if keep(spot, home) { return }
        lent = (home, spot, Date())
        CGDisplayHideCursor(CGMainDisplayID())
        CGWarpMouseCursorPosition(spot)
        CGAssociateMouseAndMouseCursorPosition(1)
        let watch = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.watchLentCursor() }
        RunLoop.main.add(watch, forMode: .common)
        lentWatch = watch
    }

    private func watchLentCursor() {
        guard let l = lent, let now = CGEvent(source: nil)?.location else { return }
        let moved = hypot(now.x - l.spot.x, now.y - l.spot.y) > 2
        guard moved || Date().timeIntervalSince(l.since) > 6 else { return }
        if moved { log("pointer moved while lent; giving it back") }
        if scrolling {                              // stop scrolling: it would now hit whatever is under the pointer
            postScroll(.zero, phase: 4)
            scrolling = false
            ignoring = true
        }
        stopMomentum(returnAfter: 0)
        giveCursorBack()
    }

    // Puts the lent pointer back where it was and shows it. A short delay lets already-posted scroll
    // events reach the window they were meant for.
    private func giveCursorBack(after delay: TimeInterval = 0) {
        guard let l = lent else { return }
        lent = nil
        lentWatch?.invalidate()
        lentWatch = nil
        let restore = {
            CGWarpMouseCursorPosition(l.home)
            CGAssociateMouseAndMouseCursorPosition(1)   // no brief pointer freeze after the warp
            CGDisplayShowCursor(CGMainDisplayID())
        }
        if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: restore) } else { restore() }
    }

    func releaseCursor() {
        stopMomentum(returnAfter: 0)
        giveCursorBack()
    }

    private func windowNumber(at p: CGPoint) -> Int? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for w in windows where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict), r.contains(p) else { continue }
            return w[kCGWindowNumber as String] as? Int
        }
        return nil
    }

    private func click(at viewPoint: NSPoint) {
        guard let p = toPortrait?(viewPoint) else { return }
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            else { continue }
            if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: 1) }
            e.flags = heldModifiers()
            e.post(tap: .cghidEventTap)
        }
    }

    // phase: CGScrollPhase raw value (1 began, 2 changed, 4 ended, 0 none); momentum: 1 begin, 2 continue, 3 end.
    private func postScroll(_ content: CGVector, phase: Int64, momentum: Int64 = 0) {
        guard let anchor = toPortrait?(touchStart) else { return }
        remainder.dx += content.dx
        remainder.dy += content.dy
        let v = Int32(remainder.dy.rounded(.towardZero)), h = Int32(remainder.dx.rounded(.towardZero))
        remainder.dx -= CGFloat(h)
        remainder.dy -= CGFloat(v)
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: v, wheel2: h, wheel3: 0)
        else { return }
        e.location = anchor
        e.flags = heldModifiers()
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        e.post(tap: .cghidEventTap)
    }

    // MARK: momentum

    private func flingVelocity() -> CGVector {
        let now = ProcessInfo.processInfo.systemUptime
        let recent = samples.filter { now - $0.t < 0.08 }   // a pause before lifting means no fling
        guard let first = recent.first, recent.count >= 2 else { return .zero }
        let span = max(now - first.t, 1.0 / 60)
        let sum = recent.reduce(CGVector.zero) { CGVector(dx: $0.dx + $1.d.dx, dy: $0.dy + $1.d.dy) }
        return CGVector(dx: sum.dx / span, dy: sum.dy / span)
    }

    private func startMomentum(_ v: CGVector) {
        guard hypot(v.dx, v.dy) >= Self.momentumMinSpeed else { return }
        var velocity = v, phase: Int64 = 1
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            velocity.dx *= Self.momentumDecay
            velocity.dy *= Self.momentumDecay
            if hypot(velocity.dx, velocity.dy) < 20 { self.stopMomentum(); return }
            self.postScroll(CGVector(dx: velocity.dx / 60, dy: velocity.dy / 60), phase: 0, momentum: phase)
            phase = 2
        }
        RunLoop.main.add(timer, forMode: .common)   // keeps running while AppKit tracks a new touch
        momentum = timer
    }

    // The momentum's end event is posted while the lent pointer is still in place, then it goes back.
    private func stopMomentum(returnAfter delay: TimeInterval = 0.05) {
        if let timer = momentum {
            timer.invalidate()
            momentum = nil
            postScroll(.zero, phase: 0, momentum: 3)
        }
        giveCursorBack(after: delay)
    }
}

final class Streamer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var virtualDisplay: CGVirtualDisplay?
    private var stream: SCStream?
    private var window: NSWindow?
    private let videoLayer = CALayer()
    private let frameQueue = DispatchQueue(label: "portraitpad.frames", qos: .userInteractive)
    private(set) var running = false
    private var starting = false
    private var parkTries = (spot: "", count: 0, since: Date.distantPast)   // retries of one parking spot

    // MARK: lifecycle

    func sync() {
        let sidecar = sidecarScreen()
        if let sidecar, !running, !starting {
            start(on: sidecar)
        } else if sidecar == nil, running {
            stop()
        } else if let sidecar, running {
            window?.setFrame(sidecar.frame, display: true)   // Sidecar resized or moved
            layoutVideoLayer()
            saveArrangement()
            parkSidecar(displayID(of: sidecar))
        }
    }

    private func start(on sidecar: NSScreen) {
        starting = true
        log("Sidecar found (\(Int(sidecar.frame.width))x\(Int(sidecar.frame.height))), starting")
        guard let vd = makeVirtualDisplay() else { log("virtual display creation failed"); starting = false; return }
        virtualDisplay = vd
        // The new display needs a moment to register before modes and capture are available.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            selectHiDPIMode(vd.displayID)
            arrange(vd: vd.displayID, sidecar: displayID(of: sidecar))
            showWindow(on: sidecar)
            Task { await startCapture(vd.displayID) }
        }
    }

    func stop() {
        log("stopping")
        (window?.contentView as? InputView)?.releaseCursor()
        stream?.stopCapture { _ in }
        stream = nil
        window?.orderOut(nil)
        window = nil
        virtualDisplay = nil          // releasing it removes the display; windows move back to the Mac
        running = false
        starting = false
    }

    // MARK: virtual display

    private func makeVirtualDisplay() -> CGVirtualDisplay? {
        let desc = CGVirtualDisplayDescriptor()
        desc.queue = DispatchQueue.main
        desc.name = "PortraitPad"
        desc.maxPixelsWide = UInt32(pixelsW)
        desc.maxPixelsHigh = UInt32(pixelsH)
        desc.sizeInMillimeters = CGSize(width: 179, height: 239)   // ~11" iPad held upright
        desc.vendorID = 0x5050
        desc.productID = 0x0001
        desc.serialNum = 0x0001
        desc.terminationHandler = { _, _ in log("virtual display terminated") }

        let vd = CGVirtualDisplay(descriptor: desc)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        // With hiDPI on, a mode is given in points and backed by 2x pixels (bounded by maxPixels).
        settings.modes = [CGVirtualDisplayMode(width: UInt(pointsW), height: UInt(pointsH), refreshRate: Double(fps))]
        guard vd.apply(settings), vd.displayID != 0 else { return nil }
        log("virtual display id \(vd.displayID)")
        return vd
    }

    private func selectHiDPIMode(_ id: CGDirectDisplayID) {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] else { return }
        let want = modes.first { $0.width == pointsW && $0.height == pointsH && $0.pixelWidth == pixelsW }
        guard let want else {
            log("HiDPI mode not found; modes: " + modes.map { "\($0.width)x\($0.height)@\($0.pixelWidth)" }.joined(separator: ", "))
            return
        }
        var cfg: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cfg)
        CGConfigureDisplayWithDisplayMode(cfg, id, want, nil)
        let err = CGCompleteDisplayConfiguration(cfg, .forSession)
        log("mode \(want.width)x\(want.height)@\(want.pixelWidth): \(err == .success ? "ok" : "error \(err.rawValue)")")
    }

    // Puts the portrait display where it was last dragged in System Settings ▸ Displays ▸ Arrange (first
    // run: directly above the Mac), and parks the hidden Sidecar desktop out of the pointer's way.
    private func arrange(vd: CGDirectDisplayID, sidecar: CGDirectDisplayID) {
        let main = CGDisplayBounds(CGMainDisplayID())
        let origin = savedOrigin(vdOriginKey)
            ?? (Int32(main.midX) - Int32(pointsW / 2), Int32(main.minY) - Int32(pointsH))
        let vdRect = CGRect(x: CGFloat(origin.0), y: CGFloat(origin.1), width: CGFloat(pointsW), height: CGFloat(pointsH))
        var cfg: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cfg)
        CGConfigureDisplayOrigin(cfg, vd, origin.0, origin.1)
        if let park = parkingSpot(vd: vdRect, sidecar: CGDisplayBounds(sidecar).size) {
            CGConfigureDisplayOrigin(cfg, sidecar, Int32(park.x), Int32(park.y))
        }
        CGCompleteDisplayConfiguration(cfg, .forSession)
        log("arranged: portrait at \(origin)")
    }

    // Called once screen changes settle while streaming, so wherever the portrait display was dragged last
    // becomes the default.
    private func saveArrangement() {
        guard let vd = virtualDisplay?.displayID else { return }
        let o = CGDisplayBounds(vd).origin, value = [Int(o.x), Int(o.y)]
        guard UserDefaults.standard.array(forKey: vdOriginKey) as? [Int] != value else { return }
        UserDefaults.standard.set(value, forKey: vdOriginKey)
        log("saved arrangement: portrait at \(value)")
    }

    private func savedOrigin(_ key: String) -> (Int32, Int32)? {
        guard let a = UserDefaults.standard.array(forKey: key) as? [Int], a.count == 2 else { return nil }
        return (Int32(a[0]), Int32(a[1]))
    }

    // The real Sidecar desktop sits hidden under the stream. Wherever the portrait display goes, keep the
    // Sidecar screen touching it only at the outer corner farthest from the Mac, never along an edge of
    // the Mac's screen: otherwise the pointer slips onto it (invisible) between the Mac and the iPad.
    private func parkSidecar(_ sidecar: CGDirectDisplayID) {
        guard let vd = virtualDisplay?.displayID else { return }
        let vdRect = CGDisplayBounds(vd), current = CGDisplayBounds(sidecar)
        guard let park = parkingSpot(vd: vdRect, sidecar: current.size) else { return }
        guard park != current.origin else { parkTries.count = 0; return }
        // Something else may move it again (System Settings applies its own copy of the arrangement when
        // its Arrange sheet closes), so retry; but give up on a spot macOS keeps refusing, to avoid a loop.
        let spot = "\(vdRect.origin) \(park)"
        if parkTries.spot != spot || Date().timeIntervalSince(parkTries.since) > 30 { parkTries = (spot, 0, Date()) }
        guard parkTries.count < 3 else { return }
        parkTries.count += 1
        var cfg: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cfg)
        CGConfigureDisplayOrigin(cfg, sidecar, Int32(park.x), Int32(park.y))
        CGCompleteDisplayConfiguration(cfg, .forSession)
        log("parked sidecar at \(park)")
    }

    private func parkingSpot(vd v: CGRect, sidecar s: CGSize) -> CGPoint? {
        let main = CGDisplayBounds(CGMainDisplayID())
        func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat { min(a1, b1) - max(a0, b0) }
        func usable(_ r: CGRect) -> Bool {
            let mx = overlap(r.minX, r.maxX, main.minX, main.maxX), my = overlap(r.minY, r.maxY, main.minY, main.maxY)
            if mx >= 0, my >= 0, mx > 0 || my > 0 { return false }   // overlaps or shares an edge with the Mac
            return !(overlap(r.minX, r.maxX, v.minX, v.maxX) > 0 && overlap(r.minY, r.maxY, v.minY, v.maxY) > 0)
        }
        let corners = [CGPoint(x: v.minX - s.width, y: v.minY - s.height), CGPoint(x: v.maxX, y: v.minY - s.height),
                       CGPoint(x: v.minX - s.width, y: v.maxY), CGPoint(x: v.maxX, y: v.maxY)]
        return corners.map { CGRect(origin: $0, size: s) }.filter(usable)
            .max { hypot($0.midX - main.midX, $0.midY - main.midY) < hypot($1.midX - main.midX, $1.midY - main.midY) }?
            .origin
    }

    // MARK: output window on the Sidecar screen

    private func showWindow(on sidecar: NSScreen) {
        // Non-activating panel: touches/Pencil land here without stealing focus from the app being used.
        let w = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isOpaque = true
        w.hasShadow = false
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.setFrame(sidecar.frame, display: false)

        let root = InputView(frame: NSRect(origin: .zero, size: sidecar.frame.size))
        root.toPortrait = { [weak self] p in self?.portraitPoint(p) }
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.contentsGravity = .resize
        videoLayer.magnificationFilter = .linear
        videoLayer.minificationFilter = .linear
        videoLayer.isOpaque = true
        root.layer?.addSublayer(videoLayer)
        w.contentView = root
        window = w
        layoutVideoLayer()
        w.orderFrontRegardless()
    }

    private func layoutVideoLayer() {
        guard let size = window?.contentView?.bounds.size else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.bounds = CGRect(x: 0, y: 0, width: size.height, height: size.width)   // portrait
        videoLayer.position = CGPoint(x: size.width / 2, y: size.height / 2)
        videoLayer.setAffineTransform(CGAffineTransform(rotationAngle: rotation))
        CATransaction.commit()
    }

    // Point in the Sidecar window (points, origin bottom-left) -> global point on the portrait display.
    // The +90° rotation puts the portrait's top edge on the window's left and its left edge on the bottom.
    private func portraitPoint(_ p: NSPoint) -> CGPoint? {
        guard let vd = virtualDisplay?.displayID, let size = window?.contentView?.bounds.size,
              size.width > 0, size.height > 0 else { return nil }
        let b = CGDisplayBounds(vd)
        let x = min(max(p.y / size.height, 0), 1) * b.width
        let y = min(max(p.x / size.width, 0), 1) * b.height
        return CGPoint(x: b.minX + x, y: b.minY + y)
    }

    // MARK: capture

    private func startCapture(_ id: CGDirectDisplayID) async {
        do {
            var display: SCDisplay?
            for _ in 0..<10 {   // the new display can take a moment to show up in shareable content
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                display = content.displays.first { $0.displayID == id }
                if display != nil { break }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            guard let display else { log("virtual display not visible to ScreenCaptureKit"); return }

            let cfg = SCStreamConfiguration()
            cfg.width = pixelsW
            cfg.height = pixelsH
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: fps)
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = true
            cfg.queueDepth = 4
            cfg.capturesAudio = false

            let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
            try await s.startCapture()
            await MainActor.run {
                stream = s
                running = true
                starting = false
            }
            log("streaming \(pixelsW)x\(pixelsH) @\(fps) fps")
        } catch {
            log("capture failed: \(error.localizedDescription)")
            await MainActor.run { starting = false }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        // Idle/blank frames carry no new image; only complete frames are shown.
        guard let info = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb),
              let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [videoLayer] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.contents = surface
            CATransaction.commit()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped: \(error.localizedDescription)")
        DispatchQueue.main.async { [self] in
            stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.sync() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let streamer = Streamer()
    var statusItem: NSStatusItem?
    var pending: DispatchWorkItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "ipad", accessibilityDescription: "PortraitPad")
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit PortraitPad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item

        UserDefaults.standard.removeObject(forKey: "sidecarOrigin")   // older versions saved it; now always parked
        let cid = _CGSDefaultConnection()
        _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)

        // Touch forwarding posts events, which macOS only allows with Accessibility permission.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { log("Accessibility not granted yet; touch input disabled until it is") }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.scheduleSync() }
        streamer.sync()
    }

    // Screen changes arrive in bursts (including the ones we cause ourselves); act once they settle.
    func scheduleSync() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.streamer.sync() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func applicationWillTerminate(_ n: Notification) { streamer.stop() }
}

let touchTypes: Set<UInt> = [18, 19, 20, 29, 30, 31, 32, 37]

func describe(_ e: NSEvent) -> String {
    var s = "type=\(e.type.rawValue)"
    if let cg = e.cgEvent {
        s += " sub=\(cg.getIntegerValueField(.mouseEventSubtype)) at=(\(Int(cg.location.x)),\(Int(cg.location.y)))"
    }
    if e.type == .appKitDefined || e.type == .systemDefined { s += " subtype=\(e.subtype.rawValue) d1=\(e.data1) d2=\(e.data2)" }
    if touchTypes.contains(e.type.rawValue) { s += " touches=\(e.allTouches().count) phase=\(e.phase.rawValue)" }
    if e.type == .swipe { s += " swipe=(\(e.deltaX),\(e.deltaY))" }
    return s
}

func describeCurrentEvent() -> String {
    guard let e = NSApp.currentEvent else { return "current=none" }
    return "current: " + describe(e)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
signal(SIGTERM) { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
app.run()
