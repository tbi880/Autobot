# Autobot

A personal iOS companion app for the car. It drives a Bluetooth LED ambient-light controller
directly (no vendor app needed), reacts to the car's reported manual selector (M) and the
turn signals (heard on the car's CAN bus) and door state, and greets the driver with a voice
assistant when the phone connects to CarPlay.

> Personal hobby project. Not affiliated with the lamp manufacturer, Google, Tencent (QQ Music)
> or Hasbro. Use the voice features hands-free and keep your eyes on the road.

## Features

### Ambient lighting
- **Power Mode when shifting by hand** (M; OBD2 Bluetooth adapter, see
  [Manual shifting detection](#manual-shifting-detection))
  - driving in D: steady purple (zone 1 at 50 %, zone 2 at 100 %)
  - the M/D decision follows the car's selector after one reading. A change starts the original
    3-second red burst and voice announcement; after the flash, the current selector is checked and
    red breathing is applied if it is still in M
  - `.speed` (GPS, 90 km/h) remains available as an alternate trigger
- **Reverse → yellow breathing**: with the lever in R the lamp does the firmware's *Yellow Gradient*
  breathing, on Power Mode's level: the Power Mode switch flash, turn signals / hazard lights, the
  A/C flash and the door alert
  still go above it. Out of R it's Power Mode again (purple steady, red breathing
  in M). The lever is the TCM's `7E1 221E12` (`3C` in R), read every round;
  the dashboard's *R* button stands in for it.
- **Turn signals and hazard lights → current mode colour flash** (OBD2 adapter, see
  [Turn signals](#turn-signals)): while the indicators or hazard lights flash, the lamp does a purple
  burst flash in normal driving mode or a red burst flash in Power Mode. It follows mode changes while
  the indicators stay on. When they stop, the lamp goes back to what it should show then: red breathing
  if still in M, the red Power Mode switch flash if it is still in its 3 seconds, or purple steady in D.
  The dashboard's *Left* / *Hazard* / *Right* buttons stand in for them (tap to start, tap again to stop).
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
  signals, A/C flash, Power Mode switch flash, then reverse / Power Mode (R and M never meet), and
  the normal purple steady underneath everything.
- **Reliable commands**: one packet at a time, mode changes are read back and resent if the
  lamp disagrees, "busy" / checksum-error replies are retried.
- **Reconnecting**: if the lamp or the OBD2 adapter drops out, scanning starts again at once, and
  while it isn't back the attempt is started over once a minute
  (`AppConfig.Bluetooth.reconnectInterval`, `ReconnectTimer`).

### DPF monitor
- **Live DPF back pressure and RPM** (OBD2 adapter, see [DPF monitor](#dpf-monitor-1)): the
  dashboard's *DPF monitor* row opens a screen that reads the engine ECU while it's open — the DPF
  differential pressure (back pressure) and engine RPM in large type and as two live charts on one
  time axis (1 / 3 / 10 min, touch to read a moment; regenerations shaded), plus back pressure
  plotted against RPM
- also shown: soot accumulated (gauge, g/L) and generated, distance since the last regeneration,
  number of regenerations, whether one is running now (banner with a timer), DPF inlet / outlet
  pressure and temperature, exhaust gas temperatures, coolant, and the raw PCM replies
- **Regeneration history**, two ways: the PCM's own record of the last 10 regenerations (km driven
  before each; found on the car with the *History finder*, since its DID isn't published), and
  Autobot's own log from now on — every regeneration with the km before it, the soot before it,
  how long it ran and the date, read once a minute while driving. Both as bar charts with the
  average
- a regeneration starting is announced — "DPF regeneration started", in the normal assistant
  voice (`AppConfig.DPF.announceRegeneration`) — and regenerations starting and finishing go to the log. Nothing is read while the screen is closed;
  while it's open, each read slots in between two rounds of live data, so Power Mode, reverse and
  the turn signals keep working. Test mode shows simulated values

### i-stop auto-off

Attempts to switch Mazda's **i-stop** (idling stop — the engine stopping at a standstill) off at the start of
each drive. A few seconds after the engine is running, if the learned state says i-stop is on, it sends a
short experimental CAN-frame replay and checks the PCM state afterward. This only runs while Autobot is
running and connected to the OBD adapter. Tuning in `AppConfig.IStop`.

Nothing about i-stop is a standard OBD2 value, so the app learns two things on the car first, with the
**i-stop finder** (dashboard → *i-stop finder*), parked with the engine running:

- **the i-stop state** (reliable): which PCM value says i-stop is armed vs disabled, found by comparing
  snapshots taken with the OFF button pressed and not (`SignalDiff`, the same way as the M flag). Read-only;
  this is what lets auto-off confirm it worked.
- **the OFF button** (experimental): which CAN frame changes while the physical OFF button is held. The
  physical button is part of the cluster switch's resistor ladder; the instrument cluster reads it and sends
  the operation signal to the PCM on HS-CAN. One capture of the whole bus overflows the adapter, so the finder
  first **maps the bus** in small blocks of CAN ids, then runs a **guided sweep**: one short press per block
  (the phone says "Hold" / "Release"), each block captured released → held → released again, with the state
  flag read before and after to prove the press registered. A bit set only while held is the button
  (momentary); one that stays after release is the i-stop status echo (latched). A changed frame is only a
  candidate: if it includes a rolling counter or checksum, replaying one captured copy will not reproduce a
  real press.
- **which modules this adapter reaches** (read-only): one tester present each to the PCM, instrument cluster,
  body control module and start stop unit (SSU). If the SSU answers, its as-built block is read — never written
  — and shown FORScan style, with what `731-01-01` byte B1 bit 4 says about i-stop at start.

Measured on this car: the i-stop state is **`7E0 22093C`, byte 1, bit `0x10`** (`00` armed, `10` off).

The press is always short — never the 3-second long-press that resets battery management — and only happens
once the engine is actually running, never in the engine-off window where that reset lives.

**Currently on** (`AppConfig.IStop.enabled = true`), but auto-off requires both a learned state and a confirmed
frame candidate. Autobot will not press if the state is unknown, because a blind toggle could turn i-stop back
on. Adapter acceptance is not confirmation that the PCM acted on the frame. If replay does not work, an
inline module that simulates the switch's resistor value is a closer match to automatic i-stop devices.

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
3. asks *"Where is our destination today?"* and listens (Mandarin only;
   stops 1.5 s after you finish, gives up after 10 s of silence)
4. understands the reply with Apple Intelligence when available, keyword rules otherwise
5. opens Google Maps:
   - a **saved place** with an exact street address → starts navigation
   - anything else → searches so you can pick
6. music:
   - was playing → it resumes after Google Maps opens
   - nothing was playing → runs the **最近播放的歌** shortcut, which only starts QQ Music and then
     opens `autobot://maps` to come back; Autobot then opens Google Maps itself — navigation
     with a Google Maps URL using `dir_action=navigate` (starts turn-by-turn navigation when
     location is available), search with `comgooglemaps://?q=…`
     - if iOS refuses to open Shortcuts, Google Maps is opened directly (no music)

If the phone is locked or the app is in the background, it only says the greeting.

### Saved places
Name + address pairs ("home" → "6 Example Street, Suburb, City"). Say the name (in any
supported language) to navigate there directly. If speech recognition gets one or two
characters wrong, the closest matching saved name or address is used. Export / import as a
versioned JSON backup.

Choose the navigation link at the top of **Saved places**: **HTTPS** uses Google's universal Maps
URL and requests immediate navigation when the phone's location is available; **App scheme** uses
`comgooglemaps://` directly, falling back to HTTPS if Google Maps isn't installed. This setting
applies to exact-address navigation, including the weekday Home-to-Work commute.

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
  car, use *M finder* to learn its selector signal if the built-in M flag does not apply.
- Optional: Google Maps, QQ Music, CarPlay head unit, an iPhone with Apple Intelligence

## Getting started

1. Open `Autobot.xcodeproj`, choose your signing team, run on a real iPhone (Bluetooth, GPS and
   CarPlay don't work in the simulator). A free developer account works; the app must be
   re-signed every 7 days.
2. Allow Bluetooth, Location ("While Using" is enough), Microphone and Speech Recognition.
3. Set up the shortcut and the automation in the Shortcuts app — see [Shortcuts](#shortcuts).
4. Optional: in Settings → Accessibility → Spoken Content → Voices, download an enhanced or
   premium English (US) female voice (e.g. Zoe or Ava) for clearer voices.

The dashboard has test buttons for the welcome flow, both Power Mode voices, every door, reverse,
and the turn signals.

## Shortcuts

Autobot needs one shortcut and one personal automation in the Shortcuts app. Names and
timings are in `AppConfig.Music`.

### 最近播放的歌 (music shortcut)

Starts QQ Music, then hands control back to Autobot. It does **not** open Google Maps.

| # | Action | Setting |
|---|--------|---------|
| 1 | *QQ音乐 – 最近播放* (or *继续播放*) | — |
| 2 | *Open URLs* | `autobot://maps` |

- **When it runs:** the Welcome assistant runs it only when no music was playing when the car
  connected. If music was already playing, Autobot opens Google Maps directly and the music
  resumes by itself.
- **How it's run:** a plain `shortcuts://run-shortcut?name=最近播放的歌` link. x-callback
  links aren't used, because since iOS 26.5 iOS refuses to open x-callback Shortcuts links
  from other apps.
- **Why step 2 matters:** iOS only lets the app in front open another app. Once Shortcuts is in
  front, Autobot can't open Google Maps, so the shortcut has to bring Autobot back first.
  Autobot waits up to `AppConfig.Music.returnTimeout` (20 s) for `autobot://maps`, then opens
  Google Maps itself:
  - saved place with an exact address → Google Maps directions URL with `dir_action=navigate`
    (opens the app when installed and starts turn-by-turn navigation when location is available)
  - any other place → `comgooglemaps://?q=<place>` (search, you pick the result)
  - no destination → `comgooglemaps://`
- **If something goes wrong:** if the shortcut never comes back, Google Maps isn't opened. If
  iOS refuses to open Shortcuts, Autobot opens Google Maps directly, without music. Either way,
  the dashboard's *last shortcut* line says what happened.

The old **Lamp Drive** shortcut (QQ Music + Google Maps search) is no longer used. Delete it,
along with any automation that still runs it.

### CarPlay automation

**Automation → CarPlay → Connects → Open URL → `autobot://start`**, set to *Run Immediately*
(don't ask).

This opens Autobot and presses ENGINE START by itself: the same start-up sound and animation, then
the progress ring, which only opens the dashboard once all three connections are there (see
[Start screen](#start-screen)). The app still needs to be installed and the OBD adapter available. The i-stop frame replay remains
experimental, as described below.

### Start screen

ENGINE START (or `autobot://start`) starts the lamp and OBD2 Bluetooth searches and car-audio
detection together. The progress ring then waits at three checkpoints (`AppConfig.Boot`):

| Progress | Waits for |
|---|---|
| 30 % | the ambient lamp (Bluetooth) |
| 60 % | the OBD2 adapter (KONNWEI, Bluetooth link up; the engine ECU doesn't have to answer yet) |
| 90 % | car audio (CarPlay) |

Only with all three connected does it run to 100 % and open the dashboard. The chips under the ring
show each connection, and the line below them what the one being waited for is doing. In test mode
(`AppConfig.TestMode`) all three are simulated as connected.

### URL scheme

| URL | Opened by | What Autobot does |
|-----|-----------|-------------------|
| `autobot://start` | CarPlay automation | presses ENGINE START by itself (same start-up and connection checks) |
| `autobot://maps` | 最近播放的歌, last step | opens Google Maps for the waiting Welcome (ignored otherwise) |

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

Modes used: `0` steady, `2` breathing (parameter `1` = red, `2` = yellow, `4` = cyan gradient), `3` burst flash
(parameter `1` = red, `5` = blue, `6` = purple; the firmware's list also has 0 colourful, 2 yellow, 3 green,
4 cyan and 7 white). A single-byte reply `FF` is an ACK; `F0` checksum error, `F3` not supported, `FC` busy.

The firmware also knows "original car" functions (turn signal, doors, overspeed… and a
*Temperature adjustment Reminder*, 气候模式). The app only offers them when the controller reports
them for the selected car model (query `90 9C`), which takes the vendor's CAN box wired to the car;
Autobot doesn't use them. Its turn-signal flash is its own: it hears the indicators on the CAN bus
through the OBD2 adapter (see [Turn signals](#turn-signals)) and sends a plain purple or red burst
flash, depending on the current Power Mode state.

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
until the engine ECU answers (ignition on). Autobot no longer scans supported PIDs or continuously
requests RPM, pedal, engine load, or estimated gear ratios. Live rounds request speed (`010D1`) and
the selector values needed for Power Mode and reverse lighting (see below), about three times a
second when the adapter responds promptly:

| Request | Reply | Value |
|---|---|---|
| `010D1` | `41 0D C` | road speed = C km/h |

The trailing `1` tells the adapter one reply is enough; it is dropped if the adapter answers `?`.
RPM is queried separately at most once per second during i-stop's startup safety check; it is not
part of live driving updates.
Protocol, request header and timings are in `AppConfig.OBD`.

### Transmission: P / R / N, the gear, and M vs D

After the engine ECU answers, Autobot asks the transmission module (TCM, `7E1`, answers from `7E9`) over UDS
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

So `221E12` gives **P, R, N and the real gear** (gear-ratio estimation has been removed), but **D1 and M1 read
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
`OBD: turn signals: frame 09A heard (10 in 1.0 s, 00 00 08 00 …)`, or `not heard` (then the mode-coloured
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

### DPF monitor

The diesel particulate filter values come from the engine ECU (PCM, `7E0`) over UDS service 22
(`MazdaDPF.swift`, `DPFMonitor.swift`). Every read, while the screen is open: RPM (`010C1`) and the
DPF pressure, plus one of the slower values in turn (`AppConfig.DPF.rotation`), giving roughly one to
two chart points a second next to the normal live data.

| Request | Value | Decoding |
|---|---|---|
| `22F47A` | DPF pressure (SAE PID `7A`) | A = bits (0 differential, 1 inlet, 2 outlet); differential = signed(B·256+C)/100 kPa, inlet D–E, outlet F–G the same |
| `22042C` | soot accumulated | (A·256+B)·100/65536 g/L |
| `22042D` | soot generated since the last regeneration | same as above |
| `220380` | regeneration running | bit 1 of A |
| `220432` | regenerations so far | A·256+B |
| `220434` | distance since the last regeneration | (B·65536+C·256+D)/640 km |
| `22F478` | exhaust gas temperatures (PID `78`) | A = sensors 1–4 present, then 2 bytes each: raw/10 − 40 °C |
| `22F47C` | DPF inlet / outlet temperature (PID `7C`) | A bit 0 inlet, bit 1 outlet; raw/10 − 40 °C |
| `22F405` | coolant (PID `05`) | A − 40 °C |

The `04xx` / `0380` DIDs and their scaling are from community Torque PID lists for SkyActiv-D cars
(not Mazda documentation); one list scales the soot by /628 and the distance by ·100/65536 instead.
The screen shows the raw bytes of every reply, so the scaling can be checked against FORScan
(`PM_ACC`, `DPF_REG_DIS`…). A value the PCM doesn't answer three times in a row shows "not
answered" and isn't asked again until the screen is reopened.

**Regeneration history.** Two sources, shown together on the DPF screen:

- *Recorded by Autobot* (`DPFRegenLog`): while live data runs it reads `220432`, `220434`,
  `22042C` and `220380` once a minute (`AppConfig.DPF.logInterval`; while the DPF screen is open its
  own reads are used), and in between `220380` alone every 15 s (`regenCheckInterval`): when it comes
  on, "DPF regeneration started" is said once (not again within 10 min). When the count goes up — or, on a PCM without the count, the distance drops
  back — an entry is saved with the highest distance read before it, the soot before it and, when
  both ends were seen, how long it ran. "≥" marks an entry whose last reading before it was from an
  earlier drive (the km in between are missing). Kept on the phone, newest first.
- *From the PCM* (`DPFHistoryFinder`): the PCM keeps the distances of its last 10 regenerations
  (Mazda's dealer tool shows them as DPF regeneration distance 01–10; a Torque preset for the
  SkyActiv-D reads each as 1 byte × 2 km, and was 30 km above the dealer tool), but the DID isn't
  published. The first scan (`7E0 0300–04FF`, single DIDs of 10+ bytes only) found nothing, so the
  finder now scans `AppConfig.DPF.historyScanPlan` — `7E0 0300–04FF` again, the rest of `0000–0FFF`,
  then `1000–1FFF` and `D000–DFFF`, about 12 000 DIDs / ~20 min — a chunk of 48 at a time between two
  rounds of live data, so Power Mode etc. keep working. Its progress is kept: *Pause*, driving off or a
  lost adapter stops it, and *Scan* carries on from there. Every DID that answers is read to the end
  twice (one that changes in between is a live value). Two shapes count as a candidate: one DID of
  10+ bytes, or a row of 10 consecutive DIDs with the same 1–4-byte reply, one entry each — as long as
  at least 6 of the 10 entries look like distances (20–1500 km) and they aren't all alike. DIDs the
  PCM refuses with anything but `7F 22 31` (no such DID) are listed: they exist but can't be read like
  this. *Extended session* runs the scan (and the re-reads) after `1003`, where some values only
  answer; the PCM drops back by itself a few seconds after the last request, and the finder sends
  `1001` when done. After the next regeneration (a new log entry, opening the DPF screen, or the end of
  a scan) the candidates are read again: the history moves along by one entry — new distance in front,
  oldest gone — and the candidate that does that is used from then on. One that changes without a
  regeneration is ruled out; one where a single entry changed in place is flagged (a ring buffer?).
  *Use this one* picks a candidate by hand, *Read by hand* asks typed-in DIDs (`0435`, `0435-043E`)
  and shows the reply or the refusal code, and *Export raw scan* shares every reply as JSON.

Reading the numbers: back pressure rises with exhaust flow, so it only means something at a given
RPM / load — the back pressure vs RPM chart is the one to compare across days. On the SkyActiv-D a
regeneration usually starts somewhere above 6 g/L of soot; at 10 g/L the PCM limits power and stops
regenerating by itself (gauge thresholds in `AppConfig.DPF`).

### i-stop (idling stop)

i-stop has no standard OBD2 PID. On this platform the i-stop OFF button is part of the **cluster switch** by
the driver's knee — a resistor ladder (about 84 Ω between its B and C pins while the OFF button is held).
The instrument cluster reads that switch and sends the operation signal to the PCM over CAN. The PCM exposes
a read-only `I-Stop_OFF` state (Mazda's PID table lists `I-Stop_OFF`, `I-Stop_TRD`, `I-Stop_VSP`, `I-Stop_VST`).
Changing it requires reproducing the instrument cluster's switch operation; there is no standard OBD2 command.

Two things are learned on the car (`IStopFinder`, `IStop.swift`):

- **State** — a flag in a PCM service-22 value, found by snapshot diff with i-stop armed vs disabled (reuses
  `BitSignal` / `SignalDiff`). `AppConfig.IStop.stateScanPlan` lists the PCM DID blocks to scan.
- **Observed CAN frame** — the whole bus at once is well over 1000 frames a second, more than the KW905 can pass
  on over Bluetooth (it stops with `BUFFER FULL`), which is why the first all-ids capture found nothing. So the
  finder maps the bus first: it monitors one aligned block of ids at a time (`ATCF <base>` + `ATCM <mask>`,
  then `ATMA`, headers on) and splits any block that overflows, or carries more than
  `AppConfig.IStop.maxGroupRate` frames a second, in two (`ATCRA` + `ATAR` put the filters back after every
  look). Then the guided sweep presses once per block (released → held → released again) and `ButtonSweep`
  sorts the changes into momentary (the button) and latched (the status echo). It's replayed experimentally by
  `OBDAdapter.injectFrame`: `ATSH <id>`, `ATCAF0` (formatting off), `ATR0` (no reply expected), write the
  captured bytes a few times, then restore. Adapter acceptance does not prove that the PCM acted on it; a
  rolling counter or checksum may make a captured copy unusable.

Two honest limits on the software route with the KW905:

- the adapter has to take `ATCF`/`ATCM` (standard ELM327 commands); if it won't, the bus can't be mapped and
  only the state can be learned (auto-off then has nothing to press).
- the instrument cluster keeps sending its own copy of the switch frame, so a replay races with it; as an
  MX-5 CAN write-up puts it, frames sent onto the bus "get overwritten almost immediately" unless the module is
  isolated behind a bridge.
- the switch itself is a resistor ladder, not a button CAN transmitter. The instrument cluster forwards its
  operation signal, and the PCM may reject a stale or incomplete replay (for example, if the message has a
  rolling counter/checksum). If it does, an inline switch-harness module that simulates the resistor value is
  the closest match to automatic i-stop devices; it emulates the button instead of relying on OBD.
- the one documented OBD-side setting is in the start stop unit's as-built data: FORScan users report
  `731-01-01` byte B1 bit 4 (1 = i-stop on at every start, stock; 0 = off at every start, the button still
  turns it on), on SkyActiv Mazda6 / CX-5 / Mazda3 / Mazda2. Writing as-built data needs the module's security
  access and a backup, so it's done with FORScan, not this app; the module check only reads it, and shows
  whether the SSU is even on the bus the KW905 reaches (newer Mazdas put it on MS-CAN).

## Manual shifting detection

`ManualShiftDetector` drives Power Mode from the **M** gate reported by the car. It does not infer M
from RPM, speed, pedal position, or gear ratios; if the selector signal is unavailable, use M finder
to learn it. Until then Power Mode stays off.

P/R/N come from the TCM (`221E12`), and D vs M from the M flag
(`7E1 221E03` bit `0x10`, built in; see
[Transmission](#transmission-p--r--n-the-gear-and-m-vs-d)), or from `221E23` on cars that answer it. Power Mode then follows the lever directly: `M` → red breathing, anything else → purple steady,
after one confirmed reading. Each change starts a 3-second red burst and announcement; after the
flash, Power Mode applies whichever selector state is current. `R` (TCM `3C`) drives reverse lighting: yellow breathing
(`ReverseLight`, `AppConfig.Reverse`).
The dashboard shows the selector and speed. The live TCM gear code remains available on the M finder
screen and is used for reverse lighting.

## Project structure

```
Autobot/
├── App/         AppModel (wiring), AutobotApp
├── Lamp/        LampProtocol (packets), LampController (BLE), LampState (scenes)
├── Lighting/    LightingArbiter (priority between lighting features), TurnSignalFlash (mode-coloured flash
│                while the indicators flash), ReverseLight (yellow breathing in R)
├── Vehicle/     OBDAdapter (OBD2 Bluetooth), ELM327 (adapter protocol), MazdaTCM (gearbox values),
│                SignalDiff (finding on/off bits by comparison), DoorFinder (learns a door's switch),
│                DoorMonitor (door state), DoorSafetyAlert, TurnSignals (the indicator lamp frame and
│                when it counts as flashing),
│                IStop (i-stop state flag + OFF-button frame, FrameDiff)
│                MazdaDPF (the PCM's DPF values and their decoding)
├── Driving/     ManualShiftDetector (manual shifting → Power Mode), MFinder (learns the M flag),
│                SpeedMonitor (GPS), PowerModeController (3-second transition buffer), CarPlayMonitor,
│                IStopController (i-stop auto-off), IStopFinder (learns the state + OFF-button frame),
│                DPFMonitor (DPF back pressure, soot, regeneration while its screen is open)
│                DPFRegenLog (records each regeneration), DPFHistoryFinder (the PCM's last-10 history)
├── Climate/     ClimateTempFlash (A/C set colder / warmer → blue / red burst flash)
├── Voice/       AudioSessionManager, Speaker, MetallicVoiceEffect, VoiceCoordinator (queue)
├── Assistant/   WelcomeAssistant (flow), SpeechListener, DestinationParser,
│                WeatherService, CommuteCheck, MapsLauncher, ShortcutsLauncher
├── Places/      SavedPlace, SavedPlacesStore
├── Backup/      AppBackup (JSON format), BackupManager
├── UI/          ContentView (dashboard), SavedPlacesView, DPFMonitorView (live DPF charts)
└── Support/     AppConfig (all phrases and tuning values), Concurrency helpers,
                 ReconnectTimer (once-a-minute Bluetooth retry for the lamp and the OBD2 adapter)
```

Everything you might want to tweak — the Power Mode trigger, OBD2 settings, phrases, voice character,
timeouts, languages, retry counts — is in
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
- Rain mode (cyan breathing while the wipers are on) — **removed**: reading the wipers (the lever
  in the lights frame, the FBCM's wiper motor bit in AUTO) took too much of the OBD2 adapter's
  bandwidth.
- Turn signals / hazard lights → purple / red flash by Power Mode — **done**: heard on HS-CAN (frame `0x09A`, see
  [Turn signals](#turn-signals)); the first drive shows which of its bits this car uses.
- Real door / boot state — **parked**: not reachable on this car's HS-CAN; needs an MS-CAN capable
  adapter (door frame `0x43E`). Code and door finder kept, switched off (`AppConfig.Doors.enabled`).
- A/C set temperature → blue / red flash — **parked**: lighting done, switched off
  (`AppConfig.Climate.enabled`); reading the set temperature needs an MS-CAN capable adapter
  (climate control unit `733`, pins 3/11).
- i-stop auto-off: attempt to replay an observed frame at the start of a drive — **experimental**, through
  the OBD2 adapter (`AppConfig.IStop`, see [i-stop](#i-stop-idling-stop)). Learns the PCM i-stop state
  (read-only) and an experimental observed frame candidate (may not replay if it requires a valid
  counter/checksum). An inline switch-harness module that simulates the resistor value is the closest match to
  automatic i-stop devices; any FORScan as-built change needs confirmation for the exact model and region.
- DPF monitor: live back pressure + RPM charts, soot, regeneration, exhaust temperatures — **done**;
  the community scaling of the Mazda DIDs is to be confirmed against FORScan on the car.
- Regeneration history: Autobot's own log — **done**; the PCM's last-10 history — finder **done**, its
  DID to be found on the car (scan, then confirmed by the next regeneration).
- More lighting features through `LightingArbiter`
