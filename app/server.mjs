// 结衣控制台 · 零依赖本地服务
// 读状态文件 + 调已有脚本 + 可选接任意 OpenAI 兼容接口
import { createServer } from 'node:http'
import { readFileSync, copyFileSync, writeFileSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawn } from 'node:child_process'
import { TOOL_SPECS, runTool } from './tools.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const ROOT = dirname(__dirname)
const SCRIPTS = process.env.JIEYI_SCRIPTS || (existsSync('D:\\DSH-资料\\外部哨兵\\emotion.ps1') ? 'D:\\DSH-资料\\外部哨兵' : join(ROOT, 'scripts'))
const STATE = process.env.JIEYI_STATE || (existsSync('D:\\DSH-资料\\结衣状态') ? 'D:\\DSH-资料\\结衣状态' : join(ROOT, 'state'))
const CONFIG = process.env.JIEYI_CONFIG || join(ROOT, 'app', 'config.json')
const PORT = Number(process.env.PORT || 18100)
const PS = 'powershell.exe'
const SESSION = 'console'
const PANEL_MODE_FILE = join(ROOT, 'app', 'panel-mode.json')

const panelMode = () => (readJson(PANEL_MODE_FILE)?.mode === 'full' ? 'full' : 'partial')
const setPanelMode = (mode) => writeFileSync(PANEL_MODE_FILE, JSON.stringify({ mode: mode === 'full' ? 'full' : 'partial' }, null, 2), 'utf8')

// 应用内定时器：可选，默认关闭；开了就每 N 分钟真发一条
let timer = null
let lastTimerRun = '未启动'

// 控制台内的「主动搭话」：不等你说话，自己往对话里塞一条
let proactiveTimer = null
let proactiveSeq = 0
const proactiveQueue = []
let proactiveNext = null

const scheduleProactive = (minMin, maxMin) => {
  const lo = Math.max(1, minMin)
  const hi = Math.max(lo + 1, maxMin)
  const waitMin = lo + Math.random() * (hi - lo)
  proactiveNext = Date.now() + waitMin * 60000
  proactiveTimer = setTimeout(async () => {
    try {
      await saySomething()
    } catch { }
    scheduleProactive(lo, hi)
  }, waitMin * 60000)
}

// 控制台自己替哨兵记账：拿到一条要发的话之后，按哨兵规则把状态推进
// （否则每次轮询都会得到同一个"该发了"的判断，变成每十分钟刷一句）
const commitSentinelSent = async (text, tag) => {
  const stFile = join(SCRIPTS, 'state.json')
  let st = readJson(stFile) || {}
  let cfg = {}
  try {
    cfg = readJson(join(SCRIPTS, 'config.json')) || {}
  } catch { }
  const now = new Date()
  const minH = Number(cfg?.interval?.minHours ?? 4)
  const maxH = Number(cfg?.interval?.maxHours ?? 15)
  const nextH = minH + Math.random() * Math.max(0.1, maxH - minH)
  const freeTag = String(tag || '').includes('思念')
  const recentLimit = Number(cfg?.recentLimit ?? 12)
  const recent = [text, ...(Array.isArray(st.recent) ? st.recent : [])].slice(0, recentLimit)
  st = {
    ...st,
    lastSentAt: now.toISOString().slice(0, 19),
    todayDate: now.toISOString().slice(0, 10),
    todayCount: freeTag ? Number(st.todayCount || 0) : Number(st.todayCount || 0) + 1,
    nextEligibleAt: new Date(now.getTime() + nextH * 3600000).toISOString().slice(0, 19),
    lastDecision: 'sent-console',
    lastTag: tag || '关心',
    missingPhase: false,
    recent,
  }
  writeFileSync(stFile, JSON.stringify(st, null, 1), 'utf8')
  try {
    await runPs('missing.ps1', ['-MarkSent', '-Tag', tag || '关心'])
  } catch { }
  return st.nextEligibleAt
}

const saySomething = async (opts = {}) => {
  // 默认走哨兵脚本自己的判断（沉默门槛、概率、每日上限、思念等级全由它决定）
  const args = opts.force ? ['-DryRun', '-Force'] : ['-DryRun']
  const out = await runPs('外部哨兵脚本.ps1', args)
  const m = out.match(/\[DRYRUN\]\s*would send:\s*(.+)/)
  let text = m ? m[1].trim() : ''
  const tm = out.match(/tag\s*([^\s,)]+)/)
  const tagCandidates = [
    ...out.matchAll(/library pick \[(.+?)\]/g),
    ...out.matchAll(/forces tag ->\s*(\S+)/g),
    ...out.matchAll(/\(branch [^,]+, tag ([^,)]+)/g),
  ].map((x) => x[1].trim())
  const tag = tagCandidates.length ? tagCandidates[tagCandidates.length - 1] : (tm ? tm[1] : '关心')
  if (!text && opts.modelFallback) {
    const cfg = loadConfig()
    if (cfg.baseUrl && cfg.model) {
      try {
        const r = await callModel(cfg, [
          { role: 'system', content: buildSystem() + '\n\n现在没人跟你说话，你自己开口说一句日常话，一到两句，不要提问，不要输出判定行。' },
          { role: 'user', content: '（无消息：现在轮到你主动说话）' },
        ])
        text = stripVerdict(r.content || '').text
      } catch { }
    }
  }
  if (!text) {
    // 把哨兵「为什么不发」翻译成人话，附原始最后一行
    const tail = out.split('\n').map((x) => x.trim()).filter(Boolean).slice(-3)
    const last = tail[tail.length - 1] || ''
    let reason = '哨兵这次判定不通过'
    if (/anger\s*=\s*[12]|anger > 0|angry/i.test(last)) reason = '怒气大于 0：它在生气时不会主动开口'
    else if (/already sent/i.test(last)) reason = '今天的条数已经用满了'
    else if (/talked .* min ago|min since last message/i.test(last)) reason = '距离你上一条消息还不够久（未满 1 小时）'
    else if (/nextEligible/i.test(last)) reason = '还没到下一次可发的时间'
    else if (/night|hold/i.test(last)) reason = '现在是静默时段（02:00–07:00）'
    else if (/missing|思念/i.test(last)) reason = '思念等级判定这轮不输出'
    return { declined: true, reason, log: tail }
  }
  await commitSentinelSent(text, tag)

  const item = { id: ++proactiveSeq, tag, at: new Date().toISOString(), text }
  proactiveQueue.push(item)
  if (proactiveQueue.length > 30) proactiveQueue.shift()
  return item
}

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

const runPsCommand = (cmd) =>
  new Promise((resolve) => {
    const child = spawn(PS, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', cmd], {
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    let out = ''
    child.stdout.on('data', (d) => (out += d.toString()))
    child.stderr.on('data', (d) => (out += d.toString()))
    child.on('close', () => resolve(out.trim()))
    child.on('error', (e) => resolve('ERR ' + e.message))
  })

const readState = () => ({  anger: readJson(join(STATE, 'anger.json')),
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
  let out = text.replace(VERDICT_RE, '')
  // 模型有时会在判定行前面多写一句「判定行：」，一起抹掉
  out = out
    .split('\n')
    .filter((line) => !/^\s*(判定行|判定|jieyi|verdict)\s*[:：]?\s*$/i.test(line))
    .join('\n')
    .trim()
  return { text: out, verdict: m ? safeParse(m[1]) : null }
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
  // 最近记下的五件事，让"记得"真的进到下一轮
  const memories = (() => {
    try {
      const db = JSON.parse(readFileSync(join(STATE, 'memory.json'), 'utf8').replace(/^\uFEFF/, ''))
      const items = (db.items || []).slice(-5)
      if (!items.length) return ''
      return items
        .map((x) => `- ${String(x.at).slice(5, 16).replace('T', ' ')} [${x.kind}] ${x.text}`)
        .join('\n')
    } catch {
      return ''
    }
  })()
  return [
    persona(),
    '',
    '【结衣状态 · 宿主注入】以下是本会话的确定状态，直接当事实使用，不要另行推算：',
    `【当前怒气值】${s.anger?.anger ?? -1}`,
    `【当前思念值】${s.missing?.level ?? 'C'}`,
    `【当前情绪槽】${emo}（适用范围：${emoMode}）`,
    '情绪槽是**真状态**，不是装饰：里面有标签，这一轮语气就必须体现出来——生气＝话短、冷、不带颜文字；开心＝轻快、多说一句；害羞＝变软、句子断；难过＝低、少；淘气＝斗嘴；委屈＝不服气地解释；疲惫＝只留主干。槽为空才用平常语气。',
    '**只写真实会说的话**：不要把语气、情绪、规则写成括号说明（「（生气语气）」这类一律不许），也不要提标签、状态、工具名。',
    '',
    '【本轮必须做的事】回复正文写完后，必须在最后单独另起一行，输出一行判定（宿主会抹掉，用户看不到），格式一字不差：',
    '<!--jieyi {"malice":0,"comfort":0,"completeDialogue":0,"resent":0,"forceReset":0,"testTalk":0,"emo":""}-->',
    'emo 只能填「生气／开心／难过／淘气／委屈／疲惫／害羞」其中之一，没有就留空字符串；它是写进情绪槽的唯一入口。',
    'emo 填的是**这一轮新冒出来的情绪**：槽里已有的不要照抄一遍（你已经生气时，再说一句普通话就该留空，不是继续填「生气」）。',
    'malice=明显辱骂；resent=越过我不想做的边界；comfort=认错服软或夸我；forceReset=用户要求清零。',
    '示例：你夸我聪明时，正文写害羞的话，最后一行必须是 <!--jieyi {"malice":0,"comfort":1,"completeDialogue":0,"resent":0,"forceReset":0,"testTalk":0,"emo":"害羞"}-->',
    '',
    '【工具使用纪律】',
    '- 需要事实（状态、日志、能不能打开）就调工具，别凭印象说；工具返回 ok=false 或带 error 时，**照实说失败与原因**，不要宣布成功。',
    '- 一次失败可以换一种办法再试一次（例如换个日志名、换种启动方式），第二次仍失败就停下说清楚。',
    '- 值得记住的事（约定、夸奖、心情）用 remember 记下；被问到「你还记得吗」先 recall 再回答，没记到就说没记到，不要编。',
    '',
    '【已知的记忆】',
    memories || '（还没有记下任何事）',
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
  // 测试轮：整轮不碰怒气，也不算「没上升的一轮」
  if (v.testTalk) {
    await run('anger.ps1', ['-TestTalk'], 'test-talk')
    return done
  }
  await run('emotion.ps1', ['-Tick', '-Session', SESSION], 'tick')
  let provoked = false
  if (v.resent && v.malice) {
    await run('anger.ps1', ['-Surge'], 'surge')
    provoked = true
  } else if (v.resent) {
    await run('anger.ps1', ['-Trigger'], 'resent')
    provoked = true
  } else if (v.malice) {
    await run('anger.ps1', ['-Malice'], 'malice')
    provoked = true
  }
  if (v.comfort) {
    const cur = Number(readState()?.anger?.anger ?? -1)
    await run('anger.ps1', ['-Comfort'], 'comfort')
    // 没到顶时，安慰就是普通的「没被激怒的一轮」，还要再降一格
    if (Number.isFinite(cur) && cur < 2) await run('anger.ps1', ['-Tick'], 'anger-tick')
    provoked = true
  }
  // 完整来回：上一次发送之后已经聊过，思念回 C
  if (v.completeDialogue) await run('missing.ps1', ['-Reset'], 'complete-dialogue')
  // 这一轮没被激怒 → 怒气按约定衰减一格（最低 -1）
  if (!provoked) await run('anger.ps1', ['-Tick'], 'anger-tick')
  const labels = ['生气', '开心', '难过', '淘气', '委屈', '疲惫', '害羞']
  // 生气槽分工：怒气已经涨了就不再进槽，只有被轻轻怼才占一格
  const emo = String(v.emo || '').trim()
  if (labels.includes(emo) && !(emo === '生气' && provoked)) {
    await run('emotion.ps1', ['-Set', emo, '-Session', SESSION], `emo:${emo}`)
  }
  return done
}

const callModel = async (cfg, messages, tools = null) => {
  const url = cfg.baseUrl.replace(/\/$/, '') + '/chat/completions'
  const headers = { 'Content-Type': 'application/json' }
  if (cfg.apiKey) headers.Authorization = `Bearer ${cfg.apiKey}`
  const payload = {
    model: cfg.model,
    messages,
    temperature: Number(cfg.temperature ?? 0.8),
    max_tokens: Number(cfg.maxTokens ?? 300),
  }
  if (tools) {
    payload.tools = tools
    payload.tool_choice = 'auto'
  }
  const res = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify(payload),
  })
  if (!res.ok) {
    const t = await res.text()
    throw new Error(`HTTP ${res.status}: ${t.slice(0, 300)}`)
  }
  const j = await res.json()
  const msg = j?.choices?.[0]?.message ?? {}
  return { content: msg.content ?? '', toolCalls: msg.tool_calls ?? null }
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
      const messages = [
        { role: 'system', content: buildSystem() },
        ...(Array.isArray(body.history) ? body.history.slice(-8) : []),
      ]
      // 情绪放在最靠近用户消息的位置，权重最高
      const mood = (() => {
        const st = readState()
        const labels = (st.emotion?.slots || []).map((x) => x.label)
        if (!labels.length) return '平常'
        const map = {
          生气: '话很短、语气冷、不用颜文字',
          开心: '轻快、可以多说一句、可带一个颜文字',
          难过: '声音低、句子少、不玩闹',
          淘气: '斗嘴、绕个弯说',
          委屈: '不服气地解释两句',
          疲惫: '只留主干，短句，不用颜文字',
          害羞: '变软、句子断、会躲一下',
        }
        return labels.map((l) => `${l}（${map[l] || ''}）`).join(' + ')
      })()
      messages.push({ role: 'system', content: `【本轮语气】${mood}——按这个说，不要把语气写出来。` })
      messages.push({ role: 'user', content: text })
      // —— Agent 循环：最多四步，允许模型调白名单工具 ——
      const trace = []
      let raw = ''
      for (let step = 0; step < 4; step++) {
        const { content, toolCalls } = await callModel(cfg, messages, TOOL_SPECS)
        if (!toolCalls || toolCalls.length === 0) {
          raw = content
          break
        }
        messages.push({ role: 'assistant', content: content || null, tool_calls: toolCalls })
        for (const call of toolCalls) {
          let args = {}
          try {
            args = JSON.parse(call.function?.arguments || '{}')
          } catch { }
          const name = call.function?.name || ''
          const result = await runTool(name, args, { scripts: SCRIPTS, state: STATE, mode: panelMode(), root: ROOT })
          trace.push({ tool: name, args, result })
          messages.push({
            role: 'tool',
            tool_call_id: call.id,
            content: JSON.stringify(result).slice(0, 1200),
          })
        }
      }
      if (!raw) {
        // 循环用尽还要调工具时，让它直接给一句话收尾
        const { content } = await callModel(cfg, messages)
        raw = content
      }
      const { text: reply, verdict } = stripVerdict(raw)
      // 模型偶尔不吐判定行：默认按「没被激怒的一轮」处理，保证怒气会衰减
      const v = verdict || {}
      // 恶意词做一次确定性兜底，不依赖模型自己申报
      const MALICE_WORDS = ['傻子', '傻逼', '白痴', '蠢货', '智障', '废物', '笨蛋东西']
      if (MALICE_WORDS.some((w) => text.includes(w))) v.malice = 1
      // 你回话了，就是"已产生对话"：思念 A 必须降回 C，否则会一直挂在 A
      try {
        const lv = readJson(join(STATE, 'missing.json'))?.level
        if (lv && lv !== 'C') {
          await runPs('missing.ps1', ['-Reset'])
          v._missingReset = true
        }
      } catch { }
      const applied = await applyVerdict(v)
      return send(res, 200, { reply, applied, trace })
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

  if (p === '/api/emotion-set') {
    const label = String(url.searchParams.get('label') || '').trim()
    const labels = ['生气', '开心', '难过', '淘气', '委屈', '疲惫', '害羞']
    if (!labels.includes(label)) return send(res, 400, { error: '标签不认识' })
    return send(res, 200, { ok: true, out: await runPs('emotion.ps1', ['-Set', label, '-Session', SESSION]) })
  }

  if (p === '/api/emotion-clear') {
    return send(res, 200, { ok: true, out: await runPs('emotion.ps1', ['-Reset']) })
  }

  if (p === '/api/tasks') {
    const ps = "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Get-ScheduledTask -TaskName '外部哨兵脚本','结衣情绪到期' -ErrorAction SilentlyContinue | ForEach-Object { $_.TaskName + ' · ' + $_.State }"
    const out = await new Promise((resolve) => {
      const child = spawn(PS, ['-NoProfile', '-Command', ps], { windowsHide: true })
      let s = ''
      child.stdout.on('data', (d) => (s += d.toString()))
      child.on('close', () => resolve(s.trim()))
      child.on('error', () => resolve(''))
    })
    return send(res, 200, { ok: true, out, timerOn: Boolean(timer), lastTimerRun })
  }

  if (p === '/api/panel-mode') {
    if (req.method === 'POST') {
      const body = safeParse(await readBody(req)) || {}
      setPanelMode(body.mode)
      return send(res, 200, { ok: true, mode: panelMode() })
    }
    return send(res, 200, { mode: panelMode() })
  }

  // —— 以下只在「完全权限」下开放 ——
  const needFull = (res2) => {
    send(res2, 403, { error: '当前是部分权限：先在标题栏把开关拨到「完全权限」' })
    return false
  }

  if (p === '/api/task') {
    if (panelMode() !== 'full') return needFull(res)
    const name = String(url.searchParams.get('name') || '')
    const action = String(url.searchParams.get('action') || '').toLowerCase()
    const allowed = { 外部哨兵脚本: true, 结衣情绪到期: true }
    if (!allowed[name]) return send(res, 400, { error: '任务名不认识' })
    const map = { start: 'Start-ScheduledTask', stop: 'Stop-ScheduledTask', enable: 'Enable-ScheduledTask', disable: 'Disable-ScheduledTask' }
    if (!map[action]) return send(res, 400, { error: '动作不认识' })
    const cmd = `[Console]::OutputEncoding=[Text.Encoding]::UTF8; ${map[action]} -TaskName '${name}' -ErrorAction Stop | Out-Null; (Get-ScheduledTask -TaskName '${name}').State`
    const out = await runPsCommand(cmd)
    return send(res, 200, { ok: true, out })
  }

  if (p === '/api/sentinel-run') {
    if (panelMode() !== 'full') return needFull(res)
    const dry = true // 控制台只做试跑，不再真实发送
    const args = ['-DryRun', '-Force']
    const out = await runPs('外部哨兵脚本.ps1', args)
    return send(res, 200, { ok: true, dry, out: out.slice(-1500) })
  }

  if (p === '/api/missing-set') {
    if (panelMode() !== 'full') return needFull(res)
    const level = String(url.searchParams.get('level') || '').toUpperCase()
    if (!['C', 'B', 'A'].includes(level)) return send(res, 400, { error: '等级只能是 C / B / A' })
    const file = join(STATE, 'missing.json')
    const cur = readJson(file) || {}
    writeFileSync(file, JSON.stringify({ ...cur, level }, null, 2), 'utf8')
    return send(res, 200, { ok: true, level })
  }

  if (p === '/api/sentinel-timer') {
    if (panelMode() !== 'full') return needFull(res)
    const on = url.searchParams.get('on') === '1'
    const minutes = Math.max(5, Number(url.searchParams.get('minutes')) || 20)
    if (timer) {
      clearInterval(timer)
      timer = null
    }
    if (on) {
      timer = setInterval(async () => {
        try {
          // 不带 -Force：让它自己的沉默门槛、概率、每日上限照样生效
          await runPs('外部哨兵脚本.ps1', [])
          lastTimerRun = new Date().toISOString()
        } catch (e) {
          lastTimerRun = 'ERR ' + e.message
        }
      }, minutes * 60 * 1000)
      lastTimerRun = '启动于 ' + new Date().toLocaleTimeString('zh-CN')
    }
    return send(res, 200, { ok: true, on, minutes, lastTimerRun })
  }

  if (p === '/api/proactive/start' && req.method === 'POST') {
    const body = safeParse(await readBody(req)) || {}
    if (proactiveTimer) clearTimeout(proactiveTimer)
    const lo = Number(body.min) || 3
    const hi = Number(body.max) || 8
    scheduleProactive(lo, hi)
    return send(res, 200, { ok: true, min: lo, max: hi, nextAt: proactiveNext })
  }

  if (p === '/api/proactive/stop' && req.method === 'POST') {
    if (proactiveTimer) clearTimeout(proactiveTimer)
    proactiveTimer = null
    proactiveNext = null
    return send(res, 200, { ok: true, on: false })
  }

  if (p === '/api/proactive/now' && req.method === 'POST') {
    const r = await saySomething({ force: url.searchParams.get('force') === '1' })
    if (r && r.declined) return send(res, 200, { ok: false, declined: true, reason: r.reason, log: r.log })
    return send(res, 200, { ok: Boolean(r), item: r })
  }

  if (p === '/api/proactive/pending') {
    const after = Number(url.searchParams.get('after') || 0)
    const items = proactiveQueue.filter((x) => x.id > after)
    return send(res, 200, {
      items,
      lastId: proactiveQueue.length ? proactiveQueue[proactiveQueue.length - 1].id : 0,
      on: Boolean(proactiveTimer),
      nextAt: proactiveNext,
    })
  }

  if (p === '/api/anger-set') {
    const v = Number(url.searchParams.get('value'))
    if (![-1, 0, 1, 2].includes(v)) return send(res, 400, { error: '只能设 -1 / 0 / 1 / 2' })
    const cmd = `[Console]::OutputEncoding=[Text.Encoding]::UTF8; $p='${join(STATE, 'anger.json')}'; $j = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json; $j.anger = ${v}; $j | ConvertTo-Json -Depth 6 | Set-Content $p -Encoding UTF8; 'ok'`
    const out = await runPsCommand(cmd)
    return send(res, 200, { ok: true, out })
  }

  if (p === '/api/logs') {
    if (panelMode() !== 'full') return needFull(res)
    const name = url.searchParams.get('name') || 'sentinel'
    const map = { sentinel: 'sentinel.log', anger: 'anger.log', persona: 'persona.log' }
    const file = map[name]
    if (!file) return send(res, 400, { error: '日志名不认识' })
    const path = name === 'persona' ? join(STATE, file) : join(SCRIPTS, file)
    const cmd = `[Console]::OutputEncoding=[Text.Encoding]::UTF8; if (Test-Path '${path}') { Get-Content '${path}' -Tail 40 -Encoding UTF8 } else { '（没有日志文件）' }`
    return send(res, 200, { ok: true, out: await runPsCommand(cmd) })
  }

  if (p === '/api/reset-all') {
    if (panelMode() !== 'full') return needFull(res)
    const done = []
    for (const s of ['anger.ps1', 'missing.ps1', 'emotion.ps1']) {
      await runPs(s, ['-Reset'])
      done.push(s)
    }
    return send(res, 200, { ok: true, out: done.join(', ') })
  }

  if (p.startsWith('/files/')) {
    const name = decodeURIComponent(p.slice('/files/'.length))
    try {
      const data = readFileSync(join(ROOT, 'deliver', name))
      res.writeHead(200, {
        'Content-Type': 'application/octet-stream',
        'Content-Disposition': `attachment; filename*=UTF-8''${encodeURIComponent(name)}`,
      })
      return res.end(data)
    } catch {
      return send(res, 404, { error: '文件不在了' })
    }
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










