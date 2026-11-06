# MolidoVPN native Windows IKEv2 profile helper.
# Credentials are entered only through the native Windows VPN UI.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Install", "Connect", "Disconnect", "Remove")]
    [string] $Action,
    [string] $ServerAddress,
    [string] $ProfileName = "MolidoVPN IKEv2"
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Administrator permission is required to install or remove the IKEv2 profile."
    }
}

function Assert-ServerAddress([string] $Address) {
    if ([string]::IsNullOrWhiteSpace($Address)) {
        throw "A valid IKEv2 server hostname or IP address is required."
    }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($Address, [ref] $ip)) { return }
    if ($Address.Length -gt 253) { throw "The IKEv2 server hostname is too long." }
    $labels = $Address.Split('.')
    if ($labels.Count -lt 2) { throw "Enter a fully-qualified IKEv2 server hostname." }
    foreach ($label in $labels) {
        if ($label.Length -lt 1 -or $label.Length -gt 63 -or
            $label -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$') {
            throw "The IKEv2 server hostname is invalid."
        }
    }
}

if ([string]::IsNullOrWhiteSpace($ProfileName) -or $ProfileName.Length -gt 64) {
    throw "The VPN profile name must contain between 1 and 64 characters."
}

switch ($Action) {
    "Install" {
        Assert-Admin
        Assert-ServerAddress $ServerAddress
        $existing = Get-VpnConnection -Name $ProfileName -ErrorAction SilentlyContinue
        if ($existing -and ($existing.ServerAddress -ne $ServerAddress -or $existing.TunnelType -ne "Ikev2")) {
            Remove-VpnConnection -Name $ProfileName -Force
            $existing = $null
        }
        if (-not $existing) {
            Add-VpnConnection -Name $ProfileName -ServerAddress $ServerAddress -TunnelType Ikev2 -AuthenticationMethod Eap -EncryptionLevel Required -RememberCredential:$false -SplitTunneling:$false -Force | Out-Null
        }
        Get-VpnConnection -Name $ProfileName | Select-Object Name, ServerAddress, TunnelType, AuthenticationMethod
    }
    "Connect" {
        $profile = Get-VpnConnection -Name $ProfileName -ErrorAction Stop
        if ($profile.TunnelType -ne "Ikev2") { throw "The selected profile is not IKEv2." }
        Start-Process -FilePath (Join-Path $env:SystemRoot "System32\rasphone.exe") -ArgumentList @("-d", $ProfileName) -Wait
    }
    "Disconnect" {
        & (Join-Path $env:SystemRoot "System32\rasdial.exe") $ProfileName "/disconnect" | Out-Null
    }
    "Remove" {
        Assert-Admin
        Remove-VpnConnection -Name $ProfileName -Force -ErrorAction SilentlyContinue
    }
}
