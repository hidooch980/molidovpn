import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'app_log.dart';
import 'engine.dart';
import 'server.dart';
import 'settings.dart';
import 'singbox_outbound.dart';

/// A sing-box (1.12) binary driven as a child process: config generation, validation, parallel delay tests
/// through the Clash API, and a local mixed (HTTP+SOCKS) proxy. Shared by the Windows and Android engines.
class SingboxCore {
  SingboxCore(
      {required this.binary, required this.workDir, required this.label, this.detectInterface = true, this.fallback});

  final String binary;
  final Directory workDir;
  final String label;

  /// Outbound for links sing-box cannot dial itself (Windows: XHTTP through the local Xray bridge), or null.
  final Json? Function(String uri)? fallback;

  /// `auto_detect_interface` needs netlink access, which Android apps do not have.
  final bool detectInterface;

  final _outbounds = <String, Json?>{};
  Process? process;
  HttpClient? _trafficClient;

  bool get binaryExists => File(binary).existsSync();

  // WARP routes depend on the (later registered) identity, so they are not cached.
  Json? outbound(Server s) =>
      s.uri.startsWith('warp://')
          ? parseOutbound(s.uri)
          : _outbounds.putIfAbsent(s.uri, () => parseOutbound(s.uri) ?? fallback?.call(s.uri));

  static Future<int> freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  /// Local DNS resolves proxy server domains (required by sing-box 1.12 when servers use domains).
  static Json _baseConfig(String logLevel) => {
        'log': {'level': logLevel},
        'dns': {
          'servers': [
            {'type': 'local', 'tag': 'local'},
          ],
        },
      };

  Future<File> _writeConfig(String name, Json config) =>
      File('${workDir.path}${Platform.pathSeparator}$name.json').writeAsString(jsonEncode(config));

  // detachedWithStdio: no console window pops up on Windows.
  Future<Process> _spawn(List<String> args) =>
      Process.start(binary, args, workingDirectory: workDir.path, mode: ProcessStartMode.detachedWithStdio);

  void _logStderr(Process proc, String what) {
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final l = line.toLowerCase();
      if (l.contains('error') || l.contains('fatal') || l.contains('warn')) AppLog.add('sing-box[$label/$what]: $line');
    }, onError: (_) {});
  }

  /// QUIC outbounds: sing-box supports no custom TLS (fragment / record_fragment) over QUIC.
  static const _quicTypes = {'hysteria2', 'tuic'};

  /// Wait between ClientHello segments when sing-box cannot measure it (Windows without admin); the
  /// sing-box default of 500 ms per segment makes every handshake seconds slower.
  static const fragmentFallbackDelay = '100ms';

  /// Master switch for sing-box multiplex (sing-mux). Off: sing-mux is a sing-box-only wire format and
  /// Xray-core servers (most public VLESS/VMess/Trojan nodes) do not accept it, so it would break them.
  /// Turn on only for servers known to run a sing-box inbound with multiplex enabled.
  static const muxEnabled = false;

  /// sing-box `multiplex` block used when [muxEnabled] (or a caller) asks for it.
  static const muxOptions = <String, dynamic>{
    'enabled': true,
    'protocol': 'h2mux',
    'max_connections': 4,
    'min_streams': 4,
    'padding': true,
  };

  /// VLESS/VMess/Trojan over plain TCP, WebSocket or gRPC. Never Reality-Vision (flow), Hysteria2/TUIC
  /// (QUIC), XHTTP (local Xray bridge, a socks outbound) or other transports.
  static bool muxCompatible(Json outbound) {
    if (!const {'vless', 'vmess', 'trojan'}.contains(outbound['type'])) return false;
    final flow = outbound['flow'];
    if (flow is String && flow.isNotEmpty) return false;
    final transport = outbound['transport'];
    final kind = transport is Map ? transport['type'] : null;
    return kind == null || kind == 'ws' || kind == 'grpc';
  }

  static Json tagged(Json outbound, String tag, EngineOptions o, {bool mux = muxEnabled}) {
    final result = {...outbound, 'tag': tag};
    final tls = outbound['tls'];
    if (o.fragment &&
        tls is Map &&
        tls['enabled'] == true &&
        tls['reality'] == null &&
        !_quicTypes.contains(outbound['type'])) {
      // record_fragment: several TLS records; fragment (sing-box 1.12+): ClientHello split over TCP segments.
      result['tls'] = {
        ...tls,
        'record_fragment': true,
        'fragment': true,
        'fragment_fallback_delay': fragmentFallbackDelay,
      };
    }
    if (mux && outbound['multiplex'] == null && muxCompatible(outbound)) result['multiplex'] = {...muxOptions};
    return result;
  }

  // Rotating file names: a background ping round never overwrites the config of another running one.
  int _checkSeq = 0, _pingSeq = 0;

  Future<bool> _configValid(List<Json> outbounds) async {
    final file = await _writeConfig('check${_checkSeq++ % 8}', {
      ..._baseConfig('error'),
      'outbounds': outbounds,
      'route': {'default_domain_resolver': 'local'},
    });
    final p = await _spawn(['check', '-c', file.path]);
    final output = await Future.wait([p.stdout.transform(utf8.decoder).join(), p.stderr.transform(utf8.decoder).join()]);
    final text = output.join().toLowerCase();
    return !text.contains('fatal') && !text.contains('error');
  }

  /// One bad outbound makes sing-box reject the whole config, so bisect to drop only the bad ones.
  Future<List<int>> _validSubset(List<int> indices, List<Json> outbounds) async {
    if (indices.isEmpty || await _configValid([for (final i in indices) outbounds[i]])) return indices;
    if (indices.length == 1) return const [];
    final mid = indices.length ~/ 2;
    return [
      ...await _validSubset(indices.sublist(0, mid), outbounds),
      ...await _validSubset(indices.sublist(mid), outbounds),
    ];
  }

  /// [stop]: checked before every try, so a cancelled or over-budget connect stops waiting at once.
  Future<bool> waitApi(int api, {bool Function()? stop}) async {
    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 500);
    try {
      for (var i = 0; i < 60; i++) {
        if (stop?.call() ?? false) return false;
        try {
          final res = await (await client.getUrl(Uri.parse('http://127.0.0.1:$api/version'))).close();
          await res.drain<void>();
          if (res.statusCode == 200) return true;
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<int> _delay(HttpClient client, int api, String tag, EngineOptions o) async {
    try {
      final uri = Uri.parse('http://127.0.0.1:$api/proxies/$tag/delay')
          .replace(queryParameters: {'timeout': '${o.timeout.inMilliseconds}', 'url': o.testUrl});
      final res = await (await client.getUrl(uri)).close().timeout(o.timeout + const Duration(seconds: 3));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return -1;
      final delay = (jsonDecode(body) as Map)['delay'];
      return delay is int && delay > 0 ? delay : -1;
    } catch (_) {
      return -1;
    }
  }

  /// Tests many servers at once in one throwaway sing-box process.
  Future<List<int>> pingAll(List<Server> servers, EngineOptions options,
      {void Function(int done)? onProgress,
      bool Function()? isCancelled,
      void Function(int index, int delay)? onResult,
      bool Function()? abort,
      int concurrency = 16}) async {
    final results = List<int>.filled(servers.length, -1);
    final outbounds = [
      for (var i = 0; i < servers.length; i++) tagged(outbound(servers[i]) ?? const {}, 'p$i', options),
    ];
    final usable = [for (var i = 0; i < servers.length; i++) if (outbound(servers[i]) != null) i];
    final valid = await _validSubset(usable, outbounds);
    final skipped = servers.length - valid.length;
    AppLog.add('$label: ping ${servers.length} servers, ${valid.length} valid configs');
    onProgress?.call(skipped);
    if (valid.isEmpty) return results;

    final api = await freePort();
    final file = await _writeConfig('ping${_pingSeq++ % 4}', {
      ..._baseConfig('error'),
      'outbounds': [for (final i in valid) outbounds[i], {'type': 'direct', 'tag': 'direct'}],
      'route': {'default_domain_resolver': 'local'},
      'experimental': {'clash_api': {'external_controller': '127.0.0.1:$api'}},
    });
    final proc = await _spawn(['run', '-c', file.path]);
    unawaited(proc.stdout.drain<void>());
    _logStderr(proc, 'ping');
    final client = HttpClient();
    // [abort] (user cancel): end the throwaway core so in-flight delay tests fail at once instead of timing out.
    final aborter = abort == null
        ? null
        : Timer.periodic(const Duration(milliseconds: 200), (t) {
            if (!abort()) return;
            t.cancel();
            Process.killPid(proc.pid);
            client.close(force: true);
          });
    try {
      if (!await waitApi(api)) {
        AppLog.add('$label: ping core API did not start');
        return results;
      }
      final delays = await runPool(valid.length, concurrency, (k) async {
        if (isCancelled?.call() ?? false) return -1;
        final delay = await _delay(client, api, 'p${valid[k]}', options);
        onResult?.call(valid[k], delay);
        return delay;
      }, onProgress: (n) => onProgress?.call(skipped + n));
      for (var k = 0; k < valid.length; k++) {
        results[valid[k]] = delays[k];
      }
      return results;
    } finally {
      aborter?.cancel();
      client.close(force: true);
      Process.killPid(proc.pid);
    }
  }

  /// Real HTTP probe of many servers: one throwaway sing-box with a local mixed inbound per server (routed to
  /// that server only); each probe fetches [AppSettings.defaultTestUrl] through its inbound and only an HTTP 204
  /// counts. Returns the time in ms per server (same order), -1 when it failed or the config is invalid.
  /// [stopOnFirstGood]: the first HTTP 204 ends every other probe at once; those report 0 (= unknown).
  Future<List<int>> probeAll(List<Server> servers, EngineOptions options,
      {void Function(int done)? onProgress,
      bool Function()? isCancelled,
      int concurrency = 12,
      bool stopOnFirstGood = false}) async {
    final results = List<int>.filled(servers.length, -1);
    final outbounds = [
      for (var i = 0; i < servers.length; i++) tagged(outbound(servers[i]) ?? const {}, 'p$i', options),
    ];
    final usable = [for (var i = 0; i < servers.length; i++) if (outbound(servers[i]) != null) i];
    final valid = await _validSubset(usable, outbounds);
    final skipped = servers.length - valid.length;
    AppLog.add('$label: probe ${servers.length} servers, ${valid.length} valid configs');
    onProgress?.call(skipped);
    if (valid.isEmpty) return results;

    final api = await freePort();
    final ports = <int>[for (var k = 0; k < valid.length; k++) await freePort()];
    final file = await _writeConfig('probe', {
      ..._baseConfig('error'),
      'inbounds': [
        for (var k = 0; k < valid.length; k++)
          {'type': 'mixed', 'tag': 'in$k', 'listen': '127.0.0.1', 'listen_port': ports[k]},
      ],
      'outbounds': [for (final i in valid) outbounds[i], {'type': 'direct', 'tag': 'direct'}],
      'route': {
        'rules': [
          for (var k = 0; k < valid.length; k++) {'inbound': ['in$k'], 'outbound': 'p${valid[k]}'},
        ],
        'final': 'direct',
        if (detectInterface) 'auto_detect_interface': true,
        'default_domain_resolver': 'local',
      },
      'experimental': {'clash_api': {'external_controller': '127.0.0.1:$api'}},
    });
    final proc = await _spawn(['run', '-c', file.path]);
    unawaited(proc.stdout.drain<void>());
    _logStderr(proc, 'probe');
    try {
      if (!await waitApi(api)) {
        AppLog.add('$label: probe core API did not start');
        return results;
      }
      final inFlight = <HttpClient>{};
      var gotGood = false;
      final times = await runPool(valid.length, concurrency, (k) async {
        if (stopOnFirstGood && gotGood) return 0;
        if (isCancelled?.call() ?? false) return -1;
        final client = HttpClient()
          ..findProxy = ((_) => 'PROXY 127.0.0.1:${ports[k]}')
          ..connectionTimeout = options.timeout;
        inFlight.add(client);
        final watch = Stopwatch()..start();
        try {
          final res = await (await client.getUrl(Uri.parse(AppSettings.defaultTestUrl))).close().timeout(options.timeout);
          await res.drain<void>();
          if (res.statusCode != 204) return -1;
          if (stopOnFirstGood && gotGood) return 0;
          gotGood = true;
          if (stopOnFirstGood) {
            for (final other in inFlight) {
              if (!identical(other, client)) other.close(force: true);
            }
          }
          return math.max(1, watch.elapsedMilliseconds);
        } catch (_) {
          return stopOnFirstGood && gotGood ? 0 : -1;
        } finally {
          inFlight.remove(client);
          client.close(force: true);
        }
      }, onProgress: (n) => onProgress?.call(skipped + n));
      for (var k = 0; k < valid.length; k++) {
        results[valid[k]] = times[k];
      }
      return results;
    } finally {
      Process.killPid(proc.pid);
    }
  }

  static const iranRuleSetUrls = {
    'geoip-ir': 'https://raw.githubusercontent.com/Chocolate4U/Iran-sing-box-rules/rule-set/geoip-ir.srs',
    'geosite-ir': 'https://raw.githubusercontent.com/Chocolate4U/Iran-sing-box-rules/rule-set/geosite-ir.srs',
  };

  File _ruleSetFile(String tag) => File('${workDir.path}${Platform.pathSeparator}$tag.srs');

  bool _hasRuleSet(String tag) {
    try {
      final f = _ruleSetFile(tag);
      return f.existsSync() && f.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  /// Both Iranian rule-sets are on disk (downloaded earlier); configs only reference them when present,
  /// so a failed download never stops sing-box from starting.
  bool get iranRuleSetsReady => iranRuleSetUrls.keys.every(_hasRuleSet);

  bool _ruleSetsBusy = false;

  /// Downloads missing or day-old Iranian rule-sets in the background (update interval 1 day). Never throws.
  Future<void> updateIranRuleSets({String? proxy}) async {
    if (_ruleSetsBusy) return;
    _ruleSetsBusy = true;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
    try {
      for (final e in iranRuleSetUrls.entries) {
        final file = _ruleSetFile(e.key);
        try {
          if (file.existsSync() &&
              file.lengthSync() > 0 &&
              DateTime.now().difference(file.lastModifiedSync()) < const Duration(days: 1)) {
            continue;
          }
          final res = await (await client.getUrl(Uri.parse(e.value))).close().timeout(const Duration(seconds: 20));
          if (res.statusCode != 200) {
            await res.drain<void>();
            continue;
          }
          final bytes = await res.fold<List<int>>(<int>[], (b, d) => b..addAll(d)).timeout(const Duration(seconds: 60));
          if (bytes.length < 16) continue;
          final tmp = File('${file.path}.tmp');
          await tmp.writeAsBytes(bytes, flush: true);
          await tmp.rename(file.path);
          AppLog.add('$label: rule-set ${e.key} updated');
        } catch (err) {
          AppLog.add('$label: rule-set ${e.key} not updated ($err)');
        }
      }
    } finally {
      client.close(force: true);
      _ruleSetsBusy = false;
    }
  }

  /// The selected Iranian gaming DNS as a sing-box 1.12 server tagged "remote"; null = automatic.
  /// It only answers inside Iran, so it connects directly: no detour (sing-box 1.12 rejects a detour
  /// to an empty direct outbound).
  static Json? dnsServer(EngineOptions o) {
    final value = o.tunnelDns;
    return value == null ? null : {'type': 'udp', 'tag': 'remote', 'server': value};
  }

  bool _useIranRuleSets(EngineOptions o) => o.bypassIran && o.iranRuleSets && iranRuleSetsReady;

  /// Config for a live connection: local mixed proxy on [port], optional TUN (Windows), optional WARP chain.
  /// [directProcesses]: executables whose own traffic must bypass the tunnel (local Psiphon/Tor, avoids a loop).
  /// TUN without a gaming DNS: proxied domains get fake IPs (no DNS round trip through the server).
  /// Gaming DNS keeps its direct UDP server; proxy servers are still resolved by "local" (default_domain_resolver).
  static bool useFakeIp(EngineOptions o, {required bool tun}) => tun && o.tunnelDns == null;

  Json connectConfig(Json outbound, int port, int api, EngineOptions o,
          {bool tun = false,
          int mtu = 1420,
          List<String> directProcesses = const [],
          List<Json> standby = const [],
          Json? warpMember,
          List<Json> extraOutbounds = const []}) =>
      {
        ..._baseConfig('warn'),
        'dns': {
          'servers': [
            {'type': 'local', 'tag': 'local'},
            if (dnsServer(o) case final remote?) remote
            else if (tun) {'type': 'https', 'tag': 'remote', 'server': '1.1.1.1', 'detour': 'proxy'},
            if (useFakeIp(o, tun: tun))
              {'type': 'fakeip', 'tag': 'fakeip', 'inet4_range': '198.18.0.0/15', 'inet6_range': 'fc00::/18'},
          ],
          if (useFakeIp(o, tun: tun))
            'rules': [
              // Direct (Iranian) domains need their real address.
              if (o.bypassIran) {'domain_suffix': ['ir'], 'server': 'local'},
              if (_useIranRuleSets(o)) {'rule_set': ['geosite-ir'], 'server': 'local'},
              {'query_type': ['A', 'AAAA'], 'server': 'fakeip'},
            ],
          'final': tun || o.tunnelDns != null ? 'remote' : 'local',
          'strategy': 'prefer_ipv4',
        },
        'inbounds': [
          {'type': 'mixed', 'tag': 'in', 'listen': '127.0.0.1', 'listen_port': port},
          if (tun)
            {
              'type': 'tun',
              'tag': 'tun',
              'interface_name': 'MobinVPN',
              'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
              'mtu': mtu,
              'auto_route': true,
              'strict_route': o.killSwitch,
              'stack': 'mixed',
            },
        ],
        'outbounds': [
          if (o.multiPath) ...[
            // Multi-path: sing-box keeps testing every member and uses the fastest working one.
            {
              'type': 'urltest',
              'tag': 'proxy',
              'outbounds': [
                for (var i = 0; i <= standby.length; i++) 'proxy-$i',
                if (warpMember != null) multiPathWarpTag,
              ],
              'url': AppSettings.defaultTestUrl,
              // 15 s: a dead member is noticed about twice as fast; tolerance keeps it from flapping.
              'interval': multiPathInterval,
              'tolerance': 100,
              'idle_timeout': '30m',
              'interrupt_exist_connections': true,
            },
            tagged(outbound, 'proxy-0', o),
            for (final (i, backup) in standby.indexed) tagged(backup, 'proxy-${i + 1}', o),
            if (warpMember != null) {...warpMember, 'tag': multiPathWarpTag},
          ] else if (standby.isEmpty)
            tagged(outbound, 'proxy', o)
          else ...[
            // Anti-freeze: "proxy" is a selector over the main server and pre-tested backups;
            // the app switches it through the Clash API without restarting the core.
            {
              'type': 'selector',
              'tag': 'proxy',
              'outbounds': [for (var i = 0; i <= standby.length; i++) 'proxy-$i'],
              'default': 'proxy-0',
              'interrupt_exist_connections': true,
            },
            tagged(outbound, 'proxy-0', o),
            for (final (i, backup) in standby.indexed) tagged(backup, 'proxy-${i + 1}', o),
          ],
          {'type': 'direct', 'tag': 'direct'},
          if (o.warp case final warp?) warp.singBoxOutbound('warp', 'proxy'),
          ...extraOutbounds,
        ],
        'route': {
          'rules': [
            {'action': 'sniff'},
            if (directProcesses.isNotEmpty) {'process_name': directProcesses, 'outbound': 'direct'},
            if (tun) {'protocol': 'dns', 'action': 'hijack-dns'},
            {'ip_is_private': true, 'outbound': 'direct'},
            if (o.bypassIran) {'domain_suffix': ['ir'], 'outbound': 'direct'},
            if (_useIranRuleSets(o)) {'rule_set': iranRuleSetUrls.keys.toList(), 'outbound': 'direct'},
            // Data saver: reject QUIC so browsers fall back to TCP (after the direct rules, so local/Iranian QUIC stays).
            if (o.dataSaver) {'network': ['udp'], 'port': [443], 'action': 'reject'},
          ],
          if (_useIranRuleSets(o))
            'rule_set': [
              for (final tag in iranRuleSetUrls.keys)
                {'type': 'local', 'tag': tag, 'format': 'binary', 'path': _ruleSetFile(tag).path},
            ],
          'final': o.warp != null ? 'warp' : 'proxy',
          if (detectInterface) 'auto_detect_interface': true,
          'default_domain_resolver': 'local',
        },
        'experimental': {
          'clash_api': {'external_controller': '127.0.0.1:$api'},
          // Keeps the fake IP mapping (and DNS cache) across restarts of the core.
          if (useFakeIp(o, tun: tun)) 'cache_file': {'enabled': true, 'store_fakeip': true},
        },
      };

  /// DNS-only mode (Windows TUN, games): no proxy at all. Every connection leaves directly; only DNS queries
  /// are hijacked and answered by the Iranian gaming DNS [dns] (queried directly, no detour).
  Json dnsOnlyConfig(String dns, int api, {int mtu = 1420}) => {
        'log': {'level': 'warn'},
        'dns': {
          'servers': [
            {'type': 'udp', 'tag': 'gaming', 'server': dns},
            {'type': 'local', 'tag': 'local'},
          ],
          'final': 'gaming',
          'strategy': 'prefer_ipv4',
        },
        'inbounds': [
          {
            'type': 'tun',
            'tag': 'tun',
            'interface_name': 'MobinVPN',
            'address': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
            'mtu': mtu,
            'auto_route': true,
            // Windows sends DNS to every adapter's server (router/LAN routes skip the TUN); strict_route
            // blocks those so queries really reach the gaming DNS.
            'strict_route': true,
            'stack': 'mixed',
          },
        ],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
        'route': {
          'rules': [
            {'action': 'sniff'},
            {'protocol': 'dns', 'action': 'hijack-dns'},
            {'port': 53, 'action': 'hijack-dns'},
          ],
          'final': 'direct',
          // Direct traffic must bind to the physical adapter, otherwise it loops back into the TUN.
          'auto_detect_interface': true,
          'default_domain_resolver': 'local',
        },
        'experimental': {
          'clash_api': {'external_controller': '127.0.0.1:$api'},
        },
      };

  /// Helper relay: a local mixed (HTTP+SOCKS) proxy on [port] whose traffic all leaves through [outbound]
  /// (without tag). Used as Psiphon's WARP upstream and to register WARP through a V2Ray server.
  Json relayConfig(Json outbound, int port, int api) => {
        ..._baseConfig('warn'),
        'inbounds': [
          {'type': 'mixed', 'tag': 'in', 'listen': '127.0.0.1', 'listen_port': port},
        ],
        'outbounds': [
          {...outbound, 'tag': 'relay'},
          {'type': 'direct', 'tag': 'direct'},
        ],
        'route': {
          'final': 'relay',
          if (detectInterface) 'auto_detect_interface': true,
          'default_domain_resolver': 'local',
        },
        'experimental': {
          'clash_api': {'external_controller': '127.0.0.1:$api'},
        },
      };

  Future<Process> start(Json config) async {
    await stop();
    final file = await _writeConfig('active', config);
    final proc = await _spawn(['run', '-c', file.path]);
    process = proc;
    _logStderr(proc, 'core');
    return proc;
  }

  /// Test interval of the multi-path urltest group.
  static const multiPathInterval = '15s';

  /// Tag of the direct WARP member of the multi-path urltest group.
  static const multiPathWarpTag = 'proxy-warp';

  /// Member currently used by the group [group] (Clash API "now"), or null when unknown.
  Future<String?> currentMember(int api, {String group = 'proxy'}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final res = await (await client.getUrl(Uri.parse('http://127.0.0.1:$api/proxies/$group')))
          .close()
          .timeout(const Duration(seconds: 3));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return null;
      final now = (jsonDecode(body) as Map)['now'];
      return now is String && now.isNotEmpty ? now : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Switches the "proxy" selector to [tag] (e.g. "proxy-1") without restarting the core.
  Future<bool> selectOutbound(int api, String tag) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.putUrl(Uri.parse('http://127.0.0.1:$api/proxies/proxy'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'name': tag}));
      final res = await req.close().timeout(const Duration(seconds: 3));
      await res.drain<void>();
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// [stop] is polled every 200 ms while a request is in flight: when it turns true the check fails at once.
  Future<bool> verifyThroughProxy(int port, String testUrl,
      {int attempts = 2, Duration timeout = const Duration(seconds: 10), bool Function()? stop}) async {
    final client = HttpClient()
      ..findProxy = ((_) => 'PROXY 127.0.0.1:$port')
      ..connectionTimeout = timeout < const Duration(seconds: 8) ? timeout : const Duration(seconds: 8);
    final aborted = Completer<bool>();
    final watcher = stop == null
        ? null
        : Timer.periodic(const Duration(milliseconds: 200), (_) {
            if (!aborted.isCompleted && stop()) aborted.complete(false);
          });
    Future<bool> request() async {
      try {
        final res = await (await client.getUrl(Uri.parse(testUrl))).close().timeout(timeout);
        await res.drain<void>().timeout(timeout);
        return res.statusCode >= 200 && res.statusCode < 400;
      } catch (_) {
        return false;
      }
    }

    try {
      for (var attempt = 0; attempt < attempts; attempt++) {
        if (aborted.isCompleted || (stop?.call() ?? false)) return false;
        if (await Future.any([request(), aborted.future])) return true;
      }
      return false;
    } finally {
      watcher?.cancel();
      client.close(force: true);
    }
  }

  Future<void> streamTraffic(int api, StreamController<TrafficStat> sink) async {
    final client = HttpClient();
    _trafficClient = client;
    try {
      final res = await (await client.getUrl(Uri.parse('http://127.0.0.1:$api/traffic'))).close();
      await for (final line in res.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;
        final m = jsonDecode(line) as Map;
        sink.add(TrafficStat(up: (m['up'] as num).toInt(), down: (m['down'] as num).toInt()));
      }
    } catch (_) {}
  }

  Future<void> stop() async {
    final proc = process;
    process = null;
    _trafficClient?.close(force: true);
    _trafficClient = null;
    if (proc != null) Process.killPid(proc.pid);
  }
}
