# NCO（数値制御発振器）用のサイン表と、19kHz PLL の定数を計算する
#
#   ・表は 1024 点で 1 周期ぶん、Q15 固定小数点（16bit signed）
#     位相アキュムレータ 32bit の上位 10bit を添字にする。
#     位相の量子化誤差は 2pi/1024 = 0.35 度 → 分離度への影響は -60dB 以下。
#   ・cos は sin の添字を +256（=90度）ずらして同じ表を引く。
import math

N = 1024
OUT = r"E:/fpga/kria260/kv260_i2s2/rtl/nco_sin.hex"

with open(OUT, "w") as f:
    for k in range(N):
        s = int(round(math.sin(2 * math.pi * k / N) * 32767))
        s = max(-32768, min(32767, s))
        f.write("%04X\n" % (s & 0xFFFF))

print("生成:", OUT, N, "エントリ")

# ---------------- PLL の定数 ----------------
FS      = 976560.0      # PLL が動く速さ（IQ のサンプリング速度）
F_PILOT = 19000.0       # パイロット信号の周波数
ACC_W   = 32            # 位相アキュムレータの幅

step0 = round(2**ACC_W * F_PILOT / FS)
hz    = 2**ACC_W / FS   # 1Hz あたりのアキュムレータ単位

print()
print("fs = %.0f Hz" % FS)
print("NCO_STEP0 = %d   (0x%08X)  ← 19kHz ぶんの位相増分" % (step0, step0))
print("1Hz = %.1f units" % hz)
print("表引きの逆算: %.4f Hz" % (step0 / hz))

# 比例ゲイン Kp: 1次ループの帯域 BW[Hz] から決める
#   位相誤差 e は Q15（32768 = 1.0 rad 相当、tan の小角近似）
#   1サンプルあたりの開ループ利得 G = Kp * 32768 * 2pi / 2^32
#   閉ループ帯域 BW ~= G * fs / (2pi)
for bw in (10.0, 30.0, 100.0):
    G  = 2 * math.pi * bw / FS
    Kp = G * 2**ACC_W / (32768 * 2 * math.pi)
    print("BW=%5.0fHz -> G=%.3e  Kp=%.2f  (2^%.2f)" % (bw, G, Kp, math.log2(Kp)))

# 採用値
KP_SHIFT = 2            # 比例項 = e << 2  （Kp = 4 → BW 約 30Hz）
Kp = 2**KP_SHIFT
G  = Kp * 32768 * 2 * math.pi / 2**ACC_W
print()
print("採用 KP_SHIFT=%d (Kp=%d) -> 閉ループ帯域 %.1f Hz" % (KP_SHIFT, Kp, G * FS / (2 * math.pi)))

# 積分ゲイン Ki: 減衰係数 zeta=0.707 なら Ki = Kp*G/2 [units / e]
ki_ideal = Kp * G / 2
print("Ki(zeta=0.707) = %.3e units/e  → 1/%.0f" % (ki_ideal, 1 / ki_ideal))
for ki_shift in (3, 4, 5):
    # freq_q8 -= e >> ki_shift、freq は Q8 なので実効は e / (2^ki_shift * 256)
    ki = 1.0 / (2**ki_shift * 256)
    zeta = 0.707 * math.sqrt(ki_ideal / ki)
    print("  KI_SHIFT=%d -> Ki=%.3e  zeta=%.2f" % (ki_shift, ki, zeta))

# パイロット検出のしきい値
#   norm のフルスケール(=偏移75kHz)が 32768。パイロットは全偏移の 9~10%。
#   NCO と掛けて LPF すると振幅は半分になる。
for pct in (0.10, 0.09):
    amp = 32768 * pct
    print("パイロット %d%% -> 振幅 %.0f, 相関出力 %.0f" % (pct * 100, amp, amp / 2))


# ---------------- L−R 経路のゲイン補正 ----------------
#
#   分離度を決めるのは位相よりも「S(=L+R) と D(=L−R) の振幅が揃っているか」。
#   L = S+D で R を打ち消すので、D が S の g 倍だと
#       分離度[dB] = 20*log10( (1+g) / (1-g) )
#   g=0.89 なら 25dB しか出ない。位相誤差 0.07 度（58dB相当）より遥かに厳しい。
#
#   D は MPX の 38kHz 付近に載っているので、
#     (a) 前段の帯域制限（4点移動平均 x PRE_STAGES 段）
#     (b) 位相差検出が 1 標本差分であること（sinc）
#   の2つで S より余分に減衰する。その逆数を D に掛けて揃える。

def ma4(f, fs, stages):
    """4点移動平均を stages 段重ねたときの振幅特性"""
    if f == 0:
        return 1.0
    num = math.sin(math.pi * 4 * f / fs)
    den = 4 * math.sin(math.pi * f / fs)
    return abs(num / den) ** stages

def disc_sinc(f, fs):
    """1標本差分で位相差を取ることによる減衰"""
    if f == 0:
        return 1.0
    x = math.pi * f / fs
    return math.sin(x) / x

F_SUB = 38000.0
print()
print("--- L−R 経路のゲイン補正 ---")
for stages in (1, 2, 3):
    print("前段 %d 段:" % stages)
    tot = 0.0
    cnt = 0
    for faud in (1000.0, 3000.0, 5000.0, 10000.0, 15000.0):
        # DSB なので 38k-f と 38k+f の両方の側波帯が戻ってくる。平均が実効ゲイン。
        lo = ma4(F_SUB - faud, FS, stages) * disc_sinc(F_SUB - faud, FS)
        hi = ma4(F_SUB + faud, FS, stages) * disc_sinc(F_SUB + faud, FS)
        g_d = (lo + hi) / 2
        g_s = ma4(faud, FS, stages) * disc_sinc(faud, FS)
        g   = g_d / g_s
        sep = 20 * math.log10((1 + g) / abs(1 - g))
        tot += g
        cnt += 1
        print("   音声 %5.0fHz: D/S = %.4f  → 補正なしの分離度 %.1f dB" % (faud, g, sep))
    gavg = tot / cnt
    dgain = round(4096 / gavg)
    print("   平均 D/S = %.4f  → D_GAIN(Q12) = %d" % (gavg, dgain))
    # 補正後に残るのは音声周波数による ばらつき だけ
    worst = 0.0
    for faud in (1000.0, 3000.0, 5000.0, 10000.0, 15000.0):
        lo = ma4(F_SUB - faud, FS, stages) * disc_sinc(F_SUB - faud, FS)
        hi = ma4(F_SUB + faud, FS, stages) * disc_sinc(F_SUB + faud, FS)
        g  = ((lo + hi) / 2) / (ma4(faud, FS, stages) * disc_sinc(faud, FS)) * (dgain / 4096)
        s  = 20 * math.log10((1 + g) / abs(1 - g))
        if worst == 0.0 or s < worst:
            worst = s
    print("   補正後の最悪分離度 = %.1f dB" % worst)
