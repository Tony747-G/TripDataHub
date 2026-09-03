# 調査 + 設計 — CrewAccess Trip Details Auto-Print

- 日付: 2026-09-03
- スコープ: Trip Details → Print の**入口だけ**を自動化する。parser / import pipeline / ImportPreviewView は変更しない
- **本フェーズはコード変更なし**（調査と設計のみ）
- 対象 revision: `aaed6f0`（release 1.4.0 build 90）

---

## 0. 結論（先出し）

**Conditional GO。**

- Phase 0（DEBUG 限定の証拠採取、クリックは一切しない）と Phase 1（純粋ロジック + テスト）は **GO**
- Phase 3（実際に Print を自動実行する）は、Phase 0 の証拠が出るまで **NO-GO**

理由は §8 に記す。要点は 1 つで、**「Print control が、我々が script を流し込める document 内の同一 origin DOM 要素なのか」が未計測**である。ここが崩れると設計全体が成立しない。本リポジトリの運用ルール「証拠のない推測で外部システム（CrewAccess の JS）を触らない」がそのまま当てはまる。

---

## 1. Current-state analysis

### 1.1 Browser flow の構造

| 層 | 実体 |
|---|---|
| 入口 | `BrowserTabView`（iPhone: RootTabView の sheet / iPad: iPadOperationalWorkspaceView の sheet。両者とも `presentsImportPreview: true`） |
| WebView | `BrowserWebView`（`UIViewRepresentable`）が `https://fltops-portal.ups.com/` を load。`.id(browserResetID)` で reset 時に作り直す |
| Delegate | `BrowserWebView.Coordinator` が **main WebView と全 popup の `WKNavigationDelegate` / `WKUIDelegate` を兼ねる** |
| 状態 | `BrowserViewModel`（`@Observable`）。`webView` / `popupWebView` / `statusMessage` / `errorMessage` |
| 取り込み | `BrowserViewModel.handlePDFData` → `AppViewModel.importCrewAccessPDFData` → `pendingImport` → `ImportPreviewView` |

`makeUIView`（`BrowserWebView.swift:47`）が作る `WKWebViewConfiguration` には **`WKUserContentController` の user script も script message handler も存在しない**。現状 JS は `evaluateJavaScript` / `callAsyncJavaScript` の pull 型のみ。

### 1.2 `WKNavigationDelegate` / `WKUIDelegate` のライフサイクル

| コールバック | 行 | 挙動 |
|---|---|---|
| `createWebViewWith` | `:156` | `linkActivated` は main WebView に load して `nil` を返す。**JS 起点の `window.open()` のみ** `BrowserPopupWebView` を生成し、`popupWebViews` / `popupParents[popup] = parent` / `popupFocusAcquisitionStates` に登録、`viewModel.popupWebView` に載せて sheet 提示 |
| `didStartProvisionalNavigation` | `:204` | main のみ `isLoading = true` |
| `didFinish` | `:219` | main は `isLoading=false` / `currentURL` 更新。popup は `recordPopupNavigationCompleted` と DEBUG DOM sampling。**最後に main/popup 共通で `inspectCompletedPage`** |
| `didFail` / `didFailProvisionalNavigation` | `:240` / `:255` | status を networkError（`NSURLErrorCancelled` は無視） |
| `decidePolicyFor navigationResponse` | `:682` | `application/pdf` のみ分岐。https/http → cancel + cookie 付き `URLSession`。blob → cancel + `popupParents[webView] ?? webView` 上で `callAsyncJavaScript` により base64 化 |
| `decidePolicyFor navigationAction` | `:733` | 常に `.allow`（現状フックなし） |
| `webViewDidClose` | `:198` | ページ側 `window.close()` のときだけ発火 |

popup の focus 取得（`:334`）は **popup identity ごとに 1 回だけ**。`hasCompletedNavigation && attached && visible && !isResolved && !isFirstResponder` を全部満たしたときに `becomeFirstResponder()` を 1 回。失敗は log のみ。**この「identity ごとに 1 回、fail-closed、retry しない」形が、本件 auto-print guard の設計の手本になる。**

teardown（`closePopups()` `:859`）は generation 方式で、実行中の再入は coalesce される（`activePopupTeardownGeneration != nil` → 即 return）。各 popup に `window.close()` を投げ、750ms timeout で `finalizePopupTeardown`。成功パス（`finishPDFProcessing` `:843`）も失敗パス（`failPDFProcessing` `:851`）も必ずここを通る。

### 1.3 didFinish → import preview までの経路

```
didFinish(webView)                        BrowserWebView.swift:219
  └ inspectCompletedPage                  :273   evaluateJavaScript 1 回
       { pageText, hasPasswordField }
       → BrowserPageStatusClassifier.status(url:pageText:hasPasswordField:)
       → viewModel.statusMessage           （webView.url == completedURL のときだけ適用）

（ユーザーが Print をタップ）
  window.open() → createWebViewWith        :156   popup 生成 + sheet 提示
  popup didFinish → becomeFirstResponder   :334   Zero Trust の手動操作を不要にしている処理
  popup が PDF を開く
  decidePolicyFor navigationResponse       :682   mime == application/pdf
    blob: → extractBlobFromURL(parent)     :791
      → handleBlobExtractionResult         :819
        → finishPDFProcessing              :843   pdfDataHandler → closePopups()
          → BrowserViewModel.handlePDFData
            → AppViewModel.importCrewAccessPDFData   AppViewModel.swift:2921
              → ImportFingerprintLedger.claim
              → CrewAccessPDFImportService.analyzeTrip（detached task）
              → pendingImport = ...
                → BrowserTabView .onChange(pendingImport?.id)
                  → ImportPreviewPresentationPolicy.browserPreviewIsPresented
                    → ImportPreviewView
```

**`inspectCompletedPage` が、main / popup 双方で 1 navigation につき 1 回走る唯一の DOM 検査点**である。auto-print の判定はここに載せるのが自然で、Release 時の JS 往復回数も増えない。

### 1.4 現在の CrewAccess / Zscaler ページ判定

production にあるのは `BrowserPageStatusClassifier`（`BrowserViewModel.swift:19-45`）だけ。

- `unable to load report` を含む → `unableToLoadReport`
- URL に `/login` `/signin` `/sign-in` `/authenticate`、または password field、または明示 copy → `loginRequired`
- それ以外 → `pageLoaded`

**CrewAccess 固有の判定も、Trip Details 判定も、production には存在しない。**

### 1.5 DOM inspection 用 JavaScript の現状

| 用途 | 場所 | ビルド | 内容 |
|---|---|---|---|
| status 判定 | `inspectCompletedPage` `:273` | Release | `document.body.innerText` と password field の有無のみ |
| blob 取得 | `extractBlobFromURL` `:791` | Release | `fetch(blobURL)` → base64 |
| popup teardown | `closePopups` `:859` | Release | `window.close()` |
| perf 計測 | `installPopupPerformanceHooks` `:413` | **DEBUG のみ** | resize / focus / blur / visibilitychange / pointerdown、`MutationObserver`（250ms debounce + signature 比較）、`snapshot()` |

DEBUG の `snapshot()` が既に持っている指標が、そのまま Trip Details 判定の材料になっている点が重要:

- `tableCount` / `nonEmptyRowCount`
- `reportNamedContainerCount` と `reportCandidateTokens`（`trip_information` / `report` / `schedule` / `roster` / `print` などを id/class/name/src/href から検出）
- **`printControlCount`** = `button, input[type=button], input[type=submit], a` のうち `innerText || value || aria-label` に `print` を含むものの数
- `busyIndicatorCount` = `[aria-busy="true"], .loading, .spinner, [role="progressbar"]`
- `unableToLoadReport`

### 1.6 Print control detection の既存コード

**production には存在しない。** DEBUG の `printControlCount` が唯一で、これは**数を数えて log に出すだけ**。要素の特定も保持もしていない。

### 1.7 同一ページで didFinish / DOM mutation が複数回起きた場合

- `inspectCompletedPage` は **document 単位の guard を持たない**。didFinish のたびに走る。適用直前の `webView.url == completedURL` は staleness 検査であって重複実行の抑止ではない
- DEBUG の `MutationObserver` に 250ms debounce と signature 比較が入っていること自体が、**report の DOM は didFinish 後も変化し続ける**ことを開発チームが把握している証拠である
- SPA / partial update に対する production の対処は無い（現状 status を上書きするだけなので害が無い）

**auto-print はここが致命的になる。**didFinish 直後に発火すると、未完成の report を印刷する / `Unable to load report` を踏む可能性がある。

### 1.8 popup lifecycle / 重複 popup 防止

- 生成は `createWebViewWith` のみ。`popupWebViews` に追記、`viewModel.popupWebView` は**最新の 1 つだけ**が sheet に出る
- teardown は generation 方式で coalesce 済み。成功・失敗の両パスが `closePopups()` を通る（Build Week で修正済み）
- `webViewDidClose` はページ由来のみ

### 1.9 PDF dedup / fingerprint と auto-print の競合 — **重要な発見**

`importPayloadFingerprint`（`AppViewModel.swift:5107`）は **PDF バイト列の SHA-256 のみ**。`ImportFingerprintLedger` は `active` を無期限、`consumed` / `dismissed` を 120 秒抑止する。

ところが `sample_trip/*.pdf` 10 件を実測すると、印刷 PDF には**ブラウザの print chrome が焼き込まれている**:

```
1 行目 : 2/21/26, 2:09 PM                        ← 印刷時刻（印刷ごとに変わる）
最終行 : https://crewaccess.inside.ups.com/access/rs/reports/<uuid>/content/Trip_Information_A70651…
```

したがって **同一 Trip を 2 回印刷すると PDF のバイト列が変わり、SHA-256 も変わる。ledger は重複を抑止できない。**

> **結論: fingerprint / dedup 層は auto-print の暴走に対する防波堤にならない。guard は browser 層で完結させる必要がある。**

なお `importCrewAccessPDFData` は `pendingImport != nil` の間は `false` を返し `Another import is waiting for review.` を出すので、preview 表示中の追い撃ちは致命傷にはならない（ただし noise にはなる）。

### 1.10 手動 Print workflow を fallback として残せるか

**残せる。** auto-print は「既存の Print control に対して `click()` を 1 回投げる」だけで、既存 control も既存経路も一切書き換えない。auto-print が発火しなければ画面は今日とまったく同じであり、ユーザーは従来どおり手でタップできる。ここは設計上の必須要件として §4 / §5 に落としてある。

---

## 2. 外部システムについて分かっていること / いないこと

### 2.1 証拠のある事実

**A. Trip Details ページの URL 形（`sample_trip/*.pdf` 10 件の印刷 footer より）**

```
https://crewaccess.inside.ups.com/access/rs/reports/<uuid-36>/content/Trip_Information_<TripId>_…
```

10 件すべてでホスト・パス構造が一致。`<uuid>` は 10 件すべて異なる（= **report 生成ごとの ID であり、trip の安定 ID ではない**）。

**B. ページの内容（同上）**

- 見出し `Trip Information`
- `Date: 25Feb2026`
- `Trip Id: A70651 25Feb2026`
- leg テーブル `Day / Flight / Departure-Arrival / Start / Start(LT) / End / End(LT) / Block / A/C / Cnx / PNR / DH / Remark`
- `Duty totals` / `Hotel details` / `Crew: 1F/O  Base: ANC …` / `Crew on trip - (1)` / `Created 21Feb2026 05:09 (UTC) by …`

parser 側の期待（`CrewAccessPDFImportService.swift:512` の `Trip Id:` prefix、`:565` の leg 正規表現、`:1006` の `XXX-YYY` + `HH:MM` 判定）と一致する。**HTML と印刷 PDF はほぼ同じテキストを持つ**と考えてよい。

**C. Print は名前付き window を開く（`docs/RCA_SEQUENTIAL_IMPORT_FAILURE.md`）**

> CrewAccess の Print は `window.open()` で名前付きウィンドウを開く。同名の window が既に存在すると WebKit は `createWebViewWith` を呼ばずに既存 window へ navigate する。

**D. report window が開いたままだと CrewAccess は再発行を拒否する**（同 RCA）。`Unable to load report, please close this tab and try again.` が繰り返すほど悪化する。

C と D は auto-print の設計に直結する。**「開きっぱなしの window がある状態で Print を叩いてはいけない」**。

### 2.2 未計測（Phase 0 で確定させる）

| # | 未確定事項 | なぜ効くか |
|---|---|---|
| U-1 | Trip Details document は **main WebView と popup のどちらに載っているか** | 判定と click の対象 WebView が変わる。DEBUG DOM sampler が popup 限定で `trip_information` と `printControlCount` を見ている以上、**popup である可能性が高い**が、実ログは提示されていない |
| U-2 | Print control は **CrewAccess の DOM 要素か、Zscaler が注入した UI か** | 事実 C は「CrewAccess の JS が `window.open` する」と読めるが、`CrewAccessImportHelpView` の手順 6〜8 は「Zscaler アイコン → ハンバーガー → Print」という **Zscaler overlay** を指している。後者なら別 origin/別 frame で、`click()` は届かない |
| U-3 | report は **iframe の中か** | main frame の `evaluateJavaScript` からは見えない。見えないなら fail-closed で何も起きない（害はないが機能も成立しない） |
| U-4 | Trip Details と print window の origin 関係 | 同上 |

**U-2 が単独で GO/NO-GO を決める。**

---

## 3. Recommended detection strategy

### 3.1 原則

- **単一 selector 依存を作らない。** 複数シグナルの AND
- **`"Print"` という語の存在だけでは絶対に発火しない**（要件 1）
- **fail-closed。** 迷ったら何もしない。false negative（手で押す）は許容、false positive（勝手に印刷）は許容しない
- 判定は **Swift 側の純粋関数**に置く。JS は「観測値を返す」だけにして、判断ロジックを JS に散らさない（テスト可能性のため）

### 3.2 シグナル（すべて必須 = AND）

| ID | シグナル | 判定方法 |
|---|---|---|
| **R1** | URL | Swift の `URLComponents` で `host == "crewaccess.inside.ups.com"` かつ path が `^/access/rs/reports/[0-9a-fA-F-]{36}/content/Trip_Information_` に一致。**文字列 contains ではなく構造で判定する** |
| **R2** | ページ同一性 | `document.title` または最初の見出しが正規化して `Trip Information` |
| **R3** | Trip 識別子 | body テキストに `Trip Id:` 行があり、値が `^[A-Z0-9]{4,8}\s+\d{2}[A-Za-z]{3}\d{4}$`（例 `A70651 25Feb2026`）。ここから `tripId` と `tripDate` を取り出す |
| **R4** | 表構造 | `table` が 1 つ以上、かつ leg アンカー行（`[A-Z]{3}\s*[-–—]\s*[A-Z]{3}` と `\d{2}:\d{2}` を同一行に含む `tr`）が 1 つ以上。parser の `:1006` と同じ意味論 |
| **R5** | readiness | `document.readyState === 'complete'`、busy indicator 0 件、body に `unable to load report` を含まない |
| **R6** | 実行可能性 | Print control 候補が**ちょうど 1 つ**に解決できる（§5.3） |

R1〜R4 が「これは Trip Details である」、R5 が「もう印刷してよい」、R6 が「押せる対象がある」。**1 つでも欠けたら何もしない。**

R1 が外れて R2〜R4 が揃うケース（URL 形が将来変わった等）は、v1 では**発火させない**。DEBUG log にだけ `urlMismatch` として残し、証拠が溜まってから緩める。

### 3.3 readiness の再評価（§1.7 への対処）

didFinish 単発では足りない。**document identity ごとに、上限付きで再評価する。**

- 評価タイミング: didFinish 直後、以後 500ms 間隔
- 上限: 20 回（約 10 秒）
- 中断条件: `webView.url` が変わった / WebView が解放された / teardown 開始 / `pendingImport != nil` / 可視 popup が入れ替わった / 判定が確定した
- 上限到達 = **静かに諦める**（status も変えない。手動 Print は生きている）

これは Release でも走るが、**「Trip Details 候補の document が開いている間だけ、最大 10 秒」**に限定される。Build Week で確立した「Release で 1Hz の `evaluateJavaScript` ポーリングを走らせない」保証は維持される（`[BrowserPerf]` の常時ポーリングは DEBUG のまま）。

### 3.4 実装位置

`inspectCompletedPage`（`:273`）の script を**1 本のまま拡張**し、既存の 2 キー（`pageText` / `hasPasswordField`）はそのまま返し、新しいキーを足す。新しい部分は IIFE 内で `try/catch` し、失敗時は `null` を返す。

- JS 往復が増えない
- status 判定の入力が変わらない = 既存挙動が変わらない
- 判定経路が 2 本に分裂しない

これが §5「既存 pipeline を変えない」に対する**唯一の意図的な例外**である（理由は上記 3 点）。

---

## 4. Recommended duplicate-execution guard

### 4.1 guard key の候補比較

| 候補 | 同一表示の再 didFinish | reload / back-forward | 同一 trip 再オープン | 別 trip | 判定 |
|---|---|---|---|---|---|
| URL 全体 | 抑止 ○ | 抑止 ○ | uuid が変われば通す | 通す | 単体でも悪くない |
| Trip ID のみ | 抑止 ○ | 抑止 ○ | **抑止してしまう** | 通す | 却下（in-progress trip の再取り込みを塞ぐ） |
| DOM 由来 ID のみ | 抑止 ○ | 抑止 ○ | 抑止 | 通す | 単体では不足 |
| navigation generation | 抑止 ○ | **通す（暴発）** | 通す | 通す | 却下 |

### 4.2 採用案

```
key = "\(tripId)|\(tripDate)|\(reportUUID)"
```

- `tripId` / `tripDate` は **R3 の DOM 由来**（人間が見ている trip の同一性）
- `reportUUID` は **URL path 由来**（report 生成の同一性）

同一表示内の didFinish 連打・DOM mutation・reload・back/forward は URL も DOM も同じなので抑止される。ユーザーが意図的に同じ trip を開き直した場合は新しい report が発行されるので `reportUUID` が変わり、**再度 auto-print される** — これは「ユーザーが再取り込みを望んで開き直した」と解釈するのが妥当。ただし暴発保険として下の G2/G3 を必ず併用する。

key は **Coordinator が所有**し、`BrowserViewModel.prepareForBrowserReset()` 経由の browser reset で消える（`BrowserWebView` が `.id(browserResetID)` で作り直されるため自然に消える）。

### 4.3 併用する 4 つのインターロック

§1.9 のとおり fingerprint ledger は当てにできないので、browser 層で多重化する。

| ID | 内容 | 推奨値 |
|---|---|---|
| **G1** | in-flight lock。auto-print は同時に 1 つだけ | — |
| **G2** | cooldown。直前の auto-print から一定時間は key を問わず発火しない | 20 秒 |
| **G3** | session cap。1 BrowserWebView インスタンスにつき上限回数 | 5 回 |
| **G4** | 事前条件。以下を全部満たすときだけ発火 | — |

G4 の事前条件:

1. `activePopupTeardownGeneration == nil`（teardown 実行中でない）
2. 対象 WebView が**現在可視**である（popup なら `viewModel.popupWebView === popup`、main なら popup sheet が出ていない）— 既存 focus 取得の事前条件と同じ形
3. 対象以外の live popup が存在しない（**事実 C/D 対策。開きっぱなしの window があるときに Print を叩かない**）
4. `viewModel.appViewModel?.pendingImport == nil`（read-only 参照のみ。`importInProgress` は private なので触らない）

**key の消費は click を投げる前に行う（optimistic marking）。** click が失敗しても再試行しない。fail した = 手動 fallback、が本設計の一貫した態度である。

---

## 5. Proposed implementation design

### 5.1 新規ファイル（純粋ロジック、WebKit 非依存）

`TripDataHub/Services/CrewAccessTripDetailsDetector.swift`

```
struct CrewAccessTripDetailsSignals   // JS の戻り値を decode したもの
    url, title, tripIdLine, tableCount, legAnchorRowCount,
    busyIndicatorCount, unableToLoadReport, readyState,
    printControlCandidateCount, printControlToken

enum CrewAccessAutoPrintDecision
    case notTripDetails(reason)
    case notReady(reason)
    case ambiguousPrintControl(count)
    case suppressed(reason)          // guard により抑止
    case fire(AutoPrintTarget)       // tripId, tripDate, reportUUID, printControlToken

enum CrewAccessTripDetailsDetector
    static func decide(url: URL?, signals: Signals) -> Decision   // R1〜R6

struct CrewAccessAutoPrintGuard       // key set / cooldown / cap / in-flight、clock 注入
    mutating func admit(key:, now:) -> Bool
    mutating func complete(key:)
    mutating func reset()
```

判断ロジックは全部ここ。WebKit も UI も不要なので、synthetic fixture で完全にユニットテストできる。

### 5.2 Coordinator への配線

- `inspectCompletedPage` の script を §3.4 のとおり拡張
- 新規 `private func evaluateAutoPrintIfNeeded(_ webView:, completedURL:, attempt: Int)` — 判定 → guard → 発火 or 再評価スケジュール
- 新規 logger category `[AutoPrint]`（`[BrowserPopup]` と同じく Release にも残す）。`decision` / `reason` / `attempt` は `.public`、**`tripId` と URL は `.private`**（乗員データ）
- テスト seam: 既存の `javaScriptEvaluator` / `popupFocusAcquirer` / `popupAttachmentChecker` と同じ形で `printControlInvoker` と `clock` を `init` に注入する

### 5.3 Print control の解決（fail-closed）

JS 側:

```
候補   : a, button, input[type=button], input[type=submit], [role=button]
label  : (innerText || value || aria-label || title) を正規化
採用   : label が /^print( trip)?$/i に完全一致
可視   : getClientRects().length > 0
有効   : disabled でない / aria-disabled でない
```

**候補が 0 個または 2 個以上なら `ambiguousPrintControl` として何もしない。** 「print」を含むだけの要素（`Printer settings` 等）は完全一致条件で落ちる。

同時に安定 token（tagName + id/class の hash + 候補内 index）を返し、**click 時に同じ resolver で解決し直して token が一致した場合のみ click する**。判定と実行の間に DOM が変わったケースを弾くため。

### 5.4 Trigger

```js
const el = resolvePrintControl(expectedToken);
if (!el) { return 'ERR:not-found'; }
el.click();
return 'OK';
```

**`element.click()` のみを使う。** サイト側の onclick / href / form submit の既存挙動をそのまま起動できるからで、これが要件「既存サイトの挙動をなるべくそのまま利用する」に最も忠実。

**使ってはいけないもの:**

- `window.print()` — Zscaler の経路を迂回する可能性があり、既存 pipeline の前提を壊す
- 合成タッチ（`dispatchEvent(new TouchEvent…)`）
- `window.focus()` / `document.body.focus()`

後ろ 2 つは技術的な理由に加えて、**既存の source-guard テストが `BrowserWebView.swift` にこれらの文字列が現れないことを assert している**（`ExternalOpenImportCoordinatorTests.test_debugFocusPulseUsesOneUIKitMethodAndDoesNotAddProductionWorkaround`）。実装時に踏むと即座に赤くなる。

### 5.5 feature flag

Settings → CrewAccess Import に `Auto Print Trip Details` トグルを置く（既定 ON）。実運用で問題が出たときに**再ビルドせずに従来動作へ戻せる**ことが目的。INV-005 により iOS / iPadOS 両サーフェスに入れる（`BrowserTabView` は共有なので browser 側の分岐は不要）。

### 5.6 既存 pipeline への変更

| 対象 | 変更 |
|---|---|
| popup handling / Zero Trust workaround | **変更なし** |
| PDF detection / blob extraction | **変更なし** |
| CrewAccess PDF parser | **変更なし** |
| fingerprint / dedup | **変更なし** |
| ImportPreviewView presentation | **変更なし** |
| `inspectCompletedPage` の script | **拡張する**（唯一の例外。理由は §3.4） |

### 5.7 フェーズ分割

| Phase | 内容 | 出口条件 |
|---|---|---|
| **0** | **DEBUG 限定の証拠採取。クリックは一切しない。** main / popup 双方の didFinish で、URL 形・`readyState`・title・`Trip Id:` 行の有無・table / leg 行数・print 候補の tagName と label と数・`window.frames.length`・自 document が iframe 内かを log | 実機の実 trip 3 本で U-1〜U-4 が確定 |
| **1** | 純粋ロジック（detector + guard）とユニットテストのみ。配線しない | §7 A-1〜A-12 が緑 |
| **2** | 配線 + feature flag。ただし **dry-run モード**で「発火したはず」を log に出すだけ | 実機で誤検知ゼロ、取りこぼしゼロ |
| **3** | 実行を有効化 | §7 D-1〜D-8 |

**Phase 0 と Phase 1 は同一 PR に混ぜない。**（Build Week の教訓: Phase 承認ごとに commit する）

---

## 6. Risks / edge cases

| # | リスク | 影響 | 対処 |
|---|---|---|---|
| **1** | Print control が Zscaler 注入 UI / 別 origin frame | **設計が成立しない** | Phase 0 で確定。cross-origin なら NO-GO。合成タッチで回避しようとしない |
| **2** | 名前付き window の衝突 / stale popup（事実 C・D） | `Unable to load report`、繰り返すほど悪化 | G4-3（他の live popup がないこと）、G4-1（teardown 中でないこと）、G2 cooldown、G3 cap |
| **3** | **重複 auto-print を ledger が抑止できない**（§1.9） | Import Preview が繰り返し出る | guard を browser 層で完結。optimistic marking |
| **4** | 発火が早すぎて未完成の report を印刷 | parser エラー / 白紙 / `Unable to load report` | R5 readiness + §3.3 の bounded 再評価 |
| **5** | didFinish 多重発火 / back-forward / SPA 部分更新 | 二重印刷 | key が同一 → 抑止 |
| **6** | report が iframe 内 | 検出できず auto-print されない | fail-closed。既存挙動に影響なし。Phase 0 で計測 |
| **7** | 他の CrewAccess report（`/content/` 配下の別レポート） | 誤発火 | R1 が `Trip_Information_` prefix を要求、R3 が Trip Id 行を要求 |
| **8** | Zscaler の再認証 / MFA が挟まる | — | URL が一致しないので発火しない |
| **9** | ユーザーが同時に手で Print を押す | print window が 2 つ | 事実 C により同名 window は既存へ navigate（既存挙動のまま）。G2 で自動側の追い撃ちは防ぐ |
| **10** | Release での JS ポーリング増加 | 電池 / 体感 | 対象 document が開いている間の最大 10 秒に限定。`[BrowserPerf]` は DEBUG のまま |
| **11** | source-guard テストへの抵触 | ビルド緑のまま設計違反、または即赤 | §5.4 の禁止文字列、既存 perf hook 文字列と `trip_information_<redacted>.html` の維持 |
| **12** | ログに乗員データが載る | プライバシー | tripId / URL は `.private`。Release で完全 URL を出さない |
| **13** | INV-005（iOS/iPad 同期） | 片側だけ改善 | `BrowserTabView` は共有。Settings トグルは両方に入れる |
| **14** | `inspectCompletedPage` 拡張が status 判定を壊す | status バーの regression | 既存キーを変えない。新規部分は IIFE 内 `try/catch` で `null` を返す |

---

## 7. Test plan

### A. ユニット（純粋、WebKit 不要）— `TripDataHubTests/CrewAccessAutoPrintTests.swift`

| ID | 検証 |
|---|---|
| A-1 | 正常な Trip Details signals → `fire`（合成 tripId を使用。実データを fixture にしない） |
| A-2 | host / path が違う（fltops-portal、別レポート種別）→ `notTripDetails` |
| A-3 | **`Print` という語だけがあり Trip Id も table も無い → `notTripDetails`**（要件 1 の直接検証） |
| A-4 | `Trip Id:` 行の形式が不正 → `notTripDetails` |
| A-5 | busy indicator あり / `readyState != complete` / `unable to load report` → `notReady` |
| A-6 | print 候補が 0 個 / 2 個以上 → `ambiguousPrintControl` |
| A-7 | 同一 key で 2 回目 → `suppressed` |
| A-8 | 同一 trip・別 reportUUID → cooldown 内なら `suppressed`、cooldown 後は `fire` |
| A-9 | session cap 超過 → `suppressed` |
| A-10 | in-flight 中 → `suppressed` |
| A-11 | browser reset 後は guard が空 |
| A-12 | `pendingImport != nil` の間は `suppressed` |

### B. Coordinator（既存の注入 seam を踏襲）

| ID | 検証 |
|---|---|
| B-1 | 同一 document で didFinish が 3 回発生しても invoker は**ちょうど 1 回**呼ばれる |
| B-2 | teardown 実行中は呼ばれない |
| B-3 | 対象が可視 popup でないときは呼ばれない |
| B-4 | invoke 失敗時に再試行せず、popup / import の状態を触らない |

**B-1 と B-4 は「呼ばれたか」ではなく「呼ばれなくても既存フローが成立するか」を見る形で書く**（T-29 と同じ方針）。

### C. source-guard（本リポジトリの慣行に合わせる）

| ID | 検証 |
|---|---|
| C-1 | `BrowserWebView.swift` が `window.print()` / `dispatchEvent(new TouchEvent` / `window.focus()` / `document.body.focus()` を含まない |
| C-2 | 既存 perf hook 文字列と `trip_information_<redacted>.html` が残っている（既存テストの再実行） |

### D. 実機（実 CrewAccess、異なる 3 trip）

| ID | 検証 |
|---|---|
| D-1 | trip A を開く → **追加タップなし**で Import Preview が出る → Confirm |
| D-2 | 続けて trip B → Preview は 1 回だけ。`[BrowserPopup] teardown complete … tracked=0` |
| D-3 | trip A を cooldown 内に開き直す → auto-print しない。**手動 Print は従来どおり動く** |
| D-4 | roster / ホーム / ログイン画面 → auto-print しない（log は `notTripDetails`） |
| D-5 | report 読み込み中に通信断 → auto-print しない、ハングしない、手動は生きている |
| D-6 | トグル OFF → 今日とまったく同じ挙動 |
| D-7 | 連続 3 回取り込み → `Unable to load report` が出ない |
| D-8 | iPad サーフェスで D-1〜D-3 が同一（INV-005） |

---

## 8. GO / NO-GO

### **Conditional GO**

| 対象 | 判定 |
|---|---|
| Phase 0（DEBUG 証拠採取、クリックなし） | **GO** |
| Phase 1（純粋ロジック + テスト、未配線） | **GO** |
| Phase 2（配線 + dry-run log） | Phase 0 の証拠が出てから **GO** |
| Phase 3（実行有効化） | **現時点では NO-GO** |

### 根拠

**GO 側:**

1. 判定材料は十分に強い。URL 形（実サンプル 10 件で一致）、`Trip Id:` 行、leg テーブル、ページタイトルの 4 つが独立に効き、単一 selector 依存にならない
2. 挿入点が既に 1 箇所に存在する（`inspectCompletedPage` が main / popup 共通で 1 navigation につき 1 回）。新しい観測経路を作らずに済む
3. 「identity ごとに 1 回・fail-closed・retry しない」という設計の手本が同じファイルに既にある（popup focus acquisition）。同じ形で書ける
4. 既存 pipeline への変更が実質ゼロで、失敗時は今日の手動フローがそのまま残る
5. 判定と guard を純粋関数に切り出せば、実機なしで大半を検証できる

**NO-GO（Phase 3）側:**

1. **U-2 が未計測。** Print control が Zscaler 注入 UI や別 origin frame にあるなら、`click()` は届かず、届かせるには合成タッチしかない。それは既存 source-guard テストが明示的に禁じている手段であり、Build Week で「証拠が出てから実装する」と決めた領域そのもの
2. **fingerprint ledger が重複印刷を抑止できない**（§1.9 は本調査で新たに判明した事実）。auto-print の guard に穴があると、ユーザーには Import Preview の連発として現れる。browser 層 guard だけが防波堤である以上、実装前に guard の単体検証を通しておく必要がある
3. **事実 C・D により、Print を叩くタイミングを誤ると `Unable to load report` に落ちる。**しかもこの障害は繰り返すほど悪化する。自動化はこの誤爆確率を上げる方向に働く

### Kill criterion

Phase 0 の結果、**Print control が cross-origin frame / Zscaler 注入 UI であることが判明した場合は NO-GO で確定**し、`docs/FOLLOW_UPS.md` に `deferred` として証拠つきで記録する。合成タッチや `window.print()` での迂回は試みない。

### Phase 0 で埋めるべき表（実機 3 trip）

| 項目 | trip 1 | trip 2 | trip 3 |
|---|---|---|---|
| Trip Details の host（main / popup） | | | |
| URL が R1 に一致するか | | | |
| `document.title` | | | |
| `Trip Id:` 行の有無 | | | |
| table 数 / leg アンカー行数 | | | |
| print 候補数と label と tagName | | | |
| 自 document が iframe 内か / `window.frames.length` | | | |
| didFinish から R5 成立までの経過時間 | | | |
| didFinish の発火回数 | | | |

この表が埋まった時点で、Phase 2 以降を再判定する。

---

## 9. Phase 0 実装メモ（branch `feature/crewaccess-auto-print`）

**observational only。** click / focus / submit / synthetic event は一切入っていない。production 挙動は変わらない。

### 入っているもの

| 場所 | 内容 |
|---|---|
| `BrowserWebView.swift` file scope（`#if DEBUG`） | `browserProbeLogger`（category `AutoPrintProbe`）と `CrewAccessPageProbe`（`PageKind` 判定 / `urlShape` 秘匿化 / `resampleIntervals` / `probeExpression` JS） |
| `Coordinator.pageInspectionScript()` | 既存 script を 1 本のまま生成。**Release は従来と 1 文字も変わらない 2 フィールド**。DEBUG のみ `probe` を追加 |
| `Coordinator.inspectCompletedPage` | 既存 3 行は不変。末尾に `#if DEBUG` の 1 ホップだけ追加 |
| `Coordinator`（`#if DEBUG`） | `beginCrewAccessProbe` / `scheduleCrewAccessProbeResample` / `logCrewAccessProbeSample` / `describeProbeElement` |
| `finalizePopupTeardown`（`#if DEBUG`） | teardown 時に probe の sequence を破棄 |

再サンプルは didFinish の +1s / +3s / +6s / +10s の 4 回で打ち止め。新しい navigation・teardown 開始・URL 変化・WebView 解放のいずれかで即中断する。

### 所有権の契約（診断は対象より長生きしない）

- 遅延実行される probe closure は **すべて `[weak self, weak webView]`**。強参照は 1 つも残さない
- pending task は `crewAccessProbeTasks: [ObjectIdentifier: Task<Void, Never>]` に登録する。**キーは `ObjectIdentifier` なので registry 自体が WebView を retain しない**。所有方向は Coordinator → Task の一方向のみ
- `closePopups()` は teardown 開始直後に対象 popup の task を **cancel** する。`Task.sleep` は cancel で即座に復帰するので、pending 診断はスケジュール終了を待たずにその場で無害化される。`finalizePopupTeardown` でも再度 cancel する
- probe は Coordinator が現に所有している WebView（main WebView か tracked popup）に対してのみ schedule される。teardown で外れた popup は次の wake で即 exit する
- 回帰テスト: `test_phase0DelayedProbeWorkUsesWeakOwnership` / `test_phase0PopupTeardownMakesPendingProbeWorkHarmlessImmediately` / `test_phase0PendingProbeDoesNotExtendCoordinatorLifetime`

### 採取される情報

- **surface**: `main` / `popup`、可視かどうか、同一 URL で didFinish が何回起きたか
- **document**: `readyState` / title / origin / **iframe の中かどうか** / `window.top` が同一 origin か / frame 数
- **frame ごと**: src origin、**`contentDocument` に到達できるか（= same-origin か）**、内側の print 候補数
- **injection の痕跡**: `script[src]` / `link[rel=stylesheet]` の origin 一覧、`zscaler|zpa|zia|zsc-` を含む id/class/src/href の数とサンプル
- **shadow DOM**: open shadow root の数。候補走査は shadow root の中も対象
- **ページ種別**: table 数 / leg 行数 / `Trip Id:` 行の有無 / `Trip Information` 見出し / roster マーカー / `unable to load report` / busy indicator
- **候補要素ごと**: root（document か shadow か）、tagName、type、id、class、role、label、value、aria-label、title、href、target、**onclick 属性の有無と本体**、**onclick プロパティの有無**、form action / method、disabled、tabIndex、可視性、bounding rect、`printMatch`（`exact` / `label-substring` / `identity-substring`）

### 秘匿化

- URL は scheme + host + path のみ。report UUID は `<uuid>`、4 桁以上の数字は `<n>`。**query は名前だけで値は一切出さない**
- JS が返す文字列はすべて空白正規化 + 4 桁以上の数字マスク + 60 文字切り詰め
- cookie / localStorage / sessionStorage / indexedDB / 認証ヘッダには一切触れない

### 実機で採取するログ

1. Xcode で **Debug** ビルドを実機にインストール（`AutoPrintProbe` は Release には入らない）
2. Console.app（またはデバイスを接続した Xcode の Console）で `subsystem: com.sfune.TripDataHub` を絞り込み、`AutoPrintProbe` と `BrowserPopup` の両方を残す
3. Browser タブで CrewAccess にサインイン → Roster → Trip Id / Detail → **Print を手で押す** → Import Preview まで通常どおり完了させる
4. これを**異なる 3 trip** で繰り返す

読む順序:

- `printElements=` が **0 でない sample の `surface=`** → Trip Details がどこに載っているか（U-1）
- その sample の `printElement[n] tag= id= class= href= hasOnclickAttribute= onclickAttribute= hasOnclickProperty= root=` → **Print が CrewAccess の DOM 要素か**（U-2）
- `printElements=0` のまま手動 Print が動くなら、`inFrame=` / `frameCount=` / `frame[n] sameOriginAccessible=` / `vendorMarkers=` / `scriptOrigins=` を見る → **Zscaler 注入 UI / cross-origin**（U-2 が NO-GO 側）
- `attempt=` の推移で `readyState` / `busy=` / `printElements=` が確定するまでの時間（R5 の待ち時間の実測値）
- `didFinishCount=` → 同一ページで didFinish が何回起きるか（guard の必要性の実測）

§8 の表はこのログから埋める。
