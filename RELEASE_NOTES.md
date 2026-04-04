# TripData Hub - Release Notes

## Version 1.0

### New: Next Flight Countdown

TripData Hub can now display a countdown to your next scheduled flight leg.

The countdown is designed specifically for pilot operations and is based on **Scheduled Departure Time (STD)**.

---

### Widget Countdown

A Home Screen Widget automatically appears when your next leg is within **12 hours** of scheduled departure.

The widget displays:

- Departure local date
- Departure airport and local time
- Arrival airport and local time
- Countdown to Scheduled Departure

---

### Live Activity & Dynamic Island

When your flight is within **6 hours of scheduled departure**, the countdown moves to a **Live Activity**.

This allows the next flight status to appear on:

- Lock Screen
- Dynamic Island
- Live Activity view

---

### Delayed Mode

Once the **Scheduled Departure Time** is reached, the countdown automatically switches to **Delayed Mode**.

Instead of showing remaining time, the display changes to:

`Delayed XXh XXm`

This shows how long the operation has passed the scheduled departure time.

---

### Deadhead Legs

Deadhead (DH) legs are included when determining the next leg.

The countdown always tracks the **next scheduled operational leg**.

---

### Time Display

All times are shown in **local airport time**.

- Departure time uses the departure airport time zone
- Arrival time uses the arrival airport time zone

Arrival date is always displayed to avoid confusion on long-haul flights and routes crossing time zones.

---

### Countdown Lifecycle

- T-12h -> Widget countdown
- T-6h -> Live Activity countdown
- T0 -> Delayed mode
- T+6h -> Countdown ends

---

### Notes

This feature focuses on **Scheduled Departure awareness**, not real-time flight tracking.

Future updates may add:

- Van Time countdown
- Report Time countdown
- Next operational event countdown
