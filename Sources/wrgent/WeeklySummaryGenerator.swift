import Foundation

struct WeeklySummaryGenerator {

    struct MeetingInfo {
        let folderName: String
        let date: Date
        let displayName: String
        let hasTranscript: Bool
        let transcriptURL: URL?
        let includeInInsight: Bool
        let useExternalTranscriptForSummary: Bool
        let hasExternalTranscript: Bool
    }

    // MARK: - Week folder naming

    static func weekFolderName(for date: Date) -> String {
        var cal = Calendar(identifier: .iso8601)
        cal.locale = Locale(identifier: "en_US_POSIX")
        let week = cal.component(.weekOfYear, from: date)
        let year = cal.component(.yearForWeekOfYear, from: date)
        return String(format: "%04d_W%02d", year, week)
    }

    static func weekRange(forFolderName name: String) -> (start: Date, end: Date) {
        // name: "2026_W26"
        let parts = name.split(separator: "_")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let weekNum = Int(String(parts[1]).dropFirst()) else {
            return thisWeekRange()
        }
        var cal = Calendar(identifier: .iso8601)
        cal.locale = Locale(identifier: "en_US_POSIX")
        var comps = DateComponents()
        comps.yearForWeekOfYear = year
        comps.weekOfYear = weekNum
        comps.weekday = 2 // Monday
        guard let weekStart = cal.date(from: comps) else { return thisWeekRange() }
        return (weekStart, weekStart.addingTimeInterval(7 * 24 * 3600))
    }

    static func thisWeekRange() -> (start: Date, end: Date) {
        var cal = Calendar(identifier: .iso8601)
        cal.locale = Locale(identifier: "ja_JP")
        guard let interval = cal.dateInterval(of: .weekOfYear, for: Date()) else {
            let now = Date(); return (now, now)
        }
        return (interval.start, interval.end)
    }

    // MARK: - Public API

    static func generate(weekFolderURL: URL, weekFolderName: String, modelName: String) throws -> URL {
        let meetings = scanMeetings(in: weekFolderURL, modelName: modelName)
        let (weekStart, weekEnd) = weekRange(forFolderName: weekFolderName)
        let text = buildSummaryText(meetings: meetings, weekStart: weekStart, weekEnd: weekEnd)
        let outputURL = weekFolderURL.appendingPathComponent("summary.txt")
        try text.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    static func scanMeetings(in weekFolderURL: URL, modelName: String) -> [MeetingInfo] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: weekFolderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"

        let calEvents = CalendarStore.load(in: weekFolderURL)
        let customNames = MeetingNameStore.load(in: weekFolderURL)
        let insightSelection = MeetingInsightStore.load(in: weekFolderURL)
        let transcriptSourceSelection = MeetingSummaryTranscriptStore.load(in: weekFolderURL)

        var result: [MeetingInfo] = []
        for item in items {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let name = item.lastPathComponent
            guard !name.hasPrefix("_") else { continue }

            let timestampStr = name.components(separatedBy: " - ").first ?? name
            guard let date = df.date(from: timestampStr) else { continue }

            // Priority: user edit > calendar import > folder name > default
            let displayName: String
            if let custom = customNames[name], !custom.trimmingCharacters(in: .whitespaces).isEmpty {
                displayName = custom
            } else if !calEvents.isEmpty, let match = CalendarStore.matchEvent(recordingStart: date, in: calEvents) {
                displayName = match.title
            } else if let r = name.range(of: " - ") {
                displayName = String(name[r.upperBound...])
            } else {
                displayName = "Zoomミーティング"
            }

            let useExternalTranscriptForSummary = transcriptSourceSelection[name] ?? false
            let transcriptURL = bestTranscriptURL(
                in: item,
                modelName: modelName,
                externalOnly: useExternalTranscriptForSummary
            )
            result.append(MeetingInfo(
                folderName: name,
                date: date,
                displayName: displayName,
                hasTranscript: transcriptURL != nil,
                transcriptURL: transcriptURL,
                includeInInsight: insightSelection[name] ?? true,
                useExternalTranscriptForSummary: useExternalTranscriptForSummary,
                hasExternalTranscript: fm.fileExists(atPath: item.appendingPathComponent("transcript_external_\(modelName).txt").path)
            ))
        }
        return result.sorted { $0.date < $1.date }
    }

    // MARK: - Private helpers

    static func bestTranscriptURL(in folderURL: URL, modelName: String, externalOnly: Bool = false) -> URL? {
        let fm = FileManager.default
        let suffix = "_\(modelName).txt"
        if externalOnly {
            let external = folderURL.appendingPathComponent("transcript_external\(suffix)")
            return fm.fileExists(atPath: external.path) ? external : nil
        }
        let merged = folderURL.appendingPathComponent("transcript\(suffix)")
        if fm.fileExists(atPath: merged.path) { return merged }
        let mic = folderURL.appendingPathComponent("transcript_self\(suffix)")
        if fm.fileExists(atPath: mic.path) { return mic }
        let sys = folderURL.appendingPathComponent("transcript_other\(suffix)")
        if fm.fileExists(atPath: sys.path) { return sys }
        let all = (try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        return all.first { $0.lastPathComponent.hasPrefix("transcript") && $0.pathExtension == "txt" }
    }

    private static func buildSummaryText(meetings: [MeetingInfo], weekStart: Date, weekEnd: Date) -> String {
        let transcribedMeetings = meetings.filter { $0.hasTranscript && $0.includeInInsight }
        var cal = Calendar(identifier: .iso8601)
        cal.locale = Locale(identifier: "ja_JP")
        let dateDf = DateFormatter(); dateDf.locale = Locale(identifier: "ja_JP"); dateDf.dateFormat = "yyyy年M月d日（EEE）"
        let timeDf = DateFormatter(); timeDf.locale = Locale(identifier: "ja_JP"); timeDf.dateFormat = "HH:mm"
        let nowDf  = DateFormatter(); nowDf.locale  = Locale(identifier: "ja_JP"); nowDf.dateFormat  = "yyyy年M月d日 HH:mm"
        let displayEnd = weekEnd.addingTimeInterval(-1)
        var lines: [String] = []
        lines.append("# 今週の打ち合わせまとめ")
        lines.append("# 期間: \(dateDf.string(from: weekStart)) 〜 \(dateDf.string(from: displayEnd))")
        lines.append("# 生成日時: \(nowDf.string(from: Date()))")
        lines.append("# 打ち合わせ数: \(transcribedMeetings.count)件")
        lines.append("")
        lines.append("""
以下は、ユーザーが「インサイトに含める」と指定した打ち合わせや会話の文字起こしです。
予定名・会議名は誤検出されている可能性があるため、予定名や会議名を重視せず、実際の会話内容からテーマを判断してください。
新規録音は自分と相手の混合音声から文字起こししており、話者ラベルはありません。旧録音の話者ラベルはmic/system音声から機械的に付けたもので、同じ発話が両方へ入る場合もあります。[自分]の発言を優先せず、選択された会話全体から重要な論点、変化、判断材料、学びを読み取ってください。

目的：
単なる議事録要約ではなく、選択された会話を横断して、何が重要だったか、認識がどう変わったか、今後につながる示唆は何かが伝わる週次振り返りにしてください。

重視する観点：
- 会議ごとの個別まとめではなく、対象となる会話全体を通した単一のインサイトにする
- 話者ごとの発言量やラベルではなく、会話から得られる論点と示唆の強さで内容を選ぶ
- 「この打ち合わせで何があったか」ではなく、週を通じて残った問い、変化、次の判断につながる内容を中心にする
- 顧客名・会社名・人名は、内容を具体化するために必要な場合のみ最小限に使う
- 予定名、議事録名、文字起こし上の会議タイトルは本文にそのまま使わない
- 育児、雑談、単なる日程調整、音声認識ミス、意味の薄い発言は除外する
- 議事録に残っている内容だけを機械的に並べるのではなく、週次振り返りとして自然な文章に統合する

出力形式：
1行目は必ず以下の形式にしてください。

[WR:ISV 鈴木 達也 : YYYY/M/D-M/D] タイトル

日付ルール：
- YYYY/M/D-M/D は、対象週における「日本のカレンダー上の最初の平日」から「日本のカレンダー上の最後の平日」までにする
- 平日は、土日および日本の祝日を除いた日とする
- 生成日時、議事録が存在する日、実際に打ち合わせがあった日は日付範囲の判定に使わない
- 対象週は、ファイル冒頭の「期間」に記載された週を基準にする
- 例：対象週が2026年6月22日（月）〜2026年6月28日（日）で、日本の祝日が含まれない場合は「2026/6/22-6/26」とする
- 月曜が祝日の場合は火曜開始、金曜が祝日の場合は木曜終了のように、日本の平日に合わせて調整する

タイトルルール：
- 「タイトル：」というラベルは出力しない
- タイトルは20〜45字程度にする
- 今週の気づき、価値、役割の変化が伝わるものにする
- 会議名や予定名をそのままタイトルにしない

本文ルール：
- 2行目以降に本文を書く
- 「内容：」というラベルは出力しない
- 本文は450〜700字程度、長くても800字以内にする
- 内容に応じて2〜5段落の自然な文章にし、毎回同じ段落数にしない
- 文体は週次振り返りとして自然な一人称にする
- 書き出し、論点の展開順、段落構成、結び方を内容に合わせて変える
- 「今週はA、B、Cなどの会話を通じて」で始まり、「特に」「また」で各論を並べる定型構成を使わない
- 会議ごとに一段落を割り当てず、複数の会話を一つの思考の流れとして統合する
- 接続語を機械的に並べず、問い、違和感、結論、具体的場面など、その週に最も自然な入口から書き始める
- 箇条書き、対象会議リスト、根拠説明、引用、注釈は出力しない
- 最終出力には、この指示文の説明や前置きを含めない
""")
        lines.append("")
        if transcribedMeetings.isEmpty {
            lines.append("（今週の文字起こし済み打ち合わせがありません）")
            return lines.joined(separator: "\n")
        }
        for meeting in transcribedMeetings {
            guard let transcriptURL = meeting.transcriptURL else { continue }
            let header = "\(dateDf.string(from: meeting.date)) \(timeDf.string(from: meeting.date)) - \(meeting.displayName)"
            lines.append(String(repeating: "=", count: 52))
            lines.append("## \(header)")
            lines.append(String(repeating: "=", count: 52))
            lines.append("")
            if let text = try? String(contentsOf: transcriptURL, encoding: .utf8), !text.isEmpty {
                lines.append(text)
            } else {
                lines.append("（文字起こしが空でした）")
            }
            lines.append("")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
