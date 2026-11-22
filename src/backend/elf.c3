// ELF64 relocatable object writer. Fixed-size records (ELF header, section
// headers, symbols, relocations) are packed structs of fixed-endian bitstruct
// fields; section payloads, strings and padding are written raw.
module aro::backend::elf;
import aro::target;
import aro::backend::object;
import std::collections::list;
import std::io;

struct Relocation
{
	Symbol* symbol; ulong offset; long addend; char kind;
}

struct SectionData
{
	String name; List{char} bytes; List{Relocation} relocs; ulong flags; ulong alignment; ulong nobits_size; ulong file_offset; uint sh_type; ushort index;
}

struct Symbol
{
	SectionData* section; bool defined; bool common; ulong offset; ulong size; char info; ushort index; String name;
}

struct Elf
{
	Allocator allocator;
	target::Target target;
	List{SectionData*} sections;
	List{Symbol*} locals;
	List{Symbol*} globals;
	List{String} owned_names;
	uint unnamed;
	ulong strtab_len;
}

const String DEFAULT_STRTAB = "\0.strtab\0.symtab\0";
const uint SHT_PROGBITS = 1;
const uint SHT_NOBITS = 8;
const uint SHT_INIT_ARRAY = 14;
const uint SHT_FINI_ARRAY = 15;

fn Elf* create(Allocator a, target::Target t)
{
	Elf e_value; Elf* e = alloc::malloc(a, @sizeof(e_value));
	*e = { .allocator = a, .target = t, .strtab_len = DEFAULT_STRTAB.len };
	e.sections.init(a); e.locals.init(a); e.globals.init(a); e.owned_names.init(a);
	return e;
}

fn void destroy(Elf* e)
{
	foreach (s : e.sections)
	{
		s.bytes.free(); s.relocs.free(); alloc::free(e.allocator, s);
	}
	foreach (s : e.locals) alloc::free(e.allocator, s);
	foreach (s : e.globals) alloc::free(e.allocator, s);
	foreach (name : e.owned_names) alloc::free(e.allocator, name.ptr);
	e.sections.free(); e.locals.free(); e.globals.free(); e.owned_names.free();
	Allocator a = e.allocator; alloc::free(a, e);
}

fn String section_name(object::Section s)
{
	switch (s.kind)
	{
		case object::SectionKind.DATA: return "data";
		case object::SectionKind.BSS: return "bss";
		case object::SectionKind.READ_ONLY_DATA: return "rodata";
		case object::SectionKind.FUNC: return "text";
		case object::SectionKind.STRINGS: return "rodata.str";
		case object::SectionKind.CUSTOM: return s.custom_name;
		case object::SectionKind.UNDEFINED: unreachable("undefined section has no name");
	}
}

fn SectionData* find_section(Elf* e, String name)
{
	foreach (s : e.sections) if (s.name == name) return s;
	return null;
}

fn List{char} * get_section(Elf* e, object::Section section)
{
	String name = section_name(section);
	SectionData* s = find_section(e, name);
	if (s) return &s.bytes;
	SectionData section_value; s = alloc::malloc(e.allocator, @sizeof(section_value));
	*s = { .name = name, .sh_type = SHT_PROGBITS };
	s.bytes.init(e.allocator); s.relocs.init(e.allocator);
	switch (section.kind)
	{
		case object::SectionKind.FUNC: s.flags = 6;
		case object::SectionKind.CUSTOM: s.flags = 6;
		case object::SectionKind.STRINGS: s.flags = 0x32;
		case object::SectionKind.READ_ONLY_DATA: s.flags = 2;
		case object::SectionKind.DATA: s.flags = 3;
		case object::SectionKind.BSS: s.flags = 3; s.sh_type = SHT_NOBITS;
		case object::SectionKind.UNDEFINED: unreachable("undefined section");
	}
	if (section.kind == object::SectionKind.CUSTOM)
	{
		// Pointer arrays the C runtime walks before main and at exit.
		if (name.starts_with("init_array")) { s.sh_type = SHT_INIT_ARRAY; s.flags = 3; }
		if (name.starts_with("fini_array")) { s.sh_type = SHT_FINI_ARRAY; s.flags = 3; }
	}
	e.sections.push(s);
	e.strtab_len += name.len + 2;
	return &s.bytes;
}

fn void set_section_align(Elf* e, object::Section section, ulong alignment)
{
	SectionData* s = find_section(e, section_name(section));
	if (!s)
	{
		(void)get_section(e, section);
		s = find_section(e, section_name(section));
	}
	if (alignment > s.alignment) s.alignment = alignment;
}

fn ulong reserve_zero(Elf* e, object::Section section, ulong size, ulong alignment)
{
	assert(section.kind == object::SectionKind.BSS, "zero reservations belong to BSS");
	assert(alignment > 0 && (alignment & (alignment - 1)) == 0, "zero reservation alignment must be a power of two");
	(void)get_section(e, section);
	set_section_align(e, section, alignment);
	SectionData* s = find_section(e, section_name(section));
	ulong offset = align_forward(s.nobits_size, alignment);
	s.nobits_size = offset + size;
	return offset;
}

fn String copy_name(Elf* e, String name)
{
	String copy = name.copy(e.allocator);
	e.owned_names.push(copy);
	return copy;
}

fn String declare_symbol(Elf* e, object::Section section, String name, bool has_name, object::Linkage linkage, object::SymbolType sym_type, ulong offset, ulong size)
{
	return declare_symbol_impl(e, section, name, has_name, linkage, sym_type, offset, size, false);
}

fn String declare_common_symbol(Elf* e, String name, ulong size, ulong alignment)
{
	assert(alignment > 0 && (alignment & (alignment - 1)) == 0, "common symbol alignment must be a power of two");
	return declare_symbol_impl(e, object::SECTION_UNDEFINED, name, true, object::Linkage.STRONG,
		object::SymbolType.VARIABLE, alignment, size, true);
}

fn String declare_symbol_impl(Elf* e, object::Section section, String name, bool has_name, object::Linkage linkage,
	object::SymbolType sym_type, ulong offset, ulong size, bool common)
{
	SectionData* sec = null;
	if (section.kind != object::SectionKind.UNDEFINED) sec = find_section(e, section_name(section));
	// Zig stores this lookup as an optional pointer. A declaration for a
	// section that has not been created yet therefore remains SHN_UNDEF.
	bool defined = sec != null || common;
	if (!has_name)
	{
		DString d; d.init(e.allocator); d.appendf(".L.%d", e.unnamed++); name = d.copy_str(e.allocator); d.free(); e.owned_names.push(name);
	}
	if (linkage == object::Linkage.LINK_ONCE) unreachable("LinkOnce symbols are unsupported by the Zig ELF writer");
	char bind = linkage == object::Linkage.INTERNAL ? 0 : (linkage == object::Linkage.WEAK ? 2 : 1);
	char ty = sym_type == object::SymbolType.FUNC ? 2 : (sym_type == object::SymbolType.VARIABLE ? 1 : 0);
	List{Symbol*} * dest = linkage == object::Linkage.INTERNAL ? &e.locals : &e.globals;
	for (sz i = 0; i < dest.len(); i++)
	{
		Symbol* old = dest.get(i);
		if (old.name == name)
		{
			old.section = sec; old.defined = defined; old.common = common; old.offset = offset; old.size = size; old.info = (bind << 4) | ty; return name;
		}
	}
	Symbol symbol_value; Symbol* sym = alloc::malloc(e.allocator, @sizeof(symbol_value));
	*sym = { .section = sec, .defined = defined, .common = common, .offset = offset, .size = size, .info = (bind << 4) | ty, .name = name };
	dest.push(sym); e.strtab_len += name.len + 1;
	return name;
}

fn Symbol* find_symbol(Elf* e, String name)
{
	foreach (s : e.locals) if (s.name == name) return s;
	foreach (s : e.globals) if (s.name == name) return s;
	return null;
}

fn void add_relocation(Elf* e, String name, object::Section section, ulong address, long addend, object::RelocKind kind = object::RelocKind.AUTO)
{
	SectionData* s = find_section(e, section_name(section));
	Symbol* sym = find_symbol(e, name);
	assert(s && sym, "relocation requires a declared symbol and section");
	// The reference stores relocation offsets in u48; checked narrowing traps
	// above this bound.
	assert(address <= 0x0000_FFFF_FFFF_FFFF, "ELF relocation offset exceeds the reference 48-bit limit");
	if (!s.relocs.len()) e.strtab_len += 5;
	if (kind == object::RelocKind.AUTO) kind = sym.defined ? object::RelocKind.PC32 : object::RelocKind.PLT32;
	s.relocs.push(
		{
			.symbol = sym, .offset = address, .addend = addend, .kind = kind.value
		}
	);
}

// Elf64_Ehdr in both byte orders; the field types fix the on-disk encoding.
struct ElfHeaderLE @packed @private
{
	char[16] ident;
	UShortLE type;
	UShortLE machine;
	UIntLE version;
	ULongLE entry;
	ULongLE phoff;
	ULongLE shoff;
	UIntLE flags;
	UShortLE ehsize;
	UShortLE phentsize;
	UShortLE phnum;
	UShortLE shentsize;
	UShortLE shnum;
	UShortLE shstrndx;
}

struct ElfHeaderBE @packed @private
{
	char[16] ident;
	UShortBE type;
	UShortBE machine;
	UIntBE version;
	ULongBE entry;
	ULongBE phoff;
	ULongBE shoff;
	UIntBE flags;
	UShortBE ehsize;
	UShortBE phentsize;
	UShortBE phnum;
	UShortBE shentsize;
	UShortBE shnum;
	UShortBE shstrndx;
}

$assert ElfHeaderLE::size == 64 && ElfHeaderBE::size == 64;

// Elf64_Shdr in both byte orders.
struct ElfSectionHeaderLE @packed @private
{
	UIntLE name;
	UIntLE type;
	ULongLE flags;
	ULongLE addr;
	ULongLE offset;
	ULongLE size;
	UIntLE link;
	UIntLE info;
	ULongLE addralign;
	ULongLE entsize;
}

struct ElfSectionHeaderBE @packed @private
{
	UIntBE name;
	UIntBE type;
	ULongBE flags;
	ULongBE addr;
	ULongBE offset;
	ULongBE size;
	UIntBE link;
	UIntBE info;
	ULongBE addralign;
	ULongBE entsize;
}

$assert ElfSectionHeaderLE::size == 64 && ElfSectionHeaderBE::size == 64;

// Elf64_Sym in both byte orders.
struct ElfSymbolLE @packed @private
{
	UIntLE name;
	char info;
	char other;
	UShortLE shndx;
	ULongLE value;
	ULongLE size;
}

struct ElfSymbolBE @packed @private
{
	UIntBE name;
	char info;
	char other;
	UShortBE shndx;
	ULongBE value;
	ULongBE size;
}

$assert ElfSymbolLE::size == 24 && ElfSymbolBE::size == 24;

// Elf64_Rela in both byte orders.
struct ElfRelaLE @packed @private
{
	ULongLE offset;
	ULongLE info;
	LongLE addend;
}

struct ElfRelaBE @packed @private
{
	ULongBE offset;
	ULongBE info;
	LongBE addend;
}

$assert ElfRelaLE::size == 24 && ElfRelaBE::size == 24;

fn void? pad(OutStream w, ulong n)
{
	for (ulong i = 0; i < n; i++) w.write_byte(0)!;
}

fn ulong align_forward(ulong value, ulong alignment)
{
	if (alignment <= 1) return value;
	ulong remainder = value % alignment;
	return remainder == 0 ? value : value + alignment - remainder;
}

fn ulong effective_alignment(SectionData* section)
{
	ulong default_alignment = (section.flags & 4) ? 16 : 1;
	return section.alignment > default_alignment ? section.alignment : default_alignment;
}

fn ulong section_size(SectionData* section)
{
	return section.sh_type == SHT_NOBITS ? section.nobits_size : (ulong)section.bytes.len();
}

fn void ensure_gnu_stack(Elf* e)
{
	SectionData* section = find_section(e, "note.GNU-stack");
	if (!section)
	{
		(void)get_section(e, { .kind = object::SectionKind.CUSTOM, .custom_name = "note.GNU-stack" });
		section = find_section(e, "note.GNU-stack");
	}
	section.flags = 0;
	section.sh_type = SHT_PROGBITS;
	section.alignment = 1;
}

// Explicit subset of std.Target.toElfMachine used by the reference writer;
// unmapped architectures retain the reference's unsupported-target trap.
fn uint machine(target::Arch a)
{
	switch (a)
	{
		case X86: return 3;
		case X86_64: return 62;
		case ARM:
		case ARMEB:
		case THUMB:
		case THUMBEB: return 40;
		case AARCH64:
		case AARCH64_BE: return 183;
		case MIPS:
		case MIPSEL:
		case MIPS64:
		case MIPS64EL: return 8;
		case POWERPC:
		case POWERPCLE: return 20;
		case POWERPC64:
		case POWERPC64LE: return 21;
		case RISCV32:
		case RISCV32BE:
		case RISCV64:
		case RISCV64BE: return 243;
		case S390X: return 22;
		case SPARC: return 2;
		case SPARC64: return 43;
		case BPFEL:
		case BPFEB: return 247;
		case LOONGARCH32:
		case LOONGARCH64: return 258;
		case AVR: return 83;
		case MSP430: return 105;
		case HEXAGON: return 164;
		case ALPHA: return 0x9026;
		case M68K: return 4;
		case SH:
		case SHEB: return 42;
		case OR1K: return 92;
		case VE: return 251;
		case CSKY: return 252;
		case ARC:
		case ARCEB: return 45;
		case XTENSA:
		case XTENSAEB: return 94;
		case M88K: return 5;
		case HPPA:
		case HPPA64: return 15;
		case AMDGCN: return 224;
		case MICROBLAZE:
		case MICROBLAZEEL: return 189;
		case LANAI: return 244;
		case KVX: return 256;
		case XCORE: return 203;
		default: unreachable("target architecture has no ELF machine mapping");
	}
}

// Emits the pinned Zig writer's ELF64 header, section payloads, symbol table,
// RELA entries, string table, and section headers in their prescribed order.
fn void? finish(Elf* e, OutStream w)
{
	ensure_gnu_stack(e);
	bool big = e.target.cpu.arch.endian() == target::Endian.BIG;
	ushort count = 3; ulong payload_end = 64; ulong rela_len = 0;
	foreach (s : e.sections)
	{
		payload_end = align_forward(payload_end, effective_alignment(s));
		s.file_offset = payload_end;
		if (s.sh_type != SHT_NOBITS) payload_end += section_size(s);
		rela_len += (ulong)s.relocs.len() * 24;
		s.index = count; count++;
		if (s.relocs.len()) count++;
	}
	ulong symcount = 1 + (ulong)e.locals.len() + (ulong)e.globals.len();
	ulong sym_len = symcount * 24;
	ulong sym_off = payload_end; ulong sym_aligned = align_forward(sym_off, 8);
	ulong rela_off = sym_aligned + sym_len; ulong str_off = rela_off + rela_len;
	ulong sh_off = align_forward(str_off + e.strtab_len, 16);
	// ELF header (64 bytes)
	ushort arch = (ushort)machine(e.target.cpu.arch);
	if (big)
	{
		ElfHeaderBE h = {
			.ident = { 0x7F, 'E', 'L', 'F', 2, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
			.type.val = 1, .machine.val = arch, .version.val = 1, .shoff.val = sh_off,
			.ehsize.val = 64, .shentsize.val = 64, .shnum.val = count, .shstrndx.val = 1,
		};
		io::write_any(w, &h)!;
	}
	else
	{
		ElfHeaderLE h = {
			.ident = { 0x7F, 'E', 'L', 'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
			.type.val = 1, .machine.val = arch, .version.val = 1, .shoff.val = sh_off,
			.ehsize.val = 64, .shentsize.val = 64, .shnum.val = count, .shstrndx.val = 1,
		};
		io::write_any(w, &h)!;
	}
	ulong payload_cursor = 64;
	foreach (s : e.sections)
	{
		pad(w, s.file_offset - payload_cursor)!;
		if (s.sh_type != SHT_NOBITS)
		{
			foreach (b : s.bytes) w.write_byte(b)!;
			payload_cursor = s.file_offset + section_size(s);
		}
		else
		{
			payload_cursor = s.file_offset;
		}
	}
	pad(w, sym_aligned - sym_off)!;
	// Null symbol.
	pad(w, 24)!;
	uint noff = (uint)DEFAULT_STRTAB.len; ushort si = 1;
	foreach (s : e.locals)
	{
		write_symbol(w, s, noff, big)!; s.index = si++; noff += (uint)s.name.len + 1;
	}
	foreach (s : e.globals)
	{
		write_symbol(w, s, noff, big)!; s.index = si++; noff += (uint)s.name.len + 1;
	}
	foreach (s : e.sections) foreach (r : s.relocs)
	{
		write_rela(w, &r, big)!;
	}
	io::write_all(w, DEFAULT_STRTAB)!;
	foreach (s : e.locals)
	{
		io::write_all(w, s.name)!; w.write_byte(0)!;
	}
	foreach (s : e.globals)
	{
		io::write_all(w, s.name)!; w.write_byte(0)!;
	}
	uint section_name_off = noff;
	foreach (s : e.sections)
	{
		if (s.relocs.len()) io::write_all(w, ".rela")!; io::write_all(w, ".")!; io::write_all(w, s.name)!; w.write_byte(0)!;
	}
	pad(w, sh_off - (str_off + e.strtab_len))!; pad(w, 64)!;
	write_shdr(w, 1, 3, 0, str_off, e.strtab_len, 0, 0, 1, 0, big)!;
	write_shdr(w, 9, 2, 0, sym_aligned, sym_len, 1, (uint)e.locals.len() + 1, 8, 24, big)!;
	ulong roff = rela_off; noff = section_name_off;
	foreach (s : e.sections)
	{
		uint rela_prefix = s.relocs.len() ? 5 : 0;
		ulong alignment = effective_alignment(s);
		write_shdr(w, noff + rela_prefix, s.sh_type, s.flags, s.file_offset, section_size(s), 0, 0, alignment, 0, big)!;
		if (s.relocs.len())
		{
			write_shdr(w, noff, 4, 0, roff, (ulong)s.relocs.len() * 24, 2, s.index, 8, 24, big)!; roff += (ulong)s.relocs.len() * 24;
		}
		noff += (uint)s.name.len + 2 + rela_prefix;
	}
	if (&w.flush) w.flush()!;
}

fn void? write_symbol(OutStream w, Symbol* s, uint name, bool big)
{
	ushort section_index = 0;
	if (s.common)
	{
		section_index = object::SHN_COMMON;
	}
	else if (s.section)
	{
		section_index = s.section.index;
	}
	if (big)
	{
		ElfSymbolBE h = {
			.name.val = name, .info = s.info, .shndx.val = section_index, .value.val = s.offset, .size.val = s.size,
		};
		io::write_any(w, &h)!;
	}
	else
	{
		ElfSymbolLE h = {
			.name.val = name, .info = s.info, .shndx.val = section_index, .value.val = s.offset, .size.val = s.size,
		};
		io::write_any(w, &h)!;
	}
}

fn void? write_rela(OutStream w, Relocation* r, bool big)
{
	ulong info = ((ulong)r.symbol.index << 32) | r.kind;
	if (big)
	{
		ElfRelaBE h = { .offset.val = r.offset, .info.val = info, .addend.val = r.addend };
		io::write_any(w, &h)!;
	}
	else
	{
		ElfRelaLE h = { .offset.val = r.offset, .info.val = info, .addend.val = r.addend };
		io::write_any(w, &h)!;
	}
}

fn void? write_shdr(OutStream w, uint name, uint ty, ulong flags, ulong offset, ulong size, uint link, uint info, ulong align, ulong entsize, bool big)
{
	if (big)
	{
		ElfSectionHeaderBE h = {
			.name.val = name, .type.val = ty, .flags.val = flags, .offset.val = offset, .size.val = size,
			.link.val = link, .info.val = info, .addralign.val = align, .entsize.val = entsize,
		};
		io::write_any(w, &h)!;
	}
	else
	{
		ElfSectionHeaderLE h = {
			.name.val = name, .type.val = ty, .flags.val = flags, .offset.val = offset, .size.val = size,
			.link.val = link, .info.val = info, .addralign.val = align, .entsize.val = entsize,
		};
		io::write_any(w, &h)!;
	}
}
