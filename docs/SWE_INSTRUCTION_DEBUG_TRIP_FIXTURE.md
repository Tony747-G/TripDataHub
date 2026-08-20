# SWE 実装指示 — DEBUG-only 検証 fixture と B-11〜B-13 Simulator harness

- 目的: 実 flight の T-6h window を待たずに、**production の state / countdown / presentation path** を Simulator で検証する
- 対象: Day 2 Priority 1（B-11 / B-12 / B-13 ＋ current leg selection ＋ non-persistence）
- **production logic は一切変更しない。** 追加は DEBUG 限定の fixture と入口のみ
- commit / stage / push は行わない

---

## 0. この検証の位置づけ（誤読防止・必ず読むこと）

This DEBUG fixture validates the production STD-only builder, shared descriptor, and ActivityKit presentation without persisting synthetic schedules. A later PO decision approved production-path Simulator ActivityKit/SpringBoard evidence for B/D acceptance; test-host rendering alone remains insufficient.

The retired airborne/arrival contract (`.inFlight`, STA-based status/stale, arrival countdown) is not a fixture acceptance target. Actual ATD/ATA/STA remain parser/history data only. Revised-import cleanup still requires authentic source PDFs and is not proven by this fixture.

---

## 1. Fixture の時刻設計 — 用途で 2 形態に分ける（重要）

**固定日時をそのまま使うと明日には壊れる。** `2026-08-16 23:40Z` は基準日時では T-6h window 内・report time 前だが、日付が変われば Leg 1 は `.expired` となり、current leg は Leg 2 へ移り、テストが一斉に落ちる。**壁時計に依存するテストは本 Build Week で排除した欠陥クラスそのもの。**

### 1-A. 自動テスト（T-45〜T-49）— `nowUTC` を注入する

`OperationalStateBuilder.build(..., nowUTC:)` は既に `nowUTC` を引数で受ける（`AppViewModel.swift:4430` が実際に渡している）。

- **leg の日時は下記の固定値のまま使ってよい**
- **`nowUTC` に固定値 `2026-08-16 18:30:00Z` を渡す**
- これで壁時計を一切参照せず、永久に決定論的になる
- `Date()` をテスト内で呼ばないこと

### 1-B. 対話 Simulator fixture — 相対オフセットで生成する

アプリ本体は実 `Date()` で動くため、固定日時では起動タイミングに依存する。

```
Leg 1  STD = now + 5h00m         → T-6h window 内、report time 前
       STA = STD + 8h20m
Leg 2  STD = now + 2d + 9h
       STA = Leg2 STD + 9h
```

Leg 1 の block 8h20m は ANC→ICN の実 block を保存したもの。これによりいつ起動しても `.preReport` かつ Live Activity 対象になる。

---

## 2. Fixture の内容

```
Trip ID: DEBUG-ANC-ICN-ANC

Leg 1  ANC → ICN   DEP 2026-08-16 23:40Z  ARR 2026-08-17 08:00Z   ATD nil  ATA nil
Leg 2  ICN → ANC   DEP 2026-08-18 09:00Z  ARR 2026-08-18 18:00Z   ATD nil  ATA nil
```

（1-B の対話 fixture では上記を相対オフセットに置き換える）

### 2-A. 2 leg 構成は必須。1 leg に簡略化しないこと

`NextReportWindowBuilder.build` は **domicile への到着が 1 つも無いと `continue` して window を生成しない**。Leg 2 の `ICN → ANC` がその条件を満たしている。

1 leg に減らすと `reportTimeUTC` が nil になり、`.preReport` ではなく `.preDeparture`（`Dep in`）になって**検証の意味が変わる**。

### 2-B. `.preReport` に到達するための必須条件

`OperationalStateBuilder.reportTimesByLegID` は **`payPeriod` + `pairing` + `depAirport == domicile`** で leg を照合して `reportTimeUTC` を割り当てる。したがって:

- 両 leg に**一貫した `payPeriod` と `pairing`** を設定する
- 検証 identity の **domicile を ANC** にする
- Leg 1 の `depAirport` が ANC であること

ここが噛み合わないと `reportTimeUTC` が nil になり `.preReport` に到達しない。

### 2-C. Report lead は 1h30m

ANC は Alaska（Lower 48 ではない）、ICN は Asia。`ReportLeadTimePolicy` により 90 分。

```
STD    2026-08-16 23:40Z
Report 2026-08-16 22:10Z
```

**期待 duration をテストに固定値で焼き込まないこと。** 常に `reportTimeUTC - nowUTC` で算出する。

---

## 3. Non-persistence — アーキテクチャ要件（最重要）

**`viewModel.schedules` に代入してはならない。** 経路は以下:

```
viewModel.schedules に代入
  → didSet: scheduleDataRevision += 1          (AppViewModel:199-203)
  → RootTabView:135 onChange
  → handleSchedulesChangedForSharing()          (:139)
  → isScheduleSharingEnabled なら
  → uploadSharedScheduleIfNeeded()              (:1391)
  → CloudKit へ upload / friends へ共有
```

**検証端末は schedule sharing が有効なので、`DEBUG-ANC-ICN-ANC` が実際に CloudKit へ上がり friends に見える。**

### 要求する形

- **DEBUG 限定の入口を作り、schedule 配列を引数で明示的に渡す。** `nextFlightCountdownOutput` は `self.schedules` を読むので、**配列を受け取る DEBUG オーバーロード**を用意して publish 経路を丸ごと回避する
- `crewAccessSchedules` にも代入しない（reconcile / retention / tombstone が動く）
- CrewAccess import 経路を一切通さない。canonical JSON を書かない
- in-memory のみ。app restart で消えてよい

---

## 4. Production path を通すこと

fixture 専用の countdown / state 実装を作ることを**禁止**する。

```
Debug fixture (TripLeg 配列)
  ↓
OperationalStateBuilder
  ↓
FlightOperationalState
  ↓
FlightPresentationPolicy
  ↓
FlightCountdownCoordinator → Live Activity / Widget payload
```

parallel logic を作った時点でこの検証は価値を失う。

---

## 5. DEBUG gating

`#if DEBUG` で以下の**すべて**を囲む。

- fixture データ
- DEBUG 入口（配列を受け取るオーバーロード）
- UI トリガー（起動ボタン等）

Release build に一切含まれないことを確認すること。昨日の `[BrowserPerf]` と同じ扱い。

---

## 6. Cleanup

production coordinator を通す以上、**Simulator 上に本物の ActivityKit activity が生成される**。検証終了時に明示的に破棄できること。

1. coordinator に nil payload を渡して Live Activity を end
2. App Group の widget snapshot を削除
3. in-memory fixture を破棄
4. production の notification を残さない

---

## 7. 追加するテスト

すべて `nowUTC = 2026-08-16 18:30:00Z` を注入して決定論的に書くこと。

| # | 内容 | assert |
|---|---|---|
| T-45 | fixture が production builder を通る | `OperationalStateBuilder` 経由で共通structured operational payloadが得られる。fixture専用engine / status derivationが存在しない |
| T-46 | Device TZ 非依存（integration） | 表示 TZ を Anchorage / Ho_Chi_Minh / Seoul と変えても、`nowUTC` が同一なら **duration が完全に一致**する。変わるのは時刻表記のみ |
| T-47 | Presentation window 独立（INV-016 / T-23 の integration） | **canonical fixture の Leg 1 を固定したまま、注入する `nowUTC` を 3 通りに変える。** 3 通りとも `FlightOperationalState` が `.preReport` で同一。`FlightPresentationVisibility` だけが 3 値すべてに変化する（下記） |

**T-47 の具体仕様（PM 訂正 — 初版の `+7h → .hidden` は誤り）**

初版は「STD = `nowUTC + 7h` で `.hidden`」と書いたが、**`FlightPresentationPolicy` は T-12h から `.widget`、T-6h から `.liveActivity`** なので `+7h` は `.widget` である（`FlightCountdownSharedModels.swift:47-60`）。訂正する。

**leg は canonical fixture の Leg 1（STD `2026-08-16 23:40Z`、reportTime `22:10Z`）を固定し、注入する `nowUTC` だけを変える。** 同一 leg データを異なる時刻位置から評価することが、INV-016 の主張そのものの検証になる。

| variant | 注入する `nowUTC` | STD からの位置 | 期待 `FlightOperationalState` | 期待 `FlightPresentationVisibility` |
|---|---|---|---|---|
| A | `2026-08-16 10:40Z` | STD − 13h | `.preReport` | `.hidden` |
| B | `2026-08-16 16:40Z` | STD − 7h | `.preReport` | `.widget` |
| C | `2026-08-16 18:40Z` | STD − 5h | `.preReport` | `.liveActivity` |

- 3 variant すべてで `now < reportTime`（22:10Z）なので **state は `.preReport` で不変**
- **変化するのは visibility だけ**であることを assert する。これが INV-016 の integration 検証
- 境界そのもの（`STD − 12h` ちょうど → `.widget`、`STD − 6h` ちょうど → `.liveActivity`）も余力があれば追加してよい。必須ではない
| T-48 | current leg selection | Leg 1が`.preReport`またはnon-expired `.departureTimePassed`の間、Leg 2が存在してもcurrentはLeg 1（`ANC → ICN`）。Leg 1のSTD+61でのみLeg 2へ進む |
| T-49 | non-persistence | fixture 実行後に `viewModel.schedules` / `crewAccessSchedules` が不変。CloudKit upload / shared schedule upload が **0 回**（spy で検証）。canonical JSON が書かれていない |

**T-49 が本指示の本体を守るテスト。** spy で upload 回数を数えること。「呼ばれていないはず」ではなく「**呼ばれていないことを assert**」する。

---

## 8. Simulator 検証手順

### B-11 — Device Time Zone independence

1. 対話 fixture を起動し、Leg 1 の countdown を表示
2. **countdown 値と実時刻を記録**
3. Simulator の TZ を `Anchorage → Ho Chi Minh → Seoul` の順に変更
4. 各切替の前後で、countdown / current leg / state / 表示 dep-arr 時刻 / device TZ を記録

**PASS**: countdown が**操作中に実際に経過した時間分だけ**減る。TZ 変更そのものでは変わらない。

**FAIL（いずれも即停止）**: TZ 変更だけで HH:MM が 17h / 18h 級にジャンプ / current leg が Leg 2 に切り替わる / stale leg が復活 / `Delayed` / schedule 由来 `Completed` が出る。

### B-12 — LCL / UTC presentation

- UTC mode: scheduled 値が UTC instant として表示される
- LCL mode: **ANC departure は ANC の airport timezone、ICN arrival は ICN の airport timezone**
- **Device TZ を SGN / Seoul にしても ANC departure の LCL が device TZ に引っ張られないこと**
- LCL / UTC 切替で `Report in` / `Dep in` / `Departure time passed` の **duration / elapsed が変化しないこと**。ATD / ATAは結果を変えない

### B-13 — Presentation window independence

T-47 の 3 variants（hidden / widget / liveActivity）を Simulator でも確認する。**Operational State は同一で、presentation eligibility だけが変わる**こと。

### current leg selection

Leg 1 検証中、current leg が `ANC → ICN` のままであること。

### non-persistence

fixture 実行後に **CloudKit と friends の共有内容に `DEBUG-` が現れないことを実際に確認**する。テストの assert だけで済ませないこと。

---

## 9. 変更してはいけないもの

- `FlightOperationalState` の評価順序・境界（INV-018）
- `OperationalStateBuilder` の current leg 選択規則
- `ReportLeadTimePolicy`
- import fingerprint ledger / queue semantics
- import transaction と CloudKit の境界
- `FlightCountdownCoordinator` の 2 モードと population barrier
- browser popup lifecycle / focus acquisition

**production 側に手を入れる必要が出たら、実装せずに PM へ報告すること。** fixture のために production を変えるのは本末転倒である。

---

## 10. 報告時に含めること

- B-11 / B-12 / B-13 の各記録（TZ ごとの countdown・state・表示時刻の表）
- current leg selection の結果
- non-persistence の**実確認**結果（CloudKit / friends に `DEBUG-` が無いこと）
- T-45〜T-49 の結果と全ユニットテスト結果
- Release build に fixture が含まれないことの確認方法と結果
- `git diff --check` と staging が空であること

**FAIL が 1 つでも出たらそこで停止し、残りを消化せずログとスクリーンショットを添えて報告すること。** 全項目を流すより、最初の FAIL を正しく切り分けるほうが価値が高い。

stage / commit / push は行わない。
