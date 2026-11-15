// Direct tests for the public object API and its ELF64 writer.
// Expected output properties are source-derived from src/backend/Object.zig
// and src/backend/Object/Elf.zig. The decoder below reads bytes independently
// of the encoder's in-memory section and symbol structures.
module elf_tests;
import aro::backend::object, aro::target;
import std::io, std::collections::list, std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

const target::Host HOST = { X86_64, LINUX, GNU };

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

struct SectionHeader
{
	uint name;
	uint type;
	ulong flags;
	ulong offset;
	ulong size;
	uint link;
	uint info;
	ulong align;
	ulong entsize;
}

struct ElfView
{
	String bytes;
	ulong shoff;
	ushort shentsize;
	ushort shnum;
	ushort shstrndx;
}

fn char byte_at(ElfView* elf, ulong at)
{
	assert(at < elf.bytes.len, "ELF read outside file");
	return elf.bytes[(sz)at];
}

fn ushort read_u16(ElfView* elf, ulong at)
{
	return (ushort)byte_at(elf, at) | ((ushort)byte_at(elf, at + 1) << 8);
}

fn uint read_u32(ElfView* elf, ulong at)
{
	uint value = 0;
	for (uint i = 0; i < 4; i++) value |= (uint)byte_at(elf, at + i) << (i * 8);
	return value;
}

fn ulong read_u64(ElfView* elf, ulong at)
{
	ulong value = 0;
	for (uint i = 0; i < 8; i++) value |= (ulong)byte_at(elf, at + i) << (i * 8);
	return value;
}

fn ElfView decode_elf(String bytes)
{
	assert(bytes.len >= 64, "ELF header is truncated");
	ElfView raw = { .bytes = bytes };
	ElfView elf = {
		.bytes = bytes,
		.shoff = read_u64(&raw, 40),
		.shentsize = read_u16(&raw, 58),
		.shnum = read_u16(&raw, 60),
		.shstrndx = read_u16(&raw, 62),
	};
	check(bytes[0], 0x7f);
	check(bytes[1], 'E'); check(bytes[2], 'L'); check(bytes[3], 'F');
	check(bytes[4], 2); // ELFCLASS64
	check(bytes[5], 1); // little endian
	check(bytes[6], 1); // current ELF version
	check(read_u16(&elf, 16), 1); // ET_REL
	check(read_u16(&elf, 18), 62); // EM_X86_64
	check(read_u32(&elf, 20), 1);
	check(read_u64(&elf, 24), 0); // entry
	check(read_u64(&elf, 32), 0); // no program headers
	check(read_u16(&elf, 54), 0);
	check(read_u16(&elf, 56), 0);
	check(read_u16(&elf, 52), 64); // ELF header size
	check(elf.shentsize, 64);
	check(elf.shstrndx, 1); // ELF writer stores section names in .strtab
	assert(elf.shnum >= 3, "ELF has the null, string, and symbol table sections");
	assert(elf.shoff + (ulong)elf.shentsize * elf.shnum <= bytes.len, "section headers fit in the output");
	return elf;
}

fn SectionHeader section_header(ElfView* elf, ushort index)
{
	assert(index < elf.shnum, "section index out of range");
	ulong at = elf.shoff + (ulong)index * elf.shentsize;
	return {
		.name = read_u32(elf, at),
		.type = read_u32(elf, at + 4),
		.flags = read_u64(elf, at + 8),
		.offset = read_u64(elf, at + 24),
		.size = read_u64(elf, at + 32),
		.link = read_u32(elf, at + 40),
		.info = read_u32(elf, at + 44),
		.align = read_u64(elf, at + 48),
		.entsize = read_u64(elf, at + 56),
	};
}

fn bool cstr_at(String bytes, ulong at, String expected)
{
	if (at + expected.len >= bytes.len) return false;
	for (sz i = 0; i < expected.len; i++) if (bytes[(sz)at + i] != expected[i]) return false;
	return bytes[(sz)at + expected.len] == 0;
}

fn String section_names(ElfView* elf)
{
	SectionHeader names = section_header(elf, elf.shstrndx);
	assert(names.offset + names.size <= elf.bytes.len, "section name strings fit in the output");
	return elf.bytes[(sz)names.offset : (sz)(names.offset + names.size)];
}

fn ushort find_section(ElfView* elf, String wanted)
{
	String names = section_names(elf);
	for (ushort i = 0; i < elf.shnum; i++)
	{
		SectionHeader sh = section_header(elf, i);
		if (sh.name < names.len && cstr_at(names, sh.name, wanted)) return i;
	}
	unreachable("expected section not found");
}

fn void expect_symbol(ElfView* elf, String wanted, char info, ushort section_index, ulong offset, ulong size)
{
	SectionHeader symtab = section_header(elf, find_section(elf, ".symtab"));
	SectionHeader strtab = section_header(elf, (ushort)symtab.link);
	String names = elf.bytes[(sz)strtab.offset : (sz)(strtab.offset + strtab.size)];
	assert(symtab.entsize == 24, "ELF64 symbol entries are 24 bytes");
	assert(symtab.size % symtab.entsize == 0, "symbol table contains whole entries");
	bool found = false;
	for (ulong i = 1; i < symtab.size / symtab.entsize; i++)
	{
		ulong at = symtab.offset + i * symtab.entsize;
		uint name = read_u32(elf, at);
		if (name >= names.len || !cstr_at(names, name, wanted)) continue;
		check(byte_at(elf, at + 4), info);
		check(read_u16(elf, at + 6), section_index);
		check(read_u64(elf, at + 8), offset);
		check(read_u64(elf, at + 16), size);
		found = true;
	}
	assert(found, "symbol exists in serialized symbol table");
}

fn ulong find_symbol_index(ElfView* elf, String wanted)
{
	SectionHeader symtab = section_header(elf, find_section(elf, ".symtab"));
	SectionHeader strtab = section_header(elf, (ushort)symtab.link);
	String names = elf.bytes[(sz)strtab.offset : (sz)(strtab.offset + strtab.size)];
	for (ulong i = 1; i < symtab.size / symtab.entsize; i++)
	{
		ulong at = symtab.offset + i * symtab.entsize;
		uint name = read_u32(elf, at);
		if (name < names.len && cstr_at(names, name, wanted)) return i;
	}
	unreachable("expected symbol not found");
}

struct BufferSink (OutStream)
{
	ByteWriter bytes;
}

fn void BufferSink.init(&self)
{
	self.bytes.init(mem);
}

fn sz? BufferSink.write(&self, char[] data) @dynamic => self.bytes.write(data);
fn void? BufferSink.write_byte(&self, char byte) @dynamic => self.bytes.write_byte(byte);
fn void? BufferSink.flush(&self) @dynamic {}

fn void BufferSink.free(&self)
{
	(void)self.bytes.destroy();
}

struct OneByteSink (OutStream)
{
	ByteWriter bytes;
	uint writes;
}

fn void OneByteSink.init(&self)
{
	self.bytes.init(mem);
	self.writes = 0;
}

fn sz? OneByteSink.write(&self, char[] data) @dynamic
{
	if (!data.len) return 0;
	self.writes++;
	return self.bytes.write(data[:1]);
}

fn void? OneByteSink.write_byte(&self, char byte) @dynamic
{
	self.writes++;
	return self.bytes.write_byte(byte);
}

fn void? OneByteSink.flush(&self) @dynamic {}

fn void OneByteSink.free(&self)
{
	(void)self.bytes.destroy();
}

fn void sections_symbols_and_relocation() @test
{
	// The source writer stores generated symbol names in an arena.
	DynamicArenaAllocator arena;
	arena.init(mem, 128);
	defer arena.free();
	Object* obj = object::create(&arena, elf_target())!!;
	defer obj.deinit();

	List{char}* text = object::get_section(obj, object::SECTION_FUNC);
	text.push(0x90); text.push(0xC3);
	List{char}* data = object::get_section(obj, object::SECTION_DATA);
	data.push(0x11); data.push(0x22); data.push(0x33); data.push(0x44);
	List{char}* custom = object::get_section(obj, { .kind = object::SectionKind.CUSTOM, .custom_name = ".meta" });
	custom.push(0xCA); custom.push(0xFE);

	String local = object::declare_symbol(obj, object::SECTION_FUNC, "local_fn", true, object::Linkage.INTERNAL, object::SymbolType.FUNC, 1, 1);
	String global = object::declare_symbol(obj, object::SECTION_DATA, "global_data", true, object::Linkage.STRONG, object::SymbolType.VARIABLE, 2, 2);
	String external = object::declare_symbol(obj, object::SECTION_UNDEFINED, "external_fn", true, object::Linkage.STRONG, object::SymbolType.EXTERNAL, 0, 0);
	String unnamed = object::declare_symbol(obj, object::SECTION_FUNC, "", false, object::Linkage.INTERNAL, object::SymbolType.FUNC, 0, 2);
	test::eq(local, "local_fn"); test::eq(global, "global_data"); test::eq(external, "external_fn");
	test::eq(unnamed, ".L.0");
	object::add_relocation(obj, external, object::SECTION_DATA, 1, -4);

	BufferSink out;
	out.init();
	defer out.free();
	object::finish(obj, &out)!!;
	ElfView elf = decode_elf(out.bytes.str_view());

	ushort text_index = find_section(&elf, ".text");
	ushort data_index = find_section(&elf, ".data");
	ushort meta_index = find_section(&elf, "..meta");
	SectionHeader text_sh = section_header(&elf, text_index);
	SectionHeader data_sh = section_header(&elf, data_index);
	SectionHeader meta_sh = section_header(&elf, meta_index);
	check(text_sh.type, 1); check(text_sh.flags, 6); check(text_sh.size, 2); check(text_sh.align, 16);
	check(data_sh.type, 1); check(data_sh.flags, 3); check(data_sh.size, 4); check(data_sh.align, 1);
	check(meta_sh.flags, 6); check(meta_sh.size, 2); check(meta_sh.align, 16);
	assert(text_sh.offset + text_sh.size <= elf.bytes.len, "text payload fits");
	assert(data_sh.offset + data_sh.size <= elf.bytes.len, "data payload fits");
	check(byte_at(&elf, text_sh.offset), 0x90); check(byte_at(&elf, text_sh.offset + 1), 0xC3);
	check(byte_at(&elf, data_sh.offset), 0x11); check(byte_at(&elf, data_sh.offset + 3), 0x44);
	check(byte_at(&elf, meta_sh.offset), 0xCA); check(byte_at(&elf, meta_sh.offset + 1), 0xFE);

	expect_symbol(&elf, "local_fn", 0x02, text_index, 1, 1); // STB_LOCAL | STT_FUNC
	expect_symbol(&elf, ".L.0", 0x02, text_index, 0, 2);
	expect_symbol(&elf, "global_data", 0x11, data_index, 2, 2); // STB_GLOBAL | STT_OBJECT
	expect_symbol(&elf, "external_fn", 0x10, 0, 0, 0); // undefined STB_GLOBAL | STT_NOTYPE

	ushort rela_index = find_section(&elf, ".rela.data");
	SectionHeader rela = section_header(&elf, rela_index);
	check(rela.type, 4); // SHT_RELA
	check(rela.link, find_section(&elf, ".symtab"));
	check(rela.info, data_index);
	check(rela.entsize, 24); check(rela.size, 24); check(rela.align, 8);
	check(read_u64(&elf, rela.offset), 1);
	ulong info = read_u64(&elf, rela.offset + 8);
	check((uint)info, 4); // x86-64 relocation type selected for an undefined symbol
	check(info >> 32, find_symbol_index(&elf, "external_fn"));
	check(read_u64(&elf, rela.offset + 16), (ulong)-4);

	SectionHeader symtab = section_header(&elf, find_section(&elf, ".symtab"));
	check(symtab.type, 2); check(symtab.link, find_section(&elf, ".strtab"));
	check(symtab.entsize, 24); check(symtab.size, 5 * 24); check(symtab.align, 8);
	check(symtab.info, 3); // null symbol plus the two local symbols
	check(section_header(&elf, find_section(&elf, ".strtab")).align, 1);
}

fn void explicit_relocations_and_section_alignment() @test
{
	Object* obj = object::create(mem, elf_target())!!;
	defer obj.deinit();
	List{char}* data = object::get_section(obj, object::SECTION_DATA);
	for (uint i = 0; i < 16; i++) data.push(0);
	String external = object::declare_symbol(obj, object::SECTION_UNDEFINED, "reloc_target", true, object::Linkage.STRONG, object::SymbolType.EXTERNAL, 0, 0);
	object::set_section_align(obj, object::SECTION_DATA, 8);
	object::set_section_align(obj, object::SECTION_DATA, 4);
	object::add_relocation(obj, external, object::SECTION_DATA, 0, 0, object::RelocKind.ABS64);
	object::add_relocation(obj, external, object::SECTION_DATA, 8, 0, object::RelocKind.REX_GOTPCRELX);

	BufferSink out;
	out.init();
	defer out.free();
	object::finish(obj, &out)!!;
	ElfView elf = decode_elf(out.bytes.str_view());
	SectionHeader data_sh = section_header(&elf, find_section(&elf, ".data"));
	check(data_sh.align, 8);
	SectionHeader rela = section_header(&elf, find_section(&elf, ".rela.data"));
	check(rela.size, 48);
	check((uint)read_u64(&elf, rela.offset + 8), 1); // R_X86_64_64
	check((uint)read_u64(&elf, rela.offset + 32), 42); // R_X86_64_REX_GOTPCRELX
}

fn void bss_nobits_and_aligned_payload_offsets() @test
{
	Object* obj = object::create(mem, elf_target())!!;
	defer obj.deinit();
	List{char}* text = object::get_section(obj, object::SECTION_FUNC);
	text.push(0x90); text.push(0x90); text.push(0xC3);
	List{char}* data = object::get_section(obj, object::SECTION_DATA);
	data.push(0x11); data.push(0x22); data.push(0x33);
	List{char}* rodata = object::get_section(obj, object::SECTION_READ_ONLY_DATA);
	rodata.push(0x44); rodata.push(0x55);
	ulong first_offset = object::reserve_zero(obj, object::SECTION_BSS, 3, 1);
	ulong second_offset = object::reserve_zero(obj, object::SECTION_BSS, 10, 16);
	object::set_section_align(obj, object::SECTION_FUNC, 32);
	object::set_section_align(obj, object::SECTION_DATA, 8);
	object::set_section_align(obj, object::SECTION_READ_ONLY_DATA, 8);
	object::declare_symbol(obj, object::SECTION_BSS, "first_zero", true, object::Linkage.STRONG,
		object::SymbolType.VARIABLE, first_offset, 3);
	object::declare_symbol(obj, object::SECTION_BSS, "second_zero", true, object::Linkage.STRONG,
		object::SymbolType.VARIABLE, second_offset, 10);

	BufferSink out;
	out.init();
	defer out.free();
	object::finish(obj, &out)!!;
	ElfView elf = decode_elf(out.bytes.str_view());
	ushort text_index = find_section(&elf, ".text");
	ushort data_index = find_section(&elf, ".data");
	ushort rodata_index = find_section(&elf, ".rodata");
	ushort bss_index = find_section(&elf, ".bss");
	SectionHeader text_sh = section_header(&elf, text_index);
	SectionHeader data_sh = section_header(&elf, data_index);
	SectionHeader rodata_sh = section_header(&elf, rodata_index);
	SectionHeader bss_sh = section_header(&elf, bss_index);
	check(text_sh.offset, 64); check(text_sh.align, 32); check(text_sh.size, 3);
	check(data_sh.offset, 72); check(data_sh.align, 8); check(data_sh.size, 3);
	check(rodata_sh.offset, 80); check(rodata_sh.align, 8); check(rodata_sh.size, 2);
	check(bss_sh.type, 8); // SHT_NOBITS
	check(bss_sh.flags, 3); check(bss_sh.offset, 96); check(bss_sh.size, 26); check(bss_sh.align, 16);
	check(byte_at(&elf, text_sh.offset), 0x90); check(byte_at(&elf, text_sh.offset + 2), 0xC3);
	check(byte_at(&elf, data_sh.offset), 0x11); check(byte_at(&elf, data_sh.offset + 2), 0x33);
	check(byte_at(&elf, rodata_sh.offset), 0x44); check(byte_at(&elf, rodata_sh.offset + 1), 0x55);
	for (ushort i = 2; i < elf.shnum; i++)
	{
		SectionHeader sh = section_header(&elf, i);
		if (sh.type != 8 && sh.size > 0) check(sh.offset % sh.align, 0);
	}
	check(section_header(&elf, find_section(&elf, ".symtab")).offset, bss_sh.offset);
	expect_symbol(&elf, "first_zero", 0x11, bss_index, 0, 3);
	expect_symbol(&elf, "second_zero", 0x11, bss_index, 16, 10);
}

fn void common_symbols_use_shn_common_and_pc32_auto_relocations() @test
{
	Object* obj = object::create(mem, elf_target())!!;
	defer obj.deinit();
	List{char}* text = object::get_section(obj, object::SECTION_FUNC);
	for (uint i = 0; i < 4; i++) text.push(0);
	String common = object::declare_common(obj, "common_value", 24, 8);
	object::add_relocation(obj, common, object::SECTION_FUNC, 0, -4);

	BufferSink out;
	out.init();
	defer out.free();
	object::finish(obj, &out)!!;
	ElfView elf = decode_elf(out.bytes.str_view());
	ushort text_index = find_section(&elf, ".text");
	expect_symbol(&elf, "common_value", 0x11, object::SHN_COMMON, 8, 24);
	SectionHeader rela = section_header(&elf, find_section(&elf, ".rela.text"));
	check(rela.size, 24);
	check((uint)read_u64(&elf, rela.offset + 8), 2); // AUTO treats common as defined: R_X86_64_PC32
	check(read_u64(&elf, rela.offset + 8) >> 32, find_symbol_index(&elf, "common_value"));
	check(read_u64(&elf, rela.offset + 16), (ulong)-4);
	check(rela.info, text_index);
}

fn void gnu_stack_note_is_added_once_across_finish_calls() @test
{
	Object* obj = object::create(mem, elf_target())!!;
	defer obj.deinit();
	BufferSink first;
	first.init();
	defer first.free();
	object::finish(obj, &first)!!;
	BufferSink second;
	second.init();
	defer second.free();
	object::finish(obj, &second)!!;
	test::eq(first.bytes.str_view(), second.bytes.str_view());
	ElfView elf = decode_elf(second.bytes.str_view());
	check(elf.shnum, 4); // null, .strtab, .symtab, and one .note.GNU-stack
	SectionHeader note = section_header(&elf, find_section(&elf, ".note.GNU-stack"));
	check(note.type, 1); check(note.flags, 0); check(note.size, 0); check(note.align, 1);
	Object* populated = object::create(mem, elf_target())!!;
	defer populated.deinit();
	object::get_section(populated, object::SECTION_FUNC).push(0xC3);
	BufferSink with_text;
	with_text.init();
	defer with_text.free();
	object::finish(populated, &with_text)!!;
	ElfView populated_elf = decode_elf(with_text.bytes.str_view());
	SectionHeader populated_note = section_header(&populated_elf, find_section(&populated_elf, ".note.GNU-stack"));
	check(populated_note.type, 1); check(populated_note.flags, 0); check(populated_note.size, 0);
}

fn void short_writes_are_retried() @test
{
	Object* obj = object::create(mem, elf_target())!!;
	defer obj.deinit();
	object::get_section(obj, object::SECTION_FUNC).push(0xC3);
	BufferSink expected;
	expected.init();
	defer expected.free();
	object::finish(obj, &expected)!!;
	ElfView reference = decode_elf(expected.bytes.str_view());

	OneByteSink sink;
	sink.init();
	defer sink.free();
	object::finish(obj, &sink)!!;
	assert(sink.writes > 1, "writer observed multiple short writes");
	test::eq(sink.bytes.str_view(), reference.bytes);
}

fn void big_endian_header_metadata() @test
{
	Object* obj = object::create(mem, big_endian_elf_target())!!;
	defer obj.deinit();
	BufferSink out;
	out.init();
	defer out.free();
	object::finish(obj, &out)!!;
	String bytes = out.bytes.str_view();
	assert(bytes.len >= 64, "big-endian ELF header is complete");
	test::eq(bytes[4], 2); // ELFCLASS64
	test::eq(bytes[5], 2); // ELFDATA2MSB
	test::eq(bytes[18], 0); test::eq(bytes[19], 183); // EM_AARCH64
	test::eq(bytes[58], 0); test::eq(bytes[59], 64); // e_shentsize
}
