# Virtual Shifting Bridge for Tacx Flux S — Plan

Nov 4, 2026 · @Daniel

## Overview

An iPhone app bridges a Tacx Flux S and Zwift to add virtual shifting. Zwift still reads real power and cadence and still controls hill resistance.

- **Goal:** shifting that feels like a real drivetrain. One sequential up/down list of gears, no front shifting.
- **Zwift keeps working normally:** it receives the trainer's measured power and cadence, and its grade commands still shape resistance.
- **Audience:** personal use only, sideloaded via Xcode. A free Apple ID needs reinstalling every 7 days; a paid developer account ($99/yr) lasts a year.
- **Not in v1:** physical shifter hardware, a Raspberry Pi bridge, App Store distribution.

## Architecture

Zwift runs on the Mac; the bridge runs on an iPhone mounted on the handlebars. Zwift pairs to the iPhone, never to the trainer directly.

&#91;embedded content: bridge architecture · data and command paths\]

Measured data flows through to Zwift unchanged. Zwift's sim values go to the gear engine, which combines them with trainer speed and the current gear to send the trainer its own grade.

- **Upstream:** the iPhone connects to the Flux S as a BLE central (FTMS, or Tacx FE-C over BLE on older firmware).
- **Downstream:** the iPhone advertises a virtual FTMS trainer (BLE peripheral) that Zwift on the Mac pairs to.
- **Data path:** power and cadence pass through unchanged. Power needs no faking, because the gear math keeps real power equal to virtual power.
- **Command path:** Zwift's simulation commands (grade, Crr, Cw, wind) stop at the gear engine, which sends the trainer an adjusted grade.

Constraints:

- **One BLE connection to the trainer at a time.** The Flux S accepts only one Bluetooth connection, and Zwift must never control it directly (over BLE or ANT+), or two controllers fight over resistance.
- **Power-only ANT+ pairing is allowed.** "Power meter required" events reject unrecognized power sources such as the bridge. For those, Zwift pairs Power from the Flux S over ANT+ (USB dongle on the Mac) and Controllable from the bridge, and the bridge's "Send power to Zwift" setting is turned off. Still to confirm: the Flux S keeps broadcasting ANT+ power while the bridge holds its Bluetooth connection.
- **No same-device bridge.** A device can't connect to a BLE peripheral it advertises itself, so Zwift and the bridge need separate devices.
- **Foreground only.** iOS restricts BLE advertising for background apps, so the bridge app stays open on screen. It doubles as the shifter display.
- **Fallback transport:** Direct Connect (DIRCON) over Wi-Fi carries the same FTMS packets over TCP, advertised with Bonjour, if BLE advertising proves unreliable.

## App components

Six components, with the gear engine as the only one holding real logic; the rest move bytes or take input.

| Component | Role | Key details |
| --- | --- | --- |
| Trainer client | BLE central to the Flux S | Subscribe to Indoor Bike Data (0x2AD2); write the FTMS Control Point (0x2AD9); FE-C over BLE fallback |
| Virtual trainer | BLE peripheral seen by Zwift | Advertise FTMS (0x1826); re-publish Indoor Bike Data; ACK every Control Point command; stable advertised name |
| Gear engine | Turns Zwift grade + current gear into a trainer grade | Strategy C force scaling (next section); A and B kept as switchable fallbacks |
| Gear profiles | User-defined gearing | Ordered ratio list, built from a 1× chainring + cassette or entered directly; wheel circumference; starting gear |
| Shift input | Up/down events | On-screen buttons, iPhone volume buttons, hold to multi-shift (\~150 ms repeat); ignored at either end with a distinct haptic |
| UI | Display and settings | Big gear readout, ratio, cadence, power, Zwift grade, "maxed" indicator, packet log, settings |

The real chain stays in one fixed cog, set once in settings (start mid-cassette; default 42×18). It belongs to the bike, not to a profile.

Settings:

- **Gear profiles:** create, edit, choose the active one.
- **Rider:** mass (rider + bike), real chainring and cog.
- **ERG behavior, configurable:** ignore shifts; each shift nudges target power by ±N W; or shifting drops ERG and switches to sim with your gears.
- **Engine:** strategy A/B/C, speed smoothing, shift ramp time (200–300 ms), command rate limit, grade scaling.
- **Calibration:** run the routine, view the fitted values.

## Gear engine math (strategy C)

The trainer stays in sim mode, and the app scales the force it applies so pedal torque matches the virtual gear. Real power then equals virtual power automatically.

**1. Force scaling.** Crank torque is wheel force × ratio × wheel radius, where ratio R = chainring ÷ cog. Equal torque in both gears gives:

```latex
F_{real} = F_{virtual} \cdot \frac{R_{virtual}}{R_{real}}
```

A harder virtual gear means more real force. Power is preserved: F\_real × v\_real = F\_virtual × v\_virtual.

**2. Virtual speed.** Derived from trainer wheel speed, which is smoother than the Flux S's estimated cadence:

```latex
v_{virtual} = v_{real} \cdot \frac{R_{virtual}}{R_{real}}
```

**3. Force the virtual bike needs.** Grade, Crr, Cw and wind come from Zwift's sim command; m (rider + bike) is an app setting. Zwift computes drafting itself and sends it as a reduced Cw (about 0.51 solo, lower in a draft); wind speed is expected to be 0. The engine must use the latest Cw from every sim command, never a cached or constant value, so drafting carries through to the trainer via the adjusted grade.

```latex
F_{virtual} = m g (\sin\theta + C_{rr}\cos\theta) + C_w (v_{virtual} + v_{wind})^2, \quad \theta = \arctan(\text{grade})
```

Set Zwift's Trainer Difficulty to 100%; at the default 50% Zwift halves grades before sending them. Do any softening in the app.

**4. Trainer command.** Send the trainer Crr = 0, Cw = 0, wind = 0 and only a grade, so its force is just its slope term. Solve for that grade using the calibration fit:

```latex
\text{grade}_{cmd} = \frac{F_{real} - a - c \cdot v_{real}}{b}
```

Clamp to the trainer's limits: about 10% simulated grade at the top, and its minimum resistance at the current speed at the bottom (the Flux S has no motor, so descents bottom out there). Show a "maxed" indicator when clamped.

**Worked example:** 80 kg, 5% climb, 85 rpm, real gear 50×17 (R 2.94), virtual 34×28 (R 1.21), wheel 2.1 m, Crr 0.004, Cw 0.51.

| Step | Value |
| --- | --- |
| v\_real (from trainer) | 8.75 m/s (31.5 km/h) |
| v\_virtual | 3.61 m/s (13 km/h) |
| F\_virtual (39.2 slope + 3.1 rolling + 6.7 aero) | 49.0 N |
| P\_virtual | 177 W |
| F\_real | 20.2 N |
| P\_real (check) | 177 W |
| grade\_cmd, if the trainer assumes 75 kg | \~2.75% |

**Choosing the real cog.** A harder real gear lowers F\_real and spins the flywheel faster, giving more headroom on climbs but a higher minimum-resistance floor on flats. Start mid-cassette; calibration data shows the best range.

**Control loop** (runs on each trainer data packet, \~1–4 Hz):

```swift
let vReal    = ema(trainer.speed)                 // smooth noisy speed
let ratioV   = gearbox.currentRatio               // ramps 200–300 ms after a shift
let vVirtual = vReal * ratioV / config.realRatio

let theta    = atan(sim.grade)
let fVirtual = mass * g * (sin(theta) + sim.crr * cos(theta))
             + sim.cw * pow(vVirtual + sim.windSpeed, 2)

let fReal    = fVirtual * ratioV / config.realRatio
var gradeCmd = (fReal - cal.a - cal.c * vReal) / cal.b
gradeCmd     = clamp(gradeCmd, cal.minGrade(vReal), cal.maxGrade)

if abs(gradeCmd - lastSent) > 0.001 || shiftJustHappened {
    trainer.setSimulation(grade: gradeCmd, crr: 0, cw: 0, wind: 0)  // rate-limited
}
```

**Fallback strategies**, behind the same interface:

- **A, grade offset:** each gear adds ±X% grade. Simplest; built first to prove the full loop.
- **B, physics in ERG:** command the trainer to hold the virtual bike's power. Avoids the ERG spiral of death because target power scales with cadence, but ERG lag can feel spongy.

**Left out of v1:** virtual inertia (m × dv/dt). The Flux S's fixed flywheel makes accelerating in a big virtual gear feel slightly too easy; add it once the basic loop feels right.

## Calibration

Calibration fits the trainer's real force response, F = a + b × grade\_cmd + c × v\_real, because the Flux S's internal sim mass and drag aren't documented. The fit replaces trusting physics constants.

1. Run Tacx's own trainer calibration first, so the baseline is clean.
2. Put the chain in the real cog you'll ride in. Results are stored per real cog.
3. The app commands a series of grades with Crr = 0, Cw = 0, wind = 0. Starting values: 0, 2, 4, 6, 8, 10%.
4. At each grade, ride steady at two or three cadences. The app records v\_real and power after a settling period.
5. For each sample, F = P ÷ v\_real. Fit a, b and c by least squares.
6. Record the limits: the grade where measured force stops rising (maxGrade) and the floor force at each speed (minGrade(v)).
7. Try sim command rates of 1, 2 and 4 Hz and keep the fastest that doesn't stutter.

Implementation notes:

- **Power cap.** Each grade is ridden at a high and a low cadence (90/75/60/50 rpm candidates), skipping any whose predicted power exceeds a rider-set cap (default 350 W). In the default 42×18 that reaches 10 % (at 50 rpm only); in a taller gear like 50×17 it stops at 8 %, since 10 % needs about 400 W even at 50 rpm.
- **Max grade.** Saturation is detected by fitting the lower grades and checking whether the next grade falls short of the prediction. If force never stops rising within the measured grades, maxGrade is assumed to be 10 % and shown as assumed.
- **Floor.** Two steps at −15 % measure the minimum force at two speeds.
- **Steadiness.** Each step settles 10 s, then averages 10 s; the window restarts if speed varies by more than 5 % (SD/mean).

The settings screen shows the fitted values and residuals, so a bad fit is visible. Re-run after trainer firmware updates or a change of real cog. Settling time and sample duration are open until the first real runs.

## Code structure and testing

Keep all logic in a pure Swift package so most work happens on the Mac without the bike.

| Layer | Contents | Why |
| --- | --- | --- |
| `TrainerCore` Swift package | FTMS packet encode/decode, gear engine, physics, calibration fit, profile models | Pure logic, unit-tested on the Mac |
| BLE layer | Central (trainer) and peripheral (virtual trainer) wrappers behind protocols | Isolates CoreBluetooth's callback-heavy API; lets DIRCON slot in as a second transport |
| Mock trainer | Fake trainer producing realistic speed, power and cadence | Develop UI and Zwift pairing on the couch |
| iOS app | SwiftUI: gear display, shift input, settings, packet log | Thin layer on top |

Testing support:

- **Packet logging from day one:** every packet, gear change, commanded grade and measured power, exported as CSV. This is how strategy C gets tuned and calibration gets fitted.
- **Captured-packet tests:** real packets recorded from the Flux S and Zwift become fixtures for codec unit tests.
- **Replay harness:** recorded grade profiles and speed traces fed through the gear engine on the Mac.

## Zwift protocol and failure handling

The bridge must answer Zwift exactly like a real FTMS trainer, or Zwift silently stops controlling it.

Zwift-facing behavior:

- **Commands to handle and ACK:** Request Control, Reset, Start/Resume, Set Target Power (ERG), Set Indoor Bike Simulation, and possibly Set Wheel Circumference and Spin Down.
- **Advertised capabilities:** copy the Flux S's real FTMS feature flags and supported power and resistance ranges.
- **Spindown prompts:** decide whether to fake success or forward a real spindown to the trainer.
- **Stable identity:** a fixed advertised name so Zwift recognizes the bridge between sessions.

Failure handling:

- **Trainer drops mid-ride:** keep the Zwift connection alive, report zero or last-known values, auto-reconnect.
- **Zwift stops sending sim commands:** fall back to a safe, moderate resistance instead of freezing at the last grade.
- **Bridge app crashes:** the trainer holds its last command, possibly a steep grade. Reset resistance on reconnect.

## Milestones

Each milestone ends with something testable on the bike or the Mac. Milestones 2–3 carry most of the BLE learning; after that it is app logic.

- [ ] **0. Protocol check.** Scan the Flux S with the free nRF Connect app and note whether it exposes FTMS (0x1826), Tacx FE-C over BLE, or both.
- [ ] **1. Core package.** `TrainerCore` with FTMS codecs, unit tests from captured packets, and the mock trainer.
- [ ] **2. Pass-through bridge.** Zwift on the Mac pairs to the iPhone and shows the trainer's correct power and cadence.
- [ ] **3. Transparent control.** Zwift's grade commands forwarded unchanged; hills feel identical to a direct connection. This is the baseline. Also confirm from the packet log that Cw drops when drafting in a group and that wind speed stays 0.
- [ ] **4. Strategy A + shifting.** Grade-offset engine, on-screen and volume-button shifting, haptics, packet log export.
- [ ] **5. Calibration + strategy C.** Calibration routine, then the force-scaling engine; compare against A on real rides.
- [ ] **6. Polish.** Gear profile editor, ERG settings, tuning knobs, failure handling.

## Risks, open questions and future options

The biggest unknowns are the Flux S's protocol support and its internal sim model; both are answered in milestones 0 and 5.

Risks:

- **Trainer limits:** about 10% max simulated grade and weak resistance at low flywheel speed. Very hard gears at slow cadence will feel capped.
- **Sim command rate:** unknown how fast the Flux S accepts updates without stuttering; assume 2–4 Hz until measured.
- **iOS advertising:** background restrictions require the app in the foreground; DIRCON over Wi-Fi is the fallback.
- **Zwift caching:** Zwift may remember trainers by name or ID; keep the advertised identity stable.

Open questions:

- Does the Flux S firmware expose FTMS, or only FE-C over BLE?
- Fake or forward Zwift's spindown requests?
- Calibration settling time and sample length.
- Which ERG behavior to default to.

Future options:

- **Bluetooth handlebar remote** paired to the iPhone. Prefer one sending plain arrow or letter keys, which reach the app as key events; volume keys need the same observation trick as the phone's buttons.
- **M5Stack CoreInk** as a handlebar shifter and e-ink gear display: ESP32 with BLE, a rotary switch for up/down, buzzer, built-in battery. The iPhone connects to it as a second BLE device.
- **Raspberry Pi bridge** for an always-on box: BlueZ handles both roles on one adapter (USB BLE dongle as fallback); Go or Python instead of Swift; GPIO buttons or a web UI for shifting.
- **Same-Mac setup** via DIRCON: bridge and Zwift on one Mac, if Zwift discovers a locally registered Bonjour service.
- **Virtual inertia** term in the gear engine.

Reference: the open-source qdomyos-zwift (QZ) project implements trainer bridging, virtual gears and DIRCON, and is useful for protocol details.
