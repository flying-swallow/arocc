// Bounds-checked ELF64 reader for the in-process linker's ET_REL/ET_DYN inputs.
module aro::backend::link;
import aro::compiler::reporting;
import std::collections::list;

const ushort ET_REL = 1;
const ushort ET_DYN = 3;
const ushort EM_X86_64 = 62;

const uint SHT_NULL = 0;
const uint SHT_PROGBITS = 1;
const uint SHT_SYMTAB = 2;
const uint SHT_STRTAB = 3;
const uint SHT_RELA = 4;
const uint SHT_DYNAMIC = 6;
const uint SHT_NOBITS = 8;
const uint SHT_REL = 9;
const uint SHT_DYNSYM = 11;
const uint SHT_GROUP = 17;
const uint SHT_SYMTAB_SHNDX = 18;
const uint SHT_GNU_VERDEF = 0x6ffffffd;
const uint SHT_GNU_VERNEED = 0x6ffffffe;
const uint SHT_GNU_VERSYM = 0x6fffffff;

const ulong SHF_GROUP = 0x200;
const uint GRP_COMDAT = 1;
const ushort SHN_UNDEF = 0;
const ushort SHN_ABS = 0xfff1;
const ushort SHN_COMMON = 0xfff2;
const ushort SHN_XINDEX = 0xffff;
const ushort SHN_LORESERVE = 0xff00;

const long DT_NULL = 0;
const long DT_NEEDED = 1;
const long DT_SONAME = 14;
const ushort VER_FLG_BASE = 1;
const ushort VERSYM_HIDDEN = 0x8000;

const ulong ELF_HEADER_SIZE = 64;
const ulong ELF_SECTION_HEADER_SIZE = 64;
const ulong ELF_SYMBOL_SIZE = 24;
const ulong ELF_RELA_SIZE = 24;
const ulong ELF_DYNAMIC_SIZE = 16;
const ulong ELF_VERDEF_SIZE = 20;
const ulong ELF_VERDAUX_SIZE = 8;

enum ElfKind : char
{
	REL,
	DYN,
}

struct InputSection
{
	String name;
	uint type;
	ulong flags;
	ulong addr;
	ulong offset;
	ulong size;
	uint link;
	uint info;
	ulong addralign;
	ulong entsize;
	char[] data;
	uint group;
}

struct InputSymbol
{
	String name;
	char bind;
	char type;
	char visibility;
	ushort shndx_raw;
	uint section;
	ulong value;
	ulong size;
	bool undefined;
	bool absolute;
	bool common;
	String version;
	bool version_hidden;
	ushort version_index;
}

struct InputRela
{
	ulong offset;
	uint type;
	uint symbol;
	long addend;
}

struct RelaSection
{
	uint section_index;
	uint target_section;
	InputRela[] entries;
}

struct SectionGroup
{
	uint section_index;
	uint signature_symbol;
	String signature;
	bool comdat;
	uint[] members;
}

struct ElfFile
{
	String path;
	char[] bytes;
	ElfKind kind;
	ushort machine;
	InputSection[] sections;
	InputSymbol[] symbols;
	uint first_global;
	RelaSection[] relas;
	SectionGroup[] groups;
	String soname;
	bool has_soname;
	String[] needed;
}

struct RawSection
{
	uint name;
	uint type;
	ulong flags;
	ulong addr;
	ulong offset;
	ulong size;
	uint link;
	uint info;
	ulong addralign;
	ulong entsize;
}

struct VersionName
{
	ushort index;
	String name;
}

fn bool is_elf(char[] bytes)
{
	return bytes.len >= 4 && bytes[0] == (char)0x7f && bytes[1] == 'E' && bytes[2] == 'L' && bytes[3] == 'F';
}

fn bool range_ok(ulong off, ulong size, ulong len)
{
	return off <= len && size <= len - off;
}

<* @return? MALFORMED_ELF *>
fn ushort? u16(char[] b, ulong at)
{
	if (!range_ok(at, 2, (ulong)b.len)) return MALFORMED_ELF~;
	return (ushort)((ushort)b[(sz)at] | ((ushort)b[(sz)at + 1] << 8));
}

<* @return? MALFORMED_ELF *>
fn uint? u32(char[] b, ulong at)
{
	if (!range_ok(at, 4, (ulong)b.len)) return MALFORMED_ELF~;
	uint value = 0;
	for (uint i = 0; i < 4; i++) value |= (uint)b[(sz)at + (sz)i] << (i * 8);
	return value;
}

<* @return? MALFORMED_ELF *>
fn ulong? u64(char[] b, ulong at)
{
	if (!range_ok(at, 8, (ulong)b.len)) return MALFORMED_ELF~;
	ulong value = 0;
	for (uint i = 0; i < 8; i++) value |= (ulong)b[(sz)at + (sz)i] << (i * 8);
	return value;
}

<* @return? MALFORMED_ELF *>
fn String? cstr(char[] table, uint off)
{
	if ((ulong)off >= (ulong)table.len) return MALFORMED_ELF~;
	for (ulong i = (ulong)off; i < (ulong)table.len; i++)
	{
		if (table[(sz)i] == 0) return (String)table[(sz)off : (sz)(i - (ulong)off)];
	}
	return MALFORMED_ELF~;
}

<* @return? MALFORMED_ELF *>
fn void? malformed(reporting::Sink d, String path, String reason)
{
	@link_err(d, LinkDiagnostic.MALFORMED_ELF, path, reason)!;
	return MALFORMED_ELF~;
}

<* @return? UNSUPPORTED_ELF *>
fn void? unsupported(reporting::Sink d, String path, String reason)
{
	@link_err(d, LinkDiagnostic.UNSUPPORTED_ELF, path, reason)!;
	return UNSUPPORTED_ELF~;
}

<* @return? MALFORMED_ELF *>
fn RawSection? read_raw_section(char[] bytes, ulong at)
{
	return {
		.name = u32(bytes, at)!,
		.type = u32(bytes, at + 4)!,
		.flags = u64(bytes, at + 8)!,
		.addr = u64(bytes, at + 16)!,
		.offset = u64(bytes, at + 24)!,
		.size = u64(bytes, at + 32)!,
		.link = u32(bytes, at + 40)!,
		.info = u32(bytes, at + 44)!,
		.addralign = u64(bytes, at + 48)!,
		.entsize = u64(bytes, at + 56)!,
	};
}

fn uint find_linked_section_type(InputSection[] sections, uint type, uint link)
{
	for (sz i = 0; i < sections.len; i++)
	{
		if (sections[i].type == type && sections[i].link == link) return (uint)i;
	}
	return 0;
}

<* @return? MALFORMED_ELF *>
fn String? section_string(reporting::Sink d, String path, char[] table, uint off)
{
	String? result = cstr(table, off);
	if (catch f = result)
	{
		malformed(d, path, "string offset is outside its table or is not NUL-terminated")!;
		return MALFORMED_ELF~;
	}
	return result;
}

<* @return? MALFORMED_ELF, UNSUPPORTED_ELF *>
fn uint? read_symbols(Allocator arena, reporting::Sink d, String path, InputSection[] sections,
	uint table_index, uint expected_type, InputSymbol[]* out_symbols, uint* first_global)
{
	InputSection* table = &sections[(sz)table_index];
	if (table.type != expected_type)
	{
		malformed(d, path, "symbol table has an unexpected section type")!;
	}
	if (table.entsize != ELF_SYMBOL_SIZE || table.size % ELF_SYMBOL_SIZE != 0)
	{
		malformed(d, path, "symbol table has an invalid entry size")!;
	}
	if (table.link >= (uint)sections.len || sections[(sz)table.link].type != SHT_STRTAB)
	{
		malformed(d, path, "symbol table link is not a string table")!;
	}
	ulong count64 = table.size / ELF_SYMBOL_SIZE;
	if (count64 > 0xFFFF_FFFF || (ulong)table.info > count64)
	{
		malformed(d, path, "symbol table count or first-global index is invalid")!;
	}
	uint count = (uint)count64;
	InputSection* strings = &sections[(sz)table.link];
	uint xindex_section = find_linked_section_type(sections, SHT_SYMTAB_SHNDX, table_index);
	for (sz i = 0; i < sections.len; i++)
	{
		if (sections[i].type == SHT_SYMTAB_SHNDX && sections[i].link == table_index)
		{
			if (xindex_section != (uint)i)
			{
				malformed(d, path, "multiple extended symbol index tables")!;
			}
			if (sections[i].entsize != 4 || sections[i].size != count64 * 4)
			{
				malformed(d, path, "extended symbol index table has an invalid size")!;
			}
		}
	}

	List{InputSymbol} symbols;
	symbols.init(arena, (sz)count);
	for (uint i = 0; i < count; i++)
	{
		ulong at = (ulong)i * ELF_SYMBOL_SIZE;
		uint name_offset = u32(table.data, at)!;
		char info = table.data[(sz)(at + 4)];
		char other = table.data[(sz)(at + 5)];
		ushort raw_index = u16(table.data, at + 6)!;
		ulong value = u64(table.data, at + 8)!;
		ulong size = u64(table.data, at + 16)!;
		String name = section_string(d, path, strings.data, name_offset)!;
		uint index = raw_index;
		if (raw_index == SHN_XINDEX)
		{
			if (!xindex_section)
			{
				malformed(d, path, "symbol uses SHN_XINDEX without an extended index table")!;
			}
			index = u32(sections[(sz)xindex_section].data, (ulong)i * 4)!;
		}

		InputSymbol symbol = {
			.name = name,
			.bind = (char)(((uint)info >> 4) & 0xf),
			.type = (char)((uint)info & 0xf),
			.visibility = (char)((uint)other & 3),
			.shndx_raw = raw_index,
			.section = 0,
			.value = value,
			.size = size,
			.undefined = false,
			.absolute = false,
			.common = false,
			.version = "",
			.version_hidden = false,
			.version_index = 0,
		};
		if (index == SHN_UNDEF)
		{
			symbol.undefined = true;
		}
		else if (index == SHN_ABS)
		{
			symbol.absolute = true;
		}
		else if (index == SHN_COMMON)
		{
			symbol.common = true;
		}
		else if (raw_index != SHN_XINDEX && index >= SHN_LORESERVE)
		{
			unsupported(d, path, "reserved symbol section index")!;
		}
		else if (index >= (uint)sections.len)
		{
			malformed(d, path, "symbol section index is outside the section table")!;
		}
		else
		{
			symbol.section = index;
		}
		symbols.push(symbol);
	}
	*out_symbols = symbols.array_view();
	*first_global = table.info;
	return count;
}

<* @return? MALFORMED_ELF, UNSUPPORTED_ELF *>
fn void? parse_relas(Allocator arena, reporting::Sink d, String path, InputSection[] sections,
	uint symbol_table_index, uint symbol_count, RelaSection[]* out_relas)
{
	List{RelaSection} relas;
	relas.init(arena);
	for (uint i = 0; i < (uint)sections.len; i++)
	{
		InputSection* section = &sections[(sz)i];
		if (section.type == SHT_REL)
		{
			unsupported(d, path, "SHT_REL on x86_64")!;
		}
		if (section.type != SHT_RELA) continue;
		if (section.entsize != ELF_RELA_SIZE || section.size % ELF_RELA_SIZE != 0)
		{
			malformed(d, path, "RELA section has an invalid entry size")!;
		}
		if (section.link != symbol_table_index)
		{
			malformed(d, path, "RELA section does not link to the selected symbol table")!;
		}
		if (section.info >= (uint)sections.len)
		{
			malformed(d, path, "RELA target section index is outside the section table")!;
		}
		ulong count64 = section.size / ELF_RELA_SIZE;
		if (count64 > 0xFFFF_FFFF)
		{
			malformed(d, path, "RELA entry count is too large")!;
		}
		List{InputRela} entries;
		entries.init(arena, (sz)count64);
		for (uint j = 0; j < (uint)count64; j++)
		{
			ulong at = (ulong)j * ELF_RELA_SIZE;
			ulong offset = u64(section.data, at)!;
			ulong info = u64(section.data, at + 8)!;
			long addend = (long)u64(section.data, at + 16)!;
			uint symbol = (uint)(info >> 32);
			if (symbol >= symbol_count)
			{
				malformed(d, path, "RELA symbol index is outside the symbol table")!;
			}
			entries.push({ .offset = offset, .type = (uint)info, .symbol = symbol, .addend = addend });
		}
		relas.push({ .section_index = i, .target_section = section.info, .entries = entries.array_view() });
	}
	*out_relas = relas.array_view();
	return;
}

<* @return? MALFORMED_ELF *>
fn void? parse_groups(Allocator arena, reporting::Sink d, String path, InputSection[] sections,
	InputSymbol[] symbols, uint symbol_table_index, SectionGroup[]* out_groups)
{
	List{SectionGroup} groups;
	groups.init(arena);
	for (uint i = 0; i < (uint)sections.len; i++)
	{
		InputSection* section = &sections[(sz)i];
		if (section.type != SHT_GROUP) continue;
		if (section.size < 4 || section.size % 4 != 0)
		{
			malformed(d, path, "group section has an invalid size")!;
		}
		if (section.link != symbol_table_index || section.info >= (uint)symbols.len)
		{
			malformed(d, path, "group section has an invalid symbol table or signature index")!;
		}
		uint flags = u32(section.data, 0)!;
		ulong member_count64 = section.size / 4 - 1;
		if (member_count64 > 0xFFFF_FFFF)
		{
			malformed(d, path, "group member count is too large")!;
		}
		List{uint} members;
		members.init(arena, (sz)member_count64);
		for (uint j = 0; j < (uint)member_count64; j++)
		{
			uint member = u32(section.data, 4 + (ulong)j * 4)!;
			if (member >= (uint)sections.len || member == i)
			{
				malformed(d, path, "group member index is outside the section table or names its group")!;
			}
			sections[(sz)member].group = (uint)groups.len() + 1;
			members.push(member);
		}
		groups.push({
			.section_index = i,
			.signature_symbol = section.info,
			.signature = symbols[(sz)section.info].name,
			.comdat = (flags & GRP_COMDAT) != 0,
			.members = members.array_view(),
		});
	}
	*out_groups = groups.array_view();
	return;
}

<* @return? MALFORMED_ELF *>
fn void? parse_dynamic(Allocator arena, reporting::Sink d, String path, InputSection[] sections,
	String* soname, bool* has_soname, String[]* out_needed)
{
	List{String} needed;
	needed.init(arena);
	uint dynamic_count = 0;
	for (uint i = 0; i < (uint)sections.len; i++) if (sections[(sz)i].type == SHT_DYNAMIC) dynamic_count++;
	if (dynamic_count > 1) malformed(d, path, "multiple dynamic sections")!;
	for (uint i = 0; i < (uint)sections.len; i++)
	{
		InputSection* section = &sections[(sz)i];
		if (section.type != SHT_DYNAMIC) continue;
		if (section.entsize != ELF_DYNAMIC_SIZE || section.size % ELF_DYNAMIC_SIZE != 0)
		{
			malformed(d, path, "dynamic section has an invalid entry size")!;
		}
		if (section.link >= (uint)sections.len || sections[(sz)section.link].type != SHT_STRTAB)
		{
			malformed(d, path, "dynamic section link is not a string table")!;
		}
		char[] strings = sections[(sz)section.link].data;
		for (ulong at = 0; at < section.size; at += ELF_DYNAMIC_SIZE)
		{
			long tag = (long)u64(section.data, at)!;
			ulong value = u64(section.data, at + 8)!;
			if (tag == DT_NULL) break;
			if (tag == DT_NEEDED)
			{
				if (value > 0xFFFF_FFFF) malformed(d, path, "dynamic string offset exceeds ELF string-table range")!;
				needed.push(section_string(d, path, strings, (uint)value)!);
			}
			else if (tag == DT_SONAME)
			{
				if (value > 0xFFFF_FFFF) malformed(d, path, "dynamic string offset exceeds ELF string-table range")!;
				*soname = section_string(d, path, strings, (uint)value)!;
				*has_soname = true;
			}
		}
	}
	*out_needed = needed.array_view();
	return;
}

<* @return? MALFORMED_ELF *>
fn String? version_name(VersionName[] versions, ushort index)
{
	for (sz i = 0; i < versions.len; i++) if (versions[i].index == index) return versions[i].name;
	return MALFORMED_ELF~;
}

<* @return? MALFORMED_ELF *>
fn void? parse_versions(Allocator arena, reporting::Sink d, String path, InputSection[] sections,
	InputSymbol[] symbols, uint dynsym_index)
{
	uint versym_index = 0;
	uint verdef_index = 0;
	uint versym_count = 0;
	uint verdef_count = 0;
	for (uint i = 0; i < (uint)sections.len; i++)
	{
		if (sections[(sz)i].type == SHT_GNU_VERSYM)
		{
			versym_count++;
			versym_index = i;
		}
		if (sections[(sz)i].type == SHT_GNU_VERDEF)
		{
			verdef_count++;
			verdef_index = i;
		}
	}
	if (versym_count > 1 || verdef_count > 1)
	{
		malformed(d, path, "multiple GNU symbol version sections")!;
	}
	if (versym_count && sections[(sz)versym_index].link != dynsym_index)
	{
		malformed(d, path, "version symbol table does not link to the dynamic symbol table")!;
	}
	if (verdef_count && (sections[(sz)verdef_index].link >= (uint)sections.len || sections[(sz)sections[(sz)verdef_index].link].type != SHT_STRTAB))
	{
		malformed(d, path, "version definition section link is not a string table")!;
	}
	List{VersionName} versions;
	versions.init(arena);
	if (verdef_count)
	{
		InputSection* verdef = &sections[(sz)verdef_index];
		char[] strings = sections[(sz)verdef.link].data;
		ulong at = 0;
		for (uint i = 0; i < verdef.info; i++)
		{
			if (!range_ok(at, ELF_VERDEF_SIZE, verdef.size))
			{
				malformed(d, path, "version definition header is truncated")!;
			}
			ushort version = u16(verdef.data, at)!;
			ushort flags = u16(verdef.data, at + 2)!;
			ushort index = u16(verdef.data, at + 4)!;
			ushort aux_count = u16(verdef.data, at + 6)!;
			uint aux_offset = u32(verdef.data, at + 12)!;
			uint next = u32(verdef.data, at + 16)!;
			(void)flags;
			if (version != 1 || aux_count == 0)
			{
				malformed(d, path, "version definition has an unsupported version or no auxiliary name")!;
			}
			ulong aux_at = at + (ulong)aux_offset;
			if (aux_at < at || !range_ok(aux_at, ELF_VERDAUX_SIZE, verdef.size))
			{
				malformed(d, path, "version definition auxiliary record is out of bounds")!;
			}
			uint name_offset = u32(verdef.data, aux_at)!;
			String name = section_string(d, path, strings, name_offset)!;
			for (sz j = 0; j < versions.len(); j++)
			{
				if (versions.entries[j].index == index)
				{
					malformed(d, path, "duplicate version definition index")!;
				}
			}
			versions.push({ .index = index, .name = name });
			if (i + 1 == verdef.info)
			{
				if (next != 0)
				{
					malformed(d, path, "version definition chain continues past its declared count")!;
				}
			}
			else
			{
				if ((ulong)next < ELF_VERDEF_SIZE || (ulong)next > verdef.size - at)
				{
					malformed(d, path, "version definition next record is out of bounds")!;
				}
				at += (ulong)next;
			}
		}
	}

	if (!versym_count) return;
	InputSection* versym = &sections[(sz)versym_index];
	if ((ulong)symbols.len > ulong::max / 2 || versym.size != (ulong)symbols.len * 2)
	{
		malformed(d, path, "version symbol table has an invalid size")!;
	}
	for (sz i = 0; i < symbols.len; i++)
	{
		ushort value = u16(versym.data, (ulong)i * 2)!;
		ushort index = (ushort)(value & 0x7fff);
		symbols[i].version_hidden = (value & VERSYM_HIDDEN) != 0;
		symbols[i].version_index = index;
		if (index < 2) continue;
		String? name = version_name(versions.array_view(), index);
		if (catch f = name)
		{
			if (!symbols[i].undefined) malformed(d, path, "defined dynamic symbol refers to an unknown version")!;
			continue;
		}
		symbols[i].version = name;
	}
	return;
}

<*
 Read an ELF64 little-endian x86-64 ET_REL or ET_DYN input. All result arrays
 are allocated from `arena`; names and file-backed section data borrow `bytes`.
 The caller owns the arena and releases the complete result by freeing it.
 @return? link::MALFORMED_ELF, link::UNSUPPORTED_ELF
*>
fn ElfFile? read_elf(Allocator arena, reporting::Sink d, String path, char[] bytes)
{
	if ((ulong)bytes.len < ELF_HEADER_SIZE) malformed(d, path, "ELF header is truncated")!;
	if (!is_elf(bytes)) malformed(d, path, "invalid ELF magic")!;
	if (bytes[6] != 1) malformed(d, path, "unsupported ELF identification version")!;
	if (bytes[4] != 2 || bytes[5] != 1)
	{
		unsupported(d, path, "only ELF64 little-endian files are supported")!;
	}
	ushort elf_type = u16(bytes, 16)!;
	ushort machine = u16(bytes, 18)!;
	uint version = u32(bytes, 20)!;
	ulong section_offset = u64(bytes, 40)!;
	ushort section_entry_size = u16(bytes, 58)!;
	ushort section_count16 = u16(bytes, 60)!;
	ushort section_names16 = u16(bytes, 62)!;
	if (version != 1) malformed(d, path, "unsupported ELF header version")!;
	if (machine != EM_X86_64) unsupported(d, path, "only EM_X86_64 is supported")!;
	if (elf_type != ET_REL && elf_type != ET_DYN) unsupported(d, path, "only ET_REL and ET_DYN are supported")!;

	ulong section_count64 = section_count16;
	ulong section_names64 = section_names16;
	if ((section_count16 == 0 && section_offset != 0) || section_names16 == SHN_XINDEX)
	{
		if (section_offset == 0)
		{
			malformed(d, path, "section header table has a zero file offset")!;
		}
		if (section_entry_size != ELF_SECTION_HEADER_SIZE)
		{
			malformed(d, path, "extended section numbering needs 64-byte section headers")!;
		}
		if (!range_ok(section_offset, ELF_SECTION_HEADER_SIZE, (ulong)bytes.len))
		{
			malformed(d, path, "section header zero is outside the file")!;
		}
		RawSection first = read_raw_section(bytes, section_offset)!;
		if (section_count16 == 0) section_count64 = first.size;
		if (section_names16 == SHN_XINDEX) section_names64 = first.link;
	}
	if (section_count64 == 0)
	{
		if (elf_type == ET_DYN) unsupported(d, path, "no section headers")!;
		malformed(d, path, "relocatable ELF has no section headers")!;
	}
	if (section_entry_size != ELF_SECTION_HEADER_SIZE)
	{
		malformed(d, path, "section header entry size is not 64 bytes")!;
	}
	if (section_offset == 0)
	{
		malformed(d, path, "section header table has a zero file offset")!;
	}
	if (section_count64 > 0xFFFF_FFFF || section_count64 > ulong::max / ELF_SECTION_HEADER_SIZE)
	{
		malformed(d, path, "section header count is too large")!;
	}
	ulong section_table_size = section_count64 * ELF_SECTION_HEADER_SIZE;
	if (!range_ok(section_offset, section_table_size, (ulong)bytes.len))
	{
		malformed(d, path, "section header table is outside the file")!;
	}
	uint section_count = (uint)section_count64;
	if (section_names64 >= (ulong)section_count)
	{
		malformed(d, path, "section name table index is outside the section table")!;
	}

	List{RawSection} raw_sections;
	raw_sections.init(arena, (sz)section_count);
	for (uint i = 0; i < section_count; i++)
	{
		ulong at = section_offset + (ulong)i * ELF_SECTION_HEADER_SIZE;
		raw_sections.push(read_raw_section(bytes, at)!);
	}
	char[] section_names = {};
	if (section_names64 != 0)
	{
		RawSection* names_header = &raw_sections.entries[(sz)section_names64];
		if (names_header.type != SHT_STRTAB)
		{
			malformed(d, path, "section name table is not a string table")!;
		}
		if (!range_ok(names_header.offset, names_header.size, (ulong)bytes.len))
		{
			malformed(d, path, "section name string table is outside the file")!;
		}
		section_names = bytes[(sz)names_header.offset : (sz)names_header.size];
	}

	List{InputSection} section_list;
	section_list.init(arena, (sz)section_count);
	for (uint i = 0; i < section_count; i++)
	{
		RawSection* raw = &raw_sections.entries[(sz)i];
		String name = "";
		if (section_names64 == 0)
		{
			if (raw.name != 0) malformed(d, path, "section has a name but no section name table")!;
		}
		else
		{
			name = section_string(d, path, section_names, raw.name)!;
		}
		char[] data = {};
		if (raw.type != SHT_NOBITS && raw.type != SHT_NULL)
		{
			if (!range_ok(raw.offset, raw.size, (ulong)bytes.len))
			{
				malformed(d, path, "section data is outside the file")!;
			}
			data = bytes[(sz)raw.offset : (sz)raw.size];
		}
		section_list.push({
			.name = name,
			.type = raw.type,
			.flags = raw.flags,
			.addr = raw.addr,
			.offset = raw.offset,
			.size = raw.size,
			.link = raw.link,
			.info = raw.info,
			.addralign = raw.addralign,
			.entsize = raw.entsize,
			.data = data,
			.group = 0,
		});
	}
	InputSection[] sections = section_list.array_view();

	ElfKind kind = elf_type == ET_REL ? ElfKind.REL : ElfKind.DYN;
	uint symbol_type = kind == ElfKind.REL ? SHT_SYMTAB : SHT_DYNSYM;
	uint symbol_table_index = 0;
	uint symbol_table_count = 0;
	for (uint i = 0; i < section_count; i++)
	{
		if (sections[(sz)i].type == symbol_type)
		{
			symbol_table_index = i;
			symbol_table_count++;
		}
	}
	if (symbol_table_count != 1)
	{
		malformed(d, path, kind == ElfKind.REL ? "expected exactly one SYMTAB" : "expected exactly one DYNSYM")!;
	}
	InputSymbol[] symbols;
	uint first_global = 0;
	uint symbol_count = read_symbols(arena, d, path, sections, symbol_table_index, symbol_type,
		&symbols, &first_global)!;
	RelaSection[] relas;
	parse_relas(arena, d, path, sections, symbol_table_index, symbol_count, &relas)!;
	SectionGroup[] groups;
	parse_groups(arena, d, path, sections, symbols, symbol_table_index, &groups)!;

	String soname = "";
	bool has_soname = false;
	String[] needed;
	if (kind == ElfKind.DYN)
	{
		parse_dynamic(arena, d, path, sections, &soname, &has_soname, &needed)!;
		parse_versions(arena, d, path, sections, symbols, symbol_table_index)!;
	}
	else
	{
		needed = {};
	}

	return {
		.path = path,
		.bytes = bytes,
		.kind = kind,
		.machine = machine,
		.sections = sections,
		.symbols = symbols,
		.first_global = first_global,
		.relas = relas,
		.groups = groups,
		.soname = soname,
		.has_soname = has_soname,
		.needed = needed,
	};
}

fn InputSection* ElfFile.find_section(&self, String name)
{
	for (sz i = 0; i < self.sections.len; i++) if (self.sections[i].name == name) return &self.sections[i];
	return null;
}

fn InputSymbol* ElfFile.find_symbol(&self, String name, String version = "")
{
	for (sz i = 0; i < self.symbols.len; i++)
	{
		InputSymbol* symbol = &self.symbols[i];
		if (symbol.name == name && (!version.len || symbol.version == version)) return symbol;
	}
	return null;
}
