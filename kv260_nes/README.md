# KV260 NES (ファミコン)

KV260 の PL に NES を Verilog で自作する。6502 CPU・PPU (画面)・APU (音)・マッパーをすべて PL に置き、
PS (ベアメタル C) は ROM の書き込みとキー入力の中継だけを行う。
映像は HDMI (PS の Live Video)、音は HDMI (PS の Live Audio) と Pmod I2S2 (J2) の両方、入力は UART のキー。

ROM はテスト ROM (nestest / blargg / Holy Mapperel) と、無料公開の自作ゲーム
(pinobatch の Thwaite・Concentration Room、GPL-3.0) を使う。ROM はリポジトリに入れない (`roms/` は git 外)。

## 段

| 段 | 内容 | 状態 |
|---|---|---|
| A | 画面バッファ 256x240 を 3 倍で HDMI に表示 | sim PASS |
| B | 6502 CPU (公式命令)。nestest のログと 1 命令ずつ照合 | 5003 命令・サイクル数まで一致 |
| C | CPU + RAM + PRG。AXI で PRG を書き nestest を実行 | 結果 $02/$03 = 00 |
| D | PPU (背景・スクロール・NMI・スプライト・0 番ヒット・OAM DMA) | sprite_hit_tests 11 本 PASS |
| E | コントローラ ($4016/$4017) と UART キー | tb_pad PASS |
| F | APU (矩形波 2・三角波・ノイズ・DMC) → I2S2、PRG-RAM | apu_test 8 本 PASS。合成済・**実機 HDMI で Thwaite 表示** |
| G | マッパー 0/1/2/3/4/7、PRG 256KB・CHR 128KB | Holy Mapperel 13 本 (WRAM 保護込み)・mmc3_test 4 本 PASS。合成済・実機で Thwaite と MMC1/MMC3 のテスト ROM 表示 |
| H | HDMI から音 (PS の Live Audio、48kHz) | tb_hdmi_audio PASS。合成済・**実機でモニターのスピーカーから Thwaite の音** |
| - | ゲームの一覧 (メニュー)。PS のソフトだけ | 実機で 8 本から選べる・LB で一覧に戻る |

## 構成

```
PS (A53 ベアメタル C, vitis_src/main.c)
  ├ HDMI 初期化 (InitDP / RunDP。kv260_chip8 から流用)
  ├ ROM (rom_data.h) を AXI で PL の PRG/CHR へ書く → CTRL bit0=1 で実行
  └ UART のキー → PAD レジスタ (12 フレーム押し続ける)
        │ AXI4-Lite  0xA0000000〜 256KB
        ▼
nes_axi_slave ── 単純なバス ──► rtl_top
                                 ├ レジスタ
                                 ├ nes_core ─┬ cpu6502  6502 CPU
                                 │           ├ ppu      画面
                                 │           ├ apu      音
                                 │           ├ mapper   バンク切替
                                 │           └ 内蔵 RAM 2KB / PRG-RAM 8KB / PRG 256KB / CHR 128KB / VRAM 2KB
                                 ├ nes_fb      画面バッファ 256x240 x 6bit
                                 ├ nes_palette 64 色 → RGB
                                 ├ vga_iface   1280x720 (74.25MHz)
                                 ├ i2s_tx      Pmod I2S2 (mclk 12.5MHz)
                                 └ xlive_audio HDMI の音 (24.576MHz → PS の Live Audio)
```

- 表示: 256x240 を縦横 3 倍 (768x720) にして X=256 から。外側は暗い灰色。
  3 で割る計算は `n*683 >> 11` (n < 768 で floor(n/3) と一致。sim で全数確認)。
- NES 側 (100MHz) と映像側 (74.25MHz) は画面バッファで切り離す。
- 音: APU の 16bit を 1024 クロックごとに保持し、トグル + 3 段 FF で mclk 側へ渡す。
- HDMI の音: 同じ保持値を 24.576MHz 側でも受け、512 クロックに 1 回 (= 48kHz ちょうど) FIFO に入れる。
  xlive_audio (miya4649 の Live_Audio_KV260_KR260_Template から) が S/PDIF 形式の語にして PS の DP に渡す。
  DP も同じ 24.576MHz から 48kHz で取り出すので、入りと出の速さが一致する。左右は同じ値 (モノラル)。
  main.c の SetupAudio がオーディオインフォフレーム (L-PCM・2ch・48kHz・16bit) を書く。
- 時間: すべて 100MHz で動かし、クロック許可で刻む。ppu_ce = 5.3693MHz (位相積算)、cpu_ce = その 3 回に 1 回。

## CPU から見たメモリ

| 番地 | 中身 |
|---|---|
| $0000-$1FFF | 内蔵 RAM 2KB (ミラー) |
| $2000-$3FFF | PPU レジスタ |
| $4000-$4013, $4015 | APU |
| $4014 | OAM DMA (513/514 サイクル CPU を止める) |
| $4016 / $4017 | コントローラ / APU フレームカウンタ |
| $6000-$7FFF | PRG-RAM 8KB |
| $8000-$FFFF | PRG。8KB の窓 4 つをマッパーのバンク番号で選ぶ |

## AXI マップ (0xA0000000)

レジスタは 0x10 刻み (Zynq US+ の HPM で 0x10 境界にないと読めない事があった教訓)。

| 番地 | 名前 | 中身 |
|---|---|---|
| 0x00000 | CTRL | bit0 実行 (0 でリセット保持) / bit2 垂直ミラー / bit3 CHR-RAM / [7:4] マッパー番号 / [11:8] PRG 16KB 個数-1 / [15:12] CHR 8KB 個数-1 |
| 0x00010 | ID | 0x4E455301 (読み専用) |
| 0x00020 | PAD | [0]A [1]B [2]Select [3]Start [4]上 [5]下 [6]左 [7]右 |
| 0x00030 | FRAME | 映像のフレーム数 |
| 0x00040 | PC | CPU の PC (観測用) |
| 0x00050 | CYC | CPU の経過サイクル数 |
| 0x00060 | PFRM | PPU のフレーム数 |
| 0x00070 | LOAD | 書き込み窓の位置 [2:0] PRG 32KB 単位 / [7:4] CHR 8KB 単位 |
| 0x08000〜 | WRAM | 内蔵 RAM の読み出し (1 語 1 バイト) |
| 0x10000〜 | FB | 画面バッファ (段A のテスト用) |
| 0x20000〜0x27FFC | PRG | 32KB の窓。1 語 = 4 バイト |
| 0x30000〜0x37FFC | CHR | 8KB の窓。1 語 = 1 バイト |

CTRL の bit0 以外は `tools/rom2c.py` が作る `ROM_CTRL` をそのまま書く。

## 各ブロックの要点

- **cpu6502.v**: 命令ごとのサイクル数が実機と同じ (ページまたぎ・分岐・空読み/空書きも)。10 進モード無し、非公式命令は 2 サイクルの NOP。
  NMI / IRQ は命令の最後の 1 つ前のサイクルの終わりで見る (実機と同じ)。
- **ppu.v**: 背景の読み出し・シフト・スクロールの時刻は olcNES と同じ。スプライトはドット 65〜128 で評価、257〜320 で模様読み、321 で表示中へ。
  列の比較は 9bit で引く (8bit だと X=255 付近が左端に折り返す)。アドレス線 A12 を mapper に出す。
- **apu.v**: フレームカウンタのリセットは $4017 書込の 3〜4 サイクル後、IRQ は 29828〜29830。DMC はバスを 4 サイクル借りる。
  出力は実機の非線形ミキサ (表引き) → ローパス約 18kHz → 直流除去約 70Hz。
- **mapper.v**: 0 NROM / 1 MMC1 / 2 UxROM / 3 CNROM / 4 MMC3 / 7 AxROM。
  MMC3 のライン割り込みは PPU の A12 の立ち上がりで数える (A12 が 10 ドット以上 0 のあとだけ。Mesen と同じ)。カウンタは新しい版 (Sharp) の動き。
  WRAM ($6000-$7FFF) の保護: MMC1 は $E000 の bit4 (SNROM は CHR バンクの bit4 も) で読み書き禁止、
  MMC3 は $A001 の bit7 で有効・bit6 で書き込み禁止。読めないときは開きバス (番地の上位 1 バイト) を返す。
  バスの衝突は真似しない。

## 検証 (sim)

```
bash sim/run_sim.sh <tb 名>
```

| tb | 中身 |
|---|---|
| tb_stageA | AXI で画面バッファを書き、映像 1 フレーム 921,600 画素を全照合 |
| tb_cpu_nestest | nestest の正解ログと PC/A/X/Y/P/SP/CYC を照合 (`python tools/nestest_prep.py` が先) |
| tb_nes_nestest | AXI だけで nestest を実行し $02/$03 を読む |
| tb_ppu_nestest | nestest のメニュー画面を描く |
| tb_pad | $4016/$4017 の読み出し (`tools/pad_test_gen.py`) |
| tb_apu | 440Hz の周波数測定 (`tools/apu_test_gen.py`) |
| tb_rom | 任意の ROM を回し、画面を PPM・ネームテーブルを文字で出す |

tb_rom の使い方:
```
python tools/rom_prep.py roms/xxx.nes [フレーム数] [ボタン(16進) フレーム [ボタン2 フレーム2]]
bash sim/run_sim.sh tb_rom
python tools/ppm2png.py sim/simbuild/frame.ppm sim/simbuild/frame.png 2
```
blargg の $6000 の結果、または描画中に画面が 30 フレーム変わらなければ早く終わる。
環境変数 `HEXDIR` / `SIMDIR` で置き場所を分ければ並列に回せる。

結果:
- blargg sprite_hit_tests 01〜11、apu_test 1〜8: 全 PASS
- Holy Mapperel 13 本: 全本でマッパー判定と PRG・IRQ・CHR が正常。
  WRAM の保護を入れて MMC1・MMC3 の結果も 0000 (保護なしでは MMC1 = 5000/1000、MMC3 = 2000)。実機の MMC1 (SNROM) でも 0000
- blargg mmc3_test: 1・2・3・5 PASS。6 は古い版 (NEC) 用で対象外。
  4 (scanline_timing) は小テスト 3 で不合格 = 割り込みが 1〜2 ドット遅い (1 ドット精度のテスト。原因未確認)。
  CPU の割り込み受付を「命令の最後の 1 つ前のサイクル」に直して、1 サイクル早かったのは解消
- Thwaite / Concentration Room: タイトル・導入場面が正しく描ける

## 合成

```
E:\vivado\2025.2\Vivado\bin\vivado.bat -mode batch -source E:/fpga/kria260/kv260_nes/vivado.tcl
```

| | 段F | 段G | 段G + WRAM 保護 | 段H (HDMI の音) |
|---|---|---|---|---|
| 所要時間 | 9 分 46 秒 | 11 分 52 秒 | 12 分 33 秒 | 11 分 13 秒 |
| WNS / WHS | +2.948 / +0.016 | +1.436 / +0.017 | +1.049 / +0.013 | +0.932 / +0.024 |
| LUT | 3301 | 3616 (3.09%) | 3623 (3.09%) | 3698 (3.16%) |
| BRAM | 25 | 105.5 (73.3%) | 105.5 (73.3%) | 105.5 (73.3%) |
| DSP | 2 | 2 | 2 | 2 |

## 実機 (Vitis GUI を使わない)

1. `python tools/rom2c.py roms/games/thwaite.nes roms/games/croom.nes ...` → `vitis_src/rom_data.h` (git 外)
   複数渡すと起動時にゲームの一覧 (メニュー) が出る。1 本ならすぐ始まる
2. `bash tools/build_elf.sh` → `E:/Xilinx/project_vitis/kv260_nes/nes.elf` (kv260_chip8 の BSP で gcc を直接呼ぶ)
3. XSA を `E:/Xilinx/project_vitis/kv260_nes/hw/` に展開し、
   `python ../kaleidoscope/tools/make_psu_nousb.py hw/psu_init.tcl hw/psu_init_nousb.tcl` (USB の 4 行を外す)
4. hw_server を起動して
   `E:/vivado/2025.2/Vitis/bin/xsdb.bat tools/xsdb_run.tcl <hw/design_1_wrapper.bit> <nes.elf> <hw/psu_init_nousb.tcl>`
   (起動モードを JTAG にしてリセット → PL 書込 → psu_init → ELF 起動。FSBL 不要)
5. 操作は `python tools/nes_pad.py COM14` (おすすめ)。小さな窓が開き、押している間ずっと押下になる。
   Xbox のゲームパッドも使える (pygame が要る。十字キー/左スティック=方向、A・Y=A、B・X=B、メニュー=Start、ビュー=Select)。
   キー: 矢印/wasd=方向、x=A、z=B、Enter=Start、スペース=Select、F2=ゲームの一覧へ、F5=リセット、Esc=終了。
   パッドの LB でもゲームの一覧へ戻る。パッドは窓を開いたあとにつないでも使える。
   Tera Term (COM14, 115200) でも操作できるが、「押した」しか届かないので 1 回 12 フレーム押したままの扱いになる
   (キー: x/k=A、z/j=B、スペース=Select、Enter=Start、wasd/矢印=方向、r=リセット)。

メニュー: 十字キーの上下で選び、A か Start で開始。ゲーム中は LB・F2・m キー、または Select+Start を 1 秒押し続けると一覧に戻る。
CPU を止めると PPU も止まって画面バッファに書かないので、PS が FB 窓に 8x8 の文字 (`vitis_src/font8x8.h`、
dhepper/font8x8 の Public Domain フォント) で一覧を書く。回路の変更は無い。

COM14 は 1 つのプログラムしか開けない (nes_pad.py・Tera Term・シリアル記録のどれか 1 つ)。

## はまったところ

- xsim で連結式の中で同じ関数を何度も呼ぶと x になる → 変数に受けてから組む。
- xsim で狭い reg を広いポートにつなぐと上位が x になる (PC が x で止まった。RTL は無実)。
- 初期値の無いレジスタ / RAM は sim で x のまま (ce の積算が回らない) → 0 で初期化。
- apu_test 4/5/6: フレームカウンタのリセット遅れと IRQ の時刻・優先 → テストのソースを読んで直した。
- Holy Mapperel は結果が出るまで 110〜390 フレーム。150 フレームで切ると灰色画面で判定できない。
- MMC3 をドット 260 で数える近似では mmc3_test が全滅 ($2006 で A12 を動かすテストがある)。
- HDMI の音: FIFO が空くたびに 100MHz 側から値を入れると、空きの知らせが遅れて 3 個ずつ固まって入り、
  値の間隔が実質 1/16kHz になった (tb_hdmi_audio で発見)。拾う時刻を DP 側のクロックで 48kHz に固定して解決。
- 見本の shift_register_vector.v は generate の中で delay_gen[i+1] を参照し、xsim が elaborate できない → 配列で書き直した。
- 入れ直した Vivado で、部品の合成が「Failed to create directory 'C'」(tclapp::load_apps) で 1 度失敗。流し直すと通った (原因不明)。
  合成中にシェルを project_1/ の中に置くと、Vivado が古いフォルダを消せず止まる。
- pygame (SDL) は自分の窓が無いとゲームパッドの「つないだ / 抜いた」の知らせを捨てる。
  nes_pad.py は tkinter の窓なので `SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1` を pygame の読み込み前に入れる。
