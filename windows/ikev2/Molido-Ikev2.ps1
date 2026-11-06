# MolidoVPN native Windows IKEv2 profile helper.
# Credentials are entered in the native Windows UI, never passed on command lines.

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

switch ($Action) {
    "Install" {
        Assert-Admin
        if ([string]::IsNullOrWhiteSpace($ServerAddress) -or $ServerAddress -notmatch '^[A-Za-z0-9.-]+$') {
            throw "A valid IKEv2 server hostname is required."
        }
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
        Start-Process -FilePath "$env:SystemRoot\System32\rasphone.exe" -ArgumentList @("-d", $ProfileName) -Wait
    }
    "Disconnect" {
        & "$env:SystemRoot\System32\rasdial.exe" $ProfileName "/disconnect" | Out-Null
    }
    "Remove" {
        Assert-Admin
        Remove-VpnConnection -Name $ProfileName -Force -ErrorAction SilentlyContinue
    }
}
