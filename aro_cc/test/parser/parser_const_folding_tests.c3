// Tests the parser's constant-declaration folding modes through its public
// constant-expression entry points. These target the upcoming mode API.
module parser_const_folding_tests;
import aro::frontend::c::compilation, aro::frontend::c::diagnostics, aro::frontend::c::parser, aro::frontend::c::parser_result;
import aro::frontend::c::preprocessor, aro::source, aro::frontend::c::symbol_stack, aro::frontend::c::tokenizer, aro::frontend::c::tokens, aro::frontend::c::tree;
import aro::string_interner, aro::frontend::c::type_store, aro::frontend::c::value;
import std::core::mem::allocators;

fn void stored_value_equals(tree::Tree* tree, NodeIndex node, long expected, Compilation* comp)
{
	if (try stored = tree.value_of(node)) { assert(stored.to_i64(comp)!! == expected); }
	else { unreachable("folded constant expression did not store its AST value"); }
}

fn void constant_expression_stores_folded_value_and_restores_mode() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		Source src = comp.add_source_from_buffer("const-fold.c", "2 + 2\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		parser::Parser p;
		p.init(&pp);
		p.bind_finalized_tokens();
		p.const_decl_folding = parser::ConstDeclFoldingMode.NO_CONST_DECL_FOLDING;
		parser_result::Result result = p.const_expr(true,
			parser::ConstDeclFoldingMode.FOLD_CONST_DECLS)!!;
		assert(result.node.kind(&p.tree) == tree::NodeKind.ADD_EXPR);
		stored_value_equals(&p.tree, result.node, 4, &comp);
		assert(p.const_decl_folding == parser::ConstDeclFoldingMode.NO_CONST_DECL_FOLDING,
			"const_expr did not restore the caller's folding mode");
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void unavailable_value_is_not_stored() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		Source src = comp.add_source_from_buffer("const-fold-unavailable.c", "answer\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		StringId answer = comp.intern_string("answer");
		parser::Parser p;
		p.init(&pp);
		p.bind_finalized_tokens();
		type_store::QualType const_int = type_store::INT.with_qualifiers({ .is_const = true });
		NodeIndex declaration = p.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
			.variable = { .qt = const_int } });
		p.define_symbol({ .name = answer, .kind = symbol_stack::SymbolKind.DEF, .qt = const_int,
			.node = declaration, .val = value::int_i64(2, &comp) });
		parser_result::Result result = p.const_expr(true,
			parser::ConstDeclFoldingMode.NO_CONST_DECL_FOLDING)!!;
		assert(result.val.is_none());
		bool found_value = false;
		if (try stored = p.tree.value_of(result.node)) { found_value = true; }
		assert(!found_value, "unavailable value was stored on the AST node");
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void integer_const_expression_rejects_noninteger_and_propagates_malformed_input() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		Source src = comp.add_source_from_buffer("bad-integer-const.c", "1 +\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		parser::Parser p;
		p.init(&pp);
		p.bind_finalized_tokens();
		parser_result::Result? malformed = p.integer_const_expr(true,
			parser::ConstDeclFoldingMode.FOLD_CONST_DECLS);
		if (catch failure = malformed) { assert(failure == parser::PARSING_FAILED); }
		else { assert(false, "malformed integer constant expression was accepted"); }
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void integer_const_expression_rejects_noninteger_result() @test
{
	// A typed double identifier: the integer entry point checks the result
	// type after parsing.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		Source src = comp.add_source_from_buffer("float-integer-const.c", "x\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		StringId x = comp.intern_string("x");
		parser::Parser p;
		p.init(&pp);
		p.bind_finalized_tokens();
		NodeIndex declaration = p.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
			.variable = { .qt = type_store::DOUBLE } });
		p.define_symbol({ .name = x, .kind = symbol_stack::SymbolKind.DEF, .qt = type_store::DOUBLE, .node = declaration });
		parser_result::Result? result = p.integer_const_expr(true,
			parser::ConstDeclFoldingMode.FOLD_CONST_DECLS);
		if (catch failure = result) { assert(failure == parser::PARSING_FAILED); }
		else { assert(false, "noninteger expression accepted as integer constant expression"); }
		assert(d.messages.len() == 1);
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void const_expression_restores_mode_after_parse_failure() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		Source src = comp.add_source_from_buffer("const-fold-fault.c", "1 +\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		parser::Parser p;
		p.init(&pp);
		p.bind_finalized_tokens();
		p.const_decl_folding = parser::ConstDeclFoldingMode.GNU_FOLDING_EXTENSION;
		fault failure = @catch(p.const_expr(true, parser::ConstDeclFoldingMode.NO_CONST_DECL_FOLDING));
		assert(failure == parser::PARSING_FAILED);
		assert(p.const_decl_folding == parser::ConstDeclFoldingMode.GNU_FOLDING_EXTENSION,
			"const_expr did not restore the caller's mode after a fault");
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void referenced_const_declaration_uses_extension_folding_mode() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		d.set("gnu-folding-constant", WARNING)!!;
		Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		Source src = comp.add_source_from_buffer("const-fold-extension.c", "answer\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		StringId answer = comp.intern_string("answer");
		parser::Parser p;
		p.init(&pp);
		p.bind_finalized_tokens();
		type_store::QualType const_int = type_store::INT.with_qualifiers({ .is_const = true });
		NodeIndex declaration = p.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
			.variable = { .qt = const_int } });
		p.define_symbol({ .name = answer, .kind = symbol_stack::SymbolKind.DEF, .qt = const_int,
			.node = declaration, .val = value::int_i64(42, &comp) });
		parser_result::Result result = p.integer_const_expr(true,
			parser::ConstDeclFoldingMode.GNU_FOLDING_EXTENSION)!!;
		stored_value_equals(&p.tree, result.node, 42, &comp);
		assert(d.messages.len() == 1,
			"GNU folding mode should diagnose a referenced const declaration");
		p.const_decl_folding = parser::ConstDeclFoldingMode.GNU_VLA_FOLDING_EXTENSION;
		p.referenced_integer_constant(p.symbols.lookup_var(answer)!!.val,
			true, false, p.tok_i);
		assert(d.messages.len() == 2,
			"GNU VLA folding mode should use the VLA-specific diagnostic");
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}
