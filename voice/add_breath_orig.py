"""在句间停顿里插入换气声：音量与位置可控，频率按说话时长控制。

用法：
  python add_breath_orig.py <输入wav> <输出wav> [音量比 0.10] [平均间隔秒 6.0]

规则：两次换气至少间隔 4 秒；目标约每 6 秒一处；位置抖动 ±0.05 秒。
"""
import os, random, sys
import numpy as np, soundfile as sf

WORK = r"D:\DSH-资料\voice\work"
BREATH = os.path.join(WORK, "refs", "breath.wav")
MIN_GAP_S = 4.0


def main():
    src, dst = sys.argv[1], sys.argv[2]
    lvl = float(sys.argv[3]) if len(sys.argv) > 3 else 0.10
    interval = float(sys.argv[4]) if len(sys.argv) > 4 else 6.0
    rng = random.Random()

    z, sr = sf.read(src)
    if z.ndim > 1:
        z = z.mean(axis=1)
    z = z.astype(np.float32)
    br, bsr = sf.read(BREATH)
    br = br.astype(np.float32)
    if bsr != sr:
        import torch, torchaudio as ta
        br = ta.functional.resample(torch.from_numpy(br)[None], bsr, sr)[0].numpy()

    w = int(0.01 * sr)
    n = len(z) // w
    env = np.array([np.sqrt(np.mean(z[i * w:(i + 1) * w] ** 2)) for i in range(n)])
    thr = max(0.006, float(env.max()) * 0.06)
    v = env > thr
    runs, i = [], 0
    while i < n:
        if v[i]:
            j = i
            while j < n and v[j]:
                j += 1
            runs.append((i * w, j * w))
            i = j
        else:
            i += 1

    speech_rms = float(np.sqrt(np.mean(z ** 2)))
    br_rms = float(np.sqrt(np.mean(br ** 2))) + 1e-9
    dur = len(z) / sr
    target_n = max(1, int(round(dur / interval)))

    cands = []
    for k in range(len(runs) - 1):
        a, b = runs[k][1], runs[k + 1][0]
        if (b - a) / sr >= 0.30:
            cands.append((a, b, (a + b) / 2 / sr))

    chosen, last_t = [], -99.0
    for a, b, t in cands:
        if t - last_t < MIN_GAP_S:
            continue
        if len(chosen) >= target_n:
            break
        if rng.random() < 0.8:
            chosen.append((a, b))
            last_t = t

    pieces, at = [], []
    for a, b in chosen:
        jit = int(rng.uniform(-0.05, 0.05) * sr)
        end = b - int(0.04 * sr)
        off = max(a, min(b - len(br), end - len(br) + jit))
        bseg = (br * (lvl * speech_rms / br_rms)).astype(np.float32)
        pieces.append((off, bseg))
        at.append(round(off / sr, 2))

    out = z.copy()
    for off, bseg in sorted(pieces, reverse=True):
        out = np.concatenate([out[:off], bseg, out[off:]])

    pk = float(np.max(np.abs(out)))
    if pk > 0.95:
        out = out * (0.95 / pk)
    sf.write(dst, out.astype(np.float32), sr)
    print(f"breaths at {at}  (目标 {target_n} 处 / {dur:.1f}s) -> {len(out)/sr:.2f}s", flush=True)


if __name__ == "__main__":
    main()
