// ELF64 relocatable object writer. All on-disk integers are emitted field by
// field; no C3 or host structure layout is part of the file format.
module aro::backend::elf;
import aro::target;
import aro::backend::object;
import std::collections::list;
import std::io;

struct Relocation { Symbol* symbol; ulong offset; long addend; char kind; }
struct SectionData { String name; List{char} bytes; List{Relocation} relocs; ulong flags; ushort index; }
struct Symbol { SectionData* section; bool defined; ulong offset; ulong size; char info; ushort index; String name; }
struct Elf
{
	Allocator allocator;
	target::Target target;
	List{SectionData*} sections;
	List{Symbol*} locals;
	List{Symbol*} globals;
	List{String} generated_names;
	uint unnamed;
	ulong strtab_len;
}

const String DEFAULT_STRTAB = "\0.strtab\0.symtab\0";

fn Elf* create(Allocator a, target::Target t)
{
	Elf e_value; Elf* e = alloc::malloc(a, @sizeof(e_value));
	*e = { .allocator = a, .target = t, .strtab_len = DEFAULT_STRTAB.len };
	e.sections.init(a); e.locals.init(a); e.globals.init(a); e.generated_names.init(a);
	return e;
}

fn void destroy(Elf* e)
{
	foreach (s : e.sections) { s.bytes.free(); s.relocs.free(); alloc::free(e.allocator, s); }
	foreach (s : e.locals) alloc::free(e.allocator, s);
	foreach (s : e.globals) alloc::free(e.allocator, s);
	foreach (name : e.generated_names) alloc::free(e.allocator, name.ptr);
	e.sections.free(); e.locals.free(); e.globals.free(); e.generated_names.free();
	Allocator a = e.allocator; alloc::free(a, e);
}

fn String section_name(object::Section s)
{
	switch (s.kind)
	{
		case object::SectionKind.DATA: return "data";
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

fn List{char}* get_section(Elf* e, object::Section section)
{
	String name = section_name(section);
	SectionData* s = find_section(e, name);
	if (s) return &s.bytes;
	SectionData section_value; s = alloc::malloc(e.allocator, @sizeof(section_value));
	*s = { .name = name };
	s.bytes.init(e.allocator); s.relocs.init(e.allocator);
	switch (section.kind)
	{
		case object::SectionKind.FUNC: s.flags = 6;
		case object::SectionKind.CUSTOM: s.flags = 6;
		case object::SectionKind.STRINGS: s.flags = 0x32;
		case object::SectionKind.READ_ONLY_DATA: s.flags = 2;
		case object::SectionKind.DATA: s.flags = 3;
		case object::SectionKind.UNDEFINED: unreachable("undefined section");
	}
	e.sections.push(s);
	e.strtab_len += name.len + 2;
	return &s.bytes;
}

fn String declare_symbol(Elf* e, object::Section section, String name, bool has_name, object::Linkage linkage, object::SymbolType sym_type, ulong offset, ulong size)
{
	SectionData* sec = null;
	if (section.kind != object::SectionKind.UNDEFINED) sec = find_section(e, section_name(section));
	// Zig stores this lookup as an optional pointer. A declaration for a
	// section that has not been created yet therefore remains SHN_UNDEF.
	bool defined = sec != null;
	if (!has_name) { DString d; d.init(e.allocator); d.appendf(".L.%d", e.unnamed++); name = d.copy_str(e.allocator); d.free(); e.generated_names.push(name); }
	if (linkage == object::Linkage.LINK_ONCE) unreachable("LinkOnce symbols are unsupported by the Zig ELF writer");
	char bind = linkage == object::Linkage.INTERNAL ? 0 : (linkage == object::Linkage.WEAK ? 2 : 1);
	char ty = sym_type == object::SymbolType.FUNC ? 2 : (sym_type == object::SymbolType.VARIABLE ? 1 : 0);
	List{Symbol*}* dest = linkage == object::Linkage.INTERNAL ? &e.locals : &e.globals;
	for (sz i = 0; i < dest.len(); i++)
	{
		Symbol* old = dest.get(i);
		if (old.name == name) { old.section = sec; old.defined = defined; old.offset = offset; old.size = size; old.info = (bind << 4) | ty; return name; }
	}
	Symbol symbol_value; Symbol* sym = alloc::malloc(e.allocator, @sizeof(symbol_value));
	*sym = { .section = sec, .defined = defined, .offset = offset, .size = size, .info = (bind << 4) | ty, .name = name };
	dest.push(sym); e.strtab_len += name.len + 1;
	return name;
}

fn Symbol* find_symbol(Elf* e, String name)
{
	foreach (s : e.locals) if (s.name == name) return s;
	foreach (s : e.globals) if (s.name == name) return s;
	return null;
}

fn void add_relocation(Elf* e, String name, object::Section section, ulong address, long addend)
{
	SectionData* s = find_section(e, section_name(section));
	Symbol* sym = find_symbol(e, name);
	assert(s && sym, "relocation requires a declared symbol and section");
	// The reference stores relocation offsets in u48; checked narrowing traps
	// above this bound.
	assert(address <= 0x0000_FFFF_FFFF_FFFF, "ELF relocation offset exceeds the reference 48-bit limit");
	if (!s.relocs.len()) e.strtab_len += 5;
	s.relocs.push({ .symbol = sym, .offset = address, .addend = addend, .kind = sym.defined ? 2 : 4 });
}

fn void? put(OutStream w, ulong v, uint n, bool big)
{
	for (uint i = 0; i < n; i++)
	{
		uint shift = big ? (n - i - 1) * 8 : i * 8;
		w.write_byte((char)(v >> shift))!;
	}
}
fn void? pad(OutStream w, ulong n) { for (ulong i = 0; i < n; i++) w.write_byte(0)!; }
// Explicit subset of std.Target.toElfMachine used by the reference writer;
// unmapped architectures retain the reference's unsupported-target trap.
fn uint machine(target::Arch a)
{
	switch (a)
	{
		case X86: return 3; case X86_64: return 62;
		case ARM: case ARMEB: case THUMB: case THUMBEB: return 40;
		case AARCH64: case AARCH64_BE: return 183;
		case MIPS: case MIPSEL: case MIPS64: case MIPS64EL: return 8;
		case POWERPC: case POWERPCLE: return 20; case POWERPC64: case POWERPC64LE: return 21;
		case RISCV32: case RISCV32BE: case RISCV64: case RISCV64BE: return 243;
		case S390X: return 22; case SPARC: return 2; case SPARC64: return 43;
		case BPFEL: case BPFEB: return 247; case LOONGARCH32: case LOONGARCH64: return 258;
		case AVR: return 83; case MSP430: return 105; case HEXAGON: return 164;
		case ALPHA: return 0x9026; case M68K: return 4; case SH: case SHEB: return 42;
		case OR1K: return 92; case VE: return 251; case CSKY: return 252;
		case ARC: case ARCEB: return 45; case XTENSA: case XTENSAEB: return 94;
		case M88K: return 5; case HPPA: case HPPA64: return 15;
		case AMDGCN: return 224; case MICROBLAZE: case MICROBLAZEEL: return 189;
		case LANAI: return 244; case KVX: return 256; case XCORE: return 203;
		default: unreachable("target architecture has no ELF machine mapping");
	}
}

// Emits the pinned Zig writer's ELF64 header, section payloads, symbol table,
// RELA entries, string table, and section headers in their prescribed order.
fn void? finish(Elf* e, OutStream w)
{
	bool big = e.target.cpu.arch.endian() == target::Endian.BIG;
	ushort count = 3; ulong payload = 0; ulong rela_len = 0;
	foreach (s : e.sections)
	{
		payload += (ulong)s.bytes.len(); rela_len += (ulong)s.relocs.len() * 24;
		s.index = count; count++;
		if (s.relocs.len()) count++;
	}
	ulong symcount = 1 + (ulong)e.locals.len() + (ulong)e.globals.len();
	ulong sym_len = symcount * 24;
	ulong sym_off = 64 + payload; ulong sym_aligned = (sym_off + 7) & ~(ulong)7;
	ulong rela_off = sym_aligned + sym_len; ulong str_off = rela_off + rela_len;
	ulong sh_off = (str_off + e.strtab_len + 15) & ~(ulong)15;
	// ELF header (64 bytes)
	io::write_all(w, "\x7FELF")!; w.write_byte(2)!; w.write_byte(big ? 2 : 1)!; w.write_byte(1)!; w.write_byte(0)!; w.write_byte(0)!; pad(w, 7)!;
	put(w, 1, 2, big)!; put(w, machine(e.target.cpu.arch), 2, big)!; put(w, 1, 4, big)!;
	put(w, 0, 8, big)!; put(w, 0, 8, big)!; put(w, sh_off, 8, big)!; put(w, 0, 4, big)!;
	put(w, 64, 2, big)!; put(w, 0, 2, big)!; put(w, 0, 2, big)!; put(w, 64, 2, big)!; put(w, count, 2, big)!; put(w, 1, 2, big)!;
	foreach (s : e.sections) foreach (b : s.bytes) w.write_byte(b)!;
	pad(w, sym_aligned - sym_off)!;
	// Null symbol.
	pad(w, 24)!;
	uint noff = (uint)DEFAULT_STRTAB.len; ushort si = 1;
	foreach (s : e.locals) { write_symbol(w, s, noff, big)!; s.index = si++; noff += (uint)s.name.len + 1; }
	foreach (s : e.globals) { write_symbol(w, s, noff, big)!; s.index = si++; noff += (uint)s.name.len + 1; }
	foreach (s : e.sections) foreach (r : s.relocs) { put(w, r.offset, 8, big)!; put(w, ((ulong)r.symbol.index << 32) | r.kind, 8, big)!; put(w, (ulong)r.addend, 8, big)!; }
	io::write_all(w, DEFAULT_STRTAB)!;
	foreach (s : e.locals) { io::write_all(w, s.name)!; w.write_byte(0)!; }
	foreach (s : e.globals) { io::write_all(w, s.name)!; w.write_byte(0)!; }
	uint section_name_off = noff;
	foreach (s : e.sections) { if (s.relocs.len()) io::write_all(w, ".rela")!; io::write_all(w, ".")!; io::write_all(w, s.name)!; w.write_byte(0)!; }
	pad(w, sh_off - (str_off + e.strtab_len))!; pad(w, 64)!;
	write_shdr(w, 1, 3, 0, str_off, e.strtab_len, 0, 0, 1, 0, big)!;
	write_shdr(w, 9, 2, 0, sym_aligned, sym_len, 1, (ulong)e.locals.len() + 1, 8, 24, big)!;
	ulong sec_off = 64; ulong roff = rela_off; noff = section_name_off;
	foreach (s : e.sections)
	{
		uint rela_prefix = s.relocs.len() ? 5 : 0;
		write_shdr(w, (ulong)noff + rela_prefix, 1, s.flags, sec_off, (ulong)s.bytes.len(), 0, 0, (s.flags & 4) ? 16 : 1, 0, big)!;
		if (s.relocs.len()) { write_shdr(w, noff, 4, 0, roff, (ulong)s.relocs.len() * 24, 2, s.index, 8, 24, big)!; roff += (ulong)s.relocs.len() * 24; }
		sec_off += (ulong)s.bytes.len(); noff += (uint)s.name.len + 2 + rela_prefix;
	}
	if (&w.flush) w.flush()!;
}

fn void? write_symbol(OutStream w, Symbol* s, uint name, bool big)
{
	put(w, name, 4, big)!; w.write_byte(s.info)!; w.write_byte(0)!;
	put(w, s.section ? s.section.index : 0, 2, big)!; put(w, s.offset, 8, big)!; put(w, s.size, 8, big)!;
}
fn void? write_shdr(OutStream w, ulong name, ulong ty, ulong flags, ulong offset, ulong size, ulong link, ulong info, ulong align, ulong entsize, bool big)
{
	put(w, name, 4, big)!; put(w, ty, 4, big)!; put(w, flags, 8, big)!; put(w, 0, 8, big)!;
	put(w, offset, 8, big)!; put(w, size, 8, big)!; put(w, link, 4, big)!; put(w, info, 4, big)!;
	put(w, align, 8, big)!; put(w, entsize, 8, big)!;
}
