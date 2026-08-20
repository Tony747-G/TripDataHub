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

**状態**: `deferred`（nightly automation は non-gating）

D-7 の自動化は 3 方式すべてで不成立と確定した。ただし **Lock Screen を諦め Dynamic Island expanded を使う**経路だけは潰しきれていない。expanded は同じ WidgetKit extension プロセスで `LiveActivityOperationalStatusView` を描画するため、redaction が起きるなら同じく起きる。

構成案: `XCUIApplication(bundleIdentifier: "com.apple.springboard")` から座標長押しで展開 → `xcrun simctl io booted screenshot` → OCR。分境界は固定 UTC を注入できないので**実時間 60 秒待って値の変化を assert** する。

**今やらない理由**: 実行時間 70 秒超・SpringBoard 座標依存で脆く、CI gate として信頼できない。手動の production-path ActivityKit / SpringBoard acceptance は完了しており、この automation は nightly の補助証拠に限られる。

**再評価条件**: nightly automation への投資が、保守コストと脆弱性を上回る価値を持つと判断されたとき。実装する場合も non-gating とする。

**関連**: `SWE_INSTRUCTION_IOS18_BASELINE_AND_T50.md` §B-1 / `PM Resolution`。

---

## F-4. CI: `CODE_SIGNING_ALLOWED=NO` で test host が起動前クラッシュ

**状態**: `deferred`

app-hosted unit test bundle を `CODE_SIGNING_ALLOWED=NO` で回すと、CloudKit が必要な simulated entitlements なしで初期化され、XCTest が接続する前に TripDataHub が落ちる。通常の署名付き Simulator 構成では 499 tests が通る。

**今やらない理由**: 現在は署名付き構成で回っており、検証は成立している。急がない。

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

**状態**: `deferred`

**再評価条件**: browser / import 周りを別件で触るとき。

**関連**: T-36〜T-40。

---

## F-6. HISTORICAL / RETIRED — Phase 5 In-Flight Progress

**状態**: `deferred`（旧 scheduled/in-flight progress proposal は retired）

Build Week 当初の、schedule経過から in-flight progress を表現する提案。2026-08-17 の Product Owner decisionにより、信頼できない時間経過から `Departed` / `In flight` / `Arriving` / `Arrived` を推測しない STD-only contractへ置換された。現行product instructionとして実装してはならない。

**再評価条件**: **trustworthy realtime source**、そのsourceとoperational semanticsを定義する**new ADR**、および**explicit PO approval**の3点がすべて揃ったとき。それまでは再開しない。

---

## F-7. XcodeGen 世代差分がビルドのたびに再発する

**状態**: `deferred`

`project.yml` を変えていなくても、XcodeGen 2.46.0 でビルドすると `.xcodeproj` が再生成され、baseline（2.44 系生成）との世代差分が毎回現れる。

```
LastUpgradeCheck 1430 → 2660 / xcscheme LastUpgradeVersion 2650 → 2660
+ ENABLE_USER_SCRIPT_SANDBOXING = YES  /  + STRING_CATALOG_GENERATE_SYMBOLS = YES
lastKnownFileType → explicitFileType（全 product）
INFOPLIST_KEY_UIAppFonts / UISupportedInterfaceOrientations（_iPad）: 配列 → 単一文字列
```

Blocker A では baseline を復元して手で 2 行だけ当てる形で回避したが、**その回避は一回限りで、ビルドのたびに戻ってくる**ことが 2026-08-17 に実証された。

**対処済み**: 2026-08-17 に A-2 検証（built `Info.plist` の baseline 比較・archive・appex 2 本・build script）を実施し、**生成物に差がないことを確認したうえで新世代を正式 baseline として受け入れた**（commit 4 = generator migration）。以後この差分は出ない。

**残る課題**: XcodeGen を再度上げたときに同じことが起きる。恒久策の候補は ① XcodeGen version の pin（`mise` / `Brewfile`）、② `.xcodeproj` を生成物として gitignore し常時生成、のいずれか。**どちらも Build Week のスコープ外。**

**再評価条件**: CI を組むとき、または XcodeGen を次に更新するとき。

---

## F-8. `Info.plist` と `INFOPLIST_KEY_*` の二重管理

**状態**: `deferred`

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

**今やらない理由**: フォントは現に動いており（Timeline のアイコンが表示されている）、正規化して**間違ったほうを消すと Timeline のアイコンが全滅する**。利用者から見た改善がゼロで、破壊のリスクだけがある。

**再評価条件**: Info.plist / build settings を別件で触るとき。実配置は確認済みなので、着手時は `project.yml` の `INFOPLIST_KEY_UIAppFonts` を削除し、**削除後に再度 archive して `MaterialIcons.ttf` が bundle 直下に残ること**を確認すること。

---

## F-9. Home Screen Widget の前景色契約が実画面で未検証

**状態**: `deferred`（2026-08-17 Tony 判断）

commit `1938e4b` で Widget の `.widget` 分岐にも `.environment(\.colorScheme, .dark)` を入れたが、**実画面での確認をしていない。**

**未検証の理由**: `FlightPresentationPolicy` の `.widget` window は T-12h〜T-6h。DEBUG fixture は `STD = now + 5h` で `.liveActivity` window に入るため、Simulator で Widget を出せない。出すには fixture の追加が必要で、Priority 2 のスコープ外と判断した。

**今の根拠**:

- T-51S が `.environment(\.colorScheme,.dark)` / `.containerBackground(for:.widget)` / `LinearGradient(` の 3 点を対で検査している（構文レベル）
- 同一の修正が Lock Screen / DI expanded で **iOS 18.6 / 26.5 × Light / Dark の 4 通りすべて PASS**

**残るリスク（明示しておく）**:

1. **`containerBackground(for:.widget)` は `activityBackgroundTint` と別機構である。** Lock Screen の PASS が Widget の PASS を論理的に保証するわけではない
2. **実運航で観測しても iOS 18 Light は覆われない。** 検証端末が iOS 18 系でない限り、この組み合わせは恒久的に未検証のまま残る

**再評価条件**: ① Widget を別件で触るとき、② iOS 18 系の実機が使えるとき、③ `.widget` window（`STD = now + 9h` 等）へ到達する DEBUG fixture を追加したとき。

**追加する場合の注意**: canonical fixture（`DEBUG-ANC-ICN-ANC` / `STD = now + 5h`）は **T-45〜T-49 の前提**なので変更しない。別の入口として追加すること。

---

## 未 commit の docs 差分について

`DEVICE_VERIFICATION_CHECKLIST.md`（commit 3 に既収録）への期待値修正と、本ファイル・`SWE_INSTRUCTION_PRIORITY2_SIMULATOR_TRIAGE.md` の新規追加は、**Priority 2 の実機検証結果を反映してから docs-only commit にまとめる**（2026-08-17 Tony 判断）。

`docs/PRIORITY2_TALLY_SHEET.md` は PM 管理の記入票。commit するかは検証完了後に判断する。
