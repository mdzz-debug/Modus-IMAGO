import AppKit
import Foundation

enum ScreenshotCompletion: String, CaseIterable, CustomStringConvertible {
    case copy
    case save
    case copyAndSave

    var description: String {
        switch self {
        case .copy: "复制到剪贴板"
        case .save: "保存到文件"
        case .copyAndSave: "复制并保存"
        }
    }

    var needsDirectory: Bool { self != .copy }
}

@MainActor
final class CapturePreferences: ObservableObject {
    static let shared = CapturePreferences()

    @Published var screenshotCompletion: ScreenshotCompletion = .copy
    @Published var thumbnailDuration: Double = 6
    @Published private(set) var saveDirectory: URL?

    private let directoryKey = "MImago.saveDirectory"
    private let thumbnailDurationKey = "MImago.thumbnailDuration"

    private init() {
        if let path = UserDefaults.standard.string(forKey: directoryKey) {
            saveDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
        if UserDefaults.standard.object(forKey: thumbnailDurationKey) != nil {
            thumbnailDuration = UserDefaults.standard.double(forKey: thumbnailDurationKey)
        }
    }

    func chooseSaveDirectory(then action: @escaping () -> Void = {}) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "使用此文件夹"
        panel.message = "截图和录屏会共用此保存位置。"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.saveDirectory = url
                UserDefaults.standard.set(url.path, forKey: self?.directoryKey ?? "")
                action()
            }
        }
    }

    func setThumbnailDuration(_ duration: Double) {
        thumbnailDuration = min(6, max(0, duration))
        UserDefaults.standard.set(thumbnailDuration, forKey: thumbnailDurationKey)
    }

    func stepThumbnailDuration(by delta: Int) {
        setThumbnailDuration(thumbnailDuration + Double(delta))
    }
}
