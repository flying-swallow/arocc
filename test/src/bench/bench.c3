// Compile-time and run-time benchmark of aro_cc against the host gcc/clang.
//
//   bazel run -c opt //test/src/bench:bench [-- --mode compile|run|all]
//       [--runs N] [--corpus FILE]... [--filter GLOB] [--compilers gcc,clang]
//
// compile: each input (empty.c, a generated many-functions file, --corpus files)
//   is timed under -E, -fsyntax-only, -c -O0 and -c -O2 per compiler; aro also
//   gets -c -O0 -fno-integrated-as to show the cost of the external assembler.
// run: each test/bench/run/*.c is built per compiler at -O0 and -O2; its stdout
//   must match the gcc -O0 build (else "wrong"), then the binary is timed.
// Cells are the median wall time of --runs runs. Only `-c opt` aro builds give
// meaningful compile numbers (fastbuild is 2.5-4x slower).
module bench;
import std::io, std::io::file, std::collections::list, std::sort, std::time, libc, aro_harness;

struct Options
{
	String aro;
	String resource_dir;
	String bench_dir;
	String mode;
	String filter;
	String[] compilers;
	List{String} corpus;
	int runs;
	String out;
}

struct Compiler
{
	String name;
	String exe;
	bool is_aro;
}

<* Median wall seconds over `runs` runs of `cmd`; < 0 when any run fails. *>
fn double time_cmd(String[] cmd, int runs, String* stdout_out = null)
{
	double[] samples = mem::temp_array(double, runs);
	for (int i = 0; i < runs; i++)
	{
		Clock start = clock::now();
		RunResult r = aro_harness::run(tmem, cmd, { .timeout_ms = 300_000, .search_path = true });
		samples[i] = (double)(long)start.to_now() / 1e9;
		if (!r.spawned || r.timed_out || r.returncode() != 0) return -1.0;
		if (stdout_out) *stdout_out = r.stdout;
	}
	sort::quicksort(samples, fn int(double a, double b) => a < b ? -1 : (a > b ? 1 : 0));
	return samples[runs / 2];
}

fn String[] concat(String[] x, String[] y)
{
	String[] out = mem::temp_array(String, x.len + y.len);
	foreach (i, v : x) out[i] = v;
	foreach (i, v : y) out[x.len + i] = v;
	return out;
}

fn String cell(double secs)
{
	if (secs < 0) return "fail";
	if (secs < 1.0) return string::tformat("%.0f ms", secs * 1000.0);
	return string::tformat("%.2f s", secs);
}

fn String[] compiler_argv(Compiler* c, Options* o, String[] args)
{
	List{String} cmd;
	cmd.init(tmem);
	cmd.push(c.exe);
	if (c.is_aro)
	{
		cmd.push("-resource-dir");
		cmd.push(o.resource_dir);
	}
	cmd.push("-w");
	cmd.push_all(args);
	return cmd.array_view();
}

<* A large translation unit of independent loop/switch functions (no recursion). *>
fn String generate_functions(String dir, int count)
{
	DString s;
	s.init(tmem);
	for (int i = 0; i < count; i++)
	{
		s.appendf("int f%d(int a, int b, int c)\n{\n\tint s = 0;\n", i);
		s.append("\tfor (int i = 0; i < a; i++) { if (i % 3 == b) s += i * c; else s -= c; }\n");
		s.appendf("\tswitch (s & 7) { case 0: s += %d; break; case 1: s ^= a; break; default: s = s * 2 + 1; }\n", i);
		s.append("\treturn s;\n}\n");
	}
	s.append("int main(void) { return f0(1, 2, 3) & 0; }\n");
	String path = string::tformat("%s/generated_%d_functions.c", dir, count);
	(void)file::save(path, s.str_view());
	return path;
}

struct Step
{
	String label;
	String[] args;
	<* aro only. *>
	bool aro_only;
}

fn void bench_compile(Options* o, Compiler[] compilers, String tmp, DString* report)
{
	List{String} inputs;
	inputs.init(tmem);
	String empty = string::tformat("%s/empty.c", tmp);
	(void)file::save(empty, "");
	inputs.push(empty);
	inputs.push(generate_functions(tmp, 4000));
	foreach (c : o.corpus) inputs.push(c);
	String obj = string::tformat("%s/out.o", tmp);
	Step[*] steps = {
		{ "-E", { "-E", "-o", "/dev/null" }, false },
		{ "-fsyntax-only", { "-fsyntax-only" }, false },
		{ "-c -O0", { "-c", "-O0", "-o", obj }, false },
		{ "-c -O0 -fno-integrated-as", { "-c", "-O0", "-fno-integrated-as", "-o", obj }, true },
		{ "-c -O2", { "-c", "-O2", "-o", obj }, false },
	};
	report.append("## Compile time (median wall)\n\n| input | step |");
	foreach (c : compilers) report.appendf(" %s |", c.name);
	report.append("\n|---|---|");
	foreach (c : compilers) report.append("---|");
	report.append("\n");
	foreach (input : inputs)
	{
		String name = aro_harness::basename_of(input);
		if (!aro_harness::glob_match(o.filter, name)) continue;
		foreach (&step : steps)
		{
			report.appendf("| %s | %s |", name, step.label);
			foreach (&c : compilers)
			{
				if (step.aro_only && !c.is_aro)
				{
					report.append(" |");
					continue;
				}
				@pool()
				{
					String[] args = concat(step.args, { input });
					report.appendf(" %s |", cell(time_cmd(compiler_argv(c, o, args), o.runs)));
				};
			}
			report.append("\n");
			io::printf(".");
		}
	}
	report.append("\n");
}

fn void bench_run(Options* o, Compiler[] compilers, String tmp, DString* report)
{
	String[]? names = aro_harness::list_sorted(tmem, o.bench_dir);
	if (catch names)
	{
		io::eprintfn("no benchmark programs in %s", o.bench_dir);
		return;
	}
	String[*] levels = { "-O0", "-O2" };
	report.append("## Run time of the compiled program (median wall)\n\n| program | level |");
	foreach (c : compilers) report.appendf(" %s |", c.name);
	report.append("\n|---|---|");
	foreach (c : compilers) report.append("---|");
	report.append("\n");
	foreach (n : names)
	{
		if (!n.ends_with(".c") || !aro_harness::glob_match(o.filter, n)) continue;
		String src = string::tformat("%s/%s", o.bench_dir, n);
		// Reference output: the first compiler's -O0 build (gcc when present).
		String expected;
		bool have_expected = false;
		foreach (level : levels)
		{
			report.appendf("| %s | %s |", n[:n.len - 2], level);
			foreach (i, &c : compilers)
			{
				String exe = string::tformat("%s/%s_%s%s", tmp, n[:n.len - 2], c.name, level);
				String[] build = compiler_argv(c, o, { level, "-o", exe, src, "-lm" });
				RunResult br = aro_harness::run(tmem, build, { .timeout_ms = 300_000, .search_path = true, .merge_stderr = true });
				if (!br.spawned || br.returncode() != 0)
				{
					report.append(br.stdout.contains("TODO") ? " unsupported |" : " build fail |");
					continue;
				}
				String got;
				double secs = time_cmd({ exe }, o.runs, &got);
				if (secs >= 0 && !have_expected)
				{
					expected = got;
					have_expected = true;
				}
				if (secs >= 0 && got != expected)
				{
					report.append(" wrong output |");
					continue;
				}
				report.appendf(" %s |", cell(secs));
			}
			report.append("\n");
			io::printf(".");
		}
	}
	report.append("\n");
}

const String USAGE = `usage: bench [--aro ARO] [--resource-dir DIR] [--bench-dir DIR] [--mode compile|run|all]
             [--runs N] [--corpus FILE]... [--filter GLOB] [--compilers gcc,clang] [--out FILE]
`;

fn int main(String[] argv)
{
	Options o;
	String root = aro_harness::repo_root(mem);
	o.aro = string::format(mem, "%s/bazel-bin/aro_cc", root);
	o.resource_dir = root;
	o.bench_dir = string::format(mem, "%s/test/bench/run", root);
	o.mode = "all";
	o.filter = "*";
	o.runs = 5;
	o.corpus.init(mem);
	String compilers_arg = "gcc,clang";
	for (sz i = 1; i < argv.len; i++)
	{
		String arg = argv[i];
		if (arg == "-h" || arg == "--help")
		{
			io::print(USAGE);
			return 0;
		}
		if (i + 1 >= argv.len)
		{
			io::eprintf("%s", USAGE);
			return 2;
		}
		String value = argv[++i];
		switch (arg)
		{
			case "--aro": o.aro = aro_harness::runfile(mem, value);
			case "--resource-dir": o.resource_dir = aro_harness::runfile(mem, value);
			case "--bench-dir": o.bench_dir = aro_harness::absolute(mem, value);
			case "--mode": o.mode = value;
			case "--runs": o.runs = value.to_int() ?? 5;
			case "--corpus": o.corpus.push(aro_harness::absolute(mem, value));
			case "--filter": o.filter = value;
			case "--compilers": compilers_arg = value;
			case "--out": o.out = aro_harness::absolute(mem, value);
			default:
				io::eprintf("unknown option %s\n%s", arg, USAGE);
				return 2;
		}
	}
	if (o.runs < 1) o.runs = 1;
	if (!aro_harness::any_exists(o.aro))
	{
		io::eprintfn("aro binary not found: %s", o.aro);
		return 1;
	}
	List{Compiler} compilers;
	compilers.init(mem);
	foreach (name : compilers_arg.split(mem, ","))
	{
		if (!name.len) continue;
		RunResult probe = aro_harness::run(tmem, { name, "--version" }, { .search_path = true });
		if (!probe.spawned || probe.returncode() != 0)
		{
			io::eprintfn("skipping %s: not runnable", name);
			continue;
		}
		compilers.push({ name, name, false });
	}
	compilers.push({ "aro", o.aro, true });
	String tmp = aro_harness::make_temp_dir(mem, "aro-bench-") ?? "";
	if (!tmp.len)
	{
		io::eprintfn("cannot create a temporary directory");
		return 1;
	}
	defer aro_harness::remove_tree(tmp);
	DString report;
	report.init(mem);
	report.appendf("# aro benchmark\n\naro: `%s`, runs per cell: %d\n\n", o.aro, o.runs);
	if (o.mode == "compile" || o.mode == "all") bench_compile(&o, compilers.array_view(), tmp, &report);
	if (o.mode == "run" || o.mode == "all") bench_run(&o, compilers.array_view(), tmp, &report);
	io::printn("");
	io::print(report.str_view());
	if (o.out.len) (void)file::save(o.out, report.str_view());
	return 0;
}
