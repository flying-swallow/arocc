// Tests the parser's constant-declaration folding modes through its public
// constant-expression entry points. These target the upcoming mode API.
module parser_const_folding_tests;
import aro::compilation, aro::diagnostics, aro::parser, aro::parser_expression, aro::parser_result;
import aro::preprocessor, aro::source, aro::symbol_stack, aro::tokenizer, aro::tokens, aro::tree;
import aro::string_interner, aro::type_store, aro::value;
import std::core::mem::allocators;

excuse PRIMARY_CALLBACK_FAILURE;

struct ConstContext
{
	symbol_stack::SymbolStack* symbols;
	StringId constant_name;
	uint calls;
}

fn parser_result::Result? parse_const_primary(void* context, parser::Parser* p, bool eval)
{
	if (p.at_eof()) return parser_expression::NO_EXPRESSION~;
	ConstContext* ctx = (ConstContext*)context;
	tokens::TokenIndex tok = p.tok_i;
	tokenizer::TokenId id = p.tree.tokens[(usz)tok].id;
	parser_result::Result result;
	if (id == tokenizer::TokenId.IDENTIFIER)
	{
		Symbol symbol = ctx.symbols.lookup(ctx.constant_name, symbol_stack::ScopeKind.VARS)!!;
		NodeIndex ref = p.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
			.decl_ref = { .qt = symbol.qt, .decl = symbol.node, .name_tok = tok } });
		value::Value referenced = eval ? p.referenced_integer_constant(
			symbol.val, symbol.qt.is_real_int(p.comp),
			symbol.kind == symbol_stack::SymbolKind.ENUMERATION, tok) : value::NONE;
		result.init(ref, symbol.qt, referenced);
	}
	else
	{
		String spelling = p.pp.tree_token_slice(p.tree.tokens[(usz)tok]);
		long n;
		if (spelling == "1") { n = 1; }
		else if (spelling == "2") { n = 2; }
		else { unreachable("unexpected integer token in const-folding fixture"); }
		NodeIndex literal = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
			.literal = { .literal_tok = tok, .qt = type_store::INT } });
		result.init(literal, type_store::INT, eval ? value::int_i64(n, p.comp) : value::NONE);
	}
	ctx.calls++;
	p.advance();
	return result;
}

fn parser_result::Result? fail_const_primary(void* context, parser::Parser* p, bool eval)
{
	return PRIMARY_CALLBACK_FAILURE~;
}

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
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("const-fold.c", "2 + 2\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		p.const_decl_folding = parser::ConstDeclFoldingMode.NO_CONST_DECL_FOLDING;
		ConstContext context = {};
		parser_result::Result result = p.const_expr_with_primary(&context, &parse_const_primary, true,
			parser::ConstDeclFoldingMode.FOLD_CONST_DECLS)!!;
		assert(result.node.kind(&p.tree) == tree::NodeKind.ADD_EXPR);
		stored_value_equals(&p.tree, result.node, 4, &comp);
		assert(p.const_decl_folding == parser::ConstDeclFoldingMode.NO_CONST_DECL_FOLDING,
			"const_expr did not restore the caller's folding mode");
		p.tree.free();
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
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("const-fold-unavailable.c", "answer\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		SymbolStack symbols;
		symbols.init(&ta);
		symbols.push_scope();
		StringId answer = comp.intern_string("answer");
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		type_store::QualType const_int = type_store::INT.with_qualifiers({ .is_const = true });
		NodeIndex declaration = tree.add_node({ .kind = tree::NodeKind.VARIABLE,
			.variable = { .qt = const_int } });
		symbols.define({ .name = answer, .kind = symbol_stack::SymbolKind.DEF, .qt = const_int,
			.node = declaration, .val = value::int_i64(2, &comp) });
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		ConstContext context = { .symbols = &symbols, .constant_name = answer };
		parser_result::Result result = p.const_expr_with_primary(&context, &parse_const_primary, true,
			parser::ConstDeclFoldingMode.NO_CONST_DECL_FOLDING)!!;
		assert(result.val.is_none());
		bool found_value = false;
		if (try stored = p.tree.value_of(result.node)) { found_value = true; }
		assert(!found_value, "unavailable value was stored on the AST node");
		p.tree.free();
		symbols.pop_scope();
		symbols.free();
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
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("bad-integer-const.c", "1 +\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		ConstContext context = {};
		parser_result::Result? malformed = p.integer_const_expr_with_primary(&context, &parse_const_primary, true,
			parser::ConstDeclFoldingMode.FOLD_CONST_DECLS);
		if (catch failure = malformed) { assert(failure == parser_expression::PARSING_FAILED); }
		else { assert(false, "malformed integer constant expression was accepted"); }
		p.tree.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void integer_const_expression_rejects_noninteger_result() @test
{
	// The same typed-identifier setup used by parser_operator_tests ensures the
	// integer entry point checks the result type after parsing.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("float-integer-const.c", "x\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		SymbolStack symbols;
		symbols.init(&ta);
		symbols.push_scope();
		StringId x = comp.intern_string("x");
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		NodeIndex declaration = tree.add_node({ .kind = tree::NodeKind.VARIABLE,
			.variable = { .qt = type_store::DOUBLE } });
		symbols.define({ .name = x, .kind = symbol_stack::SymbolKind.DEF, .qt = type_store::DOUBLE, .node = declaration });
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		ConstContext context = { .symbols = &symbols, .constant_name = x };
		parser_result::Result? result = p.integer_const_expr_with_primary(&context, &parse_const_primary, true,
			parser::ConstDeclFoldingMode.FOLD_CONST_DECLS);
		if (catch failure = result) { assert(failure == parser_expression::PARSING_FAILED); }
		else { assert(false, "noninteger expression accepted as integer constant expression"); }
		assert(d.messages.len() == 1);
		p.tree.free();
		symbols.pop_scope();
		symbols.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void const_expression_restores_mode_after_primary_fault() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("const-fold-fault.c", "1\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		p.const_decl_folding = parser::ConstDeclFoldingMode.GNU_FOLDING_EXTENSION;
		fault failure = @catch(p.const_expr_with_primary(null, &fail_const_primary, true,
			parser::ConstDeclFoldingMode.NO_CONST_DECL_FOLDING));
		assert(failure == PRIMARY_CALLBACK_FAILURE);
		assert(p.const_decl_folding == parser::ConstDeclFoldingMode.GNU_FOLDING_EXTENSION,
			"const_expr did not restore the caller's mode after a fault");
		p.tree.free();
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
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("const-fold-extension.c", "answer\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		SymbolStack symbols;
		symbols.init(&ta);
		symbols.push_scope();
		StringId answer = comp.intern_string("answer");
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		type_store::QualType const_int = type_store::INT.with_qualifiers({ .is_const = true });
		NodeIndex declaration = tree.add_node({ .kind = tree::NodeKind.VARIABLE,
			.variable = { .qt = const_int } });
		symbols.define({ .name = answer, .kind = symbol_stack::SymbolKind.DEF, .qt = const_int,
			.node = declaration, .val = value::int_i64(42, &comp) });
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)tree.tokens.len;
		ConstContext context = { .symbols = &symbols, .constant_name = answer };
		parser_result::Result result = p.integer_const_expr_with_primary(&context, &parse_const_primary, true,
			parser::ConstDeclFoldingMode.GNU_FOLDING_EXTENSION)!!;
		stored_value_equals(&p.tree, result.node, 42, &comp);
		assert(d.messages.len() == 1,
			"GNU folding mode should diagnose a referenced const declaration");
		p.const_decl_folding = parser::ConstDeclFoldingMode.GNU_VLA_FOLDING_EXTENSION;
		p.referenced_integer_constant(symbols.lookup(answer, symbol_stack::ScopeKind.VARS)!!.val,
			true, false, p.tok_i);
		assert(d.messages.len() == 2,
			"GNU VLA folding mode should use the VLA-specific diagnostic");
		p.tree.free();
		symbols.pop_scope();
		symbols.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}
