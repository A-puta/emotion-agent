"""一站式渲染：生成 → 柔和链 → 换气 → 交付。全部在一个进程里完成，压缩改成向量化。

用法：
  python render.py "文本" 名字 [--ref 尾端] [--speed 1.0]
"""
import os, random, subprocess, sys, time, warnings

import numpy as np, soundfile as sf, torch
import torchaudio as _ta
from scipy import signal as ss

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
RANGES = {"。": (0.40, 0.72), "！": (0.40, 0.72), "？": (0.40, 0.72),
          "；": (0.24, 0.42), "：": (0.24, 0.42)}
TAIL, STEPS, CFG = 0.9, 32, 1.6
BREATH = os.path.join(REFD, "breath.wav")


# ---------- EQ ----------
def lowshelf(sr, fc, g, q=0.707):
    A = 10 ** (g / 40); w0 = 2 * np.pi * fc / sr
    al = np.sin(w0) / (2 * q); c = np.cos(w0)
    b0 = A * ((A + 1) - (A - 1) * c + 2 * np.sqrt(A) * al)
    b1 = 2 * A * ((A - 1) - (A + 1) * c)
    b2 = A * ((A + 1) - (A - 1) * c - 2 * np.sqrt(A) * al)
    a0 = (A + 1) + (A - 1) * c + 2 * np.sqrt(A) * al
    a1 = -2 * ((A - 1) + (A + 1) * c)
    a2 = (A + 1) + (A - 1) * c - 2 * np.sqrt(A) * al
    return [b0 / a0, b1 / a0, b2 / a0], [1, a1 / a0, a2 / a0]


def highshelf(sr, fc, g, q=0.707):
    A = 10 ** (g / 40); w0 = 2 * np.pi * fc / sr
    al = np.sin(w0) / (2 * q); c = np.cos(w0)
    b0 = A * ((A + 1) + (A - 1) * c + 2 * np.sqrt(A) * al)
    b1 = -2 * A * ((A - 1) + (A + 1) * c)
    b2 = A * ((A + 1) + (A - 1) * c - 2 * np.sqrt(A) * al)
    a0 = (A + 1) - (A - 1) * c + 2 * np.sqrt(A) * al
    a1 = 2 * ((A - 1) - (A + 1) * c)
    a2 = (A + 1) - (A - 1) * c - 2 * np.sqrt(A) * al
    return [b0 / a0, b1 / a0, b2 / a0], [1, a1 / a0, a2 / a0]


def peak(sr, fc, g, q=1.0):
    A = 10 ** (g / 40); w0 = 2 * np.pi * fc / sr
    al = np.sin(w0) / (2 * q); c = np.cos(w0)
    b0 = 1 + al * A; b1 = -2 * c; b2 = 1 - al * A
    a0 = 1 + al / A; a1 = -2 * c; a2 = 1 - al / A
    return [b0 / a0, b1 / a0, b2 / a0], [1, a1 / a0, a2 / a0]


def soft_compress(y, sr, s, thr0=-20.0, ratio0=3.0):
    """向量化压缩（包络用 scipy 的指数平滑近似）"""
    att = np.exp(-1.0 / (0.005 * sr))
    rel = np.exp(-1.0 / (0.12 * sr))
    a = np.abs(y).astype(np.float32)
    env = ss.lfilter([1 - att], [1, -att], a)
    env = np.maximum(env, ss.lfilter([1 - rel], [1, -rel], a))
    thr = 10 ** ((thr0 - 6 * (s - 1)) / 20)
    ratio = ratio0 + 2.0 * (s - 1)
    g = np.ones_like(env)
    over = env > thr
    g[over] = (thr / env[over]) ** (1 - 1 / ratio)
    return (y * g).astype(np.float32)


def humanize(y, sr, s_old=1.8, s_soft=3.0):
    chain = [
        lowshelf(sr, 130, 4.0 * s_old, 0.7),
        peak(sr, 520, -6.5 * s_old, 0.8),
        peak(sr, 1100, -2.5 * s_old, 1.2),
        peak(sr, 3200, -3.5 * s_old, 0.8),
        highshelf(sr, 4500, -4.0 * s_old, 0.7),
        peak(sr, 2000, -2.0 * s_soft, 1.0),
        peak(sr, 3200, -2.5 * s_soft, 0.9),
        highshelf(sr, 5000, -3.0 * s_soft, 0.7),
        peak(sr, 2600, -2.0, 0.9),
        highshelf(sr, 3800, -3.5, 0.7),
    ]
    y = soft_compress(y, sr, s_old)
    for b, a in chain:
        y = ss.lfilter(b, a, y).astype(np.float32)
    rms_in = float(np.sqrt(np.mean(y ** 2))) + 1e-9
    y = y * (0.134 / rms_in)
    pk = float(np.max(np.abs(y)))
    if pk > 0.95:
        y = y * (0.95 / pk)
    return y.astype(np.float32)


# ---------- 换气 ----------
def add_breath(z, sr, lvl=0.05, interval=6.0, min_gap=4.0):
    br, bsr = sf.read(BREATH)
    br = br.astype(np.float32)
    if bsr != sr:
        br = _ta.functional.resample(torch.from_numpy(br)[None], bsr, sr)[0].numpy()
    w = int(0.01 * sr); n = len(z) // w
    env = np.sqrt(ss.lfilter(np.ones(w) / w, [1], z ** 2))[::w]
    thr = max(0.006, float(env.max()) * 0.06)
    v = env > thr
    runs, i = [], 0
    while i < len(v):
        if v[i]:
            j = i
            while j < len(v) and v[j]:
                j += 1
            runs.append((i * w, j * w)); i = j
        else:
            i += 1
    speech_rms = float(np.sqrt(np.mean(z ** 2)))
    br_rms = float(np.sqrt(np.mean(br ** 2))) + 1e-9
    target = max(1, int(round(len(z) / sr / interval)))
    rng = random.Random()
    pieces, at, last = [], [], -99.0
    for k in range(len(runs) - 1):
        a, b = runs[k][1], runs[k + 1][0]
        if (b - a) / sr < 0.30:
            continue
        t = (a + b) / 2 / sr
        if t - last < min_gap or len(pieces) >= target:
            continue
        if rng.random() < 0.8:
            jit = int(rng.uniform(-0.05, 0.05) * sr)
            end = b - int(0.04 * sr)
            off = max(a, min(b - len(br), end - len(br) + jit))
            pieces.append((off, (br * (lvl * speech_rms / br_rms)).astype(np.float32)))
            at.append(round(off / sr, 2)); last = t
    for off, seg in sorted(pieces, reverse=True):
        z = np.concatenate([z[:off], seg, z[off:]])
    return z, at


def split_text(text):
    segs, buf = [], ""
    for ch in text:
        buf += ch
        if ch in RANGES:
            segs.append(buf.strip()); buf = ""
    if buf.strip():
        segs.append(buf.strip())
    out = []
    for s in segs:
        mark = s[-1] if s[-1] in RANGES else "。"
        body = s[:-1] if s[-1] in RANGES else s
        if body.strip():
            out.append((body.strip(), mark))
    return out


def trim_edges(y, sr, head=0.03, tail=0.09):
    w = int(0.01 * sr); n = len(y) // w
    env = np.array([np.sqrt(np.mean(y[i * w:(i + 1) * w] ** 2)) for i in range(n)])
    thr = max(0.006, float(env.max()) * 0.05)
    v = np.where(env > thr)[0]
    if len(v) == 0:
        return y
    a = max(0, int(v[0] * w) - int(head * sr))
    b = min(len(y), int((v[-1] + 1) * w) + int(tail * sr))
    return y[a:b]


F5 = None


def get_model():
    """常驻用：只加载一次"""
    global F5
    if F5 is None:
        F5 = F5TTS(model="F5TTS_v1_Base", device="cuda")
    return F5


def render(text, name, ref_key="尾端", speed=1.0, f5=None):
    """渲染一条文本，返回 (work路径, 桌面路径, 时长, 换气位置)"""
    t0 = time.time()
    ref, ref_text = REFS[ref_key]
    segs = split_text(text)
    rng = random.Random()

    f5 = f5 or get_model()
    pieces, sr = [], 24000
    for body, mark in segs:
        wav, sr, _ = f5.infer(ref_file=ref, ref_text=ref_text, gen_text=body + mark,
                              nfe_step=STEPS, cfg_strength=CFG, sway_sampling_coef=-1.0,
                              speed=speed, cross_fade_duration=0.15, remove_silence=False)
        pieces.append((trim_edges(np.asarray(wav, dtype=np.float32), sr), mark, len(body)))

    z = pieces[0][0]
    for (p, _, _), (_, mark, prev) in zip(pieces[1:], pieces[:-1]):
        lo, hi = RANGES.get(mark, (0.30, 0.60))
        g = rng.uniform(lo, hi) * (1 + min(0.30, max(0.0, (prev - 12) / 70)))
        z = np.concatenate([z, np.zeros(int(g * sr), dtype=np.float32), p])
    z = np.concatenate([z, np.zeros(int(TAIL * sr), dtype=np.float32)])

    z = humanize(z, sr)
    z, at = add_breath(z, sr)
    pk = float(np.max(np.abs(z)))
    if pk > 0.95:
        z = z * (0.95 / pk)

    w_path = os.path.join(WORK, f"{name}.wav")
    d_path = os.path.join(DESK, f"{name}.wav")
    for p in (w_path, d_path):
        sf.write(p, z.astype(np.float32), sr)
    return w_path, d_path, round(len(z) / sr, 2), at, round(time.time() - t0, 1)


def main():
    text, name = sys.argv[1], sys.argv[2]
    ref_key = "尾端"
    if "--ref" in sys.argv:
        ref_key = sys.argv[sys.argv.index("--ref") + 1]
    speed = 1.0
    if "--speed" in sys.argv:
        speed = float(sys.argv[sys.argv.index("--speed") + 1])

    t0 = time.time()
    get_model()
    print("load", round(time.time() - t0, 1), flush=True)
    w, d, dur, at, el = render(text, name, ref_key, speed)
    print(f"done {dur}s  breaths {at}  用时 {el}s -> {d}", flush=True)
    open_in_player(d)


def open_in_player(path):
    """用新版媒体播放器播（绕过系统默认程序）"""
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "open_media_player.ps1")
    try:
        subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                        "-File", script, path], capture_output=True, timeout=30)
    except Exception as e:
        print("open failed:", e, flush=True)




if __name__ == "__main__":
    main()

