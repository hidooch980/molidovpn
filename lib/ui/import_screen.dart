import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/amnezia.dart';
import '../core/engine.dart';
import '../core/server.dart';
import '../core/vpn_controller.dart';
import 'aurora_background.dart';
import 'glass.dart';
import 'strings.dart';
import 'style.dart';

/// "My configs": share links pasted (several lines or base64), read from a .txt/.conf file, scanned as a QR code
/// (Android camera) or pulled from the user's own subscription URLs; they appear as their own location.
class ImportScreen extends StatelessWidget {
  const ImportScreen({super.key, required this.controller});

  final VpnController controller;

  void _toast(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));

  Future<void> _add(BuildContext context, String? text) async {
    if (text == null || text.trim().isEmpty) return;
    final added = await controller.addManualConfigs(text);
    if (context.mounted) {
      _toast(context, added == 0 ? tr('کانفیگ معتبری پیدا نشد', 'No valid config found') : tr('$added کانفیگ اضافه شد', '$added configs added'));
    }
  }

  /// .txt with links, or an AmneziaWG / WireGuard .conf (saved as the personal Amnezia config).
  Future<void> _fromFile(BuildContext context) async {
    String text;
    try {
      final file = await openFile(acceptedTypeGroups: const [
        XTypeGroup(label: 'Config', extensions: ['txt', 'conf']),
      ]);
      if (file == null) return;
      text = await file.readAsString();
    } catch (_) {
      if (context.mounted) _toast(context, tr('خواندن فایل ممکن نشد', 'Could not read the file'));
      return;
    }
    if (!context.mounted) return;
    if (!text.contains('[Interface]')) return _add(context, text);
    try {
      final config = AmneziaConfig.parse(text);
      await controller.settings.update((x) => x
        ..amneziaConfig = jsonEncode(config.toJson())
        ..amneziaEndpoint = '');
      if (context.mounted) {
        _toast(context, tr('کانفیگ AmneziaWG ذخیره شد؛ حالت «Amnezia» از آن استفاده می‌کند',
            'AmneziaWG config saved; the Amnezia mode uses it'));
      }
    } on FormatException catch (e) {
      if (context.mounted) _toast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AuroraBackground(
        colors: Palette.forState(VpnState.disconnected),
        child: SafeArea(
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final mine = controller.servers.where((s) => s.countryCode == VpnController.manualCode).toList();
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    children: [
                      Row(children: [
                        Glass(
                          radius: 16,
                          padding: const EdgeInsets.all(10),
                          onTap: () => Navigator.of(context).pop(),
                          child: Icon(backIcon, color: Palette.text),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(tr('کانفیگ‌های من', 'My configs'), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Palette.text)),
                            Text(tr('VLESS، VMess، Trojan، SS، Hysteria2، TUIC، AnyTLS، WireGuard، SOCKS، HTTP', 'VLESS, VMess, Trojan, SS, Hysteria2, TUIC, AnyTLS, WireGuard, SOCKS, HTTP'),
                                style: TextStyle(fontSize: 11.5, color: Palette.muted)),
                          ]),
                        ),
                      ]),
                      const SizedBox(height: 18),
                      Row(children: [
                        Expanded(
                          child: _BigButton(
                            icon: Icons.content_paste_rounded,
                            label: tr('چسباندن از کلیپ‌بورد', 'Paste from clipboard'),
                            colors: [Palette.accent, Palette.connected],
                            onTap: () async {
                              final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
                              if (context.mounted) await _add(context, text);
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _BigButton(
                            icon: Icons.file_open_rounded,
                            label: tr('از فایل', 'From file'),
                            colors: [Palette.connected, Palette.accent],
                            onTap: () => _fromFile(context),
                          ),
                        ),
                        if (Platform.isAndroid) ...[
                          const SizedBox(width: 12),
                          Expanded(
                            child: _BigButton(
                              icon: Icons.qr_code_scanner_rounded,
                              label: tr('اسکن QR', 'Scan QR'),
                              colors: [Palette.connected, Palette.accent],
                              onTap: () async {
                                final value = await Navigator.of(context)
                                    .push<String>(MaterialPageRoute(builder: (_) => const _ScannerPage()));
                                if (context.mounted) await _add(context, value);
                              },
                            ),
                          ),
                        ],
                      ]),
                      const SizedBox(height: 10),
                      Text(
                        tr('لینک اشتراک (subscription) هم پشتیبانی می‌شود: متن base64 یا چند لینک در چند خط را بچسبانید.',
                            'Subscriptions work too: paste base64 text or several links on separate lines.'),
                        style: TextStyle(fontSize: 12, color: Palette.muted, height: 1.6),
                      ),
                      const SizedBox(height: 14),
                      _SubscriptionBox(controller: controller),
                      const SizedBox(height: 10),
                      _PublicSourceBox(controller: controller),
                      const SizedBox(height: 14),
                      if (mine.isNotEmpty)
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: TextButton.icon(
                            onPressed: controller.pinging ? null : () => controller.probeServers(mine),
                            icon: controller.pinging
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.speed_rounded),
                            label: Text(tr('تست پینگ همه', 'Ping all')),
                          ),
                        ),
                      if (mine.isEmpty)
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: 40),
                          child: Center(child: Text(tr('هنوز کانفیگی اضافه نکرده‌اید', 'You have not added any configs yet'), style: TextStyle(color: Palette.muted))),
                        ),
                      for (final s in mine) _ConfigTile(server: s, controller: controller),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({required this.icon, required this.label, required this.colors, required this.onTap});

  final IconData icon;
  final String label;
  final List<Color> colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Palette.cardRadius),
        child: Ink(
          padding: const EdgeInsets.symmetric(vertical: 20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Palette.cardRadius),
            gradient: LinearGradient(colors: colors),
          ),
          child: Column(children: [
            Icon(icon, color: Palette.bg, size: 30),
            const SizedBox(height: 8),
            Text(label, style: TextStyle(color: Palette.bg, fontWeight: FontWeight.w800)),
          ]),
        ),
      ),
    );
  }
}

class _ConfigTile extends StatelessWidget {
  const _ConfigTile({required this.server, required this.controller});

  final Server server;
  final VpnController controller;

  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(server.uri)?.host ?? '';
    final delay = controller.delays[server.uri];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Glass(
        radius: 18,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        onTap: () {
          Navigator.of(context).popUntil((r) => r.isFirst);
          controller.connectTo(server);
        },
        child: Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: Palette.fill, borderRadius: BorderRadius.circular(8)),
            child: Text(server.protocolLabel, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Palette.accent)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(server.remark.isEmpty ? tr('بدون نام', 'Unnamed') : server.remark,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Palette.text, fontWeight: FontWeight.w700)),
              if (host.isNotEmpty)
                Text(host, maxLines: 1, textDirection: TextDirection.ltr, style: TextStyle(fontSize: 11, color: Palette.muted)),
            ]),
          ),
          if (delay != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 4),
              child: Text(delay > 0 ? '${digits(delay)} ms' : tr('ناموفق', 'failed'),
                  style: TextStyle(fontSize: 12, color: delay > 0 ? Palette.connected : Palette.danger)),
            ),
          IconButton(
            tooltip: tr('حذف', 'Delete'),
            onPressed: () => controller.removeManualConfig(server.uri),
            icon: Icon(Icons.delete_outline_rounded, color: Palette.danger),
          ),
        ]),
      ),
    );
  }
}

/// The user's own subscription URLs: add (downloaded once to validate), list with link counts, remove.
/// Links are refreshed in the background every hour.
class _SubscriptionBox extends StatefulWidget {
  const _SubscriptionBox({required this.controller});

  final VpnController controller;

  @override
  State<_SubscriptionBox> createState() => _SubscriptionBoxState();
}

class _SubscriptionBoxState extends State<_SubscriptionBox> {
  final _url = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _addUrl() async {
    final url = _url.text.trim();
    if (url.isEmpty || _busy) return;
    setState(() => _busy = true);
    final count = await widget.controller.addUserSubscription(url);
    if (!mounted) return;
    setState(() => _busy = false);
    if (count > 0) _url.clear();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text(count > 0
          ? tr('${digits(count)} کانفیگ از لینک اشتراک دریافت شد', '$count configs received from the subscription')
          : tr('لینک اشتراک دریافت نشد یا کانفیگ معتبری نداشت',
              'The subscription could not be downloaded or had no valid configs')),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Glass(
      radius: 18,
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('لینک اشتراک شخصی', 'My subscription links'),
            style: TextStyle(fontWeight: FontWeight.w800, color: Palette.text)),
        const SizedBox(height: 2),
        Text(tr('هر ساعت خودکار به‌روز می‌شود.', 'Refreshed automatically every hour.'),
            style: TextStyle(fontSize: 11.5, color: Palette.muted)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _url,
              textDirection: TextDirection.ltr,
              style: TextStyle(color: Palette.text, fontSize: 13),
              onSubmitted: (_) => _addUrl(),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'https://…',
                hintStyle: TextStyle(color: Palette.muted),
                filled: true,
                fillColor: Palette.fill,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Palette.pillRadius), borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _busy
              ? const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
              : IconButton(
                  tooltip: tr('افزودن', 'Add'), onPressed: _addUrl, icon: Icon(Icons.add_link_rounded, color: Palette.accent)),
        ]),
        for (final url in c.settings.userSubscriptions)
          Row(children: [
            Expanded(
              child: Text(url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textDirection: TextDirection.ltr,
                  style: TextStyle(fontSize: 12, color: Palette.text)),
            ),
            Text(tr('${digits(c.userSubscriptionCount(url))} کانفیگ', '${c.userSubscriptionCount(url)} configs'),
                style: TextStyle(fontSize: 11.5, color: Palette.muted)),
            IconButton(
              tooltip: tr('حذف', 'Delete'),
              onPressed: () => c.removeUserSubscription(url),
              icon: Icon(Icons.delete_outline_rounded, color: Palette.danger, size: 20),
            ),
          ]),
      ]),
    );
  }
}

/// Public profile feeds are managed independently from personal/private subscriptions.
class _PublicSourceBox extends StatefulWidget {
  const _PublicSourceBox({required this.controller});
  final VpnController controller;
  @override
  State<_PublicSourceBox> createState() => _PublicSourceBoxState();
}

class _PublicSourceBoxState extends State<_PublicSourceBox> {
  final _url = TextEditingController();
  bool _busy = false;
  @override
  void dispose() { _url.dispose(); super.dispose(); }

  Future<void> _add() async {
    final url = _url.text.trim();
    if (url.isEmpty || _busy) return;
    setState(() => _busy = true);
    final count = await widget.controller.addPublicSource(url);
    if (!mounted) return;
    setState(() => _busy = false);
    if (count > 0) _url.clear();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text(count > 0
          ? tr('${digits(count)} پروفایل از منبع عمومی اضافه شد', '$count profiles added from public source')
          : tr('منبع در دسترس نبود یا پروفایل معتبری نداشت', 'Source unavailable or contained no supported profiles')),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Glass(
      radius: 18,
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(tr('منابع عمومی سرور', 'Public server sources'),
              style: TextStyle(fontWeight: FontWeight.w800, color: Palette.text))),
          TextButton.icon(
            onPressed: _busy ? null : () => c.refreshPublicSources(),
            icon: const Icon(Icons.refresh_rounded, size: 17),
            label: Text(tr('به‌روزرسانی', 'Refresh')),
          ),
        ]),
        Text(tr('فیدهای عمومی HTTP(S) را اضافه کنید. منابع هر ساعت به‌روزرسانی می‌شوند؛ نسخه سالم قبلی هنگام خطا حفظ می‌شود.',
            'Add public HTTP(S) feeds. Sources refresh hourly; the last good copy is kept if a source fails.'),
            style: TextStyle(fontSize: 11.5, color: Palette.muted, height: 1.5)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextField(
            controller: _url,
            textDirection: TextDirection.ltr,
            style: TextStyle(color: Palette.text, fontSize: 13),
            onSubmitted: (_) => _add(),
            decoration: InputDecoration(
              isDense: true, hintText: 'https://…', hintStyle: TextStyle(color: Palette.muted),
              filled: true, fillColor: Palette.fill,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(Palette.pillRadius), borderSide: BorderSide.none),
            ),
          )),
          const SizedBox(width: 8),
          _busy
              ? const Padding(padding: EdgeInsets.all(10), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
              : IconButton(tooltip: tr('افزودن منبع', 'Add source'), onPressed: _add, icon: Icon(Icons.add_link_rounded, color: Palette.accent)),
        ]),
        for (final url in c.settings.publicSources)
          Row(children: [
            Expanded(child: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis, textDirection: TextDirection.ltr,
                style: TextStyle(fontSize: 12, color: Palette.text))),
            Text(tr('${digits(c.publicSourceCount(url))} پروفایل', '${c.publicSourceCount(url)} profiles'),
                style: TextStyle(fontSize: 11.5, color: Palette.muted)),
            IconButton(tooltip: tr('حذف منبع', 'Remove source'), onPressed: () => c.removePublicSource(url),
                icon: Icon(Icons.delete_outline_rounded, color: Palette.danger, size: 20)),
          ]),
      ]),
    );
  }
}

class _ScannerPage extends StatefulWidget {
  const _ScannerPage();

  @override
  State<_ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<_ScannerPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: Text(tr('اسکن QR کانفیگ', 'Scan config QR'))),
      body: Stack(children: [
        MobileScanner(
          onDetect: (capture) {
            final value = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
            if (value == null || _done) return;
            _done = true;
            Navigator.of(context).pop(value);
          },
        ),
        Center(
          child: Container(
            width: 250,
            height: 250,
            decoration: BoxDecoration(
              border: Border.all(color: Palette.accent, width: 3),
              borderRadius: BorderRadius.circular(28),
            ),
          ),
        ),
      ]),
    );
  }
}
