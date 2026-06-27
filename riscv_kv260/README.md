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
| `src/sim_bp.v` | `main_vio_bp.v` の iverilog 検証用テストベンチ（Xilinx IP はスタブ） |
| `src/sim_cache.v` | `main_vio_cache.v` / `main_vio_2way.v` の iverilog 検証用テストベンチ |
| `src/asm.txt` | 命令メモリに焼き込むプログラム（Σ0..100=5050、手アセンブル） |
| `src/asm_nested.txt` | ネストループ（code7-10、結果505）。gshareの効果検証用 |
| `src/asm_conflict.txt` | コンフリクト用（code8-11、低位/高位がインデックス衝突、結果5050）。2-wayの効果検証用 |
| `create_vio_full.tcl` | 4段版プロジェクト生成（Vivado batch） |
| `create_4stage.tcl` | 5段版プロジェクト生成＋ビットストリームまで |
| `create_bp.tcl` | 分岐予測版（BTB+bimodal）生成＋ビットストリームまで（VIO入力3本） |
| `create_gshare.tcl` | gshare版生成＋ビットストリームまで（VIO入力3本、ネストループ） |
| `create_cache.tcl` | 命令キャッシュ版生成＋ビットストリームまで（VIO入力3本） |
| `create_2way.tcl` | 2-wayキャッシュ版生成＋ビットストリームまで（VIO入力3本、コンフリクト用） |

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
