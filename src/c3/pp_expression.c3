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
// Deviation: the intmax assertion computes the width from the target
// (type_store::int_kind_qt(target.int_max_type())), like Zig's
// `comp.target.intMaxType()`, so type_store::init_named_types is not needed.
// Overflow detection uses 128-bit arithmetic where Zig uses @*WithOverflow.
module aro::preprocessor;
import aro::tokens, aro::tokenizer, aro::compilation, aro::diagnostics;
import aro::number_literal, aro::number_value, aro::text_literal_semantics, aro::text_literal;
import aro::type_store, aro::lang_opts;

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
	return self.is_unsigned ? self.unsigned != 0 : self.signed != 0;
}

<* Zig `Value.isZero`. *>
fn bool PpValue.is_zero(self) => !self.to_bool();

<*
 Zig `Value.toInt(usize)` as used by #embed limit: the value if it fits in a
 u64 (signed values must be >= 0), else NOT_REPRESENTABLE.
 @return? NOT_REPRESENTABLE
*>
fn ulong? PpValue.to_u64(self)
{
	if (self.is_unsigned) return self.unsigned;
	if (self.signed < 0) return NOT_REPRESENTABLE~;
	return (ulong)self.signed;
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
	if (self.is_unsigned) return;
	long s = self.signed;
	*self = pp_unsigned((ulong)s);
	if (s >= 0 || !has_side) return;
	p.pp.err(op_tok, DIAG_CONVERT_TO_POSITIVE, { diagnostics::arg_str(side), diagnostics::arg_int(s), diagnostics::arg_uint(self.unsigned) })!;
}

fn bool is_pp_expr_ws(TokenId id) @local => id == WHITESPACE || id == COMMENT || id == MACRO_WS;

<* Zig `next`: the next non-whitespace/comment/MACRO_WS token (advancing), else eof with id EOF. *>
fn TokenWithExpansionLocs PpExprParser.next(&self)
{
	while (self.index < self.tokens.len)
	{
		TokenWithExpansionLocs tok = self.tokens[self.index++];
		if (is_pp_expr_ws(tok.id)) continue;
		return tok;
	}
	self.eof.id = EOF;
	return self.eof;
}

<* Zig `peek`: like next without consuming the returned token. *>
fn TokenWithExpansionLocs PpExprParser.peek(&self)
{
	while (self.index < self.tokens.len)
	{
		TokenWithExpansionLocs tok = self.tokens[self.index];
		if (is_pp_expr_ws(tok.id))
		{
			self.index++;
			continue;
		}
		return tok;
	}
	self.eof.id = EOF;
	return self.eof;
}

<*
 Zig `parse`: assert the 64-bit intmax restriction (the target's intmax_t,
 type_store::int_kind_qt(target.int_max_type()), must be INTMAX_WIDTH bits;
 wider intmax targets are unsupported, as in Zig); `binary_expr(PREC_ANY,
 true)`; a leftover token that is not EOF -> DIAG_INVALID_PREPROC_OPERATOR
 (the value is still returned). EXPR_FAILED where Zig returns null.
 @return? EXPR_FAILED, compilation::FATAL_ERROR
*>
fn PpValue? PpExprParser.parse(&self)
{
	Compilation* comp = self.pp.comp;
	assert(type_store::int_kind_qt(comp.target.int_max_type()).bit_sizeof(comp) == INTMAX_WIDTH, "only a 64-bit intmax_t is supported");
	PpValue val = self.binary_expr(tokens::PREC_ANY, true)!;
	TokenWithExpansionLocs last = self.peek();
	if (last.id != EOF) self.pp.err(last, DIAG_INVALID_PREPROC_OPERATOR)!;
	return val;
}

<* Zig @mulWithOverflow / @addWithOverflow / @subWithOverflow on i64 via a 128-bit result. *>
fn long wrap_i128(int128 r, bool* overflow) @local
{
	if (r < (int128)long::min || r > (int128)long::max) *overflow = true;
	return (long)r;
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
 "null" means EXPR_FAILED.
 @return? EXPR_FAILED, compilation::FATAL_ERROR
*>
fn PpValue? PpExprParser.binary_expr(&self, Precedence min_prec, bool eval)
{
	PpValue lhs = self.primary_expr(eval)!;

	while (true)
	{
		TokenWithExpansionLocs tok = self.peek();
		Precedence op_prec = tokens::precedence(tok.id);
		if (op_prec.lt(min_prec) || op_prec == tokens::PREC_ASSIGN) return lhs;

		TokenWithExpansionLocs operator = self.next();
		bool eval_rhs;
		switch (operator.id)
		{
			case AMPERSAND_AMPERSAND: eval_rhs = eval && lhs.to_bool();
			case PIPE_PIPE: eval_rhs = eval && !lhs.to_bool();
			case QUESTION_MARK: eval_rhs = eval && lhs.to_bool();
			default: eval_rhs = eval;
		}
		PpValue rhs = self.binary_expr(op_prec.next(min_prec), eval_rhs)!;

		// Usual arithmetic conversion
		switch (operator.id)
		{
			case QUESTION_MARK:
			case ANGLE_BRACKET_ANGLE_BRACKET_LEFT:
			case ANGLE_BRACKET_ANGLE_BRACKET_RIGHT:
			case COMMA:
			case PIPE_PIPE:
			case AMPERSAND_AMPERSAND:
				break;
			default:
				if (lhs.is_unsigned || rhs.is_unsigned)
				{
					if (eval)
					{
						lhs.to_unsigned(self, operator, true, "left")!;
						rhs.to_unsigned(self, operator, true, "right")!;
					}
					else
					{
						lhs = pp_unsigned(0);
						rhs = pp_unsigned(0);
					}
				}
		}

		bool overflow = false;
		switch (operator.id)
		{
			case PERCENT:
				if (!rhs.is_zero())
				{
					if (lhs.is_unsigned)
					{
						lhs = pp_unsigned(lhs.unsigned % rhs.unsigned);
					}
					else if (lhs.signed == long::min && rhs.signed == -1)
					{
						lhs = pp_signed(0);
					}
					else
					{
						lhs = pp_signed(lhs.signed % rhs.signed);
					}
				}
				else if (eval)
				{
					self.pp.err(operator, DIAG_DIVISION_BY_ZERO, { diagnostics::arg_str("remainder") })!;
					return EXPR_FAILED~;
				}
			case SLASH:
				if (!rhs.is_zero())
				{
					if (lhs.is_unsigned)
					{
						lhs = pp_unsigned(lhs.unsigned / rhs.unsigned);
					}
					else if (lhs.signed == long::min && rhs.signed == -1)
					{
						overflow = true;
						lhs = pp_signed(long::min);
					}
					else
					{
						lhs = pp_signed(lhs.signed / rhs.signed);
					}
				}
				else if (eval)
				{
					self.pp.err(operator, DIAG_DIVISION_BY_ZERO, { diagnostics::arg_str("division") })!;
					return EXPR_FAILED~;
				}
			case ASTERISK:
				if (lhs.is_unsigned)
				{
					lhs = pp_unsigned(lhs.unsigned * rhs.unsigned);
				}
				else
				{
					lhs = pp_signed(wrap_i128((int128)lhs.signed * (int128)rhs.signed, &overflow));
				}
			case PLUS:
				if (lhs.is_unsigned)
				{
					lhs = pp_unsigned(lhs.unsigned + rhs.unsigned);
				}
				else
				{
					lhs = pp_signed(wrap_i128((int128)lhs.signed + (int128)rhs.signed, &overflow));
				}
			case MINUS:
				if (lhs.is_unsigned)
				{
					lhs = pp_unsigned(lhs.unsigned - rhs.unsigned);
				}
				else
				{
					lhs = pp_signed(wrap_i128((int128)lhs.signed - (int128)rhs.signed, &overflow));
				}
			case ANGLE_BRACKET_ANGLE_BRACKET_LEFT:
				bool negative = !rhs.is_unsigned && rhs.signed < 0;
				ulong amt = rhs.is_unsigned ? rhs.unsigned : (ulong)rhs.signed;
				if (negative || amt >= INTMAX_WIDTH)
				{
					overflow = true;
					// Zig sets the active field to 0, keeping the signedness.
					lhs.signed = 0;
					lhs.unsigned = 0;
				}
				else if (lhs.is_unsigned)
				{
					// Zig @shlWithOverflow(u64, u6): overflow when bits are shifted out.
					ulong res = lhs.unsigned << amt;
					if (res >> amt != lhs.unsigned) overflow = true;
					lhs = pp_unsigned(res);
				}
				else
				{
					// Zig @shlWithOverflow(i64, u6): overflow when the arithmetic shift back differs.
					long res = (long)((ulong)lhs.signed << amt);
					if (res >> amt != lhs.signed) overflow = true;
					lhs = pp_signed(res);
				}
			case ANGLE_BRACKET_ANGLE_BRACKET_RIGHT:
				bool negative = !rhs.is_unsigned && rhs.signed < 0;
				ulong amt = rhs.is_unsigned ? rhs.unsigned : (ulong)rhs.signed;
				if (negative)
				{
					overflow = true;
					lhs.signed = 0;
					lhs.unsigned = 0;
				}
				else
				{
					if (amt >= INTMAX_WIDTH)
					{
						overflow = true;
						amt = INTMAX_WIDTH - 1;
					}
					if (lhs.is_unsigned)
					{
						lhs = pp_unsigned(lhs.unsigned >> amt);
					}
					else
					{
						lhs = pp_signed(lhs.signed >> amt);
					}
				}
			case ANGLE_BRACKET_LEFT_EQUAL:
				lhs = pp_bool(lhs.is_unsigned ? lhs.unsigned <= rhs.unsigned : lhs.signed <= rhs.signed);
			case ANGLE_BRACKET_LEFT:
				lhs = pp_bool(lhs.is_unsigned ? lhs.unsigned < rhs.unsigned : lhs.signed < rhs.signed);
			case ANGLE_BRACKET_RIGHT_EQUAL:
				lhs = pp_bool(lhs.is_unsigned ? lhs.unsigned >= rhs.unsigned : lhs.signed >= rhs.signed);
			case ANGLE_BRACKET_RIGHT:
				lhs = pp_bool(lhs.is_unsigned ? lhs.unsigned > rhs.unsigned : lhs.signed > rhs.signed);
			case BANG_EQUAL:
				lhs = pp_bool(lhs.is_unsigned ? lhs.unsigned != rhs.unsigned : lhs.signed != rhs.signed);
			case EQUAL_EQUAL:
				lhs = pp_bool(lhs.is_unsigned ? lhs.unsigned == rhs.unsigned : lhs.signed == rhs.signed);
			case AMPERSAND:
				if (lhs.is_unsigned)
				{
					lhs = pp_unsigned(lhs.unsigned & rhs.unsigned);
				}
				else
				{
					lhs = pp_signed(lhs.signed & rhs.signed);
				}
			case CARET:
				if (lhs.is_unsigned)
				{
					lhs = pp_unsigned(lhs.unsigned ^ rhs.unsigned);
				}
				else
				{
					lhs = pp_signed(lhs.signed ^ rhs.signed);
				}
			case PIPE:
				if (lhs.is_unsigned)
				{
					lhs = pp_unsigned(lhs.unsigned | rhs.unsigned);
				}
				else
				{
					lhs = pp_signed(lhs.signed | rhs.signed);
				}
			case AMPERSAND_AMPERSAND:
				lhs = pp_bool(lhs.to_bool() && rhs.to_bool());
			case PIPE_PIPE:
				lhs = pp_bool(lhs.to_bool() || rhs.to_bool());
			case QUESTION_MARK:
				TokenWithExpansionLocs colon = self.next();
				if (colon.id != COLON)
				{
					self.pp.err(colon, DIAG_EXPECTED_COLON)!;
					self.pp.err(operator, DIAG_TO_MATCH_QUESTION)!;
					return EXPR_FAILED~;
				}
				bool eval_else = eval && lhs.is_zero();
				// Conditional operator is right associative.
				PpValue else_res = self.binary_expr(op_prec, eval_else)!;
				if (lhs.to_bool())
				{
					lhs = rhs;
				}
				else
				{
					lhs = else_res;
				}
				// Usual arithmetic conversion
				if (rhs.is_unsigned || else_res.is_unsigned) lhs.to_unsigned(self, operator, false, "")!;
			case COMMA:
				// Comma operator allowed in C99 if not being evaluated
				if (!self.pp.comp.langopts.standard.at_least(C99) || eval)
				{
					self.pp.err(operator, DIAG_COMMA_OPERATOR)!;
					return EXPR_FAILED~;
				}
				lhs = rhs;
			default:
				unreachable("not a preprocessor binary operator");
		}

		if (overflow && eval) self.pp.err(operator, DIAG_OVERFLOW)!;
	}
}

<* The pp record for a number_value diagnostic (same texts as number_value's templates). *>
fn PpDiagnostic number_value_pp_diag(NumberValueDiag d) @local
{
	switch (d)
	{
		case INT_LITERAL_TOO_BIG: return DIAG_INT_LITERAL_TOO_BIG;
		case IMPLICITLY_UNSIGNED_LITERAL: return DIAG_IMPLICITLY_UNSIGNED_LITERAL;
		case FLOAT_LITERAL_IN_EXPR: return DIAG_FLOAT_LITERAL_IN_EXPR;
		default: return { .tmpl = d.template() };
	}
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
	Preprocessor* pp = self.pp;
	// Zig `continue :loop p.peek().id` after a unary '+'.
	while (self.peek().id == PLUS) self.next();

	switch (self.peek().id)
	{
		case EOF:
		case R_PAREN:
			TokenWithExpansionLocs eof = self.next();
			pp.err(eof, DIAG_EXPECTED_VALUE_IN_EXPR)!;
			return EXPR_FAILED~;
		case L_PAREN:
			TokenWithExpansionLocs l_paren = self.next();
			PpValue res = self.binary_expr(tokens::PREC_ANY, eval)!;
			TokenWithExpansionLocs r_paren = self.next();
			if (r_paren.id != R_PAREN)
			{
				pp.err(r_paren, DIAG_CLOSING_PAREN)!;
				pp.err(l_paren, DIAG_TO_MATCH_PAREN)!;
				return EXPR_FAILED~;
			}
			return res;
		case KEYWORD_DEFINED:
			self.next();
			TokenWithExpansionLocs l_paren = self.peek();
			if (l_paren.id == L_PAREN) self.next();

			TokenWithExpansionLocs identifier = self.next();
			if (identifier.id == EOF)
			{
				pp.err(identifier, DIAG_MACRO_NAME_MISSING)!;
				return EXPR_FAILED~;
			}
			if (!identifier.id.is_macro_identifier())
			{
				pp.err(identifier, DIAG_MACRO_NAME_MUST_BE_IDENTIFIER)!;
				return EXPR_FAILED~;
			}
			if (l_paren.id == L_PAREN)
			{
				TokenWithExpansionLocs r_paren = self.next();
				if (r_paren.id != R_PAREN)
				{
					pp.err(r_paren, DIAG_CLOSING_PAREN)!;
					pp.err(l_paren, DIAG_TO_MATCH_PAREN)!;
					return EXPR_FAILED~;
				}
			}
			return pp_bool(pp.defines.contains(pp.expanded_slice(identifier)));
		case PP_NUM:
			TokenWithExpansionLocs num = self.next();
			NumberLiteralParser nlp = {
				.comp = pp.comp,
				.literal = pp.expanded_slice(num),
				.loc = num.loc,
				.expansion_locs = num.expansion_slice(),
			};
			NumberLiteralResult? parsed = nlp.parse();
			if (catch f = parsed)
			{
				if (f == text_literal::PARSING_FAILED) return EXPR_FAILED~;
				return f~;
			}
			PpNumberValue v = number_value::pp_int_value(parsed);
			foreach (d : v.diags.slice()) pp.err(num, number_value_pp_diag(d))!;
			if (v.rejected) return EXPR_FAILED~;
			return v.is_signed ? pp_signed(v.signed) : pp_unsigned(v.unsigned);
		case CHAR_LITERAL:
		case CHAR_LITERAL_UTF_8:
		case CHAR_LITERAL_UTF_16:
		case CHAR_LITERAL_UTF_32:
		case CHAR_LITERAL_WIDE:
			TokenWithExpansionLocs literal = self.next();
			PpCharValue c = text_literal_semantics::pp_char_value(pp.comp, literal.id, pp.expanded_slice(literal), literal.loc, literal.expansion_slice())!;
			return c.is_signed ? pp_signed(c.signed) : pp_unsigned(c.unsigned);
		case MINUS:
			TokenWithExpansionLocs minus = self.next();
			PpValue val = self.primary_expr(eval)!;
			if (val.is_unsigned) return pp_unsigned((ulong)0 - val.unsigned);
			if (val.signed == long::min)
			{
				if (eval) pp.err(minus, DIAG_OVERFLOW)!;
				return pp_signed(long::min);
			}
			return pp_signed(-val.signed);
		case TILDE:
			self.next();
			PpValue val = self.primary_expr(eval)!;
			if (val.is_unsigned) return pp_unsigned(~val.unsigned);
			return pp_signed(~val.signed);
		case BANG:
			self.next();
			PpValue val = self.primary_expr(eval)!;
			return pp_bool(!val.to_bool());
		case KEYWORD_TRUE:
		case KEYWORD_FALSE:
			TokenWithExpansionLocs literal = self.next();
			return pp_bool(literal.id == KEYWORD_TRUE);
		default:
			TokenWithExpansionLocs maybe_ident = self.next();
			if (maybe_ident.id.is_macro_identifier())
			{
				pp.err(maybe_ident, DIAG_UNDEFINED_MACRO, { diagnostics::arg_str(pp.expanded_slice(maybe_ident)) })!;
				if (self.peek().id == L_PAREN)
				{
					pp.err(maybe_ident, DIAG_FN_MACRO_UNDEFINED, { diagnostics::arg_str(pp.expanded_slice(maybe_ident)) })!;
					return EXPR_FAILED~;
				}
				return pp_signed(0);
			}
			pp.err(maybe_ident, DIAG_INVALID_PREPROC_EXPR_START)!;
			return EXPR_FAILED~;
	}
}
