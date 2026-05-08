# KV260 MIPS プロジェクト — 現在の状態

## 現在地
**Step 8 完了・push済み**

- Step 1〜8: 実機動作確認済み、origin/main の kv260_mips/ に push 済み
- クロック: 20MHz（32bit 組み合わせ除算器のタイミング対策、rebuild.tcl で設定）

## 今後のロードマップ

次の Step は未定。

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
- Vitis WS: `E:\Xilinx\project_vitis\kv_mips9`（kv_mips2〜8 は古い）
- main.c（編集はここのみ）: `E:\fpga\kria260\kv260_mips\vitis_src\main.c`
- git: https://github.com/douhaku1115/kv260.git
