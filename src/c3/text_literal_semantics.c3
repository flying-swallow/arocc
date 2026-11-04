// Character and string literal semantics: src/aro/Parser.zig charLiteral and
// stringLiteral (plus the `#if` character-constant rule from
// Preprocessor/Parser.zig primaryExpr), extracted so they need no Parser,
// token list or AST, and Value.zig printString (the `.bytes` arm of
// Value.print). See number_literal.c3 for how the plan 11 literal modules fit
// together.
//
// Decoding diagnostics (escapes, UCNs, encodings, multichar) are emitted by
// text_literal::TextLiteralParser itself. Parser-level diagnostics
// (unsupported_str_cat, empty / unterminated char literal) are *returned* as
// TextSemanticsDiag ids, because Zig reports them through Parser.err at a
// specific token.
//
// Deviations from Zig:
// - No AST nodes: Zig's char_literal / string_literal_expr node kind (ascii,
//   wide, utf8, utf16, utf32) follows from the returned TextLiteralKind
//   (CHAR and UNTERMINATED -> ascii).
// - The token walk of stringLiteral is split: `string_run` computes the
//   concatenated kind over token ids, `string_literal` decodes the pieces.
// - Zig's `p.strings` scratch buffer is a temporary List{char} from comp.gpa,
//   so there is no `literal_start` alignment step.
// - Zig aligns `comp.interner.strings` to Kind.internalStorageAlignment before
//   interning. Not needed here: the C3 value interner copies every bytes key
//   into its own heap allocation (allocator alignment >= 4), and print_string
//   reads code units byte-wise, so nothing depends on it.
// - Zig's UTF-16 `.utf8_text` arm transcodes into the scratch buffer starting
//   at `literal_start` instead of at the current end (a Zig bug: a UTF-8 run
//   that is not the first item of a u"" literal / run overwrites the earlier
//   units and leaves stale capacity bytes after them). The port appends at the
//   end, which is what the code evidently intends; sizes are identical.
module aro::text_literal_semantics;
import aro::compilation, aro::diagnostics, aro::source, aro::lang_opts, aro::type_store, aro::tokenizer;
import aro::value, aro::value_interner, aro::text_literal;
import std::collections::list;

// ---------------------------------------------------------------------------
// Zig `Parser.Diagnostic` constants used by char/string literals.

const DiagnosticTemplate DIAG_UNSUPPORTED_STR_CAT = {
	.fmt = "unsupported string literal concatenation",
	.kind = ERROR,
};

const DiagnosticTemplate DIAG_EMPTY_CHAR_LITERAL_ERROR = {
	.fmt = "empty character constant",
	.kind = ERROR,
};

const DiagnosticTemplate DIAG_UNTERMINATED_CHAR_LITERAL_ERROR = {
	.fmt = "missing terminating ' character",
	.kind = ERROR,
};

<* A parser-level literal diagnostic, reported by the caller at the given token. None takes arguments. *>
enum TextSemanticsDiag : char
{
	UNSUPPORTED_STR_CAT,
	EMPTY_CHAR_LITERAL_ERROR,
	UNTERMINATED_CHAR_LITERAL_ERROR,
}

<* The DiagnosticTemplate of a TextSemanticsDiag (its `fmt` is the final text). *>
fn DiagnosticTemplate TextSemanticsDiag.template(self)
{
	switch (self)
	{
		case UNSUPPORTED_STR_CAT: return DIAG_UNSUPPORTED_STR_CAT;
		case EMPTY_CHAR_LITERAL_ERROR: return DIAG_EMPTY_CHAR_LITERAL_ERROR;
		case UNTERMINATED_CHAR_LITERAL_ERROR: return DIAG_UNTERMINATED_CHAR_LITERAL_ERROR;
	}
}

// ---------------------------------------------------------------------------
// Character literals

<* The typed value of a character constant (Zig charLiteral's Result without the node). *>
struct CharLiteral
{
	<* CHAR for EMPTY_CHAR_LITERAL / UNTERMINATED_CHAR_LITERAL tokens (Zig node kind ascii). *>
	TextLiteralKind kind;
	QualType qt;
	Value val;
	<* EMPTY_CHAR_LITERAL / UNTERMINATED_CHAR_LITERAL tokens: report `diag` at the token. *>
	bool has_diag;
	TextSemanticsDiag diag;
}

<*
 Zig `Parser.charLiteral`. `id` and `token_bytes` are the whole token
 (prefix and quotes included). Not a char literal kind: EMPTY_CHAR_LITERAL ->
 diag EMPTY_CHAR_LITERAL_ERROR, UNTERMINATED_CHAR_LITERAL -> diag
 UNTERMINATED_CHAR_LITERAL_ERROR (other ids unreachable), with qt INT and
 val value::ZERO. Otherwise a TextLiteralParser over kind.content_slice with
 max_codepoint = kind.max_codepoint(comp) parses the constant; qt =
 kind.char_literal_type(comp); val = the signed (i32) or unsigned (u32)
 result interned as an integer.
 @return? compilation::FATAL_ERROR
*>
fn CharLiteral? char_literal(Compilation* comp, TokenId id, String token_bytes, Location loc, Location[] expansion_locs)
{
	// Zig classifies first; EMPTY / UNTERMINATED never classify as char
	// literals, so testing them up front is equivalent (and keeps this path
	// independent of the decoder).
	if (id == EMPTY_CHAR_LITERAL || id == UNTERMINATED_CHAR_LITERAL)
	{
		return {
			.kind = CHAR,
			.qt = type_store::INT,
			.val = value::ZERO,
			.has_diag = true,
			.diag = id == EMPTY_CHAR_LITERAL ? TextSemanticsDiag.EMPTY_CHAR_LITERAL_ERROR : TextSemanticsDiag.UNTERMINATED_CHAR_LITERAL_ERROR,
		};
	}
	TextLiteralKind? classified = text_literal::classify(id, CHAR_LITERAL);
	if (catch classified) unreachable("char_literal of a non-char-literal token");
	TextLiteralKind kind = classified;

	CharLiteralValue parsed = parse_char(comp, kind, token_bytes, loc, expansion_locs)!;
	Value val = parsed.is_signed ? value::int_i64((long)parsed.signed, comp) : value::int_u64((ulong)parsed.unsigned, comp);
	return { .kind = kind, .qt = kind.char_literal_type(comp), .val = val };
}

<* The `#if` value of a character constant. *>
struct PpCharValue
{
	bool is_signed;
	<* valid when !is_signed *>
	ulong unsigned;
	<* valid when is_signed *>
	long signed;
}

<*
 Zig Preprocessor/Parser.zig primaryExpr for CHAR_LITERAL* tokens (the id
 must classify as a char literal). Parse like char_literal; a signed result
 stays signed; otherwise unsigned if char_literal_type is unsigned or (kind
 CHAR and the char signedness is UNSIGNED), else signed with the u32 value.
 `id` must classify as CHAR_LITERAL (Zig `.?`).
 @return? compilation::FATAL_ERROR
*>
fn PpCharValue? pp_char_value(Compilation* comp, TokenId id, String token_bytes, Location loc, Location[] expansion_locs)
{
	TextLiteralKind? classified = text_literal::classify(id, CHAR_LITERAL);
	if (catch classified) unreachable("pp_char_value of a non-char-literal token");
	TextLiteralKind kind = classified;

	CharLiteralValue parsed = parse_char(comp, kind, token_bytes, loc, expansion_locs)!;
	if (parsed.is_signed) return { .is_signed = true, .signed = parsed.signed };
	uint u = parsed.unsigned;
	if (kind.char_literal_type(comp).signedness(comp) == UNSIGNED ||
		(kind == CHAR && type_store::char_signedness(comp) == UNSIGNED))
	{
		return { .unsigned = u };
	}
	return { .is_signed = true, .signed = (long)u };
}

// ---------------------------------------------------------------------------
// String literals

<* One string-literal token of an adjacent run. `bytes` is the whole token (prefix and quotes included). *>
struct StringPiece
{
	TokenId id;
	String bytes;
	Location loc;
	Location[] expansion_locs;
}

<* Result of `string_run`. *>
struct StringRun
{
	<* The concatenated kind (never UNTERMINATED on success). *>
	TextLiteralKind kind;
	<* Number of leading string-literal tokens in the run (Zig string_end - tok_i, > 0). *>
	sz len;
}

<*
 The first loop of Zig `Parser.stringLiteral`: starting from kind CHAR,
 concat the classify(STRING_LITERAL) kind of each leading id until one does
 not classify. On a concat failure set `*error_index` to that id's index and
 return CANNOT_CONCAT (the caller reports UNSUPPORTED_STR_CAT there, then
 skips every string-literal token). When the kind becomes UNTERMINATED set
 `*error_index` and return PARSING_FAILED (the preprocessor already reported
 it; the caller resumes after that token).
 @require ids.len > 0
 @return? text_literal::CANNOT_CONCAT, text_literal::PARSING_FAILED
*>
fn StringRun? string_run(TokenId[] ids, sz* error_index)
{
	TextLiteralKind kind = CHAR;
	sz end = 0;
	for (; end < ids.len; end++)
	{
		TextLiteralKind? next = text_literal::classify(ids[end], STRING_LITERAL);
		if (catch next) break;
		TextLiteralKind? joined = kind.concat(next);
		if (catch joined)
		{
			*error_index = end;
			return text_literal::CANNOT_CONCAT~;
		}
		kind = joined;
		if (kind == UNTERMINATED)
		{
			// Diagnostic issued in preprocessor.
			*error_index = end;
			return text_literal::PARSING_FAILED~;
		}
	}
	assert(end > 0, "string_run must start at a string literal");
	return { .kind = kind, .len = end };
}

<* The typed value of a (concatenated) string literal. *>
struct StringLiteral
{
	TextLiteralKind kind;
	CharUnitSize char_width;
	<* Array of kind.element_type with len = byte length / width (NUL included). *>
	QualType qt;
	<* Interned bytes in host (little-endian) code units, NUL terminator included. *>
	Value val;
}

<*
 The decoding part of Zig `Parser.stringLiteral` for a run of `pieces` whose
 concatenated kind is `kind` (from string_run). Each piece gets a
 TextLiteralParser over its own kind's content_slice with max_codepoint
 0x10FFFF and incorrect_encoding_is_error = pieces.len > 1. Items are
 appended in code units of `kind.char_unit_size`: VALUE truncated to the
 unit; CODEPOINT as UTF-8 / UTF-16LE (surrogate pair) / u32; UTF8_TEXT
 copied / transcoded to UTF-16LE / one u32 per codepoint;
 IMPROPERLY_ENCODED copied as raw bytes, or PARSING_FAILED when
 pieces.len > 1. Then a NUL code unit; interned with value::intern
 (key_bytes); qt = array of kind.element_type(comp).
 @require pieces.len > 0 && kind != UNTERMINATED
 @return? text_literal::PARSING_FAILED, compilation::FATAL_ERROR
*>
fn StringLiteral? string_literal(Compilation* comp, StringPiece[] pieces, TextLiteralKind kind)
{
	CharUnitSize char_width = kind.char_unit_size(comp);
	uint width = char_width.size;
	bool multi = pieces.len > 1;

	List{char} buf;
	buf.init(comp.gpa);
	defer buf.free();

	foreach (&piece : pieces)
	{
		TextLiteralKind? classified = text_literal::classify(piece.id, STRING_LITERAL);
		if (catch classified) unreachable("string_literal piece is not a string literal");
		TextLiteralKind this_kind = classified;
		String slice = this_kind.content_slice(piece.bytes);
		TextLiteralParser p = text_literal::text_parser(comp, slice, this_kind, 0x10FFFF, piece.loc, piece.expansion_locs);
		p.incorrect_encoding_is_error = multi;
		buf.reserve((slice.len + 1) * width); // +1 for null terminator

		TextLiteralItem item;
		while (p.next(&item)!)
		{
			switch (item.tag)
			{
				case VALUE:
					append_unit(&buf, item.value, width);
				case CODEPOINT:
					append_codepoint(&buf, item.value, width);
				case IMPROPERLY_ENCODED:
					if (multi) return text_literal::PARSING_FAILED~;
					buf.push_all(item.bytes);
				case UTF8_TEXT:
					if (width == 1)
					{
						buf.push_all(item.bytes);
						break;
					}
					String text = item.bytes;
					sz i = 0;
					while (i < text.len) append_codepoint(&buf, utf8_decode_valid(text, &i), width);
			}
		}
	}
	for (uint n = 0; n < width; n++) buf.push(0);

	char[] bytes = buf.array_view();
	Value val = value::intern(comp, value_interner::key_bytes(bytes));
	QualType array_qt = comp.type_store.put(type_store::type_array(kind.element_type(comp), FIXED, (ulong)bytes.len / width));
	return { .kind = kind, .char_width = char_width, .qt = array_qt, .val = val };
}

// ---------------------------------------------------------------------------
// Value.printString

<* Zig printString `style` parameter. *>
enum PrintStringStyle : char
{
	QUOTED,
	BARE,
}

<*
 Zig `Value.printString`: append the (NUL-terminated) bytes value `bytes` of
 array type `qt` to `w`. The code unit size is sizeof(qt's element) (1, 2 or
 4); the final NUL unit is dropped. Size 1: std.zig.stringEscape (\n \r \t
 \\ \" escaped, ' and 0x20..0x7E literal, anything else \xNN lowercase).
 Size 2: UTF-16LE decoded to UTF-8; a high surrogate followed by a low one is
 one codepoint, an unpaired high surrogate prints \x<hex>, a lone low
 surrogate prints U+FFFD (Zig "{u}"). Size 4: valid codepoints as UTF-8,
 anything else \x<hex> (lowercase, no padding). QUOTED wraps it in '"'.
 Integrator hookup in value.c3 Value.print, `case BYTES:`
   text_literal_semantics::print_string(key.bytes, qt, comp, w);
*>
fn void print_string(char[] bytes, QualType qt, Compilation* comp, DString w, PrintStringStyle style = QUOTED)
{
	if (style == QUOTED) w.append_char('"');

	ulong size = qt.child_type(comp).sizeof(comp);
	assert(size == 1 || size == 2 || size == 4, "string element size must be 1, 2 or 4");
	assert(bytes.len >= (sz)size);
	char[] without_null = bytes[:bytes.len - (sz)size];
	switch (size)
	{
		case 1:
			string_escape(without_null, w);
		case 2:
			sz i = 0;
			while (i < without_null.len)
			{
				uint first = load_u16(without_null, i);
				i += 2;
				bool is_surrogate = first >= 0xD800 && first <= 0xDBFF;
				if (is_surrogate && i < without_null.len)
				{
					uint second = load_u16(without_null, i);
					if (second >= 0xDC00 && second <= 0xDFFF)
					{
						i += 2;
						print_codepoint(w, 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00));
					}
					else
					{
						w.appendf("\\x%x", first);
					}
				}
				else if (is_surrogate)
				{
					w.appendf("\\x%x", first);
				}
				else
				{
					print_codepoint(w, first);
				}
			}
		case 4:
			for (sz n = 0; n + 4 <= without_null.len; n += 4)
			{
				uint item = (uint)without_null[n] | (uint)without_null[n + 1] << 8 |
					(uint)without_null[n + 2] << 16 | (uint)without_null[n + 3] << 24;
				if (item <= 0x10FFFF && !(item >= 0xD800 && item <= 0xDFFF))
				{
					print_codepoint(w, item);
				}
				else
				{
					w.appendf("\\x%x", item);
				}
			}
		default:
			unreachable();
	}

	if (style == QUOTED) w.append_char('"');
}

// ---------------------------------------------------------------------------
// Helpers

<* Shared head of charLiteral and the `#if` rule: a TextLiteralParser over the content, then `parse`. *>
fn CharLiteralValue? parse_char(Compilation* comp, TextLiteralKind kind, String token_bytes, Location loc, Location[] expansion_locs) @private
{
	TextLiteralParser p = text_literal::text_parser(comp, kind.content_slice(token_bytes), kind, kind.max_codepoint(comp), loc, expansion_locs);
	return p.parse();
}

<* Append `v` as one little-endian code unit of `width` bytes (Zig @intCast / asBytes). *>
fn void append_unit(List{char}* buf, uint v, uint width) @private
{
	for (uint n = 0; n < width; n++) buf.push((char)(v >> (8 * n)));
}

<* Append a valid codepoint as UTF-8 (width 1), UTF-16LE (width 2, surrogate pair above 0xFFFF) or one u32 (width 4). *>
fn void append_codepoint(List{char}* buf, uint c, uint width) @private
{
	switch (width)
	{
		case 1:
			char[4] enc;
			sz n = utf8_encode(c, &enc);
			buf.push_all(enc[:n]);
		case 2:
			if (c < 0x10000)
			{
				append_unit(buf, c, 2);
			}
			else
			{
				uint v = c - 0x10000;
				append_unit(buf, 0xD800 + (v >> 10), 2);
				append_unit(buf, 0xDC00 + (v & 0x3FF), 2);
			}
		default:
			append_unit(buf, c, 4);
	}
}

<* Zig std.unicode.utf8Encode for a codepoint <= 0x10FFFF (no surrogate check). *>
fn sz utf8_encode(uint c, char[4]* out) @private
{
	if (c < 0x80)
	{
		(*out)[0] = (char)c;
		return 1;
	}
	if (c < 0x800)
	{
		(*out)[0] = (char)(0xC0 | (c >> 6));
		(*out)[1] = (char)(0x80 | (c & 0x3F));
		return 2;
	}
	if (c < 0x10000)
	{
		(*out)[0] = (char)(0xE0 | (c >> 12));
		(*out)[1] = (char)(0x80 | ((c >> 6) & 0x3F));
		(*out)[2] = (char)(0x80 | (c & 0x3F));
		return 3;
	}
	(*out)[0] = (char)(0xF0 | (c >> 18));
	(*out)[1] = (char)(0x80 | ((c >> 12) & 0x3F));
	(*out)[2] = (char)(0x80 | ((c >> 6) & 0x3F));
	(*out)[3] = (char)(0x80 | (c & 0x3F));
	return 4;
}

<* Decode one codepoint of already validated UTF-8 at `*i` and advance (Zig Utf8View iterator). *>
fn uint utf8_decode_valid(String s, sz* i) @private
{
	char b = s[*i];
	if (b < 0x80)
	{
		*i += 1;
		return b;
	}
	sz n;
	uint c;
	if (b < 0xE0)
	{
		n = 2;
		c = b & 0x1F;
	}
	else if (b < 0xF0)
	{
		n = 3;
		c = b & 0x0F;
	}
	else
	{
		n = 4;
		c = b & 0x07;
	}
	assert(*i + n <= s.len, "utf8_text must be valid UTF-8");
	for (sz k = 1; k < n; k++) c = (c << 6) | (s[*i + k] & 0x3F);
	*i += n;
	return c;
}

fn uint load_u16(char[] b, sz i) @private => (uint)b[i] | (uint)b[i + 1] << 8;

<* Zig `{u}`: the codepoint as UTF-8, or U+FFFD for a surrogate / out-of-range value. *>
fn void print_codepoint(DString w, uint c) @private
{
	if (c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF)) c = 0xFFFD;
	char[4] enc;
	sz n = utf8_encode(c, &enc);
	w.append_bytes(enc[:n]);
}

<* Zig std.zig.stringEscape. *>
fn void string_escape(char[] bytes, DString w) @private
{
	foreach (b : bytes)
	{
		switch (b)
		{
			case '\n': w.append_string("\\n");
			case '\r': w.append_string("\\r");
			case '\t': w.append_string("\\t");
			case '\\': w.append_string("\\\\");
			case '"': w.append_string("\\\"");
			default:
				if (b >= 0x20 && b <= 0x7E)
				{
					w.append_char(b); // includes '\'', written unescaped like Zig
				}
				else
				{
					w.appendf("\\x%02x", b);
				}
		}
	}
}
