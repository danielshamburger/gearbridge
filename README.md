# TrainerCtrl

An iPhone app that adds virtual shifting to a Tacx Flux S smart trainer in Zwift.

The phone sits between the trainer and Zwift. It connects to the trainer over Bluetooth and shows up in Zwift as a trainer named **TrainerCtrl**. When you shift, it changes the resistance it sends to the trainer, so the bike feels like it has a full set of gears. The chain stays in one cog the whole ride.

```
Tacx Flux S  ──BLE (FTMS)──▶  TrainerCtrl (iPhone)  ──BLE (FTMS)──▶  Zwift (Mac)
     └───────────── ANT+ power (optional) ─────────────────────────────▲
```

## Features

- Shift with the on-screen + and − buttons or the volume buttons.
- 1× gear presets, or a custom chainring and cassette.
- Two shifting models:
  - **Simple:** each gear adds a fixed grade (1% by default).
  - **Calibrated:** each gear matches the power and cadence a real gear would need. It needs a one-time trainer calibration, which the app guides you through.
- If the trainer stops sending data, Zwift gets zeros. If Zwift disconnects or goes quiet, the trainer eases to a flat road.
- A packet log for each ride, which you can export as CSV from Settings.
- A mock trainer, so you can test without the real one.

## Requirements

- iPhone with iOS 17 or later
- Xcode 16 or later (Swift 6)
- Tacx Flux S (or another FTMS trainer) and Zwift on a Mac

## Building

Open `App/TrainerCtrl.xcodeproj`, choose your iPhone, and run. The shifting, protocol and calibration logic is in the `TrainerCore` Swift package, which has its own tests:

```sh
cd TrainerCore && swift test
```

## Riding

1. Put the chain in the cog you set under **Settings → Real gear on the trainer** (42×18 by default).
2. Open TrainerCtrl and tap **Start ride**. The app connects to the trainer and shows up in Zwift.
3. In Zwift, pair **Controllable** and **Cadence** to TrainerCtrl. Pair **Power** to TrainerCtrl too, unless you use ANT+ (below).
4. Keep the app in the foreground while you ride. iOS only advertises to Zwift reliably while the app is open.
5. When you're done, tap **End ride**.

**Events that require a power meter.** Zwift blocks power that comes through a bridge. In those events:
1. Turn off **Send power to Zwift**.
2. In Zwift, pair **Power** to the Flux S directly over ANT+.
3. Keep **Controllable** paired to TrainerCtrl.

## Troubleshooting

**Zwift shows TrainerCtrl as connected, but power and cadence stay at 0, then blank out, while the app still says "Waiting for Zwift to pair".** The Mac is holding stale Bluetooth information about the iPhone. To fix it:
1. Quit Zwift.
2. Turn the Mac's Bluetooth off and on again.
3. Reopen Zwift and pair TrainerCtrl again.

## Layout

| Path | What's there |
|---|---|
| `App/TrainerCtrl/BLE` | The trainer connection, the mock trainer, and the virtual trainer that Zwift sees |
| `App/TrainerCtrl/Bridge` | `BridgeController`: connects the pieces, stores settings, runs the ride |
| `App/TrainerCtrl/UI` | Screens: home, ride, settings, gears, calibration |
| `TrainerCore/Sources/TrainerCore` | FTMS encoding and decoding, bridge logic, gearing, shifting, calibration |
| `Virtual Shifting Bridge for Tacx Flux S — Plan.md` | Design plan and background |

