# HOLDER LINK

IQOS ILUMA を iPhone から直接つないで、状態を見たり設定を変えたりする自分用アプリ（非公式）。
App Store には出さず、TestFlight の内部テスターにだけ配る。

## できること

| 機能 | 中身 |
|---|---|
| バッテリー | 残量（％）と電圧 |
| 本体を探す | 本体を振動させる |
| ライト | 明るさ（高／低） |
| 振動 | 加熱の開始・使用の開始・終了まぎわ・手動で止めたとき・充電の開始 |
| 操作 | スマートジェスチャー、オートスタート |
| ロック | 本体のロック／解除 |
| 診断 | 累計の使用回数、使用日数 |
| 本体情報 | 型番、シリアル、チャージャー／ホルダーのソフトのバージョン |
| 公式でアップデート | IQOS 公式の Web アプリ（https://jp.iqos.com/apps ）をアプリ内のブラウザで開く。ブラウザは Web Bluetooth に対応 |
| 通信ログ | 送った命令と返事を表示・コピー（不具合の調査用） |

## 仕組み

```
App/Sources/
  App/            起動とタブ
  Features/       画面（Connect / Home / Settings / Info / Browser）
  Components/     部品
  Device/         BLEManager（CoreBluetooth）、DeviceStore（画面向けの状態）
App/Resources/
  webbluetooth.js アプリ内ブラウザに入れる navigator.bluetooth
Packages/IQOSKit/ 通信の決まりごと（命令のバイト列と返事の読み解き）とテスト
```

- 通信の決まりごとは、公開ライブラリ [iqos](https://github.com/V-VX/iqos)（GPL-3.0）の調査結果を参照して Swift で書き起こした。
  このリポも GPL-3.0。
- アプリ内ブラウザの Bluetooth は、IQOS 公式（iqos.com とその下）のページからの依頼にだけ答える。
- 外部ライブラリは使っていない（SwiftUI、CoreBluetooth、WebKit、Swift Testing）。

## テスト

```sh
cd Packages/IQOSKit && swift test
```

GitHub Actions の `ci` が push ごとに、このテスト（Linux）とアプリのビルド（Mac、署名なし）を行う。

## TestFlight への配布

kajisho5/runway の共通ワークフローを使う（`.github/workflows/testflight.yml`）。

初回だけ必要なこと：

1. Bundle ID `com.seventhwell.HolderLink` を登録する（済。runway の apple-bundle-id で登録）
2. App Store Connect でアプリを作る：https://appstoreconnect.apple.com/apps （API では作れないので人が行う）
3. runway の `repos.txt` に `kajisho5/holder-link` を足す（済）

実行：Actions → testflight → Run workflow。届かないときは Actions → testflight-status を実行してログを見る。

## 注意

- 非公式アプリ。IQOS の製造元とは関係がない。
- 本体のソフトの書き込みは、このアプリ自身では行わない（公式の Web アプリに任せる）。
