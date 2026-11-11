import AVFoundation
import AppKit
import SwiftUI

// MARK: - Live camera preview

final class CameraPreviewNSView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    private var mirrored: Bool
    private var observer: NSObjectProtocol?

    init(session: AVCaptureSession, mirrored: Bool) {
        self.previewLayer = AVCaptureVideoPreviewLayer(session: session)
        self.mirrored = mirrored
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
        applyMirror()

        // The preview connection only exists once the session has inputs, so re-apply when it starts.
        observer = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.didStartRunningNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.applyMirror()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    func setMirrored(_ value: Bool) {
        mirrored = value
        applyMirror()
    }

    private func applyMirror() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var mirrored = true

    func makeNSView(context: Context) -> CameraPreviewNSView {
        CameraPreviewNSView(session: session, mirrored: mirrored)
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.setMirrored(mirrored)
    }
}

// MARK: - Floating camera bubble (visible to you, never recorded into the screen file)

@MainActor
final class FloatingCameraController {
    private var panel: NSPanel?

    func show(session: AVCaptureSession, diameter: CGFloat = 240) {
        guard panel == nil else { return }

        let view = CameraPreviewNSView(session: session, mirrored: true)
        view.layer?.cornerRadius = diameter / 2
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 3
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: diameter, height: diameter),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - diameter - 32, y: frame.minY + 32))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Countdown HUD

struct CountdownView: View {
    let number: Int
    var body: some View {
        Text("\(number)")
            .font(.system(size: 120, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 220, height: 220)
            .background(.black.opacity(0.65), in: Circle())
    }
}

@MainActor
final class CountdownHUD {
    private var panel: NSPanel?
    private var host: NSHostingView<CountdownView>?

    func show(_ number: Int) {
        if let host = host {
            host.rootView = CountdownView(number: number)
            return
        }
        let host = NSHostingView(rootView: CountdownView(number: number))
        host.frame = NSRect(x: 0, y: 0, width: 220, height: 220)

        let panel = NSPanel(
            contentRect: host.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let screen = NSScreen.main {
            let f = screen.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - 110, y: f.midY - 110))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        self.host = host
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        host = nil
    }
}

// MARK: - Permissions

enum Permissions {
    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openCameraSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }
}
