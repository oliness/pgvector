use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Queries that need every row must not use the index, since scans only
# return tuples from ivfflat.probes lists (or ivfflat.max_probes)
# https://github.com/pgvector/pgvector/issues/846

my $rows = 10000;

# Makes the index path cheaper than a sort
my $cost = "SET random_page_cost = 1.1;";
my $sort = "SET enable_sort = off;";

my $node;

sub query_rows
{
	my ($sql) = @_;
	my $res = $node->safe_psql("postgres", $sql);
	return $res eq "" ? [] : [ split("\n", $res) ];
}

# Distances, in order (ties can be returned in any order)
sub distances
{
	my ($res) = @_;
	return join(",", map { (split(/\|/, $_))[-1] } @$res);
}

# Ids, sorted
sub ids
{
	my ($res) = @_;
	return join(",", sort { $a <=> $b } map { (split(/\|/, $_))[0] } @$res);
}

# Check a query matches an exact scan
sub test_complete
{
	my ($name, $settings, $query, $reference) = @_;
	$reference //= $query;

	my $expected = query_rows("SET enable_indexscan = off; $reference");
	my $actual = query_rows("$settings $query");

	is(scalar(@$actual), scalar(@$expected), "$name: all rows");
	ok(distances($actual) eq distances($expected), "$name: in order");
	ok(ids($actual) eq ids($expected), "$name: same rows");
}

# Check a query does not use the index and matches an exact scan
sub test_exact
{
	my ($name, $settings, $query, $reference) = @_;

	my $explain = $node->safe_psql("postgres", "$settings EXPLAIN (COSTS OFF) $query");
	unlike($explain, qr/Index Scan using \S*idx/, "$name: no index scan");

	test_complete($name, $settings, $query, $reference);
}

sub test_count
{
	my ($name, $settings, $query, $expected) = @_;

	is($node->safe_psql("postgres", "$settings $query"), $expected, $name);
}

sub test_index
{
	my ($name, $settings, $query, $index) = @_;

	my $explain = $node->safe_psql("postgres", "$settings EXPLAIN (COSTS OFF) $query");
	like($explain, qr/Index Scan using \S*$index/, "$name: uses index");
}

# Initialize node
$node = PostgreSQL::Test::Cluster->new('node');
$node->init;
$node->start;

# Create tables
$node->safe_psql("postgres", "CREATE EXTENSION vector;");
$node->safe_psql("postgres", "CREATE TABLE tst (i int4, v vector(3), c int4);");
$node->safe_psql("postgres",
	"INSERT INTO tst SELECT i, ARRAY[random(), random(), random()], i % 10 FROM generate_series(1, $rows) i;"
);
$node->safe_psql("postgres", "CREATE TABLE tst_halfvec (i int4, v halfvec(3));");
$node->safe_psql("postgres", "INSERT INTO tst_halfvec SELECT i, v::halfvec(3) FROM tst;");
$node->safe_psql("postgres", "CREATE TABLE tst_bit (i int4, v bit(64));");
$node->safe_psql("postgres",
	"INSERT INTO tst_bit SELECT i, (SELECT string_agg(CASE WHEN random() > 0.5 THEN '1' ELSE '0' END, '') FROM generate_series(1, 64) WHERE i > 0)::bit(64) FROM generate_series(1, $rows) i;"
);
$node->safe_psql("postgres", "CREATE TABLE ptst (i int4, v vector(3)) PARTITION BY HASH (i);");
for my $r (0 .. 3)
{
	$node->safe_psql("postgres", "CREATE TABLE ptst_$r PARTITION OF ptst FOR VALUES WITH (modulus 4, remainder $r);");
}
$node->safe_psql("postgres", "INSERT INTO ptst SELECT i, v FROM tst;");
$node->safe_psql("postgres", "ANALYZE;");

# Generate queries
my @r = ();
for (1 .. 3)
{
	push(@r, rand());
}
my $vec = "[" . join(",", @r) . "]";
my $bits = join("", map { int(rand(2)) } 1 .. 64);

# Test operator classes
my @opclasses = (
	["tst", "vector_l2_ops", "<->", $vec],
	["tst", "vector_ip_ops", "<#>", $vec],
	["tst", "vector_cosine_ops", "<=>", $vec],
	["tst_halfvec", "halfvec_l2_ops", "<->", $vec],
	["tst_bit", "bit_hamming_ops", "<~>", $bits]
);

for my $opclass (@opclasses)
{
	my ($table, $ops, $op, $query) = @$opclass;
	my $dist = "v $op '$query'";

	$node->safe_psql("postgres", "CREATE INDEX idx ON $table USING ivfflat (v $ops) WITH (lists = 100);");

	test_exact($ops, $sort, "SELECT i, $dist FROM $table ORDER BY $dist;");
	test_index("$ops with limit", $sort, "SELECT i FROM $table ORDER BY $dist LIMIT 10;", "idx");

	$node->safe_psql("postgres", "DROP INDEX idx;");
}

# Test queries without limit
$node->safe_psql("postgres", "CREATE INDEX idx ON tst USING ivfflat (v vector_l2_ops) WITH (lists = 100);");
$node->safe_psql("postgres", "CREATE INDEX ON ptst USING ivfflat (v vector_l2_ops) WITH (lists = 25);");
$node->safe_psql("postgres",
	'CREATE FUNCTION nearest(q vector) RETURNS SETOF int4 AS $$ BEGIN RETURN QUERY SELECT i FROM tst ORDER BY v <-> q; END; $$ LANGUAGE plpgsql;'
);

my $dist = "v <-> '$vec'";

test_exact("no limit", $cost, "SELECT i, $dist FROM tst ORDER BY $dist;");
test_exact("offset", $cost, "SELECT i, $dist FROM tst ORDER BY $dist OFFSET 10;");
test_exact("attribute filter", $cost, "SELECT i, $dist FROM tst WHERE c = 1 ORDER BY $dist;");
test_exact("partitioned table", $cost, "SELECT i, $dist FROM ptst ORDER BY $dist;");
test_exact("more probes", "$cost SET ivfflat.probes = 10;", "SELECT i, $dist FROM tst ORDER BY $dist;");
test_exact("iterative scan", "$cost SET ivfflat.iterative_scan = relaxed_order; SET ivfflat.max_probes = 10;",
	"SELECT i, $dist FROM tst ORDER BY $dist;");
test_exact("generic plan", "$cost SET plan_cache_mode = force_generic_plan; PREPARE p(vector) AS SELECT i, v <-> \$1 FROM tst ORDER BY v <-> \$1;",
	"EXECUTE p('$vec');", "SELECT i, $dist FROM tst ORDER BY $dist;");

# Probing every list is exact, so only check the results
test_complete("all probes", "$cost SET ivfflat.probes = 100;", "SELECT i, $dist FROM tst ORDER BY $dist;");

my $explain = $node->safe_psql("postgres",
	"$cost EXPLAIN (COSTS OFF) SELECT i, row_number() OVER (ORDER BY $dist) FROM tst;");
unlike($explain, qr/Index Scan using \S*idx/, "window function: no index scan");
test_count("window function: all rows", $cost,
	"SELECT COUNT(*), MAX(n) FROM (SELECT row_number() OVER (ORDER BY $dist) AS n FROM tst) s;", "$rows|$rows");

test_count("subquery with aggregate: all rows", $cost, "SELECT COUNT(*) FROM (SELECT i FROM tst ORDER BY $dist) s;", $rows);
test_count("function: all rows", $cost, "SELECT COUNT(*) FROM nearest('$vec');", $rows);

# Test partial index
$node->safe_psql("postgres", "CREATE INDEX partial_idx ON tst USING ivfflat (v vector_l2_ops) WITH (lists = 5) WHERE (c = 1);");
test_exact("partial index", $cost, "SELECT i, $dist FROM tst WHERE c = 1 ORDER BY $dist;");
test_index("partial index with limit", "", "SELECT i FROM tst WHERE c = 1 ORDER BY $dist LIMIT 10;", "partial_idx");
$node->safe_psql("postgres", "DROP INDEX partial_idx;");

# Test queries that should still use the index
my @index_queries = (
	["limit", "", "SELECT i FROM tst ORDER BY $dist LIMIT 10;"],
	["fetch first", "", "SELECT i FROM tst ORDER BY $dist FETCH FIRST 10 ROWS ONLY;"],
	["outer limit", "", "SELECT * FROM (SELECT i FROM tst ORDER BY $dist) s LIMIT 10;"],
	["cte with outer limit", "", "WITH n AS (SELECT i FROM tst ORDER BY $dist) SELECT * FROM n LIMIT 10;"],
	["generic plan with limit", "SET plan_cache_mode = force_generic_plan; PREPARE p(int) AS SELECT i FROM tst ORDER BY $dist LIMIT \$1;",
		"EXECUTE p(10);"],
	["lateral join with limit", "",
		"SELECT q.i, n.i FROM (SELECT i, v FROM tst WHERE i <= 3) q CROSS JOIN LATERAL (SELECT t.i FROM tst t ORDER BY t.v <-> q.v LIMIT 5) n;"],
	["partitioned table with limit", "", "SELECT i FROM ptst ORDER BY $dist LIMIT 10;"],
	["iterative scan with limit", "SET ivfflat.iterative_scan = relaxed_order;", "SELECT i FROM tst ORDER BY $dist LIMIT 10;"],
	["cursor", "", "DECLARE c CURSOR FOR SELECT i FROM tst ORDER BY $dist;"],
	["no limit with enable_seqscan off", "SET enable_seqscan = off;", "SELECT i FROM tst ORDER BY $dist;"],
	["partitioned table with enable_seqscan off", "SET enable_seqscan = off;", "SELECT i FROM ptst ORDER BY $dist;"]
);

for my $q (@index_queries)
{
	my ($name, $settings, $query) = @$q;
	test_index($name, "$cost $settings", $query, "idx");
}

# Test cursor fetches rows from the index
my $res = $node->safe_psql("postgres", qq(
	BEGIN;
	DECLARE c CURSOR FOR SELECT i FROM tst ORDER BY $dist;
	FETCH 10 FROM c;
	COMMIT;
));
my @fetched = split("\n", $res);
is(scalar(@fetched), 10, "cursor fetch");

done_testing();
