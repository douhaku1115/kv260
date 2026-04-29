# 案7: シリアル受信 → HDMI文字表示（PetaLinux版）

PCからシリアル通信で送った文字を、KV260のHDMIモニターにリアルタイム表示する。

## システム構成

```
┌──────────┐    UART 115200bps    ┌──────────────┐    HDMI    ┌──────────┐
│   PC     │ ──────────────────→ │    KV260     │ ────────→ │ モニター  │
│ tio      │   USB-JTAGケーブル   │ serial_      │           │ 文字表示  │
│/dev/     │                      │ display.py   │           │          │
│ttyUSB1   │                      │ /dev/ttyPS1  │           │          │
└──────────┘                      │ /dev/fb0     │           └──────────┘
                                  └──────────────┘
```

## 動作環境

| 項目 | 内容 |
|------|------|
| ボード | Xilinx KV260 Starter Kit |
| OS | PetaLinux 2025.1 |
| 画面解像度 | 1920x1080, 16bpp (RGB565) |
| シリアル | PS UART1 (/dev/ttyPS1), 115200bps 8N1 |
| PC側ツール | tio (シリアル端末) |

## 使い方

### 1. KV260にスクリプトを転送
```bash
scp serial_display.py dou@192.168.0.13:~/
```

### 2. KV260にSSHで接続
```bash
ssh dou@192.168.0.13
```

### 3. シリアルコンソールのgettyを停止（シリアルポートを解放）
```bash
sudo systemctl stop serial-getty@ttyPS1.service
```

### 4. スクリプトを実行
```bash
sudo python3 serial_display.py
```

### 5. PC側から文字を送信（別ターミナル）
```bash
tio -b 115200 /dev/ttyUSB1
```

tioで打った文字がHDMIモニターに緑色で表示される。

## コード解説

### 全体の流れ

```
main()
  │
  ├─ FrameBuffer() ── /dev/fb0をオープン、解像度・BPP取得、画面クリア
  │
  ├─ open_serial() ── /dev/ttyPS1をraw modeでオープン
  │
  └─ メインループ
       │
       └─ os.read(ser_fd) → 1バイトずつ fb.put_char() → HDMIに描画
```

### 主要コンポーネント

#### 1. フレームバッファ制御 (`FrameBuffer`クラス)

Linuxのフレームバッファデバイス `/dev/fb0` に直接ピクセルデータを書き込んでHDMI出力する。
GStreamerやX Window不要で、最小限のコードで画面描画が可能。

```python
# フレームバッファの情報取得（ioctlシステムコール）
fcntl.ioctl(fb_fd, FBIOGET_VSCREENINFO, buf)
# → 解像度(xres, yres)とピクセル深度(bpp)を取得

# ピクセル書き込み（seekで位置指定、writeでデータ書き込み）
offset = ((row * CHAR_H + y) * xres + col * CHAR_W) * bytes_per_pixel
os.lseek(fd, offset, os.SEEK_SET)
os.write(fd, pixel_data)
```

**フレームバッファのメモリレイアウト:**
```
アドレス 0                                    xres * bytes_per_pixel
  ├─ 1行目のピクセル (左→右) ──────────────────┤
  ├─ 2行目のピクセル ──────────────────────────┤
  :                                             :
  ├─ yres行目のピクセル ───────────────────────┤
```

**色フォーマット (RGB565, 16bpp):**
```
ビット: 15       11 10       5 4        0
        ├─ Red ──┤ ├─ Green ─┤ ├─ Blue ─┤
緑色 = 0x07E0 = 0b00000_111111_00000
```

#### 2. ビットマップフォント (`FONT_8x16`)

各ASCII文字を8x16ピクセルのビットマップで定義。
フォントデータは1文字あたり16バイト（16行 x 1バイト/行）。

```
例: 文字 'A' (0x41) のフォントデータ
バイト値   ビットパターン     表示
0x10      ...#....
0x38      ..###...
0x6C      .##.##..
0xC6      ##...##.
0xC6      ##...##.
0xFE      #######.     ← 横棒
0xC6      ##...##.
0xC6      ##...##.
0xC6      ##...##.
0xC6      ##...##.
```

各行の1バイトを左(MSB)から右(LSB)へ走査し、
ビットが1なら前景色（緑）、0なら背景色（黒）のピクセルを書く。

```python
if bits & (0x80 >> x):  # MSBから順にチェック
    pixel = FG_COLOR    # 前景色（緑）
else:
    pixel = BG_COLOR    # 背景色（黒）
```

#### 3. テキスト制御

**文字グリッド:** 画面を8x16ピクセル単位で区切り、テキスト端末として使う。
- 1920x1080の場合: 240桁 x 67行

**カーソル管理:**
- `cur_col`, `cur_row` で現在の文字位置を追跡
- 右端到達で自動改行
- 下端到達で画面全体を1行分上にスクロール

**対応する制御文字:**
- `\n`, `\r` → 改行（カーソルを次の行の先頭へ）
- `\x08`, `\x7f` → バックスペース（1文字戻って消去）

#### 4. シリアル通信 (`open_serial`)

`/dev/ttyPS1` (PS UART1) をraw modeで開く。
raw modeではカーネルの行バッファリングやエコーを無効にし、
受信した1バイトをそのまま読み取る。

```python
# termios設定
attrs[0] = 0                    # iflag: 入力処理なし
attrs[1] = 0                    # oflag: 出力処理なし
attrs[2] = CS8|CREAD|CLOCAL     # cflag: 8ビット、受信有効、モデム制御なし
attrs[3] = 0                    # lflag: エコーなし、行編集なし
attrs[6][VMIN] = 1              # 最低1バイト受信で読み出し
attrs[6][VTIME] = 0             # タイムアウトなし（ブロッキング）
```

### なぜgettyを停止するのか

KV260のPetaLinuxでは、`/dev/ttyPS1`はデフォルトでシリアルコンソール
（ログイン端末）として使われている。`serial-getty@ttyPS1.service`が
このデバイスを占有しているため、スクリプトがアクセスするには
先にgettyを停止する必要がある。
