#!/usr/bin/env python3
"""Print the cache/memory/SIMD profile of this machine (human-readable).

The standalone CLI counterpart to scripts/hardware_json.py (which emits the
JSON + machine_id used as a data dimension). The bench
(src/framework/hardware.zig) prints the same facts at the start of every run;
this script is for capturing a machine's profile once.

On macOS these come from sysctl; on Linux read /sys and /proc (the JSON
counterpart hardware_json.py already cross-platforms; this printer focuses on
the macOS sysctl view).

Usage:  scripts/hardware_profile.py
"""
from __future__ import annotations

import datetime
import os
import platform
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def sh(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ""


def sysctl(name: str) -> str:
    return sh(["sysctl", "-n", name])


def main() -> int:
    import json
    hw = subprocess.run([sys.executable,
                         os.path.join(ROOT, "scripts", "hardware_json.py")],
                        capture_output=True, text=True).stdout
    facts = json.loads(hw)

    print("=== Hardware profile ===")
    print(f"date   : {datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}")
    print(f"host   : {facts['hostname']}")
    print(f"os     : {facts['os']} ({facts['arch']})")
    print(f"machine_id : {facts['machine_id']}")
    print()
    print(f"cpu    : {facts.get('cpu', 'unknown')}")
    print(f"cores  : physical={facts.get('physicalcpu')} "
          f"logical={facts.get('logicalcpu')}")
    print()
    print("=== Cache / memory ===")
    for k in ("cachelinesize", "l1dcachesize", "l1icachesize", "l2cachesize",
              "l3cachesize", "pagesize", "memsize_bytes"):
        print(f"  {k:<22} = {facts.get(k)}")
    print()
    print("=== streaming bandwidth (measured) ===")
    print(f"  streaming_bw_gbs   = {facts.get('streaming_bw_gbs')}")
    print()
    if platform.system() == "Darwin":
        print("=== SIMD / feature flags (subset) ===")
        out = sh(["sysctl", "-a"])
        for line in out.splitlines():
            if re_match(line):
                print(f"  {line}")
    return 0


def re_match(line: str) -> bool:
    return ("hw.optional.neon" in line or "hw.optional.AdvSIMD" in line
            or "hw.optional.armv8" in line)


if __name__ == "__main__":
    raise SystemExit(main())
