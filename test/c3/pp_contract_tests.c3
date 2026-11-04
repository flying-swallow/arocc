// Tests for the plan 13 stage-0 contract code that is implemented (not
// stubbed): aro::tokens (expansion-location chains, precedence), the
// MacroTable, Preprocessor init/free/builtin registration, error reporting,
// the output token list and the ExpandBuf ownership helpers, the provider
// defaults and a spot check of the Preprocessor/Diagnostic.zig records.
// Expected values are source-derived from Tree.zig, Preprocessor.zig and
// Preprocessor/Diagnostic.zig; no Zig executable was run.
module pp_contract_tests;
import aro::preprocessor, aro::tokens, aro::tokenizer, aro::source, aro::compilation, aro::diagnostics;
import aro::hideset;
import std::io, std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

fn Location loc_at(uint index, uint offset) => { .id = { .index = index }, .byte_offset = offset, .line = 1 };

<* Run the body with a compilation whose diagnostics go to a list; checks for leaks. *>
macro @with_comp(; @body(Compilation* comp, Diagnostics* d))
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		@body(&comp, &d);
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void expansion_chain_layout() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	TokenWithExpansionLocs tok = { .id = IDENTIFIER, .loc = loc_at(0, 3) };
	check(tok.expansion_slice().len, 0);

	tok.add_expansion_location(&ta, { loc_at(0, 10) });
	Location[] s = tok.expansion_slice();
	check(s.len, 1);
	check(s[0].byte_offset, 10);
	// Capacity max(1 + 1 + 1, 4) = 4: [item, term, term, term with byte_offset 1].
	Location* raw = tok.expansion_locs;
	check(raw[1].id.index, source::UNUSED_INDEX);
	check(raw[1].byte_offset, 0);
	check(raw[3].id.index, source::UNUSED_INDEX);
	check(raw[3].byte_offset, 1);

	// Generated locations are never recorded.
	Location gen = { .id = source::GENERATED_ID, .byte_offset = 5 };
	tok.add_expansion_location(&ta, { gen, loc_at(1, 20), loc_at(2, 30) });
	s = tok.expansion_slice();
	check(s.len, 3);
	check(s[1].id.index, 1);
	check(s[2].byte_offset, 30);
	// 3 items + terminator fit in 4: no growth, marker still last.
	check(tok.expansion_locs[3].byte_offset, 1);

	tok.add_expansion_location(&ta, { loc_at(3, 40) });
	check(tok.expansion_slice().len, 4);
	// Grown to ceilPowerOfTwo(4 + 1 + 1) = 8.
	check(tok.expansion_locs[7].byte_offset, 1);
	check(tok.expansion_locs[4].id.index, source::UNUSED_INDEX);

	// dupe is independent.
	TokenWithExpansionLocs copy = tok.dupe(&ta);
	assert(copy.expansion_locs != tok.expansion_locs);
	check(copy.expansion_slice().len, 4);
	check(copy.expansion_slice()[3].byte_offset, 40);
	tokens::free_expansion_locs(&ta, copy.expansion_locs);

	// Bounded at 64.
	Location[100] many;
	foreach (i, &l : many) *l = loc_at(5, (uint)i + 100);
	tok.add_expansion_location(&ta, many[..]);
	check(tok.expansion_slice().len, tokens::MAX_EXPANSION_LOCS);
	check(tok.expansion_slice()[63].byte_offset, 100 + 59);
	tok.add_expansion_location(&ta, { loc_at(6, 1) });
	check(tok.expansion_slice().len, 64);
	tokens::free_expansion_locs(&ta, tok.expansion_locs);

	// Whitespace-like tokens never get locations.
	TokenWithExpansionLocs ws = { .id = MACRO_WS, .loc = loc_at(0, 0) };
	ws.add_expansion_location(&ta, { loc_at(0, 1) });
	assert(ws.expansion_locs == null);
	check(ta.allocation_count(), 0);
}

fn void precedence_table() @test
{
	check(tokens::precedence(COMMA), tokens::PREC_COMMA);
	check(tokens::precedence(PIPE_EQUAL), tokens::PREC_ASSIGN);
	check(tokens::precedence(QUESTION_MARK), tokens::PREC_CONDITIONAL);
	check(tokens::precedence(ANGLE_BRACKET_ANGLE_BRACKET_LEFT), tokens::PREC_SHIFT);
	check(tokens::precedence(PERCENT), tokens::PREC_MULTIPLICATIVE);
	check(tokens::precedence(IDENTIFIER), tokens::PREC_INVALID);
	check(tokens::PREC_ASSIGN.next(tokens::PREC_ANY), tokens::PREC_ASSIGN);
	check(tokens::PREC_CONDITIONAL.next(tokens::PREC_COMMA), tokens::PREC_COMMA);
	check(tokens::PREC_MULTIPLICATIVE.next(tokens::PREC_ANY), 15);
	assert(tokens::PREC_INVALID.lt(tokens::PREC_ANY));
	assert(!tokens::PREC_SHIFT.lt(tokens::PREC_SHIFT));
}

fn void raw_conversion() @test
{
	Token raw = { .id = PLUS, .source = { .index = 2 }, .start = 7, .end = 8, .line = 3 };
	TokenWithExpansionLocs t = tokens::from_raw(raw);
	check(t.id.ordinal, TokenId.PLUS.ordinal);
	check(t.loc.byte_offset, 7);
	check(t.loc.line, 3);
	check(t.loc.id.index, 2);
	assert(t.expansion_locs == null);
	assert(!t.flags.is_macro_arg);
}

fn void macro_table() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	MacroTable t;
	t.init(&ta);
	bool found;
	for (uint i = 0; i < 40; i++)
	{
		char[8] buf;
		String name = (String)io::bprintf(&buf, "M%d", i)!!;
		Macro* m = t.get_or_put(name, &found);
		assert(!found);
		m.loc.byte_offset = i;
	}
	check(t.len(), 40);
	Macro* m5 = t.get("M5");
	assert(m5 != null);
	check(m5.loc.byte_offset, 5);
	assert(t.get("nope") == null);
	t.get_or_put("M7", &found);
	assert(found);
	assert(t.ordered_remove("M3"));
	assert(!t.ordered_remove("M3"));
	assert(!t.contains("M3"));
	check(t.len(), 39);
	test::eq(t.key(3), "M4");
	check(t.macros()[3].loc.byte_offset, 4);
	check(t.get("M39").loc.byte_offset, 39);
	// Re-adding goes to the end (Zig orderedRemove + getOrPut).
	t.get_or_put("M3", &found);
	assert(!found);
	test::eq(t.key(39), "M3");
	t.free();
	check(ta.allocation_count(), 0);
}

fn void init_free_and_builtins() @test
{
	@with_comp(; Compilation* comp, Diagnostics* d)
	{
		Preprocessor pp;
		pp.init(comp, preprocessor::TESTING)!!;
		check(pp.defines.len(), 0);
		check(pp.generated_line, 1);
		pp.free();

		InitOptions opts = preprocessor::TESTING;
		opts.add_builtin_macros = true;
		pp.init(comp, opts)!!;
		// 12 always + 6 target queries (emulate NO) + 6 object macros + 3 clang objects.
		check(pp.defines.len(), 27);
		Macro* file = pp.defines.get("__FILE__");
		assert(file != null && file.is_builtin() && !file.is_func);
		check(file.tokens.len, 1);
		check(file.tokens[0].id.ordinal, TokenId.MACRO_BUILTIN_OBJ.ordinal);
		Macro* inc = pp.defines.get("__has_include");
		assert(inc.is_func && inc.params.len == 1 && inc.should_expand_args());
		assert(!pp.defines.get("__has_feature").should_expand_args());
		assert(pp.defines.get("__identifier") == null);
		pp.clear_buffers();
		pp.free();

		comp.langopts.ms_extensions = true;
		comp.langopts.emulate = GCC;
		pp.init(comp, opts)!!;
		check(pp.defines.len(), 12 + 2 + 6);
		pp.free();

		// No source epoch: asks the builtin provider, which is unsupported until plan 14.
		opts.has_source_epoch = false;
		fault f = @catch(pp.init(comp, opts));
		assert(f == aro::UNSUPPORTED);
	};
}

fn void providers_are_unsupported() @test
{
	@with_comp(; Compilation* comp, Diagnostics* d)
	{
		Preprocessor pp;
		pp.init(comp, preprocessor::TESTING)!!;
		assert(@catch(pp.m_time(source::GENERATED_ID)) == aro::UNSUPPORTED);
		FileProvider fp = pp.files;
		assert(@catch(fp.find_include(fp.ctx, &pp, "a.h", {}, QUOTES, FIRST)) == aro::UNSUPPORTED);
		assert(@catch(fp.has_include(fp.ctx, &pp, "a.h", source::UNUSED_ID, QUOTES, FIRST)) == aro::UNSUPPORTED);
		assert(@catch(fp.find_embed(fp.ctx, &pp, "a.h", source::UNUSED_ID, QUOTES, preprocessor::EMBED_UNLIMITED)) == aro::UNSUPPORTED);
		BuiltinProvider bp = pp.builtins;
		ExpandBuf buf;
		buf.init(comp.gpa);
		assert(@catch(bp.expand_obj(bp.ctx, &pp, LINE, {}, &buf)) == aro::UNSUPPORTED);
		assert(@catch(bp.expand_func(bp.ctx, &pp, HAS_FEATURE, {}, {}, null, EXPR, &buf)) == aro::UNSUPPORTED);
		buf.free();
		assert(@catch(pp.include(null, FIRST)) == aro::UNSUPPORTED);
		assert(@catch(pp.embed(null)) == aro::UNSUPPORTED);
		pp.free();
	};
}

fn void err_formats_and_locates() @test
{
	@with_comp(; Compilation* comp, Diagnostics* d)
	{
		Source src = comp.add_source_from_buffer("t.c", "#define FOO 1\nFOO\n")!!;
		Preprocessor pp;
		pp.init(comp, preprocessor::TESTING)!!;
		TokenWithExpansionLocs name = { .id = IDENTIFIER, .loc = { .id = src.id, .byte_offset = 8, .line = 1 } };
		pp.err(name, preprocessor::DIAG_MACRO_REDEFINED, { diagnostics::arg_str("FOO") })!!;
		pp.err_loc(name.loc, preprocessor::DIAG_EXPECTED_ARGUMENTS, { diagnostics::arg_uint(2), diagnostics::arg_uint(0) })!!;
		// OFF by default: not reported.
		pp.err(name, preprocessor::DIAG_KEYWORD_MACRO)!!;
		check(d.messages.len(), 2);
		test::eq(d.messages[0].text, "'FOO' macro redefined");
		check(d.messages[0].effective_kind.ordinal, MessageKind.WARNING.ordinal);
		check(d.messages[0].location.col, 9);
		test::eq(d.messages[1].text, "expected 2 argument(s) got 0");

		// Through an expansion location: reported at the outermost one plus a note.
		TokenWithExpansionLocs use = { .id = IDENTIFIER, .loc = name.loc };
		use.add_expansion_location(comp.gpa, { { .id = src.id, .byte_offset = 14, .line = 2 } });
		pp.err(use, preprocessor::DIAG_POISONED_IDENTIFIER)!!;
		check(d.messages.len(), 4);
		check(d.messages[2].location.line_no, 2);
		test::eq(d.messages[3].text, "expanded from here");
		tokens::free_expansion_locs(comp.gpa, use.expansion_locs);

		Token raw = { .id = HASH, .source = src.id, .start = 0, .end = 1, .line = 1 };
		assert(@catch(pp.fatal(raw, "too many #if nestings")) == compilation::FATAL_ERROR);
		test::eq(d.messages[^1].text, "too many #if nestings");
		pp.free();
	};
}

fn void output_tokens_own_expansions() @test
{
	@with_comp(; Compilation* comp, Diagnostics* d)
	{
		Source src = comp.add_source_from_buffer("t.c", "a + bc\n")!!;
		Preprocessor pp;
		pp.init(comp, preprocessor::TESTING)!!;

		Token raw = { .id = IDENTIFIER, .source = src.id, .start = 4, .end = 6, .line = 1 };
		test::eq(pp.tok_slice(raw), "bc");
		TokenWithExpansionLocs bc = tokens::from_raw(raw);
		test::eq(pp.expanded_slice(bc), "bc");
		Token plus = { .id = PLUS, .source = src.id, .start = 2, .end = 3, .line = 1 };
		test::eq(pp.tok_slice(plus), "+");

		pp.add_token({ .id = IDENTIFIER, .loc = { .id = src.id, .byte_offset = 0, .line = 1 } })!!;
		bc.add_expansion_location(comp.gpa, { { .id = src.id, .byte_offset = 0, .line = 1 } });
		pp.add_token(bc)!!; // moves the array
		TokenCount count = pp.get_token_count();
		TokenWithExpansionLocs extra = { .id = PLUS, .loc = tokens::raw_location(plus) };
		extra.add_expansion_location(comp.gpa, { { .id = src.id, .byte_offset = 2, .line = 1 } });
		pp.add_token(extra)!!;
		check(pp.tokens.len(), 3);
		check(pp.expansion_entries.len(), 2);
		check(pp.expansion_slice(0).len, 0);
		check(pp.expansion_slice(1).len, 1);
		check(pp.expansion_slice(2)[0].byte_offset, 2);
		pp.set_token_count(count); // frees the dropped array
		check(pp.tokens.len(), 2);
		check(pp.expansion_slice(2).len, 0);
		pp.free(); // frees the rest
	};
}

fn void expand_buf_helpers() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	ExpandBuf buf;
	buf.init(&ta);
	Location l = loc_at(0, 1);
	for (uint i = 0; i < 5; i++)
	{
		TokenWithExpansionLocs t = { .id = i % 2 ? TokenId.PLACEMARKER : TokenId.IDENTIFIER, .loc = loc_at(0, i) };
		// PLACEMARKER never gets locations; identifiers do.
		t.add_expansion_location(&ta, { l });
		buf.push(t);
	}
	preprocessor::remove_placemarkers(&ta, &buf);
	check(buf.len(), 3);
	check(buf[1].loc.byte_offset, 2);

	TokenWithExpansionLocs[2] ws = { { .id = MACRO_WS }, { .id = MACRO_WS } };
	TokenWithExpansionLocs[] pasted = preprocessor::get_paste_args(ws[..]);
	check(pasted.len, 1);
	check(pasted[0].id.ordinal, TokenId.PLACEMARKER.ordinal);
	assert(pasted[0].loc.id.is_generated());
	check(preprocessor::get_paste_args(buf.array_view()).len, 3);

	MacroArguments args;
	args.init(&ta);
	TokenWithExpansionLocs[] arg = alloc::new_array(&ta, TokenWithExpansionLocs, 1);
	arg[0] = buf[0].dupe(&ta);
	args.push(arg);
	args.push({});
	preprocessor::buf_copy_tokens(&ta, &buf, arg, { loc_at(4, 4) });
	check(buf.len(), 4);
	check(buf[3].expansion_slice().len, 2);
	check(buf[3].expansion_slice()[1].id.index, 4);
	preprocessor::deinit_macro_arguments(&ta, &args);
	preprocessor::free_expand_buf(&ta, &buf);
	check(ta.allocation_count(), 0);
}

fn void diagnostic_records() @test
{
	test::eq(preprocessor::DIAG_ELIF_WITHOUT_IF.fmt, "#elif without #if");
	check(preprocessor::DIAG_ELIF_WITHOUT_IF.kind.ordinal, MessageKind.ERROR.ordinal);
	PpDiagnostic w = preprocessor::DIAG_WARNING_DIRECTIVE;
	assert(w.show_in_system_headers && w.has_opt && w.opt == Option.WARNINGS);
	PpDiagnostic ext = preprocessor::DIAG_EXPANSION_TO_DEFINED_FUNC;
	test::eq(ext.fmt, "macro expansion producing 'defined' has undefined behavior");
	assert(ext.extension && ext.opt == Option.EXPANSION_TO_DEFINED);
	assert(!preprocessor::DIAG_EXPANSION_TO_DEFINED_OBJ.extension);
	test::eq(preprocessor::DIAG_INVALID_PP_STRINGIFY_ESCAPE.fmt, "invalid string literal, ignoring final '\\'");
	test::eq(preprocessor::DIAG_COUNTER_OVERFLOW.fmt, "'__COUNTER__' value cannot exceed 2'147'483'647");
	PpDiagnostic dt = preprocessor::DIAG_DATE_TIME;
	assert(dt.show_in_system_headers && dt.kind == OFF);
	test::eq(preprocessor::invalid_token_diagnostic(EMPTY_CHAR_LITERAL).fmt, "empty character constant");
	DiagnosticTemplate plain = preprocessor::DIAG_NEWLINE_EOF;
	assert(plain.has_opt && plain.opt == Option.NEWLINE_EOF && plain.kind == OFF && plain.extension);
}
