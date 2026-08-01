#!/usr/bin/env python3
"""Emit a JSON hardware profile to stdout (machine_id + cache/memory/cpu facts).

Cross-platform: `sysctl` on Darwin, `/proc/cpuinfo` + `/proc/meminfo` on Linux.
`machine_id` is a stable short hash of the near-immutable facts (cpu + cores +
memsize + os + arch), prefixed with the hostname — so the same machine reports
the same id across runs, and two different machines almost never collide.

Used by `scripts/collect.sh` (writes hardware.json beside runs.csv) and by the
analysis notebook (joined as a dimension via machine_id).
"""
import hashlib, json, platform, subprocess, sys


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


def _streaming_bw_gbs(facts):
    """Measure single-core streaming bandwidth: a memset-style loop over a
    buffer larger than LLC, single-threaded, timed. Returns GB/s (1e9 B/s).
    This is the bandwidth-attribution home after gbs_eff retired (§17.7): the
    notebook plots achieved_bw = bytes/p*N/frame_time vs this ceiling."""
    import time
    # Buffer ~4x the L3 (or 256MB if L3 unknown) — bigger than LLC so we measure
    # DRAM streaming, not cache.
    l3 = facts.get("l3cachesize", 0)
    buf_bytes = max(l3 * 4, 256 * 1024 * 1024) if l3 else 256 * 1024 * 1024
    try:
        buf = bytearray(buf_bytes)
        # Warmup
        for i in range(0, buf_bytes, 4096):
            buf[i] = 1
        t0 = time.perf_counter()
        # Write pass: touch every byte (memset pattern).
        for _ in range(3):
            for i in range(0, buf_bytes, 64):  # cache-line stride
                buf[i] = 0
        t1 = time.perf_counter()
        elapsed = t1 - t0
        if elapsed <= 0:
            return 0.0
        total_bytes = buf_bytes * 3
        return round(total_bytes / elapsed / 1e9, 2)
    except Exception:
        return 0.0


if __name__ == "__main__":
    json.dump(detect(), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
