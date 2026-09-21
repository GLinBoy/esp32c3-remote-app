# Mobile App: BLE Provisioning — Development Notes

This document records the problems hit while adding BLE Wi-Fi provisioning to the
Flutter app (`esp32c3_remote_app`) and how each was solved. It complements the main
[`README.md`](../README.md) and the firmware's
[development notes](../../PlatformIO/esp32c3_freertos/docs/ble-provisioning-development-notes.md),
which defines the BLE GATT service and JSON protocol.

The feature lives in:

- `lib/services/ble_provisioning_service.dart` — BLE scan/connect/messaging.
- `lib/features/provisioning/ble_provisioning_screen.dart` — the setup UI.
- `lib/core/config/ble_provisioning_config.dart` — UUIDs, name prefix, debug flag.

---

## 1. App found no devices while the phone's Bluetooth settings could

**Symptom:** the ESP32-C3 was visible in Android's Bluetooth settings and the
device serial log showed `Advertising started`, but the app's scan list was empty.

### 1a. Platform service-UUID filter was unreliable

The scan used `FlutterBluePlus.startScan(withServices: [Guid(nusService)])`,
filtering on the device side. This did not match reliably across Android devices.

**Fix:** switch to an **unfiltered** scan and filter the results **client-side**
by advertised service UUID or the `ESP32C3` name prefix
(`_onScanResults` in the provisioning screen).

### 1b. Name filter mismatch (short vs. complete name)

The firmware advertises the **short** name `ESP32C3` in the primary
advertisement and the complete name `ESP32C3-70548c` in the scan response. The
app filtered with `platformName.startsWith('ESP32C3-')`, which rejects the short
name.

**Fix:** relax the prefix to `startsWith('ESP32C3')` (no trailing hyphen) and keep
the service-UUID check as a second condition.

### 1c. flutter_blue_plus "Location services required" error

`flutter_blue_plus` checks the phone's Location services toggle before scanning
and errors if it is off. We first disabled it (`androidCheckLocationServices:
false`), which turned a fixable problem into a silent "no devices found".

**Fix:** re-enabled the check (`androidCheckLocationServices: true`) so the app
surfaces a clear error instead of failing silently.

---

## 2. `adapter=unknown` / `Bluetooth is off` on Android 11 — the main bug

**Symptom:** on the test phone (Samsung Galaxy A50, **Android 11 / SDK 30**), the
setup screen reported `Debug: adapter=unknown`, `scanning=false`, found nothing,
and "Turn on Bluetooth" did nothing — even though Bluetooth was on. The phone's
app-permission page showed **Location** but no **Nearby devices** entry.

**Root cause:** the app's manifest only declared the Android 12+ runtime
permissions (`BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`). On Android 11 those don't
exist, and the legacy `android.permission.BLUETOOTH` /
`android.permission.BLUETOOTH_ADMIN` were missing. Without them the app cannot
access the Bluetooth adapter at all, so flutter_blue_plus reported the adapter as
off/unknown and scanning returned nothing. ("Nearby devices" is an Android 12+
concept — its absence is expected on Android 11, and was the clue.)

**Fix** (`android/app/src/main/AndroidManifest.xml`): declare the legacy
permissions, matching the official `flutter_blue_plus` example:

```xml
<uses-permission android:name="android.permission.BLUETOOTH"            android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN"      android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" android:maxSdkVersion="28"/>
```

The Android 12+ permissions stay declared for newer phones:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
```

**Also required on Android 11:** the app asks for **Location** permission at
runtime and **Location services** must be enabled on the phone for BLE scanning.

**Verify:** dump the merged manifest of the APK:

```bash
aapt2 dump permissions build/app/outputs/flutter-apk/app-debug.apk | grep uses-permission
```

---

## 3. Adapter state and permission handling in the UI

- The service subscribes to `FlutterBluePlus.adapterState` and exposes
  `adapterIsOn` / `adapterState`.
- If the adapter is not `on`, the setup screen shows an "adapter off" banner with
  **Turn on Bluetooth** (`FlutterBluePlus.turnOn()`) and **Open app settings**
  (`openAppSettings()` from `permission_handler`), so the user can grant
  permissions manually.
- Permissions are requested via `permission_handler` (`bluetoothScan` +
  `bluetoothConnect` on Android 12+, `locationWhenInUse` on Android 11 and below).
- The scan auto-restarts while the setup screen is open and no device is found,
  so the device appears as soon as it starts advertising.

---

## 4. The app "connected" but the Wi-Fi scan button stayed disabled

**Symptom:** the device connected, but the welcome screen kept showing a small
spinner and the "Scan for Wi-Fi networks" button was greyed out, or the scan never
started. The device log showed it sent its `hello`/`status` notifications, but the
app never processed them.

**Root cause:** a **notification race**. The device sends `hello` _immediately_
when the app subscribes to the TX characteristic. The app called
`tx.setNotifyValue(true)` **before** subscribing to the value stream, so the very
first notifications (the `hello`) arrived while nothing was listening yet and were
dropped. `_deviceId` stayed null, so the scan button stayed disabled.

**Fix** (`lib/services/ble_provisioning_service.dart`): subscribe to the
characteristic's notification stream (`tx.onValueReceived`) **before** calling
`setNotifyValue(true)`.

---

## 5. Wi-Fi scan request wrote successfully but the device never reacted

**Symptom:** tapping "Scan for Wi-Fi" showed the spinner but the device's log never
showed `BLE command received` / `Wi-Fi scan started`. The app's `write()` reported
success yet nothing transmitted.

**Root cause:** the command was written **with response** (`write()` default), and
on the test Android 11 / Samsung device the write future completed without the
packet actually being delivered — the app waited on an acknowledgment that never
came.

**Fix** (`lib/services/ble_provisioning_service.dart`): use
`rx.write(payload, withoutResponse: true)`. A UART-style command pipe should not
wait for a device acknowledgment. Add a timeout around the command send in the UI
(`_scanWifi`) so a stuck write surfaces instead of spinning forever.

---

## 6. Wi-Fi scan results partially arrived but `scan_done` never did

**Symptom:** the app received most `scan_result` lines but never `scan_done`, so
the list stayed incomplete and the app timed out.

**Root cause:** firmware-side (see the firmware development notes §7–§8):
notifications were sent to the wrong connection and the burst overflowed the BLE
link. The app was fine; the device needed to track the subscribed connection and
pace the notifications.

**App-side hardening:** the Wi-Fi scan now has a 15-second timeout that returns to
the welcome screen with a clear message instead of spinning forever.

---

## 7. "App not installed" on the phone

**Symptom:** Android refused to install the APK with a generic "App not installed".

**Root causes (two separate ones hit):**

1. **Signature conflict:** a _release_ build was previously installed (signed with a
   different machine's debug key). Fix: uninstall the old app first, or install a
   build signed with the same key.
2. **Storage full:** `adb install` revealed the real error —
   `java.io.IOException: Requested internal only, but not enough space`. The phone
   had 100% disk usage. Fix: free up storage, then install. Debug builds are large
   (a fat debug APK can be 160 MB); use a per-ABI release build
   (`flutter build apk --release --split-per-abi` → `app-arm64-v8a-release.apk`,
   ~18 MB) for easier sideloading.

**Debugging tip:** when the generic message hides the cause, install over USB and
read the real error:

```bash
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
adb logcat   # flutter debugPrint() output lands here
```

The app logs `[ble]`/`[prov]` debug prints that were used to trace the whole
provisioning flow.

---

## 8. Debug info and how to hide it

During development the setup screen shows a **Debug:** line with scan diagnostics:

```
Debug: sdk=30 adapter=on permissions=true scanning=true raw=3
```

| Field         | Meaning                                                                             |
| ------------- | ----------------------------------------------------------------------------------- |
| `sdk`         | Android SDK version of the phone (30 = Android 11).                                 |
| `adapter`     | Bluetooth adapter state reported by flutter_blue_plus (`unknown/on/off/...`).       |
| `permissions` | Whether the app's permission request reported success.                              |
| `scanning`    | Whether a BLE scan is currently running.                                            |
| `raw`         | Number of BLE devices seen by the _unfiltered_ scan (before client-side filtering). |

The raw count is the key diagnostic: `raw = 0` means the phone's scan delivers
nothing (permission/location/adapter problem), while `raw > 0` with no ESP32-C3
listed means a discovery/filter problem.

**Hiding it:** set `BleProvisioningConfig.showDebugInfo` to `false` in
`lib/core/config/ble_provisioning_config.dart`. This hides the Debug line and the
"`N` other BLE device(s) are visible, so scanning works" diagnostic text from the
empty state. (The functional "adapter off" banner stays — it is not debug.)

---

## Troubleshooting cheatsheet

| Symptom                                                         | Likely cause / fix                                                                                                                                            |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| App finds nothing; `Debug: raw=0`                               | Phone can't scan: check Bluetooth is on, the app has Location permission (Android ≤ 11) or "Nearby devices" (Android 12+), and Location services are enabled. |
| `Debug: adapter=unknown`                                        | Missing legacy `BLUETOOTH`/`BLUETOOTH_ADMIN` permissions on Android ≤ 11 — see §2.                                                                            |
| `Debug: raw>0` but no `ESP32C3`                                 | Filter mismatch; check the device name/SERVICE in the list.                                                                                                   |
| Scan error mentioning "Location services"                       | Turn on Location services on the phone.                                                                                                                       |
| Device seen in OS Bluetooth but not in app                      | Don't connect from OS Bluetooth settings first; the firmware stays advertising now, but connect from the app to avoid confusion.                              |
| Device not in setup mode                                        | Its LED should be blinking; erase NVS on the device to force provisioning (`pio run -t erase`).                                                               |
| Connected, but "Scan for Wi-Fi" button disabled / small spinner | Notification race — subscribe before enabling notifications (see §4).                                                                                         |
| "Failed to request scan: TimeoutException…"                     | The command write hung; fixed by writing without response (see §5).                                                                                           |
| Scan spins then times out with no networks                      | Firmware notify issue (wrong connection / burst) — see firmware notes §7–§8; also check the device log for `scan_result send failed`.                         |
| "App not installed"                                             | Uninstall the old app first (signature conflict) and free phone storage (see §7).                                                                             |
