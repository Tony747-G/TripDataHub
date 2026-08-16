# RCA — Sequential distinct imports fail after the first success

- 報告: 実機 A-3 追試。Import A は正常完了。直後に**別 trip / 別内容**の PDF を同じ Print flow で取り込もうとすると Import Preview が開かない。Print 画面は開いたまま、Timeline も変わらない。繰り返すと `Unable to load report, please close this tab and try again.`
- 調査範囲: in-app browser の PDF 検出経路、import state machine、fingerprint ledger、external-open queue、App Group handoff
- **コード変更なし（調査のみ）**

---

## 結論

**Root Cause は `BrowserWebView.Coordinator` の popup WebView ライフサイクルにある。成功パスだけが cleanup を行わない。**

`closePopups()` は `viewModel.popupWebView = nil` に加えて `popupWebViews.removeAll()` と `popupParents.removeAll()` を行う唯一の関数で、**失敗パス 6 箇所すべてから呼ばれている**（`BrowserWebView.swift:213, 221, 259, 272, 278, 284`）。

一方、**成功パスは `handlePDFData(...)` を呼ぶだけ**で、`handlePDFData`（`BrowserViewModel.swift:30-46`）が行う後始末は

```swift
self.popupWebView = nil        // ← SwiftUI sheet を閉じるだけ
```

の 1 行のみ。`popupWebViews` と `popupParents` には触れない。両者は `BrowserWebView.Coordinator` の持ち物で `BrowserViewModel` からは到達できない。

もう 1 つの cleanup 経路 `webViewDidClose(_:)`（`:93-101`）は **WKUIDelegate のコールバックであり、ページ側が `window.close()` を実行したときにしか発火しない**。アプリが sheet を閉じても呼ばれない。

結果、**import が成功するたびに popup WKWebView が 1 個ずつ強参照で生き残る。**

---

## 症状 3 点がすべて 1 つの原因で説明できる

| 観測 | 機序 |
|---|---|
| 2 回目以降、Import Preview が開かない | 生き残った popup は delegate 付きで生存している。CrewAccess の Print は `window.open()` で名前付きウィンドウを開く。**同名の window が既に存在すると WebKit は `createWebViewWith` を呼ばずに既存 window へ navigate する。** その window は sheet から外れて不可視なので、PDF が読み込まれても画面上は何も起きない |
| Print 画面が開いたまま | 上記のとおり新しい popup sheet が提示されないため。`handlePDFData` に到達していないので `popupWebView = nil` も走らない |
| `Unable to load report, please close this tab and try again.` | report tab が一度も正しく閉じられない（`window.close()` が実行されない）。CrewAccess 側は report window が開いたままだと判断し、再発行を拒否する。**繰り返すほど悪化する**のはこのため |

**「1 回目は成功、2 回目から失敗」という切り分けと完全に一致する。** 1 回目の Print 時点では stale popup が存在しないため。

---

## 除外できた仮説（Tony の指示リストへの回答）

いずれも **本件の原因ではない**。

| 項目 | 判定 | 根拠 |
|---|---|---|
| fingerprint ledger の 120 秒抑止 | **無関係** | B は別内容 → SHA-256 が異なる → `claim` は `.accepted`。`suppressionState` も nil |
| `pendingImport` の解放 | **正常** | `confirmPendingImport` 成功パスで `pendingImport = nil` / `pendingImportFingerprint = nil` |
| `importInProgress` | **正常** | 同パスで `false` に戻る。`importCrewAccessPDFData` の guard も通過できる状態 |
| consumer restart after confirm | **本経路では無関係** | **browser 経路は external-open queue を一切通らない。** `handlePDFData` → `importCrewAccessPDFData` を直接呼ぶ（`BrowserViewModel.swift:37`）。`queueExternalOpenURL` は呼ばれない |
| App Group handoff completion | **本経路では無関係** | 同上。share extension 経由ではなく in-app browser 経由 |
| queue / park state | **本経路では無関係** | 同上 |
| distinct fingerprint が 1 回だけ消費されるか | **そもそも import 層に到達していない** | 下記の診断で確定できる |

**ledger の抑止セマンティクスを変更する必要はない。** 指示どおり触らないこと。

---

## 診断（実装前に 1 分で確定させる）

デバイスログで、失敗した 2 回目の取り込み時に次の行が出るかを見る。

```
[Import] pendingImport set id=... tripId=...
```

- **出ない** → PDF が import 層に到達していない → **本 RCA のとおり popup lifecycle が原因**（想定どおり）
- **出る** → import は成立しているのに Preview が出ていない → 下記の副次的欠陥が主因

---

## 副次的欠陥とした指摘は誤りだった（PM 訂正 / 修正不要）

初版で「iPhone に Preview presenter が存在しない」と書いたが、**これは誤りである。修正してはならない。**

`BrowserTabView.init(presentsImportPreview:)` のデフォルト値が `false` であることだけを見て、呼び出し側を確認していなかった。実際は **2 つの呼び出し側の両方が `true` を渡している**。

- `RootTabView.swift:75` — `NavigationStack { BrowserTabView(presentsImportPreview: true) }`
- `iPadOperationalWorkspaceView.swift:148` — 同上

したがって iPhone でも `BrowserTabView` 自身が Preview を提示する。`RootTabView.swift:147` の `!showingBrowser` ガードは **二重提示を防ぐための正しい実装**であり、`BrowserTabView.swift:21-24` のコメントがその意図を明記している。

**このガードを外すと、browser sheet の上に RootTabView からもう 1 枚 sheet を出そうとして提示が壊れる。** 触らないこと。INV-005 違反も存在しない。

上記「診断」で `[Import] pendingImport set` が出るのに Preview が出ない場合は、presenter ではなく **sheet 多重提示のタイミング**を疑うこと（browser sheet 上への提示が、直前の Import Preview の dismiss アニメーションと競合していないか）。

---

## 対策方針

### 1. 成功パスにも popup teardown を通す（主対策）

- **cleanup の責務を 1 箇所に集約する。** 現在は `closePopups()`（Coordinator）と `handlePDFData` の `popupWebView = nil`（ViewModel）に分裂しており、成功パスだけが取りこぼしている
- 成功・失敗にかかわらず、popup の後始末は **必ず同じ関数**を通ること
- teardown では以下を行う:
  1. 対象 popup を `popupWebViews` から除去
  2. `popupParents` から該当エントリを除去
  3. `viewModel.popupWebView` が同一インスタンスなら nil
  4. **popup に対して `loadHTMLString("", baseURL: nil)` 等で navigation を停止し、`navigationDelegate` / `uiDelegate` を nil にしてから解放する**（生きた delegate を残さない）
- `webViewDidClose` は「ページ側が閉じた場合」の入口として残してよいが、**唯一の cleanup 経路にしない**

### 2. 名前付き window の再利用を断つ

teardown で popup を確実に解放しても、CrewAccess 側が同名 window を参照し続ける可能性がある。取り込み成功後に **親 WebView 上で対象 window を明示的に閉じる** JS を実行することを検討する（`extractBlobFromURL` と同じ `evaluateJavaScript` 経路が使える）。これは `Unable to load report` の再発防止にも効く。

### 3. Preview presenter — 変更不要

上記の訂正のとおり、iPhone / iPad ともに `presentsImportPreview: true` で提示されている。**`RootTabView` の `!showingBrowser` ガードも `BrowserTabView` の提示条件も変更しないこと。**

### 4. 回帰テスト

Tony の指示どおり 2 本を追加する。**import state machine のレベル**（`importCrewAccessPDFData` を直接叩く形）で書けば device 不要で回せる。

| # | 内容 |
|---|---|
| T-26 | `Import A → confirm success → 直後に別内容の B を配送 → B の preview がちょうど 1 回出る`（アプリ再起動なし） |
| T-27 | `A → B → C` を 1 セッション内で連続実行。各 preview が 1 回ずつ、`importInProgress` / `pendingImport` / ledger が各回で正しく遷移する |

加えて **popup lifecycle 自体の回帰**を入れること。これがないと同じ形で再発する。

| # | 内容 |
|---|---|
| T-28 | PDF 取り込み **成功**後に `popupWebViews` と `popupParents` が空であること。失敗パス（fetch error / base64 decode 失敗 / JS error）でも同様に空であること |

T-28 が本 RCA の本体を守るテストである。T-26 / T-27 だけでは、import 層をテストするだけなので **popup leak を検出できない**。

---

## 変更してはいけないもの

- fingerprint ledger の抑止セマンティクス（active 無期限 / consumed・dismissed 120 秒）
- external-open queue / park の状態遷移
- import transaction と CloudKit の境界
- Phase 1〜3 の operational state / Live Activity 実装

本件は **browser presentation 層の欠陥**であり、Phase 2 で作った import transaction の正しさとは独立している。実際、Tony の報告でも import A 自体は 1 回で正常完了しており、RC-4 の修正は有効に機能している。
