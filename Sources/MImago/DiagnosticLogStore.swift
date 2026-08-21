import AppKit
import Foundation

enum DiagnosticLogLevel: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

final class DiagnosticLogStore: @unchecked Sendable {
    static let shared = DiagnosticLogStore()

    private let queue = DispatchQueue(label: "com.modus.imago.diagnostics")
    private let fileManager = FileManager.default
    private let sessionID = UUID().uuidString.prefix(8)
    private let logURL: URL
    private let rotatedLogURL: URL
    private let maximumLogSize = 2 * 1_024 * 1_024

    private init() {
        let baseDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let logDirectory = baseDirectory
            .appendingPathComponent("M-Imago", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try? fileManager.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )
        logURL = logDirectory.appendingPathComponent("m-imago.log")
        rotatedLogURL = logDirectory.appendingPathComponent("m-imago.previous.log")
    }

    func start() {
        log(
            .info,
            category: "lifecycle",
            "session-start version=\(Self.appVersion) build=\(Self.appBuild)"
        )
    }

    func log(
        _ level: DiagnosticLogLevel = .info,
        category: String,
        _ message: String
    ) {
        let cleanCategory = Self.singleLine(category)
        let cleanMessage = Self.singleLine(message)
        let session = String(sessionID)
        queue.async { [self] in
            rotateIfNeeded()
            let timestamp = ISO8601DateFormatter().string(from: .now)
            let entry = "\(timestamp) [\(level.rawValue)] [\(session)] [\(cleanCategory)] \(cleanMessage)\n"
            guard let data = entry.data(using: .utf8) else { return }
            if !fileManager.fileExists(atPath: logURL.path) {
                fileManager.createFile(atPath: logURL.path, contents: nil)
            }
            do {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                // Logging must never interrupt capture or recording flows.
            }
        }
    }

    func snapshot(maximumCharacters: Int = 60_000) -> String {
        queue.sync { [self] in
            let previous = (try? String(contentsOf: rotatedLogURL, encoding: .utf8)) ?? ""
            let current = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            let combined = [previous, current]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            guard combined.count > maximumCharacters else { return combined }
            return "… earlier log entries omitted …\n" + combined.suffix(maximumCharacters)
        }
    }

    @MainActor
    func feedbackReport(
        description: String,
        contact: String,
        includesDiagnostics: Bool
    ) -> String {
        let screens = NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value ?? 0
            return "display=\(id) frame=\(screen.frame.debugDescription) scale=\(screen.backingScaleFactor)"
        }.joined(separator: "\n")
        let diagnostics = includesDiagnostics ? snapshot() : "未附带"
        let normalizedContact = contact.trimmingCharacters(in: .whitespacesAndNewlines)

        return """
        M · IMAGO FEEDBACK

        问题描述
        \(description.trimmingCharacters(in: .whitespacesAndNewlines))

        联系方式
        \(normalizedContact.isEmpty ? "未填写" : normalizedContact)

        应用
        version=\(Self.appVersion) build=\(Self.appBuild)
        os=\(ProcessInfo.processInfo.operatingSystemVersionString)
        locale=\(Locale.current.identifier)
        timezone=\(TimeZone.current.identifier)

        显示器
        \(screens)

        诊断日志
        \(diagnostics)
        """
    }

    private func rotateIfNeeded() {
        guard let attributes = try? fileManager.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue >= maximumLogSize else { return }
        try? fileManager.removeItem(at: rotatedLogURL)
        try? fileManager.moveItem(at: logURL, to: rotatedLogURL)
    }

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
    }

    private static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "development"
    }
}
