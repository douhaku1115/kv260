# RISC-V on KV260（教科書プロセッサ移植）

「RISC-Vで学ぶコンピュータアーキテクチャ」（東京大学出版会）のVerilogプロセッサを
Xilinx Kria KV260 上で動作させたもの。結果は VIO で `0x13BA`（= 5050 = 0+1+…+100）を確認。

解説記事: [articles/riscv-kv260-pipeline.md](../articles/riscv-kv260-pipeline.md)

## 構成

| ファイル | 内容 |
|----------|------|
| `src/main_vio.v` | **4段パイプライン** `m_proc8_F`（教科書 code9-1、MEMはEXに併合）+ 共通モジュール + KV260トップ |
| `src/main_vio_4stage.v` | **5段パイプライン** `m_proc9`（教科書 code6-27、IF/ID/EX/MEM/WB）版 |
| `src/main_vio_bp.v` | **5段＋分岐予測** `m_proc9` に BTB（code7-4）+ bimodal 2bit（code7-11）を追加した版 |
| `src/main_vio_gshare.v` | **5段＋gshare** 予測器を gshare（code7-13、BHR^PC）に差し替えた版。命令メモリは `asm_nested.txt` |
| `src/main_vio_cache.v` | **4段＋命令キャッシュ** `m_proc8_c2`（code8-8）に直接マップ `m_cache1`（code8-7）+ 遅延主記憶 `m_imem`（code8-2）を組んだ版 |
| `src/main_vio_2way.v` | **4段＋2-wayキャッシュ** キャッシュを 2-way セットアソシアティブ `m_cache3`（code8-12、LRU付き）に差し替えた版。命令メモリは `asm_conflict.txt` |
| `src/main_vio_block.v` | **4段＋2ワードブロックキャッシュ** `m_cache2`（code8-10）+ バースト主記憶。空間的局所性で主記憶転送を半減。命令メモリは `asm_seq.txt` |
| `src/sim_bp.v` | `main_vio_bp.v` の iverilog 検証用テストベンチ（Xilinx IP はスタブ） |
| `src/sim_cache.v` | `main_vio_cache.v` / `main_vio_2way.v` の iverilog 検証用テストベンチ |
| `src/sim_block.v` | `main_vio_block.v` の iverilog 検証用テストベンチ |
| `src/asm.txt` | 命令メモリに焼き込むプログラム（Σ0..100=5050、手アセンブル） |
| `src/asm_nested.txt` | ネストループ（code7-10、結果505）。gshareの効果検証用 |
| `src/asm_conflict.txt` | コンフリクト用（code8-11、低位/高位がインデックス衝突、結果5050）。2-wayの効果検証用 |
| `src/asm_seq.txt` | 逐次プログラム（addi×50、結果50）。2ワードブロックの効果検証用 |
| `create_vio_full.tcl` | 4段版プロジェクト生成（Vivado batch） |
| `create_4stage.tcl` | 5段版プロジェクト生成＋ビットストリームまで |
| `create_bp.tcl` | 分岐予測版（BTB+bimodal）生成＋ビットストリームまで（VIO入力3本） |
| `create_gshare.tcl` | gshare版生成＋ビットストリームまで（VIO入力3本、ネストループ） |
| `create_cache.tcl` | 命令キャッシュ版生成＋ビットストリームまで（VIO入力3本） |
| `create_2way.tcl` | 2-wayキャッシュ版生成＋ビットストリームまで（VIO入力3本、コンフリクト用） |
| `create_block.tcl` | 2ワードブロックキャッシュ版生成＋ビットストリームまで（VIO入力3本、逐次用） |

## ビルド

```
vivado -mode batch -source create_4stage.tcl   # 5段版 m_proc9（create_vio_full.tcl が4段版 m_proc8_F）
```

`m_top_kv260.bit` と `m_top_kv260.ltx` が生成される。

## KV260で実行（VIO確認）

```
# 1. 転送（OpenSSH 9.0+ は -O 必須）
scp -O .../impl_1/m_top_kv260.bit petalinux@<KV260_IP>:/home/petalinux/

# 2. KV260でロード＋PLクロック有効化（VIOに必須）
sudo fpgautil -b /home/petalinux/m_top_kv260.bit
sudo devmem 0xFF5E00C0 32 0x01010A00

# 3. ホストVivado Hardware Manager（TCL）で結果読み出し
set_property PROBES.FILE {.../m_top_kv260.ltx} [get_hw_devices xck26_0]
refresh_hw_device [get_hw_devices xck26_0]
get_property INPUT_VALUE [get_hw_probes w_rslt]
# → 000013ba （= 5050）
```

## 4段 → 5段 の違い

| 項目 | 4段 (m_proc8_F) | 5段 (m_proc9) |
|------|-----------------|----------------|
| 段 | P1/P2/P3 | P1/P2/P3/P4 |
| ライトバック | P3 | P4 |
| フォワーディング | P3から1段 | P3とP4から2段 |
| load-useハザード | なし | 1サイクルstall |

移植で足したのは結果取り出しの `r_dout`（P4でx30書き込み時にcapture）のみ。
トップ／命令メモリ／VIO／クロックBDは共通で、プロセッサ本体だけ差し替える。

## 分岐予測（5段＋BTB+bimodal）

5段 `m_proc9` の PC 選択を分岐予測ベースに差し替えた版（`main_vio_bp.v`、教科書7章）。

- `m_btb`（code7-4）: 分岐先キャッシュ。`r_pc` でルックアップし予測分岐先を先取りフェッチ
- `m_bimodal`（code7-11）: 2bit 飽和カウンタ。分岐ごとに taken/not-taken を学習
- 分岐は P2(EX) で確定。真の次PCと不一致なら `w_miss` でフラッシュ＆リダイレクト

分岐予測を入れても**計算結果は 5050 のまま変わらない**ので、効果は**ミス予測回数**で観測する。
VIO に 3 本（結果 / ミス回数 / 分岐回数）を出力。教科書の HALT（`addi x30`）は実際には
停止しないため、HALT コミットで以後フェッチを止める `r_halt` を追加し、カウンタを 1 回分の値で固定した。

| | ミス予測 | 分岐 | 結果 |
|---|---|---|---|
| 予測なし（baseline） | 100 | 101 | 5050 |
| **BTB+bimodal** | **2** | 101 | 5050 |

取られる分岐ごとに毎回ミスしていた 100 回を、ウォームアップ＋ループ脱出の 2 回まで削減。
KV260 実機 VIO で `r_dout=5050` / `r_miss=2` / `r_brn=101` を確認。

```
# シミュレーション検証（要 iverilog）
cd src && iverilog -g2012 -o /tmp/bp.out main_vio_bp.v sim_bp.v && vvp /tmp/bp.out
# => RESULT=5050  MISS=2  BRANCH=101

# ビルド
vivado -mode batch -source create_bp.tcl
```

## gshare（5段＋BTB+gshare）

予測器を gshare（`main_vio_gshare.v`、code7-13）に差し替えた版。gshare は
分岐履歴レジスタ `r_bhr`（5bit）を PHT のアドレスと XOR して引くため、**相関する分岐**
（ネストループ等）を区別して予測できる。bimodal とインターフェースは同一で、予測器だけ差し替え。

効果が見えるよう命令メモリは**ネストループ**（`asm_nested.txt`、code7-10、結果505）を使用。
内ループは `T T T N` を繰り返すパターンで、bimodal は外ループのたびに脱出を外す。

| 予測器 | ミス予測 | 分岐 | 結果 |
|---|---|---|---|
| BTB+bimodal | 104 | 505 | 505 |
| **BTB+gshare** | **9** | 505 | 505 |

bimodal の 104 回ミスを gshare は 9 回まで削減。
KV260 実機 VIO で `r_dout=0x1F9`（505）/ `r_miss=9` / `r_brn=505` を確認。

```
# シミュレーション比較（要 iverilog、ネストループは asm_nested.txt を include）
cd src && iverilog -g2012 -o /tmp/g.out main_vio_gshare.v sim_bp.v && vvp /tmp/g.out
# => RESULT=505  MISS=9  BRANCH=505

# ビルド
vivado -mode batch -source create_gshare.tcl
```

## 命令キャッシュ（4段＋m_cache1＋遅延主記憶）

教科書8章のメモリ階層。**4段プロセッサ `m_proc8_c2`**（`main_vio_cache.v`、code8-8）に
**直接マップ命令キャッシュ `m_cache1`**（code8-7、32エントリ）と
**遅延つき主記憶 `m_imem`**（code8-2、`D_DELAY=5` サイクル待ち）を組み合わせた版。

- キャッシュ**ヒット**：その場で命令を返す（ストールなし）
- キャッシュ**ミス**：`w_re` で主記憶をリクエストし、返るまで `w_stall` で待つ（約 D_DELAY+1 サイクル）。返ってきた命令はキャッシュに書き込む

キャッシュが意味を持つには**遅い主記憶**が要るので、1サイクルメモリではなく `m_imem` を使う。
キャッシュを入れても結果（5050）は変わらないので、効果は**総サイクル数**で観測する（VIOに 結果 / サイクル数 / ミス回数 の3本）。

| | 総サイクル | 主記憶アクセス | 結果 |
|---|---|---|---|
| キャッシュなし（毎フェッチ主記憶待ち） | 2550 | 510 | 5050 |
| **m_proc8_c2 + m_cache1** | **560** | **10** | 5050 |

各フェッチが D_DELAY=5 サイクルかかるキャッシュなし（510×5=2550）に対し、ループがヒットする
キャッシュ版は **約4.5倍高速**。主記憶アクセスは 510→10（触れた命令の種類数）まで減る。
KV260 実機 VIO で `r_dout=0x13BA`（5050）/ `r_cyc=560` / `r_miss=10` を確認。

> 補足: 教科書 code8-8 は `P3_s`/`P3_b` の更新が抜けている（code8-4 の c1 にはある）ため、本実装で補っている。
> 結果の取り出しは4段なので P3 段（`!w_stall & P3_rd==30`）で capture する。

```
# シミュレーション（要 iverilog、asm.txt = Σ0..100）
cd src && iverilog -g2012 -o /tmp/c.out main_vio_cache.v sim_cache.v && vvp /tmp/c.out
# => RESULT=5050  CYCLES=560  MISS=10

# ビルド
vivado -mode batch -source create_cache.tcl
```

## 2-wayセットアソシアティブ・キャッシュ（m_cache3）

キャッシュを **2-way セットアソシアティブ `m_cache3`**（`main_vio_2way.v`、code8-12）に差し替えた版。
直接マップ `m_cache1` を2つ並べ、**LRU（1bit）** で追い出す way を選ぶ。同じインデックスに当たる
2つのアドレスが両方のwayに共存できるので、**コンフリクトミス（スラッシング）** を防げる。

2-wayが直接マップに勝つのはコンフリクトがある時だけなので、効果が見える専用プログラム
`asm_conflict.txt`（code8-11）を使う。これは低位 `0x0c` と高位 `0x8c`（インデックス同じ・タグ違い）を
交互に実行するため、直接マップでは毎周追い出し合う。

| キャッシュ | 総サイクル | 主記憶アクセス | 結果 |
|---|---|---|---|
| 直接マップ m_cache1 | 7938 | 1223 | 5050 |
| **2-way m_cache3** | **1928** | **21** | 5050 |

直接マップは毎周コンフリクトミスして 1223 回ミス・7938 サイクル。2-wayは両アドレスが共存でき
**21 回**（コールドスタートのみ）まで減り、**約4倍高速**。KV260 実機 VIO で
`w_rslt=5050` / `w_cyc=1928` / `w_miss=21` を確認。

```
# シミュレーション比較（要 iverilog、asm_conflict.txt を include）
cd src && iverilog -g2012 -o /tmp/2w.out main_vio_2way.v sim_cache.v && vvp /tmp/2w.out
# => RESULT=5050  CYCLES=1928  MISS=21

# ビルド
vivado -mode batch -source create_2way.tcl
```

> VIO のプローブ名はトップで接続したワイヤ名（`w_rslt` / `w_cyc` / `w_miss`）。内部レジスタ名（`r_dout` 等）では出ない。

## 2ワードブロック・キャッシュ（m_cache2）

1ライン＝**2ワード（ブロック）**のキャッシュ `m_cache2`（`main_vio_block.v`、code8-10）。
ミス時にブロック2ワードをまとめて主記憶から取ってくるので、**空間的局所性**（次の隣接命令も
キャッシュに載る）が効き、主記憶への転送回数が約半分になる。

教科書は `m_cache2` を**単体モジュールとしてのみ**提示しており、プロセッサへの統合は無い。
本実装ではブロック充填に対応した `m_proc8_c2b` と、ミス時に2ワードを一括で返すバースト主記憶
`m_imem_blk` を自作して統合した。効果が見えるよう、ループではなく**逐次プログラム**
`asm_seq.txt`（`addi` を50個、結果50）を使う。

| キャッシュ | 総サイクル | 主記憶転送 | 結果 |
|---|---|---|---|
| 1ワード m_cache1 | 324 | 54 | 50 |
| **2ワードブロック m_cache2** | **189** | **27** | 50 |

逐次コードでは各ブロック転送が2命令を運ぶので、転送回数が 54→27（半分）に、サイクルも
**約1.7倍高速**（324→189）になる。KV260 実機 VIO で `w_rslt=50` / `w_cyc=189` / `w_miss=27` を確認。
（Σのようなループ主体のコードだと、転送は半減してもサイクル差は小さい。ブロックの効果は逐次性に依存する。）

```
# シミュレーション比較（要 iverilog、asm_seq.txt を include）
cd src && iverilog -g2012 -o /tmp/blk.out main_vio_block.v sim_block.v && vvp /tmp/blk.out
# => RESULT=50  CYCLES=189  MISS=27

# ビルド
vivado -mode batch -source create_block.tcl
```

## CSR / 例外（ecall・mret）— 自作OS（KOZOS）移植の第2段

教科書のプロセッサ（`m_proc9`, 5段）を拡張し、**最小の CSR と例外機構**を追加した
（`main_vio_csr.v`, コア名 `m_proc_csr`）。教科書には CSR/例外のコードは無く、ここからは
自作OS（KOZOS 流）を載せるための独自拡張。第2段はまず**同期例外の往復**を成立させる。

| 追加命令 | 追加 CSR |
|---|---|
| `csrrw`(funct3=001) / `csrrs`(010) / `ecall` / `mret` | `mtvec`(0x305) / `mepc`(0x341) / `mcause`(0x342) / `mscratch`(0x340) |

- **トラップは分岐解決と同じ P2（EX）境界に相乗り**。既存の分岐フラッシュ `w_miss` を
  `w_redir = w_miss | ecall | mret` に拡張し、若い命令（P1/P2）を潰して PC を差し替える。
- `ecall` → `mepc ← PC`, `mcause ← 11`（M-mode 環境呼び出し）, `PC ← mtvec`
- `mret` → `PC ← mepc`（スコープ最小のため `mstatus` 復元は無し。割込みは第4段で追加予定）
- CSR 命令は**旧値を rd へ返す**（`P3_alu` を CSR 旧値で置換し既存のライトバック経路に乗せる）。
  書き込み側の rs1 値はフォワーディング済みの `w_in1` を使う。

検証プログラム `asm_csr.txt`：`mtvec` を handler に設定 → `ecall` → handler で `mcause` 取得＋
`mepc+4`（ecall をスキップする標準作法）→ `mret` で復帰 → `x30 ← mcause`。
往復が成立すれば `x30 = 11`。

> HALT は `bne x30,x0,0`（x30≠0 の自己ループ）。命令メモリが 64 語（256B）のため、PC が
> 暴走して `ecall` を再実行しないための処置。ベースの `m_proc9` は `jal` 未実装なので使えない。

| 項目 | 値 |
|---|---|
| VIO `w_rslt`（= x30 = mcause） | **0x0000000B（11）** |
| VIO `w_trapcnt`（トラップ回数） | **1** |
| ビルド WNS(setup) | +4.620 ns |

KV260 実機 VIO で `w_rslt=0000000b` / `w_trapcnt=1` を確認＝ecall→handler→mret の往復成功。

```
# シミュレーション（要 iverilog）
cd src && iverilog -g2012 -o /tmp/csr.out main_vio_csr.v sim_csr.v && vvp /tmp/csr.out
# => r_rslt = 0000000b   r_trapcnt = 1   *** PASS ***

# ビルド
vivado -mode batch -source create_csr.tcl
```


## 完全RV32I ＋ gccフロー — 自作OS（KOZOS）移植の第3段

教科書の最小コア（加算とbneのみ）を **RV32I（base整数命令セット）全実装**へ拡張し
（`main_vio_rv32i.v`, コア `m_proc_rv32i`）、**手アセンブルを卒業して gcc で書いた C を実機で動かす**。

実装した命令:

| 種別 | 命令 |
|---|---|
| ALU(R/I) | add sub sll slt sltu xor srl **sra** or and（＋即値 addi…srai） |
| 分岐 | beq bne blt bge bltu bgeu |
| ジャンプ | jal / jalr（`rd ← pc+4`） |
| 上位即値 | lui / auipc |
| ロード/ストア | lb lh lw lbu lhu / sb sh sw（バイトイネーブル） |

設計の要点:
- **ALU が funct3 を使うのは OP / OP-IMM のみ**。ロード/ストア/lui/auipc/jal/jalr の
  アドレス・リンク計算は常に加算（`sw` の funct3=010 を SLT と誤解しないため）。
- **シフトは算術/論理を別 wire に分離**（三項演算子で符号付き `>>>` と符号無し `>>` を混ぜると
  arithmetic shift が logical 化する Verilog の落とし穴を回避）。
- トラップ／ジャンプは分岐と同じ **P2（EX）境界**で解決。

### メモリマップ（Harvard）
| 領域 | アドレス | 用途 |
|---|---|---|
| IMEM(text) | `0x0000_0000..` | フェッチ（4096語=16KB） |
| DMEM(data,stack) | `0x0001_0000..` | load/store（4096語=16KB） |
| RESULT port | `0x0002_0000` | store で結果を捕捉 → VIO `w_rslt`/`w_done` |

### gccフロー（`src/gcc/`）
`crt0.S`（sp設定→`main()`→結果を`0x20000`へsw）, `link.ld`（`.text`を0x0へ, build-id無効化必須）,
`main.c`（Σ0..100）, `build_gcc.sh`（gcc→objcopy `.text`→`` `MM[i]= `` 形式の `asm_gcc.txt` 生成）。
ツールチェーン: Vitis同梱 `riscv64-unknown-elf-gcc`（rv32i/ilp32）。

```
# 命令メモリ生成（Σ0..100）
cd src/gcc && CSRC=main.c bash build_gcc.sh && cd ..
# シミュレーション（要 iverilog）
iverilog -g2012 main_vio_rv32i.v sim_rv32i.v -o /tmp/a && vvp /tmp/a
# => r_rslt = 000013ba (5050)

# ビルド
vivado -mode batch -source create_rv32i.tcl
```

**検証（gcc出力をホストgcc実行と突き合わせ）**: Σ=0x13BA / ISA網羅（`test_isa.c`,
最適化バリアで全命令発行）=ホスト一致 / バイト・ハーフmem（`test_mem.c`）=ホスト一致。
**KV260 実機 VIO で `w_rslt=0x000013ba` / `w_done=1` を確認。**

## 完全RV32I ＋ CSR/例外 統合コア（第2段＋第3段の合流）

第3段の完全RV32I に 第2段の CSR/例外（`csrrw`/`csrrs`/`ecall`/`mret`,
CSR=`mtvec`/`mepc`/`mcause`/`mscratch`）を統合（`main_vio_rv32i_csr.v`, コア `m_proc_rvsys`）。
トラップは分岐/ジャンプと同じ P2 境界の `w_redir` に相乗り、CSR 命令は旧値を rd に返す。
**RV32I 部分は無改変**（Σ/ISA/mem の回帰すべて通過）。KOZOS とタイマ割込みの土台。

gcc の C から CSR を使う場合は `-march=rv32i_zicsr`（`csr` 命令のアセンブルに必要）。

```
# CSR/例外テスト(手アセンブル): mtvec→ecall→handler→mret→mcause(=11)を出力
iverilog -g2012 -DPROG='"asm_csr_sys.txt"' main_vio_rv32i_csr.v sim_rvsys.v -o /tmp/a && vvp /tmp/a
# => r_rslt = 0000000b (mcause = Environment call from M-mode)

# gccのCからCSR/例外を使うテスト
cd src/gcc && CSRC=test_csr.c bash build_gcc.sh && cd ..
iverilog -g2012 main_vio_rv32i_csr.v sim_rvsys.v -o /tmp/a && vvp /tmp/a   # => 0000000b

# ビルド
vivado -mode batch -source create_rvsys.tcl
```

**iverilog 全5テストPASS**（Σ / ISA網羅 / mem / CSR-asm / C-CSR-gcc）。
**KV260 実機 VIO で `w_rslt=0x000013ba` / `w_done=1` を確認（統合コアでも Σ 正常）。**

## マシンタイマ割込み — 自作OS（KOZOS）移植の第4段

統合コア（`m_proc_rvsys`）に **RISC-V マシンタイマ割込み**を追加（`main_vio_timer.v`, コア `m_proc_timer`）。
KOZOS の**プリエンプション**（時間でタスクを強制切替）の心臓部。

**追加CSR**: `mstatus`（MIE=bit3 / MPIE=bit7）, `mie`（MTIE=bit7）, `mip`（MTIP=bit7, HW制御）。

**メモリマップド・タイマ（64bit, 上下2ワード）**:

| レジスタ | アドレス | 用途 |
|---|---|---|
| `mtimecmp` | `0x0003_0000`(lo) / `0x0003_0004`(hi) | 比較値（R/W） |
| `mtime` | `0x0003_0008`(lo) / `0x0003_000C`(hi) | 自走カウンタ（RO） |

`mtime >= mtimecmp` で `mip.MTIP=1`。**割込み条件 `MIE & MTIE & MTIP`** が成立すると、
P2境界で有効な命令に相乗りして `mepc ← その命令PC`（＝復帰後に再実行）, `mcause ← 0x80000007`
（Interrupt＋code7）, `MPIE←MIE, MIE←0`, `PC ← mtvec`。`mret` で `MIE←MPIE`。

**検証**（`src/gcc/test_timer.c`, gcc の `__attribute__((interrupt("machine")))` ハンドラ）:
mtvec設定→mtimecmp設定→MTIE/MIE許可→ループ。タイマ割込みでハンドラが tick++ し次の mtimecmp を設定、
5回で脱出。**`r_rslt=5` / `mcause=0x80000007` を確認**（RV32I/CSR の回帰も全通過）。

```
# タイマ割込みテストを命令メモリに生成
cd src/gcc && CSRC=test_timer.c bash build_gcc.sh && cd ..
iverilog -g2012 main_vio_timer.v sim_timer.v -o /tmp/a && vvp /tmp/a
# => r_rslt = 00000005 (タイマ割込みが5回発生)

# ビルド
vivado -mode batch -source create_timer.tcl
```

**KV260 実機 VIO で `w_rslt=0x00000005` / `w_done=1` を確認**
（gcc の C が実機でタイマ割込みによるプリエンプションを実行）。

## KOZOS 協調マルチタスク — 自作OS移植の第5段-1

これまでの全要素（RV32I・例外/ecall・スタック）を統合し、**自作OS（KOZOS流）の
コンテキストスイッチ＋スケジューラ**を載せた。コアは第4段の `main_vio_timer.v`
（`m_proc_timer`）をそのまま使用（5-1は ecall のみ、タイマは 5-2 で使う）。

**部品**（`src/gcc/`）:

| ファイル | 内容 |
|---|---|
| `kentry.S` | `trap_entry`＝コンテキストスイッチ（全GPR+mepcを現スレッドのスタックへ退避→`ksched`→次スレッドのを復元→`mret`）／`dispatch`＝最初のスレッド起動 |
| `kozos.c` | TCB・ラウンドロビン `ksched`・`thread_create`（スタックに偽の初期コンテキスト）・`yield`/`sys_exit`（a7に番号→`ecall`）・スレッドA/B |

- コンテキスト＝128B（32語）: `[0]=mepc, [i]=xi (i=1,3..31), [2]=未使用`。ecallは
  `trap_entry` で `mepc+4`（協調＝次命令へ復帰）。syscall番号は a7（フレーム slot 17）。
- スレッド生成は「スタックに偽フレームを作り、初回復元で関数へ飛ぶ」古典手法。

**検証**: 2スレッドが共有 `seq` に桁を交互追加（A=1, B=2）。ラウンドロビンで
A,B,A,B,A,B と切り替われば `seq` は `1→12→121→1212→12121→121212` と進む。

```
# KOZOS を命令メモリに生成（crt0 + kozos.c + kentry.S）
cd src/gcc && CSRC="kozos.c kentry.S" bash build_gcc.sh && cd ..
iverilog -g2012 main_vio_timer.v sim_timer.v -o /tmp/a && vvp /tmp/a
# => r_rslt = 0001d97c  (= 121212 = A,B,A,B,A,B と交互実行)

# ビルド
vivado -mode batch -source create_kozos.tcl
```

**KV260 実機 VIO で `w_rslt=0x0001D97C`（=121212）/ `w_done=1` を確認**
＝自作RISC-Vコア上で自作OSのコンテキストスイッチが実機動作。
（次: 5-2 プリエンプティブ＝yield廃止、タイマ割込みで強制切替。`mcause` 判定で
割込み時は `mepc+4` しない。）

## KOZOS プリエンプティブ・マルチタスク — 自作OS移植の第5段-2

第5段-1（協調）に**第4段のタイマ割込み**を組み合わせ、**yield を廃した本物の
プリエンプション**を実現（`src/gcc/kozos2.c`）。スレッドは自発的にCPUを手放さず、
**タイマ割込みだけ**がコンテキストスイッチを起こす。コアは `main_vio_timer.v`（`m_proc_timer`）。

**5-1 からの変更点**:
- `kentry.S` の `trap_entry` を **`mcause` 判定**に対応（後方互換）:
  - 割込み（`mcause[31]=1`）→ `mepc` を **+4 しない**（割込まれた命令を再実行）
  - 例外（`ecall`, `mcause=11`）→ 従来通り `mepc+4`（次命令へ）
- `ksched(frame, sc, mcause)` に `mcause` を渡し、割込み時はスケジューラが
  タイマを再武装（次の `mtimecmp`）＋「走っていたスレッド」を記録。
- 起動時に `mstatus.MPIE=1` を仕込み、最初の `mret` で `MIE=1`（割込み許可）にする。

**検証**: スレッドA/Bは `for(;;) cntX++;`（yield 無し）。タイマ割込みが起きるたびに
`ksched` が「割込まれていたスレッド」を `sched_seq` に記録（A=1, B=2）。
プリエンプションが A,B,A,B,A,B と交互に起きれば `sched_seq=121212`。
両スレッドが実際に走った証拠に `cntA/cntB>0` も確認して出力。

```
# プリエンプティブ版を命令メモリに生成
cd src/gcc && CSRC="kozos2.c kentry.S" bash build_gcc.sh && cd ..
iverilog -g2012 main_vio_timer.v sim_timer.v -o /tmp/a && vvp /tmp/a
# => r_rslt = 0001d97c (= 121212)

# ビルド
vivado -mode batch -source create_kozos2.tcl
```

シミュレーションで **プリエンプション6回 / ecall 0回**（＝100%タイマ駆動）、
`cntA/cntB>0`（両スレッド稼働）を確認。
**KV260 実機 VIO で `w_rslt=0x0001D97C`（=121212）/ `w_done=1` を確認**
＝自作RISC-Vコア＋自作OSで本物のプリエンプティブ・マルチタスクが実機動作。

## KOZOS sleep(n) サービス — 自作OS移植の第5段-3

プリエンプティブ基盤（5-2）に**スレッド状態と時間待ち**を導入し、`sleep(n)`
（n ティック休止して他スレッドにCPUを譲る）を実装（`src/gcc/kozos3.c`）。
コア・`kentry.S` は 5-2 から無変更（`ksched` が保存フレームの `a0` から sleep 引数を読む）。

- **スレッド状態**: `READY` / `SLEEP`（`wake` ティックを持つ）/ `DEAD`。
- `sleep(n)` = `ecall`（`a7=SYS_SLEEP, a0=n`）→ `wake=ticks+n` にして SLEEP、次の READY へ。
- **タイマ割込み = システムティック**: `ticks++` し、`ticks>=wake` の SLEEP スレッドを READY に起こす。
- 全 real スレッドが SLEEP なら **idle スレッド**（`for(;;)`, MIE=1）が回ってティックを進める。
- 全 real スレッドが DEAD で結果を出力。

**検証**: A は `sleep(2)` で 4 回、B は `sleep(4)` で 2 回、各回 `seq` に桁追加（A=1, B=2）。
A は tick 0,2,4,6 の 4 回、B は tick 0,4 の 2 回起きるので、A が B の 2 倍の頻度で走る
→ `seq=121211`。sleep 中は CPU を手放し idle/他スレッドが走る（ビジーウェイトしない）。

```
# sleep デモを命令メモリに生成
cd src/gcc && CSRC="kozos3.c kentry.S" bash build_gcc.sh && cd ..
iverilog -g2012 main_vio_timer.v sim_kozos.v -o /tmp/a && vvp /tmp/a
# => r_rslt = 0001d97b (= 121211)

# ビルド
vivado -mode batch -source create_kozos3.tcl
```

**KV260 実機 VIO で `w_rslt=0x0001D97B`（=121211）/ `w_done=1` を確認。**

> 実装の教訓: 割込みハンドラ（全32レジスタ退避/復元＋`ksched`）は分岐ミスペナルティ込みで
> 約130サイクル。タイマ間隔（`INTERVAL`）をこれより十分大きく取らないと、ハンドラ実行中に
> `mtime` が次の `mtimecmp` を越えて戻った瞬間に再割込みする**割込みストーム**でスレッドが
> 一切進めなくなる（本実装は `INTERVAL=1000`）。

## KOZOS セマフォ（wait / signal）— 自作OS移植の第5段-4

sleep（5-3）で導入した状態管理を発展させ、**同期プリミティブ セマフォ**を実装
（`src/gcc/kozos4.c`）。時間待ち（sleep）に対し、こちらは**他スレッドのイベント待ち**
（`BLOCKED` 状態）。**タイマは使わず `ecall`（wait/signal）だけ**で駆動。コア・`kentry.S` は無変更。

- `wait(s)` = `ecall`：`sem[s]>0` なら `--` して継続、`0` なら `BLOCKED`（`block_sem=s`）。
- `signal(s)` = `ecall`：`s` を待つスレッドが居れば 1 つ `READY` に起こす（ハンドオフ）、
  居なければ `sem[s]++`。
- スケジューラは、現スレッドがブロックしていなければそのまま継続（協調的）。
- 全スレッドがブロックしたら `0xDEAD` を出力（デッドロック検出）。

**検証（ping-pong）**: バイナリセマフォ `semA=1, semB=0`。
`threadA: wait(semA); seq+=1; signal(semB);`、`threadB: wait(semB); seq+=2; signal(semA);` を各3回。
2つのセマフォが **A,B,A,B を強制**するので、**タイミングに依らず** `seq=121212`。

```
# セマフォ ping-pong を命令メモリに生成
cd src/gcc && CSRC="kozos4.c kentry.S" bash build_gcc.sh && cd ..
iverilog -g2012 main_vio_timer.v sim_kozos.v -o /tmp/a && vvp /tmp/a
# => r_rslt = 0001d97c (= 121212)

# ビルド
vivado -mode batch -source create_kozos4.tcl
```

**KV260 実機 VIO で `w_rslt=0x0001D97C`（=121212）/ `w_done=1` を確認。**
sleep（時間駆動）と違い ecall のみで同期するため高速に完了（約2300サイクル）。

## KOZOS メッセージング（send / recv）— 自作OS移植の第5段-5

セマフォ（5-4）の `BLOCKED` 基盤の上に、**スレッド間通信 send/recv** を実装
（`src/gcc/kozos5.c`）。KOZOS らしい IPC。各スレッドに**メールボックス（リングバッファ）**を持たせ、
`recv` は**戻り値（`a0`）で受信値を返す**。タイマ不使用（`ecall` のみ）、コア・`kentry.S` は無変更。

- `send(dst, v)` = `ecall`：`dst` が `recv` 待ちなら**直接 `dst` の `a0` に届けて**起こす、
  でなければ `dst` のメールボックスに積む。
- `recv()` = `ecall`：自メールボックスに在れば取り出して継続、空なら `BLOCKED`
  （後で `send` が `a0` をセットして起こす）。

**検証（producer / consumer ランデブー）**: producer が値 1,2,3 を `send` し毎回 ack を待つ、
consumer が `recv` して `seq` に積み ack を返す。各 `recv` がブロック→対応する `send` で起床＋
**データ転送** → `seq=123`。

```
# メッセージングを命令メモリに生成
cd src/gcc && CSRC="kozos5.c kentry.S" bash build_gcc.sh && cd ..
iverilog -g2012 main_vio_timer.v sim_kozos.v -o /tmp/a && vvp /tmp/a
# => r_rslt = 0000007b (= 123)

# ビルド
vivado -mode batch -source create_kozos5.tcl
```

**KV260 実機 VIO で `w_rslt=0x0000007B`（=123）/ `w_done=1` を確認。**
これで KOZOS の主要サービス（協調 / プリエンプティブ / sleep / セマフォ / メッセージング）が揃った。

## KOZOS UARTコンソール（対話シェル）— 自作OS移植の第5段-6

これまで結果を VIO でしか見られなかったのに対し、**UART（送受信）で対話**できる
コンソールを追加（`src/main_vio_console.v`, シェルは `src/gcc/console.c`）。
自作RISC-Vコア上の自作OSに、**キーボードでコマンドを打って応答が返る**ようになった。

**コアへの追加**:
- メモリマップド UART（`m_uart_tx` / 新規 `m_uart_rx`）:
  `TX=0x40000`（w, 送信）, `STAT=0x40004`（r, bit0=RX有/bit1=TX満杯）, `RX=0x40008`（r, pop）。
- **IMEM にデータ読み出しポートを追加**（重要）: 文字列リテラル（`.rodata`）は `.text`＝IMEM に
  置かれるが、従来ロードは DMEM しか読めず**文字列比較が壊れていた**。text/rodata 領域
  （`adr[31:16]==0x0000`）へのロードを IMEM から読むようにして解決（`str_eq` 等が正しく動く）。

**シェル**（`console.c`, 単一ループ）: 1行読み→エコー→コマンド解釈。`help` / `echo <text>` / `sum`。
`put_dec` の除算のため `build_gcc.sh` に `-lgcc`（RV32I ソフト除算）を追加。

```
# コンソールを命令メモリに生成
cd src/gcc && CSRC="console.c" bash build_gcc.sh && cd ..
# シミュレーション(RXにコマンドを流しTXをデコード, -DUARTDIV=8)
iverilog -g2012 -DUARTDIV=8 main_vio_console.v sim_console.v -o /tmp/a && vvp /tmp/a

# ビルド
vivado -mode batch -source create_console.tcl
```

**KV260 実機（PMOD + USB-TTLアダプタ, 115200 8N1）で対話成功**:
```
KOZOS console (help/echo/sum)
KOZOS> sum
5050
KOZOS>
```
配線: `uart_tx=B11(J2-10)→アダプタRXD(緑)` / `uart_rx=D11(J2-9)←アダプタTXD(白)` / `GND(黒)`（クロス接続, `src/uart_console_pins.xdc`）。ホストは `tio -b 115200 /dev/ttyUSB*`（FT232R）。
