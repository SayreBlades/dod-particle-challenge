# experiments/report/ — the static report dashboard

A single self-contained HTML page that loads **ECharts** from a CDN, fetches
`report.json` (built by `scripts/build_report.py`), and renders a charted
dashboard. Pure-charts: no duckdb-wasm, no SQL console. All aggregation happens
server-side in duckdb; the page just renders the JSON.

## Build + serve

```sh
scripts/build_report.py                  # reads experiments/data/**/*.jsonl
                                         #   -> experiments/report/report.json
                                         #   + refreshes layout README grids (§9)
python3 -m http.server -d experiments/report 8000   # fetch needs http, not file://
# open http://localhost:8000
```

## What it shows

- **Champion grid** — heatmap per layout: fastest cell per (regime × death_q),
  colored by ns/particle (greener = faster).
- **Performance landscape** — ns/particle vs N, faceted by death rate (one
  small multiple per death rate; a line per cell). Click a legend cell to
  isolate it.
- **Achieved vs ceiling bandwidth** — achieved GB/s (`bytes/p × N / ns_frame`)
  per cell vs N, with the host's measured `streaming_bw_gbs` as a dashed
  ceiling line. Cells near the ceiling at large N are bandwidth-bound.
- **PMC bottleneck breakdown** — stacked cycle fractions per champion (useful
  / processing / delivery / discarded). Shown only when `pmc.jsonl` is present.
- **Invariant suite** — PASS/FAIL chips per cell from `--check`.

## Files

- `index.html` — the page (sections for each chart + meta header).
- `report.js` — fetch `report.json`, render the ECharts dashboard.
- `style.css` — dark dashboard theme.
- `report.json` — **gitignored** (derived; rebuilt by `build_report.py`).
- `queries.sql` — the canonical SQL (the layout READMEs embed the
  champion-grid query verbatim from here, §9). Documentary; not fetched by
  the page (aggregation is server-side now).

## Notes

- ECharts is loaded from a CDN (needs internet to view the report). To view
  offline, vendor `echarts.min.js` locally (not done yet).
- `report.json` is the full `report` view (runs + hardware join +
  `achieved_bw_gbs` derived + champion/landscape/bandwidth/pmc/checks
  aggregations). Re-run `build_report.py` after every `collect.sh`.
