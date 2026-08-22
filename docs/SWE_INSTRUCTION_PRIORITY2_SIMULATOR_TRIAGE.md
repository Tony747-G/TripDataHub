# SWE 実施指示 — Priority 2 Simulator triage（D-1〜D-7）

> **HISTORICAL / SUPERSEDED (2026-08-20)**
>
> This file records the original 2026-08-17 triage procedure; it is not the current acceptance instruction. Later PO decisions replaced arrival-driven realtime states with the four-state STD-only contract, approved production-path Simulator ActivityKit/SpringBoard evidence for D-series, and closed D-series as PASS after timer-clamp and Dynamic Island layout reacceptance. Authentic `Trip_12165.pdf` established `Block: 02:48` and `Connection at CGO: 2:26`; the `02:44` / `2:31` values below are retired historical expectations. Home Screen Widget visual acceptance remains F-9 deferred.

- 対象 commit: `953d8ba`（build-week/operational-reliability・push 済み）
- 種別: **検証のみ。production code を変更しない**
- commit / stage / push は行わない

---

## 0. この作業の位置づけ（誤読防止・必ず読むこと）

**これは acceptance ではない。triage である。**

`DEVICE_VERIFICATION_CHECKLIST.md` D-0 のとおり、Simulator の PASS は実機 Acceptance の代替にならない。本作業の目的は **Tony が実機時間を使う前に NG を安く先出しすること**であり、Priority 2 を閉じることではない。

したがって:

- **PASS しても Priority 2 は完了しない。** 「Simulator triage PASS」としてのみ報告する
- **FAIL したら価値が最大。** その時点で止めて報告する。実機を待たずに RCA へ入れる
- 報告に「D-1 OK」等と書くときは、**必ず `(sim)` を付ける**こと。実機結果と混ざると D-0 で潰した取り違えが復活する

---

## 1. 環境

| 幅 | Simulator | 備考 |
|---|---|---|
| iPhone | iPhone 16 | Dynamic Island あり |
| iPhone Pro Max | iPhone 16 Pro Max | 同上 |
| iPad | iPad Pro 13-inch (M4) | **Dynamic Island なし**。Lock Screen Live Activity のみ |

- iOS 18 以降の runtime を使うこと（deployment target 18.0）
- 各 Simulator は起動時に一度 `Erase All Content and Settings` しなくてよい。既存状態で構わない

---

## 2. 手順

### 2-1. fixture 起動

1. アプリを起動し、Settings → DEBUG fixture を起動（`DEBUG-ANC-ICN-ANC`）
2. 起動直後の状態が `.preReport` であること（`Report in ...`）を確認
3. **Live Activity が出ない場合**は `FlightPresentationPolicy` の window 外である可能性がある。fixture は `STD = now + 5h` なので `.liveActivity`（T-6h 以内）に入るはず。入らなければ**その時点で NG として報告**

### 2-2. Lock Screen

- Simulator メニュー `Device → Lock`（⌘L）でロック
- Live Activity が Lock Screen に出ることを確認

### 2-3. Dynamic Island expanded

- ホーム画面に戻り、Dynamic Island を**長押し**して expanded を開く
- **compact / minimal を expanded の代用にしないこと**

### 2-4. cleanup

- 確認終了後、fixture の停止入口から Live Activity を end する
- 次の Simulator へ移る前に必ず実施すること（居座った Activity が次の観測を汚す）

---

## 3. 確認項目

### 3-1. レイアウト（D-1 系 / D-2 系）

期待する形:

```
Flight: D901

Aug 16 (Sun)                    Aug 17 (Mon)
ANC 16:13          ✈           ICN 17:33

Report in 3 hours, 15 minutes
```

| # | 確認内容 | iPhone LS | iPhone DI | ProMax LS | ProMax DI | iPad LS |
|---|---|---|---|---|---|---|
| D-1 | 常に 4 行。増えない・減らない | | | | | |
| D-1b | 日付が空港の真上。左端 / 右端で揃う | | | | | |
| D-1c | 4 テキストとも 1 行。折り返さない | | | | | |
| D-2 | 中央は SF Symbol の飛行機 1 個のみ | | | | | |
| D-2b | 飛行機が左→右の向き | | | | | |
| D-2c | 幅不足時に縮むのはテキスト側。アイコンは不変 | | | | | |

**D-6 併記**: iOS の文字サイズを最大にして D-1 / D-1c を再確認。

**旧仕様で判定しないこと。** 「route が 1 行」「飛行機アイコンがない」は v2 で意図的に覆した旧 D-1 / D-2 である。

### 3-2. 実描画（D-7 系）

| # | サーフェス | 確認内容 | 期待 |
|---|---|---|---|
| D-7a | Lock Screen | `Report in` の数値部 | `3 hours, 15 minutes` の形。`--` / `–` / `––` / 空欄 / placeholder が**出ない** |
| D-7b | DI expanded | 同上 | Lock Screen と**同じ値** |
| D-7c | Lock Screen | 分境界をまたぐまで画面を見たまま待つ（最大 60 秒） | **アプリを開かず・`Activity.update()` なしで**値が 1 減る |
| D-7d | Lock Screen | アプリを background にしたまま 10 分以上放置 | 値が正しく進んでいる。凍結しない |
| D-7g | Lock Screen / DI expanded | 秒 | **表示されない** |

**D-7c / D-7d が本項目の中核。** 秒が消えていることだけで PASS にしないこと。`SystemFormatStyle.Timer` を採用した根拠は「OS が自動更新するので値が凍結しない」であり、そこを見なければ根拠が未検証のまま残る。

### 3-3. Connection card 回帰（D-3〜D-5）

Timeline の `ICN-CGO` leg。**Live Activity のレイアウト規則で判定しないこと。別物である。**

| # | 確認内容 | iPhone | ProMax | iPad |
|---|---|---|---|---|
| D-3 | `Block: 02:44` / `Connection at CGO: 2:31` の 2 行 | | | |
| D-4 | 両方右揃え。`/` 連結の 1 行になっていない | | | |
| D-5 | iPad も同じ 2 行構造 | | | |

---

## 4. Simulator では確認できない項目（実施しない）

以下は **実機のみ**。Simulator で代替したり、無理に通したりしないこと。

| # | 内容 | 理由 |
|---|---|---|
| D-7e | device TZ 変更で duration が変わらないこと | Simulator は Settings に Date & Time を持たず、host mac の TZ 変更が確実に伝播しない。**過去に検証済みで信頼できない** |
| D-7f の `Arriving in` | airborne 状態 | ATD が必要。地上で作れない |
| D-7f の `Scheduled Arrival Time Passed` | STA 経過 | 同上 |

`Dep in` は fixture の report time を通過させれば到達し得るが、**壁時計を進める操作（device clock の人為的前倒し）は禁止**。到達しなければ「未到達」と報告すること。

---

## 5. NG に上げてはいけないもの

| 事象 | 理由 |
|---|---|
| **DI compact / minimal で秒が出る** | `LegacyOperationalStatusView` 描画。対象外・仕様どおり |
| **Home Screen Widget で秒が出る** | 同上。`FlightPresentationPolicy` により Live Activity と同時に出ない |
| **アプリ内 Timeline が `3hr 15min`、Live Activity が `3 hours, 15 minutes`** | **表記が 2 系統あるのが現状の実装。** アプリ内は `FlightCountdownSharedStore.durationText` の自前文字列、Live Activity は OS 描画。統一の要否は PM follow-up として別途判断中。**表記差を NG に上げない** |
| fixture が Timeline に永続しない / iPad に同期しない / 再起動で消える | in-memory・非永続。意図した安全性 |
| iPad に Dynamic Island がない | ハードウェア仕様 |

---

## 6. NG が出たときの手順

**最初の確定 NG でそこで停止し、残りを消化しない。**

1. item ID を記録（例: `D-1c (sim, iPhone 16, Lock Screen)`）
2. **観測値と期待値を並べて**書く
3. スクリーンショット（可能なら画面収録）
4. Console のログを保存。`[FlightCountdown]` / `[Activity]` 系を優先
5. その時点の便名 / STD / STA / fixture 起動からの経過時間
6. **報告してから RCA に入る。** 証拠を出す前に原因推定を書き始めないこと

---

## 7. 報告フォーマット

```
Priority 2 Simulator Triage Result: PASS / FAIL

Environment:
- iPhone 16          / iOS ____
- iPhone 16 Pro Max  / iOS ____
- iPad Pro 13 (M4)   / iOS ____

Layout (sim):
D-1:   D-1b:   D-1c:
D-2:   D-2b:   D-2c:
D-6:

Rendering (sim):
D-7a:   D-7b:   D-7c:   D-7d:   D-7g:

Connection card (sim):
D-3:   D-4:   D-5:

Not run (device-only):
D-7e:  device-only
D-7f (Arriving in / STA passed):  実運航待ち

First failure, if any:
  Item:
  Observed:
  Expected:
  Evidence:
```

**全項目 PASS の場合の結び方（この文言をそのまま使うこと）**

```
Simulator triage PASS. This does NOT close Priority 2.
Device acceptance on iPhone / iPhone Pro Max / iPad remains required.
```

---

## 8. 変更してはいけないもの

- **production code 全般。** 本作業は検証のみ
- `LiveActivityOperationalStatusView` / `FlightCountdownLiveActivityTimerContract` / `FlightCountdownExpandedLayoutView`
- `FlightOperationalState` の評価順序・境界（INV-018）
- `FlightPresentationPolicy` の window
- `FlightCountdownSharedStore.durationText`（表記統一は PM 判断待ち。**先回りして直さないこと**）
- import fingerprint ledger / queue semantics / transaction 境界
- `docs/PRIORITY2_TALLY_SHEET.md`（PM 管理の記入票。SWE は編集しない）

**表示を「直したくなった」場合は実装せず PM へ報告すること。** 検証中に production を触ると、その回の観測結果がすべて無効になる。
