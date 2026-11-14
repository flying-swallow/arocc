module aro_c3_main;

import aro::compilation;
import aro::diagnostics;
import aro::driver;
import aro::host_process;
import aro::pragmas::gcc;
import aro::pragmas::message;
import aro::pragmas::once;
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

fn int main(String[] args)
{
	Diagnostics diagnostics;
	ColorMode color_mode = io::stderr().isatty() ? ESCAPE_CODES : NO_COLOR;
	diagnostics.init_writer(io::stderr(), color_mode);

	Compilation comp;
	comp.init(mem, null, &diagnostics);
	comp.environment.process = host_process::SERVICE;
	comp.pragmas.add("GCC", gcc::make_handler(mem));
	comp.pragmas.add("once", once::handler(mem));
	comp.pragmas.add("message", message::handler());

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
		comp.environment.has_runfiles_dir = true;
		comp.environment.runfiles_dir = runfiles;
	}
	else if (try test_srcdir = env::get_var(mem, "TEST_SRCDIR"))
	{
		comp.environment.has_runfiles_dir = true;
		comp.environment.runfiles_dir = test_srcdir;
	}
	if (try epoch = env::get_var(mem, "SOURCE_DATE_EPOCH"))
	{
		comp.environment.has_source_date_epoch = true;
		comp.environment.source_date_epoch = epoch;
	}

	int status = driver::run(&comp, &diagnostics, args, executable_dir);
	(void)io::stdout().flush();
	(void)io::stderr().flush();
	comp.free();
	diagnostics.free();
	return status;
}