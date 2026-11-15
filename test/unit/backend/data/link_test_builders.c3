// Byte builders for hand-authored ELF and GNU archive linker fixtures.
//
// Builder lists and returned ByteBuffers use the process allocator (`mem`), so
// fixture bytes do not depend on a caller's temporary arena. Section/member
// names and payloads are borrowed until build() returns. The returned
// ByteBuffer owns its bytes and must be released with free().
module link_test_builders;
import std::collections::list;

const ushort ET_REL = 1;
const ushort ET_DYN = 3;

const uint SHT_NULL = 0;
const uint SHT_PROGBITS = 1;
const uint SHT_SYMTAB = 2;
const uint SHT_STRTAB = 3;
const uint SHT_RELA = 4;
const uint SHT_DYNAMIC = 6;
const uint SHT_NOBITS = 8;
const uint SHT_DYNSYM = 11;
const uint SHT_GROUP = 17;
const uint SHT_GNU_VERDEF = 0x6ffffffd;
const uint SHT_GNU_VERNEED = 0x6ffffffe;
const uint SHT_GNU_VERSYM = 0x6fffffff;

const long DT_NEEDED = 1;
const long DT_STRTAB = 5;
const long DT_SYMTAB = 6;
const long DT_STRSZ = 10;
const long DT_SYMENT = 11;
const long DT_SONAME = 14;
const long DT_VERSYM = 0x6ffffff0;
const long DT_VERDEF = 0x6ffffffc;
const long DT_VERDEFNUM = 0x6ffffffd;
const long DT_VERNEED = 0x6ffffffe;
const long DT_VERNEEDNUM = 0x6fffffff;

const ulong SHF_WRITE = 1;
const ulong SHF_ALLOC = 2;
const ulong SHF_EXECINSTR = 4;
const ulong SHF_GROUP = 0x200;
const uint GRP_COMDAT = 1;

const long DT_NULL = 0;

<* Owned bytes. `view()` is borrowed and remains valid until `free()`. *>
struct ByteBuffer
{
	List{char} data;
}

fn void ByteBuffer.init(&self)
{
	self.data.init(mem);
}

fn void ByteBuffer.free(&self)
{
	self.data.free();
}

fn String ByteBuffer.view(&self)
{
	return (String)self.data.array_view();
}

fn ulong ByteBuffer.len(&self)
{
	return (ulong)self.data.len();
}

fn void ByteBuffer.put_u8(&self, uint value)
{
	self.data.push((char)value);
}

fn void ByteBuffer.put_u16(&self, uint value)
{
	for (uint i = 0; i < 2; i++) self.put_u8(value >> (i * 8));
}

fn void ByteBuffer.put_u32(&self, uint value)
{
	for (uint i = 0; i < 4; i++) self.put_u8(value >> (i * 8));
}

fn void ByteBuffer.put_u64(&self, ulong value)
{
	for (uint i = 0; i < 8; i++) self.put_u8((uint)(value >> (i * 8)));
}

fn void ByteBuffer.put_u32_be(&self, uint value)
{
	for (uint i = 0; i < 4; i++) self.put_u8(value >> ((3 - i) * 8));
}

fn void ByteBuffer.put_u64_be(&self, ulong value)
{
	for (uint i = 0; i < 8; i++) self.put_u8((uint)(value >> ((7 - i) * 8)));
}

fn void ByteBuffer.put_bytes(&self, String bytes)
{
	self.data.push_all(bytes);
}

fn void ByteBuffer.put_zeros(&self, ulong count)
{
	for (ulong i = 0; i < count; i++) self.put_u8(0);
}

fn void ByteBuffer.align(&self, ulong alignment, char fill = 0)
{
	assert(alignment != 0, "byte buffer alignment must be nonzero");
	ulong padding = (alignment - self.len() % alignment) % alignment;
	for (ulong i = 0; i < padding; i++) self.put_u8((uint)fill);
}

fn void ByteBuffer.patch_u16(&self, ulong offset, uint value)
{
	assert(offset + 2 <= self.len(), "u16 patch fits in byte buffer");
	for (uint i = 0; i < 2; i++) self.data.entries[(sz)offset + (sz)i] = (char)(value >> (i * 8));
}

fn void ByteBuffer.patch_u32(&self, ulong offset, uint value)
{
	assert(offset + 4 <= self.len(), "u32 patch fits in byte buffer");
	for (uint i = 0; i < 4; i++) self.data.entries[(sz)offset + (sz)i] = (char)(value >> (i * 8));
}

fn void ByteBuffer.patch_u64(&self, ulong offset, ulong value)
{
	assert(offset + 8 <= self.len(), "u64 patch fits in byte buffer");
	for (uint i = 0; i < 8; i++) self.data.entries[(sz)offset + (sz)i] = (char)(value >> (i * 8));
}

<* ELF string table. Offsets returned by add() are suitable for st_name/version names. *>
struct StringTable
{
	ByteBuffer bytes;
}

fn void StringTable.init(&self)
{
	self.bytes.init();
	self.bytes.put_u8(0);
}

fn void StringTable.free(&self)
{
	self.bytes.free();
}

fn uint StringTable.add(&self, String text)
{
	assert(self.bytes.len() <= (ulong)uint::max, "ELF string table offset fits u32");
	uint offset = (uint)self.bytes.len();
	self.bytes.put_bytes(text);
	self.bytes.put_u8(0);
	return offset;
}

<* Append one ELF64 symbol entry; name_offset is an offset into its linked strtab. *>
fn void put_symbol64(ByteBuffer* bytes, uint name_offset, char info, char other,
	ushort section_index, ulong value, ulong size)
{
	bytes.put_u32(name_offset);
	bytes.put_u8((uint)info);
	bytes.put_u8((uint)other);
	bytes.put_u16(section_index);
	bytes.put_u64(value);
	bytes.put_u64(size);
}

<* Append an ELF64 group payload: flags followed by section indexes. *>
fn void put_group(ByteBuffer* bytes, uint flags, ushort[] section_indexes)
{
	bytes.put_u32(flags);
	foreach (index : section_indexes) bytes.put_u32(index);
}

<* Append an ELF64 dynamic entry. Tags are signed in the ABI but encoded as u64. *>
fn void put_dynamic_entry(ByteBuffer* bytes, long tag, ulong value)
{
	bytes.put_u64((ulong)tag);
	bytes.put_u64(value);
}

<* Append an SHT_GNU_versym entry. *>
fn void put_versym(ByteBuffer* bytes, ushort version_index)
{
	bytes.put_u16(version_index);
}

<* Append an Elf_Verdef record header; use put_verdaux() for each auxiliary name. *>
fn void put_verdef_header(ByteBuffer* bytes, ushort version, ushort flags,
	ushort index, ushort aux_count, uint hash, uint aux_offset, uint next = 0)
{
	bytes.put_u16(version);
	bytes.put_u16(flags);
	bytes.put_u16(index);
	bytes.put_u16(aux_count);
	bytes.put_u32(hash);
	bytes.put_u32(aux_offset);
	bytes.put_u32(next);
}

<* Append one Elf_Verdaux version-name record. *>
fn void put_verdaux(ByteBuffer* bytes, uint name_offset, uint next = 0)
{
	bytes.put_u32(name_offset);
	bytes.put_u32(next);
}

<* Append an Elf_Verneed record header; use put_vernaux() for each auxiliary. *>
fn void put_verneed_header(ByteBuffer* bytes, ushort version, ushort aux_count,
	uint file_name_offset, uint aux_offset, uint next = 0)
{
	bytes.put_u16(version);
	bytes.put_u16(aux_count);
	bytes.put_u32(file_name_offset);
	bytes.put_u32(aux_offset);
	bytes.put_u32(next);
}

<* Append one Elf_Vernaux version requirement record. *>
fn void put_vernaux(ByteBuffer* bytes, uint hash, ushort flags, ushort version_index,
	uint name_offset, uint next = 0)
{
	bytes.put_u32(hash);
	bytes.put_u16(flags);
	bytes.put_u16(version_index);
	bytes.put_u32(name_offset);
	bytes.put_u32(next);
}

<* Append a one-name Elf_Verdef chain, useful for a minimal version definition. *>
fn void put_verdef(ByteBuffer* bytes, ushort version, ushort flags, ushort index,
	uint hash, uint name_offset, uint next = 0)
{
	put_verdef_header(bytes, version, flags, index, 1, hash, 20, next);
	put_verdaux(bytes, name_offset);
}

<* Append a one-requirement Elf_Verneed chain, useful for a minimal dependency. *>
fn void put_verneed(ByteBuffer* bytes, ushort version, ushort aux_count,
	uint file_name_offset, uint aux_hash, ushort aux_flags, ushort version_index,
	uint version_name_offset, uint next = 0)
{
	assert(aux_count == 1, "put_verneed writes one Vernaux record");
	put_verneed_header(bytes, version, aux_count, file_name_offset, 16, next);
	put_vernaux(bytes, aux_hash, aux_flags, version_index, version_name_offset);
}

struct ElfSection
{
	String name;
	String contents;
	String link_name;
	uint type;
	ulong flags;
	ulong alignment;
	ulong entry_size;
	ulong size;
	uint link;
	uint info;
}

<*
 ELF64 little-endian x86-64 fixture writer. Added section contents and names are
 borrowed until build() returns. Section indexes start at one; index zero is the
 mandatory null section. build() returns an owned, arena-independent buffer.
*>
struct ElfFixtureBuilder
{
	List{ElfSection} sections;
	ushort elf_type;
}

fn void ElfFixtureBuilder.init(&self, ushort elf_type = ET_REL)
{
	assert(elf_type == ET_REL || elf_type == ET_DYN, "fixture supports ET_REL and ET_DYN");
	self.elf_type = elf_type;
	self.sections.init(mem);
}

fn void ElfFixtureBuilder.free(&self)
{
	self.sections.free();
}

fn ushort ElfFixtureBuilder.add_section(&self, String name, uint type, ulong flags,
	ulong alignment, String contents = "", ulong entry_size = 0, uint link = 0,
	uint info = 0, String link_name = "", ulong logical_size = 0)
{
	assert(name.len != 0 && name != ".shstrtab", "section name is nonempty and .shstrtab is reserved");
	assert(alignment != 0, "ELF section alignment must be nonzero");
	assert(self.sections.len() < (sz)(ushort::max - 1), "fixture section count fits ELF64 header");
	foreach (section : self.sections) assert(section.name != name, "fixture section names are unique");
	ulong size = logical_size ? logical_size : (ulong)contents.len;
	if (type != SHT_NOBITS) assert(size == (ulong)contents.len, "file-backed section size matches contents");
	self.sections.push({
		.name = name,
		.contents = contents,
		.link_name = link_name,
		.type = type,
		.flags = flags,
		.alignment = alignment,
		.entry_size = entry_size,
		.size = size,
		.link = link,
		.info = info,
	});
	return (ushort)self.sections.len();
}

<* Add a strtab built with StringTable; its name offsets remain valid in the payload. *>
fn ushort ElfFixtureBuilder.add_string_table(&self, String name, StringTable* table)
{
	return self.add_section(name, SHT_STRTAB, 0, 1, table.bytes.view());
}

<* Add SHT_SYMTAB or SHT_DYNSYM entries linked to the named string table. *>
fn ushort ElfFixtureBuilder.add_symbol_table(&self, String name, String strtab_name,
	ByteBuffer* entries, bool dynamic, uint first_global)
{
	assert(entries.len() % 24 == 0, "ELF64 symbol table contains complete entries");
	assert(entries.len() >= 24, "ELF symbol table includes the null symbol");
	assert(first_global >= 1, "ELF symbol table keeps the null symbol local");
	assert(first_global <= entries.len() / 24, "symbol table local/global boundary is valid");
	for (uint i = 0; i < 24; i++) assert(entries.data.entries[i] == 0, "first ELF symbol entry is null");
	uint type = dynamic ? SHT_DYNSYM : SHT_SYMTAB;
	return self.add_section(name, type, 0, 8, entries.view(), 24, 0, first_global, strtab_name);
}

fn ushort ElfFixtureBuilder.find_section(&self, String name)
{
	for (sz i = 0; i < self.sections.len(); i++) if (self.sections.entries[i].name == name) return (ushort)(i + 1);
	return 0;
}

fn uint ElfFixtureBuilder.resolve_link(&self, ElfSection* section)
{
	if (!section.link_name.len) return section.link;
	ushort index = self.find_section(section.link_name);
	assert(index != 0, "section link name resolves to an existing fixture section");
	return index;
}

fn void ElfFixtureBuilder.write_section_header(&self, ByteBuffer* out, uint name_offset,
	uint type, ulong flags, ulong offset, ulong size, uint link, uint info,
	ulong alignment, ulong entry_size)
{
	out.put_u32(name_offset);
	out.put_u32(type);
	out.put_u64(flags);
	out.put_u64(0); // sh_addr
	out.put_u64(offset);
	out.put_u64(size);
	out.put_u32(link);
	out.put_u32(info);
	out.put_u64(alignment);
	out.put_u64(entry_size);
}

<* Serialize the complete fixture. ET_DYN fixtures intentionally have no program headers. *>
fn ByteBuffer ElfFixtureBuilder.build(&self)
{
	ByteBuffer out;
	out.init();
	List{ulong} offsets;
	offsets.init(mem);
	defer offsets.free();
	List{uint} name_offsets;
	name_offsets.init(mem);
	defer name_offsets.free();
	ByteBuffer shstrtab;
	shstrtab.init();
	defer shstrtab.free();
	shstrtab.put_u8(0);
	name_offsets.push(0);
	for (sz i = 0; i < self.sections.len(); i++) name_offsets.push(0);
	for (sz i = 0; i < self.sections.len(); i++)
	{
		ElfSection* section = &self.sections.entries[i];
		assert(shstrtab.len() <= (ulong)uint::max, "section name offset fits u32");
		name_offsets.entries[i + 1] = (uint)shstrtab.len();
		shstrtab.put_bytes(section.name);
		shstrtab.put_u8(0);
	}
	assert(shstrtab.len() <= (ulong)uint::max, "section name table fits u32 offsets");
	uint shstr_name_offset = (uint)shstrtab.len();
	shstrtab.put_bytes(".shstrtab");
	shstrtab.put_u8(0);

	// Reserve the ELF header; file-backed sections follow in declaration order.
	out.put_zeros(64);
	for (sz i = 0; i < self.sections.len(); i++)
	{
		ElfSection* section = &self.sections.entries[i];
		out.align(section.alignment);
		offsets.push(out.len());
		if (section.type != SHT_NOBITS) out.put_bytes(section.contents);
	}
	out.align(1);
	ulong shstr_offset = out.len();
	out.put_bytes(shstrtab.view());
	out.align(8);
	ulong shoff = out.len();
	uint shnum = (uint)self.sections.len() + 2; // null, user sections, .shstrtab
	uint shstr_index = (uint)self.sections.len() + 1;
	// Null section header.
	self.write_section_header(&out, 0, SHT_NULL, 0, 0, 0, 0, 0, 0, 0);
	for (sz i = 0; i < self.sections.len(); i++)
	{
		ElfSection* section = &self.sections.entries[i];
		uint link = self.resolve_link(section);
		self.write_section_header(&out, name_offsets.entries[i + 1], section.type, section.flags,
			offsets.entries[i], section.size, link, section.info, section.alignment, section.entry_size);
	}
	self.write_section_header(&out, shstr_name_offset, SHT_STRTAB, 0, shstr_offset,
		shstrtab.len(), 0, 0, 1, 0);
	assert(out.len() == shoff + (ulong)shnum * 64, "ELF section header table has fixed-size entries");

	// Fill the ELF64 little-endian x86-64 header.
	out.data.entries[0] = 0x7f;
	out.data.entries[1] = 'E'; out.data.entries[2] = 'L'; out.data.entries[3] = 'F';
	out.data.entries[4] = 2; // ELFCLASS64
	out.data.entries[5] = 1; // ELFDATA2LSB
	out.data.entries[6] = 1; // EV_CURRENT
	out.data.entries[7] = 0; // ELFOSABI_NONE
	out.patch_u16(16, self.elf_type);
	out.patch_u16(18, 62); // EM_X86_64
	out.patch_u32(20, 1); // EV_CURRENT
	out.patch_u64(40, shoff);
	out.patch_u32(48, 0); // e_flags
	out.patch_u16(52, 64);
	out.patch_u16(54, 0); // no program headers
	out.patch_u16(56, 0);
	out.patch_u16(58, 64);
	out.patch_u16(60, shnum);
	out.patch_u16(62, shstr_index);
	return out;
}

struct ArBuilderMember
{
	String name;
	String contents;
}

struct ArBuilderSymbol
{
	String name;
	uint member_index;
}

<*
 GNU ar archive builder. Member names and data are borrowed until build() returns.
 Added symbol names form the GNU `/` index. The returned bytes are independently
 owned and must be released with ByteBuffer.free().
*>
struct ArBuilder
{
	List{ArBuilderMember} members;
	List{ArBuilderSymbol} symbols;
	bool include_index;
}

fn void ArBuilder.init(&self, bool include_index = true)
{
	self.include_index = include_index;
	self.members.init(mem);
	self.symbols.init(mem);
}

fn void ArBuilder.free(&self)
{
	self.members.free();
	self.symbols.free();
}

fn uint ArBuilder.add_member(&self, String name, String contents)
{
	assert(name.len != 0, "archive member name is nonempty");
	foreach (byte : name) assert(byte != 0 && byte != '\n', "GNU archive member names contain no NUL or newline");
	assert(self.members.len() < (sz)uint::max, "archive member index fits u32");
	self.members.push({ .name = name, .contents = contents });
	return (uint)(self.members.len() - 1);
}

fn void ArBuilder.add_symbol(&self, uint member_index, String name)
{
	assert(member_index < (uint)self.members.len(), "archive symbol refers to an existing member");
	assert(name.len != 0, "indexed archive symbol name is nonempty");
	foreach (byte : name) assert(byte != 0, "GNU archive symbol names contain no NUL");
	self.symbols.push({ .name = name, .member_index = member_index });
}

fn bool archive_name_needs_long(String name)
{
	if (name.len > 15) return true;
	foreach (byte : name) if (byte == ' ' || byte == '/') return true;
	return false;
}

fn void put_decimal(ByteBuffer* out, ulong value)
{
	char[24] reversed;
	sz count = 0;
	do
	{
		reversed[count++] = (char)('0' + value % 10);
		value /= 10;
	} while (value != 0);
	while (count > 0) out.put_u8((uint)reversed[--count]);
}

fn void put_ar_field(ByteBuffer* out, String value, uint width)
{
	assert(value.len <= width, "archive header field fits its fixed width");
	out.put_bytes(value);
	for (uint i = (uint)value.len; i < width; i++) out.put_u8(' ');
}

fn void put_ar_decimal_field(ByteBuffer* out, ulong value, uint width)
{
	char[24] reversed;
	sz count = 0;
	do
	{
		reversed[count++] = (char)('0' + value % 10);
		value /= 10;
	} while (value != 0);
	assert(count <= width, "archive numeric field fits its fixed width");
	for (sz i = 0; i < count; i++) out.put_u8((uint)reversed[count - i - 1]);
	for (uint i = (uint)count; i < width; i++) out.put_u8(' ');
}

fn void put_ar_header(ByteBuffer* out, String name_field, ulong size)
{
	put_ar_field(out, name_field, 16);
	put_ar_decimal_field(out, 0, 12); // timestamp
	put_ar_decimal_field(out, 0, 6); // uid
	put_ar_decimal_field(out, 0, 6); // gid
	put_ar_field(out, "100644", 8);
	put_ar_decimal_field(out, size, 10);
	out.put_bytes("`\n");
}

fn void put_gnu_name_reference(ByteBuffer* out, uint offset)
{
	out.put_u8('/');
	put_decimal(out, offset);
}

fn ulong padded_ar_size(ulong size)
{
	return size + (size & 1);
}

<* Build a GNU archive with a big-endian 32-bit symbol table and GNU long names. *>
fn ByteBuffer ArBuilder.build(&self)
{
	ByteBuffer out;
	out.init();
	List{ulong} member_offsets;
	member_offsets.init(mem);
	defer member_offsets.free();
	List{uint} long_name_offsets;
	long_name_offsets.init(mem);
	defer long_name_offsets.free();

	ulong index_size = 0;
	if (self.include_index)
	{
		index_size = 4 + (ulong)self.symbols.len() * 4;
		for (sz i = 0; i < self.symbols.len(); i++) index_size += (ulong)self.symbols.entries[i].name.len + 1;
	}
	ulong long_names_size = 0;
	for (sz i = 0; i < self.members.len(); i++)
	{
		ArBuilderMember* member = &self.members.entries[i];
		if (archive_name_needs_long(member.name))
		{
			assert(long_names_size <= (ulong)uint::max, "GNU long-name offset fits u32");
			long_name_offsets.push((uint)long_names_size);
			long_names_size += (ulong)member.name.len + 2; // name/ followed by newline
		}
		else { long_name_offsets.push(uint::max); }
	}

	ulong cursor = 8;
	if (self.include_index) cursor += 60 + padded_ar_size(index_size);
	if (long_names_size) cursor += 60 + padded_ar_size(long_names_size);
	for (sz i = 0; i < self.members.len(); i++)
	{
		member_offsets.push(cursor);
		ulong data_size = (ulong)self.members.entries[i].contents.len;
		cursor += 60 + padded_ar_size(data_size);
	}
	assert(self.symbols.len() <= (sz)uint::max, "GNU archive symbol count fits u32");
	for (sz i = 0; i < member_offsets.len(); i++) assert(member_offsets.entries[i] <= (ulong)uint::max,
		"GNU archive member offset fits its 32-bit index");

	out.put_bytes("!<arch>\n");
	if (self.include_index)
	{
		put_ar_header(&out, "/", index_size);
		out.put_u32_be((uint)self.symbols.len());
		for (sz i = 0; i < self.symbols.len(); i++)
		{
			ArBuilderSymbol* symbol = &self.symbols.entries[i];
			out.put_u32_be((uint)member_offsets.entries[symbol.member_index]);
		}
		for (sz i = 0; i < self.symbols.len(); i++)
		{
			out.put_bytes(self.symbols.entries[i].name);
			out.put_u8(0);
		}
		if (index_size & 1) out.put_u8('\n');
	}

	if (long_names_size)
	{
		put_ar_header(&out, "//", long_names_size);
		for (sz i = 0; i < self.members.len(); i++)
		{
			if (long_name_offsets.entries[i] == uint::max) continue;
			out.put_bytes(self.members.entries[i].name);
			out.put_bytes("/\n");
		}
		if (long_names_size & 1) out.put_u8('\n');
	}

	for (sz i = 0; i < self.members.len(); i++)
	{
		ArBuilderMember* member = &self.members.entries[i];
		if (long_name_offsets.entries[i] != uint::max)
		{
			ByteBuffer name_field;
			name_field.init();
			put_gnu_name_reference(&name_field, long_name_offsets.entries[i]);
			put_ar_header(&out, name_field.view(), (ulong)member.contents.len);
			name_field.free();
		}
		else
		{
			ByteBuffer name_field;
			name_field.init();
			name_field.put_bytes(member.name);
			name_field.put_u8('/');
			put_ar_header(&out, name_field.view(), (ulong)member.contents.len);
			name_field.free();
		}
		out.put_bytes(member.contents);
		if (member.contents.len & 1) out.put_u8('\n');
	}
	return out;
}
