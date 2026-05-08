# KV260 MIPS プロジェクト — 現在の状態

## 現在地
**Step 7 完了・push済み**

- Step 1〜7: 実機動作確認済み、origin/master の kv260_mips/ に push 済み
- 次: Step 8 の実装
- クロック: 20MHz（32bit 組み合わせ除算器のタイミング対策、rebuild.tcl で設定）

## 今後のロードマップ

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
- Vitis WS: `E:\Xilinx\project_vitis\kv_mips8`（kv_mips2〜7 は古い）
- git: https://github.com/douhaku1115/kv260.git
