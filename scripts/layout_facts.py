#!/usr/bin/env python3
"""layout_facts.py — static per-memory-layout facts for evidence + the SPA.

The layout's identity-level data model, expressed as the numbers the
performance narrative needs: field sizes (exact — @sizeOf per field), the
stage→fields map (which fields each logical stage touches for a *living*
particle), and the loop structure of each algorithm family. From these,
per-loop HOT BYTES fall out: the bytes/particle a loop actually touches vs
the full struct stride it drags through the cache-line filler — the
"useful vs dead bandwidth" story.

Zig plain structs give no field-order guarantee (the compiler reorders), so
facts are by NAME + SIZE only; offsets are deliberately not claimed. Field
sizes sum to 66 of the 68 B stride (2 B alignment padding).

Consumed by analyze_algo.py (prompt + attested numbers) and build_report.py
(ships into <L>.mem_layout.json for the SPA layout strip).
"""
from __future__ import annotations

# stage -> fields touched for a living particle (respawn additionally rewrites
# the whole particle, but only for the dead q-fraction — noted, not counted)
STAGE_FIELDS = {
    "integrate": ["pos", "vel"],
    "decide": ["age"],
    "respawn": ["seed"],
    "render": ["pos", "color"],
}

# Algorithm family -> per-loop stage sets (the AF table from the README;
# kept in sync with report.js ALGO_FAMS and the layout READMEs).
AF_LOOPS = {
    "AF01": [["integrate", "decide", "respawn", "render"]],
    "AF02": [["integrate", "decide", "respawn"], ["render"]],
    "AF03": [["integrate", "decide"], ["respawn", "render"]],
    "AF04": [["integrate"], ["decide", "respawn", "render"]],
    "AF05": [["integrate"], ["decide", "respawn"], ["render"]],
    "AF06": [["integrate", "decide"], ["respawn"], ["render"]],
    "AF07": [["integrate"], ["decide"], ["respawn", "render"]],
    "AF08": [["integrate"], ["decide"], ["respawn"], ["render"]],
}

# Intermediate storage cost per particle, by the `intermediates` decl value.
INTERMEDIATE_BPP = {"none": 0, "mask": 1, "list": 4, "partition": 0}

LAYOUTS: dict[str, dict] = {
    "ML01": {
        "struct": "Particle (AoS, full 11-field)",
        "stride_bytes": 68,
        "fields": [
            {"name": "pos", "bytes": 12, "type": "Vec3"},
            {"name": "vel", "bytes": 12, "type": "Vec3"},
            {"name": "life", "bytes": 4, "type": "f32"},
            {"name": "age", "bytes": 4, "type": "f32"},
            {"name": "color", "bytes": 16, "type": "Vec4"},
            {"name": "size", "bytes": 4, "type": "f32"},
            {"name": "rotation", "bytes": 4, "type": "f32"},
            {"name": "mass", "bytes": 4, "type": "f32"},
            {"name": "flags", "bytes": 1, "type": "u8"},
            {"name": "kind", "bytes": 1, "type": "enum"},
            {"name": "seed", "bytes": 4, "type": "u32"},
        ],
    },
}


def loop_hot_bytes(mem_layout: str, algo_fam: str) -> list[dict] | None:
    """Per-loop {stages, hot_bytes, hot_frac} for one algorithm family."""
    lay = LAYOUTS.get(mem_layout)
    loops = AF_LOOPS.get(algo_fam)
    if not lay or not loops:
        return None
    sizes = {f["name"]: f["bytes"] for f in lay["fields"]}
    out = []
    for stages in loops:
        fields = sorted({f for s in stages for f in STAGE_FIELDS[s]})
        hot = sum(sizes[f] for f in fields)
        out.append({
            "stages": stages,
            "fields": fields,
            "hot_bytes": hot,
            "stride_bytes": lay["stride_bytes"],
            "hot_frac": round(hot / lay["stride_bytes"], 3),
        })
    return out
