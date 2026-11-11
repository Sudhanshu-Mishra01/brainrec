import AVFoundation
import AppKit
import CoreGraphics
import ScreenCaptureKit
import SwiftUI

enum RecState: Equatable {
    case idle
    case countdown(Int)
    case starting
    case recording
    case paused
    case finishing
    case compositing(Double)
}

struct DeviceInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

struct DisplayInfo: Identifiable, Hashable {
    let id: UInt32
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
}

struct WindowInfo: Identifiable, Hashable {
    let id: UInt32
    let title: String
}

struct RecordingItem: Identifiable, Hashable {
    let folder: URL
    let finalURL: URL?
    let date: Date
    let hasRaw: Bool
    var id: URL { folder }
    var name: String { folder.lastPathComponent }
}

/// Everything that exists only while a recording is running.
private final class ActiveSession {
    let clock = RecordingClock()
    let folder: URL
    let rawDir: URL
    var screenWriter: TrackWriter?
    var cameraWriter: TrackWriter?
    var micWriter: TrackWriter?
    var screenFPS = 60

    init(folder: URL, rawDir: URL) {
        self.folder = folder
        self.rawDir = rawDir
    }

    var finalURL: URL { folder.appendingPathComponent("\(folder.lastPathComponent).mp4") }
}

@MainActor
final class AppModel: ObservableObject {
    // MARK: Published state

    @Published var settings: RecorderSettings {
        didSet { settingsDidChange(old: oldValue) }
    }
    @Published private(set) var state: RecState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var windows: [WindowInfo] = []
    @Published private(set) var cameras: [DeviceInfo] = []
    @Published private(set) var microphones: [DeviceInfo] = []
    @Published private(set) var recents: [RecordingItem] = []
    @Published private(set) var lastResult: RecordingItem?
    @Published private(set) var captureInfo = CaptureInfo()
    @Published private(set) var screenPermission = false
    @Published private(set) var cameraPermission = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var errorMessage: String?

    // MARK: Collaborators

    let capture = CameraMicCapture()
    private let screen = ScreenCapture()
    private let floatingCamera = FloatingCameraController()
    private let countdownHUD = CountdownHUD()
    private var active: ActiveSession?
    private var ticker: Timer?
    /// Output folder the user picked, kept open for the whole run (needed inside the App Sandbox).
    private var scopedFolderURL: URL?

    private static let settingsKey = "brainrec.settings.v1"
    private static let bookmarkKey = "brainrec.outputFolderBookmark.v1"
    private static let folderStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    // MARK: Derived

    var isBusy: Bool { state != .idle }
    var isRecordingActive: Bool { state == .recording || state == .paused }

    var elapsedString: String {
        let s = Int(elapsed)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    var estimateText: String {
        var parts: [String] = []
        if settings.captureScreen {
            let display = displays.first(where: { $0.id == settings.displayID }) ?? displays.first
            if settings.captureMode == .display, let d = display {
                let size = settings.codec.fit(width: d.pixelWidth, height: d.pixelHeight)
                let bps = settings.bitrate(width: size.width, height: size.height, fps: settings.screenFPS)
                parts.append("Screen \(size.width)×\(size.height) @ \(settings.screenFPS) fps ≈ \(bps / 1_000_000) Mbps")
            } else {
                parts.append("Screen @ \(settings.screenFPS) fps")
            }
        }
        if settings.cameraEnabled, captureInfo.hasCamera {
            let bps = settings.bitrate(width: captureInfo.cameraWidth, height: captureInfo.cameraHeight, fps: captureInfo.cameraFPS)
            parts.append("Camera \(captureInfo.cameraWidth)×\(captureInfo.cameraHeight) @ \(captureInfo.cameraFPS) fps ≈ \(bps / 1_000_000) Mbps")
        }
        return parts.joined(separator: "\n")
    }

    // MARK: Init

    init() {
        var loaded = Self.loadSettings()
        if loaded.outputFolder.isEmpty {
            loaded.outputFolder = (NSHomeDirectory() as NSString).appendingPathComponent("Movies/BrainRec")
        }
        settings = loaded

        HotKeyCenter.shared.handler = { [weak self] id in
            Task { @MainActor in self?.handleHotKey(id) }
        }
        HotKeyCenter.shared.register()

        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        let center = NotificationCenter.default
        center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices() }
        }
        center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices() }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }

        Task { await bootstrap() }
    }

    private func bootstrap() async {
        restoreOutputFolderAccess()
        refreshPermissions()
        await requestAVPermissionsIfNeeded()
        refreshDevices()
        await refreshScreenSources()
        await reconfigureCapture()
        refreshRecents()
    }

    // MARK: Settings persistence

    private static func loadSettings() -> RecorderSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode(RecorderSettings.self, from: data) else {
            return RecorderSettings()
        }
        return decoded
    }

    private func settingsDidChange(old: RecorderSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        guard state == .idle else { return }

        let cameraChanged = old.cameraEnabled != settings.cameraEnabled
            || old.cameraID != settings.cameraID
            || old.cameraResolution != settings.cameraResolution
            || old.cameraFPS != settings.cameraFPS
        let micChanged = old.micEnabled != settings.micEnabled || old.micID != settings.micID
        if cameraChanged || micChanged {
            Task {
                await requestAVPermissionsIfNeeded()
                await reconfigureCapture()
            }
        }
        if old.captureMode != settings.captureMode {
            Task { await refreshScreenSources() }
        }
        if old.outputFolder != settings.outputFolder {
            refreshRecents()
        }
    }

    // MARK: Permissions & devices

    func refreshPermissions() {
        screenPermission = CGPreflightScreenCaptureAccess()
        cameraPermission = AVCaptureDevice.authorizationStatus(for: .video)
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private func requestAVPermissionsIfNeeded() async {
        if settings.cameraEnabled, AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        if settings.micEnabled, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        refreshPermissions()
    }

    func refreshDevices() {
        cameras = CameraMicCapture.cameras().map { DeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
        microphones = CameraMicCapture.microphones().map { DeviceInfo(id: $0.uniqueID, name: $0.localizedName) }

        if !cameras.contains(where: { $0.id == settings.cameraID }) {
            let fallback = AVCaptureDevice.default(for: .video)?.uniqueID ?? cameras.first?.id ?? ""
            if settings.cameraID != fallback { settings.cameraID = fallback }
        }
        if !microphones.contains(where: { $0.id == settings.micID }) {
            let fallback = AVCaptureDevice.default(for: .audio)?.uniqueID ?? microphones.first?.id ?? ""
            if settings.micID != fallback { settings.micID = fallback }
        }
    }

    func refreshScreenSources() async {
        screenPermission = CGPreflightScreenCaptureAccess()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let ourBundle = Bundle.main.bundleIdentifier

            displays = content.displays.map { d -> DisplayInfo in
                let mode = CGDisplayCopyDisplayMode(d.displayID)
                let pw = mode?.pixelWidth ?? d.width
                let ph = mode?.pixelHeight ?? d.height
                let screenName = NSScreen.screens.first {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.displayID
                }?.localizedName ?? "Display \(d.displayID)"
                return DisplayInfo(id: d.displayID, name: "\(screenName) (\(pw)×\(ph))", pixelWidth: pw, pixelHeight: ph)
            }

            windows = content.windows
                .filter { w in
                    w.isOnScreen && w.windowLayer == 0 && w.frame.width > 120 && w.frame.height > 80
                        && (w.title ?? "").isEmpty == false
                        && w.owningApplication != nil
                        && w.owningApplication?.bundleIdentifier != ourBundle
                }
                .map { w -> WindowInfo in
                    let app = w.owningApplication?.applicationName ?? "App"
                    return WindowInfo(id: w.windowID, title: "\(app) — \(w.title ?? "")")
                }
                .sorted { $0.title < $1.title }

            screenPermission = true
            if !displays.contains(where: { $0.id == settings.displayID }) {
                settings.displayID = displays.first?.id ?? 0
            }
            if !windows.contains(where: { $0.id == settings.windowID }) {
                settings.windowID = windows.first?.id ?? 0
            }
        } catch {
            screenPermission = false
        }
    }

    private func reconfigureCapture() async {
        let wantCamera = settings.cameraEnabled && cameraPermission == .authorized
        let wantMic = settings.micEnabled && micPermission == .authorized
        if !wantCamera && !wantMic {
            await capture.stop()
            captureInfo = CaptureInfo()
            return
        }
        captureInfo = await capture.configure(
            cameraID: wantCamera ? settings.cameraID : nil,
            resolution: settings.cameraResolution,
            fps: settings.cameraFPS,
            micID: wantMic ? settings.micID : nil
        )
    }

    // MARK: Hotkeys & timer

    private func handleHotKey(_ id: UInt32) {
        switch id {
        case HotKeyCenter.toggleRecordID: toggleRecording()
        case HotKeyCenter.togglePauseID: togglePause()
        default: break
        }
    }

    private func tick() {
        if active != nil, isRecordingActive, let session = active {
            elapsed = session.clock.elapsed()
        }
        // Mic meter with a gentle fall-off.
        let target = settings.micEnabled ? capture.micLevel : 0
        let next = max(target, micLevel - 0.08)
        if abs(next - micLevel) > 0.01 { micLevel = next }
    }

    // MARK: Actions

    func toggleRecording() {
        switch state {
        case .idle:
            Task { await startRecording() }
        case .countdown:
            cancelCountdown()
        case .recording, .paused:
            Task { await stopRecording() }
        case .starting, .finishing, .compositing:
            break
        }
    }

    func togglePause() {
        guard let session = active else { return }
        switch state {
        case .recording:
            session.clock.pause()
            state = .paused
        case .paused:
            session.clock.resume()
            state = .recording
        default:
            break
        }
    }

    private func cancelCountdown() {
        state = .idle
        countdownHUD.hide()
        floatingCamera.hide()
    }

    // MARK: Start

    private func startRecording() async {
        guard state == .idle else { return }
        errorMessage = nil
        let s = settings

        guard s.captureScreen || s.cameraEnabled else {
            errorMessage = "Turn on screen and/or camera recording first."
            return
        }
        if s.captureScreen && !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            screenPermission = false
            errorMessage = "Screen Recording permission is needed. Allow BrainRec in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen BrainRec."
            return
        }
        if s.cameraEnabled && (cameraPermission != .authorized || !captureInfo.hasCamera) {
            errorMessage = "The camera is not available. Check the Camera permission and the selected camera."
            return
        }
        if s.micEnabled && (micPermission != .authorized || !captureInfo.hasMic) {
            errorMessage = "The microphone is not available. Check the Microphone permission and the selected microphone."
            return
        }

        // Output folder + disk space check.
        let fm = FileManager.default
        let root = URL(fileURLWithPath: (s.outputFolder as NSString).expandingTildeInPath, isDirectory: true)
        let folder = root.appendingPathComponent("BrainRec \(Self.folderStamp.string(from: Date()))", isDirectory: true)
        let rawDir = folder.appendingPathComponent("raw", isDirectory: true)
        do {
            try fm.createDirectory(at: rawDir, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Cannot create the output folder: \(error.localizedDescription)"
            return
        }
        if let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < 3_000_000_000 {
            errorMessage = "Less than 3 GB free on the output disk. Free some space or choose another folder."
            try? fm.removeItem(at: folder)
            return
        }

        // Countdown (with the floating camera already visible so you can frame yourself).
        if s.cameraEnabled && s.showFloatingCamera {
            floatingCamera.show(session: capture.session)
        }
        if s.countdown > 0 {
            for n in stride(from: s.countdown, to: 0, by: -1) {
                state = .countdown(n)
                countdownHUD.show(n)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard case .countdown(let current) = state, current == n else {
                    try? fm.removeItem(at: folder)
                    return // cancelled
                }
            }
            countdownHUD.hide()
        }

        // From here on the Start button is locked until recording is really running.
        state = .starting

        // Build the session.
        let session = ActiveSession(folder: folder, rawDir: rawDir)
        session.screenFPS = s.screenFPS
        let clock = session.clock

        do {
            var target: ScreenCapture.Target?
            if s.captureScreen {
                let t = try await screen.makeTarget(settings: s)
                target = t
                session.screenWriter = try TrackWriter(
                    url: rawDir.appendingPathComponent("screen.mp4"),
                    fileType: .mp4,
                    clock: clock,
                    video: .init(
                        width: t.width, height: t.height, codec: s.codec,
                        bitrate: s.bitrate(width: t.width, height: t.height, fps: s.screenFPS),
                        fps: s.screenFPS
                    ),
                    audio: s.systemAudioEnabled ? .init(channels: 2, bitrate: 192_000) : nil
                )
            }

            let info = captureInfo
            if s.cameraEnabled {
                session.cameraWriter = try TrackWriter(
                    url: rawDir.appendingPathComponent("camera.mp4"),
                    fileType: .mp4,
                    clock: clock,
                    video: .init(
                        width: info.cameraWidth, height: info.cameraHeight, codec: s.codec,
                        bitrate: s.bitrate(width: info.cameraWidth, height: info.cameraHeight, fps: info.cameraFPS),
                        fps: info.cameraFPS
                    ),
                    audio: s.micEnabled ? .init(channels: info.micChannels, bitrate: 128_000 * info.micChannels) : nil
                )
            } else if s.micEnabled {
                session.micWriter = try TrackWriter(
                    url: rawDir.appendingPathComponent("mic.m4a"),
                    fileType: .m4a,
                    clock: clock,
                    video: nil,
                    audio: .init(channels: info.micChannels, bitrate: 128_000 * info.micChannels)
                )
            }

            // Wire capture callbacks to the writers.
            let cameraWriter = session.cameraWriter
            let micWriter = session.micWriter
            let screenWriter = session.screenWriter
            capture.setHandlers(
                video: { sb in cameraWriter?.appendVideo(sb) },
                audio: { sb in
                    cameraWriter?.appendAudio(sb)
                    micWriter?.appendAudio(sb)
                }
            )
            screen.onVideo = { sb in screenWriter?.appendVideo(sb) }
            screen.onAudio = { sb in screenWriter?.appendAudio(sb) }
            screen.onFirstFrame = { pts in clock.start(at: pts) }
            screen.onStopped = { [weak self] error in
                Task { @MainActor in self?.screenStreamStopped(error) }
            }

            try session.screenWriter?.start()
            try session.cameraWriter?.start()
            try session.micWriter?.start()
            active = session

            if let target = target {
                try await screen.start(target: target, fps: s.screenFPS, showCursor: s.showCursor, captureAudio: s.systemAudioEnabled)
                // Safety net: if no frame arrives (e.g. blank screen), start the clock anyway.
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    clock.start()
                }
            } else {
                clock.start()
            }

            elapsed = 0
            state = .recording
            NSSound(named: NSSound.Name("Tink"))?.play()
        } catch {
            await failStart(session: session, error: error)
        }
    }

    private func failStart(session: ActiveSession, error: Error) async {
        capture.setHandlers(video: nil, audio: nil)
        screen.onVideo = nil
        screen.onAudio = nil
        screen.onFirstFrame = nil
        screen.onStopped = nil
        await screen.stop()
        _ = session.clock.stop()
        for writer in [session.screenWriter, session.cameraWriter, session.micWriter].compactMap({ $0 }) {
            _ = await writer.finish(endTime: CMTime.zero)
        }
        try? FileManager.default.removeItem(at: session.folder)
        floatingCamera.hide()
        countdownHUD.hide()
        active = nil
        state = .idle
        errorMessage = "Could not start recording: \(error.localizedDescription)"
    }

    private func screenStreamStopped(_ error: Error?) {
        guard isRecordingActive else { return }
        errorMessage = "Screen capture stopped: \(error?.localizedDescription ?? "unknown reason"). Saving what was recorded."
        Task { await stopRecording() }
    }

    // MARK: Stop

    private func stopRecording() async {
        guard let session = active, isRecordingActive else { return }
        state = .finishing
        NSSound(named: NSSound.Name("Pop"))?.play()

        let endTime = session.clock.stop()
        floatingCamera.hide()
        await screen.stop()
        capture.setHandlers(video: nil, audio: nil)
        screen.onVideo = nil
        screen.onAudio = nil
        screen.onFirstFrame = nil
        screen.onStopped = nil

        var problems: [String] = []
        for writer in [session.screenWriter, session.cameraWriter, session.micWriter].compactMap({ $0 }) {
            if let error = await writer.finish(endTime: endTime) {
                problems.append("\(writer.url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let job = CompositeJob(
            screenURL: session.screenWriter?.url,
            cameraURL: session.cameraWriter?.url,
            micURL: session.micWriter?.url,
            outputURL: session.finalURL,
            settings: settings,
            fps: session.screenFPS
        )

        let succeeded = await runComposite(job)
        active = nil
        elapsed = 0
        state = .idle

        if succeeded {
            if !settings.keepRawFiles {
                try? FileManager.default.removeItem(at: session.rawDir)
            }
            lastResult = RecordingItem(folder: session.folder, finalURL: session.finalURL, date: Date(), hasRaw: settings.keepRawFiles)
            NSSound(named: NSSound.Name("Glass"))?.play()
            if !problems.isEmpty {
                errorMessage = "Saved, but some files reported problems: " + problems.joined(separator: "; ")
            }
        } else if !problems.isEmpty {
            errorMessage = (errorMessage ?? "") + " Writer problems: " + problems.joined(separator: "; ")
        }
        refreshRecents()
    }

    // MARK: Rendering

    private func runComposite(_ job: CompositeJob) async -> Bool {
        state = .compositing(0)
        do {
            try await Compositor().run(job) { [weak self] progress in
                Task { @MainActor in self?.updateProgress(progress) }
            }
            return true
        } catch {
            let rawFolder = job.outputURL.deletingLastPathComponent().appendingPathComponent("raw").path
            errorMessage = "Rendering the final MP4 failed: \(error.localizedDescription) Your raw recordings are safe in \(rawFolder)."
            return false
        }
    }

    private func updateProgress(_ value: Double) {
        if case .compositing = state { state = .compositing(value) }
    }

    /// Re-renders an old recording from its raw files using the layout currently selected in the UI.
    func rerender(_ item: RecordingItem) {
        guard state == .idle else { return }
        errorMessage = nil
        let raw = item.folder.appendingPathComponent("raw", isDirectory: true)
        let fm = FileManager.default
        func existing(_ name: String) -> URL? {
            let url = raw.appendingPathComponent(name)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        let output = item.folder.appendingPathComponent("\(item.folder.lastPathComponent) re-render.mp4")
        let job = CompositeJob(
            screenURL: existing("screen.mp4"),
            cameraURL: existing("camera.mp4"),
            micURL: existing("mic.m4a"),
            outputURL: output,
            settings: settings,
            fps: settings.screenFPS
        )
        Task {
            let ok = await runComposite(job)
            state = .idle
            if ok {
                lastResult = RecordingItem(folder: item.folder, finalURL: output, date: Date(), hasRaw: true)
                NSSound(named: NSSound.Name("Glass"))?.play()
            }
            refreshRecents()
        }
    }

    // MARK: Files

    func refreshRecents() {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: (settings.outputFolder as NSString).expandingTildeInPath, isDirectory: true)
        guard let folders = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            recents = []
            return
        }
        var items: [RecordingItem] = []
        for folder in folders where folder.lastPathComponent.hasPrefix("BrainRec ") {
            let values = try? folder.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let final = folder.appendingPathComponent("\(folder.lastPathComponent).mp4")
            let hasFinal = fm.fileExists(atPath: final.path)
            let hasRaw = fm.fileExists(atPath: folder.appendingPathComponent("raw").path)
            items.append(RecordingItem(
                folder: folder,
                finalURL: hasFinal ? final : nil,
                date: values?.creationDate ?? Date.distantPast,
                hasRaw: hasRaw
            ))
        }
        recents = Array(items.sorted { $0.date > $1.date }.prefix(6))
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            // Remember the folder across launches (required by the App Sandbox; harmless without it).
            scopedFolderURL?.stopAccessingSecurityScopedResource()
            scopedFolderURL = nil
            saveBookmark(for: url)
            if url.startAccessingSecurityScopedResource() { scopedFolderURL = url }
            settings.outputFolder = url.path
        }
    }

    // MARK: Output folder access (App Sandbox)

    /// A sandboxed app can only reopen a user-picked folder after relaunch through a security-scoped bookmark.
    private func restoreOutputFolderAccess() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            return
        }
        scopedFolderURL?.stopAccessingSecurityScopedResource()
        scopedFolderURL = url.startAccessingSecurityScopedResource() ? url : nil
        if isStale { saveBookmark(for: url) }
        if settings.outputFolder != url.path { settings.outputFolder = url.path }
    }

    private func saveBookmark(for url: URL) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
    }

    /// Screen Recording permission only applies after a restart, so offer a one-click relaunch.
    func relaunch() {
        HotKeyCenter.shared.unregisterAll() // free ⌃⌥R / ⌃⌥P for the new instance
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }

    func reveal(_ item: RecordingItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.finalURL ?? item.folder])
    }

    func play(_ item: RecordingItem) {
        if let url = item.finalURL { NSWorkspace.shared.open(url) }
    }

    func openOutputFolder() {
        let root = URL(fileURLWithPath: (settings.outputFolder as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }
}
