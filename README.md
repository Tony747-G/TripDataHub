# BidProSchedule Notes

## OpenTime Trip Information

In the OpenTime trip detail flight card, the right-side line is shown as:

`Block: HH:MM / <Type> at XXX: HH:MM`

- `Block` is calculated from UTC values: `arrUTC - depUTC` when possible.
- For `DH` and `CML`, `block = 0:00` from raw data is not trusted as arrival timing input.

### Connection/Rest/Layover Type Rules

The interval between the current leg arrival and next leg departure is classified as:

- Less than 5 hours and same-station: `Connection`
- 5 to 10 hours: `Rest`
- More than 10 hours: `Layover`

`XXX` is the current leg arrival airport.

## Bid Period / Pay Period Calendar

- BP26-01 from 2025-11-30 to 2026-01-24 (PP25-13 from 2025-11-30 to 2025-12-27, PP26-01 from 2025-12-28 to 2026-01-24)
- BP26-02 from 2026-01-25 to 2026-03-21 (PP26-02 from 2026-01-25 to 2026-02-21, PP26-03 from 2026-02-22 to 2026-03-21)
- BP26-03 from 2026-03-22 to 2026-05-16 (PP26-04 from 2026-03-22 to 2026-04-18, PP26-05 from 2026-04-19 to 2026-05-16)
- BP26-04 from 2026-05-17 to 2026-07-11 (PP26-06 from 2026-05-17 to 2026-06-13, PP26-07 from 2026-06-14 to 2026-07-11)
- BP26-05 from 2026-07-12 to 2026-09-05 (PP26-08 from 2026-07-12 to 2026-08-08, PP26-09 from 2026-08-09 to 2026-09-05)
- BP26-06 from 2026-09-06 to 2026-10-31 (PP26-10 from 2026-09-06 to 2026-10-03, PP26-11 from 2026-10-04 to 2026-10-31)
- BP26-07 from 2026-11-01 to 2026-11-28 (PP26-12 from 2026-11-01 to 2026-11-28) This is the only 4 weeks Bid Period.
- BP27-01 from 2026-11-29 to 2027-01-23 (PP26-13 from 2026-11-29 to 2026-12-26, PP27-01 from 2026-12-27 to 2027-01-23)
- BP27-02 from 2027-01-24 to 2027-03-20 (PP27-02 from 2027-01-24 to 2027-02-20, PP27-03 from 2027-02-21 to 2027-03-20)
- BP27-03 from 2027-03-21 to 2027-05-15 (PP27-04 from 2027-03-21 to 2027-04-17, PP27-05 from 2027-04-18 to 2027-05-15)
- BP27-04 from 2027-05-16 to 2027-07-10 (PP27-06 from 2027-05-16 to 2027-06-12, PP27-07 from 2027-06-13 to 2027-07-10)
- BP27-05 from 2027-07-11 to 2027-09-04 (PP27-08 from 2027-07-11 to 2027-08-07, PP27-09 from 2027-08-08 to 2027-09-04)
- BP27-06 from 2027-09-05 to 2027-10-30 (PP27-10 from 2027-09-05 to 2027-10-02, PP27-11 from 2027-10-03 to 2027-10-30)
