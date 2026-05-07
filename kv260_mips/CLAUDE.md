# KV260 MIPS プロジェクト — 現在の状態

## 現在地
**Step 6 完了・push済み**

- Step 1〜6: 実機動作確認済み、origin/main の kv260_mips/ に push 済み
- 次: Step 7 → Step 8 の順で実装

## 今後のロードマップ

### Step 7（HI/LO レジスタ新規追加）
mult, mflo, mfhi, div, multu, divu
- HI/LOレジスタ（regfile外の専用レジスタ）新規追加
- datapath.v / control.v / alu.v 変更必要

### Step 8（dmem バイト enable 対応）
lb, lbu, lh, lhu, sb, sh
- dmem.v にバイト/ハーフワード enable 対応が必要

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
- Vitis WS: `E:\Xilinx\project_vitis\kv_mips2`（kv_mips は古い）
- git: https://github.com/douhaku1115/kv260.git
