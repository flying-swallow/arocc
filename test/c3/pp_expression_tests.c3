// Tests for src/c3/pp_expression.c3 (port of src/aro/Preprocessor/Parser.zig).
//
// Each case tokenizes a single `#if <expr>` line with the raw tokenizer and
// feeds the tokens after `if` directly to PpExprParser (no macro expansion),
// mirroring Zig `Preprocessor.expr`'s token collection. Columns therefore
// match the fixture lines they come from.
//
// Provenance:
//  [fixture] value and diagnostics copied from the named test/cases file
//            (lines that need macro expansion are left out).
//  [source]  hand-derived from Preprocessor/Parser.zig (no Zig executable was run).
module pp_expression_tests;
import aro::preprocessor, aro::tokens, aro::tokenizer, aro::source, aro::compilation, aro::diagnostics;
import aro::type_store, aro::lang_opts;
import std::io, std::collections::list, std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

<* Outcome of evaluating one line. *>
struct Outcome
{
	bool failed;
	PpValue val;
}

<* Tokenize `line` (which starts with "#if"), collect the expression tokens like Zig `expr` and parse them. *>
fn Outcome eval_line(Preprocessor* pp, String line)
{
	Compilation* comp = pp.comp;
	String text = string::tformat("%s\n", line);
	// Paths must be unique: add_source_from_buffer returns an existing source of the same path.
	Source src = comp.add_source_from_buffer(string::tformat("t%d.c", comp.sources.len()), text)!!;
	Tokenizer tz;
	tz.init(src.buf, src.id, comp.langopts);
	Token hash = tz.next_no_ws();
	assert(hash.id == HASH);
	Token kw = tz.next_no_ws();
	assert(kw.id == KEYWORD_IF);

	List{TokenWithExpansionLocs} toks;
	toks.init(comp.gpa);
	defer toks.free();
	Token eof;
	while (true)
	{
		Token tok = tz.next();
		if (tok.id == NL || tok.id == EOF)
		{
			eof = tok;
			break;
		}
		if (tok.id == WHITESPACE && toks.len() == 0) continue;
		if (tok.id == COMMENT) continue;
		toks.push(tokens::from_raw(tok));
	}
	PpExprParser p = { .pp = pp, .tokens = toks.array_view(), .eof = tokens::from_raw(eof) };
	PpValue? v = p.parse();
	if (catch f = v)
	{
		assert(f == preprocessor::EXPR_FAILED, "unexpected fault");
		return { .failed = true };
	}
	return { .val = v };
}

<* Run the body with a compilation (named types set up) and preprocessor; diagnostics go to a list. *>
macro @with_pp(; @body(Preprocessor* pp, Diagnostics* d))
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		type_store::init_named_types(&comp);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		@body(&pp, &d);
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void expect_signed(Outcome o, long v)
{
	assert(!o.failed, "expected a value");
	assert(!o.val.is_unsigned, "expected a signed value");
	check(o.val.signed, v);
}

fn void expect_unsigned(Outcome o, ulong v)
{
	assert(!o.failed, "expected a value");
	assert(o.val.is_unsigned, "expected an unsigned value");
	test::eq(o.val.unsigned, v);
}

<* Message `i` has text `text`, column `col` and kind `kind`. *>
fn void expect_msg(Diagnostics* d, sz i, String text, uint col, MessageKind kind)
{
	assert(d.messages.len() > i, "missing diagnostic");
	test::eq(d.messages[i].text, text);
	check(d.messages[i].location.col, col);
	check(d.messages[i].effective_kind.ordinal, kind.ordinal);
}

<* Evaluate a line that must produce no diagnostics. *>
fn Outcome quiet(Preprocessor* pp, Diagnostics* d, String line)
{
	sz before = d.messages.len();
	Outcome o = eval_line(pp, line);
	if (d.messages.len() != before) io::eprintfn("unexpected diagnostic for `%s`: %s", line, d.messages[before].text);
	check(d.messages.len(), before);
	return o;
}

const String INVALID_START = "invalid token at start of a preprocessor expression";
const String INVALID_OP = "token is not a valid binary operator in a preprocessor subexpression";
const String OVERFLOW = "integer overflow in preprocessor expression";
const String RIGHT_NEG = "right side of operator converted from negative value to unsigned: -1 to 18446744073709551615";

// [fixture] test/cases/preprocessor binary operators.c, lines without macros.
fn void binary_operators_fixture_errors() @test
{
	@with_pp(; Preprocessor* pp, Diagnostics* d)
	{
		assert(eval_line(pp, "#if &x").failed);
		expect_msg(d, 0, INVALID_START, 5, ERROR);
		assert(eval_line(pp, "#if *x").failed);
		expect_msg(d, 1, INVALID_START, 5, ERROR);
		// x is 0 (the undef warning is off); `&=` has assignment precedence.
		expect_signed(eval_line(pp, "#if x &= 1"), 0);
		expect_msg(d, 2, INVALID_OP, 7, ERROR);
		expect_signed(eval_line(pp, "#if x++"), 0);
		expect_msg(d, 3, INVALID_OP, 6, ERROR);
		assert(eval_line(pp, "#if ++x").failed);
		expect_msg(d, 4, INVALID_START, 5, ERROR);
		expect_signed(eval_line(pp, "#if x + y++"), 0);
		expect_msg(d, 5, INVALID_OP, 10, ERROR);
		assert(eval_line(pp, "#if )").failed);
		expect_msg(d, 6, "expected value in expression", 5, ERROR);
		assert(eval_line(pp, "#if \"not allowed\"").failed);
		expect_msg(d, 7, INVALID_START, 5, ERROR);
		assert(eval_line(pp, "#if U\"not allowed\"").failed);
		expect_msg(d, 8, INVALID_START, 5, ERROR);
		assert(eval_line(pp, "#if 1 + &x").failed);
		expect_msg(d, 9, INVALID_START, 9, ERROR);
		expect_signed(eval_line(pp, "#if 1 < ABC 2"), 0);
		expect_msg(d, 10, INVALID_OP, 13, ERROR);
		check(d.messages.len(), 11);
	};
}

fn void binary_operators_fixture_values() @test
{
	@with_pp(; Preprocessor* pp, Diagnostics* d)
	{
		expect_signed(quiet(pp, d, "#if ~0 && 0"), 0);
		expect_signed(quiet(pp, d, "#if !1"), 0);
		expect_signed(quiet(pp, d, "#if 'c' && 0"), 0);

		// 68:6 implicitly unsigned literal, 68:26 right side converted; 2^63 / (2^64-1) = 0.
		expect_unsigned(eval_line(pp, "#if -9223372036854775808 / -1"), 0);
		expect_msg(d, 0, "integer literal is too large to be represented in a signed integer type, interpreting as unsigned", 6, WARNING);
		expect_msg(d, 1, RIGHT_NEG, 26, WARNING);
		check(d.messages.len(), 2);

		// Not evaluated: no conversion warning, no division by zero.
		expect_signed(quiet(pp, d, "#if 0 && (1 - 1U)"), 0);
		expect_signed(quiet(pp, d, "#if 0 && (1 && (1 / 0))"), 0);

		expect_signed(eval_line(pp, "#if -(-9223372036854775807L -1)"), long::min);
		expect_msg(d, 2, OVERFLOW, 5, WARNING);
		check(d.messages.len(), 3);
	};
}

fn void binary_operators_fixture_shifts() @test
{
	@with_pp(; Preprocessor* pp, Diagnostics* d)
	{
		String[8] lines = {
			"#if (4 >> -2) != 0", "#if (4 >> 250) != 0", "#if (4U >> -2) != 0", "#if (4U >> 250) != 0",
			"#if (4 << -2) != 0", "#if (4 << 250) != 0", "#if (4U << -2) != 0", "#if (4U << 250) != 0",
		};
		uint[8] cols = { 8, 8, 9, 9, 8, 8, 9, 9 };
		foreach (i, line : lines)
		{
			// None of the fixture's `#error bad sh*` lines fire: every result is 0.
			expect_signed(eval_line(pp, line), 0);
			expect_msg(d, i, OVERFLOW, cols[i], WARNING);
		}
		check(d.messages.len(), 8);

		// Line 112: overflow at the `/`, the comparison is false.
		expect_signed(eval_line(pp, "#if ((-9223372036854775807 - 1) / -1) != (-9223372036854775807 - 1)"), 0);
		expect_msg(d, 8, OVERFLOW, 33, WARNING);
		expect_signed(quiet(pp, d, "#if ((-9223372036854775807 - 1) % -1) != 0"), 0);

		// Line 120.
		expect_signed(eval_line(pp, "#if 0xFFFFFFFFFFFFFFFF != -1"), 0);
		expect_msg(d, 9, RIGHT_NEG, 24, WARNING);
		check(d.messages.len(), 10);
	};
}

fn void binary_operators_fixture_parens_and_ternary() @test
{
	@with_pp(; Preprocessor* pp, Diagnostics* d)
	{
		assert(eval_line(pp, "#if defined(FOO foo").failed);
		expect_msg(d, 0, "expected closing ')'", 17, ERROR);
		expect_msg(d, 1, "to match this '('", 12, NOTE);
		assert(eval_line(pp, "#if (1 foo").failed);
		expect_msg(d, 2, "expected closing ')'", 8, ERROR);
		expect_msg(d, 3, "to match this '('", 5, NOTE);

		// The ternary converts to unsigned without a warning.
		expect_signed(quiet(pp, d, "#if (0 ? 0u : -1) != 18446744073709551615ULL"), 0);
		// The unsigned inner ternary makes the outer one unsigned, so `!= -1` converts its rhs.
		expect_signed(eval_line(pp, "#if (0 ? (0 ? 0u : 1) : -1) != -1"), 0);
		expect_msg(d, 4, RIGHT_NEG, 29, WARNING);
		check(d.messages.len(), 5);
	};
}

// [fixture] #if expression error.c, #if constant expression.c, signed remainder.c,
// imaginary constants.c, signed char.c, c23 keywords.c, undefined macro.c.
fn void other_fixtures() @test
{
	@with_pp(; Preprocessor* pp, Diagnostics* d)
	{
		assert(eval_line(pp, "#if 1/q").failed);
		expect_msg(d, 0, "division by zero in preprocessor expression", 6, ERROR);

		expect_signed(quiet(pp, d, "#if 0U - 1 != 18446744073709551615ULL"), 0);
		expect_signed(quiet(pp, d, "#if (-9223372036854775807LL - 1LL) % -1 != 0"), 0);

		assert(eval_line(pp, "#if 1.0i").failed);
		expect_msg(d, 1, "floating point literal in preprocessor expression", 5, ERROR);
		check(d.messages.len(), 2);

		// The default (host) test target has a signed plain char; char16_t is unsigned.
		if (type_store::char_signedness(pp.comp) == SIGNED)
		{
			expect_signed(quiet(pp, d, "#if '\\0' - 1 > 0"), 0);
		}
		expect_signed(quiet(pp, d, "#if u'\\0' - 1 < 0"), 0);

		bool found;
		pp.defines.get_or_put("FOO", &found);
		expect_signed(quiet(pp, d, "#if defined FOO & !defined(BAZ)"), 1);
		expect_signed(quiet(pp, d, "#if !defined(BAR)"), 1);
		expect_signed(quiet(pp, d, "#if defined BAR ? 1 : 0"), 0);
		expect_signed(quiet(pp, d, "#if 1 - 1"), 0);
		expect_signed(quiet(pp, d, "#if 0 && 0"), 0);
		expect_signed(quiet(pp, d, "#if 0 || 0"), 0);
	};
	@with_pp(; Preprocessor* pp, Diagnostics* d)
	{
		d.set("undef", WARNING)!!;
		expect_signed(eval_line(pp, "#if FOO"), 0);
		expect_msg(d, 0, "'FOO' is not defined, evaluates to 0", 5, WARNING);
		assert(eval_line(pp, "#if undefined(foo)").failed);
		expect_msg(d, 1, "'undefined' is not defined, evaluates to 0", 5, WARNING);
		expect_msg(d, 2, "function-like macro 'undefined' is not defined", 5, ERROR);
		check(d.messages.len(), 3);
	};
	@with_pp(; Preprocessor* pp, Diagnostics* d)
	{
		pp.comp.langopts.set_standard("c23")!!;
		expect_signed(quiet(pp, d, "#if false"), 0);
		expect_signed(quiet(pp, d, "#if true"), 1);
		expect_signed(quiet(pp, d, "#if true + 1 != 2"), 0);
		expect_signed(quiet(pp, d, "#if defined(true) || defined(false)"), 0);
	};
}

// [source] Parser.zig binaryExpr / primaryExpr branches not covered by fixtures.
fn void source_derived_arithmetic() @test
{
	@with_pp(; Preprocessor* pp, Diagnostics* d)
	{
		expect_signed(quiet(pp, d, "#if 1 + 2 * 3"), 7);
		expect_signed(quiet(pp, d, "#if (1 + 2) * 3"), 9);
		expect_signed(quiet(pp, d, "#if 10 - 4 - 3"), 3);
		expect_signed(quiet(pp, d, "#if 7 / 2"), 3);
		expect_signed(quiet(pp, d, "#if -7 / 2"), -3);
		expect_signed(quiet(pp, d, "#if -7 % 3"), -1);
		expect_signed(quiet(pp, d, "#if 7 % -3"), 1);
		expect_unsigned(quiet(pp, d, "#if 7U % 3"), 1);
		expect_signed(quiet(pp, d, "#if 1 | 2 ^ 3 & 6"), 1 | (2 ^ (3 & 6)));
		expect_signed(quiet(pp, d, "#if 1 << 2 + 1"), 8);
		expect_signed(quiet(pp, d, "#if -16 >> 2"), -4);
		expect_unsigned(quiet(pp, d, "#if 0x8000000000000000 >> 63"), 1);
		expect_signed(quiet(pp, d, "#if 1 < 2 == 1"), 1);
		expect_signed(quiet(pp, d, "#if 2 >= 2 && 3 <= 2"), 0);
		expect_signed(quiet(pp, d, "#if 3 > 2 || 1 / 0"), 1);
		expect_signed(quiet(pp, d, "#if 1 ? 2 : 3"), 2);
		expect_signed(quiet(pp, d, "#if 0 ? 2 : 0 ? 3 : 4"), 4);
		expect_signed(quiet(pp, d, "#if 1 ? 2 : 1 / 0"), 2);
		expect_signed(quiet(pp, d, "#if 0 ? 1 / 0 : 5"), 5);
		expect_unsigned(quiet(pp, d, "#if 1 ? 2 : 3U"), 2);
		expect_unsigned(quiet(pp, d, "#if 1 ? -1 : 0U"), ulong::max);
		expect_unsigned(quiet(pp, d, "#if ~0U"), ulong::max);
		expect_signed(quiet(pp, d, "#if ~0"), -1);
		expect_unsigned(quiet(pp, d, "#if -1U"), ulong::max);
		expect_signed(quiet(pp, d, "#if +-+1"), -1);
		expect_signed(quiet(pp, d, "#if !0U"), 1);
		expect_unsigned(quiet(pp, d, "#if 18446744073709551615U + 1"), 0);
		expect_unsigned(quiet(pp, d, "#if 0U - 1"), ulong::max);
		expect_unsigned(quiet(pp, d, "#if 4294967296U * 4294967296U"), 0);
		expect_unsigned(quiet(pp, d, "#if 1U << 63"), (ulong)1 << 63);
		expect_unsigned(quiet(pp, d, "#if 9223372036854775807 + 1U"), (ulong)1 << 63);
		expect_signed(quiet(pp, d, "#if 'A'"), 65);
		expect_signed(quiet(pp, d, "#if 017"), 15);
		// Shifts do not use the usual arithmetic conversion.
		expect_signed(quiet(pp, d, "#if 1 << 2U"), 4);
		expect_unsigned(quiet(pp, d, "#if 8U >> 1"), 4);
		// Logical operators give signed results.
		expect_signed(quiet(pp, d, "#if 2U && 3U"), 1);
		// Comparison of mixed signedness without eval: no warning.
		expect_signed(quiet(pp, d, "#if 0 && -1 < 0U"), 0);
		// 0 && (1, 2): comma allowed when not evaluated (C99+).
		expect_signed(quiet(pp, d, "#if 0 && (1, 2)"), 0);
		// Not evaluated: overflow is not reported.
		expect_signed(quiet(pp, d, "#if 0 && 9223372036854775807 + 1"), 0);
		expect_signed(quiet(pp, d, "#if 0 && -(-9223372036854775807 - 1)"), 0);
		expect_signed(quiet(pp, d, "#if 0 && (1 % 0)"), 0);
	};
}

fn void source_derived_diagnostics() @test
{
	@with_pp(; Preprocessor* pp, Diagnostics* d)
	{
		sz n = 0;
		expect_signed(eval_line(pp, "#if 9223372036854775807 + 1"), long::min);
		expect_msg(d, n++, OVERFLOW, 25, WARNING);
		expect_signed(eval_line(pp, "#if -9223372036854775807 - 2"), long::max);
		expect_msg(d, n++, OVERFLOW, 26, WARNING);
		expect_signed(eval_line(pp, "#if 3037000500 * 3037000500"), (long)((ulong)3037000500 * (ulong)3037000500));
		expect_msg(d, n++, OVERFLOW, 16, WARNING);
		expect_signed(eval_line(pp, "#if 1 << 63"), long::min);
		expect_msg(d, n++, OVERFLOW, 7, WARNING);
		expect_signed(eval_line(pp, "#if -1 >> 70"), -1);
		expect_msg(d, n++, OVERFLOW, 8, WARNING);
		expect_unsigned(eval_line(pp, "#if 1U << 64"), 0);
		expect_msg(d, n++, OVERFLOW, 8, WARNING);
		expect_unsigned(eval_line(pp, "#if 3U << 63"), (ulong)1 << 63);
		expect_msg(d, n++, OVERFLOW, 8, WARNING);

		assert(eval_line(pp, "#if 5 % 0").failed);
		expect_msg(d, n++, "remainder by zero in preprocessor expression", 7, ERROR);
		assert(eval_line(pp, "#if 5U / 0").failed);
		expect_msg(d, n++, "division by zero in preprocessor expression", 8, ERROR);

		expect_signed(eval_line(pp, "#if -1 < 0U"), 0);
		expect_msg(d, n++, "left side of operator converted from negative value to unsigned: -1 to 18446744073709551615", 8, WARNING);

		// 2^64 wraps to 0 in the digit loop: too big, then a signed 0.
		expect_signed(eval_line(pp, "#if 18446744073709551616"), 0);
		expect_msg(d, n++, "integer literal is too large to be represented in any integer type", 5, ERROR);
		// Hex literals above INTMAX_MAX are unsigned without a warning.
		expect_unsigned(quiet(pp, d, "#if 0x8000000000000000"), (ulong)1 << 63);

		assert(eval_line(pp, "#if 1 ? 2").failed);
		expect_msg(d, n++, "expected ':'", 10, ERROR);
		expect_msg(d, n++, "to match this '?'", 7, NOTE);

		// Evaluated comma: the extension warning, then null.
		assert(eval_line(pp, "#if 1, 2").failed);
		expect_msg(d, n++, "comma operator in operand of #if", 6, WARNING);

		assert(eval_line(pp, "#if").failed);
		expect_msg(d, n++, "expected value in expression", 4, ERROR);
		assert(eval_line(pp, "#if 1 +").failed);
		expect_msg(d, n++, "expected value in expression", 8, ERROR);
		assert(eval_line(pp, "#if defined").failed);
		expect_msg(d, n++, "macro name missing", 12, ERROR);
		assert(eval_line(pp, "#if defined(1)").failed);
		expect_msg(d, n++, "macro name must be an identifier", 13, ERROR);
		assert(eval_line(pp, "#if 1.5").failed);
		expect_msg(d, n++, "floating point literal in preprocessor expression", 5, ERROR);
		// A number_literal syntax error returns null after its own diagnostic.
		sz before = d.messages.len();
		assert(eval_line(pp, "#if 0x1g").failed);
		check(d.messages.len(), before + 1);
		n++;
		check(d.messages.len(), n);
	};
	@with_pp(; Preprocessor* pp, Diagnostics* d)
	{
		// Before C99 even an unevaluated comma is reported.
		pp.comp.langopts.set_standard("c89")!!;
		assert(eval_line(pp, "#if 0 && (1, 2)").failed);
		check(d.messages.len(), 1);
		check(d.messages[0].location.col, 12);
	};
}

// [source] Value helpers and the explicit 64-bit intmax restriction.
fn void value_helpers() @test
{
	check(preprocessor::INTMAX_WIDTH, 64);
	assert(preprocessor::pp_bool(true).to_bool());
	assert(preprocessor::pp_unsigned(0).is_zero());
	assert(!preprocessor::pp_signed(-1).is_zero());
	test::eq(preprocessor::pp_signed(5).to_u64()!!, (ulong)5);
	test::eq(preprocessor::pp_unsigned(ulong::max).to_u64()!!, ulong::max);
	assert(@catch(preprocessor::pp_signed(-1).to_u64()) == preprocessor::NOT_REPRESENTABLE);
	@with_pp(; Preprocessor* pp, Diagnostics* d)
	{
		Compilation* comp = pp.comp;
		check(type_store::int_kind_qt(comp.target.int_max_type()).bit_sizeof(comp), preprocessor::INTMAX_WIDTH);
	};
}
