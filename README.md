# KV260 単一サイクル MIPS プロセッサ

Xilinx KV260 の PL (FPGA) 上に単一サイクル MIPS プロセッサを実装し、
PS (ARM Cortex-A53) から AXI4-Lite 経由で制御・デバッグするプロジェクト。

## アーキテクチャ概要

```
PS (ARM) ──AXI4-Lite──► mips_axi ──► mips_top
                                         │
                              ┌──────────┼──────────┐
                              ▼          ▼          ▼
                            imem      control    datapath
                         (命令メモリ) (制御ユニット)    │
                                               ┌──┴───┐
                                           regfile   ALU
                                               │      │
                                             dmem ◄───┘
                                          (データメモリ)
```

### AXI レジスタマップ (ベース: 0xA000_0000)

| オフセット | 名前       | R/W | 内容                              |
|-----------|-----------|-----|----------------------------------|
| 0x00      | CTRL      | R/W | bit0=reset, bit1=run             |
| 0x04      | PC        | R   | 現在のプログラムカウンタ             |
| 0x08      | DBG_ADDR  | R/W | 読み出すレジスタ番号 (0-31)          |
| 0x0C      | DBG_DATA  | R   | DBG_ADDR で指定したレジスタ値        |
| 0x10      | IMEM_ADDR | W   | 命令メモリ書き込みアドレス (ワード単位) |
| 0x14      | IMEM_DATA | W   | 命令メモリ書き込みデータ (書き込みトリガ) |

### 実行フロー

1. `CTRL = 0x01` (reset=1) — PC を 0 にリセット
2. `IMEM_ADDR / IMEM_DATA` に命令を順番に書き込む
3. `CTRL = 0x02` (run=1) — MIPS 実行開始
4. 一定時間後 `CTRL = 0x00` (halt) — 実行停止
5. `DBG_ADDR / DBG_DATA` でレジスタ値を読み出す

---

## 実装済み命令セット

### Step 1 — 基本演算命令

| 命令  | 形式 | opcode / funct | 動作              |
|------|------|----------------|-----------------|
| addi | I型  | op=001000      | rt = rs + imm   |
| add  | R型  | fn=100000      | rd = rs + rt    |
| sub  | R型  | fn=100010      | rd = rs - rt    |
| and  | R型  | fn=100100      | rd = rs & rt    |
| or   | R型  | fn=100101      | rd = rs \| rt   |
| slt  | R型  | fn=101010      | rd = (rs < rt)  |

### Step 2 — メモリアクセス・条件分岐

| 命令  | 形式 | opcode   | 動作                             |
|------|------|----------|--------------------------------|
| lw   | I型  | op=100011 | rt = mem[rs + imm]             |
| sw   | I型  | op=101011 | mem[rs + imm] = rt             |
| beq  | I型  | op=000100 | if (rs==rt) PC += imm<<2       |

### Step 3 — ジャンプ命令

| 命令  | 形式 | opcode / funct | 動作                             |
|------|------|----------------|--------------------------------|
| j    | J型  | op=000010      | PC = {PC+4[31:28], addr26, 00} |
| jal  | J型  | op=000011      | $31=PC+4, PC=ジャンプ先          |
| jr   | R型  | fn=001000      | PC = rs                        |

### Step 4 — 即値操作・条件分岐拡張

| 命令  | 形式 | opcode   | 動作                             |
|------|------|----------|--------------------------------|
| lui  | I型  | op=001111 | rt = {imm, 16'b0}              |
| ori  | I型  | op=001101 | rt = rs \| zero_extend(imm)    |
| bne  | I型  | op=000101 | if (rs!=rt) PC += imm<<2       |

> **lui + ori** の組み合わせで 32bit 即値をレジスタにロードできる

---

## ファイル構成

```
kv260_mips/
├── rtl/
│   ├── mips_axi.v    — AXI4-Lite スレーブラッパー
│   ├── mips_top.v    — MIPS トップモジュール
│   ├── control.v     — 制御ユニット (メインデコーダ + ALUデコーダ)
│   ├── datapath.v    — データパス (PC・レジスタ・ALU・メモリ)
│   ├── imem.v        — 命令メモリ (4096ワード / 16KB, デュアルポートRAM)
│   ├── dmem.v        — データメモリ (lw/sw 用)
│   ├── regfile.v     — レジスタファイル ($0〜$31)
│   └── alu.v         — ALU (add/sub/and/or/slt/or)
├── vitis_src/
│   └── main.c        — PS 側テストプログラム (Step 1〜4)
├── rebuild.tcl       — Vivado バッチ再ビルドスクリプト
└── README.md         — 本ファイル
```

---

## ビルド・実行手順

### Vivado (RTL 変更後)

```tcl
# Vivado バッチモードで再ビルド
vivado.bat -mode batch -source rebuild.tcl
```

`rebuild.tcl` の内容:
1. インクリメンタル合成チェックポイントを無効化
2. BD 経由で mips_axi の OOC 合成を再実行
3. 合成 → 配置配線 → ビットストリーム生成
4. XSA エクスポート (`project_1/design_1_wrapper.xsa`)

### Vitis (XSA 更新後)

RTL を変更してビットストリームを更新した場合、**新しい Vitis ワークスペースを作成する**のが最も確実。

1. 新ワークスペース作成
2. Platform: `project_1/design_1_wrapper.xsa` から作成
3. Application: Empty C Application を作成
4. `vitis_src/main.c` を src にコピー
5. Platform Build → App Build → Run

---

## 制御信号ビット割り当て (control.v)

```
controls[8:0]:
  [8] imm_zero  — 1=ゼロ拡張即値 (ori), 0=符号拡張即値
  [7] reg_write — レジスタ書き込み許可
  [6] reg_dst   — 書き込み先: 1=rd (R型), 0=rt (I型)
  [5] alu_src   — ALU 入力 B: 1=即値, 0=レジスタ
  [4] branch    — beq 分岐有効
  [3] mem_write — データメモリ書き込み (sw)
  [2] mem_to_reg— 書き戻し元: 1=メモリ, 0=ALU 結果
  [1] branch_ne — bne 分岐有効
  [0] jump      — j/jal ジャンプ
```

---

## テスト結果 (実機確認済み)

| Step | テスト内容              | 結果  |
|------|------------------------|-------|
| 1    | addi, add, sub, and, or, slt | ✓ |
| 2    | lw, sw, beq             | ✓    |
| 3    | j, jal, jr              | ✓    |
| 4    | lui, ori, bne (ループ5回) | ✓   |
