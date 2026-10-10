import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'amnezia.dart';
import 'app_log.dart';
import 'cf_clean_ip.dart';
import 'engine.dart';
import 'free_routes.dart';
import 'network_info.dart';
import 'reality_sni.dart';
import 'server.dart';
import 'singbox_core.dart';
import 'singbox_outbound.dart';
import 'warp.dart';
import 'win_free_routes.dart';
import 'win_system_proxy.dart';
import 'xray_bridge.dart';

const _proxyOwnedKey = 'win_proxy_owned';

/// Windows: bundled sing-box.exe — local proxy + Windows system proxy, or full TUN VPN as administrator.
class WindowsEngine implements VpnEngine {
  final _states = StreamController<VpnState>.broadcast();
  final _traffic = StreamController<TrafficStat>.broadcast();
  late SingboxCore _core;
  late WinFreeRoutes _free;

  /// Local Xray-core for XHTTP servers (sing-box 1.12 has no XHTTP transport).
  late XrayBridge _xray;

  /// Second sing-box process: local SOCKS → WARP, upstream of "Psiphon + WARP".
  late SingboxCore _warpHelper;

  /// WARP endpoint of the last working WARP connection ("host:port"); chains and multi-path dial it.
  String _warpEndpoint = WarpAccount.endpoints.first;

  static const _chainWarpTag = 'chain-warp', _chainPsiphonTag = 'chain-psiphon';
  int? _proxyPort;

  /// Status line while Psiphon / Tor is starting (set by the controller).
  void Function(String phase)? onPhase;

  /// Total time Tor may use (set by the controller for automatic mode); null = the full bridge ladder.
  Duration? torBudget;

  /// User-facing reason of the last failed Psiphon/Tor start, or null.
  String? get freeRouteError => _free.lastError;

  /// Set by the controller so a slow Psiphon/Tor start can be cancelled.
  bool Function() isCancelled = () => false;

  /// Hard end of the next direct / fast-path attempt (set by the controller, null = no budget). V2Ray/WARP
  /// attempts stop at it (core start and tunnel check included); Psiphon, Tor and chains ignore it.
  DateTime? deadline;

  /// A tunnel check slower than this fails a budgeted attempt (a 13 s response is not a usable server).
  static const budgetedCheck = Duration(seconds: 5);

  static bool get isAdmin {
    try {
      final isUserAnAdmin = DynamicLibrary.open('shell32.dll').lookupFunction<Int32 Function(), int Function()>('IsUserAnAdmin');
      return isUserAnAdmin() != 0;
    } catch (_) {
      return false;
    }
  }

  /// Starts a UAC-elevated copy of the app; the caller exits afterwards.
  static Future<void> relaunchAsAdmin() => Process.start(
        'powershell',
        ['-NoProfile', '-WindowStyle', 'Hidden', '-Command', "Start-Process -FilePath '${Platform.resolvedExecutable.replaceAll("'", "''")}' -Verb RunAs"],
        mode: ProcessStartMode.detached,
      );

  @override
  Stream<VpnState> get states => _states.stream;

  @override
  Stream<TrafficStat> get traffic => _traffic.stream;

  @override
  String? get httpProxy => _proxyPort == null ? null : '127.0.0.1:$_proxyPort';

  @override
  bool supports(Server server) =>
      server.uri.startsWith('warp://') ||
      FreeRoutes.isFree(server) ||
      WinFreeRoutes.isChain(server) ||
      _core.outbound(server) != null;

  /// Starts the WARP helper proxy and returns its port once traffic passes, else null.
  Future<int?> _startWarpHelper(EngineOptions options) async {
    final warp = parseOutbound('warp://$_warpEndpoint');
    if (warp == null) return null;
    onPhase?.call('راه‌اندازی WARP برای Psiphon…');
    final port = await SingboxCore.freePort();
    final api = await SingboxCore.freePort();
    await _warpHelper.start(_warpHelper.relayConfig(warp, port, api));
    if (await _warpHelper.waitApi(api) &&
        await _warpHelper.verifyThroughProxy(port, options.testUrl, attempts: 1)) {
      return port;
    }
    AppLog.add('windows: WARP helper for Psiphon did not pass traffic ($_warpEndpoint)');
    await _warpHelper.stop();
    return null;
  }

  /// WARP registration when api.cloudflareclient.com is blocked on this network: a temporary relay core
  /// forwards the registration through each of up to 3 [candidates] (V2Ray servers) until one succeeds.
  Future<WarpAccount?> registerWarpVia(List<Server> candidates) async {
    for (final s in candidates.take(3)) {
      if (isCancelled()) break;
      final o = _core.outbound(s);
      if (o == null) continue;
      final port = await SingboxCore.freePort();
      final api = await SingboxCore.freePort();
      try {
        await _warpHelper.start(_warpHelper.relayConfig(CleanIp.apply(o), port, api));
        if (!await _warpHelper.waitApi(api, stop: isCancelled)) continue;
        final account = await WarpAccount.register(proxy: '127.0.0.1:$port').timeout(const Duration(seconds: 25));
        AppLog.add('warp: registered through ${s.displayName}');
        return account;
      } catch (e) {
        AppLog.add('warp: registration through ${s.displayName} failed ($e)');
      } finally {
        await _warpHelper.stop();
      }
    }
    return null;
  }

  @override
  Future<bool> requestPermission() async => true;

  /// Pre-tested backup servers for the next [connect] (set by the controller); switched to by [failover].
  List<Server> standby = const [];

  /// False while a specific country is chosen: the multi-path group must not fail over to WARP.
  bool allowWarpMember = true;
  List<Server> _activeStandby = const [];
  int _activeIndex = 0;
  int? _api;

  /// Quick check (one request, 4 s) so a frozen tunnel is noticed within a few seconds.
  @override
  Future<bool> healthCheck(EngineOptions options) async {
    if (_dnsOnly) return _core.process != null && await _systemLookupOk();
    if (_awgActive) return await _cfTrace(const Duration(seconds: 4)) != null;
    final port = _proxyPort;
    return port != null &&
        _core.process != null &&
        await _core.verifyThroughProxy(port, options.testUrl, attempts: 1, timeout: const Duration(seconds: 4));
  }

  bool _multiPath = false, _plainRetry = false;
  Map<String, String> _memberNames = const {};

  /// Multi-path: display name of the group member sing-box currently uses, or null (off / unknown).
  Future<String?> activeMember() async {
    final api = _api;
    if (!_multiPath || api == null || _core.process == null) return null;
    final tag = await _core.currentMember(api);
    return tag == null ? null : (_memberNames[tag] ?? tag);
  }

  /// Moves the running core to the next backup server; returns it, or null when none is left.
  /// Multi-path groups pick their member themselves (a urltest cannot be switched through the API).
  Future<Server?> failover() async {
    final api = _api;
    if (_multiPath || api == null || _core.process == null || _activeIndex >= _activeStandby.length) return null;
    final next = _activeIndex + 1;
    if (!await _core.selectOutbound(api, 'proxy-$next')) return null;
    _activeIndex = next;
    final server = _activeStandby[next - 1];
    AppLog.add('windows: failover to backup ${server.displayName}');
    return server;
  }

  @override
  Future<void> init() async {
    final base = await getApplicationSupportDirectory();
    _xray = XrayBridge(
      binary: '${File(Platform.resolvedExecutable).parent.path}\\xray\\xray.exe',
      workDir: Directory('${base.path}\\core\\xray')..createSync(recursive: true),
    );
    await _xray.cleanupStale();
    _core = SingboxCore(
      binary: '${File(Platform.resolvedExecutable).parent.path}\\sing-box.exe',
      workDir: Directory('${base.path}\\core')..createSync(recursive: true),
      label: 'windows',
      fallback: _xray.socksOutbound,
    );
    _warpHelper = SingboxCore(
      binary: '${File(Platform.resolvedExecutable).parent.path}\\sing-box.exe',
      workDir: Directory('${base.path}\\core\\warp-helper')..createSync(recursive: true),
      label: 'warp-helper',
    );
    _free = WinFreeRoutes(
      appDir: File(Platform.resolvedExecutable).parent.path,
      dataDir: Directory('${base.path}\\free')..createSync(recursive: true),
    );
    await _free.cleanupStale();
    _awgDir = Directory('${base.path}\\awg')..createSync(recursive: true);
    // A previous run may have been killed while the AmneziaWG tunnel service was installed.
    if ((await SharedPreferences.getInstance()).getBool(_awgActiveKey) ?? false) await _awgUninstall();
    unawaited(RealitySni.load());
    unawaited(_core.updateIranRuleSets());
    await _releaseProxy(); // a previous run may have been killed while connected
    if (!_core.binaryExists) throw StateError('sing-box.exe کنار برنامه پیدا نشد');
  }

  @override
  Future<List<int>> pingAll(List<Server> servers, EngineOptions options,
          {void Function(int done)? onProgress, bool Function()? isCancelled, void Function(int index, int delay)? onResult}) async {
    await _xrayFor(servers);
    return _core.pingAll(servers, options.forPing,
        onProgress: onProgress, isCancelled: isCancelled, onResult: onResult, abort: this.isCancelled);
  }

  /// Starts (or extends) the Xray bridge for the XHTTP servers among [servers].
  Future<void> _xrayFor(Iterable<Server> servers) async {
    final uris = [for (final s in servers) if (isXhttpLink(s.uri) && _core.outbound(s) != null) s.uri];
    if (uris.isNotEmpty) await _xray.ensure(uris);
  }

  /// Failed real connections per server uri (this session), for [evasive] retries.
  final _failures = <String, int>{};

  static const _fingerprints = ['firefox', 'safari', 'randomized'];

  /// SNI used by the running Reality retry attempt; servers whose SNI round already ran this session.
  String? _sniOverride;
  final _sniRetried = <String>{};

  /// Retries a failing Reality server once with each of up to 3 remote SNIs; remembers the one that works.
  Future<bool> _retryRealitySni(Server server, EngineOptions options, Map<String, dynamic> realityBase) async {
    for (final sni in await RealitySni.candidates(realityBase)) {
      if (isCancelled()) break;
      AppLog.add('windows: ${server.displayName} reality retry with another SNI');
      _sniOverride = sni;
      try {
        if (await connect(server, options)) {
          await RealitySni.remember(realityBase, sni);
          return true;
        }
      } finally {
        _sniOverride = null;
      }
    }
    return false;
  }

  /// Copy of a TCP-TLS outbound (vless/vmess/trojan) with the uTLS fingerprint rotated by [failures]
  /// (firefox → safari → randomized) and, from the second failure, WebSocket early data when not set.
  static Map<String, dynamic> evasive(Map<String, dynamic> outbound, int failures) {
    if (failures <= 0 || !const {'vless', 'vmess', 'trojan'}.contains(outbound['type'])) return outbound;
    final result = {...outbound};
    final tls = outbound['tls'];
    if (tls is Map && tls['enabled'] == true) {
      result['tls'] = {
        ...Map<String, dynamic>.from(tls),
        'utls': {'enabled': true, 'fingerprint': _fingerprints[(failures - 1) % _fingerprints.length]},
      };
    }
    final transport = outbound['transport'];
    if (failures >= 2 && transport is Map && transport['type'] == 'ws' && transport['max_early_data'] == null) {
      result['transport'] = {
        ...Map<String, dynamic>.from(transport),
        'max_early_data': 2048,
        'early_data_header_name': 'Sec-WebSocket-Protocol',
      };
    }
    return result;
  }

  /// "Test servers from my internet": real HTTP 204 probes, 12 at a time (no WARP hop).
  Future<List<int>> probeAll(List<Server> servers, EngineOptions options,
          {void Function(int done)? onProgress,
          bool Function()? isCancelled,
          int concurrency = 12,
          bool stopOnFirstGood = false}) async {
    await _xrayFor(servers);
    return _core.probeAll(servers, options.forPing,
        onProgress: onProgress, isCancelled: isCancelled, concurrency: concurrency, stopOnFirstGood: stopOnFirstGood);
  }

  /// Background re-ping while idle: few parallel tests so the PC and UI stay responsive.
  Future<List<int>> prewarm(List<Server> servers, EngineOptions options, {bool Function()? isCancelled}) async {
    await _xrayFor(servers);
    return _core.pingAll(servers, options.forPing, isCancelled: isCancelled, concurrency: 4);
  }

  @override
  Future<bool> connect(Server server, EngineOptions options) async {
    if (options.tunMode && !isAdmin) throw const AdminRequiredError();
    await disconnect();
    final free = FreeRoutes.isFree(server);
    final chain = WinFreeRoutes.isChain(server);
    final deadlineAt = free || chain ? null : deadline;
    bool stopped() => isCancelled() || (deadlineAt != null && DateTime.now().isAfter(deadlineAt));
    Map<String, dynamic>? outbound;
    var extraOutbounds = const <Map<String, dynamic>>[];
    if (free) {
      // Smart chain: "Psiphon + WARP" first starts a local WARP proxy as Psiphon's upstream.
      String? upstream;
      if (server.uri == WinFreeRoutes.psiphonOverWarp.uri) {
        final helper = await _startWarpHelper(options);
        if (helper == null) return false;
        upstream = 'socks5://127.0.0.1:$helper';
      }
      // Psiphon / Tor run locally; sing-box just forwards to their SOCKS port.
      final socks = await _free.start(FreeRoutes.routeOf(server),
          isCancelled: isCancelled, onPhase: onPhase, upstreamProxy: upstream, torBudget: torBudget);
      if (socks == null) {
        await _free.stop();
        await _warpHelper.stop();
        return false;
      }
      outbound = {'type': 'socks', 'server': '127.0.0.1', 'server_port': socks, 'version': '5'};
      onPhase?.call('راه‌اندازی تونل ${server.displayName}…');
    } else if (WinFreeRoutes.isPsiphonChain(server)) {
      // V2Ray over Psiphon: the V2Ray server is dialed through Psiphon's local SOCKS port (exit = V2Ray server).
      final inner = _core.outbound(WinFreeRoutes.innerOf(server));
      if (inner == null) return false;
      final socks = await _free.start('psiphon', isCancelled: isCancelled, onPhase: onPhase);
      if (socks == null) {
        await _free.stop();
        return false;
      }
      onPhase?.call('اتصال ${WinFreeRoutes.innerOf(server).displayName} از روی Psiphon…');
      outbound = {...inner, 'detour': _chainPsiphonTag};
      extraOutbounds = [
        {'type': 'socks', 'tag': _chainPsiphonTag, 'server': '127.0.0.1', 'server_port': socks, 'version': '5'},
      ];
    } else if (chain) {
      // Smart chain: the V2Ray server is dialed inside WARP (its IP is never contacted from this network).
      final inner = _core.outbound(WinFreeRoutes.innerOf(server));
      final warp = parseOutbound('warp://$_warpEndpoint');
      if (inner == null || warp == null) return false;
      outbound = {...inner, 'detour': _chainWarpTag};
      extraOutbounds = [
        {...warp, 'tag': _chainWarpTag},
      ];
    } else {
      outbound = _core.outbound(server);
    }
    if (outbound == null) return false;
    await _xrayFor([if (chain) WinFreeRoutes.innerOf(server) else server, ...standby]);
    // Reality: a remembered working SNI, or the SNI being tried in a retry.
    final realityBase = !free && RealitySni.isReality(outbound) ? outbound : null;
    String? sniUsed;
    if (realityBase != null) {
      sniUsed = _sniOverride ?? RealitySni.remembered(realityBase);
      if (sniUsed != null) outbound = RealitySni.withSni(outbound, sniUsed);
    }
    // Anti-DPI retry: after failures, rotate the uTLS fingerprint and (ws) add early data.
    final failures = free ? 0 : (_failures[server.uri] ?? 0);
    if (failures > 0) outbound = evasive(outbound, failures);
    // Cloudflare CDN server: dial a clean edge IP found on this network (SNI/Host unchanged).
    final original = outbound;
    if (!chain) outbound = CleanIp.apply(outbound);
    final cleanIp = identical(outbound, original) ? null : outbound['server'] as String?;
    if (cleanIp != null) AppLog.add('windows: ${server.displayName} via clean Cloudflare IP $cleanIp');
    final port = options.localPort > 0 ? options.localPort : await SingboxCore.freePort();
    final api = await SingboxCore.freePort();
    final mtu = options.tunMode ? await NetworkInfo.tunMtu(options.tunMtu) : 1420;
    if (options.tunMode) AppLog.add('windows: tun mtu $mtu');
    final backups = <Server>[];
    final backupOutbounds = <Map<String, dynamic>>[];
    if (!free && !chain) {
      for (final s in standby) {
        if (s.uri == server.uri || FreeRoutes.isFree(s) || s.uri.startsWith('warp://')) continue;
        final o = _core.outbound(s);
        if (o == null) continue;
        backups.add(s);
        backupOutbounds.add(CleanIp.apply(o));
      }
    }
    _activeStandby = backups;
    _activeIndex = 0;
    // Multi-path: a direct WARP endpoint joins the urltest group when the identity exists.
    final multiPath = options.multiPath && !free && !chain;
    final warpMember =
        multiPath && allowWarpMember && !_plainRetry && WarpRegistry.account != null ? parseOutbound('warp://$_warpEndpoint') : null;
    _multiPath = multiPath;
    _memberNames = {
      'proxy-0': server.displayName,
      for (final (i, b) in backups.indexed) 'proxy-${i + 1}': b.displayName,
      SingboxCore.multiPathWarpTag: 'WARP',
    };
    final proc = await _core.start(_core.connectConfig(outbound, port, api, multiPath == options.multiPath ? options : options.withoutMultiPath,
        tun: options.tunMode,
        mtu: mtu,
        directProcesses: [
          if (free || WinFreeRoutes.isPsiphonChain(server)) ...WinFreeRoutes.processNames,
          if (_xray.available) XrayBridge.processName,
        ],
        standby: backupOutbounds,
        warpMember: warpMember,
        extraOutbounds: extraOutbounds));
    // stdout closes when the process exits: handle a crash while connected.
    unawaited(proc.stdout.drain<void>().whenComplete(() async {
      if (!identical(_core.process, proc)) return;
      _core.process = null;
      _proxyPort = null;
      await _free.stop();
      await _warpHelper.stop();
      if (options.killSwitch && !options.tunMode && options.systemProxy) {
        // Kill switch: point browsers at a dead proxy so nothing leaks until reconnect or disconnect.
        WinSystemProxy.enable('127.0.0.1:9');
      } else {
        await _releaseProxy();
      }
      _states.add(VpnState.disconnected);
    }));

    if (!await _core.waitApi(api, stop: stopped)) {
      AppLog.add(stopped()
          ? 'windows: ${server.displayName} stopped (cancelled or over the time budget)'
          : 'windows: core did not start for ${server.displayName} (see sing-box lines above)');
      await disconnect();
      if (!stopped() && (backups.isNotEmpty || warpMember != null)) {
        // A backup (or WARP member) config may be what the core rejected: try once more with the main server alone.
        final saved = standby;
        standby = const [];
        _plainRetry = true;
        try {
          return await connect(server, options);
        } finally {
          standby = saved;
          _plainRetry = false;
        }
      }
      return false;
    }
    _api = api;
    final passes = deadlineAt == null
        ? await _core.verifyThroughProxy(port, options.testUrl, stop: isCancelled)
        : await _core.verifyThroughProxy(port, options.testUrl, timeout: budgetedCheck, stop: stopped);
    if (!passes) {
      AppLog.add('windows: no traffic through ${server.displayName}'
          '${deadlineAt != null ? ' within ${budgetedCheck.inSeconds} s per check / time budget' : ''}');
      await disconnect();
      if (cleanIp != null) CleanIp.markBad(cleanIp);
      if (_sniOverride != null) return false; // one SNI of a retry round
      if (!free) _failures[server.uri] = failures + 1;
      if (realityBase != null) {
        if (sniUsed != null) await RealitySni.forget(realityBase);
        // Only on a retry (the server already failed before), once per server per session.
        if (deadlineAt == null && !isCancelled() && failures >= 1 && _sniRetried.add(server.uri)) return _retryRealitySni(server, options, realityBase);
      }
      return false;
    }
    _failures.remove(server.uri);
    if (server.uri.startsWith('warp://')) _warpEndpoint = server.uri.substring('warp://'.length);
    _proxyPort = port;
    // Fetch or refresh the Iranian rule-sets for the next connection (daily, through the tunnel if needed).
    if (options.bypassIran && options.iranRuleSets) unawaited(_core.updateIranRuleSets(proxy: '127.0.0.1:$port'));
    if (options.systemProxy && !options.tunMode) {
      WinSystemProxy.enable('127.0.0.1:$port');
      await (await SharedPreferences.getInstance()).setBool(_proxyOwnedKey, true);
    }
    unawaited(_core.streamTraffic(api, _traffic));
    return true;
  }

  /// DNS-only mode is running (no proxy; health = the system resolver answers).
  bool _dnsOnly = false;

  /// Resolves www.google.com through the system resolver (hijacked by the TUN to the gaming DNS).
  /// [log]: write the result (or error) to the diagnostic log.
  static Future<bool> _systemLookupOk({bool log = false, Duration timeout = const Duration(seconds: 5)}) async {
    try {
      final result = await InternetAddress.lookup('www.google.com').timeout(timeout);
      if (log) AppLog.add('windows: dns-only lookup ok (${result.first.address})');
      return result.isNotEmpty;
    } catch (e) {
      if (log) AppLog.add('windows: dns-only lookup failed ($e)');
      return false;
    }
  }

  /// DNS-only mode for games: TUN without any proxy, all traffic direct, DNS answered by [dns].
  /// Needs administrator like TUN mode. Returns true once a system DNS lookup succeeds.
  Future<bool> connectDnsOnly(String dns, EngineOptions options) async {
    if (!isAdmin) throw const AdminRequiredError();
    await disconnect();
    final api = await SingboxCore.freePort();
    final mtu = await NetworkInfo.tunMtu(options.tunMtu);
    AppLog.add('windows: dns-only mode via $dns, tun mtu $mtu');
    final proc = await _core.start(_core.dnsOnlyConfig(dns, api, mtu: mtu));
    AppLog.add('windows: dns-only config written, sing-box started (pid ${proc.pid})');
    unawaited(proc.stdout.drain<void>().whenComplete(() {
      if (!identical(_core.process, proc)) return;
      AppLog.add('windows: dns-only sing-box exited');
      _core.process = null;
      _dnsOnly = false;
      _states.add(VpnState.disconnected);
    }));
    if (!await _core.waitApi(api, stop: isCancelled)) {
      AppLog.add('windows: dns-only core did not start (see sing-box lines above)');
      await disconnect();
      return false;
    }
    AppLog.add('windows: dns-only core api up');
    _api = api;
    _dnsOnly = true;
    // The TUN routes and firewall rules appear a moment after the API: retry the lookup for about 6 s.
    final until = DateTime.now().add(const Duration(seconds: 6));
    var ok = false;
    while (!ok && !isCancelled() && _core.process != null) {
      ok = await _systemLookupOk(log: true, timeout: const Duration(seconds: 2));
      if (ok || DateTime.now().isAfter(until)) break;
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    if (!ok) {
      AppLog.add('windows: dns-only gave up: www.google.com did not resolve through $dns');
      await disconnect();
      return false;
    }
    unawaited(_core.streamTraffic(api, _traffic));
    return true;
  }

  /// The AmneziaWG tunnel service is installed by this app (removed on disconnect and at the next start).
  bool _awgActive = false;
  late Directory _awgDir;
  static const _awgTunnel = 'MolidoAWG';
  static const _awgActiveKey = 'awg_active';

  /// User-facing reason of the last failed AmneziaWG start, or null.
  String? amneziaError;

  /// Exit country (Cloudflare trace) of the running AmneziaWG tunnel, or null.
  String? amneziaExitCountry;

  String get _awgExe => '${File(Platform.resolvedExecutable).parent.path}\\amneziawg\\amneziawg.exe';

  /// Cloudflare /cdn-cgi/trace without a proxy as key/value pairs, or null on failure.
  static Future<Map<String, String>?> _cfTrace(Duration timeout) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.getUrl(Uri.parse('https://www.cloudflare.com/cdn-cgi/trace')).timeout(timeout);
      final res = await req.close().timeout(timeout);
      final body = await res.transform(utf8.decoder).join().timeout(timeout);
      if (res.statusCode != 200) return null;
      return {
        for (final line in const LineSplitter().convert(body))
          if (line.indexOf('=') case final i when i > 0) line.substring(0, i): line.substring(i + 1).trim(),
      };
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _awgUninstall() async {
    try {
      if (File(_awgExe).existsSync()) {
        final r = await Process.run(_awgExe, ['/uninstalltunnelservice', _awgTunnel]).timeout(const Duration(seconds: 20));
        AppLog.add('amnezia: tunnel service removed (exit ${r.exitCode})');
      }
    } catch (e) {
      AppLog.add('amnezia: removing the tunnel service failed ($e)');
    }
    final conf = File('${_awgDir.path}\\$_awgTunnel.conf');
    try {
      if (conf.existsSync()) conf.deleteSync();
    } catch (_) {}
    _awgActive = false;
    await (await SharedPreferences.getInstance()).remove(_awgActiveKey);
  }

  /// AmneziaWG (junk obfuscation included) through the bundled amneziawg.exe tunnel service. Needs administrator.
  /// Tries [preferred] first, then every endpoint of [config] for 8 s each; returns the working endpoint or null.
  Future<String?> connectAmnezia(AmneziaConfig config, EngineOptions options, {String? preferred}) async {
    if (!isAdmin) throw const AdminRequiredError();
    amneziaError = null;
    amneziaExitCountry = null;
    await disconnect();
    if (!File(_awgExe).existsSync()) {
      AppLog.add('amnezia: amneziawg.exe not found next to the app');
      amneziaError = 'amneziawg.exe کنار برنامه پیدا نشد؛ نسخه‌ی کامل برنامه را نصب کنید.';
      return null;
    }
    final order = [
      if (preferred != null && config.endpoints.contains(preferred)) preferred,
      ...config.endpoints.where((e) => e != preferred),
    ];
    AppLog.add('amnezia: ${order.length} endpoint(s), junk ${config.hasJunk ? 'on' : 'off'}');
    final conf = File('${_awgDir.path}\\$_awgTunnel.conf');
    for (final endpoint in order) {
      if (isCancelled()) break;
      onPhase?.call('AmneziaWG: $endpoint');
      AppLog.add('amnezia: trying $endpoint');
      await conf.writeAsString(config.toConf(endpoint), flush: true);
      _awgActive = true;
      await (await SharedPreferences.getInstance()).setBool(_awgActiveKey, true);
      ProcessResult? result;
      try {
        result = await Process.run(_awgExe, ['/installtunnelservice', conf.path]).timeout(const Duration(seconds: 20));
      } catch (e) {
        AppLog.add('amnezia: installing the tunnel service failed ($e)');
      }
      if (result == null || result.exitCode != 0) {
        if (result != null) AppLog.add('amnezia: install exit ${result.exitCode} ${'${result.stderr}'.trim()}');
        await _awgUninstall();
        continue;
      }
      // A plain request could still leave through the ISP while routes come up: WARP configs must show warp=on.
      final until = DateTime.now().add(const Duration(seconds: 8));
      Map<String, String>? trace;
      while (!isCancelled() && DateTime.now().isBefore(until)) {
        final t = await _cfTrace(const Duration(seconds: 3));
        if (t != null && (!config.isWarp || t['warp'] == 'on' || t['warp'] == 'plus')) {
          trace = t;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (trace != null) {
        amneziaExitCountry = trace['loc'];
        AppLog.add('amnezia: connected via $endpoint (exit ${trace['loc'] ?? '?'})');
        return endpoint;
      }
      AppLog.add('amnezia: no traffic via $endpoint within 8 s');
      await _awgUninstall();
    }
    return null;
  }

  Future<void> _releaseProxy() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_proxyOwnedKey) ?? false) {
      WinSystemProxy.disable();
      await prefs.remove(_proxyOwnedKey);
    }
  }

  @override
  Future<void> disconnect() async {
    _proxyPort = null;
    _api = null;
    _activeStandby = const [];
    _activeIndex = 0;
    _multiPath = false;
    _dnsOnly = false;
    if (_awgActive) await _awgUninstall();
    await _releaseProxy();
    await _core.stop();
    await _free.stop();
    await _warpHelper.stop();
  }
}
