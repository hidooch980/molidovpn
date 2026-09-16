import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/engine.dart';
import 'style.dart';

/// The big animated power button: rotating gradient ring, ripples when connected, progress while scanning.
/// The ring is repainted from its own layer; the button itself does not rebuild every frame.
class ConnectOrb extends StatefulWidget {
  const ConnectOrb({super.key, required this.state, required this.colors, required this.onTap, this.progress});

  final VpnState state;
  final List<Color> colors;
  final VoidCallback onTap;
  final double? progress;

  @override
  State<ConnectOrb> createState() => _ConnectOrbState();
}

class _ConnectOrbState extends State<ConnectOrb> with TickerProviderStateMixin {
  late final _spin = AnimationController(vsync: this, duration: const Duration(seconds: 7));
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));
  bool _pressed = false;

  bool get _busy => widget.state == VpnState.connecting || widget.state == VpnState.disconnecting;

  void _syncAnimations() {
    final animate = !Palette.reduceMotion || _busy;
    if (animate && !_spin.isAnimating) {
      _spin.repeat();
      _pulse.repeat();
    } else if (!animate && _spin.isAnimating) {
      _spin.stop();
      _pulse.stop();
    }
  }

  @override
  void initState() {
    super.initState();
    _syncAnimations();
  }

  @override
  void didUpdateWidget(ConnectOrb old) {
    super.didUpdateWidget(old);
    _syncAnimations();
  }

  @override
  void dispose() {
    _spin.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.state == VpnState.connected;
    final busy = _busy;
    final c = widget.colors;
    return Semantics(
      button: true,
      label: on ? 'قطع اتصال' : 'اتصال',
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) {
          setState(() => _pressed = false);
          HapticFeedback.mediumImpact();
          widget.onTap();
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedScale(
            scale: _pressed ? 0.93 : 1,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutBack,
            child: SizedBox.square(
              dimension: 290,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  RepaintBoundary(
                    child: CustomPaint(
                      size: const Size.square(290),
                      painter: _OrbPainter(
                        spin: _spin,
                        pulse: _pulse,
                        colors: c,
                        on: on,
                        busy: busy,
                        progress: widget.progress,
                        dark: Palette.isDark,
                        track: Palette.border,
                      ),
                    ),
                  ),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 700),
                    curve: Curves.easeInOutCubic,
                    width: 158,
                    height: 158,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        center: const Alignment(0, -0.24),
                        radius: 0.9,
                        colors: on
                            ? [c[0].withValues(alpha: 0.30), Palette.surface]
                            : [Palette.accent.withValues(alpha: 0.16), Palette.surface],
                        stops: const [0, 0.7],
                      ),
                      border: Border.all(color: const Color(0x24FFFFFF), width: 1),
                      boxShadow: [
                        BoxShadow(
                          color: c[0].withValues(alpha: on ? 0.35 : (Palette.isDark ? 0.22 : 0.16)),
                          blurRadius: 46,
                          offset: const Offset(0, 20),
                          spreadRadius: -14,
                        ),
                        const BoxShadow(color: Color(0x0FFFFFFF), blurRadius: 0, spreadRadius: 0, offset: Offset(0, 1)),
                      ],
                    ),
                    child: busy
                        ? FadeTransition(
                            opacity: Tween(begin: 0.45, end: 1.0).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
                            child: Icon(Icons.power_settings_new_rounded, size: 76, color: c[0]),
                          )
                        : Icon(
                            Icons.power_settings_new_rounded,
                            size: 76,
                            color: on ? Colors.white : Color.lerp(Palette.text, c[0], 0.2),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({
    required this.spin,
    required this.pulse,
    required this.colors,
    required this.on,
    required this.busy,
    required this.progress,
    required this.dark,
    required this.track,
  }) : super(repaint: Listenable.merge([spin, pulse]));

  final Animation<double> spin, pulse;
  final List<Color> colors;
  final bool on, busy, dark;
  final double? progress;
  final Color track;

  static const _coreRadius = 82.0;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxR = size.width / 2;
    final pulseV = pulse.value;
    final stroke = Paint()..style = PaintingStyle.stroke;

    if (on || busy) {
      for (var i = 0; i < 3; i++) {
        final v = (pulseV + i / 3) % 1.0;
        stroke
          ..strokeWidth = 0.6 + 2.2 * (1 - v)
          ..color = colors[i % colors.length].withValues(alpha: (1 - v) * (on ? 0.5 : 0.28));
        canvas.drawCircle(center, _coreRadius + 12 + v * (maxR - _coreRadius - 12), stroke);
      }
    }

    final ringR = _coreRadius + 24;
    final rect = Rect.fromCircle(center: center, radius: ringR);
    canvas.drawCircle(center, ringR, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = track);

    final rotation = spin.value * math.pi * 2 * (busy ? 4 : 1);
    final sweep = on
        ? math.pi * 2
        : busy
            ? math.pi * 2 * (0.25 + 0.35 * (0.5 + 0.5 * math.sin(pulseV * math.pi * 2)))
            : math.pi * 0.7;
    final fraction = sweep / (math.pi * 2);
    final shader = SweepGradient(
      colors: on ? [colors[0], colors[1], colors[2], colors[0]] : [colors[0].withValues(alpha: 0), colors[0], colors[1]],
      stops: on ? const [0, 0.33, 0.66, 1] : [0, fraction * 0.55, fraction],
      transform: GradientRotation(rotation),
    ).createShader(rect);

    // Soft glow with two wide translucent strokes instead of a per-frame blur filter.
    for (final (width, alpha) in [(16.0, 0.16), (9.0, 0.32), (4.5, 1.0)]) {
      canvas.drawArc(
        rect,
        rotation,
        sweep,
        false,
        Paint()
          ..shader = shader
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = width
          ..color = Colors.white.withValues(alpha: alpha),
      );
    }

    final sparkAngle = rotation + sweep;
    final spark = center + Offset(math.cos(sparkAngle), math.sin(sparkAngle)) * ringR;
    canvas.drawCircle(spark, 8, Paint()..color = colors[1].withValues(alpha: 0.3));
    canvas.drawCircle(spark, 3.5, Paint()..color = dark ? Colors.white : colors[0]);

    final p = progress;
    if (p != null) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: ringR + 16),
        -math.pi / 2,
        math.pi * 2 * p.clamp(0.0, 1.0),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 2.5
          ..color = dark ? Colors.white.withValues(alpha: 0.75) : colors[0],
      );
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.on != on || old.busy != busy || old.progress != progress || old.dark != dark || old.colors != colors;
}
