// Runs the complete frozen frontend corpus through aro_c3 and the
// shared fixture runner. The source corpus and its goldens define expected
// diagnostics and output; the case list freezes inventory coverage.
module frontend_regression;
import std::io, std::core::string, std::os::env, aro_runner;

const String ARO = env::WIN32 ? "aro_c3.exe" : "aro_c3";
const String CASES_DIR = "test/cases";
const String CASE_LIST = "test/migration/frontend_regression_cases.txt";

fn void assert_frozen_manifest_inventory(CaseEntry[] entries)
{
	uint[6] kinds;
	uint with_args;
	uint with_env;
	uint skip_lines;
	uint ast_goldens;
	uint expanded_goldens;
	foreach (entry : entries)
	{
		String path = string::tformat("%s/%s", CASES_DIR, entry.file);
		DString parse_log;
		parse_log.init(tmem);
		Case? parsed = aro_runner::case_from_file(tmem, path, &parse_log);
		if (catch error = parsed)
		{
			io::eprint(parse_log.str_view());
			unreachable("could not parse frontend manifest %s: %s", entry.file, error);
		}
		Case c = parsed;
		switch (c.kind)
		{
			case SYNTAX: kinds[0]++;
			case SYNTAX_IGNORE_ERRORS: kinds[1]++;
			case EXPAND_ERROR: kinds[2]++;
			case EXPAND: kinds[3]++;
			case EXPAND_PARTIAL: kinds[4]++;
			case COMPARE_OUTPUT: kinds[5]++;
		}
		if (c.args.len) with_args++;
		if (c.env.len) with_env++;
		skip_lines += (uint)c.skips.len;
		if (file::is_file(string::tformat("%s/ast/%s", CASES_DIR, entry.file))) ast_goldens++;
		if (file::is_file(string::tformat("%s/expanded/%s", CASES_DIR, entry.file))) expanded_goldens++;
	}
	assert(kinds[0] == 387 && kinds[1] == 7 && kinds[2] == 41 &&
		kinds[3] == 52 && kinds[4] == 5 && kinds[5] == 1,
		"frontend manifest kind distribution differs from the frozen inventory");
	assert(with_args == 282 && with_env == 3 && skip_lines == 29,
		"frontend manifest args/env/skip inventory differs from frozen baseline plus verified addition");
	assert(ast_goldens == 34, "frontend AST golden inventory differs from the frozen baseline");
	assert(expanded_goldens == 57, "frontend expanded golden inventory differs from frozen baseline plus verified addition");
}

fn void complete_frontend_corpus_regression() @test
{
	assert(file::is_file(ARO), "aro_c3 binary missing from runfiles");
	DString log;
	log.init(tmem);
	char[] text = file::load_temp(CASE_LIST)!!;
	CaseEntry[]? parsed = aro_runner::parse_case_list(tmem, (String)text, CASE_LIST, &log);
	if (catch error = parsed)
	{
		io::eprint(log.str_view());
		unreachable("invalid frontend regression case list: %s", error);
	}
	assert_frozen_manifest_inventory(parsed);

	SuiteOptions opts = {
		.exe = ARO,
		.cases_dir = CASES_DIR,
		.mode = FULL,
		.list = parsed,
		.gate = true,
	};
	SuiteReport report = aro_runner::run_suite(opts, io::stdout());
	report.print(io::stdout(), true);
	assert(!report.config_error, "frontend corpus selection or fixture manifest is invalid");
	assert(report.selected == 493, "frontend corpus inventory differs from frozen baseline plus verified addition");
	assert(report.executed == 492, "frontend execution count differs from frozen baseline plus verified addition");
	assert(report.passed == 492 && report.failed == 0, "frontend fixture diagnostics or output differ");
	assert(report.unsupported == 1, "compare_output support count differs from the frozen reference baseline");
	assert(report.skips == 29, "frontend manifest skip count differs from the frozen reference baseline");
	assert(report.nonzero_exit == 0, "aro_c3 exited nonzero for a fixture");
	assert(report.signaled == 0, "aro_c3 crashed for a fixture");
	assert(report.fatal == 0, "aro_c3 emitted fatal diagnostics");
	assert(report.gate_mismatches == 0 && report.passed_gate(true), "frontend corpus gate failed");
}
