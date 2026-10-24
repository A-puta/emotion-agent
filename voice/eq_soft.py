"""把合成音频往「耳边轻语」调：压中频与高频，补一点厚度，可选加大音量。

用法：
  python eq_soft.py <输入wav> <输出wav> [柔和度 1.0] [音量提升dB 0]

柔和度越大越闷越软；音量提升做在最后，削波前限幅。
"""
import sys
import numpy as np, soundfile as sf
from scipy import signal as ss


def rbj_lowshelf(sr, fc, gain_db, q=0.707):
    A = 10 ** (gain_db / 40)
    w0 = 2 * np.pi * fc / sr
    alpha = np.sin(w0) / (2 * q)
    c = np.cos(w0)
    b0 = A * ((A + 1) - (A - 1) * c + 2 * np.sqrt(A) * alpha)
    b1 = 2 * A * ((A - 1) - (A + 1) * c)
    b2 = A * ((A + 1) - (A - 1) * c - 2 * np.sqrt(A) * alpha)
    a0 = (A + 1) + (A - 1) * c + 2 * np.sqrt(A) * alpha
    a1 = -2 * ((A - 1) + (A + 1) * c)
    a2 = (A + 1) + (A - 1) * c - 2 * np.sqrt(A) * alpha
    return [b0 / a0, b1 / a0, b2 / a0], [1, a1 / a0, a2 / a0]


def rbj_highshelf(sr, fc, gain_db, q=0.707):
    A = 10 ** (gain_db / 40)
    w0 = 2 * np.pi * fc / sr
    alpha = np.sin(w0) / (2 * q)
    c = np.cos(w0)
    b0 = A * ((A + 1) + (A - 1) * c + 2 * np.sqrt(A) * alpha)
    b1 = -2 * A * ((A - 1) + (A + 1) * c)
    b2 = A * ((A + 1) + (A - 1) * c - 2 * np.sqrt(A) * alpha)
    a0 = (A + 1) - (A - 1) * c + 2 * np.sqrt(A) * alpha
    a1 = 2 * ((A - 1) - (A + 1) * c)
    a2 = (A + 1) - (A - 1) * c - 2 * np.sqrt(A) * alpha
    return [b0 / a0, b1 / a0, b2 / a0], [1, a1 / a0, a2 / a0]


def rbj_peak(sr, fc, gain_db, q=1.0):
    A = 10 ** (gain_db / 40)
    w0 = 2 * np.pi * fc / sr
    alpha = np.sin(w0) / (2 * q)
    c = np.cos(w0)
    b0 = 1 + alpha * A
    b1 = -2 * c
    b2 = 1 - alpha * A
    a0 = 1 + alpha / A
    a1 = -2 * c
    a2 = 1 - alpha / A
    return [b0 / a0, b1 / a0, b2 / a0], [1, a1 / a0, a2 / a0]


def main():
    src, dst = sys.argv[1], sys.argv[2]
    s = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
    boost_db = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0

    y, sr = sf.read(src)
    if y.ndim > 1:
        y = y.mean(axis=1)
    y = y.astype(np.float32)

    chain = [
        rbj_lowshelf(sr, 150, 1.5 * s, 0.7),
        rbj_peak(sr, 520, -5.0 * s, 0.8),
        rbj_peak(sr, 1100, -3.0 * s, 1.2),
        rbj_peak(sr, 3200, -3.5 * s, 0.8),
        rbj_highshelf(sr, 4500, -4.5 * s, 0.7),
    ]
    out = y
    for b, a in chain:
        out = ss.lfilter(b, a, out).astype(np.float32)

    # 轻压：削尖峰，听感更软
    thr = 10 ** ((-20 - 6 * (s - 1)) / 20)
    ratio = 3.0 + 2.0 * (s - 1)
    att = np.exp(-1.0 / (0.005 * sr))
    rel = np.exp(-1.0 / (0.12 * sr))
    env = 0.0
    g = np.ones(len(out), dtype=np.float32)
    for i in range(len(out)):
        x = abs(float(out[i]))
        env = att * env + (1 - att) * x if x > env else rel * env + (1 - rel) * x
        if env > thr:
            g[i] = (thr / env) ** (1 - 1 / ratio)
    out = (out * g).astype(np.float32)

    if boost_db:
        out = out * (10 ** (boost_db / 20))
    pk = float(np.max(np.abs(out)))
    if pk > 0.95:
        out = out * (0.95 / pk)
    out = out.astype(np.float32)
    sf.write(dst, out, sr)
    print("eq done", round(len(out) / sr, 2), "s", "soft", s, "boost", boost_db, flush=True)


if __name__ == "__main__":
    main()
