// Tests for aro::toolchain::* (plan 23): the discovery interface, GCC
// installation/version selection, distro detection and multilib selection.
//
// Every test runs against a synthetic discovery::MemTree; nothing here reads
// the real filesystem (no /usr, /opt or /etc of the machine running tests).
module toolchain_discovery_tests;
import aro::toolchain::discovery;
import std::core::mem::allocators, std::collections::list;

macro check(left, right)
{
	$if $defined((long)left):
		test::eq((long)left, (long)right);
	$else
		test::eq(left, right);
	$endif
}

fn void join_semantics() @test
{
	char[64] buf;
	// std.fs.path.join: skip empty, add/drop one separator at each boundary.
	check(discovery::join_buf(&buf, { "/usr", "/lib64" })!!, "/usr/lib64");
	check(discovery::join_buf(&buf, { "/usr/", "/lib64" })!!, "/usr/lib64");
	check(discovery::join_buf(&buf, { "/usr", "lib" })!!, "/usr/lib");
	check(discovery::join_buf(&buf, { "", "/lib", "x86_64-linux-gnu" })!!, "/lib/x86_64-linux-gnu");
	check(discovery::join_buf(&buf, { "a", "", "b" })!!, "a/b");
	check(discovery::join_buf(&buf, { "", "" })!!, "");
	check(discovery::join_buf(&buf, { "a//", "/b" })!!, "a//b");
	check(discovery::join_buf(&buf, { "/x/lib/gcc/t/9", "..", "..", ".." })!!, "/x/lib/gcc/t/9/../../..");
	char[4] small;
	check(@catch(discovery::join_buf(&small, { "/usr", "lib" })), discovery::PATH_TOO_LONG);
	String owned = discovery::join(mem, { "/a", "b/", "/c" });
	defer free(owned.ptr);
	check(owned, "/a/b/c");
	check(owned.ptr[owned.len], 0);
}

fn void mem_tree_resolution() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		MemTree t;
		t.init(&ta);
		t.add_dir("/usr/lib/gcc/x86_64-linux-gnu/12");
		t.add_file("/usr/lib/gcc/x86_64-linux-gnu/12/crtbegin.o");
		t.add_file("/etc/os-release", "ID=alpine\n");
		FileSystem fs = t.fs();
		check(fs.exists("/"), true);
		check(fs.exists("/usr"), true);
		check(fs.exists("/usr/"), true);
		check(fs.exists("//usr//lib"), true);
		check(fs.exists("/usr/lib/gcc/x86_64-linux-gnu/12/crtbegin.o"), true);
		check(fs.exists("/usr/lib/gcc/x86_64-linux-gnu/12/../../../../lib"), true);
		check(fs.exists("/usr/lib/gcc/x86_64-linux-gnu/12/./crtbegin.o"), true);
		check(fs.exists("/usr/missing/../lib"), false); // missing intermediate fails like POSIX
		check(fs.exists("/../usr"), true); // root's parent is root
		check(fs.exists("/etc/os-release/x"), false); // file used as directory
		check(fs.exists("/opt"), false);
		check(fs.joined_exists({ "/usr/lib", "/gcc" }), true);
		check(fs.joined_exists({ "/usr/lib", "/gcc-cross" }), false);

		char[8] buf;
		check((String)fs.read_file("/etc/os-release", &buf)!!, "ID=alpin"); // partial read (8 bytes)
		char[64] big;
		check((String)fs.read_file("/etc/os-release", &big)!!, "ID=alpine\n");
		check(@catch(fs.read_file("/etc/missing", &big)), discovery::NOT_FOUND);
		check(@catch(fs.read_file("/etc", &big)), discovery::NOT_FOUND);

		DirEntryList entries;
		entries.init(&ta);
		fs.list_dir("/usr/lib/gcc/x86_64-linux-gnu", &ta, &entries)!!;
		check(entries.len(), 1);
		check(entries[0].name, "12");
		check(entries[0].kind == DIRECTORY, true);
		discovery::free_entries(&ta, &entries);
		entries.init(&ta);
		fs.list_dir("/usr/lib/gcc/x86_64-linux-gnu/12", &ta, &entries)!!;
		check(entries.len(), 1);
		check(entries[0].kind == FILE, true);
		check(@catch(fs.list_dir("/nope", &ta, &entries)), discovery::NOT_FOUND);
		check(@catch(fs.list_dir("/etc/os-release", &ta, &entries)), discovery::NOT_A_DIRECTORY);
		discovery::free_entries(&ta, &entries);

		// add_file over an existing file replaces its contents.
		t.add_file("/etc/os-release", "ID=arch\n");
		check((String)fs.read_file("/etc/os-release", &big)!!, "ID=arch\n");
		t.free();
	}
	check(ta.allocation_count(), 0);
}

fn void mem_tree_access_log() @test
{
	MemTree t;
	t.init(mem);
	defer t.free();
	t.add_dir("/sysroot/usr/lib");
	t.record = true;
	FileSystem fs = t.fs();
	fs.exists("/sysroot/usr");
	char[16] buf;
	(void)fs.read_file("/etc/lsb-release", &buf);
	check(t.accesses.len(), 2);
	check(t.accessed_with_prefix("/sysroot"), true);
	check(t.accessed_with_prefix("/etc/"), true);
	check(t.accessed_with_prefix("/usr"), false);
	t.clear_accesses();
	check(t.accesses.len(), 0);
}
