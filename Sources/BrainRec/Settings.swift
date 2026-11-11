import Foundation

enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case display, window
    var id: String { rawValue }
    var label: String {
        switch self {
        case .display: return "Full display"
        case .window: return "Single window"
        }
    }
}

enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case h264, hevc
    var id: String { rawValue }
    var label: String {
        switch self {
        case .h264: return "H.264 – most compatible"
        case .hevc: return "HEVC (H.265) – smaller files"
        }
    }

    /// Largest frame the hardware encoder handles reliably.
    var maxWidth: Int { self == .h264 ? 4096 : 8192 }
    var maxHeight: Int { self == .h264 ? 2304 : 4320 }

    /// Scales a size down (keeping aspect ratio) so it fits the codec limits. Result is always even.
    func fit(width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(1.0, Double(maxWidth) / Double(max(width, 1)), Double(maxHeight) / Double(max(height, 1)))
        let w = Int((Double(width) * scale).rounded(.down)) & ~1
        let h = Int((Double(height) * scale).rounded(.down)) & ~1
        return (max(w, 2), max(h, 2))
    }
}

enum QualityPreset: String, Codable, CaseIterable, Identifiable {
    case balanced, high, max
    var id: String { rawValue }
    var label: String {
        switch self {
        case .balanced: return "Balanced"
        case .high: return "High"
        case .max: return "Maximum"
        }
    }
    /// Bits per pixel per frame (H.264 reference; HEVC gets a discount).
    var bitsPerPixel: Double {
        switch self {
        case .balanced: return 0.07
        case .high: return 0.12
        case .max: return 0.20
        }
    }
}

enum CameraResolution: String, Codable, CaseIterable, Identifiable {
    case hd720, hd1080, uhd4k
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hd720: return "720p"
        case .hd1080: return "1080p"
        case .uhd4k: return "4K (if camera supports it)"
        }
    }
    var targetWidth: Int {
        switch self {
        case .hd720: return 1280
        case .hd1080: return 1920
        case .uhd4k: return 3840
        }
    }
}

enum PipCorner: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .topLeft: return "↖"
        case .topRight: return "↗"
        case .bottomLeft: return "↙"
        case .bottomRight: return "↘"
        }
    }
}

enum PipShape: String, Codable, CaseIterable, Identifiable {
    case circle, roundedRect, rectangle
    var id: String { rawValue }
    var label: String {
        switch self {
        case .circle: return "Circle"
        case .roundedRect: return "Rounded"
        case .rectangle: return "Rectangle"
        }
    }
}

struct RecorderSettings: Codable, Equatable {
    // Screen
    var captureScreen = true
    var captureMode: CaptureMode = .display
    var displayID: UInt32 = 0
    var windowID: UInt32 = 0
    var screenFPS = 60
    var showCursor = true

    // Camera
    var cameraEnabled = true
    var cameraID = ""
    var cameraResolution: CameraResolution = .hd1080
    var cameraFPS = 30
    var showFloatingCamera = true

    // Audio
    var micEnabled = true
    var micID = ""
    var micVolume = 1.0
    var systemAudioEnabled = false
    var systemVolume = 0.8

    // Encoding
    var codec: VideoCodec = .h264
    var quality: QualityPreset = .high

    // Picture-in-picture layout (applied when rendering the final MP4)
    var pipCorner: PipCorner = .bottomRight
    var pipShape: PipShape = .circle
    var pipSize = 0.20            // fraction of output width
    var pipMirror = false
    var pipBorder = true
    var pipShadow = true

    // Output
    var countdown = 3
    var keepRawFiles = true
    var outputFolder = ""

    /// Target average bitrate (bits/s) for a given frame size and rate.
    func bitrate(width: Int, height: Int, fps: Int) -> Int {
        let bpp = quality.bitsPerPixel * (codec == .hevc ? 0.62 : 1.0)
        let raw = Double(width) * Double(height) * Double(max(fps, 1)) * bpp
        return Int(min(max(raw, 2_500_000), 120_000_000))
    }
}
