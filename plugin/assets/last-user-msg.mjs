// Newest user message time (epoch ms) inside a dsh session tree.
// Usage: node last-user-msg.mjs <sessionsRoot> [days] [--debug]
// Prints epoch ms, or "none" when no real user message is found.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import zlib from 'node:zlib';

const root = process.argv[2];
const days = Number(process.argv[3] || 5) || 5;
const debug = process.argv.includes('--debug');
const cutoff = Date.now() - days * 86400000;
const MAGIC = [0x28, 0xb5, 0x2f, 0xfd];

const files = [];
(function walk(d) {
  let ents = [];
  try { ents = readdirSync(d, { withFileTypes: true }); } catch { return; }
  for (const e of ents) {
    const p = join(d, e.name);
    if (e.isDirectory()) { walk(p); continue; }
    if (e.name !== 'session.v4.jsonl.zstd') continue;
    try { if (statSync(p).mtimeMs >= cutoff) files.push(p); } catch { /* ignore */ }
  }
})(root);

let best = 0;
let seen = 0;
const samples = [];
for (const f of files) {
  let buf;
  try { buf = readFileSync(f); } catch { continue; }
  const offs = [];
  for (let i = 0; i + 4 <= buf.length; i++) {
    if (buf[i] === MAGIC[0] && buf[i + 1] === MAGIC[1] && buf[i + 2] === MAGIC[2] && buf[i + 3] === MAGIC[3]) offs.push(i);
  }
  for (let k = 0; k < offs.length; k++) {
    const a = offs[k];
    const b = k + 1 < offs.length ? offs[k + 1] : buf.length;
    let txt;
    try { txt = zlib.zstdDecompressSync(buf.subarray(a, b)).toString('utf8'); } catch { continue; }
    for (const line of txt.split('\n')) {
      if (!line.startsWith('{"type":"user/message"')) continue;
      let o;
      try { o = JSON.parse(line); } catch { continue; }
      const src = o.data && o.data.source;
      if (!src || src.kind !== 'user' || !src.rpcId) continue;
      if (typeof o.time !== 'number') continue;
      seen++;
      if (samples.length < 5) {
        const t = (o.data.content || []).map((c) => c.text || '').join(' ').slice(0, 30);
        samples.push(`${new Date(o.time).toLocaleString('sv-SE')} ${t}`);
      }
      if (o.time > best) best = o.time;
    }
  }
}

if (debug) {
  process.stderr.write(`files=${files.length} userMsgs=${seen}\n${samples.join('\n')}\n`);
}
process.stdout.write(best ? String(best) : 'none');
