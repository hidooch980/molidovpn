import 'dart:io';

/// Windows' built-in IKEv2 client. Credentials are entered by rasphone's native
/// UI and are never passed to PowerShell or stored by MolidoVPN.
class WindowsIkev2 {
  String profileNameFor(String host) { final safe = host.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]'), '_'); return 'MolidoVPN IKEv2 ${safe.substring(0, safe.length > 32 ? 32 : safe.length)}'; }

  String _quote(String value) => "'${value.replaceAll("'", "''")}'";

  Future<ProcessResult> _powershell(String script) => Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
        runInShell: false,
      );

  bool validHost(String host) {
    if (host.isEmpty || host.length > 253 || host.contains(RegExp(r'\\s')) || host.contains('/') || host.contains('\\')) return false;
    if (InternetAddress.tryParse(host) != null) return true;
    return RegExp(r'^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\\.(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*

  Future<bool> connect(String host, {Duration timeout = const Duration(seconds: 75)}) async {
    if (!Platform.isWindows || !validHost(host)) return false;
    final name = _quote(profileNameFor(host));
    final server = _quote(host);
    final install = await _powershell(
      "\$ErrorActionPreference='Stop'; "
      "\$p=Get-VpnConnection -Name $name -ErrorAction SilentlyContinue; "
      "if (\$p -and (\$p.ServerAddress -ne $server -or \$p.TunnelType -ne 'Ikev2')) { "
      "Remove-VpnConnection -Name $name -Force; \$p=\$null }; "
      "if (-not \$p) { Add-VpnConnection -Name $name -ServerAddress $server "
      "-TunnelType Ikev2 -AuthenticationMethod Eap -EncryptionLevel Required "
      "-RememberCredential:\$false -SplitTunneling:\$false -Force | Out-Null }; "
      "Start-Process -FilePath (Join-Path \$env:SystemRoot 'System32\\rasphone.exe') "
      "-ArgumentList @('-d', $name)"
    );
    if (install.exitCode != 0) return false;

    final until = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(until)) {
      if (await isConnected(host)) return true;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return false;
  }

  Future<bool> isConnected(String host) async {
    if (!Platform.isWindows || !validHost(host)) return false;
    final result = await _powershell(
      "\$p=Get-VpnConnection -Name ${_quote(profileNameFor(host))} -ErrorAction SilentlyContinue; "
      "if (\$p) { [Console]::Write(\$p.ConnectionStatus) }"
    );
    return result.exitCode == 0 && result.stdout.toString().trim().toLowerCase() == 'connected';
  }

  Future<void> disconnect(String host) async {
    if (!Platform.isWindows || !validHost(host)) return;
    await Process.run(
      'rasdial.exe',
      [profileNameFor(host), '/disconnect'],
      runInShell: false,
    );
  }

  Future<void> removeProfile(String host) async {
    if (!Platform.isWindows || !validHost(host)) return;
    final name = _quote(profileNameFor(host));
    await disconnect(host);
    await _powershell("Remove-VpnConnection -Name $name -Force -ErrorAction SilentlyContinue");
  }
}
).hasMatch(host);
  }

  Future<bool> connect(String host, {Duration timeout = const Duration(seconds: 75)}) async {
    if (!Platform.isWindows || !validHost(host)) return false;
    final name = _quote(profileNameFor(host));
    final server = _quote(host);
    final install = await _powershell(
      "\$ErrorActionPreference='Stop'; "
      "\$p=Get-VpnConnection -Name $name -ErrorAction SilentlyContinue; "
      "if (\$p -and (\$p.ServerAddress -ne $server -or \$p.TunnelType -ne 'Ikev2')) { "
      "Remove-VpnConnection -Name $name -Force; \$p=\$null }; "
      "if (-not \$p) { Add-VpnConnection -Name $name -ServerAddress $server "
      "-TunnelType Ikev2 -AuthenticationMethod Eap -EncryptionLevel Required "
      "-RememberCredential:\$false -SplitTunneling:\$false -Force | Out-Null }; "
      "Start-Process -FilePath (Join-Path \$env:SystemRoot 'System32\\rasphone.exe') "
      "-ArgumentList @('-d', $name)"
    );
    if (install.exitCode != 0) return false;

    final until = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(until)) {
      if (await isConnected(host)) return true;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return false;
  }

  Future<bool> isConnected(String host) async {
    if (!Platform.isWindows || !validHost(host)) return false;
    final result = await _powershell(
      "\$p=Get-VpnConnection -Name ${_quote(profileNameFor(host))} -ErrorAction SilentlyContinue; "
      "if (\$p) { [Console]::Write(\$p.ConnectionStatus) }"
    );
    return result.exitCode == 0 && result.stdout.toString().trim().toLowerCase() == 'connected';
  }

  Future<void> disconnect(String host) async {
    if (!Platform.isWindows || !validHost(host)) return;
    await Process.run(
      'rasdial.exe',
      [profileNameFor(host), '/disconnect'],
      runInShell: false,
    );
  }

  Future<void> removeProfile(String host) async {
    if (!Platform.isWindows || !validHost(host)) return;
    final name = _quote(profileNameFor(host));
    await disconnect(host);
    await _powershell("Remove-VpnConnection -Name $name -Force -ErrorAction SilentlyContinue");
  }
}
