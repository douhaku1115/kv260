# KV260 MIPS プロジェクト — 現在の状態

## 現在地
**Step 12g-2 完了・実機確認済み**

- Step 1〜12g-2: 実機動作確認済み
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
- 12g-3: eret 復帰 (PC←EPC, SR.EXL←0) (未着手)

## 今後のロードマップ

- Step 12g-3 → 例外処理完成 (eret)。その後 test11(フル例外)・C言語実行(test10)・C テスト群を再確認

## 標準フロー（毎 Step）
1. RTL 変更
2. `vivado.bat -mode batch -source rebuild.tcl` でビルド
3. 新 Vitis ワークスペース作成（XSA: `project_1/design_1_wrapper.xsa`）
4. 実機テスト確認
5. コメント整備 → README.md 更新 → git commit & push

## 実機テストの注意
- **SD カードを抜いてベアメタル実行する**。挿したままだと SD の PetaLinux
  (`kvmipslinux`) が起動し JTAG デバッグと競合 (login プロンプトに入れない/
  `ZynqMP>` U-Boot が出る)。電源OFF→SD抜き→電源ON→Vitis Debug
- Vitis import 時 `UserConfig.cmake` に `"../main.c"` が混入する罠 → 削除必須
  (混入すると src/main.c と二重コンパイルでビルド破綻)
- `Failed to detect FSBL exit` は Vitis 2025.2 の既知警告。シリアルに出力が
  出ていればアプリは動いている。出ない時は電源サイクル→再 Debug
- RTL 不変でテスト(main.c)のみ修正した場合は Vivado 不要、App Build だけで可

## 重要パス
- Vivado: `E:\vivado\2025.2\Vivado\bin\vivado.bat`
- プロジェクト: `E:\fpga\kria260\kv260_mips\`
- XSA: `E:\fpga\kria260\kv260_mips\project_1\design_1_wrapper.xsa`
- Vitis WS: `E:\Xilinx\project_vitis\kv_mips21`（Step 12g-2。kv_mips14〜20 は古い）
- main.c（編集はここのみ）: `E:\fpga\kria260\kv260_mips\vitis_src\main.c`
- git: https://github.com/douhaku1115/kv260.git
