module predefined_macro_regression;
import std::io, aro_runner;

const String PROBE = "test/migration/pp_probe";
const String CASES_DIR = "test/cases";

fn void predefined_macro_regression() @test
{
	DString log;
	log.init(tmem);
	char[] text = file::load_temp("test/migration/predefined_macro_cases.txt")!!;
	CaseEntry[]? list = aro_runner::parse_case_list(tmem, (String)text, "test/migration/predefined_macro_cases.txt", &log);
	io::print(log.str_view());
	assert(@ok(list), "invalid predefined macro case list");
	assert(file::is_file(PROBE), "pp_probe binary missing from runfiles");

	SuiteOptions opts = { .exe = PROBE, .cases_dir = CASES_DIR, .mode = LIST, .list = list!! };
	SuiteReport rep = aro_runner::run_suite(opts, io::stdout());
	rep.print(io::stdout(), false);
	assert(!rep.config_error, "predefined macro case selection failed");
	assert(rep.selected == list!!.len, "not every predefined macro case was selected");
	assert(rep.signaled == 0, "pp_probe crashed");
	assert(rep.passed_gate(false), "predefined macro regression cases failed");
}
