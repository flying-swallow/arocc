// C3 compiler entry point. The port currently supports parse/check modes.
module aro_c3c_main;
import aro::frontend::c3::compiler;
import aro::compiler::process_util;
import std::collections::list, std::io, libc;

fn void compiler_exit(int status)
{
	io::stdout().flush()!!;
	io::stderr().flush()!!;
	libc::exit(status == compiler::COMPILER_SUCCESS_EXIT ? 0 : 1);
}

fn void usage()
{
	io::printn("Usage: aro_c3c (--check | --parse-only) [--target <arch-os>] [--stdlib <dir>] <file>...");
	io::printn("  --check, -C    Parse and check C3 sources");
	io::printn("  --parse-only  Parse C3 sources without semantic analysis");
	io::printn("  --stdlib DIR  Enable the C3 standard library at DIR");
	io::printn("Code generation is not implemented yet.");
}

fn int main(String[] args)
{
	bool check_only;
	bool parse_only;
	bool literal_files;
	String stdlib_dir;
	compiler::ArchOsTarget target = compiler::ARCH_OS_TARGET_DEFAULT;
	List{String} files;
	files.init(mem);
	defer files.free();
	for (usz i = 1; i < args.len; i++)
	{
		String arg = args[i];
		if (literal_files) { files.push(arg); continue; }
		if (arg == "--") { literal_files = true; continue; }
		if (arg == "--help" || arg == "-h") { usage(); return 0; }
		if (arg == "--version") { io::printfn("aro_c3c (C3 frontend port %s)", compiler::COMPILER_VERSION); return 0; }
		if (arg == "--check" || arg == "-C") { check_only = true; continue; }
		if (arg == "--parse-only") { parse_only = true; continue; }
		if (arg == "--target" || arg == "--stdlib")
		{
			if (++i == args.len) { io::eprintfn("aro_c3c: %s requires a value", arg); return 1; }
			if (arg == "--stdlib") { stdlib_dir = args[i]; continue; }
			target = compiler::arch_os_target_from_string(args[i]);
			if (target == compiler::ARCH_OS_TARGET_DEFAULT)
			{
				io::eprintfn("aro_c3c: invalid target '%s'", args[i]); return 1;
			}
			continue;
		}
		if (arg.len && arg[0] == '-') { io::eprintfn("aro_c3c: unknown option '%s'", arg); return 1; }
		files.push(arg);
	}
	if (check_only && parse_only) { io::eprintn("aro_c3c: choose either --check or --parse-only"); return 1; }
	if (!files.len()) { io::eprintn("aro_c3c: no input files; use --help for usage"); return 1; }
	if (!check_only && !parse_only)
	{
		io::eprintn("aro_c3c: code generation is not implemented yet; use --check or --parse-only"); return 1;
	}
	process_util::stack_limit_increase(64 * 1024 * 1024);
	compiler::compiler_reset(target);
	defer compiler::compiler_free();
	compiler::global_diagnostics.output = TO_WRITER;
	compiler::global_diagnostics.terminal = { .writer = io::stderr(), .mode = NO_COLOR };
	compiler::exit_hook = &compiler_exit;
	compiler::compiler_exe_name = args[0];
	compiler::build_target_setup_defaults();
	compiler::compiler.build.check_only = check_only;
	compiler::compiler.build.parse_only = parse_only;
	compiler::compiler.build.use_stdlib = stdlib_dir.len ? compiler::USE_STDLIB_ON : compiler::USE_STDLIB_OFF;
	if (stdlib_dir.len) compiler::compiler.context.lib_dir = stdlib_dir;
	foreach (file : files) compiler::@vec_add(&compiler::compiler.build.sources, file);
	compiler::compile();
	return compiler::compiler.context.errors_found ? 1 : 0;
}
