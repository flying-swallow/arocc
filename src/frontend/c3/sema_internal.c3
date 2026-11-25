// Port of c3c src/compiler/sema_internal.h: the sema-wide constants, the
// scope / jump-target macros and the inline helpers. The prototypes of
// sema_internal.h are implemented (or stubbed) in the sema_*.c3 files that
// mirror the c3c file defining them.
//
// Macro mapping (the C macros declare locals or return from the caller, so
// they become helper fns plus a fixed expansion at the call site):
//   SEMA_WARN(node, level, ...)         -> @sema_warn_at(context, node.loc, compiler.build.warnings.level, ...)
//   SEMA_ERROR / RETURN_SEMA_ERROR / RETURN_SEMA_ERROR_AT: see diagnostics_inline.c3
//   RETURN_VAL_SEMA_ERROR(v, node, ...) -> { @sema_error_at(context, node.loc, ...); return v; }
//   RETURN_NULL_SEMA_ERROR(node, ...)   -> { @sema_error_at(context, node.loc, ...); return null; }
//   SCOPE_START(loc)                    -> DynamicScope old_scope = scope_start(context, loc);
//   SCOPE_START_WITH_FLAGS(flags, loc)  -> DynamicScope old_scope = scope_start_with_flags(context, flags, loc);
//   SCOPE_START_WITH_LABEL(label, loc)  -> DynamicScope old_scope = scope_start_with_label(context, label, loc);
//   SCOPE_END                           -> success = scope_end(context, old_scope, success);
//   SCOPE_END_CHECK                     -> if (!scope_end_check(context, old_scope)) return false;
//   SCOPE_END_UNCHECKED                 -> scope_end_unchecked(context, old_scope);
//   SCOPE_POP_ERROR()                   -> scope_pop_error(context, old_scope)   (returns false)
//   SCOPE_OUTER_START(loc)              -> DynamicScope stored_scope = scope_outer_start(context, loc);
//   SCOPE_OUTER_END                     -> scope_outer_end(context, stored_scope);
//   SCOPE_ERROR_END_OUTER()             -> context.active_scope = stored_scope;
//   PUSH_BREAK(ast) / POP_BREAK()       -> JumpTarget old_break = push_break(context, ast); ... context.break_jump = old_break;
//   PUSH_CONTINUE(ast) / POP_CONTINUE() -> JumpTarget old_continue = push_continue(context, ast); ... context.continue_jump = old_continue;
//   PUSH_NEXT(ast, sast) / POP_NEXT()   -> NextJumpState old_next = push_next(context, ast, sast); ... pop_next(context, old_next);
//   PUSH_BREAKCONT(ast) / POP_BREAKCONT() -> BreakContState old_bc = push_breakcont(context, ast); ... pop_breakcont(context, old_bc);
//   CHECK_ON_DEFINED(ref)               -> if (ref) { *ref = true; return false; }
//   SET_JUMP_END(context, node)         -> set_jump_end(context, node.loc);
//
// Deviations from c3c:
// - The scope blocks are not `do { } while (0)` blocks: the saved scope is a
//   named local, so nested scopes in one function need distinct names.
// - `sema_resolve_storage_type` keeps c3c's `return false` on a failed
//   sema_analyse_decl, spelled STORAGE_NORMAL (its value); the goto RETRY
//   loop is a `while (true)` + `continue`.
module aro::frontend::c3::compiler;

const int INT5_MAX = 15;
const int INT12_MAX = 2047;
const int INT20_MAX = 524287;
const int INT5_MIN = -16;
const int INT12_MIN = -2048;
const int INT20_MIN = -INT20_MAX - 1;
const uint UINT5_MAX = 31;
const uint UINT12_MAX = 4095;
const uint UINT20_MAX = 1048575;

// ---------------------------------------------------------------------------
// Scope / jump-target macros

<* SCOPE_START *>
fn DynamicScope scope_start(SemaContext* context, SourceLocId loc) @inline
{
	return scope_start_with_flags(context, SCOPE_NONE, loc);
}

<* SCOPE_START_WITH_FLAGS *>
fn DynamicScope scope_start_with_flags(SemaContext* context, ScopeFlags flags, SourceLocId loc) @inline
{
	DynamicScope old_scope = context.active_scope;
	context_change_scope_with_flags(context, flags, loc);
	return old_scope;
}

<* SCOPE_START_WITH_LABEL *>
fn DynamicScope scope_start_with_label(SemaContext* context, DeclId label, SourceLocId loc) @inline
{
	DynamicScope old_scope = context.active_scope;
	context_change_scope_for_label(context, label, loc);
	return old_scope;
}

<* SCOPE_END: `success = scope_end(context, old_scope, success);` *>
fn bool scope_end(SemaContext* context, DynamicScope old_scope, bool success) @inline
{
	assert(context.active_scope.defer_last == context.active_scope.defer_start);
	success = success && sema_scope_check_locals(context, old_scope);
	context.active_scope = old_scope;
	return success;
}

<* SCOPE_END_CHECK: `if (!scope_end_check(context, old_scope)) return false;` (leaves the scope on failure, like c3c). *>
fn bool scope_end_check(SemaContext* context, DynamicScope old_scope) @inline
{
	assert(context.active_scope.defer_last == context.active_scope.defer_start);
	if (!sema_scope_check_locals(context, old_scope)) return false;
	context.active_scope = old_scope;
	return true;
}

<* SCOPE_END_UNCHECKED *>
fn void scope_end_unchecked(SemaContext* context, DynamicScope old_scope) @inline
{
	assert(context.active_scope.defer_last == context.active_scope.defer_start);
	context.active_scope = old_scope;
}

<* SCOPE_POP_ERROR(): restore the scope and yield false. *>
fn bool scope_pop_error(SemaContext* context, DynamicScope old_scope) @inline
{
	context.active_scope = old_scope;
	return false;
}

<* SCOPE_OUTER_START *>
fn DynamicScope scope_outer_start(SemaContext* context, SourceLocId loc) @inline
{
	DynamicScope stored_scope = context.active_scope;
	context_change_scope_with_flags(context, SCOPE_NONE, loc);
	return stored_scope;
}

<* SCOPE_OUTER_END *>
fn void scope_outer_end(SemaContext* context, DynamicScope stored_scope) @inline
{
	assert(context.active_scope.defer_last == context.active_scope.defer_start);
	context.active_scope = stored_scope;
}

<* PUSH_BREAK: returns the previous target, restore with `context.break_jump = old`. *>
fn JumpTarget push_break(SemaContext* context, Ast* ast) @inline
{
	JumpTarget old = context.break_jump;
	context.break_jump = { ast, context.active_scope.defer_last };
	return old;
}

<* PUSH_CONTINUE: returns the previous target, restore with `context.continue_jump = old`. *>
fn JumpTarget push_continue(SemaContext* context, Ast* ast) @inline
{
	JumpTarget old = context.continue_jump;
	context.continue_jump = { ast, context.active_scope.defer_last };
	return old;
}

<* The state PUSH_NEXT saves. *>
struct NextJumpState
{
	JumpTarget next_jump;
	Ast* next_switch;
}

<* PUSH_NEXT *>
fn NextJumpState push_next(SemaContext* context, Ast* ast, Ast* sast) @inline
{
	NextJumpState old = { context.next_jump, context.next_switch };
	context.next_jump = { ast, context.active_scope.defer_last };
	context.next_switch = sast;
	return old;
}

<* POP_NEXT *>
fn void pop_next(SemaContext* context, NextJumpState old) @inline
{
	context.next_jump = old.next_jump;
	context.next_switch = old.next_switch;
}

<* The state PUSH_BREAKCONT saves. *>
struct BreakContState
{
	JumpTarget continue_jump;
	JumpTarget break_jump;
}

<* PUSH_BREAKCONT *>
fn BreakContState push_breakcont(SemaContext* context, Ast* ast) @inline
{
	BreakContState old = { .continue_jump = push_continue(context, ast) };
	old.break_jump = push_break(context, ast);
	return old;
}

<* POP_BREAKCONT *>
fn void pop_breakcont(SemaContext* context, BreakContState old) @inline
{
	context.continue_jump = old.continue_jump;
	context.break_jump = old.break_jump;
}

<* SET_JUMP_END *>
fn void set_jump_end(SemaContext* context, SourceLocId loc) @inline
{
	context.active_scope.end_jump = { true, loc };
}

// ---------------------------------------------------------------------------
// Inline functions

fn bool sema_analyse_stmt_chain(SemaContext* context, Ast* statement)
{
	if (!ast_ok(statement)) return false;
	AstId current = astid(statement);
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

fn bool sema_analyse_func_macro(SemaContext* context, Decl* decl, AttributeDomain domain, bool* erase_decl)
{
	assert((domain & CALLABLE_TYPE) == domain);
	if (!sema_analyse_attributes(context, decl, decl.attributes, domain, erase_decl)) return decl_poison(decl);
	if (decl_is_deprecated(decl)) context.call_env.ignore_deprecation = true;
	return true;
}

fn bool sema_check_left_right_const(SemaContext* context, Expr* left, Expr* right, bool* failed_ref)
{
	if (sema_cast_const(left) && sema_cast_const(right)) return true;
	if (failed_ref)
	{
		*failed_ref = true;
		return false;
	}
	return @sema_error_at(context, (sema_cast_const(left) ? right : left).loc, "Expected this to evaluate to a constant value.");
}

fn bool sema_set_alignment(SemaContext* context, Type* type, AlignSize* result, bool is_alloca)
{
	type = type.canonical;
	if (type_is_func_ptr(type))
	{
		*result = type_abi_alignment(type_voidptr);
		return true;
	}
	if (!sema_resolve_type_decl(context, type)) return false;
	*result = is_alloca ? type_alloca_alignment(type) : type_abi_alignment(type);
	return true;
}

fn bool sema_set_alloca_alignment(SemaContext* context, Type* type, AlignSize* result)
{
	if (!sema_resolve_type_decl(context, type)) return false;
	*result = type_alloca_alignment(type);
	return true;
}

fn Attr* attr_find_kind(Attr*[] attrs, AttributeType attr_type)
{
	foreach (attr : attrs)
	{
		if (attr.attr_kind == attr_type) return attr;
	}
	return null;
}

fn bool sema_display_deprecated_warning_on_use(SemaContext* context, Decl* decl, SourceLocId loc)
{
	assert(decl.resolve_status == DONE);
	if (!decl_is_deprecated(decl)) return true;
	if (context.call_env.ignore_deprecation) return true;
	String msg = decl.attrs_resolved.deprecated;

	// Prevent multiple reports
	decl.attrs_resolved.deprecated = {};

	switch (compiler.build.warnings.deprecation)
	{
		case NOT_SET:
			unreachable();
		case SILENT:
			return true;
		case WARN:
			if (msg.len)
			{
				@sema_warning_at(loc, "'%s' is deprecated: %s.", decl.name, msg);
				return true;
			}
			@sema_warning_at(loc, "'%s' is deprecated.", decl.name);
			return true;
		case ERROR:
			if (msg.len)
			{
				@print_error_at(loc, "'%s' is deprecated: %s.", decl.name, msg);
				return false;
			}
			@print_error_at(loc, "'%s' is deprecated.", decl.name);
			return false;
	}
}

fn IndexDiff range_const_len(ExprRange* range)
{
	switch (range.range_type)
	{
		case SINGLE_ELEMENT:
			unreachable();
		case CONST_LEN:
			return (IndexDiff)range.const_end;
		case CONST_END:
			return -1;
		case CONST_RANGE:
			return (IndexDiff)range.len_index;
		case DYNAMIC:
			break;
	}
	Expr* start = exprptr(range.start);
	Expr* end = exprptrzero(range.end);
	if (!end || !expr_is_const_int(end)) return -1;
	if (!int_fits(end.const_expr.ixx, type_sz.canonical.type_kind)) return -1;
	IndexDiff end_val = (IndexDiff)int_to_i64(end.const_expr.ixx);
	if (range.is_len) return end_val;
	if (!expr_is_const_int(start)) return -1;
	if (!int_fits(start.const_expr.ixx, type_sz.canonical.type_kind)) return -1;
	IndexDiff start_val = (IndexDiff)int_to_i64(start.const_expr.ixx);
	if (range.start_from_end && range.end_from_end) return start_val - end_val + 1;
	if (range.start_from_end != range.end_from_end) return -1;
	return end_val - start_val + 1;
}

fn ArrayIndex max_array_index() @inline
{
	return type_sz.canonical == type_long ? long::max : int::max;
}

fn StorageType sema_resolve_storage_type(SemaContext* context, Type* type)
{
	if (!type) return STORAGE_UNKNOWN;
	bool is_distinct = false;
	while (true)
	{
		if (type == type_wildcard_optional) return STORAGE_WILDCARD;
		switch (type.type_kind)
		{
			case VOID:
				return is_distinct ? STORAGE_UNKNOWN : STORAGE_VOID;
			case WILDCARD:
				return STORAGE_WILDCARD;
			case UNTYPEDLIST:
			case TYPEINFO:
			case MEMBER:
			case REFLECTION:
			case FUNC_RAW:
				return STORAGE_COMPILE_TIME;
			case OPTIONAL:
				type = type.optional;
				continue;
			case ALIAS:
				// c3c returns `false` (== STORAGE_NORMAL) here.
				if (!sema_analyse_decl(context, type.decl)) return STORAGE_NORMAL;
				type = type.canonical;
				continue;
			case TYPEDEF:
				is_distinct = true;
				if (!sema_analyse_decl(context, type.decl)) return STORAGE_NORMAL;
				type = type.decl.distinct.type;
				continue;
			case FLEXIBLE_ARRAY:
				return STORAGE_UNKNOWN;
			default:
				return STORAGE_NORMAL;
		}
	}
}

fn TypeProperty type_property_by_name(String name)
{
	for (int i = 0; i < NUMBER_OF_TYPE_PROPERTIES.ordinal; i++)
	{
		if (type_property_list[i].ptr == name.ptr) return TypeProperty::values[i];
	}
	return PROPERTY_NONE;
}
