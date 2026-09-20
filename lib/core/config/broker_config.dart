import 'dart:convert';

class BrokerConfig {
  const BrokerConfig({
    required this.host,
    required this.port,
    required this.useTls,
    this.username,
    this.password,
  });

  const BrokerConfig.development()
      : host = 'test.mosquitto.org',
        port = 1883,
        useTls = false,
        username = null,
        password = null;

  factory BrokerConfig.fromJson(String source) {
    final json = jsonDecode(source) as Map<String, dynamic>;
    return BrokerConfig(
      host: json['host'] as String,
      port: json['port'] as int,
      useTls: json['useTls'] as bool? ?? false,
      username: json['username'] as String?,
      password: json['password'] as String?,
    );
  }

  final String host;
  final int port;
  final bool useTls;
  final String? username;
  final String? password;

  String toJson() => jsonEncode({
        'host': host,
        'port': port,
        'useTls': useTls,
        'username': username,
        'password': password,
      });
}
