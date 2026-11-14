// Layout and declaration-attribute regressions through frontend_probe.
module attribute_regression;
import std::io, aro_runner;

const String PROBE = "test/migration/frontend_probe";
const String CASES_DIR = "test/migration/attribute_fixtures";

fn CaseEntry[] parse_manifest(String path)
{
	DString log;
	log.init(tmem);
	char[] text = file::load_temp(path)!!;
	CaseEntry[]? parsed = aro_runner::parse_case_list(tmem, (String)text, path, &log);
	if (catch error = parsed)
	{
		io::eprint(log.str_view());
		unreachable("invalid attribute fixture manifest: %s", error);
	}
	return parsed;
}

fn void frontend_pack_and_attribute_layouts_match() @test
{
	assert(file::is_file(PROBE), "frontend_probe binary missing from runfiles");
	CaseEntry[] list = parse_manifest("test/migration/attribute_regression_cases.txt");
	SuiteOptions opts = { .exe = PROBE, .cases_dir = CASES_DIR, .mode = LIST, .list = list };
	SuiteReport report = aro_runner::run_suite(opts, io::stdout());
	assert(!report.config_error && report.selected == 4 && report.passed == 4,
		"pack and declaration-attribute layout assertions failed");
	assert(report.signaled == 0 && report.passed_gate(true),
		"frontend layout fixture did not match its expected outcome");
}
