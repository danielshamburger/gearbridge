# Performance review: latency

Goal: a shift, or a grade change from Zwift, should reach the trainer as fast as Bluetooth allows. Nothing else the app does should ever delay it. This matters most in races.

This review reads the code paths. I haven't measured on a real Flux S yet. Findings 1 and 2 were confirmed with a probe test against `TrainerCore`.

**Status:** findings 1–5 and 9 are fixed, each covered by `LatencyTests`. The rest are still open.

## The paths that matter

| Path | Route |
|---|---|
| **Shift** | button or volume key → `BridgeController.shift` → `BridgeCore.shift` → `CommandThrottle` → `ControlPointQueue` → BLE write to the trainer |
| **Zwift grade** | Zwift write → `VirtualTrainerPeripheral` → `BridgeCore.handleZwift` → throttle → queue → trainer |
| **Trainer data** | trainer notify → `FTMSTrainerLink` → `BridgeCore.handleTrainerData` → notify Zwift, and possibly re-command the trainer |

Everything runs on the main thread: both CoreBluetooth managers use `queue: nil`, alongside SwiftUI.

## Findings, worst first

### 1. ✅ Fixed. In calibrated mode, a shift's first command still used the old gear (high)

`ShiftingEngine.command` uses `gearbox.ratio(at: time)` (`ShiftingEngine.swift:86`). At the moment of a shift, the 0.25 s ramp hasn't started, so the ratio is still the old gear's (`Gearbox.swift:55`). The force-scaling strategy works from that ratio, so the command sent on the shift carries the **old** resistance. The new gear only reaches the trainer on later trainer data packets as the ramp moves forward.

Probe result: grade before the shift 8.06%, grade sent at the shift 8.06%, grade 0.3 s later 10%.

At a 1–4 Hz data rate, the full gear change lands about 0.25–1 s or more after the press. Simple mode isn't affected, because its offset uses the gear index, which changes immediately.

**Fix:** pick one or both.
- Drop the ramp, or make it much shorter (e.g. 0.1 s). The trainer's own brake response already smooths the change.
- Drive the ramp from a timer, independent of trainer data. See finding 3.

**Done:** the ramp now defaults to 0, so the command sent on a shift is final. `Gearbox` still supports a ramp if one is wanted later.

### 2. ✅ Fixed. A shift within 0.25 s of the last send waited for the next trainer data packet (high)

`CommandThrottle.shouldSend` refuses any send within `minimumInterval` (`ControlLoopHelpers.swift:68`). A forced send only sets `pending`, and pending sends are only retried when `handleTrainerData` runs. So a shift (or a new grade from Zwift) that comes within 0.25 s of a data-triggered send waits for the **next data packet**: up to 1 s at 1 Hz.

Probe result: a shift 0.1 s after a send produced no output. It went out with the next packet.

In the sim modes there's usually a send on every data packet, so a large share of shifts hit this.

**Fix:** when a forced send is refused, schedule it for `lastSendTime + minimumInterval`.
- In `BridgeCore`, return a "send due at t" alongside the outputs.
- In `BridgeController`, run a one-shot timer for that time and call a new `core.flush(at:)`.

The worst case then becomes 0.25 s instead of one data period. Also consider lowering `minimumInterval` once the Flux S's acceptable command rate is measured (plan step 7).

**Done:** added `BridgeCore.flush(at:)`, called by a 50 Hz control loop while riding. A deferred command now goes out within 20 ms of the throttle allowing it. Lowering `minimumInterval` is still open.

### 3. ✅ Fixed. The engine only ran when trainer data arrived (medium)

Speed smoothing, ramps and pending sends all advance only in `handleTrainerData`. The trainer's data rate therefore sets the bridge's reaction time.

**Fix:** a 20–50 Hz control tick while riding, which calls `core.flush(at:)`. Most ticks would do nothing, because the throttle drops unchanged commands. This also fixes the stalled ramp in finding 1 and the wait in finding 2.

**Done:** the 50 Hz loop in `BridgeController.startControlLoop`. It stops at the end of a ride.

### 4. ✅ Fixed. A Control Point request the trainer never answered blocked the queue for up to 2.5 s (medium)

FTMS allows one request in flight. `ControlPointQueue` waits up to 2 s for a response (`ControlPointQueue.swift:18`), and the timeout is only checked every 500 ms (`FTMSTrainerLink.swift:101`). If the Flux S drops one response, every shift and grade change waits behind it.

**Fix:**
- Cut the timeout to about 0.5–0.75 s. Measure the Flux S's normal response time first; the log has both send and response times.
- Check the timeout when something is enqueued, as well as in the loop.

**Done:**
- The timeout is now 0.75 s, checked on every enqueue and every 100 ms.
- Still to do: confirm against the Flux S's measured response time, and raise the timeout if its normal responses come close to 0.75 s.

### 5. ✅ Fixed. A backed-up Zwift transmit queue delivered stale data (medium)

When `updateValue` fails because the transmit queue is full, `VirtualTrainerPeripheral.send` appends the packet to `pending`, up to 50 (`VirtualTrainerPeripheral.swift:34`, `:95`). Indoor bike data then reaches Zwift in order, oldest first. With 50 queued at 4 Hz, that is up to about 12 s behind, and Zwift shows old power and cadence.

**Fix:**
- Keep only the newest packet for notify-only characteristics: indoor bike data and status.
- Keep Control Point indications in order, since Zwift needs every response.

**Done:** only the newest bike data packet waits in the queue. Responses and status stay in order.

### 6. Exporting the log blocks the main thread (medium, only if used mid-ride)

`writeLogFile` builds the whole CSV on the main thread (`BridgeController.swift:419`). `PacketLog.Entry.hex` uses `String(format:)` per byte (`PacketLog.swift:23`). For a long ride (100k+ entries), this could stall the main thread for a second or more, and with it all Bluetooth handling.

**Fix:**
- Copy `log` (a cheap copy-on-write value) and build and write the CSV in a detached task.
- Format hex with a lookup table instead of `String(format:)`.

**Done (2026-11-06):** all three.

### 7. A full log costs time on every packet (low now, grows with ride length)

At capacity (200k entries), each append calls `entries.removeFirst(overflow)` (`PacketLog.swift:45`). That shifts the whole array: about 200k moves on every packet, on the main thread. At ~15 entries/s the log fills after about 3.5 hours. Memory before that is roughly 30–50 MB, because each entry holds a heap `String` and a `[UInt8]`.

**Fix:**
- Use a ring buffer, or stream entries to a file on a background queue.
- Store `summary` lazily: keep the decoded value and format it at export time.

**Done (2026-11-06):** a ring buffer, and trainer data entries keep the decoded values until export.

### 8. SwiftUI and Bluetooth share the main thread (low to medium)

Both CoreBluetooth managers deliver on the main queue (`FTMSTrainerLink.swift:47`, `VirtualTrainerPeripheral.swift:59`). Any slow main-thread frame delays packet handling by that frame's duration, e.g.:
- presenting the Settings or Calibration sheet;
- a long `Picker` list;
- the CSV export in finding 6.

Usually that's a few ms, but sheet presentations can take 50–100 ms.

**Fix:** move the bridge onto its own serial queue or actor:
- `CBCentralManager` and `CBPeripheralManager` with `queue: bridgeQueue`;
- `BridgeCore`, the queue and the log on that queue;
- a snapshot published to the UI at ~10 Hz.

This is the biggest change here. Do it after the fixes above, and only if measurement shows main-thread stalls.

### 9. ✅ Fixed. Shift order: the haptic and log ran before the Bluetooth write (low)

`BridgeController.shift` fires the haptic (`:279`) and formats a log line before `perform(outputs)` (`:288`). Both are fast; the generator is prepared. Still, the write should go first.

**Fix:** call `perform(outputs)` first, then haptics, logging and UI state.

**Done.** As a result, the `app>trainer` write now appears in the log just *before* its `shift` event.

### 10. Every data packet re-renders the ride screen (low)

`refreshShiftState()` runs on every data packet (`BridgeController.swift:472`). It assigns `gearNumber`, `gearCount`, `gearRatio`, `gearLabel`, `trainerGrade` and `limit` even when they haven't changed. `@Observable` invalidates on every set, not only on changes.

`record()` also sets `logCount` on every entry (`:431`), which invalidates the Settings screen while it's open. With `latestData` also changing, the whole `List` is rebuilt about 4–8 times a second.

**Fix:** only assign when the value differs, and update `logCount` at most about once a second.

### 11. Speed smoothing makes sprints feel delayed (feel, calibrated mode)

Calibrated shifting computes resistance from speed smoothed with a 1 s time constant (`ControlLoopHelpers.swift:13`). In a sprint, real speed rises faster than the smoothed value, so the aero part of the resistance trails by about a second. That can feel like lag even when commands go out on time.

**Fix:** after measuring how noisy the Flux S's speed really is, shorten the constant to about 0.3–0.5 s, or smooth less while speed is rising.

### 12. Volume-key shifts take an extra main-actor hop (low)

The KVO callback hops to the main actor with `Task { @MainActor … }` (`VolumeButtonShifter.swift:73`). That adds one run-loop turn, which is small. iOS's own delay between a key press and the volume change, maybe 50–100 ms, is larger and can't be changed. On-screen buttons are the fastest input.

## Fine as is

- **FTMS encoding and decoding, `BridgeCore`, the strategies:** a few microseconds per packet, with no allocations worth worrying about.
- **Control Point coalescing:** a burst of grade updates while one request is in flight collapses to the newest, which is correct for latency.
- **The 1 Hz failure-handling tick:** cheap.
- **Haptic generators:** prepared ahead of time, so they don't stall the first shift.

## Measured on the Flux S (2026-11-05, first real ride)

From a 5-minute ride log (simple shifting, no calibration):
- **Control Point response:** median 0.26 s, 90th percentile 0.41 s, slowest 0.65 s. Every request is answered; none timed out.
- **Shift to write:** median 0.10 s, 90th percentile 0.25 s, slowest 0.40 s. Shifts that came while a request was in flight waited for its response, then up to ~50 ms more for the throttle's 0.25 s spacing.

Changes made from this:
- Shifts and Zwift commands no longer wait for the throttle's spacing. The queue already allows one request in flight and coalesces the rest, so the trainer's own ~0.26 s turnaround is the limit. Routine re-sends from trainer data still use the 0.25 s spacing.
- The queue timeout went from 0.75 s to 1.0 s, so a slow-but-valid answer (0.65 s seen) is never treated as lost.

What's left is the trainer itself: about 0.26 s to accept a command, then however long the brake takes to change resistance. Neither is in the app's control.

## Measure on the real trainer

- **Shift to write:** the `app>trainer` row now sits right before its `shift` event, so a well-behaved shift shows about 0 ms. Look for shifts with no write next to them: those were deferred by the throttle and should follow within about 0.27 s.
- **Write to response:** time from an `app>trainer` write to its `trainer>app` response. This sets the queue timeout in finding 4.
- **Data rate:** how often indoor bike data arrives from the Flux S. This sets how bad findings 1–3 are today.
- **Main-thread stalls:** an Instruments "Hangs" or Time Profiler trace during a ride, with Settings opened and closed.

## Suggested order

1. ~~Findings 1–3~~ done.
2. ~~Findings 4 and 5~~ done.
3. Findings 6, 7 and 10: cheap clean-ups. (Finding 9 is done.)
4. Finding 11: tune speed smoothing once the Flux S's speed noise is known.
5. Finding 8, only if measurement shows main-thread stalls.
