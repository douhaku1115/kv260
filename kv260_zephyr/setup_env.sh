#!/bin/bash
# WSL に Zephyr のビルド環境を作る（sudo 不要）
set -e
T0=$(date +%s)
mkdir -p ~/zephyrproject
if [ ! -x ~/zephyrproject/.venv/bin/pip ]; then
  python3 -m venv --without-pip ~/zephyrproject/.venv
  curl -sSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
  ~/zephyrproject/.venv/bin/python /tmp/get-pip.py -q
fi
source ~/zephyrproject/.venv/bin/activate
pip install -q west cmake ninja
cd ~/zephyrproject
[ -d .west ] || west init .
# 使わない hal を除いて取得量を減らす
west config manifest.project-filter -- '-hal_.*,+hal_xilinx,+cmsis,+cmsis_6'
west update --narrow -o=--depth=1
pip install -q -r zephyr/scripts/requirements-base.txt
echo "ENV_DONE $(( $(date +%s) - T0 ))s"
du -sh ~/zephyrproject
