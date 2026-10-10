import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'android_engine.dart';
import 'server.dart';
import 'settings.dart';
import 'warp.dart';
import 'windows_engine.dart';

enum VpnState { disconnected, connecting, connected, disconnecting }

class TrafficStat {
  const TrafficStat({this.up = 0, this.down = 0});

  /// Bytes per second.
  final int up, down;
}

class PermissionDeniedError implements Exception {
  const PermissionDeniedError();
}

class AdminRequiredError implements Exception {
  const AdminRequiredError();
}

class EngineOptions {
  const EngineOptions({
    this.testUrl = 'https://www.gstatic.com/generate_204',
    this.timeout = const Duration(seconds: 8),
    this.proxyOnly = false,
    this.systemProxy = true,
    this.tunMode = false,
    this.killSwitch = false,
    this.localPort = 0,
    this.bypassIran = true,
    this.dns = '1.1.1.1',
    this.fragment = false,
    this.excludedApps = const [],
    this.warp,
    this.tunnelDns,
    this.tunMtu = 0,
    this.iranRuleSets = false,
    this.multiPath = false,
    this.dataSaver = false,
  });

  /// Data saver: QUIC (UDP 443) is rejected so browsers fall back to TCP through the tunnel.
  final bool dataSaver;

  /// Windows: the "proxy" outbound is a sing-box urltest group (main server, backups, WARP) instead of a selector.
  final bool multiPath;

  /// Route Iranian IPs/domains (geoip-ir / geosite-ir rule-sets) directly; only used together with [bypassIran].
  final bool iranRuleSets;

  /// TUN interface MTU; 0 = automatic (1340 on cellular / USB tethering, 1420 otherwise).
  final int tunMtu;

  final String testUrl;
  final Duration timeout;
  final bool proxyOnly, systemProxy, tunMode, killSwitch, bypassIran, fragment;
  final int localPort;
  final String dns;
  final List<String> excludedApps;

  /// Iranian gaming DNS (IPv4) for sing-box, queried directly; null = automatic (unchanged).
  final String? tunnelDns;

  /// When set, traffic leaves through Cloudflare WARP chained behind the server.
  final WarpAccount? warp;

  /// Pings measure the server itself, without the WARP hop.
  EngineOptions get forPing => EngineOptions(
        testUrl: testUrl,
        timeout: timeout,
        proxyOnly: proxyOnly,
        systemProxy: systemProxy,
        tunMode: tunMode,
        killSwitch: killSwitch,
        localPort: localPort,
        bypassIran: bypassIran,
        dns: dns,
        fragment: fragment,
        excludedApps: excludedApps,
        tunnelDns: tunnelDns,
        tunMtu: tunMtu,
        iranRuleSets: iranRuleSets,
        dataSaver: dataSaver,
        multiPath: multiPath,
      );

  /// The same options with multi-path off (free routes keep the plain outbound).
  EngineOptions get withoutMultiPath => EngineOptions(
        testUrl: testUrl,
        timeout: timeout,
        proxyOnly: proxyOnly,
        systemProxy: systemProxy,
        tunMode: tunMode,
        killSwitch: killSwitch,
        localPort: localPort,
        bypassIran: bypassIran,
        dns: dns,
        fragment: fragment,
        excludedApps: excludedApps,
        warp: warp,
        tunnelDns: tunnelDns,
        tunMtu: tunMtu,
        iranRuleSets: iranRuleSets,
        dataSaver: dataSaver,
      );

  /// Settings that change the generated core config.
  String get configKey => '$dns|$tunnelDns|$bypassIran|$iranRuleSets|$fragment|$multiPath|$dataSaver|${warp?.privateKey}';
}

/// Platform VPN core. Delays are measured from the user's own connection.
abstract class VpnEngine {
  static VpnEngine create(AppSettings settings) => Platform.isWindows ? WindowsEngine() : AndroidEngine();

  /// Emits when the tunnel stops on its own (killed, notification button...).
  Stream<VpnState> get states;
  Stream<TrafficStat> get traffic;

  /// Local HTTP proxy "host:port" while connected, for the app's own requests (Windows only).
  String? get httpProxy;

  bool supports(Server server);
  Future<void> init();

  /// Asks for the OS VPN permission up front (Android). Returns false when the user declines.
  Future<bool> requestPermission() async => true;

  /// While connected: true when traffic still passes through the tunnel.
  Future<bool> healthCheck(EngineOptions options);

  /// Real delay in ms for each server (same order), -1 when it failed.
  Future<List<int>> pingAll(List<Server> servers, EngineOptions options,
      {void Function(int done)? onProgress, bool Function()? isCancelled, void Function(int index, int delay)? onResult});

  /// Starts the tunnel and returns true only once traffic really passes through it.
  Future<bool> connect(Server server, EngineOptions options);
  Future<void> disconnect();
}

/// Runs [task] for 0..count-1 with at most [concurrency] in flight.
/// Order after a quick parallel probe: servers that answered (fastest first), then the unknown ones
/// (not probed, or probe stopped early = 0) in their original order, then the failed ones (-1).
/// Nothing is dropped: a failed quick probe only moves a server to the back.
List<T> quickProbeOrder<T>(List<T> items, Map<T, int> times) {
  final good = [for (final i in items) if ((times[i] ?? 0) > 0) i]..sort((a, b) => times[a]!.compareTo(times[b]!));
  return [
    ...good,
    for (final i in items) if ((times[i] ?? 0) == 0) i,
    for (final i in items) if ((times[i] ?? 0) < 0) i,
  ];
}

Future<List<int>> runPool(int count, int concurrency, Future<int> Function(int index) task,
    {void Function(int done)? onProgress}) async {
  final results = List<int>.filled(count, -1);
  var next = 0, done = 0;
  Future<void> worker() async {
    while (next < count) {
      final i = next++;
      try {
        results[i] = await task(i);
      } catch (_) {
        results[i] = -1;
      }
      onProgress?.call(++done);
    }
  }

  await Future.wait(List.generate(math.min(concurrency, count), (_) => worker()));
  return results;
}
