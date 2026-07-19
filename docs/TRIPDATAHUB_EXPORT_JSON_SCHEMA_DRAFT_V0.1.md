# TripDataHub Export JSON Schema — Draft v0.1

Status: **Implemented subset**. The public export is available from a Trip's action
menu in the primary Timeline. It is intended as input for the TDH Viewer MVP. This
document does not describe the internal `CrewAccessTripJSON` persistence format or
the debug-only raw snapshot.

## Root contract

The UTF-8 JSON root contains exactly these fields:

```json
{
  "schemaVersion": "1.0",
  "exportedAt": "2026-07-19T01:30:00Z",
  "generator": {},
  "owner": {},
  "trip": {},
  "events": []
}
```

`schemaVersion` is always the JSON string `"1.0"`. `exportedAt` and operational
`instant` values use ISO 8601 UTC. Generator version and build are informational and
do not determine schema compatibility.

## Owner identity and privacy boundary

The export intentionally contains the minimum owner identity required to identify
and display whose trip it is:

```json
{
  "name": "SATOSHI FUNENO",
  "gems": "7793942",
  "base": "ANC",
  "fleet": "747",
  "position": "FO"
}
```

The owner name resolver prefers a canonical multi-part Profile display name, then
combined Profile given/family fields, a verified full name, and the matching
CrewAccess owner's full name. A single-token Profile value is retained only as a
last-resort fallback; it does not override an available complete name. Names keep
their established public order, collapse whitespace, and export in uppercase.

GEMS is an identifier and is always encoded as a string. Canonical profile data has
priority over source data. A digit-only value shorter than seven digits is left-padded
to seven; a value with seven or more digits is preserved in full so future eight-digit
and longer identifiers are supported. Positions use stable public codes (`CA`, `FO`,
and `SO`); for example, `F/O` normalizes to `FO`.

The public export does not contain the raw `crew` array, other crew members, seniority,
CloudKit/database identifiers, parser/source versions, mapping versions, raw duty or
hotel strings, file paths, diagnostics, sync/authentication state, or deletion metadata.
The export is therefore privacy-minimized, not anonymous.

## Trip and stable identifiers

`trip` contains `id`, `tripNumber`, `title`, `start`, `end`, `base`, and `status`.
Public IDs are deterministically derived from public trip number/date and event
sequence/type. They remain stable across repeated exports and do not use a CloudKit
record name, database key, or model UUID.

The filename remains deterministic and filesystem-safe:

```text
TDH_<trip-identifier>_<start-date>.json
```

## Operational time

Every event start/end and the Trip bounds use:

```json
{
  "instant": "2026-08-23T22:14:00Z",
  "local": "2026-08-23T14:14:00",
  "timeZone": "America/Anchorage",
  "utcOffset": "-08:00"
}
```

`instant` is canonical. `local` is derived from that instant and the IANA timezone,
not copied from a presentation-only source string. `utcOffset` is calculated for the
specific instant, including daylight-saving rules. When the source has no reliable
timezone, the implementation retains the correct instant and represents it in UTC.

## Implemented event subset

- `flight`: operating CrewAccess legs.
- `deadhead`: positioning/deadhead CrewAccess legs.
- `hotel`: only when the normalized schedule has a structured hotel name plus reliable
  arrival and following-departure UTC bounds.

Events are sorted by `start.instant`, then `sequence`, then `id`.

## Deferred event types

- `groundTransport`: source transport text is not retained as reliable structured data.
- `report`: duty/report timestamps are discarded before the persisted Trip model.
- `release`: duty/release timestamps are discarded before the persisted Trip model.

Raw parser strings are not exported to simulate these event types. Adding them requires
retaining structured source data in the import model and extending this public mapping.
