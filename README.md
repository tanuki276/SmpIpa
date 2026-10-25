# サンポロード for iPhone

Android版 [SANPO-ROAD](https://github.com/tanuki276/SANPO-ROAD) をもとにした iPhone 向け実装です。

## 現在の機能

- SwiftUI + MapKit + CoreLocation
- GPSで散歩ルートを地図上に記録
- 距離とGPSポイント数をリアルタイム表示
- 散歩終了後に名前・メモを付けて端末保存
- 保存した散歩の一覧とルート地図
- 距離・時間・平均ペース表示
- 合計散歩回数・距離・時間の振り返り
- GitHub Actionsで未署名IPAを自動生成

## IPAの作り方

1. GitHub の `Actions` を開く
2. `Build iPhone IPA` を選択
3. `Run workflow` を実行
4. 完了後、Artifacts の `SanpoRoad-iPhone-unsigned` を取得

生成される `SanpoRoad-unsigned.ipa` は未署名です。実機へ入れる場合は、AltStore / SideStore等で自分のApple IDを使って署名するか、Apple Developerの証明書を使った署名済みビルド設定を追加してください。

## 開発

このリポジトリは `project.yml` をXcodeGenでXcodeプロジェクトへ変換します。

```sh
brew install xcodegen
xcodegen generate
open SanpoRoad.xcodeproj
```

対応: iOS 17以降 / iPhone

## Android版から今後移植する機能

- バックグラウンドGPS記録
- 写真添付
- 検索・並び替え
- 週間目標・月間カレンダー
- Supabase同期
- 共有・エクスポート
