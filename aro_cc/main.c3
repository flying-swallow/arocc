module aro_cc_main;

import aro::frontend::c::compilation;
import aro::frontend::c::diagnostics;
import aro::frontend::c::driver;
import aro::host_process;
import aro::compiler::process_util;
import aro::frontend::c::pragmas::gcc;
import aro::frontend::c::pragmas::message;
import aro::frontend::c::pragmas::once;
import aro::frontend::c::pragmas::pack;
import std::io;
import std::io::os;
import std::io::path;
import std::os::env;
import std::os::posix;

<* GCC uses 64 MiB (128 MiB under ASan). *>
const ulong STACK_LIMIT = 64 * 1024 * 1024;

<* Initial size of the thread's top-level temp allocator. The optimizer and
   x86 lowering open nested `@pool`s per pass and per function; the stdlib
   default (256 KiB) overflows on large functions, and every overflowing pool
   then mallocs and frees its own chunk. *>
const usz TEMP_ALLOCATOR_SIZE = 8 * 1024 * 1024;

fn int main(String[] args)
{
	int result;
	@pool_init(mem, TEMP_ALLOCATOR_SIZE)
	{
		result = aro_main(args);
	};
	return result;
}

fn int aro_main(String[] args)
{
	process_util::stack_limit_increase(STACK_LIMIT);
	Diagnostics diagnostics;
	ColorMode color_mode = io::stderr().isatty() ? ESCAPE_CODES : NO_COLOR;
	diagnostics.init_writer(io::stderr(), color_mode);

	Compilation comp;
	comp.init(mem, null, &diagnostics);
	comp.environment.process = host_process::SERVICE;
	comp.pragmas.add("GCC", gcc::make_handler(mem));
	comp.pragmas.add("once", once::handler(mem));
	comp.pragmas.add("message", message::handler());
	comp.pragmas.add("pack", pack::make_handler(mem));

	String cwd = (String)path::cwd(mem)!!;
	comp.cwd = cwd;
	String executable_dir = process_util::executable_directory(mem, args, cwd);
	if (try path_value = env::get_var(mem, "PATH"))
	{
		comp.environment.has_path = true;
		comp.environment.path = path_value;
	}
	if (try runfiles = env::get_var(mem, "RUNFILES_DIR"))
	{
		comp.environment.runfiles_dir.set(runfiles);
	}
	else if (try test_srcdir = env::get_var(mem, "TEST_SRCDIR"))
	{
		comp.environment.runfiles_dir.set(test_srcdir);
	}
	if (try epoch = env::get_var(mem, "SOURCE_DATE_EPOCH"))
	{
		comp.environment.source_date_epoch.set(epoch);
	}

	int status = driver::run(&comp, &diagnostics, args, executable_dir);
	(void)io::stdout().flush();
	(void)io::stderr().flush();
	comp.free();
	diagnostics.free();
	return status;
}
