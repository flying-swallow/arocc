// //test/migration:reference_regression
//
// Runs the whole integration corpus (test/cases, Bazel data) through the C3
// runner with a supplied reference compiler, in runner.zig-compatible mode,
// and reconciles the counts with test/migration/baseline.json.
//
// The reference executable is supplied with
//   --test_env=ARO_REFERENCE_EXE=/absolute/path/to/arocc
// No Zig executable exists in this environment, so without that variable the
// test prints "reference executable unavailable" and FAILS on purpose: a
// reference run that did not happen must never look green.
module reference_regression;
import std::io, std::os::env, std::encoding::json, std::collections::object, aro_runner;

const String CASES_DIR = "test/cases";
const String BASELINE = "test/migration/baseline.json";

fn void reference_regression() @test
{
	// Inventory reconciliation runs even without a reference executable.
	Object* baseline = json::tparse((String)file::load_temp(BASELINE)!!)!!;
	Object* summary = baseline.get("integration_cases")!!.get("summary")!!;
	uint expected_files = summary.get_uint("top_level_files")!!;
	uint expected_unsupported = summary.get_uint("unimplemented_compare_output")!!;
	uint expected_zig_skips = summary.get_uint("runner_skip_stat_if_all_pass")!!;

	DString log;
	log.init(tmem);
	String[] corpus = aro_runner::list_corpus(tmem, CASES_DIR, &log)!!;
	io::printfn("corpus files: %d (baseline.json top_level_files: %d)", corpus.len, expected_files);
	assert(corpus.len == expected_files, "corpus does not match baseline.json inventory");

	String? exe = env::get_var(tmem, "ARO_REFERENCE_EXE");
	if (catch exe)
	{
		io::printn("reference executable unavailable: no reference run was performed.");
		io::printn("Set --test_env=ARO_REFERENCE_EXE=/absolute/path/to/arocc to run the corpus.");
		unreachable("reference executable unavailable (ARO_REFERENCE_EXE not set)");
	}
	if (!exe.len || !file::is_file(exe))
	{
		io::printfn("reference executable unavailable: '%s' is not a file.", exe);
		unreachable("reference executable unavailable");
	}

	SuiteOptions opts = { .exe = exe, .cases_dir = CASES_DIR, .mode = CORPUS };
	String out_dir = env::get_var(tmem, "TEST_UNDECLARED_OUTPUTS_DIR") ?? "";
	if (out_dir.len) opts.log_path = aro_runner::join_path(tmem, out_dir, "reference_outcomes.tsv");
	SuiteReport rep = aro_runner::run_suite(opts, io::stdout());
	rep.print(io::stdout(), false);

	io::printfn("baseline reconciliation: selected %d/%d, unsupported %d/%d, runner.zig skip stat %d/%d",
		rep.selected, expected_files, rep.unsupported, expected_unsupported,
		rep.skips + rep.unsupported, expected_zig_skips);
	assert(rep.selected == expected_files, "selected count differs from baseline");
	assert(rep.executed + rep.unsupported == rep.selected, "not every selected case ran to completion");
	assert(rep.unsupported == expected_unsupported, "compare_output count differs from baseline");
	assert(rep.passed_gate(false), "reference run has failing cases");
	assert(rep.signaled == 0, "reference compiler crashed");
	assert(rep.skips + rep.unsupported == expected_zig_skips, "skip count differs from baseline");
}
