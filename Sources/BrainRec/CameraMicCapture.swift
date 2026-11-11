import AVFoundation
import CoreMedia

struct CaptureInfo: Equatable {
    var cameraWidth = 0
    var cameraHeight = 0
    var cameraFPS = 30
    var micChannels = 1
    var hasMic = false
    var hasCamera: Bool { cameraWidth > 0 }
}

/// Camera + microphone in one AVCaptureSession. The session stays running while the app is open
/// (so you get a live preview and a mic meter); samples are only forwarded while a recording is active.
final class CameraMicCapture: NSObject {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "brainrec.capture.session")
    private let videoQueue = DispatchQueue(label: "brainrec.camera.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "brainrec.mic.audio", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var outputsAdded = false

    private let lock = NSLock()
    private var videoHandler: ((CMSampleBuffer) -> Void)?
    private var audioHandler: ((CMSampleBuffer) -> Void)?
    private var level: Float = 0

    // MARK: - Device lists

    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    // MARK: - Handlers (set while recording)

    func setHandlers(video: ((CMSampleBuffer) -> Void)?, audio: ((CMSampleBuffer) -> Void)?) {
        lock.lock()
        videoHandler = video
        audioHandler = audio
        lock.unlock()
    }

    /// 0...1 loudness of the last microphone buffer.
    var micLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return level
    }

    // MARK: - Configuration

    /// (Re)configures the session. Pass nil for cameraID / micID to leave that device off.
    /// An empty string means "system default device".
    func configure(cameraID: String?, resolution: CameraResolution, fps: Int, micID: String?) async -> CaptureInfo {
        await withCheckedContinuation { (continuation: CheckedContinuation<CaptureInfo, Never>) in
            sessionQueue.async {
                let info = self.configureSync(cameraID: cameraID, resolution: resolution, fps: fps, micID: micID)
                continuation.resume(returning: info)
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if self.session.isRunning { self.session.stopRunning() }
                self.session.beginConfiguration()
                if let v = self.videoInput { self.session.removeInput(v); self.videoInput = nil }
                if let a = self.audioInput { self.session.removeInput(a); self.audioInput = nil }
                self.session.commitConfiguration()
                continuation.resume()
            }
        }
    }

    private func configureSync(cameraID: String?, resolution: CameraResolution, fps: Int, micID: String?) -> CaptureInfo {
        var info = CaptureInfo()
        var chosenCamera: AVCaptureDevice?

        session.beginConfiguration()
        // No preset needed: on macOS, setting device.activeFormat (below) switches the session to
        // input-priority automatically. (AVCaptureSession.Preset.inputPriority does not exist on macOS.)

        if let v = videoInput { session.removeInput(v); videoInput = nil }
        if let a = audioInput { session.removeInput(a); audioInput = nil }

        if !outputsAdded {
            videoOutput.alwaysDiscardsLateVideoFrames = false
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
            outputsAdded = true
        }

        // Camera
        if let id = cameraID {
            let device = (id.isEmpty ? nil : AVCaptureDevice(uniqueID: id)) ?? AVCaptureDevice.default(for: .video)
            if let device = device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
                chosenCamera = device
            }
        }

        // Microphone
        if let id = micID {
            let device = (id.isEmpty ? nil : AVCaptureDevice(uniqueID: id)) ?? AVCaptureDevice.default(for: .audio)
            if let device = device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                audioInput = input

                var channels = 1
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)?.pointee {
                    channels = min(max(Int(asbd.mChannelsPerFrame), 1), 2)
                }
                // Ask the capture output for clean 48 kHz float PCM with 1 or 2 channels.
                audioOutput.audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
                info.micChannels = channels
                info.hasMic = true
            }
        }

        session.commitConfiguration()

        // Pick the best camera format for the requested resolution / frame rate.
        if let device = chosenCamera {
            if let best = Self.bestFormat(for: device, targetWidth: resolution.targetWidth, fps: fps) {
                do {
                    try device.lockForConfiguration()
                    device.activeFormat = best.format
                    let duration = CMTime(value: 1, timescale: CMTimeScale(best.fps))
                    device.activeVideoMinFrameDuration = duration
                    device.activeVideoMaxFrameDuration = duration
                    device.unlockForConfiguration()
                } catch {
                    // Keep whatever format the device had.
                }
            }
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            info.cameraWidth = Int(dims.width) & ~1
            info.cameraHeight = Int(dims.height) & ~1
            let frameSeconds = CMTimeGetSeconds(device.activeVideoMinFrameDuration)
            info.cameraFPS = frameSeconds > 0 ? max(1, Int((1.0 / frameSeconds).rounded())) : fps
        }

        if session.inputs.isEmpty {
            if session.isRunning { session.stopRunning() }
        } else if !session.isRunning {
            session.startRunning()
        }
        return info
    }

    /// Picks the largest format that fits `targetWidth` and supports `fps` (falls back to 30 / 24 / 15 fps).
    private static func bestFormat(for device: AVCaptureDevice, targetWidth: Int, fps: Int) -> (format: AVCaptureDevice.Format, fps: Int)? {
        for tryFPS in [fps, 30, 24, 15] {
            var best: AVCaptureDevice.Format?
            var bestScore = -1
            for format in device.formats {
                let supportsFPS = format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= Double(tryFPS) + 0.01 && Double(tryFPS) <= $0.maxFrameRate + 0.01
                }
                guard supportsFPS else { continue }
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let width = Int(dims.width)
                guard width <= targetWidth else { continue }
                var score = width * 10
                let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                if subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
                    score += 5
                }
                if score > bestScore {
                    best = format
                    bestScore = score
                }
            }
            if let best = best { return (best, tryFPS) }
        }
        return nil
    }
}

// MARK: - Sample buffer delegates (one method serves both protocols)

extension CameraMicCapture: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            lock.lock()
            let handler = videoHandler
            lock.unlock()
            handler?(sampleBuffer)
        } else if output === audioOutput {
            updateLevel(from: sampleBuffer)
            lock.lock()
            let handler = audioHandler
            lock.unlock()
            handler?(sampleBuffer)
        }
    }

    private func updateLevel(from sampleBuffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
        guard status == kCMBlockBufferNoErr, let base = pointer else { return }
        let count = length / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let samples = UnsafeBufferPointer(start: UnsafeRawPointer(base).assumingMemoryBound(to: Float.self), count: count)
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(count)).squareRoot()
        let db = 20 * log10(max(rms, 0.000_001))
        let normalized = max(0, min(1, (db + 50) / 50))
        lock.lock()
        level = normalized
        lock.unlock()
    }
}
