# Issue #846: approximate indexes used for `ORDER BY` without `LIMIT`

- **Issue:** https://github.com/pgvector/pgvector/issues/846 (open upstream; no linked PR, and `hnswcostestimate` is unchanged at upstream HEAD, as of 2026-09-19)
- **Branch:** `feature/846`, based on `efa08fd`, the current upstream `master` HEAD
- **Date:** 2026-09-19

## Summary

- The planner can pick an HNSW or IVFFlat index for an `ORDER BY <distance>` query with no `LIMIT`. Those scans stop early: after `hnsw.ef_search` tuples for HNSW, or after the probed lists for IVFFlat. The query then silently returns a truncated result.
- The bug is present in this clone. The issue's exact case reproduces here, returning 160 of 4,997,869 rows.
- It reaches further than the issue suggests. The maintainer called the reporter's setup (5-dim vectors, `m = 8`, partitioning) uncommon. But with `random_page_cost` at 1.5 or lower, which is common for SSDs, it also hits a 10,000-row table of 3-dim vectors with default HNSW settings. It hits IVFFlat too, and 128- and 384-dim embeddings at 50,000 rows.
- The fix on this branch is a small change to `hnswcostestimate` and `ivfflatcostestimate`. When the query needs every row (`root->tuple_fraction <= 0`), the index is disabled, unless `enable_seqscan = off`, the documented way to force an index. Queries with a `LIMIT` get identical plans and costs.
- **Validation:**
  - SQL regression suite: 15/15, including the new `no_limit` test.
  - Full TAP suite: 50 files, including two new ones holding 171 checks.
  - The new tests fail on `master` (11 SQL checks, and 117 of the 171 TAP checks) and pass on this branch.

## The issue

The reporter was on pgvector 0.8.0. They ran `ORDER BY embedding <-> '...'` without a `LIMIT` on a 5M-row table: 4 hash partitions, `vector(5)`, HNSW with `m = 8` and `ef_construction = 16`. They asked two questions:

1. Why does the query use index scans without a `LIMIT`?
2. Why does removing `embedding` from the select list switch it to a sequential scan?

The maintainer traced it to the estimated cost of an external merge sort at the default `work_mem` being very high. They saw raising the HNSW scan's total cost as the only fix, but wanted a framework for testing cost estimation first. A contributor offered to build that benchmark in February 2026.

## Reproduction on this clone

**Environment:**
- PostgreSQL 20devel, built from source.
- pgvector at `efa08fd`.
- A throwaway cluster with default planner settings unless noted: `random_page_cost = 4`, `work_mem = 4MB`, `effective_cache_size = 4GB`.

### The issue's case

The table has 5M rows in 4 hash partitions, `vector(5)`, `m = 8`, `ef_construction = 16`. Each partition has a 72 MB heap and a 270 MB HNSW index.

| Query | `master` | `feature/846` |
|---|---|---|
| `SELECT id, embedding ... ORDER BY embedding <-> q` | Merge Append of 4 HNSW index scans, cost `262.29..875065.46` (the issue shows `262.30..875089.46`), **160 of 4,997,869 rows** | Seq Scan + Sort, cost `953621.64..966116.32`, **4,997,869 rows** in 2.8 s |
| `SELECT id ... ORDER BY embedding <-> q` | Seq Scan + Sort, cost `851127.64..863622.32` | unchanged |
| `SELECT id, embedding ... ORDER BY embedding <-> q LIMIT 10` | Merge Append of index scans, cost `262.29..264.04`, 10 rows | unchanged: same plan and costs |

The answer to the reporter's second question is the sort width.
- **With `embedding` in the select list** (width 37): Seq Scan + Sort costs 966,116, more than the index's 875,065, so the index wins.
- **With only `id`** (width 12): the sort costs 863,622, less than the index, so the sequential scan wins.

### How far it reaches

These are planner costs on the issue's table on `master`. "Seq Scan + Sort" is the cheapest plan with index scans disabled. Values are listed as `SELECT id, embedding` / `SELECT id`.

| `random_page_cost` | `work_mem` | Index total | Seq Scan + Sort total | Index chosen without `LIMIT`? |
|---|---|---|---|---|
| 4 | 4MB | 875,065 | 966,116 / 863,622 | yes / no |
| 4 | 64MB | 875,065 | 829,455 / 778,208 | no / no |
| 4 | 1GB | 875,065 | 692,794 / 692,794 | no / no |
| 2 | 4MB | 524,995 | 888,024 / 814,814 | yes / yes |
| 2 | 64MB | 524,995 | 790,409 / 753,804 | yes / yes |
| 2 | 1GB | 524,995 | 692,794 / 692,794 | yes / yes |
| 1.1 | 4MB | 367,464 | 852,883 / 792,851 | yes / yes |
| 1.1 | 64MB | 367,464 | 772,839 / 742,823 | yes / yes |
| 1.1 | 1GB | 367,464 | 692,794 / 692,794 | yes / yes |

Smaller and more typical tables on `master`, with no `LIMIT`:

| Table | Setting | Plan | Rows returned |
|---|---|---|---|
| 10,000 rows, `vector(3)`, default HNSW | `random_page_cost` 4 or 2 | Seq Scan + Sort | 10,000 |
| same | `random_page_cost` 1.5, 1.1 or 1 | HNSW Index Scan | **40** |
| same, IVFFlat with `lists = 100` | `random_page_cost = 1.1` | IVFFlat Index Scan | **87** |
| 50,000 rows, `vector(128)`, `SELECT *` | `random_page_cost = 1.1` | HNSW Index Scan | **40** |
| 50,000 rows, `vector(384)`, `SELECT *` | `random_page_cost = 1.1` | HNSW Index Scan | **40** |
| 50,000 rows, `vector(768)` | `random_page_cost` 4 or 1.1 | Seq Scan + Sort | 50,000 |

Per-row planner costs at 50,000 rows with `random_page_cost = 1.1`, index total vs Seq Scan + Sort total, each divided by the row count:

| Dimensions | `SELECT *` | `SELECT id` |
|---|---|---|
| 128 | 0.210 vs 0.301 (index wins) | 0.210 vs 0.164 (Seq Scan + Sort wins) |
| 384 | 0.515 vs 0.537 (index wins) | 0.515 vs 0.293 (Seq Scan + Sort wins) |
| 768 | 0.577 vs 0.099 (Seq Scan + Sort wins) | 0.577 vs 0.099 (Seq Scan + Sort wins) |

At 768 dimensions the vectors are stored in TOAST. The sequential scan's cost estimate doesn't include TOAST reads, so Seq Scan + Sort looks cheap.

The same truncation happens with `OFFSET` but no `LIMIT`, and with window functions such as `row_number() OVER (ORDER BY embedding <-> q)`.

## Root cause

- **The scans stop early.**
  - In `hnswgettuple` (`src/hnswscan.c`), a scan with iterative scans off returns the `ef_search` candidates and ends.
  - With iterative scans on, it ends at `hnsw.max_scan_tuples` or at the memory limit.
  - IVFFlat returns only the tuples in the probed lists: `ivfflat.probes`, or up to `ivfflat.max_probes`.
- **The cost model assumes they don't.** `hnswcostestimate` (`src/hnsw.c`) and `ivfflatcostestimate` (`src/ivfflat.c`) start from `genericcostestimate`. With no index quals, it prices a walk over every index page and every row, plus the heap fetches. That total grows linearly with the row count.
- **Seq Scan + Sort grows faster.** Its cost includes about 2 × `cpu_operator_cost` × N log₂ N for comparisons, plus external-merge I/O once the sort exceeds `work_mem`. These all push the index's total below the sort's:
  - small vectors, which mean a small index and heap per row
  - a lower `m`
  - larger tables
  - a small `work_mem`
  - a low `random_page_cost`
- **With no `LIMIT`, only total cost matters.** The planner picks the cheaper full-result plan, the index. The executor then returns only what the scan produces.

The existing TAP tests already state the intended rule. "Test distance filtering without limit" in `017_hnsw_filtering.pl` and `009_ivfflat_filtering.pl` expects a Seq Scan. Nothing enforced that rule, though; it held only because of the relative costs at those tables' size.

## The change

This is the change in both cost estimate functions:

```diff
+#include "optimizer/cost.h"
 ...
-	/* Never use index without order */
-	if (path->indexorderbys == NIL)
+	/*
+	 * Never use index without order, or when all tuples are needed and seq
+	 * scans are enabled, since scans return a limited number of tuples
+	 */
+	if (path->indexorderbys == NIL ||
+		(root->tuple_fraction <= 0 && enable_seqscan))
```

**Why `root->tuple_fraction`:**
- The planner sets it from the query's `LIMIT` in `preprocess_limit`. A value of 0 means every row is needed.
- Postgres core uses the same signal to decide whether startup cost matters: `rel->consider_startup = (root->tuple_fraction > 0)` in `relnode.c`.
- It stays positive for:
  - an outer `LIMIT` over a subquery
  - `LIMIT $1` in a generic plan (0.10)
  - cursors (`cursor_tuple_fraction`)
  - `EXISTS`

**Why the `enable_seqscan` exception:**
- The README's "Why isn't a query using an index?" says an index needs `ORDER BY` and `LIMIT`. It documents `SET LOCAL enable_seqscan = off` as the way to force one.
- The SQL regression tests and the TAP duplicate tests rely on that override to exercise the index without a `LIMIT`.
- A first version without the exception failed 7 of the 14 SQL regression suites.

**How it disables the index:** it reuses the existing "no ORDER BY" branch. That sets an infinite cost, plus `disabled_nodes = 2` on Postgres 18+. So even a Sort disabled by `enable_sort = off` still wins over the index.

**Portability:** `enable_seqscan` is declared `PGDLLIMPORT` from Postgres 13 on, so Windows builds link. `root->tuple_fraction` exists in every supported version.

Behavior by query form, on a 10,000-row `vector(3)` table with both HNSW and IVFFlat. Appendix B lists the tests.

| Query form | `master` | `feature/846` |
|---|---|---|
| `ORDER BY dist`, no `LIMIT`, `random_page_cost = 1.1` | index: 40 rows (HNSW) / 87 (IVFFlat) | Seq Scan + Sort: 10,000 rows |
| `ORDER BY dist`, no `LIMIT`, `enable_sort = off` | index | Seq Scan + Sort |
| `ORDER BY dist OFFSET 5`, no `LIMIT` | index | Seq Scan + Sort |
| `row_number() OVER (ORDER BY dist)`, no `LIMIT` | max row number 40 / 87 | 10,000 |
| `ORDER BY dist LIMIT 10` | index | index |
| `SELECT * FROM (... ORDER BY dist) t LIMIT 10` | index | index |
| `LIMIT $1`, generic plan | index | index |
| `DECLARE ... CURSOR FOR ... ORDER BY dist` | index | index |
| no `LIMIT`, `enable_seqscan = off` | index | index |

**Tests:** see [Appendix B](#appendix-b-the-added-tests). `017_hnsw_filtering.pl` and `009_ivfflat_filtering.pl` each gain a "Test without limit" check, and `no_limit.sql`, `049_hnsw_no_limit.pl` and `050_ivfflat_no_limit.pl` cover the operator classes and the main query forms. All of them fail on `master` and pass on this branch.

**CHANGELOG:** an entry under 0.8.7 (unreleased).

## Validation

| Check | `master` | `feature/846` |
|---|---|---|
| Issue case (5M rows) | 160 of 4,997,869 rows | all 4,997,869 rows; `LIMIT 10` plan and costs identical |
| `no_limit.sql` (11 checks) | 11 fail | pass |
| `049_hnsw_no_limit.pl` (94 checks) | 65 fail | pass |
| `050_ivfflat_no_limit.pl` (77 checks) | 52 fail | pass |
| New assertions in TAP tests 009 and 017 | fail (test 11 in each) | pass |
| SQL regression suite (`make installcheck`) | 14/14 pass | 15/15 pass, with `no_limit` added |
| Full TAP suite | not run | 50 files, 1,427 tests, pass |
| Compiler warnings | — | none |

The full TAP run had one failure: `025_hnsw_halfvec_insert_recall.pl` reported recall of 0.9775 against its 0.98 threshold. That test queries with a `LIMIT` and `enable_seqscan = off`, which this change does not affect, and it passes on a re-run and on `master`.

## Alternatives considered

**Raising the HNSW total cost, as the maintainer suggested:**
- The increase needed depends on the setup:
  - about 1.10× for the issue's case at defaults (966,116 / 875,065)
  - 1.26× for the 10,000-row table at `random_page_cost = 1.1` (878.39 / 698.30)
  - 2.32× for the issue's table at `random_page_cost = 1.1` (852,883 / 367,464)
- It also grows with table size, because the sort's per-row cost rises with log N while the index's stays roughly flat.
- A higher total cost also changes how the planner costs `LIMIT` queries with filters, which the 0.8.0 cost tuning balanced (tests 017 and 039).
- So it can't guarantee that queries without a `LIMIT` avoid the index. The gate does, and the cost model can still be improved separately.

**A strict gate with no `enable_seqscan` exception.** Rejected: it breaks 7 of the 14 SQL regression suites and removes the documented override.

**Disabling the index whenever the query needs more rows than `ef_search`,** for example `LIMIT 100` with the default of 40. Rejected: the README documents that behavior (fewer results; use iterative scans). Switching those queries to exact scans could also be a large performance regression.

## Behavior changes and limitations

- **Slower but complete:** queries without a `LIMIT` that happened to use an index now run a sequential scan and sort. To keep the index, add a `LIMIT`, use a cursor, or `SET LOCAL enable_seqscan = off`.
- **Cursors are unchanged:** they still use the index and can still return a truncated result. That's by design, because a cursor asks for a fast start.
- **Large `LIMIT`s are unchanged:** a `LIMIT` larger than `hnsw.ef_search` still returns fewer rows, as the README documents.
- **Global setting:** the check reads the global `enable_seqscan` setting, so per-table plan advice on Postgres 19+ (`pgs_mask`) isn't considered.
- **Exact IVFFlat scans are disabled too:** IVFFlat with `probes >= lists` returns every row, but it is still disabled without a `LIMIT`. That is conservative but harmless, since Seq Scan + Sort is no worse there.

## Follow-ups

- Share these findings on #846 or open an upstream PR; the behavior change is the maintainer's call.
- The maintainer's cost-testing framework is still worth building for the `LIMIT` + filter trade-offs. It is independent of this fix.
- Consider noting in the README that cursors can still return a truncated result.

## Appendix A: reproduction SQL

The issue's case. The HNSW build took about 3 minutes with `maintenance_work_mem = 700MB` and `max_parallel_maintenance_workers = 4`; those settings affect build time only, not the plan. It needs about 1.5 GB of disk.

```sql
CREATE EXTENSION IF NOT EXISTS vector;
CREATE TABLE vector_collection2 (id integer PRIMARY KEY, embedding vector(5)) PARTITION BY HASH (id);
ALTER TABLE vector_collection2 ALTER COLUMN embedding SET STORAGE EXTERNAL;
CREATE TABLE vector_collection2_p0 PARTITION OF vector_collection2 FOR VALUES WITH (modulus 4, remainder 0);
CREATE TABLE vector_collection2_p1 PARTITION OF vector_collection2 FOR VALUES WITH (modulus 4, remainder 1);
CREATE TABLE vector_collection2_p2 PARTITION OF vector_collection2 FOR VALUES WITH (modulus 4, remainder 2);
CREATE TABLE vector_collection2_p3 PARTITION OF vector_collection2 FOR VALUES WITH (modulus 4, remainder 3);
INSERT INTO vector_collection2 SELECT i, ARRAY[random(), random(), random(), random(), random()]::vector(5) FROM generate_series(1, 4997869) i;
CREATE INDEX vector_collection2_embedding_idx ON vector_collection2 USING hnsw (embedding vector_l2_ops) WITH (m = 8, ef_construction = 16);
VACUUM ANALYZE vector_collection2;

-- 160 rows on master, 4,997,869 on feature/846
EXPLAIN (ANALYZE) SELECT id, embedding FROM vector_collection2
ORDER BY embedding <-> '[0.08761761,0.16212644,0.061548516,0.099646576,0.36062342]';
```

A small case, runnable in seconds:

```sql
CREATE TABLE tst (i int4, v vector(3));
INSERT INTO tst SELECT i, ARRAY[random(), random(), random()] FROM generate_series(1, 10000) i;
CREATE INDEX idx ON tst USING hnsw (v vector_l2_ops);
ANALYZE tst;

SET random_page_cost = 1.1;
-- 40 on master, 10000 on feature/846
SELECT count(*) FROM (SELECT i FROM tst ORDER BY v <-> '[0.5,0.5,0.5]') s;
```

## Appendix B: the added tests

Each of these fails on `master` and passes on `feature/846`.

**`test/sql/no_limit.sql`** (11 checks, runs in `make installcheck`)

Fixed data, so the expected output is exact. For each index type it runs an `ORDER BY` without a `LIMIT` over 500 rows and checks both the row count and the exact order, covering the four `vector` operators plus `halfvec`, `sparsevec` and `bit`. `enable_sort = off` makes the index path cheaper than any sort. On `master` these checks return as few as 1 row out of 500.

**`test/t/049_hnsw_no_limit.pl`** (94 checks) and **`test/t/050_ivfflat_no_limit.pl`** (77 checks)

Random data, 10,000 rows. On `master`, 65 and 52 checks fail.

- *Operator classes,* under `enable_sort = off`: the four `vector` classes plus `halfvec`, `sparsevec` and both `bit` classes for HNSW, and five classes for IVFFlat.
- *Query forms without a `LIMIT`,* under `random_page_cost = 1.1`: plain, `OFFSET`, an attribute filter, a join, a materialized CTE, a partitioned table, iterative scans, more probes, a generic plan, a window function, an aggregate subquery, a PL/pgSQL function, `CREATE TABLE AS` and a partial index.
- *Each of those asserts three things:* the plan has no index scan, the row count matches an exact scan (`enable_indexscan = off`), and the distances and ids match that scan. Comparing distances rather than ids keeps ties from making the tests flaky.
- *Forms that must still use the index:* `LIMIT`, `FETCH FIRST`, an outer `LIMIT`, an inlined CTE, `LIMIT $1` with a generic plan, `LATERAL`, partitioned tables, iterative scans, cursors, and `enable_seqscan = off` with and without partitioning. These checks pass on `master` too, which is what shows the change doesn't reach further than it should.

## Appendix C: how the patched build was tested

- **Cluster:** a throwaway cluster created with `initdb`. The local server was not touched.
- **Loading the patched library:** each session loaded it with `PGOPTIONS="-c dynamic_library_path=<dir with patched vector.so>:\$libdir"`.
  - Postgres 18+ strips `$libdir/` from `module_pathname`, so the search path applies.
  - The path actually loaded was confirmed from `/proc/<backend pid>/maps`.
- **SQL tests:** `PGHOST=... PGPORT=... PGOPTIONS=... make installcheck`.
- **TAP tests:** this Postgres was built without TAP support. `prove` ran with `PERL5LIB=<IPC-Run>/lib:<postgres source>/src/test/perl`. For the patched runs, `TEMP_CONFIG` pointed to a file containing the `dynamic_library_path` line.
