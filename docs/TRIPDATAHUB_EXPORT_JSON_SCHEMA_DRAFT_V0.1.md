# TripDataHub Export JSON Schema — Draft v0.1

Status: **Implemented subset**. The public export is available from a Trip's action
menu in the primary Timeline. It is intended as input for the TDH Viewer MVP. This
document does not describe the internal `CrewAccessTripJSON` persistence format or
the debug-only raw snapshot.

## Root contract

The UTF-8 JSON root contains exactly these fields:

```json
{
  "schemaVersion": "1.3",
  "exportedAt": "2026-07-19T01:30:00Z",
  "generator": {},
  "owner": {},
  "trip": {},
  "events": []
}
```

`schemaVersion` is the JSON string `"1.3"`. Version `1.0` was the original
flight-only contract, `1.1` introduced layover/rest fields, and `1.2` added
stable owner-name and pay-period metadata. Version `1.3` adds lossless per-endpoint
scheduled/revised/actual history and aircraft registration.
`exportedAt` and operational
`instant` values use ISO 8601 UTC. Generator version and build are informational and
do not determine schema compatibility.

## Owner identity and privacy boundary

The export intentionally contains the minimum owner identity required to identify
and display whose trip it is:

```json
{
  "name": "AVERY EXAMPLE",
  "gems": "0000001",
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

## Bid Period schedule export

The Timeline action `Export Bid Period JSON` creates `<bidPeriod.identifier>.json`
(for example, `BP26-06.json`) with schema version `1.1` and export type
`bidPeriodSchedule`. Bid Period bounds come from `BidPeriodService`, including the
03:00 domicile-local boundary and variable-duration periods. Schedule inclusion uses
half-open interval overlap, not assigned-BP equality. Each trip separately records the
BP assigned from its earliest valid UTC departure.

```json
{
  "schemaVersion": "1.1",
  "exportType": "bidPeriodSchedule",
  "exportedAt": "2026-09-10T18:00:00Z",
  "generator": {
    "name": "TripDataHub",
    "version": "1.0",
    "build": "1"
  },
  "owner": {
    "name": "AVERY EXAMPLE",
    "gems": "0000001",
    "domicile": "ANC",
    "timeZone": "America/Anchorage",
    "fleet": "747",
    "position": "FO",
    "line": {
      "equipment": "747",
      "seat": "FO",
      "seniorityNumber": "99999",
      "dateOfHire": "2020-01-01"
    }
  },
  "bidPeriod": {
    "identifier": "BP26-06",
    "start": "2026-09-06T11:00:00Z",
    "end": "2026-11-01T12:00:00Z",
    "domicile": "ANC",
    "timeZone": "America/Anchorage",
    "boundaryLocalTime": "03:00",
    "payPeriods": [
      {
        "identifier": "PP26-10",
        "ordinal": 1,
        "start": "2026-09-06T11:00:00Z",
        "end": "2026-10-04T11:00:00Z"
      },
      {
        "identifier": "PP26-11",
        "ordinal": 2,
        "start": "2026-10-04T11:00:00Z",
        "end": "2026-11-01T12:00:00Z"
      }
    ]
  },
  "trips": [],
  "calendarEvents": [
    {
      "id": "profile-faa-medical-expiry-2026-09-15",
      "category": "personal",
      "kind": "faaMedicalExpiry",
      "title": "FAA Medical Expiry Date",
      "timing": {
        "semantics": "allDay",
        "localStartDate": "2026-09-15",
        "localEndDateExclusive": "2026-09-16",
        "timeZone": "America/Anchorage",
        "timeZoneSource": "selectedBidPeriodDomicile"
      },
      "source": "profileDate"
    }
  ],
  "diagnostics": {
    "partial": false,
    "issues": []
  }
}
```

Owner identity and line fields are optional when unavailable. Missing rich CrewAccess
data likewise produces a displayed-schedule fallback plus root and per-trip diagnostic
issues; it does not invalidate the whole Bid Period export. `calendarEvents` includes
user-owned Operational and Personal events, Bid and Financial rule events, and profile
dates. Every event retains a category and one of `userCreated`, `calendarRule`, or
`profileDate` as its source. Friends and other employees are not export inputs.

`bidPeriod.payPeriods` comes from the same `BidPeriodService` definition that owns the
parent BP boundary, Pay Period count, and public PP labels. Items are ordered by their
stable one-based `ordinal`; `identifier` is the authoritative public label when TDH has
one. A future definition without a public identifier retains the ordinal rather than
inventing an operational label. PP intervals use the parent 03:00 domicile-local
boundary, are half-open `[start, end)`, and are contained within the parent BP. Normal
Bid Periods currently contain two items, while the known short Bid Period contains one.
Pay Periods inherit the parent domicile, timezone, and boundary-local-time metadata.

Each BP trip may also contain a structured `summary` sourced only from its matched rich
CrewAccess payload:

```json
{
  "summary": {
    "dutyTime": { "minutes": 975, "display": "16:15" },
    "blockTime": { "minutes": 765, "display": "12:45" },
    "creditTime": { "minutes": 860, "display": "14:20" },
    "tafb": { "minutes": 2890, "display": "48:10" },
    "tripDays": { "days": 3, "display": "3" }
  }
}
```

Duty and block minutes are totals of the authoritative per-duty values retained in the
rich payload. Credit, TAFB, and trip days map from their existing trip-level payload
fields. Individual unavailable values are omitted; if no values are available, the
whole `summary` is omitted. Corresponding `summary.*` names appear in the trip's
`diagnostics.unavailableFieldGroups`. Displayed-schedule fallback trips never fabricate
summary values. These additive BP-only fields remain part of BP schema `1.1`
and do not change the single-trip JSON contract.

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

Flight and deadhead events additionally retain each endpoint's observation history:

```json
{
  "aircraft": "747",
  "aircraftRegistration": "N123EX",
  "departure": {
    "originalScheduled": {
      "instant": "2026-08-23T22:00:00Z"
    },
    "scheduled": {
      "instant": "2026-08-23T22:14:00Z",
      "observedAt": "2026-08-22T05:15:00Z"
    },
    "actual": {
      "instant": "2026-08-23T22:21:00Z",
      "observedAt": "2026-08-24T05:15:00Z"
    }
  },
  "arrival": {
    "originalScheduled": { "instant": "2026-08-24T02:00:00Z" },
    "scheduled": { "instant": "2026-08-24T02:14:00Z" },
    "actual": { "instant": "2026-08-24T02:27:00Z" }
  }
}
```

`originalScheduled` is the first retained schedule, `scheduled` is the latest
pre-endpoint schedule, and `actual` is the latest post-endpoint observation.
`observedAt` is the CrewAccess PDF `Created` timestamp when available.

`originalScheduled` carries an `instant` only and never an `observedAt`. The model keeps
one schedule-observation timestamp per endpoint, and a revision overwrites it, so the
observation time of the *original* schedule is not retained. It is omitted rather than
back-filled from the current schedule's observation, because that would attribute
provenance the source never supplied. Consumers must not infer that a missing
`originalScheduled.observedAt` means the original and current schedules were observed
together.

Missing legacy history is omitted rather than fabricated: an absent `scheduled` block
means no pre-endpoint observation was ever recorded for that endpoint, not that the
scheduled time equals the actual one.

The backward-compatible event `start` and `end` resolve
`actual > scheduled > originalScheduled`. Note that this display ordering is deliberately
*not* the ordering used for Bid Period assignment, trip identity or report times, which
resolve `scheduled > originalScheduled` and ignore actuals entirely (see INV-012). The BP
schema `1.1` embeds this same event shape.

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

Deferred `groundTransport` rows are skipped when locating the next public flight or
deadhead segment. A layover is retained only when every skipped row preserves a
continuous station chain from the arriving segment to that next public segment.

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
