import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/broker_config.dart';

class SettingsRepository {
  static const _brokerConfigKey = 'broker_config';
  static const _nicknamesKey = 'device_nicknames';
  static const _myDeviceIdsKey = 'my_device_ids';
  static const _fallbackSettingsKey = 'device_fallback_settings';

  SettingsRepository(this._prefs);

  final SharedPreferences _prefs;

  BrokerConfig loadBrokerConfig() {
    final raw = _prefs.getString(_brokerConfigKey);
    if (raw == null) return const BrokerConfig.development();
    try {
      return BrokerConfig.fromJson(raw);
    } catch (_) {
      return const BrokerConfig.development();
    }
  }

  Future<void> saveBrokerConfig(BrokerConfig config) =>
      _prefs.setString(_brokerConfigKey, config.toJson());

  Map<String, String> loadNicknames() {
    final raw = _prefs.getString(_nicknamesKey);
    if (raw == null) return const {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((key, value) => MapEntry(key, value as String));
    } catch (_) {
      return const {};
    }
  }

  Future<void> saveNicknames(Map<String, String> nicknames) =>
      _prefs.setString(_nicknamesKey, jsonEncode(nicknames));

  /// The IDs of devices this app has set up. Only these devices are shown in
  /// the device list — other devices announcing on the shared registry topic
  /// are ignored.
  Set<String> loadMyDeviceIds() {
    final raw = _prefs.getStringList(_myDeviceIdsKey);
    if (raw == null) return const {};
    return raw.toSet();
  }

  Future<void> saveMyDeviceIds(Set<String> deviceIds) {
    final sorted = deviceIds.toList()..sort();
    return _prefs.setStringList(_myDeviceIdsKey, sorted);
  }

  /// Last-known fallback settings per device, so the management dialog can
  /// preload the values the user chose before.
  Map<String, ({bool enabled, int timeoutMinutes})> loadFallbackSettings() {
    final raw = _prefs.getString(_fallbackSettingsKey);
    if (raw == null) return const {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((id, value) {
        final v = value as Map<String, dynamic>;
        return MapEntry(
          id,
          (
            enabled: v['enabled'] == true,
            timeoutMinutes: (v['timeout_min'] as num?)?.toInt() ?? 3,
          ),
        );
      });
    } catch (_) {
      return const {};
    }
  }

  Future<void> saveFallbackSettings(
    String deviceId,
    bool enabled,
    int timeoutMinutes,
  ) {
    final all = {...loadFallbackSettings()};
    all[deviceId] = (enabled: enabled, timeoutMinutes: timeoutMinutes);
    final encoded = all.map(
      (id, v) => MapEntry(
        id,
        {'enabled': v.enabled, 'timeout_min': v.timeoutMinutes},
      ),
    );
    return _prefs.setString(_fallbackSettingsKey, jsonEncode(encoded));
  }
}
