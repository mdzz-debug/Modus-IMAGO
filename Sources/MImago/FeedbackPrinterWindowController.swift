import AppKit
import FormaUI
import SwiftUI

@MainActor
final class FeedbackPrinterWindowController {
    static let shared = FeedbackPrinterWindowController()

    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DiagnosticLogStore.shared.log(.info, category: "feedback", "printer-window-opened")
    }

    private func makeWindow() -> NSWindow {
        let size = CGSize(width: 560, height: 720)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "M · Imago 问题反馈"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.identifier = NSUserInterfaceItemIdentifier("feedback-printer")
        window.isReleasedWhenClosed = false
        window.contentMinSize = size
        window.contentMaxSize = size
        window.center()
        window.contentView = NSHostingView(
            rootView: FormaUIRoot(soundCenter: ApplicationPreferences.shared.soundCenter) {
                FeedbackPrinterWindowView()
            }
        )
        return window
    }
}

private struct FeedbackPrinterWindowView: View {
    @StateObject private var controller = FeedbackController()
    @State private var description = ""
    @State private var contact = ""
    @State private var includesDiagnostics = true

    var body: some View {
        VStack(spacing: 0) {
            header

            FormaScrollView(size: .small, showsTrack: true) {
                VStack(alignment: .leading, spacing: 14) {
                    feedbackForm
                    printerPreview
                    resultAndActions
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 22)
                .frame(maxWidth: 528)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(width: 560, height: 720)
        .background(FormaTheme.canvas.ignoresSafeArea())
        .onDisappear { controller.reset() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "printer.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(FormaTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("问题反馈打印台")
                    .font(.formaBody(18, weight: .bold))
                Text("填写反馈并预览将要附带的诊断资料")
                    .font(.formaBody(11))
                    .foregroundStyle(FormaTheme.inkSoft)
            }

            Spacer()
            FormaBadge("SIMULATION", tone: .warning, size: .small)
        }
        .padding(.leading, 22)
        .padding(.trailing, 20)
        .padding(.top, 34)
        .padding(.bottom, 14)
        .background(FormaTheme.surface)
        .overlay(alignment: .bottom) {
            FormaSectionDivider()
        }
    }

    private var feedbackForm: some View {
        FormaCard(
            title: "反馈内容",
            subtitle: "当前版本只完成交互，不会连接邮箱或上传服务",
            size: .small
        ) {
            VStack(alignment: .leading, spacing: 12) {
                FormaTextArea(
                    "问题描述",
                    text: $description,
                    characterLimit: 800,
                    size: .small
                )

                FormaTextField(
                    "联系方式（可选）",
                    text: $contact,
                    placeholder: "邮箱或其他联系方式",
                    size: .small
                )

                FormaSwitch(
                    "附带诊断日志",
                    detail: "包含版本、系统、显示器信息和应用运行日志",
                    onSystemImage: "doc.text.fill",
                    offSystemImage: "doc.text",
                    isOn: $includesDiagnostics,
                    size: .small
                )
            }
        }
    }

    private var printerPreview: some View {
        FormaCard(
            title: "打印预览",
            subtitle: "纸张进料代表日志和反馈正在打包",
            size: .small
        ) {
            FormaPaperFeedView(
                progress: controller.printProgress,
                isActive: controller.isSending,
                style: .receipt,
                paperInset: 14
            ) {
                feedbackPaper
            }
            .frame(height: 184)
        }
    }

    private var resultAndActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let resultMessage = controller.resultMessage {
                FormaInlineMessage(
                    controller.resultIsError ? "反馈未提交" : "模拟发送完成",
                    detail: resultMessage,
                    tone: controller.resultIsError ? .error : .success
                )
            }

            HStack(spacing: 10) {
                FormaButton(
                    "清空",
                    systemImage: "arrow.counterclockwise",
                    role: .secondary,
                    size: .small
                ) {
                    controller.reset()
                    description = ""
                    contact = ""
                    includesDiagnostics = true
                }

                Spacer()

                FormaButton(
                    "导出报告",
                    systemImage: "square.and.arrow.down",
                    role: .secondary,
                    size: .small
                ) {
                    controller.exportReport(
                        description: description,
                        contact: contact,
                        includesDiagnostics: includesDiagnostics
                    )
                }

                FormaButton(
                    "打印并发送",
                    systemImage: "printer.fill",
                    size: .small,
                    isLoading: controller.isSending
                ) {
                    controller.simulateSend(
                        description: description,
                        contact: contact,
                        includesDiagnostics: includesDiagnostics
                    )
                }
            }
        }
    }

    private var feedbackPaper: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("M · IMAGO / FEEDBACK")
                    .font(.formaLabel(9))
                    .tracking(1)
                Spacer()
                FormaBadge(
                    includesDiagnostics ? "LOG ON" : "LOG OFF",
                    tone: .info,
                    size: .small
                )
            }

            Text(description.isEmpty ? "请填写问题描述…" : description)
                .font(.formaBody(11, weight: .medium))
                .foregroundStyle(description.isEmpty ? FormaTheme.inkSoft : FormaTheme.ink)
                .lineLimit(4)

            Spacer(minLength: 0)

            HStack {
                Text(contact.isEmpty ? "CONTACT: NOT PROVIDED" : "CONTACT: PROVIDED")
                Spacer()
                Text("NETWORK: OFFLINE")
            }
            .font(.formaLabel(7))
            .foregroundStyle(FormaTheme.inkSoft)
        }
        .padding(14)
        .frame(height: 148)
    }
}
