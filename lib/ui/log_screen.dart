import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../core/install_id.dart';

import '../core/app_log.dart';
import '../core/engine.dart';
import '../core/network_info.dart';
import '../core/vpn_controller.dart';
import 'aurora_background.dart';
import 'glass.dart';
import 'strings.dart';
import 'style.dart';

/// Short "report a problem" text for support: version, OS, ISP bucket, settings and the recent log with
/// server links, IP addresses and UUIDs removed.
Future<String> redactedProblemReport(VpnController c) async {
  final info = await PackageInfo.fromPlatform();
  final s = c.settings;
  String redact(String text) => text
      .replaceAll(RegExp(r'[a-zA-Z][a-zA-Z0-9+.-]*://\S+'), '<link>')
      .replaceAll(RegExp(r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'), '<uuid>')
      .replaceAllMapped(RegExp(r'\b(\d{1,3})\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'),
          (m) => m[0] == '127.0.0.1' ? m[0]! : '${m[1]}.x.x.x');
  final lines = AppLog.dump().split('\n');
  return [
    'MolidoVPN problem report',
    'install ${InstallId.current}',
    'version ${info.version} (${info.buildNumber}) · ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    'isp=${NetworkInfo.operatorBucket ?? 'unknown'} state=${c.state.name} mode=${c.selectedCountry ?? 'auto'} '
        'transport=${s.transport}',
    'tun=${s.tunMode} fragment=${s.fragment} warp=${s.warp} bypassIran=${s.bypassIran} dns=${s.dnsPreset}',
    'last error: ${c.error ?? '-'}',
    '----',
    redact(lines.skip(lines.length > 150 ? lines.length - 150 : 0).join('\n')),
  ].join('\n');
}

/// Diagnostic report the user can copy and send when something does not work.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key, required this.controller});

  final VpnController controller;

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  Future<String> _report() async {
    final info = await PackageInfo.fromPlatform();
    final c = widget.controller;
    final s = c.settings;
    return [
      'MolidoVPN ${info.version} (${info.buildNumber})',
      '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'state=${c.state.name} servers=${c.servers.length} locations=${c.countries.length} mode=${c.selectedCountry ?? 'auto'}',
      'fragment=${s.fragment} warp=${s.warp} bypassIran=${s.bypassIran} tun=${s.tunMode} proxyOnly=${s.proxyOnly} '
          'pool=${s.poolSize} timeout=${s.timeoutSeconds}s testUrl=${s.testUrl}',
      'last error: ${c.error ?? '-'}',
      '----',
      AppLog.dump(),
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AuroraBackground(
        colors: Palette.forState(VpnState.disconnected),
        child: SafeArea(
          child: FutureBuilder<String>(
            future: _report(),
            builder: (context, snap) {
              final text = snap.data ?? '';
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Row(children: [
                      Glass(
                        radius: 16,
                        padding: const EdgeInsets.all(10),
                        onTap: () => Navigator.of(context).pop(),
                        child: Icon(backIcon, color: Palette.text),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(tr('گزارش خطا', 'Error report'), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Palette.text)),
                      ),
                      IconButton(
                        tooltip: tr('پاک کردن', 'Clear'),
                        onPressed: () => setState(AppLog.clear),
                        icon: Icon(Icons.delete_sweep_rounded, color: Palette.muted),
                      ),
                    ]),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Glass(
                        radius: 20,
                        padding: const EdgeInsets.all(12),
                        child: SingleChildScrollView(
                          reverse: true,
                          child: SelectableText(
                            text,
                            textDirection: TextDirection.ltr,
                            style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.5, color: Palette.text),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: text.isEmpty
                            ? null
                            : () {
                                Clipboard.setData(ClipboardData(text: text));
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                  content: Text(tr('گزارش کپی شد؛ آن را در پیام‌رسان برای پشتیبان بفرستید',
                                      'Report copied; send it to support in a messenger')),
                                  behavior: SnackBarBehavior.floating,
                                ));
                              },
                        style: FilledButton.styleFrom(
                          backgroundColor: Palette.accent,
                          foregroundColor: Palette.bg,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Palette.pillRadius)),
                        ),
                        icon: const Icon(Icons.copy_rounded),
                        label: Text(tr('کپی گزارش', 'Copy report'), style: const TextStyle(fontWeight: FontWeight.w800)),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
