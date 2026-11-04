// Tests for aro::text_literal (plan 11.3 `text-decoding`): Kind
// classification/widths/types, the escape / UCN / encoding decoder
// (TextLiteralParser.next) and character constants (TextLiteralParser.parse).
//
// Provenance (no Zig executable was run):
// - "fixture <file>:<line>" vectors reproduce a literal from test/cases/<file>
//   on a line by itself at the same column (same bytes before it), so the
//   expected diagnostic text and column are copied from that fixture's
//   manifest; values are those the fixture's _Static_asserts (or
//   -Wconstant-conversion note) imply.
// - "source-derived" vectors are hand-derived from
//   src/aro/Tokenizer/text_literal.zig, Compilation.zig (wcharMax) and the
//   target data (x86_64-linux: wchar_t = int; x86_64-windows: unsigned short).
module text_literal_tests;
import aro::text_literal, aro::compilation, aro::diagnostics, aro::source, aro::target, aro::type_store, aro::lang_opts, aro::tokenizer;
import std::io, std::core::mem::allocators, std::collections::list;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

const Host HOST = { X86_64, LINUX, GNU };

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

<*
 A parser for the literal token `tok`, which starts at byte `col - 1` of a
 one-line source whose text is `prefix` (padding) followed by `tok`.
*>
fn TextLiteralParser make_parser(Compilation* comp, String prefix, String tok, TextLiteralKind kind)
{
	DString line;
	line.init(comp.gpa);
	defer line.free();
	line.append(prefix);
	line.append(tok);
	line.append("\n");
	// Sources are looked up by path, so every literal gets its own.
	char[32] path_buf;
	String path = (String)io::bprintf(&path_buf, "lit%d.c", comp.sources.len())!!;
	Source src = comp.add_source_from_buffer(path, line.str_view())!!;
	Location loc = { .id = src.id, .byte_offset = (uint)prefix.len, .line = 1 };
	return text_literal::text_parser(comp, kind.content_slice(tok), kind, kind.max_codepoint(comp), loc, {});
}

<* `col - 1` spaces, so the token starts at column `col`. *>
fn String pad(uint col)
{
	const String SPACES = "                                                                ";
	return SPACES[:col - 1];
}

fn CharLiteralValue char_lit(Compilation* comp, uint col, String tok, TextLiteralKind kind)
{
	TextLiteralParser p = make_parser(comp, pad(col), tok, kind);
	return p.parse()!!;
}

fn void expect_unsigned(CharLiteralValue v, uint expected)
{
	assert(!v.is_signed);
	check(v.unsigned, expected);
}

<* Expect message `idx` to have `text`, effective kind `kind` and column `col`. *>
fn void expect_msg(Diagnostics* d, sz idx, String text, MessageKind kind, uint col)
{
	assert(d.messages.len() > idx, "missing message %d (%s)", idx, text);
	test::eq(d.messages[idx].text, text);
	assert(d.messages[idx].effective_kind == kind, "kind of '%s'", text);
	check(d.messages[idx].location.col, col);
}

fn void expect_opt(Diagnostics* d, sz idx, Option opt)
{
	assert(d.messages[idx].has_opt && d.messages[idx].opt == opt);
}

<*
 Decode a string-literal token with `next` the way Parser.zig stringLiteral
 does (max_codepoint 0x10FFFF); append the items to `items`.
*>
fn void decode(Compilation* comp, uint col, String tok, TextLiteralKind kind, List{TextLiteralItem}* items, bool incorrect_encoding_is_error = false)
{
	TextLiteralParser p = make_parser(comp, pad(col), tok, kind);
	p.incorrect_encoding_is_error = incorrect_encoding_is_error;
	p.max_codepoint = 0x10FFFF; // Parser.zig stringLiteral
	TextLiteralItem item;
	while (p.next(&item)!!) items.push(item);
}

// ---------------------------------------------------------------------------
// Kind (source-derived)

fn void kind_classify_and_concat() @test
{
	assert(text_literal::classify(STRING_LITERAL, STRING_LITERAL)!! == CHAR);
	assert(text_literal::classify(STRING_LITERAL_UTF_8, STRING_LITERAL)!! == UTF_8);
	assert(text_literal::classify(STRING_LITERAL_WIDE, STRING_LITERAL)!! == WIDE);
	assert(text_literal::classify(STRING_LITERAL_UTF_16, STRING_LITERAL)!! == UTF_16);
	assert(text_literal::classify(STRING_LITERAL_UTF_32, STRING_LITERAL)!! == UTF_32);
	assert(text_literal::classify(UNTERMINATED_STRING_LITERAL, STRING_LITERAL)!! == UNTERMINATED);
	assert(@catch(text_literal::classify(CHAR_LITERAL, STRING_LITERAL)) == text_literal::NOT_A_TEXT_LITERAL);

	assert(text_literal::classify(CHAR_LITERAL, CHAR_LITERAL)!! == CHAR);
	assert(text_literal::classify(CHAR_LITERAL_UTF_8, CHAR_LITERAL)!! == UTF_8);
	assert(text_literal::classify(CHAR_LITERAL_WIDE, CHAR_LITERAL)!! == WIDE);
	assert(text_literal::classify(CHAR_LITERAL_UTF_16, CHAR_LITERAL)!! == UTF_16);
	assert(text_literal::classify(CHAR_LITERAL_UTF_32, CHAR_LITERAL)!! == UTF_32);
	assert(@catch(text_literal::classify(EMPTY_CHAR_LITERAL, CHAR_LITERAL)) == text_literal::NOT_A_TEXT_LITERAL);
	assert(@catch(text_literal::classify(UNTERMINATED_CHAR_LITERAL, CHAR_LITERAL)) == text_literal::NOT_A_TEXT_LITERAL);
	assert(@catch(text_literal::classify(STRING_LITERAL, CHAR_LITERAL)) == text_literal::NOT_A_TEXT_LITERAL);

	assert(TextLiteralKind.CHAR.concat(UTF_16)!! == UTF_16);
	assert(TextLiteralKind.UTF_32.concat(CHAR)!! == UTF_32);
	assert(TextLiteralKind.WIDE.concat(WIDE)!! == WIDE);
	assert(TextLiteralKind.UNTERMINATED.concat(UTF_8)!! == UNTERMINATED);
	assert(TextLiteralKind.UTF_8.concat(UNTERMINATED)!! == UNTERMINATED);
	// fixture wide strings.c:24 (u"a" U"b": unsupported string literal concatenation)
	assert(@catch(TextLiteralKind.UTF_16.concat(UTF_32)) == text_literal::CANNOT_CONCAT);
	assert(@catch(TextLiteralKind.WIDE.concat(UTF_8)) == text_literal::CANNOT_CONCAT);
}

fn void kind_content_slice() @test
{
	test::eq(TextLiteralKind.CHAR.content_slice("'ab'"), "ab");
	test::eq(TextLiteralKind.WIDE.content_slice("L\"xyz\""), "xyz");
	test::eq(TextLiteralKind.UTF_8.content_slice("u8\"q\""), "q");
	test::eq(TextLiteralKind.UTF_16.content_slice("u''"), "");
	test::eq(TextLiteralKind.UTF_32.content_slice("U'\\n'"), "\\n");
}

fn void kind_limits_and_types() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		check(TextLiteralKind.CHAR.max_codepoint(comp), 0x7F);
		check(TextLiteralKind.UTF_8.max_codepoint(comp), 0x7F);
		check(TextLiteralKind.WIDE.max_codepoint(comp), 0x10FFFF); // min(0x10FFFF, INT_MAX)
		check(TextLiteralKind.UTF_16.max_codepoint(comp), 0xFFFF);
		check(TextLiteralKind.UTF_32.max_codepoint(comp), 0x10FFFF);
		check(TextLiteralKind.CHAR.max_int(comp), 0xFF);
		check(TextLiteralKind.UTF_8.max_int(comp), 0xFF);
		check(TextLiteralKind.WIDE.max_int(comp), 0x7FFF_FFFF);
		check(TextLiteralKind.UTF_16.max_int(comp), 0xFFFF);
		check(TextLiteralKind.UTF_32.max_int(comp), 0xFFFF_FFFF);

		assert(TextLiteralKind.CHAR.char_literal_type(comp) == type_store::INT);
		assert(TextLiteralKind.UTF_8.char_literal_type(comp) == type_store::UCHAR);
		assert(TextLiteralKind.WIDE.char_literal_type(comp) == comp.type_store.wchar);
		assert(TextLiteralKind.UTF_16.char_literal_type(comp) == comp.type_store.uint_least16_t);
		assert(TextLiteralKind.UTF_32.char_literal_type(comp) == comp.type_store.uint_least32_t);
		// fixture wide character constants.c:16-17: sizeof(u'a') == 2, sizeof(U'a') == 4
		check(TextLiteralKind.UTF_16.char_literal_type(comp).sizeof(comp), 2);
		check(TextLiteralKind.UTF_32.char_literal_type(comp).sizeof(comp), 4);

		assert(TextLiteralKind.CHAR.char_unit_size(comp) == ONE);
		assert(TextLiteralKind.UTF_8.char_unit_size(comp) == ONE);
		assert(TextLiteralKind.UTF_16.char_unit_size(comp) == TWO);
		assert(TextLiteralKind.UTF_32.char_unit_size(comp) == FOUR);
		assert(TextLiteralKind.WIDE.char_unit_size(comp) == FOUR);
		check(TextLiteralKind.WIDE.internal_storage_alignment(comp), 4);
		check(TextLiteralKind.UTF_16.internal_storage_alignment(comp), 2);
		check(TextLiteralKind.CHAR.internal_storage_alignment(comp), 1);

		assert(TextLiteralKind.CHAR.element_type(comp) == type_store::CHAR);
		assert(TextLiteralKind.UTF_8.element_type(comp) == type_store::CHAR); // gnu17: no char8_t
		assert(TextLiteralKind.WIDE.element_type(comp) == comp.type_store.wchar);
		comp.langopts.standard = C23;
		assert(TextLiteralKind.UTF_8.element_type(comp) == type_store::UCHAR);
	};
	@with_comp("x86_64-windows-msvc"; Compilation* comp, Diagnostics* d)
	{
		check(TextLiteralKind.WIDE.max_codepoint(comp), 0xFFFF); // wchar_t = unsigned short
		check(TextLiteralKind.WIDE.max_int(comp), 0xFFFF);
		assert(TextLiteralKind.WIDE.char_unit_size(comp) == TWO);
		check(TextLiteralKind.WIDE.internal_storage_alignment(comp), 2);
	};
}

// ---------------------------------------------------------------------------
// Character constants: test/cases/wide character constants.c
// (args = -Wfour-char-constants -Wno-c23-extensions; default -std = gnu17)

fn void wide_character_constants_fixture() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		d.set("four-char-constants", WARNING)!!;
		d.set("c23-extensions", OFF)!!;

		// :8 u'U+FFFF' + u'U+10001' -> 0xFFFF + 0x10001 = 131072 (constant-conversion note)
		expect_unsigned(char_lit(comp, 20, "u'\xEF\xBF\xBF'", UTF_16), 0xFFFF);
		expect_unsigned(char_lit(comp, 27, "u'\xF0\x90\x80\x81'", UTF_16), 0x10001);
		expect_msg(d, 0, "character too large for enclosing character literal type", ERROR, 27);
		// :9 L'ab' == 'b'
		expect_unsigned(char_lit(comp, 16, "L'ab'", WIDE), 'b');
		expect_msg(d, 1, "wide character literals may not contain multiple characters", ERROR, 16);
		// :10
		expect_unsigned(char_lit(comp, 16, "U'ab'", UTF_32), 'b');
		expect_msg(d, 2, "Unicode character literals may not contain multiple characters", ERROR, 16);
		// :11 '\1' == 0x01
		expect_unsigned(char_lit(comp, 16, "'\\1'", CHAR), 1);
		// :13 '\1\2\3\4' == 0x01020304
		expect_unsigned(char_lit(comp, 16, "'\\1\\2\\3\\4'", CHAR), 0x01020304);
		expect_msg(d, 3, "multi-character character constant", WARNING, 16);
		expect_opt(d, 3, FOUR_CHAR_CONSTANTS);
		// :18 U'\xFFFFFFFF' fits; :19 u'\xFFFFFFFF' does not
		expect_unsigned(char_lit(comp, 19, "U'\\xFFFFFFFF'", UTF_32), 0xFFFF_FFFF);
		expect_unsigned(char_lit(comp, 19, "u'\\xFFFFFFFF'", UTF_16), 0);
		expect_msg(d, 4, "escape sequence out of range", ERROR, 21);
		// :20-23
		expect_unsigned(char_lit(comp, 19, "U'\xF0\x9D\x92\xB5'", UTF_32), 0x1D4B5);
		char_lit(comp, 19, "u'\xF0\x9D\x92\xB5'", UTF_16);
		expect_msg(d, 5, "character too large for enclosing character literal type", ERROR, 19);
		expect_unsigned(char_lit(comp, 19, "U'\xE2\x84\xA4'", UTF_32), 0x2124);
		expect_unsigned(char_lit(comp, 19, "u'\xE2\x84\xA4'", UTF_16), 0x2124);
		// :24 U'\UFFFFFFFF'
		char_lit(comp, 19, "U'\\UFFFFFFFF'", UTF_32);
		expect_msg(d, 6, "invalid universal character", ERROR, 20);
		// :25 u'\U0001D4B5'
		char_lit(comp, 19, "u'\\U0001D4B5'", UTF_16);
		expect_msg(d, 7, "character too large for enclosing character literal type", ERROR, 19);
		// :26-27
		char_lit(comp, 19, "U'ab'", UTF_32);
		expect_msg(d, 8, "Unicode character literals may not contain multiple characters", ERROR, 19);
		char_lit(comp, 19, "u'ab'", UTF_16);
		expect_msg(d, 9, "Unicode character literals may not contain multiple characters", ERROR, 19);
		// :28 '\777' (511 > 0xFF); :29 L'\777' fits a 32-bit wchar_t
		char_lit(comp, 19, "'\\777'", CHAR);
		expect_msg(d, 10, "escape sequence out of range", ERROR, 20);
		expect_unsigned(char_lit(comp, 13, "L'\\777'", WIDE), 0x1FF);
		check(d.messages.len(), 11);

		// :32-37 (u8; the C23-extension warning is off)
		char_lit(comp, 9, "u8'ab'", UTF_8);
		expect_msg(d, 11, "Unicode character literals may not contain multiple characters", ERROR, 9);
		expect_unsigned(char_lit(comp, 9, "u8'\\xFF'", UTF_8), 0xFF);
		char_lit(comp, 9, "u8'\xE2\x88\xA2'", UTF_8);
		expect_msg(d, 12, "character too large for enclosing character literal type", ERROR, 9);
		char_lit(comp, 9, "u8'\\u0041'", UTF_8);
		expect_msg(d, 13, "character 'A' cannot be specified by a universal character name", ERROR, 9);
		expect_unsigned(char_lit(comp, 9, "u8'\\x41'", UTF_8), 0x41);
		expect_unsigned(char_lit(comp, 9, "u8'\\u0024'", UTF_8), '$');
		check(d.messages.len(), 14);

		// :38-41
		char_lit(comp, 9, "'\\x'", CHAR);
		expect_msg(d, 14, "\\x used with no following hex digits", ERROR, 9);
		char_lit(comp, 9, "'\\xg'", CHAR); // the multichar warning is suppressed after the error
		expect_msg(d, 15, "\\x used with no following hex digits", ERROR, 9);
		expect_unsigned(char_lit(comp, 9, "'\\8'", CHAR), '8');
		expect_msg(d, 16, "unknown escape sequence '\\8'", WARNING, 10);
		expect_opt(d, 16, UNKNOWN_ESCAPE_SEQUENCE);
		expect_unsigned(char_lit(comp, 9, "'\\\t'", CHAR), '\t');
		expect_msg(d, 17, "unknown escape sequence '\\x09'", WARNING, 10);
		// :42-45 GNU escapes, the pedantic warning is off by default
		expect_unsigned(char_lit(comp, 16, "'\\('", CHAR), '(');
		expect_unsigned(char_lit(comp, 16, "'\\['", CHAR), '[');
		expect_unsigned(char_lit(comp, 16, "'\\{'", CHAR), '{');
		expect_unsigned(char_lit(comp, 16, "'\\%'", CHAR), '%');
		check(d.messages.len(), 18);
		// :46-47
		char_lit(comp, 9, "'\\u'", CHAR);
		expect_msg(d, 18, "\\u used with no following hex digits", ERROR, 9);
		char_lit(comp, 9, "'\\U'", CHAR);
		expect_msg(d, 19, "\\U used with no following hex digits", ERROR, 9);
		// :48-50 #pragma GCC diagnostic warning "-Wpedantic"
		d.set("pedantic", WARNING)!!;
		expect_unsigned(char_lit(comp, 9, "'abc\\E'", CHAR), 0x6162631B);
		expect_msg(d, 20, "use of non-standard escape character '\\E'", WARNING, 13);
		expect_msg(d, 21, "multi-character character constant", WARNING, 9);
		d.set("pedantic", OFF)!!;
		// :51
		expect_unsigned(char_lit(comp, 9, "'ABC\\D'", CHAR), 0x41424344);
		expect_msg(d, 22, "unknown escape sequence '\\D'", WARNING, 13);
		expect_msg(d, 23, "multi-character character constant", WARNING, 9);
		check(d.messages.len(), 24);
	};
}

// test/cases/u8 character constant.c (no args, gnu17)
fn void u8_character_constant_fixture() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		expect_unsigned(char_lit(comp, 25, "u8'A'", UTF_8), 'A');
		expect_msg(d, 0, "UTF-8 character literal is a C23 extension", WARNING, 25);
		expect_opt(d, 0, C23_EXTENSIONS);
		d.set("c23-extensions", OFF)!!; // :3 #pragma GCC diagnostic ignored
		expect_unsigned(char_lit(comp, 16, "u8'\\xff'", UTF_8), 0xFF);
		char_lit(comp, 26, "u8'\xE2\x88\xA2'", UTF_8);
		expect_msg(d, 1, "character too large for enclosing character literal type", ERROR, 26);
		char_lit(comp, 26, "u8'\xC2\xA3'", UTF_8);
		expect_msg(d, 2, "character too large for enclosing character literal type", ERROR, 26);
		char_lit(comp, 26, "u8'AA'", UTF_8);
		expect_msg(d, 3, "Unicode character literals may not contain multiple characters", ERROR, 26);
		check(d.messages.len(), 4);
		// In C23 there is no extension warning (source-derived).
		comp.langopts.standard = C23;
		d.set("c23-extensions", WARNING)!!;
		expect_unsigned(char_lit(comp, 1, "u8'A'", UTF_8), 'A');
		check(d.messages.len(), 4);
	};
}

// test/cases/strings.c (no args, gnu17)
fn void strings_fixture() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		List{TextLiteralItem} items;
		items.init(comp.gpa);
		defer items.free();

		// :1 "\n"
		decode(comp, 25, "\"\\n\"", CHAR, &items);
		check(items.len(), 1);
		assert(items[0].tag == VALUE);
		check(items[0].value, '\n');
		// :2 "abc\x606262 " -> escape sequence out of range
		items.clear();
		decode(comp, 25, "\"abc\\x606262 \"", CHAR, &items);
		expect_msg(d, 0, "escape sequence out of range", ERROR, 29);
		check(items.len(), 3);
		assert(items[0].tag == UTF8_TEXT);
		test::eq(items[0].bytes, "abc");
		assert(items[1].tag == VALUE);
		check(items[1].value, 0);
		test::eq(items[2].bytes, " ");
		// :3 "\000062" -> octal stops after 3 digits
		items.clear();
		decode(comp, 19, "\"\\000062\"", CHAR, &items);
		check(items.len(), 2);
		check(items[0].value, 0);
		test::eq(items[1].bytes, "062");
		// :4 "\U00110000"
		items.clear();
		decode(comp, 19, "\"\\U00110000\"", CHAR, &items);
		check(items.len(), 0);
		expect_msg(d, 1, "invalid universal character", ERROR, 19);
		// :5 "\u0062"
		decode(comp, 19, "\"\\u0062\"", CHAR, &items);
		expect_msg(d, 2, "character 'b' cannot be specified by a universal character name", ERROR, 19);
		// :7 'abcde'
		expect_unsigned(char_lit(comp, 9, "'abcde'", CHAR), 0x62636465);
		expect_msg(d, 3, "multi-character character constant", WARNING, 9);
		expect_opt(d, 3, MULTICHAR);
		expect_msg(d, 4, "character constant too long for its type", WARNING, 9);
		// :9-11 surrogates and > U+10FFFF
		decode(comp, 19, "\"\\uD800\"", CHAR, &items);
		expect_msg(d, 5, "invalid universal character", ERROR, 19);
		decode(comp, 19, "\"\\U0000DFFF\"", CHAR, &items);
		expect_msg(d, 6, "invalid universal character", ERROR, 19);
		decode(comp, 19, "\"\\UFFFFFFFF\"", CHAR, &items);
		expect_msg(d, 7, "invalid universal character", ERROR, 19);
		// :12 "\u0060" ('`' is allowed)
		items.clear();
		decode(comp, 19, "\"\\u0060\"", CHAR, &items);
		check(items.len(), 1);
		assert(items[0].tag == CODEPOINT);
		check(items[0].value, '`');
		check(d.messages.len(), 8);
		// :14-15 with -Wpedantic: "aa<U+30A1>\e[1;"
		d.set("pedantic", WARNING)!!;
		items.clear();
		decode(comp, 19, "\"aa\xE3\x82\xA1\\e[1;\"", CHAR, &items);
		expect_msg(d, 8, "use of non-standard escape character '\\e'", WARNING, 23);
		check(items.len(), 3);
		test::eq(items[0].bytes, "aa\xE3\x82\xA1");
		check(items[1].value, 0x1B);
		test::eq(items[2].bytes, "[1;");
		check(d.messages.len(), 9);
	};
}

// test/cases/wide strings.c (args = -std=c23)
fn void wide_strings_fixture() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		comp.langopts.standard = C23;
		List{TextLiteralItem} items;
		items.init(comp.gpa);
		defer items.free();

		// :35 u"\U0001F917" is one codepoint (two UTF-16 units)
		decode(comp, 16, "u\"\\U0001F917\"", UTF_16, &items);
		check(items.len(), 1);
		assert(items[0].tag == CODEPOINT);
		check(items[0].value, 0x1F917);
		// :47 u"\xFFFFF"
		items.clear();
		decode(comp, 16, "u\"\\xFFFFF\"", UTF_16, &items);
		expect_msg(d, 0, "escape sequence out of range", ERROR, 18);
		// :49 u8"\xFFF"
		decode(comp, 15, "u8\"\\xFFF\"", UTF_8, &items);
		expect_msg(d, 1, "escape sequence out of range", ERROR, 18);
		// :54 "\u0020\u0020\u0020\u0020\xFFFFFFFF" (UCN basic chars are fine in C23)
		items.clear();
		decode(comp, 14, "\"\\u0020\\u0020\\u0020\\u0020\\xFFFFFFFF\"", CHAR, &items);
		expect_msg(d, 2, "escape sequence out of range", ERROR, 39);
		check(items.len(), 5);
		check(items[0].value, ' ');
		check(d.messages.len(), 3);
		// :62 U"abc\ndef\xFFghi": 11 code units
		items.clear();
		decode(comp, 16, "U\"abc\\ndef\\xFFghi\"", UTF_32, &items);
		check(items.len(), 5);
		check(items[1].value, '\n');
		check(items[3].value, 0xFF);
		test::eq(items[4].bytes, "ghi");
		check(d.messages.len(), 3);
	};
}

// test/cases/concat improperly encoded strings.c: L"" "\xFF" (ISO-8859-1 byte)
fn void improper_encoding() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		List{TextLiteralItem} items;
		items.init(comp.gpa);
		defer items.free();

		// fixture: concatenated into a wide string -> always an error, decoding continues
		decode(comp, 14, "\"\xFF\"", CHAR, &items, incorrect_encoding_is_error: true);
		expect_msg(d, 0, "illegal character encoding in character literal", ERROR, 14);
		check(items.len(), 1);
		assert(items[0].tag == IMPROPERLY_ENCODED);
		test::eq(items[0].bytes, "\xFF");

		// source-derived: a plain string warns [-Winvalid-source-encoding]
		items.clear();
		decode(comp, 1, "\"a\xFF\"", CHAR, &items);
		expect_msg(d, 1, "illegal character encoding in character literal", WARNING, 1);
		expect_opt(d, 1, INVALID_SOURCE_ENCODING);
		check(items.len(), 1);
		assert(items[0].tag == IMPROPERLY_ENCODED);

		// source-derived: a non-char literal errs and stops
		items.clear();
		decode(comp, 1, "u\"\xFF\\n\"", UTF_16, &items);
		expect_msg(d, 2, "illegal character encoding in character literal", ERROR, 1);
		check(items.len(), 0);

		// source-derived: '\xFF'-byte char constant -> warning, bytes are the chars
		CharLiteralValue v = char_lit(comp, 1, "'\xFF'", CHAR);
		expect_msg(d, 3, "illegal character encoding in character literal", WARNING, 1);
		assert(v.is_signed); // x86_64 char is signed
		check(v.signed, -1);

		// source-derived: diagnose_incorrect_encoding = false is silent
		TextLiteralParser p = make_parser(comp, "", "\"\xC0\x80\"", CHAR);
		p.diagnose_incorrect_encoding = false;
		TextLiteralItem item;
		assert(p.next(&item)!!);
		assert(item.tag == IMPROPERLY_ENCODED);
		check(d.messages.len(), 4);
	};
}

// ---------------------------------------------------------------------------
// Source-derived vectors

fn void signedness_and_values() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		CharLiteralValue v = char_lit(comp, 1, "'\\xFF'", CHAR);
		assert(v.is_signed);
		check(v.signed, -1);
		v = char_lit(comp, 1, "'\\x80'", CHAR);
		check(v.signed, -128);
		expect_unsigned(char_lit(comp, 1, "'\\x7F'", CHAR), 0x7F);
		expect_unsigned(char_lit(comp, 1, "'a'", CHAR), 'a');
		expect_unsigned(char_lit(comp, 1, "''", CHAR), 0);
		// the simple escapes
		expect_unsigned(char_lit(comp, 1, "'\\''", CHAR), '\'');
		expect_unsigned(char_lit(comp, 1, "'\\\"'", CHAR), '"');
		expect_unsigned(char_lit(comp, 1, "'\\\\'", CHAR), '\\');
		expect_unsigned(char_lit(comp, 1, "'\\?'", CHAR), '?');
		expect_unsigned(char_lit(comp, 1, "'\\a'", CHAR), 7);
		expect_unsigned(char_lit(comp, 1, "'\\b'", CHAR), 8);
		expect_unsigned(char_lit(comp, 1, "'\\f'", CHAR), 0x0C);
		expect_unsigned(char_lit(comp, 1, "'\\n'", CHAR), 0x0A);
		expect_unsigned(char_lit(comp, 1, "'\\r'", CHAR), 0x0D);
		expect_unsigned(char_lit(comp, 1, "'\\t'", CHAR), 0x09);
		expect_unsigned(char_lit(comp, 1, "'\\v'", CHAR), 0x0B);
		expect_unsigned(char_lit(comp, 1, "'\\e'", CHAR), 0x1B);
		// multichar: no sign extension; two chars keep the last byte order
		expect_unsigned(char_lit(comp, 1, "'\\xFF\\xFF'", CHAR), 0xFFFF);
		// wide/utf literals are never sign-converted
		expect_unsigned(char_lit(comp, 1, "L'\\xFF'", WIDE), 0xFF);
		check(d.messages.len(), 1); // the 'ab'-style multichar warning for '\xFF\xFF'
		expect_msg(d, 0, "multi-character character constant", WARNING, 1);

		comp.langopts.set_char_signedness(UNSIGNED);
		expect_unsigned(char_lit(comp, 1, "'\\xFF'", CHAR), 0xFF);
	};
	@with_comp("aarch64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		expect_unsigned(char_lit(comp, 1, "'\\xFF'", CHAR), 0xFF); // char is unsigned
	};
}

fn void ucn_boundaries() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		// '$', '@', '`' are allowed before C23
		expect_unsigned(char_lit(comp, 1, "U'\\u0040'", UTF_32), '@');
		// 0xA0 is the first codepoint that is never restricted
		expect_unsigned(char_lit(comp, 1, "U'\\u00A0'", UTF_32), 0xA0);
		expect_unsigned(char_lit(comp, 1, "U'\\U0010FFFF'", UTF_32), 0x10FFFF);
		expect_unsigned(char_lit(comp, 1, "U'\\uD7FF'", UTF_32), 0xD7FF);
		expect_unsigned(char_lit(comp, 1, "U'\\uE000'", UTF_32), 0xE000);
		check(d.messages.len(), 0);
		// control characters
		char_lit(comp, 1, "U'\\u009F'", UTF_32);
		expect_msg(d, 0, "universal character name refers to a control character", ERROR, 1);
		char_lit(comp, 1, "U'\\u001F'", UTF_32);
		expect_msg(d, 1, "universal character name refers to a control character", ERROR, 1);
		// 0x7F is a "basic" char formatted as x7f
		char_lit(comp, 1, "U'\\u007F'", UTF_32);
		expect_msg(d, 2, "character 'x7f' cannot be specified by a universal character name", ERROR, 1);
		// incomplete UCN, short then non-hex
		char_lit(comp, 1, "U'\\u12'", UTF_32);
		expect_msg(d, 3, "incomplete universal character name", ERROR, 1);
		char_lit(comp, 1, "U'\\U1234567g'", UTF_32);
		expect_msg(d, 4, "incomplete universal character name", ERROR, 1);
		// invalid UCN offset includes the prefix: L'\uDFFF' -> column 2
		char_lit(comp, 1, "L'\\uDFFF'", WIDE);
		expect_msg(d, 5, "invalid universal character", ERROR, 2);
		// u8 prefix is 2 bytes
		d.set("c23-extensions", OFF)!!;
		char_lit(comp, 1, "u8'\\uDC00'", UTF_8);
		expect_msg(d, 6, "invalid universal character", ERROR, 3);
		check(d.messages.len(), 7);

		// C23: basic and control chars are accepted silently
		comp.langopts.standard = C23;
		expect_unsigned(char_lit(comp, 1, "U'\\u0041'", UTF_32), 'A');
		expect_unsigned(char_lit(comp, 1, "U'\\u0001'", UTF_32), 1);
		check(d.messages.len(), 7);

		// C89: UCNs warn [-Wunicode] (after the basic-char check)
		comp.langopts.standard = C89;
		expect_unsigned(char_lit(comp, 1, "U'\\u00E9'", UTF_32), 0xE9);
		expect_msg(d, 7, "universal character names are only valid in C99 or later", WARNING, 1);
		expect_opt(d, 7, UNICODE);
		check(d.messages.len(), 8);
	};
	@with_comp("x86_64-windows-msvc"; Compilation* comp, Diagnostics* d)
	{
		// 16-bit wchar_t limits codepoints and escapes to 0xFFFF
		char_lit(comp, 1, "L'\\U00010000'", WIDE);
		expect_msg(d, 0, "character too large for enclosing character literal type", ERROR, 1);
		expect_unsigned(char_lit(comp, 1, "L'\\xFFFF'", WIDE), 0xFFFF);
		char_lit(comp, 1, "L'\\x10000'", WIDE);
		expect_msg(d, 1, "escape sequence out of range", ERROR, 3);
		check(d.messages.len(), 2);
	};
}

fn void escape_overflow_and_errors_once() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		// hex shl overflow (9 significant digits) even for UTF-32
		char_lit(comp, 1, "U'\\x100000000'", UTF_32);
		expect_msg(d, 0, "escape sequence out of range", ERROR, 3);
		// leading zeros do not overflow
		expect_unsigned(char_lit(comp, 1, "U'\\x0000000000041'", UTF_32), 0x41);
		// only one error per literal; warnings after an error are dropped too
		char_lit(comp, 1, "'\\x\\777\\q'", CHAR);
		expect_msg(d, 1, "\\x used with no following hex digits", ERROR, 1);
		check(d.messages.len(), 2);
		// unknown escape of a non-ASCII byte (deviation: Zig would trap)
		char_lit(comp, 1, "'\\\xC3'", CHAR);
		expect_msg(d, 2, "unknown escape sequence '\\xc3'", WARNING, 2);
	};
}

fn void utf8_helpers() @test
{
	assert(text_literal::utf8_validate(""));
	assert(text_literal::utf8_validate("abc\xC2\xA3\xE2\x82\xAC\xF0\x9F\xA4\x97"));
	assert(!text_literal::utf8_validate("\xC0\x80")); // overlong NUL
	assert(!text_literal::utf8_validate("\xE0\x80\x80")); // overlong
	assert(!text_literal::utf8_validate("\xED\xA0\x80")); // U+D800
	assert(!text_literal::utf8_validate("\xF4\x90\x80\x80")); // U+110000
	assert(!text_literal::utf8_validate("\x80"));
	assert(!text_literal::utf8_validate("\xE2\x82")); // truncated
	assert(!text_literal::utf8_validate("\xF8\x88\x80\x80\x80"));
	assert(text_literal::utf8_validate("\xF4\x8F\xBF\xBF")); // U+10FFFF

	String s = "a\xC2\xA3\xE2\x82\xAC\xF0\x9F\xA4\x97";
	sz i = 0;
	check(text_literal::utf8_decode_next(s, &i), 'a');
	check(text_literal::utf8_decode_next(s, &i), 0xA3);
	check(text_literal::utf8_decode_next(s, &i), 0x20AC);
	check(text_literal::utf8_decode_next(s, &i), 0x1F917);
	check(i, s.len);
}
