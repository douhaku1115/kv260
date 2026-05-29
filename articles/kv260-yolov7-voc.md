---
title: "KV260のFPGA(DPU)で動かす独自YOLOv7 - 転移学習からデプロイまで全部やった"
emoji: "🦅"
type: "tech"
topics: ["fpga", "kv260", "vitisai", "yolov7", "ディープラーニング"]
published: false
---

## はじめに

XilinxのKria KV260（FPGA SoM）上で、**自分で学習したYOLOv7モデル**を動かしました。COCO事前学習モデルをそのまま動かすのではなく、Pascal VOCで転移学習 → 量子化 → KV260のDPUで推論まで全工程を通したので、ハマりポイントと一緒にまとめます。

**結果**: 167ms/frame（約6FPS）でVOC 20クラスの物体検出を実行

| 入力 | 検出結果 |
|------|----------|
| ![input](https://github.com/douhaku1115/kv260/raw/main/kv260_yolov7_voc/test_room.jpg) | ![result](https://github.com/douhaku1115/kv260/raw/main/kv260_yolov7_voc/test_room_result.jpg) |

リポジトリ: https://github.com/douhaku1115/kv260/tree/main/kv260_yolov7_voc

## 全体の流れ

```
[ホストPC]                              [KV260]
 Ubuntu 24.04                            Ubuntu 22.04
 RTX 5070 Ti                             DPU B4096 (300MHz)
                                         VART 2.5 (Docker内)
   │                                       │
   ① YOLOv7 + COCO事前学習                 │
   ② Pascal VOC 転移学習 (PyTorch 2.7/GPU)  │
   ③ PTQ量子化 (Vitis AI 3.5)              │
   ④ コンパイル (vai_c_xir)                 │
   ⑤ xmodel ──── scp ──────────────────→ ⑥ DPU推論
```

## ハマりポイント先出し

| 問題 | 原因 | 解決策 |
|------|------|--------|
| GPU(RTX 5070 Ti)が認識されない | Vitis AI 3.5 Dockerが古いPyTorch 1.13で、Blackwell(sm_120)非対応 | 学習用と量子化用でDockerを分割 |
| `torch.load` でweights_onlyエラー | PyTorch 2.7のデフォルト変更 | 関連6ファイルで`weights_only=False`を追加 |
| `pytorch_nndct` が無い | 学習Dockerに量子化モジュールが無い | `common.py` の Concat/SPPCSPC に try/except でフォールバック |
| `fingerprint check failure` | VAI 3.5標準のarch.jsonと実機DPUが不一致 | fingerprint直接指定でコンパイル |
| ホストPython実行でsegfault | KV260 apt版`vitis-ai-runtime` 2.0 が VAI 3.5 xmodelと不一致 | Xilinx公式の`xilinx/kria-runtime:2022.1` Docker（VART 2.5）を使用 |

これらを順に説明します。

---

## ① 学習用Dockerの構築（GPU側）

RTX 5070 Tiは最新のBlackwell（sm_120）です。Vitis AI 3.5 Dockerに入っているPyTorch 1.13はsm_120非対応のため、起動直後に：

```
NVIDIA RTX 5070 Ti with CUDA capability sm_120 is not compatible
```

と出てGPU使用不可になります。そこで**学習用と量子化用でDockerを分けます**：

| 用途 | Docker | PyTorch |
|------|--------|---------|
| 学習（GPU） | nvcr.io/nvidia/pytorch:25.04-py3 | 2.7 + CUDA 12.9 |
| 量子化（CPU） | xilinx/vitis-ai-pytorch-gpu:3.5.0.001 | 1.13 |

```bash
docker run --gpus all -it --rm \
  -v /mnt/data/fpga:/workspace \
  nvcr.io/nvidia/pytorch:25.04-py3 bash
```

## ② Pascal VOC で転移学習

VOC 2007 + 2012 をダウンロード（train 16551枚、val 4952枚）：

```bash
wget http://host.robots.ox.ac.uk/pascal/VOC/voc2007/VOCtrainval_06-Nov-2007.tar
wget http://host.robots.ox.ac.uk/pascal/VOC/voc2007/VOCtest_06-Nov-2007.tar
wget http://host.robots.ox.ac.uk/pascal/VOC/voc2012/VOCtrainval_11-May-2012.tar
```

YOLO形式にXML→txt変換し、`data/voc.yaml`を作成：

```yaml
train: ./datasets/VOC/images/train
val: ./datasets/VOC/images/val
nc: 20
names: ['aeroplane', 'bicycle', 'bird', 'boat', 'bottle', 'bus', 'car', 'cat',
        'chair', 'cow', 'diningtable', 'dog', 'horse', 'motorbike', 'person',
        'pottedplant', 'sheep', 'sofa', 'train', 'tvmonitor']
```

COCO事前学習weight `yolov7.pt` から10エポックだけ転移学習：

```bash
python train.py \
  --data data/voc.yaml \
  --cfg cfg/training/yolov7.yaml \
  --weights yolov7.pt \
  --epochs 10 --batch-size 16 --img 640 \
  --name yolov7-voc
```

### `weights_only` 問題

PyTorch 2.7 では `torch.load()` のデフォルトが `weights_only=True` になり、YOLOv7のチェックポイント読み込みが失敗します。**6ファイル**に `weights_only=False` を追加する必要があります：

- `train.py` (×2)
- `models/experimental.py` (×2)  
- `utils/datasets.py`
- `utils/general.py`

## ③ PTQ量子化（Vitis AI 3.5 Docker）

学習用Dockerから抜けて、Vitis AI 3.5 Docker に切り替えます。

ところがここで `from pytorch_nndct.nn.modules import functional as nF` が学習Dockerに無いため、`models/common.py` の `Concat` と `SPPCSPC` でImportError。

**try/exceptで両環境に対応**させます：

```python
class Concat(nn.Module):
    def __init__(self, dimension=1):
        super().__init__()
        self.d = dimension
        try:
            from pytorch_nndct.nn.modules import functional as nF
            self.cat = nF.Cat()
        except ImportError:
            self.cat = None
    def forward(self, x):
        if self.cat is None:
            return torch.cat(x, self.d)
        return self.cat(x, self.d)
```

キャリブレーション50枚（精度より速度重視）：

```bash
python test_nndct.py \
  --data data/voc.yaml --img 640 --batch 1 \
  --weights best_compat.pt \
  --quant_mode calib \
  --nndct_convert_sigmoid_to_hsigmoid \
  --nndct_convert_silu_to_hswish \
  --no-trace
```

**重要オプション**:
- `--nndct_convert_silu_to_hswish`: SiLU（DPU非対応）→ HSwish変換
- `--no-trace`: traceモードのimg_size異常値を回避

xmodel出力：

```bash
python test_nndct.py ... --quant_mode test --dump_model
```

→ `nndct/Model_0_int.xmodel` が生成される

## ④ vai_c_xir でKV260向けコンパイル

VAI 3.5の標準arch.jsonは新しいDPU向けのfingerprintで、KV260 (DPUCZDX8G_ISA1_B4096) と一致しません。**実機のfingerprintを直接指定**します：

```bash
echo '{"fingerprint":"0x101000016010407"}' > /tmp/kv260_arch.json
vai_c_xir \
  -x nndct/Model_0_int.xmodel \
  -a /tmp/kv260_arch.json \
  -o compiled \
  -n yolov7_voc_kv260
```

結果：
- Target: `DPUCZDX8G_ISA1_B4096_0101000016010407`
- DPUサブグラフ: 1個
- xmodelサイズ: 39MB

## ⑤ KV260への転送

```bash
scp yolov7_voc_kv260.xmodel ubuntu@192.168.0.19:~/
scp yolov7_inference.py    ubuntu@192.168.0.19:~/
scp test_*.jpg             ubuntu@192.168.0.19:~/
```

## ⑥ KV260側のDocker環境構築（重要）

**ここで最大のハマりポイント**: KV260のUbuntu 22.04のapt版 `vitis-ai-runtime` は **2.0** で、VAI 3.5のxmodelを実行するとsegfaultします。

```bash
$ sudo XLNX_VART_FIRMWARE=... python3 yolov7_inference.py ...
Segmentation fault
```

`xdputil query` 自体もsegfaultするレベルで、ホスト側ランタイムは使えません。

**解決**: Xilinx公式のKria用Dockerイメージ（VART 2.5入り）を使います：

```bash
sudo docker pull xilinx/kria-runtime:2022.1
sudo docker run -d --name vai-builder xilinx/kria-runtime:2022.1 sleep 300
sudo docker exec vai-builder pip install opencv-python-headless numpy
sudo docker commit vai-builder vai-yolov7:v4
sudo docker rm -f vai-builder
```

これで `vai-yolov7:v4` には VART 2.5 + numpy + OpenCV が入って永続化されます。

## ⑦ 推論実行

DPUファームウェアをロード：

```bash
sudo xmutil unloadapp
sudo xmutil loadapp kv260-benchmark-b4096
```

実行スクリプト `run_yolo.sh`:

```bash
#!/bin/bash
XCLBIN=/lib/firmware/xilinx/kv260-benchmark-b4096/kv260-benchmark-b4096.xclbin
sudo docker run --rm \
  -v /home/ubuntu:/work \
  -v /dev:/dev \
  -v /run:/run \
  -v /lib/firmware/xilinx:/lib/firmware/xilinx \
  --privileged \
  -w /work \
  -e XLNX_VART_FIRMWARE=$XCLBIN \
  vai-yolov7:v4 \
  python3 /work/yolov7_inference.py /work/yolov7_voc_kv260.xmodel /work/$1
```

```bash
bash ~/run_yolo.sh test_voc.jpg
```

## 結果

### 鳥（test_voc.jpg）

![bird](https://github.com/douhaku1115/kv260/raw/main/kv260_yolov7_voc/test_voc_result.jpg)

```
Inference time: 167.1 ms
Detections: 9
  bird: 0.961
  bird: 0.868
  cow: 0.619  ← 誤検出（岩を牛と認識）
  ...
```

主役の鳥2羽を高信頼度で検出。岩肌をcow/sheepと誤検出（学習10エポックの限界）。

### 室内（test_room.jpg）

![room](https://github.com/douhaku1115/kv260/raw/main/kv260_yolov7_voc/test_room_result.jpg)

```
Detections: 11
  chair: 0.952
  tvmonitor: 0.938
  person: 0.852
  diningtable: 0.558
  ...
```

人物・TV・椅子・テーブルを高信頼度で検出。ソファをchairと誤分類（sofaクラスが未収束）。

### 街路（test_street.jpg）

![street](https://github.com/douhaku1115/kv260/raw/main/kv260_yolov7_voc/test_street_result.jpg)

```
Detections: 5
  car: 0.980
  car: 0.777
  bus: 0.616
  tvmonitor: 0.678  ← 電光掲示板を誤検出（理にかなった誤検出）
  ...
```

タクシー・バスを正確に検出。電光掲示板をTVと検出するのは、ある意味自然な誤検出。

### 性能まとめ

| 画像 | 検出数 | 主検出 | 推論時間 |
|------|--------|--------|----------|
| test_voc.jpg | 9 | bird×2 | 167ms |
| test_room.jpg | 11 | person, TV, chair, table | 167ms |
| test_street.jpg | 5 | car×3, bus | 167ms |

**全画像で167ms (6FPS) で安定動作**。

## まとめ

KV260のFPGA DPU上で**自前学習のYOLOv7（VOC 20クラス）**を6FPSで動かすことに成功しました。

- 学習: 10エポックでも主要クラスは検出可能
- 量子化: PTQ 50枚キャリブレーションで6FPS
- ランタイム: KV260のapt版は使えない、必ずVART 2.5以降のDocker

精度を上げるなら以下：
- エポック数を増やす（50〜100）
- キャリブレーション枚数を増やす（500〜1000）
- QAT（量子化考慮再学習）で mAP +7程度向上

次は**C++実装で後処理高速化（Python 90ms → C++で短縮）**、もしくは**HLSでTransformerをFPGA実装**を予定。

## 環境

- ホストPC: Ubuntu 24.04, RTX 5070 Ti, Vitis AI 3.5
- KV260: Ubuntu 22.04, DPU B4096 (DPUCZDX8G_ISA1_B4096), XRT 2.13.0
- 学習: nvcr.io/nvidia/pytorch:25.04-py3
- 量子化: xilinx/vitis-ai-pytorch-gpu:3.5.0.001
- 推論: xilinx/kria-runtime:2022.1 ベース

## 参考

- [Vitis AI 3.5 Documentation](https://xilinx.github.io/Vitis-AI/3.5/html/index.html)
- [YOLOv7 (Copyleft Model Zoo)](https://github.com/Xilinx/Vitis-AI-Copyleft-Model-Zoo)
- [リポジトリ全体](https://github.com/douhaku1115/kv260)
