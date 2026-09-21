import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config/broker_config.dart';
import '../core/models/device.dart';
import '../core/storage/settings_repository.dart';
import '../services/mqtt_service.dart';

final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('overridden in main()');
});

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SettingsRepository(ref.watch(sharedPreferencesProvider));
});

final brokerConfigProvider =
    NotifierProvider<BrokerConfigNotifier, BrokerConfig>(
  BrokerConfigNotifier.new,
);

class BrokerConfigNotifier extends Notifier<BrokerConfig> {
  @override
  BrokerConfig build() => ref.watch(settingsRepositoryProvider).loadBrokerConfig();

  Future<void> update(BrokerConfig config) async {
    await ref.read(settingsRepositoryProvider).saveBrokerConfig(config);
    state = config;
  }
}

final mqttServiceProvider = Provider<MqttService>((ref) {
  ref.keepAlive();
  final service = MqttService(ref.watch(brokerConfigProvider));
  ref.onDispose(service.dispose);
  Future.microtask(service.ensureConnected);
  return service;
});

final connectionStatusProvider =
    NotifierProvider<ConnectionStatusNotifier, MqttLinkState>(
  ConnectionStatusNotifier.new,
);

class ConnectionStatusNotifier extends Notifier<MqttLinkState> {
  @override
  MqttLinkState build() {
    final service = ref.watch(mqttServiceProvider);
    final subscription = service.events.listen((event) {
      if (event is MqttLinkChanged) state = event.state;
    });
    ref.onDispose(subscription.cancel);
    return MqttLinkState.idle;
  }
}

final devicesProvider =
    NotifierProvider<DevicesNotifier, Map<String, Device>>(
  DevicesNotifier.new,
);

/// The device IDs this app has provisioned. Only these appear in the device
/// list; announcements from unrelated devices on the shared registry topic are
/// ignored.
final myDevicesProvider = NotifierProvider<MyDevicesNotifier, Set<String>>(
  MyDevicesNotifier.new,
);

class MyDevicesNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() =>
      ref.watch(settingsRepositoryProvider).loadMyDeviceIds();

  Future<void> add(String deviceId) async {
    final next = {...state, deviceId};
    state = next;
    await ref.read(settingsRepositoryProvider).saveMyDeviceIds(next);
  }

  Future<void> remove(String deviceId) async {
    final next = {...state}..remove(deviceId);
    state = next;
    await ref.read(settingsRepositoryProvider).saveMyDeviceIds(next);
  }

  bool contains(String deviceId) => state.contains(deviceId);
}

class DevicesNotifier extends Notifier<Map<String, Device>> {
  @override
  Map<String, Device> build() {
    final service = ref.watch(mqttServiceProvider);
    final subscription = service.events.listen(_handleEvent);
    ref.onDispose(subscription.cancel);
    return const {};
  }

  void _handleEvent(MqttEvent event) {
    switch (event) {
      case MqttMessageReceived(:final topic, :final payload):
        _applyMessage(topic, payload);
      case MqttLinkChanged(state: MqttLinkState.connected):
        ref.read(mqttServiceProvider).ensureConnected();
      default:
        break;
    }
  }

  void _applyMessage(String topic, String payload) {
    Device? updated;
    if (topic == MqttService.registryTopic) {
      updated = _fromRegistryPayload(payload);
    } else if (topic.endsWith('/status') && topic.startsWith('devices/')) {
      final deviceId = topic.split('/')[1];
      if (deviceId.isEmpty) return;
      updated = _fromStatusPayload(deviceId, payload);
    }
    if (updated == null) return;

    // Only show devices this app has set up.
    if (!ref.read(myDevicesProvider).contains(updated.id)) {
      debugPrint('[mqtt] ignoring device ${updated.id} (not set up by this app)');
      return;
    }
    state = {...state, updated.id: updated};
  }

  Device? _fromRegistryPayload(String payload) {
    try {
      final json = jsonDecode(payload) as Map<String, dynamic>;
      final id = json['device_id'] as String?;
      if (id == null || id.isEmpty) return null;
      final device = Device.fromRegistry(json);
      return device.copyWith(lastSeen: DateTime.now());
    } catch (error) {
      debugPrint('[mqtt] failed to parse registry message: $error');
      return null;
    }
  }

  Device? _fromStatusPayload(String deviceId, String payload) {
    final base =
        state[deviceId] ?? Device(id: deviceId, isOnline: false, ledOn: false);

    try {
      final json = jsonDecode(payload) as Map<String, dynamic>;
      return base.copyWith(
        isOnline: json['state']?.toString().toLowerCase() == 'online',
        ssid: json['ssid'] as String?,
        rssi: (json['rssi'] as num?)?.toInt(),
        uptimeSeconds: (json['uptime_s'] as num?)?.toInt(),
        temperatureC: (json['temp_c'] as num?)?.toDouble(),
        lastSeen: DateTime.now(),
      );
    } catch (error) {
      // Legacy plain-text "online"/"offline" payload.
      return base.copyWith(
        isOnline: payload.trim().toLowerCase() == 'online',
        lastSeen: DateTime.now(),
      );
    }
  }

  bool canToggle(String deviceId) {
    final device = state[deviceId];
    return device != null &&
        device.isControllable &&
        ref.read(connectionStatusProvider) == MqttLinkState.connected;
  }

  void toggleLed(String deviceId) {
    final device = state[deviceId];
    if (device == null || !canToggle(deviceId)) return;

    final next = !device.ledOn;
    state = {...state, deviceId: device.copyWith(ledOn: next)};
    ref.read(mqttServiceProvider).publishLedCommand(device.ledTopic!, next);
  }

  Future<void> rescan() => ref.read(mqttServiceProvider).reconnect();

  /// Ask the device to start BLE advertising again so the user can change its
  /// Wi-Fi credentials. The device stays online on its current network.
  void reprovision(String deviceId) {
    ref.read(mqttServiceProvider).publishJson(
          MqttService.wifiSetTopic(deviceId),
          {'command': 'reprovision'},
        );
  }

  /// Publish a remove command (the device clears its Wi-Fi credentials and
  /// returns to BLE setup mode) and drop the device from this app.
  Future<void> removeDevice(String deviceId) async {
    ref.read(mqttServiceProvider).publishJson(
          MqttService.wifiSetTopic(deviceId),
          {'command': 'remove'},
        );
    state = {...state}..remove(deviceId);
    await ref.read(myDevicesProvider.notifier).remove(deviceId);
  }

  void setFallback(
    String deviceId, {
    required bool enabled,
    required int timeoutMinutes,
  }) {
    ref.read(mqttServiceProvider).publishJson(
          MqttService.wifiSetTopic(deviceId),
          {
            'command': 'set_fallback',
            'enabled': enabled,
            'timeout_min': timeoutMinutes,
          },
        );
  }
}

final nicknamesProvider =
    NotifierProvider<NicknamesNotifier, Map<String, String>>(
  NicknamesNotifier.new,
);

class NicknamesNotifier extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() =>
      ref.watch(settingsRepositoryProvider).loadNicknames();

  Future<void> rename(String deviceId, String nickname) async {
    final trimmed = nickname.trim();
    final next = {...state};
    if (trimmed.isEmpty) {
      next.remove(deviceId);
    } else {
      next[deviceId] = trimmed;
    }
    state = next;
    await ref.read(settingsRepositoryProvider).saveNicknames(next);
  }
}
