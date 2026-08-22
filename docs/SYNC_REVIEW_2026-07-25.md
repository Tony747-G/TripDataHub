# TripDataHub 同期レイヤ レビュー (2026-07-25)

対象: `AppViewModel.swift` の同期系、`DeviceScheduleCloudKitService`、`FriendScheduleCloudKitService`、
`CrewAccessImportCloudKitService`、`ScheduleCacheService`、`CalendarModels.swift` のマージ関数。

---

## 対応状況 (2026-07-25 更新)

初回レビューの指摘と、それに対する修正レビューでの追加指摘は下記のとおり全て対応済み。
残る唯一の未対応項目は public database からの移行で、これは独立フェーズとして扱う。

| 指摘 | 状態 | 対応 |
|---|---|---|
| unfriend が復活する | ✅ | `cancelFriendRequest` がレコード不在時も canceled レコードを作成。`restoreAcceptedLinkIfPossible` に `friendResetAt` ガード |
| 起動時にアップロードのみ無効化 | ✅ | identity 解決成功時に `recoverCloudSyncAfterIdentityAvailable` を再実行 |
| `refreshConnections` が all-or-nothing | ✅ | `withTaskGroup` + 各タスク内 catch でキャッシュ値を維持 |
| クライアント時計依存の Last Updated | ✅ | `record.modificationDate` を権威時刻に採用 |
| スナップショット全体 LWW | ✅ | ファイル層を権威とし、スナップショットは Timeline が空のときだけのフォールバックに降格 |
| ファイル mtime とクラウド時刻の比較 | ✅ | 比較を撤廃。空 Timeline 前提条件で置換 |
| `deviceID` がバックアップ復元で衝突 | ✅ | `identifierForVendor` 由来に変更 |
| `serverRecordChanged` 未処理 | ✅ | device / manual 両サービスにリトライ追加。manual は ID 単位マージ、device は意図的 LWW と明記 |
| `isDeviceSyncing` がネストに耐えない | ✅ | `deviceSyncActivityCount` でカウンタ化 |
| **`newerFriendSchedules` の id 重複 trap** | ✅ | 早期 return を撤廃し、全入力を同一マージ経路へ。片側が空でも重複を畳み込む |
| **復元パスが LogTen 参照時刻を戻さない** | ✅ | `restoreCrewAccessLegImportReferenceTimes` をフォールバック**実行前**に呼び、成功・失敗の両経路を保護 |
| **フォールバックの安全性が呼び出し側依存** | ✅ | `fetchLegacyDeviceScheduleFallbackIfNeeded` に改名し、空 Timeline 前提条件を関数内に内包 |
| public database の使用 | ⛔ 未対応 | 独立フェーズ。下記「移行方針」参照 |

### 実機テストで発覚した追加項目 (2026-07-25 第2次)

症状: 友達 GEMS7845209 の `Last Updated` だけが進み、スケジュール内容は古いまま。

| 指摘 | 状態 | 対応 |
|---|---|---|
| **`Last Updated` が「相手がアプリを開いた時刻」になっていた** | ✅ | `uploadSchedule` に content fingerprint。内容が同一なら save をスキップし `modificationDate` を進めない |
| 友達アップロードが端末同期と順序保証なしに走る | ✅ | `handleSchedulesChangedForSharing` が sharing 無効時に変更を保留し、`enableScheduleSharingForFriends` で replay |
| アップロード内容を検証するテストが皆無 | ✅ | fake に `uploadedSchedulesHistory` を追加し、内容ベースのテストを6件追加 |
| 友達リンク CKQuery 失敗が refresh 全体を中断 | ✅ | `cloudConnections` の失敗を捕捉し、既知の友達は record ID 取得で更新を継続 |
| 友達スケジュール取得失敗が成功表示になる | ✅ | レコード未作成だけを正常な空予定として扱い、実エラーはキャッシュを維持したまま `.failed` として返す |

`Last Updated` の根本原因は「サーバ更新時刻を UI に流用したこと」ではなく、
**`uploadSchedule` が無条件書き込みだったこと**。fingerprint を入れたことで
`record.modificationDate` は内容変更時のみ進むようになり、サーバ時刻を
そのままラベルに使える前提が成立した。UI 側の変更は不要。

---

## 総評

同期は3層に分かれている。

| 層 | 実体 | 収束性 |
|---|---|---|
| ファイル層 | `TDHCrewAccessImport` (1トリップ1レコード + `deletedAt` トゥームストーン) | ✅ 双方向収束する |
| 手動イベント層 | `TDHManualEventSnapshot` + `mergeManualEventSnapshots` | ✅ ID単位 LWW + トゥームストーンで収束する |
| スナップショット層 | `TDHDeviceScheduleSnapshot` (全予定を1レコードに丸ごと) | ❌ 全体 LWW。マージなし |

ファイル層と手動イベント層の設計は正しい。問題はスナップショット層と友達リンクの復活処理に集中している。

---

## 1. 同期失敗時にローカル予定と CloudKit を安全に保持できるか

### 良い点

- `performCrewAccessDeviceSync` (AppViewModel:1852) は fail-fast。ダウンロード失敗時に
  アップロードへ進まないので、「取得失敗 → 空でクラウドを上書き」という最悪ケースが構造的に起きない。
- `fetchDeviceScheduleIfNeeded` (:1359-1365) は `cacheService.save` を**先に**実行し、
  成功後に `crewAccessSchedules` を差し替える。書き込みが throw すればメモリ状態は無傷。
- `ScheduleCacheService.save` は `.atomic` 書き込み。部分書き込みでキャッシュが壊れない。
- アップロード失敗時に `lastDeviceScheduleUploadFingerprint` を更新しないので次回再試行される。
- テスト `test_syncCrewAccessDeviceData_importFetchFailure_preservesLocalAndSkipsSnapshot` /
  `..._snapshotFetchFailure_preservesLocalAndSkipsUpload` がこの不変条件を守っている。

### 問題

**[高] 起動直後はアップロードだけが黙って無効化される**

`AppViewModel.init` (:498-501):

```swift
await MainActor.run { self?.refreshCloudKitIdentity() }   // fire-and-forget、内部は最大5秒
await self?.recoverCloudSyncAfterIdentityAvailable(reason: "startup")
```

`refreshCloudKitIdentity()` は `Task.detached` を投げるだけで identity 解決を待たない。
そのため cold start では `currentCloudKitRecordName == nil` のまま同期が走る。

- `performDeviceScheduleUpload` (:1293-1295) — `currentCloudKitRecordName` 必須 → `return false`
- `performManualEventUpload` (:1423-1425) — 同上 → 何もせず return
- `fetchDeviceScheduleIfNeeded` (:1328) — `verifiedIdentity` のみ必須 → **動く**

つまり「ダウンロードは動くがアップロードは動かない」非対称な状態になる。
さらに identity 解決成功時のブランチ (:1743-1755) はログを出すだけで同期を再起動しない。
結果、CloudKit が遅い起動ではフォアグラウンド復帰までアップロードが一切走らない。

修正: identity 解決成功時に `recoverCloudSyncAfterIdentityAvailable(reason: "identity resolved")` を呼ぶ。

**[中] `fetchDeviceScheduleIfNeeded` の結果は直後に捨てられる**

`performCrewAccessDeviceSync` の順序は

1. `fetchCrewAccessImportFilesIfNeeded` — ファイルを同期
2. `fetchDeviceScheduleIfNeeded` — スナップショットで `crewAccessSchedules` を全置換
3. `applyCrewAccessRetentionPolicy` → `reconcileCrewAccessSchedulesWithImportFiles` (:2485) —
   **ローカルファイルから再構築して 2 の結果を上書き**

2 の状態代入は 3 で必ず消える。往復1回、`handleSchedulesChangedForSharing()`(友達アップロード誘発)、
`rescheduleNotificationsIfAuthorized()` を無駄に払っている。
結果的にファイル層が救済しているので実害は出にくいが、スナップショット層が単独で正しくない事実は隠れているだけ。

**[低] エラーがユーザーに見えない**

`fetchDeviceScheduleIfNeeded` の catch (:1376-1379) は `logNonFatal` のみで
`deviceSyncStatusMessage` を更新しない。ゲート3で棄却したときも `return true`(成功扱い)。
「同期したのに iPad の予定が来ない」が完全に無言になる。

**[低] `isDeviceSyncing` が Bool でネストに耐えない**

`fetchManualEventsIfNeeded` (:1456) が `isDeviceSyncing = true` にした状態で
内部から `uploadManualEventsIfNeeded` (:1485) を呼ぶ。内側の `defer` が先に `false` に戻すため、
外側がまだ実行中なのにスピナーが消える。カウンタにするべき。

---

## 2. 友達同期の再実行制御に競合や無限ループがないか

### 良い点 — coalescing 自体は正しい

`syncFriendCloudKit` / `uploadSharedScheduleIfNeeded` / `uploadDeviceScheduleIfNeeded` /
`fetchCrewAccessImportFilesIfNeeded` / `syncCrewAccessDeviceData` はすべて同じパターン:

```
in-flight なら needs=true にして return
in-flight ループ内で needs を拾って再実行
```

`@MainActor` なので `needs*=false` のクリアと `perform*` 内の状態読み取りの間に await がなく、
更新の取りこぼしは起きない。各周回は必ず実ネットワーク呼び出しを伴うが、fingerprint ガード
(`:1301`, `:1430`) が変化なしを no-op にするので有限回で終わる。**無限ループはない。**

RootTabView の `.onAppear` (:106) と `.onChange(scenePhase == .active)` (:120) が起動時に
両方発火するが、2本目は coalesce されるので二重実行にはならない。

### 問題

**[高] unfriend が復活する — 双方向の書き戻しループ**

1. 端末Aで `removeFriend` (:976) → CloudKit のリンクレコードを削除、ローカルからも削除。
   ただし `setFriendConnectionsResetAt` を**呼んでいない**(呼んでいるのは `deleteLocalProfileAccount`:5269 のみ)。
2. 端末Bはローカルに `acceptedAt` を保持したまま。次の `refreshConnection` (:463) でレコードが見つからず
   → `restoreAcceptedLinkIfPossible(canCreateAcceptedRecord: true)` (:640-680) が
   **ローカルの `acceptedAt` だけを根拠に accepted レコードを再作成**。
3. 端末Aの次回 `cloudConnections` (:410-427) が復活したレコードを拾う。
   `shouldKeepCloudLink` (:590) は `friendResetAt == nil` なので無条件 true → 友達が戻る。

`restoreAcceptedLinkIfPossible` は `friendResetAt` を引数に取っておらず、リセット判定を丸ごと迂回している。
`shouldKeepCloudLink` と `shouldReapplyLocalPendingApproval` にはリセットガードがあるのに、
この経路だけ抜けている。

修正案:
- `removeFriend` で `setFriendConnectionsResetAt(Date())`(または employeeID 単位のトゥームストーン)を記録
- `restoreAcceptedLinkIfPossible` に `friendResetAt` を渡し、`acceptedAt < friendResetAt` なら復元しない

**[中] `refreshConnections` が all-or-nothing**

`FriendScheduleCloudKitService:376-392` は `withThrowingTaskGroup`。友達1人分の refresh が
throw すると group 全体が throw → `refreshFriendSchedulesFromCloud` の catch に落ち、
**他の全友達の更新結果も破棄**され `saveFriendConnections()` もスキップされる。
ローカルは保持されるので危険ではないが、友達が増えるほど成功率が指数的に落ちる。

修正: `of: (Int, Result<FriendConnection, Error>).self` にして、失敗した要素だけ既存値を維持する。

**[低] 読み取り経路が毎回書き込む**

`refreshConnection` は `applyApproval` / `restoreAcceptedLinkIfPossible` /
`backfillFriendLinkMetadataIfNeeded` で CloudKit に save する。
同期トリガは 起動 onAppear / scenePhase.active / Friends タブ表示 / identity 検証 の4系統。
状態が変わっていないときは save をスキップする条件を足したい。

---

## 3. `Last Updated` で新しいスケジュールを選ぶ判断が妥当か

**判定: 妥当ではない。** 比較している2つの値の意味が違う。

`fetchDeviceScheduleIfNeeded` ゲート3 (:1345-1348):

```swift
let localMaxUpdatedAt = crewAccessSchedules.map(\.updatedAt).max()
if let localMax = localMaxUpdatedAt, snapshot.updatedAt <= localMax { return true }
```

| 値 | 実体 | 出所 |
|---|---|---|
| `snapshot.updatedAt` | **アップロードした端末の** `Date()` | `DeviceScheduleCloudKitService.swift:80` |
| `schedule.updatedAt` | **ローカルファイルの `contentModificationDate`** | `buildCrewAccessSchedule(from:modifiedAt:)` :4201, 4252 |

### 4つの具体的な欠陥

**(a) クライアント時計依存。サーバ時刻を使っていない**

CloudKit が付与する `record.modificationDate` があるのに、どこでも使わず自前の `Date()` を書いている。
iPad の時計が数分遅れていると、iPad のアップロードは**恒久的に「古い」**と判定され、
iPhone は iPad のデータを永久に無視する。しかもゲート3は `return true`(成功扱い)なので警告も出ない。
手動での時刻変更やタイムゾーン跨ぎの飛行が多い用途では現実的に起こる。

**(b) ファイル mtime はダウンロードでリセットされる**

`performCrewAccessImportFileFetch:1592` の `record.jsonData.write(to:)` でファイル mtime が「今」になる。
つまり同期直後は `max(local.updatedAt) ≈ now` で、そのデータを生成した当のスナップショットより新しくなる。
ゲート3は同期直後ほど「ローカル勝ち」に偏る。

**(c) `max()` 比較は集合の比較になっていない**

ローカルに1件だけ新しいトリップがあると、その端末が一度も見たことのないトリップを含む
リモートスナップショット**全体**が棄却される。トリップは互いに独立なので、
スナップショット単位の LWW は解決の粒度として誤っている。

**(d) 同じリポジトリ内に正しい実装がある**

- `mergeManualEventSnapshots` (`CalendarModels.swift:536`) — ID単位 LWW + トゥームストーン
- `deletedCrewAccessTripIntents` (`AppViewModel:1558-1588`) — トリップキー単位のトゥームストーン + タイムスタンプ

スナップショット層だけがこの設計から外れている。

### 推奨

1. 権威タイムスタンプを CloudKit の `record.modificationDate` に切り替える(表示用に `updatedAt` は残す)
2. `PayPeriodSchedule` にパース時刻 `importedAt` を持たせ、JSON 内に永続化する。ファイル mtime に依存しない
3. 全体 LWW をトリップキー単位のマージ(union + キー単位 LWW + トゥームストーン)に置き換える。
   もしくはスナップショット層を「ファイル層のキャッシュ」と割り切り、権威を持たせない

---

## 4. iPhone / iPad 間で双方向同期できるか

**層による。ファイル層と手動イベント層は双方向に収束する。スナップショット層は収束しない。**

### 良い点

- ファイル層はトリップ単位レコード + `deletedAt` トゥームストーンで、
  「片方で削除 / もう片方で再インポート」の難しいケースまでテスト済み
  (`AppViewModelDeviceSyncTests:241 / 307 / 354`)。ここは信頼できる。
- 手動イベント層は fetch → merge → 相手端末発なら再アップロード (:1484-1486)。
  fingerprint ガードで ping-pong が止まるので収束する。

### 問題

**[高] CloudKit の public database を使っている**

`ProfileCloudKitService:95` だけが `privateCloudDatabase`。それ以外は全て `publicCloudDatabase`:

- `DeviceScheduleCloudKitService:54, 171`
- `CrewAccessImportCloudKitService:65`
- `FriendScheduleCloudKitService:91`

レコード名は `tdh_device_schedule_<正規化GEMS_ID>` (`:102`) で、GEMS ID だけが鍵。
アプリの認証ユーザなら誰でも他パイロットのスケジュール・ホテル・クルーリストを読め、
さらに他人の `tdh_device_schedule_<GEMS_ID>` を**上書きできる**。
個人の端末間同期は private database、友達共有は shared zone が本来の置き場所。
同期の問題である以前に実運用データのプライバシー問題。**これが本レビューで最も重い指摘。**

**[中] 単一レコードへの同時書き込みに衝突処理がない**

iPhone と iPad が同じ `tdh_device_schedule_<GEMS_ID>` に `database.save(record)` する。
`savePolicy` 指定なし、`CKError.serverRecordChanged` のハンドリングなし
(`DeviceScheduleCloudKitService:83`、`ManualEventCloudKitService:200`)。
同時アップロードは「後勝ちで全消し」か「負けた側はログだけ出して黙って失敗」のどちらか。
`FriendScheduleCloudKitService:206, 297` にはリトライがあるので、同じ処理が必要。

**[中] `deviceID` がバックアップ復元で衝突しうる**

`getOrCreateDeviceID()` (:1675-1686) は UUID を UserDefaults に保存する。
UserDefaults は iCloud/iTunes バックアップに含まれるため、iPhone のバックアップから
iPad を復元すると**両端末が同じ deviceID を持つ**。
するとゲート2 (`snapshot.deviceID == myDeviceID → skip`, :1343) が常に成立し、
両端末が互いのアップロードを永久に無視する。`identifierForVendor` を種にするのが安全。

**[低] `DeviceScheduleSyncSource` が使われていない**

`.iphone` / `.ipad` を `userInterfaceIdiom` から判定して保存しているが (:1304, :1433)、
読み出しはログ出力 (:1374) のみで、いかなる判断にも使われていない。
iPhone 2台や iPad 2台は deviceID でしか区別できず、それで十分なので、この enum は削るか実際に使うか。

---

## 優先度順の推奨アクション

| # | 内容 | 影響 | 場所 |
|---|---|---|---|
| 1 | public database → private / shared database へ移行 | 他人のデータが読める・上書きできる | `DeviceScheduleCloudKitService:54,171` ほか |
| 2 | `removeFriend` にリセット時刻を記録、`restoreAcceptedLinkIfPossible` に `friendResetAt` ガードを追加 | unfriend が復活する | `AppViewModel:976`, `FriendScheduleCloudKitService:640` |
| 3 | identity 解決成功時に同期を再起動 | cold start でアップロードが走らない | `AppViewModel:1743-1755` |
| 4 | 権威タイムスタンプを `record.modificationDate` に変更 | 時計ズレでデータが永久に無視される | `DeviceScheduleCloudKitService:80`, `AppViewModel:1339,1347` |
| 5 | スナップショットをトリップキー単位マージに置き換え(または権威を外す) | 片方のトリップが取り込まれない | `AppViewModel:1345-1367` |
| 6 | `refreshConnections` を Result ベースにして部分失敗を許容 | 友達1人の失敗で全員分が破棄 | `FriendScheduleCloudKitService:376-392` |
| 7 | `serverRecordChanged` のリトライを device/manual サービスにも追加 | 同時書き込みで片方が消える | `DeviceScheduleCloudKitService:83,200` |
| 8 | `deviceID` を `identifierForVendor` 由来にする | バックアップ復元で同期停止 | `AppViewModel:1675` |
| 9 | `isDeviceSyncing` をカウンタ化、ゲート棄却時のユーザー通知を追加 | UX | `AppViewModel:1330,1376` |

### 追加されたテスト

- `test_newerFriendSchedules_collapsesDuplicateIDsWithoutTrapping` — 他端末由来の id 重複で trap せず、片側が空でも畳み込まれる
- `test_syncCrewAccessDeviceData_snapshotFetchFailure_restoresLogTenReferenceTimes` — 通信失敗で LogTen backlog が消えない
- `test_syncCrewAccessDeviceData_snapshotFetchSuccess_restoresLogTenReferenceTimes` — フォールバック**成功**時にも LogTen backlog が消えない
- `test_fetchLegacyFallback_neverOverwritesTimelineRebuiltFromFiles` — 非空 Timeline には適用されず、ネットワーク呼び出しにも到達しない
- `test_fetchLegacyFallback_doesNotCompareServerSnapshotToLocalFileTimestamp` — mtime 比較が復活していない
- `test_uploadThrowsRealErrorAfterRetryLimit` — リトライ枯渇時に成功を偽装しない
- `test_refreshConnections_doesNotRestoreAcceptedConnectionOlderThanReset` — リセット前の承認を復活させない
- `test_cancelFriendRequest_createsCancellationWhenCanonicalLinkIsMissing` — unfriend が相手端末で復活しない
- `test_refreshConnections_preservesOnlyFailedFriendAndKeepsOtherResults` — 部分失敗が全体を破棄しない
- `test_friendCloudKitUploadSchedule_skipsSaveWhenContentIsUnchanged` — 同一内容で `modificationDate` が進まない
- `test_friendCloudKitUploadSchedule_savesWhenContentChanges` — 内容が変われば確実に公開される
- `test_friendUpload_coalescedRequestPublishesSchedulesLoadedDuringUpload` — アップロード中に端末同期が完了したら新データが公開される
- `test_friendUpload_republishesScheduleChangeDeferredWhileSharingWasDisabled` — sharing 無効中の変更が捨てられない
- `test_friendUpload_publishesMergedSchedulesNotOnlyCrewAccess` — 公開されるのは merge 済み `schedules`
- `test_refreshConnections_degradesToRecordIDFetchWhenLinkQueryFails` — index 未デプロイでも既知の友達は更新される
- `test_refreshConnections_reportsScheduleFetchFailureAndPreservesCachedFriend` — 取得失敗時はキャッシュを維持しつつ赤ステータスになる

---

## CloudKit Production スキーマ確認 (コード変更では直せない項目)

`friendLinkRecords` は `TDHFriendLink` に対して `gemsA` / `gemsB` の等値クエリを投げる。
CloudKit Dashboard の **Production** 環境で以下を確認すること。

| Record Type | Field | 必要な index |
|---|---|---|
| `TDHFriendLink` | `gemsA` | Queryable |
| `TDHFriendLink` | `gemsB` | Queryable |
| `TDHFriendLink` | `recordName` | Queryable |

未デプロイでもアプリは動作を継続する（既知の友達は record ID 取得で更新される）が、
**新しい友達リンクの発見ができない**。Console に
`[TDHFriendLink] friend link query failed; refreshing known friends by record ID only:`
が出ていたら index 不足を疑う。

---

## 移行方針: public → private / shared database

唯一の未対応項目。現状は `ProfileCloudKitService` 以外の全レコードが `publicCloudDatabase` にあり、
GEMS ID を知る任意の認証ユーザが他パイロットのスケジュール・ホテル・クルーリストを読め、
`tdh_device_schedule_<GEMS_ID>` を上書きできる。単純に private へ切り替えると既存データが
見えなくなるため、段階移行が必要。

1. 個人データ（device schedule / manual events / import files）を private database へ二重読み込み付きで移行
2. **public 側レコードへの書き込みを read-only 化**（二重書き込み期間の不整合を避けるため 1 と 3 の間に置く）
3. 友達共有を CKShare へ移行
4. Production スキーマと権限を展開
5. 移行確認後に public 側の旧データを削除
