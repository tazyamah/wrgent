# wrgent

**wrgent**（Weekly Report GENeraTor）は、Zoom 会議の録音、ローカル文字起こし、週報用の入力ファイル生成を行う macOS メニューバーアプリです。

録音はマイクとシステム音声を別々に保存し、[WhisperKit](https://github.com/argmaxinc/WhisperKit) で端末上の文字起こしを行います。初回の Whisper モデル取得を除き、録音・文字起こし・週次まとめの作成はローカルで完結します。

## 主な機能

- Zoom 会議の開始・終了を検知して自動録音（手動録音にも対応）
- マイク音声、システム音声、ミックス音声を個別に M4A で保存
- WhisperKit による日本語文字起こし。自分と相手の音声を分けた出力と、時系列マージ版を生成
- ISO 週ごとの会議管理、カレンダー予定との会議名照合、手動での会議名変更
- 文字起こし完了後に `summary.txt` を自動更新し、Codex の週報生成フローを起動
- スリープ・録音開始失敗・文字起こし失敗時の再試行とキュー復元

## 動作要件

- macOS 14 以降
- Swift 5.9 以降（Xcode 推奨）
- マイク、画面収録、通知の各権限
- Zoom 自動録音を使う場合は Zoom デスクトップアプリ

画面収録の権限は、ScreenCaptureKit でシステム音声を取得するために必要です。アプリは最小サイズの画面ストリームを利用します。

## ビルドと起動

依存パッケージを取得して開発ビルドする場合:

```bash
swift build
```

リリースビルド、アプリバンドル作成、署名、`/Applications/wrgent.app` への配置、起動をまとめて実行する場合:

```bash
bash build.sh
```

`build.sh` は既存の `/Applications/wrgent.app` を置き換えます。`wrgent Self-Signed` 署名が利用できない環境では ad-hoc 署名を使います。

## はじめ方

1. `bash build.sh` でアプリを起動します。
2. メニューバーのマイクアイコンを開き、macOS が求めるマイク・画面収録・通知の権限を許可します。
3. 「選択中のモデルを取得」で Whisper モデルをダウンロードします。
4. 必要に応じて「Zoom自動録音」「自動文字起こし」を切り替えます。どちらも既定で有効です。
5. 録音と文字起こしが終わると、選択週の `summary.txt` が更新されます。「Codexで週報を生成」から週報ワークフローを開けます。

## 保存先

既定のライブラリは `~/Music/wrgent/` です。アプリ内の「変更」から別の保存先を選べます。

```text
~/Music/wrgent/
├── _models/                         # Whisper モデル
├── wrgent_log.txt                   # 実行ログ
└── 2026_Wnn/                        # ISO 週ごとのフォルダ
    ├── _calendar.json                # インポートしたカレンダー予定
    ├── _meeting_names.json           # 手動で設定した会議名
    ├── _transcription_queue.json     # 自動文字起こしキュー
    ├── summary.txt                   # 週報生成用の入力
    └── YYYYMMDD_HHMMSS - 会議名/
        ├── mic_partNN.m4a
        ├── system_partNN.m4a
        ├── mix_partNN.m4a
        ├── transcript_self_<model>.txt
        ├── transcript_other_<model>.txt
        └── transcript_<model>.txt
```

## テスト

文字起こしキューの週判定・復元・再試行間隔を確認するスモークテストは `Tests/TranscriptionQueuePolicySmoke.swift` にあります。

```bash
swiftc Sources/wrgent/TranscriptionQueuePolicy.swift \
  Tests/TranscriptionQueuePolicySmoke.swift \
  -o /tmp/wrgent-queue-policy-smoke
/tmp/wrgent-queue-policy-smoke
```

実装の詳細は [doc.md](doc.md) を参照してください。
