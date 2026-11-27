// Focused tests for parser context ownership and token-buffer lifetime.
module parser_context_tests;
import aro::frontend::c::parser, aro::frontend::c::parser_declaration, aro::frontend::c::parser_result;
import aro::frontend::c::preprocessor, aro::frontend::c::tokens, aro::frontend::c::tokenizer, aro::frontend::c::tree;
import aro::frontend::c::compilation, aro::frontend::c::diagnostics, aro::source;
import aro::frontend::c::type_store, aro::frontend::c::symbol_stack, aro::string_interner, aro::frontend::c::value;
import aro::frontend::c::attribute, aro::frontend::c::attribute_map;
import aro::target;
import std::core::mem::allocators, std::io;

const target::Host TEST_HOST = { target::Arch.X86_64, target::OsTag.LINUX, target::Abi.GNU };

excuse CALLBACK_FAILURE;
excuse SYMBOL_TEST_WRITE_FAILURE;

struct RejectSymbolWriter (OutStream) { char unused; }

fn sz? RejectSymbolWriter.write(&self, char[] bytes) @dynamic => SYMBOL_TEST_WRITE_FAILURE~;
fn void? RejectSymbolWriter.write_byte(&self, char byte) @dynamic => SYMBOL_TEST_WRITE_FAILURE~;
fn void? RejectSymbolWriter.flush(&self) @dynamic => SYMBOL_TEST_WRITE_FAILURE~;

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
		comp.init(&ta, compilation::native_definition(), null, &d);
		comp.target = target::parse_triple("x86_64-linux-gnu", TEST_HOST)!!;
		type_store::init_named_types(&comp.type_store, &comp.target, &comp.string_interner);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;

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
		p.free();

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
		comp.init(&ta, compilation::native_definition(), null, &d);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
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
		comp.init(&ta, compilation::native_definition(), null, &d);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
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
		comp.init(&ta, compilation::native_definition(), null, &d);
		comp.target = target::parse_triple("x86_64-linux-gnu", TEST_HOST)!!;
		type_store::init_named_types(&comp.type_store, &comp.target, &comp.string_interner);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		pp.tokens.push({ .id = EOF, .loc = source::UNUSED_LOCATION });

		Parser p;
		p.init(&pp);
		Tree result = p.parse()!!;
		assert(result.tokens.ptr == pp.tokens.array_view().ptr);
		assert(result.tokens.len > 1, "the implicit typedef prelude adds generated tokens");
		assert(result.root_decls.len() > 0, "the empty translation unit still has its implicit typedef roots");
		result.free();
		p.free();

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
		comp.init(&ta, compilation::native_definition(), null, &d);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
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
		comp.init(&ta, compilation::native_definition(), null, &d);
		Source src = comp.add_source_from_buffer("macro.c", "FIRST SECOND\nmacro body\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;

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

fn symbol_stack::Symbol parser_test_symbol(string_interner::StringId name, symbol_stack::SymbolKind kind, uint tok, uint node, QualType qt = type_store::INT)
{
	return { .name = name, .kind = kind, .qt = qt, .tok = tok, .node = (NodeIndex)node, .val = value::NONE };
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
		comp.init(&ta, compilation::native_definition(), null, &d);
		Source src = comp.add_source_from_buffer("symbol-macro.c", "Record\nMACRO\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
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

		// A writer failure during a SymbolStack diagnostic must propagate
		// through find_typedef, and explicit free still releases the scope.
		d.free();
		RejectSymbolWriter reject = {};
		d.init_writer(&reject, false);
		Parser fatal;
		fatal.init(&pp);
		fatal.bind_finalized_tokens();
		fatal.define_symbol(parser_test_symbol(tag, symbol_stack::SymbolKind.STRUCT, 0, 43));
		assert(@catch(fatal.find_typedef(tag, 0, false, &found)) == compilation::FATAL_ERROR);
		assert(d.errors == 1);
		fatal.free();
		assert(fatal.symbols.active_len == 0);
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
		comp.init(&ta, compilation::native_definition(), null, &d);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		Source src = comp.add_source_from_buffer("function-context.c", "{ 1; } { 2; }\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		FunctionContextBodyCheck check = {};
		CheckExpressions check_expressions = { &check };
		Parser p;
		p.init(&pp);
		p.declarations = {
			.statements = { .expressions = &check_expressions },
			.function_return_qt = type_store::VOID,
			.function_context = { .active = true, .variadic = true, .named_param_count = 4 },
			.has_function_context = false,
		};
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
		p.declarations.has_function_context = true;
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
		comp.init(&ta, compilation::native_definition(), null, &d);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
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
		comp.init(&ta, compilation::native_definition(), null, &d);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
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

		p.tok_i = 1;
		parser_result::Result outside = p.builtin_va_arg_pack(0)!!;
		assert(outside.qt.is_invalid());
		test::eq(d.messages[0].text, "'__va_arg_pack' used outside a call");

		// `callee` is a typed variadic function with one named parameter. The real
		// postfix grammar sets the va_arg_pack call context per argument; the
		// builtin's diagnostics show which context each pack saw.
		type_store::FuncParam[1] params = { { .qt = type_store::INT } };
		type_store::QualType callee_qt = comp.type_store.put(type_store::type_func(
			type_store::INT, type_store::FuncKind.VARIADIC, params[..]));
		type_store::NodeIndex callee_decl = p.tree.add_node({ .kind = tree::NodeKind.FUNCTION,
			.function = { .qt = callee_qt, .body = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
		p.define_symbol({ .name = comp.intern_string("callee"), .kind = symbol_stack::SymbolKind.DECL,
			.qt = callee_qt, .node = callee_decl });
		parser::VaArgPackCallContext enclosing = { .active = true, .variadic = false, .typed = true };
		p.va_arg_pack_call = enclosing;

		// Pack in the typed (named-parameter) slot, then followed by another argument.
		parser_result::Result typed_nonfinal_call = p.parse_postfix_expr()!!;
		assert(typed_nonfinal_call.node.get(&p.tree).kind == tree::NodeKind.CALL_EXPR);
		assert(d.messages.len() == 3);
		test::eq(d.messages[1].text, "'__va_arg_pack' passed as non-variadic argument");
		test::eq(d.messages[2].text, "'__va_arg_pack' is not the final argument");
		assert(p.va_arg_pack_call.active == enclosing.active);
		assert(p.va_arg_pack_call.variadic == enclosing.variadic);
		assert(p.va_arg_pack_call.typed == enclosing.typed);

		// Pack as the final, untyped (variadic) argument: accepted.
		parser_result::Result untyped_final_call = p.parse_postfix_expr()!!;
		assert(untyped_final_call.node.get(&p.tree).kind == tree::NodeKind.CALL_EXPR);
		assert(d.messages.len() == 3);
		assert(p.va_arg_pack_call.active == enclosing.active);
		assert(p.va_arg_pack_call.variadic == enclosing.variadic);
		assert(p.va_arg_pack_call.typed == enclosing.typed);

		// Pack nested inside an argument expression is not a direct argument: it
		// sees no call context, and its invalid type then fails the `+` operand.
		sz before_embedded = d.messages.len();
		assert(@catch(p.parse_postfix_expr()) == parser::PARSING_FAILED);
		bool saw_outside = false;
		for (sz i = before_embedded; i < d.messages.len(); i++)
		{
			if (d.messages[i].text == "'__va_arg_pack' used outside a call") saw_outside = true;
		}
		assert(saw_outside);
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
