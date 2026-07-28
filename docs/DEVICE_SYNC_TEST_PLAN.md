# 実機同期テスト手順 (2026-07-25 同期修正)

対象ビルド: 本セッションの同期修正を含むもの
必要機材: iPhone 1台 + iPad 1台（同一 iCloud アカウント / 同一 GEMS ID）、必要なら友達役の2台目アカウント

---

## 0. 準備

### ログの見方

同期処理は全て `Logger(subsystem: "com.sfune.TripDataHub")` に出る。Mac に端末を繋いで Console.app、
またはターミナルで:

```
log stream --device --predicate 'subsystem == "com.sfune.TripDataHub"' --style compact
```

事後に確認する場合:

```
log collect --device --last 30m
```

カテゴリは `AppViewModel`（同期本体）、`FriendLink`（友達リンク）、`Import`（PDF取込）。

### 判定に使う主要ログ

| ログ | 意味 |
|---|---|
| `CrewAccess import files fetched: <reason> total=N written=M` | ファイル層の同期完了 |
| `Device schedule fetched: <reason> source=... tripCount=N` | レガシースナップショットを**適用した** |
| `Legacy device schedule fallback skipped, Timeline rebuilt from files: <reason>` | 正常。ファイルから再構築できたのでスナップショット不使用 |
| `Device schedule uploaded: <reason> tripCount=N` | スナップショットのアップロード成功 |
| `Manual events fetched: <reason> ... operational=N personal=N tombstones=N` | 手動イベントのマージ完了 |
| `<何か> coalesced: <reason>` | 再入要求がキューされた（正常動作） |

### UI に出るステータス文言

`Trip sync completed.` / `Schedule updated from device sync.` / `Device schedule synced.` /
`Trip sync download failed. Local schedule preserved.` /
`Trip sync download failed. Cloud schedule not overwritten.` /
`Device sync download failed. Local schedule preserved.`

### 事前チェック

- [ ] 両端末で同じ GEMS ID で verify 済み
- [ ] 両端末とも iCloud サインイン済み・ネットワーク良好
- [ ] 開始前に両端末の Timeline が一致していることを目視

---

## 1. 端末IDの移行（今回の更新で一度だけ起きる）

`deviceID` が UserDefaults の UUID から `identifierForVendor` に変わったため、**更新後の初回起動で
両端末の deviceID が変わる**。ここが崩れると以降のテストが全部疑わしくなるので最初に確認する。

| # | 手順 | 期待 |
|---|---|---|
| 1.1 | 旧ビルドが入った状態から新ビルドに更新（アプリ削除はしない） | — |
| 1.2 | iPhone / iPad を順に起動 | 両端末とも Timeline が消えない |
| 1.3 | ログ確認 | `Device schedule uploaded` または `fallback skipped` が出る。`fetch failed` が続かない |
| 1.4 | 2端末の deviceID が**異なる**こと | 片方の `Device schedule fetched: ... source=` にもう片方の idiom が出る |

> ⚠️ iPhone のバックアップから iPad を復元した履歴がある場合、旧ビルドでは同一 deviceID を共有して
> 互いの更新を無視していた可能性がある。今回の修正で解消されるはずなので、その症状があったなら
> ここで直っているかを重点確認。

---

## 2. 双方向同期（メイン）

### 2.1 iPad → iPhone

| # | 手順 | 期待 |
|---|---|---|
| 1 | iPad で CrewAccess PDF を1本インポート → confirm | Timeline に反映、`CrewAccess import file uploaded: <file>` |
| 2 | iPhone をフォアグラウンドに（バックグラウンドから復帰） | `CrewAccess import files fetched: foreground total=N written=1` |
| 3 | iPhone の Timeline | 新しいトリップが出る |
| 4 | iPhone のログ | `Legacy device schedule fallback skipped` が出る（ファイルから再構築できた証拠） |

### 2.2 iPhone → iPad

2.1 の役割を逆にして同じ手順。**別のトリップ**を使うこと。

### 2.3 削除の伝播

| # | 手順 | 期待 |
|---|---|---|
| 1 | iPhone でトリップを1本削除 | Timeline から消える |
| 2 | iPad を復帰 | 同じトリップが消える |
| 3 | しばらく待って両端末を再度復帰 | **復活しない**（tombstone が効いている） |

### 2.4 再インポートが削除に勝つ

| # | 手順 | 期待 |
|---|---|---|
| 1 | iPhone でトリップAを削除 → iPad にも伝播させる | 両方から消える |
| 2 | iPad で同じトリップAの PDF を再インポート | iPad に出る |
| 3 | iPhone を復帰 | トリップAが**戻ってくる**（新しい取込が古い削除意図に勝つ） |

---

## 3. 同期失敗時のデータ保全（今回の修正の核心）

### 3.1 ダウンロード失敗でローカルが消えない

| # | 手順 | 期待 |
|---|---|---|
| 1 | iPhone の Timeline にトリップがある状態にする | — |
| 2 | 機内モード ON | — |
| 3 | アプリを一度バックグラウンド → 復帰（同期を走らせる） | Timeline が**そのまま**残る |
| 4 | ステータス文言 | `Trip sync download failed. Local schedule preserved.` |
| 5 | 機内モード OFF → 復帰 | `Trip sync completed.` に回復、内容も一致 |

### 3.2 アップロード失敗後の自動リトライ

| # | 手順 | 期待 |
|---|---|---|
| 1 | iPhone を機内モードにしてから PDF をインポート | ローカルには入る。`CrewAccess import file upload failed` |
| 2 | 機内モード OFF → 復帰 | `CrewAccess import file uploaded: <file>` が出る |
| 3 | iPad を復帰 | そのトリップが iPad に出る |

### 3.3 LogTen バックログが通信失敗で消えない ★今回の修正点

| # | 手順 | 期待 |
|---|---|---|
| 1 | iPhone でトリップを取り込み、**過去日**になるまで待つ（または過去日のトリップを取り込む） | LogTen エクスポート対象として蓄積される |
| 2 | Settings から LogTen CSV エクスポートを実行し、行数を控える | 記録 |
| 3 | 機内モードにして数回フォアグラウンド往復 | — |
| 4 | 機内モード OFF、数回同期 | — |
| 5 | 再度 LogTen CSV エクスポート | **行数が減っていない** |

> この項目が今回いちばん壊れやすかった箇所（成功経路・失敗経路の両方で参照時刻が消えていた）。
> 手順3と4の両方を必ず通すこと。

### 3.4 起動直後のアップロード ★今回の修正点

以前は cold start で CloudKit identity 解決前に同期が走り、**ダウンロードだけ動いてアップロードが
黙って skip** されていた。

| # | 手順 | 期待 |
|---|---|---|
| 1 | iPhone のアプリを完全終了（タスクスワイプ） | — |
| 2 | 機内モード OFF のまま起動し、**すぐには触らない** | — |
| 3 | ログを10秒ほど観察 | `Device schedule uploaded: identity resolved ...` または `... startup ...` が出る |
| 4 | フォアグラウンド往復をせずに iPad を復帰 | iPhone 側の状態が届いている |

---

## 4. 手動イベント（Manual Events）

| # | 手順 | 期待 |
|---|---|---|
| 4.1 | iPhone で手動イベントA、iPad で手動イベントB を**オフラインのまま**それぞれ追加 | — |
| 4.2 | 両方オンラインにして同期 | **AもBも両端末に残る**（どちらも消えない） |
| 4.3 | iPhone でAを削除 → iPad 復帰 | iPad からもAが消え、Bは残る |
| 4.4 | 同じイベントを両端末で別内容に編集 → 同期 | 後に編集した方が勝つ。片方が消えたりはしない |

### 実機確認済み

- 2026-07-27: iPad M5 と iPad mini の間で Personal Event の双方向同期を確認。両端末のどちらで作成したイベントも、もう一方へ反映された。

---

## 5. 友達同期

### 5.1 unfriend が復活しない ★今回の修正点

| # | 手順 | 期待 |
|---|---|---|
| 1 | アカウントAとBを友達にする | 双方で accepted |
| 2 | Aで友達解除 | Aの一覧から消える |
| 3 | Bのアプリを起動 → Friends タブ | Bの一覧からも消える |
| 4 | **AとBを数回ずつ起動し直す** | どちらでも**復活しない** |
| 5 | ログ（FriendLink カテゴリ） | `restored accepted friend link from local acceptedAt proof` が**出ない** |

### 5.2 1人の失敗が全員を巻き込まない ★今回の修正点

| # | 手順 | 期待 |
|---|---|---|
| 1 | 友達を2人以上登録した状態にする | — |
| 2 | Friends タブを開いて同期 | 全員のスケジュールが更新される |
| 3 | ログ | `refreshConnection failed; preserving cached friend` が出た場合でも、**他の友達の表示は更新される** |

### 5.3 別 Pay Period が消えない ★今回の修正点

| # | 手順 | 期待 |
|---|---|---|
| 1 | 友達が複数の Pay Period のスケジュールを共有している状態にする | — |
| 2 | 自分の iPhone と iPad の両方で Friends タブを開く | — |
| 3 | 友達が1つの Pay Period だけ更新 → 自分の両端末で同期 | **他の Pay Period が消えない** |
| 4 | Friends 一覧の `Last Updated` 表示 | 友達が最後にアップロードした時刻になっている |

### 5.5 `Last Updated` が内容変更時のみ進む ★今回の修正点

以前は相手がアプリを開くだけでタイムスタンプが進み、内容が古いまま「更新された」ように見えていた。

| # | 手順 | 期待 |
|---|---|---|
| 1 | 友達側の端末で、スケジュールを**変更せずに**アプリを開閉する（3回） | — |
| 2 | 自分の端末で Friends タブを同期 | `Last Updated` が**進まない** |
| 3 | 友達側でログ確認 | `uploadSchedule: unchanged, skipping save to preserve modificationDate` |
| 4 | 友達側でトリップを1本インポート | — |
| 5 | 自分の端末で同期 | `Last Updated` が進み、**内容も新しくなっている** |

> ⚠️ この項目は**相手側にも今回のビルドが入っている必要がある**。相手が旧ビルドなら
> 無条件アップロードのままなので 2 で進んでしまう。Tony の iPhone ↔ iPad mini の
> 2台間で確認するのが確実。

### 5.6 友達リンククエリの index 確認 ★今回の修正点

| # | 手順 | 期待 |
|---|---|---|
| 1 | Production ビルドで Friends タブを開く | — |
| 2 | Console で `friend link query failed` を検索 | **出ない**のが正常 |
| 3 | 出た場合 | CloudKit Dashboard の Production で `TDHFriendLink` の `gemsA` / `gemsB` に Queryable index を追加。既知の友達は更新され続けるが、新規リンクの発見ができない |

### 5.4 連打耐性

| # | 手順 | 期待 |
|---|---|---|
| 1 | Friends タブで Pull-to-refresh を素早く5回 | クラッシュしない、重複リクエストが `coalesced` ログになる |
| 2 | 同期中にアプリをバックグラウンド → 即復帰 を3回 | スピナーが**途中で消えない**（カウンタ化の確認）、最終状態が正しい |

---

## 6. 回帰確認（壊していないこと）

- [ ] PDF 取込 → プレビュー → confirm が通る
- [ ] Timeline / Calendar / iPad ワークスペースの表示崩れなし
- [ ] 次回レポート通知が正しくスケジュールされる
- [ ] ウィジェット（カウントダウン）が更新される
- [ ] LogTen CSV エクスポートの内容が妥当
- [ ] Demo Mode（App Review 資格情報）で同期が走らない

---

## 記録テンプレート

各項目について:

```
項目: 3.3 LogTen バックログ
端末: iPhone 15 Pro / iOS 18.x, iPad Air / iPadOS 18.x
結果: PASS / FAIL
実際の挙動:
関連ログ:
```

FAIL が出たら、その項目の**前後30秒**のログを丸ごと確保してから次に進むこと。
`log collect --device --last 30m` が手軽。

---

## 既知の制約（テスト中に遭遇しても想定内）

- **public CloudKit database**: 個人データが public DB にある状態は未対応のまま。
  今回のテスト範囲外だが、テスト用の GEMS ID を使う場合は他人のレコードを踏まないよう注意。
- **`identifierForVendor` の変化**: TripDataHub を含む同一ベンダーのアプリを端末から全て削除して
  再インストールすると deviceID が変わり、自分の過去スナップショットを一度取り込むことがある。
  Timeline が空のときだけ適用されるので実害はないが、ログ上は `Device schedule fetched` が出る。
- **スナップショットは last-writer-wins**: iPhone と iPad が同時刻にアップロードすると、
  スナップショットレコードは後勝ちになる。トリップ本体はファイル層で収束するので Timeline は正しくなる。
