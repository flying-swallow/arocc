// Tests for text_literal_semantics that do not need the text_literal decoder
// (plan 11.4): print_string (Zig Value.printString / std.zig.stringEscape),
// the TextSemanticsDiag table and char_literal's empty / unterminated tokens.
// The decoder-dependent paths are in text_literal_semantics_manual_tests.c3.
// Expected values are source-derived from Value.zig printString,
// std.zig.stringEscape, std.unicode and Parser.zig charLiteral; no Zig
// executable was run.
module text_literal_semantics_tests;
import aro::text_literal_semantics, aro::text_literal, aro::value, aro::value_interner;
import aro::compilation, aro::diagnostics, aro::source, aro::target, aro::type_store, aro::tokenizer;
import std::io, std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

const Host HOST = { X86_64, LINUX, GNU };

<* Run the body with a compilation for `triple` whose diagnostics go to a list. *>
macro @with_comp(String triple; @body(Compilation* comp))
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
		@body(&comp);
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

<* print_string of `bytes` (NUL included) as an array of `elem`, into `out` (reset first). *>
fn String print(Compilation* comp, DString* out, QualType elem, char[] bytes, PrintStringStyle style = QUOTED)
{
	out.clear();
	ulong elem_size = elem.sizeof(comp);
	QualType arr = comp.type_store.put(type_store::type_array(elem, FIXED, (ulong)bytes.len / elem_size));
	text_literal_semantics::print_string(bytes, arr, comp, *out, style);
	return out.str_view();
}

fn void print_string_bytes() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp)
	{
		DString out;
		out.init(comp.gpa);
		defer out.free();
		test::eq(print(comp, &out, type_store::CHAR, "foo\0"), "\"foo\"");
		test::eq(print(comp, &out, type_store::CHAR, "foo\0", BARE), "foo");
		test::eq(print(comp, &out, type_store::CHAR, "\0"), "\"\"");
		// stringEscape: \n \r \t \\ \" escaped; ' kept; other non-printables \xNN lowercase.
		test::eq(print(comp, &out, type_store::CHAR, "a\n\r\t\\\"'b\0"), "\"a\\n\\r\\t\\\\\\\"'b\"");
		test::eq(print(comp, &out, type_store::CHAR, (char[]){ 0x01, 0x7F, 0xFF, 0x1B, ' ', '~', 0 }), "\"\\x01\\x7f\\xff\\x1b ~\"");
		// Embedded NUL is escaped; only the final unit is dropped.
		test::eq(print(comp, &out, type_store::CHAR, (char[]){ 'a', 0, 'b', 0 }), "\"a\\x00b\"");
		// UTF-8 bytes are escaped byte-wise.
		test::eq(print(comp, &out, type_store::UCHAR, "\xC3\xA9\0"), "\"\\xc3\\xa9\"");
	};
}

fn void print_string_utf16() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp)
	{
		DString out;
		out.init(comp.gpa);
		defer out.free();
		QualType u16 = comp.type_store.uint_least16_t;
		check(u16.sizeof(comp), 2);
		// "aé" LE, NUL unit.
		test::eq(print(comp, &out, u16, (char[]){ 'a', 0, 0xE9, 0, 0, 0 }), "\"a\xC3\xA9\"");
		// Surrogate pair U+1F917 = D83E DD17.
		test::eq(print(comp, &out, u16, (char[]){ 0x3E, 0xD8, 0x17, 0xDD, 0, 0 }), "\"\xF0\x9F\xA4\x97\"");
		// High surrogate followed by a non-low unit: \x<hex>, then the next unit.
		test::eq(print(comp, &out, u16, (char[]){ 0x3E, 0xD8, 'A', 0, 0, 0 }), "\"\\xd83eA\"");
		// High surrogate at the end.
		test::eq(print(comp, &out, u16, (char[]){ 'A', 0, 0x00, 0xDB, 0, 0 }, BARE), "A\\xdb00");
		// Lone low surrogate: Zig "{u}" prints U+FFFD.
		test::eq(print(comp, &out, u16, (char[]){ 0x17, 0xDD, 0, 0 }), "\"\xEF\xBF\xBD\"");
		// Control characters are not escaped for wide strings.
		test::eq(print(comp, &out, u16, (char[]){ '\n', 0, 0, 0 }), "\"\n\"");
	};
}

fn void print_string_utf32() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp)
	{
		DString out;
		out.init(comp.gpa);
		defer out.free();
		QualType u32 = comp.type_store.uint_least32_t;
		check(u32.sizeof(comp), 4);
		test::eq(print(comp, &out, u32, (char[]){ 'A', 0, 0, 0, 0x17, 0xF9, 0x01, 0, 0, 0, 0, 0 }), "\"A\xF0\x9F\xA4\x97\"");
		// Surrogate and > 0x10FFFF: \x<hex>, lowercase, unpadded.
		test::eq(print(comp, &out, u32, (char[]){ 0x00, 0xD8, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x11, 0, 0, 0, 0, 0 }),
			"\"\\xd800\\xffffffff\\x110000\"");
		// wchar_t (int on x86_64 linux) has the same unit size.
		test::eq(print(comp, &out, comp.type_store.wchar, (char[]){ 'z', 0, 0, 0, 0, 0, 0, 0 }, BARE), "z");
	};
}

fn void diag_templates() @test
{
	test::eq(TextSemanticsDiag.UNSUPPORTED_STR_CAT.template().fmt, "unsupported string literal concatenation");
	test::eq(TextSemanticsDiag.EMPTY_CHAR_LITERAL_ERROR.template().fmt, "empty character constant");
	test::eq(TextSemanticsDiag.UNTERMINATED_CHAR_LITERAL_ERROR.template().fmt, "missing terminating ' character");
	assert(TextSemanticsDiag.UNSUPPORTED_STR_CAT.template().kind == ERROR);
}

fn void char_literal_empty_and_unterminated() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp)
	{
		Location loc = { .line = 1 };
		CharLiteral r = text_literal_semantics::char_literal(comp, EMPTY_CHAR_LITERAL, "''", loc, {})!!;
		assert(r.has_diag && r.diag == EMPTY_CHAR_LITERAL_ERROR);
		assert(r.kind == CHAR && r.qt == type_store::INT && r.val.opt_ref == value::ZERO.opt_ref);
		r = text_literal_semantics::char_literal(comp, UNTERMINATED_CHAR_LITERAL, "'a", loc, {})!!;
		assert(r.has_diag && r.diag == UNTERMINATED_CHAR_LITERAL_ERROR);
		assert(r.kind == CHAR && r.qt == type_store::INT && r.val.opt_ref == value::ZERO.opt_ref);
		check(comp.diagnostics.messages.len(), 0); // returned, not reported
	};
}
