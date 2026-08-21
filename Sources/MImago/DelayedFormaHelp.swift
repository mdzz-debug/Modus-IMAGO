import FormaUI
import SwiftUI

enum DelayedFormaHelpPlacement {
    case above
    case below
}

private struct DelayedFormaHelpModifier: ViewModifier {
    let title: String
    let detail: String
    let placement: DelayedFormaHelpPlacement
    let delay: Duration

    @State private var isHovering = false
    @State private var isPresented = false
    @State private var presentationTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: placement == .above ? .top : .bottom) {
                if isPresented {
                    FormaFloatingCard(padding: 9) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title)
                                .font(.formaBody(11, weight: .bold))
                                .foregroundStyle(FormaColor.ink)
                            Text(detail)
                                .font(.formaBody(10))
                                .foregroundStyle(FormaColor.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: 208, alignment: .leading)
                    }
                    .fixedSize()
                    .offset(y: placement == .above ? -72 : 72)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(10_000)
                }
            }
            .zIndex(isPresented ? 10_000 : 0)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    guard !isHovering else { return }
                    isHovering = true
                    presentationTask?.cancel()
                    presentationTask = Task { @MainActor in
                        do {
                            try await Task.sleep(for: delay)
                        } catch {
                            return
                        }
                        guard !Task.isCancelled, isHovering else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            isPresented = true
                        }
                    }
                case .ended:
                    isHovering = false
                    presentationTask?.cancel()
                    presentationTask = nil
                    if isPresented {
                        withAnimation(.easeOut(duration: 0.09)) {
                            isPresented = false
                        }
                    }
                }
            }
            .onDisappear {
                presentationTask?.cancel()
                presentationTask = nil
            }
    }
}

extension View {
    func delayedFormaHelp(
        _ title: String,
        detail: String,
        placement: DelayedFormaHelpPlacement = .above,
        delay: Duration = .seconds(1)
    ) -> some View {
        modifier(
            DelayedFormaHelpModifier(
                title: title,
                detail: detail,
                placement: placement,
                delay: delay
            )
        )
    }
}
