// Integration coverage using an explicit runfile fixture tree. The pp_probe
// is still a preprocessing-only driver; expected bytes and diagnostics are
// checked directly without requiring parser support or Zig execution.
module preprocessor_integration;
import std::io, std::collections::list, aro_runner;

const String PROBE = "src/tests/migration/pp_probe";
const String SOURCE = "test/regression/preprocessor/fixtures/main.c";
const String SEARCH_FIRST = "test/regression/preprocessor/fixtures/search/first";
const String SEARCH_SECOND = "test/regression/preprocessor/fixtures/search/second";
const String FRAMEWORKS = "test/regression/preprocessor/fixtures/Frameworks";

fn ChildResult run_fixture(String source, String mode)
{
	List{String} args;
	args.init(tmem);
	args.push(aro_runner::absolute_from_cwd(tmem, PROBE));
	args.push("-fno-color-diagnostics");
	args.push(source);
	args.push(mode);
	if (mode == "-E") args.push("-P");
	args.push("-std=c23");
	args.push("-I");
	args.push(SEARCH_FIRST);
	args.push("-I");
	args.push(SEARCH_SECOND);
	args.push("-F");
	args.push(FRAMEWORKS);
	ChildResult result = aro_runner::run_child(tmem, args.array_view(), "", aro_runner::child_environment(tmem, {}));
	assert(result.spawned, "pp_probe failed to start for fixture");
	assert(result.exited, "pp_probe did not exit for fixture");
	return result;
}

fn void include_embed_filesystem_integration() @test
{
	List{String} args;
	args.init(tmem);
	args.push(aro_runner::absolute_from_cwd(tmem, PROBE));
	args.push("-fno-color-diagnostics");
	args.push(SOURCE);
	args.push("-E");
	args.push("-P");
	args.push("-std=c23");
	args.push("-I");
	args.push(SEARCH_FIRST);
	args.push("-I");
	args.push(SEARCH_SECOND);
	args.push("-F");
	args.push(FRAMEWORKS);
	ChildResult result = aro_runner::run_child(tmem, args.array_view(), "", aro_runner::child_environment(tmem, {}));
	assert(result.spawned, "pp_probe failed to start");
	assert(result.exited && result.exit_code == 0, "pp_probe failed during include/embed preprocessing");
	assert(result.stderr.len == 0, "include/embed fixture emitted unexpected diagnostics");

	// Check the macro-expanded include, recursive include guard, pragma once,
	// feature query, include_next search, and binary/empty embed result bytes.
	assert(result.stdout.contains("int once_value = 41;"), "macro-expanded include or pragma once failed");
	assert(result.stdout.contains("int recursive_value = 7;"), "guarded recursion failed");
	assert(result.stdout.contains("int query_result = 1;"), "__has_include result was incorrect");
	assert(result.stdout.contains("int missing_query_result = 0;"), "missing __has_include result was incorrect");
	assert(result.stdout.contains("int embed_query_result = 1;"), "__has_embed result was incorrect");
	assert(result.stdout.contains("int empty_embed_query_result = 2;"), "empty __has_embed result was incorrect");
	assert(result.stdout.contains("int missing_embed_query_result = 0;"), "missing __has_embed result was incorrect");
	assert(result.stdout.contains("int next_value = 53;"), "include_next did not select the second directory");
	assert(result.stdout.contains("int framework_value = 81;"), "framework include search failed");
	assert(result.stdout.contains("0,255,65"), "unlimited #embed did not emit the complete binary payload");
	assert(result.stdout.contains("9,0,255,8"), "binary #embed bytes or prefix/suffix were incorrect");
	// Zig emits prefix, if_empty and suffix for an empty payload: "1," + ",2".
	assert(result.stdout.contains("1,,2"), "zero-limit #embed did not preserve prefix/suffix");
	// if_empty(77) sits on the #embed line, so -P output keeps it on its own line.
	assert(result.stdout.contains("int empty_payload[] = {\n77\n};"), "empty #embed if_empty result was incorrect");
	assert(result.stdout.contains("const char* timestamp_value = \"") && !result.stdout.contains("__TIMESTAMP__"), "__TIMESTAMP__ was not expanded through the file service");
}

fn void include_failure_and_depth_integration() @test
{
	ChildResult missing = run_fixture("test/regression/preprocessor/fixtures/errors/missing.c", "-E");
	assert(missing.exit_code == 1, "missing include did not exit 1");
	assert(missing.stdout.len == 0, "missing include unexpectedly emitted preprocessed output");
	assert(missing.stderr.contains("'absent.h' not found"), "missing include diagnostic was absent");

	ChildResult cycle = run_fixture("test/regression/preprocessor/fixtures/errors/cycle.c", "-E");
	// The depth limit is an ordinary error that stops only the deepest include
	// (Zig StopPreprocessing); a release -E run still prints and exits 0.
	assert(cycle.exit_code == 0, "unguarded include cycle did not finish -E");
	assert(cycle.stderr.contains("#include nested too deeply"), "unguarded include cycle did not report maximum include depth");

	ChildResult depth = run_fixture("test/regression/preprocessor/fixtures/depth/main.c", "-E");
	assert(depth.exit_code == 0, "maximum-depth include chain did not finish -E");
	assert(depth.stderr.contains("#include nested too deeply"), "maximum-depth include chain diagnostic was absent");
}

fn void dependency_and_pragma_eof_integration() @test
{
	ChildResult deps = run_fixture(SOURCE, "-M");
	assert(deps.exit_code == 0, "dependency generation failed");
	assert(deps.stderr.len == 0, "dependency generation emitted unexpected diagnostics");
	assert(deps.stdout.contains("test/regression/preprocessor/fixtures/main.c"), "dependency output omitted the main source");
	assert(deps.stdout.contains("include/once.h"), "dependency output omitted included header");
	assert(deps.stdout.contains("include/query_only.h"), "dependency output omitted __has_include target");
	assert(deps.stdout.contains("search/first/next.h") && deps.stdout.contains("search/second/next.h"), "dependency output omitted include_next headers");
	assert(deps.stdout.contains("Frameworks/Sample.framework/Headers/Value.h"), "dependency output omitted framework header");
	assert(deps.stdout.contains("payload.bin"), "dependency output omitted the embedded payload");

	ChildResult pragma = run_fixture("test/regression/preprocessor/fixtures/pragma_eof.c", "-E");
	assert(pragma.exit_code == 0, "pragma-at-EOF preprocessing failed");
	assert(pragma.stderr.len == 0, "pragma-at-EOF emitted unexpected diagnostics");
	assert(pragma.stdout == "#pragma integration_eof\n", "pragma-at-EOF output bytes changed");
}
