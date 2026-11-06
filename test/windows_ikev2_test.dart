import 'package:flutter_test/flutter_test.dart';
import 'package:mobin_vpn/core/windows_ikev2.dart';

void main() {
  test('validates native IKEv2 hostnames without accepting shell input', () {
    final manager = WindowsIkev2();
    expect(manager.validHost('vpn.example.com'), isTrue);
    expect(manager.validHost('vpn-01.example.net'), isTrue);
    expect(manager.validHost('192.0.2.10'), isTrue);
    expect(manager.validHost('2001:db8::1'), isTrue);
    expect(manager.validHost('vpn.example.com; Start-Process calc'), isFalse);
    expect(manager.validHost('https://vpn.example.com'), isFalse);
    expect(manager.validHost('.example.com'), isFalse);
    expect(manager.validHost('example.com.'), isFalse);
    expect(manager.validHost(''), isFalse);
    expect(manager.profileNameFor('vpn-a.example.com'), isNot(manager.profileNameFor('vpn-b.example.com')));
    expect(manager.profileNameFor('vpn-a.example.com').length, lessThan(64));
  });
}
