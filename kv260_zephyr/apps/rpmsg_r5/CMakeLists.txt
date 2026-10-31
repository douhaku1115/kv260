cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(rpmsg_r5)

# OpenAMP / libmetal と、Zephyr の resource_table.h・addr_translation.h の置き場所
target_include_directories(app PRIVATE ${LIBMETAL_INCLUDE_DIR} ${OPENAMP_INCLUDE_DIR} ${PLATFORM_DIR})
target_sources(app PRIVATE src/main.c)

# リソーステーブルを BTCM に置く (rsc_table.ld の説明を参照)
zephyr_linker_sources(RAM_SECTIONS rsc_table.ld)
