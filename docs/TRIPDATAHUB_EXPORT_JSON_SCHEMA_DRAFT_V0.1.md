# TripDataHub Export JSON Schema — Draft v0.1

Status: **Implemented subset**. The public export is available from a Trip's action
menu in the primary Timeline. It is intended as input for the TDH Viewer MVP. This
document does not describe the internal `CrewAccessTripJSON` persistence format or
the debug-only raw snapshot.

## Root contract

The UTF-8 JSON root contains exactly these fields:

```json
{
  "schemaVersion": "1.2",
  "exportedAt": "2026-07-19T01:30:00Z",
  "generator": {},
  "owner": {},
  "trip": {},
  "events": []
}
```

`schemaVersion` is the JSON string `"1.2"`. Version `1.0` was the original
flight-only contract and `1.1` introduced layover/rest fields.
`exportedAt` and operational
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
- `layover`: the interval between an arriving Flight Block-in and the next Flight
  Block-out at the same station. It is interleaved with flights using a continuous
  public `sequence` and links to the adjacent flight/deadhead segments with
  `previousSegmentID` and `nextSegmentID`.

Events are sorted by `start.instant`, then `sequence`, then `id`.

The layover event keeps the derived block gap separate from rest and hotel occupancy:

```json
{
  "id": "event-trip-a70610-2026-07-21-layover-2",
  "type": "layover",
  "sequence": 2,
  "start": {},
  "end": {},
  "station": "SDF",
  "previousSegmentID": "event-trip-a70610-2026-07-21-flight-1",
  "nextSegmentID": "event-trip-a70610-2026-07-21-flight-3",
  "blockGap": {
    "start": {},
    "end": {},
    "durationMinutes": 1692,
    "derived": true,
    "derivation": "previousSegment.end_to_nextSegment.start"
  },
  "scheduledRest": {
    "dutyEnd": {},
    "nextDutyStart": {},
    "durationMinutes": 1572,
    "derived": true,
    "calculationRule": {
      "dutyEndMinutesAfterBlockIn": 30,
      "dutyStartMinutesBeforeBlockOut": 90
    }
  },
  "hotel": {
    "name": "Crowne Plaza Louisville Airport Expo Center",
    "phone": "502-367-2251",
    "sourceName": "Crowne Plaza Louisville Airpor",
    "nameNormalization": {
      "derived": true,
      "method": "knownHotelDirectory",
      "matchedBy": "stationAndPhone"
    }
  }
}
```

`start` and `end` remain on every event for compatibility; on a layover they equal
the `blockGap` bounds. `blockGap` is explicitly marked derived and is not Scheduled
Rest or hotel occupancy. Missing hotel fields are omitted.

TDH's authoritative scheduled hotel-rest calculation is:

- `dutyEnd = arrivingFlight.blockIn + 30 minutes`
- `nextDutyStart = nextFlight.blockOut - 90 minutes`
- `scheduledRest = dutyEnd ... nextDutyStart`

This rule is applied only across a verified duty boundary. Structured layover metadata
establishes that boundary directly. Otherwise, the CrewAccess Trip day/source sequence
must increase and the Block-in-to-next-Block-out interval must satisfy TDH's documented
Layover classification of more than ten hours. Adjacent legs in the same Trip day
without layover metadata remain in the same duty and do not produce a layover or
`scheduledRest`. The result is marked `derived` and the two offsets are included in
`calculationRule`.

`hotelStay` remains separate and is emitted only when persisted Check-in and Check-out
instants are both available. The current importer does not persist those timestamp
pairs, so `hotelStay` is omitted rather than inferred from `blockGap` or
`scheduledRest`.

Schema `1.1` was a minor, additive version: existing Flight/deadhead fields were
unchanged, optional layover fields can be ignored, and consumers must skip event
objects whose `type` they do not recognize instead of failing the entire document.

Schema `1.2` directly renames the Draft-only layover references from
`previousFlightID` / `nextFlightID` to `previousSegmentID` / `nextSegmentID` because
the referenced segment may be a `deadhead`. This is structurally breaking, but the
Draft has no production Viewer or external consumer in this repository, so the
misleading legacy fields are not emitted in parallel.

Hotel names may be replaced only by the bundled known-hotel directory. Matching order
is exact station-plus-normalized-phone (`stationAndPhone`), directory-unique normalized
phone (`phone`), exact station-plus-raw-name (`stationAndRawName`), then
directory-unique exact raw name (`rawName`). Duplicate phone or raw-name entries are
never resolved without station. When the public name differs, `sourceName` and
`nameNormalization` record the source and the branch that actually matched.
Unknown or ambiguous names are preserved verbatim; no prefix/fuzzy matching, online
lookup, or runtime external API is used by public JSON export.

## Deferred event types

- `groundTransport`: source transport text is not retained as reliable structured data.
- `report`: duty/report timestamps are discarded before the persisted Trip model.
- `release`: duty/release timestamps are discarded before the persisted Trip model.

Raw parser strings are not exported to simulate these event types. Adding them requires
retaining structured source data in the import model and extending this public mapping.
