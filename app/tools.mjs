// 工具定义与执行 · 供控制台的 Agent 循环使用
// 只暴露白名单动作：不执行任意命令、不写任意文件
import { spawn } from 'node:child_process'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const PS = 'powershell.exe'

const runPsFile = (scripts, script, args = []) =>
  new Promise((resolve) => {
    const child = spawn(PS, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(scripts, script), ...args], {
      windowsHide: true,
    })
    let out = ''
    child.stdout.on('data', (d) => (out += d.toString()))
    child.stderr.on('data', (d) => (out += d.toString()))
    child.on('close', () => resolve(out.trim()))
    child.on('error', (e) => resolve('ERR ' + e.message))
  })

const runPsCmd = (cmd) =>
  new Promise((resolve) => {
    const child = spawn(PS, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', cmd], { windowsHide: true })
    let out = ''
    child.stdout.on('data', (d) => (out += d.toString()))
    child.stderr.on('data', (d) => (out += d.toString()))
    child.on('close', () => resolve(out.trim()))
    child.on('error', (e) => resolve('ERR ' + e.message))
  })

// 启动方式：能查到 AUMID 的走 shell:AppsFolder，其余走绝对路径或 PATH
const APP_LAUNCH = {
  qq: { aumid: 'QQ', proc: 'QQ' },
  wechat: { exe: 'C:\\Program Files\\Tencent\\Weixin\\Weixin.exe', proc: 'Weixin' },
  edge: { exe: 'msedge.exe', proc: 'msedge' },
  notepad: { exe: 'notepad.exe', proc: 'Notepad' },
  explorer: { exe: 'explorer.exe', proc: 'explorer' },
  calc: { exe: 'calc.exe', proc: 'CalculatorApp' },
  vscode: { exe: 'Code.exe', proc: 'Code' },
}

const APP_MAP = {
  qq: 'qq.exe',
  wechat: 'WeChat.exe',
  edge: 'msedge.exe',
  notepad: 'notepad.exe',
  explorer: 'explorer.exe',
  calc: 'calc.exe',
  vscode: 'Code.exe',
}

export const TOOL_SPECS = [
  {
    type: 'function',
    function: {
      name: 'get_state',
      description: '读取当前情绪槽、怒气、思念、模式等状态',
      parameters: { type: 'object', properties: {}, required: [] },
    },
  },
  {
    type: 'function',
    function: {
      name: 'set_emotion',
      description: '往情绪槽里加一格情绪（会按挤占规则生效）',
      parameters: {
        type: 'object',
        properties: { label: { type: 'string', enum: ['生气', '开心', '难过', '淘气', '委屈', '疲惫', '害羞'] } },
        required: ['label'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'pick_line',
      description: '从日常话语库里挑一句（不花钱），可按当前场景筛',
      parameters: {
        type: 'object',
        properties: { foreground: { type: 'string', enum: ['work', 'game', 'other'] } },
        required: [],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'run_sentinel',
      description: '试跑一次主动搭话的判定，默认不真的发送',
      parameters: {
        type: 'object',
        properties: { for_real: { type: 'boolean', description: 'true 时才真的发出去' } },
        required: [],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'open_app',
      description: '打开本机上的一个常用程序（白名单）',
      parameters: {
        type: 'object',
        properties: { app: { type: 'string', enum: Object.keys(APP_MAP) } },
        required: ['app'],
      },
    },
  },
  {
    type: 'function',
    function: {
      name: 'list_tasks',
      description: '查看两个定时任务是否在运行',
      parameters: { type: 'object', properties: {}, required: [] },
    },
  },
]

export async function runTool(name, args, { scripts, state, mode }) {
  const needFull = ['run_sentinel', 'open_app', 'list_tasks']
  if (needFull.includes(name) && mode !== 'full') {
    return { error: '这几个动作需要「完全权限」，先把标题栏开关拨过去' }
  }
  const readJson = (f) => {
    try {
      return JSON.parse(readFileSync(join(state, f), 'utf8').replace(/^\uFEFF/, ''))
    } catch {
      return null
    }
  }
  switch (name) {
    case 'get_state': {
      const emo = readJson('emotion.json')
      const anger = readJson('anger.json')
      const missing = readJson('missing.json')
      return {
        slots: (emo?.slots || []).map((s) => s.label),
        fatigue: emo?.fatigue ?? 0,
        locked: Boolean(emo?.lock),
        anger: anger?.anger ?? -1,
        missing: missing?.level ?? 'C',
        rounds: emo?.seg?.count ?? 0,
      }
    }
    case 'set_emotion': {
      const out = await runPsFile(scripts, 'emotion.ps1', ['-Set', String(args?.label || ''), '-Session', 'console'])
      return { ok: true, out, slots: (readJson('emotion.json')?.slots || []).map((s) => s.label) }
    }
    case 'pick_line': {
      const a = ['-Show']
      if (args?.foreground) a.push('-Foreground', String(args.foreground))
      return { line: await runPsFile(scripts, 'pick_phrase.ps1', a) }
    }
    case 'run_sentinel': {
      const real = args?.for_real === true
      const out = await runPsFile(scripts, '外部哨兵脚本.ps1', real ? ['-Force'] : ['-DryRun', '-Force'])
      return { real, out: out.slice(-800) }
    }
    case 'open_app': {
      const key = String(args?.app || '').toLowerCase()
      const spec = APP_LAUNCH[key]
      if (!spec) return { error: '不在白名单里' }
      const target = spec.aumid ? `shell:AppsFolder\\${spec.aumid}` : spec.exe
      const cmd = `[Console]::OutputEncoding=[Text.Encoding]::UTF8; try { Start-Process '${target}' -ErrorAction Stop; 'launched' } catch { 'ERR ' + $_.Exception.Message }`
      const out = await runPsCmd(cmd)
      await new Promise((r) => setTimeout(r, 2500))
      const check = await runPsCmd(`[Console]::OutputEncoding=[Text.Encoding]::UTF8; $p = Get-Process -Name '${spec.proc}' -ErrorAction SilentlyContinue; if ($p) { 'RUNNING ' + @($p).Count } else { 'NOT-RUNNING' }`)
      const running = check.includes('RUNNING') && !check.includes('NOT-RUNNING')
      return {
        ok: running,
        launched: out.trim(),
        process: check.trim(),
        note: running ? `${key} 已经在运行` : `${key} 没有起来，可能是安装路径不同或需要手动授权`,
      }
    }
    case 'list_tasks': {
      const out = await runPsCmd("[Console]::OutputEncoding=[Text.Encoding]::UTF8; Get-ScheduledTask -TaskName '外部哨兵脚本','结衣情绪到期' -ErrorAction SilentlyContinue | ForEach-Object { $_.TaskName + ' · ' + $_.State }")
      return { tasks: out }
    }
    default:
      return { error: '未知工具' }
  }
}
