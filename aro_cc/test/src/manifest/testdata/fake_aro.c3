// Portable child executable used by //aro_cc/test/src/manifest:runner_tests.
// Environment controls mirror the old shell fixture, with FAKE_CRASH asking
// the C runtime to abort so each host reports its native abnormal outcome.
module fake_aro @link(env::WIN32, "kernel32");
import std::io, std::io::file, std::io::path, std::os::env, std::core::dstring;

extern fn void abort();
extern fn void raise_exception(uint code, uint flags, uint argument_count, void* arguments) @cname("RaiseException");

fn void terminate_abnormally()
{
	$if env::WIN32:
		// GetExitCodeProcess preserves this NTSTATUS exception code, which the
		// Windows runner host reports as abnormal termination with signal=-1.
		raise_exception(0xC0000005, 1, 0, null);
	$else
		abort();
	$endif
}

fn void copy_file_to(String path, OutStream output)
{
	char[]? data = file::load(mem, path);
	if (catch data) return;
	io::write_all(output, data)!!;
}

fn void write_argv(String destination, String[] args)
{
	DString contents;
	contents.init(mem);
	String cwd = (String)path::cwd(mem)!!;
	contents.appendf("cwd=%s\n", cwd);
	foreach (arg : args) contents.appendf("arg=%s\n", arg);
	file::save(destination, contents.str_view())!!;
}

fn void write_flood(int count)
{
	if (count <= 0) return;
	char[4096] bytes;
	foreach (&c : bytes) *c = 'x';
	sz remaining = (sz)count;
	while (remaining > 0)
	{
		sz chunk = remaining < bytes.len ? remaining : bytes.len;
		io::write_all(io::stdout(), bytes[:chunk])!!;
		io::write_all(io::stderr(), bytes[:chunk])!!;
		remaining -= chunk;
	}
}

fn int main(String[] args)
{
	if (try argv_path = env::get_var(mem, "FAKE_ARGV")) write_argv(argv_path, args[1..]);
	if (try flood_text = env::get_var(mem, "FAKE_FLOOD"))
	{
		int count = flood_text.to_int() ?? 0;
		write_flood(count);
	}
	if (try out_path = env::get_var(mem, "FAKE_OUT")) copy_file_to(out_path, io::stdout());
	if (try err_path = env::get_var(mem, "FAKE_ERR")) copy_file_to(err_path, io::stderr());
	if (try echo = env::get_var(mem, "FAKE_ECHO")) io::eprintf("fake.c:1:1: warning: %s\n", echo);
	(void)io::stdout().flush();
	(void)io::stderr().flush();
	if (try crash = env::get_var(mem, "FAKE_CRASH"))
	{
		if (crash == "1") terminate_abnormally();
	}
	if (try exit_text = env::get_var(mem, "FAKE_EXIT")) return exit_text.to_int() ?? 0;
	return 0;
}
