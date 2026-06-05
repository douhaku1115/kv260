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
    ↓ [DPUスレッド]  YOLOv7推論 (~190ms)
    ↓     ↕ キュー (両ステージを重ねる)
    ↓ [メインスレッド] 後処理 (~90ms) + 描画
    ↓
HDMIモニタ (バウンディングボックス+クラス名+FPS表示)
```

## 動作結果

| 項目 | 値 |
|------|-----|
| DPU推論 | ~190ms |
| 後処理 | ~90ms |
| 合計(直列) | ~275ms (3.6 FPS) |
| **合計(パイプライン化後)** | **~200ms (5.0 FPS)** |
| 検出クラス | COCO 80クラス |
| モデルサイズ | 39MB (xmodel) |

DPU推論(ハード)と後処理(CPU)を別スレッドに分けて重ね、3.6→5.0 FPS に向上。DPU 190ms が律速なので、理論上限(~5.3 FPS)にほぼ到達している。

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

## DPUと後処理のパイプライン化 (3.6 → 5.0 FPS)

後処理を90msまで詰めても、1スレッドで「DPU(190ms)→後処理(90ms)」を直列実行すると合計275ms(3.6 FPS)になる。そこで **DPU推論と後処理を別スレッドに分け、キューでつないで重ねる**。

```
[DPUスレッド]   フレーム取得→前処理→DPU推論 → キューへ
                     ↓ queue.Queue(maxsize=1)
[メインスレッド] キューから受信→後処理(decode+NMS)→描画→imshow
```

DPUスレッドがフレームNを推論する裏で、メインスレッドがフレームN-1の後処理を実行する。スループットは `max(DPU側≈200ms, 後処理側≈100ms)≈200ms` となり 5.0 FPS。

```python
def inference_worker(runner, cam, in_w, in_h, output_tensors, result_q, stop_event):
    while not stop_event.is_set():
        ret, frame = cam.read()
        if not ret or frame is None:
            time.sleep(0.001); continue
        # 前処理 + DPU推論
        ...
        output_data = [np.empty(ot.dims, dtype=np.float32) for ot in output_tensors]  # フレーム毎に新規
        job_id = runner.execute_async(input_data, output_data)
        runner.wait(job_id)                      # wait中はVARTがGILを解放
        result_q.put((frame, output_data, infer_ms), timeout=0.5)
```

ポイント:

- **VARTは `wait()` の間 GIL を解放する**。だからDPU待機中にメインスレッドのNumPy後処理が並列に走り、本当に重なる(公式マルチスレッド例がスケールするのと同じ理由)。同一スレッドで `execute_async` 後にそのまま後処理すると重ならない。
- DPU出力バッファは**フレーム毎に新規確保**する。使い回すと、後段が読んでいる間にDPUスレッドが上書きする競合が起きる。
- これ以上はDPU推論190ms自体が壁。さらに上げるなら入力縮小(640→416)や軽量モデルへ。

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
| `cvNamedWindow` not implemented | OpenCVがheadless版 | `pip install opencv-python`(headlessでない版)に入替 |
| `_ARRAY_API not found` / `numpy.core.multiarray failed to import` | NumPy 2.x と OpenCV(1.x向けビルド)の非互換 | コンテナ内で `pip install "numpy<2"` |
| `Check failed: !get_factory().empty()` | DPU未ロード | `sudo xmutil loadapp kv260-benchmark-b4096` |
| `xhost: unable to open display ":1"` | SSH経由でXのアクセス権が無い | `export XAUTHORITY=$(ps -C Xorg -o args=｜grep -oP '(?<=-auth )\S+'｜head -1)` を設定 |
| `unable to find image ... or may require docker login` | スクリプトのタグ名と実イメージのタグが不一致 | `docker tag` で合わせる / `docker images` でタグ確認 |
| `scp: write remote ... Failure` / `No space left` | SD満杯 | load済みのimage tarやaptキャッシュ削除(`apt-get clean`) |
| camera 0 open失敗 | デバイスID違い | `ls /dev/video*`で確認、ID変更 |

## まとめ

- KV260のDPU B4096でYOLOv7 COCO 80クラスのリアルタイム物体検出を実現
- 後処理最適化(sigmoid事前フィルタ + NumPyベクトル化)で 0.6→3.6 FPS
- **DPUと後処理のパイプライン化(別スレッド+キュー)で 3.6→5.0 FPS**。DPU 190msが律速で理論上限近く
- Dockerイメージを作り込んでおけばモデル差し替えだけで別タスクに対応可能。ただしSD入替で消えるので保存(`docker save`)推奨
