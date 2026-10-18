import 'package:flutter/material.dart';

import '../core/engine.dart';
import '../core/smart/smart_connect.dart';
import 'strings.dart';
import 'style.dart';
import 'widgets.dart';

/// v2 «فیروزه و شب» Smart Connect panel: while connecting, the live race (one chip per route family, pulsing
/// while tested, a weighted progress bar and the current leader); once connected, the winner card with its
/// reason and the warm runner-up. Pure view of a [SmartRun]; hidden when there is none.
class SmartConnectPanel extends StatelessWidget {
  const SmartConnectPanel({super.key, required this.run, required this.state});

  final SmartRun? run;
  final VpnState state;

  @override
  Widget build(BuildContext context) {
    final r = run;
    if (r == null) return const SizedBox.shrink();
    if (state == VpnState.connected && r.winner != null) return SmartWinnerCard(run: r);
    if (state != VpnState.connecting) return const SizedBox.shrink();
    return SmartRacePanel(run: r);
  }
}

class SmartRacePanel extends StatelessWidget {
  const SmartRacePanel({super.key, required this.run});

  final SmartRun run;

  @override
  Widget build(BuildContext context) {
    final r = run;
    final families = r.families.values.toList();
    final tested = families.where((f) => f.status == SmartStatus.ok || f.status == SmartStatus.failed).length;
    final leader = r.leader;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 6),
      Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
              color: Palette.raised, borderRadius: BorderRadius.circular(Palette.pillRadius), border: Border.all(color: Palette.border)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: Palette.accent)),
            const SizedBox(width: 8),
            Text(tr('سنجش هوشمند · مرحله‌ی ${digits(r.stage)} از ۳', 'Smart test · stage ${r.stage} of 3'),
                style: TextStyle(fontSize: 12.5, color: Palette.text, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      Text(tr('${digits(tested)} از ${digits(families.length)} روش سنجیده شد', '$tested of ${families.length} methods tested'),
          textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Palette.text)),
      const SizedBox(height: 4),
      Text(tr('دست‌دهی واقعی، تأخیر و پایداری هر روش، هم‌زمان', 'Real handshake, latency and stability of every method, in parallel'),
          textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Palette.muted)),
      const SizedBox(height: 10),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
            value: r.progress, minHeight: 4, color: Palette.accent, backgroundColor: Palette.raised),
      ),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, box) {
        const gap = 8.0;
        final w = (box.maxWidth - 2 * gap) / 3;
        return Wrap(spacing: gap, runSpacing: gap, children: [
          for (final f in families) SizedBox(width: w, child: SmartChip(family: f)),
        ]);
      }),
      if (leader != null) ...[
        const SizedBox(height: 12),
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: tr('پیشتاز فعلی: ', 'Leading: ')),
              TextSpan(text: leader.family, style: TextStyle(color: Palette.accentText, fontWeight: FontWeight.w700)),
              TextSpan(
                  text: tr(' — امتیاز ${digits(leader.score.round())} · ${smartReason(leader.measured)}',
                      ' — score ${leader.score.round()} · ${smartReason(leader.measured, stableWord: 'stable')}')),
            ]),
            style: TextStyle(fontSize: 13, color: Palette.muted),
          ),
        ),
      ],
    ]);
  }
}

class SmartChip extends StatefulWidget {
  const SmartChip({super.key, required this.family});

  final SmartFamilyState family;

  @override
  State<SmartChip> createState() => _SmartChipState();
}

class _SmartChipState extends State<SmartChip> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.family;
    final testing = f.status == SmartStatus.testing;
    if (testing && !Palette.reduceMotion && !_pulse.isAnimating) _pulse.repeat(reverse: true);
    if ((!testing || Palette.reduceMotion) && _pulse.isAnimating) _pulse.stop();
    final dim = f.status == SmartStatus.failed || f.status == SmartStatus.skipped;
    final dot = switch (f.status) {
      SmartStatus.ok || SmartStatus.testing => Palette.accent,
      SmartStatus.failed => Palette.faint,
      _ => Palette.muted,
    };
    final detail = f.detail(
      queued: tr('در صف', 'queued'),
      testing: tr('در حال سنجش…', 'testing…'),
      failed: tr('ناموفق', 'failed'),
      skipped: tr('لازم نشد', 'not needed'),
    );
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) => Opacity(
        opacity: dim ? 0.55 : 1,
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: Palette.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: testing ? Palette.accent.withValues(alpha: 0.5 + 0.5 * _pulse.value) : Palette.border,
                width: testing ? 1.6 : 1),
            boxShadow: testing ? [BoxShadow(color: Palette.glow.withValues(alpha: 0.35 * _pulse.value), blurRadius: 12)] : null,
          ),
          child: child,
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
        Row(children: [
          Expanded(
            child: Text(f.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textDirection: TextDirection.ltr,
                textAlign: TextAlign.start,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Palette.text)),
          ),
          const SizedBox(width: 6),
          Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: dot)),
        ]),
        const SizedBox(height: 4),
        Text(detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 11.5,
                color: f.status == SmartStatus.ok ? Palette.accentText : Palette.muted,
                fontFamily: f.status == SmartStatus.ok ? Palette.numericFamily : null)),
      ]),
    );
  }
}

class SmartWinnerCard extends StatelessWidget {
  const SmartWinnerCard({super.key, required this.run});

  final SmartRun run;

  @override
  Widget build(BuildContext context) {
    final w = run.winner!;
    final runner = run.runnerUp;
    final title = '${w.family} · ${w.label}';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: Palette.brandGradient),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(Icons.check_rounded, color: Palette.bg, size: 28),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: Palette.text)),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                        color: Palette.accent.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(10)),
                    child: Text(tr('برنده', 'Winner'),
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Palette.accentText)),
                  ),
                ]),
                const SizedBox(height: 4),
                Text(
                    tr('${run.reason ?? ''} — امتیاز ${digits(w.score.round())} از ${digits(run.routesTested)} مسیر سنجیده‌شده',
                        '${run.reason ?? ''} — score ${w.score.round()} of ${run.routesTested} routes tested'),
                    style: TextStyle(fontSize: 12.5, height: 1.5, color: Palette.muted)),
              ]),
            ),
          ]),
          if (runner != null) ...[
            const SizedBox(height: 10),
            Divider(height: 1, color: Palette.border),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: Text(tr('ذخیره‌ی آماده: ${runner.family} · ${runner.label}', 'Ready as backup: ${runner.family} · ${runner.label}'),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: Palette.muted)),
              ),
              Text(tr('جابه‌جایی فوری', 'instant failover'),
                  style: TextStyle(fontSize: 12.5, color: Palette.accentText, fontWeight: FontWeight.w600)),
            ]),
          ],
        ]),
      ),
    );
  }
}
