// Port of c3c src/compiler/sema_static_analysis.c (revision 54bab366a): the
// simple null-pointer flow analysis run after sema.
//
// Deviations from c3c:
// - `SANullability`'s NULLABILITY_X values are `SANullability.X`.
// - The `goto RETRY` loops are `while (true)` loops.
// - The NON_RUNTIME_EXPR / UNRESOLVED_EXPRS groups (plus SUBSCRIPT_ASSIGN and
//   OPERATOR_CHARS) of sa_analyse_expr are the `default: unreachable()` arm.
// - sa_set_slot_nullability keeps c3c's `uint32_t bit` (slots >= 32 get no
//   bit), so the behaviour matches.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

const int MAX_SLOTS = 64;

alias FlagSlot = ulong;
alias SASlotId = int;

struct SAState
{
	FlagSlot is_null;
	FlagSlot not_null;
	bool dead;
}

struct SAContext
{
	bool bail;
	DeclId[MAX_SLOTS] slots;
	int slot_count;
	SAState state;
}

enum SANullability : char
{
	UNKNOWN,
	NULL,
	NOT_NULL,
}

macro bool @sa_bit_set(FlagSlot x, int bit) => ((x >> bit) & 1) != 0;

// sema_static_analysis.c:70
fn void sema_static_analysis()
{
	foreach (mod : compiler.context.module_list)
	{
		foreach (unit : mod.units)
		{
			sa_analyse_functions(unit.functions);
			sa_analyse_functions(unit.methods);
			sa_analyse_functions(unit.lambdas);
		}
	}
}

// sema_static_analysis.c:83 (static)
fn void sa_analyse_functions(Decl*[] functions)
{
	SAContext context;
	foreach (func : functions)
	{
		if (func.decl_kind != FUNC || !func.func_decl.body || !func.is_body_checked) continue;
		if (!func.is_live) continue;
		sa_analyse_function(&context, func);
	}
}

// sema_static_analysis.c:94 (static)
fn void sa_analyse_function(SAContext* c, Decl* func)
{
	c.bail = false;
	c.state.is_null = 0;    // Empty null flags
	c.state.not_null = 0;   // Empty not null flags
	c.state.dead = false;
	c.slot_count = 0; // No slots in use

	foreach (param : func.func_decl.signature.params)
	{
		if (!param) continue;
		SASlotId slot = sa_allocate_slot(c, param);
		if (slot >= 0) sa_set_slot_nullability(c, slot, param.var_decl.not_null ? SANullability.NOT_NULL : SANullability.UNKNOWN);
	}
	Ast* body = astptr(func.func_decl.body);
	assert(body.ast_kind == COMPOUND_STMT);
	AstId next = body.compound_stmt.first_stmt;
	while (next)
	{
		Ast* stmt = astptr(next);
		next = stmt.next;
		sa_analyse_stmt(c, stmt);
		if (c.bail) break;
	}
}

// sema_static_analysis.c:120 (static)
fn void sa_analyse_stmt(SAContext* c, Ast* stmt)
{
	if (!stmt || c.bail) return;

	switch (stmt.ast_kind)
	{
		case DEFER_STMT:
		case NOP_STMT:
			return;
		case CT_COMPOUND_STMT:
			sa_analyse_stmt_chain(c, stmt.ct_compound_stmt);
			return;
		case COMPOUND_STMT:
			sa_analyse_stmt_chain(c, stmt.compound_stmt.first_stmt);
			return;
		case EXPR_STMT:
			sa_analyse_expr_stmt(c, stmt.expr_stmt);
			return;
		case DECLARE_STMT:
			sa_analyse_declare(c, stmt.declare_stmt);
			return;
		case DECLS_STMT:
			foreach (decl : stmt.decls_stmt) sa_analyse_declare(c, decl);
			return;
		case RETURN_STMT:
			sa_analyse_return(c, stmt);
			return;
		case BLOCK_EXIT_STMT:
			sa_analyse_block_exit(c, stmt);
			return;
		case ASSERT_STMT:
			sa_analyse_assert(c, stmt);
			return;
		case IF_STMT:
			sa_analyse_if(c, stmt);
			return;
		case FOR_STMT:
			sa_analyse_for(c, stmt);
			return;
		case SWITCH_STMT:
			sa_analyse_switch(c, stmt);
			return;
		case NEXTCASE_STMT:
			sa_analyse_nextcase(c, stmt);
			return;
		case BREAK_STMT:
		case CONTINUE_STMT:
			sa_analyse_break_continue(c, stmt);
			return;
		case CT_ASSERT:
		case CT_ECHO_STMT:
		case CT_ELSE_STMT:
		case CT_EXPAND_STMT:
		case CT_FOREACH_STMT:
		case CT_FOR_STMT:
		case CT_IF_STMT:
		case CT_SWITCH_STMT:
		case CT_TYPE_ASSIGN_STMT:
		case POISONED:
		case FOREACH_STMT:
		case CASE_STMT:
		case DEFAULT_STMT:
			unreachable();
		case ASM_BLOCK_STMT:
		case ASM_LABEL:
		case ASM_STMT:
			c.bail = true;
			return;
	}
}

// sema_static_analysis.c:194 (static)
fn void sa_analyse_stmt_chain(SAContext* c, AstId id)
{
	while (id)
	{
		Ast* ast = astptr(id);
		sa_analyse_stmt(c, ast);
		id = ast.next;
	}
}

// sema_static_analysis.c:204 (static)
fn void sa_analyse_expr_stmt(SAContext* c, Expr* expr)
{
	sa_analyse_expr(c, expr);
}

// sema_static_analysis.c:209 (static)
fn void sa_analyse_declare(SAContext* c, Decl* decl)
{
	if (!decl || decl.decl_kind != VAR) return;
	// Only handle locals, excluding tlocal and static.
	if (decl.var_decl.kind != LOCAL || decl.var_decl.is_static || decl.var_decl.is_threadlocal) return;
	Expr* init = decl.var_decl.init_expr;
	if (init && @is_optional(init))
	{
		// Skip optional
		c.bail = true;
		return;
	}
	SANullability state;
	if (init)
	{
		state = sa_analyse_expr(c, init);
	}
	else
	{
		state = decl.var_decl.no_init ? SANullability.UNKNOWN : SANullability.NULL;
	}
	SASlotId slot = sa_allocate_slot(c, decl);
	if (slot < 0) return;
	sa_set_slot_nullability(c, slot, state);
}

// sema_static_analysis.c:235 (static)
fn void sa_analyse_return(SAContext* c, Ast* stmt)
{
	c.bail = true;
}

// sema_static_analysis.c:240 (static)
fn void sa_analyse_block_exit(SAContext* c, Ast* stmt)
{
	c.bail = true;
}

// sema_static_analysis.c:245 (static)
fn void sa_analyse_assert(SAContext* c, Ast* stmt)
{
	c.bail = true;
}

// sema_static_analysis.c:250 (static)
fn void sa_analyse_if(SAContext* c, Ast* stmt)
{
	if (stmt.if_stmt.flow.label)
	{
		c.bail = true;
		return;
	}
	Expr* cond = exprptr(stmt.if_stmt.cond);
	sa_analyse_expr(c, cond);
	bool is_simple = sa_expr_is_simple(cond);
	SAState stored = c.state;
	if (is_simple) sa_narrow(c, cond, true);
	sa_analyse_stmt(c, astptrzero(stmt.if_stmt.then_body));
	SAState then_state = c.state;
	c.state = stored;
	if (is_simple) sa_narrow(c, cond, false);
	sa_analyse_stmt(c, astptrzero(stmt.if_stmt.else_body));
	c.state = sa_state_join(then_state, c.state);
}

// sema_static_analysis.c:270 (static)
fn void sa_analyse_for(SAContext* c, Ast* stmt)
{
	c.bail = true;
}

// sema_static_analysis.c:274 (static)
fn void sa_analyse_switch(SAContext* c, Ast* stmt)
{
	c.bail = true;
}

// sema_static_analysis.c:278 (static)
fn void sa_analyse_nextcase(SAContext* c, Ast* stmt)
{
	c.bail = true;
}

// sema_static_analysis.c:282 (static)
fn void sa_analyse_break_continue(SAContext* c, Ast* stmt)
{
	c.bail = true;
}

// sema_static_analysis.c:287 (static)
fn void sa_assign_slot(SAContext* c, Expr* lhs, SANullability value)
{
	if (lhs.expr_kind != IDENTIFIER) return;
	SASlotId slot = sa_allocate_slot(c, lhs.ident_expr);
	if (slot >= 0) sa_set_slot_nullability(c, slot, value);
}

// sema_static_analysis.c:294 (static)
fn void sa_set_slot_nullability(SAContext* c, SASlotId slot, SANullability nullability)
{
	assert(slot >= 0 && slot < MAX_SLOTS);
	uint bit = (uint)(1UL << slot);
	switch (nullability)
	{
		case NOT_NULL:
			c.state.not_null |= bit;
			c.state.is_null &= ~(FlagSlot)bit;
			return;
		case NULL:
			c.state.not_null &= ~(FlagSlot)bit;
			c.state.is_null |= bit;
			return;
		case UNKNOWN:
			c.state.not_null &= ~(FlagSlot)bit;
			c.state.is_null &= ~(FlagSlot)bit;
			return;
	}
}

// sema_static_analysis.c:316 (static)
fn SASlotId sa_find_slot(SAContext* c, Decl* decl)
{
	DeclId id = declid(decl);
	for (int i = 0; i < c.slot_count; i++)
	{
		if (c.slots[i] == id) return i;
	}
	return -1;
}

// sema_static_analysis.c:326 (static)
fn SASlotId sa_allocate_slot(SAContext* c, Decl* decl)
{
	assert(decl);
	if (!decl || decl.decl_kind != VAR) return -1;
	if ((decl.var_decl.kind != LOCAL && decl.var_decl.kind != PARAM) || decl.var_decl.is_static || decl.var_decl.is_threadlocal) return -1;
	DeclId id = declid(decl);
	for (int i = 0; i < c.slot_count; i++)
	{
		if (c.slots[i] == id) return i;
	}
	if (c.slot_count == MAX_SLOTS) return -1;
	c.slots[c.slot_count] = id;
	return c.slot_count++;
}

// sema_static_analysis.c:341 (static)
fn SAState sa_state_join(SAState a, SAState b)
{
	return { .is_null = a.is_null & b.is_null, .not_null = a.not_null & b.not_null };
}

// sema_static_analysis.c:346 (static)
fn SANullability sa_analyse_expr(SAContext* c, Expr* expr)
{
	if (!expr) return UNKNOWN;
	while (true)
	{
		switch (expr.expr_kind)
		{
			case NOP:
				return UNKNOWN;
			case CONST:
				return sa_analyse_const_expr(c, expr);
			case CALL:
				return sa_analyse_call_expr(c, expr);
			case BINARY:
				return sa_analyse_binary_expr(c, expr);
			case IDENTIFIER:
				return sa_analyse_ident_expr(c, expr);
			case COND:
				return sa_analyse_expr_list(c, expr.cond_expr);
			case UNARY:
			case POST_UNARY:
				return sa_analyse_unary_expr(c, expr);
			case RVALUE:
			case RECAST:
			case DISCARD:
				expr = expr.inner_expr;
				continue;
			case TWO:
				sa_analyse_expr(c, expr.two_expr.first);
				expr = expr.two_expr.last;
				continue;
			case INT_TO_BOOL:
				sa_analyse_expr(c, expr.int_to_bool_expr.inner);
				return UNKNOWN;
			case ACCESS_RESOLVED:
			case ADDR_CONVERSION:
			case ASM:
			case BENCHMARK_HOOK:
			case BITACCESS:
			case BITASSIGN:
			case BUILTIN:
			case BUILTIN_ACCESS:
			case CATCH:
			case DECL:
			case DEFAULT_ARG:
			case DESIGNATED_INITIALIZER_LIST:
			case DESIGNATOR:
			case ENUM_FROM_ORD:
			case EXPRESSION_LIST:
			case EXT_TRUNC:
			case FLOAT_TO_INT:
			case FORCE_UNWRAP:
			case INITIALIZER_LIST:
			case INT_TO_FLOAT:
			case INT_TO_PTR:
			case LAMBDA:
			case LAST_FAULT:
			case MACRO_BLOCK:
			case MACRO_BODY_EXPANSION:
			case MAKE_ANY:
			case MAKE_SLICE:
			case MEMBER_GET:
			case MEMBER_SET:
			case NAMED_ARGUMENT:
			case NAMED_EVAL_ARGUMENT:
			case OPTIONAL:
			case POINTER_OFFSET:
			case PTR_ACCESS:
			case PTR_TO_INT:
			case RETHROW:
			case RETVAL:
			case SCALAR_TO_VECTOR:
			case SLICE:
			case SLICE_ASSIGN:
			case SLICE_COPY:
			case SLICE_LEN:
			case SLICE_TO_VEC_ARRAY:
			case SUBSCRIPT:
			case SUBSCRIPT_ADDR:
			case SWIZZLE:
			case TERNARY:
			case TEST_HOOK:
			case TRY:
			case TRY_UNWRAP_CHAIN:
			case TYPEID_INFO:
			case VECTOR_FROM_ARRAY:
			case VECTOR_TO_ARRAY:
				c.bail = true;
				return UNKNOWN;
			default:
				// NON_RUNTIME_EXPR, UNRESOLVED_EXPRS, SUBSCRIPT_ASSIGN, OPERATOR_CHARS
				unreachable();
		}
	}
}

// sema_static_analysis.c:443 (static)
fn SANullability sa_analyse_const_expr(SAContext* c, Expr* expr)
{
	switch (expr.const_expr.const_kind)
	{
		case POINTER:
			return expr.const_expr.ptr ? SANullability.NOT_NULL : SANullability.NULL;
		case REF:
			return NOT_NULL;
		default:
			return UNKNOWN;
	}
}

// sema_static_analysis.c:457 (static)
fn SANullability sa_analyse_binary_expr(SAContext* c, Expr* expr)
{
	Expr* left = exprptr(expr.binary_expr.left);
	Expr* right = exprptr(expr.binary_expr.right);
	BinaryOp op = expr.binary_expr.operator;
	switch (op)
	{
		case ASSIGN:
			SANullability value = sa_analyse_expr(c, right);
			sa_analyse_expr(c, left);
			sa_assign_slot(c, left, value);
			return value;
		case AND:
		case OR:
			sa_analyse_expr(c, left);
			SAState skipped = c.state;
			sa_analyse_expr(c, right);
			c.state = sa_state_join(skipped, c.state);
			return UNKNOWN;
		case ELSE:
			c.bail = true;
			return UNKNOWN;
		default:
			sa_analyse_expr(c, left);
			sa_analyse_expr(c, right);
			if (op > BinaryOp.ASSIGN) sa_assign_slot(c, left, UNKNOWN);
			return UNKNOWN;
	}
}

// sema_static_analysis.c:491 (static)
fn SANullability sa_analyse_call_expr(SAContext* c, Expr* expr)
{
	if (expr.call_expr.is_builtin || expr.call_expr.varargs.ptr || expr.call_expr.va_is_splat
		|| expr.call_expr.function_contracts || expr.call_expr.no_return)
	{
		c.bail = true;
		return UNKNOWN;
	}
	if (!expr.call_expr.is_func_ref) sa_analyse_expr(c, exprptr(expr.call_expr.function));
	Decl* callee = expr.call_expr.is_func_ref ? declptr(expr.call_expr.func_ref) : null;
	Decl*[] params = callee && callee.decl_kind == FUNC ? callee.func_decl.signature.params : {};
	int param_count = (int)params.len;
	SANullability[MAX_PARAMS] values;
	foreach (i, arg : expr.call_expr.arguments)
	{
		SANullability v = sa_analyse_expr(c, arg);
		if (i < MAX_PARAMS) values[i] = v;
	}
	if (c.bail) return UNKNOWN;
	foreach (j, arg : expr.call_expr.arguments)
	{
		if (j >= param_count || j >= MAX_PARAMS || !params[j] || !params[j].var_decl.not_null) continue;
		if (values[j] != NULL) continue;
		if (c.state.dead) continue;
		if (params[j].var_decl.self_addr)
		{
			@print_error_at(arg.loc, "This method may not be called on a value known to be null.");
		}
		else
		{
			@print_error_at(arg.loc, "This value is null, but the parameter must be non-null.");
		}
		@sema_note_prev_at(params[j].loc, "The definition is here.");
	}
	return UNKNOWN;
}

// sema_static_analysis.c:523 (static)
fn SANullability sa_analyse_ident_expr(SAContext* c, Expr* expr)
{
	SASlotId slot = sa_find_slot(c, expr.ident_expr);
	if (slot < 0) return UNKNOWN;
	if (@sa_bit_set(c.state.is_null, slot)) return NULL;
	if (@sa_bit_set(c.state.not_null, slot)) return NOT_NULL;
	return UNKNOWN;
}

// sema_static_analysis.c:532 (static)
fn SANullability sa_analyse_expr_list(SAContext* c, Expr*[] exprs)
{
	SANullability value = UNKNOWN;
	foreach (arg : exprs) value = sa_analyse_expr(c, arg);
	return value;
}

// sema_static_analysis.c:539 (static)
fn SANullability sa_analyse_unary_expr(SAContext* c, Expr* expr)
{
	Expr* inner = expr.unary_expr.expr;
	switch (expr.unary_expr.operator)
	{
		case ERROR:
			unreachable();
		case NOT:
		case NEG:
		case BITNEG:
		case PLUS:
			sa_analyse_expr(c, inner);
			return UNKNOWN;
		case INC:
		case DEC:
			sa_analyse_expr(c, inner);
			sa_assign_slot(c, inner, UNKNOWN);
			return UNKNOWN;
		case TADDR:
			sa_analyse_expr(c, inner);
			return NOT_NULL;
		case ADDR:
			c.bail = true;
			return UNKNOWN;
		case DEREF:
			if (sa_analyse_expr(c, inner) == NULL && !c.bail && !c.state.dead)
			{
				@print_error_at(expr.loc, "This would dereference a null pointer.");
			}
			return UNKNOWN;
	}
}

// sema_static_analysis.c:573 (static)
fn Expr* sa_flatten_expr(Expr* expr)
{
	while (expr.expr_kind == RVALUE || expr.expr_kind == RECAST) expr = expr.inner_expr;
	return expr;
}

// sema_static_analysis.c:579 (static)
fn bool sa_expr_is_null_const(Expr* expr)
{
	expr = sa_flatten_expr(expr);
	return expr_is_const_pointer(expr) && !expr.const_expr.ptr;
}

// sema_static_analysis.c:585 (static)
fn bool sa_expr_is_simple_recursive(Expr* expr, int* budget)
{
	if (--*budget < 0) return false;
	while (true)
	{
		switch (expr.expr_kind)
		{
			case IDENTIFIER:
			case CONST:
				return true;
			case RVALUE:
			case RECAST:
				expr = expr.inner_expr;
				continue;
			case TWO:
				expr = expr.two_expr.last;
				continue;
			case COND:
				expr = @veclast(expr.cond_expr);
				continue;
			case INT_TO_BOOL:
				expr = expr.int_to_bool_expr.inner;
				continue;
			case UNARY:
				if (expr.unary_expr.operator != NOT) return false;
				expr = expr.unary_expr.expr;
				continue;
			case BINARY:
				switch (expr.binary_expr.operator)
				{
					case AND:
					case OR:
					case EQ:
					case NE:
						return sa_expr_is_simple_recursive(exprptr(expr.binary_expr.left), budget)
							&& sa_expr_is_simple_recursive(exprptr(expr.binary_expr.right), budget);
					default:
						return false;
				}
			default:
				return false;
		}
	}
}

// sema_static_analysis.c:628 (static)
fn bool sa_expr_is_simple(Expr* expr)
{
	int budget = 16;
	return sa_expr_is_simple_recursive(expr, &budget);
}

// sema_static_analysis.c:634 (static)
fn void sa_narrow(SAContext* c, Expr* expr, bool truth)
{
	if (c.state.dead) return;
	while (true)
	{
		switch (expr.expr_kind)
		{
			case RVALUE:
			case RECAST:
				expr = expr.inner_expr;
				continue;
			case COND:
				expr = @veclast(expr.cond_expr);
				continue;
			case TWO:
				expr = expr.two_expr.last;
				continue;
			case INT_TO_BOOL:
				Expr* inner = expr.int_to_bool_expr.inner;
				if (type_flatten(inner.type).type_kind != POINTER) return;
				bool non_null = truth != expr.int_to_bool_expr.negate;
				sa_narrow_nullable(c, inner, non_null ? SANullability.NOT_NULL : SANullability.NULL);
				return;
			case UNARY:
				if (expr.unary_expr.operator == NOT)
				{
					expr = expr.unary_expr.expr;
					truth = !truth;
					continue;
				}
				return;
			case BINARY:
				Expr* left = exprptr(expr.binary_expr.left);
				Expr* right = exprptr(expr.binary_expr.right);
				switch (expr.binary_expr.operator)
				{
					case AND:
						if (!truth) return;
						sa_narrow(c, left, true);
						sa_narrow(c, right, true);
						return;
					case OR:
						if (truth) return;
						sa_narrow(c, left, false);
						sa_narrow(c, right, false);
						return;
					case EQ:
					case NE:
						bool is_eq = (expr.binary_expr.operator == BinaryOp.EQ) == truth;
						SANullability value = is_eq ? SANullability.NULL : SANullability.NOT_NULL;
						if (sa_expr_is_null_const(right))
						{
							sa_narrow_nullable(c, left, value);
						}
						else if (sa_expr_is_null_const(left))
						{
							sa_narrow_nullable(c, right, value);
						}
						return;
					default:
						return;
				}
			default:
				return;
		}
	}
}

// sema_static_analysis.c:701 (static)
fn void sa_narrow_nullable(SAContext* c, Expr* expr, SANullability nullability)
{
	expr = sa_flatten_expr(expr);
	if (expr.expr_kind != IDENTIFIER) return;
	SASlotId slot = sa_find_slot(c, expr.ident_expr);
	if (slot < 0) return;
	SANullability current = sa_analyse_ident_expr(c, expr);
	// Just continue if same
	if (current == nullability) return;
	// Path is dead if nullability is known to differ
	if (current != UNKNOWN)
	{
		c.state.dead = true;
	}
	sa_set_slot_nullability(c, slot, nullability);
}
