-- experiments/report/queries.sql — the canonical queries for the report
-- (champion grid, performance landscape, bandwidth plot, PMC breakdown).
-- The layout READMEs embed the champion-grid query verbatim (§9); this file
-- is the live source the duckdb-wasm page runs.

-- 1. Champion grid: the FASTEST cell per (regime, death_q), min ns/particle.
--    regime: small <=65K, mid 262K-1M, large >=4M.
WITH ranked AS (
  SELECT cell, death_q,
    CASE WHEN N <= 65000 THEN 'small' WHEN N <= 1000000 THEN 'mid' ELSE 'large' END AS regime,
    min(ns_particle) AS ns_particle,
    row_number() OVER (PARTITION BY
      CASE WHEN N <= 65000 THEN 'small' WHEN N <= 1000000 THEN 'mid' ELSE 'large' END,
      death_q
      ORDER BY min(ns_particle)) AS rk
  FROM report
  GROUP BY cell, death_q, regime
)
SELECT regime, death_q, cell, round(ns_particle, 3) AS ns_particle
FROM ranked WHERE rk = 1
ORDER BY regime, death_q;

-- 2. Performance landscape: ns/particle vs N per cell, faceted by death_q.
SELECT cell, death_q, N,
       min(ns_particle) AS ns_particle_min,
       max(ns_particle) AS ns_particle_max
FROM report
GROUP BY cell, death_q, N
ORDER BY cell, death_q, N;

-- 3. Achieved vs ceiling bandwidth per cell (per host).
SELECT cell, N,
       round(min(achieved_bw_gbs), 2) AS achieved_bw_gbs,
       (SELECT streaming_bw_gbs FROM hardware LIMIT 1) AS streaming_bw_gbs
FROM report
GROUP BY cell, N
ORDER BY N, cell;

-- 4. PMC bottleneck breakdown (when pmc.jsonl is present).
SELECT cell, N, death_q, trial, cycles,
       useful_pct, processing_pct, delivery_pct, discarded_pct
FROM pmc
ORDER BY cell, N, death_q;

-- 5. Invariant-suite results (when checks.jsonl is present).
SELECT cell, death_q, checked, count(*) AS n
FROM checks
GROUP BY cell, death_q, checked
ORDER BY cell, death_q;
