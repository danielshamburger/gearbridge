# Plan: connect to Zwift over Wi-Fi

Gearbridge talks to Zwift over Bluetooth today. This plan adds a second way: Wi-Fi, using Wahoo's **Direct Connect** protocol (also called DIRCON), which Zwift supports for trainers on the local network. The trainer side doesn't change: the Flux S only speaks Bluetooth (and ANT+), so the phone still reaches it over Bluetooth.

Status: planned (2026-11-06). Nothing built yet.

## Decisions already made

- **Settings → Zwift → Connect over: Bluetooth / Wi-Fi.** One at a time, never both: two "Gearbridge" devices in Zwift's pairing screen would invite mixed pairing, and both cost battery.
- **Bluetooth stays the default** until Wi-Fi has been ridden on the real setup. If it proves solid, Wi-Fi may become the default later.
- **No third-party packages.** Use Apple's Network framework (`NWListener`, `NWConnection`) for TCP and Bonjour.
- **`TrainerCore` and the shifting logic don't change.** Direct Connect carries the same FTMS bytes the app already sends and receives over Bluetooth.

## Why

- It avoids the Mac's Bluetooth. That removes the stale-pairing problem in the README's Troubleshooting section, and the Mac's limit on Bluetooth connections.
- Zwift finds the app through Bonjour, not Bluetooth advertising, which iOS only does reliably in the foreground.
- The phone runs one Bluetooth connection (to the trainer) instead of two.

## Rules

- **Latency:** no added latency for shifts or Zwift grades. The `LatencyTests` suite must still pass. Over TCP, turn Nagle off (`noDelay`) so small packets go out at once.
- **Commits:** as the user only (see the repo's usual commit command), no Co-Authored-By trailer. Push after each commit.
- **Screen transitions** keep the default iOS timing.

## The protocol

There's no official public spec. The details below come from open-source implementations that work with Zwift, listed under Sources. Items marked **(check)** differ between them or haven't been confirmed against Zwift.

### Discovery (Bonjour)

| Field | Value |
|---|---|
| Service type | `_wahoo-fitness-tnp._tcp` (domain `local.`) |
| Service name | `Gearbridge` (`BridgeController.advertisedName`) |
| Port | 36866, the port real Wahoo devices use. If it's taken, any free port, because Bonjour advertises the actual port. |
| TXT `ble-service-uuids` | `0x1826` (FTMS). **(check)** Some implementations use the full 128-bit UUID string instead. The DirCon library uses `0x1826` and is tested with Zwift. |
| TXT `mac-address` | A stable, made-up MAC such as `02:xx:xx:xx:xx:xx` (`02` marks it as locally administered). Generate it once and save it. |
| TXT `serial-number` | A stable made-up serial. Generate it once and save it. |

### Message framing

Every message, in both directions, starts with a 6-byte header:

| Byte | Field |
|---|---|
| 0 | Version, always `1` |
| 1 | Message ID (see below) |
| 2 | Sequence number |
| 3 | Response code (`0` in requests) |
| 4–5 | Payload length, **big-endian** UInt16 |

Then comes the payload of that length.

- TCP is a stream. One read can hold part of a message or several messages, so buffer the input and split it by the length field.
- Where a UUID appears in a payload, it's the full **16-byte** UUID. 16-bit Bluetooth UUIDs use the Bluetooth base `0000XXXX-0000-1000-8000-00805F9B34FB`: bytes 2–3 hold the short UUID, high byte first.

**Message IDs**

| ID | Message |
|---|---|
| `0x01` | Discover services |
| `0x02` | Discover characteristics |
| `0x03` | Read characteristic |
| `0x04` | Write characteristic |
| `0x05` | Enable characteristic notifications |
| `0x06` | Unsolicited notification (from the app to Zwift) |
| `0x07` | Unknown. Zwift sends it with an empty payload. Reply with success and an empty payload. |
| `0xFF` | Error |

**Response codes**

| Code | Meaning |
|---|---|
| `0x00` | Success |
| `0x01` | Unknown message type |
| `0x02` | Unexpected error |
| `0x03` | Service not found |
| `0x04` | Characteristic not found |
| `0x05` | Operation not supported |
| `0x06` | Write failed |

**Characteristic property flags** (a byte in the discover-characteristics reply)

| Flag | Value |
|---|---|
| Read | `0x01` |
| Write | `0x02` |
| Notify | `0x04` |
| Indicate | `0x08` |

### Requests and replies

A reply uses the **same message ID and sequence number** as its request. An error reply has the error's response code and an empty payload. Unsolicited notifications use sequence number `0`.

| Request from Zwift | Request payload | Reply payload |
|---|---|---|
| `0x01` discover services | empty | 16 bytes per service. Only FTMS (`1826`). |
| `0x02` discover characteristics | service UUID | Service UUID, then 17 bytes per characteristic: UUID plus a properties byte. |
| `0x03` read | characteristic UUID | UUID, then the value |
| `0x04` write | UUID, then the bytes to write | UUID only. **(check)** The DirCon library replies with the UUID only; other implementations add the FTMS response bytes too. Start with UUID only. |
| `0x05` enable notifications | UUID, then 1 byte: `1` on, `0` off | UUID only |
| `0x07` | empty | empty, success |
| anything else | n/a | response code `0x01`, empty |

- **Unknown service:** response code `0x03`. **Unknown characteristic:** response code `0x04`.
- **An operation a characteristic doesn't allow** (for example writing to Indoor Bike Data): response code `0x05`.

### Pushes from the app (`0x06`)

The payload is the UUID followed by the value.

- **Indoor Bike Data (`2AD2`) and Fitness Machine Status (`2ADA`):** send only to clients that enabled notifications on that characteristic.
- **Control Point responses (`2AD9`):** send to **every connected client**, whether or not it enabled notifications. The DirCon library found Zwift needs this: Zwift doesn't always enable notifications on `2AD9`, and without the Request Control response, pairing never finishes.
- **Optional:** when a client enables notifications on `2AD2`, send the latest Indoor Bike Data frame straight away. Some implementations do this for Apple TV and Windows clients. Add it only if Zwift on the Mac seems slow to show data.

### The characteristics to expose

These are the same as `VirtualTrainerPeripheral` exposes over Bluetooth:

| UUID | Name | Properties | Value / behaviour |
|---|---|---|---|
| `2ACC` | Fitness Machine Feature | read `0x01` | `feature.encoded()` |
| `2AD2` | Indoor Bike Data | notify `0x04` | pushed |
| `2AD3` | Training Status | read+notify `0x05` | `[0x00, 0x01]` |
| `2AD6` | Supported Resistance Level Range | read `0x01` | `resistanceRange.encoded()` |
| `2AD8` | Supported Power Range | read `0x01` | `powerRange.encoded()` |
| `2AD9` | Control Point | write+indicate `0x0A` | writes go to `BridgeController.handleZwiftWrite`; responses are pushed |
| `2ADA` | Fitness Machine Status | notify `0x04` | pushed |

## Steps

### 1. Put the Zwift side behind one interface (refactor, no behaviour change)

- Add a `ZwiftLink` protocol in `App/Gearbridge/BLE/`, based on what `BridgeController` uses from `VirtualTrainerPeripheral` today:
  - Properties: `state`, `subscriberCount`, `feature`, `powerRange`, `resistanceRange`.
  - Callbacks: `onControlPointWrite`, `onChange`, `onLog`.
  - Methods: `start()`, `stop()`, `notify(IndoorBikeData)`, `notify(FitnessMachineStatus)`, `indicate(ControlPointResponse)`.
- Move `VirtualTrainerPeripheral.State` out to a shared `ZwiftLinkState`. It's used by:
  - `BridgeController.zwiftState` (line ~66);
  - `zwiftLabel` (~589);
  - `RideView`'s Zwift pill (~340).
- Move the read values out of `VirtualTrainerPeripheral.readValue(for:)` into a small shared type, so both links answer reads the same way. `TrainerCore` is a good home, for example `VirtualTrainerGATT`, holding feature and ranges and returning the bytes for a UUID.
- `BridgeController`:
  - Replace `peripheral` with `zwift: any ZwiftLink` in every place it's used:
    - init wiring (~300–315);
    - `startRide` (~342);
    - `finishEndingRide` (~376);
    - `reportsPower` (~117);
    - `handle(_:)` `.feature` and `.powerRange` (~716, ~719);
    - `perform` (~742–749).
  - **Keep calling the Bluetooth peripheral's `publish()` at launch, whichever connection is chosen.** Its comment explains why: the Mac caches the iPhone's GATT layout, so the service must be added at launch and never removed.
- Build the app and run `swift test`. Nothing visible should change.

### 2. Direct Connect logic in `TrainerCore` (pure, tested)

New folder: `TrainerCore/Sources/TrainerCore/DirectConnect/`.

- **`DirectConnectMessage`:**
  - Fields: ID, sequence number, response code, optional UUID, data.
  - `encoded() -> [UInt8]`.
  - A stream decoder: feed it bytes; it returns the complete messages and keeps any partial message for the next read.
  - A length or framing it can't make sense of is an error, and the caller closes that connection.
- **`DirectConnectSession`:** one per connected client. No networking.
  - `handle(_ message) -> [DirectConnectMessage]` gives the replies.
  - It reports Control Point writes as an event, and tracks which characteristics the client has enabled notifications on.
  - Reads come from the shared GATT values from step 1.
  - It decides which pushes a client gets: Indoor Bike Data and Status if subscribed, Control Point responses always.
- **Tests** (new `DirectConnectTests.swift`):
  - Encode/decode round trip for every message type.
  - A message split across two reads; two messages in one read.
  - The 16-byte UUID layout of a short UUID.
  - Discover services returns only `1826`. Discover characteristics returns the table above with the right property bytes.
  - A read of `2ACC` returns the feature bytes. A read of an unknown UUID returns code `0x04`.
  - A write to `2AD9` produces a Control Point write event and a UUID-only reply. A write to `2AD2` returns `0x05`.
  - Enable on `2AD2`, then a push of bike data reaches that client. Disable, and it doesn't.
  - A Control Point response reaches a client that never subscribed.
  - `0x07` gets an empty success reply. An unknown ID gets `0x01`.
  - Replies echo the request's sequence number. Pushes use `0`.

### 3. The Wi-Fi link in the app

New file: `App/Gearbridge/BLE/DirectConnectServer.swift`. A `@MainActor` class conforming to `ZwiftLink`.

- **`start()`:**
  - Create an `NWListener` for TCP on port 36866, falling back to any free port, with `noDelay` on.
  - Set `listener.service` to the Bonjour name, type and TXT record above.
  - State: `.starting`, then `.advertising` when the listener is ready.
  - Use `.unavailable("…")` when the phone isn't on Wi-Fi. Use `NWPathMonitor` with `requiredInterfaceType: .wifi` to tell.
- **Each new connection:**
  - Wrap it with a `DirectConnectSession`, read in a loop, and feed the decoder.
  - Write the replies.
  - Route write events to `onControlPointWrite`.
  - Log through `onLog` with the channel `zwift-wifi`: connect, disconnect, subscriptions and errors, as the Bluetooth link logs its events.
- **`subscriberCount`:** the number of connected clients with `2AD2` notifications on. It drives "Zwift connected" and `core.zwiftConnectionChanged`. A closed connection counts as unsubscribed.
- **Backpressure:** mirror the Bluetooth link. If a send to a client hasn't completed, replace any queued Indoor Bike Data with the newest frame rather than queueing a backlog. Keep Control Point responses and Status in order.
- **`stop()`:** cancel the listener and close every connection. **(check)** Make sure Zwift finds the app again on the next ride. If it's slow to, try keeping connections open between rides instead, as the Bluetooth link keeps Zwift's subscriptions.
- **Background:** a ride keeps the app alive in the background through Bluetooth events from the trainer. An open TCP connection should keep working while the app runs, but this has to be tested on the phone (see the checklist).

### 4. The setting

- **`BridgeController`:**
  - `enum ZwiftConnection: String { case bluetooth, wifi }`, saved under a new key, default `.bluetooth`.
  - Changing it during a ride:
    - stop the old link;
    - call `core.zwiftConnectionChanged(connected: false, at:)` if it was connected;
    - start the new one;
    - log `settings: zwiftConnection=…`.
- **`SettingsView` → Zwift page (~line 190–205):**
  - A **Connect over** picker: Bluetooth / Wi-Fi.
  - "Advertised as" stays.
  - With Wi-Fi chosen, the footer says the phone and the Mac must be on the same Wi-Fi network, and that the trainer still connects to the phone over Bluetooth.
  - Keep the ANT+ sentence.
- **`zwiftLabel`:** keep "Waiting for Zwift to pair" and "Zwift connected". Add "Not on Wi-Fi" for the unavailable case.
- **Home screen readiness hints:** check that they still read correctly with Wi-Fi chosen.

### 5. Info.plist

- **`NSLocalNetworkUsageDescription`:** add it as `INFOPLIST_KEY_NSLocalNetworkUsageDescription` in both the Debug and Release build settings of the app target in `project.pbxproj`, next to the Bluetooth one (~lines 283 and 311). Text, for example: "Gearbridge shows up in Zwift on your local network when you connect over Wi-Fi."
- **`NSBonjourServices`:** an array with `_wahoo-fitness-tnp._tcp`. Add it to `App/Gearbridge-Info.plist`, because arrays can't go in build settings.
- No multicast entitlement is needed: advertising a service through `NWListener` doesn't require it.
- iOS asks for local network permission the first time the listener starts. If the user denies it, the listener fails. Show that as `.unavailable("Local network access is off. Allow it in the Settings app.")`.

### 6. README

- **Features:** add "Connects to Zwift over Bluetooth or Wi-Fi."
- **Riding, step 3:** with Wi-Fi, Gearbridge appears in Zwift's pairing lists with a Wi-Fi icon; the phone and the Mac must be on the same network.
- **Troubleshooting:** Wi-Fi not found. Check the same network, guest networks or routers that block devices from seeing each other, the local network permission, and VPNs.
- **Dependencies table:** add Network (Wi-Fi connection to Zwift) and Wahoo Direct Connect (the Wi-Fi protocol).

### 7. Check on the device, with Zwift on the Mac

1. On the Mac, run `dns-sd -B _wahoo-fitness-tnp._tcp` during a ride: Gearbridge should be listed. Then run `dns-sd -L Gearbridge _wahoo-fitness-tnp._tcp` to see the port and TXT record.
2. Zwift's pairing screen shows Gearbridge with a Wi-Fi icon under Power, Controllable and Cadence.
3. Pairing completes: the log shows Request Control from Zwift and the success response going back.
4. Shifting and Zwift's grades reach the trainer. Compare shift feel with Bluetooth.
5. Lock the phone mid-ride: data keeps reaching Zwift for several minutes, and Zwift's grades still reach the trainer.
6. End a ride and start another: Zwift reconnects without re-pairing.
7. Restart Zwift mid-ride: it reconnects.
8. Turn Wi-Fi off on the phone: the app shows "Not on Wi-Fi", and the trainer eases to flat after the usual Zwift-quiet timeout.
9. Deny local network permission (Settings → Privacy → Local Network): the app shows the problem clearly.
10. Switch Bluetooth ↔ Wi-Fi mid-ride: the old connection drops and the new one pairs.

## Open questions

- **Does Zwift on Mac still support Direct Connect?** Forum reports say yes, with occasional regressions. Check before step 3, ideally with the `dns-sd` check plus a quick test of the session from step 2.
- **Write reply format:** UUID only or with the FTMS response bytes (see the **(check)** above). Start with UUID only. If Zwift resends writes or never finishes pairing, try adding the bytes.
- **`ble-service-uuids` format:** `0x1826`, or the full UUID if Zwift doesn't list the device.
- **Does Zwift block power over Direct Connect in events that require a power meter?** Assume yes, the same as Bluetooth. The ANT+ advice in the README stays.

## Sources

- [DirCon (Berg0162/DirCon)](https://github.com/Berg0162/DirCon): an ESP32 gateway tested with Zwift. See `docs/FTMS.md` for the Control Point note and `src/DirConManager.cpp` for the replies.
- [qdomyos-zwift](https://github.com/cagnulein/qdomyos-zwift): the inspiration for this feature.
- [Wahoo: Using Direct Connect](https://support.wahoofitness.com/hc/en-us/articles/360018905100)
- [SmartSpin2k issue 340](https://www.github.com/doudar/SmartSpin2k/issues/340): includes a packet capture of Zwift talking Direct Connect.
