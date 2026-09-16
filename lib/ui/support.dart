import 'dart:convert';
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/app_log.dart';
import 'strings.dart';
import 'widgets.dart';

const siteUrl = 'https://hidooch980.github.io/molidovpn/';

/// "معرفی به دوستان": QR code of the website plus copy link.
Future<void> showShareDialog(BuildContext context) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('معرفی به دوستان', 'Tell your friends')),
        content: SizedBox(
          width: 300,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              tr('دوستانتان با اسکن این کد یا باز کردن لینک، MolidoVPN را نصب می‌کنند.',
                  'Friends can scan this code or open the link to install MolidoVPN.'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: QrImageView(data: siteUrl, size: 220, backgroundColor: Colors.white),
            ),
            const SizedBox(height: 10),
            const SelectableText(siteUrl, textDirection: TextDirection.ltr, textAlign: TextAlign.center),
          ]),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(const ClipboardData(text: siteUrl));
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('لینک کپی شد', 'Link copied'))));
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: Text(tr('کپی لینک', 'Copy link')),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('بستن', 'Close'))),
        ],
      ),
    );

/// Row that opens [showShareDialog]; on the simple home and in Settings → About.
class ShareFriendsRow extends StatelessWidget {
  const ShareFriendsRow({super.key});

  @override
  Widget build(BuildContext context) => NavSettingRow(
        icon: Icons.qr_code_2_rounded,
        title: tr('معرفی به دوستان', 'Tell your friends'),
        onTap: () => showShareDialog(context),
      );
}

const telegramHandle = '@Molido_Vpn';
const telegramUrl = 'https://t.me/Molido_Vpn';

/// Opens [url] in the system browser / handler app (no url_launcher dependency).
Future<void> openLink(String url) async {
  try {
    if (Platform.isWindows) {
      await Process.start('explorer', [url], mode: ProcessStartMode.detached);
    } else if (Platform.isAndroid) {
      await AndroidIntent(action: 'action_view', data: url).launch();
    }
  } catch (e) {
    AppLog.add('open link failed: $e');
  }
}

/// Compact "Telegram support" row, used on the home screen and in Settings → About.
class TelegramSupportRow extends StatelessWidget {
  const TelegramSupportRow({super.key});

  @override
  Widget build(BuildContext context) => NavSettingRow(
        icon: Icons.send_rounded,
        title: tr('پشتیبانی تلگرام', 'Telegram support'),
        value: telegramHandle,
        ltrValue: true,
        onTap: () => openLink(telegramUrl),
      );
}

const _donateUrls = [
  'https://raw.githubusercontent.com/hidooch980/molidovpn-android/main/remote/donate.json',
  'https://cdn.jsdelivr.net/gh/hidooch980/molidovpn-android@main/remote/donate.json',
];

class DonateItem {
  const DonateItem(this.label, this.value, this.url);

  final String label, value, url;
}

class DonateInfo {
  const DonateInfo({required this.title, required this.text, required this.items});

  final String title, text;
  final List<DonateItem> items;
}

/// Remote donate info (GitHub raw, then jsDelivr). Null when both fail.
Future<DonateInfo?> fetchDonate() async {
  String str(Object? v) => v is String ? v.trim() : '';
  for (final url in _donateUrls) {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close().timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        await response.drain<void>();
        continue;
      }
      final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
      final json = jsonDecode(body);
      if (json is! Map) continue;
      final raw = json['items'];
      final items = <DonateItem>[
        if (raw is List)
          for (final i in raw)
            if (i is Map) DonateItem(str(i['label']), str(i['value']), str(i['url'])),
      ];
      return DonateInfo(
        title: str(json[L10n.en ? 'title_en' : 'title_fa']),
        text: str(json[L10n.en ? 'text_en' : 'text_fa']),
        items: items,
      );
    } catch (e) {
      AppLog.add('donate: $url failed: $e');
    } finally {
      client.close(force: true);
    }
  }
  return null;
}

/// Donate dialog fed by the remote JSON; falls back to a Telegram hint.
Future<void> showDonateDialog(BuildContext context) {
  final future = fetchDonate();
  return showDialog<void>(
    context: context,
    builder: (context) => FutureBuilder<DonateInfo?>(
      future: future,
      builder: (context, snap) {
        final info = snap.data;
        final loading = snap.connectionState != ConnectionState.done;
        final Widget body;
        if (loading) {
          body = const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        } else if (info == null || (info.text.isEmpty && info.items.isEmpty)) {
          body = Text(tr('برای حمایت به $telegramHandle پیام دهید', 'To support us, message $telegramHandle on Telegram'));
        } else {
          body = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (info.text.isNotEmpty) Text(info.text),
              for (final item in info.items) _DonateItemTile(item: item),
            ],
          );
        }
        final title = info == null || info.title.isEmpty ? tr('حمایت مالی', 'Donate') : info.title;
        final fallback = !loading && (info == null || (info.text.isEmpty && info.items.isEmpty));
        return AlertDialog(
          title: Text(title),
          content: SizedBox(width: 380, child: SingleChildScrollView(child: body)),
          actions: [
            if (fallback)
              TextButton(onPressed: () => openLink(telegramUrl), child: const Text(telegramHandle)),
            TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('بستن', 'Close'))),
          ],
        );
      },
    ),
  );
}

class _DonateItemTile extends StatelessWidget {
  const _DonateItemTile({required this.item});

  final DonateItem item;

  @override
  Widget build(BuildContext context) {
    final url = item.url;
    final canOpen = url.startsWith('https://') || url.startsWith('http://') || url.startsWith('tg://');
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (item.label.isNotEmpty) Text(item.label, style: const TextStyle(fontWeight: FontWeight.w700)),
        if (item.value.isNotEmpty) SelectableText(item.value, textDirection: TextDirection.ltr),
        Wrap(spacing: 8, children: [
          if (item.value.isNotEmpty)
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: item.value));
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('کپی شد', 'Copied'))));
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: Text(tr('کپی', 'Copy')),
            ),
          if (canOpen)
            TextButton.icon(
              onPressed: () => openLink(url),
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: Text(tr('باز کردن', 'Open')),
            ),
        ]),
      ]),
    );
  }
}
