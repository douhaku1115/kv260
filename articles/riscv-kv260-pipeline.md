---
title: "「RISC-Vで学ぶコンピュータアーキテクチャ」のパイプラインプロセッサをKV260で動かす"
emoji: "🔧"
type: "tech"
topics: ["fpga", "kv260", "riscv", "vivado", "verilog"]
published: true
---

## はじめに

「RISC-Vで学ぶコンピュータアーキテクチャ」（東京大学出版会）の教科書に載っている**4段パイプラインRISC-Vプロセッサ**を、Xilinx Kria KV260上で動作させました。

教科書のコードはArty A7等の教育用ボード向けですが、KV260ではクロック供給やデバッグ方法が異なるため、移植にいくつかハマりポイントがあります。本記事ではその過程をまとめます。

**結果**: VIOで計算結果 `0x13BA`（= 5050 = 0+1+2+...+100）を確認

## 環境

| 項目 | 内容 |
|------|------|
| ボード | Kria KV260 (xck26-sfvc784-2LV-c) |
| ツール | Vivado 2025.1 |
| ホストPC | Ubuntu, RTX 5070 Ti |
| KV260 OS | Linux (PetaLinux系) |
| 接続 | JTAG + SSH (192.168.0.x) |

## 教科書のプロセッサ構成

教科書Chap9の `m_proc8_F` は以下の構成を持つ4段パイプラインプロセッサです（MEMはEX段に併合）。

```
[IF: フェッチ] → [ID: デコード/レジスタ読み] → [EX: 実行(+MEM)] → [WB: ライトバック]
      P1_*               P2_*                       P3_*
```

### 主な特徴

- **4段パイプライン**: IF → ID → EX → WB（MEMはEX段に併合）
- **データフォワーディング**: EX段で前の命令の結果を直接バイパス
- **分岐予測**: 静的「Not Taken」（常にPC+4をフェッチ、ミス時2サイクルペナルティ）
- **対応命令**: R形式(add等)、I形式(addi, lw等)、S形式(sw)、B形式(bne等)、U形式(lui, auipc)、J形式(jal)

### テストプログラム

0から100までの和（= 5050）を計算し、結果をレジスタx30に格納します。

```verilog
`MM[0]={12'd0,5'd0,3'h0,5'd10,7'h13};         // addi x10,x0,0
`MM[1]={12'd0,5'd0,3'h0,5'd3,7'h13};          // addi x3,x0,0
`MM[2]={12'd101,5'd0,3'h0,5'd1,7'h13};        // addi x1,x0,101
`MM[3]={7'd0,5'd3,5'd10,3'h0,5'd10,7'h33};    // L: add x10,x10,x3
`MM[4]={12'd1,5'd3,3'h0,5'd3,7'h13};          // addi x3,x3,1
`MM[5]={~12'd0,5'd1,5'd3,3'h1,5'b11001,7'h63};// bne x3,x1,L
`MM[6]=32'h00050f13;                          // addi x30,x10,0 (HALT)
```

## 教科書コード → KV260 の変更点

教科書のコードはArty A7等を想定しており、KV260ではそのまま動きません。

| 項目 | 教科書 (Arty等) | KV260 |
|------|-----------------|-------|
| クロック | PL外部ピン (XDC指定) | Zynq PS の `pl_clk0` (100MHz) |
| 結果確認 | VIO IP (直接インスタンス) | VIO IP + Zynq PS クロック |
| XDC制約 | 必要 | 不要（ボード定義で処理） |
| `$finish` | シミュレーション終了用 | 削除（実機では不要） |

### KV260固有の問題: PLクロック

KV260はPL側に外部クロックピンがありません。クロックはZynq UltraScale+ PSの`pl_clk0`から供給されます。そのため、**ブロックデザインでZynq PSをインスタンス化**してクロックを取り出す必要があります。

## プロジェクト構成

```
kv260/
├── src/
│   ├── main_vio.v      # プロセッサ + VIOトップモジュール
│   └── asm.txt          # テストプログラム
└── create_vio_full.tcl  # Vivadoプロジェクト自動生成スクリプト
```

### トップモジュール

```verilog
module m_top_kv260();
  wire w_clk;
  wire [31:0] w_rslt;
  clk_bd_wrapper m0 (.pl_clk0(w_clk));  // Zynq PSからクロック取得
  m_proc8_F m1 (w_clk, w_rslt);         // RISC-Vプロセッサ
  vio_0 m2 (w_clk, w_rslt);             // VIOで結果観測
endmodule
```

ポイントは `clk_bd_wrapper` です。これはブロックデザインで作成したZynq PSのラッパーで、`pl_clk0`のみを出力します。AXIポートは全て無効化しています。

### TCLスクリプト（抜粋）

```tcl
# Zynq PSを追加（クロック供給のみ）
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 zynq_ultra_ps_e_0
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
  -config {apply_board_preset "1"} [get_bd_cells zynq_ultra_ps_e_0]

# AXIポート全無効（クロックだけ使う）
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0 {0} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} \
  CONFIG.PSU__USE__M_AXI_GP2 {0} \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
] [get_bd_cells zynq_ultra_ps_e_0]

# クロックを外部ポートとして公開
create_bd_port -dir O -type clk pl_clk0
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_ports pl_clk0]
```

## ビルドと書き込み

### 1. プロジェクト生成

```bash
cd /path/to/kv260
vivado -mode batch -source create_vio_full.tcl
```

### 2. ビットストリーム生成

```bash
vivado -mode batch -source - <<'EOF'
open_project vivado/riscv_kv260_vio2/riscv_kv260_vio2.xpr
launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
EOF
```

### 3. KV260への書き込み

```bash
# ホストPCからbitファイルを転送
scp -O vivado/riscv_kv260_vio2/riscv_kv260_vio2.runs/impl_1/m_top_kv260.bit \
  dou@192.168.0.15:/home/dou/

# KV260上でFPGAにロード
ssh dou@192.168.0.15
sudo fpgautil -b /home/dou/m_top_kv260.bit
```

## ハマりポイント

### 1. scp が動かない（sshは動く）

**症状**: `ssh`でログインできるが、`scp`や`sftp`がフリーズまたはパスワードエラー

**原因**: OpenSSH 9.0以降、scpのデフォルトプロトコルがSFTPベースに変更された。KV260側のSFTPサブシステムが未設定。

**解決策**: レガシーSCPプロトコルを使う

```bash
scp -O file.bit dou@192.168.0.15:/home/dou/
```

### 2. devmem でカーネルパニック

**症状**: `sudo devmem 0xA0000000 32` でカーネルがフリーズ

**原因**: AXI GPIO版のデザインで、PS-PLのAXIインターフェースが正しく初期化されていない。`fpgautil`はPLのみ書き換えるため、PS側のAXIマスターポートが有効化されない。

**教訓**: KV260でAXI経由のPS-PL通信を行うには、適切なデバイスツリーオーバーレイとドライバが必要。単純な`devmem`アクセスは危険。

### 3. VIOが検出されない (debug hub not found)

**症状**: JTAG経由でProgram Device後、Hardware ManagerでVIOが見えない

```
INFO: [Labtools 27-1434] Device xck26 is programmed with a design 
that has no supported debug core(s) in it.
WARNING: [Labtools 27-3361] The debug hub core was not detected.
```

**原因**: `pl_clk0`がPS側で無効化されていた。VIOのデバッグハブはフリーランニングクロックが必要。

**解決策**: `fpgautil`経由でロードした後、PLクロックを有効化する。

```bash
# PLクロックレジスタを確認
sudo devmem 0xFF5E00C0 32
# → 0x00010A00 (bit24 = 0: クロック無効)

# bit24を立ててクロック有効化
sudo devmem 0xFF5E00C0 32 0x01010A00
```

その後、Vivado Hardware Managerで `refresh_hw_device` するとVIOが検出される。

### 4. JTAG Program Device ではVIOが動かない

**症状**: JTAGでProgram Deviceした後、VIOが検出されない

**原因**: JTAGはPLファブリックのみを書き換え、PSの設定（クロック出力等）は変更しない。`pl_clk0`が無効のままだとVIOのデバッグハブが動作しない。

**解決策**: `fpgautil`経由でロードする（PS-PLインターフェースが正しく初期化される）。または上記の`devmem`でPLクロックを手動有効化する。

## 動作確認

fpgautil でロード＆PLクロック有効化後、Vivado TCLコンソールで：

```tcl
# probeファイルを設定
set_property PROBES.FILE {.../m_top_kv260.ltx} [get_hw_devices xck26_0]
refresh_hw_device [get_hw_devices xck26_0]

# VIO確認
get_hw_vios
# → hw_vio_1

# 結果読み取り
get_property INPUT_VALUE [get_hw_probes w_rslt]
# → 000013ba
```

**0x13BA = 5050** --- 0+1+2+...+100 の計算結果が正しく得られました。

## 続編: 5段パイプライン版 (m_proc9)

同じ枠組みで、教科書のもう一段深い**5段パイプライン版 `m_proc9`**（code6-27）も動かしました。4段版（`m_proc8_F`、MEMをEXに併合）に対し、`m_proc9` は **MEM段を独立**させた古典的な5段（IF/ID/EX/MEM/WB）です。主な違いは次の通りです。

```
4段(m_proc8_F): [IF] → [ID] → [EX(+MEM)] → [WB]          (P1 / P2 / P3)
5段(m_proc9)  : [IF] → [ID] → [EX] → [MEM] → [WB]        (P1 / P2 / P3 / P4)
```

| 項目 | 4段 (m_proc8_F) | 5段 (m_proc9) |
|------|-----------------|----------------|
| パイプライン段 | 4 (IF/ID/EX/WB) | 5 (IF/ID/EX/MEM/WB) |
| パイプラインレジスタ | P1/P2/P3 | P1/P2/P3/P4 |
| ライトバック | P3段 | **P4段** |
| フォワーディング | P3から1段 | **P3とP4から2段** |
| load-useハザード | （なし） | **1サイクルstall** (`w_lduse`) |

### 移植で必要だった唯一の変更

教科書の `m_proc9` は結果出力ポートを持たないため、4段版と同じく **結果を取り出す `r_dout` を追加**します。合計はプログラム末尾の `HALT`（`addi x30,x10,0`）で `x30` に入りますが、5段ではライトバックが **P4段**なので、capture条件も P4 を見ます。

```verilog
// 4段(m_proc8_F): P3でx30書き込み時にcapture
always @(posedge w_clk)
  r_dout <= (!P3_s & !P3_b & P3_v & P3_rd==30) ? w_rt : r_dout;

// 5段(m_proc9): ライトバックがP4段なのでP4を見る
always @(posedge w_clk)
  r_dout <= (!P4_s & !P4_b & P4_v & P4_rd==30) ? w_rt : r_dout;
```

レジスタファイルの書き込みポートも P3_rd → **P4_rd**、フォワーディングは P3 と P4 の2段からのバイパスになります（教科書の `m_proc9` 本体がそのまま対応済み）。トップ・命令メモリ・VIO・クロックBDは4段版を流用し、プロセッサ本体だけ差し替えれば済みます。

### 結果

ビルド（WNS +5.39ns、エラーなし）後、4段版と全く同じ手順（`fpgautil` → `devmem 0xFF5E00C0` → VIO）で確認：

```
get_property INPUT_VALUE [get_hw_probes w_rslt]
# → 000013ba
```

**5段でも `0x13BA`（5050）** が得られ、パイプライン段数を増やしても正しく動作することを確認できました。一度KV260向けの枠組み（PSクロック供給＋VIO＋fpgautil手順）を整えてしまえば、教科書の他のプロセッサ版も本体を差し替えるだけで動かせます。

## 続編: 分岐予測 (BTB + bimodal / gshare)

5段 `m_proc9` のPC選択を、教科書7章の**動的分岐予測**に差し替えました。`r_pc`（フェッチ段）で予測器を引いて分岐先を先取りフェッチし、分岐がP2（EX）で確定したときに外していればフラッシュ＆リダイレクトします。

- **BTB**（`m_btb`, code7-4）: 分岐先キャッシュ。`r_pc` で引いて予測分岐先を得る
- **bimodal**（`m_bimodal`, code7-11）: 2bit飽和カウンタ。分岐ごとに taken/not-taken を学習
- **gshare**（`m_gshare`, code7-13）: 分岐履歴レジスタ `r_bhr`（5bit）をPHTアドレスとXORして引く。相関する分岐に強い

### 効果は「結果」ではなく「ミス予測回数」で観測する

ここが移植上の肝でした。**分岐予測を入れても計算結果は 5050 のまま変わりません**。VIOで結果だけ読んでも、予測が効いているかは一切分かりません。そこで観測対象を増やし、VIOに **結果 / ミス予測回数 / 分岐実行回数** の3本を出しました。

もう一つ問題があります。教科書の `HALT`（`addi x30,x10,0`）は実際には停止せず、命令メモリ末尾で先頭へ折り返してプログラムが再実行されるため、カウンタが累積して読めません。そこで **HALTがコミットしたら以後フェッチを止める `r_halt`** を追加し、カウンタを1回分の値で固定しました。

```verilog
// 真のHALT: x30書き込みがコミットしたら以後フェッチを止める
reg r_halt = 0;
always @(posedge w_clk)
  if (!P4_s & !P4_b & P4_v & P4_rd==30) r_halt <= 1;
// フェッチ段: r_halt中は新規命令を流さない
{P1_v, P2_v} <= {!w_miss & !r_halt, !w_miss & P1_v};
```

### bimodal の結果（Σ 0..100）

`bne` ループ1個（taken 100回＋not-taken 1回）のΣプログラムで比較します。予測なし（常にPC+4）は取られる分岐ごとに毎回外すので約100回ミスします。

| | ミス予測 | 分岐 | 結果 |
|---|---|---|---|
| 予測なし (static not-taken) | 100 | 101 | 5050 |
| **BTB + bimodal** | **2** | 101 | 5050 |

ウォームアップ（初回）とループ脱出の2回だけに削減。KV260実機VIOで `r_miss=2` を確認しました。

### gshare の結果（ネストループ）

gshareの効果を見るには相関する分岐が要るので、**ネストループ**（code7-10、内ループ4回×外ループ101回、結果505）を使います。内ループの分岐は `T T T N` を繰り返すパターンで、bimodalは外ループのたびに脱出を外します。gshareは履歴 `r_bhr` でこのパターンを区別できます。

| 予測器 | ミス予測 | 分岐 | 結果 |
|---|---|---|---|
| BTB + bimodal | 104 | 505 | 505 |
| **BTB + gshare** | **9** | 505 | 505 |

bimodalの104回ミスを、gshareは **9回** まで削減。KV260実機VIOで `r_dout=0x1F9`（505）/ `r_miss=9` / `r_brn=505` を確認しました。

### 検証フロー

合成は10分ほどかかるので、先に **iverilog** で論理を確定させてからビルドしました（XilinxのVIO/クロックBDはスタブに差し替え）。手トレースとシミュレーションと実機の3つで数値が一致しています。

```
# シミュレーション（要 iverilog）
cd src && iverilog -g2012 -o /tmp/g.out main_vio_gshare.v sim_bp.v && vvp /tmp/g.out
# => RESULT=505  MISS=9  BRANCH=505
```

## 続編: 命令キャッシュ (m_proc8_c2)

教科書8章の**メモリ階層**も動かしました。ここは4段プロセッサ `m_proc8` をベースに、**直接マップ命令キャッシュ** `m_cache1`（code8-7、32エントリ）と、**遅延つき主記憶** `m_imem`（code8-2、`D_DELAY=5` サイクル待ち）を組み合わせた `m_proc8_c2`（code8-8）です。

- キャッシュ**ヒット**：その場で命令を返す（ストールなし）
- キャッシュ**ミス**：`w_re` で主記憶をリクエストし、返るまで `w_stall`。返った命令をキャッシュに書く

### キャッシュには「遅いメモリ」が要る

これまでの版の命令メモリは1サイクルで読めるので、そこにキャッシュを足しても意味がありません。キャッシュの効果を出すには、**わざと遅い主記憶**（`m_imem`、5サイクル待ち）を用意する必要があります。これが8章のキモでした。

### 効果はサイクル数で観測する

分岐予測と同じく、キャッシュを入れても結果（5050）は変わりません。そこでVIOに **結果 / 総サイクル数 / ミス回数** の3本を出し、HALTで `r_halt` を立ててサイクルカウンタを1回分に固定します。

| | 総サイクル | 主記憶アクセス | 結果 |
|---|---|---|---|
| キャッシュなし（毎フェッチ主記憶待ち） | 2550 | 510 | 5050 |
| **m_proc8_c2 + m_cache1** | **560** | **10** | 5050 |

各フェッチが5サイクルかかるキャッシュなし（510×5=2550）に対し、ループがキャッシュにヒットするキャッシュ版は **約4.5倍高速**。主記憶アクセスも 510→10（触れた命令の種類数）まで減ります。KV260実機VIOで `r_dout=0x13BA`（5050）/ `r_cyc=560` / `r_miss=10` を確認しました。

なお教科書の code8-8 は `P3_s`/`P3_b`（ストア／分岐フラグ）のパイプライン更新が抜けており（前段の c1=code8-4 にはある）、そのままだと分岐がレジスタを誤って書きます。本実装では補っています。結果の取り出しは4段なので、ライトバックの **P3段**（`!w_stall & P3_rd==30`）で capture します。

```
# シミュレーション（要 iverilog、asm.txt = Σ0..100）
cd src && iverilog -g2012 -o /tmp/c.out main_vio_cache.v sim_cache.v && vvp /tmp/c.out
# => RESULT=5050  CYCLES=560  MISS=10
```

## まとめ

教科書のRISC-Vプロセッサ（4段パイプライン、フォワーディング付き）をKV260で動作させました。

教育用ボード向けのコードをKV260に移植する際のポイント：

1. **クロック**: KV260はPL外部クロックがないため、Zynq PSの`pl_clk0`をブロックデザイン経由で取得する
2. **デバッグ**: VIOを使う場合、`fpgautil`でロード後にPLクロック（`0xFF5E00C0`）の有効化が必要
3. **転送**: OpenSSH 9.0以降は `scp -O` を使う
4. **AXI経由の読み取り**: 単純な`devmem`は危険。VIOの方が確実

教科書のコードがそのままでは動かない部分が多く、KV260特有の知識が必要ですが、一度環境を整えれば他の章のプロセッサも同様の手順で動かせます。本記事では続けて **5段版 m_proc9**、**7章の分岐予測（BTB+bimodal / gshare）**、**8章の命令キャッシュ（m_proc8_c2）** まで動かしました。分岐予測やキャッシュのように結果（5050）が変わらない機能は、VIOに **ミス予測回数** や **サイクル数** などの観測値を足し、教科書のHALTを真の停止に変えてカウンタを固定するのがポイントです。

## ソースコード

https://github.com/douhaku1115/kv260/tree/main/riscv_kv260

## 参考

- 「RISC-Vで学ぶコンピュータアーキテクチャ」東京大学出版会
- [Kria KV260 Vision AI Starter Kit](https://www.amd.com/en/products/system-on-modules/kria/k26/kv260-vision-starter-kit.html)
- [Vivado Debug and Programming User Guide (UG908)](https://docs.amd.com/r/en-US/ug908-vivado-programming-debugging)
- [Zynq UltraScale+ Technical Reference Manual (UG1085)](https://docs.amd.com/r/en-US/ug1085-zynq-ultrascale-trm)
