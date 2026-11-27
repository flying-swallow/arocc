// Port of c3c src/compiler/parse_expr.c: the Pratt expression parser
// (`rules` table), literals, initializer lists, calls, lambdas, try/catch
// unwraps and the compile-time expression forms.
//
// c3c's returning macros are expanded as described in parser.c3; when an
// ASSIGN_*_OR_RET targets an existing lvalue the `assign_*_ok` helpers of
// parse_expr_support.c3 are used.
//
// Deviations from c3c:
// - `goto DONE` / `goto EXIT` / `goto ERROR` / `goto ADVANCE` are
//   restructured (if/else chains, labelled loops, flags).
// - Int128 math is native uint128 (`ixx.high` is `ixx >> 64`).
// - PRINT_ERROR_HERE(err) with a runtime message is `"%s", err`.
// - `parse_range`, `parse_vasplat` and `parse_init_list` are non-static in
//   c3c but not exported by a header; they stay plain module functions here.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;
import std::core::mem;

alias ParseFn = fn Expr*(ParseContext* c, Expr* left, SourceLoc* lhs_start);

struct ParseRule
{
	ParseFn prefix;
	ParseFn infix;
	Precedence precedence;
}

fn bool parse_current_is_expr(ParseContext* c)
{
	return rules[c.tok.ordinal].prefix != null;
}

<*
 maybe_range ::= range | ('^'? INTEGER)
 range ::= dot_range | colon_range
 dot_range ::= ('^'? INTEGER)? .. ('^'? INTEGER)?
 colon_range ::= ('^'? INTEGER)? : ('^'? INTEGER)?
*>
fn bool parse_range(ParseContext* c, ExprRange* range)
{
	SourceLoc start = c.span;
	// Insert zero if missing
	if (tok_is(c, DOTDOT) || tok_is(c, COLON))
	{
		// ..123 and :123
		range.start_from_end = false;
		range.start = exprid(expr_new_const_int(make_loc(c.span), type_uint, 0));
	}
	else
	{
		// Parse ^123 and 123
		range.start_from_end = try_consume(c, BIT_XOR);
		if (!assign_exprid_ok(&range.start, parse_expr(c))) return false;
	}
	// Check if .. or :
	bool is_len_range = range.is_len = try_consume(c, COLON);
	if (!is_len_range && !try_consume(c, DOTDOT))
	{
		// Otherwise this is a single element
		range.range_type = SINGLE_ELEMENT;
		return true;
	}
	// Is there an expression next?
	range.end_from_end = try_consume(c, BIT_XOR);
	if (range.end_from_end || parse_current_is_expr(c))
	{
		if (!assign_exprid_ok(&range.end, parse_expr(c))) return false;
		return true;
	}

	// Otherwise we have [1..] or [3:]
	if (range.is_len)
	{
		SourceLoc loc = extend_loc_with_token(&start, &c.prev_span);
		@print_error_at_loc(&loc, "Length-ranges using ':' may not elide the length.");
		return false;
	}

	range.end_from_end = false;
	range.end = 0;
	return true;
}

fn bool parse_generic_expr_list(ParseContext* c, Expr*[]* exprs_ref)
{
	advance_and_verify(c, LBRACE);
	if (try_consume(c, RBRACE)) return true;
	do
	{
		Expr* expr = parse_expr(c);
		if (!expr_ok(expr)) return false;
		@vec_add(exprs_ref, expr);
		if (!try_consume(c, COMMA))
		{
			if (!expect_advance(c, RBRACE)) return false;
			return true;
		}
	} while (!try_consume(c, RBRACE));
	return true;
}

<* rethrow_expr ::= call_expr '!' *>
fn Expr* parse_rethrow_expr(ParseContext* c, Expr* left_side, SourceLoc* lhs_start)
{
	assert(expr_ok(left_side));
	advance_and_verify(c, BANG);
	Expr* expr = expr_new_loc(RETHROW, lhs_start);
	expr.rethrow_expr.inner = left_side;
	range_extend_prev(c, expr.loc);
	return expr;
}

<*
 Parse lhs [op] [rhs]
 This will return lhs if no candidate is found.
*>
fn Expr* parse_precedence_with_left_side(ParseContext* c, Expr* left_side, SourceLoc* lhs_start, Precedence precedence)
{
	while (true)
	{
		TokenType tok = c.tok;
		Precedence token_precedence = rules[tok.ordinal].precedence;
		// See if the operator precedence is greater than the last, if so exit.
		// Note that if the token is not an operator then token_precedence = 0
		if (precedence.ordinal > token_precedence.ordinal) break;
		// LHS may be poison.
		if (!expr_ok(left_side)) return left_side;

		// Special rule to prevent = {}.
		if (tok == DOT && left_side.expr_kind == INITIALIZER_LIST) break;

		// See if there is a rule for infix.
		ParseFn infix_rule = rules[tok.ordinal].infix;
		// Otherwise we ran into a symbol that can't appear in this position.
		if (!infix_rule)
		{
			@print_error_here(c, "'%s' can't appear in this position, did you forget something before the operator?", token_type_to_string(tok));
			return poisoned_expr;
		}
		// The rule exists, so run it.
		left_side = infix_rule(c, left_side, lhs_start);
	}
	return left_side;
}

<* Parse an expression in any position. *>
fn Expr* parse_precedence(ParseContext* c, Precedence precedence)
{
	SourceLoc lhs_start = c.span;
	// Get the rule for the previous token.
	ParseFn prefix_rule = rules[c.tok.ordinal].prefix;
	// No prefix rule => either it's not an expression
	// or it is a token that can't be in a prefix position.
	if (!prefix_rule)
	{
		if (c.tok == TRY || c.tok == CATCH)
		{
			@print_error_here(c, "'%s' can only be used in if/while conditionals or defer, it cannot be used standalone.", token_type_to_string(c.tok));
			return poisoned_expr;
		}
		if (token_is_keyword(c.tok))
		{
			@print_error_here(c, "'%s' is a keyword and not an expression, it can't be used here.", token_type_to_string(c.tok));
			return poisoned_expr;
		}
		@print_error_here(c, "An expression was expected.");
		return poisoned_expr;
	}
	// Get the expression
	Expr* left_side = prefix_rule(c, null, null);
	// Exit if it's an error.
	if (!expr_ok(left_side)) return left_side;
	// Now parse the (optional) right hand side.
	return parse_precedence_with_left_side(c, left_side, &lhs_start, precedence);
}

<* Parse anything with higher precedence than && etc. *>
fn Expr* parse_try_chain_expr(ParseContext* c)
{
	return parse_precedence(c, RELATIONAL);
}

<*
 catch_unwrap ::= CATCH (IDENT | type? IDENT '=' catch_chain) | catch_chain
 catch_chain ::= parse_try_catch_rhs_expr (',' parse_try_catch_rhs_expr)*
*>
fn Expr* parse_catch_unwrap(ParseContext* c)
{
	Expr* expr = expr_new(CATCH_UNRESOLVED, make_loc(c.span));
	advance_and_verify(c, CATCH);
	Expr*[] exprs;

	// First, try parsing as single expression
	Expr* sub_expr = parse_try_chain_expr(c);
	if (!expr_ok(sub_expr)) return poisoned_expr;

	// Check if we have a chain.
	if (try_consume(c, COMMA))
	{
		// Create the chain.
		@vec_add(&exprs, sub_expr);
		do
		{
			if (!assign_expr_ok(&sub_expr, parse_try_chain_expr(c))) return poisoned_expr;
			@vec_add(&exprs, sub_expr);
		} while (try_consume(c, COMMA));
		// We're done.
		expr.unresolved_catch_expr.exprs = exprs;
		return expr;
	}

	// We don't have a chain, so it's either "fault f" or "f" or an expression.
	if (sub_expr.expr_kind == TYPEINFO)
	{
		// Assign the type
		expr.unresolved_catch_expr.type = sub_expr.type_expr;
		// Assign the variable
		if (!assign_expr_ok(&expr.unresolved_catch_expr.variable, parse_try_chain_expr(c))) return poisoned_expr;
	}
	else
	{
		// Here we assume it's either "f" or an expression.
		expr.unresolved_catch_expr.type = null;
		expr.unresolved_catch_expr.variable = sub_expr;
	}
	// If we don't have an '=', we check whether
	if (!try_consume(c, EQ))
	{
		// If we had "fault f", then we MUST have '='
		if (expr.unresolved_catch_expr.type)
		{
			@print_error_here(c, "Expected a '=' here.");
			return poisoned_expr;
		}
		// We just have `catch foo`, so we add the "variable" as an expression
		@vec_add(&expr.unresolved_catch_expr.exprs, expr.unresolved_catch_expr.variable);
		expr.unresolved_catch_expr.variable = null;
		range_extend_prev(c, expr.loc);
		return expr;
	}
	// After '=' we have a chain of expressions.
	do
	{
		if (!assign_expr_ok(&sub_expr, parse_try_chain_expr(c))) return poisoned_expr;
		@vec_add(&exprs, sub_expr);
	} while (try_consume(c, COMMA));
	expr.unresolved_catch_expr.exprs = exprs;
	range_extend_prev(c, expr.loc);
	return expr;
}

<* try_unwrap ::= TRY ((type? IDENT '=' try_rhs_expr) | try_rhs_expr) *>
fn Expr* parse_try_unwrap(ParseContext* c)
{
	Expr* expr = expr_new_token(c, TRY_UNRESOLVED);
	advance_and_verify(c, TRY);
	Expr* lhs = parse_try_chain_expr(c);
	if (!expr_ok(lhs)) return poisoned_expr;
	if (lhs.expr_kind == TYPEINFO)
	{
		expr.unresolved_try_expr.type = lhs.type_expr;
		if (!assign_expr_ok(&expr.unresolved_try_expr.variable, parse_try_chain_expr(c))) return poisoned_expr;
	}
	else
	{
		expr.unresolved_try_expr.variable = lhs;
	}
	if (lhs.expr_kind == TYPEINFO && expr.unresolved_try_expr.variable.expr_kind != UNRESOLVED_IDENTIFIER)
	{
		@print_error_at(expr.unresolved_try_expr.variable.loc, "A new variable was expected.");
		return poisoned_expr;
	}
	if (try_consume(c, EQ))
	{
		if (!assign_expr_ok(&expr.unresolved_try_expr.init, parse_try_chain_expr(c))) return poisoned_expr;
	}
	range_extend_prev(c, expr.loc);
	return expr;
}

<* try_unwrap_chain ::= try_unwrap ('&&' (try_unwrap | try_chain_expr))* *>
fn Expr* parse_try_unwrap_chain(ParseContext* c)
{
	Expr*[] unwraps;
	Expr* first_unwrap = parse_try_unwrap(c);
	if (!expr_ok(first_unwrap)) return poisoned_expr;
	@vec_add(&unwraps, first_unwrap);
	while (try_consume(c, AND))
	{
		if (tok_is(c, TRY))
		{
			Expr* expr = parse_try_unwrap(c);
			if (!expr_ok(expr)) return poisoned_expr;
			@vec_add(&unwraps, expr);
			continue;
		}
		Expr* next_unwrap = parse_try_chain_expr(c);
		if (!expr_ok(next_unwrap)) return poisoned_expr;
		@vec_add(&unwraps, next_unwrap);
	}
	Expr* try_unwrap_chain = expr_new_expr(TRY_UNWRAP_CHAIN, first_unwrap);
	try_unwrap_chain.try_unwrap_chain_expr = unwraps;
	range_extend_prev(c, try_unwrap_chain.loc);
	return try_unwrap_chain;
}

<* cond_list ::= ((expr | decl-expr) COMMA)* (expr | decl-expr | try_unwrap_chain | catch_unwrap ) *>
fn Expr* parse_cond(ParseContext* c)
{
	Expr* decl_expr = expr_new_token(c, COND);
	decl_expr.cond_expr = {};
	while (true)
	{
		if (tok_is(c, TRY))
		{
			Expr* try_unwrap = parse_try_unwrap_chain(c);
			if (!expr_ok(try_unwrap)) return poisoned_expr;
			@vec_add(&decl_expr.cond_expr, try_unwrap);
			if (tok_is(c, COMMA))
			{
				@print_error_at(try_unwrap.loc, "The 'try' must be placed last, can you change it?");
				return poisoned_expr;
			}
			break;
		}
		if (tok_is(c, CATCH))
		{
			Expr* catch_unwrap = parse_catch_unwrap(c);
			if (!expr_ok(catch_unwrap)) return poisoned_expr;
			@vec_add(&decl_expr.cond_expr, catch_unwrap);
			if (tok_is(c, COMMA))
			{
				@print_error_at(catch_unwrap.loc, "The 'catch' must be placed last, can you change it?");
				return poisoned_expr;
			}
			break;
		}

		Expr* expr = parse_decl_or_expr(c);
		if (!expr_ok(expr)) return poisoned_expr;
		@vec_add(&decl_expr.cond_expr, expr);
		if (!try_consume(c, COMMA)) break;
	}
	range_extend_prev(c, decl_expr.loc);
	return decl_expr;
}

// These used to be explicitly inlined, but that seems to lead to confusing MSVC linker errors.
// They are probably still inlined by the compiler, though I haven't checked.
fn Expr* parse_expr(ParseContext* c)
{
	return parse_precedence(c, ASSIGNMENT);
}

fn Expr* parse_constant_expr(ParseContext* c)
{
	return parse_precedence(c, Precedence::from_ordinal(Precedence.ASSIGNMENT.ordinal + 1));
}

fn Expr* parse_type_or_identifier(ParseContext* c)
{
	return parse_precedence(c, PRIMARY);
}

<*
 param_path ::= ('[' expr ']' | '.' IDENT)*

 @param [&inout] path : "reference to the path to return"
 @return "true if parsing succeeds, false otherwise."
*>
fn bool parse_param_path(ParseContext* c, DesignatorElement*[]* path)
{
	*path = {};
	while (true)
	{
		if (tok_is(c, LBRACKET))
		{
			// Parse the inside of [ ]
			DesignatorElement* element = calloc_arena(DesignatorElement::size);
			element.kind = ARRAY;
			advance_and_verify(c, LBRACKET);
			if (!assign_expr_ok(&element.index_expr, parse_expr(c))) return false;

			// Possible range
			if (try_consume(c, DOTDOT))
			{
				if (!assign_expr_ok(&element.index_end_expr, parse_expr(c))) return false;
				element.kind = RANGE;
			}
			if (!expect_advance(c, RBRACKET)) return false;
			// Include right bracket in the expr
			@vec_add(path, element);
			continue;
		}
		if (tok_is(c, DOT))
		{
			advance(c);
			DesignatorElement* element = calloc_arena(DesignatorElement::size);
			element.kind = FIELD;
			if (!assign_expr_ok(&element.field_expr, parse_precedence(c, PRIMARY))) return false;
			@vec_add(path, element);
			continue;
		}
		return true;
	}
}

<* Parse a lambda "fn void() ..." *>
fn Expr* parse_lambda(ParseContext* c, Expr* left, SourceLoc* lhs_span)
{
	assert(!left, "Unexpected left hand side");

	// Create the expr
	Expr* expr = expr_new_token(c, LAMBDA);

	// Step past the "fn"
	advance_and_verify(c, FN);

	// Start generating a function
	Decl* func = decl_calloc();
	func.loc = make_loc(c.prev_span);
	func.decl_kind = FUNC;
	func.visibility = LOCAL;
	func.func_decl.generated_lambda = {};
	TypeInfo* return_type = null;

	// Two possibilities: "fn ()" and "fn int()"
	// Handle the typed version:
	if (!tok_is(c, LPAREN))
	{
		if (!assign_type_ok(&return_type, parse_optional_type(c))) return poisoned_expr;
	}

	// Start parsing the argument list
	if (!expect_advance(c, LPAREN)) return poisoned_expr;
	Decl*[] decls;
	Variadic variadic = NONE;
	int vararg_index = -1;

	// Parse parameters
	if (!parse_parameters(c, &decls, &variadic, &vararg_index, LAMBDA)) return poisoned_expr;
	if (!expect_advance(c, RPAREN)) return poisoned_expr;

	// Construct the signature
	Signature* sig = &func.func_decl.signature;
	sig.vararg_index = vararg_index < 0 ? (int)decls.len : vararg_index;
	sig.params = decls;
	sig.rtype = return_type ? type_infoid(return_type) : 0;
	sig.variadic = variadic;

	// Parse any attributes
	if (!parse_attributes(c, &func.attributes, null, null, null, "on lambda declarations", null, null)) return poisoned_expr;
	range_extend_prev(c, func.loc);

	// We either have short or regular bodies
	if (tok_is(c, IMPLIES))
	{
		// =>
		if (!assign_astid_ok(&func.func_decl.body, parse_short_body(c, func, true))) return poisoned_expr;
	}
	else if (tok_is(c, LBRACE))
	{
		// { }
		if (!assign_astid_ok(&func.func_decl.body, parse_compound_stmt(c))) return poisoned_expr;
	}
	else
	{
		// Something else
		@print_error_here(c, "Expected the beginning of a block or a short statement.");
		return poisoned_expr;
	}
	expr.lambda_expr = func;
	range_extend_prev(c, expr.loc);
	return expr;
}

<* vasplat ::= ...$vaarg ('[' range_expr ']')? *>
fn Expr* parse_vasplat(ParseContext* c)
{
	Expr* expr = expr_new_token(c, VASPLAT);
	advance_and_verify(c, ELLIPSIS);
	advance_and_verify(c, CT_VAARG);
	if (try_consume(c, LBRACKET))
	{
		if (!parse_range(c, &expr.vasplat_expr)) return poisoned_expr;
		if (expr.vasplat_expr.range_type == SINGLE_ELEMENT)
		{
			@print_error_at(expr.loc, "...$vaarg expected a range.");
			return poisoned_expr;
		}
		if (!expect_advance(c, RBRACKET)) return poisoned_expr;
	}
	range_extend_prev(c, expr.loc);
	return expr;
}

<*
 param_list ::= ('...' arg | arg (',' arg)*)?

 parameter ::= ((param_path '=')? expr) | param_path
*>
fn bool parse_arg_list(ParseContext* c, Expr*[]* result, TokenType param_end, bool vasplat)
{
	*result = {};
	while (true)
	{
		Expr* expr = null;
		SourceLoc start_span = c.span;

		if (peek(c) == COLON && (token_is_param_name(c.tok) || tok_is(c, CT_EVAL)))
		{
			// Create the parameter expr
			expr = expr_new_loc(NAMED_ARGUMENT, &start_span);
			expr.named_argument_expr.name = symstr(c);
			expr.named_argument_expr.name_span = make_loc(c.span);
			advance(c);
			advance(c);
			if (!assign_expr_ok(&expr.named_argument_expr.value, parse_expr(c))) return false;
			range_extend_prev(c, expr.loc);
		}
		else if (vasplat && tok_is(c, ELLIPSIS) && peek(c) == CT_VAARG)
		{
			if (!assign_expr_ok(&expr, parse_vasplat(c))) return false;
		}
		else
		{
			if (!assign_expr_ok(&expr, parse_expr(c))) return false;
			if (expr.expr_kind == CT_EVAL && try_consume(c, COLON))
			{
				Expr* inner = expr;
				expr = expr_new_loc(NAMED_EVAL_ARGUMENT, &start_span);
				expr.eval_named_argument_expr.name = inner;
				if (!assign_expr_ok(&expr.eval_named_argument_expr.value, parse_expr(c))) return false;
			}
		}
		// DONE:
		@vec_add(result, expr);
		if (!try_consume(c, COMMA))
		{
			return true;
		}
		if (tok_is(c, param_end)) return true;
	}
}

<*
 param_list ::= ('...' arg | arg (',' arg)*)?

 parameter ::= ((param_path '=')? expr) | param_path

 `splat` may be null.
*>
fn bool parse_init_list(ParseContext* c, Expr*[]* result, TokenType param_end, bool* splat, bool vasplat)
{
	*result = {};
	if (splat) *splat = false;
	while (true)
	{
		Expr* expr = null;
		DesignatorElement*[] path;
		SourceLoc start_span = c.span;

		if (!parse_param_path(c, &path)) return false;
		if (path.len)
		{
			// Create the parameter expr
			expr = expr_new_loc(DESIGNATOR, &start_span);
			expr.designator_expr.path = path;

			if (try_consume(c, EQ))
			{
				if (!assign_expr_ok(&expr.designator_expr.value, parse_expr(c))) return false;
			}
			range_extend_prev(c, expr.loc);
		}
		else if (vasplat && tok_is(c, ELLIPSIS) && peek(c) == CT_VAARG)
		{
			if (!assign_expr_ok(&expr, parse_vasplat(c))) return false;
		}
		else
		{
			if (splat)
			{
				if (*splat)
				{
					@print_error_here(c, "'...' is only allowed on the last argument in a call.");
					return false;
				}
				*splat = try_consume(c, ELLIPSIS);
			}
			if (!assign_expr_ok(&expr, parse_expr(c))) return false;
		}
		// DONE:
		@vec_add(result, expr);
		if (!try_consume(c, COMMA))
		{
			return true;
		}
		if (tok_is(c, param_end)) return true;
	}
}

<* expression_list ::= decl_or_expr+ *>
fn Expr* parse_expression_list(ParseContext* c, bool allow_decls)
{
	Expr* expr_list = expr_new_token(c, EXPRESSION_LIST);
	while (true)
	{
		Expr* expr = parse_decl_or_expr(c);
		if (!expr_ok(expr)) return poisoned_expr;
		if (expr.expr_kind == DECL && !allow_decls)
		{
			@print_error_here(c, "This looks like a declaration, which isn't allowed here.");
			return poisoned_expr;
		}
		@vec_add(&expr_list.expression_list, expr);
		if (!try_consume(c, COMMA)) break;
	}
	return expr_list;
}

fn Expr* parse_ct_expression_list(ParseContext* c, bool allow_decl)
{
	Expr* expr_list = expr_new_token(c, EXPRESSION_LIST);
	while (true)
	{
		Expr* expr;
		if (tok_is(c, VAR))
		{
			Decl* decl = parse_var_decl(c);
			if (!decl_ok(decl)) return poisoned_expr;
			if (!allow_decl)
			{
				@print_error_here(c, "This looks like a declaration, which isn't allowed here.");
				return poisoned_expr;
			}
			expr = expr_new(DECL, decl.loc);
			expr.decl_expr = decl;
		}
		else
		{
			if (!assign_expr_ok(&expr, parse_decl_or_expr(c))) return poisoned_expr;
		}
		@vec_add(&expr_list.expression_list, expr);
		if (!try_consume(c, COMMA)) break;
	}
	return expr_list;
}

<*
 type_expr ::= void | any | int | short ... etc

 @param c : "the context"
 @param left : "must be null."
 @param lhs_start : "unused"
*>
fn Expr* parse_type_identifier(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Unexpected left hand side");
	return parse_type_expression_with_path(c, null);
}

<*
 splat_expr ::= '...' expr

 @param c : "the context"
 @param left : "must be null."
 @param lhs_start : "unused"
*>
fn Expr* parse_splat(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Unexpected left hand side");
	Expr* expr = expr_new_token(c, SPLAT);
	advance_and_verify(c, ELLIPSIS);
	if (!assign_expr_ok(&expr.inner_expr, parse_expr(c))) return poisoned_expr;
	range_extend_prev(c, expr.loc);
	return expr;
}

fn Expr* parse_type_property_expr(ParseContext* c, Expr* type)
{
	advance_and_verify(c, SCOPE);
	if (try_consume(c, TYPEID))
	{
		TypeInfo* info = type.type_expr;
		if (info.resolve_status == DONE)
		{
			type.expr_kind = CONST;
			type.const_expr.const_kind = TYPEID;
			type.const_expr.typeid_type = info.type;
			type.type = type_typeid;
		}
		else
		{
			type.expr_kind = TYPEID;
		}
		range_extend_prev(c, type.loc);
		return type;
	}
	Expr* expr = expr_new(TYPE_PROPERTY, type.loc);
	expr.type_property_expr.type = type;
	expr.type_property_expr.token_span = make_loc(c.span);
	expr.type_property_expr.property = symstr(c);
	if (try_consume(c, IDENT))
	{
		range_extend_prev(c, expr.loc);
		return expr;
	}
	@print_error_here(c, "A type property, like 'name' or 'size' was expected after '::'");
	return poisoned_expr;
}

<* type_expr ::= type (`::` IDENT)? *>
fn Expr* parse_type_expr(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Unexpected left hand side");
	Expr* expr = expr_new_token(c, TYPEINFO);
	TypeInfo* type = parse_optional_type(c);
	if (!type_info_ok(type)) return poisoned_expr;
	expr.loc = type.loc;
	expr.type_expr = type;
	expr.type = type_typeinfo;
	if (type.resolve_status == DONE) expr.resolve_status = DONE;
	if (tok_is(c, SCOPE))
	{
		return parse_type_property_expr(c, expr);
	}
	return expr;
}

<*
 ct_stringify ::= $stringify '(' expr ')'

 @param c : "the context"
 @param left : "must be null"
 @param lhs_start : "unused"
*>
fn Expr* parse_ct_stringify(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Unexpected left hand side");
	SourceLoc start_span = c.span;
	advance(c);
	if (!expect_advance(c, LPAREN)) return poisoned_expr;
	SourceLoc start_loc = c.prev_span;
	uint start_offset = start_loc.offset + start_loc.length;
	Expr* inner = parse_expr(c);
	if (!expr_ok(inner)) return poisoned_expr;
	uint end_loc = c.span.offset;
	if (!expect_advance(c, RPAREN)) return poisoned_expr;
	if (inner.expr_kind == HASH_IDENT || (inner.expr_kind == VAARG))
	{
		Expr* expr = expr_new(STRINGIFY, make_loc(start_span));
		expr.inner_expr = inner;
		range_extend_prev(c, expr.loc);
		return expr;
	}
	SourceFile* file = source_file_by_id(start_span.file_id);
	return expr_new_const_string(make_loc(start_span), str_copy(file.contents[start_offset:end_loc - start_offset]));
}

<* unary_expr ::= unary_op unary_prec_expr *>
fn Expr* parse_unary_expr(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Did not expect a left hand side!");

	if (tok_is(c, MINUS))
	{
		if (peek(c) == INTEGER)
		{
			advance(c);
			return parse_integer_expr(c, true);
		}
	}
	bool is_bangbang = tok_is(c, BANGBANG);
	Expr* unary = expr_new_token(c, UNARY);
	if (c.tok == CT_AND)
	{
		@print_error_here(c, "'&&&' is the compile time '&&' operator. If you want to take a temp address of an address, use () or space to clarify the intent, e.g. '&&(&a)'.");
		return poisoned_expr;
	}
	unary.unary_expr.operator = unaryop_from_token(c.tok);
	assert(unary.unary_expr.operator != UnaryOp.ERROR);
	advance(c);
	Expr* right_side = parse_precedence(c, UNARY);

	if (!expr_ok(right_side)) return right_side;
	unary.unary_expr.expr = right_side;
	range_extend_prev(c, unary.loc);
	if (is_bangbang)
	{
		Expr* outer = expr_new_expr(UNARY, unary);
		outer.unary_expr = { .expr = unary, .operator = NOT };
		return outer;
	}
	return unary;
}

fn Expr* parse_raise_expr_suffix(ParseContext* c, Expr* left_side, SourceLoc* lhs_start)
{
	assert(expr_ok(left_side));
	if (left_side.expr_kind == TYPEINFO)
	{
		@print_error_at(left_side.loc, "Expected a fault before '~'.");
		return poisoned_expr;
	}
	advance_and_verify(c, BIT_NOT);
	Expr* expr = expr_new_loc(OPTIONAL, lhs_start);
	expr.inner_expr = left_side;
	range_extend_prev(c, expr.loc);
	return expr;
}

<* post_unary_expr ::= <expr> unary_op *>
fn Expr* parse_post_unary(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(expr_ok(left));
	Expr* unary = expr_new_loc(POST_UNARY, lhs_start);
	unary.unary_expr.expr = left;
	unary.unary_expr.operator = unaryop_from_token(c.tok);
	advance(c);
	range_extend_prev(c, unary.loc);
	return unary;
}

<* elvis_expr := <left> ?: ternary_prec_expr *>
fn Expr* parse_elvis_expr(ParseContext* c, Expr* left_side, SourceLoc* lhs_start)
{
	assert(expr_ok(left_side));

	Expr* expr_ternary = expr_new_loc(TERNARY, lhs_start);
	expr_ternary.ternary_expr.cond = exprid(left_side);
	advance_and_verify(c, ELVIS);
	expr_ternary.ternary_expr.then_expr = 0;
	if (!assign_exprid_ok(&expr_ternary.ternary_expr.else_expr, parse_precedence(c, ORELSE))) return poisoned_expr;
	range_extend_prev(c, expr_ternary.loc);
	return expr_ternary;
}

<*
 ternary_optional_expr ::= optional_expr | ternary_expr
 optional_expr ::= <left> '?' '!'?
 ternary_expr ::= <left> '?' expr ':' ternary_prec_expr
*>
fn Expr* parse_ternary_expr(ParseContext* c, Expr* left_side, SourceLoc* lhs_start)
{
	assert(expr_ok(left_side));

	Expr* expr = expr_new_loc(TERNARY, lhs_start);
	bool is_const = tok_is(c, CT_TERNARY);
	advance(c);

	if (is_const)
	{
		expr.ternary_expr.is_const = true;
	}

	// Otherwise we have a ternary
	expr.ternary_expr.cond = exprid(left_side);
	// LHS is a plain expression
	Expr* true_expr = parse_expr(c);
	if (!expr_ok(true_expr)) return poisoned_expr;
	expr.ternary_expr.then_expr = exprid(true_expr);
	if (!expect_advance(c, COLON)) return poisoned_expr;

	// RHS is ternary prec, to get right -> left associativity
	if (!assign_exprid_ok(&expr.ternary_expr.else_expr, parse_precedence(c, TERNARY))) return poisoned_expr;
	range_extend_prev(c, expr.loc);
	return expr;
}

<*
 grouping_expr ::= cast_expr | group_expr

 cast_expr ::= '(' type ')' expr
 group_expr ::= '(' expr ')'

 When parsing we retain EXPR_GROUP in order to require explicit parentheses later
 as needed.
*>
fn Expr* parse_grouping_expr(ParseContext* c, Expr* left, SourceLoc* lhs_span)
{
	assert(!left, "Unexpected left hand side");
	SourceLoc span = c.span;
	advance_and_verify(c, LPAREN);
	Expr* expr = parse_expr(c);
	if (!expr_ok(expr)) return poisoned_expr;
	if (!expect_advance(c, RPAREN)) return poisoned_expr;
	// Look at what follows.
	switch (expr.expr_kind)
	{
		case TYPEINFO:
		{
			TypeInfo* info = expr.type_expr;
			if (tok_is(c, LBRACE))
			{
				if (!assign_expr_ok(&expr, parse_type_compound_literal_expr_after_type(c, info))) return poisoned_expr;
				*sourcelocptr(expr.loc) = extend_loc_with_token(&span, sourcelocptr(expr.loc));
				return expr;
			}
			// Create a cast expr
			if (rules[c.tok.ordinal].prefix)
			{
				Precedence prec = tok_is(c, LBRACE) ? PRIMARY : CALL;
				Expr* inner_expr = parse_precedence(c, prec);
				if (!expr_ok(inner_expr)) return poisoned_expr;
				ExprId inner = exprid(inner_expr);
				SourceLocId loc = make_loc(span);
				*expr = { .expr_kind = CAST,
						.loc = loc,
						.cast_expr.type_info = type_infoid(info),
						.cast_expr.expr = inner };
				range_extend_prev(c, expr.loc);
			}
		}
		case BINARY:
			expr.binary_expr.grouped = true;
		case TERNARY:
			expr.ternary_expr.grouped = true;
		default:
			break;
	}
	return expr;
}

fn bool index_expr_match(Expr* expr1, Expr* expr2)
{
	if (expr1.expr_kind != CONST || expr1.const_expr.const_kind != INTEGER) return false;
	if (expr2.expr_kind != CONST || expr2.const_expr.const_kind != INTEGER) return false;
	return int_comp(expr1.const_expr.ixx, expr2.const_expr.ixx, EQ);
}

fn bool designators_match(DesignatorElement*[] el1, DesignatorElement*[] el2)
{
	usz len = el1.len;
	if (len != el2.len) return false;
	for (usz i = 0; i < len; i++)
	{
		DesignatorElement* el = el1[i];
		DesignatorElement* other = el2[i];
		if (el.kind != other.kind) return false;
		switch (el.kind)
		{
			case FIELD:
				if (el.field_expr.expr_kind != UNRESOLVED_IDENTIFIER) return false;
				if (other.field_expr.expr_kind != UNRESOLVED_IDENTIFIER) return false;
				if (el.field_expr.unresolved_ident_expr.ident.ptr != other.field_expr.unresolved_ident_expr.ident.ptr) return false;
				continue;
			case RANGE:
				if (!index_expr_match(el.index_end_expr, other.index_end_expr)) return false;
				nextcase;
			case ARRAY:
				if (!index_expr_match(el.index_expr, other.index_expr)) return false;
				continue;
		}
	}
	return true;
}

<*
 initializer_list
 	: '{' initializer_values '}'
	| '{' initializer_values ',' '}'
	;

 initializer_values
	: initializer
	| initializer_values ',' initializer
	;
*>
fn Expr* parse_initializer_list(ParseContext* c, Expr* left, SourceLoc* lhs_span)
{
	assert(!left, "Unexpected left hand side");
	Expr* initializer_list = expr_new_token(c, INITIALIZER_LIST);
	advance_and_verify(c, LBRACE);
	Expr* splat = null;
	bool duplicates = false;
	if (!try_consume(c, RBRACE))
	{
		Expr*[] exprs;
		if (!parse_init_list(c, &exprs, RBRACE, null, true)) return poisoned_expr;
		int designated = -1;
		usz elements = exprs.len;
		for (usz i = 0; i < elements; i++)
		{
			Expr* expr = exprs[i];
			if (i == 0 && expr.expr_kind == SPLAT)
			{
				splat = expr;
				continue;
			}
			bool error = false;
			if (expr.expr_kind == DESIGNATOR)
			{
				if (designated == 0)
				{
					designated = expr.designator_expr.path[0].kind == FIELD ? 1 : 2;
					error = true;
				}
				else
				{
					designated = expr.designator_expr.path[0].kind == FIELD ? 1 : 2;
					if (duplicates) continue;
					for (usz j = 0; j < i; j++)
					{
						Expr* other = exprs[j];
						if (other.expr_kind != DESIGNATOR) continue;
						if (designators_match(expr.designator_expr.path, other.designator_expr.path))
						{
							@print_error_at(expr.loc, "This element is assigned twice in the same initializer.");
							@sema_note_prev_at(exprs[j].loc, "The previous assignment was here.");
							duplicates = true;
							break;
						}
					}
					continue;
				}
			}
			else
			{
				if (designated > 0)
				{
					error = true;
				}
				else
				{
					designated = 0;
					continue;
				}
			}
			assert(error);
			// ERROR:
			String error_text = designated == 1 ? ".field" : "[1]";
			@print_error_at(expr.loc, "You’re using both named and unnamed values "
				"in the same initializer. Try using either all '%s = value' or all regular values — "
				"but not both together.", error_text);
			return poisoned_expr;
		}
		if (!try_consume(c, RBRACE))
		{
			@print_error_here(c, "A comma or '}' was expected here.");
			return poisoned_expr;
		}
		range_extend_prev(c, initializer_list.loc);
		if (designated > 0)
		{
			if (splat)
			{
				@vec_erase_front(&exprs, 1);
				splat = splat.inner_expr;
			}
			initializer_list.designated_init = { .splat = splat, .list = exprs };
			initializer_list.expr_kind = DESIGNATED_INITIALIZER_LIST;
		}
		else
		{
			initializer_list.initializer_list = exprs;
		}
	}
	range_extend_prev(c, initializer_list.loc);
	return duplicates ? poisoned_expr : initializer_list;
}

fn Expr* parse_orelse(ParseContext* c, Expr* left_side, SourceLoc* lhs_start)
{
	assert(left_side && expr_ok(left_side));

	advance_and_verify(c, QUESTQUEST);

	Expr* right_side;
	// Assignment operators have precedence right -> left.
	if (!assign_expr_ok(&right_side, parse_precedence(c, ORELSE))) return poisoned_expr;

	Expr* expr = expr_new_binary(make_loc(*lhs_start), left_side, right_side, ELSE);

	range_extend_prev(c, expr.loc);
	return expr;
}

fn Expr* parse_binary(ParseContext* c, Expr* left_side, SourceLoc* start)
{
	assert(left_side && expr_ok(left_side));

	// Remember the operator.
	TokenType operator_type = c.tok;

	advance(c);

	Expr* right_side;
	// Assignment operators have precedence right -> left.
	if (rules[operator_type.ordinal].precedence == ASSIGNMENT)
	{
		if (!assign_expr_ok(&right_side, parse_precedence(c, ASSIGNMENT))) return poisoned_expr;
	}
	else
	{
		Precedence next = Precedence::from_ordinal(rules[operator_type.ordinal].precedence.ordinal + 1);
		if (!assign_expr_ok(&right_side, parse_precedence(c, next))) return poisoned_expr;
	}

	Expr* expr = expr_new_binary(make_loc(*start), left_side, right_side, binaryop_from_token(operator_type));

	range_extend_prev(c, expr.loc);
	return expr;
}

fn Expr* parse_call_expr(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(left && expr_ok(left));

	Expr*[] params;
	advance_and_verify(c, LPAREN);
	Decl*[] body_args;
	if (!tok_is(c, RPAREN) && !tok_is(c, EOS))
	{
		// Pick a modest guess. (c3c VECNEW(Expr*, 8))
		if (!parse_arg_list(c, &params, RPAREN, true)) return poisoned_expr;
	}
	if (try_consume(c, EOS))
	{
		if (!parse_next_may_be_type_or_ident(c))
		{
			if (token_is_keyword_ident(c.tok) && c.span.row == c.prev_span.row)
			{
				@print_error_here(c, "'%s' is a keyword, and can't be used as a parameter name.", symstr(c));
				return poisoned_expr;
			}
			@print_error_last(c, "Expected an ending ')'. Did you forget a ')' before this ';'?");
			return poisoned_expr;
		}
		if (!parse_parameters(c, &body_args, null, null, CALL)) return poisoned_expr;
	}
	if (!tok_is(c, RPAREN))
	{
		@print_error_last(c, "Expected the ending ')' here.");
		return poisoned_expr;
	}
	advance(c);

	Expr* call = expr_new_loc(CALL, lhs_start);
	call.call_expr.function = exprid(left);
	call.call_expr.arguments = params;
	range_extend_prev(c, call.loc);
	if (body_args.len && !tok_is(c, LBRACE))
	{
		@print_error_here(c, "Expected a macro body here.");
		return poisoned_expr;
	}
	int force_inline = -1;
	while (tok_is(c, AT_IDENT))
	{
		AttributeType attr_type = attribute_by_name(symstr(c));
		advance(c);
		int new_inline = attr_type == AttributeType.INLINE ? 1 : 0;
		switch (attr_type)
		{
			case PURE:
				if (call.call_expr.attr_pure)
				{
					@print_error_last(c, "Repeat of the same attribute is not allowed.");
					return poisoned_expr;
				}
				call.call_expr.attr_pure = true;
				continue;
			case INLINE:
			case NOINLINE:
				if (force_inline == new_inline)
				{
					@print_error_last(c, "Repeat of the same attribute is not allowed.");
					return poisoned_expr;
				}
				if (force_inline != -1)
				{
					@print_error_last(c, "@inline and @noinline cannot be combined");
					return poisoned_expr;
				}
				force_inline = new_inline;
				continue;
			default:
				@print_error_last(c, "Only '@pure', '@inline' and '@noinline' are valid attributes for calls.");
				return poisoned_expr;
		}
	}
	if (tok_is(c, AT_TYPE_IDENT))
	{
		@print_error_here(c, "User defined attributes are not allowed, only @pure, @inline and @noinline.");
		return poisoned_expr;
	}
	if (force_inline != -1)
	{
		call.call_expr.attr_force_inline = force_inline == 1;
		call.call_expr.attr_force_noinline = force_inline == 0;
	}
	Ast* body = null;
	if (tok_is(c, LBRACE))
	{
		if (!assign_ast_ok(&body, parse_compound_stmt(c))) return poisoned_expr;
	}

	if (body || body_args.len)
	{
		Expr* macro_body = expr_new(MACRO_BODY, call.loc);
		macro_body.macro_body_expr.body = body;
		macro_body.macro_body_expr.body_arguments = body_args;
		call.call_expr.macro_body = exprid(macro_body);
	}

	return call;
}

<* subscript ::= '[' range_expr ']' *>
fn Expr* parse_subscript_expr(ParseContext* c, Expr* left, SourceLoc* lhs_span)
{
	assert(left && expr_ok(left));
	advance_and_verify(c, LBRACKET);

	Expr* subs_expr = expr_new_loc(SUBSCRIPT, lhs_span);
	subs_expr.subscript_expr.expr = exprid(left);

	ExprRange range = { .range_type = DYNAMIC };
	if (!parse_range(c, &range)) return poisoned_expr;
	if (!expect_advance(c, RBRACKET)) return poisoned_expr;
	if (range.range_type == SINGLE_ELEMENT)
	{
		subs_expr.subscript_expr.index = {
				.expr = range.start,
				.start_from_end = range.start_from_end
		};
	}
	else
	{
		subs_expr.expr_kind = SLICE;
		subs_expr.slice_expr.expr = exprid(left);
		subs_expr.slice_expr.range = range;
	}
	range_extend_prev(c, subs_expr.loc);
	return subs_expr;
}

<* generic_expr ::= IDENT generic_parameters *>
fn Expr* parse_generic_expr(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(left && expr_ok(left));
	Expr* subs_expr = expr_new_loc(GENERIC_IDENT, lhs_start);
	subs_expr.generic_ident_expr.parent = exprid(left);
	if (!parse_generic_expr_list(c, &subs_expr.generic_ident_expr.parameters)) return poisoned_expr;
	range_extend_prev(c, subs_expr.loc);
	return subs_expr;
}

<*
 access_expr ::= '.' primary_expr
 deref_subscript ::= '.' '[' expr ']'
*>
fn Expr* parse_access_expr(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(left && expr_ok(left));
	advance_and_verify(c, DOT);
	if (tok_is(c, LBRACKET))
	{
		Expr* deref = expr_new(MAYBE_DEREF, left.loc);
		deref.inner_expr = left;
		return parse_subscript_expr(c, deref, lhs_start);
	}
	Expr* access_expr = expr_new_loc(ACCESS_UNRESOLVED, lhs_start);
	access_expr.access_unresolved_expr.parent = left;
	if (!assign_expr_ok(&access_expr.access_unresolved_expr.child, parse_precedence(c, PRIMARY))) return poisoned_expr;
	range_extend_prev(c, access_expr.loc);
	return access_expr;
}

fn Expr* parse_ct_ident(ParseContext* c, Expr* left, SourceLoc* lhs_span)
{
	assert(!left, "Unexpected left hand side");
	if (try_consume(c, CT_CONST_IDENT))
	{
		@print_error_last(c, "Compile time identifiers may not be constants.");
		return poisoned_expr;
	}
	Expr* expr = expr_new_token(c, CT_IDENT);
	expr.ct_ident_expr.identifier = symstr(c);
	advance_and_verify(c, CT_IDENT);
	return expr;
}

fn Expr* parse_hash_ident(ParseContext* c, Expr* left, SourceLoc* lhs_span)
{
	assert(!left, "Unexpected left hand side");
	Expr* expr = expr_new_token(c, HASH_IDENT);
	expr.ct_ident_expr.identifier = symstr(c);
	advance_and_verify(c, HASH_IDENT);
	return expr;
}

<* ct_eval ::= CT_EVAL '(' expr ')' *>
fn Expr* parse_ct_eval(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Unexpected left hand side");
	Expr* expr = expr_new_token(c, CT_EVAL);
	advance(c);
	if (!expect_advance(c, LPAREN)) return poisoned_expr;
	if (!assign_expr_ok(&expr.inner_expr, parse_expr(c))) return poisoned_expr;
	if (!expect_advance(c, RPAREN)) return poisoned_expr;
	range_extend_prev(c, expr.loc);
	return expr;
}

fn Expr* parse_ct_defined(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Unexpected left hand side");
	Expr* defined = expr_new_loc(CT_DEFINED, &c.span);
	advance(c);
	if (!expect_advance(c, LPAREN)) return poisoned_expr;
	while (!try_consume(c, RPAREN))
	{
		Expr* expr = parse_decl_or_expr(c);
		if (!expr_ok(expr)) return poisoned_expr;
		@vec_add(&defined.expression_list, expr);
		if (!try_consume(c, COMMA))
		{
			if (!expect_advance(c, RPAREN)) return poisoned_expr;
			break;
		}
	}
	range_extend_prev(c, defined.loc);
	return defined;
}

<*
 ct_refect ::= CT_REFLECT '(' expr ')'

 Note that this is transformed to $Typeof(expr).sizeof.
*>
fn Expr* parse_ct_reflect(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Unexpected left hand side");
	Expr* expr = expr_new_loc(CT_REFLECT, &c.span);
	advance(c);
	if (!expect_advance(c, LPAREN)) return poisoned_expr;
	if (!assign_expr_ok(&expr.inner_expr, parse_expr(c))) return poisoned_expr;
	if (!expect_advance(c, RPAREN)) return poisoned_expr;

	range_extend_prev(c, expr.loc);
	return expr;
}

<* ct_checks ::= CT_EMBED '(' constant_expr (',' constant_expr)? ')' *>
fn Expr* parse_ct_embed(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Unexpected left hand side");
	Expr* embed = expr_new_token(c, EMBED);
	advance_and_verify(c, CT_EMBED);
	if (!expect_advance(c, LPAREN)) return poisoned_expr;
	if (!assign_expr_ok(&embed.embed_expr.filename, parse_constant_expr(c))) return poisoned_expr;
	if (try_consume(c, COMMA))
	{
		if (!assign_expr_ok(&embed.embed_expr.len, parse_constant_expr(c))) return poisoned_expr;
	}
	if (!expect_advance(c, RPAREN)) return poisoned_expr;
	range_extend_prev(c, embed.loc);
	return embed;
}

<*
 lengthof ::= LENGTHOF '(' expr ')'
 flat_path ::= expr ('.' primary) | '[' expr ']')*
*>
fn Expr* parse_lengthof(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Unexpected left hand side");
	Expr* expr = expr_new_token(c, LENGTHOF);
	advance(c);
	if (!expect_advance(c, LPAREN)) return poisoned_expr;
	if (!assign_expr_ok(&expr.inner_expr, parse_expr(c))) return poisoned_expr;
	if (!expect_advance(c, RPAREN)) return poisoned_expr;
	range_extend_prev(c, expr.loc);
	return expr;
}

fn Expr* parse_ct_feature(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Unexpected left hand side");
	Expr* expr = expr_new_loc(CT_FEATURE, &c.span);
	advance(c);
	if (!expect_advance(c, LPAREN)) return poisoned_expr;
	if (!assign_expr_ok(&expr.inner_expr, parse_expr(c))) return poisoned_expr;
	if (!expect_advance(c, RPAREN)) return poisoned_expr;
	range_extend_prev(c, expr.loc);
	if (compiler.build.warnings.deprecation == WarningLevel.ERROR)
	{
		@print_error_at(expr.loc, "Top declaration '@if' is deprecated except for generic declarations, please use '@feat' instead.");
		return poisoned_expr;
	}
	@print_deprecated_at(expr.loc, "'$feature' is deprecated, please use '$feat' instead.");
	return expr;
}

fn Expr* parse_ct_feat(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Unexpected left hand side");
	Expr* expr = expr_new_loc(CT_FEATURE, &c.span);
	advance(c);
	if (!expect_advance(c, LPAREN)) return poisoned_expr;
	if (!assign_expr_ok(&expr.inner_expr, parse_expression_list(c, false))) return poisoned_expr;
	if (!expect_advance(c, RPAREN)) return poisoned_expr;
	range_extend_prev(c, expr.loc);
	return expr;
}

<* ct_arg ::= VAARG ('.' len) | ('[' '^'? expr ']') *>
fn Expr* parse_vaarg(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Unexpected left hand side");
	Expr* expr = expr_new_token(c, VAARG);
	advance(c);
	if (try_consume(c, DOT))
	{
		if (!tok_is(c, IDENT) || symstr(c).ptr != kw_len.ptr)
		{
			@print_error_here(c, "Expected '.len' after '$vaarg'");
			return poisoned_expr;
		}
		advance(c);
		expr.expr_kind = VACOUNT;
		range_extend_prev(c, expr.loc);
		return expr;
	}
	if (!expect_advance(c, LBRACKET)) return poisoned_expr;
	expr.vaarg_index.start_from_end = try_consume(c, BIT_XOR);
	if (!assign_exprid_ok(&expr.vaarg_index.expr, parse_expr(c))) return poisoned_expr;
	if (!expect_advance(c, RBRACKET)) return poisoned_expr;
	range_extend_prev(c, expr.loc);
	return expr;
}

<*
 identifier ::= CONST_IDENT | IDENT
 Note: if the identifier is "return" (only possible in doc lexing "mode"), create an EXPR_RETVAL instead.
*>
fn Expr* parse_identifier(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Unexpected left hand side");
	if (symstr(c).ptr == kw_return.ptr)
	{
		Expr* expr = expr_new_token(c, RETVAL);
		advance(c);
		return expr;
	}
	Expr* expr = expr_new_token(c, UNRESOLVED_IDENTIFIER);
	expr.unresolved_ident_expr.ident = symstr(c);
	expr.unresolved_ident_expr.is_const = tok_is(c, CONST_IDENT);
	advance(c);
	return expr;
}

fn Expr* parse_identifier_starting_expression(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Unexpected left hand side");
	ModulePath* path;
	if (!parse_path_prefix(c, &path)) return poisoned_expr;
	switch (c.tok)
	{
		case IDENT:
		case CONST_IDENT:
		case AT_IDENT:
		{
			Expr* expr = parse_identifier(c, null, lhs_start);
			expr.unresolved_ident_expr.path = path;
			if (path)
			{
				*sourcelocptr(expr.loc) = extend_loc_with_token(sourcelocptr(path.loc), sourcelocptr(expr.loc));
			}
			return expr;
		}
		case TYPE_IDENT:
			return parse_type_expression_with_path(c, path);
		default:
			@print_error_here(c, "Expected a type, function or constant.");
			return poisoned_expr;
	}
}

<* force_unwrap ::= expr '!!' *>
fn Expr* parse_force_unwrap_expr(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	Expr* force_unwrap_expr = expr_new_loc(FORCE_UNWRAP, lhs_start);
	advance(c);
	force_unwrap_expr.inner_expr = left;
	range_extend_prev(c, force_unwrap_expr.loc);
	return force_unwrap_expr;
}

<*
 builtin ::= '$$' IDENT
 compiler_const ::= '$$' CONST_IDENT

 Note this code accepts any ident as builtin, and relies on the lexer to prevent space between tokens.
*>
fn Expr* parse_builtin(ParseContext* c, Expr* left, SourceLoc* loc)
{
	assert(!left, "Had left hand side");
	Expr* expr = expr_new_token(c, BUILTIN);
	if (!token_is_some_ident(peek(c)))
	{
		@print_error_here(c, "Unexpected '$$', did you mean to write a builtin?");
		return poisoned_expr;
	}
	advance_and_verify(c, BUILTIN);
	expr.builtin_expr.ident = symstr(c);
	*sourcelocptr(expr.loc) = extend_loc_with_token(sourcelocptr(expr.loc), &c.span);
	if (try_consume(c, CONST_IDENT))
	{
		expr.expr_kind = COMPILER_CONST;
		return expr;
	}
	advance(c);
	return expr;
}

fn int read_int_suffix(char* string, usz loc, usz len, char c)
{
	switch (c | 32)
	{
		case 'l':
			if (loc == len - 2 && (string[loc + 1] | 32) == 'l') return 128;
			if (loc != len - 1) return -1;
			return 64;
		case 'u':
			if (loc == len - 3 && (string[loc + 1] | 32) == 'l' && (string[loc + 2] | 32) == 'l') return 128;
			if (loc == len - 2 && (string[loc + 1] | 32) == 'l') return 64;
			return 0;
		default:
			return -1;
	}
}

fn Expr* parse_integer_expr(ParseContext* c, bool negated)
{
	Expr* expr_int = expr_new_token(c, CONST);
	if (negated) *sourcelocptr(expr_int.loc) = extend_loc_with_token(&c.prev_span, &c.span);
	expr_int.resolve_status = DONE;
	usz len = c.data.lex.len;
	char* string = symstr(c).ptr;
	uint128 ixx = 0;
	int type_bits = 0;
	int hex_characters = 0;
	bool is_decimal = false;
	bool wrapped = false;
	bool set_unsigned = false;
	ulong max;
	uint radix = 10;
	switch (len > 2 ? (string[1] | 32) : '0')
	{
		case 'x':
			radix = 16;
			max = ulong::max >> 4;
			for HEX: (usz loc = 2; loc < len; loc++)
			{
				char ch = string[loc];
				switch (ch | 32)
				{
					case 'u':
						type_bits = read_int_suffix(string, loc, len, ch);
						set_unsigned = true;
						break HEX;
					case 'l':
						type_bits = read_int_suffix(string, loc, len, ch);
						break HEX;
					case '_' | 32:
						continue;
					default:
						break;
				}
				if ((ulong)(ixx >> 64) > max) wrapped = true;
				ixx <<= 4;
				ixx += (ulong)char_hex_to_nibble(ch);
				hex_characters++;
			}
		case 'o':
			radix = 8;
			max = ulong::max >> 3;
			for OCT: (usz loc = 2; loc < len; loc++)
			{
				char ch = string[loc];
				switch (ch | 32)
				{
					case 'u':
						type_bits = read_int_suffix(string, loc, len, ch);
						set_unsigned = true;
						break OCT;
					case 'l':
						type_bits = read_int_suffix(string, loc, len, ch);
						break OCT;
					case '_' | 32:
						continue;
					default:
						break;
				}
				if ((ulong)(ixx >> 64) > max) wrapped = true;
				ixx <<= 3;
				ixx += (ulong)(ch - '0');
			}
		case 'b':
			radix = 2;
			max = ulong::max >> 1;
			for BIN: (usz loc = 2; loc < len; loc++)
			{
				char ch = string[loc];
				switch (ch | 32)
				{
					case 'u':
						type_bits = read_int_suffix(string, loc, len, ch);
						set_unsigned = true;
						break BIN;
					case 'l':
						type_bits = read_int_suffix(string, loc, len, ch);
						break BIN;
					case '_' | 32:
						continue;
					default:
						break;
				}
				if ((ulong)(ixx >> 64) > max) wrapped = true;
				ixx <<= 1;
				ixx += (ulong)(ch - '0');
			}
		default:
			is_decimal = true;
			for DEC: (usz loc = 0; loc < len; loc++)
			{
				char ch = string[loc];
				switch (ch | 32)
				{
					case 'u':
						type_bits = read_int_suffix(string, loc, len, ch);
						set_unsigned = true;
						break DEC;
					case 'l':
						type_bits = read_int_suffix(string, loc, len, ch);
						break DEC;
					case '_' | 32:
						continue;
					default:
						break;
				}
				ulong old_top = (ulong)(ixx >> 64);
				ixx *= 10;
				ixx += (ulong)(ch - '0');
				if (!wrapped && old_top > (ulong)(ixx >> 64)) wrapped = true;
			}
	}
	// EXIT:
	if (wrapped)
	{
		@print_error_at(expr_int.loc, "Integer size exceeded 128 bits, max 128 bits are supported.");
		return poisoned_expr;
	}
	if (negated)
	{
		if (set_unsigned)
		{
			@print_error_at(expr_int.loc, "Negating an explicitly unsigned value is not allowed, but you can place the value inside of (), "
								"like -(%s).", i128_to_string(ixx, radix, false, true));
			return poisoned_expr;
		}
		if (i128_comp(ixx, INT128_MIN, type_u128) == CMP_GT)
		{
			@print_error_at(expr_int.loc, "The negated integer size would exceed an int128.");
			return poisoned_expr;
		}
		ixx = -ixx;
	}

	expr_int.const_expr.const_kind = INTEGER;
	expr_int.const_expr.is_character = false;
	expr_int.const_expr.is_hex = hex_characters > 0;
	Type*[8] types = { type_short, type_ushort, type_int, type_uint, type_long, type_ulong, type_i128, type_u128 };
	BitSize min_bits = compiler.platform.width_c_int;
	bool allow_unsigned = !negated && (!is_decimal || set_unsigned);
	int start;
	switch (type_bits)
	{
		case 64: start = 4;
		case 128: start = 6;
		default: start = min_bits == 16 ? 0 : 2;
	}
	Int result = { .i = ixx, .type = negated ? TypeKind.I128 : TypeKind.U128 };
	Type* type_base = null;
	for (int i = start; i < 8; i++)
	{
		bool is_signed = i % 2 == 0;
		if (is_signed && set_unsigned) continue;
		if (!is_signed && !allow_unsigned) continue;
		Type* type = types[i];
		if (int_fits(result, type.type_kind))
		{
			type_base = type;
			result.type = type.type_kind;
			break;
		}
	}
	if (!type_base)
	{
		if (type_bits)
		{
			@print_error_at(expr_int.loc, "'%s' does not fit in a '%c%d' literal.",
						   i128_to_string(ixx, radix, true, false), set_unsigned ? 'u' : 'i', type_bits);
		}
		else
		{
			if (set_unsigned)
			{
				@print_error_at(expr_int.loc, "'%s' does not fit in an unsigned integer literal.",
							   i128_to_string(ixx, radix, false, false));
			}
			else
			{
				if (negated)
				{
					@print_error_at(expr_int.loc, "'%s' does not fit in a signed integer literal.", i128_to_string(ixx, radix, true, false));
				}
				else
				{
					@print_error_at(expr_int.loc, "'%s' does not fit in a signed integer literal, but you can try making it unsigned by appending the 'U' suffix.", i128_to_string(ixx, radix, false, false));
				}
			}
		}
		return poisoned_expr;
	}
	expr_int.const_expr.ixx = result;
	expr_int.type = type_base;
	advance(c);
	return expr_int;
}

fn Expr* parse_integer(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	return parse_integer_expr(c, false);
}

<*
 Parse hex, skipping over invalid characters.
 @param result_pointer : "ref to place to put the data"
 @param data : "start pointer"
 @param end : "end pointer"
*>
fn void parse_hex(char* result_pointer, char* data, char* end)
{
	char* data_current = result_pointer;
	assert(data_current);
	while (data < end)
	{
		int val;
		int val2;
		while ((val = char_hex_to_nibble(*(data++))) < 0) if (data == end) return;
		while ((val2 = char_hex_to_nibble(*(data++))) < 0) {}
		*(data_current++) = (char)((val << 4) | val2);
	}
}

<* Slow base64 -> sextet *>
fn int base64_to_sextet(char c)
{
	if (c >= 'A' && c <= 'Z') return c - 'A';
	if (c >= 'a' && c <= 'z') return c - 'a' + 26;
	if (c >= '0' && c <= '9') return c - '0' + 52;
	if (c == '+') return 62;
	if (c == '/') return 63;
	if (c == '=') return 0;
	return -1;
}

<*
 Parse hex, skipping over invalid characters.
 @param result_pointer : "ref to place to put the data"
 @param result_pointer_end : "the end of the result data"
 @param data : "start pointer"
 @param end : "end pointer"
*>
fn void parse_base64(char* result_pointer, char* result_pointer_end, char* data, char* end)
{
	char* data_current = result_pointer;
	assert(data_current);
	while (data < end)
	{
		int val;
		int val2;
		int val3;
		int val4;
		while ((val = base64_to_sextet(*(data++))) < 0) if (data == end) return; // goto DONE
		while ((val2 = base64_to_sextet(*(data++))) < 0) {}
		while ((val3 = base64_to_sextet(*(data++))) < 0) {}
		while ((val4 = base64_to_sextet(*(data++))) < 0) {}
		uint triplet = (uint)((val << 3 * 6) + (val2 << 2 * 6) + (val3 << 6) + val4);
		if (data_current < result_pointer_end) *(data_current++) = (char)((triplet >> 16) & 0xFF);
		if (data_current < result_pointer_end) *(data_current++) = (char)((triplet >> 8) & 0xFF);
		if (data_current < result_pointer_end) *(data_current++) = (char)(triplet & 0xFF);
	}
}

fn Expr* parse_bytes_expr(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Had left hand side");
	ArrayIndex len = 0;
	char* data = null;
	SourceLoc loc = c.span;
	while (c.tok == BYTES)
	{
		ArrayIndex next_len = (ArrayIndex)c.data.bytes_len;
		if (!next_len)
		{
			advance(c);
			continue;
		}
		ArrayIndex new_len = len + next_len;
		char* new_data = calloc_arena((usz)new_len + 1);
		if (data)
		{
			mem::move(new_data, data, (sz)len);
		}
		data = new_data;
		if (c.data.is_base64)
		{
			char* base64data = c.data.lex.ptr + 4;
			char* end = base64data + c.data.lex.len - 1 - 4;
			parse_base64(new_data + len, new_data + len + next_len, base64data, end);
		}
		else
		{
			char* hexdata = c.data.lex.ptr + 2;
			char* end = hexdata + c.data.lex.len - 1 - 2;
			parse_hex(new_data + len, hexdata, end);
		}
		len = new_len;
		data[len] = 0;
		advance(c);
	}
	if (len == 0)
	{
		@print_error_last(c, "A byte array must be at least 1 byte long. While an array cannot be zero length, you can initialize a zero length slice using '{}'.");
		return poisoned_expr;
	}
	loc = extend_loc_with_token(&loc, &c.prev_span);
	Expr* expr_bytes = expr_new_loc(CONST, &loc);
	expr_bytes.const_expr.bytes.ptr = data;
	expr_bytes.const_expr.bytes.len = len;
	expr_bytes.const_expr.const_kind = BYTES;
	Type* type = type_get_array(type_char, len);
	expr_bytes.type = type;
	expr_bytes.resolve_status = DONE;
	return expr_bytes;
}

<* Char literals may be 1, 2, 4, 8 or 16 bytes. They are always unsigned. *>
fn Expr* parse_char_lit(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Had left hand side");
	Expr* expr_int = expr_new_token(c, CONST);
	expr_int.const_expr.is_character = true;
	expr_int.resolve_status = DONE;
	expr_int.const_expr.ixx.i = c.data.char_value;
	expr_int.const_expr.const_kind = INTEGER;
	switch (c.data.width)
	{
		case 1:
			expr_int.type = type_char;
			expr_int.const_expr.ixx.type = U8;
		case 2:
			expr_int.type = type_ushort;
			expr_int.const_expr.ixx.type = U16;
		case 3:
		case 4:
			expr_int.type = type_uint;
			expr_int.const_expr.ixx.type = U32;
		case 5:
		case 6:
		case 7:
		case 8:
			expr_int.type = type_ulong;
			expr_int.const_expr.ixx.type = U64;
		default:
			expr_int.type = type_u128;
			expr_int.const_expr.ixx.type = U128;
	}
	advance(c);
	return expr_int;
}

<* Parse a double from the underlying string into a constant. *>
fn Expr* parse_double(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Had left hand side");
	String err;
	Expr* number = expr_new_token(c, CONST);
	String original = symstr(c);
	bool is_hex = original.ptr[0] == '0' && (original.ptr[1] == 'x' || original.ptr[1] == 'X');
	// This is set to try to print in a similar manner as the input.
	number.const_expr.is_hex = is_hex;
	Float f = is_hex ? float_from_hex(original, &err) : float_from_string(original, &err);
	if (f.type == POISONED)
	{
		@print_error_here(c, "%s", err);
		return poisoned_expr;
	}
	number.const_expr.fxx = f;
	switch (number.const_expr.fxx.type)
	{
		case F128:
			number.type = type_f128;
		case F64:
			number.type = type_double;
		case F32:
			number.type = type_float;
		case F16:
			number.type = type_float16;
		case BF16:
			number.type = type_bfloat;
		default:
			unreachable();
	}
	number.const_expr.const_kind = FLOAT;
	number.resolve_status = DONE;
	advance(c);
	return number;
}

fn bool parse_joined_strings(ParseContext* c, String* str_ref, usz* len_ref)
{
	if (str_ref) *str_ref = {};
	String str = symstr(c);
	usz len = c.data.string.len;
	advance_and_verify(c, STRING);
	// Simple string optimization.
	if (str_ref && c.tok != STRING && !(tok_is(c, DOCS_EOL) && peek(c) == STRING))
	{
		*str_ref = str;
		if (len_ref) *len_ref = len;
		return true;
	}
	// Now handle multiple strings
	if (str_ref)
	{
		scratch_buffer_clear();
	}
	scratch_buffer_append_len(str.ptr, len);

	// Skip EOL for contracts
	if (tok_is(c, DOCS_EOL) && peek(c) == STRING) advance(c);
	while (tok_is(c, STRING))
	{
		// Grab the token.
		usz next_len = c.data.string.len;
		len += next_len;
		if (!next_len)
		{
			// Zero length so just continue.
			advance_and_verify(c, STRING);
			continue;
		}
		str = symstr(c);
		// We might overrun the buffer with this, so then we need to do a copy.
		bool append = true;
		if (!scratch_buffer_may_append(next_len))
		{
			// If it is not imperative we keep it, we skip here.
			if (!str_ref)
			{
				append = false;
			}
			else
			{
				if (!(*str_ref).ptr)
				{
					*str_ref = scratch_buffer_copy();
				}
				else
				{
					*str_ref = str_cat_len((*str_ref).ptr, len - (usz)scratch_buffer_len() - next_len, scratch_buffer_ptr(), (usz)scratch_buffer_len());
				}
				scratch_buffer_clear();
				// It might still overrun if it's too big:
				if (!scratch_buffer_may_append(next_len))
				{
					*str_ref = str_cat_len((*str_ref).ptr, len - next_len, str.ptr, next_len);
					append = false;
				}
			}
		}
		if (append) scratch_buffer_append_len(str.ptr, next_len);
		// ADVANCE:
		advance_and_verify(c, STRING);
		if (tok_is(c, DOCS_EOL) && peek(c) == STRING) advance(c);
	}
	if (len > uint::max)
	{
		@print_error_here(c, "String exceeded max size.");
		return false;
	}
	// If we don't keep it, we're done.
	if (!str_ref) return true;

	if ((*str_ref).ptr)
	{
		*str_ref = str_cat_len((*str_ref).ptr, len - (usz)scratch_buffer_len(), scratch_buffer_ptr(), (usz)scratch_buffer_len());
	}
	else
	{
		*str_ref = scratch_buffer_copy();
	}
	if (len_ref) *len_ref = len;
	return true;
}

<* string_literal ::= STRING+ *>
fn Expr* parse_string_literal(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Had left hand side");
	Expr* expr_string = expr_new_token(c, CONST);
	String str;
	usz len;
	if (!parse_joined_strings(c, &str, &len)) return poisoned_expr;
	expr_string.const_expr.bytes.ptr = str.ptr;
	expr_string.const_expr.bytes.len = (uint)len;
	expr_string.type = type_string;
	expr_string.const_expr.const_kind = STRING;
	expr_string.resolve_status = DONE;
	return expr_string;
}

<* bool ::= 'true' | 'false' *>
fn Expr* parse_bool(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Had left hand side");
	Expr* number = expr_new_token(c, CONST);
	number.const_expr = { .b = tok_is(c, TRUE), .const_kind = BOOL };
	number.type = type_bool;
	number.resolve_status = DONE;
	advance(c);
	return number;
}

<* Parse 'null', creating a const void* with zero address. *>
fn Expr* parse_null(ParseContext* c, Expr* left, SourceLoc* lhs_start)
{
	assert(!left, "Had left hand side");
	Expr* number = expr_new_token(c, CONST);
	number.const_expr.const_kind = POINTER;
	number.const_expr.ptr = 0;
	number.type = type_voidptr;
	number.resolve_status = DONE;
	advance(c);
	return number;
}

<* Expects an initializer list, then appends the type making it a compound expr rather than initializer list. *>
fn Expr* parse_type_compound_literal_expr_after_type(ParseContext* c, TypeInfo* type_info)
{
	Expr* expr = expr_new(COMPOUND_LITERAL, type_info.loc);
	expr.expr_compound_literal.type_info = type_info;
	if (!expect(c, LBRACE)) return poisoned_expr;
	if (!assign_expr_ok(&expr.expr_compound_literal.initializer, parse_initializer_list(c, null, null))) return poisoned_expr;
	range_extend_prev(c, expr.loc);
	return expr;
}

<* type_expression_with_path ::= TYPE_IDENT initializer_list? *>
fn Expr* parse_type_expression_with_path(ParseContext* c, ModulePath* path)
{
	TypeInfo* type;
	if (path)
	{
		type = type_info_new(INFO_IDENTIFIER, path.loc);
		type.unresolved.path = path;
		type.unresolved.name = symstr(c);
		advance_and_verify(c, TYPE_IDENT);
		range_extend_prev(c, type.loc);
		if (!assign_type_ok(&type, parse_type_with_base(c, type))) return poisoned_expr;
		type.optional = try_consume(c, QUESTION);
	}
	else
	{
		if (!assign_type_ok(&type, parse_optional_type(c))) return poisoned_expr;
	}
	if (tok_is(c, LBRACE))
	{
		return parse_type_compound_literal_expr_after_type(c, type);
	}
	Expr* expr = expr_new(TYPEINFO, type.loc);
	expr.type_expr = type;
	expr.type = type_typeinfo;
	if (type.resolve_status == DONE) expr.resolve_status = DONE;
	if (tok_is(c, SCOPE))
	{
		return parse_type_property_expr(c, expr);
	}
	return expr;
}

ParseRule[TokenType::len] rules = {
	[TokenType.BOOL.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.CHAR.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.ICHAR.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.SHORT.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.USHORT.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.INT.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.UINT.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.LONG.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.ULONG.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.INT128.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.UINT128.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.SZ.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.USZ.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.IPTR.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.UPTR.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.FLOAT.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.DOUBLE.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.BFLOAT.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.FLOAT16.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.FLOAT128.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.VOID.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.TYPEID.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.FAULT.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.UNTYPEDLIST.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.ANY.ordinal] = { &parse_type_identifier, null, NONE },

	[TokenType.QUESTION.ordinal] = { null, &parse_ternary_expr, TERNARY },
	[TokenType.QUESTQUEST.ordinal] = { null, &parse_orelse, ORELSE },
	[TokenType.ELVIS.ordinal] = { null, &parse_elvis_expr, ORELSE },
	[TokenType.PLUSPLUS.ordinal] = { &parse_unary_expr, &parse_post_unary, CALL },
	[TokenType.MINUSMINUS.ordinal] = { &parse_unary_expr, &parse_post_unary, CALL },
	[TokenType.LPAREN.ordinal] = { &parse_grouping_expr, &parse_call_expr, CALL },
	[TokenType.BANGBANG.ordinal] = { &parse_unary_expr, &parse_force_unwrap_expr, CALL },
	[TokenType.LBRACKET.ordinal] = { null, &parse_subscript_expr, CALL },
	[TokenType.LBRACE.ordinal] = { &parse_initializer_list, &parse_generic_expr, PRIMARY },
	[TokenType.MINUS.ordinal] = { &parse_unary_expr, &parse_binary, ADDITIVE },
	[TokenType.PLUS.ordinal] = { &parse_unary_expr, &parse_binary, ADDITIVE },
	[TokenType.DIV.ordinal] = { null, &parse_binary, MULTIPLICATIVE },
	[TokenType.MOD.ordinal] = { null, &parse_binary, MULTIPLICATIVE },
	[TokenType.STAR.ordinal] = { &parse_unary_expr, &parse_binary, MULTIPLICATIVE },
	[TokenType.DOT.ordinal] = { null, &parse_access_expr, CALL },
	[TokenType.BANG.ordinal] = { &parse_unary_expr, &parse_rethrow_expr, CALL },
	[TokenType.BYTES.ordinal] = { &parse_bytes_expr, null, NONE },
	[TokenType.BIT_NOT.ordinal] = { &parse_unary_expr, &parse_raise_expr_suffix, CALL },
	[TokenType.BIT_XOR.ordinal] = { null, &parse_binary, BIT },
	[TokenType.BIT_OR.ordinal] = { null, &parse_binary, BIT },
	[TokenType.AMP.ordinal] = { &parse_unary_expr, &parse_binary, BIT },
	[TokenType.EQEQ.ordinal] = { null, &parse_binary, RELATIONAL },
	[TokenType.NOT_EQUAL.ordinal] = { null, &parse_binary, RELATIONAL },
	[TokenType.GREATER.ordinal] = { null, &parse_binary, RELATIONAL },
	[TokenType.GREATER_EQ.ordinal] = { null, &parse_binary, RELATIONAL },
	[TokenType.LESS.ordinal] = { null, &parse_binary, RELATIONAL },
	[TokenType.LESS_EQ.ordinal] = { null, &parse_binary, RELATIONAL },
	[TokenType.SHL.ordinal] = { null, &parse_binary, SHIFT },
	[TokenType.SHR.ordinal] = { null, &parse_binary, SHIFT },
	[TokenType.TRUE.ordinal] = { &parse_bool, null, NONE },
	[TokenType.FALSE.ordinal] = { &parse_bool, null, NONE },
	[TokenType.NULL.ordinal] = { &parse_null, null, NONE },
	[TokenType.LENGTHOF.ordinal] = { &parse_lengthof, null, NONE },
	[TokenType.INTEGER.ordinal] = { &parse_integer, null, NONE },
	[TokenType.BUILTIN.ordinal] = { &parse_builtin, null, NONE },
	[TokenType.CHAR_LITERAL.ordinal] = { &parse_char_lit, null, NONE },
	[TokenType.STRING.ordinal] = { &parse_string_literal, null, NONE },
	[TokenType.REAL.ordinal] = { &parse_double, null, NONE },
	[TokenType.OR.ordinal] = { null, &parse_binary, OR },
	[TokenType.CT_OR.ordinal] = { null, &parse_binary, OR },
	[TokenType.CT_CONCAT.ordinal] = { null, &parse_binary, ADDITIVE },
	[TokenType.CT_CONCAT_ASSIGN.ordinal] = { null, &parse_binary, ASSIGNMENT },
	[TokenType.AND.ordinal] = { &parse_unary_expr, &parse_binary, AND },
	[TokenType.CT_AND.ordinal] = { &parse_unary_expr, &parse_binary, AND },
	[TokenType.EQ.ordinal] = { null, &parse_binary, ASSIGNMENT },
	[TokenType.PLUS_ASSIGN.ordinal] = { null, &parse_binary, ASSIGNMENT },
	[TokenType.MINUS_ASSIGN.ordinal] = { null, &parse_binary, ASSIGNMENT },
	[TokenType.MULT_ASSIGN.ordinal] = { null, &parse_binary, ASSIGNMENT },
	[TokenType.MOD_ASSIGN.ordinal] = { null, &parse_binary, ASSIGNMENT },
	[TokenType.DIV_ASSIGN.ordinal] = { null, &parse_binary, ASSIGNMENT },
	[TokenType.BIT_XOR_ASSIGN.ordinal] = { null, &parse_binary, ASSIGNMENT },
	[TokenType.BIT_AND_ASSIGN.ordinal] = { null, &parse_binary, ASSIGNMENT },
	[TokenType.BIT_OR_ASSIGN.ordinal] = { null, &parse_binary, ASSIGNMENT },
	[TokenType.SHR_ASSIGN.ordinal] = { null, &parse_binary, ASSIGNMENT },
	[TokenType.SHL_ASSIGN.ordinal] = { null, &parse_binary, ASSIGNMENT },

	[TokenType.IDENT.ordinal] = { &parse_identifier_starting_expression, null, NONE },
	[TokenType.TYPE_IDENT.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.CT_IDENT.ordinal] = { &parse_ct_ident, null, NONE },
	[TokenType.CONST_IDENT.ordinal] = { &parse_identifier, null, NONE },
	[TokenType.CT_CONST_IDENT.ordinal] = { &parse_ct_ident, null, NONE },
	[TokenType.CT_TYPE_IDENT.ordinal] = { &parse_type_identifier, null, NONE },
	[TokenType.HASH_IDENT.ordinal] = { &parse_hash_ident, null, NONE },
	[TokenType.AT_IDENT.ordinal] = { &parse_identifier, null, NONE },
	[TokenType.ELLIPSIS.ordinal] = { &parse_splat, null, NONE },
	[TokenType.FN.ordinal] = { &parse_lambda, null, NONE },
	[TokenType.CT_DEFINED.ordinal] = { &parse_ct_defined, null, NONE },
	[TokenType.CT_EMBED.ordinal] = { &parse_ct_embed, null, NONE },
	[TokenType.CT_EVAL.ordinal] = { &parse_ct_eval, null, NONE },
	[TokenType.CT_FEATURE.ordinal] = { &parse_ct_feature, null, NONE },
	[TokenType.CT_FEAT.ordinal] = { &parse_ct_feat, null, NONE },
	[TokenType.CT_REFLECT.ordinal] = { &parse_ct_reflect, null, NONE },
	[TokenType.CT_STRINGIFY.ordinal] = { &parse_ct_stringify, null, NONE },
	[TokenType.CT_TERNARY.ordinal] = { null, &parse_ternary_expr, TERNARY },
	[TokenType.CT_TYPEFROM.ordinal] = { &parse_type_expr, null, NONE },
	[TokenType.CT_TYPEOF.ordinal] = { &parse_type_expr, null, NONE },
	[TokenType.CT_VAARG.ordinal] = { &parse_vaarg, null, NONE },
};
