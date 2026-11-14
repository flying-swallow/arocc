// Host subprocess adapter used by production toolchain discovery.
module aro::host_process;
import std::collections::list;
import std::core::mem;
import std::core::mem::allocators;
import std::os::process;
import std::thread;

struct CaptureTask
{
	process::Process* child;
	bool stderr;
	List{char} bytes;
	bool failed;
}

<* Drain one captured child stream. The task's list uses the thread-safe libc allocator. *>
fn int capture_stream(void* arg)
{
	CaptureTask* task = arg;
	char[4096] buffer;
	while (true)
	{
		sz? read_count;
		if (task.stderr)
		{
			read_count = task.child.read_stderr(&buffer[0], buffer.len);
		}
		else
		{
			read_count = task.child.read_stdout(&buffer[0], buffer.len);
		}
		if (catch read_count)
		{
			task.failed = true;
			(void)task.child.terminate();
			return 1;
		}
		if (read_count == 0) break;
		task.bytes.push_all(buffer[:read_count]);
	}
	return 0;
}

<* Copy captured bytes into caller-owned, NUL-terminated storage, including empty output. *>
fn String copy_capture(Allocator a, char[] bytes)
{
	char* output = alloc::malloc(a, (sz)bytes.len + 1);
	if (bytes.len) mem::copy(output, bytes.ptr, bytes.len);
	output[bytes.len] = 0;
	return (String)output[:bytes.len];
}

<*
 Run a host child with stdout and stderr captured. This callback is currently
 used by Darwin SDK discovery for xcrun, whose output is a small path string.
 Returned strings are allocated with `a`; their caller owns and frees them.
*>
fn ProcessResult run(void* ctx, Allocator a, String[] argv)
{
	(void)ctx;
	ProcessResult result = {};
	process::Process? child_opt = process::spawn(argv, INHERIT_ENV, {}, process::CAPTURE, process::CAPTURE, process::CAPTURE);
	if (catch child_opt) return result;
	process::Process child = child_opt;
	result.started = true;
	defer (void)child.destroy();

	CaptureTask stdout_task = { .child = &child };
	CaptureTask stderr_task = { .child = &child, .stderr = true };
	stdout_task.bytes.init(&allocators::LIBC_ALLOCATOR);
	defer stdout_task.bytes.free();
	stderr_task.bytes.init(&allocators::LIBC_ALLOCATOR);
	defer stderr_task.bytes.free();

	thread::Thread stdout_thread;
	if (catch start_error = stdout_thread.create(&capture_stream, &stdout_task))
	{
		(void)child.terminate();
		(void)capture_stream(&stdout_task);
		(void)capture_stream(&stderr_task);
		int? exit_code = child.join();
		if (catch exit_code) return result;
		result.exited = true;
		result.exit_code = exit_code;
		return result;
	}

	thread::Thread stderr_thread;
	if (catch start_error = stderr_thread.create(&capture_stream, &stderr_task))
	{
		(void)child.terminate();
		(void)capture_stream(&stderr_task);
		(void)stdout_thread.join();
		int? exit_code = child.join();
		if (catch exit_code) return result;
		result.exited = true;
		result.exit_code = exit_code;
		return result;
	}

	(void)stdout_thread.join();
	(void)stderr_thread.join();
	int? exit_code = child.join();
	if (catch exit_code)
	{
		(void)child.terminate();
		(void)child.join();
		return result;
	}
	result.exited = true;
	result.exit_code = exit_code;
	result.stdout = copy_capture(a, stdout_task.bytes.array_view());
	result.stderr = copy_capture(a, stderr_task.bytes.array_view());
	if (stdout_task.failed || stderr_task.failed) result.exit_code = 1;
	return result;
}

const ProcessService SERVICE = { .ctx = null, .run = &run };
