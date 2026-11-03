// Tests for the C3 fixture runner (runner.c3). The child compiler is the
// shell script testdata/fake_aro.sh, steered through each case's manifest
// `env =` line. Case files are written under $TEST_TMPDIR at run time so
// fixtures can use space-containing paths and the checked-in corpus is never
// touched.
module runner_tests;
import std::io, std::io::path, std::os::env, aro_runner;

const String FAKE_REL = "test/migration/testdata/fake_aro.sh";

fn String fake_exe()
{
	if (try p = env::get_var(tmem, "FAKE_ARO_EXE")) return p;
	return aro_runner::absolute_from_cwd(tmem, FAKE_REL);
}

// A fresh directory (that may contain spaces) under the test temp dir.
fn String scratch(String name)
{
	String root = env::get_var(tmem, "TEST_TMPDIR") ?? "/tmp";
	String dir = aro_runner::join_path(tmem, root, name);
	if (file::is_dir(dir)) (void)path::rmtree(path::tnew(dir)!!);
	(void)path::mkdir(dir, true)!!;
	return dir;
}

fn String put(String dir, String rel, String contents)
{
	String p = aro_runner::join_path(tmem, dir, rel);
	(void)path::mkdir(aro_runner::dirname(p), true)!!;
	file::save(p, contents)!!;
	return p;
}

fn String read(String dir, String rel)
{
	return (String)file::load(tmem, aro_runner::join_path(tmem, dir, rel))!!;
}

fn CaseOutcome run(String case_path)
{
	return aro_runner::run_case(tmem, case_path, fake_exe());
}

fn Case parse_ok(String contents)
{
	DString log;
	log.init(tmem);
	Case? c = aro_runner::case_from_contents(tmem, "t", contents, &log);
	if (catch err = c)
	{
		io::printfn("unexpected parse failure %s: %s", err, log.str_view());
		unreachable("parse failed");
	}
	return c;
}

macro void expect_parse_fault(String contents, fault expected, String message)
{
	DString log;
	log.init(tmem);
	Case? c = aro_runner::case_from_contents(tmem, "t", contents, &log);
	if (catch err = c)
	{
		assert(err == expected, "wrong fault %s", err);
		assert(log.str_view().contains(message), "missing message '%s' in '%s'", message, log.str_view());
		return;
	}
	unreachable("expected a manifest fault");
}

macro void expect_fail(CaseOutcome o, fault f)
{
	if (o.status != FAIL || o.failure != f)
	{
		io::printfn("status=%s failure=%s log:\n%s", o.status.name(), o.failure, o.log.str_view());
		unreachable("expected failure");
	}
}

macro void expect_pass(CaseOutcome o)
{
	if (o.status != PASS)
	{
		io::printfn("status=%s failure=%s log:\n%s", o.status.name(), o.failure, o.log.str_view());
		unreachable("expected pass");
	}
}

// ---------------------------------------------------------------------------
// Manifest parsing (caseFromFile / trailingLines)
// ---------------------------------------------------------------------------

fn void parse_all_kinds() @test
{
	assert(parse_ok("/** manifest:\nsyntax\n*/").kind == SYNTAX);
	assert(parse_ok("/** manifest:\nsyntax_ignore_errors\n*/").kind == SYNTAX_IGNORE_ERRORS);
	assert(parse_ok("/** manifest:\nexpand_error\n*/").kind == EXPAND_ERROR);
	assert(parse_ok("/** manifest:\nexpand\n*/").kind == EXPAND);
	assert(parse_ok("/** manifest:\nexpand_partial\n*/").kind == EXPAND_PARTIAL);
	Case c = parse_ok("/** manifest:\ncompare_output\n\nhello\nworld\n*/");
	assert(c.kind == COMPARE_OUTPUT);
	assert(c.expected_output == "hello\nworld", "got '%s'", c.expected_output);
	// Surrounding whitespace of the kind line is ignored.
	assert(parse_ok("int x;\n/** manifest: \t\r\n  syntax \r\n*/\n").kind == SYNTAX);
}

fn void parse_options_and_trailing_lines() @test
{
	Case c = parse_ok(`int x;
/** manifest:
syntax
args = -Iinclude  -Wfoo	-x
skip = thing is broken
env = A=1 B=x=y
skip=second

foo.c:1:4: error: something went wrong

  	trailing spaces
*/
`);
	assert(c.name == "t");
	assert(c.kind == SYNTAX);
	// args are split on single spaces only (tabs stay inside an argument).
	assert(c.args.len == 2, "args %s", c.args);
	assert(c.args[0] == "-Iinclude");
	assert(c.args[1] == "-Wfoo\t-x");
	assert(c.skips.len == 2);
	assert(c.skips[0] == "thing is broken");
	assert(c.skips[1] == "second");
	assert(c.env.len == 2);
	assert(c.env[0].key == "A" && c.env[0].value == "1");
	assert(c.env[1].key == "B" && c.env[1].value == "x=y");
	// Trailing lines are trimmed and empty lines in the middle are kept.
	assert(c.expected_errors.len == 3, "errors %s", c.expected_errors);
	assert(c.expected_errors[0] == "foo.c:1:4: error: something went wrong");
	assert(c.expected_errors[1] == "");
	assert(c.expected_errors[2] == "trailing spaces");
}

fn void parse_later_args_replace_earlier() @test
{
	Case c = parse_ok("/** manifest:\nsyntax\nargs = -a -b\nargs = -c\n*/");
	assert(c.args.len == 1 && c.args[0] == "-c");
	c = parse_ok("/** manifest:\nsyntax\nenv = A=1\nenv = B=2\n*/");
	assert(c.env.len == 1 && c.env[0].key == "B");
}

fn void parse_invalid_env_pair_is_ignored() @test
{
	DString log;
	log.init(tmem);
	Case c = aro_runner::case_from_contents(tmem, "t", "/** manifest:\nsyntax\nenv = NOEQ A=1\n*/", &log)!!;
	assert(c.env.len == 1 && c.env[0].key == "A");
	assert(log.str_view().contains("t: invalid env key value pair: NOEQ"));
}

fn void parse_no_blank_line_means_no_trailing_data() @test
{
	Case c = parse_ok("/** manifest:\nexpand\nargs = -DX\n*/");
	assert(c.expected_errors.len == 0);
	// The manifest ends at the LAST `*/` of the file.
	c = parse_ok("/** manifest:\nsyntax\n\na */ b\n*/");
	assert(c.expected_errors.len == 1 && c.expected_errors[0] == "a */ b");
}

fn void parse_malformed_manifests() @test
{
	expect_parse_fault("int x;\n", aro_runner::TEST_MANIFEST_MISSING, "t: no test manifest");
	expect_parse_fault("/* x */ /** manifest:\nsyntax\n", aro_runner::UNTERMINATED_MANIFEST, "t: unterminated manifest");
	expect_parse_fault("/** manifest:\nsyntax\n", aro_runner::UNTERMINATED_MANIFEST, "t: unterminated manifest");
	expect_parse_fault("/** manifest:\nsyntaxx\n*/", aro_runner::TEST_MANIFEST_INVALID_TYPE, "t: invalid test case type: syntaxx");
	expect_parse_fault("/** manifest:\n*/", aro_runner::TEST_MANIFEST_INVALID_TYPE, "t: invalid test case type: ");
	expect_parse_fault("/** manifest:\nsyntax\nfoo.c:1:1: error: x\n*/", aro_runner::TEST_MANIFEST_MISSING_VALUE, "t: missing value for config option: foo.c:1:1: error: x");
	expect_parse_fault("/** manifest:\nsyntax\nbogus = 1\n*/", aro_runner::TEST_MANIFEST_UNKNOWN_OPTION, "t: unknown config option: bogus");
}

fn void malformed_manifest_fails_the_case_without_running() @test
{
	String dir = scratch("malformed");
	String p = put(dir, "bad.c", "int x;\n");
	CaseOutcome o = run(p);
	expect_fail(o, aro_runner::TEST_MANIFEST_MISSING);
	assert(!o.ran);
	assert(o.log.str_view().contains("bad: no test manifest"));
}

fn void non_c_file_is_a_failure() @test
{
	String dir = scratch("nonc");
	String p = put(dir, "notes.txt", "/** manifest:\nsyntax\n*/");
	CaseOutcome o = run(p);
	expect_fail(o, aro_runner::INVALID_NAME);
	assert(o.log.str_view().contains("test case is not a .c file:"));
}

// ---------------------------------------------------------------------------
// Running cases against the fake child
// ---------------------------------------------------------------------------

fn void syntax_passes_and_passes_flags_cwd_and_env() @test
{
	String dir = scratch("dir with space/sub dir");
	put(dir, "data/err.txt", "In file included:\nmy case.c:1:1: warning: first [-Wfoo]\nnoise line\nmy case.c:2:1: error: second\nmy case.c:2:1: note: third\nnote: --sysroot may be required when cross-compiling to Darwin targets\n1 error generated.\n");
	put(dir, "data/out.txt", "AST\n");
	put(dir, "ast/my case.c", "AST\n");
	// Manifest env values cannot contain spaces (the line is split on ' '),
	// so they name space-free files relative to the case directory.
	String p = put(dir, "my case.c", `int x;
/** manifest:
syntax
args = -Iinclude -DFOO=1
env = FAKE_ARGV=data/argv.txt FAKE_OUT=data/out.txt FAKE_ERR=data/err.txt
skip = known gap

warning: first
error: second
note: third
*/
`);
	CaseOutcome o = run(p);
	expect_pass(o);
	assert(o.ran && o.exited && o.exit_code == 0 && o.signal == 0);
	assert(o.skips == 1);
	assert(o.log.str_view() == "my case: known gap\n", "log '%s'", o.log.str_view());
	String argv = read(dir, "data/argv.txt");
	String expected = string::tformat("cwd=%s\narg=-fno-color-diagnostics\narg=my case.c\narg=-fsyntax-only\narg=--verbose-ast\narg=-Iinclude\narg=-DFOO=1\n",
		aro_runner::absolute_from_cwd(tmem, dir));
	assert(argv == expected, "argv:\n%s\nexpected:\n%s", argv, expected);
}

fn void environment_is_inherited_and_overridden() @test
{
	String dir = scratch("env");
	env::set_var("FAKE_ECHO", "from-parent");
	defer env::clear_var("FAKE_ECHO");
	String p = put(dir, "inherit.c", "/** manifest:\nsyntax\n\nwarning: from-parent\n*/");
	expect_pass(run(p));
	p = put(dir, "override.c", "/** manifest:\nsyntax\nenv = FAKE_ECHO=from-case\n\nwarning: from-case\n*/");
	expect_pass(run(p));
}

fn void missing_ast_golden_is_not_an_error() @test
{
	String dir = scratch("noast");
	String p = put(dir, "a.c", "/** manifest:\nsyntax\nenv = FAKE_OUT=a.c\n*/");
	expect_pass(run(p));
}

fn void ast_mismatch_fails() @test
{
	String dir = scratch("astmismatch");
	put(dir, "ast/a.c", "expected ast\n");
	put(dir, "data/out", "actual ast\n");
	String p = put(dir, "a.c", "/** manifest:\nsyntax\nenv = FAKE_OUT=data/out\n*/");
	CaseOutcome o = run(p);
	expect_fail(o, aro_runner::OUTPUT_MISMATCH);
	assert(o.log.str_view().contains("expected ast"));
	assert(o.log.str_view().contains("in case 'a'"));
	// syntax_ignore_errors still compares the AST.
	p = put(dir, "b.c", "/** manifest:\nsyntax_ignore_errors\nenv = FAKE_OUT=data/out\n*/");
	put(dir, "ast/b.c", "other\n");
	expect_fail(run(p), aro_runner::OUTPUT_MISMATCH);
}

fn void syntax_ignore_errors_ignores_diagnostics() @test
{
	String dir = scratch("ignore");
	String p = put(dir, "a.c", "/** manifest:\nsyntax_ignore_errors\nenv = FAKE_ECHO=whatever FAKE_EXIT=1\n*/");
	CaseOutcome o = run(p);
	expect_pass(o);
	assert(o.exit_code == 1);
}

fn void diagnostics_are_ordered_substrings() @test
{
	String dir = scratch("diags");
	put(dir, "data/err", "a.c:1:1: error: one\na.c:2:1: warning: two\n");
	String p = put(dir, "ok.c", "/** manifest:\nsyntax\nenv = FAKE_ERR=data/err\n\nerror: one\ntwo\n*/");
	expect_pass(run(p));
	p = put(dir, "swapped.c", "/** manifest:\nsyntax\nenv = FAKE_ERR=data/err\n\nwarning: two\nerror: one\n*/");
	CaseOutcome o = run(p);
	expect_fail(o, aro_runner::MISSING_ERROR);
	assert(o.log.str_view().contains("======= expected to find error =======\nwarning: two"));
	p = put(dir, "missing.c", "/** manifest:\nsyntax\nenv = FAKE_ERR=data/err\n\nerror: one\nwarning: two\nnote: three\n*/");
	o = run(p);
	expect_fail(o, aro_runner::MISMATCHED_ERRORS);
	assert(o.log.str_view().contains("note: three"));
	p = put(dir, "extra.c", "/** manifest:\nsyntax\nenv = FAKE_ERR=data/err\n\nerror: one\n*/");
	o = run(p);
	expect_fail(o, aro_runner::MISMATCHED_ERRORS);
	assert(o.log.str_view().contains("========= new error ==========\na.c:2:1: warning: two"));
	assert(o.log.str_view().contains("in case 'extra'"));
	// No expected diagnostics, none produced.
	p = put(dir, "none.c", "/** manifest:\nsyntax\n*/");
	expect_pass(run(p));
}

fn void expand_uses_e_p_and_exact_golden() @test
{
	String dir = scratch("expand");
	put(dir, "data/out", "int x;\n");
	put(dir, "expanded/a.c", "int x;\n");
	String p = put(dir, "a.c", "/** manifest:\nexpand\nargs = -std=c23\nenv = FAKE_OUT=data/out FAKE_ARGV=data/argv\n*/");
	expect_pass(run(p));
	String argv = read(dir, "data/argv");
	assert(argv.contains("arg=a.c\narg=-E\narg=-P\narg=-std=c23\n"), "argv %s", argv);
	put(dir, "expanded/b.c", "int x;");
	p = put(dir, "b.c", "/** manifest:\nexpand\nenv = FAKE_OUT=data/out\n*/");
	expect_fail(run(p), aro_runner::OUTPUT_MISMATCH);
}

fn void expand_requires_golden() @test
{
	String dir = scratch("expandmissing");
	String p = put(dir, "a.c", "/** manifest:\nexpand\n*/");
	CaseOutcome o = run(p);
	expect_fail(o, aro_runner::GOLDEN_UNREADABLE);
	assert(o.log.str_view().contains("can't open expanded file"));
	p = put(dir, "b.c", "/** manifest:\nexpand_partial\n*/");
	expect_fail(run(p), aro_runner::GOLDEN_UNREADABLE);
}

fn void expand_partial_checks_suffix() @test
{
	String dir = scratch("partial");
	put(dir, "data/out", "prefix\nint x;\nsuffix\n");
	put(dir, "expanded/end.c", "suffix\n");
	put(dir, "expanded/middle.c", "int x;\n");
	put(dir, "expanded/start.c", "prefix\n");
	String p = put(dir, "end.c", "/** manifest:\nexpand_partial\nenv = FAKE_OUT=data/out\n*/");
	expect_pass(run(p));
	p = put(dir, "middle.c", "/** manifest:\nexpand_partial\nenv = FAKE_OUT=data/out\n*/");
	expect_fail(run(p), aro_runner::OUTPUT_MISMATCH);
	p = put(dir, "start.c", "/** manifest:\nexpand_partial\nenv = FAKE_OUT=data/out\n*/");
	CaseOutcome o = run(p);
	expect_fail(o, aro_runner::OUTPUT_MISMATCH);
	assert(o.log.str_view().contains("expected to end with"));
}

fn void expand_error_checks_only_diagnostics() @test
{
	String dir = scratch("experr");
	String p = put(dir, "a.c", "/** manifest:\nexpand_error\nenv = FAKE_ECHO=bad FAKE_EXIT=1 FAKE_OUT=a.c\n\nwarning: bad\n*/");
	CaseOutcome o = run(p);
	expect_pass(o);
	assert(o.exit_code == 1);
}

fn void compare_output_is_unsupported() @test
{
	String dir = scratch("compare");
	String p = put(dir, "hello world.c", "/** manifest:\ncompare_output\nenv = FAKE_ARGV=argv\n\nHello, world!\n*/");
	CaseOutcome o = run(p);
	assert(o.status == UNSUPPORTED);
	assert(!o.ran);
	assert(!file::exists(aro_runner::join_path(tmem, dir, "argv")), "child must not run");
	assert(o.log.str_view() == "hello world: TODO compare output\n");
}

fn void crash_is_a_failure_with_signal() @test
{
	String dir = scratch("crash");
	String p = put(dir, "a.c", "/** manifest:\nsyntax_ignore_errors\nenv = FAKE_SIGNAL=SEGV\n*/");
	CaseOutcome o = run(p);
	expect_fail(o, aro_runner::CRASHED);
	assert(o.ran && !o.exited && o.signal == 11, "signal %d", o.signal);
	assert(o.log.str_view().contains("arocc command crashed:\n"));
	p = put(dir, "b.c", "/** manifest:\nsyntax\nenv = FAKE_SIGNAL=ABRT\n*/");
	o = run(p);
	expect_fail(o, aro_runner::CRASHED);
	assert(o.signal == 6);
}

fn void nonzero_exit_and_fatal_are_recorded() @test
{
	String dir = scratch("exit");
	put(dir, "data/err", "a.c:1:1: fatal error: 'x.h' file not found\n");
	String p = put(dir, "a.c", "/** manifest:\nsyntax\nenv = FAKE_ERR=data/err FAKE_EXIT=1\n\nfatal error: 'x.h'\n*/");
	CaseOutcome o = run(p);
	// runner.zig accepts any exit status once diagnostics match.
	expect_pass(o);
	assert(o.exited && o.exit_code == 1 && o.fatal);
}

fn void large_output_on_both_pipes_does_not_deadlock() @test
{
	String dir = scratch("flood");
	String p = put(dir, "a.c", "/** manifest:\nsyntax_ignore_errors\nenv = FAKE_FLOOD=1048576\n*/");
	CaseOutcome o = run(p);
	expect_pass(o);
	assert(o.stdout_len == 1048576 && o.stderr_len == 1048576, "%d %d", o.stdout_len, o.stderr_len);
}

fn void missing_executable_fails() @test
{
	String dir = scratch("noexe");
	String p = put(dir, "a.c", "/** manifest:\nsyntax\n*/");
	CaseOutcome o = aro_runner::run_case(tmem, p, aro_runner::join_path(tmem, dir, "does-not-exist"));
	expect_fail(o, aro_runner::SPAWN_FAILED);
	assert(!o.ran);
}

// ---------------------------------------------------------------------------
// Case lists, selection modes, gates and failure propagation
// ---------------------------------------------------------------------------

fn CaseEntry[] list_ok(String text)
{
	DString log;
	log.init(tmem);
	CaseEntry[]? l = aro_runner::parse_case_list(tmem, text, "list", &log);
	if (catch err = l)
	{
		io::printfn("%s", log.str_view());
		unreachable("list parse failed");
	}
	return l;
}

macro void expect_list_fault(String text, String message)
{
	DString log;
	log.init(tmem);
	CaseEntry[]? l = aro_runner::parse_case_list(tmem, text, "list", &log);
	if (catch err = l)
	{
		assert(err == aro_runner::CASE_LIST_INVALID);
		assert(log.str_view().contains(message), "log '%s'", log.str_view());
		return;
	}
	unreachable("expected list fault");
}

fn void case_list_parsing() @test
{
	CaseEntry[] l = list_ok("// comment\n\n#pragma pack msvc.c\nhello world.c result=unsupported\n  b.c exit=1 fatal  \nc.c result=fail signal=11\n");
	assert(l.len == 4);
	assert(l[0].file == "#pragma pack msvc.c");
	assert(l[0].expect.result == PASS && l[0].expect.exit_code == 0 && !l[0].expect.fatal);
	assert(l[1].file == "hello world.c" && l[1].expect.result == UNSUPPORTED);
	assert(l[2].file == "b.c" && l[2].expect.exit_code == 1 && l[2].expect.fatal);
	assert(l[3].expect.result == FAIL && l[3].expect.signal == 11);
	expect_list_fault("a.h\n", "must name a .c file");
	expect_list_fault("a.c\na.c\n", "duplicate case entry 'a.c'");
	expect_list_fault("a.c bogus=1\n", "unknown expectation key 'bogus'");
	expect_list_fault("a.c result=maybe\n", "invalid result 'maybe'");
	expect_list_fault("a.c exit=x\n", "invalid exit status 'x'");
	expect_list_fault("sub/a.c\n", "file name inside the cases directory");
}

fn String make_corpus(String name)
{
	String dir = scratch(name);
	put(dir, "README.md", "ignored\n");
	put(dir, "data/err", "a.c:1:1: error: boom\n");
	put(dir, "pass.c", "/** manifest:\nsyntax\n*/");
	put(dir, "errors.c", "/** manifest:\nsyntax\nenv = FAKE_ERR=data/err FAKE_EXIT=1\n\nerror: boom\n*/");
	put(dir, "hello world.c", "/** manifest:\ncompare_output\n\nhi\n*/");
	put(dir, "skipped.c", "/** manifest:\nsyntax\nskip = one\nskip = two\n*/");
	return dir;
}

fn SuiteReport suite(String dir, SelectMode mode, String list, bool gate, DString* out)
{
	SuiteOptions opts = { .exe = fake_exe(), .cases_dir = dir, .mode = mode, .gate = gate };
	if (list.len) opts.list = list_ok(list);
	return aro_runner::run_suite(opts, out);
}

fn void corpus_mode_counts() @test
{
	String dir = make_corpus("corpus");
	DString out;
	out.init(tmem);
	SuiteReport r = suite(dir, CORPUS, "", false, &out);
	assert(!r.config_error);
	assert(r.selected == 4, "selected %d", r.selected);
	assert(r.executed == 3);
	assert(r.passed == 3);
	assert(r.failed == 0);
	assert(r.unsupported == 1);
	assert(r.skips == 2);
	assert(r.nonzero_exit == 1);
	assert(r.passed_gate(false));
	assert(out.str_view().contains("skipped: one\nskipped: two\n"));
}

fn void failure_propagates_to_suite_result() @test
{
	String dir = make_corpus("corpusfail");
	put(dir, "crash.c", "/** manifest:\nsyntax\nenv = FAKE_SIGNAL=SEGV\n*/");
	put(dir, "wrong.c", "/** manifest:\nsyntax\n\nerror: never printed\n*/");
	DString out;
	out.init(tmem);
	SuiteReport r = suite(dir, CORPUS, "", false, &out);
	assert(r.selected == 6);
	assert(r.failed == 2, "failed %d", r.failed);
	assert(r.signaled == 1);
	assert(!r.passed_gate(false));
	DString rep;
	rep.init(tmem);
	r.print(&rep, false);
	assert(rep.str_view().contains("failed: 2\n"));
	assert(rep.str_view().contains("RESULT: FAIL\n"));
}

fn void list_mode_selects_and_rejects_bad_selections() @test
{
	String dir = make_corpus("listmode");
	DString out;
	out.init(tmem);
	SuiteReport r = suite(dir, LIST, "pass.c\n", false, &out);
	assert(!r.config_error && r.selected == 1 && r.passed == 1);

	out.clear();
	r = suite(dir, LIST, "pass.c\nnope.c\n", false, &out);
	assert(r.config_error && !r.passed_gate(false));
	assert(out.str_view().contains("case list entry does not exist: nope.c (line 2)"));

	out.clear();
	r = suite(dir, LIST, "// nothing\n", false, &out);
	assert(r.config_error);
	assert(out.str_view().contains("empty case selection"));

	out.clear();
	r = suite(scratch("emptydir"), CORPUS, "", false, &out);
	assert(r.config_error);
}

fn void full_mode_rejects_unclassified_cases() @test
{
	String dir = make_corpus("fullmode");
	DString out;
	out.init(tmem);
	SuiteReport r = suite(dir, FULL, "pass.c\nerrors.c\n", false, &out);
	assert(r.config_error);
	assert(out.str_view().contains("unclassified case: hello world.c"));
	assert(out.str_view().contains("unclassified case: skipped.c"));
	assert(!out.str_view().contains("README.md"));

	out.clear();
	r = suite(dir, FULL, "pass.c\nerrors.c exit=1\nhello world.c result=unsupported\nskipped.c\n", true, &out);
	assert(!r.config_error);
	assert(r.selected == 4 && r.gate_mismatches == 0, "%s", out.str_view());
	assert(r.passed_gate(true));
}

fn void gate_compares_complete_outcomes() @test
{
	String dir = make_corpus("gate");
	put(dir, "data/fatal", "a.c:1:1: fatal error: 'x.h' file not found\n");
	put(dir, "fatal.c", "/** manifest:\nsyntax\nenv = FAKE_ERR=data/fatal FAKE_EXIT=1\n\nfatal error\n*/");
	put(dir, "crash.c", "/** manifest:\nsyntax_ignore_errors\nenv = FAKE_SIGNAL=SEGV\n*/");
	DString out;
	out.init(tmem);

	// Nonzero exit without an expectation is a gate failure even though the
	// case passes in runner.zig terms.
	SuiteReport r = suite(dir, LIST, "errors.c\n", true, &out);
	assert(r.passed == 1 && r.gate_mismatches == 1);
	assert(!r.passed_gate(true));
	assert(out.str_view().contains("gate mismatch: errors.c: expected result=pass exit=0 signal=0, got result=pass exit=1 signal=0"), "%s", out.str_view());

	// A fatal diagnostic must be expected explicitly, even with the right exit.
	out.clear();
	r = suite(dir, LIST, "fatal.c exit=1\n", true, &out);
	assert(r.gate_mismatches == 1);
	out.clear();
	r = suite(dir, LIST, "fatal.c exit=1 fatal\n", true, &out);
	assert(r.gate_mismatches == 0 && r.passed_gate(true));

	// A crash never matches a plain known failure; only the exact signal does.
	out.clear();
	r = suite(dir, LIST, "crash.c result=fail\n", true, &out);
	assert(r.gate_mismatches == 1);
	out.clear();
	r = suite(dir, LIST, "crash.c result=fail signal=11\n", true, &out);
	assert(r.gate_mismatches == 0);

	// Unsupported must be declared, and an unexpected pass is a mismatch too.
	out.clear();
	r = suite(dir, LIST, "hello world.c\npass.c result=fail\n", true, &out);
	assert(r.gate_mismatches == 2);
}

fn void gate_rejects_unspawnable_compiler() @test
{
	String dir = make_corpus("gatenoexe");
	SuiteOptions opts = { .exe = aro_runner::join_path(tmem, dir, "missing-exe"), .cases_dir = dir, .mode = LIST, .gate = true };
	opts.list = list_ok("pass.c result=fail\n");
	DString out;
	out.init(tmem);
	SuiteReport r = aro_runner::run_suite(opts, &out);
	assert(r.failed == 1 && r.executed == 0);
	assert(r.gate_mismatches == 1, "a case that never ran cannot match");
}

fn void outcome_log_is_written_after_collection() @test
{
	String dir = make_corpus("tsv");
	String log_dir = scratch("tsv log dir");
	SuiteOptions opts = { .exe = fake_exe(), .cases_dir = dir, .mode = CORPUS, .log_path = aro_runner::join_path(tmem, log_dir, "out come.tsv") };
	DString out;
	out.init(tmem);
	SuiteReport r = aro_runner::run_suite(opts, &out);
	assert(!r.config_error);
	String tsv = read(log_dir, "out come.tsv");
	assert(tsv.starts_with("case\tresult\texit\tsignal\tfatal\tstdout_bytes\tstderr_bytes\texpected\tgate\n"));
	assert(tsv.contains("errors.c\tpass\t1\t0\tno\t0\t21\t"), "%s", tsv);
	assert(tsv.contains("hello world.c\tunsupported\tnone\t"));
}
