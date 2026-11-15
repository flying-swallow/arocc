// Exact-output regression over data-only AST selectors. These vectors are
// source-derived from the C3 emitter and do not claim executable Zig parity.
module assembly_regression;
import std::io, aro_runner;

const String PROBE = "test/src/probes/assembly_probe";
const String CASES_DIR = "test/regression/assembly/fixtures";
const String CASE_LIST = "test/regression/assembly/cases.txt";

fn CaseEntry[] parse_cases()
{
	DString log;
	log.init(tmem);
	char[] contents = file::load_temp(CASE_LIST)!!;
	CaseEntry[]? parsed = aro_runner::parse_case_list(tmem, (String)contents, CASE_LIST, &log);
	if (catch error = parsed)
	{
		io::eprint(log.str_view());
		unreachable("invalid assembly fixture list: %s", error);
	}
	return parsed;
}

fn void assembly_data_vectors_match_source_derived_goldens() @test
{
	assert(file::is_file(PROBE), "assembly_probe binary missing from runfiles");
	CaseEntry[] list = parse_cases();
	SuiteOptions opts = { .exe = PROBE, .cases_dir = CASES_DIR, .mode = LIST, .list = list,
		.gate = true };
	SuiteReport report = aro_runner::run_suite(opts, io::stdout());
	assert(!report.config_error && report.selected == list.len,
		"assembly fixture selection did not include every listed case");
	assert(report.passed == list.len && report.failed == 0 && report.unsupported == 0,
		"assembly output differed from its source-derived vector");
	assert(report.signaled == 0 && report.passed_gate(true), "assembly fixture probe failed");
}
