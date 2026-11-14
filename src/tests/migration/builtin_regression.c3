// Frontend regression scaffold for builtin expressions. Keep this test
// dormant until the fixture set has complete expected outcomes; parser
// callback failures are not builtin outcomes and must not be frozen as such.
module builtin_regression;
import std::io, std::core::string, aro_runner;

const String PROBE = "src/tests/migration/frontend_probe";
const String CASES_DIR = "test/regression/builtin/fixtures";
const String CASE_LIST = "test/regression/builtin/cases.txt";

// The probe now binds declaration, expression, and builtin call productions.
// Enable only after the selected cases have source-derived expected outcomes;
// AST goldens are intentionally not invented for this gate.
const bool RUN_BUILTIN_REGRESSION = false;

const uint FIXTURE_COUNT = 9;

fn CaseEntry[] parse_cases()
{
	DString log;
	log.init(tmem);
	char[] contents = file::load_temp(CASE_LIST)!!;
	CaseEntry[]? parsed = aro_runner::parse_case_list(tmem, (String)contents, CASE_LIST, &log);
	if (catch error = parsed)
	{
		io::eprint(log.str_view());
		unreachable("invalid builtin fixture list: %s", error);
	}
	return parsed;
}

fn void builtin_frontend_vectors_match_manifest() @test
{
	CaseEntry[] list = parse_cases();
	assert(list.len == FIXTURE_COUNT, "builtin fixture manifest inventory changed");
	foreach (entry : list)
	{
		String path = string::tformat("%s/%s", CASES_DIR, entry.file);
		assert(file::is_file(path), "builtin fixture is missing: %s", path);
	}

	if (!RUN_BUILTIN_REGRESSION)
	{
		(void)io::fprintn(io::stdout(), "PENDING: builtin fixtures need complete expected diagnostics and AST/value goldens");
		return;
	}

	assert(file::is_file(PROBE), "frontend_probe binary missing from runfiles");
	SuiteOptions opts = {
		.exe = PROBE,
		.cases_dir = CASES_DIR,
		.mode = FULL,
		.list = list,
		.gate = true,
	};
	SuiteReport report = aro_runner::run_suite(opts, io::stdout());
	report.print(io::stdout(), true);
	assert(!report.config_error, "builtin fixture selection or manifest is invalid");
	assert(report.selected == list.len, "builtin fixture selection differs from the manifest");
	assert(report.executed == report.selected,
		"builtin fixture suite did not execute every selected case");
	assert(report.unsupported == 0, "builtin fixture suite contains unsupported cases");
	assert(report.signaled == 0, "frontend_probe crashed on a builtin fixture");
	assert(report.gate_mismatches == 0 && report.passed_gate(true),
		"builtin fixture outcomes differ from their exact manifest expectations");
}
