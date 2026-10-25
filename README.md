# Autobot

A personal iOS companion app for the car. It drives a Bluetooth LED ambient-light controller
directly (no vendor app needed), reacts to manual shifting (worked out from OBD2 live data), the
turn signals (heard on the car's CAN bus) and door state, and greets the driver with a voice
assistant when the phone connects to CarPlay.

> Personal hobby project. Not affiliated with the lamp manufacturer, Google, Tencent (QQ Music)
> or Hasbro. Use the voice features hands-free and keep your eyes on the road.

## Features

### Ambient lighting
- **Power Mode when shifting by hand** (M; OBD2 Bluetooth adapter, see
  [Manual shifting detection](#manual-shifting-detection))
  - driving in D: steady purple (zone 1 at 50 %, zone 2 at 100 %)
  - shifting yourself and holding the revs: firmware *Red Gradient* breathing, until the revs
    have stayed at or below 2500 r/min for 10 s
  - switching goes through a 3-second *buffer zone*: red burst flash + the Power Mode
    announcement, then the trigger is checked again and the new lighting is applied, or the
    old one restored if it went back
  - other triggers in `AppConfig.PowerMode.trigger`: `.engineRPM` (2500 r/min) and `.speed`
    (GPS, 90 km/h)
- **Reverse → yellow breathing**: with the lever in R the lamp does the firmware's *Yellow Gradient*
  breathing, on Power Mode's level: the turn signals / hazard lights, the A/C flash, Power Mode's
  switch flash and the door alert still go above it. Out of R it's Power Mode again (purple steady,
  red breathing in M). The lever is the TCM's `7E1 221E12` (`3C` in R), already read every round;
  the dashboard's *R* button stands in for it.
- **Turn signals and hazard lights → Yellow Burst Flash** (OBD2 adapter, see
  [Turn signals](#turn-signals)): while the indicators or the hazard lights flash, the lamp does the
  firmware's *Yellow Burst Flash*, above Power Mode — in M too, and during a Power Mode switch. When
  they stop, the lamp goes back to what it should show then: red breathing if still in M, the red
  switch flash if a Power Mode switch is still in its 3 s, purple steady in D. The dashboard's
  *Left* / *Hazard* / *Right* buttons stand in for them (tap to start, tap again to stop).
- **A/C temperature flash**: the temperature dial turned colder → *Blue Burst Flash*, warmer →
  *Red Burst Flash*, until 3 s after the last click. Another click the same way starts the 3 s
  again; a click the other way switches the colour at once (the later turn wins). Then the previous
  lighting comes back. Ready, but not fed by the car yet: this CX-5 keeps the set temperature in the
  climate control unit on MS-CAN, which the KW905 can't reach (see
  [A/C set temperature](#ac-set-temperature)); the dashboard's *A/C −* / *A/C +* buttons stand in
  for the dial. **Currently off** (`AppConfig.Climate.enabled = false`): the A/C row is hidden and
  the climate control unit isn't checked, until there's an MS-CAN capable adapter.
- **Door safety alert** (highest priority): any door or the boot open → *Red Burst Flash* and
  "Door open detected"; when everything is closed the previous lighting comes back.
  Door state comes from the car: the body control module's door status (`726 22C150`), or a
  door the [door finder](#doors-which-one-is-open) learned (test buttons while neither is read).
- **Priority arbiter**: every lighting feature requests a scene with a priority, the highest
  one wins, and withdrawing a request restores the next one. From the top: door alert, turn
  signals, A/C flash, Power Mode switch flash, then reverse / Power Mode (R and M never meet).
- **Reliable commands**: one packet at a time, mode changes are read back and resent if the
  lamp disagrees, "busy" / checksum-error replies are retried.

### Voice
- "Power Mode Activated" / "Power Mode Deactivated" in the assistant's female voice, spoken navigation-style: other audio is ducked,
  not stopped.
- A single voice queue so prompts never overlap; urgent alerts go first.

### Welcome assistant (CarPlay)
Runs once per drive when the lamp is connected and CarPlay audio is detected:

1. pauses the music, says *"Welcome back, Tim."*
2. 06:00–11:59: a one-sentence weather briefing (Open-Meteo, no API key)
   - **Weekday commute**: Monday–Friday 07:00–09:59, within 300 m of the saved place marked
     **Home**, with a place marked **Work**: no question. Navigation to Work starts and the music
     is handled as in step 6, then *"Navigating to work."* and *"The music is now continued."*
     (once it's playing). Steps 3–5 are skipped.
3. asks *"Where is our destination today?"* and listens (English and Mandarin at once,
   on-device; stops 1.5 s after you finish, gives up after 10 s of silence)
4. understands the reply with Apple Intelligence when available, keyword rules otherwise
5. opens Google Maps:
   - a **saved place** with an exact street address → starts navigation
   - anything else → searches so you can pick
6. music:
   - was playing → it resumes after Google Maps opens
   - nothing was playing → runs a shortcut that starts QQ Music and opens Google Maps:
     - navigation (weekday commute, saved place with an exact address) → **最近播放的歌** with
       the navigation link (the route starts by itself, then QQ Music comes up)
     - search or no destination → **Lamp Drive** with the search text (QQ Music first, then
       Google Maps search, so you can pick the result)
     - if iOS refuses to open Shortcuts, Google Maps is opened directly (no music)

If the phone is locked or the app is in the background, it only says the greeting.

### Saved places
Name + address pairs ("home" → "6 Example Street, Suburb, City"). Say the name (in any
supported language) to navigate there directly. If speech recognition gets one or two
characters wrong, the closest matching saved name or address is used. Export / import as a
versioned JSON backup.

Swipe right on a place (or use *Use as* in the editor) to mark it as **Home** or **Work**; only
one place can have each. Home's address is looked up on Apple Maps once and cached, for the
weekday commute check. Hours, days and radius are in `AppConfig.Commute`.

## Requirements

- iPhone with iOS 26.4+, Xcode 26+
- The lamp: BLE controller advertising as `Pocket Link …` (Zhuhai Jieli chipset), the one used
  by the *LAMP&FRGN* Android app
- The OBD2 adapter: ELM327-compatible BLE adapter advertising as `KONNWEI` (service `FFF0`),
  plugged into the car's OBD port. Close its own app (MAXOBD) while driving, otherwise both apps
  talk to the adapter at once
- The car: set up for a Mazda CX-5 2.2 diesel (2015) with the 6-speed automatic. For another
  car, change the gear ratios, the top-gear r/min per km/h and the D-mode limits in
  `AppConfig.Manual`
- Optional: Google Maps, QQ Music, CarPlay head unit, an iPhone with Apple Intelligence

## Getting started

1. Open `Autobot.xcodeproj`, choose your signing team, run on a real iPhone (Bluetooth, GPS and
   CarPlay don't work in the simulator). A free developer account works; the app must be
   re-signed every 7 days.
2. Allow Bluetooth, Location ("While Using" is enough), Microphone and Speech Recognition.
3. For "start music when nothing was playing", create two shortcuts in the Shortcuts app
   (names in `AppConfig.Music`):
   - **最近播放的歌** (navigation; input = Google Maps navigation link):
     *Open* (Shortcut Input) → *QQ音乐 – 最近播放*
   - **Lamp Drive** (search / no destination; input = search text or nothing):
     *QQ音乐 – 继续播放* → *If* Shortcut Input *has any value*: *Google Maps – Search*
     (query = Shortcut Input), *Otherwise*: *Open App – Google Maps* → *End If*

   The app runs them with plain `shortcuts://run-shortcut` links (no x-callback: since
   iOS 26.5, iOS refuses to open x-callback Shortcuts links from other apps).
4. Optional: in Settings → Accessibility → Spoken Content → Voices, download an enhanced or
   premium English (US) female voice (e.g. Zoe or Ava) for clearer voices.

The dashboard has test buttons for the welcome flow, both Power Mode voices, every door, reverse
and the turn signals.

## Lamp protocol

Reverse-engineered from the Android app (`com.szraise.carled` 1.2.7) for interoperability.

| | |
|---|---|
| Service | `AE30` |
| Write | `AE01` (write without response) |
| Notify | `AE02` |

Frame: `2E | type | len | data… | checksum`, where
`checksum = (type + len + Σ data) XOR 0xFF` (low 8 bits).

| Command | Type | Data |
|---|---|---|
| Start (after connect) | `81` | `01` |
| Brightness | `8D` | `00, flags (0x40 = on), zone1, zone2` (0–100) |
| Colour | `8D` | `01, 08 (single colour) / 00 (two zones), R1 G1 B1, R2 G2 B2` |
| Mode | `8D` | `02, rhythm<<4 \| mode1, mode, parameter, speed` |
| Query | `90` | `7C, 00 brightness / 01 colour / 02 mode` → reply type `7C` |

Modes used: `0` steady, `2` breathing (parameter `1` = red gradient, `2` = yellow gradient), `3` burst flash
(parameter `1` = red, `2` = yellow, `5` = blue; the app's list is 0 colourful, 1 red, 2 yellow, 3 green, 4 cyan,
5 blue, 6 purple, 7 white). A single-byte reply `FF` is an ACK; `F0` checksum error, `F3` not
supported, `FC` busy.

The firmware also knows "original car" functions (turn signal, doors, overspeed… and a
*Temperature adjustment Reminder*, 气候模式). The app only offers them when the controller reports
them for the selected car model (query `90 9C`), which takes the vendor's CAN box wired to the car;
Autobot doesn't use them. Its yellow turn-signal flash is its own: it hears the indicators on the CAN
bus through the OBD2 adapter (see [Turn signals](#turn-signals)) and sends the plain *Yellow Burst
Flash* mode (`2E 8D 05 02 xx 03 02 ss cs`, after the custom colour `FF FF 00`).

## OBD2 adapter

A KONNWEI Bluetooth LE OBD2 adapter, ELM327-compatible. Its own app, MAXOBD
(`com.jiawei.maxobd` 1.1.03), identifies the car as ISO 15765-4 CAN with 11-bit IDs and the engine
ECU answering from `7E8`.

| | |
|---|---|
| Service | `FFF0` |
| Write | `FFF2` (write without response): ASCII command + `\r` |
| Notify | `FFF1`: ASCII reply in chunks, ending with the `>` prompt |

After connecting: `ATZ`, `ATE0`, `ATL0`, `ATS0`, `ATH0`, `ATAT1`, `ATSP6`, `ATSH7E0`, then `0100`
until the engine ECU answers (ignition on), then `0100`, `0120`, … to list the PIDs it has
(written to the log). After that, about three times a second (a little less often while the turn
signals are listened for, see [Turn signals](#turn-signals)):

| Request | Reply | Value |
|---|---|---|
| `010C0D1` | `41 0C A B 0D C` | RPM = (256·A + B) / 4, speed = C km/h |
| `015A1` (or `01491`, `01041`) | `41 5A A` | pedal (or engine load) = A · 100 / 255 % |
| `01A41`, only if the car has it | `41 A4 A B C D` | gear = upper half of B |

The trailing `1` tells the adapter one reply is enough; it is dropped if the adapter answers `?`.
If the ECU answers only one PID per request, RPM and speed are asked separately.
Protocol, request header and timings are in `AppConfig.OBD`.

### Transmission: P / R / N, the gear, and M vs D

After the PID list, Autobot asks the transmission module (TCM, `7E1`, answers from `7E9`) over UDS
*service 22* (read data by identifier), which the KW905 passes straight through. Measured on this
car with the lever in each position:

| Lever | `7E1 221E12` (TCM "gear") | `7E0 221E1F` (PCM) |
|---|---|---|
| P | `46` | `80` |
| R | `3C` | `81` |
| N | `32` | `80` |
| D (stopped, 1st) | `01` | `81` |
| M1 | `01` | `81` |
| M2 | `02` | `81` |

So `221E12` gives **P, R, N and the real gear** (no more RPM ÷ speed estimate), but **D1 and M1 read
the same** — neither value carries the M flag. The M finder (below) found it in **`7E1 221E03`,
byte 0, bit `0x10`**: `00` in D, `10` in M. That is built in (`AppConfig.Transmission.mFlag`), so
Power Mode follows M ↔ D straight away. The Ford-style selector DID `221E23` (one byte for
P/R/N/D/M, answered by many Ford/Mazda PCMs) isn't answered by this car at all; Autobot still tries
it first (`AppConfig.OBD.selectorHeaders`) for cars that have it.

**The M finder** (dashboard → *M finder*; `MFinder`, `SignalDiff`) is how it was found, and can
learn a different one for another car (it then replaces the built-in flag until *Forget*):

1. *Scan* (car stopped, engine running, ~1–2 min, once): which DIDs do the TCM and PCM answer?
   (`AppConfig.MFinder.scanPlan`; kept on the phone)
2. Lever in **D**, foot on the brake → *Snapshot D*; lever in **M**, staying in **M1** → *Snapshot M*
3. Repeat D and M once more. The bits that are steady within each position but differ between them
   are the candidates; values that only drift (temperatures) or count drop out. After two snapshots
   of each, the best candidate (on the TCM, whole byte steady, a single bit…) is saved and Power
   Mode follows the lever right away. *Forget* starts over.

Live data pauses while a finder scans or snapshots (it runs between two rounds, never interleaved).
MAXOBD's own Mazda module reads these values through `MZD_*.BIN` definition files it downloads
separately (none ship in the APK), so the IDs come from measuring the car, not from the app.

### Turn signals

The indicators aren't a value the adapter can ask for: the car *broadcasts* them. In the 2015 CX-5's
SkyActiv family the indicator lamps are in frame **`0x09A`**, sent about 10 times a second on HS-CAN,
the bus the KW905 is on (from community databases, not yet confirmed on this car: the first look of
every connection checks it, see below). So once a round Autobot listens to the bus for a moment:

`ATCAF0` (CAN formatting off: the frame has no ISO-TP length byte, so all 8 bytes are shown as they
are) → `ATCRA09A` (only that frame) → `ATMA` (monitor) … a space stops it → `ATCAF1`; the next request
puts the receive filter back (`ATAR`).

Byte 2 follows the flasher: lit, dark, lit… about 0.35 s each. Which bit is which isn't certain for
this car, because the two community databases disagree:

| Byte 2 | `0x20` | `0x10` | `0x08` | `0x04` |
|---|---|---|---|---|
| Mazda SkyActiv CAN database ([majbthrd/MazdaCANbus](https://github.com/majbthrd/MazdaCANbus), first-generation SkyActiv) | left | right | lights on | – |
| openpilot `mazda_2017.dbc` (CX-5 2017+, Mazda3 / Mazda6 2017) | – | – | right | left |

So all four bits are watched and only a bit that **flashes** counts (`TurnSignalDetector`); one that
stays lit for 1 s, like the lights-on bit, is a steady light and is ignored:

- off → flashing: a lit phase that ended. Each look lasts at least one dark phase (0.45 s), so
  flashing indicators are always caught, typically within about a second
- flashing → off: dark for 0.6 s while listening, typically about a second after they stop (3-flash
  lane changes included)
- left and right together: the hazard lights

The first look of every connection lasts 1 s, with the CAN IDs shown, and logs what it heard:
`OBD: turn signals: frame 09A heard (10 in 1.0 s, 00 00 08 00 …)`, or `not heard` (then the yellow
flash only follows the test buttons, and the frame is looked for again every 30 rounds). Every start
and stop is logged with the lamp byte of that look, e.g.
`Turn signals: Left flashing · 09A byte 2: 00 20 20 00`, and the dashboard's *Turn signals* row shows
the frame live: switch each indicator on once to check. Listening makes each round of live data a
few hundred ms longer; `AppConfig.TurnSignals` can make it less frequent (`everyRounds`) or switch
it off.

### Doors: which one is open

> **Currently off** (`AppConfig.Doors.enabled = false`; the door rows are hidden from the dashboard
> and nothing door-related is read). On the 2015 CX-5 the BCM refuses `726 22C150` (`7F2231`), and
> neither `C100`–`C1FF` nor `DA00`–`DAFF` holds a door: the door switches live on the MS-CAN body bus
> (OBD pins 3/11), which the KW905 (HS-CAN only, pins 6/14) can't reach. The code below stays for an
> adapter that can also talk MS-CAN (then the `0x43E` door frame could be monitored).

The doors are read from the body control module (BCM, `726`, answers from `72E`). Its replies are
outside the `7E8`–`7EF` range an ELM327 listens to by default, so Autobot points the adapter at them
(`ATCRA72E`) and back to automatic (`ATAR`) afterwards.

**Built in: the BCM's door-ajar status, `726 22C150`** (`AppConfig.Doors.builtIn`). This is the
Ford/Mazda BCM layout from the [OBDb](https://github.com/OBDb) community database (listed for the
CX-5, Mazda6, Mazda2, Focus, Explorer; confirmed there on the 2007 Mazda6, 2009/2012 Mazda2 and
2012–18 Focus, not yet on a CX-5). The 2015 CX-5's BCM answers the Ford battery DIDs of the same
family (`4027`–`402B`), so there's a good chance it has this one as well; one read in the car settles
it. Bit set = open:

| Byte | Bit | Opening |
|---|---|---|
| 1 | `0x10` | Boot (liftgate) |
| 1 | `0x08` | Rear R |
| 1 | `0x04` | Rear L |
| 2 | `0x80` | Driver (the BCM knows which side that is — front right on a right-hand-drive car) |
| 2 | `0x40` | Passenger |

At every start Autobot reads it once and logs either `OBD: door status reported (726 22C150 = …)`
or `… not answered (…)`. Then it's read about once a second (`AppConfig.Doors.pollEveryRounds`),
`DoorMonitor` follows and the door alert runs on real data. Every change is logged with the raw
value (`Doors: Driver open · 726 22C150 = 00 00 80`), and the *Doors* screen (dashboard → *Doors*)
shows each door, the raw bytes and where each door comes from — open the doors one by one to check.

**Door finder** (same screen; `DoorFinder`, `SignalDiff`), only for a door that isn't shown right or
when the car doesn't answer `C150`. It finds a door's bit by comparison, the same way as the M flag:

1. *Scan* the body control module (parked, ignition on, ~2 min, once; `AppConfig.Doors.scanPlan`,
   the BCM's body-status block `C100`–`C1FF` around `C150`)
2. Everything shut → *All closed*
3. For each opening: open **only** that one → its button → close it (Driver, Passenger, Rear L,
   Rear R, Boot)
4. *All closed* once more

For each opening, its snapshots are compared with **all the others** (it's closed in those, even
where another door is open). What's left is that door's own switch: a bit every door sets (door-ajar
lamp, dome light) is set in other doors' snapshots too and drops out, and so do drifting values. A
door is saved once that's certain and then replaces the built-in signal for that door; *Forget
learned doors* goes back to the built-in ones. *Export raw scan* writes every snapshot to a JSON file
to share, so a bit can be worked out by hand.

What the first attempts showed (exported scan, 17 snapshots): the BCM's `DA00`–`DAFF` block (58 DIDs)
holds **no** door at all — only `DA13` (counts down by itself) and `DA1E` (battery voltage, which sags
when the courtesy lamps come on) ever change. The 12V-battery DIDs (`4027`–`402B`) drift constantly
and drowned the door bits before that. All of them are ignored (`AppConfig.Doors.ignoredDIDs`).

### A/C set temperature

> **Not readable with the KW905.** The set temperature is kept by the climate control unit, and the
> CX-5 workshop manual puts that unit (full-auto air conditioner) on the **MS-CAN** bus, with the
> rear body control module, BSM and audio unit; the instrument cluster is the gateway to HS-CAN. The
> KW905 only connects to HS-CAN (OBD pins 6/14). What the cluster passes on to HS-CAN for the engine
> is the A/C request, the blower speed and the i-stop requests (frame `0x436` in the Mazda3 SkyActiv
> CAN database), not the set temperature.

At every connection Autobot sends the climate control unit (`733`, Ford/Mazda layout, replies from
`73B`) one harmless *tester present* (`3E00`) and logs whether it answers;
`OBD: climate control unit (733) not answering …` is the expected line with the KW905
(`AppConfig.Climate`). The dashboard's *A/C temp test* row shows the same.

What it would take: an adapter that also reaches MS-CAN (pins 3/11, 125 kbit/s) and works with an
iPhone, e.g. a BLE adapter sold for FORScan such as the vLinker FD+. The set temperature can then be
found like the M flag: scan the climate control unit's DIDs and compare snapshots at different
settings, or watch its MS-CAN frames while turning the dial (0.5 °C steps, 15.0–32.0 °C).
The readings go to `ClimateTempFlash.setPointChanged(to:)`; the lighting part already works.

## Manual shifting detection

`ManualShiftDetector` drives Power Mode from the **M** gate. It uses the real selector when the car
reports it and works it out from the numbers when it doesn't:

**Real lever (preferred).** P/R/N come from the TCM (`221E12`), and D vs M from the M flag
(`7E1 221E03` bit `0x10`, built in; see
[Transmission](#transmission-p--r--n-the-gear-and-m-vs-d)), or from `221E23` on cars that answer it. Power Mode then follows the lever directly: `M` → red breathing, anything else → purple steady,
debounced by a couple of readings. `R` (TCM `3C`) drives the reverse lighting: yellow breathing
(`ReverseLight`, `AppConfig.Reverse`).

**Worked out from RPM/speed/pedal (fallback, when the TCM doesn't answer).** Standard OBD2
(SAE J1979) has no selector position, and the TCM's gear value reads the same in D and M, so
`ManualShiftDetector` looks for what the automatic never does on its own in D (it shifts up early:
about 2000 r/min at 110 km/h in 6th):

1. **Revs held above what D allows for the pedal**, for 1 s: more than 2600 r/min with the foot
   off, 3000 at 40 % pedal, 3800 at 70 %, 4600 at 90 %, 4800 at full throttle (straight lines in
   between). Past 4800 r/min a moment is enough, since D shifts up before that even when floored.
2. **A downshift with the foot off** at 25 km/h or more that lands at 1800 r/min or more (engine
   braking). Coasting in D, the gearbox only shifts down at low revs.

The gear is RPM ÷ speed matched against the gearbox ratios (3.552 / 2.022 / 1.452 / 1.000 /
0.708 / 0.599), with 6th set from 2000 r/min at 110 km/h on the speedometer and fine-tuned while
cruising; PID `A4` is used instead if the car has it. Manual ends once the revs have stayed at or
below 2500 r/min for 10 s. Pedal: PID `5A`, otherwise `49`, otherwise the engine load `04`.

Blind spots: on long descents the automatic can shift down by itself to brake with the engine,
which looks like rule 2, and with the pedal floored only revs past 4800 r/min count, because D
revs high then too.
The D-mode limits are estimates; tune them in `AppConfig.Manual` after a drive. The dashboard shows
RPM, gear, speed, pedal and why manual was detected, and the log lists the PIDs the car has.

## Project structure

```
Autobot/
├── App/         AppModel (wiring), AutobotApp
├── Lamp/        LampProtocol (packets), LampController (BLE), LampState (scenes)
├── Lighting/    LightingArbiter (priority between lighting features), TurnSignalFlash (yellow flash
│                while the indicators flash), ReverseLight (yellow breathing in R)
├── Vehicle/     OBDAdapter (OBD2 Bluetooth), ELM327 (adapter protocol), MazdaTCM (gearbox values),
│                SignalDiff (finding on/off bits by comparison), DoorFinder (learns a door's switch),
│                DoorMonitor (door state), DoorSafetyAlert, TurnSignals (the indicator lamp frame and
│                when it counts as flashing)
├── Driving/     ManualShiftDetector (manual shifting → Power Mode), MFinder (learns the M flag),
│                EngineMonitor (RPM only),
│                SpeedMonitor (GPS), PowerModeController (buffer zone), CarPlayMonitor
├── Climate/     ClimateTempFlash (A/C set colder / warmer → blue / red burst flash)
├── Voice/       AudioSessionManager, Speaker, MetallicVoiceEffect, VoiceCoordinator (queue)
├── Assistant/   WelcomeAssistant (flow), SpeechListener, DestinationParser,
│                WeatherService, CommuteCheck, MapsLauncher, ShortcutsLauncher
├── Places/      SavedPlace, SavedPlacesStore
├── Backup/      AppBackup (JSON format), BackupManager
├── UI/          ContentView (dashboard), SavedPlacesView
└── Support/     AppConfig (all phrases and tuning values), Concurrency helpers
```

Everything you might want to tweak — the manual-shift detection limits, gear ratios, the Power
Mode trigger, OBD2 settings, phrases, voice character, timeouts, languages, retry counts — is in
`Support/AppConfig.swift`.

### Adding a lighting feature
1. Add a scene to `LampState` and its packets in `LampController` (if new).
2. Add a `LightingArbiter.Source` with a priority.
3. Call `lighting.request(scene, from: .yourSource)` / `lighting.clear(.yourSource)`.

### Backup format
```json
{
  "format": "autobot-backup",
  "version": 1,
  "exportedAt": "2026-10-18T09:30:00Z",
  "app": { "name": "Autobot", "version": "1.0", "build": "1" },
  "data": {
    "savedPlaces": [{ "id": "…", "name": "home", "address": "6 Example Street, Suburb, City",
                      "role": "home" }]
  }
}
```
New kinds of data are added as new optional sections under `data`; older and newer app
versions ignore sections they don't know.

## Roadmap

- Real lever over OBD2: P/R/N + gear from the TCM (`7E1 221E12`), M vs D from `7E1 221E03` bit
  `0x10` — **done**. R → yellow breathing (reverse lighting) — **done**.
- Turn signals / hazard lights → yellow flash — **done**: heard on HS-CAN (frame `0x09A`, see
  [Turn signals](#turn-signals)); the first drive shows which of its bits this car uses.
- Real door / boot state — **parked**: not reachable on this car's HS-CAN; needs an MS-CAN capable
  adapter (door frame `0x43E`). Code and door finder kept, switched off (`AppConfig.Doors.enabled`).
- A/C set temperature → blue / red flash — **parked**: lighting done, switched off
  (`AppConfig.Climate.enabled`); reading the set temperature needs an MS-CAN capable adapter
  (climate control unit `733`, pins 3/11).
- More lighting features through `LightingArbiter`
