# -*- coding: utf-8 -*-
# ---------------------------------------------------------------------------
# train_mnist.py -- 段13 段階A: MNIST を学習し、8ビット整数に量子化して
#                   FPGA 用の係数ファイル(hex)を書き出す
#
#   【なぜ量子化するか】
#     FPGA では浮動小数点の積和は高価。8ビット整数なら DSP 1 個で足り、
#     内蔵メモリも 1/4 で済む。そのかわり「浮動小数点で学習 → 整数に置き換えても
#     精度が落ちないこと」を数字で確かめてから RTL を書く必要がある。
#
#   【量子化の方式】
#     重み        : int8  (-128〜127)
#     特徴マップ  : uint8 (0〜255)。ReLU の後なので負にならない
#     積和        : int32
#     スケール調整: 右シフトのみ (2の冪に丸める)。掛け算器が要らない
#
#     浮動小数点の式:
#       y = Σ(w_f × x_f) + b_f
#     量子化すると (w_f = w_s × W, x_f = x_s × X):
#       y = w_s·x_s·Σ(W × X) + b_f
#     次の層の入力スケール y_s で割って整数に直すと:
#       Y = (w_s·x_s / y_s)·(Σ(W × X) + B)      B = b_f / (w_s·x_s)
#     この (w_s·x_s / y_s) を 2 の冪に丸めれば、右シフト 1 回で済む。
#
#   【出力】
#     rtl/*.hex        … 重みとバイアス (RTL が $readmemh で読む)
#     rtl/cnn_param.vh … シフト量などの定数 (RTL が `include する)
#     sim/test_*.hex   … 検証用のテスト画像と期待される答え
#
#   使い方:
#     python train_mnist.py
# ---------------------------------------------------------------------------
import io
import os
import sys

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torchvision import datasets, transforms

# Windows のコンソールで日本語が化けないようにする
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RTL  = os.path.join(ROOT, "rtl")
SIM  = os.path.join(ROOT, "sim")
DATA = os.path.join(HERE, "data")

torch.manual_seed(0)
np.random.seed(0)

# ===========================================================================
# ネットワーク
# ===========================================================================
#   入力 28x28x1
#    → conv1 3x3x1x8   + ReLU → 26x26x8
#    → maxpool 2x2            → 13x13x8
#    → conv2 3x3x8x16  + ReLU → 11x11x16
#    → maxpool 2x2            → 5x5x16
#    → 全結合 400→10
class Net(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(1, 8, 3)
        self.conv2 = nn.Conv2d(8, 16, 3)
        self.fc    = nn.Linear(16 * 5 * 5, 10)

    def forward(self, x):
        x = F.relu(self.conv1(x))
        x = F.max_pool2d(x, 2)
        x = F.relu(self.conv2(x))
        x = F.max_pool2d(x, 2)
        return self.fc(x.flatten(1))


def load_data():
    # 入力は 0〜255 の整数のまま扱う（FPGA 側と揃えるため）
    tf = transforms.Compose([transforms.ToTensor()])
    tr = datasets.MNIST(DATA, train=True,  download=True, transform=tf)
    te = datasets.MNIST(DATA, train=False, download=True, transform=tf)
    return (torch.utils.data.DataLoader(tr, batch_size=128, shuffle=True),
            torch.utils.data.DataLoader(te, batch_size=512, shuffle=False))


def train(net, tr_loader, te_loader, epochs=3):
    opt = torch.optim.Adam(net.parameters(), lr=1e-3)
    for ep in range(epochs):
        net.train()
        for x, y in tr_loader:
            opt.zero_grad()
            loss = F.cross_entropy(net(x), y)
            loss.backward()
            opt.step()
        acc = evaluate_float(net, te_loader)
        print("  エポック %d 終了  正解率 %.2f%%" % (ep + 1, acc * 100))
    return net


def evaluate_float(net, loader):
    net.eval()
    ok = n = 0
    with torch.no_grad():
        for x, y in loader:
            ok += (net(x).argmax(1) == y).sum().item()
            n  += y.numel()
    return ok / n


# ===========================================================================
# 量子化
# ===========================================================================
def quantize_weight(w):
    """重みを int8 にする。戻り値: (整数の重み, スケール)"""
    s = float(np.abs(w).max()) / 127.0
    if s == 0.0:
        s = 1.0
    q = np.clip(np.round(w / s), -127, 127).astype(np.int32)
    return q, s


def pow2_shift(m):
    """スケール比 m (< 1) を 2 の冪に丸め、右シフト量を返す

    切り捨て(round)ではなく切り上げ(ceil)にする。
    round だとシフトが 1 ビット足りない場合があり、そのとき出力が
    設計上の最大値 255 を超えて飽和し、情報が失われる。
    ceil なら最大でも 1 ビット分の精度を捨てるだけで済み、飽和は起きない。
    """
    if m <= 0:
        return 0
    return int(max(0, np.ceil(-np.log2(m))))


def collect_scales(net, loader, nbatch=8):
    """検証データを流して各層の出力の最大値を調べ、活性化のスケールを決める

    入力は学習時と同じ 0〜1 のまま流すこと。
    ここで x * 255 を流すと a1/a2 の最大値が 255 倍に見え、
    そこから決まるスケールも 255 倍ずれる。その結果 CONV1_SHIFT が
    8 ビット過大になり、特徴マップがほぼ全部 0 に潰れて推論が壊れる。
    「FPGA 側の入力が 0〜255 だから」という辻褄合わせは、入力スケール
    s_in = 1/255 のほうで既に済んでいる（QuantNet を見よ）。
    """
    net.eval()
    mx1 = mx2 = mx3 = 0.0
    with torch.no_grad():
        for i, (x, _) in enumerate(loader):
            if i >= nbatch:
                break
            a1 = F.max_pool2d(F.relu(net.conv1(x)), 2)
            a2 = F.max_pool2d(F.relu(net.conv2(a1)), 2)
            a3 = net.fc(a2.flatten(1))
            mx1 = max(mx1, float(a1.max()))
            mx2 = max(mx2, float(a2.max()))
            mx3 = max(mx3, float(a3.abs().max()))
    # 特徴マップは 0〜255 に収めたいので、最大値が 255 になるスケールにする
    return mx1 / 255.0, mx2 / 255.0, mx3


class QuantNet:
    """整数だけで推論する版。RTL はこれと 1 ビットも違わない結果を出すこと。"""

    def __init__(self, net, loader):
        # ---- 重みを int8 にする ----
        w1 = net.conv1.weight.detach().numpy()
        w2 = net.conv2.weight.detach().numpy()
        w3 = net.fc.weight.detach().numpy()
        b1 = net.conv1.bias.detach().numpy()
        b2 = net.conv2.bias.detach().numpy()
        b3 = net.fc.bias.detach().numpy()

        self.W1, s_w1 = quantize_weight(w1)
        self.W2, s_w2 = quantize_weight(w2)
        self.W3, s_w3 = quantize_weight(w3)

        # ---- 活性化のスケールを実データから決める ----
        s_a1, s_a2, s_a3 = collect_scales(net, loader)

        # 入力は 0〜255 の整数そのまま（浮動小数点では 0〜1 なのでスケール 1/255）
        s_in = 1.0 / 255.0

        # 各層のシフト量 = -log2(重みスケール × 入力スケール ÷ 出力スケール)
        #
        #   ここで大事なのは「次の層に渡すのは、丸めた後に実際に成立している
        #   スケール」だということ。シフト量を 2 の冪に切り上げた時点で、
        #   出力の実スケールは狙った s_a1 ではなく s_w1 × s_in × 2^sh1 になる。
        #   丸める前の s_a1 を次層の計算に使うと、その分の誤差が層ごとに
        #   積み上がってしまう。だから r1, r2（実スケール）を計算して使う。
        self.sh1 = pow2_shift(s_w1 * s_in / s_a1)
        r1 = s_w1 * s_in * (2.0 ** self.sh1)        # conv1 出力の実スケール
        self.sh2 = pow2_shift(s_w2 * r1 / s_a2)
        r2 = s_w2 * r1 * (2.0 ** self.sh2)          # conv2 出力の実スケール

        #   全結合は最終層。欲しいのは 10 個のスコアの大小関係だけで、
        #   絶対値には意味がない。したがってスケールを合わせる必要がなく、
        #   積和の int32 をそのまま出せばよい（シフト 0）。
        #   ここで無理にスケールを合わせると（例えば最大値が 1 になるように
        #   18 ビット右シフトすると）スコアが全部 0 に潰れて推論が壊れる。
        #   RTL 側も右シフト回路が要らなくなって好都合。
        self.sh3 = 0

        # バイアスは積和と同じ単位に直しておく（B = b / (w_s × x_s)）
        self.B1 = np.round(b1 / (s_w1 * s_in)).astype(np.int32)
        self.B2 = np.round(b2 / (s_w2 * r1)).astype(np.int32)
        self.B3 = np.round(b3 / (s_w3 * r2)).astype(np.int32)

        self.scales = dict(w1=s_w1, w2=s_w2, w3=s_w3,
                           a1=r1, a2=r2, a3=s_a3, inp=s_in)

    # ---- 以下、RTL に落とす計算そのもの（整数のみ）----
    @staticmethod
    def conv3x3(x, W, B, shift):
        """x: (Cin,H,W) uint8 → 出力 (Cout,H-2,W-2) uint8"""
        cin, h, w = x.shape
        cout = W.shape[0]
        oh, ow = h - 2, w - 2
        y = np.zeros((cout, oh, ow), dtype=np.int64)
        for co in range(cout):
            acc = np.full((oh, ow), B[co], dtype=np.int64)
            for ci in range(cin):
                for ky in range(3):
                    for kx in range(3):
                        acc += int(W[co, ci, ky, kx]) * x[ci, ky:ky + oh, kx:kx + ow]
            y[co] = acc
        y = y >> shift                      # スケール調整（右シフトのみ）
        y = np.clip(y, 0, 255)              # ReLU と 8ビット飽和を同時に行う
        return y.astype(np.uint8)

    @staticmethod
    def maxpool2(x):
        c, h, w = x.shape
        h2, w2 = h // 2, w // 2
        x = x[:, :h2 * 2, :w2 * 2].reshape(c, h2, 2, w2, 2)
        return x.max(axis=(2, 4))

    def forward_layers(self, img):
        """img: (28,28) uint8 → 各層の出力を全部返す

        RTL のデバッグはこの中間値と 1 バイトずつ突き合わせる。
        最後のスコアだけ見て「合わない」と言っても、どの層が原因か分からない。
        """
        c1 = self.conv3x3(img.reshape(1, 28, 28).astype(np.int64),
                          self.W1, self.B1, self.sh1)       # 8 x 26 x 26 uint8
        p1 = self.maxpool2(c1)                              # 8 x 13 x 13 uint8
        c2 = self.conv3x3(p1.astype(np.int64),
                          self.W2, self.B2, self.sh2)       # 16 x 11 x 11 uint8
        p2 = self.maxpool2(c2)                              # 16 x  5 x  5 uint8
        v   = p2.astype(np.int64).flatten()                 # 400
        acc = self.W3.astype(np.int64) @ v + self.B3        # 10
        sc  = (acc >> self.sh3).astype(np.int32)
        return c1, p1, c2, p2, sc

    def forward(self, img):
        """img: (28,28) uint8 → 10 個のスコア(int32)"""
        return self.forward_layers(img)[4]


def evaluate_quant(qnet, loader, limit=2000):
    ok = n = 0
    for x, y in loader:
        imgs = (x.numpy() * 255.0).round().astype(np.uint8)
        for i in range(imgs.shape[0]):
            if qnet.forward(imgs[i, 0]).argmax() == int(y[i]):
                ok += 1
            n += 1
            if n >= limit:
                return ok / n
    return ok / n


# ===========================================================================
# 書き出し
# ===========================================================================
def write_hex(path, arr, bits):
    """整数の配列を hex で1行1語ずつ書く（2の補数）"""
    mask = (1 << bits) - 1
    digits = bits // 4
    with open(path, "w") as fp:
        for v in np.asarray(arr).flatten():
            fp.write("%0*x\n" % (digits, int(v) & mask))
    return np.asarray(arr).size


def export(qnet, loader):
    os.makedirs(RTL, exist_ok=True)
    os.makedirs(SIM, exist_ok=True)

    # ---- 重み ----
    #   並び順は RTL が読む順に合わせる:
    #     conv: [出力ch][入力ch][縦][横]
    #     全結合: [出力][入力]
    n = write_hex(os.path.join(RTL, "conv1_w.hex"), qnet.W1,  8)
    print("  conv1_w.hex  %4d 語 (8bit)" % n)
    n = write_hex(os.path.join(RTL, "conv1_b.hex"), qnet.B1, 32)
    print("  conv1_b.hex  %4d 語 (32bit)" % n)
    n = write_hex(os.path.join(RTL, "conv2_w.hex"), qnet.W2,  8)
    print("  conv2_w.hex  %4d 語 (8bit)" % n)
    n = write_hex(os.path.join(RTL, "conv2_b.hex"), qnet.B2, 32)
    print("  conv2_b.hex  %4d 語 (32bit)" % n)
    n = write_hex(os.path.join(RTL, "fc_w.hex"),    qnet.W3,  8)
    print("  fc_w.hex     %4d 語 (8bit)" % n)
    n = write_hex(os.path.join(RTL, "fc_b.hex"),    qnet.B3, 32)
    print("  fc_b.hex     %4d 語 (32bit)" % n)

    # ---- 定数 ----
    # 他の .v は UTF-8 なので、ここも明示的に UTF-8 で書く。
    # 指定しないと Windows では cp932 になり、xvlog で文字コードが混在する。
    with io.open(os.path.join(RTL, "cnn_param.vh"), "w", encoding="utf-8",
                 newline="\n") as fp:
        fp.write("// train_mnist.py が自動生成する。手で編集しない。\n")
        fp.write("//   シフト量は「積和の結果を何ビット右へずらすか」。\n")
        fp.write("//   量子化のスケール合わせを 2 の冪に丸めてあるので乗算器が要らない。\n")
        fp.write("localparam integer CONV1_SHIFT = %d;\n" % qnet.sh1)
        fp.write("localparam integer CONV2_SHIFT = %d;\n" % qnet.sh2)
        fp.write("localparam integer FC_SHIFT    = %d;\n" % qnet.sh3)
        fp.write("\n")
        fp.write("localparam integer C1_IN = 1,  C1_OUT = 8,  C1_SIZE = 28;\n")
        fp.write("localparam integer C2_IN = 8,  C2_OUT = 16, C2_SIZE = 13;\n")
        fp.write("localparam integer FC_IN = 400, FC_OUT = 10;\n")
    print("  cnn_param.vh  (CONV1_SHIFT=%d CONV2_SHIFT=%d FC_SHIFT=%d)"
          % (qnet.sh1, qnet.sh2, qnet.sh3))

    # ---- 検証用のテスト画像と期待される答え ----
    #   RTL のシミュレーションはこの画像を入れ、この答えと一致することを確認する
    x, y = next(iter(loader))
    imgs = (x.numpy() * 255.0).round().astype(np.uint8)[:10, 0]
    labels = y.numpy()[:10]

    write_hex(os.path.join(SIM, "test_images.hex"), imgs, 8)

    # ---- 層ごとの中間値（RTL を 1 層ずつ突き合わせるため）----
    #   並び順はどれも [画像][チャネル][縦][横]。RTL のバッファもこの順に持つ。
    lay = [qnet.forward_layers(imgs[i]) for i in range(10)]
    for name, k, bits, shape in (("conv1_out", 0,  8, "8ch x 26 x 26"),
                                 ("pool1_out", 1,  8, "8ch x 13 x 13"),
                                 ("conv2_out", 2,  8, "16ch x 11 x 11"),
                                 ("pool2_out", 3,  8, "16ch x  5 x  5"),
                                 ("scores",    4, 32, "10")):
        a = np.stack([L[k] for L in lay])
        n = write_hex(os.path.join(SIM, "test_%s.hex" % name), a, bits)
        print("  test_%-9s.hex %6d 語 (%dbit)  1枚あたり %s"
              % (name, n, bits, shape))

    with io.open(os.path.join(SIM, "test_expected.txt"), "w", encoding="utf-8",
                 newline="\n") as fp:
        fp.write("# 画像番号  正解  量子化推論の答え  10個のスコア\n")
        for i in range(10):
            sc = qnet.forward(imgs[i])
            fp.write("%d %d %d %s\n" % (i, labels[i], sc.argmax(),
                                        " ".join(str(int(v)) for v in sc)))
    print("  test_images.hex   10 枚 (28x28)")
    print("  test_expected.txt 期待される答え")


def step_data():
    """段階1: MNIST を取ってくるだけ"""
    print("MNIST を取得する...")
    tr, te = load_data()
    nx = len(tr.dataset)
    ny = len(te.dataset)
    print("  学習用 %d 枚 / 検証用 %d 枚" % (nx, ny))
    print("  保存先: %s" % DATA)
    print("完了。次は  python train_mnist.py train")


def step_train(epochs=3):
    """段階2: 学習して重みを保存する（時間がかかるのはここだけ）"""
    tr, te = load_data()
    print("学習する（%d エポック、CPU）" % epochs)
    net = train(Net(), tr, te, epochs=epochs)
    acc = evaluate_float(net, te)
    path = os.path.join(HERE, "mnist_float.pt")
    torch.save(net.state_dict(), path)
    print("")
    print("  浮動小数点の正解率 : %.2f %%" % (acc * 100))
    print("  保存: %s" % path)
    print("完了。次は  python train_mnist.py quant")


def step_quant(limit=2000):
    """段階3: 保存した重みを読んで量子化し、係数を書き出す（何度でもやり直せる）"""
    path = os.path.join(HERE, "mnist_float.pt")
    if not os.path.exists(path):
        print("mnist_float.pt が無い。先に  python train_mnist.py train  を実行すること")
        return 1

    _, te = load_data()
    net = Net()
    net.load_state_dict(torch.load(path))
    net.eval()

    acc_f = evaluate_float(net, te)

    print("8 ビットに量子化する...")
    qnet = QuantNet(net, te)
    print("  重みのスケール : conv1=%.3e conv2=%.3e fc=%.3e"
          % (qnet.scales["w1"], qnet.scales["w2"], qnet.scales["w3"]))
    print("  シフト量       : conv1=%d conv2=%d fc=%d"
          % (qnet.sh1, qnet.sh2, qnet.sh3))

    print("量子化した版で推論する（%d 枚）..." % limit)
    acc_q = evaluate_quant(qnet, te, limit=limit)

    print("")
    print("=" * 52)
    print("  浮動小数点        : %.2f %%" % (acc_f * 100))
    print("  8ビット整数       : %.2f %%" % (acc_q * 100))
    print("  差                : %.2f 点" % ((acc_f - acc_q) * 100))
    print("=" * 52)
    print("")

    print("係数を書き出す...")
    export(qnet, te)
    print("")
    print("完了。整数版の正解率が基準になる。RTL はこれと完全に一致すること。")
    return 0


def main():
    cmd = sys.argv[1] if len(sys.argv) >= 2 else ""
    if   cmd == "data":  return step_data()
    elif cmd == "train": return step_train(int(sys.argv[2]) if len(sys.argv) >= 3 else 3)
    elif cmd == "quant": return step_quant()
    else:
        print("使い方:")
        print("  python train_mnist.py data      MNIST を取得する")
        print("  python train_mnist.py train [n] 学習する（既定 3 エポック）")
        print("  python train_mnist.py quant     量子化して係数を書き出す")
        return 1


if __name__ == "__main__":
    sys.exit(main() or 0)
