# 512点FFT用のツイドル係数テーブルを生成する
#   W_N^k = cos(2πk/N) - i sin(2πk/N)  の cos/sin を Q15固定小数点(16bit)で出力
#   k = 0..N/2-1 の 256 エントリ
import math

N = 512
half = N // 2

cos_path = r"E:/fpga/kria260/kv260_i2s2/rtl/twiddle_cos.hex"
sin_path = r"E:/fpga/kria260/kv260_i2s2/rtl/twiddle_sin.hex"

with open(cos_path, "w") as fc, open(sin_path, "w") as fs:
    for k in range(half):
        c = int(round(math.cos(2 * math.pi * k / N) * 32767))
        s = int(round(math.sin(2 * math.pi * k / N) * 32767))
        # +32767 は 0x7FFF に丸める（16bit signed の範囲内）
        if c > 32767:  c = 32767
        if s > 32767:  s = 32767
        fc.write("%04X\n" % (c & 0xFFFF))
        fs.write("%04X\n" % (s & 0xFFFF))

print("生成:", cos_path, "/", sin_path, " 各", half, "エントリ")
print("先頭 cos[0]=0x7FFF(≒1.0), sin[0]=0x0000 になっているはず")
