# MolidoVPN on iPhone (free web install)

## What is included

The website under `site/` is installable from Safari as a Progressive Web App (PWA). It provides the MolidoVPN web experience and a shortcut on the iPhone Home Screen without App Store distribution fees.

## Install

1. Open the MolidoVPN website in Safari.
2. Tap Share.
3. Choose **Add to Home Screen** and confirm.
4. Launch MolidoVPN from the new Home Screen icon.

The PWA manifest and service worker are scoped to the website path, so this also works when hosted under a GitHub Pages project subpath.

## VPN tunnel limitation

A PWA does **not** create a system-wide iOS VPN tunnel. For actual device traffic tunneling, use a compatible iOS VPN client and the existing iOS subscription endpoint. The website links to the subscription; it does not claim to connect the iPhone VPN by itself.

## Cache and privacy

The service worker caches only the static application shell. It deliberately bypasses API, subscription, and tunnel-configuration paths so that live server lists and connection profiles are not stored as stale offline responses.

## IKEv2 status

Do not publish a `.mobileconfig` profile until the IKEv2 server, authentication method, certificate chain, DNS, and routing behavior have been verified. Never generate a profile with placeholder hosts, credentials, or certificates.

## Native iOS roadmap

A native client requires an iOS Network Extension design and the relevant Apple entitlements/signing. Keep this as a separate later release track; the free PWA is not a substitute for a native packet-tunnel app.
