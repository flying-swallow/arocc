// Port of src/aro/Tokenizer/text_literal.zig: character/string literal
// classification (Kind), the escape / UCN / encoding decoder (Parser.next) and
// character-constant evaluation (Parser.parse). See number_literal.c3 for how
// the four literal modules fit together.
//
// Stage 0 (plan 11 contract) defined the types, diagnostic templates and
// signatures; 11.3 `text-decoding` implemented the bodies. `utf8_validate` /
// `utf8_decode_next` (Zig std.unicode Utf8View) are public for
// text_literal_semantics.
//
// Parser-free: nothing here needs a token list or AST. The preprocessor (plan
// 13: `#if` character constants, Preprocessor.unescapeUcn) builds a
// TextLiteralParser from a token's bytes, Location and expansion locations
// exactly like the C parser does.
//
// Deviations from Zig:
// - Zig `Item` (union(enum)) is a tagged struct `TextLiteralItem`; the
//   `utf8_text` Utf8View is the validated byte slice (`bytes`).
// - Zig `Parser.next() !?Item` is `bool? next(&self, TextLiteralItem* out)`:
//   false where Zig returns null (end of literal, or decoding stopped after an
//   error that was already reported).
// - Zig `Parser.Result` (union { unsigned: u32, signed: i32 }) is
//   `CharLiteralValue` with an `is_signed` flag.
// - Zig struct field defaults are set by `text_parser(...)`.
// - Zig `Compilation.wcharMax` and `Compilation.CharUnitSize` live here until
//   compilation.c3 grows them (API note for the integrator).
// - Parser.parse collects chars in a gpa List (Zig: 4-entry stack buffer
//   first). For a single CHAR > 0xFF with signed char (only after
//   char_too_large was reported) the value is truncated to 8 bits where Zig's
//   @intCast would trap.
// - An unknown escape of a non-ASCII byte formats as '\xNN' where Zig's
//   Ascii.init (@intCast to u7) would trap.
module aro::text_literal;
import aro::compilation, aro::diagnostics, aro::source, aro::lang_opts, aro::type_store, aro::tokenizer;
import std::io, std::collections::list;

<* Zig `error.CannotConcat` from Kind.concat. *>
excuse CANNOT_CONCAT;
<* Zig `Kind.classify` returning null: the token is not a literal of the requested context. *>
excuse NOT_A_TEXT_LITERAL;
<*
 Zig `error.ParsingFailed` for literals: the literal was rejected and its
 diagnostic (if any) was already reported. Shared by number_literal,
 number_value and text_literal_semantics.
*>
excuse PARSING_FAILED;

// ---------------------------------------------------------------------------
// Zig `text_literal.Parser.Diagnostic` constants (exact Zig text).

const DiagnosticTemplate DIAG_ILLEGAL_CHAR_ENCODING_ERROR = {
	.fmt = "illegal character encoding in character literal",
	.kind = ERROR,
};

const DiagnosticTemplate DIAG_ILLEGAL_CHAR_ENCODING_WARNING = {
	.fmt = "illegal character encoding in character literal",
	.kind = WARNING,
	.has_opt = true,
	.opt = Option.INVALID_SOURCE_ENCODING,
};

const DiagnosticTemplate DIAG_MISSING_HEX_ESCAPE = {
	.fmt = "\\{c} used with no following hex digits",
	.kind = ERROR,
};

const DiagnosticTemplate DIAG_ESCAPE_SEQUENCE_OVERFLOW = {
	.fmt = "escape sequence out of range",
	.kind = ERROR,
};

const DiagnosticTemplate DIAG_INCOMPLETE_UNIVERSAL_CHARACTER = {
	.fmt = "incomplete universal character name",
	.kind = ERROR,
};

const DiagnosticTemplate DIAG_INVALID_UNIVERSAL_CHARACTER = {
	.fmt = "invalid universal character",
	.kind = ERROR,
};

const DiagnosticTemplate DIAG_CHAR_TOO_LARGE = {
	.fmt = "character too large for enclosing character literal type",
	.kind = ERROR,
};

const DiagnosticTemplate DIAG_UCN_BASIC_CHAR_ERROR = {
	.fmt = "character '{c}' cannot be specified by a universal character name",
	.kind = ERROR,
};

const DiagnosticTemplate DIAG_UCN_BASIC_CHAR_WARNING = {
	.fmt = "specifying character '{c}' with a universal character name is incompatible with C standards before C23",
	.kind = OFF,
	.has_opt = true,
	.opt = Option.PRE_C23_COMPAT,
};

const DiagnosticTemplate DIAG_UCN_CONTROL_CHAR_ERROR = {
	.fmt = "universal character name refers to a control character",
	.kind = ERROR,
};

const DiagnosticTemplate DIAG_UCN_CONTROL_CHAR_WARNING = {
	.fmt = "universal character name referring to a control character is incompatible with C standards before C23",
	.kind = OFF,
	.has_opt = true,
	.opt = Option.PRE_C23_COMPAT,
};

const DiagnosticTemplate DIAG_C89_UCN_IN_LITERAL = {
	.fmt = "universal character names are only valid in C99 or later",
	.kind = WARNING,
	.has_opt = true,
	.opt = Option.UNICODE,
};

const DiagnosticTemplate DIAG_NON_STANDARD_ESCAPE_CHAR = {
	.fmt = "use of non-standard escape character '\\{c}'",
	.kind = OFF,
	.extension = true,
};

const DiagnosticTemplate DIAG_UNKNOWN_ESCAPE_SEQUENCE = {
	.fmt = "unknown escape sequence '\\{c}'",
	.kind = WARNING,
	.has_opt = true,
	.opt = Option.UNKNOWN_ESCAPE_SEQUENCE,
};

const DiagnosticTemplate DIAG_FOUR_CHAR_CHAR_LITERAL = {
	.fmt = "multi-character character constant",
	.kind = OFF,
	.has_opt = true,
	.opt = Option.FOUR_CHAR_CONSTANTS,
};

const DiagnosticTemplate DIAG_MULTICHAR_LITERAL_WARNING = {
	.fmt = "multi-character character constant",
	.kind = WARNING,
	.has_opt = true,
	.opt = Option.MULTICHAR,
};

const DiagnosticTemplate DIAG_INVALID_MULTICHAR_LITERAL = {
	.fmt = "{s} character literals may not contain multiple characters",
	.kind = ERROR,
};

const DiagnosticTemplate DIAG_CHAR_LIT_TOO_WIDE = {
	.fmt = "character constant too long for its type",
	.kind = WARNING,
};

const DiagnosticTemplate DIAG_U8_CHAR_LIT = {
	.fmt = "UTF-8 character literal is a C23 extension",
	.kind = WARNING,
	.has_opt = true,
	.opt = Option.C23_EXTENSIONS,
	.extension = true,
};

// ---------------------------------------------------------------------------
// Shared diagnostic plumbing (implemented in stage 0; used by number_literal too)

<* Zig `text_literal.Ascii`: a 7-bit character formatted for a "{c}" template. *>
struct Ascii
{
	char val;
}

<*
 Zig `Ascii.init` (@intCast to u7).
 @require val < 0x80 : "Ascii holds a 7-bit value"
*>
fn Ascii ascii(uint val) => { .val = (char)val };

<*
 Zig `Ascii.format`: write `fmt` up to "{c}", then the character if
 std.ascii.isPrint (0x20..0x7E), otherwise "x" and two lowercase hex digits.
 Returns the index just past the template.
*>
fn sz? Ascii.format(self, OutStream w, String fmt)
{
	sz i = diagnostics::template_index(w, fmt, "{c}")!;
	if (self.val >= 0x20 && self.val <= 0x7E)
	{
		io::write_all(w, (char[]){ self.val })!;
	}
	else
	{
		io::fprintf(w, "x%02x", (uint)self.val)!;
	}
	return i;
}

enum LiteralArgKind : char
{
	NONE,
	STRING,
	ASCII,
}

<*
 The single format argument of a literal diagnostic: none, a "{s}" string or
 a "{c}" Ascii. (Every literal diagnostic takes at most one argument.)
*>
struct LiteralArg
{
	LiteralArgKind kind;
	String str;
	Ascii ascii;
}

fn LiteralArg arg_none() => { .kind = NONE };
fn LiteralArg arg_str(String s) => { .kind = STRING, .str = s };
fn LiteralArg arg_ascii(Ascii c) => { .kind = ASCII, .ascii = c };

<* Zig `Diagnostics.formatArgs` for one LiteralArg. *>
fn void? format_literal_arg(OutStream w, String fmt, LiteralArg arg)
{
	sz i = 0;
	switch (arg.kind)
	{
		case NONE: break;
		case STRING: i = diagnostics::format_string(w, fmt, arg.str)!;
		case ASCII: i = arg.ascii.format(w, fmt)!;
	}
	if (fmt.len > i) io::write_all(w, fmt[i..])!;
}

<*
 The body shared by Zig `number_literal.Parser.err` and
 `text_literal.Parser.warn`: return early when the template's effective kind
 (checked without a location, like Zig) is OFF; otherwise format the text and
 `add_with_location(comp, msg @ loc.expand(comp), expansion_locs, true)`.
 @return? compilation::FATAL_ERROR
*>
fn void? emit_literal_diagnostic(Compilation* comp, DiagnosticTemplate d, LiteralArg arg, Location loc, Location[] expansion_locs)
{
	Message probe = d.message(d.fmt);
	if (comp.diagnostics.effective_kind(&probe) == OFF) return;

	DString text;
	text.init(comp.gpa);
	defer text.free();
	if (catch format_literal_arg(&text, d.fmt, arg)) unreachable("formatting into a DString failed");
	comp.diagnostics.add_with_location(comp, d.message_at(text.str_view(), loc.expand(comp)), expansion_locs, true)!;
}

// ---------------------------------------------------------------------------
// Compilation helpers (Zig Compilation.wcharMax / CharUnitSize)

<* Zig `Compilation.CharUnitSize`: the byte width of one string-literal code unit. *>
enum CharUnitSize : char (uint size)
{
	ONE { 1 },
	TWO { 2 },
	FOUR { 4 },
}

<*
 Zig `Compilation.wcharMax`: the largest value of the target's wchar_t
 (maxInt of u8/i8, u16/i16 or u32/i32 by its bit size and signedness).
*>
fn uint wchar_max(Compilation* comp)
{
	QualType wchar = comp.type_store.wchar;
	bool is_unsigned = wchar.signedness(comp) == UNSIGNED;
	switch (wchar.bit_sizeof(comp))
	{
		case 8: return is_unsigned ? 0xFF : 0x7F;
		case 16: return is_unsigned ? 0xFFFF : 0x7FFF;
		case 32: return is_unsigned ? 0xFFFF_FFFF : 0x7FFF_FFFF;
		default: unreachable("unexpected wchar_t size");
	}
}

// ---------------------------------------------------------------------------
// Item / Kind

enum TextLiteralItemTag : char
{
	<* decoded hex or character escape *>
	VALUE,
	<* validated unicode codepoint (UCN) *>
	CODEPOINT,
	<* Char literal in the source text is not utf8 encoded *>
	IMPROPERLY_ENCODED,
	<* 1 or more unescaped bytes, validated UTF-8 *>
	UTF8_TEXT,
}

<*
 Zig `text_literal.Item`. `value` holds VALUE (u32) and CODEPOINT (u21);
 `bytes` holds IMPROPERLY_ENCODED and UTF8_TEXT and is a slice of the
 parser's `literal`.
*>
struct TextLiteralItem
{
	TextLiteralItemTag tag;
	uint value;
	String bytes;
}

<* Zig `Kind.classify` context. *>
enum ClassifyContext : char
{
	STRING_LITERAL,
	CHAR_LITERAL,
}

<* Zig `text_literal.Kind`. *>
enum TextLiteralKind : char
{
	CHAR,
	WIDE,
	UTF_8,
	UTF_16,
	UTF_32,
	<* Error kind that halts parsing *>
	UNTERMINATED,
}

<*
 Zig `Kind.classify`.
 STRING_LITERAL: STRING_LITERAL -> CHAR, STRING_LITERAL_UTF_8 -> UTF_8,
 STRING_LITERAL_WIDE -> WIDE, STRING_LITERAL_UTF_16 -> UTF_16,
 STRING_LITERAL_UTF_32 -> UTF_32, UNTERMINATED_STRING_LITERAL -> UNTERMINATED.
 CHAR_LITERAL: CHAR_LITERAL -> CHAR, CHAR_LITERAL_UTF_8 -> UTF_8,
 CHAR_LITERAL_WIDE -> WIDE, CHAR_LITERAL_UTF_16 -> UTF_16,
 CHAR_LITERAL_UTF_32 -> UTF_32. Anything else: NOT_A_TEXT_LITERAL (Zig null).
 @return? NOT_A_TEXT_LITERAL
*>
fn TextLiteralKind? classify(TokenId id, ClassifyContext context)
{
	switch (context)
	{
		case STRING_LITERAL:
			switch (id)
			{
				case STRING_LITERAL: return CHAR;
				case STRING_LITERAL_UTF_8: return UTF_8;
				case STRING_LITERAL_WIDE: return WIDE;
				case STRING_LITERAL_UTF_16: return UTF_16;
				case STRING_LITERAL_UTF_32: return UTF_32;
				case UNTERMINATED_STRING_LITERAL: return UNTERMINATED;
				default: return NOT_A_TEXT_LITERAL~;
			}
		case CHAR_LITERAL:
			switch (id)
			{
				case CHAR_LITERAL: return CHAR;
				case CHAR_LITERAL_UTF_8: return UTF_8;
				case CHAR_LITERAL_WIDE: return WIDE;
				case CHAR_LITERAL_UTF_16: return UTF_16;
				case CHAR_LITERAL_UTF_32: return UTF_32;
				default: return NOT_A_TEXT_LITERAL~;
			}
	}
}

<*
 Zig `Kind.concat`; only for string literals. The result kind of two adjacent
 string literals: UNTERMINATED if either is; self if equal; CHAR + X -> X;
 X + CHAR -> X; otherwise CANNOT_CONCAT.
 @return? CANNOT_CONCAT
*>
fn TextLiteralKind? TextLiteralKind.concat(self, TextLiteralKind other)
{
	if (self == UNTERMINATED || other == UNTERMINATED) return UNTERMINATED;
	if (self == other) return self; // can always concat with own kind
	if (self == CHAR) return other; // char + X -> X
	if (other == CHAR) return self; // X + char -> X
	return CANNOT_CONCAT~;
}

<*
 Zig `Kind.maxCodepoint`: largest unicode codepoint representable by this kind
 via literal text or UCNs (may be smaller than max_int): CHAR, UTF_8 -> 0x7F;
 WIDE -> min(0x10FFFF, wchar_max); UTF_16 -> 0xFFFF; UTF_32 -> 0x10FFFF.
 @require self != UNTERMINATED
*>
fn uint TextLiteralKind.max_codepoint(self, Compilation* comp)
{
	switch (self)
	{
		case CHAR:
		case UTF_8:
			return 0x7F;
		case WIDE:
			uint m = wchar_max(comp);
			return m < 0x10FFFF ? m : 0x10FFFF;
		case UTF_16: return 0xFFFF;
		case UTF_32: return 0x10FFFF;
		case UNTERMINATED: unreachable("max_codepoint of an unterminated literal");
	}
}

<*
 Zig `Kind.maxInt`: largest integer representable: CHAR, UTF_8 -> 0xFF;
 WIDE -> wchar_max; UTF_16 -> 0xFFFF; UTF_32 -> 0xFFFF_FFFF.
 @require self != UNTERMINATED
*>
fn uint TextLiteralKind.max_int(self, Compilation* comp)
{
	switch (self)
	{
		case CHAR:
		case UTF_8:
			return 0xFF;
		case WIDE: return wchar_max(comp);
		case UTF_16: return 0xFFFF;
		case UTF_32: return 0xFFFF_FFFF;
		case UNTERMINATED: unreachable("max_int of an unterminated literal");
	}
}

<*
 Zig `Kind.charLiteralType`: CHAR -> INT; WIDE -> type_store.wchar;
 UTF_8 -> UCHAR; UTF_16 -> type_store.uint_least16_t;
 UTF_32 -> type_store.uint_least32_t.
 @require self != UNTERMINATED
*>
fn QualType TextLiteralKind.char_literal_type(self, Compilation* comp)
{
	switch (self)
	{
		case CHAR: return type_store::INT;
		case WIDE: return comp.type_store.wchar;
		case UTF_8: return type_store::UCHAR;
		case UTF_16: return comp.type_store.uint_least16_t;
		case UTF_32: return comp.type_store.uint_least32_t;
		case UNTERMINATED: unreachable("char_literal_type of an unterminated literal");
	}
}

<*
 Zig `Kind.contentSlice`: the literal without its prefix and quotes:
 CHAR [1..len-1], WIDE/UTF_16/UTF_32 [2..len-1], UTF_8 [3..len-1].
 @require self != UNTERMINATED
*>
fn String TextLiteralKind.content_slice(self, String delimited)
{
	sz end = delimited.len - 1; // remove trailing quote
	sz start;
	switch (self)
	{
		case CHAR: start = 1;
		case WIDE:
		case UTF_16:
		case UTF_32:
			start = 2;
		case UTF_8: start = 3;
		case UNTERMINATED: unreachable("content_slice of an unterminated literal");
	}
	return delimited[start : end - start];
}

<*
 Zig `Kind.charUnitSize`: CHAR, UTF_8 -> ONE; UTF_16 -> TWO; UTF_32 -> FOUR;
 WIDE -> by sizeof(wchar_t) (2 -> TWO, 4 -> FOUR, else unreachable).
 @require self != UNTERMINATED
*>
fn CharUnitSize TextLiteralKind.char_unit_size(self, Compilation* comp)
{
	switch (self)
	{
		case CHAR:
		case UTF_8:
			return ONE;
		case UTF_16: return TWO;
		case UTF_32: return FOUR;
		case WIDE:
			switch (comp.type_store.wchar.sizeof(comp))
			{
				case 2: return TWO;
				case 4: return FOUR;
				default: unreachable("unexpected sizeof(wchar_t)");
			}
		case UNTERMINATED: unreachable("char_unit_size of an unterminated literal");
	}
}

<*
 Zig `Kind.internalStorageAlignment`: host alignment of the code unit type
 (u8/u16/u32) of `char_unit_size`, i.e. 1, 2 or 4.
*>
fn usz TextLiteralKind.internal_storage_alignment(self, Compilation* comp)
{
	return self.char_unit_size(comp).size;
}

<*
 Zig `Kind.elementType`: CHAR -> CHAR; UTF_8 -> UCHAR if
 langopts.has_char8_t() else CHAR; otherwise char_literal_type.
 @require self != UNTERMINATED
*>
fn QualType TextLiteralKind.element_type(self, Compilation* comp)
{
	switch (self)
	{
		case CHAR: return type_store::CHAR;
		case UTF_8: return comp.langopts.has_char8_t() ? type_store::UCHAR : type_store::CHAR;
		case WIDE:
		case UTF_16:
		case UTF_32:
			return self.char_literal_type(comp);
		case UNTERMINATED: unreachable("element_type of an unterminated literal");
	}
}

// ---------------------------------------------------------------------------
// Parser (the decoder)

<* Zig `text_literal.Parser.Result`. *>
struct CharLiteralValue
{
	bool is_signed;
	<* valid when !is_signed *>
	uint unsigned;
	<* valid when is_signed *>
	int signed;
}

<*
 Zig `text_literal.Parser`: decodes the content of one character/string
 literal (or an extended identifier containing UCNs) item by item. Needs only
 a Compilation (langopts, target char signedness / wchar, diagnostics).
 Build with `text_parser`.
*>
struct TextLiteralParser
{
	Compilation* comp;
	<* content bytes (Kind.content_slice of the token, or an identifier) *>
	String literal;
	<* read position in `literal` (Zig `i`) *>
	sz i;
	TextLiteralKind kind;
	uint max_codepoint;
	Location loc;
	<* Offset added to `loc.byte_offset` when emitting an error; reset after every diagnostic. *>
	uint offset;
	Location[] expansion_locs;
	<* We only want to issue a max of 1 error per char literal *>
	bool errored;
	<* Makes incorrect encoding always an error. Used when concatenating string literals. *>
	bool incorrect_encoding_is_error;
	<*
	 If this is false, do not issue any diagnostics for incorrect character
	 encoding. Incorrect encoding is allowed if we are unescaping an identifier
	 in the preprocessor.
	*>
	bool diagnose_incorrect_encoding;
}

<*
 A TextLiteralParser with Zig's field defaults: i = 0, offset = 0,
 errored = false, incorrect_encoding_is_error = false,
 diagnose_incorrect_encoding = true.
*>
fn TextLiteralParser text_parser(Compilation* comp, String literal, TextLiteralKind kind, uint max_codepoint, Location loc, Location[] expansion_locs)
{
	return {
		.comp = comp,
		.literal = literal,
		.kind = kind,
		.max_codepoint = max_codepoint,
		.loc = loc,
		.expansion_locs = expansion_locs,
		.diagnose_incorrect_encoding = true,
	};
}

<*
 Zig `Parser.parse`: evaluate a character constant.
 - UTF_8 kind before C23: warn DIAG_U8_CHAR_LIT.
 - Fast path: a single ASCII byte is the value.
 - Otherwise collect u32 chars from `next`: VALUE/CODEPOINT append the value,
   IMPROPERLY_ENCODED appends each byte, UTF8_TEXT appends each codepoint and
   errs DIAG_CHAR_TOO_LARGE if the largest exceeds max_codepoint.
 - More than one char: CHAR kind with exactly 4 -> warn
   DIAG_FOUR_CHAR_CHAR_LITERAL; other CHAR -> warn
   DIAG_MULTICHAR_LITERAL_WARNING; WIDE -> err DIAG_INVALID_MULTICHAR_LITERAL
   with "wide"; UTF_8/16/32 -> same with "Unicode".
 - CHAR multichar: val = (val << 8) + (u8)item for each item, tracking u32 shl
   overflow -> err DIAG_CHAR_LIT_TOO_WIDE. Otherwise val = the last char (0 if none).
 - CHAR, not multichar, val > 0x7F and char_signedness == SIGNED:
   { is_signed, (i8)(u8)val }. Else { unsigned = val }.
 @return? compilation::FATAL_ERROR
*>
fn CharLiteralValue? TextLiteralParser.parse(&self)
{
	if (self.kind == UTF_8 && !self.comp.langopts.standard.at_least(C23))
	{
		self.warn(DIAG_U8_CHAR_LIT)!;
	}
	uint val = 0;

	bool is_multichar = false;
	if (self.literal.len == 1 && self.literal[0] < 0x80)
	{
		// fast path: single unescaped ASCII char
		val = self.literal[0];
	}
	else
	{
		List{uint} chars;
		chars.init(self.comp.gpa);
		defer chars.free();

		TextLiteralItem item;
		while (self.next(&item)!)
		{
			switch (item.tag)
			{
				case VALUE:
				case CODEPOINT:
					chars.push(item.value);
				case IMPROPERLY_ENCODED:
					foreach (b : item.bytes) chars.push(b);
				case UTF8_TEXT:
					uint max_codepoint_seen = 0;
					sz j = 0;
					while (j < item.bytes.len)
					{
						uint c = utf8_decode_next(item.bytes, &j);
						if (c > max_codepoint_seen) max_codepoint_seen = c;
						chars.push(c);
					}
					if (max_codepoint_seen > self.max_codepoint) self.err(DIAG_CHAR_TOO_LARGE)!;
			}
		}

		is_multichar = chars.len() > 1;
		if (is_multichar)
		{
			if (self.kind == CHAR && chars.len() == 4)
			{
				self.warn(DIAG_FOUR_CHAR_CHAR_LITERAL)!;
			}
			else if (self.kind == CHAR)
			{
				self.warn(DIAG_MULTICHAR_LITERAL_WARNING)!;
			}
			else
			{
				String kind_name = self.kind == WIDE ? "wide" : "Unicode";
				self.err(DIAG_INVALID_MULTICHAR_LITERAL, arg_str(kind_name))!;
			}
		}

		bool multichar_overflow = false;
		if (self.kind == CHAR && is_multichar)
		{
			foreach (c : chars)
			{
				if (val >> 24 != 0) multichar_overflow = true; // @shlWithOverflow(val, 8)
				val = (val << 8) + (c & 0xFF);
			}
		}
		else if (chars.len() > 0)
		{
			val = chars[chars.len() - 1];
		}

		if (multichar_overflow) self.err(DIAG_CHAR_LIT_TOO_WIDE)!;
	}

	// C99 6.4.4.4.10
	// > If an integer character constant contains a single character or escape sequence,
	// > its value is the one that results when an object with type char whose value is
	// > that of the single character or escape sequence is converted to type int.
	// This conversion only matters if `char` is signed and has a high-order bit of `1`
	if (self.kind == CHAR && !is_multichar && val > 0x7F && type_store::char_signedness(self.comp) == SIGNED)
	{
		// Zig @intCast(u8) here only fails after char_too_large was reported; truncate instead.
		return { .is_signed = true, .signed = (int)(ichar)(char)val };
	}
	return { .unsigned = val };
}

<*
 Zig `Parser.next`: decode the next item into `out`; false at the end (or
 when decoding stops after a reported error, Zig null).
 - Unescaped run up to the next '\\': UTF8_TEXT if valid UTF-8. Invalid:
   !diagnose_incorrect_encoding -> IMPROPERLY_ENCODED silently;
   incorrect_encoding_is_error -> warn DIAG_ILLEGAL_CHAR_ENCODING_ERROR and
   IMPROPERLY_ENCODED; kind != CHAR -> err DIAG_ILLEGAL_CHAR_ENCODING_ERROR and
   false; else warn DIAG_ILLEGAL_CHAR_ENCODING_WARNING and IMPROPERLY_ENCODED.
 - "\\u" / "\\U": parseUnicodeEscape (missing hex -> DIAG_MISSING_HEX_ESCAPE;
   4/8 digits, shl overflow -> DIAG_ESCAPE_SEQUENCE_OVERFLOW with
   offset += start + prefix_len; short -> DIAG_INCOMPLETE_UNIVERSAL_CHARACTER;
   > u21 max or not a valid codepoint (surrogate) ->
   DIAG_INVALID_UNIVERSAL_CHARACTER with the same offset; > max_codepoint ->
   DIAG_CHAR_TOO_LARGE; < 0xA0 except '$' '@' '`': before C23 err
   DIAG_UCN_BASIC_CHAR_ERROR (0x20..0x7F, Ascii arg) or
   DIAG_UCN_CONTROL_CHAR_ERROR; before C99 also warn DIAG_C89_UCN_IN_LITERAL;
   result CODEPOINT). Note: Zig's *_WARNING branches are unreachable because
   they repeat the !C23 test; keep that.
 - Other escapes: parseEscapedChar (\' \" \\ ? n r t a b f v; \e \E -> 0x1B and
   \( \{ \[ \% -> the char, both warn DIAG_NON_STANDARD_ESCAPE_CHAR with
   offset += i; \x hex (any length) / up to 3 octal digits: shl overflow or
   > kind.max_int -> err DIAG_ESCAPE_SEQUENCE_OVERFLOW (offset += start +
   prefix_len), value 0; \x with no digits -> DIAG_MISSING_HEX_ESCAPE 'x';
   unknown -> warn DIAG_UNKNOWN_ESCAPE_SEQUENCE, value = the char).
 @return? compilation::FATAL_ERROR
*>
fn bool? TextLiteralParser.next(&self, TextLiteralItem* out)
{
	if (self.i >= self.literal.len) return false;

	sz start = self.i;
	if (self.literal[start] != '\\')
	{
		sz end = start + 1;
		while (end < self.literal.len && self.literal[end] != '\\') end++;
		self.i = end;
		String unescaped_slice = self.literal[start : end - start];

		if (utf8_validate(unescaped_slice))
		{
			*out = { .tag = UTF8_TEXT, .bytes = unescaped_slice };
			return true;
		}
		*out = { .tag = IMPROPERLY_ENCODED, .bytes = unescaped_slice };
		if (!self.diagnose_incorrect_encoding) return true;
		if (self.incorrect_encoding_is_error)
		{
			self.warn(DIAG_ILLEGAL_CHAR_ENCODING_ERROR)!;
			return true;
		}
		if (self.kind != CHAR)
		{
			self.err(DIAG_ILLEGAL_CHAR_ENCODING_ERROR)!;
			return false;
		}
		self.warn(DIAG_ILLEGAL_CHAR_ENCODING_WARNING)!;
		return true;
	}
	switch (self.literal[start + 1])
	{
		case 'u':
		case 'U':
			return parse_unicode_escape(self, out);
		default:
			*out = parse_escaped_char(self)!;
			return true;
	}
}

<*
 Zig `Parser.err`: like `warn`, but at most one per literal: if already
 `errored` do nothing, otherwise warn and set `errored`. Resets `offset`.
 @return? compilation::FATAL_ERROR
*>
fn void? TextLiteralParser.err(&self, DiagnosticTemplate d, LiteralArg arg = { .kind = NONE })
{
	defer self.offset = 0;
	if (self.errored) return;
	defer self.errored = true;
	self.warn(d, arg)!;
}

<*
 Zig `Parser.warn`: always resets `offset`; skipped when `errored`; otherwise
 emit_literal_diagnostic at `loc` with byte_offset += offset.
 @return? compilation::FATAL_ERROR
*>
fn void? TextLiteralParser.warn(&self, DiagnosticTemplate d, LiteralArg arg = { .kind = NONE })
{
	defer self.offset = 0;
	if (self.errored) return;
	Location offset_location = self.loc;
	offset_location.byte_offset += self.offset;
	emit_literal_diagnostic(self.comp, d, arg, offset_location, self.expansion_locs)!;
}

<*
 Zig `Parser.prefixLen`: CHAR 0; UTF_8 2; WIDE/UTF_16/UTF_32 1.
 @require self.kind != UNTERMINATED
*>
fn uint TextLiteralParser.prefix_len(&self)
{
	switch (self.kind)
	{
		case CHAR: return 0;
		case UTF_8: return 2;
		case WIDE:
		case UTF_16:
		case UTF_32:
			return 1;
		case UNTERMINATED: unreachable("prefix_len of an unterminated literal");
	}
}

// ---------------------------------------------------------------------------
// Escape decoding (Zig Parser.parseUnicodeEscape / parseEscapedChar /
// parseNumberEscape)

<* Zig `std.fmt.charToDigit(c, base)` for bases 8 and 16; -1 when `c` is not a digit. *>
fn int escape_digit(char c, uint base) @private
{
	int d;
	switch (c)
	{
		case '0'..'9': d = c - '0';
		case 'a'..'f': d = c - 'a' + 10;
		case 'A'..'F': d = c - 'A' + 10;
		default: return -1;
	}
	return d < (int)base ? d : -1;
}

<*
 Zig `Parser.parseUnicodeEscape`: `p.literal[p.i..]` starts with "\\u" or "\\U".
 @return? compilation::FATAL_ERROR
*>
fn bool? parse_unicode_escape(TextLiteralParser* p, TextLiteralItem* out) @private
{
	sz start = p.i;
	assert(p.literal[p.i] == '\\');
	char kind = p.literal[p.i + 1];
	assert(kind == 'u' || kind == 'U');

	p.i += 2;
	if (p.i >= p.literal.len || escape_digit(p.literal[p.i], 16) < 0)
	{
		p.err(DIAG_MISSING_HEX_ESCAPE, arg_ascii(ascii(kind)))!;
		return false;
	}
	sz expected_len = kind == 'u' ? 4 : 8;
	bool overflowed = false;
	sz count = 0;
	uint val = 0;

	for (sz k = 0; p.i + k < p.literal.len; k++)
	{
		if (k == expected_len) break;
		int digit = escape_digit(p.literal[p.i + k], 16);
		if (digit < 0) break;
		if (val >> 28 != 0) overflowed = true; // @shlWithOverflow(val, 4)
		val = (val << 4) | (uint)digit;
		count++;
	}
	p.i += expected_len;

	if (overflowed)
	{
		p.offset += (uint)(start + p.prefix_len());
		p.err(DIAG_ESCAPE_SEQUENCE_OVERFLOW)!;
		return false;
	}

	if (count != expected_len)
	{
		p.err(DIAG_INCOMPLETE_UNIVERSAL_CHARACTER)!;
		return false;
	}

	// val > maxInt(u21) or !std.unicode.utf8ValidCodepoint(val)
	if (val > 0x10FFFF || (val >= 0xD800 && val <= 0xDFFF))
	{
		p.offset += (uint)(start + p.prefix_len());
		p.err(DIAG_INVALID_UNIVERSAL_CHARACTER)!;
		return false;
	}

	if (val > p.max_codepoint)
	{
		p.err(DIAG_CHAR_TOO_LARGE)!;
		return false;
	}

	if (val < 0xA0 && (val != '$' && val != '@' && val != '`'))
	{
		bool is_error = !p.comp.langopts.standard.at_least(C23);
		if (val >= 0x20 && val <= 0x7F)
		{
			if (is_error)
			{
				p.err(DIAG_UCN_BASIC_CHAR_ERROR, arg_ascii(ascii(val)))!;
			}
			else if (!p.comp.langopts.standard.at_least(C23))
			{
				// Unreachable in Zig too (same condition as is_error); kept verbatim.
				p.warn(DIAG_UCN_BASIC_CHAR_WARNING, arg_ascii(ascii(val)))!;
			}
		}
		else
		{
			if (is_error)
			{
				p.err(DIAG_UCN_CONTROL_CHAR_ERROR)!;
			}
			else if (!p.comp.langopts.standard.at_least(C23))
			{
				p.warn(DIAG_UCN_CONTROL_CHAR_WARNING)!;
			}
		}
	}

	if (!p.comp.langopts.standard.at_least(C99)) p.warn(DIAG_C89_UCN_IN_LITERAL)!;
	*out = { .tag = CODEPOINT, .value = val };
	return true;
}

fn TextLiteralItem value_item(uint v) @private => { .tag = VALUE, .value = v };

<*
 Zig `Parser.parseEscapedChar`: `p.literal[p.i]` is the backslash.
 @return? compilation::FATAL_ERROR
*>
fn TextLiteralItem? parse_escaped_char(TextLiteralParser* p) @private
{
	p.i += 1;
	char c = p.literal[p.i];
	defer if (c != 'x' && (c < '0' || c > '7')) p.i += 1;

	switch (c)
	{
		case '\n':
		case '\r':
			unreachable("removed by line splicing");
		case '\'':
		case '"':
		case '\\':
		case '?':
			return value_item(c);
		case 'n': return value_item('\n');
		case 'r': return value_item('\r');
		case 't': return value_item('\t');
		case 'a': return value_item(0x07);
		case 'b': return value_item(0x08);
		case 'e':
		case 'E':
			p.offset += (uint)p.i;
			p.warn(DIAG_NON_STANDARD_ESCAPE_CHAR, arg_ascii(ascii(c)))!;
			return value_item(0x1B);
		case '(':
		case '{':
		case '[':
		case '%':
			p.offset += (uint)p.i;
			p.warn(DIAG_NON_STANDARD_ESCAPE_CHAR, arg_ascii(ascii(c)))!;
			return value_item(c);
		case 'f': return value_item(0x0C);
		case 'v': return value_item(0x0B);
		case 'x': return value_item(parse_number_escape(p, 16)!);
		case '0'..'7': return value_item(parse_number_escape(p, 8)!);
		case 'u':
		case 'U':
			unreachable("handled by parse_unicode_escape");
		default:
			p.offset += (uint)p.i;
			// Zig's Ascii.init (@intCast to u7) traps on a non-ASCII byte; format it as "x.." instead.
			Ascii a = { .val = c };
			p.warn(DIAG_UNKNOWN_ESCAPE_SEQUENCE, arg_ascii(a))!;
			return value_item(c);
	}
}

<*
 Zig `Parser.parseNumberEscape`: octal (`p.literal[p.i]` is the first digit,
 at most 3 digits) or hex (`p.literal[p.i]` is the 'x', any number of digits).
 @require base == 8 || base == 16
 @return? compilation::FATAL_ERROR
*>
fn uint? parse_number_escape(TextLiteralParser* p, uint base) @private
{
	uint val = 0;
	sz count = 0;
	bool overflowed = false;
	sz start = p.i;
	defer p.i += count;

	String slice;
	if (base == 8)
	{
		sz end = p.literal.len < p.i + 3 ? p.literal.len : p.i + 3; // max 3 chars
		slice = p.literal[p.i : end - p.i];
	}
	else
	{
		p.i += 1; // skip over 'x'; could have an arbitrary number of chars
		slice = p.literal[p.i : p.literal.len - p.i];
	}
	uint shift = base == 8 ? 3 : 4;
	foreach (c : slice)
	{
		int digit = escape_digit(c, base);
		if (digit < 0) break;
		if (val >> (32 - shift) != 0) overflowed = true; // @shlWithOverflow
		val = (val << shift) + (uint)digit;
		count++;
	}
	if (overflowed || val > p.kind.max_int(p.comp))
	{
		p.offset += (uint)(start + p.prefix_len());
		p.err(DIAG_ESCAPE_SEQUENCE_OVERFLOW)!;
		return 0;
	}
	if (count == 0)
	{
		assert(base == 16);
		p.err(DIAG_MISSING_HEX_ESCAPE, arg_ascii(ascii('x')))!;
	}
	return val;
}

// ---------------------------------------------------------------------------
// UTF-8 (Zig std.unicode.Utf8View.init / Utf8Iterator.nextCodepoint)

<*
 Zig `std.unicode.utf8ValidateSlice` (what `Utf8View.init` checks): every
 sequence complete, no stray continuation bytes, no overlong encodings, no
 surrogate halves (U+D800..U+DFFF) and nothing above U+10FFFF.
*>
fn bool utf8_validate(String s)
{
	sz i = 0;
	while (i < s.len)
	{
		char b = s[i];
		if (b < 0x80)
		{
			i++;
			continue;
		}
		sz n;
		uint cp;
		uint min;
		switch
		{
			case b >= 0xC0 && b <= 0xDF: n = 2; cp = b & 0x1F; min = 0x80;
			case b >= 0xE0 && b <= 0xEF: n = 3; cp = b & 0x0F; min = 0x800;
			case b >= 0xF0 && b <= 0xF7: n = 4; cp = b & 0x07; min = 0x10000;
			default: return false;
		}
		if (i + n > s.len) return false;
		for (sz k = 1; k < n; k++)
		{
			char cb = s[i + k];
			if (cb & 0xC0 != 0x80) return false;
			cp = (cp << 6) | (cb & 0x3F);
		}
		if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return false;
		i += n;
	}
	return true;
}

<*
 Zig `Utf8Iterator.nextCodepoint` on bytes already accepted by `utf8_validate`:
 decode the codepoint at `*i` and advance `*i` past it.
 @require *i < s.len
*>
fn uint utf8_decode_next(String s, sz* i)
{
	char b = s[*i];
	sz n;
	uint cp;
	switch
	{
		case b < 0x80: n = 1; cp = b;
		case b < 0xE0: n = 2; cp = b & 0x1F;
		case b < 0xF0: n = 3; cp = b & 0x0F;
		default: n = 4; cp = b & 0x07;
	}
	for (sz k = 1; k < n; k++) cp = (cp << 6) | (s[*i + k] & 0x3F);
	*i += n;
	return cp;
}
