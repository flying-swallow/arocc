// Tests for aro::tokenizer, aro::lang_opts, aro::char_info and the generated
// aro::identifier_tables.
//
// The expect_tokens cases are ported verbatim from the `test` blocks in
// src/aro/Tokenizer.zig; "ArmLdrex versions" from src/aro/LangOpts.zig;
// is_xid_start / is_xid_continue from src/aro/char_info.zig. The per-standard
// gating, byte-range and line-accounting cases are source-derived: their
// expected values come from reading Tokenizer.zig / LangOpts.zig (no Zig
// executable was run). The randomized test replaces Zig's fuzz test
// ("Tokenizer fuzz test") with a deterministic PRNG and checks the same
// progress invariant.
module tokenizer_tests;
import aro::tokenizer, aro::lang_opts, aro::char_info, aro::source, aro::compilation;
import std::io, std::core::mem::allocators;

<* test::eq for slices; numeric values are compared as long (test::eq rejects int vs uint). *>
macro check(left, right)
{
	$if $defined((long)left):
		test::eq((long)left, (long)right);
	$else
		test::eq(left, right);
	$endif
}

fn LangOpts std_opts(Standard s)
{
	LangOpts o = lang_opts::DEFAULT;
	o.standard = s;
	return o;
}

<* Zig's expectTokensExtra: whitespace is skipped, and the token after the expected ones must be EOF. *>
fn void expect_tokens_extra(String contents, TokenId[] expected, LangOpts opts)
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		Source src = comp.add_source_from_buffer("path", contents)!!;
		Tokenizer t;
		t.init(src.buf, src.id, opts);
		usz i = 0;
		while (i < expected.len)
		{
			Token tok = t.next();
			if (tok.id == WHITESPACE) continue;
			if (tok.id != expected[i])
			{
				io::eprintfn("input %s: token %d: expected %s, found %s", contents, i, expected[i], tok.id);
			}
			test::eq(tok.id, expected[i]);
			i++;
		}
		Token last = t.next();
		if (last.id != EOF) io::eprintfn("input %s: expected eof, found %s", contents, last.id);
		test::eq(last.id, TokenId.EOF);
		comp.free();
	}
	check(ta.allocation_count(), 0);
}

fn void expect_tokens(String contents, TokenId[] expected)
{
	expect_tokens_extra(contents, expected, lang_opts::DEFAULT);
}

<* Tokens (whitespace included) with their byte ranges and lines, using the source's splice locations. *>
struct Expected
{
	TokenId id;
	uint start;
	uint end;
	uint line;
}

fn void expect_ranges(String contents, Expected[] expected, LangOpts opts = lang_opts::DEFAULT)
{
	Compilation comp;
	comp.init(mem);
	defer comp.free();
	Source src = comp.add_source_from_buffer("path", contents)!!;
	Tokenizer t;
	t.init(src.buf, src.id, opts, src.splice_locs);
	foreach (i, e : expected)
	{
		Token tok = t.next();
		if (tok.id != e.id || tok.start != e.start || tok.end != e.end || tok.line != e.line)
		{
			io::eprintfn("input %s: token %d: expected %s %d..%d line %d, found %s %d..%d line %d",
				contents, i, e.id, e.start, e.end, e.line, tok.id, tok.start, tok.end, tok.line);
		}
		test::eq(tok.id, e.id);
		check(tok.start, e.start);
		check(tok.end, e.end);
		check(tok.line, e.line);
		test::eq(tok.source.index, src.id.index);
	}
}

// ---- Tokenizer.zig unit tests ----

fn void escaped_literals_at_eof_or_with_embedded_nul_byte() @test
{
	expect_tokens("'\\", { UNTERMINATED_CHAR_LITERAL });
	expect_tokens("\"\\", { UNTERMINATED_STRING_LITERAL });
	expect_tokens("'\\\x00", { UNTERMINATED_CHAR_LITERAL });
	expect_tokens("\"\\\x00", { UNTERMINATED_STRING_LITERAL });
}

fn void operators() @test
{
	expect_tokens(
		" ! != | || |= = ==\n"
		" ( ) { } [ ] . .. ...\n"
		" ^ ^= + ++ += - -- -=\n"
		" * *= % %= -> : ; / /=\n"
		" , & && &= ? < <= <<\n"
		"  <<= > >= >> >>= ~ # ##\n",
		{
			BANG, BANG_EQUAL, PIPE, PIPE_PIPE, PIPE_EQUAL, EQUAL, EQUAL_EQUAL, NL,
			L_PAREN, R_PAREN, L_BRACE, R_BRACE, L_BRACKET, R_BRACKET, PERIOD, PERIOD, PERIOD, ELLIPSIS, NL,
			CARET, CARET_EQUAL, PLUS, PLUS_PLUS, PLUS_EQUAL, MINUS, MINUS_MINUS, MINUS_EQUAL, NL,
			ASTERISK, ASTERISK_EQUAL, PERCENT, PERCENT_EQUAL, ARROW, COLON, SEMICOLON, SLASH, SLASH_EQUAL, NL,
			COMMA, AMPERSAND, AMPERSAND_AMPERSAND, AMPERSAND_EQUAL, QUESTION_MARK, ANGLE_BRACKET_LEFT,
			ANGLE_BRACKET_LEFT_EQUAL, ANGLE_BRACKET_ANGLE_BRACKET_LEFT, NL,
			ANGLE_BRACKET_ANGLE_BRACKET_LEFT_EQUAL, ANGLE_BRACKET_RIGHT, ANGLE_BRACKET_RIGHT_EQUAL,
			ANGLE_BRACKET_ANGLE_BRACKET_RIGHT, ANGLE_BRACKET_ANGLE_BRACKET_RIGHT_EQUAL, TILDE, HASH, HASH_HASH, NL,
		});
}

fn void keywords() @test
{
	expect_tokens(
		"auto __auto_type break case char const continue default do\n"
		"double else enum extern float for goto if int\n"
		"long register return short signed sizeof static\n"
		"struct switch typedef union unsigned void volatile\n"
		"while _Bool _Complex _Imaginary inline restrict _Alignas\n"
		"_Alignof _Atomic _Generic _Noreturn _Static_assert _Thread_local __thread\n"
		"__attribute __attribute__\n",
		{
			KEYWORD_AUTO, KEYWORD_AUTO_TYPE, KEYWORD_BREAK, KEYWORD_CASE, KEYWORD_CHAR, KEYWORD_CONST,
			KEYWORD_CONTINUE, KEYWORD_DEFAULT, KEYWORD_DO, NL,
			KEYWORD_DOUBLE, KEYWORD_ELSE, KEYWORD_ENUM, KEYWORD_EXTERN, KEYWORD_FLOAT, KEYWORD_FOR,
			KEYWORD_GOTO, KEYWORD_IF, KEYWORD_INT, NL,
			KEYWORD_LONG, KEYWORD_REGISTER, KEYWORD_RETURN, KEYWORD_SHORT, KEYWORD_SIGNED, KEYWORD_SIZEOF,
			KEYWORD_STATIC, NL,
			KEYWORD_STRUCT, KEYWORD_SWITCH, KEYWORD_TYPEDEF, KEYWORD_UNION, KEYWORD_UNSIGNED, KEYWORD_VOID,
			KEYWORD_VOLATILE, NL,
			KEYWORD_WHILE, KEYWORD_BOOL, KEYWORD_COMPLEX, KEYWORD_IMAGINARY, KEYWORD_INLINE, KEYWORD_RESTRICT,
			KEYWORD_ALIGNAS, NL,
			KEYWORD_ALIGNOF, KEYWORD_ATOMIC, KEYWORD_GENERIC, KEYWORD_NORETURN, KEYWORD_STATIC_ASSERT,
			KEYWORD_THREAD_LOCAL, KEYWORD_THREAD, NL,
			KEYWORD_ATTRIBUTE1, KEYWORD_ATTRIBUTE2, NL,
		});
}

fn void preprocessor_keywords() @test
{
	expect_tokens(
		"#include\n#include_next\n#embed\n#define\n#ifdef\n#ifndef\n#error\n#pragma\n",
		{
			HASH, KEYWORD_INCLUDE, NL,
			HASH, KEYWORD_INCLUDE_NEXT, NL,
			HASH, KEYWORD_EMBED, NL,
			HASH, KEYWORD_DEFINE, NL,
			HASH, KEYWORD_IFDEF, NL,
			HASH, KEYWORD_IFNDEF, NL,
			HASH, KEYWORD_ERROR, NL,
			HASH, KEYWORD_PRAGMA, NL,
		});
}

fn void line_continuation() @test
{
	expect_tokens(
		"#define foo \\\n"
		"  bar\n"
		"\"foo\\\n"
		" bar\"\n"
		"#define \"foo\"\n"
		" \"bar\"\n"
		"#define \"foo\" \\\n"
		" \"bar\"",
		{
			HASH, KEYWORD_DEFINE, IDENTIFIER, IDENTIFIER, NL,
			STRING_LITERAL, NL,
			HASH, KEYWORD_DEFINE, STRING_LITERAL, NL,
			STRING_LITERAL, NL,
			HASH, KEYWORD_DEFINE, STRING_LITERAL, STRING_LITERAL,
		});
}

fn void string_prefix() @test
{
	expect_tokens(
		"\"foo\"\nu\"foo\"\nu8\"foo\"\nU\"foo\"\nL\"foo\"\n'foo'\nu8'A'\nu'foo'\nU'foo'\nL'foo'\n",
		{
			STRING_LITERAL, NL, STRING_LITERAL_UTF_16, NL, STRING_LITERAL_UTF_8, NL,
			STRING_LITERAL_UTF_32, NL, STRING_LITERAL_WIDE, NL,
			CHAR_LITERAL, NL, CHAR_LITERAL_UTF_8, NL, CHAR_LITERAL_UTF_16, NL,
			CHAR_LITERAL_UTF_32, NL, CHAR_LITERAL_WIDE, NL,
		});
}

fn void num_suffixes() @test
{
	expect_tokens(
		" 1.0f 1.0L 1.0 .0 1. 0x1p0f 0X1p0\n"
		" 0l 0lu 0ll 0llu 0\n"
		" 1u 1ul 1ull 1\n"
		" 1.0i 1.0I\n"
		" 1.0if 1.0If 1.0fi 1.0fI\n"
		" 1.0il 1.0Il 1.0li 1.0lI\n",
		{
			PP_NUM, PP_NUM, PP_NUM, PP_NUM, PP_NUM, PP_NUM, PP_NUM, NL,
			PP_NUM, PP_NUM, PP_NUM, PP_NUM, PP_NUM, NL,
			PP_NUM, PP_NUM, PP_NUM, PP_NUM, NL,
			PP_NUM, PP_NUM, NL,
			PP_NUM, PP_NUM, PP_NUM, PP_NUM, NL,
			PP_NUM, PP_NUM, PP_NUM, PP_NUM, NL,
		});
}

fn void comments() @test
{
	expect_tokens("//foo\n#foo", { NL, HASH, IDENTIFIER });
	LangOpts o = lang_opts::DEFAULT;
	o.preserve_comments = true;
	expect_tokens_extra("//foo\nvoid\n//bar", { COMMENT, NL, KEYWORD_VOID, NL, COMMENT }, o);
}

fn void extended_identifiers() @test
{
	expect_tokens("𝓪𝓻𝓸𝓬𝓬", { EXTENDED_IDENTIFIER });
	expect_tokens("u𝓪𝓻𝓸𝓬𝓬", { EXTENDED_IDENTIFIER });
	expect_tokens("u8𝓪𝓻𝓸𝓬𝓬", { EXTENDED_IDENTIFIER });
	expect_tokens("U𝓪𝓻𝓸𝓬𝓬", { EXTENDED_IDENTIFIER });
	expect_tokens("L𝓪𝓻𝓸𝓬𝓬", { EXTENDED_IDENTIFIER });
	expect_tokens("1™", { PP_NUM, EXTENDED_IDENTIFIER });
	expect_tokens("1.™", { PP_NUM, EXTENDED_IDENTIFIER });
	expect_tokens("..™", { PERIOD, PERIOD, EXTENDED_IDENTIFIER });
	expect_tokens("0™", { PP_NUM, EXTENDED_IDENTIFIER });
	expect_tokens("0b\U000E0000", { PP_NUM, EXTENDED_IDENTIFIER });
	expect_tokens("0b0\U000E0000", { PP_NUM, EXTENDED_IDENTIFIER });
	expect_tokens("01\U000E0000", { PP_NUM, EXTENDED_IDENTIFIER });
	expect_tokens("010\U000E0000", { PP_NUM, EXTENDED_IDENTIFIER });
	expect_tokens("0x\U000E0000", { PP_NUM, EXTENDED_IDENTIFIER });
	expect_tokens("0x0\U000E0000", { PP_NUM, EXTENDED_IDENTIFIER });
	expect_tokens("\"\\0\U000E0000\"", { STRING_LITERAL });
	expect_tokens("\"\\x\U000E0000\"", { STRING_LITERAL });
	expect_tokens("\"\\u\U000E0000\"", { STRING_LITERAL });
	expect_tokens("1e\U000E0000", { PP_NUM, EXTENDED_IDENTIFIER });
	expect_tokens("1e1\U000E0000", { PP_NUM, EXTENDED_IDENTIFIER });
}

fn void digraphs() @test
{
	expect_tokens("%:<::><%%>%:%:", { HASH, L_BRACKET, R_BRACKET, L_BRACE, R_BRACE, HASH_HASH });
	expect_tokens("\"%:<::><%%>%:%:\"", { STRING_LITERAL });
	expect_tokens("%:%42 %:%", { HASH, PERCENT, PP_NUM, HASH, PERCENT });
}

fn void c23_keywords() @test
{
	expect_tokens_extra("true false alignas alignof bool static_assert thread_local nullptr typeof_unqual",
		{
			KEYWORD_TRUE, KEYWORD_FALSE, KEYWORD_C23_ALIGNAS, KEYWORD_C23_ALIGNOF, KEYWORD_C23_BOOL,
			KEYWORD_C23_STATIC_ASSERT, KEYWORD_C23_THREAD_LOCAL, KEYWORD_NULLPTR, KEYWORD_TYPEOF_UNQUAL,
		}, std_opts(C23));
}

fn void gcc_integer_keywords() @test
{
	expect_tokens("__int24", { IDENTIFIER });
	LangOpts o = lang_opts::DEFAULT;
	o.has_int24 = true;
	expect_tokens_extra("__int24", { KEYWORD_INT24 }, o);
}

fn void universal_character_names() @test
{
	expect_tokens("\\", { INVALID });
	expect_tokens("\\g", { INVALID, IDENTIFIER });
	expect_tokens("\\u", { INCOMPLETE_UCN, IDENTIFIER });
	expect_tokens("\\ua", { INCOMPLETE_UCN, IDENTIFIER });
	expect_tokens("\\U9", { INCOMPLETE_UCN, IDENTIFIER });
	expect_tokens("\\ug", { INCOMPLETE_UCN, IDENTIFIER });
	expect_tokens("\\uag", { INCOMPLETE_UCN, IDENTIFIER });

	expect_tokens("\\ ", { INVALID, EOF });
	expect_tokens("\\g ", { INVALID, IDENTIFIER, EOF });
	expect_tokens("\\u ", { INCOMPLETE_UCN, IDENTIFIER, EOF });
	expect_tokens("\\ua ", { INCOMPLETE_UCN, IDENTIFIER, EOF });
	expect_tokens("\\U9 ", { INCOMPLETE_UCN, IDENTIFIER, EOF });
	expect_tokens("\\ug ", { INCOMPLETE_UCN, IDENTIFIER, EOF });
	expect_tokens("\\uag ", { INCOMPLETE_UCN, IDENTIFIER, EOF });

	expect_tokens("a\\", { IDENTIFIER, INVALID });
	expect_tokens("a\\g", { IDENTIFIER, INVALID, IDENTIFIER });
	expect_tokens("a\\u", { IDENTIFIER, INCOMPLETE_UCN, IDENTIFIER });
	expect_tokens("a\\ua", { IDENTIFIER, INCOMPLETE_UCN, IDENTIFIER });
	expect_tokens("a\\U9", { IDENTIFIER, INCOMPLETE_UCN, IDENTIFIER });
	expect_tokens("a\\ug", { IDENTIFIER, INCOMPLETE_UCN, IDENTIFIER });
	expect_tokens("a\\uag", { IDENTIFIER, INCOMPLETE_UCN, IDENTIFIER });

	expect_tokens("a\\ ", { IDENTIFIER, INVALID, EOF });
	expect_tokens("a\\g ", { IDENTIFIER, INVALID, IDENTIFIER, EOF });
	expect_tokens("a\\u ", { IDENTIFIER, INCOMPLETE_UCN, IDENTIFIER, EOF });
	expect_tokens("a\\ua ", { IDENTIFIER, INCOMPLETE_UCN, IDENTIFIER, EOF });
	expect_tokens("a\\U9 ", { IDENTIFIER, INCOMPLETE_UCN, IDENTIFIER, EOF });
	expect_tokens("a\\ug ", { IDENTIFIER, INCOMPLETE_UCN, IDENTIFIER, EOF });
	expect_tokens("a\\uag ", { IDENTIFIER, INCOMPLETE_UCN, IDENTIFIER, EOF });
}

// ---- Source-derived: complete UCNs, keyword gating by standard and options ----

fn void complete_ucns() @test
{
	expect_tokens("\\u00e9", { EXTENDED_IDENTIFIER });
	expect_tokens("\\U0001F914x", { EXTENDED_IDENTIFIER });
	expect_tokens("a\\u00e9b", { EXTENDED_IDENTIFIER });
	expect_tokens("\\UFFFFFFFF", { EXTENDED_IDENTIFIER }); // classification does not validate the value
	expect_tokens("a$b", { EXTENDED_IDENTIFIER });
	expect_tokens("$", { EXTENDED_IDENTIFIER });
	LangOpts o = lang_opts::DEFAULT;
	o.dollars_in_identifiers = false;
	expect_tokens_extra("a$b", { IDENTIFIER, INVALID, IDENTIFIER }, o);
	expect_tokens_extra("$", { INVALID }, o);
}

fn void gating_by_standard() @test
{
	String src = "inline restrict typeof asm __asm__ _Alignas bool true _Countof __typeof__";
	// C89: no C99/GNU/C23 keywords; implementation-namespace spellings are always keywords.
	expect_tokens_extra(src, {
		IDENTIFIER, IDENTIFIER, IDENTIFIER, IDENTIFIER, KEYWORD_ASM2, KEYWORD_ALIGNAS,
		IDENTIFIER, IDENTIFIER, KEYWORD_COUNTOF, KEYWORD_TYPEOF2 }, std_opts(C89));
	expect_tokens_extra(src, {
		IDENTIFIER, IDENTIFIER, IDENTIFIER, IDENTIFIER, KEYWORD_ASM2, KEYWORD_ALIGNAS,
		IDENTIFIER, IDENTIFIER, KEYWORD_COUNTOF, KEYWORD_TYPEOF2 }, std_opts(ISO9899));
	// GNU89: inline, typeof and asm are GNU keywords; restrict needs C99.
	expect_tokens_extra(src, {
		KEYWORD_INLINE, IDENTIFIER, KEYWORD_TYPEOF, KEYWORD_ASM, KEYWORD_ASM2, KEYWORD_ALIGNAS,
		IDENTIFIER, IDENTIFIER, KEYWORD_COUNTOF, KEYWORD_TYPEOF2 }, std_opts(GNU89));
	expect_tokens_extra(src, {
		KEYWORD_INLINE, KEYWORD_RESTRICT, IDENTIFIER, IDENTIFIER, KEYWORD_ASM2, KEYWORD_ALIGNAS,
		IDENTIFIER, IDENTIFIER, KEYWORD_COUNTOF, KEYWORD_TYPEOF2 }, std_opts(C99));
	expect_tokens_extra(src, {
		KEYWORD_INLINE, KEYWORD_RESTRICT, IDENTIFIER, IDENTIFIER, KEYWORD_ASM2, KEYWORD_ALIGNAS,
		IDENTIFIER, IDENTIFIER, KEYWORD_COUNTOF, KEYWORD_TYPEOF2 }, std_opts(C11));
	expect_tokens_extra(src, {
		KEYWORD_INLINE, KEYWORD_RESTRICT, IDENTIFIER, IDENTIFIER, KEYWORD_ASM2, KEYWORD_ALIGNAS,
		IDENTIFIER, IDENTIFIER, KEYWORD_COUNTOF, KEYWORD_TYPEOF2 }, std_opts(C17));
	// The default standard is GNU17.
	expect_tokens_extra(src, {
		KEYWORD_INLINE, KEYWORD_RESTRICT, KEYWORD_TYPEOF, KEYWORD_ASM, KEYWORD_ASM2, KEYWORD_ALIGNAS,
		IDENTIFIER, IDENTIFIER, KEYWORD_COUNTOF, KEYWORD_TYPEOF2 }, lang_opts::DEFAULT);
	// C23: typeof and the C23 keywords; asm still needs GNU.
	expect_tokens_extra(src, {
		KEYWORD_INLINE, KEYWORD_RESTRICT, KEYWORD_TYPEOF, IDENTIFIER, KEYWORD_ASM2, KEYWORD_ALIGNAS,
		KEYWORD_C23_BOOL, KEYWORD_TRUE, KEYWORD_COUNTOF, KEYWORD_TYPEOF2 }, std_opts(C23));
	expect_tokens_extra(src, {
		KEYWORD_INLINE, KEYWORD_RESTRICT, KEYWORD_TYPEOF, KEYWORD_ASM, KEYWORD_ASM2, KEYWORD_ALIGNAS,
		KEYWORD_C23_BOOL, KEYWORD_TRUE, KEYWORD_COUNTOF, KEYWORD_TYPEOF2 }, std_opts(GNU23));
	expect_tokens_extra(src, {
		KEYWORD_INLINE, KEYWORD_RESTRICT, KEYWORD_TYPEOF, IDENTIFIER, KEYWORD_ASM2, KEYWORD_ALIGNAS,
		KEYWORD_C23_BOOL, KEYWORD_TRUE, KEYWORD_COUNTOF, KEYWORD_TYPEOF2 }, std_opts(C2Y));
	expect_tokens_extra(src, {
		KEYWORD_INLINE, KEYWORD_RESTRICT, KEYWORD_TYPEOF, KEYWORD_ASM, KEYWORD_ASM2, KEYWORD_ALIGNAS,
		KEYWORD_C23_BOOL, KEYWORD_TRUE, KEYWORD_COUNTOF, KEYWORD_TYPEOF2 }, std_opts(GNU2Y));
}

fn void c23_keywords_are_identifiers_before_c23() @test
{
	expect_tokens_extra("true false alignas alignof bool static_assert thread_local nullptr typeof_unqual constexpr",
		{
			IDENTIFIER, IDENTIFIER, IDENTIFIER, IDENTIFIER, IDENTIFIER, IDENTIFIER, IDENTIFIER, IDENTIFIER,
			IDENTIFIER, IDENTIFIER,
		}, std_opts(C17));
	expect_tokens_extra("constexpr", { KEYWORD_CONSTEXPR }, std_opts(C2Y));
}

fn void digraphs_by_standard() @test
{
	// hasDigraphs defaults to standard >= gnu89, so C89 and C94 have none.
	expect_tokens_extra("<: :> <% %> %:", {
		ANGLE_BRACKET_LEFT, COLON, COLON, ANGLE_BRACKET_RIGHT, ANGLE_BRACKET_LEFT, PERCENT, PERCENT,
		ANGLE_BRACKET_RIGHT, PERCENT, COLON }, std_opts(C89));
	expect_tokens_extra("<: :> <% %> %:", { L_BRACKET, R_BRACKET, L_BRACE, R_BRACE, HASH }, std_opts(C99));
	expect_tokens_extra("<: :> <% %> %:", { L_BRACKET, R_BRACKET, L_BRACE, R_BRACE, HASH }, std_opts(C11));
	expect_tokens_extra("<: :> <% %> %:", { L_BRACKET, R_BRACKET, L_BRACE, R_BRACE, HASH }, std_opts(C23));
	LangOpts on = std_opts(C89);
	on.digraphs = ON;
	expect_tokens_extra("<: %:%:", { L_BRACKET, HASH_HASH }, on);
	LangOpts off = lang_opts::DEFAULT;
	off.digraphs = OFF;
	expect_tokens_extra("<: %:%:", { ANGLE_BRACKET_LEFT, COLON, PERCENT, COLON, PERCENT, COLON }, off);
}

fn void digit_separators() @test
{
	expect_tokens_extra("1'000'000 0x1'f 1'", { PP_NUM, PP_NUM, PP_NUM, UNTERMINATED_CHAR_LITERAL }, std_opts(C23));
	expect_tokens_extra("1'000", { PP_NUM }, std_opts(C2Y));
	expect_tokens_extra("1'000", { PP_NUM, UNTERMINATED_CHAR_LITERAL }, std_opts(C17));
	expect_tokens_extra("1'2'", { PP_NUM, CHAR_LITERAL }, std_opts(C11));
	expect_tokens_extra("1'+'", { PP_NUM, CHAR_LITERAL }, std_opts(C23));
}

fn void pp_number_boundaries() @test
{
	expect_tokens("1e+5 1e-5 0x1p-3 1.e+ 1+2 1.2.3 1..2 .5e+x", {
		PP_NUM, PP_NUM, PP_NUM, PP_NUM, PP_NUM, PLUS, PP_NUM, PP_NUM, PP_NUM, PP_NUM });
	expect_tokens("1p+p+3", { PP_NUM });
	expect_tokens("0x1e+1", { PP_NUM });
	expect_tokens("1_000", { PP_NUM });
}

fn void option_gated_keywords() @test
{
	String src = "_Float32 _Float128x _Decimal64 __int64 _int8 _cdecl __forceinline __declspec __stdcall";
	expect_tokens(src, {
		KEYWORD_FLOAT32, KEYWORD_FLOAT128X, KEYWORD_DFLOAT64, IDENTIFIER, IDENTIFIER, IDENTIFIER,
		IDENTIFIER, IDENTIFIER, KEYWORD_STDCALL });
	LangOpts clang = lang_opts::DEFAULT;
	clang.set_emulated_compiler(CLANG);
	expect_tokens_extra(src, {
		IDENTIFIER, IDENTIFIER, IDENTIFIER, IDENTIFIER, IDENTIFIER, IDENTIFIER,
		IDENTIFIER, IDENTIFIER, KEYWORD_STDCALL }, clang);
	LangOpts msvc = lang_opts::DEFAULT;
	msvc.set_emulated_compiler(MSVC);
	expect_tokens_extra(src, {
		KEYWORD_FLOAT32, KEYWORD_FLOAT128X, KEYWORD_DFLOAT64, KEYWORD_INT64, KEYWORD_INT8_2, KEYWORD_CDECL2,
		KEYWORD_FORCEINLINE, KEYWORD_DECLSPEC, KEYWORD_STDCALL }, msvc);
}

fn void ctrl_z_is_eof_with_ms_extensions() @test
{
	expect_tokens("a\x1Ab", { IDENTIFIER, INVALID, IDENTIFIER });
	LangOpts msvc = lang_opts::DEFAULT;
	msvc.set_ms_extensions(true);
	expect_tokens_extra("a\x1Ab", { IDENTIFIER }, msvc);
}

fn void malformed_literals() @test
{
	expect_tokens("''", { EMPTY_CHAR_LITERAL });
	expect_tokens("'a\n'", { UNTERMINATED_CHAR_LITERAL, NL, UNTERMINATED_CHAR_LITERAL });
	expect_tokens("\"abc\nx", { UNTERMINATED_STRING_LITERAL, NL, IDENTIFIER });
	expect_tokens("\"a\x00b\"", { STRING_LITERAL });
	expect_tokens("'\x00'", { CHAR_LITERAL });
	expect_tokens("/* never closed", { UNTERMINATED_COMMENT });
	expect_tokens("/* * ", { UNTERMINATED_COMMENT });
	expect_tokens("a\x00b", { IDENTIFIER, INVALID, IDENTIFIER });
	expect_tokens("@`", { INVALID, INVALID });
}

// ---- Source-derived: byte ranges, lines and splices ----

fn void byte_ranges() @test
{
	expect_ranges("int x = 42;", {
		{ KEYWORD_INT, 0, 3, 1 }, { WHITESPACE, 3, 4, 1 }, { IDENTIFIER, 4, 5, 1 }, { WHITESPACE, 5, 6, 1 },
		{ EQUAL, 6, 7, 1 }, { WHITESPACE, 7, 8, 1 }, { PP_NUM, 8, 10, 1 }, { SEMICOLON, 10, 11, 1 },
		{ EOF, 11, 11, 1 }, { EOF, 11, 11, 1 },
	});
	// u8 followed by a non-quote re-scans as an identifier from the prefix.
	expect_ranges("u8x L'a' ...", {
		{ IDENTIFIER, 0, 3, 1 }, { WHITESPACE, 3, 4, 1 }, { CHAR_LITERAL_WIDE, 4, 8, 1 },
		{ WHITESPACE, 8, 9, 1 }, { ELLIPSIS, 9, 12, 1 }, { EOF, 12, 12, 1 },
	});
}

fn void comment_ranges_and_lines() @test
{
	// A block comment followed by text is reported as whitespace spanning the comment.
	expect_ranges("/*\n\n*/x", { { WHITESPACE, 0, 6, 3 }, { IDENTIFIER, 6, 7, 3 }, { EOF, 7, 7, 3 } });
	// A block comment followed by a newline yields the newline token alone.
	expect_ranges("/* */\ny", { { NL, 5, 6, 2 }, { IDENTIFIER, 6, 7, 2 } });
	// A block comment followed by spaces merges into the following whitespace.
	expect_ranges("/**/  y", { { WHITESPACE, 4, 6, 1 }, { IDENTIFIER, 6, 7, 1 } });
	// A skipped line comment restarts the state machine without resetting the
	// token start, so the newline token spans the comment too (as in Zig).
	expect_ranges("//c\nz", { { NL, 0, 4, 2 }, { IDENTIFIER, 4, 5, 2 } });
	// A line comment at EOF keeps the comment start as the EOF start.
	expect_ranges("x//c", { { IDENTIFIER, 0, 1, 1 }, { EOF, 1, 4, 1 } });
	LangOpts o = lang_opts::DEFAULT;
	o.preserve_comments = true;
	expect_ranges("/*a\nb*/c//d", {
		{ COMMENT, 0, 7, 2 }, { IDENTIFIER, 7, 8, 2 }, { COMMENT, 8, 11, 2 }, { EOF, 11, 11, 2 } }, o);
}

fn void splice_line_accounting() @test
{
	// "a \\\nb\nc" is stored as "a b\nc" with a splice at offset 2.
	expect_ranges("a \\\nb\nc", {
		{ IDENTIFIER, 0, 1, 1 }, { WHITESPACE, 1, 2, 1 }, { IDENTIFIER, 2, 3, 2 }, { NL, 3, 4, 3 },
		{ IDENTIFIER, 4, 5, 3 }, { EOF, 5, 5, 3 },
	});
	// Two splices inside one token are both counted once the next token starts past them.
	expect_ranges("ab\\\nc\\\nd e", {
		{ IDENTIFIER, 0, 4, 1 }, { WHITESPACE, 4, 5, 3 }, { IDENTIFIER, 5, 6, 3 },
	});
}

fn void next_no_ws_variants() @test
{
	Compilation comp;
	comp.init(mem);
	defer comp.free();
	Source src = comp.add_source_from_buffer("path", "a /*c*/ //d\n b")!!;
	LangOpts o = lang_opts::DEFAULT;
	o.preserve_comments = true;
	Tokenizer t;
	t.init(src.buf, src.id, o);
	test::eq(t.next_no_ws().id, TokenId.IDENTIFIER);
	test::eq(t.next_no_ws().id, TokenId.NL);
	test::eq(t.next_no_ws().id, TokenId.IDENTIFIER);
	test::eq(t.next_no_ws().id, TokenId.EOF);
	t.init(src.buf, src.id, o);
	test::eq(t.next_no_ws_comments().id, TokenId.IDENTIFIER);
	test::eq(t.next_no_ws_comments().id, TokenId.COMMENT);
	test::eq(t.next_no_ws_comments().id, TokenId.COMMENT);
	test::eq(t.next_no_ws_comments().id, TokenId.NL);
}

// ---- Token.Id helpers and the keyword table ----

fn void keyword_table_is_sorted_and_round_trips() @test
{
	foreach (i, kw : tokenizer::KEYWORDS)
	{
		if (i > 0) assert(tokenizer::compare_bytes(tokenizer::KEYWORDS[i - 1].name, kw.name) < 0, "KEYWORDS not sorted at %s", kw.name);
		test::eq(tokenizer::lookup_keyword(kw.name), kw.id);
		// Zig spells keyword_regcall "_regcall" in all_kws but "__regcall" in lexeme().
		if (kw.id != KEYWORD_REGCALL) test::eq(kw.id.lexeme()!!, kw.name);
	}
	test::eq(tokenizer::lookup_keyword("_regcall"), TokenId.KEYWORD_REGCALL);
	test::eq(tokenizer::lookup_keyword("__regcall"), TokenId.IDENTIFIER);
	test::eq(tokenizer::lookup_keyword(""), TokenId.IDENTIFIER);
	test::eq(tokenizer::lookup_keyword("autox"), TokenId.IDENTIFIER);
	test::eq(tokenizer::lookup_keyword("aut"), TokenId.IDENTIFIER);
}

fn void token_id_helpers() @test
{
	test::eq(TokenId.HASH_HASH.lexeme()!!, "##");
	test::eq(TokenId.MACRO_WS.lexeme()!!, " ");
	test::eq(TokenId.NL.lexeme()!!, "");
	test::eq(TokenId.INCOMPLETE_UCN.lexeme()!!, "\\");
	assert(@catch(TokenId.IDENTIFIER.lexeme()) == tokenizer::NO_LEXEME);
	assert(@catch(TokenId.PP_NUM.lexeme()) == tokenizer::NO_LEXEME);
	test::eq(TokenId.PP_NUM.symbol(), "a number");
	test::eq(TokenId.INVALID.symbol(), "invalid bytes");
	test::eq(TokenId.CHAR_LITERAL_WIDE.symbol(), "a character literal");
	test::eq(TokenId.ARROW.symbol(), "->");
	test::eq(TokenId.KEYWORD_C23_BOOL.symbol(), "bool");

	TokenId id = KEYWORD_DEFINE;
	id.simplify_macro_keyword();
	test::eq(id, TokenId.IDENTIFIER);
	id = KEYWORD_DEFINED;
	id.simplify_macro_keyword();
	test::eq(id, TokenId.KEYWORD_DEFINED);
	id.simplify_macro_keyword_extra(true);
	test::eq(id, TokenId.IDENTIFIER);
	id = KEYWORD_INT;
	id.simplify_macro_keyword_extra(true);
	test::eq(id, TokenId.KEYWORD_INT);

	assert(TokenId.KEYWORD_COUNTOF.is_macro_identifier());
	assert(!TokenId.PP_NUM.is_macro_identifier());
	assert(TokenId.R_PAREN.should_track_hideset(FUNC));
	assert(!TokenId.R_PAREN.should_track_hideset(OBJ));
	assert(TokenId.KEYWORD_DEFINED.valid_preprocessor_expr_start());
	assert(!TokenId.SEMICOLON.valid_preprocessor_expr_start());
	assert(TokenId.HASH.allows_digraphs(lang_opts::DEFAULT));
	assert(!TokenId.HASH.allows_digraphs(std_opts(C89)));
	assert(!TokenId.PLUS.allows_digraphs(lang_opts::DEFAULT));
	assert(TokenId.KEYWORD_GOTO.can_open_gcc_asm_stmt());
	assert(TokenId.STRING_LITERAL_UTF_8.is_string_literal());
	assert(!TokenId.CHAR_LITERAL.is_string_literal());

	test::eq(tokenizer::ucn_classify("\\"), UCNKind.NONE);
	test::eq(tokenizer::ucn_classify("\\x"), UCNKind.NONE);
	test::eq(tokenizer::ucn_classify("\\u12"), UCNKind.INCOMPLETE);
	test::eq(tokenizer::ucn_classify("\\u12aF"), UCNKind.HEX4);
	test::eq(tokenizer::ucn_classify("\\U0001f91"), UCNKind.INCOMPLETE);
	test::eq(tokenizer::ucn_classify("\\U0001f914"), UCNKind.HEX8);
}

// ---- Randomized progress test (Zig "Tokenizer fuzz test") ----

struct Rng
{
	ulong state;
}

fn ulong Rng.next(&self)
{
	ulong x = self.state;
	x ^= x << 13;
	x ^= x >> 7;
	x ^= x << 17;
	self.state = x;
	return x;
}

<* Bytes that steer the tokenizer into its multi-byte states. *>
const char[*] INTERESTING = {
	0, '\n', '\r', '\\', '"', '\'', '/', '*', '%', ':', '<', '>', '#', '.', '+', '-', 'e', 'p', 'u', '8',
	'U', 'L', 'x', '0', '1', '_', '$', 0x1A, ' ', '\t', '=', '&', '|', '^', '!', 0x80, 0xC3, 0xE2, 0xF0, 0xFF,
};

fn void run_progress(char[] contents, LangOpts opts)
{
	Compilation comp;
	comp.init(mem);
	defer comp.free();
	Source src = comp.add_source_from_buffer("fuzz.c", contents)!!;
	Tokenizer t;
	t.init(src.buf, src.id, opts, src.splice_locs);
	uint len = (uint)src.buf.len;
	uint prev_line = 1;
	for (usz steps = 0; ; steps++)
	{
		assert(steps <= (usz)len + 1, "tokenizer did not reach EOF");
		uint prev_index = t.index;
		Token tok = t.next();
		assert(t.index <= len, "index past the end of the buffer");
		assert(tok.start <= tok.end && tok.end <= len, "token range out of bounds");
		assert(tok.line >= prev_line, "line went backwards");
		prev_line = tok.line;
		if (tok.id == EOF) break;
		// ensure that the tokenizer always makes progress
		assert(prev_index < t.index, "no progress at %d", prev_index);
	}
}

fn void randomized_progress() @test
{
	Rng rng = { 0x9E37_79B9_7F4A_7C15 };
	LangOpts[6] configs;
	configs[0] = lang_opts::DEFAULT;
	configs[1] = std_opts(C89);
	configs[2] = std_opts(C23);
	configs[3] = std_opts(C2Y);
	configs[3].preserve_comments = true;
	configs[4] = std_opts(C11);
	configs[4].set_ms_extensions(true);
	configs[4].dollars_in_identifiers = false;
	configs[5] = std_opts(C99);
	configs[5].digraphs = OFF;
	char[256] buf;
	for (int iter = 0; iter < 3000; iter++)
	{
		usz n = (usz)(rng.next() % 257);
		bool raw = iter % 3 == 0;
		for (usz i = 0; i < n; i++)
		{
			ulong r = rng.next();
			buf[i] = raw ? (char)r : INTERESTING[(usz)(r % INTERESTING.len)];
		}
		run_progress(buf[:n], configs[iter % configs.len]);
	}
	// Every single byte and every byte pair starting with a state-entering byte.
	for (int b = 0; b < 256; b++)
	{
		char[1] one = { (char)b };
		foreach (opts : configs) run_progress(one[..], opts);
		foreach (c : INTERESTING)
		{
			char[2] two = { c, (char)b };
			foreach (opts : configs) run_progress(two[..], opts);
		}
	}
}

// ---- lang_opts ----

fn void arm_ldrex_versions() @test
{
	check((char)(ArmLdrex){ .b = true }, 1);
	check((char)(ArmLdrex){ .b = true, .h = true }, 3);
	check((char)(ArmLdrex){ .b = true, .h = true, .w = true }, 7);
	check((char)(ArmLdrex){ .b = true, .h = true, .w = true, .d = true }, 15);
	check((char)(ArmLdrex){ .b = true }, lang_opts::ARM_LDREX_B_INT);
	check((char)(ArmLdrex){ .h = true }, lang_opts::ARM_LDREX_H_INT);
	check((char)(ArmLdrex){ .w = true }, lang_opts::ARM_LDREX_W_INT);
	check((char)(ArmLdrex){ .d = true }, lang_opts::ARM_LDREX_D_INT);
	ArmLdrex none = lang_opts::ARM_LDREX_NONE;
	ArmLdrex all = lang_opts::ARM_LDREX_ALL;
	check((char)none, 0);
	check((char)all, 15);
}

fn void standards() @test
{
	LangOpts o = lang_opts::DEFAULT;
	test::eq(o.standard, Standard.DEFAULT);
	o.set_standard("c90")!!;
	test::eq(o.standard, Standard.C89);
	o.set_standard("iso9899:199409")!!;
	test::eq(o.standard, Standard.ISO9899);
	o.set_standard("gnu2y")!!;
	test::eq(o.standard, Standard.GNU23); // Zig maps gnu2y to gnu23
	o.set_standard("c2y")!!;
	test::eq(o.standard, Standard.C2Y);
	assert(@catch(o.set_standard("c3")) == lang_opts::INVALID_STANDARD);
	test::eq(o.standard, Standard.C2Y);

	assert(Standard.C23.at_least(C11));
	assert(!Standard.C17.at_least(DEFAULT));
	assert(Standard.DEFAULT.is_gnu() && !Standard.DEFAULT.is_explicit_gnu());
	assert(Standard.GNU89.is_explicit_gnu() && !Standard.C99.is_gnu());
	test::eq(Standard.C89.std_c_version_macro(), "");
	test::eq(Standard.DEFAULT.std_c_version_macro(), "201710L");
	test::eq(Standard.GNU2Y.std_c_version_macro(), "202400L");

	LangOpts dflt = lang_opts::DEFAULT;
	assert(!dflt.has_char8_t());
	assert(std_opts(C23).has_char8_t());
	assert(!std_opts(C89).has_digraphs() && std_opts(GNU89).has_digraphs());
	check(Compiler.CLANG.default_gcc_version(), 40201);
	check(Compiler.NO.default_gcc_version(), 70100);
	LangOpts msvc = lang_opts::DEFAULT;
	msvc.set_emulated_compiler(MSVC);
	assert(msvc.ms_extensions && msvc.declspec_attrs && msvc.allow_fixed_sized_int_suffixes());
	assert(!msvc.has_target_os_macros());
	check(FPEvalMethod.INDETERMINATE.value, -1);
	check(FPEvalMethod.EXTENDED.value, 2);

	// é (U+00E9) is allowed everywhere; U+0300 cannot start an identifier from C11 on.
	assert(Standard.C99.codepoint_allowed_in_identifier(0xE9, true));
	assert(Standard.C11.codepoint_allowed_in_identifier(0x300, false));
	assert(!Standard.C11.codepoint_allowed_in_identifier(0x300, true));
	assert(!Standard.C23.codepoint_allowed_in_identifier(0x300, true));
	assert(Standard.C23.codepoint_allowed_in_identifier(0x300, false));
	assert(!Standard.C99.codepoint_allowed_in_identifier(0x0660, true)); // ARABIC-INDIC DIGIT ZERO
}

// ---- char_info ----

fn void xid_tables_cover_all_codepoints() @test
{
	// Zig: "isXidStart / isXidContinue panic check".
	usz starts = 0;
	usz continues = 0;
	for (uint c = 0x80; c < 0x110000; c++)
	{
		if (c >= 0xD800 && c <= 0xDFFF) continue;
		if (char_info::is_xid_start(c)) starts++;
		if (char_info::is_xid_continue(c))
		{
			continues++;
		}
		else
		{
			assert(!char_info::is_xid_start(c), "XID_Start must imply XID_Continue at %x", c);
		}
	}
	assert(starts > 100_000 && continues > starts);
}

fn void xid_start_and_continue() @test
{
	assert(!char_info::is_xid_start(0x1811)); // ᠑
	assert(!char_info::is_xid_start(0x2122)); // ™
	assert(!char_info::is_xid_start(0xA3)); // £
	assert(!char_info::is_xid_start(0x1F914)); // 🤔
	assert(char_info::is_xid_continue(0x1811));
	assert(!char_info::is_xid_continue(0x2122));
	assert(!char_info::is_xid_continue(0xA3));
	assert(!char_info::is_xid_continue(0x1F914));
	assert(char_info::is_xid_start(0xE9) && char_info::is_xid_start(0x1D4EA)); // é, 𝓪
}

fn void char_classes() @test
{
	assert(char_info::is_c11_id_char(0xA8) && !char_info::is_c11_id_char(0xA9));
	assert(char_info::is_c11_id_char(0xE0000) && !char_info::is_c11_id_char(0xEFFFE));
	assert(char_info::is_c99_id_char(0x0386) && !char_info::is_c99_id_char(0x0387));
	assert(char_info::is_c11_disallowed_initial_id_char(0xFE2F));
	assert(char_info::is_c99_disallowed_initial_id_char(0x0F33) && !char_info::is_c99_disallowed_initial_id_char(0x0F34));
	assert(char_info::is_invisible(0xFEFF) && !char_info::is_invisible(0xFEFE));
	test::eq(char_info::homoglyph(0x037E), ";");
	test::eq(char_info::homoglyph(0xFF3C), "\\");
	test::eq(char_info::homoglyph(0xE9), "");
	test::eq(char_info::is_normalized(0x0374), NfcQuickCheck.NO);
	test::eq(char_info::is_normalized(0x41), NfcQuickCheck.YES);
	test::eq(char_info::get_canonical_class(0x0301), CanonicalCombiningClass.ABOVE);
	check(char_info::get_canonical_class(0x0301).value, 230);
	test::eq(char_info::get_canonical_class(0x1E94A), CanonicalCombiningClass.NUKTA);
	test::eq(char_info::get_canonical_class(0x41), CanonicalCombiningClass.NOT_REORDERED);
}
