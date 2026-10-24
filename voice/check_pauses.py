"""断句检查器：把生成音频里测到的停顿，和文本标点推算的位置对齐，标出可疑处。

用法：
  python check_pauses.py <wav> "<文本>"
"""
import sys
import numpy as np, soundfile as sf

STRONG = {"。": 1.0, "！": 1.0, "？": 1.0, "；": 0.8, "：": 0.8, "…": 0.6}
WEAK = {"，": 0.35, "、": 0.2, ",": 0.35, ";": 0.8, ":": 0.8, ".": 1.0, "!": 1.0, "?": 1.0}
PAUSE_CHARS = set(STRONG) | set(WEAK)


def detect(path, win=0.01, min_pause=0.12, rel_thr=0.06):
    y, sr = sf.read(path)
    y = y.astype(np.float32)
    w = int(win * sr)
    n = len(y) // w
    env = np.array([np.sqrt(np.mean(y[i * w:(i + 1) * w] ** 2)) for i in range(n)])
    thr = max(0.008, float(env.max()) * rel_thr)
    voiced = env > thr
    runs, i = [], 0
    while i < n:
        if voiced[i]:
            j = i
            while j < n and voiced[j]:
                j += 1
            runs.append((i * win, j * win))
            i = j
        else:
            i += 1
    pauses = []
    for k in range(len(runs) - 1):
        a, b = runs[k][1], runs[k + 1][0]
        if b - a >= min_pause:
            pauses.append((round(a, 3), round(b, 3), round(b - a, 3)))
    if runs:
        tail_start = runs[-1][1]
        tail_len = len(y) / sr - tail_start
        if tail_len >= 0.12:
            pauses.append((round(tail_start, 3), round(len(y) / sr, 3), round(tail_len, 3)))
    return runs, pauses


def main():
    wav, text = sys.argv[1], sys.argv[2]
    chars = [c for c in text if c.strip()]
    n = len(chars)
    anchors = []
    for i, c in enumerate(chars):
        if c in PAUSE_CHARS:
            w = STRONG.get(c) or WEAK.get(c)
            anchors.append((i, c, w))

    runs, pauses = detect(wav)
    total_voiced = sum(b - a for a, b in runs)

    mapped = []
    for a, b, d in pauses:
        before = sum(max(0.0, min(b2, a) - a2) for a2, b2 in runs if a2 < a)
        est = n * (before / total_voiced) if total_voiced else 0
        mapped.append((a, b, d, est))

    print(f"音频: {wav}")
    print(f"字数: {n}  有声段: {len(runs)}  停顿: {len(pauses)}  锚点(标点): {len(anchors)}")
    print()
    print("标点推算位置:")
    for i, c, w in anchors:
        print(f"  {i:>3} 字  {c}  (权重 {w})")

    print()
    print("检测到的停顿:")
    for a, b, d, est in mapped:
        ctx = "".join(chars[max(0, int(est) - 5):int(est) + 5])
        print(f"  {a:>6.2f}s ~ {b:>6.2f}s  长 {d:.2f}s  约第 {est:>5.1f} 字  [{ctx}]")

    tol = max(3.0, 0.08 * n)
    problems = []
    for a, b, d, est in mapped:
        near = [x for x in anchors if abs(x[0] - est) <= tol]
        if not near:
            problems.append(("多余停顿", a, b, d, est))
            continue
        exp = max(x[2] for x in near)
        if d < 0.12 and exp >= 0.8:
            problems.append(("停顿过短", a, b, d, est))
    for i, c, w in anchors:
        if w >= 0.6:
            hit = [x for x in mapped if abs(x[3] - i) <= tol and x[2] >= 0.10]
            if not hit:
                problems.append(("缺少停顿", i, c, w, i))

    print()
    if not problems:
        print("结论: 没发现明显断句错位")
    else:
        print("可疑处:")
        for p in problems:
            if p[0] == "缺少停顿":
                print(f"  缺少停顿: 第 {p[1]} 字「{p[2]}」附近应有停顿，但没有测到")
            else:
                print(f"  {p[0]}: {p[1]:.2f}s~{p[2]:.2f}s（{p[3]:.2f}s，约第 {p[4]:.1f} 字）")


if __name__ == "__main__":
    main()
