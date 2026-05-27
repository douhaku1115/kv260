# KV260 MIPS プロジェクト — 現在の状態

## 現在地
**Step 12f 完了・実機確認済み**

- Step 1〜12f: 実機動作確認済み
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
- 12g (Step 13 と統合検討): 例外処理 (Step 11) のパイプライン化 (未着手)

## 今後のロードマップ

- Step 12g 対応 → 全 Step 1〜11 をパイプラインで再現。C 言語実行(test10)も再確認

## 標準フロー（毎 Step）
1. RTL 変更
2. `vivado.bat -mode batch -source rebuild.tcl` でビルド
3. 新 Vitis ワークスペース作成（XSA: `project_1/design_1_wrapper.xsa`）
4. 実機テスト確認
5. コメント整備 → README.md 更新 → git commit & push

## 重要パス
- Vivado: `E:\vivado\2025.2\Vivado\bin\vivado.bat`
- プロジェクト: `E:\fpga\kria260\kv260_mips\`
- XSA: `E:\fpga\kria260\kv260_mips\project_1\design_1_wrapper.xsa`
- Vitis WS: `E:\Xilinx\project_vitis\kv_mips19`（Step 12f。kv_mips14〜18 は古い）
- main.c（編集はここのみ）: `E:\fpga\kria260\kv260_mips\vitis_src\main.c`
- git: https://github.com/douhaku1115/kv260.git
