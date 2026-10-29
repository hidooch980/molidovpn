import { readFile } from 'node:fs/promises';
import { webcrypto } from 'node:crypto';
import assert from 'node:assert/strict';
import test from 'node:test';

if (!globalThis.crypto) Object.defineProperty(globalThis, 'crypto', { value: webcrypto });
// Exercise the real production functions; no duplicate cache implementation.
const source = await readFile(new URL('./sub-worker.js', import.meta.url), 'utf8');
const { cachedCatalog, catalogKey, nodeFingerprint, smartRankLines } = await import(
  'data:text/javascript;base64,' + Buffer.from(source + '\nexport { cachedCatalog, catalogKey, nodeFingerprint, smartRankLines };').toString('base64')
);
const edge = new Map();
globalThis.caches = { default: {
  async match(key) { return edge.get(String(key))?.clone(); },
  async put(key, response) { edge.set(String(key), response.clone()); },
}};
const ctx = { waitUntil(promise) { return promise; } };
const request = (path, init) => new Request('https://worker.example' + path, init);
const call = (req, build) => cachedCatalog(req, new URL(req.url), ctx, build);

test('polls and concurrent cold requests build once; conditional GET and HEAD have no body', async () => {
  let builds = 0;
  const build = async () => {
    builds++;
    await new Promise(resolve => setTimeout(resolve, 10));
    return new Response('vless://fixture', { headers: { 'content-type': 'text/plain', 'profile-title': 'MolidoVPN' } });
  };
  const responses = await Promise.all(Array.from({ length: 20 }, (_, i) => call(request('/sub/1?poll=' + i), build)));
  assert.equal(builds, 1);
  for (const r of responses) assert.equal(await r.text(), 'vless://fixture');
  const normal = await call(request('/sub/1'), build);
  const etag = normal.headers.get('etag');
  assert.match(etag, /^"[a-f0-9]{64}"$/);
  const unchanged = await call(request('/sub/1', { headers: { 'if-none-match': 'W/' + etag } }), build);
  assert.equal(unchanged.status, 304);
  assert.equal(await unchanged.text(), '');
  const head = await call(request('/sub/1', { method: 'HEAD' }), build);
  assert.equal(head.headers.get('etag'), etag);
  assert.equal(await head.text(), '');
  assert.equal(builds, 1);
});

test('errors are not cached and failed builds can retry', async () => {
  let calls = 0;
  const build = async () => ++calls === 1 ? new Response('unavailable', { status: 502 }) : new Response('recovered');
  assert.equal((await call(request('/sub/2'), build)).status, 502);
  assert.equal(await (await call(request('/sub/2'), build)).text(), 'recovered');
  assert.equal(calls, 2);
  await assert.rejects(call(request('/sub/3'), async () => { throw new Error('upstream'); }));
  assert.equal(await (await call(request('/sub/3'), async () => new Response('retry'))).text(), 'retry');
});

test('cache expires, retries the builder and preserves separate formats and routes', async () => {
  const now = Date.now;
  let time = now();
  Date.now = () => time;
  try {
    edge.clear();
    let n = 0;
    const build = async () => new Response('generation-' + ++n);
    assert.equal(await (await call(request('/ios'), build)).text(), 'generation-1');
    assert.equal(await (await call(request('/ios?format=singbox'), build)).text(), 'generation-2');
    assert.equal(await (await call(request('/ios/singbox?noise=yes'), build)).text(), 'generation-2');
    time += 60_001;
    edge.clear(); // model Cache API expiry
    assert.equal(await (await call(request('/ios'), build)).text(), 'generation-3');
  } finally { Date.now = now; }
  assert.equal(catalogKey(new URL('https://worker.example/sub/99')), null);
  assert.equal((await call(request('/unknown'), () => assert.fail('unknown route built'))).status, 404);
  assert.equal((await call(request('/sub/1', { method: 'POST' }), () => assert.fail('POST built'))).status, 405);
});

test('fingerprints retain protocol identity and ignore display names; no-evidence ranking is valid', async () => {
  const line = 'vless://id@example.com:443?security=tls&type=ws';
  const expected = Buffer.from(await webcrypto.subtle.digest('SHA-256', new TextEncoder().encode(line))).subarray(0, 8).toString('hex');
  assert.equal(await nodeFingerprint(line + '#first'), expected);
  assert.equal(await nodeFingerprint(line + '#renamed'), expected);
  const quic = 'hysteria2://id@example.com:443';
  assert.deepEqual(await smartRankLines([quic, line], null), [line, quic]);
});
