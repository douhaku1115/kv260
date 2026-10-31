cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(kv260_cnn_rtos)

# テスト画像と期待値は apps/cnn と共用 (gen_cnn_data.py で作ったもの)
target_include_directories(app PRIVATE ../cnn/src)
target_sources(app PRIVATE src/main.c)
