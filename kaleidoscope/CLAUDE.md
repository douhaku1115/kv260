# 万華鏡 FPGA実装プロジェクト

## 最初に必ずやること

1. **`HANDOFF.md` を最後まで読む。** これは作業指示書。読まずに作業を始めない
2. **`ref/target_8point_photo.jpg` と `ref/target_6point_jewel.jpg` を Read ツールで開いて実際に見る。** これが目標映像
3. **`ref/motion.gif` を見る。** 静止画では分からない「動き」が目標の半分を占める
4. **`ref/cell_raw.jpg` を見る。** 万華鏡の折り返しをかける前の原画（Step 4で作るもの）
5. `ref/SCOPE_FS.glsl`（62行）を読む。これが実装の核心

## このプロジェクトは何か

KV260（Kria K26 SOM / Zynq UltraScale+ MPSoC）で、オイル万華鏡の映像を作ってDisplayPortに出す。
参照実装（WebGL版）が `E:\Dropbox\claude\APP\kaleidoscope\index.html` に既にあり、**それと同じ映像を作るのが目標**。
答えは全部そこにある。ゼロから考える必要は無い。

## 禁止事項

- 目標映像の画像・GIFを見ずに実装を始める
- HANDOFF.md の Step順を飛ばす
- **DE10-Nano用のQuartus/TCL資産（`E:\fpga\de10nano\`, `E:\Quartus\`）を流用しようとする** — Intel系。KV260はXilinx系で完全に別物
- 参照実装 `index.html` を書き換える。答え合わせ用の資産なので触らない
- KV260は未セットアップの可能性が高い。**勝手に環境構築を始めない。HANDOFF.md の Step 0 でユーザーに確認する**

## 現在の進捗

- [ ] Step 0: 環境確認
- [ ] Step 1: DisplayPortにテストパターン
- [ ] Step 2: 万華鏡の折り返し（★本番）
- [ ] Step 3: 回転
- [ ] Step 4: ピースの描画
- [ ] Step 5: 物理シミュレーション
- [ ] Step 6: 仕上げ

進んだらこのチェックを更新すること。
