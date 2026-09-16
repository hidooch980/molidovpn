import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';

class UpdateInfo {
  const UpdateInfo({required this.version, required this.url, required this.assetName, required this.size});

  final String version, url, assetName;

  /// 0 when unknown (found without the GitHub API).
  final int size;
}

/// In-app updates from this repo's latest GitHub Release.
class Updater {
  static const _repo = 'hidooch980/molidovpn';
  static const releasesPage = 'https://github.com/$_repo/releases/latest';

  /// Per-ABI APK (~50 MB) matching the running build; universal (~140 MB) only for other CPUs.
  static String get _assetName {
    if (Platform.isWindows) return 'MolidoVPN-windows-x64.zip';
    return switch (Abi.current()) {
      Abi.androidArm64 => 'MolidoVPN-android-arm64.apk',
      Abi.androidArm => 'MolidoVPN-android-armv7.apk',
      _ => 'MolidoVPN-android-universal.apk',
    };
  }

  HttpClient _client(String? proxy) {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
    return client;
  }

  static Future<String> installedVersion() async => (await PackageInfo.fromPlatform()).version;

  /// Returns the newer release, or null when already up to date.
  Future<UpdateInfo?> check({String? proxy}) async {
    final installed = await installedVersion();
    UpdateInfo? latest;
    try {
      latest = await _fromApi(installed, proxy, _mirrorApi);
    } catch (e) {
      AppLog.add('update: mirror failed ($e), trying the GitHub API');
      try {
        latest = await _fromApi(installed, proxy, 'https://api.github.com/repos/$_repo/releases/latest');
      } catch (e) {
        AppLog.add('update: GitHub API failed ($e), trying the releases page');
        latest = await _fromRedirect(proxy);
      }
    }
    if (latest == null) return null;
    final newer = isNewer(latest.version, installed);
    AppLog.add('update: installed $installed, latest ${latest.version}${newer ? ' → update available' : ''}');
    return newer ? latest : null;
  }

  /// Our Cloudflare worker: same JSON as the GitHub API, download links served through the worker.
  static const _mirrorApi = 'https://molido-sub.hidooch980.workers.dev/app/latest.json';

  Future<UpdateInfo?> _fromApi(String installed, String? proxy, String url) async {
    final client = _client(proxy);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers
        ..set(HttpHeaders.userAgentHeader, 'MobinVPN/$installed')
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 20));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final json = jsonDecode(body) as Map<String, dynamic>;
      final version = '${json['tag_name']}'.replaceFirst(RegExp('^v'), '');
      final asset = (json['assets'] as List).cast<Map<String, dynamic>>().where((a) => a['name'] == _assetName).firstOrNull;
      if (asset == null) return null;
      return UpdateInfo(
        version: version,
        url: asset['browser_download_url'] as String,
        assetName: _assetName,
        size: (asset['size'] as num).toInt(),
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Without the API (rate limited or blocked): /releases/latest redirects to /releases/tag/vX.Y.Z.
  Future<UpdateInfo?> _fromRedirect(String? proxy) async {
    final client = _client(proxy);
    try {
      final req = await client.getUrl(Uri.parse(releasesPage));
      req.followRedirects = false;
      final res = await req.close().timeout(const Duration(seconds: 20));
      await res.drain<void>();
      final location = res.headers.value(HttpHeaders.locationHeader) ?? '';
      final tag = RegExp(r'/tag/(v?[\d.]+)').firstMatch(location)?.group(1);
      if (tag == null) return null;
      return UpdateInfo(
        version: tag.replaceFirst(RegExp('^v'), ''),
        url: 'https://github.com/$_repo/releases/download/$tag/$_assetName',
        assetName: _assetName,
        size: 0,
      );
    } finally {
      client.close(force: true);
    }
  }

  static bool isNewer(String candidate, String installed) {
    List<int> parts(String v) => v.split('+').first.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final a = parts(candidate), b = parts(installed);
    for (var i = 0; i < a.length || i < b.length; i++) {
      final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  Future<File> download(UpdateInfo update, {String? proxy, required void Function(double progress) onProgress}) async {
    final file = File('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}${update.assetName}');
    final client = _client(proxy);
    AppLog.add('update: downloading ${update.url}${proxy != null ? ' via $proxy' : ''}');
    try {
      final res = await (await client.getUrl(Uri.parse(update.url))).close();
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final total = res.contentLength > 0 ? res.contentLength : update.size;
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in res.timeout(const Duration(seconds: 60))) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress(received / total);
        }
      } finally {
        await sink.close();
      }
      if (total > 0 && received != total) throw FileSystemException('download incomplete: $received of $total bytes');
      AppLog.add('update: downloaded $received bytes to ${file.path}');
      return file;
    } finally {
      client.close(force: true);
    }
  }

  /// Android: opens the system installer. Windows: a detached script swaps the files once this process exits,
  /// then relaunches the app — the caller must exit right after.
  Future<void> install(File file) async {
    if (Platform.isAndroid) {
      final result = await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
      AppLog.add('update: installer result ${result.type} ${result.message}');
      if (result.type != ResultType.done) throw Exception(result.message);
      return;
    }
    final exe = Platform.resolvedExecutable;
    final dir = File(exe).parent.path;
    final temp = file.parent.path;
    String q(String s) => "'${s.replaceAll("'", "''")}'";
    final script = File('$temp\\mobin_update.ps1');
    final log = '$temp\\mobin_update.log';
    // Extract to a staging folder first, then copy over the app. If the app folder is not writable
    // (e.g. Program Files) the script re-runs itself as administrator.
    final content = '''
param([switch]\$Elevated)
\$ErrorActionPreference = 'Stop'
Start-Transcript -Path ${q(log)} -Append | Out-Null
try {
  while (Get-Process -Id $pid -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 300 }
  Get-Process sing-box -ErrorAction SilentlyContinue | Where-Object { \$_.Path -like ${q('$dir\\*')} } | Stop-Process -Force
  Start-Sleep -Milliseconds 700
  \$stage = Join-Path ${q(temp)} 'mobin_update_stage'
  if (Test-Path \$stage) { Remove-Item \$stage -Recurse -Force }
  Expand-Archive -LiteralPath ${q(file.path)} -DestinationPath \$stage -Force
  try {
    Copy-Item -Path (Join-Path \$stage '*') -Destination ${q(dir)} -Recurse -Force
  } catch {
    if (-not \$Elevated) {
      Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',\$PSCommandPath,'-Elevated')
      exit
    }
    throw
  }
  Start-Process -FilePath ${q(exe)}
} catch {
  Write-Output "update failed: \$_"
  Start-Process ${q(releasesPage)}
  Start-Process -FilePath ${q(exe)}
}
Stop-Transcript | Out-Null
''';
    // UTF-8 with BOM so Windows PowerShell 5.1 reads non-English paths correctly.
    await script.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(content)]);
    AppLog.add('update: starting installer script ${script.path} (log: $log)');
    await Process.start(
      'powershell',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', script.path],
      mode: ProcessStartMode.detached,
    );
  }

  /// Fallback when in-app update fails: open the download page in the browser.
  static Future<void> openReleasesPage() async {
    try {
      if (Platform.isWindows) {
        await Process.start('explorer', [releasesPage], mode: ProcessStartMode.detached);
      } else if (Platform.isAndroid) {
        await const AndroidIntent(action: 'action_view', data: releasesPage).launch();
      }
    } catch (e) {
      AppLog.add('update: could not open releases page: $e');
    }
  }
}
