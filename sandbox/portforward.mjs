#!/usr/bin/env node
// airlock port forwarder — makes localhost-bound dev servers reachable.
//
// Docker publishes a port by DNAT'ing to the container's interface address.
// A dev server that binds 127.0.0.1 (the default for Vite, Astro, Next, and
// most others) is therefore unreachable from the host no matter how the port
// is mapped — which is why those tools all ship a --host flag.
//
// This removes the need for that flag. For each watched port it reads
// /proc/net/tcp{,6} and, ONLY when something is listening on loopback and
// nothing is listening on the wildcard address, opens a forwarder on the
// container's own IP that relays to 127.0.0.1.
//
// The "and nothing on the wildcard" condition is what keeps --host working:
// a server that already binds 0.0.0.0 owns the port, so we stay out of its
// way rather than racing it for the bind and making it fail with EADDRINUSE.
//
// No dependencies: node stdlib and /proc only.
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';

const PORTS = (process.env.AIRLOCK_FORWARD_PORTS || '3000,3001,3002,3003,3004,3005,4000,4173,4200,4321,5000,5001,5173,5174,5175,6006,8000,8080,8081,8787,9000')
  .split(',').map(n => parseInt(n, 10)).filter(Number.isInteger);
const INTERVAL = 1000;

const V4_ANY = '00000000', V4_LOOP = '0100007F';

// /proc/net/tcp6 stores an address as 4 x 32-bit words in HOST byte order, so
// ::1 appears as ...01000000, not ...00000001. Normalise by byte-swapping each
// word before comparing, or the v6 cases never match -- which is exactly the
// bug that made loopback-bound Astro/Vite (they listen on ::1) look idle.
const v6norm = h => {
  let o = '';
  for (let i = 0; i < 32; i += 8) {
    const w = h.slice(i, i + 8);
    o += w.slice(6, 8) + w.slice(4, 6) + w.slice(2, 4) + w.slice(0, 2);
  }
  return o.toUpperCase();
};
const V6_ANY = '0'.repeat(32);
const V6_LOOP = '0'.repeat(31) + '1';
// ::ffff:a.b.c.d — IPv4-mapped sockets show up on the v6 table too.
const V6_MAPPED_ANY = '00000000000000000000FFFF00000000';
const V6_MAPPED_LOOP = '00000000000000000000FFFF7F000001';

// The address Docker forwards published traffic to (first non-internal IPv4).
function outwardIP() {
  for (const list of Object.values(os.networkInterfaces()))
    for (const i of list || [])
      if (i.family === 'IPv4' && !i.internal) return i.address;
  return null;
}

// port -> {any:bool, loop:bool}, from the kernel's own listening table.
function listening() {
  const m = new Map();
  for (const file of ['/proc/net/tcp', '/proc/net/tcp6']) {
    const v6 = file.endsWith('6');
    let txt;
    try { txt = fs.readFileSync(file, 'utf8'); } catch { continue; }
    for (const line of txt.split('\n').slice(1)) {
      const f = line.trim().split(/\s+/);
      if (f.length < 4 || f[3] !== '0A') continue;      // 0A = TCP_LISTEN
      const [addrRaw, portHex] = f[1].split(':');
      const port = parseInt(portHex, 16);
      const cur = m.get(port) || { any: false, loop: false, target: null };
      if (v6) {
        const a = v6norm(addrRaw);
        if (a === V6_ANY || a === V6_MAPPED_ANY) cur.any = true;
        else if (a === V6_LOOP) { cur.loop = true; cur.target = cur.target || '::1'; }
        else if (a === V6_MAPPED_LOOP) { cur.loop = true; cur.target = cur.target || '127.0.0.1'; }
      } else {
        const a = addrRaw.toUpperCase();
        if (a === V4_ANY) cur.any = true;
        else if (a === V4_LOOP) { cur.loop = true; cur.target = '127.0.0.1'; }
      }
      m.set(port, cur);
    }
  }
  return m;
}

const active = new Map();   // port -> net.Server

function start(ip, port, target) {
  const srv = net.createServer(client => {
    const up = net.connect(port, target);
    client.on('error', () => up.destroy());
    up.on('error', () => client.destroy());
    client.pipe(up).pipe(client);
  });
  srv.on('error', () => { active.delete(port); srv.close(); });   // lost the race; retry next tick
  srv.listen(port, ip, () => console.error(`[airlock] forwarding ${ip}:${port} -> ${target}:${port}`));
  active.set(port, srv);
}

function tick() {
  const ip = outwardIP();
  if (!ip) return;
  const live = listening();
  for (const port of PORTS) {
    const s = live.get(port) || { any: false, loop: false };
    // Our own forwarder shows up as a wildcard-free listener on `ip`, so judge
    // solely on loopback vs wildcard and let `active` track what we opened.
    const want = s.loop && !s.any;
    if (want && !active.has(port)) start(ip, port, s.target || '127.0.0.1');
    else if (!want && active.has(port) && !s.any) {
      // server went away entirely -> drop the forwarder so a later one can bind
      if (!s.loop) { active.get(port).close(); active.delete(port); }
    }
  }
}

setInterval(tick, INTERVAL).unref?.();
setInterval(() => {}, 1 << 30);   // keep the process alive
tick();
