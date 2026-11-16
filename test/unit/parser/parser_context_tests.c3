// Focused tests for parser context ownership and token-buffer lifetime.
module parser_context_tests;
import aro::parser, aro::parser_builtin, aro::parser_declaration, aro::parser_postfix, aro::parser_result;
import aro::preprocessor, aro::tokens, aro::tokenizer, aro::tree;
import aro::compilation, aro::diagnostics, aro::source;
import aro::type_store, aro::symbol_stack, aro::string_interner, aro::value;
import aro::attribute, aro::attribute_map;
import std::core::mem::allocators, std::io;

excuse CALLBACK_FAILURE;
excuse SYMBOL_TEST_WRITE_FAILURE;

struct RejectSymbolWriter (OutStream) { char unused; }

alias HookFn = fn void?(void* context, Parser* p);
alias TypedHookFn = fn QualType?(void* context, Parser* p);

<* Test handler built from free fixture functions; unset hooks report HOOK_ABSENT. *>
struct FnHandler (parser::IParserHandler)
{
	void* context;
	HookFn declaration;
	HookFn type_name;
	TypedHookFn typed_type_name;
	HookFn implicit_typedefs;
}

fn void? FnHandler.handle_declaration(&self, Parser* p) @dynamic
{
	if (!self.declaration) return parser::HOOK_ABSENT~;
	return self.declaration(self.context, p);
}

fn void? FnHandler.handle_type_name(&self, Parser* p) @dynamic
{
	if (!self.type_name) return parser::HOOK_ABSENT~;
	return self.type_name(self.context, p);
}

fn QualType? FnHandler.handle_typed_type_name(&self, Parser* p) @dynamic
{
	if (!self.typed_type_name) return parser::HOOK_ABSENT~;
	return self.typed_type_name(self.context, p);
}

fn void? FnHandler.handle_implicit_typedefs(&self, Parser* p) @dynamic
{
	if (!self.implicit_typedefs) return parser::HOOK_ABSENT~;
	return self.implicit_typedefs(self.context, p);
}

fn sz? RejectSymbolWriter.write(&self, char[] bytes) @dynamic => SYMBOL_TEST_WRITE_FAILURE~;
fn void? RejectSymbolWriter.write_byte(&self, char byte) @dynamic => SYMBOL_TEST_WRITE_FAILURE~;
fn void? RejectSymbolWriter.flush(&self) @dynamic => SYMBOL_TEST_WRITE_FAILURE~;

fn QualType? return_int_type(void* context, Parser* p) => type_store::INT;

fn QualType? fail_type_name(void* context, Parser* p)
{
	return CALLBACK_FAILURE~;
}

fn void? fail_legacy_type_name(void* context, Parser* p)
{
	return CALLBACK_FAILURE~;
}

fn void? consume_one_token(void* context, Parser* p)
{
	p.advance();
}

fn void? append_eof_token(void* context, Parser* p)
{
	p.pp.tokens.push({ .id = EOF, .loc = source::UNUSED_LOCATION });
}

struct FunctionContextBodyCheck
{
	bool expected_active;
	bool expected_variadic;
	uint expected_named_params;
	uint calls;
}

fn parser_result::Result? inspect_function_context_body(void* context, Parser* p, bool eval)
{
	FunctionContextBodyCheck* check = (FunctionContextBodyCheck*)context;
	assert(p.function_context.active == check.expected_active);
	assert(p.function_context.variadic == check.expected_variadic);
	assert(p.function_context.named_param_count == check.expected_named_params);
	assert(!p.at_eof() && p.tree.tokens[(usz)p.tok_i].id == tokenizer::TokenId.PP_NUM);
	tokens::TokenIndex tok = p.tok_i;
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
		.literal = { .literal_tok = tok, .qt = type_store::INT } });
	p.advance();
	check.calls++;
	return { .node = node, .qt = type_store::INT };
}

struct VaPackPostfixCheck
{
	type_store::QualType callee_qt;
	parser::VaArgPackCallContext[8] observed;
	uint observed_count;
}

fn parser_result::Result? va_pack_test_primary(void* context, Parser* p, bool eval)
{
	VaPackPostfixCheck* check = (VaPackPostfixCheck*)context;
	if (p.at_eof() || p.tree.tok_slice(p.tok_i) != "callee") return parser_postfix::PARSING_FAILED~;
	tokens::TokenIndex tok = p.tok_i;
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
		.literal = { .literal_tok = tok, .qt = check.callee_qt } });
	p.advance();
	return { .node = node, .qt = check.callee_qt };
}

fn parser_result::Result? va_pack_test_expression(void* context, Parser* p,
	tokens::Precedence min_prec, bool eval)
{
	VaPackPostfixCheck* check = (VaPackPostfixCheck*)context;
	if (p.at_eof()) return parser_postfix::PARSING_FAILED~;
	tokens::TokenIndex tok = p.tok_i;
	tokens::TreeToken token = p.tree.tokens[(usz)tok];
	assert(check.observed_count < check.observed.len);
	check.observed[check.observed_count++] = p.va_arg_pack_call;
	if (token.id == tokenizer::TokenId.IDENTIFIER && p.tree.tok_slice(tok) == "__builtin_va_arg_pack")
	{
		p.advance();
		parser_builtin::BuiltinParser builtin = { .parser = p };
		return builtin.va_arg_pack(tok);
	}
	if (token.id != tokenizer::TokenId.PP_NUM) return parser_postfix::PARSING_FAILED~;
	p.advance();
	if (p.is_at(tokenizer::TokenId.PLUS))
	{
		p.advance();
		return va_pack_test_expression(context, p, min_prec, eval);
	}
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
		.literal = { .literal_tok = tok, .qt = type_store::INT } });
	return { .node = node, .qt = type_store::INT };
}

fn void? check_eof_bounds(void* context, Parser* p)
{
	assert(p.current() == 0);
	assert(p.at_eof());
	p.advance();
	assert(p.current() == 1);
	p.advance();
	assert(p.current() == 1);
}

fn void parser_starts_at_index_zero_and_bounds_empty_and_eof_buffers() @test
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
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;

		Parser empty;
		empty.init(&pp);
		empty.bind_finalized_tokens();
		assert(empty.current() == 0);
		assert(empty.at_eof());
		assert(@catch(empty.peek_index()) == parser::NO_TOKEN);
		assert(@catch(empty.peek()) == parser::NO_TOKEN);
		assert(@catch(empty.peek_text()) == parser::NO_TOKEN);
		empty.advance();
		assert(empty.current() == 0);
		empty.free();

		pp.tokens.push({ .id = EOF, .loc = source::UNUSED_LOCATION });
		Parser p;
		p.init(&pp);
		// The EOF token prevents a declaration callback from running, so
		// exercise the bounded cursor directly against the borrowed slice.
		p.bind_finalized_tokens();
		assert(p.peek_index()!! == 0);
		assert(p.peek()!!.id == EOF);
		check_eof_bounds(null, &p)!!;
		Tree result = p.parse()!!;
		result.free();

		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void parser_eat_and_expect_preserve_cursor_on_mismatch() @test
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
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Source src = comp.add_source_from_buffer("tokens.c", "name")!!;
		pp.add_token({ .id = IDENTIFIER, .loc = parser_loc(src, 0, 1) })!!;
		pp.tokens.push({ .id = EOF, .loc = parser_loc(src, 4, 1) });
		Parser p;
		p.init(&pp);
		p.bind_finalized_tokens();
		test::eq(p.peek_text()!!, "name");
		assert(@catch(p.eat(SEMICOLON)) == parser::NO_TOKEN && p.current() == 0);
		assert(p.eat(IDENTIFIER)!! == 0 && p.current() == 1);
		assert(@catch(p.expect(R_PAREN)) == parser::PARSING_FAILED);
		assert(p.current() == 1);
		assert(d.messages.len() == 1);
		test::eq(d.messages[0].text, "expected ')' before end of file");
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void missing_closing_delimiter_reports_opener_note() @test
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
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Source src = comp.add_source_from_buffer("delim.c", "(name")!!;
		pp.add_token({ .id = L_PAREN, .loc = parser_loc(src, 0, 1) })!!;
		pp.add_token({ .id = IDENTIFIER, .loc = parser_loc(src, 1, 1) })!!;
		pp.tokens.push({ .id = EOF, .loc = parser_loc(src, 5, 1) });
		Parser p;
		p.init(&pp);
		p.bind_finalized_tokens();
		p.advance();
		assert(@catch(p.expect_closing(R_PAREN, 0)) == parser::PARSING_FAILED);
		assert(d.messages.len() == 2);
		test::eq(d.messages[0].text, "expected ')', found 'an identifier'");
		test::eq(d.messages[1].kind, diagnostics::MessageKind.NOTE);
		test::eq(d.messages[1].text, "to match this '('");
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void empty_translation_unit_owns_tree_only() @test
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
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		pp.tokens.push({ .id = EOF, .loc = source::UNUSED_LOCATION });

		Parser p;
		p.init(&pp);
		Tree result = p.parse()!!;
		assert(result.tokens.ptr == pp.tokens.array_view().ptr);
		assert(result.tokens.len == 1);
		assert(result.root_decls.len() == 0);
		result.free();

		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void declaration_callback_controls_cursor() @test
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
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		pp.tokens.push({ .id = IDENTIFIER, .loc = source::UNUSED_LOCATION });

		FnHandler handler = {
			.declaration = &consume_one_token,
			.implicit_typedefs = &append_eof_token,
		};
		Parser p;
		p.init(&pp, &handler);
		Tree result = p.parse()!!;
		assert(p.current() == 1);
		assert(result.tokens.len == 2);
		result.free();

		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void legacy_and_typed_type_name_callbacks_are_distinct() @test
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
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Source src = comp.add_source_from_buffer("type-name-callback.c", "name")!!;
		pp.tokens.push({ .id = IDENTIFIER, .loc = parser_loc(src, 0, 1) });
		FnHandler legacy_callbacks = { .type_name = &consume_one_token };
		Parser p;
		p.init(&pp, &legacy_callbacks);
		p.bind_finalized_tokens();
		p.parse_type_name()!!;
		assert(p.current() == 1);
		p.free();

		legacy_callbacks.type_name = &fail_legacy_type_name;
		Parser failing;
		failing.init(&pp, &legacy_callbacks);
		failing.bind_finalized_tokens();
		assert(@catch(failing.parse_type_name()) == CALLBACK_FAILURE);
		failing.free();

		FnHandler typed_callbacks = { .typed_type_name = &return_int_type };
		Parser typed;
		typed.init(&pp, &typed_callbacks);
		typed.bind_finalized_tokens();
		assert(typed.parse_typed_type_name()!!.eql(type_store::INT, &comp));
		typed.free();

		typed_callbacks.typed_type_name = &fail_type_name;
		Parser typed_failing;
		typed_failing.init(&pp, &typed_callbacks);
		typed_failing.bind_finalized_tokens();
		assert(@catch(typed_failing.parse_typed_type_name()) == CALLBACK_FAILURE);
		typed_failing.free();

		Parser missing;
		missing.init(&pp);
		missing.bind_finalized_tokens();
		assert(@catch(missing.parse_typed_type_name()));
		assert(d.messages.len() == 1);
		test::eq(d.messages[0].text, "parser grammar callback is unavailable");
		missing.free();

		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void parser_can_be_abandoned_before_parse() @test
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
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Parser p;
		p.init(&pp);
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn Location parser_loc(Source src, uint offset, uint line) => {
	.id = src.id,
	.byte_offset = offset,
	.line = line,
};

fn void grammar_diagnostics_follow_macro_expansion_order() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("macro.c", "FIRST SECOND\nmacro body\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;

		// Expansion locations are stored innermost first; the call site is last
		// and therefore owns the primary diagnostic location.
		TokenWithExpansionLocs first = { .id = IDENTIFIER, .loc = parser_loc(src, 0, 1) };
		first.add_expansion_location(comp.gpa, { parser_loc(src, 13, 2), parser_loc(src, 0, 1) });
		pp.add_token(first)!!;
		TokenWithExpansionLocs second = { .id = IDENTIFIER, .loc = parser_loc(src, 6, 1) };
		second.add_expansion_location(comp.gpa, { parser_loc(src, 13, 2), parser_loc(src, 6, 1) });
		pp.add_token(second)!!;
		pp.tokens.push({ .id = EOF, .loc = source::UNUSED_LOCATION });

		Parser p;
		p.init(&pp);
		p.bind_finalized_tokens();
		assert(@catch(p.expect(SEMICOLON)) == parser::PARSING_FAILED);
		p.advance();
		assert(@catch(p.expect(SEMICOLON)) == parser::PARSING_FAILED);
		p.free();

		assert(d.messages.len() == 6);
		test::eq(d.messages[0].kind, diagnostics::MessageKind.ERROR);
		test::eq(d.messages[0].text, "expected ';', found 'an identifier'");
		test::eq(d.messages[0].location.path, "macro.c");
		assert(d.messages[0].location.line_no == 1 && d.messages[0].location.col == 1);
		test::eq(d.messages[1].kind, diagnostics::MessageKind.NOTE);
		test::eq(d.messages[1].text, "expanded from here");
		assert(d.messages[1].location.line_no == 2 && d.messages[1].location.col == 1);
		test::eq(d.messages[2].text, "expanded from here");
		assert(d.messages[2].location.line_no == 1 && d.messages[2].location.col == 1);

		test::eq(d.messages[3].kind, diagnostics::MessageKind.ERROR);
		test::eq(d.messages[3].text, "expected ';', found 'an identifier'");
		assert(d.messages[3].location.line_no == 1 && d.messages[3].location.col == 7);
		test::eq(d.messages[4].text, "expanded from here");
		assert(d.messages[4].location.line_no == 2 && d.messages[4].location.col == 1);
		test::eq(d.messages[5].text, "expanded from here");
		assert(d.messages[5].location.line_no == 1 && d.messages[5].location.col == 7);

		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void? fail_after_allocating_tree_node(void* context, Parser* p)
{
	p.tree.add_node({ .kind = tree::NodeKind.EMPTY_DECL });
	return p.diagnostics.add({ .kind = diagnostics::MessageKind.FATAL_ERROR, .text = "fatal parser diagnostic" });
}

fn void? recover_after_failure(void* context, Parser* p)
{
	p.advance();
}

fn symbol_stack::Symbol parser_test_symbol(string_interner::StringId name, symbol_stack::SymbolKind kind, uint tok, uint node, QualType qt = type_store::INT)
{
	return { .name = name, .kind = kind, .qt = qt, .tok = tok, .node = (NodeIndex)node, .val = value::NONE };
}

struct ImplicitTypedefState
{
	string_interner::StringId name;
	bool declaration_saw_typedef;
}

fn void? seed_implicit_typedef(void* context, Parser* p)
{
	ImplicitTypedefState* state = (ImplicitTypedefState*)context;
	p.define_symbol(parser_test_symbol(state.name, symbol_stack::SymbolKind.TYPEDEF, 0, 90));
}

fn void? inspect_implicit_typedef(void* context, Parser* p)
{
	ImplicitTypedefState* state = (ImplicitTypedefState*)context;
	symbol_stack::Symbol found;
	state.declaration_saw_typedef = p.find_typedef(state.name, 0, false, &found)!! && found.kind == symbol_stack::SymbolKind.TYPEDEF;
	p.advance();
}

fn void parser_symbol_lookup_shadowing_and_scope_reuse() @test
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
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Parser p;
		p.init(&pp);
		assert(p.symbols_initialized && p.symbols.active_len == 1);

		string_interner::StringId ordinary = comp.intern_string("item");
		string_interner::StringId alias_name = comp.intern_string("Alias");
		string_interner::StringId tag = comp.intern_string("Record");
		p.define_symbol(parser_test_symbol(ordinary, symbol_stack::SymbolKind.DEF, 1, 11));
		p.define_symbol(parser_test_symbol(alias_name, symbol_stack::SymbolKind.TYPEDEF, 2, 12));
		p.define_symbol(parser_test_symbol(tag, symbol_stack::SymbolKind.STRUCT, 3, 13));
		assert(p.find_symbol(ordinary)!!.node == (NodeIndex)11);
		symbol_stack::Symbol found;
		assert(p.find_typedef(alias_name, 0, false, &found)!! && found.node == (NodeIndex)12);
		assert(p.find_tag(tag, KEYWORD_STRUCT, 0, IDENTIFIER, &found)!! && found.node == (NodeIndex)13);

		p.push_scope();
		p.define_symbol(parser_test_symbol(ordinary, symbol_stack::SymbolKind.DECL, 4, 21, type_store::LONG));
		assert(p.find_symbol(ordinary)!!.node == (NodeIndex)21);
		p.pop_scope();
		assert(p.find_symbol(ordinary)!!.node == (NodeIndex)11);

		string_interner::StringId scoped = comp.intern_string("scoped");
		p.push_scope();
		p.define_symbol(parser_test_symbol(scoped, symbol_stack::SymbolKind.DEF, 5, 31, type_store::LONG));
		p.pop_scope();
		assert(!@ok(p.find_symbol(scoped)));

		p.push_scope(); // Reuses the popped scope after clearing its old entries.
		assert(!@ok(p.find_symbol(scoped)));
		p.define_symbol(parser_test_symbol(scoped, symbol_stack::SymbolKind.DEF, 6, 32, type_store::LONG));
		assert(p.find_symbol(scoped)!!.node == (NodeIndex)32);
		p.pop_scope();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void implicit_typedefs_run_inside_outer_scope_before_declarations() @test
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
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		pp.tokens.push({ .id = IDENTIFIER, .loc = source::UNUSED_LOCATION });
		pp.tokens.push({ .id = EOF, .loc = source::UNUSED_LOCATION });
		ImplicitTypedefState state = { .name = comp.intern_string("Implicit") };
		Parser p;
		FnHandler handler = {
			.context = &state,
			.declaration = &inspect_implicit_typedef,
			.implicit_typedefs = &seed_implicit_typedef,
		};
		p.init(&pp, &handler);
		Tree result = p.parse()!!;
		assert(state.declaration_saw_typedef);
		assert(!p.symbols_initialized && p.symbols.active_len == 0);
		assert(result.tokens.len == 2);
		result.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void parser_symbol_diagnostics_keep_token_macro_locations_and_fatal_errors() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("symbol-macro.c", "Record\nMACRO\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs token = { .id = IDENTIFIER, .loc = parser_loc(src, 0, 1) };
		token.add_expansion_location(comp.gpa, { parser_loc(src, 7, 2), parser_loc(src, 0, 1) });
		pp.add_token(token)!!;
		pp.tokens.push({ .id = EOF, .loc = source::UNUSED_LOCATION });
		string_interner::StringId tag = comp.intern_string("Record");
		Parser p;
		p.init(&pp);
		p.bind_finalized_tokens();
		p.define_symbol(parser_test_symbol(tag, symbol_stack::SymbolKind.STRUCT, 0, 42));
		symbol_stack::Symbol found;
		assert(!@catch(p.find_typedef(tag, 0, false, &found)));
		assert(d.messages.len() == 3);
		test::eq(d.messages[0].text, "must use 'struct' tag to refer to type 'Record'");
		test::eq(d.messages[0].location.path, "symbol-macro.c");
		assert(d.messages[0].location.line_no == 1 && d.messages[0].location.col == 1);
		test::eq(d.messages[1].text, "expanded from here");
		assert(d.messages[1].location.line_no == 2 && d.messages[1].location.col == 1);
		test::eq(d.messages[2].text, "expanded from here");
		assert(d.messages[2].location.line_no == 1 && d.messages[2].location.col == 1);
		p.free();

		// A writer failure during a SymbolContext diagnostic must propagate
		// through find_typedef, and explicit free still releases the scope.
		d.free();
		RejectSymbolWriter reject = {};
		d.init_writer(&reject, diagnostics::ColorMode.NO_COLOR);
		Parser fatal;
		fatal.init(&pp);
		fatal.bind_finalized_tokens();
		fatal.define_symbol(parser_test_symbol(tag, symbol_stack::SymbolKind.STRUCT, 0, 43));
		assert(@catch(fatal.find_typedef(tag, 0, false, &found)) == compilation::FATAL_ERROR);
		assert(d.errors == 1);
		fatal.free();
		assert(!fatal.symbols_initialized);
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void parser_failure_cleanup_allows_later_success() @test
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
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		pp.tokens.push({ .id = IDENTIFIER, .loc = source::UNUSED_LOCATION });
		pp.tokens.push({ .id = EOF, .loc = source::UNUSED_LOCATION });

		Parser p;
		FnHandler failing_handler = { .declaration = &fail_after_allocating_tree_node };
		p.init(&pp, &failing_handler);
		assert(@catch(p.parse()) == compilation::FATAL_ERROR);
		assert(!p.initialized);
		assert(!p.symbols_initialized && p.symbols.active_len == 0);
		assert(d.messages.len() == 1);
		test::eq(d.messages[0].kind, diagnostics::MessageKind.FATAL_ERROR);
		test::eq(d.messages[0].text, "fatal parser diagnostic");

		// Reinitialize over the same borrowed token buffer and prove the failed
		// tree's owned allocations were released before a clean parse succeeds.
		FnHandler recovering_handler = { .declaration = &recover_after_failure };
		p.init(&pp, &recovering_handler);
		Tree result = p.parse()!!;
		assert(result.root_decls.len() == 0);
		assert(!p.symbols_initialized && p.symbols.active_len == 0);
		result.free();

		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void declaration_body_installs_only_supplied_function_context_and_restores_it() @test
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
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Source src = comp.add_source_from_buffer("function-context.c", "{ 1; } { 2; }\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		FunctionContextBodyCheck check = {};
		CheckExpressions check_expressions = { &check };
		parser_declaration::DeclarationParser declarations = {
			.context = &check,
			.statements = { .expressions = &check_expressions },
			.function_return_qt = type_store::VOID,
			.function_context = { .active = true, .variadic = true, .named_param_count = 4 },
			.has_function_context = false,
		};
		Parser p;
		p.init(&pp, &declarations);
		p.bind_finalized_tokens();
		parser::FunctionContext enclosing = { .active = true, .variadic = false, .named_param_count = 9 };
		p.set_function_context(enclosing);

		p.parse_body()!!;
		assert(check.calls == 1);
		assert(p.function_context.active == enclosing.active);
		assert(p.function_context.variadic == enclosing.variadic);
		assert(p.function_context.named_param_count == enclosing.named_param_count);

		check.expected_active = true;
		check.expected_variadic = true;
		check.expected_named_params = 4;
		declarations.has_function_context = true;
		p.handler = &declarations;
		p.parse_body()!!;
		assert(check.calls == 2);
		assert(p.function_context.active == enclosing.active);
		assert(p.function_context.variadic == enclosing.variadic);
		assert(p.function_context.named_param_count == enclosing.named_param_count);

		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void va_pack_function_context_requires_named_variadic_inline_function() @test
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
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Parser p;
		p.init(&pp);
		type_store::NodeIndex decl = p.tree.add_node({ .kind = tree::NodeKind.FUNCTION,
			.function = { .qt = type_store::INVALID, .body = type_store::NODE_NULL,
				.definition = type_store::NODE_NULL } });
		p.set_function_context({});
		assert(!p.check_va_pack_function(0, "__builtin_va_arg_pack")!!);
		test::eq(d.messages[0].text, "'__builtin_va_arg_pack' cannot be used outside a function");

		p.set_function_context({ .active = true, .declaration = decl.pack(),
			.variadic = false, .named_param_count = 1 });
		assert(!p.check_va_pack_function(0, "__builtin_va_arg_pack")!!);
		test::eq(d.messages[1].text, "'__builtin_va_arg_pack' used in a function with fixed args");

		p.set_function_context({ .active = true, .declaration = decl.pack(),
			.variadic = true, .named_param_count = 0 });
		assert(!p.check_va_pack_function(0, "__builtin_va_arg_pack")!!);
		test::eq(d.messages[2].text, "'__builtin_va_arg_pack' used in a function with fixed args");

		p.set_function_context({ .active = true, .declaration = decl.pack(),
			.variadic = true, .named_param_count = 1 });
		assert(!p.check_va_pack_function(0, "__builtin_va_arg_pack")!!);
		test::eq(d.messages[3].text, "'__builtin_va_arg_pack' used in a function that is not always inlined");

		attribute::Attribute always_inline = { .args = { .tag = attribute::AttributeTag.ALWAYS_INLINE },
			.syntax = attribute::AttributeSyntax.GNU,
			.name = { .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.ALWAYS_INLINE } };
		attribute_map::AttrRef always_ref = p.tree.attr_map.put(always_inline);
		attribute_map::AttrRef[1] always_refs = { always_ref };
		p.tree.attr_map.set_decl_attrs(decl, always_refs[..]);
		assert(p.check_va_pack_function(0, "__builtin_va_arg_pack")!!);

		attribute::Attribute gnu_inline = { .args = { .tag = attribute::AttributeTag.GNU_INLINE },
			.syntax = attribute::AttributeSyntax.GNU,
			.name = { .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.GNU_INLINE } };
		attribute_map::AttrRef gnu_ref = p.tree.attr_map.put(gnu_inline);
		attribute_map::AttrRef[1] gnu_refs = { gnu_ref };
		p.tree.attr_map.set_decl_attrs(decl, gnu_refs[..]);
		assert(p.check_va_pack_function(0, "__builtin_va_arg_pack")!!);
		assert(d.messages.len() == 4);

		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void va_pack_postfix_context_is_direct_typed_and_restored() @test
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
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		Source src = comp.add_source_from_buffer("va-pack-context.c",
			"__builtin_va_arg_pack() callee(__builtin_va_arg_pack(), 1) callee(1, __builtin_va_arg_pack()) callee(1 + __builtin_va_arg_pack())\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		Parser p;
		p.init(&pp);
		p.bind_finalized_tokens();
		type_store::NodeIndex decl = p.tree.add_node({ .kind = tree::NodeKind.FUNCTION,
			.function = { .qt = type_store::INVALID, .body = type_store::NODE_NULL,
				.definition = type_store::NODE_NULL } });
		attribute::Attribute always_inline = { .args = { .tag = attribute::AttributeTag.ALWAYS_INLINE },
			.syntax = attribute::AttributeSyntax.GNU,
			.name = { .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.ALWAYS_INLINE } };
		attribute_map::AttrRef attr_ref = p.tree.attr_map.put(always_inline);
		attribute_map::AttrRef[1] refs = { attr_ref };
		p.tree.attr_map.set_decl_attrs(decl, refs[..]);
		p.set_function_context({ .active = true, .declaration = decl.pack(),
			.variadic = true, .named_param_count = 1 });

		parser_builtin::BuiltinParser builtin = { .parser = &p };
		p.tok_i = 1;
		parser_result::Result outside = builtin.va_arg_pack(0)!!;
		assert(outside.qt.is_invalid());
		test::eq(d.messages[0].text, "'__va_arg_pack' used outside a call");

		type_store::FuncParam[1] params = { { .qt = type_store::INT } };
		VaPackPostfixCheck check = { .callee_qt = comp.type_store.put(type_store::type_func(
			type_store::INT, type_store::FuncKind.VARIADIC, params[..])) };
		parser_postfix::CallbackParts postfix_parts = { .context = &check, .primary = &va_pack_test_primary, .nested = &va_pack_test_expression };
		parser_postfix::PostfixParser postfix = { .parser = &p, .parts = &postfix_parts };
		parser::VaArgPackCallContext enclosing = { .active = true, .variadic = false, .typed = true };
		p.va_arg_pack_call = enclosing;

		parser_result::Result typed_nonfinal_call = postfix.parse()!!;
		assert(typed_nonfinal_call.node.get(&p.tree).kind == tree::NodeKind.CALL_EXPR);
		assert(check.observed_count == 2);
		assert(check.observed[0].active && check.observed[0].variadic && check.observed[0].typed);
		assert(!check.observed[1].active);
		assert(d.messages.len() == 3);
		test::eq(d.messages[1].text, "'__va_arg_pack' passed as non-variadic argument");
		test::eq(d.messages[2].text, "'__va_arg_pack' is not the final argument");
		assert(p.va_arg_pack_call.active == enclosing.active);
		assert(p.va_arg_pack_call.variadic == enclosing.variadic);
		assert(p.va_arg_pack_call.typed == enclosing.typed);

		parser_result::Result untyped_final_call = postfix.parse()!!;
		assert(untyped_final_call.node.get(&p.tree).kind == tree::NodeKind.CALL_EXPR);
		assert(check.observed_count == 4);
		assert(!check.observed[2].active);
		assert(check.observed[3].active && check.observed[3].variadic && !check.observed[3].typed);
		assert(d.messages.len() == 3);
		assert(p.va_arg_pack_call.active == enclosing.active);
		assert(p.va_arg_pack_call.variadic == enclosing.variadic);
		assert(p.va_arg_pack_call.typed == enclosing.typed);

		parser_result::Result embedded_call = postfix.parse()!!;
		assert(embedded_call.node.get(&p.tree).kind == tree::NodeKind.CALL_EXPR);
		assert(check.observed_count == 6);
		assert(!check.observed[4].active && !check.observed[5].active);
		assert(d.messages.len() == 4);
		test::eq(d.messages[3].text, "'__va_arg_pack' used outside a call");
		assert(p.va_arg_pack_call.active == enclosing.active);
		assert(p.va_arg_pack_call.variadic == enclosing.variadic);
		assert(p.va_arg_pack_call.typed == enclosing.typed);

		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

<* Statement expressions routed to `inspect_function_context_body` with the check as context. *>
struct CheckExpressions (parser::IExpressionGrammar)
{
	FunctionContextBodyCheck* check;
}

fn parser_result::Result? CheckExpressions.expression(&self, parser::Parser* p, bool eval) @dynamic
	=> inspect_function_context_body(self.check, p, eval);
fn parser_result::Result? CheckExpressions.assignment_expression(&self, parser::Parser* p, bool eval) @dynamic
	=> parser::HOOK_ABSENT~;
fn parser_result::Result? CheckExpressions.integer_constant_expression(&self, parser::Parser* p,
	parser::ConstDeclFoldingMode mode, bool eval) @dynamic => parser::HOOK_ABSENT~;
