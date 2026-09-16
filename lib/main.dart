import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/account.dart';
import 'core/native_bridge.dart';
import 'core/single_instance.dart';
import 'core/tray.dart';
import 'core/update_notifier.dart';
import 'core/vpn_controller.dart';
import 'ui/auth_screen.dart';
import 'ui/console_home.dart';
import 'ui/strings.dart';
import 'ui/style.dart';

/// Survives app rebuilds on theme changes, so screens can be reopened after the switch.
final appNavigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // A second launch never gets this far: two copies fighting over the same TUN adapter and sing-box
  // port is exactly what made connections flaky (silently failing to bind, or disconnecting when the
  // other instance let go of the adapter). The existing window is focused instead.
  if (!SingleInstance.acquire()) {
    exit(0);
  }
  final controller = VpnController();
  runApp(MobinApp(controller: controller));
  unawaited(initTray(controller, showWindow: () {}));
  NativeBridge.attach(controller);
  unawaited(controller.account.init());
  unawaited(controller.init());
  unawaited(_setupUpdateNotifications());
}

Future<void> _setupUpdateNotifications() async {
  try {
    await UpdateNotifier.init();
    await UpdateNotifier.requestPermission();
    await UpdateNotifier.scheduleBackgroundChecks();
  } catch (e) {
    debugPrint('update notifications unavailable: $e');
  }
}

class MobinApp extends StatefulWidget {
  const MobinApp({super.key, required this.controller});

  final VpnController controller;

  @override
  State<MobinApp> createState() => _MobinAppState();
}

class _MobinAppState extends State<MobinApp> with WidgetsBindingObserver {
  // Closing the window must turn the Windows system proxy off again.
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onExitRequested: () async {
      await widget.controller.disconnect();
      return AppExitResponse.exit;
    },
  );

  @override
  void initState() {
    super.initState();
    _lifecycle;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangePlatformBrightness() {
    if (widget.controller.settings.themeMode == 'system') setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.controller.settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final brightness = switch (settings.themeMode) {
          'light' => Brightness.light,
          'dark' => Brightness.dark,
          _ => PlatformDispatcher.instance.platformBrightness,
        };
        Palette.apply(brightness, reduceMotion: settings.reduceMotion);
        L10n.en = settings.language == 'en';
        final dark = brightness == Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Palette.bg,
          ),
          child: MaterialApp(
            // Palette values are read directly by widgets, so a theme switch rebuilds the whole tree.
            key: ValueKey('$brightness-${settings.reduceMotion}-${settings.language}'),
            navigatorKey: appNavigatorKey,
            title: 'MolidoVPN',
            debugShowCheckedModeBanner: false,
            locale: L10n.locale,
            supportedLocales: AppLocalizationDelegates.supportedLocales,
            localizationsDelegates: AppLocalizationDelegates.all,
            theme: ThemeData(
              brightness: brightness,
              useMaterial3: true,
              colorSchemeSeed: Palette.accent,
              scaffoldBackgroundColor: Palette.bg,
              fontFamily: Platform.isWindows ? 'Segoe UI' : null,
            ),
            builder: (context, child) => Directionality(textDirection: L10n.direction, child: child!),
            home: ListenableBuilder(
              listenable: widget.controller.account,
              builder: (context, _) {
                final account = widget.controller.account;
                return switch (account.status) {
                  AccountStatus.loading => Scaffold(body: Center(child: CircularProgressIndicator(color: Palette.accent))),
                  AccountStatus.signedOut => AuthScreen(account: account),
                  AccountStatus.disabled || AccountStatus.otherDevice => AccountBlockedScreen(account: account),
                  AccountStatus.ok => ConsoleHome(controller: widget.controller),
                };
              },
            ),
          ),
        );
      },
    );
  }
}
