// Source-derived lifecycle expectations from src/main.zig and
// src/aro/Driver.zig. This suite does not claim executable parity without a
// compatible Zig run. Inputs and outputs live in a temporary directory;
// include and child-process services are injected through Compilation.
module cli_tests;
import aro, aro::frontend::c::driver, aro::frontend::c::compilation, aro::frontend::c::diagnostics, aro::frontend::c::preprocessor, aro::toolchain::multilib;
import std::io, std::io::path, std::os::env, std::collections::list, std::core::dstring, std::core::mem::allocators, std::core::string;
import aro_runner;

struct FakeFile { String path; String contents; }
struct FakeFiles { FakeFile[8] entries; uint count; uint reads; }
struct FakeChild { uint calls; }

fn void FakeFiles.add(&self, String path, String contents)
{
	assert(self.count < 8, "too many fake files in CLI fixture");
	self.entries[self.count] = { .path = path, .contents = contents };
	self.count++;
}

fn bool fake_exists(void* ctx, String path)
{
	FakeFiles* files = (FakeFiles*)ctx;
	for (uint i = 0; i < files.count; i++) if (files.entries[i].path == path) return true;
	return false;
}

fn char[]? fake_read(void* ctx, Allocator a, String path, ulong limit)
{
	FakeFiles* files = (FakeFiles*)ctx;
	for (uint i = 0; i < files.count; i++)
	{
		FakeFile entry = files.entries[i];
		if (entry.path != path) continue;
		files.reads++;
		usz len = entry.contents.len;
		if (limit != ulong::max && (ulong)len > limit) len = (usz)limit;
		char* copy = alloc::malloc(a, (sz)len + 1);
		if (len) mem::copy(copy, entry.contents.ptr, (sz)len);
		copy[len] = 0;
		return copy[:len];
	}
	return preprocessor::FILE_NOT_FOUND~;
}

fn ulong? fake_mtime(void* ctx, String path) => 0;

fn ProcessResult fake_child(void* ctx, Allocator a, String[] argv)
{
	FakeChild* child = (FakeChild*)ctx;
	child.calls++;
	return { .started = true, .exited = true, .exit_code = 0 };
}

fn String scratch(String name)
{
	String root = env::get_var(tmem, "TEST_TMPDIR") ?? (String)path::temp_directory(tmem)!!;
	String dir = string::tformat("%s/aro cli %s", root, name);
	if (file::is_dir(dir)) (void)path::rmtree(path::tnew(dir)!!);
	(void)path::mkdir(dir, true)!!;
	return dir;
}

fn String join(String dir, String name) => string::tformat("%s/%s", dir, name);

fn String put(String dir, String name, String contents)
{
	String path = join(dir, name);
	file::save(path, contents)!!;
	return path;
}

fn String read(String path) => (String)file::load(tmem, path)!!;

fn int run_driver(String[] args, diagnostics::Diagnostics* d, FakeFiles* files = null, FakeChild* child = null, String executable_dir = "", String runfiles_dir = "")
{
	compilation::Compilation comp;
	comp.init(mem, null, d);
	if (files != null)
	{
		comp.include_files = { .ctx = (void*)files, .exists = &fake_exists, .read = &fake_read, .mtime = &fake_mtime };
	}
	if (child != null) comp.environment.process = { .ctx = (void*)child, .run = &fake_child };
	if (runfiles_dir.len)
	{
		comp.environment.runfiles_dir.set(runfiles_dir);
	}
	// Pin date/time macros so tests are independent of the machine clock.
	comp.environment.source_date_epoch.set("0");
	int result = driver::run(&comp, d, args, executable_dir);
	comp.free();
	return result;
}

fn void preprocess_output_markers_and_color_options() @test
{
	String dir = scratch("output markers");
	String input = put(dir, "input.c", "int answer = 42;\n");
	String plain = join(dir, "plain.i");
	diagnostics::Diagnostics d;
	d.init_list(mem);
	int status = run_driver({ "aro", "-E", "-P", "-nostdinc", "-nobuiltininc", "-fno-color-diagnostics", "-o", plain, input }, &d);
	assert(status == 0, "preprocessing without line markers failed: %d", status);
	assert(d.color == diagnostics::ColorOverride.FORCE_OFF, "-fno-color-diagnostics did not force color off");
	String plain_text = read(plain);
	assert(plain_text.contains("int answer = 42;"), "preprocessed output omitted source tokens");
	assert(!plain_text.contains("# 1 ") && !plain_text.contains("#line 1 "), "-P still emitted a line marker");
	d.free();

	String numbered = join(dir, "numbered.i");
	d.init_list(mem);
	status = run_driver({ "aro", "-E", "-nostdinc", "-nobuiltininc", "-o", numbered, input }, &d);
	assert(status == 0, "preprocessing with numeric line markers failed: %d", status);
	String numbered_text = read(numbered);
	assert(numbered_text.contains("# 1 ") && numbered_text.contains(input), "default line marker did not name the input");
	d.free();

	String line_style = join(dir, "line-style.i");
	d.init_list(mem);
	status = run_driver({ "aro", "-E", "-fuse-line-directives", "-fcolor-diagnostics", "-nostdinc", "-nobuiltininc", "-o", line_style, input }, &d);
	assert(status == 0, "preprocessing with #line markers failed: %d", status);
	assert(d.color == diagnostics::ColorOverride.FORCE_ON, "-fcolor-diagnostics did not force color on");
	String line_text = read(line_style);
	assert(line_text.contains("#line 1 ") && line_text.contains(input), "-fuse-line-directives did not emit #line markers");
	d.free();
}

fn void macro_dump_and_injected_implicit_sources() @test
{
	String dir = scratch("macro sources");
	String input = put(dir, "input.c", "int a = FROM_IMACROS;\nint b = FROM_INCLUDE;\nconst char* date = __DATE__;\n");
	FakeFiles files;
	files.add("/fake/macros.h", "#define FROM_IMACROS 23\n");
	files.add("/fake/implicit.h", "#define FROM_INCLUDE 19\n");
	String output = join(dir, "expanded.i");
	diagnostics::Diagnostics d;
	d.init_list(mem);
	int status = run_driver({ "aro", "-E", "-P", "-nostdinc", "-nobuiltininc", "-imacros", "/fake/macros.h", "-include", "/fake/implicit.h", "-DCLI_MACRO=7", "-o", output, input }, &d, &files);
	assert(status == 0, "preprocessing with implicit sources failed: %d", status);
	assert(files.reads >= 2, "driver did not read fake -imacros/-include sources");
	String expanded = read(output);
	assert(expanded.contains("int a = 23;") && expanded.contains("int b = 19;"), "implicit source macros were not applied");
	assert(expanded.contains("Jan  1 1970"), "SOURCE_DATE_EPOCH was not applied to __DATE__");
	d.free();

	String macros = join(dir, "macros.i");
	d.init_list(mem);
	status = run_driver({ "aro", "-E", "-P", "-dM", "-nostdinc", "-nobuiltininc", "-DCLI_MACRO=7", "-o", macros, input }, &d);
	assert(status == 0, "macro dump failed: %d", status);
	assert(read(macros).contains("#define CLI_MACRO 7"), "-dM omitted the command-line macro");
	d.free();

	String dump_input = put(dir, "dump.c", "int from_macro = CLI_MACRO;\n");
	for (uint i = 0; i < 2; i++)
	{
		bool full_definition = i == 0;
		String dump_path = join(dir, full_definition ? "dump-dD.i" : "dump-dN.i");
		String mode = full_definition ? "-dD" : "-dN";
		d.init_list(mem);
		status = run_driver({ "aro", "-E", "-P", mode, "-nostdinc", "-nobuiltininc", "-DCLI_MACRO=7", "-o", dump_path, dump_input }, &d);
		assert(status == 0, "%s macro dump failed: %d", mode, status);
		String dumped = read(dump_path);
		assert(dumped.contains("#define CLI_MACRO"), "%s omitted the command-line macro name", mode);
		if (full_definition) assert(dumped.contains("#define CLI_MACRO 7"), "-dD omitted the macro replacement");
		assert(dumped.contains("int from_macro = 7;"), "%s omitted the preprocessed source result", mode);
		d.free();
	}
}

fn void dependency_escaping_and_input_output_failures() @test
{
	String dir = scratch("dependency paths");
	String input = put(dir, "input file#one.c", "int value;\n");
	String deps_path = join(dir, "deps.d");
	diagnostics::Diagnostics d;
	d.init_list(mem);
	int status = run_driver({ "aro", "-M", "-MF", deps_path, "-nostdinc", "-nobuiltininc", input }, &d);
	assert(status == 0, "dependency generation failed: %d", status);
	String deps = read(deps_path);
	assert(deps.contains("input\\ file\\#one.o:"), "Make dependency target did not use the source stem and object suffix: %s", deps);
	assert(deps.contains("input\\ file\\#one.c"), "Make dependency path did not escape spaces and '#': %s", deps);
	d.free();

	String missing = join(dir, "missing input.c");
	d.init_list(mem);
	status = run_driver({ "aro", "-E", "-nostdinc", "-nobuiltininc", missing }, &d);
	assert(status != 0 && d.errors != 0, "missing input did not fail with a diagnostic");
	d.free();

	String failed_output = join(dir, "absent parent/output.i");
	d.init_list(mem);
	status = run_driver({ "aro", "-E", "-P", "-nostdinc", "-nobuiltininc", "-o", failed_output, input }, &d);
	assert(status != 0 && d.errors != 0, "output creation failure did not produce a diagnostic");
	assert(!file::exists(failed_output), "failed output open created an output file");
	d.free();
}

fn String cli_diag_text(diagnostics::Diagnostics* d)
{
	DString text;
	text.tinit();
	foreach (i, message : d.messages)
	{
		if (i > 0) text.appendf("; ");
		text.appendf("%s", message.text);
	}
	return text.str_view();
}

fn bool diagnostics_contain(diagnostics::Diagnostics* d, String text)
{
	foreach (message : d.messages) if (message.text.contains(text)) return true;
	return false;
}

fn void preprocessing_errors_return_failure_and_preserve_output() @test
{
	String dir = scratch("preprocessing error");
	String input = put(dir, "input.c", "#error preprocessing-error-probe\nint answer = 42;\n");
	String output = join(dir, "output.i");
	diagnostics::Diagnostics d;
	d.init_list(mem);
	int status = run_driver({ "aro", "-E", "-P", "-nostdinc", "-nobuiltininc", "-o", output, input }, &d);
	assert(status == 1, "preprocessing error did not return exit status 1: %d", status);
	assert(d.errors != 0 && diagnostics_contain(&d, "preprocessing-error-probe"),
		"preprocessing error diagnostic was not preserved: %s", cli_diag_text(&d));
	assert(file::exists(output), "preprocessing error discarded the output file");
	assert(read(output).contains("int answer = 42;"), "preprocessing error discarded valid preprocessed output");
	d.free();
}

fn void multiple_inputs_reset_per_source_diagnostics() @test
{
	String dir = scratch("multiple inputs");
	String malformed = put(dir, "malformed.c", "int value = ;\n");
	String valid = put(dir, "valid.c", "#warning second translation unit\n");
	diagnostics::Diagnostics d;
	d.init_list(mem);
	int status = run_driver({ "aro", "-fsyntax-only", "-nostdinc", "-nobuiltininc", "-fno-color-diagnostics", malformed, valid }, &d);
	assert(status != 0, "malformed first translation unit unexpectedly succeeded");
	assert(diagnostics_contain(&d, "second translation unit"), "driver did not process the valid second translation unit after the first error");
	assert(d.errors != 0 && d.warnings != 0, "expected the first-unit error and second-unit warning");
	d.free();
}

fn void stdin_dash_reads_the_injected_file_stream() @test
{
	String dir = scratch("stdin input");
	String input = put(dir, "stdin.c", "int from_stdin = 31;\n");
	String output = join(dir, "stdin.i");
	File? stdin_opt = file::open(input, "rb");
	if (catch file_error = stdin_opt) unreachable("could not open temporary stdin file: %s", file_error);
	File stdin_stream = stdin_opt;
	defer (void)stdin_stream.close();
	diagnostics::Diagnostics d;
	d.init_list(mem);
	compilation::Compilation comp;
	comp.init(mem, null, &d);
	comp.environment.source_date_epoch.set("0");
	int status = driver::run_with_stdin(&comp, &d,
		{ "aro", "-E", "-P", "-nostdinc", "-nobuiltininc", "-o", output, "-" }, "", &stdin_stream);
	assert(status == 0, "driver could not preprocess stdin: %d", status);
	assert(read(output).contains("int from_stdin = 31;"), "driver did not read the injected stdin stream");
	comp.free();
	d.free();
}

fn void backend_data_only_modes_and_unsupported_cases() @test
{
	String dir = scratch("backend data only");
	String input = put(dir, "data.c", "int value = 42;\n");
	for (uint i = 0; i < 3; i++)
	{
		String output = join(dir, string::tformat("backend-%d.out", i));
		FakeChild child;
		diagnostics::Diagnostics d;
		d.init_list(mem);
		String mode = i == 0 ? "-S" : i == 1 ? "-c" : "";
		List{String} argv;
		argv.init(tmem);
		argv.push("aro");
		argv.push("-O0");
		// Counts the injected assembler child: pin the system assembler path.
		argv.push("-fno-integrated-as");
		if (mode.len) argv.push(mode);
		argv.push("--target=x86_64-linux-gnu");
		argv.push("-nostdinc");
		argv.push("-nobuiltininc");
		argv.push("-nostdlib");
		argv.push("-o");
		argv.push(output);
		argv.push(input);
		int status = run_driver(argv.array_view(), &d, null, &child);
		assert(status == 0 && d.errors == 0, "data-only backend mode %d failed; diagnostics: %s", i, cli_diag_text(&d));
		if (i == 0)
		{
			assert(file::exists(output), "-S did not retain its requested output");
			assert(child.calls == 0, "-S unexpectedly invoked a child process; diagnostics: %s", cli_diag_text(&d));
		}
		else if (i == 1)
		{
			assert(child.calls == 1, "-c did not invoke the injected assembler once; diagnostics: %s", cli_diag_text(&d));
		}
		else
		{
			assert(child.calls == 2, "link mode did not invoke assembler and linker; diagnostics: %s", cli_diag_text(&d));
		}
		d.free();
	}

	String function_input = put(dir, "function.c", "int answer(void) { return 42; }\n");
	FakeChild function_child;
	diagnostics::Diagnostics function_d;
	function_d.init_list(mem);
	// Unlike Zig's data-only -O0 assembly stub, -O0 uses the Ir backend with no passes.
	String function_output = join(dir, "function.s");
	int function_status = run_driver({ "aro", "-O0", "-S", "-nostdinc", "-nobuiltininc", "-o", function_output, function_input }, &function_d, null, &function_child);
	assert(function_status == 0 && function_d.errors == 0,
		"-O0 function definition failed; diagnostics: %s", cli_diag_text(&function_d));
	assert(read(function_output).contains("answer"), "-O0 -S output does not define the function");
	assert(function_child.calls == 0, "-S unexpectedly invoked a child process; diagnostics: %s", cli_diag_text(&function_d));
	function_d.free();

	FakeChild target_child;
	diagnostics::Diagnostics target_d;
	target_d.init_list(mem);
	int target_status = run_driver({ "aro", "-O0", "-S", "--target=aarch64-linux-gnu", "-nostdinc", "-nobuiltininc", input }, &target_d, null, &target_child);
	assert(target_status != 0 && diagnostics_contain(&target_d, "unsupported target"),
		"unsupported target did not preserve the source-derived target diagnostic; diagnostics: %s", cli_diag_text(&target_d));
	assert(target_child.calls == 0, "unsupported target invoked an assembler; diagnostics: %s", cli_diag_text(&target_d));
	target_d.free();
}

fn void toolchain_fault_messages_match_zig() @test
{
	assert(driver::toolchain_fault_message(multilib::TOO_MANY_MULTILIBS) == "found more than one multilib with the same priority");
}

fn void builtin_headers_are_discovered_from_runfiles() @test
{
	String test_srcdir = env::get_var(tmem, "TEST_SRCDIR") ?? "";
	assert(test_srcdir.len, "TEST_SRCDIR is required for runfiles header discovery");
	String dir = scratch("runfiles headers");
	String input = put(dir, "stddef.c", "#include <stddef.h>\nsize_t value;\n");
	String output = join(dir, "stddef.i");
	diagnostics::Diagnostics d;
	d.init_list(mem);
	int status = run_driver({ "aro", "-E", "-P", "-nostdlibinc", "-fno-color-diagnostics", "-o", output, input }, &d, null, null, "", test_srcdir);
	assert(status == 0, "driver could not resolve builtin headers from TEST_SRCDIR runfiles: %d", status);
	assert(read(output).contains("size_t value;"), "runfiles-discovered stddef.h did not preprocess the input");
	d.free();
}

fn String decode_manifest_field(String field)
{
	DString decoded;
	decoded.tinit();
	for (usz i = 0; i < field.len; i++)
	{
		if (field[i] == '\\' && i + 1 < field.len)
		{
			i++;
			switch (field[i])
			{
				case 's': decoded.append(' ');
				case 'b': decoded.append('\\');
				case 'n': decoded.append('\n');
				default:
					decoded.append('\\');
					decoded.append(field[i]);
			}
		}
		else
		{
			decoded.append(field[i]);
		}
	}
	return decoded.str_view();
}

fn String? production_executable_from_manifest(String manifest_path, String workspace, String suffix)
{
	char[]? manifest_data = file::load(tmem, manifest_path);
	if (catch manifest_data) return NOT_FOUND~;
	String contents = (String)manifest_data;
	String expected = string::tformat("%s/aro_c3%s", workspace, suffix);
	usz start = 0;
	while (start < contents.len)
	{
		usz end = start;
		while (end < contents.len && contents[end] != '\n') end++;
		usz line_end = end;
		if (line_end > start && contents[line_end - 1] == '\r') line_end--;
		String line = line_end > start ? contents[start..line_end - 1] : "";
		if (line.len && line[0] == '\\') line = line[1..];
		usz separator = 0;
		while (separator < line.len && line[separator] != ' ') separator++;
		if (separator < line.len)
		{
			String key = decode_manifest_field(line[0..separator - 1]);
			if (key == expected)
			{
				String path = decode_manifest_field(line[separator + 1..]);
				return aro_runner::absolute_from_cwd(tmem, path);
			}
		}
		start = end + 1;
	}
	return NOT_FOUND~;
}

fn String production_executable()
{
	String workspace = env::get_var(tmem, "TEST_WORKSPACE") ?? "";
	String root = env::get_var(tmem, "TEST_SRCDIR") ?? "";
	String suffix = env::WIN32 ? ".exe" : "";
	assert(workspace.len, "TEST_WORKSPACE is required to resolve aro_c3 from runfiles");
	if (root.len)
	{
		String candidate = aro_runner::join_path(tmem, aro_runner::join_path(tmem, root, workspace), string::tformat("aro_c3%s", suffix));
		if (file::is_file(candidate)) return candidate;
	}
	if (try manifest = env::get_var(tmem, "RUNFILES_MANIFEST_FILE"))
	{
		if (try candidate = production_executable_from_manifest(manifest, workspace, suffix)) return candidate;
	}
	unreachable("production aro_c3 binary was not found in runfiles tree or RUNFILES_MANIFEST_FILE");
	return "";
}

fn ChildResult run_production_cli(String[] args, EnvPair[] overrides = {}, bool omit_runfiles = false)
{
	List{String} argv;
	argv.init(tmem);
	argv.push(production_executable());
	foreach (arg : args) argv.push(arg);
	String[] environment = aro_runner::child_environment(tmem, overrides);
	if (omit_runfiles)
	{
		List{String} filtered;
		filtered.init(tmem);
		foreach (entry : environment) if (!entry.starts_with("RUNFILES_DIR=")) filtered.push(entry);
		environment = filtered.array_view();
	}
	ChildResult result = aro_runner::run_child(tmem, argv.array_view(), "", environment);
	assert(result.spawned && result.exited, "aro_c3 failed to start or exit");
	return result;
}

fn void production_main_uses_runfiles_environment_for_builtin_headers() @test
{
	String dir = scratch("production runfiles");
	String input = put(dir, "stddef.c", "#include <stddef.h>\nsize_t value;\n");
	String[] args = { "-E", "-P", "-nostdlibinc", "-fno-color-diagnostics", input };
	String runfiles = env::get_var(tmem, "TEST_SRCDIR") ?? "";
	assert(runfiles.len, "TEST_SRCDIR is required for the production CLI runfiles test");
	ChildResult explicit_runfiles = run_production_cli(args, { { .key = "RUNFILES_DIR", .value = runfiles } });
	assert(explicit_runfiles.exit_code == 0, "aro_c3 failed to use RUNFILES_DIR: %s", explicit_runfiles.stderr);
	assert(explicit_runfiles.stdout.contains("size_t value;"), "aro_c3 did not find stddef.h through RUNFILES_DIR");

	ChildResult fallback = run_production_cli(args, {}, true);
	assert(fallback.exit_code == 0, "aro_c3 failed to use TEST_SRCDIR fallback: %s", fallback.stderr);
	assert(fallback.stdout.contains("size_t value;"), "aro_c3 did not find stddef.h through TEST_SRCDIR");
}

fn void production_cli_renders_color_overrides_to_stderr() @test
{
	String dir = scratch("diagnostic color");
	String input = put(dir, "error.c", "#error color-probe\n");
	String[] force_on_args = { "-E", "-fcolor-diagnostics", "-nostdinc", "-nobuiltininc", input };
	ChildResult force_on = run_production_cli(force_on_args);
	assert(force_on.exit_code == 1, "#error did not fail with forced color");
	assert(force_on.stderr.contains("\x1b["), "-fcolor-diagnostics did not render ANSI color on stderr: %s", force_on.stderr);

	String[] force_off_args = { "-E", "-fno-color-diagnostics", "-nostdinc", "-nobuiltininc", input };
	ChildResult force_off = run_production_cli(force_off_args);
	assert(force_off.exit_code == 1, "#error did not fail with color disabled");
	assert(!force_off.stderr.contains("\x1b["), "-fno-color-diagnostics emitted ANSI color on stderr: %s", force_off.stderr);
}

fn void production_main_copies_source_date_epoch_environment() @test
{
	String dir = scratch("production date macro");
	String input = put(dir, "date.c", "const char* date = __DATE__;\n");
	String[] args = { "-E", "-P", "-nostdinc", "-nobuiltininc", input };
	ChildResult result = run_production_cli(args, { { .key = "SOURCE_DATE_EPOCH", .value = "0" } });
	assert(result.exit_code == 0, "aro_c3 failed while expanding __DATE__: %s", result.stderr);
	assert(result.stdout.contains("Jan  1 1970"), "aro_c3 did not pass SOURCE_DATE_EPOCH into compilation: %s", result.stdout);
}

fn void production_preprocessor_output_dash_uses_stdout() @test
{
	String dir = scratch("stdout output");
	String input = put(dir, "stdout.c", "int output_to_stdout = 11;\n");
	String[] args = { "-E", "-P", "-nostdinc", "-nobuiltininc", "-o", "-", input };
	ChildResult result = run_production_cli(args);
	assert(result.exit_code == 0, "aro_c3 failed while writing preprocessor output to stdout: %s", result.stderr);
	assert(result.stdout.contains("int output_to_stdout = 11;"), "-E -o - did not write preprocessor output to stdout: %s", result.stdout);
}

fn void production_verbose_ast_uses_stdout() @test
{
	String dir = scratch("verbose ast");
	String input = put(dir, "ast.c", "int ast_output = 13;\n");
	String[] args = { "-fsyntax-only", "--verbose-ast", "-nostdinc", "-nobuiltininc", input };
	ChildResult result = run_production_cli(args);
	assert(result.exit_code == 0, "aro_c3 failed while dumping a valid AST: %s", result.stderr);
	assert(result.stdout.contains("ast_output"), "--verbose-ast did not write the parsed tree to stdout: %s", result.stdout);
	assert(result.stderr.len == 0, "valid --verbose-ast input emitted unexpected diagnostics: %s", result.stderr);
}

fn uint count_occurrences(String text, String needle)
{
	if (needle.len == 0 || needle.len > text.len) return 0;
	uint count = 0;
	for (usz i = 0; i + needle.len <= text.len; i++)
	{
		if (text[i:needle.len] == needle) count++;
	}
	return count;
}

fn void production_whole_program_ir_renames_static_helpers() @test
{
	String dir = scratch("whole program merged IR");
	String first = put(dir, "a.c",
		"static int helper(void) { return 1; }\nint shared(void);\nint a_entry(void) { return helper() + shared(); }\n");
	String second = put(dir, "b.c",
		"static int helper(void) { return 2; }\nint shared(void) { return helper(); }\n");
	String output = join(dir, "out.o");
	String[] args = { "-fwhole-program", "-c", "--verbose-ir", "-nostdinc", "-nobuiltininc", "-o", output, first, second };
	ChildResult result = run_production_cli(args);
	assert(result.stdout.contains("i32 @helper.tu0(") && result.stdout.contains("i32 @helper.tu1("),
		"merged IR did not rename both TU-local helpers: %s", result.stdout);
	assert(result.stdout.contains("i32 @a_entry(") && result.stdout.contains("i32 @shared("),
		"merged IR omitted an external function definition: %s", result.stdout);
	assert(count_occurrences(result.stdout, "i32 @shared(") == 1,
		"shared external definition did not appear exactly once: %s", result.stdout);
	assert(!result.stdout.contains("i32 @helper("), "whole-program IR retained a bare static helper definition: %s", result.stdout);
	assert(count_occurrences(result.stdout, ") {\n") == 4,
		"whole-program IR did not emit exactly four function definitions: %s", result.stdout);
	sz a_entry = result.stdout.index_of("i32 @a_entry(")!!;
	sz shared = result.stdout.index_of("i32 @shared(")!!;
	assert(a_entry < shared, "merged IR did not preserve input order: %s", result.stdout);
}

fn void production_whole_program_duplicate_external_definitions_do_not_dump_ir() @test
{
	String dir = scratch("whole program duplicate definitions");
	String first = put(dir, "a.c", "int shared(void) { return 0; }\n");
	String second = put(dir, "b.c", "int shared(void) { return 0; }\n");
	String[] args = { "-fwhole-program", "-c", "--verbose-ir", "-nostdinc", "-nobuiltininc", first, second };
	ChildResult result = run_production_cli(args);
	assert(result.exit_code == 1 && result.stderr.contains("multiple definitions of 'shared'"),
		"duplicate external definitions were not rejected: %s", result.stderr);
	assert(result.stderr.contains(first) && result.stderr.contains(second),
		"duplicate definition diagnostic omitted an input path: %s", result.stderr);
	assert(result.stdout.len == 0, "duplicate external definitions dumped partial IR: %s", result.stdout);
}

fn void production_whole_program_preserves_static_linkage_across_redeclaration() @test
{
	String dir = scratch("whole program static redeclaration");
	String first = put(dir, "first.c",
		"static int h(void);\nint h(void) { return 0; }\n");
	String second = put(dir, "second.c", "static int h(void) { return 1; }\n");
	String[] args = { "-fwhole-program", "-c", "--verbose-ir", "-nostdinc", "-nobuiltininc", first, second };
	ChildResult result = run_production_cli(args);
	assert(result.stdout.contains("i32 @h.tu0(") && result.stdout.contains("i32 @h.tu1("),
		"static function redeclaration did not retain TU-local linkage: %s", result.stdout);
}

fn void production_whole_program_merges_external_global_definitions() @test
{
	String dir = scratch("whole program global merge");
	String first = put(dir, "first.c", "int shared; extern int initialized;\n");
	String second = put(dir, "second.c", "int shared; int initialized = 23;\n");
	String output = join(dir, "out.o");
	String[] args = { "-fwhole-program", "-c", "--verbose-ir", "-nostdinc", "-nobuiltininc", "-o", output, first, second };
	ChildResult result = run_production_cli(args);
	assert(result.exit_code == 0, "compatible external global declarations failed to merge: %s", result.stderr);
	assert(count_occurrences(result.stdout, "global @shared size") == 1,
		"tentative definitions from two TUs were not merged into one global: %s", result.stdout);
	assert(result.stdout.contains("global @shared size 4 align 4 bss tentative"),
		"the merged tentative global was not zero-initialized: %s", result.stdout);
	assert(count_occurrences(result.stdout, "global @initialized size") == 1,
		"the initialized definition did not replace its extern declaration: %s", result.stdout);
	assert(result.stdout.contains("global @initialized size 4 align 4 data {\n    bytes \"\\x17\\x00\\x00\\x00\""),
		"the initialized global was not retained in merged IR: %s", result.stdout);
	assert(!result.stdout.contains("extern @initialized"),
		"the merged IR retained an extern declaration alongside its definition: %s", result.stdout);
}

fn void production_whole_program_rejects_duplicate_initialized_globals() @test
{
	String dir = scratch("whole program duplicate globals");
	String first = put(dir, "first.c", "int shared = 1;\n");
	String second = put(dir, "second.c", "int shared = 2;\n");
	String[] args = { "-fwhole-program", "-c", "--verbose-ir", "-nostdinc", "-nobuiltininc", first, second };
	ChildResult result = run_production_cli(args);
	assert(result.exit_code == 1 && result.stderr.contains("multiple definitions of 'shared'"),
		"duplicate initialized globals were not rejected: %s", result.stderr);
	assert(result.stderr.contains(first) && result.stderr.contains(second),
		"duplicate global diagnostic omitted an input path: %s", result.stderr);
	assert(result.stdout.len == 0, "duplicate initialized globals dumped partial IR: %s", result.stdout);
}

fn void production_optimized_ir_without_whole_program_keeps_per_translation_unit_dumps() @test
{
	String dir = scratch("optimized per translation unit IR");
	String first = put(dir, "a.c",
		"static int helper(void) { return 1; }\nint shared(void);\nint a_entry(void) { return helper() + shared(); }\n");
	String second = put(dir, "b.c",
		"static int helper(void) { return 2; }\nint shared(void) { return helper(); }\n");
	String[] args = { "-O1", "-c", "--verbose-ir", "-nostdinc", "-nobuiltininc", first, second };
	ChildResult result = run_production_cli(args);
	assert(count_occurrences(result.stdout, "i32 @helper(") == 2,
		"optimized mode did not emit two per-translation-unit definitions with bare helper names: %s", result.stdout);
	assert(result.stdout.contains("i32 @shared(") && !result.stdout.contains("@helper.tu"),
		"optimized mode changed ordinary per-TU symbol names: %s", result.stdout);
}

fn void production_whole_program_compile_only_keeps_external_and_removes_dead_static() @test
{
	String dir = scratch("whole program compile-only DCE policy");
	String main_input = put(dir, "a.c", "int main(void) { return 0; }\n");
	String exports_input = put(dir, "b.c",
		"int exported(void) { return 11; }\nstatic int dead_static(void) { return 23; }\n");
	String output = join(dir, "out.o");
	String[] args = { "-O1", "-fwhole-program", "-c", "--verbose-ir", "-nostdinc", "-nobuiltininc",
		"-o", output, main_input, exports_input };
	ChildResult result = run_production_cli(args);
	assert(result.exit_code == 0, "whole-program compile-only IR failed: %s", result.stderr);
	assert(result.stdout.contains("i32 @exported("),
		"whole-program compile-only IR removed an external definition: %s", result.stdout);
	assert(!result.stdout.contains("dead_static"),
		"whole-program compile-only IR retained an unreachable static definition: %s", result.stdout);
}

fn void production_whole_program_link_with_user_object_keeps_external_definitions() @test
{
	String dir = scratch("whole program user-object DCE policy");
	String helper_source = put(dir, "helper.c", "int helper_from_object(void) { return 0; }\n");
	String helper_object = join(dir, "helper.o");
	String[] helper_args = { "-c", "-nostdinc", "-nobuiltininc", "-o", helper_object, helper_source };
	ChildResult helper_result = run_production_cli(helper_args);
	assert(helper_result.exit_code == 0, "failed to create the user-object fixture: %s", helper_result.stderr);

	String input = put(dir, "input.c",
		"int main(void) { return 0; }\nint exported(void) { return 11; }\nstatic int dead_static(void) { return 23; }\n");
	String output = join(dir, "linked.o");
	String[] args = { "-O1", "-fwhole-program", "-r", "-nostdlib", "--verbose-ir", "-nostdinc", "-nobuiltininc",
		"-o", output, input, helper_object };
	ChildResult result = run_production_cli(args);
	assert(result.exit_code == 0, "whole-program link with a user object failed: %s", result.stderr);
	assert(result.stdout.contains("i32 @exported("),
		"link-mode IR removed an external definition needed by user-object linking: %s", result.stdout);
	assert(!result.stdout.contains("dead_static"),
		"link-mode IR retained an unreachable static definition: %s", result.stdout);
}
