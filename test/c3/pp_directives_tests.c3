// Tests for src/c3/pp_directives.c3 (plan 13.5): IfContext packing,
// find_include_guard, expect_* helpers, skip and preprocess_extra on inputs
// that only contain directives, whitespace and skipped text, so no macro
// expansion (13.3), stringify (13.4) or #if expression evaluation (13.2) is
// reached. Expected diagnostics are source-derived from Preprocessor.zig /
// Preprocessor/Diagnostic.zig; the "#elifndef error.c" and "nested #ifs.c"
// shapes come from test/cases. No Zig executable was run.
module pp_directives_tests;
import aro::preprocessor, aro::tokens, aro::tokenizer, aro::source, aro::compilation, aro::diagnostics;
import aro::lang_opts, aro::type_store;
import std::io, std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

fn void expect_msg(Diagnostics* d, sz i, String text, uint line, uint col)
{
	test::eq(d.messages[i].text, text);
	check(d.messages[i].location.line_no, line);
	check(d.messages[i].location.col, col);
}

<*
 Preprocess `text` (as "t.c") with a list-diagnostics compilation; the body
 gets the preprocessor, diagnostics, the source and the result of
 preprocess_extra. Checks for leaks.
*>
macro @with_pp(String text, Standard std, bool preserve_ws, Linemarkers markers; @body(Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof))
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = std;
		Source src = comp.add_source_from_buffer("t.c", text)!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		pp.preserve_whitespace = preserve_ws;
		pp.linemarkers = markers;
		bool found;
		pp.defines.get_or_put("DEFINED", &found);
		TokenWithExpansionLocs? r = pp.preprocess_extra(src);
		fault f = @catch(r);
		TokenWithExpansionLocs eof;
		if (try v = r) eof = v;
		@body(&pp, &d, src, f, eof);
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

macro @pp(String text; @body(Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof))
{
	@with_pp(text, DEFAULT, false, NONE; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		@body(pp, d, src, f, eof);
	};
}

fn void if_context_packing() @test
{
	IfContext c = preprocessor::IF_CONTEXT_DEFAULT;
	for (int i = 1; i <= 255; i++)
	{
		assert(!c.increment());
		c.set(IfNesting::values[i % 3]);
	}
	check(c.level, 255);
	// Each level keeps its own two bits.
	for (int i = 255; i >= 1; i--)
	{
		check(c.get().ordinal, i % 3);
		c.decrement();
	}
	check(c.level, 0);
	// Level 1 is overwritten in place.
	c.increment();
	c.set(UNTIL_ENDIF_SEEN_ELSE);
	c.set(UNTIL_ELSE);
	check(c.get().ordinal, IfNesting.UNTIL_ELSE.ordinal);
	// u8 overflow on the 256th nesting (Zig @addWithOverflow).
	c.level = 255;
	assert(c.increment());
	check(c.level, 0);
}

fn void include_guard_detection() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	Compilation comp;
	comp.init(&ta);
	Preprocessor pp;
	pp.init(&comp, preprocessor::TESTING)!!;
	Source a = comp.add_source_from_buffer("a.h", "\n\n  # ifndef A_H /* c */\n#define A_H\n#endif\n")!!;
	test::eq(pp.find_include_guard(a)!!, "A_H");
	Source b = comp.add_source_from_buffer("b.h", "#if !defined B_H\n#endif\n")!!;
	assert(@catch(pp.find_include_guard(b)) == preprocessor::NO_INCLUDE_GUARD);
	Source c = comp.add_source_from_buffer("c.h", "int x;\n#ifndef C_H\n#endif\n")!!;
	assert(@catch(pp.find_include_guard(c)) == preprocessor::NO_INCLUDE_GUARD);
	Source e = comp.add_source_from_buffer("e.h", "#ifndef 1\n")!!;
	assert(@catch(pp.find_include_guard(e)) == preprocessor::NO_INCLUDE_GUARD);
	pp.free();
	comp.free();
	check(ta.allocation_count(), 0);
}

fn void expect_helpers() @test
{
	@pp("\n"; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		Source s1 = pp.comp.add_source_from_buffer("e1.c", "  FOO /* x */ bar baz\nnext")!!;
		Tokenizer t;
		t.init(s1.buf, s1.id, pp.comp.langopts);
		test::eq(pp.expect_macro_name(&t)!!, "FOO");
		pp.expect_nl(&t)!!;
		check(d.messages.len(), 1);
		expect_msg(d, 0, "extra tokens at end of macro directive", 1, 15);
		check(t.next().id.ordinal, TokenId.IDENTIFIER.ordinal);

		Source s2 = pp.comp.add_source_from_buffer("e2.c", "  1 rest of line\nnext")!!;
		t.init(s2.buf, s2.id, pp.comp.langopts);
		assert(@catch(pp.expect_macro_name(&t)) == preprocessor::NO_MACRO_NAME);
		expect_msg(d, 1, "macro name missing", 1, 3);
		// skip_to_nl consumed the line.
		check(t.next().id.ordinal, TokenId.IDENTIFIER.ordinal);

		// A keyword is a macro identifier.
		t.init(" if\n", src.id, pp.comp.langopts);
		test::eq(pp.expect_macro_name(&t)!!, "if");

		t.init("a b c\nd", src.id, pp.comp.langopts);
		preprocessor::skip_to_nl(&t);
		check(t.line, 2);
	};
}

fn void ifdef_branches() @test
{
	// test/cases/#ifdef.c and nested #ifs.c shapes with nothing in the active branches.
	@pp("#ifdef DEFINED\n#else\nskipped text 'x\n#endif\n#ifdef BAZ\nint\n#if 0\n#else\n#endif\n#else\n#endif\n#ifndef BAZ\n#elif garbage(\n#endif\n"; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(!f);
		TokenWithExpansionLocs e = eof;
		check(e.id.ordinal, TokenId.EOF.ordinal);
		check(e.loc.line, 15);
		check(d.messages.len(), 0);
		check(pp.tokens.len(), 0);
		check(pp.preprocess_count, 1);
	};
}

fn void conditional_errors() @test
{
	// `#ifdef` without a name: the nl was taken by expect_macro_name, so
	// skip_to_nl eats the (blank) next line, as in Zig.
	@pp("#else\n#endif\n#ifdef\n\n#endif\n#ifdef DEFINED\n#else\n#else\n#endif\n#ifdef X\n#else\n#elifdef X\n#else\neaten by skip_to_nl\n#endif\n#ifdef DEFINED extra\n#else\n#else\n#elif 1\n#endif\n"; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(!f);
		expect_msg(d, 0, "#else without #if", 1, 2);
		expect_msg(d, 1, "#endif without #if", 2, 2);
		expect_msg(d, 2, "macro name missing", 4, 7); // the nl token carries the next line (Zig; cf. #elifndef error.c)
		// skip(UNTIL_ENDIF_SEEN_ELSE) from the true branch's #else
		expect_msg(d, 3, "#else after #else", 8, 2);
		// main-loop #elifdef / #else in the seen-else state; after expect_nl,
		// #else's skip_to_nl eats the following line (as Zig).
		expect_msg(d, 4, "#elifdef is a C23 extension", 12, 2);
		expect_msg(d, 5, "#elifdef after #else", 12, 2);
		expect_msg(d, 6, "#else after #else", 13, 2);
		expect_msg(d, 7, "extra tokens at end of macro directive", 16, 16);
		expect_msg(d, 8, "#else after #else", 18, 2);
		expect_msg(d, 9, "#elif after #else", 19, 2);
		check(d.messages.len(), 10);
		check(pp.tokens.len(), 0);
	};
}

fn void elifdef_c23() @test
{
	// test/cases/#elifndef error.c: missing names after #elifdef / #elifndef are
	// reported at the nl token, which carries the next line (4:9 and 13:10 there).
	@with_pp("#ifdef FOO\n#elifdef\n#else\n#endif\n#ifdef FOO\n#elifndef\n#else\n#endif\n#ifdef FOO\n#elifndef DEFINED\n#elifdef DEFINED\n#endif\n", C23, false, NONE; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(!f);
		check(d.messages.len(), 2);
		expect_msg(d, 0, "macro name missing", 3, 9);
		expect_msg(d, 1, "macro name missing", 7, 10);
	};
	// Before C23 a skipped #elifndef (even nested) is reported as "#elifdef" (as Zig).
	@with_pp("#ifdef X\n#if 0\n#elifndef Y\n#endif\n#endif\n#elifndef X\n", C17, false, NONE; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(!f);
		expect_msg(d, 0, "#elifdef is a C23 extension", 3, 2);
		expect_msg(d, 1, "#elifndef is a C23 extension", 6, 2);
		expect_msg(d, 2, "#elifndef without #if", 6, 2);
		// level 1 was opened by the #elifndef: X undefined -> then branch, never closed.
		expect_msg(d, 3, "unterminated conditional directive", 7, 1);
		check(d.messages.len(), 4);
	};
}

fn void unterminated_conditionals() @test
{
	@pp("#ifdef A\nint x;\n"; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(!f);
		TokenWithExpansionLocs e = eof;
		check(e.loc.line, 3);
		check(d.messages.len(), 1);
		expect_msg(d, 0, "unterminated conditional directive", 3, 1);
	};
	// `#` at eof inside a conditional: reported at the '#', the eof token is returned.
	@pp("#ifdef A\n#else\n#"; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(!f);
		TokenWithExpansionLocs e = eof;
		check(e.id.ordinal, TokenId.EOF.ordinal);
		check(e.loc.byte_offset, 16);
		check(d.messages.len(), 1);
		expect_msg(d, 0, "unterminated conditional directive", 3, 1);
	};
}

fn void too_many_nestings() @test
{
	DString s;
	s.init(mem);
	defer s.free();
	for (int i = 0; i < 256; i++) s.append("#ifdef DEFINED\n");
	@pp(s.str_view(); Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(f == compilation::FATAL_ERROR);
		check(d.messages.len(), 1);
		expect_msg(d, 0, "too many #if nestings", 256, 2);
		check(d.messages[0].kind.ordinal, MessageKind.FATAL_ERROR.ordinal);
	};
}

fn void undef_and_invalid_directives() @test
{
	@pp("#undef DEFINED junk\n#undef 3\n#\n#foo bar\n"; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(!f);
		assert(!pp.defines.contains("DEFINED"));
		expect_msg(d, 0, "extra tokens at end of macro directive", 1, 16);
		expect_msg(d, 1, "macro name missing", 2, 8);
		expect_msg(d, 2, "invalid preprocessing directive", 4, 1);
		check(d.messages.len(), 3);
	};
}

fn void include_guards_recorded() @test
{
	@pp("#ifndef G_H\n#define_is_not_reached\n#endif\n\n"; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(!f);
		// G_H undefined: then branch; `#define_is_not_reached` is an invalid directive.
		check(d.messages.len(), 1);
		test::eq(pp.include_guards.get((uint)src.id)!!, "G_H");
	};
	// Something after the level-1 #endif clears the guard.
	@pp("#ifndef G_H\n#endif\n#\n"; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(!f);
		assert(!pp.include_guards.has_key((uint)src.id));
	};
	// #else at level 1 clears it.
	@pp("#ifndef G_H\n#else\n#endif\n"; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(!f);
		assert(!pp.include_guards.has_key((uint)src.id));
	};
}

fn void newline_eof() @test
{
	@pp("#ifdef A\n#endif"; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(!f);
		check(d.messages.len(), 0); // -Wnewline-eof is off by default
	};
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		d.set("newline-eof", WARNING)!!;
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("t.c", "#ifdef A\n#endif")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		pp.preprocess_extra(src)!!;
		check(d.messages.len(), 1);
		expect_msg(&d, 0, "no newline at end of file", 2, 7);
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void preserve_whitespace_tokens() @test
{
	@with_pp("  \n#ifdef A\nint\n#endif\n", DEFAULT, true, NONE; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(!f);
		check(d.messages.len(), 0);
		check(pp.tokens.len(), 5);
		check(pp.tokens[0].id.ordinal, TokenId.WHITESPACE.ordinal);
		for (int i = 1; i < 5; i++) check(pp.tokens[i].id.ordinal, TokenId.NL.ordinal);
		// The NL added by skip carries the new line number.
		check(pp.tokens[2].loc.line, 4);
	};
}

fn void line_directives() @test
{
	@with_pp("#line 10 \"x.c\"\n#line 0x5\n#line 20\n# 7 \"a.h\" 1 3 4\n# 8 \"b.h\" 2 1\n", DEFAULT, false, LINE_DIRECTIVES; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(!f);
		TokenWithExpansionLocs e = eof;
		// Line 2 of the file is line 10 of "x.c".
		expect_msg(d, 0, "#line directive requires a positive integer argument", 10, 7);
		test::eq(d.messages[0].location.path, "x.c");
		// `# 8 "b.h" 2 1` (line 7 of "a.h"): flag 1 is only valid first.
		expect_msg(d, 1, "invalid flag '1' in line marker directive", 7, 13);
		check(d.messages.len(), 2);
		check(pp.tokens.len(), 3);
		TreeToken t0 = pp.tokens[0];
		check(t0.id.ordinal, TokenId.LINEMARKER.ordinal);
		check(t0.loc.line, 10);
		check(t0.loc.byte_offset, 0);
		assert(t0.loc.id.is_alias);
		Source x = pp.comp.get_source(t0.loc.id);
		test::eq(x.path, "x.c");
		check(x.kind.ordinal, SourceKind.USER.ordinal);

		TreeToken t1 = pp.tokens[1];
		check(t1.id.ordinal, TokenId.INCLUDE_START.ordinal);
		check(t1.loc.line, 7);
		Source a = pp.comp.get_source(t1.loc.id);
		test::eq(a.path, "a.h");
		check(a.kind.ordinal, SourceKind.EXTERN_C_SYSTEM.ordinal);

		TreeToken t2 = pp.tokens[2];
		check(t2.id.ordinal, TokenId.INCLUDE_RESUME.ordinal);
		check(t2.loc.line, 8);
		// The eof token is in the last alias and counts lines from there.
		check(e.loc.line, 8);
	};
	@pp("#line x \"y\"\n#line 5 notastring\n#line\n# 4294967296 \"z\"\n"; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(!f);
		expect_msg(d, 0, "#line directive requires a simple digit sequence", 1, 7);
		expect_msg(d, 1, "#line directive requires a positive integer argument", 1, 7);
		expect_msg(d, 2, "invalid filename for #line directive", 2, 9);
		// `#line 5 notastring` took effect: the next line is 5.
		expect_msg(d, 3, "#line directive requires a simple digit sequence", 6, 6);
		expect_msg(d, 4, "#line directive requires a positive integer argument", 6, 6);
		expect_msg(d, 5, "line marker directive requires a positive integer argument", 6, 3);
		check(d.messages.len(), 6);
		check(pp.tokens.len(), 0); // linemarkers NONE
	};
}

fn void unsupported_directives_are_diagnosed() @test
{
	@pp("#include \"a.h\"\n"; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(f == aro::UNSUPPORTED);
		check(d.messages.len(), 1);
		expect_msg(d, 0, "'#include' is not supported yet by the C3 port", 1, 2);
		check(d.messages[0].kind.ordinal, MessageKind.ERROR.ordinal);
	};
	@pp("#include_next <a.h>\n"; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(f == aro::UNSUPPORTED);
		// DIAG_INCLUDE_NEXT is off by default; include_depth 0 -> outside-header warning.
		expect_msg(d, 0, "#include_next in primary source file; will search from start of include path", 1, 2);
		expect_msg(d, 1, "'#include_next' is not supported yet by the C3 port", 1, 2);
		check(d.messages.len(), 2);
	};
	@pp("#embed \"a.bin\"\n"; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(f == aro::UNSUPPORTED);
		expect_msg(d, 0, "#embed is a C23 extension", 1, 2);
		expect_msg(d, 1, "'#embed' is not supported yet by the C3 port", 1, 2);
		check(d.messages.len(), 2);
	};
	@pp("#ifdef DEFINED\n#pragma once\n#endif\n"; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(f == aro::UNSUPPORTED);
		expect_msg(d, 0, "'#pragma' is not supported yet by the C3 port", 2, 2);
		check(d.messages.len(), 1);
	};
	// Skipped include directives are not evaluated.
	@pp("#ifdef A\n#include <nothing.h>\n#pragma x\n#endif\n"; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		assert(!f);
		check(d.messages.len(), 0);
	};
}

fn void skip_leaves_tokenizer_at_directive() @test
{
	@pp("\n"; Preprocessor* pp, Diagnostics* d, Source src, fault f, TokenWithExpansionLocs eof)
	{
		Tokenizer t;
		String text = "a\n#if X\n#elif\n#endif\n  #  elif Y\n";
		t.init(text, src.id, pp.comp.langopts);
		pp.skip(&t, UNTIL_ELSE)!!;
		check(t.index, 21);
		check(t.line, 5);
		Token h = t.next_no_ws();
		check(h.id.ordinal, TokenId.HASH.ordinal);
		// UNTIL_ENDIF ignores #elif but stops at #else.
		t.init("#elif\n#else\n#endif\n", src.id, pp.comp.langopts);
		pp.skip(&t, UNTIL_ENDIF)!!;
		check(t.index, 6);
		check(d.messages.len(), 0);
	};
}

fn void empty_if_expression_uses_real_evaluator() @test
{
	// An empty #if / #elif expression needs no macro expansion: PpExprParser
	// reports "expected value in expression" at the nl token and the
	// condition is false (Zig `parse() orelse return false`). [source]
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		type_store::init_named_types(&comp);
		Source src = comp.add_source_from_buffer("t.c", "#if\nskipped\n#else\n#endif\n#ifdef X\n#elif\nskipped\n#endif\n#ifdef DEFINED\n#elif\n#endif\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		bool found;
		pp.defines.get_or_put("DEFINED", &found);
		pp.preprocess_extra(src)!!;
		check(d.messages.len(), 2);
		// The nl token carries the next line, as for "macro name missing" above.
		expect_msg(&d, 0, "expected value in expression", 2, 4);
		expect_msg(&d, 1, "expected value in expression", 7, 6);
		check(pp.tokens.len(), 0);
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}
