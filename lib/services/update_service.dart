import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class UpdateInfo {
  const UpdateInfo({required this.version, required this.downloadUrl});

  final String version;
  final String downloadUrl;
}

class UpdateService {
  static const String repoOwner = 'GLinBoy';
  static const String repoName = 'esp32c3-remote-app';

  static const MethodChannel _installChannel =
      MethodChannel('com.glinboy.esp32c3_remote_app/install');

  Future<UpdateInfo?> checkForUpdate() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final response = await http.get(
        Uri.parse(
          'https://api.github.com/repos/$repoOwner/$repoName/releases',
        ),
        headers: const {'Accept': 'application/vnd.github+json'},
      );

      if (response.statusCode != 200) {
        debugPrint('Update check failed: HTTP ${response.statusCode}');
        return null;
      }

      final releases = jsonDecode(response.body) as List<dynamic>;
      UpdateInfo? best;
      for (final entry in releases) {
        if (entry is! Map<String, dynamic>) continue;
        if (entry['draft'] == true) continue;

        final tag = entry['tag_name'] as String?;
        if (tag == null || tag.isEmpty) continue;
        final version = tag.startsWith('v') ? tag.substring(1) : tag;

        if (!_isNewerVersion(version, currentVersion)) continue;

        final apkUrl = _apkUrl(entry);
        if (apkUrl == null) continue;

        if (best == null || _isNewerVersion(version, best.version)) {
          best = UpdateInfo(version: version, downloadUrl: apkUrl);
        }
      }
      return best;
    } catch (error) {
      debugPrint('Update check failed: $error');
      return null;
    }
  }

  Future<File?> downloadUpdate(String url) async {
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        debugPrint('Update download failed: HTTP ${response.statusCode}');
        return null;
      }

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/app-update.apk');
      await file.writeAsBytes(response.bodyBytes, flush: true);
      return file;
    } catch (error) {
      debugPrint('Update download failed: $error');
      return null;
    }
  }

  Future<bool> installApk(File apkFile) async {
    if (!Platform.isAndroid) return false;

    if (!await Permission.requestInstallPackages.request().isGranted) {
      debugPrint('Install permission denied');
      return false;
    }

    try {
      await _installChannel.invokeMethod<void>('installApk', {
        'path': apkFile.path,
      });
      return true;
    } catch (error) {
      debugPrint('Install failed: $error');
      return false;
    }
  }

  String? _apkUrl(Map<String, dynamic> release) {
    final assets = release['assets'];
    if (assets is! List) return null;
    for (final asset in assets) {
      if (asset is! Map) continue;
      final name = asset['name'];
      final url = asset['browser_download_url'];
      if (name is String && url is String && name.endsWith('.apk')) {
        return url;
      }
    }
    return null;
  }

  bool _isNewerVersion(String latest, String current) =>
      _compareVersions(latest, current) > 0;
}

int _compareVersions(String a, String b) {
  final parsedA = _parseVersion(a);
  final parsedB = _parseVersion(b);

  for (var i = 0; i < 3; i++) {
    final diff = parsedA.numbers[i].compareTo(parsedB.numbers[i]);
    if (diff != 0) return diff;
  }

  final preA = parsedA.pre;
  final preB = parsedB.pre;
  if (preA == null && preB == null) return 0;
  if (preA == null) return 1;
  if (preB == null) return -1;

  final length = preA.length < preB.length ? preA.length : preB.length;
  for (var i = 0; i < length; i++) {
    final x = preA[i];
    final y = preB[i];
    final xNumber = int.tryParse(x);
    final yNumber = int.tryParse(y);
    final int diff;
    if (xNumber != null && yNumber != null) {
      diff = xNumber.compareTo(yNumber);
    } else if (xNumber != null) {
      diff = -1;
    } else if (yNumber != null) {
      diff = 1;
    } else {
      diff = x.compareTo(y);
    }
    if (diff != 0) return diff;
  }
  return preA.length.compareTo(preB.length);
}

({List<int> numbers, List<String>? pre}) _parseVersion(String version) {
  final withoutBuild = version.split('+').first;
  final dash = withoutBuild.indexOf('-');
  final core = dash == -1 ? withoutBuild : withoutBuild.substring(0, dash);
  final pre = dash == -1 ? null : withoutBuild.substring(dash + 1).split('.');
  final parts = core.split('.');
  final numbers = List<int>.generate(3, (i) {
    if (i >= parts.length) return 0;
    return int.tryParse(parts[i]) ?? 0;
  });
  return (numbers: numbers, pre: pre);
}
