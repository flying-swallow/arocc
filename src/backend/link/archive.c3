// Lazy, bounds-checked reader for GNU System V archives.
module aro::backend::link;
import aro::diagnostics;
import std::collections::list;

const ulong AR_MAGIC_SIZE = 8;
const ulong AR_HEADER_SIZE = 60;

struct ArchiveSymbol
{
	String name;
	ulong member_offset;
}

struct ArchiveMember
{
	String name;
	ulong header_offset;
	ulong data_offset;
	ulong size;
	char[] data;
}

<*
 A GNU ar archive. `bytes`, `symbols`, and `long_names` borrow or reference
 storage kept alive by the caller. The regular member list is not materialized;
 callers decode a member only when they need it.
*>
struct Archive
{
	String path;
	char[] bytes;
	ArchiveSymbol[] symbols;
	String long_names;
	ulong first_member;
}

struct RawArchiveHeader
{
	String name;
	ulong header_offset;
	ulong data_offset;
	ulong size;
	ulong next_offset;
}

fn bool archive_range_ok(ulong off, ulong size, ulong len)
{
	return off <= len && size <= len - off;
}

fn bool is_archive(char[] bytes)
{
	return (ulong)bytes.len >= AR_MAGIC_SIZE && bytes[0] == '!' && bytes[1] == '<' &&
		((bytes[2] == 'a' && bytes[3] == 'r' && bytes[4] == 'c' && bytes[5] == 'h' && bytes[6] == '>') ||
		 (bytes[2] == 't' && bytes[3] == 'h' && bytes[4] == 'i' && bytes[5] == 'n' && bytes[6] == '>')) &&
		bytes[7] == '\n';
}

fn bool is_thin_archive(char[] bytes)
{
	return (ulong)bytes.len >= AR_MAGIC_SIZE && bytes[0] == '!' && bytes[1] == '<' && bytes[2] == 't' &&
		bytes[3] == 'h' && bytes[4] == 'i' && bytes[5] == 'n' && bytes[6] == '>' && bytes[7] == '\n';
}

<* @return? MALFORMED_ARCHIVE *>
fn void? malformed_archive(Diagnostics* d, String path, String reason)
{
	@link_err(d, Diagnostic.MALFORMED_ARCHIVE, path, reason)!;
	return MALFORMED_ARCHIVE~;
}

<* @return? UNSUPPORTED_ARCHIVE *>
fn void? unsupported_archive(Diagnostics* d, String path, String reason)
{
	@link_err(d, Diagnostic.UNSUPPORTED_ARCHIVE, path, reason)!;
	return UNSUPPORTED_ARCHIVE~;
}

<* Parse an unsigned decimal field. Spaces are permitted only after its digits. *>
fn ulong? archive_decimal(char[] bytes, ulong at, ulong width)
{
	if (!archive_range_ok(at, width, (ulong)bytes.len)) return MALFORMED_ARCHIVE~;
	ulong end = at + width;
	if (at == end || bytes[(sz)at] < '0' || bytes[(sz)at] > '9') return MALFORMED_ARCHIVE~;
	ulong value = 0;
	bool saw_digit = false;
	while (at < end && bytes[(sz)at] >= '0' && bytes[(sz)at] <= '9')
	{
		uint digit = (uint)(bytes[(sz)at] - '0');
		if (value > (ulong::max - digit) / 10) return MALFORMED_ARCHIVE~;
		value = value * 10 + digit;
		saw_digit = true;
		at++;
	}
	while (at < end && bytes[(sz)at] == ' ') at++;
	if (!saw_digit || at != end) return MALFORMED_ARCHIVE~;
	return value;
}

<* Parse a decimal offset from the trimmed GNU `/N` header spelling. *>
fn ulong? archive_name_offset(String text)
{
	if (!text.len) return MALFORMED_ARCHIVE~;
	ulong value = 0;
	foreach (c : text)
	{
		if (c < '0' || c > '9') return MALFORMED_ARCHIVE~;
		uint digit = (uint)(c - '0');
		if (value > (ulong::max - digit) / 10) return MALFORMED_ARCHIVE~;
		value = value * 10 + digit;
	}
	return value;
}

fn String ar_header_name(char[] bytes, ulong at)
{
	ulong end = at + 16;
	while (end > at && bytes[(sz)(end - 1)] == ' ') end--;
	return (String)bytes[(sz)at : (sz)(end - at)];
}

<* Read one member header and validate its data range and optional pad byte. *>
fn RawArchiveHeader? parse_archive_header(char[] bytes, ulong header_offset)
{
	ulong length = (ulong)bytes.len;
	if (!archive_range_ok(header_offset, AR_HEADER_SIZE, length)) return MALFORMED_ARCHIVE~;
	if (bytes[(sz)(header_offset + 58)] != '`' || bytes[(sz)(header_offset + 59)] != '\n')
	{
		return MALFORMED_ARCHIVE~;
	}
	ulong? size_opt = archive_decimal(bytes, header_offset + 48, 10);
	if (catch size_opt) return MALFORMED_ARCHIVE~;
	ulong size = size_opt;
	ulong data_offset = header_offset + AR_HEADER_SIZE;
	if (!archive_range_ok(data_offset, size, length)) return MALFORMED_ARCHIVE~;
	ulong data_end = data_offset + size;
	ulong next_offset = data_end;
	if (size & 1)
	{
		if (data_end < length)
		{
			if (bytes[(sz)data_end] != '\n') return MALFORMED_ARCHIVE~;
			next_offset++;
		}
		// Some archive writers omit the final pad byte. It is harmless at EOF.
	}
	return {
		.name = ar_header_name(bytes, header_offset),
		.header_offset = header_offset,
		.data_offset = data_offset,
		.size = size,
		.next_offset = next_offset,
	};
}

fn bool is_special_archive_name(String name)
{
	return name == "/" || name == "/SYM64/" || name == "//";
}

<* Parse a GNU symbol index into the arena list, preserving its symbol order. *>
fn void? read_gnu_index(char[] data, bool wide, List{ArchiveSymbol}* symbols)
{
	ulong word_size = wide ? 8 : 4;
	if ((ulong)data.len < word_size) return MALFORMED_ARCHIVE~;
	ulong count;
	if (wide)
	{
		count = archive_u64_be(data, 0)!;
	}
	else
	{
		count = (ulong)archive_u32_be(data, 0)!;
	}
	ulong length = (ulong)data.len;
	if (count > (length - word_size) / word_size) return MALFORMED_ARCHIVE~;
	ulong names_offset = word_size + count * word_size;
	ulong cursor = names_offset;
	for (ulong i = 0; i < count; i++)
	{
		ulong offset_at = word_size + i * word_size;
		ulong member_offset;
		if (wide)
		{
			member_offset = archive_u64_be(data, offset_at)!;
		}
		else
		{
			member_offset = (ulong)archive_u32_be(data, offset_at)!;
		}
		if (cursor >= length) return MALFORMED_ARCHIVE~;
		ulong start = cursor;
		while (cursor < length && data[(sz)cursor] != 0) cursor++;
		if (cursor == length) return MALFORMED_ARCHIVE~;
		symbols.push({
			.name = (String)data[(sz)start : (sz)(cursor - start)],
			.member_offset = member_offset,
		});
		cursor++;
	}
	return;
}

<* Decode a GNU long name terminated by `/\n` or by a newline. *>
fn String? gnu_long_name(String table, ulong offset)
{
	ulong length = (ulong)table.len;
	if (offset >= length) return MALFORMED_ARCHIVE~;
	ulong end = offset;
	while (end < length && table[(sz)end] != '\n') end++;
	if (end == length) return MALFORMED_ARCHIVE~;
	if (end > offset && table[(sz)(end - 1)] == '/') end--;
	return (String)table[(sz)offset : (sz)(end - offset)];
}

<* Decode one regular member; special members are rejected by this helper. *>
fn ArchiveMember? decode_archive_member(Archive* archive, RawArchiveHeader header, Diagnostics* d)
{
	String raw_name = header.name;
	if (is_special_archive_name(raw_name)) return MALFORMED_ARCHIVE~;
	if (raw_name.starts_with("__.SYMDEF"))
	{
		unsupported_archive(d, archive.path, "BSD archive symbol indexes are not supported")!;
	}
	if (raw_name.starts_with("#1/"))
	{
		unsupported_archive(d, archive.path, "BSD extended member names are not supported")!;
	}
	String name;
	if (raw_name.len > 1 && raw_name[0] == '/')
	{
		ulong? offset_opt = archive_name_offset(raw_name[1..]);
		if (catch offset_opt) return MALFORMED_ARCHIVE~;
		String? long_name_opt = gnu_long_name(archive.long_names, offset_opt);
		if (catch long_name_opt) return MALFORMED_ARCHIVE~;
		name = long_name_opt;
	}
	else
	{
		name = raw_name;
		if (raw_name.len > 0 && raw_name[raw_name.len - 1] == '/')
		{
			name = raw_name[0 : raw_name.len - 1];
		}
	}
	return {
		.name = name,
		.header_offset = header.header_offset,
		.data_offset = header.data_offset,
		.size = header.size,
		.data = archive.bytes[(sz)header.data_offset : (sz)header.size],
	};
}

<*
 Read only the archive magic and leading GNU symbol/long-name tables. Regular
 member headers and bodies are parsed lazily by `member_at` and `next_member`.
 All member data and names borrow the input bytes.
 @return? link::MALFORMED_ARCHIVE, link::UNSUPPORTED_ARCHIVE
*>
fn Archive? read_archive(Allocator arena, Diagnostics* d, String path, char[] bytes)
{
	if (is_thin_archive(bytes)) unsupported_archive(d, path, "thin archives are not supported")!;
	if (!is_archive(bytes)) malformed_archive(d, path, "invalid or truncated archive magic")!;
	List{ArchiveSymbol} symbols;
	symbols.init(arena);
	String long_names = "";
	bool has_long_names = false;
	bool has_index = false;
	ulong cursor = AR_MAGIC_SIZE;
	ulong length = (ulong)bytes.len;
	while (cursor < length)
	{
		// A partial header that is not recognizable as a leading special member
		// is left for the lazy member iterator to diagnose.
		if (!archive_range_ok(cursor, 16, length)) break;
		String raw_name = ar_header_name(bytes, cursor);
		if (!is_special_archive_name(raw_name)) break;
		RawArchiveHeader? header_opt = parse_archive_header(bytes, cursor);
		if (catch header_opt) malformed_archive(d, path, "malformed leading archive member")!;
		RawArchiveHeader header = header_opt!!;
		char[] data = bytes[(sz)header.data_offset : (sz)header.size];
		if (raw_name == "//")
		{
			if (has_long_names) malformed_archive(d, path, "multiple GNU long-name tables")!;
			has_long_names = true;
			long_names = (String)data;
		}
		else
		{
			if (has_index) malformed_archive(d, path, "multiple GNU symbol indexes")!;
			has_index = true;
			if (catch f = read_gnu_index(data, raw_name == "/SYM64/", &symbols))
			{
				malformed_archive(d, path, "invalid GNU symbol index")!;
			}
		}
		cursor = header.next_offset;
	}
	return {
		.path = path,
		.bytes = bytes,
		.symbols = symbols.array_view(),
		.long_names = long_names,
		.first_member = cursor,
	};
}

<*
 Parse the member whose header is named by a GNU symbol index offset.
 @return? link::MALFORMED_ARCHIVE, link::UNSUPPORTED_ARCHIVE
*>
fn ArchiveMember? Archive.member_at(&self, Diagnostics* d, ulong header_offset)
{
	if (header_offset < AR_MAGIC_SIZE || (header_offset & 1) != 0 ||
		!archive_range_ok(header_offset, AR_HEADER_SIZE, (ulong)self.bytes.len))
	{
		malformed_archive(d, self.path, "symbol index offset is not an even member header inside the archive")!;
	}
	RawArchiveHeader? header_opt = parse_archive_header(self.bytes, header_offset);
	if (catch header_opt) malformed_archive(d, self.path, "malformed archive member header")!;
	ArchiveMember? result = decode_archive_member(self, header_opt!!, d);
	if (catch err = result)
	{
		if (err == UNSUPPORTED_ARCHIVE) return UNSUPPORTED_ARCHIVE~;
		malformed_archive(d, self.path, "invalid archive member name")!;
	}
	return result!!;
}

<*
 Iterate regular members from a byte cursor. Special index/name-table headers
 encountered later in the archive are skipped without materializing their data.
 @return? link::MALFORMED_ARCHIVE, link::UNSUPPORTED_ARCHIVE
*>
fn bool? Archive.next_member(&self, Diagnostics* d, ulong* cursor, ArchiveMember* out)
{
	ulong position = *cursor;
	ulong length = (ulong)self.bytes.len;
	if (position == length) return false;
	if (position < AR_MAGIC_SIZE || position > length || (position & 1) != 0)
	{
		malformed_archive(d, self.path, "archive member cursor is outside an even header offset")!;
	}
	while (position < length)
	{
		RawArchiveHeader? header_opt = parse_archive_header(self.bytes, position);
		if (catch header_opt) malformed_archive(d, self.path, "malformed archive member header")!;
		RawArchiveHeader header = header_opt!!;
		if (is_special_archive_name(header.name))
		{
			position = header.next_offset;
			continue;
		}
		ArchiveMember? member_opt = decode_archive_member(self, header, d);
		if (catch err = member_opt)
		{
			if (err == UNSUPPORTED_ARCHIVE) return UNSUPPORTED_ARCHIVE~;
			malformed_archive(d, self.path, "invalid archive member name")!;
		}
		*out = member_opt!!;
		*cursor = header.next_offset;
		return true;
	}
	*cursor = position;
	return false;
}

<* Find the first symbol with this name; duplicate index entries stay ordered. *>
fn ArchiveSymbol* Archive.find_symbol(&self, String name)
{
	for (sz i = 0; i < self.symbols.len; i++)
	{
		if (self.symbols[i].name == name) return &self.symbols[i];
	}
	return null;
}

<* @return? MALFORMED_ARCHIVE *>
fn uint? archive_u32_be(char[] bytes, ulong at)
{
	if (!archive_range_ok(at, 4, (ulong)bytes.len)) return MALFORMED_ARCHIVE~;
	uint value = 0;
	for (uint i = 0; i < 4; i++) value = (value << 8) | (uint)bytes[(sz)at + (sz)i];
	return value;
}

<* @return? MALFORMED_ARCHIVE *>
fn ulong? archive_u64_be(char[] bytes, ulong at)
{
	if (!archive_range_ok(at, 8, (ulong)bytes.len)) return MALFORMED_ARCHIVE~;
	ulong value = 0;
	for (uint i = 0; i < 8; i++) value = (value << 8) | (ulong)bytes[(sz)at + (sz)i];
	return value;
}
