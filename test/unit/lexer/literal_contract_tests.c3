// Tests for the plan 11 stage-0 contract code that is implemented (not
// stubbed): text_literal's shared diagnostic plumbing (Ascii,
// emit_literal_diagnostic), Compilation.wchar_max, text_parser defaults,
// Compilation.float80_type / LiteralSite.err and the diagnostic
// id -> template tables. Expected values are source-derived from
// Tokenizer/text_literal.zig (Ascii.format), Compilation.zig (wcharMax,
// float80Type) and the Diagnostic constants; no Zig executable was run.
module literal_contract_tests;
import aro::text_literal, aro::number_literal, aro::number_value, aro::text_literal_semantics;
import aro::compilation, aro::diagnostics, aro::source, aro::target, aro::type_store, aro::lang_opts;
import std::io, std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

const Host HOST = { X86_64, LINUX, GNU };

fn String fmt_ascii(String fmt, char c) => string::tformat(fmt, text_literal::ascii(c));
fn String fmt_byte(String fmt, char c) => string::tformat(fmt, (text_literal::Ascii){ c });

<* Run the body with a compilation for `triple` whose diagnostics go to a list. *>
macro @with_comp(String triple; @body(Compilation* comp, Diagnostics* d))
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		comp.target = target::parse_triple(triple, HOST)!!;
		comp.langopts.set_target_options(&comp.target);
		type_store::init_named_types(&comp);
		@body(&comp, &d);
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void ascii_format() @test
{
	@pool()
	{
		test::eq(fmt_ascii(Diagnostic.INVALID_BINARY_DIGIT.fmt, '9'),
			"invalid digit '9' in binary constant");
		test::eq(fmt_ascii(Diagnostic.MISSING_HEX_ESCAPE.fmt, 'x'),
			"\\x used with no following hex digits");
		// Non-printable: "x" + two lowercase hex digits.
		test::eq(fmt_ascii(Diagnostic.UNKNOWN_ESCAPE_SEQUENCE.fmt, 0x1F),
			"unknown escape sequence '\\x1f'");
		test::eq(fmt_ascii("<%s>", 0x7F), "<x7f>");
		// A non-ASCII byte (text_literal builds Ascii directly there) also prints as hex.
		test::eq(fmt_byte("<%s>", 0xE9), "<xe9>");
		test::eq(string::tformat(Diagnostic.INVALID_INT_SUFFIX.fmt, "qq"),
			"invalid suffix 'qq' on integer constant");
		test::eq(Diagnostic.EXPONENT_HAS_NO_DIGITS.fmt, "exponent has no digits");
	};
}

fn void wchar_and_float80() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		check(comp.wchar_max(), 0x7FFF_FFFF); // wchar_t = int
		assert(comp.float80_type()!! == type_store::LONG_DOUBLE);
		comp.langopts.emulate = MSVC;
		assert(@catch(comp.float80_type()) == compilation::NO_FLOAT80);
	};
	@with_comp("x86_64-windows-msvc"; Compilation* comp, Diagnostics* d)
	{
		check(comp.wchar_max(), 0xFFFF); // wchar_t = unsigned short
	};
	@with_comp("aarch64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		assert(@catch(comp.float80_type()) == compilation::NO_FLOAT80);
	};
}

fn void emit_and_parser_defaults() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		Source src = comp.add_source_from_buffer("lit.c", "int x = 0b2;\n")!!;
		Location loc = { .id = src.id, .byte_offset = 8, .line = 1 };
		text_literal::emit_literal_diagnostic(comp, Diagnostic.INVALID_BINARY_DIGIT, loc, {}, text_literal::ascii('2'))!!;
		// OFF by default: dropped.
		text_literal::emit_literal_diagnostic(comp, Diagnostic.C23_BINARY, loc, {})!!;
		check(d.messages.len(), 1);
		test::eq(d.messages[0].text, "invalid digit '2' in binary constant");
		assert(d.messages[0].effective_kind == ERROR);
		check(d.messages[0].location.col, 9);

		TextLiteralParser t = text_literal::text_parser(comp, "ab", CHAR, 0x7F, loc, {});
		check(t.i, 0);
		check(t.offset, 0);
		assert(!t.errored && !t.incorrect_encoding_is_error && t.diagnose_incorrect_encoding);
	};
}

fn void diag_tables() @test
{
	test::eq(Diagnostic.INT_LITERAL_TOO_BIG.fmt,
		"integer literal is too large to be represented in any integer type");
	assert(Diagnostic.GNU_IMAGINARY_CONSTANT.kind == OFF);
	assert(Diagnostic.IMPLICITLY_UNSIGNED_LITERAL.meta.extension);
	test::eq(Diagnostic.UNSUPPORTED_STR_CAT.fmt, "unsupported string literal concatenation");
	test::eq(Diagnostic.UNTERMINATED_CHAR_LITERAL_ERROR.fmt, "missing terminating ' character");
	NumberDiags ds = { .gnu_imaginary_constant = true, .implicitly_unsigned_literal = true };
	Diagnostic[5] got;
	usz n;
	ds.@each(; $diag) { got[n++] = $diag; };
	check(n, 2);
	assert(got[0] == IMPLICITLY_UNSIGNED_LITERAL && got[1] == GNU_IMAGINARY_CONSTANT);
}
