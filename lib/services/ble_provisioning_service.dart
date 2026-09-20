import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/config/ble_provisioning_config.dart';

enum BleLinkState { disconnected, connecting, connected, error }

/// Wraps the BLE GATT provisioning service on the ESP32-C3.
///
/// The phone writes newline-terminated JSON commands to the RX characteristic
/// and receives newline-terminated JSON responses as notifications on the TX
/// characteristic. Long responses are split across several notifications by the
/// device; this class reassembles them on `\n`.
class BleProvisioningService {
  BleProvisioningService() {
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      _lastAdapterState = state;
    });
  }

  final _lines = StreamController<String>.broadcast();
  final _connectionState = StreamController<BleLinkState>.broadcast();

  StreamSubscription? _adapterSub;
  StreamSubscription? _connStateSub;
  StreamSubscription? _txSub;

  BluetoothAdapterState _lastAdapterState = BluetoothAdapterState.unknown;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _rx;
  bool _isConnected = false;

  final StringBuffer _rxBuffer = StringBuffer();

  /// Newline-delimited JSON messages received from the device.
  Stream<String> get lines => _lines.stream;

  Stream<BleLinkState> get connectionState => _connectionState.stream;

  BleLinkState get linkState =>
      _isConnected ? BleLinkState.connected : BleLinkState.disconnected;

  /// Raw FlutterBluePlus scan result stream (re-emits the full list).
  Stream<List<ScanResult>> get scanResults => FlutterBluePlus.scanResults;

  Stream<bool> get isScanning => FlutterBluePlus.isScanning;

  bool get adapterIsOn => _lastAdapterState == BluetoothAdapterState.on;

  BluetoothAdapterState get adapterState => _lastAdapterState;

  Future<void> turnOn() => FlutterBluePlus.turnOn();

  Future<void> scanForDevices() {
    // Unfiltered scan: filtering by service UUID at the platform level is
    // unreliable on some Android devices, so we scan everything and let the UI
    // filter by name prefix / advertised service UUID instead.
    //
    // androidCheckLocationServices stays on: on many phones BLE scanning still
    // needs the Location services toggle, and a clear error here beats a silent
    // "no devices found".
    return FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 30),
      androidCheckLocationServices: true,
    );
  }

  Future<void> stopScan() => FlutterBluePlus.stopScan();

  Future<void> connect(BluetoothDevice device) async {
    // Tear down any previous device first. Reconnecting to the same device
    // (e.g. after a failed attempt) without disconnecting can fail on Android
    // if a stale GATT connection from the previous attempt lingers at the
    // platform level.
    if (_device != null) {
      await disconnect();
    }
    _device = device;
    _emitState(BleLinkState.connecting);

    try {
      await device.connect(
        license: License.nonprofit,
        mtu: 512,
        timeout: const Duration(seconds: 15),
      );
    } catch (e) {
      // flutter_blue_plus cancels the pending attempt on timeout, but make
      // sure no partial platform connection is left behind either.
      if (device.isConnected) {
        await device.disconnect();
      }
      _device = null;
      _emitState(BleLinkState.error);
      rethrow;
    }

    _connStateSub?.cancel();
    _connStateSub = device.connectionState.listen((state) {
      final connected = state == BluetoothConnectionState.connected;
      if (connected != _isConnected) {
        _isConnected = connected;
        _emitState(
          connected ? BleLinkState.connected : BleLinkState.disconnected,
        );
      }
    });

    final chars = await _findProvisioningService(device);
    if (chars == null) {
      if (device.isConnected) {
        await device.disconnect();
      }
      _device = null;
      _emitState(BleLinkState.error);
      throw StateError('Provisioning service not found on device');
    }
    _rx = chars.$1;
    final tx = chars.$2;

    // Subscribe to notifications BEFORE enabling them. The device sends its
    // `hello` immediately when we subscribe, so listening afterwards would race
    // and drop the first messages.
    _txSub?.cancel();
    _txSub = tx.onValueReceived.listen(_onDataReceived);
    await tx.setNotifyValue(true);
  }

  /// Finds the RX/TX provisioning characteristics on [device].
  ///
  /// Android caches a peripheral's GATT database per device address, and on a
  /// reconnect to a device we have connected to before `discoverServices()`
  /// can return a stale — even empty — service list (surfacing as
  /// "Provisioning service not found"). When the first discovery does not find
  /// the service, clear the cache (`BluetoothGatt.refresh`) and rediscover once
  /// before giving up.
  Future<(BluetoothCharacteristic, BluetoothCharacteristic)?>
  _findProvisioningService(BluetoothDevice device) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0 && !device.isConnected) {
        await device.connect(
          license: License.nonprofit,
          mtu: 512,
          timeout: const Duration(seconds: 15),
        );
      }

      final services = await device.discoverServices();
      BluetoothCharacteristic? rx;
      BluetoothCharacteristic? tx;
      for (final service in services) {
        debugPrint('[ble] service: ${service.uuid.str}');
        if (service.uuid.str != BleProvisioningConfig.serviceUuid) continue;
        for (final characteristic in service.characteristics) {
          debugPrint(
            '[ble]   chr: ${characteristic.uuid.str} '
            'props=${characteristic.properties}',
          );
          if (characteristic.uuid.str ==
              BleProvisioningConfig.rxCharacteristicUuid) {
            rx = characteristic;
          } else if (characteristic.uuid.str ==
              BleProvisioningConfig.txCharacteristicUuid) {
            tx = characteristic;
          }
        }
      }
      if (rx != null && tx != null) return (rx, tx);

      if (attempt == 0 && defaultTargetPlatform == TargetPlatform.android) {
        debugPrint(
          '[ble] provisioning service not found; '
          'clearing Android GATT cache and retrying',
        );
        try {
          await device.clearGattCache();
          // Give the stack a moment to apply the refresh before rediscovering.
          await Future<void>.delayed(const Duration(milliseconds: 400));
        } catch (e) {
          debugPrint('[ble] clearGattCache failed: $e');
        }
      }
    }
    return null;
  }

  Future<void> disconnect() async {
    _txSub?.cancel();
    _txSub = null;
    _connStateSub?.cancel();
    _connStateSub = null;
    final device = _device;
    _device = null;
    _rx = null;
    _rxBuffer.clear();
    if (device != null && device.isConnected) {
      await device.disconnect();
    }
    _isConnected = false;
    _emitState(BleLinkState.disconnected);
  }

  /// Writes a command line (a `\n` is appended automatically).
  ///
  /// Uses write-without-response: this is a UART-style command pipe and we
  /// don't want to block waiting for a Write Response (which can hang on some
  /// Android/device combinations).
  Future<void> sendCommand(String line) async {
    final rx = _rx;
    if (rx == null) {
      debugPrint('[ble] sendCommand: no RX characteristic');
      throw StateError('Not connected to a provisioning device');
    }
    final payload = Uint8List.fromList(utf8.encode('$line\n'));
    debugPrint('[ble] writing ${payload.length} bytes to ${rx.uuid.str}');
    try {
      await rx.write(payload, withoutResponse: true);
      debugPrint('[ble] write completed');
    } catch (e) {
      debugPrint('[ble] write FAILED: $e');
      rethrow;
    }
  }

  void _onDataReceived(List<int> data) {
    for (final byte in data) {
      if (byte == 0x0A) {
        // '\n' — end of a logical message.
        final line = _rxBuffer.toString();
        _rxBuffer.clear();
        if (line.isNotEmpty && !_lines.isClosed) {
          _lines.add(line);
        }
      } else if (byte != 0x0D) {
        _rxBuffer.writeCharCode(byte);
      }
    }
  }

  void _emitState(BleLinkState state) {
    if (!_connectionState.isClosed) {
      _connectionState.add(state);
    }
  }

  void dispose() {
    _txSub?.cancel();
    _connStateSub?.cancel();
    _adapterSub?.cancel();
    if (_device != null && _device!.isConnected) {
      _device!.disconnect();
    }
    _lines.close();
    _connectionState.close();
  }
}
