import AppKit
import FormaUI
import SwiftUI

enum RecordingQuality: String, CaseIterable, CustomStringConvertible, Sendable {
    case adaptive1080p = "1080p 自适应"
    case p720 = "720p"
    case original = "原始分辨率"

    var description: String { rawValue }
}

enum RecordingFPS: Int, CaseIterable, CustomStringConvertible, Sendable {
    case fps15 = 15
    case fps30 = 30
    case fps60 = 60

    var description: String { "\(rawValue) fps" }
}

enum RecordingFileFormat: String, CaseIterable, CustomStringConvertible, Sendable {
    case mp4 = "MP4"
    case mov = "MOV"

    var description: String { rawValue }
}

enum RecordingCountdown: Int, CaseIterable, CustomStringConvertible, Sendable {
    case off = 0
    case three = 3
    case five = 5

    var description: String {
        rawValue == 0 ? "关闭" : "\(rawValue) 秒"
    }
}

enum RecordingDuration: Int, CaseIterable, CustomStringConvertible, Sendable {
    case unlimited = 0
    case oneMinute = 1
    case fiveMinutes = 5
    case tenMinutes = 10
    case thirtyMinutes = 30
    case sixtyMinutes = 60

    var description: String {
        rawValue == 0 ? "不限时" : "\(rawValue) 分钟"
    }
}

struct RecordingOptions: Sendable, Hashable {
    var quality: RecordingQuality = .adaptive1080p
    var frameRate: RecordingFPS = .fps30
    var format: RecordingFileFormat = .mp4
    var capturesSystemAudio = true
    var capturesMicrophone = false
    var showsCursor = true
    var showsMouseClicks = true
    var countdownSeconds = 3
    var maximumDurationMinutes = 0
}

/// Recording controls are kept inside the capture overlay so the selected
/// region stays visible while its settings are adjusted.
struct RecordingSetupPanelView: View {
    let selectionDescription: String
    let onStart: (RecordingOptions) -> Void
    let onCancel: () -> Void

    @ObservedObject private var preferences = CapturePreferences.shared
    @ObservedObject private var recordingPreferences = RecordingPreferences.shared

    var body: some View {
        FormaCard(
            title: "M · IMAGO 录屏",
            subtitle: selectionDescription,
            size: .small
        ) {
            HStack(alignment: .top, spacing: 14) {
                recordingParameters
                    .zIndex(100)

                Rectangle()
                    .fill(FormaTheme.line)
                    .frame(width: 1, height: 148)

                captureSwitches
                    .zIndex(10)

                Rectangle()
                    .fill(FormaTheme.line)
                    .frame(width: 1, height: 148)

                actions
            }
        }
        .frame(width: 940)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await MImagoPermissions.shared.synchronizeRecordingPermission() }
        }
    }

    private var recordingParameters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                FormaDropdown(
                    "清晰度",
                    items: RecordingQuality.allCases,
                    selection: $recordingPreferences.quality,
                    size: .medium
                )
                .delayedFormaHelp(
                    "录制清晰度",
                    detail: "选择自适应 1080p、720p 或原始分辨率"
                )
                .zIndex(60)
                FormaDropdown(
                    "帧率",
                    items: RecordingFPS.allCases,
                    selection: $recordingPreferences.frameRate,
                    size: .medium
                )
                .delayedFormaHelp(
                    "录制帧率",
                    detail: "选择每秒 15、30 或 60 帧；帧率越高文件通常越大"
                )
                .zIndex(50)
            }
            .zIndex(60)

            HStack(spacing: 10) {
                FormaDropdown(
                    "格式",
                    items: RecordingFileFormat.allCases,
                    selection: $recordingPreferences.format,
                    size: .medium
                )
                .delayedFormaHelp(
                    "视频格式",
                    detail: "选择导出为 MP4 或 MOV 文件"
                )
                .zIndex(40)
                FormaDropdown(
                    "倒计时",
                    items: RecordingCountdown.allCases,
                    selection: $recordingPreferences.countdown,
                    size: .medium
                )
                .delayedFormaHelp(
                    "开始倒计时",
                    detail: "录制前显示 3 秒、5 秒倒计时，或立即开始"
                )
                .zIndex(30)
            }
            .zIndex(40)

            HStack(spacing: 10) {
                FormaDropdown(
                    "录屏时长",
                    items: RecordingDuration.allCases,
                    selection: $recordingPreferences.duration,
                    size: .medium
                )
                .delayedFormaHelp(
                    "最长录制时长",
                    detail: "到达设定时长后自动停止并保存；不限时则手动停止"
                )
                .zIndex(20)

                HStack(spacing: 7) {
                    Image(systemName: "folder.fill")
                    Text(preferences.saveDirectory?.lastPathComponent ?? "未设置保存位置")
                        .lineLimit(1)
                }
                .font(.formaBody(11, weight: .semibold))
                .foregroundStyle(
                    preferences.saveDirectory == nil
                        ? FormaTheme.accent
                        : FormaTheme.inkSoft
                )
                .frame(width: 190, alignment: .leading)
            }
            .zIndex(20)
        }
        .frame(width: 470)
    }

    private var captureSwitches: some View {
        VStack(alignment: .leading, spacing: 3) {
            FormaSwitch(
                "系统声音",
                detail: "捕获应用与系统播放声音",
                onSystemImage: "speaker.wave.2.fill",
                offSystemImage: "speaker.slash.fill",
                isOn: $recordingPreferences.capturesSystemAudio,
                size: .small
            )
            .delayedFormaHelp(
                "系统声音",
                detail: "录入应用播放和系统播放的声音"
            )
            FormaSwitch(
                "麦克风",
                detail: "使用系统默认输入设备",
                onSystemImage: "mic.fill",
                offSystemImage: "mic.slash.fill",
                isOn: microphoneBinding,
                size: .small
            )
            .delayedFormaHelp(
                "麦克风",
                detail: "录入系统默认麦克风；首次开启会检查权限"
            )
            FormaSwitch(
                "鼠标点击",
                onSystemImage: "cursorarrow.click.2",
                offSystemImage: "cursorarrow",
                isOn: $recordingPreferences.showsMouseClicks,
                size: .small
            )
            .delayedFormaHelp(
                "鼠标点击提示",
                detail: "在视频中显示鼠标点击的视觉反馈"
            )
            FormaSwitch(
                "显示光标",
                onSystemImage: "cursorarrow",
                offSystemImage: "cursorarrow.slash",
                isOn: $recordingPreferences.showsCursor,
                size: .small
            )
            .delayedFormaHelp(
                "显示光标",
                detail: "决定录制画面中是否包含鼠标指针"
            )
        }
        .frame(width: 250)
    }

    private var microphoneBinding: Binding<Bool> {
        Binding(
            get: { recordingPreferences.capturesMicrophone },
            set: { isEnabled in
                guard isEnabled else {
                    recordingPreferences.capturesMicrophone = false
                    return
                }
                Task { @MainActor in
                    let isAuthorized = await MImagoPermissions.shared.ensureMicrophoneAuthorization()
                    recordingPreferences.capturesMicrophone = isAuthorized
                    if !isAuthorized {
                        CaptureController.shared.setStatusMessage("麦克风权限未开启，已关闭麦克风录制。")
                    }
                }
            }
        )
    }

    private var actions: some View {
        VStack(spacing: 10) {
            FormaBadge("准备录制", tone: .success, size: .small)
            Spacer(minLength: 0)
            FormaButton(
                "开始录制",
                systemImage: "record.circle.fill",
                size: .medium,
                depth: .raised
            ) {
                onStart(recordingPreferences.options)
            }
            .frame(width: 140)
            .delayedFormaHelp(
                "开始录制",
                detail: "按当前参数启动倒计时并开始录屏"
            )

            FormaButton(
                "取消",
                systemImage: "xmark",
                role: .secondary,
                size: .small
            ) {
                onCancel()
            }
            .frame(width: 140)
            .delayedFormaHelp(
                "取消录制",
                detail: "关闭录屏选区并返回主窗口"
            )
        }
        .frame(width: 140, height: 148)
    }
}
