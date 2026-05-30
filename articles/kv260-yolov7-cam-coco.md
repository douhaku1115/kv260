---
title: "KV260でYOLOv7 COCO 80クラス リアルタイムカメラ物体検出"
emoji: "📷"
type: "tech"
topics: ["fpga", "kv260", "vitisai", "yolov7", "objectdetection"]
published: true
---

## はじめに

KV260のDPU (B4096) を使い、USBカメラの映像をYOLOv7でリアルタイム物体検出する。COCO 80クラスモデルにより、人・車・動物・家具など幅広い物体を検出できる。

## 構成

```
USBカメラ (640x480)
    ↓
KV260 (Zynq UltraScale+ / DPU B4096)
    ↓ YOLOv7推論 (~185ms)
    ↓ 後処理 (~90ms)
    ↓
HDMIモニタ (バウンディングボックス+クラス名+FPS表示)
```

## 動作結果

| 項目 | 値 |
|------|-----|
| DPU推論 | ~185ms |
| 後処理 | ~90ms |
| 合計 | ~320ms (3.1 FPS) |
| 検出クラス | COCO 80クラス |
| モデルサイズ | 39MB (xmodel) |

## 前提条件

- KV260 Ubuntu 22.04 (Kria公式イメージ)
- DPU: DPUCZDX8G_ISA1_B4096 (kv260-benchmark-b4096)
- Docker: vai-yolov7:v5 (Vitis AI runtime 2.5 + OpenCV + GTK)
- USBカメラ (UVC対応)
- HDMIモニタ接続

## 手順

### 1. モデル準備

Vitis AI Model ZooのYOLOv7をB4096用にコンパイルしたxmodelを使用。

```bash
# KV260の~/にyolov7_kv260.xmodelを配置
ls ~/yolov7_kv260.xmodel
```

### 2. DPUファームウェアロード

```bash
sudo xmutil unloadapp
sudo xmutil loadapp kv260-benchmark-b4096
```

### 3. X11設定

HDMIモニタの前で操作する（SSH経由ではなく直接）。

```bash
export DISPLAY=:1
xhost +local:
```

### 4. 推論実行

```bash
sudo docker run --rm \
  -v /home/ubuntu:/work \
  -v /dev:/dev \
  -v /run:/run \
  -v /lib/firmware/xilinx:/lib/firmware/xilinx \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -e DISPLAY=$DISPLAY \
  -e XLNX_VART_FIRMWARE=/lib/firmware/xilinx/kv260-benchmark-b4096/kv260-benchmark-b4096.xclbin \
  --privileged \
  --net=host \
  -w /work \
  vai-yolov7:v5 \
  python3 /work/yolov7_cam.py /work/yolov7_kv260.xmodel 1
```

カメラIDは末尾の数字（`0`または`1`）で切り替え可能。

### 5. 終了

HDMIモニタ上のウィンドウで `q` キーを押す。

## 後処理の高速化ポイント

Python版の後処理で0.6FPS→3.1FPSに改善した手法:

### sigmoid事前フィルタ

sigmoid(x) > threshold は x > log(threshold/(1-threshold)) と等価。全グリッドにsigmoidを計算せず、生の値で比較して通過した検出のみ処理する。

```python
raw_thresh = np.log(conf_thresh / (1.0 - conf_thresh))
mask = raw_obj > raw_thresh  # sigmoid前にフィルタ
```

### NumPyベクトル化

3重forループ(80x80x3=19,200回)を廃止し、`np.where` + 一括演算に置き換え。

```
Before: 3重forループ → 1400ms
After:  NumPyベクトル化 + sigmoid事前フィルタ → 90ms
```

## Docker環境構築メモ

`vai-yolov7:v5`は以下で構築:

```bash
# ベース: xilinx/kria-runtime:2022.1 (VART 2.5入り)
# 追加: pip install vart xir opencv-python numpy
# GTK: apt install libgtk2.0-0
# OpenCV: pip install opencv-python (headlessではない版)
```

:::message
`opencv-python-headless`ではcv2.imshowが使えない。必ず`opencv-python`を使うこと。
:::

## トラブルシューティング

| エラー | 原因 | 対策 |
|--------|------|------|
| `cvNamedWindow` not implemented | OpenCVがheadless版 | `pip install opencv-python`に入替 |
| `Check failed: !get_factory().empty()` | DPU未ロード | `sudo xmutil loadapp kv260-benchmark-b4096` |
| `xhost: unable to open display ""` | DISPLAY未設定 | `export DISPLAY=:1` |
| camera 0 open失敗 | デバイスID違い | `ls /dev/video*`で確認、ID変更 |
| ディスク容量不足 | Docker/tar.gz等 | 不要なtar.gz削除 |

## まとめ

- KV260のDPU B4096でYOLOv7 COCO 80クラスのリアルタイム物体検出を実現
- 3.1 FPSで人・車・動物など幅広い物体を検出
- Python後処理の最適化（sigmoid事前フィルタ + NumPyベクトル化）が重要
- Dockerイメージを作り込んでおけばモデル差し替えだけで別タスクに対応可能
