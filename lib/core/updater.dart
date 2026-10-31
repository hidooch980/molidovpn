import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.url,
    required this.assetName,
    required this.size,
    this.sha256,
    this.critical = false,
  });

  final String version, url, assetName;

  /// From the release metadata (GitHub `digest`); the download must match it when known.
  final String? sha256;

  /// Owner marked the release "[critical]": prompt at once instead of installing on exit/idle.
  final bool critical;

  /// 0 when unknown (found without the GitHub API).
  final int size;
}

/// In-app updates from this repo's latest GitHub Release.
class Updater {
  static const _repo = 'hidooch980/molidovpn';
  static const releasesPage = 'https://github.com/$_repo/releases/latest';

  /// Per-ABI APK (~50 MB) matching the running build; universal (~140 MB) only for other CPUs.
  static String get _assetName {
    // The installer, not the zip: it closes the app and every core (also elevated ones, and the AmneziaWG
    // service) before copying, so an update upgrades in place instead of failing on locked files.
    if (Platform.isWindows) return 'MolidoVPN-windows-setup.exe';
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
    // Static GitHub copies first (no Cloudflare request), the GitHub API, the Worker, then the page redirect.
    for (final url in sources) {
      try {
        latest = await _fromApi(installed, proxy, url);
        // A static copy is refreshed by a cron job every few minutes: when it says "nothing newer", ask
        // GitHub's redirect once (not the Worker) so a just-published release is not hidden behind it.
        if (url.contains('/vpn-sub') && (latest == null || !isNewer(latest.version, installed))) {
          final fresh = await _fromRedirect(proxy).catchError((_) => null);
          if (fresh != null && isNewer(fresh.version, installed)) {
            latest = await _fromApi(installed, proxy, sources[2]).catchError((_) => fresh) ?? fresh; // with sha256 when it can
          }
        }
        break;
      } catch (e) {
        AppLog.add('update: $url failed ($e)');
      }
    }
    latest ??= await _fromRedirect(proxy);
    if (latest == null) return null;
    final newer = isNewer(latest.version, installed);
    AppLog.add('update: installed $installed, latest ${latest.version}${newer ? ' → update available' : ''}');
    return newer ? latest : null;
  }

  /// Our Cloudflare worker: same JSON as the GitHub API, download links served through the worker.
  static const _mirrorApi = 'https://molido-sub.hidooch980.workers.dev/app/latest.json';

  static const sources = [
    'https://raw.githubusercontent.com/hidooch980/vpn-sub/live/latest.json',
    'https://cdn.jsdelivr.net/gh/hidooch980/vpn-sub@live/latest.json',
    'https://api.github.com/repos/$_repo/releases/latest',
    _mirrorApi,
  ];

  /// Release JSON (GitHub shape, or our mirrors' with `sha256`/`critical`) → the asset for this build.
  static UpdateInfo? parseRelease(Map<String, dynamic> json, String assetName) {
    final version = '${json['tag_name']}'.replaceFirst(RegExp('^v'), '');
    final asset = (json['assets'] as List).cast<Map<String, dynamic>>().where((a) => a['name'] == assetName).firstOrNull;
    if (asset == null) return null;
    final digest = '${asset['digest'] ?? ''}';
    var sha = '${asset['sha256'] ?? ''}'.toLowerCase();
    if (sha.isEmpty && digest.startsWith('sha256:')) sha = digest.substring(7).toLowerCase();
    return UpdateInfo(
      version: version,
      url: asset['browser_download_url'] as String,
      assetName: assetName,
      size: (asset['size'] as num?)?.toInt() ?? 0,
      sha256: RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) ? sha : null,
      critical: json['critical'] == true || '${json['body'] ?? ''}'.toLowerCase().contains('[critical]'),
    );
  }

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
      return parseRelease(jsonDecode(body) as Map<String, dynamic>, _assetName);
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
      final want = update.sha256;
      if (want != null) {
        final got = await sha256File(file);
        if (got != want) {
          await file.delete();
          throw FileSystemException('download damaged (sha256 $got, expected $want)');
        }
      }
      AppLog.add('update: downloaded $received bytes to ${file.path}');
      return file;
    } finally {
      client.close(force: true);
    }
  }

  /// Android: opens the system installer. Windows: a detached script swaps the files once this process exits,
  /// then relaunches the app — the caller must exit right after.
  static Future<String> sha256File(File file) async {
    final sink = Sha256().newHashSink();
    await for (final chunk in file.openRead()) {
      sink.add(chunk);
    }
    sink.close();
    return (await sink.hash()).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// [relaunch]: start the new version when setup is done (false when the user chose Exit).
  Future<void> install(File file, {bool relaunch = true}) async {
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
    if (file.path.toLowerCase().endsWith('.exe')) {
      // Silent in-place upgrade; the installer relaunches the app (/relaunch=1) when it is done.
      final setupLog = '$temp\\mobin_setup.log';
      final setupScript = '''
\$ErrorActionPreference = 'Stop'
Start-Transcript -Path ${q(log)} -Append | Out-Null
try {
  while (Get-Process -Id $pid -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 300 }
  \$p = Start-Process -FilePath ${q(file.path)} -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/relaunch=${relaunch ? 1 : 0}',${q('/LOG="$setupLog"')} -Wait -PassThru
  if (\$p.ExitCode -ne 0) { throw "setup exit code \$(\$p.ExitCode)" }
} catch {
  Write-Output "update failed: \$_"
  Start-Process ${q(releasesPage)}
  Start-Process -FilePath ${q(exe)}
}
Stop-Transcript | Out-Null
''';
      await script.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(setupScript)]);
      AppLog.add('update: running installer silently via ${script.path} (log: $log, $setupLog)');
      await _runDetached(script);
      return;
    }
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
    await _runDetached(script);
  }

  /// Runs [script] in PowerShell outside this process (it must survive our exit).
  Future<void> _runDetached(File script) async {
    // `Process.start(mode: detached)` is not enough on Windows: when this app runs inside a job
    // object (Windows Terminal, some launchers, MSIX) with "kill on close", the detached child dies
    // the instant this process exits, even though DETACHED_PROCESS was requested — the update script
    // never runs and the app just vanishes. A one-shot Scheduled Task is started by a separate OS
    // service, so it is never a member of this process's job and survives our exit unconditionally.
    final taskName = 'MolidoVPNUpdate_${DateTime.now().millisecondsSinceEpoch}';
    // schtasks.exe does not tokenize its own command line like every other Win32 program: passed as one
    // argv element (no shell involved), a `/tr` value containing spaces gets split back into separate
    // schtasks options ("Invalid argument/option - '-NoProfile'") even though it arrived as a single,
    // correctly quoted argument. schtasks only keeps it together when the value ALSO carries its own
    // literal wrapping double-quotes as characters — verified against the real binary.
    final command = '"powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "${script.path}""';
    final create = await Process.run('schtasks', [
      '/create', '/tn', taskName, '/tr', command, '/sc', 'once', '/st', _oneMinuteFromNow(), '/f',
    ]);
    if (create.exitCode == 0) {
      await Process.run('schtasks', ['/run', '/tn', taskName]);
      // Best-effort cleanup a bit later; the task has already fired by then.
      unawaited(Future.delayed(const Duration(minutes: 2), () => Process.run('schtasks', ['/delete', '/tn', taskName, '/f'])));
    } else {
      // Scheduled Tasks unavailable (locked-down policy): fall back to the direct detached spawn.
      AppLog.add('update: schtasks failed (${create.stderr}), falling back to Process.start');
      await Process.start(
        'powershell',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', script.path],
        mode: ProcessStartMode.detached,
      );
    }
  }

  /// "HH:mm" a minute from now, for `schtasks /st` — the task fires almost immediately in practice.
  static String _oneMinuteFromNow() {
    final t = DateTime.now().add(const Duration(minutes: 1));
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
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
