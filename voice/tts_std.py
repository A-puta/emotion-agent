"""结衣语音合成：只在句号／问号／叹号／分号／冒号处切段并留间隔。

用法：
  python tts_std.py "文本" 名字 [--ref 尾端]

切段规则：只在 。！？；： 处断开，逗号与段内节奏交给模型自己；
间隔在区间内随机（句末 0.40–0.72 秒，分号／冒号 0.24–0.42 秒），
再按前一句字数最多加三成；结尾补 0.9 秒静音。
"""
import os, random, sys, warnings
import numpy as np, soundfile as sf, torch
import torchaudio as _ta

warnings.filterwarnings("ignore")


def _load(path, **kw):
    d, sr = sf.read(path, always_2d=True)
    return torch.from_numpy(d.T).float(), sr


_ta.load = _load
from f5_tts.api import F5TTS

WORK = r"D:\DSH-资料\voice\work"
REFD = os.path.join(WORK, "refs")
DESK = os.path.join(os.path.expanduser("~"), "Desktop", "DSH传输")

REFS = {
    "尾端": (os.path.join(REFD, "ref_endsample.wav"), "然后到现在，随口念出来。"),
    "中性": (os.path.join(WORK, "ref_zh_live.wav"),
             "是的，好想我呵呵。确实快一个星期没见，也没有一个星期吧，周二不是才见过，诶，也不算实际上的见。"),
    "淘气": (os.path.join(REFD, "ref_emo_taoqi.wav"),
             "屁是什么东西，屁是人类正常的生理现象，大家不要感到羞耻，哼，打嗝也是一种正常的生理现象"),
    "开心": (os.path.join(REFD, "ref_emo_kaixin_nowav.wav"),
             "几个月之后吧，我还能怎么漏呢，我还能怎么漏宝宝们，你要是说一个月的话，具体日期我也不知道哇"),
    "开心2": (os.path.join(REFD, "ref_emo_kaixin2.wav"),
              "呃哈哈，欸，我看了我看啦，哈哈happy，我看了我看了我看了，呃，呃"),
    "呵斥": (os.path.join(REFD, "ref_emo_hechi.wav"),
             "少骗我，明明是恐怖游戏好吧，听说恐怖程度在生化危机之上，你们真当我玩生化危机不怕是吗"),
}

RANGES = {
    "。": (0.40, 0.72), "！": (0.40, 0.72), "？": (0.40, 0.72),
    "；": (0.24, 0.42), "：": (0.24, 0.42),
}
TAIL = 0.9
STEPS, CFG = 32, 1.6
rng = random.Random()


def trim_edges(y, sr, head=0.03, tail=0.09):
    w = int(0.01 * sr)
    n = len(y) // w
    env = np.array([np.sqrt(np.mean(y[i * w:(i + 1) * w] ** 2)) for i in range(n)])
    thr = max(0.006, float(env.max()) * 0.05)
    v = np.where(env > thr)[0]
    if len(v) == 0:
        return y
    a = max(0, int(v[0] * w) - int(head * sr))
    b = min(len(y), int((v[-1] + 1) * w) + int(tail * sr))
    return y[a:b]


def split_text(text):
    segs, buf = [], ""
    for ch in text:
        buf += ch
        if ch in RANGES:
            segs.append(buf.strip())
            buf = ""
    if buf.strip():
        segs.append(buf.strip())
    out = []
    for s in segs:
        if not s:
            continue
        mark = s[-1] if s[-1] in RANGES else "。"
        body = s[:-1] if s[-1] in RANGES else s
        if body.strip():
            out.append((body.strip(), mark))
    return out


def gap_for(mark, prev_chars):
    lo, hi = RANGES.get(mark, (0.30, 0.60))
    extra = min(0.30, max(0.0, (prev_chars - 12) / 70))
    return rng.uniform(lo, hi) * (1 + extra)


def main():
    text, name = sys.argv[1], sys.argv[2]
    ref_key = "尾端"
    if "--ref" in sys.argv:
        ref_key = sys.argv[sys.argv.index("--ref") + 1]
    speed = 1.0
    if "--speed" in sys.argv:
        speed = float(sys.argv[sys.argv.index("--speed") + 1])
    ref, ref_text = REFS[ref_key]

    segs = split_text(text)
    print("片段", len(segs), [len(s[0]) for s in segs], flush=True)

    f5 = F5TTS(model="F5TTS_v1_Base", device="cuda")
    pieces, sr = [], 24000
    for body, mark in segs:
        wav, sr, _ = f5.infer(ref_file=ref, ref_text=ref_text, gen_text=body + mark,
                              nfe_step=STEPS, cfg_strength=CFG, sway_sampling_coef=-1.0,
                              speed=speed, cross_fade_duration=0.15, remove_silence=False)
        pieces.append((trim_edges(np.asarray(wav, dtype=np.float32), sr), mark, len(body)))
        print("段", len(body), "字", flush=True)

    z = pieces[0][0]
    for (p, _, _), (_, mark, prev_chars) in zip(pieces[1:], pieces[:-1]):
        g = gap_for(mark, prev_chars)
        print("gap", mark, round(g, 3), flush=True)
        z = np.concatenate([z, np.zeros(int(g * sr), dtype=np.float32), p])

    z = np.concatenate([z, np.zeros(int(TAIL * sr), dtype=np.float32)])
    z = (z * (0.9 / float(np.max(np.abs(z))))).astype(np.float32)
    for p in [os.path.join(WORK, f"{name}.wav"), os.path.join(DESK, f"{name}.wav")]:
        sf.write(p, z, sr)
    print("written", round(len(z) / sr, 2), "s", flush=True)


if __name__ == "__main__":
    main()
