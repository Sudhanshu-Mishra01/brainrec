import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case noDisplay
    case noWindow

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found to record."
        case .noWindow: return "The selected window is no longer available. Pick another one."
        }
    }
}

/// Screen (and optional system audio) capture using ScreenCaptureKit.
/// Frames are delivered as raw sample buffers; the caller decides where they go.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Target {
        let filter: SCContentFilter
        let width: Int
        let height: Int
    }

    var onVideo: ((CMSampleBuffer) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    /// Called once with the timestamp of the first usable frame.
    var onFirstFrame: ((CMTime) -> Void)?
    var onStopped: ((Error?) -> Void)?

    private var stream: SCStream?
    private var gotFirstFrame = false
    private var stoppingByUs = false
    private let videoQueue = DispatchQueue(label: "brainrec.screen.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "brainrec.screen.audio", qos: .userInteractive)

    // MARK: - Target resolution

    /// Works out what to capture and at which pixel size (native Retina pixels, clamped to what the codec can encode).
    @MainActor
    func makeTarget(settings: RecorderSettings) async throws -> Target {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // Never record our own windows (control panel, floating camera, countdown).
        let ourApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }

        switch settings.captureMode {
        case .display:
            guard let display = content.displays.first(where: { $0.displayID == settings.displayID }) ?? content.displays.first else {
                throw RecorderError.noDisplay
            }
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            let pixelW = mode?.pixelWidth ?? display.width * 2
            let pixelH = mode?.pixelHeight ?? display.height * 2
            let size = settings.codec.fit(width: pixelW, height: pixelH)
            let filter = SCContentFilter(display: display, excludingApplications: ourApps, exceptingWindows: [])
            return Target(filter: filter, width: size.width, height: size.height)

        case .window:
            guard let window = content.windows.first(where: { $0.windowID == settings.windowID }) else {
                throw RecorderError.noWindow
            }
            let scale = NSScreen.screens.map { $0.backingScaleFactor }.max() ?? 2.0
            let pixelW = Int(window.frame.width * scale)
            let pixelH = Int(window.frame.height * scale)
            let size = settings.codec.fit(width: pixelW, height: pixelH)
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return Target(filter: filter, width: size.width, height: size.height)
        }
    }

    // MARK: - Start / stop

    func start(target: Target, fps: Int, showCursor: Bool, captureAudio: Bool) async throws {
        let config = SCStreamConfiguration()
        config.width = target.width
        config.height = target.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = showCursor
        config.queueDepth = 8
        if captureAudio {
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }

        let newStream = SCStream(filter: target.filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if captureAudio {
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        gotFirstFrame = false
        stoppingByUs = false
        stream = newStream
        try await newStream.startCapture()
    }

    func stop() async {
        guard let current = stream else { return }
        stoppingByUs = true
        stream = nil
        try? await current.stopCapture()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        switch type {
        case .screen:
            guard isUsableFrame(sampleBuffer) else { return }
            if !gotFirstFrame {
                gotFirstFrame = true
                onFirstFrame?(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            }
            onVideo?(sampleBuffer)
        case .audio:
            onAudio?(sampleBuffer)
        default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !stoppingByUs else { return }
        onStopped?(error)
    }

    // MARK: - Helpers

    /// ScreenCaptureKit also sends "idle" callbacks (nothing changed on screen). Only real frames are written.
    /// The very first frame is accepted whatever its status, so a static screen still starts the video at t=0.
    private func isUsableFrame(_ sb: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let first = attachments.first,
              let raw = first[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        if status == .complete { return true }
        return !gotFirstFrame && CMSampleBufferGetImageBuffer(sb) != nil
    }
}
