// Smoke coverage for declarations and expressions through frontend_probe.
module declaration_regression;
import std::io, aro_runner;

const String PROBE = "src/tests/migration/frontend_probe";
const String CASES_DIR = "test/regression/declaration/fixtures";

fn CaseEntry[] parse_manifest(String path)
{
	DString log;
	log.init(tmem);
	char[] text = file::load_temp(path)!!;
	CaseEntry[]? parsed = aro_runner::parse_case_list(tmem, (String)text, path, &log);
	if (catch error = parsed)
	{
		io::eprint(log.str_view());
		unreachable("invalid declaration fixture manifest: %s", error);
	}
	return parsed;
}

fn SuiteReport run_manifest(String path)
{
	CaseEntry[] list = parse_manifest(path);
	SuiteOptions opts = { .exe = PROBE, .cases_dir = CASES_DIR, .mode = LIST, .list = list };
	return aro_runner::run_suite(opts, io::stdout());
}

fn void declaration_supported_smokes() @test
{
	assert(file::is_file(PROBE), "frontend_probe binary missing from runfiles");
	SuiteReport supported = run_manifest("test/regression/declaration/cases.txt");
	assert(!supported.config_error && supported.selected == 2 && supported.passed == 2,
		"supported declaration parser cases failed");
	assert(supported.signaled == 0 && supported.passed_gate(true),
		"declaration parser cases did not match their expected outcomes");
}
