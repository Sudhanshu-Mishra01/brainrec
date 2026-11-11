import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

struct CompositeJob {
    var screenURL: URL?      // screen.mp4 (video + optional system audio)
    var cameraURL: URL?      // camera.mp4 (video + optional mic audio)
    var micURL: URL?         // mic.m4a (only when the camera was off)
    var outputURL: URL
    var settings: RecorderSettings
    var fps: Int
}

enum CompositeError: LocalizedError {
    case noVideo
    case reader(String)
    case writer(String)
    case noFrames

    var errorDescription: String? {
        switch self {
        case .noVideo: return "No video track found in the recorded files."
        case .reader(let m): return "Could not read a recorded file (\(m))."
        case .writer(let m): return "Could not write the final MP4 (\(m))."
        case .noFrames: return "The screen recording contains no frames."
        }
    }
}

final class ErrorBox {
    private let lock = NSLock()
    private var stored: Error?
    func set(_ error: Error) {
        lock.lock()
        if stored == nil { stored = error }
        lock.unlock()
    }
    var error: Error? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

struct AudioSource {
    let track: AVAssetTrack
    let duration: CMTime
    let volume: Float
}

/// Reads decoded BGRA frames from a video file and answers "which frame is on screen at time t?".
/// Screen recordings are variable frame rate (a frame only exists when something changed), so the last
/// frame is held until the next one arrives.
final class FrameSource {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var current: CVPixelBuffer?
    private var next: (time: Double, buffer: CVPixelBuffer)?
    private var primed = false
    private(set) var failure: Error?

    init(asset: AVAsset, track: AVAssetTrack) throws {
        let r = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])
        o.alwaysCopiesSampleData = false
        guard r.canAdd(o) else { throw CompositeError.reader("cannot add track output") }
        r.add(o)
        guard r.startReading() else {
            throw CompositeError.reader(r.error?.localizedDescription ?? "startReading failed")
        }
        reader = r
        output = o
    }

    private func readNext() -> (time: Double, buffer: CVPixelBuffer)? {
        while let sb = output.copyNextSampleBuffer() {
            if let pb = CMSampleBufferGetImageBuffer(sb) {
                return (CMSampleBufferGetPresentationTimeStamp(sb).seconds, pb)
            }
        }
        if reader.status == .failed {
            failure = reader.error ?? CompositeError.reader("decode failed")
        }
        return nil
    }

    func frame(at t: Double) -> CVPixelBuffer? {
        if !primed {
            primed = true
            next = readNext()
        }
        while let n = next, n.time <= t + 0.000_001 {
            current = n.buffer
            next = readNext()
        }
        return current ?? next?.buffer
    }
}

/// Camera bubble: placement, mask (circle / rounded / rectangle), border ring and drop shadow.
/// Coordinates are Core Image coordinates (origin bottom-left).
struct PipOverlay {
    let rect: CGRect
    let decoration: CIImage
    let mask: CIImage
    let mirror: Bool

    init(outputSize: CGSize, cameraSize: CGSize, settings: RecorderSettings) {
        let outW = outputSize.width
        let outH = outputSize.height
        let pipW = max(2, (outW * CGFloat(settings.pipSize)).rounded())
        var pipH = pipW
        if settings.pipShape != .circle {
            let aspect = cameraSize.height > 0 ? cameraSize.width / cameraSize.height : 16.0 / 9.0
            pipH = max(2, (pipW / aspect).rounded())
        }
        let border: CGFloat = settings.pipBorder ? max(3, (outW * 0.0025).rounded()) : 0
        let margin = (outW * 0.025).rounded() + border
        let x: CGFloat = (settings.pipCorner == .topLeft || settings.pipCorner == .bottomLeft) ? margin : outW - margin - pipW
        let y: CGFloat = (settings.pipCorner == .bottomLeft || settings.pipCorner == .bottomRight) ? margin : outH - margin - pipH
        let placed = CGRect(x: x, y: y, width: pipW, height: pipH)

        rect = placed
        mirror = settings.pipMirror
        mask = PipOverlay.makeMask(size: placed.size, shape: settings.pipShape)
        decoration = PipOverlay.makeDecoration(
            size: placed.size,
            shape: settings.pipShape,
            border: border,
            shadow: settings.pipShadow,
            origin: placed.origin
        )
    }

    /// Draws the camera (cropped, scaled, masked) plus its decoration over the screen image.
    func compose(screen: CIImage, camera: CIImage) -> CIImage {
        let ce = camera.extent
        let targetAspect = rect.width / rect.height
        var crop = ce
        if ce.width / ce.height > targetAspect {
            crop.size.width = ce.height * targetAspect
            crop.origin.x = ce.minX + (ce.width - crop.width) / 2
        } else {
            crop.size.height = ce.width / targetAspect
            crop.origin.y = ce.minY + (ce.height - crop.height) / 2
        }

        var image = camera
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))

        if mirror {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -crop.width, y: 0))
        }

        let scale = max(rect.width / crop.width, rect.height / crop.height)
        image = image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale,
            kCIInputAspectRatioKey: 1.0
        ])
        image = image.cropped(to: CGRect(origin: .zero, size: rect.size))
        image = image.applyingFilter("CISourceInCompositing", parameters: [
            kCIInputBackgroundImageKey: mask
        ])
        image = image.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))

        return image.composited(over: decoration.composited(over: screen))
    }

    // MARK: Drawing helpers

    private static func bitmap(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func path(for shape: PipShape, in rect: CGRect) -> CGPath {
        switch shape {
        case .circle:
            return CGPath(ellipseIn: rect, transform: nil)
        case .roundedRect:
            let r = min(rect.width, rect.height) * 0.14
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        case .rectangle:
            return CGPath(rect: rect, transform: nil)
        }
    }

    private static func makeMask(size: CGSize, shape: PipShape) -> CIImage {
        let w = Int(size.width)
        let h = Int(size.height)
        let fallback = CIImage(color: CIColor.white).cropped(to: CGRect(origin: .zero, size: size))
        guard let ctx = bitmap(w, h) else { return fallback }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.addPath(path(for: shape, in: CGRect(x: 0, y: 0, width: w, height: h)))
        ctx.fillPath()
        guard let cg = ctx.makeImage() else { return fallback }
        return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
    }

    private static func makeDecoration(size: CGSize, shape: PipShape, border: CGFloat, shadow: Bool, origin: CGPoint) -> CIImage {
        guard border > 0 || shadow else { return CIImage.empty() }
        let pad = border + size.width * 0.25
        let w = Int(size.width + pad * 2)
        let h = Int(size.height + pad * 2)
        guard let ctx = bitmap(w, h) else { return CIImage.empty() }

        let inner = CGRect(x: pad, y: pad, width: size.width, height: size.height)
        let outer = inner.insetBy(dx: -border, dy: -border)

        ctx.saveGState()
        if shadow {
            ctx.setShadow(
                offset: CGSize(width: 0, height: -size.height * 0.03),
                blur: size.width * 0.09,
                color: CGColor(gray: 0, alpha: 0.55)
            )
        }
        // White ring when there is a border; otherwise a dark base so the shadow has something to cast from.
        ctx.setFillColor(border > 0 ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1))
        ctx.addPath(path(for: shape, in: outer))
        ctx.fillPath()
        ctx.restoreGState()

        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(translationX: origin.x - pad, y: origin.y - pad))
    }
}

/// Builds the final MP4 from the raw recordings.
///  • Screen + camera: re-renders every frame (constant frame rate) with the camera bubble on top.
///  • Anything else: the video is copied without re-encoding; only the audio is mixed.
final class Compositor {
    func run(_ job: CompositeJob, progress: @escaping (Double) -> Void) async throws {
        let screenAsset = job.screenURL.map { AVURLAsset(url: $0) }
        let cameraAsset = job.cameraURL.map { AVURLAsset(url: $0) }
        let micAsset = job.micURL.map { AVURLAsset(url: $0) }

        guard let primaryAsset = screenAsset ?? cameraAsset else { throw CompositeError.noVideo }
        let primaryTracks = try await primaryAsset.loadTracks(withMediaType: .video)
        guard let primaryTrack = primaryTracks.first else { throw CompositeError.noVideo }
        let primarySize = try await primaryTrack.load(.naturalSize)
        let primaryFormats = try await primaryTrack.load(.formatDescriptions)
        let primaryDuration = try await primaryAsset.load(.duration)
        var duration = primaryDuration.seconds

        // Camera overlay only makes sense when a screen recording exists too.
        var overlayCameraTrack: AVAssetTrack?
        var overlayCameraSize = CGSize.zero
        if screenAsset != nil, let camAsset = cameraAsset {
            let tracks = try await camAsset.loadTracks(withMediaType: .video)
            if let track = tracks.first {
                overlayCameraTrack = track
                overlayCameraSize = try await track.load(.naturalSize)
                let camDuration = try await camAsset.load(.duration)
                duration = max(duration, camDuration.seconds)
            }
        }

        // Audio sources: system audio (screen file), mic (camera file or mic file).
        var audioSources: [AudioSource] = []
        if let asset = screenAsset,
           let source = try await Compositor.audioSource(from: asset, volume: Float(job.settings.systemVolume)) {
            audioSources.append(source)
        }
        if let asset = cameraAsset,
           let source = try await Compositor.audioSource(from: asset, volume: Float(job.settings.micVolume)) {
            audioSources.append(source)
        }
        if let asset = micAsset,
           let source = try await Compositor.audioSource(from: asset, volume: Float(job.settings.micVolume)) {
            audioSources.append(source)
        }

        let formatHint = primaryFormats.first
        let cameraAssetForOverlay: AVAsset? = overlayCameraTrack != nil ? cameraAsset : nil
        let sources = audioSources
        let totalDuration = duration

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Compositor.process(
                        job: job,
                        primaryAsset: primaryAsset,
                        primaryTrack: primaryTrack,
                        primarySize: primarySize,
                        formatHint: formatHint,
                        cameraAsset: cameraAssetForOverlay,
                        cameraTrack: overlayCameraTrack,
                        cameraSize: overlayCameraSize,
                        audioSources: sources,
                        duration: totalDuration,
                        progress: progress
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func audioSource(from asset: AVURLAsset, volume: Float) async throws -> AudioSource? {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { return nil }
        let duration = try await asset.load(.duration)
        return AudioSource(track: track, duration: duration, volume: volume)
    }

    // MARK: - Blocking pipeline (runs on a background queue)

    private static func process(
        job: CompositeJob,
        primaryAsset: AVAsset,
        primaryTrack: AVAssetTrack,
        primarySize: CGSize,
        formatHint: CMFormatDescription?,
        cameraAsset: AVAsset?,
        cameraTrack: AVAssetTrack?,
        cameraSize: CGSize,
        audioSources: [AudioSource],
        duration: Double,
        progress: @escaping (Double) -> Void
    ) throws {
        try? FileManager.default.removeItem(at: job.outputURL)

        let writer = try AVAssetWriter(outputURL: job.outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let errors = ErrorBox()
        let group = DispatchGroup()
        var readers: [AVAssetReader] = []

        let width = Int(primarySize.width) & ~1
        let height = Int(primarySize.height) & ~1
        let fps = max(job.fps, 1)

        // ---------- Video ----------
        let videoInput: AVAssetWriterInput
        let startVideo: () -> Void

        if let camAsset = cameraAsset, let camTrack = cameraTrack {
            // Composite: screen + camera bubble, constant frame rate.
            let settings = job.settings
            let bitrate = Int(Double(settings.bitrate(width: width, height: height, fps: fps)) * 1.1)
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: Compositor.videoSettings(width: width, height: height, codec: settings.codec, bitrate: bitrate, fps: fps)
            )
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ]
            )
            let screenSource = try FrameSource(asset: primaryAsset, track: primaryTrack)
            let cameraSource = try FrameSource(asset: camAsset, track: camTrack)
            let overlay = PipOverlay(
                outputSize: CGSize(width: width, height: height),
                cameraSize: cameraSize,
                settings: settings
            )
            // Colour management off: pixel values pass through untouched.
            let ciContext = CIContext(options: [
                .workingColorSpace: NSNull(),
                .outputColorSpace: NSNull(),
                .cacheIntermediates: false
            ])
            let imageOptions: [CIImageOption: Any] = [.colorSpace: NSNull()]
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let totalFrames = max(1, Int((duration * Double(fps)).rounded(.up)))
            let queue = DispatchQueue(label: "brainrec.compose.video")

            videoInput = input
            startVideo = {
                group.enter()
                var index = 0
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        if errors.error != nil || index >= totalFrames {
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                        let ok: Bool = autoreleasepool {
                            let t = Double(index) / Double(fps)
                            guard let screenBuffer = screenSource.frame(at: t) else {
                                errors.set(screenSource.failure ?? CompositeError.noFrames)
                                return false
                            }
                            guard let pool = adaptor.pixelBufferPool else {
                                errors.set(CompositeError.writer("no pixel buffer pool"))
                                return false
                            }
                            var created: CVPixelBuffer?
                            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
                            guard let target = created else {
                                errors.set(CompositeError.writer("could not allocate a frame"))
                                return false
                            }
                            var image = CIImage(cvPixelBuffer: screenBuffer, options: imageOptions)
                            if let cameraBuffer = cameraSource.frame(at: t) {
                                image = overlay.compose(
                                    screen: image,
                                    camera: CIImage(cvPixelBuffer: cameraBuffer, options: imageOptions)
                                )
                            }
                            ciContext.render(image, to: target, bounds: bounds, colorSpace: nil)
                            Compositor.tagColor(target)
                            let pts = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
                            if !adaptor.append(target, withPresentationTime: pts) {
                                errors.set(CompositeError.writer(writer.error?.localizedDescription ?? "append failed"))
                                return false
                            }
                            return true
                        }
                        if !ok {
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                        index += 1
                        if index % 10 == 0 {
                            progress(min(0.98, Double(index) / Double(totalFrames)))
                        }
                    }
                }
            }
        } else {
            // Passthrough: copy the compressed video as-is (no quality loss, very fast).
            let output = AVAssetReaderTrackOutput(track: primaryTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let reader = try AVAssetReader(asset: primaryAsset)
            guard reader.canAdd(output) else { throw CompositeError.reader("cannot read video track") }
            reader.add(output)
            guard reader.startReading() else {
                throw CompositeError.reader(reader.error?.localizedDescription ?? "startReading failed")
            }
            readers.append(reader)

            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint)
            input.expectsMediaDataInRealTime = false
            let queue = DispatchQueue(label: "brainrec.remux.video")
            let safeDuration = max(duration, 0.001)

            videoInput = input
            startVideo = {
                group.enter()
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        if errors.error != nil {
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                        if let sample = output.copyNextSampleBuffer() {
                            if !input.append(sample) {
                                errors.set(CompositeError.writer(writer.error?.localizedDescription ?? "append failed"))
                                input.markAsFinished()
                                group.leave()
                                return
                            }
                            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                            progress(min(0.98, t / safeDuration))
                        } else {
                            if reader.status == .failed {
                                errors.set(reader.error ?? CompositeError.reader("read failed"))
                            }
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }
        }

        guard writer.canAdd(videoInput) else { throw CompositeError.writer("cannot add video input") }
        writer.add(videoInput)

        // ---------- Audio (mic + system audio mixed to stereo AAC) ----------
        var startAudio: (() -> Void)?
        if !audioSources.isEmpty {
            let composition = AVMutableComposition()
            var parameters: [AVMutableAudioMixInputParameters] = []
            var compositionTracks: [AVAssetTrack] = []
            for source in audioSources {
                guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try track.insertTimeRange(CMTimeRange(start: CMTime.zero, duration: source.duration), of: source.track, at: CMTime.zero)
                let p = AVMutableAudioMixInputParameters(track: track)
                p.setVolume(source.volume, at: CMTime.zero)
                parameters.append(p)
                compositionTracks.append(track)
            }

            if !compositionTracks.isEmpty {
                let mix = AVMutableAudioMix()
                mix.inputParameters = parameters

                let pcm: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
                let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: compositionTracks, audioSettings: pcm)
                audioOutput.audioMix = mix
                let audioReader = try AVAssetReader(asset: composition)
                guard audioReader.canAdd(audioOutput) else { throw CompositeError.reader("cannot mix audio") }
                audioReader.add(audioOutput)
                guard audioReader.startReading() else {
                    throw CompositeError.reader(audioReader.error?.localizedDescription ?? "audio startReading failed")
                }
                readers.append(audioReader)

                let aacSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 256_000
                ]
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
                audioInput.expectsMediaDataInRealTime = false
                guard writer.canAdd(audioInput) else { throw CompositeError.writer("cannot add audio input") }
                writer.add(audioInput)

                let queue = DispatchQueue(label: "brainrec.compose.audio")
                startAudio = {
                    group.enter()
                    audioInput.requestMediaDataWhenReady(on: queue) {
                        while audioInput.isReadyForMoreMediaData {
                            if errors.error != nil {
                                audioInput.markAsFinished()
                                group.leave()
                                return
                            }
                            if let sample = audioOutput.copyNextSampleBuffer() {
                                if !audioInput.append(sample) {
                                    errors.set(CompositeError.writer(writer.error?.localizedDescription ?? "audio append failed"))
                                    audioInput.markAsFinished()
                                    group.leave()
                                    return
                                }
                            } else {
                                if audioReader.status == .failed {
                                    errors.set(audioReader.error ?? CompositeError.reader("audio read failed"))
                                }
                                audioInput.markAsFinished()
                                group.leave()
                                return
                            }
                        }
                    }
                }
            }
        }

        // ---------- Run ----------
        guard writer.startWriting() else {
            throw CompositeError.writer(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: CMTime.zero)
        startVideo()
        startAudio?()
        group.wait()

        if let error = errors.error {
            readers.forEach { $0.cancelReading() }
            writer.cancelWriting()
            throw error
        }

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()

        guard writer.status == .completed else {
            throw CompositeError.writer(writer.error?.localizedDescription ?? "finish failed")
        }
        progress(1.0)
    }

    // MARK: - Helpers

    private static func videoSettings(width: Int, height: Int, codec: VideoCodec, bitrate: Int, fps: Int) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalDurationKey: 2.0
        ]
        if codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        }
        let colorProps: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
        return [
            AVVideoCodecKey: codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: colorProps,
            AVVideoCompressionPropertiesKey: compression
        ]
    }

    /// Marks rendered frames as Rec.709 so the encoder's YUV conversion matches the colour tags in the file.
    private static func tagColor(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
}
