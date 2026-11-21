// Tests for LinkFs and the ELF64 ET_REL/ET_DYN input reader.
// Synthetic ELF fixtures use the small byte builders in data/link_test_builders.c3.
module link_reader_tests;
import aro::backend::object, aro::backend::link;
import aro::frontend::c::diagnostics, aro::host_process, aro::target;
import link_test_builders;
import std::collections::list;
import std::core::mem, std::core::mem::allocators;
import std::io;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

const target::Host HOST = { X86_64, LINUX, GNU };

const uint SHT_PROGBITS = 1;
const uint SHT_RELA = 4;
const uint SHT_NOBITS = 8;
const uint SHT_DYNAMIC = 6;
const uint SHT_GROUP = 17;
const uint SHT_GNU_VERDEF = 0x6ffffffd;
const uint SHT_GNU_VERSYM = 0x6fffffff;
const ulong SHF_ALLOC = 2;
const ulong SHF_WRITE = 1;
const ulong SHF_EXECINSTR = 4;
const ulong SHF_GROUP = 0x200;
const ushort SHN_COMMON = 0xfff2;
const long DT_NEEDED = 1;
const long DT_SONAME = 14;
const long DT_NULL = 0;
const uint GRP_COMDAT = 1;

fn target::Target elf_target()
{
	target::Target? parsed = target::parse_triple("x86_64-linux-gnu", HOST);
	if (catch err = parsed) unreachable("test target must parse");
	return parsed;
}

fn target::Target big_endian_elf_target()
{
	target::Target? parsed = target::parse_triple("aarch64_be-linux-gnu", HOST);
	if (catch err = parsed) unreachable("big-endian test target must parse");
	return parsed;
}

struct BufferSink (OutStream)
{
	ByteWriter bytes;
}

fn void BufferSink.init(&self) => self.bytes.init(mem);
fn sz? BufferSink.write(&self, char[] data) @dynamic => self.bytes.write(data);
fn void? BufferSink.write_byte(&self, char byte) @dynamic => self.bytes.write_byte(byte);
fn void? BufferSink.flush(&self) @dynamic {}
fn void BufferSink.free(&self) { (void)self.bytes.destroy(); }

fn uint read_u32(char[] bytes, ulong at)
{
	uint value = 0;
	for (uint i = 0; i < 4; i++) value |= (uint)bytes[(sz)at + (sz)i] << (i * 8);
	return value;
}

fn ulong read_u64(char[] bytes, ulong at)
{
	ulong value = 0;
	for (uint i = 0; i < 8; i++) value |= (ulong)bytes[(sz)at + (sz)i] << (i * 8);
	return value;
}

fn void patch_u16(char[] bytes, ulong at, ushort value)
{
	for (uint i = 0; i < 2; i++) bytes[(sz)at + (sz)i] = (char)(value >> (i * 8));
}

fn void patch_u32(char[] bytes, ulong at, uint value)
{
	for (uint i = 0; i < 4; i++) bytes[(sz)at + (sz)i] = (char)(value >> (i * 8));
}

fn void patch_u64(char[] bytes, ulong at, ulong value)
{
	for (uint i = 0; i < 8; i++) bytes[(sz)at + (sz)i] = (char)(value >> (i * 8));
}

fn ulong section_header_at(char[] bytes, ushort index)
{
	return read_u64(bytes, 40) + (ulong)index * 64;
}

fn ulong section_data_at(char[] bytes, ushort index)
{
	return read_u64(bytes, section_header_at(bytes, index) + 24);
}

fn link_test_builders::ByteBuffer build_rela_fixture()
{
	link_test_builders::StringTable strings;
	strings.init();
	defer strings.free();
	uint external_name = strings.add("external_fn");

	link_test_builders::ByteBuffer symbols;
	symbols.init();
	defer symbols.free();
	link_test_builders::put_symbol64(&symbols, 0, 0, 0, 0, 0, 0);
	link_test_builders::put_symbol64(&symbols, external_name, 0x10, 0, 0, 0, 0);

	link_test_builders::ByteBuffer rela;
	rela.init();
	defer rela.free();
	rela.put_u64(0);
	rela.put_u64((1UL << 32) | 1);
	rela.put_u64(0);

	link_test_builders::ElfFixtureBuilder builder;
	builder.init();
	defer builder.free();
	ushort text = builder.add_section(".text", SHT_PROGBITS, SHF_ALLOC | SHF_EXECINSTR, 16, "\x90\xC3");
	builder.add_section(".data", SHT_PROGBITS, SHF_ALLOC | SHF_WRITE, 8, "\x11\x22\x33\x44");
	builder.add_string_table(".strtab", &strings);
	ushort symtab = builder.add_symbol_table(".symtab", ".strtab", &symbols, false, 1);
	builder.add_section(".rela.text", SHT_RELA, 0, 8, rela.view(), 24, symtab, text);
	return builder.build();
}

fn link_test_builders::ByteBuffer build_group_fixture(bool bad_member)
{
	link_test_builders::StringTable strings;
	strings.init();
	defer strings.free();
	uint foo_name = strings.add("foo");
	uint common_name = strings.add("common_var");

	link_test_builders::ByteBuffer symbols;
	symbols.init();
	defer symbols.free();
	link_test_builders::put_symbol64(&symbols, 0, 0, 0, 0, 0, 0);
	link_test_builders::put_symbol64(&symbols, foo_name, 0x12, 0, 1, 0, 1);
	link_test_builders::put_symbol64(&symbols, common_name, 0x11, 0, SHN_COMMON, 8, 16);

	link_test_builders::ByteBuffer group;
	group.init();
	defer group.free();
	ushort[1] members = { bad_member ? ushort::max : 1 };
	link_test_builders::put_group(&group, GRP_COMDAT, members[..]);

	link_test_builders::ElfFixtureBuilder builder;
	builder.init();
	defer builder.free();
	builder.add_section(".text.foo", SHT_PROGBITS,
		SHF_ALLOC | SHF_EXECINSTR | SHF_GROUP, 16, "\x90");
	builder.add_section(".group", SHT_GROUP, 0, 4, group.view(), 4, 0, 1, ".symtab");
	builder.add_string_table(".strtab", &strings);
	builder.add_symbol_table(".symtab", ".strtab", &symbols, false, 1);
	return builder.build();
}

fn link_test_builders::ByteBuffer build_dyn_versions_fixture()
{
	link_test_builders::StringTable strings;
	strings.init();
	defer strings.free();
	uint f_name = strings.add("f");
	uint g_name = strings.add("g");
	uint soname_name = strings.add("libx.so.1");
	uint needed_name = strings.add("libdep.so");
	uint base_name = strings.add("BASE");
	uint v1_name = strings.add("V1");
	uint v2_name = strings.add("V2");

	link_test_builders::ByteBuffer symbols;
	symbols.init();
	defer symbols.free();
	link_test_builders::put_symbol64(&symbols, 0, 0, 0, 0, 0, 0);
	link_test_builders::put_symbol64(&symbols, f_name, 0x12, 0, 1, 0, 1);
	link_test_builders::put_symbol64(&symbols, f_name, 0x12, 0, 1, 1, 1);
	link_test_builders::put_symbol64(&symbols, g_name, 0x12, 0, 0, 0, 0);

	link_test_builders::ByteBuffer dynamic;
	dynamic.init();
	defer dynamic.free();
	link_test_builders::put_dynamic_entry(&dynamic, DT_NEEDED, needed_name);
	link_test_builders::put_dynamic_entry(&dynamic, DT_SONAME, soname_name);
	link_test_builders::put_dynamic_entry(&dynamic, DT_NULL, 0);

	link_test_builders::ByteBuffer versym;
	versym.init();
	defer versym.free();
	link_test_builders::put_versym(&versym, 0);
	link_test_builders::put_versym(&versym, 0x8002);
	link_test_builders::put_versym(&versym, 3);
	link_test_builders::put_versym(&versym, 4);

	link_test_builders::ByteBuffer verdef;
	verdef.init();
	defer verdef.free();
	link_test_builders::put_verdef(&verdef, 1, 1, 1, 0, base_name, 28);
	link_test_builders::put_verdef(&verdef, 1, 0, 2, 0, v1_name, 28);
	link_test_builders::put_verdef(&verdef, 1, 0, 3, 0, v2_name);

	link_test_builders::ElfFixtureBuilder builder;
	builder.init(link_test_builders::ET_DYN);
	defer builder.free();
	builder.add_section(".text", SHT_PROGBITS, SHF_ALLOC | SHF_EXECINSTR, 16, "\xC3");
	builder.add_string_table(".dynstr", &strings);
	ushort dynsym = builder.add_symbol_table(".dynsym", ".dynstr", &symbols, true, 1);
	builder.add_section(".dynamic", SHT_DYNAMIC, SHF_ALLOC | SHF_WRITE, 8,
		dynamic.view(), 16, 0, 0, ".dynstr");
	builder.add_section(".gnu.version", SHT_GNU_VERSYM, 0, 2, versym.view(), 2, 0, 0, ".dynsym");
	builder.add_section(".gnu.version_d", SHT_GNU_VERDEF, 0, 4, verdef.view(), 0, 0, 3, ".dynstr");
	(void)dynsym;
	return builder.build();
}

fn void expect_reader_failure(char[] bytes, bool unsupported = false)
{
	DynamicArenaAllocator arena;
	arena.init(mem, 256);
	defer arena.free();
	Diagnostics d;
	d.init_list(mem);
	defer d.free();
	link::ElfFile? result = link::read_elf(&arena, &d, "bad-input.o", bytes);
	if (unsupported)
	{
		check(@catch(result), link::UNSUPPORTED_ELF);
	}
	else
	{
		check(@catch(result), link::MALFORMED_ELF);
	}
	check(d.messages.len(), 1);
	check(d.messages[0].kind.ordinal, diagnostics::MessageKind.ERROR.ordinal);
	check(d.messages[0].effective_kind.ordinal, diagnostics::MessageKind.ERROR.ordinal);
}

fn void expect_no_diagnostics(Diagnostics* d)
{
	check(d.messages.len(), 0);
}

fn String trim_newlines(String text)
{
	while (text.len && (text[text.len - 1] == '\n' || text[text.len - 1] == '\r')) text = text[:text.len - 1];
	return text;
}

fn void reader_round_trips_writer_output() @test
{
	DynamicArenaAllocator arena;
	arena.init(mem, 256);
	defer arena.free();
	object::Object* obj = object::create(&arena, elf_target())!!;
	defer obj.deinit();
	object::get_section(obj, object::SECTION_FUNC).push(0x90);
	object::get_section(obj, object::SECTION_FUNC).push(0xC3);
	object::get_section(obj, object::SECTION_DATA).push(0x11);
	object::get_section(obj, object::SECTION_DATA).push(0x22);
	object::get_section(obj, object::SECTION_DATA).push(0x33);
	object::get_section(obj, object::SECTION_DATA).push(0x44);
	List{char}* custom = object::get_section(obj,
		{ .kind = object::SectionKind.CUSTOM, .custom_name = ".meta" });
	custom.push(0xCA); custom.push(0xFE);
	ulong bss_offset = object::reserve_zero(obj, object::SECTION_BSS, 8, 8);
	String local = object::declare_symbol(obj, object::SECTION_FUNC, "local_fn", true,
		object::Linkage.INTERNAL, object::SymbolType.FUNC, 1, 1);
	String global = object::declare_symbol(obj, object::SECTION_DATA, "global_data", true,
		object::Linkage.STRONG, object::SymbolType.VARIABLE, 2, 2);
	String external = object::declare_symbol(obj, object::SECTION_UNDEFINED, "external_fn", true,
		object::Linkage.STRONG, object::SymbolType.EXTERNAL, 0, 0);
	String unnamed = object::declare_symbol(obj, object::SECTION_FUNC, "", false,
		object::Linkage.INTERNAL, object::SymbolType.FUNC, 0, 2);
	object::declare_symbol(obj, object::SECTION_BSS, "zero_data", true,
		object::Linkage.STRONG, object::SymbolType.VARIABLE, bss_offset, 8);
	String common = object::declare_common(obj, "common_data", 16, 8);
	test::eq(local, "local_fn"); test::eq(global, "global_data");
	test::eq(external, "external_fn"); test::eq(unnamed, ".L.0"); test::eq(common, "common_data");
	object::add_relocation(obj, external, object::SECTION_DATA, 1, -4);

	BufferSink out;
	out.init();
	defer out.free();
	object::finish(obj, &out)!!;
	DynamicArenaAllocator read_arena;
	read_arena.init(mem, 256);
	defer read_arena.free();
	Diagnostics d;
	d.init_list(mem);
	defer d.free();
	link::ElfFile elf = link::read_elf(&read_arena, &d, "writer.o", (char[])out.bytes.str_view())!!;
	expect_no_diagnostics(&d);
	check((uint)elf.kind, (uint)link::ElfKind.REL);
	check(elf.machine, 62);
	check(elf.first_global, 3);

	link::InputSection* text = elf.find_section(".text");
	link::InputSection* data = elf.find_section(".data");
	link::InputSection* meta = elf.find_section("..meta");
	link::InputSection* bss = elf.find_section(".bss");
	link::InputSection* note = elf.find_section(".note.GNU-stack");
	assert(text && data && meta && bss && note, "writer sections are available through the reader");
	check(text.type, SHT_PROGBITS); check(text.flags, 6); check(text.addralign, 16);
	check(text.size, 2); test::eq((String)text.data, "\x90\xC3");
	check(data.type, SHT_PROGBITS); check(data.flags, 3); check(data.addralign, 1);
	check(data.size, 4); test::eq((String)data.data, "\x11\x22\x33\x44");
	check(meta.flags, 6); check(meta.addralign, 16); test::eq((String)meta.data, "\xCA\xFE");
	check(bss.type, SHT_NOBITS); check(bss.flags, 3); check(bss.size, 8); check(bss.data.len, 0);
	check(note.type, SHT_PROGBITS); check(note.flags, 0); check(note.size, 0);
	check(note.addralign, 1);

	link::InputSymbol* local_symbol = elf.find_symbol("local_fn");
	link::InputSymbol* global_symbol = elf.find_symbol("global_data");
	link::InputSymbol* external_symbol = elf.find_symbol("external_fn");
	link::InputSymbol* bss_symbol = elf.find_symbol("zero_data");
	link::InputSymbol* common_symbol = elf.find_symbol("common_data");
	assert(local_symbol && global_symbol && external_symbol && bss_symbol && common_symbol,
		"writer symbols are decoded");
	check(local_symbol.bind, 0); check(local_symbol.type, 2); check(local_symbol.undefined, false);
	check(local_symbol.value, 1); check(local_symbol.size, 1);
	test::eq(elf.sections[local_symbol.section].name, ".text");
	check(global_symbol.bind, 1); check(global_symbol.type, 1);
	check(global_symbol.value, 2); check(global_symbol.size, 2);
	test::eq(elf.sections[global_symbol.section].name, ".data");
	check(external_symbol.undefined, true); check(external_symbol.bind, 1);
	check(external_symbol.type, 0);
	test::eq(external_symbol.name, "external_fn");
	check(bss_symbol.common, false); check(bss_symbol.value, 0); check(bss_symbol.size, 8);
	test::eq(elf.sections[bss_symbol.section].name, ".bss");
	check(common_symbol.common, true); check(common_symbol.undefined, false);
	check(common_symbol.shndx_raw, SHN_COMMON);
	check(common_symbol.value, 8); check(common_symbol.size, 16);

	check(elf.relas.len, 1);
	test::eq(elf.sections[elf.relas[0].target_section].name, ".data");
	check(elf.relas[0].entries.len, 1);
	link::InputRela* relocation = &elf.relas[0].entries[0];
	check(relocation.offset, 1); check(relocation.type, 4); check(relocation.addend, -4);
	test::eq(elf.symbols[relocation.symbol].name, "external_fn");
}

fn void reader_round_trips_explicit_relocations() @test
{
	object::Object* obj = object::create(mem, elf_target())!!;
	defer obj.deinit();
	List{char}* data = object::get_section(obj, object::SECTION_DATA);
	for (uint i = 0; i < 16; i++) data.push(0);
	String external = object::declare_symbol(obj, object::SECTION_UNDEFINED, "reloc_target", true,
		object::Linkage.STRONG, object::SymbolType.EXTERNAL, 0, 0);
	object::set_section_align(obj, object::SECTION_DATA, 8);
	object::add_relocation(obj, external, object::SECTION_DATA, 0, 0, object::RelocKind.ABS64);
	object::add_relocation(obj, external, object::SECTION_DATA, 8, 0, object::RelocKind.REX_GOTPCRELX);
	BufferSink out;
	out.init();
	defer out.free();
	object::finish(obj, &out)!!;
	DynamicArenaAllocator arena;
	arena.init(mem, 256);
	defer arena.free();
	Diagnostics d;
	d.init_list(mem);
	defer d.free();
	link::ElfFile elf = link::read_elf(&arena, &d, "relocs.o", (char[])out.bytes.str_view())!!;
	expect_no_diagnostics(&d);
	link::InputSection* data_section = elf.find_section(".data");
	assert(data_section != null);
	check(data_section.addralign, 8);
	check(elf.relas.len, 1);
	check(elf.relas[0].entries.len, 2);
	check(elf.relas[0].entries[0].type, 1);
	check(elf.relas[0].entries[1].type, 42);
	check(elf.relas[0].entries[1].offset, 8);
}

fn void reader_rejects_malformed_and_unsupported_inputs() @test
{
	link_test_builders::ByteBuffer fixture = build_rela_fixture();
	defer fixture.free();
	String source = fixture.view();

	expect_reader_failure((char[])source[:63]);
	char[] bad_magic = alloc::clone_slice(mem, (char[])source);
	defer alloc::free(mem, bad_magic.ptr);
	bad_magic[0] = 0;
	expect_reader_failure(bad_magic);

	char[] bad_section_offset = alloc::clone_slice(mem, (char[])source);
	defer alloc::free(mem, bad_section_offset.ptr);
	patch_u64(bad_section_offset, 40, (ulong)bad_section_offset.len + 128);
	expect_reader_failure(bad_section_offset);

	// The fixture section order is .text, .data, .strtab, .symtab, .rela.text, .shstrtab.
	char[] bad_symbol_name = alloc::clone_slice(mem, (char[])source);
	defer alloc::free(mem, bad_symbol_name.ptr);
	ulong symtab_data = section_data_at(bad_symbol_name, 4);
	patch_u32(bad_symbol_name, symtab_data + 24, uint::max);
	expect_reader_failure(bad_symbol_name);

	char[] bad_rela_symbol = alloc::clone_slice(mem, (char[])source);
	defer alloc::free(mem, bad_rela_symbol.ptr);
	ulong rela_data = section_data_at(bad_rela_symbol, 5);
	patch_u64(bad_rela_symbol, rela_data + 8, (999UL << 32) | 1);
	expect_reader_failure(bad_rela_symbol);

	char[] executable = alloc::clone_slice(mem, (char[])source);
	defer alloc::free(mem, executable.ptr);
	patch_u16(executable, 16, 2);
	expect_reader_failure(executable, true);

	Object* big_endian = object::create(mem, big_endian_elf_target())!!;
	defer big_endian.deinit();
	BufferSink big_endian_out;
	big_endian_out.init();
	defer big_endian_out.free();
	object::finish(big_endian, &big_endian_out)!!;
	expect_reader_failure((char[])big_endian_out.bytes.str_view(), true);
}

fn void reader_decodes_groups_and_common_symbols() @test
{
	link_test_builders::ByteBuffer fixture = build_group_fixture(false);
	defer fixture.free();
	DynamicArenaAllocator arena;
	arena.init(mem, 256);
	defer arena.free();
	Diagnostics d;
	d.init_list(mem);
	defer d.free();
	link::ElfFile elf = link::read_elf(&arena, &d, "group.o", (char[])fixture.view())!!;
	expect_no_diagnostics(&d);
	check(elf.groups.len, 1);
	link::SectionGroup* group = &elf.groups[0];
	test::eq(group.signature, "foo");
	check(group.comdat, true);
	check(group.members.len, 1);
	check(elf.sections[group.members[0]].group, 1);
	link::InputSymbol* common = elf.find_symbol("common_var");
	assert(common != null);
	check(common.common, true); check(common.value, 8); check(common.size, 16);

	link_test_builders::ByteBuffer bad_fixture = build_group_fixture(true);
	defer bad_fixture.free();
	expect_reader_failure((char[])bad_fixture.view());
}

fn void reader_decodes_synthetic_dynamic_versions() @test
{
	link_test_builders::ByteBuffer fixture = build_dyn_versions_fixture();
	defer fixture.free();
	DynamicArenaAllocator arena;
	arena.init(mem, 256);
	defer arena.free();
	Diagnostics d;
	d.init_list(mem);
	defer d.free();
	link::ElfFile elf = link::read_elf(&arena, &d, "libx.so", (char[])fixture.view())!!;
	expect_no_diagnostics(&d);
	check((uint)elf.kind, (uint)link::ElfKind.DYN);
	check(elf.has_soname, true);
	test::eq(elf.soname, "libx.so.1");
	check(elf.needed.len, 1);
	test::eq(elf.needed[0], "libdep.so");
	link::InputSymbol* v1 = elf.find_symbol("f", "V1");
	link::InputSymbol* v2 = elf.find_symbol("f", "V2");
	link::InputSymbol* undefined = elf.find_symbol("g");
	assert(v1 && v2 && undefined, "versioned and undefined dynamic symbols are present");
	check(v1.version_hidden, true);
	check(v1.undefined, false);
	check(v2.version_hidden, false);
	check(v2.undefined, false);
	check(undefined.undefined, true);
	test::eq(undefined.version, "");
	check(undefined.version_index, 4);
}

fn void scrt1_reader_handles_host_startup_object() @test @feat(POSIX)
{
	ProcessResult result = host_process::run(null, mem, { "gcc", "-print-file-name=Scrt1.o" });
	defer
	{
		if (result.stdout.ptr) alloc::free(mem, result.stdout.ptr);
		if (result.stderr.ptr) alloc::free(mem, result.stderr.ptr);
	}
	String path = "";
	if (result.started && result.exited && result.exit_code == 0) path = trim_newlines((String)result.stdout);
	if (!path.len || path == "Scrt1.o") path = "/usr/lib/x86_64-linux-gnu/Scrt1.o";
	Diagnostics d;
	d.init_list(mem);
	defer d.free();
	link::LinkFs fs;
	fs.init(mem);
	defer fs.free();
	if (!fs.exists(path)) path = "/lib/x86_64-linux-gnu/Scrt1.o";
	if (!fs.exists(path)) return;
	char[] bytes = fs.read(&d, path)!!;
	DynamicArenaAllocator arena;
	arena.init(mem, 256);
	defer arena.free();
	link::ElfFile elf = link::read_elf(&arena, &d, path, bytes)!!;
	expect_no_diagnostics(&d);
	check((uint)elf.kind, (uint)link::ElfKind.REL);
	link::InputSymbol* start = elf.find_symbol("_start");
	link::InputSymbol* libc_start = elf.find_symbol("__libc_start_main");
	link::InputSymbol* main_symbol = elf.find_symbol("main");
	assert(start && libc_start && main_symbol, "Scrt1.o exposes startup references");
	check(start.undefined, false); check(start.bind, 1); check(start.type, 2);
	test::eq(elf.sections[start.section].name, ".text");
	check(libc_start.undefined, true); check(main_symbol.undefined, true);
	bool text_relocations = false;
	foreach (rela : elf.relas)
	{
		if (elf.sections[rela.target_section].name == ".text") text_relocations = true;
	}
	assert(text_relocations, "Scrt1.o contains relocations against its startup text");
}

fn void libc_reader_selects_default_and_compat_versions() @test @feat(POSIX)
{
	Diagnostics d;
	d.init_list(mem);
	defer d.free();
	link::LinkFs fs;
	fs.init(mem);
	defer fs.free();
	String path = "/lib/x86_64-linux-gnu/libc.so.6";
	if (!fs.exists(path)) path = "/usr/lib/x86_64-linux-gnu/libc.so.6";
	if (!fs.exists(path)) return;
	char[] bytes = fs.read(&d, path)!!;
	DynamicArenaAllocator arena;
	arena.init(mem, 1024);
	defer arena.free();
	link::ElfFile elf = link::read_elf(&arena, &d, path, bytes)!!;
	expect_no_diagnostics(&d);
	check((uint)elf.kind, (uint)link::ElfKind.DYN);
	check(elf.has_soname, true);
	test::eq(elf.soname, "libc.so.6");
	link::InputSymbol* current = elf.find_symbol("__libc_start_main", "GLIBC_2.34");
	link::InputSymbol* compatibility = elf.find_symbol("__libc_start_main", "GLIBC_2.2.5");
	assert(current && compatibility, "libc exports both symbol versions");
	check(current.undefined, false); check(current.version_hidden, false);
	check(compatibility.undefined, false); check(compatibility.version_hidden, true);
}

fn void link_fs_overlay_cache_errors_and_lifetime() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	Diagnostics d;
	d.init_list(mem);
	{
	link::LinkFs fs;
	fs.init(&ta);
	fs.add_overlay("libfake.a", "synthetic archive");
	check(fs.exists("libfake.a"), true);
	char[] original_overlay = fs.read(&d, "libfake.a")!!;
	test::eq((String)original_overlay, "synthetic archive");
	fs.add_overlay("libfake.a", "replacement");
	test::eq((String)original_overlay, "synthetic archive");
	test::eq((String)fs.read(&d, "libfake.a")!!, "replacement");

	String disk_path = "/etc/os-release";
	assert(fs.exists(disk_path), "host disk-cache fixture exists");
	char[] first = fs.read(&d, disk_path)!!;
	char[] second = fs.read(&d, disk_path)!!;
	check(first.ptr == second.ptr, true);
	fs.add_overlay(disk_path, "overlay wins");
	test::eq((String)fs.read(&d, disk_path)!!, "overlay wins");
	String libc_link = "/usr/lib/x86_64-linux-gnu/libc.so";
	assert(fs.exists(libc_link), "host libc linker path exists");
	fs.add_overlay(libc_link, "x");
	test::eq((String)fs.read(&d, libc_link)!!, "x");
	expect_no_diagnostics(&d);

	String missing_path = "/definitely-missing-arocc-link-input";
	check(fs.exists(missing_path), false);
	char[]? missing = fs.read(&d, missing_path);
	check(@catch(missing), link::FILE_NOT_FOUND);
	check(d.messages.len(), 1);
	check(d.messages[0].kind.ordinal, diagnostics::MessageKind.ERROR.ordinal);
	check(d.messages[0].effective_kind.ordinal, diagnostics::MessageKind.ERROR.ordinal);

	fs.free();
	}
	check(ta.allocation_count(), 0);
	d.free();
	ta.free();
}
