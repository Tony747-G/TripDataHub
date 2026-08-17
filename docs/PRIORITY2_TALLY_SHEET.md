# Priority 2 実施票 — Live Activity レイアウト / 実描画

- 対象 commit: `953d8ba`（build-week/operational-reliability）
- 判定は `OK` / `NG` / `未確認` の 3 値。**迷ったら NG**
- 詳細仕様は `DEVICE_VERIFICATION_CHECKLIST.md` の D 章。本票は記録用の短縮版

---

## 事前準備

1. Xcode から 3 機種へ直接インストール（未 push 分ではないが、TestFlight 経由ではなく実ビルドで確認する）
2. Settings → DEBUG fixture を起動（`DEBUG-ANC-ICN-ANC`）
3. fixture 起動直後は `Report in` 状態（STD = now + 5h、report = STD − 1h30m）
4. 記録に残すもの: 機種 / iOS バージョン / 確認時刻 / スクリーンショット

**Simulator ではなく実機で行うこと。** Simulator の結果は Priority 2 の完了条件を満たさない。

---

## 1. レイアウト（D-1 系 / D-2 系）

各セルに `OK` / `NG` / `未確認` を記入。**Lock Screen と Dynamic Island expanded の両方**を見る。

期待する形:

```
Flight: D901

Aug 16 (Sun)                    Aug 17 (Mon)
ANC 16:13          ✈           ICN 17:33

Report in 3 hours, 15 minutes
```

| # | 確認内容 | iPhone LS | iPhone DI | Pro Max LS | Pro Max DI | iPad LS |
|---|---|---|---|---|---|---|
| D-1 | 常に 4 行。増えない・減らない | | | | | |
| D-1b | 日付が空港の真上。左端/右端で揃う | | | | | |
| D-1c | 4 テキストとも 1 行。折り返さない | | | | | |
| D-2 | 中央は飛行機アイコン 1 個のみ | | | | | |
| D-2b | 飛行機が左→右の向き | | | | | |
| D-2c | 幅不足時に縮むのはテキスト側 | | | | | |

**D-6 併記**: iOS の文字サイズを最大にして D-1 / D-1c を再確認 → `______`

---

## 2. 実描画（D-7 系）— **本 Priority の中核**

Lock Screen で確認。DI expanded は D-7b のみ。

| # | 確認内容 | 判定 | 実測値 |
|---|---|---|---|
| D-7a | `Report in` の数値が `--` / `–` / 空欄でない | | 例: `3 hours, 15 minutes` → |
| D-7b | DI expanded が Lock Screen と**同じ値** | | LS: ____ / DI: ____ |
| D-7g | 秒が表示されない | | |
| **D-7c** | 画面を見たまま最大 60 秒待つ → **アプリを開かずに**値が 1 減る | | 前: ____ → 後: ____ |
| **D-7d** | アプリを閉じて 10 分以上放置 → 見たら値が正しく進んでいる | | 放置前: ____ / 放置後: ____ / 経過: ____分 |
| D-7e | device TZ を ANC → SGN → ICN と変更 → **duration が変わらない** | | ANC: ____ / SGN: ____ / ICN: ____ |

> **表記の注意**: Live Activity は OS 描画のため `3 hours, 29 minutes` の形。アプリ内 Timeline の `3hr 29min` とは**文字列が異なるのが正**。表記差を NG に上げないこと。

**D-7c / D-7d が最重要。** 秒が消えていることだけで PASS にしないこと。採用根拠は「OS が自動更新するのでアプリを開かなくても凍結しない」であり、そこを見なければ根拠が未検証のまま残る。

### D-7f — 4 状態すべて

| 状態 | 到達方法 | 判定 |
|---|---|---|
| `Report in` | DEBUG fixture 起動直後 | |
| `Dep in` | fixture の report time 通過待ち、または fixture 側で STD を近づける | |
| `Arriving in` | **実運航待ち**（ATD 必要） | 実運航待ち |
| `Scheduled Arrival Time Passed` | **実運航待ち**（STA 通過必要） | 実運航待ち |

後半 2 つが未確認でも **Priority 2 は止めない。**「条件付き完了・実運航待ち 2 項目」として報告する。

---

## 3. Timeline Connection card（D-3〜D-5・本変更の対象外）

回帰確認のみ。`ICN-CGO` leg を見る。

| # | 確認内容 | iPhone | Pro Max | iPad |
|---|---|---|---|---|
| D-3 | `Block: 02:44` / `Connection at CGO: 2:31` の 2 行 | | | |
| D-4 | 両方右揃え。`/` 連結の 1 行になっていない | | | |
| D-5 | iPad も同じ 2 行構造 | | | |

---

## 4. NG に上げてはいけないもの

以下は**仕様どおり**。見つけても NG にしない。

- **Dynamic Island compact / minimal で秒が出る**（`H:MM:SS`）— `LegacyOperationalStatusView` 描画。対象外
- **Home Screen Widget で秒が出る** — 同上。`FlightPresentationPolicy` により Live Activity と同時に表示されないため利用者が並べて見ることはない
- fixture の Trip が Timeline に出ない / iPad に同期されない — fixture は in-memory・非永続。CloudKit / Friends へ上げない設計

---

## 5. 完了報告に含めるもの

1. 上記 3 表の記入済みコピー
2. **3 幅 × 2 サーフェス**のスクリーンショット
3. D-7c / D-7d の前後の値と経過時間
4. 実運航待ちとして残した項目の一覧
5. 機種と iOS バージョン

**NG が 1 つでもあれば、そこで止めて PM に上げること。** 残りを消化するより最初の NG を正しく切り分けるほうが価値が高い。

---

## 記録欄

- 実施日: ____________
- 機種 / OS: iPhone ________ / iPhone Pro Max ________ / iPad ________
- 総合判定: `PASS` / `条件付き PASS（実運航待ち ___ 項目）` / `FAIL`
- 備考:

---

## 実施結果 — Simulator triage（2026-08-17 記入・PM）

**これは Simulator triage の結果であり、Priority 2 の実機 acceptance ではない。**

### レイアウト（sim・iOS 26.5）

| # | iPhone 16 | 16 Pro Max | iPad Pro 13 |
|---|---|---|---|
| D-1 / D-1b / D-1c | PASS | PASS | PASS |
| D-2 / D-2b / D-2c | PASS | PASS | PASS |
| D-6（最大 Dynamic Type） | PASS | PASS | PASS |

### 実描画 appearance / OS マトリクス（sim）

| Runtime / Appearance | Lock Screen | DI expanded | Home Widget |
|---|---|---|---|
| iOS 18.6 Light | PASS | PASS | **未観測** |
| iOS 18.6 Dark | PASS | PASS | **未観測** |
| iOS 26.5 Light | PASS | PASS | **未観測** |
| iOS 26.5 Dark | PASS | PASS | **未観測** |

全 run で `Activity` count = 1。redaction / 空欄 / 秒 / 折り返しなし。D-7a / D-7c / D-7d / D-7g PASS。

**Home Widget が未観測である理由**: `FlightPresentationPolicy` の `.widget` window は T-12h〜T-6h。DEBUG fixture は `STD = now + 5h` で `.liveActivity` window に入るため、Widget が表示されない。**fixture / policy を書き換えて無理に出すことはしない**と PM が判断した。

### 未実施のまま残るもの

| 項目 | 理由 |
|---|---|
| D-3〜D-5（Connection card） | 実 Trip データ必要。Priority 5 の device acceptance へ再分類 |
| D-7e（device TZ 変更） | device-only。Simulator の TZ 伝播が信頼できない |
| D-7f の `Arriving in` / `Scheduled Arrival Time Passed` | 実運航待ち |
| **Home Widget の色（iOS 18 Light）** | **window 外で未観測。`FOLLOW_UPS.md` F-9 参照** |
| 実機 acceptance 全般 | Simulator は代替にならない |

### 判定

```
Simulator triage PASS on iOS 18 and iOS 26.5.
This does NOT close Priority 2.
Device acceptance on iPhone / iPhone Pro Max / iPad remains required,
and D-3 through D-5 move to device acceptance with real trip data.
```
