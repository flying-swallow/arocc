// C3 port of test/runner.zig: the integration fixture runner.
//
// Faithfully ported from the Zig runner:
//   * Case / case_from_file / trailing_lines: manifest parsing
//     (`/** manifest:` ... last `*/`, kind line, `key = value` options until the
//     first blank line, trailing data afterwards).
//   * run_case_extra: runs the compiler in the case's directory with
//     `<exe> -fno-color-diagnostics <basename>` + kind flags + manifest args,
//     manifest env overriding the inherited environment, then checks ordered
//     diagnostic substrings and the exact AST / expanded output.
//   * expand_partial checks that stdout ENDS WITH the expected file, matching
//     runner.zig and the test/README.MD description.
//   * compare_output is not implemented and is counted as `unsupported`.
//
// Additions for migration gates (not in runner.zig): per-case outcome
// records (exit status, signal, fatal diagnostic, byte counts), explicit case
// lists with expected outcomes, full-corpus classification and a gate mode
// that compares complete outcomes instead of accepting any nonzero exit.
//
// Nothing is normalized: diagnostics, AST and expansion output are compared
// byte for byte. Environment-dependent paths are avoided by construction
// (the child runs with the case directory as CWD and gets the case basename).
//
// Process handling uses explicit host implementations: POSIX uses
// posix_spawn + addchdir_np + pipes + poll + waitpid, and Windows uses
// CreateProcessW + inheritable pipes + PeekNamedPipe. Both preserve argv,
// child CWD, replacement environments, and concurrent output collection.
module aro_runner;
import std::io, std::io::path, std::os::env, std::collections::list, std::sort;
import libc, std::os::posix, std::net::os, std::os::win32, std::thread;

// ---------------------------------------------------------------------------
// Faults (names follow the Zig error set of runner.zig)
// ---------------------------------------------------------------------------

excuse
{
	INVALID_NAME,
	TEST_MANIFEST_MISSING,
	UNTERMINATED_MANIFEST,
	TEST_MANIFEST_MISSING_TYPE,
	TEST_MANIFEST_INVALID_TYPE,
	TEST_MANIFEST_MISSING_VALUE,
	TEST_MANIFEST_UNKNOWN_OPTION,
	CASE_READ_FAILED,
	SPAWN_FAILED,
	CRASHED,
	MISSING_ERROR,
	MISMATCHED_ERRORS,
	OUTPUT_MISMATCH,
	GOLDEN_UNREADABLE,
	CASE_LIST_INVALID,
	CASE_LIST_EMPTY,
	CASE_LIST_NONEXISTENT,
	CASE_LIST_UNCLASSIFIED,
	CASES_DIR_UNREADABLE,
}

// ---------------------------------------------------------------------------
// Case
// ---------------------------------------------------------------------------

enum CaseKind
{
	SYNTAX,               // -fsyntax-only --verbose-ast, check errors + optional ast/<name>
	SYNTAX_IGNORE_ERRORS, // -fsyntax-only --verbose-ast, ignore errors, optional ast/<name>
	EXPAND_ERROR,         // -E -P, check errors only
	EXPAND,               // -E -P, check errors + exact expanded/<name>
	EXPAND_PARTIAL,       // -E -P, check errors + stdout ends with expanded/<name>
	COMPARE_OUTPUT,       // unimplemented in runner.zig: counted as unsupported
}

const String[*] KIND_NAMES = { "syntax", "syntax_ignore_errors", "expand_error", "expand", "expand_partial", "compare_output" };

fn String CaseKind.name(self) => KIND_NAMES[self.ordinal];

struct EnvPair
{
	String key;
	String value;
}

struct Case
{
	String name;
	CaseKind kind;
	String[] skips;
	String[] args;
	EnvPair[] env;
	// Trailing lines for syntax / expand_error / expand / expand_partial.
	String[] expected_errors;
	// Trailing data for compare_output.
	String expected_output;
}

// Zig's std.mem.find semantics: an empty needle is always found.
fn bool contains(String haystack, String needle)
{
	if (needle.len == 0) return true;
	if (needle.len > haystack.len) return false;
	for (sz i = 0; i + needle.len <= haystack.len; i++)
	{
		if (haystack[i:needle.len] == needle) return true;
	}
	return false;
}

fn sz? find_first(String haystack, String needle)
{
	if (needle.len > haystack.len) return NOT_FOUND~;
	for (sz i = 0; i + needle.len <= haystack.len; i++)
	{
		if (haystack[i:needle.len] == needle) return i;
	}
	return NOT_FOUND~;
}

fn sz? find_last(String haystack, String needle)
{
	if (needle.len > haystack.len) return NOT_FOUND~;
	sz i = haystack.len - needle.len + 1;
	while (i > 0)
	{
		i--;
		if (haystack[i:needle.len] == needle) return i;
	}
	return NOT_FOUND~;
}

fn bool is_one_of(char c, String set)
{
	foreach (s : set) if (s == c) return true;
	return false;
}

fn String trim_set(String s, String set) => trim_end_set(trim_start_set(s, set), set);

fn String trim_start_set(String s, String set)
{
	sz start = 0;
	while (start < s.len && is_one_of(s[start], set)) start++;
	return s[start..];
}

fn String trim_end_set(String s, String set)
{
	sz end = s.len;
	while (end > 0 && is_one_of(s[end - 1], set)) end--;
	return s[:end];
}

// std.mem.splitScalar: yields every segment, including empty ones.
struct LineSplitter
{
	String buffer;
	sz index;
	bool done;
	char delimiter;
}

fn LineSplitter split_scalar(String buffer, char delimiter) => { .buffer = buffer, .delimiter = delimiter };

fn String? LineSplitter.next(&self)
{
	if (self.done) return NO_MORE_ELEMENT~;
	sz start = self.index;
	for (sz i = start; i < self.buffer.len; i++)
	{
		if (self.buffer[i] == self.delimiter)
		{
			self.index = i + 1;
			return self.buffer[start:i - start];
		}
	}
	self.done = true;
	return self.buffer[start..];
}

fn String LineSplitter.rest(&self) => self.done ? "" : self.buffer[self.index..];

// std.mem.tokenizeScalar: yields only non-empty segments.
fn String[] tokenize_scalar(Allocator a, String buffer, char delimiter)
{
	List{String} out;
	out.init(a);
	LineSplitter it = split_scalar(buffer, delimiter);
	while (try part = it.next())
	{
		if (part.len) out.push(part);
	}
	return out.array_view();
}

// Host path helpers. Manifest paths are portable slash paths, while paths
// supplied by the host (test temp dirs, cwd and runfiles) use native syntax.
fn bool is_path_separator(char c)
{
	$if env::WIN32:
		return c == '/' || c == '\\';
	$else
		return c == '/';
	$endif
}

fn char native_path_separator()
{
	$if env::WIN32:
		return '\\';
	$else
		return '/';
	$endif
}

fn String basename(String p)
{
	sz end = p.len;
	while (end > 0 && is_path_separator(p[end - 1])) end--;
	String t = p[:end];
	for (sz i = t.len; i > 0; i--)
	{
		if (is_path_separator(t[i - 1])) return t[i..];
	}
	return t;
}

fn String stem(String p)
{
	String b = basename(p);
	if (try idx = find_last(b, "."))
	{
		if (idx == 0) return b;
		return b[:idx];
	}
	return b;
}

fn String dirname(String p)
{
	$if env::WIN32:
		// Preserve a drive root after trimming any extra trailing separators.
		if (p.len >= 3 && p[1] == ':' && is_path_separator(p[2]))
		{
			sz end = p.len;
			while (end > 3 && is_path_separator(p[end - 1])) end--;
			if (end == 3) return p[:3];
		}
	$endif
	sz end = p.len;
	while (end > 1 && is_path_separator(p[end - 1])) end--;
	String t = p[:end];
	for (sz i = t.len; i > 0; i--)
	{
		if (is_path_separator(t[i - 1]))
		{
			if (i == 1) return t[:1];
			$if env::WIN32:
				if (i == 3 && t[1] == ':') return t[:3];
			$endif
			return t[:i - 1];
		}
	}
	return ".";
}

fn String join_path(Allocator a, String dir, String name)
{
	if (dir.len == 0) return name.copy(a);
	if (is_path_separator(dir[^1])) return string::format(a, "%s%s", dir, name);
	return string::format(a, "%s%c%s", dir, native_path_separator(), name);
}

<*
 Parses the manifest out of the contents of a case file (runner.zig caseFromFile,
 minus the file read). Diagnostics are appended to `log` exactly as the Zig
 runner prints them.
*>
fn Case? case_from_contents(Allocator a, String name, String contents, DString* log)
{
	const String START_KEY = "/** manifest:";
	const String END_KEY = "*/";
	sz? start = find_first(contents, START_KEY);
	if (catch start)
	{
		log.appendf("%s: no test manifest\n", name);
		return TEST_MANIFEST_MISSING~;
	}
	sz? end = find_last(contents, END_KEY);
	// The Zig runner slices contents[start + key.len .. end] unchecked, which
	// panics if the last `*/` precedes the manifest; report it as unterminated.
	if (catch end)
	{
		log.appendf("%s: unterminated manifest\n", name);
		return UNTERMINATED_MANIFEST~;
	}
	if (end < start + START_KEY.len)
	{
		log.appendf("%s: unterminated manifest\n", name);
		return UNTERMINATED_MANIFEST~;
	}
	String manifest = trim_set(contents[start + START_KEY.len .. end - 1], " \t\n\r");

	List{String} skips;
	skips.init(a);
	String[] args = {};
	EnvPair[] envs = {};

	LineSplitter it = split_scalar(manifest, '\n');

	String? first = it.next();
	if (catch first)
	{
		log.appendf("%s: test case type not specified\n", name);
		return TEST_MANIFEST_MISSING_TYPE~;
	}
	String kind_name = trim_set(first, " \t\r");
	CaseKind kind;
	bool found_kind = false;
	foreach (i, kn : KIND_NAMES)
	{
		if (kn == kind_name)
		{
			kind = (CaseKind)i;
			found_kind = true;
			break;
		}
	}
	if (!found_kind)
	{
		log.appendf("%s: invalid test case type: %s\n", name, kind_name);
		return TEST_MANIFEST_INVALID_TYPE~;
	}

	while (try line = it.next())
	{
		String trimmed = trim_set(line, " \t\r");
		if (trimmed.len == 0) break; // Start of trailing data.

		sz? eq = find_first(trimmed, "=");
		if (catch eq)
		{
			log.appendf("%s: missing value for config option: %s\n", name, trimmed);
			return TEST_MANIFEST_MISSING_VALUE~;
		}
		String key = trim_end_set(trimmed[:eq], " \t");
		String value = trim_start_set(trimmed[eq + 1..], " \t");
		switch (key)
		{
			case "skip":
				skips.push(value.copy(a));
			case "args":
				args = tokenize_scalar(a, value, ' ');
			case "env":
				List{EnvPair} buf;
				buf.init(a);
				foreach (env_kv : tokenize_scalar(a, value, ' '))
				{
					sz? keq = find_first(env_kv, "=");
					if (catch keq)
					{
						log.appendf("%s: invalid env key value pair: %s\n", name, env_kv);
						continue;
					}
					buf.push({ .key = env_kv[:keq], .value = env_kv[keq + 1..] });
				}
				envs = buf.array_view();
			default:
				log.appendf("%s: unknown config option: %s\n", name, key);
				return TEST_MANIFEST_UNKNOWN_OPTION~;
		}
	}

	Case c = {
		.name = name,
		.kind = kind,
		.skips = skips.array_view(),
		.args = args,
		.env = envs,
	};
	switch (kind)
	{
		case SYNTAX:
		case EXPAND_ERROR:
		case EXPAND:
		case EXPAND_PARTIAL:
			c.expected_errors = trailing_lines(a, &it);
		case SYNTAX_IGNORE_ERRORS:
			break;
		case COMPARE_OUTPUT:
			c.expected_output = it.rest();
	}
	return c;
}

fn String[] trailing_lines(Allocator a, LineSplitter* it)
{
	List{String} buf;
	buf.init(a);
	while (try line = it.next())
	{
		buf.push(trim_set(line, " \t\r"));
	}
	return buf.array_view();
}

fn Case? case_from_file(Allocator a, String path, DString* log)
{
	String name = stem(path);
	char[]? contents = file::load(a, path);
	if (catch err = contents)
	{
		log.appendf("%s: unable to read '%s': %s\n", name, path, err);
		return CASE_READ_FAILED~;
	}
	return case_from_contents(a, name, (String)contents, log);
}

// ---------------------------------------------------------------------------
// Child process execution (host implementations)
// ---------------------------------------------------------------------------

extern fn CInt posix_spawn_file_actions_addchdir_np(Posix_spawn_file_actions_t* actions, ZString path) @feat(POSIX);
extern fn CInt posix_spawn_file_actions_addopen(Posix_spawn_file_actions_t* actions, CInt fd, ZString path, CInt oflag, CUInt mode) @feat(POSIX);
extern fn Win32_WCHAR* getEnvironmentStringsW() @cname("GetEnvironmentStringsW") @feat(WIN32);
extern fn Win32_BOOL freeEnvironmentStringsW(Win32_WCHAR* block) @cname("FreeEnvironmentStringsW") @feat(WIN32);
extern fn Win32_HANDLE createFileW(Win32_LPCWSTR name, Win32_DWORD access, Win32_DWORD share,
	Win32_LPSECURITY_ATTRIBUTES security, Win32_DWORD disposition, Win32_DWORD flags,
	Win32_HANDLE template) @cname("CreateFileW") @feat(WIN32);

const int F_SETFD @feat(POSIX) = 2;
const int FD_CLOEXEC @feat(POSIX) = 1;
const int F_GETFL @feat(POSIX) = 3;
const int F_SETFL @feat(POSIX) = 4;
const int CHILD_O_NONBLOCK @feat(POSIX) = $feat(DARWIN) ? 0x04 : 0x0800;
const Win32_DWORD GENERIC_READ @feat(WIN32) = 0x80000000;
const Win32_DWORD FILE_SHARE_READ @feat(WIN32) = 1;
const Win32_DWORD FILE_SHARE_WRITE @feat(WIN32) = 2;

struct ChildResult
{
	bool spawned;
	bool exited;     // terminated normally
	int exit_code;   // valid when exited
	int signal;      // POSIX signal; -1 when abnormal termination has no signal code
	String stdout;
	String stderr;
	long max_rss_kib; // -1 when unavailable or not portable across hosts.
}

fn void drain_into(CInt fd, DString* out, bool* open) @feat(POSIX)
{
	char[16384] buf;
	sz n = libc::read((Fd)fd, &buf, buf.len);
	if (n > 0)
	{
		out.append_bytes(buf[:n]);
		return;
	}
	if (n < 0 && (libc::errno() == EINTR || libc::errno() == EAGAIN)) return;
	// EOF or hard error: stop polling this descriptor.
	libc::close(fd);
	*open = false;
}

fn void close_fd_pair(CInt read_fd, CInt write_fd) @feat(POSIX)
{
	libc::close(read_fd);
	libc::close(write_fd);
}

fn bool set_cloexec(CInt fd) @feat(POSIX)
{
	return libc::fcntl((Fd)fd, F_SETFD, FD_CLOEXEC) == 0;
}

fn bool set_nonblocking(CInt fd) @feat(POSIX)
{
	CInt flags = libc::fcntl((Fd)fd, F_GETFL);
	return flags >= 0 && libc::fcntl((Fd)fd, F_SETFL, flags | CHILD_O_NONBLOCK) == 0;
}

<* POSIX host implementation for Linux and macOS. waitpid omits rusage:
 Linux reports KiB while Darwin reports bytes, so RSS is unavailable rather
 than mislabeled or dependent on a handwritten host ABI struct. *>
fn ChildResult run_child_posix(Allocator a, String[] argv, String cwd, String[] environment) @feat(POSIX)
{
	ChildResult r = { .max_rss_kib = -1 };
	Posix_spawn_file_actions_t actions;
	if (posix::spawn_file_actions_init(&actions)) return r;
	defer posix::spawn_file_actions_destroy(&actions);
	CInt[2] outp;
	CInt[2] errp;
	if (posix::pipe(&outp)) return r;
	if (!set_cloexec(outp[0]) || !set_cloexec(outp[1]) || !set_nonblocking(outp[0]))
	{
		close_fd_pair(outp[0], outp[1]);
		return r;
	}
	if (posix::pipe(&errp))
	{
		close_fd_pair(outp[0], outp[1]);
		return r;
	}
	if (!set_cloexec(errp[0]) || !set_cloexec(errp[1]) || !set_nonblocking(errp[0]))
	{
		close_fd_pair(outp[0], outp[1]);
		close_fd_pair(errp[0], errp[1]);
		return r;
	}
	ZString* c_argv = mem::alloc_array(ZString, argv.len + 1);
	defer mem::free(c_argv);
	ZString* c_env = mem::alloc_array(ZString, environment.len + 1);
	defer mem::free(c_env);
	Pid_t pid;
	CInt spawn_err = 0;
	@pool()
	{
		foreach (i, s : argv) c_argv[i] = s.zstr_tcopy();
		c_argv[argv.len] = null;
		foreach (i, s : environment) c_env[i] = s.zstr_tcopy();
		c_env[environment.len] = null;
		spawn_err = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", libc::O_RDONLY, 0);
		if (!spawn_err) spawn_err = posix::spawn_file_actions_adddup2(&actions, outp[1], 1);
		if (!spawn_err) spawn_err = posix::spawn_file_actions_adddup2(&actions, errp[1], 2);
		if (!spawn_err && cwd.len) spawn_err = posix_spawn_file_actions_addchdir_np(&actions, cwd.zstr_tcopy());
		if (!spawn_err) spawn_err = posix::spawn(&pid, c_argv[0], &actions, null, c_argv, c_env);
	};
	libc::close(outp[1]);
	libc::close(errp[1]);
	if (spawn_err)
	{
		libc::close(outp[0]);
		libc::close(errp[0]);
		return r;
	}
	r.spawned = true;
	DString out;
	out.init(a);
	DString err;
	err.init(a);
	bool out_open = true;
	bool err_open = true;
	while (out_open || err_open)
	{
		Posix_pollfd[2] fds;
		Posix_nfds_t n = 0;
		if (out_open) fds[n++] = { .fd = outp[0], .events = os::POLLIN };
		if (err_open) fds[n++] = { .fd = errp[0], .events = os::POLLIN };
		CInt rc = os::poll(&fds, n, -1);
		if (rc < 0)
		{
			if (libc::errno() == EINTR) continue;
			// The descriptors are nonblocking, so keep servicing both until EOF.
			while (out_open || err_open)
			{
				if (out_open) { drain_into(outp[0], &out, &out_open); }
				if (err_open) { drain_into(errp[0], &err, &err_open); }
				thread::sleep_ms(1);
			}
			break;
		}
		for (Posix_nfds_t i = 0; i < n; i++)
		{
			if (!fds[i].revents) continue;
			if (fds[i].fd == outp[0]) { drain_into(outp[0], &out, &out_open); }
			else { drain_into(errp[0], &err, &err_open); }
		}
	}
	CInt status;
	while (true)
	{
		Pid_t w = posix::waitpid(pid, &status, 0);
		if (w == pid) break;
		if (w < 0 && libc::errno() == EINTR) continue;
		r.signal = -1;
		r.stdout = out.str_view();
		r.stderr = err.str_view();
		return r;
	}
	if (posix::wIFEXITED(status))
	{
		r.exited = true;
		r.exit_code = posix::wEXITSTATUS(status);
	}
	else if (posix::wIFSIGNALED(status)) { r.signal = posix::wTERMSIG(status); }
	else { r.signal = -1; }
	r.stdout = out.str_view();
	r.stderr = err.str_view();
	return r;
}

fn void append_windows_arg(DString* line, String arg) @feat(WIN32)
{
	line.append_char('"');
	sz slashes = 0;
	foreach (c : arg)
	{
		if (c == '\\')
		{
			slashes++;
			continue;
		}
		if (c == '"')
		{
			line.append_char_repeat('\\', slashes * 2 + 1);
			line.append_char('"');
		}
		else
		{
			line.append_char_repeat('\\', slashes);
			line.append_char(c);
		}
		slashes = 0;
	}
	line.append_char_repeat('\\', slashes * 2);
	line.append_char('"');
}

fn void append_windows_output(Win32_HANDLE handle, DString* out, bool* open) @feat(WIN32)
{
	Win32_DWORD available = 0;
	if (!win32::peekNamedPipe(handle, null, 0, null, &available, null))
	{
		win32::closeHandle(handle);
		*open = false;
		return;
	}
	if (!available) return;
	char[16384] buffer;
	Win32_DWORD nread = 0;
	Win32_DWORD request = available < buffer.len ? available : (Win32_DWORD)buffer.len;
	if (win32::readFile(handle, &buffer, request, &nread, null) && nread)
	{
		out.append_bytes(buffer[:nread]);
		return;
	}
	win32::closeHandle(handle);
	*open = false;
}

<* Win32 host implementation. Windows has process exit codes, not POSIX
 signals; unhandled NTSTATUS exception codes are recorded as abnormal with
 signal=-1 (unavailable), never as fabricated POSIX signal numbers. *>
fn ChildResult run_child_windows(Allocator a, String[] argv, String cwd, String[] environment) @feat(WIN32)
{
	ChildResult r = { .max_rss_kib = -1 };
	if (!argv.len) return r;
	Win32_SECURITY_ATTRIBUTES sa = { .nLength = Win32_SECURITY_ATTRIBUTES::size, .bInheritHandle = 1 };
	Win32_HANDLE out_read, out_write, err_read, err_write;
	if (!win32::createPipe(&out_read, &out_write, &sa, 0)) return r;
	if (!win32::setHandleInformation(out_read, win32::HANDLE_FLAG_INHERIT, 0))
	{
		win32::closeHandle(out_read);
		win32::closeHandle(out_write);
		return r;
	}
	if (!win32::createPipe(&err_read, &err_write, &sa, 0))
	{
		win32::closeHandle(out_read);
		win32::closeHandle(out_write);
		return r;
	}
	if (!win32::setHandleInformation(err_read, win32::HANDLE_FLAG_INHERIT, 0))
	{
		win32::closeHandle(out_read);
		win32::closeHandle(out_write);
		win32::closeHandle(err_read);
		win32::closeHandle(err_write);
		return r;
	}
	Win32_HANDLE null_input = createFileW(@wstring("NUL"), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
		&sa, win32::OPEN_EXISTING, win32::FILE_ATTRIBUTE_NORMAL, null);
	if (null_input == win32::INVALID_HANDLE_VALUE)
	{
		win32::closeHandle(out_read);
		win32::closeHandle(out_write);
		win32::closeHandle(err_read);
		win32::closeHandle(err_write);
		return r;
	}
	Win32_STARTUPINFOW startup = {
		.cb = Win32_STARTUPINFOW::size,
		.dwFlags = win32::STARTF_USESTDHANDLES,
		.hStdInput = null_input,
		.hStdOutput = out_write,
		.hStdError = err_write,
	};
	Win32_PROCESS_INFORMATION info;
	DString command;
	command.init(a);
	foreach (i, arg : argv)
	{
		if (i) command.append_char(' ');
		append_windows_arg(&command, arg);
	}
	WString command_line = command.str_view().to_wstring(a)!!;
	WString application = argv[0].to_wstring(a)!!;
	WString directory = cwd.len ? cwd.to_wstring(a)!! : null;
	DString env_block;
	env_block.init(a);
	foreach (entry : environment)
	{
		env_block.append(entry);
		env_block.append_char('\0');
	}
	if (!environment.len) env_block.append_char('\0');
	WString win_env = env_block.str_view().to_wstring(a)!!;
	if (!win32::createProcessW(application, command_line, null, null, 1,
		win32::CREATE_UNICODE_ENVIRONMENT, win_env, directory, &startup, &info))
	{
		win32::closeHandle(null_input);
		win32::closeHandle(out_read);
		win32::closeHandle(out_write);
		win32::closeHandle(err_read);
		win32::closeHandle(err_write);
		return r;
	}
	r.spawned = true;
	win32::closeHandle(info.hThread);
	win32::closeHandle(null_input);
	win32::closeHandle(out_write);
	win32::closeHandle(err_write);
	DString out;
	out.init(a);
	DString err;
	err.init(a);
	bool out_open = true;
	bool err_open = true;
	while (out_open || err_open)
	{
		if (out_open) append_windows_output(out_read, &out, &out_open);
		if (err_open) append_windows_output(err_read, &err, &err_open);
		win32::sleep(1);
	}
	Win32_DWORD wait_result = win32::waitForSingleObject(info.hProcess, win32::INFINITE);
	Win32_DWORD exit_code;
	if (wait_result == win32::WAIT_OBJECT_0 && win32::getExitCodeProcess(info.hProcess, &exit_code))
	{
		if (exit_code >= 0xC0000000) { r.signal = -1; }
		else
		{
			r.exited = true;
			r.exit_code = (int)exit_code;
		}
	}
	else { r.signal = -1; }
	win32::closeHandle(info.hProcess);
	r.stdout = out.str_view();
	r.stderr = err.str_view();
	return r;
}

fn ChildResult run_child(Allocator a, String[] argv, String cwd, String[] environment)
{
	$switch:
	$case env::WIN32:
		return run_child_windows(a, argv, cwd, environment);
	$case env::POSIX:
		return run_child_posix(a, argv, cwd, environment);
	$default:
		return { .max_rss_kib = -1 };
	$endswitch
}

<*
 The runner's inherited environment as "K=V" strings, with the case's
 `env` entries replacing (or adding) keys, like Environ.Map.put in runner.zig.
*>
fn bool env_name_equal(String a, String b, bool windows)
{
	if (a.len != b.len) return false;
	for (sz i = 0; i < a.len; i++)
	{
		char x = a[i];
		char y = b[i];
		if (windows)
		{
			if (x >= 'A' && x <= 'Z') x += 32;
			if (y >= 'A' && y <= 'Z') y += 32;
		}
		if (x != y) return false;
	}
	return true;
}

fn String environment_key(String entry)
{
	if (try eq = find_first(entry, "=")) return entry[:eq];
	return entry;
}

fn int compare_windows_environment(String a, String b)
{
	String x = environment_key(a);
	String y = environment_key(b);
	sz n = min(x.len, y.len);
	for (sz i = 0; i < n; i++)
	{
		char cx = x[i];
		char cy = y[i];
		if (cx >= 'A' && cx <= 'Z') cx += 32;
		if (cy >= 'A' && cy <= 'Z') cy += 32;
		if (cx < cy) return -1;
		if (cx > cy) return 1;
	}
	if (x.len < y.len) return -1;
	if (x.len > y.len) return 1;
	return 0;
}

fn bool override_has_key(EnvPair[] overrides, String key, bool windows)
{
	foreach (kv : overrides) if (env_name_equal(kv.key, key, windows)) return true;
	return false;
}

fn String[] append_overrides(Allocator a, List{String}* out, EnvPair[] overrides, bool windows)
{
	foreach (i, kv : overrides)
	{
		bool later = false;
		for (sz j = i + 1; j < overrides.len; j++)
		{
			if (env_name_equal(overrides[j].key, kv.key, windows)) later = true;
		}
		if (!later) out.push(string::format(a, "%s=%s", kv.key, kv.value));
	}
	return out.array_view();
}

fn String[] child_environment_posix(Allocator a, EnvPair[] overrides) @feat(POSIX)
{
	List{String} out;
	out.init(a);
	ZString* e = posix::environ;
	for (sz i = 0; e && e[i]; i++)
	{
		String entry = e[i].str_view();
		String key = entry;
		if (try eq = find_first(entry, "=")) key = entry[:eq];
		if (!override_has_key(overrides, key, false)) out.push(entry);
	}
	return append_overrides(a, &out, overrides, false);
}

fn String[] child_environment_windows(Allocator a, EnvPair[] overrides) @feat(WIN32)
{
	List{String} out;
	out.init(a);
	Win32_WCHAR* block = getEnvironmentStringsW();
	if (block)
	{
		sz i = 0;
		while (block[i])
		{
			WString entry_ptr = (WString)&block[i];
			sz entry_len16 = (sz)win32::wcslen(entry_ptr);
			String entry = string::from_wstring(a, entry_ptr)!!;
			String key = entry;
			if (try eq = find_first(entry, "=")) key = entry[:eq];
			// Windows pseudo variables such as =C:=C:\\ are inherited intact.
			if (!override_has_key(overrides, key, true)) out.push(entry);
			i += entry_len16 + 1;
		}
		(void)freeEnvironmentStringsW(block);
	}
	String[] result = append_overrides(a, &out, overrides, true);
	quicksort(result, &compare_windows_environment);
	return result;
}

fn String[] child_environment(Allocator a, EnvPair[] overrides)
{
	$switch:
	$case env::WIN32:
		return child_environment_windows(a, overrides);
	$case env::POSIX:
		return child_environment_posix(a, overrides);
	$default:
		List{String} out;
		out.init(a);
		return append_overrides(a, &out, overrides, false);
	$endswitch
}

// ---------------------------------------------------------------------------
// Running one case
// ---------------------------------------------------------------------------

enum CaseStatus
{
	PASS,
	FAIL,
	UNSUPPORTED,
}

const String[*] STATUS_NAMES = { "pass", "fail", "unsupported" };
fn String CaseStatus.name(self) => STATUS_NAMES[self.ordinal];

struct CaseOutcome
{
	String path;
	String name;
	CaseStatus status;
	fault failure;        // why it failed (when status == FAIL)
	bool ran;             // the child process was spawned and reaped
	bool exited;
	int exit_code;
	int signal;
	bool fatal;           // stderr contains a `fatal error: ` diagnostic
	sz stdout_len;
	sz stderr_len;
	uint skips;           // known skips (counted only when the case passes)
	long max_rss_kib;
	String command;       // space-joined argv, for crash reports
	DString log;          // messages runner.zig would print for this case
}

fn bool has_fatal(String stderr)
{
	LineSplitter it = split_scalar(stderr, '\n');
	while (try line = it.next())
	{
		if (contains(line, "fatal error: ")) return true;
	}
	return false;
}

// Appends s to log with NUL and other C0 control bytes escaped, so captured
// child output cannot truncate the log. Logging only; comparisons use raw bytes.
fn void append_escaped(DString* log, String s)
{
	const String HEX = "0123456789abcdef";
	for (usz i = 0; i < s.len; i++)
	{
		char c = s[i];
		if (c == 0) { log.append_char('\\'); log.append_char('0'); }
		else if (c < 0x20 && c != '\n' && c != '\t' && c != '\r')
		{
			log.append_char('\\'); log.append_char('x');
			log.append_char(HEX[(usz)c >> 4]); log.append_char(HEX[(usz)c & 15]);
		}
		else
		{
			log.append_char(c);
		}
	}
}

fn void report_strings_mismatch(DString* log, String expected, String actual)
{
	log.appendf("\n====== expected this output: =========\n");
	append_escaped(log, expected);
	log.appendf("␃\n\n======== instead found this: =========\n");
	append_escaped(log, actual);
	log.appendf("␃\n\n======================================\n");
	sz i = 0;
	while (i < expected.len && i < actual.len && expected[i] == actual[i]) i++;
	log.appendf("First difference occurs at byte %d\n", i);
}

<*
 Runs one case file with `exe` (absolute path, or relative to the runner's CWD).
 Mirrors runner.zig runCase/runCaseExtra; the result is recorded instead of
 being reduced to an error union.
*>
fn CaseOutcome run_case(Allocator a, String case_path, String exe)
{
	CaseOutcome o = { .path = case_path, .name = stem(case_path), .max_rss_kib = -1 };
	o.log.init(a);
	if (catch f = run_case_extra(a, case_path, exe, &o))
	{
		o.status = FAIL;
		o.failure = f;
	}
	return o;
}

fn String absolute_from_cwd(Allocator a, String p)
{
	bool absolute = p.len > 0 && is_path_separator(p[0]);
	$if env::WIN32:
		absolute = absolute || (p.len >= 3 && p[1] == ':' && is_path_separator(p[2]));
		absolute = absolute || (p.len >= 2 && is_path_separator(p[0]) && is_path_separator(p[1]));
	$endif
	if (absolute) return p.copy(a);
	Path? cwd = path::cwd(a);
	if (catch cwd) return p.copy(a);
	return join_path(a, (String)cwd, p);
}

fn void? run_case_extra(Allocator a, String path, String exe, CaseOutcome* o)
{
	DString* log = &o.log;
	if (!path.ends_with(".c"))
	{
		log.appendf("test case is not a .c file: '%s'\n", path);
		return INVALID_NAME~;
	}
	String cases_dir = dirname(path);
	Case c = case_from_file(a, path, log)!;

	String[] kind_args;
	switch (c.kind)
	{
		case SYNTAX:
		case SYNTAX_IGNORE_ERRORS:
			kind_args = { "-fsyntax-only", "--verbose-ast" };
		case EXPAND_ERROR:
		case EXPAND:
		case EXPAND_PARTIAL:
			kind_args = { "-E", "-P" };
		case COMPARE_OUTPUT:
			log.appendf("%s: TODO compare output\n", c.name);
			o.status = UNSUPPORTED;
			return;
	}

	// runner.zig passes the exe relative to the cases dir; an absolute path is
	// equivalent and survives the child's chdir.
	List{String} args;
	args.init(a);
	args.push(absolute_from_cwd(a, exe));
	args.push("-fno-color-diagnostics");
	args.push(basename(path));
	args.push_all(kind_args);
	args.push_all(c.args);
	o.command = string::join(a, args.array_view(), " ");

	ChildResult r = run_child(a, args.array_view(), cases_dir, child_environment(a, c.env));
	if (!r.spawned)
	{
		log.appendf("unable to spawn arocc command:\n%s\n", o.command);
		return SPAWN_FAILED~;
	}
	o.ran = true;
	o.exited = r.exited;
	o.exit_code = r.exit_code;
	o.signal = r.signal;
	o.stdout_len = r.stdout.len;
	o.stderr_len = r.stderr.len;
	o.max_rss_kib = r.max_rss_kib;
	o.fatal = has_fatal(r.stderr);
	if (!r.exited)
	{
		log.appendf("arocc command crashed:\n%s\n", o.command);
		return CRASHED~;
	}
	String stdout = r.stdout;
	String stderr = r.stderr;

	switch (c.kind)
	{
		case SYNTAX:
		case EXPAND_ERROR:
		case EXPAND:
		case EXPAND_PARTIAL:
			String[] expected_errors = c.expected_errors;
			List{String} actual_errors;
			actual_errors.init(a);
			foreach (msg : tokenize_scalar(a, stderr, '\n'))
			{
				if (!contains(msg, "error: ") && !contains(msg, "warning: ") && !contains(msg, "note: ")) continue;
				if (msg == "note: --sysroot may be required when cross-compiling to Darwin targets") continue;
				actual_errors.push(msg);
			}
			sz len = min(expected_errors.len, actual_errors.len());
			for (sz i = 0; i < len; i++)
			{
				if (!contains(actual_errors[i], expected_errors[i]))
				{
					log.appendf("\n======= expected to find error =======\n%s\n\n=== but output does not contain it ===\n", expected_errors[i]);
					append_escaped(log, stderr);
					log.appendf("\n\nin case '%s'\n", c.name);
					return MISSING_ERROR~;
				}
			}
			if (expected_errors.len != actual_errors.len())
			{
				foreach (expected : expected_errors[len..])
				{
					log.appendf("\n======= expected to find error =======\n%s\n\n=== but output does not contain it ===\n", expected);
					append_escaped(log, stderr);
				}
				foreach (actual : actual_errors.array_view()[len..])
				{
					log.appendf("\n========= new error ==========\n");
					append_escaped(log, actual);
					log.appendf("\n\n=== not in expected errors ===\n");
				}
				log.appendf("in case '%s'\n", c.name);
				return MISMATCHED_ERRORS~;
			}
		case COMPARE_OUTPUT:
			unreachable("compare_output returns before running");
		case SYNTAX_IGNORE_ERRORS:
			break;
	}

	switch (c.kind)
	{
		case SYNTAX:
		case SYNTAX_IGNORE_ERRORS:
			String ast_path = join_path(a, join_path(a, cases_dir, "ast"), basename(path));
			if (file::is_file(ast_path))
			{
				char[]? expected = file::load(a, ast_path);
				if (catch err = expected)
				{
					log.appendf("can't open ast file '%s': %s\n", ast_path, err);
					return GOLDEN_UNREADABLE~;
				}
				if ((String)expected != stdout)
				{
					report_strings_mismatch(log, (String)expected, stdout);
					log.appendf("in case '%s'\n", c.name);
					return OUTPUT_MISMATCH~;
				}
			}
			else if (file::exists(ast_path))
			{
				log.appendf("can't open ast file '%s': not a file\n", ast_path);
				return GOLDEN_UNREADABLE~;
			}
			// A missing AST file is not an error (FileNotFound is ignored).
		case EXPAND_ERROR:
			break;
		case EXPAND:
		case EXPAND_PARTIAL:
			String expanded_path = join_path(a, join_path(a, cases_dir, "expanded"), basename(path));
			char[]? expected = file::load(a, expanded_path);
			if (catch err = expected)
			{
				log.appendf("can't open expanded file '%s': %s\n", expanded_path, err);
				return GOLDEN_UNREADABLE~;
			}
			if (c.kind == EXPAND)
			{
				if ((String)expected != stdout)
				{
					report_strings_mismatch(log, (String)expected, stdout);
					log.appendf("in case '%s'\n", c.name);
					return OUTPUT_MISMATCH~;
				}
			}
			else if (!stdout.ends_with((String)expected))
			{
				log.appendf("\n====== expected to end with: =========\n");
				append_escaped(log, (String)expected);
				log.appendf("\n========= but found: ==============\n");
				append_escaped(log, stdout);
				log.appendf("\n");
				log.appendf("in case '%s'\n", c.name);
				return OUTPUT_MISMATCH~;
			}
		case COMPARE_OUTPUT:
			unreachable("compare_output returns before running");
	}

	foreach (skip : c.skips) log.appendf("%s: %s\n", c.name, skip);
	o.skips = (uint)c.skips.len;
	o.status = PASS;
}

// ---------------------------------------------------------------------------
// Case lists (per-stage manifests) and expectations
// ---------------------------------------------------------------------------

<*
 Expected outcome of a case in gate mode. Every field must match the actual
 outcome exactly. Defaults: result=pass exit=0 signal=0, no fatal diagnostic.
*>
struct Expectation
{
	CaseStatus result;
	int exit_code;
	int signal;
	bool fatal;
}

struct CaseEntry
{
	String file;          // file name inside the cases directory
	Expectation expect;
	uint line;
}

<*
 Parses a case list. Format, one entry per line:

   // comment
   <file name ending in .c> [result=pass|fail|unsupported] [exit=N] [signal=N] [fatal]

 The file name extends to the first ".c" followed by whitespace or the end of
 the line, so names may contain spaces ("hello world.c"). Blank lines and
 lines starting with "//" are ignored ('#' cannot mark comments: case names
 such as "#pragma pack msvc.c" start with it). Duplicates and unknown keys
 are errors.
*>
fn CaseEntry[]? parse_case_list(Allocator a, String text, String source, DString* log)
{
	List{CaseEntry} out;
	out.init(a);
	LineSplitter it = split_scalar(text, '\n');
	uint lineno = 0;
	while (try raw = it.next())
	{
		lineno++;
		String line = trim_set(raw, " \t\r");
		if (line.len == 0 || line.starts_with("//")) continue;
		sz name_end = 0;
		bool found = false;
		for (sz i = 0; i + 2 <= line.len; i++)
		{
			if (line[i] == '.' && line[i + 1] == 'c' && (i + 2 == line.len || line[i + 2] == ' ' || line[i + 2] == '\t'))
			{
				name_end = i + 2;
				found = true;
				break;
			}
		}
		if (!found)
		{
			log.appendf("%s:%d: case entry must name a .c file: %s\n", source, lineno, line);
			return CASE_LIST_INVALID~;
		}
		CaseEntry e = { .file = line[:name_end], .line = lineno };
		bool has_path_separator = false;
		foreach (c : e.file)
		{
			if (is_path_separator(c)) has_path_separator = true;
		}
		if (has_path_separator)
		{
			log.appendf("%s:%d: case entry must be a file name inside the cases directory: %s\n", source, lineno, e.file);
			return CASE_LIST_INVALID~;
		}
		foreach (word : tokenize_scalar(a, line[name_end..].trim(), ' '))
		{
			String w = word.trim();
			if (!w.len) continue;
			if (w == "fatal")
			{
				e.expect.fatal = true;
				continue;
			}
			sz? eq = find_first(w, "=");
			if (catch eq)
			{
				log.appendf("%s:%d: unknown expectation '%s'\n", source, lineno, w);
				return CASE_LIST_INVALID~;
			}
			String key = w[:eq];
			String value = w[eq + 1..];
			switch (key)
			{
				case "result":
					switch (value)
					{
						case "pass": e.expect.result = PASS;
						case "fail": e.expect.result = FAIL;
						case "unsupported": e.expect.result = UNSUPPORTED;
						default:
							log.appendf("%s:%d: invalid result '%s'\n", source, lineno, value);
							return CASE_LIST_INVALID~;
					}
				case "exit":
					int? v = value.to_int();
					if (catch v)
					{
						log.appendf("%s:%d: invalid exit status '%s'\n", source, lineno, value);
						return CASE_LIST_INVALID~;
					}
					e.expect.exit_code = v;
				case "signal":
					int? v = value.to_int();
					if (catch v)
					{
						log.appendf("%s:%d: invalid signal '%s'\n", source, lineno, value);
						return CASE_LIST_INVALID~;
					}
					e.expect.signal = v;
				default:
					log.appendf("%s:%d: unknown expectation key '%s'\n", source, lineno, key);
					return CASE_LIST_INVALID~;
			}
		}
		foreach (prev : out)
		{
			if (prev.file == e.file)
			{
				log.appendf("%s:%d: duplicate case entry '%s' (first on line %d)\n", source, lineno, e.file, prev.line);
				return CASE_LIST_INVALID~;
			}
		}
		out.push(e);
	}
	return out.array_view();
}

<*
 Lists the corpus like runner.zig: every regular file directly inside
 `cases_dir` except README.md, sorted by name. Symlinks to regular files
 count as files, because Bazel runfiles trees are made of symlinks.
*>
fn String[]? list_corpus(Allocator a, String cases_dir, DString* log)
{
	PathList? entries = path::ls(a, path::new(a, cases_dir)!!);
	if (catch err = entries)
	{
		log.appendf("unable to open '%s': %s\n", cases_dir, err);
		return CASES_DIR_UNREADABLE~;
	}
	List{String} out;
	out.init(a);
	foreach (p : entries)
	{
		String n = (String)p;
		if (n == "README.md") continue;
		if (!file::is_file(join_path(a, cases_dir, n))) continue;
		out.push(n.copy(a));
	}
	String[] names = out.array_view();
	quicksort(names, fn int(String x, String y) => x.compare_to(y));
	return names;
}

enum SelectMode
{
	CORPUS,    // every file in the directory, no list (runner.zig behavior)
	LIST,      // only the files named in the case list
	FULL,      // every file in the directory, each of which must be listed
}

<*
 Resolves the selection. Fails on nonexistent list entries, on an empty
 selection and (FULL) on corpus files missing from the list.
*>
fn CaseEntry[]? select_cases(Allocator a, String cases_dir, SelectMode mode, CaseEntry[] list, DString* log)
{
	List{CaseEntry} out;
	out.init(a);
	switch (mode)
	{
		case CORPUS:
			foreach (n : list_corpus(a, cases_dir, log)!) out.push({ .file = n });
		case LIST:
		case FULL:
			uint missing = 0;
			foreach (e : list)
			{
				if (!file::is_file(join_path(a, cases_dir, e.file)))
				{
					log.appendf("case list entry does not exist: %s (line %d)\n", e.file, e.line);
					missing++;
				}
			}
			if (missing) return CASE_LIST_NONEXISTENT~;
			if (mode == FULL)
			{
				uint unclassified = 0;
				foreach (n : list_corpus(a, cases_dir, log)!)
				{
					bool listed = false;
					foreach (e : list)
					{
						if (e.file == n)
						{
							listed = true;
							break;
						}
					}
					if (!listed)
					{
						log.appendf("unclassified case: %s\n", n);
						unclassified++;
					}
				}
				if (unclassified) return CASE_LIST_UNCLASSIFIED~;
			}
			out.push_all(list);
	}
	// The original runner accepts an empty corpus (for example, a directory
	// containing only README.md) and reports zero tests. Explicit lists and
	// full-corpus gates still need a non-empty selection to be meaningful.
	if (!out.len() && mode != CORPUS)
	{
		log.appendf("empty case selection in '%s'\n", cases_dir);
		return CASE_LIST_EMPTY~;
	}
	return out.array_view();
}

fn bool outcome_matches(CaseOutcome* o, Expectation e)
{
	if (!o.ran && o.status != UNSUPPORTED) return false; // never ran: incomplete
	if (o.status != e.result) return false;
	if (o.status == UNSUPPORTED) return true;
	if (o.signal != e.signal) return false;
	if (o.exited && o.exit_code != e.exit_code) return false;
	if (o.fatal != e.fatal) return false;
	return true;
}

fn String describe_outcome(Allocator a, CaseOutcome* o)
{
	if (o.status == UNSUPPORTED) return "result=unsupported".copy(a);
	if (!o.ran) return string::format(a, "result=%s (child not run: %s)", o.status.name(), o.failure);
	return string::format(a, "result=%s exit=%s signal=%d%s", o.status.name(),
		o.exited ? string::format(a, "%d", o.exit_code) : "none", o.signal, o.fatal ? " fatal" : "");
}

fn String describe_expectation(Allocator a, Expectation e)
{
	if (e.result == UNSUPPORTED) return "result=unsupported".copy(a);
	return string::format(a, "result=%s exit=%d signal=%d%s", e.result.name(), e.exit_code, e.signal, e.fatal ? " fatal" : "");
}

// ---------------------------------------------------------------------------
// Suites
// ---------------------------------------------------------------------------

struct SuiteOptions
{
	String exe;
	String cases_dir;
	SelectMode mode;
	CaseEntry[] list;
	bool gate;          // compare complete outcomes against expectations
	String log_path;    // optional per-case outcome log (TSV), written after collection
}

struct SuiteReport
{
	bool config_error;  // bad selection / list: nothing meaningful was run
	uint selected;
	uint executed;      // cases whose child ran to completion (incl. crashes)
	uint passed;
	uint failed;
	uint unsupported;   // compare_output
	uint skips;         // known skip entries of passing cases
	uint nonzero_exit;
	uint signaled;
	uint fatal;
	uint gate_mismatches;
	long max_rss_kib;
	bool has_max_rss;
}

<*
 Runs a suite, writing per-case messages to `out` after each case completes
 and returning the report. All per-case memory is released after each case.
*>
fn SuiteReport run_suite(SuiteOptions opts, OutStream out)
{
	SuiteReport rep;
	@pool()
	{
		DString cfg_log;
		cfg_log.init(tmem);
		CaseEntry[]? sel = select_cases(tmem, opts.cases_dir, opts.mode, opts.list, &cfg_log);
		(void)io::fprint(out, cfg_log.str_view());
		if (catch sel)
		{
			rep.config_error = true;
			return rep;
		}
		rep.selected = (uint)sel.len;
		DString tsv;
		tsv.init(tmem);
		tsv.append("case\tresult\texit\tsignal\tfatal\tstdout_bytes\tstderr_bytes\texpected\tgate\n");
		foreach (e : sel)
		{
			@pool()
			{
				String case_path = join_path(tmem, opts.cases_dir, e.file);
				CaseOutcome o = run_case(tmem, case_path, opts.exe);
				(void)io::fprint(out, o.log.str_view());
				switch (o.status)
				{
					case PASS: rep.passed++;
					case FAIL: rep.failed++;
					case UNSUPPORTED: rep.unsupported++;
				}
				if (o.ran) rep.executed++;
				rep.skips += o.skips;
				if (o.ran && o.exited && o.exit_code != 0) rep.nonzero_exit++;
				if (o.ran && !o.exited) rep.signaled++;
				if (o.fatal) rep.fatal++;
				if (o.max_rss_kib >= 0 && (!rep.has_max_rss || o.max_rss_kib > rep.max_rss_kib))
				{
					rep.max_rss_kib = o.max_rss_kib;
					rep.has_max_rss = true;
				}
				bool match = outcome_matches(&o, e.expect);
				if (opts.gate && !match)
				{
					rep.gate_mismatches++;
					(void)io::fprintfn(out, "gate mismatch: %s: expected %s, got %s", e.file,
						describe_expectation(tmem, e.expect), describe_outcome(tmem, &o));
				}
				if (opts.log_path.len)
				{
					tsv.appendf("%s\t%s\t%s\t%d\t%s\t%d\t%d\t%s\t%s\n", e.file, o.status.name(),
						o.ran && o.exited ? string::tformat("%d", o.exit_code) : "none", o.signal,
						o.fatal ? "yes" : "no", o.stdout_len, o.stderr_len,
						describe_expectation(tmem, e.expect), match ? "match" : "MISMATCH");
				}
			};
		}
		if (opts.log_path.len)
		{
			if (catch err = file::save(opts.log_path, tsv.str_view()))
			{
				(void)io::fprintfn(out, "unable to write log '%s': %s", opts.log_path, err);
				rep.config_error = true;
			}
		}
	};
	return rep;
}

fn bool SuiteReport.passed_gate(&self, bool gate)
{
	if (self.config_error) return false;
	if (gate) return self.gate_mismatches == 0;
	return self.failed == 0;
}

fn void SuiteReport.print(&self, OutStream out, bool gate)
{
	if (self.has_max_rss)
	{
		(void)io::fprintfn(out, "max mem used = %d KiB", self.max_rss_kib);
	}
	else
	{
		(void)io::fprintfn(out, "max mem used = unavailable");
	}
	(void)io::fprintfn(out, "selected: %d", self.selected);
	(void)io::fprintfn(out, "executed: %d", self.executed);
	(void)io::fprintfn(out, "passed: %d", self.passed);
	(void)io::fprintfn(out, "failed: %d", self.failed);
	(void)io::fprintfn(out, "unsupported (compare_output): %d", self.unsupported);
	(void)io::fprintfn(out, "known skips: %d", self.skips);
	(void)io::fprintfn(out, "nonzero exit: %d", self.nonzero_exit);
	(void)io::fprintfn(out, "signaled: %d", self.signaled);
	(void)io::fprintfn(out, "fatal diagnostics: %d", self.fatal);
	if (gate) (void)io::fprintfn(out, "gate mismatches: %d", self.gate_mismatches);
	if (self.config_error)
	{
		(void)io::fprintn(out, "RESULT: ERROR (invalid case selection or configuration)");
	}
	else
	{
		(void)io::fprintfn(out, "RESULT: %s", self.passed_gate(gate) ? "PASS" : "FAIL");
	}
}
