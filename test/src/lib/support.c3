// Runfiles, workspace paths, parallel loops and small text helpers.
module aro_harness;
import std::io, std::io::path, std::io::file, std::collections::list, std::thread, std::thread::cpu;

<* Bazel runfiles root for this test/binary: TEST_SRCDIR/TEST_WORKSPACE, RUNFILES_DIR/_main, or "" outside Bazel. *>
fn String runfiles_root(Allocator a)
{
	String ws = getenv(tmem, "TEST_WORKSPACE");
	if (!ws.len) ws = "_main";
	String src = getenv(tmem, "TEST_SRCDIR");
	if (src.len) return string::format(a, "%s/%s", src, ws);
	String dir = getenv(tmem, "RUNFILES_DIR");
	if (dir.len) return string::format(a, "%s/%s", dir, ws);
	return "".copy(a);
}

<* `rel` (a $(rootpath) value) as an absolute path: under the runfiles root when there is one, else against cwd. *>
fn String runfile(Allocator a, String rel)
{
	if (rel.starts_with("/")) return rel.copy(a);
	@pool()
	{
		String root = runfiles_root(tmem);
		if (root.len && any_exists(string::tformat("%s/%s", root, rel))) return string::format(a, "%s/%s", root, rel);
	};
	return absolute(a, rel);
}

<* The source workspace when run by `bazel run` (BUILD_WORKSPACE_DIRECTORY), else "". *>
fn String workspace_dir(Allocator a) => getenv(a, "BUILD_WORKSPACE_DIRECTORY");

<* Repository root: the bazel run workspace, the test runfiles root, or the current directory. *>
fn String repo_root(Allocator a)
{
	String ws = workspace_dir(a);
	if (ws.len) return ws;
	String rf = runfiles_root(a);
	if (rf.len) return rf;
	return absolute(a, ".");
}

<* Bazel test sharding: (index, total); (0, 1) when not sharded. Touches TEST_SHARD_STATUS_FILE. *>
fn int[2] shard_info()
{
	@pool()
	{
		String total_s = getenv(tmem, "TEST_TOTAL_SHARDS");
		if (!total_s.len) return { 0, 1 };
		int total = total_s.to_int() ?? 1;
		int index = getenv(tmem, "TEST_SHARD_INDEX").to_int() ?? 0;
		String status = getenv(tmem, "TEST_SHARD_STATUS_FILE");
		if (status.len) (void)file::save(status, "");
		return { index, total < 1 ? 1 : total };
	};
}

<* Number of logical CPUs for the default worker count. *>
fn int cpu_count() @feat(POSIX)
{
	int n = cpu::native_cpu();
	return n > 0 ? n : 4;
}

alias ParallelFn = fn void(void* ctx, sz index);

struct ParallelState @local
{
	ParallelFn f;
	void* ctx;
	sz count;
	sz next;
	Mutex lock;
}

fn int parallel_worker(void* arg) @local
{
	ParallelState* st = arg;
	while (true)
	{
		sz i;
		st.lock.lock();
		i = st.next++;
		st.lock.unlock();
		if (i >= st.count) return 0;
		// Worker threads have no temp allocator of their own.
		@pool_init(mem, 1 << 20)
		{
			st.f(st.ctx, i);
		};
	}
}

<* Call f(ctx, i) for i in [0, count) on `jobs` threads; returns when all are done. *>
fn void parallel_for(int jobs, sz count, ParallelFn f, void* ctx)
{
	if (jobs <= 1 || count <= 1)
	{
		for (sz i = 0; i < count; i++) f(ctx, i);
		return;
	}
	ParallelState st = { .f = f, .ctx = ctx, .count = count };
	st.lock.init()!!;
	defer (void)st.lock.destroy();
	int n = jobs > (int)count ? (int)count : jobs;
	Thread[] threads = mem::alloc_array(Thread, n);
	defer mem::free(threads);
	for (int t = 0; t < n; t++) threads[t].create(&parallel_worker, &st)!!;
	for (int t = 0; t < n; t++) (void)threads[t].join();
}

<* Lines of `text` without terminators (str.splitlines for \n and \r\n). *>
fn String[] split_lines(Allocator a, String text)
{
	List{String} out;
	out.init(a);
	Splitter lines = text.tokenize_all("\n", skip_last: true);
	while (try line = lines.next()) out.push(line.strip_suffix("\r"));
	return out.array_view();
}

<* Whitespace-separated words (str.split()). *>
fn String[] split_ws(Allocator a, String s)
{
	List{String} out;
	out.init(a);
	sz i = 0;
	while (i < s.len)
	{
		while (i < s.len && s[i].is_space()) i++;
		sz start = i;
		while (i < s.len && !s[i].is_space()) i++;
		if (i > start) out.push(s[start:i - start]);
	}
	return out.array_view();
}
