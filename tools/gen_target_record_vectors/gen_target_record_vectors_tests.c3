module gen_target_record_vectors_tests;
import std, gen_target_record_vectors;

fn void if_regex_backtracking() @test
{
	String name;
	assert(gen_target_record_vectors::match_if("#ifdef FOO", &name));
	test::eq(name, "FOO");
	assert(gen_target_record_vectors::match_if("#elif defined(BAR) && x", &name));
	test::eq(name, "BAR");
	assert(gen_target_record_vectors::match_if("#if defined BAZ", &name));
	test::eq(name, "defined");
	// `(?:def)?` gives its letters back to `\w+` when nothing follows.
	assert(gen_target_record_vectors::match_if("#ifdef", &name));
	test::eq(name, "def");
	assert(gen_target_record_vectors::match_if("#ifX", &name));
	test::eq(name, "X");
	assert(!gen_target_record_vectors::match_if("#if (X)", &name));
	assert(!gen_target_record_vectors::match_if("#else", &name));
}

fn void mapping_uses_last_end() @test
{
	String name;
	String rest;
	assert(gen_target_record_vectors::match_mapping("// MAPPING|G|a-b-c-d:X|END|e-f-g-h:Y|END trailing", &name, &rest));
	test::eq(name, "G");
	test::eq(rest, "a-b-c-d:X|END|e-f-g-h:Y");
	assert(!gen_target_record_vectors::match_mapping("// MAPPING|G|END", &name, &rest));
}

const String RECORDS = `// MAPPING|ONE|x86_64-x86_64-linux-gnu:Gcc|x86-i686-macos-none:Clang|END
#ifdef ONE
_Static_assert(sizeof(A) == 1, "");
_Static_assert(_Alignof(A) == 01, "");
_Static_assert(sizeof(E) == 2, "");
_Static_assert(_Alignof(E) == 2, "");
_Static_assert(sizeof(G) == 4, "");
_Static_assert(_Alignof(G) == 4, "");
_Static_assert(sizeof(I) == 8, "");
_Static_assert(_Alignof(I) == 8, "");
_Static_assert(sizeof(K) == 8, "");
_Static_assert(_Alignof(K) == 8, "");
_Static_assert(sizeof(L) == 8, "");
_Static_assert(_Alignof(L) == 8, "");
_Static_assert(sizeof(M) == 4, "");
_Static_assert(_Alignof(M) == 4, "");
_Static_assert(sizeof(N) == 8, "");
_Static_assert(_Alignof(N) == 8, "");
#endif
`;

fn void rewrites_region() @test
{
	String tests = "head\n" "\t// BEGIN GENERATED RECORD VECTORS (//tools/gen_target_record_vectors)\n" "old\n" "\t// END GENERATED RECORD VECTORS\n" "tail\n";
	String got = gen_target_record_vectors::rewrite(tmem, tests, RECORDS)!!;
	test::eq(got, "head\n\t// BEGIN GENERATED RECORD VECTORS (//tools/gen_target_record_vectors)\n"
		"\t{ \"x86_64-linux-gnu\", \"x86_64\", { 1, 1, 2, 2, 4, 4, 8, 8, 8, 8, 8, 8, 4, 4, 8, 8 } }, // group ONE\n"
		"\t// END GENERATED RECORD VECTORS\ntail\n");
}
