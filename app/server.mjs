// 结衣控制台 · 零依赖本地服务
// 读状态文件 + 调已有脚本 + 可选接任意 OpenAI 兼容接口
import { createServer } from 'node:http'
import { readFileSync, copyFileSync, writeFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawn } from 'node:child_process'

const __dirname = dirname(fileURLToPath(import.meta.url))
const ROOT = dirname(__dirname)
const SCRIPTS = process.env.JIEYI_SCRIPTS || join(ROOT, 'scripts')
const STATE = process.env.JIEYI_STATE || join(ROOT, 'state')
const CONFIG = process.env.JIEYI_CONFIG || join(ROOT, 'app', 'config.json')
const PORT = Number(process.env.PORT || 18100)
const PS = 'powershell.exe'
const SESSION = 'console'

const readJson = (p) => {
  try {
    // PowerShell 写的 UTF-8 带 BOM，JSON.parse 会直接报错，这里先削掉
    return JSON.parse(readFileSync(p, 'utf8').replace(/^\uFEFF/, ''))
  } catch {
    return null
  }
}

const loadConfig = () => ({
  baseUrl: '',
  apiKey: '',
  model: '',
  temperature: 0.8,
  maxTokens: 300,
  ...(readJson(CONFIG) || {}),
})

const saveConfig = (cfg) => {
  writeFileSync(CONFIG, JSON.stringify(cfg, null, 2), 'utf8')
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

const readState = () => ({
  anger: readJson(join(STATE, 'anger.json')),
  missing: readJson(join(STATE, 'missing.json')),
  emotion: readJson(join(STATE, 'emotion.json')),
  emotionMode: readJson(join(STATE, 'emotion-mode.json')),
  sentinelMode: readJson(join(STATE, 'sentinel-mode.json')),
  usage: readJson(join(SCRIPTS, 'phrase-usage.json')),
})

const persona = () => {
  try {
    return readFileSync(join(ROOT, 'plugin', 'assets', 'persona.md'), 'utf8')
  } catch {
    return ''
  }
}

const VERDICT_RE = /<!--jieyi\s+(\{[\s\S]*?\})\s*-->/

const stripVerdict = (text) => {
  const m = text.match(VERDICT_RE)
  return { text: text.replace(VERDICT_RE, '').trim(), verdict: m ? safeParse(m[1]) : null }
}

const safeParse = (s) => {
  try {
    return JSON.parse(s)
  } catch {
    return null
  }
}

const buildSystem = () => {
  const s = readState()
  const slots = (s.emotion?.slots || []).map((x) => x.label)
  const emo = slots.length ? slots.join(' + ') : '空'
  const emoMode = s.emotionMode?.mode === 'all' ? '全部对话' : '仅日常对话'
  return [
    '【结衣状态 · 宿主注入】以下是本会话的确定状态，直接当事实使用，不要另行推算：',
    `【当前怒气值】${s.anger?.anger ?? -1}`,
    `【当前思念值】${s.missing?.level ?? 'C'}`,
    `【当前情绪槽】${emo}（适用范围：${emoMode}）`,
    '读完本轮用户消息后，另起一行输出判定行（宿主会抹掉，用户看不到）：',
    '<!--jieyi {"malice":0,"comfort":0,"completeDialogue":0,"resent":0,"forceReset":0,"testTalk":0,"emo":""}-->',
    'emo=这一轮冒出的情绪，只能填「生气／开心／难过／淘气／委屈／疲惫／害羞」其中之一，没有就留空字符串；它是写进情绪槽的唯一入口，别在正文里提这件事。',
    'malice=明显辱骂；resent=越过我不想做的边界；comfort=认错服软或夸我；forceReset=用户要求清零。',
    '',
    persona(),
  ].join('\n')
}

const applyVerdict = async (v) => {
  if (!v) return []
  const done = []
  const run = async (script, args, tag) => {
    await runPs(script, args)
    done.push(tag)
  }
  if (v.forceReset) {
    await run('anger.ps1', ['-Reset'], 'anger-reset')
    return done
  }
  await run('emotion.ps1', ['-Tick', '-Session', SESSION], 'tick')
  if (v.resent && v.malice) await run('anger.ps1', ['-Surge'], 'surge')
  else if (v.resent) await run('anger.ps1', ['-Trigger'], 'resent')
  else if (v.malice) await run('anger.ps1', ['-Malice'], 'malice')
  if (v.comfort) await run('anger.ps1', ['-Comfort'], 'comfort')
  const labels = ['生气', '开心', '难过', '淘气', '委屈', '疲惫', '害羞']
  if (labels.includes(String(v.emo || '').trim())) {
    await run('emotion.ps1', ['-Set', String(v.emo).trim(), '-Session', SESSION], `emo:${v.emo}`)
  }
  return done
}

const callModel = async (cfg, messages) => {
  const url = cfg.baseUrl.replace(/\/$/, '') + '/chat/completions'
  const headers = { 'Content-Type': 'application/json' }
  if (cfg.apiKey) headers.Authorization = `Bearer ${cfg.apiKey}`
  const res = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      model: cfg.model,
      messages,
      temperature: Number(cfg.temperature ?? 0.8),
      max_tokens: Number(cfg.maxTokens ?? 300),
    }),
  })
  if (!res.ok) {
    const t = await res.text()
    throw new Error(`HTTP ${res.status}: ${t.slice(0, 300)}`)
  }
  const j = await res.json()
  return j?.choices?.[0]?.message?.content ?? ''
}

const send = (res, code, body, type = 'application/json; charset=utf-8') => {
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store' })
  res.end(typeof body === 'string' ? body : JSON.stringify(body))
}

const readBody = (req) =>
  new Promise((resolve) => {
    let b = ''
    req.on('data', (c) => (b += c))
    req.on('end', () => resolve(b))
  })

const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1')
  const p = url.pathname

  if (p === '/' || p === '/index.html') {
    return send(res, 200, readFileSync(join(__dirname, 'public', 'index.html'), 'utf8'), 'text/html; charset=utf-8')
  }

  if (p === '/api/state') return send(res, 200, readState())

  if (p === '/api/config' && req.method === 'GET') {
    const cfg = loadConfig()
    return send(res, 200, {
      baseUrl: cfg.baseUrl,
      model: cfg.model,
      hasKey: Boolean(cfg.apiKey),
      temperature: cfg.temperature,
    })
  }

  if (p === '/api/config' && req.method === 'POST') {
    const body = safeParse(await readBody(req)) || {}
    const cfg = loadConfig()
    if (typeof body.baseUrl === 'string') cfg.baseUrl = body.baseUrl.trim()
    if (typeof body.model === 'string') cfg.model = body.model.trim()
    if (typeof body.apiKey === 'string' && body.apiKey !== '') cfg.apiKey = body.apiKey.trim()
    if (body.temperature !== undefined) cfg.temperature = Number(body.temperature)
    saveConfig(cfg)
    return send(res, 200, { ok: true })
  }

  if (p === '/api/chat' && req.method === 'POST') {
    const body = safeParse(await readBody(req)) || {}
    const text = String(body.text || '').slice(0, 2000)
    if (!text) return send(res, 400, { error: '空消息' })
    const cfg = loadConfig()
    if (!cfg.baseUrl || !cfg.model) {
      return send(res, 400, { error: '还没配置接口：填 baseUrl 与 model（本地模型可以不填 key）' })
    }
    try {
      const raw = await callModel(cfg, [
        { role: 'system', content: buildSystem() },
        ...(Array.isArray(body.history) ? body.history.slice(-8) : []),
        { role: 'user', content: text },
      ])
      const { text: reply, verdict } = stripVerdict(raw)
      const applied = await applyVerdict(verdict)
      return send(res, 200, { reply, applied })
    } catch (e) {
      return send(res, 502, { error: String(e.message || e) })
    }
  }

  if (p === '/api/emotion-mode') {
    const mode = url.searchParams.get('mode') === 'all' ? 'all' : 'daily'
    const target = join(STATE, 'emotion-mode.json')
    writeFileSync(target, JSON.stringify({ mode, at: new Date().toISOString() }), 'utf8')
    return send(res, 200, { ok: true, mode })
  }

  if (p === '/api/sentinel-mode') {
    const mode = url.searchParams.get('mode') === 'model' ? 'model' : 'library'
    writeFileSync(join(STATE, 'sentinel-mode.json'), JSON.stringify({ mode, at: new Date().toISOString() }), 'utf8')
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
    return send(res, 200, { ok: true, line: await runPs('pick_phrase.ps1', args) })
  }

  if (p === '/api/emotion-run') {
    return send(res, 200, { ok: true, out: await runPs('emotion.ps1', ['-Show']) })
  }

  return send(res, 404, { error: 'not found' })
})

server.listen(PORT, '127.0.0.1', () => {
  console.log(`结衣控制台：http://127.0.0.1:${PORT}`)
  console.log(`脚本目录：${SCRIPTS}`)
  console.log(`状态目录：${STATE}`)
  const cfg = loadConfig()
  console.log(cfg.baseUrl && cfg.model && cfg.apiKey ? `模型接口：${cfg.baseUrl} (${cfg.model})` : '模型接口：未配置（面板照常可用）')
  if (!existsSync(CONFIG)) console.log(`提示：把 app/config.example.json 复制成 app/config.json 就能开启对话`)
})
