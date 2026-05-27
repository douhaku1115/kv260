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

### Step 5 — 即値論理演算・シフト命令

| 命令  | 形式 | opcode / funct | 動作                              |
|------|------|----------------|----------------------------------|
| andi | I型  | op=001100      | rt = rs & zero_extend(imm)       |
| xori | I型  | op=001110      | rt = rs ^ zero_extend(imm)       |
| slti | I型  | op=001010      | rt = (rs < sign_imm) ? 1 : 0    |
| addiu| I型  | op=001001      | rt = rs + imm (オーバーフロー無視) |
| sll  | R型  | fn=000000      | rd = rt << shamt                 |
| srl  | R型  | fn=000010      | rd = rt >> shamt (論理)           |
| sra  | R型  | fn=000011      | rd = rt >>> shamt (算術)          |

> **sll/srl/sra** は rs フィールドを無視し、shamt[10:6] をシフト量として使用する

### Step 6 — 符号なし演算・NOR・可変シフト命令

| 命令  | 形式 | opcode / funct | 動作                                    |
|------|------|----------------|----------------------------------------|
| addu | R型  | fn=100001      | rd = rs + rt (オーバーフロー無視)         |
| subu | R型  | fn=100011      | rd = rs - rt (オーバーフロー無視)         |
| sltu | R型  | fn=101011      | rd = (rs < rt) ? 1 : 0 (符号なし比較)   |
| sltiu| I型  | op=001011      | rt = (rs < sign_imm) ? 1 : 0 (符号なし) |
| nor  | R型  | fn=100111      | rd = ~(rs \| rt)                       |
| sllv | R型  | fn=000100      | rd = rt << rs[4:0] (可変シフト量)        |
| srlv | R型  | fn=000110      | rd = rt >> rs[4:0] (論理, 可変)          |
| srav | R型  | fn=000111      | rd = rt >>> rs[4:0] (算術, 可変)         |

> **sllv/srlv/srav** はシフト量を shamt フィールドではなく **rs レジスタの下位 5bit** から取る（datapath.v で切り替え）  
> **sltiu** は即値を符号拡張した後、符号なし整数として比較する

### Step 7 — HI/LO レジスタ・乗除算命令

| 命令  | 形式 | funct  | 動作                                         |
|------|------|--------|---------------------------------------------|
| mult | R型  | 011000 | {HI,LO} = $signed(rs) × $signed(rt)         |
| multu| R型  | 011001 | {HI,LO} = rs × rt (符号なし)                 |
| div  | R型  | 011010 | LO = $signed(rs) / $signed(rt), HI = 余り    |
| divu | R型  | 011011 | LO = rs / rt (符号なし), HI = 余り            |
| mfhi | R型  | 010000 | rd = HI                                     |
| mflo | R型  | 010010 | rd = LO                                     |

> HI/LO は regfile 外の専用 32bit レジスタ。  
> **タイミング注意**: 32bit 組み合わせ除算器のクリティカルパスが約 42ns のため、クロックを 20MHz に設定している（rebuild.tcl の clk_wiz 設定）。

### Step 9 — rs と 0 の比較分岐命令

| 命令  | 形式 | opcode        | 動作                               |
|------|------|---------------|------------------------------------|
| bltz | I型  | op=000001/rt=0 | if (rs < 0) PC += imm<<2          |
| bgez | I型  | op=000001/rt=1 | if (rs >= 0) PC += imm<<2         |
| blez | I型  | op=000110     | if (rs <= 0) PC += imm<<2         |
| bgtz | I型  | op=000111     | if (rs > 0) PC += imm<<2          |

> **bltz/bgez** は opcode=0x01 (REGIMM) の共通エンコーディングで、rt フィールドで命令を区別する。  
> 分岐条件は `rs` の符号ビット (`rd1[31]`) と ゼロ判定 (`rd1==0`) から組み合わせて判定する。ALU 結果は使用しない。

### Step 8 — バイト/ハーフワードメモリアクセス命令

| 命令  | 形式 | opcode   | 動作                                          |
|------|------|----------|---------------------------------------------|
| lb   | I型  | op=100000 | rt = sign_extend(mem[rs+imm][7:0])          |
| lbu  | I型  | op=100100 | rt = zero_extend(mem[rs+imm][7:0])          |
| lh   | I型  | op=100001 | rt = sign_extend(mem[rs+imm][15:0])         |
| lhu  | I型  | op=100101 | rt = zero_extend(mem[rs+imm][15:0])         |
| sb   | I型  | op=101000 | mem[rs+imm][7:0] = rt[7:0]                 |
| sh   | I型  | op=101001 | mem[rs+imm][15:0] = rt[15:0]               |

> **ビッグエンディアン** (MIPS 標準)。バイトアドレス offset 0 が MSB 側 (mem[31:24])。  
> dmem.v はバイトイネーブル書き込み対応。`mem_size[1:0]` と `addr[1:0]` から byte_en を生成。

### Step 10 — C言語実行

RTL 変更なし。mips-linux-gnu-gcc でコンパイルした C プログラムを MIPS コアで実行する。

**コンパイル環境 (WSL Ubuntu 24.04)**

```bash
# ツールチェイン
mips-linux-gnu-gcc (Ubuntu 12.x) — ビッグエンディアン MIPS1

# コンパイルフラグ
-mips1 -mfp32 -EB -O0 -ffreestanding -nostdlib -nostartfiles -fno-pic -mno-abicalls

# -O0 を使う理由: ディレイスロットが NOP で埋まる
#   → ディレイスロット非実装の本ハードウェアで正常動作
```

**ハードウェア制約 (Cプログラム作成時の注意)**

| 制約 | 理由 |
|------|------|
| グローバル変数・static変数 **使用不可** | .data/.rodata は imem 領域に配置されるが lw は dmem しか読めない (Harvard アーキテクチャ) |
| ローカル変数 (スタック) のみ使用可 | dmem は 0x000〜0x3FF の 1KB、`$sp = 0x3FC` で初期化済み |
| `-O0` 固定 | `-O2` ではディレイスロットに有効命令が入り、本HWで結果が狂う |

**起動シーケンス (step10/crt0.S)**

```asm
_start:
    ori $sp, $0, 0x3FC   # $sp = 0x3FC (dmem 256ワード = 1KB の末尾)
    jal main
    nop                  # ディレイスロット (本HWではスキップ、無害)
_halt:
    j _halt
```

### Step 11 — 例外処理 (CP0/syscall/オーバーフロー)

CP0 コプロセッサ、syscall 命令、オーバーフロー例外、mfc0/mtc0/eret を実装。

**追加した CP0 レジスタ**

| CP0番号 | 名前 | 内容 |
|---------|------|------|
| $12 | SR (Status)  | bit0 = EXL (例外処理中フラグ) |
| $13 | Cause        | bits[6:2] = ExcCode (8=syscall, 12=Overflow) |
| $14 | EPC          | 例外発生命令の PC |

**追加した命令**

| 命令 | エンコーディング | 動作 |
|------|------------------|------|
| syscall | opcode=000000, funct=001100 | 例外発生 (ExcCode=8) |
| mfc0 rt, $rd | opcode=010000, rs=00000 | GPR[rt] ← CP0[rd] |
| mtc0 rt, $rd | opcode=010000, rs=00100 | CP0[rd] ← GPR[rt] |
| eret    | opcode=010000, rs=10000, funct=011000 | PC ← EPC, SR.EXL ← 0 |

**例外動作 (datapath.v)**

```
例外発生時 (syscall | (exc_on_ov & alu_overflow)):
  EPC    ← PC（発生した命令の PC）
  Cause  ← {24'b0, ExcCode, 2'b0}
  SR.EXL ← 1
  PC     ← EXC_VEC = 0x0000_0080  ※imem の word 32
  書き込み抑制: reg_write_actual = reg_write & ~exception
```

> **オーバーフロー対象**: `add` / `addi` / `sub` で `(a[31]==b[31]) && (result[31]!=a[31])`。`addu/addiu/subu` では発生しない（MIPS 仕様）。

**例外ハンドラ例 (imem word 32 から配置)**

```asm
0x80: addi  $1, $1, 1     # 例外回数カウント
0x84: mfc0  $26, $14      # $26(k0) = EPC
0x88: addiu $26, $26, 4   # $26 = EPC+4 (発生命令をスキップ)
0x8C: mtc0  $26, $14      # EPC ← EPC+4
0x90: eret                # PC ← EPC (戻る)
```

> ハンドラが EPC を +4 して書き戻しているため、復帰後 `mfc0 $rt, $14` は **更新後の EPC = 元PC+4** を返す点に注意。

---

### Step 12 — 5段パイプライン化 (`mips_top_pipe.v`)

単一サイクル版の `mips_top.v` を `mips_top_pipe.v` に置き換えて 5段パイプラインで実装。
`mips_axi.v` は `mips_top_pipe` をインスタンス化する（単一サイクルに戻したい場合は
`mips_top` に変更すれば良い）。

**パイプライン構成**

```
IF → IF/ID → ID → ID/EX → EX → EX/MEM → MEM → MEM/WB → WB

IF:   imem 読み出し・PC 更新
ID:   命令デコード (control.v) + regfile 読み出し
EX:   ALU 演算、分岐/jr 判定
MEM:  dmem アクセス (lw/sw)
WB:   regfile 書き戻し
```

**サブステップ実装履歴**

| サブ | スコープ | 主要追加内容 |
|------|---------|------------|
| 12a  | パイプラインレジスタ確立 | IF/ID, ID/EX, EX/MEM, MEM/WB の 4 段。`addi/add/sub` で動作確認 |
| 12b  | フォワーディング | EX/MEM→EX, MEM/WB→EX 直送 + WB→ID 同サイクルバイパス。R 型データ依存 OK |
| 12c  | メモリ + ロードユース | lw/sw 追加。`lw → 直後に lw 結果を使う` を 1 サイクルストールで吸収 |
| 12d  | 分岐・ジャンプ | beq/bne (EX 段で taken 判定, IF/ID + ID/EX フラッシュ), j/jal (ID 段, IF/ID フラッシュ), jr (EX 段, rs はフォワーディング) |
| 12e  | 残り即値/ALU/分岐 | lui (EX で `{imm16,16'b0}` 生成), ori/andi/xori (ID でゼロ拡張即値), シフト sll/srl/sra・sllv/srlv/srav (EX でオペランド入替), bltz/bgez/blez/bgtz (EX で rs と 0 比較), addiu/addu/subu/sltu/sltiu/nor |
| 12f  | 乗除算・サブワード | mult/multu/div/divu (EX で HI/LO 書込み、フォワーディング後オペランド), mfhi/mflo (EX で HI/LO 読出→WB), lb/lbu/lh/lhu/sb/sh (MEM で byte_en 生成・スライス+符号/ゼロ拡張) |

**ハザード処理**

| ハザード種別 | 解決方法 | ペナルティ |
|------------|---------|----------|
| データ (1 命令前) | EX/MEM → EX フォワーディング | 0 サイクル |
| データ (2 命令前) | MEM/WB → EX フォワーディング | 0 サイクル |
| データ (3 命令前, WB-ID 同サイクル) | WB→ID バイパス | 0 サイクル |
| ロードユース (`lw` 直後で使用) | 1 サイクルストール + MEM/WB→EX フォワーディング | 1 サイクル |
| 分岐 (taken) | IF/ID と ID/EX をフラッシュ | 2 サイクル |
| ジャンプ (j/jal) | IF/ID をフラッシュ | 1 サイクル |
| レジスタジャンプ (jr) | IF/ID と ID/EX をフラッシュ | 2 サイクル |

**フラッシュ実装**

- `flush_if_id = id_take_jump | ex_take_branch` — IF/ID 段に NOP (32'b0) を書き込む
- `flush_id_ex = ex_take_branch` — ID/EX 段の制御信号を全 0 にする (バブル挿入)

**jal の書き戻しデータパス**

jal は `$31 ← PC+4` を書き戻すため、`id_ex_jal_instr` と `id_ex_pc_plus4` を
EX/MEM, MEM/WB に伝搬し、WB 段の write_data mux で選択する：

```
wb_write_data = mem_wb_jal_instr   ? mem_wb_pc_plus4    // jal
              : mem_wb_mem_to_reg  ? mem_wb_mem_data    // lw
                                   : mem_wb_alu_result; // 通常
```

**Step 12e の実装詳細**

- **lui**: EX 段で `id_ex_lui_instr` のとき `{id_ex_sign_imm[15:0], 16'b0}` を生成し、ALU 結果の代わりに EX/MEM へ伝搬（imm16 は伝搬済み即値の下位 16bit から取得、新規レジスタ不要）
- **ゼロ拡張即値 (ori/andi/xori)**: ID 段で `imm_zero` により `{16'b0,imm16}` / 符号拡張を選択して ID/EX へ。分岐は imm_zero=0 なので分岐ターゲット計算に影響なし
- **rs と 0 の比較分岐 (bltz/bgez/blez/bgtz)**: EX 段でフォワーディング後 rs (`alu_in_a`) の符号ビットとゼロ判定から taken を生成。beq/bne と同じフラッシュ機構を流用
- **シフト (sll/srl/sra/sllv/srlv/srav)**: EX 段でオペランドを入替（`a=rt`, `b=shamt` or `rs`）。shamt は伝搬済み即値の `[10:6]` から取得。値オペランドは rt なので既存の `forward_b` がそのまま機能
- **addiu/addu/subu/sltu/sltiu/nor**: 既存 ALU 経路でそのまま動作（追加ロジック不要）

**Step 12f の実装詳細**

- **mult/multu/div/divu**: EX 段でフォワーディング後の rs/rt から積/商余を計算し、`id_ex_hilo_write` のとき HI/LO レジスタへ書き込む。バブル/フラッシュ時は `id_ex_hilo_write=0` にして誤書込みを防ぐ
- **mfhi/mflo**: EX 段で HI/LO を読み `ex_result` 経由で WB へ。mfhi/mflo は mult/div の 1 命令以上後に EX へ来るため、HI/LO は前サイクルに書込み済みで**専用フォワーディング不要**
- **lb/lbu/lh/lhu/sb/sh**: `mem_size`/`mem_unsigned` を EX/MEM まで伝搬。MEM 段で `mem_size + addr[1:0]` から byte_en 生成、書込みデータをバイト/ハーフ複製。読出しは MEM 段でスライス+符号/ゼロ拡張して MEM/WB へ
- `sw→lb/lh` の store→load は dmem が同期書込み/非同期読出しのため、`sw→lw`（12c）と同じく 1 命令後の読出しで成立
- 注意: 32bit 組み合わせ除算器が EX 段に入るためタイミング余裕が縮小（WNS +5.1ns @20MHz）

**Step 12g 以降の予定**

- Step 11 の例外処理 (CP0/syscall/overflow) のパイプライン化 (Step 13 検討)
- C 言語実行 (test10) と C テスト群のパイプライン再確認

---

## C言語実行の流れ

新しい C プログラムを MIPS コアで動かすまでのフローを説明する。

### 全体の流れ

```
[1] tests/*.c を作成/編集
        ↓
[2] WSL で build_all.sh を実行
        ↓  (mips-linux-gnu-gcc でコンパイル → uint32 配列を生成)
[3] vitis_src/main.c が自動更新される
        ↓
[4] Vitis でプロジェクトをビルド
        ↓
[5] KV260 実機で実行 → UART でテスト結果確認
```

### ステップ詳細

#### [1] C テストプログラムを作成する

`step10/tests/` フォルダに `.c` ファイルを作成する。

```c
// DESCRIPTION: フィボナッチ数列 fib(10)
// EXPECTED: 55
int main(void) {
    int a = 0, b = 1;
    for (int i = 0; i < 9; i++) {
        int t = a + b;
        a = b;
        b = t;
    }
    return b;   // $v0 = 55
}
```

**書き方のルール:**
- 先頭に `// DESCRIPTION:` と `// EXPECTED:` コメントを書く（結果表示に使われる）
- グローバル変数・static変数は使わない（ローカル変数のみ）
- `return` した値が `$v0` としてレポートされる

#### [2] WSL でビルドスクリプトを実行する

```bash
# WSL を開いて実行
cd /mnt/e/fpga/kria260/kv260_mips/step10
bash build_all.sh
```

内部では `update_main.py` が呼ばれ:
1. `tests/*.c` を全て `mips-linux-gnu-gcc -O0` でコンパイル
2. 生成したバイナリを uint32 配列に変換
3. `vitis_src/main.c` の `AUTO-GENERATED BEGIN〜END` マーカー間を自動書き換え

#### [3] vitis_src/main.c の変化を確認する

`vitis_src/main.c` 内の以下のマーカー区間が新しいテスト関数で置き換わる:

```c
// ==== AUTO-GENERATED C TESTS BEGIN (step10/build_all.sh) ====

static const u32 prog_fibonacci[] = { 0x27BDFFFC, ... };
static void run_c_fibonacci(void) { ... }

static void run_all_c_tests(void) {
    run_c_fibonacci();
    run_c_factorial();
    ...
}

// ==== AUTO-GENERATED C TESTS END ====
```

#### [4] Vitis でリビルド & 書き込む

1. Vitis を開く（ワークスペース: `E:\Xilinx\project_vitis\kv_mips11`）
2. `kv_mips_app` を右クリック → **Build** (ハンマーアイコン)
3. **Run** (再生ボタン) → KV260 に書き込み実行

#### [5] UART でテスト結果を確認する

シリアルターミナル（115200bps）に以下のように出力される:

```
==== C Program Tests ====

--- C: フィボナッチ数列 fib(10) ---
PC = 0x00000044
Expected: $v0 = 55
  $v0 = 0x00000037 (55)  ← OK

--- C: 階乗 fact(7) ---
Expected: $v0 = 5040
  $v0 = 0x000013B0 (5040)  ← OK
```

---

## ファイル構成

```
kv260_mips/
├── rtl/
│   ├── mips_axi.v       — AXI4-Lite スレーブラッパー (mips_top_pipe をインスタンス化)
│   ├── mips_top.v       — MIPS トップモジュール (単一サイクル版, Step 1〜11)
│   ├── mips_top_pipe.v  — MIPS トップモジュール (5段パイプライン版, Step 12)
│   ├── control.v        — 制御ユニット (メインデコーダ + ALUデコーダ)
│   ├── datapath.v       — データパス (単一サイクル版, mips_top から参照)
│   ├── imem.v           — 命令メモリ (4096ワード / 16KB, デュアルポートRAM)
│   ├── dmem.v           — データメモリ (バイトイネーブル付き)
│   ├── regfile.v        — レジスタファイル ($0〜$31)
│   └── alu.v            — ALU (add/sub/and/or/slt/sltu/xor/nor/sll/srl/sra)
├── step10/
│   ├── crt0.S           — ベアメタルスタートアップ (_start → main, $sp初期化)
│   ├── mips.ld          — リンカスクリプト (0x0000 起点, note セクション破棄)
│   ├── build.sh         — 単体ビルドスクリプト (WSL 用)
│   ├── build_all.sh     — テスト一括ビルド → main.c 自動更新 (WSL 用)
│   ├── update_main.py   — C→バイナリ→uint32配列変換 & main.c 書き換えスクリプト
│   ├── test10.c         — 最初のテストプログラム (add 関数, $v0=60)
│   ├── bin2array.py     — バイナリ → uint32 配列変換ツール (単体用)
│   └── tests/           — 一括実行テストプログラム
│       ├── fibonacci.c  — fib(10) → $v0=55
│       ├── factorial.c  — fact(7) → $v0=5040
│       ├── sum_loop.c   — sum(1..10) → $v0=55
│       ├── bubble_sort.c— バブルソート最小値 → $v0=1
│       └── gcd.c        — gcd(48,18) → $v0=6
├── vitis_src/
│   └── main.c        — PS 側テストプログラム (Step 1〜10)
├── rebuild.tcl       — Vivado バッチ再ビルドスクリプト
└── README.md         — 本ファイル
```

---

## ビルド・実行手順

### Vivado (RTL 変更後)

```tcl
# Vivado バッチモードで再ビルド (フルパス指定)
vivado.bat -mode batch -source E:/fpga/kria260/kv260_mips/rebuild.tcl
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
  [8] imm_zero  — 1=ゼロ拡張即値 (ori/andi/xori), 0=符号拡張即値
  [7] reg_write — レジスタ書き込み許可
  [6] reg_dst   — 書き込み先: 1=rd (R型), 0=rt (I型)
  [5] alu_src   — ALU 入力 B: 1=即値, 0=レジスタ
  [4] branch    — beq 分岐有効
  [3] mem_write — データメモリ書き込み (sw)
  [2] mem_to_reg— 書き戻し元: 1=メモリ, 0=ALU 結果
  [1] branch_ne — bne 分岐有効
  [0] jump      — j/jal ジャンプ
```

### ALU 制御コード (alu_control[3:0])

| コード | 演算 | 使用命令 |
|--------|------|---------|
| 0000   | AND  | and, andi |
| 0001   | OR   | or, ori |
| 0010   | ADD  | add, addu, addi, addiu, lw, sw |
| 0110   | SUB  | sub, subu, beq, bne |
| 0111   | SLT  | slt, slti |
| 1000   | XOR  | xori |
| 1001   | SLL  | sll, sllv |
| 1010   | SRL  | srl, srlv |
| 1011   | SRA  | sra, srav |
| 1100   | SLTU | sltu, sltiu |
| 1101   | NOR  | nor |

---

## テスト結果 (実機確認済み)

| Step | テスト内容              | 結果  |
|------|------------------------|-------|
| 1    | addi, add, sub, and, or, slt | ✓ |
| 2    | lw, sw, beq             | ✓    |
| 3    | j, jal, jr              | ✓    |
| 4    | lui, ori, bne (ループ5回) | ✓   |
| 5    | andi, xori, slti, addiu, sll, srl, sra | ✓ |
| 6    | addu, subu, sltu, sltiu, nor, sllv, srlv, srav | ✓ |
| 7    | mult, multu, div, divu, mfhi, mflo             | ✓ |
| 8    | lb, lbu, lh, lhu, sb, sh (ビッグエンディアン)   | ✓ |
| 9    | bltz, bgez, blez, bgtz (rs と 0 の比較分岐)    | ✓ |
| 10   | C言語実行 (mips-gcc コンパイル, 関数呼び出し・スタック) | ✓ |
| 11   | 例外処理 (CP0, syscall, overflow, mfc0/mtc0/eret) | ✓ |
| 12a  | 5段パイプライン基本構造 (addi/add/sub, 独立命令)       | ✓ |
| 12b  | フォワーディング + WB→ID バイパス (R 型データ依存) | ✓ |
| 12c  | lw/sw + ロードユースストール                           | ✓ |
| 12d  | 分岐 (beq/bne) + ジャンプ (j/jal/jr) + フラッシュ      | ✓ |
| 12e  | lui/ori/andi/xori/シフト/blez系/addiu/addu/subu/sltu/sltiu/nor | ✓ |
| 12f  | mult/multu/div/divu/mfhi/mflo + lb/lbu/lh/lhu/sb/sh           | ✓ |
