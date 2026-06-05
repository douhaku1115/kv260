---
title: "自作MIPSプロセッサをKV260で5段パイプライン化する（例外処理まで）"
emoji: "⚙️"
type: "tech"
topics: ["fpga", "kv260", "mips", "verilog", "computerarchitecture"]
published: true
---

## はじめに

Xilinx Kria KV260 の PL（FPGA）上に **MIPS プロセッサを自作**し、単一サイクル版から **5段パイプライン版** へ段階的に発展させました。教科書のコードを移植するのではなく、命令を1つずつ追加しながらスクラッチで実装しているのが特徴です。

本記事では特に難所だった **パイプライン化（フォワーディング・ハザード・例外処理）** の設計をまとめます。

**到達点**: Step 1〜12g-2 まで実機動作確認済み。基本演算からメモリ・分岐・乗除算・サブワードアクセス・**精密例外（syscall/overflow）** までパイプラインで動作。

## 環境

| 項目 | 内容 |
|------|------|
| ボード | Kria KV260 (xck26-sfvc784-2LV-c) |
| ツール | Vivado / Vitis 2025.2 |
| 動作クロック | 20MHz（PS の pl_clk0 → clk_wiz） |
| PS-PL通信 | AXI4-Lite (M_AXI_HPM0_FPD) |
| デバッグ | ベアメタル C（Vitis）+ UART |

## 全体構成

PS（ARM Cortex-A53）の C プログラムから AXI4-Lite 経由で MIPS コアを制御します。命令メモリへの書き込み、実行開始/停止、レジスタ値の読み出しを AXI レジスタ経由で行います。

```
PS (ARM) ──AXI4-Lite──► mips_axi ──► mips_top_pipe
                                         │
                              ┌──────────┼──────────┐
                              ▼          ▼          ▼
                            imem      control    datapath
                         (命令メモリ) (制御ユニット) (5段パイプライン)
```

### AXI レジスタマップ（ベース: 0xA000_0000）

| オフセット | 名前 | R/W | 内容 |
|-----------|------|-----|------|
| 0x00 | CTRL | R/W | bit0=reset, bit1=run |
| 0x04 | PC | R | 現在のプログラムカウンタ |
| 0x08 | DBG_ADDR | R/W | 読み出すレジスタ番号 (0-31) |
| 0x0C | DBG_DATA | R | DBG_ADDR で指定したレジスタ値 |
| 0x10 | IMEM_ADDR | W | 命令メモリ書き込みアドレス |
| 0x14 | IMEM_DATA | W | 命令メモリ書き込みデータ |

実行フローはシンプルです。

1. `CTRL = 0x01` で reset
2. `IMEM_ADDR/IMEM_DATA` に命令を順に書き込む
3. `CTRL = 0x02` で実行開始
4. 一定時間後に `CTRL = 0x00` で停止
5. `DBG_ADDR/DBG_DATA` でレジスタ値を確認

## 単一サイクルから5段パイプラインへ

最初は単一サイクル版（`mips_top.v`）で Step 1〜11（基本命令〜例外処理）を完成させ、その後 `mips_top_pipe.v` として5段パイプライン版に作り直しました。`mips_axi.v` がインスタンス化するモジュールを差し替えるだけで両者を切り替えられます。

```
IF → IF/ID → ID → ID/EX → EX → EX/MEM → MEM → MEM/WB → WB

IF:   imem 読み出し・PC 更新
ID:   命令デコード（control.v）+ regfile 読み出し
EX:   ALU 演算、分岐/jr 判定
MEM:  dmem アクセス（lw/sw）
WB:   regfile 書き戻し
```

パイプライン化は Step 12 として、さらに細かいサブステップに分割して進めました。各サブステップごとに Vivado ビルド → 実機テスト → git push を繰り返しています。

| サブ | 内容 |
|------|------|
| 12a | パイプラインレジスタ確立（IF/ID, ID/EX, EX/MEM, MEM/WB） |
| 12b | フォワーディング + WB→ID 同サイクルバイパス |
| 12c | lw/sw + ロードユースストール |
| 12d | beq/bne + j/jal/jr + フラッシュ |
| 12e | lui/ori/シフト/blez系/addiu 等の残り命令 |
| 12f | mult/div/HI/LO + バイト/ハーフワードアクセス |
| 12g-1 | CP0 レジスタ + mfc0/mtc0 |
| 12g-2 | syscall/overflow 例外発生（本記事のメイン） |

## ハザード対策

パイプライン化で必ずぶつかるのがハザードです。本実装では以下のように解決しました。

| ハザード種別 | 解決方法 | ペナルティ |
|------------|---------|----------|
| データ（1命令前） | EX/MEM → EX フォワーディング | 0 |
| データ（2命令前） | MEM/WB → EX フォワーディング | 0 |
| データ（3命令前, WB-ID 同時） | WB→ID バイパス | 0 |
| ロードユース（lw 直後で使用） | 1サイクルストール + フォワーディング | 1 |
| 分岐（taken） | IF/ID と ID/EX をフラッシュ | 2 |
| ジャンプ（j/jal） | IF/ID をフラッシュ | 1 |

### フォワーディングの基本形

EX 段で、ALU 入力のレジスタ番号が後段（EX/MEM, MEM/WB）の書き込み先と一致する場合、レジスタファイルを待たずに結果を直送します。

```verilog
// ForwardA (ALU 入力 a, rs 側)
if (ex_mem_reg_write && (ex_mem_write_reg != 0) && (ex_mem_write_reg == id_ex_rs))
    forward_a = 2'b10;   // EX/MEM の結果を直送（1命令前）
else if (mem_wb_reg_write && (mem_wb_write_reg != 0) && (mem_wb_write_reg == id_ex_rs))
    forward_a = 2'b01;   // MEM/WB の結果を直送（2命令前）
else
    forward_a = 2'b00;   // ID/EX のレジスタ値をそのまま
```

### 「EX 段で書いて次サイクルに読む」パターン

mult/div の HI/LO レジスタ（Step 12f）と CP0 レジスタ（Step 12g-1）は、どちらも **EX 段でレジスタに書き込み、読み出し命令（mfhi/mflo/mfc0）が1命令以上後に EX へ来る**ため、専用フォワーディングが不要です。読み出し時には既に前サイクルで書き込み済みだからです。

```verilog
// CP0 レジスタ（EX 段で mtc0 が書き込み）
always @(posedge clk) begin
    if (id_ex_is_mtc0 & ~halt) begin
        case (id_ex_rd)
            5'd12: cp0_sr    <= alu_in_rt;
            5'd13: cp0_cause <= alu_in_rt;
            5'd14: cp0_epc   <= alu_in_rt;
        endcase
    end
end
```

このとき重要なのが、**バブル/フラッシュ時に write enable を 0 にする**ことです。これを忘れるとフラッシュされた無効命令が HI/LO や CP0 を破壊します。

## 本題: パイプラインでの例外処理（Step 12g-2）

ここがパイプライン化で最も設計判断を要する部分でした。**精密例外（precise exception）** を実装します。

### 何が難しいか

単一サイクルなら「例外が起きたら PC を 0x80 に飛ばす」だけですが、パイプラインでは:

- 例外を**どのステージで検出**するか
- **EPC に何の PC を保存**するか（例外を起こした命令のアドレス）
- 例外より後にフェッチされた**若い命令をどう無効化**するか
- 例外を起こした命令自身の**副作用（レジスタ/メモリ書き込み）をどう止めるか**

を精密に調停する必要があります。

### 検出: EX 段

本実装では syscall と算術オーバーフローを EX 段で検出します。

```verilog
wire ex_exc_overflow = id_ex_exc_on_ov & ex_alu_overflow;
assign ex_exception  = (id_ex_is_syscall | ex_exc_overflow) & ~halt;
wire [4:0] ex_exc_code = id_ex_is_syscall ? 5'd8 : 5'd12; // 8=Syscall, 12=Overflow
```

syscall も add/addi/sub も分岐命令ではないので、分岐成立（`ex_take_branch`）と例外が同時に立つことはなく、調停がシンプルになります。

### EPC: pc_plus4 - 4 で導出

EPC には「例外を起こした命令の PC」が必要です。パイプラインには各ステージに `pc_plus4` を伝搬してあるので、**専用の PC レジスタを足さずに `pc_plus4 - 4`** で例外命令の PC を得られます。

```verilog
wire [31:0] ex_exc_pc = id_ex_pc_plus4 - 32'd4;  // 例外命令の PC

always @(posedge clk) begin
    if (ex_exception) begin
        cp0_epc   <= ex_exc_pc;
        cp0_cause <= {25'b0, ex_exc_code, 2'b0};  // Cause[6:2] = ExcCode
        cp0_sr    <= {cp0_sr[31:1], 1'b1};        // EXL = 1
    end
    // ... mtc0 の処理 ...
end
```

### PC リダイレクト: 例外を最優先

PC 次値選択では例外を最優先にします。優先順位は **例外 > 分岐/jr > ジャンプ > +4** です。

```verilog
localparam EXC_VEC = 32'h00000080;  // 例外ベクタ

wire [31:0] pc_next_select =
    ex_exception   ? EXC_VEC :
    ex_take_branch ? (id_ex_jr_w ? ex_jr_target : ex_branch_target) :
    id_take_jump   ? id_jump_target :
                     pc_plus4;
```

### フラッシュと副作用の抑止

例外発生時は、若い命令（IF/ID と ID/EX）をフラッシュし、さらに**例外命令自身の書き込みを抑止**します。オーバーフローした `add` は結果を書いてはいけないからです。

```verilog
// フラッシュ信号に例外を OR
wire flush_if_id = id_take_jump | ex_take_branch | ex_exception;
wire flush_id_ex = ex_take_branch | ex_exception;

// 例外命令自身の reg_write/mem_write を抑止
ex_mem_reg_write <= id_ex_reg_write & ~ex_exception;
ex_mem_mem_write <= id_ex_mem_write & ~ex_exception;
```

また、ID/EX のバブル/フラッシュ時には `id_ex_is_syscall` と `id_ex_exc_on_ov` を 0 にして、**無効命令が誤って例外を起こさない**ようにします。これはフォワーディングのバブル処理と同じ考え方です。

## 実機テスト

UART 経由で結果を確認します。syscall 例外のテストプログラムは以下です（eret はまだ未実装なので、ハンドラは値を退避して無限ループ）。

```
メイン:
  0x00: addi $1,$0,0      $1=0 (例外カウンタ)
  0x04: addi $7,$0,0      $7=0 (スキップ確認用)
  0x08: syscall           → 例外! EPC=0x08, ExcCode=8, PC→0x80
  0x0C: addi $7,$0,0x63   ★スキップされるべき
  0x10: j 0x10

ハンドラ (0x80):
  0x80: addi $1,$1,1      $1++ (到達した証拠)
  0x84: mfc0 $2,$14       $2 = EPC
  0x88: mfc0 $3,$13       $3 = Cause
  0x8C: mfc0 $4,$12       $4 = SR
  0x90: j 0x90
```

実機出力：

```
--- Test EXC: syscall exception ---
  Expected: $1=1, $2=0x08, $3=0x20, $4=0x01, $7=0 (skipped)
  $1 = 0x00000001 (1)       ← ハンドラ到達
  $2 = 0x00000008 (8)       ← EPC = syscall の PC
  $3 = 0x00000020 (32)      ← Cause: ExcCode=8 → 8<<2
  $4 = 0x00000001 (1)       ← SR: EXL=1
  $7 = 0x00000000 (0)       ← syscall 後の命令はスキップ
```

オーバーフロー例外も同様に確認できました。`addi $5,$5,1`（$5=0x7FFFFFFF=INT_MAX）でオーバーフローを起こし、$5 が書き換わらないこと（書き込み抑止）も確認しています。

```
--- Test OVF: overflow exception ---
  $2 = 0x00000010 (EPC)
  $3 = 0x00000030 (Cause = 12<<2)
  $5 = 0x7FFFFFFF (書き込み抑止でそのまま)
  $7 = 0x00000000 (スキップ)
```

## ハマりポイント

### SD カードの OS が JTAG デバッグと競合する

ベアメタルで JTAG デバッグする際、SD カードに PetaLinux イメージが入っていると、ボードがそれを起動してしまい Vitis の JTAG 接続と競合します。シリアルに `login:` プロンプトや U-Boot の `ZynqMP>` が出てきたらこのパターンです。

**対策**: 電源 OFF → SD カードを抜く → 電源 ON → Vitis で Debug。ベアメタルでは SD は不要です。

### Vitis の `Failed to detect FSBL exit`

Vitis 2025.2 で出やすい警告で、FSBL の終了をシンボルで検出できずタイムアウトするものです。多くの場合**アプリ自体は動いており、シリアルに出力が出ていれば成功**しています。出ない場合は電源サイクル後に再 Debug します。

### UserConfig.cmake への `"../main.c"` 混入

main.c をインポートすると `UserConfig.cmake` の `USER_COMPILE_SOURCES` に `"../main.c"` が自動追加されることがあり、`src/main.c` と二重コンパイルになってビルドが壊れます。混入していたら削除します。

## まとめ

自作 MIPS プロセッサを KV260 で5段パイプライン化し、フォワーディング・各種ハザード対策・**精密例外（syscall/overflow）** まで実機で動作させました。

パイプライン例外の設計ポイント：

1. **EPC は `pc_plus4 - 4`** で導出（専用 PC レジスタ不要）
2. **PC 優先順位**は 例外 > 分岐/jr > ジャンプ > +4
3. **例外命令の副作用**（reg/mem 書き込み）を `& ~ex_exception` で抑止
4. **バブル/フラッシュ時**は例外フラグ・write enable を 0 にして誤動作を防ぐ

次は eret（例外復帰）を実装して例外処理を完成させる予定です。

## ソースコード

https://github.com/douhaku1115/kv260/tree/main/kv260_mips

## 参考

- [Kria KV260 Vision AI Starter Kit](https://www.amd.com/en/products/system-on-modules/kria/k26/kv260-vision-starter-kit.html)
- David A. Patterson, John L. Hennessy「コンピュータの構成と設計（パタヘネ）」
- [MIPS Architecture For Programmers](https://www.mips.com/)
