# TDH Build Week — 実機確認チェックリスト

- 対象: Phase 1〜4 完了ビルド（未 commit）
- 必要機材: iPhone、iPad、CrewAccess の実 Trip PDF（Original / Revised の 2 種）
- 目的: Definition of Done の全項目を実機で照合する
- 原則: **Incorrect operational information is worse than no information.**

判定は「仕様どおり」か「そうでない」の 2 値。迷ったら NG にして PM に上げること。

---

## A. Revised Trip Import（RC-4 / Phase 2）

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

## B. Countdown / Flight State（RC-1 / RC-2 / RC-3 / Phase 1）

Trip 開始前から順に確認する。時間を飛ばせない項目は、実際のトリップ中に確認すること。

**本章は「アプリ内 Timeline」の表示を見る。** Live Activity / Lock Screen は D-7 で別途確認する。両者は表記が異なる（下記 D-7 の注記を参照）。

| # | タイミング | 期待表示 |
|---|---|---|
| B-1 | Report Time より前 | `Report in HHhr MMmin` |
| B-2 | Report Time 経過後、STD 前 | `Dep in HHhr MMmin` |
| B-3 | B-2 の値 | **STD との実差と一致**（数分でもズレたら NG。RC-2 の再発） |
| B-4 | STD 経過・実際にはまだ出発していない | `Scheduled Departure Time Passed` |
| B-5 | B-4 の状態 | `Delayed` の文字が**どこにも出ない** |
| B-6 | 飛行中（ATD 観測済み） | `Arriving in HHhr MMmin` |
| B-7 | 飛行中に STD+6h を超えた長距離便（ANC→SGN 等） | `Completed` が**出ない**（旧実装の最頻出バグ） |
| B-8 | STA 経過・ATA 未確認 | 2 行表示:<br>`Scheduled Arrival Time Passed HHhr MMmin`<br>`Scheduled Arrival: HH:MM LCL` |
| B-9 | Timeline の表示を LCL ⇄ UTC 切替 | **1 行目の経過時間は変化しない**。2 行目の時刻表記だけ変わる |
| B-10 | STA + 1 時間経過後 | そのフライトの表示が**止まる**（居座らない） |

**Time Zone（最重要・実運用で壊れた箇所）**

| # | 手順 | 期待 |
|---|---|---|
| B-11 | `Dep in` 表示中に device TZ を ANC → SGN へ変更 | **カウントダウンの残り時間が変化しない** |
| B-12 | 続けて SGN → ICN（韓国）へ変更 | 同上。`Delayed 5h 23m` のような値が出ない |
| B-13 | TZ 変更後の時刻表記 | 表示 TZ だけが変わる |

**Deadhead**

| # | 確認内容 | 期待 |
|---|---|---|
| B-14 | `DH KE480 SGN→ICN` の countdown | Operating 便と**同じ挙動**（DH だけ計算が違わない） |
| B-15 | DH 便で device TZ を韓国に変更 | 残り時間が変化しない |

---

## C. Live Activity / Dynamic Island / 起動時復元（RC-5 / Phase 3）

| # | 手順 | 期待 |
|---|---|---|
| C-1 | Report → Dep → STD 経過 と状態が進む間 | Dynamic Island が**消えて再生成されない**（同一 leg なら更新のみ） |
| C-2 | 1 leg 終了 → 次 leg へ | 旧 leg の表示が消え、新 leg が 1 つだけ出る |
| C-3 | Revised Trip を Replace した直後 | 旧 schedule 由来の Live Activity が**残らない** |
| C-4 | 同上 | 旧 schedule 由来の通知が**残らない**（通知センターを確認） |
| C-5 | **ICN 到着後にアプリを再起動** | `+2:28 STD` のような Delayed 表示が**復活しない**（症状 11 の再発確認） |
| C-6 | アプリ起動直後 | **画面が即座に出る**（空白のまま止まらない。Phase 3 で修正した箇所） |
| C-7 | 起動を 5 回程度繰り返す | Dynamic Island が**二重に出ない** |
| C-8 | 到着済み・完了した leg | Dynamic Island に出てこない |

---

## D. Layout / Live Activity 実描画（Phase 4 v2）

**iPhone / iPhone Pro Max / iPad の 3 機種すべてで確認すること。**

### D-0. 検証レイヤーの区別（先に読むこと）

**Simulator の PASS と unit test の green は、実機 Acceptance の代替ではない。** 何がどこまでを保証するのかを取り違えると、緑のまま実機が壊れる。実際に 2026-08 の `Report in --hr --min` はこの取り違えで通過した。

| レイヤー | 何を保証するか | 何を保証しないか |
|---|---|---|
| unit test（T-14） | 4 行構成が幅によって増減しないこと。3 幅でホスト内レンダリング高さが一致すること | **WidgetKit プロセスでの実描画**。ホスト内 `UIHostingController` は別プロセスの redaction 経路を通らない |
| unit test（T-50S） | Live Activity 経路が redaction 既知の構文（`Text(timerInterval:)` / `.components(style:` / `.dateRange(`）へ**戻らない**こと | 描画結果そのもの。**ピクセルを一切見ていない** |
| Simulator 対話確認（B-11〜B-13 / debug fixture） | state 遷移・visibility window・TZ 非依存性・current leg 選択 | 実機の Lock Screen 描画、実運航の時刻進行、実 PDF 由来のデータ |
| **実機 D-1〜D-7** | 上記すべてが**実際の画面**で成立していること | — |

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

### D-3〜D-6. Timeline Connection card（**本変更の対象外・従来どおり**）

> **D-3〜D-5 は Simulator triage の対象外。** connection を持つ実 Trip データ（`ICN-CGO` 等）が必要で、
> DEBUG fixture は 2 leg の `ANC-ICN-ANC` である。fixture を拡張すると T-45〜T-49 の前提が崩れるため拡張しない。
> **実 PDF を扱う Priority 5 と併せて、実機で確認する。**（2026-08-17 再分類）

番号は据え置き。他ドキュメントからの参照を壊さないため。

| # | 確認内容 | 期待 |
|---|---|---|
| D-3 | Timeline の Connection card（ICN-CGO leg） | 2 行:<br>`Block: 02:44`<br>`Connection at CGO: 2:31` |
| D-4 | 同上 | 両方**右揃え**。`/` で繋がった 1 行になっていない |
| D-5 | iPad の Connection card | iPhone と**同じ 2 行構造** |
| D-6 | 文字サイズ設定を大きくする | 折り返しが発生しない（縮小で吸収される） |

---

### D-7. Live Activity duration rendering（**自動テスト不能・実機必須**）

**この項目は自動化できない。人間が実際の画面を見る以外に検証手段がない。**

**自動化不能の理由**: WidgetKit extension は別プロセスで描画され、公開 XCTest API から Lock Screen へ遷移する手段がなく（`XCUIDevice.Button` に `.lock` が存在しない）、SpringBoard へ固定 UTC を注入できない。ActivityKit 実 host / ホスト内 snapshot / XCUITest の 3 方式すべてを検証済み。（調査記録: `SWE_INSTRUCTION_IOS18_BASELINE_AND_T50.md` B-1）

#### 対象サーフェス（どれを見るかを取り違えないこと）

| サーフェス | 描画元 | 表記 | D-7 対象 |
|---|---|---|---|
| **Lock Screen Live Activity** | `LiveActivityOperationalStatusView` → **OS 描画**（`SystemFormatStyle.Timer`） | `3 hours, 15 minutes`（分精度・OS ロケール依存） | **対象** |
| **Dynamic Island expanded** | 同上 | 同上 | **対象** |
| Dynamic Island compact | `LegacyOperationalStatusView` | `H:MM:SS`（秒あり） | 対象外。**秒が出るのが正**。NG に上げない |
| Dynamic Island minimal | 同上 | 同上 | 同上 |
| Home Screen Widget | 同上 | 同上 | 対象外。`FlightPresentationPolicy` により Live Activity と**同時に出ない**ため利用者が並べて見ることはない（follow-up として記録済み） |

> **重要 — アプリ内表記と Live Activity 表記は異なる。**
> アプリ内 Timeline は `FlightCountdownSharedStore.durationText` が生成する `3hr 15min`、
> Live Activity は OS が描画する `3 hours, 15 minutes`。**同じ値でも文字列が違うのが現状の実装である。**
> B 章（アプリ内）の `HHhr MMmin` と D-7（Live Activity）の表記差を NG として上げないこと。
> 表記統一は **`FOLLOW_UPS.md` F-1 として deferred 判断済み**（2026-08-17）。現状維持でよい。

#### 確認項目

| # | サーフェス | 確認内容 | 期待 |
|---|---|---|---|
| D-7a | **Lock Screen** | `Report in` の数値部 | `3 hours, 15 minutes` の形（**`3hr 15min` ではない**）。`--` / `–` / `––` / 空欄 / placeholder が**出ない** |
| D-7b | **Dynamic Island expanded** | 同上 | 同上。Lock Screen と**同じ値**を示す。**下記の観測規約に従うこと** |
| D-7c | Lock Screen | 分境界をまたぐまで**画面を見たまま待つ**（最大 60 秒） | **アプリを開かずに**値が 1 減る。凍結しない |
| D-7d | Lock Screen | アプリをバックグラウンドに置いたまま 10 分以上放置してから見る | 値が正しく進んでいる。古い値が残らない |
| D-7e | Lock Screen | device TZ を ANC → SGN → ICN と変更 | **duration が変化しない**。変わるのは空港時刻の表記のみ |
| D-7f | Lock Screen / DI expanded | `Dep in` / `Arriving in` / `Scheduled Arrival Time Passed` の各状態 | いずれも D-7a と同じ条件を満たす。**4 状態すべてを見ること** |
| D-7g | Lock Screen | 秒 | **表示されない** |

**D-7c と D-7d が本項目の中核。** 「秒が消えているか」だけを見て PASS としないこと。`SystemFormatStyle.Timer` を採用した根拠は「**OS が自動更新するのでアプリを開かなくても値が凍結しない**」であり、そこを確認しなければ採用根拠が未検証のまま残る。


> **D-7b / 複数サーフェス比較の観測規約（必須）**
>
> DEBUG fixture は起動のたびに `STD = now + 5h` を作り直す。**run をまたいで撮った 2 枚を比較すると必ず食い違う。**
> 実際に 2026-08-17、別 run の Lock Screen と DI expanded を比較して FAIL と誤判定した。
>
> 1. Simulator を `Erase All Content and Settings` で初期化する
> 2. fixture を **1 回だけ**起動し、起動時刻を記録する
> 3. **同一分内**に両サーフェスを撮影する。その間にアプリ再起動・fixture 再起動・再ビルドをしない
> 4. 画面の文字列を **1 文字ずつそのまま**書き写す。要約・言い換えをしない（`Dep in` を `Depart in` と書かない）
> 5. 食い違いを見つけたら、RCA の前に `Activity<FlightCountdownAttributes>.activities` の **count / id / legID / plannedDepartureUTC** を確認する。`count >= 2` なら lifecycle 欠陥、`count == 1` なら観測手順を疑う
>
> **算術チェック**: 同一 leg なら `Dep in` は `Report in` より必ず report lead（ANC↔ICN は 90 分）だけ大きい。差が 90 分でない 2 値は同一 run のものではない。

#### OS バージョン網羅（**最低サポート版での確認は必須**）

本アプリの最低サポートは **iOS 18.0**。`SystemFormatStyle.Timer` は OS 描画のため、**最低サポート版で 1 度は D-7a / D-7c / D-7g を通すこと。**
最新版のみで確認して済ませない。先の `TimeDataSource` の dash redaction も特定 OS 版で発見された事象であり、OS 版依存の描画差は本件で実証済みである。

文字列そのものは OS 版 / ロケールで変わり得る。**NG の条件は「redaction・空欄・秒の出現・凍結」のみ**とし、語形の差は NG にしない（観測文字列は報告すること）。

#### 再実行が必須になる契機

1. iOS メジャーバージョン更新
1b. **最低サポート OS を引き上げたとき**（新しい下限で再確認する）
2. `LiveActivityOperationalStatusView` または `FlightCountdownLiveActivityTimerContract` の変更
3. Xcode メジャーバージョン更新

---

## Priority 2 完了条件（再定義）

**旧定義「D-1〜D-6 を 3 幅で確認」は無効。** v2 レイアウトと D-7 追加を反映して以下に置き換える。

Priority 2 が完了したと報告できるのは、**次の 3 条件をすべて満たしたとき**に限る。

**条件 1 — レイアウト（3 幅 × 実機）**

- D-1 / D-1b / D-1c / D-2 / D-2b / D-2c を **iPhone / iPhone Pro Max / iPad の実機**で確認
- **Lock Screen と Dynamic Island expanded の両方**で確認する。片方のみは不可
- D-3〜D-6（Timeline Connection card）も同 3 機種で確認

**条件 2 — 実描画（D-7）**

- D-7a〜D-7g を実機で確認
- **4 状態（`Report in` / `Dep in` / `Arriving in` / `Scheduled Arrival Time Passed`）すべて**を通す。DEBUG fixture で到達できる状態は fixture で、できないものは実運航で
- **DEBUG fixture で到達できる範囲だけを見て「D-7 PASS」と報告しない。** どの状態を fixture で見て、どれが実運航待ちかを明示する

**条件 3 — 記録**

- 3 幅 × 2 サーフェスのスクリーンショットを添付
- Simulator で見たものと実機で見たものを**区別して**記録する。「Simulator で確認」は条件 1・2 のいずれも満たさない

**明示的に Priority 2 の完了条件に含めないもの**

- T-14 / T-50S の green — CI の前提条件であって、完了の根拠ではない
- B-11〜B-13 の Simulator PASS — Priority 1 の項目であり、レイアウトを何も保証しない
- 実運航でしか到達できない `Arriving in`（airborne）と `Scheduled Arrival Time Passed` — **次のトリップまで開いたままにする。** これらが未確認であることを理由に Priority 2 を止めず、「条件付き完了・実運航待ち 2 項目」として報告すること

---

## E. 回帰（壊していないこと）

| # | 確認内容 | 期待 |
|---|---|---|
| E-1 | iPhone で Import → iPad で確認 | 同期される |
| E-2 | Friends タブの rest window | 表示される。**Asia regional leg では従来より 30 分短い**（report lead 60→90 分の修正による意図した変化） |
| E-3 | Bid Period / Calendar 表示 | 従来どおり |
| E-4 | LogTen CSV export | 従来どおり |
| E-5 | 通知（48h / 24h / 12h） | 設定した時刻に届く |

---

## 記録方法

各項目を `OK` / `NG` / `未確認` で記録し、NG は次を添えて PM に上げること。

1. 機種と OS バージョン
2. 実際の表示（スクリーンショットが最良）
3. その時点の便名・STD / STA・device TZ
4. 再現手順

**NG が 1 つでもあれば Definition of Done 未達。** 該当 Phase に差し戻す。

---

## 補足

### 検証状況（2026-08-17 時点）

| 区分 | 状況 |
|---|---|
| A（import transaction） | **PASS**。ただし **A-3 / A-3b / A-3c は再確認が必要**（2026-08-15 に A-3 FAIL → `.alert` へ修正済み） |
| A-8〜A-11（重複配送ストレス） | 未実施。Priority 5 |
| B-1〜B-5 / B-9 / B-10 / B-14 | 未実施。一部は DEBUG fixture で前倒し可能 |
| B-6 / B-7 / B-8 | **実運航待ち**。airborne / STA 経過は地上で作れない |
| B-11〜B-13 | Simulator で PASS。**実機での再確認は未実施**（Priority 1 は Simulator harness までで完了扱い） |
| C-1〜C-4 / C-8 | 未実施 |
| C-5 | **実運航待ち**（到着後 relaunch） |
| C-6 / C-7 | 未実施。Priority 3 |
| D-1〜D-7 | **未実施。Priority 2（本 v2 定義で実施すること）** |
| E-1 / E-3 / E-4 / E-5 | 未実施 |
| E-2 | 未実施。Priority 4 |

### 実施順の推奨

1. **Priority 2（D-1〜D-7）** — 地上で今すぐ消化できる。Live Activity 変更の commit 直後に実施するのが最も差し戻しが早い
2. Priority 3（C-6 / C-7） — 起動系。同じく地上で可能
3. Priority 4（E-2） — Friends rest window
4. Priority 5（A-8〜A-11） — import ストレス。実 PDF が必要
5. **実運航 acceptance（B-6 / B-7 / B-8 / C-5 / C-8 ＋ D-7 の airborne 系）** — 次の `ANC-SGN-ICN-CGO-ICN-ANC` で確認

### 注意

- **Simulator / unit test の PASS を実機 Acceptance として報告しないこと。** D-0 の表を参照。Definition of Done の「実機で iPhone + iPad を確認」は、実機でしか閉じられない
- 未 commit の状態で実機に入れる必要があるため、Xcode から直接インストールすること
- DEBUG fixture（Settings から起動）を使うと、実運航を待たずに `Report in` / `Dep in` の描画を確認できる。ただし **fixture は in-memory・非永続**であり、CloudKit / Friends へは一切上がらない。実 Trip データでの確認を置き換えるものではない
