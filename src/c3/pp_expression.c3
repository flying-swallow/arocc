// Port of src/aro/Preprocessor/Parser.zig. OWNER: plan 13.2 `pp-expr`.
//
// Evaluates a fully macro-expanded #if / #elif (and #embed limit) token slice.
// Values are intmax_t / uintmax_t with the CURRENT 64-bit restriction made
// explicit: `parse` asserts that the target's intmax_t is INTMAX_WIDTH bits
// (Zig `assert(comp.target.intMaxType().bitSizeof(comp) == intmax_width)`);
// wider intmax targets are unsupported, as in Zig.
//
// Literal decoding uses plan 11's APIs: number_literal::NumberLiteralParser
// (+ number_value::pp_int_value, whose `diags` the caller reports in order
// with err) for PP_NUM and text_literal_semantics::pp_char_value for
// character constants.
//
// Stage 0: types and signatures only; every body is a stub.
module aro::preprocessor;
import aro::tokens, aro::tokenizer, aro::compilation, aro::diagnostics;
import aro::number_literal, aro::number_value, aro::text_literal_semantics;

<* Zig `intmax_width`. *>
const uint INTMAX_WIDTH = 64;

<* Zig `Parser.Value` (union { signed: i64, unsigned: u64 }). *>
struct PpValue
{
	bool is_unsigned;
	<* valid when !is_unsigned *>
	long signed;
	<* valid when is_unsigned *>
	ulong unsigned;
}

<* Zig `Value.init(i64)` / `init(comptime_int)`. *>
fn PpValue pp_signed(long v) => { .signed = v };
<* Zig `Value.init(u64)`. *>
fn PpValue pp_unsigned(ulong v) => { .is_unsigned = true, .unsigned = v };
<* Zig `Value.init(bool)`: signed 0 or 1. *>
fn PpValue pp_bool(bool b) => { .signed = b ? 1 : 0 };

<* Zig `Value.toBool`: value != 0. *>
fn bool PpValue.to_bool(self)
{
	unreachable("stage 0 stub");
}

<* Zig `Value.isZero`. *>
fn bool PpValue.is_zero(self)
{
	unreachable("stage 0 stub");
}

<*
 Zig `Value.toInt(usize)` as used by #embed limit: the value if it fits in a
 u64 (signed values must be >= 0), else NOT_REPRESENTABLE.
 @return? NOT_REPRESENTABLE
*>
fn ulong? PpValue.to_u64(self)
{
	unreachable("stage 0 stub");
}

<* PpValue.to_u64: the value does not fit. *>
excuse NOT_REPRESENTABLE;

<* Zig's `null` result of parse / binaryExpr / primaryExpr: an error was already reported. *>
excuse EXPR_FAILED;

<*
 Zig `Parser`: a cursor over `tokens` (borrowed) with `eof` returned (with its
 id forced to EOF) past the end. Whitespace, comments and MACRO_WS are skipped.
*>
struct PpExprParser
{
	Preprocessor* pp;
	TokenWithExpansionLocs[] tokens;
	uint index;
	TokenWithExpansionLocs eof;
}

<*
 Zig `Value.toUnsigned(p, op_tok, opt_side)`: signed >= 0 -> same value as
 unsigned; negative -> bit-cast to u64 and, when `has_side`, warn
 DIAG_CONVERT_TO_POSITIVE at op_tok with (side, signed value, unsigned value).
 @return? compilation::FATAL_ERROR
*>
fn void? PpValue.to_unsigned(&self, PpExprParser* p, TokenWithExpansionLocs op_tok, bool has_side, String side)
{
	unreachable("stage 0 stub");
}

<* Zig `next`: the next non-whitespace/comment/MACRO_WS token (advancing), else eof with id EOF. *>
fn TokenWithExpansionLocs PpExprParser.next(&self)
{
	unreachable("stage 0 stub");
}

<* Zig `peek`: like next without consuming the returned token. *>
fn TokenWithExpansionLocs PpExprParser.peek(&self)
{
	unreachable("stage 0 stub");
}

<*
 Zig `parse`: assert the 64-bit intmax restriction
 (comp.type_store.intmax.bit_sizeof(comp) == INTMAX_WIDTH; named types must
 be initialized, type_store::init_named_types); `binary_expr(PREC_ANY,
 true)`; a leftover token that is not EOF -> DIAG_INVALID_PREPROC_OPERATOR
 (the value is still returned). EXPR_FAILED where Zig returns null.
 @return? EXPR_FAILED, compilation::FATAL_ERROR
*>
fn PpValue? PpExprParser.parse(&self)
{
	unreachable("stage 0 stub");
}

<*
 Zig `binaryExpr(min_prec, eval)`. Precedence climbing with tokens::precedence:
 stop when op_prec.lt(min_prec) or op_prec == PREC_ASSIGN. Short circuit:
 && evaluates rhs only if eval and lhs true; || only if eval and lhs false;
 ?: then-branch only if eval and lhs true, else-branch only if eval and lhs
 zero. Usual arithmetic conversion (except ?:, <<, >>, comma, ||, &&): if
 either side is unsigned, with eval both go through to_unsigned("left" /
 "right"), without eval both become unsigned 0. Operators: % and / by zero
 -> DIAG_DIVISION_BY_ZERO ("remainder" / "division") and null when eval
 (else lhs unchanged); signed min % -1 = 0, min / -1 = min with overflow;
 * + - signed with overflow detection, unsigned wrapping; << with amount < 0
 or >= INTMAX_WIDTH -> overflow, lhs 0, else shl with overflow; >> with
 amount < 0 -> overflow, lhs 0, >= width -> overflow and shift by width-1;
 comparisons / bit ops / &&, || give signed 0/1 or same-signedness results;
 ?: requires ':' (else DIAG_EXPECTED_COLON at it + note
 DIAG_TO_MATCH_QUESTION at '?', null), else = binary_expr(op_prec, ..),
 result converted to unsigned (no warning) if either branch is unsigned;
 comma: error DIAG_COMMA_OPERATOR and null before C99 or when eval, else rhs.
 Any overflow with eval -> warning DIAG_OVERFLOW at the operator.
 "null" below means EXPR_FAILED.
 @return? EXPR_FAILED, compilation::FATAL_ERROR
*>
fn PpValue? PpExprParser.binary_expr(&self, Precedence min_prec, bool eval)
{
	unreachable("stage 0 stub");
}

<*
 Zig `primaryExpr(eval)`. EOF / ')' -> DIAG_EXPECTED_VALUE_IN_EXPR, null.
 '(' expr ')' (missing ')' -> DIAG_CLOSING_PAREN + note DIAG_TO_MATCH_PAREN).
 `defined` [ '(' ] ident [ ')' ]: eof -> DIAG_MACRO_NAME_MISSING, non-identifier
 -> DIAG_MACRO_NAME_MUST_BE_IDENTIFIER, missing ')' -> CLOSING_PAREN + note;
 value signed 0/1 from pp.defines.contains(expanded_slice). PP_NUM:
 NumberLiteralParser.parse (PARSING_FAILED -> null) then pp_int_value: report
 its diags in order (FLOAT_LITERAL_IN_EXPR -> null). Char literals:
 pp_char_value. '+' is skipped; '-' negates (signed: 0 - v with overflow
 warning DIAG_OVERFLOW when eval; unsigned: wrapping); '~' complements; '!'
 gives signed !to_bool; `true`/`false` -> 1/0. Other macro identifiers:
 DIAG_UNDEFINED_MACRO (name), and if followed by '(' also
 DIAG_FN_MACRO_UNDEFINED (name) and null, else signed 0. Anything else:
 DIAG_INVALID_PREPROC_EXPR_START, null.
 "null" means EXPR_FAILED.
 @return? EXPR_FAILED, compilation::FATAL_ERROR
*>
fn PpValue? PpExprParser.primary_expr(&self, bool eval)
{
	unreachable("stage 0 stub");
}
