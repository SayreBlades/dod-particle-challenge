# experiments/report/ — the static report site

A single self-contained HTML page that loads **duckdb-wasm** from a CDN,
fetches `data.parquet` (built by `scripts/build_report.py`), and runs all
queries client-side. Fully data-driven: swap the parquet, the page updates.

## Build + serve

```sh
scripts/build_report.py                  # reads experiments/data/**/*.jsonl
                                         #   -> experiments/report/data.parquet
                                         #   + refreshes layout README grids (§9)
python3 -m http.server -d experiments/report 8000   # fetch needs http, not file://
# open http://localhost:8000
```

## Files

- `index.html` — the page (champion grid, landscape, bandwidth, checks, PMC,
  and an interactive SQL console against the loaded `report` table).
- `report.js` — duckdb-wasm init, fetch, query, render.
- `queries.sql` — the canonical SQL (the layout READMEs embed the
  champion-grid query verbatim from here, §9).
- `style.css` — minimal.
- `data.parquet` — **gitignored** (derived; rebuilt by `build_report.py`).

## Notes

- duckdb-wasm is loaded from a CDN (needs internet to view the report). To
  view offline, vendor the `.wasm` locally (not done yet).
- `data.parquet` is the `report` view (runs + hardware join +
  `achieved_bw_gbs` derived). `checks`/`pmc` are separate JSONL not yet
  bundled into the parquet — the report shows a pointer for now.
