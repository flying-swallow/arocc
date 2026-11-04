// Character and string literal semantics: src/aro/Parser.zig charLiteral and
// stringLiteral (plus the `#if` character-constant rule from
// Preprocessor/Parser.zig primaryExpr), extracted so they need no Parser,
// token list or AST. See number_literal.c3 for how the plan 11 literal modules
// fit together.
//
// Stage 0 (plan 11 contract): types, diagnostic ids and signatures; bodies are
// `unreachable("stage 0 stub")` until 11.4 `char-string` lands.
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
// - Zig's `p.strings` scratch buffer is a temporary List{char} from comp.gpa.
module aro::text_literal_semantics;
import aro::compilation, aro::diagnostics, aro::source, aro::lang_opts, aro::type_store, aro::tokenizer;
import aro::value, aro::value_interner, aro::text_literal;

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
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
}
