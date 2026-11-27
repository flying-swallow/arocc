// `check_probe [--target <arch-os>] [--lib <stdlib dir>] <file>...`: parse + semantically check the
// files with the c3 frontend (like `c3c -C --use-stdlib=no compile <files>`,
// check only, no codegen; with `--lib`, the stdlib in that dir is used, like
// `c3c -C --lib-dir`-less default `c3c -C compile`). Errors go to stderr as "(path:row:col) Error: text"; exit 1 if
// any error was reported. `--target` picks the c3c arch/os target (default
// linux-x64, c3c's host default).
module c3_check_probe;
import aro::frontend::c3::compiler, aro::frontend::c3::diagnostics;
import std::io, libc;

fn void probe_exit(int exit_value)
{
	io::stdout().flush()!!;
	io::stderr().flush()!!;
	libc::exit(exit_value == compiler::COMPILER_SUCCESS_EXIT ? 0 : 1);
}

fn int main(String[] args)
{
	String[] files = args[1..];
	compiler::ArchOsTarget arch_os = compiler::ARCH_OS_TARGET_DEFAULT;
	if (files.len >= 2 && files[0] == "--target")
	{
		arch_os = compiler::arch_os_target_from_string(files[1]);
		if (arch_os == compiler::ARCH_OS_TARGET_DEFAULT)
		{
			io::eprintfn("Invalid target %s.", files[1]);
			return 1;
		}
		files = files[2..];
	}
	compiler::compiler_reset(arch_os);
	defer compiler::compiler_free();
	compiler::global_diagnostics.output = TO_WRITER;
	compiler::global_diagnostics.writer = io::stderr();
	compiler::global_diagnostics.use_ansi = false;
	compiler::exit_hook = &probe_exit;
	compiler::build_target_setup_defaults();
	compiler::compiler.build.use_stdlib = compiler::USE_STDLIB_OFF;
	compiler::compiler.build.check_only = true;
	if (files.len >= 2 && files[0] == "--lib")
	{
		compiler::compiler.build.use_stdlib = compiler::USE_STDLIB_ON;
		compiler::compiler.context.lib_dir = files[1];
		files = files[2..];
	}
	foreach (path : files) compiler::@vec_add(&compiler::compiler.build.sources, path);
	compiler::compile();
	return compiler::compiler.context.errors_found ? 1 : 0;
}
