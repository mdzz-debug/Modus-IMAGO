import AppKit
import FormaUI
import SwiftUI

struct CaptureWindowCandidate: Sendable, Hashable {
    let windowID: CGWindowID
    let processID: pid_t
    let frame: CGRect
}

enum CaptureAnnotationKind: Sendable, Hashable {
    case rectangle
    case ellipse
    case line
    case arrow
    case text
    case mosaic
    case highlight
}

enum CaptureAnnotationColor: String, CaseIterable, Sendable, Hashable {
    case red
    case orange
    case yellow
    case green
    case blue
    case white
    case black

    var swiftUIColor: Color {
        switch self {
        case .red: Color(red: 0.96, green: 0.20, blue: 0.18)
        case .orange: Color(red: 1.00, green: 0.49, blue: 0.12)
        case .yellow: Color(red: 1.00, green: 0.82, blue: 0.12)
        case .green: Color(red: 0.20, green: 0.72, blue: 0.38)
        case .blue: Color(red: 0.18, green: 0.48, blue: 0.90)
        case .white: .white
        case .black: Color(red: 0.08, green: 0.07, blue: 0.06)
        }
    }

    var cgColor: CGColor {
        switch self {
        case .red: CGColor(red: 0.96, green: 0.20, blue: 0.18, alpha: 1)
        case .orange: CGColor(red: 1.00, green: 0.49, blue: 0.12, alpha: 1)
        case .yellow: CGColor(red: 1.00, green: 0.82, blue: 0.12, alpha: 1)
        case .green: CGColor(red: 0.20, green: 0.72, blue: 0.38, alpha: 1)
        case .blue: CGColor(red: 0.18, green: 0.48, blue: 0.90, alpha: 1)
        case .white: CGColor(gray: 1, alpha: 1)
        case .black: CGColor(gray: 0.08, alpha: 1)
        }
    }
}

enum CaptureAnnotationThickness: CGFloat, CaseIterable, Sendable, Hashable, CustomStringConvertible {
    case thin = 2
    case medium = 4
    case thick = 7

    var description: String {
        switch self {
        case .thin: "细"
        case .medium: "中"
        case .thick: "粗"
        }
    }

    var textFontSize: CGFloat {
        switch self {
        case .thin: 15
        case .medium: 19
        case .thick: 25
        }
    }

    var mosaicWidth: CGFloat {
        switch self {
        case .thin: 16
        case .medium: 28
        case .thick: 44
        }
    }
}

enum CaptureTextSize: CGFloat, CaseIterable, Sendable, Hashable, CustomStringConvertible {
    case small = 15
    case medium = 19
    case large = 25

    var description: String {
        switch self {
        case .small: "小"
        case .medium: "中"
        case .large: "大"
        }
    }
}

enum CaptureTextBackground: String, CaseIterable, Sendable, Hashable {
    case none
    case black
    case white
    case red
    case orange
    case yellow
    case green
    case blue

    var swiftUIColor: Color? {
        switch self {
        case .none: nil
        case .black: Color.black.opacity(0.82)
        case .white: Color.white.opacity(0.88)
        case .red: CaptureAnnotationColor.red.swiftUIColor.opacity(0.88)
        case .orange: CaptureAnnotationColor.orange.swiftUIColor.opacity(0.88)
        case .yellow: CaptureAnnotationColor.yellow.swiftUIColor.opacity(0.88)
        case .green: CaptureAnnotationColor.green.swiftUIColor.opacity(0.88)
        case .blue: CaptureAnnotationColor.blue.swiftUIColor.opacity(0.88)
        }
    }

    var cgColor: CGColor? {
        switch self {
        case .none: nil
        case .black: CGColor(gray: 0, alpha: 0.82)
        case .white: CGColor(gray: 1, alpha: 0.88)
        case .red: CaptureAnnotationColor.red.cgColor.copy(alpha: 0.88)
        case .orange: CaptureAnnotationColor.orange.cgColor.copy(alpha: 0.88)
        case .yellow: CaptureAnnotationColor.yellow.cgColor.copy(alpha: 0.88)
        case .green: CaptureAnnotationColor.green.cgColor.copy(alpha: 0.88)
        case .blue: CaptureAnnotationColor.blue.cgColor.copy(alpha: 0.88)
        }
    }
}

struct CaptureAnnotation: Sendable, Hashable {
    let kind: CaptureAnnotationKind
    let start: CGPoint
    let end: CGPoint
    let color: CaptureAnnotationColor
    let thickness: CaptureAnnotationThickness
    let text: String?
    let textSize: CaptureTextSize?
    let textBackground: CaptureTextBackground?
    let points: [CGPoint]
}

enum CaptureSelectionTarget: Sendable, Hashable {
    case window(windowID: CGWindowID, processID: pid_t)
    case region(displayID: CGDirectDisplayID, normalizedRect: CGRect)
}

struct CaptureSelectionResult: Sendable, Hashable {
    let target: CaptureSelectionTarget
    let annotations: [CaptureAnnotation]
    let action: CaptureResultAction
}

enum CaptureResultAction: Sendable, Hashable {
    case finish
    case pin
    case longScreenshot
}

private enum CaptureOverlayPurpose: Sendable, Hashable {
    case screenshot
    case recording
}

private final class CaptureOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onCancelRequested: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            onCancelRequested?()
            return
        }
        if event.type == .leftMouseDown || event.type == .rightMouseDown,
           !isKeyWindow {
            makeKeyAndOrderFront(nil)
        }
        if event.type == .keyDown,
           event.keyCode == 51 || event.keyCode == 117 {
            // Let the field editor handle Backspace/Delete while text is being
            // entered. Otherwise the keys delete the selected annotation.
            if firstResponder is NSTextView {
                super.sendEvent(event)
            } else {
                NotificationCenter.default.post(name: .deleteSelectedCaptureAnnotation, object: nil)
            }
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancelRequested?()
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // NSWindow normally keeps panels inside visibleFrame, which removes the
        // menu bar/notch and Dock from a screen-sized overlay. Keeping the full
        // display frame makes SwiftUI selection coordinates map one-to-one to
        // ScreenCaptureKit source coordinates.
        frameRect
    }
}

private extension Notification.Name {
    static let deleteSelectedCaptureAnnotation = Notification.Name(
        "MImago.deleteSelectedCaptureAnnotation"
    )
}

@MainActor
private final class CaptureOverlaySession: ObservableObject {
    @Published private(set) var selectedDisplayID: CGDirectDisplayID?

    func claim(_ displayID: CGDirectDisplayID) -> Bool {
        if let selectedDisplayID {
            return selectedDisplayID == displayID
        }
        selectedDisplayID = displayID
        DiagnosticLogStore.shared.log(
            .info,
            category: "capture-selection",
            "display-claimed id=\(displayID)"
        )
        return true
    }

    func release(_ displayID: CGDirectDisplayID) {
        guard selectedDisplayID == displayID else { return }
        selectedDisplayID = nil
    }
}

@MainActor
enum FreeSelectionOverlay {
    private static var activePanels: [CGDirectDisplayID: NSPanel] = [:]
    private static var escapeMonitor: Any?
    private static var cancelAction: (() -> Void)?
    private static var watchdogTask: Task<Void, Never>?

    static func present(
        on screens: [NSScreen],
        windowCandidatesByDisplayID: [CGDirectDisplayID: [CaptureWindowCandidate]],
        initialPointerGlobalLocation: CGPoint,
        onConfirm: @escaping (CaptureSelectionResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        present(
            purpose: .screenshot,
            screens: screens,
            windowCandidatesByDisplayID: windowCandidatesByDisplayID,
            initialPointerGlobalLocation: initialPointerGlobalLocation,
            onConfirm: { result, _ in onConfirm(result) },
            onCancel: onCancel
        )
    }

    static func presentRecording(
        on screens: [NSScreen],
        windowCandidatesByDisplayID: [CGDirectDisplayID: [CaptureWindowCandidate]],
        initialPointerGlobalLocation: CGPoint,
        onConfirm: @escaping (CaptureSelectionResult, RecordingOptions) -> Void,
        onCancel: @escaping () -> Void
    ) {
        present(
            purpose: .recording,
            screens: screens,
            windowCandidatesByDisplayID: windowCandidatesByDisplayID,
            initialPointerGlobalLocation: initialPointerGlobalLocation,
            onConfirm: { result, options in
                guard let options else { return }
                onConfirm(result, options)
            },
            onCancel: onCancel
        )
    }

    private static func present(
        purpose: CaptureOverlayPurpose,
        screens: [NSScreen],
        windowCandidatesByDisplayID: [CGDirectDisplayID: [CaptureWindowCandidate]],
        initialPointerGlobalLocation: CGPoint,
        onConfirm: @escaping (CaptureSelectionResult, RecordingOptions?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        dismiss()
        guard !screens.isEmpty else { return }
        cancelAction = onCancel
        let session = CaptureOverlaySession()
        DiagnosticLogStore.shared.log(
            .info,
            category: "capture-overlay",
            "present purpose=\(purpose) displays=\(screens.count)"
        )

        var initialPanel: NSPanel?
        for screen in screens {
            guard let rawDisplayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { continue }
            let displayID = CGDirectDisplayID(rawDisplayID.uint32Value)
            let initialPointerLocation = CGPoint(
                x: initialPointerGlobalLocation.x - screen.frame.minX,
                y: screen.frame.maxY - initialPointerGlobalLocation.y
            )

            let panel = CaptureOverlayPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.acceptsMouseMovedEvents = true
            panel.onCancelRequested = {
                Task { @MainActor in cancel() }
            }
            let hostingView = NSHostingView(rootView: FormaUIRoot(soundCenter: ApplicationPreferences.shared.soundCenter) {
                FreeSelectionOverlayView(
                    purpose: purpose,
                    displayID: displayID,
                    session: session,
                    windowCandidates: windowCandidatesByDisplayID[displayID] ?? [],
                    initialPointerLocation: initialPointerLocation,
                    onConfirm: { result, options in
                        DiagnosticLogStore.shared.log(
                            .info,
                            category: "capture-overlay",
                            "confirmed display=\(displayID) target=\(result.target.logDescription)"
                        )
                        dismiss()
                        onConfirm(result, options)
                    },
                    onCancel: {
                        cancel()
                    }
                )
            })
            hostingView.frame = CGRect(origin: .zero, size: screen.frame.size)
            hostingView.autoresizingMask = [.width, .height]
            panel.contentView = hostingView
            // Assigning an NSHostingView may cause AppKit to refit a panel to
            // its visible screen area. Reassert each complete display frame.
            panel.setFrame(screen.frame, display: false)
            activePanels[displayID] = panel
            if screen.frame.contains(initialPointerGlobalLocation) {
                initialPanel = panel
            }
        }

        guard !activePanels.isEmpty else {
            cancelAction = nil
            return
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in cancel() }
            return nil
        }
        watchdogTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard !activePanels.isEmpty else { return }
            DiagnosticLogStore.shared.log(
                .warning,
                category: "capture-overlay",
                "overlay-remains-active-after-30-seconds panels=\(activePanels.count)"
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        for panel in activePanels.values where panel !== initialPanel {
            panel.orderFrontRegardless()
        }
        (initialPanel ?? activePanels.values.first)?.makeKeyAndOrderFront(nil)
    }

    static func cancel() {
        guard let action = cancelAction else { return }
        DiagnosticLogStore.shared.log(.info, category: "capture-overlay", "cancelled")
        dismiss()
        action()
    }

    static func dismiss() {
        watchdogTask?.cancel()
        watchdogTask = nil
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        activePanels.values.forEach {
            ($0 as? CaptureOverlayPanel)?.onCancelRequested = nil
            $0.orderOut(nil)
            $0.close()
        }
        activePanels.removeAll()
        cancelAction = nil
        NSCursor.arrow.set()
    }
}

private extension CaptureSelectionTarget {
    var logDescription: String {
        switch self {
        case let .window(windowID, processID):
            "window id=\(windowID) pid=\(processID)"
        case let .region(displayID, normalizedRect):
            "region display=\(displayID) rect=\(normalizedRect.debugDescription)"
        }
    }
}

private enum CaptureOverlayTool: Sendable, Hashable {
    case rectangle
    case ellipse
    case line
    case arrow
    case text
    case mosaic
    case highlight
}

private enum ConfirmedOverlaySelection: Sendable, Hashable {
    case window(CaptureWindowCandidate)
    case region(CGRect)

    var frame: CGRect {
        switch self {
        case let .window(candidate): candidate.frame
        case let .region(rect): rect
        }
    }

    var isRegion: Bool {
        if case .region = self { return true }
        return false
    }

    var isWindow: Bool {
        if case .window = self { return true }
        return false
    }
}

private enum SelectionResizeHandle: CaseIterable, Sendable, Hashable {
    case northWest, north, northEast
    case west, east
    case southWest, south, southEast

    func position(in rect: CGRect) -> CGPoint {
        switch self {
        case .northWest: CGPoint(x: rect.minX, y: rect.minY)
        case .north: CGPoint(x: rect.midX, y: rect.minY)
        case .northEast: CGPoint(x: rect.maxX, y: rect.minY)
        case .west: CGPoint(x: rect.minX, y: rect.midY)
        case .east: CGPoint(x: rect.maxX, y: rect.midY)
        case .southWest: CGPoint(x: rect.minX, y: rect.maxY)
        case .south: CGPoint(x: rect.midX, y: rect.maxY)
        case .southEast: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}

private struct ScreenshotToolbarLayout {
    let toolbarPosition: CGPoint
    let stylePanelPosition: CGPoint
}

private struct OverlayAnnotation: Identifiable, Sendable, Hashable {
    let id: UUID
    var kind: CaptureAnnotationKind
    var start: CGPoint
    var end: CGPoint
    var color: CaptureAnnotationColor
    var thickness: CaptureAnnotationThickness
    var text: String?
    var textSize: CaptureTextSize?
    var textBackground: CaptureTextBackground?
    var points: [CGPoint]

    init(
        id: UUID = UUID(),
        kind: CaptureAnnotationKind,
        start: CGPoint,
        end: CGPoint,
        color: CaptureAnnotationColor,
        thickness: CaptureAnnotationThickness,
        text: String?,
        textSize: CaptureTextSize? = nil,
        textBackground: CaptureTextBackground? = nil,
        points: [CGPoint] = []
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.color = color
        self.thickness = thickness
        self.text = text
        self.textSize = textSize
        self.textBackground = textBackground
        self.points = points
    }
}

private struct FreeSelectionOverlayView: View {
    let purpose: CaptureOverlayPurpose
    let displayID: CGDirectDisplayID
    @ObservedObject var session: CaptureOverlaySession
    let windowCandidates: [CaptureWindowCandidate]
    let onConfirm: (CaptureSelectionResult, RecordingOptions?) -> Void
    let onCancel: () -> Void

    @State private var hoveredWindow: CaptureWindowCandidate?
    @State private var confirmedSelection: ConfirmedOverlaySelection?
    @State private var draftSelectionStart: CGPoint?
    @State private var draftSelectionEnd: CGPoint?
    @State private var activeTool: CaptureOverlayTool?
    @State private var annotations: [OverlayAnnotation] = []
    @State private var annotationDraft: OverlayAnnotation?
    @State private var resizeStartRect: CGRect?
    @State private var didCrossDragThreshold = false
    @State private var annotationColor: CaptureAnnotationColor = .red
    @State private var annotationThickness: CaptureAnnotationThickness = .medium
    @State private var textColor: CaptureAnnotationColor = .white
    @State private var textBackground: CaptureTextBackground = .black
    @State private var textSize: CaptureTextSize = .medium
    @State private var expandedStyleTool: CaptureOverlayTool?
    @State private var textDraftPosition: CGPoint?
    @State private var textDraft = ""
    @State private var editingTextAnnotationID: UUID?
    @State private var editingTextOriginal: OverlayAnnotation?
    @State private var selectedAnnotationID: UUID?
    @State private var hoveredAnnotationID: UUID?
    @State private var annotationDragStart: OverlayAnnotation?
    @State private var recordingCountdownValue: Int?
    @State private var recordingCountdownTask: Task<Void, Never>?

    init(
        purpose: CaptureOverlayPurpose,
        displayID: CGDirectDisplayID,
        session: CaptureOverlaySession,
        windowCandidates: [CaptureWindowCandidate],
        initialPointerLocation: CGPoint,
        onConfirm: @escaping (CaptureSelectionResult, RecordingOptions?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.purpose = purpose
        self.displayID = displayID
        self.session = session
        self.windowCandidates = windowCandidates
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _hoveredWindow = State(initialValue: windowCandidates.first { $0.frame.contains(initialPointerLocation) })
    }

    var body: some View {
        GeometryReader { proxy in
            let screenBounds = CGRect(origin: .zero, size: proxy.size)
            let highlight = activeHighlight(in: screenBounds)
            let isLockedOut = session.selectedDisplayID.map { $0 != displayID } ?? false

            ZStack {
                Color.black.opacity(0.40)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            guard !isLockedOut else { return }
                            if confirmedSelection == nil, draftSelectionStart == nil {
                                let nextWindow = windowAt(location)
                                if nextWindow?.windowID != hoveredWindow?.windowID {
                                    withAnimation(.easeOut(duration: 0.065)) {
                                        hoveredWindow = nextWindow
                                    }
                                }
                                return
                            }

                            guard purpose == .screenshot,
                                  textDraftPosition == nil,
                                  let selection = confirmedSelection?.frame,
                                  selection.contains(location) else {
                                if hoveredAnnotationID != nil {
                                    hoveredAnnotationID = nil
                                    updateCursor()
                                }
                                return
                            }
                            let nextAnnotationID = annotation(at: location)?.id
                            if nextAnnotationID != hoveredAnnotationID {
                                hoveredAnnotationID = nextAnnotationID
                                updateCursor()
                            }
                        case .ended:
                            if confirmedSelection == nil, hoveredWindow != nil {
                                withAnimation(.easeOut(duration: 0.065)) {
                                    hoveredWindow = nil
                                }
                            }
                            hoveredAnnotationID = nil
                            updateCursor()
                        }
                    }
                    .gesture(primaryGesture(in: screenBounds))
                    .allowsHitTesting(!isLockedOut)

                if isLockedOut {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { }
                    lockedDisplayMessage
                        .position(x: screenBounds.midX, y: screenBounds.midY)
                } else {
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: highlight.width, height: highlight.height)
                        .position(x: highlight.midX, y: highlight.midY)
                        .blendMode(.destinationOut)
                        .allowsHitTesting(false)

                    Rectangle()
                        .stroke(FormaTheme.accent, lineWidth: 2)
                        .frame(width: max(0, highlight.width - 2), height: max(0, highlight.height - 2))
                        .position(x: highlight.midX, y: highlight.midY)
                        .shadow(color: .black.opacity(0.32), radius: 2)
                        .allowsHitTesting(false)

                    if purpose == .screenshot {
                        annotationCanvas(selection: highlight)
                        if let textDraftPosition {
                            textEditor(at: textDraftPosition, selection: highlight, in: screenBounds)
                        }
                    }

                    if let selection = confirmedSelection,
                       selection.isRegion,
                       draftSelectionStart == nil {
                        let resizingEnabled = activeTool == nil
                            && expandedStyleTool == nil
                            && textDraftPosition == nil
                            && recordingCountdownValue == nil
                        resizeEdgeHitAreas(for: selection.frame, in: screenBounds)
                            .allowsHitTesting(resizingEnabled)
                            .zIndex(100)
                        resizeHandles(for: selection.frame, in: screenBounds)
                            .opacity(resizingEnabled ? 1 : 0)
                            .allowsHitTesting(resizingEnabled)
                            .zIndex(101)
                    }

                    selectionSizeLabel(for: highlight, in: screenBounds)

                    if confirmedSelection != nil,
                       draftSelectionStart == nil,
                       recordingCountdownValue == nil {
                        captureControls(for: highlight, in: screenBounds)
                    }

                    if let recordingCountdownValue {
                        Color.clear
                            .contentShape(Rectangle())
                            .ignoresSafeArea()
                            .zIndex(900)
                        recordingCountdownOverlay(
                            value: recordingCountdownValue,
                            selection: highlight
                        )
                    }
                }
            }
            .compositingGroup()
        }
        // Fill the complete display-backed surface so the selection uses the
        // same top-left coordinate space as ScreenCaptureKit's sourceRect.
        .ignoresSafeArea(.all)
        .onAppear { updateCursor() }
        .onChange(of: activeTool) { _, _ in updateCursor() }
        .onChange(of: textColor) { _, _ in updateEditingTextStyle() }
        .onChange(of: textBackground) { _, _ in updateEditingTextStyle() }
        .onChange(of: textSize) { _, _ in updateEditingTextStyle() }
        .onChange(of: session.selectedDisplayID) { _, selectedDisplayID in
            guard let selectedDisplayID, selectedDisplayID != displayID else { return }
            hoveredWindow = nil
            draftSelectionStart = nil
            draftSelectionEnd = nil
            didCrossDragThreshold = false
            NSCursor.arrow.set()
        }
        .onReceive(NotificationCenter.default.publisher(for: .deleteSelectedCaptureAnnotation)) { _ in
            deleteSelectedAnnotation()
        }
        .onExitCommand { cancel() }
        .onDisappear {
            recordingCountdownTask?.cancel()
            recordingCountdownTask = nil
            NSCursor.arrow.set()
        }
    }

    private func primaryGesture(in bounds: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if confirmedSelection == nil {
                    let distance = hypot(value.translation.width, value.translation.height)
                    guard distance >= 3 else { return }
                    guard session.claim(displayID) else { return }
                    if draftSelectionStart == nil {
                        draftSelectionStart = clamped(value.startLocation, to: bounds)
                        annotations.removeAll()
                        hoveredWindow = nil
                    }
                    didCrossDragThreshold = true
                    draftSelectionEnd = clamped(value.location, to: bounds)
                    return
                }

                guard purpose == .screenshot,
                      textDraftPosition == nil,
                      let selection = confirmedSelection?.frame,
                      selection.contains(value.startLocation) else { return }

                if annotationDragStart == nil,
                   let hit = annotation(at: value.startLocation) {
                    annotationDragStart = hit
                    selectedAnnotationID = hit.id
                    hoveredAnnotationID = hit.id
                    NSCursor.closedHand.set()
                }

                if let dragStart = annotationDragStart {
                    moveAnnotation(
                        dragStart,
                        translation: value.translation,
                        within: selection
                    )
                    return
                }

                guard let activeTool else {
                    selectedAnnotationID = nil
                    return
                }

                switch activeTool {
                case .rectangle, .ellipse, .line, .arrow, .highlight:
                    let kind: CaptureAnnotationKind = switch activeTool {
                    case .rectangle: .rectangle
                    case .ellipse: .ellipse
                    case .line: .line
                    case .arrow: .arrow
                    case .text: .text
                    case .mosaic: .mosaic
                    case .highlight: .highlight
                    }
                    annotationDraft = OverlayAnnotation(
                        kind: kind,
                        start: clamped(value.startLocation, to: selection),
                        end: clamped(value.location, to: selection),
                        color: annotationColor,
                        thickness: annotationThickness,
                        text: nil
                    )
                case .mosaic:
                    let location = clamped(value.location, to: selection)
                    if var draft = annotationDraft {
                        if draft.points.last.map({ hypot($0.x - location.x, $0.y - location.y) >= 2 }) != false {
                            draft.points.append(location)
                            draft.end = location
                            annotationDraft = draft
                        }
                    } else {
                        let start = clamped(value.startLocation, to: selection)
                        annotationDraft = OverlayAnnotation(
                            kind: .mosaic,
                            start: start,
                            end: location,
                            color: .black,
                            thickness: annotationThickness,
                            text: nil,
                            points: [start, location]
                        )
                    }
                case .text:
                    break
                }
            }
            .onEnded { value in
                if confirmedSelection == nil {
                    if let start = draftSelectionStart,
                       let end = draftSelectionEnd {
                        let rect = normalizedRect(from: start, to: end).intersection(bounds)
                        if rect.width >= 6, rect.height >= 6 {
                            confirmedSelection = .region(rect)
                        } else {
                            session.release(displayID)
                        }
                        draftSelectionStart = nil
                        draftSelectionEnd = nil
                        didCrossDragThreshold = false
                        activeTool = nil
                        updateCursor()
                        return
                    }

                    guard session.claim(displayID) else { return }
                    if !didCrossDragThreshold,
                       let candidate = windowAt(value.startLocation) ?? windowAt(value.location) {
                        confirmedSelection = .window(candidate)
                        hoveredWindow = candidate
                    } else {
                        confirmedSelection = .region(bounds)
                        hoveredWindow = nil
                    }
                    didCrossDragThreshold = false
                    annotations.removeAll()
                    activeTool = nil
                    updateCursor()
                    return
                }

                guard purpose == .screenshot,
                      textDraftPosition == nil,
                      let selection = confirmedSelection?.frame,
                      selection.contains(value.startLocation) else { return }

                if let dragStart = annotationDragStart {
                    let current = annotations.first { $0.id == dragStart.id } ?? dragStart
                    let movement = hypot(value.translation.width, value.translation.height)
                    annotationDragStart = nil
                    updateCursor()
                    if movement < 3, current.kind == .text {
                        beginEditingText(current)
                    }
                    return
                }

                guard let activeTool else { return }
                switch activeTool {
                case .rectangle, .ellipse, .line, .arrow, .highlight:
                    guard let draft = annotationDraft else { return }
                    if hypot(draft.end.x - draft.start.x, draft.end.y - draft.start.y) >= 3 {
                        annotations.append(draft)
                        selectedAnnotationID = draft.id
                    }
                    annotationDraft = nil
                case .mosaic:
                    guard let draft = annotationDraft else { return }
                    if draft.points.count >= 2 {
                        annotations.append(draft)
                        selectedAnnotationID = draft.id
                    }
                    annotationDraft = nil
                case .text:
                    beginNewText(at: clamped(value.location, to: selection))
                }
            }
    }

    private var lockedDisplayMessage: some View {
        VStack(spacing: 8) {
            Image(systemName: "display.2")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text("已在另一块屏幕选择")
                .font(.formaBody(13, weight: .semibold))
                .foregroundStyle(.white)
            Text("按 Esc 可取消本次选择")
                .font(.formaBody(11))
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.black.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .allowsHitTesting(false)
    }

    private func activeHighlight(in bounds: CGRect) -> CGRect {
        if let start = draftSelectionStart,
           let end = draftSelectionEnd {
            return validHighlight(normalizedRect(from: start, to: end), in: bounds)
        }
        if let confirmedSelection {
            return validHighlight(confirmedSelection.frame, in: bounds)
        }
        if let hoveredWindow {
            return validHighlight(hoveredWindow.frame, in: bounds)
        }
        return bounds
    }

    private func validHighlight(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        let clipped = rect.standardized.intersection(bounds)
        guard !clipped.isNull,
              !clipped.isInfinite,
              clipped.origin.x.isFinite,
              clipped.origin.y.isFinite,
              clipped.width.isFinite,
              clipped.height.isFinite,
              clipped.width >= 0,
              clipped.height >= 0 else {
            return bounds
        }
        return clipped
    }

    private func windowAt(_ location: CGPoint) -> CaptureWindowCandidate? {
        windowCandidates.first { $0.frame.contains(location) }
    }

    @ViewBuilder
    private func selectionSizeLabel(for selection: CGRect, in bounds: CGRect) -> some View {
        Text("\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.black.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .position(
                x: min(bounds.width - 56, max(56, selection.minX + 56)),
                y: selection.minY > 34 ? selection.minY - 17 : selection.minY + 17
            )
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func captureControls(for selection: CGRect, in bounds: CGRect) -> some View {
        if purpose == .recording {
            recordingSetupPanel(for: selection, in: bounds)
        } else {
            let layout = screenshotToolbarLayout(for: selection, in: bounds)
            screenshotToolbar(at: layout.toolbarPosition, in: bounds)

            if expandedStyleTool != nil {
                annotationStylePanel
                    .frame(width: annotationStylePanelSize.width, height: annotationStylePanelSize.height)
                    .contentShape(Rectangle())
                    .onHover { isInside in
                        if isInside { NSCursor.arrow.set() }
                        else { updateCursor() }
                    }
                    .position(layout.stylePanelPosition)
                    .zIndex(520)
            }
        }
    }

    @ViewBuilder
    private func screenshotToolbar(at position: CGPoint, in bounds: CGRect) -> some View {
        HStack(spacing: 7) {
            toolButton(
                "rectangle.dashed",
                label: "矩形标注",
                help: "拖拽绘制矩形；二级工具栏可调整颜色和粗细",
                tool: .rectangle,
                showsStylePanel: true
            )
            toolButton(
                "circle.dashed",
                label: "圆圈标注",
                help: "拖拽绘制圆圈；二级工具栏可调整颜色和粗细",
                tool: .ellipse,
                showsStylePanel: true
            )
            toolButton(
                "line.diagonal",
                label: "画线",
                help: "按住鼠标拖拽绘制直线",
                tool: .line,
                showsStylePanel: true
            )
            toolButton(
                "arrow.up.right",
                label: "画箭头",
                help: "从起点拖向重点位置绘制箭头",
                tool: .arrow,
                showsStylePanel: true
            )
            toolButton(
                "character.cursor.ibeam",
                label: "文字标注",
                help: "点击截图输入文字；可再次点击文字进行编辑",
                tool: .text,
                showsStylePanel: true
            )
            toolButton(
                "square.grid.3x3.fill",
                label: "马赛克",
                help: "在敏感内容上拖动涂抹；二级工具栏调整笔刷粗细",
                tool: .mosaic,
                showsStylePanel: true
            )
            toolButton(
                "highlighter",
                label: "聚光高亮",
                help: "拖出亮区，截图其余位置会变暗以突出重点",
                tool: .highlight
            )
            actionButton(
                "rectangle.stack.badge.plus",
                label: "截长图",
                help: confirmedSelection?.isWindow == true
                    ? "自动滚动当前窗口并拼接成长图"
                    : "请先单击选择一个可滚动窗口，再使用截长图",
                role: .secondary,
                isEnabled: confirmedSelection?.isWindow == true
            ) {
                confirm(in: bounds, action: .longScreenshot)
            }
            actionButton("pin", label: "置顶截图", help: "完成编辑并将截图独立置顶显示", role: .secondary) {
                confirm(in: bounds, action: .pin)
            }
            actionButton("xmark", label: "取消截图", help: "退出本次截图，也可以按 Esc", role: .secondary) {
                cancel()
            }
            actionButton("checkmark", label: "确认截图", help: "完成截图并执行通用设置中的保存或复制动作", role: .primary) {
                confirm(in: bounds)
            }
        }
        .padding(7)
        .frame(width: 535, height: 46)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(FormaTheme.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(FormaTheme.lineStrong, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.34), radius: 8, y: 3)
        .contentShape(Rectangle())
        .onHover { isInside in
            if isInside { NSCursor.arrow.set() }
            else { updateCursor() }
        }
        .position(position)
        .zIndex(510)
    }

    private func screenshotToolbarLayout(
        for rawSelection: CGRect,
        in rawBounds: CGRect
    ) -> ScreenshotToolbarLayout {
        let bounds = rawBounds.standardized
        let selection = validHighlight(rawSelection, in: bounds)
        let toolbarSize = CGSize(width: 535, height: 46)
        let stylePanelSize = annotationStylePanelSize
        let edgeInset: CGFloat = 4
        let outsideGap: CGFloat = 10
        let styleGap: CGFloat = 8
        let belowY = selection.maxY + outsideGap + toolbarSize.height / 2
        let aboveY = selection.minY - outsideGap - toolbarSize.height / 2
        let insideBottomY = selection.maxY - outsideGap - toolbarSize.height / 2
        let styleExtent = expandedStyleTool == nil ? 0 : styleGap + stylePanelSize.height
        let belowClusterFits = selection.maxY + outsideGap + toolbarSize.height + styleExtent
            <= bounds.maxY - edgeInset
        let aboveClusterFits = selection.minY - outsideGap - toolbarSize.height - styleExtent
            >= bounds.minY + edgeInset
        let toolbarY: CGFloat
        if expandedStyleTool != nil, belowClusterFits {
            toolbarY = belowY
        } else if expandedStyleTool != nil, aboveClusterFits {
            toolbarY = aboveY
        } else if belowY <= bounds.maxY - edgeInset {
            toolbarY = belowY
        } else if aboveY >= bounds.minY + edgeInset {
            toolbarY = aboveY
        } else {
            toolbarY = min(
                bounds.maxY - toolbarSize.height / 2 - edgeInset,
                max(bounds.minY + toolbarSize.height / 2 + edgeInset, insideBottomY)
            )
        }

        let isFullScreenSelection = abs(selection.width - bounds.width) < 1
            && abs(selection.height - bounds.height) < 1
        let toolbarX: CGFloat
        if isFullScreenSelection {
            toolbarX = bounds.midX
        } else {
            toolbarX = min(
                bounds.maxX - toolbarSize.width / 2 - edgeInset,
                max(toolbarSize.width / 2 + edgeInset, selection.maxX - toolbarSize.width / 2)
            )
        }
        let styleX = stylePanelX(toolbarX: toolbarX, bounds: bounds)
        let styleY = toolbarY + stylePanelOffset(
            toolbarY: toolbarY,
            selection: selection,
            bounds: bounds
        )
        let clampedStyleY = min(
            bounds.maxY - stylePanelSize.height / 2 - edgeInset,
            max(bounds.minY + stylePanelSize.height / 2 + edgeInset, styleY)
        )
        return ScreenshotToolbarLayout(
            toolbarPosition: CGPoint(x: toolbarX, y: toolbarY),
            stylePanelPosition: CGPoint(x: styleX, y: clampedStyleY)
        )
    }

    @ViewBuilder
    private func recordingSetupPanel(for selection: CGRect, in bounds: CGRect) -> some View {
        let panelSize = CGSize(width: 940, height: 208)
        let edgeInset: CGFloat = 8
        let outsideGap: CGFloat = 10
        let belowY = selection.maxY + outsideGap + panelSize.height / 2
        let insideBottomY = selection.maxY - outsideGap - panelSize.height / 2
        // Recording controls belong below the selected area. Keep them outside
        // whenever the full panel fits; otherwise tuck the same panel against
        // the selection's inner bottom edge. Never jump it above the selection.
        let panelY: CGFloat = if belowY + panelSize.height / 2 <= bounds.maxY - edgeInset {
            belowY
        } else {
            min(
                bounds.maxY - panelSize.height / 2 - edgeInset,
                max(bounds.minY + panelSize.height / 2 + edgeInset, insideBottomY)
            )
        }
        // Keep the recording controls centered directly below the selection.
        // Only shift horizontally when the panel would cross a display edge.
        let panelX = min(
            bounds.maxX - panelSize.width / 2 - edgeInset,
            max(bounds.minX + panelSize.width / 2 + edgeInset, selection.midX)
        )

        RecordingSetupPanelView(
            selectionDescription: "录制区域 · \(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))",
            onStart: { options in
                beginRecordingCountdown(options: options, in: bounds)
            },
            onCancel: cancel
        )
        .frame(width: panelSize.width, height: panelSize.height)
        .onHover { isInside in
            if isInside { NSCursor.arrow.set() }
            else { updateCursor() }
        }
        .position(x: panelX, y: panelY)
        .zIndex(200)
    }

    @ViewBuilder
    private func recordingCountdownOverlay(value: Int, selection: CGRect) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(FormaTheme.accent)
                Text("M · IMAGO")
                    .font(.formaLabel(10))
                    .tracking(0.8)
            }

            Text("\(value)")
                .font(.system(size: 58, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())

            Text("秒后开始录制")
                .font(.formaBody(12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
        }
        .frame(width: 176, height: 142)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(FormaTheme.ink.opacity(0.92))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(FormaTheme.accent.opacity(0.9), lineWidth: 2)
        }
        .shadow(color: .black.opacity(0.42), radius: 14, y: 6)
        .position(x: selection.midX, y: selection.midY)
        .allowsHitTesting(false)
        .zIndex(1000)
    }

    private func beginRecordingCountdown(options: RecordingOptions, in bounds: CGRect) {
        recordingCountdownTask?.cancel()
        guard options.countdownSeconds > 0 else {
            confirm(in: bounds, recordingOptions: options)
            return
        }

        recordingCountdownTask = Task { @MainActor in
            for second in stride(from: options.countdownSeconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    recordingCountdownValue = second
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else { return }
            recordingCountdownValue = nil
            recordingCountdownTask = nil
            var immediateOptions = options
            immediateOptions.countdownSeconds = 0
            confirm(in: bounds, recordingOptions: immediateOptions)
        }
    }

    @ViewBuilder
    private func toolButton(
        _ systemImage: String,
        label: String,
        help: String,
        tool: CaptureOverlayTool,
        showsStylePanel: Bool = false
    ) -> some View {
        FormaButton(
            "",
            systemImage: systemImage,
            role: .secondary,
            size: .small,
            showsSelectionDot: true,
            isSelected: activeTool == tool,
            depth: .raised
        ) {
            withTransaction(Transaction(animation: nil)) {
                if textDraftPosition != nil {
                    cancelTextDraft()
                }
                if activeTool == tool {
                    activeTool = nil
                    expandedStyleTool = nil
                } else {
                    activeTool = tool
                    expandedStyleTool = showsStylePanel ? tool : nil
                }
                annotationDraft = nil
            }
        }
        .frame(width: 40)
        .accessibilityLabel(label)
        .delayedFormaHelp(label, detail: help)
    }

    @ViewBuilder
    private func actionButton(
        _ systemImage: String,
        label: String,
        help: String,
        role: FormaButtonRole,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        FormaButton(
            "",
            systemImage: systemImage,
            role: role,
            size: .small,
            depth: .raised,
            action: action
        )
        .frame(width: 40)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
        .delayedFormaHelp(label, detail: help)
    }

    private var annotationStylePanelSize: CGSize {
        switch expandedStyleTool {
        case .text:
            CGSize(width: 294, height: 132)
        case .mosaic:
            CGSize(width: 202, height: 58)
        default:
            CGSize(width: 202, height: 84)
        }
    }

    @ViewBuilder
    private var annotationStylePanel: some View {
        FormaFloatingCard(padding: 9) {
            if expandedStyleTool == .text {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        styleLabel("字号")
                        FormaCompactRail(
                            items: CaptureTextSize.allCases,
                            selection: $textSize,
                            size: .small,
                            segmentWidth: 46
                        )
                        .delayedFormaHelp(
                            "文字大小",
                            detail: "选择小、中、大字号；编辑已有文字时会立即应用"
                        )
                    }
                    HStack(spacing: 8) {
                        styleLabel("文字")
                        annotationColorPicker(selection: $textColor)
                            .delayedFormaHelp(
                                "文字颜色",
                                detail: "选择文字前景色；再次编辑文字时也可修改"
                            )
                    }
                    HStack(spacing: 8) {
                        styleLabel("背景")
                        FormaButton(
                            "",
                            systemImage: "nosign",
                            role: .secondary,
                            size: .small,
                            showsSelectionDot: true,
                            isSelected: textBackground == .none,
                            depth: .raised
                        ) {
                            textBackground = .none
                        }
                        .frame(width: 34)
                        .delayedFormaHelp(
                            "无文字背景",
                            detail: "移除文字后面的色块，只保留文字本身"
                        )
                        FormaColorSwatchPicker(
                            items: CaptureTextBackground.allCases.compactMap { background in
                                guard let color = background.swiftUIColor else { return nil }
                                return FormaColorSwatch(id: background.rawValue, color: color)
                            },
                            selection: Binding(
                                get: { textBackground.rawValue },
                                set: { textBackground = CaptureTextBackground(rawValue: $0) ?? .black }
                            ),
                            swatchSize: 17
                        )
                        .delayedFormaHelp(
                            "文字背景色",
                            detail: "选择文字后方色块的颜色，提高文字可读性"
                        )
                    }
                }
            } else if expandedStyleTool == .mosaic {
                HStack(spacing: 8) {
                    styleLabel("粗细")
                    FormaCompactRail(
                        items: CaptureAnnotationThickness.allCases,
                        selection: $annotationThickness,
                        size: .small,
                        segmentWidth: 44
                    )
                    .delayedFormaHelp(
                        "马赛克粗细",
                        detail: "选择涂抹笔刷的宽度；已有马赛克可拖动调整位置"
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    FormaCompactRail(
                        items: CaptureAnnotationThickness.allCases,
                        selection: $annotationThickness,
                        size: .small,
                        segmentWidth: 44
                    )
                    .delayedFormaHelp(
                        "标注粗细",
                        detail: "选择线条的粗细，之后绘制的标注会使用该尺寸"
                    )
                    annotationColorPicker(selection: $annotationColor)
                        .delayedFormaHelp(
                            "标注颜色",
                            detail: "选择矩形、圆圈、直线或箭头的颜色"
                        )
                }
            }
        }
    }

    private func styleLabel(_ title: String) -> some View {
        Text(title)
            .font(.formaBody(10, weight: .semibold))
            .foregroundStyle(FormaColor.inkSoft)
            .frame(width: 29, alignment: .leading)
    }

    private func annotationColorPicker(
        selection: Binding<CaptureAnnotationColor>
    ) -> some View {
        FormaColorSwatchPicker(
            items: CaptureAnnotationColor.allCases.map {
                FormaColorSwatch(id: $0.rawValue, color: $0.swiftUIColor)
            },
            selection: Binding(
                get: { selection.wrappedValue.rawValue },
                set: { selection.wrappedValue = CaptureAnnotationColor(rawValue: $0) ?? .red }
            ),
            swatchSize: 19
        )
    }

    private func stylePanelOffset(
        toolbarY: CGFloat,
        selection: CGRect,
        bounds: CGRect
    ) -> CGFloat {
        let panelHeight = annotationStylePanelSize.height
        let gap: CGFloat = 8
        let offset = 23 + gap + panelHeight / 2

        if toolbarY >= selection.maxY,
           toolbarY + 23 + gap + panelHeight <= bounds.maxY - 4 {
            return offset
        }
        if toolbarY <= selection.minY,
           toolbarY - 23 - gap - panelHeight >= bounds.minY + 4 {
            return -offset
        }
        if toolbarY - offset - panelHeight / 2 >= bounds.minY + 4 {
            return -offset
        }
        return offset
    }

    private func stylePanelX(toolbarX: CGFloat, bounds: CGRect) -> CGFloat {
        let panelHalfWidth = annotationStylePanelSize.width / 2
        let firstToolCenterOffset: CGFloat = -235
        let toolStep: CGFloat = 47
        let toolIndex: CGFloat = switch expandedStyleTool {
        case .rectangle: 0
        case .ellipse: 1
        case .line: 2
        case .arrow: 3
        case .text: 4
        case .mosaic: 5
        case .highlight: 6
        case nil: 0
        }
        let desired = toolbarX + firstToolCenterOffset + toolStep * toolIndex
        return min(
            bounds.maxX - panelHalfWidth - 4,
            max(bounds.minX + panelHalfWidth + 4, desired)
        )
    }

    @ViewBuilder
    private func annotationCanvas(selection: CGRect) -> some View {
        Canvas { context, _ in
            var allAnnotations = annotations
            if let annotationDraft { allAnnotations.append(annotationDraft) }

            context.clip(to: Path(selection))
            let highlightAnnotations = allAnnotations.filter { $0.kind == .highlight }
            if activeTool == .highlight || !highlightAnnotations.isEmpty {
                context.fill(Path(selection), with: .color(.black.opacity(0.52)))
                context.blendMode = .destinationOut
                for annotation in highlightAnnotations {
                    let rect = normalizedRect(from: annotation.start, to: annotation.end)
                    context.fill(Path(rect), with: .color(.white))
                }
                context.blendMode = .normal
            }

            for annotation in allAnnotations {
                if annotation.kind == .highlight {
                    drawAnnotationSelection(
                        annotation,
                        bounds: annotationBounds(annotation),
                        in: &context
                    )
                    continue
                }

                if annotation.kind == .mosaic {
                    drawMosaicPreview(annotation, in: &context)
                    drawAnnotationSelection(
                        annotation,
                        bounds: annotationBounds(annotation),
                        in: &context
                    )
                    continue
                }

                if annotation.kind == .text {
                    guard let text = annotation.text, !text.isEmpty else { continue }
                    let fontSize = annotation.textSize?.rawValue
                        ?? annotation.thickness.textFontSize
                    let resolved = context.resolve(
                        Text(text)
                            .font(.custom("PingFang SC", size: fontSize))
                            .fontWeight(.semibold)
                            .foregroundStyle(annotation.color.swiftUIColor)
                    )
                    let textSize = resolved.measure(
                        in: CGSize(width: max(1, selection.width), height: 200)
                    )
                    let backgroundRect = CGRect(
                        x: annotation.start.x - 5,
                        y: annotation.start.y - 3,
                        width: textSize.width + 10,
                        height: textSize.height + 6
                    )
                    if let backgroundColor = annotation.textBackground?.swiftUIColor {
                        context.fill(
                            Path(roundedRect: backgroundRect, cornerRadius: 4),
                            with: .color(backgroundColor)
                        )
                    }
                    context.draw(
                        resolved,
                        at: annotation.start,
                        anchor: .topLeading
                    )
                    drawAnnotationSelection(
                        annotation,
                        bounds: backgroundRect,
                        in: &context
                    )
                    continue
                }
                let path: Path
                if annotation.kind == .rectangle {
                    path = Path(normalizedRect(from: annotation.start, to: annotation.end))
                } else if annotation.kind == .ellipse {
                    path = Path(ellipseIn: normalizedRect(from: annotation.start, to: annotation.end))
                } else {
                    var linePath = Path()
                    linePath.move(to: annotation.start)
                    linePath.addLine(to: annotation.end)
                    path = linePath
                }
                context.stroke(
                    path,
                    with: .color(annotation.color.swiftUIColor),
                    style: StrokeStyle(
                        lineWidth: annotation.thickness.rawValue,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )

                if annotation.kind == .arrow {
                    let arrow = arrowHeadPath(from: annotation.start, to: annotation.end, length: 13)
                    context.stroke(
                        arrow,
                        with: .color(annotation.color.swiftUIColor),
                        style: StrokeStyle(
                            lineWidth: annotation.thickness.rawValue,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }

                drawAnnotationSelection(
                    annotation,
                    bounds: annotationBounds(annotation),
                    in: &context
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func drawMosaicPreview(
        _ annotation: OverlayAnnotation,
        in context: inout GraphicsContext
    ) {
        let points = annotation.points.isEmpty
            ? [annotation.start, annotation.end]
            : annotation.points
        guard points.count >= 2 else { return }

        let block = max(8, annotation.thickness.mosaicWidth / 2)
        let radius = annotation.thickness.mosaicWidth / 2
        for pair in zip(points, points.dropFirst()) {
            let distance = hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
            let steps = max(1, Int(ceil(distance / max(3, block * 0.45))))
            for step in 0...steps {
                let progress = CGFloat(step) / CGFloat(steps)
                let center = CGPoint(
                    x: pair.0.x + (pair.1.x - pair.0.x) * progress,
                    y: pair.0.y + (pair.1.y - pair.0.y) * progress
                )
                let minX = center.x - radius
                let minY = center.y - radius
                let rows = max(1, Int(ceil(annotation.thickness.mosaicWidth / block)))
                for row in 0..<rows {
                    for column in 0..<rows {
                        let rect = CGRect(
                            x: minX + CGFloat(column) * block,
                            y: minY + CGFloat(row) * block,
                            width: block + 0.5,
                            height: block + 0.5
                        )
                        let isDark = (row + column + Int(center.x / block) + Int(center.y / block)).isMultiple(of: 2)
                        context.fill(
                            Path(rect),
                            with: .color(
                                isDark
                                    ? Color(red: 0.38, green: 0.40, blue: 0.42).opacity(0.78)
                                    : Color(red: 0.62, green: 0.64, blue: 0.66).opacity(0.68)
                            )
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func textEditor(at position: CGPoint, selection: CGRect, in bounds: CGRect) -> some View {
        let panelSize = CGSize(width: 256, height: 92)
        let x = min(
            bounds.maxX - panelSize.width / 2 - 6,
            max(bounds.minX + panelSize.width / 2 + 6, position.x + panelSize.width / 2)
        )
        let preferredY = position.y + panelSize.height / 2 + 8
        let y = min(
            bounds.maxY - panelSize.height / 2 - 6,
            max(bounds.minY + panelSize.height / 2 + 6, preferredY)
        )

        FormaFloatingCard(padding: 8) {
            VStack(spacing: 7) {
                FormaTextField(
                    "文字标注",
                    text: $textDraft,
                    placeholder: "输入文字",
                    size: .small
                )
                HStack(spacing: 7) {
                    Spacer()
                    FormaButton(
                        "",
                        systemImage: "xmark",
                        role: .secondary,
                        size: .small,
                        depth: .raised
                    ) {
                        cancelTextDraft()
                    }
                    .frame(width: 38)
                    .delayedFormaHelp("取消文字", detail: "放弃本次文字输入", placement: .below)
                    FormaButton(
                        "",
                        systemImage: "checkmark",
                        size: .small,
                        depth: .raised
                    ) {
                        commitTextDraft()
                    }
                    .frame(width: 38)
                    .delayedFormaHelp("确认文字", detail: "完成文字标注并保留在截图上", placement: .below)
                }
            }
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .onHover { isInside in
            if isInside { NSCursor.arrow.set() }
            else { updateCursor() }
        }
        .position(x: x, y: y)
        .zIndex(300)
    }

    private func commitTextDraft() {
        guard let position = textDraftPosition else { return }
        let trimmed = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelTextDraft()
            return
        }

        if let editingTextAnnotationID,
           let index = annotations.firstIndex(where: { $0.id == editingTextAnnotationID }) {
            annotations[index].start = position
            annotations[index].end = position
            annotations[index].color = textColor
            annotations[index].text = trimmed
            annotations[index].textSize = textSize
            annotations[index].textBackground = textBackground
            selectedAnnotationID = editingTextAnnotationID
        } else {
            let annotation = OverlayAnnotation(
                kind: .text,
                start: position,
                end: position,
                color: textColor,
                thickness: annotationThickness,
                text: trimmed,
                textSize: textSize,
                textBackground: textBackground
            )
            annotations.append(annotation)
            selectedAnnotationID = annotation.id
        }
        textDraftPosition = nil
        textDraft = ""
        editingTextAnnotationID = nil
        editingTextOriginal = nil
    }

    private func cancelTextDraft() {
        if let original = editingTextOriginal,
           let index = annotations.firstIndex(where: { $0.id == original.id }) {
            annotations[index] = original
        }
        textDraftPosition = nil
        textDraft = ""
        editingTextAnnotationID = nil
        editingTextOriginal = nil
    }

    private func deleteSelectedAnnotation() {
        guard textDraftPosition == nil,
              let selectedAnnotationID else { return }
        annotations.removeAll { $0.id == selectedAnnotationID }
        self.selectedAnnotationID = nil
        hoveredAnnotationID = nil
        annotationDragStart = nil
        updateCursor()
    }

    private func beginNewText(at position: CGPoint) {
        editingTextAnnotationID = nil
        editingTextOriginal = nil
        textDraftPosition = position
        textDraft = ""
        selectedAnnotationID = nil
        activeTool = .text
        expandedStyleTool = .text
    }

    private func beginEditingText(_ annotation: OverlayAnnotation) {
        guard annotation.kind == .text else { return }
        editingTextAnnotationID = annotation.id
        editingTextOriginal = annotation
        textDraftPosition = annotation.start
        textDraft = annotation.text ?? ""
        textColor = annotation.color
        textSize = annotation.textSize ?? .medium
        textBackground = annotation.textBackground ?? .black
        selectedAnnotationID = annotation.id
        activeTool = .text
        expandedStyleTool = .text
    }

    private func updateEditingTextStyle() {
        guard let editingTextAnnotationID,
              let index = annotations.firstIndex(where: { $0.id == editingTextAnnotationID }) else { return }
        annotations[index].color = textColor
        annotations[index].textSize = textSize
        annotations[index].textBackground = textBackground
    }

    private func annotation(at point: CGPoint) -> OverlayAnnotation? {
        annotations.reversed().first { annotationContains($0, point: point) }
    }

    private func annotationContains(_ annotation: OverlayAnnotation, point: CGPoint) -> Bool {
        let tolerance = max(9, annotation.thickness.rawValue + 5)
        switch annotation.kind {
        case .text:
            return annotationBounds(annotation)
                .insetBy(dx: -6, dy: -6)
                .contains(point)
        case .line, .arrow:
            return distance(
                from: point,
                toSegmentFrom: annotation.start,
                to: annotation.end
            ) <= tolerance
        case .mosaic:
            let points = annotation.points.isEmpty
                ? [annotation.start, annotation.end]
                : annotation.points
            return zip(points, points.dropFirst()).contains { pair in
                distance(from: point, toSegmentFrom: pair.0, to: pair.1)
                    <= annotation.thickness.mosaicWidth / 2 + 5
            }
        case .highlight:
            return normalizedRect(from: annotation.start, to: annotation.end)
                .insetBy(dx: -6, dy: -6)
                .contains(point)
        case .rectangle:
            let rect = normalizedRect(from: annotation.start, to: annotation.end)
            guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
            return min(
                abs(point.x - rect.minX),
                abs(point.x - rect.maxX),
                abs(point.y - rect.minY),
                abs(point.y - rect.maxY)
            ) <= tolerance
        case .ellipse:
            let rect = normalizedRect(from: annotation.start, to: annotation.end)
            let radiusX = max(1, rect.width / 2)
            let radiusY = max(1, rect.height / 2)
            let normalizedX = (point.x - rect.midX) / radiusX
            let normalizedY = (point.y - rect.midY) / radiusY
            let radialDistance = abs(hypot(normalizedX, normalizedY) - 1)
                * min(radiusX, radiusY)
            return radialDistance <= tolerance
        }
    }

    private func annotationBounds(_ annotation: OverlayAnnotation) -> CGRect {
        if annotation.kind == .text {
            let text = annotation.text ?? ""
            let fontSize = annotation.textSize?.rawValue
                ?? annotation.thickness.textFontSize
            let font = NSFont(name: "PingFang SC", size: fontSize)
                ?? NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            let size = (text as NSString).size(withAttributes: [.font: font])
            return CGRect(
                x: annotation.start.x - 5,
                y: annotation.start.y - 3,
                width: max(12, ceil(size.width) + 10),
                height: max(fontSize + 6, ceil(size.height) + 6)
            )
        }

        if annotation.kind == .mosaic {
            let points = annotation.points.isEmpty
                ? [annotation.start, annotation.end]
                : annotation.points
            guard let first = points.first else { return .zero }
            var bounds = CGRect(origin: first, size: .zero)
            for point in points.dropFirst() {
                bounds = bounds.union(CGRect(origin: point, size: .zero))
            }
            let inset = annotation.thickness.mosaicWidth / 2
            return bounds.insetBy(dx: -inset, dy: -inset)
        }

        return normalizedRect(from: annotation.start, to: annotation.end)
            .insetBy(dx: -annotation.thickness.rawValue / 2, dy: -annotation.thickness.rawValue / 2)
    }

    private func moveAnnotation(
        _ original: OverlayAnnotation,
        translation: CGSize,
        within selection: CGRect
    ) {
        guard let index = annotations.firstIndex(where: { $0.id == original.id }) else { return }
        let bounds = annotationBounds(original)
        let minimumX = selection.minX - bounds.minX
        let maximumX = selection.maxX - bounds.maxX
        let minimumY = selection.minY - bounds.minY
        let maximumY = selection.maxY - bounds.maxY
        let deltaX = minimumX <= maximumX
            ? min(maximumX, max(minimumX, translation.width))
            : 0
        let deltaY = minimumY <= maximumY
            ? min(maximumY, max(minimumY, translation.height))
            : 0

        var moved = original
        moved.start.x += deltaX
        moved.start.y += deltaY
        moved.end.x += deltaX
        moved.end.y += deltaY
        if !moved.points.isEmpty {
            moved.points = moved.points.map { point in
                CGPoint(x: point.x + deltaX, y: point.y + deltaY)
            }
        }
        annotations[index] = moved
    }

    private func distance(
        from point: CGPoint,
        toSegmentFrom start: CGPoint,
        to end: CGPoint
    ) -> CGFloat {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let lengthSquared = deltaX * deltaX + deltaY * deltaY
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = min(
            1,
            max(0, ((point.x - start.x) * deltaX + (point.y - start.y) * deltaY) / lengthSquared)
        )
        let closest = CGPoint(
            x: start.x + projection * deltaX,
            y: start.y + projection * deltaY
        )
        return hypot(point.x - closest.x, point.y - closest.y)
    }

    private func drawAnnotationSelection(
        _ annotation: OverlayAnnotation,
        bounds: CGRect,
        in context: inout GraphicsContext
    ) {
        guard annotation.id == hoveredAnnotationID
            || annotation.id == selectedAnnotationID else { return }
        let outline = bounds.insetBy(dx: -5, dy: -5)
        let path = Path(roundedRect: outline, cornerRadius: 5)
        context.stroke(
            path,
            with: .color(.black.opacity(0.58)),
            style: StrokeStyle(lineWidth: 3, dash: [5, 4])
        )
        context.stroke(
            path,
            with: .color(.white.opacity(0.94)),
            style: StrokeStyle(lineWidth: 1, dash: [5, 4])
        )
    }

    @ViewBuilder
    private func resizeHandles(for rect: CGRect, in bounds: CGRect) -> some View {
        ForEach(SelectionResizeHandle.allCases, id: \.self) { handle in
            let visualPosition = handle.position(in: rect)
            let hitPosition = clampedResizeHitPosition(visualPosition, in: bounds, radius: 14)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.white)
                .overlay {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .stroke(FormaTheme.accent, lineWidth: 1.5)
                }
                .frame(width: 9, height: 9)
                .position(visualPosition)
                .allowsHitTesting(false)

            Color.clear
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .gesture(resizeGesture(handle: handle, currentRect: rect, bounds: bounds))
                .onHover { isInside in
                    if isInside { resizeCursor(for: handle).set() }
                    else { updateCursor() }
                }
                .position(hitPosition)
        }
    }

    @ViewBuilder
    private func resizeEdgeHitAreas(for rect: CGRect, in bounds: CGRect) -> some View {
        let edgeThickness: CGFloat = 14
        let horizontalWidth = max(0, rect.width - 34)
        let verticalHeight = max(0, rect.height - 34)
        let northY = min(bounds.maxY - edgeThickness / 2, max(bounds.minY + edgeThickness / 2, rect.minY))
        let southY = min(bounds.maxY - edgeThickness / 2, max(bounds.minY + edgeThickness / 2, rect.maxY))
        let westX = min(bounds.maxX - edgeThickness / 2, max(bounds.minX + edgeThickness / 2, rect.minX))
        let eastX = min(bounds.maxX - edgeThickness / 2, max(bounds.minX + edgeThickness / 2, rect.maxX))

        Color.clear
            .frame(width: horizontalWidth, height: edgeThickness)
            .contentShape(Rectangle())
            .gesture(resizeGesture(handle: .north, currentRect: rect, bounds: bounds))
            .onHover { $0 ? NSCursor.resizeUpDown.set() : updateCursor() }
            .position(x: rect.midX, y: northY)
        Color.clear
            .frame(width: horizontalWidth, height: edgeThickness)
            .contentShape(Rectangle())
            .gesture(resizeGesture(handle: .south, currentRect: rect, bounds: bounds))
            .onHover { $0 ? NSCursor.resizeUpDown.set() : updateCursor() }
            .position(x: rect.midX, y: southY)
        Color.clear
            .frame(width: edgeThickness, height: verticalHeight)
            .contentShape(Rectangle())
            .gesture(resizeGesture(handle: .west, currentRect: rect, bounds: bounds))
            .onHover { $0 ? NSCursor.resizeLeftRight.set() : updateCursor() }
            .position(x: westX, y: rect.midY)
        Color.clear
            .frame(width: edgeThickness, height: verticalHeight)
            .contentShape(Rectangle())
            .gesture(resizeGesture(handle: .east, currentRect: rect, bounds: bounds))
            .onHover { $0 ? NSCursor.resizeLeftRight.set() : updateCursor() }
            .position(x: eastX, y: rect.midY)
    }

    private func resizeGesture(
        handle: SelectionResizeHandle,
        currentRect: CGRect,
        bounds: CGRect
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if resizeStartRect == nil { resizeStartRect = currentRect }
                guard let startRect = resizeStartRect else { return }
                confirmedSelection = .region(
                    resizedRect(
                        startRect,
                        handle: handle,
                        translation: value.translation,
                        bounds: bounds
                    )
                )
                annotations.removeAll()
            }
            .onEnded { _ in resizeStartRect = nil }
    }

    private func resizedRect(
        _ rect: CGRect,
        handle: SelectionResizeHandle,
        translation: CGSize,
        bounds: CGRect
    ) -> CGRect {
        var minX = rect.minX
        var maxX = rect.maxX
        var minY = rect.minY
        var maxY = rect.maxY

        switch handle {
        case .northWest:
            minX += translation.width; minY += translation.height
        case .north:
            minY += translation.height
        case .northEast:
            maxX += translation.width; minY += translation.height
        case .west:
            minX += translation.width
        case .east:
            maxX += translation.width
        case .southWest:
            minX += translation.width; maxY += translation.height
        case .south:
            maxY += translation.height
        case .southEast:
            maxX += translation.width; maxY += translation.height
        }

        let minimumSide: CGFloat = 24
        if maxX - minX < minimumSide {
            if [.northWest, .west, .southWest].contains(handle) { minX = maxX - minimumSide }
            else { maxX = minX + minimumSide }
        }
        if maxY - minY < minimumSide {
            if [.northWest, .north, .northEast].contains(handle) { minY = maxY - minimumSide }
            else { maxY = minY + minimumSide }
        }

        minX = max(bounds.minX, minX)
        minY = max(bounds.minY, minY)
        maxX = min(bounds.maxX, maxX)
        maxY = min(bounds.maxY, maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func confirm(
        in bounds: CGRect,
        recordingOptions: RecordingOptions? = nil,
        action: CaptureResultAction = .finish
    ) {
        guard let confirmedSelection else { return }
        let frame = confirmedSelection.frame
        guard frame.width > 4, frame.height > 4 else { return }

        let normalizedAnnotations = (purpose == .screenshot ? annotations : []).map { annotation in
            CaptureAnnotation(
                kind: annotation.kind,
                start: CGPoint(
                    x: (annotation.start.x - frame.minX) / frame.width,
                    y: (annotation.start.y - frame.minY) / frame.height
                ),
                end: CGPoint(
                    x: (annotation.end.x - frame.minX) / frame.width,
                    y: (annotation.end.y - frame.minY) / frame.height
                ),
                color: annotation.color,
                thickness: annotation.thickness,
                text: annotation.text,
                textSize: annotation.textSize,
                textBackground: annotation.textBackground,
                points: annotation.points.map { point in
                    CGPoint(
                        x: (point.x - frame.minX) / frame.width,
                        y: (point.y - frame.minY) / frame.height
                    )
                }
            )
        }

        let target: CaptureSelectionTarget
        switch confirmedSelection {
        case let .window(candidate):
            target = .window(windowID: candidate.windowID, processID: candidate.processID)
        case let .region(rect):
            target = .region(
                displayID: displayID,
                normalizedRect: CGRect(
                    x: rect.minX / bounds.width,
                    y: rect.minY / bounds.height,
                    width: rect.width / bounds.width,
                    height: rect.height / bounds.height
                )
            )
        }
        onConfirm(
            CaptureSelectionResult(
                target: target,
                annotations: normalizedAnnotations,
                action: purpose == .recording ? .finish : action
            ),
            recordingOptions
        )
    }

    private func cancel() {
        recordingCountdownTask?.cancel()
        recordingCountdownTask = nil
        recordingCountdownValue = nil
        onCancel()
    }

    private func updateCursor() {
        guard confirmedSelection != nil else {
            NSCursor.crosshair.set()
            return
        }
        if annotationDragStart != nil {
            NSCursor.closedHand.set()
        } else if hoveredAnnotationID != nil {
            NSCursor.openHand.set()
        } else if activeTool == .text {
            NSCursor.iBeam.set()
        } else if activeTool != nil {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func resizeCursor(for handle: SelectionResizeHandle) -> NSCursor {
        switch handle {
        case .north, .south: .resizeUpDown
        case .west, .east: .resizeLeftRight
        case .northWest, .southEast: .crosshair
        case .northEast, .southWest: .crosshair
        }
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(start.x - end.x),
            height: abs(start.y - end.y)
        )
    }

    private func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(rect.maxX, max(rect.minX, point.x)),
            y: min(rect.maxY, max(rect.minY, point.y))
        )
    }

    private func clampedResizeHitPosition(
        _ point: CGPoint,
        in bounds: CGRect,
        radius: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: min(bounds.maxX - radius, max(bounds.minX + radius, point.x)),
            y: min(bounds.maxY - radius, max(bounds.minY + radius, point.y))
        )
    }

    private func arrowHeadPath(from start: CGPoint, to end: CGPoint, length: CGFloat) -> Path {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let spread = CGFloat.pi / 6
        let first = CGPoint(
            x: end.x - length * cos(angle - spread),
            y: end.y - length * sin(angle - spread)
        )
        let second = CGPoint(
            x: end.x - length * cos(angle + spread),
            y: end.y - length * sin(angle + spread)
        )
        var path = Path()
        path.move(to: first)
        path.addLine(to: end)
        path.addLine(to: second)
        return path
    }
}
