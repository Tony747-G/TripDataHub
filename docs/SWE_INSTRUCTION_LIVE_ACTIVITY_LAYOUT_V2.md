# SWE 実装指示 — Live Activity レイアウト刷新と status 表記の変更

- 種別: Phase 4 の追加変更（UI ＋ status 文字列）
- 実機の Lock Screen 表示を見た Tony の判断による差し替え
- commit / stage / push は行わない

---

## 1. 新レイアウト

```
Flight: D901

Aug 16 (Sun)                    Aug 17 (Mon)
ANC 16:13          ✈           ICN 17:33

Report in 3hr 15min
```

現行は日付が route 行の**下**にあるが、これを**上**へ移し、各空港の真上に配置する。中央は `→` ではなく**飛行機アイコン**。

### 構成

| 行 | 内容 | 揃え |
|---|---|---|
| 1 | `Flight: <便名>` | 左 |
| 2 | 出発日 / 到着日 | 左端 / 右端 |
| 3 | `ANC 16:13` / アイコン / `ICN 17:33` | 左端 / 中央 / 右端 |
| 4 | status（`Report in 3hr 15min` 等） | 左 |

- 日付書式は現行の `MMM d (EEE)` を維持（`Aug 16 (Sun)`）
- 2 行目の日付は 3 行目の対応する空港カラムと**左右の揃えを一致**させる

---

## 2. 飛行機アイコンの実装条件（必須）

**元の wrap バグを再発させないこと。** 当時の実装はこうだった。

```swift
HStack(spacing: 8) {
    Text("\(dep) \(depTime)")
    Spacer(minLength: 0)
    Text("・・・✈・・・")        // ← 約 7 文字幅の装飾文字列
    Spacer(minLength: 0)
    Text("\(arr) \(arrTime)")
}
```

原因は「装飾文字列の幅」＋「`minLength: 0` の Spacer 2 個」＋「`lineLimit` なし」の組み合わせであり、**飛行機そのものではない**。したがって以下を守れば安全に置ける。

- **SF Symbol を使う**（`airplane` 等）。`・・・✈・・・` のような文字列装飾は禁止
- アイコンに **固定 frame を与える**。テキストカラムを押し出さないこと
- テキスト 4 つ（日付 2 ＋ 空港時刻 2）すべてに **`lineLimit(1)` ＋ `minimumScaleFactor` ＋ `allowsTightening`**
- 幅が不足したときに**縮むのはテキスト側**。アイコンは固定
- `Spacer` を使う場合は `minLength` に実値を与える
- **進行方向が左→右に読める向き**にすること

---

## 3. status 表記を `HHhr MMmin` に変更（実装方式は SWE 調査により確定）

現行は `Text(timerInterval:countsDown:)` による `H:MM:SS`。Lock Screen では秒が `––` で描画され、`Report in 3:15:––` という未完成に見える表示になっている。

**新表記**

```
Report in 3hr 15min
```

秒は表示しない。`.scheduledArrivalPassed` の経過時間も同様。

### 採用する実装

**WidgetKit 実描画調査により `SystemFormatStyle.Timer` の minute precision を採用する。**

```swift
// 残り時間（Report in / Dep in / Arriving in）
Text(.currentDate,
     format: .timer(countingDownIn: Date.distantPast..<targetDate,
                    showsHours: true,
                    maxFieldCount: 2,
                    maxPrecision: .seconds(60)))

// 経過時間（Scheduled Arrival Time Passed）
Text(.currentDate,
     format: .timer(countingUpIn: plannedArrivalUTC..<staleDate,
                    showsHours: true,
                    maxFieldCount: 2,
                    maxPrecision: .seconds(60)))
```

- **OS が自動更新する。** アプリがバックグラウンドでも値が凍結しない
- `maxPrecision: .seconds(60)` により秒を表示せず、分境界で system-driven 更新する
- **分境界スケジューラの追加は不要。** `staleDate` を freshness 用に短縮する必要もない
- 既存の `staleDate = plannedArrivalUTC + 1h` は **operational lifecycle 用としてそのまま維持**する
- countdown target は既存の absolute UTC instant を変更せず、そのまま interval の境界に使う

### 却下した方式（記録）

- **計算文字列 ＋ 毎分更新**: iOS のバックグラウンドアプリは Live Activity を毎分更新できない。アプリを開かない限り値が凍結し、「アプリを開かずチラ見する」という運航中の主要な使い方で精度が落ちる。**Build Week が潰した症状の再導入になるため不採用**
- **`Text(date, style: .relative)`**: 自動更新は保証されるが、**1 時間未満で秒が出る**（`11 min, 13 sec`）ため「秒を消す」を満たさない。加えて duration だけが device locale に追従し、英語の接頭辞と混在する
- **`TimeDataSource.dateRange` ＋ `Date.ComponentsFormatStyle`**: 通常の SwiftUI formatter テストでは値を生成できるが、WidgetKit Live Activity では `--hr --min` の dash redaction が再現した。locale、static/inline、style、fields を変えても解消しないため不採用

---

## 3-B. deployment target を iOS 18 へ引き上げる（Tony 承認済み）

`SystemFormatStyle.Timer` は iOS 18+ である。**iOS 17 fallback は持たず、deployment target 18.0 の単一経路にする**方針を Tony が選択した。

### 作業

- `project.yml` の `IPHONEOS_DEPLOYMENT_TARGET: "17.0"` → `"18.0"`
- XcodeGen で `.xcodeproj` を再生成（pbxproj 内の 2 箇所が追随することを確認）
- **app 本体・widget extension・share action extension のすべて**が 18.0 になっていること
- `@available` / `if #available(iOS 18, *)` による分岐を新コードに入れないこと

### 制約

- **これは release-affecting change である。** iOS 17 のままの利用者は以降の更新を受け取れなくなる
- iOS 17 fallback は追加しない。target 引き上げと新表記の実装以外の availability 整理は行わない
- **commit を分けること。** target 引き上げは独立した commit にし、レイアウト変更と混ぜない
- テスト・ビルドに使う Simulator を iOS 18 以降に揃えること

最低対応 OS を iOS 18.0 とすることは Product decision として確定済み。iOS 17 fallback の追加や target の再引き下げは本変更の対象外。

---

## 4. テスト

### T-14 更新（既存を書き換え）

- 対象を新レイアウトに差し替え
- **行数が常に 4 行**であること（幅によって増減しない）
- iPhone / iPhone Pro Max / iPad 相当の 3 幅で**レンダリング高さが一致**すること
- **飛行機アイコンを含む構成で測ること。** これが「アイコンを置いてよい」根拠になる
- 日付行と route 行の左右の揃えが一致していること

### T-50S（Live Activity system-timer syntax guard）

自動テストは `LiveActivityOperationalStatusView` のソース範囲だけを読み、既知の redaction 経路へ戻らないことを検証する。これはレンダリング結果の検証ではなく、構文回帰ガードである。

- `Text(timerInterval:` / `.components(style:` / `.dateRange(` / `style: .relative` / `style: .timer` が Live Activity 本体にない
- `.timer(countingDownIn:` と `.timer(countingUpIn:` が存在する
- `LegacyOperationalStatusView` は検査範囲外とする

実レンダリングは `DEVICE_VERIFICATION_CHECKLIST.md` D-7 の device-only acceptance とする。timer contract（`maxFieldCount == 2`、`maxPrecision == 60s`、UTC interval 境界）は別の補助テストで固定する。

### 既存テストの維持

T-15（iPhone / iPad で同一 Connection card 構成）は変更しない。Timeline の Connection card は本変更の対象外。

---

## 5. 変更してはいけないもの

- `FlightOperationalState` の評価順序・境界
- `OperationalStateBuilder` の current leg 選択
- import fingerprint ledger / queue / transaction 境界
- browser popup lifecycle / focus acquisition
- Timeline の Connection card レイアウト（T-15 の対象）
- **status の文言そのもの**（`Report in` / `Dep in` / `Scheduled Departure Time Passed` / `Arriving in` / `Scheduled Arrival Time Passed`）。変えるのは**時間の書式だけ**

---

## 6. 適用範囲

- Lock Screen Live Activity
- Dynamic Island expanded
- compact / minimal は幅が足りないため**対象外**。現行のまま

**Home Screen Widget は現状維持（PM 承認済み）。** `.widget` と `.liveActivity` は `FlightPresentationPolicy.visibility` の排他値であり同時に表示されないため、書式が異なっても利用者が並べて見ることはない。T-14 の 3 幅は Live Activity 用であり Widget の安全性は証明しない。

ただし条件が 2 つある。

1. `OperationalStatusView` の分離は「たまたま分かれた」ではなく、**`.widget` / `.liveActivity` という明示的な presentation style として実装し、その意図をコメントに残す**こと。でないと次の担当者が「統一されていない」と判断して片方を壊す
2. **Widget の status 書式が未整合であることを follow-up として記録**する（Print Preview readiness と同じ扱い）

---

## 7. 報告時に含めること

- 3 幅でのスクリーンショット（アイコンあり）
- T-14、T-50S、および D-7 の WidgetKit / ActivityKit 実描画結果と全ユニットテスト結果
- `staleDate` をどう設定したか、分境界更新をどこから駆動したか
- `git diff --check` と staging が空であること

stage / commit / push は行わない。
