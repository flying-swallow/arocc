// Exercise preprocessing of initializer-bearing source files. The cases use
// expand_error mode so this target checks preprocessing only.
module initializer_regression;
import std::io, aro_runner;

const String PROBE = "src/tests/migration/frontend_probe";
const String CASES_DIR = "test/regression/declaration/fixtures";

fn void initializer_sources_preprocess_without_diagnostics() @test
{
	assert(file::is_file(PROBE), "frontend_probe binary missing from runfiles");
	DString log;
	log.init(tmem);
	char[] text = file::load_temp("test/regression/initializer/cases.txt")!!;
	CaseEntry[] entries = aro_runner::parse_case_list(tmem, (String)text, "initializer_regression_cases.txt", &log)!!;
	SuiteOptions opts = { .exe = PROBE, .cases_dir = CASES_DIR, .mode = LIST, .list = entries };
	SuiteReport report = aro_runner::run_suite(opts, io::stdout());
	assert(!report.config_error && report.selected == 3 && report.passed == 3,
		"initializer source preprocessing regression failed");
	assert(report.signaled == 0 && report.passed_gate(true),
		"initializer sources should preprocess cleanly");
}
