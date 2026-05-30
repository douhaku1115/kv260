#!/bin/bash
XCLBIN=/lib/firmware/xilinx/kv260-benchmark-b4096/kv260-benchmark-b4096.xclbin
sudo docker run --rm \
  -v /home/ubuntu:/work \
  -v /dev:/dev \
  -v /run:/run \
  -v /lib/firmware/xilinx:/lib/firmware/xilinx \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -e DISPLAY=$DISPLAY \
  -e XLNX_VART_FIRMWARE=$XCLBIN \
  --privileged \
  --net=host \
  -w /work \
  vai-yolov7:v5 \
  python3 /work/yolov7_cam.py /work/yolov7_kv260.xmodel ${1:-0}
