// molido-edge: VLESS over WebSocket on Cloudflare Workers (edgetunnel-style), for the owner's own
// Cloudflare route. Secrets: UUID (client id), WS_PATH (e.g. /ws-xxxx). Anything else gets a plain page.
// TCP via cloudflare:sockets connect(); UDP only for DNS (port 53, answered over DoH). Early data is read
// from the Sec-WebSocket-Protocol header (xray/sing-box "ed" / max_early_data).
import { connect } from 'cloudflare:sockets';

const WS_OPEN = 1;
const DOH = 'https://1.1.1.1/dns-query';

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const upgrade = request.headers.get('Upgrade');
    if (!env.UUID || !env.WS_PATH || url.pathname !== env.WS_PATH || !upgrade || upgrade.toLowerCase() !== 'websocket') {
      return new Response('<!doctype html><title>OK</title><p>It works.</p>', {
        headers: { 'content-type': 'text/html; charset=utf-8' },
      });
    }
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    server.accept();
    const early = request.headers.get('sec-websocket-protocol') || '';
    handle(server, early, env).catch(() => safeClose(server));
    return new Response(null, { status: 101, webSocket: client });
  },
};

function uuidBytes(uuid) {
  const hex = uuid.replace(/-/g, '').toLowerCase();
  if (!/^[0-9a-f]{32}$/.test(hex)) return null;
  const out = new Uint8Array(16);
  for (let i = 0; i < 16; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

function decodeEarly(value) {
  if (!value) return null;
  try {
    const b64 = value.replace(/-/g, '+').replace(/_/g, '/');
    const bin = atob(b64 + '==='.slice((b64.length + 3) % 4));
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

function safeClose(ws) {
  try {
    if (ws.readyState === WS_OPEN || ws.readyState === 2) ws.close();
  } catch {}
}

function concat(a, b) {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

// Parses the VLESS request header; null when invalid or the id does not match.
function parseHeader(buf, id) {
  if (buf.length < 24) return null;
  const version = buf[0];
  for (let i = 0; i < 16; i++) if (buf[1 + i] !== id[i]) return null;
  let p = 17;
  const optLen = buf[p++];
  p += optLen;
  if (buf.length < p + 4) return null;
  const cmd = buf[p++]; // 1 = TCP, 2 = UDP
  const port = (buf[p] << 8) | buf[p + 1];
  p += 2;
  const atype = buf[p++];
  let host = '';
  if (atype === 1) {
    if (buf.length < p + 4) return null;
    host = `${buf[p]}.${buf[p + 1]}.${buf[p + 2]}.${buf[p + 3]}`;
    p += 4;
  } else if (atype === 2) {
    const len = buf[p++];
    if (buf.length < p + len) return null;
    host = new TextDecoder().decode(buf.subarray(p, p + len));
    p += len;
  } else if (atype === 3) {
    if (buf.length < p + 16) return null;
    const parts = [];
    for (let i = 0; i < 8; i++) parts.push(((buf[p + i * 2] << 8) | buf[p + i * 2 + 1]).toString(16));
    host = `[${parts.join(':')}]`;
    p += 16;
  } else return null;
  if (cmd !== 1 && cmd !== 2) return null;
  return { version, cmd, port, host, rest: buf.subarray(p) };
}

async function handle(ws, earlyHeader, env) {
  const id = uuidBytes(env.UUID);
  if (!id) return safeClose(ws);
  let pending = decodeEarly(earlyHeader) || new Uint8Array(0);
  let state = 'header'; // header -> tcp | udp
  let writer = null;
  let socket = null;
  let udpBuf = new Uint8Array(0);
  let responseHeader = null;
  let queue = Promise.resolve();

  const onData = async (chunk) => {
    if (state === 'header') {
      pending = concat(pending, chunk);
      const h = parseHeader(pending, id);
      if (!h) {
        if (pending.length > 512) safeClose(ws);
        return;
      }
      responseHeader = new Uint8Array([h.version, 0]);
      if (h.cmd === 2) {
        if (h.port !== 53) return safeClose(ws);
        state = 'udp';
        await onUdp(h.rest);
        return;
      }
      state = 'tcp';
      socket = await openTcp(h.host, h.port, env);
      writer = socket.writable.getWriter();
      if (h.rest.length) await writer.write(h.rest);
      pipeBack(socket, ws, () => responseHeader, () => (responseHeader = null));
      return;
    }
    if (state === 'tcp') await writer.write(chunk);
    else if (state === 'udp') await onUdp(chunk);
  };

  // VLESS UDP: [len16][payload] frames; each DNS query is answered over DoH.
  const onUdp = async (chunk) => {
    udpBuf = concat(udpBuf, chunk);
    while (udpBuf.length >= 2) {
      const len = (udpBuf[0] << 8) | udpBuf[1];
      if (udpBuf.length < 2 + len) break;
      const query = udpBuf.slice(2, 2 + len);
      udpBuf = udpBuf.slice(2 + len);
      const res = await fetch(DOH, {
        method: 'POST',
        headers: { 'content-type': 'application/dns-message' },
        body: query,
      });
      const answer = new Uint8Array(await res.arrayBuffer());
      const frame = new Uint8Array(2 + answer.length);
      frame[0] = answer.length >> 8;
      frame[1] = answer.length & 0xff;
      frame.set(answer, 2);
      if (ws.readyState !== WS_OPEN) return;
      if (responseHeader) {
        ws.send(concat(responseHeader, frame));
        responseHeader = null;
      } else ws.send(frame);
    }
  };

  const enqueue = (chunk) => {
    queue = queue.then(() => onData(chunk)).catch((e) => {
      console.log('edge error', String(e && e.message));
      safeClose(ws);
      try {
        socket && socket.close();
      } catch {}
    });
  };

  ws.addEventListener('message', (e) => {
    const d = e.data;
    if (typeof d === 'string') return;
    if (d instanceof ArrayBuffer) enqueue(new Uint8Array(d));
    else if (ArrayBuffer.isView(d)) enqueue(new Uint8Array(d.buffer, d.byteOffset, d.byteLength));
    else if (d && typeof d.arrayBuffer === 'function') {
      const p = d.arrayBuffer();
      queue = queue.then(() => p).then((b) => onData(new Uint8Array(b))).catch(() => safeClose(ws));
    } else console.log('edge: unknown frame', Object.prototype.toString.call(d));
  });
  ws.addEventListener('close', () => {
    try {
      socket && socket.close();
    } catch {}
  });
  ws.addEventListener('error', () => {
    try {
      socket && socket.close();
    } catch {}
  });
  if (pending.length) {
    const first = pending;
    pending = new Uint8Array(0);
    enqueue(first);
  }
}

// Direct connect; when the destination refuses (e.g. it is itself on Cloudflare), retry through PROXY_IP.
async function openTcp(host, port, env) {
  const target = host.startsWith('[') ? host.slice(1, -1) : host;
  try {
    const s = connect({ hostname: target, port });
    await s.opened;
    return s;
  } catch (e) {
    if (!env.PROXY_IP) throw e;
    const [ph, pp] = env.PROXY_IP.split(':');
    const s = connect({ hostname: ph, port: Number(pp) || port });
    await s.opened;
    return s;
  }
}

async function pipeBack(socket, ws, getHeader, clearHeader) {
  try {
    await socket.readable.pipeTo(
      new WritableStream({
        write(chunk) {
          if (ws.readyState !== WS_OPEN) throw new Error('ws closed');
          const h = getHeader();
          if (h) {
            ws.send(concat(h, chunk));
            clearHeader();
          } else ws.send(chunk);
        },
      })
    );
  } catch (e) {
    console.log('pipe error', String(e && e.message));
  }
  safeClose(ws);
}
