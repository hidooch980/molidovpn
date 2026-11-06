import 'package:flutter_test/flutter_test.dart';
import 'package:mobin_vpn/core/windows_ikev2.dart';

void main() {
  test('validates native IKEv2 hostnames without accepting shell input', () {
    final manager = WindowsIkev2();
    expect(manager.validHost('vpn.example.com'), isTrue);
    expect(manager.validHost('vpn-01.example.net'), isTrue);
    expect(manager.validHost('vpn.example.com; Start-Process calc'), isFalse);
    expect(manager.validHost('https://vpn.example.com'), isFalse);
    expect(manager.validHost('.example.com'), isFalse);
    expect(manager.validHost('example.com.'), isFalse);
    expect(manager.validHost(''), isFalse);
  });
}
