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
    return f


if __name__ == "__main__":
    json.dump(detect(), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
