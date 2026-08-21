import Foundation

@MainActor
final class RecordingPreferences: ObservableObject {
    static let shared = RecordingPreferences()

    @Published var quality: RecordingQuality { didSet { persist() } }
    @Published var frameRate: RecordingFPS { didSet { persist() } }
    @Published var format: RecordingFileFormat { didSet { persist() } }
    @Published var countdown: RecordingCountdown { didSet { persist() } }
    @Published var duration: RecordingDuration { didSet { persist() } }
    @Published var capturesSystemAudio: Bool { didSet { persist() } }
    @Published var capturesMicrophone: Bool { didSet { persist() } }
    @Published var showsCursor: Bool { didSet { persist() } }
    @Published var showsMouseClicks: Bool { didSet { persist() } }

    private enum Key {
        static let quality = "MImago.recording.quality"
        static let frameRate = "MImago.recording.frameRate"
        static let format = "MImago.recording.format"
        static let countdown = "MImago.recording.countdown"
        static let duration = "MImago.recording.duration"
        static let systemAudio = "MImago.recording.systemAudio"
        static let microphone = "MImago.recording.microphone"
        static let cursor = "MImago.recording.cursor"
        static let mouseClicks = "MImago.recording.mouseClicks"
    }

    private init(defaults: UserDefaults = .standard) {
        quality = RecordingQuality(
            rawValue: defaults.string(forKey: Key.quality) ?? ""
        ) ?? .adaptive1080p
        frameRate = RecordingFPS(
            rawValue: defaults.object(forKey: Key.frameRate) as? Int ?? 30
        ) ?? .fps30
        format = RecordingFileFormat(
            rawValue: defaults.string(forKey: Key.format) ?? ""
        ) ?? .mp4
        countdown = RecordingCountdown(
            rawValue: defaults.object(forKey: Key.countdown) as? Int ?? 3
        ) ?? .three
        duration = RecordingDuration(
            rawValue: defaults.object(forKey: Key.duration) as? Int ?? 0
        ) ?? .unlimited
        capturesSystemAudio = defaults.object(forKey: Key.systemAudio) as? Bool ?? true
        capturesMicrophone = defaults.object(forKey: Key.microphone) as? Bool ?? false
        showsCursor = defaults.object(forKey: Key.cursor) as? Bool ?? true
        showsMouseClicks = defaults.object(forKey: Key.mouseClicks) as? Bool ?? true
    }

    var options: RecordingOptions {
        RecordingOptions(
            quality: quality,
            frameRate: frameRate,
            format: format,
            capturesSystemAudio: capturesSystemAudio,
            capturesMicrophone: capturesMicrophone,
            showsCursor: showsCursor,
            showsMouseClicks: showsMouseClicks,
            countdownSeconds: countdown.rawValue,
            maximumDurationMinutes: duration.rawValue
        )
    }

    private func persist(defaults: UserDefaults = .standard) {
        defaults.set(quality.rawValue, forKey: Key.quality)
        defaults.set(frameRate.rawValue, forKey: Key.frameRate)
        defaults.set(format.rawValue, forKey: Key.format)
        defaults.set(countdown.rawValue, forKey: Key.countdown)
        defaults.set(duration.rawValue, forKey: Key.duration)
        defaults.set(capturesSystemAudio, forKey: Key.systemAudio)
        defaults.set(capturesMicrophone, forKey: Key.microphone)
        defaults.set(showsCursor, forKey: Key.cursor)
        defaults.set(showsMouseClicks, forKey: Key.mouseClicks)
    }
}
