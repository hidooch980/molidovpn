import 'package:flutter/material.dart';

import 'style.dart';

/// Frosted-looking card. No BackdropFilter: re-blurring an animated background every frame was the main source of lag.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 24,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.borderColor,
  });

  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    // Design-system card: 24 px corners, border only in light theme (or when a highlight color is given).
    final shape = BorderRadius.circular(radius >= 18 ? Palette.cardRadius : radius);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: shape,
        splashColor: Palette.fillStrong,
        highlightColor: Palette.fill,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: shape,
            // Frosted glass without a real BackdropFilter (see the class comment for why): a faint
            // translucent white fill plus a hairline translucent border does almost all of the work
            // that a blur would, at zero per-frame cost.
            color: Palette.isDark ? Palette.surface : null,
            gradient: Palette.isDark ? null : LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Palette.cardTop, Palette.cardBottom],
            ),
            border: Border.all(color: borderColor ?? Palette.border, width: borderColor != null ? 1.5 : 1),
            boxShadow: Palette.isDark
                ? [const BoxShadow(color: Color(0x59000000), blurRadius: 28, offset: Offset(0, 14))]
                : [BoxShadow(color: Palette.shadow, blurRadius: 22, offset: const Offset(0, 8))],
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}
