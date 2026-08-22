# TDH Reliability Build Week — Acceptance Checklist

- Authoritative baseline: `build-week/operational-reliability` at `78a67b0`
- Evidence layer is specified per item; production-path Simulator ActivityKit/SpringBoard evidence is valid where later PO approval says so.
- 原則: **Incorrect operational information is worse than no information.**

判定は「仕様どおり」か「そうでない」の 2 値。迷ったら NG にして PM に上げること。

---

## A. Revised Trip Import（RC-4 / Phase 2）

**Current status:** A-1〜A-7 **BLOCKED**（authentic Original/Revised pair待ち、合成・復元禁止）。A-8〜A-11 **PASS**。PDF identity は filename/path ではなく bytes の SHA-256。

`ANC → SGN → ICN → ANC` を取り込んだ状態から、`ANC → SGN → ICN → CGO → ICN → ANC` を取り込む。

| # | 確認内容 | 期待 |
|---|---|---|
| A-1 | Revised PDF を共有 → Import Preview が出る | **1 回だけ** |
| A-2 | Replacement 検出時の Preview 下部 | `Confirm Import` が出ず、`Replace and Import` のみ |
| A-3 | `Replace and Import` をタップ | **画面中央に Alert** が出る。`Replace Existing Trip?` と置換対象の Trip ID・警告文が読める |
| A-3b | **iPad で同じ操作** | Alert が**画面中央**に出る。右側に popover として anchor されない（元の不具合報告の形に戻っていないこと） |
| A-3c | Alert の `Cancel` | Preview に戻る。import は実行されない。何も削除されない |
| A-4 | Alert の `Replace and Import` | **1 回で完了**。Preview が再表示されない |
| A-5 | Timeline | Revised（CGO 往復を含む）に更新されている |
| A-6 | 旧 `DH 5X67` | Timeline にも Dynamic Island にも出てこない |
| A-7 | iPad を開く | 同じ Revised Trip が同期されている（iCloud sync 維持） |

**重複配送の確認（RC-4 の本体）**

| # | 手順 | 期待 |
|---|---|---|
| A-8 | 同じ PDF を続けて 2 回共有 | Preview は 1 回だけ。2 回目は無反応で正常 |
| A-9 | Preview を開いたまま **15 分以上**放置してから確定 | 確定後に同じ Preview が再表示されない |
| A-10 | Preview を Cancel → **3 分待ってから**同じ PDF を再共有 | **Preview が出る**（意図的な再 import は通ること。ここが出ないと NG） |
| A-11 | Trip A の Preview 表示中に別 Trip B を共有 | B は保持され、A を確定/破棄した後に 1 回だけ出る |

---

## B. STD-only Operational Countdown（RC-1 / RC-2 / RC-3 / Phase 1）

Realtime state は `.preReport` / `.preDeparture` / `.departureTimePassed` / `.expired` の4つだけ。入力は planned departure UTC、optional report UTC、`nowUTC`。ATD / ATA / STA は realtime evaluator に入れない。

| # | Status | Authoritative acceptance |
|---|---|---|
| B-1 | **PASS** | first base-departure report前は `Report in …` |
| B-2 | **PASS** | report以降STD前は `Dep in …`。later legではreportを推測しない |
| B-3 | **PASS** | durationはabsolute UTC anchor由来でdisplay/device TZ非依存 |
| B-4 | **PASS** | STD以降は `Departure time passed …`。elapsed minutesはfloor |
| B-5 | **PASS** | minute 60までeligible、STD+61でexpired。Delayed/arrival semanticなし |
| B-6〜B-9 | **RETIRED** | arrival/Actual-driven realtime acceptanceはSTD-only PO contractで廃止。Actual/STAはhistory/display dataとしてのみ保持 |
| B-10 | **PASS** | evaluator/expiration/staleはSTD+61、visible timerはSTD+60でclamp。suspended shellは次回app executionのreconcileでend。exact background dismissalは保証しない |
| B-11〜B-13 | **PASS** | ANC / SGN / ICNでsame absolute anchors/state/semantic/duration |
| B-14 | **PASS** | DHとoperating legは同じbuilder/descriptor engine |
| B-15 | **PASS** | DHもtimezone-independent |

---

## C. Live Activity / Dynamic Island / 起動時復元（RC-5 / Phase 3）

| # | Status | Authoritative acceptance |
|---|---|---|
| C-1 | **PASS** | same legの `Report in → Dep in → Departure time passed` はActivity IDを維持しupdateのみ |
| C-2 | **PASS** | old leg expiry後のnext available reconcileでold end → next eligible legをexactly once request、count=1 |
| C-3/C-4 | **BLOCKED** | authentic Original/Revised pairが必要 |
| C-5 | **RETIRED** | arrival/Delayed relaunch contractはSTD-only modelに存在しない |
| C-6 | **PASS** | retained-data Simulatorでcold launch 15/15 PASS |
| C-7 | **PASS** | repeated launch/endでduplicate/resurrectionなし |
| C-8 | **RETIRED** | arrival/completed selectionはSTD+61 expiryへ置換 |

---

## D. Layout / Live Activity 実描画（Phase 4 v2）

**iPhone / iPhone Pro Max / iPad の 3 機種すべてで確認すること。**

### D-0. 検証レイヤーの区別（先に読むこと）

Evidence layerを混同しないこと。test-host renderingはActivityKit/SpringBoard pixelsを証明しない。一方、後発PO決定により、approved DEBUG runtime hookから real ActivityKit → WidgetKit extension → SpringBoard を通したSimulator evidenceはD-series acceptanceとして有効である。

| レイヤー | 何を保証するか | 何を保証しないか |
|---|---|---|
| unit/static（T-14 / T-50S / T-51S） | layout/forbidden API/foreground contractの構造回帰 | SpringBoard pixels |
| test-host snapshot | host process内layout | extension redaction/runtime |
| production-path Simulator ActivityKit/SpringBoard | runtime Lock Screen/DI、timer boundary、appearance | そのrunで未観測のphysical-device固有挙動 |
| physical device | device固有integration | 未観測OS/surface |

**T-50S と D-7 の役割分担**

- **T-50S = 構文の回帰防止。** 「誰かが redaction する API へ戻した」を CI で即座に赤にする。人間の目を必要としない
- **D-7 = 描画結果の受け入れ。** 「その API が今の OS で実際に正しく描かれる」を人間が確認する。自動化できない

**片方だけでは不十分。** T-50S が緑でも OS 側の挙動が変われば D-7 は落ちる。D-7 が過去に PASS でも構文が戻れば意味を失う。**どちらかの PASS をもう一方の代替として報告しないこと。**

---

### D-1〜D-2. Live Activity 4 行レイアウト（v2・Lock Screen ＋ Dynamic Island expanded）

現行仕様は以下。日付は route 行の**上**、中央は SF Symbol の飛行機。

```
Flight: D901

Aug 16 (Sun)                    Aug 17 (Mon)
ANC 16:13          ✈           ICN 17:33

Report in 3 hours, 15 minutes
```

| # | 確認内容 | 期待 |
|---|---|---|
| D-1 | 行構成 | **常に 4 行**。幅・機種・文字サイズによって 5 行以上に増えない、3 行に減らない |
| D-1b | 2 行目（日付）と 3 行目（空港＋時刻）の左右 | 出発側は**左端で揃う**、到着側は**右端で揃う**。カラムがずれない |
| D-1c | 4 つのテキスト（日付 2 ＋ 空港時刻 2） | いずれも **1 行**。折り返さない。長い便名・4 文字空港でも縮小で吸収される |
| D-2 | 中央のアイコン | **SF Symbol の飛行機 1 個**。`・・・✈・・・` のような文字装飾ではない |
| D-2b | 進行方向 | 飛行機が**左→右に読める向き** |
| D-2c | 幅が不足したとき | **縮むのはテキスト側**。アイコンの大きさと位置は変わらず、テキストカラムを押し出さない |

> **旧 D-1 / D-2 は廃止。** 旧版は「route 行が 1 行であること」「飛行機アイコンや装飾がないこと」を要求していたが、これは wrap バグ回避のための当時の暫定仕様であり、v2 で意図的に覆した。旧仕様のまま確認して NG を上げないこと。

### D-3〜D-6. Timeline Connection card

Authentic `Trip_12165.pdf` をproduction parser/canonical JSONへ通した値がauthoritative gate。旧 `02:44` / `2:31` はこのPDFと一致せずretired。

| # | 確認内容 | 期待 / Status |
|---|---|---|
| D-3 | Timeline Connection card | `Block: 02:48` — **PASS** |
| D-4 | block / connection | `Connection at CGO: 2:26`、別行・右揃え — **PASS** |
| D-5 | iPad | 同じ2行構造と値 — **PASS** |
| D-6 | enlarged text | 不要なwrap/clippingなし — **PASS** |

---

### D-7. STD-only ActivityKit presentation — **PASS**

対象はLock ScreenとiPhone Dynamic Island expanded。iPadはLock ScreenのみでDynamic IslandはN/A。compact/minimalは対象外。Home Screen Widget実描画は **F-9 DEFERRED**。

| # | Acceptance | Status |
|---|---|---|
| D-7a | `Report in …`、dash/redaction/blank/secondsなし | **PASS** |
| D-7b | `Dep in …`、Lock Screen / DI expanded | **PASS** |
| D-7c | `Departure time passed …`、minute 60 stressを含む | **PASS** |
| D-7d | minute-only OS-driven rendering。polling/per-minute updateなし | **PASS** |
| D-7e | countdown/count-upのminute boundaryでfreezeしない | **PASS** |
| D-7f | 上記3つのSTD-only wordingすべて。retired arrival wordingなし | **PASS** |
| D-7g | Light/Dark visibility。iPad Lock Screenも両appearance | **PASS** |

```text
timerClampUTC = STD + 60 minutes
expirationUTC = STD + 61 minutes
staleDate     = STD + 61 minutes
```

+59は59 minutes、+60以降のvisible timerは60 minutesでclamp。STD+61 exactlyのbackground wake/dismissalは保証しない。shellが残った場合も次回app executionで`.expired`をreconcileしendする。

D-7はiOS/Xcode major update、minimum OS引き上げ、またはLive Activity timer/layout contract変更時に再実施する。

---

## Priority 2 完了条件（reconciled）

**Priority 2: PASS.** D-1〜D-7はproduction-path ActivityKit/SpringBoard runtimeおよびauthentic PDF由来Timeline evidenceで再acceptance済み。3幅のLock Screen、対応iPhoneのDI expanded、Light/Dark、minute boundary、60-minute clampを含む。iPad DIはN/A。Home Screen Widget pixelsはF-9へdefer。

---

## E. 回帰（壊していないこと）

| # | Status | Authoritative acceptance |
|---|---|---|
| E-1 | **BLOCKED** | same candidate buildのiCloud-authenticated pair待ち。direct CloudKit injectionで代替しない |
| E-2 | **PASS** | iPhone/iPad iOS 18.6: HKG `Rest: 14:00`、HND overlap `23h 0m` |
| E-3 | **PASS** | Physical iPad BP26-05 / Calendar。Trip 12165 / A70193R / A70639 exactly once |
| E-4 | **RETIRED** | LogTen CSV Exportはcurrent release scope外。UI/debug/direct-call代替を追加しない |
| E-5 | **PENDING** | 48h / 24h real notification observationのみ。12hはcurrent contract外 |

---

## 記録方法

各項目を `OK` / `NG` / `未確認` で記録し、NG は次を添えて PM に上げること。

1. 機種と OS バージョン
2. 実際の表示（スクリーンショットが最良）
3. その時点の便名・STD / STA・device TZ
4. 再現手順

**NG が 1 つでもあれば Definition of Done 未達。** 該当 Phase に差し戻す。

---

## 補足 — Current status（2026-08-20）

- A-1〜A-7 / C-3/C-4: **BLOCKED** authentic Original/Revised pair待ち
- A-8〜A-11: **PASS**
- B-series current STD-only acceptance: **PASS**。B-6〜B-9 retired
- C-1/C-2/C-6/C-7: **PASS**。C-5/C-8 retired
- D-1〜D-7: **PASS**
- E-1: **BLOCKED**
- E-2/E-3: **PASS**
- E-4: **RETIRED**
- E-5: **PENDING** 48h/24h
- F-series（Home Screen Widget visual F-9を含む）: **DEFERRED**

古いchecklist/instructionのarrival contractやSimulator無効扱いを根拠に、PASS/RETIRED項目を再openしないこと。
