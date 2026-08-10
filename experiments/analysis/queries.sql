-- Canonical queries for the analysis bundles.
-- Champions are partitioned by `threads` (decision 8): a parallel algo's
-- T=10 run and a serial algo's T=1 run never share a podium. min ns_particle
-- across trials; one row per (N, death_q, threads).

-- Global top-3 per (N, death_q, threads) on ONE machine:
WITH ranked AS (
  SELECT algo, mem_layout, death_q, threads, N,
    min(ns_particle) AS ns_particle, min(achieved_bw_gbs) AS achieved_bw_gbs,
    row_number() OVER (PARTITION BY N, death_q, threads ORDER BY min(ns_particle)) AS rk
  FROM report
  WHERE machine_id = '<machine_id>'           -- :scope
  GROUP BY algo, mem_layout, death_q, threads, N
)
SELECT N, death_q, threads, rk, algo, mem_layout,
       round(ns_particle, 3) AS ns_particle,
       round(achieved_bw_gbs, 2) AS achieved_bw_gbs
FROM ranked WHERE rk <= 3 ORDER BY threads, N, death_q, rk;

-- Same, scoped to ONE mem_layout (add: AND mem_layout = '<L>').
