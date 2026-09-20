class Device {
  const Device({
    required this.id,
    required this.isOnline,
    required this.ledOn,
    this.ledTopic,
    this.lastSeen,
    this.ssid,
    this.rssi,
    this.uptimeSeconds,
    this.temperatureC,
  });

  factory Device.fromRegistry(Map<String, dynamic> json) {
    return Device(
      id: json['device_id'] as String,
      ledTopic: json['led_topic'] as String?,
      isOnline: json['status'] == 'online',
      ledOn: json['led_state'] == 'ON',
    );
  }

  final String id;
  final String? ledTopic;
  final bool isOnline;
  final bool ledOn;
  final DateTime? lastSeen;
  final String? ssid;
  final int? rssi;
  final int? uptimeSeconds;
  final double? temperatureC;

  bool get isControllable => isOnline && ledTopic != null;

  Device copyWith({
    String? ledTopic,
    bool? isOnline,
    bool? ledOn,
    DateTime? lastSeen,
    String? ssid,
    int? rssi,
    int? uptimeSeconds,
    double? temperatureC,
  }) {
    return Device(
      id: id,
      ledTopic: ledTopic ?? this.ledTopic,
      isOnline: isOnline ?? this.isOnline,
      ledOn: ledOn ?? this.ledOn,
      lastSeen: lastSeen ?? this.lastSeen,
      ssid: ssid ?? this.ssid,
      rssi: rssi ?? this.rssi,
      uptimeSeconds: uptimeSeconds ?? this.uptimeSeconds,
      temperatureC: temperatureC ?? this.temperatureC,
    );
  }
}
