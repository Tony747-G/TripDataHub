# Internal JSON Export Investigation (Debug-only)

Investigation notes and a temporary debug export mechanism for inspecting **everything
the app currently knows about one trip**, to inform the design of a future public
"Export JSON" schema. See `docs/CLOUDKIT.md` for the general CloudKit record catalog.

## Three separate concepts — do not conflate them

1. **CloudKit synchronization JSON** — the existing `[PayPeriodSchedule]` payload stored
   in `TDHSharedSchedule.schedulesData` (and mirrored to `TDHDeviceScheduleSnapshot`),
   produced by `try JSONEncoder().encode(schedules)` in
   `FriendScheduleCloudKitService.uploadSchedule` / `DeviceScheduleCloudKitService.uploadDeviceSchedule`.
   Small, stable-ish, byte-exact, and already shipping.
2. **Raw trip snapshot (`TripRawDebugSnapshot`)** — the debug-only diagnostic aggregate
   this document describes. It is **not** the CloudKit payload and **not** a stable or
   public schema. It over-collects everything reachable for one trip, on purpose, so a
   human can look at it and decide what belongs in a future public export.
3. **Public Export JSON** — not part of this task. Will later be explicitly selected and
   transformed from the raw snapshot and the domain models, with deliberate field
   naming/normalization decisions. Do not treat anything below as that schema.

## Why the CloudKit payload is not a complete trip snapshot

`schedulesData` only contains `PayPeriodSchedule`/`TripLeg`/`OpenTimeTrip` — a thin,
already-normalized slice. Tracing the Import Preview and Timeline rendering code paths
shows the app holds materially more data about a trip than that payload carries:

- The richer parser-time DTO (`CrewAccessTripJSON`/`CrewAccessTripItemJSON`), which
  includes `dutyTotals`, `hotelDetails`, `crew`, `mappingVersion`, etc. — persisted to
  `Documents/CrewAccessImports/*.json` but never uploaded to CloudKit.
  `TripDataHub/Services/CrewAccessPDFImportService.swift:107-219`.
- Import provenance (`sourceFileName`, `createdAt`, parse warnings/errors, extract
  stats) — held on `PendingImport` (`CrewAccessPDFImportService.swift:22-37`), never
  synced anywhere.
- Airport/timezone metadata resolved separately at render time by
  `IATATimeZoneResolver` (`TripDataHub/Services/IATATimeZoneResolver.swift`) — a static
  lookup table, not stored per-trip.
- Manual events (`ManualOperationalEvent`/`ManualPersonalEvent`,
  `TripDataHub/Models/CalendarModels.swift:292,467`) rendered alongside trips on the
  real Timeline (`Views/TimelineTabView.swift`) — not trip-scoped by ID, matched purely
  by UTC time-range overlap at render time.
- A read-only on-disk summary store (`CrewAccessTripSummaryStore.swift`) that
  re-derives hotel-by-station and credit/TAFB text from the same `Documents/CrewAccessImports/*.json`
  files, used as a fallback by the Timeline UI — independent of the in-memory schedule.

## Discovered data sources for a trip

| Source | File | What it holds | Reaches `TDHSharedSchedule`? |
|---|---|---|---|
| `PayPeriodSchedule` / `TripLeg` / `OpenTimeTrip` | `Models/TripModels.swift` | Normalized legs, times, layover station/hotel-name/duration | Yes — this *is* the payload |
| `CrewAccessTripJSON` / `CrewAccessTripItemJSON` / `CrewAccessCrewJSON` | `Services/CrewAccessPDFImportService.swift:107-219` | Richer parser DTO: dutyTotals (raw strings), hotelDetails (raw strings), crew list, mapping/schema versions, per-leg tz/derivation metadata | No |
| `PendingImport` | `Services/CrewAccessPDFImportService.swift:22-38` | Import provenance: sourceFileName, createdAt, warnings, errors, rawExtractStats | No |
| `RawExtractStats` | `Services/CrewAccessPDFImportService.swift:44-48` | pageCount/characterCount/lineCount only — **no raw text retained** | No |
| `IATATimeZoneResolver` | `Services/IATATimeZoneResolver.swift` | Static IATA → timezone/airport name/city name table | No |
| `CrewAccessTripSummaryStore` | `Services/CrewAccessTripSummaryStore.swift` | Re-derived hotelByStation, creditTime, tripDays, tafb, read from disk | No |
| `ManualOperationalEvent` / `ManualPersonalEvent` | `Models/CalendarModels.swift:292,467` | Crew-base + UTC window + free-text notes, not trip-scoped | Separate CloudKit record (`TDHManualEventSnapshot`), unrelated to trip sync |

### Confirmed gaps — data that exists in the source PDF but is not reachable anywhere in the running app

These would require modifying parsing/model code to retain, which this task
deliberately avoids (see "Do not modify production serialization" in scope). They are
listed in the snapshot's own `diagnostics.knownGaps` array instead of being
backfilled:

- **Duty start/end and report/release times** — parsed by `PDFTripParser` into
  `Trip`/`FlightLeg` (`Models/RosterParsingModels.swift`), but that intermediate object
  is discarded inside `CrewAccessPDFImportService.analyzeTrip`; only layover
  station/hotel-name/duration survive into `TripLeg`.
- **Ground transportation details** — three separate parsers
  (`PDFTripParser.swift`, `TripScheduleSnapshotEncoder.swift`,
  `CrewAccessTripSummaryStore.swift`) treat the `"Hotel Transport:"` token purely as a
  text delimiter; whatever follows it in the PDF is never captured into any field.
- **Hotel phone / check-in / check-out times** — parsed into `LayoverLeg`
  (`RosterParsingModels.swift:88-96`) but discarded before reaching `TripLeg` or
  `CrewAccessTripJSON`.
- **Raw extracted PDF text** — exists only in a local variable inside `analyzeTrip`
  and is gone once that function returns; never attached to `CrewAccessImportDraft`
  or `PendingImport`.
- Also worth noting as dead code, not a true gap: `FlightLeg.crew: [CrewMember]`
  (`RosterParsingModels.swift:84,99-107`) is always empty — the real crew list that
  reaches disk is `CrewAccessTripJSON.crew: [CrewAccessCrewJSON]`.

## What the raw snapshot includes

`TripRawDebugSnapshot` (defined in `TripDataHub/ViewModels/AppViewModel.swift`, inside
a `#if DEBUG` block just above the existing `#if DEBUG extension AppViewModel { ... }`)
composes existing `Codable` types directly (`PayPeriodSchedule`, `CrewAccessTripJSON`,
`ManualOperationalEvent`, `ManualPersonalEvent`) plus small `Encodable` mirror structs
for types that aren't `Codable` in production (`RawExtractStats`, `ImportWarning`,
`ImportErrorItem`, `CrewAccessTripSummary`) — no `Codable` conformance was added to any
production type.

Root shape (`snapshotVersion`, `generatedAt`, `generator`, `warning`, `trip`,
`cloudKitScheduleRepresentation`, `relatedData`, `derivedData`, `diagnostics`):

- **`warning`** — a machine-readable stability disclaimer emitted into every snapshot
  file, stating that this is an unstable DEBUG diagnostic format, not the CloudKit
  payload and not the public Export JSON schema.
- **`trip`** (stored source data) — `tripId`, `tripDate`, `importSource`,
  `sourceFileName`, `importCreatedAt`, the full `parsedSchedule` (`PayPeriodSchedule`),
  the full `crewAccessTripJSON`, `rawExtractStats`, `warnings`, `errors`.
- **`cloudKitScheduleRepresentation`** — the same `PayPeriodSchedule` wrapped in a
  single-element array with `recordType`/`field` labels, so a reader can see exactly
  what shape CloudKit stores. Re-encoded through this snapshot's own encoder (pretty,
  sorted, ISO-8601 dates) — **explicitly not a byte-exact copy** of what
  `FriendScheduleCloudKitService.uploadSchedule` actually sends (that call uses a
  separate, unconfigured `JSONEncoder()`).
- **`relatedData`** (related records) — `manualEvents` (operational/personal events
  whose UTC window overlaps the trip's overall leg span; carries an explicit
  `associationMethod` field stating the association is **inferred by UTC overlap at
  export time** — production manual events have no trip ID, and this diagnostic-only
  filter is distinct from the app's real rest/timeline overlap logic in
  `Views/TimelineSupport.swift`), `tripSummaryStoreEntry` (the on-disk
  `CrewAccessTripSummaryStore` entry for this trip ID, if one already exists).
- **`derivedData`** (calculated values, clearly separated from stored source data) —
  `legCount`, `openTimeTripCount`, `uniqueAirports`, `hasDeadheadLegs` (from
  `CrewAccessTripJSON.items`, since `TripLeg` itself has no deadhead flag — `nil` if
  `jsonPayload` is unavailable), and `airports` (IATA → timezone/airport name/city
  name, resolved at export time from `IATATimeZoneResolver`'s static table — these
  values are never stored on any trip model, which is why they live under
  `derivedData` rather than `relatedData`).
- **`diagnostics`** (metadata about the snapshot itself) — `unavailableData` (a
  structured array where each entry carries `dataGroup`, `status`, `reason`,
  `sourceStage`, and `availableWithParserChanges`, covering the four gaps listed
  above so the gaps travel inside the JSON itself, not only in this document), and
  `mappingVersion` (echoed from `CrewAccessTripJSON.mappingVersion`).

Unavailable data is represented as `null`/omitted (Swift `Optional` fields), never
invented. No CloudKit system metadata (record name, change tag), device identifiers,
GEMS ID, or authentication material is included anywhere in the snapshot.

## Encoder configuration (raw snapshot only — distinct from the CloudKit encoder)

```swift
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
```

This is a deliberately different, independent encoder from the one used for the real
CloudKit upload (`JSONEncoder()` with no configuration, `.deferredToDate` for
`updatedAt`). The raw snapshot is not a claim of byte identity with anything CloudKit
receives — it exists purely for local investigation.

## Trigger and output

- **Trigger:** `Button("Export Raw Trip Snapshot (Debug)")` inside the existing
  `#if DEBUG` "Diagnostics" `DisclosureGroup` in
  `TripDataHub/Views/ImportPreviewView.swift` (Import Preview screen, shown right
  after a PDF import, before Confirm/Cancel). Calls
  `AppViewModel.debugExportRawTripSnapshot(pending:)`.
- **Output file:** `<Documents>/tripdatahub-raw-trip-<tripId>.json` (trip ID
  sanitized by replacing `/` with `-`).
- **Logging:** the full file path is logged via the existing `logNonFatal` helper
  (`Logger.error`, `.public` privacy) for retrieval from Console/sysdiagnose or the
  simulator's container.
- Only reachable for a trip currently pending import (not yet-confirmed trips already
  sitting in `AppViewModel.schedules` are out of scope for this button, per the task's
  UI boundary).

## Not a stable schema

Every field name, nesting shape, and included section in `TripRawDebugSnapshot` may
change at any time. It is a diagnostic aggregate meant to be read once by a human
during investigation, not parsed by any other code, not versioned for compatibility,
and not a preview of the public Export JSON format. The future public export will be a
separate, deliberately-designed model that selects and transforms fields out of the
domain model (`PayPeriodSchedule`, `CrewAccessTripJSON`, etc.) — it will not simply be
this snapshot renamed.

## Removing this temporary mechanism later

1. Delete the `TripRawDebugSnapshot` type and its `#if DEBUG` block, and delete
   `debugExportRawTripSnapshot(pending:)` plus its private helper methods
   (`buildRawSnapshotAirports`, `buildRawSnapshotManualEvents`,
   `rawSnapshotUnavailableData`) from `AppViewModel.swift`.
2. Delete the `Button("Export Raw Trip Snapshot (Debug)")` block from the `#if DEBUG`
   Diagnostics section in `ImportPreviewView.swift`.

## Validation

- Completed on this machine:
  - `xcodebuild -scheme TripDataHub -configuration Debug -destination 'generic/platform=iOS Simulator' build` — **BUILD SUCCEEDED**.
  - `xcodebuild -scheme TripDataHub -configuration Release -destination 'generic/platform=iOS Simulator' build` — **BUILD SUCCEEDED** (confirms the `#if DEBUG`-guarded snapshot type, builder methods, and button compile out cleanly; the compiler physically strips `#if DEBUG` blocks when `DEBUG` is undefined).
  - `xcodebuild test -scheme TripDataHub -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -only-testing:TripDataHubTests` — **310/310 tests passed**, confirming no change to `FriendScheduleCloudKitService`, `DeviceScheduleCloudKitService`, or any production serialization path.
  - A standalone Swift smoke test using the identical encoder configuration
    (`.iso8601` dates, `.prettyPrinted` + `.sortedKeys`) confirmed the output is valid
    JSON that round-trips through `JSONSerialization`.
  - Source-level confirmation: `FriendScheduleCloudKitService.uploadSchedule` and
    `DeviceScheduleCloudKitService.uploadDeviceSchedule` are byte-for-byte unmodified;
    the new code is additive-only and never calls either CloudKit service.
- Still required on the Mac (needs the simulator/device runtime, not available to
  complete here):
  - Run the app in the iOS Simulator, import a real CrewAccess PDF, open Import
    Preview, expand Diagnostics, tap "Export Raw Trip Snapshot (Debug)".
  - Confirm the logged file path resolves inside the simulator's Documents container
    and the file opens as valid, readable JSON with the expected sections populated.
  - Spot-check that fields expected to be `null` (e.g., `tripSummaryStoreEntry` for a
    brand-new trip not yet written to `Documents/CrewAccessImports/`) are indeed
    `null` rather than throwing or crashing.
  - Confirm no `TDHSharedSchedule`/`TDHDeviceScheduleSnapshot`/any CloudKit write
    occurs merely from tapping the debug button (it only calls the local
    `AppViewModel` method, never `friendScheduleCloudKitService`/
    `deviceScheduleCloudKitService`).
