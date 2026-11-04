// Tests for src/c3/macro_expand.c3 (plan 13.3 `expansion`): #define parsing
// and redefinition checks, function-macro argument collection, exhaustive
// rescanning, hideset recursion blocking, __VA_ARGS__ / __VA_OPT__ /
// placemarkers, GNU comma deletion and expansion-location chains.
//
// These tests only use paths that do not reach the 13.4 (stringify / paste)
// or 13.5 (directives) code, so they run against the stage-0 stubs of those
// files. A tiny in-test driver stands in for preprocessExtra: it handles
// `#define` (Preprocessor.define), `#undef` (removes the macro) and sends
// every other token through Preprocessor.expand_macro, keeping NL tokens so
// the output can be split into lines.
//
// Output comparison: output tokens are joined with single spaces per line and
// empty lines are dropped. Provenance of the expected values:
//  - "fixture": the token sequence of test/cases/expanded/<name> with the
//    whitespace normalized the same way (the fixture is rendered by Zig's
//    prettyPrintTokens, which this test does not use), and diagnostics text,
//    line and column from the fixture's manifest.
//  - "source-derived": read from Preprocessor.zig by hand; no Zig executable
//    was run.
module macro_expand_tests;
import aro::preprocessor, aro::tokens, aro::tokenizer, aro::source, aro::compilation, aro::diagnostics;
import aro::hideset, aro::lang_opts;
import std::io, std::core::string, std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

<* Minimal stand-in for preprocessExtra: #define / #undef, NL, everything else expand_macro. *>
fn void? drive(Preprocessor* pp, Source src)
{
	Tokenizer t;
	t.init(src.buf, src.id, pp.comp.langopts, src.splice_locs);
	bool start_of_line = true;
	while (true)
	{
		Token tok = t.next();
		switch (tok.id)
		{
			case EOF:
				return;
			case NL:
				start_of_line = true;
				pp.add_token(tokens::from_raw(tok))!;
			case WHITESPACE:
			case COMMENT:
				break;
			case HASH:
				if (!start_of_line) nextcase default;
				Token directive = t.next_no_ws();
				if (directive.id == KEYWORD_DEFINE)
				{
					pp.define(&t, directive)!;
				}
				else if (directive.id == KEYWORD_UNDEF)
				{
					Token name = t.next_no_ws();
					pp.defines.ordered_remove(pp.tok_slice(name));
					while (true)
					{
						Token n = t.next();
						if (n.id == NL || n.id == EOF) break;
					}
				}
				else
				{
					unreachable("test driver only handles #define and #undef");
				}
				start_of_line = true;
			default:
				start_of_line = false;
				pp.expand_macro(&t, tok)!;
		}
	}
}

<* The output, one line per source line: tokens joined by single spaces, empty lines dropped (temp-allocated). *>
fn String render(Preprocessor* pp)
{
	DString out;
	out.tinit();
	DString line;
	line.tinit();
	foreach (tok : pp.tokens)
	{
		// WHITESPACE comes from re-tokenized __VA_OPT__ contents.
		if (tok.id == WHITESPACE) continue;
		// The raw EOF that nextBufToken pulled while collecting an unterminated call.
		if (tok.id == EOF) continue;
		if (tok.id == NL)
		{
			if (line.len())
			{
				if (out.len()) out.append("\n");
				out.append(line.str_view());
				line.clear();
			}
			continue;
		}
		if (line.len()) line.append(" ");
		line.append(pp.tree_token_slice(tok));
	}
	if (line.len())
	{
		if (out.len()) out.append("\n");
		out.append(line.str_view());
	}
	return out.str_view();
}

<*
 Preprocess `text` with the test driver and run the body; checks that every
 allocation (including token expansion arrays) is released.
*>
macro @with_pp(String text, Compiler emulate = CLANG, String standard = ""; @body(Preprocessor* pp, Diagnostics* d, Source src))
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.set_emulated_compiler(emulate);
		if (standard.len) comp.langopts.set_standard(standard)!!;
		Source src = comp.add_source_from_buffer("t.c", text)!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		drive(&pp, src)!!;
		@body(&pp, &d, src);
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

<* Expect exactly `want` as output and no diagnostics. *>
fn void expect_clean(String text, String want, Compiler emulate = CLANG, String standard = "")
{
	@with_pp(text, emulate, standard; Preprocessor* pp, Diagnostics* d, Source src)
	{
		test::eq(render(pp), want);
		check(d.messages.len(), 0);
	};
}

<* Expect message `i` to be `text` at line:col. *>
fn void expect_msg(Diagnostics* d, sz i, String text, uint line, uint col)
{
	assert(i < d.messages.len(), "missing diagnostic %d (%s)", i, text);
	test::eq(d.messages[i].text, text);
	check(d.messages[i].location.line_no, line);
	check(d.messages[i].location.col, col);
}

// ---------------------------------------------------------------------------
// Object-like macros and recursion blocking

fn void object_macro_expansion() @test
{
	// fixture: object macro expansion.c
	expect_clean("#define x a\nx\n#define a 1\nx\n#define y define\ny\n\n#define __restrict restrict\n\n#define empty\nempty\n",
		"a\n1\ndefine");
}

fn void recursive_object_macro() @test
{
	// fixture: recursive object macro.c
	expect_clean("#define y x\n#define x y\nx\n\n#undef y\n#undef x\n\n#define x x\nx\n\n#define int int\nint\n",
		"x\nx\nint");
}

fn void macro_self_definition() @test
{
	// fixture: macro self definition.c
	expect_clean("#define FOO FOO\n\nFOO\n\n#define BAR BAZ\n#define BAZ BAR\n\nBAR\nBAZ\n", "FOO\nBAR\nBAZ");
}

fn void macro_expansion_exhaustion() @test
{
	// fixture: macro expansion exhaustion.c
	expect_clean("#define CREATE_CALL F\n#define F(x) (x + 2)\n\nCREATE_CALL(2)\n", "( 2 + 2 )");
}

// ---------------------------------------------------------------------------
// Function-like macros

fn void recursive_func_macro() @test
{
	// fixture: recursive func macro.c
	expect_clean("#define F(x) G(x)\n#define G(x) F(x)\n\nF(1)\n", "F ( 1 )");
}

fn void recursive_call_non_expanded_parens() @test
{
	// fixture: recursive call non-expanded parens.c
	expect_clean("#define foo(X) 1 bar\n#define bar(X) 2 foo\n\nfoo(X)(Y)(Z)\n", "1 2 1 bar");
}

fn void nested_macro_call() @test
{
	// fixture: nested macro call.c
	expect_clean("#define A(x) x\n#define B(x) A(x)\n\nB(B(x))\nA(B(x))\n", "x\nx");
}

fn void rparen_hideset_in_argument_expansion() @test
{
	// fixture: rparen hideset in argument expansion.c
	expect_clean("#define A(m) m( B(f)\n#define B(x) A(x)\n\n#define C(x) < x >\n\nA(C) ) *\n", "< f ( B ( f ) > *");
}

fn void macro_expansion_disabled() @test
{
	// fixture: macro expansion disabled.c
	expect_clean("#define EMPTY()\n#define LOOP_INDIRECTION() LOOP\n#define LOOP(x) x LOOP_INDIRECTION EMPTY()() (x)\nLOOP(1)\n\n"
		"#define DEFER(id) id EMPTY()\n#define EXPAND(...) __VA_ARGS__\n\n#define A() 123\nEXPAND(DEFER(A)())\n",
		"1 LOOP_INDIRECTION ( ) ( 1 )\n123");
}

fn void lazy_macro() @test
{
	// fixture: lazy macro.c
	expect_clean("#define REC_EMPTY\n#define REC_DEFER(op) op REC_EMPTY\n\n#define REC_0_HOOK() REC_0\n#define REC_1 REC_DEFER(REC_0_HOOK)()\n\nREC_1\n",
		"REC_0_HOOK ( )");
}

fn void unspecified_expansion() @test
{
	// fixture: unspecified expansion.c
	expect_clean("#define f(a) a*g\n#define g(a) f(a)\n\nf(2)(9)\n", "2 * 9 * g");
}

fn void macro_unbalanced_parens_call() @test
{
	// fixture: macro unbalanced parens call.c
	expect_clean("#define FIRST(x) x\n#define SECOND FIRST\n#define THIRD SECOND( FIRST\nTHIRD 42)\n", "FIRST 42");
}

fn void macro_re_expansion() @test
{
	// fixture: macro re-expansion.c, without INCOMPLETE2 (it pastes with ##;
	// see macro_expand_manual_tests).
	expect_clean("#define f(a) a\n#define z z[0]\n\n#define h(x) f(x(1))\n#define s(x) z\n\n#define K h(s)\n\n#define H h\n\n#define L H\n\n"
		"#define SS (s)\n\n#define INCOMPLETE f(1\n\n#define Z1 z Z2\n#define Z2 z Z1\n\n"
		"#define THETA(x) x f\n#define TAU(x) x TAU\n#define OMEGA(x) TAU(x)(1) THETA(x)\n\n"
		"f(f(z))\nh(s)\nK\nH(s)\nL(s)\nH SS\nINCOMPLETE)\nZ1\nTAU(1)(2)\nOMEGA(1)(z)\n",
		"z [ 0 ]\nz [ 0 ]\nz [ 0 ]\nz [ 0 ]\nz [ 0 ]\nh ( s )\n1\nz [ 0 ] z [ 0 ] Z1\n1 TAU ( 2 )\n1 TAU ( 1 ) 1 z [ 0 ]");
}

fn void whitespace_macro_arguments() @test
{
	// fixture: whitespace macro arguments.c (whitespace-only lines dropped)
	expect_clean("#define h() 1\n#define g(x) x\n#define f(x, y) g(y) x\n\n#define p(...) h(__VA_ARGS__)\n#define q(e, ...) f(e, __VA_ARGS__)\n\n"
		"h()\ng()\nf(1,)\nf(1,q)\nf(,)\np()\nq(3, 2)\nq(, 3)\n",
		"1\n1\nq 1\n1\n2 3\n3");
}

fn void arguments_span_lines() @test
{
	// source-derived: nextBufToken pulls tokens (including newlines) from the
	// tokenizer while collecting arguments; newlines become MACRO_WS.
	expect_clean("#define f(a, b) b a\nf(1,\n  2\n) end\n", "2 1 end");
	// Nested parentheses and commas inside them stay in one argument.
	expect_clean("#define first(a, b) a\nfirst((1, 2), 3)\n", "( 1 , 2 )");
	// A function-like macro name without '(' is not a call.
	expect_clean("#define f(a) a\nf + f\n", "f + f");
	expect_clean("#define f(a) a\nf\n\n(9)\n", "9");
}

// ---------------------------------------------------------------------------
// Variadic macros, __VA_OPT__, placemarkers, GNU comma deletion

fn void var_args_macro_functions() @test
{
	// fixture: var args macro functions.c (second macro; the first stringifies)
	expect_clean("#define bar(a,...) bar __VA_ARGS__\n#define baz(a,...) baz bar(__VA_ARGS__)\nbaz(1,2,3,4)\n", "baz bar 3 , 4");
}

fn void gnu_variadic_macros() @test
{
	// fixture: gnu variadic macros.c without the '#args' stringification;
	// the warning is enabled by -Wpedantic in the fixture.
	@with_pp("#define a(foo, args...) foo __VA_ARGS__ args\na(1,2,3,4)\n"; Preprocessor* pp, Diagnostics* d, Source src)
	{
		test::eq(render(pp), "1 __VA_ARGS__ 2 , 3 , 4");
	};
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		d.set("pedantic", WARNING)!!;
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("t.c", "#define a(foo, args...) #args, foo __VA_ARGS__ args\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		drive(&pp, src)!!;
		check(d.messages.len(), 1);
		expect_msg(&d, 0, "named variadic macros are a GNU extension", 1, 20);
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void va_opt() @test
{
	// fixture: __VA_OPT__.c line 2 (expand_error fixture: values source-derived
	// from expandVaOpt, which re-tokenizes the __VA_OPT__ contents).
	expect_clean("#define foo(...) __VA_OPT__(1, 2, ) __VA_OPT__(3, 4)\nfoo(1)\nfoo()\n", "1 , 2 , 3 , 4");
	// source-derived
	expect_clean("#define F(a, ...) f(a __VA_OPT__(,) __VA_ARGS__)\nF(1)\nF(1, 2, 3)\n", "f ( 1 )\nf ( 1 , 2 , 3 )");
	// source-derived: without '...' __VA_OPT__ is simplified to a plain identifier.
	expect_clean("#define baz() __VA_OPT__(1)\nbaz()\n", "__VA_OPT__ ( 1 )");
}

fn void placemarkers_dropped() @test
{
	// source-derived: an empty object macro expands to a PLACEMARKER, which
	// remove_placemarkers / add_tokens_from_expand_buf drop.
	expect_clean("#define E\n#define f(x) [x]\nf(E) f() E E\n", "[ ] [ ]");
}

fn void token_paste_delete_comma_gnu() @test
{
	// fixture: token paste delete comma gnu.c (-Wgnu-zero-variadic-macro-arguments)
	String text = "#define eprintf(format, ...) fprintf (stderr, format, ##__VA_ARGS__)\neprintf(\"foo\");\neprintf(\"foo\",);\neprintf(\"foo\", \"bar\");\n\n"
		"#define ZERO_ARGS(...) foo(a, ##__VA_ARGS__)\n\nZERO_ARGS()\nZERO_ARGS(b)\n\n"
		"#define foo(a,...) a, ## __VA_ARGS__\n#define bar\n\nfoo(1,bar)\n";
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		d.set("gnu-zero-variadic-macro-arguments", WARNING)!!;
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("t.c", text)!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		drive(&pp, src)!!;
		test::eq(render(&pp), "fprintf ( stderr , \"foo\" ) ;\nfprintf ( stderr , \"foo\" , ) ;\nfprintf ( stderr , \"foo\" , \"bar\" ) ;\nfoo ( a )\nfoo ( a , b )\n1 ,");
		check(d.messages.len(), 5);
		String m = "token pasting of ',' and __VA_ARGS__ is a GNU extension";
		expect_msg(&d, 0, m, 1, 55);
		expect_msg(&d, 1, m, 1, 55);
		expect_msg(&d, 2, m, 6, 31);
		expect_msg(&d, 3, m, 6, 31);
		expect_msg(&d, 4, m, 11, 23);
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void empty_va_args_comma_delete_c99() @test
{
	// fixture: empty va args comma delete c99.c (-std=c99 keeps the comma)
	expect_clean("#define ZERO_ARGS(...) foo(a, ##__VA_ARGS__)\n\nZERO_ARGS()\nZERO_ARGS(b)\n", "foo ( a , )\nfoo ( a , b )", CLANG, "c99");
}

// ---------------------------------------------------------------------------
// Argument-count and unterminated-call errors

fn void incorrect_macro_arg_count() @test
{
	// fixture: incorrect macro arg count.c. Output source-derived: the call's
	// arguments are removed but the macro name stays.
	@with_pp("#define TWO_ARGS(A, B) A B\n\nTWO_ARGS()\nTWO_ARGS(A)\nTWO_ARGS(A, B, C)\nTWO_ARGS(,,,)\n"; Preprocessor* pp, Diagnostics* d, Source src)
	{
		check(d.messages.len(), 4);
		expect_msg(d, 0, "expected 2 argument(s) got 1", 3, 1);
		expect_msg(d, 1, "expected 2 argument(s) got 1", 4, 1);
		expect_msg(d, 2, "expected 2 argument(s) got 3", 5, 1);
		expect_msg(d, 3, "expected 2 argument(s) got 4", 6, 1);
		test::eq(render(pp), "TWO_ARGS\nTWO_ARGS\nTWO_ARGS\nTWO_ARGS");
	};
}

fn void indirect_macro_invocation_wrong_arg_count() @test
{
	// fixture: indirect macro invocation wrong arg count.c
	@with_pp("#define h(x) x(0)\n#define s()\nh(s)\n"; Preprocessor* pp, Diagnostics* d, Source src)
	{
		check(d.messages.len(), 3);
		expect_msg(d, 0, "expected 0 argument(s) got 1", 3, 1);
		expect_msg(d, 1, "expanded from here", 1, 14);
		expect_msg(d, 2, "expanded from here", 3, 3);
	};
}

fn void at_least_arguments() @test
{
	// source-derived: expected_at_least_arguments (a warning) for too few
	// named arguments of a variadic macro.
	@with_pp("#define v(a, b, ...) a b\nv(1)\n"; Preprocessor* pp, Diagnostics* d, Source src)
	{
		check(d.messages.len(), 1);
		expect_msg(d, 0, "expected at least 2 argument(s) got 1", 2, 1);
		check(d.messages[0].effective_kind.ordinal, MessageKind.WARNING.ordinal);
		test::eq(render(pp), "v");
	};
}

fn void unmatched_macro_paren() @test
{
	// fixture: unmatched macro paren.c. Output source-derived: the tokenizer
	// is restored to just after the name and the collected tokens (clang:
	// including the name) are removed, so the rest is re-read normally.
	@with_pp("#define f(x) x\n\nf(1\n"; Preprocessor* pp, Diagnostics* d, Source src)
	{
		check(d.messages.len(), 1);
		expect_msg(d, 0, "unterminated function macro argument list", 3, 1);
		test::eq(render(pp), "( 1");
		// source-derived: the raw EOF appended to the expansion buffer by
		// nextBufToken stays there and reaches the output (Zig does the same).
		check(pp.tokens[1].id.ordinal, TokenId.EOF.ordinal); // [0] is the blank line's NL
	};
	@with_pp("#define f(x) x\n\nf(1\n", GCC; Preprocessor* pp, Diagnostics* d, Source src)
	{
		check(d.messages.len(), 1);
		test::eq(render(pp), "f ( 1");
		check(pp.tokens[2].id.ordinal, TokenId.EOF.ordinal);
	};
}

// ---------------------------------------------------------------------------
// Definitions and redefinitions

fn void macro_redefinition() @test
{
	// fixture: macro redefinition.c
	@with_pp("#define FOO 1\n#define FOO 2\n#define FOO 3\n#define FOO 3\n\n#define BAR 1 /* fjfao */  /* fjfao */ 2\n#define BAR 1 2\n\n"
		"#define BAZ + /* fjfao */  /* fjfao */ /\n#define BAZ +/\n\n#define QUX 1 /* FJDLKS */\n#define QUX 1\n"; Preprocessor* pp, Diagnostics* d, Source src)
	{
		check(d.messages.len(), 6);
		expect_msg(d, 0, "'FOO' macro redefined", 2, 9);
		expect_msg(d, 1, "previous definition is here", 1, 9);
		expect_msg(d, 2, "'FOO' macro redefined", 3, 9);
		expect_msg(d, 3, "previous definition is here", 2, 9);
		expect_msg(d, 4, "'BAZ' macro redefined", 10, 9);
		expect_msg(d, 5, "previous definition is here", 9, 9);
	};
}

fn void function_macro_redefinition() @test
{
	// source-derived (Macro.eql): parameter names and var_args take part.
	@with_pp("#define F(a) a\n#define F(a) a\n#define F(b) a\n#define G(a, ...) a\n#define G(a, ...) a\n#define G(a) a\n"; Preprocessor* pp, Diagnostics* d, Source src)
	{
		check(d.messages.len(), 4);
		expect_msg(d, 0, "'F' macro redefined", 3, 9);
		expect_msg(d, 1, "previous definition is here", 2, 9);
		expect_msg(d, 2, "'G' macro redefined", 6, 9);
		expect_msg(d, 3, "previous definition is here", 5, 9);
		Macro* g = pp.defines.get("G");
		assert(g.is_func && !g.var_args);
		check(g.params.len, 1);
	};
}

fn void builtin_macro_redefinition() @test
{
	// source-derived: redefining a builtin warns without a previous-definition note.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("t.c", "#define __LINE__ 1\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		pp.add_builtin_macro("__LINE__", preprocessor::builtin_obj(LINE));
		drive(&pp, src)!!;
		check(d.messages.len(), 1);
		expect_msg(&d, 0, "redefining builtin macro", 1, 9);
		assert(!pp.defines.get("__LINE__").is_builtin());
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void keyword_hidden_by_macro() @test
{
	// fixture: keyword hidden by macro.c (-pedantic), without the #include line.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		d.set("pedantic", WARNING)!!;
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("t.c", "#define int foo\n#define include hello\n\n#define if then\n#define alignof _Alignof\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		drive(&pp, src)!!;
		check(d.messages.len(), 2);
		expect_msg(&d, 0, "keyword is hidden by macro definition", 1, 9);
		expect_msg(&d, 1, "keyword is hidden by macro definition", 4, 9);
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void definition_body_shapes() @test
{
	// source-derived: body whitespace runs become one generated MACRO_WS,
	// leading/trailing whitespace is dropped, parameters become MACRO_PARAM
	// with end = index, and a MACRO_PARAM before ## becomes
	// MACRO_PARAM_NO_EXPAND; `#x` becomes STRINGIFY_PARAM.
	@with_pp("#define O   a    b  \n#define F(x, y)  y ## x  #x z\n#define E\n#define V(...) __VA_ARGS__\n"; Preprocessor* pp, Diagnostics* d, Source src)
	{
		check(d.messages.len(), 0);
		Macro* o = pp.defines.get("O");
		assert(!o.is_func);
		check(o.tokens.len, 3);
		check(o.tokens[0].id.ordinal, TokenId.IDENTIFIER.ordinal);
		check(o.tokens[1].id.ordinal, TokenId.MACRO_WS.ordinal);
		assert(o.tokens[1].source.is_generated());
		check(o.tokens[2].id.ordinal, TokenId.IDENTIFIER.ordinal);
		check(o.loc.byte_offset, 8);

		Macro* f = pp.defines.get("F");
		assert(f.is_func && !f.var_args);
		check(f.params.len, 2);
		test::eq(f.params[0], "x");
		test::eq(f.params[1], "y");
		// '##' clears the pending whitespace, so there is no MACRO_WS before it.
		TokenId[] want = { MACRO_PARAM_NO_EXPAND, HASH_HASH, MACRO_WS, MACRO_PARAM, MACRO_WS, STRINGIFY_PARAM, MACRO_WS, IDENTIFIER };
		check(f.tokens.len, want.len);
		foreach (i, w : want) check(f.tokens[i].id.ordinal, w.ordinal);
		check(f.tokens[0].end, 1);
		check(f.tokens[3].end, 0);
		check(f.tokens[5].end, 0);

		Macro* e = pp.defines.get("E");
		check(e.tokens.len, 0);
		Macro* v = pp.defines.get("V");
		assert(v.is_func && v.var_args);
		check(v.params.len, 0);
		check(v.tokens.len, 1);
		check(v.tokens[0].id.ordinal, TokenId.KEYWORD_VA_ARGS.ordinal);
	};
}

fn void definition_errors_without_skip() @test
{
	// fixture: macro definition errors.c lines 1, 2 and 9 (these return
	// without skip_to_nl); the rest are in macro_expand_manual_tests.
	@with_pp("#define one a ##\n#define two a ## ##\n#define nine(a) a ##\n"; Preprocessor* pp, Diagnostics* d, Source src)
	{
		check(d.messages.len(), 3);
		expect_msg(d, 0, "'##' cannot appear at the end of a macro expansion", 1, 15);
		expect_msg(d, 1, "'##' cannot appear at the end of a macro expansion", 2, 18);
		expect_msg(d, 2, "'##' cannot appear at the end of a macro expansion", 3, 19);
		assert(!pp.defines.contains("one"));
		assert(!pp.defines.contains("two"));
		assert(!pp.defines.contains("nine"));
	};
}

// ---------------------------------------------------------------------------
// Expansion locations and hidesets

fn void expansion_locations() @test
{
	// source-derived: object macro tokens get [name loc]; a substituted
	// argument gets [param loc in body, call name loc]; body tokens of a
	// function macro get [call name loc].
	@with_pp("#define X y\nX\n#define F(a) a+1\nF(z)\n"; Preprocessor* pp, Diagnostics* d, Source src)
	{
		test::eq(render(pp), "y\nz + 1");
		check(d.messages.len(), 0);
		// tokens: y NL z + 1 NL (the NL of the #define lines are consumed by define)
		TokenIndex y = 0;
		test::eq(pp.tree_token_slice(pp.tokens[y]), "y");
		Location[] l = pp.expansion_slice(y);
		check(l.len, 1);
		check(l[0].byte_offset, 12); // X on line 2
		check(l[0].line, 2);

		TokenIndex z = 2;
		test::eq(pp.tree_token_slice(pp.tokens[z]), "z");
		l = pp.expansion_slice(z);
		check(l.len, 2);
		check(l[0].byte_offset, 27); // `a` in F's body
		check(l[1].byte_offset, 31); // F on line 4
		l = pp.expansion_slice(z + 1);
		check(l.len, 1);
		check(l[0].byte_offset, 31);
	};
}

fn void nested_expansion_locations() @test
{
	// source-derived: B(y) -> A(y) -> y. y is copied into B's body at `x`
	// (offset 30) and gets B (offset 33); then A's body `x` (offset 13) is
	// appended, then A's own location in B's body (offset 28) and A's chain [B].
	@with_pp("#define A(x) x\n#define B(x) A(x)\nB(y)\n"; Preprocessor* pp, Diagnostics* d, Source src)
	{
		test::eq(render(pp), "y");
		Location[] l = pp.expansion_slice(0);
		uint[] want = { 30, 33, 13, 28, 33 };
		check(l.len, want.len);
		foreach (i, w : want) check(l[i].byte_offset, w);
	};
}

fn void expand_exhaustive_expr_context() @test
{
	// source-derived: in EXPR context `defined X` and `defined ( X )` are
	// skipped, other macros expand, and `defined` produced by an object macro
	// warns -Wexpansion-to-defined.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		d.set("expansion-to-defined", WARNING)!!;
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("t.c", "#define X 1\n#define D defined X\n")!!;
		Source use = comp.add_source_from_buffer("u.c", "defined X && defined ( X ) && X && D")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		drive(&pp, src)!!;

		ExpandBuf buf;
		buf.init(comp.gpa);
		Tokenizer t;
		t.init(use.buf, use.id, comp.langopts);
		while (true)
		{
			Token tok = t.next();
			if (tok.id == EOF) break;
			if (tok.id == WHITESPACE) continue;
		// The raw EOF that nextBufToken pulled while collecting an unterminated call.
		if (tok.id == EOF) continue;
			buf.push(tokens::from_raw(tok));
		}
		pp.expand_macro_exhaustive(null, &buf, 0, buf.len(), EXPR)!!;
		DString s;
		s.tinit();
		foreach (tok : buf)
		{
			if (tok.id == MACRO_WS) continue;
			if (s.len()) s.append(" ");
			s.append(pp.expanded_slice(tok));
		}
		test::eq(s.str_view(), "defined X && defined ( X ) && 1 && defined X");
		check(d.messages.len(), 2);
		test::eq(d.messages[0].text, "macro expansion producing 'defined' has undefined behavior");
		test::eq(d.messages[1].text, "expanded from here");
		preprocessor::free_expand_buf(comp.gpa, &buf);
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void hideset_marks_rescan() @test
{
	// source-derived: after expanding X -> X the produced X carries X in its
	// hideset, so it is not expanded again; the hideset is cleared per
	// top-level expansion.
	@with_pp("#define X X\nX X\n"; Preprocessor* pp, Diagnostics* d, Source src)
	{
		test::eq(render(pp), "X X");
		check(pp.expansion_slice(0).len, 1);
		check(pp.expansion_slice(1).len, 1);
	};
}

fn void token_iterator() @test
{
	TokenWithExpansionLocs[] toks = {
		{ .id = MACRO_WS }, { .id = IDENTIFIER, .loc = { .byte_offset = 1 } }, { .id = WHITESPACE }, { .id = L_PAREN, .loc = { .byte_offset = 3 } },
	};
	TokenIterator it = { .toks = toks };
	TokenWithExpansionLocs out;
	assert(it.next_no_ws(&out));
	check(out.loc.byte_offset, 1);
	check(it.i, 2);
	assert(it.next_no_ws(&out));
	check(out.loc.byte_offset, 3);
	check(it.i, 4);
	assert(!it.next_no_ws(&out));
}
