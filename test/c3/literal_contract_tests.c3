// Tests for the plan 11 stage-0 contract code that is implemented (not
// stubbed): text_literal's shared diagnostic plumbing (Ascii, LiteralArg,
// emit_literal_diagnostic), wchar_max, text_parser defaults,
// number_literal::float80_type / NumberLiteralParser.err and the diagnostic
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

fn String fmt_arg(ByteWriter* bw, String fmt, LiteralArg arg)
{
	bw.index = 0;
	text_literal::format_literal_arg(bw, fmt, arg)!!;
	return bw.str_view();
}

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
	char[64] buf;
	ByteWriter bw;
	bw.init_with_buffer(&buf);
	test::eq(fmt_arg(&bw, "invalid digit '{c}' in binary constant", text_literal::arg_ascii(text_literal::ascii('9'))),
		"invalid digit '9' in binary constant");
	test::eq(fmt_arg(&bw, "\\{c} used with no following hex digits", text_literal::arg_ascii(text_literal::ascii('x'))),
		"\\x used with no following hex digits");
	// Non-printable: "x" + two lowercase hex digits.
	test::eq(fmt_arg(&bw, "unknown escape sequence '\\{c}'", text_literal::arg_ascii(text_literal::ascii(0x1F))),
		"unknown escape sequence '\\x1f'");
	test::eq(fmt_arg(&bw, "<{c}>", text_literal::arg_ascii(text_literal::ascii(0x7F))), "<x7f>");
	test::eq(fmt_arg(&bw, "invalid suffix '{s}' on integer constant", text_literal::arg_str("qq")),
		"invalid suffix 'qq' on integer constant");
	test::eq(fmt_arg(&bw, "exponent has no digits", text_literal::arg_none()), "exponent has no digits");
}

fn void wchar_and_float80() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		check(text_literal::wchar_max(comp), 0x7FFF_FFFF); // wchar_t = int
		assert(number_literal::float80_type(comp)!! == type_store::LONG_DOUBLE);
		comp.langopts.emulate = MSVC;
		assert(@catch(number_literal::float80_type(comp)) == number_literal::NO_FLOAT80);
	};
	@with_comp("x86_64-windows-msvc"; Compilation* comp, Diagnostics* d)
	{
		check(text_literal::wchar_max(comp), 0xFFFF); // wchar_t = unsigned short
	};
	@with_comp("aarch64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		assert(@catch(number_literal::float80_type(comp)) == number_literal::NO_FLOAT80);
	};
}

fn void emit_and_parser_defaults() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		Source src = comp.add_source_from_buffer("lit.c", "int x = 0b2;\n")!!;
		Location loc = { .id = src.id, .byte_offset = 8, .line = 1 };
		NumberLiteralParser p = { .comp = comp, .literal = "0b2", .loc = loc };
		p.err(number_literal::DIAG_INVALID_BINARY_DIGIT, text_literal::arg_ascii(text_literal::ascii('2')))!!;
		// OFF by default: dropped.
		p.err(number_literal::DIAG_C23_BINARY)!!;
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
	test::eq(NumberValueDiag.INT_LITERAL_TOO_BIG.template().fmt,
		"integer literal is too large to be represented in any integer type");
	assert(NumberValueDiag.GNU_IMAGINARY_CONSTANT.template().kind == OFF);
	assert(NumberValueDiag.IMPLICITLY_UNSIGNED_LITERAL.template().extension);
	test::eq(TextSemanticsDiag.UNSUPPORTED_STR_CAT.template().fmt, "unsupported string literal concatenation");
	test::eq(TextSemanticsDiag.UNTERMINATED_CHAR_LITERAL_ERROR.template().fmt, "missing terminating ' character");
	NumberValueDiags ds;
	ds.push(IMPLICITLY_UNSIGNED_LITERAL);
	ds.push(GNU_IMAGINARY_CONSTANT);
	check(ds.slice().len, 2);
	assert(ds.slice()[1] == GNU_IMAGINARY_CONSTANT);
}
