import AVFoundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            RecorderPane()
            Divider()
            SettingsPane()
                .frame(width: 430)
        }
        .frame(minWidth: 1040, minHeight: 720)
    }
}

// MARK: - Left side: preview, controls, results

struct RecorderPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            preview
            controls

            if case .compositing(let progress) = model.state {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                    Text("Rendering final MP4… \(Int(progress * 100))%")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let message = model.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.errorMessage = nil }
                }
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if let result = model.lastResult, let url = result.finalURL {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text("Saved").font(.headline)
                        Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Play") { model.play(result) }
                    Button("Show in Finder") { model.reveal(result) }
                }
                .padding(10)
                .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer(minLength: 0)
            RecentsList()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var preview: some View {
        ZStack {
            Color.black
            if model.settings.cameraEnabled && model.captureInfo.hasCamera {
                CameraPreview(session: model.capture.session, mirrored: true)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash").font(.system(size: 36))
                    Text(model.settings.cameraEnabled ? "Waiting for camera…" : "Camera is off")
                }
                .foregroundStyle(.secondary)
            }
            if case .countdown(let n) = model.state {
                Text("\(n)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 8)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topLeading) {
            if model.isRecordingActive {
                HStack(spacing: 6) {
                    Circle().fill(model.state == .paused ? Color.yellow : Color.red).frame(width: 10, height: 10)
                    Text(model.state == .paused ? "PAUSED" : "REC").font(.caption.bold())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.white)
                .padding(12)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Text(model.elapsedString)
                .font(.system(size: 32, weight: .semibold))
                .monospacedDigit()
            Spacer()
            if model.isRecordingActive {
                Button(model.state == .paused ? "Resume" : "Pause") { model.togglePause() }
                    .controlSize(.large)
            }
            Button {
                model.toggleRecording()
            } label: {
                Label(primaryTitle, systemImage: primaryIcon)
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRecordingActive ? Color.gray : Color.red)
            .controlSize(.large)
            .disabled(primaryDisabled)
        }
    }

    private var primaryTitle: String {
        switch model.state {
        case .idle: return "Start Recording"
        case .countdown: return "Cancel"
        case .starting: return "Starting…"
        case .recording, .paused: return "Stop"
        case .finishing: return "Finishing…"
        case .compositing: return "Rendering…"
        }
    }

    private var primaryIcon: String {
        switch model.state {
        case .idle: return "record.circle"
        case .countdown: return "xmark.circle"
        case .recording, .paused: return "stop.circle.fill"
        case .starting, .finishing, .compositing: return "hourglass"
        }
    }

    private var primaryDisabled: Bool {
        switch model.state {
        case .idle, .countdown, .recording, .paused: return false
        case .starting, .finishing, .compositing: return true
        }
    }
}

struct RecentsList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if !model.recents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent recordings").font(.headline)
                ForEach(model.recents) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).lineLimit(1)
                            Text(item.date, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Play") { model.play(item) }
                            .disabled(item.finalURL == nil)
                        Button("Reveal") { model.reveal(item) }
                        Button("Re-render") { model.rerender(item) }
                            .disabled(!item.hasRaw || model.isBusy)
                            .help("Builds a new MP4 from the raw files using the layout currently selected on the right.")
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Right side: settings

struct SettingsPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            screenSection
            cameraSection
            audioSection
            if model.settings.captureScreen && model.settings.cameraEnabled {
                layoutSection
            }
            qualitySection
            outputSection
            permissionsSection
        }
        .formStyle(.grouped)
        .disabled(model.isBusy)
    }

    // MARK: Sections

    private var screenSection: some View {
        Section("Screen") {
            Toggle("Record screen", isOn: $model.settings.captureScreen)
            if model.settings.captureScreen {
                Picker("Capture", selection: $model.settings.captureMode) {
                    ForEach(CaptureMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if model.settings.captureMode == .display {
                    Picker("Display", selection: $model.settings.displayID) {
                        ForEach(model.displays) { display in
                            Text(display.name).tag(display.id)
                        }
                    }
                } else {
                    Picker("Window", selection: $model.settings.windowID) {
                        ForEach(model.windows) { window in
                            Text(window.title).tag(window.id)
                        }
                    }
                    Button("Refresh window list") {
                        Task { await model.refreshScreenSources() }
                    }
                }

                Picker("Frame rate", selection: $model.settings.screenFPS) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("Show mouse cursor", isOn: $model.settings.showCursor)
            }
        }
    }

    private var cameraSection: some View {
        Section("Camera") {
            Toggle("Record camera", isOn: $model.settings.cameraEnabled)
            if model.settings.cameraEnabled {
                Picker("Camera", selection: $model.settings.cameraID) {
                    ForEach(model.cameras) { camera in
                        Text(camera.name).tag(camera.id)
                    }
                }
                Picker("Resolution", selection: $model.settings.cameraResolution) {
                    ForEach(CameraResolution.allCases) { resolution in
                        Text(resolution.label).tag(resolution)
                    }
                }
                Picker("Frame rate", selection: $model.settings.cameraFPS) {
                    Text("30 fps").tag(30)
                    Text("60 fps (if supported)").tag(60)
                }
                Toggle("Floating camera while recording", isOn: $model.settings.showFloatingCamera)
            }
        }
    }

    private var audioSection: some View {
        Section("Audio") {
            Toggle("Record microphone", isOn: $model.settings.micEnabled)
            if model.settings.micEnabled {
                Picker("Microphone", selection: $model.settings.micID) {
                    ForEach(model.microphones) { mic in
                        Text(mic.name).tag(mic.id)
                    }
                }
                ProgressView(value: Double(model.micLevel))
                    .tint(model.micLevel > 0.92 ? Color.red : Color.green)
                HStack {
                    Text("Mic volume")
                    Slider(value: $model.settings.micVolume, in: 0...2)
                    Text("\(Int(model.settings.micVolume * 100))%").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }
            if model.settings.captureScreen {
                Toggle("Record system audio", isOn: $model.settings.systemAudioEnabled)
                if model.settings.systemAudioEnabled {
                    HStack {
                        Text("System volume")
                        Slider(value: $model.settings.systemVolume, in: 0...2)
                        Text("\(Int(model.settings.systemVolume * 100))%").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var layoutSection: some View {
        Section("Camera bubble in final video") {
            Picker("Corner", selection: $model.settings.pipCorner) {
                ForEach(PipCorner.allCases) { corner in
                    Text(corner.symbol).tag(corner)
                }
            }
            .pickerStyle(.segmented)

            Picker("Shape", selection: $model.settings.pipShape) {
                ForEach(PipShape.allCases) { shape in
                    Text(shape.label).tag(shape)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Size")
                Slider(value: $model.settings.pipSize, in: 0.12...0.40)
                Text("\(Int(model.settings.pipSize * 100))%").monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            Toggle("White border", isOn: $model.settings.pipBorder)
            Toggle("Drop shadow", isOn: $model.settings.pipShadow)
            Toggle("Mirror camera in final video", isOn: $model.settings.pipMirror)
            Text("You can change this later and use “Re-render” on any recording — the raw files are kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var qualitySection: some View {
        Section("Quality") {
            Picker("Codec", selection: $model.settings.codec) {
                ForEach(VideoCodec.allCases) { codec in
                    Text(codec.label).tag(codec)
                }
            }
            Picker("Quality", selection: $model.settings.quality) {
                ForEach(QualityPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            if !model.estimateText.isEmpty {
                Text(model.estimateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var outputSection: some View {
        Section("Output") {
            HStack {
                Text(model.settings.outputFolder)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") { model.chooseOutputFolder() }
                Button("Open") { model.openOutputFolder() }
            }
            if model.settings.outputFolder.contains("/Library/Containers/") {
                Text("Saving inside BrainRec's private folder. Click Choose… to save to Movies, Desktop or an external drive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Stepper("Countdown: \(model.settings.countdown) s", value: $model.settings.countdown, in: 0...10)
            Toggle("Keep raw files (screen / camera / mic)", isOn: $model.settings.keepRawFiles)
            Text("Hotkeys: ⌃⌥R start / stop · ⌃⌥P pause / resume")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            permissionRow("Screen Recording", granted: model.screenPermission) {
                Permissions.openScreenRecordingSettings()
            }
            permissionRow("Camera", granted: model.cameraPermission == .authorized) {
                Permissions.openCameraSettings()
            }
            permissionRow("Microphone", granted: model.micPermission == .authorized) {
                Permissions.openMicrophoneSettings()
            }
            if !model.screenPermission {
                Text("After allowing Screen Recording in System Settings, relaunch BrainRec once so it takes effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Relaunch BrainRec") { model.relaunch() }
            }
            Button("Re-check permissions & devices") {
                model.refreshPermissions()
                model.refreshDevices()
                Task { await model.refreshScreenSources() }
            }
        }
    }

    private func permissionRow(_ title: String, granted: Bool, open: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.red)
            Text(title)
            Spacer()
            if !granted {
                Button("Open Settings", action: open)
            }
        }
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(model.isRecordingActive ? "Stop Recording" : "Start Recording") {
            model.toggleRecording()
        }
        .disabled(model.state == .starting || model.state == .finishing)

        Button(model.state == .paused ? "Resume" : "Pause") {
            model.togglePause()
        }
        .disabled(!model.isRecordingActive)

        Divider()

        Button("Show BrainRec Window") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Button("Open Recordings Folder") {
            model.openOutputFolder()
        }

        Divider()

        Button("Quit BrainRec") {
            NSApplication.shared.terminate(nil)
        }
    }
}
