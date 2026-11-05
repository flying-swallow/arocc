module preprocessor_regression;
import std::io, aro_runner;

const String PROBE = "test/migration/pp_probe";
const String CASES_DIR = "test/cases";

fn void run_case_list(String case_list)
{
	DString log;
	log.init(tmem);
	char[] text = file::load_temp(case_list)!!;
	CaseEntry[]? list = aro_runner::parse_case_list(tmem, (String)text, case_list, &log);
	io::print(log.str_view());
	assert(@ok(list), "invalid preprocessing case list");
	assert(file::is_file(PROBE), "pp_probe binary missing from runfiles");

	SuiteOptions opts = { .exe = PROBE, .cases_dir = CASES_DIR, .mode = LIST, .list = list!! };
	SuiteReport rep = aro_runner::run_suite(opts, io::stdout());
	rep.print(io::stdout(), false);
	assert(!rep.config_error, "preprocessing case selection failed");
	assert(rep.selected == list!!.len, "not every preprocessing case was selected");
	assert(rep.signaled == 0, "pp_probe crashed");
	assert(rep.passed_gate(false), "preprocessing regression cases failed");
}

fn void preprocessing_regression() @test
{
	run_case_list("test/migration/macro_regression_cases.txt");
	run_case_list("test/migration/predefined_macro_cases.txt");
	run_case_list("test/migration/include_embed_regression_cases.txt");
}
