# Autobot

A personal iOS companion app for the car. It drives a Bluetooth LED ambient-light controller
directly (no vendor app needed), reacts to speed and door state, and greets the driver with a
voice assistant when the phone connects to CarPlay.

> Personal hobby project. Not affiliated with the lamp manufacturer, Google, Tencent (QQ Music)
> or Hasbro. Use the voice features hands-free and keep your eyes on the road.

## Features

### Ambient lighting
- **Speed-based Power Mode** (GPS)
  - below 90 km/h: steady purple (zone 1 at 50 %, zone 2 at 100 %)
  - at or above 90 km/h: firmware *Red Gradient* breathing
  - debounced, so hovering around the threshold doesn't flicker
  - switching goes through a 3-second *buffer zone*: red burst flash + the Power Mode
    announcement, then the speed is checked again and the new lighting is applied, or the
    old one restored if the speed went back
- **Door safety alert** (highest priority): any door or the boot open → *Red Burst Flash* and
  "Door open detected"; when everything is closed the previous lighting comes back.
  Door state currently comes from test buttons; OBD2 / ECU input is planned.
- **Priority arbiter**: every lighting feature requests a scene with a priority, the highest
  one wins, and withdrawing a request restores the next one.
- **Reliable commands**: one packet at a time, mode changes are read back and resent if the
  lamp disagrees, "busy" / checksum-error replies are retried.

### Voice
- "Power Mode Activated" (calm British male voice with a light digital effect) and
  "Power Mode Deactivated" (female voice), spoken navigation-style: other audio is ducked,
  not stopped.
- A single voice queue so prompts never overlap; urgent alerts go first.

### Welcome assistant (CarPlay)
Runs once per drive when the lamp is connected and CarPlay audio is detected:

1. pauses the music, says *"Welcome back, Tim."*
2. 06:00–11:59: a one-sentence weather briefing (Open-Meteo, no API key)
3. asks *"Where is our destination today?"* and listens (English and Mandarin at once,
   on-device; stops 1.5 s after you finish, gives up after 10 s of silence)
4. understands the reply with Apple Intelligence when available, keyword rules otherwise
5. opens Google Maps:
   - a **saved place** with an exact street address → starts navigation
   - anything else → searches so you can pick
6. resumes the music (or starts QQ Music through a shortcut if nothing was playing)

If the phone is locked or the app is in the background, it only says the greeting.

### Saved places
Name + address pairs ("home" → "6 Example Street, Suburb, City"). Say the name (in any
supported language) to navigate there directly. Export / import as a versioned JSON backup.

## Requirements

- iPhone with iOS 26.4+, Xcode 26+
- The lamp: BLE controller advertising as `Pocket Link …` (Zhuhai Jieli chipset), the one used
  by the *LAMP&FRGN* Android app
- Optional: Google Maps, QQ Music, CarPlay head unit, an iPhone with Apple Intelligence

## Getting started

1. Open `Autobot.xcodeproj`, choose your signing team, run on a real iPhone (Bluetooth, GPS and
   CarPlay don't work in the simulator). A free developer account works; the app must be
   re-signed every 7 days.
2. Allow Bluetooth, Location ("While Using" is enough), Microphone and Speech Recognition.
3. For "resume music when nothing was playing", create a shortcut in the Shortcuts app named
   **Lamp Drive** that receives text/URL input, with two actions in this order:
   *Open URLs* (Shortcut Input) → *QQ音乐 – 继续播放*. Google Maps opens first, so a failing QQ
   Music step can't leave you in Shortcuts; on error the app's x-callback opens Maps again.
4. Optional: in Settings → Accessibility → Spoken Content → Voices, download an enhanced
   English (UK) male voice (e.g. Daniel) for the Power Mode voice.

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

## Project structure

```
Autobot/
├── App/         AppModel (wiring), AutobotApp
├── Lamp/        LampProtocol (packets), LampController (BLE), LampState (scenes)
├── Lighting/    LightingArbiter (priority between lighting features)
├── Vehicle/     DoorMonitor (door state), DoorSafetyAlert
├── Driving/     SpeedMonitor (GPS), PowerModeController (buffer zone), CarPlayMonitor
├── Voice/       AudioSessionManager, Speaker, MetallicVoiceEffect, VoiceCoordinator (queue)
├── Assistant/   WelcomeAssistant (flow), SpeechListener, DestinationParser,
│                WeatherService, MapsLauncher, ShortcutsLauncher
├── Places/      SavedPlace, SavedPlacesStore
├── Backup/      AppBackup (JSON format), BackupManager
├── UI/          ContentView (dashboard), SavedPlacesView
└── Support/     AppConfig (all phrases and tuning values), Concurrency helpers
```

Everything you might want to tweak — speed threshold, phrases, voice character, timeouts,
languages, retry counts — is in `Support/AppConfig.swift`.

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
    "savedPlaces": [{ "id": "…", "name": "home", "address": "6 Example Street, Suburb, City" }]
  }
}
```
New kinds of data are added as new optional sections under `data`; older and newer app
versions ignore sections they don't know.

## Roadmap

- OBD2 Bluetooth adapter → real door / boot state from the ECU (feeds `DoorMonitor`)
- More lighting features through `LightingArbiter`
