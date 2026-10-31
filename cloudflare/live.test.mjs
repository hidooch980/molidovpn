import { readFile } from 'node:fs/promises';
import { webcrypto } from 'node:crypto';
import assert from 'node:assert/strict';
import test from 'node:test';

if (!globalThis.crypto) Object.defineProperty(globalThis, 'crypto', { value: webcrypto });
const source = await readFile(new URL('./sub-worker.js', import.meta.url), 'utf8');
const { liveBody, livePush, parseDiag, INSTALL_RE } = await import(
  'data:text/javascript;base64,' + Buffer.from(source + '\nexport { liveBody, livePush, parseDiag, INSTALL_RE };').toString('base64')
);

const kv = {
  flags: { default_mode: 'v2ray', disabled: ['tor'] },
  notice: { id: 'n1', enabled: true, text: 'سلام', type: 'info' },
};
const env = (extra = {}) => ({
  DB: { prepare: () => ({ bind: (k) => ({ first: async () => (kv[k] ? { v: JSON.stringify(kv[k]) } : null) }) }) },
  ...extra,
});

test('live body carries normalized flags and the active notice', async () => {
  const b = await liveBody(env());
  assert.deepEqual(b.flags, { v: 1, default_mode: 'v2ray', disabled: ['tor'], notice: true });
  assert.equal(b.notice.id, 'n1');
});

test('push is signed with the secret key and verifies with the public key', async () => {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const jwk = JSON.stringify(await crypto.subtle.exportKey('jwk', pair.privateKey));
  const sent = [];
  globalThis.fetch = async (url, init) => { sent.push({ url, body: init.body }); return new Response('{}'); };
  await livePush(env({ LIVE_SIGN_KEY: jwk, LIVE_TOPIC: 'topic-x' }));
  assert.equal(sent.length, 1);
  assert.equal(sent[0].url, 'https://ntfy.sh/topic-x');
  const msg = JSON.parse(sent[0].body);
  const ok = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, pair.publicKey,
    Buffer.from(msg.s, 'base64'), new TextEncoder().encode(msg.p));
  assert.ok(ok);
  assert.equal(JSON.parse(msg.p).t, 'live');
});

test('no secret: nothing is sent', async () => {
  let calls = 0;
  globalThis.fetch = async () => { calls++; return new Response(''); };
  await livePush(env({ LIVE_TOPIC: 'topic-x' }));
  assert.equal(calls, 0);
});

test('install id format is MLD + two Crockford base32 groups', () => {
  assert.ok(INSTALL_RE.test('MLD-7K2M-9QXZ'));
  for (const bad of ['MLD-7K2M-9QXI', 'MLD-7k2m-9qxz', 'mld-7K2M-9QXZ', 'MLD-7K2M9QXZ', 'MLD-7K2M-9QXU']) assert.ok(!INSTALL_RE.test(bad), bad);
});

test('diag bodies are validated, clipped and capped', () => {
  assert.equal(parseDiag({ install_id: 'nope', events: [{}] }), null);
  assert.equal(parseDiag({ install_id: 'MLD-0000-0000', events: [] }), null);
  const d = parseDiag({
    install_id: 'MLD-0000-0000', op: 'mci', mccmnc: '43211', ver: '3.2.1',
    events: Array.from({ length: 100 }, (_, i) => ({ at: 1, kind: 'error', method: 'v2ray', msg: 'x'.repeat(1000) + i })),
  });
  assert.equal(d.events.length, 60);
  assert.equal(d.events[0].msg.length, 400);
  assert.ok(d.events[0].at > 1_700_000_000); // clamped into the retention window
  assert.equal(parseDiag({ install_id: 'MLD-0000-0000', op: 'evil', events: [{}] }).op, null);
  assert.equal(parseDiag({ install_id: 'MLD-0000-0000', mccmnc: '12', events: [{}] }).mccmnc, null);
});
