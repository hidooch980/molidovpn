// Renders the Windows home (v2 «فیروزه و شب») in its Smart Connect states to PNG files.
// Gated: MOLIDO_SCREENS=<output dir> flutter test test/screens_test.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobin_vpn/core/engine.dart';
import 'package:mobin_vpn/core/server.dart';
import 'package:mobin_vpn/core/smart/smart_connect.dart';
import 'package:mobin_vpn/core/vpn_controller.dart';
import 'package:mobin_vpn/ui/console_home.dart';
import 'package:mobin_vpn/ui/style.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeEngine extends VpnEngine {
  final _s = StreamController<VpnState>.broadcast();
  final _t = StreamController<TrafficStat>.broadcast();
  @override
  Stream<VpnState> get states => _s.stream;
  @override
  Stream<TrafficStat> get traffic => _t.stream;
  @override
  String? get httpProxy => null;
  @override
  bool supports(Server server) => true;
  @override
  Future<void> init() async {}
  @override
  Future<bool> healthCheck(EngineOptions options) async => true;
  @override
  Future<List<int>> pingAll(List<Server> servers, EngineOptions options,
          {void Function(int done)? onProgress, bool Function()? isCancelled, void Function(int index, int delay)? onResult}) async =>
      List.filled(servers.length, -1);
  @override
  Future<bool> connect(Server server, EngineOptions options) async => true;
  @override
  Future<void> disconnect() async {}
}

Server _s(String uri, String remark, [Protocol p = Protocol.vless]) =>
    Server(uri: uri, remark: remark, countryCode: 'DE', protocol: p);

SmartRun _race({required bool done}) {
  final run = SmartRun();
  final cdn = SmartCandidate(_s('vless://a@h:443?security=tls&type=ws#DE 03', 'DE 03 · CDN'));
  final cdn2 = SmartCandidate(_s('vless://b@h:443?security=tls&type=ws#NL 07', 'NL 07 · CDN'));
  final reality = SmartCandidate(_s('vless://c@h:443?security=reality&type=tcp#FI 02', 'FI 02 · Reality'));
  final xhttp = SmartCandidate(_s('vless://d@h:443?security=tls&type=xhttp#DE 11', 'DE 11 · XHTTP'));
  final hy2 = SmartCandidate(_s('hysteria2://e@h:443#DE 05', 'DE 05 · HY2', Protocol.hysteria2));
  final frag = SmartCandidate(_s('vless://f@h:443?security=tls&type=ws#TR 01', 'TR 01 · CDN'), fragment: true);
  final warp = SmartCandidate(_s('viawarp:vless://g', 'DE 03 + WARP'));
  final psiphon = SmartCandidate(_s('psiphon://auto', 'Psiphon', Protocol.socks));
  final tor = SmartCandidate(_s('tor://auto', 'Tor', Protocol.socks));
  final all = [cdn, cdn2, reality, xhttp, hy2, frag, warp, psiphon, tor];
  all.forEach(run.register);
  run.total = 14;
  run.testing([cdn, cdn2, reality, xhttp, hy2, frag]);
  run.record(cdn, 84);
  run.record(reality, -1);
  run.record(hy2, 212);
  run.record(cdn2, 140);
  run.stage = 2;
  run.record(cdn, 91, countsForProgress: true);
  if (done) {
    run.record(xhttp, -1);
    run.record(frag, 160);
    run.record(cdn, 88);
    run.record(hy2, 230);
    cdn.shared = 0.82;
    run
      ..winner = cdn
      ..runnerUp = hy2
      ..reason = smartReason(cdn.measured)
      ..routesTested = 6
      ..stage = 3
      ..finish();
  }
  return run;
}

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final bytes = File(f).readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }

  await load('Vazirmatn', [
    for (final w in ['Regular', 'Medium', 'Bold', 'ExtraBold', 'Black']) 'fonts/Vazirmatn-$w.ttf',
  ]);
  await load('Space Grotesk', ['fonts/SpaceGrotesk-Regular.ttf']);
  // Windows has Consolas; the test host does not.
  await load('Consolas', ['fonts/SpaceGrotesk-Regular.ttf']);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '';
  final icons = File('$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) await load('MaterialIcons', [icons.path]);
}

void main() {
  final out = Platform.environment['MOLIDO_SCREENS'];
  if (out == null || out.isEmpty) {
    test('screens (set MOLIDO_SCREENS to render)', () {}, skip: 'MOLIDO_SCREENS not set');
    return;
  }

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await _loadFonts();
  });

  for (final dark in [true, false]) {
    for (final shot in ['idle', 'testing', 'connected']) {
      testWidgets('windows-home-$shot-${dark ? 'dark' : 'light'}', (tester) async {
        tester.view.physicalSize = const Size(1040, 1720);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        Palette.apply(dark ? Brightness.dark : Brightness.light, reduceMotion: true);
        final c = VpnController(engine: _FakeEngine());
        await c.settings.update((s) {
          s.onboarded = true;
          s.reportsAsked = true;
        });
        if (shot == 'testing') {
          c.state = VpnState.connecting;
          c.smart = _race(done: false);
          c.progressDone = 5;
          c.progressTotal = 14;
        } else if (shot == 'connected') {
          c.state = VpnState.connected;
          c.smart = _race(done: true);
          c.connectedAt = DateTime.now().subtract(const Duration(minutes: 12, seconds: 48));
        }
        final key = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
              useMaterial3: true,
              colorSchemeSeed: Palette.accent,
              scaffoldBackgroundColor: Palette.bg,
              fontFamily: 'Vazirmatn',
            ),
            builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
            home: ConsoleHome(controller: c),
          ),
        ));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          Directory(out).createSync(recursive: true);
          File('$out/windows-home-$shot-${dark ? 'dark' : 'light'}.png').writeAsBytesSync(png!.buffer.asUint8List());
        });
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      });
    }
  }
}
