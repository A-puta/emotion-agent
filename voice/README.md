# 语音（可选）

情绪与压力测试不依赖这一层；没有 NVIDIA 显卡时，整个项目退化为纯文本，功能完整。

## 它能做什么

- **本地零样本克隆**：给 10–20 秒参考录音和对应文本，就能用那个音色念任意中文句子。
- **人味处理**：句间停顿按标点随机化、插入换气、低频补厚与高频收敛、响度归一。
- **常驻服务**：跑一个本地 HTTP 服务，POST 文本即出音频。

## 现状

本机实测过的方案是 F5-TTS（`F5TTS_v1_Base`），32 步、贴合度 1.6；
参考音频放在 `voice/refs/`，请**只使用本人或已获授权的声音**。

## 最少需要

| 项 | 要求 |
|---|---|
| GPU | 显存 ≥ 6 GB（F5 推理峰值约 1.1 GB，另需模型加载余量） |
| 磁盘 | 模型与虚拟环境约 11 GB |
| Python | 3.10+ |

## 跑起来

```bash
python -m venv venv
venv\Scripts\activate
pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu128
pip install f5-tts soundfile numpy
set HF_HOME=D:\models            # 指到 hub 的上一级
set NUMBA_DISABLE_JIT=1          # Windows 上没有这个会卡住
python voice_server.py           # 默认 127.0.0.1:18080
```

```bash
curl -X POST http://127.0.0.1:18080/say ^
  -H "Content-Type: application/json" ^
  -d "{\"text\":\"今天也辛苦了。\",\"name\":\"关心\"}"
```

返回 `{path, seconds, breaths, elapsed}`，音频落在 `voice/work/`。

## 没有显卡

保持 `voice/` 不动，只跑情绪与控制台即可——演示时把「说一句」换成「发一条文字」。
