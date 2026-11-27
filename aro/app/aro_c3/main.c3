module aro_c3_main;

import aro::frontend::c::compilation;
import aro::frontend::c::diagnostics;
import aro::frontend::c::driver;
import aro::host_process;
import aro::frontend::c::pragmas::gcc;
import aro::frontend::c::pragmas::message;
import aro::frontend::c::pragmas::once;
import aro::frontend::c::pragmas::pack;
import std::io;
import std::io::os;
import std::io::path;
import std::os::env;
import std::os::posix;

fn bool has_executable_path_prefix(String executable)
{
	foreach (char c : executable)
	{
		if (path::is_separator(c)) return true;
		$if env::WIN32:
			if (c == ':') return true;
		$endif
	}
	return false;
}

fn bool is_executable_candidate(Path candidate)
{
	if (!path::is_file(candidate)) return false;
	$if env::POSIX:
		return posix::access(candidate.zstr_tcopy(), 1) == 0;
	$else
		return true;
	$endif
}

fn String executable_directory(Allocator a, String[] args, String cwd)
{
	if (args.len == 0) return cwd;
	String executable = args[0];
	if (!has_executable_path_prefix(executable))
	{
		if (try path_value = env::get_var(a, "PATH"))
		{
			String[] search_dirs = path_value.split(a, env::WIN32 ? ";" : ":");
			foreach (String search_dir : search_dirs)
			{
				String directory = search_dir.len > 0 ? search_dir : cwd;
				if (try base = path::new(a, directory))
				{
					if (try candidate = base.append(a, executable))
					{
						if (is_executable_candidate(candidate))
						{
							if (try absolute = candidate.to_absolute_path(a))
							{
								return absolute.path_dirname(a) ?? cwd;
							}
						}
					}
					$if env::WIN32:
						bool has_extension = false;
						if (try existing_extension = path::tnew(executable).extension()) has_extension = true;
						if (!has_extension)
						{
							String[] extensions;
							if (try path_ext = env::get_var(a, "PATHEXT"))
							{
								extensions = path_ext.split(a, ";", skip_empty: true);
							}
							else
							{
								extensions = { ".COM", ".EXE", ".BAT", ".CMD" };
							}
							foreach (String extension : extensions)
							{
								if (try candidate = base.append(a, executable, extension: extension))
								{
									if (is_executable_candidate(candidate))
									{
										if (try absolute = candidate.to_absolute_path(a))
										{
											return absolute.path_dirname(a) ?? cwd;
										}
									}
								}
							}
						}
					$endif
				}
			}
		}
	}
	String dir = executable.path_dirname(a) ?? ".";
	return dir.to_absolute_path(a) ?? cwd;
}

struct Rlimit
{
	ulong cur;
	ulong max;
}

const CInt RLIMIT_STACK = 3; // Linux, macOS and the BSDs
const ulong RLIM_INFINITY = ulong::max;

extern fn CInt getrlimit(CInt resource, Rlimit* rlim) @feat(POSIX);
extern fn CInt setrlimit(CInt resource, Rlimit* rlim) @feat(POSIX);

<* Port of libiberty `stack_limit_increase`, which GCC calls at startup
 (toplev.cc, gcc.cc): raise the soft RLIMIT_STACK to `pref` bytes, capped at the
 hard limit, so the main thread's stack can grow for deeply nested input (GCC's
 limits-* torture tests nest ~10k levels). *>
fn void stack_limit_increase(ulong pref)
{
	$if env::POSIX:
		Rlimit rlim;
		if (getrlimit(RLIMIT_STACK, &rlim) != 0) return;
		if (rlim.cur == RLIM_INFINITY || rlim.cur >= pref) return;
		if (rlim.max != RLIM_INFINITY && rlim.cur >= rlim.max) return;
		rlim.cur = pref;
		if (rlim.max != RLIM_INFINITY && rlim.cur > rlim.max) rlim.cur = rlim.max;
		setrlimit(RLIMIT_STACK, &rlim);
	$endif
}

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
	stack_limit_increase(STACK_LIMIT);
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
	String executable_dir = executable_directory(mem, args, cwd);
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
