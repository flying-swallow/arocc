// Source-derived backend CLI lifecycle coverage. The injected child records
// argv as separate strings; these checks do not claim executable parity.
module backend_cli_regression;
import aro, aro::driver, aro::compilation, aro::diagnostics;
import aro::driver_exec;
import std::io, std::io::path, std::os::env, std::core::mem::allocators, std::core::string, std::core::dstring;

enum ChildFailure : char { NONE, SPAWN, WAIT, EXIT, SIGNAL }

struct BackendChild
{
	uint calls;
	uint stored_args;
	uint[8] starts;
	uint[8] counts;
	String[128] args;
	uint fail_call;
	ChildFailure failure;
	bool write_assembler_output;
	String observed_link_object;
	bool observed_link_object_exists;
}

extern fn CInt chmod(ZString path, uint mode) @feat(POSIX);

fn ProcessResult backend_fake_child(void* ctx, Allocator a, String[] argv)
{
	BackendChild* child = (BackendChild*)ctx;
	uint call_index = child.calls;
	assert(call_index < child.starts.len, "too many fake backend process calls");
	child.starts[call_index] = child.stored_args;
	child.counts[call_index] = (uint)argv.len;
	foreach (arg : argv)
	{
		assert(child.stored_args < child.args.len, "fake backend argv capture is full");
		child.args[child.stored_args++] = string::tformat("%s", arg);
	}
	child.calls++;

	bool fail = child.fail_call == child.calls;
	ProcessResult result = { .started = true, .exited = true, .exit_code = 0 };
	if (fail)
	{
		switch (child.failure)
		{
			case SPAWN:
				result.started = false;
				result.spawn_error = io::FILE_NOT_FOUND;
			case WAIT: result.exited = false;
			case EXIT: result.exit_code = 7;
			case SIGNAL: result.exit_code = -9;
			case NONE: break;
		}
	}

	bool assembler_call = argv.len == 4 && argv[2] == "-o" && argv[0].ends_with("/as");
	if (result.started && !assembler_call)
	{
		foreach (arg : argv)
		{
			if (!arg.ends_with(".o") || !file::exists(arg)) continue;
			child.observed_link_object = string::tformat("%s", arg);
			child.observed_link_object_exists = true;
			break;
		}
	}
	if (child.write_assembler_output && result.started && assembler_call)
	{
		if (catch ignored = file::save(argv[3], "fake object")) { (void)ignored; }
	}
	else if (result.started && result.exited && result.exit_code == 0)
	{
		for (uint i = 0; (usz)i + 1 < argv.len; i++)
		{
			if (argv[i] != "-o") continue;
			if (catch ignored = file::save(argv[i + 1], "fake linked output")) { (void)ignored; }
			break;
		}
	}
	(void)a;
	return result;
}

fn String backend_scratch(String name)
{
	String root = env::get_var(tmem, "TEST_TMPDIR") ?? (String)path::temp_directory(tmem)!!;
	String dir = string::tformat("%s/aro backend cli %s", root, name);
	if (file::is_dir(dir)) (void)path::rmtree(path::tnew(dir)!!);
	(void)path::mkdir(dir, true)!!;
	return dir;
}

fn String backend_join(String dir, String name) => string::tformat("%s/%s", dir, name);

fn String backend_put(String dir, String name, String contents)
{
	String output = backend_join(dir, name);
	file::save(output, contents)!!;
	return output;
}

fn bool backend_diag_contains(diagnostics::Diagnostics* d, String text)
{
	foreach (message : d.messages) if (message.text.contains(text)) return true;
	return false;
}

fn String backend_first_diag_text(diagnostics::Diagnostics* d)
{
	return d.messages.len() == 0 ? "<none>" : d.messages[0].text;
}

fn String backend_diag_text(diagnostics::Diagnostics* d)
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

fn uint backend_diag_count(diagnostics::Diagnostics* d, diagnostics::MessageKind kind, String text)
{
	uint count = 0;
	foreach (message : d.messages) if (message.kind == kind && message.text.contains(text)) count++;
	return count;
}

<* Index of the first message of `kind` whose text contains `text`; -1 when absent. *>
fn int backend_diag_index(diagnostics::Diagnostics* d, diagnostics::MessageKind kind, String text)
{
	int index = 0;
	foreach (message : d.messages)
	{
		if (message.kind == kind && message.text.contains(text)) return index;
		index++;
	}
	return -1;
}

fn String[] backend_argv(BackendChild* child, uint call)
{
	assert(call < child.calls, "requested an uncaptured fake backend call");
	uint start = child.starts[call];
	return child.args[start : child.counts[call]];
}

fn uint backend_linker_calls(BackendChild* child)
{
	uint count = 0;
	for (uint call = 0; call < child.calls; call++)
	{
		String[] argv = backend_argv(child, call);
		if (argv.len > 0 && !argv[0].ends_with("/as")) count++;
	}
	return count;
}

fn bool argv_has(String[] argv, String expected)
{
	foreach (arg : argv) if (arg == expected) return true;
	return false;
}

fn bool argv_has_sequence(String[] argv, String[] expected)
{
	if (expected.len > argv.len) return false;
	for (usz i = 0; i + expected.len <= argv.len; i++)
	{
		bool matches = true;
		for (usz j = 0; j < expected.len; j++)
		{
			if (argv[i + j] != expected[j]) { matches = false; break; }
		}
		if (matches) return true;
	}
	return false;
}

fn String argv_value_after(String[] argv, String option)
{
	for (uint i = 0; (usz)i + 1 < argv.len; i++) if (argv[i] == option) return argv[i + 1];
	return "";
}

fn int run_backend_driver(String[] args, diagnostics::Diagnostics* d, BackendChild* child, String path_value)
{
	compilation::Compilation comp;
	comp.init(mem, null, d);
	comp.environment.process = { .ctx = (void*)child, .run = &backend_fake_child };
	comp.environment.has_path = true;
	comp.environment.path = path_value;
	comp.environment.has_source_date_epoch = true;
	comp.environment.source_date_epoch = "0";
	int status = driver::run(&comp, d, args, "");
	comp.free();
	return status;
}

fn int run_backend_driver_host(String[] args, diagnostics::Diagnostics* d, String path_value)
{
	compilation::Compilation comp;
	comp.init(mem, null, d);
	// Leave the process service unset so linker execution uses driver_exec.run_host.
	comp.environment.process = {};
	comp.environment.has_path = true;
	comp.environment.path = path_value;
	comp.environment.has_source_date_epoch = true;
	comp.environment.source_date_epoch = "0";
	int status = driver::run(&comp, d, args, "");
	comp.free();
	return status;
}

fn String backend_tool_path(String dir)
{
	String tool_dir = backend_join(dir, "tools with spaces");
	(void)path::mkdir(tool_dir, true)!!;
	String assembler = backend_join(tool_dir, "as");
	file::save(assembler, "fake executable marker")!!;
	assert(chmod(assembler.zstr_tcopy(), 0o755) == 0, "could not mark fake assembler executable");
	return string::tformat("%s:/usr/bin:/bin", tool_dir);
}

fn void backend_argv_spaces_multiple_inputs_and_temp_cleanup() @test
{
	String dir = backend_scratch("argv spaces");
	String path_value = backend_tool_path(dir);
	String first = backend_put(dir, "first source.c", "int first = 1;\n");
	String second = backend_put(dir, "second source.c", "int second = 2;\n");
	String user_object = backend_put(dir, "user object.o", "user object contents");
	String output = backend_join(dir, "linked output");
	BackendChild child = { .write_assembler_output = true };
	diagnostics::Diagnostics d;
	d.init_list(mem);
	int status = run_backend_driver({ "aro", "-O0", "--target=x86_64-linux-gnu", "--verbose-linker-args", "-nostdinc", "-nobuiltininc", "-nostdlib", "-o", output, first, second, user_object }, &d, &child, path_value);
	assert(status == 0 && d.errors == 0, "data-only link flow with multiple inputs failed; diagnostics: %s", backend_diag_text(&d));
	assert(child.calls == 3, "two source inputs should invoke two assemblers and one linker, got %d; diagnostics: %s", child.calls, backend_diag_text(&d));

	String[] assembler_argv = backend_argv(&child, 0);
	assert(assembler_argv[0].contains("tools with spaces/as"), "assembler executable path lost its spaces: %s", assembler_argv[0]);
	assert(assembler_argv.len == 4 && assembler_argv[2] == "-o", "assembler argv was not kept as structured arguments");
	assert(assembler_argv[1].ends_with(".s"), "assembler input was not a temporary assembly path: %s", assembler_argv[1]);
	String first_assembly = assembler_argv[1];
	String first_object = assembler_argv[3];
	String[] second_assembler_argv = backend_argv(&child, 1);
	String second_assembly = second_assembler_argv[1];
	String second_object = second_assembler_argv[3];
	assert(second_assembler_argv[0] == assembler_argv[0], "assembler executable changed between inputs");

	String[] linker_argv = backend_argv(&child, 2);
	assert(argv_value_after(linker_argv, "-o") == output, "linker output path was not one intact argv item");
	assert(argv_has(linker_argv, user_object), "linker argv omitted the user object path containing spaces");
	assert(file::exists(user_object), "temporary cleanup deleted the user object input");
	assert(!file::exists(first_assembly) && !file::exists(second_assembly), "temporary assembly files survived successful linking");
	assert(!file::exists(first_object) && !file::exists(second_object), "temporary object outputs survived successful linking");
	assert(file::exists(output), "fake linker did not observe and materialize its output path");
	d.free();
}

fn void optimized_integrated_as_writes_objects_without_subprocesses() @test
{
	String dir = backend_scratch("optimized prototypes");
	String path_value = backend_tool_path(dir);
	String prototype = backend_put(dir, "prototype.c", "int f(void);\n");
	String prototype_output = backend_join(dir, "prototype.o");
	BackendChild prototype_child;
	diagnostics::Diagnostics prototype_d;
	prototype_d.init_list(mem);
	int prototype_status = run_backend_driver({ "aro", "-O1", "-fintegrated-as", "--target=x86_64-linux-gnu", "-c", "-nostdinc", "-nobuiltininc", "-o", prototype_output, prototype }, &prototype_d, &prototype_child, path_value);
	assert(prototype_status == 0 && prototype_d.errors == 0,
		"prototype-only -O1 -fintegrated-as compile failed; diagnostics: %s", backend_diag_text(&prototype_d));
	assert(file::exists(prototype_output), "prototype-only -O1 compile did not write an object");
	String prototype_bytes = (String)file::load(mem, prototype_output)!!;
	assert(prototype_bytes.starts_with("\x7fELF"), "prototype-only -O1 output is not an ELF object");
	alloc::free(mem, prototype_bytes.ptr);
	assert(prototype_child.calls == 0, "prototype-only -O1 -fintegrated-as compile spawned a subprocess");
	prototype_d.free();

	String definition = backend_put(dir, "definition.c", "int f(void) { return 0; }\n");
	String definition_output = backend_join(dir, "definition.o");
	BackendChild definition_child;
	diagnostics::Diagnostics definition_d;
	definition_d.init_list(mem);
	int definition_status = run_backend_driver({ "aro", "-O1", "-fintegrated-as", "--target=x86_64-linux-gnu", "-c", "-nostdinc", "-nobuiltininc", "-o", definition_output, definition }, &definition_d, &definition_child, path_value);
	assert(definition_status == 0 && definition_d.errors == 0,
		"function definition -O1 -fintegrated-as compile failed; diagnostics: %s", backend_diag_text(&definition_d));
	assert(file::exists(definition_output), "function definition -O1 -fintegrated-as compile did not write an object");
	String definition_bytes = (String)file::load(mem, definition_output)!!;
	assert(definition_bytes.starts_with("\x7fELF"), "function definition -O1 -fintegrated-as output is not an ELF object");
	alloc::free(mem, definition_bytes.ptr);
	assert(definition_child.calls == 0, "function definition -O1 -fintegrated-as compile spawned a subprocess");
	definition_d.free();
}

fn void optimized_link_mode_uses_and_cleans_temporary_object() @test
{
	String dir = backend_scratch("optimized link object");
	String path_value = backend_tool_path(dir);
	String prototype = backend_put(dir, "prototype.c", "int f(void);\n");
	String output = backend_join(dir, "linked output");
	BackendChild child;
	diagnostics::Diagnostics d;
	d.init_list(mem);
	int status = run_backend_driver({ "aro", "-O1", "-fintegrated-as", "--target=x86_64-linux-gnu", "-nostdinc", "-nobuiltininc", "-nostdlib", "-o", output, prototype }, &d, &child, path_value);
	assert(status == 0 && d.errors == 0,
		"prototype-only -O1 -fintegrated-as link failed; diagnostics: %s", backend_diag_text(&d));
	assert(child.calls == 1 && backend_linker_calls(&child) == 1,
		"prototype-only -O1 -fintegrated-as link should invoke only the linker; calls=%d diagnostics: %s", child.calls, backend_diag_text(&d));
	String[] linker_argv = backend_argv(&child, 0);
	assert(argv_value_after(linker_argv, "-o") == output, "-O1 linker argv omitted the requested output path");
	String temp_object = child.observed_link_object;
	assert(child.observed_link_object_exists && temp_object != "",
		"linker did not receive an existing temporary object path");
	assert(argv_has(linker_argv, temp_object) && temp_object != prototype && temp_object != output,
		"linker argv omitted its temporary object input");
	assert(!file::exists(temp_object), "temporary -O1 -fintegrated-as object survived successful linking");
	assert(file::exists(output), "fake linker did not materialize the linked output");
	d.free();
}

fn void integrated_as_assemble_mode_writes_text_without_subprocesses() @test
{
	String dir = backend_scratch("integrated as assemble mode");
	String source = backend_put(dir, "function.c", "int f(void) { return 7; }\n");
	String output = backend_join(dir, "function.s");
	BackendChild child;
	diagnostics::Diagnostics d;
	d.init_list(mem);
	int status = run_backend_driver({ "aro", "-O1", "-fintegrated-as", "--target=x86_64-linux-gnu", "-S", "-nostdinc", "-nobuiltininc", "-o", output, source }, &d, &child, backend_tool_path(dir));
	assert(status == 0 && d.errors == 0,
		"-O1 -fintegrated-as -S failed; diagnostics: %s", backend_diag_text(&d));
	assert(child.calls == 0, "-O1 -fintegrated-as -S spawned a subprocess");
	assert(file::exists(output), "-O1 -fintegrated-as -S did not write its output");
	String output_bytes = (String)file::load(mem, output)!!;
	assert(!output_bytes.starts_with("\x7fELF"), "-O1 -fintegrated-as -S wrote an ELF object instead of assembly text");
	assert(output_bytes.contains(".intel_syntax") && output_bytes.contains("f:"),
		"-O1 -fintegrated-as -S output did not contain assembly text: %s", output_bytes);
	alloc::free(mem, output_bytes.ptr);
	d.free();
}

fn void optimized_nostdlib_static_auto_integrates_without_temporary_assembly() @test
{
	String dir = backend_scratch("static integrated link");
	String source = backend_put(dir, "global.c", "int value = 42;\n");
	String output = backend_join(dir, "linked output");
	BackendChild child;
	diagnostics::Diagnostics d;
	d.init_list(mem);
	int status = run_backend_driver({ "aro", "-O1", "--target=x86_64-linux-gnu", "-nostdinc", "-nobuiltininc", "-nostdlib", "-static", "-o", output, source }, &d, &child, backend_tool_path(dir));
	assert(status == 0 && d.errors == 0,
		"-O1 -nostdlib -static auto integrated link failed; diagnostics: %s", backend_diag_text(&d));
	assert(child.calls == 1 && backend_linker_calls(&child) == 1,
		"-O1 -nostdlib -static should invoke only the linker; calls=%d diagnostics: %s", child.calls, backend_diag_text(&d));
	String[] linker_argv = backend_argv(&child, 0);
	assert(argv_value_after(linker_argv, "-o") == output, "static integrated linker argv omitted the requested output path");
	String temp_object = child.observed_link_object;
	assert(child.observed_link_object_exists && temp_object != "" && argv_has(linker_argv, temp_object),
		"static integrated linker did not receive an existing temporary object");
	foreach (arg : linker_argv) assert(!arg.ends_with(".s"), "static integrated linker received a temporary assembly path: %s", arg);
	assert(!file::exists(temp_object), "temporary static integrated object survived successful linking");
	assert(file::exists(output), "static integrated fake linker did not materialize its output");
	d.free();
}

fn void optimized_nostdlib_without_static_keeps_assembler_and_linker() @test
{
	String dir = backend_scratch("dynamic external assembler link");
	String source = backend_put(dir, "global.c", "int value = 42;\n");
	String output = backend_join(dir, "linked output");
	BackendChild child = { .write_assembler_output = true };
	diagnostics::Diagnostics d;
	d.init_list(mem);
	int status = run_backend_driver({ "aro", "-O1", "--target=x86_64-linux-gnu", "-nostdinc", "-nobuiltininc", "-nostdlib", "-o", output, source }, &d, &child, backend_tool_path(dir));
	assert(status == 0 && d.errors == 0,
		"-O1 -nostdlib without -static link failed; diagnostics: %s", backend_diag_text(&d));
	assert(child.calls == 2 && backend_linker_calls(&child) == 1,
		"-O1 -nostdlib without -static should invoke assembler then linker; calls=%d diagnostics: %s", child.calls, backend_diag_text(&d));
	String[] assembler_argv = backend_argv(&child, 0);
	String[] linker_argv = backend_argv(&child, 1);
	assert(assembler_argv.len == 4 && assembler_argv[0].ends_with("/as") && assembler_argv[1].ends_with(".s") && assembler_argv[2] == "-o" && assembler_argv[3].ends_with(".o"),
		"non-static optimized path did not invoke the system assembler with a temporary .s and object output");
	assert(argv_value_after(linker_argv, "-o") == output, "non-static optimized linker argv omitted the requested output path");
	assert(!file::exists(assembler_argv[1]) && !file::exists(assembler_argv[3]),
		"non-static optimized path did not clean its temporary assembly/object files");
	assert(file::exists(output), "non-static fake linker did not materialize its output");
	d.free();
}

fn void assembler_process_failures_report_and_clean_temporary_assembly() @test
{
	String dir = backend_scratch("assembler failures");
	String path_value = backend_tool_path(dir);
	String input = backend_put(dir, "source.c", "int value = 19;\n");
	String[4] expected = { "unable to spawn linker: file not found", "error waiting for linker", "assembler exited with an error code", "assembler crashed" };
	for (uint i = 0; i < expected.len; i++)
	{
		BackendChild child = { .fail_call = 1, .failure = (ChildFailure)(i + 1), .write_assembler_output = true };
		diagnostics::Diagnostics d;
		d.init_list(mem);
		String output = backend_join(dir, string::tformat("requested output %d.o", i));
		int status = run_backend_driver({ "aro", "-O0", "--target=x86_64-linux-gnu", "-c", "-nostdinc", "-nobuiltininc", "-o", output, input }, &d, &child, path_value);
		assert(status != 0 && d.errors != 0 && backend_diag_contains(&d, expected[i]),
			"assembler outcome %d did not report its source-derived diagnostic; diagnostics: %s", i, backend_diag_text(&d));
		assert(child.calls == 1, "assembler outcome %d did not invoke exactly one child; diagnostics: %s", i, backend_diag_text(&d));
		String[] child_argv = backend_argv(&child, 0);
		assert(!file::exists(child_argv[1]), "temporary assembly survived assembler outcome %d", i);
		assert(file::exists(input), "assembler outcome %d deleted its source input", i);
		d.free();
	}
}

fn void linker_process_failures_clean_temps_and_preserve_user_object() @test
{
	String dir = backend_scratch("linker failures");
	String path_value = backend_tool_path(dir);
	String first = backend_put(dir, "one.c", "int one = 1;\n");
	String second = backend_put(dir, "two.c", "int two = 2;\n");
	String user_object = backend_put(dir, "keep object.o", "keep me");
	String[4] expected = { "unable to spawn linker: file not found", "error waiting for linker", "linker exited with an error code", "linker crashed" };
	for (uint i = 0; i < expected.len; i++)
	{
		BackendChild child = { .fail_call = 3, .failure = (ChildFailure)(i + 1), .write_assembler_output = true };
		diagnostics::Diagnostics d;
		d.init_list(mem);
		String output = backend_join(dir, string::tformat("failed link %d", i));
		int status = run_backend_driver({ "aro", "-O0", "--target=x86_64-linux-gnu", "-nostdinc", "-nobuiltininc", "-nostdlib", "-o", output, first, second, user_object }, &d, &child, path_value);
		assert(status != 0 && d.errors != 0 && backend_diag_contains(&d, expected[i]),
			"linker outcome %d did not report its source-derived diagnostic; diagnostics: %s", i, backend_diag_text(&d));
		assert(child.calls == 3, "linker outcome %d did not reach the linker; diagnostics: %s", i, backend_diag_text(&d));
		for (uint call = 0; call < 2; call++)
		{
			String[] as_argv = backend_argv(&child, call);
			assert(!file::exists(as_argv[1]), "temporary assembly survived linker outcome %d", i);
			assert(!file::exists(as_argv[3]), "temporary object survived linker outcome %d", i);
		}
		assert(file::exists(user_object), "linker cleanup deleted user object input on outcome %d", i);
		d.free();
	}
}

fn void missing_linker_host_spawn_reports_exact_fatal_text() @test
{
	String dir = backend_scratch("missing linker host spawn");
	String empty_path = backend_join(dir, "empty PATH");
	String sysroot = backend_join(dir, "empty sysroot");
	(void)path::mkdir(empty_path, true)!!;
	(void)path::mkdir(sysroot, true)!!;
	String prototype = backend_put(dir, "prototype.c", "int f(void);\n");
	String input = backend_put(dir, "input.o", "object marker");
	String output = backend_join(dir, "output.o");

	String? original_path = env::get_var(tmem, "PATH");
	env::set_var("PATH", empty_path);
	defer
	{
		if (try saved_path = original_path) { env::set_var("PATH", saved_path); }
		else { env::clear_var("PATH"); }
	}

	diagnostics::Diagnostics d;
	d.init_list(mem);
	int status = run_backend_driver_host({ "aro", "-O1", "-fintegrated-as", "--target=x86_64-linux-gnu",
		string::tformat("--sysroot=%s", sysroot), "-nostdinc", "-nobuiltininc", "-nostdlib", "-r",
		"-o", output, prototype, input }, &d, empty_path);
	String expected = "unable to spawn linker: file not found";
	assert(status == 1, "missing host linker should exit with status 1, got %d; diagnostics: %s", status, backend_diag_text(&d));
	assert(d.messages.len() == 1 && d.messages[0].kind == diagnostics::MessageKind.FATAL_ERROR && d.messages[0].text == expected,
		"real host linker spawn did not produce exactly the expected FATAL text; diagnostics: %s", backend_diag_text(&d));
	assert(!file::exists(output), "failed host linker spawn created its output file");
	d.free();
}

fn void expect_windows_linker_spawn_fatal(String dir, String linker, String expected) @feat(WIN32)
{
	$if env::WIN32:
	String empty_path = backend_join(dir, "empty PATH");
	String sysroot = backend_join(dir, "empty sysroot");
	(void)path::mkdir(empty_path, true)!!;
	(void)path::mkdir(sysroot, true)!!;
	String prototype = backend_put(dir, "prototype.c", "int f(void);\n");
	String input = backend_put(dir, "input.o", "object marker");
	String output = backend_join(dir, "output.o");

	diagnostics::Diagnostics d;
	d.init_list(mem);
	int status = run_backend_driver_host({ "aro", "-O1", "-fintegrated-as", "--target=x86_64-linux-gnu",
		string::tformat("--ld-path=%s", linker), string::tformat("--sysroot=%s", sysroot),
		"-nostdinc", "-nobuiltininc", "-nostdlib", "-r", "-o", output, prototype, input }, &d, empty_path);
	assert(status == 1, "host linker spawn should exit with status 1, got %d; diagnostics: %s", status, backend_diag_text(&d));
	assert(d.messages.len() == 1 && d.messages[0].kind == diagnostics::MessageKind.FATAL_ERROR && d.messages[0].text == expected,
		"real host linker spawn did not produce exactly the expected FATAL text; diagnostics: %s", backend_diag_text(&d));
	assert(!file::exists(output), "failed host linker spawn created its output file");
	d.free();
	$endif
}

fn void invalid_image_host_spawn_reports_invalid_exe() @feat(WIN32) @test
{
	$if env::WIN32:
	String dir = backend_scratch("invalid image host spawn");
	String linker = backend_put(dir, "ld.exe", "not a portable executable");
	expect_windows_linker_spawn_fatal(dir, linker, "unable to spawn linker: InvalidExe");
	$endif
}

fn void backslash_invalid_image_host_spawn_reports_invalid_exe() @feat(WIN32) @test
{
	$if env::WIN32:
	String dir = backend_scratch("backslash invalid image host spawn");
	String linker = backend_put(dir, "ld.exe", "not a portable executable");
	DString windows_linker;
	windows_linker.tinit();
	foreach (c : linker) windows_linker.append_char(c == '/' ? '\\' : c);
	expect_windows_linker_spawn_fatal(dir, windows_linker.str_view(), "unable to spawn linker: InvalidExe");
	$endif
}

fn void directory_linker_host_spawn_reports_access_denied() @feat(WIN32) @test
{
	$if env::WIN32:
	String dir = backend_scratch("directory linker host spawn");
	String linker = backend_join(dir, "ld.exe");
	(void)path::mkdir(linker, true)!!;
	expect_windows_linker_spawn_fatal(dir, linker, "unable to spawn linker: access denied");
	$endif
}

fn void invalid_linker_names_are_fatal_before_process_launch() @test
{
	String dir = backend_scratch("invalid linker names");
	String source = backend_put(dir, "input.c", "int value = 1;\n");
	String input = backend_put(dir, "input.o", "object marker");
	String output = backend_join(dir, "output");
	String path_value = backend_tool_path(dir);

	BackendChild ld_path_child = { .write_assembler_output = true };
	diagnostics::Diagnostics ld_path_d;
	ld_path_d.init_list(mem);
	int ld_path_status = run_backend_driver({ "aro", "-O0", "--target=x86_64-linux-gnu", "-nostdinc", "-nobuiltininc", "-nostdlib", "--ld-path=/nonexistent/ld", "-o", output, source, input }, &ld_path_d, &ld_path_child, path_value);
	String ld_path_message = "invalid linker name in argument '--ld-path=/nonexistent/ld'";
	assert(backend_diag_count(&ld_path_d, diagnostics::MessageKind.FATAL_ERROR, ld_path_message) == 1,
		"invalid --ld-path did not produce its FATAL diagnostic: %s", backend_first_diag_text(&ld_path_d));
	assert(ld_path_child.calls == 1 && backend_linker_calls(&ld_path_child) == 0,
		"invalid --ld-path launched the linker (assembler calls=%d); diagnostics: %s", ld_path_child.calls, backend_diag_text(&ld_path_d));
	ld_path_d.free();

	BackendChild fuse_child = { .write_assembler_output = true };
	diagnostics::Diagnostics fuse_d;
	fuse_d.init_list(mem);
	int fuse_status = run_backend_driver({ "aro", "-O0", "--target=x86_64-linux-gnu", "-nostdinc", "-nobuiltininc", "-nostdlib", "-fuse-ld=nosuch", "-o", output, source, input }, &fuse_d, &fuse_child, path_value);
	String fuse_message = "invalid linker name in argument '-fuse-ld=nosuch'";
	assert(backend_diag_count(&fuse_d, diagnostics::MessageKind.FATAL_ERROR, fuse_message) == 1,
		"invalid -fuse-ld did not produce its FATAL diagnostic: %s", backend_first_diag_text(&fuse_d));
	assert(fuse_child.calls == 1 && backend_linker_calls(&fuse_child) == 0,
		"invalid -fuse-ld launched the linker (assembler calls=%d); diagnostics: %s", fuse_child.calls, backend_diag_text(&fuse_d));
	assert(ld_path_status == 1 && fuse_status == 1,
		"invalid linker selections should exit 1 (statuses: --ld-path=%d, -fuse-ld=%d)", ld_path_status, fuse_status);
	fuse_d.free();
}

fn void static_pie_error_keeps_linker_mode_argument_order() @test
{
	String dir = backend_scratch("static pie arguments");
	String source = backend_put(dir, "input.c", "int value = 1;\n");
	String input = backend_put(dir, "input.o", "object marker");
	String output = backend_join(dir, "output");
	BackendChild child = { .write_assembler_output = true };
	diagnostics::Diagnostics d;
	d.init_list(mem);
	int status = run_backend_driver({ "aro", "-O0", "--target=x86_64-linux-gnu", "-nostdinc", "-nobuiltininc", "-nostdlib", "-static-pie", "-pie", "-o", output, source, input }, &d, &child, backend_tool_path(dir));
	String message = "cannot specify 'nopie' along with 'static-pie'";
	assert(backend_diag_count(&d, diagnostics::MessageKind.ERROR, message) == 1,
		"static-pie/-pie did not record exactly one ERROR: %s", backend_first_diag_text(&d));
	assert(child.calls == 2 && backend_linker_calls(&child) == 1,
		"static-pie/-pie should run one assembler and one linker, got %d child calls; diagnostics: %s", child.calls, backend_diag_text(&d));
	String[] linker_argv = backend_argv(&child, child.calls - 1);
	String[5] expected = { "-static", "-pie", "--no-dynamic-linker", "-z", "text" };
	assert(argv_has_sequence(linker_argv, expected[..]), "static-pie linker args did not retain the exact ordered mode sequence");
	assert(status == 1, "static-pie/-pie should exit 1 after recording an ERROR, got %d", status);
	d.free();
}

fn void verbose_linker_args_quote_special_object_path() @test
{
	String object_path = "objects with space/object\"name\x01.o";
	String quoted = driver_exec::quoted_arg_text(mem, object_path);
	assert(quoted == "\"objects with space/object\\\"name\\x01.o\"",
		"verbose linker arg did not match Zig fmtString quoting: %s", quoted);
	alloc::free(mem, quoted.ptr);
}

fn void output_and_parser_errors_prevent_process_launch() @test
{
	String dir = backend_scratch("preflight errors");
	String path_value = backend_tool_path(dir);
	String input = backend_put(dir, "source.c", "int value = 23;\n");
	String missing_parent_output = backend_join(dir, "missing parent/output.s");
	BackendChild output_child;
	diagnostics::Diagnostics output_d;
	output_d.init_list(mem);
	int output_status = run_backend_driver({ "aro", "-O0", "--target=x86_64-linux-gnu", "-S", "-nostdinc", "-nobuiltininc", "-o", missing_parent_output, input }, &output_d, &output_child, path_value);
	assert(output_status != 0 && output_d.errors != 0 && backend_diag_contains(&output_d, "unable to create output file"),
		"backend output creation failure did not produce its source-derived diagnostic; diagnostics: %s", backend_diag_text(&output_d));
	assert(output_child.calls == 0 && !file::exists(missing_parent_output), "output-file failure launched a child or created a file; diagnostics: %s", backend_diag_text(&output_d));
	output_d.free();

	BackendChild parser_child;
	diagnostics::Diagnostics parser_d;
	parser_d.init_list(mem);
	int parser_status = run_backend_driver({ "aro", "-O9", "-c", input }, &parser_d, &parser_child, path_value);
	// main.zig:94-102: a driver FatalError (and any run with errors) exits 1, not 2.
	assert(parser_status == 1 && parser_d.errors != 0 && backend_diag_contains(&parser_d, "invalid command-line argument"),
		"parser error did not preserve its source-derived diagnostic; diagnostics: %s", backend_diag_text(&parser_d));
	assert(parser_child.calls == 0, "parser error launched a backend process; diagnostics: %s", backend_diag_text(&parser_d));
	parser_d.free();

	String malformed = backend_put(dir, "malformed.c", "int value = ;\n");
	BackendChild syntax_child;
	diagnostics::Diagnostics syntax_d;
	syntax_d.init_list(mem);
	int syntax_status = run_backend_driver({ "aro", "-O0", "--target=x86_64-linux-gnu", "-c", "-nostdinc", "-nobuiltininc", malformed }, &syntax_d, &syntax_child, path_value);
	assert(syntax_status != 0 && syntax_d.errors != 0,
		"malformed C source did not preserve its source-derived parser diagnostic; diagnostics: %s", backend_diag_text(&syntax_d));
	assert(syntax_child.calls == 0, "C parser error launched a backend process; diagnostics: %s", backend_diag_text(&syntax_d));
	syntax_d.free();
}

// Zig parity: Driver.zig:1242-1243 reports "no input files" via d.fatal; main.zig:94-102
// maps error.FatalError to exit status 1.
fn void driver_no_inputs_is_fatal_status_one() @test
{
	String dir = backend_scratch("no inputs");
	BackendChild child;
	diagnostics::Diagnostics d;
	d.init_list(mem);
	int status = run_backend_driver({ "aro" }, &d, &child, backend_tool_path(dir));
	assert(status == 1, "missing input files should exit with status 1, got %d; diagnostics: %s", status, backend_diag_text(&d));
	assert(backend_diag_count(&d, diagnostics::MessageKind.FATAL_ERROR, "no input files") == 1, "missing input files should report exactly one FATAL_ERROR; diagnostics: %s", backend_diag_text(&d));
	assert(child.calls == 0, "missing input files launched a backend process; diagnostics: %s", backend_diag_text(&d));
	d.free();
}

// Zig parity: Driver.zig:1244-1245 rejects -o with several non-linking inputs via d.fatal;
// main.zig:94-102 maps error.FatalError to exit status 1.
fn void driver_dash_o_with_multiple_outputs_is_fatal() @test
{
	String dir = backend_scratch("dash o multiple");
	String first = backend_put(dir, "first.c", "int first = 1;\n");
	String second = backend_put(dir, "second.c", "int second = 2;\n");
	String output = backend_join(dir, "x.o");
	BackendChild child;
	diagnostics::Diagnostics d;
	d.init_list(mem);
	int status = run_backend_driver({ "aro", "-O0", "--target=x86_64-linux-gnu", "-c", "-nostdinc", "-nobuiltininc", "-o", output, first, second }, &d, &child, backend_tool_path(dir));
	assert(status == 1, "-c -o with two inputs should exit with status 1, got %d; diagnostics: %s", status, backend_diag_text(&d));
	assert(backend_diag_count(&d, diagnostics::MessageKind.FATAL_ERROR, "cannot specify -o when generating multiple output files") == 1,
		"-c -o with two inputs should report exactly one FATAL_ERROR; diagnostics: %s", backend_diag_text(&d));
	assert(child.calls == 0 && !file::exists(output), "-c -o with two inputs launched a child or created the output; diagnostics: %s", backend_diag_text(&d));
	d.free();
}

// Zig parity: Driver.zig:1248-1250 emits the linker-unused ERROR before any source is processed,
// then Driver.zig:1274-1276 preprocesses the source (emitting #warning hi) and Driver.zig:1277-1280
// returns on errors; main.zig:94-102 exits 1.
fn void driver_syntax_only_orders_unused_link_input_before_warning() @test
{
	String dir = backend_scratch("syntax only unused link");
	String source = backend_put(dir, "warned.c", "#warning hi\n");
	String object = backend_join(dir, "foo.o");
	BackendChild child;
	diagnostics::Diagnostics d;
	d.init_list(mem);
	int status = run_backend_driver({ "aro", "-O0", "--target=x86_64-linux-gnu", "-fsyntax-only", "-nostdinc", "-nobuiltininc", source, object }, &d, &child, backend_tool_path(dir));
	assert(status == 1, "-fsyntax-only with an unused linker input should exit with status 1, got %d; diagnostics: %s", status, backend_diag_text(&d));
	int error_index = backend_diag_index(&d, diagnostics::MessageKind.ERROR, "linker input file unused because linking not done");
	int warning_index = backend_diag_index(&d, diagnostics::MessageKind.WARNING, "hi");
	assert(error_index >= 0, "missing ERROR for the unused linker input; diagnostics: %s", backend_diag_text(&d));
	assert(warning_index > error_index, "#warning hi must follow the unused-linker-input ERROR (error at %d, warning at %d); diagnostics: %s / %s", error_index, warning_index, d.messages[0].text, d.messages.len() > 1 ? d.messages[1].text : "none");
	assert(d.errors == 1 && d.warnings == 1, "expected one error and one warning, got %d errors and %d warnings; diagnostics: %s", d.errors, d.warnings, backend_diag_text(&d));
	assert(child.calls == 0, "-fsyntax-only launched a backend process; diagnostics: %s", backend_diag_text(&d));
	d.free();
}

// Zig parity: -dM only selects a dump mode consumed inside the -E branch (Driver.zig:1417-1419).
// Zig has no "-d<letter> requires -E" check, so -fsyntax-only -dM is accepted.
fn void driver_dump_macros_is_accepted_under_syntax_only() @test
{
	String dir = backend_scratch("dump macros syntax only");
	String source = backend_put(dir, "source.c", "int value = 1;\n");
	BackendChild child;
	diagnostics::Diagnostics d;
	d.init_list(mem);
	int status = run_backend_driver({ "aro", "-O0", "--target=x86_64-linux-gnu", "-fsyntax-only", "-dM", "-nostdinc", "-nobuiltininc", source }, &d, &child, backend_tool_path(dir));
	assert(status == 0 && d.errors == 0, "-fsyntax-only -dM should exit 0 with no errors, got status %d and %d errors: %s; diagnostics: %s", status, d.errors, d.messages.len() > 0 ? d.messages[0].text : "none", backend_diag_text(&d));
	assert(child.calls == 0, "-fsyntax-only -dM launched a backend process; diagnostics: %s", backend_diag_text(&d));
	d.free();
}

// Zig parity: --verbose-ast only gates the AST dump after parsing (Driver.zig:1480), and the
// -E branch returns before it (Driver.zig:1419-1475). Zig has no -fsyntax-only requirement.
fn void driver_verbose_ast_is_accepted_with_preprocess_only() @test
{
	String dir = backend_scratch("verbose ast preprocess only");
	String source = backend_put(dir, "source.c", "int value = 1;\n");
	BackendChild child;
	diagnostics::Diagnostics d;
	d.init_list(mem);
	int status = run_backend_driver({ "aro", "-O0", "--target=x86_64-linux-gnu", "-E", "--verbose-ast", "-nostdinc", "-nobuiltininc", source }, &d, &child, backend_tool_path(dir));
	assert(status == 0 && d.errors == 0, "-E --verbose-ast should exit 0 with no errors, got status %d and %d errors: %s; diagnostics: %s", status, d.errors, d.messages.len() > 0 ? d.messages[0].text : "none", backend_diag_text(&d));
	assert(child.calls == 0, "-E --verbose-ast launched a backend process; diagnostics: %s", backend_diag_text(&d));
	d.free();
}
