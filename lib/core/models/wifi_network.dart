/// A Wi-Fi network reported by the device in a `scan_result` BLE message.
class WifiNetwork {
  const WifiNetwork({
    required this.ssid,
    required this.rssi,
    required this.auth,
    required this.channel,
  });

  factory WifiNetwork.fromJson(Map<String, dynamic> json) {
    return WifiNetwork(
      ssid: json['ssid'] as String? ?? '',
      rssi: json['rssi'] as int? ?? 0,
      auth: json['auth'] as String? ?? 'UNKNOWN',
      channel: json['channel'] as int? ?? 0,
    );
  }

  final String ssid;
  final int rssi;
  final String auth;
  final int channel;

  bool get isOpen => auth == 'OPEN';

  String get authLabel {
    switch (auth) {
      case 'OPEN':
        return 'Open';
      case 'WEP':
        return 'WEP';
      case 'WPA':
        return 'WPA';
      case 'WPA2':
        return 'WPA2';
      case 'WPA/WPA2':
        return 'WPA/WPA2';
      case 'WPA3':
        return 'WPA3';
      case 'WPA2/WPA3':
        return 'WPA2/WPA3';
      case 'WPA2-ENT':
        return 'Enterprise';
      default:
        return auth;
    }
  }

  WifiNetwork copyWith({
    String? ssid,
    int? rssi,
    String? auth,
    int? channel,
  }) {
    return WifiNetwork(
      ssid: ssid ?? this.ssid,
      rssi: rssi ?? this.rssi,
      auth: auth ?? this.auth,
      channel: channel ?? this.channel,
    );
  }
}
