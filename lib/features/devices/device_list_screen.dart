import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/device.dart';
import '../../providers/app_providers.dart';
import '../../services/mqtt_service.dart';
import '../provisioning/ble_provisioning_screen.dart';
import '../settings/broker_settings_screen.dart';

enum _ManageAction { rename, changeWifi, remove, fallback }

class DeviceListScreen extends ConsumerStatefulWidget {
  const DeviceListScreen({super.key});

  @override
  ConsumerState<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends ConsumerState<DeviceListScreen> {
  static const _backgroundDisconnectDelay = Duration(seconds: 30);

  Timer? _backgroundTimer;
  Timer? _lastSeenTicker;
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onShow: _onForeground,
      onHide: _onBackground,
    );
    _lastSeenTicker = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    _backgroundTimer?.cancel();
    _lastSeenTicker?.cancel();
    super.dispose();
  }

  void _onForeground() {
    _backgroundTimer?.cancel();
    ref.read(mqttServiceProvider).ensureConnected();
  }

  void _onBackground() {
    _backgroundTimer?.cancel();
    _backgroundTimer = Timer(_backgroundDisconnectDelay, () {
      unawaited(ref.read(mqttServiceProvider).disconnect());
    });
  }

  Future<void> _rescan() => ref.read(devicesProvider.notifier).rescan();

  Future<void> _editNickname(String deviceId, String current) async {
    final nickname = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(deviceId: deviceId, initial: current),
    );
    if (nickname != null && mounted) {
      await ref.read(nicknamesProvider.notifier).rename(deviceId, nickname);
    }
  }

  void _showDeviceDetails(Device device, String? nickname) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => _DeviceDetailSheet(device: device, nickname: nickname),
    );
  }

  Future<void> _changeWifi(Device device) async {
    ref.read(devicesProvider.notifier).reprovision(device.id);
    if (!mounted) return;
    // The device starts advertising again; reuse the provisioning flow so the
    // user can pair and enter new credentials.
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const BleProvisioningScreen(title: 'Change Wi-Fi'),
      ),
    );
  }

  Future<void> _confirmRemove(Device device, String? nickname) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Remove ${nickname ?? device.id}?'),
        content: const Text(
          'This clears the device\'s stored Wi-Fi credentials and returns it '
          'to BLE setup mode. The device will blink and advertise until it is '
          're-provisioned.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref.read(devicesProvider.notifier).removeDevice(device.id);
    }
  }

  Future<void> _editFallback(Device device) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _FallbackSettingsDialog(deviceId: device.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final linkState = ref.watch(connectionStatusProvider);
    final devices = ref.watch(devicesProvider);
    final broker = ref.watch(brokerConfigProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('ESP32C3 Remote'),
        actions: [
          _ConnectionBadge(state: linkState),
          IconButton(
            tooltip: 'Rescan',
            icon:
                linkState == MqttLinkState.reconnecting ||
                    linkState == MqttLinkState.connecting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _rescan,
          ),
          IconButton(
            tooltip: 'Set up a new device (BLE)',
            icon: const Icon(Icons.bluetooth_searching),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const BleProvisioningScreen(),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Broker settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const BrokerSettingsScreen(),
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _rescan,
        child: switch (devices.isEmpty) {
          true => ListView(
            children: [
              _EmptyState(linkState: linkState, brokerHost: broker.host),
            ],
          ),
          false => _buildDeviceList(devices, linkState),
        },
      ),
    );
  }

  Widget _buildDeviceList(
    Map<String, Device> devices,
    MqttLinkState linkState,
  ) {
    final nicknames = ref.watch(nicknamesProvider);
    final entries = devices.values.toList()
      ..sort((a, b) {
        if (a.isOnline != b.isOnline) return a.isOnline ? -1 : 1;
        final nameA = nicknames[a.id] ?? a.id;
        final nameB = nicknames[b.id] ?? b.id;
        return nameA.compareTo(nameB);
      });

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final device = entries[index];
        return _DeviceTile(
          device: device,
          nickname: nicknames[device.id],
          enabled:
              device.isControllable && linkState == MqttLinkState.connected,
          onTap: () => _showDeviceDetails(device, nicknames[device.id]),
          onToggle: (_) =>
              ref.read(devicesProvider.notifier).toggleLed(device.id),
          onRename: () => _editNickname(device.id, nicknames[device.id] ?? ''),
          onReprovision: () => _changeWifi(device),
          onRemove: () => _confirmRemove(device, nicknames[device.id]),
          onSetFallback: () => _editFallback(device),
        );
      },
    );
  }
}

String formatLastSeen(DateTime? lastSeen) {
  if (lastSeen == null) return 'never seen';
  final elapsed = DateTime.now().difference(lastSeen);
  if (elapsed.inSeconds < 10) return 'seen just now';
  if (elapsed.inMinutes < 1) return 'seen ${elapsed.inSeconds}s ago';
  if (elapsed.inHours < 1) return 'seen ${elapsed.inMinutes}m ago';
  if (elapsed.inDays < 1) return 'seen ${elapsed.inHours}h ago';
  return 'seen ${elapsed.inDays}d ago';
}

String formatUptime(int? uptimeSeconds) {
  if (uptimeSeconds == null || uptimeSeconds < 0) return 'unknown';
  final days = uptimeSeconds ~/ 86400;
  final hours = (uptimeSeconds % 86400) ~/ 3600;
  final minutes = (uptimeSeconds % 3600) ~/ 60;
  if (days > 0) return '${days}d ${hours}h';
  if (hours > 0) return '${hours}h ${minutes}m';
  if (minutes > 0) return '${minutes}m';
  return '${uptimeSeconds}s';
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.deviceId, required this.initial});

  final String deviceId;
  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Rename ${widget.deviceId}'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Nickname',
          hintText: 'e.g. Living Room LED',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge({required this.state});

  final MqttLinkState state;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (state) {
      MqttLinkState.connected => (Colors.green, 'Connected'),
      MqttLinkState.connecting => (Colors.orange, 'Connecting'),
      MqttLinkState.reconnecting => (Colors.orange, 'Reconnecting'),
      MqttLinkState.disconnected => (Colors.red, 'Offline'),
      MqttLinkState.idle => (Colors.grey, 'Idle'),
    };

    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Chip(
        avatar: CircleAvatar(backgroundColor: color, radius: 5),
        label: Text(label, style: Theme.of(context).textTheme.labelMedium),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.linkState, required this.brokerHost});

  final MqttLinkState linkState;
  final String brokerHost;

  @override
  Widget build(BuildContext context) {
    final message = switch (linkState) {
      MqttLinkState.connected =>
        'No devices set up yet.\nTap the Bluetooth icon to connect to an '
            'ESP32-C3 and set up its Wi-Fi.',
      MqttLinkState.connecting ||
      MqttLinkState.reconnecting => 'Connecting to $brokerHost...',
      MqttLinkState.disconnected || MqttLinkState.idle =>
        'Not connected to the MQTT broker.\nPull down to retry.',
    };

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const SizedBox(height: 96),
          if (linkState == MqttLinkState.connecting ||
              linkState == MqttLinkState.reconnecting)
            const CircularProgressIndicator()
          else
            Icon(
              Icons.sensors_off_rounded,
              size: 56,
              color: Theme.of(context).colorScheme.outline,
            ),
          const SizedBox(height: 24),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.enabled,
    required this.onTap,
    required this.onToggle,
    required this.onRename,
    required this.onReprovision,
    required this.onRemove,
    required this.onSetFallback,
    this.nickname,
  });

  final Device device;
  final String? nickname;
  final bool enabled;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRename;
  final VoidCallback onReprovision;
  final VoidCallback onRemove;
  final VoidCallback onSetFallback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = nickname ?? device.id;

    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: device.isOnline
            ? Colors.green.shade400
            : theme.colorScheme.outlineVariant,
        child: Icon(
          Icons.lightbulb,
          color: device.ledOn
              ? Colors.amber
              : theme.colorScheme.surfaceContainerHighest,
        ),
      ),
      title: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontFamily: nickname == null ? 'monospace' : null,
        ),
      ),
      subtitle: Text(_subtitle, style: theme.textTheme.bodySmall),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(device.ledOn ? 'ON' : 'OFF', style: theme.textTheme.labelMedium),
          Switch(value: device.ledOn, onChanged: enabled ? onToggle : null),
          PopupMenuButton<_ManageAction>(
            tooltip: 'Manage',
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (action) {
              switch (action) {
                case _ManageAction.rename:
                  onRename();
                case _ManageAction.changeWifi:
                  onReprovision();
                case _ManageAction.remove:
                  onRemove();
                case _ManageAction.fallback:
                  onSetFallback();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: _ManageAction.rename, child: Text('Rename')),
              PopupMenuItem(
                value: _ManageAction.changeWifi,
                child: Text('Change Wi-Fi'),
              ),
              PopupMenuItem(
                value: _ManageAction.remove,
                child: Text('Remove device'),
              ),
              PopupMenuItem(
                value: _ManageAction.fallback,
                child: Text('Fallback settings'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String get _subtitle {
    final parts = <String>[
      device.isOnline ? 'online' : 'offline',
      ?device.ssid,
      if (device.rssi case final rssi?) '$rssi dBm',
      formatLastSeen(device.lastSeen),
    ];
    return parts.join(' · ');
  }
}

class _DeviceDetailSheet extends StatelessWidget {
  const _DeviceDetailSheet({required this.device, this.nickname});

  final Device device;
  final String? nickname;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(nickname ?? device.id, style: theme.textTheme.titleLarge),
            Text(
              device.id,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Divider(height: 24),
            _DetailRow(
              label: 'Status',
              value: device.isOnline ? 'Online' : 'Offline',
            ),
            _DetailRow(
              label: 'Last seen',
              value: formatLastSeen(device.lastSeen),
            ),
            if (device.ssid case final ssid?)
              _DetailRow(label: 'Wi-Fi', value: ssid),
            if (device.rssi case final rssi?)
              _DetailRow(label: 'Signal', value: '$rssi dBm'),
            if (device.uptimeSeconds case final uptime?)
              _DetailRow(label: 'Uptime', value: formatUptime(uptime)),
            if (device.temperatureC case final temp?)
              _DetailRow(
                label: 'Device temperature',
                value: '${temp.toStringAsFixed(1)} °C',
              ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _FallbackSettingsDialog extends ConsumerStatefulWidget {
  const _FallbackSettingsDialog({required this.deviceId});

  final String deviceId;

  @override
  ConsumerState<_FallbackSettingsDialog> createState() =>
      _FallbackSettingsDialogState();
}

class _FallbackSettingsDialogState
    extends ConsumerState<_FallbackSettingsDialog> {
  late bool _enabled;
  late int _timeoutMinutes;

  @override
  void initState() {
    super.initState();
    // Preload the values last sent to this device (defaults match the
    // firmware: enabled, 3 minutes).
    final saved = ref
        .read(settingsRepositoryProvider)
        .loadFallbackSettings()[widget.deviceId];
    _enabled = saved?.enabled ?? true;
    _timeoutMinutes = saved?.timeoutMinutes ?? 3;
  }

  void _save() {
    ref
        .read(devicesProvider.notifier)
        .setFallback(
          widget.deviceId,
          enabled: _enabled,
          timeoutMinutes: _timeoutMinutes,
        );
    ref
        .read(settingsRepositoryProvider)
        .saveFallbackSettings(widget.deviceId, _enabled, _timeoutMinutes);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Fallback to BLE setup'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled'),
            subtitle: const Text(
              'Enter BLE setup if Wi-Fi cannot be reached within the timeout',
            ),
            value: _enabled,
            onChanged: (value) => setState(() => _enabled = value),
          ),
          const SizedBox(height: 8),
          Text('Timeout: $_timeoutMinutes min'),
          Slider(
            value: _timeoutMinutes.toDouble(),
            min: 1,
            max: 5,
            divisions: 4,
            label: '$_timeoutMinutes min',
            onChanged: _enabled
                ? (value) => setState(() => _timeoutMinutes = value.round())
                : null,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
