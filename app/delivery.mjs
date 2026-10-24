// 投递适配器：把一句话送到"人能看到"的地方
// 默认只送进控制台对话；想接自己的 IM，就在 app/delivery.json 里改 type
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const readJson = (p) => {
  try {
    return JSON.parse(readFileSync(p, 'utf8').replace(/^\uFEFF/, ''))
  } catch {
    return null
  }
}

/**
 * type = console  ：只进控制台对话（默认，零配置）
 * type = http     ：POST {text} 到任意地址（自家机器人网关、webhook）
 * type = onebot   ：POST OneBot v11 的 send_private_msg（NapCat / go-cqhttp 等）
 * type = dsh-im   ：POST DSH 的投递接口（{botId,targetId,text}）
 */
export async function deliver(root, text) {
  const cfg = readJson(join(root, 'app', 'delivery.json')) || {}
  const type = String(cfg.type || 'console')
  if (type === 'console') return { ok: true, type, note: '只显示在控制台' }
  if (!cfg.endpoint) return { ok: false, type, error: '没有配置 endpoint' }

  try {
    if (type === 'onebot') {
      const body = {
        action: 'send_private_msg',
        params: { user_id: cfg.targetId, message: text },
        echo: `jieyi-${Date.now()}`,
      }
      const headers = { 'Content-Type': 'application/json' }
      if (cfg.token) headers.Authorization = `Bearer ${cfg.token}`
      const res = await fetch(cfg.endpoint, { method: 'POST', headers, body: JSON.stringify(body) })
      const t = await res.text()
      return res.ok ? { ok: true, type, response: t.slice(0, 200) } : { ok: false, type, error: `HTTP ${res.status}: ${t.slice(0, 200)}` }
    }

    if (type === 'dsh-im') {
      const body = { botId: cfg.botId, targetId: cfg.targetId, text }
      const res = await fetch(cfg.endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=utf-8' },
        body: JSON.stringify(body),
      })
      const t = await res.text()
      return res.ok ? { ok: true, type, response: t.slice(0, 200) } : { ok: false, type, error: `HTTP ${res.status}: ${t.slice(0, 200)}` }
    }

    // 通用 http webhook
    const headers = { 'Content-Type': 'application/json; charset=utf-8' }
    if (cfg.token) headers.Authorization = `Bearer ${cfg.token}`
    const res = await fetch(cfg.endpoint, { method: 'POST', headers, body: JSON.stringify({ text }) })
    const t = await res.text()
    return res.ok ? { ok: true, type, response: t.slice(0, 200) } : { ok: false, type, error: `HTTP ${res.status}: ${t.slice(0, 200)}` }
  } catch (e) {
    return { ok: false, type, error: String(e.message || e) }
  }
}
