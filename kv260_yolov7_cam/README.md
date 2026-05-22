# KV260 YOLOv7 リアルタイムカメラ物体検出

USBカメラの映像をYOLOv7 + DPU B4096でリアルタイム物体検出し、HDMIモニタに結果を表示する。
案8（kv260_yolov7_dpu）で作成したxmodelをそのまま流用。

## 動作結果

- DPU推論: 185ms/frame
- 合計: 275ms/frame（3.6 FPS）
- 80クラス（COCO）のリアルタイム検出

## ファイル構成

```
kv260_yolov7_cam/
├── README.md
├── yolov7_cam.py       ... カメラ取得 → DPU推論 → 描画 → 表示のメインスクリプト
└── run_yolo_cam.sh     ... Docker起動ラッパー
```

## 処理の全体フロー

```
main()
  │
  ├─ xir.Graph.deserialize()          ← xmodelロード（案8で量子化済み）
  ├─ vart.Runner.create_runner()      ← DPUランナー生成
  │
  ├─ CameraThread(camera_id)          ← カメラ取得スレッド起動
  │     別スレッドでcv2.VideoCapture.read()を常時実行
  │     最新フレームをlock付きで保持
  │
  └─ メインループ
       │
       ├─ cam.read()                  ← 最新フレーム取得（ノンブロッキング）
       │
       ├─ 前処理
       │     BGR→RGB変換
       │     640x640にリサイズ
       │     float32正規化（/255.0）
       │
       ├─ DPU推論（185ms）
       │     execute_async() + wait()
       │     出力: 3スケール [80x80, 40x40, 20x20] x 3アンカー x 85
       │
       ├─ 後処理（~90ms）
       │     decode_outputs()         ← アンカーベースデコード（NumPyベクトル化）
       │     nms()                    ← Non-Maximum Suppression
       │
       ├─ 描画
       │     バウンディングボックス + クラス名 + スコア
       │     DPU時間 / 合計時間 / FPS / 検出数を左上に表示
       │
       └─ cv2.imshow()                ← HDMIモニタに表示
            'q'キーで終了
```

## 後処理の高速化

初期実装（Python 3重forループ）では後処理に約1400msかかり、全体で0.6 FPSだった。
以下の最適化で90msまで短縮（約15倍高速化）:

### 1. 事前フィルタリング（sigmoidスキップ）

sigmoid(x) > threshold は x > log(threshold / (1 - threshold)) と等価。
全グリッドにsigmoidを計算せず、生の値で閾値比較してから、通過した検出のみsigmoidを計算する。

```python
raw_thresh = np.log(conf_thresh / (1.0 - conf_thresh))
mask = raw_obj > raw_thresh       # sigmoid前にフィルタ
ays, axs, ans = np.where(mask)    # 通過したインデックスのみ
det = out[ays, axs, ans]          # 必要な検出だけ取り出す
```

### 2. NumPyベクトル化

3重forループ（grid_h x grid_w x 3 = 25,200回）を廃止し、NumPyの一括演算に置き換え。

```
Before: for ay in range(80): for ax in range(80): for a in range(3): ...  → 1400ms
After:  np.where(mask) + 一括sigmoid + 一括座標計算                      →   90ms
```

## 実行方法

### 前提条件

- 案8（kv260_yolov7_dpu）のxmodelとDockerイメージ（vai-yolov7:v2）がKV260上にあること
- USBカメラがKV260に接続されていること（/dev/video0）
- KV260のHDMIモニタ前で直接操作すること（SSH経由ではX11表示不可）

### 手順

1. DPUファームウェアをロード
```
sudo xmutil unloadapp
sudo xmutil loadapp kv260-benchmark-b4096
```

2. X11アクセスを許可
```
export DISPLAY=:1
xhost +local:
```

3. 実行
```
DISPLAY=:1 bash ~/run_yolo_cam.sh
```

4. 終了: HDMIモニタ上のウィンドウで `q` キーを押す

### カメラIDを変更する場合

```
DISPLAY=:1 bash ~/run_yolo_cam.sh 1
```

## パフォーマンス内訳

| 処理 | 時間 | 備考 |
|------|------|------|
| カメラ取得 | ~0ms | 別スレッドで常時取得 |
| 前処理（resize+正規化） | ~15ms | 640x480→640x640 |
| DPU推論 | ~185ms | DPUCZDX8G B4096, 300MHz |
| 後処理（デコード+NMS） | ~90ms | NumPyベクトル化版 |
| 描画+表示 | ~10ms | cv2.imshow (X11) |
| **合計** | **~275ms** | **3.6 FPS** |

## 試行した最適化とその結果

| 最適化 | 結果 | 理由 |
|--------|------|------|
| Python 3重forループ → NumPyベクトル化 | 1400ms → 270ms | ループ廃止で大幅改善 |
| sigmoid事前フィルタ | 270ms → 90ms | 演算対象を大幅削減 |
| カメラ取得スレッド化 | 効果なし | DPUがボトルネックのため |
| DPU推論+後処理パイプライン化 | 効果なし | execute_asyncが実際にはブロックするため |

## 環境

- KV260 Ubuntu 22.04
- DPU: DPUCZDX8G_ISA1_B4096 (300MHz)
- Docker: vai-yolov7:v2 (Vitis AI runtime + OpenCV GUI)
- xmodel: 案8で量子化・コンパイル済みYOLOv7
- USBカメラ: UVC対応 640x480
- 表示: HDMI (cv2.imshow, X11, DISPLAY=:1)
