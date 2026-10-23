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
let vdOriginKey = "portraitOrigin", sidecarOriginKey = "sidecarOrigin"

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PortraitPad.log")
let logFile: FileHandle? = {
    if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
    let h = try? FileHandle(forWritingTo: logURL)
    h?.seekToEndOfFile()
    return h
}()

// Gesture debugging: `defaults write local.z.PortraitPad debugInput -bool true` logs each touch update and
// the gesture decisions; `debugEvents` additionally logs every system input event (heavy: it lags).
let debugInput = UserDefaults.standard.bool(forKey: "debugInput")
let debugEvents = UserDefaults.standard.bool(forKey: "debugEvents")

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

// Input that Sidecar delivers to its own (covered) screen, re-posted at the matching spot on the portrait
// display. Needs Accessibility permission to post events.
//
// Sidecar hands finger touches to AppKit gesture recognizers (as direct-touch events) rather than as
// mouse events. A zero-delay press recognizer tracks one-finger touches: a short still touch clicks, a
// drag scrolls the content under the finger (with momentum on release). It cancels when a second finger
// lands and never restarts, so a two-finger pan recognizer takes over: sideways switches Spaces /
// full-screen apps like the trackpad does, up and down scrolls.
final class InputView: NSView, NSGestureRecognizerDelegate {
    var toPortrait: ((NSPoint) -> CGPoint?)?

    static let tapSlop: CGFloat = 10            // movement (pt) before a touch becomes a scroll or swipe
    static let tapMaxDuration = 0.5             // longer still touches are ignored, not clicked
    static let multiTapWindow = 0.45, multiTapSlop: CGFloat = 30
    static let momentumDecay: CGFloat = 0.965   // per frame at 60 Hz
    static let momentumMinSpeed: CGFloat = 150  // pt/s to start a fling; it stops below 20 pt/s
    static let spaceSwipeDistance: CGFloat = 60 // pt sideways for a two-finger swipe to switch Spaces
    static let stallTimeout = 4.0               // s without updates mid-touch before tracking is reset

    private enum Mode { case undecided, scroll, spaceSwipe, ignored }

    private let source = CGEventSource(stateID: .hidSystemState)
    private var touchStart = NSPoint.zero, touchStartTime = Date(), lastPoint = NSPoint.zero
    private var mode = Mode.undecided, verticalLock = true, fingers = 1
    private var remainder = CGVector.zero                       // sub-point scroll left to post
    private var samples: [(t: TimeInterval, d: CGVector)] = []  // recent scroll deltas, for fling speed
    private var momentum: Timer?
    private var lastTap: (time: Date, at: NSPoint, count: Int64)?
    private var watchdog: DispatchWorkItem?
    private weak var active: NSGestureRecognizer?               // the recognizer that owns the current touch

    override init(frame: NSRect) {
        super.init(frame: frame)
        let touch = NSPressGestureRecognizer(target: self, action: #selector(trackOneFinger(_:)))
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

    @objc private func trackOneFinger(_ g: NSPressGestureRecognizer) { track(g, fingers: 1) }
    @objc private func trackTwoFingers(_ g: NSPanGestureRecognizer) { track(g, fingers: 2) }

    private func track(_ g: NSGestureRecognizer, fingers n: Int) {
        let p = g.location(in: self)
        if debugInput { log("touch[\(n)] state=\(g.state.rawValue) at=(\(Int(p.x)),\(Int(p.y))) " + describeCurrentEvent()) }
        if g.state != .began, g !== active { return }   // updates from a touch that was handed over
        armWatchdog(g)
        switch g.state {
        case .began:
            if active != nil, active !== g { abandonTouch() }   // a second finger landed: two-finger takes over
            active = g
            stopMomentum()
            fingers = max(n, touchCount())
            mode = .undecided
            touchStart = p
            lastPoint = p
            touchStartTime = Date()
            remainder = .zero
            samples = []
        case .changed:
            fingers = max(fingers, touchCount())
            if mode == .undecided, hypot(p.x - touchStart.x, p.y - touchStart.y) > Self.tapSlop { decideMode(at: p) }
            if mode == .scroll {
                let d = contentDelta(from: lastPoint, to: p)
                postScroll(d, phase: 2)             // changed
                samples.append((ProcessInfo.processInfo.systemUptime, d))
            }
            lastPoint = p
        case .ended, .cancelled:
            active = nil
            switch mode {
            case .scroll:
                postScroll(.zero, phase: 4)         // ended
                startMomentum(flingVelocity())
            case .spaceSwipe:
                finishSpaceSwipe()
            case .undecided:
                if g.state == .ended, fingers == 1, Date().timeIntervalSince(touchStartTime) <= Self.tapMaxDuration {
                    click(at: touchStart)
                }
            case .ignored:
                break
            }
            mode = .undecided
        default:
            break
        }
    }

    private func abandonTouch() {
        if mode == .scroll { postScroll(.zero, phase: 4) }
        mode = .undecided
        active = nil
    }

    // Once a touch has moved: two fingers sideways switch Spaces, three or more do nothing, anything else scrolls.
    private func decideMode(at p: NSPoint) {
        let d = contentDelta(from: touchStart, to: p)
        defer { if debugInput { log("decide fingers=\(fingers) sideways=\(Int(d.dx)) vertical=\(Int(d.dy)) -> \(mode)") } }
        if fingers >= 3 {
            mode = .ignored
        } else if fingers == 2, abs(d.dx) > abs(d.dy) {
            mode = .spaceSwipe
        } else {
            mode = .scroll
            verticalLock = abs(d.dy) >= abs(d.dx)
            moveCursor(to: touchStart)              // scroll events go to the window under the pointer
            postScroll(.zero, phase: 1)             // began
            lastPoint = touchStart                  // the slop distance scrolls too, so nothing jumps
        }
    }

    // Finger movement in this (landscape, y-up) view -> content movement on the portrait display.
    // The image is rotated +90°: portrait "down" is view +x, portrait "right" is view +y. Content follows
    // the finger; CGEvent scroll axis 1 is vertical (+ moves content down), axis 2 horizontal (+ right).
    private func contentDelta(from a: NSPoint, to b: NSPoint) -> CGVector {
        let d = CGVector(dx: b.y - a.y, dy: b.x - a.x)
        guard mode == .scroll else { return d }
        return verticalLock ? CGVector(dx: 0, dy: d.dy) : CGVector(dx: d.dx, dy: 0)
    }

    private func touchCount() -> Int {
        guard let e = NSApp.currentEvent, e.type == .directTouch else { return 1 }
        return e.allTouches().count
    }

    // Like the trackpad's "swipe between full-screen applications": fingers left shows the Space on the
    // right (Ctrl-→), fingers right the one on the left (Ctrl-←). Sent only after the fingers lift:
    // switching mid-touch left the touch unfinished and froze all touch input.
    private func finishSpaceSwipe() {
        let d = contentDelta(from: touchStart, to: lastPoint)
        if debugInput { log("space swipe sideways=\(Int(d.dx)) vertical=\(Int(d.dy))") }
        guard abs(d.dx) > Self.spaceSwipeDistance, abs(d.dx) > abs(d.dy) * 1.5,
              let target = toPortrait?(touchStart), let ipad = portraitBounds(),
              let home = CGEvent(source: nil)?.location else { return }
        let previous = NSWorkspace.shared.frontmostApplication
        // Space switching acts on the display under the pointer: park it on the iPad just long enough for
        // the Dock to read it (30 ms was enough in testing; 0 was not), then put it back where it was.
        CGWarpMouseCursorPosition(target)
        pressControlArrow(d.dx < 0 ? 124 : 123)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            CGWarpMouseCursorPosition(home)
            CGAssociateMouseAndMouseCursorPosition(1)   // no brief pointer freeze after the warp
        }
        // The new Space activates its own app. When the pointer was on another screen, keep the keyboard
        // where it was once the switch animation is done.
        if !ipad.contains(home), let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.restoreFocus(previous, ipad: ipad) }
        }
    }

    private func portraitBounds() -> CGRect? {
        guard let a = toPortrait?(.zero), let b = toPortrait?(NSPoint(x: bounds.width, y: bounds.height)) else { return nil }
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    // Re-activates `app` only while one of its windows is still visible off the iPad, so this never pulls
    // the iPad back to the Space just left. Via Accessibility: a background app may not activate others.
    private func restoreFocus(_ app: NSRunningApplication, ipad: CGRect) {
        guard NSWorkspace.shared.frontmostApplication != app else { return }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let visibleElsewhere = windows.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict) else { return false }
            return !ipad.contains(CGPoint(x: r.midX, y: r.midY))
        }
        guard visibleElsewhere else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                     kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    // If a touch never reports an end (e.g. the system took over mid-gesture), the recognizer would ignore
    // every later touch; resetting it ends the stuck touch (the action gets .cancelled) and frees it.
    private func armWatchdog(_ g: NSGestureRecognizer) {
        watchdog?.cancel()
        watchdog = nil
        guard g.state == .began || g.state == .changed else { return }
        let w = DispatchWorkItem { [weak g] in
            guard let g, g.state == .began || g.state == .changed else { return }
            log("touch tracking stalled; resetting")
            g.isEnabled = false
            g.isEnabled = true
        }
        watchdog = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stallTimeout, execute: w)
    }

    // MARK: posting

    // Arrow keys carry the fn and numeric-pad flags on a real keyboard; the Mission Control hotkeys match on them.
    private func pressControlArrow(_ keyCode: CGKeyCode) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            e.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
            e.post(tap: .cghidEventTap)
        }
    }

    private func moveCursor(to viewPoint: NSPoint) {
        guard let p = toPortrait?(viewPoint) else { return }
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private func click(at viewPoint: NSPoint) {
        guard let p = toPortrait?(viewPoint) else { return }
        let now = Date()
        var count: Int64 = 1
        if let last = lastTap, now.timeIntervalSince(last.time) < Self.multiTapWindow,
           hypot(viewPoint.x - last.at.x, viewPoint.y - last.at.y) < Self.multiTapSlop {
            count = min(last.count + 1, 3)          // double-tap selects a word, triple a line
        }
        lastTap = (now, viewPoint, count)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            else { continue }
            if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: count) }
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
        RunLoop.main.add(timer, forMode: .common)   // keeps running while AppKit tracks a new gesture
        momentum = timer
    }

    private func stopMomentum() {
        guard let timer = momentum else { return }
        timer.invalidate()
        momentum = nil
        postScroll(.zero, phase: 0, momentum: 3)
    }

    // MARK: trackpad/mouse that wanders onto the Sidecar screen

    // The pointer jumps to the matching spot on the portrait display.
    override func mouseMoved(with e: NSEvent) {
        guard let cg = e.cgEvent?.copy(), let p = toPortrait?(e.locationInWindow) else { return }
        cg.location = p
        cg.post(tap: .cghidEventTap)
    }

    // Two-finger trackpad scroll: axes turn with the image (see contentDelta).
    override func scrollWheel(with e: NSEvent) {
        guard let cg = e.cgEvent?.copy(), let p = toPortrait?(e.locationInWindow) else { return }
        cg.location = p
        let pairs: [(CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
            (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2),
        ]
        for (v, h) in pairs {
            let lv = cg.getIntegerValueField(v), lh = cg.getIntegerValueField(h)
            cg.setIntegerValueField(v, value: lh)
            cg.setIntegerValueField(h, value: -lv)
        }
        let fv = cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fh = cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fh)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fv)
        cg.post(tap: .cghidEventTap)
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
            saveArrangement(sidecar: displayID(of: sidecar))
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

    // Restores the arrangement last set in System Settings ▸ Displays ▸ Arrange (origins relative to
    // the main display). First run: portrait display directly above the Mac, the real Sidecar desktop
    // parked beside it, not touching the Mac, so the pointer can't stray there.
    private func arrange(vd: CGDirectDisplayID, sidecar: CGDirectDisplayID) {
        let main = CGDisplayBounds(CGMainDisplayID())
        let vdOrigin: (Int32, Int32), scOrigin: (Int32, Int32)
        if let v = savedOrigin(vdOriginKey), let s = savedOrigin(sidecarOriginKey) {
            vdOrigin = v
            scOrigin = s
        } else {
            let vdX = Int32(main.midX) - Int32(pointsW / 2), vdY = Int32(main.minY) - Int32(pointsH)
            vdOrigin = (vdX, vdY)
            scOrigin = (vdX - Int32(CGDisplayBounds(sidecar).width), vdY)
        }
        var cfg: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cfg)
        CGConfigureDisplayOrigin(cfg, vd, vdOrigin.0, vdOrigin.1)
        CGConfigureDisplayOrigin(cfg, sidecar, scOrigin.0, scOrigin.1)
        CGCompleteDisplayConfiguration(cfg, .forSession)
        log("arranged: portrait at \(vdOrigin), sidecar at \(scOrigin)")
    }

    // Called once screen changes settle while streaming, so whatever the user dragged last becomes the default.
    private func saveArrangement(sidecar: CGDirectDisplayID) {
        guard let vd = virtualDisplay?.displayID else { return }
        let v = CGDisplayBounds(vd).origin, s = CGDisplayBounds(sidecar).origin
        let d = UserDefaults.standard
        let newV = [Int(v.x), Int(v.y)], newS = [Int(s.x), Int(s.y)]
        guard d.array(forKey: vdOriginKey) as? [Int] != newV || d.array(forKey: sidecarOriginKey) as? [Int] != newS else { return }
        d.set(newV, forKey: vdOriginKey)
        d.set(newS, forKey: sidecarOriginKey)
        log("saved arrangement: portrait at \(newV), sidecar at \(newS)")
    }

    private func savedOrigin(_ key: String) -> (Int32, Int32)? {
        guard let a = UserDefaults.standard.array(forKey: key) as? [Int], a.count == 2 else { return nil }
        return (Int32(a[0]), Int32(a[1]))
    }

    // MARK: output window on the Sidecar screen

    private func showWindow(on sidecar: NSScreen) {
        // Non-activating panel: touches/Pencil land here without stealing focus from the app being used.
        let w = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.acceptsMouseMovedEvents = true
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

        // Touch forwarding posts events, which macOS only allows with Accessibility permission.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { log("Accessibility not granted yet; touch input disabled until it is") }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.scheduleSync() }
        streamer.sync()
        if debugEvents { startInputDebugging() }
    }

    // Screen changes arrive in bursts (including the ones we cause ourselves); act once they settle.
    func scheduleSync() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.streamer.sync() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func applicationWillTerminate(_ n: Notification) { streamer.stop() }

    var debugTap: CFMachPort?

    func startInputDebugging() {
        log("input debugging on")
        _ = NSEvent.addLocalMonitorForEvents(matching: .any) { e in
            if e.type != .mouseMoved { log("local event " + describe(e)) }
            return e
        }
        // Keys anyone posts (does Sidecar turn a 3-finger swipe into Cmd-Z?) and gesture/swipe events.
        let cb: CGEventTapCallBack = { _, type, e, _ in
            if [10, 11, 12, 29, 30, 31].contains(type.rawValue) {
                log("tap type=\(type.rawValue) key=\(e.getIntegerValueField(.keyboardEventKeycode)) flags=\(String(e.flags.rawValue, radix: 16)) pid=\(e.getIntegerValueField(.eventSourceUnixProcessID)) at=(\(Int(e.location.x)),\(Int(e.location.y)))")
            }
            return Unmanaged.passUnretained(e)
        }
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                       eventsOfInterest: CGEventMask.max, callback: cb, userInfo: nil) {
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            debugTap = tap
        } else {
            log("debug event tap unavailable")
        }
    }
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
