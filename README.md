# BrainRec

Native macOS recorder: **screen + face camera + mic (+ system audio) at the same time**, saved as a normal **MP4**.
Swift, ScreenCaptureKit, AVFoundation, hardware H.264/HEVC encoding. No ffmpeg, no browser capture, no WebM.

> **Status:** written without access to a Mac. It has been syntax-checked (parses clean) but **not compiled and not run**.
> Expect a few compile or runtime fixes on first build. See "If the build fails" below.

## Requirements
- macOS 14 (Sonoma) or newer, Apple Silicon recommended
- Xcode 15+ (or just the Command Line Tools: `xcode-select --install`)

## Build and run
```bash
cd BrainRec
chmod +x build.sh
./build.sh
open BrainRec.app
```
First launch asks for **Camera**, **Microphone** and **Screen Recording**. After you allow Screen Recording,
**quit and reopen the app** once (macOS only applies it on the next launch).

### Keep permissions across rebuilds (recommended)
With the default ad-hoc signature, macOS treats every rebuild as a new app and asks again.
Make a free self-signed certificate once: *Keychain Access → Certificate Assistant → Create a Certificate…*
(name `BrainRec Dev`, type **Code Signing**). Then:
```bash
SIGN_ID="BrainRec Dev" ./build.sh
```

## Testing and publishing
| Doc | What it is |
|---|---|
| [`docs/TESTING.md`](docs/TESTING.md) | 12-point test checklist + the sandbox pass. Do this first |
| [`docs/APP_STORE.md`](docs/APP_STORE.md) | Mac App Store, step by step, with copy-paste listing text and review notes |
| [`docs/PRIVACY_POLICY.md`](docs/PRIVACY_POLICY.md) | Privacy policy to host on your website (required by the App Store) |

Build variants:
```bash
./build.sh              # dev build, not sandboxed (use for first tests)
SANDBOX=1 ./build.sh    # same entitlements as the App Store build
```
For the App Store itself: `xcodegen generate`, then archive in Xcode (see `docs/APP_STORE.md`).

## What you get per recording
```
~/Movies/BrainRec/BrainRec 2026-11-01 14.30.05/
├── BrainRec 2026-11-01 14.30.05.mp4   ← final video: screen + camera bubble + mixed audio
└── raw/
    ├── screen.mp4    screen (+ system audio)
    ├── camera.mp4    camera (+ mic)
    └── mic.m4a       only when the camera is off
```
Raw files are kept by default so you can **Re-render** later with a different bubble position/size/shape.

## Features
- Full display or single window, native Retina pixels, 30 / 60 fps, cursor on/off
- Camera picker (built-in, USB, iPhone Continuity Camera), 720p / 1080p / 4K, 30 / 60 fps
- Mic picker with live level meter, optional system audio, separate volume for each
- H.264 (most compatible) or HEVC (smaller), Balanced / High / Maximum bitrate, size estimate shown in the UI
- Final video: camera bubble as circle / rounded / rectangle, any corner, size slider, border, shadow, mirror
- Final video is **constant frame rate** (edits cleanly in Premiere / DaVinci / CapCut)
- Screen + camera + mic are on one shared clock, so they stay in sync; pause/resume cuts the paused time out of every file
- Floating camera preview while recording (never appears in the screen recording), countdown HUD
- Menu bar item + global hotkeys: **⌃⌥R** start/stop, **⌃⌥P** pause/resume
- Disk-space check before start; if rendering fails, the raw files are still saved
- No camera? The screen video is copied without re-encoding and only the audio is mixed (no quality loss)

## Quality notes
| Setting | 1080p60 | 1440p60 | 4K60 (H.264) |
|---|---|---|---|
| Balanced | ~9 Mbps | ~15 Mbps | ~35 Mbps |
| High (default) | ~15 Mbps | ~27 Mbps | ~60 Mbps |
| Maximum | ~25 Mbps | ~44 Mbps | ~100 Mbps |

HEVC uses about 40% less. H.264 hardware encoding tops out at 4096×2304, so a 5K/6K display is scaled down
automatically with H.264; pick HEVC to keep full 5K/6K.
The final video is encoded a second time from the raw files. At these bitrates the loss is not visible.

## Not included (yet)
- Region/area selection (full display or one window only)
- Mouse-click highlights, keystroke overlay, drawing tools
- Crash-safe (fragmented) raw files: if the app crashes mid-recording, that recording is lost
- Editable hotkeys (they are constants in `HotKey.swift`)

## If the build fails
Send the first 5–10 error lines from `swift build` back and they can be fixed quickly. The most likely spots, since
nothing was compiled: Carbon hotkey calls in `HotKey.swift`, ScreenCaptureKit config in `ScreenCapture.swift`,
Core Image calls in `Compositor.swift`.

## Troubleshooting
- **Black or empty screen video** → Screen Recording not granted, or you did not reopen the app after granting. Check *System Settings → Privacy & Security → Screen & System Audio Recording*.
- **Permission asked again after every rebuild** → use the self-signed certificate above.
- **No camera preview** → Camera permission, or another app is using the camera.
- **Hotkey does nothing** → another app owns ⌃⌥R; change the key in `HotKey.swift`.

## Code map
| File | Job |
|---|---|
| `AppModel.swift` | state machine: countdown → record → pause → stop → render, permissions, devices, recents |
| `ScreenCapture.swift` | ScreenCaptureKit stream (screen + system audio) |
| `CameraMicCapture.swift` | AVCaptureSession for camera + mic, format picker, mic meter |
| `RecordingClock.swift` | one shared timeline, pause handling |
| `TrackWriter.swift` | hardware-encoded MP4/M4A writer for one source |
| `Compositor.swift` | builds the final MP4 (bubble, mask, border, shadow, audio mix) |
| `Overlays.swift` | preview view, floating camera, countdown HUD, permission links |
| `Views.swift`, `BrainRecApp.swift` | SwiftUI window and menu bar |
| `Resources/BrainRec-AppStore.entitlements` | App Sandbox + camera + mic + user-selected folder |
| `Resources/Assets.xcassets` | placeholder app icon (replace with your own design before launch) |
| `project.yml` | XcodeGen spec that generates the Xcode project for archiving |
