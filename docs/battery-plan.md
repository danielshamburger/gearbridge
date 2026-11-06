# Plan: battery improvements

The background is in [battery-review.md](battery-review.md). None of this is started.

**Rule for every step:** no added latency for shifts or Zwift grades. Steps 1–2 change the timing code, so the `LatencyTests` suite must still pass after them.

## Part 1: no tradeoff, for everyone

### 1. Event-driven control loop instead of 50 Hz polling

**Core:**
- Give `CommandThrottle` a `nextDue: TimeInterval?`: `lastSendTime + minimumInterval` while a forced send is pending, otherwise nil.
- Give `BridgeCore` a `flushDue: TimeInterval?` that returns it, or nil when there's no engine, during an override, or in ERG.

**App:**
- In `BridgeController`, after every `perform`, if `core.flushDue` is set, arm one timer for that time. Cancel or re-arm it if the due time changes.
- When the timer fires, call `core.flush(at:)`.
- Delete `startControlLoop`.

**Tests:**
- `flushDue` is nil when nothing is deferred.
- `flushDue` equals the last send time + 0.25 s after a deferred shift.
- `flushDue` is nil again after the flush.

### 2. One-shot trainer timeout instead of a 10 Hz loop

`FTMSTrainerLink`:
- When a request is written, start a timer for `queue.timeout`.
- When its reply arrives, cancel the timer.
- When the timer fires, call `checkTimeout`, and write the next request if there is one.
- Delete `startTimeoutLoop`.

### 3. Stop advertising while Zwift is connected

`VirtualTrainerPeripheral`:
- When `subscriberCount` goes from 0 to more than 0, call `stopAdvertising()`.
- When it goes back to 0, call `startAdvertising` straight away.

Keep `state == .advertising` meaning "ready", or add a `.connected` state so the label stays accurate.

Check with Zwift: a reconnect after a Wi-Fi blip or a Zwift restart must still find the trainer quickly.

### 4. Only update UI state that changed

`BridgeController`:
- `refreshShiftState` compares each value before assigning it: `if gearNumber != new { gearNumber = new }`, and the same for the rest.
- Update `logCount` at most once a second, from the 1 Hz tick, not from `record()`.
- Apply the same check to `zwiftMode` and `fallback` in `handleZwiftWrite`.

### 5. Dark ride screen

`RideView`:
- Force a dark colour scheme on the ride screen only, with a black background behind the list.
- Keep the gear number and readouts high-contrast.
- The home and settings screens follow the system setting.

## Part 2: one setting

### 6. "Dim screen while riding" (off by default)

**Setting:** in Settings, under a new "Display" section, persisted like the other settings.

**While riding with the setting on:**
- After 15 s without a touch, ease `UIScreen.main.brightness` down to about 0.15.
- Any touch brings brightness back to its earlier value and restarts the 15 s countdown.
- Shifts with the volume buttons don't wake the screen.

**Restore the original brightness when:**
- the ride ends;
- the app goes to the background (`scenePhase` not active);
- the ride view disappears.

Brightness is a system-wide value, so the app must never leave it dimmed.

**Notes:**
- Read the starting brightness when the ride starts, not at launch.
- Catch touches with a simultaneous gesture on the ride screen, so the buttons still work on the first tap.

## Part 3: optional, for robustness (not battery)

### 7. Keep Bluetooth working while the phone is locked

**Status:** done. The background modes are in `App/TrainerCtrl-Info.plist`. `BackgroundRideGuard` ends a ride after 10 minutes in the background without pedalling. The device checks below are still to do.

**Setup:** add the `bluetooth-central` and `bluetooth-peripheral` background modes (`INFOPLIST_KEY_UIBackgroundModes` in the project).

**Expected while locked:**
- Trainer data still reaches Zwift.
- Zwift's grades still reach the trainer.
- Shifting pauses.

**Check on the device:**
- Do the timers (deferred send, 1 Hz failsafe tick) run between Bluetooth events? If not, move the stale-data check onto the data path.
- Does Zwift stay connected through a lock and unlock?
- Is the volume-button shifter still working after unlocking? Restart it on becoming active if not.
- Add a ride-screen note when coming back from background: "Phone was locked: shifting paused".

## Related open items from the performance review

Cheap, and they help both latency and battery:
- Build the log export off the main thread.
- Use a ring buffer for the packet log, with formatting deferred until export.
- Tune speed smoothing once the Flux S's speed noise is measured.

## Measuring

Before and after Part 1, and with step 6 on:
- Xcode's Energy gauge during a 10-minute simulated ride, with the screen at the same brightness each time.
- Battery % over a one-hour real ride.
