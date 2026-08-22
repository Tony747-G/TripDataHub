# RCA v2 — Import Preview が閉じない / `Unable to load report` が残る

- 実機証拠: P-1 FAIL。Alert は中央に出て消えるが、**Import Preview が残る**。Timeline へ戻らない。同じ trip を再試行すると `Unable to load report, please close this tab and try again.` が再発
- 前提: popup lifecycle 修正（`docs/RCA_SEQUENTIAL_IMPORT_FAILURE.md`）適用済み
- **コード変更なし（調査のみ）**
- 注記: 添付の画面録画は PM 側で再生できていない。以下はコード解析に基づく。**§4 の判別手順で確定させること**

---

## 結論

**前回の popup RCA は正しかったが、観測症状の説明としては不完全だった。** 残っている失敗は **2 つの独立した欠陥**であり、popup lifecycle とは別物である。

| # | 欠陥 | 症状 |
|---|---|---|
| **F-1** | Import Preview の sheet 提示が **iPhone だけ一方向バインディング**。閉じるのは `dismiss()` 頼み | Alert 消滅後も Preview が残る |
| **F-2** | Swift 側の popup teardown では **CrewAccess の report session を解放できない**（`window.close()` を一度も呼んでいない） | 同じ trip の再 Print で `Unable to load report` |

---

## F-1 — Import Preview の dismissal が iPhone だけ `dismiss()` 依存

### 証拠

`pendingImport` の変化に対する 3 つの presenter の実装が**非対称**である。

| Presenter | 実装 | 方向 |
|---|---|---|
| `iPadOperationalWorkspaceView.swift:264` | `isShowingImportPreviewFromExternalOpen = newValue != nil` | **双方向** |
| `RootTabView.swift:146-150` | `if newValue != nil, !showingBrowser { ... = true }` | **true のみ** |
| `BrowserTabView.swift:74-78` | `if presentsImportPreview, newValue != nil { showingImportPreview = true }` | **true のみ** |

**iPad は `pendingImport` が nil になった時点で sheet が自動的に閉じる。iPhone は閉じる経路が `dismiss()` しか存在しない。**

`ImportPreviewView` の Alert action:

```swift
primaryButton: .destructive(Text("Replace and Import")) {
    Task {
        if await viewModel.confirmPendingImport(expectedReplacementIDs: ...) {
            dismiss()          // ← iPhone ではこれが唯一の閉じる手段
        }
    }
}
```

### なぜ Preview が残るのか（**PM 初版の因果説明は誤り。SWE 指摘により訂正**）

> **【訂正】** 初版は「invalidation の 2 秒を待っている**間に** `pendingImport` が nil になり `dismiss()` が失効する」と書いたが、**実行順序が違う。** `runReplacementDerivedStateInvalidationBestEffort()` は `pendingImport = nil` より**前**に完了している（`AppViewModel.swift:3238` → `:3252`）。この説明は成立しない。

実際の順序は次のとおり（`AppViewModel.swift:3238-3264`）。

```
runReplacementDerivedStateInvalidationBestEffort()   ← 最大 2 秒。ここは nil より前
        ↓
pendingImport = nil                                  （:3252）
importInProgress = false
crewAccessImportMessage = "CrewAccess import complete: ..."   （:3256）
        ↓
await rescheduleNotificationsIfAuthorized()          （:3258）★ここが本命
        ↓
transactionHandedToUpload = true / upload Task 発火
        ↓
return true
        ↓
ImportPreviewView 側で dismiss()
```

**`pendingImport = nil` と `return true` の間に `await rescheduleNotificationsIfAuthorized()` が挟まっている。** この内部は `UNUserNotificationCenter` の **timeout のないシステム呼び出し**の連続である。

- `getNotificationSettings`
- `getPendingNotificationRequests` / `getDeliveredNotifications`
- 有効な threshold × window の数だけ `center.add(request)`

この await の最中、状態は次のようになる。

1. `pendingImport` は **既に nil** → `ImportPreviewView` の body は `ContentUnavailableView("No Pending Import")` へ切り替わっている（`ImportPreviewView.swift:204-210`）
2. Alert は既に閉じている
3. **`dismiss()` はまだ一度も呼ばれていない**（`return true` に到達していないため）

**つまり `dismiss()` は「失効した」のではなく「まだ呼ばれていない」。** 画面録画の「Alert が消えて空の Preview が残る」は、**現行コードだけでそのまま説明できる。** SwiftUI の view identity や環境値の失効を持ち出す必要はない。

いずれにせよ **iPhone には `pendingImport` の nil を提示 state に反映する経路が存在しない**ため、この待ち時間がそのまま「Preview が残る」として見える。iPad は双方向バインディングなので nil の時点で閉じる。**対策（§5-1）は初版のままで正しい。**

### これは INV-005 違反である

同一機能の iOS / iPad 実装が異なり、**iPad だけが正しく動く**。INV-005（等価サーフェスの同期）が守られていれば発生しなかった。

---

## F-2 — `window.close()` を一度も呼んでいない

### 証拠

`closePopups()`（`BrowserWebView.swift:327-347`）が行うのは Swift 側の後始末だけである。

```swift
popup.stopLoading()
popup.navigationDelegate = nil
popup.uiDelegate = nil
popup.loadHTMLString("", baseURL: nil)   // ← 自分の WKWebView を空にするだけ
popupWebViews.removeAll()
popupParents.removeAll()
```

**CrewAccess の opener ページは `window.open()` の戻り値（window handle）を保持している。** こちらが WKWebView を破棄しても、opener 側の JS から見て「report window は開いたまま」である。`popupWebViews.isEmpty` は **アプリ内部の状態を語るだけで、ページ側の状態については何も保証しない。**

したがって `Unable to load report, please close this tab and try again.` は **cleanup 修正では原理的に解消しない。** これは前回の RCA が踏み込まなかった領域であり、当時は証拠がないため JS を撃たない判断をした。**今回「cleanup 後も再発する」という証拠が得られたので、この判断は見直す段階にある。**

### 追加の観測点

`Unable to load report` のページは **`text/html` であって `application/pdf` ではない**。したがって `decidePolicyFor navigationResponse` は `.allow` を返し、**成功・失敗いずれの teardown 経路にも入らない**（`BrowserWebView.swift:158-160`）。

このエラー popup は、ユーザーが Close を押すまで生き続ける。そして **F-1 で Import Preview が前面に残っていると、その Close に到達できない。** 2 つの欠陥が重なると詰みやすくなる。

---

## Tony の質問への回答

| 質問 | 回答 |
|---|---|
| `confirmPendingImport()` は成功を返すか | **コード上は成功パスで `return true`**（`AppViewModel.swift:3300`）。ただし実機で本当に到達したかは §4 で確定。失敗時は `importInProgress = false` にして `return false`（`:3301-3313`） |
| 成功後に `pendingImport` は nil になるか | **なる。** `self.pendingImport = nil` / `pendingImportFingerprint = nil` を成功パスで実行 |
| Import Preview の提示・解除を制御している state | **iPhone は `BrowserTabView.showingImportPreview`（`@State`）のみ。** これを false にする経路は `dismiss()` だけ。`pendingImport` の変化では false にならない ← **F-1 の本体** |
| browser sheet と Import Preview sheet の所有権競合 | **iPhone は競合なし**（`RootTabView` が `!showingBrowser` で抑止）。**iPad には潜在的な二重 presenter がある** — SWE 指摘により訂正。`iPadOperationalWorkspaceView:147` が `BrowserTabView(presentsImportPreview: true)` を提示し、同時に `:263-264` の `onChange` が**無条件**で自分の Preview sheet も true にする。iPhone にある `!showingBrowser` 相当の抑止が iPad にはない |
| popup cleanup が実機で到達しているか | **§4 のログで確定**。ただし F-1・F-2 はいずれも cleanup が正常に走っていても発生する |
| named window / session が生き残るか | **生き残る。** `window.close()` を呼んでいないため。§F-2 のとおり |
| cleanup 後も `Unable to load report` になる理由 | **Swift 側 cleanup と CrewAccess 側 session は別物だから。** 前者を完全にしても後者は解放されない |

---

## 4. 判別手順（実装前に確定させる）

### 4-1. 残っている Preview の中身（最優先・これだけで F-1 が確定する）

`Replace and Import` を押した後、画面に残っている Import Preview を見る。

| 表示 | 意味 |
|---|---|
| **`No Pending Import`**（書類アイコン ＋ "Start a CrewAccess import from the share sheet."） | **local commit は成功地点を通過し、`pendingImport` は nil になった。** ただし **`confirmPendingImport()` が true を返したことまでは証明しない**（notification reschedule で待機中の可能性）→ **F-1 で確定** |
| leg のリストが残っている | `confirmPendingImport` が false を返した → drift check か commit error。`crewAccessImportMessage` の内容を確認 |

> **【訂正】** 初版はこの表で「sheet の解除だけが失われた」と断定していたが、**`dismiss()` がまだ呼ばれていないだけ**の可能性が高い。上記のとおり `No Pending Import` の表示は nil 到達までしか証明しない（SWE 指摘）。

### 4-2. Timeline の実態

残った Preview を手動で閉じ（スワイプ）、Timeline を見る。**新しい trip が入っていれば import 自体は成功しており、純粋に提示層の欠陥。**

### 4-3. ログ

```
[Import] pendingImport set id=...
[Import] replacement derived-state seam completed        （または timed out）
```

> **【訂正】** 初版は `CrewAccess import complete: ...` を確認対象に挙げたが、**これは `logger` 出力ではなく `crewAccessImportMessage` への UI property 代入**（`AppViewModel.swift:3256`）であり、**Console には出ない**（SWE 指摘）。

seam の行の**後で処理が止まって見える**なら、`await rescheduleNotificationsIfAuthorized()` での待機が有力。

`closePopups()` には現在ログがないため、実機での teardown 到達・`popupWebViews` / `popupParents` の空を**直接証明できない**。実装時に開始・終了と tracked popup 数の診断ログを入れること。

---

## 5. 対策方針

### 5-1. F-1 — 提示 state を `pendingImport` から双方向に導出する（主対策）

- **`dismiss()` に依存しない。** `pendingImport` が nil になったら sheet が閉じる形にする
- `BrowserTabView.swift:74-78` を **iPad と同じ双方向**にする

  ```
  showingImportPreview = presentsImportPreview && (newValue != nil)
  ```

- `RootTabView.swift:146-150` も同様に、**nil になったら false を代入する**。`!showingBrowser` の抑止は true 側にのみ適用すること（このガード自体は正しいので残す）
- `ImportPreviewView` 側の `dismiss()` は残してよいが、**唯一の解除手段にしない**
- **3 presenter の実装を一致させること**（INV-005）。可能なら共通の modifier / helper に括り出す
- **iPad の二重 presenter も同時に解消する**（SWE 指摘）。`iPadOperationalWorkspaceView:263-264` は無条件に自分の Preview を true にしており、browser sheet から `BrowserTabView(presentsImportPreview: true)` が提示する Preview と二重になりうる。iPhone の `!showingBrowser` 相当の抑止を iPad にも入れるか、**どちらか一方の presenter に統一する**
- **`await rescheduleNotificationsIfAuthorized()` は transaction 側に残してよい**（T-7 の担保に必要）。UI の解除を `pendingImport` から導出すれば、通知の再スケジュール完了を待たずに閉じられる。**transaction の順序には手を入れないこと**

### 5-4. docs routing（PM の手落ち）

本書 `docs/RCA_V2_IMPORT_PREVIEW_STUCK.md` は現在 `docs/AI_CONTEXT_INDEX.md` から routing されていない。index の "Only the files listed in this index exist" と矛盾する。**実装フェーズで routing を追加すること**（Phase 0 で PM 自身が定めたルールの適用漏れ。SWE 指摘）。

### 5-2. F-2 — report window を CrewAccess 側でも閉じる

- teardown の前に、**popup 自身のコンテキストで `window.close()` を実行する**（`evaluateJavaScript("window.close()")`）。これは window 名を知らなくても実行でき、**前回「証拠がないので撃たない」とした JS とは別物**である
- 効かない場合の次段として、opener 側の handle を無効化する方法を検討する。ここは window 名の証拠が要るので、**実機で opener 側の JS を調査してから**
- あわせて、**`Unable to load report` のような非 PDF エラーページを表示した popup も teardown 対象に含めるか**を検討する（現状は `.allow` されて放置される）

### 5-3. テスト

| # | 内容 |
|---|---|
| T-29 | `pendingImport` が nil になったとき、**3 presenter すべて**で Import Preview の提示 state が false になる。`dismiss()` を呼ばない条件下で検証すること |
| T-30 | **`pendingImport` が nil になった後の `rescheduleNotificationsIfAuthorized()` を遅延させても、Preview が閉じる。**（SWE 指摘により訂正。初版の「seam の 2 秒 timeout」条件では今回の実行順序を再現できない。seam は nil より前に完了しているため） |
| T-31 | teardown 時に popup コンテキストで `window.close()` 相当が 1 回実行される（JS 実行を注入可能にして回数を検証） |

**T-29 が本 RCA の本体を守るテスト。** 「`dismiss()` が呼ばれたか」ではなく「**呼ばれなくても閉じるか**」を検証すること。

---

## 6. 変更してはいけないもの

- fingerprint ledger の抑止セマンティクス
- external-open queue / park の状態遷移
- import transaction と CloudKit の境界
- `RootTabView` の `!showingBrowser` **ガードそのもの**（true 側の抑止は正しい。false 代入を追加するだけ）
- 前回入れた popup teardown の集約（**あれは正しい。今回の 2 件とは独立した実在の leak を直している**）
