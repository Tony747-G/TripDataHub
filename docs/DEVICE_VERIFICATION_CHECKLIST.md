# TDH Reliability Build Week — Acceptance Checklist

> **2026-08-28 product decision:** Flight Countdown Live Activities were removed. Sections C and
> the Live Activity parts of D are historical evidence only and are no longer release gates or
> re-verification instructions. Current acceptance is the absence of Lock Screen/Dynamic Island
> Flight Countdown configuration and runtime request/update/end paths. Home Screen Widget checks
> remain applicable.

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
| A-6 | 旧 `DH 5X67` | TimelineにもHome Screen Widgetのcurrent snapshotにも出てこない |
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
| B-4 | **PASS** | `[STD, STD+61min)` はschedule-domain state `.departureTimePassed`。Actual departureを意味せず、visible elapsed contractは持たない |
| B-5 | **PASS** | minute 60までeligible、STD+61でexpired。Delayed/arrival semanticなし |
| B-6〜B-9 | **RETIRED** | arrival/Actual-driven realtime acceptanceはSTD-only PO contractで廃止。Actual/STAはhistory/display dataとしてのみ保持 |
| B-10 | **RETIRED BY FEATURE REMOVAL** | Flight Live Activityのstale、visible timer clamp、suspended shell、reconcile/end acceptanceは現行要件ではない。STD+61はB-5のdomain/selection boundaryとしてのみ維持 |
| B-11〜B-13 | **PASS** | ANC / SGN / ICNでsame absolute anchors/state/semantic/duration |
| B-14 | **PASS** | DHとoperating legは同じbuilder/descriptor engine |
| B-15 | **PASS** | DHもtimezone-independent |

---

## C. RETIRED — Live Activity / Dynamic Island / 起動時復元（historical）

| # | Status | Authoritative acceptance |
|---|---|---|
| C-1〜C-8 | **RETIRED BY FEATURE REMOVAL** | Activity identity、request/update/end、relaunch、resurrection acceptanceは現行release gateではない |

---

## D. RETIRED Live Activity evidence / active Home Widget evidence

**iPhone / iPhone Pro Max / iPad の 3 機種すべてで確認すること。**

### D-0. Current verification boundary

T-14/T-50SとActivityKit/SpringBoardのD-series acceptanceはすべてretired。T-51SはActive Home Screen Widgetのforeground/background ownershipだけを検証する。Home Widgetの実描画acceptanceはF-9に従う。

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

### D-7〜D-8. Flight Live Activity acceptance — **RETIRED BY FEATURE REMOVAL**

Lock Screen、Dynamic Island、post-STD elapsed、stale、timer clamp、suspended shell、foreground reconcile、Activity endのacceptanceは削除済みfeatureのhistorical evidenceであり、再実施しない。Issues 2〜7と9はfeature removalにより解決済み。Active Home Screen Widget acceptanceはF-9を使用する。

---

## Priority 2 完了条件（reconciled）

Historical D-series Flight Live Activity gates are **RETIRED BY FEATURE REMOVAL**. Timeline Connection card acceptance remains recorded in D-3〜D-6. Home Screen Widget pixels remain F-9 deferred.

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
- B-series current schedule-domain acceptance: **PASS**。B-6〜B-10 retired
- C-series Flight Live Activity: **RETIRED BY FEATURE REMOVAL**
- D-series Flight Live Activity: **RETIRED BY FEATURE REMOVAL**。D-3〜D-6 Timeline evidenceのみ維持
- E-1: **BLOCKED**
- E-2/E-3: **PASS**
- E-4: **RETIRED**
- E-5: **PENDING** 48h/24h
- F-series（Home Screen Widget visual F-9を含む）: **DEFERRED**

古いchecklist/instructionのarrival contractやSimulator無効扱いを根拠に、PASS/RETIRED項目を再openしないこと。
