# Publishing BrainRec on the Mac App Store — end to end

Do **docs/TESTING.md** first, including the sandbox pass. Do not start here until tests 1–10 pass.

What is already prepared in this repo: sandbox entitlements, `Info.plist` with permission texts and encryption flag,
placeholder app icon, XcodeGen project file, listing text (below), privacy policy (`docs/PRIVACY_POLICY.md`).
What only you can do: Apple account, signing, screenshots, hosting two web pages, clicking Submit.

---

## Step 1 — Apple Developer Program (day 1)
1. Go to developer.apple.com/programs/enroll and enroll as an **Individual** (needs an Apple ID with two-factor auth; $99 per year).
2. Wait for approval (hours to ~2 days).
3. If you plan to charge money later, also finish *App Store Connect → Business (Agreements, Tax, and Banking)*. Free apps skip this.

## Step 2 — Generate the Xcode project
```bash
brew install xcodegen
cd BrainRec
xcodegen generate
open BrainRec.xcodeproj
```
In Xcode:
1. Click the project → target **BrainRec** → **Signing & Capabilities**.
2. Tick **Automatically manage signing**, choose your **Team**.
3. Confirm these show up: **App Sandbox** with *Camera*, *Audio Input*, *User Selected File: Read/Write*. (They come from `Resources/BrainRec-AppStore.entitlements`.)
4. **General** tab: Version `1.0`, Build `1`, Minimum deployment `macOS 14.0`, Category *Video*.
5. Press ⌘R once to check it runs. If you get build errors, send them over.

Bundle ID is `com.letscodebrain.brainrec`. Change it in `project.yml` if you want another one, and use the same one in App Store Connect. It cannot be changed after you create the app record.

## Step 3 — Publish two web pages
- **Privacy policy**: put `docs/PRIVACY_POLICY.md` on letscodebrain.com (fill the bracketed items). Needed URL.
- **Support page**: any page with your support email / contact form. Needed URL.

## Step 4 — Create the app in App Store Connect
appstoreconnect.apple.com → **Apps → + → New App**
- Platforms: **macOS**
- Name: `BrainRec` (if it is taken, try `BrainRec Recorder` or `BrainRec – Screen & Face`)
- Primary language: English (U.S.)
- Bundle ID: `com.letscodebrain.brainrec` (appears after Xcode has registered it in step 2/6; if not, create it at developer.apple.com → Certificates, Identifiers & Profiles → Identifiers)
- SKU: `brainrec-mac-1` (any unique text)

Then fill the **App Information** and **version 1.0** pages with the text in "Listing copy" below.

## Step 5 — Screenshots
Mac screenshots must be one of: 1280×800, 1440×900, 2560×1600, 2880×1800. Upload 1–10, 3–5 is a good number. Suggestions:
1. Main window with the camera preview and a big Start button
2. A finished video: screen with the circular camera bubble
3. Layout settings (corner, shape, size)
4. Quality settings with the bitrate estimate
5. Menu bar control while recording

On a Retina Mac, take them with ⌘⇧5 and resize to 2880×1800 (Preview → Tools → Adjust Size). Do not show other people's faces,
private data or other brands' logos.

## Step 6 — Archive and upload
1. In Xcode choose destination **Any Mac (Apple Silicon, Intel)** (top bar).
2. **Product → Archive**.
3. In the Organizer window: select the archive → **Distribute App → App Store Connect → Upload**, keep the defaults (automatic signing). Xcode creates the *Apple Distribution* and *Mac Installer Distribution* certificates for you.
4. Wait 10–30 minutes. The build appears in App Store Connect under **TestFlight** and on the version page, after Apple's processing e-mail.
5. Apple regularly raises the minimum Xcode version for uploads. If the upload is rejected for the SDK, update Xcode and archive again.

## Step 7 — TestFlight (test the real, signed, sandboxed build)
1. App Store Connect → your app → **TestFlight** → add yourself under **Internal Testing**.
2. Install **TestFlight** from the Mac App Store, accept the invite, install BrainRec.
3. Re-run tests 1–10 from `docs/TESTING.md`. Internal testing needs no Apple review.
4. Anything broken → fix, raise the **Build** number (it must be higher for every upload), archive and upload again.

## Step 8 — Fill in the rest and submit
On the **1.0** version page:
- Select the build you tested
- Screenshots, description, keywords, promotional text, support URL (below)
- **Copyright**: `2026 Let's Code Brain`
- **App Review Information**: no sign-in needed; paste the review notes below; add your phone and e-mail

Other pages:
- **App Privacy** → Get Started → **Data Not Collected** → Publish. Privacy policy URL: your page from step 3.
- **Age Rating**: answer **None** to every question → lowest rating.
- **Pricing and Availability**: Free (or pick a price). Availability: all countries.
- **Content Rights**: "does not contain, show or access third-party content".
- **Export compliance**: no questions appear because `ITSAppUsesNonExemptEncryption` is `NO` in `Info.plist`.
- **Version release**: choose *Manually release* so you control the launch day.

Click **Add for Review → Submit for Review**. First reviews usually take 1–3 days.

## Step 9 — If rejected
Read the message in the *Resolution Center*, fix the exact point, upload a new build if code changed (or just reply if it was a metadata/notes issue),
and resubmit. Most likely causes for this kind of app:
- **2.1 App Completeness**: reviewer saw a black screen video because Screen Recording needs a relaunch → the review notes and the *Relaunch BrainRec* button cover this.
- **2.4.5 Mac App Store requirements**: app not sandboxed → build must use `BrainRec-AppStore.entitlements`.
- **2.3 Accurate Metadata**: screenshots or text show features the app does not have. Keep the description honest.
- **4.3 Spam / copycat** or name in use: pick a distinct name and screenshots.
- **5.1.1 Privacy**: missing or wrong privacy policy URL.

## Step 10 — After approval
Release it (or it releases automatically). For every update: change **Version** (e.g. 1.0.1) and **Build** (+1) in `project.yml`
(or in Xcode), run `xcodegen generate` if you edited it, then Archive → Upload → TestFlight → Submit again.

---

# Listing copy (paste into App Store Connect)

**Name** (max 30): `BrainRec`

**Subtitle** (max 30): `Record screen and face to MP4`

**Promotional text** (max 170):
```
Record your screen and your face at the same time, in full quality. One click, one MP4 file, ready for YouTube, Shorts and your courses.
```

**Keywords** (max 100, comma separated, no spaces after commas):
```
webcam,facecam,capture,tutorial,video,picture in picture,youtuber,teacher,lesson,demo,course,creator
```

**Category:** Primary *Video*, secondary *Productivity*

**Description** (max 4000):
```
BrainRec records your screen and your face camera at the same time and gives you one clean MP4 file.

Made for teachers, YouTubers, course creators and developers who record tutorials, lessons and demos.

RECORD EVERYTHING AT ONCE
• Full display or a single window, in native Retina quality, at 30 or 60 fps
• Your camera next to the screen: built-in, USB or iPhone camera, up to 4K
• Your microphone, plus optional system audio
• Pause and resume without breaking sync

HIGH QUALITY, REAL MP4
• Hardware-accelerated H.264 or HEVC, with Balanced, High and Maximum quality
• One final MP4 with your camera bubble on the screen, mixed audio and a constant frame rate that edits cleanly in Final Cut, Premiere, DaVinci Resolve and CapCut
• Raw screen and camera files are saved too, so you can change the layout later

YOUR CAMERA, YOUR WAY
• Circle, rounded or rectangle bubble in any corner
• Adjustable size, border, shadow and mirror
• Floating camera preview while you record, which never appears in the recording

BUILT FOR FLOW
• Menu bar control and global hotkeys: Control-Option-R to start or stop, Control-Option-P to pause
• Countdown before recording starts
• Live microphone level meter

PRIVATE BY DESIGN
BrainRec has no account, no ads, no analytics and no internet access. Everything is recorded and saved on your Mac.

Requires macOS 14 or later. BrainRec asks for Camera, Microphone and Screen Recording permission the first time you use each feature.
```
> Only list features that really work after your tests. Remove any line that failed testing (for example 4K or 60 fps camera if your camera cannot do it).

**App Review notes:**
```
No account or sign-in is needed.

BrainRec records the screen, the camera and the microphone, so macOS asks for three permissions on first use:
Camera, Microphone, and Screen & System Audio Recording.
IMPORTANT: after allowing Screen Recording in System Settings, macOS applies it on the next launch.
Please click "Relaunch BrainRec" (Permissions section, right side of the main window) or quit and reopen the app once.

To test:
1. Allow the three permissions and relaunch.
2. Click "Start Recording" (3-second countdown), wait about 10 seconds, click "Stop".
3. The app renders the final MP4 (progress bar), then "Saved" appears with Play / Show in Finder buttons.
   Files are saved to the app's default folder, or to the folder chosen with "Choose…" in the Output section.

The app does not use the network and collects no data. Global hotkeys (Control-Option-R / Control-Option-P) are optional conveniences.
```

**Support URL / Marketing URL:** your pages from step 3.
