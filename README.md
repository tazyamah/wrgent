# wrgent

**wrgent**（Weekly Report GENeraTor）は、Zoom 会議の録音、ローカル文字起こし、週報用の入力ファイル生成を行う macOS メニューバーアプリです。

新規録音はマイクとシステム音声を混ぜた音声だけ保存し、既定のlarge-v3-turboは[MLX](https://github.com/ml-explore/mlx-examples/tree/main/whisper)で端末上の文字起こしを行います。ほかのモデルは[WhisperKit](https://github.com/argmaxinc/WhisperKit)を使います。初回のモデル取得を除き、録音・文字起こし・週次まとめの作成はローカルで完結します。

## 主な機能

- Zoom 会議の開始・終了を検知して自動録音（手動録音にも対応）
- 自分と相手の混合音声をM4Aで保存。サイズによる分割は維持
- 混合音声を1回認識して会話全体の文章を生成。同じモデルは次の会議でも再利用
- MLX turboを同じプロセスで再利用し、キャッシュ上限を256MiBに制限
- 異常な繰り返しや短い区間への大量の出力を検出し、該当する認識窓だけを一度再認識
- メニューの外側のクリックや他アプリへの切り替えでウィンドウを閉じる
- 旧録音の個別音声と既存の「外部音声のみ」文字起こしにも対応
- ISO 週ごとの会議管理、カレンダー予定との会議名照合、手動での会議名変更
- 文字起こし完了後に `summary.txt` を自動更新し、Codex の週報生成フローを起動
- スリープ・録音開始失敗・文字起こし失敗時の再試行とキュー復元

## 動作要件

- macOS 14 以降
- Apple Silicon（MLX turboに必要）
- Swift 5.9 以降（Xcode 推奨）
- マイク、画面収録、通知の各権限
- Zoom 自動録音を使う場合は Zoom デスクトップアプリ

画面収録の権限は、ScreenCaptureKit でシステム音声を取得するために必要です。アプリは最小サイズの画面ストリームを利用します。

## ビルドと起動

依存パッケージを取得して開発ビルドするには、次のコマンドを実行します。

```bash
swift build
```

次のコマンドでリリースビルド、署名、`/Applications/wrgent.app`への配置と起動を実行します。

```bash
bash build.sh
```

`build.sh`は既存の`/Applications/wrgent.app`を置き換えます。独立したPython 3.12.12とmlx-whisper 0.4.3、MLX 0.32.3をアプリに同梱するため、導入後の実行はHomebrewのPythonや比較用フォルダに依存しません。ビルド時はuv 0.9.5で実行環境を`.build`内に用意します。`wrgent Self-Signed`署名が利用できない環境ではad-hoc署名を使います。

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
        ├── mix_partNN.m4a             # 自分と相手の混合音声
        └── transcript_<model>.txt
```

新規録音には「自分／相手」の話者ラベルや相手だけの抽出機能はありません。既存の個別音声・文字起こしは削除しません。

MLX turboへ切り替えても、モデルの選択キーと`transcript_openai_whisper-large-v3_turbo.txt`の名前は維持します。既存の文字起こしを自動で上書きしません。MLXのモデルは`_models/mlx-whisper-large-v3-turbo/`に保存します。

`WRGENT_BUILD_ONLY=1 bash build.sh`で、稼働中のアプリを変更せずにビルドできます。ビルドスクリプトは、導入済みであればmacOS 26.5 SDKを使います。別のSDKを使う場合は`WRGENT_SDK_PATH`にパスを指定してください。

## テスト

文字起こしキューの週判定・復元・再試行間隔を確認するスモークテストは `Tests/TranscriptionQueuePolicySmoke.swift` にあります。

```bash
swiftc Sources/wrgent/TranscriptionQueuePolicy.swift \
  Tests/TranscriptionQueuePolicySmoke.swift \
  -o /tmp/wrgent-queue-policy-smoke
/tmp/wrgent-queue-policy-smoke
```

実装の詳細は [doc.md](doc.md) を参照してください。

混合音声の保存、入力選択、旧録音との互換性、サマリ生成は`bash Tests/run-pipeline-smoke.sh`で検証できます。実マイクの収録とWhisperモデルの認識は、このスモークテストには含みません。

実モデルの認識確認は`bash Tests/run-recognition-smoke.sh /path/to/_models`で実行できます。日本語のテスト音声を生成し、同じモデルで3回認識して所要時間と期待語を確認します。長時間の会議音声に対する精度・速度の評価ではありません。

繰り返し対策の回帰テストは`python3 Tests/test_mlx_quality.py`で実行できます。正常な強調表現を残すこと、異常な短区間・音声の範囲外の出力を除くこと、再認識が該当窓だけを置き換えることを確認します。
