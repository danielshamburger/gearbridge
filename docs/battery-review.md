# Battery review

Goal: use as little battery as possible during a ride, without adding any latency to shifting or to Zwift's grade changes (see `performance-review.md`).

Nothing here has been measured yet. The power figures are typical published values for recent iPhones, there only to rank the items. Measure with Xcode's Energy gauge, or battery % over a one-hour ride, before relying on them.

## Where the power goes

| Consumer | Rough draw | Why |
|---|---|---|
| **Display** | 0.4–1.5 W, depending on brightness | The screen stays on for the whole ride (`isIdleTimerDisabled`, `RideView.swift:49`), because the app has no Bluetooth background modes and is suspended if the phone locks. |
| Bluetooth radio | 10–50 mW | Two connections (trainer and Zwift), plus advertising. |
| CPU wake-ups | a few to tens of mW | Timers: the 50 Hz control loop, the 10 Hz timeout check, the 1 Hz failsafe tick. |
| UI updates | small | The ride screen redraws about 4–8 times a second with live numbers. |
| Logging, haptics, audio session | negligible | |

A recent iPhone holds about 13–17 Wh. At roughly 1 W in total, a one-hour race uses about 6–8% of the battery. **The screen is most of that.** Everything else together is probably under a tenth of it.

## Changes with no tradeoff (recommended)

These cost nothing in latency or features.

1. **Make the 50 Hz control loop event-driven.**
   - Today `startControlLoop` wakes the CPU 50 times a second, all ride long, and almost always finds nothing to send.
   - Instead, `BridgeCore` can report when a deferred command becomes due (`lastSendTime + 0.25 s`), and the controller arms a single timer for that moment.
   - Latency stays the same, and there are no wake-ups while nothing is waiting.
2. **Arm the trainer timeout only while a request is waiting.**
   - `FTMSTrainerLink`'s timeout loop runs at 10 Hz for the whole connection.
   - A one-shot timer started when a request is written, and cancelled when the reply arrives, does the same job.
3. **Stop advertising once Zwift is connected.**
   - The virtual trainer keeps advertising even after Zwift subscribes, so the radio keeps transmitting adverts all ride.
   - Stop when Zwift subscribes, and restart as soon as it unsubscribes, so reconnecting is just as fast.
4. **Only update UI state that actually changed.**
   - `refreshShiftState` assigns six properties on every packet, which redraws the gear area even when nothing changed.
   - `record()` updates `logCount` on every log entry.
   - The fix: compare values before assigning, and update the log count at most once a second. This is also finding 10 in the performance review.
5. **Use a dark ride screen.**
   - On OLED iPhones (every model since the X except the SE and XR/11), black pixels draw almost no power.
   - Ride screen background: true black. The grouped `List` currently uses grey cards in light mode.
   - The gear number and readouts stay bright and readable.

Together these trim the non-display part. Item 5 is the only one that touches the display, and it can matter more than all the others combined.

## Changes with a tradeoff

| Option | Battery saved | Cost |
|---|---|---|
| **Dim the screen while riding.** Drop brightness to ~15% after about 15 s without a touch; a tap restores it. Volume-button shifts don't need the screen. | **Largest available:** roughly halves the display's draw. | The screen is harder to read at a glance until tapped. Brightness is a system setting, so the app must restore it when the ride ends or the app leaves the foreground. |
| **Update the live readouts once a second instead of on every packet.** The gear number stays instant. | Small | Power, cadence and speed on the phone lag up to 1 s. Zwift is unaffected. |
| **Turn off the detailed packet log.** Keep events only. | Very small | Less to diagnose problems with afterwards. |
| **Lower the Bluetooth command rate or ask for higher connection latency.** | Small | **Adds lag.** Not recommended for racing. |
| **Add Bluetooth background modes so the phone can lock.** | The largest, if the screen can be off | See below. Shifting mostly stops working while the phone is locked. |

### Letting the phone lock

With the `bluetooth-central` and `bluetooth-peripheral` background modes, the connections survive a locked screen. Trainer data still reaches Zwift and Zwift's grades still reach the trainer, because Bluetooth events wake the app. But:

- **The on-screen buttons can't be used.**
- **Volume-button shifting is unreliable or doesn't work.** The method the app uses needs the app on screen.
- **Timers aren't guaranteed to run.** That includes the deferred-send timer and the failsafe tick.
- **Zwift may not see the app if it needs to re-pair.** iOS drops the advertised name and services from adverts in the background.

So a locked phone means riding with no virtual shifting. That rules it out as a battery setting. It is still worth adding as **protection against an accidental lock or interruption mid-race**: instead of the bridge dying, Zwift keeps getting power and the trainer keeps getting grades until you unlock. Whether to do this is a separate decision from battery.

## Power settings?

The tradeoffs aren't big enough to justify Normal / Low Power / Race modes:

- Apart from the screen, every saving is either free (do it for everyone) or too small to notice.
- The only option that would noticeably cut latency is one we shouldn't offer for racing.

**Recommendation:**

1. Make the five no-tradeoff changes for everyone.
2. Add one setting, **"Dim screen while riding"**, off by default. It's the only option with a meaningful saving, and it costs only readability.
3. Separately, consider the Bluetooth background modes for robustness, not for battery.

Riders worried about battery on long events can also just keep the phone plugged in. The app has no reason to discourage that.
