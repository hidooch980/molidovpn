import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/engine.dart';
import '../core/server.dart';
import '../core/settings.dart';
import '../core/speed_test.dart';
import '../core/vpn_controller.dart';
import '../core/win_startup.dart';
import '../core/windows_engine.dart';
import 'amnezia_import.dart';
import 'apps_screen.dart';
import 'help_screen.dart';
import 'import_screen.dart';
import 'log_screen.dart';
import 'strings.dart';
import 'style.dart';
import 'support.dart';
import 'usage_screen.dart';
import 'widgets.dart';

/// Settings tab: section headers over grouped rounded cards. Secondary screens (configs, usage, logs, help) live here.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});

  final VpnController controller;

  AppSettings get s => controller.settings;

  /// Theme/language switches rebuild the whole app; keep the Settings tab selected across the rebuild.
  void _changeAppearance(Future<void> Function() change) {
    AppNav.tab = 2;
    change();
  }

  static const _androidNotice = 'The Android app is based on the open-source MSN-GUARD project (AGPL-3.0). '
      'Source: https://github.com/hidooch980/molidovpn-android';

  void _toast(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));
  }

  /// "آخرین اسکن: N دقیقه پیش · M سرور سالم" for the background scanner row.
  String _scanSummary() {
    final at = controller.lastScanAt;
    if (at == null) {
      return tr('هر ساعت همه سرورها از اینترنت شما تست می‌شوند؛ هنوز اسکنی انجام نشده',
          'Tests every server from your internet hourly; no scan yet');
    }
    final minutes = DateTime.now().difference(at).inMinutes;
    final healthy = controller.lastScanHealthy;
    return tr('آخرین اسکن: $minutes دقیقه پیش · $healthy سرور سالم',
        'Last scan: $minutes min ago · $healthy working servers');
  }

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    return PageShell(
      title: tr('تنظیمات', 'Settings'),
      showBack: true,
      child: ListenableBuilder(
        listenable: Listenable.merge([controller, s]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            if (controller.state != VpnState.disconnected)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  Icon(Icons.info_outline_rounded, size: 16, color: Palette.muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(tr('تغییرات اتصال از اتصال بعدی اعمال می‌شوند.', 'Connection changes apply from the next connection.'),
                        style: TextStyle(fontSize: 12.5, color: Palette.muted)),
                  ),
                ]),
              ),

            SectionHeader(tr('تنظیمات اصلی', 'Main settings')),
            CardGroup(children: [
              ChoiceSettingRow<String>(
                icon: Icons.translate_rounded,
                title: tr('زبان', 'Language'),
                options: const {'fa': 'فارسی', 'en': 'English'},
                value: s.language,
                onChanged: (v) => _changeAppearance(() => s.update((x) => x.language = v)),
              ),
              ChoiceSettingRow<String>(
                icon: Icons.brightness_6_outlined,
                title: tr('تم', 'Theme'),
                options: {'system': tr('خودکار', 'System'), 'light': tr('روشن', 'Light'), 'dark': tr('تیره', 'Dark')},
                value: s.themeMode,
                onChanged: (v) => _changeAppearance(() => s.update((x) => x.themeMode = v)),
              ),
              SwitchSettingRow(
                icon: Icons.bolt_rounded,
                title: tr('اتصال خودکار', 'Auto-connect'),
                subtitle: tr('با باز شدن برنامه، پس از دریافت سرورها خودش وصل می‌شود',
                    'Connects by itself when the app opens and servers are loaded'),
                value: s.connectOnLaunch,
                onChanged: (v) => s.update((x) => x.connectOnLaunch = v),
              ),
              if (Platform.isWindows)
                SwitchSettingRow(
                  icon: Icons.power_settings_new_rounded,
                  title: tr('اجرا با روشن شدن ویندوز', 'Launch at Windows startup'),
                  subtitle: tr('همراه با «اتصال خودکار»، از همان ابتدای روشن شدن ویندوز وصل هستید',
                      'Together with auto-connect you are protected right after Windows starts'),
                  value: s.launchAtStartup,
                  onChanged: (v) {
                    WinStartup.setEnabled(v);
                    s.update((x) => x.launchAtStartup = v);
                  },
                ),
              SwitchSettingRow(
                icon: Icons.flag_outlined,
                title: tr('سایت‌های ایرانی مستقیم', 'Iranian sites direct'),
                subtitle: tr('دامنه‌های .ir و شبکه‌ی محلی از VPN عبور نمی‌کنند (سریع‌تر، بانک‌ها کار می‌کنند)',
                    '.ir domains and the local network bypass the VPN (faster, banks work)'),
                value: s.bypassIran,
                onChanged: (v) => s.update((x) {
                  x.bypassIran = v;
                  // Turning it on (again) enables the full Iranian IP/domain lists too.
                  if (v) x.iranRuleSets = true;
                }),
              ),
              const TelegramSupportRow(),
              NavSettingRow(
                icon: Icons.favorite_outline_rounded,
                title: tr('حمایت مالی', 'Donate'),
                onTap: () => showDonateDialog(context),
              ),
              FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (context, snap) => NavSettingRow(
                  icon: Icons.verified_outlined,
                  title: tr('نسخه', 'Version'),
                  value: snap.data?.version ?? '…',
                  ltrValue: true,
                ),
              ),
              NavSettingRow(
                icon: Icons.system_update_outlined,
                title: tr('بررسی به‌روزرسانی', 'Check for updates'),
                onTap: () async {
                  final u = await controller.checkUpdate();
                  if (!context.mounted) return;
                  if (u == null) {
                    _toast(context, tr('برنامه به‌روز است', 'The app is up to date'));
                  } else {
                    await controller.installUpdate();
                  }
                },
              ),
            ]),

            const SizedBox(height: 16),
            _AdvancedSettings(children: [
            SectionHeader(tr('ظاهر', 'Appearance')),
            CardGroup(children: [
              SwitchSettingRow(
                icon: Icons.animation_rounded,
                title: tr('کاهش انیمیشن', 'Reduce motion'),
                subtitle: tr('برای کامپیوترها و گوشی‌های ضعیف روان‌تر', 'Smoother on slow computers and phones'),
                value: s.reduceMotion,
                onChanged: (v) => _changeAppearance(() => s.update((x) => x.reduceMotion = v)),
              ),
            ]),

            SectionHeader(tr('شروع و اتصال خودکار', 'Startup & auto-connect')),
            CardGroup(children: [
              SwitchSettingRow(
                icon: Icons.autorenew_rounded,
                title: tr('اتصال دوباره‌ی خودکار', 'Auto-reconnect'),
                subtitle: tr('اگر اتصال قطع شد، بهترین سرور بعدی را وصل کن', 'If the connection drops, connect the next best server'),
                value: s.autoReconnect,
                onChanged: (v) => s.update((x) => x.autoReconnect = v),
              ),
              if (Platform.isWindows)
                SwitchSettingRow(
                  icon: Icons.alt_route_rounded,
                  title: tr('V2Ray از روی Psiphon', 'V2Ray over Psiphon'),
                  subtitle: tr('در حالت خودکار اگر سرورهای V2Ray مستقیم وصل نشدند، از داخل Psiphon به آن‌ها وصل می‌شود (خروجی خارج از ایران)',
                      'In automatic mode, when V2Ray servers fail directly, they are dialed through Psiphon (exit outside Iran)'),
                  value: s.v2rayOverPsiphon,
                  onChanged: (v) => s.update((x) => x.v2rayOverPsiphon = v),
                ),
              SwitchSettingRow(
                icon: Icons.schedule_rounded,
                title: tr('زمان‌بندی اتصال', 'Scheduled connection'),
                subtitle: tr('از ${s.scheduleFrom} وصل و در ${s.scheduleTo} قطع می‌شود (برنامه باید باز باشد)',
                    'Connects at ${s.scheduleFrom} and disconnects at ${s.scheduleTo} (app must be open)'),
                value: s.scheduleEnabled,
                onChanged: (v) => s.update((x) => x.scheduleEnabled = v),
              ),
              if (s.scheduleEnabled) ...[
                NavSettingRow(
                  icon: Icons.play_circle_outline_rounded,
                  title: tr('ساعت شروع', 'Start time'),
                  value: s.scheduleFrom,
                  ltrValue: true,
                  onTap: () async {
                    final v = await _prompt(context, tr('ساعت شروع (HH:MM)', 'Start time (HH:MM)'), s.scheduleFrom,
                        keyboard: TextInputType.datetime);
                    if (v == null) return;
                    if (AppSettings.parseTime(v) == null) {
                      if (context.mounted) _toast(context, tr('قالب ساعت درست نیست؛ مثل 08:30', 'Invalid time; e.g. 08:30'));
                      return;
                    }
                    await s.update((x) => x.scheduleFrom = v.trim());
                  },
                ),
                NavSettingRow(
                  icon: Icons.stop_circle_outlined,
                  title: tr('ساعت پایان', 'End time'),
                  value: s.scheduleTo,
                  ltrValue: true,
                  onTap: () async {
                    final v = await _prompt(context, tr('ساعت پایان (HH:MM)', 'End time (HH:MM)'), s.scheduleTo,
                        keyboard: TextInputType.datetime);
                    if (v == null) return;
                    if (AppSettings.parseTime(v) == null) {
                      if (context.mounted) _toast(context, tr('قالب ساعت درست نیست؛ مثل 23:00', 'Invalid time; e.g. 23:00'));
                      return;
                    }
                    await s.update((x) => x.scheduleTo = v.trim());
                  },
                ),
              ],
            ]),

            SectionHeader(tr('محافظت', 'Protection')),
            CardGroup(children: [
              if (Platform.isWindows) ...[
                SwitchSettingRow(
                  icon: Icons.vpn_lock_rounded,
                  title: tr('VPN کامل (TUN)', 'Full VPN (TUN)'),
                  subtitle: WindowsEngine.isAdmin
                      ? tr('همه‌ی برنامه‌ها و بازی‌ها از VPN عبور می‌کنند', 'All apps and games go through the VPN')
                      : tr('همه‌ی برنامه‌ها و بازی‌ها — نیاز به اجرای برنامه به‌عنوان Administrator',
                          'All apps and games — requires running as Administrator'),
                  value: s.tunMode,
                  onChanged: (v) => s.update((x) => x.tunMode = v),
                ),
                if (s.tunMode && !WindowsEngine.isAdmin)
                  NavSettingRow(
                    icon: Icons.admin_panel_settings_rounded,
                    title: tr('اجرای دوباره به‌عنوان Administrator', 'Restart as Administrator'),
                    onTap: () async {
                      await controller.disconnect();
                      await WindowsEngine.relaunchAsAdmin();
                      exit(0);
                    },
                  ),
                SwitchSettingRow(
                  icon: Icons.shield_outlined,
                  title: 'Kill Switch',
                  subtitle: s.tunMode
                      ? tr('فقط ترافیک از تونل عبور می‌کند (strict route)', 'Traffic only passes through the tunnel (strict route)')
                      : tr('اگر هسته قطع شد، مرورگرها تا اتصال دوباره یا قطع دستی اینترنت ندارند',
                          'If the core stops, browsers have no internet until reconnect or manual disconnect'),
                  value: s.killSwitch,
                  onChanged: (v) => s.update((x) => x.killSwitch = v),
                ),
              ],
              if (Platform.isAndroid) ...[
                SwitchSettingRow(
                  icon: Icons.lan_outlined,
                  title: tr('فقط پراکسی (بدون VPN)', 'Proxy only (no VPN)'),
                  subtitle: tr('SOCKS روی 127.0.0.1:1080 — برای برنامه‌هایی که پراکسی را دستی تنظیم می‌کنند',
                      'SOCKS on 127.0.0.1:1080 — for apps where you set the proxy manually'),
                  value: s.proxyOnly,
                  onChanged: (v) => s.update((x) => x.proxyOnly = v),
                ),
                NavSettingRow(
                  icon: Icons.shield_outlined,
                  title: tr('Kill Switch (قطع اینترنت بدون VPN)', 'Kill Switch (block internet without VPN)'),
                  subtitle: tr('در تنظیمات VPN اندروید، MolidoVPN را «همیشه روشن» و «مسدود کردن اتصال بدون VPN» کنید',
                      'In Android VPN settings set MolidoVPN to "Always-on" and "Block connections without VPN"'),
                  onTap: () => const AndroidIntent(action: 'android.settings.VPN_SETTINGS').launch(),
                ),
              ],
            ]),

            if (Platform.isWindows) ...[
              SectionHeader(tr('پراکسی ویندوز', 'Windows proxy')),
              CardGroup(children: [
                SwitchSettingRow(
                  icon: Icons.settings_ethernet_rounded,
                  title: tr('تنظیم پراکسی ویندوز', 'Set Windows system proxy'),
                  subtitle: tr('خاموش: فقط پراکسی محلی اجرا می‌شود و خودتان تنظیمش می‌کنید',
                      'Off: only the local proxy runs and you configure it yourself'),
                  value: s.systemProxy,
                  onChanged: (v) => s.update((x) => x.systemProxy = v),
                ),
                NavSettingRow(
                  icon: Icons.numbers_rounded,
                  title: tr('پورت پراکسی محلی (HTTP/SOCKS)', 'Local proxy port (HTTP/SOCKS)'),
                  value: s.localPort == 0 ? tr('خودکار', 'Auto') : '${s.localPort}',
                  onTap: () async {
                    final v = await _prompt(context, tr('پورت (خالی = خودکار)', 'Port (empty = auto)'),
                        s.localPort == 0 ? '' : '${s.localPort}',
                        keyboard: TextInputType.number);
                    if (v == null) return;
                    final port = int.tryParse(v) ?? 0;
                    await s.update((x) => x.localPort = port > 1024 && port < 65536 ? port : 0);
                  },
                ),
                if (controller.engine.httpProxy != null)
                  NavSettingRow(
                    icon: Icons.link_rounded,
                    title: tr('پراکسی فعال', 'Active proxy'),
                    value: controller.engine.httpProxy!,
                    ltrValue: true,
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: controller.engine.httpProxy!));
                      _toast(context, tr('آدرس پراکسی کپی شد', 'Proxy address copied'));
                    },
                  ),
              ]),
            ],

            SectionHeader(tr('مسیریابی و ضد فیلتر', 'Routing & anti-filter')),
            CardGroup(children: [
              if (Platform.isAndroid)
                NavSettingRow(
                  icon: Icons.apps_rounded,
                  title: tr('برنامه‌های خارج از VPN', 'Apps outside VPN'),
                  subtitle: s.excludedApps.isEmpty
                      ? tr('مثلاً بانک و تاکسی اینترنتی را مستقیم وصل کنید', 'E.g. connect banking and ride apps directly')
                      : tr('${s.excludedApps.length} برنامه مستقیم وصل می‌شوند', '${s.excludedApps.length} apps connect directly'),
                  onTap: () => _push(context, AppsScreen(settings: s)),
                ),
              SwitchSettingRow(
                icon: Icons.cloud_outlined,
                title: tr('Cloudflare WARP روی سرور', 'Cloudflare WARP over server'),
                subtitle: tr(
                    'سایت‌هایی که IP سرورهای رایگان را بسته‌اند باز می‌شوند (مثلاً بعضی سرویس‌های هوش مصنوعی)؛ پینگ کمی بیشتر',
                    'Opens sites that block free-server IPs (e.g. some AI services); slightly higher ping'),
                value: s.warp,
                onChanged: (v) async {
                  await s.update((x) => x.warp = v);
                  if (v && !await controller.ensureWarp() && context.mounted) {
                    _toast(context, tr('ثبت WARP الان ممکن نشد؛ هنگام اتصال دوباره تلاش می‌شود',
                        'WARP registration failed for now; it will retry when connecting'));
                  }
                },
              ),
              SwitchSettingRow(
                icon: Icons.content_cut_rounded,
                title: tr('ضد فیلتر (TLS Fragment)', 'Anti-filter (TLS Fragment)'),
                subtitle: tr('تکه‌تکه کردن شروع اتصال TLS برای عبور از فیلترینگ شدید؛ کمی کندتر',
                    'Splits the TLS handshake to pass heavy filtering; a bit slower'),
                value: s.fragment,
                onChanged: (v) => s.update((x) => x.fragment = v),
              ),
              if (Platform.isWindows)
                SwitchSettingRow(
                  icon: Icons.alt_route_rounded,
                  title: tr('اتصال چندمسیره', 'Multi-path connection'),
                  subtitle: tr('سرور اصلی، سرورهای پشتیبان و WARP هم‌زمان آماده‌اند و سریع‌ترینِ سالم هر ۳۰ ثانیه انتخاب می‌شود',
                      'Main server, backups and WARP stay ready; the fastest working one is picked every 30 s'),
                  value: s.multiPath,
                  onChanged: (v) => s.update((x) => x.multiPath = v),
                ),
              if (Platform.isWindows)
                SwitchSettingRow(
                  icon: Icons.data_saver_on_rounded,
                  title: tr('حالت کم‌مصرف', 'Data saver'),
                  subtitle: tr('QUIC (UDP 443) بسته می‌شود تا مرورگر از TCP داخل تونل استفاده کند؛ تست‌های پس‌زمینه هم خاموش می‌شوند',
                      'Blocks QUIC (UDP 443) so browsers use TCP through the tunnel; background probing is turned off'),
                  value: s.dataSaver,
                  onChanged: (v) => s.update((x) => x.dataSaver = v),
                ),
              if (Platform.isWindows)
                SwitchSettingRow(
                  icon: Icons.radar_rounded,
                  title: tr('اسکنر پس‌زمینه', 'Background scanner'),
                  subtitle: _scanSummary(),
                  value: s.backgroundScanner,
                  onChanged: (v) => s.update((x) => x.backgroundScanner = v),
                ),
              if (Platform.isAndroid)
                ChoiceSettingRow<String>(
                  icon: Icons.dns_outlined,
                  title: 'DNS',
                  options: {...AppSettings.dnsServers, if (!AppSettings.dnsServers.containsKey(s.dns)) s.dns: s.dns},
                  value: s.dns,
                  onChanged: (v) => s.update((x) => x.dns = v),
                ),
            ]),

            const SectionHeader('DNS'),
            CardGroup(children: [
              ChoiceSettingRow<String>(
                icon: Icons.dns_outlined,
                title: 'DNS',
                subtitle: tr('خودکار: همان رفتار پیش‌فرض برنامه. از اتصال بعدی اعمال می‌شود.',
                    'Auto: the app default. Applies from the next connection.'),
                options: {'auto': tr('خودکار', 'Auto')},
                value: s.dnsPreset,
                onChanged: (v) => s.update((x) => x.dnsPreset = v),
              ),
              ChoiceSettingRow<String>(
                icon: Icons.sports_esports_outlined,
                title: tr('DNS گیمینگ', 'Gaming DNS'),
                subtitle: tr('برای بازی‌های آنلاین؛ پینگ کمتر به سرورهای بازی ایرانی. ممکن است خارج از ایران کار نکند.',
                    'For online games; lower ping to Iranian game servers. May not work outside Iran.'),
                options: {for (final e in AppSettings.gamingDnsPresets.entries) e.key: e.value.$1},
                value: s.dnsPreset,
                onChanged: (v) => s.update((x) => x.dnsPreset = v),
              ),
            ]),

            SectionHeader(tr('انتخاب سرور', 'Server selection')),
            CardGroup(children: [
              ChoiceSettingRow<int>(
                icon: Icons.format_list_numbered_rounded,
                title: tr('تعداد سرور برای حالت هوشمند', 'Servers tested in smart mode'),
                subtitle: tr('بیشتر = دقیق‌تر ولی کندتر', 'More = more accurate but slower'),
                options: {20: digits(20), 40: digits(40), 80: digits(80)},
                value: s.poolSize,
                onChanged: (v) => s.update((x) => x.poolSize = v),
              ),
              ChoiceSettingRow<int>(
                icon: Icons.timer_outlined,
                title: tr('حداکثر زمان تست', 'Test timeout'),
                options: {for (final n in const [5, 8, 12]) n: tr('${digits(n)} ثانیه', '$n s')},
                value: s.timeoutSeconds,
                onChanged: (v) => s.update((x) => x.timeoutSeconds = v),
              ),
              ChoiceSettingRow<String>(
                icon: Icons.network_ping_rounded,
                title: tr('آدرس تست پینگ', 'Ping test URL'),
                options: AppSettings.testUrls,
                value: s.testUrl,
                onChanged: (v) => s.update((x) => x.testUrl = v),
              ),
              _ProtocolRow(settings: s),
            ]),

            SectionHeader(tr('لیست سرورها', 'Server list')),
            CardGroup(children: [
              NavSettingRow(
                icon: Icons.bookmark_added_outlined,
                title: tr('کانفیگ‌های من (وارد کردن دستی / QR)', 'My configs (manual import / QR)'),
                value: tr('${s.manualConfigs.length} کانفیگ', '${s.manualConfigs.length} configs'),
                onTap: () => _push(context, ImportScreen(controller: controller)),
              ),
              if (Platform.isWindows)
                NavSettingRow(
                  icon: Icons.vpn_key_outlined,
                  title: tr('Amnezia: کانفیگ شخصی (اختیاری)', 'Amnezia: personal config (optional)'),
                  value: s.amneziaConfig.isEmpty ? tr('خودکار (WARP)', 'Automatic (WARP)') : tr('وارد شده', 'Imported'),
                  onTap: () => showAmneziaImport(context, s),
                ),
              NavSettingRow(
                icon: Icons.add_link_rounded,
                title: tr('لینک اشتراک دلخواه', 'Custom subscription link'),
                value: s.customSubscription.isEmpty ? tr('پیش‌فرض (Molido)', 'Default (Molido)') : s.customSubscription,
                ltrValue: s.customSubscription.isNotEmpty,
                onTap: () async {
                  final v = await _prompt(context, tr('لینک اشتراک (خالی = پیش‌فرض)', 'Subscription link (empty = default)'),
                      s.customSubscription,
                      keyboard: TextInputType.url);
                  if (v == null) return;
                  await s.update((x) => x.customSubscription = v.trim());
                  await controller.refresh();
                },
              ),
              NavSettingRow(
                icon: Icons.refresh_rounded,
                title: tr('به‌روزرسانی لیست سرورها', 'Refresh server list'),
                value: tr('${controller.servers.length} سرور', '${controller.servers.length} servers'),
                busy: controller.loading,
                onTap: controller.refresh,
              ),
            ]),

            SectionHeader(tr('حریم خصوصی', 'Privacy')),
            CardGroup(children: [
              SwitchSettingRow(
                icon: Icons.insights_outlined,
                title: tr('گزارش ناشناس کیفیت سرورها', 'Anonymous server quality reports'),
                subtitle: tr(
                    'فقط شناسه‌ی ناشناس سرور، موفق یا ناموفق بودن اتصال، تأخیر و نوع شبکه فرستاده می‌شود؛ '
                        'بدون IP، نام یا اطلاعات وب‌گردی. به انتخاب سرورهای بهتر برای همه کمک می‌کند.',
                    'Only an anonymous server id, success or failure, latency and network type are sent; '
                        'no IP, name or browsing data. Helps pick better servers for everyone.'),
                value: s.anonymousReports,
                onChanged: (v) => s.update((x) => x.anonymousReports = v),
              ),
            ]),

            SectionHeader(tr('ابزارها و پشتیبانی', 'Tools & support')),
            CardGroup(children: [
              NavSettingRow(
                icon: Icons.insights_rounded,
                title: tr('آمار مصرف', 'Usage statistics'),
                onTap: () => _push(context, UsageScreen(controller: controller)),
              ),
              NavSettingRow(
                icon: Icons.fact_check_outlined,
                title: tr('تست سرورها از اینترنت من', 'Test servers from my internet'),
                subtitle: s.anonymousReports
                    ? tr('همه‌ی سرورها با درخواست واقعی تست و نتیجه به‌صورت ناشناس برای رتبه‌بندی ایران فرستاده می‌شود',
                        'Tests all servers with a real request and anonymously reports results for the Iran ranking')
                    : tr('همه‌ی سرورها با درخواست واقعی تست می‌شوند (برای کمک به رتبه‌بندی، گزارش ناشناس را روشن کنید)',
                        'Tests all servers with a real request (turn on anonymous reports to help the ranking)'),
                onTap: () {
                  final busy = controller.state == VpnState.connecting || controller.state == VpnState.disconnecting;
                  final tunnelled = Platform.isWindows && s.tunMode && controller.state == VpnState.connected;
                  if (busy || tunnelled || controller.servers.isEmpty) {
                    _toast(
                        context,
                        tunnelled
                            ? tr('در حالت VPN کامل اول قطع کنید تا اینترنت خودتان سنجیده شود',
                                'In full VPN mode disconnect first so your own internet is measured')
                            : tr('الان ممکن نیست؛ کمی بعد دوباره امتحان کنید', 'Not possible right now; try again shortly'));
                    return;
                  }
                  showDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => _ServerTestDialog(controller: controller),
                  );
                },
              ),
              NavSettingRow(
                icon: Icons.menu_book_outlined,
                title: tr('راهنما', 'Help'),
                subtitle: tr('اگر وصل نشد یا کند بود، اینجا را بخوانید', 'Read this if it does not connect or is slow'),
                onTap: () => _push(context, const HelpScreen()),
              ),
              NavSettingRow(
                icon: Icons.bug_report_outlined,
                title: tr('گزارش خطا', 'Error report'),
                subtitle: tr('جزئیات آخرین اتصال‌ها؛ کپی کنید و بفرستید', 'Details of recent connections; copy and send'),
                onTap: () => _push(context, LogScreen(controller: controller)),
              ),
              NavSettingRow(
                icon: Icons.support_agent_rounded,
                title: tr('گزارش مشکل', 'Report a problem'),
                subtitle: tr('نسخه، اپراتور و گزارش اخیر بدون لینک سرور و IP کپی می‌شود',
                    'Copies version, operator and the recent log without server links or IPs'),
                onTap: () async {
                  final text = await redactedProblemReport(controller);
                  await Clipboard.setData(ClipboardData(text: text));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(tr('گزارش کپی شد؛ برای پشتیبانی بفرستید', 'Report copied; send it to support')),
                      behavior: SnackBarBehavior.floating,
                      duration: const Duration(seconds: 8),
                      action: SnackBarAction(
                        label: tr('ارسال به پشتیبانی', 'Send to support'),
                        onPressed: () => openLink(telegramUrl),
                      ),
                    ));
                  }
                },
              ),
              if (controller.state == VpnState.connected && controller.engine.httpProxy != null)
                NavSettingRow(
                  icon: Icons.speed_rounded,
                  title: tr('تست سرعت', 'Speed test'),
                  subtitle: tr('دانلود و آپلود از داخل VPN (speed.cloudflare.com)',
                      'Download and upload through the VPN (speed.cloudflare.com)'),
                  onTap: () async {
                    final proxy = controller.engine.httpProxy;
                    if (proxy == null) return;
                    _toast(context, tr('تست سرعت در حال انجام…', 'Running speed test…'));
                    final r = await SpeedTest.run(proxy);
                    if (!context.mounted) return;
                    String fmt(double? v) => v == null ? tr('ناموفق', 'failed') : '${v.toStringAsFixed(1)} Mbps';
                    await showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(tr('نتیجه‌ی تست سرعت', 'Speed test result')),
                        content: Text('${tr('دانلود', 'Download')}: ${fmt(r.down)}\n${tr('آپلود', 'Upload')}: ${fmt(r.up)}'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('باشه', 'OK'))),
                        ],
                      ),
                    );
                  },
                ),
            ]),

            SectionHeader(tr('درباره', 'About')),
            CardGroup(children: [
              const ShareFriendsRow(),
              NavSettingRow(
                icon: Icons.code_rounded,
                title: tr('کد برنامه در گیت‌هاب', 'Source code on GitHub'),
                subtitle: 'github.com/hidooch980/molidovpn',
                onTap: () {
                  Clipboard.setData(const ClipboardData(text: 'https://github.com/hidooch980/molidovpn'));
                  _toast(context, tr('لینک کپی شد', 'Link copied'));
                },
              ),
              NavSettingRow(
                icon: Icons.gavel_rounded,
                title: tr('مجوزهای متن‌باز', 'Open-source licenses'),
                subtitle: _androidNotice,
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'MolidoVPN',
                  applicationLegalese: _androidNotice,
                ),
              ),
              NavSettingRow(
                icon: Icons.qr_code_2_rounded,
                title: tr('پشتیبان‌گیری تنظیمات', 'Back up settings'),
                subtitle: tr('کپی JSON و QR؛ بدون کانفیگ‌ها، حساب WARP یا لینک اشتراک',
                    'Copies JSON and shows a QR; no configs, WARP identity or subscription link'),
                onTap: () async {
                  final json = s.toBackupJson();
                  await Clipboard.setData(ClipboardData(text: json));
                  if (!context.mounted) return;
                  await showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(tr('پشتیبان تنظیمات (کپی شد)', 'Settings backup (copied)')),
                      content: SizedBox(
                        width: 260,
                        height: 260,
                        child: ColoredBox(
                          color: Colors.white,
                          child: QrImageView(data: json, size: 260, backgroundColor: Colors.white),
                        ),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('بستن', 'Close'))),
                      ],
                    ),
                  );
                },
              ),
              NavSettingRow(
                icon: Icons.settings_backup_restore_rounded,
                title: tr('بازیابی تنظیمات', 'Restore settings'),
                subtitle: tr('متن JSON پشتیبان را جای‌گذاری کنید', 'Paste the backup JSON text'),
                onTap: () async {
                  final clip = await Clipboard.getData(Clipboard.kTextPlain);
                  if (!context.mounted) return;
                  final v = await _prompt(context, tr('JSON پشتیبان', 'Backup JSON'), clip?.text ?? '');
                  if (v == null) return;
                  final ok = await s.restoreBackup(v);
                  if (context.mounted) {
                    _toast(context, ok ? tr('تنظیمات بازیابی شد', 'Settings restored') : tr('متن پشتیبان معتبر نیست', 'Invalid backup text'));
                  }
                },
              ),
              NavSettingRow(
                icon: Icons.restart_alt_rounded,
                title: tr('بازگشت به تنظیمات پیش‌فرض', 'Reset to defaults'),
                danger: true,
                onTap: () async {
                  await s.reset();
                  if (context.mounted) _toast(context, tr('تنظیمات پیش‌فرض شد', 'Settings reset'));
                },
              ),
            ]),
            ]),
          ],
        ),
      ),
    );
  }
}

/// "تنظیمات پیشرفته": everything beyond the main settings, collapsed until opened.
class _AdvancedSettings extends StatelessWidget {
  const _AdvancedSettings({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: AppCard(
        child: ExpansionTile(
          leading: Icon(Icons.tune_rounded, color: Palette.accent),
          title: Text(tr('تنظیمات پیشرفته', 'Advanced settings'),
              style: TextStyle(fontWeight: FontWeight.w700, color: Palette.text)),
          subtitle: Text(tr('حالت اتصال، محافظت، DNS، سرورها، ابزارها', 'Connection, protection, DNS, servers, tools'),
              style: TextStyle(fontSize: 12, color: Palette.muted)),
          iconColor: Palette.muted,
          collapsedIconColor: Palette.muted,
          childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

Future<String?> _prompt(BuildContext context, String title, String initial, {TextInputType? keyboard}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => Directionality(
      textDirection: L10n.direction,
      child: AlertDialog(
        backgroundColor: Palette.sheet,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Palette.cardRadius)),
        title: Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Palette.text)),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: keyboard,
          textDirection: TextDirection.ltr,
          style: TextStyle(color: Palette.text),
          decoration: InputDecoration(
            filled: true,
            fillColor: Palette.raised,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(Palette.pillRadius), borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('انصراف', 'Cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Palette.accent,
              foregroundColor: Palette.bg,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Palette.pillRadius)),
            ),
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(tr('ذخیره', 'Save')),
          ),
        ],
      ),
    ),
  );
}

class _ServerTestDialog extends StatefulWidget {
  const _ServerTestDialog({required this.controller});

  final VpnController controller;

  @override
  State<_ServerTestDialog> createState() => _ServerTestDialogState();
}

class _ServerTestDialogState extends State<_ServerTestDialog> {
  int _done = 0, _total = 0;
  bool _cancelled = false;
  Map<String, (int, int)>? _result;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final result = await widget.controller.testAllServers(
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() {
          _done = done;
          _total = total;
        });
      },
      isCancelled: () => _cancelled,
    );
    if (mounted) setState(() => _result = result);
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final working = result?.values.fold<int>(0, (a, e) => a + e.$1) ?? 0;
    final all = result?.values.fold<int>(0, (a, e) => a + e.$2) ?? 0;
    return Directionality(
      textDirection: L10n.direction,
      child: AlertDialog(
        backgroundColor: Palette.sheet,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Palette.cardRadius)),
        title: Text(tr('تست سرورها از اینترنت من', 'Test servers from my internet'),
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Palette.text)),
        content: SizedBox(
          width: 320,
          child: result == null
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
                  const SizedBox(height: 12),
                  Text(tr('${digits(_done)} از ${digits(_total)} سرور', '$_done of $_total servers'),
                      style: TextStyle(color: Palette.muted)),
                ])
              : SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(
                        tr('${digits(working)} از ${digits(all)} سرور کار می‌کنند', '$working of $all servers work'),
                        style: TextStyle(fontWeight: FontWeight.w700, color: Palette.text)),
                    const SizedBox(height: 8),
                    for (final e in result.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(children: [
                          Expanded(child: Text(e.key, style: TextStyle(color: Palette.text))),
                          Text(tr('${digits(e.value.$1)} / ${digits(e.value.$2)}', '${e.value.$1} / ${e.value.$2}'),
                              style: TextStyle(color: e.value.$1 > 0 ? Palette.connected : Palette.muted)),
                        ]),
                      ),
                    if (widget.controller.settings.anonymousReports && !_cancelled) ...[
                      const SizedBox(height: 8),
                      Text(tr('نتیجه‌ها به‌صورت ناشناس فرستاده شد. ممنون!', 'Results were reported anonymously. Thanks!'),
                          style: TextStyle(fontSize: 12.5, color: Palette.muted)),
                    ],
                  ]),
                ),
        ),
        actions: [
          if (result == null)
            TextButton(
              onPressed: _cancelled ? null : () => setState(() => _cancelled = true),
              child: Text(tr('توقف', 'Stop')),
            )
          else
            TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('بستن', 'Close'))),
        ],
      ),
    );
  }
}

class _ProtocolRow extends StatelessWidget {
  const _ProtocolRow({required this.settings});

  final AppSettings settings;

  static const _android = {Protocol.vless, Protocol.vmess, Protocol.trojan, Protocol.shadowsocks};

  @override
  Widget build(BuildContext context) {
    final xrayOnly = Platform.isAndroid; // Android runs Xray only
    final available = xrayOnly ? Protocol.values.where(_android.contains) : Protocol.values;
    return SettingRow(
      icon: Icons.security_outlined,
      title: tr('پروتکل‌ها', 'Protocols'),
      subtitle: tr('فقط سرورهای این پروتکل‌ها استفاده می‌شوند', 'Only servers with these protocols are used'),
      below: Wrap(spacing: 8, runSpacing: 8, children: [
        for (final p in available)
          AppChip(
            label: Server(uri: '', remark: '', countryCode: '', protocol: p).protocolLabel,
            selected: settings.protocols.contains(p),
            onTap: () {
              final next = {...settings.protocols};
              next.contains(p) ? next.remove(p) : next.add(p);
              if (next.isNotEmpty) settings.update((x) => x.protocols = next);
            },
          ),
      ]),
    );
  }
}
