// Port of src/aro/Source.zig: source identifiers, locations and line/column
// expansion. A `Source` is a plain value; the bytes it points to are owned by
// the `Compilation` that created it (see compilation.c3).
module aro::source;

<*
 Stable identifier of a source. Mirrors Zig's `packed struct(u32)`:
 bits 0..30 are the index, bit 31 marks an index into the alias table.
*>
bitstruct SourceId : uint
{
	uint index : 0..30;
	bool is_alias : 31;
}

const uint UNUSED_INDEX = 0x7FFF_FFFF;    // maxInt(u31) - 0
const uint GENERATED_INDEX = 0x7FFF_FFFE; // maxInt(u31) - 1

const SourceId UNUSED_ID = { .index = UNUSED_INDEX };
const SourceId GENERATED_ID = { .index = GENERATED_INDEX };

fn bool SourceId.is_unused(self) => !self.is_alias && self.index == UNUSED_INDEX;
fn bool SourceId.is_generated(self) => !self.is_alias && self.index == GENERATED_INDEX;

<* Classifies the file for line marker output in -E mode *>
enum SourceKind : char
{
	USER,            // regular file
	SYSTEM,          // included from a system include directory
	EXTERN_C_SYSTEM, // included from an "implicit extern C" directory
}

<* A position in a source. Zero-initialization is NOT the unused location; use UNUSED_LOCATION. *>
struct Location
{
	SourceId id;
	uint byte_offset;
	uint line;
}

const Location UNUSED_LOCATION = { .id = UNUSED_ID };

fn bool Location.eql(self, Location other)
{
	return self.id == other.id && self.byte_offset == other.byte_offset && self.line == other.line;
}

struct ExpandedLocation
{
	String path;
	String line; // slice of the source buffer (borrowed)
	uint line_no;
	uint col;
	uint width;
	bool end_with_splice;
	SourceKind kind;
}

struct Source
{
	String path;
	<* Normalized contents. Always followed by a NUL byte: buf.ptr[buf.len] == 0. *>
	String buf;
	SourceId id;
	<*
	 Each entry is a byte position within `buf` where a backslash+newline was deleted
	 from the original raw buffer. The same position can appear multiple times if
	 multiple consecutive splices happened. Guaranteed to be non-decreasing.
	*>
	uint[] splice_locs;
	SourceKind kind;
	<* Path of the umbrella framework; a prefix slice of `path`, or an empty slice for none. *>
	String umbrella_framework_path;
}

fn bool Source.has_umbrella_framework_path(&self) => self.umbrella_framework_path.ptr != null;

<* Number of bytes of a UTF-8 sequence starting with `b`, or 0 if `b` is not a valid start byte. *>
fn uint utf8_sequence_length(char b) @private
{
	switch
	{
		case b < 0x80: return 1;
		case (b & 0xE0) == 0xC0: return 2;
		case (b & 0xF0) == 0xE0: return 3;
		case (b & 0xF8) == 0xF0: return 4;
		default: return 0;
	}
}

<*
 Decode a UTF-8 sequence of length `len` (2..4) with the same validity rules as
 std.unicode.utf8Decode2/3/4. Returns false for malformed sequences.
*>
fn bool utf8_decode(char* s, uint len, uint* out) @private
{
	for (uint k = 1; k < len; k++)
	{
		if ((s[k] & 0xC0) != 0x80) return false;
	}
	uint cp;
	switch (len)
	{
		case 2:
			cp = (uint)(s[0] & 0x1F) << 6 | (s[1] & 0x3F);
			if (cp < 0x80) return false;
		case 3:
			cp = (uint)(s[0] & 0x0F) << 12 | (uint)(s[1] & 0x3F) << 6 | (s[2] & 0x3F);
			if (cp < 0x800) return false;
			if (cp >= 0xD800 && cp <= 0xDFFF) return false;
		case 4:
			cp = (uint)(s[0] & 0x07) << 18 | (uint)(s[1] & 0x3F) << 12 | (uint)(s[2] & 0x3F) << 6 | (s[3] & 0x3F);
			if (cp < 0x10000) return false;
			if (cp > 0x10FFFF) return false;
		default:
			unreachable();
	}
	*out = cp;
	return true;
}

<* Expand `loc` (which must be inside this source) into line text, column and display width. *>
fn ExpandedLocation Source.line_col(&self, Location loc)
{
	String buf = self.buf;
	usz offset = loc.byte_offset;
	usz start = 0;
	// find the start of the line which is either a newline or a splice
	for (usz k = offset; k > 0; k--)
	{
		if (buf[k - 1] == '\n')
		{
			start = k;
			break;
		}
	}
	uint splice_index = (uint)self.splice_locs.len;
	foreach (idx, splice_offset : self.splice_locs)
	{
		if (splice_offset > start)
		{
			if (splice_offset < offset)
			{
				start = splice_offset;
				splice_index = (uint)idx + 1;
				break;
			}
			splice_index = (uint)idx;
			break;
		}
	}

	usz i = start;
	uint col = 1;
	uint width = 0;
	// TODO (from Zig) this is still incorrect, but better
	for (; i < offset; col++)
	{
		uint len = utf8_sequence_length(buf[i]);
		if (len == 0)
		{
			i++;
			continue;
		}
		if (len > buf.len - i) break;
		uint cp = buf[i];
		if (len > 1 && !utf8_decode(&buf[i], len, &cp))
		{
			i++;
			continue;
		}
		width += codepoint_width(cp);
		i += len;
	}

	// find the end of the line which is either a newline, EOF or a splice
	usz nl = buf.len;
	bool end_with_splice = false;
	for (usz k = start; k < buf.len; k++)
	{
		if (buf[k] == '\n')
		{
			nl = k;
			break;
		}
	}
	if (self.splice_locs.len > splice_index && nl > self.splice_locs[splice_index] && self.splice_locs[splice_index] > start)
	{
		end_with_splice = true;
		nl = self.splice_locs[splice_index];
	}
	return {
		.path = self.path,
		.line = buf[start:nl - start],
		.line_no = loc.line,
		.col = col,
		.width = width,
		.end_with_splice = end_with_splice,
		.kind = self.kind,
	};
}

<* Terminal display width of a codepoint (1 or 2). *>
fn uint codepoint_width(uint cp)
{
	switch (cp)
	{
		case 0x1100..0x115F:
		case 0x2329:
		case 0x232A:
		case 0x2E80..0x303F:
		case 0x3040..0x3247:
		case 0x3250..0x4DBF:
		case 0x4E00..0xA4C6:
		case 0xA960..0xA97C:
		case 0xAC00..0xD7A3:
		case 0xF900..0xFAFF:
		case 0xFE10..0xFE19:
		case 0xFE30..0xFE6B:
		case 0xFF01..0xFF60:
		case 0xFFE0..0xFFE6:
		case 0x1B000..0x1B001:
		case 0x1F200..0x1F251:
		case 0x20000..0x3FFFD:
		case 0x1F300..0x1F5FF:
		case 0x1F900..0x1F9FF:
			return 2;
		default:
			return 1;
	}
}
