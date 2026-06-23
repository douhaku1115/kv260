# KV260 MIPS プロジェクト — 現在の状態

## 現在地
**OS-prep2b 完了・実機確認済み（タイマ割込達成、プリエンプティブの土台完成）**

- Step 1〜12g-3: パイプライン化 全機能 実機動作確認済み
- OS-prep1: 統一メモリ(von Neumann)化。test_vn (自己書き換え) で $5=0x77 実機確認
- OS-prep2a: CP0 Count($9)/Compare($11)。Count自動+1 ($1=4<$2=8)、Compare=0x40 実機確認
- OS-prep2b: タイマ割込。SR[1]=IE新設、timer_pendingフラグ(IP7相当)で取りこぼし防止。test_timer_b で $1=140 実機確認
- 単一サイクル版 (`mips_top.v`) は Step 11 で完成、`mips_top_pipe.v` (Step 12) に切替済み
- 切り戻し: `mips_axi.v` で `mips_top_pipe` → `mips_top` に変更すれば単一サイクルに戻る
- クロック: 20MHz（rebuild.tcl で設定）

## Step 12 サブステップ進捗

- 12a: パイプライン基本構造 ✓
- 12b: フォワーディング + WB→ID バイパス ✓
- 12c: lw/sw + ロードユースストール ✓
- 12d: beq/bne + j/jal/jr + フラッシュ ✓
- 12e: lui/ori/andi/xori/シフト/blez 系/addiu/addu/subu/sltu/sltiu/nor ✓
- 12f: mult/multu/div/divu/mfhi/mflo + lb/lbu/lh/lhu/sb/sh ✓
- 12g-1: CP0 (SR/Cause/EPC) + mfc0/mtc0 ✓
- 12g-2: syscall/overflow 例外発生 + 0x80 リダイレクト + フラッシュ ✓
- 12g-3: eret 復帰 (PC←EPC, SR.EXL←0)、test11 フル例外合格 ✓

## OS 実装 (Step 12 完了後、新フェーズ)

- **OS-prep1: von Neumann 化** ✓ (unified_mem.v で imem/dmem 統合、test_vn で $5=0x77 実機確認)
- **OS-prep2a: CP0 Count/Compare レジスタ** ✓ (Count自動+1, Compare読み書き 実機確認)
- **OS-prep2b: タイマ割込** ✓ (SR[1]=IE, timer_pendingフラグ, test_timer_b で $1=140 実機確認)
  - 重要な学び: Count==Compare は1サイクルのみ→ペンディングフラグ保持しないと割込取りこぼし($1=2)。フラグ追加で$1=140
- OS-1: 協調マルチタスク (yield, コンテキスト保存/復元) — 次
- OS-2: プリエンプティブ (タイマ割込でラウンドロビン) — 未着手
- 注: 既存テスト(Test1〜11)は Harvard 前提で統一メモリでは一部干渉(既知、OS実装に影響なし)

## 今後のロードマップ

- パイプライン化(Step 12)は例外処理まで完了。残: C言語実行(test10)・C テスト群をパイプラインで再確認

## 標準フロー（毎 Step）
1. RTL 変更
2. `vivado.bat -mode batch -source rebuild.tcl` でビルド
3. 新 Vitis ワークスペース作成（XSA: `project_1/design_1_wrapper.xsa`）
4. 実機テスト確認
5. コメント整備 → README.md 更新 → git commit & push

## 実機テストの注意
- **★QSPIブート競合 (2026-06 判明、確立した対処)**: このKV260はQSPIにブート
  イメージが書かれており、SD抜いても `QSPI 32bit Boot Mode`→PMU→BL31→U-Boot
  (`ZynqMP>`) とフルブートする。これがJTAGデバッグと競合し
  `Failed to detect FSBL exit` / `Could not find ARM device` / `AP transaction timeout`
  が出る。**確実な対処** = U-Boot を起動完了させて (ZynqMP> まで待つ=DAP有効化)、
  Vitis の Debug Configuration で **Board Initialization = None** にし
  (FSBL/psu_init を実行せず U-Boot 済みのPS初期化を流用)、アプリだけJTAGロード。
  → main で停止 → Resume でシリアルに出力。mips22/mips23 ともこの方法で成功。
- Board Init で FSBL→TCL(psu_init)に変えるのも一案だが、QSPIブートと二重初期化で
  AP timeout が出るため、None が最も確実
- SD カードは抜いたままでよい (QSPIブートなので SD有無は競合に無関係)
- Vitis import 時 `UserConfig.cmake` に `"../main.c"` が混入する罠 → 削除必須
  (混入すると src/main.c と二重コンパイルでビルド破綻)
- RTL 不変でテスト(main.c)のみ修正した場合は Vivado 不要、App Build だけで可

## 重要パス
- Vivado: `E:\vivado\2025.2\Vivado\bin\vivado.bat`
- プロジェクト: `E:\fpga\kria260\kv260_mips\`
- XSA: `E:\fpga\kria260\kv260_mips\project_1\design_1_wrapper.xsa`
- Vitis WS: `E:\Xilinx\project_vitis\kv_mips26`（OS-prep2b。kv_mips14〜25 は古い）
- main.c（編集はここのみ）: `E:\fpga\kria260\kv260_mips\vitis_src\main.c`
- git: https://github.com/douhaku1115/kv260.git
