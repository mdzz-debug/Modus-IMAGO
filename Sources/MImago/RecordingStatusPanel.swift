import AppKit
import FormaUI
import SwiftUI

@MainActor
enum RecordingStatusPanel {
    private static var panel: NSPanel?

    static func present(onStop: @escaping () -> Void) {
        dismiss()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let size = CGSize(width: 320, height: 86)
        let visibleFrame = screen.visibleFrame
        let origin = CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + 24
        )
        let panel = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.contentView = NSHostingView(rootView: FormaUIRoot(soundCenter: ApplicationPreferences.shared.soundCenter) {
            RecordingStatusView(startDate: .now, onStop: onStop)
        })
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    static func dismiss() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

private struct RecordingStatusView: View {
    let startDate: Date
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(FormaTheme.accent.opacity(0.14))
                    .frame(width: 42, height: 42)
                Circle()
                    .fill(FormaTheme.accent)
                    .frame(width: 14, height: 14)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("M · IMAGO 录制中")
                    .font(.formaLabel(10))
                    .tracking(0.8)
                TimelineView(.periodic(from: startDate, by: 1)) { context in
                    Text(elapsedText(at: context.date))
                        .font(.system(size: 19, weight: .bold, design: .monospaced))
                        .foregroundStyle(FormaTheme.ink)
                }
            }

            Spacer(minLength: 8)

            FormaButton(
                "停止并保存",
                systemImage: "stop.fill",
                role: .dark,
                size: .small,
                depth: .raised
            ) {
                onStop()
            }
            .frame(width: 126)
        }
        .padding(14)
        .frame(width: 320, height: 86)
        .background {
            RoundedRectangle(cornerRadius: FormaCornerRadius.panel, style: .continuous)
                .fill(FormaTheme.canvas)
        }
        .overlay {
            RoundedRectangle(cornerRadius: FormaCornerRadius.panel, style: .continuous)
                .stroke(FormaTheme.lineStrong, lineWidth: 1)
        }
    }

    private func elapsedText(at date: Date) -> String {
        let total = max(0, Int(date.timeIntervalSince(startDate)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
