import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../core/config/broker_config.dart';

enum MqttLinkState { idle, connecting, connected, reconnecting, disconnected }

sealed class MqttEvent {
  const MqttEvent();
}

class MqttLinkChanged extends MqttEvent {
  const MqttLinkChanged(this.state, this.detail);
  final MqttLinkState state;
  final String detail;
}

class MqttMessageReceived extends MqttEvent {
  const MqttMessageReceived(this.topic, this.payload);
  final String topic;
  final String payload;
}

class MqttService {
  MqttService(this._config) {
    _client = _buildClient();
  }

  static const registryTopic = 'devices/registry';
  static const statusTopicFilter = 'devices/+/status';

  /// Topic a device listens on for management commands (reprovision, remove,
  /// set_fallback).
  static String wifiSetTopic(String deviceId) => 'devices/$deviceId/wifi/set';

  static const _retryBaseDelay = Duration(seconds: 1);
  static const _retryMaxDelay = Duration(seconds: 60);

  final BrokerConfig _config;
  late final MqttServerClient _client;

  final _events = StreamController<MqttEvent>.broadcast();
  Stream<MqttEvent> get events => _events.stream;

  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>?
  _updatesSubscription;

  Timer? _retryTimer;
  int _retryAttempt = 0;
  bool _disposed = false;
  bool _userDisconnected = false;
  bool _connectInFlight = false;

  MqttLinkState get linkState {
    switch (_client.connectionStatus?.state) {
      case MqttConnectionState.connected:
        return MqttLinkState.connected;
      case MqttConnectionState.connecting:
      case MqttConnectionState.faulted:
        return MqttLinkState.connecting;
      default:
        return MqttLinkState.disconnected;
    }
  }

  MqttServerClient _buildClient() {
    final client = MqttServerClient.withPort(
      _config.host,
      'esp32c3_remote_app_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}',
      _config.port,
    );
    client.logging(on: false);
    client.setProtocolV311();
    client.keepAlivePeriod = 30;
    client.connectTimeoutPeriod = 5000;
    client.secure = _config.useTls;
    client.autoReconnect = true;
    client.resubscribeOnAutoReconnect = true;

    client.onConnected = _onConnected;
    client.onDisconnected = _onDisconnected;
    client.onAutoReconnect = _onAutoReconnecting;
    client.onAutoReconnected = _onAutoReconnected;

    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(client.clientIdentifier)
        .startClean();

    return client;
  }

  Future<void> connect() async {
    if (_disposed || _connectInFlight || _userDisconnected) return;
    if (linkState == MqttLinkState.connected) return;

    _connectInFlight = true;
    _emit(
      MqttLinkState.connecting,
      'connecting to ${_config.host}:${_config.port}',
    );
    try {
      await _client.connect();
    } catch (error) {
      _emit(MqttLinkState.disconnected, 'connect failed: $error');
      _scheduleRetry();
    } finally {
      _connectInFlight = false;
    }

    if (!_disposed && linkState != MqttLinkState.connected) {
      _scheduleRetry();
    }
  }

  void ensureConnected() {
    if (_disposed) return;
    _userDisconnected = false;
    if (_retryTimer?.isActive ?? false) return;
    if (_connectInFlight) return;
    if (linkState == MqttLinkState.connected) return;
    unawaited(connect());
  }

  Future<void> disconnect() async {
    _userDisconnected = true;
    _retryTimer?.cancel();
    _client.autoReconnect = false;
    try {
      _client.disconnect();
    } catch (_) {}
    _emit(MqttLinkState.disconnected, 'disconnected by user');
  }

  Future<void> reconnect() async {
    if (_disposed) return;
    _retryTimer?.cancel();
    _userDisconnected = false;
    _client.autoReconnect = false;
    try {
      _client.disconnect();
    } catch (_) {}
    _client.autoReconnect = true;
    await connect();
  }

  void publishLedCommand(String topic, bool on) {
    _publish(topic, on ? 'ON' : 'OFF');
  }

  void publishJson(String topic, Map<String, dynamic> payload) {
    _publish(topic, jsonEncode(payload));
  }

  void _publish(String topic, String payload) {
    if (linkState != MqttLinkState.connected) return;
    final builder = MqttClientPayloadBuilder();
    builder.addString(payload);
    _client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retryTimer?.cancel();
    _updatesSubscription?.cancel();
    try {
      _client.disconnect();
    } catch (_) {}
    unawaited(_events.close());
  }

  void _onMessages(List<MqttReceivedMessage<MqttMessage>> messages) {
    for (final received in messages) {
      final publish = received.payload as MqttPublishMessage;
      final text = MqttPublishPayload.bytesToStringAsString(
        publish.payload.message,
      );
      if (_events.isClosed) return;
      _events.add(MqttMessageReceived(received.topic, text));
    }
  }

  void _onConnected() {
    _retryAttempt = 0;
    _retryTimer?.cancel();
    _updatesSubscription?.cancel();
    _updatesSubscription = _client.updates?.listen(_onMessages);
    _client.subscribe(registryTopic, MqttQos.atLeastOnce);
    _client.subscribe(statusTopicFilter, MqttQos.atLeastOnce);
    _emit(
      MqttLinkState.connected,
      'subscribed to $registryTopic and $statusTopicFilter',
    );
  }

  void _onDisconnected() {
    if (_disposed || _userDisconnected) return;
    _emit(MqttLinkState.disconnected, 'connection lost');
    _scheduleRetry();
  }

  void _onAutoReconnecting() {
    _emit(MqttLinkState.reconnecting, 'auto reconnecting');
  }

  void _onAutoReconnected() {
    _emit(MqttLinkState.connected, 'auto reconnected');
  }

  void _scheduleRetry() {
    if (_disposed || _userDisconnected) return;
    if (_retryTimer?.isActive ?? false) return;
    var delay = _retryBaseDelay * pow(2, min(_retryAttempt, 8)).toInt();
    if (delay > _retryMaxDelay) delay = _retryMaxDelay;
    _retryAttempt += 1;
    _emit(MqttLinkState.reconnecting, 'next attempt in ${delay.inSeconds}s');
    _retryTimer = Timer(delay, () => unawaited(connect()));
  }

  void _emit(MqttLinkState state, String detail) {
    if (_events.isClosed) return;
    _events.add(MqttLinkChanged(state, detail));
  }
}
