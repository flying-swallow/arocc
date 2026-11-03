// Command-line entry point of the C3 fixture runner (see runner.c3).
module aro_runner_main;
import std::io, std::os::env, aro_runner;

const String USAGE = `Usage: %s [options] <arocc-exe> <cases-dir>

Runs the integration fixtures in <cases-dir> with <arocc-exe>, like
test/runner.zig. <arocc-exe> may be omitted when ARO_RUNNER_EXE is set.

Options:
  --cases FILE  run only the cases listed in FILE (per-stage case manifest)
  --all         with --cases: run the whole corpus and reject unlisted cases
  --gate        compare each case's complete outcome (result, exit status,
                signal, fatal diagnostic) with the expectation in the case
                list instead of accepting any exit status
  --log FILE    write a per-case TSV outcome log after all cases ran
`;

fn int main(String[] args)
{
	SuiteOptions opts;
	String cases_file;
	bool all;
	String[2] positional;
	sz npos = 0;
	for (sz i = 1; i < args.len; i++)
	{
		String arg = args[i];
		switch (arg)
		{
			case "--cases":
			case "--log":
				if (i + 1 >= args.len)
				{
					io::eprintfn("%s requires an argument", arg);
					return 2;
				}
				if (arg == "--cases")
				{
					cases_file = args[++i];
				}
				else
				{
					opts.log_path = args[++i];
				}
			case "--all":
				all = true;
			case "--gate":
				opts.gate = true;
			case "-h":
			case "--help":
				io::printf(USAGE, args[0]);
				return 0;
			default:
				if (arg.len > 1 && arg[0] == '-')
				{
					io::eprintfn("unknown option: %s", arg);
					io::eprintf(USAGE, args[0]);
					return 2;
				}
				if (npos == 2)
				{
					io::eprintf(USAGE, args[0]);
					return 2;
				}
				positional[npos++] = arg;
		}
	}
	if (npos == 2)
	{
		opts.exe = positional[0];
		opts.cases_dir = positional[1];
	}
	else if (npos == 1)
	{
		String? from_env = env::get_var(mem, "ARO_RUNNER_EXE");
		if (catch from_env)
		{
			io::eprintfn("no compiler executable: pass <arocc-exe> or set ARO_RUNNER_EXE");
			io::eprintf(USAGE, args[0]);
			return 2;
		}
		opts.exe = from_env;
		opts.cases_dir = positional[0];
	}
	else
	{
		io::eprintf(USAGE, args[0]);
		return 2;
	}
	if (all && !cases_file.len)
	{
		io::eprintfn("--all requires --cases (the classification list)");
		return 2;
	}
	if (opts.gate && !cases_file.len)
	{
		io::eprintfn("--gate requires --cases (the expected outcomes)");
		return 2;
	}
	opts.mode = all ? FULL : cases_file.len ? LIST : CORPUS;
	if (cases_file.len)
	{
		char[]? text = file::load(mem, cases_file);
		if (catch err = text)
		{
			io::eprintfn("unable to read case list '%s': %s", cases_file, err);
			return 2;
		}
		DString log;
		log.init(mem);
		CaseEntry[]? list = aro_runner::parse_case_list(mem, (String)text, cases_file, &log);
		io::eprint(log.str_view());
		if (catch list) return 2;
		opts.list = list;
	}

	SuiteReport rep = aro_runner::run_suite(opts, io::stderr());
	rep.print(io::stderr(), opts.gate);
	if (rep.config_error) return 2;
	return rep.passed_gate(opts.gate) ? 0 : 1;
}
