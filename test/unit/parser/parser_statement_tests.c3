// Direct tests for the bounded statement and GNU asm parser APIs. Expression
// and asm-string callbacks below intentionally provide only fixture behavior.
// Declaration-form for initializers remains callback supplied by the owner.
module parser_statement_tests;
import aro::attribute, aro::attribute_map, aro::compilation, aro::diagnostics, aro::parser, aro::parser_asm, aro::parser_expression, aro::parser_primary;
import aro::parser_declaration, aro::parser_frontend, aro::parser_postfix, aro::parser_result, aro::parser_statement, aro::preprocessor, aro::source, aro::tokenizer, aro::tokens, aro::tree;
import aro::type_store, aro::value;
import aro::parser_builtin, aro::parser_declarator, aro::text_literal;
import aro::pragma;
import std::core::mem::allocators, std::core::mem;

fn parser_result::Result? fixture_expression(void* context, parser::Parser* p, bool eval)
{
	if (p.at_eof() || p.is_at(tokenizer::TokenId.SEMICOLON) || p.is_at(tokenizer::TokenId.R_PAREN) ||
		p.is_at(tokenizer::TokenId.COLON) || p.is_at(tokenizer::TokenId.R_BRACE)) return parser_expression::NO_EXPRESSION~;
	if (!p.is_at(tokenizer::TokenId.PP_NUM)) return parser_expression::NO_EXPRESSION~;
	tokens::TokenIndex tok = p.tok_i;
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
		.literal = { .literal_tok = tok, .qt = type_store::INT } });
	p.advance();
	parser_result::Result result;
	result.init(node, type_store::INT, eval ? value::int_i64(1, p.comp) : value::NONE);
	return result;
}

struct RecoveryExpressionFixture { bool fail_next; }

fn parser_result::Result? fixture_recovery_expression(void* context, parser::Parser* p, bool eval)
{
	RecoveryExpressionFixture* fixture = (RecoveryExpressionFixture*)context;
	if (fixture.fail_next)
	{
		fixture.fail_next = false;
		return parser_statement::PARSING_FAILED~;
	}
	return fixture_expression(null, p, eval);
}

fn parser_result::Result? fixture_advance_then_fail_expression(void* context, parser::Parser* p, bool eval)
{
	RecoveryExpressionFixture* fixture = (RecoveryExpressionFixture*)context;
	if (fixture.fail_next)
	{
		fixture.fail_next = false;
		p.advance();
		return parser_statement::PARSING_FAILED~;
	}
	return fixture_expression(null, p, eval);
}

fn type_store::NodeIndex? fixture_failed_local_declaration(void* context, parser::Parser* p)
{
	if (!p.is_at(tokenizer::TokenId.KEYWORD_INT)) return tree::NULL_NODE~;
	while (!p.at_eof() && !p.is_at(tokenizer::TokenId.SEMICOLON)) p.advance();
	if (!p.at_eof()) p.advance();
	assert(p.is_at(tokenizer::TokenId.KEYWORD_RETURN), "failed declaration should leave the next statement at the cursor");
	return parser_statement::PARSING_FAILED~;
}

fn parser_result::Result? fixture_fail_identifier_expression(void* context, parser::Parser* p, bool eval)
{
	if (p.is_at(tokenizer::TokenId.IDENTIFIER))
	{
		p.advance();
		return parser_statement::PARSING_FAILED~;
	}
	return fixture_expression(null, p, eval);
}

fn type_store::NodeIndex? fixture_failed_declaration_through_semicolon(void* context, parser::Parser* p)
{
	if (!p.is_at(tokenizer::TokenId.KEYWORD_INT)) return tree::NULL_NODE~;
	while (!p.at_eof() && !p.is_at(tokenizer::TokenId.SEMICOLON)) p.advance();
	if (!p.at_eof()) p.advance();
	return parser_statement::PARSING_FAILED~;
}

fn parser_result::Result? fixture_switch_expression_impl(void* context, parser::Parser* p, bool eval, bool unavailable_cases)
{
	if (p.at_eof() || p.is_at(tokenizer::TokenId.SEMICOLON) || p.is_at(tokenizer::TokenId.R_PAREN) ||
		p.is_at(tokenizer::TokenId.COLON) || p.is_at(tokenizer::TokenId.R_BRACE)) return parser_expression::NO_EXPRESSION~;
	if (!p.is_at(tokenizer::TokenId.PP_NUM)) return parser_expression::NO_EXPRESSION~;
	tokens::TokenIndex tok = p.tok_i;
	String spelling = p.tree.tok_slice(tok);
	long parsed_value = spelling == "0" ? 0 : spelling == "1" ? 1 : spelling == "2" ? 2 :
		spelling == "3" ? 3 : spelling == "4" ? 4 : spelling == "5" ? 5 : 8;
	bool unavailable = unavailable_cases && (spelling == "2" || spelling == "3");
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
		.literal = { .literal_tok = tok, .qt = type_store::INT } });
	p.advance();
	parser_result::Result result;
	result.init(node, type_store::INT, eval && !unavailable ? value::int_i64(parsed_value, p.comp) : value::NONE);
	return result;
}

fn parser_result::Result? fixture_switch_expression(void* context, parser::Parser* p, bool eval)
{
	return fixture_switch_expression_impl(context, p, eval, false);
}

fn parser_result::Result? fixture_switch_integer_constant_expression(void* context, parser::Parser* p, parser::ConstDeclFoldingMode mode, bool eval)
{
	return p.integer_const_expr_with_primary(context, &fixture_switch_expression, eval, mode);
}

fn parser_result::Result? fixture_switch_expression_with_unavailable_values(void* context, parser::Parser* p, bool eval)
{
	return fixture_switch_expression_impl(context, p, eval, true);
}

fn parser_result::Result? fixture_unavailable_switch_integer_constant_expression(void* context, parser::Parser* p, parser::ConstDeclFoldingMode mode, bool eval)
{
	return p.integer_const_expr_with_primary(context, &fixture_switch_expression_with_unavailable_values, eval, mode);
}

fn parser_result::Result? fixture_full_expression(void* context, parser::Parser* p, bool eval)
{
	return p.expr_with_primary(context, &fixture_expression, eval);
}

fn parser_result::Result? fixture_postfix_expression(void* context, parser::Parser* p, tokens::Precedence min_prec, bool eval)
{
	return p.expr_with_primary(context, &fixture_expression, eval);
}

fn parser_result::Result? fixture_postfix_primary(void* context, parser::Parser* p, bool eval)
{
	return parser_postfix::PARSING_FAILED~;
}

fn parser_postfix::StatementExpressionBodyResult? fixture_statement_expression_body(void* context, parser::Parser* p, bool eval)
{
	parser_statement::StatementParser* statements = (parser_statement::StatementParser*)context;
	statements.parser = p;
	type_store::NodeIndex? maybe_body = statements.parse_body(false);
	if (catch maybe_body) return parser_postfix::PARSING_FAILED~;
	type_store::NodeIndex body = maybe_body;
	tree::NodeCompoundStmt compound = body.get(&p.tree).compound_stmt;
	type_store::QualType qt = type_store::VOID;
	if (compound.body.len > 0)
	{
		type_store::NodeIndex last = compound.body[compound.body.len - 1];
		tree::Node last_node = last.get(&p.tree);
		if (last_node.kind.family == tree::NodeFamily.EXPR) qt = last.qt(&p.tree);
	}
	return { .body = body, .qt = qt };
}

fn type_store::NodeIndex? fixture_asm_string(void* context, parser::Parser* p)
{
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.STRING_LITERAL_EXPR,
		.char_literal = { .literal_tok = p.tok_i, .qt = type_store::INVALID, .kind = tree::CharLiteralKind.ASCII } });
	p.advance();
	return node;
}

fn void statement_compounds_unwind_scopes_and_parse_control_flow() @test
{
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
		source::Source src = comp.add_source_from_buffer("statement.c", "{ ; { return; } if (1) while (1) break; else continue; do ; while (1); for (;;1) return 1; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p;
		p.init(&pp);
		p.bind_finalized_tokens();
		uint original_scopes = (uint)p.symbols.active_len;
		StatementGrammar statements_grammar = { .expr = &fixture_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		type_store::NodeIndex body = statements.parse_body()!!;
		assert(body.kind(&p.tree) == tree::NodeKind.COMPOUND_STMT);
		assert(p.symbols.active_len == original_scopes, "compound scope must be popped after parsing");
		assert(p.at_eof());
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void compound_scope_unwinds_on_parse_error() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("statement.c", "{ if (1) }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		uint original_scopes = (uint)p.symbols.active_len;
		StatementGrammar statements_grammar = { .expr = &fixture_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		statements.parse_body()!!;
		assert(p.symbols.active_len == original_scopes);
		assert(p.at_eof(), "recovery must consume the unmatched block closing brace");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void compound_body_recovers_after_failed_statement() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("statement-recovery.c", "{ 1; 2; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		uint original_scopes = (uint)p.symbols.active_len;
		RecoveryExpressionFixture fixture = { .fail_next = true };
		StatementGrammar statements_grammar = { .context = &fixture, .expr = &fixture_recovery_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		type_store::NodeIndex body = statements.parse_body()!!;
		tree::Node parsed_body = body.get(&p.tree);
		assert(parsed_body.kind == tree::NodeKind.COMPOUND_STMT);
		assert(parsed_body.compound_stmt.body.len == 1, "the failed statement must be skipped");
		tree::Node recovered = parsed_body.compound_stmt.body[0].get(&p.tree);
		assert(recovered.kind == tree::NodeKind.INT_LITERAL);
		assert(p.tree.tok_slice(recovered.literal.literal_tok) == "2", "the later statement must be retained");
		assert(!fixture.fail_next, "the fixture must fail exactly one expression");
		assert(p.symbols.active_len == original_scopes, "compound scope must be popped after recovery");
		assert(p.at_eof(), "recovery must leave the compound closing brace for parse_body");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void compound_body_keeps_next_statement_after_advanced_failure() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("statement-recovery.c", "{ int broken; return 2; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		StatementGrammar statements_grammar = { .local = &fixture_failed_local_declaration, .expr = &fixture_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		type_store::NodeIndex body = statements.parse_body()!!;
		tree::Node parsed_body = body.get(&p.tree);
		assert(parsed_body.kind == tree::NodeKind.COMPOUND_STMT);
		assert(parsed_body.compound_stmt.body.len == 1, "the failed declaration must be skipped");
		tree::Node recovered = parsed_body.compound_stmt.body[0].get(&p.tree);
		assert(recovered.kind == tree::NodeKind.RETURN_STMT, "the next statement must be retained");
		assert(p.at_eof(), "recovery must leave the compound closing brace for parse_body");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void compound_body_recovers_two_failed_statements_in_one_body() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("statement-recovery.c", "{ bad; 1; bad; 2; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		uint original_scopes = (uint)p.symbols.active_len;
		StatementGrammar statements_grammar = { .expr = &fixture_fail_identifier_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		type_store::NodeIndex body = statements.parse_body()!!;
		tree::NodeCompoundStmt compound = body.get(&p.tree).compound_stmt;
		assert(compound.body.len == 2, "both statements after the two failed items must be retained");
		tree::Node first = compound.body[0].get(&p.tree);
		tree::Node second = compound.body[1].get(&p.tree);
		assert(first.kind == tree::NodeKind.INT_LITERAL);
		assert(p.tree.tok_slice(first.literal.literal_tok) == "1");
		assert(second.kind == tree::NodeKind.INT_LITERAL);
		assert(p.tree.tok_slice(second.literal.literal_tok) == "2");
		usz expected_stmt_diagnostics = 0;
		foreach (message : d.messages)
		{
			if (message.text == "expected statement") expected_stmt_diagnostics++;
		}
		assert(expected_stmt_diagnostics == 2, "each failed item must diagnose exactly once");
		assert(p.symbols.active_len == original_scopes, "compound scope must be popped after recovery");
		assert(p.at_eof(), "recovery must leave the compound closing brace for parse_body");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void compound_body_keeps_statement_after_declaration_consumed_its_semicolon() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("statement-recovery.c", "{ int broken; 2; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		StatementGrammar statements_grammar = { .local = &fixture_failed_declaration_through_semicolon, .expr = &fixture_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		type_store::NodeIndex body = statements.parse_body()!!;
		tree::NodeCompoundStmt compound = body.get(&p.tree).compound_stmt;
		assert(compound.body.len == 1, "the failed declaration must be skipped");
		tree::Node recovered = compound.body[0].get(&p.tree);
		assert(recovered.kind == tree::NodeKind.INT_LITERAL, "a non-keyword statement after the consumed ';' must be retained");
		assert(p.tree.tok_slice(recovered.literal.literal_tok) == "2");
		assert(p.at_eof(), "recovery must leave the compound closing brace for parse_body");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void compound_item_recovery_fault_predicate_covers_all_parse_failures() @test
{
	assert(parser_statement::recoverable_statement_item_fault(parser::PARSING_FAILED));
	assert(parser_statement::recoverable_statement_item_fault(parser_asm::PARSING_FAILED));
	assert(parser_statement::recoverable_statement_item_fault(parser_builtin::PARSING_FAILED));
	assert(parser_statement::recoverable_statement_item_fault(parser_declaration::PARSING_FAILED));
	assert(parser_statement::recoverable_statement_item_fault(parser_declarator::PARSING_FAILED));
	assert(parser_statement::recoverable_statement_item_fault(parser_expression::PARSING_FAILED));
	assert(parser_statement::recoverable_statement_item_fault(parser_postfix::PARSING_FAILED));
	assert(parser_statement::recoverable_statement_item_fault(parser_primary::PARSING_FAILED));
	assert(parser_statement::recoverable_statement_item_fault(parser_statement::PARSING_FAILED));
	assert(parser_statement::recoverable_statement_item_fault(text_literal::PARSING_FAILED));
	assert(parser_statement::recoverable_statement_item_fault(parser_expression::NO_EXPRESSION));
	assert(!parser_statement::recoverable_statement_item_fault(compilation::FATAL_ERROR));
	assert(!parser_statement::recoverable_statement_item_fault(mem::OUT_OF_MEMORY));
	assert(!parser_statement::recoverable_statement_item_fault(parser::HOOK_ABSENT));
}

fn void compound_body_recovery_tracks_delimiter_kinds_independently() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("statement-recovery.c", "{ broken [ 0 } ; return 1; ] ; return 2; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		RecoveryExpressionFixture fixture = { .fail_next = true };
		StatementGrammar statements_grammar = { .context = &fixture, .expr = &fixture_advance_then_fail_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		type_store::NodeIndex body = statements.parse_body()!!;
		tree::NodeCompoundStmt parsed_body = body.get(&p.tree).compound_stmt;
		assert(parsed_body.body.len == 1, "a ')' must not close the unmatched '[' nesting depth");
		assert(parsed_body.body[0].get(&p.tree).kind == tree::NodeKind.RETURN_STMT);
		tree::Node recovered_return = parsed_body.body[0].get(&p.tree);
		assert(p.tree.tok_slice(recovered_return.return_stmt.expr.get(&p.tree).literal.literal_tok) == "2");
		assert(p.at_eof());
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void compound_body_recovery_consumes_unmatched_closing_brace() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("statement-recovery.c", "{ broken } 2;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		RecoveryExpressionFixture fixture = { .fail_next = true };
		StatementGrammar statements_grammar = { .context = &fixture, .expr = &fixture_advance_then_fail_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		type_store::NodeIndex body = statements.parse_body()!!;
		assert(body.get(&p.tree).compound_stmt.body.len == 0);
		assert(p.is_at(tokenizer::TokenId.PP_NUM), "tokens after the consumed block must remain for the enclosing parser");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void gnu_asm_basic_statement_and_qualifiers_parse() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("asm.c", "__asm__ volatile inline (\"nop\");")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		parser_asm::AsmParser asm_parser = { .asm_string = &fixture_asm_string };
		StatementGrammar statements_grammar = { .expr = &fixture_expression };
		parser_statement::StatementParser statements = { .parser = &p, .asm_parser = &asm_parser, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		type_store::NodeIndex node = statements.parse_statement()!!;
		assert(node.kind(&p.tree) == tree::NodeKind.ASM_STMT);
		assert(p.at_eof());
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void gnu_asm_requires_string_and_trailing_semicolon() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("asm.c", "asm(1)")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		parser_asm::AsmParser asm_parser = { .asm_string = &fixture_asm_string };
		assert(@catch(asm_parser.parse_asm_statement(&p)) == parser::PARSING_FAILED);
		assert(d.messages.len() > 0);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void installed_asm_parser_falls_through_for_non_asm_statements() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("asm.c", "; {} asm(\"nop\");")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		parser_asm::AsmParser asm_parser = { .asm_string = &fixture_asm_string };
		StatementGrammar statements_grammar = { .expr = &fixture_expression };
		parser_statement::StatementParser statements = { .parser = &p, .asm_parser = &asm_parser, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		assert(statements.parse_statement()!!.kind(&p.tree) == tree::NodeKind.NULL_STMT);
		assert(statements.parse_statement()!!.kind(&p.tree) == tree::NodeKind.COMPOUND_STMT);
		assert(statements.parse_statement()!!.kind(&p.tree) == tree::NodeKind.ASM_STMT);
		assert(p.at_eof());
		assert(d.messages.len() == 0);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void return_statements_preserve_value_and_void_operand_shapes() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("return.c", "{ return 1; return; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		StatementGrammar statements_grammar = { .expr = &fixture_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		type_store::NodeIndex body = statements.parse_body()!!;
		tree::NodeCompoundStmt compound = body.get(&p.tree).compound_stmt;
		assert(compound.body.len == 2);
		tree::Node first = compound.body[0].get(&p.tree);
		tree::Node second = compound.body[1].get(&p.tree);
		assert(first.kind == tree::NodeKind.RETURN_STMT);
		assert(first.return_stmt.operand == tree::ReturnOperandKind.EXPR);
		assert(first.return_stmt.return_qt.is_invalid());
		assert(first.return_stmt.expr.kind(&p.tree) == tree::NodeKind.INT_LITERAL);
		assert(first.return_stmt.expr.qt(&p.tree).eql(type_store::INT, &comp));
		assert(second.kind == tree::NodeKind.RETURN_STMT);
		assert(second.return_stmt.operand == tree::ReturnOperandKind.NONE);
		assert(p.at_eof());
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn parser_result::Result? fixture_pointer_expression(void* context, parser::Parser* p, bool eval)
{
	if (p.at_eof() || p.is_at(tokenizer::TokenId.SEMICOLON) || p.is_at(tokenizer::TokenId.R_PAREN) ||
		p.is_at(tokenizer::TokenId.COLON) || p.is_at(tokenizer::TokenId.R_BRACE)) return parser_expression::NO_EXPRESSION~;
	if (!p.is_at(tokenizer::TokenId.PP_NUM)) return parser_expression::NO_EXPRESSION~;
	tokens::TokenIndex tok = p.tok_i;
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
		.literal = { .literal_tok = tok, .qt = type_store::VOID_POINTER } });
	p.advance();
	parser_result::Result result;
	result.init(node, type_store::VOID_POINTER, value::NONE);
	return result;
}

fn parser_result::Result? fixture_pointer_integer_constant_expression(void* context, parser::Parser* p, parser::ConstDeclFoldingMode mode, bool eval)
{
	return p.integer_const_expr_with_primary(context, &fixture_pointer_expression, eval, mode);
}

fn void function_return_context_types_and_validates_returns() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("return.c", "foo { return 1; return; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		tokens::TokenIndex function_name = p.tok_i;
		p.advance();
		StatementGrammar statements_grammar = { .expr = &fixture_expression };
		parser_statement::StatementParser statements = { .parser = &p, .function_return_qt = type_store::INT, .function_name_tok = function_name, .has_function_context = true, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		type_store::NodeIndex body = statements.parse_body(true)!!;
		tree::NodeCompoundStmt compound = body.get(&p.tree).compound_stmt;
		assert(compound.body.len == 2);
		tree::Node returned = compound.body[0].get(&p.tree);
		assert(returned.return_stmt.return_qt.eql(type_store::INT, &comp));
		assert(returned.return_stmt.expr.qt(&p.tree).eql(type_store::INT, &comp));
		// Zig returnStmt emits func_should_return for the bare `return;`; Zig compoundStmt then
		// emits unreachable_code at the second return, which follows the noreturn `return 1;`.
		assert(d.messages.len() == 2);
		test::eq(d.messages[0].text, "non-void function 'foo' should return a value");
		test::eq(d.messages[1].text, "unreachable code");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void pointer_to_integer_return_uses_conversion_diagnostic() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("return.c", "foo { return 1; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		tokens::TokenIndex function_name = p.tok_i; p.advance();
		StatementGrammar statements_grammar = { .expr = &fixture_pointer_expression };
		parser_statement::StatementParser statements = { .parser = &p, .function_return_qt = type_store::INT, .function_name_tok = function_name, .has_function_context = true, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		type_store::NodeIndex body = statements.parse_body(true)!!;
		tree::NodeCompoundStmt compound = body.get(&p.tree).compound_stmt;
		tree::Node returned = compound.body[0].get(&p.tree);
		assert(returned.return_stmt.return_qt.eql(type_store::INT, &comp));
		assert(d.messages.len() == 1);
		test::eq(d.messages[0].text, "implicit pointer to integer conversion from 'void *' to 'int'");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void void_function_returning_value_is_diagnosed() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("return.c", "foo { return 1; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		tokens::TokenIndex function_name = p.tok_i; p.advance();
		StatementGrammar statements_grammar = { .expr = &fixture_expression };
		parser_statement::StatementParser statements = { .parser = &p, .function_return_qt = type_store::VOID, .function_name_tok = function_name, .has_function_context = true, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		type_store::NodeIndex body = statements.parse_body(true)!!;
		tree::NodeCompoundStmt compound = body.get(&p.tree).compound_stmt;
		tree::Node returned = compound.body[0].get(&p.tree);
		assert(returned.return_stmt.return_qt.eql(type_store::VOID, &comp));
		assert(d.messages.len() == 1);
		test::eq(d.messages[0].text, "void function 'foo' should not return a value");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void switch_duplicate_cases_defaults_and_out_of_switch_diagnostics() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("switch.c", "{ switch (1) { case 1: ; case 1: ; default: ; default: ; } case 1: ; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		StatementGrammar statements_grammar = { .expr = &fixture_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		statements.parse_body()!!;
		assert(d.messages.len() == 5);
		test::eq(d.messages[0].text, "duplicate case value '1'");
		test::eq(d.messages[1].text, "previous case defined here");
		test::eq(d.messages[2].text, "multiple default cases in the same switch");
		test::eq(d.messages[3].text, "previous case defined here");
		test::eq(d.messages[4].text, "'case' statement not in a switch statement");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void switch_case_ranges_keep_typed_bounds_and_detect_interior_duplicates() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("switch-range.c", "{ switch (0) { case 2 ... 5: ; case 4: ; case 8: ; } }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		StatementGrammar statements_grammar = { .expr = &fixture_switch_expression, .ice = &fixture_switch_integer_constant_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		type_store::NodeIndex body = statements.parse_body()!!;
		tree::NodeCompoundStmt outer = body.get(&p.tree).compound_stmt;
		assert(outer.body.len == 1);
		tree::Node switch_node = outer.body[0].get(&p.tree);
		assert(switch_node.kind == tree::NodeKind.SWITCH_STMT);
		tree::NodeCompoundStmt switch_body = switch_node.switch_stmt.body.get(&p.tree).compound_stmt;
		assert(switch_body.body.len == 3);
		tree::Node range = switch_body.body[0].get(&p.tree);
		assert(range.kind == tree::NodeKind.CASE_STMT);
		assert(!range.case_stmt.end.is_null(), "GNU case range should retain an end node");
		type_store::NodeIndex range_start = range.case_stmt.start;
		type_store::NodeIndex range_end = range.case_stmt.end.unwrap();
		assert(range_start.kind(&p.tree) == tree::NodeKind.INT_LITERAL);
		assert(range_end.kind(&p.tree) == tree::NodeKind.INT_LITERAL);
		assert(range_start.qt(&p.tree).eql(type_store::INT, &comp));
		assert(range_end.qt(&p.tree).eql(type_store::INT, &comp));
		assert(p.tree.tok_slice(range_start.get(&p.tree).literal.literal_tok) == "2");
		assert(p.tree.tok_slice(range_end.get(&p.tree).literal.literal_tok) == "5");
		assert(d.messages.len() == 2);
		test::eq(d.messages[0].text, "duplicate case value '4'");
		assert(d.messages[0].has_location && d.messages[0].location.col == 37);
		test::eq(d.messages[1].text, "previous case defined here");
		assert(d.messages[1].has_location && d.messages[1].location.col == 21);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void switch_overlapping_case_ranges_are_duplicate_cases() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("switch-overlap.c", "{ switch (0) { case 2 ... 5: ; case 4 ... 8: ; } }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		StatementGrammar statements_grammar = { .expr = &fixture_switch_expression, .ice = &fixture_switch_integer_constant_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		type_store::NodeIndex body = statements.parse_body()!!;
		tree::NodeCompoundStmt outer = body.get(&p.tree).compound_stmt;
		tree::Node switch_node = outer.body[0].get(&p.tree);
		tree::NodeCompoundStmt switch_body = switch_node.switch_stmt.body.get(&p.tree).compound_stmt;
		assert(switch_body.body.len == 2);
		tree::Node overlap = switch_body.body[1].get(&p.tree);
		assert(overlap.kind == tree::NodeKind.CASE_STMT);
		assert(!overlap.case_stmt.end.is_null());
		assert(d.messages.len() == 2);
		test::eq(d.messages[0].text, "duplicate case value '4'");
		assert(d.messages[0].has_location && d.messages[0].location.col == 37);
		test::eq(d.messages[1].text, "previous case defined here");
		assert(d.messages[1].has_location && d.messages[1].location.col == 21);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void switch_unavailable_case_values_are_diagnosed_in_source_order() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("switch-unavailable.c", "{ switch (0) { case 1 ... 2: ; case 3: ; } }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		StatementGrammar statements_grammar = { .expr = &fixture_switch_expression_with_unavailable_values, .ice = &fixture_unavailable_switch_integer_constant_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		statements.parse_body()!!;
		assert(d.messages.len() == 2);
		test::eq(d.messages[0].text, "case value must be an integer constant expression");
		assert(d.messages[0].has_location && d.messages[0].location.col == 27);
		test::eq(d.messages[1].text, "case value must be an integer constant expression");
		assert(d.messages[1].has_location && d.messages[1].location.col == 37);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void descending_switch_case_range_reports_empty_range() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("switch-empty-range.c", "{ switch (0) { case 5 ... 3: ; } }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		StatementGrammar statements_grammar = { .expr = &fixture_switch_expression, .ice = &fixture_switch_integer_constant_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		statements.parse_body()!!;
		assert(d.messages.len() == 1);
		test::eq(d.messages[0].text, "empty case range specified");
		assert(d.messages[0].has_location && d.messages[0].location.col == 21);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void switch_case_bound_requires_a_real_integer_type() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("switch-type.c", "{ switch (0) { case 1: ; } }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		parser::ConstDeclFoldingMode previous_mode = p.const_decl_folding;
		StatementGrammar statements_grammar = { .expr = &fixture_switch_expression, .ice = &fixture_pointer_integer_constant_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		statements.parse_body()!!;
		assert(p.const_decl_folding == previous_mode, "failed case bound must restore constant folding mode");
		assert(d.messages.len() == 1);
		test::eq(d.messages[0].text, "expression is not an integer constant expression");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void computed_goto_requires_address_of_label_expression() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		// Ignore the independent discarded-value warning; this test checks function-level goto validation.
		d.set("unused-value", OFF)!!;
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("goto.c", "{ goto *1; } { goto *1; &&target; target: ; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		StatementGrammar statements_grammar = { .expr = &fixture_full_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		statements.parse_body(true)!!;
		assert(d.messages.len() == 1);
		test::eq(d.messages[0].text, "computed goto in function with no address-of-label expressions");
		statements.parse_body(true)!!;
		assert(d.messages.len() == 1, "&&label in the second function satisfies its computed goto");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void malformed_function_body_clears_label_and_scope_state() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("recovery.c", "{ kept: ; if (1) } { goto kept; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		uint original_scopes = (uint)p.symbols.active_len;
		StatementGrammar statements_grammar = { .expr = &fixture_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		type_store::NodeIndex recovered_body = statements.parse_body(true)!!;
		assert(recovered_body.kind(&p.tree) == tree::NodeKind.COMPOUND_STMT);
		assert(!statements.in_function);
		assert(statements.labels.len() == 0 && statements.gotos.len() == 0);
		assert(p.symbols.active_len == original_scopes);
		// Recovery consumed the malformed function's closing brace.
		type_store::NodeIndex next_body = statements.parse_body(true)!!;
		assert(next_body.kind(&p.tree) == tree::NodeKind.COMPOUND_STMT);
		tree::NodeCompoundStmt second_body = next_body.get(&p.tree).compound_stmt;
		assert(second_body.body.len == 1, "the second body should contain its goto statement");
		assert(second_body.body[0].get(&p.tree).kind == tree::NodeKind.GOTO_STMT);
		assert(!statements.in_function);
		assert(statements.labels.len() == 0 && statements.gotos.len() == 0);
		assert(p.symbols.active_len == original_scopes);
		assert(d.messages.len() == 2, "the malformed if and the second function's unresolved goto should diagnose");
		test::eq(d.messages[0].text, "expected statement");
		test::eq(d.messages[1].text, "use of undeclared label 'kept'");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void source_derived_recovered_function_does_not_leak_labels() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("label-recovery.c",
			"void f(void){ kept: ; if (1) } void g(void){ goto kept; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp);
		parser_frontend::FrontendHandler frontend;
		frontend.bind(&p);
		tree::Tree parsed = p.parse()!!;
		uint function_count = 0;
		foreach (decl : parsed.root_decls)
		{
			if (decl.get(&parsed).kind == tree::NodeKind.FUNCTION) function_count++;
		}
		assert(function_count == 2, "both function definitions should be retained after recovery");
		assert(d.messages.len() == 2, "the recovery error and later unresolved label should both diagnose");
		test::eq(d.messages[0].text, "expected statement");
		test::eq(d.messages[1].text, "use of undeclared label 'kept'");
		parsed.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void statement_attributes_attach_and_validate_argument_counts() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		// Zig gates the C23 attribute diagnostic on this warning option.
		d.set("c23-extensions", WARNING)!!;
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("stmt-attrs.c", "__attribute__((unused)) first: ; [[gnu::unused]] second: ; __attribute__((unused(1))) third: ;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		StatementGrammar statements_grammar = { .expr = &fixture_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		type_store::NodeIndex first = statements.parse_statement()!!;
		assert(first.kind(&p.tree) == tree::NodeKind.LABELED_STMT);
		attribute_map::AttrRef[] attrs = p.tree.attr_map.attrs(first.pack());
		assert(attrs.len == 1);
		assert(p.tree.attr_map.get(attrs[0]).args.tag == attribute::AttributeTag.UNUSED);
		type_store::NodeIndex second = statements.parse_statement()!!;
		assert(second.kind(&p.tree) == tree::NodeKind.LABELED_STMT);
		attribute_map::AttrRef[] c23_attrs = p.tree.attr_map.attrs(second.pack());
		assert(c23_attrs.len == 1);
		assert(p.tree.attr_map.get(c23_attrs[0]).args.tag == attribute::AttributeTag.UNUSED);
		type_store::NodeIndex third = statements.parse_statement()!!;
		assert(third.kind(&p.tree) == tree::NodeKind.LABELED_STMT);
		assert(p.tree.attr_map.attrs(third.pack()).len == 0);
		assert(d.messages.len() == 2);
		test::eq(d.messages[0].text, "[[]] attributes are a C23 extension");
		test::eq(d.messages[1].text, "'unused' attribute takes no arguments");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void fallthrough_statement_attribute_is_accepted_before_case_inside_switch() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("stmt-fallthrough.c",
			"switch (1) { case 0: __attribute__((fallthrough)); case 1: break; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		StatementGrammar statements_grammar = { .expr = &fixture_switch_expression, .ice = &fixture_switch_integer_constant_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		type_store::NodeIndex switch_stmt = statements.parse_statement()!!;
		assert(switch_stmt.kind(&p.tree) == tree::NodeKind.SWITCH_STMT);
		tree::NodeCompoundStmt switch_body = switch_stmt.get(&p.tree).switch_stmt.body.get(&p.tree).compound_stmt;
		assert(switch_body.body.len == 2);
		tree::Node first_case = switch_body.body[0].get(&p.tree);
		assert(first_case.kind == tree::NodeKind.CASE_STMT);
		type_store::NodeIndex fallthrough_stmt = first_case.case_stmt.body;
		assert(fallthrough_stmt.kind(&p.tree) == tree::NodeKind.NULL_STMT);
		attribute_map::AttrRef[] attrs = p.tree.attr_map.attrs(fallthrough_stmt.pack());
		assert(attrs.len == 1);
		assert(p.tree.attr_map.get(attrs[0]).args.tag == attribute::AttributeTag.FALLTHROUGH);
		assert(d.messages.len() == 0);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void fallthrough_statement_attribute_outside_switch_is_diagnosed() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("stmt-fallthrough.c", "__attribute__((fallthrough));")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		StatementGrammar statements_grammar = { .expr = &fixture_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		type_store::NodeIndex stmt = statements.parse_statement()!!;
		assert(stmt.kind(&p.tree) == tree::NodeKind.NULL_STMT);
		assert(d.messages.len() == 1);
		test::eq(d.messages[0].text, "'fallthrough' attribute outside a switch statement");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// Leading attributes before a block-scope declaration must reach the declaration
// parser through the real DeclarationParser local-declaration hook, not the
// statement-attribute applier (which rejects 'noreturn').
fn void block_scope_declaration_with_noreturn_attribute_is_not_statement_attribute() @test
{
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
		source::Source src = comp.add_source_from_buffer("block-decl-noreturn.c",
			"void f(void) { __attribute__((noreturn)) int x; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1, "the function should be retained");
		tree::Node function_node = result.root_decls[0].get(&result);
		assert(function_node.kind == tree::NodeKind.FUNCTION);
		tree::Node body_node = function_node.function.body.unwrap().get(&result);
		assert(body_node.compound_stmt.body.len == 2, "the void function body also gets an implicit return statement");
		tree::Node declaration_statement = body_node.compound_stmt.body[0].get(&result);
		assert(declaration_statement.kind == tree::NodeKind.DECL_STMT, "a leading attribute before a declaration should not turn it into a statement");
		tree::Node x = declaration_statement.decl_stmt.decls[0].get(&result);
		assert(x.kind == tree::NodeKind.VARIABLE);
		assert(result.tok_slice(x.variable.name_tok) == "x");
		for (sz i = 0; i < d.messages.len(); i++)
		{
			assert(d.messages[i].text != "'noreturn' attribute cannot be applied to a statement", "a block-scope declaration must not be diagnosed as a statement attribute");
		}

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void fallthrough_statement_attribute_still_routes_to_statement_with_declaration_parser() @test
{
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
		source::Source src = comp.add_source_from_buffer("block-fallthrough.c",
			"void f(void) { __attribute__((fallthrough)); }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1, "the function should be retained");
		tree::Node function_node = result.root_decls[0].get(&result);
		assert(function_node.kind == tree::NodeKind.FUNCTION);
		tree::Node body_node = function_node.function.body.unwrap().get(&result);
		assert(body_node.compound_stmt.body.len == 2, "the void function body also gets an implicit return statement");
		tree::Node null_statement = body_node.compound_stmt.body[0].get(&result);
		assert(null_statement.kind == tree::NodeKind.NULL_STMT, "fallthrough should remain a statement attribute on the null statement");
		assert(d.messages.len() == 1);
		test::eq(d.messages[0].text, "'fallthrough' attribute outside a switch statement");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void label_interposed_gnu_attributes_attach_to_labeled_node() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("label-attrs.c", "__attribute__((unused)) target: __attribute__((unused)) ;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		StatementGrammar statements_grammar = { .expr = &fixture_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		type_store::NodeIndex labeled = statements.parse_statement()!!;
		assert(labeled.kind(&p.tree) == tree::NodeKind.LABELED_STMT);
		attribute_map::AttrRef[] attrs = p.tree.attr_map.attrs(labeled.pack());
		assert(attrs.len == 2, "leading and label-interposed attributes must both attach to the label");
		assert(p.tree.attr_map.get(attrs[0]).args.tag == attribute::AttributeTag.UNUSED);
		assert(p.tree.attr_map.get(attrs[1]).args.tag == attribute::AttributeTag.UNUSED);
		tree::Node body = labeled.get(&p.tree).labeled_stmt.body.get(&p.tree);
		assert(body.kind == tree::NodeKind.NULL_STMT);
		assert(p.tree.attr_map.attrs(labeled.get(&p.tree).labeled_stmt.body.pack()).len == 0);
		assert(d.messages.len() == 0);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void malformed_statement_attributes_and_scopes_are_restored() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("stmt-attrs-recovery.c", "{ __attribute__((unused)) for (;;) } ;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		uint original_scopes = (uint)p.symbols.active_len;
		StatementGrammar statements_grammar = { .expr = &fixture_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		statements.parse_body()!!;
		assert(p.symbols.active_len == original_scopes);
		assert(p.is_at(tokenizer::TokenId.SEMICOLON), "recovery must leave the following statement at the cursor");
		type_store::NodeIndex next = statements.parse_statement()!!;
		assert(next.kind(&p.tree) == tree::NodeKind.NULL_STMT);
		assert(p.tree.attr_map.attrs(next.pack()).len == 0, "failed statement attributes must not leak");
		assert(p.symbols.active_len == original_scopes);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void gnu_statement_expression_wraps_compound_and_uses_final_expression_type() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		d.set("gnu-statement-expression", diagnostics::MessageKind.WARNING)!!;
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("stmt-expr.c", "({ 1; })")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		p.set_function_context({ .active = true });
		StatementGrammar statements_grammar = { .expr = &fixture_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		parser_postfix::CallbackParts postfix_parts = { .context = &statements, .primary = &fixture_postfix_primary, .nested = &fixture_postfix_expression, .statement_expression_context = &statements, .statement_expression_body = &fixture_statement_expression_body };
		parser_postfix::PostfixParser postfix = { .parser = &p, .parts = &postfix_parts, .statement_body = &postfix_parts };
		parser_result::Result result = postfix.parse()!!;
		assert(result.node.kind(&p.tree) == tree::NodeKind.STMT_EXPR);
		assert(result.qt.eql(type_store::INT, &comp));
		tree::Node statement_expr = result.node.get(&p.tree);
		assert(statement_expr.unary.qt.eql(type_store::INT, &comp));
		assert(statement_expr.unary.operand.kind(&p.tree) == tree::NodeKind.COMPOUND_STMT);
		tree::NodeCompoundStmt body = statement_expr.unary.operand.get(&p.tree).compound_stmt;
		assert(body.body.len == 1);
		assert(body.body[0].kind(&p.tree) == tree::NodeKind.INT_LITERAL);
		assert(p.at_eof());
		assert(d.messages.len() == 1);
		test::eq(d.messages[0].text, "use of GNU statement expression extension");
		assert(d.messages[0].has_opt && d.messages[0].opt == diagnostics::Option.GNU_STATEMENT_EXPRESSION);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void gnu_statement_expression_file_scope_diagnostics_are_ordered() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		d.set("gnu-statement-expression", diagnostics::MessageKind.WARNING)!!;
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("stmt-expr-file-scope.c", "({ 1; })")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		uint original_scopes = (uint)p.symbols.active_len;
		StatementGrammar statements_grammar = { .expr = &fixture_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		parser_postfix::CallbackParts postfix_parts = { .context = &statements, .primary = &fixture_postfix_primary, .nested = &fixture_postfix_expression, .statement_expression_context = &statements, .statement_expression_body = &fixture_statement_expression_body };
		parser_postfix::PostfixParser postfix = { .parser = &p, .parts = &postfix_parts, .statement_body = &postfix_parts };
		assert(@catch(postfix.parse()) == parser_postfix::PARSING_FAILED);
		assert(d.messages.len() == 2);
		test::eq(d.messages[0].text, "use of GNU statement expression extension");
		test::eq(d.messages[1].text, "statement expression not allowed at file scope");
		assert(p.symbols.active_len == original_scopes, "file-scope rejection must not enter the compound body");
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void gnu_statement_expression_without_final_expression_has_void_type() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("stmt-expr-void.c", "({ ; })")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		p.set_function_context({ .active = true });
		StatementGrammar statements_grammar = { .expr = &fixture_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		parser_postfix::CallbackParts postfix_parts = { .context = &statements, .primary = &fixture_postfix_primary, .nested = &fixture_postfix_expression, .statement_expression_context = &statements, .statement_expression_body = &fixture_statement_expression_body };
		parser_postfix::PostfixParser postfix = { .parser = &p, .parts = &postfix_parts, .statement_body = &postfix_parts };
		parser_result::Result result = postfix.parse()!!;
		assert(result.node.kind(&p.tree) == tree::NodeKind.STMT_EXPR);
		assert(result.qt.eql(type_store::VOID, &comp));
		assert(result.node.get(&p.tree).unary.operand.kind(&p.tree) == tree::NodeKind.COMPOUND_STMT);
		assert(p.at_eof());
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void malformed_gnu_statement_expression_restores_attribute_and_scope_state() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("stmt-expr-recovery.c",
			"({ __attribute__((unused)) ; for (;;)")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		p.set_function_context({ .active = true });
		uint original_scopes = (uint)p.symbols.active_len;
		usz original_attributes = (usz)p.tree.attr_map.attributes.len();
		usz original_extra = (usz)p.tree.attr_map.extra.len();
		usz original_decl_attrs = (usz)p.tree.attr_map.decl_attrs.len();
		StatementGrammar statements_grammar = { .expr = &fixture_expression };
		parser_statement::StatementParser statements = { .parser = &p, .expressions = &statements_grammar, .local_declarations = &statements_grammar };
		parser_postfix::CallbackParts postfix_parts = { .context = &statements, .primary = &fixture_postfix_primary, .nested = &fixture_postfix_expression, .statement_expression_context = &statements, .statement_expression_body = &fixture_statement_expression_body };
		parser_postfix::PostfixParser postfix = { .parser = &p, .parts = &postfix_parts, .statement_body = &postfix_parts };
		assert(@catch(postfix.parse()) == parser_postfix::PARSING_FAILED);
		assert(p.symbols.active_len == original_scopes);
		assert(p.tree.attr_map.attributes.len() == (sz)original_attributes);
		assert(p.tree.attr_map.extra.len() == (sz)original_extra);
		assert(p.tree.attr_map.decl_attrs.len() == (sz)original_decl_attrs);
		p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// Probe for pragma replay between compound-statement items. Preprocessing reports
// HANDLED so no unknown-pragma note is emitted; the parser callback is what counts.
<* Pragma handler counting parser replays; preprocessing just accepts the pragma. *>
struct PragmaCompoundProbe (pragma::IPragma)
{
	uint parse_calls;
}

fn pragma::PragmaResult PragmaCompoundProbe.preprocessor_handler(&self, preprocessor::Preprocessor* pp, tokens::TokenIndex start_idx) @dynamic
	=> pragma::PragmaResult.HANDLED;

fn pragma::PragmaResult PragmaCompoundProbe.parser_handler(&self, parser::Parser* p, tokens::TokenIndex start_idx) @dynamic
{
	self.parse_calls++;
	return pragma::PragmaResult.HANDLED;
}

// A `#pragma` between compound-statement items replays once before the statement
// and once as the last item before the closing brace; the function stays intact.
fn void parser_replays_pragma_inside_compound_statement() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		PragmaCompoundProbe probe = {};
		bool added_probe = comp.pragmas.add("probe", &probe);
		assert(added_probe);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		source::Source src = comp.add_source_from_buffer("pragma_compound.c",
			"void f(void)\n{\nint x;\n#pragma probe\nx = 1;\n#pragma probe\n}\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser::Parser p; p.init(&pp);
		parser_frontend::FrontendHandler frontend;
		frontend.bind(&p);
		tree::Tree parsed = p.parse()!!;

		assert(probe.parse_calls == 2, "each #pragma between compound items should replay once");
		assert(d.messages.len() == 0, "replayed compound-statement pragmas should not add diagnostics");
		uint function_count = 0;
		foreach (decl : parsed.root_decls)
		{
			if (decl.get(&parsed).kind == tree::NodeKind.FUNCTION) function_count++;
		}
		assert(function_count == 1, "function f should remain the only function definition");

		parsed.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

alias StmtExprFn = fn parser_result::Result?(void* context, parser::Parser* p, bool eval);
alias StmtIceFn = fn parser_result::Result?(void* context, parser::Parser* p, parser::ConstDeclFoldingMode mode, bool eval);
alias StmtLocalFn = fn type_store::NodeIndex?(void* context, parser::Parser* p);

<* Statement grammar over this file's callback fixtures; a null callback is parser::HOOK_ABSENT. *>
struct StatementGrammar (parser::IExpressionGrammar, parser_statement::ILocalDeclarationGrammar)
{
	void* context;
	StmtExprFn expr;
	StmtIceFn ice;
	void* local_context;
	StmtLocalFn local;
}

fn parser_result::Result? StatementGrammar.expression(&self, parser::Parser* p, bool eval) @dynamic
{
	if (!self.expr) return parser::HOOK_ABSENT~;
	return self.expr(self.context, p, eval);
}
fn parser_result::Result? StatementGrammar.integer_constant_expression(&self, parser::Parser* p,
	parser::ConstDeclFoldingMode mode, bool eval) @dynamic
{
	if (!self.ice) return parser::HOOK_ABSENT~;
	return self.ice(self.context, p, mode, eval);
}
fn type_store::NodeIndex? StatementGrammar.parse_local_declaration(&self, parser::Parser* p) @dynamic
{
	if (!self.local) return parser::HOOK_ABSENT~;
	return self.local(self.local_context, p);
}
