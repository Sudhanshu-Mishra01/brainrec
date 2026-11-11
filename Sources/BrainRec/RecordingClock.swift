import CoreMedia
import Foundation

/// One shared timeline for every capture source (screen, system audio, camera, mic).
///
/// All sources stamp their samples with the Mac's host clock. This class converts those
/// stamps into "file time" (0 = the moment recording started, pauses removed), so every
/// raw file starts at 0 and stays in sync with the others.
final class RecordingClock {
    private let lock = NSLock()
    private var t0 = CMTime.invalid
    private var stopTime = CMTime.invalid
    private var pauses: [(start: CMTime, end: CMTime)] = []
    private var openPauseStart: CMTime?

    static func hostNow() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    var isStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return t0.isValid
    }

    /// Starts the timeline. Ignored if already started.
    func start(at time: CMTime = RecordingClock.hostNow()) {
        lock.lock(); defer { lock.unlock() }
        guard !t0.isValid else { return }
        t0 = time
    }

    func pause() {
        lock.lock(); defer { lock.unlock() }
        guard t0.isValid, openPauseStart == nil, !stopTime.isValid else { return }
        openPauseStart = RecordingClock.hostNow()
    }

    func resume() {
        lock.lock(); defer { lock.unlock() }
        guard let start = openPauseStart else { return }
        pauses.append((start: start, end: RecordingClock.hostNow()))
        openPauseStart = nil
    }

    /// Stops the timeline. Returns the final length on the file timeline.
    @discardableResult
    func stop() -> CMTime {
        lock.lock(); defer { lock.unlock() }
        let now = RecordingClock.hostNow()
        if let start = openPauseStart {
            pauses.append((start: start, end: now))
            openPauseStart = nil
        }
        stopTime = now
        return durationLocked(until: now)
    }

    /// Seconds of recorded material so far (pauses excluded).
    func elapsed() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        let end = stopTime.isValid ? stopTime : RecordingClock.hostNow()
        return durationLocked(until: end).seconds
    }

    /// Converts a host-clock timestamp into file time. Returns nil if the sample must be dropped
    /// (before start, during a pause, or after stop).
    func map(_ pts: CMTime) -> CMTime? {
        lock.lock(); defer { lock.unlock() }
        guard t0.isValid, pts.isValid, CMTimeCompare(pts, t0) >= 0 else { return nil }
        if stopTime.isValid, CMTimeCompare(pts, stopTime) > 0 { return nil }
        var offset = t0
        for p in pauses {
            if CMTimeCompare(pts, p.start) >= 0 && CMTimeCompare(pts, p.end) < 0 { return nil }
            if CMTimeCompare(pts, p.end) >= 0 {
                offset = CMTimeAdd(offset, CMTimeSubtract(p.end, p.start))
            }
        }
        if let open = openPauseStart, CMTimeCompare(pts, open) >= 0 { return nil }
        return CMTimeSubtract(pts, offset)
    }

    private func durationLocked(until end: CMTime) -> CMTime {
        guard t0.isValid else { return CMTime.zero }
        var d = CMTimeSubtract(end, t0)
        for p in pauses { d = CMTimeSubtract(d, CMTimeSubtract(p.end, p.start)) }
        if let open = openPauseStart { d = CMTimeSubtract(d, CMTimeSubtract(end, open)) }
        return CMTimeMaximum(d, CMTime.zero)
    }
}
