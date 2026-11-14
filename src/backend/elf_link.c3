// Small in-process static ELF linker for a single ELF x86-64 relocatable
// object. The input ELF object remains immutable: section contents are copied
// into linker-owned buffers before relocation patches are applied.
module aro::backend::elf_link;
import aro::backend::elf;
import aro::backend::object;
import aro::target;
import std::collections::list;
import std::io;

excuse UNSUPPORTED_TARGET;
excuse MISSING_ENTRY;
excuse UNDEFINED_SYMBOL;
excuse UNSUPPORTED_RELOCATION;
excuse RELOCATION_OVERFLOW;

const ulong DEFAULT_BASE = 0x400000;
const ulong DEFAULT_PAGE = 0x1000;
const ulong ELF_HEADER_SIZE = 64;
const ulong PROGRAM_HEADER_SIZE = 56;
const ulong SECTION_HEADER_SIZE = 64;

const uint PT_LOAD = 1;
const uint PT_GNU_STACK = 0x6474e551;
const uint PF_X = 1;
const uint PF_W = 2;
const uint PF_R = 4;

const uint R_X86_64_PC32 = 2;
const uint R_X86_64_PLT32 = 4;
const uint R_X86_64_64 = 1;
const uint R_X86_64_GOTPCRELX = 41;
const uint R_X86_64_REX_GOTPCRELX = 42;
const uint GROUP_RX = 0;
const uint GROUP_R = 1;
const uint GROUP_RW = 2;
const uint GROUP_COUNT = 3;

struct LinkOptions
{
	String entry;
	ulong base;
	ulong page;
	String* failed_name;
}

const LinkOptions DEFAULT_LINK_OPTIONS = { .entry = "_start", .base = DEFAULT_BASE, .page = DEFAULT_PAGE };

struct SectionLayout
{
	elf::SectionData* source;
	List{char} bytes;
	ulong file_offset;
	ulong address;
	bool placed;
}

struct SegmentLayout
{
	bool present;
	ulong start;
	ulong end;
	ulong file_size;
	ulong memory_size;
}

fn ulong? align_up(ulong value, ulong alignment)
{
	if (!alignment || (alignment & (alignment - 1)) != 0) return UNSUPPORTED_TARGET~;
	if (value > ulong::max - (alignment - 1)) return UNSUPPORTED_TARGET~;
	return (value + alignment - 1) & ~(alignment - 1);
}

fn ulong? add_size(ulong value, ulong size)
{
	if (value > ulong::max - size) return UNSUPPORTED_TARGET~;
	return value + size;
}

fn void free_layouts(List{SectionLayout}* layouts)
{
	for (sz i = 0; i < layouts.len(); i++) layouts.entries[i].bytes.free();
	layouts.free();
}

fn SectionLayout* find_layout(List{SectionLayout}* layouts, elf::SectionData* section)
{
	for (sz i = 0; i < layouts.len(); i++)
	{
		SectionLayout* layout = &layouts.entries[i];
		if (layout.source == section) return layout;
	}
	return null;
}

fn elf::Symbol* find_symbol(elf::Elf* input, String name)
{
	foreach (symbol : input.globals) if (symbol.name == name && symbol.defined) return symbol;
	foreach (symbol : input.locals) if (symbol.name == name && symbol.defined) return symbol;
	return null;
}

fn uint section_group(elf::SectionData* section)
{
	if ((section.flags & 4) != 0) return GROUP_RX;
	if ((section.flags & 1) != 0) return GROUP_RW;
	return GROUP_R;
}

fn ulong? symbol_address(List{SectionLayout}* layouts, elf::Symbol* symbol, String* failed_name)
{
	if (!symbol.defined)
	{
		uint binding = (uint)symbol.info >> 4;
		if (binding == 2) return 0; // An unresolved weak reference resolves to zero.
		if (failed_name) *failed_name = symbol.name;
		return UNDEFINED_SYMBOL~;
	}
	SectionLayout* layout = find_layout(layouts, symbol.section);
	if (!layout || !layout.placed || symbol.offset > (ulong)layout.bytes.len()) return UNSUPPORTED_RELOCATION~;
	return add_size(layout.address, symbol.offset)!;
}

fn void? apply_relocations(elf::Elf* input, List{SectionLayout}* layouts, String* failed_name)
{
	foreach (source : input.sections)
	{
		SectionLayout* layout = find_layout(layouts, source);
		assert(layout, "each input section has a linker layout");
		foreach (relocation : source.relocs)
		{
			uint kind = (uint)relocation.kind;
			bool absolute64 = kind == R_X86_64_64;
			bool gotpcrelx = kind == R_X86_64_GOTPCRELX || kind == R_X86_64_REX_GOTPCRELX;
			if (!absolute64 && !gotpcrelx && kind != R_X86_64_PC32 && kind != R_X86_64_PLT32)
			{
				return UNSUPPORTED_RELOCATION~;
			}
			ulong patch_size = absolute64 ? 8 : 4;
			if (relocation.offset > (ulong)layout.bytes.len() || (ulong)layout.bytes.len() - relocation.offset < patch_size)
			{
				return UNSUPPORTED_RELOCATION~;
			}
			if (gotpcrelx)
			{
				if (!relocation.symbol.defined)
				{
					if (failed_name) *failed_name = relocation.symbol.name;
					return UNDEFINED_SYMBOL~;
				}
				if (relocation.offset < 2 || layout.bytes.entries[(sz)(relocation.offset - 2)] != (char)0x8b)
				{
					return UNSUPPORTED_RELOCATION~;
				}
				layout.bytes.entries[(sz)(relocation.offset - 2)] = (char)0x8d;
			}
			ulong target_address = symbol_address(layouts, relocation.symbol, failed_name)!;
			sz offset = (sz)relocation.offset;
			if (absolute64)
			{
				int128 value = (int128)target_address + (int128)relocation.addend;
				if (value < 0 || value > (int128)ulong::max) return RELOCATION_OVERFLOW~;
				ulong bits = (ulong)value;
				for (uint i = 0; i < 8; i++) layout.bytes.entries[offset + (sz)i] = (char)(bits >> (i * 8));
				continue;
			}
			ulong place = add_size(layout.address, relocation.offset)!;
			int128 value = (int128)target_address + (int128)relocation.addend - (int128)place;
			if (value < (int128)int::min || value > (int128)int::max) return RELOCATION_OVERFLOW~;
			uint bits = (uint)(int)value;
			layout.bytes.entries[offset] = (char)(bits & 0xff);
			layout.bytes.entries[offset + 1] = (char)((bits >> 8) & 0xff);
			layout.bytes.entries[offset + 2] = (char)((bits >> 16) & 0xff);
			layout.bytes.entries[offset + 3] = (char)((bits >> 24) & 0xff);
		}
	}
	return;
}

fn ulong? entry_address(elf::Elf* input, List{SectionLayout}* layouts, String entry, ulong base)
{
	elf::Symbol* symbol = find_symbol(input, entry);
	if (!symbol || !symbol.defined) return MISSING_ENTRY~;
	SectionLayout* layout = find_layout(layouts, symbol.section);
	if (!layout || !layout.placed || section_group(layout.source) != GROUP_RX || symbol.offset >= (ulong)layout.bytes.len()) return MISSING_ENTRY~;
	ulong address = add_size(layout.address, symbol.offset)!;
	if (address < base) return MISSING_ENTRY~;
	return address;
}

fn void? put_u(OutStream writer, ulong value, uint byte_count)
{
	for (uint i = 0; i < byte_count; i++) writer.write_byte((char)(value >> (i * 8)))!;
}

fn void? write_zeros(OutStream writer, ulong count)
{
	for (ulong i = 0; i < count; i++) writer.write_byte(0)!;
}

fn void? write_elf_header(OutStream writer, ulong entry, ushort phnum)
{
	io::write_all(writer, "\x7FELF")!;
	writer.write_byte(2)!; // ELFCLASS64
	writer.write_byte(1)!; // ELFDATA2LSB
	writer.write_byte(1)!; // EV_CURRENT
	writer.write_byte(0)!; // ELFOSABI_NONE
	writer.write_byte(0)!; // ABI version
	write_zeros(writer, 7)!;
	put_u(writer, 2, 2)!; // ET_EXEC
	put_u(writer, 62, 2)!; // EM_X86_64
	put_u(writer, 1, 4)!; // EV_CURRENT
	put_u(writer, entry, 8)!;
	put_u(writer, ELF_HEADER_SIZE, 8)!;
	put_u(writer, 0, 8)!; // No section header table.
	put_u(writer, 0, 4)!; // e_flags
	put_u(writer, ELF_HEADER_SIZE, 2)!;
	put_u(writer, PROGRAM_HEADER_SIZE, 2)!;
	put_u(writer, phnum, 2)!;
	put_u(writer, SECTION_HEADER_SIZE, 2)!; // e_shentsize
	put_u(writer, 0, 2)!; // e_shnum
	put_u(writer, 0, 2)!; // e_shstrndx
}

fn void? write_program_header(OutStream writer, uint kind, uint flags, ulong offset, ulong address, ulong file_size, ulong memory_size, ulong alignment)
{
	put_u(writer, kind, 4)!;
	put_u(writer, flags, 4)!;
	put_u(writer, offset, 8)!;
	put_u(writer, address, 8)!;
	put_u(writer, address, 8)!;
	put_u(writer, file_size, 8)!;
	put_u(writer, memory_size, 8)!;
	put_u(writer, alignment, 8)!;
}

fn void? write_group(OutStream writer, List{SectionLayout}* layouts, uint group, ulong* cursor)
{
	for (sz i = 0; i < layouts.len(); i++)
	{
		SectionLayout* layout = &layouts.entries[i];
		if (!layout.placed || section_group(layout.source) != group || !layout.bytes.len()) continue;
		if (layout.file_offset > *cursor) write_zeros(writer, layout.file_offset - *cursor)!;
		foreach (byte : layout.bytes) writer.write_byte(byte)!;
		*cursor = layout.file_offset + (ulong)layout.bytes.len();
	}
	return;
}

<*
 Link one in-memory ELF object into a static ELF64 x86-64 executable.
 The output is written after layout, entry validation, and relocations succeed.
 @return? UNSUPPORTED_TARGET, MISSING_ENTRY, UNDEFINED_SYMBOL, UNSUPPORTED_RELOCATION, RELOCATION_OVERFLOW
*>
fn void? write_executable(object::Object* obj, OutStream w, LinkOptions opts = DEFAULT_LINK_OPTIONS)
{
	// C3 aggregate literals zero omitted fields, so recover LinkOptions defaults
	// for calls that specify only an override such as `.failed_name`.
	if (!opts.entry.len) opts.entry = DEFAULT_LINK_OPTIONS.entry;
	if (!opts.base) opts.base = DEFAULT_LINK_OPTIONS.base;
	if (!opts.page) opts.page = DEFAULT_LINK_OPTIONS.page;
	if (opts.failed_name) *opts.failed_name = "";
	if (obj.format != target::ObjectFormat.ELF || obj.target.cpu.arch != target::Arch.X86_64 || obj.target.cpu.arch.endian() != target::Endian.LITTLE)
	{
		return UNSUPPORTED_TARGET~;
	}
	if (!obj.implementation) return UNSUPPORTED_TARGET~;
	if (!opts.page || (opts.page & (opts.page - 1)) != 0 || opts.base % opts.page != 0)
	{
		return UNSUPPORTED_TARGET~;
	}
	elf::Elf* input = (elf::Elf*)obj.implementation;
	List{SectionLayout} layouts;
	layouts.init(obj.allocator, input.sections.len());
	defer free_layouts(&layouts);

	bool[GROUP_COUNT] has_group = { false, false, false };
	foreach (source : input.sections)
	{
		SectionLayout layout;
		layout.source = source;
		layout.file_offset = 0;
		layout.address = 0;
		layout.placed = false;
		layout.bytes.init(obj.allocator, source.bytes.len());
		layout.bytes.push_all(source.bytes.array_view());
		layouts.push(layout);
		if (source.bytes.len()) has_group[section_group(source)] = true;
	}

	ushort phnum = 1; // PT_GNU_STACK is always emitted.
	for (uint group = 0; group < GROUP_COUNT; group++) if (has_group[group]) phnum++;
	ulong phdr_bytes = PROGRAM_HEADER_SIZE * (ulong)phnum;
	ulong header_end = add_size(ELF_HEADER_SIZE, phdr_bytes)!;

	SegmentLayout[GROUP_COUNT] segments = {};
	ulong cursor = header_end;
	for (uint group = 0; group < GROUP_COUNT; group++)
	{
		if (!has_group[group]) continue;
		SegmentLayout* segment = &segments[group];
		segment.present = true;
		if (group == GROUP_RX)
		{
			segment.start = 0;
			cursor = align_up(cursor, 16)!;
		}
		else
		{
			cursor = align_up(cursor, opts.page)!;
			segment.start = cursor;
		}
		for (sz i = 0; i < layouts.len(); i++)
		{
			SectionLayout* layout = &layouts.entries[i];
			if (section_group(layout.source) != group) continue;
			cursor = align_up(cursor, 16)!;
			layout.file_offset = cursor;
			layout.address = add_size(opts.base, cursor)!;
			layout.placed = true;
			cursor = add_size(cursor, (ulong)layout.bytes.len())!;
		}
		segment.end = cursor;
		segment.file_size = segment.end - segment.start;
		segment.memory_size = segment.end - segment.start;
	}
	if (!segments[GROUP_RX].present) return MISSING_ENTRY~;

	ulong entry_value = entry_address(input, &layouts, opts.entry, opts.base)!;
	apply_relocations(input, &layouts, opts.failed_name)!;

	write_elf_header(w, entry_value, phnum)!;
	for (uint group = 0; group < GROUP_COUNT; group++)
	{
		SegmentLayout* segment = &segments[group];
		if (!segment.present) continue;
		uint flags = group == GROUP_RX ? PF_R | PF_X : (group == GROUP_R ? PF_R : PF_R | PF_W);
		ulong offset = group == GROUP_RX ? 0 : segment.start;
		ulong address = add_size(opts.base, offset)!;
		write_program_header(w, PT_LOAD, flags, offset, address,
			segment.file_size, segment.memory_size, opts.page)!;
	}
	write_program_header(w, PT_GNU_STACK, PF_R | PF_W, 0, 0, 0, 0, 0)!;

	ulong output_cursor = header_end;
	for (uint group = 0; group < GROUP_COUNT; group++)
	{
		SegmentLayout* segment = &segments[group];
		if (!segment.present) continue;
		write_group(w, &layouts, group, &output_cursor)!;
		if (output_cursor < segment.end)
		{
			write_zeros(w, segment.end - output_cursor)!;
			output_cursor = segment.end;
		}
	}
	if (&w.flush) w.flush()!;
	return;
}

struct LinkBuffer (OutStream)
{
	ByteWriter bytes;
}

fn void LinkBuffer.init(&self, Allocator a) { self.bytes.init(a); }
fn sz? LinkBuffer.write(&self, char[] data) @dynamic => self.bytes.write(data);
fn void? LinkBuffer.write_byte(&self, char byte) @dynamic => self.bytes.write_byte(byte);
fn void? LinkBuffer.flush(&self) @dynamic {}
fn void LinkBuffer.free(&self) { (void)self.bytes.destroy(); }

<*
 Link an object and return an owned byte buffer allocated with `a`.
 @return? UNSUPPORTED_TARGET, MISSING_ENTRY, UNDEFINED_SYMBOL, UNSUPPORTED_RELOCATION, RELOCATION_OVERFLOW
*>
fn char[]? link_executable(Allocator a, object::Object* obj, LinkOptions opts = DEFAULT_LINK_OPTIONS)
{
	LinkBuffer output;
	output.init(a);
	defer output.free();
	write_executable(obj, &output, opts)!;
	String bytes = output.bytes.str_view();
	char* owned = alloc::malloc(a, (usz)bytes.len);
	for (sz i = 0; i < bytes.len; i++) owned[i] = bytes[i];
	return owned[:bytes.len];
}
