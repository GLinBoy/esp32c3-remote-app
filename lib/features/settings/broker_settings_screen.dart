import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/broker_config.dart';
import '../../providers/app_providers.dart';

class BrokerSettingsScreen extends ConsumerStatefulWidget {
  const BrokerSettingsScreen({super.key});

  @override
  ConsumerState<BrokerSettingsScreen> createState() =>
      _BrokerSettingsScreenState();
}

class _BrokerSettingsScreenState extends ConsumerState<BrokerSettingsScreen> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late bool _useTls;
  bool _obscurePassword = true;

  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    final config = ref.read(brokerConfigProvider);
    _hostController = TextEditingController(text: config.host);
    _portController = TextEditingController(text: config.port.toString());
    _usernameController = TextEditingController(text: config.username ?? '');
    _passwordController = TextEditingController(text: config.password ?? '');
    _useTls = config.useTls;
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final config = BrokerConfig(
      host: _hostController.text.trim(),
      port: int.parse(_portController.text.trim()),
      useTls: _useTls,
      username: _usernameController.text.trim().isEmpty
          ? null
          : _usernameController.text.trim(),
      password: _passwordController.text.isEmpty ? null : _passwordController.text,
    );
    await ref.read(brokerConfigProvider.notifier).update(config);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reconnecting to ${config.host}:${config.port}...')),
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Broker Settings'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _hostController,
              decoration: const InputDecoration(
                labelText: 'Host',
                hintText: 'test.mosquitto.org',
                border: OutlineInputBorder(),
              ),
              validator: (value) =>
                  value == null || value.trim().isEmpty ? 'Host is required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _portController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Port',
                hintText: '1883 (plain) / 8883 (TLS)',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                final port = int.tryParse(value ?? '');
                if (port == null || port < 1 || port > 65535) {
                  return 'Enter a valid port (1-65535)';
                }
                return null;
              },
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text('Use TLS'),
              subtitle: const Text('mqtts:// — recommended for any real broker'),
              value: _useTls,
              onChanged: (value) => setState(() => _useTls = value),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: 'Username (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                labelText: 'Password (optional)',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('Save and reconnect'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () {
                _hostController.text = 'test.mosquitto.org';
                _portController.text = '1883';
                _usernameController.clear();
                _passwordController.clear();
                setState(() => _useTls = false);
              },
              child: const Text('Reset to development defaults'),
            ),
          ],
        ),
      ),
    );
  }
}
