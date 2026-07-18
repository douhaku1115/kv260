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

## KOZOS 対話シェル ＋ カーネル統合 — 自作OS移植の第5段-7

コンソール（5-6）とプリエンプティブ・カーネル（5-2〜5-3）を統合し、**シェル自身を
1つのKOZOSスレッド**として走らせた（`src/gcc/kozos_sh.c`）。コマンドで**生きたOSを操作**できる。
コア・`kentry.S` は無変更（`main_vio_console.v` = UART+timer+CSR+RV32I 全部入りを流用）。

**コマンド**: `help` / `echo <text>` / `sum` / `tick`（システムtick）/ `ps`（スレッド一覧: id/state/cnt）/ `run`（ワーカースレッド動的起動）。

- スレッド構成: `NTHREAD=6`（0=shell / 1..4=worker / 5=idle）。
- シェルの `get_c` は入力が無ければ `sleep(1)` で他スレッドにCPUを譲る。
- ワーカーは `cnt[id]++; sleep(3);` を繰り返す（`ps` で `cnt` が進むのが見える）。
- `run` は空きスロットに動的生成（割込み禁止の critical section 内で TCB を用意）。
- **割込み禁止は `csrr`+`csrw` で手動**（本コアが正しく実装する CSR 命令は `csrrw`/`csrrs` のみ。
  `csrrc`/即値版は非対応なので使わない）。

```
# 対話シェルを命令メモリに生成
cd src/gcc && CSRC="kozos_sh.c kentry.S" bash build_gcc.sh && cd ..
# ビルド
vivado -mode batch -source create_shell.tcl
```

**KV260 実機（tio, 115200）で対話・マルチタスクを確認**:
```
KOZOS> run
spawned t1
KOZOS> run
spawned t2
KOZOS> ps
 t0 RUN   cnt=0
 t1 SLEEP cnt=695531      <- 100MHz実機で裏で回り続けるワーカー
 t2 SLEEP cnt=384046
 t5 READY cnt=0
```
`ps` を打つたびに worker の `cnt` が増える＝自作RISC-Vコア上で自作OSが対話的にプリエンプティブ・マルチタスクしている。

### 第5段-7 追加コマンド ＋ RX FIFO 化

シェルにコマンドを追加し、UART受信を FIFO 化した（`kozos_sh.c` / `main_vio_console.v`）。

- `kill <id>`: 指定ワーカースレッドを終了（スロット解放）。`run`/`ps`/`kill` で簡易プロセス管理。
- `peek <hex>`: 番地の値を読んで表示（例 `peek 30008` = mtime下位、打つたびに変化＝タイマ稼働）。
- `poke <hex> <hex>`: 番地に書き込み（例 `poke 40000 5a` = UART送信レジスタに 'Z' を書く→送信）。
  → 再合成せずにメモリ/MMIO を対話で読み書きできる。
- **`m_uart_rx` を16段FIFO化**: 単一バイト受信→FIFO受信にし、高速入力/ペーストでの取りこぼしを防止。

```
KOZOS> kill 1
killed t1
KOZOS> peek 30008
0x1cd3e49b        <- mtime下位(タイマは走り続けるので毎回変わる)
KOZOS> poke 40000 5a
Zok               <- UART送信レジスタに 'Z'(0x5a) を書いて送信
```
KV260 実機で `kill`/`peek`/`poke` と FIFO 受信を確認。

### 第5段-7 割込み駆動UART ＋ 優先度スケジューリング ＋ dump

シェル/カーネルをさらに拡張（`kozos_sh.c` / `main_vio_console.v`）。

- **割込み駆動UART**: UART RX を外部割込み化（`mip.MEIP=rx_valid`, `mie.MEIE`=bit11, `mcause=0x8000000B`）。
  シェルの `get_c` は入力が無ければ `ST_WAITRX` でブロックし、UART受信割込みで起こす。ポーリングを廃止した
  イベント駆動。入力待ちの間はCPUを完全に手放すのでワーカーが回る。
- **優先度スケジューリング**: TCB に優先度を持たせ、READY の中で最高優先度を選ぶ（同順位はラウンドロビン）。
  shell=2 / worker=1 / idle=0。`ps` に `pri=` 列。入力が来たら shell（最高優先度）が即応する。
- **dump `<hex> <n>`**: メモリ範囲を4語/行で16進表示。

```
KOZOS> ps
 t0 RUN   pri=2 cnt=0
 t1 SLEEP pri=1 cnt=4
 t5 READY pri=0 cnt=0
KOZOS> dump 30008 2
0x00030008: 0x0001261f 0x00000000
```

> **ハマり: 副作用のあるロード＋精密割込み**
> UART RX 読み（`lw 0x40008`）は FIFO を pop する副作用を持つ。読み込み中にタイマ割込みが入ると
> `lw` が再実行され、**2度 pop して1バイト取りこぼす**（非冪等ロードと精密例外の典型問題）。
> RX 読みを割込み禁止で囲んでアトミック化して解決した。自作CPUでOSを作るときに出会う、
> ハードとソフトの境界のバグの好例。

シミュレーション（`-DUARTDIV=8` で RX にコマンド投入→TXデコード）で `run`/`ps`(pri列)/`dump` を確認。
ビルド WNS +3.368ns。

### コア重大バグ: 精密割込みの二重実行（修正）

プリエンプティブ環境でシェルの `sum`（1+2+…+100）が **5050 でなく 10050** になった。
プリエンプションを止める（タイマ間隔を巨大化）と 5050 に戻る＝**プリエンプションで命令が二重実行**されていた。

- **原因**: 割込み（`w_take_irq`）が EX 段（P2）の命令に相乗りし `mepc←P2_pc` で復帰後に再実行させるが、
  EX→MEM のレジスタ更新 `{P3_v,P4_v} <= {P2_v & !w_lduse, P3_v}` が**割込み時も P2 命令を P3 へ通して
  コミットさせていた** → コミット＋再実行＝二重実行。
- **分岐との非対称**: 分岐（`w_miss`）は P2 の分岐命令自身をコミットさせるのが正しい（分岐は完了する）。
  一方、割込みは P2 命令を**復帰点**として保存するのでコミットさせてはいけない。この非対称が抜けていた。
- **修正（1行）**: `{P3_v,P4_v} <= {P2_v & !w_lduse & !w_take_irq, P3_v}`。
  `main_vio_console.v` と `main_vio_timer.v` の両方に適用。プリエンプション下でも `sum`=5050 になる。

自作CPUに割込み駆動のOSを載せて初めて露見する「精密割込み」バグの好例。以前の UART RX 二重 pop も同じ根本原因だった。

### シェルの計算コマンド（sum n / calc）＋ nice / 履歴

- `sum` = 1+…+100、`sum <n>` = 1+…+n。`calc <a> <op> <b>` = 四則演算（`calc 6 * 7` → 42）。
- `nice <id> <prio>` = 実行中に優先度変更。↑↓キーでコマンド履歴の呼び戻し（ESC シーケンス解釈）。

```
KOZOS> sum 100
5050
KOZOS> calc 100 - 37
63
```
（`m_top_kv260` ビルド WNS +3.633ns）

### シリアルブートローダ（任意プログラム実行）— 第5段-8

再合成せずに、ホストでコンパイルした任意プログラムをシリアルで送って実行する仕組み。

- **RTL（`main_vio_console.v`）**: DMEM（`0x0001_xxxx`）を**フェッチ可能**にした（`m_am_dmem` に命令フェッチ用の第2ポートを追加し、
  `PC` が DMEM 領域なら DMEM から命令を取る）。これで DMEM に書き込んだコードをコアが実行できる。
- **モニタ（`kozos_sh.c` の `load` コマンド）**: `load <n>` で n ワードの機械語をシリアル受信し
  `0x0001_3000` へ格納 → そこへ関数呼び出しでジャンプ → 戻り値を `ret=` 表示。
- **ヘルパ（`gcc/mkload.sh`）**: `int prog(void){...}` の C を rv32im でコンパイルし、貼り付け用の `load <n>` ＋ hex を出力。
  制約は位置独立（ローカル変数・演算・ループのみ。グローバル/文字列/他関数呼び出しは不可）。

```
$ bash gcc/mkload.sh myprog.c    # int prog(void){ ... return 値; }
load 11
00a00713 02e05063 ...            # ← この2行を tio に貼る
run @13000...
ret=55
```

コード領域は `0x13000`〜`0x13FFF`（1024 命令 = 4KB）、実行時スタックは間借りで約1KB。
「数値を計算して 1 個の整数を返す」タイプのアルゴリズムを、焼き直しなしで試せる。

### RV32M（乗除算）拡張 — 第5段-9

rv32i には乗除算命令が無く `* / %` がライブラリ呼び出しになる（ブートローダで使えない）ため、コアに RV32M を追加。

- **乗算（組合せ / DSP, 1 サイクル）**: MUL / MULH / MULHSU / MULHU。符号有無に応じ 33bit へ拡張し 33×33 積の下位/上位を取る。
- **除算（多サイクル反復, 約 34 サイクル）**: DIV / DIVU / REM / REMU。**32 サイクルの復元法除算器**を実装し、
  既存のロード使用ハザードのストール機構を拡張（`w_stall = w_lduse | w_div_stall`）してパイプラインを停止。
  絶対値で無符号除算し符号を後付け（商符号 = 被除数 ^ 除数、剰余符号 = 被除数）。0 除算は仕様通り DIV→−1 / REM→被除数。
  **除算中は割込みを保留**（完了後に受理）。
- **`mkload.sh` を `-march=rv32im` に更新**。ロードする C で `/ * %` がそのままハード命令になる。

```
KOZOS> load 10                   # a=1000,b=7; a/b*(a%b) 等 → 1000
3e800793 00078793 ...
ret=1000
```

sim で符号付き除算・0 除算・RV32I 回帰（fib=610, 素数個数=8）を確認。`m_top_kv260` ビルド WNS +1.199ns。

### ブートローダ グローバル変数対応 — 第5段-10

ブートローダで読み込むプログラムに、グローバル変数（`.data` 初期値付き・`.bss` ゼロ初期化）・グローバル配列・
関数呼び出し・再帰を使えるようにした。**ホスト側（`mkload.sh` + `load.ld`）だけの変更で、RTL は無変更（再合成不要）**。

- **固定リンク**: プログラムを `0x13000` に固定リンクする（新規 `gcc/load.ld`）。グローバル変数に絶対番地が付き、
  コードは `lui/lw` の絶対アドレスで参照する。像を `.text` → `.data` → `.bss` の順に連続配置。
- **`.bss` ゼロ化**: `mkload.sh` が `.text`+`.data` をバイナリ化し、`_bss_end` までゼロ語を後付けする
  （リンカシンボルから `.bss` の終端を取得）。これで `0x13000` から `.bss` 終端までが `load` の 1 転送で埋まる。
- `load` コマンド自体は変更不要（N 語を `0x13000` に書いてジャンプするだけ）。像は `0x13000`〜`0x13FFF` の 1024 語に収める。

```
$ bash gcc/mkload.sh myprog.c    # グローバル変数・配列・関数呼び出しOK
load 18
00013737 ... 000003e8
run @13000...
ret=1010
```

sim で `.data`（初期値）・`.bss`（ゼロ初期化依存）・グローバル配列・再帰関数（gcd）を確認。**実機で `ret=1010`（一致 18/18 語）確認済み**。

### SD自動起動 — 第5段-11

**電源ONだけで自作RISC-V＋KOZOSが立ち上がる**ようにした。PetaLinuxプロジェクトに
systemdサービス（`riscv-load.service` = fpgautil＋pl_clk0設定）とビットストリームを焼き込み、
SDカードから起動する。毎回の scp→fpgautil→devmem の手動3手順が不要になる。

```
電源ON → U-Boot(QSPI) → SDのboot.scr → uEnv.txt
  → 自ビルドカーネル + SD ext4 rootfs → systemd → riscv-load.service → KOZOS>
```

部品（Yoctoレシピ・uEnv.txt）と組み立て手順・ハマりどころ4件
（pmu-firmwareの`VERSAL_PLM`バグ、`IMAGE_BOOT_FILES`のimage.ub、
巨大initramfsのRAM起動ハング→SD ext4 root化、rootfs.ext4の鮮度）は
[`sdboot/README.md`](sdboot/README.md) にまとめた。SDを抜けば従来の純正QSPI Linuxに戻る。

### 分岐予測（BTB + gshare）を KOZOS コアに統合 — 第5段-12

これまで単体デモ（`main_vio_gshare.v` 等、5段 m_proc9）でしか無かった分岐予測を、
**実際に OS が走る KOZOS コア（`main_vio_console.v` の m_proc_console）に統合**して高速化した。

- **予測（フェッチ段）**: `r_pc` で BTB（64エントリ, tag=pc[31:8] でフル PC 一致＝精密）と gshare
  （64エントリ PHT・6bit BHR）を引く。ヒット＆taken 予測なら次 PC を予測分岐先へ（投機フェッチ）。
- **ミス予測検出（P2）**: 分岐の真の次 PC ＝ `taken?tpc:pc+4`。P1 に実フェッチした命令の PC がそれと違えば
  ミス → フラッシュ＋正 PC へ回復。従来の「取られる分岐は毎回 2 サイクルのフラッシュ」を、当たれば無ペナルティに。
- jal/jalr/割込み/トラップは従来通り P2 解決（予測対象外＝リスク限定）。分岐コミット時に BTB/gshare を更新。
- **A/B 測定用に MMIO**（`0x0005_0000`=予測 ON/OFF, `0x0005_0004`=ミス回数, `0x0005_0008`=分岐回数）を追加。
  1 枚のビットストリームで予測 ON/OFF を切り替えて比較できる。

sim（ループ 1000 回、ブートローダで実行）:

| | 予測ON | 予測OFF |
|---|---|---|
| サイクル数 | **9,660** | 12,970（**約26%削減**） |
| ミス予測回数 | 179 | 1,287（**約1/7**） |

KOZOS 回帰（`sum`=5050, `load`=ret=610）で計算結果不変を確認。ビルド WNS +0.960ns。

#### ローダの堅牢化（シリアル雑音耐性）＋ 送信スクリプト

hex を手貼りすると UART RX FIFO（16B）溢れや、ポートのライン揺れで紛れ込む雑音バイトにより **語がずれて誤ロード**することがあった（`read_hex_word` が 16 進以外の文字を「0 の語」と数えてしまうため）。

- **ローダ堅牢化（`kozos_sh.c`）**: `read_hex_word` を「**16 進数字が来るまで読み飛ばす**」に変更。空白に加えて雑音バイト（`0x00`/`0xFF` 等）も無視するので、語ずれが起きない。sim で 0x00/0xFF を注入しても `ret=1010` を確認。
- **送信スクリプト（`gcc/sendprog.py`）**: ホストから `mkload.sh` を呼び、hex を **エコー同期**で 1 語ずつ確実に送る（各語のエコーを待って次を送る＝FIFO 溢れなし）。tio を閉じてから実行：
  ```
  python3 gcc/sendprog.py /dev/ttyUSB4 myprog.c   # -> run.../ret= と 一致 N/N を表示
  ```

実機起動・操作の手順は [`HOWTO_KOZOS.md`](HOWTO_KOZOS.md) にまとめてある。

### 2コア SMP（段1: 共有メモリ + ハードウェアロック）— 第5段-13

自作コアを**2個並べた SMP（対称マルチプロセッサ）**の土台。まずは簡単なコア（`m_smpcore`＝
RV32I の `m_proc_rv32i` に hartid 入力と共有バスを足したもの）で、
「2コアが共有メモリを**正しく排他**できる」ことを最小構成で実証する（`main_vio_smp.v`）。

- **共有ブロック `m_shared`**（`0x0003_xxxx`）: `0x30000`=**test-and-set ロック**（読=TAS: 旧値を返し
  0 なら取得、書=解放）、`0x30004`=共有カウンタ、`0x30008`=hartid、`0x3000C`=done。
  両コアが同一サイクルで TAS しても **core0 優先で解決**（ロック取得が二重にならない、コアのストール不要）。
- **私有メモリ**: IMEM（同一プログラム）と DMEM（各自スタック）は各コア私有。共有は `0x0003_xxxx` のみ。
- **テスト**（`gcc/smp_test.c`）: 両コアが `while(LOCK); COUNT++; LOCK=0;` を各 100 回 → **counter=200 / done=3**。

sim で排他の効果を対比（`gcc/smp_norace.c` = ロック無し版）:

| | 共有カウンタ |
|---|---|
| test-and-set ロック **あり** | **200**（正しい） |
| ロック **なし** | **100**（2コアが同期実行で衝突し半分取りこぼす） |

`create_smp.tcl` でビルド（VIO: probe0=counter, probe1=done）。ビルド WNS +3.229ns。

### 2コア SMP（段2: IPI = コア間割込み）— 第5段-13b

段1の `m_smpcore` は割込み機構が無いので、まず **最小の CSR/割込み**（timer コアから移植:
`mtvec`/`mepc`/`mstatus(MIE/MPIE)`/`mcause`/`mret`/`csrrw/csrrs`）を足し、割込み源を **IPI** にした。

- **IPI 機構**（`m_shared` に追加）: `0x30010`=IPI 送信（書込値の bit で対象コア）、`0x30014`=ack（自コア
  pending クリア）。各コアの pending を割込み源（mip bit3=MSIP 相当）として供給。`mie` bit3(MSIE)+`mstatus`
  MIE で許可すると、pending で `mepc←PC, PC←mtvec, MIE←0`、ハンドラで ack→`mret` 復帰。
- **デモ**（`gcc/ipi_test.c`）: core0 が core1 へ IPI を 50 回送信（受信カウンタでハンドシェイクし 1 件ずつ確実に配送）、
  core1 は `__attribute__((interrupt("machine")))` のハンドラで受信・ack。→ **受信数=50 / done=3**。

sim で 50 IPI の配送・ハンドラ実行を確認（1471 サイクル）。ビルド WNS +3.156ns。

### 2コア SMP（段3: 並列ワークキュー）— 第5段-13c

**2コアが 1 つの共有ワークキューを協調処理**する SMP 並列の実証（実行完了型スケジューリング）。
`m_shared` に汎用共有レジスタ 8 本（`0x30020`〜`0x3003C`）を追加。

- **動作**（`gcc/work_queue.c`）: 共有の `next_task`（キュー）から両コアがロックでタスクを 1 個ずつ取得 →
  **計算（`sum 1..10(k+1)`）はロック無しで並列実行** → 結果を共有 `result` に排他加算。全 20 タスク。
- ロックが守るのは「キュー取得」と「結果加算」だけ。重い計算は 2 コア並列で走る。

sim（全 20 タスク）:

| 項目 | 結果 |
|---|---|
| result（20タスクの総和） | **144550**（期待通り＝取りこぼし無しで正しく同期） |
| hart0 / hart1 処理数 | **10 / 10**（両コアが均等に分担＝並列動作） |
| done | 3 |

`create_smp.tcl` でビルド（VIO: probe0=result=144550, probe1=done=3）。WNS +3.148ns。

### 2コア SMP（段4: スレッド移送型スケジューラ）— 第5段-13d

**スレッドの文脈を共有 RAM に置き、`swtch` で切り替え、1 つのスレッド群を 2 コアで実行**する
本格 SMP スケジューリング。スレッドは一方のコアで中断→**もう一方のコアで再開**（マイグレーション）できる。

- **共有 RAM**（`m_sharedram` = デュアルポート BRAM 4KB, `0x0004_xxxx`）を追加。各コアに 2 本目のメモリポート。
  スレッドのスタックと TCB をここに置く（両コアがアクセス）。同一番地の同時書込はロック／スレッド所有で回避。
- **`swtch`**（`gcc/swtch.S`）: callee-saved(s0-s11, ra) をスタックに退避し sp を保存 / 復元。
  スレッド文脈が共有 RAM 上のスタックに載るので、別コアで復元＝再開できる。
- **スケジューラ**（`gcc/smp_sched.c`）: 各コアのスケジューラ文脈は私有 DMEM のスタック。共有レディキュー
  （`TCB_ST[]`）から READY スレッドをロックで取得→`swtch` で実行。yield で戻り、READY に戻す。
  共有データは全て固定共有 RAM アドレス（C グローバルは私有 DMEM になり移送で不整合になるため）。

sim（3スレッド × 各5回, 毎回 yield）:

| 項目 | 結果 |
|---|---|
| 各スレッドのカウント | **5 / 5 / 5**（全スレッド完走） |
| RANMASK（動いたコアの bit） | 1 / 2 / **3** ← thread2 が**両コアで実行＝マイグレーション成立** |
| 総カウント（VIO probe0） | 15 |

`create_smp.tcl` でビルド。WNS +0.450ns。段1〜4 で 2コア SMP の土台（共有メモリ・ロック・IPI・
並列ワークキュー・スレッド移送）が一通り揃った。

### 2コア SMP（段5: プリエンプション）— 第5段-13e

段4 は協調型（スレッドが `yield()` してくれる前提）だった。**タイマ割込みで yield を強制**し、
yield しない暴走スレッドでも切り替わるようにした（プリエンプティブ SMP）。

- **per-core タイマ**（`0x0006_xxxx`: mtimecmp/mtime）を各コアに追加。MTIP を割込み源に
  （IPI の MSIP と並ぶ。mcause 7/3 で区別）。
- **強制切替**（`gcc/smp_preempt.c`）: `__attribute__((interrupt("machine")))` のタイマハンドラが
  `preempt()`＝`swtch` を呼ぶ。**caller-saved は interrupt 属性が、callee-saved は swtch が退避**するので
  合わせて全文脈が保存され、任意の実行地点で安全に切れる。
- **MIE 規律**: スレッド実行中のみ MIE=1（プリエンプト可）。スケジューラ／ロック保持中は MIE=0。
  スケジューラは各スライス開始時に `mtimecmp = mtime + INTERVAL` を設定（MTIP 解除＋次スライス予約）。
- スケジューラはラウンドロビン化（共有 RR ポインタ）。

sim（**yield しない暴走スレッド×3** を 2 コアで 60,000 サイクル実行）:

| | t0 | t1 | t2 |
|---|---|---|---|
| プリエンプション **ON** | 3781 | 3723 | **3718**（全部進行＝時分割成立） |
| プリエンプション **OFF** | 8512 | 8499 | **0**（2コアを2スレッドが占有→**餓死**） |

`create_smp.tcl` でビルド、WNS +0.509ns（ルーティング輻輳が出たが収束）。
これで 2コア SMP は「共有メモリ・排他・IPI・並列実行・スレッド移送・**プリエンプション**」まで完成。

### 本コアで KOZOS SMP（段A/B1: デュアル console コア + 対話シェル）— 第5段-14

これまでの SMP 実験は簡単なコア（RV32I+VIO）だった。今度は**フル機能の KOZOS コア
（RV32IM＋分岐予測＋CSR/タイマ＋ブートローダ）を 2 個並べ、対話シェル付きの SMP** にする
（`main_vio_smpk.v`、コア= `m_kcore`）。

- **アドレスマップは本コアのまま**（0x0003=per-core タイマ, 0x0004=UART, 0x0005=分岐予測）にし、
  既存 `kozos_sh.c` が無変更で動くようにした。新設: **0x0006=共有ブロック**（TAS ロック/hartid/IPI/done/汎用レジスタ8本）、
  **0x0007=共有 RAM**（デュアルポート 4KB）。
- **UART は 1 本しかない**ので、コアから外に出して **2 ポート調停付き共有ペリフェラル**に
  （TX は両コア書込可・core0 優先、RX と RX 割込みは core0=シェルのみ）。
- **段A**: 2コア構成で core0 の既存シェルが従来通り動く（回帰）。core1 は待機。→ `sum`=5050 / `ps` OK。
- **段B1**: core1 を**ジョブ実行エージェント**にし、シェルに 2 コマンド追加:
  - `smp` … hartid と core1 の生存カウンタ(HB)を表示
  - `rsum <n>` … core1 に sum 1..n を依頼（共有レジスタのメールボックス経由）。待つ間もシェルは `sys_sleep` で OS を回す

```
KOZOS> smp
hart=0 core1_hb=2209        <- core1 が並走している
KOZOS> rsum 1000
core1: 500500               <- 第2コアが計算した結果
```

### 本コアで KOZOS SMP（段B2: カーネル SMP 化）— 第5段-14 完結

KOZOS カーネル自体を SMP 化した（`gcc/kozos_smp.c`）。**対話シェルを持つ本物の SMP OS** になった。

- **TCB とスレッドスタックを共有 RAM（16KB に拡大）へ**移し、**両コアが同じ `ksched` を実行**。
  カーネルはハードウェア TAS ロック（`0x60000`）で直列化（トラップ中= MIE0 で取得するので
  自コアのプリエンプションとはデッドロックしない。ユーザ文脈からは `int_off → klock` の順）。
- **スレッド配置**: shell(t0) は hart0 固定（UART RX/MEIE が core0 のみ）。worker(t1..t4) は**両コアを移動**。
  idle は hart ごとに 1 本（t5=hart0, t6=hart1）。`ST_RUN` 状態を導入し他コアの実行中スレッドを選ばない。
- ticks は hart0 のタイマだけが進める（sleep 起床も hart0 側で処理）。タイマ位相は hart で
  ずらし（1000/1300）、両コアのスケジューリング機会を分散。
- `ps` に **h 列（最後に実行した hart）**を追加。`smp` は各 hart の現スレッドを表示。

sim（`run`×3 でワーカー3本起動後の `ps`）:

```
KOZOS> ps
 t0 RUN   pri=2 h=0 cnt=0     <- シェル(hart0)
 t1 READY pri=1 h=0 cnt=24
 t2 RUN   pri=1 h=1 cnt=21    <- いままさに hart1 で実行中
 t3 READY pri=1 h=1 cnt=18
 t5 READY pri=0 h=0 cnt=0
 t6 RUN   pri=0 h=1 cnt=0
KOZOS> smp
hart0: t0  hart1: t6
KOZOS> sum
5050                          <- 回帰 OK
```

ワーカーが h=0/h=1 に分散し、シェルが応答しつつ**もう一方のコアでスレッドが並列実行**されている。
教科書の最小コアから始めた自作 CPU が、**対話シェル付きデュアルコア SMP OS** まで到達した。
