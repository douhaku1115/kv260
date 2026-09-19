# -*- coding: utf-8 -*-
"""Vitis の Debug 構成 (launch.json) が指すファイルが実在するかを調べる。

  使い方:  python tools/check_launch.py <ワークスペースのパス>
"""
import json
import os
import sys

BASE = sys.argv[1] if len(sys.argv) > 1 else "E:/Xilinx/project_vitis/kv260_kaleido"


def main():
    lj = None
    for root, _, files in os.walk(BASE):
        if "launch.json" in files and "_ide" in root:
            lj = os.path.join(root, "launch.json")
            break
    if not lj:
        print("launch.json が見つからない")
        return

    d = json.load(open(lj, encoding="utf-8"))
    t = d["configurations"][0]["targetSetup"]
    z = t["zuInitialization"]
    print("resetSystem=%s  resetAPU=%s  programDevice=%s"
          % (t["resetSystem"], t["resetAPU"], t["programDevice"]))
    print("isFsbl=%s  initWithFSBL=%s  runPsuInit=%s"
          % (z["isFsbl"], z["usingFSBL"]["initWithFSBL"], z["usingPsuInit"]["runPsuInit"]))
    print()

    items = [
        ("fsbl",     z["usingFSBL"]["fsblFile"]),
        ("psu_init", z["usingPsuInit"]["psuInitTclFile"]),
        ("bit",      t["bitstreamFile"]),
        ("elf",      t["downloadElf"][0]["elfFile"]),
    ]
    for name, p in items:
        q = p.replace("${workspaceFolder}", BASE).replace("\\", "/")
        ok = os.path.exists(q)
        mt = ""
        if ok:
            import time
            mt = time.strftime("%m/%d %H:%M", time.localtime(os.path.getmtime(q)))
        print("%-9s %-4s %-12s %s" % (name, "ある" if ok else "ない", mt, q.replace(BASE + "/", "")))


if __name__ == "__main__":
    main()
