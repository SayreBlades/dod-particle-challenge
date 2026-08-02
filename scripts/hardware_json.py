#!/usr/bin/env python3
"""Emit a JSON hardware profile to stdout (machine_id + cache/memory/cpu facts).

Cross-platform: `sysctl` on Darwin, `/proc/cpuinfo` + `/proc/meminfo` on Linux.
`machine_id` is a stable short hash of the near-immutable facts (cpu + cores +
memsize + os + arch), prefixed with the hostname — so the same machine reports
the same id across runs, and two different machines almost never collide.

Used by `scripts/collect.sh` (writes hardware.json in the host data dir) and by
the report (joined as a dimension via machine_id). `streaming_bw_gbs` is
measured by shelling out to the Zig `--bandwidth` microbench (real hardware
bandwidth, not a Python interpreter loop).
"""
import hashlib, json, os, platform, subprocess, sys


def sh(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ""


def sysctl(name):
    return sh(["sysctl", "-n", name])


def _linux_cpu():
    try:
        for line in open("/proc/cpuinfo"):
            if line.startswith("model name"):
                return line.split(":", 1)[1].strip()
    except Exception:
        pass
    return platform.processor() or "unknown"


def _linux_meminfo_bytes():
    try:
        for line in open("/proc/meminfo"):
            if line.startswith("MemTotal:"):
                return int(line.split()[1]) * 1024
    except Exception:
        pass
    return 0


def detect():
    f = {}
    f["hostname"] = platform.node().split(".")[0]
    f["os"] = f"{platform.system()} {platform.release()}"
    f["arch"] = platform.machine()
    if platform.system() == "Darwin":
        f["cpu"] = sysctl("machdep.cpu.brand_string") or "unknown"
        f["physicalcpu"] = int(sysctl("hw.physicalcpu") or 0)
        f["logicalcpu"] = int(sysctl("hw.logicalcpu") or 0)
        f["cachelinesize"] = int(sysctl("hw.cachelinesize") or 0)
        f["l1dcachesize"] = int(sysctl("hw.l1dcachesize") or 0)
        f["l1icachesize"] = int(sysctl("hw.l1icachesize") or 0)
        f["l2cachesize"] = int(sysctl("hw.l2cachesize") or 0)
        f["l3cachesize"] = int(sysctl("hw.l3cachesize") or 0)
        f["pagesize"] = int(sysctl("hw.pagesize") or 0)
        f["memsize_bytes"] = int(sysctl("hw.memsize") or 0)
    else:
        cores = 0
        try:
            cores = int(sh(["nproc"]))
        except Exception:
            pass
        f["cpu"] = _linux_cpu()
        f["physicalcpu"] = cores
        f["logicalcpu"] = cores
        f["cachelinesize"] = 0
        f["l1dcachesize"] = 0
        f["l1icachesize"] = 0
        f["l2cachesize"] = 0
        f["l3cachesize"] = 0
        f["pagesize"] = 4096
        f["memsize_bytes"] = _linux_meminfo_bytes()
    # machine_id: hostname + short hash of the identifying facts.
    ident = "|".join(str(x) for x in (
        f["cpu"], f["physicalcpu"], f["logicalcpu"],
        f["memsize_bytes"], f["os"], f["arch"],
    ))
    h = hashlib.sha1(ident.encode()).hexdigest()[:8]
    f["machine_id"] = f"{f['hostname']}-{h}"
    f["streaming_bw_gbs"] = _streaming_bw_gbs(f)
    return f


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _streaming_bw_gbs(facts):
    """Measure single-core streaming bandwidth via the Zig --bandwidth microbench
    (refactor §6.4). The bench binary runs a tight streaming-write loop over a
    buffer > LLC, single-threaded, timed — real hardware bandwidth, not a Python
    interpreter loop (which capped at ~5.56 GB/s on an M4 that streams ~24+).
    Prints `streaming_bw_gbs=<value>` to stdout.

    Falls back to a Python estimate (clearly warned) if the Zig toolchain or
    build fails, so analysis-only hosts still produce a number."""
    import subprocess
    bin_path = os.path.join(ROOT, "out", "bin", "dod-particles")
    # Build the bandwidth binary if missing (a default reference cell; the
    # --bandwidth flag is cell-agnostic — it never touches the sim). Use the
    # reference strat so no Halide/python env is needed.
    if not os.path.exists(bin_path):
        try:
            subprocess.run(
                ["zig", "build", "-p", "out", "-Dlayout=L1",
                 "-Dstrat=B1.w1-autovec.w2-simple", "-Dmode=bench",
                 "-Doptimize=ReleaseFast"],
                cwd=ROOT, capture_output=True, timeout=120, check=True,
            )
        except (subprocess.SubprocessError, FileNotFoundError) as e:
            sys.stderr.write(
                f"warning: could not build the Zig bandwidth binary ({e}); "
                "falling back to the Python estimate (CEILING IS UNRELIABLE)\n")
            return _streaming_bw_gbs_python(facts)
    try:
        out = subprocess.run(
            [bin_path, "--bandwidth"], cwd=ROOT,
            capture_output=True, text=True, timeout=10,
        ).stderr
        for line in out.splitlines():
            if line.startswith("streaming_bw_gbs="):
                return float(line.split("=", 1)[1])
    except (subprocess.SubprocessError, ValueError) as e:
        sys.stderr.write(f"warning: bandwidth microbench failed ({e}); ")
    sys.stderr.write("falling back to the Python estimate (CEILING IS UNRELIABLE)\n")
    return _streaming_bw_gbs_python(facts)


def _streaming_bw_gbs_python(facts):
    """Fallback estimate: a Python bytearray memset loop. Interpreter-bound —
    under-reports real bandwidth by ~4-5x — but produces a number when the
    Zig toolchain is unavailable. The result is warned when used."""
    import time
    l3 = facts.get("l3cachesize", 0)
    buf_bytes = max(l3 * 4, 256 * 1024 * 1024) if l3 else 256 * 1024 * 1024
    try:
        buf = bytearray(buf_bytes)
        for i in range(0, buf_bytes, 4096):
            buf[i] = 1
        t0 = time.perf_counter()
        for _ in range(3):
            for i in range(0, buf_bytes, 64):
                buf[i] = 0
        t1 = time.perf_counter()
        elapsed = t1 - t0
        if elapsed <= 0:
            return 0.0
        return round(buf_bytes * 3 / elapsed / 1e9, 2)
    except Exception:
        return 0.0


if __name__ == "__main__":
    json.dump(detect(), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
