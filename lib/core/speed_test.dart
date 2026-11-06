import 'dart:async';
import 'dart:io';

/// Measures traffic through the supplied local HTTP proxy using speed.cloudflare.com.
/// Every transfer is bounded and incomplete/failed HTTP responses are not reported as speed.
class SpeedTest {
  SpeedTest._();

  static const _downBytes = 10 * 1000 * 1000, _upBytes = 2 * 1000 * 1000;
  static const _limit = Duration(seconds: 20);
  static const _probeLimit = Duration(seconds: 4);
  static const _probeCount = 5;

  /// Mbps (download/upload), median probe latency, mean absolute adjacent-probe
  /// variation, and failed-probe percentage. Failed directions are null.
  static Future<({
    double? down,
    double? up,
    double? pingMs,
    double? jitterMs,
    double? packetLossPct,
  })> run(String proxy) async {
    final client = HttpClient()
      ..findProxy = ((_) => 'PROXY $proxy')
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final probes = await _probe(client);
      final down = await _download(client);
      final up = await _upload(client);
      return (
        down: down,
        up: up,
        pingMs: _median(probes),
        jitterMs: _jitter(probes),
        packetLossPct: (_probeCount - probes.length) * 100 / _probeCount,
      );
    } finally {
      client.close(force: true);
    }
  }

  static Duration? _remaining(Stopwatch watch, Duration limit) {
    final remaining = limit - watch.elapsed;
    return remaining > Duration.zero ? remaining : null;
  }

  static double _mbps(int bytes, Duration elapsed) =>
      elapsed.inMicroseconds <= 0 ? 0 : bytes * 8 / 1e6 / (elapsed.inMicroseconds / 1e6);

  static double? _median(List<double> values) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
  }

  static double? _jitter(List<double> values) {
    if (values.length < 2) return null;
    var total = 0.0;
    for (var i = 1; i < values.length; i++) {
      total += (values[i] - values[i - 1]).abs();
    }
    return total / (values.length - 1);
  }

  static Future<List<double>> _probe(HttpClient client) async {
    final values = <double>[];
    for (var i = 0; i < _probeCount; i++) {
      final watch = Stopwatch()..start();
      try {
        final req = await client.getUrl(Uri.parse('https://speed.cloudflare.com/__down?bytes=0'))
            .timeout(_probeLimit);
        final beforeResponse = _remaining(watch, _probeLimit);
        if (beforeResponse == null) continue;
        final res = await req.close().timeout(beforeResponse);
        final beforeBody = _remaining(watch, _probeLimit);
        if (beforeBody == null) continue;
        if (res.statusCode != HttpStatus.ok) {
          await res.drain<void>().timeout(beforeBody);
          continue;
        }
        await res.drain<void>().timeout(beforeBody);
        if (watch.elapsed <= _probeLimit) values.add(watch.elapsedMicroseconds / 1000);
      } catch (_) {
        // A failed probe is counted in packet loss, not silently omitted from the denominator.
      }
    }
    return values;
  }

  static Future<double?> _download(HttpClient client) async {
    try {
      final watch = Stopwatch()..start();
      final req = await client.getUrl(Uri.parse('https://speed.cloudflare.com/__down?bytes=$_downBytes'))
          .timeout(_limit);
      final beforeResponse = _remaining(watch, _limit);
      if (beforeResponse == null) return null;
      final res = await req.close().timeout(beforeResponse);
      if (res.statusCode != HttpStatus.ok ||
          (res.contentLength >= 0 && res.contentLength != _downBytes)) {
        await res.drain<void>().timeout(_limit);
        return null;
      }
      final beforeBody = _remaining(watch, _limit);
      if (beforeBody == null) return null;
      var received = 0;
      await for (final chunk in res.timeout(beforeBody)) {
        received += chunk.length;
        if (received > _downBytes || watch.elapsed >= _limit) return null;
      }
      if (received != _downBytes || watch.elapsed > _limit) return null;
      return _mbps(received, watch.elapsed);
    } catch (_) {
      return null;
    }
  }

  static Future<double?> _upload(HttpClient client) async {
    try {
      final watch = Stopwatch()..start();
      final req = await client.postUrl(Uri.parse('https://speed.cloudflare.com/__up'))
          .timeout(_limit);
      req.headers.contentType = ContentType.binary;
      req.contentLength = _upBytes;
      const chunk = 64 * 1000;
      final block = List<int>.filled(chunk, 0);
      for (var sent = 0; sent < _upBytes; sent += chunk) {
        req.add(sent + chunk <= _upBytes ? block : block.sublist(0, _upBytes - sent));
      }
      final beforeResponse = _remaining(watch, _limit);
      if (beforeResponse == null) return null;
      final res = await req.close().timeout(beforeResponse);
      final beforeBody = _remaining(watch, _limit);
      if (beforeBody == null) return null;
      await res.drain<void>().timeout(beforeBody);
      if (res.statusCode < HttpStatus.ok || res.statusCode >= HttpStatus.multipleChoices ||
          watch.elapsed > _limit) {
        return null;
      }
      return _mbps(_upBytes, watch.elapsed);
    } catch (_) {
      return null;
    }
  }
}
