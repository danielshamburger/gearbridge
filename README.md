<p align="center"><img src="docs/app-icon.png" width="128" alt="Gearbridge app icon"></p>

# Gearbridge

An iPhone app that adds virtual shifting to a [Tacx Flux S](https://www.garmin.com/en-US/p/690888/) smart trainer in [Zwift](https://www.zwift.com/).

The phone sits between the trainer and Zwift. It connects to the trainer over Bluetooth and shows up in Zwift as a trainer named **Gearbridge**. When you shift, it changes the resistance it sends to the trainer, so the bike feels like it has a full set of gears. The chain stays in one cog the whole ride.

```
Tacx Flux S  ──BLE (FTMS)──▶  Gearbridge (iPhone)  ──BLE (FTMS)──▶  Zwift (Mac)
     └───────────── ANT+ power (optional) ─────────────────────────────▲
```

## Features

- Connects to Zwift over Bluetooth or Wi-Fi.
- Shift with the on-screen + and − buttons or the volume buttons.
- 1× gear presets, or a custom chainring and cassette.
- Two shifting models:
  - **Simple:** each gear adds a fixed grade (1% by default).
  - **Calibrated:** each gear matches the power and cadence a real gear would need. It needs a one-time trainer calibration, which the app guides you through.
- Shift from the lock screen or the Dynamic Island, with the phone locked or in another app.
- Remembers your trainer, and lets you pick it when there's more than one nearby.
- Works in events that require a power meter: Zwift takes power straight from the trainer over ANT+, or over Bluetooth if your trainer accepts a second connection, while the app keeps the shifting.

## Riding

1. Put the chain in the cog you set under **Settings → Trainer → Real gear** (42×18 by default).
2. Open Gearbridge and tap **Start ride**. The app connects to the trainer and shows up in Zwift.
   The first ride connects to the first smart trainer it finds and remembers it. With more than one trainer around, pick yours under **Settings → Trainer → Trainer**.
3. In Zwift, pair **Controllable** and **Cadence** to Gearbridge. Pair **Power** to Gearbridge too, unless you use ANT+ (below).
   To connect over Wi-Fi, choose it under **Settings → Zwift → Connect over**. Gearbridge then shows up in Zwift's pairing lists with a Wi-Fi icon. The phone and the Mac must be on the same network.
4. Keep the app open while you pair. iOS only advertises to Zwift reliably while the app is on screen.
   Once paired, locking the phone or switching apps keeps the trainer and Zwift connected.
   To shift from there, use the − / + buttons on the lock screen, or long-press the Dynamic Island. Volume-button shifting needs the app on screen.
   A ride left in the background with no pedalling for 10 minutes ends on its own, so the app stops using Bluetooth.
5. When you're done, tap **End ride**.

**Events that require a power meter.** Zwift blocks power that comes through a bridge. In those events:
1. Turn off **Send power to Zwift**.
2. In Zwift, pair **Power** to the Flux S directly over ANT+, or over Bluetooth if the trainer accepts a second connection.
3. Keep **Controllable** paired to Gearbridge.

## Requirements

- iPhone with iOS 17 or later
- Xcode 16 or later (Swift 6)
- [Tacx Flux S](https://www.garmin.com/en-US/p/690888/) (or another FTMS trainer) and [Zwift](https://www.zwift.com/) on a Mac

## Dependencies

| Dependency | Used for |
|---|---|
| [Bluetooth Fitness Machine Service (FTMS)](https://www.bluetooth.com/specifications/specs/fitness-machine-service-1-0/) | The protocol on both sides: reading the trainer and setting its resistance, and acting as a trainer for Zwift |
| CoreBluetooth | Connecting to the trainer (central) and advertising to Zwift (peripheral) |
| SwiftUI and Observation | All screens and app state |
| ActivityKit, WidgetKit and AppIntents | The lock screen and Dynamic Island widget, and its shift buttons |
| Network | The Wi-Fi connection to Zwift: a TCP server found through Bonjour |
| Wahoo Direct Connect | The protocol Zwift uses over Wi-Fi (no official spec; implemented from open-source work) |
| AVFoundation and MediaPlayer | Shifting with the volume buttons |

## Building

Open `App/Gearbridge.xcodeproj`, choose your iPhone, and run. The shifting, protocol and calibration logic is in the `TrainerCore` Swift package, which has its own tests:

```sh
cd TrainerCore && swift test
```

## Troubleshooting

**Zwift shows Gearbridge as connected, but power and cadence stay at 0, then blank out, while the app still says "Waiting for Zwift to pair".** The Mac is holding stale Bluetooth information about the iPhone. To fix it:
1. Quit Zwift.
2. Turn the Mac's Bluetooth off and on again.
3. Reopen Zwift and pair Gearbridge again.

**Zwift doesn't find Gearbridge over Wi-Fi.** Check that:
- the phone and the Mac are on the same network (guest networks, and routers that stop devices seeing each other, break it);
- Local Network is allowed for Gearbridge in the Settings app under Privacy;
- no VPN is on.

## Debugging

- **Debug mode:** under **Settings → Diagnostics**. It shows Zwift's command and the trainer grade while riding, and logs every trainer reading.
- **Packet log:** each ride's commands, responses and events, exported as CSV from **Settings → Diagnostics**.
- **Failsafes:** if the trainer stops sending data, Zwift gets zeros. If Zwift disconnects or goes quiet, the trainer eases to a flat road.
- **Simulate:** under **Settings → Trainer → Source**, a simulated trainer for trying the app without the bike. Choosing it turns on debug mode.

## Layout

| Path | What's there |
|---|---|
| `App/Gearbridge/BLE` | The trainer connection, the simulated trainer, and the virtual trainer that Zwift sees |
| `App/Gearbridge/Bridge` | `BridgeController`: connects the pieces, stores settings, runs the ride |
| `App/Gearbridge/UI` | Screens: home, ride, settings, gears, calibration |
| `App/GearbridgeLiveActivity` | The lock screen and Dynamic Island widget extension |
| `App/Shared` | Code in both the app and the extension: the Live Activity's data and the shift action |
| `TrainerCore/Sources/TrainerCore` | FTMS encoding and decoding, bridge logic, gearing, shifting, calibration |
| `Virtual Shifting Bridge for Tacx Flux S — Plan.md` | Design plan and background |

