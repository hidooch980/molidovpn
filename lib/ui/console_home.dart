import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/engine.dart';
import '../core/network_info.dart';
import '../core/remote_config.dart';
import '../core/vpn_controller.dart';
import '../core/whats_new.dart';
import 'flag_badge.dart';
import 'location_sheet.dart';
import 'onboarding.dart';
import 'servers_screen.dart';
import 'settings_screen.dart';
import 'strings.dart';
import 'style.dart';
import 'support.dart';
import 'widgets.dart';

/// Single unified scrolling home: connection status, live IP, location, route/DNS controls,
/// servers, traffic stats, network facts and support. Settings and Servers open as pages.
class ConsoleHome extends StatefulWidget {
  const ConsoleHome({super.key, required this.controller});

  final VpnController controller;

  @override
  State<ConsoleHome> createState() => _ConsoleHomeState();
}

class _ConsoleHomeState extends State<ConsoleHome> {
  final network = NetworkInfo();
  final _latency = <int>[];
  VpnState? _lastState;
  Timer? _probe, _netTimer;
  WhatsNew? _whatsNew;

  VpnController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onController);
    unawaited(WhatsNew.check().then((w) {
      if (mounted && w != null) setState(() => _whatsNew = w);
    }));
    unawaited(network.refresh());
    _netTimer = Timer.periodic(const Duration(minutes: 2), (_) => network.refresh(proxy: c.engine.httpProxy));
    if (AppNav.tab == 2) {
      // A theme/language switch rebuilt the app from Settings: reopen it.
      AppNav.tab = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openSettings();
      });
    }
    unawaited(_firstRun());
  }

  /// First-launch steps, then the anonymous reports consent question.
  Future<void> _firstRun() async {
    await c.ready.future;
    final s = c.settings;
    if (mounted && !s.onboarded) {
      await showOnboarding(context);
      await s.update((x) => x.onboarded = true);
    }
    await _askReportsConsent();
  }

  void _openSettings() =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsScreen(controller: c)));

  void _openServers() =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ServersScreen(controller: c)));

  /// Asked once: opt in to anonymous server quality reports.
  Future<void> _askReportsConsent() async {
    await c.ready.future;
    final s = c.settings;
    if (!mounted || s.reportsAsked) return;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(tr('کمک به انتخاب سرورهای بهتر', 'Help pick better servers')),
        content: Text(tr(
            'گزارش کیفیت اختیاری است و فقط پس از موافقت شما فعال می‌شود. شناسه مستعار سرور، نتیجه اتصال، تأخیر، نوع شبکه، '
                'دسته اپراتور، حالت اتصال و نسخه برنامه ارسال می‌شود. در Windows، heartbeat نمونه‌برداری‌شده و گزارش خطای مجاز '
                'ممکن است شناسه نصب تصادفی پایدار و رویدادهای خطای پاک‌سازی‌شده را هم داشته باشد. برنامه IP شخصی، نام، مقصد وب‌گردی '
                'یا محتوای ترافیک را در بدنه گزارش نمی‌فرستد؛ اما ارائه‌دهنده زیرساخت هنگام اتصال HTTPS می‌تواند IP مبدأ را ببیند '
                'و برای محدودسازی درخواست استفاده کند. بعداً از تنظیمات ← حریم خصوصی قابل تغییر است.',
            'Quality reports are optional and enabled only with your consent. They include a pseudonymous server id, result, '
                'latency, network type, coarse operator bucket, route mode and app version. On Windows, sampled heartbeats and '
                'permitted failure diagnostics may also include a random persistent install ID and scrubbed error events. '
                'The app does not put your personal IP, name, browsing destinations or traffic content in the report body; '
                'however, the infrastructure provider can see the source IP when receiving HTTPS requests and may use it for '
                'rate limiting. You can change this later in Settings → Privacy.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('نه، ممنون', 'No thanks'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('موافقم', 'Allow'))),
        ],
      ),
    );
    await s.update((x) {
      x.reportsAsked = true;
      if (accepted == true) x.anonymousReports = true;
    });
  }

  void _onController() {
    if (c.state == _lastState) return;
    _lastState = c.state;
    if (c.state == VpnState.connected) {
      _latency.clear();
      _probe?.cancel();
      _probe = Timer.periodic(const Duration(seconds: 10), (_) => _measure());
      unawaited(_measure());
    } else {
      _probe?.cancel();
    }
    if (c.state == VpnState.connected || c.state == VpnState.disconnected) {
      // Never leave the previous route's address visible while the new route is checked.
      network.clearLookup();
      Future<void>.delayed(const Duration(milliseconds: 1500), () => network.refresh(proxy: c.engine.httpProxy));
    }
  }

  Future<void> _measure() async {
    final ms = await c.measureConnection();
    if (!mounted || ms == null) return;
    setState(() {
      _latency.add(ms);
      if (_latency.length > 24) _latency.removeAt(0);
    });
  }

  @override
  void dispose() {
    _probe?.cancel();
    _netTimer?.cancel();
    c.removeListener(_onController);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Palette.bg,
      bottomNavigationBar: _BottomDock(
        onHome: () {},
        onServers: _openServers,
        onSettings: _openSettings,
      ),
      body: Stack(children: [
        // Two soft, static ambient glows behind the whole page — the cinematic-dark mood from the
        // approved design. Static (no per-frame work), so they cost nothing.
        if (Palette.isDark) ...[
          Positioned(top: -70, left: -60, child: _AmbientGlow(color: Palette.accent)),
          Positioned(bottom: 30, right: -70, child: _AmbientGlow(color: Palette.accent2, size: 190)),
        ],
        ListenableBuilder(
        listenable: Listenable.merge([c, network, c.settings]),
        builder: (context, _) {
          return SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: math.min(kContentWidth, constraints.maxWidth),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        _Header(controller: c, onSettings: _openSettings),
                        if (_whatsNew case final w?)
                          _WhatsNewCard(info: w, onClose: () => setState(() => _whatsNew = null)),
                        if (c.notice case final notice?)
                          _NoticeBanner(notice: notice, onClose: c.dismissNotice),
                        if (c.update != null) _UpdateLine(controller: c),
                        const SizedBox(height: 6),
                        Center(child: _Squircle(controller: c)),
                        _SimpleStatus(controller: c),
                        const SizedBox(height: 6),
                        _ExitCard(controller: c, network: network, latency: _latency),
                        const SizedBox(height: 6),
                        _LocationCard(controller: c),
                        const SizedBox(height: 6),
                        _ServerQuickCard(controller: c, onTap: _openServers),
                        TextButton.icon(
                          onPressed: () => openLink(telegramUrl),
                          icon: const Icon(Icons.support_agent_rounded, size: 17),
                          label: Text(tr('پشتیبانی و راهنما', 'Support & help')),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
        ),
      ]),
    );
  }
}

/// Compact server summary card used on the redesigned home screen.
class _ServerQuickCard extends StatelessWidget {
  const _ServerQuickCard({required this.controller, required this.onTap});

  final VpnController controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 12, 12),
      child: Row(children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: Palette.accent.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(Icons.public_rounded, color: Palette.accent, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('شبکه سرورها', 'Server network'),
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Palette.text)),
            const SizedBox(height: 3),
            Text(
              '${digits(controller.servers.length)} ${tr('سرور در دسترس', 'servers available')} · ${serversUpdatedAgo(controller.updatedAt)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: Palette.muted),
            ),
          ]),
        ),
        Icon(chevronEnd, color: Palette.accent),
      ]),
    );
  }
}

/// Floating-style bottom navigation: only the three destinations that exist today.
class _BottomDock extends StatelessWidget {
  const _BottomDock({required this.onHome, required this.onServers, required this.onSettings});

  final VoidCallback onHome;
  final VoidCallback onServers;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(18, 4, 18, 10),
        child: Container(
          height: 66,
          decoration: BoxDecoration(
            color: Palette.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Palette.border.withValues(alpha: 0.75)),
            boxShadow: Palette.isDark
                ? [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 22, offset: const Offset(0, 8))]
                : [BoxShadow(color: Palette.shadow, blurRadius: 16, offset: const Offset(0, 5))],
          ),
          child: Row(children: [
            Expanded(child: _DockItem(
              icon: Icons.home_rounded,
              label: tr('خانه', 'Home'),
              selected: true,
              onTap: onHome,
            )),
            Expanded(child: _DockItem(
              icon: Icons.dns_rounded,
              label: tr('سرورها', 'Servers'),
              onTap: onServers,
            )),
            Expanded(child: _DockItem(
              icon: Icons.tune_rounded,
              label: tr('تنظیمات', 'Settings'),
              onTap: onSettings,
            )),
          ]),
        ),
      ),
    );
  }
}

class _DockItem extends StatelessWidget {
  const _DockItem({required this.icon, required this.label, required this.onTap, this.selected = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Palette.accent : Palette.muted;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 21, color: color),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 10.5, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: color)),
          ],
        ),
      ),
    );
  }
}

/// A blurred, low-opacity color blob used purely as page-background atmosphere.
class _AmbientGlow extends StatelessWidget {
  const _AmbientGlow({required this.color, this.size = 230});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 60, sigmaY: 60),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.16)),
          ),
        ),
      );
}

/// "What's new" after an update, once; right-to-left Persian card.
class _WhatsNewCard extends StatelessWidget {
  const _WhatsNewCard({required this.info, required this.onClose});

  final WhatsNew info;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Container(
          padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 14, 4),
          decoration: BoxDecoration(
            color: Palette.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Palette.accent.withValues(alpha: 0.45)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('✨ به‌روزرسانی نسخهٔ ${info.version}',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Palette.text)),
            const SizedBox(height: 6),
            for (final item in info.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text('• $item', style: TextStyle(fontSize: 13, height: 1.5, color: Palette.text)),
              ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(onPressed: onClose, child: const Text('باشه')),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Owner announcement from the panel: small dismissible card, always right-to-left (the text is Persian).
class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner({required this.notice, required this.onClose});

  final AppNotice notice;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    // Saffron for warnings, lapis (lajvard) for info notices.
    final accent = notice.warning ? Palette.connecting : Palette.violet;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Container(
          padding: const EdgeInsetsDirectional.fromSTEB(14, 8, 4, 8),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: Palette.isDark ? 0.16 : 0.10),
            borderRadius: BorderRadius.circular(Palette.cardRadius),
            border: Border.all(color: accent.withValues(alpha: 0.40)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Icon(notice.warning ? Icons.warning_amber_rounded : Icons.campaign_outlined, size: 18, color: accent),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(notice.text, style: TextStyle(fontSize: 13, height: 1.5, color: Palette.text)),
                if (notice.link.isNotEmpty)
                  TextButton(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
                    onPressed: () => openLink(notice.link),
                    child: Text(notice.linkLabel.isEmpty ? 'باز کردن لینک' : notice.linkLabel),
                  ),
              ]),
            ),
            IconButton(
              tooltip: tr('بستن اطلاعیه', 'Close announcement'),
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
              icon: Icon(Icons.close_rounded, size: 18, color: Palette.muted),
            ),
          ]),
        ),
      ),
    );
  }
}

/// One plain sentence for errors in the simple view; the technical message stays in the log and advanced view.
String _friendlyError(String error) {
  if (error.contains('Administrator')) {
    return tr('این حالت دسترسی مدیر ویندوز می‌خواهد. برنامه را ببندید، روی آیکونش کلیک راست کنید و «Run as administrator» را بزنید.',
        'This mode needs Windows administrator rights. Close the app, right-click its icon and choose "Run as administrator".');
  }
  if (error.contains('کشور')) {
    return tr('سروری از این کشور در دسترس نیست. مکان را روی «خودکار» بگذارید.',
        'No server is available in this country. Set the location to "Automatic".');
  }
  return tr('وصل نشد. اینترنت خود را بررسی کنید و دوباره تلاش کنید.', "Couldn't connect. Check your internet and try again.");
}

/// Secondary "message support" link shown under a connection failure (simple and advanced views).
class _SupportButton extends StatelessWidget {
  const _SupportButton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: TextButton.icon(
        onPressed: () => openLink(telegramUrl),
        icon: const Icon(Icons.support_agent_rounded, size: 18),
        label: Text(tr('مشکل دارید؟ پیام به پشتیبانی', 'Having trouble? Message support')),
      ),
    );
  }
}

/// Simple view: one plain status line, or a friendly error with a big retry button (retries in automatic mode).
class _SimpleStatus extends StatelessWidget {
  const _SimpleStatus({required this.controller});

  final VpnController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final error = c.state == VpnState.disconnected ? c.error : null;
    if (error != null) {
      return Column(children: [
        Text(_friendlyError(error),
            textAlign: TextAlign.center, style: TextStyle(fontSize: 14.5, height: 1.6, color: Palette.errorText)),
        const SizedBox(height: 12),
        SizedBox(
          width: 260,
          height: 50,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Palette.accent,
              foregroundColor: Palette.bg,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Palette.pillRadius)),
            ),
            onPressed: () async {
              c.clearError();
              if (c.settings.transport != 'auto') await c.settings.update((x) => x.transport = 'auto');
              await c.connect();
            },
            icon: const Icon(Icons.refresh_rounded),
            label: Text(tr('دوباره تلاش کن', 'Try again'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ),
        const _SupportButton(),
      ]);
    }
    // Smart Connect shows its own race panel (progress, chips, leader) right above.
    if (c.state == VpnState.connecting && c.smart != null) return const SizedBox(height: 4);
    final line = switch (c.state) {
      VpnState.connected => c.exitInIran
          ? tr('متصل هستید (خروجی ایران است؛ بعضی سایت‌ها باز نمی‌شوند)', 'Connected (exit is in Iran; some sites will not open)')
          : tr('متصل هستید و اینترنت شما امن است', 'You are connected and protected'),
      VpnState.connecting => tr('در حال پیدا کردن بهترین سرور…', 'Finding the best server…'),
      VpnState.disconnecting => tr('در حال قطع اتصال…', 'Disconnecting…'),
      VpnState.disconnected => tr('برای اتصال، دکمه‌ی بالا را بزنید', 'Press the button above to connect'),
    };
    return Column(children: [
      Text(line,
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: c.state == VpnState.connected ? Palette.connected : Palette.muted)),
      if (c.state == VpnState.connecting && c.progress != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 60, vertical: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: c.progress, minHeight: 3, color: Palette.connecting, backgroundColor: Palette.raised),
          ),
        ),
    ]);
  }
}

/// Simple view: "مکان: خودکار (بهترین)" with a flag; opens the country list.
class _LocationCard extends StatelessWidget {
  const _LocationCard({required this.controller});

  final VpnController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final locked = c.state != VpnState.disconnected;
    final code = c.selectedCountry;
    final place = code == null ? tr('خودکار (بهترین)', 'Automatic (best)') : locationLabel(c);
    return Opacity(
      opacity: locked ? 0.6 : 1,
      child: AppCard(
        onTap: locked ? null : () => showLocationSheet(context, c),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          FlagBadge(code: code, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Text('${tr('مکان', 'Location')}: $place',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: Palette.text)),
          ),
          Icon(chevronEnd, color: Palette.muted),
        ]),
      ),
    );
  }
}

/// Logo + name + status pill, gear at the end.
class _Header extends StatelessWidget {
  const _Header({required this.controller, required this.onSettings});

  final VpnController controller;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final (label, color, glow) = _stateLook(controller);
    return Row(children: [
      const _Logo(),
      const SizedBox(width: 10),
      Text('MolidoVPN',
          textDirection: TextDirection.ltr,
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: Palette.text)),
      const SizedBox(width: 10),
      Flexible(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: Palette.raised, borderRadius: BorderRadius.circular(Palette.pillRadius)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: glow ? color : Palette.muted,
                boxShadow: glow ? [BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: 6)] : null,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: glow ? color : Palette.text)),
            ),
          ]),
        ),
      ),
      const Spacer(),
      IconButton(
        tooltip: tr('حمایت مالی', 'Donate'),
        onPressed: () => showDonateDialog(context),
        icon: const Icon(Icons.favorite_rounded, color: Colors.pinkAccent, size: 20),
      ),
      IconButton(
        tooltip: tr('تنظیمات', 'Settings'),
        onPressed: onSettings,
        icon: Icon(Icons.settings_rounded, color: Palette.text),
      ),
    ]);
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.asset(
        'assets/icon/icon.png',
        width: 32,
        height: 32,
        errorBuilder: (context, error, stack) => Container(
          width: 32,
          height: 32,
          color: Palette.accent.withValues(alpha: 0.16),
          child: Icon(Icons.shield_rounded, size: 20, color: Palette.accent),
        ),
      ),
    );
  }
}

(String, Color, bool) _stateLook(VpnController c) {
  final failed = c.state == VpnState.disconnected && c.error != null;
  return switch (c.state) {
    VpnState.connected => (tr('متصل', 'Connected'), Palette.connected, true),
    VpnState.connecting => (tr('در حال اتصال...', 'Connecting...'), Palette.connecting, true),
    VpnState.disconnecting => (tr('در حال قطع', 'Disconnecting'), Palette.connecting, true),
    VpnState.disconnected =>
      failed ? (tr('اتصال ناموفق', 'Failed'), Palette.danger, true) : (tr('متصل نیست', 'Not connected'), Palette.muted, false),
  };
}

class _UpdateLine extends StatelessWidget {
  const _UpdateLine({required this.controller});

  final VpnController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: AppCard(
        onTap: c.installUpdate,
        color: Palette.accent.withValues(alpha: 0.12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          Icon(Icons.system_update_outlined, size: 18, color: Palette.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              c.updateProgress == null
                  ? tr('نسخه‌ی ${c.update!.version} آماده‌ی نصب است', 'Version ${c.update!.version} is ready to install')
                  : tr('دانلود ${((c.updateProgress ?? 0) * 100).toStringAsFixed(0)}٪',
                      'Downloading ${((c.updateProgress ?? 0) * 100).toStringAsFixed(0)}%'),
              style: TextStyle(color: Palette.accent, fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          Icon(chevronEnd, color: Palette.accent),
        ]),
      ),
    );
  }
}

/// Android OrbitDialView: 190 px squircle, 64 corner, 4 px sweep-gradient ring, glow that breathes while
/// connecting, power glyph with a caption, or the session timer while connected.
class _Squircle extends StatefulWidget {
  const _Squircle({required this.controller});

  final VpnController controller;

  @override
  State<_Squircle> createState() => _SquircleState();
}

class _SquircleState extends State<_Squircle> with SingleTickerProviderStateMixin {
  static const double _size = 154, _radius = 52, _ring = 4;
  bool _down = false;
  late final _loop = AnimationController(vsync: this, duration: const Duration(milliseconds: 1150));
  Timer? _clock;

  @override
  void dispose() {
    _clock?.cancel();
    _loop.dispose();
    super.dispose();
  }

  void _syncClock(bool connected) {
    if (connected && _clock == null) {
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!connected && _clock != null) {
      _clock!.cancel();
      _clock = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final busy = c.state == VpnState.connecting || c.state == VpnState.disconnecting;
    final connected = c.state == VpnState.connected;
    final failed = c.state == VpnState.disconnected && c.error != null;
    final idle = c.state == VpnState.disconnected && !failed;
    final animate = busy && !Palette.reduceMotion;
    if (animate && !_loop.isAnimating) _loop.repeat();
    if (!animate && _loop.isAnimating) _loop.stop();
    _syncClock(connected);

    final (Color start, Color end) = failed
        ? (Palette.danger, Color.lerp(Palette.danger, Palette.connecting, 0.35)!)
        : busy
            ? (Palette.connecting, Palette.accent)
            : (Palette.accent, Palette.connected);
    final ringAlpha = idle ? 0.6 : 1.0;
    final iconColor = connected
        ? Palette.connected
        : (busy ? Palette.connecting : (failed ? Palette.danger : Palette.accent));
    final caption = switch (c.state) {
      VpnState.connecting => c.progress != null
          ? tr('در حال اتصال ${digits((c.progress! * 100).round())}٪', 'CONNECTING ${(c.progress! * 100).round()}%')
          : tr('در حال اتصال...', 'CONNECTING'),
      VpnState.disconnecting => tr('در حال قطع...', 'STOPPING'),
      VpnState.connected => tr('متصل شد', 'Connected'),
      _ => failed ? tr('تلاش مجدد', 'RETRY') : tr('برای اتصال لمس کنید', 'TAP TO CONNECT'),
    };
    final captionColor = failed ? Palette.errorText : (busy ? Palette.connecting : Palette.muted);
    final timer = connected && c.connectedAt != null ? formatDuration(DateTime.now().difference(c.connectedAt!)) : null;

    return Semantics(
      button: true,
      label: connected ? tr('قطع اتصال', 'Disconnect') : (busy ? tr('در حال اتصال', 'Connecting') : tr('اتصال', 'Connect')),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) {
            setState(() => _down = false);
            HapticFeedback.selectionClick();
            c.toggle();
          },
          child: AnimatedScale(
            scale: _down ? 0.965 : 1,
            duration: Duration(milliseconds: _down ? 110 : 190),
            curve: Curves.easeOutCubic,
            child: SizedBox.square(
              dimension: _size + 56,
              child: Center(
                child: AnimatedBuilder(
                  animation: _loop,
                  builder: (context, child) {
                    final f = animate ? _loop.value : 0.0;
                    final pulse = animate ? (f < 0.5 ? f * 2 : (1 - f) * 2) : (busy ? 0.5 : 0.0);
                    final (Color glow, double alpha, double blur) = busy
                        ? (Palette.connecting, 0.28 + 0.40 * pulse, 16 + 14 * pulse)
                        : connected
                            ? (Palette.connected, 0.30, 22.0)
                            : failed
                                ? (Palette.danger, 0.24, 14.0)
                                : (Palette.accent, 0.16, 14.0);
                    return Container(
                      width: _size,
                      height: _size,
                      padding: const EdgeInsets.all(_ring),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(_radius),
                        gradient: SweepGradient(
                          colors: [
                            start.withValues(alpha: ringAlpha),
                            end.withValues(alpha: ringAlpha),
                            start.withValues(alpha: ringAlpha),
                          ],
                          stops: const [0, 0.5, 1],
                          transform: GradientRotation(f * 2 * math.pi),
                        ),
                        boxShadow: [BoxShadow(color: glow.withValues(alpha: alpha), blurRadius: blur * 2, spreadRadius: 1)],
                      ),
                      child: child,
                    );
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(_radius - _ring),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        // Opaque: a translucent fill let the bright sweep ring behind it show through
                        // and washed out the caption and timer.
                        colors: [Palette.raised, Palette.bg],
                      ),
                    ),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.power_settings_new_rounded, size: 56, color: iconColor),
                      const SizedBox(height: 10),
                      if (timer != null) ...[
                        Text(timer,
                            textDirection: TextDirection.ltr,
                            style: TextStyle(
                                fontSize: 22,
                                fontFamily: Palette.monoFamily,
                                fontFamilyFallback: Palette.monoFallback,
                                letterSpacing: Palette.spacing(0.12, 22),
                                color: Palette.text)),
                        Text(tr('زمان اتصال', 'SESSION'),
                            style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w500,
                                letterSpacing: Palette.spacing(0.12, 9.5),
                                color: Palette.muted)),
                      ] else
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(caption,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: Palette.spacing(0.12, 12),
                                  color: captionColor)),
                        ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Android ExitNodeCard: flag tile, caption, big monospace IP, country line, sparkline. Opens the location picker.
class _ExitCard extends StatelessWidget {
  const _ExitCard({required this.controller, required this.network, required this.latency});

  final VpnController controller;
  final NetworkInfo network;
  final List<int> latency;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final locked = c.state != VpnState.disconnected;
    final tunnelled = c.state == VpnState.connected;
    final ip = network.ip;
    final code = network.countryCode;
    final country = code == null ? '' : code.toUpperCase();
    final measuring = ip == null && c.state != VpnState.disconnected;
    final location = measuring
        ? tr('در حال خواندن از داخل تونل', 'reading from inside the tunnel')
        : country.isNotEmpty && tunnelled
            ? '$country · ${tr('از تونل', 'tunnelled')}'
            : country.isNotEmpty
                ? country
                : (tunnelled ? tr('از تونل', 'tunnelled') : tr('بدون تونل', 'not tunnelled'));
    final radius = BorderRadius.circular(18);
    final fill = Color.lerp(Palette.surface, Palette.text, 0.03)!;
    return Semantics(
      button: !locked,
      label: tr('انتخاب سرور یا کشور', 'Choose server or country'),
      child: Material(
        color: fill,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: Palette.text.withValues(alpha: 0.09)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: locked ? null : () => showLocationSheet(context, c),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(11, 8, 12, 8),
            child: Row(children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Color.lerp(Palette.surface, Palette.bg, 0.5),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Palette.text.withValues(alpha: 0.10)),
                ),
                child: FlagBadge(code: tunnelled ? (c.current?.countryCode ?? code) : code, size: 30),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tunnelled ? tr('نود خروجی', 'EXIT NODE') : tr('آی‌پی شما', 'YOUR IP'),
                      style: TextStyle(
                          fontSize: L10n.en ? 9.5 : 10.5,
                          fontWeight: FontWeight.w500,
                          letterSpacing: Palette.spacing(0.14, 9.5),
                          color: Palette.faint.withValues(alpha: 0.95))),
                  const SizedBox(height: 2),
                  Text(
                    measuring ? tr('در حال سنجش…', 'measuring…') : (ip ?? tr('آی‌پی در دسترس نیست', 'IP unavailable')),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textDirection: TextDirection.ltr,
                    style: TextStyle(
                      fontSize: ip == null ? 13.0 : (ip.length > 20 ? 12.5 : 17.0),
                      fontWeight: FontWeight.w500,
                      fontFamily: Palette.monoFamily,
                      fontFamilyFallback: Palette.monoFallback,
                      color: Palette.text,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(location,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: Palette.faint.withValues(alpha: 0.9))),
                ]),
              ),
              SizedBox(width: 52, height: 24, child: CustomPaint(painter: _Sparkline(List.of(latency), Palette.accent))),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Smooth line over recent latency samples; a calm sine wave until there are enough samples.
class _Sparkline extends CustomPainter {
  _Sparkline(this.values, this.color);

  final List<int> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (values.length < 2) {
      for (var i = 0; i <= 26; i++) {
        final x = size.width * i / 26;
        final y = size.height / 2 + math.sin(i / 26 * 3 * math.pi) * size.height * 0.28;
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
    } else {
      final peak = values.reduce(math.max).toDouble();
      final low = values.reduce(math.min).toDouble();
      final span = math.max(1.0, peak - low);
      for (var i = 0; i < values.length; i++) {
        final x = size.width * i / (values.length - 1);
        final y = size.height - 2 - ((values[i] - low) / span) * (size.height - 4);
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = color);
  }

  @override
  bool shouldRepaint(_Sparkline old) => true;
}

/// Mode rail: three equal-width chips per row (Auto, V2Ray, WARP / Psiphon, Tor).
