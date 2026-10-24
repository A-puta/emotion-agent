# 接自己的 IM 通道

控制台默认**只把主动说的话显示在自己页面里**（`type = console`），零配置就能跑。
想把话送到你自己的聊天软件，在 `app/delivery.json` 里改一行 `type` 即可。

```jsonc
// 默认：只进控制台对话
{ "type": "console" }
```

---

## 支持四种通道

### 1. `console`（默认，零配置）

只显示在控制台对话里。适合演示、也适合只是本地自用的人。

### 2. `onebot`（QQ 机器人框架：NapCat / Lagrange / go-cqhttp）

```json
{
  "type": "onebot",
  "endpoint": "http://127.0.0.1:3000/send_private_msg",
  "token": "你在框架里设的 access_token",
  "targetId": "你的QQ号"
}
```

发的是 OneBot v11 的 `send_private_msg`。群聊把 action 换成 `send_group_msg`、`targetId` 换成群号（需要的话改 `app/delivery.mjs` 两行）。

### 3. `dsh-im`（本机跑着 DSH 时）

```json
{
  "type": "dsh-im",
  "endpoint": "http://127.0.0.1:19387/api/dsh-im/delivery/messages",
  "botId": "你的 botId",
  "targetId": "你的 targetId"
}
```

`botId` / `targetId` 来自 DSH 的 IM 配置。**这是本机私有值，不要提交到仓库。**

### 4. `http`（任意 webhook / 自己的服务）

```json
{
  "type": "http",
  "endpoint": "https://你的服务/hook",
  "token": "可选"
}
```

POST `{"text": "..."}`，够接任何简单网关。

---

## 没配会怎样

- 主动说的话照样出现在控制台对话里
- 只是不会往外部发
- 控制台会如实显示投递结果（成功 `sent:true`，失败给出 HTTP 状态码和原因）

---

## 注意

- `app/delivery.json` 已加入 `.gitignore`，包含 token 也不要紧，但**别手工贴进 README 或 issue**。
- 哨兵脚本自己也有一份投递配置（`scripts/config.json` 的 `delivery`），它管的是「计划任务那条路径」；控制台走的是 `app/delivery.json`。两边可以只启用一边。
