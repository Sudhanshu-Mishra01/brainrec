# Testing BrainRec

Nothing in this project has been compiled or run yet. Do these steps in order and stop at the first failure.

## 0. Build
```bash
./build.sh
open BrainRec.app
```
Always start it with `open`. If you run the file inside the app from Terminal, macOS gives the Camera / Screen Recording
permission to **Terminal** instead of BrainRec and the test is meaningless.

To capture logs while testing:
```bash
touch /tmp/brainrec.log && open -W --stdout /tmp/brainrec.log --stderr /tmp/brainrec.log BrainRec.app
```
Build fails? Copy the first 5–10 lines starting with `error:` and send them over.
Crash on launch? Send the newest file in `~/Library/Logs/DiagnosticReports/` that starts with `BrainRec`.

Grant Camera, Microphone, Screen Recording → **quit and reopen** (or click *Relaunch BrainRec* in the Permissions section).

## 1. Functional checklist
| # | Test | Pass means |
|---|---|---|
| 1 | Launch | Camera preview is live, mic meter moves when you talk |
| 2 | Screen only (turn camera + mic off, 10 s) | `final .mp4` plays in QuickTime, ⌘I shows your native resolution |
| 3 | Camera + mic only (turn screen off, 10 s) | MP4 with your face and voice |
| 4 | Screen + camera + mic (30 s) | Bubble in the chosen corner, voice audible |
| 5 | Sync | Clap once while a stopwatch / flashing thing is on screen. Clap sound and flash line up |
| 6 | System audio | Music playing on the Mac is in the recording |
| 7 | Pause / resume | Paused part is cut out, audio and video still in sync after resume |
| 8 | Hotkeys | ⌃⌥R and ⌃⌥P work while another app is in front |
| 9 | Window mode | Only the chosen window is recorded |
| 10 | Re-render | Change corner / shape, click *Re-render* on a recent recording → new MP4 with the new layout |
| 11 | Long run: 15 min at 4K60 (H.264, High) | No crash, no growing memory, sync still correct at the end |
| 12 | Real-world | Upload to YouTube, open in your editor (CapCut / DaVinci / Premiere) |

Handy checks:
```bash
mdls -name kMDItemDurationSeconds -name kMDItemPixelWidth -name kMDItemPixelHeight "path/to/file.mp4"
```
With ffmpeg installed (`brew install ffmpeg`) you can see codec, frame rate and bitrate:
```bash
ffprobe -v error -show_entries stream=codec_name,width,height,r_frame_rate,bit_rate,codec_type -of compact "path/to/file.mp4"
```

## 2. Sandbox pass (do this before any App Store step)
```bash
SANDBOX=1 ./build.sh
open BrainRec.app
```
Repeat tests 1–4 and 10. Extra checks for the sandbox:
- Default save location is inside `~/Library/Containers/com.letscodebrain.brainrec/Data/Movies/BrainRec`
- Click **Choose…**, pick `~/Movies` → record → quit → reopen → the folder is still remembered and writable
- **Relaunch BrainRec** button restarts the app and ⌃⌥R works afterwards

Sandbox problems usually show up in Console.app (filter for `sandbox` or `BrainRec`) as `deny(1) file-write-create …`.

## 3. What to send back
For each failed test: the test number, what you expected, what happened, and any Terminal / Console lines.
