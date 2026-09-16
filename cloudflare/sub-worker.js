// MolidoVPN subscription link (Cloudflare Worker, free plan).
// Serves the server list from GitHub under your own worker address, with a profile name and
// auto-update interval that Hiddify / Streisand / v2rayNG show. /lite = small list for iPhone.
const FULL = 'https://raw.githubusercontent.com/hidooch980/vpn-sub/sub/sub_base64.txt';
const LITE = 'https://raw.githubusercontent.com/hidooch980/vpn-sub/sub/lite_base64.txt';
const MIRROR = (file) => `https://cdn.jsdelivr.net/gh/hidooch980/vpn-sub@sub/${file}`;

const REPO = 'hidooch980/mobin-vpn';

// App updates through this worker, for networks where github.com / api.github.com are slow or filtered.
// /app/latest.json — same shape as the GitHub "latest release" API, with download URLs pointing back here.
// /app/<asset>      — streams that asset of the latest release.
async function appRoute(url, request, ctx) {
  const name = url.pathname.slice('/app/'.length);
  if (name === 'latest.json') {
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { 'user-agent': 'MolidoVPN-worker', accept: 'application/vnd.github+json' },
      cf: { cacheTtl: 300, cacheEverything: true },
    });
    if (!res.ok) return new Response('release info unavailable', { status: 502 });
    const r = await res.json();
    const body = {
      tag_name: r.tag_name,
      published_at: r.published_at,
      // Old apps (<= rename) look for MobinVPN-* names: list each asset under both names.
      assets: r.assets.flatMap((a) => {
        const one = (n) => ({ name: n, size: a.size, browser_download_url: `${url.origin}/app/${n}` });
        return a.name.startsWith('MolidoVPN-') ? [one(a.name), one(a.name.replace(/^MolidoVPN-/, 'MobinVPN-'))] : [one(a.name)];
      }),
    };
    return new Response(JSON.stringify(body), {
      headers: { 'content-type': 'application/json', 'cache-control': 'public, max-age=300', 'access-control-allow-origin': '*' },
    });
  }
  if (name === 'changelog.json') {
    const v = (url.searchParams.get('v') || '').replace(/^v/, '');
    const path = /^[0-9.]+$/.test(v) ? `download/v${v}` : 'latest/download';
    const res = await fetch(`https://github.com/${REPO}/releases/${path}/changelog.json`, {
      redirect: 'follow', cf: { cacheTtl: 3600, cacheEverything: true },
    });
    if (!res.ok) return new Response('{"items":[]}', { status: 404, headers: { 'content-type': 'application/json' } });
    return new Response(await res.text(), {
      headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'public, max-age=3600', 'access-control-allow-origin': '*' },
    });
  }
  if (!/^[A-Za-z0-9._-]+\.(apk|zip|exe)$/.test(name)) return new Response('not found', { status: 404 });
  return appAsset(name, request, ctx);
}

// Release downloads through Cloudflare's edge: cached per release tag in caches.default (object max 512 MB on
// the free plan; our largest asset is ~150 MB), streamed (no worker memory limit hit), Range → 206 for resume.
// Old names (MobinVPN-*) map to the renamed MolidoVPN-* assets so already-installed apps still update.
async function latestTag() {
  const res = await fetch(`https://github.com/${REPO}/releases/latest`, { redirect: 'manual', cf: { cacheTtl: 120, cacheEverything: true } });
  return (res.headers.get('location') || '').match(/\/tag\/([^/?#]+)/)?.[1] || null;
}

async function appAsset(name, request, ctx) {
  const file = name.replace(/^MobinVPN-/, 'MolidoVPN-');
  const tag = await latestTag();
  const headers = {
    'content-type': file.endsWith('.apk') ? 'application/vnd.android.package-archive' : 'application/octet-stream',
    'content-disposition': `attachment; filename="${file}"`,
    'cache-control': 'public, max-age=86400',
    'accept-ranges': 'bytes',
    'access-control-allow-origin': '*',
  };
  const range = request.headers.get('range');
  const cache = caches.default;
  const key = tag ? `https://molido-cache.invalid/app/${tag}/${file}` : null;
  if (key && request.method === 'GET') {
    const hit = await cache.match(new Request(key, { headers: range ? { range } : {} }));
    if (hit) {
      const h = new Headers(hit.headers); h.set('x-cache', 'HIT');
      return new Response(hit.body, { status: hit.status, headers: h });
    }
  }
  const src = (n) => tag ? `https://github.com/${REPO}/releases/download/${tag}/${n}` : `https://github.com/${REPO}/releases/latest/download/${n}`;
  const get = async (h) => {
    let r = await fetch(src(file), { redirect: 'follow', headers: h });
    if (r.status === 404 && file !== name) r = await fetch(src(name), { redirect: 'follow', headers: h });
    return r;
  };
  const res = await get(range ? { range } : {});
  if (!(res.status === 200 || res.status === 206)) return new Response('download unavailable', { status: 502 });
  const out = new Headers(headers);
  for (const k of ['content-length', 'content-range']) if (res.headers.get(k)) out.set(k, res.headers.get(k));
  out.set('x-cache', 'MISS');
  if (key && request.method === 'GET') {
    // Fill the cache with a separate full fetch (a tee would buffer in worker memory for slow clients).
    ctx.waitUntil((async () => {
      const full = range ? await get({}) : null;
      const body = full || null;
      if (range && !(body && body.status === 200)) return;
      const src2 = body || await get({});
      if (src2.status !== 200) return;
      const h = new Headers(headers); h.set('cache-control', 'public, max-age=31536000, immutable');
      if (src2.headers.get('content-length')) h.set('content-length', src2.headers.get('content-length'));
      await cache.put(key, new Response(src2.body, { status: 200, headers: h }));
    })().catch(() => {}));
  }
  return new Response(request.method === 'HEAD' ? null : res.body, { status: res.status, headers: out });
}

// /remote/<file> — app config files from the android repo, for networks where GitHub is filtered.
const REMOTE_FILES = {
  'policy.json': 'application/json; charset=utf-8',
  'shard-nodes.txt': 'text/plain; charset=utf-8',
  'smart-split.json': 'application/json; charset=utf-8',
};
async function remoteRoute(url) {
  const name = url.pathname.slice('/remote/'.length);
  const type = REMOTE_FILES[name];
  if (!type) return new Response('not found', { status: 404 });
  const sources = [
    `https://raw.githubusercontent.com/hidooch980/molidovpn-android/main/remote/${name}`,
    `https://cdn.jsdelivr.net/gh/hidooch980/molidovpn-android@main/remote/${name}`,
  ];
  for (const source of sources) {
    const res = await fetch(source, { cf: { cacheTtl: 300, cacheEverything: true } }).catch(() => null);
    if (!res || !res.ok) continue;
    return new Response(await res.text(), {
      headers: { 'content-type': type, 'cache-control': 'public, max-age=300', 'access-control-allow-origin': '*' },
    });
  }
  return new Response('file unavailable', { status: 502 });
}

// WARP device registration relay: api.cloudflareclient.com is often reset from Iran. Forwards the app's
// registration POST unchanged (only a public key goes up; the private key never leaves the device).
async function warpRegRoute(request) {
  if (request.method !== 'POST') return new Response('method not allowed', { status: 405 });
  const body = await request.text();
  if (body.length > 2048) return new Response('bad request', { status: 400 });
  const res = await fetch('https://api.cloudflareclient.com/v0a2158/reg', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'user-agent': 'okhttp/3.12.1', 'cf-client-version': 'a-6.10-2158' },
    body,
  });
  return new Response(await res.text(), {
    status: res.status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  });
}

// Anonymous opt-in connection reports, aggregated per UTC day in D1. No IPs are stored.
const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
  'access-control-allow-headers': 'content-type',
};
const NODE_RE = /^([0-9a-f]{16}|mode:[a-z0-9_-]{1,20})$/;
const NETS = new Set(['wifi', 'cellular', 'other']);
const APPS = new Set(['android', 'windows']);
// Iranian operator bucket, stored inside the net column as "<net>|<op>" so the table keeps its key.
const OPS = new Set(['mci', 'irancell', 'tci', 'rightel', 'shatel', 'other']);
const MODE_RE = /^[a-z0-9_-]{1,20}$/;
const LIMIT_PER_MIN = 60;
const hits = new Map(); // in-memory only (per isolate): client-ip -> {minute, n}

function limited(ip) {
  const minute = Math.floor(Date.now() / 60000);
  if (hits.size > 5000) hits.clear();
  const h = hits.get(ip);
  if (!h || h.minute !== minute) {
    hits.set(ip, { minute, n: 1 });
    return false;
  }
  return ++h.n > LIMIT_PER_MIN;
}

const bad = () => new Response('bad request', { status: 400, headers: CORS });

async function reportRoute(request, env, ctx) {
  if (request.method !== 'POST') return new Response('method not allowed', { status: 405, headers: CORS });
  const len = Number(request.headers.get('content-length') || 0);
  if (len > 1024) return bad();
  const text = await request.text();
  if (text.length > 1024) return bad();
  let r;
  try {
    r = JSON.parse(text);
  } catch {
    return bad();
  }
  if (!r || typeof r !== 'object' || Array.isArray(r)) return bad();
  if (r.v !== 1 || typeof r.node !== 'string' || !NODE_RE.test(r.node)) return bad();
  if (typeof r.ok !== 'boolean' || !NETS.has(r.net) || !APPS.has(r.app)) return bad();
  if (typeof r.ver !== 'string' || r.ver.length > 32) return bad();
  if (r.op !== undefined && r.op !== null && !OPS.has(r.op)) return bad();
  const netKey = r.op ? `${r.net}|${r.op}` : r.net;
  // Optional connection mode (newer apps): also counted under "mode:<mode>" in a row marked "|m" so daily
  // totals do not count it twice while per-operator mode stats and scores can use it.
  if (r.mode !== undefined && r.mode !== null && (typeof r.mode !== 'string' || !MODE_RE.test(r.mode))) return bad();
  const ms = r.ms;
  if (!(ms === null || ms === undefined || (Number.isInteger(ms) && ms >= 1 && ms <= 60000))) return bad();
  // Optional working clean Cloudflare IP {ip, ms}, shared per operator via /cfip.
  let cf = null;
  if (r.cfip !== undefined && r.cfip !== null) {
    const c = r.cfip;
    if (!c || typeof c !== 'object' || !isCfIpv4(c.ip) || !Number.isInteger(c.ms) || c.ms < 1 || c.ms > 10000) return bad();
    cf = { ip: c.ip, ms: c.ms };
  }

  if (limited(request.headers.get('cf-connecting-ip') || 'unknown')) return new Response(null, { status: 204, headers: CORS });

  // Local Iran tester result for an owner config: kept separately (latest run + consecutive failures) so
  // the reports table for owner configs holds only real app reports from users.
  if (r.owner === true && r.ver === 'local-iran-test') {
    let isOwner = false;
    try {
      isOwner = (await ownerFps(env, ctx)).has(r.node);
    } catch {}
    if (isOwner) {
      const now = Date.now();
      await env.DB.prepare(
        `INSERT INTO owner_tests (fp, ok, ms, tested_at, fail_streak) VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(fp) DO UPDATE SET
           fail_streak = CASE WHEN excluded.ok = 1 THEN 0
             WHEN owner_tests.ok = 0 AND owner_tests.tested_at > ?6 THEN owner_tests.fail_streak
             ELSE owner_tests.fail_streak + 1 END,
           ok = excluded.ok, ms = excluded.ms, tested_at = excluded.tested_at`
      )
        .bind(r.node, r.ok ? 1 : 0, r.ok && Number.isInteger(ms) ? ms : null, now, r.ok ? 0 : 1, now - OWNER_RUN_GAP_MS)
        .run();
      return new Response(null, { status: 204, headers: CORS });
    }
  }

  const day = new Date().toISOString().slice(0, 10);
  const hasMs = Number.isInteger(ms) ? 1 : 0;
  const upsert = (node, net) =>
    env.DB.prepare(
      `INSERT INTO reports (day, node, app, net, ok, fail, ms_sum, ms_n) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
       ON CONFLICT(day, node, app, net) DO UPDATE SET ok = ok + excluded.ok, fail = fail + excluded.fail,
         ms_sum = ms_sum + excluded.ms_sum, ms_n = ms_n + excluded.ms_n`
    ).bind(day, node, r.app, net, r.ok ? 1 : 0, r.ok ? 0 : 1, hasMs ? ms : 0, hasMs);
  const writes = [upsert(r.node, netKey)];
  if (r.mode && !r.node.startsWith('mode:')) writes.push(upsert(`mode:${r.mode}`, `${netKey}|m`));
  if (cf && r.ok) {
    await ensureCfSchema(env);
    writes.push(
      env.DB.prepare(
        `INSERT INTO cf_ips (op, ip, ok_count, ms_avg, updated) VALUES (?1, ?2, 1, ?3, ?4)
         ON CONFLICT(op, ip) DO UPDATE SET ok_count = ok_count + 1,
           ms_avg = (ms_avg * 3 + excluded.ms_avg) / 4, updated = excluded.updated`
      ).bind(r.op || 'other', cf.ip, cf.ms, Date.now())
    );
  }
  await env.DB.batch(writes);
  return new Response(null, { status: 204, headers: CORS });
}

// Anonymous opt-in "currently connected" heartbeats. No IPs stored, same session id the app already
// generates for /report. Upserts last_seen; a session with no heartbeat for a while just ages out.
let activeSchemaReady = false;
async function ensureActiveSchema(env) {
  if (activeSchemaReady) return;
  await env.DB.prepare(
    'CREATE TABLE IF NOT EXISTS active_sessions (session_id TEXT PRIMARY KEY, op TEXT, mode TEXT, last_seen INTEGER NOT NULL)'
  ).run();
  activeSchemaReady = true;
}
const SESSION_RE = /^[A-Za-z0-9_-]{8,64}$/;
const ONLINE_WINDOW_S = 90;
const ACTIVE_PRUNE_S = 600;

async function heartbeatRoute(request, env, ctx) {
  if (request.method !== 'POST') return new Response('method not allowed', { status: 405, headers: CORS });
  const len = Number(request.headers.get('content-length') || 0);
  if (len > 512) return bad();
  const text = await request.text();
  if (text.length > 512) return bad();
  let r;
  try {
    r = JSON.parse(text);
  } catch {
    return bad();
  }
  if (!r || typeof r !== 'object' || Array.isArray(r)) return bad();
  if (typeof r.session_id !== 'string' || !SESSION_RE.test(r.session_id)) return bad();
  if (r.op !== undefined && r.op !== null && !OPS.has(r.op)) return bad();
  if (r.mode !== undefined && r.mode !== null && (typeof r.mode !== 'string' || !MODE_RE.test(r.mode))) return bad();

  if (limited(request.headers.get('cf-connecting-ip') || 'unknown')) return new Response(null, { status: 204, headers: CORS });

  await ensureActiveSchema(env);
  await env.DB.prepare(
    `INSERT INTO active_sessions (session_id, op, mode, last_seen) VALUES (?1, ?2, ?3, ?4)
     ON CONFLICT(session_id) DO UPDATE SET op = excluded.op, mode = excluded.mode, last_seen = excluded.last_seen`
  )
    .bind(r.session_id, r.op || null, r.mode || null, Math.floor(Date.now() / 1000))
    .run();
  return new Response(null, { status: 204, headers: CORS });
}

// GET /admin/api/online — admin-only, no caching (must be fresh).
async function onlineRoute(env) {
  await ensureActiveSchema(env);
  const since = Math.floor(Date.now() / 1000) - ONLINE_WINDOW_S;
  const { results } = await env.DB.prepare('SELECT op, mode FROM active_sessions WHERE last_seen > ?1').bind(since).all();
  const byOperator = { mci: 0, irancell: 0, tci: 0, other: 0 };
  const byMode = {};
  for (const row of results) {
    const op = STAT_OPS.includes(row.op) ? row.op : 'other';
    byOperator[op]++;
    const mode = row.mode || 'unknown';
    byMode[mode] = (byMode[mode] || 0) + 1;
  }
  return adminJson({ count: results.length, byOperator, byMode });
}

// Cloudflare IPv4 ranges (https://www.cloudflare.com/ips-v4); none overlap private space.
const CF_V4 = [
  '173.245.48.0/20', '103.21.244.0/22', '103.22.200.0/22', '103.31.4.0/22', '141.101.64.0/18',
  '108.162.192.0/18', '190.93.240.0/20', '188.114.96.0/20', '197.234.240.0/22', '198.41.128.0/17',
  '162.158.0.0/15', '104.16.0.0/13', '104.24.0.0/14', '172.64.0.0/13', '131.0.72.0/22',
];
const ipv4Int = (ip) => ip.split('.').reduce((a, p) => a * 256 + Number(p), 0);
function isCfIpv4(ip) {
  if (typeof ip !== 'string' || !/^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/.test(ip)) return false;
  if (/^(10\.|127\.|0\.|169\.254\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(ip)) return false;
  const v = ipv4Int(ip);
  return CF_V4.some((r) => {
    const [base, bits] = r.split('/');
    const size = 2 ** (32 - Number(bits));
    const start = ipv4Int(base);
    return v >= start && v < start + size;
  });
}

let cfSchemaReady = false;
async function ensureCfSchema(env) {
  if (cfSchemaReady) return;
  await env.DB.prepare(
    'CREATE TABLE IF NOT EXISTS cf_ips (op TEXT NOT NULL, ip TEXT NOT NULL, ok_count INTEGER NOT NULL, ms_avg INTEGER NOT NULL, updated INTEGER NOT NULL, PRIMARY KEY (op, ip))'
  ).run();
  cfSchemaReady = true;
}

// Top clean Cloudflare IPs reported working on this operator in the last 3 days (global when none), cached 5 min.
async function cfipRoute(request, env, ctx) {
  const opParam = new URL(request.url).searchParams.get('op');
  const op = OPS.has(opParam) ? opParam : '';
  const key = new Request(new URL(`/cfip?op=${op}`, request.url).toString());
  const hit = await caches.default.match(key);
  if (hit) return hit;
  let out = [];
  try {
    await ensureCfSchema(env);
    const since = Date.now() - 3 * 86400000;
    const query = (byOp) =>
      env.DB.prepare(
        `SELECT ip, SUM(ok_count) ok, CAST(AVG(ms_avg) AS INTEGER) ms FROM cf_ips
         WHERE updated > ?1 ${byOp ? 'AND op = ?2' : ''} GROUP BY ip ORDER BY ok * 1000 / (ms + 50) DESC LIMIT 10`
      ).bind(...(byOp ? [since, op] : [since]));
    if (op) out = (await query(true).all()).results;
    if (!out.length) out = (await query(false).all()).results;
  } catch {}
  const res = new Response(JSON.stringify(out.map((r) => ({ ip: r.ip, ms: r.ms, n: r.ok }))), {
    headers: { 'content-type': 'application/json', 'cache-control': 'public, max-age=300', ...CORS },
  });
  ctx.waitUntil(caches.default.put(key, res.clone()));
  return res;
}

function summarize(s) {
  return {
    ok: s.ok,
    fail: s.fail,
    n: s.ok + s.fail,
    ms: s.ms_n ? Math.round(s.ms_sum / s.ms_n) : null,
    score: Math.round(((s.ok + 1) / (s.ok + s.fail + 2)) * 1000) / 1000,
  };
}

async function scoresRoute(request, env, ctx) {
  const cache = caches.default;
  // ?op=mci|irancell|… limits the scores to reports from that operator ("mode:<name>" keys included, so apps
  // can rank connection modes per operator; each entry carries n = reports, apps fall back to global when low).
  const opParam = new URL(request.url).searchParams.get('op');
  const op = OPS.has(opParam) ? opParam : '';
  const key = new Request(new URL(`/scores?op=${op}`, request.url).toString());
  const hit = await cache.match(key);
  if (hit) return hit;

  const since = new Date(Date.now() - 6 * 86400000).toISOString().slice(0, 10);
  const { results } = await env.DB.prepare(
    `SELECT node, net, SUM(ok) ok, SUM(fail) fail, SUM(ms_sum) ms_sum, SUM(ms_n) ms_n
     FROM reports WHERE day >= ?1 AND (?2 = '' OR net LIKE '%|' || ?2 OR net LIKE '%|' || ?2 || '|m') GROUP BY node, net`
  )
    .bind(since, op)
    .all();
  const acc = {};
  for (const row of results) {
    const a = (acc[row.node] ||= { all: { ok: 0, fail: 0, ms_sum: 0, ms_n: 0 } });
    const baseNet = String(row.net).split('|')[0];
    for (const k of [baseNet === 'cellular' || baseNet === 'wifi' ? baseNet : null, 'all']) {
      if (!k) continue;
      const s = (a[k] ||= { ok: 0, fail: 0, ms_sum: 0, ms_n: 0 });
      s.ok += row.ok; s.fail += row.fail; s.ms_sum += row.ms_sum; s.ms_n += row.ms_n;
    }
  }
  const out = {};
  for (const [node, a] of Object.entries(acc)) {
    out[node] = summarize(a.all);
    if (a.cellular) out[node].cellular = summarize(a.cellular);
    if (a.wifi) out[node].wifi = summarize(a.wifi);
  }
  const res = new Response(JSON.stringify(out), {
    headers: { 'content-type': 'application/json', 'cache-control': 'public, max-age=300', ...CORS },
  });
  ctx.waitUntil(cache.put(key, res.clone()));
  return res;
}

// iPhone list (/lite, /ios; /hiddify also adds WARP). Built for Iranian networks and iOS clients:
// CDN-fronted SHARD nodes first (VLESS/Trojan over WebSocket+TLS behind Cloudflare — what works best
// in Iran), then TLS/Reality/QUIC nodes from the tested list. Plain Shadowsocks and non-TLS VMess are
// dropped: they are the first to be blocked and waste the client's connect attempts.
const IOS_MAX = 80;
const decodeList = (body) => {
  const t = body.trim();
  if (t.includes('://')) return t;
  try {
    return atob(t.replace(/\s/g, ''));
  } catch {
    return '';
  }
};
const iosFriendly = (line) => {
  const scheme = line.slice(0, line.indexOf('://')).toLowerCase();
  if (scheme === 'hysteria2' || scheme === 'hy2' || scheme === 'tuic') return true;
  if (scheme !== 'vless' && scheme !== 'trojan') return false;
  const q = new URLSearchParams(line.split('#')[0].split('?')[1] || '');
  const sec = (q.get('security') || (scheme === 'trojan' ? 'tls' : '')).toLowerCase();
  return sec === 'tls' || sec === 'reality';
};

// /sub/1 … /sub/5: five separate links, 50–100 configs each, different servers per link, so a family
// member can add two or three and still have a working list when one gets filtered.
const SUB_LINKS = 5;
const SUB_MIN = 50;
const SUB_MAX = 100;
const strongTransport = (line) => iosFriendly(line.split('#')[0]);

// Iran-measured quality from the anonymous reports (apps + local Iran tests), last 7 days.
async function reportScores(env) {
  try {
    const since = new Date(Date.now() - 6 * 86400000).toISOString().slice(0, 10);
    const { results } = await env.DB.prepare(
      'SELECT node, SUM(ok) ok, SUM(fail) fail FROM reports WHERE day >= ?1 GROUP BY node'
    )
      .bind(since)
      .all();
    return new Map(results.map((r) => [r.node, r]));
  } catch {
    return new Map();
  }
}

async function nodeFingerprint(line) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(line.split('#')[0].trim()));
  return [...new Uint8Array(digest)].slice(0, 8).map((b) => b.toString(16).padStart(2, '0')).join('');
}

// 0 = worked in Iran, 1 = no data, 2 = only failures in Iran. Stable within a tier.
async function rankByReports(lines, scores) {
  if (!scores.size) return lines;
  const tiers = await Promise.all(
    lines.map(async (line) => {
      const s = scores.get(await nodeFingerprint(line));
      if (!s) return [1, 0];
      if (s.ok > 0) return [0, -(s.ok + 1) / (s.ok + s.fail + 2)];
      return [2, 0];
    })
  );
  return lines
    .map((line, i) => ({ line, t: tiers[i], i }))
    .sort((a, b) => a.t[0] - b.t[0] || a.t[1] - b.t[1] || a.i - b.i)
    .map((x) => x.line);
}

// Drop servers that only ever failed from inside Iran, as long as at least [min] others remain.
async function dropIranFailed(lines, scores, min) {
  if (!scores.size) return lines;
  const failed = await Promise.all(
    lines.map(async (line) => {
      const s = scores.get(await nodeFingerprint(line));
      return !!s && s.ok === 0 && s.fail > 0;
    })
  );
  const kept = lines.filter((_, i) => !failed[i]);
  return kept.length >= min ? kept : lines;
}

// Every config is shown as "<location flag> MolidoVPN NN" (flag taken from the tested name; 🌐 when unknown).
function brand(lines) {
  const counters = new Map();
  return lines.map((line) => {
    const hash = line.indexOf('#');
    const core = hash >= 0 ? line.slice(0, hash) : line;
    if (!core.includes('://') || core.startsWith('warp://')) return line;
    let name = '';
    try {
      name = hash >= 0 ? decodeURIComponent(line.slice(hash + 1)) : '';
    } catch {
      name = line.slice(hash + 1);
    }
    let flag = (name.match(/\p{Regional_Indicator}{2}/u) || [])[0];
    if (!flag && core.startsWith('vmess://')) {
      try {
        flag = (JSON.parse(atob(core.slice(8))).ps || '').match(/\p{Regional_Indicator}{2}/u)?.[0];
      } catch {}
    }
    flag = flag || '🌐';
    const vip = lines.vip?.has(lineCore(line)) ? ' VIP' : '';
    const n = (counters.get(flag + vip) || 0) + 1;
    counters.set(flag + vip, n);
    const label = `${flag} MolidoVPN ${String(n).padStart(2, '0')}${vip}`;
    if (core.startsWith('vmess://')) {
      try {
        const j = JSON.parse(atob(core.slice(8)));
        j.ps = label;
        const bytes = new TextEncoder().encode(JSON.stringify(j));
        let bin = '';
        for (const b of bytes) bin += String.fromCharCode(b);
        return `vmess://${btoa(bin)}`;
      } catch {
        return `${core}#${encodeURIComponent(label)}`;
      }
    }
    return `${core}#${encodeURIComponent(label)}`;
  });
}

async function subRoute(url, env, ctx) {
  const n = Number(url.pathname.split('/')[2]);
  if (!Number.isInteger(n) || n < 1 || n > SUB_LINKS) return new Response('use /sub/1 … /sub/5', { status: 404 });
  const owner = ownerLines(env, ctx);
  const get = (u) =>
    fetch(u, { cf: { cacheTtl: 300, cacheEverything: true } })
      .then((r) => (r.ok ? r.text() : ''))
      .catch(() => '');
  const [shard, full] = await Promise.all([
    get('https://raw.githubusercontent.com/hidooch980/molidovpn-android/main/remote/shard-nodes.txt').then(
      (t) => t || get('https://cdn.jsdelivr.net/gh/hidooch980/molidovpn-android@main/remote/shard-nodes.txt')
    ),
    get(FULL).then((t) => t || get(MIRROR('sub_base64.txt'))),
  ]);

  // Pool in quality order: CDN nodes, then TLS/Reality/QUIC, then everything else (tested list order).
  const seen = new Set();
  const cdn = [], strong = [], rest = [];
  let c = 0;
  for (const l of shard.split('\n')) {
    const line = l.trim();
    if (!line.includes('://') || line.startsWith('#')) continue;
    const core = line.split('#')[0];
    if (seen.has(core)) continue;
    seen.add(core);
    cdn.push(`${core}#${encodeURIComponent(`MolidoVPN CDN ${++c}`)}`);
  }
  for (const l of decodeList(full).split('\n')) {
    const line = l.trim();
    if (!line.includes('://')) continue;
    const core = line.split('#')[0];
    if (seen.has(core)) continue;
    seen.add(core);
    (strongTransport(line) ? strong : rest).push(line);
  }

  // Deal the non-CDN pool round-robin so every link gets a similar mix, then top each link up with
  // CDN nodes (shared across links — they are the most reliable in Iran) to reach at least SUB_MIN.
  const scores = await reportScores(env);
  const ranked = await rankByReports([...strong, ...rest], scores);
  const cdnRanked = await rankByReports(cdn, scores);
  cdn.splice(0, cdn.length, ...cdnRanked);
  const buckets = Array.from({ length: SUB_LINKS }, () => []);
  ranked.forEach((line, i) => {
    const b = buckets[i % SUB_LINKS];
    if (b.length < SUB_MAX - 20) b.push(line);
  });
  const mine = buckets[n - 1];
  const cdnShare = cdn.filter((_, i) => i % SUB_LINKS === n - 1);
  const cdnOthers = cdn.filter((_, i) => i % SUB_LINKS !== n - 1);
  const lines = [...cdnShare, ...mine];
  while (lines.length < SUB_MIN && cdnOthers.length) lines.push(cdnOthers.shift());
  if (!lines.length) return new Response('server list unavailable, try again shortly', { status: 502 });
  const clean = await dropIranFailed(await rankByReports(lines, scores), scores, SUB_MIN);
  return listResponse(brand(mergeOwner(await owner, clean.slice(0, SUB_MAX))), `MolidoVPN ${n}`);
}

function listResponse(lines, title) {
  const bytes = new TextEncoder().encode(lines.join('\n'));
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return new Response(btoa(bin), {
    headers: {
      'content-type': 'text/plain; charset=utf-8',
      'profile-title': 'base64:' + btoa(title),
      'profile-update-interval': '1',
      'profile-web-page-url': 'https://hidooch980.github.io/mobin-vpn/',
      'cache-control': 'public, max-age=300',
      'access-control-allow-origin': '*',
    },
  });
}

async function iosRoute(url, env, ctx) {
  const owner = ownerLines(env, ctx);
  const get = (u) =>
    fetch(u, { cf: { cacheTtl: 300, cacheEverything: true } })
      .then((r) => (r.ok ? r.text() : ''))
      .catch(() => '');
  const [shard, full, lite] = await Promise.all([
    get('https://raw.githubusercontent.com/hidooch980/molidovpn-android/main/remote/shard-nodes.txt').then(
      (t) => t || get('https://cdn.jsdelivr.net/gh/hidooch980/molidovpn-android@main/remote/shard-nodes.txt')
    ),
    get(FULL).then((t) => t || get(MIRROR('sub_base64.txt'))),
    get(LITE).then((t) => t || get(MIRROR('lite_base64.txt'))),
  ]);

  const seen = new Set();
  const out = [];
  const add = (line, name) => {
    line = line.trim();
    if (!line.includes('://') || line.startsWith('#')) return;
    const core = line.split('#')[0];
    if (seen.has(core) || !iosFriendly(core)) return;
    seen.add(core);
    out.push(name ? `${core}#${encodeURIComponent(name)}` : line);
  };
  let cdn = 0;
  for (const l of shard.split('\n')) if (l.includes('://')) add(l, `MolidoVPN CDN ${++cdn}`);
  for (const l of decodeList(lite).split('\n')) add(l);
  for (const l of decodeList(full).split('\n')) add(l);

  // Collect everything iPhone-friendly, put Iran-proven servers first, drop Iran-failed ones when
  // enough others exist, then cap for the iOS memory limit.
  const scores = await reportScores(env);
  const rankedOut = await rankByReports(out, scores);
  const lines = brand(mergeOwner(await owner, (await dropIranFailed(rankedOut, scores, 20)).slice(0, IOS_MAX)));
  if (url.pathname.startsWith('/hiddify')) lines.unshift('warp://auto#MolidoVPN%20WARP', 'warp://p2@auto#MolidoVPN%20WARP%20in%20WARP');
  if (!lines.length) return new Response('server list unavailable, try again shortly', { status: 502 });

  const bytes = new TextEncoder().encode(lines.join('\n'));
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return new Response(btoa(bin), {
    headers: {
      'content-type': 'text/plain; charset=utf-8',
      'profile-title': 'base64:' + btoa('MolidoVPN'),
      'profile-update-interval': '1',
      'profile-web-page-url': 'https://hidooch980.github.io/mobin-vpn/',
      'cache-control': 'public, max-age=300',
      'access-control-allow-origin': '*',
    },
  });
}

// ---------------------------------------------------------------------------------------------------
// Owner items: subscription links and single configs the owner adds from /admin. They are placed first
// in every list (/, /lite, /ios, /hiddify, /sub/1..5) and reach all users on their next list refresh.
// ---------------------------------------------------------------------------------------------------
const OWNER_SCHEMES = new Set(['vless', 'vmess', 'trojan', 'ss', 'hysteria2', 'hy2', 'tuic', 'wireguard']);
const OWNER_MAX_ITEMS = 300; // rows in owner_items
const OWNER_MAX_LINES = 150; // owner configs merged into one list
const OWNER_SUB_MAX_LINES = 100; // configs taken from one owner sub link
const OWNER_CONFIG_MAX_LEN = 4096;
const OWNER_URL_MAX_LEN = 2048;
const OWNER_NOTE_MAX_LEN = 200;
const OWNER_SUB_TTL = 600; // seconds
const ADMIN_MAX_FAILS = 5;
const ADMIN_LOCK_MS = 15 * 60000;

let ownerSchemaReady = false;
async function ensureOwnerSchema(env) {
  if (ownerSchemaReady) return;
  await env.DB.batch([
    env.DB.prepare(
      `CREATE TABLE IF NOT EXISTS owner_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL CHECK (kind IN ('sub', 'config')),
        value TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        enabled INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL
      )`
    ),
    env.DB.prepare(
      'CREATE TABLE IF NOT EXISTS admin_fails (ip_hash TEXT PRIMARY KEY, fails INTEGER NOT NULL, locked_until INTEGER NOT NULL, updated INTEGER NOT NULL)'
    ),
    // Latest local Iran test per owner config fingerprint (from iran_node_test.py via /report with owner:true).
    env.DB.prepare(
      'CREATE TABLE IF NOT EXISTS owner_tests (fp TEXT PRIMARY KEY, ok INTEGER NOT NULL, ms INTEGER, tested_at INTEGER NOT NULL, fail_streak INTEGER NOT NULL DEFAULT 0)'
    ),
    // Owner settings set in /admin: 'notice' (announcement) and 'flags' (remote app config), JSON values.
    env.DB.prepare('CREATE TABLE IF NOT EXISTS owner_kv (k TEXT PRIMARY KEY, v TEXT NOT NULL, updated INTEGER NOT NULL)'),
  ]);
  // Columns added after the first release; ALTER fails harmlessly when they already exist.
  for (const col of ['always_show INTEGER NOT NULL DEFAULT 0', 'due_at INTEGER NOT NULL DEFAULT 0']) {
    await env.DB.prepare(`ALTER TABLE owner_items ADD COLUMN ${col}`).run().catch(() => {});
  }
  ownerSchemaReady = true;
}

const lineCore = (line) => line.split('#')[0].trim();

function validConfig(line) {
  if (typeof line !== 'string') return false;
  const t = line.trim();
  if (!t || t.length > OWNER_CONFIG_MAX_LEN || /\s/.test(t)) return false;
  const i = t.indexOf('://');
  if (i <= 0 || t.length <= i + 3) return false;
  return OWNER_SCHEMES.has(t.slice(0, i).toLowerCase());
}

function validSubUrl(value) {
  if (typeof value !== 'string' || value.length > OWNER_URL_MAX_LEN) return false;
  try {
    const u = new URL(value.trim());
    return u.protocol === 'https:' && !!u.hostname && !u.username && !u.password;
  } catch {
    return false;
  }
}

async function sha256Hex(text) {
  const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

// Configs from one owner sub link, cached ~10 min in caches.default. Never throws.
async function fetchOwnerSub(link, ctx) {
  try {
    const cache = caches.default;
    const key = new Request(`https://owner-sub.molido.internal/${await sha256Hex(link)}`);
    const hit = await cache.match(key);
    if (hit) return (await hit.text()).split('\n').filter(Boolean);
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), 8000);
    let body = '';
    try {
      const res = await fetch(link, { signal: ac.signal, redirect: 'follow', headers: { 'user-agent': 'v2rayNG/1.9' } });
      if (res.ok) body = (await res.text()).slice(0, 2_000_000);
    } finally {
      clearTimeout(timer);
    }
    const lines = decodeList(body)
      .split('\n')
      .map((l) => l.trim())
      .filter(validConfig)
      .slice(0, OWNER_SUB_MAX_LINES);
    if (lines.length) {
      const res = new Response(lines.join('\n'), { headers: { 'cache-control': `public, max-age=${OWNER_SUB_TTL}` } });
      ctx.waitUntil(cache.put(key, res));
    }
    return lines;
  } catch {
    return [];
  }
}

// All enabled owner configs (single configs first, then sub-link configs), deduped, as
// { line, fp, item }. Throws on DB errors.
async function ownerEntries(env, ctx) {
  await ensureOwnerSchema(env);
  const { results } = await env.DB.prepare(
    'SELECT id, kind, value, always_show, due_at FROM owner_items WHERE enabled = 1 ORDER BY id'
  ).all();
  const configs = results.filter((r) => r.kind === 'config');
  const subs = results.filter((r) => r.kind === 'sub');
  const subLines = await Promise.all(subs.map((r) => fetchOwnerSub(r.value, ctx)));
  const src = [...configs.map((r) => [r, r.value]), ...subs.flatMap((r, i) => subLines[i].map((l) => [r, l]))];
  const seen = new Set();
  const out = [];
  for (const [item, line] of src) {
    const core = lineCore(line);
    if (!validConfig(line) || seen.has(core)) continue;
    seen.add(core);
    out.push({ line: line.trim(), fp: await nodeFingerprint(line), item });
    if (out.length >= OWNER_MAX_LINES) break;
  }
  return out;
}

const OWNER_FAIL_RUNS = 2; // hide after this many consecutive failed local Iran test runs
const OWNER_RETEST_MS = 3600000; // owner configs are due for the quick local test after 1 h
const OWNER_RUN_GAP_MS = 5 * 60000; // failures closer than this count as the same run

// Local Iran tests (owner_tests) and app reports from Iranian users for owner fingerprints. Never throws.
async function ownerStatus(env) {
  const tests = new Map();
  const users = new Map();
  try {
    const { results } = await env.DB.prepare('SELECT fp, ok, ms, tested_at, fail_streak FROM owner_tests').all();
    for (const r of results) tests.set(r.fp, r);
  } catch {}
  try {
    const day = (d) => new Date(Date.now() - d * 86400000).toISOString().slice(0, 10);
    const { results } = await env.DB.prepare(
      `SELECT node, SUM(ok) ok, SUM(fail) fail, SUM(CASE WHEN day >= ?2 THEN ok ELSE 0 END) recent_ok
       FROM reports WHERE day >= ?1 GROUP BY node`
    )
      .bind(day(6), day(1))
      .all();
    for (const r of results) users.set(r.node, r);
  } catch {}
  return { tests, users };
}

// Hidden from users: failed the latest OWNER_FAIL_RUNS local Iran runs, no user success in ~2 days, no override.
function ownerHidden(entry, st) {
  if (entry.item.always_show) return false;
  const t = st.tests.get(entry.fp);
  if (!t || t.ok || t.fail_streak < OWNER_FAIL_RUNS) return false;
  return !((st.users.get(entry.fp) || {}).recent_ok > 0);
}

function ownerDue(entry, st, now) {
  const t = st.tests.get(entry.fp);
  return !t || t.tested_at < now - OWNER_RETEST_MS || entry.item.due_at > t.tested_at;
}

// Owner configs served to users (Iran-failed ones removed). Never throws.
async function ownerLines(env, ctx) {
  try {
    const entries = await ownerEntries(env, ctx);
    if (!entries.length) return [];
    const st = await ownerStatus(env);
    return entries.filter((e) => !ownerHidden(e, st)).map((e) => e.line);
  } catch {
    return [];
  }
}

// /owner/configs — public list of owner config URIs for the local Iran tester (they are public inside / anyway).
// id is the report fingerprint; due = never tested, older than 1 h, or "test again" pressed in /admin.
async function ownerConfigsRoute(env, ctx) {
  const headers = { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' };
  try {
    const entries = await ownerEntries(env, ctx);
    const st = entries.length ? await ownerStatus(env) : { tests: new Map(), users: new Map() };
    const now = Date.now();
    const configs = entries.map((e) => ({ id: e.fp, uri: e.line, due: ownerDue(e, st, now) }));
    return new Response(JSON.stringify({ configs }), { headers });
  } catch {
    return new Response(JSON.stringify({ error: 'unavailable' }), { status: 500, headers });
  }
}

// Owner fingerprints, cached per isolate for a minute (used to accept owner test results in /report).
let ownerFpCache = { at: 0, set: new Set() };
async function ownerFps(env, ctx) {
  if (Date.now() - ownerFpCache.at > 60000) {
    ownerFpCache = { at: Date.now(), set: new Set((await ownerEntries(env, ctx)).map((e) => e.fp)) };
  }
  return ownerFpCache.set;
}

// Owner configs first, then the normal list without duplicates of them.
function mergeOwner(owner, lines) {
  if (!owner.length) return lines;
  const seen = new Set(owner.map(lineCore));
  const merged = [...owner, ...lines.filter((l) => !seen.has(lineCore(l)))];
  merged.vip = seen; // brand() names owner configs "... VIP"
  return merged;
}

const ADMIN_HEADERS = {
  'cache-control': 'no-store',
  'x-content-type-options': 'nosniff',
  'x-frame-options': 'DENY',
  'referrer-policy': 'no-referrer',
};
const adminJson = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { 'content-type': 'application/json; charset=utf-8', ...ADMIN_HEADERS } });

async function timingSafeKeyEqual(a, b) {
  const [x, y] = await Promise.all([a, b].map((s) => crypto.subtle.digest('SHA-256', new TextEncoder().encode(s))));
  const ua = new Uint8Array(x), ub = new Uint8Array(y);
  let diff = 0;
  for (let i = 0; i < ua.length; i++) diff |= ua[i] ^ ub[i];
  return diff === 0;
}

// Returns null when authorized, otherwise the error response.
async function adminAuth(request, env) {
  if (!env.ADMIN_KEY) return adminJson({ error: 'ADMIN_KEY not set. Run: npx wrangler secret put ADMIN_KEY' }, 503);
  await ensureOwnerSchema(env);
  const ip = request.headers.get('cf-connecting-ip') || 'unknown';
  // Salted with the admin key so stored hashes cannot be reversed to IPs; rows are removed after a day.
  const ipHash = await sha256Hex(`molido-admin|${env.ADMIN_KEY}|${ip}`);
  const now = Date.now();
  const row = await env.DB.prepare('SELECT fails, locked_until FROM admin_fails WHERE ip_hash = ?1').bind(ipHash).first();
  if (row && row.locked_until > now) {
    return adminJson({ error: 'locked', retry_after_s: Math.ceil((row.locked_until - now) / 1000) }, 429);
  }
  const auth = request.headers.get('authorization') || '';
  const given = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  if (given && (await timingSafeKeyEqual(given, env.ADMIN_KEY))) {
    if (row) await env.DB.prepare('DELETE FROM admin_fails WHERE ip_hash = ?1').bind(ipHash).run();
    return null;
  }
  const fails = (row ? row.fails : 0) + 1;
  const lockedUntil = fails >= ADMIN_MAX_FAILS ? now + ADMIN_LOCK_MS : 0;
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO admin_fails (ip_hash, fails, locked_until, updated) VALUES (?1, ?2, ?3, ?4)
       ON CONFLICT(ip_hash) DO UPDATE SET fails = excluded.fails, locked_until = excluded.locked_until, updated = excluded.updated`
    ).bind(ipHash, lockedUntil ? 0 : fails, lockedUntil, now),
    env.DB.prepare('DELETE FROM admin_fails WHERE updated < ?1').bind(now - 86400000),
  ]);
  return adminJson({ error: lockedUntil ? 'locked' : 'unauthorized' }, lockedUntil ? 429 : 401);
}

async function adminApi(request, env, url, ctx) {
  if (request.method === 'OPTIONS') return new Response(null, { status: 405, headers: ADMIN_HEADERS });
  const denied = await adminAuth(request, env);
  if (denied) return denied;
  const path = url.pathname.replace(/\/+$/, '');
  const DB = env.DB;

  if (path === '/admin/api/items' && request.method === 'GET') {
    const { results } = await DB.prepare(
      'SELECT id, kind, value, note, enabled, always_show, due_at, created_at FROM owner_items ORDER BY id DESC'
    ).all();
    const st = await ownerStatus(env);
    const now = Date.now();
    // Iran status per config: last local test, consecutive failed runs, 7-day user reports, hidden/due.
    const one = (item, line, fp) => {
      const t = st.tests.get(fp);
      const u = st.users.get(fp) || { ok: 0, fail: 0 };
      const e = { item, fp, line };
      return {
        tested: !!t,
        ok: t ? !!t.ok : null,
        ms: t ? t.ms : null,
        tested_at: t ? t.tested_at : null,
        fail_streak: t ? t.fail_streak : 0,
        user_ok: u.ok || 0,
        user_fail: u.fail || 0,
        hidden: ownerHidden(e, st),
        due: ownerDue(e, st, now),
      };
    };
    const items = await Promise.all(
      results.map(async (it) => {
        if (it.kind === 'config') return { ...it, status: one(it, it.value, await nodeFingerprint(it.value)) };
        const lines = await fetchOwnerSub(it.value, ctx);
        const s = await Promise.all(lines.map(async (l) => one(it, l, await nodeFingerprint(l))));
        return {
          ...it,
          status: {
            total: s.length,
            ok: s.filter((x) => x.ok === true).length,
            failed: s.filter((x) => x.ok === false).length,
            untested: s.filter((x) => !x.tested).length,
            hidden: s.filter((x) => x.hidden).length,
            due: s.some((x) => x.due),
            tested_at: Math.max(0, ...s.map((x) => x.tested_at || 0)) || null,
          },
        };
      })
    );
    return adminJson({ items });
  }

  const readBody = async () => {
    const text = await request.text();
    if (text.length > 200_000) return null;
    try {
      const b = JSON.parse(text);
      return b && typeof b === 'object' && !Array.isArray(b) ? b : null;
    } catch {
      return null;
    }
  };

  if (path === '/admin/api/stats' && request.method === 'GET') return adminJson(await adminStats(env));
  if (path === '/admin/api/online' && request.method === 'GET') return onlineRoute(env);

  if (path === '/admin/api/notice' && request.method === 'GET') return adminJson({ notice: (await kvGet(env, 'notice')) || null });
  if (path === '/admin/api/notice' && request.method === 'PUT') {
    const b = await readBody();
    if (!b || typeof b.text !== 'string') return adminJson({ error: 'bad request' }, 400);
    const text = b.text.trim().slice(0, NOTICE_TEXT_MAX);
    const link = typeof b.link === 'string' ? b.link.trim() : '';
    if (link && !validSubUrl(link)) return adminJson({ error: 'لینک باید با https:// شروع شود' }, 400);
    const expires = b.expires_at === null || b.expires_at === undefined || b.expires_at === '' ? null : Number(b.expires_at);
    if (expires !== null && !(Number.isInteger(expires) && expires > 0)) return adminJson({ error: 'bad expiry' }, 400);
    const prev = (await kvGet(env, 'notice')) || {};
    const next = {
      text,
      link,
      link_label: typeof b.link_label === 'string' ? b.link_label.trim().slice(0, 40) : '',
      type: b.type === 'warning' ? 'warning' : 'info',
      enabled: b.enabled === true && !!text,
      expires_at: expires,
    };
    // A new id (shown again to users who dismissed the old one) only when the content changes.
    const same = prev.id && prev.text === next.text && prev.link === next.link && prev.link_label === next.link_label && prev.type === next.type;
    next.id = same ? prev.id : Date.now().toString(36);
    await kvSet(env, 'notice', next);
    return adminJson({ notice: next });
  }

  if (path === '/admin/api/flags' && request.method === 'GET')
    return adminJson({ flags: normalizeFlags(await kvGet(env, 'flags')), modes: APP_MODES });
  if (path === '/admin/api/flags' && request.method === 'PUT') {
    const b = await readBody();
    if (!b || !Array.isArray(b.disabled) || typeof b.default_mode !== 'string') return adminJson({ error: 'bad request' }, 400);
    const keys = Object.keys(APP_MODES);
    if (b.disabled.some((m) => !keys.includes(m))) return adminJson({ error: 'unknown mode' }, 400);
    if (new Set(b.disabled).size >= keys.length) return adminJson({ error: 'حداقل یک حالت اتصال باید فعال بماند' }, 400);
    if (b.default_mode !== 'auto' && (!keys.includes(b.default_mode) || b.disabled.includes(b.default_mode)))
      return adminJson({ error: 'حالت پیش‌فرض نباید غیرفعال باشد' }, 400);
    const flags = normalizeFlags(b);
    await kvSet(env, 'flags', flags);
    return adminJson({ flags });
  }

  if (path === '/admin/api/items' && request.method === 'POST') {
    const b = await readBody();
    if (!b || (b.kind !== 'sub' && b.kind !== 'config') || typeof b.value !== 'string') return adminJson({ error: 'bad request' }, 400);
    const note = typeof b.note === 'string' ? b.note.trim().slice(0, OWNER_NOTE_MAX_LEN) : '';
    const { n } = await DB.prepare('SELECT COUNT(*) n FROM owner_items').first();
    const created = new Date().toISOString();
    if (b.kind === 'sub') {
      const link = b.value.trim();
      if (!validSubUrl(link)) return adminJson({ error: 'invalid link (must be https, max 2048 chars)' }, 400);
      if (n >= OWNER_MAX_ITEMS) return adminJson({ error: 'too many items' }, 400);
      await DB.prepare('INSERT INTO owner_items (kind, value, note, enabled, created_at) VALUES (?1, ?2, ?3, 1, ?4)')
        .bind('sub', link, note, created)
        .run();
      return adminJson({ added: 1, rejected: 0 });
    }
    const lines = b.value.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
    const valid = [...new Set(lines.filter(validConfig))];
    const room = Math.max(0, OWNER_MAX_ITEMS - n);
    const toAdd = valid.slice(0, room);
    if (toAdd.length) {
      await DB.batch(
        toAdd.map((line) =>
          DB.prepare('INSERT INTO owner_items (kind, value, note, enabled, created_at) VALUES (?1, ?2, ?3, 1, ?4)').bind('config', line, note, created)
        )
      );
    }
    return adminJson({ added: toAdd.length, rejected: lines.length - toAdd.length }, toAdd.length ? 200 : 400);
  }

  const m = path.match(/^\/admin\/api\/items\/(\d{1,12})$/);
  if (m) {
    const id = Number(m[1]);
    if (request.method === 'DELETE') {
      await DB.prepare('DELETE FROM owner_items WHERE id = ?1').bind(id).run();
      return adminJson({ ok: true });
    }
    if (request.method === 'PATCH') {
      const b = await readBody();
      // { enabled?: bool, always_show?: bool, retest?: true } — retest makes the item due for the quick local Iran test.
      const ups = [];
      if (b && typeof b.enabled === 'boolean') ups.push(DB.prepare('UPDATE owner_items SET enabled = ?1 WHERE id = ?2').bind(b.enabled ? 1 : 0, id));
      if (b && typeof b.always_show === 'boolean')
        ups.push(DB.prepare('UPDATE owner_items SET always_show = ?1 WHERE id = ?2').bind(b.always_show ? 1 : 0, id));
      if (b && b.retest === true) ups.push(DB.prepare('UPDATE owner_items SET due_at = ?1 WHERE id = ?2').bind(Date.now(), id));
      if (!ups.length) return adminJson({ error: 'bad request' }, 400);
      await DB.batch(ups);
      return adminJson({ ok: true });
    }
  }
  return adminJson({ error: 'not found' }, 404);
}

// ---------------------------------------------------------------------------------------------------
// Announcement (/app/notice.json), remote app flags (/app/flags.json) and anonymous stats for /admin.
// ---------------------------------------------------------------------------------------------------
// Modes the owner can switch off. 'auto' and the user's own configs can never be disabled.
const APP_MODES = {
  warp: 'WARP / WireGuard',
  masque: 'MASQUE',
  gool: 'WARP-on-WARP',
  amnezia: 'AmneziaWG',
  psiphon: 'Psiphon',
  tor: 'Tor',
  dns: 'DNS (بدون تونل)',
  shard: 'SHARD',
  v2ray: 'V2Ray',
};
const NOTICE_TEXT_MAX = 500;
const PUBLIC_JSON = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'public, max-age=60',
  'access-control-allow-origin': '*',
};

async function kvGet(env, k) {
  await ensureOwnerSchema(env);
  const row = await env.DB.prepare('SELECT v FROM owner_kv WHERE k = ?1').bind(k).first();
  if (!row) return null;
  try {
    return JSON.parse(row.v);
  } catch {
    return null;
  }
}

async function kvSet(env, k, value) {
  await ensureOwnerSchema(env);
  await env.DB.prepare(
    'INSERT INTO owner_kv (k, v, updated) VALUES (?1, ?2, ?3) ON CONFLICT(k) DO UPDATE SET v = excluded.v, updated = excluded.updated'
  )
    .bind(k, JSON.stringify(value), Date.now())
    .run();
}

// Stored flags -> always-valid flags (unknown modes dropped; never all disabled; default not disabled).
function normalizeFlags(f) {
  const keys = Object.keys(APP_MODES);
  const disabled = f && Array.isArray(f.disabled) ? [...new Set(f.disabled.filter((m) => keys.includes(m)))] : [];
  if (disabled.length >= keys.length) return { v: 1, default_mode: 'auto', disabled: [] };
  let def = f && typeof f.default_mode === 'string' ? f.default_mode : 'auto';
  if (def !== 'auto' && (!keys.includes(def) || disabled.includes(def))) def = 'auto';
  return { v: 1, default_mode: def, disabled };
}

function activeNotice(n, now = Date.now()) {
  if (!n || !n.enabled || typeof n.text !== 'string' || !n.text.trim()) return null;
  if (n.expires_at && n.expires_at <= now) return null;
  return {
    id: String(n.id || ''),
    text: n.text,
    type: n.type === 'warning' ? 'warning' : 'info',
    link: n.link || '',
    link_label: n.link_label || '',
    expires_at: n.expires_at || null,
  };
}

// Public, cached ~60 s. {} when there is no active announcement.
async function noticeRoute(env) {
  let body = {};
  try {
    body = activeNotice(await kvGet(env, 'notice')) || {};
  } catch {}
  return new Response(JSON.stringify(body), { headers: PUBLIC_JSON });
}

// Public, cached ~60 s. Defaults (everything enabled, automatic) when nothing is set or D1 fails.
async function flagsRoute(env) {
  let flags = normalizeFlags(null);
  let notice = false;
  try {
    flags = normalizeFlags(await kvGet(env, 'flags'));
    notice = !!activeNotice(await kvGet(env, 'notice'));
  } catch {}
  return new Response(JSON.stringify({ ...flags, notice }), { headers: PUBLIC_JSON });
}

const STAT_OPS = ['mci', 'irancell', 'tci', 'other'];
const statOp = (net) => {
  const op = String(net).split('|')[1] || '';
  return STAT_OPS.includes(op) && op !== 'other' ? op : 'other';
};
const statMode = (node) => {
  const m = String(node).slice(5);
  return m === 'wireguard' ? 'warp' : m;
};

// Last 14 days, from the anonymous reports table only (no IPs exist there).
async function adminStats(env) {
  const since = new Date(Date.now() - 13 * 86400000).toISOString().slice(0, 10);
  const [days, nets, modes] = await Promise.all([
    env.DB.prepare(
      `SELECT day, SUM(ok) ok, SUM(fail) fail FROM reports WHERE day >= ?1 AND net NOT LIKE '%|m' GROUP BY day ORDER BY day`
    ).bind(since).all(),
    env.DB.prepare(`SELECT net, SUM(ok) ok, SUM(fail) fail FROM reports WHERE day >= ?1 AND net NOT LIKE '%|m' GROUP BY net`)
      .bind(since)
      .all(),
    env.DB.prepare(`SELECT node, net, SUM(ok) ok, SUM(fail) fail FROM reports WHERE day >= ?1 AND node LIKE 'mode:%' GROUP BY node, net`)
      .bind(since)
      .all(),
  ]);
  const ops = Object.fromEntries(STAT_OPS.map((o) => [o, { ok: 0, fail: 0, modes: {} }]));
  for (const r of nets.results) {
    const o = ops[statOp(r.net)];
    o.ok += r.ok;
    o.fail += r.fail;
  }
  for (const r of modes.results) {
    const o = ops[statOp(r.net)];
    const m = (o.modes[statMode(r.node)] ||= { ok: 0, fail: 0 });
    m.ok += r.ok;
    m.fail += r.fail;
  }
  const operators = STAT_OPS.map((op) => {
    const o = ops[op];
    const list = Object.entries(o.modes)
      .map(([mode, s]) => ({ mode, ok: s.ok, fail: s.fail, n: s.ok + s.fail, score: (s.ok + 1) / (s.ok + s.fail + 2) }))
      .sort((a, b) => (b.n >= 5) - (a.n >= 5) || b.score - a.score || b.n - a.n);
    return { op, ok: o.ok, fail: o.fail, best_mode: list[0] || null, modes: list };
  });
  return { days: days.results, operators };
}

function adminPage(env) {
  const keySet = !!env.ADMIN_KEY;
  const html = `<!doctype html><html lang="fa" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">
<title>پنل مدیریت MolidoVPN</title>
<style>
:root{--bg:#f4f6fb;--card:#fff;--text:#1b2030;--mute:#6b7285;--line:#dde2ee;--accent:#3b5bdb;--danger:#d6336c;--ok:#2b8a3e}
@media (prefers-color-scheme:dark){:root{--bg:#10131b;--card:#191d29;--text:#e8ebf3;--mute:#9aa1b5;--line:#2a3042;--accent:#748ffc;--danger:#f06595;--ok:#69db7c}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.6 Tahoma,"Segoe UI",system-ui,sans-serif;padding:16px}
main{max-width:720px;margin:0 auto}h1{font-size:20px;margin:0 0 12px}h2{font-size:16px;margin:0 0 8px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px;margin-bottom:14px}
input,textarea,select{width:100%;font:inherit;color:var(--text);background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:9px;margin:4px 0 10px}
textarea{min-height:120px;direction:ltr;text-align:left;font-family:ui-monospace,Consolas,monospace;font-size:13px}
button{font:inherit;border:0;border-radius:8px;padding:8px 14px;background:var(--accent);color:#fff;cursor:pointer}
button.ghost{background:transparent;color:var(--text);border:1px solid var(--line)}button.danger{background:var(--danger)}
.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}.mute{color:var(--mute);font-size:13px}
.item{border-top:1px solid var(--line);padding:10px 0}.item:first-child{border-top:0}
.val{direction:ltr;text-align:left;font-family:ui-monospace,Consolas,monospace;font-size:12px;word-break:break-all;margin:4px 0}
.badge{font-size:12px;border-radius:6px;padding:1px 8px;border:1px solid var(--line)}.on{color:var(--ok)}.off{color:var(--danger)}
table{width:100%;border-collapse:collapse;font-size:13px;margin:8px 0}th,td{text-align:right;padding:5px 4px;border-top:1px solid var(--line);vertical-align:middle}
.bar{height:8px;border-radius:4px;background:var(--line);min-width:60px;overflow:hidden}.bar>i{display:block;height:100%;background:var(--ok)}
.tbl{overflow-x:auto}
#msg{min-height:1.4em}code{direction:ltr;display:inline-block;background:var(--bg);padding:2px 6px;border-radius:6px}
</style></head><body><main>
<h1>پنل مدیریت MolidoVPN</h1>
${
  keySet
    ? ''
    : `<div class="card"><h2>کلید مدیریت تنظیم نشده است</h2><p>برای فعال شدن پنل، در پوشه <code>cloudflare</code> این دستور را اجرا کنید و یک کلید طولانی و محرمانه وارد کنید:</p><p><code>npx wrangler secret put ADMIN_KEY</code></p></div>`
}
<div class="card" id="login"${keySet ? '' : ' hidden'}>
<h2>ورود</h2><label>کلید مدیریت<input id="key" type="password" autocomplete="current-password"></label>
<button id="loginBtn">ورود</button></div>
<div id="panel" hidden>
<div class="card"><h2>کاربران متصل الان</h2><div id="online" class="row"><span class="mute">در حال بارگذاری…</span></div></div>
<div class="card"><h2>اطلاعیه همگانی</h2>
<p class="mute">پیامی که بالای صفحه اصلی هر دو برنامه (اندروید و ویندوز) نشان داده می‌شود. کاربر می‌تواند آن را ببندد؛ با تغییر متن دوباره نمایش داده می‌شود.</p>
<label>متن (فارسی)<textarea id="nText" maxlength="500" style="direction:rtl;text-align:right;font-family:inherit;min-height:80px"></textarea></label>
<div class="row"><label style="flex:2">لینک (اختیاری، https)<input id="nLink" dir="ltr" placeholder="https://t.me/Molido_Vpn"></label>
<label style="flex:1">متن دکمه لینک<input id="nLabel" maxlength="40" placeholder="بیشتر"></label></div>
<div class="row"><label style="flex:1">نوع<select id="nType"><option value="info">اطلاع‌رسانی</option><option value="warning">هشدار</option></select></label>
<label style="flex:1">تاریخ انقضا (اختیاری)<input id="nExp" type="datetime-local"></label></div>
<label class="row"><input id="nOn" type="checkbox" style="width:auto;margin:0"> نمایش اطلاعیه به کاربران</label>
<div class="row" style="margin-top:8px"><button id="nSave">ذخیره اطلاعیه</button><span class="mute" id="nState"></span></div></div>
<div class="card"><h2>تنظیمات راه دور برنامه‌ها</h2>
<p class="mute">حالت‌های تیک‌خورده در همه برنامه‌ها غیرفعال می‌شوند (در حالت خودکار رد می‌شوند و در انتخاب حالت خاکستری‌اند). حداقل یک حالت باید فعال بماند. تغییرات حداکثر در چند دقیقه به برنامه‌ها می‌رسد.</p>
<label>حالت پیش‌فرض برای کاربرانی که خودشان حالتی انتخاب نکرده‌اند<select id="fDef"></select></label>
<div id="fModes" class="row" style="gap:14px"></div>
<div class="row" style="margin-top:10px"><button id="fSave">ذخیره تنظیمات</button></div></div>
<div class="card"><h2>آمار ناشناس (۱۴ روز اخیر)</h2>
<p class="mute">فقط از گزارش‌های ناشناسی که کاربران خودشان فعال کرده‌اند؛ هیچ IP یا اطلاعات شخصی ذخیره نمی‌شود.</p>
<div class="row"><button class="ghost" id="sLoad">به‌روزرسانی آمار</button></div><div id="stats"></div></div>
<div class="card"><h2>افزودن</h2>
<label>نوع<select id="kind"><option value="config">کانفیگ (یک یا چند خط)</option><option value="sub">لینک اشتراک (https)</option></select></label>
<label>مقدار<textarea id="value" placeholder="vless://...&#10;trojan://..."></textarea></label>
<label>یادداشت (اختیاری)<input id="note" maxlength="200"></label>
<div class="row"><button id="addBtn">افزودن</button><button class="ghost" id="logoutBtn">خروج</button></div></div>
<div class="card"><h2>موارد <span class="mute" id="count"></span></h2><div id="list"></div></div>
</div>
<p id="msg" class="mute"></p>
</main>
<script>
(function(){
var $=function(id){return document.getElementById(id)};
var key='';try{key=sessionStorage.getItem('mk')||''}catch(e){}
function msg(t){$('msg').textContent=t||''}
function api(method,path,body){
  var o={method:method,headers:{'Authorization':'Bearer '+key}};
  if(body){o.headers['content-type']='application/json';o.body=JSON.stringify(body)}
  return fetch('/admin/api'+path,o).then(function(r){return r.json().catch(function(){return {}}).then(function(j){j._s=r.status;return j})});
}
function err(j){
  if(j._s===401){logout();return 'کلید اشتباه است'}
  if(j._s===429){logout();return 'تلاش‌های ناموفق زیاد؛ چند دقیقه بعد دوباره امتحان کنید'}
  if(j._s===503)return 'کلید مدیریت روی سرور تنظیم نشده است';
  return j.error||('خطا '+j._s);
}
function logout(){key='';extrasLoaded=false;if(onlineTimer){clearInterval(onlineTimer);onlineTimer=null}try{sessionStorage.removeItem('mk')}catch(e){}$('panel').hidden=true;$('login').hidden=false}
function load(){
  return api('GET','/items').then(function(j){
    if(j._s!==200){msg(err(j));return}
    $('login').hidden=true;$('panel').hidden=false;loadExtras();
    var list=$('list');list.textContent='';$('count').textContent='('+j.items.length+')';
    j.items.forEach(function(it){
      var d=document.createElement('div');d.className='item';
      var h=document.createElement('div');h.className='row';
      var b1=document.createElement('span');b1.className='badge';b1.textContent=it.kind==='sub'?'لینک اشتراک':'کانفیگ';
      var b2=document.createElement('span');b2.className='badge '+(it.enabled?'on':'off');b2.textContent=it.enabled?'فعال':'غیرفعال';
      var n=document.createElement('span');n.className='mute';n.textContent=(it.note?it.note+' · ':'')+String(it.created_at).slice(0,10);
      var st=it.status||{},b3=document.createElement('span'),b4=document.createElement('span');b4.className='mute';
      var when=function(ms){return ms?new Date(ms).toLocaleString('fa-IR',{dateStyle:'short',timeStyle:'short'}):''};
      if(it.kind==='sub'){
        b3.className='badge '+(st.total&&st.ok===st.total?'on':st.failed?'off':'');
        b3.textContent=st.total?(st.ok+' از '+st.total+' سالم'):'⏳ کانفیگی دریافت نشد';
        b4.textContent=[st.untested?st.untested+' هنوز تست نشده':'',st.hidden?st.hidden+' پنهان از کاربران':'',st.tested_at?'آخرین تست '+when(st.tested_at):''].filter(Boolean).join(' · ');
      }else if(!st.tested){b3.className='badge';b3.textContent='⏳ هنوز تست نشده'}
      else if(st.ok){b3.className='badge on';b3.textContent='✅ ایران OK ('+(st.ms||'?')+' ms، '+when(st.tested_at)+')'}
      else{b3.className='badge off';b3.textContent='❌ از ایران وصل نشد';b4.textContent=when(st.tested_at)+(st.hidden?' · پنهان از کاربران':'')}
      if(it.kind==='config'&&(st.user_ok+st.user_fail))b4.textContent=(b4.textContent?b4.textContent+' · ':'')+'گزارش کاربران ایران: '+Math.round(100*st.user_ok/(st.user_ok+st.user_fail))+'% از '+(st.user_ok+st.user_fail);
      if(st.due&&it.due_at&&(!st.tested_at||it.due_at>st.tested_at))b4.textContent=(b4.textContent?b4.textContent+' · ':'')+'در صف تست';
      h.append(b1,b2,b3,b4,n);
      var v=document.createElement('div');v.className='val';v.textContent=it.value.length>300?it.value.slice(0,300)+'…':it.value;
      var a=document.createElement('div');a.className='row';
      var t=document.createElement('button');t.className='ghost';t.textContent=it.enabled?'غیرفعال کن':'فعال کن';
      t.onclick=function(){api('PATCH','/items/'+it.id,{enabled:!it.enabled}).then(function(r){r._s===200?load():msg(err(r))})};
      var re=document.createElement('button');re.className='ghost';re.textContent='تست دوباره';
      re.onclick=function(){api('PATCH','/items/'+it.id,{retest:true}).then(function(r){if(r._s===200){msg('در صف تست؛ حداکثر ۱۵ دقیقه');load()}else msg(err(r))})};
      var al=document.createElement('label');al.className='row mute';var cb=document.createElement('input');cb.type='checkbox';cb.style.width='auto';cb.style.margin='0';cb.checked=!!it.always_show;
      cb.onchange=function(){api('PATCH','/items/'+it.id,{always_show:cb.checked}).then(function(r){r._s===200?load():msg(err(r))})};
      al.append(cb,document.createTextNode('همیشه نشان بده'));
      var del=document.createElement('button');del.className='danger';del.textContent='حذف';
      del.onclick=function(){if(confirm('حذف شود؟'))api('DELETE','/items/'+it.id).then(function(r){r._s===200?load():msg(err(r))})};
      a.append(t,re,al,del);d.append(h,v,a);list.append(d);
    });
  }).catch(function(){msg('خطای شبکه')});
}
var OPN={mci:'همراه اول (MCI)',irancell:'ایرانسل',tci:'مخابرات (TCI)',other:'سایر (وای‌فای و اپراتورهای دیگر)'};
var MODES={};
function el(tag,text,cls){var e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(cls)e.className=cls;return e}
function pct(ok,fail){var n=ok+fail;return n?Math.round(100*ok/n):0}
function bar(p){var b=el('div','','bar'),i=el('i');i.style.width=p+'%';b.append(i);return b}
function localDt(ms){var d=new Date(ms-new Date(ms).getTimezoneOffset()*60000);return d.toISOString().slice(0,16)}
function loadNotice(){api('GET','/notice').then(function(j){if(j._s!==200)return;var n=j.notice||{};
  $('nText').value=n.text||'';$('nLink').value=n.link||'';$('nLabel').value=n.link_label||'';$('nType').value=n.type==='warning'?'warning':'info';
  $('nExp').value=n.expires_at?localDt(n.expires_at):'';$('nOn').checked=!!n.enabled;
  $('nState').textContent=n.enabled?(n.expires_at&&n.expires_at<Date.now()?'منقضی شده':'در حال نمایش'):'خاموش'})}
$('nSave').onclick=function(){var exp=$('nExp').value?new Date($('nExp').value).getTime():null;
  api('PUT','/notice',{text:$('nText').value,link:$('nLink').value,link_label:$('nLabel').value,type:$('nType').value,enabled:$('nOn').checked,expires_at:exp}).then(function(r){if(r._s===200){msg('اطلاعیه ذخیره شد');loadNotice()}else msg(err(r))})};
function loadFlags(){api('GET','/flags').then(function(j){if(j._s!==200)return;MODES=j.modes||{};var f=j.flags;
  var sel=$('fDef');sel.textContent='';var o=el('option','خودکار (پیشنهاد)');o.value='auto';sel.append(o);
  var box=$('fModes');box.textContent='';box.append(el('span','غیرفعال کردن:','mute'));
  Object.keys(MODES).forEach(function(m){var op=el('option',MODES[m]);op.value=m;sel.append(op);
    var l=el('label','','row');var c=el('input');c.type='checkbox';c.style.width='auto';c.style.margin='0';c.value=m;c.checked=f.disabled.indexOf(m)>=0;l.append(c,document.createTextNode(MODES[m]));box.append(l)});
  sel.value=f.default_mode})}
$('fSave').onclick=function(){var dis=[].slice.call($('fModes').querySelectorAll('input:checked')).map(function(c){return c.value});
  if(dis.length>=Object.keys(MODES).length){msg('حداقل یک حالت اتصال باید فعال بماند');return}
  api('PUT','/flags',{default_mode:$('fDef').value,disabled:dis}).then(function(r){if(r._s===200){msg('تنظیمات ذخیره شد');loadFlags()}else msg(err(r))})};
function loadStats(){var box=$('stats');box.textContent='در حال بارگذاری…';api('GET','/stats').then(function(j){box.textContent='';if(j._s!==200){box.textContent=err(j);return}
  var tot=j.days.reduce(function(a,d){return a+d.ok+d.fail},0);
  if(!tot){box.append(el('p','هنوز گزارشی در این بازه ثبت نشده است.','mute'));return}
  box.append(el('h2','تلاش‌های اتصال روزانه'));var w=el('div','','tbl'),t=el('table'),h=el('tr');['روز','تلاش','موفق','درصد موفقیت',''].forEach(function(x){h.append(el('th',x))});t.append(h);
  var max=Math.max.apply(null,j.days.map(function(d){return d.ok+d.fail}));
  j.days.forEach(function(d){var r=el('tr'),n=d.ok+d.fail,c=el('td');var b=bar(Math.round(100*n/max));b.firstChild.style.background='var(--accent)';c.append(b);
    r.append(el('td',new Date(d.day+'T12:00:00Z').toLocaleDateString('fa-IR',{month:'short',day:'numeric'})),el('td',n.toLocaleString('fa-IR')),el('td',d.ok.toLocaleString('fa-IR')),el('td',pct(d.ok,d.fail).toLocaleString('fa-IR')+'٪'),c);t.append(r)});
  w.append(t);box.append(w);
  box.append(el('h2','بر اساس اپراتور'));w=el('div','','tbl');t=el('table');h=el('tr');['اپراتور','گزارش','موفقیت','','بهترین حالت اتصال'].forEach(function(x){h.append(el('th',x))});t.append(h);
  j.operators.forEach(function(o){var r=el('tr'),n=o.ok+o.fail,c=el('td');c.append(bar(pct(o.ok,o.fail)));var b=o.best_mode;
    var bt=b?(MODES[b.mode]||b.mode)+' · '+pct(b.ok,b.fail).toLocaleString('fa-IR')+'٪ از '+b.n.toLocaleString('fa-IR')+(b.n<5?' (داده کم)':''):'—';
    r.append(el('td',OPN[o.op]||o.op),el('td',n.toLocaleString('fa-IR')),el('td',n?pct(o.ok,o.fail).toLocaleString('fa-IR')+'٪':'—'),c,el('td',bt));t.append(r)});
  w.append(t);box.append(w);
  box.append(el('p','«بهترین حالت» فقط از گزارش‌هایی که نوع اتصال را دارند (نسخه‌های جدید) محاسبه می‌شود؛ حالت‌هایی با کمتر از ۵ گزارش در اولویت نیستند.','mute'));
}).catch(function(){box.textContent='خطای شبکه'})}
$('sLoad').onclick=loadStats;
var onlineTimer=null;
function loadOnline(){api('GET','/online').then(function(j){var box=$('online');if(j._s!==200){box.textContent=err(j);return}
  box.textContent='';box.append(el('strong','کاربران متصل الان: '+j.count.toLocaleString('fa-IR')));
  var parts=[];Object.keys(OPN).forEach(function(o){var n=(j.byOperator||{})[o]||0;if(n)parts.push(OPN[o]+': '+n.toLocaleString('fa-IR'))});
  if(parts.length)box.append(el('span',' · '+parts.join(' · '),'mute'));
}).catch(function(){})}
function startOnline(){loadOnline();if(onlineTimer)clearInterval(onlineTimer);onlineTimer=setInterval(loadOnline,17000)}
var extrasLoaded=false;
function loadExtras(){if(extrasLoaded)return;extrasLoaded=true;loadNotice();loadFlags();loadStats();startOnline()}
$('loginBtn').onclick=function(){key=$('key').value.trim();if(!key)return;try{sessionStorage.setItem('mk',key)}catch(e){}$('key').value='';msg('');load()};
$('key').onkeydown=function(e){if(e.key==='Enter')$('loginBtn').click()};
$('logoutBtn').onclick=function(){logout();msg('')};
$('addBtn').onclick=function(){
  var body={kind:$('kind').value,value:$('value').value,note:$('note').value};
  if(!body.value.trim())return;
  api('POST','/items',body).then(function(j){
    if(j._s===200){$('value').value='';$('note').value='';msg('افزوده شد: '+j.added+(j.rejected?' · نامعتبر/رد شده: '+j.rejected:''));load()}
    else msg(j.added===0?'هیچ کانفیگ معتبری پیدا نشد (نامعتبر: '+j.rejected+')':err(j));
  }).catch(function(){msg('خطای شبکه')});
};
if(key&&${keySet})load();
})();
</script></body></html>`;
  return new Response(html, {
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'content-security-policy':
        "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'",
      ...ADMIN_HEADERS,
    },
  });
}

export default {
  async scheduled(event, env, ctx) {
    const cutoff = new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10);
    ctx.waitUntil(env.DB.prepare('DELETE FROM reports WHERE day < ?1').bind(cutoff).run());
    ctx.waitUntil(
      ensureOwnerSchema(env)
        .then(() =>
          env.DB.batch([
            env.DB.prepare('DELETE FROM admin_fails WHERE updated < ?1').bind(Date.now() - 86400000),
            env.DB.prepare('DELETE FROM owner_tests WHERE tested_at < ?1').bind(Date.now() - 30 * 86400000),
          ])
        )
        .catch(() => {})
    );
    ctx.waitUntil(
      ensureCfSchema(env)
        .then(() => env.DB.prepare('DELETE FROM cf_ips WHERE updated < ?1').bind(Date.now() - 3 * 86400000).run())
        .catch(() => {})
    );
    ctx.waitUntil(
      ensureActiveSchema(env)
        .then(() => env.DB.prepare('DELETE FROM active_sessions WHERE last_seen < ?1').bind(Math.floor(Date.now() / 1000) - ACTIVE_PRUNE_S).run())
        .catch(() => {})
    );
  },

  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method === 'OPTIONS' && (url.pathname === '/report' || url.pathname === '/scores' || url.pathname === '/heartbeat'))
      return new Response(null, { status: 204, headers: CORS });
    if (url.pathname === '/report') return reportRoute(request, env, ctx);
    if (url.pathname === '/heartbeat') return heartbeatRoute(request, env, ctx);
    if (url.pathname === '/owner/configs') return ownerConfigsRoute(env, ctx);
    if (url.pathname === '/scores') return scoresRoute(request, env, ctx);
    if (url.pathname === '/cfip') return cfipRoute(request, env, ctx);
    if (url.pathname.startsWith('/remote/')) return remoteRoute(url);
    if (url.pathname === '/app/notice.json') return noticeRoute(env);
    if (url.pathname === '/app/flags.json') return flagsRoute(env);
    if (url.pathname.startsWith('/app/')) return appRoute(url, request, ctx);
    if (url.pathname === '/warp/reg') return warpRegRoute(request);
    if (url.pathname === '/admin' || url.pathname === '/admin/') return adminPage(env);
    if (url.pathname.startsWith('/admin/api')) {
      try {
        return await adminApi(request, env, url, ctx);
      } catch {
        return adminJson({ error: 'server error' }, 500);
      }
    }
    if (url.pathname.startsWith('/admin')) return adminJson({ error: 'not found' }, 404);
    if (url.pathname.startsWith('/sub/')) return subRoute(url, env, ctx);
    if (url.pathname.startsWith('/lite') || url.pathname.startsWith('/ios') || url.pathname.startsWith('/hiddify'))
      return iosRoute(url, env, ctx);
    const sources = [FULL, MIRROR('sub_base64.txt')];
    const owner = ownerLines(env, ctx);

    for (const source of sources) {
      const res = await fetch(source, { cf: { cacheTtl: 300, cacheEverything: true } }).catch(() => null);
      if (!res || !res.ok) continue;
      const branded = brand(mergeOwner(await owner, decodeList(await res.text()).split('\n').filter((l) => l.includes('://'))));
      const bytes = new TextEncoder().encode(branded.join('\n'));
      let bin = '';
      for (const b of bytes) bin += String.fromCharCode(b);
      return new Response(btoa(bin), {
        headers: {
          'content-type': 'text/plain; charset=utf-8',
          'profile-title': 'base64:' + btoa('MolidoVPN'),
          'profile-update-interval': '1',
          'profile-web-page-url': 'https://hidooch980.github.io/mobin-vpn/',
          'cache-control': 'public, max-age=300',
          'access-control-allow-origin': '*',
        },
      });
    }
    return new Response('server list unavailable, try again shortly', { status: 502 });
  },
};
