import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class FeedbackController: ObservableObject {
    @Published private(set) var isSending = false
    @Published private(set) var printProgress = 0.0
    @Published private(set) var resultMessage: String?
    @Published private(set) var resultIsError = false

    private var sendTask: Task<Void, Never>?

    func simulateSend(
        description: String,
        contact: String,
        includesDiagnostics: Bool
    ) {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resultIsError = true
            resultMessage = "请先填写问题描述。"
            return
        }

        sendTask?.cancel()
        isSending = true
        printProgress = 0
        resultMessage = nil
        resultIsError = false
        DiagnosticLogStore.shared.log(
            .info,
            category: "feedback",
            "simulation-start diagnostics=\(includesDiagnostics) description-length=\(trimmed.count)"
        )

        sendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for step in 1...18 {
                guard !Task.isCancelled else { return }
                printProgress = Double(step) / 18
                do {
                    try await Task.sleep(for: .milliseconds(55))
                } catch {
                    return
                }
            }

            _ = DiagnosticLogStore.shared.feedbackReport(
                description: trimmed,
                contact: contact,
                includesDiagnostics: includesDiagnostics
            )
            isSending = false
            resultMessage = "打印交互已完成；当前版本不会真的上传或发送邮件。"
            DiagnosticLogStore.shared.log(
                .info,
                category: "feedback",
                "simulation-finished without-network-upload"
            )
        }
    }

    func exportReport(
        description: String,
        contact: String,
        includesDiagnostics: Bool
    ) {
        let report = DiagnosticLogStore.shared.feedbackReport(
            description: description.isEmpty ? "未填写问题描述" : description,
            contact: contact,
            includesDiagnostics: includesDiagnostics
        )
        let panel = NSSavePanel()
        panel.title = "导出 M · Imago 反馈报告"
        panel.message = "报告包含你填写的内容、应用环境和诊断日志。"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "M-Imago-Feedback-\(Self.timestamp()).txt"

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try report.write(to: destination, atomically: true, encoding: .utf8)
            resultIsError = false
            resultMessage = "反馈报告已导出。"
            DiagnosticLogStore.shared.log(
                .info,
                category: "feedback",
                "report-exported name=\(destination.lastPathComponent)"
            )
        } catch {
            resultIsError = true
            resultMessage = "导出失败：\(error.localizedDescription)"
            DiagnosticLogStore.shared.log(
                .error,
                category: "feedback",
                "report-export-failed error=\(error.localizedDescription)"
            )
        }
    }

    func reset() {
        sendTask?.cancel()
        sendTask = nil
        isSending = false
        printProgress = 0
        resultMessage = nil
        resultIsError = false
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }
}
