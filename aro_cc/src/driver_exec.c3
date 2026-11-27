// Assembler and linker process helpers, kept separate from driver policy.
module aro::frontend::c::driver_exec;
import aro::frontend::c::diagnostics;
import aro::toolchain;
import aro::toolchain::darwin;
import std::collections::list;
import std::core::mem;
import std::core::string;
import std::io;
import std::io::file;
import libc;
import std::os;
import std::os::env;
import std::os::posix;
import std::os::process;
import std::os::win32;

excuse INVALID_EXE;

// CRASHED: the wait status is neither a normal exit nor a signal. Zig reports it as "crashed" too.
enum ProcessOutcomeKind : char
{
	EXITED, SIGNALED, CRASHED, SPAWN_FAILED, WAIT_FAILED
}

// Which tool ran. Selects the exit and crash wording in report_outcome.
enum ExecTool : char
{
	ASSEMBLER, LINKER
}

struct ProcessOutcome
{
	ProcessOutcomeKind kind;
	int value;
	// Fault behind SPAWN_FAILED or WAIT_FAILED. Zero when none was reported.
	fault fault_value;
}

<*
 Text for a fault from a spawn, wait, or argument step. Ports Zig's
 Driver.errorDescription (src/aro/Driver.zig 1194-1215). Zig's `@errorName`
 fallback is `short_name()`, which drops the module path that `%s` prints
 (`process::FAILED_TO_START_PROCESS` becomes `FAILED_TO_START_PROCESS`).
 A zero fault means no fault was recorded. Injected test seams carry none, and
 POSIX waitpid errors are not mapped to a fault. Both get Zig's Unexpected text.
*>
fn String error_description(fault f)
{
	if (!f) return "an unexpected error occurred";
	switch (f)
	{
		case mem::OUT_OF_MEMORY: return "ran out of memory";
		case io::FILE_NOT_FOUND: return "file not found";
		case INVALID_EXE: return "InvalidExe";
		case io::FILE_IS_DIR: return "is a directory";
		case io::FILE_NOT_DIR: return "is not a directory";
		case io::NAME_TOO_LONG: return "file name is too long";
		// C3 maps EACCES to io::NO_PERMISSION. Zig's AccessDenied is the same errno.
		case io::NO_PERMISSION: return "access denied";
		// C3 maps EMFILE to this. Zig's SystemFdQuotaExceeded (ENFILE) is not mapped:
		// C3 sends ENFILE to io::OUT_OF_SPACE, which has no Zig counterpart.
		case io::TOO_MANY_DESCRIPTORS: return "ran out of file descriptors";
		// C3 uses this for an errno it does not map, like Zig's Unexpected.
		case io::UNKNOWN_ERROR: return "an unexpected error occurred";
		default: return f.short_name();
	}
}

// Probe result for one path, from access(X_OK) and errno. Only used after a spawn failure.
enum ExecProbe : char
{
	RUNNABLE, MISSING, DENIED, UNKNOWN
}

<*
 Probe one path the way execve reaches it. ENOENT and ENOTDIR mean missing and EACCES means
 denied. A directory is denied because execve reports EACCES for it. Any other errno is
 UNKNOWN, and the caller keeps the spawn fault.
*>
fn ExecProbe probe_exec_path(String path) @feat(POSIX)
{
	if (posix::access(path.zstr_tcopy(), 1 /* X_OK */) == 0) return file::is_dir(path) ? DENIED : RUNNABLE;
	CInt err = libc::errno();
	if (err == Errno.ENOENT || err == Errno.ENOTDIR) return MISSING;
	if (err == Errno.EACCES) return DENIED;
	return UNKNOWN;
}

<*
 argv[0] contains a slash, so execve reaches it directly: missing is FILE_NOT_FOUND and
 denied is NO_PERMISSION. Anything else is left unclassified.
*>
fn void? classify_direct_path(String path) @feat(POSIX)
{
	ExecProbe probe = probe_exec_path(path);
	if (probe == MISSING) return io::FILE_NOT_FOUND~;
	if (probe == DENIED) return io::NO_PERMISSION~;
	return;
}

<*
 Bare argv[0]: walk the Toolchain PATH entries. Empty entries are skipped, matching
 Toolchain.find_program_by_name. A runnable candidate or an unknown errno means the failure
 was not a lookup miss, so nothing is classified. Otherwise a denied candidate gives
 NO_PERMISSION, and no candidate at all gives FILE_NOT_FOUND.
*>
fn void? classify_path_search(String name, String path_env) @feat(POSIX)
{
	bool saw_denied = false;
	usz start = 0;
	for (usz i = 0; i <= path_env.len; i++)
	{
		if (i < path_env.len && path_env[i] != ':') continue;
		if (i == start)
		{
			start = i + 1; continue;
		}
		String dir = path_env[start : i - start];
		start = i + 1;
		DString candidate;
		candidate.init(tmem);
		defer candidate.free();
		if (dir.len > 0)
		{
			candidate.append(dir);
			candidate.append_char('/');
		}
		candidate.append(name);
		ExecProbe probe = probe_exec_path(candidate.str_view());
		if (probe == RUNNABLE || probe == UNKNOWN) return;
		if (probe == DENIED) saw_denied = true;
	}
	if (saw_denied) return io::NO_PERMISSION~;
	return io::FILE_NOT_FOUND~;
}

<*
 Check one Windows candidate using a temporary buffer.
*>
fn bool windows_candidate_exists(String dir, String name, bool add_dir, String extension) @feat(WIN32)
{
	DString candidate;
	candidate.init(tmem);
	defer candidate.free();
	if (add_dir)
	{
		candidate.append(dir);
		candidate.append_char('\\');
	}
	candidate.append(name);
	candidate.append(extension);
	return file::exists(candidate.str_view());
}

<*
 Classify why argv[0] failed to start, searching the PATH configured on the Toolchain. An
 empty argv[0] is FILE_NOT_FOUND. POSIX uses access probes; Windows checks PATH/PATHEXT
 candidates and classifies the captured CreateProcessW error.
*>
fn void? classify_spawn_failure(String[] argv, String path_env, uint win32_error) @feat(POSIX, WIN32)
{
	$if env::POSIX:
		if (argv.len == 0 || argv[0].len == 0) return io::FILE_NOT_FOUND~;
		String name = argv[0];
		bool has_slash = false;
		foreach (c : name)
		{
			if (c == '/') has_slash = true;
		}
		if (has_slash) return classify_direct_path(name);
		return classify_path_search(name, path_env);
	$endif
	$if env::WIN32:
		if (argv.len == 0 || argv[0].len == 0) return io::FILE_NOT_FOUND~;
		String name = argv[0];
		bool explicit_path = false;
		bool has_extension = false;
		foreach (c : name)
		{
			if (c == '/' || c == '\\')
			{
				explicit_path = true;
				has_extension = false;
			}
			else if (c == ':') explicit_path = true;
			else if (c == '.') has_extension = true;
		}

		String pathext = env::get_var(tmem, "PATHEXT") ?? ".COM;.EXE;.BAT;.CMD";
		bool found = false;
		if (explicit_path)
		{
			found = windows_candidate_exists("", name, false, "");
			if (!found && !has_extension)
			{
				usz start = 0;
				for (usz i = 0; i <= pathext.len; i++)
				{
					if (i < pathext.len && pathext[i] != ';') continue;
					if (i == start)
					{
						start = i + 1; continue;
					}
					String extension = pathext[start : i - start];
					start = i + 1;
					if (windows_candidate_exists("", name, false, extension))
					{
						found = true; break;
					}
				}
			}
		}
		else
		{
			usz path_start = 0;
			for (usz i = 0; i <= path_env.len && !found; i++)
			{
				if (i < path_env.len && path_env[i] != ';') continue;
				if (i == path_start)
				{
					path_start = i + 1; continue;
				}
				String dir = path_env[path_start : i - path_start];
				path_start = i + 1;
				found = windows_candidate_exists(dir, name, true, "");
				if (found || has_extension) continue;
				usz ext_start = 0;
				for (usz j = 0; j <= pathext.len; j++)
				{
					if (j < pathext.len && pathext[j] != ';') continue;
					if (j == ext_start)
					{
						ext_start = j + 1; continue;
					}
					String extension = pathext[ext_start : j - ext_start];
					ext_start = j + 1;
					if (windows_candidate_exists(dir, name, true, extension))
					{
						found = true; break;
					}
				}
			}
		}
		if (!found) return io::FILE_NOT_FOUND~;
		if (win32_error == win32::ERROR_FILE_NOT_FOUND || win32_error == win32::ERROR_PATH_NOT_FOUND)
		return io::FILE_NOT_FOUND~;
		if (win32_error == win32::ERROR_ACCESS_DENIED) return io::NO_PERMISSION~;
		if (win32_error == win32::ERROR_BAD_EXE_FORMAT) return INVALID_EXE~;
		return;
	$endif
}

<*
 Outcome for a failed spawn. Only FAILED_TO_START_PROCESS names argv[0], so other spawn
 faults pass through unchanged. POSIX probes argv[0]; Windows also classifies the captured
 CreateProcessW error after checking whether a matching candidate exists.
*>
fn ProcessOutcome spawn_failure(String[] argv, fault spawn_fault, String path_env, uint win32_error)
{
	if (spawn_fault == process::FAILED_TO_START_PROCESS)
	{
		fault probed = @catch(classify_spawn_failure(argv, path_env, win32_error));
		if (probed) return { .kind = SPAWN_FAILED, .fault_value = probed };
	}
	return { .kind = SPAWN_FAILED, .fault_value = spawn_fault };
}

<* Run the host process and capture GetLastError immediately after a Windows spawn failure. *>
fn ProcessOutcome run_host(String[] argv, String path_env) @feat(POSIX, WIN32)
{
	process::Process? child_opt = process::spawn(argv, INHERIT_ENV, {},
		process::INHERIT, process::INHERIT, process::INHERIT);
	if (catch spawn_fault = child_opt)
	{
		$if env::WIN32:
			uint win32_error = win32::getLastError();
			return spawn_failure(argv, spawn_fault, path_env, win32_error);
		$else
			return spawn_failure(argv, spawn_fault, path_env, 0);
		$endif
	}
	process::Process child = child_opt;
	defer (void)child.destroy();

	$if env::POSIX:
		CInt status = 0;
		Pid_t waited;
		while (true)
		{
			waited = posix::waitpid(child.child, &status, 0);
			if (waited != -1 || libc::errno() != EINTR) break;
		}
		if (waited != child.child) return { .kind = WAIT_FAILED };
		if (posix::wIFEXITED(status)) return { .kind = EXITED, .value = posix::wEXITSTATUS(status) };
		if (posix::wIFSIGNALED(status)) return { .kind = SIGNALED, .value = posix::wTERMSIG(status) };
		return { .kind = CRASHED };
	$else
		CInt? exit_code_opt = child.join();
		if (catch join_fault = exit_code_opt) return { .kind = WAIT_FAILED, .fault_value = join_fault };
		return { .kind = EXITED, .value = exit_code_opt };
	$endif
}

<*
 Run an injected process service. ProcessResult has no signal field, so test
 services encode a signal as a negative exit_code (for example, -9 for signal
 9); nonnegative values retain the usual exit-code meaning. The callback owns
 neither argv nor its elements, and its returned output buffers are released
 here as required by ProcessResult's contract.
 @require service.run != null
*>
fn ProcessOutcome run_injected(Allocator a, ProcessService service, String[] argv)
{
	ProcessResult result = service.run(service.ctx, a, argv);
	defer
	{
		if (result.stdout.ptr) alloc::free(a, result.stdout.ptr);
		if (result.stderr.ptr) alloc::free(a, result.stderr.ptr);
	}
	if (!result.started) return { .kind = SPAWN_FAILED, .fault_value = result.spawn_error };
	if (!result.exited) return { .kind = WAIT_FAILED };
	if (result.exit_code < 0) return { .kind = SIGNALED, .value = -result.exit_code };
	return { .kind = EXITED, .value = result.exit_code };
}

<*
 Report a failed outcome with Zig's invokeAssembler / invokeLinker wording
 (src/aro/Driver.zig 1358-1385 and 1604-1650). Spawn and wait failures say
 "linker" for both tools. Zig's invokeAssembler says the same, and that is kept
 on purpose.
*>
fn void? report_outcome(Allocator a, Diagnostics* d, ExecTool tool, ProcessOutcome outcome)
{
	bool is_assembler = tool == ExecTool.ASSEMBLER;
	switch (outcome.kind)
	{
		case SPAWN_FAILED: return d.add(
			{
				.kind = FATAL_ERROR, .text = string::tformat("unable to spawn linker: %s", error_description(outcome.fault_value))
		}
		);
		case WAIT_FAILED: return d.add(
			{
				.kind = FATAL_ERROR, .text = string::tformat("error waiting for linker: %s", error_description(outcome.fault_value))
		}
		);
		case SIGNALED:
			return d.add(
				{
					.kind = FATAL_ERROR, .text = is_assembler ? "assembler crashed" : "linker crashed"
				}
			);
		case CRASHED:
			return d.add(
				{
					.kind = FATAL_ERROR, .text = is_assembler ? "assembler crashed" : "linker crashed"
				}
			);
		case EXITED:
			if (outcome.value == 0) return;
			return d.add(
				{
					.kind = FATAL_ERROR, .text = is_assembler ? "assembler exited with an error code" : "linker exited with an error code"
				}
			);
	}
}

fn void? execute(Allocator a, Diagnostics* d, ExecTool tool, String[] argv,
	ProcessService* service, String path_env)
{
	ProcessOutcome outcome;
	if (service)
	{
		outcome = run_injected(a, *service, argv);
	}
	else
	{
		outcome = run_host(argv, path_env);
	}
	return report_outcome(a, d, tool, outcome);
}

const String HEX_DIGITS = "0123456789abcdef";

<*
 Write one argv item in the quoted form used by --verbose-linker-args. Ports Zig's
 `"{f}"` over std.zig.fmtString (stringEscape in std/zig.zig). Escapes are \\, \",
 \n, \r, and \t. Every other byte outside 0x20..0x7e is \xNN with lowercase hex, so
 \b \f \v \0 come out as \x08 \x0c \x0b \x00. The single quote is not escaped.
 C3 String.escape is not used: it writes \b \f \v \0 and differs from Zig.
*>
fn String quoted_arg_text(Allocator a, String arg)
{
	DString out;
	out.init(a);
	out.append_char('"');
	foreach (char c : arg)
	{
		switch (c)
		{
			case '\n': out.append(`\n`);
			case '\r': out.append(`\r`);
			case '\t': out.append(`\t`);
			case '\\': out.append(`\\`);
			case '"': out.append(`\"`);
			default:
				if (c >= 0x20 && c <= 0x7e)
				{
					out.append_char(c);
				}
				else
				{
					usz code = c;
					out.append(`\x`);
					out.append_char(HEX_DIGITS[code >> 4]);
					out.append_char(HEX_DIGITS[code & 0xf]);
				}
		}
	}
	out.append_char('"');
	String result = out.str_view().copy(a);
	out.free();
	return result;
}

fn void? write_quoted_arg(String arg)
{
	String text = quoted_arg_text(tmem, arg);
	defer alloc::free(tmem, text.ptr);
	io::write_all(io::stdout(), text)!;
}

<* Print each argument quoted, separated by spaces, followed by a newline. *>
fn void? dump_linker_args(String[] argv)
{
	foreach (i, arg : argv)
	{
		if (i != 0) io::write_all(io::stdout(), " ")!;
		write_quoted_arg(arg)!;
	}
	io::write_all(io::stdout(), "\n")!;
	return io::stdout().flush();
}

<* Invoke the host assembler with inherited stdin, stdout, and stderr. *>
fn void? invoke_assembler(Toolchain* tc, Diagnostics* d, String input_path, String output_path)
{
	return invoke_assembler_impl(tc, d, input_path, output_path, null);
}

<*
 Invoke the assembler using a supplied process service. This entry point is
 intended for tests that need to inspect structured argv or simulate outcomes.
 @require service.run != null
*>
fn void? invoke_assembler_with_process(Toolchain* tc, Diagnostics* d, ProcessService service,
	String input_path, String output_path)
{
	return invoke_assembler_impl(tc, d, input_path, output_path, &service);
}

fn void? invoke_assembler_impl(Toolchain* tc, Diagnostics* d, String input_path,
	String output_path, ProcessService* service)
{
	if (tc.inner == toolchain::InnerKind.DARWIN)
	{
		String assembler = darwin::find_tool(tc.a, &tc.env, "as")!;
		defer alloc::free(tc.a, assembler.ptr);
		String[6] args = { assembler, "-arch", "arm64", input_path, "-o", output_path };
		return execute(tc.a, d, ExecTool.ASSEMBLER, args[..], service, tc.env.path);
	}
	char[4096] assembler_path_buf;
	String assembler_path = tc.get_assembler_path(assembler_path_buf[..]);
	String[4] argv = { assembler_path, input_path, "-o", output_path };
	return execute(tc.a, d, ExecTool.ASSEMBLER, argv[..], service, tc.env.path);
}

<* Invoke the selected host linker with inherited stdin, stdout, and stderr. *>
fn void? invoke_linker(Toolchain* tc, Diagnostics* d, String output_name,
	String[] link_objects, bool verbose_args = false)
{
	return invoke_linker_impl(tc, d, output_name, link_objects, verbose_args, null);
}

<*
 Invoke the linker using a supplied process service. This entry point is
 intended for tests that need to inspect structured argv or simulate outcomes.
 @require service.run != null
*>
fn void? invoke_linker_with_process(Toolchain* tc, Diagnostics* d, ProcessService service,
	String output_name, String[] link_objects, bool verbose_args = false)
{
	return invoke_linker_impl(tc, d, output_name, link_objects, verbose_args, &service);
}

fn void? invoke_linker_impl(Toolchain* tc, Diagnostics* d, String output_name,
	String[] link_objects, bool verbose_args, ProcessService* service)
{
	char[4096] linker_path_buf;
	String? linker_path_opt = tc.get_linker_path(linker_path_buf[..]);
	if (catch path_fault = linker_path_opt)
	{
		// INVALID_LINKER_PATH: the toolchain already reported a FATAL. Return the fault so
		// the driver exits 1, without adding a second message.
		if (path_fault == toolchain::INVALID_LINKER_PATH) return path_fault~;
		return d.add(
			{
				.kind = FATAL_ERROR, .text = string::tformat("unable to resolve linker: %s", error_description(path_fault))
		}
		);
	}

	List{String} argv;
	argv.init(tc.a);
	defer argv.free();
	argv.push(linker_path_opt);

	// Linker policy creates temporary path arguments through Toolchain.a. Use
	// tmem on a shallow copy so those strings live through this synchronous call
	// without becoming allocations owned by the long-lived Toolchain.
	Toolchain argument_tc = *tc;
	argument_tc.a = tmem;
	fault args_fault = @catch(argument_tc.build_linker_args(output_name, link_objects, &argv));
	// UNSUPPORTED_LINKER_TARGET: the toolchain already emitted FATAL "This toolchain does not support linking yet".
	// Return the fault so the driver exits 1, without adding a second message.
	if (args_fault == toolchain::UNSUPPORTED_LINKER_TARGET) return args_fault~;
	if (args_fault) return d.add(
		{
			.kind = FATAL_ERROR, .text = string::tformat("unable to build linker args: %s", error_description(args_fault))
	}
	);

	String[] args = argv.array_view();
	if (verbose_args)
	{
		fault dump_fault = @catch(dump_linker_args(args));
		if (dump_fault) return d.add(
			{
				.kind = FATAL_ERROR, .text = string::tformat("unable to dump linker args: %s", error_description(dump_fault))
		}
		);
	}
	return execute(tc.a, d, ExecTool.LINKER, args, service, tc.env.path);
}
