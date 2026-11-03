// Tests for aro::toolchain::* (plan 23): the discovery interface, GCC
// installation/version selection, distro detection and multilib selection.
//
// Every test runs against a synthetic discovery::MemTree; nothing here reads
// the real filesystem (no /usr, /opt or /etc of the machine running tests).
//
// Sources of expected values:
// - "Zig tests": ported verbatim from the `test` blocks of GCCVersion.zig and
//   Distro.zig.
// - Everything else is source-derived: read off GCCVersion.zig, Multilib.zig,
//   Distro.zig and GCCDetector.zig (plus std.fs.path.join / std.fmt.parseInt
//   semantics) for the exact synthetic tree each test builds. No Zig
//   executable was run, so no differential parity is claimed.
module toolchain_discovery_tests;
import aro::toolchain::discovery, aro::toolchain::gcc_version, aro::toolchain::multilib;
import aro::toolchain::distro, aro::toolchain::gcc_detector, aro::target;
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

// ===========================================================================
// GCCVersion (src/aro/Toolchain/GCCVersion.zig)
// ===========================================================================

// Ported verbatim from GCCVersion.zig `test parse`: each version is preferred
// over the next one.
fn void gcc_version_zig_test_parse() @test
{
	GccVersion[10] versions = {
		gcc_version::parse("5"),
		gcc_version::parse("4"),
		gcc_version::parse("4.2"),
		gcc_version::parse("4.0"),
		gcc_version::parse("4.0-patched"),
		gcc_version::parse("4.0.2"),
		gcc_version::parse("4.0.1"),
		gcc_version::parse("4.0.1-patched"),
		gcc_version::parse("4.0.0"),
		gcc_version::parse("4.0.0-patched"),
	};
	for (usz i = 0; i + 1 < versions.len; i++)
	{
		GccVersion first = versions[i];
		GccVersion second = versions[i + 1];
		check(first.order(first) == EQ, true);
		check(first.order(second) == GT, true);
		check(second.order(first) == LT, true);
	}
	check(versions[^1].order(versions[^1]) == EQ, true);
}

fn void expect_version(String text, int major, int minor, int patch, String suffix)
{
	GccVersion v = gcc_version::parse(text);
	check(v.major, major);
	check(v.minor, minor);
	check(v.patch, patch);
	check(v.suffix, suffix);
}

// Source-derived from GCCVersion.parse (std.fmt.parseInt + mem.findNone).
fn void gcc_version_parse_fields() @test
{
	expect_version("12", 12, -1, -1, "");
	expect_version("12.2.0", 12, 2, 0, "");
	expect_version("4.0-patched", 4, 0, -1, "-patched");
	expect_version("4.0.1-patched", 4, 0, 1, "-patched");
	expect_version("4.2rc1", 4, 2, -1, "rc1");
	expect_version("4.0.x", 4, 0, -1, ""); // patch text without digits is ignored
	expect_version("5.1.2.3", 5, 1, 2, ""); // pieces after the third are ignored
	expect_version("+5", 5, -1, -1, ""); // parseInt accepts a '+' sign
	expect_version("1_0", 10, -1, -1, ""); // and '_' digit separators
	// Malformed: major -1, everything else at the defaults.
	expect_version("", -1, -1, -1, "");
	expect_version("abc", -1, -1, -1, "");
	expect_version("-1", -1, -1, -1, "");
	expect_version("4.x", -1, -1, -1, "");
	expect_version("4.-1", -1, -1, -1, "");
	expect_version("99999999999", -1, -1, -1, "");
	expect_version("13-junk", -1, -1, -1, "");
	GccVersion v = gcc_version::parse("10.3.1");
	check(v.major_str, "10");
	check(v.minor_str, "3");
	check(gcc_version::parse("4").minor_str, "");
}

fn void gcc_version_missing_parts_preference() @test
{
	// The detector's minimum check: isLessThan(4, 1, 1, "").
	check(gcc_version::parse("4.1.1").is_less_than(4, 1, 1, ""), false);
	check(gcc_version::parse("4.1.0").is_less_than(4, 1, 1, ""), true);
	check(gcc_version::parse("4.1").is_less_than(4, 1, 1, ""), false); // missing patch preferred
	check(gcc_version::parse("4").is_less_than(4, 1, 1, ""), false); // missing minor preferred
	check(gcc_version::parse("4.0").is_less_than(4, 1, 1, ""), true);
	check(gcc_version::parse("4.1.1-rc").is_less_than(4, 1, 1, ""), true); // suffix loses to none
	check(gcc_version::parse("3.9").is_less_than(4, 1, 1, ""), true);
	check(gcc_version::parse("bogus").is_less_than(4, 1, 1, ""), true);
	// Suffixes compare bytewise.
	check(gcc_version::parse("4.0.1-a").order(gcc_version::parse("4.0.1-b")) == LT, true);
	check(gcc_version::parse("12").order(gcc_version::parse("12.1")) == GT, true);
	check(gcc_version::parse("010").order(gcc_version::parse("10")) == EQ, true);
	// The detector's starting point (`.{}`) is below every real version.
	GccVersion d = gcc_version::DEFAULT;
	check(gcc_version::parse("0.0.0").order(d) == GT, true);
}

fn void gcc_version_to_unsigned() @test
{
	check(gcc_version::parse("12.2.0").to_unsigned(), 120200);
	check(gcc_version::parse("4").to_unsigned(), 40000);
	check(gcc_version::parse("4.9").to_unsigned(), 40900);
	check(gcc_version::parse("bogus").to_unsigned(), 0);
	// Wrapping multiplication like clang: 500000 * 10000 mod 2^32.
	check(gcc_version::parse("500000").to_unsigned(), 705032704);
}

// ===========================================================================
// Multilib (src/aro/Toolchain/Multilib.zig)
// ===========================================================================

fn void multilib_select() @test
{
	Detected d;
	d.push(multilib::init("", "", { "-m32", "+m64", "-mx32" }));
	d.push(multilib::init("/32", "/32", { "+m32", "-m64", "-mx32" }));
	check(d.multilibs().len, 2);
	check(d.multilibs()[1].flags().len, 3);
	check(d.select({ "+m64", "-m32", "-mx32" })!!, true);
	check(d.selected.gcc_suffix, "");
	check(d.select({ "-m64", "+m32", "-mx32" })!!, true);
	check(d.selected.gcc_suffix, "/32");
	// Nothing matches: false and the previous selection is kept.
	check(d.select({ "-m64", "-m32", "+mx32" })!!, false);
	check(d.selected.gcc_suffix, "/32");
	// A flag nobody asks about matches itself; '+' flags then need no check flag.
	Detected e;
	e.push(multilib::init("/a", "/a", { "+foo" }));
	e.push(multilib::init("/b", "/b", { "-foo" }));
	check(@catch(e.select({ "+bar" })), multilib::TOO_MANY_MULTILIBS); // both match themselves
	check(e.select({ "+foo" })!!, true);
	check(e.selected.gcc_suffix, "/a");
	// The first check flag with a given name wins.
	check(e.select({ "-foo", "+foo" })!!, true);
	check(e.selected.gcc_suffix, "/b");
	// A multilib without flags always matches.
	Detected f;
	f.push(multilib::init("", "", {}));
	check(f.select({ "+m64" })!!, true);
	Detected empty;
	check(empty.select({ "+m64" })!!, false);
}

fn void multilib_too_many() @test
{
	Detected d;
	d.push(multilib::init("", "", { "-m32", "+m64" }));
	d.push(multilib::init("/64", "/64", { "-m32", "+m64" }));
	check(@catch(d.select({ "+m64", "-m32" })), multilib::TOO_MANY_MULTILIBS);
	// Still fine when only one of them matches.
	check(d.select({ "+m32" })!!, false);
}

fn void multilib_filter() @test
{
	MemTree t;
	t.init(mem);
	defer t.free();
	t.add_file("/gcc/t/12/crtbegin.o");
	t.add_file("/gcc/t/12/32/crtbegin.o");
	t.add_dir("/gcc/t/12/x32"); // directory without the file
	Env env = { .fs = t.fs(), .target = target::from_triple("x86_64-linux-gnu")!! };
	Detected d;
	d.push(multilib::init("", "", { "+m64" }));
	d.push(multilib::init("/64", "/64", { "+m64" }));
	d.push(multilib::init("/32", "/32", { "+m32" }));
	d.push(multilib::init("/x32", "/x32", { "+mx32" }));
	Filter flt = { .base = { "/gcc/t", "12" }, .file = "crtbegin.o" };
	check(flt.exists(&d.multilib_buf[0], &env), true);
	check(flt.exists(&d.multilib_buf[1], &env), false);
	d.filter(flt, &env);
	check(d.multilibs().len, 2);
	check(d.multilibs()[0].gcc_suffix, "");
	check(d.multilibs()[1].gcc_suffix, "/32");
}

// ===========================================================================
// Distro (src/aro/Toolchain/Distro.zig)
// ===========================================================================

// Ported verbatim from the Distro.zig tests.
fn void distro_zig_tests() @test
{
	check(distro::scan_for_debian("squeeze/sid") == Tag.DEBIAN_SQUEEZE, true);
	check(distro::scan_for_debian("11.1.2") == Tag.DEBIAN_BULLSEYE, true);
	check(distro::scan_for_debian("None") == Tag.UNKNOWN, true);
	check(distro::scan_for_debian("") == Tag.UNKNOWN, true);

	check(distro::scan_for_red_hat("Fedora release 7") == Tag.FEDORA, true);
	check(distro::scan_for_red_hat("Red Hat Enterprise Linux release 7") == Tag.RHEL7, true);
	check(distro::scan_for_red_hat("CentOS release 5") == Tag.RHEL5, true);
	check(distro::scan_for_red_hat("CentOS release 4") == Tag.UNKNOWN, true);
	check(distro::scan_for_red_hat("") == Tag.UNKNOWN, true);

	String lsb = "DISTRIB_ID=Ubuntu\nDISTRIB_RELEASE=20.04\nDISTRIB_CODENAME=focal\nDISTRIB_DESCRIPTION=\"Ubuntu 20.04.6 LTS\"\n";
	check(distro::scan_for_lsb_release(lsb)!! == Tag.UBUNTU_FOCAL, true);

	String osr = "NAME=\"Alpine Linux\"\nID=alpine\nVERSION_ID=3.18.2\nPRETTY_NAME=\"Alpine Linux v3.18\"\nHOME_URL=\"https://alpinelinux.org/\"\nBUG_REPORT_URL=\"https://gitlab.alpinelinux.org/alpine/aports/-/issues\"\n";
	check(distro::scan_for_os_release(osr)!! == Tag.ALPINE, true);
}

// Source-derived: malformed or unrecognized release files.
fn void distro_malformed_release_files() @test
{
	check(@catch(distro::scan_for_os_release("")), distro::NO_MATCH);
	check(@catch(distro::scan_for_os_release("NAME=Foo\nVERSION=1\n")), distro::NO_MATCH);
	check(@catch(distro::scan_for_os_release("ID=\"fedora\"\n")), distro::NO_MATCH); // quotes not stripped
	check(@catch(distro::scan_for_os_release("ID=alpine\r\n")), distro::NO_MATCH); // CR kept
	check(@catch(distro::scan_for_os_release(" ID=arch\n")), distro::NO_MATCH);
	check(@catch(distro::scan_for_os_release("ID=ubuntu\n")), distro::NO_MATCH); // not in the list
	check(distro::scan_for_os_release("ID=debian\nID=sles\n")!! == Tag.OPEN_SUSE, true); // later lines scanned
	check(distro::scan_for_os_release("ID_LIKE=x\nID=exherbo")!! == Tag.EXHERBO, true); // no trailing newline
	check(distro::scan_for_os_release("ID=opensuse\n")!! == Tag.OPEN_SUSE, true);
	check(distro::scan_for_os_release("ID=gentoo\n")!! == Tag.GENTOO, true);
	check(distro::scan_for_os_release("ID=arch\n")!! == Tag.ARCH, true);
	check(distro::scan_for_os_release("ID=fedora\n")!! == Tag.FEDORA, true);

	check(@catch(distro::scan_for_lsb_release("DISTRIB_CODENAME=noble\n")), distro::NO_MATCH);
	check(@catch(distro::scan_for_lsb_release("DISTRIB_CODENAME=\n")), distro::NO_MATCH);
	check(distro::scan_for_lsb_release("DISTRIB_CODENAME=hardy")!! == Tag.UBUNTU_HARDY, true);
	check(distro::scan_for_lsb_release("DISTRIB_CODENAME=lunar\n")!! == Tag.UBUNTU_LUNAR, true);

	check(distro::scan_for_red_hat("CentOS release 6.5 (Final)") == Tag.RHEL6, true);
	check(distro::scan_for_red_hat("Scientific Linux release 7.9") == Tag.RHEL7, true);
	check(distro::scan_for_red_hat("Red Hat Enterprise Linux release 8.1") == Tag.UNKNOWN, true);
	check(distro::scan_for_red_hat("fedora release 38") == Tag.UNKNOWN, true); // case sensitive

	check(distro::scan_for_debian("12.4\n") == Tag.DEBIAN_BOOKWORM, true);
	check(distro::scan_for_debian("5.0") == Tag.DEBIAN_LENNY, true);
	check(distro::scan_for_debian("13.0") == Tag.DEBIAN_TRIXIE, true);
	check(distro::scan_for_debian("13\n") == Tag.UNKNOWN, true); // "13\n" is not an integer
	check(distro::scan_for_debian("14.1") == Tag.UNKNOWN, true);
	check(distro::scan_for_debian("256.1") == Tag.UNKNOWN, true); // u8 overflow, then not a codename
	check(distro::scan_for_debian("-0.1") == Tag.UNKNOWN, true); // parses as 0
	check(distro::scan_for_debian("bookworm/sid\n") == Tag.DEBIAN_BOOKWORM, true);
	check(distro::scan_for_debian("trixie/sid") == Tag.UNKNOWN, true);
}

fn void distro_predicates() @test
{
	check(Tag.UBUNTU_LUCID.get_hash_style() == HashStyle.BOTH, true);
	check(Tag.UBUNTU_JAUNTY.get_hash_style() == HashStyle.BOTH, true);
	check(Tag.UBUNTU_KARMIC.get_hash_style() == HashStyle.BOTH, true);
	check(Tag.OPEN_SUSE.get_hash_style() == HashStyle.BOTH, true);
	check(Tag.UBUNTU_FOCAL.get_hash_style() == HashStyle.GNU, true);
	check(Tag.UNKNOWN.get_hash_style().name, "gnu");
	check(Tag.RHEL6.is_redhat(), true);
	check(Tag.FEDORA.is_redhat(), true);
	check(Tag.GENTOO.is_redhat(), false);
	check(Tag.DEBIAN_LENNY.is_debian() && Tag.DEBIAN_TRIXIE.is_debian(), true);
	check(Tag.EXHERBO.is_debian() || Tag.UBUNTU_HARDY.is_debian(), false);
	check(Tag.UBUNTU_HARDY.is_ubuntu() && Tag.UBUNTU_LUNAR.is_ubuntu(), true);
	check(Tag.UNKNOWN.is_ubuntu() || Tag.OPEN_SUSE.is_ubuntu(), false);
	check(Tag.ALPINE.is_alpine() && Tag.GENTOO.is_gentoo() && Tag.OPEN_SUSE.is_open_suse(), true);
}

fn Tag detect_on(MemTree* t, String triple, String sysroot = "")
{
	Env env = { .fs = t.fs(), .target = target::from_triple(triple)!!, .sysroot = sysroot };
	return distro::detect(&env);
}

fn void distro_detect_order() @test
{
	MemTree t;
	t.init(mem);
	defer t.free();
	check(detect_on(&t, "x86_64-linux-gnu") == Tag.UNKNOWN, true); // nothing at all
	t.add_file("/etc/gentoo-release", "Gentoo Base System release 2.14\n");
	check(detect_on(&t, "x86_64-linux-gnu") == Tag.GENTOO, true);
	t.add_file("/etc/debian_version", "12.4\n");
	check(detect_on(&t, "x86_64-linux-gnu") == Tag.DEBIAN_BOOKWORM, true);
	// An unrecognized redhat-release stops the search with UNKNOWN.
	t.add_file("/etc/redhat-release", "Rocky Linux release 9.2\n");
	check(detect_on(&t, "x86_64-linux-gnu") == Tag.UNKNOWN, true);
	t.add_file("/etc/lsb-release", "DISTRIB_CODENAME=jammy\n");
	check(detect_on(&t, "x86_64-linux-gnu") == Tag.UBUNTU_JAMMY, true);
	// os-release without a known ID falls through to lsb-release.
	t.add_file("/etc/os-release", "ID=ubuntu\n");
	check(detect_on(&t, "x86_64-linux-gnu") == Tag.UBUNTU_JAMMY, true);
	t.add_file("/etc/os-release", "ID=arch\n");
	check(detect_on(&t, "x86_64-linux-gnu") == Tag.ARCH, true);
	check(detect_on(&t, "aarch64-linux-musl") == Tag.ARCH, true);
	// Target is not Linux: no files are consulted.
	check(detect_on(&t, "x86_64-windows-gnu") == Tag.UNKNOWN, true);
	check(detect_on(&t, "x86_64-freebsd-none") == Tag.UNKNOWN, true);
	check(detect_on(&t, "aarch64-macos-none") == Tag.UNKNOWN, true);
}

fn void distro_usr_lib_os_release_fallback() @test
{
	MemTree t;
	t.init(mem);
	defer t.free();
	t.add_file("/usr/lib/os-release", "ID=fedora\n");
	check(detect_on(&t, "x86_64-linux-gnu") == Tag.FEDORA, true);
	// /etc/os-release wins when it exists, even if unrecognized (no second read).
	t.add_file("/etc/os-release", "ID=nixos\n");
	check(detect_on(&t, "x86_64-linux-gnu") == Tag.UNKNOWN, true);
}

fn void distro_reads_host_files_not_sysroot() @test
{
	MemTree t;
	t.init(mem);
	defer t.free();
	t.add_file("/sr/etc/os-release", "ID=alpine\n");
	t.add_file("/sr/etc/gentoo-release");
	t.record = true;
	check(detect_on(&t, "x86_64-linux-gnu", "/sr") == Tag.UNKNOWN, true);
	check(t.accessed_with_prefix("/sr"), false);
}

fn void distro_truncated_release_file() @test
{
	MemTree t;
	t.init(mem);
	defer t.free();
	// 64 lines of 16 bytes fill the 1024-byte buffer: the ID line is not seen.
	DString s;
	s.init(mem);
	defer s.free();
	for (int i = 0; i < 64; i++) s.append("COMMENT=xxxxxxx\n");
	s.append("ID=alpine\n");
	check(s.len(), 1034);
	t.add_file("/etc/os-release", s.str_view());
	check(detect_on(&t, "x86_64-linux-gnu") == Tag.UNKNOWN, true);
	// 1018 bytes before the ID line: only "ID=alp" fits, which does not match.
	DString c;
	c.init(mem);
	defer c.free();
	for (int i = 0; i < 63; i++) c.append("COMMENT=xxxxxxx\n");
	c.append("PAD=xxxxx\nID=alpine\n");
	check(c.len(), 1028);
	t.add_file("/etc/os-release", c.str_view());
	check(detect_on(&t, "x86_64-linux-gnu") == Tag.UNKNOWN, true);
	// 1002 bytes before it: the whole line fits.
	t.add_file("/etc/os-release", c.str_view()[16..]);
	check(detect_on(&t, "x86_64-linux-gnu") == Tag.ALPINE, true);
}

// ===========================================================================
// GCCDetector (src/aro/Toolchain/GCCDetector.zig)
//
// Every expected selection below is source-derived (read off GCCDetector.zig
// for the exact synthetic tree built in the test); no Zig executable ran.
// ===========================================================================

fn void collect_counts(String triple, usz lib_dirs, usz triples, usz biarch_lib_dirs, usz biarch_triples)
{
	Env env = { .target = target::from_triple(triple)!! };
	Candidates c;
	gcc_detector::collect_lib_dirs_and_triples(&env, &c);
	check(c.lib_dirs.len, lib_dirs);
	check(c.triple_aliases.len, triples);
	check(c.biarch_lib_dirs.len, biarch_lib_dirs);
	check(c.biarch_triple_aliases.len, biarch_triples);
}

fn void detector_candidate_lists() @test
{
	collect_counts("x86_64-linux-gnu", 2, 11, 4, 11);
	collect_counts("x86_64-linux-gnux32", 2, 2, 4, 20);
	collect_counts("x86-linux-gnu", 2, 0, 0, 0); // x86 has no triple aliases in Zig
	collect_counts("aarch64-linux-gnu", 2, 4, 2, 4);
	collect_counts("aarch64_be-linux-gnu", 1, 2, 1, 2);
	collect_counts("arm-linux-gnueabihf", 1, 4, 0, 0);
	collect_counts("arm-linux-gnueabi", 1, 1, 0, 0);
	collect_counts("armeb-linux-gnueabihf", 1, 2, 0, 0);
	collect_counts("mips-linux-gnu", 2, 5, 3, 8);
	collect_counts("mipsel-linux-gnu", 2, 8, 3, 8);
	collect_counts("mips64-linux-gnuabi64", 2, 6, 3, 7);
	collect_counts("mips64el-linux-gnuabi64", 2, 6, 3, 10);
	collect_counts("powerpc64le-linux-gnu", 2, 5, 2, 3);
	collect_counts("riscv64-linux-gnu", 2, 3, 2, 3);
	collect_counts("sparc64-linux-gnu", 2, 2, 2, 2);
	collect_counts("s390x-linux-gnu", 2, 5, 0, 0);
	collect_counts("loongarch64-linux-gnu", 2, 2, 0, 0);
	collect_counts("m68k-linux-gnu", 1, 3, 0, 0);
	collect_counts("x86_64-linux-android", 2, 1, 2, 1);
	collect_counts("aarch64-linux-android", 2, 1, 0, 0);
	collect_counts("x86_64-illumos-none", 0, 0, 0, 0);
	collect_counts("hexagon-linux-musl", 0, 0, 0, 0);

	Env env = { .target = target::from_triple("x86_64-linux-gnu")!! };
	Candidates c;
	gcc_detector::collect_lib_dirs_and_triples(&env, &c);
	check(c.lib_dirs.items[0], "/lib64");
	check(c.triple_aliases.items[0], "x86_64-linux-gnu");
	check(c.triple_aliases.items[10], "x86_64-amazon-linux");
	check(c.biarch_lib_dirs.items[0], "/libx32");
	check(c.biarch_lib_dirs.items[2], "/lib32");
	check(c.biarch_triple_aliases.items[2], "i586-linux-gnu");
}

fn void detector_prefixes() @test
{
	MemTree t;
	t.init(mem);
	defer t.free();
	GccDetector d;
	d.init(mem);
	defer d.free();
	Env env = { .fs = t.fs(), .target = target::from_triple("x86_64-linux-gnu")!! };
	CandidateList p;
	d.collect_prefixes(&env, &p);
	check(p.len, 1);
	check(p.items[0], "/usr");

	t.add_dir("/opt/rh");
	p = {};
	d.collect_prefixes(&env, &p);
	check(p.len, 14);
	check(p.items[0], "/opt/rh/gcc-toolset-12/root/usr");
	check(p.items[12], "/opt/rh/devtoolset-2/root/usr");
	check(p.items[13], "/usr");

	// /opt/rh is only consulted for Linux targets.
	env.target = target::from_triple("x86_64-freebsd-none")!!;
	p = {};
	d.collect_prefixes(&env, &p);
	check(p.len, 1);
	env.target = target::from_triple("x86_64-linux-gnu")!!;

	// Sysroot: the sysroot itself, then "/usr" ++ sysroot (verbatim Zig
	// concatenation); /opt/rh and the explicit prefix are ignored.
	env.sysroot = "/sr";
	env.gcc_install_prefix = "/opt/gcc";
	p = {};
	d.collect_prefixes(&env, &p);
	check(p.len, 2);
	check(p.items[0], "/sr");
	check(p.items[1], "/usr/sr");
	check(gcc_detector::gcc_toolchain_dir(&env), "");

	// Explicit GCC prefix (no sysroot): alone, one trailing '/' dropped.
	env.sysroot = "";
	env.gcc_install_prefix = "/opt/gcc//";
	p = {};
	d.collect_prefixes(&env, &p);
	check(p.len, 1);
	check(p.items[0], "/opt/gcc/");
	check(gcc_detector::gcc_toolchain_dir(&env), "/opt/gcc//");
}

struct Expect
{
	bool valid;
	String triple;
	String version;
	String install_path;
	String gcc_suffix;
}

fn void expect_selection(MemTree* t, String target_triple, Expect e, String sysroot = "", String prefix = "")
{
	Env env = { .fs = t.fs(), .target = target::from_triple(target_triple)!!, .sysroot = sysroot, .gcc_install_prefix = prefix };
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		GccDetector d;
		d.init(&ta);
		d.discover(&env)!!;
		check(d.is_valid, e.valid);
		List{String} programs;
		programs.init(&ta);
		d.append_tool_path(&ta, &programs);
		if (e.valid)
		{
			check(d.gcc_triple, e.triple);
			check(d.version.major_str, e.version);
			check(d.install_path, e.install_path);
			check(d.selected.gcc_suffix, e.gcc_suffix);
			check(d.selected.os_suffix, e.gcc_suffix);
			String parent = string::tformat("%s/../../..", e.install_path);
			check(d.parent_lib_path, parent);
			check(programs.len(), 1);
			check(programs[0], string::tformat("%s/../%s/bin", parent, e.triple));
		}
		else
		{
			check(d.install_path, "");
			check(programs.len(), 0);
		}
		foreach (s : programs) alloc::free(&ta, s.ptr);
		programs.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void detector_basic_and_missing() @test
{
	MemTree t;
	t.init(mem);
	defer t.free();
	expect_selection(&t, "x86_64-linux-gnu", { .valid = false }); // empty tree
	t.add_dir("/usr/lib/x86_64-linux-gnu");
	expect_selection(&t, "x86_64-linux-gnu", { .valid = false }); // no gcc dir
	t.add_dir("/usr/lib/gcc/x86_64-linux-gnu/12");
	expect_selection(&t, "x86_64-linux-gnu", { .valid = false }); // version dir without crtbegin.o
	t.add_file("/usr/lib/gcc/x86_64-linux-gnu/12/crtbegin.o");
	expect_selection(&t, "x86_64-linux-gnu", { true, "x86_64-linux-gnu", "12", "/usr/lib/gcc/x86_64-linux-gnu/12", "" });
}

fn void detector_competing_versions() @test
{
	MemTree t;
	t.init(mem);
	defer t.free();
	String base = "/usr/lib/gcc/x86_64-linux-gnu/";
	foreach (v : (String[]){ "9", "12.1", "11.3.0", "12", "4.1.0", "4.0" })
	{
		t.add_file(string::tformat("%s%s/crtbegin.o", base, v));
	}
	t.add_dir("/usr/lib/gcc/x86_64-linux-gnu/14"); // no crtbegin.o: skipped
	t.add_file("/usr/lib/gcc/x86_64-linux-gnu/15"); // a file, not a directory
	t.add_file("/usr/lib/gcc/x86_64-linux-gnu/13-junk/crtbegin.o"); // unparsable
	t.add_other("/usr/lib/gcc/x86_64-linux-gnu/16"); // symlink stand-in
	// "12" beats "12.1": a missing minor is preferred.
	expect_selection(&t, "x86_64-linux-gnu", { true, "x86_64-linux-gnu", "12", "/usr/lib/gcc/x86_64-linux-gnu/12", "" });

	// Only versions below 4.1.1: nothing is selected.
	MemTree old;
	old.init(mem);
	defer old.free();
	old.add_file("/usr/lib/gcc/x86_64-linux-gnu/4.1.0/crtbegin.o");
	old.add_file("/usr/lib/gcc/x86_64-linux-gnu/3/crtbegin.o");
	expect_selection(&old, "x86_64-linux-gnu", { .valid = false });
	old.add_file("/usr/lib/gcc/x86_64-linux-gnu/4.1/crtbegin.o");
	expect_selection(&old, "x86_64-linux-gnu", { true, "x86_64-linux-gnu", "4", "/usr/lib/gcc/x86_64-linux-gnu/4.1", "" });
}

fn void detector_alternate_triples() @test
{
	MemTree t;
	t.init(mem);
	defer t.free();
	t.add_file("/usr/lib64/gcc/x86_64-suse-linux/7/crtbegin.o");
	expect_selection(&t, "x86_64-linux-gnu", { true, "x86_64-suse-linux", "7", "/usr/lib64/gcc/x86_64-suse-linux/7", "" });
	// A higher version under another alias and lib dir wins.
	t.add_file("/usr/lib/gcc/x86_64-redhat-linux/11/crtbegin.o");
	expect_selection(&t, "x86_64-linux-gnu", { true, "x86_64-redhat-linux", "11", "/usr/lib/gcc/x86_64-redhat-linux/11", "" });
	// The target's own triple is scanned before the aliases, so an equal
	// version under it (here in gcc-cross) is found first and kept.
	t.add_file("/usr/lib/gcc-cross/x86_64-linux-gnu/11/crtbegin.o");
	expect_selection(&t, "x86_64-linux-gnu", { true, "x86_64-linux-gnu", "11", "/usr/lib/gcc-cross/x86_64-linux-gnu/11", "" });
	// Same triple, equal version: gcc is scanned before gcc-cross and wins.
	t.add_file("/usr/lib/gcc/x86_64-linux-gnu/11/crtbegin.o");
	expect_selection(&t, "x86_64-linux-gnu", { true, "x86_64-linux-gnu", "11", "/usr/lib/gcc/x86_64-linux-gnu/11", "" });
	t.add_file("/usr/lib/gcc-cross/x86_64-linux-gnu/12/crtbegin.o");
	expect_selection(&t, "x86_64-linux-gnu", { true, "x86_64-linux-gnu", "12", "/usr/lib/gcc-cross/x86_64-linux-gnu/12", "" });

	// The 32-bit variant's triple ("i386-linux-gnu", from toLLVMTriple) is a
	// plain (non-biarch) alias of an x86_64 target.
	MemTree u;
	u.init(mem);
	defer u.free();
	u.add_file("/usr/lib/gcc/i386-linux-gnu/10/crtbegin.o");
	expect_selection(&u, "x86_64-linux-gnu", { true, "i386-linux-gnu", "10", "/usr/lib/gcc/i386-linux-gnu/10", "" });

	// aarch64 / Android / cross compilers.
	MemTree a;
	a.init(mem);
	defer a.free();
	a.add_file("/usr/lib/gcc-cross/aarch64-linux-gnu/13/crtbegin.o");
	expect_selection(&a, "aarch64-linux-gnu", { true, "aarch64-linux-gnu", "13", "/usr/lib/gcc-cross/aarch64-linux-gnu/13", "" });
	expect_selection(&a, "aarch64-linux-android", { .valid = false });
	a.add_file("/usr/lib/gcc/aarch64-linux-android/4.9/crtbegin.o");
	expect_selection(&a, "aarch64-linux-android", { true, "aarch64-linux-android", "4", "/usr/lib/gcc/aarch64-linux-android/4.9", "" });
	expect_selection(&a, "x86_64-linux-gnu", { .valid = false }); // nothing for the target
}

fn void detector_32_64_siblings() @test
{
	// x86_64 target, base + /32 multilib: the 64-bit default is selected.
	MemTree t;
	t.init(mem);
	defer t.free();
	t.add_file("/usr/lib/gcc/x86_64-linux-gnu/12/crtbegin.o");
	t.add_file("/usr/lib/gcc/x86_64-linux-gnu/12/32/crtbegin.o");
	expect_selection(&t, "x86_64-linux-gnu", { true, "x86_64-linux-gnu", "12", "/usr/lib/gcc/x86_64-linux-gnu/12", "" });
	// i386 target on the same tree: found through the 64-bit variant's
	// triple, with the /32 multilib.
	expect_selection(&t, "x86-linux-gnu", { true, "x86_64-linux-gnu", "12", "/usr/lib/gcc/x86_64-linux-gnu/12", "/32" });

	// Base + /64 (32-bit-default GCC): x86_64 selects /64.
	MemTree s;
	s.init(mem);
	defer s.free();
	s.add_file("/usr/lib/gcc/x86_64-linux-gnu/12/crtbegin.o");
	s.add_file("/usr/lib/gcc/x86_64-linux-gnu/12/64/crtbegin.o");
	expect_selection(&s, "x86_64-linux-gnu", { true, "x86_64-linux-gnu", "12", "/usr/lib/gcc/x86_64-linux-gnu/12", "/64" });

	// Without /32, an i386 target takes the base directory as its 32-bit default.
	MemTree n;
	n.init(mem);
	defer n.free();
	n.add_file("/usr/lib/gcc/x86_64-linux-gnu/12/crtbegin.o");
	expect_selection(&n, "x86-linux-gnu", { true, "x86_64-linux-gnu", "12", "/usr/lib/gcc/x86_64-linux-gnu/12", "" });

	// Biarch lib dir: an i686 GCC in /usr/lib32 serves x86_64 only via /64.
	MemTree b;
	b.init(mem);
	defer b.free();
	b.add_file("/usr/lib32/gcc/i686-linux-gnu/12/crtbegin.o");
	expect_selection(&b, "x86_64-linux-gnu", { .valid = false });
	b.add_file("/usr/lib32/gcc/i686-linux-gnu/12/64/crtbegin.o");
	expect_selection(&b, "x86_64-linux-gnu", { true, "i686-linux-gnu", "12", "/usr/lib32/gcc/i686-linux-gnu/12", "/64" });

	// x32 (ptrBitWidth 32): an x86_64 GCC with only an /x32 multilib is not
	// usable, because the select flags ask for +m32 (source-derived quirk).
	MemTree x;
	x.init(mem);
	defer x.free();
	x.add_file("/usr/lib/gcc/x86_64-linux-gnu/12/crtbegin.o");
	x.add_file("/usr/lib/gcc/x86_64-linux-gnu/12/x32/crtbegin.o");
	expect_selection(&x, "x86_64-linux-gnux32", { .valid = false });
	x.add_file("/usr/libx32/gcc/x86_64-linux-gnux32/12/crtbegin.o");
	expect_selection(&x, "x86_64-linux-gnux32", { true, "x86_64-linux-gnux32", "12", "/usr/libx32/gcc/x86_64-linux-gnux32/12", "" });
}

fn void detector_unported_multilib_arches() @test
{
	// RISC-V/MIPS/CSKY/MSP430 multilib detection is a TODO in Zig: the empty
	// default multilib is taken without looking for crtbegin.o; AVR has none.
	MemTree t;
	t.init(mem);
	defer t.free();
	t.add_dir("/usr/lib/gcc/riscv64-linux-gnu/13");
	t.add_dir("/usr/lib/gcc/avr/7.3.0");
	t.add_dir("/usr/lib/gcc/mips-linux-gnu/10");
	expect_selection(&t, "riscv64-linux-gnu", { true, "riscv64-linux-gnu", "13", "/usr/lib/gcc/riscv64-linux-gnu/13", "" });
	expect_selection(&t, "avr-freestanding-none", { true, "avr", "7", "/usr/lib/gcc/avr/7.3.0", "" });
	expect_selection(&t, "mips-linux-gnueabihf", { true, "mips-linux-gnu", "10", "/usr/lib/gcc/mips-linux-gnu/10", "" });
}

fn void detector_explicit_prefix_precedence() @test
{
	MemTree t;
	t.init(mem);
	defer t.free();
	t.add_file("/usr/lib/gcc/x86_64-linux-gnu/13/crtbegin.o");
	t.add_file("/opt/gcc/lib/gcc/x86_64-linux-gnu/9/crtbegin.o");
	expect_selection(&t, "x86_64-linux-gnu", { true, "x86_64-linux-gnu", "13", "/usr/lib/gcc/x86_64-linux-gnu/13", "" });
	// The explicit prefix replaces every default prefix, even with an older GCC.
	expect_selection(&t, "x86_64-linux-gnu", { true, "x86_64-linux-gnu", "9", "/opt/gcc/lib/gcc/x86_64-linux-gnu/9", "" }, "", "/opt/gcc/");
	// ... and does not fall back to /usr when it holds nothing.
	expect_selection(&t, "x86_64-linux-gnu", { .valid = false }, "", "/opt/empty");
	// A sysroot disables the explicit prefix.
	t.add_file("/sr/lib/gcc/x86_64-linux-gnu/8/crtbegin.o");
	expect_selection(&t, "x86_64-linux-gnu", { true, "x86_64-linux-gnu", "8", "/sr/lib/gcc/x86_64-linux-gnu/8", "" }, "/sr", "/opt/gcc");

	// /opt/rh toolsets come before /usr, and the first prefix with a GCC wins.
	t.add_file("/opt/rh/devtoolset-9/root/usr/lib/gcc/x86_64-redhat-linux/9/crtbegin.o");
	expect_selection(&t, "x86_64-linux-gnu", { true, "x86_64-redhat-linux", "9", "/opt/rh/devtoolset-9/root/usr/lib/gcc/x86_64-redhat-linux/9", "" });
	t.add_file("/opt/rh/gcc-toolset-12/root/usr/lib/gcc/x86_64-redhat-linux/12/crtbegin.o");
	expect_selection(&t, "x86_64-linux-gnu", { true, "x86_64-redhat-linux", "12", "/opt/rh/gcc-toolset-12/root/usr/lib/gcc/x86_64-redhat-linux/12", "" });
}

<* True when every recorded access starts with one of `allowed`. *>
fn bool accesses_within(MemTree* t, String[] allowed)
{
	foreach (s : t.accesses)
	{
		bool ok = false;
		foreach (a : allowed)
		{
			if (s.starts_with(a)) ok = true;
		}
		if (!ok) return false;
	}
	return true;
}

fn void detector_sysroot_isolation() @test
{
	MemTree t;
	t.init(mem);
	defer t.free();
	// A newer host GCC and /opt/rh must not leak into a sysroot build.
	t.add_file("/usr/lib/gcc/x86_64-linux-gnu/13/crtbegin.o");
	t.add_file("/opt/rh/gcc-toolset-12/root/usr/lib/gcc/x86_64-redhat-linux/12/crtbegin.o");
	t.add_file("/sr/lib/gcc/x86_64-linux-gnu/10/crtbegin.o");
	t.record = true;
	expect_selection(&t, "x86_64-linux-gnu", { true, "x86_64-linux-gnu", "10", "/sr/lib/gcc/x86_64-linux-gnu/10", "" }, "/sr");
	check(accesses_within(&t, { "/sr" }), true);
	t.clear_accesses();

	// Empty sysroot tree: only the sysroot and the "/usr" ++ sysroot prefix
	// (Zig's verbatim concatenation) are looked at; nothing is selected.
	MemTree e;
	e.init(mem);
	defer e.free();
	e.add_file("/usr/lib/gcc/x86_64-linux-gnu/13/crtbegin.o");
	e.add_dir("/opt/rh");
	e.add_dir("/empty");
	e.record = true;
	expect_selection(&e, "x86_64-linux-gnu", { .valid = false }, "/empty");
	check(accesses_within(&e, { "/empty", "/usr/empty" }), true);
	check(e.accessed_with_prefix("/usr/empty"), true);
	check(e.accessed_with_prefix("/opt"), false);

	// The quirky second prefix is real: a GCC under "/usr" ++ sysroot is found.
	e.add_file("/usr/empty/lib/gcc/x86_64-linux-gnu/11/crtbegin.o");
	expect_selection(&e, "x86_64-linux-gnu", { true, "x86_64-linux-gnu", "11", "/usr/empty/lib/gcc/x86_64-linux-gnu/11", "" }, "/empty");
}

fn void detector_without_sysroot_never_reads_outside_prefixes() @test
{
	// Default discovery only touches /opt/rh (existence) and /usr.
	MemTree t;
	t.init(mem);
	defer t.free();
	t.add_file("/usr/lib/gcc/x86_64-linux-gnu/12/crtbegin.o");
	t.record = true;
	expect_selection(&t, "x86_64-linux-gnu", { true, "x86_64-linux-gnu", "12", "/usr/lib/gcc/x86_64-linux-gnu/12", "" });
	check(accesses_within(&t, { "/usr", "/opt/rh" }), true);
	check(t.accessed_with_prefix("/opt/rh/"), false); // /opt/rh is absent
}
