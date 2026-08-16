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

## D. Layout（Phase 4）

**iPhone / iPhone Pro Max / iPad の 3 機種すべてで確認すること。**

| # | 確認内容 | 期待 |
|---|---|---|
| D-1 | Live Activity の route 行 | `ANC 23:24 → SGN 02:45` が **1 行**。2 行に折り返さない |
| D-2 | 同上 | 飛行機アイコンや装飾がない |
| D-3 | Timeline の Connection card（ICN-CGO leg） | 2 行:<br>`Block: 02:44`<br>`Connection at CGO: 2:31` |
| D-4 | 同上 | 両方**右揃え**。`/` で繋がった 1 行になっていない |
| D-5 | iPad の Connection card | iPhone と**同じ 2 行構造** |
| D-6 | 文字サイズ設定を大きくする | 折り返しが発生しない（縮小で吸収される） |

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

- **2026-08-15 実機確認の結果**: A（transaction）は PASS、**A-3 は FAIL** で UI を `.alert` へ修正済み。A-3 / A-3b / A-3c は**再確認が必要**。B〜E は端末 offline のため未実施。
- B-6 / B-7 / B-8 / C-5 は**実際のトリップ中でないと確認しにくい**。次の `ANC-SGN-ICN-CGO-ICN-ANC` パターンで確認するのが確実。
- B-11〜B-13 と C-6 / C-7 / D-1〜D-6 は**地上で今すぐ確認できる**。先にこちらを消化しておくと差し戻しが早い。
- 未 commit の状態で実機に入れる必要があるため、Xcode から直接インストールすること。
