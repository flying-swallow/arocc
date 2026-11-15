// Unit tests for test_suite_runner: directive parsing, written-file contents
// and diagnostic matching.
module test_suite_runner_tests;
import std::io, test_suite_runner;

fn CaseSpec parse_ok(String name, String text)
{
	CaseSpec spec;
	DString log;
	log.tinit();
	bool ok = test_suite_runner::parse_case(tmem, name, text, &spec, &log);
	assert(ok, "parse failed: %s", log.str_view());
	return spec;
}

fn bool parse_fails(String name, String text)
{
	CaseSpec spec;
	DString log;
	log.tinit();
	return !test_suite_runner::parse_case(tmem, name, text, &spec, &log);
}

fn void headers_are_removed_and_trailing_directives_stripped() @test
{
	String text = "// #kind: expand_error\n// #opt: -std=c23 -I include\n// #env: A=1 B=2\n#elifdef // #error@9: macro name missing\r\nint x; // #warning: unused // #note@3: here\nlast";
	CaseSpec spec = parse_ok("x.c", text);
	assert(spec.kind == EXPAND_ERROR);
	assert(spec.opts.len() == 3 && spec.opts[2] == "include");
	assert(spec.env.len() == 2 && spec.env[1].key == "B" && spec.env[1].value == "2");
	RunFile* f = spec.files[0];
	assert(f.name == "x.c");
	// Code bytes survive exactly, including the CR and the missing final newline.
	assert(f.content.str_view() == "#elifdef\r\nint x;\nlast");
	assert(f.diags.len() == 3);
	assert(f.diags[0].kind == "error" && f.diags[0].line == 1 && f.diags[0].col == 9 && f.diags[0].text == "macro name missing");
	assert(f.diags[1].kind == "warning" && f.diags[1].line == 2 && f.diags[1].col == 0 && f.diags[1].text == "unused");
	assert(f.diags[2].kind == "note" && f.diags[2].line == 2 && f.diags[2].col == 3);
}

fn void ordinary_comments_are_code() @test
{
	// Looks like directives but has no known `key:`: kept as code.
	String text = "// #if __is_target_os(ios)\n// #error \"mismatching os\"\n, 0 // #embed does not provide a NUL\n";
	CaseSpec spec = parse_ok("y.c", text);
	assert(spec.files[0].content.str_view() == text);
	assert(spec.files[0].diags.len() == 0 && spec.anywhere.len() == 0);
}

fn void ct_sections() @test
{
	String text = "// #kind: expand\nint a;\n// #file: inc/h.h\nint b; // #warning: w\n// #expect: stdout\nint a;\n// #error: not a directive here\n";
	CaseSpec spec = parse_ok("z.ct", text);
	assert(spec.files.len() == 2);
	assert(spec.files[0].name == "z.c" && spec.files[0].content.str_view() == "int a;\n");
	assert(spec.files[1].name == "inc/h.h" && spec.files[1].content.str_view() == "int b;\n");
	assert(spec.files[1].diags[0].line == 1);
	assert(spec.has_expect && spec.expect_stdout.str_view() == "int a;\n// #error: not a directive here\n");
}

fn void malformed_cases_fail() @test
{
	assert(parse_fails("a.c", "// #kind: nonsense\n"));
	assert(parse_fails("a.c", "// #expect: stdout\n"));          // .c cannot have sections
	assert(parse_fails("a.ct", "// #kind: expand\nint x;\n"));    // expand needs an expected stdout
	assert(parse_fails("a.c", "// #kind: run\nint main(void){}\n")); // run needs #exit
	assert(parse_fails("a.c", "// #error@3: header has no line\n"));
}

fn void diagnostic_lines() @test
{
	Diag d;
	assert(test_suite_runner::parse_diag("#elifndef error.c:4:9: error: macro name missing", &d));
	assert(d.file == "#elifndef error.c" && d.line == 4 && d.col == 9 && d.kind == "error" && d.msg == "macro name missing");
	assert(test_suite_runner::parse_diag("a.c:1:2: error: error: nested", &d));
	assert(d.kind == "error" && d.msg == "error: nested");
	assert(test_suite_runner::parse_diag("x.h:3:1: fatal error: 'y.h' file not found", &d));
	assert(d.kind == "fatal error" && d.file == "x.h");
	assert(test_suite_runner::parse_diag("error: environment variable bad", &d));
	assert(d.loc == "" && d.line == 0 && d.msg == "environment variable bad");
	assert(!test_suite_runner::parse_diag("         ^", &d));
	assert(!test_suite_runner::parse_diag("2 errors generated.", &d));
}

fn bool matches(String text, String stderr)
{
	CaseSpec spec = parse_ok("m.c", text);
	DString out;
	out.tinit();
	return test_suite_runner::check_diagnostics(&spec, stderr, &out);
}

fn void diagnostic_matching() @test
{
	String src = "int a; // #error@5: bad thing\n// #warning: inc.h:2:1: careful\n";
	String good = "m.c:1:5: error: bad thing happened\nint a;\n    ^\ninc.h:2:1: warning: careful now\n1 error generated.\n";
	assert(matches(src, good));
	// Wrong line, column, kind, missing and extra diagnostics all fail.
	assert(!matches(src, "m.c:2:5: error: bad thing\ninc.h:2:1: warning: careful\n"));
	assert(!matches(src, "m.c:1:6: error: bad thing\ninc.h:2:1: warning: careful\n"));
	assert(!matches(src, "m.c:1:5: warning: bad thing\ninc.h:2:1: warning: careful\n"));
	assert(!matches(src, "m.c:1:5: error: bad thing\n"));
	assert(!matches(src, "m.c:1:5: error: bad thing\ninc.h:2:1: warning: careful\nm.c:1:1: note: extra\n"));
	// The same expectation cannot absorb two diagnostics.
	assert(!matches("int a; // #error: x\n", "m.c:1:1: error: x\nm.c:1:2: error: x\n"));
	assert(matches("int a; // #error: x // #error: x\n", "m.c:1:1: error: x\nm.c:1:2: error: x\n"));
}
