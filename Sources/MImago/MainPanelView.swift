import FormaUI
import SwiftUI

enum PanelSection: String, CaseIterable, Identifiable, CustomStringConvertible {
    case screenshot
    case recording
    case system
    case general

    var id: String { rawValue }
    var description: String { title }

    var title: String {
        switch self {
        case .screenshot: "截图"
        case .recording: "录屏"
        case .system: "系统"
        case .general: "通用"
        }
    }

    var icon: String {
        switch self {
        case .screenshot: "camera.viewfinder"
        case .recording: "record.circle"
        case .system: "desktopcomputer"
        case .general: "slider.horizontal.3"
        }
    }

    var subtitle: String {
        switch self {
        case .screenshot: "截图操作、完成方式与快捷键"
        case .recording: "录屏操作、画质声音与快捷键"
        case .system: "权限、系统入口与登录行为"
        case .general: "公共保存位置与应用信息"
        }
    }
}

struct MainPanelView: View {
    @State private var selection: PanelSection = .screenshot

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader()

            StatusOverviewPanel(selection: $selection)

            PanelModeSwitcher(selection: $selection)

            DetailView(selection: selection)
                .id(selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 840)
        .background(FormaTheme.canvas.ignoresSafeArea())
        .task {
            await MImagoPermissions.shared.synchronizeRecordingPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await MImagoPermissions.shared.synchronizeRecordingPermission() }
        }
    }
}

private struct StatusOverviewPanel: View {
    @Binding var selection: PanelSection
    @ObservedObject private var capture = CaptureController.shared
    @ObservedObject private var capturePreferences = CapturePreferences.shared
    @ObservedObject private var recordingPreferences = RecordingPreferences.shared
    @ObservedObject private var permissions = MImagoPermissions.shared.center
    @ObservedObject private var application = ApplicationPreferences.shared

    var body: some View {
        FormaStatusBoard(
            subtitle: capture.statusMessage,
            items: statusItems
        ) {
            FormaTextSlotReel(
                items: PanelSection.allCases.map(\.title),
                selectionIndex: Binding(
                    get: { PanelSection.allCases.firstIndex(of: selection) ?? 0 },
                    set: { selection = PanelSection.allCases[$0] }
                ),
                size: .small,
                wraps: true
            )
            .frame(width: 112)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(FormaTheme.surface)
    }

    private var statusItems: [FormaStatusBoardItem] {
        switch selection {
        case .screenshot:
            return [
                .init(id: "capture-result", label: "当前结果", detail: capture.statusMessage, tone: captureTone),
                .init(id: "completion", label: "完成后", detail: capturePreferences.screenshotCompletion.description),
                .init(id: "format", label: "图片格式", detail: "PNG", tone: .info),
                .init(
                    id: "thumbnail",
                    label: "浮动缩略图",
                    detail: capturePreferences.thumbnailDuration == 0 ? "关闭" : "",
                    tone: capturePreferences.thumbnailDuration == 0 ? .info : .success,
                    reelValue: capturePreferences.thumbnailDuration,
                    reelFractionDigits: 1,
                    reelSuffix: "秒"
                )
            ]
        case .recording:
            return [
                .init(id: "recording-result", label: "录屏状态", detail: capture.statusMessage, tone: captureTone),
                .init(id: "quality", label: "清晰度", detail: recordingPreferences.quality.description),
                .init(
                    id: "rate-format",
                    label: "帧率与格式",
                    detail: "\(recordingPreferences.frameRate) · \(recordingPreferences.format)"
                ),
                .init(
                    id: "audio",
                    label: "声音",
                    detail: audioSummary,
                    tone: recordingPreferences.capturesMicrophone ? .success : .info
                )
            ]
        case .system:
            let behavior = application.behavior
            return [
                permissionItem(.screenRecording, id: "screen", label: "屏幕录制"),
                permissionItem(.microphone, id: "microphone", label: "麦克风"),
                .init(id: "dock", label: "Dock 图标", detail: behavior.showsDockIcon ? "显示" : "隐藏"),
                .init(
                    id: "startup",
                    label: "后台入口",
                    detail: backgroundEntrySummary,
                    tone: application.showsMenuBar ? .success : .warning
                )
            ]
        case .general:
            return [
                .init(
                    id: "directory",
                    label: "公共保存位置",
                    detail: capturePreferences.saveDirectory?.lastPathComponent ?? "未设置",
                    tone: capturePreferences.saveDirectory == nil ? .warning : .success
                ),
                .init(id: "sharing", label: "截图与录屏", detail: "共用保存目录"),
                .init(id: "product", label: "品牌", detail: "M · IMAGO", tone: .info),
                .init(id: "version", label: "应用", detail: "M · IMAGO")
            ]
        }
    }

    private var captureTone: FormaTone {
        if capture.statusMessage.contains("失败") || capture.statusMessage.contains("无法") { return .error }
        if capture.statusMessage.contains("正在") || capture.statusMessage.contains("选择") { return .warning }
        return .success
    }

    private var audioSummary: String {
        let sources = [
            recordingPreferences.capturesSystemAudio ? "系统" : nil,
            recordingPreferences.capturesMicrophone ? "麦克风" : nil
        ].compactMap { $0 }
        return sources.isEmpty ? "关闭" : sources.joined(separator: " + ")
    }

    private var backgroundEntrySummary: String {
        let menuBar = application.showsMenuBar ? "开" : "关"
        let launch = application.behavior.launchAtLoginStatus == .enabled ? "开" : "关"
        return "菜单栏\(menuBar) · 自启动\(launch)"
    }

    private func permissionItem(
        _ kind: FormaPermissionKind,
        id: String,
        label: String
    ) -> FormaStatusBoardItem {
        let status = permissions.status(for: kind)
        return .init(
            id: id,
            label: label,
            detail: status.title(in: .chinese),
            tone: status.tone
        )
    }
}

private struct WorkspaceHeader: View {
    var body: some View {
        HStack(spacing: 14) {
            BrandMark()

            Text("M · IMAGO")
                .font(.formaBody(19, weight: .bold))
                .tracking(0.5)

            Spacer()
        }
        .padding(.leading, 20)
        .padding(.trailing, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .background(FormaTheme.surface)
        .overlay(alignment: .bottom) {
            FormaSectionDivider()
        }
    }
}

private struct BrandMark: View {
    var body: some View {
        if let url = Bundle.module.url(forResource: "AppIcon-1024", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct PanelModeSwitcher: View {
    @Binding var selection: PanelSection

    var body: some View {
        HStack(spacing: 8) {
            ForEach(PanelSection.allCases) { section in
                FormaButton(
                    section.title,
                    systemImage: section.icon,
                    role: .secondary,
                    size: .medium,
                    labelSize: .small,
                    showsSelectionDot: true,
                    isSelected: selection == section,
                    depth: .raised
                ) {
                    selection = section
                }
                .accessibilityHint(section.subtitle)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .background(FormaTheme.surface)
        .overlay(alignment: .bottom) {
            FormaSectionDivider()
        }
    }
}

private struct DetailView: View {
    let selection: PanelSection

    var body: some View {
        FormaScrollView(size: .small, showsTrack: true) {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 26)
            .frame(maxWidth: 492, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .screenshot: ScreenshotPanel()
        case .recording: RecordingPanel()
        case .system: SystemSettingsPanel()
        case .general: GeneralSettingsPanel()
        }
    }
}

private struct ScreenshotPanel: View {
    @ObservedObject private var capture = CaptureController.shared
    @ObservedObject private var preferences = CapturePreferences.shared
    @State private var isSaveDirectoryDialogPresented = false
    @State private var pendingAction: (() -> Void)?

    var body: some View {
        FormaCard(title: "截图操作", subtitle: "选择区域或直接截取主显示器") {
            HStack(spacing: 12) {
                FormaButton("自由截图", systemImage: "viewfinder", depth: .raised) {
                    runWhenReady {
                        CaptureController.shared.requestFreeScreenshot()
                    }
                }
                FormaButton("截取主显示器", systemImage: "camera", role: .secondary) {
                    runWhenReady {
                        MImagoPermissions.shared.performWithScreenCapturePermission {
                            CaptureController.shared.takeScreenshot()
                        }
                    }
                }
            }
            FormaInlineMessage(
                capture.statusMessage,
                detail: preferences.saveDirectory == nil
                    ? "默认复制到剪贴板；保存时会要求选择截图和录屏共用的保存位置。"
                    : "保存位置：\(preferences.saveDirectory!.lastPathComponent)",
                tone: .info
            )
        }

        CaptureSettings()

        ShortcutSettings(kind: .screenshot)
        .overlay {
            FormaDialog(
                title: "选择保存位置",
                message: "截图和录屏将共用这个文件夹。默认复制无需设置保存位置。",
                isPresented: $isSaveDirectoryDialogPresented
            ) {
                HStack {
                    FormaButton("暂不设置", role: .secondary) {
                        isSaveDirectoryDialogPresented = false
                        pendingAction = nil
                    }
                    FormaButton("选择存储路径", systemImage: "folder") {
                        isSaveDirectoryDialogPresented = false
                        CapturePreferences.shared.chooseSaveDirectory {
                            let action = pendingAction
                            pendingAction = nil
                            action?()
                        }
                    }
                }
            }
        }
    }

    private func runWhenReady(requiresDirectory: Bool? = nil, action: @escaping () -> Void) {
        let needsDirectory = requiresDirectory ?? preferences.screenshotCompletion.needsDirectory
        guard !needsDirectory || preferences.saveDirectory != nil else {
            pendingAction = action
            isSaveDirectoryDialogPresented = true
            return
        }
        action()
    }
}

private struct RecordingPanel: View {
    @ObservedObject private var capture = CaptureController.shared
    @ObservedObject private var preferences = CapturePreferences.shared
    @State private var isSaveDirectoryDialogPresented = false
    @State private var pendingAction: (() -> Void)?

    var body: some View {
        FormaCard(title: "录屏操作", subtitle: "先选择录制范围，再在浮动面板中确认参数") {
            HStack(spacing: 12) {
                FormaButton(
                    capture.isRecording ? "停止并保存" : "选择区域并录屏",
                    systemImage: capture.isRecording ? "stop.circle" : "record.circle",
                    role: capture.isRecording ? .destructive : .primary,
                    depth: .raised
                ) {
                    if capture.isRecording {
                        capture.stopRecording()
                    } else {
                        runWhenReady {
                            CaptureController.shared.requestRecordingSelection()
                        }
                    }
                }
            }
            FormaInlineMessage(
                capture.statusMessage,
                detail: preferences.saveDirectory == nil
                    ? "录屏需要保存位置，开始前会引导选择截图和录屏共用的文件夹。"
                    : "保存位置：\(preferences.saveDirectory!.lastPathComponent)",
                tone: .info
            )
        }

        RecordingSettings()

        ShortcutSettings(kind: .recording)
            .overlay {
                FormaDialog(
                    title: "选择保存位置",
                    message: "截图和录屏将共用这个文件夹。设置后会继续进入录屏区域选择。",
                    isPresented: $isSaveDirectoryDialogPresented
                ) {
                    HStack {
                        FormaButton("取消", role: .secondary) {
                            isSaveDirectoryDialogPresented = false
                            pendingAction = nil
                        }
                        FormaButton("选择存储路径", systemImage: "folder") {
                            isSaveDirectoryDialogPresented = false
                            CapturePreferences.shared.chooseSaveDirectory {
                                let action = pendingAction
                                pendingAction = nil
                                action?()
                            }
                        }
                    }
                }
            }
    }

    private func runWhenReady(action: @escaping () -> Void) {
        guard preferences.saveDirectory != nil else {
            pendingAction = action
            isSaveDirectoryDialogPresented = true
            return
        }
        action()
    }
}

private struct SystemSettingsPanel: View {
    var body: some View {
        AppearanceSettings()
        FormaDisclosure(
            "权限",
            detail: "截图、录屏和通知所需的系统授权",
            size: .small,
            initiallyExpanded: false
        ) {
            PermissionSettings()
        }
    }
}

private struct GeneralSettingsPanel: View {
    var body: some View {
        SoundSettings()
        StorageSettings()
        FeedbackSettings()
        ApplicationInfoSettings()
    }
}

private struct SoundSettings: View {
    var body: some View {
        FormaCard(title: "界面音效", subtitle: "统一控制所有 FormaUI 组件的反馈声音", size: .small) {
            FormaFormRow("音效方案", detail: "静音、经典或机械音效", size: .small) {
                FormaSoundSetControl(size: .small)
            }
        }
    }
}

private struct CaptureSettings: View {
    @ObservedObject private var preferences = CapturePreferences.shared
    @State private var includeCursor = true

    var body: some View {
        FormaCard(title: "默认行为", subtitle: "截图完成后的处理方式", size: .small) {
            DropdownSettingsRow("完成后") {
                FormaDropdown(
                    "完成后",
                    items: ScreenshotCompletion.allCases,
                    selection: $preferences.screenshotCompletion,
                    size: .medium
                )
            }
            .zIndex(20)
            FormaSectionDivider()
                .zIndex(0)
            FormaFormRow("图片格式", detail: "当前截图格式", size: .small) {
                FormaBadge("PNG", tone: .info, size: .small)
            }
                .zIndex(0)
        }
        .zIndex(10)
        FormaSection(
            title: "捕获选项",
            footer: preferences.thumbnailDuration == 0
                ? "浮动缩略图已关闭"
                : "截图完成后在右下角显示 \(preferences.thumbnailDuration.formatted(.number.precision(.fractionLength(1)))) 秒"
        ) {
            SettingsSwitchRow(
                "包含鼠标指针",
                detail: "区域和全屏截图可单独调整",
                isOn: $includeCursor
            )
            FormaSectionDivider()
            FormaSlider(
                "浮动缩略图时长",
                value: Binding(
                    get: { preferences.thumbnailDuration },
                    set: { preferences.setThumbnailDuration($0) }
                ),
                range: 0...6,
                step: 0.1,
                formatter: { value in
                    value == 0 ? "关闭" : String(format: "%.1f 秒", value)
                }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .zIndex(0)
    }
}

private struct RecordingSettings: View {
    @ObservedObject private var preferences = RecordingPreferences.shared

    var body: some View {
        FormaCard(title: "画面与文件", subtitle: "这里的值会作为录屏浮动面板的默认值", size: .small) {
            DropdownSettingsRow("清晰度") {
                FormaDropdown(
                    "清晰度",
                    items: RecordingQuality.allCases,
                    selection: $preferences.quality,
                    size: .medium
                )
            }
            .zIndex(50)
            FormaSectionDivider()
            DropdownSettingsRow("帧率") {
                FormaDropdown(
                    "帧率",
                    items: RecordingFPS.allCases,
                    selection: $preferences.frameRate,
                    size: .medium
                )
            }
            .zIndex(40)
            FormaSectionDivider()
            DropdownSettingsRow("格式") {
                FormaDropdown(
                    "格式",
                    items: RecordingFileFormat.allCases,
                    selection: $preferences.format,
                    size: .medium
                )
            }
            .zIndex(30)
            FormaSectionDivider()
            DropdownSettingsRow("倒计时") {
                FormaDropdown(
                    "倒计时",
                    items: RecordingCountdown.allCases,
                    selection: $preferences.countdown,
                    size: .medium
                )
            }
            .zIndex(20)
            FormaSectionDivider()
            DropdownSettingsRow("最长录制时长") {
                FormaDropdown(
                    "最长录制时长",
                    items: RecordingDuration.allCases,
                    selection: $preferences.duration,
                    size: .medium
                )
            }
            .zIndex(10)
        }
        .zIndex(50)

        FormaSection(title: "声音") {
            SettingsSwitchRow(
                "系统声音",
                detail: "捕获应用与系统播放声音",
                isOn: $preferences.capturesSystemAudio
            )
            FormaSectionDivider()
            SettingsSwitchRow(
                "麦克风",
                detail: "使用系统默认输入设备",
                isOn: microphoneBinding
            )
        }
        .zIndex(10)

        FormaSection(title: "鼠标") {
            SettingsSwitchRow(
                "显示鼠标点击",
                detail: "录制时标记鼠标点击位置",
                isOn: $preferences.showsMouseClicks
            )
            FormaSectionDivider()
            SettingsSwitchRow(
                "显示光标",
                detail: "在录制结果中保留鼠标指针",
                isOn: $preferences.showsCursor
            )
        }
        .zIndex(0)

    }

    private var microphoneBinding: Binding<Bool> {
        Binding(
            get: { preferences.capturesMicrophone },
            set: { isEnabled in
                guard isEnabled else {
                    preferences.capturesMicrophone = false
                    return
                }
                Task { @MainActor in
                    let isAuthorized = await MImagoPermissions.shared.ensureMicrophoneAuthorization()
                    preferences.capturesMicrophone = isAuthorized
                    if !isAuthorized {
                        CaptureController.shared.setStatusMessage("麦克风权限未开启，已关闭麦克风录制。")
                    }
                }
            }
        )
    }
}

private struct DropdownSettingsRow<Accessory: View>: View {
    let title: String
    @ViewBuilder let accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.formaBody(12, weight: .semibold))
            Spacer(minLength: 16)
            accessory
        }
        .padding(.vertical, 0)
    }
}

/// `FormaSection` owns the surrounding card and dividers; toggle rows own their insets.
/// `FormaSwitch` deliberately has no horizontal container padding because it is also used
/// in compact toolbars, so settings screens add this spacing at the composition layer.
private struct SettingsSwitchRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    init(_ title: String, detail: String, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        FormaSwitch(title, detail: detail, isOn: $isOn)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }
}

private enum ShortcutSettingsKind {
    case screenshot
    case recording
}

private struct ShortcutSettings: View {
    let kind: ShortcutSettingsKind
    @ObservedObject private var shortcuts = ShortcutSettingsStore.shared

    var body: some View {
        FormaCard(title: "快捷键", subtitle: "点击后录入；保存时检查系统和应用内冲突", size: .small) {
            if kind == .screenshot {
                ShortcutSettingsRow(
                    "区域截图",
                    shortcut: shortcuts.binding(for: "shortcut.region-capture")
                )
                FormaSectionDivider()
                ShortcutSettingsRow(
                    "全屏截图",
                    shortcut: shortcuts.binding(for: "shortcut.full-screen-capture")
                )
            } else {
                ShortcutSettingsRow(
                    "区域录屏",
                    shortcut: shortcuts.binding(for: "shortcut.region-recording")
                )
                FormaSectionDivider()
                ShortcutSettingsRow(
                    "停止录屏",
                    shortcut: shortcuts.binding(for: "shortcut.stop-recording")
                )
            }
            if let validationMessage = shortcuts.validationMessage {
                FormaInlineMessage(
                    "快捷键未保存",
                    detail: validationMessage,
                    tone: .warning
                )
            }
        }
    }
}

private struct ShortcutSettingsRow: View {
    let title: String
    @Binding var shortcut: FormaGlobalShortcut?

    init(_ title: String, shortcut: Binding<FormaGlobalShortcut?>) {
        self.title = title
        self._shortcut = shortcut
    }

    var body: some View {
        FormaFormRow(title, size: .small) {
            FormaShortcutRecorder(shortcut: $shortcut, size: .small)
        }
    }
}

private struct PermissionSettings: View {
    @ObservedObject private var permissions = MImagoPermissions.shared.center

    var body: some View {
        FormaPermissionChecklist(
            [.accessibility, .screenRecording, .microphone, .camera, .notifications],
            center: permissions,
            actionStyle: .authorization
        )
        .task {
            for permission in [
                FormaPermissionKind.accessibility,
                .screenRecording,
                .microphone,
                .camera,
                .notifications
            ] {
                _ = await permissions.refresh(permission)
            }
        }
    }
}

private struct StorageSettings: View {
    @ObservedObject private var preferences = CapturePreferences.shared

    var body: some View {
        FormaCard(title: "公共保存位置", subtitle: "截图和录屏使用同一文件夹", size: .small) {
            FormaFormRow("当前文件夹", detail: preferences.saveDirectory?.path ?? "尚未设置", size: .small) {
                FormaButton(
                    preferences.saveDirectory == nil ? "选择存储路径" : "更换存储路径",
                    systemImage: "folder",
                    role: .secondary,
                    size: .small
                ) {
                    preferences.chooseSaveDirectory()
                }
            }
        }
    }
}

private struct FeedbackSettings: View {
    var body: some View {
        FormaCard(
            title: "问题反馈",
            subtitle: "反馈时可自动附带诊断信息；当前版本仅提供交互预览",
            size: .small
        ) {
            FormaFormRow(
                "反馈与诊断",
                detail: "在独立打印窗口中填写和预览反馈",
                size: .small
            ) {
                FormaButton(
                    "提交反馈",
                    systemImage: "printer.fill",
                    role: .secondary,
                    size: .small
                ) {
                    FeedbackPrinterWindowController.shared.show()
                }
            }
        }
    }
}

private struct ApplicationInfoSettings: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    }

    var body: some View {
        FormaDisclosure(
            "应用信息",
            detail: "品牌与当前构建",
            size: .small,
            initiallyExpanded: false
        ) {
            VStack(spacing: 0) {
                FormaFormRow("品牌", detail: "MODUS", size: .small) {
                    FormaBadge("M · IMAGO", tone: .info, size: .small)
                }
                FormaSectionDivider()
                FormaFormRow("版本", detail: "M · IMAGO", size: .small) {
                    FormaBadge(version, tone: .success, size: .small)
                }
            }
        }
    }
}

private struct AppearanceSettings: View {
    @ObservedObject private var application = ApplicationPreferences.shared
    @ObservedObject private var behavior = ApplicationPreferences.shared.behavior

    var body: some View {
        FormaSection(title: "应用图标") {
            SettingsSwitchRow(
                "在 Dock 中显示",
                detail: "关闭后应用仍可通过菜单栏和快捷键使用",
                isOn: Binding(
                    get: { behavior.showsDockIcon },
                    set: { behavior.setDockIconVisible($0) }
                )
            )
            FormaSectionDivider()
            SettingsSwitchRow(
                "显示菜单栏图标",
                detail: "关闭前请确认已配置其他进入方式",
                isOn: Binding(
                    get: { application.showsMenuBar },
                    set: { application.setMenuBarVisible($0) }
                )
            )
        }
        FormaSection(title: "启动") {
            SettingsSwitchRow(
                "登录时启动",
                detail: "由 macOS 登录项管理",
                isOn: Binding(
                    get: { behavior.launchAtLoginStatus == .enabled },
                    set: { behavior.setLaunchAtLogin($0) }
                )
            )
        }
        .task { behavior.refresh() }
    }
}

struct MenuBarPanel: View {
    let openMainWindow: () -> Void

    var body: some View {
        FormaMenuBarPanel(
            title: "M · Imago",
            subtitle: "MODUS",
            status: "准备就绪",
            actions: [
                FormaMenuBarPanelAction(id: "free-screenshot", title: "自由截图", systemImage: "viewfinder") {
                    CaptureController.shared.requestFreeScreenshot()
                },
                FormaMenuBarPanelAction(id: "screenshot", title: "截取主显示器", systemImage: "camera") {
                    MImagoPermissions.shared.performWithScreenCapturePermission {
                        CaptureController.shared.takeScreenshot()
                    }
                },
                FormaMenuBarPanelAction(id: "record", title: "开始/停止录屏", systemImage: "record.circle") {
                    if CaptureController.shared.isRecording {
                        CaptureController.shared.stopRecording()
                    } else {
                        CaptureController.shared.requestRecordingSelection()
                    }
                },
                FormaMenuBarPanelAction(id: "open", title: "打开主面板", systemImage: "macwindow", action: openMainWindow),
                FormaMenuBarPanelAction(id: "quit", title: "退出", systemImage: "power", role: .destructive) { NSApp.terminate(nil) }
            ]
        )
    }
}
