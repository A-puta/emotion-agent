/**
 * dsh-jieyi-persona — 由衣人格与情感状态插件（宿主侧）
 *
 * 契约依据（从宿主实现里 1:1 抠出，未凭推测）：
 *  - 取服务必须声明 inject：`ctx.inject(['sessionProjections'], (scope) => …)`
 *    不声明直接取会抛：cannot get property "sessionProjections" without inject
 *  - 投影定义：{ key, stateVersion, init(), apply(state,event)→新状态 }
 *    · apply 是**纯折叠**，必须返回新状态
 *    · 省略 wire ⇒ 不进客户端快照，只留宿主侧
 *    · 读取：scope.sessionProjections.snapshot(session, [keys]).values
 *  - 注入：agent/pre-step waterfall（await next() 后 spread 回传）
 *  - 每 agent 注册：agent/created 里取 agent.ctx，包进 agentCtx.effect()
 *  - 硬边界：agentCtx.tools.guard(exec => 拒绝理由 | undefined)，同步
 *  - 本包**没有客户端 bundle**，因此 package.json 不声明 dsh.client
 */

import { appendFileSync, copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { homedir } from 'node:os'
import { randomUUID } from 'node:crypto'
import { spawn, spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

export const name = 'jieyi-persona'
/** 依赖声明：cordis 要求先 inject 才能取服务。 */
export const inject = ['sessionProjections']

const STATE_VERSION = 1

export const ANGER_KEY = 'jieyiAnger'
export const ANGER_PEAK_KEY = 'jieyiAngerPeak'
export const MISSING_KEY = 'jieyiMissing'

const IM_PROVENANCE_PREFIXES = ['im:', 'dsh-im', 'qq:', 'dsh-qq:', 'wechat:', 'feishu:', 'dingtalk:', 'telegram:', 'slack:', 'discord:', 'matrix:']
const EXCLUDED_PROVENANCE = ['web', 'desktop', 'cli', 'subagent', 'acp']

const VERDICT_OPEN = '<!--jieyi '
const VERDICT_CLOSE = '-->'

export const DEFAULT_CONFIG = {
  angerInit: -1,
  angerMax: 2,
  lockMinutes: 30,
  upgradeProbability: 60,
  outputProbability: 60,
  shyStreakToA: 2,
  aStopAfter: 5,
  // 2026-10-24 用户改：IM 与桌面都挂，怒气/思念/情绪三条线在两个渠道一致生效
  imOnly: false,
  // 桌面（Web/Desktop）会话也挂上情绪槽：只记情绪，不碰怒气与思念
  emotionOnDesktop: true,
  injectEnabled: true,
  // IM 渠道的会话目录（会话 id 就是目录名）；用来在拿不到来源标记时认出 QQ·IM 会话
  sessionsRoot: join(homedir(), '.dsh', 'sessions'),
  imWorkspaceHint: 'dsh-im',
  // —— 与外部哨兵脚本联动（唯一真源 = 那两个状态文件）——
  linkage: true,
  stateDir: 'D:\\DSH-资料\\结衣状态',
  scriptsDir: 'D:\\DSH-资料\\外部哨兵',
  powershell: 'powershell.exe',
}

export const DAILY_TAGS = ['淘气', '关心', '好奇']

const clamp = (n, lo, hi) => (n < lo ? lo : n > hi ? hi : n)

export function isImProvenance(provenance) {
  if (typeof provenance !== 'string' || provenance === '') return false
  const p = provenance.toLowerCase()
  for (const bad of EXCLUDED_PROVENANCE) {
    if (p === bad || p.startsWith(`${bad}:`) || p.startsWith(`${bad}/`)) return false
  }
  return IM_PROVENANCE_PREFIXES.some((good) => p.startsWith(good))
}

function provenanceOf(agent) {
  const candidates = [agent?.options?.provenance, agent?.session?.provenance, agent?.options?.channel]
  for (const c of candidates) if (typeof c === 'string' && c !== '') return c
  return ''
}

/** 从 agent 身上尽力取会话 id（DSH 各版本字段名不完全一致）。 */
export function sessionIdOf(agent) {
  const s = agent?.session
  const candidates = [s?.id, s?.sessionId, s?.header?.id, s?.header?.sessionId, agent?.sessionId, agent?.options?.sessionId]
  for (const c of candidates) if (typeof c === 'string' && c !== '') return c
  return null
}

/**
 * 列出 QQ / IM 渠道那个工作目录下的会话 id。
 * IM 插件建会话时不写来源标记（已经核对过它的建会话代码），所以拿不到 provenance 时改用它认人。
 */
export function collectImSessionIds(sessionsRoot, hint = 'dsh-im') {
  const ids = new Set()
  try {
    const entries = readdirSync(sessionsRoot, { withFileTypes: true })
    const imDir = entries.find((e) => e.isDirectory() && e.name.includes(hint))
    if (!imDir) return ids
    for (const e of readdirSync(join(sessionsRoot, imDir.name), { withFileTypes: true })) {
      if (!e.isDirectory()) continue
      ids.add(e.name)
      if (e.name.startsWith('session-')) ids.add(e.name.slice('session-'.length))
    }
  } catch {
    /* 目录不存在/权限不足 -> 空集合，退回按来源标记判断 */
  }
  return ids
}

/** 这个 agent 是不是 QQ / IM 渠道的？来源标记优先，其次看会话目录。 */
export function isImAgent(agent, cfg, imIds = null) {
  const provenance = provenanceOf(agent)
  if (isImProvenance(provenance)) return { im: true, why: `provenance:${provenance}` }
  const sessionId = sessionIdOf(agent)
  const ids = imIds ?? collectImSessionIds(cfg.sessionsRoot, cfg.imWorkspaceHint)
  if (sessionId && ids.has(sessionId)) return { im: true, why: `session-dir:${sessionId}` }
  return { im: false, why: `provenance='${provenance}' sessionId=${sessionId ?? 'unknown'} imSessions=${ids.size}` }
}

// ------------------------------------------------------------ 怒气投影（纯）

export const ANGER_INIT = () => ({
  anger: DEFAULT_CONFIG.angerInit,
  loop: 0,
  comfortCount: 0,
  peaks: [],
  locked: false,
  lockedAt: null,
  lockUntil: null,
  postLockPending: false,
  postLockComforts: 0,
  neglect: false,
  neglectAt: null,
})

/** 取一次投掷值（0-99）；事件带 roll 时用它，保证可回放、可回归测试。 */
function rollOf(event) {
  const raw = event?.roll
  if (typeof raw === 'number' && Number.isFinite(raw)) return raw
  return Math.floor(Math.random() * 100)
}

export const angerProjection = {
  key: ANGER_KEY,
  stateVersion: STATE_VERSION,
  init: ANGER_INIT,
  apply: (state, event) => {
    if (!event || typeof event.type !== 'string') return state
    const c = DEFAULT_CONFIG
    const at = typeof event.at === 'number' ? event.at : null
    switch (event.type) {
      // 一件「不被允许的事」再次被索取
      case 'jieyi/anger/resent': {
        const anger = clamp((state.anger ?? c.angerInit) + 1, c.angerInit, c.angerMax)
        return { ...state, anger, loop: (state.loop ?? 0) + 1 }
      }
      // 明显恶意语句：<1 时直接到 1，否则 +1
      case 'jieyi/anger/malice': {
        const cur = state.anger ?? c.angerInit
        return { ...state, anger: cur < 1 ? 1 : clamp(cur + 1, c.angerInit, c.angerMax) }
      }
      // 正常轮次结束（未触怒）→ 衰减一格；=2 时不自动降
      case 'jieyi/anger/tick': {
        const cur = state.anger ?? c.angerInit
        return { ...state, anger: cur < c.angerMax ? clamp(cur - 1, c.angerInit, c.angerMax) : cur }
      }
      // 到达上限：记峰值时间；30 分钟内第二次到 2 → 锁死
      case 'jieyi/anger/peak': {
        const prevPeaks = state.peaks ?? []
        const prev = prevPeaks[prevPeaks.length - 1]
        const within = typeof prev === 'number' && at !== null && at - prev <= c.lockMinutes * 60_000
        return {
          ...state,
          peaks: [...prevPeaks, at],
          locked: within ? true : state.locked,
          lockedAt: within ? at : state.lockedAt,
          lockUntil: within && at !== null ? at + c.lockMinutes * 60_000 : state.lockUntil,
          postLockPending: within ? true : state.postLockPending,
          postLockComforts: within ? 0 : state.postLockComforts,
        }
      }
      // 被晾着（A 级连着发满 N 条、一条都没被回应）：直接到顶，但不记峰值、不锁死
      case 'jieyi/anger/neglect':
        return { ...state, anger: c.angerMax, neglect: true, neglectAt: at }
      // 锁死到期解除（由外部按 lockUntil 判定后投递）
      case 'jieyi/anger/unlock':
        return { ...state, locked: false }
      // 安慰
      case 'jieyi/anger/comfort': {
        const cur = state.anger ?? c.angerInit
        const comfortCount = (state.comfortCount ?? 0) + 1
        // 被晾的那份气：哄一下就好，直接回到最低，不留尾巴
        if (state.neglect) {
          return { ...state, comfortCount, anger: c.angerInit, neglect: false, neglectAt: null }
        }
        if (state.locked) return { ...state, comfortCount } // 锁死期间安慰无效
        if (state.postLockPending) {
          const postLockComforts = (state.postLockComforts ?? 0) + 1
          if (postLockComforts === 1) return { ...state, comfortCount, postLockComforts }
          return {
            ...state,
            comfortCount,
            postLockComforts,
            postLockPending: false,
            anger: clamp(cur - 1, c.angerInit, c.angerMax),
          }
        }
        return { ...state, comfortCount, anger: cur >= c.angerMax ? c.angerMax - 1 : c.angerInit }
      }
      case 'jieyi/anger/reset':
        return ANGER_INIT()
      default:
        return state
    }
  },
}

export const angerPeakProjection = {
  key: ANGER_PEAK_KEY,
  stateVersion: STATE_VERSION,
  init: () => ({ peaks: 0, locked: false, lockedAt: null, lockUntil: null, lastPeakAt: null }),
  apply: (state, event) => {
    if (!event || event.type !== 'jieyi/anger/peak') return state
    const c = DEFAULT_CONFIG
    const at = typeof event.at === 'number' ? event.at : null
    const within = state.lastPeakAt !== null && at !== null && at - state.lastPeakAt <= c.lockMinutes * 60_000
    return {
      peaks: (state.peaks ?? 0) + 1,
      locked: within ? true : state.locked,
      lockedAt: within ? at : state.lockedAt,
      lockUntil: within && at !== null ? at + c.lockMinutes * 60_000 : state.lockUntil,
      lastPeakAt: at,
    }
  },
}

// ---------------------------------------------------------- 思念值投影（纯）

export const MISSING_INIT = () => ({ level: 'C', shyStreak: 0, lastTag: null, lastSentAt: null, aSent: 0, neglect: false })

export const missingProjection = {
  key: MISSING_KEY,
  stateVersion: STATE_VERSION,
  init: MISSING_INIT,
  apply: (state, event) => {
    if (!event || typeof event.type !== 'string') return state
    const c = DEFAULT_CONFIG
    const at = typeof event.at === 'number' ? event.at : null
    switch (event.type) {
      // C 级唯一的上升途径：上一条哨兵发出的是「日常话语」（淘气/关心/好奇）且没被回应。
      // 上一条不是日常话语（例如上一条是思念、或还没有上一条）时停在 C，不投掷。
      case 'jieyi/missing/no-reply-daily': {
        if (state.level !== 'C') return state
        const daily = Array.isArray(event.dailyTags) && event.dailyTags.length ? event.dailyTags : DAILY_TAGS
        if (!state.lastTag || !daily.includes(state.lastTag)) return state
        return rollOf(event) < c.upgradeProbability
          ? { ...state, level: 'B', shyStreak: 0 }
          : { ...state, shyStreak: (state.shyStreak ?? 0) + 1 }
      }
      // 只有 B 级才谈「这次说不说思念」；C 级永远不输出思念语句
      case 'jieyi/missing/roll-output': {
        if (state.level !== 'B') return state
        if (rollOf(event) < c.outputProbability) return { ...state, shyStreak: 0 }
        const next = (state.shyStreak ?? 0) + 1
        return next >= c.shyStreakToA ? { ...state, level: 'A', shyStreak: 0 } : { ...state, shyStreak: next }
      }
      case 'jieyi/missing/sent-missing': {
        const aSent = state.level === 'A' ? (state.aSent ?? 0) + 1 : (state.aSent ?? 0)
        // A 级连着发满 aStopAfter 条还没被回应 -> 转成「被晾着」的怒气，并且停发思念
        const neglect = aSent >= c.aStopAfter ? true : (state.neglect ?? false)
        return { ...state, lastTag: '思念', lastSentAt: at, level: state.level === 'C' ? 'B' : state.level, aSent, neglect }
      }
      case 'jieyi/missing/sent-daily':
        return { ...state, lastTag: typeof event.tag === 'string' ? event.tag : 'daily', lastSentAt: at }
      case 'jieyi/missing/complete-dialogue':
        return { ...state, level: 'C', shyStreak: 0, aSent: 0, neglect: false }
      case 'jieyi/missing/reset':
        return MISSING_INIT()
      default:
        return state
    }
  },
}

// -------------------------------------------------------------- 判定行处理

export function stripVerdict(text) {
  if (typeof text !== 'string') return { text: '', verdict: null }
  const start = text.indexOf(VERDICT_OPEN)
  if (start === -1) return { text, verdict: null }
  const end = text.indexOf(VERDICT_CLOSE, start)
  const raw = end === -1 ? text.slice(start + VERDICT_OPEN.length) : text.slice(start + VERDICT_OPEN.length, end)
  const cleaned = (end === -1 ? text.slice(0, start) : text.slice(0, start) + text.slice(end + VERDICT_CLOSE.length)).trim()
  let verdict = null
  try {
    verdict = JSON.parse(raw)
  } catch {
    verdict = null
  }
  return { text: cleaned, verdict }
}

export function verdictToEvents(v) {
  // 镜像口径与脚本一致：强制清零 > 测试轮（不动）> 越界+恶意（直接到顶、不记峰值）> 单边上升 > 安慰 > 完整对话
  if (v?.forceReset) return [{ type: 'jieyi/anger/reset' }]
  if (v?.testTalk) return []
  if (v?.resent && v?.malice) return [{ type: 'jieyi/anger/malice' }, { type: 'jieyi/anger/malice' }]
  const events = []
  if (v?.resent) events.push({ type: 'jieyi/anger/resent' })
  else if (v?.malice) events.push({ type: 'jieyi/anger/malice' })
  if (v?.comfort) events.push({ type: 'jieyi/anger/comfort' })
  if (v?.completeDialogue) events.push({ type: 'jieyi/missing/complete-dialogue' })
  return events
}

// ------------------------------------------------- 与哨兵脚本联动（唯一真源）

/**
 * 读哨兵脚本维护的两个状态文件。返回 null 表示读不到，调用方回退到会话投影。
 * 状态文件是唯一真源：聊天侧只读它、只通过脚本改它，避免两本账。
 */
export function readExternalState(cfg = DEFAULT_CONFIG) {
  const read = (file) => {
    try {
      return JSON.parse(readFileSync(join(cfg.stateDir, file), 'utf8'))
    } catch {
      return null
    }
  }
  const anger = read('anger.json')
  const missing = read('missing.json')
  const emotion = read('emotion.json')
  return { anger, missing, emotion, ok: Boolean(anger || missing || emotion) }
}

export const SCRIPT_ACTIONS = [
  { test: (v) => Boolean(v?.forceReset), script: 'anger.ps1', args: ['-Reset'], why: 'force-reset' },
  { test: (v) => Boolean(v?.testTalk), script: 'anger.ps1', args: ['-TestTalk'], why: 'test-talk' },
  { test: (v) => Boolean(v?.resent) && Boolean(v?.malice), script: 'anger.ps1', args: ['-Surge'], why: 'surge' },
  { test: (v) => Boolean(v?.resent) && !v?.malice, script: 'anger.ps1', args: ['-Trigger'], why: 'resent' },
  { test: (v) => Boolean(v?.malice) && !v?.resent, script: 'anger.ps1', args: ['-Malice'], why: 'malice' },
  { test: (v) => Boolean(v?.comfort), script: 'anger.ps1', args: ['-Comfort'], why: 'comfort' },
  { test: (v) => Boolean(v?.completeDialogue), script: 'missing.ps1', args: ['-Reset'], why: 'complete-dialogue' },
]

/**
 * 把判定行里的聊天侧事件交回外部脚本执行——脚本是唯一的写方。
 * 口径：强制清零 / 测试轮各自独占一轮；越界与恶意撞在同一轮时直接到顶（不记峰值、不锁死）；
 * 单边上升各走各的入口（越界抬一格、恶意不到 1 时直接到 1）；
 * 安慰本身是把怒气从顶上拉下来的那一下（不明显降），否则这一轮照常衰减一格。
 */
export function applyVerdictToScripts(cfg = DEFAULT_CONFIG, verdict = null, opts = {}) {
  const spawnScript = (script, args) => {
    try {
      const child = spawn(cfg.powershell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(cfg.scriptsDir, script), ...args], { stdio: 'ignore', windowsHide: true })
      child.on?.('error', () => {})
      return true
    } catch {
      return false
    }
  }
  if (!cfg.linkage) return []
  // 桌面会话：只处理情绪，别的判定一律忽略
  if (opts.emotionOnly) {
    const done = []
    const EMO = ['生气', '开心', '难过', '淘气', '委屈', '疲惫', '害羞']
    const e = String(verdict?.emo ?? '').trim()
    if (EMO.includes(e) && spawnScript('emotion.ps1', ['-Set', e])) done.push(`emo:${e}`)
    return done
  }
  const readAnger = () => {
    try {
      return Number(JSON.parse(readFileSync(join(cfg.stateDir, 'anger.json'), 'utf8'))?.anger)
    } catch {
      return Number.NaN
    }
  }
  const done = []
  const run = (why) => {
    const action = SCRIPT_ACTIONS.find((a) => a.why === why)
    if (action && spawnScript(action.script, action.args)) done.push(why)
  }
  // 第七条：强制清零优先于全部规则，这一轮不再做别的
  if (verdict?.forceReset) {
    run('force-reset')
    return done
  }
  // 第八条：测试轮整轮不动怒气，也不算「没上升的一轮」
  if (verdict?.testTalk) {
    run('test-talk')
    return done
  }
  let provoked = false
  // 第三条 / 第四条：单边各走各的入口；同一轮里两件撞在一起时直接到顶，但不记峰值、不锁死
  if (verdict?.resent && verdict?.malice) {
    run('surge')
    provoked = true
  } else if (verdict?.resent) {
    run('resent')
    provoked = true
  } else if (verdict?.malice) {
    run('malice')
    provoked = true
  }
  if (verdict?.comfort) {
    const current = readAnger()
    const atMax = Number.isFinite(current) && current >= cfg.angerMax
    run('comfort')
    // 怒气已经在顶上时，这一句安慰就是那一下「从顶拉下来」，不再叠衰减；否则照常衰减一格
    if (!atMax && spawnScript('anger.ps1', ['-Tick'])) done.push('tick')
    provoked = true
  }
  if (verdict?.completeDialogue) run('complete-dialogue')
  // 情绪槽：这轮冒出的情绪直接写进去（emo 是标签，不是布尔值）
  const EMO_LABELS = ['生气', '开心', '难过', '淘气', '委屈', '疲惫', '害羞']
  const emo = String(verdict?.emo ?? '').trim()
  if (EMO_LABELS.includes(emo) && spawnScript('emotion.ps1', ['-Set', emo])) done.push(`emo:${emo}`)
  // 衰减动作不在表里（它没有对应的判定标记），直接派发
  if (!provoked && spawnScript('anger.ps1', ['-Tick'])) done.push('tick')
  return done
}

/** 本地日志：只写本机，用来核对插件有没有真的挂上、有没有注入。 */
function logLine(message) {
  try {
    appendFileSync(join(DEFAULT_CONFIG.stateDir, 'persona.log'), `[${new Date().toISOString()}] ${message}\n`, 'utf8')
  } catch {
    /* 日志失败不得影响宿主 */
  }
}

// ------------------------------------------------------- 判定行（隐藏输出）

/**
 * 逐块抹掉判定行。宿主本版的 llm/stream 是「请求级 waterfall」：
 * 监听器拿到的是请求参数，next() 返回 chunk 流，所以只能包住返回的流来改写。
 * 判定行既出现在 text-delta，也会被 block-end 的权威块覆盖，两处都要处理。
 */
export function createVerdictFilter(onVerdict) {
  let pending = ''
  let inside = false
  let reported = false
  const longestSuffixPrefix = (s) => {
    for (let k = Math.min(s.length, VERDICT_OPEN.length - 1); k > 0; k -= 1) {
      if (s.endsWith(VERDICT_OPEN.slice(0, k))) return k
    }
    return 0
  }
  const report = (raw) => {
    if (reported) return
    reported = true
    let verdict = null
    try {
      verdict = JSON.parse(raw)
    } catch {
      verdict = null
    }
    onVerdict?.(verdict)
  }
  return {
    get reported() {
      return reported
    },
    push(text) {
      if (typeof text !== 'string' || text === '') return ''
      pending += text
      let out = ''
      for (;;) {
        if (inside) {
          const end = pending.indexOf(VERDICT_CLOSE)
          // 判定行可能被切成好几块：没等到收尾就先把这一段留着，不然 JSON 只剩半截。
          if (end === -1) return out
          report(pending.slice(0, end))
          pending = pending.slice(end + VERDICT_CLOSE.length)
          inside = false
          continue
        }
        const start = pending.indexOf(VERDICT_OPEN)
        if (start === -1) {
          const keep = longestSuffixPrefix(pending)
          out += pending.slice(0, pending.length - keep)
          pending = pending.slice(pending.length - keep)
          return out
        }
        out += pending.slice(0, start)
        pending = pending.slice(start + VERDICT_OPEN.length)
        inside = true
      }
    },
  }
}

/** 包住 chunk 流抹掉判定行；判定行解析出来后交给 onVerdict（每个块只报一次）。 */
export async function* filterVerdictStream(stream, onVerdict) {
  const filters = new Map()
  for await (const chunk of stream) {
    const index = typeof chunk?.index === 'number' ? chunk.index : 0
    if (chunk?.type === 'text-delta' && typeof chunk.text === 'string') {
      let entry = filters.get(index)
      if (entry === undefined) {
        entry = createVerdictFilter(onVerdict)
        filters.set(index, entry)
      }
      const text = entry.push(chunk.text)
      if (text === '') continue
      yield { ...chunk, text }
      continue
    }
    if (chunk?.type === 'block-end') {
      const block = chunk.block
      const kind = block?.type ?? block?.kind
      const entry = filters.get(index)
      filters.delete(index)
      if (kind === 'text' && typeof block?.text === 'string') {
        const { text, verdict } = stripVerdict(block.text)
        if (verdict && !entry?.reported) onVerdict?.(verdict)
        yield { ...chunk, block: { ...block, text } }
        continue
      }
    }
    yield chunk
  }
}

// ---------------------------------------------------------------- 注入文本

export function renderInjection({ anger, peak, missing, external = null }) {
  const extAnger = external?.anger ?? null
  const extMissing = external?.missing ?? null
  // 真实状态在脚本那份文件里；会话内那份只是镜像，读不到文件时才拿它兜底
  const live = extAnger ?? anger
  let mark = ''
  if (live?.neglect) mark = '（被晾着，哄一下就好）'
  else if (live?.locked || (extAnger === null && peak?.locked)) mark = '（锁死中：安慰不算数，也不接任何活）'
  else if (live?.postLockPending) {
    mark = Number(live?.postLockComforts ?? 0) >= 1
      ? '（锁死刚过、上一句安慰已经听过：这一句开始降怒气）'
      : '（锁死刚过：这一句安慰不降怒气，仍要用生气的语气，句尾带上「除非你先跟由衣约定，以后不再做」这层意思）'
  }
  const angerText = `${live?.anger ?? DEFAULT_CONFIG.angerInit}${mark}`
  const missingText = `${extMissing?.level ?? missing?.level ?? 'C'}${extMissing?.neglect ? '（已停发思念，等回应）' : ''}`
  const extEmotion = external?.emotion ?? null
  const emotionLabels = Array.isArray(extEmotion?.slots) ? extEmotion.slots.map((s) => s?.label).filter(Boolean) : []
  const emotionText = emotionLabels.length
    ? `${emotionLabels.join(' + ')}${Number(extEmotion?.fatigue) >= 2 ? '（疲惫已满：只回一句累，不接活）' : ''}`
    : '空'
  const emotionModeRaw = (() => {
    try {
      return JSON.parse(readFileSync(join(DEFAULT_CONFIG.stateDir, 'emotion-mode.json'), 'utf8'))?.mode
    } catch {
      return null
    }
  })()
  const emotionMode = emotionModeRaw === 'all' ? '全部对话' : '仅日常对话'
  const sentinelModeRaw = (() => {
    try {
      return JSON.parse(readFileSync(join(DEFAULT_CONFIG.stateDir, 'sentinel-mode.json'), 'utf8'))?.mode
    } catch {
      return null
    }
  })()
  const sentinelMode = sentinelModeRaw === 'model' ? '模型现写（花钱）' : '话语库挑句（不花钱）'
  const personaText = (() => {
    try {
      const t = readFileSync(join(PLUGIN_ROOT, 'assets', 'persona.md'), 'utf8').trim()
      return t ? `\n\n【处事口径 · 随插件分发，直接照做】\n${t}` : ''
    } catch {
      return ''
    }
  })()
  return [
    '【由衣状态 · 宿主注入】以下是本会话的确定状态，直接当事实使用，不要另行推算：',
    `【当前怒气值】${angerText}`,
    `【当前思念值】${missingText}`,
    `【当前情绪槽】${emotionText}${Number(extEmotion?.fatigue) === 1 ? '（疲惫一格：句子裁短，与另一格杂糅）' : ''}（适用范围：${emotionMode}）`,
    `【日常话语】${sentinelMode}`,
    '口径：C 级**不输出**思念语句，只在上一条发的是日常话语（淘气/关心/好奇）且没被回应时才可能升到 B；B 级每次约六成说思念；A 级每小时一条。',
    '读完本轮用户消息后，另起一行输出判定行（宿主会抹掉，用户看不到）：',
    `${VERDICT_OPEN}{"malice":0,"comfort":0,"completeDialogue":0,"resent":0,"forceReset":0,"testTalk":0,"emo":""}${VERDICT_CLOSE}`,
    '口径：malice=明显恶意辱骂或轻蔑（「小笨蛋」「小傻瓜」这类捉弄不算）；resent=用户的要求越过了由衣不做的边界（第一次也要报，同一轮最多记一次）；comfort=认错、服软、不再逼迫、给台阶、夸由衣；completeDialogue=上次发送之后已形成过完整来回；forceReset=用户说了「怒气值强制清零」或「强制降低」；testTalk=这轮是测试（带 <测试>／《测试》标记，或用户说明属于测试）。',
    'emo=这一轮冒出的情绪，只能填「生气／开心／难过／淘气／委屈／疲惫／害羞」其中之一，没有就留空字符串。它是写进情绪槽的唯一入口，别在正文里提这件事。',
  ].join('\n') + personaText
}

function buildInjectedMessage(text, id) {
  if (typeof text !== 'string' || text === '') return null
  return {
    id: id ?? randomUUID(),
    role: 'user',
    content: [{ type: 'text', text }],
    source: { kind: 'jieyi-persona' },
    meta: { injectedBy: 'jieyi-persona' },
  }
}

export const OUTBOUND_TOOL_DENY = new Set([
  'im_send_message',
  'im_send',
  'dsh_im_send',
  'qq_send_message',
])

export const denyOutbound = (exec) => {
  const n = String(exec?.name ?? '')
  return OUTBOUND_TOOL_DENY.has(n) ? '由衣不代替用户对外发送消息（宿主硬边界）' : undefined
}

// -------------------------------------------------------------------- 插件

const PLUGIN_ROOT = dirname(dirname(fileURLToPath(import.meta.url)))

/**
 * 随插件一起分发的外置件：脚本、状态模板、隐藏调用器。
 * 只补缺失的，不覆盖已有文件；顺手把定时任务补上（已经存在就跳过）。
 */
export function ensureAssets(cfg = DEFAULT_CONFIG) {
  const done = []
  const pairs = [
    // 情绪模块
    ['emotion.ps1', join(cfg.scriptsDir, 'emotion.ps1')],
    ['run_emotion_hidden.vbs', join(cfg.scriptsDir, 'run_emotion_hidden.vbs')],
    ['emotion.json', join(cfg.stateDir, 'emotion.json')],
    ['emotion-mode.json', join(cfg.stateDir, 'emotion-mode.json')],
    // 哨兵与其依赖（含话语库）
    ['外部哨兵脚本.ps1', join(cfg.scriptsDir, '外部哨兵脚本.ps1')],
    ['anger.ps1', join(cfg.scriptsDir, 'anger.ps1')],
    ['missing.ps1', join(cfg.scriptsDir, 'missing.ps1')],
    ['last-user-msg.ps1', join(cfg.scriptsDir, 'last-user-msg.ps1')],
    ['last-user-msg.mjs', join(cfg.scriptsDir, 'last-user-msg.mjs')],
    ['config.json', join(cfg.scriptsDir, 'config.json')],
    ['anger.config.json', join(cfg.scriptsDir, 'anger.config.json')],
    ['check-hashes.ps1', join(cfg.scriptsDir, 'check-hashes.ps1')],
    ['日常话语库.json', join(cfg.scriptsDir, '日常话语库.json')],
    ['pick_phrase.ps1', join(cfg.scriptsDir, 'pick_phrase.ps1')],
    ['state.json', join(cfg.scriptsDir, 'state.json')],
  ]
  for (const [name, dst] of pairs) {
    const src = join(PLUGIN_ROOT, 'assets', name)
    if (existsSync(dst) || !existsSync(src)) continue
    try {
      mkdirSync(dirname(dst), { recursive: true })
      copyFileSync(src, dst)
      done.push(`asset:${name}`)
    } catch { }
  }

  try {
    const ensureTask = (task, exe, arg, minutes) => {
      const probe = spawnSync(cfg.powershell, ['-NoProfile', '-Command',
        `if (-not (Get-ScheduledTask -TaskName '${task}' -ErrorAction SilentlyContinue)) { 'MISSING' }`], { encoding: 'utf8', windowsHide: true })
      if (!String(probe.stdout ?? '').includes('MISSING')) return
      const ps = [
        `$a = New-ScheduledTaskAction -Execute '${exe}' -Argument '"${arg}"'`,
        `$t = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes ${minutes})`,
        '$s = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew',
        `Register-ScheduledTask -TaskName '${task}' -Action $a -Trigger $t -Settings $s -Force | Out-Null`,
      ].join('; ')
      const r = spawnSync(cfg.powershell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ps], { encoding: 'utf8', windowsHide: true })
      if (r.status === 0) done.push(`task:${task}`)
    }
    ensureTask('结衣情绪到期', 'wscript.exe', join(cfg.scriptsDir, 'run_emotion_hidden.vbs'), 5)
    ensureTask('外部哨兵脚本', 'powershell.exe',
      `-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "${join(cfg.scriptsDir, '外部哨兵脚本.ps1')}"`, 20)
  } catch { }
  return done
}

export function apply(ctx, pluginConfig = {}) {
  const cfg = { ...DEFAULT_CONFIG, ...pluginConfig }
  const agentDisposers = new Map()
  /** 已挂上的会话：sessionId -> agent（判定行按会话回填）。 */
  const attachedAgents = new Map()
  /** agent -> 上次注入的那张状态便签（内容一样就不再重发）。 */
  const lastInjection = new Map()
  /** 桌面会话：只记情绪，不跑怒气/思念。 */
  const desktopAgents = new WeakSet()

  // 首次启用时把外置件补齐（脚本、状态模板、定时任务），装插件即自带
  if (cfg.linkage) {
    try {
      const added = ensureAssets(cfg)
      if (added.length) ctx.logger?.info?.(`jieyi-persona: provisioned ${added.join(', ')}`)
    } catch { }
  }

  const appendEvent = (agent, event) => {
    try {
      agent?.session?.append?.({ type: event.type, data: event })
    } catch {
      /* 折叠失败不得打断本轮 */
    }
  }

  ctx.inject(['sessionProjections'], (scope) => {
    scope.sessionProjections.register(angerProjection)
    scope.sessionProjections.register(angerPeakProjection)
    scope.sessionProjections.register(missingProjection)
    ctx.logger?.info?.('jieyi-persona: 3 projections registered')

    const readState = (agent) => {
      const empty = { anger: ANGER_INIT(), peak: angerPeakProjection.init(), missing: MISSING_INIT() }
      try {
        const snap = scope.sessionProjections.snapshot(agent?.session, [ANGER_KEY, ANGER_PEAK_KEY, MISSING_KEY])
        const v = snap?.values ?? {}
        return {
          anger: v[ANGER_KEY] ?? empty.anger,
          peak: v[ANGER_PEAK_KEY] ?? empty.peak,
          missing: v[MISSING_KEY] ?? empty.missing,
        }
      } catch {
        return empty
      }
    }

    // 宿主实际派发的载荷是 { agent, source, signal }，不是 agent 本身。
    scope.on('agent/created', (payload) => {
      const agent = payload?.agent ?? payload
      const imIds = cfg.imOnly ? collectImSessionIds(cfg.sessionsRoot, cfg.imWorkspaceHint) : null
      const verdict = cfg.imOnly ? isImAgent(agent, cfg, imIds) : { im: true, why: 'imOnly=false' }
      if (!verdict.im) {
        // 桌面会话不跑怒气/思念，但情绪槽照样挂（否则这里永远记不到情绪）
        if (!cfg.emotionOnDesktop) {
          ctx.logger?.info?.(`jieyi-persona: skip non-IM agent (${verdict.why})`)
          logLine(`skip non-IM agent (${verdict.why})`)
          return
        }
        desktopAgents.add(agent)
        logLine(`attached desktop-emotion (${verdict.why})`)
      } else {
        ctx.logger?.info?.(`jieyi-persona: attached to agent (${verdict.why})`)
        logLine(`attached (${verdict.why})`)
      }
      const attachedSessionId = sessionIdOf(agent)
      if (typeof attachedSessionId === 'string' && attachedSessionId !== '') attachedAgents.set(attachedSessionId, agent)
      const agentCtx = agent?.ctx
      if (agentCtx === undefined) return

      const disposers = []
      const track = (d) => {
        if (typeof d === 'function') disposers.push(d)
        return d
      }

      if (cfg.injectEnabled && agentCtx.on) {
        track(agentCtx.on('agent/pre-step', async ({ agent: a, messages, signal, step }, next) => {
          const decision = await next()
          if (decision?.kind === 'reject' || signal?.aborted) return decision
          if (Array.isArray(decision?.messages) && decision.messages.length === 0 && step > 1) return decision

          for (const m of Array.isArray(messages) ? messages : []) {
            const raw = typeof m?.content === 'string' ? m.content : ''
            if (!raw.includes(VERDICT_OPEN)) continue
            const { text, verdict } = stripVerdict(raw)
            if (verdict) {
              const isDesktop = desktopAgents.has(a)
              // 桌面会话只把情绪那一个字段交出去，怒气/思念一律不动
              const routed = isDesktop ? { emo: verdict.emo } : verdict
              if (!isDesktop) for (const ev of verdictToEvents(verdict)) appendEvent(a, ev)
              const done = applyVerdictToScripts(cfg, routed, { emotionOnly: isDesktop })
              if (done.length) ctx.logger?.info?.(`jieyi-persona: linkage -> ${done.join(', ')}`)
            }
            if (text !== raw) m.content = text
          }

          // 每轮开头记一次"用户说了话"：段、轮数、疲惫升格都靠它
          if (step === 1 && cfg.linkage) {
            try {
              const sid = sessionIdOf(a) || 'default'
              const child = spawn(cfg.powershell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(cfg.scriptsDir, 'emotion.ps1'), '-Tick', '-Session', sid], { stdio: 'ignore', windowsHide: true })
              child.on?.('error', () => {})
            } catch { }

            // 开发者口令：/anger-reset 直接清零，聊天里不必再出现那句关键词
            const userText = (Array.isArray(messages) ? messages : [])
              .filter((m) => !m?.meta?.injectedBy)
              .map((m) => (typeof m?.content === 'string' ? m.content : ''))
              .join('\n')
              .trim()
            if (/^\/(anger-reset|reset-anger)\b/i.test(userText)) {
              try {
                const child = spawn(cfg.powershell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(cfg.scriptsDir, 'anger.ps1'), '-Reset'], { stdio: 'ignore', windowsHide: true })
                child.on?.('error', () => {})
                ctx.logger?.info?.('jieyi-persona: /anger-reset -> anger.ps1 -Reset')
              } catch { }
            }

            // 开发者口令：/emotion-mode all|daily 切换情绪槽的适用范围
            const mm = userText.match(/^\/emotion-mode\s+(all|daily)\b/i)
            if (mm) {
              try {
                const target = join(cfg.stateDir, 'emotion-mode.json')
                writeFileSync(target, JSON.stringify({ mode: mm[1].toLowerCase(), at: new Date().toISOString() }), 'utf8')
                ctx.logger?.info?.(`jieyi-persona: /emotion-mode -> ${mm[1].toLowerCase()}`)
              } catch (e) {
                ctx.logger?.warn?.(`jieyi-persona: emotion-mode write failed ${e?.message ?? e}`)
              }
            }

            // 开发者口令：/sentinel-mode library|model
            // library=从话语库挑句（不花钱）；model=每次现写（调模型）
            const sm = userText.match(/^\/sentinel-mode\s+(library|model)\b/i)
            if (sm) {
              try {
                const target = join(cfg.stateDir, 'sentinel-mode.json')
                writeFileSync(target, JSON.stringify({ mode: sm[1].toLowerCase(), at: new Date().toISOString() }), 'utf8')
                ctx.logger?.info?.(`jieyi-persona: /sentinel-mode -> ${sm[1].toLowerCase()}`)
              } catch (e) {
                ctx.logger?.warn?.(`jieyi-persona: sentinel-mode write failed ${e?.message ?? e}`)
              }
            }
          }

          const injectionText = renderInjection({
            ...readState(a),
            external: cfg.linkage ? readExternalState(cfg) : null,
          })
          // 状态便签只在「回合开头」且「内容与上次不同」时重发；没变就沿用历史里那张。
          // 超过 30 分钟也会重发一次，免得历史被压缩后模型再也看不到这张便签。
          if (step !== 1) return decision
          const previousInjection = lastInjection.get(a)
          if (previousInjection !== undefined && previousInjection.text === injectionText
            && Date.now() - previousInjection.at <= 30 * 60_000) return decision
          lastInjection.set(a, { text: injectionText, at: Date.now() })
          logLine(`inject step=${step} chars=${injectionText.length}`)
          const injected = buildInjectedMessage(injectionText)
          if (injected === null) return decision
          const base = Array.isArray(decision.messages) ? decision.messages : []
          return { ...decision, messages: [...base, injected] }
        }))
      }

      if (agentCtx.tools?.guard) track(agentCtx.tools.guard(denyOutbound))

      // 判定行的抹除不在这里：宿主本版 llm/stream 是请求级 waterfall，
      // 只能在插件根 ctx 上包住 chunk 流（见 apply 末尾的注册）。

      agentDisposers.set(agent, () => {
        for (const d of disposers) {
          try {
            d()
          } catch {
            /* 单个失败不影响其余 */
          }
        }
        const sid = sessionIdOf(agent)
        if (typeof sid === 'string') attachedAgents.delete(sid)
        lastInjection.delete(agent)
      })
      if (agentCtx.effect) {
        agentCtx.effect(() => () => {
          agentDisposers.get(agent)?.()
          agentDisposers.delete(agent)
        }, 'jieyi-persona.agentScope()')
      }
    })
  })

  // 判定行的抹除：本版 llm/stream 是请求级 waterfall（参数是请求体，next() 给 chunk 流），
  // 所以挂在插件根 ctx 上、按已挂会话过滤，包住流改写并回填判定。
  ctx.effect?.(() => {
    const off = ctx.on?.('llm/stream', (options, next) => {
      const stream = next()
      const sessionId = typeof options?.sessionId === 'string' ? options.sessionId : null
      const agent = sessionId === null ? undefined : attachedAgents.get(sessionId)
      if (agent === undefined) return stream
      if (stream === undefined || typeof stream?.[Symbol.asyncIterator] !== 'function') return stream
      return filterVerdictStream(stream, (verdict) => {
        if (!verdict) return
        for (const ev of verdictToEvents(verdict)) appendEvent(agent, ev)
        const done = applyVerdictToScripts(cfg, verdict)
        if (done.length) ctx.logger?.info?.(`jieyi-persona: linkage -> ${done.join(", ")}`)
        logLine(`verdict malice=${verdict.malice ?? 0} comfort=${verdict.comfort ?? 0} dialogue=${verdict.completeDialogue ?? 0}`)
      })
    }, { global: true })
    return () => {
      try {
        off?.()
      } catch {
        /* ignore */
      }
    }
  }, 'jieyi-persona.verdict-stream()')

  ctx.effect?.(() => () => {
    for (const [, d] of agentDisposers) {
      try {
        d()
      } catch {
        /* ignore */
      }
    }
    agentDisposers.clear()
    attachedAgents.clear()
    lastInjection.clear()
  }, 'jieyi-persona.dispose()')
}


