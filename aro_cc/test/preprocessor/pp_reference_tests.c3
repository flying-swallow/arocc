// Tests ported from the Zig reference tests in src/aro/Preprocessor.zig:
// "Preserve pragma tokens sometimes" (lines 3991-4049) and "Include guards"
// (lines 4082-4177). Expected values are copied from the Zig source and are
// not loosened. The include guard test does not stop at the first mismatch:
// every failing tag/template combination is printed and counted, and the
// test fails at the end if the count is not zero. The Zig "destringify" test
// between the two is ported elsewhere.
module pp_reference_tests;
import aro::frontend::c::preprocessor, aro::frontend::c::tokens, aro::frontend::c::tokenizer, aro::source, aro::frontend::c::compilation, aro::frontend::c::diagnostics;
import aro::frontend::c::pragma, aro::frontend::c::pragmas::gcc, aro::frontend::c::pragmas::once, aro::frontend::c::pragmas::message, aro::frontend::c::pragmas::pack;
import std::io, std::core::mem::allocators, std::core::dstring, std::core::string;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

<*
 Preprocess `text` with the default pragma handlers and preserve_whitespace
 set, as Zig's runPreprocessor does, and return the result-only pretty print
 (allocated from tmem). Checks for leaks.
*>
fn String run_pp(String text)
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	DString out;
	out.init(tmem);
	{
		Compilation comp;
		comp.init(&ta, compilation::native_definition());
		// Registration stays outside assert(): C3 strips asserts in release builds.
		bool gcc_added = comp.pragmas.add("GCC", gcc::make_handler(comp.gpa));
		bool once_added = comp.pragmas.add("once", once::handler(comp.gpa));
		bool message_added = comp.pragmas.add("message", message::handler());
		bool pack_added = comp.pragmas.add("pack", pack::make_handler(comp.gpa));
		assert(gcc_added && once_added && message_added && pack_added);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		pp.preserve_whitespace = true;
		assert(pp.linemarkers == NONE);
		Source src = comp.add_source_from_buffer("<test_runner>", text)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		pp.pretty_print_tokens(&out, RESULT_ONLY)!!;
		pp.free();
		comp.free();
	}
	check(ta.allocation_count(), 0);
	return out.str_view();
}

fn void preserve_pragma_tokens_sometimes() @test
{
	String gcc_diagnostic = "#pragma GCC diagnostic error \"-Wnewline-eof\"\n#pragma GCC warning error \"-Wnewline-eof\"\nint x;\n#pragma GCC ignored error \"-Wnewline-eof\"\n";
	test::eq(run_pp(gcc_diagnostic), gcc_diagnostic);
	// TODO should only be one newline afterwards when emulating clang
	test::eq(run_pp("#pragma once\nint x;\n#pragma once\n"), "\nint x;\n\n");
	test::eq(run_pp("#pragma GCC poison foobar\n"), "\n");
}

<* Zig pairsWithIfndef: whether a directive keyword pairs with an #ifndef guard. *>
fn bool pairs_with_ifndef(TokenId tok)
{
	switch (tok)
	{
		case KEYWORD_ELIF:
		case KEYWORD_ELIFDEF:
		case KEYWORD_ELIFNDEF:
		case KEYWORD_ELSE:
			return true;
		case KEYWORD_INCLUDE:
		case KEYWORD_INCLUDE_NEXT:
		case KEYWORD_EMBED:
		case KEYWORD_DEFINE:
		case KEYWORD_DEFINED:
		case KEYWORD_UNDEF:
		case KEYWORD_IFDEF:
		case KEYWORD_IFNDEF:
		case KEYWORD_ERROR:
		case KEYWORD_WARNING:
		case KEYWORD_PRAGMA:
		case KEYWORD_LINE:
		case KEYWORD_ENDIF:
			return false;
		default:
			unreachable("pairs_with_ifndef: tag not covered by the Zig switch");
	}
}

<* Zig skippable: tags the include guard test never tries. *>
fn bool skippable(TokenId tok)
{
	switch (tok)
	{
		case KEYWORD_DEFINED:
		case KEYWORD_VA_ARGS:
		case KEYWORD_VA_OPT:
		case KEYWORD_ENDIF:
			return true;
		default:
			return false;
	}
}

<* Text appended after the directive name in the Zig testIncludeGuard switch. *>
fn String suffix_for(TokenId tok)
{
	switch (tok)
	{
		case KEYWORD_INCLUDE:
		case KEYWORD_INCLUDE_NEXT:
			return " \"bar.h\"";
		case KEYWORD_DEFINE:
		case KEYWORD_UNDEF:
			return " BAR";
		case KEYWORD_IFNDEF:
		case KEYWORD_IFDEF:
		case KEYWORD_ELIFDEF:
		case KEYWORD_ELIFNDEF:
			return " BAR\n#endif";
		default:
			return "";
	}
}

<*
 Preprocess `text` as test.h with bar.h available and compare the number of
 include guards recorded with `expected`. A preprocess fault counts as a
 failure. Prints one line for a mismatch and returns 1, or returns 0. Checks
 for leaks.
*>
fn int guard_case(TokenId tag, String kind, String text, int expected)
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	int failed = 0;
	{
		Compilation comp;
		comp.init(&ta, compilation::native_definition());
		comp.add_source_from_buffer("bar.h", "int bar = 5;\n")!!;
		Source src = comp.add_source_from_buffer("test.h", text)!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, comp.file_provider())!!;
		TokenWithExpansionLocs? r = pp.preprocess(src);
		fault f = @catch(r);
		int actual = (int)pp.include_guards.len();
		if (!f)
		{
			if (actual != expected)
			{
				failed = 1;
				io::eprintfn("include guard %s (%s): expected %d guard(s), got %d", string::tformat("%s", tag), kind, expected, actual);
			}
		}
		else
		{
			failed = 1;
			io::eprintfn("include guard %s (%s): expected %d guard(s), got fault %s", string::tformat("%s", tag), kind, expected, f);
		}
		pp.free();
		comp.free();
	}
	check(ta.allocation_count(), 0);
	return failed;
}

fn void include_guards() @test
{
	int failures = 0;
	foreach (tag : TokenId::values)
	{
		if (skippable(tag)) continue;
		TokenId copy = tag;
		copy.simplify_macro_keyword();
		if (copy == tag && tag != KEYWORD_ELSE) continue;
		String name = tag.lexeme()!!;
		String suffix = suffix_for(tag);
		int expected_inside = pairs_with_ifndef(tag) ? 0 : 1;

		DString inside;
		inside.init(mem);
		inside.append("//Leading comment (should be ignored)\n\n#ifndef FOO\n#");
		inside.append(name);
		inside.append(suffix);
		inside.append("\n#endif");
		failures += guard_case(tag, "inside", inside.str_view(), expected_inside);
		inside.free();

		DString outside;
		outside.init(mem);
		outside.append("#ifndef FOO\n#endif\n#");
		outside.append(name);
		outside.append(suffix);
		failures += guard_case(tag, "outside", outside.str_view(), 0);
		outside.free();
	}
	test::eq(failures, 0);
}
