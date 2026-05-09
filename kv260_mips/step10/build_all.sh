#!/bin/bash
# build_all.sh — tests/*.c を全てコンパイルして vitis_src/main.c を自動更新する
#
# 使い方 (WSL から):
#   cd /mnt/e/fpga/kria260/kv260_mips/step10
#   bash build_all.sh
#
# 実行後:
#   vitis_src/main.c が更新される → Vitis で再ビルドして実機確認
#
# 新しいCプログラムを追加する方法:
#   1. tests/myprogram.c を作成
#      先頭に // DESCRIPTION: ... と // EXPECTED: ... コメントを書く
#   2. このスクリプトを再実行

set -e
cd "$(dirname "$0")"

echo "=== build_all.sh: C Tests Auto-Build ==="
echo ""
python3 update_main.py
echo ""
echo "=== Complete! Next: rebuild Vitis project ==="
