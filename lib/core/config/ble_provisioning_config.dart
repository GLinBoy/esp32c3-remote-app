/// Constants for the BLE provisioning GATT service on the ESP32-C3 firmware.
///
/// The device exposes a Nordic-UART-style byte pipe: the phone writes
/// newline-terminated JSON lines to the RX characteristic and receives
/// newline-terminated JSON lines via notifications on the TX characteristic.
class BleProvisioningConfig {
  BleProvisioningConfig._();

  static const serviceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const rxCharacteristicUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
  static const txCharacteristicUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';

  /// Devices advertise as `ESP32C3-<last 3 bytes of MAC>` (e.g. ESP32C3-a9e0f3).
  static const deviceNamePrefix = 'ESP32C3-';

  /// Shows the `Debug:` scan-diagnostics line on the BLE setup screen.
  /// Set to `false` to hide it (useful for a clean UI in production).
  static const bool showDebugInfo = true;
}
