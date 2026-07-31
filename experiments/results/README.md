# experiments/results/ — analysis

`analyze.ipynb` — the single analysis artifact. Loads every
`experiments/data/<layout>/*/runs.csv`, joins `hardware.json` on `machine_id`,
and produces:

1. **Performance landscapes** — ns/particle vs N, one curve per cell, per mode,
   per machine. The curve shape names the regime (flat = bandwidth-bound;
   rising = overhead/cache-spill).
2. **Effective bandwidth** — `gbs_eff` (step mode) vs the DRAM ceiling, the
   honest "is this stage bandwidth-bound?" view.
3. **Champion grid** (Table C) — best cell per regime per mode per machine.
   **No global winner**: every champion carries regime + numbers + cell.
4. **Cross-machine comparison** — the same cell overlaid across machines;
   the answer moves with hardware, which is the whole reason `machine_id`
   is a dimension.
5. **Hardware facts** — the cache/memory anchors for every interpretation.

Run it:

```
.venv/bin/jupyter nbconvert --execute --to notebook --inplace experiments/results/analyze.ipynb
# or open in JupyterLab and Run All
```

The notebook is the "we've fully explored this layout" deliverable: once a
layout's champion grid is stable across machines + death rates, the layout is
done and the cross-layout summary (§13.2 of the plan) can cite it.
