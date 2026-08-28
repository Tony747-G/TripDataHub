# TDH Build Week — UI/UX Reliability Fix / SWE Instruction

> **Historical instruction:** 2026-08-28のProduct Owner decisionによりFlight Countdown Live
> Activitiesは削除された。本書中のActivityKit、Lock Screen、Dynamic Island、Activity
> request/update/end、staleDate、timer-clamp要件はすべてretiredであり実装してはならない。
> 現行契約はADR-004、INV-020、INV-021を参照する。

- Status: Historical implementation handoff; current authoritative contract is §0.1 and implementation/acceptance is recorded in the current checklist
- PM: Product Manager (TripDataHub)
- Assignee: SWE (implementation authority)
- QA: invariant / regression validation
- Scope: Trip Revision Import / Flight State / Countdown / Live Activity / Notification / Timeline UI
- Baseline: `ANC-SGN-ICN-CGO-ICN-ANC` 実運用 Build
- 原則: **Incorrect operational information is worse than no information.**

---

## 0. この文書の使い方

PM Instructions に従い、実装前にコード調査を完了させた。本書は

1. Root Cause Analysis（コード実体に基づく）
2. Proposed Architecture / State Model
3. Implementation Plan
4. SWE Handoff（作業単位・受け入れ条件）

の順で構成する。**個別 patch を禁止する。** 症状ごとの対症修正ではなく、下記 RCA で特定した 5 つの共通 root cause を潰すこと。

SWE は着手前に `AGENTS.md` → `docs/AI_CONTEXT_INDEX.md` → `docs/INVARIANTS.md` → `docs/ADR/ADR-002-utc-source-of-truth.md` を読むこと。特に **INV-012（Display / Planning の時刻二系統）** は本 Build Week の中心にある。

### 0.1 Product Owner revision — 2026-08-17（authoritative）

Product Owner は、CrewAccess ATD / ATA を real-time source として利用できないことを確定した。旧 seven-state contract と、その arrival / Actual-driven assertion は retired である。本項、改訂後の INV-013〜018、ADR-004、および本書 §5 の改訂 T-xx 定義が、以下の旧記述より優先する。

- operational evaluator の入力は `plannedDepartureUTC`、optional `reportTimeUTC`、`nowUTC` のみ
- state は `.preReport` / `.preDeparture` / `.departureTimePassed` / `.expired`
- `plannedArrivalUTC` / STA は route display metadata のみ。ATD / ATA は INV-012 の history data のみ
- 評価順序は `now >= STD+61min` → expired、`now >= STD` → departure-time-passed、report 前 → pre-report、その他 STD 前 → pre-departure
- `.departureTimePassed` は elapsed minute 0〜60。STD+61 で除外
- operational expirationは `expirationUTC = STD+61min`、OS-driven elapsed表示の上限は別概念の `timerClampUTC = STD+60min`。Activity shellが残ってもvisible elapsedは60分で停止する
- current leg は non-expired `.departureTimePassed` を最新 STD 順で優先し、STD+61 で初めて次 leg へ進む。short turn で次 leg の `Dep in` が短縮または消失してよい
- App Timeline / Widget / Live Activity は同じ structured descriptor、state、prefix、anchor UTC を使用する
- elapsed 部分は `SystemFormatStyle.Timer` の OS localization を許容する。`XX min` の文字列完全一致は要求しない
- formatting のための毎分 `Activity.update()`、Swift timer、polling は禁止
- `Arriving in`、`Scheduled Arrival Time Passed`、STA countdown、ATD-driven `.inFlight`、ATA-driven real-time `.completed` は削除対象

§2 の RCA は当時の欠陥を説明する historical evidence として残す。§3 の旧 seven-state proposal、旧 Phase 1 手順、旧 arrival-side Definition of Done は実装指示として使用してはならない。

---

## 1. 調査対象と実際に読んだコード

| 領域 | ファイル |
|---|---|
| Countdown engine | `TripDataHub/Models/FlightCountdownSupport.swift` |
| Phase 定義（共有） | `TripDataHub/Models/FlightCountdownSharedModels.swift` |
| Live Activity lifecycle | `TripDataHub/Services/FlightCountdownCoordinator.swift` |
| Widget / Dynamic Island | `TripDataCountdownWidgetExtension/TripDataCountdownWidget.swift` |
| Import transaction | `TripDataHub/ViewModels/AppViewModel.swift`（`importCrewAccessPDFData` / `externalConsumerLoop` / `confirmPendingImport` / `resetExternalOpenDedup` / `claimPersistentFingerprint`） |
| Import UI | `TripDataHub/Views/ImportPreviewView.swift` |
| Countdown refresh trigger | `TripDataHub/Views/RootTabView.swift` |
| Report time | `TripDataHub/Services/NextReportWindowBuilder.swift` |
| Notification | `TripDataHub/Services/NextReportNotificationService.swift` |
| Timeline 行 / 状態 | `TripDataHub/Views/TimelineRowViews.swift`, `TripDataHub/Models/TripLegDisplaySupport.swift` |
| Parser 日付演算 | `TripDataHub/Services/PDFTripParser.swift` |
| Model 時刻契約 | `TripDataHub/Models/TripModels.swift` |

---

## 2. Root Cause Analysis

観測された症状は 12 個あるが、原因は **5 個** に収束する。以下 RC-1〜RC-5。

### RC-1 — Flight State が存在せず、Presentation Phase が State を代行している

`FlightCountdownSharedModels.swift`:

```swift
static func phase(scheduledDepartureUTC: Date, now: Date) -> CountdownPresentationPhase {
    if now < std.addingTimeInterval(-12h) { return .none }
    if now < std.addingTimeInterval(-6h)  { return .widget }
    if now < std                          { return .liveCountdown }
    if now < std.addingTimeInterval(+6h)  { return .liveDelayed }   // ← STD 経過のみで Delayed
    return .finished                                                 // ← STD+6h のみで Completed
}
```

このモデルには **STD しか入力がない**。STA も ATD/ATA も参照していない。したがって:

- `.liveDelayed` = 「STD を過ぎた」だけ → `statusText` が `"Delayed \(...)"` を返す（`FlightCountdownSupport.swift:86`、Widget 側 `TripDataCountdownWidget.swift:280` も同文言）。**これが禁止事項「STD passed → Delayed」の実装そのもの。**
- `.finished` = 「STD+6h を過ぎた」だけ → `"Completed"`（`TripDataCountdownWidget.swift:282`）。ANC→SGN は block 約 13h なので、**STD+6h は確実に飛行中**。「飛行中なのに Completed」はこの 6h 定数の必然的な帰結であり、偶発ではない。
- Dynamic Island compact trailing の `+H:MM STD`（`:321`）も同じ判定。実運用で見えた `+2:28 STD` はこれ。

> **重要な判定**: 報告された `Delayed 5h 23m`（SGN→ICN DH KE480、韓国 TZ 変更後）は **TZ バグではない**。KE480 の block は約 5h であり、5h23m は「STD からの経過時間」＝ `.liveDelayed` カウンタの値と一致する。すなわち **到着済み leg が Live Activity に残り、STD からの経過時間を Delayed として表示し続けていた**。TZ 変更は引き金ではなく、ユーザーが画面を見た契機にすぎない。
> ただし TZ 依存は別途 RC-5 に実在するので、両方を修正する。

### RC-2 — Countdown target が Planning 時刻ではなく Display 時刻を見ている（INV-012 違反）

`FlightCountdownSupport.swift:189`:

```swift
guard let scheduledDepartureUTC = LegConnectionTextBuilder.parseUTC(depUTC),   // ← depUTC
      let scheduledArrivalUTC   = LegConnectionTextBuilder.parseUTC(arrUTC),
```

`TripModels.swift` の型契約:

- `depUTC` / `arrUTC` = **Display 用**。解決順は `Actual > Current Scheduled > Original Scheduled`。
- `plannedDepartureUTC` / `plannedArrivalUTC` = **Planning 用**。`stdUTC ?? originalSTDUTC ?? depUTC`。

Countdown は planning 系を使わなければならない（`NextReportWindowBuilder` は正しく `plannedDepartureUTC` を使っており、Countdown だけが逸脱している）。

結果:

- ATD が観測されている leg では **countdown target が STD ではなく ATD になる** → `Dep in HH:MM` が STD との差と一致しない。**「数分〜30 分程度のズレ」の直接原因**（ATD − STD の実分布と一致）。
- 逆に `stdUTC` が nil で `originalSTDUTC` しかない leg では、revised 前の original が target になりうる。

### RC-3 — Current Leg 選択が「終了した leg」を除外しない

`FlightCountdownSupport.swift:41`:

```swift
let eligibleLegs = legs.filter {
    nowUTC >= $0.scheduledDepartureUTC.addingTimeInterval(-12h)
 && nowUTC <  $0.scheduledDepartureUTC.addingTimeInterval(+6h)
}
```

**arrival も actual も一切見ていない。** さらに優先順位は `liveCountdown > widget > liveDelayed`。

したがって:

- 到着済み（`ataUTC != nil`）の leg でも、STD+6h 以内なら選択対象に残る。
- 次の leg がまだ T-12h に入っていない時間帯では、**終了した leg が唯一の候補になる** → `.liveDelayed` として選択 → Live Activity を新規生成 → `+2:28 STD`。
- **症状 11（ICN 到着後にアプリ起動したら 5X173 が Delayed として復活）はこれで完全に説明できる。** OS 上の残骸ではなく、アプリが起動のたびに再生成している。
- 現行の in-flight leg（STD は過ぎたが STA 前）よりも、次 leg の `.liveCountdown` が優先されるため、**飛行中に次の leg が Dynamic Island を奪う**経路も存在する。

### RC-4 — Import が 1 transaction ではなく、dedup を自分で解除して再実行している

`AppViewModel.externalConsumerLoop()`:

```swift
if pendingImport != nil {
    hasQueuedImport = true
    await externalOpenCoordinator.requeueFront(nextItem)   // ← 同一 PDF を先頭に戻す
    break
}
```

`AppViewModel.confirmPendingImport()`（成功パス末尾）:

```swift
self.pendingImport = nil
hasQueuedImport = false
await resetExternalOpenDedup()          // ← ExternalOpenLaunchGate.reset()
                                        //   + coordinator.reset()
                                        //   + clearPersistentImportFingerprint()
importInProgress = false
startExternalConsumerIfNeeded()         // ← requeue 済みの同一 PDF を再消費
```

そして重複抑止の TTL:

```swift
private static let persistentFingerprintTTL: TimeInterval = 30   // 秒
```

**結論**: iOS が同一 PDF を 2 経路（App Group handoff / external open URL、または Inbox コピー違い）で届けると、

1. 2 通目は `pendingImport != nil` により **破棄されず front に requeue** される
2. ユーザーが `Replace and Import` を押す
3. `resetExternalOpenDedup()` が **content fingerprint 重複排除を明示的に消す**
4. `startExternalConsumerIfNeeded()` が requeue 済みの同一 PDF を再消費
5. **同じ Import Preview が再度出る** → 2 回目の `Replace and Import`（今度は今入れたばかりの trip を自分自身で置換）

これが「実質 2 回操作が必要」の機構的原因。30 秒 TTL も無力：Import Preview のレビュー時間は通常 30 秒を超えるため、reset がなくても TTL 切れで重複が通る。

補足（UI 側）: `ImportPreviewView.swift:154/180` は `Confirm Import` を押すと `confirmationDialog` で `Replace and Import` を出す。Replacement 時に **確定操作が 2 段**あり、これが要求仕様違反。

### RC-5 — Derived operational state の再構築点が「画面イベント」しかなく、rebuild が保証されていない

`RootTabView.swift` の 3 箇所のみが `refreshFlightCountdownPresentation()` を呼ぶ:

- `.onAppear`
- `.onChange(of: scenePhase) == .active`
- `.onChange(of: viewModel.scheduleDataRevision)`

問題点:

1. **周期 refresh が存在しない。** アプリを開いたまま STD/STA を跨いでも current leg は再選択されない。
2. `refreshFlightCountdownPresentation` は `Task { }` の fire-and-forget。**起動直後に `Activity<FlightCountdownAttributes>.activities` がまだ populate されていない**タイミングで走ると、既存 Live Activity を 0 件と誤認して `end` を行わず、新規 `Activity.request` を追加する。旧 leg の Live Activity（DH 5X67）が生き残る経路。**症状 10 の主因。**
3. Notification 側 (`rescheduleNotificationsIfAuthorized`) と Live Activity 側は別経路で、順序保証も失敗時の整合もない。
4. Replace 成功時に「旧 derived state を明示破棄する」ステップが存在しない。現状は「新 state を計算した結果として偶然古いものが消える」ことに依存している。

加えて **TZ 依存の実在箇所**（RC-1 の誤診とは別）:

- `PDFTripParser.addDays(_:to:)` は `DateFormatter`（`timeZone` 未設定＝device TZ）と `Calendar.current` で日跨ぎ演算をしている。**device TZ が変わると day rollover の結果が変わりうる。** date-line crossing trip で危険。
- `NextReportNotificationService` は `Calendar.dateComponents(in:from:)` の **全component**（weekday / weekOfYear / quarter / nanosecond 等を含む）を `UNCalendarNotificationTrigger` に渡している。過剰制約による不発・誤発火の既知パターン。absolute 差分ベースに変更すべき。

---

## 3. Historical Architecture / State Model — RETIRED by §0.1

### 3.1 時刻の単一原則

> **Countdown / state 判定に使う Date は、すべて絶対時刻（UTC instant）である。TimeZone は表示フォーマット時にのみ適用する。**

- 入力は `plannedDepartureUTC` / `plannedArrivalUTC`（Planning）、`atdUTC` / `ataUTC`（Actual）、および trip 単位の `reportTimeUTC`。`depUTC` / `arrUTC` は **Countdown engine から参照禁止**。
- Duration = `target.timeIntervalSince(now)` のみ。`Calendar` / `DateComponents` を duration 算出に使わない。
- 表示 TZ（LCL/UTC）は Timeline のユーザー選択に追従する presentation layer の関心事。

### 3.2 Operational State と Presentation Window の分離（前提）

この 2 つは **別レイヤーであり、絶対に混ぜない**。RC-1 は両者が同一 enum に同居していたことが本質である。

| レイヤー | 責務 | 入力 | 例 |
|---|---|---|---|
| **Operational State** | その leg が運航上どの段階にあるか | `plannedDepartureUTC` / `plannedArrivalUTC` / `atdUTC` / `ataUTC` ＋ optional な `reportTimeUTC` | `.inFlight`, `.scheduledDeparturePassed` |
| **Presentation Policy** | その state を **どの面に、いつから** 出すか | Operational State ＋ 現在時刻 ＋ 面ごとの window 定数 | Widget は T-12h から、Live Activity は T-6h から |

- `T-12h` / `T-6h` などの window 定数は **Presentation Policy にのみ存在**し、`FlightOperationalState` の判定に一切入らない。
- したがって「Live Activity にまだ出ていない」ことと「まだ運航段階に入っていない」ことは**別事象**として扱える。
- Presentation Policy は面ごとに異なってよいが、**入力となる Operational State は §3.6 の単一 builder の出力ただ 1 つ**である。

### 3.3 Flight State Model（新規・唯一の判定器）

新規ファイル `TripDataHub/Models/FlightOperationalState.swift` を作る。

```swift
/// Leg 単位の運航状態。Presentation window（T-12h / T-6h 等）は一切含まない。
///
/// 判定入力は 5 つ:
///   - planning 時刻 2 つ  : plannedDepartureUTC / plannedArrivalUTC（必須）
///   - actual 時刻 2 つ    : atdUTC / ataUTC（いずれも optional。nil = 未観測）
///   - reportTimeUTC       : optional。trip 単位の値で、trip の最初の domicile 出発 leg
///                           にのみ非 nil。nil の leg は report 概念を持たない。
enum FlightOperationalState: Equatable {
    case preReport                   // Trip 開始前 かつ Report Time 前
    case postReportPreDeparture      // Report Time 以降、または Trip 開始後の後続 leg。STD 前
    case scheduledDeparturePassed    // STD 経過、ATD 不明、STA 前（Delayed とは言わない）
    case inFlight                    // ATD 確認済み、ATA 未確認、かつ STA 前
    case scheduledArrivalPassed      // STA 経過、ATA 不明（STA + 1h まで）。ATD の有無を問わない
    case completed                   // ATA 確認済み（＝ actual completed のみ）
    case stale                       // STA + 1h 超、ATA 不明 → 表示を止める。ATD の有無を問わない
}
```

> **`.preTrip` は削除した。** 旧定義の `.preTrip` と `.preReport` は「Trip 開始前・Report Time 前」で意味が重複しており、境界が SWE の推測に委ねられていた。`.preReport` に一本化する。
>
> 「まだ遠い未来の leg なので何も出さない」は **Operational State ではなく Presentation Policy** で表現する（§3.2）。`.preReport` であっても Presentation Policy が「T-12h 前は非表示」と判断すれば何も出ない。

**Report Time の適用範囲（`.preReport` と `.postReportPreDeparture` の境界）**

Report Time は **leg の属性ではなく trip の属性**である。したがって:

- **Trip の最初の domicile 出発 leg のみ** が `.preReport` を取りうる。Report Time は `NextReportWindowBuilder` が算出する trip 単位の値（§3.5 の region rule 適用後）。
- **Trip 開始後（＝ Report Time 経過後）の後続 leg** は Report Time を持たない。STD 前であれば無条件に `.postReportPreDeparture` とする。今 Build では `Pick up in` を実装しないため、後続 leg に report 相当の概念を持ち込まない。
- Report Time が算出できない場合（domicile 出発 leg が特定できない等）は `.postReportPreDeparture` にフォールバックし、`Dep in` を出す。**`.preReport` を推測で作らない。**

**判定入力**は次の 5 つのみ:

| 入力 | 出所 |
|---|---|
| `plannedDepartureUTC` | `TripLeg` |
| `plannedArrivalUTC` | `TripLeg` |
| `atdUTC`（nil 可） | `TripLeg` |
| `ataUTC`（nil 可） | `TripLeg` |
| `reportTimeUTC`（nil 可 / trip 単位・最初の domicile 出発 leg のみ非 nil） | `NextReportWindowBuilder` |

**遷移規則（上から順に評価し、最初に該当したものを返す。時間経過のみで actual を推測しない）**

```
1. ata != nil                                   → .completed
2. ata == nil && now >= STA + 1h                → .stale
3. ata == nil && now >= STA                     → .scheduledArrivalPassed
4. atd != nil && now <  STA                     → .inFlight
5. now >= STD                                   → .scheduledDeparturePassed
6. reportTime != nil && now < reportTime        → .preReport
7. それ以外（STD 前）                             → .postReportPreDeparture
```

**評価順序の根拠（重要 — 旧版の誤りを修正した箇所）**

- **`.completed` だけが actual 優先。** ATA が観測されていれば、経過時間に関係なく `.completed`。これは唯一「実際に終わった」と言える根拠だから。
- **STA 境界は `.inFlight` を上書きする。** 規則 2・3 を規則 4 より先に評価する。ATD が既知でも ATA が未観測なら、STA を過ぎた時点で `.inFlight`（＝`Arriving in`）を出し続けることはできない。schedule-based countdown は STA でゼロになるため、それ以降 `Arriving in` を出せば負値かゼロ張り付きになり、事実上「もう着いているはず」という推測を表示することになる。**これは禁止事項そのもの。**
- したがって `.scheduledArrivalPassed` と `.stale` は **ATD の有無を問わず**到達する。旧版は規則 2 に `atd != nil → .inFlight` を置いていたため、**ATD が既知のフライトでは `.scheduledArrivalPassed` と `.stale` が到達不能（dead state）になっていた。** ATD が判明する実運用フライトほど STA 経過後に `.inFlight` のまま張り付くという、最も起きやすい経路が壊れていた。
- 規則 5 に到達するのは `ata == nil && now < STA` かつ（`atd == nil` または規則 4 で分岐済み）の場合、すなわち **ATD 不明で STD 経過・STA 前**のケース。
- `Delayed` という語は **enum にも表示文字列にも存在させない**。今 Build で `Delayed` / `Completed`（actual 由来でないもの）の文字列は全削除する。

**`.inFlight` の根拠は今 Build では ATD のみに固定する。**

```
atdUTC != nil && ataUTC == nil && now < STA  →  .inFlight
```

- ATD 以外の根拠（経過時間、次 leg の存在、connection 成立、位置情報等）から airborne / in-progress を **推定してはならない**。ATD がないまま STD を過ぎた leg は `.scheduledDeparturePassed` であり、それ以上のことを主張しない。
- 逆方向も同じく推測しない: **ATD があっても STA を過ぎたら `.inFlight` を維持しない。** ATD は「出発した」ことの証拠であって「まだ飛んでいる」ことの証拠ではない。STA 経過後に in-flight を主張し続けることは、時間経過からの推測と同じ誤りである。
- ATD 以外の根拠を将来追加する場合は別 Build ＋ ADR で扱う。

> Incorrect operational information is worse than no information.

**判定入力が欠けている場合（`.unknown` state は作らない）— PM 確定事項**

「unknown」という語が 2 つの異なる事象に使われていたため、ここで分離して確定する。

| 種別 | 意味 | 扱い |
|---|---|---|
| **(a) Operational unknown**<br>＝ actual state が未確認 | schedule は判っているが ATD / ATA が観測されていない | **これが `.scheduledDeparturePassed` と `.scheduledArrivalPassed` そのものである。** 中立的な schedule ベース表示を出す。この 2 state が「不明を不明として出す」ための state であり、専用の state を追加する必要はない |
| **(b) Input insufficiency**<br>＝ state が計算できない | `plannedDepartureUTC` / `plannedArrivalUTC` が nil、TZ 解決不能 等 | **operational state を生成しない。** その leg は current leg 候補から除外し、次の候補へ進む。表示面には何も出さない |

- **`.unknown` state は作らない。** 7 states のままとする。
- 理由: `.unknown` を state として持つと、それは current leg 候補になり、表示文言を持つことになる。「状態が判らない leg」に画面上の居場所を与えると、必ず「何か出す」方向に引っ張られる。**判らないなら候補から外すのが唯一の安全な扱い**であり、これは `.stale` を「表示を止める」state として定義したのと同じ判断である。
- 種別 (b) は **サイレントに握り潰さない。** operational state を生成できなかった leg は理由付きで log に残し、既存の `SyncDiagnosticsLog` から追跡できるようにする。ただし運航中にユーザー向けエラーバナーを出すことはしない（Distraction になるため）。
- 現行 `countdownLeg()` が parse 失敗時に nil を返す挙動は、この規則の既存実装として妥当。**nil の意味を「候補外」に統一し、「後で埋める」「デフォルト値を入れる」ことはしない。**

**ATD 既知フライトの正常な遷移列（今 Build の期待動作）**

```
.postReportPreDeparture
      ↓ (now >= STD, ATD 未観測)
.scheduledDeparturePassed
      ↓ (ATD 観測)
.inFlight                        ← "Arriving in HHhr MMmin"
      ↓ (now >= STA, ATA 未観測)
.scheduledArrivalPassed          ← 2 行表示（§3.4）
      ↓ (now >= STA + 1h, ATA 未観測)
.stale                           ← 表示終了
```

ATA が観測された時点で、この列のどこからでも `.completed` へ遷移する。

### 3.4 表示文言（唯一の仕様）

各 state の表示は **status 行**（今どういう状態か / 経過・残り時間）と、必要な場合の **reference 行**（基準となる schedule timestamp）の 2 要素で構成する。

| State | status 行 | reference 行 |
|---|---|---|
| `.preReport` | `Report in HHhr MMmin` | なし |
| `.postReportPreDeparture` | `Dep in HHhr MMmin` | なし |
| `.scheduledDeparturePassed` | `Scheduled Departure Time Passed` | なし |
| `.inFlight` | `Arriving in HHhr MMmin`（**STA 前に限る**。値は必ず正） | なし |
| `.scheduledArrivalPassed` | `Scheduled Arrival Time Passed HHhr MMmin` | `Scheduled Arrival: HH:MM LCL` / `Scheduled Arrival: HH:MM UTC` |
| `.completed` | 表示なし（Live Activity end、次 leg へ遷移） | なし |
| `.stale` | 表示なし（Live Activity end、Widget snapshot 削除） | なし |

**`.scheduledArrivalPassed` の表示仕様（status と reference timestamp を分離する）**

STA を経過し、ATA が不明の場合は必ず 2 行で出す。**ATD が既知（飛行中だったフライト）でも、ATA が未観測なら同じ表示に切り替わる** — §3.3 の遷移規則 3 を参照。

```
Scheduled Arrival Time Passed 0h 12m
Scheduled Arrival: 14:55 LCL
```

Timeline の表示モードが UTC の場合:

```
Scheduled Arrival Time Passed 0h 12m
Scheduled Arrival: 05:55 UTC
```

- **1 行目** = STA からの経過時間（`now − STA`）。`HHhr MMmin` 形式、絶対時刻差分で算出する。
- **2 行目** = Scheduled / Revised Arrival の reference timestamp。**revised がある場合は revised 値**（＝ `plannedArrivalUTC` の解決結果）。
- **LCL / UTC は Timeline でユーザーが選択している表示モードに追従する。** LCL は arrival airport の timezone（`arrivalTimeZoneID`）で解決する。device timezone は使わない。
- 表示モードの切替で **1 行目の経過時間は変化しない**（絶対時刻差分であるため）。変わるのは 2 行目の時刻表記のみ。
- **STA + 1h を超えたら `.stale` に遷移し、表示を終了する。** それ以降このフライトについて persistent status を出し続けない。
- 経過時間がどれだけ伸びても `Completed` は表示しない。`Completed` は ATA 観測時のみ。

補足:

- Trip 開始後は Report Time を表示しない（`Pick up in` は将来対応。今 Build 未実装）。
- `Arriving in` は `plannedArrivalUTC − now`。内部仕様コメントに「schedule-based countdown / not a real-time ETA」と明記すること。**`.inFlight` は STA 前にしか存在しないため、この値が 0 以下になる経路は存在しない。** 0 以下が観測されたら state machine のバグであり、`max(0, ...)` でクランプして隠蔽しないこと（assertion を推奨）。
- Dynamic Island compact trailing のような幅の狭い面では status 行のみを出し、reference 行は expanded / Lock Screen に出す。**status 行の文言そのものを面ごとに変えないこと。**

### 3.5 Report Time rule（今 Build の実装範囲）

```
origin と destination が両方 Lower 48   → STD - 1:00
それ以外（Alaska / Hawaii を含む）        → STD - 1:30
```

- **この rule はアプリ全体で唯一である。** report lead を計算する箇所が 2 つ以上あってはならない。
- 現行 `NextReportWindowBuilder.reportLeadTimeSeconds = 90 * 60` の固定値を、region 判定関数に置換する。
- Lower 48 判定は airport IATA → region の解決が必要。`DomicileSupport` / `IATATimeZoneResolver` の既存資産を再利用し、**新規の並行実装を作らないこと**（AGENTS.md）。判定不能時は安全側（1:30）にフォールバックする。

**Asia / Europe regional の 60 分 rule は「未実装」ではなく「誤実装」である — PM 訂正（Phase 1 レビュー時に判明）**

本書の旧版は「Asia regional / Europe regional の 1h rule は今回実装しない（将来対応）」と記述していたが、**これは事実誤認だった。** `TimelineSupport.swift` の rest / layover card が、次 leg の duty start を計算する際に既に独自の report lead を持っている:

```swift
private static func reportLeadMinutes(for nextLeg: TripLeg) -> Int {
    flightIsWhollyInsideReducedReportRegion(nextLeg) ? 60 : 90
}
// flightIsWhollyInsideReducedReportRegion は depRegion == arrRegion を返すため、
// Asia→Asia / Europe→Europe も 60 分になる
```

**PM が運航当事者に確認した結果、正しい rule は Lower 48 ↔ Lower 48 のみ 60 分、Asia / Europe regional は 90 分である。** したがって Timeline 側の現行挙動は仕様どおりではなく **バグ**であり、将来実装すべき機能でもない。

必須対応:

- `TimelineSupport.reportLeadMinutes` の判定を **`depRegion == arrRegion` から「両端が `.lower48` であること」に修正**する。Asia→Asia / Europe→Europe は 90 分になる
- `NextReportWindowBuilder` と `TimelineSupport` が **同一の判定関数を共有**すること。`ReportRegionResolver` の共通化だけでは不十分で、**lead time を返す関数そのものを 1 本にする**
- 影響: `ICN→CGO` / `CGO→ICN` など Asia regional leg の Timeline rest card 表示が 30 分変わる。これは意図された修正である
- `ReportRegion` の `.asia` / `.europe` は分類としては残してよいが、**今 Build では lead time を変える根拠にしない**

### 3.6 Single Source of Truth（derived state の一本化）

新規 `TripDataHub/Services/OperationalStateBuilder.swift`（naming は SWE 裁量）を導入し、以下 **すべて** がこれ 1 本を参照する:

- Dynamic Island
- Lock Screen Live Activity
- Home Screen Widget
- Notification scheduling
- App Timeline
- App launch reconstruction

```
Persisted Trips (revised = 唯一の source of truth)
        ↓
Current Trip / Current Revision
        ↓
Current Leg 選択（下記規則）
        ↓
FlightOperationalState 判定
        ↓
Presentation payload（1 個）
        ↓ 配信
Live Activity / Widget snapshot / Notification schedule / Timeline
```

**Current Leg 選択規則（RC-3 の置換）**

優先順に評価し、最初に該当した leg を current とする。

1. `.inFlight`（1 個のみ想定。複数あれば STD が最新のもの）
2. `.scheduledArrivalPassed`（STA 経過・ATA 不明。まだこの leg が最新の運航対象）
3. `.scheduledDeparturePassed`（STD 経過・ATD 不明）
4. `.postReportPreDeparture` / `.preReport` のうち **STD が最も早い** leg
5. `.completed` / `.stale` の leg は **候補から完全に除外**（RC-3 の直接修正）
6. **判定入力が欠けて operational state を生成できない leg は、上記いずれの順位にも入れず候補から除外**し、次の候補へ進む（§3.3 の種別 (b)）。除外は log に残す
7. 候補なしなら presentation payload は nil（＝ Live Activity end / Widget snapshot 削除）

順序の根拠: 出発側の未来 leg（規則 4）よりも、到着側の現在進行 leg（規則 1〜3）が常に優先される。旧実装は `liveCountdown > widget > liveDelayed` の順で **未来 leg が飛行中 leg を奪う**構造だったため、これを逆転させている。

Operating flight と Commercial DH で **判定も計算も分岐させない**。DH は `isDeadhead` という表示属性にすぎない（`FlightCountdownLeg.isDeadhead` は残すが、engine の分岐条件にしない）。

### 3.7 Replace Import transaction

```
Parse → Validate → Detect Existing Trip
      → [Replacement 必要?] → 中央 Modal 1 回だけ
      → Replace old trip（persist）
      → Invalidate old derived state（後述の 6 手順・destructive rebuild）
      → Rebuild current operational state
      → Refresh Timeline / Live Activity / Notification
      → Done
```

**Invalidate old derived state（順序厳守・全て await 完了させる）**

1. `nextreport.` prefix の pending / delivered notification を **全 cancel**
2. 既存 Live Activity を **全 end**（`legID` 一致判定に依存せず、無条件 end）
3. App Group snapshot ファイルを削除、current/next-leg cache を invalidate
4. revised trip を persist
5. revised trip から current operational state を再計算
6. 必要であれば新しい Live Activity / Notification を生成

> **方針（Replacement 時のみ）**: Trip Replacement では既存 Live Activity を patch して延命しない。**destructive rebuild**（全 end → 再生成）を選ぶ。patch 方式は旧 leg の残存を許すため（RC-5 / 症状 10）。
>
> **この destructive rebuild は Trip Replacement 専用である。** 通常運用の `refresh` にこの方式を適用してはならない — §3.8 を参照。

### 3.8 Live Activity Lifecycle（Replacement と通常 refresh の区別）

`FlightCountdownCoordinator` は **2 つのモードを明示的に持つ**。呼び出し側がどちらかを指定し、coordinator が推測しない。

```swift
enum LiveActivityRefreshMode {
    case reconcile            // 通常運用: 同一 leg なら update、leg 変更なら end → create
    case destructiveRebuild   // Trip Revision / Replacement 専用: 無条件 end → rebuild
}
```

| ケース | モード | 挙動 |
|---|---|---|
| **同一 leg の state 遷移**<br>`.preReport → .postReportPreDeparture`<br>`.postReportPreDeparture → .scheduledDeparturePassed`<br>`.inFlight` 中の `Arriving in` 更新<br>`.inFlight → .scheduledArrivalPassed` | `.reconcile` | **既存 Activity を `update` する。end しない。** |
| **current leg が変わる**（前 leg 完了 → 次 leg へ） | `.reconcile` | 旧 leg の Activity を `end` → 新 current leg の Activity を `create` |
| **current leg が nil になる**（`.completed` / `.stale` のみ） | `.reconcile` | 該当 Activity を `end`、snapshot 削除。新規 create はしない |
| **Trip Revision / Replacement** | `.destructiveRebuild` | current leg 一致に関係なく **旧 Activity を全 end** → revised source of truth から完全 rebuild |

- `.reconcile` で毎回無条件に end/request し直す設計にしてはならない。Live Activity の再生成は視覚的なちらつきと ActivityKit の request 予算消費を招く。**state が変わっても leg が同じなら update。**
- `.destructiveRebuild` は `confirmPendingImport()` の replacement 成功パスからのみ呼ぶ。scenePhase / 周期 refresh / 起動時 reconcile からは呼ばない。
- 起動時 reconcile は `.reconcile` で行う。ただし **`Activity.activities` が populate される前に判定しないこと**（RC-5-2）。populate 前に走ると「既存 0 件」と誤認して不要な create をしてしまい、これは reconcile と destructive rebuild のどちらでも同じ事故になる。

---

## 4. Implementation Plan

### Phase 0 — 契約の明文化（コード変更前）

- `docs/INVARIANTS.md` の INV-013〜018 を 2026-08-17 Product Owner revision に同期すること
  - **INV-013**: real-time operational 判定は `plannedDepartureUTC` / optional `reportTimeUTC` / `nowUTC` のみ。STA は route display、ATD / ATA は history data。
  - **INV-014**: 時間経過から Actual を推測しない。STD〜STD+60 は schedule fact `Departure time passed` のみ、STD+61 で表示終了。
  - **INV-015**: derived operational state（Live Activity / Notification / Widget snapshot / current-leg cache）は単一 builder の出力のみから生成する。**Trip 置換時は破棄→再生成（destructive rebuild）、通常の state 遷移は reconcile/update** とし、両者を混同しない。
  - **INV-016**: `T-12h` / `T-6h` 等の表示 window 定数は Presentation Policy に属し、`FlightOperationalState` の判定入力にしてはならない。
  - **INV-017**: Actual は history-only。ATD / ATA の違いが operational output を変えてはならない。
  - **INV-018**: exact boundary は STD / STD+61。passed leg は minute 60 まで current を保持し、+61 で次 leg へ進む。
- 各 invariant には **Rule / Why / 禁止される実装 / Enforced by / 対応する T-xx** を記載する。Phase 0 時点では型もテストも存在しないため、`Enforced by` は **「Phase 1〜3 で強制される予定」と明示**し、実装済みであるかのように書かないこと（SWE 提案を採用）
- ADR を 1 本追加: `docs/ADR/ADR-004-flight-operational-state-model.md`（本書 §3 を正式化）
- **`docs/AI_CONTEXT_INDEX.md` に routing entry を追加（PM 承認済み・Phase 0 の 3 番目のファイル）**
  - 新セクション `## If Touching Flight State / Countdown / Live Activity / Notification` を設け、`docs/ADR/ADR-004-flight-operational-state-model.md`、`docs/INVARIANTS.md`（INV-013〜018）、本書へ routing する
  - 理由: index は routing layer であり、`Phase` 節に「Only the files listed in this index exist」と明記されている。**index に載っていない ADR は将来の agent から不可視**であり、Phase 0 の目的（契約の固定）が達成されない
- **本書（`docs/BUILD_WEEK_TDH_RELIABILITY_SWE_INSTRUCTION.md`）を Phase 0 の commit に同梱すること。** INV-013〜018 と ADR-004 は T-1〜T-23 を引用しているが、**T-xx の定義は本書にしか存在しない。** 本書が untracked のままだと、6 件の invariant がすべて未定義の test ID を参照することになる。ADR-004 の `Related` にも本書を追加する
  - ADR には「既存 `FlightCountdownTests.swift` の phase テスト群が誤った仕様を固定しており、Phase 1 で削除・書き換えの対象になる」ことを **Consequences として明記**する。テストの削除は意図された仕様変更であり、QA への事前通知が必要
  - Lower 48 判定の **データ源は決定済みとして書かない**（§8 の未決事項 #1。ADR には report lead-time の製品ルールのみを記録する）

### Phase 1 — P0-A revision: STD-only Operational Countdown（実装は別承認待ち）

1. `FlightOperationalState` を `.preReport` / `.preDeparture` / `.departureTimePassed` / `.expired` の4 casesへ置換する。旧 arrival / Actual-driven casesを aliasとして残さない。
2. evaluator signature を `plannedDepartureUTC` / optional `reportTimeUTC` / `nowUTC` のみにする。`plannedArrivalUTC` / ATD / ATAを受け取る引数を持たせない。
3. exact orderを `STD+61 → STD → report → preDeparture` とし、すべて `>=` で後段へ倒す。elapsed minuteは floorで0〜60、+61でexpired。
4. reportはtrip最初の domicile departureだけ。後続legはreportなし。算出不能時は `.preDeparture`。
5. current legはnon-expired `.departureTimePassed`をlatest STDで優先し、+61で除外してearliest future legへ進む。
6. App Timeline iPhone/iPad、Widget、Live Activity、Dynamic Island、notification、launch reconstructionを同じ structured descriptorへ収束させる。Timeline独自の `(-05d 15h 45m)` countdown APIは削除し、並行実装を残さない。
7. prefixは `Report in` / `Dep in` / `Departure time passed`。elapsed valueはOS localizationを許容し、formatting pollingは導入しない。
8. boundary schedulerとActivity stale boundaryをreport / STD / STD+61へ置換する。STA / STA+1hを削除する。
9. Actual fields、parser、canonical JSON、Leg Historyは維持するが、operational conversionはATD/ATAをparse・validate・exclude reasonに使用しない。
10. legacy derived stateをfail closedでmigrationし、旧arrival copyとActivityが残存しないことをreconcileで保証する。
11. Operating / DHでengineを分岐しない。

### Phase 2 — P0-B: Replace Import を 1 transaction 化

1. `externalConsumerLoop`: `pendingImport != nil` 時の重複投入は **requeue せず、content fingerprint が一致するなら破棄**する（別 trip の PDF のみ queue に残す）
2. `confirmPendingImport()` から `resetExternalOpenDedup()` を **削除**。fingerprint は「消費済み」として保持する
3. `persistentFingerprintTTL` を 30 秒から、レビュー時間を包含する値（最低 15 分）に延長。または TTL ではなく「確定済み fingerprint リスト」方式へ変更（推奨）
4. Import UI: replacement 検出時は `Confirm Import` を出さず、**中央 Modal 1 個**にする

```
Replace Existing Trip?

Trip 12165 already exists.
The imported schedule contains revisions and will replace the current version.

[ Cancel ]   [ Replace and Import ]
```

   - `Confirm Import` と `Replace and Import` を **同時に画面に存在させない**
   - replacement なしの通常 import は従来どおり `Confirm Import` 1 回

   > **【取り消し】Phase 2 レビューで PM が承認した「Modal なし」の逸脱は、実機確認 A-3 の FAIL により撤回する。**
   >
   > 撤回理由: `Replacements` Section は List の上部にあり、確定ボタンは Legs / Warnings Section の下にある。**6 leg のトリップでは警告とボタンが同一画面に収まらない。** 「同一条件で描画されるから視認できる」という PM の判断は誤りだった。破壊的操作の直前に警告が見えないのは要件違反である。
   >
   > **確定仕様（Phase 2 UI-only correction / Tony 承認済み）**
   >
   > | 状況 | Preview 下部のボタン | タップ後 |
   > |---|---|---|
   > | replacement candidate **なし** | `Confirm Import` | 直接 import 実行（従来どおり） |
   > | replacement candidate **あり** | `Replace and Import` | **画面中央の `.alert`** を表示。Alert 内の最終確定も `Replace and Import` |
   >
   > - replacement 時に generic な `Confirm Import` を **描画しない**
   > - **`.confirmationDialog` を使わない。** iPad では popover として anchor され、元の不具合報告にあった「右側 popover」がまさにこれ。`.alert` は iPhone / iPad どちらでも常に画面中央に出る
   > - 状態を変える確定操作は Alert 内の `Replace and Import` の **1 回だけ**
   > - `Replacements — This import will replace Trip 12165.` の Section 表示は **維持**する
   >
   > Alert の内容:
   >
   > ```
   > Replace Existing Trip?
   >
   > Trip 12165 already exists.
   > The imported schedule contains revisions and will replace the current version.
   >
   > [ Cancel ]   [ Replace and Import ]
   > ```
   >
   > - candidate が複数ある場合は、旧 `confirmationDialog` の message と同様に **全対象を列挙**する（`sameTripID` と `timeOverlap` で文言を出し分ける）
   > - `expectedReplacementIDs` は **Alert を提示する時点**の candidate から取得する。Alert に表示した対象と、`confirmPendingImport` が実際に削除する対象を一致させるため
   > - **transaction / fingerprint ledger / queue のロジックには一切触れないこと。** RC-4 の修正は実機で PASS しており、本件は UI 層のみの修正である
   > - 検証: **T-25** を追加する — replacement 経路で `Confirm Import` が描画されないこと、`.confirmationDialog` を使っていないこと、状態を変える確定が 1 回であること
5. `confirmPendingImport()` の成功パスで §3.7 の invalidate 手順を **`.destructiveRebuild` モードとして明示的に呼び出し**、rebuild 完了まで await する
6. **iCloud / CloudKit sync の既存 transaction 境界を壊さないこと。** `beginCrewAccessImportTransaction()` 〜 upload の defer 構造は現状維持。invalidate は local commit 後・upload と並行して行ってよいが、rollback パスでも整合すること

#### Phase 2 追加条件（SWE 設計レビュー時に PM が確定）

**(a) content fingerprint は全 delivery path を横断する単一 ledger であること**

重複配送は external open URL 経由だけではない。**App Group handoff（share extension）経由**も同じ PDF を届ける。したがって:

- `consumePendingAppGroupImportIfAvailable` 経路も **同一の fingerprint ledger を通す**
- 既存の `recentlyConsumedHandoffFileNames`（ファイル名ベース）は `ExternalOpenLaunchGate.stableKey` と同格の **Layer 1 補助**へ降格する。content identity の根拠にしない
- 片方の経路だけ ledger を通す実装は RC-4 を半分しか塞がない

**(b) `dismissed` / `consumed` の抑止は「配送バースト窓」であって「再 import 禁止期間」ではない**

提案の `dismissed` 15 分保持は、**ユーザーが意図的に同じ PDF を再共有したときに無反応になる**。Import Preview を Cancel して、確認のうえ同じファイルを再共有する操作は正常な運用であり、これを 15 分間サイレントに握り潰すのは元のバグより悪い。

確定ルール:

| ledger 状態 | 抑止範囲 |
|---|---|
| **pending active**（preview 表示中） | **経過時間に関係なく常に破棄。** ここが 30 秒 TTL 問題の本体であり、無期限で正しい |
| `consumed`（confirm 成功後） | **配送バースト窓のみ**（推奨 120 秒）。それ以降の同一 fingerprint は意図的な再 import として preview を出す |
| `dismissed`（discard 後） | 同上（推奨 120 秒） |

- 重複配送は数秒以内に到着するため、120 秒で RC-4 は完全に塞がる。15 分は不要であり、副作用のほうが大きい
- **どの状態でも「サイレントに何も起きない」を作らないこと。** 抑止した場合は log に残す。ユーザー起点の再共有を抑止する設計にはしない
- 既存の `test_tombstoneAfterConfirm_doesNotDeleteExplicitReimport` が示すとおり、**同一 trip の明示的な再 import は support された動線**である。これを壊さないこと

**(c) derived-state invalidation は import transaction を無期限にブロックできてはならない**

`.destructiveRebuild` を upload handoff より前に await する設計は正しいが、**ActivityKit / UNUserNotificationCenter の呼び出しが遅延・失敗した場合に transaction が開いたままになる**経路を作ってはならない。transaction が開いている間 foreground / startup sync は defer されるため、ここでのハングは sync 停止に直結する。

- この時点で **local source of truth は既に durable かつ verify 済み**である。derived state の invalidation 失敗を理由に import を失敗扱いにしない
- invalidation は **best-effort + timeout + log** とし、失敗しても import は成功として確定させる
- 失敗した場合の後始末は Phase 3 の `.reconcile`（起動時 / scene activation）が担う

**(d) Phase 2 が作るのは「seam」であり、Phase 3 の実装を先取りしない**

- Phase 2 では **replacement 成功後に await する単一 call site と、その注入可能な seam（protocol / closure）** を確定する
- seam の既定実装は no-op または現行挙動のままでよい。**Activity の end/create、notification cancel、snapshot 削除、`.reconcile` とのモード分離は Phase 3 の責務**
- テストは seam の spy に対して「replacement で 1 回、新規 import で 0 回、rollback で 0 回」を検証する

**(e) T-7 / T-8 は Phase 3 へ移す（PM の過去指示の訂正）**

以前「Phase 2 の PR に T-4 / T-5 / T-7 / T-8 を含めること」と指示したが、(d) のとおり Phase 2 は seam までであり、**実際の notification / Live Activity 破棄は Phase 3 で実装される**。したがって:

- **Phase 2 に含める**: T-4、T-5、および §想定テストに挙げられた duplicate / queue / transaction 系
- **Phase 3 に移す**: T-7（stale notification invalidation）、T-8（stale Live Activity invalidation）

### Phase 3 — P0-C: Live Activity / Notification lifecycle

1. `FlightCountdownCoordinator.refresh` に `LiveActivityRefreshMode`（§3.8）を導入し、呼び出し側がモードを指定する形にする。coordinator 側でモードを推測しない
   - `.reconcile` — **同一 leg の state 遷移は `update`。leg が変わったときのみ end → create。** 無条件の end/request を通常経路に入れないこと
   - `.destructiveRebuild` — Trip Replacement 専用。current leg 一致に関係なく全 end → 完全 rebuild
   - 呼び出し元の対応: `RootTabView` の 3 箇所・周期 refresh・起動時 reconcile はすべて `.reconcile`。`confirmPendingImport()` の replacement 成功パスのみ `.destructiveRebuild`
2. 起動時 race 対策: `Activity.activities` が populate される前に判定しない。モードは `.reconcile`

   > **PM 訂正（Phase 3 レビュー）— 「UI を出す前に await」とは書いたが、アプリ UI 全体を gate する意味ではない。**
   >
   > 本要件の目的は **coordinator が未 populate の空リストを「Activity なし」と誤認して重複生成すること**を防ぐ 1 点のみであり、`FlightCountdownActivityClient.waitForInitialActivityPopulation()` を coordinator 経路の内側で待てば達成される。
   >
   > **アプリの root UI を reconcile 完了まで描画しない実装は禁止する。** 理由:
   > - populate 待ちは bounded（8 回 × 100ms）だが、その後に続く `persist` / `reloadWidgets` / `activities()` / `end()` / `request()` は **timeout のないシステム呼び出し**であり、いずれかが wedge すると root UI が `Color.clear` のまま復帰しない
   > - これは運航前・運航中に開かれるアプリであり、**空白画面は本 Build Week が排除しようとしている「誤った運航情報」より悪い**。何も出ないアプリは Distraction ではなく障害である
   > - bounded な成功パスでも、cold launch のたびに空白フレームが挿入される
   >
   > 正しい形: **root UI は即座に描画し、launch reconcile は background task として走らせる。** 重複生成の防止は `waitForInitialActivityPopulation()` が担保する。追加の安全策が必要なら Phase 2 seam と同様に reconcile 全体へ timeout を掛けてよいが、**UI の描画を待たせないこと。**

   > **追加要件（Phase 3 再レビュー）— populate 保証を「呼び出し側が正しい引数を渡したか」に依存させない**
   >
   > `waitForInitialActivityPopulation: true` を渡す call site が 1 つでも、cold launch では `scenePhase` が `.inactive → .active` に遷移するため `onChange(of: scenePhase)` の `.reconcile`（wait なし）が**同時に走る**。`FlightCountdownCoordinator` は actor だが、population 待ちは `refresh` 内の `await` なので **その間に他の refresh が再入できる**。結果、wait なしの経路が未 populate の空リストを読み、`request()` して **重複 Activity を作る** — RC-5-2 と同一の欠陥が別 entry point から再発する。
   >
   > **保証を coordinator 内部の状態に移すこと。** 例: coordinator が `hasCompletedInitialPopulationWait` を持ち、**false の間はどのモード・どの呼び出し元であっても、必ず population 待ちを済ませてから activity 判定に進む**。`waitForInitialActivityPopulation` 引数は撤去してよい。
   >
   > 理由: 「正しい call site から正しい引数で呼ばれたときだけ安全」という設計は、INV-015 が禁じている *surface ごとの独自判断* と同じ脆さを持つ。**構造で保証すること。**
3. refresh は report time / STD / STD+61 の **境界駆動の再評価**とする。formattingまたはstate更新のための毎分 pollingは禁止。同一 leg の visible state 遷移は `update`、実行機会のあるSTD+61または次回app executionでlegが消える場合はend、次legへ変わる場合はend/requestに落ちること
4. `.expired`（STD+61）をreconcileした時点で旧 Live Activity をimmediate endし、次legが無ければsnapshotを削除する。local-only構成ではsuspended/terminated中のexact boundary wake/dismissalを保証しない。`staleDate = STD+61`は補助metadataでありdismissal guaranteeではない
5. `.departureTimePassed`のsystem timerは`STD..<timerClampUTC`、`timerClampUTC = STD+60min`とする。Activity shellがSTD+61以降も残る場合も60分で表示をclampする。`expirationUTC`と同一propertyにしてはならない
6. `NextReportNotificationService`: `UNCalendarNotificationTrigger` + 全 component を、absolute 差分の `UNTimeIntervalNotificationTrigger`、または `[.year,.month,.day,.hour,.minute,.second,.timeZone]` に限定した component set へ変更
7. Report time lead を §3.5 の region rule に置換

### Phase 4 — P1: Timeline / Live Activity UI

1. Live Activity route 行（`TripDataCountdownWidget.swift:224-233`）: `Spacer` 2 個＋装飾文字列 `・・・✈・・・` の HStack が wrap 原因。**`ANC 23:24 → SGN 02:45` の 1 行固定**に置換。飛行機アイコンは、全対象幅で wrap しないことを実機で確認できた場合のみ可。装飾より layout stability 優先
2. Connection card: `LegConnectionTextBuilder.blockAndConnectionText` は block / connection を **単一文字列**で返しており、幅依存の途中 wrap は不可避。**構造化した値を返す API に変更**する。authoritative acceptance fixture の Trip 12165 では次の値となる:

```swift
struct BlockConnectionDisplay {
    let blockText: String            // "Block: 02:48"
    let connectionText: String?      // "Connection at CGO: 2:26"
}
```

   呼び出し 4 箇所（`ScheduleTimelineRendererView:164`, `TimelineTabView:1259`, `iPadTimelineSidebarView:731`, `OpenTimeTripDetailView:188`）を 2 行・両方右揃えの `VStack(alignment: .trailing)` に更新。**iPhone / iPhone Pro Max / iPad で同一構造**。既存の単一文字列 API は削除する（並行実装を残さない）

### Phase 5 — HISTORICAL / SUPERSEDED proposal: In-Flight Progress

This proposal predates the 2026-08-17 STD-only PO contract and is **not a current implementation instruction**. A future trustworthy realtime source would require a separate build and a new ADR; scheduled time passage alone must not recreate arrival, in-flight, or completed semantics.

---

## 5. Testing Requirements

既存 regression tests が pass したまま実運用で破綻したため、**既存 unit tests の pass を完了条件にしない。**

以下のT-1〜T-24は2026-08-17 Product Owner revision後のauthoritative definitionsである。旧arrival / Actual-driven assertionはretiredであり、同じT番号の旧説明より本表とT-20詳細が優先する。

`TripDataHubTests/FlightCountdownTests.swift` の phase テスト群（`test_phase_atExact_T0_isLiveDelayed` 等）は **誤った仕様を固定している**。State model 置換に伴い削除・書き換える。QA には「これらの test が消えることは意図された仕様変更である」と明示すること。

### 必須追加テスト

| # | テスト | 判定 |
|---|---|---|
| T-1 | shared absolute-time descriptor | `Report in` / `Dep in` のtarget、`Departure time passed` のanchorが共通payloadのabsolute UTC instantと一致。`timerClampUTC = STD+60`と`expirationUTC = STD+61`を別々に保持する |
| T-2 | device timezone 変更（ANC → SGN → ICN → Korea）| **duration が 1 秒も変化しない** |
| T-3 | date-line crossing | ICN→ANC で日付が壊れない。`PDFTripParser.addDays` の TZ 依存を含む |
| T-4 | revised-trip replacement | 確定操作 1 回・transaction 1 回で完了 |
| T-5 | 同一 PDF 2 経路配信 | 2 個目が破棄され、Import Preview が再表示されない |
| T-6 | app relaunch reconstruction | `now >= STD+61min` のlegがcurrentにならず、次の有効legが選択される |
| T-7 | stale notification invalidation | replace 後、旧 trip の pending/delivered が 0 件 |
| T-8 | stale Live Activity invalidation | replace 後、旧 leg の Activity が 0 件 |
| T-9 | operating vs DH parity | 同一schedule入力で **完全に同一のduration / state / semantic descriptor** |
| T-10 | STD elapsed boundary | STD+0 / +1 / +60で `.departureTimePassed`、`Delayed` / `Departed` / `Completed`を生成しない |
| T-11 | Actual independence | ATD / ATAのnil・非nil・値の違いだけではstate / status / selection / payloadが一切変化しない |
| T-12 | STD+61 lifecycle | 境界ちょうどで evaluator は `.expired`。reconcileが実行された時点で次legが無ければpayload nil / Activity immediate end / snapshot削除。suspended中のexact dismissalは要求せず、残存shellのtimerは60分でclampする。ATD / ATA値に依存しない |
| T-13 | Report time rule | Lower48↔Lower48 = 60 分、AK/HI 含む = 90 分、判定不能 = 90 分 |
| T-14 | narrow-width UI | Live Activity route 行 / Connection card が wrap しない |
| T-15 | iPad UI | Connection card が iPhone と同一構造 |
| T-16 | equivalent-surface semantic parity | 同一leg / nowでApp Timeline iPhone/iPad、Widget、Live Activityが同じstate / prefix / anchor UTCを消費し、Timeline独自countdownが存在しない |
| T-17 | Actual/STA inputs absent by construction | evaluator signatureにSTA / ATD / ATAが無く、state enumが4 casesで、旧arrival/Actual-driven casesが存在しない |
| T-18 | same-leg transition vs expiry | `.preReport → .preDeparture → .departureTimePassed` はupdateのみ。STD+61以降の次回reconcileで次legなしならendし、end/requestで同一legを再生成しない |
| T-19 | current leg 変更 vs replacement | leg 変更時は旧 end ＋ 新 create。Trip replacement 時は current leg が同一でも **全 end → rebuild** |
| T-20 | **4-state全境界列** | 単一leg・単一testでreport前 / reportちょうど / STD直前 / STD / +1 / +60 / +61を進め、下記のexact stateと表示をassert |
| T-21 | exact evaluation order | `STD+61 → STD → report → preDeparture` の優先順、report / STD / +61 equality、passed leg優先が固定される |
| Timer clamp | display/lifecycle boundary separation | +59は59分、+60:00と+60:59は60分、+61以降も残存shellは60分。timer range上限はSTD+60、evaluator/stale上限はSTD+61で互いに異なる |
| T-22 | input insufficiencyとActual非依存 | STD欠落はstate生成不可。route presentationに必要なplanning/TZ欠落はpayload除外・reason log。ATD/ATA欠落・不正値だけでは除外しない |
| T-23 | **state が presentation window から独立していること（INV-016 の dedicated enforcing test）** | `now = STD − 30h`でも `.preReport` / `.preDeparture` を返す。面のvisibilityとstateが独立し、evaluator signatureにwindow入力が無い |
| T-24 | **report lead time が全経路で一致すること** | 同一 leg に対し `NextReportWindowBuilder` の report time と `TimelineSupport` の duty start が **同じ lead を使う**。特に Asia→Asia（`ICN→CGO`）と Europe→Europe で **両経路とも 90 分**になること。Lower48↔Lower48 で両経路とも 60 分 |
| T-25 | **Replacement confirmation UI**（実機 A-3 FAIL を受けて追加） | replacement candidate ありのとき `Confirm Import` が描画されない。確認は `.alert` であり `.confirmationDialog` を使っていない。状態を変える確定操作が 1 回だけ。Alert の message に全 candidate の Trip ID が含まれる。candidate なしのときは `Confirm Import` が描画される |

**T-23 を追加した理由（PM レビュー指摘）**

INV-016（window 定数を state 判定に入れない）は、SWE 提出時点で **dedicated test を持っていなかった**。列挙されていた T-1 / T-10 / T-11 / T-12 / T-17 / T-20 はいずれも window 定数の混入を検出できず、**将来 `T-12h` を state 評価に再導入する回帰が全 test を pass してしまう**。T-23 はその 1 点のみを証明する。

- 実装形態は「state 評価関数に window 定数を渡す引数が存在しない」ことを型で示すのが最良だが、型で示せない場合は本 test を必須とする。
- INV-016 の `Enforced by` 行を **T-23 を主とする**記述に更新すること。

**T-20 の具体仕様（省略不可・2026-08-17 PO revision の核心）**

最初の domicile-departure leg を用意し、legの日時を固定したまま `nowUTC` だけを進める。

| `nowUTC` | 期待 state | 期待semantic表示 |
|---|---|---|
| `report − 1min` | `.preReport` | prefix `Report in`、anchor = report |
| `report`（境界ちょうど） | `.preDeparture` | prefix `Dep in`、anchor = STD |
| `STD − 1min` | `.preDeparture` | prefix `Dep in`、anchor = STD |
| `STD`（境界ちょうど） | `.departureTimePassed` | prefix `Departure time passed`、elapsed minute 0 |
| `STD + 1min` | `.departureTimePassed` | elapsed minute 1 |
| `STD + 60min` | `.departureTimePassed` | elapsed minute 60 |
| `STD + 61min`（境界ちょうど） | `.expired` | 新payloadなし。reconcile実行時はnext legなしならActivity immediate end。未実行なら残存shellは60分表示で停止 |

- evaluatorは `STD+61 → STD → report → preDeparture` の順で評価する。
- elapsedは `floor((nowUTC - STD) / 60)`。+60:59までは60、+61:00でexpired。
- 同一fixtureのATD / ATAだけを変更しても全行の結果が変わらないことを併せてassertする。
- `.inFlight` / `.scheduledArrivalPassed` / `.completed` / STA-based `.stale`、`Arriving in` / `Scheduled Arrival Time Passed` が一度も現れないこと。
- visibleな同一leg遷移はupdateのみ。+61以降をreconcileしたterminal transitionだけがendまたはnext-leg changeを許可する。

その他:

- **T-2 は device timezone を scenario 途中で変更すること**（固定 TZ 2 本の比較では不十分）。
- **T-17 は型による回帰防止である。** stateが4 casesであること、evaluatorにSTA / ATD / ATA / presentation-window入力が無いこと、`reportTimeUTC == nil` の後続legが `.preDeparture` になることをassertする。
- **T-18 / T-19 は §3.8 の 2 モード分離を守る唯一の自動検証**であり、省略不可。ActivityKit 呼び出しは protocol 越しに spy を挿して回数を数えること。
- **T-20 / T-21 はSTD+60/+61とpassed-leg ownershipを固定する自動検証**であり、省略不可。

### Regression Scenarios（実データ）

- **Scenario A — Revised Trip**: `ANC→SGN→ICN→ANC` → `ANC→SGN→ICN→CGO→ICN→ANC`。confirmation 1 回 / transaction 1 回 / Timeline 正 / 旧 DH 5X67 が生存しない / 旧 notification 消滅 / 旧 Live Activity 消滅 / current leg 正 / **iCloud sync 正常維持**
- **Scenario B — 5X68 ANC→SGN**: `Report in` → `Dep in` → `Departure time passed`（minute 0〜60）→ STD+61でevaluator expired。同一legのvisible遷移はActivity updateのみ。suspended中にshellが残ってもelapsedは60でclampし、次のapp executionでendする。countdown anchorはabsolute report/STD、TZ変更でduration不変、ATD/ATAの有無で結果不変、arrival operational copyはゼロ
- **Scenario C — DH KE480 SGN→ICN**: operatingと同一engine / SGN→KoreaのTZ変更でduration不変 / `Delayed`その他Actual推測ゼロ / passed legが+60までcurrent / +61で次legへ遷移。短いturnで次legの`Dep in`が短縮・消失してもaccepted behavior
- **Scenario D — ICN→CGO→ICN**: revised leg が original を置換 / CGO→ICN 完了後に original DH leg が再浮上しない / app restart で obsolete flight を再生成しない / current/next event が revised trip のみから導出

---

## 6. Definition of Done

以下 **すべて** を満たすまで完了扱いにしない。

- [ ] Revised Trip が 1 回の操作で置換できる
- [ ] Replacement confirmation が 1 つだけ（`Confirm Import` と `Replace and Import` が同時に存在しない）
- [ ] Replacement 確認が画面中央の `.alert` で表示され、iPad で popover として anchor されない
- [ ] Alert に置換対象の Trip ID と警告文が含まれる
- [ ] 旧 schedule 由来の Notification が残らない
- [ ] 旧 schedule 由来の Live Activity が残らない
- [ ] Countdown duration が absolute time と一致する
- [ ] Device timezone 変更で duration が変化しない
- [ ] Report Time 前は `Report in` を表示する（Lower48 rule 実装済み）
- [ ] 最初のdomicile departureはreport前に`Report in`、report以降STD前に`Dep in`を表示する
- [ ] 後続legはreportを持たず、STD前は`Dep in`を表示する
- [ ] STD〜STD+60でprefix `Departure time passed`とOS-driven localized elapsed valueを表示する
- [ ] STD+60は表示され、STD+61境界ちょうどでevaluatorは`.expired`となる。実行中または次回app executionのreconcileで旧Activityをendし、suspended中の残存shellは60分から進まない
- [ ] `timerClampUTC = STD+60`と`expirationUTC = staleDate = STD+61`が別のdescriptor/APIとして表現され、count-up rangeが前者を使用する
- [ ] passed legはminute 60までfuture legより優先し、+61で次legへ進む
- [ ] `FlightOperationalState` が4 casesで、`.inFlight` / `.scheduledArrivalPassed` / real-time `.completed` / STA-based `.stale`を持たない
- [ ] evaluator signatureにSTA / ATD / ATA / presentation window入力が無い
- [ ] ATD / ATAの有無・値だけを変えてもstate / status / selection / lifecycleが変化しない
- [ ] `Arriving in` / `Scheduled Arrival Time Passed` / arrival reference operational lineが全surfaceから消えている
- [ ] App Timeline iPhone/iPad、Widget、Live Activityが同じstate / prefix / anchor UTCを消費し、Timeline独自`(-05d 15h 45m)` countdownが残っていない
- [ ] `SystemFormatStyle.Timer`のOS localizationを使用し、formatting目的の毎分Activity update / Swift timer / pollingが無い
- [ ] window定数（T-12h / T-6h）がstate判定に入っていない
- [ ] 同一 leg の state 遷移で Live Activity を end/create せず update している
- [ ] Trip Replacement 時のみ destructive rebuild が行われる
- [ ] actual stateをreal-time operational pathへ入力せず、schedule factだけを`.departureTimePassed`として表示する
- [ ] 判定入力が欠けている leg は operational state を生成せず、current leg 候補から除外され、表示面に何も出さない（`.unknown` state を作っていない）
- [ ] 入力欠落が log に残り、サイレントに握り潰されていない
- [ ] App restart 後も正しい current leg / state を再構築する
- [ ] Commercial DH でも同じ time engine を使用する
- [ ] report lead time を計算する箇所がアプリ全体で 1 つだけであり、Asia/Europe regional が 90 分になっている
- [ ] Route graphic が wrap しない
- [ ] Connection Card が device 幅によって不自然に wrap しない
- [ ] 既存 iCloud sync behavior を壊さない
- [ ] PO revision後のauthoritative T-1〜T-24へtestsを同期し、T-25以降の非関連coverageを維持する
- [ ] 実機で iPhone + iPad を確認

---

## 7. SWE への指示（作業順序）

1. **本書 §2 の RCA を自分で検証してから着手すること。** PM の読みと実装の実態が食い違う場合は、実装せずに PM へ report（AGENTS.md「code と docs が食い違う場合は報告」）
2. Phase 0（INVARIANTS / ADR）を先に PR に載せる。state model のレビューを通してから実装に入る
3. Phase 1 → 2 → 3 の順。**Phase 1 と 2 を 1 つの PR に混ぜない**（回帰時の切り分けが不能になる）
4. Phase 4 は Phase 1-3 の merge 後
5. Phase 5 は着手しない（P0 完了後に PM が判断）
6. 各 Phase で対応する T-xx を同一 PR に含める。test なしの実装 PR は受け付けない
7. commit / push / release は別作業。指示があるまで行わない

### 明示的な禁止事項

- 症状ごとの個別 patch（例: `Delayed` の文字列だけ差し替える、Live Activity を起動時に決め打ちで end する）
- `depUTC` / `arrUTC` を countdown / state 判定に使うこと
- operating と DH で計算経路を分けること
- 既存の単一文字列 `blockAndConnectionText` を残したまま新 API を追加すること（並行実装禁止）
- 時間経過を根拠に actual state を推測すること
- real-time operational evaluator / selection / lifecycleへSTA / ATD / ATAを入力すること
- `.inFlight` / `.scheduledArrivalPassed` / real-time `.completed` / STA-based `.stale`を残すこと
- `Arriving in` / `Scheduled Arrival Time Passed` / arrival reference operational lineを残すこと
- exact order `STD+61 → STD → report → preDeparture` を並べ替えること
- `.departureTimePassed`をactual departureの証拠として扱うこと
- non-expired `.departureTimePassed`をfuture legで早期に置換すること
- localized elapsed copyを固定するために毎分`Activity.update()` / Swift timer / pollingを導入すること
- App Timelineの独自countdown APIを共通payloadと並行して残すこと
- `T-12h` / `T-6h` 等の window 定数を `FlightOperationalState` の判定に持ち込むこと
- 通常の `refresh` で Live Activity を無条件に end/request し直すこと（destructive rebuild は replacement 専用）

---

## 8. 未決事項（PM が引き取る）

| # | 項目 | 状態 |
|---|---|---|
| 1 | Lower 48 判定のデータ源（IATA → region table を新設するか、既存 TZ resolver から導出するか） | SWE から実装可能性の報告を受けて PM が決定 |
| 2 | Asia / Europe regional の 1h report rule | 今 Build 対象外。次 Build で仕様化 |
| 3 | `Pick up in` 表示 | 今 Build 未実装。次 Build |
| 4 | In-Flight Progress UI | P0 完了後に判断 |

> 旧「信頼できる in-progress 認識の定義」とATD-driven `.inFlight` contractは2026-08-17 Product Owner revisionでretired。trustworthy real-time sourceを将来追加する場合は別Build＋新規ADRで扱う。
