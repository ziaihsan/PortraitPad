# PortraitPad

PortraitPad lets you use an iPad connected with Sidecar as a portrait (upright) display for your Mac,
and you can still tap and scroll on it with your finger.

macOS cannot rotate a Sidecar display. BetterDisplay can work around this, but the feature is paid.
PortraitPad does this one job for free, in a single small menu bar app.

Tested on macOS 27.0.1 and 27.2.1 with a MacBook Air (M1) and a 12.9-inch iPad Pro (M1).

PortraitPad is an unofficial project and is not affiliated with Apple. It uses private macOS APIs,
so a macOS update can break it.

## What it does

- Adds a portrait display called "PortraitPad" to your Mac and shows it on the iPad, rotated so it
  reads correctly when you hold the iPad upright.
- Starts by itself when Sidecar connects and stops when Sidecar disconnects.
- Remembers where you put the portrait display in System Settings ▸ Displays ▸ Arrange.
- Keeps the real Sidecar screen (hidden behind the picture) parked in the far corner of the iPad
  screen, so your pointer does not get lost on it. If something moves it back, for example System
  Settings when you close Arrange, PortraitPad parks it again.
- Uses very little power: about 0.5 to 0.7% CPU and 15 to 30 MB of memory when the screen is still.

## Touch gestures on the iPad

| Gesture | Result |
|---|---|
| Tap with one finger | Left click at that spot |
| Drag one finger (right away, or after holding) | Scroll that follows your finger, with momentum |
| Swipe two fingers left or right, then lift | Switch Space or full-screen app on the iPad display (Ctrl+→ / Ctrl+←) |
| Any other two-finger gesture, or three or more fingers | Ignored |

Your trackpad and mouse work exactly as before.

Scrolling does not move your pointer. macOS sends scroll events to the window under the pointer,
and Electron apps such as Claude ignore scroll events sent to them directly. So when the pointer is
somewhere else, PortraitPad borrows it: it hides the pointer, moves it under your finger, and puts it
back when the scroll and its momentum end. If you touch the trackpad in the meantime, you get the
pointer back at once and the scroll stops. A two-finger swipe borrows the pointer the same way for
150 ms, because macOS switches the Space on the display that has the pointer.

Sidecar delivers finger touches to AppKit gesture recognizers as `directTouch` events, not as mouse
events. The comments in `InputView` (`Sources/main.swift`) explain how PortraitPad handles them.

## Requirements

- A Mac with macOS 14 or later.
- An iPad that supports Sidecar.
- Command Line Tools with Swift 6.x (`xcode-select --install`). You do not need Xcode.

## Install

```bash
git clone https://github.com/ziaihsan/PortraitPad.git
cd PortraitPad
./build.sh
cp -R build/PortraitPad.app ~/Applications/
```

Then open PortraitPad from Spotlight and connect your iPad with Sidecar.

[SETUP.md](SETUP.md) has the full steps: permissions, a signing certificate so you do not have to
grant permissions again after every build, and what to check when something does not work.

PortraitPad needs two permissions, both in System Settings ▸ Privacy & Security:

- Screen & System Audio Recording, to capture the portrait display.
- Accessibility, to turn your taps, scrolls, and swipes into clicks and key presses.

To start PortraitPad automatically when you log in, add `~/Applications/PortraitPad.app` in System
Settings ▸ General ▸ Login Items. It does not do this by itself.

## Versions

- `main` has portrait display, tap to click, one-finger scrolling, and two-finger swipes to switch
  Spaces.
- Tag `v1-konservatif` is a more conservative version without the two-finger swipe, so it never
  sends the Control key. If swipes cause problems, build that version instead:

  ```bash
  git checkout v1-konservatif && ./build.sh
  ```

## How it works

```
virtual display "PortraitPad", 984×1312 pt, HiDPI, 60 Hz   (CGVirtualDisplay, private API)
  → captured with ScreenCaptureKit (IOSurface frames, only when the content changes)
  → shown on a CALayer rotated +90° in a window that covers the Sidecar screen
```

Frames go straight from ScreenCaptureKit to Core Animation, with no pixel copies on the CPU.

## Debugging

```bash
defaults write local.z.PortraitPad debugInput -bool true    # log every touch
tail -f ~/Library/Logs/PortraitPad.log
```

To turn it off, run `defaults delete local.z.PortraitPad debugInput` and restart the app.

`Tools/eventprobe.swift` is a separate tool for finding out what Sidecar actually sends for each
finger gesture. It shows instructions upright on the iPad and logs every event:

```bash
swiftc -O Tools/eventprobe.swift -o build/eventprobe
build/eventprobe --cursortest > probe.log    # also: --passive, --level=N
```

## Limitations

- The portrait size is fixed at 984×1312 points, which matches the 3:4 screen of the 12.9-inch iPad
  Pro. On an iPad with a different shape the picture is stretched a little. To change it, edit
  `pointsW` and `pointsH` at the top of `Sources/main.swift`.
- The rotation direction is fixed: the top of the picture is on the left edge of the iPad when it
  is held in landscape.
- Apple limits Sidecar to 60 Hz, so ProMotion (120 Hz) does not work this way.
- `CGVirtualDisplay` and the `SetsCursorInBackground` property (used to hide the pointer while
  PortraitPad borrows it) are private APIs. They still work on macOS 27.
- The real Sidecar desktop still exists behind the picture. A window dragged onto it is hidden.
