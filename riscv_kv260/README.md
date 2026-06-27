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
| `src/sim_bp.v` | `main_vio_bp.v` の iverilog 検証用テストベンチ（Xilinx IP はスタブ） |
| `src/asm.txt` | 命令メモリに焼き込むプログラム（Σ0..100=5050、手アセンブル） |
| `create_vio_full.tcl` | 4段版プロジェクト生成（Vivado batch） |
| `create_4stage.tcl` | 5段版プロジェクト生成＋ビットストリームまで |
| `create_bp.tcl` | 分岐予測版プロジェクト生成＋ビットストリームまで（VIO入力3本） |

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
