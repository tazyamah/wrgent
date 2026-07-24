# wrgent — 機能・ロジック解説

**wrgent**（Weekly Report GENeraTor）は、Zoom 会議を自動で録音し、ローカルで文字起こしし、週次のまとめを生成する macOS メニューバー常駐アプリです。すべての処理（録音・文字起こし）はローカルで完結し、音声やテキストが外部に送信されることはありません。

- プラットフォーム: macOS 14+ / Swift 5.9 / SwiftUI (`MenuBarExtra`)
- 依存: [WhisperKit](https://github.com/argmaxinc/WhisperKit)（オンデバイス文字起こし）
- ビルド/デプロイ: `bash build.sh`（`swift build -c release` → `.app` 組み立て → 署名 → `/Applications` へ配置 → 起動）

---

## 全体の流れ

```
Zoom起動を検知 ─▶ 自動で録音開始 ─▶ 会議終了を検知 ─▶ 録音停止・保存
                                                              │
                                          自動文字起こしキューへ投入
                                                              ▼
                        WhisperKit で mic / system を個別に文字起こし
                                                              │
                              時系列マージ → transcript*.txt を保存
                                                              ▼
                     「今週のまとめを生成」→ 週フォルダ内の全文字起こしを
                        1つの summary.txt（LLM 用プロンプト付き）に結合
```

録音・文字起こしは、会議名の推定（Zoom ウィンドウタイトル／カレンダー／手入力）と週単位のフォルダ管理を伴います。

---

## ファイル構成と役割

| ファイル | 役割 |
|---|---|
| `ZoomWeeklyRecApp.swift` | アプリのエントリポイント。メニューバーアイコン、通知許可、アクセサリ（Dock 非表示）動作 |
| `ContentView.swift` | メニューバーのポップオーバー UI 一式 |
| `AudioRecorder.swift` | 中核。録音制御・Zoom 監視・文字起こしキュー・週フォルダ管理・音声パイプライン |
| `Transcriber.swift` | WhisperKit ラッパー。モデル取得、無音区間検出、セグメントのフィルタリング |
| `WeeklySummaryGenerator.swift` | 週フォルダの走査と `summary.txt`（LLM 用プロンプト＋文字起こし）の生成 |
| `CalendarStore.swift` | カレンダー予定 JSON の保存・読み込み・録音時刻とのマッチング |
| `MeetingNameStore.swift` | ユーザーが手入力した会議名の永続化（`_meeting_names.json`） |
| `RingBuffer.swift` | ロックフリー風リングバッファ（マイク／システム音声の一時保管） |
| `Logger.swift` | ファイル＋標準エラーへのログ出力（`wrgent_log.txt`） |

---

## 1. アプリ起動とメニューバー

`ZoomWeeklyRecApp.swift`

- `@main WrgentApp` は `MenuBarExtra`（`.window` スタイル）でメニューバーに常駐。
- `AppDelegate` が起動時に通知許可を要求し、`NSApp.setActivationPolicy(.accessory)` で Dock アイコンを消す（メニューバー専用アプリ化）。通常ウィンドウは `orderOut` で隠す。
- メニューバーアイコン（`MenuBarStatusLabel`）は状態で切り替わる:
  - 録音中: 赤い `mic.fill`
  - 文字起こし中: 紫の `waveform`
  - まとめ生成中: 紫の `doc.text.fill`
  - 待機中: テンプレートの `mic`（ライト/ダーク自動対応）

---

## 2. Zoom 会議の自動検知（`ZoomMonitor`）

`AudioRecorder.swift` 末尾の `ZoomMonitor`。

- 5 秒間隔でポーリング（バックグラウンドの `DispatchSourceTimer`）。
- **会議中の判定ロジック** (`isMeetingActive`):
  1. Zoom アプリ（bundle id `us.zoom.xos`）が起動しているか
  2. かつ `pgrep -x CptHost` が成功するか（`CptHost` は Zoom が会議中にのみ起動する補助プロセス）
- 状態遷移でコールバックを発火:
  - 非会議 → 会議: `onMeetingStart`
  - 会議 → 非会議: `onMeetingEnd`
  - 会議継続中: `onMeetingStillActive`（毎ポーリング。録音が始まっていなければリトライ用）

`AudioRecorder.startZoomMonitor()` がこれらを配線:
- **開始時**: 録音名を「Zoomミーティング」にして `startRecording()`、通知を送信。さらに **最大 12 秒間（2 秒 × 6 回）** Zoom ウィンドウタイトルをポーリングし、`extractZoomWindowTitle()` で会議名を取得できたら録音名を上書き。
- **終了時**: `stopRecording()`（→ 自動文字起こしへ）。
- **継続中で未録音**: 取りこぼしをリカバリするため `startRecording()` を再試行。

### ウィンドウタイトルの抽出 (`extractZoomWindowTitle`)
`CGWindowListCopyWindowInfo` で全ウィンドウを走査し、オーナー名に「zoom」を含むものから:
- `"◯◯ - Zoom"` / `"◯◯ - Zoomミーティング"` のサフィックスを剥がして会議名を得る
- 汎用的な名前（`Zoom`, `zoom.us`, `Zoom Meeting` 等）はスキップ

---

## 3. 音声パイプライン（録音の核心）

2 系統の音声を同時に取り込み、**個別ファイル**と**ミックス**の両方を保存します。

```
マイク  ─▶ AVAudioEngine inputNode tap ─▶ micPump ─▶ micRing ┐
                                                             ├─▶ Mixer ─┬─▶ mic_partNN.m4a
システム ─▶ ScreenCaptureKit SCStream  ─▶ sysPump ─▶ sysRing ┘         ├─▶ system_partNN.m4a
                                                                        └─▶ mix_partNN.m4a
```

### 3.1 取り込み源
- **マイク**: `AVAudioEngine` の `inputNode` に tap を設置 (`startMicCapture`)。デバイス構成変更（`.AVAudioEngineConfigurationChange`、Zoom 終了時などに発火）を監視し、変化時は `unexpectedStop`。
- **システム音声**: `ScreenCaptureKit` の `SCStream`（`capturesAudio = true`, `excludesCurrentProcessAudio = true`, 画面は 2×2 の最小サイズ）(`startSystemAudioCapture`)。
  - `SCShareableContent` / `startCapture` は一部の macOS ビルドで無限にハングしうるため、それぞれ **20 秒 / 10 秒のタイムアウト**を `TaskGroup` でレースさせ、失敗時は素早くフォールバック。

### 3.2 `AudioPump`
- 入力の任意フォーマットを、内部処理フォーマット（**48kHz / 2ch / Float32 非インターリーブ**）へ `AVAudioConverter` で変換（フォーマットごとにキャッシュ）。
- 変換後のサンプルを `RingBuffer` に書き込む。

### 3.3 `RingBuffer`
- チャネルごとの固定長 Float 配列（容量 = 10 秒分）。`os_unfair_lock` で保護。
- 書き込みが容量を超えると古いデータを捨てる（オーバーフロー時に read インデックスを進める）。
- 生産者（オーディオコールバック）と消費者（Mixer）を疎結合にする。

### 3.4 `Mixer`
- **40ms 間隔**の `DispatchSourceTimer` で駆動 (`tick`)。
- 実経過時間（`uptimeNanoseconds` の差分）× サンプルレートで、今回書き出すフレーム数を算出（端数 `remainder` を繰り越して時間ドリフトを防止）。
- 各リングから読み出し → **システム用 / マイク用の個別ファイルへ書き込み** → 両者を加算ミックス → **[-1, 1] にクリップ** → ミックスファイルへ書き込み。

### 3.5 `SegmentWriter`
- `AVAudioFile`（AAC / m4a, 48kHz, 128kbps）へ書き込む。
- ファイルサイズを推定し、**24MB を超えると自動で次のパートファイルに分割**（`baseName_partNN.m4a`）。文字起こし時にパートを結合して扱う。

### 3.6 堅牢性の作り込み
- **開始世代管理**: 各開始処理に世代番号を付け、タイムアウト後に古い `SCStream` が戻ってきても新しい録音を上書きしない。
- **開始ガード**: `startAsync` が 35 秒でスタックしたら録音リソースと `isStarting` を強制復旧。Zoom 会議が続いていれば監視側が再試行する。
- **手動開始は非常口**: 自動開始が処理中のままでも、手動開始ボタンで古い開始処理を破棄してクリーンに再試行できる。
- **マイク構成変更の局所復旧**: Zoom 参加時の `AVAudioEngineConfigurationChange` では録音全体を停止せず、2 秒待ってマイクだけを再接続する。システム音声はその間も録音を継続する。
- **入力別ウォッチドッグ**: 20 秒ごとにミキサー、マイク、システム音声の進行を個別に監視する。一方だけの障害では利用可能な音源の録音を継続する。
- **スリープ対応**: スリープ直前に録音を安全に停止・保存し、文字起こし待ち行列を永続化する。復帰後に処理を再開する。
- 各種エラー（マイク不可・システム音声不可）はユーザー設定を壊さずローカル変数でフォールバックし、両方失敗した場合のみ中断。

---

## 4. ファイル/フォルダ構成と週単位管理

ライブラリのデフォルトは `~/Music/wrgent/`（`chooseLibrary` で変更可、security-scoped bookmark で永続化）。

```
wrgent/
├── _models/                         # WhisperKit モデル + .ready_<model> マーカー
├── wrgent_log.txt
├── 2026_W27/                        # ISO 8601 週フォルダ (yearForWeekOfYear + weekOfYear)
│   ├── _calendar.json               # インポートしたカレンダー予定
│   ├── _meeting_names.json          # 手入力の会議名 { フォルダ名: 表示名 }
│   ├── summary.txt                  # 週次まとめ（LLM 用）
│   └── 20260706_140000 - 会議名/     # 個別録音フォルダ（timestamp [- 名前]）
│       ├── mic_part01.m4a
│       ├── system_part01.m4a
│       ├── mix_part01.m4a
│       ├── transcript_self_<model>.txt    # 自分（マイク）
│       ├── transcript_other_<model>.txt   # 相手（システム音声）
│       └── transcript_<model>.txt         # 時系列マージ版
```

- **週フォルダ名**: `WeeklySummaryGenerator.weekFolderName` が ISO 8601 カレンダーで `YYYY_Wnn` を生成。
- **マイグレーション** (`migrateToWeekFolders`): 旧レイアウト（週フォルダなしの録音、`_calendar_YYYY_Wnn.json`、`weekly_summary_*.txt`、フラットな `_meeting_names.json`）を起動時に現行の週フォルダ構成へ自動移行。
- 文字起こしファイル名にモデル名をサフィックスとして含むため、**モデルを変えると別ファイルとして併存**できる。

---

## 5. 文字起こし（`Transcriber` + キュー）

### 5.1 モデル管理
- 選択肢: `large-v3_turbo`（既定）/ `large-v3` / `medium` / `small`（`UserDefaults` に保存）。
- `ensureLoaded()` が WhisperKit を初期化しモデルをダウンロード（`_models/` 配下）。完了時に `.ready_<model>` マーカーを作成 → `isModelReady` で判定。

### 5.2 文字起こし処理 (`transcribeSelected`)
1. 対象フォルダの `mic_part*` と `system_part*` を列挙。
2. WhisperKit で **マイク → システム音声の順に各パートを個別に文字起こし**（言語は `ja` 固定）。パート間はオーディオ実長で時刻オフセットを加算。
3. 生セグメントを **2 段でフィルタ** (`Transcriber.transcribe`):
   - **低密度カット**: 10 秒超のセグメントで文字密度が 1 文字/秒未満 → 幻聴（ハルシネーション）とみなして除去。
   - **無音域外カット**: 事前に RMS で検出した発話区間（`speechRange`、RMS 閾値 0.004）の外にあるセグメントを除去。
4. 出力（存在するもののみ）:
   - `transcript_self_<model>.txt`（自分の発話）
   - `transcript_other_<model>.txt`（相手の発話）
   - `transcript_<model>.txt`（従来互換の全音声マージ版）
   - `transcript_external_<model>.txt`（システム音声だけの版。全行に `[相手]` を前置）
   - 会議一覧のマイク／スピーカーアイコンで、週報の `summary.txt` に全音声版または外部音声のみ版のどちらを使うかを会議ごとに選ぶ

### 5.3 自動文字起こしキュー
- 録音停止時、`autoTranscribe` が ON なら**現在の ISO 週の録音だけ**を `transcriptionQueue` に投入 (`scheduleAutoTranscription`)。過去週は自動投入せず、UI から必要な録音だけを手動実行できる。
- 待ち行列は `_transcription_queue.json` に保存し、アプリ終了・クラッシュ・スリープ後も失わない。復元時は現在週かつ実在する録音だけを残し、週をまたいだ古い項目は除外する。処理中の項目は文字起こしファイルの書き込み完了までキュー先頭に残す。
- `processTranscriptionQueue` が「録音開始中でも録音中でも文字起こし中でもない」ときに 1 件ずつ順次処理する。
- 文字起こし実行中に Zoom が始まった場合は文字起こしを止めず、録音を並行して最優先で開始する。次の文字起こし項目は録音終了まで待つ。
- 一時的な失敗は項目を削除せず、60 秒後またはスリープ復帰後に再試行する。Core Audioで開けない破損音声は恒久エラーとしてログに残し、キューから外して次の録音へ進む。
- UI からの手動起動 (`enqueueMeetingForTranscription`) も同じキューを通る。スリープ復帰時にもキューを再開。

---

## 6. 会議名の推定

表示名は次の優先順位で決まる（`WeeklySummaryGenerator.scanMeetings`）:

1. **ユーザー手入力**（`_meeting_names.json`、UI の鉛筆アイコンから編集）
2. **カレンダー予定とのマッチ**（`CalendarStore.matchEvent`: 録音開始時刻が予定の開始 5 分前〜終了内にあり、最も開始時刻が近い予定を採用）
3. **フォルダ名のサフィックス**（Zoom ウィンドウタイトル由来など）
4. 既定値 **「Zoomミーティング」**

### カレンダーインポート（`CalendarStore`）
- Chrome 拡張「orautil → wrgent」がコピーした JSON（`{ exported, events: [{ title, start, end }] }`）を UI から貼り付け。
- 現在選択中の週フォルダに `_calendar.json` として保存。日時は ISO 8601（タイムゾーン付き/なし両対応）でパース。

---

## 7. 週次まとめの生成（`WeeklySummaryGenerator`）

「今週のまとめを生成」ボタン → `generate`:

1. 選択中の週フォルダを走査し、文字起こし済みの会議を収集（`scanMeetings` → `bestTranscriptURL` はマージ版 → 自分 → 相手の順で最良の文字起こしを選択）。
2. `summary.txt` を生成:
   - **ヘッダ**: 期間・生成日時・打ち合わせ数。
   - **LLM 用プロンプト**（ハードコード）: 「週次インサイトを 1 本作る」ための詳細な指示。`[WR:ISV 鈴木 達也 : YYYY/M/D-M/D] タイトル` という 1 行目の書式、平日レンジ（土日祝を除外）の算出ルール、タイトル/本文の文字数・トーンの規約などを含む。
   - **本文**: 各会議の見出し（日付・時刻・会議名）＋文字起こし全文を区切り線付きで連結。
3. 生成後、Finder で `summary.txt` を選択表示。

この `summary.txt` は「そのまま LLM に貼れば週報が書き上がる」入力ファイルとして設計されている。

### Codex 連携 (`openWeeklyReportInCodex`)
- `summary.txt` が存在する場合、`codex://new?path=...&prompt=$weekly-report WEEK=YYYY_Wnn` という URL スキームで Codex を開き、週報生成を起動できる（ローカル環境依存の連携）。

---

## 8. UI（`ContentView`）

メニューバーのポップオーバー（幅 380）は上から:

1. **ステータス**: 現在状態のアイコン＋テキスト、録音中の経過時間、文字起こし/処理状況、画面収録許可の案内、手動録音の開始/停止＋録音名入力。
2. **今週の打ち合わせ**: 週セレクタ（Picker）、会議一覧（文字起こし済みは緑チェック、未済は波形ボタンで手動文字起こし・鉛筆で改名）、「今週のまとめを生成」「Codex で週報を生成」ボタン。
3. **カレンダー**: 予定 JSON のインポート UI。
4. **モデル**: Whisper モデル選択と初回ダウンロード。
5. **フッター**: ライブラリ場所の表示/変更、Zoom 自動録音・自動文字起こしのトグル、フォルダを開く、終了、ビルド番号。

状態はすべて `@MainActor final class AudioRecorder: ObservableObject` の `@Published` を通じてバインドされる。

---

## 9. 権限・ログ

- **必要な権限**: マイク（`AVCaptureDevice`）、画面収録（`CGPreflight/RequestScreenCaptureAccess` — システム音声取得に必須）、通知。画面収録が未許可なら設定を開くよう促す。
- **ログ** (`RecLog`): 標準エラーと `wrgent_log.txt` の両方に、タイムスタンプ付きで録音・文字起こし・エラーの詳細を記録。トラブルシュートの主要な手掛かり。

---

## ビルド & 実行

```bash
bash build.sh
```

`swift build -c release` → `wrgent.app` を組み立て → 署名（`wrgent Self-Signed` があれば使用、なければ ad-hoc）→ 既存プロセスを終了 → `/Applications/wrgent.app` へ配置 → 起動。
