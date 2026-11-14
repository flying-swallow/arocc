// Tests the expression parser with preprocessed tokens and a seeded symbol
// scope. The callback supplies primary tokens; unary and parenthesis parsing
// are part of the expression engine under test.
module parser_expression_tests;
import aro::compilation, aro::diagnostics, aro::parser, aro::parser_diagnostics, aro::parser_expression, aro::parser_result;
import aro::preprocessor, aro::source, aro::string_interner, aro::symbol_stack, aro::tokenizer, aro::tokens, aro::tree;
import aro::type_store, aro::value, aro::value_interner, aro::lang_opts;
import aro::parser_frontend;
import std::core::mem::allocators;

struct UnaryContext
{
	symbol_stack::SymbolStack* symbols;
	StringId identifier;
	StringId second_identifier;
	uint suppressed_primaries;
}

fn parser_result::Result? parse_seeded_unary(void* context, parser::Parser* p, bool eval)
{
	if (p.at_eof()) return parser_expression::NO_EXPRESSION~;
	UnaryContext* ctx = (UnaryContext*)context;
	tokens::TokenIndex tok = p.tok_i;
	tokenizer::TokenId id = p.tree.tokens[(usz)tok].id;
	parser_result::Result result;
	if (id == tokenizer::TokenId.IDENTIFIER)
	{
		String spelling = p.pp.tree_token_slice(p.tree.tokens[(usz)tok]);
		StringId name = spelling == "y" ? ctx.second_identifier : ctx.identifier;
		Symbol symbol = ctx.symbols.lookup(name, symbol_stack::ScopeKind.VARS)!!;
		NodeIndex ref = p.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
			.decl_ref = { .qt = symbol.qt, .decl = symbol.node, .name_tok = tok } });
		result.init(ref, symbol.qt, symbol.val);
	}
	else
	{
		// The fixture accepts only the small integer literals used below.
		String spelling = p.pp.tree_token_slice(p.tree.tokens[(usz)tok]);
		long literal_value = spelling == "0" ? 0 : spelling == "1" ? 1 : 2;
		if (!eval) ctx.suppressed_primaries++;
		NodeIndex literal = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
			.literal = { .literal_tok = tok, .qt = type_store::INT } });
		result.init(literal, type_store::INT, eval ? value::int_i64(literal_value, p.comp) : value::NONE);
	}
	p.advance();
	return result;
}

alias TypeNameProbeFn = fn parser::TypeNameProbe?(void* context, parser::Parser* p);

<* Parser handler that only supplies the speculative type-name probe. The
   probe function can be swapped to exercise different probe outcomes. *>
struct ProbeHandler (parser::IParserHandler)
{
	TypeNameProbeFn probe;
}

fn parser::TypeNameProbe? ProbeHandler.handle_typed_type_name_probe(&self, parser::Parser* p) @dynamic
	=> self.probe(null, p);

fn parser::TypeNameProbe? probe_int_type_name(void* context, parser::Parser* p)
{
	if (p.at_eof() || p.tree.tokens[(usz)p.tok_i].id != tokenizer::TokenId.KEYWORD_INT) return { .matched = false };
	p.advance();
	return { .matched = true, .qt = type_store::INT };
}

// Source-derived scope: this helper tests expression-engine semantics with a
// deliberately tiny primary callback, not the owning C grammar's unary parser.
fn void check_expression(String text, tree::NodeKind expected_kind, long expected_value,
	bool expect_failure = false, uint expected_suppressed = 0, bool conditional_right_assoc = false)
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("expr.c", text)!!;
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
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)p.tree.tokens.len;
		UnaryContext context = { .symbols = &symbols, .identifier = x, .second_identifier = x };
		parser_expression::ExpressionParser expression = { .parser = &p, .context = &context, .primary_expression = &parse_seeded_unary };
		parser_result::Result? maybe_result = expression.parse();
		if (catch parse_error = maybe_result)
		{
			assert(expect_failure, "unexpected expression parse failure");
			assert(parse_error == parser_expression::PARSING_FAILED || parse_error == parser_expression::NO_EXPRESSION ||
				parse_error == parser::PARSING_FAILED);
		}
		else
		{
			assert(!expect_failure, "malformed expression unexpectedly parsed");
			parser_result::Result result = maybe_result;
			assert(result.node.tag(&p.tree).kind == expected_kind);
			assert(result.val.to_i64(&comp)!! == expected_value);
			if (conditional_right_assoc)
			{
				Node outer = result.node.get(&p.tree);
				assert(outer.conditional.else_expr.get(&p.tree).kind == tree::NodeKind.COND_EXPR);
			}
		}
		assert(context.suppressed_primaries == expected_suppressed);
		p.tree.free();
		symbols.pop_scope();
		symbols.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void unary_and_parenthesized_expressions() @test
{
	check_expression("+2\n", tree::NodeKind.PLUS_EXPR, 2);
	check_expression("-2\n", tree::NodeKind.NEGATE_EXPR, -2);
	check_expression("!2\n", tree::NodeKind.BOOL_NOT_EXPR, 0);
	check_expression("~2\n", tree::NodeKind.BIT_NOT_EXPR, -3);
	check_expression("(2 + 2)\n", tree::NodeKind.PAREN_EXPR, 4);
}

fn void sizeof_type_name_has_no_expression_operand() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("expr.c", "sizeof(int)\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		ProbeHandler int_probe = { .probe = &probe_int_type_name };
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d, .handler = &int_probe };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)p.tree.tokens.len;
		UnaryContext context;
		parser_expression::ExpressionParser expression = { .parser = &p, .context = &context,
			.primary_expression = &parse_seeded_unary };
		parser_result::Result result = expression.parse()!!;
		assert(result.node.tag(&p.tree).kind == tree::NodeKind.SIZEOF_EXPR);
		assert((ulong)result.val.to_i64(&comp)!! == type_store::INT.sizeof_or_null(&comp)!!);
		Node node = result.node.get(&p.tree);
		assert(node.type_info.expr == type_store::NODE_NULL);
		assert(node.type_info.operand_qt.eql(type_store::INT, &comp));
		p.tree.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void alignof_type_name_has_no_expression_operand() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		Source src = comp.add_source_from_buffer("expr.c", "alignof(int)\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		ProbeHandler int_probe = { .probe = &probe_int_type_name };
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d, .handler = &int_probe };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)p.tree.tokens.len;
		UnaryContext context;
		parser_expression::ExpressionParser expression = { .parser = &p, .context = &context,
			.primary_expression = &parse_seeded_unary };
		parser_result::Result result = expression.parse()!!;
		assert(result.node.tag(&p.tree).kind == tree::NodeKind.ALIGNOF_EXPR);
		assert(result.val.to_i64(&comp)!! == type_store::INT.alignof(&comp));
		Node node = result.node.get(&p.tree);
		assert(node.type_info.expr == type_store::NODE_NULL);
		assert(node.type_info.operand_qt.eql(type_store::INT, &comp));
		p.tree.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void conditional_expression_is_right_associative() @test
{
	// Source-derived: Parser.zig's conditional production recurses at the same
	// precedence for its else arm, making the operator right associative.
	check_expression("1 ? 2 : 0 ? 1 : 2\n", tree::NodeKind.COND_EXPR, 2,
		false, 3, true);
}

fn void logical_and_conditional_short_circuit_suppresses_evaluation() @test
{
	check_expression("0 && 2\n", tree::NodeKind.BOOL_AND_EXPR, 0, false, 1);
	check_expression("1 || 2\n", tree::NodeKind.BOOL_OR_EXPR, 1, false, 1);
	check_expression("1 ? 2 : 0\n", tree::NodeKind.COND_EXPR, 2, false, 1);
}

fn void malformed_conditional_expression_fails() @test
{
	check_expression("1 ? 2\n", tree::NodeKind.COND_EXPR, 0, true);
	check_expression("1 ? 2 :\n", tree::NodeKind.COND_EXPR, 0, true);
	check_expression("1 +\n", tree::NodeKind.ADD_EXPR, 0, true);
}

fn void binary_expression_uses_preprocessed_tokens_and_seeded_symbol_types() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("expr.c", "#define EXPR x\nEXPR + 2\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;

		symbol_stack::SymbolStack symbols;
		symbols.init(&ta);
		symbols.push_scope();
		StringId x = comp.intern_string("x");
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		NodeIndex decl = tree.add_node({ .kind = tree::NodeKind.VARIABLE,
			.variable = { .name_tok = 0, .qt = type_store::INT } });
		symbols.define({ .name = x, .kind = symbol_stack::SymbolKind.DEF, .qt = type_store::INT,
			.node = decl, .val = value::int_i64(3, &comp) });

		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)p.tree.tokens.len;
		UnaryContext context = { .symbols = &symbols, .identifier = x, .second_identifier = x };
		parser_expression::ExpressionParser expression = {
			.parser = &p, .context = &context, .primary_expression = &parse_seeded_unary,
		};
		parser_result::Result result = expression.parse()!!;
		assert(result.qt.eql(type_store::INT, &comp));
		assert(result.node.tag(&p.tree).kind == tree::NodeKind.ADD_EXPR);
		assert(result.val.to_i64(&comp)!! == 5);
		assert(p.tok_i == 3 && p.at_eof());

		p.tree.free();
		symbols.pop_scope();
		symbols.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void assignment_expression_is_right_associative() @test
{
	// The callback's seeded identifiers each have type int; no constant value
	// is needed to check the shape of the right-associative assignment tree.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("assign.c", "x = y = 2\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		SymbolStack symbols;
		symbols.init(&ta);
		symbols.push_scope();
		StringId x = comp.intern_string("x");
		StringId y = comp.intern_string("y");
		Tree tree;
		tree.init(&comp, pp.tokens.array_view());
		NodeIndex x_decl = tree.add_node({ .kind = tree::NodeKind.VARIABLE, .variable = { .name_tok = 0, .qt = type_store::INT } });
		NodeIndex y_decl = tree.add_node({ .kind = tree::NodeKind.VARIABLE, .variable = { .name_tok = 0, .qt = type_store::INT } });
		symbols.define({ .name = x, .kind = symbol_stack::SymbolKind.DEF, .qt = type_store::INT, .node = x_decl });
		symbols.define({ .name = y, .kind = symbol_stack::SymbolKind.DEF, .qt = type_store::INT, .node = y_decl });
		// The unary fixture resolves each identifier through the seeded scope
		// and emits the literal for the final primary.
		parser::Parser p = { .pp = &pp, .comp = &comp, .diagnostics = &d };
		p.tree = tree;
		p.tok_end = (tokens::TokenIndex)p.tree.tokens.len;
		UnaryContext context = { .symbols = &symbols, .identifier = x, .second_identifier = y };
		parser_expression::ExpressionParser expression = { .parser = &p, .context = &context, .primary_expression = &parse_seeded_unary };
		parser_result::Result result = expression.parse()!!;
		assert(result.node.tag(&p.tree).kind == tree::NodeKind.ASSIGN_EXPR);
		Node inner = result.node.get(&p.tree);
		assert(inner.binary.rhs.get(&p.tree).kind == tree::NodeKind.ASSIGN_EXPR);
		p.tree.free();
		symbols.pop_scope();
		symbols.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// The parser-owned entry points below deliberately use the finalized token
// stream and the real PrimaryParser/PostfixParser composition. The small type
// name probe models the grammar-owned typedef lookup needed for cast ambiguity.
struct ExpressionFixture
{
	TrackingAllocator allocator;
	diagnostics::Diagnostics diagnostics;
	compilation::Compilation comp;
	preprocessor::Preprocessor pp;
	parser::Parser parser;
	ProbeHandler probe_handler;
	bool active;
}

fn parser::TypeNameProbe? expression_type_name_probe(void* context, parser::Parser* p)
{
	if (p.at_eof()) return { .matched = false };
	tokenizer::TokenId id = p.tree.tokens[(usz)p.tok_i].id;
	switch (id)
	{
		case KEYWORD_INT:
			p.advance();
			return { .matched = true, .qt = type_store::INT };
		case KEYWORD_LONG:
			p.advance();
			return { .matched = true, .qt = type_store::LONG };
		case KEYWORD_FLOAT:
			p.advance();
			return { .matched = true, .qt = type_store::FLOAT };
		case KEYWORD_CHAR:
			p.advance();
			return { .matched = true, .qt = type_store::CHAR };
		default: break;
	}
	if (id != tokenizer::TokenId.IDENTIFIER) return { .matched = false };
	StringId name = p.comp.intern_string(p.tree.tok_slice(p.tok_i));
	symbol_stack::Symbol? maybe_symbol = p.find_symbol(name);
	if (catch maybe_symbol) return { .matched = false };
	symbol_stack::Symbol symbol = maybe_symbol;
	if (symbol.kind != symbol_stack::SymbolKind.TYPEDEF) return { .matched = false };
	p.advance();
	return { .matched = true, .qt = symbol.qt };
}

fn parser::TypeNameProbe? expression_type_name_probe_consuming_miss(void* context, parser::Parser* p)
{
	if (!p.at_eof()) p.advance();
	return { .matched = false };
}

fn parser::TypeNameProbe? expression_type_name_probe_diagnosed_failure(void* context, parser::Parser* p)
{
	tokens::TokenIndex probe_tok = p.tok_i;
	p.advance();
	p.emit_parser_diag(parser_diagnostics::ParserDiag.TODO, "diagnosed probe failure", probe_tok)!;
	return parser::PARSING_FAILED~;
}

fn parser::TypeNameProbe? expression_type_name_probe_fatal_failure(void* context, parser::Parser* p)
{
	p.advance();
	return compilation::FATAL_ERROR~;
}

fn void ExpressionFixture.init(&self, String input, String path = "expr.c",
	lang_opts::Standard standard = lang_opts::DEFAULT.standard)
{
	self.allocator.init(mem);
	self.diagnostics.init_list(&self.allocator);
	self.comp.init(&self.allocator, null, &self.diagnostics);
	self.comp.langopts.standard = standard;
	self.pp.init(&self.comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
	source::Source src = self.comp.add_source_from_buffer(path, input)!!;
	TokenWithExpansionLocs eof = self.pp.preprocess(src)!!;
	self.pp.add_token(eof)!!;
	self.probe_handler = { .probe = &expression_type_name_probe };
	self.parser.init(&self.pp, &self.probe_handler);
	self.parser.bind_finalized_tokens();
	self.active = true;
}

fn void ExpressionFixture.free(&self)
{
	if (!self.active) return;
	self.parser.free();
	self.pp.free();
	self.comp.free();
	self.diagnostics.free();
	assert(self.allocator.allocation_count() == 0);
	self.allocator.free();
	self.active = false;
}

fn NodeIndex ExpressionFixture.seed_symbol(&self, String name, symbol_stack::SymbolKind kind,
	type_store::QualType qt, value::Value val = value::NONE)
{
	NodeIndex decl = self.parser.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 0, .qt = qt } });
	self.parser.define_symbol({ .name = self.comp.intern_string(name), .kind = kind,
		.qt = qt, .node = decl, .val = val });
	return decl;
}

fn bool has_expression_diagnostic(ExpressionFixture* f, String text)
{
	foreach (message : f.diagnostics.messages)
	{
		if (message.text == text) return true;
	}
	return false;
}

fn void parser_owned_sizeof_alignof_disambiguate_type_names_and_expressions() @test
{
	ExpressionFixture f;
	f.init("sizeof(int)\n");
	defer f.free();
	parser_result::Result sized_type = f.parser.expr()!!;
	assert(sized_type.node.tag(&f.parser.tree).kind == tree::NodeKind.SIZEOF_EXPR);
	Node sized_type_node = sized_type.node.get(&f.parser.tree);
	assert(sized_type_node.type_info.expr == type_store::NODE_NULL);
	assert(sized_type_node.type_info.operand_qt.eql(type_store::INT, &f.comp));
	assert((ulong)sized_type.val.to_i64(&f.comp)!! == type_store::INT.sizeof_or_null(&f.comp)!!);
	assert(f.parser.at_eof());

	f.free();
	f.init("alignof(Alias)\n", "expr.c", lang_opts::Standard.C23);
	f.seed_symbol("Alias", symbol_stack::SymbolKind.TYPEDEF, type_store::LONG);
	parser_result::Result aligned_type = f.parser.expr()!!;
	assert(aligned_type.node.tag(&f.parser.tree).kind == tree::NodeKind.ALIGNOF_EXPR);
	Node aligned_type_node = aligned_type.node.get(&f.parser.tree);
	assert(aligned_type_node.type_info.expr == type_store::NODE_NULL);
	assert(aligned_type_node.type_info.operand_qt.eql(type_store::LONG, &f.comp));
	assert(aligned_type.val.to_i64(&f.comp)!! == type_store::LONG.alignof(&f.comp));
	assert(f.parser.at_eof());

	f.free();
	f.init("sizeof(object)\n");
	NodeIndex object_decl = f.seed_symbol("object", symbol_stack::SymbolKind.DEF, type_store::INT);
	UnaryContext context = { .symbols = &f.parser.symbols,
		.identifier = f.comp.intern_string("object"), .second_identifier = f.comp.intern_string("object") };
	parser_result::Result sized_expression = f.parser.expr_with_primary(&context, &parse_seeded_unary)!!;
	assert(sized_expression.node.tag(&f.parser.tree).kind == tree::NodeKind.SIZEOF_EXPR);
	Node sized_expression_node = sized_expression.node.get(&f.parser.tree);
	assert(sized_expression_node.type_info.expr != type_store::NODE_NULL);
	NodeIndex sized_operand = sized_expression_node.type_info.expr.unpack()!!;
	Node sized_operand_node = sized_operand.get(&f.parser.tree);
	assert(sized_operand_node.kind == tree::NodeKind.PAREN_EXPR);
	assert(sized_operand_node.unary.operand.get(&f.parser.tree).decl_ref.decl == object_decl);
	assert(sized_expression_node.type_info.operand_qt.eql(type_store::INT, &f.comp));
	assert(f.parser.at_eof());
}

fn void parser_owned_type_name_probe_restores_only_nonmatches_and_propagates_faults() @test
{
	ExpressionFixture f;
	f.init("sizeof(object)\n");
	defer f.free();
	f.seed_symbol("object", symbol_stack::SymbolKind.DEF, type_store::INT);
	f.probe_handler.probe = &expression_type_name_probe_consuming_miss;
	UnaryContext context = { .symbols = &f.parser.symbols,
		.identifier = f.comp.intern_string("object"), .second_identifier = f.comp.intern_string("object") };
	parser_result::Result miss = f.parser.expr_with_primary(&context, &parse_seeded_unary)!!;
	assert(miss.node.tag(&f.parser.tree).kind == tree::NodeKind.SIZEOF_EXPR);
	assert(miss.node.get(&f.parser.tree).type_info.expr != type_store::NODE_NULL);
	assert(f.parser.at_eof(), "a consuming non-match must restore the expression cursor");
	assert(f.diagnostics.messages.len() == 0);

	f.free();
	f.init("sizeof(int)\n");
	f.probe_handler.probe = &expression_type_name_probe_diagnosed_failure;
	parser_result::Result? diagnosed = f.parser.expr();
	if (catch diagnosed_fault = diagnosed)
	{
		assert(diagnosed_fault == parser::PARSING_FAILED);
	}
	else { assert(false, "a diagnosed type-name probe failure must propagate"); }
	assert(f.parser.tok_i == 3 && f.parser.is_at(tokenizer::TokenId.R_PAREN),
		"a diagnosed probe failure must preserve its consumed cursor");
	assert(has_expression_diagnostic(&f, "diagnosed probe failure"));

	f.free();
	f.init("sizeof(int)\n");
	f.probe_handler.probe = &expression_type_name_probe_fatal_failure;
	parser_result::Result? fatal = f.parser.expr();
	if (catch fatal_fault = fatal)
	{
		assert(fatal_fault == compilation::FATAL_ERROR);
	}
	else { assert(false, "a fatal type-name probe fault must propagate"); }
	assert(f.parser.tok_i == 3 && f.parser.is_at(tokenizer::TokenId.R_PAREN),
		"a fatal probe fault must preserve its consumed cursor");

	f.free();
	f.init("sizeof(int + 1)\n");
	parser_result::Result? malformed_type_operand = f.parser.expr();
	if (catch malformed_type_operand_fault = malformed_type_operand)
	{
		assert(malformed_type_operand_fault == parser::PARSING_FAILED);
	}
	else { assert(false, "a matched type name without its closing parenthesis must fail"); }
	assert(f.parser.tok_i == 3 && f.parser.is_at(tokenizer::TokenId.PLUS),
		"a matched type-name parse must not backtrack into an expression");
	assert(f.diagnostics.messages.len() > 0);
}

fn void parser_owned_unary_folding_respects_eval_suppression() @test
{
	ExpressionFixture f;
	f.init("sizeof(3)\n");
	defer f.free();
	UnaryContext context = { .symbols = &f.parser.symbols };
	parser_result::Result unevaluated_size = f.parser.expr_with_primary(&context, &parse_seeded_unary, false)!!;
	assert(unevaluated_size.node.tag(&f.parser.tree).kind == tree::NodeKind.SIZEOF_EXPR);
	// sizeof computes its result from the checked type even when its enclosing
	// expression suppresses value evaluation.
	assert((ulong)unevaluated_size.val.to_i64(&f.comp)!! == type_store::INT.sizeof_or_null(&f.comp)!!);

	f.free();
	f.init("__imag 7\n");
	context = { .symbols = &f.parser.symbols };
	parser_result::Result suppressed_imaginary_part = f.parser.expr_with_primary(&context, &parse_seeded_unary, false)!!;
	assert(suppressed_imaginary_part.node.tag(&f.parser.tree).kind == tree::NodeKind.IMAG_EXPR);
	assert(suppressed_imaginary_part.val.is_none());
}

fn void parser_owned_primary_decodes_number_types_and_imaginary_literals() @test
{
	// Source-derived: unsuffixed `42` is signed int; `42u` is unsigned int;
	// `1.5f` and `1.5` are float and double; GNU `7i` has integer literal
	// type int in the complex domain.
	ExpressionFixture f;
	f.init("42\n");
	defer f.free();
	parser_result::Result signed_result = f.parser.expr()!!;
	assert(signed_result.node.tag(&f.parser.tree).kind == tree::NodeKind.INT_LITERAL);
	assert(signed_result.qt == type_store::INT);
	assert(signed_result.qt.bit_sizeof(&f.comp) == type_store::INT.bit_sizeof(&f.comp));
	assert(signed_result.qt.signedness(&f.comp) == SIGNED);
	assert(signed_result.val.to_i64(&f.comp)!! == 42);
	assert(f.parser.at_eof());

	f.free();
	f.init("42u\n");
	parser_result::Result unsigned_result = f.parser.expr()!!;
	assert(unsigned_result.node.tag(&f.parser.tree).kind == tree::NodeKind.INT_LITERAL);
	assert(unsigned_result.qt == type_store::UINT);
	assert(unsigned_result.qt.bit_sizeof(&f.comp) == type_store::UINT.bit_sizeof(&f.comp));
	assert(unsigned_result.qt.signedness(&f.comp) == UNSIGNED);
	assert(unsigned_result.val.to_i64(&f.comp)!! == 42);
	assert(f.parser.at_eof());

	// A second independent parser fixture keeps each result tied to one token stream.
	f.free();
	f.init("1.5f\n");
	parser_result::Result float_result = f.parser.expr()!!;
	assert(float_result.node.tag(&f.parser.tree).kind == tree::NodeKind.FLOAT_LITERAL);
	assert(float_result.qt == type_store::FLOAT && float_result.qt.is_float(&f.comp));
	assert(float_result.qt.bit_sizeof(&f.comp) == type_store::FLOAT.bit_sizeof(&f.comp));
	assert(!float_result.val.is_none() && float_result.val.is(value_interner::InternerKeyTag.FLOAT, &f.comp));
	value_interner::InternerKey float_key = f.comp.interner.get(float_result.val.ref());
	assert(float_key.float_val.tag == value_interner::KeyFloatTag.F32);
	assert(float_key.float_val.f32 == 0x3FC00000); // IEEE-754 bits for 1.5f
	assert(f.parser.at_eof());

	f.free();
	f.init("1.5\n");
	parser_result::Result double_result = f.parser.expr()!!;
	assert(double_result.node.tag(&f.parser.tree).kind == tree::NodeKind.FLOAT_LITERAL);
	assert(double_result.qt == type_store::DOUBLE && double_result.qt.is_float(&f.comp));
	assert(double_result.qt.bit_sizeof(&f.comp) == type_store::DOUBLE.bit_sizeof(&f.comp));
	assert(double_result.val.is(value_interner::InternerKeyTag.FLOAT, &f.comp));
	value_interner::InternerKey double_key = f.comp.interner.get(double_result.val.ref());
	assert(double_key.float_val.tag == value_interner::KeyFloatTag.F64);
	assert(double_key.float_val.f64 == 0x3FF8000000000000); // IEEE-754 bits for 1.5
	assert(f.parser.at_eof());

	f.free();
	f.init("7i\n");
	parser_result::Result imaginary = f.parser.expr()!!;
	assert(imaginary.node.tag(&f.parser.tree).kind == tree::NodeKind.IMAGINARY_LITERAL);
	assert(imaginary.qt.is(&f.comp, type_store::TypeTag.COMPLEX));
	assert(imaginary.qt.child_type(&f.comp) == type_store::INT);
	Node imaginary_node = imaginary.node.get(&f.parser.tree);
	assert(imaginary_node.unary.operand.get(&f.parser.tree).literal.qt == type_store::INT);
	assert(imaginary_node.unary.operand.get(&f.parser.tree).literal.literal_tok == 0);
	assert(imaginary.val.is_none());
	assert(f.parser.at_eof());
}

fn void parser_owned_primary_decodes_characters_and_concatenates_strings() @test
{
	// Source-derived: a character constant is an int value; adjacent ordinary
	// string tokens form one array literal including its final NUL byte.
	ExpressionFixture f;
	f.init("'A'\n");
	defer f.free();
	parser_result::Result character = f.parser.expr()!!;
	assert(character.node.tag(&f.parser.tree).kind == tree::NodeKind.CHAR_LITERAL);
	Node character_node = character.node.get(&f.parser.tree);
	assert(character.qt == type_store::INT && character_node.char_literal.kind == tree::CharLiteralKind.ASCII);
	assert(character.val.to_i64(&f.comp)!! == 65);
	assert(f.parser.at_eof());

	f.free();
	f.init("\"ab\" \"cd\"\n");
	parser_result::Result string = f.parser.expr()!!;
	assert(string.node.tag(&f.parser.tree).kind == tree::NodeKind.STRING_LITERAL_EXPR);
	Node string_node = string.node.get(&f.parser.tree);
	assert(string_node.char_literal.kind == tree::CharLiteralKind.ASCII);
	type_store::Type array = string.qt.get_type(&f.comp);
	assert(array.tag == type_store::TypeTag.ARRAY && array.array.len.kind == type_store::ArrayLenKind.FIXED);
	assert(array.array.len.len == 5);
	assert(string.val.to_bytes(&f.comp) == "abcd\0");
	assert(f.parser.tok_i == 2 && f.parser.at_eof());
}

fn void parser_owned_primary_resolves_ordinary_enum_and_typedef_symbols() @test
{
	// Source-derived: ordinary names form declaration references, enumerators
	// form enumeration references with their constant values, and a typedef name
	// is a type rather than an expression.
	ExpressionFixture f;
	f.init("object\n");
	defer f.free();
	NodeIndex object_decl = f.seed_symbol("object", symbol_stack::SymbolKind.DEF, type_store::LONG);
	parser_result::Result object = f.parser.expr()!!;
	assert(object.node.tag(&f.parser.tree).kind == tree::NodeKind.DECL_REF_EXPR);
	assert(object.node.get(&f.parser.tree).decl_ref.decl == object_decl);
	assert(object.qt == type_store::LONG && f.parser.at_eof());

	f.free();
	f.init("answer\n");
	NodeIndex enum_decl = f.seed_symbol("answer", symbol_stack::SymbolKind.ENUMERATION,
		type_store::INT, value::int_i64(19, &f.comp));
	parser_result::Result answer = f.parser.expr()!!;
	assert(answer.node.tag(&f.parser.tree).kind == tree::NodeKind.ENUMERATION_REF);
	assert(answer.node.get(&f.parser.tree).decl_ref.decl == enum_decl);
	assert(answer.val.to_i64(&f.comp)!! == 19 && f.parser.at_eof());

	f.free();
	f.init("Alias\n");
	f.seed_symbol("Alias", symbol_stack::SymbolKind.TYPEDEF, type_store::LONG);
	parser_result::Result? typedef_expression = f.parser.expr();
	if (catch typedef_expression) {}
	else { assert(false, "a typedef name cannot be parsed as an expression"); }
	assert(has_expression_diagnostic(&f, "unexpected type name 'Alias': expected expression"));
	assert(f.parser.at_eof());
}

fn void parser_owned_primary_reports_unknown_names_and_expanded_macro_locations() @test
{
	// Source-derived: an undeclared identifier is diagnosed at its use site;
	// macro-expanded tokens carry an expansion location back to the invocation.
	ExpressionFixture f;
	f.init("missing_name\n");
	defer f.free();
	parser_result::Result? missing = f.parser.expr();
	if (catch missing) {}
	else { assert(false, "an unknown identifier must fail primary-expression parsing"); }
	assert(has_expression_diagnostic(&f, "use of undeclared identifier 'missing_name'"));
	assert(f.parser.tok_i == 0);

	f.free();
	f.init("#define BAD_NAME absent_name\nBAD_NAME\n", "macro_expr.c");
	parser_result::Result? expanded = f.parser.expr();
	if (catch expanded) {}
	else { assert(false, "an unknown identifier produced by a macro must still fail"); }
	assert(has_expression_diagnostic(&f, "use of undeclared identifier 'absent_name'"));
	assert(f.diagnostics.messages.len() > 0);
	assert(f.diagnostics.messages[0].has_location);
	assert(f.diagnostics.messages[0].location.path == "macro_expr.c");
	assert(f.diagnostics.messages[0].location.line_no == 2);
}

fn void parser_owned_grouping_and_cast_disambiguation_preserve_cursor() @test
{
	// Source-derived: `(object)` groups when the type-name probe explicitly
	// reports no match; `(Alias) 3` commits to a cast and consumes its operand.
	ExpressionFixture f;
	f.init("(object)\n");
	defer f.free();
	NodeIndex object_decl = f.seed_symbol("object", symbol_stack::SymbolKind.DEF, type_store::INT);
	f.parser.advance();
	parser::TypeNameProbe no_type = f.parser.probe_typed_type_name()!!;
	assert(!no_type.matched && f.parser.tok_i == 1);
	assert(f.diagnostics.messages.len() == 0, "a speculative type-name miss must not diagnose");
	f.parser.tok_i = 0;
	parser_result::Result grouped = f.parser.expr()!!;
	assert(grouped.node.tag(&f.parser.tree).kind == tree::NodeKind.PAREN_EXPR);
	assert(grouped.node.get(&f.parser.tree).unary.operand.get(&f.parser.tree).decl_ref.decl == object_decl);
	assert(f.parser.tok_i + 1 == f.parser.tok_end && f.parser.at_eof());

	f.free();
	f.init("(Alias) 3\n");
	f.seed_symbol("Alias", symbol_stack::SymbolKind.TYPEDEF, type_store::LONG);
	parser_result::Result cast = f.parser.expr()!!;
	assert(cast.node.tag(&f.parser.tree).kind == tree::NodeKind.CAST);
	Node cast_node = cast.node.get(&f.parser.tree);
	assert(cast_node.cast.qt == type_store::LONG && !cast_node.cast.implicit);
	assert(cast.qt == type_store::LONG && cast.val.to_i64(&f.comp)!! == 3);
	assert(f.parser.tok_i + 1 == f.parser.tok_end && f.parser.at_eof());

	f.free();
	f.init("(int)\n");
	parser_result::Result? missing_cast_operand = f.parser.expr();
	if (catch missing_cast_operand) {}
	else { assert(false, "a matched type name must require a cast operand"); }
	assert(f.parser.at_eof());

	f.free();
	f.init("(float) object\n");
	type_store::QualType int_pointer = f.comp.type_store.put(type_store::type_pointer(type_store::INT));
	f.seed_symbol("object", symbol_stack::SymbolKind.DEF, int_pointer);
	parser_result::Result? rejected_cast = f.parser.expr();
	if (catch rejected_cast) {}
	else { assert(false, "a pointer-to-float cast must be rejected"); }
	assert(has_expression_diagnostic(&f, "pointer cannot be cast to type float"));
}

fn void parser_owned_generic_selects_typed_and_default_associations() @test
{
	// Source-derived: _Generic selects the first compatible association, or
	// reparses the default arm when no typed association matches.
	ExpressionFixture f;
	f.init("_Generic(1, int: 11, default: 22)\n");
	defer f.free();
	parser_result::Result typed = f.parser.expr()!!;
	assert(typed.node.tag(&f.parser.tree).kind == tree::NodeKind.GENERIC_EXPR);
	Node typed_node = typed.node.get(&f.parser.tree);
	assert(typed_node.generic.chosen.get(&f.parser.tree).kind == tree::NodeKind.GENERIC_ASSOCIATION_EXPR);
	assert(typed_node.generic.rest.len == 1);
	assert(typed.val.to_i64(&f.comp)!! == 11 && f.parser.at_eof());

	f.free();
	f.init("_Generic(1L, int: 11, default: 22)\n");
	parser_result::Result fallback = f.parser.expr()!!;
	Node fallback_node = fallback.node.get(&f.parser.tree);
	assert(fallback.node.tag(&f.parser.tree).kind == tree::NodeKind.GENERIC_EXPR);
	assert(fallback_node.generic.chosen.get(&f.parser.tree).kind == tree::NodeKind.GENERIC_DEFAULT_EXPR);
	assert(fallback.val.to_i64(&f.comp)!! == 22 && f.parser.at_eof());
}

fn void parser_owned_generic_diagnoses_duplicates_and_rejects_bad_unselected_arms() @test
{
	// Source-derived: duplicate compatible type associations are diagnosed;
	// every arm is parsed even when its type is not selected.
	ExpressionFixture f;
	f.init("_Generic(1, int: 11, int: 12)\n");
	defer f.free();
	parser_result::Result duplicate = f.parser.expr()!!;
	assert(duplicate.node.tag(&f.parser.tree).kind == tree::NodeKind.GENERIC_EXPR);
	assert(has_expression_diagnostic(&f, "type int in generic association compatible with previously specified type"));
	assert(has_expression_diagnostic(&f, "compatible type int specified here"));
	assert(duplicate.val.to_i64(&f.comp)!! == 11);

	f.free();
	f.init("_Generic(1, int: 11, default: (2 +))\n");
	parser_result::Result? rejected_arm = f.parser.expr();
	if (catch rejected_arm) {}
	else { assert(false, "an unselected generic arm with malformed syntax must be rejected"); }
	assert(f.diagnostics.errors > 0);

	f.free();
	f.init("_Generic(1L, default: 22, default: 33)\n");
	parser_result::Result duplicate_default = f.parser.expr()!!;
	assert(duplicate_default.val.to_i64(&f.comp)!! == 22);
	assert(has_expression_diagnostic(&f, "duplicate default generic association"));
}

fn void parser_owned_generic_missing_association_reports_expected_type() @test
{
	// Source-derived: Parser.zig reports "expected a type" when _Generic has no
	// association after the controlling comma, and the parse fails.
	ExpressionFixture f;
	f.init("_Generic(1,)\n");
	defer f.free();
	parser_result::Result? missing = f.parser.expr();
	if (catch missing) {}
	else { assert(false, "a _Generic with no association must fail to parse"); }
	assert(has_expression_diagnostic(&f, "expected a type"));
}

fn void parser_owned_unavailable_statement_and_specialized_builtin_forms_fail() @test
{
	// Source-derived: statement expressions and specialized builtin primaries
	// are explicit unavailable productions in this parser composition.
	ExpressionFixture f;
	f.init("({ 1; })\n");
	defer f.free();
	parser_result::Result? statement_expr = f.parser.expr();
	if (catch statement_expr) {}
	else { assert(false, "statement-expression primary should report unavailable"); }
	assert(has_expression_diagnostic(&f, "statement expressions are unavailable in this parser composition"));

	f.free();
	f.init("__builtin_choose_expr(1, 2, 3)\n");
	parser_result::Result builtin = f.parser.expr()!!;
	tree::Node builtin_call = builtin.node.get(&f.parser.tree);
	assert(builtin_call.kind == tree::NodeKind.CALL_EXPR);
	assert(call_callee_reference(&f.parser.tree, builtin_call.call.callee).kind == tree::NodeKind.BUILTIN_REF);
	assert(!has_expression_diagnostic(&f, "specialized builtin primary expressions are unavailable"));
	assert(f.parser.at_eof());

	f.free();
	f.init("(int){ 1 }\n");
	parser_result::Result? compound_literal = f.parser.expr();
	if (catch compound_literal) {}
	else { assert(false, "unbound typed compound-literal seam should report unavailable"); }
	assert(has_expression_diagnostic(&f, "compound literal expressions are unavailable in this parser composition"));
	assert(f.parser.tree.tokens[(usz)f.parser.tok_i].id == tokenizer::TokenId.L_BRACE);
}

fn void parser_owned_constexpr_references_respect_symbol_kind_and_restore_folding_mode() @test
{
	// Source-derived: only CONSTEXPR symbols participate in const-declaration
	// folding, and const_expr restores its caller's mode after each entry.
	ExpressionFixture f;
	f.init("ordinary\n");
	defer f.free();
	f.seed_symbol("ordinary", symbol_stack::SymbolKind.DEF, type_store::INT,
		value::int_i64(41, &f.comp));
	f.parser.const_decl_folding = parser::ConstDeclFoldingMode.GNU_FOLDING_EXTENSION;
	parser_result::Result ordinary = f.parser.const_expr(true,
		parser::ConstDeclFoldingMode.FOLD_CONST_DECLS)!!;
	assert(ordinary.val.is_none(), "a variable's stored value must not make its reference fold");
	assert(f.parser.const_decl_folding == parser::ConstDeclFoldingMode.GNU_FOLDING_EXTENSION);

	f.free();
	f.init("answer\n");
	f.seed_symbol("answer", symbol_stack::SymbolKind.CONSTEXPR, type_store::INT,
		value::int_i64(42, &f.comp));
	f.parser.const_decl_folding = parser::ConstDeclFoldingMode.NO_CONST_DECL_FOLDING;
	parser_result::Result constant = f.parser.const_expr(true,
		parser::ConstDeclFoldingMode.FOLD_CONST_DECLS)!!;
	assert(constant.val.to_i64(&f.comp)!! == 42);
	assert(f.parser.const_decl_folding == parser::ConstDeclFoldingMode.NO_CONST_DECL_FOLDING);

	f.free();
	f.init("answer\n");
	f.seed_symbol("answer", symbol_stack::SymbolKind.CONSTEXPR, type_store::INT,
		value::int_i64(42, &f.comp));
	parser_result::Result suppressed = f.parser.const_expr(true,
		parser::ConstDeclFoldingMode.NO_CONST_DECL_FOLDING)!!;
	assert(suppressed.val.is_none());
	assert(f.parser.const_decl_folding == parser::ConstDeclFoldingMode.FOLD_CONST_DECLS);
}

// Call-site cases below use ExpressionFixture, which composes the real primary
// and postfix parsers. Its ProbeHandler leaves the builtin-call hook unset, so
// the callee observed here is the node the primary parser produced.

fn tree::Node call_callee_reference(tree::Tree* tree, type_store::NodeIndex callee)
{
	tree::Node node = callee.get(tree);
	while (node.kind == tree::NodeKind.CAST && node.cast.implicit)
	{
		node = node.cast.operand.get(tree);
	}
	return node;
}

fn void unknown_builtin_identifier_call_reaches_builtin_ref_callee() @test
{
	// `__builtin_unreachable` is not one of the specialized builtin primaries;
	// as an ordinary builtin name used as a call, its callee must be BUILTIN_REF.
	ExpressionFixture f;
	f.init("__builtin_unreachable()\n", "builtin_call.c", lang_opts::Standard.C17);
	defer f.free();
	parser_result::Result call = f.parser.expr()!!;
	Node call_node = call.node.get(&f.parser.tree);
	assert(call_node.kind == tree::NodeKind.CALL_EXPR);
	assert(call_callee_reference(&f.parser.tree, call_node.call.callee).kind == tree::NodeKind.BUILTIN_REF,
		"an unknown builtin identifier used as a call must reach a BUILTIN_REF callee");
	assert(f.parser.at_eof());
	assert(f.diagnostics.messages.len() == 0, "a builtin call with a known name must not diagnose");
}

fn void library_builtin_call_reaches_builtin_ref_callee_with_implicit_declaration() @test
{
	// `printf` is a library name in the builtin table with no visible declaration:
	// the callee is BUILTIN_REF and the implicit library declaration is diagnosed.
	ExpressionFixture f;
	f.init("printf(\"x\")\n", "builtin_call.c", lang_opts::Standard.C17);
	defer f.free();
	parser_result::Result call = f.parser.expr()!!;
	Node call_node = call.node.get(&f.parser.tree);
	assert(call_node.kind == tree::NodeKind.CALL_EXPR);
	assert(call_callee_reference(&f.parser.tree, call_node.call.callee).kind == tree::NodeKind.BUILTIN_REF,
		"a library builtin name used as a call must reach a BUILTIN_REF callee");
	assert(has_expression_diagnostic(&f, "implicitly declaring library function 'printf'"),
		"a library builtin without a declaration must diagnose the implicit declaration");
}

fn void undeclared_call_is_implicit_declaration_under_c17() @test
{
	// Before C23, an identifier followed by '(' is an implicitly declared function:
	// the call still parses, and the implicit-declaration error is reported.
	ExpressionFixture f;
	f.init("missing_fn(1)\n", "implicit_call.c", lang_opts::Standard.C17);
	defer f.free();
	parser_result::Result call = f.parser.expr()!!;
	Node call_node = call.node.get(&f.parser.tree);
	assert(call_node.kind == tree::NodeKind.CALL_EXPR);
	assert(call_callee_reference(&f.parser.tree, call_node.call.callee).kind == tree::NodeKind.DECL_REF_EXPR,
		"an implicitly declared function must be referenced through a declaration");
	assert(f.parser.at_eof());
	assert(has_expression_diagnostic(&f,
		"call to undeclared function 'missing_fn'; ISO C99 and later do not support implicit function declarations"),
		"C17 must diagnose the implicit function declaration");
}

fn void undeclared_call_fails_as_undeclared_under_c23() @test
{
	// From C23 on there is no implicit function declaration: the same call fails
	// as an undeclared identifier at the use site.
	ExpressionFixture f;
	f.init("missing_fn(1)\n", "implicit_call.c", lang_opts::Standard.C23);
	defer f.free();
	parser_result::Result? maybe_call = f.parser.expr();
	if (catch maybe_call) {}
	else { assert(false, "an undeclared call must fail to parse under C23"); }
	assert(f.parser.tok_i == 0);
	assert(has_expression_diagnostic(&f, "use of undeclared identifier 'missing_fn'"));
	assert(!has_expression_diagnostic(&f,
		"call to undeclared function 'missing_fn'; ISO C99 and later do not support implicit function declarations"),
		"C23 must not take the implicit function declaration path");
}

<* True when the translation unit retains a function definition, with a body,
   named `name`. Prototypes share NodeKind.FUNCTION and are skipped. *>
fn bool has_function_definition(tree::Tree* result, String name)
{
	foreach (root : result.root_decls)
	{
		Node node = root.get(result);
		if (node.kind != tree::NodeKind.FUNCTION || node.function.body.is_null()) continue;
		if (result.tok_slice(node.function.name_tok) == name) return true;
	}
	return false;
}

fn void predefined_func_identifier_is_valid_inside_function() @test
{
	// `__func__` inside a function body must parse without diagnostics. This
	// needs a function body, so it uses the production FrontendHandler composition.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("predefined_inside.c",
			"int f(void) { const char *name = __func__; return 0; }\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser::Parser p;
		p.init(&pp);
		parser_frontend::FrontendHandler frontend;
		frontend.bind(&p);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 0, "__func__ inside a function must not diagnose");
		assert(has_function_definition(&result, "f"), "the function containing __func__ must be retained");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void predefined_func_identifier_warns_at_file_scope() @test
{
	// Outside any function `__func__` has no enclosing name; it is still accepted
	// but reports a single predefined-identifier warning.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("predefined_top_level.c",
			"const char *name = __func__;\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser::Parser p;
		p.init(&pp);
		parser_frontend::FrontendHandler frontend;
		frontend.bind(&p);
		tree::Tree result = p.parse()!!;

		usz warning_count = 0;
		foreach (message : d.messages)
		{
			if (message.kind == diagnostics::MessageKind.WARNING) warning_count++;
		}
		assert(warning_count == 1, "expected one file-scope predefined identifier warning, got %d", warning_count);
		assert(d.messages[0].kind == diagnostics::MessageKind.WARNING);
		assert(d.messages[0].text == "predefined identifier is only valid inside function");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}
