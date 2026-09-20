# Development Plan: Mobile App to Replace `mqtt_test_client.py`

Hand this document to an LLM (or a developer) as the brief for building a
mobile app that replaces the Python test script with a real, installable
app for controlling ESP32-C3 LED devices over MQTT.

---

## 1. Project Context (give this to the LLM first)

We have a fleet of ESP32-C3 devices running ESP-IDF firmware that:
- Connect to Wi-Fi and an MQTT broker (currently `test.mosquitto.org:1883`,
  a free public test broker — plaintext, no auth, for development only).
- Each device has a unique ID derived from its MAC address (12 hex chars,
  e.g. `a1b2c3d4e5f6`).
- On boot/connect, each device publishes a **retained** JSON message to
  `devices/registry`:
  ```json
  {"device_id":"a1b2c3d4e5f6","status":"online","led_topic":"devices/a1b2c3d4e5f6/led/set","led_state":"OFF"}
  ```
- Each device subscribes to its own command topic:
  `devices/<device_id>/led/set` — accepts plain text payloads `"ON"` or
  `"OFF"`.
- Each device publishes its connectivity status (with Last Will) to:
  `devices/<device_id>/status` — `"online"` while connected, broker
  auto-publishes `"offline"` (retained) if it drops unexpectedly.
- LED state persists across device reboots (stored in NVS on-device), and
  the device blinks its LED while disconnected from Wi-Fi, holding steady
  once connected.

The existing Python script (`mqtt_test_client.py`) is a CLI tool that:
subscribes to `devices/registry` and `devices/+/status`, prints newly
discovered devices, and lets a user type `list`, `<index> on`, `<index> off`
to control a device. **The mobile app should replace this entirely** with a
proper UI: auto-discover devices, show their live status, and let the user
tap a toggle to control each one.

---

## 2. Goals and Non-Goals

**Goals:**
- Auto-discover all devices publishing to `devices/registry`, no manual
  entry of device IDs.
- Show each device's live online/offline status (via its status topic +
  Last Will).
- Toggle each device's LED on/off with a single tap.
- Reflect the LED's actual current state in the UI (from the retained
  `led_state` field in the registry message, and updated live afterward).
- Work on both iOS and Android from one codebase (cross-platform).
- Be easy to extend later: adding more device types/topics shouldn't
  require a rewrite.

**Non-goals (explicitly out of scope for v1):**
- No user accounts/login — this is a personal/local tool.
- No push notifications.
- No support for the public unauthenticated broker in any shipped/distributed
  build — see Section 6 on security before this goes beyond your own device.

---

## 3. Recommended Tech Stack

| Layer | Recommendation | Why |
|---|---|---|
| Framework | **Flutter** | Single codebase for iOS + Android, mature MQTT support, good for a UI-focused IoT control app [web:179][web:187] |
| MQTT client | **`mqtt_client` (Dart package)** | Most widely used and actively maintained Dart MQTT client; supports plain TCP and WebSocket/TLS [web:175][web:179] |
| State management | **Riverpod** or **Provider** | Keep the MQTT client as a long-lived singleton service outside the widget tree, so reconnects/rebuilds don't tear down the connection [web:185] |
| Local storage (optional, v2) | `shared_preferences` | Cache last-known device list/state so the UI isn't empty on cold start before the first registry messages arrive |

If you'd rather use React Native instead of Flutter, the equivalent choice
is **MQTT.js over WebSocket (`wss://`)** for Expo-friendly setups, or a
native client like `sp-react-native-mqtt` if you need raw TCP [web:185][web:186].
This plan assumes Flutter; ask the LLM to substitute React Native
equivalents if you prefer that stack.

---

## 4. Feature Breakdown (in build order)

### Phase 1 — Connect and discover
1. MQTT service class: connect to broker, handle connect/disconnect/error
   events, expose connection status to the UI.
2. Subscribe to `devices/registry` and `devices/+/status` on connect.
3. Parse incoming registry JSON messages into a `Device` model:
   ```dart
   class Device {
     final String id;
     final String ledTopic;
     bool isOnline;
     bool ledState;
   }
   ```
4. Maintain an in-memory map of known devices, keyed by `device_id`.
   Update it as registry/status messages arrive. This directly replaces
   the Python script's `known_devices` dict.
5. Basic list screen: show all known devices with their online/offline
   status.

### Phase 2 — Control
6. Tap-to-toggle: publish `"ON"` or `"OFF"` to a device's `led_topic` with
   QoS 1 (guarantees delivery once, appropriate for commands that must not
   be silently dropped) [web:185][web:186].
7. Optimistic UI update on tap, reconciled with the actual state once the
   device's next registry/status update confirms it (devices don't
   currently echo state changes back immediately — see Section 7 for a
   firmware enhancement that would improve this).
8. Pull-to-refresh or manual "rescan" button that re-subscribes to force
   retained messages to redeliver, in case a device was missed.

### Phase 3 — Resilience
9. Reconnection with exponential backoff on connection loss, mirroring the
   approach already used in the device firmware [web:185].
10. Re-subscribe to all topics automatically after every reconnect — most
    brokers drop subscriptions when a session ends unless using a proper
    persistent session [web:185][web:186].
11. Network-awareness: detect when the phone itself has no network and
    show a clear "no connection" state rather than a confusing empty
    device list.
12. Handle app backgrounding gracefully — see Section 5 for platform
    specifics.

### Phase 4 — Polish (optional, v2)
13. Per-device nickname/label editing (stored locally on the phone), so
    devices show as "Living Room LED" instead of a raw hex ID.
14. Last-seen timestamp per device.
15. Manual broker/topic configuration screen (useful if you migrate off
    the public test broker later).

---

## 5. Mobile Lifecycle Considerations (give this to the LLM explicitly)

Mobile OSes aggressively limit background networking, which affects a
persistent MQTT connection:

- **iOS:** long-lived background connections are heavily restricted. A
  common, pragmatic pattern is to only maintain the MQTT connection while
  the app is in the foreground, and reconnect + resubscribe when the app
  returns to foreground [web:174][web:185]. Trying to keep a full-time
  background MQTT connection on iOS requires special entitlements (VoIP,
  background fetch) and is not reliable for this use case — don't build
  for that in v1.
- **Android:** foreground connections work the same way; if a truly
  persistent background connection is wanted later, that requires a
  foreground service, which should be a deliberate v2 decision, not a
  default [web:185].
- **Recommended v1 behavior:** connect when the app opens, disconnect
  cleanly when it's sent to background for an extended period, reconnect
  and resubscribe on foreground. This matches how the Python test script
  already behaves (only "live" while running) and avoids fighting OS
  battery/background restrictions.

---

## 6. Security Notes (give this to the LLM explicitly)

- The current setup uses `test.mosquitto.org:1883` — public, unauthenticated,
  unencrypted. This is fine for development but the LLM should **not**
  hardcode this as a permanent production broker in generated code without
  flagging it.
- Before distributing this app beyond your own device (e.g., via TestFlight,
  Play Store internal testing, or sharing with others), plan to:
  - Move to a private broker with authentication (self-hosted Mosquitto,
    or a managed service).
  - Use TLS (`mqtts://`, typically port 8883) instead of plain `mqtt://`.
  - Store broker credentials in secure platform storage — Keychain on iOS,
    EncryptedSharedPreferences/Android Keystore on Android — not hardcoded
    in source [web:186].
- Ask the LLM to make the broker URL/port/TLS-toggle a configurable setting
  from the start, even if defaulted to the public test broker, so migrating
  later doesn't require a code change.

---

## 7. Optional Firmware Enhancement (mention to the LLM, but this is device-side, not app-side)

Currently, after an `ON`/`OFF` command is sent, the device doesn't
immediately re-publish its new state — the app would only learn the true
current state from the next registry announcement or status update. Two
options exist, and it's worth deciding before the LLM builds Phase 2:

- **Simplest:** on the device firmware, immediately publish an updated
  `led_state` field to `devices/registry` (retained) any time `set_led()`
  is called, not just at boot. This is a small firmware change (a few
  lines) that makes the state genuinely authoritative and removes the need
  for the app to guess/optimistically assume success.
- **Alternative:** add a dedicated `devices/<device_id>/led/state` topic
  that the device publishes to (retained) on every state change, separate
  from the registry topic. Cleaner separation of "who exists" vs. "what's
  its current state," but is a slightly bigger change.

Recommend picking the first option for now — it's a minimal addition to
the existing `publish_registration()` function and immediately makes the
mobile app's state display trustworthy without guesswork.

---

## 8. Prompt Template for the LLM

Paste this as your actual instruction to the LLM, adjusting the bracketed
parts as needed:

> Build a Flutter app that connects to an MQTT broker and controls a fleet
> of ESP32-C3 IoT devices, replacing a Python CLI test script. Use the
> `mqtt_client` Dart package. Broker: `test.mosquitto.org`, port 1883,
> plain TCP (no TLS for now, but make this configurable). Devices announce
> themselves via retained JSON messages on `devices/registry` in the form
> `{"device_id": "...", "status": "online", "led_topic": "...",
> "led_state": "ON"|"OFF"}`. Devices also publish to
> `devices/<device_id>/status` with `"online"`/`"offline"` (offline is set
> via broker Last Will on unexpected disconnect). To control a device,
> publish the plain text payload `"ON"` or `"OFF"` (QoS 1) to its
> `led_topic`. Build: (1) a service layer that manages the MQTT connection
> as a singleton, handles reconnection with exponential backoff, and
> resubscribes to `devices/registry` and `devices/+/status` after every
> reconnect; (2) a device list screen showing all discovered devices with
> online/offline status and a toggle switch reflecting/controlling LED
> state; (3) graceful handling of app foreground/background transitions
> per iOS/Android platform norms — connect on foreground, disconnect
> cleanly if backgrounded for an extended period, reconnect and
> resubscribe on return to foreground. Use Riverpod for state management.
> Do not hardcode broker credentials in a way that blocks moving to a
> private authenticated broker later — expose broker host/port/TLS as
> configurable values.

---

## 9. Suggested Build Order / Milestones

1. Bare Flutter app that connects to the broker and prints raw incoming
   messages to the console — proves connectivity works before any UI.
2. Parse registry messages into a device list, render as a simple
   `ListView` with online/offline text.
3. Add the ON/OFF toggle per device, wired to publish commands.
4. Add reconnect/resubscribe logic and foreground/background handling.
5. Polish: nicknames, last-seen timestamps, manual broker config screen.

Each milestone should be independently testable against your existing
firmware without any firmware changes required until Section 7's optional
enhancement, if you choose to do it.
