import 'dart:async';
import 'dart:io';

/// Windows' built-in IKEv2 client. Credentials are entered by rasphone's native
/// UI and are never passed to PowerShell or stored by MolidoVPN.
class WindowsIkev2 {
  static const profileName = 'MolidoVPN IKEv2';

  String _quote(String value) => "'${value.replaceAll("'", "''")}'";

  Future<ProcessResult> _powershell(String script) => Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
        runInShell: false,
      );

  bool validHost(String host) =>
      host.length <= 253 &&
      RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(host) &&
      !host.startsWith('.') &&
      !host.endsWith('.');

  Future<bool> connect(String host, {Duration timeout = const Duration(seconds: 75)}) async {
    if (!Platform.isWindows || !validHost(host)) return false;
    final name = _quote(profileName);
    final server = _quote(host);
    final install = await _powershell(
      "$ErrorActionPreference='Stop'; "
      "$p=Get-VpnConnection -Name $name -ErrorAction SilentlyContinue; "
      "if ($p -and ($p.ServerAddress -ne $server -or $p.TunnelType -ne 'Ikev2')) { "
      "Remove-VpnConnection -Name $name -Force; $p=$null }; "
      "if (-not $p) { Add-VpnConnection -Name $name -ServerAddress $server "
      "-TunnelType Ikev2 -AuthenticationMethod Eap -EncryptionLevel Required "
      "-RememberCredential:$false -SplitTunneling:$false -Force | Out-Null }; "
      "Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\\rasphone.exe') "
      "-ArgumentList @('-d', $name)"
    );
    if (install.exitCode != 0) return false;

    final until = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(until)) {
      if (await isConnected()) return true;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return false;
  }

  Future<bool> isConnected() async {
    if (!Platform.isWindows) return false;
    final result = await _powershell(
      "$p=Get-VpnConnection -Name ${_quote(profileName)} -ErrorAction SilentlyContinue; "
      "if ($p) { [Console]::Write($p.ConnectionStatus) }"
    );
    return result.exitCode == 0 && result.stdout.toString().trim().toLowerCase() == 'connected';
  }

  Future<void> disconnect() async {
    if (!Platform.isWindows) return;
    await Process.run(
      'rasdial.exe',
      [profileName, '/disconnect'],
      runInShell: false,
    );
  }

  Future<void> removeProfile() async {
    if (!Platform.isWindows) return;
    await disconnect();
    await _powershell("Remove-VpnConnection -Name ${_quote(profileName)} -Force -ErrorAction SilentlyContinue");
  }
}
