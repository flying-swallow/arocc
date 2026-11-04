// Port of src/aro/Tokenizer/text_literal.zig: character/string literal
// classification (Kind), the escape / UCN / encoding decoder (Parser.next) and
// character-constant evaluation (Parser.parse). See number_literal.c3 for how
// the four literal modules fit together.
//
// Stage 0 (plan 11 contract): types, diagnostic templates and signatures.
// The shared diagnostic plumbing (Ascii, LiteralArg, emit_literal_diagnostic),
// `wchar_max`, `CharUnitSize` and the `text_parser` constructor are
// implemented; everything else is `unreachable("stage 0 stub")` until
// 11.3 `text-decoding` lands.
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
module aro::text_literal;
import aro::compilation, aro::diagnostics, aro::source, aro::lang_opts, aro::type_store, aro::tokenizer;
import std::io;

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
	unreachable("stage 0 stub");
}

<*
 Zig `Kind.concat`; only for string literals. The result kind of two adjacent
 string literals: UNTERMINATED if either is; self if equal; CHAR + X -> X;
 X + CHAR -> X; otherwise CANNOT_CONCAT.
 @return? CANNOT_CONCAT
*>
fn TextLiteralKind? TextLiteralKind.concat(self, TextLiteralKind other)
{
	unreachable("stage 0 stub");
}

<*
 Zig `Kind.maxCodepoint`: largest unicode codepoint representable by this kind
 via literal text or UCNs (may be smaller than max_int): CHAR, UTF_8 -> 0x7F;
 WIDE -> min(0x10FFFF, wchar_max); UTF_16 -> 0xFFFF; UTF_32 -> 0x10FFFF.
 @require self != UNTERMINATED
*>
fn uint TextLiteralKind.max_codepoint(self, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<*
 Zig `Kind.maxInt`: largest integer representable: CHAR, UTF_8 -> 0xFF;
 WIDE -> wchar_max; UTF_16 -> 0xFFFF; UTF_32 -> 0xFFFF_FFFF.
 @require self != UNTERMINATED
*>
fn uint TextLiteralKind.max_int(self, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<*
 Zig `Kind.charLiteralType`: CHAR -> INT; WIDE -> type_store.wchar;
 UTF_8 -> UCHAR; UTF_16 -> type_store.uint_least16_t;
 UTF_32 -> type_store.uint_least32_t.
 @require self != UNTERMINATED
*>
fn QualType TextLiteralKind.char_literal_type(self, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<*
 Zig `Kind.contentSlice`: the literal without its prefix and quotes:
 CHAR [1..len-1], WIDE/UTF_16/UTF_32 [2..len-1], UTF_8 [3..len-1].
 @require self != UNTERMINATED
*>
fn String TextLiteralKind.content_slice(self, String delimited)
{
	unreachable("stage 0 stub");
}

<*
 Zig `Kind.charUnitSize`: CHAR, UTF_8 -> ONE; UTF_16 -> TWO; UTF_32 -> FOUR;
 WIDE -> by sizeof(wchar_t) (2 -> TWO, 4 -> FOUR, else unreachable).
 @require self != UNTERMINATED
*>
fn CharUnitSize TextLiteralKind.char_unit_size(self, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<*
 Zig `Kind.internalStorageAlignment`: host alignment of the code unit type
 (u8/u16/u32) of `char_unit_size`, i.e. 1, 2 or 4.
*>
fn usz TextLiteralKind.internal_storage_alignment(self, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<*
 Zig `Kind.elementType`: CHAR -> CHAR; UTF_8 -> UCHAR if
 langopts.has_char8_t() else CHAR; otherwise char_literal_type.
 @require self != UNTERMINATED
*>
fn QualType TextLiteralKind.element_type(self, Compilation* comp)
{
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
}

<*
 Zig `Parser.err`: like `warn`, but at most one per literal: if already
 `errored` do nothing, otherwise warn and set `errored`. Resets `offset`.
 @return? compilation::FATAL_ERROR
*>
fn void? TextLiteralParser.err(&self, DiagnosticTemplate d, LiteralArg arg = { .kind = NONE })
{
	unreachable("stage 0 stub");
}

<*
 Zig `Parser.warn`: always resets `offset`; skipped when `errored`; otherwise
 emit_literal_diagnostic at `loc` with byte_offset += offset.
 @return? compilation::FATAL_ERROR
*>
fn void? TextLiteralParser.warn(&self, DiagnosticTemplate d, LiteralArg arg = { .kind = NONE })
{
	unreachable("stage 0 stub");
}

<*
 Zig `Parser.prefixLen`: CHAR 0; UTF_8 2; WIDE/UTF_16/UTF_32 1.
 @require self.kind != UNTERMINATED
*>
fn uint TextLiteralParser.prefix_len(&self)
{
	unreachable("stage 0 stub");
}
