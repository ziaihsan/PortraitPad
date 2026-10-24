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
// events. One zero-delay press recognizer follows each touch: a short still touch clicks, a drag
// scrolls the content under the finger (with momentum on release). Everything else is left alone:
// multi-finger touches, and mouse/trackpad events on this hidden screen, so the real pointer is never
// thrown around.
final class InputView: NSView {
    var toPortrait: ((NSPoint) -> CGPoint?)?

    static let tapSlop: CGFloat = 10            // movement (pt) before a touch becomes a scroll
    static let tapMaxDuration = 0.5             // longer still touches are ignored, not clicked
    static let momentumDecay: CGFloat = 0.965   // per frame at 60 Hz
    static let momentumMinSpeed: CGFloat = 150  // pt/s to start a fling; it stops below 20 pt/s

    private let source = CGEventSource(stateID: .hidSystemState)
    private var touchStart = NSPoint.zero, touchStartTime = Date(), lastPoint = NSPoint.zero
    private var ignoring = false, scrolling = false, verticalLock = true
    private var remainder = CGVector.zero                       // sub-point scroll left to post
    private var samples: [(t: TimeInterval, d: CGVector)] = []  // recent scroll deltas, for fling speed
    private var momentum: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let touch = NSPressGestureRecognizer(target: self, action: #selector(track(_:)))
        touch.minimumPressDuration = 0
        touch.allowableMovement = .greatestFiniteMagnitude
        addGestureRecognizer(touch)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: touch tracking

    @objc private func track(_ g: NSPressGestureRecognizer) {
        let p = g.location(in: self)
        if debugInput { log("touch state=\(g.state.rawValue) at=(\(Int(p.x)),\(Int(p.y))) " + describeCurrentEvent()) }
        switch g.state {
        case .began:
            stopMomentum()
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
                pointCursor(at: touchStart)         // scroll events go to the window under the pointer
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

    private func isOneFinger() -> Bool {
        guard let e = NSApp.currentEvent, e.type == .directTouch else { return false }   // not a finger
        return e.allTouches().count == 1
    }

    private func endScroll(fling: Bool) {
        guard scrolling else { return }
        scrolling = false
        postScroll(.zero, phase: 4)                 // ended
        if fling { startMomentum(flingVelocity()) }
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

    // Modifier keys really held on the keyboard (Cmd-tap still works), nothing else.
    private func heldModifiers() -> CGEventFlags {
        CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
    }

    // Moves the pointer under the finger only when it isn't already over the window being touched,
    // so scrolling on the iPad usually leaves the pointer where it is.
    private func pointCursor(at viewPoint: NSPoint) {
        guard let p = toPortrait?(viewPoint), let here = CGEvent(source: nil)?.location else { return }
        if let target = windowNumber(at: p), target == windowNumber(at: here) { return }
        guard let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
        else { return }
        e.flags = heldModifiers()
        e.post(tap: .cghidEventTap)
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

    private func stopMomentum() {
        guard let timer = momentum else { return }
        timer.invalidate()
        momentum = nil
        postScroll(.zero, phase: 0, momentum: 3)
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
    private var lastPark: String?                      // last parking attempt, so a refused spot isn't retried

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
        guard let park = parkingSpot(vd: vdRect, sidecar: current.size), park != current.origin else { return }
        let attempt = "\(vdRect.origin) \(park)"
        guard lastPark != attempt else { return }          // macOS refused this spot already: don't loop
        lastPark = attempt
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
