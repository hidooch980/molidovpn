import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import test from 'node:test';

const source = await readFile(new URL('./sub-worker.js', import.meta.url), 'utf8');
const { default: worker } = await import(
  'data:text/javascript;base64,' + Buffer.from(source).toString('base64')
);
const ctx = { waitUntil(promise) { return promise; } };
const request = (path, init) => new Request('https://worker.example' + path, init);

test('Android update metadata comes from canonical Android repo and preserves legacy APK aliases', async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (input) => {
    const url = String(input);
    assert.equal(url, 'https://api.github.com/repos/hidooch980/molidovpn-android/releases/latest');
    return new Response(JSON.stringify({
      tag_name: 'v4.0.2',
      published_at: '2026-11-04T00:00:00Z',
      body: 'Security and stability updates',
      assets: [
        {
          name: 'MolidoMeshAI-android-arm64.apk',
          size: 1024,
          digest: 'sha256:' + 'a'.repeat(64),
        },
      ],
    }), { status: 200, headers: { 'content-type': 'application/json' } });
  };
  try {
    const response = await worker.fetch(request('/app/latest.json'), {}, ctx);
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.equal(body.tag_name, 'v4.0.2');
    const names = body.assets.map((asset) => asset.name);
    assert.deepEqual(names, [
      'MolidoMeshAI-android-arm64.apk',
      'MolidoVPN-android-arm64.apk',
      'MobinVPN-android-arm64.apk',
    ]);
    for (const asset of body.assets) {
      assert.match(asset.sha256, /^[a-f0-9]{64}$/);
      assert.equal(asset.browser_download_url, 'https://worker.example/app/' + asset.name);
    }
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('legacy Android APK download names resolve to canonical signed Android release assets', async () => {
  const originalFetch = globalThis.fetch;
  const originalCaches = globalThis.caches;
  const calls = [];
  globalThis.caches = { default: {
    async match() { return undefined; },
    async put() {},
  }};
  globalThis.fetch = async (input, init = {}) => {
    const url = String(input);
    calls.push(url);
    if (url === 'https://github.com/hidooch980/molidovpn-android/releases/latest') {
      return new Response(null, {
        status: 302,
        headers: { location: 'https://github.com/hidooch980/molidovpn-android/releases/tag/v4.0.2' },
      });
    }
    if (url === 'https://github.com/hidooch980/molidovpn-android/releases/download/v4.0.2/MolidoMeshAI-android-arm64.apk') {
      return new Response('signed-apk-fixture', { status: 200, headers: { 'content-length': '18' } });
    }
    throw new Error('Unexpected upstream URL: ' + url);
  };
  try {
    const response = await worker.fetch(request('/app/MolinoVPN-android-arm64.apk'.replace('MolinoVPN', 'MolidoVPN')), {}, ctx);
    assert.equal(response.status, 200);
    assert.equal(await response.text(), 'signed-apk-fixture');
    assert.ok(calls.includes('https://github.com/hidooch980/molidovpn-android/releases/latest'));
    assert.ok(calls.includes('https://github.com/hidooch980/molidovpn-android/releases/download/v4.0.2/MolidoMeshAI-android-arm64.apk'));
    assert.ok(calls.every((url) => !url.includes('/repos/hidooch980/molidovpn/releases/')));
  } finally {
    globalThis.fetch = originalFetch;
    globalThis.caches = originalCaches;
  }
});
