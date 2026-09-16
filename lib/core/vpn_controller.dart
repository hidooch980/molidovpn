import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account.dart';
import 'amnezia.dart';
import 'android_engine.dart';
import 'app_log.dart';
import 'background_scanner.dart';
import 'cf_clean_ip.dart';
import 'countries.dart';
import 'free_routes.dart';
import 'engine.dart';
import 'network_info.dart';
import 'outline.dart';
import 'remote_config.dart';
import 'reports.dart';
import 'server.dart';
import 'settings.dart';
import 'subscription.dart';
import 'udp_probe.dart';
import 'update_notifier.dart';
import 'updater.dart';
import 'usage_stats.dart';
import 'warp.dart';
import 'win_free_routes.dart';
import 'windows_engine.dart';
import 'xray_bridge.dart';

class CountryGroup {
  CountryGroup(this.code);

  final String code;
  final List<Server> servers = [];

  String get name => countryName(code);
}

class _Cancelled implements Exception {}

class _UserError implements Exception {
  const _UserError(this.message);
  final String message;
}

class VpnController extends ChangeNotifier {
  VpnController({VpnEngine? engine, SubscriptionRepository? repository})
      : _engineOverride = engine,
        repository = repository ?? SubscriptionRepository();

  final VpnEngine? _engineOverride;
  late final VpnEngine engine = _engineOverride ?? VpnEngine.create(settings);
  final SubscriptionRepository repository;
  final settings = AppSettings();
  final updater = Updater();
  final usage = UsageStats();
  final account = Account();

  // Traffic not yet reported to the account server (bytes).
  int _unreportedUp = 0, _unreportedDown = 0;

  static const _countryKey = 'country', _lastServerKey = 'last_server';
  static const _countryPoolSize = 30, _connectAttempts = 4;

  /// Completes once settings, cache and the first server refresh are done.
  final ready = Completer<void>();

  /// Pseudo location: starred servers only.
  static const favoritesMode = 'FAV';

  /// Country code given to user-imported configs (shown as "کانفیگ‌های من").
  static const manualCode = 'ZZ';

  /// Direct mode tries at most this many servers before giving up.
  static const _directAttempts = 6;

  /// Smart mode stops pinging after this many responsive servers (Android pings one by one, so stop at the first).
  static int get _enoughGood => Platform.isAndroid ? 1 : 3;

  SubscriptionData? _data;
  List<Server> servers = const [];
  List<CountryGroup> countries = const [];

  /// Last measured delay per server uri (-1 = failed).
  final Map<String, int> delays = {};

  /// null = automatic (best server from any country).
  String? selectedCountry;
  VpnState state = VpnState.disconnected;
  String? phase;
  int progressDone = 0, progressTotal = 0;
  Server? current;
  int? currentDelay;
  DateTime? connectedAt;
  TrafficStat traffic = const TrafficStat();
  DateTime? updatedAt;
  bool loading = false, pinging = false;
  String? error;
  bool _cancel = false, _userStopping = false;

  UpdateInfo? update;

  /// null = not downloading.
  double? updateProgress;

  double? get progress => progressTotal == 0 ? null : progressDone / progressTotal;

  EngineOptions get _options => _optionsWith();

  EngineOptions _optionsWith({Duration? timeout}) => EngineOptions(
        testUrl: settings.testUrl,
        timeout: timeout ?? Duration(seconds: settings.timeoutSeconds),
        proxyOnly: settings.proxyOnly,
        systemProxy: settings.systemProxy,
        tunMode: settings.tunMode,
        killSwitch: settings.killSwitch,
        localPort: settings.localPort,
        bypassIran: settings.bypassIran,
        dns: settings.dns,
        fragment: settings.fragment,
        excludedApps: settings.excludedApps.toList(),
        warp: settings.warp ? WarpAccount.fromJsonString(settings.warpAccount) : null,
        tunnelDns: settings.tunnelDns,
        tunMtu: settings.tunMtu,
        iranRuleSets: settings.bypassIran && settings.iranRuleSets,
        multiPath: settings.multiPath,
        dataSaver: settings.dataSaver,
      );

  /// Home-screen announcement from the owner panel; null when none or dismissed.
  AppNotice? get notice => RemoteConfig.notice;

  Future<void> dismissNotice() async {
    await RemoteConfig.dismissNotice();
    notifyListeners();
  }

  /// Applies the owner's flags: a disabled route falls back to automatic, and users who never picked a
  /// route follow the owner's default route (when this platform has it).
  void _applyRemoteFlags() {
    final t = settings.transport;
    var target = t;
    if (!settings.transportChosen) {
      final def = RemoteConfig.defaultMode;
      target = def != 'auto' && (def == 'v2ray' || def == 'warp' || transportAvailable(def)) ? def : 'auto';
    }
    if (target != 'auto' && RemoteConfig.isDisabled(target)) target = 'auto';
    if (target != t && state == VpnState.disconnected) {
      AppLog.add('remote config: route $t -> $target');
      unawaited(settings.update((s) => s.transport = target));
    }
  }

  /// Fetches flags and the announcement (throttled inside); never throws.
  Future<void> refreshRemoteConfig({bool force = false}) async {
    try {
      if (await RemoteConfig.refresh(proxy: engine.httpProxy, force: force)) {
        _applyRemoteFlags();
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> init() async {
    await Future.wait([settings.load(), usage.load(), RemoteConfig.loadCached()]);
    _applyRemoteFlags();
    unawaited(refreshRemoteConfig(force: true));
    settings.addListener(() {
      final data = _data;
      if (data != null) _apply(data);
    });
    engine.states.listen((s) {
      if (s != VpnState.disconnected || state != VpnState.connected || _userStopping) return;
      final dropped = current;
      _markDisconnected();
      if (settings.autoReconnect) unawaited(_switchAway(dropped, alreadyDisconnected: true));
    });
    // Watchdog: a tunnel can stay "up" while the server stops passing traffic.
    Timer.periodic(const Duration(seconds: 5), (_) => _watchdog());
    engine.traffic.listen((t) {
      if (state != VpnState.connected) return;
      usage.add(t);
      _unreportedUp += t.up;
      _unreportedDown += t.down;
      traffic = t;
      notifyListeners();
    });
    final prefs = await SharedPreferences.getInstance();
    final warpIrMs = prefs.getInt(_warpIrKey);
    if (warpIrMs != null) _warpIrUntil = DateTime.fromMillisecondsSinceEpoch(warpIrMs);
    selectedCountry = prefs.getString(_countryKey);
    // The removed gaming mode was stored as 'GAME': fall back to automatic.
    if (selectedCountry == 'GAME') {
      selectedCountry = null;
      await prefs.remove(_countryKey);
    }
    if (Platform.isWindows) await NetworkInfo.detectIpv6();
    try {
      await engine.init();
      AppLog.add('engine ready (${Platform.operatingSystem} ${Platform.operatingSystemVersion})');
    } catch (e) {
      AppLog.add('engine init failed: $e');
      error = 'راه‌اندازی هسته ناموفق بود: $e';
    }
    _userSubBodies = await UserSubscriptions.loadCached(settings.userSubscriptions);
    _parseUserSubs();
    final cached = await repository.loadCached();
    if (cached != null) _apply(cached);
    await refresh();
    // Launched at Windows startup the network may not be up yet: give the server list a few more tries.
    for (var i = 0; i < 3 && _data == null && settings.connectOnLaunch; i++) {
      await Future<void>.delayed(const Duration(seconds: 8));
      await refresh();
    }
    if (!ready.isCompleted) ready.complete();
    unawaited(_loadScores());
    unawaited(_health.load().catchError((Object _) {}));
    // Auto-connect uses the normal connect path, so the selected location (favorites, country) is respected.
    if (settings.connectOnLaunch && servers.isNotEmpty && state == VpnState.disconnected) {
      AppLog.add('auto-connect on launch (mode=${selectedCountry ?? 'auto'})');
      unawaited(connect());
    }
    await checkUpdate();
    // Long-running sessions (e.g. Windows left open) still hear about new releases and get fresh servers.
    Timer.periodic(const Duration(hours: 6), (_) => checkUpdate());
    // Server lists stay fresh while the app runs (the built-in list every 30 min; Connect refreshes a stale one).
    Timer.periodic(const Duration(minutes: 30), (_) => refresh());
    unawaited(refreshUserSubscriptions());
    unawaited(_resolveOutline());
    Timer.periodic(const Duration(hours: 1), (_) {
      refreshUserSubscriptions();
      _resolveOutline();
    });
    // Pre-warm: keep delays of the top servers fresh while idle, so Connect starts with the fastest ones.
    Timer(const Duration(minutes: 1), () => _prewarm());
    Timer.periodic(const Duration(minutes: 20), (_) => _prewarm());
    // Background scanner: real probes of every server from the user's own internet, hourly.
    Timer(const Duration(minutes: 3), () => _backgroundScan());
    Timer.periodic(_scanEvery, (_) => _backgroundScan());
    // Clean Cloudflare IP scan (Windows): checks the network every 5 min, rescans on change or after 30 min.
    Timer(const Duration(seconds: 20), _cleanIpTick);
    Timer.periodic(const Duration(minutes: 5), (_) => _cleanIpTick());
    Timer.periodic(const Duration(seconds: 30), (_) => _scheduleTick());
    if (Account.configured) Timer.periodic(const Duration(minutes: 1), (_) => _reportUsage());
    // Opt-in anonymous "still connected" ping for the admin panel's live count; no IPs, same opt-in as reports.
    Timer.periodic(const Duration(seconds: 50), (_) => _heartbeatTick());
  }

  /// Shared quality score (0..1) per server uri from the optional /scores endpoint; empty when unavailable.
  final Map<String, double> _scoreByUri = {};

  /// Operator bucket the current scores were loaded for ('' = none).
  String? _scoresOp;

  Future<void> _loadScores() async {
    try {
      final op = NetworkInfo.operatorBucket;
      _scoresOp = op ?? '';
      final scores = await ServerReports.fetchScores(proxy: engine.httpProxy, op: op);
      if (scores == null || scores.isEmpty) return;
      _modeScore
        ..clear()
        ..addEntries(scores.entries.where((e) => e.key.startsWith('mode:')));
      _scoreByUri.clear();
      for (final s in servers) {
        final node = _isWarp(s) ? ServerReports.warpNode : await ServerReports.fingerprint(s.uri);
        final score = scores[node];
        if (score != null) _scoreByUri[s.uri] = score;
      }
      AppLog.add('scores: ${_scoreByUri.length} servers scored');
    } catch (_) {
      // Optional: never affects connecting.
    }
  }

  void _heartbeatTick() {
    if (!settings.anonymousReports || state != VpnState.connected) return;
    final server = current;
    unawaited(ServerReports.heartbeat(proxy: engine.httpProxy, mode: server != null ? _routeOf(server) : null));
  }

  /// Opt-in anonymous report of one connection attempt; fire-and-forget.
  void _report(Server server, bool ok, {int? ms}) {
    if (!settings.anonymousReports) return;
    unawaited(() async {
      try {
        final node = _isWarp(server) ? ServerReports.warpNode : await ServerReports.fingerprint(server.uri);
        var delay = ms != null && ms > 0 ? ms : null;
        if (ok && delay == null) delay = await measureConnection();
        await ServerReports.send(node: node, ok: ok, ms: delay, proxy: ok ? engine.httpProxy : null, mode: _routeOf(server));
      } catch (_) {}
    }());
  }

  int _healthFailures = 0;
  bool _watching = false;

  /// Servers that recently dropped, skipped until the time stored here.
  final Map<String, DateTime> _badUntil = {};

  bool _isBad(Server s) => _badUntil[s.uri]?.isAfter(DateTime.now()) ?? false;

  /// Last working server is remembered per network (Wi-Fi, each SIM operator), like the Android app's per-SIM ladder.
  Future<String> _networkServerKey() async => '$_lastServerKey:${await NetworkInfo.networkKey()}';

  /// Learning: the winner is also remembered per ISP bucket and 3-hour time slot (evening filtering differs
  /// from morning), and that one is tried first; falls back to the per-network winner.
  Future<String> _bucketServerKey() async =>
      '${await _networkServerKey()}|${NetworkInfo.operatorBucket ?? '-'}|h${DateTime.now().hour ~/ 3}';

  Future<String?> _lastWinner() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(await _bucketServerKey()) ?? prefs.getString(await _networkServerKey());
  }

  Future<void> _rememberWinner(String uri) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(await _networkServerKey(), uri);
    await prefs.setString(await _bucketServerKey(), uri);
  }

  int _watchTick = 0;

  /// True after the anti-freeze watchdog moved the running tunnel to a backup server (shown on the home screen).
  bool switchedToBackup = false;

  /// Multi-path (Windows): name of the group member currently carrying traffic; null when off or unknown.
  String? activeMember;

  Future<void> _refreshActiveMember() async {
    final eng = engine;
    if (eng is! WindowsEngine) return;
    final member = state == VpnState.connected ? await eng.activeMember() : null;
    if (member != activeMember) {
      activeMember = member;
      notifyListeners();
    }
  }

  Future<void> _watchdog() async {
    _watchTick++;
    final eng = engine;
    if (state == VpnState.connected || activeMember != null) unawaited(_refreshActiveMember());
    final quick = eng is WindowsEngine; // Windows: light 4 s check every 5 s with in-core failover
    final fresh = connectedAt != null && DateTime.now().difference(connectedAt!) < const Duration(seconds: 40);
    if (!quick && !fresh && _watchTick % 3 != 0) return; // every 5 s while fresh, then every 15 s
    if (_watching || state != VpnState.connected || !settings.autoReconnect) {
      if (state != VpnState.connected) _healthFailures = 0;
      return;
    }
    _watching = true;
    try {
      final ok = await engine.healthCheck(_options);
      if (state != VpnState.connected) return;
      _healthFailures = ok ? 0 : _healthFailures + 1;
      if (!ok) AppLog.add('watchdog: no traffic through ${current?.displayName} ($_healthFailures)');
      if (eng is WindowsEngine && _healthFailures >= 2) {
        final dropped = current;
        final backup = await eng.failover();
        if (backup != null && state == VpnState.connected) {
          if (dropped != null) _badUntil[dropped.uri] = DateTime.now().add(const Duration(minutes: 10));
          _healthFailures = 0;
          current = backup;
          currentDelay = delays[backup.uri];
          switchedToBackup = true;
          notifyListeners();
          _report(backup, true, ms: delays[backup.uri]);
          return;
        }
      }
      // Right after connecting, two failed checks (~10 s) are enough to move on; later three (~45 s).
      final fresh = connectedAt != null && DateTime.now().difference(connectedAt!) < const Duration(seconds: 40);
      if (_healthFailures >= (fresh ? 2 : 3)) await _switchAway(current);
    } finally {
      _watching = false;
    }
  }

  /// Auto mode: the connected server stopped working — put it aside for 10 minutes and connect to another one.
  Future<void> _switchAway(Server? dropped, {bool alreadyDisconnected = false}) async {
    _healthFailures = 0;
    if (dropped != null) {
      _badUntil[dropped.uri] = DateTime.now().add(const Duration(minutes: 10));
      AppLog.add('auto switch: leaving ${dropped.displayName}');
    }
    if (!alreadyDisconnected) await disconnect();
    error = 'سرور ${dropped?.displayName ?? ''} قطع شد؛ جابه‌جایی خودکار به سرور دیگر…';
    notifyListeners();
    await connect();
  }

  /// Sends traffic used since the last report; disconnects when the panel has turned the account off.
  Future<void> _reportUsage() async {
    if (_unreportedUp == 0 && _unreportedDown == 0 && state != VpnState.connected) return;
    final up = _unreportedUp, down = _unreportedDown;
    _unreportedUp = _unreportedDown = 0;
    final status = await account.reportUsage(up, down);
    if (status != AccountStatus.ok && state == VpnState.connected) {
      AppLog.add('account: $status reported by server, disconnecting');
      await disconnect();
    }
  }

  /// Pseudo country code of the free WARP route.
  static const warpCode = 'WARP';

  /// Free WARP route: one entry per Cloudflare endpoint (no server list needed).
  static List<Server> get warpServers => [
        for (final (i, endpoint) in WarpAccount.endpoints.indexed)
          Server(
            uri: 'warp://$endpoint',
            remark: 'Cloudflare WARP ${(i + 1).toString().padLeft(2, '0')} · WG',
            countryCode: warpCode,
            protocol: Protocol.wireguard,
          ),
        ...warpServersV6,
      ];

  /// IPv6 WARP endpoints: Windows only, and only while the PC has global IPv6.
  static List<Server> get warpServersV6 => [
        if (Platform.isWindows && NetworkInfo.globalIpv6)
          for (final (i, endpoint) in WarpAccount.endpointsV6.indexed)
            Server(
              uri: 'warp://$endpoint',
              remark: 'Cloudflare WARP IPv6 ${(i + 1).toString().padLeft(2, '0')} · WG',
              countryCode: warpCode,
              protocol: Protocol.wireguard,
            ),
      ];

  bool _isWarp(Server s) => s.countryCode == warpCode;

  /// The connected route exits in Iran (WARP exits in the user's own country): some services will not work.
  bool exitInIran = false;

  /// Status line while DNS-only mode is connected, else null.
  String? dnsOnlyNote;

  /// Persian warning for [exitInIran]; the UI shows its own English text.
  static const exitIranMessage = 'خروجی ایران است؛ بعضی سرویس‌ها (مثل Gemini) کار نمی‌کنند';

  static const _warpIrKey = 'warp_exit_ir_until';
  DateTime? _warpIrUntil;

  /// WARP was seen exiting in Iran on this network within the last 24 hours.
  bool get _warpExitsIr => _warpIrUntil?.isAfter(DateTime.now()) ?? false;

  /// Iranian users: V2Ray first, then Psiphon, then WARP / chains, then Tor.
  bool get _iranOrder => NetworkInfo.ownCountry == 'IR' || _warpExitsIr;

  /// Whether exit checks make sense: skipped when the user's own network is known to be outside Iran.
  bool get _checkExit => NetworkInfo.ownCountry == null || NetworkInfo.ownCountry == 'IR';

  /// Cloudflare trace through the live tunnel: true when the exit country is Iran. Unknown counts as not Iran.
  Future<bool> _exitIsIran(Server server) async {
    final proxy = engine.httpProxy;
    if (proxy == null || !_checkExit) return false;
    final loc = await NetworkInfo.traceCountry(proxy);
    AppLog.add('exit check: ${server.displayName} loc=${loc ?? '?'}');
    if (loc != 'IR') return false;
    if (_isWarp(server)) {
      _warpIrUntil = DateTime.now().add(const Duration(hours: 24));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_warpIrKey, _warpIrUntil!.millisecondsSinceEpoch);
    }
    return true;
  }

  /// WARP routes and the smart-chain routes built on WARP.
  bool _needsWarp(Server s) => _isWarp(s) || WinFreeRoutes.needsWarp(s);

  /// Route of a server for reports and the owner's disabled-mode flags: warp, psiphon, tor or v2ray.
  String _routeOf(Server s) {
    if (WinFreeRoutes.isPsiphonChain(s)) return 'psiphon';
    if (WinFreeRoutes.needsWarp(s) || _isWarp(s)) return 'warp';
    if (FreeRoutes.isFree(s)) return FreeRoutes.routeOf(s);
    return 'v2ray';
  }

  /// False when the owner switched off this server's route (chains: when any of their legs is off).
  bool _routeAllowed(Server s) {
    final off = RemoteConfig.disabled;
    if (off.isEmpty) return true;
    if (WinFreeRoutes.isPsiphonChain(s)) return !off.contains('psiphon') && !off.contains('v2ray');
    if (s.uri == WinFreeRoutes.psiphonOverWarp.uri) return !off.contains('psiphon') && !off.contains('warp');
    if (WinFreeRoutes.isChain(s)) return !off.contains('warp') && !off.contains('v2ray');
    return !off.contains(_routeOf(s));
  }

  /// Shared success score per route (`mode:<route>`) for this operator; used to order free routes.
  final Map<String, double> _modeScore = {};

  /// Psiphon has clearly done better than WARP on this operator (enough shared reports on both).
  bool get _psiphonBeforeWarp {
    final p = _modeScore['mode:psiphon'], w = _modeScore['mode:warp'];
    return p != null && w != null && p > w + 0.1;
  }

  /// Applies the route setting to a candidate pool, minus routes the owner disabled (all kept if that
  /// would leave nothing to try).
  List<Server> _byTransport(List<Server> pool) {
    final all = _byTransportAll(pool);
    final allowed = all.where(_routeAllowed).toList();
    return allowed.isEmpty ? all : allowed;
  }

  List<Server> _byTransportAll(List<Server> pool) => switch (settings.transport) {
        'warp' => warpServers,
        'psiphon' when transportAvailable('psiphon') => [FreeRoutes.psiphon],
        'tor' when transportAvailable('tor') => [FreeRoutes.tor],
        'v2ray' => pool.where((s) => !_isWarp(s)).toList(),
        // From Iran WARP exits in Iran: V2Ray, then Psiphon, then WARP and the chains (their exit is the V2Ray
        // server / Psiphon), then Tor.
        _ when _iranOrder => [
            ...pool.where((s) => !_isWarp(s)),
            ..._psiphonChains(pool),
            if (transportAvailable('psiphon')) FreeRoutes.psiphon,
            ...warpServers.take(4),
            ...warpServersV6.take(2),
            if (Platform.isWindows) ...[
              for (final s in pool.where((x) => !_isWarp(x) && !UdpProbe.udpOnly(x)).take(2)) WinFreeRoutes.viaWarp(s),
              WinFreeRoutes.psiphonOverWarp,
              FreeRoutes.tor,
            ],
          ],
        // Operator reports say Psiphon beats WARP here: same routes, Psiphon block first.
        _ when _psiphonBeforeWarp => [
            ...pool.where((s) => !_isWarp(s)),
            ..._psiphonChains(pool),
            if (transportAvailable('psiphon')) FreeRoutes.psiphon,
            ...warpServers.take(4),
            ...warpServersV6.take(2),
            if (Platform.isWindows) ...[
              for (final s in pool.where((x) => !_isWarp(x) && !UdpProbe.udpOnly(x)).take(2)) WinFreeRoutes.viaWarp(s),
              WinFreeRoutes.psiphonOverWarp,
              FreeRoutes.tor,
            ],
          ],
        // Automatic: V2Ray servers, then free WARP, then Psiphon (and Tor on Windows) as the last resort.
        _ => [
            ...pool.where((s) => !_isWarp(s)),
            ...warpServers.take(4),
            ...warpServersV6.take(2),
            ..._psiphonChains(pool),
            if (transportAvailable('psiphon')) FreeRoutes.psiphon,
            // Smart chain (Windows) before Tor: two V2Ray servers dialed inside WARP, then Psiphon over WARP.
            if (Platform.isWindows) ...[
              for (final s in pool.where((x) => !_isWarp(x) && !UdpProbe.udpOnly(x)).take(2)) WinFreeRoutes.viaWarp(s),
              WinFreeRoutes.psiphonOverWarp,
              FreeRoutes.tor,
            ],
          ],
      };

  /// "V2Ray over Psiphon" (Windows, automatic mode): the 3 best V2Ray servers (fastest recent ping first) dialed
  /// through Psiphon, tried right before Psiphon alone so the exit stays outside Iran.
  List<Server> _psiphonChains(List<Server> pool) {
    if (!Platform.isWindows || !settings.v2rayOverPsiphon || settings.transport != 'auto') return const [];
    final list = pool
        .where((s) =>
            !_isWarp(s) &&
            !FreeRoutes.isFree(s) &&
            !WinFreeRoutes.isChain(s) &&
            !UdpProbe.udpOnly(s) &&
            !isXhttpLink(s.uri))
        .toList();
    final pinged = list.where((s) => (delays[s.uri] ?? -1) > 0).toList()
      ..sort((a, b) => delays[a.uri]!.compareTo(delays[b.uri]!));
    return [for (final s in (pinged.isNotEmpty ? pinged : list).take(3)) WinFreeRoutes.viaPsiphon(s)];
  }

  /// Whether a route choice ('auto', 'v2ray', 'warp', 'psiphon', 'tor') works on this platform.
  /// The UI uses this instead of a hard-coded "coming soon" flag.
  static bool transportAvailable(String t) => switch (t) {
        'psiphon' || 'tor' => Platform.isAndroid || Platform.isWindows,
        'dns' || 'amnezia' => Platform.isWindows,
        _ => true,
      };

  void _apply(SubscriptionData data) {
    _data = data;
    WarpRegistry.account = WarpAccount.fromJsonString(settings.warpAccount);
    final seen = <String>{};
    final manual = [
      for (final link in settings.manualConfigs)
        if (Server.fromUri(OutlineKeys.isDynamic(link) ? _outline[link] ?? '' : link) case final s?)
          Server(uri: s.uri, remark: s.remark, countryCode: manualCode, protocol: s.protocol),
      for (final url in settings.userSubscriptions)
        for (final s in _userSubServers[url] ?? const <Server>[])
          Server(uri: s.uri, remark: s.remark, countryCode: manualCode, protocol: s.protocol),
    ].where((s) => seen.add(s.uri) && engine.supports(s));
    servers = [
      ...manual,
      ...data.servers.where((s) => settings.protocols.contains(s.protocol) && engine.supports(s)),
      ...warpServers,
    ];
    final groups = <String, CountryGroup>{};
    for (final s in servers) {
      groups.putIfAbsent(s.countryCode, () => CountryGroup(s.countryCode)).servers.add(s);
      // A user config named after a country (e.g. "🇹🇷 Turkey") is also listed under that country.
      final real = s.countryCode == manualCode ? countryCodeFromText(s.remark) : null;
      if (real != null && real != unknownCountry) {
        groups.putIfAbsent(real, () => CountryGroup(real)).servers.add(s);
      }
    }
    countries = groups.values.toList();
    if (selectedCountry != null &&
        selectedCountry != favoritesMode &&
        !groups.containsKey(selectedCountry)) {
      selectedCountry = null;
    }
    updatedAt = data.updatedAt;
    notifyListeners();
  }

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    notifyListeners();
    try {
      _apply(await repository.fetch(customUrl: settings.customSubscription));
      AppLog.add('servers: ${servers.length} usable in ${countries.length} locations');
    } catch (e) {
      AppLog.add('servers: refresh failed: $e');
      if (servers.isEmpty) error = 'دریافت لیست سرورها ناموفق بود. اینترنت را بررسی کنید.';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Returns the available update (also stored in [update]), null when up to date or offline.
  Future<UpdateInfo?> checkUpdate() async {
    try {
      update = await updater.check(proxy: engine.httpProxy);
      final found = update;
      if (found != null) unawaited(UpdateNotifier.notifyIfNew(found));
      notifyListeners();
    } catch (_) {
      // Offline or GitHub blocked: try again later.
    }
    return update;
  }

  Future<void> installUpdate() async {
    final info = update;
    if (info == null || updateProgress != null) return;
    updateProgress = 0;
    notifyListeners();
    try {
      final file = await updater.download(info, proxy: engine.httpProxy, onProgress: (p) {
        updateProgress = p;
        notifyListeners();
      });
      if (Platform.isWindows) await disconnect();
      await updater.install(file);
      if (Platform.isWindows) exit(0);
    } catch (e) {
      AppLog.add('update: failed: $e');
      error = 'به‌روزرسانی داخل برنامه ناموفق بود؛ صفحه‌ی دانلود در مرورگر باز شد. '
          'اگر گیت‌هاب باز نمی‌شود، اول وصل شوید و دوباره امتحان کنید.';
      unawaited(Updater.openReleasesPage());
    } finally {
      updateProgress = null;
      notifyListeners();
    }
  }

  Future<void> selectCountry(String? code) async {
    if (code == selectedCountry) return;
    selectedCountry = code;
    // WARP, Psiphon, Tor, Amnezia and DNS cannot exit in a chosen country: use the country's V2Ray servers.
    if (code != null && code != favoritesMode && settings.transport != 'auto' && settings.transport != 'v2ray') {
      await settings.update((s) => s.transport = 'auto');
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    code == null ? await prefs.remove(_countryKey) : await prefs.setString(_countryKey, code);
    if (state == VpnState.connected) {
      await disconnect();
      await connect();
    }
  }

  Future<void> toggle() async {
    switch (state) {
      case VpnState.connected:
        await disconnect();
      case VpnState.connecting:
        // Cancel at once: stop the core now and let the running attempt unwind in the background.
        _cancel = true;
        unawaited(engine.disconnect());
        _markDisconnected();
      case VpnState.disconnected:
        await connect();
      case VpnState.disconnecting:
        break;
    }
  }

  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _notifyTimer;

  /// Big ping rounds report progress per server: rebuild the UI at most every 250 ms.
  void _throttledNotify() {
    const gap = Duration(milliseconds: 250);
    final since = DateTime.now().difference(_lastNotify);
    if (since >= gap) {
      _notifyTimer?.cancel();
      _notifyTimer = null;
      _lastNotify = DateTime.now();
      notifyListeners();
    } else {
      _notifyTimer ??= Timer(gap - since, () {
        _notifyTimer = null;
        _lastNotify = DateTime.now();
        notifyListeners();
      });
    }
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  /// Measures delay for [list] (servers screen) without connecting.
  Future<void> pingServers(List<Server> list) async {
    if (pinging || list.isEmpty) return;
    pinging = true;
    notifyListeners();
    try {
      final result = await engine.pingAll(list, _options);
      for (var i = 0; i < list.length; i++) {
        delays[list[i].uri] = result[i];
      }
    } finally {
      pinging = false;
      notifyListeners();
    }
  }

  /// "Test servers from my internet": probes every server (except WARP) from the user's own connection and
  /// returns (working, total) per protocol label. With anonymous reports on, each result is reported
  /// (with the ISP bucket) so the shared Iran ranking learns from this network. Results also update [delays].
  Future<Map<String, (int, int)>> testAllServers(
      {void Function(int done, int total)? onProgress, bool Function()? isCancelled}) async {
    final list = servers.where((s) => !_isWarp(s)).toList();
    final eng = engine;
    final options = _options;
    void progress(int done) => onProgress?.call(done, list.length);
    final result = eng is WindowsEngine
        ? await eng.probeAll(list, options, onProgress: progress, isCancelled: isCancelled)
        : await engine.pingAll(list, options, onProgress: progress, isCancelled: isCancelled);
    final cancelled = isCancelled?.call() ?? false;
    final byProtocol = <String, (int, int)>{};
    for (var i = 0; i < list.length; i++) {
      if (!cancelled) delays[list[i].uri] = result[i];
      final label = list[i].protocolLabel;
      final (ok, total) = byProtocol[label] ?? (0, 0);
      byProtocol[label] = (ok + (result[i] > 0 ? 1 : 0), total + 1);
    }
    AppLog.add('server test: ${result.where((d) => d > 0).length}/${list.length} working'
        '${cancelled ? ' (cancelled)' : ''}');
    notifyListeners();
    if (settings.anonymousReports && !cancelled) {
      final proxy = engine.httpProxy;
      unawaited(runPool(list.length, 4, (i) async {
        final node = await ServerReports.fingerprint(list[i].uri);
        await ServerReports.send(node: node, ok: result[i] > 0, ms: result[i] > 0 ? result[i] : null, proxy: proxy);
        return 0;
      }));
    }
    return byProtocol;
  }

  /// Server picked in the list (v2rayNG style: tap selects, the connect button connects to it).
  Server? chosen;

  void choose(Server? server) {
    chosen = server;
    notifyListeners();
  }

  /// While connected: time for a request through the tunnel in ms, or null when it fails.
  Future<int?> measureConnection() async {
    if (state != VpnState.connected) return null;
    final watch = Stopwatch()..start();
    final ok = await engine.healthCheck(_options);
    return ok ? watch.elapsedMilliseconds : null;
  }

  bool isFavorite(Server s) => settings.favorites.contains(s.uri);

  Future<void> toggleFavorite(Server s) => settings.update((x) {
        final next = {...x.favorites};
        next.contains(s.uri) ? next.remove(s.uri) : next.add(s.uri);
        x.favorites = next;
      });

  /// Outline dynamic keys (ssconf://) resolved to their current ss:// link.
  final Map<String, String> _outline = {};

  /// Fetches every ssconf:// key again (hourly): Outline servers may rotate the address or password.
  Future<void> _resolveOutline() async {
    final keys = settings.manualConfigs.where(OutlineKeys.isDynamic).toList();
    if (keys.isEmpty) return;
    for (final key in keys) {
      final ss = await OutlineKeys.resolve(key, proxy: engine.httpProxy);
      if (ss != null) _outline[key] = ss;
    }
    final data = _data;
    if (data != null) _apply(data);
  }

  /// Adds share links (one per line, or a base64 subscription body) and Outline ssconf:// keys.
  /// Returns how many were new and valid.
  Future<int> addManualConfigs(String text) async {
    final dynamicKeys = <String>[];
    for (final line in const LineSplitter().convert(text)) {
      final key = line.trim();
      if (!OutlineKeys.isDynamic(key)) continue;
      final ss = await OutlineKeys.resolve(key, proxy: engine.httpProxy);
      AppLog.add('outline: dynamic key ${ss == null ? 'could not be fetched' : 'resolved'}');
      if (ss == null) continue;
      _outline[key] = ss;
      dynamicKeys.add(key);
    }
    final found = [...parseSubscription(text).where(engine.supports).map((s) => s.uri), ...dynamicKeys];
    final existing = settings.manualConfigs.toSet();
    final fresh = found.where(existing.add).toList();
    if (fresh.isNotEmpty) await settings.update((x) => x.manualConfigs = [...fresh, ...x.manualConfigs]);
    return fresh.length;
  }

  /// Body and parsed servers of each user subscription URL.
  Map<String, String> _userSubBodies = {};
  final Map<String, List<Server>> _userSubServers = {};
  bool _userSubsBusy = false;

  void _parseUserSubs() {
    _userSubServers
      ..clear()
      ..addAll({for (final e in _userSubBodies.entries) e.key: parseSubscription(e.value)});
  }

  /// Number of links last fetched from [url].
  int userSubscriptionCount(String url) => _userSubServers[url]?.length ?? 0;

  /// Re-downloads every user subscription URL (hourly and on demand); failures keep the cached links.
  Future<void> refreshUserSubscriptions() async {
    if (_userSubsBusy || settings.userSubscriptions.isEmpty) return;
    _userSubsBusy = true;
    try {
      for (final url in settings.userSubscriptions) {
        try {
          _userSubBodies[url] = await UserSubscriptions.fetch(url, proxy: engine.httpProxy);
        } catch (e) {
          AppLog.add('user subscription: refresh failed ($e)');
        }
      }
      _parseUserSubs();
      final data = _data;
      if (data != null) _apply(data);
    } finally {
      _userSubsBusy = false;
    }
  }

  /// Adds a subscription URL after one successful download; returns the number of links (0 = not added).
  Future<int> addUserSubscription(String url) async {
    final u = Uri.tryParse(url.trim());
    if (u == null || !(u.isScheme('http') || u.isScheme('https')) || u.host.isEmpty) return 0;
    final key = u.toString();
    try {
      final body = await UserSubscriptions.fetch(key, proxy: engine.httpProxy);
      _userSubBodies[key] = body;
      _parseUserSubs();
    } catch (e) {
      AppLog.add('user subscription: add failed ($e)');
      return 0;
    }
    if (!settings.userSubscriptions.contains(key)) {
      await settings.update((x) => x.userSubscriptions = [...x.userSubscriptions, key]);
    } else {
      final data = _data;
      if (data != null) _apply(data);
    }
    return userSubscriptionCount(key);
  }

  Future<void> removeUserSubscription(String url) async {
    _userSubBodies.remove(url);
    _userSubServers.remove(url);
    await UserSubscriptions.forget(url);
    await settings.update((x) => x.userSubscriptions = x.userSubscriptions.where((u) => u != url).toList());
  }

  /// Real probe of the user's configs (Windows: HTTP 204 through each server; Android: core delay test).
  Future<void> probeServers(List<Server> list) async {
    if (pinging || list.isEmpty) return;
    final eng = engine;
    if (eng is! WindowsEngine) return pingServers(list);
    pinging = true;
    notifyListeners();
    try {
      final result = await eng.probeAll(list, _options);
      for (var i = 0; i < list.length; i++) {
        delays[list[i].uri] = result[i];
      }
    } finally {
      pinging = false;
      notifyListeners();
    }
  }

  Future<void> removeManualConfig(String uri) =>
      settings.update((x) => x.manualConfigs = x.manualConfigs.where((u) => u != uri && _outline[u] != uri).toList());

  static const warpFailedMessage = 'ثبت WARP از اینترنت شما ممکن نشد (سرور ثبت Cloudflare در ایران مسدود است). '
      'مسیر «V2Ray» یا «Psiphon» را انتخاب کنید؛ پس از یک اتصال موفق، WARP خودکار از داخل تونل ثبت می‌شود.';

  /// Last failed quick registration: automatic mode does not wait for WARP again for 30 minutes.
  DateTime? _warpQuickFailedAt;

  /// Creates the WARP identity once and keeps it permanently in settings (later connects never need the API).
  /// Order: Cloudflare API directly (3 s), the MolidoVPN worker relay (8 s), then — full mode only — through
  /// the active tunnel, or (Windows, not connected) a temporary relay over the best V2Ray servers.
  /// [quick] (automatic mode): only the first two steps, and not again for 30 minutes after a failure.
  Future<bool> ensureWarp({bool quick = false}) async {
    if (WarpAccount.fromJsonString(settings.warpAccount) != null) return true;
    if (quick) {
      final failed = _warpQuickFailedAt;
      if (failed != null && DateTime.now().difference(failed) < const Duration(minutes: 30)) return false;
    }
    if (await _registerWarp(null, const Duration(seconds: 3))) return true;
    if (await _registerWarp(null, const Duration(seconds: 8), url: WarpAccount.relayUrl)) return true;
    if (quick) {
      _warpQuickFailedAt = DateTime.now();
      return false;
    }
    final tunnel = engine.httpProxy;
    if (tunnel != null && await _registerWarp(tunnel, const Duration(seconds: 25))) return true;
    final eng = engine;
    if (eng is WindowsEngine && state != VpnState.connected) {
      final account = await eng.registerWarpVia(_warpRelayCandidates());
      if (account != null) {
        await _saveWarp(account);
        return true;
      }
    }
    return false;
  }

  Future<bool> _registerWarp(String? proxy, Duration limit, {String url = WarpAccount.apiUrl}) async {
    final how = url != WarpAccount.apiUrl ? 'via worker relay' : (proxy == null ? 'direct' : 'through the tunnel');
    try {
      await _saveWarp(await WarpAccount.register(proxy: proxy, url: url).timeout(limit));
      AppLog.add('warp: registered $how');
      return true;
    } catch (e) {
      AppLog.add('warp: registration $how failed ($e)');
      return false;
    }
  }

  Future<void> _saveWarp(WarpAccount account) async {
    WarpRegistry.account = account;
    _warpQuickFailedAt = null;
    await settings.update((x) => x.warpAccount = jsonEncode(account.toJson()));
    AppLog.add('warp: identity registered and saved');
  }

  /// Best-pinged healthy TCP servers first, then the rest of the list.
  List<Server> _warpRelayCandidates() {
    final list = servers.where((s) => !_isWarp(s) && !UdpProbe.udpOnly(s) && !_isBad(s)).toList();
    final pinged = list.where((s) => (delays[s.uri] ?? -1) > 0).toList()
      ..sort((a, b) => delays[a.uri]!.compareTo(delays[b.uri]!));
    final seen = pinged.map((s) => s.uri).toSet();
    return [...pinged, ...list.where((s) => !seen.contains(s.uri))].take(3).toList();
  }

  /// Connects to one specific server chosen by the user.
  Future<void> connectTo(Server server) async {
    if (state == VpnState.connected) await disconnect();
    await connect(only: server);
  }

  /// Connects to [server] with up to two backups (best recent delays, same location mode) ready inside the core.
  Future<bool> _engineConnect(Server server, EngineOptions options) {
    final eng = engine;
    if (eng is WindowsEngine) {
      final country = selectedCountry;
      final backups = servers
          .where((s) =>
              s.uri != server.uri &&
              (delays[s.uri] ?? -1) > 0 &&
              !_isWarp(s) &&
              !FreeRoutes.isFree(s) &&
              !_isBad(s) &&
              (country == null ||
                  (country == favoritesMode ? settings.favorites.contains(s.uri) : _inCountry(s, country))))
          .toList()
        ..sort((a, b) => delays[a.uri]!.compareTo(delays[b.uri]!));
      eng.standby = backups.take(2).toList();
    }
    return engine.connect(server, options);
  }

  /// Hard budget of one direct / fast-path attempt (Windows), core start and tunnel check included.
  static const _directBudget = Duration(seconds: 12);

  /// Direct or fast-path attempt. Windows: bounded by [_directBudget] (a very slow server can no longer freeze
  /// "connecting"); a server that fails is put aside for 10 minutes so the next connect does not start with it.
  Future<bool> _directConnect(Server server, EngineOptions options) async {
    final eng = engine;
    if (eng is! WindowsEngine || FreeRoutes.isFree(server) || WinFreeRoutes.isChain(server)) {
      return _engineConnect(server, options);
    }
    eng.deadline = DateTime.now().add(_directBudget);
    try {
      // The engine stops by itself at the deadline; this is only a safety net.
      final ok = await _engineConnect(server, options).timeout(_directBudget + const Duration(seconds: 4),
          onTimeout: () async {
        AppLog.add('connect: ${server.displayName} exceeded the ${_directBudget.inSeconds} s budget');
        await engine.disconnect();
        return false;
      });
      if (!ok && !_cancel) _badUntil[server.uri] = DateTime.now().add(const Duration(minutes: 10));
      return ok;
    } finally {
      eng.deadline = null;
    }
  }

  void _checkCancel() {
    if (_cancel) throw _Cancelled();
  }

  /// Last known "inside the scheduled range" value; the schedule only acts when it changes,
  /// so a manual connect/disconnect in the middle of the range is respected.
  bool? _scheduleInside;

  void _scheduleTick() {
    if (!settings.scheduleEnabled) {
      _scheduleInside = null;
      return;
    }
    final inside = settings.insideSchedule(DateTime.now());
    final previous = _scheduleInside;
    _scheduleInside = inside;
    if (previous == null || previous == inside) return;
    if (inside && state == VpnState.disconnected) {
      AppLog.add('schedule: time range started, connecting');
      unawaited(connect());
    } else if (!inside && state == VpnState.connected) {
      AppLog.add('schedule: time range ended, disconnecting');
      unawaited(disconnect());
    }
  }

  void _cleanIpTick() {
    if (!Platform.isWindows || servers.isEmpty || settings.dataSaver) return;
    // Scans must measure the user's own network: not while connecting, and not through a TUN tunnel.
    final direct = state == VpnState.disconnected || (state == VpnState.connected && !settings.tunMode);
    if (!direct) return;
    unawaited(NetworkInfo.detectIpv6().then((had) {
      // Newly (un)available IPv6 changes the WARP endpoint list.
      if (had != servers.any((s) => s.uri.startsWith('warp://['))) {
        final data = _data;
        if (data != null) _apply(data);
      }
    }));
    unawaited(CleanIp.tick(servers.where((s) => !_isWarp(s) && !FreeRoutes.isFree(s)).toList()));
    unawaited(UdpProbe.probe());
  }

  /// When the last idle re-ping finished; its delays order the next connect.
  DateTime? _prewarmAt;
  bool _prewarming = false;

  /// When each failed delay (-1) was first seen; failures older than [_failureTtl] are forgotten so the
  /// server is re-pinged and can come back.
  final Map<String, DateTime> _failedAt = {};
  static const _failureTtl = Duration(hours: 6);

  /// Drops failed delays older than 6 h; returns the servers whose failure expired.
  List<Server> _expireFailures() {
    final now = DateTime.now();
    final expired = <String>{};
    for (final e in delays.entries) {
      if (e.value > 0) {
        _failedAt.remove(e.key);
        continue;
      }
      final at = _failedAt.putIfAbsent(e.key, () => now);
      if (now.difference(at) > _failureTtl) expired.add(e.key);
    }
    for (final uri in expired) {
      delays.remove(uri);
      _failedAt.remove(uri);
      _badUntil.remove(uri);
    }
    return servers.where((s) => expired.contains(s.uri)).toList();
  }

  /// Lists older than this are refreshed in the background when Connect is pressed (the cache is used meanwhile).
  static const _staleList = Duration(minutes: 30);

  void _refreshIfStale() {
    final at = updatedAt;
    if (loading || (at != null && DateTime.now().difference(at) < _staleList)) return;
    AppLog.add('servers: list older than ${_staleList.inMinutes} min, refreshing in the background');
    unawaited(refresh());
  }

  Future<void> _prewarm() async {
    final eng = engine;
    if (eng is! WindowsEngine || settings.dataSaver || _prewarming || pinging || loading || _connectRun != null) return;
    if (state != VpnState.disconnected || servers.isEmpty) return;
    _prewarming = true;
    try {
      final revived = _expireFailures().where((s) => !_isWarp(s) && !FreeRoutes.isFree(s));
      final top = (await _candidates()).where((s) => !_isWarp(s) && !FreeRoutes.isFree(s)).take(30).toList();
      final seen = top.map((s) => s.uri).toSet();
      // Servers whose failure expired (older than 6 h) are re-pinged too, so they can come back.
      final pool = [...top, ...revived.where((s) => seen.add(s.uri)).take(10)];
      if (pool.isEmpty || state != VpnState.disconnected) return;
      final result = await eng.prewarm(pool, _options, isCancelled: () => state != VpnState.disconnected);
      if (state != VpnState.disconnected) return; // a connect started meanwhile: results may be partial
      for (var i = 0; i < pool.length; i++) {
        delays[pool[i].uri] = result[i];
      }
      _prewarmAt = DateTime.now();
      AppLog.add('prewarm: ${result.where((d) => d > 0).length}/${pool.length} servers responded');
      notifyListeners();
    } catch (e) {
      AppLog.add('prewarm: $e');
    } finally {
      _prewarming = false;
    }
  }

  // ---- Background scanner ----

  static const _scanEvery = Duration(minutes: 60);
  static const _scanTimeout = Duration(seconds: 5);
  static const _scanCap = Duration(minutes: 5);
  static const _scanConcurrency = 8;

  final HealthBook _health = HealthBook();
  final HourlyBudget _scanReports = HourlyBudget(200);
  bool _scanning = false, _scanStop = false;

  /// When the last background scan finished and how many servers passed; null = none yet.
  DateTime? lastScanAt;
  int lastScanHealthy = 0;

  /// Memory key of the user's own network: Windows has one network key, so the ISP bucket separates networks.
  String get _healthNet => 'desktop|${NetworkInfo.operatorBucket ?? '-'}';

  /// Hourly real probe (HTTP 204 through a temporary sing-box) of every server: built-in list, user configs and
  /// user subscriptions. Runs only on the user's own network: disconnected, or connected in system-proxy mode
  /// (the probe core dials servers directly and ignores the Windows proxy); never with TUN. Stops at connect.
  Future<void> _backgroundScan() async {
    final eng = engine;
    if (eng is! WindowsEngine || !settings.backgroundScanner || settings.dataSaver) return;
    if (_scanning || _prewarming || pinging || loading || _connectRun != null) return;
    bool allowed() =>
        settings.backgroundScanner &&
        !settings.tunMode &&
        (state == VpnState.disconnected || (state == VpnState.connected && settings.systemProxy));
    if (!allowed()) return;
    final list = servers.where((s) => !_isWarp(s) && !FreeRoutes.isFree(s) && !WinFreeRoutes.isChain(s)).toList();
    if (list.isEmpty) return;
    _scanning = true;
    _scanStop = false;
    final startedIn = state;
    final started = DateTime.now();
    final net = _healthNet;
    bool stop() =>
        _scanStop || !allowed() || state != startedIn || DateTime.now().difference(started) > _scanCap;
    try {
      final result = await eng.probeAll(list, _optionsWith(timeout: _scanTimeout),
          isCancelled: stop, concurrency: _scanConcurrency);
      if (stop()) {
        AppLog.add('background scan: stopped after ${DateTime.now().difference(started).inSeconds} s, results dropped');
        return;
      }
      for (var i = 0; i < list.length; i++) {
        _health.record(net, list[i].uri, result[i]);
        if (state == VpnState.disconnected) delays[list[i].uri] = result[i];
      }
      lastScanAt = DateTime.now();
      lastScanHealthy = result.where((d) => d > 0).length;
      AppLog.add('background scan: $lastScanHealthy/${list.length} servers work on this network');
      unawaited(_health.save().catchError((Object _) {}));
      notifyListeners(); // once per scan
      if (settings.anonymousReports) {
        final n = _scanReports.take(list.length);
        final proxy = state == VpnState.connected ? engine.httpProxy : null;
        unawaited(runPool(n, 2, (i) async {
          final node = await ServerReports.fingerprint(list[i].uri);
          await ServerReports.send(node: node, ok: result[i] > 0, ms: result[i] > 0 ? result[i] : null, proxy: proxy);
          return 0;
        }));
      }
    } catch (e) {
      AppLog.add('background scan: $e');
    } finally {
      _scanning = false;
    }
  }

  /// Fresh idle ping results: responsive servers first (fastest first), untested next, failed last.
  List<Server> _byFreshDelay(List<Server> pool) {
    final at = _prewarmAt;
    if (at == null || DateTime.now().difference(at) > const Duration(minutes: 25)) return pool;
    int rank(Server s) {
      final d = delays[s.uri];
      if (d == null) return 100000;
      return d > 0 ? d : 200000;
    }

    final indexed = pool.indexed.toList()
      ..sort((a, b) {
        final byDelay = rank(a.$2).compareTo(rank(b.$2));
        return byDelay != 0 ? byDelay : a.$1.compareTo(b.$1);
      });
    return [for (final e in indexed) e.$2];
  }

  /// Server [s] belongs to country [code]; user configs count under the country named in their remark.
  static bool _inCountry(Server s, String code) =>
      s.countryCode == code || (s.countryCode == manualCode && countryCodeFromText(s.remark) == code);

  /// Round-robin across countries so a pool compares many locations, not only the first one.
  /// A user config listed under both "کانفیگ‌های من" and its country is taken once.
  static List<Server> _roundRobin(List<CountryGroup> groups, int size) {
    final pool = <Server>[];
    final taken = <String>{};
    for (var round = 0; pool.length < size; round++) {
      var added = false;
      for (final g in groups) {
        if (round < g.servers.length && pool.length < size) {
          if (taken.add(g.servers[round].uri)) pool.add(g.servers[round]);
          added = true;
        }
      }
      if (!added) break;
    }
    return pool;
  }

  Future<List<Server>> _candidates() async {
    final List<Server> pool;
    final country = selectedCountry;
    final size = settings.poolSize;
    if (country == favoritesMode) {
      final favorites = servers.where((s) => settings.favorites.contains(s.uri)).toList();
      final healthy = favorites.where((s) => !_isBad(s)).toList();
      return healthy.isEmpty ? favorites : healthy;
    }
    if (country != null) {
      pool = _byFreshDelay(servers.where((s) => _inCountry(s, country)).take(_countryPoolSize).toList());
    } else {
      pool = _byFreshDelay(_roundRobin(countries, size));
    }
    // Background scanner results for this network: recent successes first, repeated failures last.
    final net = _healthNet;
    final ordered = _health.order(net, pool, (s) => s.uri);
    pool
      ..clear()
      ..addAll(ordered);
    final last = await _lastWinner();
    final lastServer = servers.where((s) => s.uri == last).firstOrNull;
    if (lastServer != null &&
        (country == null || _inCountry(lastServer, country)) &&
        !_health.isDeprioritised(net, lastServer.uri)) {
      pool
        ..remove(lastServer)
        ..insert(0, lastServer);
    }
    // Skip servers that just dropped, unless nothing else is left.
    final healthy = pool.where((s) => !_isBad(s)).toList();
    return healthy.isEmpty ? pool : healthy;
  }

  /// AmneziaWG (Windows) with the personal config when one is imported, otherwise a config built from the app's
  /// own WARP identity. [auto]: quick WARP registration only, and a route exiting in Iran is dropped.
  Future<bool> _amnezia(WindowsEngine eng, EngineOptions options, {required bool auto}) async {
    var config = AmneziaConfig.fromJsonString(settings.amneziaConfig);
    if (config == null) {
      if (WarpAccount.fromJsonString(settings.warpAccount) == null) {
        phase = 'ساخت هویت رایگان Cloudflare WARP…';
        notifyListeners();
        if (!await ensureWarp(quick: auto)) {
          eng.amneziaError = warpFailedMessage;
          return false;
        }
      }
      final warp = WarpAccount.fromJsonString(settings.warpAccount);
      if (warp == null) return false;
      config = AmneziaConfig.fromWarp(
          privateKey: warp.privateKey, peerPublicKey: warp.peerPublicKey, v4: warp.addressV4, v6: warp.addressV6);
    }
    phase = 'اتصال AmneziaWG…';
    notifyListeners();
    final working = await eng.connectAmnezia(config, options,
        preferred: settings.amneziaEndpoint.isEmpty ? null : settings.amneziaEndpoint);
    if (working == null || _cancel) return false;
    final ir = _checkExit && eng.amneziaExitCountry == 'IR';
    if (auto && ir) {
      AppLog.add('connect: AmneziaWG exits in Iran, skipped in automatic mode');
      await eng.disconnect();
      return false;
    }
    if (working != settings.amneziaEndpoint) await settings.update((x) => x.amneziaEndpoint = working);
    // WARP exits in the user's own country: warn like other WARP routes.
    exitInIran = ir;
    dnsOnlyNote = 'AmneziaWG · $working';
    current = null;
    currentDelay = null;
    connectedAt = DateTime.now();
    state = VpnState.connected;
    phase = null;
    notifyListeners();
    return true;
  }

  /// Automatic mode (Windows): AmneziaWG as a late fallback when it can work here (admin, full tunnel, UDP open).
  Future<bool> _amneziaAuto(EngineOptions options) async {
    final eng = engine;
    if (eng is! WindowsEngine || settings.transport != 'auto' || _cancel) return false;
    if (!WindowsEngine.isAdmin || options.proxyOnly || UdpProbe.blocked) return false;
    try {
      return await _amnezia(eng, options, auto: true);
    } catch (e) {
      AppLog.add('connect: AmneziaWG (auto) failed ($e)');
      return false;
    }
  }

  Future<void>? _connectRun;

  Future<void> connect({Server? only}) async {
    final previous = _connectRun;
    if (previous != null) await previous; // a cancelled attempt may still be unwinding
    if (state != VpnState.disconnected) return;
    _refreshIfStale();
    // Automatic mode honours the owner's latest disabled routes; a slow or blocked fetch never holds the connect.
    if (only == null && settings.transport == 'auto') {
      await refreshRemoteConfig().timeout(const Duration(seconds: 3), onTimeout: () {});
    }
    final run = _connect(only);
    _connectRun = run;
    try {
      await run;
    } finally {
      if (identical(_connectRun, run)) _connectRun = null;
    }
    // WARP could not be registered before: now the tunnel carries the request (saved for next time).
    if (state == VpnState.connected &&
        WarpRegistry.account == null &&
        (settings.warp || settings.transport == 'auto')) {
      unawaited(ensureWarp());
    }
  }

  Future<void> _connect(Server? only) async {
    error = null;
    _cancel = false;
    _scanStop = true; // a running background scan stops at once (its sing-box is killed when in-flight probes end)
    // The ISP became known (or changed) since scores were loaded: refresh them for this operator.
    if (_scoresOp != null && (NetworkInfo.operatorBucket ?? '') != _scoresOp) unawaited(_loadScores());
    state = VpnState.connecting;
    phase = 'در حال آماده‌سازی…';
    progressDone = progressTotal = 0;
    notifyListeners();
    var options = _options;
    exitInIran = false;
    // A chosen country (automatic or V2Ray route): only servers from that country, and the exit must be there.
    // Never WARP, Psiphon, Tor, Amnezia or an Iran exit instead.
    final country = selectedCountry;
    final countryMode = only == null &&
        country != null &&
        country != favoritesMode &&
        (settings.transport == 'auto' || settings.transport == 'v2ray');
    final noCountryServer = countryMode
        ? 'سرور سالمی از ${countryName(country)} پیدا نشد؛ کشور دیگری انتخاب کنید یا «خودکار» را بزنید'
        : '';
    if (engine case final WindowsEngine eng) eng.allowWarpMember = !countryMode;
    // Automatic mode: a route that exits in Iran is set aside (not reported as bad); the first is kept if all do.
    final autoExit = only == null && settings.transport == 'auto';
    Server? irFallback;
    Future<bool> exitOk(Server server) async {
      if (countryMode) {
        final proxy = engine.httpProxy;
        final loc = proxy == null ? null : await NetworkInfo.traceCountry(proxy);
        AppLog.add('exit check: ${server.displayName} loc=${loc ?? '?'} wanted=$country');
        if (loc == null || loc == country) return true;
        AppLog.add('connect: ${server.displayName} exits in $loc, not $country; trying the next $country server');
        _badUntil[server.uri] = DateTime.now().add(const Duration(minutes: 10));
        await engine.disconnect();
        return false;
      }
      if (!await _exitIsIran(server)) return true;
      if (!autoExit) {
        exitInIran = true;
        return true;
      }
      AppLog.add('connect: ${server.displayName} exits in Iran, trying the next route');
      irFallback ??= server;
      await engine.disconnect();
      return false;
    }

    Future<bool> useIrFallback() async {
      final server = irFallback;
      if (server == null) return false;
      _checkCancel();
      phase = 'اتصال به ${server.displayName}';
      notifyListeners();
      if (!await _engineConnect(server, options)) return false;
      _checkCancel();
      AppLog.add('connect: every route exits in Iran, keeping ${server.displayName}');
      current = server;
      currentDelay = null;
      connectedAt = DateTime.now();
      exitInIran = true;
      state = VpnState.connected;
      phase = null;
      notifyListeners();
      _report(server, true);
      return true;
    }

    final eng = engine;
    if (eng is AndroidEngine) {
      eng.isCancelled = () => _cancel;
      eng.onPhase = (text) {
        phase = text;
        notifyListeners();
      };
    } else if (eng is WindowsEngine) {
      // Automatic mode: Tor is the last resort and may not hold the connect for minutes.
      eng.torBudget = only == null && settings.transport == 'auto' ? const Duration(seconds: 90) : null;
      eng.isCancelled = () => _cancel;
      eng.onPhase = (text) {
        phase = text;
        notifyListeners();
      };
    }
    try {
      if (Account.configured && await account.refreshStatus() != AccountStatus.ok) {
        throw const _UserError('حساب شما اجازه‌ی اتصال ندارد (غیرفعال یا روی دستگاه دیگر).');
      }
      // Ask for the VPN permission before anything else, so the system dialog shows immediately.
      if (!options.proxyOnly) {
        phase = 'دریافت اجازه‌ی VPN…';
        notifyListeners();
        final granted = await engine.requestPermission();
        AppLog.add('vpn permission: ${granted ? 'granted' : 'denied'}');
        if (!granted) throw const PermissionDeniedError();
      }
      // DNS-only mode (games): no proxy, only DNS through the chosen Iranian gaming DNS.
      if (settings.transport == 'dns' && only == null) {
        if (eng is! WindowsEngine) throw const _UserError('حالت DNS فقط در ویندوز در دسترس است.');
        final preset = AppSettings.gamingDnsPresets[settings.dnsPreset] ?? AppSettings.gamingDnsPresets['radar']!;
        final (name, address) = preset;
        phase = 'راه‌اندازی DNS گیمینگ $name…';
        notifyListeners();
        try {
          if (!await eng.connectDnsOnly(address, options)) {
            _checkCancel();
            throw _UserError('DNS گیمینگ $name فعال نشد (نام www.google.com پاسخ نگرفت). جزئیات در گزارش خطا.');
          }
        } on AdminRequiredError {
          throw const _UserError(
              'حالت DNS به TUN و دسترسی Administrator نیاز دارد. از تنظیمات «اجرای دوباره به‌عنوان ادمین» را بزنید.');
        }
        _checkCancel();
        dnsOnlyNote = 'DNS گیمینگ فعال است: $name';
        current = null;
        currentDelay = null;
        connectedAt = DateTime.now();
        state = VpnState.connected;
        phase = null;
        notifyListeners();
        return;
      }
      // AmneziaWG (Windows): the imported config runs as an amneziawg.exe tunnel service, endpoints tried in order.
      if (settings.transport == 'amnezia' && only == null) {
        if (eng is! WindowsEngine) throw const _UserError('AmneziaWG فقط در ویندوز در دسترس است.');
        try {
          if (await _amnezia(eng, options, auto: false)) return;
        } on AdminRequiredError {
          throw const _UserError(
              'AmneziaWG دسترسی Administrator می‌خواهد. از تنظیمات «اجرای دوباره به‌عنوان ادمین» را بزنید.');
        }
        _checkCancel();
        throw _UserError(eng.amneziaError ?? 'هیچ‌کدام از Endpointهای Amnezia وصل نشد. جزئیات در گزارش خطا.');
      }
      if (servers.isEmpty && only == null) await refresh();
      if (settings.warp && options.warp == null) {
        phase = 'ساخت هویت Cloudflare WARP…';
        notifyListeners();
        if (await ensureWarp(quick: true)) {
          options = _options;
        } else {
          error = 'ثبت WARP ناموفق بود؛ این بار بدون WARP وصل می‌شویم.';
        }
      }
      final List<Server> pool = only != null
          ? [only]
          : countryMode
              ? (await _candidates())
                  .where((s) => !_needsWarp(s) && !FreeRoutes.isFree(s) && !WinFreeRoutes.isChain(s))
                  .toList()
              : _byTransport(await _candidates());
      if (countryMode && pool.isEmpty) throw _UserError(noCountryServer);
      if (pool.any(_needsWarp) && WarpRegistry.account == null) {
        // Automatic mode only tries the direct API and the worker relay; an explicit WARP choice tries every way.
        final quick = only == null && settings.transport != 'warp';
        phase = 'ساخت هویت رایگان Cloudflare WARP…';
        notifyListeners();
        if (!await ensureWarp(quick: quick)) {
          AppLog.add('warp: registration failed${quick ? ', automatic mode skips WARP routes' : ''}');
          pool.removeWhere(_needsWarp);
          if (pool.isEmpty) throw const _UserError(warpFailedMessage);
        }
      }
      if (pool.isEmpty) {
        final country = selectedCountry;
        throw _UserError(country != null && country != favoritesMode
            ? 'سروری از این کشور در دسترس نیست'
            : 'سروری برای این موقعیت پیدا نشد.');
      }
      // UDP is dropped on this network: skip Hysteria2/TUIC/WireGuard/WARP in automatic selection.
      if (only == null &&
          (settings.transport == 'auto' || settings.transport == 'v2ray') &&
          UdpProbe.blocked &&
          pool.any((s) => !UdpProbe.udpOnly(s))) {
        final before = pool.length;
        pool.removeWhere((s) => UdpProbe.udpOnly(s) || WinFreeRoutes.needsWarp(s));
        AppLog.add('connect: UDP blocked here, skipped ${before - pool.length} UDP-only routes');
      }

      // Fast path like v2rayNG: reconnect straight to the last working server, no ping round.
      final last = await _lastWinner();
      if (only == null && pool.isNotEmpty && pool.first.uri == last) {
        final server = pool.first;
        phase = 'اتصال سریع به ${server.displayName}';
        notifyListeners();
        AppLog.add('connect: fast path to last server ${server.displayName}');
        final fastOk = await _directConnect(server, options);
        if (fastOk && await exitOk(server)) {
          _checkCancel();
          current = server;
          currentDelay = null;
          connectedAt = DateTime.now();
          state = VpnState.connected;
          phase = null;
          notifyListeners();
          _report(server, true);
          return;
        }
        if (!_cancel && !fastOk) _report(server, false);
        AppLog.add('connect: fast path failed, testing servers');
        pool.removeAt(0);
        _checkCancel();
      }
      if (only != null) {
        // A server the user picked: connect directly, the tunnel check itself proves it works.
        phase = 'اتصال به ${only.displayName}';
        notifyListeners();
        if (await engine.connect(only, options)) {
          _checkCancel();
          current = only;
          connectedAt = DateTime.now();
          state = VpnState.connected;
          phase = null;
          notifyListeners();
          // Manual route (e.g. WARP): only warn when the exit is in Iran, never disconnect.
          if (await _exitIsIran(only) && state == VpnState.connected) {
            exitInIran = true;
            notifyListeners();
          }
          _report(only, true);
          await _rememberWinner(only.uri);
          return;
        }
        if (!_cancel) _report(only, false);
        throw const _UserError('این سرور وصل نشد. سرور دیگری را امتحان کنید.');
      }

      {
        // Direct first (like v2rayNG): no ping round, try servers in order until one really carries traffic.
        final tried = pool.take(_directAttempts).toList();
        for (final server in tried) {
          _checkCancel();
          phase = 'اتصال مستقیم به ${server.displayName}';
          notifyListeners();
          final directOk = await _directConnect(server, options);
          if (directOk && await exitOk(server)) {
            _checkCancel();
            AppLog.add('connect: direct to ${server.displayName} (${server.protocolLabel})');
            current = server;
            currentDelay = null;
            connectedAt = DateTime.now();
            state = VpnState.connected;
            phase = null;
            notifyListeners();
            _report(server, true);
            await _rememberWinner(server.uri);
            return;
          }
          if (!_cancel && !directOk) _report(server, false);
          AppLog.add('connect: direct ${server.displayName} ${directOk ? 'exits in Iran' : 'failed'}');
        }
        // None worked: test the remaining servers and connect to the fastest responsive one.
        AppLog.add('connect: direct attempts failed, testing the other servers');
        pool.removeWhere(tried.contains);
        if (pool.isEmpty) {
          if (countryMode) throw _UserError(noCountryServer);
          if (only == null && await _amneziaAuto(options)) return;
          _checkCancel();
          if (await useIrFallback()) return;
          // Psiphon / Tor alone (or last): their own reason instead of the server-list advice.
          final eng = engine;
          final freeError = eng is WindowsEngine && tried.isNotEmpty && FreeRoutes.isFree(tried.last)
              ? eng.freeRouteError
              : null;
          throw _UserError(
              freeError ?? 'اتصال برقرار نشد. لیست سرورها را به‌روزرسانی کنید یا کشور دیگری انتخاب کنید.');
        }
      }

      phase = 'سنجش سرورها با اینترنت شما';
      progressTotal = pool.length;
      notifyListeners();
      AppLog.add('connect: mode=${selectedCountry ?? 'auto'} pool=${pool.length} platform=${Platform.operatingSystem}');
      // Smart/country modes stop testing once a few good servers are found — much faster, especially on Android.
      final canStopEarly = only == null;
      var good = 0;
      final measured = await engine.pingAll(
        pool,
        options,
        isCancelled: () => _cancel || (canStopEarly && good >= _enoughGood),
        onResult: (_, delay) {
          if (delay > 0 && delay < 2500) good++;
        },
        onProgress: (done) {
          progressDone = done;
          _throttledNotify();
        },
      );
      _checkCancel();
      AppLog.add('ping: ${measured.where((d) => d > 0).length}/${pool.length} responded '
          '(best ${measured.where((d) => d > 0).fold<int?>(null, (a, d) => a == null || d < a ? d : a)} ms)');
      for (var i = 0; i < pool.length; i++) {
        delays[pool[i].uri] = measured[i];
      }

      // Fastest first; within the same ~100 ms band, the shared quality score (when available) breaks the tie.
      int band(int i) => measured[i] ~/ 100;
      double score(int i) => _scoreByUri[pool[i].uri] ?? -1;
      var ranked = [for (var i = 0; i < pool.length; i++) if (measured[i] > 0) i]
        ..sort((a, b) {
          final byBand = band(a).compareTo(band(b));
          if (byBand != 0) return byBand;
          final byScore = score(b).compareTo(score(a));
          return byScore != 0 ? byScore : measured[a].compareTo(measured[b]);
        });
      if (ranked.isEmpty) {
        // A failed ping test is not proof the server is dead (the test URL may be blocked): try connecting anyway.
        AppLog.add('ping: nothing responded, trying direct connection to the first servers');
        ranked = List.generate(pool.length < _connectAttempts ? pool.length : _connectAttempts, (i) => i);
      }

      progressTotal = 0;
      for (final i in ranked.take(_connectAttempts)) {
        _checkCancel();
        final server = pool[i];
        phase = 'اتصال به ${server.displayName}';
        notifyListeners();
        if (!await _engineConnect(server, options)) {
          AppLog.add('connect: ${server.displayName} (${server.protocolLabel}) failed');
          if (!_cancel) _report(server, false, ms: measured[i]);
          continue;
        }
        AppLog.add('connect: connected to ${server.displayName} (${server.protocolLabel}, ${measured[i]} ms)');
        if (_cancel) {
          await engine.disconnect();
          throw _Cancelled();
        }
        if (!await exitOk(server)) continue;
        current = server;
        currentDelay = measured[i];
        connectedAt = DateTime.now();
        state = VpnState.connected;
        phase = null;
        notifyListeners();
        _report(server, true, ms: measured[i]);
        await _rememberWinner(server.uri);
        return;
      }
      if (countryMode) throw _UserError(noCountryServer);
      if (await _amneziaAuto(options)) return;
      _checkCancel();
      if (await useIrFallback()) return;
      throw const _UserError(
          'اتصال برقرار نشد. «ضد فیلتر» را روشن کنید یا کشور دیگری را امتحان کنید. جزئیات در تنظیمات ← گزارش خطا.');
    } on _Cancelled {
      await engine.disconnect();
      _markDisconnected();
    } on AdminRequiredError {
      error = 'حالت VPN کامل (TUN) دسترسی Administrator می‌خواهد. از تنظیمات «اجرای دوباره به‌عنوان ادمین» را بزنید.';
      _markDisconnected();
    } on PermissionDeniedError {
      error = 'اجازه‌ی VPN داده نشد. دوباره دکمه را بزنید و در پنجره‌ی اندروید «تأیید» را انتخاب کنید. '
          'اگر پنجره نیامد: تنظیمات گوشی ← شبکه ← VPN، و VPN دیگری را که «همیشه روشن» است خاموش کنید.';
      _markDisconnected();
    } on _UserError catch (e) {
      AppLog.add('connect: ${e.message}');
      error = e.message;
      _markDisconnected();
    } catch (e, st) {
      AppLog.add('connect: unexpected $e\n$st');
      error = 'خطای غیرمنتظره: $e';
      await engine.disconnect();
      _markDisconnected();
    }
  }

  Future<void> disconnect() async {
    if (state == VpnState.disconnected) return;
    state = VpnState.disconnecting;
    _userStopping = true;
    notifyListeners();
    try {
      await engine.disconnect();
    } finally {
      _userStopping = false;
      _markDisconnected();
    }
  }

  void _markDisconnected() {
    ServerReports.endSession();
    unawaited(usage.save());
    state = VpnState.disconnected;
    current = null;
    currentDelay = null;
    connectedAt = null;
    switchedToBackup = false;
    activeMember = null;
    exitInIran = false;
    dnsOnlyNote = null;
    traffic = const TrafficStat();
    phase = null;
    progressDone = progressTotal = 0;
    notifyListeners();
  }
}
