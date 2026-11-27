// Tests for aro::frontend::c3::lexer / tokens / symtab (port of c3c lexer.c).
// Expected token kinds and messages are read from c3c src/compiler/lexer.c.
module c3_lexer_tests;
import aro::frontend::c3::lexer, aro::frontend::c3::tokens, aro::frontend::c3::symtab, aro::frontend::c3::diagnostics;
import std::collections::list, std::core::mem::allocators, std::core::mem::alloc;

macro check(left, right)
{
	$if $defined((long)left):
		test::eq((long)left, (long)right);
	$else
		test::eq(left, right);
	$endif
}

struct Lexed
{
	TokenType type;
	String string;
	SourceSpan span;
	uint128 char_value;
	char width;
	ulong bytes_len;
	bool is_base64;
}

struct Fixture
{
	TrackingAllocator ta;
	Symtab symtab;
	Diagnostics diags;
	String source;
	Lexer lexer;
	List{Lexed} tokens;
	<* Owned copies of STRING contents (the lexer allocates them on `ta`). *>
	List{String} owned;
}

fn void Fixture.init(&self, String text)
{
	self.ta.init(mem);
	self.symtab.init(&self.ta);
	self.diags.init_list(&self.ta);
	self.diags.add_file("test.c3");
	self.source = lexer::clean_source(&self.ta, text)!!;
	self.lexer.init(&self.ta, &self.symtab, &self.diags, 0, self.source);
	self.tokens.init(&self.ta);
	self.owned.init(&self.ta);
	while (true)
	{
		self.lexer.next_token();
		Lexer* l = &self.lexer;
		Lexed t = { .type = l.token_type, .string = l.data.string, .span = l.tok_span, .char_value = l.data.char_value,
		            .width = l.data.width, .bytes_len = l.data.bytes_len, .is_base64 = l.data.is_base64 };
		if (t.type == STRING) self.owned.push(t.string);
		self.tokens.push(t);
		if (t.type == TokenType.EOF) break;
	}
}

fn void Fixture.free(&self)
{
	foreach (s : self.owned) alloc::free(&self.ta, s.ptr);
	self.owned.free();
	self.tokens.free();
	alloc::free(&self.ta, self.source.ptr);
	self.diags.free();
	self.symtab.free();
	check(self.ta.allocation_count(), 0);
	self.ta.free();
}

fn void Fixture.expect_types(&self, TokenType[] expected)
{
	check(self.tokens.len(), expected.len + 1);
	foreach (i, t : expected) test::eq(self.tokens[i].type, t);
	test::eq(self.tokens[expected.len].type, TokenType.EOF);
}

fn void expect_types(String text, TokenType[] expected)
{
	Fixture f;
	f.init(text);
	defer f.free();
	f.expect_types(expected);
	check(f.diags.errors, 0);
}

<* Lex `text` and expect exactly one error whose diagnostic is `diag`. *>
fn void expect_error(String text, Diagnostic diag)
{
	Fixture f;
	f.init(text);
	defer f.free();
	check(f.diags.reports.len(), 1);
	test::eq(f.diags.reports[0].diag, diag);
}

module c3_lexer_tests @test;
import aro::frontend::c3::lexer, aro::frontend::c3::tokens, aro::frontend::c3::diagnostics, aro::frontend::c3::symtab, std::core::mem::allocators, std::core::mem::alloc;

fn void identifier_kinds()
{
	expect_types("foo Foo FOO __Foo _foo $foo $Foo $FOO @foo @Foo @FOO #foo _",
		{ IDENT, TYPE_IDENT, CONST_IDENT, TYPE_IDENT, IDENT, CT_IDENT, CT_TYPE_IDENT, CT_CONST_IDENT,
		  AT_IDENT, AT_TYPE_IDENT, AT_CONST_IDENT, HASH_IDENT, UNDERSCORE });
}

fn void keywords()
{
	expect_types("fn int main void usz struct $if $endif $Typeof return foreach_r untypedlist",
		{ FN, INT, IDENT, VOID, USZ, STRUCT, CT_IF, CT_ENDIF, CT_TYPEOF, RETURN, FOREACH_R, UNTYPEDLIST });
}

fn void identifiers_are_interned()
{
	Fixture f;
	f.init("alpha beta alpha");
	defer f.free();
	f.expect_types({ IDENT, IDENT, IDENT });
	test::eq(f.tokens[0].string.ptr, f.tokens[2].string.ptr);
	test::eq(f.tokens[0].string, "alpha");
}

fn void operators()
{
	expect_types("+++= +++ ??? ?? ?: ? &&& && &= & ||| || |= | ... .. . :: : [< >] [ ] => == = != !! ! -> -- -= <<= << <= < >>= >> >= > $$foo",
		{ CT_CONCAT_ASSIGN, CT_CONCAT, CT_TERNARY, QUESTQUEST, ELVIS, QUESTION, CT_AND, AND, BIT_AND_ASSIGN, AMP,
		  CT_OR, OR, BIT_OR_ASSIGN, BIT_OR, ELLIPSIS, DOTDOT, DOT, SCOPE, COLON, LVEC, RVEC, LBRACKET, RBRACKET,
		  IMPLIES, EQEQ, EQ, NOT_EQUAL, BANGBANG, BANG, ARROW, MINUSMINUS, MINUS_ASSIGN, SHL_ASSIGN, SHL, LESS_EQ,
		  LESS, SHR_ASSIGN, SHR, GREATER_EQ, GREATER, BUILTIN, IDENT });
}

fn void numbers()
{
	expect_types("123 0x1F 0o17 0b101 1_000 10u 10UL 7l 1.5 1. 1e10 2.5e-3 0x1.8p3 2.0f 3d 1..2",
		{ INTEGER, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER, REAL, REAL, REAL, REAL, REAL,
		  REAL, REAL, INTEGER, DOTDOT, INTEGER });
}

fn void number_spelling()
{
	Fixture f;
	f.init("0x1F;");
	defer f.free();
	test::eq(f.tokens[0].string, "0x1F");
}

fn void comments_and_shebang()
{
	expect_types("#!/usr/bin/env c3\n/* a /* nested */ b */ x // tail\ny", { IDENT, IDENT });
}

fn void strings()
{
	Fixture f;
	f.init(`"a\nb" "\x41é" ` "`a``b`");
	defer f.free();
	f.expect_types({ STRING, STRING, STRING });
	test::eq(f.tokens[0].string, "a\nb");
	test::eq(f.tokens[1].string, "A\xc3\xa9");
	test::eq(f.tokens[2].string, "a`b");
}

fn void char_literals()
{
	Fixture f;
	f.init(`'a' 'ab' '\n' 'ሴ' '\U0001F600' 'é'`);
	defer f.free();
	f.expect_types({ CHAR_LITERAL, CHAR_LITERAL, CHAR_LITERAL, CHAR_LITERAL, CHAR_LITERAL, CHAR_LITERAL });
	check(f.tokens[0].char_value, 'a');
	check(f.tokens[0].width, 1);
	check(f.tokens[1].char_value, 0x6162);
	check(f.tokens[1].width, 2);
	check(f.tokens[2].char_value, '\n');
	check(f.tokens[3].char_value, 0x1234);
	check(f.tokens[3].width, 2);
	check(f.tokens[4].char_value, 0x1F600);
	check(f.tokens[4].width, 4);
	check(f.tokens[5].char_value, 0xE9);
	check(f.tokens[5].width, 2);
}

fn void byte_literals()
{
	Fixture f;
	f.init(`x"0a ff" b64"SGVsbG8=" b64'SGk'`);
	defer f.free();
	f.expect_types({ BYTES, BYTES, BYTES });
	check(f.tokens[0].bytes_len, 2);
	test::eq(f.tokens[0].is_base64, false);
	check(f.tokens[1].bytes_len, 5);
	test::eq(f.tokens[1].is_base64, true);
	check(f.tokens[2].bytes_len, 2);
}

fn void doc_comment_contracts()
{
	Fixture f;
	f.init("<* Hello there \n @return \"x\" *> fn");
	defer f.free();
	f.expect_types({ DOCS_START, AT_IDENT, STRING, DOCS_END, FN });
	test::eq(f.tokens[0].string, "Hello there");
}

fn void doc_comment_eol_and_return_ident()
{
	expect_types("<*\n @require return > 0\n*>", { DOCS_START, AT_IDENT, IDENT, GREATER, INTEGER, DOCS_EOL, DOCS_END });
}

fn void spans()
{
	Fixture f;
	f.init("a\n  bc");
	defer f.free();
	check(f.tokens[1].span.row, 2);
	check(f.tokens[1].span.col, 3);
	check(f.tokens[1].span.offset, 4);
	check(f.tokens[1].span.length, 2);
}

fn void carriage_returns_and_bom_are_removed()
{
	expect_types("\xEF\xBB\xBFa\r\nb", { IDENT, IDENT });
}

fn void utf16_is_rejected()
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	test::eq(@catch(lexer::clean_source(&ta, "\xFF\xFEa")), lexer::NOT_UTF8);
}

fn void lexing_errors()
{
	expect_error("1__0", LEX_MULTIPLE_UNDERSCORE);
	expect_error("0o8", LEX_OCTAL_DIGITS);
	expect_error("0b2", LEX_BINARY_DIGITS);
	expect_error("0xg", LEX_HEX_DIGITS);
	expect_error("9a", LEX_INVALID_LITERAL);
	expect_error("10_", LEX_NUMBER_TRAILING_UNDERSCORE);
	expect_error("1.5u", LEX_INT_SUFFIX_ON_FLOAT);
	expect_error("0o7f", LEX_OCTAL_FLOAT_SUFFIX);
	expect_error("1e", LEX_EXPONENT_EOF);
	expect_error("''", LEX_CHAR_EMPTY);
	expect_error("'abc", LEX_CHAR_UNTERMINATED);
	expect_error(`'\q'`, LEX_INVALID_ESCAPE);
	expect_error(`"abc`, LEX_STRING_EOF);
	expect_error("\"abc\nx", LEX_STRING_EOL);
	expect_error(`"\q"`, LEX_STRING_INVALID_ESCAPE);
	expect_error("x\"abc\"", LEX_HEX_ARRAY_ODD);
	expect_error("x\"0g\"", LEX_HEX_ARRAY_INVALID_CHAR);
	expect_error("`abc", LEX_RAW_STRING_EOF);
	expect_error("$$1", LEX_BUILTIN_EXPECTED_LETTER);
	expect_error("__", LEX_IDENT_ONLY_UNDERSCORE);
	expect_error("$", LEX_IDENT_EXPECTED_AFTER_PREFIX);
	expect_error("\\", LEX_STRAY_CHAR);
}

fn void error_message_text()
{
	Fixture f;
	f.init("\\");
	defer f.free();
	test::eq(f.diags.reports[0].text, "'\\' may not be placed outside of a string or comment, did you perhaps forget a \" somewhere?");
}

fn void errors_scan_rest_of_file()
{
	// c3c lexer_next_token: after an error, skip the line, then scan (and report)
	// every remaining token; the call returns false and ends on the last token.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	Symtab st;
	st.init(&ta);
	defer st.free();
	Diagnostics d;
	d.init_list(&ta);
	defer d.free();
	String src = lexer::clean_source(&ta, "1__0 a b\n$$\nc")!!;
	defer alloc::free(&ta, src.ptr);
	Lexer l;
	l.init(&ta, &st, &d, 0, src);
	test::eq(l.next_token(), false);
	check(d.errors, 2);
	test::eq(d.reports[1].diag, Diagnostic.LEX_BUILTIN_EXPECTED_LETTER);
	test::eq(l.token_type, TokenType.IDENT);
	test::eq(l.data.string, "c");
	test::eq(l.next_token(), true);
	test::eq(l.token_type, TokenType.EOF);
}

fn void token_spellings()
{
	test::eq(TokenType.CT_CONCAT_ASSIGN.text, "+++=");
	test::eq(TokenType.FOREACH_R.text, "foreach_r");
	test::eq(TokenType.AT_IDENT.text, "MACRO_IDENT");
	test::eq(TokenType.INT.is_any_type(), true);
	test::eq(TokenType.TYPE_IDENT.is_any_type(), true);
	test::eq(TokenType.FN.is_any_type(), false);
}

fn void shared_tooling_reports_use_c3_diagnostics() @test
{
	TrackingAllocator allocator;
	allocator.init(mem);
	Diagnostics diagnostics;
	diagnostics.init_list(&allocator);
	diagnostics.tooling_sink().emit(ERROR, "linker failed")!!;
	diagnostics.tooling_sink().emit(OFF, "disabled warning", "fuse-ld-path")!!;
	diagnostics.tooling_sink().emit(NOTE, "toolchain selected")!!;
	assert(diagnostics.errors == 1);
	assert(diagnostics.reports.len() == 2);
	assert(diagnostics.reports[0].text == "linker failed");
	diagnostics.free();
	assert(allocator.allocation_count() == 0);
	allocator.free();
}
