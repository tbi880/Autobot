# Autobot

A personal iOS companion app for the car. It drives a Bluetooth LED ambient-light controller
directly (no vendor app needed), reacts to manual shifting (worked out from OBD2 live data) and
door state, and greets the driver with a voice assistant when the phone connects to CarPlay.

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
- **Door safety alert** (highest priority): any door or the boot open → *Red Burst Flash* and
  "Door open detected"; when everything is closed the previous lighting comes back.
  Door state currently comes from test buttons; OBD2 / ECU input is planned.
- **Priority arbiter**: every lighting feature requests a scene with a priority, the highest
  one wins, and withdrawing a request restores the next one.
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

The dashboard has test buttons for the welcome flow, both Power Mode voices and every door.

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

Modes used: `0` steady, `2` breathing (parameter `1` = red gradient), `3` burst flash
(parameter `1` = red). A single-byte reply `FF` is an ACK; `F0` checksum error, `F3` not
supported, `FC` busy.

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
(written to the log). After that, about three times a second:

| Request | Reply | Value |
|---|---|---|
| `010C0D1` | `41 0C A B 0D C` | RPM = (256·A + B) / 4, speed = C km/h |
| `015A1` (or `01491`, `01041`) | `41 5A A` | pedal (or engine load) = A · 100 / 255 % |
| `01A41`, only if the car has it | `41 A4 A B C D` | gear = upper half of B |

The trailing `1` tells the adapter one reply is enough; it is dropped if the adapter answers `?`.
If the ECU answers only one PID per request, RPM and speed are asked separately.
Protocol, request header and timings are in `AppConfig.OBD`.

## Manual shifting detection

No OBD2 value says "M". MAXOBD was reverse-engineered (its DEX code, `libobd.so` and its Mazda
module `libmazda.so`) to look for one:

- Standard OBD2 (SAE J1979) has no selector position (P/R/N/D/M). The nearest thing is PID `A4`,
  *transmission actual gear*, which MAXOBD's generic engine (`libobd.so`) shows as `Gear %d`:
  a gear number, the same in D and in M. Its live-data tables hold the standard mode 01 PIDs
  01–CD and nothing else.
- The Mazda module reads Mazda-specific data from definition files it downloads separately
  (`MZD_*.BIN`, `DSTREAM_EN.BIN`). None ship with the app, so there is no manual-mode signal to
  reuse.

So `ManualShiftDetector` works it out from RPM, speed and the pedal, looking for what the
automatic never does on its own in D (it shifts up early: about 2000 r/min at 110 km/h in 6th):

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
├── Lighting/    LightingArbiter (priority between lighting features)
├── Vehicle/     OBDAdapter (OBD2 Bluetooth), ELM327 (adapter protocol), DoorMonitor (door state),
│                DoorSafetyAlert
├── Driving/     ManualShiftDetector (manual shifting → Power Mode), EngineMonitor (RPM only),
│                SpeedMonitor (GPS), PowerModeController (buffer zone), CarPlayMonitor
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

- Real door / boot state (feeds `DoorMonitor`): not part of standard OBD2, needs Mazda-specific
  data on top of the OBD2 connection
- More lighting features through `LightingArbiter`
