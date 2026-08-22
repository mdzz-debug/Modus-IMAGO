import AppKit
import Foundation

@MainActor
final class UpdateController {
    static let shared = UpdateController()

    private struct GitHubRelease: Decodable {
        let tagName: String
        let name: String?
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case draft
            case prerelease
        }
    }

    private struct ReleaseVersion: Comparable {
        let components: [Int]

        init(_ rawValue: String) {
            let normalized = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            components = normalized.split(separator: ".").map { component in
                Int(component.prefix { $0.isNumber }) ?? 0
            }
        }

        static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
            let count = max(lhs.components.count, rhs.components.count)
            for index in 0..<count {
                let left = index < lhs.components.count ? lhs.components[index] : 0
                let right = index < rhs.components.count ? rhs.components[index] : 0
                if left != right { return left < right }
            }
            return false
        }
    }

    private let latestReleaseURL = URL(
        string: "https://api.github.com/repos/mdzz-debug/Modus-IMAGO/releases/latest"
    )!
    private var isChecking = false

    private init() {}

    func checkForUpdates() {
        guard !isChecking else { return }
        isChecking = true
        DiagnosticLogStore.shared.log(
            .info,
            category: "update",
            "manual-update-check-requested"
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isChecking = false }
            do {
                var request = URLRequest(url: latestReleaseURL)
                request.setValue(
                    "application/vnd.github+json",
                    forHTTPHeaderField: "Accept"
                )
                request.setValue(
                    "M-Imago/\(currentVersion)",
                    forHTTPHeaderField: "User-Agent"
                )
                let (data, response) = try await URLSession.shared.data(
                    for: request
                )
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw UpdateError.invalidResponse
                }
                if httpResponse.statusCode == 404 {
                    showNoPublishedReleaseAlert()
                    return
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    throw UpdateError.httpStatus(httpResponse.statusCode)
                }
                let release = try JSONDecoder().decode(
                    GitHubRelease.self,
                    from: data
                )
                guard !release.draft, !release.prerelease else {
                    showNoPublishedReleaseAlert()
                    return
                }
                showResult(for: release)
            } catch {
                DiagnosticLogStore.shared.log(
                    .warning,
                    category: "update",
                    "manual-update-check-failed error=\(error.localizedDescription)"
                )
                showFailureAlert(error)
            }
        }
    }

    private var currentVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.0"
    }

    private func showResult(for release: GitHubRelease) {
        let latestVersion = release.tagName.trimmingCharacters(
            in: CharacterSet(charactersIn: "vV")
        )
        if ReleaseVersion(currentVersion) < ReleaseVersion(latestVersion) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "发现新版本 \(latestVersion)"
            alert.informativeText = release.name.map {
                "当前版本：\(currentVersion)\n最新版本：\($0)"
            } ?? "当前版本：\(currentVersion)"
            alert.addButton(withTitle: "打开下载页面")
            alert.addButton(withTitle: "稍后")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(release.htmlURL)
            }
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "已经是最新版本"
        alert.informativeText = "当前版本：\(currentVersion)"
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showNoPublishedReleaseAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "暂时没有可用更新"
        alert.informativeText = "GitHub Releases 中还没有正式发布版本。"
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showFailureAlert(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "检查更新失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private enum UpdateError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                "更新服务器返回了无效响应。"
            case let .httpStatus(statusCode):
                "更新服务器返回错误（HTTP \(statusCode)）。"
            }
        }
    }
}
