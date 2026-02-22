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
