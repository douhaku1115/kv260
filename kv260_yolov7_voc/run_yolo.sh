#!/bin/bash
# YOLOv7 VOC inference on KV260 DPU
# Usage: bash run_yolo.sh <image>
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
