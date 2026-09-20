import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:esp32c3_remote_app/core/models/device.dart';
import 'package:esp32c3_remote_app/core/storage/settings_repository.dart';
import 'package:esp32c3_remote_app/features/devices/device_list_screen.dart';
import 'package:esp32c3_remote_app/services/mqtt_service.dart';

void main() {
  test('parses a registry announcement', () {
    final json = jsonDecode(
      '{"device_id":"a1b2c3d4e5f6","status":"online",'
      '"led_topic":"devices/a1b2c3d4e5f6/led/set","led_state":"ON"}',
    ) as Map<String, dynamic>;

    final device = Device.fromRegistry(json);

    expect(device.id, 'a1b2c3d4e5f6');
    expect(device.ledTopic, 'devices/a1b2c3d4e5f6/led/set');
    expect(device.isOnline, isTrue);
    expect(device.ledOn, isTrue);
    expect(device.isControllable, isTrue);
  });

  test('offline device without topic is not controllable', () {
    const device = Device(id: 'a1b2c3d4e5f6', isOnline: false, ledOn: false);

    expect(device.isControllable, isFalse);
  });

  test('copyWith preserves id and updates state', () {
    const device = Device(
      id: 'a1b2c3d4e5f6',
      ledTopic: 'devices/a1b2c3d4e5f6/led/set',
      isOnline: true,
      ledOn: false,
    );

    final updated = device.copyWith(ledOn: true);

    expect(updated.id, device.id);
    expect(updated.ledTopic, device.ledTopic);
    expect(updated.ledOn, isTrue);
  });

  test('new devices have no telemetry', () {
    const device = Device(id: 'a1b2c3d4e5f6', isOnline: false, ledOn: false);

    expect(device.ssid, isNull);
    expect(device.rssi, isNull);
    expect(device.uptimeSeconds, isNull);
    expect(device.temperatureC, isNull);
  });

  test('copyWith sets and preserves telemetry', () {
    const device = Device(id: 'a1b2c3d4e5f6', isOnline: false, ledOn: false);

    final withTelemetry = device.copyWith(
      ssid: 'MyNetwork',
      rssi: -45,
      uptimeSeconds: 1234,
      temperatureC: 41.2,
    );
    final merged = withTelemetry.copyWith(isOnline: true);

    expect(merged.id, device.id);
    expect(merged.isOnline, isTrue);
    expect(merged.ssid, 'MyNetwork');
    expect(merged.rssi, -45);
    expect(merged.uptimeSeconds, 1234);
    expect(merged.temperatureC, 41.2);
  });

  test('formatUptime renders human-readable uptime', () {
    expect(formatUptime(0), '0s');
    expect(formatUptime(45), '45s');
    expect(formatUptime(90), '1m');
    expect(formatUptime(1234), '20m');
    expect(formatUptime(3600), '1h 0m');
    expect(formatUptime(5400), '1h 30m');
    expect(formatUptime(90061), '1d 1h');
  });

  test('formatUptime handles null and negative', () {
    expect(formatUptime(null), 'unknown');
    expect(formatUptime(-1), 'unknown');
  });

  test('wifiSetTopic builds the wifi management topic', () {
    expect(
      MqttService.wifiSetTopic('a1b2c3d4e5f6'),
      'devices/a1b2c3d4e5f6/wifi/set',
    );
  });

  test('fallback settings round-trip per device', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final repository = SettingsRepository(prefs);

    expect(repository.loadFallbackSettings(), isEmpty);

    await repository.saveFallbackSettings('a1b2c3d4e5f6', true, 5);
    expect(repository.loadFallbackSettings()['a1b2c3d4e5f6'], (
      enabled: true,
      timeoutMinutes: 5,
    ));

    await repository.saveFallbackSettings('a1b2c3d4e5f6', false, 1);
    expect(repository.loadFallbackSettings()['a1b2c3d4e5f6'], (
      enabled: false,
      timeoutMinutes: 1,
    ));
  });
}
