# SWE 実装指示 — Browser popup lifecycle success-path cleanup

- 前提: `docs/RCA_SEQUENTIAL_IMPORT_FAILURE.md`（PM 承認済み・**訂正版**）を先に読むこと
- 対象: `TripDataHub/Views/BrowserWebView.swift`、`TripDataHub/ViewModels/BrowserViewModel.swift`
- 種別: presentation 層のバグ修正。**Phase 2 の import transaction とは独立**
- commit / stage / push: **行わない**

---

## 0. まず診断を確定させる（実装前）

デバイスログで、失敗した 2 回目の取り込み時に次が出るかを確認する。

```
[Import] pendingImport set id=... tripId=...
```

**出ない**ことを確認できたら本 RCA どおり。出る場合は実装前に PM へ報告すること（別の原因が主）。

---

## 1. 変更してはいけないもの

- **fingerprint ledger の抑止セマンティクス**（active 無期限 / consumed・dismissed 120 秒）
- **external-open queue / park の状態遷移**
- **import transaction と CloudKit の境界**（`beginCrewAccessImportTransaction()` 〜 upload の defer 構造）
- **`RootTabView.swift:147` の `!showingBrowser` ガード**、および `BrowserTabView` の `presentsImportPreview` の渡し方
  - 初版 RCA の「iPhone に presenter がない」は **PM の誤り**。両呼び出し側が既に `true` を渡している（`RootTabView.swift:75` / `iPadOperationalWorkspaceView.swift:148`）
  - **このガードを外すと二重 sheet 提示になって壊れる**
- Phase 1〜3 の operational state / Live Activity 実装

---

## 2. 主対策 — popup teardown を成功パスにも通す

### 現状の欠陥

`closePopups()`（`BrowserWebView.swift:293`）が `popupWebViews` / `popupParents` を掃除する唯一の関数で、**失敗パス 6 箇所からのみ**呼ばれている（`:213, 221, 259, 272, 278, 284`）。

成功パスは `viewModel.handlePDFData(data, ...)` を呼ぶだけで、その後始末は `BrowserViewModel.swift:44` の `self.popupWebView = nil` の 1 行のみ。`popupWebViews` / `popupParents` は Coordinator の持ち物なので ViewModel からは到達できない。**責務が 2 型に分裂し、成功パスだけが取りこぼしている。**

### 要求する形

**popup ライフサイクルの責務を `BrowserWebView.Coordinator` に一本化する。**

1. **`BrowserViewModel.handlePDFData` から `self.popupWebView = nil` を削除する。** ViewModel は popup のライフサイクルに関与しない
2. **成功パス 2 箇所**（`:226` の https 経路、`:267` の blob 経路）で、`handlePDFData` へデータを渡した**直後に `closePopups()` を呼ぶ**
3. これにより cleanup 経路は `closePopups()` **ただ 1 つ**になる。成功・失敗のどちらも同じ関数を通る

### 順序に関する注意（重要）

- `extractBlobFromURL(urlStr, from: parentWV)` は `popupParents[ObjectIdentifier(webView)]` を使って親 WebView を解決する。**blob 抽出の JS が完了して `data` を受け取る前に `popupParents` を消してはならない**
- 成功パスの `data` は既に `Data`（値型）としてメモリ上にあるため、`handlePDFData` へ渡した後の teardown は安全
- `handlePDFData` は内部で `Task { await importCrewAccessPDFData(...) }` を回すが、`data` は捕捉済みなので teardown の影響を受けない

### `closePopups()` の強化

現状は参照を捨てるだけなので、**live な WebView を確実に無効化してから解放する**こと。

1. 対象 popup の `stopLoading()` を呼ぶ
2. `navigationDelegate = nil` / `uiDelegate = nil` にする（生きた delegate を残さない）
3. `loadHTMLString("", baseURL: nil)` 等で現在のコンテンツを破棄する
4. `popupWebViews` / `popupParents` から除去
5. `viewModel.popupWebView` が同一インスタンスなら nil

`webViewDidClose(_:)` は「ページ側が `window.close()` した場合」の入口として残してよいが、**唯一の cleanup 経路にしない**。内部で `closePopups()` 相当を呼ぶ形に寄せること。

---

## 3. 名前付き window の再利用を断つ

teardown で popup を解放しても、CrewAccess 側の JS が同名 window を参照し続ける可能性がある。これが `Unable to load report, please close this tab and try again.` の直接要因と考えられる。

- 取り込み成功後、**親 WebView 上で対象 window を明示的に閉じる JS を実行する**ことを検討する。`extractBlobFromURL` と同じ `evaluateJavaScript` 経路が使える
- 実装可否は CrewAccess 側の window 名に依存するため、**SWE が実機ログで window 名を確認したうえで判断してよい**
- 判断がつかない場合は、まず §2 のみを実装して実機で A→B→C を検証し、`Unable to load report` が再発するかどうかで要否を決めること。**推測で JS を撃たない**

---

## 4. テスト

### T-26 / T-27（Tony 指示・import 層）

| # | 内容 |
|---|---|
| T-26 | `Import A → confirm success → 直後に別内容の B を配送 → B の preview がちょうど 1 回出る`（アプリ再起動なし） |
| T-27 | `A → B → C` を 1 セッション内で連続実行。各 preview が 1 回ずつ出る。`importInProgress` / `pendingImport` / `pendingImportFingerprint` / ledger が各回で正しく遷移する |

`importCrewAccessPDFData` を直接叩く形で書けば device 不要で回せる。

### T-28（本 RCA の本体を守るテスト・省略不可）

| # | 内容 |
|---|---|
| T-28 | PDF 取り込み **成功**後に `popupWebViews` と `popupParents` が **空**であること。失敗パス（fetch error / empty response / base64 decode 失敗 / JS error）でも同様に空であること |

**T-26 / T-27 だけでは不十分。** 両者は import 層のテストであり、popup leak を検出できない。T-28 がないと同じ形で再発する。

Coordinator の内部状態を検査できるよう、テスト用の可視性（`internal` 化や検査用プロパティ）を最小限で用意してよい。**プロダクション経路の挙動を変えないこと。**

---

## 5. 実機確認（修正後・Tony が実施）

| # | 確認内容 | 期待 |
|---|---|---|
| P-1 | `A → B → C` を 1 セッション内で連続 import | **3 回とも Import Preview が正常に出る**。アプリ再起動なし |
| P-2 | 各回の Print 画面 | 取り込み後に閉じる。開いたまま残らない |
| P-3 | CrewAccess Print Preview | **白画面化しない**。`Unable to load report, please close this tab and try again.` が出ない |
| P-4 | 3 回目の Timeline | C が正しく反映されている |
| P-5 | iPad で同じ手順 | 同じ結果（INV-005） |

---

## 6. 報告時に含めること

- 診断結果（`[Import] pendingImport set` がログに出たか）
- `closePopups()` を単一 API に統合できたか。できなかった場合はその理由
- §3 の JS による window close を実装したか、しなかったか、およびその判断根拠
- T-26 / T-27 / T-28 の結果と全ユニットテストの結果
- `git diff --check` と staging が空であること

修正後は **stage / commit / push せずに停止**し、差分を提示すること。
