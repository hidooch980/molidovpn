import 'dart:convert';
import 'dart:math' as math;

import '../server.dart';

/// Smart Connect (Windows): race every route in parallel, score each one, connect to the strongest and keep the
/// runner-up warm. The same scoring as the Android app (engine/SmartScore.kt), so both platforms agree on what
/// "strongest" means. Everything in this file is pure (no I/O) and unit-tested.

/// Weights of the 0..100 score. Stability matters most: a route that answers 3 of 3 probes beats a slightly
/// faster one that answers 1 of 3.
class SmartWeights {
  const SmartWeights({this.stability = 0.45, this.latency = 0.30, this.throughput = 0.15, this.connect = 0.10});

  final double stability, latency, throughput, connect;
}

/// What the race measured for one route.
class SmartMeasured {
  const SmartMeasured({this.probes = const [], this.connectMs, this.throughput, this.exitIran = false});

  /// One entry per probe round: delay in ms, or <= 0 when the probe failed.
  final List<int> probes;

  /// Time until the route first carried traffic (core start or Psiphon/Tor bootstrap); null = only probed.
  final int? connectMs;

  /// 0..1 quality prior (shared crowd score of this server, or a measured download); null = unknown (0.5).
  final double? throughput;

  /// The exit is inside Iran (WARP often is): half the score, so foreign exits win when one exists.
  final bool exitIran;

  List<int> get ok => [for (final p in probes) if (p > 0) p];
  double get stability => probes.isEmpty ? 0 : ok.length / probes.length;
  int? get medianMs => smartMedian(ok);
}

int? smartMedian(List<int> values) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2).round();
}

double _clamp01(double v) => v.isNaN ? 0 : v.clamp(0.0, 1.0).toDouble();

/// Latency on a log scale: 100 ms → 1, 3 s → 0.
double smartLatencyNorm(int ms) =>
    _clamp01(1 - (math.log(math.max(ms, 1)) - math.log(100)) / (math.log(3000) - math.log(100)));

/// Connect/bootstrap time: 2 s → 1, 90 s → 0.
double smartConnectNorm(int ms) => _clamp01(1 - (ms - 2000) / 88000);

/// 0..100; 0 when no probe succeeded.
double smartScore(SmartMeasured m, [SmartWeights w = const SmartWeights()]) {
  final median = m.medianMs;
  if (median == null) return 0;
  final connect = m.connectMs == null ? 1.0 : smartConnectNorm(m.connectMs!);
  final throughput = m.throughput == null ? 0.5 : _clamp01(m.throughput!);
  final raw = w.stability * m.stability +
      w.latency * smartLatencyNorm(median) +
      w.throughput * throughput +
      w.connect * connect;
  final total = w.stability + w.latency + w.throughput + w.connect;
  final score = 100 * raw / (total <= 0 ? 1 : total);
  return m.exitIran ? score * 0.5 : score;
}

/// Short reason line for the winner card, e.g. "84ms · 3/3 پایدار".
String smartReason(SmartMeasured m, {String stableWord = 'پایدار', String iranWord = 'خروجی ایران'}) {
  final parts = <String>[];
  final median = m.medianMs;
  if (median != null) parts.add('${median}ms');
  if (m.probes.isNotEmpty) parts.add('${m.ok.length}/${m.probes.length} $stableWord');
  if (m.exitIran) parts.add(iranWord);
  return parts.join(' · ');
}

/// Owner-tunable limits (flags.json → "smart"); every value is clamped so a bad config cannot break connecting.
class SmartConfig {
  const SmartConfig({
    this.enabled = true,
    this.probeTimeoutS = 6,
    this.concurrency = 12,
    this.maxPool = 60,
    this.stabilityRounds = 2,
    this.stabilityTop = 8,
    this.fragmentRace = true,
    this.fragmentMax = 12,
    this.fragmentBelow = 3,
    this.memoryTtlDays = 14,
    this.stickiness = 5,
  });

  final bool enabled, fragmentRace;
  final int probeTimeoutS, concurrency, maxPool, stabilityRounds, stabilityTop, fragmentMax, fragmentBelow, memoryTtlDays;

  /// Score bonus of the route that won last time on this network (avoids flapping between near-equal routes).
  final double stickiness;

  static SmartConfig fromJson(Object? json) {
    if (json is! Map) return const SmartConfig();
    const d = SmartConfig();
    int i(String k, int def, int lo, int hi) {
      final v = json[k];
      return v is num ? v.round().clamp(lo, hi) : def;
    }

    bool b(String k, bool def) => json[k] is bool ? json[k] as bool : def;
    final st = json['stickiness'];
    return SmartConfig(
      enabled: b('enabled', d.enabled),
      probeTimeoutS: i('probe_timeout_s', d.probeTimeoutS, 2, 20),
      concurrency: i('concurrency', d.concurrency, 2, 32),
      maxPool: i('max_pool', d.maxPool, 4, 200),
      stabilityRounds: i('stability_rounds', d.stabilityRounds, 0, 4),
      stabilityTop: i('stability_top', d.stabilityTop, 1, 24),
      fragmentRace: b('fragment_race', d.fragmentRace),
      fragmentMax: i('fragment_max', d.fragmentMax, 0, 40),
      fragmentBelow: i('fragment_below', d.fragmentBelow, 0, 20),
      memoryTtlDays: i('memory_ttl_days', d.memoryTtlDays, 1, 90),
      stickiness: st is num ? st.toDouble().clamp(0, 20).toDouble() : d.stickiness,
    );
  }
}

enum SmartCost { cheap, expensive }

enum SmartStatus { queued, testing, ok, failed, skipped }

/// Route family shown as one chip in the smart-test grid.
String smartFamily(Server s, {bool fragment = false}) {
  final uri = s.uri.toLowerCase();
  if (uri.startsWith('psiphon://auto')) return 'Psiphon';
  if (uri.startsWith('psiphon://')) return 'Psiphon + WARP';
  if (uri.startsWith('tor://')) return 'Tor';
  if (uri.startsWith('viawarp:')) return 'V2Ray + WARP';
  if (uri.startsWith('viapsiphon:')) return 'V2Ray + Psiphon';
  if (uri.startsWith('warp://')) return 'WARP';
  if (fragment) return 'Fragment';
  switch (s.protocol) {
    case Protocol.hysteria2:
      return 'Hysteria2';
    case Protocol.tuic:
      return 'TUIC';
    case Protocol.wireguard:
      return 'WireGuard';
    case Protocol.anytls:
      return 'AnyTLS';
    case Protocol.shadowsocks:
      return 'Shadowsocks';
    default:
  }
  final query = Uri.tryParse(s.uri.split('#').first)?.queryParameters ?? const <String, String>{};
  final security = (query['security'] ?? '').toLowerCase();
  final type = (query['type'] ?? query['net'] ?? '').toLowerCase();
  if (security == 'reality') return 'Reality';
  if (type == 'xhttp' || type == 'splithttp') return 'XHTTP';
  if (type == 'ws' || type == 'httpupgrade' || type == 'grpc') return 'V2Ray CDN';
  return s.protocol == Protocol.trojan ? 'Trojan' : 'V2Ray';
}

/// One raced route: a server, optionally with TLS fragmentation switched on.
class SmartCandidate {
  SmartCandidate(this.server, {this.fragment = false, SmartCost? cost, String? family})
      : cost = cost ?? (_expensive(server) ? SmartCost.expensive : SmartCost.cheap),
        family = family ?? smartFamily(server, fragment: fragment);

  final Server server;
  final bool fragment;
  final SmartCost cost;
  final String family;
  final List<int> probes = [];
  double? shared;
  bool exitIran = false;

  String get id => fragment ? 'frag:${server.uri}' : server.uri;
  String get label => fragment ? '${server.displayName} + Fragment' : server.displayName;

  SmartMeasured get measured => SmartMeasured(probes: probes, throughput: shared, exitIran: exitIran);
  double get score => smartScore(measured);
  bool get responded => probes.any((p) => p > 0);

  /// Psiphon, Tor, chains and WARP are not probed in the parallel race (each needs its own process / identity).
  static bool _expensive(Server s) {
    final uri = s.uri.toLowerCase();
    return uri.startsWith('psiphon://') ||
        uri.startsWith('tor://') ||
        uri.startsWith('viawarp:') ||
        uri.startsWith('viapsiphon:') ||
        uri.startsWith('warp://');
  }
}

/// Final order of the race: responsive routes by score (last winner gets [SmartConfig.stickiness]), then the
/// expensive unprobed routes in their given order (remembered winner first), then routes whose probes failed
/// (a failed probe is not proof — the test URL may be blocked — so they stay as a last resort).
List<SmartCandidate> smartRank(List<SmartCandidate> candidates,
    {SmartMemoryEntry? memory, SmartConfig config = const SmartConfig()}) {
  double effective(SmartCandidate c) {
    var s = c.score;
    if (memory != null && c.id == memory.winner) s += config.stickiness;
    if (memory != null && c.id == memory.runnerUp) s += config.stickiness / 2;
    return s;
  }

  final responsive = [for (final c in candidates) if (c.cost == SmartCost.cheap && c.responded) c];
  final scores = {for (final c in responsive) c: effective(c)};
  final indexOf = {for (final (i, c) in candidates.indexed) c: i};
  responsive.sort((a, b) {
    final byScore = scores[b]!.compareTo(scores[a]!);
    if (byScore != 0) return byScore;
    final byMs = (a.measured.medianMs ?? 1 << 30).compareTo(b.measured.medianMs ?? 1 << 30);
    return byMs != 0 ? byMs : indexOf[a]!.compareTo(indexOf[b]!);
  });
  final expensive = [for (final c in candidates) if (c.cost == SmartCost.expensive) c];
  final remembered = expensive.where((c) => c.id == memory?.winner).toList();
  final failed = [for (final c in candidates) if (c.cost == SmartCost.cheap && !c.responded && !c.fragment) c];
  return [
    ...responsive,
    ...remembered,
    ...expensive.where((c) => !remembered.contains(c)),
    ...failed,
  ];
}

/// Fragment variants worth racing: TLS-over-TCP servers whose plain probe failed, at most [max].
List<Server> smartFragmentTargets(List<SmartCandidate> raced, bool Function(Server) fragmentable, int max) => [
      for (final c in raced)
        if (c.cost == SmartCost.cheap && !c.fragment && !c.responded && fragmentable(c.server)) c.server,
    ].take(max).toList();

/// Winner and runner-up remembered per network (gateway + operator) for [SmartConfig.memoryTtlDays].
class SmartMemoryEntry {
  const SmartMemoryEntry({required this.winner, this.runnerUp, this.score = 0, required this.at});

  final String winner;
  final String? runnerUp;
  final double score;
  final DateTime at;

  Map<String, Object?> toJson() =>
      {'w': winner, if (runnerUp != null) 'r': runnerUp, 's': score.round(), 'at': at.millisecondsSinceEpoch};

  static SmartMemoryEntry? fromJson(Object? json) {
    if (json is! Map || json['w'] is! String || json['at'] is! num) return null;
    return SmartMemoryEntry(
      winner: json['w'] as String,
      runnerUp: json['r'] is String ? json['r'] as String : null,
      score: json['s'] is num ? (json['s'] as num).toDouble() : 0,
      at: DateTime.fromMillisecondsSinceEpoch((json['at'] as num).toInt()),
    );
  }
}

class SmartMemory {
  SmartMemory([Map<String, SmartMemoryEntry>? entries]) : entries = entries ?? {};

  static const maxNetworks = 16;
  final Map<String, SmartMemoryEntry> entries;

  static SmartMemory decode(String? text) {
    if (text == null || text.isEmpty) return SmartMemory();
    try {
      final json = jsonDecode(text);
      if (json is! Map) return SmartMemory();
      return SmartMemory({
        for (final e in json.entries)
          if (e.key is String && SmartMemoryEntry.fromJson(e.value) != null) e.key as String: SmartMemoryEntry.fromJson(e.value)!,
      });
    } catch (_) {
      return SmartMemory();
    }
  }

  String encode() => jsonEncode({for (final e in entries.entries) e.key: e.value.toJson()});

  SmartMemoryEntry? lookup(String network, DateTime now, {int ttlDays = 14}) {
    final e = entries[network];
    if (e == null || now.difference(e.at) > Duration(days: ttlDays)) return null;
    return e;
  }

  void remember(String network, SmartMemoryEntry entry) {
    entries.remove(network);
    entries[network] = entry;
    while (entries.length > maxNetworks) {
      final oldest = entries.entries.reduce((a, b) => a.value.at.isBefore(b.value.at) ? a : b).key;
      entries.remove(oldest);
    }
  }
}

/// One chip of the smart-test grid.
class SmartFamilyState {
  SmartFamilyState(this.label);

  final String label;
  SmartStatus status = SmartStatus.queued;
  int routes = 0, tested = 0, ok = 0;
  int? bestMs;

  String detail({required String queued, required String testing, required String failed, required String skipped}) =>
      switch (status) {
        SmartStatus.queued => queued,
        SmartStatus.testing => testing,
        SmartStatus.failed => failed,
        SmartStatus.skipped => skipped,
        SmartStatus.ok => '${bestMs ?? '?'}ms · $ok/$tested',
      };
}

/// Live state of one Smart Connect run, read by the UI.
class SmartRun {
  SmartRun();

  /// 1 = parallel race, 2 = stability / fragment rounds, 3 = connecting to the winner.
  int stage = 1;
  final Map<String, SmartFamilyState> families = {};
  int done = 0, total = 0;
  SmartCandidate? leader, winner, runnerUp;
  String? reason;
  int routesTested = 0;
  bool finished = false;

  double get progress => total == 0 ? 0 : (done / total).clamp(0.0, 1.0).toDouble();

  void register(SmartCandidate c) => (families[c.family] ??= SmartFamilyState(c.family)).routes++;

  void testing(Iterable<SmartCandidate> cs) {
    for (final c in cs) {
      final f = families[c.family];
      if (f != null && f.status == SmartStatus.queued) f.status = SmartStatus.testing;
    }
  }

  /// One probe result of [c]; updates its chip, the leader and the progress.
  void record(SmartCandidate c, int ms, {bool countsForProgress = true}) {
    c.probes.add(ms);
    if (countsForProgress) done++;
    final f = families[c.family];
    if (f != null) {
      if (c.probes.length == 1) f.tested++;
      if (ms > 0) {
        if (c.probes.where((p) => p > 0).length == 1) f.ok++;
        f.bestMs = f.bestMs == null ? ms : math.min(f.bestMs!, ms);
        f.status = SmartStatus.ok;
      } else if (f.status != SmartStatus.ok && f.tested >= f.routes) {
        f.status = SmartStatus.failed;
      }
    }
    if (c.responded && (leader == null || c.score > leader!.score)) leader = c;
  }

  /// Families still queued when a winner was found (expensive routes that never needed to run).
  void finish() {
    finished = true;
    for (final f in families.values) {
      if (f.status == SmartStatus.queued) f.status = SmartStatus.skipped;
      if (f.status == SmartStatus.testing) f.status = f.ok > 0 ? SmartStatus.ok : SmartStatus.failed;
    }
  }
}
