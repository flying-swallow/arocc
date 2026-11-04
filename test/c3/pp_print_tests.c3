// Tests for src/c3/pp_print.c3 (plan 13.6): fmtEscapes, printLinemarker,
// prettyPrintMacro / prettyPrintMacrosOnly and prettyPrintTokens over
// hand-built output token lists (no macro expansion involved).
// Every expected string is source-derived: traced by hand through
// src/aro/Preprocessor.zig (prettyPrintTokens and helpers). No Zig executable
// was run.
module pp_print_tests;
import aro::preprocessor, aro::tokens, aro::tokenizer, aro::source, aro::compilation, aro::diagnostics;
import std::io, std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

<* Run the body with a compilation + testing preprocessor; checks for leaks. *>
macro @with_pp(; @body(Compilation* comp, Preprocessor* pp))
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		@body(&comp, &pp);
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn Source add_src(Compilation* comp, String path, String text) => comp.add_source_from_buffer(path, text)!!;

<* Append every raw token of `src` (whitespace and newlines included, eof excluded) to the output, then EOF. *>
fn void push_all(Preprocessor* pp, Source src, bool skip_ws = false)
{
	Tokenizer tz;
	tz.init(src.buf, src.id, pp.comp.langopts);
	while (true)
	{
		Token t = tz.next();
		if (skip_ws && t.id == WHITESPACE) continue;
		pp.tokens.push({ .id = t.id, .loc = tokens::raw_location(t) });
		if (t.id == EOF) return;
	}
}

fn void push(Preprocessor* pp, TokenId id, Source src, uint offset, uint line = 1)
{
	pp.tokens.push({ .id = id, .loc = { .id = src.id, .byte_offset = offset, .line = line } });
}

fn String print(Preprocessor* pp, DumpMode mode = RESULT_ONLY)
{
	DString out;
	out.init(tmem);
	pp.pretty_print_tokens(&out, mode)!!;
	return out.str_view();
}

fn void escapes() @test
{
	DString out;
	out.init(tmem);
	preprocessor::write_escaped(&out, "a\n\"\\\t\r\x01\xff ~!#&([]'`{")!!;
	test::eq(out.str_view(), "a\\n\\\"\\\\\\t\\r\\x01\\xff ~!#&([]\\x27`{");
}

fn void linemarkers() @test
{
	@with_pp(; Compilation* comp, Preprocessor* pp)
	{
		Source s = add_src(comp, "dir/t\"x.c", "");
		DString out;
		out.init(tmem);
		pp.linemarkers = NUMERIC_DIRECTIVES;
		pp.print_linemarker(&out, 1, s, START)!!;
		out.append('|');
		pp.print_linemarker(&out, 12, s, RESUME)!!;
		out.append('|');
		pp.print_linemarker(&out, 3, s, NONE)!!;
		out.append('|');
		s.kind = SYSTEM;
		pp.print_linemarker(&out, 4, s, RESUME)!!;
		out.append('|');
		s.kind = EXTERN_C_SYSTEM;
		pp.print_linemarker(&out, 5, s, START)!!;
		out.append('|');
		pp.linemarkers = LINE_DIRECTIVES;
		pp.print_linemarker(&out, 6, s, START)!!;
		test::eq(out.str_view(), `# 1 "dir/t\"x.c" 1|# 12 "dir/t\"x.c" 2|# 3 "dir/t\"x.c"|# 4 "dir/t\"x.c" 2 3|# 5 "dir/t\"x.c" 1 3 4|#line 6 "dir/t\"x.c"`);
	};
}

fn void blank_lines_collapse_without_linemarkers() @test
{
	@with_pp(; Compilation* comp, Preprocessor* pp)
	{
		// 3 NLs before the next token: one newline, last_nl stays false.
		push_all(pp, add_src(comp, "a.c", "int x;\n\n\nint   y;\n"));
		test::eq(print(pp), "int x;\nint   y;\n");
	};
	@with_pp(; Compilation* comp, Preprocessor* pp)
	{
		// No trailing newline in the source: eof adds one.
		push_all(pp, add_src(comp, "b.c", "a\nb"));
		test::eq(print(pp), "a\nb\n");
	};
	@with_pp(; Compilation* comp, Preprocessor* pp)
	{
		// Leading run of 2 NLs: nothing (last_nl starts true).
		push_all(pp, add_src(comp, "c.c", "\n\na"));
		test::eq(print(pp), "a\n");
	};
	@with_pp(; Compilation* comp, Preprocessor* pp)
	{
		// A single leading NL is printed.
		push_all(pp, add_src(comp, "d.c", "\na"));
		test::eq(print(pp), "\na\n");
	};
	@with_pp(; Compilation* comp, Preprocessor* pp)
	{
		// Whitespace before the next token survives the collapse; trailing NLs are dropped.
		push_all(pp, add_src(comp, "e.c", "a\n\n  b\n\n\n"));
		test::eq(print(pp), "a\n  b\n");
	};
	@with_pp(; Compilation* comp, Preprocessor* pp)
	{
		// Only eof.
		push_all(pp, add_src(comp, "f.c", ""));
		test::eq(print(pp), "");
	};
}

fn void blank_lines_with_linemarkers() @test
{
	@with_pp(; Compilation* comp, Preprocessor* pp)
	{
		// Fewer than 8 newlines are printed one by one.
		pp.linemarkers = NUMERIC_DIRECTIVES;
		push_all(pp, add_src(comp, "a.c", "a\n\n\nb\n"));
		test::eq(print(pp), "a\n\n\nb\n");
	};
	@with_pp(; Compilation* comp, Preprocessor* pp)
	{
		// 8 newlines become a linemarker for the LAST nl token (Zig uses
		// tokens[j - 1]). The tokenizer gives an nl token the line AFTER it
		// (Tokenizer.next bumps `line` before building the token), so the
		// marker names line 9, the line of `b`.
		pp.linemarkers = NUMERIC_DIRECTIVES;
		push_all(pp, add_src(comp, "b.c", "a\n\n\n\n\n\n\n\nb\n"));
		test::eq(print(pp), "a\n# 9 \"b.c\"\nb\n");
	};
	@with_pp(; Compilation* comp, Preprocessor* pp)
	{
		pp.linemarkers = LINE_DIRECTIVES;
		push_all(pp, add_src(comp, "c.c", "a\n\n\n\n\n\n\n\n\n  b\n"));
		test::eq(print(pp), "a\n#line 10 \"c.c\"\n  b\n");
	};
}

fn void include_markers() @test
{
	@with_pp(; Compilation* comp, Preprocessor* pp)
	{
		pp.linemarkers = NUMERIC_DIRECTIVES;
		Source s = add_src(comp, "t.c", "a\nb\nc\n");
		push(pp, INCLUDE_START, s, 0xFFFF_FFFF);
		push(pp, IDENTIFIER, s, 0);
		push(pp, NL, s, 1);
		push(pp, INCLUDE_RESUME, s, 2, 5);
		push(pp, IDENTIFIER, s, 2);
		push(pp, LINEMARKER, s, 3, 7);
		push(pp, NL, s, 3);
		push(pp, IDENTIFIER, s, 4);
		push(pp, INCLUDE_RESUME, s, 0, 9);
		push(pp, EOF, s, 6);
		test::eq(print(pp), "# 1 \"t.c\" 1\na\n# 5 \"t.c\" 2\nb\n# 7 \"t.c\"\nc\n# 9 \"t.c\" 2\n");
	};
}

fn void pragma_line() @test
{
	@with_pp(; Compilation* comp, Preprocessor* pp)
	{
		Source s = add_src(comp, "p.c", "#pragma foo  bar(1)\nx\n");
		Tokenizer tz;
		tz.init(s.buf, s.id, comp.langopts);
		tz.next(); // '#'
		Token t;
		while ((t = tz.next()).id != EOF)
		{
			if (t.id == WHITESPACE) continue;
			TokenId id = t.id;
			pp.tokens.push({ .id = id, .loc = tokens::raw_location(t) });
		}
		pp.tokens.push({ .id = EOF, .loc = tokens::raw_location(t) });
		test::eq(print(pp), "#pragma foo bar ( 1 )\nx\n");
	};
}

fn void macro_printing() @test
{
	@with_pp(; Compilation* comp, Preprocessor* pp)
	{
		comp.langopts.preserve_comments = true;
		Source s = add_src(comp, "m.c", "#define /*a*/ FOO /*b*/ 1  /*c*/\t+ 2 // d\n#undef FOO\n");
		DString out;
		out.init(tmem);
		Location loc = { .id = s.id, .byte_offset = 1, .line = 1 };
		pp.pretty_print_macro(&out, loc, NAME_AND_BODY)!!;
		out.append('|');
		pp.pretty_print_macro(&out, loc, NAME_ONLY)!!;
		out.append('|');
		loc = { .id = s.id, .byte_offset = 43, .line = 2 };
		test::eq(s.buf[42:6], "#undef");
		pp.pretty_print_macro(&out, loc, NAME_AND_BODY)!!;
		test::eq(out.str_view(), "define FOO /*b*/ 1 /*c*/ + 2 // d|define FOO|undef FOO");
	};
	@with_pp(; Compilation* comp, Preprocessor* pp)
	{
		// Without -C the comments are whitespace.
		Source s = add_src(comp, "m.c", "#define F(x, y) x /* c */ ## y\n");
		DString out;
		out.init(tmem);
		pp.pretty_print_macro(&out, { .id = s.id, .byte_offset = 1, .line = 1 }, NAME_AND_BODY)!!;
		test::eq(out.str_view(), "define F(x, y) x ## y");
	};
}

fn void macros_only_dump() @test
{
	@with_pp(; Compilation* comp, Preprocessor* pp)
	{
		Source s = add_src(comp, "m.c", "#define A 1\n#define B(x) x\n");
		pp.add_builtin_macros();
		bool found;
		// Zig defineMacro stores the macro NAME's location.
		pp.defines.get_or_put("A", &found).loc = { .id = s.id, .byte_offset = 8, .line = 1 };
		pp.defines.get_or_put("B", &found).loc = { .id = s.id, .byte_offset = 20, .line = 2 };
		pp.tokens.push({ .id = EOF, .loc = { .id = s.id } });
		test::eq(print(pp, MACROS_ONLY), "#define A 1\n#define B(x) x\n");
	};
}

fn void define_tokens_in_dump_modes() @test
{
	@with_pp(; Compilation* comp, Preprocessor* pp)
	{
		Source s = add_src(comp, "m.c", "#define FOO 42\nFOO\n#undef FOO\n");
		push(pp, KEYWORD_DEFINE, s, 1);
		push(pp, NL, s, 14);
		push(pp, PP_NUM, s, 12);
		push(pp, NL, s, 18);
		push(pp, KEYWORD_UNDEF, s, 20, 3);
		push(pp, NL, s, 29, 3);
		push(pp, EOF, s, 30, 4);
		test::eq(print(pp, MACROS_AND_RESULT), "#define FOO 42\n42\n#undef FOO\n");
		test::eq(print(pp, MACRO_NAMES_AND_RESULT), "#define FOO\n42\n#undef FOO\n");
	};
}
