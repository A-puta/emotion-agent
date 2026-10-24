# 结衣 · 会记事的人格式代理

一个跑在本机的「人格化聊天代理」：它会因为你说的话改变情绪，会记得上一句话的气还没消，
在你不说话的时候自己找上门来，也能用你指定的音色开口说话。

不是提示词套壳——情绪、怒气、思念、疲惫都是**有状态、会过期、会互相挤占**的，
状态存在本地文件里，插件只负责读写，模型不另记一套账。

---

## 一、它有什么

**七格情绪，会自己退场**
生气／开心／难过／淘气／委屈／疲惫／害羞。同一类叠加会加重，不同类会杂糅成别的情绪
（生气＋淘气＝佯怒，害羞＋淘气＝佯羞）。重情绪留 25 分钟、轻的留 10 分钟，
**从这一段对话结束才开始计时**——聊着的时候不倒数。

**疲惫是硬状态**
同一段里聊满 50 句、平均每 2 分钟一句 → 疲惫一格，句子自动裁短；
满 100 句 → 两格，视为这段对话已结束，只回一句「我很累」，不接活。每 30 分钟自己降一格。

**怒气有等级，也有代价**
从 -1 起算、上限 2；被反复索取、被怼、被骂各有不同的上升路径；
30 分钟内两次到顶就锁死，锁死期间安慰无效、活一律不接。
只有开发者口令 `/anger-reset` 能强制清零。

**思念 C/B/A 三档**
沉默越久越往上走，B 档约六成会开口、A 档每小时一条。
写得很克制：不催、不道歉、不提问。

**不花钱的主动搭话**
内置 129 条日常话语库，按时间、前台程序、天气、沉默时长、每日上限自动挑选，
**一次模型都不调**，所以不产生任何 API 费用；想让它每次现写，一条口令切回去。

**克隆音色说话（可选）**
本地零样本语音克隆，参考音任何一段十几秒的录音就能用；
带句间停顿、换气、柔和处理，输出自动落到桌面。

---

## 二、它是怎么跑起来的

```
用户消息
   │
   ├─ 插件（plugin/）── 读出状态 → 拼进提示词 → 模型回话 → 解析判定行
   │                                              │
   │                                              ▼
   │                                   scripts/ 里的 PS 脚本改状态文件
   │                                              │
   └─ 计划任务（每 5 分钟）────────────── 扫过期、降疲惫
                                                  │
空档期（每 20 分钟）── 哨兵决定要不要主动开口 ─────┘
                          ├─ 库模式：挑一句（0 调用）
                          └─ 模型模式：现写一句
```

- **状态是真源**：`anger.json`、`missing.json`、`emotion.json`、`emotion-mode.json`、`sentinel-mode.json`
- **脚本是唯一写方**：聊天侧只读，判定交回脚本执行，避免两本账
- **插件不存状态**：它只做「读 → 注入 → 转发」

---

## 三、跑起来

### 0. 需要什么

- Windows 10/11
- PowerShell 5.1（系统自带）
- 可选：Node ≥ 22（跑控制台）、Python 3.10+ 与一块 NVIDIA 显卡（跑语音）

### 1. 放置文件

把仓库放到任意目录，建议 `D:\jieyi-agent`，并在 `scripts/config.json` 里把
`stateDir` / `scriptsDir` 指到你自己的路径。

### 2. 建状态目录

```powershell
New-Item -ItemType Directory -Force -Path 'D:\DSH-资料\结衣状态'
Copy-Item .\scripts\emotion.json            'D:\DSH-资料\结衣状态\emotion.json'
Copy-Item .\scripts\emotion-mode.json       'D:\DSH-资料\结衣状态\emotion-mode.json'
Copy-Item .\scripts\sentinel-mode.json      'D:\DSH-资料\结衣状态\sentinel-mode.json' -ErrorAction SilentlyContinue
Copy-Item .\scripts\state.json              'D:\DSH-资料\结衣状态\state.json'
```

### 3. 注册两个定时任务

```powershell
# 情绪过期与疲惫恢复（每 5 分钟）
$a = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument '"<仓库>\scripts\run_emotion_hidden.vbs"'
$t = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName '结衣情绪到期' -Action $a -Trigger $t -Force
```

```powershell
# 主动搭话（每 20 分钟；先跑 -DryRun 确认不会乱发）
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "<仓库>\scripts\外部哨兵脚本.ps1"'
$t = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 20)
Register-ScheduledTask -TaskName '外部哨兵脚本' -Action $a -Trigger $t -Force
```

### 4. 装上插件

把 `plugin/` 放进 DSH 的 `profiles/<profile>/node_modules/dsh-jieyi-persona/`，
重启 DSH——插件首次启动会自动补齐缺失的脚本与状态模板（`ensureAssets`）。

### 5. 打开控制台（可选但推荐）

```powershell
node app/server.mjs        # 默认 http://127.0.0.1:18100
```

面板上能看四个状态、切两个模式、手动触发一句、听一段语音。

### 6. 跑语音（可选）

见 `voice/README.md`；没有显卡会自动降级成纯文本，不影响情绪部分。

---

## 四、示例：一次完整的来回

```
你：你最近好像变聪明了
它：（害羞进槽，语气变软）……你忽然这么讲，我一时间都不知道该把脸往哪放了。

你：不要骄傲哦，一直这样也会越来越笨哟
它：（淘气叠加 → 佯羞）哼，才夸一句就开始下套。

（你十几分钟没说话）
哨兵：从 129 条里挑一条 ——「晴。你要是出门，记得看路。」（本次调用 0 次模型）
```

---

## 五、指令

| 指令 | 作用 |
|---|---|
| `/anger-reset` | 怒气清零、解除锁死 |
| `/emotion-mode daily` \| `all` | 情绪槽只作用于日常对话，还是所有对话 |
| `/sentinel-mode library` \| `model` | 主动搭话从库里挑（不花钱），还是让模型现写 |

---

## 六、边界

- 情绪只改说话方式，**不改事实、能力边界与安全约束**；紧急求助永远正常回答。
- 话语库是模板，句子会重复；要「每次不同」就得走模型模式，也就开始花钱。
- 语音克隆**只做本人或已授权的声音**。
- 这是本机应用，不上传聊天内容；主动搭话只用「时间／沉默时长／天气／前台程序分类」这几个信号。

---

## 七、目录

```
app/      本地控制台（状态面板 / 模式切换 / 手动触发）
plugin/   DSH 插件（读状态、注入提示词、转发判定、自动补齐脚本）
scripts/  情绪、怒气、思念、哨兵、话语库挑选器、状态模板
voice/    本地零样本语音克隆（可选）
docs/     条件说明、演示脚本、约定总表
```

---

## 八、许可

MIT。人格设定与话语库内容属于本项目作者，可自行改写。
