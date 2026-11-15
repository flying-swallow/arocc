// Shared pieces of the native Linux x86-64 integration programs (ports of the
// former native_*.sh tests): host gate, case expectations, PATH setup and
// shell-compatible exit statuses.
module native;
import std::io, std::io::file, std::os::env, aro_harness;

<* The native tests run only on Linux x86-64 hosts (`uname -s`/`uname -m` in the scripts). *>
const bool NATIVE_HOST = env::LINUX && env::X86_64;

<* Flush our stdout before a child writes to the inherited descriptors. *>
fn void flush_stdout()
{
	(void)io::stdout().flush();
	(void)io::stderr().flush();
}

<* Exit status as `$?` reports it: the exit code, 128 + signal, or 127 when the program could not start. *>
fn int shell_status(aro_harness::RunResult* r)
{
	if (!r.spawned) return 127;
	return r.exited ? r.exit_code : 128 + r.signal;
}

<* `basename "$source" .c`. *>
fn String case_name(String source)
{
	String base = aro_harness::basename_of(source);
	if (base.len > 2 && base.ends_with(".c")) return base[:base.len - 2];
	return base;
}

<*
 N from a first line that is exactly `// expect N` (N decimal digits), as
 `sed -n '1s#^// expect \([0-9][0-9]*\)$#\1#p'`; -1 when absent or unreadable.
*>
fn long expected_status(String source)
{
	@pool()
	{
		char[]? bytes = file::load_temp(source);
		if (catch bytes) return -1;
		String text = (String)bytes;
		String line = text;
		if (try nl = text.index_of_char('\n')) line = text[:nl];
		const String PREFIX = "// expect ";
		if (!line.starts_with(PREFIX)) return -1;
		String digits = line[PREFIX.len..];
		if (!digits.len || digits.len > 18) return -1;
		long value = 0;
		foreach (c : digits)
		{
			if (c < '0' || c > '9') return -1;
			value = value * 10 + (long)(c - '0');
		}
		return value;
	};
}

<* `$(head -n 3 file)`: the first three lines, without trailing newlines. *>
fn String head3(Allocator a, String text)
{
	sz end = 0;
	int lines = 0;
	while (end < text.len && lines < 3)
	{
		if (text[end] == '\n') lines++;
		end++;
	}
	String out = text[:end];
	while (out.len && out[^1] == '\n') out = out[:out.len - 1];
	return out.copy(a);
}

<* Print `head -n 3` of `text` directly (keeps the final newline of each line). *>
fn void print_head3(String text)
{
	sz end = 0;
	int lines = 0;
	while (end < text.len && lines < 3)
	{
		if (text[end] == '\n') lines++;
		end++;
	}
	io::print(text[:end]);
}

<* Prepend `dir` (made absolute) to this process's PATH, so aro_c3 finds the declared `as`. *>
fn void prepend_path(String dir)
{
	@pool()
	{
		String abs = aro_harness::absolute(tmem, dir);
		String old = aro_harness::getenv(tmem, "PATH");
		env::set_var("PATH", string::tformat("%s:%s", abs, old));
	};
}

<* A runfiles-relative `$(location)` argument as an absolute path. *>
fn String resolve_arg(Allocator a, String arg) => arg.len ? aro_harness::runfile(a, arg) : arg;

<* Whether `p` is a readable file (`[ -r ]`). *>
fn bool is_readable(String p)
{
	@pool()
	{
		return aro_harness::access(p.zstr_tcopy(), 4) == 0 && aro_harness::any_exists(p);
	};
}
