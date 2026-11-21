// Compile data and control flow with aro_c3, link using the host compiler,
// and execute the results through both native output paths.
module native_backend_cli_integration;
import std::io, aro_harness, native;

<* Run a step with inherited output; its shell status (nonzero ends the test, as under `set -e`). *>
fn int step(String[] argv)
{
	native::flush_stdout();
	RunResult r = aro_harness::run(tmem, argv, { .inherit_stdio = true });
	return native::shell_status(&r);
}

fn int main(String[] args)
{
	if (args.len != 5)
	{
		io::eprintfn("usage: %s <aro_c3> <backend_data.c> <backend_consumer.c> <c_compiler>", args[0]);
		return 2;
	}
	String aro_c3_arg = args[1];
	String data_source = args[2];
	String consumer_source = args[3];
	String cc_arg = args[4];

	if (!native::NATIVE_HOST)
	{
		io::printn("SKIP: native backend CLI integration requires Linux x86-64");
		return 0;
	}

	foreach (executable : (String[]){ aro_c3_arg, cc_arg })
	{
		if (!aro_harness::is_executable(native::resolve_arg(tmem, executable)))
		{
			io::eprintfn("native backend CLI integration: not executable: %s", executable);
			return 1;
		}
	}
	foreach (source : (String[]){ data_source, consumer_source })
	{
		if (!native::is_readable(source))
		{
			io::eprintfn("native backend CLI integration: source is not readable: %s", source);
			return 1;
		}
	}
	String aro_c3 = native::resolve_arg(mem, aro_c3_arg);
	String cc = native::resolve_arg(mem, cc_arg);

	String? tmpdir = aro_harness::make_temp_dir(mem, "aro-native-backend.");
	if (catch tmpdir)
	{
		io::eprintn("native backend CLI integration: cannot create a temporary directory");
		return 1;
	}
	defer aro_harness::remove_tree(tmpdir);
	String data_object = string::format(mem, "%s/backend_data.o", tmpdir);
	String consumer_object = string::format(mem, "%s/backend_consumer.o", tmpdir);
	String binary = string::format(mem, "%s/backend_consumer", tmpdir);

	// The declared native tool runfiles keep cc and as side by side. aro_c3 finds
	// its assembler through PATH, so expose that directory for its invocation.
	native::prepend_path(aro_harness::dirname_of(cc));

	int status;
	if ((status = step({ aro_c3, "-c", data_source, "-o", data_object }))) return status;
	if ((status = step({ cc, "-c", consumer_source, "-o", consumer_object }))) return status;
	if ((status = step({ cc, consumer_object, data_object, "-o", binary }))) return status;
	if ((status = step({ binary }))) return status;

	// Exercise scalar identities, dominating CSE, PHI edges, side effects,
	// and loop backedges through both output paths and optimization levels.
	String pipeline_source = string::format(mem, "%s/ir_pipeline.c", tmpdir);
	file::save(pipeline_source,
		"volatile int observed;\n"
		"int bump(void) { observed = observed + 1; return observed; }\n"
		"int identity(int x) { return (((x + 0) * 1) | 0) ^ (x ^ x); }\n"
		"int common(int x, int y, int c) { int p = x * y; "
		"if (c) return (y * x) + p; return (x * y) - p; }\n"
		"int join(int c, int d, int x, int y) { int r; "
		"if (c) { if (d) r = x; else r = y; } else r = y; return r; }\n"
		"int main(void) { int sum = 0; for (int i = 0; i < 6; ++i) "
		"{ if (i & 1) sum += i; else sum += 2 * i; } if (sum != 21) return 1; "
		"for (int x = -17; x <= 17; ++x) for (int y = -9; y <= 9; ++y) "
		"for (int c = 0; c < 2; ++c) for (int d = 0; d < 2; ++d) { "
		"if (identity(x) != x) return 2; "
		"if (common(x, y, c) != (c ? 2*x*y : 0)) return 3; "
		"if (join(c, d, x, y) != (c && d ? x : y)) return 4; } "
		"int zero = bump() * 0; return zero != 0 || observed != 1; }\n")!!;
	foreach (mode : (String[]){ "-fintegrated-as", "-fno-integrated-as" })
	{
		foreach (level : (String[]){ "-O0", "-O1", "-O2", "-O3", "-Os", "-Oz" })
		{
			if ((status = step({ aro_c3, level, "--verify-ir", mode, "-c", pipeline_source, "-o", data_object }))) return status;
			if ((status = step({ cc, data_object, "-o", binary }))) return status;
			if ((status = step({ binary }))) return status;
		}
	}

	io::printn("native backend CLI integration passed: exported scalar and string contents verified");
	return 0;
}
