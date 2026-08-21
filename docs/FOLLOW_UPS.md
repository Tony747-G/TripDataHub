# TDH — Follow-up register

Build Week 中に「意図的に今はやらない」と判断した項目の一覧。**判断済みであることが重要**であり、未検討の TODO とは区別する。

各項目は「何を」「なぜ今やらないか」「いつ再評価するか」の 3 点を持つ。再評価の条件が来たら PM が判断する。

| 状態 | 意味 |
|---|---|
| `deferred` | 判断済み。現状維持。再評価条件が来るまで触らない |
| `open` | 判断待ち。PM が結論を出す必要がある |

---

## F-1. duration 表記の 2 系統併存

**状態**: `deferred`（2026-08-17 Tony 判断）

現状:

| サーフェス | 生成元 | 文字列 |
|---|---|---|
| アプリ内 Timeline | `FlightCountdownSharedStore.durationText`（自前組立） | `Report in 3hr 29min` |
| Lock Screen / DI expanded | OS 描画（`SystemFormatStyle.Timer`） | `Report in 3 hours, 29 minutes` |

**値の意味は一致している。** Timeline と Live Activity は同時に見えるため、利用者は両表記を並べて目にする。

**今やらない理由**:

1. Live Activity 側を `3hr 29min` に寄せるには自前文字列へ戻すことになり、**dash redaction と値凍結を再発させた実装そのもの**に戻る。P0 の成果を捨てることになる
2. Timeline 側を `3 hours, 29 minutes` に寄せると、Timeline は横幅が狭いため、現行 STD-only contract の stress case `Departure time passed 60 minutes` で折り返しリスクが高い。D-6 の回帰を作りかねない
3. 運航上どちらも誤読しない。原則「Incorrect operational information is worse than no information」に照らして、情報の正しさは損なわれていない

**再評価条件**: 利用者から可読性の指摘が出たとき、または Timeline のレイアウトを別件で作り直すとき。

**関連**: `DEVICE_VERIFICATION_CHECKLIST.md` D-7 の注記。**表記差を NG に上げないこと**が両検証票に明記済み。

---

## F-2. Widget の status 書式が Live Activity と未整合

**状態**: `deferred`

Home Screen Widget と DI compact / minimal は `LegacyOperationalStatusView` で `H:MM:SS`（秒あり）を描画する。Live Activity（Lock Screen / DI expanded）は分精度。

**今やらない理由**: `FlightPresentationPolicy.visibility` により `.widget` と `.liveActivity` は**排他**であり、利用者が並べて見ることはない。Widget 側のレイアウト安全性は T-14 の 3 幅検証の対象外で、変更すると別の回帰確認が必要になる。

**再評価条件**: Widget のレイアウトを別件で触るとき、または `FlightPresentationPolicy` の排他性が崩れるとき。

**関連**: `SWE_INSTRUCTION_LIVE_ACTIVITY_LAYOUT_V2.md` §6 条件 2。

---

## F-3. Dynamic Island expanded の nightly XCUITest

**状態**: `KEEP DEFERRED`（nightly automation は non-gating）

D-7 の自動化は 3 方式すべてで不成立と確定した。ただし **Lock Screen を諦め Dynamic Island expanded を使う**経路だけは潰しきれていない。expanded は同じ WidgetKit extension プロセスで `LiveActivityOperationalStatusView` を描画するため、redaction が起きるなら同じく起きる。

構成案: `XCUIApplication(bundleIdentifier: "com.apple.springboard")` から座標長押しで展開 → `xcrun simctl io booted screenshot` → OCR。分境界は固定 UTC を注入できないので**実時間 60 秒待って値の変化を assert** する。

**今やらない理由**: Dynamic Island expanded を安定して開く公開 API / accessibility path がなく、座標だけに依存する操作は脆い。実行時間も 70 秒を超え、CI gate として信頼できない。手動の production-path ActivityKit / SpringBoard D-series acceptance が authoritative runtime evidence として完了しているため、この automation は nightly の補助証拠に限られる。

**再評価条件**: nightly automation への投資が、保守コストと脆弱性を上回る価値を持つと判断されたとき。実装する場合も acceptance gate ではなく、失敗時に人間が確認する non-gating artifact collector とする。

**関連**: `SWE_INSTRUCTION_IOS18_BASELINE_AND_T50.md` §B-1 / `PM Resolution`。

---

## F-4. CI: `CODE_SIGNING_ALLOWED=NO` で test host が起動前クラッシュ

**状態**: `KEEP DEFERRED`

app-hosted unit test bundle を `CODE_SIGNING_ALLOWED=NO` で回すと、Simulator entitlement の生成・埋め込みが無効になり、CloudKit が必要な simulated entitlements なしで初期化される。その結果、XCTest が接続する前に TripDataHub が落ちる。通常の署名付き Simulator 構成、および Release / TestFlight は影響を受けない。

**今やらない理由**: 現在は署名付き構成で回っており、検証は成立している。future CI では app-hosted tests に通常の local Simulator signing を使用する。Release signing や production behavior を変更する問題ではない。

**再評価条件**: **CI を組む段で必ず刺さる。** その時点で対処する。

**2026-08-17 追記 — 影響はテストホストに限らない**

entitlement を持たないビルドは、**通常の cold launch でも起動時に落ちる。**

```
In order to use CloudKit, your process must have a
com.apple.developer.icloud-services entitlement.
→ CKContainer.__allocating_init(identifier:) → EXC_BREAKPOINT / SIGTRAP
  AppViewModel.syncProfileWithCloudKit()  (AppViewModel.swift:7438)
```

`CKContainer(identifier:)` は entitlement 欠落時にハードトラップする。1.2.26 (84) の Simulator ビルドで実際に発生し、Priority 3 の C-6 を 1 度ブロックした。

**2026-08-17 追記 — Simulator ビルドの entitlement 確認方法（重要）**

`codesign -d --entitlements :-` は **Simulator ビルドでは空の dict を返す。これは異常ではない。** Xcode 26 の Simulator ビルドは entitlements を署名 blob ではなく **実行ファイルの `__TEXT,__entitlements` セクション**に Simulated entitlements として埋め込む。

| ビルド | codesign entitlements | Mach-O `__TEXT,__entitlements` |
|---|---|---|
| 1.2.27 (85) 正常 | 空 dict | **存在**（0x2e2）。`com.apple.developer.icloud-services = [CloudKit]` を含む |
| 1.2.26 (84) 破損 | 無し | **無し** |

**Simulator ビルドの正しい確認手順**:

1. `<Build>/TripDataHub.app-Simulated.xcent` の内容を見る
2. 実行ファイルの `__TEXT,__entitlements` セクションの有無とサイズを見る
3. `codesign -d --entitlements :-` の結果で判断しない

**関連**: `SIMULATOR_TROUBLESHOOTING.md`。

---

## F-5. Print Preview readiness の文言

**状態**: `DEFER — needs typed readiness state machine`

現在の状態は同義ではない。

```
navigationLoaded != pdfAvailable != previewReady
```

navigation 完了後に非同期 status が更新されるため、より新しい readiness 表示を stale な navigation status が上書きすることが構造上あり得る。一方、無効な import action 自体は guard されており、単純な文言差し替えだけでは状態契約を正しく表せない。

**今やらない理由**: typed readiness state machine と、非同期 event の優先順位を定義する必要がある。TestFlight 直前の wording patch では閉じない。

**再評価条件**: browser / import の状態機械を別件で改修するとき。

**関連**: T-36〜T-40。

---

## F-6. HISTORICAL / RETIRED — Phase 5 In-Flight Progress

**状態**: `RETIRED`

Build Week 当初の、schedule経過から in-flight progress を表現する提案。2026-08-17 の Product Owner decisionにより、信頼できない時間経過から `Departed` / `In flight` / `Arriving` / `Arrived` を推測しない STD-only contractへ置換された。現行product instructionとして実装してはならない。

**再評価条件**: **trustworthy realtime source**、そのsourceとoperational semanticsを定義する**new ADR**、および**explicit PO approval**の3点がすべて揃ったとき。それまでは再開しない。

---

## F-7. XcodeGen 世代差分がビルドのたびに再発する

**状態**: `DEFER — needs standalone XcodeGen reproducibility project`

last reproducible point は commit `49f3167`。その時点では XcodeGen 2.46.0 の正規 wrapper invocation で生成差分が 0 になる。現在の checked-in project は、その後の XcodeGen 出力と Xcode 26 normalization が混在する hybrid baseline で、`project.yml` と現行 invocation だけから再現できない。

```
LastUpgradeCheck 1430 → 2660 / xcscheme LastUpgradeVersion 2650 → 2660
+ ENABLE_USER_SCRIPT_SANDBOXING = YES  /  + STRING_CATALOG_GENERATE_SYMBOLS = YES
lastKnownFileType → explicitFileType（全 product）
INFOPLIST_KEY_UIAppFonts / UISupportedInterfaceOrientations（_iPad）: 配列 → 単一文字列
```

一時 copy での再生成では、現行 baseline に対して wrapper invocation でも pbxproj に意味差分が発生し、bare `xcodegen generate` では shared scheme にも追加差分が発生した。したがって TestFlight 前は **checked-in `.xcodeproj` を Release source of truth とし、再生成しない。**

**今やらない理由**: 恒久対応には XcodeGen version の pin、generation wrapper、spec ownership、Xcode post-generation normalization、CI diff gate を一つの再現性プロジェクトとして決める必要がある。release 直前の surgical fix に収まらない。

**再評価条件**: standalone XcodeGen reproducibility project を着手するとき。CI を組むとき、または XcodeGen を次に更新するときが契機になる。

---

## F-8. `Info.plist` と `INFOPLIST_KEY_*` の二重管理

**状態**: `PASS`

checked-in の `TripDataHub/Info.plist` と `project.yml` の `INFOPLIST_KEY_*` build settings が**両方存在し、Xcode が merge している**。

`UIAppFonts` で顕在化した:

| 由来 | 値 | 生きているか |
|---|---|---|
| `TripDataHub/Info.plist` | `MaterialIcons.ttf` | **生きている** |
| `project.yml` → `INFOPLIST_KEY_UIAppFonts` | `Resources/Fonts/MaterialIcons.ttf` | **dead（実測確認済み）** |

根拠: `project.pbxproj` の `MaterialIcons.ttf` は **PBXGroup（`path = Fonts`）配下の通常ファイル参照**であり folder reference ではない。Resources build phase でコピーされると **bundle 直下に平置き**される。

**2026-08-17 archive で実測確認済み:**

```
TripDataHub.app/MaterialIcons.ttf        存在（356,840 bytes）
TripDataHub.app/Resources/Fonts/         存在しない
archive 内の MaterialIcons.ttf           上記 1 件のみ
```

したがって **`project.yml` の `INFOPLIST_KEY_UIAppFonts` 側は解決していない dead entry** である。正規化する場合に消すのはこちら。`Info.plist` の `MaterialIcons.ttf` は**消してはならない**。

`UISupportedInterfaceOrientations` は両者の文字列が一致するため merge 後に dedup され、4 値のまま問題が出ていない。**たまたま噛み合っているだけ**である。

**完了内容**: dead path だけを削除した。

- `project.yml`: dead `INFOPLIST_KEY_UIAppFonts` declaration を削除
- `TripDataHub/Info.plist`: `Resources/Fonts/MaterialIcons.ttf` を削除し、live `MaterialIcons.ttf` を維持
- checked-in `project.pbxproj`: 対応する Debug / Release の 2 行だけを surgical に削除

Release artifact では `MaterialIcons.ttf` が bundle root に exactly once 存在し、`Resources/Fonts/` は存在しない。source / bundle SHA-256 は一致し、Timeline の Material Icons は tofu・blank・fallback なしで実描画 PASS。Release app / Widget / Share extension build も PASS。

orientation 等の他の Info.plist / build-setting 二重管理はこの font registration cleanup の対象外であり、F-7 の reproducibility project と混同しない。

---

## F-9. Home Screen Widget active visual acceptance

**状態**: `PASS`

canonical fixture（`DEBUG-ANC-ICN-ANC` / `STD = now + 5h`）を変更せず、DEBUG-only の `homeWidgetPreReport` scenario（`STD = now + 9h`）を追加して production WidgetKit / SpringBoard 経路を検証した。

**実画面 acceptance**:

| family | Light | Dark |
|---|---|---|
| `systemSmall` | PASS | PASS |
| `systemMedium` | PASS | PASS |

`systemSmall` は family-aware な 2 行構成（semantic prefix / system timer）とし、`systemMedium` は 1 行を維持した。flight / route identity、approved prefix、hours / minutes、minute precision、contrast が可読で、ellipsis・秒・dash・blank・clipping はない。shared descriptor、wording、timer semantics は変更していない。

---

## 未 commit の docs 差分について

`DEVICE_VERIFICATION_CHECKLIST.md`（commit 3 に既収録）への期待値修正と、本ファイル・`SWE_INSTRUCTION_PRIORITY2_SIMULATOR_TRIAGE.md` の新規追加は、**Priority 2 の実機検証結果を反映してから docs-only commit にまとめる**（2026-08-17 Tony 判断）。

`docs/PRIORITY2_TALLY_SHEET.md` は PM 管理の記入票。commit するかは検証完了後に判断する。
