// Child processes for the test harness and tools: argv, cwd, environment,
// captured or inherited output, an optional timeout that kills the whole
// process group, and the terminating signal (std::os::process reports neither
// signals nor timeouts and has no cwd option).
module aro_harness;
import std::io, std::io::path, std::os::env, std::collections::list, std::time;
import libc, std::os::posix, std::net::os, std::thread, std::os::process;

extern fn CInt posix_spawn_file_actions_addchdir_np(Posix_spawn_file_actions_t* actions, ZString path) @feat(POSIX);
extern fn CInt posix_spawn_file_actions_addopen(Posix_spawn_file_actions_t* actions, CInt fd, ZString path, CInt oflag, CUInt mode) @feat(POSIX);
extern fn CInt posix_spawnattr_init(Posix_spawnattr_t* attr) @feat(POSIX);
extern fn CInt posix_spawnattr_destroy(Posix_spawnattr_t* attr) @feat(POSIX);
extern fn CInt posix_spawnattr_setflags(Posix_spawnattr_t* attr, short flags) @feat(POSIX);
extern fn CInt posix_spawnattr_setpgroup(Posix_spawnattr_t* attr, Pid_t pgroup) @feat(POSIX);
extern fn CInt access(ZString path, CInt mode) @feat(POSIX);
extern fn CInt sys_fcntl(Fd fd, CInt cmd, ...) @cname("fcntl") @feat(POSIX); // std libc only declares fcntl on BSD before c3c 0.8.6

const short POSIX_SPAWN_SETPGROUP @feat(POSIX) = 2;
const CInt SIGKILL = 9;
const CInt X_OK = 1;
const int F_SETFD @feat(POSIX) = 2;
const int FD_CLOEXEC @feat(POSIX) = 1;
const int F_GETFL @feat(POSIX) = 3;
const int F_SETFL @feat(POSIX) = 4;
const int CHILD_O_NONBLOCK @feat(POSIX) = $feat(DARWIN) ? 0x04 : 0x0800;

struct RunOptions
{
	<* Working directory of the child; empty = inherit. *>
	String cwd;
	<* Full child environment as KEY=VALUE; null = inherit this process's. See env_with. *>
	String[] env;
	<* Kill the child's process group after this many milliseconds; 0 = no limit. *>
	long timeout_ms;
	<* Send the child's stderr into the same capture as stdout (Python stderr=STDOUT). *>
	bool merge_stderr;
	<* Let the child write to this process's stdout/stderr instead of capturing. *>
	bool inherit_stdio;
	<* Search PATH for argv[0] when it has no '/'. *>
	bool search_path;
}

struct RunResult
{
	bool spawned;
	<* Terminated normally; exit_code is valid. *>
	bool exited;
	int exit_code;
	<* Terminating signal, or 0. *>
	int signal;
	bool timed_out;
	String stdout;
	String stderr;
}

<* Exit status in Python's convention: exit code, or -signal when signaled. *>
fn int RunResult.returncode(&self) => self.exited ? self.exit_code : -self.signal;

<* Captured stdout followed by stderr (Python capture_output + concatenation). *>
fn String RunResult.output(&self, Allocator a) => string::format(a, "%s%s", self.stdout, self.stderr);

fn void drain_into(CInt fd, DString* out, bool* open) @feat(POSIX) @local
{
	char[16384] buf;
	sz n = libc::read((Fd)fd, &buf, buf.len);
	if (n > 0)
	{
		out.append_bytes(buf[:n]);
		return;
	}
	if (n < 0 && (libc::errno() == EINTR || libc::errno() == EAGAIN)) return;
	libc::close(fd);
	*open = false;
}

fn bool prepare_pipe(CInt[2]* p) @feat(POSIX) @local
{
	if (posix::pipe(p)) return false;
	if (sys_fcntl((Fd)(*p)[0], F_SETFD, FD_CLOEXEC) || sys_fcntl((Fd)(*p)[1], F_SETFD, FD_CLOEXEC))
	{
		libc::close((*p)[0]);
		libc::close((*p)[1]);
		return false;
	}
	CInt flags = sys_fcntl((Fd)(*p)[0], F_GETFL);
	if (flags < 0 || sys_fcntl((Fd)(*p)[0], F_SETFL, flags | CHILD_O_NONBLOCK))
	{
		libc::close((*p)[0]);
		libc::close((*p)[1]);
		return false;
	}
	return true;
}

<*
 Run `argv` to completion (or until the timeout) and return its status and
 output. Never faults: a child that could not start has spawned == false.
*>
fn RunResult run(Allocator a, String[] argv, RunOptions opts = {}) @feat(POSIX)
{
	RunResult r;
	if (!argv.len) return r;
	Posix_spawn_file_actions_t actions;
	if (posix::spawn_file_actions_init(&actions)) return r;
	defer posix::spawn_file_actions_destroy(&actions);
	Posix_spawnattr_t attr;
	if (posix_spawnattr_init(&attr)) return r;
	defer posix_spawnattr_destroy(&attr);
	// Own process group, so a timeout can kill grandchildren (as/ld/cc) too.
	posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
	posix_spawnattr_setpgroup(&attr, 0);

	CInt[2] outp = { -1, -1 };
	CInt[2] errp = { -1, -1 };
	bool capture = !opts.inherit_stdio;
	if (capture)
	{
		if (!prepare_pipe(&outp)) return r;
		if (!opts.merge_stderr && !prepare_pipe(&errp))
		{
			libc::close(outp[0]);
			libc::close(outp[1]);
			return r;
		}
	}
	String[] environment = opts.env;
	ZString* c_argv = mem::alloc_array(ZString, argv.len + 1);
	defer mem::free(c_argv);
	ZString* c_env = null;
	defer if (c_env) mem::free(c_env);
	Pid_t pid;
	CInt spawn_err = 0;
	@pool()
	{
		foreach (i, s : argv) c_argv[i] = s.zstr_tcopy();
		c_argv[argv.len] = null;
		ZString* envp = posix::environ;
		if (environment.ptr)
		{
			c_env = mem::alloc_array(ZString, environment.len + 1);
			foreach (i, s : environment) c_env[i] = s.zstr_tcopy();
			c_env[environment.len] = null;
			envp = c_env;
		}
		spawn_err = posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", libc::O_RDONLY, 0);
		if (capture)
		{
			if (!spawn_err) spawn_err = posix::spawn_file_actions_adddup2(&actions, outp[1], 1);
			if (!spawn_err) spawn_err = posix::spawn_file_actions_adddup2(&actions, opts.merge_stderr ? outp[1] : errp[1], 2);
		}
		if (!spawn_err && opts.cwd.len) spawn_err = posix_spawn_file_actions_addchdir_np(&actions, opts.cwd.zstr_tcopy());
		if (!spawn_err)
		{
			spawn_err = opts.search_path && !argv[0].contains("/")
				? posix::spawnp(&pid, c_argv[0], &actions, &attr, c_argv, envp)
				: posix::spawn(&pid, c_argv[0], &actions, &attr, c_argv, envp);
		}
	};
	if (capture)
	{
		libc::close(outp[1]);
		if (errp[1] >= 0) libc::close(errp[1]);
	}
	if (spawn_err)
	{
		if (capture)
		{
			libc::close(outp[0]);
			if (errp[0] >= 0) libc::close(errp[0]);
		}
		return r;
	}
	r.spawned = true;
	DString out;
	out.init(a);
	DString err;
	err.init(a);
	bool out_open = capture;
	bool err_open = capture && !opts.merge_stderr;
	Clock start = clock::now();
	bool killed = false;
	CInt status;
	bool reaped = false;
	while (true)
	{
		long wait_ms = -1;
		if (opts.timeout_ms > 0 && !killed)
		{
			long elapsed = (long)start.to_now() / 1_000_000;
			if (elapsed >= opts.timeout_ms)
			{
				posix::kill(-pid, SIGKILL);
				posix::kill(pid, SIGKILL);
				killed = true;
				r.timed_out = true;
			}
			else
			{
				wait_ms = opts.timeout_ms - elapsed;
			}
		}
		if (!out_open && !err_open)
		{
			// Nothing to read (or inherited stdio): poll the child for exit.
			Pid_t w = posix::waitpid(pid, &status, (opts.timeout_ms > 0 && !killed) ? posix::WNOHANG : 0);
			if (w == pid) { reaped = true; break; }
			if (w < 0 && libc::errno() != EINTR) break;
			if (w == 0) thread::sleep_ms(wait_ms > 0 && wait_ms < 5 ? wait_ms : 5);
			continue;
		}
		Posix_pollfd[2] fds;
		Posix_nfds_t n = 0;
		if (out_open) fds[n++] = { .fd = outp[0], .events = os::POLLIN };
		if (err_open) fds[n++] = { .fd = errp[0], .events = os::POLLIN };
		CInt rc = os::poll(&fds, n, (CInt)(wait_ms > int::max ? int::max : wait_ms));
		if (rc < 0)
		{
			if (libc::errno() == EINTR) continue;
			break;
		}
		for (Posix_nfds_t i = 0; i < n; i++)
		{
			if (!fds[i].revents) continue;
			if (fds[i].fd == outp[0]) { drain_into(outp[0], &out, &out_open); }
			else { drain_into(errp[0], &err, &err_open); }
		}
	}
	if (out_open) libc::close(outp[0]);
	if (err_open) libc::close(errp[0]);
	while (!reaped)
	{
		Pid_t w = posix::waitpid(pid, &status, 0);
		if (w == pid) { reaped = true; break; }
		if (w < 0 && libc::errno() == EINTR) continue;
		break;
	}
	if (killed)
	{
		// Reap any stragglers of the group that may still hold resources.
		posix::kill(-pid, SIGKILL);
	}
	if (reaped)
	{
		if (posix::wIFEXITED(status))
		{
			r.exited = true;
			r.exit_code = posix::wEXITSTATUS(status);
		}
		else if (posix::wIFSIGNALED(status))
		{
			r.signal = posix::wTERMSIG(status);
		}
	}
	r.stdout = out.str_view();
	r.stderr = err.str_view();
	return r;
}

<* Windows fallback: no cwd, timeout or signal support (the harness targets POSIX hosts). *>
fn RunResult run(Allocator a, String[] argv, RunOptions opts = {}) @feat(WIN32)
{
	RunResult r;
	Process? p = process::spawn(argv, { .inherit_env = true, .stderr_to_stdout = opts.merge_stderr }, {},
		DEFAULT, opts.inherit_stdio ? INHERIT : CAPTURE, opts.inherit_stdio ? INHERIT : CAPTURE);
	if (catch p) return r;
	r.spawned = true;
	CInt? code = p.join();
	if (try code)
	{
		r.exited = true;
		r.exit_code = code;
	}
	return r;
}

<* This process's environment plus `overrides` (KEY=VALUE; later entries win, KEY= with no '=' removes). *>
fn String[] env_with(Allocator a, String[] overrides)
{
	List{String} out;
	out.init(a);
	ZString* e = posix::environ;
	for (sz i = 0; e && e[i]; i++)
	{
		String entry = e[i].str_view();
		bool replaced = false;
		foreach (o : overrides)
		{
			if (env_key(o) == env_key(entry)) replaced = true;
		}
		if (!replaced) out.push(entry.copy(a));
	}
	foreach (o : overrides)
	{
		if (o.contains("=")) out.push(o.copy(a));
	}
	return out.array_view();
}

fn String env_key(String entry) @local
{
	sz? eq = entry.index_of_char('=');
	if (catch eq) return entry;
	return entry[:eq];
}

<* The value of environment variable `name`, or "" when unset. *>
fn String getenv(Allocator a, String name)
{
	String? v = env::get_var(a, name);
	if (catch v) return "";
	return v;
}

<* PATH lookup like shutil.which; "" when not found. Names with '/' are checked as given. *>
fn String which(Allocator a, String name) @feat(POSIX)
{
	@pool()
	{
		if (name.contains("/")) return access(name.zstr_tcopy(), X_OK) == 0 ? name.copy(a) : "";
		String path = getenv(tmem, "PATH");
		foreach (dir : path.tsplit(":"))
		{
			if (!dir.len) continue;
			String candidate = string::tformat("%s/%s", dir, name);
			if (access(candidate.zstr_tcopy(), X_OK) == 0 && !dir_exists(candidate)) return candidate.copy(a);
		}
	};
	return "";
}

<* Whether `p` names an executable file. *>
fn bool is_executable(String p) @feat(POSIX)
{
	@pool()
	{
		return access(p.zstr_tcopy(), X_OK) == 0 && file_exists(p);
	};
}

const String[*] SIGNAL_NAMES = {
	"", "SIGHUP", "SIGINT", "SIGQUIT", "SIGILL", "SIGTRAP", "SIGABRT", "SIGBUS", "SIGFPE", "SIGKILL",
	"SIGUSR1", "SIGSEGV", "SIGUSR2", "SIGPIPE", "SIGALRM", "SIGTERM", "SIGSTKFLT", "SIGCHLD", "SIGCONT",
	"SIGSTOP", "SIGTSTP", "SIGTTIN", "SIGTTOU", "SIGURG", "SIGXCPU", "SIGXFSZ", "SIGVTALRM", "SIGPROF",
	"SIGWINCH", "SIGIO", "SIGPWR", "SIGSYS",
};

<* Linux signal name (signal.Signals(n).name), or SIG<n> when unknown. *>
fn String signal_name(Allocator a, int sig)
{
	if (sig > 0 && sig < SIGNAL_NAMES.len) return SIGNAL_NAMES[sig].copy(a);
	return string::format(a, "SIG%d", sig);
}
