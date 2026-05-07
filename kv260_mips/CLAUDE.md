# KV260 MIPS プロジェクト — 現在の状態

## 現在地
**Step 5 完了・git push 待ち**

- Step 1〜5: 実機動作確認済み
- 次の作業: git commit & push → 次の Step を検討

## Step 5 で追加する命令（7命令）

### Group A — control.v の case 追加のみ
| 命令  | opcode   | 動作                        |
|------|----------|---------------------------|
| andi | 001100   | rt = rs & zero_extend(imm) |
| xori | 001110   | rt = rs ^ zero_extend(imm) |
| slti | 001010   | rt = (rs < sign_imm) ? 1:0 |
| addiu| 001001   | rt = rs + imm（オーバーフロー無視）|

### Group B — datapath / ALU 変更必要
| 命令  | funct  | 動作                     |
|------|--------|--------------------------|
| sll  | 000000 | rd = rt << shamt         |
| srl  | 000010 | rd = rt >> shamt（論理）  |
| sra  | 000011 | rd = rt >>> shamt（算術） |

> xori は ALU に XOR 追加、sll/srl/sra は shamt フィールドを datapath に配線する必要あり

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
