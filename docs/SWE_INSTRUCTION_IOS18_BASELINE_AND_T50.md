# SWE 実装指示 — iOS 18 baseline 確定 / project diff 最小化 / T-50 再定義

- 種別: Build Week Phase 4 の commit gate 解除作業
- 前提: Live Activity minute-only countdown の実機 acceptance は **PASS 済み**。表示の作り直しは行わない
- **production countdown implementation は変更しないこと**
- commit / stage / push は行わない

---

## 0. Product Decision（Tony 確定・議論不要）

- **TDH の minimum supported OS は正式に iOS 18.0 とする**
- **iOS 17 fallback は不要。** `@available(iOS 18, *)` / `if #available` による分岐を新規に入れないこと
- **App Store の iOS 17 シェア確認は今回の commit gate にしない**
- `SystemFormatStyle.Timer` 単一路線で進める

`IPHONEOS_DEPLOYMENT_TARGET = 18.0` は確定事項である。以降の作業は「18.0 にする是非」ではなく「**18.0 にするために本当に必要な差分だけに縮小できるか**」である。

---

## Blocker A — project 再生成差分の最小化

### A-0. 現状

`project.yml` の 1 行変更（`17.0` → `18.0`）に対し、`.xcodeproj` の再生成が**新しい Xcode / XcodeGen 世代**で行われた結果、無関係な差分が混入している。

```
  LastUpgradeCheck                     1430  →  2660
  xcscheme LastUpgradeVersion          2650  →  2660
+ ENABLE_USER_SCRIPT_SANDBOXING = YES              （新規・全 target）
+ STRING_CATALOG_GENERATE_SYMBOLS = YES            （新規・全 target）
- INFOPLIST_KEY_UISupportedInterfaceOrientations = (配列形式)
+ INFOPLIST_KEY_UISupportedInterfaceOrientations = "空白区切り単一文字列"
- INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = (配列形式)
+ INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "空白区切り単一文字列"
- INFOPLIST_KEY_UIAppFonts = (Resources/Fonts/MaterialIcons.ttf,)
+ INFOPLIST_KEY_UIAppFonts = Resources/Fonts/MaterialIcons.ttf
- lastKnownFileType                    →  explicitFileType   （全 product 参照）
  DEVELOPMENT_TEAM 行の並び替え
```

これらは countdown 作業の成果ではなく **generator 世代差の副産物**である。とくに `UIAppFonts` と orientation の 2 件は、ビルド成果物の `Info.plist` に実際に入る値を変え得る。MaterialIcons が読めなければ Timeline のアイコンが全滅し、orientation が落ちれば iPad の landscape 制約が壊れる。実機 acceptance は Live Activity のみを見ており、ここは一切検証されていない。

### A-1. まず baseline へ戻して最小差分を試みる（本指示の主眼）

**別 commit に分けるだけでは不十分。** 順番は以下。

1. `git stash` 等で作業内容を退避し、`.xcodeproj` を **HEAD の baseline に戻す**
2. `project.yml` の `IPHONEOS_DEPLOYMENT_TARGET` のみを `"18.0"` に変更
3. **baseline を生成したのと同じ世代の XcodeGen** で再生成する
   - 現在使用中の XcodeGen version（`xcodegen --version`）を報告すること
   - baseline pbxproj の `LastUpgradeCheck = 1430` / objectVersion / `PBXFileReference` の書式から、どの世代で生成されたかを推定して報告すること
   - 必要なら `mise` / `brew` / tarball で旧 version を一時的に用意してよい
4. 結果の `git diff TripDataHub.xcodeproj/project.pbxproj` が
   **`IPHONEOS_DEPLOYMENT_TARGET = 17.0` → `18.0` の 2 行だけ**になるかを確認する

**2 行だけになった場合** — それが採用差分。`.xcscheme` の `LastUpgradeVersion` 変更も revert し、Blocker A は完了とする。A-2 は不要。

### A-2. 最小化できなかった場合のみ — generator migration として独立 commit

旧世代 XcodeGen を用意できない、あるいは用意しても差分が残る場合に限り、以下を**実測して**報告したうえで、独立 commit とする。

推測で「たぶん同じ」と書かないこと。**ビルドして生成物を読むこと。**

| # | 確認内容 | 方法 | 期待 |
|---|---|---|---|
| A-2-1 | `UIAppFonts` | baseline / 変更後それぞれで build し、`plutil -p <build>/TripDataHub.app/Info.plist` の該当キーを比較 | **baseline と完全一致すること**（絶対値ではなく差分を見る）。<br>**PM 訂正 2026-08-17**: 初版は「配列 1 要素 `Resources/Fonts/MaterialIcons.ttf`」と書いたが**誤り**。checked-in `TripDataHub/Info.plist` と `project.yml` の `INFOPLIST_KEY_UIAppFonts` が Xcode によって merge されるため、実際の生成物は 2 要素（`MaterialIcons.ttf` / `Resources/Fonts/MaterialIcons.ttf`）である。**これは migration が作った差ではない。** 本検証の目的は「migration が生成物を変えていないこと」であり、判定基準は baseline との一致のみ。詳細は `FOLLOW_UPS.md` F-8 |
| A-2-2 | `UISupportedInterfaceOrientations` | 同上 | **完全一致**。4 値の配列 |
| A-2-3 | `UISupportedInterfaceOrientations~ipad` | 同上 | **完全一致**。landscape 2 値の配列 |
| A-2-4 | Archive 成功 | `xcodebuild archive` | 成功。かつ `.app/PlugIns/` に **`TripDataCountdownWidgetExtension.appex` と `TripDataShareActionExtension.appex` の両方**が存在し署名されていること（`project.yml` のコメントにある過去の欠落事故の再発確認） |
| A-2-5 | build scripts 成功 | 同上 | `ENABLE_USER_SCRIPT_SANDBOXING = YES` によって run script phase が失敗していないこと。該当 phase が無いなら「無い」と報告すること |

`plutil -p` の出力は**該当キーの生ログをそのまま貼ること。** 要約しない。

### A-3. commit 分割

最終的に commit は最大 3 本。混ぜないこと。

1. （A-2 に至った場合のみ）generator migration — pbxproj / xcscheme の世代差分のみ
2. iOS 18 baseline — `project.yml` の target 変更と、それに追随する pbxproj 差分
3. Live Activity 表記・レイアウト — Swift ソースとテスト

**実際の stage / commit は行わない。** 「この 3 本にこう分ける」という対応表を差分ファイル名つきで提示するところまで。

### A-4. 触ってはいけないもの

- `project.yml` の target 以外の設定（bundle id / version / entitlements / dependency 構造）
- `.claude/settings.local.json`、`.claude/worktrees/`、`TDH-icon-1024.png` — **staging 対象に一切含めない**
- MARKETING_VERSION / CURRENT_PROJECT_VERSION の bump（別途 Tony が判断する）

---

## Blocker B — T-50 の再定義

### B-0. 現行が不十分な理由

現行の `test_liveActivitySystemTimerContractUsesMinutePrecisionAndAbsoluteUTCIntervals` は

```swift
XCTAssertEqual(FlightCountdownLiveActivityTimerContract.maxFieldCount, 2)
XCTAssertEqual(FlightCountdownLiveActivityTimerContract.maxPrecision, .seconds(60))
```

を確認しているだけで、**定数が定数であることを確認する自己言及テスト**である。実機で `Report in --hr --min` が出ていた `TimeDataSource` 版でも、この形のテストは緑のまま通っていた。T-26 / T-27 が popup leak を検出できなかったのと同じ欠陥クラスである。

さらに同テスト内に

```swift
// ... T-50 separately verifies this through the real WidgetKit renderer.
```

というコメントがあるが、**その T-50 は存在しない。** コメントが嘘をついている状態も是正すること。

### B-1. まず方式調査（実装より先）

**XCUITest 固定ではない。** 以下 3 方式のうち、どれが実際の WidgetKit / ActivityKit の redaction 発生地点を通れるかを調査し、**制約を報告してから**最終方式を決めること。

| 方式 | 調べること | 想定される制約 |
|---|---|---|
| ① ActivityKit 実 host integration | `ActivityKit` で実 Activity を起動し、`ActivityContent` の描画結果へ到達できるか。テスト host が widget extension プロセスの描画を観測できるか | Live Activity は別プロセス（WidgetKit extension）で描画される。テストプロセスから直接ピクセルを取れない可能性が高い |
| ② Widget rendering / snapshot test | widget extension の View を **extension と同じレンダリング条件**（Lock Screen 相当の redaction 環境）で `ImageRenderer` / `UIHostingController` にかけ、画像またはテキストを取得できるか | 実機の redaction は「別プロセス＋privacy 条件」で発生する。ホスト内 rendering では再現しない可能性がある。**再現しないなら T-50 として無価値。その場合は「再現しない」と報告すること** |
| ③ XCUITest / SpringBoard inspection | Live Activity を起動し、XCUITest から Lock Screen / Dynamic Island の accessibility label または screenshot を取得できるか | SpringBoard の accessibility 到達性、Lock Screen へ遷移する手段、Simulator での安定性 |

**実現不可能な方式を無理に採用しないこと。** 3 方式すべてが要件を満たせない場合は、**満たせない理由を方式ごとに具体的に書いて停止**し、PM に判断を求めること。「代わりに手動確認しました」で置き換えることは認めない。

### B-2. 採用する T-50 が満たすべき条件

方式が決まったら、以下 2 点を**両方**検出できる自動テストとして書くこと。

1. **redaction / 空表示の検出** — レンダリング結果に `--` / `–` / `––` / 空文字 / placeholder が現れたら **FAIL** すること。`TimeDataSource` 版で実際に出ていた `Report in --hr --min` を、このテストが赤にできることを**実証すること**（一時的に旧実装へ差し戻して赤になるのを確認し、その結果を報告する。差し戻しは検証後に戻す）
2. **minute boundary で値が変化すること** — **manual な Activity update を発行せずに**、分境界をまたぐと表示値が変わること。これが「OS が自動更新する」という採用根拠そのものの検証である。時刻の進行は fixture の絶対 UTC を動かす形で構成してよいが、**`Date()` に依存する非決定的なテストにしないこと**

条件 1 だけでは「凍結した値がそのまま残る」症状を検出できない。条件 2 だけでは redaction を検出できない。**両方必要。**

### B-3. 既存テストの扱い

- 現行の定数確認テストは **T-50 としては廃止**する。contract 定数の回帰として残す価値はあるので、`T-50` を名乗らない別名（例: `test_liveActivityTimerContractConstants`）へ改名し、嘘のコメントを削除すること
- T-14（4 行レイアウト / 3 幅高さ一致）は**変更しない**
- T-45〜T-49（debug fixture）も**変更しない**

---

## 変更してはいけないもの

- **Historical scope note:** この節の「production countdown implementationを現行のまま維持」は2026-08-17 PO revisionによりretired。新contract実装まではコード変更を開始しないが、承認後はADR-004 / INV-013〜018 / authoritative T-xxに従って置換する
- `FlightOperationalState` の評価順序・境界（2026-08-17改訂INV-018: STD / STD+61）
- `OperationalStateBuilder` の current leg 選択規則（passed legをminute 60まで優先）
- `FlightCountdownActivityLifecyclePolicy.staleDate`（`plannedDepartureUTC + 61min`）
- `FlightCountdownStatusPresentationStyle` による `.widget` / `.liveActivity` の分岐と、そのコメント
- `LegacyOperationalStatusView` の `Text(timerInterval:)`（Widget / compact / minimal は対象外のまま）
- import fingerprint ledger / queue semantics / transaction 境界
- browser popup lifecycle / focus acquisition

---

## 報告時に含めること

1. **minimal project diff** — 使用した XcodeGen version、baseline の推定生成世代、最小化を試みた結果の `git diff --stat` と pbxproj の全差分
2. **Info.plist / archive 結果** — A-2 に至った場合のみ。`plutil -p` の生ログ、archive の成否、`.app/PlugIns/` の中身、build script の状況
3. **T-50 方式と実行結果** — 3 方式それぞれの調査結果と制約、採用方式とその理由、B-2 条件 1 の「旧実装で赤になること」の実証ログ、条件 2 の結果、全ユニットテスト結果
4. **`git diff --check`** の出力と、staging が空であること
5. A-3 の commit 分割対応表（ファイル名つき）

**いずれかの段階で判断がつかなくなったら、実装を進めずそこで停止して報告すること。** 前回の T-47 仕様矛盾のときと同じ扱いでよい。

stage / commit / push は行わない。

---

## PM Resolution — T-50 replacement and follow-up

The original automated T-50 is not implementable with current public test APIs. ActivityKit host tests cannot observe WidgetKit pixels; host snapshots do not reproduce the extension privacy/redaction environment; and public XCUITest has no Lock Screen button or fixed-UTC injection for SpringBoard.

- **T-50S (commit gate):** source-scope guard for `LiveActivityOperationalStatusView`. It rejects `Text(timerInterval:`, `.components(style:`, `.dateRange(`, `style: .relative`, and `style: .timer`, and requires `.timer(countingDownIn:` plus `.timer(countingUpIn:`. The count-up source must use the presentation-only STD..<STD+60min clamp; lifecycle expiration and `staleDate` remain separately fixed at STD+61min. Arrival prefixes, arrival-state cases, planned-arrival count-up intervals, or reuse of the expiration Date as the timer upper bound fail the guard. It does not claim to verify rendered pixels.
- **D-7 (device-only acceptance):** `docs/DEVICE_VERIFICATION_CHECKLIST.md` verifies that Lock Screen and Dynamic Island expanded render numeric durations without dash/blank redaction.
- **Follow-up after Priority 5:** evaluate a nightly, non-gating Dynamic Island expanded XCUITest using SpringBoard coordinate long-press, screenshot OCR, and a real-time 70-second minute-boundary observation. Do not require Lock Screen, and do not implement this during the current commit-gate work.
