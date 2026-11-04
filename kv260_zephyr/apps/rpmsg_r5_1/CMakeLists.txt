cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(rpmsg_r5_1)

# R5_1 (2 コア目)。起動の仕組みは apps/rpmsg_r5 と同じで、リンカの工夫 (linker.ld / rsc_table.ld) もそちらを使う
target_include_directories(app PRIVATE ${LIBMETAL_INCLUDE_DIR} ${OPENAMP_INCLUDE_DIR} ${PLATFORM_DIR})
target_sources(app PRIVATE src/main.c)

zephyr_linker_sources(RAM_SECTIONS ${CMAKE_CURRENT_SOURCE_DIR}/../rpmsg_r5/rsc_table.ld)
