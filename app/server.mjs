// 结衣控制台 · 零依赖本地服务
// 只读状态文件 + 调已有脚本，不重写任何规则
import { createServer } from 'node:http'
import { readFileSync, copyFileSync, writeFileSync } from 'node:fs'
import { join, dirname, extname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawn } from 'node:child_process'

const __dirname = dirname(fileURLToPath(import.meta.url))
const ROOT = dirname(__dirname)
const SCRIPTS = process.env.JIEYI_SCRIPTS || join(ROOT, 'scripts')
const STATE = process.env.JIEYI_STATE || join(ROOT, 'state')
const PORT = Number(process.env.PORT || 18100)
const PS = 'powershell.exe'

const readJson = (p) => {
  try {
    // PowerShell 写的 UTF-8 带 BOM，JSON.parse 会直接报错，这里先削掉
    const txt = readFileSync(p, 'utf8').replace(/^\uFEFF/, '')
    return JSON.parse(txt)
  } catch {
    return null
  }
}

const runPs = (script, args = []) =>
  new Promise((resolve) => {
    const child = spawn(PS, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(SCRIPTS, script), ...args], {
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    let out = ''
    child.stdout.on('data', (d) => (out += d.toString()))
    child.stderr.on('data', (d) => (out += d.toString()))
    child.on('close', () => resolve(out.trim()))
    child.on('error', (e) => resolve('ERR ' + e.message))
  })

const state = () => ({
  anger: readJson(join(STATE, 'anger.json')),
  missing: readJson(join(STATE, 'missing.json')),
  emotion: readJson(join(STATE, 'emotion.json')),
  emotionMode: readJson(join(STATE, 'emotion-mode.json')),
  sentinelMode: readJson(join(STATE, 'sentinel-mode.json')),
  usage: readJson(join(SCRIPTS, 'phrase-usage.json')),
})

const send = (res, code, body, type = 'application/json; charset=utf-8') => {
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store' })
  res.end(typeof body === 'string' ? body : JSON.stringify(body))
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1')
  const p = url.pathname

  if (p === '/' || p === '/index.html') {
    return send(res, 200, readFileSync(join(__dirname, 'public', 'index.html'), 'utf8'), 'text/html; charset=utf-8')
  }

  if (p === '/api/state') return send(res, 200, state())

  if (p === '/api/emotion-mode') {
    const mode = url.searchParams.get('mode') === 'all' ? 'all' : 'daily'
    const target = join(STATE, 'emotion-mode.json')
    copyFileSync(target, target + '.bak')
    writeFileSyncSafe(target, JSON.stringify({ mode, at: new Date().toISOString() }))
    return send(res, 200, { ok: true, mode })
  }

  if (p === '/api/sentinel-mode') {
    const mode = url.searchParams.get('mode') === 'model' ? 'model' : 'library'
    const target = join(STATE, 'sentinel-mode.json')
    writeFileSyncSafe(target, JSON.stringify({ mode, at: new Date().toISOString() }))
    return send(res, 200, { ok: true, mode })
  }

  if (p === '/api/anger-reset') {
    const out = await runPs('anger.ps1', ['-Reset'])
    return send(res, 200, { ok: true, out })
  }

  if (p === '/api/pick') {
    const args = ['-Show']
    const fg = url.searchParams.get('fg')
    if (fg) args.push('-Foreground', fg)
    const out = await runPs('pick_phrase.ps1', args)
    return send(res, 200, { ok: true, line: out })
  }

  if (p === '/api/emotion-run') {
    const out = await runPs('emotion.ps1', ['-Show'])
    return send(res, 200, { ok: true, out })
  }

  return send(res, 404, { error: 'not found' })
})

function writeFileSyncSafe(path, data) {
  try {
    writeFileSync(path, data, 'utf8')
  } catch (e) {
    console.warn('write failed:', e.message)
  }
}

server.listen(PORT, '127.0.0.1', () => {
  console.log(`结衣控制台：http://127.0.0.1:${PORT}`)
  console.log(`脚本目录：${SCRIPTS}`)
  console.log(`状态目录：${STATE}`)
})
