-- Benchmark for the json and jsonb casts
--
-- Each conversion is timed several times and the fastest run reported.
--
-- digits rounds the values to that many decimal places. Use 0 for the full
-- precision of a float, which doubles the size of the json.
--
-- Usage:
--   psql -f bench/json_casts.sql
--   psql -v rows=20000 -v dim=128 -v runs=5 -v digits=0 -f bench/json_casts.sql

\set ON_ERROR_STOP on

\if :{?rows}
\else
\set rows 3000
\endif

\if :{?dim}
\else
\set dim 1536
\endif

\if :{?runs}
\else
\set runs 5
\endif

\if :{?digits}
\else
\set digits 6
\endif

CREATE EXTENSION IF NOT EXISTS vector;

DROP TABLE IF EXISTS bench_casts;
DROP TABLE IF EXISTS bench_casts_sink;

CREATE TABLE bench_casts AS
SELECT i, (SELECT jsonb_agg(CASE WHEN :digits > 0 THEN round(random()::numeric, :digits) ELSE random()::numeric END) FROM generate_series(1, :dim) WHERE i > 0) AS b
FROM generate_series(1, :rows) i;

ALTER TABLE bench_casts ADD COLUMN v vector(:dim);
UPDATE bench_casts SET v = b::text::vector(:dim);
VACUUM ANALYZE bench_casts;

CREATE TABLE bench_casts_sink (embedding vector(:dim));

CREATE OR REPLACE FUNCTION bench_casts_best(query text, runs int) RETURNS numeric AS $$
DECLARE
	start timestamptz;
	elapsed double precision;
	best double precision := NULL;
BEGIN
	FOR i IN 1..runs LOOP
		start := clock_timestamp();
		EXECUTE query;
		elapsed := extract(epoch FROM clock_timestamp() - start) * 1000;

		IF best IS NULL OR elapsed < best THEN
			best := elapsed;
		END IF;
	END LOOP;

	RETURN round(best::numeric, 1);
END;
$$ LANGUAGE plpgsql;

SELECT :rows AS rows, :dim AS dim, :runs AS runs, :digits AS digits,
	(SELECT avg(length(b::text))::int FROM bench_casts) AS json_bytes;

SELECT conversion, bench_casts_best(format(query, :dim), :runs) AS best_ms
FROM (VALUES
	('jsonb -> vector (via text)', 'SELECT count(b::text::vector(%1$s)) FROM bench_casts'),
	('jsonb -> vector', 'SELECT count(b::vector(%1$s)) FROM bench_casts'),
	('jsonb -> halfvec (via text)', 'SELECT count(b::text::halfvec(%1$s)) FROM bench_casts'),
	('jsonb -> halfvec', 'SELECT count(b::halfvec(%1$s)) FROM bench_casts'),
	('vector -> jsonb (via array)', 'SELECT count(to_jsonb(v::real[])) FROM bench_casts'),
	('vector -> json (via array)', 'SELECT count(to_json(v::real[])) FROM bench_casts'),
	('vector -> json', 'SELECT count(v::json) FROM bench_casts')
) AS t(conversion, query);

-- Each time includes the truncate that resets the sink between runs
SELECT ingest, bench_casts_best(format(query, :dim), :runs) AS best_ms
FROM (VALUES
	('insert from jsonb (via text)', 'INSERT INTO bench_casts_sink SELECT b::text::vector(%1$s) FROM bench_casts; TRUNCATE bench_casts_sink'),
	('insert from jsonb', 'INSERT INTO bench_casts_sink SELECT b::vector(%1$s) FROM bench_casts; TRUNCATE bench_casts_sink')
) AS t(ingest, query);

DROP FUNCTION bench_casts_best(text, int);
DROP TABLE bench_casts;
DROP TABLE bench_casts_sink;
