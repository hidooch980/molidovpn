import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

import 'engine.dart';
import 'vpn_controller.dart';

const _keyToggle = 'toggle';
const _keyShow = 'show';
const _keyExit = 'exit';

_TrayHandler? _handler;

/// Windows system tray: status tooltip plus connect/disconnect, show and exit.
Future<void> initTray(VpnController controller, {required VoidCallback showWindow}) async {
  if (!Platform.isWindows || _handler != null) return;
  final handler = _TrayHandler(controller, showWindow);
  _handler = handler;
  await trayManager.setIcon('assets/icon/tray_icon.ico');
  trayManager.addListener(handler);
  controller.addListener(handler.refresh);
  await handler.update();
}

class _TrayHandler with TrayListener {
  _TrayHandler(this.controller, this.showWindow);

  final VpnController controller;
  final VoidCallback showWindow;
  VpnState? _shown;

  void refresh() {
    if (controller.state != _shown) unawaited(update());
  }

  Future<void> update() async {
    final state = controller.state;
    _shown = state;
    final status = switch (state) {
      VpnState.connected => 'متصل',
      VpnState.connecting => 'در حال اتصال',
      VpnState.disconnecting => 'در حال قطع',
      VpnState.disconnected => 'قطع',
    };
    final toggleLabel = state == VpnState.disconnected ? 'وصل' : 'قطع';
    await trayManager.setToolTip('MolidoVPN — $status');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: _keyToggle, label: toggleLabel),
      MenuItem(key: _keyShow, label: 'نمایش برنامه'),
      MenuItem.separator(),
      MenuItem(key: _keyExit, label: 'خروج'),
    ]));
  }

  @override
  void onTrayIconMouseDown() => showWindow();

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _keyToggle:
        unawaited(controller.toggle());
      case _keyShow:
        showWindow();
      case _keyExit:
        unawaited(_exit());
    }
  }

  Future<void> _exit() async {
    if (controller.state != VpnState.disconnected) await controller.disconnect();
    await controller.installOnExit();
    await trayManager.destroy();
    exit(0);
  }
}
