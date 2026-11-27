// Port of c3c src/compiler/parse_stmt.c: statements (compound, if, while,
// do, for, foreach, switch/case, defer, return, break/continue/nextcase,
// asm blocks, assert) and the compile-time statements ($if, $switch, $for,
// $foreach, $assert, $error, $echo, $expand).
//
// c3c's returning macros are expanded as described in parser.c3 (and
// parse_expr_support.c3 for ASSIGN_*_OR_RET into existing lvalues);
// CHECK_HAS_BODY(text) is `if (!check_has_body(c, text)) return poisoned_ast;`.
//
// Deviations from c3c:
// - The file-local `consume_eos(ParseContext*, Ast*)` is `consume_eos_ast`
//   (parser.c3 already has the CONSUME_EOS_OR_RET helper `consume_eos`).
// - `goto DONE` in parse_decl_stmt_after_type is restructured.
// - copy_type_info_single / copy_attributes_single come from
//   parse_expr_support.c3 (copying.c is not ported yet).
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// --- Internal functions

fn bool next_is_end_parens(ParseContext* c)
{
	TokenType tok = c.tok;
	return tok == RBRACE || tok == RPAREN;
}

<* c3c CHECK_HAS_BODY(text_): false (after reporting) if the body is missing. *>
fn bool check_has_body(ParseContext* c, String text_)
{
	if (next_is_end_parens(c))
	{
		@print_error_after(&c.prev_span, "The body of %s statement was expected here.", text_);
		return false;
	}
	return true;
}

fn Ast* parse_decl_stmt_after_type(ParseContext* c, TypeInfo* type)
{
	Ast* ast = ast_calloc();
	ast.loc = copy_loc(type.loc);
	ast.ast_kind = DECLARE_STMT;
	if (!assign_decl_ok(&ast.declare_stmt, parse_local_decl_after_type(c, type))) return poisoned_ast;
	Decl* decl = ast.declare_stmt;
	switch (c.tok)
	{
		case LBRACKET:
			if (!decl.var_decl.init_expr)
			{
				SourceLoc loc = extend_loc_with_token(sourcelocptr(type.loc), &c.span);
				@print_error_at_loc(&loc, "This looks like the beginning of a declaration with the format 'int %s[4]' "
								   "which is a c-style array declaration. In C3, you need to use something like 'int[4] %s' instead.",
								   decl.name, decl.name);
				return poisoned_ast;
			}
		case EOS:
			// goto DONE
			range_extend_prev(c, ast.loc);
			return ast;
		default:
			break;
	}

	if (decl.attributes.len || decl.var_decl.init_expr)
	{
		if (tok_is(c, COMMA) && peek(c) == IDENT)
		{
			if (decl.var_decl.init_expr)
			{
				@print_error_at(decl.var_decl.init_expr.loc, "Multiple variable declarations cannot use initialization.");
				return poisoned_ast;
			}
			if (decl.attributes.len)
			{
				assert(decl.attributes[^1]);
				@print_error_at(decl.attributes[^1].loc, "Multiple variable declarations must have attributes at the end.");
				return poisoned_ast;
			}
		}
		// goto DONE
		range_extend_prev(c, ast.loc);
		return ast;
	}
	Decl*[] decls;
	@vec_add(&decls, decl);
	Attr*[] attributes;
	while (try_consume(c, COMMA))
	{
		if (!assign_decl_ok(&decl, parse_local_decl_after_type(c, copy_type_info_single(type)))) return poisoned_ast;
		if (decl.var_decl.init_expr)
		{
			@print_error_at(decl.var_decl.init_expr.loc, "Multiple variable declarations cannot use initialization.");
			return poisoned_ast;
		}
		if (decl.attributes.len)
		{
			if (tok_is(c, COMMA))
			{
				assert(decl.attributes[^1]);
				@print_error_at(decl.attributes[^1].loc, "Multiple variable declarations must have attributes at the end.");
				return poisoned_ast;
			}
			attributes = decl.attributes;
		}
		@vec_add(&decls, decl);
	}
	if (attributes.len)
	{
		foreach (d : decls)
		{
			if (d == decl) continue;
			d.attributes = copy_attributes_single(attributes);
		}
	}
	ast.decls_stmt = decls;
	ast.ast_kind = DECLS_STMT;
	// DONE:
	range_extend_prev(c, ast.loc);
	return ast;
}

<*
 declaration_stmt
 	: declaration ';'
*>
fn Ast* parse_declaration_stmt(ParseContext* c)
{
	if (tok_is(c, CONST))
	{
		// Consts don't have multiple declarations.
		Ast* decl_stmt = new_ast_loc(DECLARE_STMT, c.span);
		if (!assign_decl_ok(&decl_stmt.declare_stmt, parse_const_declaration(c, false, false))) return poisoned_ast;
		decl_stmt.declare_stmt.visibility = LOCAL;
		range_extend_prev(c, decl_stmt.loc);
		if (!consume_eos(c)) return poisoned_ast;
		return decl_stmt;
	}

	bool is_threadlocal = try_consume(c, TLOCAL);
	bool is_static = !is_threadlocal && try_consume(c, STATIC);
	is_static = is_threadlocal || is_static;
	TypeInfo* type = parse_optional_type(c);
	if (!type_info_ok(type)) return poisoned_ast;
	Ast* result = parse_decl_stmt_after_type(c, type);
	if (!ast_ok(result)) return poisoned_ast;
	if (!consume_eos(c)) return poisoned_ast;
	if (result.ast_kind == DECLARE_STMT)
	{
		result.declare_stmt.var_decl.is_threadlocal = is_threadlocal;
		result.declare_stmt.var_decl.is_static = is_static || is_threadlocal;
		result.declare_stmt.visibility = LOCAL;
		return result;
	}
	foreach (var_ : result.decls_stmt)
	{
		var_.var_decl.is_threadlocal = is_threadlocal;
		var_.var_decl.is_static = is_static || is_threadlocal;
		var_.visibility = LOCAL;
	}
	return result;
}

fn Decl* parse_optional_label(ParseContext* c, Ast* parent)
{
	if (!tok_is(c, CONST_IDENT)) return null;
	Decl* decl = decl_new_loc(LABEL, symstr(c), c.span);
	decl.label.parent = astid(parent);
	advance_and_verify(c, CONST_IDENT);
	if (!try_consume(c, COLON))
	{
		@print_error_at(decl.loc, "The name must be followed by a ':', did you forget it?");
		return poisoned_decl;
	}
	return decl;
}

fn void parse_optional_label_target(ParseContext* c, Label* label)
{
	if (tok_is(c, CONST_IDENT))
	{
		label.loc = make_loc(c.span);
		label.name = symstr(c);
		advance_and_verify(c, CONST_IDENT);
	}
}

fn bool parse_asm_offset(ParseContext* c, ExprAsmArg* asm_arg)
{
	if (!tok_is(c, INTEGER))
	{
		@print_error_here(c, "Expected an integer value.");
		return false;
	}
	Expr* offset = parse_integer(c, null, null);
	assert(expr_is_const_int(offset));
	Int i = offset.const_expr.ixx;
	if ((ulong)(i.i >> 64))
	{
		@print_error_here(c, "The value is too high for an offset.");
		return false;
	}
	asm_arg.offset = (long)(ulong)i.i;
	return true;
}

fn bool parse_asm_scale(ParseContext* c, ExprAsmArg* asm_arg)
{
	if (!tok_is(c, INTEGER))
	{
		@print_error_here(c, "Expected an integer value.");
		return false;
	}
	Expr* value = parse_integer(c, null, null);
	assert(expr_is_const_int(value));
	Int i = value.const_expr.ixx;
	if ((ulong)(i.i >> 64))
	{
		@print_error_here(c, "The value is too high for a scale: %s", int_to_str(i, 10, false));
		return false;
	}
	switch ((ulong)i.i)
	{
		case 1:
			asm_arg.offset_type = SCALE_1;
		case 2:
			asm_arg.offset_type = SCALE_2;
		case 4:
			asm_arg.offset_type = SCALE_4;
		case 8:
			asm_arg.offset_type = SCALE_8;
		default:
			@print_error_here(c, "Expected 1, 2, 4 or 8.");
			return false;
	}
	return true;
}

<*
 Asm [REG + BAR * 4], [&foo]
 asm_addr ::= '[' asm_expr
*>
fn bool parse_asm_addr(ParseContext* c, ExprAsmArg* asm_arg)
{
	asm_arg.kind = ARG_ADDR;
	asm_arg.offset_type = SCALE_1;
	Expr* base = parse_asm_expr(c);
	if (!expr_ok(base)) return false;

	// Simple case [foo]
	if (try_consume(c, RBRACKET))
	{
		// Here we're covering [&foo]
		if (base.expr_asm_arg.kind == ARG_MEMADDR)
		{
			*asm_arg = base.expr_asm_arg;
			asm_arg.kind = ARG_MEMVAR;
			return true;
		}
		asm_arg.base = exprid(base);
		return true;
	}

	asm_arg.base = exprid(base);

	// [foo + ... or [foo - ...]
	TokenType type = c.tok;
	switch (type)
	{
		case PLUS:
		case MINUS:
			advance(c);
		default:
			@print_error_here(c, "Expected + or - here.");
			return false;
	}
	if (type == MINUS) asm_arg.neg_offset = true;

	// If it's an integer, then it's [foo + 123] or [foo - 213]
	if (tok_is(c, INTEGER))
	{
		if (!parse_asm_offset(c, asm_arg)) return false;
		if (!expect_advance(c, RBRACKET)) return false;
		return true;
	}

	// Otherwise we expect the index.
	if (!assign_exprid_ok(&asm_arg.idx, parse_asm_expr(c))) return false;

	// We got [foo + bar] or [foo - bar]
	if (try_consume(c, RBRACKET)) return true;

	switch (c.tok)
	{
		case STAR:
			// [foo + bar * ...]
			advance(c);
			if (!parse_asm_scale(c, asm_arg)) return false;
		case SHR:
			advance(c);
			asm_arg.offset_type = SCALE_SHR;
			if (!parse_asm_offset(c, asm_arg)) return false;
			if (!expect_advance(c, RBRACKET)) return false;
			return true;
		case SHL:
			advance(c);
			asm_arg.offset_type = SCALE_SHL;
			if (!parse_asm_offset(c, asm_arg)) return false;
			if (!expect_advance(c, RBRACKET)) return false;
			return true;
		default:
			break;
	}
	// [foo + bar * 4]
	if (try_consume(c, RBRACKET)) return true;

	if (asm_arg.neg_offset)
	{
		@print_error_here(c, "Addressing cannot both have a negated index and an offset.");
		return false;
	}

	switch (c.tok)
	{
		case MINUS:
			asm_arg.neg_offset = true;
		case PLUS:
			break;
		default:
			@print_error_here(c, "Expected + or - here.");
			return false;
	}
	advance(c);

	if (!parse_asm_offset(c, asm_arg)) return false;

	if (!expect_advance(c, RBRACKET)) return false;
	return true;
}

<*
 asm_expr ::= asm_addr | asm_reg | asm_regvar | asm_addrof | asm_argvalue
 asm_reg = CT_IDENT | CT_CONST_IDENT (register name)
 asm_regvar = IDENT (variable)
 asm_addof = '&' IDENT (variable address)
 asm_argvalue = ('-'? INTEGER) | CONST_IDENT | FLOAT | '(' expr ')'
*>
fn Expr* parse_asm_expr(ParseContext* c)
{
	Expr* expr = expr_new_token(c, ASM);
	switch (c.tok)
	{
		case LBRACKET:
			advance(c);
			if (!parse_asm_addr(c, &expr.expr_asm_arg)) return poisoned_expr;
			range_extend_prev(c, expr.loc);
			return expr;
		case CT_IDENT:
		case CT_CONST_IDENT:
			expr.expr_asm_arg.kind = ARG_REG;
			expr.expr_asm_arg.reg.name = c.data.string;
			advance(c);
			return expr;
		case HASH_IDENT:
			@print_error_here(c, "Compile time variables need to be wrapped in () inside an asm block.");
			return poisoned_expr;
		case IDENT:
			expr.expr_asm_arg.kind = ARG_REGVAR;
			expr.expr_asm_arg.ident.name = c.data.string;
			advance(c);
			return expr;
		case AMP:
			expr.expr_asm_arg.kind = ARG_MEMADDR;
			advance(c);
			expr.expr_asm_arg.ident.name = c.data.string;
			if (!try_consume(c, IDENT))
			{
				@print_error_here(c, "Expected a variable name after '&', like '&foo'.");
				return poisoned_expr;
			}
			return expr;
		case MINUS:
			expr.expr_asm_arg.kind = ARG_VALUE;
			if (!assign_exprid_ok(&expr.expr_asm_arg.expr_id, parse_expr(c))) return poisoned_expr;
			return expr;
		case INTEGER:
		case CONST_IDENT:
		case REAL:
			expr.expr_asm_arg.kind = ARG_VALUE;
			if (!assign_exprid_ok(&expr.expr_asm_arg.expr_id, parse_expr(c))) return poisoned_expr;
			return expr;
		case LPAREN:
			advance(c);
			expr.expr_asm_arg.kind = ARG_VALUE;
			if (!assign_exprid_ok(&expr.expr_asm_arg.expr_id, parse_expr(c))) return poisoned_expr;
			if (!@consume(c, RPAREN, "Expected the ')' here.")) return poisoned_expr;
			range_extend_prev(c, expr.loc);
			return expr;
		default:
			@print_error_here(c, "This doesn't look like an asm argument.");
			return poisoned_expr;
	}
}

<*
 asm_label | asm_stmt
 asm_label     ::= CONST_IDENT ':'
 asm_stmt      ::= IDENT | int ('.' IDENT) )? asm_expr_list? ';'
 asm_expr_list ::= asm_expr (',' asm_expr)* ','?
*>
fn Ast* parse_asm_stmt(ParseContext* c)
{
	Ast* asm_stmt = ast_new_curr(c, ASM_STMT);
	if (tok_is(c, CONST_IDENT))
	{
		asm_stmt.asm_label = symstr(c);
		advance_and_verify(c, CONST_IDENT);
		asm_stmt.ast_kind = ASM_LABEL;
		if (!@consume(c, COLON, "Expected a ':' to terminate the label.")) return poisoned_ast;
		return asm_stmt;
	}
	if (!tok_is(c, IDENT) && !tok_is(c, INT))
	{
		@print_error_here(c, "Expected an asm instruction here.");
		return poisoned_ast;
	}
	asm_stmt.asm_stmt.instruction = symstr(c);
	advance(c);
	if (try_consume(c, DOT))
	{
		if (!tok_is(c, IDENT))
		{
			@print_error_here(c, "Expected asm instruction variant.");
			return poisoned_ast;
		}
		asm_stmt.asm_stmt.variant = symstr(c);
		advance_and_verify(c, IDENT);
	}
	Expr*[] list;
	while (!try_consume(c, EOS))
	{
		Expr* expr = parse_asm_expr(c);
		if (!expr_ok(expr)) return poisoned_ast;
		@vec_add(&list, expr);
		if (try_consume(c, COMMA)) continue;
		if (!expect(c, EOS)) return poisoned_ast;
	}
	asm_stmt.asm_stmt.args = list;
	return asm_stmt;
}

fn bool read_asm_attributes(ParseContext* c, bool* is_volatile_ref, bool* is_aligned_ref, bool after_start)
{
	bool is_volatile = true;
	bool is_aligned = false;
	while (tok_is(c, AT_IDENT))
	{
		String kw = symstr(c);
		if (kw.ptr == kw_at_pure.ptr)
		{
			if (!is_volatile) return @print_error_here(c, "'@pure' should only appear once.");
			is_volatile = false;
		}
		else if (kw.ptr == kw_at_align.ptr)
		{
			if (is_aligned) return @print_error_here(c, "'@align' should only appear once.");
			is_aligned = true;
		}
		else
		{
			return @print_error_here(c, "Only '@pure' and '@align' attributes are allowed.");
		}
		advance_and_verify(c, AT_IDENT);
		if (!tok_is(c, AT_IDENT))
		{
			if (after_start && !tok_is(c, LBRACE)) return @print_error_here(c, "Expected '{' after the attribute.");
			break;
		}
	}
	*is_volatile_ref = is_volatile;
	*is_aligned_ref = is_aligned;
	return true;
}

<* asm ::= 'asm' @pure? @inline? '{' asm_stmt* '}' | 'asm' '(' string ')' @pure? @inline? *>
fn Ast* parse_asm_block_stmt(ParseContext* c)
{
	Ast* ast = new_ast_loc(ASM_BLOCK_STMT, c.span);
	advance_and_verify(c, ASM);
	bool is_volatile = false;
	bool is_aligned = false;
	if (!read_asm_attributes(c, &is_volatile, &is_aligned, true)) return poisoned_ast;
	if (try_consume(c, LBRACE))
	{
		AsmInlineBlock* block = calloc_arena(AsmInlineBlock::size);
		AstId* prev = &block.asm_stmt;
		while (!try_consume(c, RBRACE))
		{
			Ast* block_stmt = parse_asm_stmt(c);
			if (!ast_ok(block_stmt)) return poisoned_ast;
			*prev = astid(block_stmt);
			prev = &block_stmt.next;
		}
		ast.asm_block_stmt.block = block;
		ast.asm_block_stmt.is_volatile = is_volatile;
		ast.asm_block_stmt.is_aligned = is_aligned;
		return ast;
	}
	ast.asm_block_stmt.is_string = true;
	if (!expect_advance(c, LPAREN)) return poisoned_ast;
	if (!assign_exprid_ok(&ast.asm_block_stmt.asm_string, parse_expr(c))) return poisoned_ast;
	if (!expect_advance(c, RPAREN)) return poisoned_ast;
	if (!read_asm_attributes(c, &is_volatile, &is_aligned, false)) return poisoned_ast;
	ast.asm_block_stmt.is_volatile = is_volatile;
	ast.asm_block_stmt.is_aligned = is_aligned;
	range_extend_prev(c, ast.loc);
	if (!consume_eos(c)) return poisoned_ast;
	return ast;
}

<*
 do_stmt ::= DO optional_label compound_stmt (WHILE '(' expression ')')? ';'

 Note that we transform do to a for loop (with a special flag)
 – and in parsing we allow a regular statement, but disambiguate that
 during semantic analysis.
*>
fn Ast* parse_do_stmt(ParseContext* c)
{
	Ast* do_ast = new_ast_token(c, FOR_STMT);

	advance_and_verify(c, DO);

	do_ast.flow.skip_first = true;
	if (!assign_declid_ok(&do_ast.for_stmt.flow.label, parse_optional_label(c, do_ast))) return poisoned_ast;
	if (!check_has_body(c, "a do")) return poisoned_ast;
	if (!assign_astid_ok(&do_ast.for_stmt.body, parse_stmt(c))) return poisoned_ast;

	if (try_consume(c, EOS))
	{
		do_ast.for_stmt.cond = exprid(expr_new_const_bool(make_loc(c.prev_span), type_bool, false));
	}
	else
	{
		if (!expect_advance(c, WHILE)) return poisoned_ast;
		if (!expect_advance(c, LPAREN)) return poisoned_ast;
		if (!assign_exprid_ok(&do_ast.for_stmt.cond, parse_expr(c))) return poisoned_ast;
		if (!expect_advance(c, RPAREN)) return poisoned_ast;
		if (!consume_eos(c)) return poisoned_ast;
	}
	return do_ast;
}

fn bool token_type_ends_case(TokenType type, TokenType case_type, TokenType default_type)
{
	return type == case_type || type == default_type || type == RBRACE || type == CT_ENDSWITCH;
}

fn Ast* parse_case_stmts(ParseContext* c, TokenType case_type, TokenType default_type, uint row)
{
	if (token_type_ends_case(c.tok, case_type, default_type))
	{
		if (c.span.row > row + 1 && (c.tok == CASE || c.tok == DEFAULT))
		{
			@print_error_last(c, "Fallthrough cases with empty rows or comments have unclear meaning, an explicit 'break' or 'nextcase' is needed (or remove the spacing!).");
			return poisoned_ast;
		}
		return null;
	}
	Ast* compound = new_ast_token(c, COMPOUND_STMT);
	AstId* next = &compound.compound_stmt.first_stmt;
	while (!token_type_ends_case(c.tok, case_type, default_type))
	{
		if (!check_has_body(c, "a case")) return poisoned_ast;
		Ast* stmt = parse_stmt(c);
		if (!ast_ok(stmt)) return poisoned_ast;
		ast_append(&next, stmt);
	}
	return compound;
}

<* defer_stmt ::= DEFER (TRY | CATCH | '(' CATCH var ')')? statement *>
fn Ast* parse_defer_stmt(ParseContext* c)
{
	advance_and_verify(c, DEFER);
	Ast* defer_stmt = new_ast_token(c, DEFER_STMT);
	if (try_consume(c, TRY))
	{
		defer_stmt.defer_stmt.is_try = true;
	}
	else if (try_consume(c, CATCH))
	{
		defer_stmt.defer_stmt.is_catch = true;
	}
	else if (tok_is(c, LPAREN) && peek(c) == CATCH)
	{
		advance_and_verify(c, LPAREN);
		if (!expect_advance(c, CATCH)) return poisoned_ast;
		if (!expect_ident(c, "identifier")) return poisoned_ast;
		Ast* compound = ast_new_curr(c, COMPOUND_STMT);
		Ast* first = ast_new_curr(c, DECLARE_STMT);
		SourceLocId loc = make_loc(c.span);
		Decl* decl = decl_new_var(c.data.string, loc, type_info_new_base(type_fault, loc), LOCAL);
		defer_stmt.defer_stmt.is_catch = true;
		decl.var_decl.init_expr = expr_new(LAST_FAULT, decl.loc);
		first.declare_stmt = decl;
		advance_and_verify(c, IDENT);
		if (!expect_advance(c, RPAREN)) return poisoned_ast;
		if (!check_has_body(c, "a defer-catch")) return poisoned_ast;
		if (!assign_astid_ok(&first.next, parse_stmt(c))) return poisoned_ast;
		compound.compound_stmt.first_stmt = astid(first);
		defer_stmt.defer_stmt.body = astid(compound);
		return defer_stmt;
	}
	if (!check_has_body(c, "a defer")) return poisoned_ast;
	if (!assign_astid_ok(&defer_stmt.defer_stmt.body, parse_stmt(c))) return poisoned_ast;
	return defer_stmt;
}

<*
 while_stmt ::= WHILE optional_label '(' cond ')' statement

 Note that during parsing we rewrite this as a for loop.
*>
fn Ast* parse_while_stmt(ParseContext* c)
{
	Ast* while_ast = new_ast_token(c, FOR_STMT);
	advance_and_verify(c, WHILE);

	if (!assign_declid_ok(&while_ast.for_stmt.flow.label, parse_optional_label(c, while_ast))) return poisoned_ast;
	if (!expect_advance(c, LPAREN)) return poisoned_ast;
	if (!assign_exprid_ok(&while_ast.for_stmt.cond, parse_cond(c))) return poisoned_ast;
	if (!expect_advance(c, RPAREN)) return poisoned_ast;
	uint row = c.prev_span.row;
	if (!check_has_body(c, "a while")) return poisoned_ast;
	Ast* body = parse_stmt(c);
	if (!ast_ok(body)) return poisoned_ast;
	if (body.ast_kind != COMPOUND_STMT && row != sourcelocptr(body.loc).row)
	{
		@print_error_at(body.loc, "A single statement after 'while' must be placed on the same line, or be enclosed in {}.");
		return poisoned_ast;
	}
	while_ast.for_stmt.body = astid(body);
	return while_ast;
}

<*
 if_stmt ::= IF optional_label '(' cond ')' compound_stmt (ELSE compound_stmt)?
           | IF optional_label '(' cond ')' statement
*>
fn Ast* parse_if_stmt(ParseContext* c)
{
	Ast* if_ast = new_ast_token(c, IF_STMT);
	advance_and_verify(c, IF);
	if (!assign_declid_ok(&if_ast.if_stmt.flow.label, parse_optional_label(c, if_ast))) return poisoned_ast;
	if (!expect_advance(c, LPAREN)) return poisoned_ast;
	if (!assign_exprid_ok(&if_ast.if_stmt.cond, parse_cond(c))) return poisoned_ast;
	uint row = c.span.row;
	if (!tok_is(c, RPAREN))
	{
		switch (c.tok)
		{
			case IDENT:
			case CONST:
				@print_error_here(c, "Finding an identifier here was surprising - did you forget '||' or '&&' or the ending ')' character?");
				return poisoned_ast;
			default:
				break;
		}
	}
	if (!expect_advance(c, RPAREN)) return poisoned_ast;

	uint next_row = c.span.row;
	if (!check_has_body(c, "an if")) return poisoned_ast;
	if (!assign_astid_ok(&if_ast.if_stmt.then_body, parse_stmt(c))) return poisoned_ast;
	if (row != next_row && astptr(if_ast.if_stmt.then_body).ast_kind != COMPOUND_STMT)
	{
		// Poison it and pick it up later.
		ast_poison(astptr(if_ast.if_stmt.then_body));
	}
	if (try_consume(c, ELSE))
	{
		if (!check_has_body(c, "an else")) return poisoned_ast;
		if (!assign_astid_ok(&if_ast.if_stmt.else_body, parse_stmt(c))) return poisoned_ast;
	}
	return if_ast;
}

<*
 case_stmt
 	: CASE expression ':' case_stmts
 	| CASE expression DOTDOT expression ':' case_stmts
 	| CAST type ':' case_stmts
 	;
*>
fn Ast* parse_case_stmt(ParseContext* c, TokenType case_type, TokenType default_type, int index)
{
	Ast* ast = new_ast_token(c, CASE_STMT);
	advance(c);
	Expr* expr = parse_expr(c);
	if (!expr_ok(expr)) return poisoned_ast;
	ast.case_stmt.expr = exprid(expr);
	ast.case_stmt.index = index;
	// Change type -> type.typeid
	if (expr.expr_kind == TYPEINFO)
	{
		// Fold constant immediately
		if (expr.type_expr.resolve_status == DONE)
		{
			Type* cond_val = expr.type_expr.type;
			expr.expr_kind = CONST;
			expr.const_expr.const_kind = TYPEID;
			expr.const_expr.typeid_type = cond_val.canonical;
			expr.type = type_typeid;
		}
		else
		{
			expr.expr_kind = TYPEID;
		}
	}
	if (try_consume(c, DOTDOT))
	{
		if (!assign_exprid_ok(&ast.case_stmt.to_expr, parse_expr(c))) return poisoned_ast;
	}
	uint row = c.span.row;
	if (!try_consume(c, COLON))
	{
		@print_error_at_loc(&c.prev_span, "Missing ':' after case");
		return poisoned_ast;
	}
	range_extend_prev(c, ast.loc);
	if (!assign_ast_ok(&ast.case_stmt.body, parse_case_stmts(c, case_type, default_type, row))) return poisoned_ast;
	return ast;
}

<*
 default_stmt
  : DEFAULT ':' case_stmts
*>
fn Ast* parse_default_stmt(ParseContext* c, TokenType case_type, TokenType default_type, int index)
{
	Ast* ast = new_ast_token(c, DEFAULT_STMT);
	ast.case_stmt.index = index;
	advance(c);
	if (!@consume(c, COLON, "Expected ':' after 'default'.")) return poisoned_ast;
	uint row = c.span.row;
	range_extend_prev(c, ast.loc);
	if (!assign_ast_ok(&ast.case_stmt.body, parse_case_stmts(c, case_type, default_type, row))) return poisoned_ast;
	ast.case_stmt.expr = 0;
	return ast;
}

<*
 switch_body
  : case_stmt
  | default_stmt
  | case_stmt switch_body
  | default_stmt switch body
  ;
*>
fn bool parse_switch_body(ParseContext* c, Ast*[]* cases, TokenType case_type, TokenType default_type)
{
	if (!expect_advance(c, LBRACE)) return false;
	int index = 0;
	while (!try_consume(c, RBRACE))
	{
		Ast* result;
		TokenType tok = c.tok;
		if (tok == case_type)
		{
			if (!assign_ast_ok(&result, parse_case_stmt(c, case_type, default_type, index))) return false;
		}
		else if (tok == default_type)
		{
			if (!assign_ast_ok(&result, parse_default_stmt(c, case_type, default_type, index))) return false;
		}
		else
		{
			@print_error_here(c, "A 'case' or 'default' would be needed here.");
			return false;
		}
		@vec_add(cases, result);
		index++;
	}
	return true;
}

<* switch ::= SWITCH optional_label ('(' cond ')')? switch_body *>
fn Ast* parse_switch_stmt(ParseContext* c)
{
	Ast* switch_ast = new_ast_token(c, SWITCH_STMT);
	advance_and_verify(c, SWITCH);
	if (!assign_declid_ok(&switch_ast.switch_stmt.flow.label, parse_optional_label(c, switch_ast))) return poisoned_ast;
	if (!try_consume(c, LPAREN))
	{
		switch_ast.switch_stmt.cond = 0;
	}
	else
	{
		if (!assign_exprid_ok(&switch_ast.switch_stmt.cond, parse_cond(c))) return poisoned_ast;
		if (!expect_advance(c, RPAREN)) return poisoned_ast;
	}
	if (tok_is(c, AT_IDENT))
	{
		if (symstr(c).ptr != kw_at_jump.ptr)
		{
			@print_error_here(c, "Only '@jump' is allowed after a switch.");
			return poisoned_ast;
		}
		switch_ast.switch_stmt.flow.jump = true;
		advance(c);
	}

	if (!parse_switch_body(c, &switch_ast.switch_stmt.cases, CASE, DEFAULT)) return poisoned_ast;
	return switch_ast;
}

<* for_stmt ::= IF optional_label '(' expression_list? ';' cond? ';' expression_list? ')' statement *>
fn Ast* parse_for_stmt(ParseContext* c)
{
	Ast* ast = new_ast_token(c, FOR_STMT);
	advance_and_verify(c, FOR);

	// Label
	if (!assign_declid_ok(&ast.for_stmt.flow.label, parse_optional_label(c, ast))) return poisoned_ast;

	if (!expect_advance(c, LPAREN)) return poisoned_ast;
	if (try_consume(c, EOS))
	{
		ast.for_stmt.init = 0;
	}
	else
	{
		if (!assign_exprid_ok(&ast.for_stmt.init, parse_expression_list(c, true))) return poisoned_ast;
		if (!consume_eos(c)) return poisoned_ast;
	}

	if (try_consume(c, EOS))
	{
		ast.for_stmt.cond = 0;
	}
	else
	{
		if (!assign_exprid_ok(&ast.for_stmt.cond, parse_cond(c))) return poisoned_ast;
		if (!consume_eos(c)) return poisoned_ast;
	}

	if (try_consume(c, RPAREN))
	{
		ast.for_stmt.incr = 0;
	}
	else
	{
		if (!assign_exprid_ok(&ast.for_stmt.incr, parse_expression_list(c, false))) return poisoned_ast;
		if (!expect_advance(c, RPAREN)) return poisoned_ast;
	}

	// Ast range does not include the body
	range_extend_prev(c, ast.loc);
	uint row = c.prev_span.row;
	if (!check_has_body(c, "a for")) return poisoned_ast;
	Ast* body = parse_stmt(c);
	if (!ast_ok(body)) return poisoned_ast;
	if (body.ast_kind != COMPOUND_STMT && row != sourcelocptr(body.loc).row)
	{
		@print_error_at(body.loc, "A single statement after 'for' must be placed on the same line, or be enclosed in {}.");
		return poisoned_ast;
	}
	ast.for_stmt.body = astid(body);
	return ast;
}

<* foreach_var ::= optional_type? '&'? IDENT *>
fn bool parse_foreach_var(ParseContext* c, Ast* foreach_)
{
	TypeInfo* type = null;

	// If we don't get foreach (foo ... or foreach (*foo ... then a type is expected.
	bool is_by_ref = try_consume(c, AMP);
	Expr* expr = parse_type_or_identifier(c);
	if (!expr_ok(expr)) return false;
	Decl* var_;
	if (expr.expr_kind == TYPEINFO)
	{
		if (is_by_ref)
		{
			@print_error_at(expr.loc, "Expected an identifier after '&'.");
			return false;
		}
		type = expr.type_expr;
		is_by_ref = try_consume(c, AMP);
		var_ = decl_new_var_loc(symstr(c), &c.span, type, LOCAL);
		if (!try_consume(c, IDENT)) return @print_error_here(c, "Expected an identifier after the type.");
	}
	else
	{
		if (!expr_is_plain_identifier(expr))
		{
			@print_error_at(expr.loc, "Expected a plain identifier after '&'.");
			return false;
		}
		var_ = decl_new_var(expr.unresolved_ident_expr.ident, expr.loc, null, LOCAL);
	}
	if (is_by_ref) foreach_.foreach_stmt.value_by_ref = true;
	foreach_.foreach_stmt.variable = declid(var_);
	return true;
}

<*
 foreach_stmt ::= (FOREACH | FOREACH_R) optional_label '(' foreach_vars ':' expression ')' statement
 foreach_vars ::= foreach_var (',' foreach_var)?
*>
fn Ast* parse_foreach_stmt(ParseContext* c)
{
	Ast* ast = new_ast_token(c, FOREACH_STMT);

	ast.foreach_stmt.is_reverse = try_consume(c, FOREACH_R);
	if (!ast.foreach_stmt.is_reverse)
	{
		advance_and_verify(c, FOREACH);
	}

	if (!assign_declid_ok(&ast.foreach_stmt.flow.label, parse_optional_label(c, ast))) return poisoned_ast;
	if (!expect_advance(c, LPAREN)) return poisoned_ast;

	// Parse the first variable.
	if (!parse_foreach_var(c, ast)) return poisoned_ast;

	// Do we have a second variable?
	if (try_consume(c, COMMA))
	{
		// Copy the first variable to "index"
		ast.foreach_stmt.index = ast.foreach_stmt.variable;
		ast.foreach_stmt.index_by_ref = ast.foreach_stmt.value_by_ref;
		ast.foreach_stmt.value_by_ref = false;

		// Parse the second variable
		if (!parse_foreach_var(c, ast)) return poisoned_ast;
	}

	if (!expect_advance(c, COLON)) return poisoned_ast;

	if (!assign_exprid_ok(&ast.foreach_stmt.enumeration, parse_expr(c))) return poisoned_ast;

	if (!expect_advance(c, RPAREN)) return poisoned_ast;

	range_extend_prev(c, ast.loc);
	if (!check_has_body(c, "a foreach")) return poisoned_ast;
	if (!assign_astid_ok(&ast.foreach_stmt.body, parse_stmt(c))) return poisoned_ast;
	return ast;
}

<* continue_stmt ::= CONTINUE optional_label_target ';' *>
fn Ast* parse_continue_stmt(ParseContext* c)
{
	Ast* ast = new_ast_token(c, CONTINUE_STMT);
	advance_and_verify(c, CONTINUE);
	parse_optional_label_target(c, &ast.contbreak_stmt.label);
	if (ast.contbreak_stmt.label.name.ptr) ast.contbreak_stmt.is_label = true;
	range_extend_prev(c, ast.loc);
	if (!consume_eos(c)) return poisoned_ast;
	return ast;
}

<* next ::= NEXTCASE ((CONST_IDENT ':')? expression)? ';' *>
fn Ast* parse_nextcase_stmt(ParseContext* c)
{
	Ast* ast = new_ast_token(c, NEXTCASE_STMT);
	advance_and_verify(c, NEXTCASE);
	if (try_consume(c, EOS))
	{
		return ast;
	}
	if (tok_is(c, CONST_IDENT) && peek(c) == COLON)
	{
		parse_optional_label_target(c, &ast.nextcase_stmt.label);
		advance_and_verify(c, COLON);
	}
	if (try_consume(c, DEFAULT))
	{
		ast.nextcase_stmt.is_default = true;
	}
	else
	{
		if (!assign_exprid_ok(&ast.nextcase_stmt.expr, parse_expr(c))) return poisoned_ast;
	}
	if (!consume_eos(c)) return poisoned_ast;
	return ast;
}

<* break_stmt ::= BREAK optional_label_target ';' *>
fn Ast* parse_break_stmt(ParseContext* c)
{
	Ast* ast = new_ast_token(c, BREAK_STMT);
	advance_and_verify(c, BREAK);
	parse_optional_label_target(c, &ast.contbreak_stmt.label);
	if (ast.contbreak_stmt.label.name.ptr) ast.contbreak_stmt.is_label = true;
	range_extend_prev(c, ast.loc);
	if (!consume_eos(c)) return poisoned_ast;
	return ast;
}

<*
 expr_stmt
  : expression EOS
  ;
*>
fn Ast* parse_expr_stmt(ParseContext* c)
{
	Ast* stmt = new_ast_token(c, EXPR_STMT);
	if (!assign_expr_ok(&stmt.expr_stmt, parse_expr(c))) return poisoned_ast;
	range_extend_prev(c, stmt.loc);
	if (!consume_eos(c)) return poisoned_ast;
	return stmt;
}

fn Ast* parse_ct_type_assign_stmt(ParseContext* c)
{
	Ast* stmt = new_ast_token(c, CT_TYPE_ASSIGN_STMT);
	stmt.ct_type_assign_stmt.var_name = symstr(c);
	advance_and_verify(c, CT_TYPE_IDENT);
	advance_and_verify(c, EQ);
	if (!assign_expr_ok(&stmt.ct_type_assign_stmt.type_expr, parse_expr(c))) return poisoned_ast;
	if (!consume_eos(c)) return poisoned_ast;
	return stmt;
}

fn Ast* parse_decl_or_expr_stmt(ParseContext* c)
{
	if (tok_is(c, CT_TYPE_IDENT) && peek(c) == EQ)
	{
		return parse_ct_type_assign_stmt(c);
	}
	Expr* expr = parse_expr(c);
	if (!expr_ok(expr)) return poisoned_ast;
	if (expr.expr_kind == TYPEINFO)
	{
		Ast* decl_ast = parse_decl_stmt_after_type(c, expr.type_expr);
		if (!ast_ok(decl_ast)) return poisoned_ast;
		if (!consume_eos(c)) return poisoned_ast;
		return decl_ast;
	}
	Ast* ast = ast_calloc();
	ast.loc = expr.loc;
	ast.ast_kind = EXPR_STMT;
	ast.expr_stmt = expr;
	if (tok_is(c, IDENT) && expr.expr_kind == UNRESOLVED_IDENTIFIER)
	{
		@print_error_at(expr.loc, "Expected a type here.");
		return poisoned_ast;
	}
	if (!consume_eos(c)) return poisoned_ast;
	return ast;
}

<*
 var_stmt
  : var CT_IDENT '=' const_expr EOS
  | var CT_TYPE '=' const_expr EOS
  ;
*>
fn Ast* parse_var_stmt(ParseContext* c)
{
	Ast* ast = new_ast_token(c, DECLARE_STMT);
	if (!assign_decl_ok(&ast.var_stmt, parse_var_decl(c))) return poisoned_ast;
	range_extend_prev(c, ast.loc);
	if (!consume_eos(c)) return poisoned_ast;
	return ast;
}

fn bool parse_ct_compound_stmt(ParseContext* c, AstId* start, Ast* start_if)
{
	AstId* next = start;
	while (true)
	{
		TokenType tok = c.tok;
		if (tok == CT_ELSE || tok == CT_ENDIF) break;
		if (tok == RBRACE || tok == EOF)
		{
			@print_error_here(c, "Expected '$endif' for '$if'");
			@sema_note_prev_at(start_if.loc, "The unterminated '$if' was here.");
			return false;
		}
		Ast* stmt = parse_stmt(c);
		if (!ast_ok(stmt)) return false;
		ast_append(&next, stmt);
	}
	return true;
}

<*
 ct_if_stmt
 	: CT_IF expression ':' ct_compound_stmt (ct_elif_stmt | ct_else_stmt) CT_ENDIF EOS
 	;
*>
fn Ast* parse_ct_if_stmt(ParseContext* c)
{
	Ast* ast = ast_new_curr(c, CT_IF_STMT);

	advance_and_verify(c, CT_IF);

	if (!assign_expr_ok(&ast.ct_if_stmt.expr, parse_expr(c))) return poisoned_ast;
	if (!expect_advance(c, COLON)) return poisoned_ast;
	if (!parse_ct_compound_stmt(c, &ast.ct_if_stmt.then, ast)) return poisoned_ast;

	if (tok_is(c, CT_ELSE))
	{
		Ast* else_ast = new_ast_token(c, CT_ELSE_STMT);
		advance_and_verify(c, CT_ELSE);
		if (!parse_ct_compound_stmt(c, &else_ast.ct_else_stmt, ast)) return poisoned_ast;
		ast.ct_if_stmt.elif = astid(else_ast);
	}
	if (!expect_advance(c, CT_ENDIF)) return poisoned_ast;
	range_extend_prev(c, ast.loc);
	return ast;
}

<*
 return
  : RETURN expression
 	| RETURN
 	;
*>
fn Ast* parse_return_stmt(ParseContext* c)
{
	advance_and_verify(c, RETURN);
	Ast* ast = ast_new_curr(c, RETURN_STMT);
	if (!tok_is(c, EOS))
	{
		if (!assign_expr_ok(&ast.return_stmt.expr, parse_expr(c))) return poisoned_ast;
		range_extend_prev(c, ast.loc);
	}
	if (!consume_eos(c)) return poisoned_ast;
	return ast;
}

<* ct_expand_stmt :: CT_EXPAND '(' expr ')' *>
fn Ast* parse_ct_expand_stmt(ParseContext* c)
{
	Ast* ast = ast_new_curr(c, CT_EXPAND_STMT);
	advance_and_verify(c, CT_EXPAND);
	if (!expect_advance(c, LPAREN)) return poisoned_ast;
	if (!assign_expr_ok(&ast.expand_stmt, parse_expr(c))) return poisoned_ast;
	if (!expect_advance(c, RPAREN)) return poisoned_ast;
	if (!consume_eos(c)) return poisoned_ast;
	return ast;
}

<* ct_foreach_stmt ::= CT_FOREACH CT_IDENT (',' CT_IDENT)? ':' expr ':' statement* CT_ENDFOREACH *>
fn Ast* parse_ct_foreach_stmt(ParseContext* c)
{
	Ast* ast = new_ast_token(c, CT_FOREACH_STMT);
	advance_and_verify(c, CT_FOREACH);
	if (peek(c) == COMMA)
	{
		Decl* index = decl_new_var_loc(symstr(c), &c.span, null, LOCAL_CT);
		ast.ct_foreach_stmt.index = declid(index);
		if (!@consume(c, CT_IDENT, "Expected a compile time index variable")) return poisoned_ast;
		advance_and_verify(c, COMMA);
	}
	ast.ct_foreach_stmt.value = declid(decl_new_var_loc(symstr(c), &c.span, null, LOCAL_CT));
	if (!@consume(c, CT_IDENT, "Expected a compile time variable")) return poisoned_ast;
	if (!@consume(c, COLON, "Expected ':'.")) return poisoned_ast;
	if (!assign_exprid_ok(&ast.ct_foreach_stmt.expr, parse_expr(c))) return poisoned_ast;
	if (!@consume(c, COLON, "Expected ':'.")) return poisoned_ast;
	Ast* body = new_ast(CT_COMPOUND_STMT, ast.loc);
	ast.ct_foreach_stmt.body = astid(body);
	AstId* current = &body.ct_compound_stmt;
	while (!try_consume(c, CT_ENDFOREACH))
	{
		Ast* stmt = parse_stmt(c);
		if (!ast_ok(stmt)) return poisoned_ast;
		*current = astid(stmt);
		current = &stmt.next;
	}
	return ast;
}

<*
 ct_for_stmt
  | CT_FOR decl_expr_list? ';' expression_list? ';' expression_list? ':' statement* CT_ENDFOR
  ;
*>
fn Ast* parse_ct_for_stmt(ParseContext* c)
{
	Ast* ast = ast_new_curr(c, CT_FOR_STMT);
	advance_and_verify(c, CT_FOR);

	if (!tok_is(c, EOS))
	{
		if (!assign_exprid_ok(&ast.for_stmt.init, parse_ct_expression_list(c, true))) return poisoned_ast;
	}
	if (!consume_eos(c)) return poisoned_ast;

	// Cond is required.
	if (!assign_exprid_ok(&ast.for_stmt.cond, parse_expr(c))) return poisoned_ast;
	if (!consume_eos(c)) return poisoned_ast;

	if (!tok_is(c, COLON))
	{
		if (!assign_exprid_ok(&ast.for_stmt.incr, parse_ct_expression_list(c, false))) return poisoned_ast;
	}

	if (!expect_advance(c, COLON)) return poisoned_ast;

	Ast* body = new_ast(CT_COMPOUND_STMT, ast.loc);
	ast.for_stmt.body = astid(body);
	AstId* current = &body.ct_compound_stmt;
	while (!try_consume(c, CT_ENDFOR))
	{
		Ast* stmt = parse_stmt(c);
		if (!ast_ok(stmt)) return poisoned_ast;
		*current = astid(stmt);
		current = &stmt.next;
	}
	return ast;
}

<*
 ct_switch_stmt ::= CT_SWITCH const_expr? ':' ct_case_statement* CT_ENDSWITCH

 ct_case_statement ::= (CT_CASE constant_expr | CT_DEFAULT) ':' opt_stmt_list
*>
fn Ast* parse_ct_switch_stmt(ParseContext* c)
{
	Ast* ast = ast_new_curr(c, CT_SWITCH_STMT);
	advance_and_verify(c, CT_SWITCH);
	if (!tok_is(c, COLON))
	{
		if (tok_is(c, CT_CASE))
		{
			@print_error_last(c, "Expected ':' after '$switch'.");
			return poisoned_ast;
		}
		if (!assign_exprid_ok(&ast.ct_switch_stmt.cond, parse_constant_expr(c))) return poisoned_ast;
	}
	if (!expect_advance(c, COLON)) return poisoned_ast;
	Ast*[] cases;
	while (!try_consume(c, CT_ENDSWITCH))
	{
		Ast* result;
		TokenType tok = c.tok;
		if (tok == CT_CASE)
		{
			if (!assign_ast_ok(&result, parse_case_stmt(c, CT_CASE, CT_DEFAULT, 0))) return poisoned_ast;
		}
		else if (tok == CT_DEFAULT)
		{
			if (!assign_ast_ok(&result, parse_default_stmt(c, CT_CASE, CT_DEFAULT, 0))) return poisoned_ast;
		}
		else
		{
			@print_error_here(c, "A '$case' or '$default' would be needed here.");
			return poisoned_ast;
		}
		@vec_add(&cases, result);
	}
	ast.ct_switch_stmt.body = cases;
	return ast;
}

<* c3c parse_stmt.c `consume_eos(ParseContext*, Ast*)` (renamed, see header). *>
fn Ast* consume_eos_ast(ParseContext* c, Ast* ast)
{
	if (!try_consume(c, EOS))
	{
		@print_error_after(&c.prev_span, "Expected a ';' here.");
		advance(c);
		return poisoned_ast;
	}
	return ast;
}

<* assert_stmt ::= ASSERT '(' assert_expr (',' expr)? ')' ';' *>
fn Ast* parse_assert_stmt(ParseContext* c)
{
	Ast* ast = ast_new_curr(c, ASSERT_STMT);
	advance_and_verify(c, ASSERT);
	if (!@consume(c, LPAREN, "'assert' needs a '(' here, did you forget it?")) return poisoned_ast;
	if (!assign_exprid_ok(&ast.assert_stmt.expr, parse_expr(c))) return poisoned_ast;

	if (try_consume(c, COMMA))
	{
		Expr*[] args;
		if (!assign_exprid_ok(&ast.assert_stmt.message, parse_constant_expr(c))) return poisoned_ast;
		while (try_consume(c, COMMA))
		{
			Expr* expr = parse_expr(c);
			if (!expr_ok(expr)) return poisoned_ast;
			@vec_add(&args, expr);
		}
		ast.assert_stmt.args = args;
	}
	if (!@consume(c, RPAREN, "The ending ')' was expected here.")) return poisoned_ast;
	return consume_eos_ast(c, ast);
}

// --- External functions

<* ct_assert_stmt ::= CT_ASSERT constant_expression (':' constant_expression (',' constant_expression)*)? ';' *>
fn Ast* parse_ct_assert_stmt(ParseContext* c)
{
	Ast* ast = ast_new_curr(c, CT_ASSERT);
	advance_and_verify(c, CT_ASSERT);
	if (!assign_exprid_ok(&ast.assert_stmt.expr, parse_constant_expr(c))) return poisoned_ast;
	if (try_consume(c, COLON))
	{
		if (!assign_exprid_ok(&ast.assert_stmt.message, parse_constant_expr(c))) return poisoned_ast;
		while (try_consume(c, COMMA))
		{
			Expr* expr = parse_constant_expr(c);
			if (!expr_ok(expr)) return poisoned_ast;
			@vec_add(&ast.assert_stmt.args, expr);
		}
	}
	return consume_eos_ast(c, ast);
}

<* ct_error_stmt ::= CT_ERROR constant_expression (',' constant_expression)* ';' *>
fn Ast* parse_ct_error_stmt(ParseContext* c)
{
	Ast* ast = ast_new_curr(c, CT_ASSERT);
	advance_and_verify(c, CT_ERROR);
	ast.assert_stmt.expr = 0;
	if (!assign_exprid_ok(&ast.assert_stmt.message, parse_constant_expr(c))) return poisoned_ast;
	while (try_consume(c, COMMA))
	{
		Expr* expr = parse_constant_expr(c);
		if (!expr_ok(expr)) return poisoned_ast;
		@vec_add(&ast.assert_stmt.args, expr);
	}
	return consume_eos_ast(c, ast);
}

fn Ast* parse_ct_echo_stmt(ParseContext* c)
{
	Ast* ast = ast_new_curr(c, CT_ECHO_STMT);
	advance_and_verify(c, CT_ECHO);
	if (!assign_expr_ok(&ast.expr_stmt, parse_constant_expr(c))) return poisoned_ast;
	return consume_eos_ast(c, ast);
}

fn Ast* parse_stmt(ParseContext* c)
{
	switch (c.tok)
	{
		case LBRACE:
			return parse_compound_stmt(c);
		case VOID..UNTYPEDLIST: // TYPELIKE_TOKENS
		case TYPE_IDENT:
		case CT_TYPE_IDENT:
		case CT_TYPEOF:
		case CT_TYPEFROM:
		case HASH_IDENT:
		case IDENT:
		case CONST_IDENT:
			return parse_decl_or_expr_stmt(c);
		case VAR:
			return parse_var_stmt(c);
		case TLOCAL:   // Global means declaration!
		case STATIC:   // Static means declaration!
		case CONST:    // Const means declaration!
			return parse_declaration_stmt(c);
		case RETURN:
			return parse_return_stmt(c);
		case IF:
			return parse_if_stmt(c);
		case WHILE:
			return parse_while_stmt(c);
		case DEFER:
			return parse_defer_stmt(c);
		case SWITCH:
			return parse_switch_stmt(c);
		case DO:
			return parse_do_stmt(c);
		case FOR:
			return parse_for_stmt(c);
		case FOREACH:
		case FOREACH_R:
			return parse_foreach_stmt(c);
		case CONTINUE:
			return parse_continue_stmt(c);
		case CASE:
			@print_error_here(c, "'case' was found outside of 'switch', did you mismatch a '{ }' pair?");
			advance(c);
			return poisoned_ast;
		case BREAK:
			return parse_break_stmt(c);
		case NEXTCASE:
			return parse_nextcase_stmt(c);
		case ASM:
			return parse_asm_block_stmt(c);
		case DEFAULT:
			@print_error_here(c, "'default' was found outside of 'switch', did you mismatch a '{ }' pair?");
			advance(c);
			return poisoned_ast;
		case CT_ECHO:
			return parse_ct_echo_stmt(c);
		case CT_ASSERT:
			return parse_ct_assert_stmt(c);
		case CT_ERROR:
			return parse_ct_error_stmt(c);
		case CT_EXPAND:
			return parse_ct_expand_stmt(c);
		case CT_IF:
			return parse_ct_if_stmt(c);
		case CT_SWITCH:
			return parse_ct_switch_stmt(c);
		case CT_FOREACH:
			return parse_ct_foreach_stmt(c);
		case CT_FOR:
			return parse_ct_for_stmt(c);
		case AMP:
		case AT:
		case AT_CONST_IDENT:
		case AT_IDENT:
		case AT_TYPE_IDENT:
		case BANG:
		case BIT_NOT:
		case BIT_OR:
		case BIT_XOR:
		case BUILTIN:
		case BYTES:
		case CHAR_LITERAL:
		case CT_AND:
		case CT_CONCAT:
		case CT_CONCAT_ASSIGN:
		case CT_CONST_IDENT:
		case CT_DEFINED:
		case CT_EMBED:
		case CT_EVAL:
		case CT_FEAT:
		case CT_FEATURE:
		case CT_IDENT:
		case CT_OR:
		case CT_REFLECT:
		case CT_STRINGIFY:
		case CT_TERNARY:
		case CT_VAARG:
		case FALSE:
		case INTEGER:
		case LENGTHOF:
		case LPAREN:
		case MINUS:
		case MINUSMINUS:
		case NULL:
		case OR:
		case PLUS:
		case PLUSPLUS:
		case REAL:
		case STAR:
		case STRING:
		case TRUE:
			return parse_expr_stmt(c);
		case ASSERT:
			return parse_assert_stmt(c);
		case INVALID_TOKEN:
			advance(c);
			return poisoned_ast;
		case ALIAS:
		case AND:
		case ARROW:
		case ATTRDEF:
		case ATTRMACRO:
		case BANGBANG:
		case BITSTRUCT:
		case BIT_AND_ASSIGN:
		case BIT_OR_ASSIGN:
		case BIT_XOR_ASSIGN:
		case CONSTDEF:
		case CONSTSET:
		case COLON:
		case COMMA:
		case CT_CASE:
		case CT_DEFAULT:
		case CT_ELSE:
		case CT_ENDFOR:
		case CT_ENDFOREACH:
		case CT_ENDIF:
		case CT_ENDSWITCH:
		case CT_EXEC:
		case CT_INCLUDE:
		case DIV:
		case DIV_ASSIGN:
		case DOCS_END:
		case DOCS_START:
		case DOC_COMMENT:
		case DOLLAR:
		case DOT:
		case DOTDOT:
		case ELLIPSIS:
		case ELSE:
		case ELVIS:
		case ENUM:
		case EQ:
		case EQEQ:
		case EXTERN:
		case FAULTDEF:
		case FN:
		case GREATER:
		case GREATER_EQ:
		case HASH:
		case IMPLIES:
		case IMPORT:
		case INLINE:
		case INTERFACE:
		case LBRACKET:
		case LESS:
		case LESS_EQ:
		case LVEC:
		case MACRO:
		case MINUS_ASSIGN:
		case MOD:
		case MODULE:
		case MOD_ASSIGN:
		case MULT_ASSIGN:
		case NOT_EQUAL:
		case PLUS_ASSIGN:
		case QUESTION:
		case QUESTQUEST:
		case RVEC:
		case SCOPE:
		case SHL:
		case SHL_ASSIGN:
		case SHR:
		case SHR_ASSIGN:
		case STRUCT:
		case TYPEDEF:
		case UNDERSCORE:
		case UNION:
			@print_error_here(c, "Unexpected '%s' found when expecting a statement.",
								 token_type_to_string(c.tok));
			advance(c);
			return poisoned_ast;
		case RPAREN:
		case RBRACE:
		case RBRACKET:
			@print_error_here(c, "Mismatched '%s' found.", token_type_to_string(c.tok));
			advance(c);
			return poisoned_ast;
		case TRY:
		case CATCH:
			@print_error_here(c, "'%s' can only be used when unwrapping an optional, did you mean '%s?'?", token_type_to_string(c.tok), token_type_to_string(c.tok));
			advance(c);
			return poisoned_ast;
		case EOS:
		{
			Ast* nop = ast_new_curr(c, NOP_STMT);
			advance(c);
			return nop;
		}
		case EOF:
			@print_error_here(c, "Reached the end of the file when expecting a statement.");
			return poisoned_ast;
		case DOCS_EOL:
			@print_error_here(c, "Unexpectedly reached end of line.");
			return poisoned_ast;
	}
}

<*
 compound_stmt
  : '{' stmt_list '}'
  ;

 stmt_list
  : stmt
  | stmt stmt_list
  ;

 @return "a compound statement"
*>
fn Ast* parse_compound_stmt(ParseContext* c)
{
	Ast* ast = ast_new_curr(c, COMPOUND_STMT);
	if (!expect_advance(c, LBRACE)) return poisoned_ast;
	AstId* next = &ast.compound_stmt.first_stmt;
	while (!try_consume(c, RBRACE))
	{
		Ast* stmt = parse_stmt(c);
		if (!ast_ok(stmt)) return poisoned_ast;
		ast_append(&next, stmt);
	}
	ast.compound_stmt.end_loc = make_loc(c.prev_span);
	range_extend_prev(c, ast.loc);
	return ast;
}

<*
 We're parsing "=> bar();" in the case of a "lambda" but also in case we have the short form
 starting with a macro with a body, so "=> @pool() {", we should avoid parsing the ";"
 In the lambda case that's part of the expression EOS, in the other case we're simply removing it.
*>
fn Ast* parse_short_body(ParseContext* c, Decl* func_or_macro, bool is_lambda)
{
	// Advance past the =>
	advance(c);

	// We create the synthetic compound stmt
	Ast* ast = ast_new_curr(c, COMPOUND_STMT);
	AstId* next = &ast.compound_stmt.first_stmt;

	// Create a return and append it.
	Ast* ret = ast_new_curr(c, RETURN_STMT);
	ast_append(&next, ret);

	// Let's grab the rtype to figure out whether it's a plain `void`
	TypeInfo* rtype = type_infoptrzero(func_or_macro.func_decl.signature.rtype);
	bool is_void_return = rtype && rtype.resolve_status == DONE && type_is_void(rtype.type);

	// Parse the expression inside.
	Expr* expr = parse_expr(c);
	if (!expr_ok(expr)) return poisoned_ast;

	// Copy the return location to the expression.
	ret.loc = expr.loc;

	// If we have "@pool() { }", then we parse this in a special way
	// and discard the `;`
	if (expr.expr_kind == CALL && expr.call_expr.macro_body)
	{
		ret.ast_kind = EXPR_STMT;
		ret.expr_stmt = expr;
		expr.call_expr.is_outer_call = true;
		return ast;
	}

	// If it's not a lambda, consume the `;`
	if (!is_lambda && !consume_eos(c)) return poisoned_ast;

	// In the case of void return, we can optimize
	// it by not having a return.
	if (is_void_return)
	{
		ret.ast_kind = EXPR_STMT;
		ret.expr_stmt = expr;
	}
	else
	{
		// Assign the expression to the return.
		ret.return_stmt.expr = expr;
	}
	return ast;
}
