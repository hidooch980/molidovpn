import 'package:flutter/material.dart';

import '../core/engine.dart';
import 'strings.dart';

/// MolidoVPN design system «فیروزه و شب»: night-navy canvas / cool-white in light, Persian turquoise
/// (firoozeh) accent and connected state, saffron while connecting, pomegranate (anar) for failures,
/// lapis (lajvard) for notices.
/// [apply] is called whenever the theme changes and the app rebuilds.
class Palette {
  static bool isDark = true;
  static bool reduceMotion = false;

  /// Card corner radius; buttons and pills use [pillRadius].
  static const double cardRadius = 20;
  static const double pillRadius = 14;
  static const double bigRadius = 28;

  static Color bg = const Color(0xFF0C1222);
  static Color surface = const Color(0xFF141C30);
  static Color raised = const Color(0xFF1C2640);
  static Color border = const Color(0xFF26314F);
  static Color text = const Color(0xFFEEF2FA);
  static Color muted = const Color(0xFF9AA6C0);
  static Color accent = const Color(0xFF2DD4BF);
  static Color accent2 = const Color(0xFF5EE0CC);
  static Color connected = const Color(0xFF2DD4BF);
  static Color connecting = const Color(0xFFF4A93B);
  static Color danger = const Color(0xFFE5484D);
  static Color glow = const Color(0x592DD4BF);

  /// Android AppAppearance extras: tertiary text, upload accent, readable accent text, failure headline.
  static Color faint = const Color(0xFF66728F);
  static Color violet = const Color(0xFF7088F2);
  static Color accentText = const Color(0xFF5EE0CC);
  static Color errorText = const Color(0xFFF2878A);

  /// Legacy name of the "connected / selected" color.
  static Color amber = const Color(0xFF2DD4BF);
  static Color mapDot = const Color(0x332DD4BF);
  static Color fill = const Color(0x0BFFFFFF);
  static Color fillStrong = const Color(0x17FFFFFF);
  static Color sheet = const Color(0xFF141C30);
  static Color cardTop = const Color(0xFF141C30);
  static Color cardBottom = const Color(0xFF141C30);
  static Color shadow = const Color(0x00000000);
  static double auroraStrength = 0.0;

  static void apply(Brightness brightness, {required bool reduceMotion}) {
    Palette.reduceMotion = reduceMotion;
    isDark = brightness == Brightness.dark;
    if (isDark) {
      bg = const Color(0xFF0C1222);
      surface = const Color(0xFF141C30);
      raised = const Color(0xFF1C2640);
      border = const Color(0xFF26314F);
      text = const Color(0xFFEEF2FA);
      muted = const Color(0xFF9AA6C0);
      accent = const Color(0xFF2DD4BF);
      accent2 = const Color(0xFF5EE0CC);
      connected = const Color(0xFF2DD4BF);
      connecting = const Color(0xFFF4A93B);
      danger = const Color(0xFFE5484D);
      glow = const Color(0x592DD4BF);
      fill = const Color(0x0BFFFFFF);
      fillStrong = const Color(0x17FFFFFF);
      faint = const Color(0xFF66728F);
      violet = const Color(0xFF7088F2);
      accentText = const Color(0xFF5EE0CC);
      errorText = const Color(0xFFF2878A);
    } else {
      bg = const Color(0xFFF6F8FB);
      surface = const Color(0xFFFFFFFF);
      raised = const Color(0xFFEEF2F7);
      border = const Color(0xFFE2E8F0);
      text = const Color(0xFF0F172A);
      muted = const Color(0xFF5B6478);
      accent = const Color(0xFF12A594);
      accent2 = const Color(0xFF0B6E7A);
      connected = const Color(0xFF0B8577);
      connecting = const Color(0xFFD98B1E);
      danger = const Color(0xFFE5484D);
      glow = const Color(0x3312A594);
      fill = const Color(0x0A0F172A);
      fillStrong = const Color(0x140F172A);
      faint = const Color(0xFF94A0B8);
      violet = const Color(0xFF4F6BED);
      accentText = const Color(0xFF0B8577);
      errorText = const Color(0xFFC9363B);
    }
    amber = connected;
    mapDot = accent.withValues(alpha: 0.2);
    sheet = surface;
    cardTop = surface;
    cardBottom = surface;
    // Soft shadow only in light; dark relies on the #26314F hairline instead.
    shadow = isDark ? const Color(0x00000000) : const Color(0x140F172A);
    auroraStrength = 0.0;
  }

  /// Android letter-spacing (em) as Flutter logical pixels; Persian renders with 0.
  static double spacing(double em, double fontSize) => L10n.en ? em * fontSize : 0;

  /// Monospace face for addresses and timers.
  static const String monoFamily = 'Consolas';
  static const List<String> monoFallback = ['Cascadia Mono', 'Courier New', 'monospace'];

  /// Numeric face for stats/ping/speed digits (bundled asset, no network dependency).
  static const String numericFamily = 'Space Grotesk';

  /// Brand gradient (firoozeh 400 → 700), used by the connected button and brand marks.
  static const List<Color> brandGradient = [Color(0xFF2DD4BF), Color(0xFF0B6E7A)];

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
