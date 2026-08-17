# SWE 実施指示（追補）— Priority 2 Simulator triage 残項目

- 前提: `SWE_INSTRUCTION_PRIORITY2_SIMULATOR_TRIAGE.md` の初回実施結果（INCOMPLETE・確定 FAIL なし）を受けたもの
- 種別: **検証のみ。production code / DEBUG fixture を変更しない**
- commit / stage / push は行わない

---

## 0. 初回実施の判定 — 2 つの停止判断は正しい

先に明記しておく。以下 2 点は**指示どおりの正しい判断**であり、修正を求めない。

1. **D-3〜D-5 のためにデータを注入しなかったこと** — 推測でスケジュールを作れば、それは「何を確認したのか分からない PASS」になる
2. **T-15 の green を目視確認の代替にしなかったこと** — `DEVICE_VERIFICATION_CHECKLIST.md` D-0 の分離をそのまま守れている

初回で PASS した D-1 系 / D-2 系 / D-6 / D-7a / D-7c / D-7d は**再実施不要**。ただし §1 の条件下では話が変わる。

---

## 1. 【最優先・新規】D-7 を iOS 18 runtime で再確認する

### なぜ必要か

初回実施は **3 幅すべて iOS 26.5** で行われた。しかし本アプリの **minimum supported OS は iOS 18.0** である（`IPHONEOS_DEPLOYMENT_TARGET = 18.0`、commit `49f3167`）。

つまり現時点で、**iOS 18 / 19 / … 上で `SystemFormatStyle.Timer` がどう描画されるかの証拠が 1 つもない。**

これは楽観できる状況ではない。**先の `TimeDataSource.dateRange` の dash redaction も iOS 26.5 で発見された。** OS バージョンによって Live Activity の描画挙動が変わり得ることは、この案件で既に実証されている。iOS 18 の利用者に `Report in --` が出る可能性を、未検証のまま出荷することはできない。

D-7 の再実行契機に「iOS メジャーバージョン更新」を挙げておきながら、**最低サポート版での初回確認を飛ばしていた**のは PM の見落としである。

### 実施内容

Xcode から **iOS 18.x の Simulator runtime をダウンロード**し、iPhone 16 相当の Simulator を 1 台用意する。

| # | 確認内容 | 期待 |
|---|---|---|
| D-7a (iOS 18) | Lock Screen の `Report in` 数値部 | `3 hours, 29 minutes` の形。`--` / `–` / `––` / 空欄 / placeholder が**出ない** |
| D-7g (iOS 18) | 秒 | **表示されない** |
| D-7c (iOS 18) | 分境界をまたぐまで待つ（最大 60 秒） | **アプリを開かず・`Activity.update()` なしで**値が 1 減る |
| D-1 (iOS 18) | 行構成 | 常に 4 行 |

**文字列が iOS 26.5 と異なる場合も NG ではない。** OS 描画なのでロケール / OS 版で語形が変わり得る。**NG の条件は「redaction・空欄・秒の出現・凍結」だけ**である。ただし iOS 26.5 と異なる文字列が出た場合は、**その実文字列を報告すること**（`DEVICE_VERIFICATION_CHECKLIST.md` の期待値表記を PM が更新する）。

**D-7d（10 分放置）は iOS 18 では省略してよい。** 26.5 で確認済みであり、凍結は OS 版に依存しにくい。時間コストに見合わない。

**ここで FAIL が出た場合は最重要。** iOS 18 を最低サポートとした判断そのものの見直しになる。即座に停止して報告すること。

---

## 2. D-7b / D-7g（Dynamic Island expanded）— 長押しの手段

「Computer Use に長押しがない」で止まっているが、**長押しは down / up の分解で作れる。** 以下を上から順に試すこと。

### 手段 A（推奨）— マウス down / up の分解

Dynamic Island の座標へ mouse-down → 約 1.0 秒待機 → 同座標で mouse-up。単一の「click」ではなく、押下と解放を別操作として発行する。

Computer Use に `left_mouse_down` / `left_mouse_up` 相当があればそれを使う。無ければ手段 B。

### 手段 B — `cliclick`

```
cliclick dd:<x>,<y>  w:1000  du:<x>,<y>
```

Simulator ウィンドウ上の Dynamic Island の絶対座標を指定する。

### 手段 C — AppleScript

`System Events` で `mouse down` / `delay 1` / `mouse up` を発行する。

### 手段 D（最終手段）— 使い捨て XCUITest

```swift
let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
    .press(forDuration: 1.0)
```

**手段 D を選んだ場合の制約:**

- **repository に commit しない。** 使い捨てとして書き、確認後に削除する
- **`FOLLOW_UPS.md` F-3（DI expanded の nightly XCUITest）の着手ではない。** F-3 は Priority 5 完了後の判断であり、これを前倒しの根拠にしないこと
- 削除後に `git status` が作業開始時と同一であることを確認する

### 確認内容

| # | 確認内容 | 期待 |
|---|---|---|
| D-7b | DI expanded の `Report in` 数値部 | Lock Screen と**同じ値**。`--` / 空欄 / placeholder が出ない |
| D-7g (DI) | 秒 | **表示されない** |
| D-1 (DI) | 行構成 | 4 行 |
| D-2 (DI) | 中央のアイコン | SF Symbol の飛行機 1 個 |

**iPad は対象外**（Dynamic Island 非搭載）。iPhone 16 / iPhone 16 Pro Max の 2 幅で行う。

**4 手段すべてが不成立の場合は、手段ごとに何がどう失敗したかを書いて停止すること。** その場合 D-7b / D-7g(DI) は device-only へ再分類する。

---

## 3. D-3〜D-5（Connection card）— **Simulator triage の対象から外す**

初回の判断は正しい。**しかし解決策はデータ注入ではなく、再分類である。**

D-3〜D-5 は「実 Trip データ（`ICN-CGO` のような connection を持つ leg）を Timeline で見る」検証であり、以下のいずれも取り得ない。

- **DEBUG fixture の拡張は禁止。** fixture を 3 leg 化すると T-45〜T-49 の前提（2 leg / `.preReport` 到達条件）が崩れる。検証のために production/DEBUG を変えるのは本末転倒
- **推測データの注入は禁止。** 初回で正しく却下済み
- **T-15 の代替は禁止。** D-0 違反

したがって **D-3〜D-5 は device acceptance 側（実 PDF を取り込んだ実機）で確認する。** Priority 5（A-8〜A-11 の import ストレス）で実 PDF を扱うため、そこで併せて見るのが自然である。

**本追補では D-3〜D-5 を実施しない。** チェックリスト側は PM が再分類する。

---

## 4. 変更してはいけないもの（初回から継続）

- production code 全般
- **DEBUG fixture の内容・leg 数・時刻設計**（本追補で新たに明示）
- `LiveActivityOperationalStatusView` / `FlightCountdownLiveActivityTimerContract` / `FlightCountdownExpandedLayoutView`
- `FlightCountdownSharedStore.durationText`（`FOLLOW_UPS.md` F-1 で deferred 確定）
- `FlightOperationalState` の評価順序・境界（INV-018）
- `FlightPresentationPolicy` の window
- `docs/PRIORITY2_TALLY_SHEET.md`（PM 管理）

---

## 5. 報告フォーマット

```
Priority 2 Simulator Triage — Addendum Result: PASS / FAIL / INCOMPLETE

[1] iOS 18 runtime
  Runtime version:
  D-7a (iOS 18):    観測文字列:
  D-7g (iOS 18):
  D-7c (iOS 18):    前: ____ → 後: ____
  D-1  (iOS 18):

[2] Dynamic Island expanded
  採用した手段: A / B / C / D
  D-7b:   LS: ____ / DI: ____
  D-7g (DI):
  D-1 (DI):
  D-2 (DI):
  （手段 D を使った場合）使い捨てテストの削除確認: git status 差分なし  YES / NO

[3] 未実施のまま残るもの
  D-3〜D-5:       device acceptance へ再分類（本追補では対象外）
  D-7e:           device-only
  D-7f (Arriving in / STA passed):  実運航待ち

First failure, if any:
  Item:
  Observed:
  Expected:
  Evidence:

git diff --check:
staging area:
fixture cleanup:
```

**全項目 PASS の場合の結び方**

```
Simulator triage PASS on iOS 18 and iOS 26.5.
This does NOT close Priority 2.
Device acceptance on iPhone / iPhone Pro Max / iPad remains required,
and D-3 through D-5 move to device acceptance with real trip data.
```

**§1 で FAIL が出た場合は §2 に進まず、そこで停止して報告すること。**
