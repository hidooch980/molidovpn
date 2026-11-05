import 'package:flutter/foundation.dart';

/// In-memory diagnostic log shown in "گزارش خطا" so users can copy and send it.
class AppLog {
  static const _max = 500;
  static final List<String> _lines = [];

  // The support log is user-shareable. Keep useful failure context while
  // removing credentials, account identifiers, profile links and IP addresses.
  static final _secretField = RegExp(
    r"""(?<![A-Za-z0-9_])(["']?(?:authorization|proxy-authorization|password|passwd|passphrase|token|access[_-]?token|refresh[_-]?token|api[_-]?key|secret|client[_-]?secret|private[_-]?key|credential)["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|(?:bearer|basic)\s+\S+|\S+)""",
    caseSensitive: false,
  );
  static final _email = RegExp(
    r'\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
    caseSensitive: false,
  );
  static final _configUri = RegExp(
    r"""\b(?:vmess|vless|trojan|ss|ssr|hysteria2|tuic|wireguard)://[^\s"'<>]+""",
    caseSensitive: false,
  );
  static final _ipv4 = RegExp(
    r'\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b',
  );
  static final _wgKey = RegExp(r'(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}=');

  static String _redact(String message) {
    var safe = message.replaceAllMapped(
      _secretField,
      (match) => '${match.group(1) ?? ''}[redacted]',
    );
    safe = safe.replaceAll(_configUri, '[vpn-profile]');
    safe = safe.replaceAll(_email, '[email]');
    safe = safe.replaceAll(_ipv4, '[ip]');
    safe = safe.replaceAll(_wgKey, '[key]');
    return safe;
  }

  static void add(String message) {
    final safe = _redact(message);
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    _lines.add('${two(t.hour)}:${two(t.minute)}:${two(t.second)}  $safe');
    if (_lines.length > _max) _lines.removeRange(0, _lines.length - _max);
    debugPrint('[mobin] $safe');
  }

  static String dump() => _lines.join('\n');

  static void clear() => _lines.clear();
}
