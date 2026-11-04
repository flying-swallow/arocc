// Manual tests for src/c3/macro_expand.c3 (plan 13.3 `expansion`) whose
// paths reach code owned by 13.4 (stringify / paste_tokens /
// make_generated_token in macro_paste.c3) or 13.5 (skip_to_nl in
// pp_directives.c3). Tagged "manual" until those land; the integrator should
// drop the tag (or fold these into macro_expand_tests).
//
// Same driver and provenance labels as macro_expand_tests.c3: "fixture" =
// test/cases/expanded/<name> with whitespace normalized to single spaces
// per line (empty lines dropped) plus manifest diagnostics; "source-derived"
// = read from Preprocessor.zig, no Zig executable was run.
module macro_expand_manual_tests;
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


<* Run `text` with diagnostics option `opt` (a -W name or "pedantic") set to warning. *>
macro @with_opt(String text, String opt; @body(Preprocessor* pp, Diagnostics* d))
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		d.set(opt, WARNING)!!;
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("t.c", text)!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		drive(&pp, src)!!;
		@body(&pp, &d);
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void function_macro_expansion() @test
{
	// fixture: function macro expansion.c
	expect_clean("#define HE HI\n#define LLO _THERE\n#define HELLO \"HI THERE\"\n#define CAT(a,b) a##b\n#define XCAT(a,b) CAT(a,b)\n#define CALL(fn) fn(HE,LLO)\n"
		"CAT(HE, LLO)\nXCAT(HE, LLO)\nCALL(CAT)\n\n#define FOO(a, b) BAR(a, b)\n#define BAR(a, b) a, b\n\nFOO(1, (2, 3))\n\n#define S(...) S()\nS()\n",
		"\"HI THERE\"\nHI_THERE\n\"HI THERE\"\n1 , ( 2 , 3 )\nS ( )");
}

fn void incomplete_paste_call() @test
{
	// fixture: macro re-expansion.c, the INCOMPLETE2 line
	expect_clean("#define g(a, b) a##b\n#define INCOMPLETE2 g(1\nINCOMPLETE2,3)\n", "13");
}

fn void deferred_macro_expansion() @test
{
	// fixture: deferred macro expansion.c
	expect_clean("#define F(acc)          F_PROGRESS(acc)\n#define F_PROGRESS(acc) CONTINUE(F)(acc##X)\n#define F_HOOK()        F\n"
		"#define UNROLL(...)     __VA_ARGS__\n#define DEFER(op)       op EMPTY\n#define EMPTY\n#define CONTINUE(k)     DEFER(k##_HOOK)()\n\nUNROLL(F_PROGRESS(X))\n",
		"F_HOOK ( ) ( XXX )");
}

fn void empty_macro_block_expansion() @test
{
	// fixture: empty macro block expansion.c
	expect_clean("#define CONTINUE(k) DEFER(k##_HOOK)()\n#define DEFER(op) op EMPTY\n#define EMPTY\n#define F_HOOK() F\n\nCONTINUE( F)\nCONTINUE(F)\n",
		"F_HOOK ( )\nF_HOOK ( )");
}

fn void x_macro() @test
{
	// fixture: X macro.c
	expect_clean("#define X(a) Foo_ ## a = a,\nenum Foo {\nX(1)\nX(2)\nX(3)\nX(4)\nX(5)\n};\n",
		"enum Foo {\nFoo_1 = 1 ,\nFoo_2 = 2 ,\nFoo_3 = 3 ,\nFoo_4 = 4 ,\nFoo_5 = 5 ,\n} ;");
}

fn void standard_placeholder_example() @test
{
	// fixture: standard-placeholder-example.c
	expect_clean("#define t(x,y,z) x ## y ## z\nint j[] = { t(1,2,3), t(,4,5), t(6,,7), t(8,9,),\n           t(10,,), t(,11,), t(,,12), t(,,) };\n",
		"int j [ ] = { 123 , 45 , 67 , 89 ,\n10 , 11 , 12 , } ;");
}

fn void placeholder_tokens_pasting() @test
{
	// fixture: placeholder tokens pasting.c
	expect_clean("#define CAT(a, b) a##b\n#define CAT2(a, b) (a##b)\n\nx CAT(,)x\nCAT(,y)\n\nx CAT2(,)x\nCAT2(,y)\nCAT2(x,)\n",
		"x x\ny\nx ( ) x\n( y )\n( x )");
}

fn void macro_token_pasting_order() @test
{
	// fixture: macro token pasting order.c
	expect_clean("#define CAT(a, ...) a ## __VA_ARGS__\n#define M(val) val\n#define TEST(c) CAT(TEST_, c)\n#define abc 1\n\nTEST(M(0))\nCAT(TEST_, M(0))\nCAT(ab, c)\nCAT(a b, c)\n",
		"TEST_0\nTEST_M ( 0 )\n1\na bc");
}

fn void macro_expands_to_self_after_pasting() @test
{
	// fixture: macro expands to self after pasting.c
	expect_clean("#define CAT_PREFIX2(a,b) a ## b\n#define CAT_PREFIX(a,b) CAT_PREFIX2(a, b)\n\n#define speex_resampler_init CAT_PREFIX(speex,_resampler_init)\n"
		"#define speex_resampler_init_frac CAT_PREFIX(speex,_resampler_init_frac)\n\nvoid speex_resampler_init(void);\nvoid speex_resampler_init_frac(void);\n",
		"void speex_resampler_init ( void ) ;\nvoid speex_resampler_init_frac ( void ) ;");
}

fn void apply_pasted_macro_name() @test
{
	// fixture: apply pasted macro name.c
	expect_clean("#define CONCAT_(a, b) a##b\n#define CONCAT(a, b)  CONCAT_(a, b)\n#define APPLY(macro, args) macro args\n\n#define OVERLOAD1(x) x\n\nint call_via_apply = APPLY(CONCAT(OVERLOAD, 1), (7));\n",
		"int call_via_apply = 7 ;");
}

fn void repeated_paste_macro_argument() @test
{
	// fixture: repeated paste macro argument.c (shortened to three uses)
	expect_clean("#define bb aa\n#define aa short(b,b)\n#define short(a, b) a ## b\n#define foo(x) short(x, x) short(x, x) short(x, x)\nfoo(a)\n",
		"short ( b , b ) short ( b , b ) short ( b , b )");
}

fn void standard_redefinition_reexamination_example() @test
{
	// fixture: standard-redefinition-reexamination-example.c without the `h`
	// line (its `\` token) and with the m/(f) call kept on one output line
	// (its newline is consumed while collecting arguments).
	expect_clean("#define x 3\n#define f(a) f(x * (a)) \n#undef x\n#define x 2\n#define g f\n#define z z[0]\n#define m(a) a(w)\n#define w 0,1\n"
		"#define t(a) a\n#define p() int\n#define q(x) x\n#define r(x,y) x ## y\n#define str(x) # x\n"
		"f(y+1) + f(f(z)) % t(t(g)(0) + t)(1);\ng(x+(3,4)-w) & m\n     (f)^m(m);\np() i[q()] = { q(1), r(2,3), r(4,), r(,5), r(,) };\nchar c[2][6] = { str(hello), str() };\n",
		"f ( 2 * ( y + 1 ) ) + f ( 2 * ( f ( 2 * ( z [ 0 ] ) ) ) ) % f ( 2 * ( 0 ) ) + t ( 1 ) ;\n"
		"f ( 2 * ( 2 + ( 3 , 4 ) - 0 , 1 ) ) & f ( 2 * ( 0 , 1 ) ) ^ m ( 0 , 1 ) ;\n"
		"int i [ ] = { 1 , 23 , 4 , 5 , } ;\nchar c [ 2 ] [ 6 ] = { \"hello\" , \"\" } ;");
}

fn void var_args_stringify() @test
{
	// fixture: var args macro functions.c, gnu variadic macros.c
	expect_clean("#define foo(a,...) #__VA_ARGS__\nfoo(1,2,3,4,5,6)\n", "\"2,3,4,5,6\"");
	expect_clean("#define a(foo, args...) #args, foo __VA_ARGS__ args\na(1,2,3,4)\n", "\"2,3,4\" , 1 __VA_ARGS__ 2 , 3 , 4");
}

fn void empty_variadic_paste() @test
{
	// fixture: empty variadic paste.c (-pedantic)
	@with_opt("#define ASM_SIZE(inst, ...)   ASM_SEL(inst##l##__VA_ARGS__, \\\n                                          inst##q##__VA_ARGS__)\n\nASM_SIZE(bts)\n", "pedantic"; Preprocessor* pp, Diagnostics* d)
	{
		test::eq(render(pp), "ASM_SEL ( btsl , btsq )");
		check(d.messages.len(), 2);
		String m = "passing no argument for the '...' parameter of a variadic macro is incompatible with C standards before C23";
		expect_msg(d, 0, m, 1, 48);
		expect_msg(d, 1, m, 2, 52);
	};
}

fn void va_opt_fixture() @test
{
	// fixture: __VA_OPT__.c diagnostics; output source-derived.
	@with_pp("#define foo(...) __VA_OPT__(1, 2, ) __VA_OPT__(3, 4)\nfoo(1)\n\n#define bar(...)  a ## __VA_OPT__(3, 4) +\nbar()\n\n#define baz() __VA_OPT__(1)\nbaz()\n\n"
		"#define invalid1(...) __VA_OPT__ 1\n#define invalid2(...) __VA_OPT__(1\n\n"; Preprocessor* pp, Diagnostics* d, Source src)
	{
		check(d.messages.len(), 3);
		expect_msg(d, 0, "missing '(' following __VA_OPT__", 10, 33);
		expect_msg(d, 1, "unterminated __VA_OPT__ argument list", 12, 35);
		expect_msg(d, 2, "to match this '('", 11, 33);
		test::eq(render(pp), "1 , 2 , 3 , 4\na +\n__VA_OPT__ ( 1 )");
		assert(!pp.defines.contains("invalid1"));
		assert(!pp.defines.contains("invalid2"));
	};
}

fn void macro_definition_errors() @test
{
	// fixture: macro definition errors.c (the #define lines)
	@with_pp("#define one a ##\n#define two a ## ##\n#define three ##\n#define four(1)\n#define five(a,... b\n#define six(a 1)\n#define seven(a) #b\n"
		"#define eight(a) ##\n#define nine(a) a ##\n#define ten##\n"; Preprocessor* pp, Diagnostics* d, Source src)
	{
		check(d.messages.len(), 12);
		expect_msg(d, 0, "'##' cannot appear at the end of a macro expansion", 1, 15);
		expect_msg(d, 1, "'##' cannot appear at the end of a macro expansion", 2, 18);
		expect_msg(d, 2, "'##' cannot appear at the start of a macro expansion", 3, 15);
		expect_msg(d, 3, "invalid token in macro parameter list", 4, 14);
		expect_msg(d, 4, "missing ')' in macro parameter list", 5, 20);
		expect_msg(d, 5, "to match this '('", 5, 13);
		expect_msg(d, 6, "expected comma in macro parameter list", 6, 15);
		expect_msg(d, 7, "'#' is not followed by a macro parameter", 7, 19);
		expect_msg(d, 8, "'##' cannot appear at the start of a macro expansion", 8, 18);
		expect_msg(d, 9, "'##' cannot appear at the end of a macro expansion", 9, 19);
		expect_msg(d, 10, "ISO C99 requires whitespace after the macro name", 10, 12);
		expect_msg(d, 11, "'##' cannot appear at the start of a macro expansion", 10, 12);
		test::eq(render(pp), "");
		check(pp.defines.len(), 0);
	};
}

fn void nested_unterminated_macro() @test
{
	// fixtures: nested unterminated macro clang.c / gcc.c (diagnostics only)
	String text = "#define str(s) # s\n#define xstr(s) str(s)\n#define INCFILE(n) str(strcmp(\nxstr(INCFILE(2)) INCFILE(2))\n";
	foreach (emulate : (Compiler[]){ CLANG, GCC })
	{
		@with_pp(text, emulate; Preprocessor* pp, Diagnostics* d, Source src)
		{
			check(d.messages.len(), 4);
			expect_msg(d, 0, "unterminated function macro argument list", 4, 6);
			expect_msg(d, 1, "expanded from here", 3, 20);
			expect_msg(d, 2, "unterminated function macro argument list", 4, 18);
			expect_msg(d, 3, "expanded from here", 3, 20);
		};
	}
}

fn void stringify_generated_token_locations() @test
{
	// source-derived: the stringified token is generated (GENERATED_ID) and
	// carries [the '#' location in the body, the macro name].
	@with_pp("#define S(x) #x\nS(a b)\n"; Preprocessor* pp, Diagnostics* d, Source src)
	{
		test::eq(render(pp), "\"a b\"");
		assert(pp.tokens[0].loc.id.is_generated());
		Location[] l = pp.expansion_slice(0);
		check(l.len, 2);
		check(l[0].byte_offset, 13);
		check(l[1].byte_offset, 16);
	};
}
