import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/config/ble_provisioning_config.dart';
import '../../core/models/wifi_network.dart';
import '../../providers/app_providers.dart';
import '../../services/ble_provisioning_service.dart';

enum _Stage {
  permission,
  deviceScan,
  connecting,
  welcome,
  scanning,
  selecting,
  sending,
  done,
}

class BleProvisioningScreen extends ConsumerStatefulWidget {
  const BleProvisioningScreen({super.key, this.title = 'Set up device'});

  final String title;

  @override
  ConsumerState<BleProvisioningScreen> createState() =>
      _BleProvisioningScreenState();
}

class _BleProvisioningScreenState extends ConsumerState<BleProvisioningScreen> {
  late final BleProvisioningService _service;
  _Stage _stage = _Stage.permission;
  List<ScanResult> _devices = [];
  List<WifiNetwork> _networks = [];
  int _rawDeviceCount = 0;
  bool _permissionsOk = false;
  int _sdkInt = 0;
  Timer? _scanTimeout;
  String? _selectedSsid;
  String? _deviceId;
  String? _statusDetail;
  String? _error;
  bool _obscurePassword = true;
  final TextEditingController _passwordController = TextEditingController();

  StreamSubscription? _scanResultsSub;
  StreamSubscription? _isScanningSub;
  StreamSubscription? _connectionSub;
  StreamSubscription? _linesSub;

  @override
  void initState() {
    super.initState();
    _service = BleProvisioningService();
    _scanResultsSub = _service.scanResults.listen(_onScanResults);
    _isScanningSub = _service.isScanning.listen(_onScanningChanged);
    _connectionSub = _service.connectionState.listen(_onConnectionState);
    _linesSub = _service.lines.listen(_onLine);
    _requestPermissionsAndStart();
  }

  void _onScanningChanged(bool scanning) {
    if (!mounted) return;
    if (!scanning && _stage == _Stage.deviceScan) {
      // The 30s scan window ended while we are still looking — restart it so
      // the device shows up whenever it starts advertising.
      _scheduleRescan();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _scanResultsSub?.cancel();
    _isScanningSub?.cancel();
    _connectionSub?.cancel();
    _linesSub?.cancel();
    _scanTimeout?.cancel();
    _service.dispose();
    super.dispose();
  }

  Future<void> _requestPermissionsAndStart() async {
    final granted = await _ensurePermissions();
    if (!mounted) return;
    if (!granted) {
      setState(() {
        _stage = _Stage.permission;
        _permissionsOk = false;
        _error = 'Bluetooth permission is required to set up a device.';
      });
      return;
    }
    setState(() {
      _stage = _Stage.deviceScan;
      _permissionsOk = true;
      _error = null;
    });
    await _startDeviceScan();
  }

  Future<bool> _ensurePermissions() async {
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      _sdkInt = info.version.sdkInt;
      if (info.version.sdkInt >= 31) {
        final scan = await Permission.bluetoothScan.request();
        final connect = await Permission.bluetoothConnect.request();
        return scan.isGranted && connect.isGranted;
      }
      final location = await Permission.locationWhenInUse.request();
      return location.isGranted;
    }
    if (Platform.isIOS) {
      final bluetooth = await Permission.bluetooth.request();
      return bluetooth.isGranted;
    }
    return true;
  }

  Future<void> _startDeviceScan() async {
    if (!_service.adapterIsOn) {
      await _service.turnOn();
    }
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
    try {
      await _service.scanForDevices();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Failed to start scan: $e');
    }
  }

  /// Keeps only ESP32-C3 provisioning devices (by advertised service UUID or
  /// name prefix) out of the unfiltered scan results.
  void _onScanResults(List<ScanResult> results) {
    if (!mounted) return;
    final target = Guid(BleProvisioningConfig.serviceUuid);
    setState(() {
      _rawDeviceCount = results.length;
      _devices = results.where((r) {
        final hasService = r.advertisementData.serviceUuids.any(
          (u) => u == target,
        );
        final name = r.device.platformName;
        return hasService || name.startsWith('ESP32C3');
      }).toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
    });
  }

  bool _rescanScheduled = false;

  void _scheduleRescan() {
    if (_rescanScheduled || _stage != _Stage.deviceScan) return;
    _rescanScheduled = true;
    Future.delayed(const Duration(milliseconds: 400), () {
      _rescanScheduled = false;
      if (mounted && _stage == _Stage.deviceScan && _devices.isEmpty) {
        _startDeviceScan();
      }
    });
  }

  void _onConnectionState(BleLinkState state) {
    if (!mounted) return;
    switch (state) {
      case BleLinkState.connecting:
        setState(() {
          _stage = _Stage.connecting;
          _error = null;
        });
      case BleLinkState.connected:
        setState(() {
          _stage = _Stage.welcome;
          _error = null;
        });
      case BleLinkState.error:
        setState(() {
          _stage = _Stage.deviceScan;
          // _connectTo() catches the actual exception and shows the specific
          // failure; this generic message is only a fallback so a real reason
          // is never hidden behind "out of range".
          _error ??= 'Could not connect. The device may be out of range.';
        });
        _startDeviceScan();
      case BleLinkState.disconnected:
        if (_stage == _Stage.welcome ||
            _stage == _Stage.scanning ||
            _stage == _Stage.selecting ||
            _stage == _Stage.sending) {
          setState(() {
            _stage = _Stage.deviceScan;
            _error = 'Device disconnected.';
          });
          _startDeviceScan();
        }
    }
  }

  void _onLine(String line) {
    debugPrint('[prov] line: $line');
    Map<String, dynamic> message;
    try {
      message = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (!mounted) return;
    switch (message['type']) {
      case 'hello':
        setState(() {
          _deviceId = message['device_id'] as String?;
          _statusDetail = null;
        });
      case 'status':
        _onStatus(message);
      case 'scan_result':
        final network = WifiNetwork.fromJson(message);
        setState(() {
          final index = _networks.indexWhere((n) => n.ssid == network.ssid);
          if (index >= 0) {
            _networks[index] = network;
          } else {
            _networks.add(network);
          }
          _networks.sort((a, b) => b.rssi.compareTo(a.rssi));
        });
      case 'scan_done':
        _scanTimeout?.cancel();
        setState(() => _stage = _Stage.selecting);
    }
  }

  void _onStatus(Map<String, dynamic> message) {
    final wifi = message['wifi'] as String?;
    final detail = message['detail'] as String?;
    setState(() {
      _statusDetail = detail;
      if (wifi == 'connected') {
        _stage = _Stage.done;
      } else if (wifi == 'scan_error' || wifi == 'error') {
        _stage = _Stage.welcome;
        _statusDetail = detail;
      }
    });
  }

  Future<void> _connectTo(BluetoothDevice device) async {
    await _service.stopScan();
    setState(() => _stage = _Stage.connecting);
    try {
      await _service.connect(device);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.deviceScan;
        _error = 'Failed to connect: $e';
      });
      _startDeviceScan();
    }
  }

  Future<void> _scanWifi() async {
    _scanTimeout?.cancel();
    setState(() {
      _stage = _Stage.scanning;
      _networks = [];
      _statusDetail = null;
    });
    debugPrint('[prov] requesting wifi scan');
    try {
      // Timeout so a stuck write surfaces instead of spinning forever.
      await _service
          .sendCommand('{"type":"scan"}')
          .timeout(const Duration(seconds: 5));
      debugPrint('[prov] scan request sent, waiting for device...');
      // If the device never answers, stop spinning and show an error.
      _scanTimeout = Timer(const Duration(seconds: 15), () {
        if (!mounted || _stage != _Stage.scanning) return;
        debugPrint('[prov] wifi scan timed out');
        setState(() {
          _stage = _Stage.welcome;
          _statusDetail =
              'Timed out waiting for Wi-Fi scan results. '
              'Check that the device is still connected.';
        });
      });
    } catch (e) {
      debugPrint('[prov] scan request error: $e');
      if (!mounted) return;
      setState(() {
        _stage = _Stage.welcome;
        _statusDetail = 'Failed to request scan: $e';
      });
    }
  }

  Future<void> _sendCredentials() async {
    final ssid = _selectedSsid;
    if (ssid == null) return;
    final command = jsonEncode({
      'type': 'connect',
      'ssid': ssid,
      'password': _passwordController.text,
    });
    setState(() {
      _stage = _Stage.sending;
      _statusDetail = null;
    });
    try {
      await _service.sendCommand(command);
      // This device now belongs to this app — make it visible in the list.
      final id = _deviceId;
      if (id != null) {
        unawaited(ref.read(myDevicesProvider.notifier).add(id));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.selecting;
        _statusDetail = 'Failed to send: $e';
      });
    }
  }

  Future<void> _finish() async {
    await _service.disconnect();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    return switch (_stage) {
      _Stage.permission => _PermissionView(
        error: _error,
        onRetry: _requestPermissionsAndStart,
      ),
      _Stage.deviceScan => _buildDeviceScan(),
      _Stage.connecting => const _CenteredProgress(label: 'Connecting...'),
      _Stage.welcome => _buildWelcome(),
      _Stage.scanning => const _CenteredProgress(label: 'Scanning Wi-Fi...'),
      _Stage.selecting => _buildWifiList(),
      _Stage.sending => const _CenteredProgress(
        label: 'Sending credentials...',
      ),
      _Stage.done => _DoneView(deviceId: _deviceId, onDone: _finish),
    };
  }

  Widget _buildDeviceScan() {
    final scanning = FlutterBluePlus.isScanningNow;
    final adapterOn = _service.adapterIsOn;
    return Column(
      children: [
        if (_error != null) _ErrorBanner(message: _error!),
        if (!adapterOn)
          _AdapterOffBanner(
            sdkInt: _sdkInt,
            onTurnOn: () async {
              try {
                await _service.turnOn();
              } catch (_) {}
              if (mounted) setState(() {});
            },
            onOpenSettings: () => openAppSettings(),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '$_rawDeviceCount BLE device(s) nearby, '
                  '${_devices.length} ESP32-C3 in setup mode.\nTap one to connect.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              IconButton(
                tooltip: 'Rescan',
                onPressed: scanning ? null : _startDeviceScan,
                icon: scanning
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (BleProvisioningConfig.showDebugInfo)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Debug: sdk=$_sdkInt adapter=${_service.adapterState.name} '
              'permissions=$_permissionsOk scanning=$scanning raw=$_rawDeviceCount',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(fontFamily: 'monospace'),
            ),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: _devices.isEmpty
              ? _EmptyHint(
                  icon: Icons.bluetooth_searching,
                  text: scanning
                      ? 'Scanning for ESP32-C3 devices...\n'
                            'Make sure the device is blinking and waiting for setup.'
                      : BleProvisioningConfig.showDebugInfo
                      ? 'No ESP32-C3 devices found.\n'
                            '$_rawDeviceCount other BLE device(s) are visible, '
                            'so scanning works.\n'
                            'Is the device blinking and in setup mode?'
                      : 'No ESP32-C3 devices found.\n'
                            'Is the device blinking and in setup mode?',
                )
              : ListView.separated(
                  itemCount: _devices.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final result = _devices[index];
                    final name = result.device.platformName;
                    return ListTile(
                      leading: const Icon(Icons.memory),
                      title: Text(
                        name.isNotEmpty ? name : result.device.remoteId.str,
                        style: name.isNotEmpty
                            ? null
                            : const TextStyle(fontFamily: 'monospace'),
                      ),
                      subtitle: Text('RSSI ${result.rssi} dBm'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _connectTo(result.device),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildWelcome() {
    final deviceId = _deviceId;
    final ready = deviceId != null;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Icon(Icons.check_circle, size: 56, color: Colors.green.shade400),
          const SizedBox(height: 16),
          Text(
            ready ? 'Connected to $deviceId' : 'Connected',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (!ready) ...[
            const SizedBox(height: 16),
            const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ],
          if (_statusDetail != null) ...[
            const SizedBox(height: 8),
            Text(
              _statusDetail!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
          const Spacer(),
          FilledButton.icon(
            onPressed: ready ? _scanWifi : null,
            icon: const Icon(Icons.wifi),
            label: const Text('Scan for Wi-Fi networks'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _finish, child: const Text('Cancel')),
        ],
      ),
    );
  }

  Widget _buildWifiList() {
    if (_networks.isEmpty) {
      return const _EmptyHint(
        icon: Icons.wifi_off,
        text: 'No networks found.\nGo back and try again.',
      );
    }
    final selected = _networks
        .where((n) => n.ssid == _selectedSsid)
        .firstOrNull;
    return Column(
      children: [
        if (_statusDetail != null) _ErrorBanner(message: _statusDetail!),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Choose your Wi-Fi network',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: _networks.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final network = _networks[index];
              final isSelected = network.ssid == _selectedSsid;
              return ListTile(
                leading: Icon(isSelected ? Icons.wifi : Icons.wifi_outlined),
                title: Text(
                  network.ssid.isEmpty ? '(hidden network)' : network.ssid,
                ),
                subtitle: Text('${network.authLabel} · ${network.rssi} dBm'),
                trailing: isSelected
                    ? const Icon(Icons.check_circle, color: Colors.green)
                    : null,
                onTap: () => setState(() {
                  _selectedSsid = network.ssid;
                  _statusDetail = null;
                }),
              );
            },
          ),
        ),
        if (selected != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    hintText: selected.isOpen
                        ? '(open network)'
                        : 'Wi-Fi password',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility
                            : Icons.visibility_off,
                      ),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _sendCredentials,
                  icon: const Icon(Icons.link),
                  label: const Text('Connect to network'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _PermissionView extends StatelessWidget {
  const _PermissionView({required this.error, required this.onRetry});

  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.bluetooth_disabled, size: 56),
          const SizedBox(height: 16),
          Text(
            error ?? 'Bluetooth permission is required.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.perm_device_information),
            label: const Text('Grant permission'),
          ),
        ],
      ),
    );
  }
}

class _DoneView extends StatelessWidget {
  const _DoneView({required this.deviceId, required this.onDone});

  final String? deviceId;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          const Icon(Icons.verified, size: 64, color: Colors.green),
          const SizedBox(height: 16),
          Text(
            'Device is online!',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            '${deviceId ?? 'The device'} is now connected to your Wi-Fi '
            'and should appear in the device list shortly.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: onDone,
            icon: const Icon(Icons.check),
            label: const Text('Done'),
          ),
        ],
      ),
    );
  }
}

class _CenteredProgress extends StatelessWidget {
  const _CenteredProgress({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(label, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.errorContainer,
      padding: const EdgeInsets.all(12),
      child: Text(
        message,
        style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
      ),
    );
  }
}

class _AdapterOffBanner extends StatelessWidget {
  const _AdapterOffBanner({
    required this.sdkInt,
    required this.onTurnOn,
    required this.onOpenSettings,
  });

  final int sdkInt;
  final VoidCallback onTurnOn;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.tertiaryContainer,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Bluetooth is off or not accessible.',
            style: TextStyle(
              color: theme.colorScheme.onTertiaryContainer,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            sdkInt >= 31
                ? 'Make sure Bluetooth is on and the app has the '
                      '"Nearby devices" permission (Settings → Apps → ESP32C3 Remote '
                      '→ Permissions).'
                : 'Make sure Bluetooth is on, the app has Location permission, '
                      'and Location services are enabled.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onTertiaryContainer,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton(
                onPressed: onTurnOn,
                child: const Text('Turn on Bluetooth'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: onOpenSettings,
                child: const Text('Open app settings'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
