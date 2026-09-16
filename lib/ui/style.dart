import 'package:flutter/material.dart';

import '../core/engine.dart';
import 'strings.dart';

/// MolidoVPN design system: deep teal-black canvas / mint-white in light, teal accent,
/// emerald when connected, amber while connecting, red for failures.
/// [apply] is called whenever the theme changes and the app rebuilds.
class Palette {
  static bool isDark = true;
  static bool reduceMotion = false;

  /// Card corner radius; buttons and pills use [pillRadius].
  static const double cardRadius = 18;
  static const double pillRadius = 12;
  static const double bigRadius = 26;

  static Color bg = const Color(0xFF0B111C);
  static Color surface = const Color(0x0BFFFFFF);
  static Color raised = const Color(0xFF121A29);
  static Color border = const Color(0x14FFFFFF);
  static Color text = const Color(0xFFEEF2F8);
  static Color muted = const Color(0xFF8A94A8);
  static Color accent = const Color(0xFF34D399);
  static Color accent2 = const Color(0xFF22D3EE);
  static Color connected = const Color(0xFF34D399);
  static Color connecting = const Color(0xFFFBBF24);
  static Color danger = const Color(0xFFF87171);
  static Color glow = const Color(0x5934D399);

  /// Android AppAppearance extras: tertiary text, upload accent, readable accent text, failure headline.
  static Color faint = const Color(0xFF5B6478);
  static Color violet = const Color(0xFF9B8CFF);
  static Color accentText = const Color(0xFF34D399);
  static Color errorText = const Color(0xFFFCA5A5);

  /// Legacy name of the "connected / selected" color.
  static Color amber = const Color(0xFF34D399);
  static Color mapDot = const Color(0x3334D399);
  static Color fill = const Color(0x0BFFFFFF);
  static Color fillStrong = const Color(0x17FFFFFF);
  static Color sheet = const Color(0xFF121A29);
  static Color cardTop = const Color(0xFF121A29);
  static Color cardBottom = const Color(0xFF121A29);
  static Color shadow = const Color(0x00000000);
  static double auroraStrength = 0.0;

  static void apply(Brightness brightness, {required bool reduceMotion}) {
    Palette.reduceMotion = reduceMotion;
    isDark = brightness == Brightness.dark;
    if (isDark) {
      bg = const Color(0xFF0B111C);
      surface = const Color(0x0BFFFFFF);
      raised = const Color(0xFF121A29);
      border = const Color(0x14FFFFFF);
      text = const Color(0xFFEEF2F8);
      muted = const Color(0xFF8A94A8);
      accent = const Color(0xFF34D399);
      accent2 = const Color(0xFF22D3EE);
      connected = const Color(0xFF34D399);
      connecting = const Color(0xFFFBBF24);
      danger = const Color(0xFFF87171);
      glow = const Color(0x5934D399);
      fill = const Color(0x0BFFFFFF);
      fillStrong = const Color(0x17FFFFFF);
      faint = const Color(0xFF5B6478);
      violet = const Color(0xFF9B8CFF);
      accentText = const Color(0xFF34D399);
      errorText = const Color(0xFFFCA5A5);
    } else {
      bg = const Color(0xFFF3FAF8);
      surface = const Color(0xFFFFFFFF);
      raised = const Color(0xFFE6F4F0);
      border = const Color(0xFFD3E7E1);
      text = const Color(0xFF0B1F1B);
      muted = const Color(0xFF4B6B64);
      accent = const Color(0xFF0F9E8A);
      accent2 = const Color(0xFF0891B2);
      connected = const Color(0xFF059669);
      connecting = const Color(0xFFB45309);
      danger = const Color(0xFFDC2626);
      glow = const Color(0x330F9E8A);
      fill = const Color(0x0A0B1F1B);
      fillStrong = const Color(0x140B1F1B);
      faint = const Color(0xFF587A72);
      violet = const Color(0xFF6B5BD6);
      accentText = const Color(0xFF0B7A6B);
      errorText = const Color(0xFFB91C1C);
    }
    amber = connected;
    mapDot = accent.withValues(alpha: 0.2);
    sheet = surface;
    cardTop = surface;
    cardBottom = surface;
    shadow = const Color(0x00000000);
    auroraStrength = 0.0;
  }

  /// Android letter-spacing (em) as Flutter logical pixels; Persian renders with 0.
  static double spacing(double em, double fontSize) => L10n.en ? em * fontSize : 0;

  /// Monospace face for addresses and timers.
  static const String monoFamily = 'Consolas';
  static const List<String> monoFallback = ['Cascadia Mono', 'Courier New', 'monospace'];

  /// Numeric face for stats/ping/speed digits (bundled asset, no network dependency).
  static const String numericFamily = 'Space Grotesk';

  /// Shown only after a reported connection failure.
  static Color get failure => danger;

  /// Card outline: none in dark (surface contrast does the work), a hairline in light.
  static BorderSide get cardSide => isDark ? BorderSide.none : BorderSide(color: border);

  /// Three colors per connection state: primary, secondary, highlight.
  static List<Color> forState(VpnState state) => switch (state) {
        VpnState.connected => [connected, accent, border],
        VpnState.connecting || VpnState.disconnecting => [connecting, accent, border],
        VpnState.disconnected => [accent, connected, border],
      };

  static Color forDelay(int? ms) {
    if (ms == null || ms <= 0) return muted;
    if (ms < 350) return connected;
    if (ms < 800) return connecting;
    return danger;
  }
}

String formatSpeed(int bytesPerSecond) {
  if (bytesPerSecond < 1024) return '$bytesPerSecond B/s';
  if (bytesPerSecond < 1024 * 1024) return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
  return '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(1)} MB/s';
}

String formatDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
}

String timeAgo(DateTime time) {
  final d = DateTime.now().difference(time);
  if (d.inMinutes < 1) return tr('همین الان', 'just now');
  if (d.inHours < 1) return tr('${d.inMinutes} دقیقه پیش', '${d.inMinutes} min ago');
  if (d.inDays < 1) return tr('${d.inHours} ساعت پیش', '${d.inHours} h ago');
  return tr('${d.inDays} روز پیش', '${d.inDays} days ago');
}

/// Smoothly cross-fades a list of colors whenever [colors] changes.
class AnimatedColors extends StatefulWidget {
  const AnimatedColors({super.key, required this.colors, required this.builder});

  final List<Color> colors;
  final Widget Function(BuildContext context, List<Color> colors) builder;

  @override
  State<AnimatedColors> createState() => _AnimatedColorsState();
}

class _AnimatedColorsState extends State<AnimatedColors> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 900), value: 1);
  late List<Color> _from = widget.colors, _to = widget.colors;

  List<Color> get _current {
    final t = Curves.easeInOutCubic.transform(_controller.value);
    return [for (var i = 0; i < _to.length; i++) Color.lerp(_from[i], _to[i], t)!];
  }

  @override
  void didUpdateWidget(AnimatedColors old) {
    super.didUpdateWidget(old);
    if (!_sameColors(old.colors, widget.colors)) {
      _from = _current;
      _to = widget.colors;
      _controller.forward(from: 0);
    }
  }

  static bool _sameColors(List<Color> a, List<Color> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AnimatedBuilder(animation: _controller, builder: (context, _) => widget.builder(context, _current));
}
