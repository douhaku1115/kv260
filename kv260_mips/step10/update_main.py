#!/usr/bin/env python3
# update_main.py — tests/*.c を全てコンパイルして vitis_src/main.c を自動更新する
#
# 使い方 (WSL の step10/ ディレクトリで実行):
#   python3 update_main.py
#
# 仕組み:
#   1. tests/*.c を mips-linux-gnu-gcc でコンパイル
#   2. 各バイナリを uint32 配列に変換
#   3. vitis_src/main.c の BEGIN〜END マーカー間を書き換える
#
# tests/*.c の書き方:
#   // DESCRIPTION: プログラムの説明
#   // EXPECTED: 期待する $v0 の値 (10進数)
#   int main(void) { ... }
#
# 注意:
#   - グローバル変数・static変数は使用不可 (dmem/imem分離のため)
#   - ローカル変数 (スタック) のみ使用すること
#   - -O0 コンパイル: ディレイスロット = NOP (本HWに必須)

import os, sys, re, struct, subprocess

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
TESTS_DIR   = os.path.join(SCRIPT_DIR, "tests")
MAIN_C      = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "vitis_src", "main.c"))
MARKER_BEGIN = "// ==== AUTO-GENERATED C TESTS BEGIN (step10/build_all.sh) ===="
MARKER_END   = "// ==== AUTO-GENERATED C TESTS END ===="

CC      = "mips-linux-gnu-gcc"
OBJCOPY = "mips-linux-gnu-objcopy"
CFLAGS  = ["-mips1", "-mfp32", "-EB", "-O0",
           "-ffreestanding", "-nostdlib", "-nostartfiles",
           "-fno-pic", "-mno-abicalls"]
CRT0     = os.path.join(SCRIPT_DIR, "crt0.S")
LDSCRIPT = os.path.join(SCRIPT_DIR, "mips.ld")


def compile_test(cfile):
    name   = os.path.splitext(os.path.basename(cfile))[0]
    elf    = os.path.join(TESTS_DIR, f"{name}.elf")
    binary = os.path.join(TESTS_DIR, f"{name}.bin")
    cmd = [CC] + CFLAGS + [f"-Wl,-T,{LDSCRIPT}", "-o", elf, CRT0, cfile]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  ERROR compiling {os.path.basename(cfile)}:", file=sys.stderr)
        print(r.stderr, file=sys.stderr)
        return None
    subprocess.run([OBJCOPY, "-O", "binary", elf, binary],
                   check=True, capture_output=True)
    return binary


def bin_to_words(binfile):
    with open(binfile, 'rb') as f:
        data = f.read()
    while len(data) % 4 != 0:
        data += b'\x00'
    return [struct.unpack('>I', data[i:i+4])[0] for i in range(0, len(data), 4)]


def parse_meta(cfile):
    expected = description = None
    with open(cfile, encoding='utf-8') as f:
        for line in f:
            m = re.search(r'//\s*EXPECTED:\s*(\S+)', line)
            if m:
                expected = m.group(1)
            m = re.search(r'//\s*DESCRIPTION:\s*(.+)', line)
            if m:
                description = m.group(1).strip()
    return expected, description


def generate_section(cfiles):
    lines     = []
    run_funcs = []

    for cfile in sorted(cfiles):
        name     = os.path.splitext(os.path.basename(cfile))[0]
        expected, desc = parse_meta(cfile)
        label    = desc or name
        exp_str  = expected if expected else "?"

        print(f"  [{name}] compiling...", file=sys.stderr)
        binfile = compile_test(cfile)
        if not binfile:
            print(f"  [{name}] SKIPPED (compile error)", file=sys.stderr)
            continue

        words   = bin_to_words(binfile)
        varname = f"prog_{name}"
        funcname = f"run_c_{name}"

        lines += [
            f"// {'-'*56}",
            f"// C: {label}   Expected: $v0 = {exp_str}",
            f"// {'-'*56}",
            f"static const u32 {varname}[] = {{",
        ]
        for i, w in enumerate(words):
            lines.append(f"    0x{w:08X},  // [{i:3d}] 0x{i*4:04X}")
        lines += [
            f"}};",
            f"#define {varname.upper()}_COUNT"
            f"  (sizeof({varname}) / sizeof({varname}[0]))",
            f"",
            f"static void {funcname}(void)",
            f"{{",
            f'    xil_printf("--- C: {label} ---\\r\\n");',
            f"    mips_reset();",
            f"    mips_load_program({varname}, {varname.upper()}_COUNT);",
            f"    mips_run_cycles(500);",
            f'    xil_printf("PC = 0x%08x\\r\\n", mips_read_pc());',
            f'    xil_printf("Expected: $v0 = {exp_str}\\r\\n");',
            f'    xil_printf("  $v0 = 0x%08x (%d)\\r\\n",'
            f' mips_read_reg(2), mips_read_reg(2));',
            f"}}",
            f"",
        ]
        run_funcs.append(funcname)
        print(f"  [{name}] OK  ({len(words)} words)", file=sys.stderr)

    # run_all_c_tests()
    lines += [
        "static void run_all_c_tests(void)",
        "{",
        '    xil_printf("\\r\\n==== C Program Tests ====\\r\\n\\r\\n");',
    ]
    for fn in run_funcs:
        lines.append(f"    {fn}();")
        lines.append('    xil_printf("\\r\\n");')
    lines += ["}", ""]

    return lines


def main():
    cfiles = sorted([
        os.path.join(TESTS_DIR, f)
        for f in os.listdir(TESTS_DIR)
        if f.endswith('.c')
    ])
    if not cfiles:
        print("No .c files in tests/", file=sys.stderr)
        sys.exit(1)

    print(f"Tests: {[os.path.basename(f) for f in cfiles]}", file=sys.stderr)

    new_lines = generate_section(cfiles)

    with open(MAIN_C, encoding='utf-8') as f:
        original = f.read()

    bi = original.find(MARKER_BEGIN)
    ei = original.find(MARKER_END)
    if bi == -1 or ei == -1:
        print("ERROR: markers not found in main.c", file=sys.stderr)
        print(f"  Expected: '{MARKER_BEGIN}'", file=sys.stderr)
        sys.exit(1)

    before  = original[:bi + len(MARKER_BEGIN)] + "\n\n"
    after   = "\n" + original[ei:]
    updated = before + "\n".join(new_lines) + after

    with open(MAIN_C, 'w', encoding='utf-8') as f:
        f.write(updated)

    print(f"\nDone! {MAIN_C} updated. ({len(cfiles)} tests)", file=sys.stderr)


if __name__ == '__main__':
    main()
