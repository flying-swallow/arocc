// Port of c3c src/compiler/sema_stmts.c (revision 54bab366a): statement
// analysis, conditions / unwraps, contracts and function bodies.
//
// Deviations from c3c:
// - The SCOPE_* / PUSH_* macros are expanded as described in
//   sema_internal.c3; nested scopes use distinct names for the saved scope
//   (`old_scope`, `old_scope2`, ...). `goto` is restructured with flags,
//   helper blocks or `nextcase`; each spot is marked.
// - Runtime format strings from `panic_fn_desc` go through `str_vprintf`
//   with only as many arguments as the format consumes (`text_count`).
// - sema_unwrappable_from_catch_in_else reads `catch_expr.exprs` where c3c
//   reads `unresolved_catch_expr.exprs` of the (already resolved) EXPR_CATCH:
//   in C both alias the same vector by layout accident, in C3 they do not.
// - sema_analyse_foreach_stmt's "flexible array member" error drops the
//   unused extra printf argument (the format check would reject it).
// - $echo prints with std::io (c3c printf / puts to stdout).
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens, std::io, std::math;

// sema_stmts.c:56
fn bool sema_scope_check_locals(SemaContext* context, DynamicScope old_scope)
{
	WarningLevel unused_local = compiler.build.warnings.unused_local;
	if (unused_local == SILENT) return true;
	int last = context.active_scope.current_local;
	for (int i = old_scope.current_local; i < last; i++)
	{
		Decl* decl = context.locals[i];
		if (!decl.is_used && decl.name.ptr)
		{
			switch (decl.var_decl.kind)
			{
				case LOCAL:
				case LOCAL_CT:
				case LOCAL_CT_TYPE:
					if (!@sema_warn_at(context, decl.loc, unused_local, "The variable '%s' is never used.", decl.name)) return false;
				default:
					break;
			}
		}
	}
	return true;
}

// sema_stmts.c:81 (static)
fn bool sema_analyse_asm_label(SemaContext* context, AsmInlineBlock* block, Ast* label)
{
	String name = label.asm_label;
	foreach (other : block.labels)
	{
		if (name.ptr == other.asm_label.ptr)
		{
			@sema_error_at(context, label.loc, "Duplicate ASM label '%s'.", name);
			@sema_note_prev_at(other.loc, "The previous definition was here.");
			return false;
		}
	}
	@vec_add(&block.labels, label);
	return true;
}

// sema_stmts.c:97 (static)
fn bool sema_analyse_asm_stmt(SemaContext* context, Ast* stmt)
{
	if (stmt.asm_block_stmt.is_string) return sema_analyse_asm_string_stmt(context, stmt);
	// Check for support
	if (!asm_is_supported(compiler.platform.arch))
	{
		return @sema_error_at(context, stmt.loc, "This architecture does not support inline asm.");
	}
	// Init as needed.
	init_asm(&compiler.platform);
	AsmInlineBlock* block = stmt.asm_block_stmt.block;
	AstId ast_id = block.asm_stmt;
	scratch_buffer_clear();
	while (ast_id)
	{
		Ast* ast = astptr(ast_id);
		ast_id = ast.next;
		if (ast.ast_kind == ASM_LABEL)
		{
			sema_analyse_asm_label(context, block, ast);
			continue;
		}
		if (!sema_analyse_asm(context, block, ast)) return false;
	}
	return true;
}

<*
 assert(foo), assert(foo, message, ...)

 - assert(false) is a compile time error.
*>
// sema_stmts.c:129 (static)
fn bool sema_analyse_assert_stmt(SemaContext* context, Ast* statement)
{
	Expr* expr = exprptr(statement.assert_stmt.expr);
	// c3c: assert(expr != null); -- C assert, compiled out in c3c release builds

	// Verify that the message is a string if it exists.
	Expr* message_expr = exprptrzero(statement.assert_stmt.message);
	if (message_expr)
	{
		if (!sema_analyse_ct_expr(context, message_expr)) return false;
		if (!expr_is_const_string(message_expr)) return @sema_error_at(context, message_expr.loc, "Expected a constant string as the error message.");

		foreach (e : statement.assert_stmt.args)
		{
			if (!sema_analyse_expr_rvalue(context, e)) return false;
			if (@is_optional(e)) return @sema_error_at(context, e.loc, "Optionals cannot be used as assert arguments, use '??', '!' or '!!' to fix this.");
			switch (sema_resolve_storage_type(context, e.type))
			{
				case STORAGE_ERROR:
					return false;
				case STORAGE_NORMAL:
					break;
				case STORAGE_WILDCARD:
					return @sema_error_at(context, e.loc, "This value is always rethrown and doesn't have a definite type. This is not valid.");
				case STORAGE_VOID:
					return @sema_error_at(context, e.loc, "This expression is of type 'void', did you make a mistake?");
				case STORAGE_COMPILE_TIME:
					if (e.type == type_untypedlist)
					{
						return @sema_error_at(context, e.loc, "The type of an untyped list cannot be inferred, you can try adding an explicit type to solve this.");
					}
					return @sema_error_at(context, e.loc, "You can't use a compile time type (%s) as an assert argument.", type_invalid_storage_type_name(e.type));
				case STORAGE_UNKNOWN:
					return @sema_error_at(context, e.loc, "You can't use an argument of type %s in an assert.", type_quoted_error_string(e.type));
			}
		}
	}

	// We might have `assert(false)` or `assert(true)`
	CondResult result_no_resolve = COND_MISSING;
	if (expr.resolve_status == DONE && expr_is_const_bool(expr))
	{
		result_no_resolve = expr.const_expr.b ? COND_TRUE : COND_FALSE;
	}

	// Check the conditional inside
	CondResult result = COND_MISSING;
	if (!sema_analyse_cond_expr(context, expr, &result)) return false;

	// If it's constant, we process it differently.
	switch (result)
	{
		case COND_TRUE:
			// It's true, then replace the statement with a nop.
			statement.ast_kind = NOP_STMT;
			return true;
		case COND_FALSE:
			// Was this 'assert(false)'?
			if (result_no_resolve == COND_FALSE)
			{
				// If this is a test, then assert(false) is permitted.
				if (context.call_env.current_function && context.call_env.current_function.func_decl.attr_test)
				{
					set_jump_end(context, statement.loc);
					return true;
				}
				// Otherwise, require unreachable.
				return @sema_error_at(context, expr.loc, "Use 'unreachable' instead of 'assert(false)'.");
			}
			// Otherwise we print an error.
			if (!context.active_scope.end_jump.active && !context.active_scope.is_dead)
			{
				if (message_expr && sema_cast_const(message_expr) && !statement.assert_stmt.args.len)
				{
					return @sema_error_at(context, expr.loc, "%s", (String)message_expr.const_expr.bytes.ptr[:message_expr.const_expr.bytes.len]);
				}
				if (statement.assert_stmt.is_ensure) return @sema_error_at(context, expr.loc, "Contract violated.");
				return @sema_error_at(context, expr.loc, "This expression will always be 'false'.");
			}
			// Otherwise, continue, this is fine as it can't be reached.
			return true;
		case COND_MISSING:
			// If the assert isn't compile time resolvable, we keep the assert.
			if (!message_expr)
			{
				scratch_buffer_clear();
				loc_to_scratch(expr.loc);
				statement.assert_stmt.panic_function = FN_ASSERT;
				statement.assert_stmt.panic_text[0] = scratch_buffer_copy();
				message_expr = expr_new_const_string(expr.loc, str_vprintf(panic_fn_desc[PanicFunction.FN_ASSERT.ordinal].format, statement.assert_stmt.panic_text[0]));
				statement.assert_stmt.message = exprid(message_expr);
			}
			return true;
	}
	unreachable();
}

<*
 break and break LABEL;
*>
// sema_stmts.c:229 (static)
fn bool sema_analyse_break_stmt(SemaContext* context, Ast* statement)
{
	assert(!statement.contbreak_stmt.is_resolved);
	// If there is no break target and there is no label,
	// we skip.
	if (!context.break_jump.target && !statement.contbreak_stmt.is_label)
	{
		if (context_labels_exist_in_scope(context))
		{
			return @sema_error_at(context, statement.loc, "Unlabelled 'break' is not allowed here.");
		}
		return @sema_error_at(context, statement.loc, "There is no valid target for 'break', did you make a mistake?");
	}

	// Is jump, and set it as resolved.
	set_jump_end(context, statement.loc);
	statement.contbreak_stmt.is_resolved = true;

	JumpTarget jump_target = { .target = null };

	if (statement.contbreak_stmt.label.name.ptr)
	{
		// If we have a label, pick it and set the parent astid to that target.
		Decl* target = sema_analyse_label(context, statement);
		if (!decl_ok(target)) return false;
		// We don't need to do any checking since all(!) label constructs support break.

		jump_target = { astptr(target.label.parent), target.label.defer_id };
	}
	else
	{
		// Jump to the default break target.
		jump_target = context.break_jump;
	}

	assert(jump_target.target);
	jump_target.target.flow.has_break = true;
	statement.contbreak_stmt.ast = astid(jump_target.target);

	// Append the defers.
	statement.contbreak_stmt.defers = context_get_defers(context, jump_target.defer_id, true);
	return true;
}

<*
 The regular { }
*>
// sema_stmts.c:275 (static)
fn bool sema_analyse_compound_stmt(SemaContext* context, Ast* statement)
{
	bool success;
	EndJump ends_with_jump;
	DynamicScope old_scope = scope_start(context, statement.loc);
	{
		success = sema_analyse_compound_statement_no_scope(context, statement);
		ends_with_jump = context.active_scope.end_jump;
	}
	success = scope_end(context, old_scope, success);
	// Overwrite the jump if we didn't have one
	if (!context.active_scope.end_jump.active) context.active_scope.end_jump = ends_with_jump;
	return success;
}

<*
 Ct compound statement
*>
// sema_stmts.c:293 (static)
fn bool sema_analyse_ct_compound_stmt(SemaContext* context, Ast* statement)
{
	if (!ast_ok(statement)) return false;
	AstId current = statement.ct_compound_stmt;
	Ast* ast = null;
	bool all_ok = true;
	while (current)
	{
		ast = ast_next(&current);
		if (!sema_analyse_statement(context, ast))
		{
			ast_poison(ast);
			all_ok = false;
		}
	}
	return all_ok;
}

<*
 continue and continue FOO;
*>
// sema_stmts.c:314 (static)
fn bool sema_analyse_continue_stmt(SemaContext* context, Ast* statement)
{
	// If we have a plain continue and no continue label, we just failed.
	if (!context.continue_jump.target && !statement.contbreak_stmt.label.name.ptr)
	{
		return @sema_error_at(context, statement.loc, "'continue' is not allowed here.");
	}

	JumpTarget jump_target = { .target = null };
	if (statement.contbreak_stmt.label.name.ptr)
	{
		// If we have a label grab it.
		Decl* target = sema_analyse_label(context, statement);
		if (!decl_ok(target)) return false;
		jump_target = { astptr(target.label.parent), target.label.defer_id };

		// Continue can only be used with "for" statements, skipping the "do {  };" statement
		if (!ast_supports_continue(jump_target.target))
		{
			return @sema_error_at(context, statement.loc, "'continue' may only be used with 'for', 'foreach', 'while' and 'do-while' statements.");
		}
	}
	else
	{
		// Use default defer and ast.
		jump_target = context.continue_jump;
	}

	// This makes the active scope jump.
	set_jump_end(context, statement.loc);

	// Link the parent and add the defers.
	statement.contbreak_stmt.ast = astid(jump_target.target);
	statement.contbreak_stmt.is_resolved = true;
	statement.contbreak_stmt.defers = context_get_defers(context, jump_target.defer_id, true);
	return true;
}

// sema_stmts.c:352 (static)
fn Expr* sema_dive_into_expression(Expr* expr)
{
	// Dive into any cast, because it might have been cast into boolean.
	while (true)
	{
		switch (expr.expr_kind)
		{
			case RVALUE:
			case RECAST:
			case PTR_ACCESS:
				expr = expr.inner_expr;
				continue;
			case MAKE_SLICE:
				expr = expr.make_slice_expr.ptr;
				continue;
			case MAKE_ANY:
				expr = expr.make_any_expr.inner;
				continue;
			case INT_TO_BOOL:
				expr = expr.int_to_bool_expr.inner;
				continue;
			case CAST:
				expr = exprptr(expr.cast_expr.expr);
				continue;
			default:
				return expr;
		}
	}
}

// sema_stmts.c:383 (static)
fn bool sema_catch_in_cond(Expr* cond)
{
	assert(cond.expr_kind == COND, "Assumed cond");

	Expr* last = @veclast(cond.cond_expr);
	assert(last);
	last = sema_dive_into_expression(last);

	// Skip any non-unwraps
	return last.expr_kind == CATCH;
}

<*
 If we have "if (catch x)", then we want to unwrap x in the else clause.
*>
// sema_stmts.c:398 (static)
fn void sema_unwrappable_from_catch_in_else(SemaContext* c, Expr* cond)
{
	assert(cond.expr_kind == COND, "Assumed cond");

	Expr* last = @veclast(cond.cond_expr);
	assert(last);
	last = sema_dive_into_expression(last);

	// Skip any non-unwraps
	if (last.expr_kind != CATCH) return;

	// If we have "if (catch x)" then this will unwrap x in the
	// else branch.
	foreach (expr : last.catch_expr.exprs)
	{
		if (expr.expr_kind != IDENTIFIER) continue;

		Decl* decl = expr.ident_expr;
		if (decl.decl_kind != VAR) continue;
		assert(decl.type.type_kind == OPTIONAL, "The variable should always be optional at this point.");

		// Note that we could possibly have "if (catch x, x)" and in this case we'd
		// unwrap twice, but that isn't really a problem.

		// 5. Locals and globals may be unwrapped
		switch (decl.var_decl.kind)
		{
			case LOCAL:
			case GLOBAL:
				sema_unwrap_var(c, decl);
			default:
				break;
		}
	}
}

// --- Sema analyse stmts

// sema_stmts.c:438 (static)
fn PanicFunction contract_panic_function(Expr* contract, bool is_ensure)
{
	if (contract.contract_expr.comment.ptr) return is_ensure ? PanicFunction.FN_ENSURE_MESSAGE : PanicFunction.FN_REQUIRE_MESSAGE;
	return is_ensure ? PanicFunction.FN_ENSURE : PanicFunction.FN_REQUIRE;
}

// sema_stmts.c:444
fn String contract_to_message(Expr* contract, bool is_ensure)
{
	PanicFunctionDescriptor* desc = &panic_fn_desc[contract_panic_function(contract, is_ensure).ordinal];
	if (desc.text_count == 2) return str_vprintf(desc.format, contract.contract_expr.expr_string, contract.contract_expr.comment);
	return str_vprintf(desc.format, contract.contract_expr.expr_string);
}

<*
 Turn a "require" or "ensure" into a contract in the callee.
*>
// sema_stmts.c:452 (static)
fn bool assert_create_from_contract(SemaContext* context, Expr* directive, bool is_ensure, AstId** asserts, SourceLocId evaluation_location, SourceLocId* arg_loc_map)
{
	Expr* declexpr = directive.contract_expr.decl_exprs;
	assert(declexpr.expr_kind == EXPRESSION_LIST);
	String comment = contract_to_message(directive, is_ensure);
	PanicFunction panic_function = contract_panic_function(directive, is_ensure);
	foreach (expr : declexpr.expression_list)
	{
		if (expr.expr_kind == DECL) return @sema_error_at(context, expr.loc, "Only expressions are allowed in contracts.");
		if (!sema_analyse_expr_rhs(context, type_bool, expr, false, null, false)) return false;

		if (evaluation_location) expr.loc = evaluation_location;
		if (directive.contract_expr.param.found && arg_loc_map)
		{
			expr.loc = arg_loc_map[directive.contract_expr.param.index];
		}
		if (expr_is_const_bool(expr))
		{
			if (expr.const_expr.b) continue;
			// With an evaluation location the error is at the call site, outside any generic instance.
			Decl* generic_instance = context.generic_instance;
			if (evaluation_location) context.generic_instance = null;
			@sema_error_at(context, expr.loc, "%s", comment);
			context.generic_instance = generic_instance;
			return false;
		}

		Ast* assert_ = new_ast(ASSERT_STMT, expr.loc);
		assert_.assert_stmt.is_ensure = true;
		assert_.assert_stmt.expr = exprid(expr);
		Expr* comment_expr = expr_new_const_string(assert_.loc, comment);
		assert_.assert_stmt.message = exprid(comment_expr);
		assert_.assert_stmt.panic_function = panic_function;
		assert_.assert_stmt.panic_text[0] = directive.contract_expr.expr_string;
		assert_.assert_stmt.panic_text[1] = directive.contract_expr.comment;
		ast_append(asserts, assert_);
	}
	return true;
}

// Check whether a defer chain contains a try or a catch.
// sema_stmts.c:493 (static)
fn bool sema_defer_has_try_or_catch(AstId defer_top, AstId defer_bottom, bool* has_catch_ref)
{
	bool has_try = false;
	while (defer_bottom != defer_top)
	{
		Ast* defer_ = astptr(defer_top);
		if (defer_.defer_stmt.is_catch)
		{
			if (has_catch_ref) *has_catch_ref = true;
			return true;
		}
		if (defer_.defer_stmt.is_try)
		{
			has_try = true;
		}
		defer_top = defer_.defer_stmt.prev_defer;
	}
	return has_try;
}

// Print defers at return (from macro/block or from function)
// sema_stmts.c:515 (static)
fn void sema_inline_return_defers(SemaContext* context, Ast* stmt, AstId defer_bottom)
{
	// Store the cleanup defers, which will happen on try.
	stmt.return_stmt.cleanup = context_get_defers(context, defer_bottom, true);

	// If we have an optional return, then we create a cleanup_fail
	bool has_catch = false;
	if (stmt.return_stmt.expr && @is_optional(stmt.return_stmt.expr)
		&& sema_defer_has_try_or_catch(context.active_scope.defer_last, context.block_return_defer, &has_catch))
	{
		stmt.return_stmt.cleanup_catch = has_catch;
		stmt.return_stmt.cleanup_fail = context_get_defers(context, context.block_return_defer, false);
		return;
	}
	// Otherwise we make the cleanup fail be the same as the cleanup.
	stmt.return_stmt.cleanup_fail = stmt.return_stmt.cleanup ? astid(copy_ast_defer(astptr(stmt.return_stmt.cleanup))) : 0;
}

<*
 Check that an optional returned actually matches the "returns!" declared
 by the contract.
*>
// sema_stmts.c:537 (static)
fn bool sema_check_return_matches_opt_returns(SemaContext* context, Expr* ret_expr)
{
	if (!@is_optional(ret_expr) || !context.call_env.opt_returns.len) return true;

	// TODO if this is a call, then we should check against
	// the "return!" in that call.
	// But for now we
	if (ret_expr.expr_kind != OPTIONAL) return true;
	Expr* inner = ret_expr.inner_expr;
	if (!sema_cast_const(inner)) return true;

	// Here we have a const optional return.
	assert(ret_expr.inner_expr.const_expr.const_kind == FAULT);
	Decl* fault_ = ret_expr.inner_expr.const_expr.enum_val;

	// Check that we find it.
	foreach (opt : context.call_env.opt_returns)
	{
		// c3c: assert(opt.decl_kind == FAULT); -- C assert, compiled out in c3c release builds
		if (opt == fault_) return true;
	}
	// No match
	return @sema_error_at(context, ret_expr.loc, "This value does not match declared optional returns, it needs to be declared with the other optional returns.");
}

// sema_stmts.c:562 (static)
fn bool sema_analyse_macro_constant_ensures(SemaContext* context, Expr* ret_expr)
{
	if (!context.current_macro) return true;
	assert(context.current_macro);
	// This is a per return check, so we don't do it if the return expression is missing,
	// or if it is optional, or – obviously - if there are no '@ensure'.
	if (!ret_expr || !context.macro_has_ensures || @is_optional(ret_expr)) return true;

	// If the return expression can't be flattened to a constant value, then
	// we won't be able to do any constant ensure checks anyway, so skip.
	if (!sema_cast_const(ret_expr)) return true;

	Decl* contracts = declptrzero(context.current_macro.docs);
	Expr*[] ensures = contracts ? contracts.contracts_decl.ensures : {};

	// We store the old return_expr for retval
	Expr* return_expr_old = context.return_expr;
	// And set our new one.
	context.return_expr = ret_expr;
	bool success = true;
	DynamicScope old_scope = scope_start_with_flags(context, SCOPE_ENSURE_MACRO, ret_expr.loc);
	// c3c: `goto END` leaves both loops.
	foreach END: (directive : ensures)
	{
		Expr* checks = copy_expr_single(directive.contract_expr.decl_exprs);
		assert(checks.expr_kind == EXPRESSION_LIST);
		Expr*[] exprs = checks.expression_list;
		foreach (expr : exprs)
		{
			if (expr.expr_kind == DECL)
			{
				@sema_error_at(context, expr.loc, "Only expressions are allowed.");
				success = false;
				break END;
			}
			CondResult result = COND_MISSING;
			if (!sema_analyse_cond_expr(context, expr, &result))
			{
				success = false;
				break END;
			}
			// Skipping non-const.
			if (result == COND_MISSING) continue;
			if (result == COND_TRUE) continue;
			@sema_error_at(context, ret_expr.loc, "%s", contract_to_message(directive, true));
			success = false;
			break END;
		}
	}
	success = scope_end(context, old_scope, success);
	context.return_expr = return_expr_old;
	return success;
}

// Handle exit in a macro or in an expression block.
// sema_stmts.c:623 (static)
fn bool sema_analyse_block_exit_stmt(SemaContext* context, Ast* statement)
{
	assert(context.active_scope.flags & SCOPE_MACRO);
	statement.ast_kind = BLOCK_EXIT_STMT;
	bool is_jump = context.active_scope.end_jump.active;
	Type* block_type = context.expected_block_type;
	Expr* ret_expr = statement.return_stmt.expr;
	if (ret_expr)
	{
		if (block_type)
		{
			if (!sema_analyse_expr_rhs(context, block_type, ret_expr, true, null, false)) return false;
		}
		else
		{
			if (!sema_analyse_expr_rvalue(context, ret_expr)) return false;
		}
		if (!sema_check_return_matches_opt_returns(context, ret_expr)) return false;
		is_jump = context.active_scope.end_jump.active && !is_jump;
		bool is_noreturn = ret_expr.expr_kind == CALL && ret_expr.call_expr.no_return;
		if (is_noreturn || is_jump)
		{
			if (is_noreturn) set_jump_end(context, ret_expr.loc);
			statement.ast_kind = EXPR_STMT;
			statement.expr_stmt = ret_expr;
			sema_inline_return_defers(context, statement, context.block_return_defer);
			return true;
		}
	}
	else
	{
		// What if we already had an expected type and we do an empty return.
		if (block_type && !type_is_void(type_no_optional(block_type)))
		{
			return @sema_error_at(context, statement.loc, "Expected a return value of type %s here.", type_quoted_error_string(block_type));
		}
	}
	set_jump_end(context, statement.loc);
	statement.return_stmt.block_exit_ref = context.block_exit_ref;
	sema_inline_return_defers(context, statement, context.block_return_defer);
	if (!sema_analyse_macro_constant_ensures(context, ret_expr)) return false;
	@vec_add(&context.block_returns, statement);
	return true;
}

// Prevent the common mistake of `return &a` where "a" is a local.
// Returns true if the check is ok (no such escape).
// sema_stmts.c:672 (static)
fn bool sema_check_not_stack_variable_escape(SemaContext* context, Expr* expr)
{
	Expr* outer = expr;
	expr = sema_dive_into_expression(expr);
	bool allow_pointer = false;
	if (expr_is_const_slice(expr) && expr.const_expr.slice_init)
	{
		return @sema_error_at(context, outer.loc, "A slice literal is backed by a stack allocated array which will be invalid once the function returns. "
						  "However, you can place the literal in a global or 'static' variable and safely return that value as long "
		                  "as the caller of the function won't modify the slice.");

	}
	// We only want && and &
	if (expr.expr_kind == SUBSCRIPT_ADDR)
	{
		expr = exprptr(expr.subscript_expr.expr);
		allow_pointer = true;
		// c3c: goto CHECK_ACCESS
	}
	else
	{
		if (expr.expr_kind != UNARY) return true;
		if (expr.unary_expr.operator == TADDR)
		{
			return @sema_error_at(context, outer.loc, "A pointer to a temporary value will be invalid once the function returns. Try copying the value to the heap or the temp memory instead.");
		}
		if (expr.unary_expr.operator != ADDR) return true;
		expr = expr.unary_expr.expr;
	}
	// CHECK_ACCESS:
	assert(expr.resolve_status == DONE);
	// &foo.bar.baz => foo
	while (expr.expr_kind == ACCESS_RESOLVED)
	{
		// If we indexed into something, like &foo.bar.baz[3]
		if (allow_pointer)
		{
			// Then if foo.bar.baz was a pointer or slice, that's ok.
			TypeKind kind = type_flatten(expr.type).type_kind;
			if (kind == POINTER || kind == SLICE) return true;
		}
		expr = expr.access_resolved_expr.parent;
	}
	if (expr.expr_kind != IDENTIFIER) return true;
	Decl* decl = expr.ident_expr;
	if (decl.decl_kind != VAR) return true;
	switch (decl.var_decl.kind)
	{
		case LOCAL:
			if (decl.var_decl.is_static) return true;
			nextcase PARAM;
		case PARAM:
			switch (type_flatten(decl.type).type_kind)
			{
				case POINTER:
				case SLICE:
					// &foo[2] is fine if foo is a pointer or slice.
					if (allow_pointer) return true;
				default:
					break;
			}
		default:
			return true;
	}
	return @sema_error_at(context, outer.loc, "A pointer to a local variable will be invalid once the function returns. "
					  "Allocate the data on the heap or temp memory to return a pointer.");
}

// We have the following possibilities:
//  1. return
//  2. return <non void expr>
//  3. return <void expr>
//
// If we are in a block or a macro expansion we need to handle it differently.
// sema_stmts.c:751 (static)
fn bool sema_analyse_return_stmt(SemaContext* context, Ast* statement)
{
	if (context.active_scope.in_defer)
	{
		return @sema_error_at(context, statement.loc, "Return is not allowed inside of a defer.");
	}

	// This might be a return in a function block or a macro which must be treated differently.
	if (context.active_scope.flags & SCOPE_MACRO)
	{
		return sema_analyse_block_exit_stmt(context, statement);
	}

	// 1. We mark that the current scope ends with a jump.
	set_jump_end(context, statement.loc);

	if (context.call_env.is_naked_fn)
	{
		return @sema_error_at(context, statement.loc, "'return' is not allowed in '@naked' functions.");
	}
	Type* expected_rtype = context.rtype;
	assert(expected_rtype, "We should always have known type from a function return.");

	Expr* return_expr = statement.return_stmt.expr;
	if (return_expr)
	{
		if (!sema_analyse_expr_rhs(context, expected_rtype, return_expr, type_is_optional(expected_rtype), null, false)) return false;
		if (!sema_check_not_stack_variable_escape(context, return_expr)) return false;
		if (!sema_check_return_matches_opt_returns(context, return_expr)) return false;
		// Process any ensures.
		sema_inline_return_defers(context, statement, 0);
	}
	else
	{
		if (type_no_optional(expected_rtype).canonical != type_void)
		{
			@sema_error_at(context, statement.loc, "Expected to return a result of type %s.", type_to_error_string(expected_rtype));
			return false;
		}
		statement.return_stmt.cleanup = context_get_defers(context, 0, true);
	}

	// c3c: `goto SKIP_ENSURE` is a break out of the labelled if.
	if SKIP_ENSURE: (context.call_env.ensures)
	{
		// Never generate an expression.
		if (return_expr && return_expr.expr_kind == OPTIONAL) break SKIP_ENSURE;
		AstId first = 0;
		AstId* append_id = &first;
		// Creating an assign statement
		Decl* contracts = declptrzero(context.call_env.current_function.docs);
		Expr*[] ensures = contracts ? contracts.contracts_decl.ensures : {};
		context.return_expr = return_expr;
		foreach (ensure : ensures)
		{
			bool success;
			DynamicScope old_scope = scope_start_with_flags(context, SCOPE_ENSURE, statement.loc);
			{
				success = assert_create_from_contract(context, copy_expr_single(ensure), true, &append_id, statement.loc, null);
			}
			success = scope_end(context, old_scope, success);
			if (!success) return false;
		}
		if (!first) break SKIP_ENSURE;
		if (statement.return_stmt.cleanup)
		{
			Ast* last = ast_last(astptr(statement.return_stmt.cleanup));
			last.next = first;
		}
		else
		{
			statement.return_stmt.cleanup = first;
		}
	}

	assert(!return_expr || type_no_optional(statement.return_stmt.expr.type).canonical == type_no_optional(expected_rtype).canonical);
	return true;
}

// sema_stmts.c:830 (static)
fn bool sema_expr_valid_try_expression(Expr* expr)
{
	assert(expr.resolve_status == DONE);
	// The first unreachable group starts with c3c's UNRESOLVED_EXPRS.
	switch (expr.expr_kind)
	{
		case TRY_UNRESOLVED:
		case ACCESS_UNRESOLVED:
		case CATCH_UNRESOLVED:
		case UNRESOLVED_IDENTIFIER:
		case CAST:
		case TYPEID:
		case EMBED:
		case VASPLAT:
		case OTHER_CONTEXT:
		case VACOUNT:
		case VAARG:
		case IOTA_DECL:
		case LENGTHOF:
		case CT_IDENT:
		case TYPE_PROPERTY:
		case GENERIC_IDENT:
		case COMPOUND_LITERAL:
		case MACRO_BODY:
		case CT_SUBSCRIPT:
		case BITASSIGN:
		case CATCH:
		case COND:
		case POISONED:
		case CT_FEATURE:
		case CT_DEFINED:
		case CT_EVAL:
		case CT_REFLECT:
		case CONTRACT:
		case NAMED_ARGUMENT:
		case NAMED_EVAL_ARGUMENT:
			unreachable();
		case BINARY:
		case DISCARD:
		case LAST_FAULT:
		case MAKE_ANY:
		case MEMBER_GET:
		case MEMBER_SET:
		case POINTER_OFFSET:
		case POST_UNARY:
		case SPLAT:
		case TERNARY:
		case TYPECALL:
		case UNARY:
			return false;
		case BITACCESS:
		case BUILTIN:
		case BUILTIN_ACCESS:
		case CALL:
		case COMPILER_CONST:
		case CONST:
		case DECL:
		case DESIGNATED_INITIALIZER_LIST:
		case DESIGNATOR:
		case EXPRESSION_LIST:
		case MACRO_BLOCK:
		case OPTIONAL:
		case FORCE_UNWRAP:
		case HASH_IDENT:
		case IDENTIFIER:
		case INITIALIZER_LIST:
		case LAMBDA:
		case MACRO_BODY_EXPANSION:
		case NOP:
		case OPERATOR_CHARS:
		case RETHROW:
		case RETVAL:
		case SLICE:
		case SLICE_ASSIGN:
		case SLICE_COPY:
		case STRINGIFY:
		case SUBSCRIPT:
		case SWIZZLE:
		case SUBSCRIPT_ADDR:
		case SUBSCRIPT_ASSIGN:
		case BENCHMARK_HOOK:
		case TEST_HOOK:
		case TRY:
		case TRY_UNWRAP_CHAIN:
		case TYPEID_INFO:
		case TYPEINFO:
		case ACCESS_RESOLVED:
		case ASM:
		case DEFAULT_ARG:
		case EXT_TRUNC:
		case INT_TO_BOOL:
		case VECTOR_TO_ARRAY:
		case SLICE_TO_VEC_ARRAY:
		case MAKE_SLICE:
		case SCALAR_TO_VECTOR:
		case PTR_ACCESS:
		case FLOAT_TO_INT:
		case INT_TO_FLOAT:
		case INT_TO_PTR:
		case PTR_TO_INT:
		case SLICE_LEN:
		case VECTOR_FROM_ARRAY:
		case RVALUE:
		case RECAST:
		case ADDR_CONVERSION:
		case ENUM_FROM_ORD:
		case MAYBE_DEREF:
			return true;
		case TWO:
			return sema_expr_valid_try_expression(expr.two_expr.last);
	}
}

// sema_stmts.c:925 (static)
fn bool sema_analyse_try_unwrap(SemaContext* context, Expr* expr)
{
	assert(expr.expr_kind == TRY_UNRESOLVED);
	Expr* ident = expr.unresolved_try_expr.variable;
	Expr* optional = expr.unresolved_try_expr.init;

	// Case A. Unwrapping a single variable.
	if (!optional)
	{
		if (!sema_analyse_expr_rvalue(context, ident)) return false;
		// The `try foo()` case.
		if (ident.expr_kind != IDENTIFIER)
		{
			if (!sema_expr_valid_try_expression(ident))
			{
				return @sema_error_at(context, ident.loc, "You need to assign this expression to something in order to use it with 'if (try ...)'.");
			}
			expr.expr_kind = TRY;
			expr.try_expr = { .optional = ident, .lhs = null, .assign_existing = true };
			expr.resolve_status = DONE;
			expr.type = type_bool;
			return true;
		}
		Decl* decl = ident.ident_expr;
		if (decl.decl_kind != VAR)
		{
			return @sema_error_at(context, ident.loc, "Expected this to be the name of an optional variable, but it isn't. Did you mistype?");
		}
		if (!@is_optional(decl))
		{
			if (decl.var_decl.kind == UNWRAPPED)
			{
				return @sema_error_at(context, ident.loc, "This variable is already unwrapped, so you cannot use 'try' on it again, please remove the 'try'.");
			}
			return @sema_error_at(context, ident.loc, "Expected this variable to be an optional, otherwise it can't be used for unwrap, maybe you didn't intend to use 'try'?");
		}
		expr.expr_kind = TRY;
		expr.try_expr = { .decl = decl, .assign_existing = false };
		expr.type = type_bool;
		sema_unwrap_var(context, decl);
		expr.resolve_status = DONE;
		return true;
	}

	// Case B. We are unwrapping to a variable that may or may not exist.
	TypeInfo* var_type = expr.unresolved_try_expr.type;

	// 2. If we have a type for the variable, resolve it.
	if (var_type)
	{
		if (!sema_resolve_type_info(context, var_type, RESOLVE_TYPE_DEFAULT)) return false;
		if (@is_optional(var_type))
		{
			return @sema_error_at(context, var_type.loc, "Only non-optional types may be used as types for 'try', please remove the '?'.");
		}
	}

	// 3. We are creating a new variable

	// 3a. If we had a variable type, then our expression must be an identifier.
	if (ident.expr_kind != UNRESOLVED_IDENTIFIER) return @sema_error_at(context, ident.loc, "A variable name was expected here.");
	assert(ident.resolve_status != DONE);
	if (ident.unresolved_ident_expr.path) return @sema_error_at(context, ident.unresolved_ident_expr.path.loc, "The variable may not have a path.");
	if (ident.unresolved_ident_expr.is_const) return @sema_error_at(context, ident.loc, "Expected a variable starting with a lower case letter.");
	String ident_name = ident.unresolved_ident_expr.ident;

	// Special check for `if (try a = a)`
	if (optional.expr_kind == UNRESOLVED_IDENTIFIER
		&& !optional.unresolved_ident_expr.path && optional.unresolved_ident_expr.ident.ptr == ident_name.ptr)
	{
		return @sema_error_at(context, ident.loc, "If you want to unwrap the same variable, use 'if (try %s)' { ... } instead.", ident_name);
	}

	// 3b. Evaluate the expression
	if (!sema_analyse_expr_rvalue(context, optional)) return false;

	if (!@is_optional(optional))
	{
		return @sema_error_at(context, optional.loc, "Expected an optional expression to 'try' here. If it isn't an optional, remove 'try'.");
	}

	if (var_type)
	{
		if (!cast_implicit(context, optional, var_type.type, false)) return false;
	}

	// 4c. Create a type_info if needed.
	if (!var_type)
	{
		var_type = type_info_new_base(optional.type.optional, optional.loc);
	}

	// 4d. A new declaration is created.
	Decl* decl = decl_new_var(ident.unresolved_ident_expr.ident, ident.loc, var_type, LOCAL);

	// 4e. Analyse it
	if (!sema_analyse_local(context, decl, null)) return false;

	expr.expr_kind = TRY;
	expr.try_expr = { .decl = decl, .optional = optional, .assign_existing = false };
	expr.type = type_bool;
	expr.resolve_status = DONE;
	return true;
}

// sema_stmts.c:1031 (static)
fn bool sema_analyse_try_unwrap_chain(SemaContext* context, Expr* expr, CondType cond_type, CondResult* result)
{
	assert(cond_type == TYPE_UNWRAP_BOOL);
	assert(expr.expr_kind == TRY_UNWRAP_CHAIN);

	foreach (chain_element : expr.try_unwrap_chain_expr)
	{
		if (chain_element.expr_kind == TRY_UNRESOLVED)
		{
			if (!sema_analyse_try_unwrap(context, chain_element)) return false;
			continue;
		}
		bool old_is_fail = *result == COND_FALSE;
		if (!sema_analyse_cond_expr(context, chain_element, result)) return false;
		if (old_is_fail) *result = COND_FALSE;
	}
	expr.type = type_bool;
	expr.resolve_status = DONE;
	return true;
}

// sema_stmts.c:1051 (static)
fn bool sema_analyse_catch_unwrap(SemaContext* context, Expr* expr)
{
	Expr* ident = expr.unresolved_catch_expr.variable;
	TypeInfo* type = expr.unresolved_catch_expr.type;

	Decl* decl = null;
	// c3c: `goto RESOLVE_EXPRS` skips the variable creation.
	if (type || ident)
	{
		type = type ? type : type_info_new_base(type_fault, expr.loc);

		if (!sema_resolve_type_info(context, type, RESOLVE_TYPE_DEFAULT)) return false;

		if (type.type.canonical != type_fault)
		{
			return @sema_error_at(context, type.loc, "Expected the type to be %s, not %s.", type_quoted_error_string(type_fault),
			                  type_quoted_error_string(type.type));
		}
		if (ident.expr_kind != UNRESOLVED_IDENTIFIER)
		{
			return @sema_error_at(context, ident.loc, "A variable name was expected here.");
		}

		if (ident.unresolved_ident_expr.path) return @sema_error_at(context, ident.unresolved_ident_expr.path.loc, "The variable may not have a path.");
		if (ident.unresolved_ident_expr.is_const) return @sema_error_at(context, ident.loc, "Expected a variable starting with a lower case letter.");

		// 4d. A new declaration is created.
		decl = decl_new_var(ident.unresolved_ident_expr.ident, ident.loc, type, LOCAL);
		decl.var_decl.no_init = true;

		// 4e. Analyse it
		if (!sema_analyse_local(context, decl, null)) return false;
	}

	// RESOLVE_EXPRS:
	Expr*[] exprs = expr.unresolved_catch_expr.exprs;
	foreach (fail : exprs)
	{
		if (!sema_analyse_expr_rvalue(context, fail)) return false;
		if (!type_is_optional(fail.type))
		{
			return @sema_error_at(context, fail.loc, "This expression is not optional, did you add it by mistake?");
		}
	}
	expr.catch_expr = { .exprs = exprs, .decl = decl };
	expr.expr_kind = CATCH;
	expr.type = type_fault;
	expr.resolve_status = DONE;
	return true;
}

// sema_stmts.c:1099 (static)
fn void sema_remove_unwraps_from_try(SemaContext* c, Expr* cond)
{
	assert(cond.expr_kind == COND);
	Expr* last = @veclast(cond.cond_expr);
	if (!last || last.expr_kind != TRY_UNWRAP_CHAIN) return;
	foreach (expr : last.try_unwrap_chain_expr)
	{
		if (expr.expr_kind != TRY) continue;
		if (expr.try_expr.assign_existing) continue;
		if (expr.try_expr.optional)
		{
			sema_erase_var(c, expr.try_expr.decl);
		}
		else
		{
			sema_erase_unwrapped(c, expr.try_expr.decl);
		}
	}
}

// sema_stmts.c:1119 (static)
fn bool sema_analyse_last_cond(SemaContext* context, Expr* expr, CondType cond_type, CondResult* result)
{
	switch (expr.expr_kind)
	{
		case TRY_UNWRAP_CHAIN:
			if (cond_type != TYPE_UNWRAP_BOOL)
			{
				return @sema_error_at(context, expr.loc, "Try unwrapping is only allowed inside of a 'while' or 'if' conditional.");
			}
			return sema_analyse_try_unwrap_chain(context, expr, cond_type, result);
		case CATCH_UNRESOLVED:
			if (cond_type != TYPE_UNWRAP_BOOL)
			{
				return @sema_error_at(context, expr.loc, "Catch unwrapping is only allowed inside of a 'while' or 'if' conditional, maybe '@catch(<expr>)' will do what you need?");
			}
			if (!sema_analyse_catch_unwrap(context, expr))
			{
				context.active_scope.is_poisoned = true;
				return false;
			}
			return true;
		default:
			break;
	}
	return sema_analyse_expr_rvalue(context, expr);
}

// An decl-expr-list is a list of a mixture of declarations and expressions.
// The last declaration or expression is propagated. So for example:
//
//   int a = 3, b = 4, float c = 4.0
//
// In this case the final value is 4.0 and the type is float.
// sema_stmts.c:1153 (static)
fn bool sema_analyse_cond_list(SemaContext* context, Expr* expr, CondType cond_type, CondResult* result)
{
	assert(expr.expr_kind == COND);

	Expr*[] dexprs = expr.cond_expr;
	int entries = (int)dexprs.len;

	// 1. Special case, there are no entries, so the type is void
	if (entries == 0)
	{
		expr.type = type_void;
		return true;
	}

	// 2. Walk through each of our declarations / expressions as if they were regular expressions.
	for (int i = 0; i < entries - 1; i++)
	{
		Expr* dexpr = dexprs[i];
		if (!sema_analyse_expr_rvalue(context, dexpr)) return false;
		if (!sema_expr_check_discard(context, dexpr)) return false;
	}

	if (!sema_analyse_last_cond(context, dexprs[entries - 1], cond_type, result)) return false;

	expr.type = dexprs[entries - 1].type;
	expr.resolve_status = DONE;
	return true;
}

// Analyse a conditional expression:
//
//  1. The middle statement in a for loop
//  2. The expression in an if, while
//  3. The expression in a switch
//
// Returns true if it passes analysis; `result` is the constant result if known.
// sema_stmts.c:1196 (static)
fn bool sema_analyse_cond(SemaContext* context, Expr* expr, CondType cond_type, CondResult* result)
{
	bool cast_to_bool = cond_type == TYPE_UNWRAP_BOOL;
	assert(expr.expr_kind == COND, "Conditional expressions should always be of type EXPR_DECL_LIST");

	// 1. Analyse the declaration list.
	ScopeFlags current_flags = context.active_scope.flags;
	context.active_scope.flags |= SCOPE_COND;
	bool success = sema_analyse_cond_list(context, expr, cond_type, result);
	context.active_scope.flags = current_flags;
	if (!success) return false;

	// 2. If we get "void", either through a void call or an empty list,
	//    signal that.
	if (type_is_void(expr.type))
	{
		if (cast_to_bool) return @sema_error_at(context, expr.loc, "Expected a boolean expression.");
		return @sema_error_at(context, expr.loc, "Expected an expression resulting in a value.");
	}

	// 3. We look at the last element (which is guaranteed to exist because
	//    the type was not void.
	Expr* last = @veclast(expr.cond_expr);

	if (last.expr_kind == DECL)
	{
		// 3c. The declaration case
		Decl* decl = last.decl_expr;
		Expr* init = decl.var_decl.init_expr;
		// 3d. We expect an initialization for the last declaration.
		if (!init)
		{
			return @sema_error_at(context, last.loc, "Expected a declaration with initializer.");
		}
		// 3e. Expect that it isn't an optional
		if (@is_optional(init))
		{
			return sema_error_failed_cast(context, last, last.type, cast_to_bool ? type_bool : init.type);
		}
		if (@is_optional(decl))
		{
			return @sema_error_at(context, decl.loc, "Expected a non-optional variable.");
		}
		if (cast_to_bool)
		{
			if (!may_cast(context, init, type_bool, true, true))
			{
				return @sema_error_at(context, last.decl_expr.var_decl.init_expr.loc, "The expression needs to be convertible to a boolean.");
			}

			cast_no_check(last, type_bool, false);
		}
		if (cast_to_bool && expr_is_const_bool(init))
		{
			*result = init.const_expr.b ? COND_TRUE : COND_FALSE;
		}
		return true;
	}
	if (cast_to_bool && last.expr_kind == BINARY && last.binary_expr.operator >= BinaryOp.ASSIGN && !last.binary_expr.grouped)
	{
		if (expr.cond_expr.len > 1)
		{
			return @sema_error_at(context, last.loc, "An assignment in the last conditional must be parenthesized - did you mean to use '==' instead?");
		}
		return @sema_error_at(context, last.loc, "An assignment in a conditional must have an extra parenthesis - did you mean to use '==' instead?");
	}

	// 3a. Check for optional in case of an expression.
	if (@is_optional(last))
	{
		if (type_is_void(type_no_optional(last.type)) && cast_to_bool)
		{
			return @sema_error_at(context, last.loc, "Use '@ok(<expr>)' or '@catch(<expr>)' to explicitly convert a 'void!' to a boolean.");
		}
		return @sema_error_at(context, last.loc, "The expression may not be an optional, but was %s.", type_quoted_error_string(last.type));
	}
	// 3b. Cast to bool if that is needed
	if (cast_to_bool)
	{
		if (!cast_explicit(context, last, type_bool)) return false;
	}
	if (expr_is_const_bool(last))
	{
		*result = last.const_expr.b ? COND_TRUE : COND_FALSE;
	}
	return true;
}

// sema_stmts.c:1283 (static)
fn bool sema_analyse_ct_type_assign_stmt(SemaContext* context, Ast* statement)
{
	Expr* right = statement.ct_type_assign_stmt.type_expr;
	if (!sema_analyse_expr(context, right)) return false;
	if (right.expr_kind == TYPEINFO)
	{
		expr_rewrite_const_typeid(right, right.type_expr.type);
	}
	if (!expr_is_const_typeid(right)) return @sema_error_at(context, right.loc, "Expected a type or constant typeid here.");

	Decl* decl = sema_find_symbol(context, statement.ct_type_assign_stmt.var_name);
	if (!decl) return @sema_error_at(context, statement.loc, "'%s' is not defined in this scope yet.", statement.ct_type_assign_stmt.var_name);
	if (decl_is_defaulted_var(decl)) return @sema_error_at(context, statement.loc, "The parameter '%s' was not provided by the caller.", decl.name);
	decl.var_decl.init_expr = right;
	statement.ast_kind = NOP_STMT;

	return true;
}

// sema_stmts.c:1302 (static)
fn bool sema_analyse_decls_stmt(SemaContext* context, Ast* statement)
{
	bool should_nop = true;
	foreach (i, decl : statement.decls_stmt)
	{
		VarDeclKind kind = decl.var_decl.kind;
		if (kind == LOCAL_CT_TYPE || kind == LOCAL_CT)
		{
			if (!sema_analyse_var_decl_ct(context, decl, null)) return false;
			statement.decls_stmt[i] = null;
		}
		else
		{
			if (!sema_analyse_local(context, decl, null)) return false;
			should_nop = false;
		}
	}
	if (should_nop) statement.ast_kind = NOP_STMT;
	return true;
}

// sema_stmts.c:1323 (static)
fn bool sema_analyse_declare_stmt(SemaContext* context, Ast* statement)
{
	Decl* decl = statement.declare_stmt;
	VarDeclKind kind = decl.var_decl.kind;
	bool erase = kind == LOCAL_CT_TYPE || kind == LOCAL_CT;
	if (!sema_analyse_local(context, decl, null))
	{
		if (!decl_ok(decl)) context.active_scope.is_poisoned = true;
		return false;
	}
	if (erase || decl.decl_kind == ERASED) statement.ast_kind = NOP_STMT;
	return true;
}

// sema_stmts.c:1337 (static)
fn bool sema_analyse_expr_stmt(SemaContext* context, Ast* statement)
{
	Expr* expr = statement.expr_stmt;
	if (!sema_analyse_expr_rvalue(context, expr)) return false;
	if (!sema_expr_check_discard(context, expr)) return false;
	if (expr.expr_kind == CONST)
	{
		// Remove all const statements.
		statement.ast_kind = NOP_STMT;
	}
	return true;
}

// sema_stmts.c:1350 (static)
fn bool sema_analyse_defer_stmt_body(SemaContext* context, Ast* statement)
{
	Ast* body = astptr(statement.defer_stmt.body);
	if (body.ast_kind == DEFER_STMT)
	{
		return @sema_error_at(context, body.loc, "A defer may not have a body consisting of a raw 'defer', this looks like a mistake.");
	}
	if (body.ast_kind != COMPOUND_STMT)
	{
		Ast* new_body = new_ast(COMPOUND_STMT, body.loc);
		new_body.compound_stmt.first_stmt = astid(body);
		body = new_body;
		statement.defer_stmt.body = astid(body);
	}
	body.compound_stmt.parent_defer = astid(statement);
	bool success = true;
	DynamicScope old_scope = scope_start(context, statement.loc);
	{
		context.active_scope.defer_last = 0;
		context.active_scope.defer_start = 0;
		context.active_scope.in_defer = statement;

		BreakContState old_bc = push_breakcont(context, null);
		NextJumpState old_next = push_next(context, null, null);

		// Only ones allowed.
		context.active_scope.flags = 0;

		success = sema_analyse_statement(context, body);

		pop_breakcont(context, old_bc);
		pop_next(context, old_next);

		// We should never need to replace any defers here.
	}
	success = scope_end(context, old_scope, success);

	return success;
}

// sema_stmts.c:1392 (static)
fn bool sema_analyse_defer_stmt(SemaContext* context, Ast* statement)
{
	if (!sema_analyse_defer_stmt_body(context, statement)) return false;

	statement.defer_stmt.prev_defer = context.active_scope.defer_last;
	context.active_scope.defer_last = astid(statement);

	return true;
}

// sema_stmts.c:1403 (static)
fn bool sema_analyse_for_cond(SemaContext* context, ExprId* cond_ref, bool* infinite)
{
	ExprId cond_id = *cond_ref;
	if (!cond_id)
	{
		*infinite = true;
		return true;
	}
	Expr* cond = exprptr(cond_id);
	CondResult result = COND_MISSING;
	if (cond.expr_kind == COND)
	{
		if (!sema_analyse_cond(context, cond, TYPE_UNWRAP_BOOL, &result)) return false;
	}
	else
	{
		if (!sema_analyse_cond_expr(context, cond, &result)) return false;
	}

	// If this is const true, then set this to infinite and remove the expression.
	if (result == COND_TRUE)
	{
		if (cond.expr_kind != COND || (cond.cond_expr.len == 1 && cond.cond_expr[0].expr_kind != DECL))
		{
			cond = null;
		}
		*infinite = true;
	}
	else
	{
		*infinite = false;
	}
	*cond_ref = cond ? exprid(cond) : 0;
	return true;
}

// sema_stmts.c:1438 (static)
fn bool sema_analyse_for_stmt(SemaContext* context, Ast* statement)
{
	bool success = true;
	bool is_infinite = false;

	Ast* body = astptr(statement.for_stmt.body);
	assert(body);
	bool do_loop = statement.for_stmt.flow.skip_first;
	if (body.ast_kind != COMPOUND_STMT && do_loop)
	{
		return @sema_error_at(context, body.loc, "A do loop must use { } around its body.");
	}
	// Enter for scope
	DynamicScope stored_scope = scope_outer_start(context, statement.loc);
	{
		if (statement.for_stmt.init)
		{
			success = sema_analyse_expr_rvalue(context, exprptr(statement.for_stmt.init));
		}

		// Conditional scope start
		DynamicScope old_scope = scope_start_with_label(context, statement.for_stmt.flow.label, statement.loc);
		{
			if (!do_loop)
			{
				if (!sema_analyse_for_cond(context, &statement.for_stmt.cond, &is_infinite) || !success)
				{
					context.active_scope = stored_scope;
					return false;
				}
			}

			BreakContState old_bc = push_breakcont(context, statement);
			success = sema_analyse_statement(context, body);
			statement.for_stmt.flow.no_exit = context.active_scope.end_jump.active;
			pop_breakcont(context, old_bc);
			if (success && context.active_scope.defer_last != context.active_scope.defer_start)
			{
				@sema_error_at(context, body.loc, "Looping over a raw 'defer' is not allowed, was this a mistake?");
				success = false;
			}

			// End for body scope
			context_pop_defers_and_replace_ast(context, body);
		}
		success = scope_end(context, old_scope, success);

		if (statement.for_stmt.flow.skip_first)
		{
			DynamicScope old_scope2 = scope_start(context, statement.loc);
			{
				if (!sema_analyse_for_cond(context, &statement.for_stmt.cond, &is_infinite) || !success)
				{
					context.active_scope = stored_scope;
					return false;
				}
			}
			success = scope_end(context, old_scope2, success);
			// Rewrite do { } while(true) to while (true) { }
			if (is_infinite)
			{
				assert(!statement.for_stmt.cond);
				statement.for_stmt.flow.skip_first = false;
			}
		}

		if (success && statement.for_stmt.incr)
		{
			// Incr scope start
			DynamicScope old_scope3 = scope_start(context, statement.loc);
			{
				success = sema_analyse_expr_rvalue(context, exprptr(statement.for_stmt.incr));
				// Incr scope end
			}
			success = scope_end(context, old_scope3, success);
		}

		// End for body scope
		context_pop_defers_and_replace_ast(context, statement);
	}
	scope_outer_end(context, stored_scope);

	if (is_infinite && !statement.for_stmt.flow.has_break)
	{
		if (!success) context.active_scope.is_poisoned = true;
		set_jump_end(context, statement.loc);
	}
	return success;
}

// sema_stmts.c:1534 (static)
fn bool sema_foreach_param_contract(SemaContext* context, Expr* enumerator, Decl* var_, bool value_by_ref)
{
	if (enumerator.expr_kind == UNARY && enumerator.unary_expr.operator == DEREF) enumerator = enumerator.unary_expr.expr;
	if (enumerator.expr_kind != IDENTIFIER) return true;
	Decl* decl = enumerator.ident_expr;
	if (decl.decl_kind != VAR) return true;
	if (value_by_ref)
	{
		var_.var_decl.in_param = decl.var_decl.in_param;
		var_.var_decl.out_param = decl.var_decl.out_param;
		return true;
	}
	if (decl.var_decl.out_param && !decl.var_decl.in_param)
	{
		return @sema_error_at(context, enumerator.loc, "'out' parameters may not be read.");
	}
	return true;
}

// foreach_stmt ::= foreach
// sema_stmts.c:1559 (static)
fn bool sema_analyse_foreach_stmt(SemaContext* context, Ast* statement)
{
	// Pull out the relevant data.
	Decl* var_ = declptr(statement.foreach_stmt.variable);
	Decl* index = declptrzero(statement.foreach_stmt.index);
	Expr* enumerator = exprptr(statement.foreach_stmt.enumeration);
	AstId body = statement.foreach_stmt.body;
	AstId first_stmt = 0;
	AstId* succ = &first_stmt;
	Expr*[] expressions;
	bool is_reverse = statement.foreach_stmt.is_reverse;
	bool value_by_ref = statement.foreach_stmt.value_by_ref;
	bool iterator_was_initializer = enumerator.expr_kind == INITIALIZER_LIST;

	// Check the type if needed
	TypeInfo* variable_type_info = vartype(var_);
	if (variable_type_info && !sema_resolve_type_info(context, variable_type_info, RESOLVE_TYPE_DEFAULT)) return false;
	if (variable_type_info)
	{
		switch (sema_resolve_storage_type(context, variable_type_info.type))
		{
			case STORAGE_ERROR: return false;
			case STORAGE_NORMAL: break;
			default: return @sema_error_at(context, var_.loc, "%s is not a valid type for '%s', only runtime types with a known size may be used.", type_quoted_error_string(variable_type_info.type), var_.name);
		}
	}
	if (value_by_ref && enumerator.expr_kind == UNARY && enumerator.unary_expr.operator == DEREF)
	{
		Expr* pointer = enumerator.unary_expr.expr;
		if (!sema_analyse_expr_rvalue(context, pointer)) return false;
		Type* flat = type_flatten(pointer.type);
		enumerator.unary_expr.no_read = flat.type_kind == POINTER && type_is_arraylike(type_flatten(flat.pointer));
	}
	// Conditional scope start
	DynamicScope old_scope = scope_start(context, statement.loc);
	{
		// In the case of foreach (int x : { 1, 2, 3 }) we will infer the int[] type, so pick out the number of elements.
		Type* inferred_type = variable_type_info ? type_get_inferred_array(type_no_optional(variable_type_info.type)) : null;

		if (variable_type_info)
		{
			if (!sema_analyse_inferred_expr(context, inferred_type, enumerator, null)) return scope_pop_error(context, old_scope);
		}
		else
		{
			if (!sema_analyse_expr_rvalue(context, enumerator)) return scope_pop_error(context, old_scope);
		}
		// And pop the cond scope.
	}
	if (!scope_end_check(context, old_scope)) return false;

	// Trying to iterate over an optional is meaningless, it should always be handled
	// So check if it's a foreach (x : may_fail())
	if (@is_optional(enumerator))
	{
		return @sema_error_at(context, enumerator.loc, "The foreach iterable expression may not be optional.");
	}

	// We handle the case of `foreach(&i, v : foo)` here, as it gives the chance
	// to give better errors
	if (statement.foreach_stmt.index_by_ref)
	{
		assert(index);
		return @sema_error_at(context, index.loc, "The index cannot be held by reference, did you accidentally add a '&'?");
	}

	// We might have an untyped list, if we failed the conversion.
	Type* canonical = enumerator.type.canonical;
	if (canonical.type_kind == UNTYPEDLIST)
	{
		if (variable_type_info || !iterator_was_initializer)
		{
			return @sema_error_at(context, enumerator.loc, "It is not possible to enumerate a compile time 'untyped' list at runtime, but you can use the compile time `$foreach` with the list.");
		}
		return @sema_error_at(context, var_.loc, "Add an explicit type to the variable if you want to iterate over an initializer list.");
	}

	Type* original_type = enumerator.type;
	// In the case of a single `*`, then we will implicitly dereference that pointer.
	if (canonical.type_kind == POINTER)
	{
		// Something like Foo** will not be dereferenced, only Foo*
		if (canonical.pointer.type_kind == POINTER)
		{
			return @sema_error_at(context, enumerator.loc, "It is not possible to enumerate an expression of type %s.", type_quoted_error_string(enumerator.type));
		}
		if (!sema_expr_rewrite_insert_deref(context, enumerator)) return false;
		canonical = enumerator.type.canonical;
	}

	// At this point we should have dereferenced any pointer or bailed.
	assert(!type_is_pointer(enumerator.type));

	if (enumerator.type.type_kind == FLEXIBLE_ARRAY)
	{
		return @sema_error_at(context, enumerator.loc, "It is not possible to enumerate over a flexible array member.");
	}

	// Check that we can even index this expression, this will dig into the flattened type.
	Type* value_type = type_get_indexed_type(enumerator.type);

	// However, if we have something distinct, that flattens to a pointer, we should never take the
	// the underlying pointee type.
	if (type_is_distinct_like(canonical) && type_flatten(canonical).type_kind == POINTER)
	{
		value_type = null;
	}

	// If we have a value type and it's by ref, then we get the pointer to that type.
	if (value_type && value_by_ref) value_type = type_get_ptr(value_type);

	Decl* len = null;
	Decl* index_function = null;
	Type* index_type = type_sz;
	bool is_enum_iterator = false;
	bool need_deref = false;

	// Now we lower the foreach...
	// If we can't find a value, or it has a subscript overload we assume it has an overload
	if (!value_type || sema_type_has_subscript_overloads(canonical))
	{
		// Get the overload for .len
		len = sema_find_untyped_operator(enumerator.type, OVERLOAD_LEN, null);
		// For foo[]
		Decl* by_val = sema_find_untyped_operator(enumerator.type, OVERLOAD_ELEMENT_AT, null);
		// For &foo[]
		Decl* by_ref = sema_find_untyped_operator(enumerator.type, OVERLOAD_ELEMENT_REF, null);

		// If we don't have .len, or there is neither by val nor by ref
		if (!len || (!by_val && !by_ref))
		{
			if (!sema_type_has_subscript_overloads(canonical))
			{
				return @sema_error_at(context, enumerator.loc, "It's not possible to enumerate an expression of type %s.", type_quoted_error_string(original_type));
			}
			return @sema_error_at(context, enumerator.loc, "%s can't be used with 'foreach', since it has no %s.", type_quoted_error_string(original_type),
			                  len ? "'@operator([])' or '@operator(&[])'" : "'@operator(len)'");
		}
		// If we want the value "by ref" and there isn't a &[], then this is an error.
		if (!by_ref && value_by_ref)
		{
			return @sema_error_at(context, enumerator.loc, "%s has no '@operator(&[])', so 'foreach' can only iterate it by value.", type_quoted_error_string(enumerator.type));
		}

		// If there was an error in either of those declarations,
		// bail here.
		if (!decl_ok(len) || !decl_ok(by_val) || !decl_ok(by_ref)) return false;

		// Get the proper macro
		index_function = value_by_ref ? by_ref : by_val;
		if (!index_function)
		{
			// c3c: assert(!value_by_ref); -- C assert, compiled out in c3c release builds
			need_deref = true;
			index_function = by_ref;
		}
		assert(index_function);

		// The index type is the second parameter.
		index_type = index_function.func_decl.signature.params[1].type;

		// If it's an enum this is handled in a special way.
		is_enum_iterator = index_type.canonical.type_kind == ENUM;
		// We check that the index is either using integer or enums.
		if (!type_is_integer(index_type) && !is_enum_iterator)
		{
			return @sema_error_at(context, enumerator.loc, "Only types indexed by integers or enums may be used with foreach.");
		}

		// The return type is the value type if it is known (it's inferred for macros)
		TypeInfoId rtype = index_function.func_decl.signature.rtype;
		value_type = rtype ? type_infoptr(rtype).type : null;
		if (need_deref && value_type)
		{
			if (value_type.type_kind != POINTER) return @sema_error_at(context, enumerator.loc, "Expected the index function to return a pointer.");
			value_type = value_type.pointer;
		}
	}

	// Get the type of the variable, if available (e.g. foreach (Foo x : y) has a type
	TypeInfo* type_info = vartype(var_);

	// Set up the value, assigning the type as needed.
	// Element *value @noinit
	if (!type_info)
	{
		type_info = type_info_new_base(value_type, var_.loc);
		var_.var_decl.type_info = type_infoid(type_info);
	}
	if (!sema_resolve_type_info(context, type_info, RESOLVE_TYPE_DEFAULT)) return false;

	// Set up the optional index parameter
	Type* index_var_type = null;
	if (index)
	{
		// The index may or may not have a type, infer it as needed.
		TypeInfo* idx_type_info = vartype(index);
		if (!idx_type_info)
		{
			idx_type_info = type_info_new_base(index_type, enumerator.loc);
			index.var_decl.type_info = type_infoid(idx_type_info);
		}
		if (!sema_resolve_type_info(context, idx_type_info, RESOLVE_TYPE_DEFAULT)) return false;

		// The resulting type is our "index_var_type"
		index_var_type = idx_type_info.type;

		// Check that we don't have `foreach(int? i, y : z)`
		if (type_is_optional(index_var_type))
		{
			return @sema_error_at(context, idx_type_info.loc, "The index may not be an optional.");
		}
		// If we have an enum iterator, the enums must match.
		if (is_enum_iterator)
		{
			if (index_var_type.canonical != index_type.canonical)
			{
				return @sema_error_at(context, idx_type_info.loc, "The index value must be the enum %s.", type_quoted_error_string(index_type));
			}
		}
		else if (!type_is_integer(type_flatten(index_var_type)))
		{
			// Otherwise make sure it's an integer.
			return @sema_error_at(context, idx_type_info.loc,
			                  "The index must be an integer type, '%s' is not valid.",
			                  type_to_error_string(index_var_type));
		}
	}

	assert(enumerator.resolve_status == DONE);
	Decl* temp;
	bool is_addr = false;
	Expr* len_call = null;
	ArrayIndex array_len = 0;
	Type* flat = type_flatten(enumerator.type);
	if (!len && !sema_foreach_param_contract(context, enumerator, var_, value_by_ref)) return false;
	if (!len && flat.type_kind == SLICE)
	{
		// Foo[] __slice$ = s; Foo* __enum$ = __slice$.ptr;
		Decl* slice = decl_new_generated_var(enumerator.type, LOCAL, enumerator.loc);
		@vec_add(&expressions, expr_generate_decl(slice, enumerator));
		Expr* ptr = expr_new_expr(PTR_ACCESS, enumerator);
		expr_rewrite_ptr_access(ptr, expr_variable(slice), type_get_ptr(flat.array.base));
		temp = decl_new_generated_var(ptr.type, LOCAL, enumerator.loc);
		@vec_add(&expressions, expr_generate_decl(temp, ptr));
		len_call = expr_new_expr(SLICE_LEN, enumerator);
		expr_rewrite_slice_len(len_call, expr_variable(slice), type_sz);
	}
	else
	{
		// Store either "Foo* __enum$ = &some_var;" or "Foo __enum$ = some_call()"
		if (enumerator.expr_kind == IDENTIFIER)
		{
			decl_write(enumerator.ident_expr);
			temp = enumerator.ident_expr;
		}
		else
		{
			if (expr_may_ref(enumerator))
			{
				is_addr = true;
				expr_insert_addr(enumerator);
			}
			temp = decl_new_generated_var(enumerator.type, LOCAL, enumerator.loc);
			@vec_add(&expressions, expr_generate_decl(temp, enumerator));
		}
		// Create @__enum$.len() or @(*__enum$).len()
		Expr* enum_val = expr_variable(temp);
		enum_val.loc = enumerator.loc;
		if (is_addr && !sema_expr_rewrite_insert_deref(context, enum_val)) return false;
		if (len)
		{
			len_call = expr_new(CALL, enumerator.loc);
			if (!sema_insert_method_call(context, len_call, len, enum_val, {}, false)) return false;
		}
		else
		{
			array_len = flat.array.len;
		}
	}
	bool is_single_pass = array_len == 1;
	if (is_single_pass)
	{
		is_reverse = false;
	}

	// Find the actual index type -> flattening the enum
	Type* actual_index_type = is_enum_iterator ? enum_inner_type(index_type.canonical) : index_type;

	// Generate the index variable
	Decl* idx_decl = decl_new_generated_var(actual_index_type, LOCAL, index ? index.loc : enumerator.loc);

	// IndexType __len$ = (ActualIndexType)(@__enum$.len())
	Decl* len_decl = null;

	if (is_reverse)
	{
		if (!len_call)
		{
			// Create const len if missing.
			len_call = expr_new_const_int(enumerator.loc, type_sz, (ulong)array_len);
		}
		if (is_enum_iterator)
		{
			if (!cast_explicit(context, len_call, actual_index_type)) return false;
		}
		else
		{
			if (!cast_implicit(context, len_call, actual_index_type, false)) return false;
		}
		// __idx$ = (ActualIndexType)(@__enum$.len()) (or const)
		@vec_add(&expressions, expr_generate_decl(idx_decl, len_call));
	}
	else
	{
		if (len_call)
		{
			len_decl = decl_new_generated_var(actual_index_type, LOCAL, enumerator.loc);
			bool success;
			if (is_enum_iterator)
			{
				success = cast_explicit_silent(context, len_call, actual_index_type);
			}
			else
			{
				success = cast_implicit_silent(context, len_call, actual_index_type, false);
			}
			if (!success)
			{
				@sema_error_at(context, enumerator.loc,
				           "'foreach' is not supported, as the length %s cannot "
				           "be %s to %s - please update your definition.",
				           type_quoted_error_string(len_call.type), is_enum_iterator ? "cast" : "implicitly cast",
				           type_quoted_error_string(actual_index_type));
				if (len)
				{
					@sema_note_prev_at(len.loc, "The definition of 'len()' is here.");
					decl_poison(len);
				}
				if (index_function)
				{
					@sema_note_prev_at(index_function.loc, "The index definition is here.");
					decl_poison(index_function);
				}
				return false;
			}
			@vec_add(&expressions, expr_generate_decl(len_decl, len_call));
		}
		Expr* idx_init = expr_new_const_int(idx_decl.loc, actual_index_type, 0);
		@vec_add(&expressions, expr_generate_decl(idx_decl, idx_init));
	}

	// Add all declarations to the init
	Expr* init_expr = expr_new(EXPRESSION_LIST, var_.loc);
	init_expr.expression_list = expressions;

	Expr* update = null;
	Expr* cond;
	if (is_reverse)
	{
		// Create __idx$ > 0
		Expr* rhs = expr_new_const_int(enumerator.loc, actual_index_type, 0);
		cond = expr_new_binary(idx_decl.loc, expr_variable(idx_decl), rhs, GT);

		// Create --__idx$
		Expr* dec = expr_new(UNARY, idx_decl.loc);
		dec.unary_expr.expr = expr_variable(idx_decl);
		dec.unary_expr.operator = DEC;
		dec.unary_expr.no_wrap = true;
		Ast* update_stmt = new_ast(EXPR_STMT, idx_decl.loc);
		update_stmt.expr_stmt = dec;
		ast_append(&succ, update_stmt);
	}
	else if (is_single_pass)
	{
		cond = expr_new_const_bool(idx_decl.loc, type_bool, false);
	}
	else
	{
		// Create __idx$ < __len$
		cond = expr_new(BINARY, idx_decl.loc);
		cond.binary_expr.operator = LT;
		cond.binary_expr.left = exprid(expr_variable(idx_decl));
		if (len_decl)
		{
			cond.binary_expr.right = exprid(expr_variable(len_decl));
		}
		else
		{
			Expr* rhs = expr_new_const_int(enumerator.loc, type_sz, (ulong)array_len);
			cond.binary_expr.right = exprid(rhs);
		}

		// Create ++__idx$
		update = expr_new(UNARY, idx_decl.loc);
		update.unary_expr.expr = expr_variable(idx_decl);
		update.unary_expr.operator = INC;
		update.unary_expr.no_wrap = true;
	}

	// Create IndexType index = __idx$
	if (index)
	{
		Ast* declare_ast = new_ast(DECLARE_STMT, var_.loc);
		declare_ast.declare_stmt = index;
		Expr* load_idx = expr_variable(idx_decl);
		if (is_enum_iterator)
		{
			load_idx.type = index_var_type;
		}
		if (!cast_explicit(context, load_idx, index_var_type)) return false;
		index.var_decl.init_expr = load_idx;
		ast_append(&succ, declare_ast);
	}

	// Create value = (*__$enum)[__idx$]
	Ast* value_declare_ast = new_ast(DECLARE_STMT, var_.loc);
	value_declare_ast.declare_stmt = var_;

	Expr* subscript = expr_new(SUBSCRIPT, var_.loc);
	Expr* enum_val = expr_variable(temp);
	enum_val.loc = enumerator.loc;
	if (is_addr && !sema_expr_rewrite_insert_deref(context, enum_val)) return false;
	subscript.subscript_expr.expr = exprid(enum_val);
	Expr* index_expr = array_len == 1 ? expr_new_const_int(var_.loc, idx_decl.type, 0) : expr_variable(idx_decl);
	if (is_enum_iterator)
	{
		expr_rewrite_enum_from_ord(index_expr, index_type);
	}
	subscript.subscript_expr.index.expr = exprid(index_expr);
	subscript.subscript_expr.no_check = !len;
	if (value_by_ref || need_deref)
	{
		Expr* addr = expr_new(UNARY, subscript.loc);
		addr.unary_expr.operator = ADDR;
		addr.unary_expr.expr = subscript;
		subscript = addr;
	}
	if (need_deref)
	{
		Expr* deref = expr_new(UNARY, subscript.loc);
		deref.unary_expr.operator = DEREF;
		deref.unary_expr.expr = subscript;
		subscript = deref;
	}
	var_.var_decl.init_expr = subscript;
	ast_append(&succ, value_declare_ast);
	Ast* body_ast = astptr(body);
	ast_append(&succ, body_ast);
	Ast* compound_stmt = new_ast(COMPOUND_STMT, body_ast.loc);
	compound_stmt.compound_stmt.first_stmt = first_stmt;
	compound_stmt.compound_stmt.is_loop_body = true;
	FlowCommon flow = statement.foreach_stmt.flow;
	flow.skip_first = is_single_pass;
	statement.for_stmt = { .init = exprid(init_expr),
	                       .cond = exprid(cond),
	                       .incr = update ? exprid(update) : 0,
	                       .flow = flow,
	                       .body = astid(compound_stmt),
	};
	statement.ast_kind = FOR_STMT;
	return sema_analyse_for_stmt(context, statement);
}

// sema_stmts.c:2023 (static)
fn bool sema_check_for_dead_code(SemaContext* context, Ast* statement)
{
	if (context.active_scope.end_jump.active && !context.active_scope.allow_dead_code)
	{
		context.active_scope.allow_dead_code = true;
		bool warn = @sema_warn_at(context, statement.loc, compiler.build.warnings.dead_code, "This code will never execute.");
		if (compiler.build.warnings.dead_code.ordinal > WarningLevel.SILENT.ordinal) @sema_note_prev_at(context.active_scope.end_jump.loc, "This code is preventing it from executing");
		return warn;
	}
	return true;
}

// sema_stmts.c:2035 (static)
fn bool sema_analyse_if_stmt(SemaContext* context, Ast* statement)
{
	bool else_jump = false;
	bool then_jump = false;
	bool success;

	Expr* cond = exprptr(statement.if_stmt.cond);
	Ast* then = astptr(statement.if_stmt.then_body);
	AstId else_id = statement.if_stmt.else_body;
	Ast* else_body = else_id ? astptr(else_id) : null;
	CondResult result = COND_MISSING;
	bool is_invalid = false;
	bool reverse = false;
	DynamicScope stored_scope = scope_outer_start(context, statement.loc);
	{
		success = sema_analyse_cond(context, cond, TYPE_UNWRAP_BOOL, &result);
		if (success && cond.expr_kind == COND)
		{
			Expr*[] list = cond.cond_expr;
			reverse = list.len == 1 && list[0].expr_kind == UNARY && list[0].unary_expr.operator == NOT;
		}
		if (success && !ast_ok(then))
		{
			@sema_error_at(context, then.loc,
					   "The 'then' part of a single line if-statement must start on the same line as the 'if' or use '{ }'");
			success = false;
		}

		if (success && else_body)
		{
			bool then_has_braces = then.ast_kind == COMPOUND_STMT;
			if (!then_has_braces)
			{
				@sema_error_at(context, then.loc, "if-statements with an 'else' must use '{ }' even around a single statement.");
				success = false;
			}
			if (success && else_body.ast_kind != COMPOUND_STMT &&
				else_body.ast_kind != IF_STMT)
			{
				@sema_error_at(context, else_body.loc,
						   "An 'else' must use '{ }' even around a single statement.");
				success = false;
			}
			if (success && else_body.ast_kind == IF_STMT)
			{
				// Without an 'else' of its own the inner if-statement would accept a single statement.
				Ast* else_then = astptr(else_body.if_stmt.then_body);
				if (ast_ok(else_then) && else_then.ast_kind != COMPOUND_STMT)
				{
					@sema_error_at(context, else_then.loc, "An 'else if' must use '{ }' even around a single statement.");
					success = false;
				}
			}
		}
		// c3c: `goto END` is a break out of this loop.
		while END: (true)
		{
			if (!sema_check_for_dead_code(context, then))
			{
				success = false;
				break END;
			}
			DynamicScope old_scope = scope_start_with_label(context, statement.if_stmt.flow.label, then.loc);
			{
				if (result == COND_FALSE) context.active_scope.is_dead = true;
				success = success && sema_analyse_statement(context, then);
				if (context.active_scope.defer_last != context.active_scope.defer_start)
				{
					if (success) @sema_error_at(context, then.loc, "An 'if' statement may not be followed by a raw 'defer' statement, this looks like a mistake.");
					context.active_scope.defer_last = context.active_scope.defer_start;
					success = false;
				}
				then_jump = context.active_scope.end_jump.active && !(statement.if_stmt.flow.label && statement.if_stmt.flow.has_break);
			}
			success = scope_end(context, old_scope, success);

			if (!success) break END;
			else_jump = false;
			if (statement.if_stmt.else_body)
			{
				bool store_break = statement.if_stmt.flow.has_break;
				statement.if_stmt.flow.has_break = false;
				DynamicScope old_scope2 = scope_start_with_label(context, statement.if_stmt.flow.label, statement.loc);
				{
					if (result == COND_TRUE) context.active_scope.is_dead = true;
					sema_remove_unwraps_from_try(context, cond);
					sema_unwrappable_from_catch_in_else(context, cond);
					success = sema_analyse_statement(context, else_body);
					else_jump = context.active_scope.end_jump.active && !(statement.if_stmt.flow.label && statement.if_stmt.flow.has_break);
				}
				success = scope_end(context, old_scope2, success);
				statement.if_stmt.flow.has_break |= store_break;
			}
			break;
		}

		// END:
		context_pop_defers_and_replace_ast(context, statement);

		is_invalid = context.active_scope.is_poisoned;
	}
	scope_outer_end(context, stored_scope);
	if (is_invalid) context.active_scope.is_poisoned = true;
	if (!success)
	{
		if (then_jump && sema_catch_in_cond(cond)) context.active_scope.is_poisoned = true;
		return false;
	}
	if (then_jump)
	{
		sema_unwrappable_from_catch_in_else(context, cond);
	}
	if (then_jump && else_jump && !statement.flow.has_break)
	{
		set_jump_end(context, statement.loc);
	}
	else if (then_jump && result == COND_TRUE)
	{
		set_jump_end(context, statement.loc);
	}
	else if (else_jump && result == COND_FALSE)
	{
		set_jump_end(context, statement.loc);
	}
	if (reverse)
	{
		cond.cond_expr[0] = cond.cond_expr[0].unary_expr.expr;
		statement.if_stmt.else_body = statement.if_stmt.then_body;
		statement.if_stmt.then_body = else_id;
	}
	return true;
}

// sema_stmts.c:2164 (static)
fn bool sema_analyse_asm_string_stmt(SemaContext* context, Ast* stmt)
{
	Expr* body = exprptr(stmt.asm_block_stmt.asm_string);
	if (!sema_analyse_ct_expr(context, body)) return false;
	if (!expr_is_const_string(body))
	{
		return @sema_error_at(context, body.loc, "The asm statement expects a constant string.");
	}
	return true;
}

// When jumping to a label
// sema_stmts.c:2182 (static)
fn Decl* sema_analyse_label(SemaContext* context, Ast* stmt)
{
	Label* label = stmt.ast_kind == NEXTCASE_STMT ? &stmt.nextcase_stmt.label : &stmt.contbreak_stmt.label;
	String name = label.name;
	Decl* target = sema_find_label_symbol(context, name);
	if (!target)
	{
		target = sema_find_label_symbol_anywhere(context, name);
		if (target && target.decl_kind == LABEL)
		{
			if (target.label.scope_defer != astid(context.active_scope.in_defer))
			{
				switch (stmt.ast_kind)
				{
					case BREAK_STMT:
						@sema_error_at(context, stmt.loc, "You cannot break out of a defer.");
						return poisoned_decl;
					case CONTINUE_STMT:
						@sema_error_at(context, stmt.loc, "You cannot use continue out of a defer.");
						return poisoned_decl;
					case NEXTCASE_STMT:
						@sema_error_at(context, stmt.loc, "You cannot use nextcase out of a defer.");
						return poisoned_decl;
					default:
						unreachable();
				}
			}
			@sema_error_at(context, stmt.loc, "'%s' cannot be reached from the current scope.", name);
			return poisoned_decl;
		}
		@sema_error_at(context, stmt.loc, "A labelled statement with the name '%s' can't be found in the current scope.", name);
		return poisoned_decl;
	}
	if (target.decl_kind != LABEL)
	{
		@sema_error_at(context, label.loc, "Expected the name to match a label, not a constant.");
		return poisoned_decl;
	}
	if (context.active_scope.in_defer)
	{
		if (target.label.scope_defer != astid(context.active_scope.in_defer))
		{
			switch (stmt.ast_kind)
			{
				case BREAK_STMT:
					@sema_error_at(context, stmt.loc, "You cannot break out of a defer.");
					return poisoned_decl;
				case CONTINUE_STMT:
					@sema_error_at(context, stmt.loc, "You cannot use continue out of a defer.");
					return poisoned_decl;
				case NEXTCASE_STMT:
					@sema_error_at(context, stmt.loc, "You cannot use nextcase out of a defer.");
					return poisoned_decl;
				default:
					unreachable();
			}
		}
	}
	return target;
}

// sema_stmts.c:2243 (static)
fn bool context_labels_exist_in_scope(SemaContext* context)
{
	Decl*[] locals = context.locals;
	for (usz local = (usz)context.active_scope.current_local; local > 0; local--)
	{
		if (locals[local - 1].decl_kind == LABEL) return true;
	}
	return false;
}

// sema_stmts.c:2254 (static)
fn bool sema_analyse_nextcase_stmt(SemaContext* context, Ast* statement)
{
	set_jump_end(context, statement.loc);
	// c3c: assert(!statement.nextcase_stmt.is_resolved); -- C assert, compiled out in c3c release builds
	statement.nextcase_stmt.is_resolved = true;

	if (!context.next_jump.target && !statement.nextcase_stmt.label.name.ptr && !statement.nextcase_stmt.expr && !statement.nextcase_stmt.is_default)
	{
		if (context.next_switch)
		{
			return @sema_error_at(context, statement.loc, "A plain 'nextcase' is not allowed on the last case.");
		}
		return @sema_error_at(context, statement.loc, "'nextcase' can only be used inside of a switch.");
	}

	Ast* parent = context.next_switch;
	if (statement.nextcase_stmt.label.name.ptr)
	{
		Decl* target = sema_analyse_label(context, statement);
		if (!decl_ok(target)) return false;
		parent = astptr(target.label.parent);
		AstKind kind = parent.ast_kind;
		if (kind != SWITCH_STMT)
		{
			return @sema_error_at(context, statement.nextcase_stmt.label.loc, "Expected the label to match a 'switch' or 'if-catch' statement.");
		}
	}
	if (!parent)
	{
		return @sema_error_at(context, statement.loc, "No matching switch could be found.");
	}

	// Handle jump to default.
	Ast*[] cases = parent.switch_stmt.cases;
	statement.nextcase_stmt.is_expr = false;
	if (statement.nextcase_stmt.is_default)
	{
		int default_ast = -1;
		foreach (idx, cs : cases)
		{
			if (cs.ast_kind == DEFAULT_STMT)
			{
				default_ast = (int)idx;
				break;
			}
		}
		if (default_ast < 0) return @sema_error_at(context, statement.loc, "There is no 'default' in the switch to jump to.");
		statement.nextcase_stmt.switch_stmt = astid(parent);
		statement.nextcase_stmt.defer_id = context_get_defers(context, parent.switch_stmt.defer_id, true);
		statement.nextcase_stmt.case_number = default_ast;
		return true;
	}

	Expr* value = exprptrzero(statement.nextcase_stmt.expr);
	statement.nextcase_stmt.switch_stmt = astid(parent);
	if (!value)
	{
		assert(context.next_jump.target);
		statement.nextcase_stmt.defer_id = context_get_defers(context, parent.switch_stmt.defer_id, true);
		statement.nextcase_stmt.case_number = context.next_jump.target.case_stmt.index;
		return true;
	}

	Expr* cond = exprptrzero(parent.switch_stmt.cond);

	if (!cond)
	{
		return @sema_error_at(context, statement.loc, "'nextcase' cannot be used with an expressionless switch.");
	}

	if (value.expr_kind == TYPEINFO)
	{
		TypeInfo* type_info = value.type_expr;
		if (!sema_resolve_type_info(context, type_info, RESOLVE_TYPE_DEFAULT)) return false;
		statement.nextcase_stmt.defer_id = context_get_defers(context, parent.switch_stmt.defer_id, true);
		if (cond.type.canonical != type_typeid)
		{
			@sema_error_at(context, statement.loc, "Unexpected 'type' in as an 'nextcase' destination.");
			@sema_note_prev_at(statement.loc, "The 'switch' here uses expected a type '%s'.", type_to_error_string(cond.type));
			return false;
		}
		Type* type = type_info.type.canonical;
		foreach (idx, case_stmt : parent.switch_stmt.cases)
		{
			if (case_stmt.ast_kind == DEFAULT_STMT) continue;
			Expr* expr = exprptr(case_stmt.case_stmt.expr);
			if (sema_cast_const(expr) && expr.const_expr.typeid_type == type)
			{
				statement.nextcase_stmt.case_number = (int)idx;
				return true;
			}
		}
		return @sema_error_at(context, type_info.loc, "There is no case for type '%s'.", type_to_error_string(type_info.type));
	}

	Type* expected_type = parent.ast_kind == SWITCH_STMT ? cond.type : type_fault;

	if (!sema_analyse_expr_rhs(context, expected_type, value, false, null, false)) return false;

	statement.nextcase_stmt.defer_id = context_get_defers(context, parent.switch_stmt.defer_id, true);

	if (sema_cast_const(value))
	{
		// c3c: `goto VARIABLE_JUMP` is a break out of the labelled loop.
		bool variable_jump = false;
		foreach VARIABLE_JUMP: (idx, case_stmt : parent.switch_stmt.cases)
		{
			if (case_stmt.ast_kind == DEFAULT_STMT) continue;
			Expr* from = exprptr(case_stmt.case_stmt.expr);
			if (!sema_cast_const(from))
			{
				variable_jump = true;
				break VARIABLE_JUMP;
			}
			ExprConst* const_expr = &from.const_expr;
			ExprConst* to_const_expr = case_stmt.case_stmt.to_expr ? &exprptr(case_stmt.case_stmt.to_expr).const_expr : const_expr;
			if (expr_const_in_range(&value.const_expr, &value.const_expr, const_expr, to_const_expr))
			{
				statement.nextcase_stmt.case_number = (int)idx;
				return true;
			}
		}
		if (!variable_jump)
		{
			return @sema_error_at(context, value.loc, "There is no 'case %s' in the switch, please check if a case is missing or if this value is incorrect.", expr_const_to_error_string(&value.const_expr));
		}
	}
	// VARIABLE_JUMP:
	statement.nextcase_stmt.is_expr = true;
	statement.nextcase_stmt.nextcase_value = value;
	return true;
}

// sema_stmts.c:2380 (static)
fn bool sema_analyse_then_overwrite(SemaContext* context, Ast* statement, AstId replacement)
{
	if (!replacement)
	{
		statement.ast_kind = NOP_STMT;
		return true;
	}
	Ast* last = null;
	statement.ast_kind = NOP_STMT;
	AstId next = statement.next;
	statement.next = replacement;
	AstId current = replacement;
	assert(current);
	while (current)
	{
		Ast* ast = ast_next(&current);
		if (!sema_analyse_statement(context, ast)) return false;
		last = ast;
	}
	last = ast_last(last);
	last.next = next;
	return true;
}

// sema_stmts.c:2405 (static)
fn bool sema_analyse_ct_if_stmt(SemaContext* context, Ast* statement)
{
	int ct_context = sema_context_push_ct_stack(context);
	// c3c: `goto SUCCESS` / `goto FAILED` set `success` and fall out.
	bool success = false;
	CondResult res = sema_check_comp_time_bool(context, statement.ct_if_stmt.expr);
	if (res == COND_TRUE)
	{
		success = sema_analyse_then_overwrite(context, statement, statement.ct_if_stmt.then);
	}
	else if (res != COND_MISSING)
	{
		Ast* elif = astptrzero(statement.ct_if_stmt.elif);
		while (true)
		{
			if (!elif)
			{
				// Turn into NOP!
				statement.ast_kind = NOP_STMT;
				success = true;
				break;
			}
			// We found else, then just replace with that.
			if (elif.ast_kind == CT_ELSE_STMT)
			{
				success = sema_analyse_then_overwrite(context, statement, elif.ct_else_stmt);
				break;
			}
			assert(elif.ast_kind == CT_IF_STMT);

			res = sema_check_comp_time_bool(context, elif.ct_if_stmt.expr);
			if (res == COND_MISSING) break;
			if (res == COND_TRUE)
			{
				success = sema_analyse_then_overwrite(context, statement, elif.ct_if_stmt.then);
				break;
			}
			elif = astptrzero(elif.ct_if_stmt.elif);
		}
	}
	sema_context_pop_ct_stack(context, ct_context);
	return success;
}

// sema_stmts.c:2449 (static)
fn bool sema_analyse_compound_statement_no_scope(SemaContext* context, Ast* compound_statement)
{
	bool all_ok = ast_ok(compound_statement);
	AstId current = compound_statement.compound_stmt.first_stmt;
	Ast* ast = null;
	while (current)
	{
		ast = ast_next(&current);
		if (!sema_analyse_statement(context, ast))
		{
			ast_poison(ast);
			all_ok = false;
			// Don't continue inside a macro, since we get too many "inlined" errors.
			if (context.current_macro) break;
		}
	}
	if (all_ok && compound_statement.compound_stmt.is_loop_body && context.active_scope.defer_last != context.active_scope.defer_start)
	{
		@sema_error_at(context, ast.loc, "Looping over a raw 'defer' is not allowed, was this a mistake?");
		all_ok = false;
	}
	AstId* next = ast ? &ast_last(ast).next : &compound_statement.compound_stmt.first_stmt;
	context_pop_defers(context, next);
	return all_ok;
}

// sema_stmts.c:2475 (static)
fn bool sema_check_type_case(SemaContext* context, Ast* case_stmt, Ast*[] cases, int index)
{
	Expr* expr = exprptr(case_stmt.case_stmt.expr);
	if (case_stmt.case_stmt.to_expr)
	{
		return @sema_error_at(context, exprptr(case_stmt.case_stmt.to_expr).loc, "Case ranges are not allowed when switching on a typeid.");
	}
	if (!sema_analyse_expr_rhs(context, type_typeid, expr, false, null, false)) return false;

	if (sema_cast_const(expr))
	{
		Type* my_type = expr.const_expr.typeid_type;
		for (int i = 0; i < index; i++)
		{
			Ast* other = cases[i];
			if (other.ast_kind != CASE_STMT) continue;
			Expr* other_expr = exprptr(other.case_stmt.expr);
			if (sema_cast_const(other_expr) && other_expr.const_expr.typeid_type == my_type)
			{
				@sema_error_at(context, case_stmt.loc, "The same type appears more than once.");
				@sema_note_prev_at(other.loc, "Here is the case with that type.");
				return false;
			}
		}
	}
	return true;
}

// sema_stmts.c:2503 (static)
fn bool sema_check_duplicate_case(SemaContext* context, Ast* case_stmt, Ast*[] cases, int index, ExprConst* const_expr, ExprConst* to_const_expr)
{
	bool compare_folded = const_expr.const_kind == INTEGER || const_expr.const_kind == ENUM;
	if (!compare_folded && !case_stmt.case_stmt.was_constant) return true;
	for (int i = 0; i < index; i++)
	{
		Ast* other = cases[i];
		if (other.ast_kind != CASE_STMT) continue;
		Expr* other_expr = exprptr(other.case_stmt.expr);
		Expr* other_to_expr = exprptrzero(other.case_stmt.to_expr);
		if (!compare_folded && !other.case_stmt.was_constant) continue;
		if (!sema_cast_const(other_expr)) continue;
		if (other_to_expr && !sema_cast_const(other_to_expr)) continue;
		ExprConst* other_const = &other_expr.const_expr;
		ExprConst* other_to_const = other_to_expr ? &other_to_expr.const_expr : other_const;
		if (expr_const_in_range(const_expr, to_const_expr, other_const, other_to_const))
		{
			@sema_error_at(context, case_stmt.loc, "The same case value appears more than once.");
			@sema_note_prev_at(other.loc, "Here is the previous use of that value.");
			return false;
		}
	}
	return true;
}

// sema_stmts.c:2528 (static)
fn bool sema_check_value_case(SemaContext* context, Type* switch_type, Ast* case_stmt, Ast*[] cases, int index, bool* if_chained, bool* max_ranged, long* actual_cases_ref, Int* low, Int* high)
{
	assert(switch_type);
	Expr* expr = exprptr(case_stmt.case_stmt.expr);
	Expr* to_expr = exprptrzero(case_stmt.case_stmt.to_expr);
	// Non-integer cases only diagnose duplicates that were already constant before folding.
	case_stmt.case_stmt.was_constant = expr.expr_kind == CONST;

	// 1. Try to do implicit conversion to the correct type.
	if (!sema_analyse_expr_rhs(context, switch_type, expr, false, null, false)) return false;
	if (to_expr && !sema_analyse_expr_rhs(context, switch_type, to_expr, false, null, false)) return false;

	bool is_range = to_expr != null;
	bool first_is_const = sema_cast_const(expr) && (expr_is_const_int(expr) || expr_is_const_enum(expr));
	if (!is_range && !first_is_const)
	{
		*if_chained = true;
		if (!sema_cast_const(expr)) return true;
		if (expr.const_expr.const_kind == FLOAT && math::is_nan(expr.const_expr.fxx.f))
		{
			return @sema_error_at(context, expr.loc, "A NaN case can never match, since NaN is not equal to anything, including itself.");
		}
		return sema_check_duplicate_case(context, case_stmt, cases, index, &expr.const_expr, &expr.const_expr);
	}
	(*actual_cases_ref)++;
	if (is_range)
	{
		bool second_is_const = sema_cast_const(to_expr) && (expr_is_const_int(to_expr) || expr_is_const_enum(to_expr));
		if (!first_is_const || !second_is_const) return @sema_error_at(context, (first_is_const ? to_expr : expr).loc, "Ranges must be constant integers or enum values, but this is not an integer / enum constant.");
	}
	bool is_enum = expr_is_const_enum(expr);
	ExprConst* const_expr = &expr.const_expr;
	ExprConst* to_const_expr = to_expr ? &to_expr.const_expr : const_expr;

	if (const_expr.const_kind == INTEGER)
	{
		if (low.type == POISONED || int_comp(*low, const_expr.ixx, GT)) *low = const_expr.ixx;
		if (high.type == POISONED || int_comp(*high, to_const_expr.ixx, LT)) *high = to_const_expr.ixx;
	}
	if (!*max_ranged && is_range)
	{
		if (is_enum)
		{
			int ord1 = const_expr.enum_val.enum_constant.inner_ordinal;
			int ord2 = to_const_expr.enum_val.enum_constant.inner_ordinal;
			if (ord1 > ord2)
			{
				@sema_error_at(context, make_loc(extend_loc_with_token(sourcelocptr(expr.loc), sourcelocptr(to_expr.loc))),
				              "The range is not valid because the first enum (%s) has a higher ordinal than the second (%s). "
				              "It would work if you swapped their order.",
				              const_expr.enum_val.name,
				              to_const_expr.enum_val.name);
				return false;
			}
			(*actual_cases_ref) += (long)(ord2 - ord1);
			if (compiler.build.switchrange_max_size < ord2 - ord1)
			{
				*max_ranged = true;
			}
		}
		else
		{
			if (int_comp(const_expr.ixx, to_const_expr.ixx, GT))
			{
				@sema_error_at(context, make_loc(extend_loc_with_token(sourcelocptr(expr.loc), sourcelocptr(to_expr.loc))),
				              "The range is not valid because the first value (%s) is greater than the second (%s). "
				              "It would work if you swapped their order.",
				              int_to_str(const_expr.ixx, 10, false),
				              int_to_str(to_const_expr.ixx, 10, false));
				return false;
			}
			uint128 range = int_sub(to_const_expr.ixx, const_expr.ixx).i;
			uint128 max_range = (uint128)(ulong)compiler.build.switchrange_max_size;
			*actual_cases_ref += (long)(ulong)range;
			if (range > max_range)
			{
				*max_ranged = true;
			}
		}
	}
	return sema_check_duplicate_case(context, case_stmt, cases, index, const_expr, to_const_expr);
}

// sema_stmts.c:2612 (static)
fn String create_missing_enums_in_switch_error(Ast*[] cases, int found_count, Decl*[] enums)
{
	int enum_count = (int)enums.len;
	int missing = enum_count - found_count;
	scratch_buffer_clear();
	if (missing == 1)
	{
		scratch_buffer_append("Enum value ");
	}
	else
	{
		@scratch_buffer_printf("%d enum values were not handled in the switch: ", missing);
	}
	int case_count = (int)cases.len;
	int printed = 0;
	// c3c: `goto CONTINUE` / `goto DONE` are the labelled continue / break.
	for DONE: (int i = 0; i < enum_count; i++)
	{
		bool handled = false;
		for (int j = 0; j < case_count; j++)
		{
			Expr* e = exprptr(cases[j].case_stmt.expr);
			Expr* e_to = exprptrzero(cases[j].case_stmt.to_expr);
			assert(expr_is_const_enum(e));
			int ordinal_from = e.const_expr.enum_val.enum_constant.inner_ordinal;
			int ordinal_to = e_to ? e_to.const_expr.enum_val.enum_constant.inner_ordinal : ordinal_from;
			if (i >= ordinal_from && i <= ordinal_to)
			{
				handled = true;
				break;
			}
		}
		if (handled) continue DONE;
		if (++printed != 1)
		{
			scratch_buffer_append(printed == missing ? " and " : ", ");
		}
		scratch_buffer_append(enums[i].name);
		if (printed > 2 && missing > 3)
		{
			scratch_buffer_append(", ...");
			break DONE;
		}
		if (printed == missing) break DONE;
	}
	// DONE:
	if (missing == 1)
	{
		scratch_buffer_append(" was not handled in the switch - either add it or add 'default'.");
		return scratch_buffer_str();
	}
	scratch_buffer_append(" - either add them or use 'default'.");
	return scratch_buffer_str();
}

// sema_stmts.c:2660 (static)
fn bool sema_analyse_switch_body(SemaContext* context, Ast* statement, SourceLocId expr_loc, CanonicalType* switch_type, Ast*[] cases)
{
	bool is_enum_switch = false;
	bool if_chain = true;
	Decl*[] enum_values;
	if (type_is_comparable(switch_type))
	{
		Type* flat = type_flatten(switch_type);
		TypeKind flat_switch_type_kind = flat.type_kind;
		is_enum_switch = flat_switch_type_kind == ENUM;
		if (is_enum_switch) enum_values = flat.decl.enums.values;
		// We need an if-chain if this isn't an enum/integer type.
		if_chain = !is_enum_switch && !type_kind_is_any_integer(flat_switch_type_kind);
	}
	else
	{
		return @sema_error_at(context, expr_loc, "You cannot switch over '%s'. Only types that natively support '==' may be used.", type_to_error_string(switch_type));
	}
	Ast* default_case = null;
	assert(context.active_scope.defer_start == context.active_scope.defer_last);

	bool exhaustive = false;
	int case_count = (int)cases.len;
	bool success = true;
	bool max_ranged = false;
	bool type_switch = switch_type == type_typeid;
	long actual_enum_cases = 0;
	Int low = { .type = POISONED };
	Int high = { .type = POISONED };
	for (int i = 0; i < case_count; i++)
	{
		if (!success) break;
		Ast* stmt = cases[i];
		Ast* next = (i < case_count - 1) ? cases[i + 1] : null;
		NextJumpState old_next = push_next(context, next, statement);
		switch (stmt.ast_kind)
		{
			case CASE_STMT:
				if (type_switch)
				{
					if (!sema_check_type_case(context, stmt, cases, i))
					{
						success = false;
						break;
					}
				}
				else
				{
					if (!sema_check_value_case(context, switch_type, stmt, cases, i, &if_chain, &max_ranged, &actual_enum_cases, &low, &high))
					{
						success = false;
						break;
					}
				}
			case DEFAULT_STMT:
				exhaustive = true;
				if (default_case)
				{
					@sema_error_at(context, stmt.loc, "'default' may only appear once in a single 'switch', please remove one.");
					@sema_note_prev_at(default_case.loc, "Here is the previous use.");
					success = false;
				}
				default_case = stmt;
			default:
				unreachable();
		}
		pop_next(context, old_next);
	}

	if (success && if_chain && default_case && cases[case_count - 1] != default_case)
	{
		int i = 0;
		while (cases[i] != default_case) i++;
		@sema_error_at(context, cases[i + 1].loc, "A 'case' may not follow 'default' in this switch: its cases are evaluated in order, so this case would never be evaluated.");
		@sema_note_prev_at(default_case.loc, "The 'default' is here.");
		return false;
	}
	if (!exhaustive && is_enum_switch) exhaustive = actual_enum_cases == enum_values.len;
	bool all_jump_end = exhaustive;
	for (int i = 0; i < case_count; i++)
	{
		Ast* stmt = cases[i];
		DynamicScope old_scope = scope_start(context, statement.loc);
		{
			JumpTarget old_break = push_break(context, statement);
			Ast* next = (i < case_count - 1) ? cases[i + 1] : null;
			NextJumpState old_next = push_next(context, next, statement);
			Ast* body = stmt.case_stmt.body;
			success = success && (!body || sema_analyse_compound_statement_no_scope(context, body));
			context.break_jump = old_break;
			pop_next(context, old_next);
			// c3c's `continue` leaves the do-while(0) of SCOPE_START before
			// SCOPE_END runs, so the scope is not restored; kept as is.
			if (!body && i < case_count - 1) continue;
			all_jump_end &= context.active_scope.end_jump.active;
		}
		success = scope_end(context, old_scope, success);
	}
	if (is_enum_switch && !exhaustive && success && !if_chain)
	{
		return @sema_error_at(context, statement.loc, "%s", create_missing_enums_in_switch_error(cases, (int)actual_enum_cases, enum_values));
	}
	if (statement.flow.jump)
	{
		if (if_chain) return @sema_error_at(context, statement.loc, "The switch cannot use a jump table because it cannot be translated into a jump, please remove '@jump'.");
		// Ignore max ranged
		max_ranged = false;
		if (low.type != POISONED)
		{
			high.type = I128;
			low.type = I128;
			Int range = int_sub(high, low);
			Int max = { .i = (uint128)(ulong)compiler.build.switchjump_max_size, .type = range.type };
			if (int_comp(range, max, GE))
			{
				return @sema_error_at(context, statement.loc, "The switch cannot use a jump table size of the table would exceed "
				                             "the maximum allowed (%d), please remove '@jump'.", compiler.build.switchjump_max_size);
			}
		}
		// Do not generate a jump table if we only have a default statement.
		if (default_case && case_count == 1)
		{
			statement.flow.jump = false;
		}
	}

	statement.flow.no_exit = all_jump_end;
	statement.switch_stmt.flow.if_chain = if_chain || max_ranged;
	return success;
}

// sema_stmts.c:2791 (static)
fn bool sema_analyse_ct_switch_stmt(SemaContext* context, Ast* statement)
{
	int ct_context = sema_context_push_ct_stack(context);
	// c3c: `goto FAILED` is `break FAILED`, `goto SUCCESS` sets `success`.
	bool success = false;
	while FAILED: (true)
	{
		// Evaluate the switch statement
		Expr* cond = exprptrzero(statement.ct_switch_stmt.cond);
		if (cond && !sema_analyse_ct_expr(context, cond)) break FAILED;

		// If we have a type, then we do different evaluation
		// compared to when it is a value.
		Type* type = cond ? cond.type : type_bool;
		bool is_type = false;
		switch (type_flatten(type).type_kind)
		{
			case TYPEID:
				is_type = true;
				nextcase ENUM;
			case ENUM:
			case CONSTSET:
			case I8..I128:
			case U8..U128:
			case F16..F128:
			case BOOL:
				break;
			case SLICE:
				if (expr_is_const_string(cond)) break;
				nextcase default;
			default:
				assert(cond);
				@sema_error_at(context, cond.loc, "Only types, strings, enums, integers, floats and booleans may be used with '$switch'."); // NOLINT
				break FAILED;
		}

		ExprConst* switch_expr_const = cond ? &cond.const_expr : null;
		Ast*[] cases = statement.ct_switch_stmt.body;

		int case_count = (int)cases.len;
		assert(case_count <= int::max);
		int matched_case = (int)case_count;
		int default_case = (int)case_count;

		// Go through each case
		for (int i = 0; i < case_count; i++)
		{
			Ast* stmt = cases[i];
			switch (stmt.ast_kind)
			{
				case CASE_STMT:
					Expr* expr = exprptr(stmt.case_stmt.expr);
					// c3c: assert(expr); -- C assert, compiled out in c3c release builds
					Expr* to_expr = exprptrzero(stmt.case_stmt.to_expr);
					if (to_expr && !type_is_integer(type_flatten(type)))
					{
						@sema_error_at(context, to_expr.loc, "$case ranges are only allowed for integers.");
						break FAILED;
					}
					// Do not evaluate if found.
					if (matched_case != case_count && expr && expr.resolve_status != DONE)
					{
						continue;
					}
					if (is_type)
					{
						if (!sema_analyse_ct_expr(context, expr)) break FAILED;
						if (expr.type != type_typeid)
						{
							@sema_error_at(context, expr.loc, "A type was expected here not %s.", type_quoted_error_string(expr.type));
							break FAILED;
						}
					}
					else
					{
						// Do not evaluate if found.
						if (matched_case != case_count && expr.resolve_status != DONE) continue;
						if (!sema_analyse_expr_rhs(context, type, expr, false, null, false)) break FAILED;
						if (to_expr && !sema_analyse_expr_rhs(context, type, to_expr, false, null, false)) break FAILED;
					}
					if (!sema_cast_const(expr))
					{
						@sema_error_at(context, expr.loc, "The $case must have a constant expression.");
						break FAILED;
					}
					if (!cond)
					{
						if (!expr.const_expr.b) continue;
						if (matched_case == case_count) matched_case = (int)i;
						continue;
					}
					if (to_expr && !sema_cast_const(to_expr))
					{
						@sema_error_at(context, to_expr.loc, "The $case must have a constant expression.");
						break FAILED;
					}
					ExprConst* const_expr = &expr.const_expr;
					ExprConst* const_to_expr = to_expr ? &to_expr.const_expr : const_expr;
					if (to_expr && expr_const_compare(const_expr, const_to_expr, GT))
					{
						@sema_error_at(context, to_expr.loc, "The end of a range must be less or equal to the beginning.");
						break FAILED;
					}
					// Check that it is unique.
					for (int j = 0; j < i; j++)
					{
						Ast* other_stmt = cases[j];
						if (other_stmt.ast_kind == DEFAULT_STMT) continue;
						Expr* other = exprptr(other_stmt.case_stmt.expr);
						Expr* other_to = exprptrzero(other_stmt.case_stmt.to_expr);
						if (other.resolve_status != DONE) continue;
						if (other_to && other_to.resolve_status != DONE) continue;
						ExprConst* other_const = &other.const_expr;
						ExprConst* other_const_to = other_to ? &other_to.const_expr : other_const;
						if (expr_const_in_range(const_expr, const_to_expr, other_const, other_const_to))
						{
							@sema_error_at(context, stmt.loc, "'%s' appears more than once.", expr_const_to_error_string(const_expr));
							@sema_note_prev_at(exprptr(cases[j].case_stmt.expr).loc, "The previous $case was here.");
							break FAILED;
						}
					}
					if (is_type)
					{
						assert(const_expr == const_to_expr);
						Type* switch_type = switch_expr_const.typeid_type;
						Type* case_type = const_expr.typeid_type;
						if (matched_case > i && type_is_subtype(case_type.canonical, switch_type.canonical))
						{
							matched_case = (int)i;
						}
					}
					else if (expr_const_in_range(switch_expr_const, switch_expr_const, const_expr, const_to_expr))
					{
						matched_case = (int)i;
					}
				case DEFAULT_STMT:
					if (i != case_count - 1)
					{
						@sema_error_at(context, stmt.loc, "$default must be last in a $switch.");
						break FAILED;
					}
					default_case = (int)i;
					continue;
				default:
					unreachable();
			}
		}

		if (matched_case == case_count) matched_case = default_case;

		Ast* body = null;
		for (int i = matched_case; i < case_count; i++)
		{
			body = cases[i].case_stmt.body;
			if (body) break;
		}
		if (!body)
		{
			statement.ast_kind = NOP_STMT;
			success = true;
			break FAILED;
		}
		success = sema_analyse_then_overwrite(context, statement, body.compound_stmt.first_stmt);
		break;
	}
	sema_context_pop_ct_stack(context, ct_context);
	return success;
}

// sema_stmts.c:2960 (static)
fn bool sema_analyse_ct_foreach_stmt(SemaContext* context, Ast* statement)
{
	int ct_context = sema_context_push_ct_stack(context);
	Expr* collection = exprptr(statement.ct_foreach_stmt.expr);
	if (!sema_analyse_ct_expr(context, collection)) return false;
	// c3c: `goto FAILED_NO_LIST` / `goto FAILED` break out of the labelled loop.
	bool failed_no_list = false;
	while FAILED: (true)
	{
		if (!expr_is_const(collection))
		{
			failed_no_list = true;
			break FAILED;
		}
		int count = -1;
		ConstInitializer* initializer = null;
		Expr*[] expressions;
		Type* const_list_type = null;
		char* bytes = null;
		Type* bytes_type = null;
		switch (collection.const_expr.const_kind)
		{
			case FLOAT:
			case INTEGER:
			case BOOL:
			case ENUM:
			case FAULT:
			case POINTER:
			case TYPEID:
			case REF:
			case MEMBER:
			case REFLECTION:
				failed_no_list = true;
				break FAILED;
			case SLICE:
				if (!collection.const_expr.slice_init)
				{
					sema_context_pop_ct_stack(context, ct_context);
					statement.ast_kind = NOP_STMT;
					return true;
				}
				initializer = collection.const_expr.slice_init;
				nextcase INITIALIZER;
			case INITIALIZER:
				if (collection.const_expr.const_kind == INITIALIZER) initializer = collection.const_expr.initializer;
				// INITIALIZER:
				ConstInitType init_type = initializer.kind;
				const_list_type = type_flatten(collection.type);
				if (const_list_type.type_kind == ARRAY || type_kind_is_real_vector(const_list_type.type_kind))
				{
					count = (int)const_list_type.array.len;
				}
				else
				{
					count = (int)sema_len_from_const(collection);
					if (count <= 0)
					{
						if (count < 0 && init_type != INIT_ZERO)
						{
							@sema_error_at(context, collection.loc, "Only regular arrays are allowed here.");
							break FAILED;
						}
						sema_context_pop_ct_stack(context, ct_context);
						statement.ast_kind = NOP_STMT;
						return true;
					}
				}
			case UNTYPED_LIST:
				expressions = collection.const_expr.untyped_list;
				count = (int)expressions.len;
			case BYTES:
			case STRING:
				bytes = collection.const_expr.bytes.ptr;
				count = (int)collection.const_expr.bytes.len;
				bytes_type = type_get_indexed_type(collection.type);
		}
		Decl* index = declptrzero(statement.ct_foreach_stmt.index);

		AstId start = 0;
		if (index)
		{
			index.type = type_int;
			if (!sema_add_local(context, index)) break FAILED;
		}
		Decl* value = declptr(statement.ct_foreach_stmt.value);
		if (!sema_add_local(context, value)) break FAILED;
		// Get the body
		Ast* body = astptr(statement.ct_foreach_stmt.body);
		AstId* current = &start;
		int loop_context = sema_context_push_ct_stack(context);
		for (int i = 0; i < count; i++)
		{
			sema_context_pop_ct_stack(context, loop_context);
			Ast* compound_stmt = copy_ast_single(body);
			if (expressions.ptr)
			{
				Expr* expr = expressions[i];
				value.var_decl.init_expr = expr;
				value.type = expr.type;
			}
			else if (bytes)
			{
				value.var_decl.init_expr = expr_new(CONST, collection.loc);
				// c3c passes a (signed) `char` to a uint64_t parameter.
				expr_rewrite_const_int(value.var_decl.init_expr, bytes_type, (ulong)(long)(ichar)bytes[i]);
				value.type = bytes_type;
			}
			else
			{
				Expr* expr = expr_new(CONST, collection.loc);
				if (!expr_rewrite_to_const_initializer_index(const_list_type, initializer, expr, i, false))
				{
					@sema_error_at(context, collection.loc, "Complex expressions are not allowed.");
					break FAILED;
				}
				value.var_decl.init_expr = expr;
				value.type = const_list_type;
			}
			if (index)
			{
				index.var_decl.init_expr = expr_new_const_int(index.loc, type_int, (ulong)i);
				index.type = type_int;
			}
			if (!sema_analyse_statement(context, compound_stmt)) break FAILED;
			*current = astid(compound_stmt);
			current = &compound_stmt.next;
		}
		sema_context_pop_ct_stack(context, ct_context);
		if (!start)
		{
			statement.ast_kind = NOP_STMT;
		}
		else
		{
			statement.ast_kind = CT_COMPOUND_STMT;
			statement.ct_compound_stmt = start;
		}
		return true;
	}
	if (failed_no_list)
	{
		// FAILED_NO_LIST:
		@sema_error_at(context, collection.loc, "Expected a list to iterate over, but this was a non-list expression of type %s.",
		           type_quoted_error_string(collection.type));
	}
	// FAILED:
	sema_context_pop_ct_stack(context, ct_context);
	return false;
}

// sema_stmts.c:3099 (static)
fn bool sema_analyse_switch_stmt(SemaContext* context, Ast* statement)
{
	statement.switch_stmt.scope_defer = context.active_scope.in_defer;

	DynamicScope old_scope = scope_start_with_label(context, statement.switch_stmt.flow.label, statement.loc);
	{
		Expr* cond = exprptrzero(statement.switch_stmt.cond);
		Type* switch_type;

		if (statement.ast_kind == SWITCH_STMT)
		{
			CondResult res = COND_MISSING;
			if (cond && !sema_analyse_cond(context, cond, TYPE_EVALTYPE_VALUE, &res)) return false;
			Expr* last = cond ? @veclast(cond.cond_expr) : null;
			switch_type = last ? last.type.canonical : type_bool;
		}
		else
		{
			switch_type = type_fault;
		}

		statement.switch_stmt.defer_id = context.active_scope.defer_last;
		if (!sema_analyse_switch_body(context, statement, cond ? cond.loc : statement.loc,
		                              switch_type.canonical,
		                              statement.switch_stmt.cases))
		{
			return scope_pop_error(context, old_scope);
		}
		context_pop_defers_and_replace_ast(context, statement);
	}
	if (!scope_end_check(context, old_scope)) return false;

	if (statement.flow.no_exit && !statement.flow.has_break)
	{
		set_jump_end(context, statement.loc);
	}
	return true;
}

// sema_stmts.c:3139
fn bool sema_analyse_ct_assert_stmt(SemaContext* context, Ast* statement)
{
	Expr* expr = exprptrzero(statement.assert_stmt.expr);
	ExprId message = statement.assert_stmt.message;
	Expr* message_expr = message ? exprptr(message) : null;
	if (message_expr)
	{
		if (!sema_analyse_expr_rvalue(context, message_expr)) return false;
		if (message_expr.expr_kind != CONST || message_expr.const_expr.const_kind != STRING)
		{
			return @sema_error_at(context, message_expr.loc, "Expected a string as the error message.");
		}
	}
	CondResult res = expr ? sema_check_comp_time_bool(context, expr) : COND_FALSE;

	if (res == COND_MISSING) return false;
	SourceLocId span = expr ? expr.loc : statement.loc;
	if (res == COND_FALSE)
	{
		if (message_expr)
		{
			int len = (int)statement.assert_stmt.args.len;
			if (len && !sema_expr_analyse_sprintf(context, message_expr, message_expr, statement.assert_stmt.args, len)) return false;
			@sema_error_at(context, span, "%s", (String)message_expr.const_expr.bytes.ptr[:message_expr.const_expr.bytes.len]);
		}
		else
		{
			@sema_error_at(context, span, "Compile time assert failed.");
		}
		context.active_scope.is_poisoned = true;
		return false;
	}
	statement.ast_kind = NOP_STMT;
	return true;
}

// sema_stmts.c:3175
fn bool sema_analyse_ct_expand_stmt(SemaContext* context, Ast* stmt)
{
	Expr* string = stmt.expand_stmt;
	if (!sema_analyse_ct_expr(context, string)) return false;
	if (!expr_is_const_string(string)) return @sema_error_at(context, string.loc, "Expected a constant string to '$expand'.");
	scratch_buffer_clear();
	SourceLoc* loc = sourcelocptr(string.loc);
	@scratch_buffer_printf("%s.%d.%d", context.unit.file.full_path, loc.row, loc.col);
	SourceFile* file = source_file_text_load(scratch_buffer_str(), str_copy((String)string.const_expr.bytes.ptr[:string.const_expr.bytes.len]));
	Ast* result = parse_include_file_stmts(file, context.unit);
	stmt.ast_kind = NOP_STMT;
	if (!result) return true;
	if (!ast_ok(result)) return ast_poison(stmt);
	return sema_analyse_then_overwrite(context, stmt, astid(result));
}

// sema_stmts.c:3191
fn bool sema_analyse_ct_echo_stmt(SemaContext* context, Ast* statement)
{
	Expr* message = statement.expr_stmt;
	if (!sema_analyse_expr_rvalue(context, message)) return false;
	if (!sema_cast_const(message))
	{
		return @sema_error_at(context, message.loc, "Expected a constant value.");
	}
	String prefix = compiler.build.echo_prefix.ptr ? compiler.build.echo_prefix : "c3c:";
	// c3c strstr: NONE stands for a NULL result.
	const sz NONE = -1;
	while (prefix.len > 0)
	{
		sz next_file = prefix.index_of("{FILE}") ?? NONE;
		sz next_line = prefix.index_of("{LINE}") ?? NONE;
		sz next = next_line;
		if (next_file != NONE)
		{
			if (next_line != NONE && next_line < next_file)
			{
				next = next_line;
				next_file = NONE;
			}
			else
			{
				next = next_file;
				next_line = NONE;
			}
		}
		if (next == NONE)
		{
			io::print(prefix);
			break;
		}
		if (next != 0)
		{
			io::print(prefix[:next]);
		}
		prefix = prefix[next + 6..];
		if (next_line != NONE)
		{
			io::printf("%d", sourcelocptr(statement.loc).row);
		}
		else
		{
			SourceFile* file = source_file_by_id(sourcelocptr(statement.loc).file_id);
			io::print(file.name);
		}
	}
	io::print(" ");
	scratch_buffer_clear();
	if (type_is_void(message.type))
	{
		scratch_buffer_append("(void)");
	}
	else
	{
		expr_const_to_scratch_buffer(&message.const_expr);
	}
	io::printn(scratch_buffer_str());
	statement.ast_kind = NOP_STMT;
	return true;
}

// $for(<list of ct decl/expr>, <cond>, <incr>):
// sema_stmts.c:3256 (static)
fn bool sema_analyse_ct_for_stmt(SemaContext* context, Ast* statement)
{
	int for_context = sema_context_push_ct_stack(context);
	// c3c: `goto FAILED` is `break FAILED`.
	while FAILED: (true)
	{
		ExprId init;
		if ((init = statement.for_stmt.init))
		{
			Expr* init_expr = exprptr(init);
			assert(init_expr.expr_kind == EXPRESSION_LIST);

			// Check the list of expressions.
			foreach (expr : init_expr.expression_list)
			{
				// Only a subset of declarations are allowed. We check this here.
				if (expr.expr_kind == DECL)
				{
					Decl* decl = expr.decl_expr;
					if (decl.decl_kind != VAR || (decl.var_decl.kind != LOCAL_CT && decl.var_decl.kind != LOCAL_CT_TYPE))
					{
						@sema_error_at(context, expr.loc, "Only 'var $foo' and 'var $Type' declarations are allowed in '$for'");
						break FAILED;
					}
					if (!sema_analyse_var_decl_ct(context, decl, null)) break FAILED;
					continue;
				}
				// If expression evaluate it and make sure it is constant.
				if (!sema_analyse_ct_expr(context, expr)) break FAILED;
			}
		}
		ExprId condition = statement.for_stmt.cond;
		ExprId incr = statement.for_stmt.incr;
		Ast* body = astptr(statement.for_stmt.body);
		AstId start = 0;
		AstId* current = &start;
		Expr*[] incr_list = incr ? exprptr(incr).expression_list : {};
		assert(condition);
		// We set a maximum of macro iterations.
		// we might consider reducing this.
		int current_ct_scope = sema_context_push_ct_stack(context);
		for (int i = 0; ; i++)
		{
			if (i >= compiler.build.max_macro_iterations)
			{
				@sema_error_at(context, statement.loc, "Too many iterations in '$for' (it exceeded %d), you can change this limit using '--max-macro-iterations'.", compiler.build.max_macro_iterations);
				break FAILED;
			}
			sema_context_pop_ct_stack(context, current_ct_scope);
			// First evaluate the cond, which we note that we *must* have.
			// we need to make a copy
			Expr* copy = copy_expr_single(exprptr(condition));
			CondResult result = COND_MISSING;
			if (!sema_analyse_cond_expr(context, copy, &result)) break FAILED;
			if (result == COND_MISSING)
			{
				@sema_error_at(context, copy.loc, "Expected a value that can be evaluated at compile time.");
				break FAILED;
			}
			// Break if we reached "false"
			if (result == COND_FALSE) break;

			// Otherwise we copy the body.
			Ast* compound_stmt = copy_ast_single(body);

			// Analyse the body
			if (!sema_analyse_statement(context, compound_stmt)) break FAILED;

			// Append it.
			*current = astid(compound_stmt);
			current = &compound_stmt.next;

			// Copy and evaluate all the expressions in "incr"
			foreach (expr : incr_list)
			{
				if (!sema_analyse_ct_expr(context, copy_expr_single(expr))) break FAILED;
			}
		}
		// Analysis is done turn the generated statements into a compound statement for lowering.
		statement.ast_kind = CT_COMPOUND_STMT;
		statement.ct_compound_stmt = start;
		sema_context_pop_ct_stack(context, for_context);
		return true;
	}
	// FAILED:
	sema_context_pop_ct_stack(context, for_context);
	return false;
}

// sema_stmts.c:3342 (static)
fn bool sema_analyse_statement_inner(SemaContext* context, Ast* statement)
{
	switch (statement.ast_kind)
	{
		case POISONED:
		case ASM_STMT:
		case ASM_LABEL:
			unreachable();
		case CT_TYPE_ASSIGN_STMT:
			return sema_analyse_ct_type_assign_stmt(context, statement);
		case DECLS_STMT:
			return sema_analyse_decls_stmt(context, statement);
		case CT_EXPAND_STMT:
			return sema_analyse_ct_expand_stmt(context, statement);
		case ASM_BLOCK_STMT:
			return sema_analyse_asm_stmt(context, statement);
		case ASSERT_STMT:
			return sema_analyse_assert_stmt(context, statement);
		case BREAK_STMT:
			return sema_analyse_break_stmt(context, statement);
		case CASE_STMT:
			return @sema_error_at(context, statement.loc, "Unexpected 'case' outside of switch");
		case COMPOUND_STMT:
			return sema_analyse_compound_stmt(context, statement);
		case CT_COMPOUND_STMT:
			return sema_analyse_ct_compound_stmt(context, statement);
		case CONTINUE_STMT:
			return sema_analyse_continue_stmt(context, statement);
		case CT_ASSERT:
			return sema_analyse_ct_assert_stmt(context, statement);
		case CT_IF_STMT:
			return sema_analyse_ct_if_stmt(context, statement);
		case CT_ECHO_STMT:
			return sema_analyse_ct_echo_stmt(context, statement);
		case DECLARE_STMT:
			return sema_analyse_declare_stmt(context, statement);
		case DEFAULT_STMT:
			return @sema_error_at(context, statement.loc, "Unexpected 'default' outside of switch");
		case DEFER_STMT:
			return sema_analyse_defer_stmt(context, statement);
		case EXPR_STMT:
			return sema_analyse_expr_stmt(context, statement);
		case FOREACH_STMT:
			return sema_analyse_foreach_stmt(context, statement);
		case FOR_STMT:
			return sema_analyse_for_stmt(context, statement);
		case IF_STMT:
			return sema_analyse_if_stmt(context, statement);
		case NOP_STMT:
			return true;
		case BLOCK_EXIT_STMT:
			unreachable();
		case RETURN_STMT:
			return sema_analyse_return_stmt(context, statement);
		case SWITCH_STMT:
			return sema_analyse_switch_stmt(context, statement);
		case NEXTCASE_STMT:
			return sema_analyse_nextcase_stmt(context, statement);
		case CT_SWITCH_STMT:
			return sema_analyse_ct_switch_stmt(context, statement);
		case CT_ELSE_STMT:
			unreachable();
		case CT_FOREACH_STMT:
			return sema_analyse_ct_foreach_stmt(context, statement);
		case CT_FOR_STMT:
			return sema_analyse_ct_for_stmt(context, statement);
	}
}

// sema_stmts.c:3413
fn bool sema_analyse_statement(SemaContext* context, Ast* statement)
{
	if (context.active_scope.is_poisoned) return false;
	if (statement.ast_kind == POISONED) return false;
	EndJump end_jump = context.active_scope.end_jump;
	usz returns = context.block_returns.len;
	if (!sema_analyse_statement_inner(context, statement)) return ast_poison(statement);
	if (end_jump.active)
	{
		if (!context.active_scope.allow_dead_code)
		{
			// If we start with an don't start with an assert AND the scope is a macro, then it's bad.
			if (statement.ast_kind != ASSERT_STMT && statement.ast_kind != NOP_STMT && !(context.active_scope.flags & SCOPE_MACRO))
			{
				context.active_scope.allow_dead_code = true;
				bool warn = @sema_warn_at(context, statement.loc, compiler.build.warnings.dead_code, "This code will never execute.");
				if (compiler.build.warnings.dead_code.ordinal > WarningLevel.SILENT.ordinal) @sema_note_prev_at(end_jump.loc, "No code will execute after this statement.");
				if (!warn) return ast_poison(statement);
			}
			// Remove it
		}
		@vec_resize(&context.block_returns, returns);
		statement.ast_kind = NOP_STMT;
	}
	return true;
}

// sema_stmts.c:3440 (static)
fn bool sema_analyse_ensure(SemaContext* context, Expr* directive)
{
	Expr* declexpr = directive.contract_expr.decl_exprs;
	assert(declexpr.expr_kind == EXPRESSION_LIST);

	foreach (expr : declexpr.expression_list)
	{
		if (expr.expr_kind == DECL)
		{
			return @sema_error_at(context, expr.loc, "Only expressions are allowed.");
		}
	}
	return true;
}

// sema_stmts.c:3455 (static)
fn bool sema_analyse_call_optional_returns(SemaContext* context, Decl* contract)
{
	if (!contract || !contract.contracts_decl.opt_returns.len)
	{
		context.call_env.opt_returns = {};
		return true;
	}
	if (!sema_analyse_optional_returns(context, contract)) return false;
	context.call_env.opt_returns = contract.contracts_decl.opt_returns_resolved;
	return true;
}

// sema_stmts.c:3468
fn void sema_append_contract_asserts(AstId assert_first, Ast* compound_stmt)
{
	assert(compound_stmt.ast_kind == COMPOUND_STMT);
	if (!assert_first) return;
	Ast* ast = new_ast(COMPOUND_STMT, compound_stmt.loc);
	ast.compound_stmt.first_stmt = assert_first;
	ast_prepend(&compound_stmt.compound_stmt.first_stmt, ast);
}

// sema_stmts.c:3477
fn bool sema_analyse_contracts(SemaContext* context, Decl* contract, Expr*[] requires, Expr*[] ensures, AstId** asserts, SourceLocId call_loc, bool* has_ensures, SourceLocId* arg_loc_map)
{
	context.call_env.opt_returns = {};
	if (has_ensures)
	{
		if (!sema_analyse_call_optional_returns(context, contract)) return false;
	}

	foreach (require : requires)
	{
		if (!assert_create_from_contract(context, require, false, asserts, call_loc, arg_loc_map)) return false;
	}
	if (!has_ensures) return true;
	foreach (ensure : ensures)
	{
		if (!sema_analyse_ensure(context, ensure)) return false;
		*has_ensures = true;
	}
	return true;
}

// sema_stmts.c:3498
fn bool sema_analyse_function_body(SemaContext* context, Decl* func, int macro_depth_start)
{
	// Stop if it's already poisoned.
	if (!decl_ok(func)) return false;
	assert(func.resolve_status == DONE);
	if (func.is_body_checked) return true;
	func.is_body_checked = true;
	context.generic_instance = func.is_templated ? declptr(func.instance_id) : null;
	// Check the signature here we test for variadic raw, since we don't support it.
	Signature* signature = &func.func_decl.signature;
	if (signature.variadic == RAW)
	{
		return @sema_error_at(context, func.loc, "C-style variadic arguments '...' are not supported for regular functions,"
						  " please use typed vaargs on the form 'int... args' or "
						  "untyped vaargs on the form 'args...' instead.");
	}

	// Pull out the prototype
	FunctionPrototype* prototype = func.type.function.prototype;
	assert(prototype);
	context.macro_call_depth = macro_depth_start;
	// Set up the context for analysis
	context.original_module = null;
	CallEnv env = {
		.current_function = func,
		.is_naked_fn = func.func_decl.attr_naked,
		.kind = ENV_FUNCTION,
		.pure = func.func_decl.signature.attrs.is_pure,
		.ignore_deprecation = func.allow_deprecated || decl_is_deprecated(func)
	};
	context.call_env = env;

	Type* rtype = context.rtype = typeget(signature.rtype);
	bool is_lambda = func.func_decl.is_lambda;
	DynamicScope new_scope = {
		.depth = 0,
		.label_start = 0,
		.current_local = 0
	};

	context.active_scope = new_scope;
	@vec_resize(&context.ct_locals, 0);
	// Clear returns
	@vec_resize(&context.block_returns, 0);
	// Zero out any jumps
	context.break_jump = context.continue_jump = context.next_jump = { .target = null };
	assert(func.func_decl.body);

	Ast* body = astptr(func.func_decl.body);
	Decl*[] lambda_params;
	DynamicScope old_scope = scope_start(context, func.loc);
	{
		assert(context.active_scope.depth == 1);
		foreach (param : signature.params)
		{
			if (!sema_add_local(context, param)) return false;
		}
		if (is_lambda)
		{
			// If we're a lambda we need to pass on the compile time values that will
			// be baked into the function.
			lambda_params = copy_decl_list_single(func.func_decl.lambda_ct_parameters);
			foreach (ct_param : lambda_params)
			{
				ct_param.var_decl.is_read = false;
				if (!sema_add_local(context, ct_param)) return false;
			}
		}
		AstId assert_first = 0;
		AstId* next = &assert_first;
		bool has_ensures = false;
		Decl* contracts = declptrzero(func.docs);
		if (contracts)
		{
			copy_begin();
			Expr*[] requires = copy_exprlist_macro(contracts.contracts_decl.requires);
			Expr*[] ensures = copy_exprlist_macro(contracts.contracts_decl.ensures);
			copy_end();
			if (!sema_analyse_contracts(context, contracts, requires, ensures, &next, 0, &has_ensures, null)) return false;
		}
		context.call_env.ensures = has_ensures;
		bool is_naked = func.func_decl.attr_naked;
		if (!is_naked) sema_append_contract_asserts(assert_first, body);
		assert(rtype);
		Type* canonical_rtype = type_no_optional(rtype).canonical;
		// c3c: `goto NEXT` is a break out of the labelled if.
		if NEXT: (!is_naked && has_ensures && type_is_void(canonical_rtype))
		{
			AstId* append_pos = &body.compound_stmt.first_stmt;
			if (*append_pos)
			{
				Ast* last = ast_last(astptr(*append_pos));
				if (last.ast_kind == RETURN_STMT) break NEXT;
				append_pos = &last.next;
			}
			Ast* ret = ast_calloc();
			ret.ast_kind = RETURN_STMT;
			ret.loc = body.loc;
			*append_pos = astid(ret);
		}
		// NEXT:
		if (!sema_analyse_compound_statement_no_scope(context, body)) return false;
		assert(context.active_scope.depth == 1);
		if (!context.active_scope.end_jump.active)
		{
			if (canonical_rtype != type_void && !is_naked)
			{
				return @sema_error_at(context, func.loc, "Missing return statement at the end of the function.");
			}
		}
	}
	WarningLevel unused_param = compiler.build.warnings.unused_parameter;
	WarningLevel unused_local = compiler.build.warnings.unused_local;
	if (unused_param != SILENT || unused_local != SILENT)
	{
		int last = context.active_scope.current_local;
		for (int i = 0; i < last; i++)
		{
			Decl* decl = context.locals[i];
			if (!decl.is_used && decl.name.ptr)
			{
				switch (decl.var_decl.kind)
				{
					case PARAM:
					case PARAM_EXPR:
					case PARAM_CT:
					case PARAM_CT_TYPE:
						if (!@sema_warn_at(context, decl.loc, compiler.build.warnings.unused_parameter, "The parameter '%s' is never used.", decl.name)) return false;
					case LOCAL:
					case LOCAL_CT:
					case LOCAL_CT_TYPE:
						if (!@sema_warn_at(context, decl.loc, compiler.build.warnings.unused_local, "The variable '%s' is never used.", decl.name)) return false;
					default:
						break;
				}
			}
		}
	}
	scope_end_unchecked(context, old_scope);
	if (lambda_params.len)
	{
		foreach (i, ct_param : lambda_params)
		{
			func.func_decl.lambda_ct_parameters[i].var_decl.is_read = ct_param.var_decl.is_read;
			func.func_decl.lambda_ct_parameters[i].is_used = ct_param.is_used;
		}
	}
	return true;
}
