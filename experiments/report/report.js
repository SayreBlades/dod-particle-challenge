// report.js — fetch data.parquet, init duckdb-wasm, run the queries.sql sections,
// render tables, wire the SQL console. Data fetched (not bundled); the page is
// fully data-driven. Serve with `python3 -m http.server` from experiments/report/.
import * as duckdb from "https://cdn.jsdelivr.net/npm/@duckdb/duckdb-wasm@1.29.0/dist/duckdb-browser.mjs";

const status = (msg) => { document.getElementById("status").textContent = msg; };

let db, con;

async function init() {
  const dist = "https://cdn.jsdelivr.net/npm/@duckdb/duckdb-wasm@1.29.0/dist/";
  const bundle = await duckdb.selectBundle({
    mvp:   { main: dist + "duckdb-mvp.wasm",   worker: dist + "duckdb-browser-mvp.worker.js" },
    eh:    { main: dist + "duckdb-eh.wasm",    worker: dist + "duckdb-browser-eh.worker.js" },
  });
  const worker = new Worker(bundle.mainWorker, { type: "module" });
  db = new duckdb.AsyncDuckDB(worker, undefined);
  await db.instantiate(bundle.mainModule, bundle.pthreadWorker);
  con = await db.connect();
}

async function loadData() {
  // Fetch the parquet the builder wrote, register it, build the `report` view
  // (achieved_bw_gbs derived here so the page doesn't need the host join).
  const buf = await fetch("data.parquet").then((r) => r.arrayBuffer());
  await db.registerFileBuffer("data.parquet", new Uint8Array(buf));
  await con.run("CREATE TABLE report_raw AS SELECT * FROM read_parquet('data.parquet')");
  await con.run(`
    CREATE TABLE report AS SELECT *,
      bytes_per_particle * N / NULLIF(ns_frame, 0) AS achieved_bw_gbs
    FROM report_raw`);
  // hardware + checks + pmc tables are already inside the parquet? No — the
  // builder JOINs hardware into `report` and writes only that. checks/pmc are
  // separate jsonl; for now they're not in the parquet (TODO: include them).
}

async function runSql(sql) {
  const r = await con.query(sql);
  if (r.numRows === 0) return { schema: [], rows: [] };
  const schema = r.schema.map((c) => c.name);
  const rows = r.toArray().map((o) => Object.fromEntries(Object.entries(o)));
  return { schema, rows };
}

function renderTable(elId, { schema, rows }) {
  if (!schema.length) { document.getElementById(elId).innerHTML = "<em>(no rows)</em>"; return; }
  let html = "<table><thead><tr>" + schema.map((c) => `<th>${c}</th>`).join("") + "</tr></thead><tbody>";
  for (const r of rows) {
    html += "<tr>" + schema.map((c) => `<td>${r[c]}</td>`).join("") + "</tr>";
  }
  document.getElementById(elId).innerHTML = html + "</tbody></table>";
}

async function runSection(elId, sql) {
  try {
    renderTable(elId, await runSql(sql));
  } catch (e) {
    document.getElementById(elId).innerHTML = `<em>(error: ${e.message})</em>`;
  }
}

const Q = {
  champions: `SELECT regime, death_q, cell, round(min(ns_particle),3) AS ns_particle,
              round(min(achieved_bw_gbs),2) AS achieved_bw_gbs
              FROM (SELECT *, CASE WHEN N<=65000 THEN 'small' WHEN N<=1000000 THEN 'mid' ELSE 'large' END AS regime FROM report)
              GROUP BY regime, death_q, cell ORDER BY regime, death_q, ns_particle`,
  landscape: `SELECT cell, death_q, N, round(min(ns_particle),3) AS ns_min
              FROM report GROUP BY cell, death_q, N ORDER BY cell, death_q, N`,
  bandwidth: `SELECT cell, N, round(min(achieved_bw_gbs),2) AS achieved_bw_gbs
              FROM report GROUP BY cell, N ORDER BY N, cell`,
  checks:    `SELECT 'open experiments/data/<host>/checks.jsonl' AS note`,
  pmc:       `SELECT 'open experiments/data/<host>/pmc.jsonl' AS note`,
};

(async () => {
  try {
    status("initializing duckdb-wasm…");
    await init();
    status("fetching data.parquet…");
    await loadData();
    status("rendering…");
    await runSection("champions-table", Q.champions);
    await runSection("landscape-table", Q.landscape);
    await runSection("bandwidth-table", Q.bandwidth);
    await runSection("checks-table", Q.checks);
    await runSection("pmc-table", Q.pmc);
    const n = await runSql("SELECT count(*) AS n FROM report");
    status(`loaded ${n.rows[0].n} run rows.`);
  } catch (e) {
    status(`error: ${e.message}`);
    console.error(e);
  }

  document.getElementById("sql-run").onclick = async () => {
    const sql = document.getElementById("sql-input").value;
    const s = document.getElementById("sql-status");
    s.textContent = "running…";
    try { renderTable("sql-result", await runSql(sql)); s.textContent = "ok"; }
    catch (e) { document.getElementById("sql-result").innerHTML = `<em>${e.message}</em>`; s.textContent = `error: ${e.message}`; }
  };
})();
