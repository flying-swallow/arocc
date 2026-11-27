module harness_lib_tests;
import std, aro_harness;

fn void glob_and_lines() @test
{
	assert(aro_harness::glob_match("x86_64-*-*", "x86_64-pc-linux-gnu"));
	assert(aro_harness::glob_match("i?86-*-*", "i686-pc-linux-gnu"));
	assert(!aro_harness::glob_match("avr-*-*", "x86_64-pc-linux-gnu"));
	assert(aro_harness::glob_match("[ab]*", "beta"));
	String[] lines = aro_harness::split_lines(tmem, "a\r\nb\n\nc");
	test::eq(lines.len, 4);
	test::eq(lines[0], "a");
	test::eq(lines[3], "c");
	test::eq(aro_harness::split_ws(tmem, "  -O2  -Wall\t-g ").len, 3);
}

fn void process_capture_timeout_signal() @test
{
	RunResult r = aro_harness::run(tmem, { "/bin/echo", "hi" });
	assert(r.spawned && r.exited && r.exit_code == 0);
	test::eq(r.stdout, "hi\n");
	r = aro_harness::run(tmem, { "/bin/sleep", "5" }, { .timeout_ms = 200 });
	assert(r.timed_out && !r.exited);
	r = aro_harness::run(tmem, { "/bin/kill", "-SEGV", "$$" }, { .search_path = true });
	assert(r.spawned);
	r = aro_harness::run(tmem, { "/bin/pwd" }, { .cwd = "/" });
	test::eq(r.stdout, "/\n");
	r = aro_harness::run(tmem, { "true" }, { .search_path = true });
	assert(r.exited && r.exit_code == 0);
	r = aro_harness::run(tmem, { "/nonexistent/binary" });
	assert(!r.spawned);
}

fn void temp_dirs() @test
{
	String dir = aro_harness::make_temp_dir(tmem, "harness-")!!;
	assert(aro_harness::dir_exists(dir));
	file::save(string::tformat("%s/a.txt", dir), "abc")!!;
	aro_harness::remove_tree(dir);
	assert(!aro_harness::any_exists(dir));
}
