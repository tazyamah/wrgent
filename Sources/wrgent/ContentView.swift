import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var recorder: AudioRecorder
    @State private var editingMeetingId: String? = nil
    @State private var editingMeetingName = ""
    @State private var showAdvancedSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            statusSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            weekSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            advancedSettingsSection
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 360)
    }

    // MARK: - Header

    private var headerSection: some View {
        Text("wrgent")
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 10)
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusIcon
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(statusColor)
            }

            if recorder.isRecording {
                Text(timeString(recorder.elapsed))
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if !recorder.transcriptionStatus.isEmpty {
                Text(recorder.transcriptionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if !recorder.statusMessage.isEmpty {
                Text(recorder.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if recorder.needsScreenPermission {
                VStack(alignment: .leading, spacing: 4) {
                    Text("「画面収録」の許可が必要です")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    MenuBarActionButton("システム設定を開く", onClick: recorder.requestScreenAccess)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
            }

            manualRecordingControls
        }
    }

    @ViewBuilder
    private var manualRecordingControls: some View {
        if recorder.isFinalizingRecording {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("録音ファイルを保存中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 28)
        } else if recorder.isRecording {
            RecordingActionButton(
                title: "録音を停止",
                systemImage: "stop.circle.fill",
                isDestructive: true,
                onClick: { recorder.stopRecording() }
            )
            .frame(maxWidth: .infinity, minHeight: 28)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                TextField("録音名（省略可）", text: $recorder.recordingName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                RecordingActionButton(
                    title: recorder.isStarting ? "録音開始をやり直す" : "手動で録音を開始",
                    systemImage: recorder.isStarting ? "arrow.clockwise.circle" : "record.circle",
                    isDestructive: false,
                    onClick: { recorder.startRecording() }
                )
                .frame(maxWidth: .infinity, minHeight: 28)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if recorder.isRecording {
            Image(systemName: "mic.fill").foregroundStyle(.red).font(.system(size: 16))
        } else if recorder.isFinalizingRecording {
            Image(systemName: "externaldrive.fill").foregroundStyle(.orange).font(.system(size: 16))
        } else if recorder.isTranscribing {
            Image(systemName: "waveform").foregroundStyle(Color.accentColor).font(.system(size: 16))
        } else if recorder.isGeneratingSummary {
            Image(systemName: "doc.text").foregroundStyle(Color.accentColor).font(.system(size: 16))
        } else {
            Image(systemName: "clock").foregroundStyle(.secondary).font(.system(size: 16))
        }
    }

    private var statusText: String {
        if recorder.isRecording {
            return "録音中"
        } else if recorder.isFinalizingRecording {
            return "録音を保存中…"
        } else if recorder.isStarting {
            return "録音を開始中…"
        } else if recorder.isTranscribing {
            return "文字起こし中…"
        } else if recorder.isGeneratingSummary {
            return "まとめを生成中…"
        } else if recorder.autoRecordZoom {
            return "待機中（Zoom監視中）"
        } else {
            return "待機中"
        }
    }

    private var statusColor: Color {
        if recorder.isRecording { return .red }
        if recorder.isTranscribing || recorder.isGeneratingSummary { return .accentColor }
        return .secondary
    }

    // MARK: - This week's meetings

    private var weekSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                CodexActionButton(
                    title: "予定取得",
                    systemImage: "calendar.badge.plus",
                    onClick: { recorder.openCalendarImportInCodex() }
                )
                .fixedSize()

                MenuBarActionButton(
                    "",
                    systemImage: "arrow.clockwise",
                    onClick: recorder.reloadCalendarAndMeetings
                )
                .help("予定と打ち合わせ名を再読み込み")

                if recorder.calendarImportedCount > 0 {
                    Text("\(recorder.calendarImportedCount)件")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Spacer(minLength: 0)
                WeekPopupButton(
                    weeks: recorder.availableWeeks,
                    selectedWeek: recorder.selectedWeek,
                    label: weekPickerLabel,
                    onSelect: selectWeek
                )
                .frame(maxWidth: 180)
            }

            if recorder.weeklyMeetings.isEmpty {
                Text("今週の録音はまだありません")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(recorder.weeklyMeetings) { meeting in
                    meetingRow(meeting)
                }
            }

            let transcribedCount = recorder.weeklyMeetings.filter(\.hasTranscript).count
            MenuBarActionButton(
                "Codexで週報を生成",
                systemImage: "sparkles.rectangle.stack",
                isEnabled: transcribedCount > 0,
                style: .prominent,
                onClick: recorder.openWeeklyReportInCodex
            )
            .frame(maxWidth: .infinity, minHeight: 28)
            .padding(.top, 4)

            if recorder.pendingTranscriptionCount > 0 {
                Text("未完了の文字起こしを自動処理中: \(recorder.pendingTranscriptionCount)件")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if transcribedCount > 0 {
                Text("summary.txtは文字起こし完了時に自動更新されます")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private func meetingRow(_ meeting: MeetingRecord) -> some View {
        if editingMeetingId == meeting.id {
            HStack(spacing: 4) {
                TextField("打ち合わせ名", text: $editingMeetingName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { commitEdit(meeting) }
                MenuBarActionButton(
                    "",
                    systemImage: "checkmark",
                    controlSize: .mini,
                    style: .prominent,
                    onClick: { commitEdit(meeting) }
                )
                MenuBarActionButton(
                    "",
                    systemImage: "xmark",
                    controlSize: .mini,
                    onClick: { editingMeetingId = nil }
                )
            }
            .padding(.vertical, 1)
        } else {
            HStack(spacing: 6) {
                Image(systemName: meeting.hasTranscript ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(meeting.hasTranscript ? .green : .secondary)
                    .font(.caption)
                MenuBarActionButton(
                    meetingLabel(meeting),
                    controlSize: .mini,
                    style: .plain,
                    onClick: { beginEdit(meeting) }
                )
                .lineLimit(1)
                .foregroundStyle(
                    meeting.includeInInsight
                        ? (meeting.hasTranscript ? Color.primary : Color.secondary)
                        : Color.secondary.opacity(0.65)
                )
                Spacer(minLength: 0)
                MenuBarActionButton(
                    "",
                    systemImage: meeting.includeInInsight ? "lightbulb.fill" : "lightbulb.slash",
                    controlSize: .mini,
                    style: .plain,
                    onClick: {
                        recorder.setMeetingInsightIncluded(
                            folderName: meeting.id,
                            included: !meeting.includeInInsight
                        )
                    }
                )
                .help(meeting.includeInInsight ? "クリックしてインサイト対象外にする" : "クリックしてインサイト対象に戻す")
                MenuBarActionButton(
                    "",
                    systemImage: meeting.useExternalTranscriptForSummary ? "speaker.wave.2.fill" : "mic.fill",
                    controlSize: .mini,
                    style: .plain,
                    onClick: {
                        recorder.setMeetingSummaryTranscriptSource(
                            folderName: meeting.id,
                            externalOnly: !meeting.useExternalTranscriptForSummary
                        )
                    }
                )
                .help(meeting.useExternalTranscriptForSummary ? "週報には全音声版を使う" : "週報には外部音声のみ版を使う")
                if !meeting.hasTranscript {
                    MenuBarActionButton(
                        "",
                        systemImage: recorder.isMeetingInTranscriptionQueue(meeting) ? "clock" : "waveform",
                        controlSize: .mini,
                        style: .plain,
                        onClick: { recorder.enqueueMeetingForTranscription(meeting) }
                    )
                    .help("文字起こしを開始")
                }
                MenuBarActionButton(
                    "",
                    systemImage: "pencil",
                    controlSize: .mini,
                    style: .plain,
                    onClick: { beginEdit(meeting) }
                )
            }
        }
    }

    private func beginEdit(_ meeting: MeetingRecord) {
        editingMeetingId = meeting.id
        editingMeetingName = meeting.displayName
    }

    private func commitEdit(_ meeting: MeetingRecord) {
        recorder.setMeetingName(folderName: meeting.id, name: editingMeetingName)
        editingMeetingId = nil
    }

    private func meetingLabel(_ meeting: MeetingRecord) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "M/d(EEE) HH:mm"
        return "\(df.string(from: meeting.date))  \(meeting.displayName)"
    }

    private func weekPickerLabel(_ week: String) -> String {
        let (start, end) = WeeklySummaryGenerator.weekRange(forFolderName: week)
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "M/d"
        let endDisplay = end.addingTimeInterval(-1)
        let isCurrent = week == WeeklySummaryGenerator.weekFolderName(for: Date())
        let label = "\(week)  \(df.string(from: start))〜\(df.string(from: endDisplay))"
        return isCurrent ? "\(label)（今週）" : label
    }

    /// AppKit is still tracking the popup menu when it delivers its action.
    /// Defer all published-state changes until that tracking cycle has returned.
    private func selectWeek(_ week: String) {
        guard week != recorder.selectedWeek else { return }
        Task { @MainActor in
            await Task.yield()
            recorder.selectedWeek = week
            recorder.refreshWeeklyMeetings()
            recorder.refreshCalendarCount()
            editingMeetingId = nil
        }
    }

    // MARK: - Advanced settings

    private var advancedSettingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuBarActionButton(
                "その他の設定",
                systemImage: showAdvancedSettings ? "chevron.down" : "chevron.right",
                style: .plain,
                onClick: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showAdvancedSettings.toggle()
                    }
                }
            )

            if showAdvancedSettings {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Whisperモデル")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ModelPopupButton(
                        models: AudioRecorder.modelOptions,
                        selectedModel: $recorder.selectedModelName,
                        isEnabled: !recorder.isTranscribing
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !recorder.modelReady {
                    MenuBarActionButton(
                        "選択中のモデルを取得",
                        isEnabled: !recorder.isTranscribing,
                        onClick: recorder.downloadModel
                    )
                }

                HStack(spacing: 12) {
                    MenuBarCheckbox(
                        "Zoom自動録音",
                        isOn: $recorder.autoRecordZoom,
                        isEnabled: !recorder.isRecording &&
                            !recorder.isStarting &&
                            !recorder.isFinalizingRecording
                    )
                    MenuBarCheckbox("自動文字起こし", isOn: $recorder.autoTranscribe)
                }

                HStack(spacing: 8) {
                    Text(recorder.libraryDisplay)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    MenuBarActionButton(
                        "開く",
                        controlSize: .mini,
                        onClick: recorder.openLibraryInFinder
                    )
                    MenuBarActionButton(
                        "変更",
                        isEnabled: !recorder.isRecording &&
                            !recorder.isStarting &&
                            !recorder.isFinalizingRecording &&
                            !recorder.isTranscribing,
                        controlSize: .mini,
                        onClick: recorder.chooseLibrary
                    )
                }
            }
            .padding(.top, 8)
            }
        }
        .font(.caption)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 8) {
            Text("build \(buildVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            MenuBarActionButton(
                "終了",
                style: .plain,
                onClick: { NSApp.terminate(nil) }
            )
            .foregroundStyle(.red)
        }
    }

    // MARK: - Helpers

    private var buildVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
