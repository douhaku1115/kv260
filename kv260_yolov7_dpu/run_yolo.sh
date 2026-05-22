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
  vai-yolov7:v1 \
  python3 /work/yolov7_inference.py /work/yolov7_kv260.xmodel /work/$1
