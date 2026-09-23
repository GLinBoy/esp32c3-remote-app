# ESP32C3 Remote

A Flutter app that discovers and controls ESP32-C3 devices over MQTT. It replaces
the command-line Python test client (`mqtt_test_client.py`) with a proper mobile
UI, and pairs with the ESP-IDF firmware in
`playground/PlatformIO/esp32c3_freertos`.

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
   (online/offline) and what its light actually is. If you unplug a device, the
   app notices and greys out its switch instead of letting you tap into the void.

You can also give devices friendly names ("Desk LED") instead of hex IDs, and
the app remembers them between launches.

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

| Layer            | Choice               | Why                                                                 |
| ---------------- | -------------------- | ------------------------------------------------------------------- |
| Framework        | Flutter (Dart)       | One codebase, Android today, iOS-ready (icon set already in place)  |
| State management | Riverpod 3           | Long-lived MQTT service outside the widget tree, testable providers |
| MQTT client      | `mqtt_client` 10.x   | Mature Dart MQTT client, plain TCP + TLS, auto-reconnect support    |
| Persistence      | `shared_preferences` | Broker settings and per-device nicknames                            |

### Architecture

Three thin layers, one direction of dependency (UI -> state -> service):

```
lib/
├── core/
│   ├── config/broker_config.dart     # host / port / TLS / credentials (immutable)
│   ├── models/device.dart            # Device model + registry JSON parsing
│   └── storage/settings_repository.dart  # shared_preferences wrapper
├── services/
│   └── mqtt_service.dart             # connection lifecycle, reconnection, event stream
├── providers/
│   └── app_providers.dart            # Riverpod: link state, devices map, nicknames, settings
└── features/
    ├── devices/device_list_screen.dart   # list, connection badge, rename, rescan
    └── settings/broker_settings_screen.dart
```

- `MqttService` is a plain-Dart singleton (no Flutter imports). It owns the
  `MqttServerClient`, exposes a broadcast stream of typed events
  (`MqttLinkChanged`, `MqttMessageReceived`) and commands
  (`connect`, `disconnect`, `reconnect`, `publishLedCommand`).
- Notifiers subscribe to that stream and translate events into state:
  `connectionStatusProvider` (link state for the badge) and `devicesProvider`
  (the `Map<String, Device>`).
- Changing the broker in Settings updates `brokerConfigProvider`, which rebuilds
  the service provider, which disposes the old client and connects to the new
  broker. No app restart needed.

### The MQTT contract

Everything the app and firmware agree on:

| Topic                         | Direction       | Payload              | Notes                                                                     |
| ----------------------------- | --------------- | -------------------- | ------------------------------------------------------------------------- |
| `devices/registry`            | device -> world | JSON (below)         | Retained. Published on boot, on reconnect, and after every LED change     |
| `devices/<device_id>/status`  | device -> world | `online` / `offline` | Retained; `offline` is the broker-published Last Will when a device drops |
| `devices/<device_id>/led/set` | app -> device   | `ON` / `OFF`         | Plain text, QoS 1                                                         |

Registry message format (`device_id` is the 12-hex-char Wi-Fi MAC):

```json
{
  "device_id": "14639370548c",
  "status": "online",
  "led_topic": "devices/14639370548c/led/set",
  "led_state": "ON"
}
```

Discovery works because the registry message is **retained**: the broker
re-delivers it to every newly subscribed client, so the app learns about all
known devices within a second of connecting.

The app subscribes to `devices/registry` and the wildcard `devices/+/status`,
and re-subscribes after every reconnect (the broker drops subscriptions with
clean sessions).

### Resilience and mobile lifecycle

- Initial connect failures retry with exponential backoff (1s doubling, 60s cap).
- Mid-session drops use `mqtt_client`'s built-in auto-reconnect with automatic
  re-subscription.
- On app background a 30s grace timer disconnects cleanly; returning to the
  foreground reconnects. This matches mobile OS norms (no background sockets).

### Running it

```bash
flutter pub get
flutter run                 # pick your device/emulator
flutter build apk --debug   # standalone APK in build/app/outputs/flutter-apk/
flutter analyze && flutter test
```

The ESP32 side is a PlatformIO/ESP-IDF project; flash it with
`pio run -t upload`. The firmware in that repo re-publishes its registry
message immediately after every LED change, which is what keeps the app's
display authoritative instead of optimistic.

### Configuration

Defaults to `test.mosquitto.org:1883` (public, unencrypted, no auth) for
development. The gear icon in the app bar opens Broker Settings where host,
port, TLS, username and password can be changed and are persisted locally.

### Security note

The development setup is fine for experimenting on your own devices, but do not
ship it: move to a private broker with authentication and TLS (`mqtts://`, port 8883) before distributing the app. The configuration screen and
`BrokerConfig` already support this without code changes.

### Roadmap ideas

- iOS build (assets and icon set are already in the repo)
- Optional Android foreground service for background control
- More device types (the registry/topic scheme extends naturally)

---

## CI/CD Pipeline

This project uses GitHub Actions for continuous integration and releases.

### Workflows

- **`mobile-ci.yml`**: Runs `flutter analyze` and `flutter test` on every push/PR
- **`mobile-release.yml`**: Builds signed release APK on semver tags

### Creating a Release

```bash
git tag v1.1.0
git push origin v1.1.0
```

GitHub Actions will:

1. Build signed release APK with version `1.1.0`
2. Generate SHA-256 checksum
3. Create GitHub Release with `app-release.apk` and checksum

### APK Signing

The release APK is signed with a persistent keystore stored as GitHub encrypted secret.
This ensures:

- APK installs without "unsigned app" warnings
- In-place updates (no uninstall required)
- Same signature across all releases

**For contributors**: If setting up your own fork, generate a keystore:

```bash
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Then store as GitHub secrets: `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`.

---

## Self-Distribution & Auto-Update

This app is **not distributed via Play Store**. Users install APK directly from GitHub Releases.

### Installing

1. Download `app-release.apk` from [Releases](https://github.com/GLinBoy/esp32c3-remote-app/releases)
2. Enable "Install from Unknown Sources" on Android device (Settings → Security)
3. Open APK file → Tap "Install"

### Auto-Update

The app checks GitHub Releases API on startup for newer versions.
When an update is available:

1. Dialog prompts: "Update available: vX.Y.Z. Install now?"
2. Tap "Install" → APK downloads in background
3. Android install prompt appears → Tap "Install" again
4. App updates in place (no data loss)

**Note**: Silent install is NOT possible on stock Android without root.
User must confirm install (Android security requirement).
