// Compiler shim for //aro_cc/test/src/fuzz:afl_fuzz: replace this process with
// AFL_CC (default afl-clang-fast, looked up on PATH) and the same arguments.
module afl_cc;
import std::io, std::os::posix, aro_harness;

extern fn CInt execv(ZString path, ZString* argv);

fn int main(String[] args)
{
	String compiler = aro_harness::getenv(mem, "AFL_CC");
	if (!compiler.len) compiler = "afl-clang-fast";
	String path = aro_harness::which(mem, compiler);
	if (!path.len)
	{
		io::eprintfn("AFL compiler not found: %s (set AFL_CC and pass --action_env=AFL_CC)", compiler);
		return 127;
	}
	ZString* argv = mem::new_array(ZString, args.len + 1);
	argv[0] = compiler.zstr_copy(mem);
	for (sz i = 1; i < args.len; i++) argv[i] = args[i].zstr_copy(mem);
	argv[args.len] = null;
	execv(path.zstr_copy(mem), argv);
	io::eprintfn("%s: cannot execute: %s", compiler, path);
	return 126;
}
