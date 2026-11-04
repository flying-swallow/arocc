// Decoder-dependent tests for text_literal_semantics (plan 11.4): char_literal,
// pp_char_value, string_run and string_literal go through text_literal's
// classify / Kind methods / TextLiteralParser, which plan 11.3 implements in
// parallel. Tagged "manual" until 11.3 is merged; the integrator should drop
// the tag (or fold these into //test/c3:literal_tests).
//
// Expected values are source-derived from Parser.zig charLiteral /
// stringLiteral, Preprocessor/Parser.zig primaryExpr and the fixtures
// test/cases/{wide strings, char literal sign extension, concat improperly
// encoded strings}.c; no Zig executable was run.
module text_semantics_manual_tests;
import aro::text_literal_semantics, aro::text_literal, aro::value, aro::value_interner;
import aro::compilation, aro::diagnostics, aro::source, aro::target, aro::type_store, aro::tokenizer, aro::lang_opts;
import std::io, std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

const Host HOST = { X86_64, LINUX, GNU };

<* Run the body with a compilation for `triple` (C23) whose diagnostics go to a list. *>
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
		comp.langopts.standard = C23;
		type_store::init_named_types(&comp);
		@body(&comp, &d);
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

<* A source holding `text`; the location of byte `offset` in it. *>
fn Location loc_in(Compilation* comp, String text, uint offset, String path = "lit.c")
{
	Source src = comp.add_source_from_buffer(path, text)!!; // deduplicated by path
	return { .id = src.id, .byte_offset = offset, .line = 1 };
}

fn CharLiteral char_lit(Compilation* comp, TokenId id, String bytes)
{
	Location loc = loc_in(comp, bytes, 0);
	return text_literal_semantics::char_literal(comp, id, bytes, loc, {})!!;
}

fn PpCharValue pp_char(Compilation* comp, TokenId id, String bytes)
{
	Location loc = loc_in(comp, bytes, 0);
	return text_literal_semantics::pp_char_value(comp, id, bytes, loc, {})!!;
}

fn void char_literals() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		CharLiteral r = char_lit(comp, CHAR_LITERAL, "'a'");
		assert(!r.has_diag && r.kind == CHAR && r.qt == type_store::INT);
		check(r.val.to_i64(comp)!!, 'a');
		// Signed char: '\xFF' == -1 (char literal sign extension.c).
		r = char_lit(comp, CHAR_LITERAL, "'\\xFF'");
		check(r.val.to_i64(comp)!!, -1);
		// Multichar: (val << 8) + byte, no sign extension.
		r = char_lit(comp, CHAR_LITERAL, "'\\x00\\xFF'");
		check(r.val.to_i64(comp)!!, 255);
		r = char_lit(comp, CHAR_LITERAL, "'\\xFF\\xFF'");
		check(r.val.to_i64(comp)!!, 65535);
		check(d.messages.len(), 2); // -Wmultichar warnings
		test::eq(d.messages[0].text, "multi-character character constant");
		// Four chars: four_char_char_literal is OFF by default.
		r = char_lit(comp, CHAR_LITERAL, "'abcd'");
		check(r.val.to_i64(comp)!!, 0x61626364);
		check(d.messages.len(), 2);
		// u8'\xFF' == 0xFF, type unsigned char.
		r = char_lit(comp, CHAR_LITERAL_UTF_8, "u8'\\xFF'");
		assert(r.kind == UTF_8 && r.qt == type_store::UCHAR);
		check(r.val.to_u64(comp)!!, 0xFF);
		// Wide / UTF-16 / UTF-32 types.
		r = char_lit(comp, CHAR_LITERAL_WIDE, "L'a'");
		assert(r.kind == WIDE && r.qt == comp.type_store.wchar);
		check(r.val.to_i64(comp)!!, 'a');
		r = char_lit(comp, CHAR_LITERAL_UTF_16, "u'\\u00e9'");
		assert(r.kind == UTF_16 && r.qt == comp.type_store.uint_least16_t);
		check(r.val.to_u64(comp)!!, 0xE9);
		r = char_lit(comp, CHAR_LITERAL_UTF_32, "U'\\U0001F917'");
		assert(r.kind == UTF_32 && r.qt == comp.type_store.uint_least32_t);
		check(r.val.to_u64(comp)!!, 0x1F917);
		check(d.messages.len(), 2);
	};
}

fn void pp_char_values() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		// #if '\xFF' != -1 / #if u8'\xFF' != 0xFF (char literal sign extension.c).
		PpCharValue v = pp_char(comp, CHAR_LITERAL, "'\\xFF'");
		assert(v.is_signed);
		check(v.signed, -1);
		v = pp_char(comp, CHAR_LITERAL_UTF_8, "u8'\\xFF'");
		assert(!v.is_signed);
		check(v.unsigned, 0xFF);
		// Plain char, signed target: signed.
		v = pp_char(comp, CHAR_LITERAL, "'a'");
		assert(v.is_signed);
		check(v.signed, 'a');
		// wchar_t is int on x86_64 linux: signed.
		v = pp_char(comp, CHAR_LITERAL_WIDE, "L'a'");
		assert(v.is_signed);
		v = pp_char(comp, CHAR_LITERAL_UTF_16, "u'a'");
		assert(!v.is_signed);
		check(v.unsigned, 'a');
	};
	@with_comp("aarch64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		// Unsigned char target: a CHAR literal is unsigned, and '\xFF' is 255.
		PpCharValue v = pp_char(comp, CHAR_LITERAL, "'a'");
		assert(!v.is_signed);
		check(v.unsigned, 'a');
		v = pp_char(comp, CHAR_LITERAL, "'\\xFF'");
		assert(!v.is_signed);
		check(v.unsigned, 0xFF);
		// wchar_t is unsigned int on aarch64 linux.
		v = pp_char(comp, CHAR_LITERAL_WIDE, "L'a'");
		assert(!v.is_signed);
	};
}

fn void string_runs() @test
{
	sz idx = -1;
	StringRun run = text_literal_semantics::string_run({ STRING_LITERAL, STRING_LITERAL_UTF_16, STRING_LITERAL, SEMICOLON }, &idx)!!;
	assert(run.kind == UTF_16);
	check(run.len, 3);
	run = text_literal_semantics::string_run({ STRING_LITERAL }, &idx)!!;
	assert(run.kind == CHAR);
	check(run.len, 1);
	// u"a" U"b" (wide strings.c line 24): fails at the second token.
	assert(@catch(text_literal_semantics::string_run({ STRING_LITERAL_UTF_16, STRING_LITERAL_UTF_32 }, &idx)) == text_literal::CANNOT_CONCAT);
	check(idx, 1);
	assert(@catch(text_literal_semantics::string_run({ STRING_LITERAL_WIDE, STRING_LITERAL, STRING_LITERAL_UTF_8 }, &idx)) == text_literal::CANNOT_CONCAT);
	check(idx, 2);
	assert(@catch(text_literal_semantics::string_run({ STRING_LITERAL, UNTERMINATED_STRING_LITERAL, STRING_LITERAL }, &idx)) == text_literal::PARSING_FAILED);
	check(idx, 1);
}

<* Decode the adjacent string tokens `toks` (bytes) of kinds `ids`, all at offset 0 of one source. *>
fn StringLiteral? decode(Compilation* comp, TokenId[] ids, String[] toks)
{
	StringPiece[16] pieces;
	for (sz i = 0; i < ids.len; i++)
	{
		pieces[i] = { .id = ids[i], .bytes = toks[i], .loc = loc_in(comp, toks[i], 0) };
	}
	sz idx;
	StringRun run = text_literal_semantics::string_run(ids, &idx)!!;
	check(run.len, ids.len);
	return text_literal_semantics::string_literal(comp, pieces[:ids.len], run.kind);
}

fn void check_bytes(Compilation* comp, StringLiteral s, char[] expected)
{
	char[] got = s.val.to_bytes(comp);
	check(got.len, expected.len);
	foreach (i, c : expected) check(got[i], c);
	Type t = s.qt.get_type(comp);
	assert(t.tag == ARRAY);
	check(t.array.len.len, (ulong)expected.len / s.char_width.size);
}

fn String printed(Compilation* comp, DString* out, StringLiteral s)
{
	out.clear();
	text_literal_semantics::print_string(s.val.to_bytes(comp), s.qt, comp, *out, BARE);
	return out.str_view();
}

fn void string_literals() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		StringLiteral s = decode(comp, { STRING_LITERAL }, { "\"abc\"" })!!;
		assert(s.kind == CHAR && s.char_width == ONE);
		assert(s.qt.get_type(comp).array.elem == type_store::CHAR);
		check_bytes(comp, s, "abc\0");
		// u"a" u"bc": 4 u16 units (wide strings.c E).
		s = decode(comp, { STRING_LITERAL_UTF_16, STRING_LITERAL_UTF_16 }, { "u\"a\"", "u\"bc\"" })!!;
		check_bytes(comp, s, (char[]){ 'a', 0, 'b', 0, 'c', 0, 0, 0 });
		// U"A" "BC": 4 u32 units (F).
		s = decode(comp, { STRING_LITERAL_UTF_32, STRING_LITERAL }, { "U\"A\"", "\"BC\"" })!!;
		assert(s.kind == UTF_32 && s.qt.get_type(comp).array.elem == comp.type_store.uint_least32_t);
		check_bytes(comp, s, (char[]){ 'A', 0, 0, 0, 'B', 0, 0, 0, 'C', 0, 0, 0, 0, 0, 0, 0 });
		// u"🤗" / u"\U0001F917": surrogate pair (G, H).
		s = decode(comp, { STRING_LITERAL_UTF_16 }, { "u\"\xF0\x9F\xA4\x97\"" })!!;
		check_bytes(comp, s, (char[]){ 0x3E, 0xD8, 0x17, 0xDD, 0, 0 });
		s = decode(comp, { STRING_LITERAL_UTF_16 }, { "u\"\\U0001F917\"" })!!;
		check_bytes(comp, s, (char[]){ 0x3E, 0xD8, 0x17, 0xDD, 0, 0 });
		// U"🤗" (I), u8"🤗" / u8"\U0001F917" (J, K).
		s = decode(comp, { STRING_LITERAL_UTF_32 }, { "U\"\xF0\x9F\xA4\x97\"" })!!;
		check_bytes(comp, s, (char[]){ 0x17, 0xF9, 0x01, 0, 0, 0, 0, 0 });
		s = decode(comp, { STRING_LITERAL_UTF_8 }, { "u8\"\xF0\x9F\xA4\x97\"" })!!;
		check_bytes(comp, s, "\xF0\x9F\xA4\x97\0");
		assert(s.qt.get_type(comp).array.elem == type_store::UCHAR); // C23: char8_t
		s = decode(comp, { STRING_LITERAL_UTF_8 }, { "u8\"\\U0001F917\"" })!!;
		check_bytes(comp, s, "\xF0\x9F\xA4\x97\0");
		// "word" u"" "a": 6 u16 units (P). The UTF-8 run of the third piece is
		// appended (Zig would transcode it over the first unit; see the module header).
		s = decode(comp, { STRING_LITERAL, STRING_LITERAL_UTF_16, STRING_LITERAL }, { "\"word\"", "u\"\"", "\"a\"" })!!;
		check_bytes(comp, s, (char[]){ 'w', 0, 'o', 0, 'r', 0, 'd', 0, 'a', 0, 0, 0 });
		// L"" with escapes: value truncated to the unit; wchar_t is 4 bytes.
		s = decode(comp, { STRING_LITERAL_WIDE }, { "L\"\\x41\\u00e9\"" })!!;
		check_bytes(comp, s, (char[]){ 0x41, 0, 0, 0, 0xE9, 0, 0, 0, 0, 0, 0, 0 });
		// A UCN in a plain string is UTF-8 encoded.
		s = decode(comp, { STRING_LITERAL }, { "\"\\u00e9\"" })!!;
		check_bytes(comp, s, "\xC3\xA9\0");
		check(d.messages.len(), 0);

		// _Static_assert messages (wide strings.c lines 51-52): print as UTF-8.
		DString out;
		out.init(comp.gpa);
		defer out.free();
		s = decode(comp, { STRING_LITERAL_UTF_16 }, { "u\"\xF0\x9F\x98\xAC\\U0001f62c\"" })!!;
		test::eq(printed(comp, &out, s), "\xF0\x9F\x98\xAC\xF0\x9F\x98\xAC");
		s = decode(comp, { STRING_LITERAL_UTF_32 }, { "U\"\xF0\x9F\x98\xAC\\U0001f62c\"" })!!;
		test::eq(printed(comp, &out, s), "\xF0\x9F\x98\xAC\xF0\x9F\x98\xAC");
		check(d.messages.len(), 0);
	};
}

fn void improperly_encoded() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		// One piece: the raw bytes are kept (with a -Winvalid-source-encoding warning).
		StringLiteral s = decode(comp, { STRING_LITERAL }, { "\"a\xFF\"" })!!;
		check_bytes(comp, s, "a\xFF\0");
		check(d.messages.len(), 1);
		assert(d.messages[0].effective_kind == WARNING);

		// concat improperly encoded strings.c: L"" "\xFF" -> error at the second
		// token (col 14), and the literal fails.
		String text = "int *p = L\"\" \"\xFF\";\n";
		StringPiece[2] pieces = {
			{ .id = STRING_LITERAL_WIDE, .bytes = text[9:3], .loc = loc_in(comp, text, 9, "concat.c") },
			{ .id = STRING_LITERAL, .bytes = text[13:3] },
		};
		pieces[1].loc = pieces[0].loc;
		pieces[1].loc.byte_offset = 13;
		assert(@catch(text_literal_semantics::string_literal(comp, &pieces, WIDE)) == text_literal::PARSING_FAILED);
		check(d.messages.len(), 2);
		test::eq(d.messages[1].text, "illegal character encoding in character literal");
		assert(d.messages[1].effective_kind == ERROR);
		check(d.messages[1].location.col, 14);
	};
}
