// Native execution and bidirectional Apple Clang ABI checks.
module darwin_arm64_integration;
import std::io, aro_harness, native, aro::target;

fn int step(String[] args)
{
	native::flush_stdout();
	RunResult result = aro_harness::run(tmem, args, { .inherit_stdio = true, .search_path = true });
	int status = native::shell_status(&result);
	if (status) io::eprintfn("step failed (%d): %s", status, args[0]);
	return status;
}

fn int main(String[] args)
{
	target::Host? host = target::host();
	if (catch host) return 0;
	if (host.arch != target::Arch.AARCH64 || host.os != target::OsTag.MACOS)
	{
		io::printn("SKIP: requires ARM64 macOS and Apple command line tools");
		return 0;
	}
	if (args.len != 4) return 2;
	String aro = native::resolve_arg(tmem, args[1]);
	String producer = native::resolve_arg(tmem, args[2]);
	String consumer = native::resolve_arg(tmem, args[3]);
	String directory = aro_harness::make_temp_dir(tmem, "aro-darwin-arm64.")!!;
	defer aro_harness::remove_tree(directory);
	String obj = string::tformat("%s/abi.o", directory);
	String binary = string::tformat("%s/program", directory);
	String assembly = string::tformat("%s/program.s", directory);
	int status;
	foreach (level : (String[]){ "-O0", "-O2", "-O3" })
	{
		// Aro-generated callees must accept calls from Apple Clang.
		if ((status = step({ aro, level, "--verify-ir", "-c", producer, "-o", obj }))) return status;
		if ((status = step({ "xcrun", "clang", "-mmacosx-version-min=13.0", consumer, obj, "-o", binary }))) return status;
		if ((status = step({ binary }))) return status;
		// Aro-generated callers must use the ABI expected by Apple Clang.
		if ((status = step({ "xcrun", "clang", "-mmacosx-version-min=13.0", "-c", producer, "-o", obj }))) return status;
		if ((status = step({ aro, level, "--verify-ir", consumer, obj, "-o", binary }))) return status;
		if ((status = step({ binary }))) return status;
		if ((status = step({ aro, level, "--verify-ir", producer, consumer, "-o", binary }))) return status;
		if ((status = step({ binary }))) return status;
		if ((status = step({ aro, level, "--verify-ir", "-fwhole-program", producer, consumer, "-o", binary }))) return status;
		if ((status = step({ binary }))) return status;
	}
	if ((status = step({ aro, "-S", consumer, "-o", assembly }))) return status;
	String asm_text = (String)file::load_temp(assembly)!!;
	if (!asm_text.contains(".build_version macos") || !asm_text.contains("_main")) return 1;
	if ((status = step({ "xcrun", "as", "-arch", "arm64", assembly, "-o", obj }))) return status;
	RunResult integrated = aro_harness::run(tmem, { aro, "-fintegrated-as", "-c", consumer, "-o", obj });
	if (!integrated.exited || integrated.exit_code == 0 || !integrated.stderr.contains("-fno-integrated-as")) return 1;
	String unsupported = string::tformat("%s/unsupported.c", directory);
	String[] sources = {
		"void f(void) { __asm__(\"nop\"); }",
		"typedef int V __attribute__((vector_size(16))); V f(V x) { return x; }",
		"__int128 f(__int128 x) { return x; }",
		"int f(int *p) { return __atomic_load_n(p, 5); }",
	};
	String[] expected = { "inline assembly is unsupported", "vector arguments and results", "wider than 64 bits", "atomic_load" };
	foreach (i, source : sources)
	{
		file::save(unsupported, source)!!;
		RunResult result = aro_harness::run(tmem, { aro, "-c", unsupported, "-o", obj });
		if (!result.exited || result.exit_code == 0 || !result.stderr.contains(expected[i]))
		{
			io::eprintfn("unsupported feature diagnostic failed: %s", result.stderr);
			return 1;
		}
	}
	io::printn("ARM64 macOS integration passed at O0/O2/O3, including whole-program and Clang interoperability");
	return 0;
}
