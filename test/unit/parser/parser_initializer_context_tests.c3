// Initializer value requirements and variable-length-array diagnostics.
module parser_init_ctx_tests;
import aro::compilation, aro::diagnostics, aro::parser, aro::parser_declaration, aro::parser_result;
import aro::preprocessor, aro::source, aro::symbol_stack, aro::tokens, aro::tokenizer, aro::tree, aro::type_store, aro::value;

fn parser_result::Result? parse_context_test_expr(void* context, parser::Parser* p, bool eval)
{
	if (p.at_eof()) return parser::PARSING_FAILED~;
	tokens::TokenIndex tok = p.tok_i;
	String spelling = p.pp.tree_token_slice(p.tree.tokens[(usz)tok]);
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
		.literal = { .literal_tok = tok, .qt = type_store::INT } });
	p.advance();
	value::Value val = eval && spelling != "unknown" ? value::int_i64(1, p.comp) : value::NONE;
	return { .node = node, .qt = type_store::INT, .val = val };
}

fn parser_result::Result? parse_context_test_ice(void* context, parser::Parser* p, parser::ConstDeclFoldingMode folding)
{
	return parse_context_test_expr(context, p, true);
}

fn void init_context_parser(Compilation* comp, Preprocessor* pp, Source src, Parser* p)
{
	pp.init(comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
	pp.add_token(pp.preprocess(src)!!)!!;
	p.init(pp, {});
	p.bind_finalized_tokens();
	p.bind_initializer_parser(&grammar_parse_context_test_expr);
	type_store::NodeIndex declaration = p.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .qt = type_store::INT } });
	p.define_symbol({ .name = comp.intern_string("unknown"), .kind = symbol_stack::SymbolKind.DEF,
		.qt = type_store::INT, .node = declaration, .val = value::NONE });
}

fn void runtime_initializer_accepts_unavailable_value() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		source::Source src = comp.add_source_from_buffer("runtime-init.c", "unknown")!!;
		preprocessor::Preprocessor pp;
		parser::Parser p;
		init_context_parser(&comp, &pp, src, &p);
		parser_result::Result parsed = p.parse_initializer(type_store::INT)!!;
		assert(parsed.val.is_none());
		assert(d.messages.len() == 0);
		assert(p.init_context == parser::InitContext.RUNTIME);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void constexpr_initializer_requires_known_value() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		source::Source src = comp.add_source_from_buffer("constexpr-init.c", "unknown")!!;
		preprocessor::Preprocessor pp;
		parser::Parser p;
		init_context_parser(&comp, &pp, src, &p);
		parser_declaration::DeclarationParser declaration = {};
		declaration.parse_variable_initializer(&p, type_store::INT, true, false)!!;
		assert(d.messages.len() == 1);
		test::eq(d.messages[0].text, "constexpr variable must be initialized by a constant expression");
		assert(p.init_context == parser::InitContext.RUNTIME);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void constexpr_initializer_accepts_known_value() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		source::Source src = comp.add_source_from_buffer("constexpr-known-init.c", "1")!!;
		preprocessor::Preprocessor pp;
		parser::Parser p;
		init_context_parser(&comp, &pp, src, &p);
		parser_declaration::DeclarationParser declaration = {};
		parser_result::Result parsed = declaration.parse_variable_initializer(&p, type_store::INT, true, false)!!;
		assert(!parsed.val.is_none(), "constexpr initialization keeps the scalar value available to the declaration owner");
		assert(d.messages.len() == 0);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void static_aggregate_initializer_checks_saved_child_values() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		source::Source src = comp.add_source_from_buffer("static-init.c", "{ 1, 2 }")!!;
		preprocessor::Preprocessor pp;
		parser::Parser p;
		init_context_parser(&comp, &pp, src, &p);
		type_store::QualType array_ty = comp.type_store.put(type_store::type_array(type_store::INT, type_store::ArrayLenKind.FIXED, 3));
		parser_declaration::DeclarationParser declaration = {};
		parser_result::Result parsed = declaration.parse_variable_initializer(&p, array_ty, false, true)!!;
		tree::Node array = parsed.node.get(&p.tree);
		assert(array.kind == tree::NodeKind.ARRAY_INIT_EXPR);
		assert(array.container_init.items.len == 3);
		assert(array.container_init.items[2].get(&p.tree).kind == tree::NodeKind.ARRAY_FILLER_EXPR);
		assert(d.messages.len() == 0, "constant children and zero-filled elements satisfy static initialization");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void static_initializer_rejects_unavailable_value() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		source::Source src = comp.add_source_from_buffer("static-unknown-init.c", "unknown")!!;
		preprocessor::Preprocessor pp;
		parser::Parser p;
		init_context_parser(&comp, &pp, src, &p);
		parser_declaration::DeclarationParser declaration = {};
		declaration.parse_variable_initializer(&p, type_store::INT, false, true)!!;
		assert(d.messages.len() == 1);
		test::eq(d.messages[0].text, "initializer element is not a compile-time constant");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// Emits a known ERROR diagnostic and returns no saved value, so a static
// requirement would fail on top of it unless the error skip applies.
fn parser_result::Result? parse_context_error_test_expr(void* context, parser::Parser* p, bool eval)
{
	if (p.at_eof()) return parser::PARSING_FAILED~;
	tokens::TokenIndex tok = p.tok_i;
	Diagnostic.EXPECTED_EXPR.@emit(p, tok)!;
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
		.literal = { .literal_tok = tok, .qt = type_store::INT } });
	p.advance();
	return { .node = node, .qt = type_store::INT, .val = value::NONE };
}

fn void init_context_error_parser(Compilation* comp, Preprocessor* pp, Source src, Parser* p)
{
	pp.init(comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
	pp.add_token(pp.preprocess(src)!!)!!;
	p.init(pp, {});
	p.bind_finalized_tokens();
	p.bind_initializer_parser(&grammar_parse_context_error_test_expr);
}

fn void static_initializer_skips_value_check_after_error() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		source::Source src = comp.add_source_from_buffer("static-error-init.c", "unknown")!!;
		preprocessor::Preprocessor pp;
		parser::Parser p;
		init_context_error_parser(&comp, &pp, src, &p);
		p.parse_initializer_with_context(type_store::INT, parser::InitContext.STATIC, false)!!;
		assert(d.messages.len() == 1, "a static initializer that already reported an error is not re-checked for a value");
		test::eq(d.messages[0].text, "expected expression");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void variable_length_array_initializer_reports_diagnostic_and_recovers() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		source::Source src = comp.add_source_from_buffer("vla-init.c", "{ 1 }")!!;
		preprocessor::Preprocessor pp;
		parser::Parser p;
		init_context_parser(&comp, &pp, src, &p);
		type_store::NodeIndex bound = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
			.literal = { .literal_tok = 0, .qt = type_store::INT } });
		type_store::QualType vla_ty = comp.type_store.put(type_store::type_vla(type_store::INT, bound));
		parser_result::Result parsed = p.parse_initializer(vla_ty)!!;
		assert(parsed.node.get(&p.tree).kind == tree::NodeKind.DEFAULT_INIT_EXPR,
			"the unsupported VLA initializer is consumed and represented by the existing fallback node");
		assert(d.messages.len() == 1);
		test::eq(d.messages[0].text, "variable-sized object may not be initialized");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

alias InitAssignFn = fn parser_result::Result?(void* context, parser::Parser* p, bool eval);
alias InitIceFn = fn parser_result::Result?(void* context, parser::Parser* p, parser::ConstDeclFoldingMode folding);

<* IExpressionGrammar over this file's initializer test productions. *>
struct InitGrammar (parser::IExpressionGrammar)
{
	void* context;
	InitAssignFn assign;
	InitIceFn ice;
}

fn parser_result::Result? InitGrammar.assignment_expression(&self, parser::Parser* p, bool eval) @dynamic
	=> self.assign(self.context, p, eval);
fn parser_result::Result? InitGrammar.integer_constant_expression(&self, parser::Parser* p,
	parser::ConstDeclFoldingMode folding, bool eval) @dynamic
	=> self.ice(self.context, p, folding);

InitGrammar grammar_parse_context_test_expr = { null, &parse_context_test_expr, &parse_context_test_ice };
InitGrammar grammar_parse_context_error_test_expr = { null, &parse_context_error_test_expr, &parse_context_test_ice };
