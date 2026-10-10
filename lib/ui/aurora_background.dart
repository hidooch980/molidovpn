import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'style.dart';

/// Slowly drifting aurora blobs (+ twinkling particles in dark mode), tinted by the connection state.
/// Painted in its own layer and driven by the painter's repaint listenable, so the UI on top never rebuilds for it.
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({super.key, required this.colors, required this.child});

  final List<Color> colors;
  final Widget child;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground> with SingleTickerProviderStateMixin {
  late final _loop = AnimationController(vsync: this, duration: const Duration(seconds: 36), value: 0.2);

  @override
  void initState() {
    super.initState();
    if (!Palette.reduceMotion) _loop.repeat();
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: CustomPaint(
            painter: _AuroraPainter(_loop, widget.colors, Palette.isDark, Palette.bg),
            isComplex: true,
            willChange: !Palette.reduceMotion,
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter(this.animation, this.colors, this.dark, this.bg) : super(repaint: animation);

  final Animation<double> animation;
  final List<Color> colors;
  final bool dark;
  final Color bg;

  static final _particles = List.generate(26, (i) {
    final r = math.Random(i * 7919 + 13);
    return (x: r.nextDouble(), y: r.nextDouble(), size: 0.6 + r.nextDouble() * 1.4, phase: r.nextDouble());
  });

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value;
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    final a = t * 2 * math.pi;
    final s = size.longestSide;
    final strength = Palette.auroraStrength;
    final blobs = [
      (Offset(size.width * (0.15 + 0.18 * math.sin(a)), size.height * (0.18 + 0.10 * math.cos(a * 2))), s * 0.60, colors[0]),
      (Offset(size.width * (0.90 + 0.14 * math.cos(a)), size.height * (0.46 + 0.14 * math.sin(a))), s * 0.52, colors[1]),
      (Offset(size.width * (0.35 + 0.22 * math.sin(a + 2)), size.height * (0.95 + 0.06 * math.cos(a + 1))), s * 0.62, colors[2]),
    ];
    for (final (center, radius, color) in blobs) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(colors: [
            color.withValues(alpha: strength),
            color.withValues(alpha: strength * 0.3),
            color.withValues(alpha: 0),
          ], stops: const [0, 0.45, 1]).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }

    // «فیروزه و شب» uses a calm solid canvas: particles only when an aurora strength is set.
    if (dark && strength > 0) {
      final paint = Paint();
      for (final p in _particles) {
        final y = (p.y - t * (0.35 + p.phase * 0.5)) % 1.0;
        final twinkle = 0.5 + 0.5 * math.sin(a * 9 + p.phase * math.pi * 2);
        paint.color = Colors.white.withValues(alpha: 0.08 + 0.4 * twinkle);
        canvas.drawCircle(Offset(p.x * size.width, y * size.height), p.size, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.dark != dark || old.bg != bg || !_same(old.colors, colors);

  static bool _same(List<Color> a, List<Color> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
