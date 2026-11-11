import AVFoundation
import CoreMedia

enum TrackWriterError: LocalizedError {
    case cannotAddInput(String)
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotAddInput(let what): return "Could not set up the \(what) encoder."
        case .startFailed(let why): return "Could not start writing the file: \(why)"
        }
    }
}

/// Writes one raw file (MP4 or M4A) from live capture buffers using hardware encoding.
/// Thread-safe: capture callbacks from different queues can call append* concurrently.
final class TrackWriter {
    struct VideoConfig {
        var width: Int
        var height: Int
        var codec: VideoCodec
        var bitrate: Int
        var fps: Int
    }

    struct AudioConfig {
        var channels: Int
        var bitrate: Int
    }

    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput?
    private let audioInput: AVAssetWriterInput?
    private let clock: RecordingClock
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var lastVideoPTS = CMTime.invalid
    private var lastAudioPTS = CMTime.invalid
    private(set) var droppedVideoFrames = 0

    init(url: URL, fileType: AVFileType, clock: RecordingClock, video: VideoConfig?, audio: AudioConfig?) throws {
        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: fileType)
        var vIn: AVAssetWriterInput?
        var aIn: AVAssetWriterInput?

        if let v = video {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: v.bitrate,
                AVVideoExpectedSourceFrameRateKey: v.fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0
            ]
            if v.codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
                compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
            }
            let colorProps: [String: Any] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
            let settings: [String: Any] = [
                AVVideoCodecKey: v.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
                AVVideoWidthKey: v.width,
                AVVideoHeightKey: v.height,
                AVVideoColorPropertiesKey: colorProps,
                AVVideoCompressionPropertiesKey: compression
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard w.canAdd(input) else { throw TrackWriterError.cannotAddInput("video") }
            w.add(input)
            vIn = input
        }

        if let a = audio {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: a.channels,
                AVEncoderBitRateKey: a.bitrate
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard w.canAdd(input) else { throw TrackWriterError.cannotAddInput("audio") }
            w.add(input)
            aIn = input
        }

        self.url = url
        self.clock = clock
        self.writer = w
        self.videoInput = vIn
        self.audioInput = aIn
    }

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        guard writer.startWriting() else {
            throw TrackWriterError.startFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: CMTime.zero)
        started = true
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let pts = clock.map(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) else { return }
        lock.lock(); defer { lock.unlock() }
        guard started, !finished, let input = videoInput, writer.status == .writing else { return }
        if lastVideoPTS.isValid, CMTimeCompare(pts, lastVideoPTS) <= 0 {
            droppedVideoFrames += 1
            return
        }
        guard input.isReadyForMoreMediaData else {
            droppedVideoFrames += 1
            return
        }
        guard let out = Self.retimed(sampleBuffer, to: pts) else { return }
        if input.append(out) { lastVideoPTS = pts }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let pts = clock.map(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) else { return }
        lock.lock(); defer { lock.unlock() }
        guard started, !finished, let input = audioInput, writer.status == .writing else { return }
        if lastAudioPTS.isValid, CMTimeCompare(pts, lastAudioPTS) < 0 { return }
        guard input.isReadyForMoreMediaData else { return }
        guard let out = Self.retimed(sampleBuffer, to: pts) else { return }
        if input.append(out) { lastAudioPTS = pts }
    }

    /// Finishes the file. `endTime` is the length on the file timeline (from RecordingClock.stop()).
    /// Returns an error if the file could not be completed.
    func finish(endTime: CMTime) async -> Error? {
        guard beginFinish(endTime: endTime) else { return nil }
        await writer.finishWriting()
        return writer.status == .failed ? writer.error : nil
    }

    /// Locked, synchronous part of finishing. Returns false if there is nothing to finish.
    private func beginFinish(endTime: CMTime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard started, !finished else { return false }
        finished = true
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        if writer.status == .writing {
            writer.endSession(atSourceTime: endTime)
        }
        return true
    }

    // MARK: - Helpers

    /// Copies a sample buffer with a new presentation time (all timing entries shifted by the same delta).
    private static func retimed(_ sb: CMSampleBuffer, to newPTS: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0 else { return nil }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count) == noErr else {
            return nil
        }
        let delta = CMTimeSubtract(newPTS, CMSampleBufferGetPresentationTimeStamp(sb))
        for i in infos.indices {
            infos[i].presentationTimeStamp = CMTimeAdd(infos[i].presentationTimeStamp, delta)
            if infos[i].decodeTimeStamp.isValid {
                infos[i].decodeTimeStamp = CMTimeAdd(infos[i].decodeTimeStamp, delta)
            }
        }
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sb,
            sampleTimingEntryCount: count,
            sampleTimingArray: &infos,
            sampleBufferOut: &out
        )
        return status == noErr ? out : nil
    }
}
