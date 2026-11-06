import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server.dart';

/// User-adjustable advanced settings, persisted in shared_preferences.
class AppSettings extends ChangeNotifier {
  static const defaultTestUrl = 'https://www.gstatic.com/generate_204';
  static const testUrls = {
    defaultTestUrl: 'Google',
    'https://cp.cloudflare.com/generate_204': 'Cloudflare',
    'https://www.apple.com/library/test/success.html': 'Apple',
  };
  /// Iranian gaming DNS for the sing-box core: id -> (label, address). Only answers inside Iran, so queried directly.
  static const gamingDnsPresets = <String, (String, String)>{
    'radar': ('Radar Game', '10.202.10.10'),
    'electro': ('Electro', '78.157.42.100'),
    'shecan': ('Shecan', '178.22.122.100'),
    '403': ('403.online', '10.202.10.202'),
  };

  /// Selected gaming DNS address; null = automatic.
  String? get tunnelDns => gamingDnsPresets[dnsPreset]?.$2;

  static const dnsServers = {'1.1.1.1': 'Cloudflare', '8.8.8.8': 'Google', '9.9.9.9': 'Quad9'};

  // Appearance
  String themeMode = 'system'; // system | light | dark
  bool reduceMotion = false;
  String language = 'fa'; // fa | en

  // Connection
  String androidCore = 'auto'; // auto | xray | singbox
  String connectMode = 'direct'; // direct (like v2rayNG, no ping) | test (ping first, pick fastest)
  String transport = 'auto'; // auto (V2Ray servers, WARP, then Psiphon) | v2ray | warp | psiphon | tor | dns (Windows: gaming DNS only, no proxy)
  bool transportChosen = false; // the user picked a route themselves (else the owner's default route applies)
  bool autoReconnect = true;
  bool connectOnLaunch = true; // "اتصال خودکار": connect once servers load (also after Windows startup)
  bool anonymousReports = false; // opt-in anonymous server quality reports
  bool reportsAsked = false; // the first-launch consent dialog for reports was shown
  bool proxyOnly = false; // Android: local proxy without VPN tunnel
  bool systemProxy = true; // Windows: set the Windows system proxy
  bool tunMode = false; // Windows: full-device VPN (administrator)
  bool killSwitch = false; // Windows: block traffic if the core dies
  int localPort = 0; // Windows: 0 = random free port
  int tunMtu = 0; // Windows TUN: 0 = automatic (manual override when set)

  // Routing / DNS / anti-censorship
  bool bypassIran = true;
  bool iranRuleSets = true; // with bypassIran: full Iranian IP/domain lists direct (new installs; existing users keep .ir only)
  String dns = '1.1.1.1';
  String dnsPreset = 'auto'; // auto | a gamingDnsPresets id
  bool fragment = false;
  bool dataSaver = false; // Windows: block QUIC (UDP 443) and skip background pre-warm / clean-IP probing
  bool backgroundScanner = true; // Windows: hourly real probe of every server from the user's own internet
  bool multiPath = false; // Windows: "proxy" is a urltest group (main + backups + WARP) instead of a selector
  Set<String> excludedApps = {}; // Android package names that skip the VPN

  // Extras
  bool warp = false; // chain Cloudflare WARP behind the server
  bool v2rayOverPsiphon = true; // Windows automatic mode: best V2Ray servers dialed through Psiphon
  String warpAccount = ''; // JSON of WarpAccount, created on first use
  String amneziaConfig = ''; // Windows: JSON of the imported AmneziaConfig (secret: never in backups or logs)
  String amneziaEndpoint = ''; // last AmneziaWG endpoint that passed traffic, tried first
  bool launchAtStartup = false; // Windows
  bool homeAdvanced = false; // home shows mode chips, DNS, servers and stats (off = simple view, always automatic)
  bool onboarded = false; // first-launch steps were shown
  bool scheduleEnabled = false; // connect when the time range starts, disconnect when it ends
  String scheduleFrom = '08:00', scheduleTo = '23:00'; // HH:MM, local time; may cross midnight
  Set<String> favorites = {}; // server uris
  List<String> manualConfigs = []; // user-imported share links
  List<String> userSubscriptions = []; // private/personal subscription URLs, refreshed hourly
  List<String> publicSources = []; // additional public profile feeds, refreshed hourly

  // Server selection
  int poolSize = 40;
  int timeoutSeconds = 8;
  String testUrl = defaultTestUrl;
  Set<Protocol> protocols = Protocol.values.toSet();
  String customSubscription = '';

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    themeMode = p.getString('s_themeMode') ?? themeMode;
    reduceMotion = p.getBool('s_reduceMotion') ?? reduceMotion;
    language = p.getString('s_language') == 'en' ? 'en' : 'fa';
    androidCore = p.getString('s_androidCore') ?? androidCore;
    connectMode = p.getString('s_connectMode') ?? connectMode;
    transport = p.getString('s_transport') ?? transport;
    // Existing users who already picked a non-automatic route count as having chosen.
    transportChosen = p.getBool('s_transportChosen') ?? (transport != 'auto');
    autoReconnect = p.getBool('s_autoReconnect') ?? autoReconnect;
    connectOnLaunch = p.getBool('s_autoConnect') ?? connectOnLaunch;
    anonymousReports = p.getBool('s_anonReports') ?? anonymousReports;
    reportsAsked = p.getBool('s_reportsAsked') ?? anonymousReports;
    proxyOnly = p.getBool('s_proxyOnly') ?? proxyOnly;
    systemProxy = p.getBool('s_systemProxy') ?? systemProxy;
    tunMode = p.getBool('s_tunMode') ?? tunMode;
    killSwitch = p.getBool('s_killSwitch') ?? killSwitch;
    localPort = p.getInt('s_localPort') ?? localPort;
    tunMtu = p.getInt('s_tunMtu') ?? tunMtu;
    bypassIran = p.getBool('s_bypassIran') ?? bypassIran;
    final storedRuleSets = p.getBool('s_iranRuleSets');
    if (storedRuleSets == null) {
      // Migration: only fresh installs get the Iranian rule-sets by default; existing users keep their behaviour.
      final existing = p.containsKey('sub_time') || p.getKeys().any((k) => k.startsWith('s_'));
      iranRuleSets = !existing;
      await p.setBool('s_iranRuleSets', iranRuleSets);
    } else {
      iranRuleSets = storedRuleSets;
    }
    dns = p.getString('s_dns') ?? dns;
    final storedDns = p.getString('s_dnsPreset');
    // Presets that no longer exist (Cloudflare, Google, custom...) fall back to automatic.
    dnsPreset = storedDns != null && gamingDnsPresets.containsKey(storedDns) ? storedDns : 'auto';
    fragment = p.getBool('s_fragment') ?? fragment;
    multiPath = p.getBool('s_multiPath') ?? multiPath;
    dataSaver = p.getBool('s_dataSaver') ?? dataSaver;
    backgroundScanner = p.getBool('s_bgScanner') ?? backgroundScanner;
    excludedApps = (p.getStringList('s_excludedApps') ?? const []).toSet();
    warp = p.getBool('s_warp') ?? warp;
    v2rayOverPsiphon = p.getBool('s_v2rayOverPsiphon') ?? v2rayOverPsiphon;
    warpAccount = p.getString('s_warpAccount') ?? warpAccount;
    amneziaConfig = p.getString('s_amneziaConfig') ?? amneziaConfig;
    amneziaEndpoint = p.getString('s_amneziaEndpoint') ?? amneziaEndpoint;
    launchAtStartup = p.getBool('s_launchAtStartup') ?? launchAtStartup;
    homeAdvanced = p.getBool('s_homeAdvanced') ?? homeAdvanced;
    onboarded = p.getBool('s_onboarded') ?? onboarded;
    scheduleEnabled = p.getBool('s_scheduleEnabled') ?? scheduleEnabled;
    scheduleFrom = p.getString('s_scheduleFrom') ?? scheduleFrom;
    scheduleTo = p.getString('s_scheduleTo') ?? scheduleTo;
    favorites = (p.getStringList('s_favorites') ?? const []).toSet();
    manualConfigs = p.getStringList('s_manualConfigs') ?? [];
    userSubscriptions = p.getStringList('s_userSubs') ?? [];
    publicSources = p.getStringList('s_publicSources') ?? [];
    poolSize = p.getInt('s_poolSize') ?? poolSize;
    timeoutSeconds = p.getInt('s_timeout') ?? timeoutSeconds;
    testUrl = p.getString('s_testUrl') ?? testUrl;
    customSubscription = p.getString('s_customSub') ?? customSubscription;
    final names = p.getStringList('s_protocols');
    if (names != null) {
      final parsed = Protocol.values.where((x) => names.contains(x.name)).toSet();
      if (parsed.isNotEmpty) protocols = parsed;
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await Future.wait([
      p.setString('s_themeMode', themeMode),
      p.setBool('s_reduceMotion', reduceMotion),
      p.setString('s_language', language),
      p.setString('s_androidCore', androidCore),
      p.setString('s_connectMode', connectMode),
      p.setString('s_transport', transport),
      p.setBool('s_transportChosen', transportChosen),
      p.setBool('s_autoReconnect', autoReconnect),
      p.setBool('s_autoConnect', connectOnLaunch),
      p.setBool('s_anonReports', anonymousReports),
      p.setBool('s_reportsAsked', reportsAsked),
      p.setBool('s_proxyOnly', proxyOnly),
      p.setBool('s_systemProxy', systemProxy),
      p.setBool('s_tunMode', tunMode),
      p.setBool('s_killSwitch', killSwitch),
      p.setInt('s_localPort', localPort),
      p.setInt('s_tunMtu', tunMtu),
      p.setBool('s_bypassIran', bypassIran),
      p.setBool('s_iranRuleSets', iranRuleSets),
      p.setString('s_dns', dns),
      p.setString('s_dnsPreset', dnsPreset),
      p.setBool('s_fragment', fragment),
      p.setBool('s_multiPath', multiPath),
      p.setBool('s_dataSaver', dataSaver),
      p.setBool('s_bgScanner', backgroundScanner),
      p.setStringList('s_excludedApps', excludedApps.toList()),
      p.setBool('s_warp', warp),
      p.setBool('s_v2rayOverPsiphon', v2rayOverPsiphon),
      p.setString('s_warpAccount', warpAccount),
      p.setString('s_amneziaConfig', amneziaConfig),
      p.setString('s_amneziaEndpoint', amneziaEndpoint),
      p.setBool('s_launchAtStartup', launchAtStartup),
      p.setBool('s_homeAdvanced', homeAdvanced),
      p.setBool('s_onboarded', onboarded),
      p.setBool('s_scheduleEnabled', scheduleEnabled),
      p.setString('s_scheduleFrom', scheduleFrom),
      p.setString('s_scheduleTo', scheduleTo),
      p.setStringList('s_favorites', favorites.toList()),
      p.setStringList('s_manualConfigs', manualConfigs),
      p.setStringList('s_userSubs', userSubscriptions),
      p.setStringList('s_publicSources', publicSources),
      p.setInt('s_poolSize', poolSize),
      p.setInt('s_timeout', timeoutSeconds),
      p.setString('s_testUrl', testUrl),
      p.setString('s_customSub', customSubscription),
      p.setStringList('s_protocols', protocols.map((x) => x.name).toList()),
    ]);
  }

  /// Portable backup of non-secret settings only: no WARP identity, imported configs, favorites,
  /// custom subscription link or app lists.
  String toBackupJson() => jsonEncode({
        'molido_settings': 1,
        'themeMode': themeMode,
        'reduceMotion': reduceMotion,
        'language': language,
        'connectMode': connectMode,
        'transport': transport,
        'autoReconnect': autoReconnect,
        'connectOnLaunch': connectOnLaunch,
        'anonymousReports': anonymousReports,
        'systemProxy': systemProxy,
        'tunMode': tunMode,
        'killSwitch': killSwitch,
        'localPort': localPort,
        'tunMtu': tunMtu,
        'bypassIran': bypassIran,
        'iranRuleSets': iranRuleSets,
        'dnsPreset': dnsPreset,
        'fragment': fragment,
        'multiPath': multiPath,
        'dataSaver': dataSaver,
        'backgroundScanner': backgroundScanner,
        'v2rayOverPsiphon': v2rayOverPsiphon,
        'poolSize': poolSize,
        'timeoutSeconds': timeoutSeconds,
        'testUrl': testUrl,
        'protocols': protocols.map((x) => x.name).toList(),
        'scheduleEnabled': scheduleEnabled,
        'scheduleFrom': scheduleFrom,
        'scheduleTo': scheduleTo,
      });

  /// Applies a [toBackupJson] text; unknown or wrongly typed fields are ignored. Returns false when invalid.
  Future<bool> restoreBackup(String text) async {
    Object? decoded;
    try {
      decoded = jsonDecode(text.trim());
    } catch (_) {
      return false;
    }
    if (decoded is! Map<String, dynamic> || decoded['molido_settings'] != 1) return false;
    final m = decoded;
    T? pick<T>(String key) => m[key] is T ? m[key] as T : null;
    await update((s) {
      s
        ..themeMode = pick<String>('themeMode') ?? s.themeMode
        ..reduceMotion = pick<bool>('reduceMotion') ?? s.reduceMotion
        ..language = pick<String>('language') == 'en' ? 'en' : (pick<String>('language') == 'fa' ? 'fa' : s.language)
        ..connectMode = pick<String>('connectMode') ?? s.connectMode
        ..transport = pick<String>('transport') ?? s.transport
        ..autoReconnect = pick<bool>('autoReconnect') ?? s.autoReconnect
        ..connectOnLaunch = pick<bool>('connectOnLaunch') ?? s.connectOnLaunch
        ..anonymousReports = pick<bool>('anonymousReports') ?? s.anonymousReports
        ..systemProxy = pick<bool>('systemProxy') ?? s.systemProxy
        ..tunMode = pick<bool>('tunMode') ?? s.tunMode
        ..killSwitch = pick<bool>('killSwitch') ?? s.killSwitch
        ..localPort = pick<int>('localPort') ?? s.localPort
        ..tunMtu = pick<int>('tunMtu') ?? s.tunMtu
        ..bypassIran = pick<bool>('bypassIran') ?? s.bypassIran
        ..iranRuleSets = pick<bool>('iranRuleSets') ?? s.iranRuleSets
        ..dnsPreset = gamingDnsPresets.containsKey(pick<String>('dnsPreset')) ? pick<String>('dnsPreset')! : 'auto'
        ..fragment = pick<bool>('fragment') ?? s.fragment
        ..multiPath = pick<bool>('multiPath') ?? s.multiPath
        ..dataSaver = pick<bool>('dataSaver') ?? s.dataSaver
        ..backgroundScanner = pick<bool>('backgroundScanner') ?? s.backgroundScanner
        ..v2rayOverPsiphon = pick<bool>('v2rayOverPsiphon') ?? s.v2rayOverPsiphon
        ..poolSize = pick<int>('poolSize') ?? s.poolSize
        ..timeoutSeconds = pick<int>('timeoutSeconds') ?? s.timeoutSeconds
        ..testUrl = pick<String>('testUrl') ?? s.testUrl
        ..scheduleEnabled = pick<bool>('scheduleEnabled') ?? s.scheduleEnabled
        ..scheduleFrom = parseTime(pick<String>('scheduleFrom') ?? '') != null ? pick<String>('scheduleFrom')! : s.scheduleFrom
        ..scheduleTo = parseTime(pick<String>('scheduleTo') ?? '') != null ? pick<String>('scheduleTo')! : s.scheduleTo;
      final names = m['protocols'];
      if (names is List) {
        final parsed = Protocol.values.where((x) => names.contains(x.name)).toSet();
        if (parsed.isNotEmpty) s.protocols = parsed;
      }
      s.reportsAsked = true;
    });
    return true;
  }

  /// Minutes after midnight for "HH:MM", or null when invalid.
  static int? parseTime(String hhmm) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(hhmm.trim());
    if (m == null) return null;
    final h = int.parse(m[1]!), min = int.parse(m[2]!);
    return h < 24 && min < 60 ? h * 60 + min : null;
  }

  /// Whether [now] falls in the scheduled range (a range may cross midnight, e.g. 22:00–02:00).
  bool insideSchedule(DateTime now) {
    final from = parseTime(scheduleFrom), to = parseTime(scheduleTo);
    if (from == null || to == null || from == to) return false;
    final m = now.hour * 60 + now.minute;
    return from < to ? (m >= from && m < to) : (m >= from || m < to);
  }

  Future<void> update(void Function(AppSettings s) change) async {
    change(this);
    notifyListeners();
    await _save();
  }

  /// Resets tuning options; keeps personal data (favorites, imported configs, WARP identity).
  Future<void> reset() => update((s) {
        s
          ..warp = false
          ..autoReconnect = true
          ..connectOnLaunch = true
          ..proxyOnly = false
          ..systemProxy = true
          ..tunMode = false
          ..killSwitch = false
          ..localPort = 0
          ..bypassIran = true
          ..iranRuleSets = true
          ..dns = '1.1.1.1'
          ..dnsPreset = 'auto'
          ..fragment = false
          ..multiPath = false
          ..dataSaver = false
          ..backgroundScanner = true
          ..excludedApps = {}
          ..poolSize = 40
          ..timeoutSeconds = 8
          ..testUrl = defaultTestUrl
          ..protocols = Protocol.values.toSet()
          ..customSubscription = '';
      });
}
