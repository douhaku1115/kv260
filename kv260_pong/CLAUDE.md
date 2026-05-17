# KV260 Pong プロジェクト

KV260 の HDMI Live Video 出力で Pong ゲームを実装。PS 側 C プログラムから PL の AXI スレーブ経由で矩形位置を制御。

## アーキテクチャ

```
PS (C) ──M_AXI_HPM0_FPD──► AXI Interconnect ──► rect_axi_slave
                                                       │
                                                  rect_x, rect_y
                                                       │
                                                       ▼
                                                  rtl_top (CDC)
                                                       │
                                              VGA timing + 矩形描画
                                                       │
                                                       ▼
                                                 dp_live_video_in
                                                       │
                                                       ▼
                                                  HDMI コネクタ → HDMI モニタ
```

## AXI レジスタマップ (0xA0000000)

| オフセット | 名前   | 方向 | 内容 |
|----------|--------|------|------|
| 0x00     | RECT_X | R/W  | 矩形の X 座標 (0〜1279) |
| 0x04     | RECT_Y | R/W  | 矩形の Y 座標 (0〜719)  |

矩形サイズは 50x50 固定 (Phase A1)、色は白固定、背景は青固定。

## 段階的進行

| Phase | 内容 |
|-------|------|
| A1 (現在) | AXI で矩形 1 個の X/Y 制御。PS で左右往復ループ |
| A2 | 矩形数 3 (左パドル/右パドル/ボール) + サイズ/色可変 |
| B  | PS で時間ベースのアニメーション |
| C  | UART キー入力 (w/a/s/d) でパドル操作 |
| D  | ボール反射・衝突判定・スコア表示 → Pong 完成 |

## 重要パス

- プロジェクト: `E:\fpga\kria260\kv260_pong\`
- XSA: `E:\fpga\kria260\kv260_pong\project_1\design_1_wrapper.xsa`
- vivado.tcl: 上書きで完全再構築する
- main.c: `E:\fpga\kria260\kv260_pong\vitis_src\main.c` (編集はここのみ)
- Vivado: `E:\vivado\2025.2\Vivado\bin\vivado.bat`

## 標準フロー

1. RTL or vivado.tcl 編集
2. `vivado.bat -mode batch -source vivado.tcl` でビルド
3. 新 Vitis ワークスペース作成 (例: kv_pong1, kv_pong2, ...)
4. Platform: 新 XSA で作成
5. App: main.c 取り込み、ビルド
6. Debug 実行 (Reset APU ON 推奨)
7. 実機確認: HDMI 矩形が動く

## 関連メモリ

- [[project_kv260_hdmi_rect]] — DPDMA 版の HDMI 矩形描画 (こちらは未完成、Pong はこちらと独立)
- [[feedback_vitis_bsp]] — Vitis 2025.2 の BSP stdout 問題 (Pong も同じ罠の可能性あり)
