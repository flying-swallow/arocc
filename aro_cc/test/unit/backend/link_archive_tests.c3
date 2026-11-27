// Synthetic GNU archive and linker-script tests, plus host format cross-checks.
module link_archive_tests;
import aro::backend::link;
import aro::compiler::reporting;
import link_test_builders;
import std::core::mem, std::core::mem::allocators, std::core::string;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

fn void expect_no_diagnostics(Collector* d)
{
	check(d.messages.len(), 0);
}

fn void expect_diagnostic_error(Collector* d)
{
	check(d.messages.len(), 1);
	check(d.messages[0].kind.ordinal, reporting::Severity.ERROR.ordinal);
}

fn void expect_archive_failure(char[] bytes, bool unsupported = false)
{
	DynamicArenaAllocator arena;
	arena.init(mem, 256);
	defer arena.free();
	Collector d;
	d.init(mem);
	defer d.free();
	link::Archive? parsed = link::read_archive(&arena, d.tooling_sink(), "bad.a", bytes);
	if (unsupported)
	{
		check(@catch(parsed), link::UNSUPPORTED_ARCHIVE);
	}
	else
	{
		check(@catch(parsed), link::MALFORMED_ARCHIVE);
	}
	expect_diagnostic_error(&d);
}

fn void expect_member_failure(char[] bytes)
{
	DynamicArenaAllocator arena;
	arena.init(mem, 256);
	defer arena.free();
	Collector d;
	d.init(mem);
	defer d.free();
	link::Archive archive = link::read_archive(&arena, d.tooling_sink(), "bad.a", bytes)!!;
	expect_no_diagnostics(&d);
	ulong cursor = archive.first_member;
	link::ArchiveMember member;
	bool? parsed = archive.next_member(d.tooling_sink(), &cursor, &member);
	check(@catch(parsed), link::MALFORMED_ARCHIVE);
	expect_diagnostic_error(&d);
}

fn void expect_script_failure(String text, bool unsupported, uint line)
{
	DynamicArenaAllocator arena;
	arena.init(mem, 256);
	defer arena.free();
	Collector d;
	d.init(mem);
	defer d.free();
	link::LdScript? parsed = link::parse_ld_script(&arena, d.tooling_sink(), "bad.ld", text);
	if (unsupported)
	{
		check(@catch(parsed), link::UNSUPPORTED_SCRIPT);
	}
	else
	{
		check(@catch(parsed), link::MALFORMED_SCRIPT);
	}
	expect_diagnostic_error(&d);
	if (!unsupported)
	{
		assert(d.messages[0].text.contains(string::tformat("bad.ld:%d:", line)),
			"script diagnostic includes the source line");
	}
}

fn void set_ascii(link_test_builders::ByteBuffer* bytes, ulong offset, String value, ulong width)
{
	assert(value.len <= width, "field value fits its fixed width");
	for (ulong i = 0; i < width; i++)
	{
		bytes.data.entries[(sz)(offset + i)] = i < (ulong)value.len ? value[(sz)i] : ' ';
	}
}

fn void set_be_u32(link_test_builders::ByteBuffer* bytes, ulong offset, uint value)
{
	for (uint i = 0; i < 4; i++)
	{
		bytes.data.entries[(sz)(offset + i)] = (char)(value >> ((3 - i) * 8));
	}
}

fn link_test_builders::ByteBuffer build_one_symbol_archive()
{
	link_test_builders::ArBuilder builder;
	builder.init();
	defer builder.free();
	uint member = builder.add_member("one.o", "x");
	builder.add_symbol(member, "foo");
	return builder.build();
}

fn void synthetic_archive_members_and_index() @test
{
	link_test_builders::ArBuilder builder;
	builder.init();
	defer builder.free();
	uint short_member_index = builder.add_member("short.o", "abc");
	uint long_member_index = builder.add_member("a_very_long_member_name.o", "wxyz");
	builder.add_symbol(short_member_index, "foo");
	builder.add_symbol(long_member_index, "bar");
	builder.add_symbol(long_member_index, "baz");
	link_test_builders::ByteBuffer bytes = builder.build();
	defer bytes.free();

	DynamicArenaAllocator arena;
	arena.init(mem, 256);
	defer arena.free();
	Collector d;
	d.init(mem);
	defer d.free();
	link::Archive archive = link::read_archive(&arena, d.tooling_sink(), "synthetic.a", (char[])bytes.view())!!;
	expect_no_diagnostics(&d);
	check(archive.symbols.len, 3);
	test::eq(archive.symbols[0].name, "foo");
	test::eq(archive.symbols[1].name, "bar");
	test::eq(archive.symbols[2].name, "baz");
	check(archive.symbols[0].member_offset > 8, true);
	assert(archive.symbols[0].member_offset != archive.symbols[1].member_offset);
	check(archive.symbols[1].member_offset, archive.symbols[2].member_offset);
	link::ArchiveMember foo_member = archive.member_at(d.tooling_sink(), archive.symbols[0].member_offset)!!;
	test::eq(foo_member.name, "short.o");
	link::ArchiveSymbol* baz = archive.find_symbol("baz");
	assert(baz != null);
	link::ArchiveMember baz_member = archive.member_at(d.tooling_sink(), baz.member_offset)!!;
	test::eq(baz_member.name, "a_very_long_member_name.o");
	test::eq((String)baz_member.data, "wxyz");
	check(baz_member.size, 4);
	check(baz_member.data_offset, baz_member.header_offset + 60);

	ulong cursor = archive.first_member;
	link::ArchiveMember member;
	bool? has_member = archive.next_member(d.tooling_sink(), &cursor, &member);
	check(has_member!!, true);
	test::eq(member.name, "short.o");
	test::eq((String)member.data, "abc");
	check(member.size, 3);
	has_member = archive.next_member(d.tooling_sink(), &cursor, &member);
	check(has_member!!, true);
	test::eq(member.name, "a_very_long_member_name.o");
	test::eq((String)member.data, "wxyz");
	check(member.size, 4);
	has_member = archive.next_member(d.tooling_sink(), &cursor, &member);
	check(has_member!!, false);
	expect_no_diagnostics(&d);
}

fn void archive_without_index_or_long_names() @test
{
	link_test_builders::ArBuilder builder;
	builder.init(false);
	defer builder.free();
	builder.add_member("one.o", "1");
	builder.add_member("two.o", "22");
	link_test_builders::ByteBuffer bytes = builder.build();
	defer bytes.free();

	DynamicArenaAllocator arena;
	arena.init(mem, 256);
	defer arena.free();
	Collector d;
	d.init(mem);
	defer d.free();
	link::Archive archive = link::read_archive(&arena, d.tooling_sink(), "no-index.a", (char[])bytes.view())!!;
	expect_no_diagnostics(&d);
	check(archive.symbols.len, 0);
	ulong cursor = archive.first_member;
	link::ArchiveMember member;
	bool? has_member = archive.next_member(d.tooling_sink(), &cursor, &member);
	check(has_member!!, true);
	test::eq(member.name, "one.o");
	has_member = archive.next_member(d.tooling_sink(), &cursor, &member);
	check(has_member!!, true);
	test::eq(member.name, "two.o");
	has_member = archive.next_member(d.tooling_sink(), &cursor, &member);
	check(has_member!!, false);
	expect_no_diagnostics(&d);
}

fn void empty_archive() @test
{
	link_test_builders::ByteBuffer bytes;
	bytes.init();
	defer bytes.free();
	bytes.put_bytes("!<arch>\n");

	DynamicArenaAllocator arena;
	arena.init(mem, 256);
	defer arena.free();
	Collector d;
	d.init(mem);
	defer d.free();
	link::Archive archive = link::read_archive(&arena, d.tooling_sink(), "empty.a", (char[])bytes.view())!!;
	expect_no_diagnostics(&d);
	check(archive.symbols.len, 0);
	ulong cursor = archive.first_member;
	link::ArchiveMember member;
	bool? has_member = archive.next_member(d.tooling_sink(), &cursor, &member);
	check(has_member!!, false);
	expect_no_diagnostics(&d);
}

fn void archive_rejects_malformed() @test
{
	link_test_builders::ByteBuffer bytes;
	bytes.init();
	bytes.put_bytes("!<arch>\n");
	bytes.data.entries[0] = 'X';
	check(link::is_archive((char[])bytes.view()), false);
	expect_archive_failure((char[])bytes.view());
	bytes.free();

	bytes.init();
	bytes.put_bytes("!<thin>\n");
	check(link::is_archive((char[])bytes.view()), true);
	expect_archive_failure((char[])bytes.view(), true);
	bytes.free();

	link_test_builders::ArBuilder builder;
	builder.init(false);
	defer builder.free();
	builder.add_member("one.o", "x");
	link_test_builders::ByteBuffer fixture = builder.build();
	defer fixture.free();
	// The first regular member starts at byte 8; fmag is the final two header bytes.
	fixture.data.entries[66] = '!';
	expect_member_failure((char[])fixture.view());
	fixture.data.entries[66] = '`';

	set_ascii(&fixture, 56, "12x", 10);
	expect_member_failure((char[])fixture.view());
	set_ascii(&fixture, 56, "9999999999", 10);
	expect_member_failure((char[])fixture.view());

	link_test_builders::ByteBuffer indexed = build_one_symbol_archive();
	defer indexed.free();
	// The GNU index data begins at byte 68; replace its count with 0x40000000.
	set_be_u32(&indexed, 68, 0x40000000);
	expect_archive_failure((char[])indexed.view());

	link_test_builders::ArBuilder no_index_builder;
	no_index_builder.init(false);
	defer no_index_builder.free();
	no_index_builder.add_member("short.o", "x");
	link_test_builders::ByteBuffer bad_long_ref = no_index_builder.build();
	defer bad_long_ref.free();
	set_ascii(&bad_long_ref, 8, "/999", 16);
	link_test_builders::ByteBuffer bad_offset = build_one_symbol_archive();
	defer bad_offset.free();
	// The first index offset is at byte 72; an odd offset cannot name a member header.
	set_be_u32(&bad_offset, 72, 69);

	DynamicArenaAllocator arena;
	arena.init(mem, 256);
	defer arena.free();
	Collector d;
	d.init(mem);
	defer d.free();
	link::Archive no_table = link::read_archive(&arena, d.tooling_sink(), "no-table.a", (char[])bad_long_ref.view())!!;
	expect_no_diagnostics(&d);
	ulong no_table_cursor = no_table.first_member;
	link::ArchiveMember no_table_member;
	bool? invalid_name = no_table.next_member(d.tooling_sink(), &no_table_cursor, &no_table_member);
	check(@catch(invalid_name), link::MALFORMED_ARCHIVE);
	expect_diagnostic_error(&d);
	d.free();
	d.init(mem);
	link::Archive parsed_offset = link::read_archive(&arena, d.tooling_sink(), "bad-offset.a", (char[])bad_offset.view())!!;
	expect_no_diagnostics(&d);
	check(parsed_offset.symbols[0].member_offset, 69);
	link::ArchiveMember? invalid_member = parsed_offset.member_at(d.tooling_sink(), parsed_offset.symbols[0].member_offset);
	check(@catch(invalid_member), link::MALFORMED_ARCHIVE);
	expect_diagnostic_error(&d);
}

fn void host_libc_nonshared() @test @feat(POSIX)
{
	Collector d;
	d.init(mem);
	defer d.free();
	link::LinkFs fs;
	fs.init(mem);
	defer fs.free();
	String path = "/usr/lib/x86_64-linux-gnu/libc_nonshared.a";
	if (!fs.exists(path)) return;
	char[] bytes = fs.read(d.tooling_sink(), path)!!;
	DynamicArenaAllocator arena;
	arena.init(mem, 1024);
	defer arena.free();
	link::Archive archive = link::read_archive(&arena, d.tooling_sink(), path, bytes)!!;
	expect_no_diagnostics(&d);
	assert(archive.symbols.len > 0);
	// Confirmed with `nm -s`: atexit is present in the host archive index.
	link::ArchiveSymbol* symbol = archive.find_symbol("atexit");
	assert(symbol != null, "host libc_nonshared indexes atexit");
	link::ArchiveMember member = archive.member_at(d.tooling_sink(), symbol.member_offset)!!;
	link::ElfFile elf = link::read_elf(&arena, d.tooling_sink(),
		string::tformat("%s(%s)", path, member.name), member.data)!!;
	check((uint)elf.kind, (uint)link::ElfKind.REL);
	link::InputSymbol* definition = elf.find_symbol("atexit");
	assert(definition != null && !definition.undefined, "indexed archive member defines atexit");
	expect_no_diagnostics(&d);
}

fn void synthetic_ld_script_inputs() @test
{
	String libc_script = "OUTPUT_FORMAT(elf64-x86-64)\nGROUP ( /usr/lib/x86_64-linux-gnu/libc.so.6 /usr/lib/x86_64-linux-gnu/libc_nonshared.a AS_NEEDED ( /lib64/ld-linux-x86-64.so.2 ) )";
	DynamicArenaAllocator arena;
	arena.init(mem, 256);
	defer arena.free();
	Collector d;
	d.init(mem);
	defer d.free();
	link::LdScript libc = link::parse_ld_script(&arena, d.tooling_sink(), "libc.so", libc_script)!!;
	expect_no_diagnostics(&d);
	check(libc.inputs.len, 3);
	test::eq(libc.output_format, "elf64-x86-64");
	check(libc.has_output_format, true);
	test::eq((uint)libc.inputs[0].kind, (uint)link::ScriptInputKind.PATH);
	test::eq(libc.inputs[0].name, "/usr/lib/x86_64-linux-gnu/libc.so.6");
	check(libc.inputs[0].in_group, true);
	check(libc.inputs[0].as_needed, false);
	test::eq(libc.inputs[1].name, "/usr/lib/x86_64-linux-gnu/libc_nonshared.a");
	check(libc.inputs[1].in_group, true);
	check(libc.inputs[1].as_needed, false);
	test::eq(libc.inputs[2].name, "/lib64/ld-linux-x86-64.so.2");
	check(libc.inputs[2].in_group, true);
	check(libc.inputs[2].as_needed, true);
	check(libc.inputs[2].is_absolute(), true);

	link::LdScript gcc = link::parse_ld_script(&arena, d.tooling_sink(), "libgcc_s.so",
		"GROUP ( libgcc_s.so.1 -lgcc )")!!;
	expect_no_diagnostics(&d);
	check(gcc.inputs.len, 2);
	test::eq((uint)gcc.inputs[0].kind, (uint)link::ScriptInputKind.PATH);
	test::eq(gcc.inputs[0].name, "libgcc_s.so.1");
	check(gcc.inputs[0].is_absolute(), false);
	test::eq((uint)gcc.inputs[1].kind, (uint)link::ScriptInputKind.LIB);
	test::eq(gcc.inputs[1].name, "gcc");
	check(gcc.inputs[0].in_group, true);
	check(gcc.inputs[1].in_group, true);

	link::LdScript input = link::parse_ld_script(&arena, d.tooling_sink(), "input.ld",
		"INPUT(a.o, \"b c.o\" -lm)")!!;
	check(input.inputs.len, 3);
	test::eq(input.inputs[0].name, "a.o");
	test::eq(input.inputs[1].name, "b c.o");
	test::eq((uint)input.inputs[2].kind, (uint)link::ScriptInputKind.LIB);
	test::eq(input.inputs[2].name, "m");
	foreach (script_input : input.inputs) check(script_input.in_group, false);

	link::LdScript comments = link::parse_ld_script(&arena, d.tooling_sink(), "comments.ld",
		"INPUT(/* before token */ a.o, /* across\nlines */ b.o)")!!;
	check(comments.inputs.len, 2);
	test::eq(comments.inputs[1].name, "b.o");

	link::LdScript formats = link::parse_ld_script(&arena, d.tooling_sink(), "formats.ld",
		"OUTPUT_FORMAT(first, second, third) INPUT(x.o)")!!;
	test::eq(formats.output_format, "first");
	check(formats.has_output_format, true);
	check(link::looks_like_script((char[])libc_script), true);
	char[4] elf_magic = { (char)0x7f, 'E', 'L', 'F' };
	check(link::looks_like_script(elf_magic[..]), false);
	char[8] archive_magic = { '!', '<', 'a', 'r', 'c', 'h', '>', '\n' };
	check(link::looks_like_script(archive_magic[..]), false);
}

fn void ld_script_rejects_malformed_and_unsupported() @test
{
	expect_script_failure("GROUP(a.o)\n/* unterminated", false, 2);
	expect_script_failure("GROUP (\n a.o\n", false, 3);
	expect_script_failure("GROUP()", false, 1);
	expect_script_failure("INPUT(-l)", false, 1);
	expect_script_failure("SEARCH_DIR(/x)", true, 1);
	expect_script_failure("GROUP(AS_NEEDED(AS_NEEDED(a.o)))", true, 1);
}

fn void host_libc_so_script() @test @feat(POSIX)
{
	String path = "/usr/lib/x86_64-linux-gnu/libc.so";
	Collector d;
	d.init(mem);
	defer d.free();
	link::LinkFs fs;
	fs.init(mem);
	defer fs.free();
	if (!fs.exists(path)) return;
	char[] bytes = fs.read(d.tooling_sink(), path)!!;
	assert(link::looks_like_script(bytes));
	DynamicArenaAllocator arena;
	arena.init(mem, 256);
	defer arena.free();
	link::LdScript script = link::parse_ld_script(&arena, d.tooling_sink(), path, (String)bytes)!!;
	check(script.inputs.len, 3);
	test::eq(script.output_format, "elf64-x86-64");
	check(script.inputs[2].as_needed, true);
	expect_no_diagnostics(&d);
}

fn void host_libgcc_s_script() @test @feat(POSIX)
{
	Collector d;
	d.init(mem);
	defer d.free();
	link::LinkFs fs;
	fs.init(mem);
	defer fs.free();
	String path = "";
	char[] bytes;
	for (int version = 20; version >= 9; version -= 1)
	{
		String candidate = string::tformat("/usr/lib/gcc/x86_64-linux-gnu/%d/libgcc_s.so", version);
		if (!fs.exists(candidate)) continue;
		char[] candidate_bytes = fs.read(d.tooling_sink(), candidate)!!;
		if (!link::looks_like_script(candidate_bytes)) continue;
		path = candidate;
		bytes = candidate_bytes;
		break;
	}
	if (!path.len) return;
	DynamicArenaAllocator arena;
	arena.init(mem, 256);
	defer arena.free();
	link::LdScript script = link::parse_ld_script(&arena, d.tooling_sink(), path, (String)bytes)!!;
	bool saw_relative_soname = false;
	bool saw_gcc = false;
	foreach (script_input : script.inputs)
	{
		if (script_input.kind == link::ScriptInputKind.PATH && !script_input.is_absolute() &&
			script_input.name.starts_with("libgcc_s.so")) saw_relative_soname = true;
		if (script_input.kind == link::ScriptInputKind.LIB && script_input.name == "gcc") saw_gcc = true;
	}
	assert(saw_relative_soname, "host libgcc script has a relative libgcc_s path");
	assert(saw_gcc, "host libgcc script contains the gcc library input");
	expect_no_diagnostics(&d);
}
