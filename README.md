# ESP32C3 Remote

A Flutter app that discovers, provisions and controls ESP32-C3 devices over
Bluetooth Low Energy and MQTT. It is the everyday client for the ESP-IDF
firmware in [`GLinBoy/esp32c3-firmware`](https://github.com/GLinBoy/esp32c3-firmware),
and replaces the command-line test client used during early development.

---

## For everyone: what does this app do?

Imagine each of your ESP32 devices is a smart plug with a light. This app is the
remote control for them:

1. **Set a device up.** If an ESP32-C3 can't reach Wi-Fi, it advertises itself
   over Bluetooth. Tap the Bluetooth icon, pick the device, and tell it which
   network to join.
2. **Plug it in.** The device connects to your Wi-Fi and announces itself:
   "Hi, I'm device `14639370548c`, my light is currently OFF."
3. **Open the app.** Only the devices _you_ set up appear in the list — you won't
   see other people's devices that happen to use the same broker.
4. **Tap the switch.** The command travels through a public message hub
   ("MQTT broker") to the device and the light flips.
5. **See the truth.** Each device reports whether it is currently reachable
   (online/offline), its Wi-Fi signal, uptime and chip temperature. If you unplug
   a device, the app notices and greys out its switch instead of letting you tap
   into the void.
6. **Manage it later.** From the device's menu you can rename it, change its
   Wi-Fi (re-run Bluetooth setup), configure its auto-provisioning fallback, or
   remove it entirely.

The app also checks GitHub for a newer version of itself and offers to install it
in-app (see [Self-Distribution & Auto-Update](#self-distribution--auto-update)).

```
 ESP32 device  ──── Wi-Fi ────>  MQTT broker  <──── internet ────  your phone (this app)
    "I'm online, LED is OFF"  ─────────────────────────────────>
    <─────────────────────────────────  "turn LED ON, please"
```

All parties talk through the broker, so the app never needs to know the
device's IP address, and devices can be anywhere with internet access.

---

## For developers

### Tech stack

| Layer            | Choice                       | Why                                                                 |
| ---------------- | ---------------------------- | ------------------------------------------------------------------- |
| Framework        | Flutter (Dart)               | One codebase, Android today, iOS-ready (project scaffolding present) |
| State management | Riverpod 3                   | Long-lived MQTT service outside the widget tree, testable providers |
| MQTT client      | `mqtt_client` 10.x           | Mature Dart MQTT client, plain TCP + TLS, auto-reconnect support    |
| BLE              | `flutter_blue_plus`          | Device provisioning over a Nordic-UART-style GATT service           |
| Persistence      | `shared_preferences`         | Broker settings, nicknames, "my devices", fallback preferences      |
| Platform         | `permission_handler`, `device_info_plus` | Runtime BLE/location permissions, install permission, SDK checks |
| Updates          | `http`, `path_provider`, `package_info_plus` | In-app APK update from GitHub Releases            |

### Architecture

Three thin layers, one direction of dependency (UI -> state -> service):

```
lib/
├── core/
│   ├── config/
│   │   ├── broker_config.dart            # host / port / TLS / credentials (immutable)
│   │   └── ble_provisioning_config.dart  # GATT UUIDs, name prefix, debug flag
│   ├── models/
│   │   ├── device.dart                   # Device model + registry parsing
│   │   └── wifi_network.dart             # Scanned AP + auth label
│   └── storage/settings_repository.dart  # shared_preferences wrapper
├── services/
│   ├── mqtt_service.dart                 # connection lifecycle, reconnection, event stream
│   ├── ble_provisioning_service.dart     # BLE scan / connect / JSON line protocol
│   └── update_service.dart               # GitHub Releases check, APK download, install
├── providers/
│   └── app_providers.dart                # Riverpod: link state, devices, nicknames, settings
└── features/
    ├── devices/device_list_screen.dart   # list, detail sheet, manage menu, rescan
    ├── provisioning/ble_provisioning_screen.dart  # BLE setup / change Wi-Fi flow
    └── settings/broker_settings_screen.dart
```

- `MqttService` is a plain-Dart class (no Flutter imports). It owns the
  `MqttServerClient`, exposes a broadcast stream of typed events
  (`MqttLinkChanged`, `MqttMessageReceived`) and commands
  (`connect`, `disconnect`, `reconnect`, `publishLedCommand`, `publishJson`).
- `BleProvisioningService` wraps `flutter_blue_plus`: an unfiltered scan
  (filtered client-side by name/Service UUID), connection management, and a
  newline-delimited JSON line pipe over the GATT RX/TX characteristics.
- Notifiers subscribe to the MQTT event stream and translate events into state:
  `connectionStatusProvider` (link state for the badge) and `devicesProvider`
  (the `Map<String, Device>`). `myDevicesProvider` remembers which devices this
  app provisioned, so announcements from unrelated devices are ignored.
- Changing the broker in Settings updates `brokerConfigProvider`, which rebuilds
  the service provider, which disposes the old client and connects to the new
  broker. No app restart needed.

### The MQTT contract

Everything the app and firmware agree on:

| Topic                         | Direction       | Payload              | Notes                                                                      |
| ----------------------------- | --------------- | -------------------- | -------------------------------------------------------------------------- |
| `devices/registry`            | device -> world | JSON (below)         | Retained. Published on boot, on connect, and after every LED change        |
| `devices/<device_id>/status`  | device -> world | JSON (below)         | Retained online/offline + telemetry heartbeats every 30s; `offline` is the broker-published Last Will |
| `devices/<device_id>/led/set` | app -> device   | `ON` / `OFF`         | Plain text, QoS 1                                                          |
| `devices/<device_id>/wifi/set`| app -> device   | JSON command         | QoS 1. `reprovision`, `remove`, `set_fallback`                             |
| `devices/ota`                 | tool -> device  | JSON update metadata | Retained. The app does not publish to this topic                           |

Registry message format (`device_id` is the 12-hex-char Wi-Fi MAC):

```json
{
  "device_id": "14639370548c",
  "status": "online",
  "led_topic": "devices/14639370548c/led/set",
  "led_state": "ON"
}
```

Status message format (telemetry; the app renders SSID, signal, uptime and
temperature in the device detail sheet):

```json
{
  "state": "online",
  "device_id": "14639370548c",
  "ssid": "MyNetwork",
  "rssi": -52,
  "uptime_s": 3600,
  "temp_c": 41.2
}
```

Discovery works because the registry message is **retained**: the broker
re-delivers it to every newly subscribed client, so the app learns about all
known devices within a second of connecting.

The app subscribes to `devices/registry` and the wildcard `devices/+/status`,
and re-subscribes after every reconnect (the broker drops subscriptions with
clean sessions).

### BLE provisioning

The app talks to the firmware's Nordic-UART-style GATT service
(`6e400001-…`), writing newline-terminated JSON to the RX characteristic
(`6e400002-…`) and reassembling newline-terminated notifications from the TX
characteristic (`6e400003-…`).

| App -> device | Device -> app |
| --- | --- |
| `{"type":"scan"}` | `{"type":"hello","device_id":"…","wifi":"…"}` |
| `{"type":"connect","ssid":"…","password":"…"}` | `{"type":"status","wifi":"…","detail":"…"}` |
| `{"type":"set_broker","url":"mqtt://…"}` | `{"type":"scan_result","ssid":"…","rssi":-45,"auth":"WPA2","channel":6}` |
|  | `{"type":"scan_done","count":N}` |

The current screen uses `scan` and `connect`; `set_broker` is supported by the
firmware for changing a device's broker URI over BLE.

The full protocol and the Android-specific pitfalls (permissions, GATT cache,
notification races, write-without-response) are documented in
[`docs/ble-provisioning-development-notes.md`](docs/ble-provisioning-development-notes.md).

### Device management

From the device tile's manage menu:

- **Rename** — a local nickname, stored in `shared_preferences`.
- **Change Wi-Fi** — publishes `{"command":"reprovision"}` to
  `devices/<id>/wifi/set`; the device starts advertising again while staying
  online, and the app opens the BLE setup flow so you can enter new credentials.
- **Remove device** — publishes `{"command":"remove"}`; the device erases its
  Wi-Fi credentials and returns to setup mode, and the app forgets it.
- **Fallback settings** — publishes `{"command":"set_fallback","enabled":…,"timeout_min":1-5}`,
  controlling how long the device waits for Wi-Fi before returning to BLE setup.

### Auto-update

`UpdateService` queries the GitHub Releases API
(`https://api.github.com/repos/GLinBoy/esp32c3-remote-app/releases`), skips
drafts, picks the newest release that has an `.apk` asset and a higher semver
than the installed app (pre-release aware), then downloads it to the cache
directory. `installApk` requests `REQUEST_INSTALL_PACKAGES` and launches the
system installer through a `FileProvider` via the native method channel.

### Resilience and mobile lifecycle

- Initial connect failures retry with exponential backoff (1s doubling, 60s cap).
- Mid-session drops use `mqtt_client`'s built-in auto-reconnect with automatic
  re-subscription.
- On app background a 30s grace timer disconnects cleanly; returning to the
  foreground reconnects. This matches mobile OS norms (no background sockets).
- The update check runs on startup and every 24 hours while the list screen is open.

### Running it

```bash
flutter pub get
flutter run                 # pick your device/emulator
flutter build apk --debug   # standalone APK in build/app/outputs/flutter-apk/
flutter analyze && flutter test
```

The ESP32 side is the PlatformIO/ESP-IDF project in
[`GLinBoy/esp32c3-firmware`](https://github.com/GLinBoy/esp32c3-firmware); flash
it with `pio run -t upload`. The firmware re-publishes its registry message
immediately after every LED change, which is what keeps the app's display
authoritative instead of optimistic.

### Configuration

Defaults to `test.mosquitto.org:1883` (public, unencrypted, no auth) for
development. The gear icon in the app bar opens Broker Settings where host,
port, TLS, username and password can be changed and are persisted locally.

Note that this configures the **app's** connection. A device's broker URI is
stored separately in the device's own NVS and can be changed over BLE with the
firmware's `set_broker` command.

### Security note

The development setup is fine for experimenting on your own devices, but do not
ship it: move to a private broker with authentication and TLS (`mqtts://`, port
8883) before distributing the app. The configuration screen and `BrokerConfig`
already support this without code changes.

### Roadmap ideas

- iOS build (project scaffolding and icon set are already in the repo)
- Optional Android foreground service for background control
- More device types (the registry/topic scheme extends naturally)

---

## CI/CD Pipeline

This project uses GitHub Actions for continuous integration and releases.

### Workflows

- **`mobile-ci.yml`**: on every push and on PRs to `main`, runs
  `flutter pub get`, `flutter analyze` and `flutter test` (Flutter 3.47.1 stable).
- **`mobile-release.yml`**: on tags matching `v*.*.*`, builds a **signed**
  release APK (`--build-name=<tag version>`), computes its SHA-256, and creates a
  GitHub Release with `app-release.apk` and `app-release.sha256`.

### Creating a Release

```bash
git tag v1.1.0
git push origin v1.1.0
```

GitHub Actions will:

1. Build the signed release APK with version `1.1.0`
2. Generate a SHA-256 checksum
3. Create a GitHub Release with `app-release.apk` and `app-release.sha256`

### APK Signing

The release APK is signed with a persistent keystore stored as GitHub encrypted
secrets. This ensures:

- APK installs without "unsigned app" warnings
- In-place updates (no uninstall required)
- Same signature across all releases

**For contributors**: If setting up your own fork, generate a keystore:

```bash
keytool -genkey -v -keystore upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Then store these GitHub Actions secrets: `KEYSTORE_BASE64` (base64 of the `.jks`),
`KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`. The keystore and
`android/key.properties` are git-ignored and must never be committed.

---

## Self-Distribution & Auto-Update

This app is **not distributed via Play Store**. Users install the APK directly
from GitHub Releases.

### Installing

1. Download `app-release.apk` from [Releases](https://github.com/GLinBoy/esp32c3-remote-app/releases)
2. Enable "Install from Unknown Sources" on the Android device (Settings → Security)
3. Open the APK file → Tap "Install"

### Auto-Update

The app checks the GitHub Releases API on startup and every 24 hours. When a
newer version is available:

1. Dialog prompts: "Update available: vX.Y.Z. Install now?"
2. Tap "Install" → the APK downloads in the background
3. Android asks you to allow installs from this app if not already granted
4. The system install prompt appears → Tap "Install"
5. The app updates in place (no data loss)

**Note**: Silent install is NOT possible on stock Android without root. The user
must confirm the install (Android security requirement).

---

## Further Documentation

- [`CONTRIBUTING.md`](CONTRIBUTING.md) — branch workflow, local testing, releases
- [`docs/ble-provisioning-development-notes.md`](docs/ble-provisioning-development-notes.md) —
  BLE provisioning implementation notes and troubleshooting
- Firmware counterpart: [`GLinBoy/esp32c3-firmware`](https://github.com/GLinBoy/esp32c3-firmware)
