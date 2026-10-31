cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(kv260_amp_r5)

# A53 と共通の取り決め (amp_shared.h)
target_include_directories(app PRIVATE ../..)
target_sources(app PRIVATE src/main.c)
