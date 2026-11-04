// Tests for src/c3/macro_paste.c3 (plan 13.4 `stringify-paste`): stringify,
// destringify, paste_tokens and make_generated_token(_extra). Tokens are fed
// directly (lexed from small buffers; whitespace becomes MACRO_WS as in macro
// argument collection), not through the macro expander.
//
// Provenance of expected values (no Zig executable was run):
//  [fixture X]  test/cases/X (its expanded/ golden or manifest diagnostics).
//  [zig-test]   the `test "destringify"` block in src/aro/Preprocessor.zig.
//  [source]     derived by reading Preprocessor.zig stringify / pasteTokens /
//               makeGeneratedTokenExtra and Tokenizer.zig.
module macro_paste_tests;
import aro::preprocessor, aro::tokens, aro::tokenizer, aro::source, aro::compilation, aro::diagnostics;
import aro::hideset;
import std::io, std::core::mem::allocators, std::collections::list;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

<* Run the body with a compilation (diagnostics to a list) and a preprocessor; checks for leaks. *>
macro @with_pp(; @body(Compilation* comp, Diagnostics* d, Preprocessor* pp))
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
		@body(&comp, &d, &pp);
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

<*
 Lex `src` from byte `from` up to (not including) byte `to` into `out`
 (tokens::from_raw; WHITESPACE and NL -> MACRO_WS; stops at EOF).
*>
fn void lex_range(Comp* comp, Source src, uint from, uint to, ExpandBuf* out)
{
	Tokenizer t;
	t.init(src.buf, src.id, comp.langopts);
	while (true)
	{
		Token raw = t.next();
		if (raw.id == EOF || raw.start >= to) break;
		if (raw.start < from) continue;
		TokenWithExpansionLocs tok = tokens::from_raw(raw);
		if (tok.id == WHITESPACE || tok.id == NL) tok.id = MACRO_WS;
		out.push(tok);
	}
}
alias Comp = Compilation;

<* Lex all of `text` (a fresh source named `path`). *>
fn Source lex_all(Comp* comp, String path, String text, ExpandBuf* out)
{
	Source src = comp.add_source_from_buffer(path, text)!!;
	lex_range(comp, src, 0, (uint)src.buf.len, out);
	return src;
}

<* Stringify `toks` into a cleared char_buf and return its contents. *>
fn String stringify_text(Preprocessor* pp, TokenWithExpansionLocs[] toks)
{
	pp.char_buf.clear();
	pp.stringify(toks)!!;
	return (String)pp.char_buf.array_view();
}

<* The concatenated expanded spellings of `buf` (MACRO_WS -> " "), in the temp allocator. *>
fn String spell(Preprocessor* pp, ExpandBuf* buf)
{
	DString s;
	s.tinit();
	foreach (t : buf.array_view()) s.append(pp.expanded_slice(t));
	return s.str_view();
}

int source_counter;

<* Lex `text` from a new source, stringify it and compare with `expected`. *>
fn void lex_and_stringify(Comp* comp, Preprocessor* pp, String text, String expected)
{
	ExpandBuf buf;
	buf.init(comp.gpa);
	lex_all(comp, string::tformat("s%d.c", source_counter++), text, &buf);
	test::eq(stringify_text(pp, buf.array_view()), expected);
	preprocessor::free_expand_buf(comp.gpa, &buf);
}

// ---------------------------------------------------------------------------
// stringify

fn void stringify_spacing_and_escapes() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [fixture standard-concatenation-strings-example.c] str(strncmp("abc\0d", "abc", '\4') // this goes away
		//    == 0): the comment+newline+indent reach stringify as one MACRO_WS.
		lex_and_stringify(comp, pp, "strncmp(\"abc\\0d\", \"abc\", '\\4')\n   == 0",
			"\"strncmp(\\\"abc\\\\0d\\\", \\\"abc\\\", '\\\\4') == 0\"\n");
		// [fixture same] str(: @\n): backslash outside a literal is not escaped.
		lex_and_stringify(comp, pp, ": @\\n", "\": @\\n\"\n");
		// [fixture same] str(INCFILE(2) . h) with INCFILE(2) unexpanded.
		lex_and_stringify(comp, pp, "INCFILE(2) . h", "\"INCFILE(2) . h\"\n");
		// [source] leading/trailing MACRO_WS dropped, runs collapse to one space.
		lex_and_stringify(comp, pp, "  a \t  b  ", "\"a b\"\n");
		// [source] empty argument (fixture stringify backslashes.c: str()).
		check(stringify_text(pp, {}).len, 3);
		test::eq(stringify_text(pp, {}), "\"\"\n");
		// [source] '"' always escaped; '\' escaped inside string and char literals of every prefix but u8 chars.
		lex_and_stringify(comp, pp, "L\"q\\\"\" u'\\n' U'\\t' L'\\0' u8\"\\a\"", "\"L\\\"q\\\\\\\"\\\" u'\\\\n' U'\\\\t' L'\\\\0' u8\\\"\\\\a\\\"\"\n");
		lex_and_stringify(comp, pp, "u8'\\n'", "\"u8'\\n'\"\n");
		lex_and_stringify(comp, pp, "'\"'", "\"'\\\"'\"\n");
		check(d.messages.len(), 0);
	};
}

fn void stringify_generated_token() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [fixture standard-concatenation-strings-example.c] xstr(INCFILE(2).h) -> "vers2.h":
		// the pasted `vers2` lives in generated_buf.
		ExpandBuf lhs;
		lhs.init(comp.gpa);
		lex_all(comp, "p.c", "vers 2", &lhs);
		check(lhs.len(), 3);
		check(lhs[2].id.ordinal, TokenId.PP_NUM.ordinal);
		TokenWithExpansionLocs rhs = lhs[2];
		lhs.size = 1; // MACRO_WS and PP_NUM have no arrays
		pp.paste_tokens(&lhs, { rhs })!!;
		check(lhs.len(), 1);
		lex_all(comp, "p2.c", ".h", &lhs);
		check(lhs.len(), 3);
		test::eq(stringify_text(pp, lhs.array_view()), "\"vers2.h\"\n");
		preprocessor::free_expand_buf(comp.gpa, &lhs);
	};
}

fn void stringify_trailing_backslash() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [fixture stringify invalid escape.c] x[str(\) -> x[""
		// warning at 2:7: invalid string literal, ignoring final '\'
		String text = "#define str(s) # s\nx[str(\\)\n";
		Source src = comp.add_source_from_buffer("stringify invalid escape.c", text)!!;
		ExpandBuf arg;
		arg.init(comp.gpa);
		lex_range(comp, src, 25, 26, &arg);
		check(arg.len(), 1);
		test::eq(stringify_text(pp, arg.array_view()), "\"\"\n");
		check(d.messages.len(), 1);
		test::eq(d.messages[0].text, "invalid string literal, ignoring final '\\'");
		check(d.messages[0].effective_kind.ordinal, MessageKind.WARNING.ordinal);
		check(d.messages[0].location.line_no, 2);
		check(d.messages[0].location.col, 7);
		preprocessor::free_expand_buf(comp.gpa, &arg);

		// [source] (fixture stringify backslashes.c inputs) `\\` -> "\\" re-tokenizes as a
		// terminated string: no warning, and Zig keeps the tokenizing NUL before '\n'.
		lex_and_stringify(comp, pp, "\\\\", "\"\\\\\"\0\n");
		// `\\\` -> "\\\" is unterminated: warn, drop the final '\'.
		lex_and_stringify(comp, pp, "\\\\\\", "\"\\\\\"\n");
		// `\\\\` -> "\\\\" terminated.
		lex_and_stringify(comp, pp, "\\\\\\\\", "\"\\\\\\\\\"\0\n");
		check(d.messages.len(), 2);
	};
}

// ---------------------------------------------------------------------------
// destringify

fn void destringify_vectors() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		String[2][*] vectors = {
			{ "hello\tworld\n", "hello\tworld\n" },   // [zig-test]
			{ " \\\"FOO BAR BAZ\\\"", " \"FOO BAR BAZ\"" }, // [zig-test]
			{ " \\\\t\\\\n\n", " \\t\\n\n" },          // [zig-test]
			{ "a\\b", "a\\b" },                         // [source] lone '\' kept
			{ "a\\", "a" },                             // [source] trailing lone '\' dropped
		};
		foreach (v : vectors)
		{
			pp.char_buf.clear();
			pp.destringify(v[0]);
			test::eq((String)pp.char_buf.array_view(), v[1]);
		}
	};
}

// ---------------------------------------------------------------------------
// make_generated_token

fn void generated_token_offsets_and_locations() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [source] makeGeneratedTokenExtra.
		Source src = comp.add_source_from_buffer("g.c", "abc def\n")!!;
		TokenWithExpansionLocs a = { .id = IDENTIFIER, .loc = { .id = src.id, .byte_offset = 0, .line = 1 } };
		a.add_expansion_location(comp.gpa, { { .id = src.id, .byte_offset = 4, .line = 1 } });
		HidesetIndex hs = pp.hideset.prepend(a.loc, 3, hideset::NONE);
		pp.hideset.put(a.loc, hs);

		comp.generated_buf.push_all("xyz\n");
		TokenWithExpansionLocs g = pp.make_generated_token(0, STRING_LITERAL, a);
		check(g.id.ordinal, TokenId.STRING_LITERAL.ordinal);
		assert(g.loc.id.is_generated());
		check(g.loc.byte_offset, 0);
		check(g.loc.line, 1);
		check(pp.generated_line, 2);
		assert(!g.flags.is_macro_arg);
		Location[] chain = g.expansion_slice();
		check(chain.len, 2);
		check(chain[0].byte_offset, 0);
		check(chain[1].byte_offset, 4);
		check(pp.hideset.get(g.loc), hs);

		// Generated source location is not recorded; hs and is_macro_arg are taken as given.
		TokenWithExpansionLocs g2 = pp.make_generated_token_extra(4, PP_NUM, g, hideset::NONE, true);
		check(g2.loc.byte_offset, 4);
		check(g2.loc.line, 2);
		assert(g2.flags.is_macro_arg);
		check(g2.expansion_slice().len, 2);
		check(g2.expansion_slice()[0].byte_offset, 0);
		check(g2.expansion_slice()[0].id.index, src.id.index);
		check(pp.hideset.get(g2.loc), hideset::NONE);

		tokens::free_expansion_locs(comp.gpa, a.expansion_locs);
		tokens::free_expansion_locs(comp.gpa, g.expansion_locs);
		tokens::free_expansion_locs(comp.gpa, g2.expansion_locs);
	};
}

// ---------------------------------------------------------------------------
// paste_tokens

fn void paste_object_macro() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [fixture object macro token pasting.c] #define x a##1 -> a1
		ExpandBuf toks;
		toks.init(comp.gpa);
		Source src = lex_all(comp, "o.c", "a 1", &toks);
		TokenWithExpansionLocs rhs = toks[2];
		toks.size = 1;
		comp.generated_buf.push_all("q\n");
		pp.paste_tokens(&toks, { rhs })!!;
		check(toks.len(), 1);
		check(toks[0].id.ordinal, TokenId.IDENTIFIER.ordinal);
		assert(toks[0].loc.id.is_generated());
		check(toks[0].loc.byte_offset, 2);
		check(toks[0].loc.line, 1);
		check(pp.generated_line, 2);
		// [source] the pasted spelling plus '\n' is appended; the NUL stays past the length.
		test::eq((String)comp.generated_buf.array_view(), "q\na1\n");
		check(comp.generated_buf.entries[comp.generated_buf.len()], 0);
		test::eq(pp.expanded_slice(toks[0]), "a1");
		// The expansion chain starts at lhs.
		check(toks[0].expansion_slice().len, 1);
		check(toks[0].expansion_slice()[0].byte_offset, 0);
		check(d.messages.len(), 0);

		// Pasting onto a generated lhs re-reads generated_buf: a1 ## 1 -> a11.
		pp.paste_tokens(&toks, { rhs })!!;
		check(toks.len(), 1);
		test::eq(pp.expanded_slice(toks[0]), "a11");
		check(toks[0].loc.byte_offset, 5);
		check(toks[0].loc.line, 2);
		// lhs was generated: only its chain (the original `a`) is kept.
		check(toks[0].expansion_slice().len, 1);
		preprocessor::free_expand_buf(comp.gpa, &toks);
	};
}

fn void paste_whitespace_and_rest() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [fixture macro token pasting order.c] CAT(a b, c) -> a bc
		ExpandBuf lhs;
		lhs.init(comp.gpa);
		ExpandBuf rhs;
		rhs.init(comp.gpa);
		lex_all(comp, "w.c", "a b ", &lhs);
		lex_all(comp, "w2.c", " c d e", &rhs);
		check(lhs.len(), 4);
		pp.paste_tokens(&lhs, rhs.array_view())!!;
		// [source] trailing lhs MACRO_WS popped, leading rhs MACRO_WS skipped, rest copied.
		test::eq(spell(pp, &lhs), "a bc d e");
		check(lhs.len(), 7);
		check(lhs[2].id.ordinal, TokenId.IDENTIFIER.ordinal);
		assert(lhs[2].loc.id.is_generated());
		check(lhs[3].id.ordinal, TokenId.MACRO_WS.ordinal);
		preprocessor::free_expand_buf(comp.gpa, &lhs);
		preprocessor::free_expand_buf(comp.gpa, &rhs);

		// [fixture paste operator whitespace.c] F(A) with (X##Y) -> (AY)
		lhs.init(comp.gpa);
		rhs.init(comp.gpa);
		lex_all(comp, "f.c", "(A", &lhs);
		lex_all(comp, "f2.c", "Y)", &rhs);
		pp.paste_tokens(&lhs, rhs.array_view()[:1])!!;
		buf_push_dupes(comp, &lhs, rhs.array_view()[1..]);
		test::eq(spell(pp, &lhs), "(AY)");
		preprocessor::free_expand_buf(comp.gpa, &lhs);
		preprocessor::free_expand_buf(comp.gpa, &rhs);
		check(d.messages.len(), 0);
	};
}

fn void buf_push_dupes(Comp* comp, ExpandBuf* buf, TokenWithExpansionLocs[] toks)
{
	foreach (t : toks) buf.push(t.dupe(comp.gpa));
}

fn void paste_empty_sides() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		ExpandBuf lhs;
		lhs.init(comp.gpa);
		ExpandBuf rhs;
		rhs.init(comp.gpa);
		// [source] whitespace-only lhs: popped, then rhs copied verbatim (incl. whitespace).
		lex_all(comp, "e.c", "  ", &lhs);
		lex_all(comp, "e2.c", " x", &rhs);
		pp.paste_tokens(&lhs, rhs.array_view())!!;
		check(lhs.len(), 2);
		check(lhs[0].id.ordinal, TokenId.MACRO_WS.ordinal);
		test::eq(spell(pp, &lhs), " x");
		check(comp.generated_buf.len(), 0);
		preprocessor::free_expand_buf(comp.gpa, &lhs);
		preprocessor::free_expand_buf(comp.gpa, &rhs);

		// [source] whitespace-only rhs: lhs pushed back unchanged, nothing generated.
		lhs.init(comp.gpa);
		rhs.init(comp.gpa);
		lex_all(comp, "e3.c", "y ", &lhs);
		lex_all(comp, "e4.c", "   ", &rhs);
		pp.paste_tokens(&lhs, rhs.array_view())!!;
		check(lhs.len(), 1);
		assert(!lhs[0].loc.id.is_generated());
		check(comp.generated_buf.len(), 0);
		preprocessor::free_expand_buf(comp.gpa, &lhs);
		preprocessor::free_expand_buf(comp.gpa, &rhs);
	};
}

fn void paste_placemarkers() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [fixture placeholder tokens pasting.c] CAT(,) -> nothing; CAT(,y) -> y; CAT2(x,) -> (x)
		ExpandBuf lhs;
		lhs.init(comp.gpa);
		lhs.push(preprocessor::get_paste_args({})[0]);
		pp.paste_tokens(&lhs, preprocessor::get_paste_args({}))!!;
		check(lhs.len(), 1);
		check(lhs[0].id.ordinal, TokenId.PLACEMARKER.ordinal);
		assert(lhs[0].loc.id.is_generated());
		// [source] the pasted text is just "\n" (first token NL; the id is forced to PLACEMARKER).
		test::eq((String)comp.generated_buf.array_view(), "\n");
		assert(lhs[0].expansion_locs == null);
		preprocessor::free_expand_buf(comp.gpa, &lhs);

		ExpandBuf rhs;
		rhs.init(comp.gpa);
		lex_all(comp, "y.c", "y", &rhs);
		lhs.init(comp.gpa);
		lhs.push(preprocessor::get_paste_args({})[0]);
		pp.paste_tokens(&lhs, rhs.array_view())!!;
		check(lhs.len(), 1);
		check(lhs[0].id.ordinal, TokenId.IDENTIFIER.ordinal);
		test::eq(pp.expanded_slice(lhs[0]), "y");
		preprocessor::free_expand_buf(comp.gpa, &lhs);

		lhs.init(comp.gpa);
		lhs.push(rhs[0].dupe(comp.gpa));
		pp.paste_tokens(&lhs, preprocessor::get_paste_args({}))!!;
		check(lhs.len(), 1);
		check(lhs[0].id.ordinal, TokenId.IDENTIFIER.ordinal);
		test::eq(pp.expanded_slice(lhs[0]), "y");
		preprocessor::free_expand_buf(comp.gpa, &lhs);
		preprocessor::free_expand_buf(comp.gpa, &rhs);
		check(d.messages.len(), 0);
	};
}

fn void paste_invalid() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [source] + ## - -> "+-" re-tokenizes as PLUS MINUS: error, both tokens kept.
		ExpandBuf lhs;
		lhs.init(comp.gpa);
		Source src = lex_all(comp, "i.c", "+ -", &lhs);
		TokenWithExpansionLocs rhs = lhs[2];
		lhs.size = 1;
		pp.paste_tokens(&lhs, { rhs })!!;
		check(d.messages.len(), 1);
		test::eq(d.messages[0].text, "pasting formed '+-', an invalid preprocessing token");
		check(d.messages[0].effective_kind.ordinal, MessageKind.ERROR.ordinal);
		check(d.messages[0].location.line_no, 1);
		check(d.messages[0].location.col, 1);
		check(lhs.len(), 2);
		check(lhs[0].id.ordinal, TokenId.PLUS.ordinal);
		assert(lhs[0].loc.id.is_generated());
		check(lhs[0].loc.byte_offset, 0);
		check(lhs[1].id.ordinal, TokenId.MINUS.ordinal);
		// tokFromRaw(next): generated, offset start + 1, the tmp tokenizer's line (1), no chain.
		assert(lhs[1].loc.id.is_generated());
		check(lhs[1].loc.byte_offset, 1);
		check(lhs[1].loc.line, 1);
		assert(lhs[1].expansion_locs == null);
		test::eq(spell(pp, &lhs), "+-");
		preprocessor::free_expand_buf(comp.gpa, &lhs);

		// [source] a valid paste of punctuators: - ## = -> "-=" (MINUS_EQUAL), no error.
		lhs.init(comp.gpa);
		lex_all(comp, "i2.c", "- =", &lhs);
		rhs = lhs[2];
		lhs.size = 1;
		pp.paste_tokens(&lhs, { rhs })!!;
		check(lhs.len(), 1);
		check(lhs[0].id.ordinal, TokenId.MINUS_EQUAL.ordinal);
		check(d.messages.len(), 1);
		preprocessor::free_expand_buf(comp.gpa, &lhs);
	};
}

fn void paste_preserved_comments() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		comp.langopts.preserve_comments = true;
		comp.langopts.preserve_comments_in_macros = true;
		// [fixture preserve comments in macros.c, -CC] #define a() 1 /*foo*/ ## /*bar*/ 2
		// error at 1:15: pasting formed '/*foo*//*bar*/', an invalid preprocessing token
		String text = "#define a() 1 /*foo*/ ## /*bar*/ 2\n";
		Source src = comp.add_source_from_buffer("preserve comments in macros.c", text)!!;
		ExpandBuf lhs;
		lhs.init(comp.gpa);
		ExpandBuf rhs;
		rhs.init(comp.gpa);
		lex_range(comp, src, 12, 21, &lhs); // "1 /*foo*/"
		lex_range(comp, src, 25, 34, &rhs); // "/*bar*/ 2"
		check(lhs.len(), 3);
		check(rhs[0].id.ordinal, TokenId.COMMENT.ordinal);
		pp.paste_tokens(&lhs, rhs.array_view())!!;
		check(d.messages.len(), 1);
		test::eq(d.messages[0].text, "pasting formed '/*foo*//*bar*/', an invalid preprocessing token");
		check(d.messages[0].location.line_no, 1);
		check(d.messages[0].location.col, 15);
		// [1, ws, /*foo*/ (generated), /*bar*/ (from_raw), ws, 2]
		check(lhs.len(), 6);
		check(lhs[2].id.ordinal, TokenId.COMMENT.ordinal);
		test::eq(pp.expanded_slice(lhs[2]), "/*foo*/");
		test::eq(pp.expanded_slice(lhs[3]), "/*bar*/");
		test::eq(spell(pp, &lhs), "1 /*foo*//*bar*/ 2");
		preprocessor::free_expand_buf(comp.gpa, &lhs);
		preprocessor::free_expand_buf(comp.gpa, &rhs);

		// [fixture preserve comments paste whitespace.c, -CC]
		// paste(hello/*trailing*/, world) -> hello world; suffix(hello/*trailing*/) -> hello 1
		lhs.init(comp.gpa);
		rhs.init(comp.gpa);
		Source s2 = lex_all(comp, "c.c", "hello/*trailing*/", &lhs);
		check(lhs.len(), 2);
		lhs[1].flags.is_macro_arg = true;
		lhs[1].add_expansion_location(comp.gpa, { { .id = s2.id, .byte_offset = 0, .line = 1 } });
		lex_all(comp, "c2.c", "world", &rhs);
		pp.paste_tokens(&lhs, rhs.array_view())!!;
		check(lhs.len(), 3);
		check(lhs[1].id.ordinal, TokenId.MACRO_WS.ordinal);
		test::eq(spell(pp, &lhs), "hello world");
		check(comp.generated_buf.len(), "/*foo*//*bar*/\n".len);
		preprocessor::free_expand_buf(comp.gpa, &lhs);
		preprocessor::free_expand_buf(comp.gpa, &rhs);

		// [source] no MACRO_WS is inserted when rhs starts with whitespace.
		lhs.init(comp.gpa);
		rhs.init(comp.gpa);
		lex_all(comp, "c3.c", "hello/*trailing*/", &lhs);
		lhs[1].flags.is_macro_arg = true;
		lex_all(comp, "c4.c", " 1", &rhs);
		pp.paste_tokens(&lhs, rhs.array_view())!!;
		test::eq(spell(pp, &lhs), "hello 1");
		check(lhs.len(), 3);
		preprocessor::free_expand_buf(comp.gpa, &lhs);
		preprocessor::free_expand_buf(comp.gpa, &rhs);
		check(d.messages.len(), 1);
	};
}

fn void paste_comments_dropped_without_cc() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [source] without -CC, comments around ## are skipped like whitespace.
		ExpandBuf lhs;
		lhs.init(comp.gpa);
		ExpandBuf rhs;
		rhs.init(comp.gpa);
		lex_all(comp, "n.c", "x /*a*/ ", &lhs);
		lex_all(comp, "n2.c", "/*b*/ y", &rhs);
		pp.paste_tokens(&lhs, rhs.array_view())!!;
		check(lhs.len(), 1);
		test::eq(pp.expanded_slice(lhs[0]), "xy");
		preprocessor::free_expand_buf(comp.gpa, &lhs);
		preprocessor::free_expand_buf(comp.gpa, &rhs);
		check(d.messages.len(), 0);
	};
}

fn void paste_hideset_and_flags() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [source] hideset(result) = intersection(hideset(lhs), hideset(rhs));
		// is_macro_arg = lhs or rhs.
		Source src = comp.add_source_from_buffer("h.c", "A B x y\n")!!;
		Location la = { .id = src.id, .byte_offset = 0, .line = 1 };
		Location lb = { .id = src.id, .byte_offset = 2, .line = 1 };
		HidesetIndex just_b = pp.hideset.prepend(lb, 1, hideset::NONE);
		HidesetIndex a_b = pp.hideset.prepend(la, 1, just_b);
		TokenWithExpansionLocs x = { .id = IDENTIFIER, .loc = { .id = src.id, .byte_offset = 4, .line = 1 } };
		TokenWithExpansionLocs y = { .id = IDENTIFIER, .loc = { .id = src.id, .byte_offset = 6, .line = 1 } };
		y.flags.is_macro_arg = true;
		pp.hideset.put(x.loc, a_b);
		pp.hideset.put(y.loc, just_b);
		ExpandBuf lhs;
		lhs.init(comp.gpa);
		lhs.push(x);
		pp.paste_tokens(&lhs, { y })!!;
		check(lhs.len(), 1);
		test::eq(pp.expanded_slice(lhs[0]), "xy");
		assert(lhs[0].flags.is_macro_arg);
		HidesetIndex hs = pp.hideset.get(lhs[0].loc);
		check(pp.hideset.len(hs), 1);
		assert(pp.hideset.contains(hs, "B"));
		assert(!pp.hideset.contains(hs, "A"));
		preprocessor::free_expand_buf(comp.gpa, &lhs);
	};
}

fn void paste_error_promoted_to_fatal() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [source] pp.err goes through Diagnostics.addWithLocation, which only stops on a
		// declared fatal kind: with -Wfatal-errors the invalid-paste error is reported as
		// fatal but paste_tokens still completes (Zig behavior). Ownership is unchanged.
		d.state.fatal_errors = true;
		ExpandBuf lhs;
		lhs.init(comp.gpa);
		Source src = lex_all(comp, "f.c", "+ -", &lhs);
		lhs[0].add_expansion_location(comp.gpa, { { .id = src.id, .byte_offset = 2, .line = 1 } });
		TokenWithExpansionLocs rhs = lhs[2];
		lhs.size = 1;
		pp.paste_tokens(&lhs, { rhs })!!;
		check(lhs.len(), 2);
		check(d.messages.len(), 2);
		check(d.messages[0].effective_kind.ordinal, MessageKind.FATAL_ERROR.ordinal);
		// Reported at the outermost expansion location (col 3), then the note.
		check(d.messages[0].location.col, 3);
		test::eq(d.messages[1].text, "expanded from here");
		// The generated token's chain is lhs.loc then lhs's chain.
		check(lhs[0].expansion_slice().len, 2);
		check(lhs[0].expansion_slice()[1].byte_offset, 2);
		preprocessor::free_expand_buf(comp.gpa, &lhs);
	};
}
