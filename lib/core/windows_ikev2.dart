import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Windows' built-in IKEv2 client. Credentials are entered by rasphone's native
/// UI and are never passed to PowerShell or stored by MolidoVPN.
class WindowsIkev2 {
  String profileNameFor(String host) { final safe = host.toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]'), '_'); return 'MolidoVPN IKEv2 ${safe.substring(0, safe.length > 32 ? 32 : safe.length)}'; }

  String _quote(String value) => "'${value.replaceAll("'", "''")}'";

  /// Runs a child with a hard deadline. Future.timeout alone leaves the OS process alive;
  /// kill it on timeout so repeated VPN status checks cannot accumulate orphan processes.
  Future<ProcessResult> _runBounded(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      runInShell: false,
    ).timeout(timeout);
    try {
      final values = await Future.wait<Object>([
        process.exitCode,
        process.stdout.transform(utf8.decoder).join(),
        process.stderr.transform(utf8.decoder).join(),
      ]).timeout(timeout);
      return ProcessResult(
        process.pid,
        values[0] as int,
        values[1] as String,
        values[2] as String,
      );
    } on TimeoutException {
      process.kill();
      rethrow;
    }
  }

  Future<ProcessResult> _powershell(String script) => _runBounded(
        'powershell.exe',
        ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
      );

  bool validHost(String host) {
    if (host.isEmpty || host.length > 253 || host.contains(RegExp(r'\s')) || host.contains('/') || host.contains('\\')) return false;
    if (InternetAddress.tryParse(host) != null) return true;
    final labels = host.split('.');
    return labels.every((label) => label.isNotEmpty && label.length <= 63 &&
        RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$').hasMatch(label));
  }

  Future<bool> connect(String host, {Duration timeout = const Duration(seconds: 75)}) async {
    if (!Platform.isWindows || !validHost(host)) return false;
    final name = _quote(profileNameFor(host));
    final server = _quote(host);
    try {
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
    } on TimeoutException {
      return false;
    } on ProcessException {
      return false;
    }
  }

  Future<bool> isConnected(String host) async {
    if (!Platform.isWindows || !validHost(host)) return false;
    try {
      final result = await _powershell(
        "\\$p=Get-VpnConnection -Name ${_quote(profileNameFor(host))} -ErrorAction SilentlyContinue; "
        "if (\\$p) { [Console]::Write(\\$p.ConnectionStatus) }"
      );
      return result.exitCode == 0 && result.stdout.toString().trim().toLowerCase() == 'connected';
    } on TimeoutException {
      return false;
    } on ProcessException {
      return false;
    }
  }

  Future<void> disconnect(String host) async {
    if (!Platform.isWindows || !validHost(host)) return;
    try {
      await _runBounded('rasdial.exe', [profileNameFor(host), '/disconnect']);
    } on TimeoutException {
      // A hung rasdial process must not block app shutdown or profile cleanup.
    } on ProcessException {
      // The native VPN service may already be stopped; disconnect is best-effort.
    }
  }

  Future<void> removeProfile(String host) async {
    if (!Platform.isWindows || !validHost(host)) return;
    final name = _quote(profileNameFor(host));
    await disconnect(host);
    try {
      await _powershell("Remove-VpnConnection -Name $name -Force -ErrorAction SilentlyContinue");
    } on TimeoutException {
      // Leave the profile in place rather than hanging the UI indefinitely.
    } on ProcessException {
      // PowerShell unavailable: preserve the profile and report via the caller's state.
    }
  }
}
