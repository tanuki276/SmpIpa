# サンポロード for iPhone

Android版 [`tanuki276/SANPO-ROAD`](https://github.com/tanuki276/SANPO-ROAD) の機能を iPhone 向けに移植した SwiftUI アプリです。

## 主な機能

- MapKit + CoreLocation による GPS 散歩記録
- 通常 / 高精度 GPS、ノイズ除去、GPS品質レポート
- バックグラウンド位置情報、休憩 / 再開、区間分割
- 距離・歩行時間・休憩時間・経過時間・平均ペース
- 名前・メモ・タグ・写真・お気に入り
- 履歴検索、30日 / 3km / 写真 / お気に入り絞り込み、距離 / 時間ソート
- 週間目標、8週間グラフ、月間カレンダー、タグ別集計、連続日数
- 過去ルートとの同一コース判定・比較・再歩行
- GPX / CSV / SANPO JSON バックアップ（Android版形式と互換）
- 共有リンク、メモ / 地図の個別共有、期限設定、リンク無効化
- 地図共有時の始点・終点 150m プライバシーマスク
- Google + Supabase Auth、散歩 / 写真の任意クラウド同期
- HealthKit へのウォーキング / 距離書き込み、歩数・平均心拍・アクティブエネルギー表示
- アカウント削除、手動再同期、プライバシー / 利用規約表示

## iOSでの置き換え

Androidの Health Connect は HealthKit、OpenStreetMap は MapKit / Apple Maps、Foreground Service の常駐通知は iOS のバックグラウンド位置情報・位置情報インジケータ・通知アクションへ置き換えています。iOSではアプリをユーザーが強制終了した後の継続記録はOS仕様上保証できません。

## ビルド

プロジェクト定義は XcodeGen の `project.yml` です。iOS 17 以上を対象にしています。

```sh
brew install xcodegen
xcodegen generate
open SanpoRoad.xcodeproj
```

GitHub Actions の `Build iPhone IPA` は署名なしの `.ipa` を生成して Artifacts に保存します。実機配布用に署名する場合は Apple Developer の Signing 設定と HealthKit capability を有効にしてください。

## クラウド

Android版と同じ Supabase プロジェクト・DB / Storage / RPC / Edge Function を使います。クライアントには公開用 Publishable Key のみを含め、service role key は使用しません。クラウド同期と写真同期は初期状態で OFF です。

## データ保全と互換性

- 保存失敗時は履歴を保存前の状態に戻し、保存待ちの散歩を残します。空き容量などを確認して再試行できます。
- 散歩終了時に保存待ちファイルを作れなかった場合、記録を一時停止してライブデータを保持します。
- 保存画面はスワイプで閉じず、保存または破棄で終了します。再起動後は「保存待ちの散歩を開く」から再表示できます。
- 読み込めない履歴ファイルは上書きせず、エラーを表示します。
- Android旧形式の配列JSONや、省略された追加項目を含むバックアップを読み込めます。必須項目・型・形式バージョンの検証は維持します。
- インポートは一括保存し、写真や履歴の保存失敗時は取り込み前に戻します。同一アカウントでの再取り込みは重複を避けます。

## テスト

`xcodegen generate` 後、Xcode の `SanpoRoad` スキームで Test を実行してください。
GitHub Actions でも利用可能な iPhone Simulator を選び、回帰テストが成功してから署名なしIPAを生成します。
テスト結果は `SanpoRoad-TestResults` Artifact に保存します。

手動確認: 通常の散歩終了→保存、写真付き保存、アプリ再起動時の保存待ち再表示、Androidバックアップのインポートを確認してください。GPS・バックグラウンド動作・HealthKitは実機での確認が必要です。
