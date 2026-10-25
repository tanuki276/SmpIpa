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
