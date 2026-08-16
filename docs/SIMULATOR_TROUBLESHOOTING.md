# Simulator Troubleshooting

Recurring local Simulator issues and first-response commands.

## SBMainWorkspace Busy / Application Failed Preflight

Symptom:

```text
The request was denied by service delegate (SBMainWorkspace) for reason: Busy ("Application failed preflight checks").
```

Observed root cause:

SpringBoard inside the booted Simulator can keep stale app-update state for `com.sfune.BidProSchedule`. The app install has already completed, but SpringBoard still reports:

```text
Cannot launch application scene sceneID:com.sfune.BidProSchedule-default while it's application is being updated
```

This is usually not a TripDataHub app crash. It happens before the app process starts.

First recovery step, before rebooting macOS:

```sh
xcrun simctl spawn booted launchctl kickstart -k user/501/com.apple.SpringBoard
```

Then retry launching the app:

```sh
xcrun simctl launch booted com.sfune.BidProSchedule
```

If SpringBoard restart does not recover it, escalate in this order:

1. Quit and reopen Simulator.
2. `xcrun simctl shutdown booted`, then boot the device again.
3. Restart CoreSimulator services.
4. Reboot macOS only as the last resort.
