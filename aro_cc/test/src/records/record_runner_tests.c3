// Unit tests for the record fixture parser and diagnostic classifier.
module record_runner_tests;
import aro_record_runner;

fn RecordCase[] parse_ok(String path, String contents)
{
	return aro_record_runner::parse_mapping_text(tmem, path, contents)!!;
}

fn void multiple_mapping_lines_keep_path_define_and_target() @test
{
	String contents = "// MAPPING|ONE|x86_64-test-linux-gnu:Gcc|x86-test-linux-gnu:Clang|END\n// MAPPING|TWO|arm-test-other-eabi:Gcc|END\n";
	RecordCase[] cases = parse_ok("aro_cc/test/records/sample_test.c", contents);
	assert(cases.len == 3, "expected 3 cases, got %s", cases.len);
	assert(cases[0].path == "aro_cc/test/records/sample_test.c");
	assert(cases[0].define == "ONE");
	assert(cases[0].target == "x86_64-test-linux-gnu:Gcc");
	assert(cases[1].path == "aro_cc/test/records/sample_test.c");
	assert(cases[1].define == "ONE");
	assert(cases[1].target == "x86-test-linux-gnu:Clang");
	assert(cases[2].path == "aro_cc/test/records/sample_test.c");
	assert(cases[2].define == "TWO");
	assert(cases[2].target == "arm-test-other-eabi:Gcc");
}

fn void define_expands_to_each_target_case() @test
{
	RecordCase[] cases = parse_ok("records.c", "// MAPPING|FEATURE_FLAG|target-a|target-b|target-c|END\n");
	assert(cases.len == 3, "expected 3 expanded cases, got %s", cases.len);
	for (usz i = 0; i < cases.len; i++)
	{
		assert(cases[i].define == "FEATURE_FLAG", "case %s has define '%s'", i, cases[i].define);
		assert(cases[i].path == "records.c");
	}
	assert(cases[0].target == "target-a");
	assert(cases[1].target == "target-b");
	assert(cases[2].target == "target-c");
}

fn void end_stops_current_mapping() @test
{
	RecordCase[] cases = parse_ok("records.c", "// MAPPING|ONE|target-before-end|END|target-after-end\n// MAPPING|TWO|next-mapping|END\n");
	assert(cases.len == 2, "expected 2 cases, got %s", cases.len);
	assert(cases[0].target == "target-before-end");
	assert(cases[0].define == "ONE");
	assert(cases[1].target == "next-mapping");
	assert(cases[1].define == "TWO");
}

fn void mapping_without_targets_is_empty() @test
{
	RecordCase[] cases = parse_ok("records.c", "// MAPPING|NO_TARGETS|END\n");
	assert(cases.len == 0, "expected no cases, got %s", cases.len);
}

fn void diagnostics_classify_layout_failures() @test
{
	ExpectedFailure actual = aro_record_runner::classify_diagnostics("record.c:1:1: error: assertion failed\n_Static_assert(sizeof(struct R) == 8, \"layout\");\n");
	assert(actual.parse == false);
	assert(actual.layout);
	assert(actual.extra == false);
	assert(actual.offset == false);
}

fn void diagnostics_classify_extra_failures() @test
{
	ExpectedFailure actual = aro_record_runner::classify_diagnostics("record.c:1:1: error: assertion failed\n_Static_assert(sizeof(struct R_extra_size) == 8, \"extra\");\n");
	assert(actual.parse == false);
	assert(actual.layout == false);
	assert(actual.extra);
	assert(actual.offset == false);
}

fn void diagnostics_classify_offset_failures() @test
{
	ExpectedFailure actual = aro_record_runner::classify_diagnostics("record.c:1:1: error: assertion failed\n_Static_assert(__builtin_bitoffsetof(struct R, field) == 8, \"offset\");\n");
	assert(actual.parse == false);
	assert(actual.layout == false);
	assert(actual.extra == false);
	assert(actual.offset);
}

fn void diagnostics_classify_unknown_non_static_error_as_parse() @test
{
	ExpectedFailure actual = aro_record_runner::classify_diagnostics("record.c:1:1: error: unknown compiler diagnostic\nthis is not a static assertion\n");
	assert(actual.parse);
	assert(actual.layout == false);
	assert(actual.extra == false);
	assert(actual.offset == false);
}

fn void frozen_failure_tuples_are_layout_and_extra_skips() @test
{
	ExpectedFailure first = aro_record_runner::expected_failure("x86_64-x86_64-windows-gnu:Gcc", "0068");
	assert(!first.parse && first.layout && first.extra && !first.offset);
	ExpectedFailure second = aro_record_runner::expected_failure("x86_64-x86_64-windows-gnu:Gcc", "0082");
	assert(!second.parse && second.layout && second.extra && !second.offset);
	ExpectedFailure ordinary = aro_record_runner::expected_failure("x86_64-x86_64-windows-gnu:Gcc", "0099");
	assert(!ordinary.has_any());
}
