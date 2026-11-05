import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'app_log.dart';
import 'updater.dart';

/// System notification when a new release is out: checked on launch, every few hours while the app runs,
/// and on Android also in the background (WorkManager) when the app is closed.
class UpdateNotifier {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static const _task = 'mobin-update-check';
  static const _notifiedKey = 'update_notified_version';

  static Future<void> init() async {
    if (_ready) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        windows: WindowsInitializationSettings(
          appName: 'MolidoVPN',
          appUserModelId: 'Mobin.MobinVPN',
          guid: '8f3c2a1e-6b4d-4f7a-9c1e-2d5b7a9e4c10',
        ),
      ),
    );
    _ready = true;
  }

  static Future<void> requestPermission() async {
    if (!Platform.isAndroid) return;
    await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
  }

  /// Shows one notification per new version.
  static Future<void> notifyIfNew(UpdateInfo update) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_notifiedKey) == update.version) return;
    await init();
    await _plugin.show(
      id: 7001,
      title: 'نسخه‌ی جدید MolidoVPN',
      body: 'نسخه‌ی ${update.version} آماده است. برنامه را باز کنید و «به‌روزرسانی» را بزنید.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'updates',
          'به‌روزرسانی برنامه',
          channelDescription: 'اعلان وقتی نسخه‌ی جدید منتشر می‌شود',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
    await prefs.setString(_notifiedKey, update.version);
  }

  static Future<void> scheduleBackgroundChecks() async {
    if (!Platform.isAndroid) return;
    await Workmanager().initialize(updateCheckCallback);
    await Workmanager().registerPeriodicTask(
      _task,
      _task,
      frequency: const Duration(hours: 6),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }
}

/// Runs in a background isolate started by WorkManager.
@pragma('vm:entry-point')
void updateCheckCallback() {
  Workmanager().executeTask((task, input) async {
    try {
      final update = await Updater().check();
      if (update != null) await UpdateNotifier.notifyIfNew(update);
    } catch (e) {
      AppLog.add('background update check failed: $e');
    }
    return true;
  });
}
