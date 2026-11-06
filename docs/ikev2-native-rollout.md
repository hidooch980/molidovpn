# Native IKEv2 implementation — Android + Windows

## Product decision

IKEv2 is a first-class transport on both Android and Windows, separate from
sing-box/Xray. The selected rollout includes provider-operated free endpoints
and MolidoVPN-owned endpoints.

A directory entry containing only host, identity label, and account URL is
discovery metadata, not a connectable profile. No credentials may be guessed
or committed to the repository.

## Android

- Use Android VpnManager + Ikev2VpnProfile (API 30+ and device IPsec feature).
- Use EAP-MSCHAPv2 for username/password providers.
- Request platform consent from provisionVpnProfile; start only after RESULT_OK.
- API 33+ uses startProvisionedVpnProfileSession; API 30–32 use the deprecated
  no-return start method.
- The OS owns this tunnel. Do not start MolidoVpnService or create a second TUN.
- Credentials are handed to the OS profile and must not be logged or stored by
  MolidoVPN.
- Older devices keep existing transports and report IKEv2 as unsupported.

Implementation entry point: android-app/app/src/main/java/com/molido/vpn/NativeIkev2Manager.kt.

## Windows

- Use the built-in Windows VpnClient profile API for IKEv2/EAP.
- Require encryption and full-tunnel routing.
- Use rasphone's native credential UI; never pass passwords as process arguments.
- Elevation is required for machine-wide profile management when Windows asks.

Implementation helper: windows/ikev2/Molido-Ikev2.ps1.

## Failover policy

1. Keep provider and owned endpoints separately tagged with source, region, host,
   IKE identity, auth method, certificate policy, and credential reference.
2. Never reuse credentials across unrelated providers.
3. A reachability probe is not proof of successful IKE authentication.
4. On tunnel loss, stop the old profile/session, use bounded exponential backoff,
   then try the next endpoint with its matching credential record.
5. Confirm OS tunnel state, default route, DNS, and public egress IP before marking
   connected. Cap retries and expose manual retry.
6. Native OS failover may briefly interrupt traffic; do not promise seamless
   failover until a kill switch and leak tests pass.

## Release gates — not yet satisfied

- Integrate both managers into the app connection state machine and home UI.
- Add secure credential entry/storage or provider-specific account import.
- Extend directory schema with auth and certificate metadata; never store passwords.
- Add lifecycle, host-validation, retry-limit, and state-transition tests.
- Build Android API 26/30/33+ variants and verify unsupported-device behavior.
- Build Windows x64 and test standard-user/elevated profile lifecycle.
- End-to-end test against controlled IKEv2 servers on both platforms: valid/invalid
  credentials, certificate mismatch, network change, disconnect, reconnect,
  failover, DNS/IP leak checks, and uninstall cleanup.

Do not advertise IKEv2 as available until these gates pass.
