// Port of the first half of c3c src/compiler/sema_expr.c (revision 54bab366a,
// lines 1..~7049: context switching, identifiers, ternary, calls / argument
// evaluation / format checks, macro calls and body expansion, typecalls,
// subscripts, slices and ranges, access children, reflection and type
// properties). The second half is sema_expr2.c3. Each function keeps its
// `// sema_expr.c:<line>` marker and c3c order.
//
// Deviations from c3c:
// - gotos are restructured: label targets used by several paths became
//   small `@local` helpers next to their function (lvalue_err /
//   lvalue_check_optional / lvalue_failed_ref, param_err_with_definition
//   (RETURN_ERR_WITH_DEFINITION), sema_func_error_note (RETURN_SEMA_FUNC_ERROR's
//   note), sema_call_check_format (CHECK_FORMAT), format_unexpected_end /
//   format_too_few_arguments, macro_call_exit_fail / macro_call_fold_ct,
//   macro_no_match_ref, member_access_missing_ref, reflection_access_failed,
//   sema_call_analyse_func_contracts); RETRY labels are loops.
// - c3c's function-local `static int contract_depth` is a module global.
// - Vector NULL returns (splat inserts) are null slices (`.ptr == null`);
//   vector truthiness tests use `.len`, except `call_expr.varargs` which is
//   tested by `.ptr` because `vasplat` shares its union slot.
// - sema_call_evaluate_arguments does not read params[vaarg_index] past the
//   end for raw C varargs (c3c UB, value unused): it passes null.
// - Format strings with unused extra C arguments drop the extra argument;
//   `%lld`/`%llu` are `%d`; non-literal formats go through "%s".
// - Exhaustive C case lists ending in `goto ERR` / `return false` use `default`.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

const int MEMBER_IS_PARAM = -1;

struct CalledDeclContext
{
	bool macro_decl;
	Decl* definition;
	SourceLocId call_location;
	String name;
	String block_parameter;
	Decl*[] params;
	Expr* struct_var;
	Signature* signature;
	Decl*[] macro_va_decls;
	Decl*[] evaluations;
}

struct ContextSwitchState
{
	bool in_no_eval;
	InliningSpan* old_inlining;
	Decl* generic_instance;
}

enum SplatResult : char
{
	ZERO,
	ONE,
	NONE,
}

<* c3c `struct SubcriptLookup` / `SubscriptLookup`. *>
struct SubscriptLookup
{
	Expr* subscripted;
	Type* subscripted_type; // Might be flat version of subscripted's type.
	OperatorOverload operator_overload;
	Decl* overload_method;
	Type* subscript_value_type;
	bool is_ref;
	bool try_get_ref;
	bool ref_succeded;
}

enum RangeEnv : char
{
	ARRAY,
	SLICE,
	PTR,
	FLEXIBLE,
}

// sema_expr.c:218 (static)
fn ContextSwitchState context_switch_state_push(SemaContext* context, SemaContext* new_context)
{
	ContextSwitchState state = { .in_no_eval = new_context.call_env.in_no_eval, .old_inlining = new_context.inlined_at, .generic_instance = new_context.generic_instance };
	new_context.call_env.in_no_eval = context.call_env.in_no_eval;
	new_context.inlined_at = context.inlined_at;
	return state;
}

// sema_expr.c:227 (static)
fn void context_switch_stat_pop(SemaContext* swapped, ContextSwitchState state)
{
	swapped.call_env.in_no_eval = state.in_no_eval;
	swapped.inlined_at = state.old_inlining;
	swapped.generic_instance = state.generic_instance;
}

// sema_expr.c:234
fn bool sema_check_array_index(SemaContext* context, Expr* index, bool is_len)
{
	if (expr_is_const_int(index) && !int_fits(index.const_expr.ixx, type_sz.canonical.type_kind))
	{
		return @sema_error_at(context, index.loc, "The %s is out of range: it cannot fit in a %s.", is_len ? "length" : "index", type_quoted_error_string(type_sz));
	}
	return true;
}

// sema_expr.c:243
fn Expr* sema_enter_inline_member(Expr* parent, CanonicalType* type)
{
	Expr* expr;
	switch (type.type_kind)
	{
		case STRUCT:
		{
			Decl* decl = type.decl;
			if (!decl.is_substruct) return null;
			expr = expr_access_inline_member(parent, decl);
		}
		case TYPEDEF:
		{
			Decl* decl = type.decl;
			if (!decl.is_substruct) return null;
			expr = expr_copy(parent);
			type = type.decl.distinct.type;
			expr.type = type;
		}
		case CONSTSET:
		{
			Decl* decl = type.decl;
			if (!decl.is_substruct) return null;
			expr = expr_copy(parent);
			expr.type = decl.enums.type_info.type;
		}
		default:
			return null;
	}
	if (@is_optional(parent)) expr.type = type_add_optional(expr.type, true);
	return expr;
}

// sema_expr.c:284
<*
 Analyse $vaarg[0], returning the expression inside.
 Returns a poisoned expr if it fails.
*>
fn Expr* sema_expr_analyse_ct_arg_index(SemaContext* context, SubscriptIndex* index, bool* no_match_ref)
{
	int args = (int)context.macro_varargs.len;
	Expr* index_expr = exprptr(index.expr);
	if (!sema_analyse_expr_rvalue(context, index_expr)) return poisoned_expr;
	if (!type_is_integer(index_expr.type))
	{
		@sema_error_at(context, index_expr.loc, "Expected the argument index here, but found a value of type %s.", type_quoted_error_string(index_expr.type));
		return poisoned_expr;
	}
	if (!sema_cast_const(index_expr))
	{
		@sema_error_at(context, index_expr.loc, "Vaarg functions need a constant argument, but this is a runtime value.");
		return poisoned_expr;
	}
	Int index_val = index_expr.const_expr.ixx;
	if (int_is_neg(index_val))
	{
		@sema_error_at(context, index_expr.loc, "The index cannot be negative.");
		return poisoned_expr;
	}
	Int int_max = { .i = 0xFFFFF, .type = U32 };
	bool out_of_range = int_comp(index_val, int_max, GE);
	if (!out_of_range)
	{
		int idx = (int)(ulong)index_val.i;
		if (index.start_from_end) idx = args - idx;
		if (idx >= 0 && idx < args) return context.macro_varargs[idx];
	}
	// OUT_OF_RANGE:
	if (no_match_ref)
	{
		*no_match_ref = true;
		return poisoned_expr;
	}
	@sema_error_at(context, index_expr.loc, "Only %d vaarg%s exist.", args, args == 1 ? "" : "s");
	return poisoned_expr;
}

// sema_expr.c:320
fn Expr* sema_resolve_string_ident(SemaContext* context, Expr* inner, bool report_missing)
{
	assert(expr_is_const_string(inner));
	char* bytes = inner.const_expr.bytes.ptr;
	ArrayIndex len = inner.const_expr.bytes.len;
	String str = (String)bytes[:len];
	ModulePath* path;
	String ident;
	TokenType token = sema_splitpathref(str, len, &path, &ident);
	inner.resolve_status = NOT_DONE;
	bool unexpected_path = false;
	switch (token)
	{
		case IDENT:
		case CONST_IDENT:
		case AT_IDENT:
			if (!ident.ptr) break;
			inner.expr_kind = UNRESOLVED_IDENTIFIER;
			inner.unresolved_ident_expr = { .path = path, .ident = ident, .is_const = token == CONST_IDENT };
			return inner;
		case CT_IDENT:
			if (path)
			{
				unexpected_path = true;
				break;
			}
			if (!ident.ptr) break;
			inner.expr_kind = CT_IDENT;
			inner.ct_ident_expr.identifier = ident;
			return inner;
		case HASH_IDENT:
			if (path)
			{
				unexpected_path = true;
				break;
			}
			if (!ident.ptr) break;
			inner.expr_kind = HASH_IDENT;
			inner.ct_ident_expr.identifier = ident;
			return inner;
		case VOID..UNTYPEDLIST:
		case TYPE_IDENT:
		case CT_TYPE_IDENT:
			@sema_error_at(context, inner.loc, "'%s' looks like a type name, use '$Typefrom' rather than '$eval' to evaluate it.", str);
			return poisoned_expr;
		default:
			@sema_error_at(context, inner.loc, "'%s' could not be resolved to a valid identifier.", str);
			return poisoned_expr;
	}
	if (unexpected_path)
	{
		@sema_error_at(context, inner.loc, "Unexpected path in '%s'.", str);
		return poisoned_expr;
	}
	// NO_MATCH:
	if (report_missing) @sema_error_at(context, inner.loc, "'%s' could not be found, did you spell it right?", str);
	return null;
}

// sema_expr.c:364
fn Expr* sema_ct_eval_expr(SemaContext* context, CtEvalKind eval_kind, Expr* inner, bool report_missing, bool* was_reflect)
{
	if (!sema_analyse_ct_expr(context, inner)) return null;
	if (!expr_is_const_string(inner))
	{
		if (was_reflect && inner.resolve_status == DONE && expr_is_const_reflection(inner))
		{
			*was_reflect = true;
			return inner;
		}
		switch (eval_kind)
		{
			case EVAL_IDENTIFIER:
				@sema_error_at(context, inner.loc, "'$eval' expects a constant string as the argument.");
				return poisoned_expr;
			case EVAL_IMPLICIT_IDENTIFIER:
				@sema_error_at(context, inner.loc, "A constant string was expected as the argument.");
				return poisoned_expr;
		}
	}
	if (was_reflect) *was_reflect = false;
	return sema_resolve_string_ident(context, inner, report_missing);
}

// sema_expr.c:388
fn void expr_set_to_ref(Expr* expr)
{
	switch (expr.expr_kind)
	{
		case ACCESS_UNRESOLVED:
			expr.access_unresolved_expr.is_ref = true;
		case SUBSCRIPT:
			expr.subscript_expr.ref = true;
		case HASH_IDENT:
			expr.hash_ident_expr.is_ref = true;
		case OTHER_CONTEXT:
			expr.expr_other_context.is_ref = true;
		default:
			break;
	}
}

// sema_expr.c:409
fn Expr* expr_access_inline_member(Expr* parent, Decl* parent_decl)
{
	Expr* embedded_struct = expr_new(ACCESS_RESOLVED, parent.loc);
	embedded_struct.resolve_status = DONE;
	embedded_struct.access_resolved_expr.parent = parent;
	embedded_struct.access_resolved_expr.ref = parent_decl.strukt.members[0];
	embedded_struct.type = type_add_optional(embedded_struct.access_resolved_expr.ref.type, @is_optional(parent));
	return embedded_struct;
}

// sema_expr.c:419 (static)
fn bool expr_const_foldable_unary(Expr* expr, UnaryOp unary)
{
	if (!sema_cast_const(expr) || !expr_is_const(expr)) return false;
	ConstKind kind = expr.const_expr.const_kind;
	switch (unary)
	{
		case INC:
		case DEC:
			return false;
		case PLUS:
		case NEG:
			return kind == FLOAT || kind == INTEGER;
		case BITNEG:
			return kind == BOOL || kind == INTEGER;
		case NOT:
			return kind == BOOL;
		case ERROR:
			unreachable();
		case DEREF:
		case ADDR:
		case TADDR:
			unreachable();
	}
}

// sema_expr.c:444 (static)
fn bool expr_both_const_foldable(Expr* left, Expr* right, BinaryOp op)
{
	if (!sema_cast_const(left) || !sema_cast_const(right) || !expr_is_const(left) || !expr_is_const(right)) return false;
	ConstKind a = left.const_expr.const_kind;
	ConstKind b = right.const_expr.const_kind;
	switch (a)
	{
		case BOOL:
			if (a != b) return false;
			switch (op)
			{
				case BIT_AND:
				case BIT_OR:
				case BIT_XOR:
				case NE:
				case EQ:
				case AND:
				case OR:
					return true;
				default:
					return false;
			}
		case FLOAT:
		case INTEGER:
			if (a != b) return false;
			return op != AND && op != OR;
		case BYTES:
		case STRING:
			if (op != EQ && op != NE) return false;
			return a == b || b == SLICE || b == BYTES || b == STRING;
		case ENUM:
		case FAULT:
		case TYPEID:
		case REF:
			break;
		case POINTER:
			if (op == SUB) return true;
		case SLICE:
			if (op != EQ && op != NE) return false;
			return b == BYTES || b == STRING;
		case INITIALIZER:
			switch (type_flatten(left.type).type_kind)
			{
				case VECTOR:
				case SIMD_VECTOR:
					if (a != b) return false;
					return op == EQ || op == NE;
				case BITSTRUCT:
					if (a != b) return false;
					switch (op)
					{
						case EQ:
						case NE:
						case BIT_AND:
						case BIT_XOR:
						case BIT_OR:
							return true;
						default:
							return false;
					}
				default:
					return false;
			}
		case UNTYPED_LIST:
		case REFLECTION:
			return false;
		case MEMBER:
			return true;
	}
	return (a == b) && (op == EQ || op == NE);
}

// sema_expr.c:516 (static)
fn bool expr_both_any_integer_or_integer_bool_vector(Expr* left, Expr* right)
{
	Type* flatten_left = type_flatten(left.type);
	Type* flatten_right = type_flatten(right.type);
	if (type_is_integer(flatten_left) && type_is_integer(flatten_right)) return true;

	if (!type_kind_is_real_vector(flatten_left.type_kind) || !type_kind_is_real_vector(flatten_right.type_kind)) return false;

	return type_is_integer_or_bool_kind(flatten_left.array.base) && type_is_integer_or_bool_kind(flatten_right.array.base);
}

// sema_expr.c:527 (static)
fn void expr_binary_unify_failability(Expr* expr, Expr* left, Expr* right)
{
	expr.type = type_add_optional(left.type, @is_optional(right));
}

// sema_expr.c:532
fn CondResult sema_check_comp_time_bool(SemaContext* context, Expr* expr)
{
	CondResult result = COND_MISSING;
	if (!sema_analyse_cond_expr(context, expr, &result)) return COND_MISSING;
	if (result == COND_MISSING)
	{
		@sema_error_at(context, expr.loc, "Compile time evaluation requires a compile time constant value.");
	}
	return result;
}

// sema_expr.c:543
fn bool sema_expr_analyse_sprintf(SemaContext* context, Expr* expr, Expr* format_string, Expr*[] args, int num_args)
{
	if (!sema_analyse_expr_rvalue(context, format_string)) return false;
	if (!sema_cast_const(format_string))
	{
		return @sema_error_at(context, format_string.loc, "Expected a constant format string expression.");
	}
	for (int i = 0; i < num_args; i++)
	{
		Expr* e = args[i];
		if (!sema_analyse_expr_rvalue(context, e)) return false;
		if (!sema_cast_const(e))
		{
			return @sema_error_at(context, e.loc, "Expected a constant expression.");
		}
	}
	if (!expr_is_const_string(format_string))
	{
		return @sema_error_at(context, format_string.loc, "Expected a constant format string.");
	}
	char* inner_str = format_string.const_expr.bytes.ptr;
	ArrayIndex len = format_string.const_expr.bytes.len;
	scratch_buffer_clear();
	ArrayIndex current_index = 0;
	for (ArrayIndex i = 0; i < len; i++)
	{
		char c = inner_str[i];
		if (c == '%')
		{
			i++;
			switch (inner_str[i])
			{
				case 's':
					if (current_index == num_args) return @sema_error_at(context, format_string.loc, "Too many arguments in format string.");
					expr_const_to_scratch_buffer(&(args[current_index++].const_expr));
					continue;
				case '%':
					scratch_buffer_append_char('%');
					continue;
				default:
					return @sema_error_at(context, format_string.loc, "Only '%%s' is supported for compile time sprintf.");
			}
		}
		scratch_buffer_append_char(c);
	}
	if (current_index != num_args)
	{
		return @sema_error_at(context, expr.loc, "Too many arguments to sprintf.");
	}
	expr_rewrite_const_string_from_scratch(expr);
	return true;
}

// sema_expr.c:597 (static)
fn bool expr_is_const_storage(Expr* expr, bool literal_is_const)
{
	while (true)
	{
		switch (expr.expr_kind)
		{
			case CONST:
				return literal_is_const;
			case IDENTIFIER:
				return expr.ident_expr.decl_kind == VAR && expr.ident_expr.var_decl.kind == CONST;
			case BITACCESS:
			case ACCESS_RESOLVED:
				expr = expr.access_resolved_expr.parent;
				if (type_flatten(expr.type).type_kind == ENUM) return true;
				continue;
			case SUBSCRIPT:
			case SUBSCRIPT_ADDR:
			case SLICE:
				expr = exprptr(expr.expr_kind == SLICE ? expr.slice_expr.expr : expr.subscript_expr.expr);
				if (!expr.type) return false;
				switch (type_flatten(expr.type).type_kind)
				{
					case ARRAY:
					case VECTOR:
					case SIMD_VECTOR:
						continue;
					default:
						return false;
				}
			case UNARY:
				if (expr.unary_expr.operator != DEREF) return false;
				expr = expr.unary_expr.expr;
				if (expr.expr_kind == SUBSCRIPT_ADDR) continue;
				if (expr.expr_kind != UNARY || expr.unary_expr.operator != ADDR) return false;
				expr = expr.unary_expr.expr;
				continue;
			default:
				return false;
		}
	}
}

// sema_expr.c:638 (static)
fn bool expr_refers_to_const(Expr* expr)
{
	switch (expr.expr_kind)
	{
		case CONST:
			if (!expr_is_const_ref(expr)) return false;
			return expr.const_expr.global_ref.decl_kind == VAR && expr.const_expr.global_ref.var_decl.kind == CONST;
		case IDENTIFIER:
		{
			Decl* decl = expr.ident_expr;
			if (decl.decl_kind != VAR || decl.var_decl.kind != CONST || !decl.var_decl.init_expr) return false;
			return type_flatten(decl.type).type_kind == SLICE && expr_is_const(decl.var_decl.init_expr) && !sema_type_has_subscript_overloads(decl.type);
		}
		case PTR_ACCESS:
			return expr_refers_to_const(expr.inner_expr);
		case UNARY:
			if (expr.unary_expr.operator != ADDR) return false;
			expr = expr.unary_expr.expr;
			if (expr.expr_kind == UNARY && expr.unary_expr.operator == DEREF) return expr_refers_to_const(expr.unary_expr.expr);
		case SUBSCRIPT_ADDR:
		case SLICE:
			break;
		default:
			return false;
	}
	if (expr_is_const(expr)) return false;
	if (expr_is_const_storage(expr, true)) return true;
	if (expr.expr_kind == SLICE) return expr_refers_to_const(exprptr(expr.slice_expr.expr));
	return expr.expr_kind == SUBSCRIPT_ADDR && expr_refers_to_const(exprptr(expr.subscript_expr.expr));
}

// sema_expr.c:670 (static)
<* The c3c labels ERR / CHECK_OPTIONAL / FAILED_REF become the helpers below. *>
fn bool sema_binary_is_expr_lvalue(SemaContext* context, Expr* top_expr, Expr* expr, bool* failed_ref)
{
	if (expr.expr_kind == CT_SUBSCRIPT) return true;
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
			unreachable();
		case SWIZZLE:
			if (expr.swizzle_expr.is_overlapping)
			{
				return @sema_error_at(context, expr.loc, "You cannot use swizzling to assign to multiple elements if they are overlapping");
			}
			if (!sema_binary_is_expr_lvalue(context, top_expr, exprptr(expr.swizzle_expr.parent), failed_ref)) return false;
			return lvalue_check_optional(context, top_expr, expr, failed_ref);
		case LAMBDA:
			if (failed_ref) return lvalue_failed_ref(failed_ref);
			return @sema_error_at(context, expr.loc, "This expression is a value and cannot be assigned to.");
		case EXT_TRUNC:
		case INT_TO_BOOL:
		case DISCARD:
			return lvalue_err(context, top_expr, failed_ref);
		case IDENTIFIER:
		{
			Decl* decl = expr.ident_expr;
			if (decl.decl_kind != VAR)
			{
				if (failed_ref) return lvalue_failed_ref(failed_ref);
				return @sema_error_at(context, top_expr.loc, "You cannot assign a value to %s.", decl_to_a_name(decl));
			}
			if (decl.var_decl.kind == CONST)
			{
				if (failed_ref) return lvalue_failed_ref(failed_ref);
				return @sema_error_at(context, top_expr.loc, "You cannot assign to a constant.");
			}
			decl = decl_raw(decl);
			switch (decl.var_decl.kind)
			{
				case LOCAL_CT:
				case LOCAL_CT_TYPE:
				case LOCAL:
				case GLOBAL:
				case PARAM:
				case PARAM_CT:
				case PARAM_CT_TYPE:
					return true;
				case CONST:
				case PARAM_EXPR:
					unreachable();
				case MEMBER:
				case BITMEMBER:
					return lvalue_err(context, top_expr, failed_ref);
				case UNWRAPPED:
				case ERASE:
				case REWRAPPED:
					unreachable();
			}
		}
		case UNARY:
			if (expr.unary_expr.operator != DEREF) return lvalue_err(context, top_expr, failed_ref);
			if (@is_optional(expr))
			{
				if (failed_ref) return lvalue_failed_ref(failed_ref);
				return @sema_error_at(context, top_expr.loc, "You cannot assign to a dereferenced optional.");
			}
			return true;
		case BITACCESS:
		case ACCESS_RESOLVED:
		{
			Decl* decl = expr.access_resolved_expr.ref;
			switch (decl.decl_kind)
			{
				case MACRO:
				case FUNC:
					if (failed_ref) return lvalue_failed_ref(failed_ref);
					return @sema_error_at(context, top_expr.loc, "You cannot assign a value to %s.", decl_to_a_name(decl));
				case VAR:
					if (type_flatten(expr.access_resolved_expr.parent.type).type_kind == ENUM)
					{
						if (failed_ref) return lvalue_failed_ref(failed_ref);
						return @sema_error_at(context, top_expr.loc, "Associated enum values are constant and can't be assigned to.");
					}
					nextcase default;
				default:
					if (!sema_binary_is_expr_lvalue(context, top_expr, expr.access_resolved_expr.parent, failed_ref)) return false;
					return lvalue_check_optional(context, top_expr, expr, failed_ref);
			}
		}
		case SUBSCRIPT:
		case SLICE:
		{
			Expr* parent = exprptr(expr.expr_kind == SLICE ? expr.slice_expr.expr : expr.subscript_expr.expr);
			if (expr_is_const_storage(expr, true) || (parent.expr_kind == IDENTIFIER && expr_refers_to_const(parent)))
			{
				if (failed_ref) return lvalue_failed_ref(failed_ref);
				return @sema_error_at(context, top_expr.loc, "You cannot assign to an element of a constant.");
			}
			if (parent.type && (type_is_arraylike(type_flatten(parent.type)) || parent.expr_kind == SLICE) && !sema_binary_is_expr_lvalue(context, top_expr, parent, failed_ref)) return false;
			return lvalue_check_optional(context, top_expr, expr, failed_ref);
		}
		case SUBSCRIPT_ASSIGN:
			return lvalue_check_optional(context, top_expr, expr, failed_ref);
		case CONST:
			if (failed_ref) return lvalue_failed_ref(failed_ref);
			return @sema_error_at(context, top_expr.loc, "You cannot assign to a constant expression.");
		default:
			// ADDR_CONVERSION, ASM, BINARY, CALL, ... (c3c lists them all): goto ERR.
			return lvalue_err(context, top_expr, failed_ref);
	}
}

<* sema_binary_is_expr_lvalue `ERR:` label. *>
fn bool lvalue_err(SemaContext* context, Expr* top_expr, bool* failed_ref) @local
{
	if (failed_ref) return lvalue_failed_ref(failed_ref);
	return @sema_error_at(context, top_expr.loc, "An assignable expression, like a variable, was expected here.");
}

<* sema_binary_is_expr_lvalue `CHECK_OPTIONAL:` label. *>
fn bool lvalue_check_optional(SemaContext* context, Expr* top_expr, Expr* expr, bool* failed_ref) @local
{
	if (@is_optional(expr))
	{
		if (failed_ref) return lvalue_failed_ref(failed_ref);
		return @sema_error_at(context, top_expr.loc, "You cannot assign to an optional value.");
	}
	return true;
}

<* sema_binary_is_expr_lvalue `FAILED_REF:` label. *>
fn bool lvalue_failed_ref(bool* failed_ref) @local
{
	*failed_ref = true;
	return false;
}

// sema_expr.c:861
fn bool expr_may_ref(Expr* expr)
{
	switch (expr.expr_kind)
	{
		case ADDR_CONVERSION:
		case CONTRACT:
		case DEFAULT_ARG:
		case DISCARD:
		case ENUM_FROM_ORD:
		case EXT_TRUNC:
		case FLOAT_TO_INT:
		case INT_TO_BOOL:
		case INT_TO_FLOAT:
		case INT_TO_PTR:
		case LAMBDA:
		case MAKE_SLICE:
		case MEMBER_GET:
		case MEMBER_SET:
		case PTR_ACCESS:
		case PTR_TO_INT:
		case RECAST:
		case RVALUE:
		case SCALAR_TO_VECTOR:
		case SLICE_LEN:
		case SLICE_TO_VEC_ARRAY:
		case SWIZZLE:
		case TYPECALL:
		case VECTOR_FROM_ARRAY:
		case VECTOR_TO_ARRAY:
			return false;
		case SUBSCRIPT_ASSIGN:
			return true;
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
			unreachable();
		case IDENTIFIER:
		{
			Decl* decl = expr.ident_expr;
			if (decl.decl_kind != VAR) return false;
			if (decl.var_decl.kind == CONST) return false;
			decl = decl_raw(decl);
			switch (decl.var_decl.kind)
			{
				case LOCAL:
				case GLOBAL:
				case PARAM:
					return true;
				case CONST:
				case PARAM_EXPR:
				case MEMBER:
				case BITMEMBER:
				case LOCAL_CT:
				case LOCAL_CT_TYPE:
				case PARAM_CT:
				case PARAM_CT_TYPE:
					return false;
				case UNWRAPPED:
				case ERASE:
				case REWRAPPED:
					unreachable();
			}
		}
		case UNARY:
			return expr.unary_expr.operator == DEREF;
		case BITACCESS:
		case ACCESS_RESOLVED:
			return expr_may_ref(expr.access_resolved_expr.parent);
		case SUBSCRIPT:
		case SLICE:
		case SUBSCRIPT_ADDR:
			return true;
		case HASH_IDENT:
			return false;
		case TWO:
			return expr_may_ref(expr.two_expr.last);
		case EXPRESSION_LIST:
			if (!expr.expression_list.len) return false;
			return expr_may_ref(@veclast(expr.expression_list));
		default:
			// ASM, BINARY, CALL, CONST, ... (c3c lists them all).
			return false;
	}
}

// sema_expr.c:989
fn bool sema_expr_check_assign(SemaContext* context, Expr* expr, bool* failed_ref)
{
	Expr* inner;
	if (!sema_binary_is_expr_lvalue(context, expr, expr, failed_ref)) return false;
	if (expr.expr_kind == SUBSCRIPT)
	{
		inner = exprptr(expr.subscript_expr.expr);
		if (inner.expr_kind == IDENTIFIER) decl_write(inner.ident_expr);
		if (inner.expr_kind == UNARY && inner.unary_expr.operator == DEREF && type_is_arraylike(type_flatten(inner.type))) inner = inner.inner_expr;
	}
	else
	{
		if (expr.expr_kind == BITACCESS || expr.expr_kind == ACCESS_RESOLVED) expr = expr.access_resolved_expr.parent;
		if (expr.expr_kind == IDENTIFIER)
		{
			decl_write(expr.ident_expr);
		}
		if (expr.expr_kind != UNARY) return true;
		inner = expr.inner_expr;
	}
	// CHECK_INNER:
	if (expr_is_const(inner))
	{
		switch (inner.const_expr.const_kind)
		{
			case FLOAT:
			case INTEGER:
			case BOOL:
			case FAULT:
			case ENUM:
			case BYTES:
			case STRING:
			case TYPEID:
			case SLICE:
			case INITIALIZER:
			case UNTYPED_LIST:
			case MEMBER:
			case REFLECTION:
				return @sema_error_at(context, expr.loc, "You cannot assign to a constant expression.");
			case POINTER:
			case REF:
				return true;
		}
	}
	if (inner.expr_kind != IDENTIFIER) return true;
	Decl* decl = inner.ident_expr;
	if (decl.decl_kind != VAR) return true;
	if (!decl.var_decl.in_param || decl.var_decl.out_param) return true;
	return @sema_error_at(context, inner.loc, "'in' parameters may not be assigned to.");
}

// sema_expr.c:1039
fn void sema_fold_global_init(Expr* init)
{
	if (init.expr_kind != IDENTIFIER) return;
	Decl* decl = decl_flatten(init.ident_expr);
	if (decl.decl_kind != VAR || decl.var_decl.kind != CONST || decl.is_extern) return;
	expr_replace(init, copy_expr_single(decl.var_decl.init_expr));
}

// sema_expr.c:1047 (static)
fn bool sema_cast_ident_rvalue(SemaContext* context, Expr* expr)
{
	Decl* decl = expr.ident_expr;
	decl = decl_flatten(decl);
	switch (decl.decl_kind)
	{
		case FUNC:
			@sema_error_at(context, expr.loc, "A function name cannot be used as a value, did you want to pass it by pointer? If so then you need to add '&', like '&%s'.", decl.name);
			return expr_poison(expr);
		case MACRO:
			@sema_error_at(context, expr.loc, "Expected a macro followed by (...).");
			return expr_poison(expr);
		case ENUM_CONSTANT:
			// This can't happen, inferred identifiers are folded to consts they are never identifiers.
			unreachable();
		case VAR:
			break;
		case FAULT:
			expr_rewrite_const_fault(expr, decl);
			return true;
		case FNTYPE:
		case ALIAS:
		case ALIAS_PATH:
		case ATTRIBUTE:
		case BODYPARAM:
		case CT_ASSERT:
		case CT_ECHO:
		case CT_EXEC:
		case CT_EXPAND:
		case CT_INCLUDE:
		case DECLARRAY:
		case TYPEDEF:
		case ERASED:
		case GROUP:
		case IMPORT:
		case TYPE_ALIAS:
		case GENERIC:
		case GENERIC_INSTANCE:
		case CONTRACT:
			unreachable();
		case POISONED:
			return expr_poison(expr);
		case LABEL:
			@sema_error_at(context, expr.loc, "Did you intend to use the label '%s' here?", decl.name);
			return expr_poison(expr);
		case BITSTRUCT:
			@sema_error_at(context, expr.loc, "Expected bitstruct followed by (...) or '.'.");
			return expr_poison(expr);
		case STRUCT:
			@sema_error_at(context, expr.loc, "Expected struct followed by {...} or '.'.");
			return expr_poison(expr);
		case INTERFACE:
			@sema_error_at(context, expr.loc, "Expected an interface to be followed by '.' when used as an expression.");
			return expr_poison(expr);
		case UNION:
			@sema_error_at(context, expr.loc, "Expected union followed by {...} or '.'.");
			return expr_poison(expr);
		case CONSTSET:
			@sema_error_at(context, expr.loc, "Expected constset name followed by '.' and a constset value.");
			return expr_poison(expr);
		case ENUM:
			@sema_error_at(context, expr.loc, "Expected enum name followed by '.' and an enum value.");
			return expr_poison(expr);
	}
	switch (decl.var_decl.kind)
	{
		case CONST:
		case GLOBAL:
		case LOCAL:
		case LOCAL_CT:
		case LOCAL_CT_TYPE:
			if (decl.in_init)
			{
				return @sema_error_at(context, expr.loc, "This looks like the initialization of the variable was circular.");
			}
		default:
			break;
	}
	switch (decl.var_decl.kind)
	{
		case CONST:
			if (decl.is_extern) return true;
			// Only fold aggregates if they are untyped and local
			if ((decl.var_decl.type_info || !decl.var_decl.is_static) && type_is_aggregate(decl.type)) return true;
			expr_replace(expr, copy_expr_single(decl.var_decl.init_expr));
			if (!sema_analyse_expr_rvalue(context, expr)) return false;
			if (!sema_cast_const(expr) && !expr_is_runtime_const(expr))
			{
				return @sema_error_at(context, decl.var_decl.init_expr.loc, "The expression must be constant.");
			}
			return true;
		case PARAM_EXPR:
		case ERASE:
		case REWRAPPED:
			unreachable();
		case PARAM_CT_TYPE:
		case PARAM_CT:
		case LOCAL_CT:
		case LOCAL_CT_TYPE:
			return sema_cast_ct_ident_rvalue(context, expr);
		case LOCAL:
			if (decl.var_decl.copy_const && decl.var_decl.init_expr && expr_is_const(decl.var_decl.init_expr))
			{
				// c3c: assert(decl.var_decl.init_expr.resolve_status == DONE); -- C assert, compiled out in c3c release builds
				expr_replace(expr, copy_expr_single(decl.var_decl.init_expr));
				return true;
			}
			return true;
		case PARAM:
		case GLOBAL:
		case UNWRAPPED:
			return true;
		case BITMEMBER:
		case MEMBER:
			@sema_error_at(context, expr.loc, "Expected '%s' followed by a method call or property.", decl.name);
			return expr_poison(expr);
	}
}

// sema_expr.c:1168 (static)
fn bool sema_expr_analyse_ternary(SemaContext* context, Type* infer_type, Expr* expr)
{
	Expr* left = exprptrzero(expr.ternary_expr.then_expr);
	Expr* cond = exprptr(expr.ternary_expr.cond);
	CondResult path = COND_MISSING;
	bool is_const = expr.ternary_expr.is_const;
	bool success;
	// Normal
	if (left)
	{
		if (!sema_analyse_cond_expr(context, cond, &path)) return expr_poison(expr);
		if (is_const && path == COND_MISSING)
		{
			return @sema_error_at(context, cond.loc, "When using '???' the cond expression must evaluate to a constant.");
		}
		bool is_left = path == COND_TRUE;
		if (!is_const || is_left)
		{
			DynamicScope old_scope = scope_start(context, left.loc);
			success = sema_analyse_maybe_dead_expr(context, left, !is_left, infer_type);
			success = scope_end(context, old_scope, success);
			if (!success) return expr_poison(expr);
		}
	}
	else
	{
		// Elvis
		if (!sema_analyse_expr_rvalue(context, cond)) return expr_poison(expr);
		assert(cond && cond.type);
		Type* type = cond.type.canonical;
		if (type.type_kind != BOOL && !may_cast(context, cond, type_bool, true, true))
		{
			return @sema_error_at(context, cond.loc, "Cannot convert expression to boolean.");
		}
		if (expr_is_const(cond))
		{
			Expr* copy = copy_expr_single(cond);
			cast_no_check(copy, type_bool, false);
			assert(expr_is_const_bool(copy));
			path = copy.const_expr.b ? COND_TRUE : COND_FALSE;
			expr.ternary_expr.then_expr = exprid(cond);
			expr.ternary_expr.cond = exprid(copy);
			left = cond;
		}
		else
		{
			// From foo :? bar
			// (bool)($temp = foo) ? $temp : bar
			Decl* temp = decl_new_generated_var(cond.type, LOCAL, cond.loc);
			temp.var_decl.init_expr = expr_copy(cond);
			cond.expr_kind = DECL;
			cond.decl_expr = temp;
			cond.resolve_status = NOT_DONE;
			if (!sema_analyse_expr_rvalue(context, cond)) return false;
			if (!cast_explicit(context, cond, type_bool)) return false;
			left = expr_variable(temp);
			expr.ternary_expr.then_expr = exprid(left);
			if (!sema_analyse_expr_rvalue(context, left)) return false;
		}
	}

	bool is_right = path == COND_FALSE;

	Expr* right = exprptr(expr.ternary_expr.else_expr);

	if (!is_const || is_right)
	{
		DynamicScope old_scope = scope_start(context, right.loc);
		success = sema_analyse_maybe_dead_expr(context, right, !is_right, infer_type);
		success = scope_end(context, old_scope, success);
		if (!success) return expr_poison(expr);
	}

	if (is_const)
	{
		switch (path)
		{
			case COND_TRUE:
				expr_replace(expr, left);
				return true;
			case COND_FALSE:
				expr_replace(expr, right);
				return true;
			default:
				unreachable();
		}
	}

	Type* left_canonical = left.type.canonical;
	Type* right_canonical = right.type.canonical;
	if (left_canonical != right_canonical)
	{
		Type* max = type_find_max_type(context, type_no_optional(left_canonical), type_no_optional(right_canonical), left, right);
		if (!max)
		{
			return @sema_error_at(context, expr.loc, "Cannot find a common parent type of '%s' and '%s'",
				type_to_error_string(left.type), type_to_error_string(right.type));
		}
		if (max == poisoned_type) return false;
		Type* no_fail_max = type_no_optional(max);
		if (!cast_implicit_binary(context, left, no_fail_max, null)
			|| !cast_implicit_binary(context, right, no_fail_max, null)) return false;
	}

	switch (sema_resolve_storage_type(context, left.type))
	{
		case STORAGE_ERROR:
			return false;
		case STORAGE_COMPILE_TIME:
			if (left.type == type_untypedlist)
			{
				return @sema_error_at(context, expr.loc, "The ternary would be an 'untyped list', you need to explicitly type one or both branches to a runtime type.");
			}
			return @sema_error_at(context, expr.loc, "A ternary must always return a runtime type, but it was %s.", type_invalid_storage_type_name(left_canonical));
		default:
			break;
	}
	if (path != COND_MISSING)
	{
		expr_replace(expr, path == COND_TRUE ? left : right);
	}

	expr_binary_unify_failability(expr, left, right);
	return true;
}

// sema_expr.c:1299 (static)
fn bool sema_expr_analyse_enum_constant(SemaContext* context, Expr* expr, String name, Decl* decl)
{
	Decl* enum_constant = decl_find_enum_constant(decl, name);
	if (!enum_constant) return false;

	if (!sema_analyse_decl(context, decl))
	{
		expr_poison(expr);
		return true;
	}

	if (enum_constant.resolve_status == NOT_DONE)
	{
		if (decl.decl_kind == ENUM)
		{
			@sema_error_at(context, expr.loc, "Unable to properly resolve enum constant value, this can sometimes happen in recursive definitions.");
		}
		else
		{
			@sema_error_at(context, expr.loc, "Unable to properly resolve constset value, this can sometimes happen in recursive definitions.");
		}
		expr_poison(expr);
		return true;
	}
	if (!sema_display_deprecated_warning_on_use(context, decl, expr.loc))
	{
		expr_poison(expr);
		return true;
	}
	if (enum_constant.resolve_status == DONE)
	{
		if (!sema_display_deprecated_warning_on_use(context, enum_constant, expr.loc))
		{
			expr_poison(expr);
			return true;
		}
	}
	expr.type = decl.type;
	if (enum_constant.enum_constant.is_raw)
	{
		expr_replace(expr, copy_expr_single(enum_constant.enum_constant.value));
		if (!sema_analyse_expr_rvalue(context, expr)) expr_poison(expr);
		return true;
	}
	expr.expr_kind = CONST;
	expr.const_expr.const_kind = ENUM;
	expr.const_expr.enum_val = enum_constant;
	expr.resolve_status = DONE;
	return true;
}

// sema_expr.c:1338 (static)
fn bool sema_identifier_find_possible_inferred(SemaContext* context, Type* to, Expr* expr)
{
	to = to.canonical;
	switch (to.type_kind)
	{
		case CONSTSET:
		case ENUM:
			if (!decl_ok(to.decl))
			{
				expr_poison(expr);
				return true;
			}
			return sema_expr_analyse_enum_constant(context, expr, expr.unresolved_ident_expr.ident, to.decl);
		default:
			return false;
	}
}

// sema_expr.c:1352 (static)
fn bool sema_expr_analyse_identifier(SemaContext* context, Type* to, Expr* expr, bool* failed_ref)
{
	assert(expr);
	assert(expr.unresolved_ident_expr.ident.ptr);

	assert(expr.resolve_status != DONE);
	DeclId body_param;
	if (!expr.unresolved_ident_expr.path && context.current_macro && (body_param = context.current_macro.func_decl.body_param))
	{
		if (expr.unresolved_ident_expr.ident.ptr == declptr(body_param).name.ptr)
		{
			expr.expr_kind = MACRO_BODY_EXPANSION;
			expr.body_expansion_expr.first_stmt = 0;
			expr.body_expansion_expr.declarations = {};
			expr.resolve_status = NOT_DONE;
			expr.type = type_void;
			return true;
		}
	}
	// Just start with inference
	if (!expr.unresolved_ident_expr.path && to)
	{
		if (sema_identifier_find_possible_inferred(context, to, expr)) return expr_ok(expr);
	}

	Decl* decl = sema_find_path_symbol(context, expr.unresolved_ident_expr.ident, expr.unresolved_ident_expr.path);

	// Is this a broken decl?
	if (!decl_ok(decl)) return false;

	// Rerun if we can't do inference.
	if (!decl)
	{
		if (failed_ref)
		{
			*failed_ref = true;
			return false;
		}
		if (!expr.unresolved_ident_expr.path && expr.unresolved_ident_expr.is_const && (!to || (to.canonical.type_kind != ENUM && to.canonical.type_kind != CONSTSET)))
		{
			CompilationUnit*[] units = context.unit.mod.units;
			foreach (unit : units)
			{
				foreach (d : unit.enums)
				{
					foreach (enum_val : d.enums.values)
					{
						if (enum_val.name.ptr == expr.unresolved_ident_expr.ident.ptr)
						{
							String type = d.decl_kind == CONSTSET ? "constset" : "enum";
							return @sema_error_at(context, expr.loc, "No constant named '%s' was found in the current scope. Did you "
								"mean the value '%s' of the %s '%s'? The %s type cannot be inferred%s, so in that case you need to use "
								"the qualified name: '%s.%s'.",
								enum_val.name, enum_val.name, type, d.name, type, to ? " correctly" : "", d.name, enum_val.name);
						}
					}
				}
			}
		}
		decl = sema_resolve_symbol(context, expr.unresolved_ident_expr.ident, expr.unresolved_ident_expr.path, expr.loc);
		assert(!decl);
		return false;
	}
	if (failed_ref && decl_is_defaulted_var(decl))
	{
		*failed_ref = true;
		return false;
	}

	if (decl_needs_prefix(decl))
	{
		if (!sema_analyse_decl(context, decl)) return false;
		if (decl.decl_kind == ERASED)
		{
			if (decl.is_if)
			{
				@sema_error_at(context, expr.loc, "Matching identifier is not available due to '@if' being evaluated to false.");
			}
			else
			{
				@sema_error_at(context, expr.loc, "Matching identifier is not available due to '@feat' being evaluated to false.");
			}
			@sema_note_prev_at(decl.loc, "The definition was here.");
			return false;
		}
		if (decl.unit.mod != context.unit.mod && !expr.unresolved_ident_expr.path)
		{
			String message;
			switch (decl.decl_kind)
			{
				case VAR:
					message = "Globals";
				case FUNC:
					message = "Functions";
				case MACRO:
					message = "Macros";
				case ALIAS:
					message = "Aliases";
				case FAULT:
					message = "Faults";
				default:
					unreachable();
			}
			return @sema_error_at(context, expr.loc, "%s from other modules must be prefixed with the module name, please use %s::%s instead.", message, decl.unit.mod.short_path, decl.name);
		}
	}
	if (decl_is_defaulted_var(decl))
	{
		return @sema_error_at(context, expr.loc, "The parameter '%s' was not provided by the caller.", decl.name);
	}
	if (decl.resolve_status != DONE)
	{
		if (!sema_analyse_decl(context, decl)) return decl_poison(decl);
	}
	sema_display_deprecated_warning_on_use(context, decl, expr.loc);

	decl_used(decl);
	decl = decl_flatten(decl);
	decl_used(decl);
	if (decl.decl_kind == VAR)
	{
		decl_read(decl);
		switch (decl.var_decl.kind)
		{
			case CONST:
				if (!decl.type)
				{
					if (decl.var_decl.init_expr.resolve_status == RUNNING)
					{
						return @sema_error_at(context, decl.var_decl.init_expr.loc, "The evaluation of this expression is recursive.");
					}
					Expr* copy = copy_expr_single(decl.var_decl.init_expr);
					if (!sema_analyse_expr_rvalue(context, copy)) return false;
					if (!expr_is_runtime_const(copy))
					{
						return @sema_error_at(context, expr.loc, "Constant value did not evaluate to a constant.");
					}
					expr_replace(expr, copy);
					return true;
				}
			case PARAM:
				if (context.call_env.is_naked_fn && !(context.active_scope.flags & SCOPE_MACRO))
				{
					return @sema_error_at(context, expr.loc, "Parameters may not be directly accessed in '@naked' functions.");
				}
			case GLOBAL:
				if (context.call_env.pure)
				{
					return @sema_error_at(context, expr.loc, "'@pure' functions may not access globals.");
				}
			default:
				break;
		}
	}
	else if (decl.decl_kind == FAULT)
	{
		expr_rewrite_const_fault(expr, decl);
		return true;
	}
	expr_resolve_ident(expr, decl);
	return true;
}

// sema_expr.c:1517 (static)
fn bool sema_expr_resolve_ct_identifier(SemaContext* context, Expr* expr)
{
	assert(expr.resolve_status != DONE);
	assert(expr && expr.ct_ident_expr.identifier.ptr);

	Decl* decl = sema_resolve_symbol(context, expr.ct_ident_expr.identifier, null, expr.loc);
	if (!decl)
	{
		return expr_poison(expr);
	}

	if (decl_is_defaulted_var(decl))
	{
		return @sema_error_at(context, expr.loc, "The parameter '%s' was not provided by the caller.", decl.name);
	}
	assert(decl.decl_kind == VAR);
	assert(decl.resolve_status == DONE);

	decl_read(decl);
	expr.type = decl.type;
	expr.ident_expr = decl;
	expr.expr_kind = IDENTIFIER;
	return true;
}

// sema_expr.c:1544 (static)
fn bool sema_expr_analyse_ct_identifier(SemaContext* context, Expr* expr)
{
	if (!sema_expr_resolve_ct_identifier(context, expr)) return false;
	return sema_cast_ct_ident_rvalue(context, expr);
}

// sema_expr.c:1551 (static)
fn bool sema_binary_analyse_with_inference(SemaContext* context, Expr* left, Expr* right, BinaryOp op, Type* to)
{
	int op_result;
	switch (op)
	{
		case AND:
		case OR:
		case CT_AND:
		case CT_OR:
			op_result = 1;
		case EQ:
		case NE:
		case GT:
		case GE:
		case LE:
		case LT:
			op_result = 2;
		default:
			op_result = 0;
	}
	if (op_result == 1) return true;
	// If lhs or rhs is an initializer list, infer
	bool is_init_rhs = right.expr_kind == INITIALIZER_LIST;
	bool is_init_lhs = left.expr_kind == INITIALIZER_LIST;
	if (!is_init_rhs || !is_init_lhs)
	{
		if (is_init_rhs)
		{
			if (!sema_analyse_expr_rvalue(context, left)) return false;
			if (type_kind_is_any_vector(type_flatten(left.type).type_kind))
			{
				return sema_analyse_inferred_expr(context, left.type, right, null);
			}
			return sema_analyse_expr_rvalue(context, right);
		}
		if (is_init_lhs)
		{
			if (!sema_analyse_expr_rvalue(context, right)) return false;
			if (type_kind_is_any_vector(type_flatten(right.type).type_kind))
			{
				return sema_analyse_inferred_expr(context, right.type, left, null);
			}
			return sema_analyse_expr_rvalue(context, left);
		}

		if (op_result == 2)
		{
			if (!sema_analyse_expr_rvalue(context, left)) return false;

			switch (left.type.canonical.type_kind)
			{
				case ENUM:
				case CONSTSET:
					return sema_analyse_inferred_expr(context, left.type, right, null);
				default:
					return sema_analyse_expr_rvalue(context, right);
			}
		}
	}
	// EVAL_BOTH:
	// Infer constset in Foo f = FOO | BAR
	if (to && to.canonical.type_kind == CONSTSET)
	{
		return sema_analyse_inferred_expr(context, to, left, null) && sema_analyse_inferred_expr(context, to, right, null);
	}
	if (!sema_analyse_expr_rvalue(context, left)) return false;

	// Infer constset in f & BAR
	if (left.type.canonical.type_kind == CONSTSET)
	{
		return sema_analyse_inferred_expr(context, left.type, right, null);
	}
	return sema_analyse_expr_rvalue(context, right);
}

// sema_expr.c:1612 (static)
fn bool sema_binary_analyse_subexpr(SemaContext* context, Expr* left, Expr* right)
{
	// Special handling of f = FOO_BAR
	if (right.expr_kind == UNRESOLVED_IDENTIFIER && right.unresolved_ident_expr.is_const)
	{
		if (!sema_analyse_expr_rvalue(context, left)) return false;
		switch (type_flatten(left.type).type_kind)
		{
			case ENUM:
			case CONSTSET:
				return sema_analyse_inferred_expr(context, left.type, right, null);
			default:
				break;
		}
	}
	// Special handling of f = FOO_BAR
	if (left.expr_kind == UNRESOLVED_IDENTIFIER && left.unresolved_ident_expr.is_const)
	{
		if (!sema_analyse_expr_rvalue(context, right)) return false;
		switch (type_flatten(right.type).type_kind)
		{
			case ENUM:
			case CONSTSET:
				return sema_analyse_inferred_expr(context, right.type, left, null);
			default:
				break;
		}
	}
	if (right.expr_kind == INITIALIZER_LIST)
	{
		if (!sema_analyse_expr_rvalue(context, left)) return false;
		if (type_kind_is_any_vector(type_flatten(left.type).type_kind))
		{
			return sema_analyse_inferred_expr(context, left.type, right, null);
		}
		return sema_analyse_expr_rvalue(context, right);
	}
	if (left.expr_kind == INITIALIZER_LIST)
	{
		if (!sema_analyse_expr_rvalue(context, right)) return false;
		if (type_kind_is_any_vector(type_flatten(right.type).type_kind))
		{
			return sema_analyse_inferred_expr(context, right.type, left, null);
		}
		return sema_analyse_expr_rvalue(context, left);
	}
	return sema_analyse_expr_rvalue(context, left) && sema_analyse_expr_rvalue(context, right);
}

// sema_expr.c:1661 (static)
fn bool sema_binary_analyse_arithmetic_subexpr(SemaContext* context, Expr* expr, String error, bool bool_and_bitstruct_is_allowed, OperatorOverload* operator_overload_ref, bool* failed_ref)
{
	Expr* left = exprptr(expr.binary_expr.left);
	Expr* right = exprptr(expr.binary_expr.right);

	// 1. Analyse both sides.
	assert(left.resolve_status == DONE);
	assert(right.resolve_status == DONE);

	Type* left_type = type_no_optional(left.type).canonical;
	Type* right_type = type_no_optional(right.type).canonical;
	Type* flat_left = type_flatten(left_type);

	if (bool_and_bitstruct_is_allowed)
	{
		if (flat_left.type_kind == BITSTRUCT && left_type == right_type) return true;
		if (flat_left == type_bool && left_type == right_type) return true;
	}

	// 2. Perform promotion to a common type.
	return sema_binary_arithmetic_promotion(context, left, right, left_type, right_type, expr, error,
		bool_and_bitstruct_is_allowed, operator_overload_ref, failed_ref);
}

// sema_expr.c:1687 (static)
fn int sema_call_find_index_of_named_parameter(SemaContext* context, Decl*[] func_params, Expr* expr)
{
	String name = expr.named_argument_expr.name;
	foreach (i, func_param : func_params)
	{
		if (func_param && func_param.name.ptr == name.ptr) return (int)i;
	}
	@sema_error_at(context, expr.loc, "There's no parameter with the name '%s'.", name);
	return -1;
}

// sema_expr.c:1698 (static)
fn bool sema_call_check_invalid_body_arguments(SemaContext* context, Expr* call, CalledDeclContext* callee)
{
	Expr* macro_body = exprptrzero(call.call_expr.macro_body);
	Decl*[] body_arguments = macro_body ? macro_body.macro_body_expr.body_arguments : {};
	bool has_body_arguments = body_arguments.len > 0;

	// 1. Check if there are body arguments but no actual block.
	if (has_body_arguments && !callee.block_parameter.ptr)
	{
		if (callee.macro_decl)
		{
			return @sema_error_at(context, body_arguments[0].loc, "This macro does not support arguments.");
		}
		return @sema_error_at(context, body_arguments[0].loc, "Only macro calls may have body arguments for a trailing block.");
	}

	// 2. If there is a body then...
	if (macro_body && macro_body.macro_body_expr.body)
	{
		// 2a. If not a macro then this is an error.
		if (!callee.macro_decl)
		{
			return @sema_error_at(context, call.loc, "Only macro calls may take a trailing block.");
		}
		// 2b. If we don't have a block parameter, then this is an error as well
		if (!callee.block_parameter.ptr)
		{
			return @sema_error_at(context, call.loc, "This macro does not support trailing statements, please remove it.");
		}

		// 2c. This is a macro and it has a block parameter. Everything is fine!
		return true;
	}

	// 3. If we don't have a body, then if it has a block parameter this is an error.
	if (callee.block_parameter.ptr)
	{
		assert(callee.macro_decl);
		return @sema_error_at(context, call.loc, "Expected call to have a trailing statement, did you forget to add it?");
	}

	// 4. No "body" and no block parameter, this is fine.
	return true;
}

<* c3c RETURN_ERR_WITH_DEFINITION (returns false). *>
fn bool param_err_with_definition(Decl* definition, int errors) @local
{
	if (compiler.context.errors_found != errors) @sema_note_prev_at(definition.loc, "The definition is here.");
	return false;
}

<* c3c RETURN_SEMA_FUNC_ERROR (the formatted error is emitted by the caller). *>
fn bool sema_func_error_note(Decl* decl) @local
{
	@sema_note_prev_at(decl.loc, "The definition was here.");
	return false;
}

// sema_expr.c:1745 (static)
fn bool sema_analyse_parameter(SemaContext* context, Expr* arg, Decl* param, Decl* definition, bool* optional_ref, bool* no_match_ref, bool macro_, bool is_method_target)
{
	VarDeclKind kind = param.var_decl.kind;
	Type* type = param.type;
	// 16. Analyse a regular argument.
	int errors = compiler.context.errors_found;
	switch (kind)
	{
		case PARAM:
			// foo
			if (expr_is_named_param(arg))
			{
				// This only happens in body arguments
				return @sema_error_at(context, arg.loc, "Named arguments are not supported for body parameters.");
			}
			if (!sema_analyse_expr_rhs_param(context, type, arg, no_match_ref)) return false;
			if (@is_optional(arg)) *optional_ref = true;
			switch (sema_resolve_storage_type(context, arg.type))
			{
				case STORAGE_ERROR:
					return false;
				case STORAGE_NORMAL:
					break;
				case STORAGE_VOID:
				case STORAGE_WILDCARD:
					return @sema_error_at(context, arg.loc, "A 'void' value cannot be passed as a parameter.");
				case STORAGE_COMPILE_TIME:
					return @sema_error_at(context, arg.loc, "It is only possible to use %s as a compile time parameter.",
									  type_invalid_storage_type_name(arg.type));
				case STORAGE_UNKNOWN:
					return @sema_error_at(context, arg.loc, "A value of type '%s' has no known size so cannot be "
										   "passed as a parameter, you can pass a pointer to it though.",
									  type_quoted_error_string(arg.type));
			}
			if (!sema_call_check_contract_param_match(context, param, arg)) return param_err_with_definition(definition, errors);
			if (!param.alignment)
			{
				assert(macro_, "Only in the macro case should we need to insert the alignment.");
				if (!sema_set_alloca_alignment(context, arg.type, &param.alignment)) return false;
			}
		case PARAM_EXPR:
			if (param.type)
			{
				if (!sema_analyse_expr_rhs_param(context, param.type, arg, null))
				{
					return param_err_with_definition(definition, errors);
				}
			}
			// #foo
			if (context.is_temp)
			{
				SemaContext* temp = context;
				context = (SemaContext*)calloc_arena(SemaContext::size);
				*context = *temp;
			}
			Expr* inner = expr_copy(arg);
			arg.expr_kind = OTHER_CONTEXT;
			ExprOtherContext other = { .context = context, .inner = inner };
			arg.expr_other_context = other;
			arg.resolve_status = NOT_DONE;
		case PARAM_CT:
			// $foo
			assert(macro_);
			if (!sema_analyse_expr_rhs_param(context, type, arg, no_match_ref))
			{
				return param_err_with_definition(definition, errors);
			}
			if (!sema_cast_const(arg) && !expr_is_runtime_const(arg))
			{
				if (is_method_target)
				{
					@sema_error_at(context, arg.loc, "This method is only valid on a compile time constant value.");
					return sema_func_error_note(definition);
				}
				if (arg.expr_kind == IDENTIFIER)
				{
					Decl* decl = arg.ident_expr;
					if (decl.decl_kind == VAR && decl.var_decl.kind == CONST && decl.is_extern)
					{
						@sema_error_at(context, arg.loc, "A compile-time parameter requires a value known at compile time. Did you mistake if for a regular parameter? 'extern' constants are not compile-time constants.");
						return sema_func_error_note(definition);
					}
				}
				@sema_error_at(context, arg.loc, "A compile time parameter must always be a compile-time constant value, did you mistake it for a regular parameter?");
				return sema_func_error_note(definition);
			}
		case PARAM_CT_TYPE:
			// $Foo
			if (!sema_analyse_expr(context, arg)) return param_err_with_definition(definition, errors);

			if (arg.expr_kind == TYPEINFO)
			{
				// c3c: assert(arg.type_expr.resolve_status == DONE); -- C assert, compiled out in c3c release builds
				expr_rewrite_const_typeid(arg, arg.type_expr.type);
			}
			if (!sema_cast_const(arg) || !expr_is_const_typeid(arg))
			{
				@sema_error_at(context, arg.loc, "A type, like 'int' or 'double' was expected for the parameter '%s'.", param.name);
				return sema_func_error_note(definition);
			}
		case CONST:
		case GLOBAL:
		case LOCAL:
		case MEMBER:
		case BITMEMBER:
		case LOCAL_CT:
		case LOCAL_CT_TYPE:
		case UNWRAPPED:
		case REWRAPPED:
		case ERASE:
			unreachable();
	}
	if (type_len_is_inferred(type))
	{
		param.type = type_no_optional(arg.type);
	}
	return true;
}

// sema_expr.c:1867 (static)
fn bool sema_set_default_argument(SemaContext* context, CalledDeclContext* callee, Expr* call, Decl* param, bool* no_match_ref, Expr** expr_ref, bool* optional)
{
	Expr* init_expr = param.var_decl.init_expr;
	if (!init_expr)
	{
		// Handle foo = ... macro init
		if (param.var_decl.no_init)
		{
			param.var_decl.defaulted = true;
		}
		return true;
	}
	Expr* arg = copy_expr_single(init_expr);
	bool parameter_checked = false;
	if (arg.resolve_status != DONE)
	{
		SemaContext default_context;
		SemaContext* new_context = context_transform_for_eval(context, &default_context, param.unit);
		ContextSwitchState switch_state = context_switch_state_push(context, new_context);
		new_context.generic_instance = declptrzero(param.generic_id);
		InliningSpan inlined_at;
		if (!new_context.inlined_at)
		{
			inlined_at = { .loc = call.loc, .instance = new_context.generic_instance != context.generic_instance ? new_context.generic_instance : null };
			new_context.inlined_at = &inlined_at;
		}
		bool success;
		DynamicScope old_scope = scope_start(context, arg.loc);
		new_context.original_module = context.original_module;
		success = sema_analyse_parameter(new_context, arg, param, callee.definition, optional, no_match_ref,
										 callee.macro_decl, false);
		success = success && sema_scope_check_locals(context, old_scope);
		success = scope_end(context, old_scope, success);
		context_switch_stat_pop(new_context, switch_state);
		sema_context_destroy(&default_context);
		if (no_match_ref && *no_match_ref) return true;
		if (!success)
		{
			// RETURN_NOTE_FUNC_DEFINITION
			@sema_note_prev_at(callee.definition.loc, "The definition was here.");
			return false;
		}
		parameter_checked = true;
	}
	switch (param.var_decl.kind)
	{
		case PARAM_CT:
		case PARAM_CT_TYPE:
		case PARAM_EXPR:
			*expr_ref = arg;
			param.var_decl.defaulted = true;
			if (parameter_checked) return true;
			return sema_analyse_parameter(context, arg, param, callee.definition, optional, no_match_ref,
										  callee.macro_decl, false);
		default:
			break;
	}
	Expr* function_scope_arg = expr_new(DEFAULT_ARG, arg.loc);
	function_scope_arg.resolve_status = DONE;
	function_scope_arg.type = arg.type;
	function_scope_arg.default_arg_expr.inner = arg;
	function_scope_arg.default_arg_expr.loc = callee.call_location;
	*expr_ref = function_scope_arg;
	if (parameter_checked) return true;
	return sema_analyse_parameter(context, function_scope_arg, param, callee.definition, optional, no_match_ref,
								  callee.macro_decl, false);
}

// sema_expr.c:1933 (static)
fn Expr* sema_splat_analyse_temp(SemaContext* context, Decl* decl, Expr* access, Decl*[]* evaluation_ref)
{
	if (evaluation_ref)
	{
		if (!sema_analyse_decl(context, decl) || !sema_analyse_expr_rvalue(context, access)) return null;
		@vec_add(evaluation_ref, decl);
		return access;
	}
	Expr* two = expr_new_expr(TWO, access);
	Expr* expr = expr_new(DECL, decl.loc);
	expr.decl_expr = decl;
	two.two_expr.first = expr;
	two.two_expr.last = access;
	return sema_analyse_expr_rvalue(context, two) ? two : null;
}

// sema_expr.c:1949 (static)
<* Returns a null slice on error (c3c NULL). *>
fn Expr*[] sema_splat_struct_insert(SemaContext* context, Expr*[] args, Expr* arg, Decl* strukt, int index, Decl*[]* evaluation_ref)
{
	int len = (int)strukt.strukt.members.len;
	args = sema_prepare_splat_insert(args, len, index);
	if (sema_cast_const(arg))
	{
		assert(expr_is_const_initializer(arg));
		ConstInitializer* initializer = arg.const_expr.initializer;
		if (initializer.kind == INIT_ZERO)
		{
			for (ArrayIndex i = 0; i < len; i++)
			{
				Expr* expr = expr_calloc();
				expr.loc = arg.loc;
				expr_rewrite_to_const_zero(expr, strukt.strukt.members[i].type);
				args[i + index] = expr;
			}
			return args;
		}
		assert(initializer.kind == INIT_STRUCT);
		for (ArrayIndex i = 0; i < len; i++)
		{
			ConstInitializer* c = initializer.init_struct[i];
			Expr* expr;
			switch (c.kind)
			{
				case INIT_ZERO:
					expr = expr_calloc();
					expr.loc = arg.loc;
					expr_rewrite_to_const_zero(expr, strukt.strukt.members[i].type);
					args[i + index] = expr;
				case INIT_VALUE:
					expr = copy_expr_single(c.init_value);
				default:
					expr = expr_calloc();
					expr.loc = arg.loc;
					expr_rewrite_const_initializer(expr, strukt.strukt.members[i].type, c);
			}
			args[i + index] = expr;
		}
		return args;
	}
	if (context.call_env.kind != ENV_FUNCTION)
	{
		@sema_error_at(context, arg.loc, "Cannot splat a non-constant value in a global context.");
		return {};
	}
	Decl* temp = decl_new_generated_var(arg.type, LOCAL, arg.loc);
	assert(arg);
	temp.var_decl.init_expr = arg;
	Expr* access = expr_new_expr(ACCESS_RESOLVED, arg);
	access.access_resolved_expr = { .parent = expr_variable(temp), .ref = strukt.strukt.members[0] };
	access.resolve_status = DONE;
	access.type = strukt.strukt.members[0].type;
	args[index] = sema_splat_analyse_temp(context, temp, access, evaluation_ref);
	if (!args[index]) return {};
	for (ArrayIndex i = 1; i < len; i++)
	{
		access = expr_new_expr(ACCESS_RESOLVED, arg);
		access.access_resolved_expr = { .parent = expr_variable(temp), .ref = strukt.strukt.members[i] };
		access.resolve_status = DONE;
		access.type = strukt.strukt.members[i].type;
		args[index + i] = access;
	}
	return args;
}

// sema_expr.c:2019 (static)
<* Returns a null slice on error (c3c NULL). *>
fn Expr*[] sema_splat_arraylike_insert(SemaContext* context, Expr*[] args, Expr* arg, ArrayIndex len, ArrayIndex index, Decl*[]* macro_va_decl_ref, Decl*[]* evaluation_ref)
{
	if (len > int::max || index > int::max || len + index > int::max)
	{
		@sema_error_at(context, arg.loc, "Resulting splat would be too large");
		return {};
	}
	args = sema_prepare_splat_insert(args, (int)len, (int)index);
	if (sema_cast_const(arg))
	{
		for (int i = 0; i < (int)len; i++)
		{
			Expr* expr = expr_copy(arg);
			Expr* subscript = expr_new_expr(SUBSCRIPT, expr);
			subscript.subscript_expr.index.expr = exprid(expr_new_const_int(arg.loc, type_sz, (ulong)i));
			subscript.subscript_expr.expr = exprid(expr);
			args[i + index] = subscript;
		}
		return args;
	}
	if (context.call_env.kind != ENV_FUNCTION)
	{
		@sema_error_at(context, arg.loc, "Cannot splat a non-constant value in a global context.");
		return {};
	}
	Decl* temp = decl_new_generated_var(arg.type, LOCAL, arg.loc);
	assert(arg);
	temp.var_decl.init_expr = arg;
	Expr* subscript = expr_new_expr(SUBSCRIPT, arg);
	subscript.subscript_expr.index.expr = exprid(expr_new_const_int(arg.loc, type_sz, 0));
	subscript.subscript_expr.expr = exprid(expr_variable(temp));
	if (macro_va_decl_ref) @vec_add(macro_va_decl_ref, temp);
	args[index] = sema_splat_analyse_temp(context, temp, subscript, evaluation_ref);
	if (!args[index]) return {};
	for (int i = 1; i < len; i++)
	{
		subscript = expr_new_expr(SUBSCRIPT, arg);
		subscript.subscript_expr.index.expr = exprid(expr_new_const_int(arg.loc, type_sz, (ulong)i));
		subscript.subscript_expr.expr = exprid(expr_variable(temp));
		args[index + i] = subscript;
	}
	return args;
}

// sema_expr.c:2063 (static)
fn ArrayIndex sema_len_from_expr(Expr* expr)
{
	CanonicalType* type = expr.type.canonical;
	while (true)
	{
		switch (type.type_kind)
		{
			case OPTIONAL:
				type = type.optional.canonical;
				continue;
			case TYPEDEF:
			case CONSTSET:
				if (sema_type_has_subscript_overloads(type)) return -1;
				type = type_flatten(type);
				continue;
			case VECTOR:
			case SIMD_VECTOR:
			case ARRAY:
				return (ArrayIndex)type.array.len;
			case UNTYPEDLIST:
				return sema_len_from_const(expr);
			case SLICE:
				break;
			default:
				return -1;
		}
		break;
	}
	if (expr.expr_kind == IDENTIFIER && expr.ident_expr.decl_kind == VAR && expr.ident_expr.var_decl.kind == CONST) expr = copy_expr_single(expr);
	if (sema_cast_const(expr))
	{
		return sema_len_from_const(expr);
	}
	if (expr.expr_kind != SLICE) return -1;
	return range_const_len(&expr.slice_expr.range);
}

// sema_expr.c:2096 (static)
fn Decl* sema_find_splat_arg(Decl*[] params, String name)
{
	foreach (decl : params)
	{
		if (decl && decl.name.ptr == name.ptr) return decl;
	}
	return null;
}

// sema_expr.c:2112 (static)
fn SplatResult sema_splat_optional_argument(SemaContext* context, Expr* expr)
{
	Decl* macro_ = context.current_macro;
	Decl*[] macro_params;
	if (macro_)
	{
		macro_params = macro_.func_decl.signature.params;
	}
	else
	{
		if (context.call_env.kind != ENV_FUNCTION || !context.call_env.current_function.func_decl.in_macro)
		{
			return NONE;
		}
		macro_params = context.call_env.current_function.func_decl.lambda_ct_parameters;
	}
	Decl* candidate = null;
	switch (expr.expr_kind)
	{
		case UNRESOLVED_IDENTIFIER:
			if (expr.unresolved_ident_expr.path) break;
			candidate = sema_find_splat_arg(macro_params, expr.unresolved_ident_expr.ident);
		case HASH_IDENT:
			candidate = sema_find_splat_arg(macro_params, expr.hash_ident_expr.identifier);
		case CT_IDENT:
			candidate = sema_find_splat_arg(macro_params, expr.ct_ident_expr.identifier);
		default:
			return NONE;
	}
	if (!candidate) return NONE;
	if (!candidate.var_decl.no_init) return NONE;
	// We found it, it's a valid variable.
	Decl* local = sema_find_local(context, candidate.name);
	if (local && local.var_decl.kind == candidate.var_decl.kind && !decl_is_defaulted_var(local)) return ONE;
	// It's missing! Let's splat-zero
	return ZERO;
}

// sema_expr.c:2153 (static)
fn Type* sema_get_va_type(SemaContext* context, Expr* expr, Variadic variadic)
{
	if (variadic == RAW)
	{
		if (expr.resolve_status != DONE)
		{
			expr = copy_expr_single(expr);
			if (!sema_analyse_expr_rvalue(context, expr)) return poisoned_type;
		}
		return expr.type;
	}
	// c3c: assert(expr.expr_kind == MAKE_ANY); -- C assert, compiled out in c3c release builds
	return expr.make_any_expr.typeid_expr.const_expr.typeid_type;
}

// sema_expr.c:2168 (static)
fn Decl*[]* sema_splat_evaluation_ref(CalledDeclContext* callee)
{
	if (!callee.macro_decl) return null;
	return &callee.evaluations;
}

// sema_expr.c:2174 (static)
fn void sema_add_macro_evaluation(CalledDeclContext* callee, Decl* param)
{
	if (!callee.macro_decl || !param || param.var_decl.kind != PARAM) return;
	@vec_add(&callee.evaluations, param);
}

// sema_expr.c:2180 (static)
<*
 The c3c labels become: SPLAT_NORMAL a `splat_normal` flag, NO_MATCH_REF
 an inline `*no_match_ref = true; return false;`, CHECK_FORMAT (with its
 UNEXPECTED_END / TOO_FEW_ARGUMENTS labels) the `sema_call_check_format`
 helper below.
*>
fn bool sema_call_evaluate_arguments(SemaContext* context, CalledDeclContext* callee, Expr* call, bool* optional, bool* no_match_ref)
{
	// Check body arguments (for macro calls, or possibly broken
	if (!sema_call_check_invalid_body_arguments(context, call, callee)) return false;
	// Pick out all the arguments and parameters.
	Signature* sig = callee.signature;
	int vaarg_index = sig.vararg_index;
	Variadic variadic = sig.variadic;
	Decl*[] decl_params = callee.params;
	int format_index = (int)sig.attrs.format - 1;
	// If this is a type call, then we have an implicit first argument.
	if (callee.struct_var)
	{
		@vec_insert_first(&call.call_expr.arguments, callee.struct_var);
		call.call_expr.is_type_method = true;
		assert(!call.call_expr.is_pointer_call);
	}

	// Zero out all argument slots.
	int func_param_count = (int)decl_params.len;

	// We might have a typed variadic call e.g. foo(int, double...)
	// get that type.
	Type* variadic_type = null;
	Type* variadic_slot_type = null;
	if (variadic == TYPED || variadic == ANY)
	{
		// 7a. The parameter type is <type>[], so we get the <type>
		variadic_slot_type = decl_params[vaarg_index].type;
		assert(variadic_slot_type.type_kind == SLICE);
		variadic_type = variadic_slot_type.array.base;
	}

	Expr*[] args = call.call_expr.arguments;
	int num_args = (int)args.len;
	Decl*[] params = callee.params;

	assert(func_param_count < MAX_PARAMS);
	Expr*[] actual_args = {};
	for (int i = 0; i < func_param_count; i++)
	{
		@vec_add(&actual_args, null);
	}

	// 2. Loop through the parameters.
	bool has_named = false;
	bool vararg_evaluation_added = false;
	ArrayIndex last_index = -1;
	Expr* last_named_arg = null;
	Expr* last = null;
	bool has_vaarg_param = variadic != NONE && vaarg_index < func_param_count;
	ArrayIndex needed = (ArrayIndex)func_param_count - (callee.struct_var ? 1 : 0) - (has_vaarg_param ? 1 : 0);
	// Do we need to store decls separately?
	Decl*[]* macro_va_decl_ref_maybe = callee.macro_decl && variadic == RAW ? &callee.macro_va_decls : null;
	for (int i = 0; i < num_args; i++)
	{
		Expr* arg = args[i];
		if (i > 0) last = args[i - 1];
		assert(expr_ok(arg));
		if (arg.expr_kind == VASPLAT && context.current_macro)
		{
			Expr*[] new_args = sema_vasplat_insert(context, args, arg, i);
			if (!new_args.ptr) return false;
			args = new_args;
			i--;
			num_args = (int)args.len;
			continue;
		}
		if (arg.expr_kind == SPLAT)
		{
			Expr* inner = arg.inner_expr;
			switch (sema_splat_optional_argument(context, inner))
			{
				case ZERO:
					@vec_erase_at(&args, (usz)i);
					i--;
					num_args--;
					continue;
				case ONE:
					expr_replace(arg, inner);
					i--;
					continue;
				case NONE:
					break;
			}
			if (!sema_analyse_expr_rvalue(context, inner)) return false;
			*optional |= @is_optional(inner);

			// Let's try fit up a slice to the in the vaslot
			if (variadic_type && i == vaarg_index)
			{
				// Is it not the last and not a named argument, then we do a normal splat.
				bool splat_normal = i + 1 < num_args && !expr_is_named_param(args[i + 1]);
				if (!splat_normal)
				{
					// Convert an array/vector to an address of an array.
					Expr* inner_new = inner;
					if (type_is_arraylike(inner.type))
					{
						inner_new = copy_expr_single(inner);
						if (sema_cast_const(inner_new) && expr_is_const_initializer(inner_new))
						{
							ConstInitializer* initializer = inner_new.const_expr.initializer;
							inner_new.const_expr.const_kind = SLICE;
							inner_new.const_expr.slice_init = initializer;
							inner_new.type = type_get_slice(inner_new.type.array.base);
						}
						else
						{
							expr_insert_addr(inner_new);
						}
					}
					if (cast_implicit_silent(context, inner_new, variadic_slot_type, false))
					{
						if (inner != inner_new) expr_replace(inner, inner_new);
						// We splat it in the right spot!
						call.call_expr.va_is_splat = true;
						call.call_expr.vasplat = inner;
						sema_add_macro_evaluation(callee, decl_params[vaarg_index]);
						vararg_evaluation_added = true;
						continue;
					}
				}
			}
			// SPLAT_NORMAL:
			Type* flat = type_flatten(inner.type);
			bool is_struct = false;
			switch (flat.type_kind)
			{
				case VECTOR:
				case SIMD_VECTOR:
				case ARRAY:
				case SLICE:
				case UNTYPEDLIST:
					break;
				case STRUCT:
					is_struct = true;
				default:
					return @sema_error_at(context, arg.loc, "An argument of type %s cannot be splatted.",
									  type_quoted_error_string(inner.type));
			}
			ArrayIndex len = is_struct ? 0 : sema_len_from_expr(inner);
			if (!is_struct && len == -1) return @sema_error_at(context, arg.loc, "Only a value with a length known at compile time can be splatted, but if you slice it to a constant length it will work (e.g. '...val[:2]').");
			if (!is_struct && len == 0 && !expr_is_const(arg))
			{
				return @sema_error_at(context, arg.loc, "A non-constant zero size splat cannot be used with raw varargs.");
			}
			Decl*[]* evaluation_ref = sema_splat_evaluation_ref(callee);
			Expr*[] new_args = is_struct
				? sema_splat_struct_insert(context, args, inner, flat.decl, i, evaluation_ref)
				: sema_splat_arraylike_insert(context, args, inner, len, i, i >= vaarg_index ? macro_va_decl_ref_maybe : null, evaluation_ref);
			if (!new_args.ptr) return false;
			args = new_args;
			i--;
			num_args = (int)args.len;
			continue;
		}
		// Fold $eval
		if (arg.expr_kind == NAMED_EVAL_ARGUMENT)
		{
			Expr* eval_name = arg.eval_named_argument_expr.name;
			Expr* name = eval_name.inner_expr;
			if (!sema_analyse_ct_expr(context, name)) return false;
			if (!expr_is_const_string(name)) return @sema_error_at(context, eval_name.loc, "'$eval' expects a constant string as the argument.");
			String name_string = (String)name.const_expr.bytes.ptr[:name.const_expr.bytes.len];
			if (!str_is_identifier(name_string)) return @sema_error_at(context, eval_name.loc, "'$eval' expects a parameter name as the argument.");
			TokenType type = IDENT;
			name_string = symtab_add(name_string, &type);
			if (type != IDENT) return @sema_error_at(context, eval_name.loc, "'$eval' expected a parameter name as the argument.");
			arg.expr_kind = NAMED_ARGUMENT;
			Expr* val = arg.eval_named_argument_expr.value;
			arg.named_argument_expr.name = name_string;
			arg.named_argument_expr.name_span = name.loc;
			arg.named_argument_expr.value = val;
		}
		if (arg.expr_kind == NAMED_ARGUMENT)
		{
			// Find the location of the parameter.
			int index = sema_call_find_index_of_named_parameter(context, params, arg);

			// If it's not found then this is an error. Let's not invoke nomatch
			if (index < 0) return false;

			// We have named parameters, that will add some restrictions.
			has_named = true;

			Decl* param = params[index];
			// 8d. We might actually be finding the typed vararg at the end,
			//     this is an error.
			if (param.var_decl.vararg)
			{
				// c3c passes an unused param->name argument here.
				@sema_error_at(context, arg.loc, "Vararg parameters may not be named parameters, "
												"use normal parameters instead.");
				return sema_func_error_note(callee.definition);
			}

			// 8e. We might have already set this parameter, that is not allowed.
			if (actual_args[index] && actual_args[index].expr_kind != DEFAULT_ARG && !param.var_decl.defaulted)
			{
				return @sema_error_at(context, arg.loc, "The parameter '%s' was already set.", param.name);
			}

			if (last_index > index)
			{
				@sema_error_at(context, arg.loc, "Named arguments must always be declared in order.");
				@sema_note_prev_at(last_named_arg.loc, "Place it before this argument.");
				return false;
			}
			if (last_index == -1) last_index = (ArrayIndex)i - 1;
			for (int j = (int)last_index + 1; j < index; j++)
			{
				if (j == vaarg_index)
				{
					if (!vararg_evaluation_added) sema_add_macro_evaluation(callee, params[j]);
					vararg_evaluation_added = true;
					continue;
				}
				if (!sema_set_default_argument(context, callee, call,
											   params[j], no_match_ref,
											   &actual_args[j],
											   optional))
				{
					return false;
				}
				sema_add_macro_evaluation(callee, params[j]);
			}
			last_index = index;
			last_named_arg = arg;

			actual_args[index] = arg.named_argument_expr.value;
			if (actual_args[index].expr_kind == SPLAT)
			{
				Expr* inner = actual_args[index].inner_expr;
				switch (sema_splat_optional_argument(context, inner))
				{
					case ZERO:
						if (!sema_set_default_argument(context, callee, call,
													   params[index], no_match_ref,
													   &actual_args[index],
													   optional))
						{
							return false;
						}
						sema_add_macro_evaluation(callee, params[index]);
						continue;
					case ONE:
						expr_replace(actual_args[index], inner);
					case NONE:
						break;
				}
			}
			if (!sema_analyse_parameter(context, actual_args[index], param, callee.definition, optional, no_match_ref,
										callee.macro_decl, false)) return false;
			sema_add_macro_evaluation(callee, param);
			continue;
		}
		if (call.call_expr.va_is_splat)
		{
			if (no_match_ref)
			{
				*no_match_ref = true;
				return false;
			}
			@sema_error_at(context, arg.loc,
						   "This looks like an argument after a splatted variable, which "
						   "isn't allowed. Did you add too many arguments?");
			return sema_func_error_note(callee.definition);
		}
		if (has_named)
		{
			@sema_error_at(context, args[i - 1].loc,
						   "Named arguments must be placed after positional arguments.");
			return sema_func_error_note(callee.definition);
		}

		// 11. We might have a typed variadic argument.
		if (variadic == NONE && i >= func_param_count)
		{
			// 15. We have too many parameters...
			if (no_match_ref)
			{
				*no_match_ref = true;
				return false;
			}
			@sema_error_at(context, arg.loc,
						   "This argument would exceed the number of parameters, "
						   "did you add too many arguments?");
			return sema_func_error_note(callee.definition);
		}

		// 10. If we exceed the function parameter count (remember we reduced this by one
		//     in the case of typed vararg) we're now in a variadic list.
		if (variadic != NONE && i >= vaarg_index)
		{
			// c3c reads params[vaarg_index] past the end for raw C varargs (it is
			// ignored there, as only macros record evaluations): pass null instead.
			if (!vararg_evaluation_added) sema_add_macro_evaluation(callee, vaarg_index < params.len ? params[vaarg_index] : null);
			vararg_evaluation_added = true;
			switch (variadic)
			{
				case RAW:
					// Only analyse for non-macro
					if (!callee.macro_decl)
					{
						if (!sema_analyse_expr_rvalue(context, arg)) return false;
						switch (sema_resolve_storage_type(context, arg.type))
						{
							case STORAGE_ERROR:
								return false;
							case STORAGE_NORMAL:
								break;
							default:
								return @sema_error_at(context, arg.loc, "A value of type %s cannot be passed as a raw variadic argument.",
													  type_quoted_error_string(arg.type));
						}
						cast_promote_vararg(arg);
					}
					// Set the argument at the location.
					*optional |= @is_optional(arg);
				case ANY:
					if (!sema_analyse_expr_rvalue(context, arg)) return false;
					Type* type = arg.type;
					switch (sema_resolve_storage_type(context, arg.type))
					{
						case STORAGE_ERROR:
							return false;
						case STORAGE_NORMAL:
							break;
						default:
							return @sema_error_at(context, arg.loc, "A value of type %s cannot be passed as a variadic argument.",
												  type_quoted_error_string(type));
					}
					expr_insert_addr(arg);
					nextcase TYPED;
				case TYPED:
					if (!sema_analyse_expr_rhs(context, variadic_type, arg, true, no_match_ref, false)) return false;
					*optional |= @is_optional(arg);
				case NONE:
					unreachable();
			}
			@vec_add(&call.call_expr.varargs, arg);
			continue;
		}
		if (!sema_analyse_parameter(context, arg, params[i], callee.definition, optional, no_match_ref, callee.macro_decl, callee.struct_var && i == 0)) return false;
		sema_add_macro_evaluation(callee, params[i]);
		actual_args[i] = arg;
	}
	// c3c tests the pointer, which `vasplat` (same union) also sets.
	if (call.call_expr.varargs.ptr && variadic != RAW)
	{
		Decl* param = params[vaarg_index];
		if (param.var_decl.kind == PARAM_CT)
		{
			if (call.call_expr.va_is_splat)
			{
				if (!expr_is_runtime_const(call.call_expr.vasplat))
				{
					@sema_error_at(context, call.call_expr.vasplat.loc, "The splat must be a compile time value.");
					@sema_note_prev_at(callee.definition.loc, "The definition was here.");
					return false;
				}
			}
			else
			{
				foreach (ct_param : call.call_expr.varargs)
				{
					if (!expr_is_runtime_const(ct_param))
					{
						@sema_error_at(context, ct_param.loc, "All vaargs must be constant values.");
						@sema_note_prev_at(callee.definition.loc, "The definition was here.");
						return false;
					}
				}
			}
		}
	}
	if (num_args) last = args[num_args - 1];
	call.call_expr.arguments = args;
	// 17. Set default values.
	for (int i = 0; i < func_param_count; i++)
	{
		// 17a. Assigned a value - skip
		if (actual_args[i]) continue;
		if (i == vaarg_index && variadic != NONE)
		{
			if (!vararg_evaluation_added) sema_add_macro_evaluation(callee, params[i]);
			vararg_evaluation_added = true;
			continue;
		}

		if (!sema_set_default_argument(context, callee, call, params[i], no_match_ref, &actual_args[i],
									   optional)) return false;
		sema_add_macro_evaluation(callee, params[i]);
	}
	for (int i = 0; i < func_param_count; i++)
	{
		if (i == vaarg_index) continue;
		if (actual_args[i]) continue;
		Decl* param = params[i];
		if (param.var_decl.no_init) continue; // Macro empty args
		// Argument missing, that's bad.
		if (no_match_ref)
		{
			*no_match_ref = true;
			return false;
		}
		if (!has_named || !param.name.ptr)
		{
			int missing = 1;
			for (int j = i + 1; j < func_param_count; j++) if (!actual_args[j] && (j != vaarg_index || !has_vaarg_param)) missing++;
			int implicit_args = callee.struct_var ? 1 : 0;
			if (callee.params.len == (usz)(1 + implicit_args))
			{
				if (param.type)
				{
					@sema_error_at(context, call.loc,
								   "This call expected a parameter of type %s, did you forget it?",
								   type_quoted_error_string(param.type));
					return sema_func_error_note(callee.definition);
				}
				@sema_error_at(context, call.loc, "This call expected a parameter, did you forget it?");
				return sema_func_error_note(callee.definition);
			}
			if (variadic != NONE && i > vaarg_index && last)
			{
				@print_error_after(sourcelocptr(last.loc), "Expected '%s: ...' after this argument.", param.name);
				@sema_note_prev_at(callee.definition.loc, "The definition was here.");
				return false;
			}
			if (num_args == implicit_args)
			{
				if (variadic != NONE)
				{
					@sema_error_at(context, call.loc, "'%s' expects at least %d parameter%s, but none were provided.",
								   callee.name, missing, missing == 1 ? "" : "s");
					return sema_func_error_note(callee.definition);
				}
				if (missing != needed)
				{
					@sema_error_at(context, call.loc, "'%s' expects %d-%d parameters, but none were provided.",
								   callee.name, missing, needed);
					return sema_func_error_note(callee.definition);
				}
				@sema_error_at(context, call.loc, "'%s' expects %d parameter(s), but none were provided.",
							   callee.name, needed);
				return sema_func_error_note(callee.definition);
			}
			if (!last) last = args[0];
			int more_needed = (int)((ArrayIndex)func_param_count - i) - (has_vaarg_param && i < vaarg_index ? 1 : 0);
			if (missing != more_needed)
			{
				@sema_error_at(context, last.loc,
							   "%d-%d additional arguments were expected after this one, did you forget them?",
							   missing, more_needed);
				return sema_func_error_note(callee.definition);
			}
			@sema_error_at(context, last.loc,
						   "%d more %s expected after this one, did you forget %s?",
						   more_needed, more_needed == 1 ? "argument was" : "arguments were", more_needed == 1 ? "it" : "them");
			return sema_func_error_note(callee.definition);
		}
		@sema_error_at(context, call.loc, "The parameter '%s' must be set, did you forget it?", param.name);
		return sema_func_error_note(callee.definition);
	}
	call.call_expr.arguments = actual_args;
	if (format_index >= 0) return sema_call_check_format(context, callee, call, actual_args, format_index, variadic);
	return true;
}

<* The CHECK_FORMAT tail of sema_call_evaluate_arguments. *>
fn bool sema_call_check_format(SemaContext* context, CalledDeclContext* callee, Expr* call, Expr*[] actual_args, int format_index, Variadic variadic) @local
{
	// Check
	Expr* expr = actual_args[format_index];
	if (!sema_cast_const(expr) || call.call_expr.va_is_splat) return true;
	if (!expr_is_const_string(expr))
	{
		return @sema_error_at(context, expr.loc, "The format string must be a constant string.");
	}
	// c3c: assert(expr_is_const_string(expr)); -- C assert, compiled out in c3c release builds
	char* data = expr.const_expr.bytes.ptr;
	usz len = (usz)expr.const_expr.bytes.len;
	if (len > int::max) return @sema_error_at(context, expr.loc, "String too long");
	int idx = 0;
	Expr*[] vaargs = call.call_expr.varargs;
	int vacount = (int)vaargs.len;
	for (int i = 0; i < (int)len; i++)
	{
		if (data[i] != '%') continue;
		i++;
		char c = data[i];
		// NEXT_FLAG:
		bool is_percent = false;
		while (true)
		{
			switch (c)
			{
				case '-':
				case '+':
				case '0':
				case '#':
				case ' ':
					if (++i == (int)len) return format_unexpected_end(context, callee, call);
					c = data[i];
					continue;
				case '%':
					is_percent = true;
				default:
					break;
			}
			break;
		}
		if (is_percent) continue;
		if (idx == vacount) return format_too_few_arguments(context, callee, call);
		expr = vaargs[idx];
		if (!expr) return format_too_few_arguments(context, callee, call);
		Type* type_original = sema_get_va_type(context, expr, variadic);
		if (!type_ok(type_original)) return false;
		Type* type = type_flatten(type_original);

		// Possible variable width
		if (c == '*')
		{
			if (!type_is_integer(type))
			{
				return @sema_error_at(context, vaargs[idx].loc, "Expected an integer for the format width.");
			}
			if (++i == (int)len) return format_unexpected_end(context, callee, call);
			c = data[i];
			if (++idx == vacount) return format_too_few_arguments(context, callee, call);
			expr = vaargs[idx];
			if (!expr) return format_too_few_arguments(context, callee, call);
			type_original = sema_get_va_type(context, expr, variadic);
			type = type_flatten(type_original);
			if (!type_ok(type)) return false;
		}
		else
		{
			while (char_is_digit(c))
			{
				if (++i == (int)len) return format_unexpected_end(context, callee, call);
				c = data[i];
			}
		}
		if (c == '.')
		{
			if (++i == (int)len) return format_unexpected_end(context, callee, call);
			c = data[i];
			if (c == '*')
			{
				if (!type_is_integer(type))
				{
					return @sema_error_at(context, vaargs[idx].loc, "Expected an integer for the format width, not %s.", type_quoted_error_string(type_original));
				}
				if (++i == (int)len) return format_unexpected_end(context, callee, call);
				c = data[i];
				if (++idx == vacount) return format_too_few_arguments(context, callee, call);
				expr = vaargs[idx];
				if (!expr) return format_too_few_arguments(context, callee, call);
				type_original = sema_get_va_type(context, expr, variadic);
				type = type_flatten(type);
				if (!type_ok(type)) return false;
			}
			else
			{
				if (!char_is_digit(c))
				{
					return @sema_error_at(context, actual_args[format_index].loc, "Expected a format width or '*' in the format string but got another character");
				}
				while (char_is_digit(c))
				{
					if (++i == (int)len) return format_unexpected_end(context, callee, call);
					c = data[i];
				}
			}
		}
		switch (c)
		{
			case 's':
				break;
			case 'c':
				if (!type_is_integer(type))
				{
					return @sema_error_at(context, vaargs[idx].loc, "Expected an integer here, but the type was %s.", type_quoted_error_string(type_original));
				}
			case 'd':
			case 'X':
			case 'x':
			case 'B':
			case 'b':
			case 'o':
			case 'a':
			case 'A':
			case 'F':
			case 'f':
			case 'e':
			case 'E':
			case 'g':
			case 'G':
				if (!type_is_number_or_bool(type) && !type_is_pointer_type(type))
				{
					if (type.type_kind == ENUM)
					{
						// c3c passes an unused type argument here.
						return @sema_error_at(context, vaargs[idx].loc, "An enum cannot directly be turned into a number. Use '.ordinal' to convert it to its value.");
					}
					return @sema_error_at(context, vaargs[idx].loc, "Expected a number here, but it was a value of type %s.", type_quoted_error_string(type_original));
				}
			case 'p':
				if (!type_is_pointer_type(type) && !type_is_integer(type))
				{
					return @sema_error_at(context, vaargs[idx].loc, "Expected a pointer here, but it was a value of type %s.", type_quoted_error_string(type_original));
				}
			case 'H':
			case 'h':
				if (!type_flat_is_valid_for_arg_h(type))
				{
					return @sema_error_at(context, vaargs[idx].loc, "Expected a pointer, char array or slice here, but the type was %s.", type_quoted_error_string(type_original));
				}
			case 'u':
				return @sema_error_at(context, actual_args[format_index].loc, "Format strings do not support '%%u'. if you want to print an unsigned number, just use '%%d'.");
			case ' ':
				return @sema_error_at(context, actual_args[format_index].loc, "The format string contains a '%%' that isn't followed by a format declaration, if you want to use '%%' in a format string you need to escape it by typing '%%%%'.");
			default:
				if (c > 31 && c < 127)
				{
					return @sema_error_at(context, actual_args[format_index].loc, "Unexpected escape sequence '%%%c' in format declaration.", c);
				}
				return @sema_error_at(context, actual_args[format_index].loc, "Unexpected character in format declaration.");
		}
		// NEXT:
		idx++;
	}
	if (idx < vacount)
	{
		@sema_error_at(context, call.loc, "Too many arguments were provided for the formatting string.");
		return sema_func_error_note(callee.definition);
	}
	return true;
}

<* sema_call_evaluate_arguments `UNEXPECTED_END:` label. *>
fn bool format_unexpected_end(SemaContext* context, CalledDeclContext* callee, Expr* call) @local
{
	@sema_error_at(context, call.loc, "Unexpected end of formatting string mid format declaration.");
	return sema_func_error_note(callee.definition);
}

<* sema_call_evaluate_arguments `TOO_FEW_ARGUMENTS:` label. *>
fn bool format_too_few_arguments(SemaContext* context, CalledDeclContext* callee, Expr* call) @local
{
	@sema_error_at(context, call.loc, "Too few arguments were provided for the formatting string.");
	return sema_func_error_note(callee.definition);
}

// sema_expr.c:2792 (static)
fn bool sema_call_check_contract_param_match(SemaContext* context, Decl* param, Expr* expr)
{
	if (param.var_decl.not_null && expr_is_const_pointer(expr) && !expr.const_expr.ptr)
	{
		return @sema_error_at(context, expr.loc, "You may not pass null to the '&' parameter.");
	}

	if (param.var_decl.out_param && expr_refers_to_const(expr))
	{
		// CONST_OUT_ERROR:
		return @sema_error_at(context, expr.loc, "A const parameter may not be passed into a function or macro as an 'out' or 'inout' argument.");
	}

	if (expr.expr_kind != IDENTIFIER) return true;
	Decl* ident = expr.ident_expr;
	if (ident.decl_kind != VAR) return true;
	if (ident.var_decl.out_param && !ident.var_decl.in_param && param.var_decl.in_param)
	{
		return @sema_error_at(context, expr.loc, "An 'out' parameter may not be passed into a function or macro as an 'in' or 'inout' argument.");
	}
	if (ident.var_decl.in_param && !ident.var_decl.out_param && param.var_decl.out_param)
	{
		return @sema_error_at(context, expr.loc, "An 'in' parameter may not be passed into a function or macro as an 'out' or 'inout' argument.");
	}
	return true;
}

// sema_expr.c:2817 (static)
fn bool sema_has_require(DeclId doc_id)
{
	if (!doc_id) return false;
	return declptr(doc_id).contracts_decl.requires.len != 0;
}

// sema_expr.c:2823 (static)
fn bool sema_call_analyse_func_invocation(SemaContext* context, Decl* decl, Type* type, Expr* expr, Expr* struct_var, bool optional, String name, bool* no_match_ref)
{
	Signature* sig = type.function.signature;
	CalledDeclContext callee = {
		.macro_decl = false,
		.definition = decl,
		.call_location = expr.loc,
		.name = name,
		.block_parameter = {},
		.struct_var = struct_var,
		.params = sig.params,
		.signature = sig,
	};
	if (context.call_env.pure && !sig.attrs.is_pure && !expr.call_expr.attr_pure)
	{
		@sema_error_at(context, expr.loc, "Only '@pure' functions may be called, you can override this with an attribute.");
		return false;
	}

	if (sig.attrs.noreturn)
	{
		expr.call_expr.no_return = true;
		if (!context.call_env.in_no_eval) set_jump_end(context, expr.loc);
	}

	if (!sema_call_evaluate_arguments(context, &callee, expr, &optional, no_match_ref)) return false;
	if (expr.call_expr.is_dynamic_dispatch)
	{
		Expr* any_val = expr.call_expr.arguments[0];
		assert(any_val.expr_kind == PTR_ACCESS);
		*any_val = *(any_val.inner_expr);
	}
	expr.call_expr.function_contracts = 0;
	DeclId contract_id = decl.docs;

	if (sema_has_require(contract_id))
	{
		switch (sema_call_analyse_func_contracts(context, &callee, decl, sig, expr, contract_id))
		{
			case BOOL_ERR: return false;
			default: break;
		}
	}
	// SKIP_CONTRACTS:
	expr.call_expr.has_optional_arg = optional;

	Type* rtype = typeget(type.function.signature.rtype);
	if (!type_is_void(rtype))
	{
		bool is_optional_return = type_is_optional(rtype);
		expr.call_expr.is_optional_return = is_optional_return;
		expr.call_expr.must_use = sig.attrs.nodiscard || (is_optional_return && !sig.attrs.maydiscard);
	}
	expr.type = type_add_optional(rtype, optional);
	return true;
}

int contract_depth;

<*
 The contract part of sema_call_analyse_func_invocation (between the
 `!sema_has_require` test and SKIP_CONTRACTS). BOOL_ERR is c3c's
 `return false`; anything else continues at SKIP_CONTRACTS. Like c3c the
 temp context is not destroyed on the `!is_safe` and recursion paths.
 c3c's function-local `static int contract_depth` is the global above.
*>
fn BoolErr sema_call_analyse_func_contracts(SemaContext* context, CalledDeclContext* callee, Decl* decl, Signature* sig, Expr* expr, DeclId contract_id) @local
{
	bool is_safe = safe_mode_enabled();
	SemaContext temp_context;
	if (!sema_expr_setup_call_analysis(context, callee, &temp_context,
										expr, null, null, {}, {},
										null, null))
	{
		// END_CONTRACT:
		sema_context_destroy(&temp_context);
		return BOOL_ERR;
	}
	SourceLocId[MAX_PARAMS] arg_positions = {};
	foreach (i, param : sig.params)
	{
		if (!param || !param.name.ptr) continue;
		Expr* arg = expr.call_expr.arguments[i];
		if (arg) arg_positions[i] = arg.loc;
		if (!arg)
		{
			// c3c: assert(i == sig.vararg_index); -- C assert, compiled out in c3c release builds
			if (expr.call_expr.va_is_splat)
			{
				arg = expr.call_expr.vasplat;
			}
			else
			{
				Expr*[] exprs = expr.call_expr.varargs;
				Expr* init_list = expr_new_expr(INITIALIZER_LIST, expr);
				init_list.initializer_list = exprs;
				init_list.type = param.type;
				Expr* compound_init = expr_new_expr(COMPOUND_LITERAL, expr);
				compound_init.expr_compound_literal.initializer = init_list;
				compound_init.expr_compound_literal.type_info = type_info_new_base(param.type, param.loc);
				if (!sema_analyse_expr_rvalue(context, compound_init))
				{
					sema_context_destroy(&temp_context);
					return BOOL_ERR;
				}
				arg = compound_init;
				if (is_safe) expr.call_expr.va_is_splat = true;
			}
		}
		Decl* new_param = decl_new_generated_var(arg.type, LOCAL, expr.loc);
		new_param.name = param.name;
		new_param.unit = context.unit;
		new_param.var_decl.copy_const = true;
		Expr* new_arg = expr_generate_decl(new_param, arg);
		new_arg.resolve_status = DONE;
		new_arg.type = arg.type;
		if (!sema_add_local(&temp_context, new_param))
		{
			sema_context_destroy(&temp_context);
			return BOOL_ERR;
		}
		if (@is_optional(new_param))
		{
			sema_unwrap_var(&temp_context, new_param);
		}
		if (i == sig.vararg_index)
		{
			if (is_safe) expr.call_expr.vasplat = new_arg;
			continue;
		}
		if (is_safe) expr.call_expr.arguments[i] = new_arg;
	}
	AstId assert_first = 0;
	AstId* next = &assert_first;
	Decl* contracts = declptr(contract_id);
	copy_begin();
	Expr*[] requires = copy_exprlist_macro(contracts.contracts_decl.requires);
	Expr*[] ensures = copy_exprlist_macro(contracts.contracts_decl.ensures);
	copy_end();

	// We need to track contracts in case we have recursive addition of preconditions.
	if (contract_depth > MAX_CONTRACT_DEPTH)
	{
		if (!@sema_warn_at(context, decl.loc, compiler.build.warnings.recursive_contracts, "Contract resolution exceeded the maximum depth for this function; remaining contracts will be ignored.")) return BOOL_ERR;
	}
	else
	{
		contract_depth++;
		bool contract_success = sema_analyse_contracts(&temp_context, contracts, requires, ensures, &next, expr.loc, null, &arg_positions[0]);
		contract_depth--;
		if (!contract_success) return BOOL_ERR;
	}

	if (!is_safe) return BOOL_TRUE;

	expr.call_expr.function_contracts = assert_first;

	// END_CONTRACT:
	sema_context_destroy(&temp_context);
	return BOOL_TRUE;
}

// sema_expr.c:2962 (static)
fn bool sema_expr_analyse_var_call(SemaContext* context, Expr* expr, Expr* var_, Type* func_ptr_type, bool optional, bool* no_match_ref)
{
	func_ptr_type = type_flat_distinct_inline(func_ptr_type);
	if (func_ptr_type.type_kind != FUNC_PTR)
	{
		if (no_match_ref)
		{
			*no_match_ref = true;
			return false;
		}
		return @sema_error_at(context, expr.loc, "Only macros, functions and function pointers may be invoked, this is of type '%s'.",
							  type_to_error_string(func_ptr_type));
	}
	if (sema_cast_const(var_) && expr_is_const_pointer(var_) && var_.const_expr.ptr == 0)
	{
		return @sema_error_at(context, var_.loc, "You cannot call a null function pointer.");
	}
	Type* pointee = func_ptr_type.pointer;
	expr.call_expr.is_pointer_call = true;
	Decl* func_decl = pointee.function.decl;
	// This declaration might not have been resolved, so in that case do it.
	if (func_decl.resolve_status != DONE && !sema_analyse_decl(context, func_decl)) return false;
	return sema_call_analyse_func_invocation(context, func_decl, pointee, expr, null, optional,
											 func_ptr_type.pointer.name,
											 no_match_ref);
}

// sema_expr.c:2990 (static)
<* Unify returns in a macro or expression block. *>
fn Type* context_unify_returns(SemaContext* context)
{
	bool all_returns_need_casts = false;
	Type* common_type = null;

	// 1. Loop through the returns.
	bool optional = false;
	int returns = (int)context.block_returns.len;
	if (!returns) return type_void;
	for (int i = 0; i < returns; i++)
	{
		Ast* return_stmt = context.block_returns[i];
		Type* rtype;
		if (!return_stmt)
		{
			optional = true;
			rtype = type_wildcard;
		}
		else
		{
			Expr* ret_expr = return_stmt.return_stmt.expr;
			rtype = ret_expr ? ret_expr.type : type_void;
			if (type_is_optional(rtype))
			{
				optional = true;
				rtype = type_no_optional(rtype);
			}
		}
		// 2. If we have no common type, set to the return type.
		if (!common_type)
		{
			common_type = rtype;
			continue;
		}

		// 3. Same type -> we're done.
		if (common_type == rtype || (type_is_void(common_type) && rtype == type_wildcard)) continue;

		// 4. Find the max of the old and new.
		Type* max = type_find_max_type(context, common_type, rtype, null, null);
		if (max == poisoned_type) return null;
		// 5. No match -> error.
		if (!max)
		{
			assert(return_stmt);
			@sema_error_at(context, return_stmt.loc, "Cannot find a common parent type of %s and %s",
						   type_quoted_error_string(rtype), type_quoted_error_string(common_type));
			Ast* prev = context.block_returns[i - 1];
			assert(prev);
			@sema_note_prev_at(prev.loc, "The previous return was here.");
			return null;
		}

		// 6. Set the new max, mark as needing a cast on all returns.
		common_type = max;
		all_returns_need_casts = true;
	}

	assert(common_type);

	// 7. Insert casts.
	if (all_returns_need_casts)
	{
		assert(common_type != type_wildcard);
		foreach (return_stmt : context.block_returns)
		{
			if (!return_stmt) continue;
			Expr* ret_expr = return_stmt.return_stmt.expr;
			if (!ret_expr)
			{
				if (type_is_void(common_type)) continue;
				context_unify_returns(context);
			}
			// 8. All casts should work.
			if (!cast_implicit(context, ret_expr, common_type, false))
			{
				return null;
			}
		}
	}

	return type_add_optional(common_type, optional);
}

// sema_expr.c:3074 (static)
fn bool sema_expr_analyse_func_call(SemaContext* context, Expr* expr, Decl* decl, Expr* struct_var, bool optional, bool* no_match_ref)
{
	expr.call_expr.is_pointer_call = false;
	if (decl.func_decl.attr_test)
	{
		@sema_error_at(context, expr.loc, "@test functions may not be directly called.");
		return false;
	}

	if (decl.func_decl.attr_benchmark)
	{
		@sema_error_at(context, expr.loc, "@benchmark functions may not be directly called.");
		return false;
	}

	sema_display_deprecated_warning_on_use(context, decl, expr.loc);

	// Tag dynamic dispatch.
	if (struct_var && decl.func_decl.attr_interface_method) expr.call_expr.is_dynamic_dispatch = true;

	return sema_call_analyse_func_invocation(context, decl,
											 decl.type,
											 expr,
											 struct_var,
											 optional,
											 decl.name, no_match_ref);
}

// sema_expr.c:3103 (static)
fn bool sema_expr_setup_call_analysis(SemaContext* context, CalledDeclContext* callee, SemaContext* macro_context, Expr* call_expr, Type* rtype, Ast* yield_body, Decl*[] yield_params, Decl*[] params, BlockExit** block_exit_ref, InliningSpan* span_ref)
{
	Decl* decl = callee.definition;
	sema_context_init(macro_context, decl.unit);
	macro_context.generic_instance = declptrzero(decl.instance_id);
	macro_context.compilation_unit = context.unit;
	macro_context.macro_call_depth = context.macro_call_depth + 1;
	macro_context.call_env = context.call_env;
	macro_context.expected_block_type = rtype;
	if (span_ref)
	{
		Decl* instance = macro_context.generic_instance != context.generic_instance ? macro_context.generic_instance : null;
		*span_ref = { call_expr.loc, context.inlined_at, instance };
	}
	else
	{
		span_ref = context.inlined_at;
	}
	macro_context.inlined_at = span_ref;
	macro_context.current_macro = callee.macro_decl ? decl : null;
	macro_context.yield_body = yield_body;
	macro_context.yield_params = yield_params;
	macro_context.yield_context = context;
	if (!call_expr.call_expr.va_is_splat)
	{
		foreach (expr : call_expr.call_expr.varargs)
		{
			if (expr.resolve_status == DONE) continue;
			Expr* expr_inner = expr_copy(expr);
			expr.expr_kind = OTHER_CONTEXT;
			expr.expr_other_context.inner = expr_inner;
			expr.expr_other_context.context = context;
		}
	}
	macro_context.macro_has_vaargs = callee.macro_decl && callee.signature.variadic == RAW;
	macro_context.macro_varargs = macro_context.macro_has_vaargs ? call_expr.call_expr.varargs : {};
	macro_context.original_module = context.original_module ? context.original_module : context.compilation_unit.mod;
	macro_context.macro_params = params;

	macro_context.block_exit_ref = block_exit_ref;

	context_change_scope_with_flags(macro_context, SCOPE_MACRO, call_expr.loc);
	macro_context.block_return_defer = macro_context.active_scope.defer_last;

	return true;
}

// sema_expr.c:3156 (static)
fn void sema_update_link_from_macro(SemaContext* context, ResolvedAttrData* attributes)
{
	assert(attributes && attributes.links.len);
	if (context.call_env.kind != ENV_FUNCTION && context.call_env.kind != ENV_FUNCTION_STATIC) return;
	Decl* func = context.call_env.current_function;

	assert(func.resolved_attributes);

	if (!func.attrs_resolved)
	{
		decl_create_resolved_attributes(func);
	}
	String[] updated = func.attrs_resolved.links;
	foreach (link : attributes.links)
	{
		@vec_add(&updated, link);
	}
	func.attrs_resolved.links = updated;
}

// sema_expr.c:3176 (static)
fn bool sema_analyse_macro_body_params(SemaContext* context, Decl* decl, Expr* call_expr, Decl*[] body_params, bool* no_match_ref)
{
	int body_params_count = (int)body_params.len;
	Decl*[] macro_body_params = decl.func_decl.body_param ? declptr(decl.func_decl.body_param).body_params : {};
	int expected_body_params = (int)macro_body_params.len;

	// Too many parameters
	if (expected_body_params > body_params_count)
	{
		if (no_match_ref) return macro_no_match_ref(no_match_ref);
		return @sema_error_at(context, call_expr.loc, "Not enough parameters for the macro body, expected %d.", expected_body_params);
	}

	// Too few parameters
	if (expected_body_params < body_params_count)
	{
		if (no_match_ref) return macro_no_match_ref(no_match_ref);
		return @sema_error_at(context, call_expr.loc, "Too many parameters for the macro body, expected %d.", expected_body_params);
	}

	for (int j = 0; j < expected_body_params; j++)
	{
		Decl* body_param = macro_body_params[j];
		assert(body_param.resolve_status == DONE);
		Decl* body_arg = body_params[j];

		// Check type mismatch
		VarDeclKind kind_of_expected = body_param.var_decl.kind;
		if (kind_of_expected != body_arg.var_decl.kind)
		{
			switch (kind_of_expected)
			{
				case PARAM_CT_TYPE:
					@sema_error_at(context, body_arg.loc, "Expected a type argument.");
					return sema_func_error_note(decl);
				case PARAM_EXPR:
					@sema_error_at(context, body_arg.loc, "Expected an expression argument.");
					return sema_func_error_note(decl);
				case PARAM_CT:
					@sema_error_at(context, body_arg.loc, "Expected a compile time ('$') argument.");
					return sema_func_error_note(decl);
				case PARAM:
					@sema_error_at(context, body_arg.loc, "Expected a regular argument.");
					return sema_func_error_note(decl);
				default:
					unreachable();
			}
		}

		// Check that the argument doesn't have default values
		if (body_arg.var_decl.init_expr)
		{
			return @sema_error_at(context, body_arg.var_decl.init_expr.loc, "Macro body parameters should never have default values.");
		}

		// No type checking
		switch (kind_of_expected)
		{
			case PARAM_CT_TYPE:
				continue;
			case PARAM_CT:
			case PARAM_EXPR:
			case PARAM:
				// Optional typing
				break;
			default:
				unreachable();
		}

		// Check type
		TypeInfo* expected_type_info = vartype(body_param);
		TypeInfo* type_info = vartype(body_arg);

		// Check the body argument type
		if (type_info && !sema_resolve_type_info(context, type_info, RESOLVE_TYPE_DEFAULT)) return false;

		Type* type = type_info ? type_info.type : null;

		// Infer the type if needed
		if (!type && expected_type_info) type = expected_type_info.type;

		// Check that types match, no conversion, just look at the canonical type.
		if (type && expected_type_info && type.canonical != expected_type_info.type.canonical)
		{
			if (no_match_ref) return macro_no_match_ref(no_match_ref);
			return @sema_error_at(context, type_info.loc, "This parameter should be %s but was %s",
								  type_quoted_error_string(expected_type_info.type),
								  type_quoted_error_string(type));
		}

		// Assign the resulting type to the argument
		body_arg.type = type;

		if (type)
		{
			switch (sema_resolve_storage_type(context, type))
			{
				case STORAGE_ERROR:
					return false;
				case STORAGE_NORMAL:
					if (!sema_set_alloca_alignment(context, type, &body_arg.alignment)) return false;
				default:
					break;
			}
		}
	}
	return true;
}

<* Handle failure in `$defined` (c3c NO_MATCH_REF label). *>
fn bool macro_no_match_ref(bool* no_match_ref) @local
{
	*no_match_ref = true;
	return false;
}

// sema_expr.c:3287 (static)
fn bool sema_analyse_macro_params(SemaContext* context, SemaContext* macro_context, Expr* call_expr, CalledDeclContext* callee, Decl*[] params, AstId** next_ref)
{
	foreach (idx, param : params)
	{
		// Skip raw vararg
		if (!param)
		{
			if (callee.macro_va_decls.len)
			{
				foreach (d : callee.macro_va_decls)
				{
					sema_add_local(macro_context, d);
				}
			}
			continue;
		}
		if (!sema_add_local(macro_context, param)) return false;
		if (param.var_decl.no_init && param.var_decl.defaulted) continue;
		if (param.var_decl.init_expr)
		{
			Type* param_type = param.type;
			if (param_type && param.var_decl.type_info && (param.var_decl.out_param || param.var_decl.not_null))
			{
				param_type = type_flatten(param_type);
				if (param_type.type_kind != POINTER && param_type.type_kind != SLICE && param_type.type_kind != INTERFACE && param_type.type_kind != ANY)
				{
					return @sema_error_at(context, param.var_decl.init_expr.loc, "Expected a pointer, slice or interface value for '%s'.", param.name);
				}
			}
			if (param.var_decl.not_null && param_type && (param_type.type_kind == POINTER || param_type.type_kind == SLICE || param_type.type_kind == INTERFACE || param_type.type_kind == ANY))
			{
				Expr* expr = expr_variable(param);
				Expr* binary = expr_new_expr(BINARY, expr);
				binary.binary_expr.left = exprid(expr);
				binary.binary_expr.right = exprid(expr_new_const_null(expr.loc, type_voidptr));
				binary.binary_expr.operator = NE;
				if (!sema_analyse_expr_rhs(context, type_bool, binary, false, null, false)) return false;
				PanicFunction panic_function = callee.struct_var && idx == 0 ? FN_NULL_METHOD : FN_REF_ARG;
				String string = panic_fn_desc[panic_function.ordinal].format;
				if (expr_is_const_bool(binary) && !binary.const_expr.b)
				{
					@sema_error_at(context, param.var_decl.init_expr.loc, "%s", string);
					return false;
				}

				Ast* assert_ = new_ast(ASSERT_STMT, param.var_decl.init_expr.loc);
				assert_.assert_stmt.is_ensure = true;
				assert_.assert_stmt.expr = exprid(binary);
				Expr* comment_expr = expr_new_const_string(expr.loc, string);
				assert_.assert_stmt.message = exprid(comment_expr);
				assert_.assert_stmt.panic_function = panic_function;
				ast_append(next_ref, assert_);
			}
		}
	}
	return true;
}

// sema_expr.c:3345
<*
 c3c labels: EXIT_FAIL is `macro_call_exit_fail`, the NOT_CT / EXIT
 split is the `folded` flag set by `macro_call_fold_ct`.
*>
fn bool sema_expr_analyse_macro_call(SemaContext* context, Expr* call_expr, Expr* struct_var, Decl* decl, bool call_var_optional, bool* no_match_ref)
{
	bool is_always_const = decl.func_decl.signature.attrs.always_const;

	ResolvedAttrData* attributes = decl_get_resolved_attributes(decl);

	// Handle @link
	if (attributes && attributes.links.len) sema_update_link_from_macro(context, attributes);

	bool is_outer = call_expr.call_expr.is_outer_call;
	assert(decl.decl_kind == MACRO);

	if (context.macro_call_depth > MAX_MACRO_RECURSION_DEPTH)
	{
		decl.decl_kind = POISONED;
		return @sema_error_at(context, call_expr.loc, "Failure evaluating macro, max call depth reached, "
			"possibly due non-terminating macro recursion.");
	}

	sema_display_deprecated_warning_on_use(context, decl, call_expr.loc);

	// Being macro copy
	copy_begin();
	Decl*[] params = copy_decl_list_macro(decl.func_decl.signature.params);
	Ast* body = copy_ast_macro(astptr(decl.func_decl.body));
	Decl* contracts = declptrzero(decl.docs);
	Expr*[] requires = contracts ? contracts.contracts_decl.requires : {};
	Expr*[] ensures = contracts ? contracts.contracts_decl.ensures : {};
	if (requires.len) requires = copy_exprlist_macro(requires);
	if (ensures.len) ensures = copy_exprlist_macro(ensures);
	Signature* sig = &decl.func_decl.signature;
	copy_end();

	// Create caller info
	CalledDeclContext callee = {
		.macro_decl = true,
		.call_location = call_expr.loc,
		.name = decl.name,
		.params = params,
		.definition = decl,
		.block_parameter = decl.func_decl.body_param ? declptr(decl.func_decl.body_param).name : {},
		.signature = sig,
		.struct_var = struct_var
	};

	// Is any argument an optional
	bool has_optional_arg = call_var_optional;
	if (!sema_call_evaluate_arguments(context, &callee, call_expr, &has_optional_arg, no_match_ref)) return false;

	int vararg_index = sig.vararg_index;
	Expr*[] args = call_expr.call_expr.arguments;
	SourceLocId[MAX_PARAMS] arg_positions = {};
	foreach (i, param : params)
	{
		if (i == vararg_index)
		{
			if (!param) continue;
			// Splat? That's the simple case.
			if (call_expr.call_expr.va_is_splat)
			{
				args[i] = call_expr.call_expr.vasplat;
				if (!sema_analyse_expr_rvalue(context, args[i])) return false;
			}
			else
			{
				Expr*[] exprs = call_expr.call_expr.varargs;
				Expr* literal = expr_new(COMPOUND_LITERAL, exprs.len ? exprs[0].loc : param.loc);
				Expr* initializer_list = expr_new_expr(INITIALIZER_LIST, literal);
				initializer_list.initializer_list = exprs;
				literal.expr_compound_literal.type_info = vartype(param);
				literal.expr_compound_literal.initializer = initializer_list;
				args[i] = literal;
				if (!sema_analyse_expr_rvalue(context, literal)) return false;
			}
		}
		param.var_decl.init_expr = args[i];
		if (!args[i]) continue;
		arg_positions[i] = args[i].loc;
		// Lazy arguments doesn't affect optional arg.
		if (param.var_decl.kind == PARAM_EXPR) continue;
		has_optional_arg = has_optional_arg || @is_optional(args[i]);
	}

	Expr* macro_body = exprptrzero(call_expr.call_expr.macro_body);
	Decl*[] body_params = macro_body ? macro_body.macro_body_expr.body_arguments : {};
	if (!sema_analyse_macro_body_params(context, decl, call_expr, body_params, no_match_ref)) return false;

	DynamicScope old_scope = context.active_scope;
	// Create a scope, since the macro itself will not.
	context_change_scope_with_flags(context, SCOPE_NONE, call_expr.loc);
	SemaContext macro_context;

	Type* rtype = typeget(sig.rtype);
	bool optional_return = rtype && type_is_optional(rtype);
	bool may_be_optional = !rtype || optional_return;
	if (rtype) rtype = type_no_optional(rtype);

	BlockExit** block_exit_ref = (BlockExit**)calloc_arena(uptr::size);

	InliningSpan span;
	if (!sema_expr_setup_call_analysis(context, &callee, &macro_context, call_expr, rtype,
		macro_body ? macro_body.macro_body_expr.body : null, body_params, params, block_exit_ref, &span))
	{
		return macro_call_exit_fail(context, old_scope, &macro_context);
	}

	AstId assert_first = 0;
	AstId* next = &assert_first;

	if (!sema_analyse_macro_params(context, &macro_context, call_expr, &callee, params, &next)) return macro_call_exit_fail(context, old_scope, &macro_context);

	// Handle contracts
	bool has_ensures = false;
	if (!sema_analyse_contracts(&macro_context, contracts, requires, ensures, &next, call_expr.loc, &has_ensures, &arg_positions[0])) return false;
	macro_context.macro_has_ensures = has_ensures;
	sema_append_contract_asserts(assert_first, body);

	// Analyse the macro itself
	if (!sema_analyse_statement(&macro_context, body)) return macro_call_exit_fail(context, old_scope, &macro_context);

	// Analyse return
	assert(macro_context.active_scope.depth == 1);
	bool implicit_void_return = !macro_context.active_scope.end_jump.active;
	params = macro_context.macro_params;
	bool is_no_return = sig.attrs.noreturn;

	if (!macro_context.block_returns.len)
	{
		if (rtype && rtype != type_void && !macro_context.active_scope.end_jump.active)
		{
			@sema_error_at(context, decl.loc,
						   "Missing return in macro that should evaluate to %s.",
						   type_quoted_error_string(rtype));
			return macro_call_exit_fail(context, old_scope, &macro_context);
		}
	}
	else if (is_no_return)
	{
		@sema_error_at(context, macro_context.block_returns[0].loc, "Return used despite macro being marked '@noreturn'.");
		return macro_call_exit_fail(context, old_scope, &macro_context);
	}

	if (rtype)
	{
		bool inferred_len = type_len_is_inferred(rtype);
		foreach (return_stmt : macro_context.block_returns)
		{
			if (!return_stmt)
			{
				assert(may_be_optional);
				continue;
			}
			Expr* ret_expr = return_stmt.return_stmt.expr;
			if (!ret_expr)
			{
				if (type_is_void(rtype)) continue;
				@sema_error_at(context, return_stmt.loc, "Expected returning a value of type %s.", type_quoted_error_string(rtype));
				return macro_call_exit_fail(context, old_scope, &macro_context);
			}
			Type* type = ret_expr.type;
			if (inferred_len)
			{
				Type* flattened = type_flatten(type);
				if (flattened.type_kind == ARRAY && rtype.type_kind == INFERRED_ARRAY)
				{
					rtype = type_get_array(rtype.array.base, flattened.array.len);
					inferred_len = false;
				}
				else if (flattened.type_kind == VECTOR && rtype.type_kind == INFERRED_VECTOR)
				{
					rtype = type_get_vector(rtype.array.base, VECTOR, (int)flattened.array.len);
					inferred_len = false;
				}
			}
			bool success = cast_implicit_silent(context, ret_expr, rtype, false);
			if (inferred_len || (!may_be_optional && @is_optional(ret_expr)) || !success)
			{
				@sema_error_at(context, ret_expr.loc, "Expected %s, not %s.", type_quoted_error_string(rtype),
							   type_quoted_error_string(type));
				return macro_call_exit_fail(context, old_scope, &macro_context);
			}
			ret_expr.type = type_add_optional(ret_expr.type, optional_return);
		}
	}
	else
	{
		rtype = context_unify_returns(&macro_context);
		if (!rtype) return macro_call_exit_fail(context, old_scope, &macro_context);
		optional_return = type_is_optional(rtype);
	}

	// Handle the implicit return.
	if (implicit_void_return)
	{
		if (type_is_wildcard(rtype))
		{
			optional_return = optional_return || type_is_optional(rtype);
			rtype = type_void;
		}
		else
		{
			Type* flat = type_flatten(rtype);
			if (flat != type_void)
			{
				return @sema_error_at(context, decl.loc, "Macro implicitly returns 'void' at the end, which cannot be cast to the inferred %s.",
									  type_quoted_error_string(rtype));
			}
		}
	}

	call_expr.type = type_add_optional(rtype, optional_return || has_optional_arg);
	if (is_no_return && type_is_void(rtype))
	{
		call_expr.type = type_wildcard;
	}

	assert(call_expr.type);
	bool must_use = false;
	if (rtype != type_void || optional_return)
	{
		must_use = sig.attrs.nodiscard || (optional_return && !sig.attrs.maydiscard);
	}
	int returns_found = (int)macro_context.block_returns.len;
	// We may have zero normal macro returns but the active scope still has a "jump end".
	// In this case it is triggered by the @body()
	if (!returns_found && macro_context.active_scope.end_jump.active)
	{
		is_no_return = true;
	}
	bool folded = false;
	if ((returns_found == 1 && !implicit_void_return) || (returns_found == 0 && implicit_void_return))
	{
		folded = macro_call_fold_ct(&callee, &macro_context, call_expr, params, body, returns_found, optional_return);
	}
	if (!folded)
	{
		// NOT_CT:
		call_expr.expr_kind = MACRO_BLOCK;
		call_expr.macro_block = {
			.had_optional_arg = has_optional_arg,
			.is_must_use = must_use,
			.is_optional_return = optional_return,
			.first_stmt = body.compound_stmt.first_stmt,
			.macro_decl = decl,
		};
		if (callee.evaluations.len)
		{
			foreach (idx, evaluation_decl : callee.evaluations)
			{
				if (evaluation_decl.var_decl.kind != PARAM) continue;
				foreach (j, original_param : callee.params)
				{
					if (evaluation_decl != original_param) continue;
					callee.evaluations[idx] = params[j];
					break;
				}
			}
			call_expr.macro_block.arguments = callee.evaluations;
		}
		call_expr.macro_block.block_exit = block_exit_ref;
		call_expr.macro_block.is_noreturn = is_no_return;
	}
	// EXIT:
	if (is_outer && !type_is_void(call_expr.type))
	{
		return @sema_error_at(context, call_expr.loc, "The macro itself returns %s here, but only 'void' is permitted "
							  "when a macro with trailing body is used directly after '=>'.",
							  type_quoted_error_string(rtype));
	}
	assert(context.active_scope.defer_last == context.active_scope.defer_start);
	context.active_scope = old_scope;
	if (is_no_return)
	{
		set_jump_end(context, call_expr.loc);
	}
	sema_context_destroy(&macro_context);
	call_expr.resolve_status = DONE;
	if (!expr_is_runtime_const(call_expr))
	{
		if (is_always_const)
		{
			@sema_error_at(context, call_expr.loc, "The macro failed to fold to a constant value, despite being '@const'.");
			@sema_note_prev_at(decl.loc, "The macro was declared here.");
			return false;
		}
		if (call_expr.type == type_untypedlist)
		{
			@sema_error_at(context, call_expr.loc, "The macro returns an untyped list, but the macro did not evaluate to a constant. The macro needs to explicitly cast the return value to the expected type.");
			@sema_note_prev_at(decl.loc, "The macro was declared here.");
			return false;
		}
	}
	return true;
}

<* sema_expr_analyse_macro_call: the compile time folding attempt; true means `goto EXIT`, false `goto NOT_CT`. *>
fn bool macro_call_fold_ct(CalledDeclContext* callee, SemaContext* macro_context, Expr* call_expr, Decl*[] params, Ast* body, int returns_found, bool optional_return) @local
{
	if (callee.evaluations.len) return false;
	Ast* ret = returns_found ? macro_context.block_returns[0] : null;
	Expr* result = ret ? ret.return_stmt.expr : null;
	if (result && !expr_is_runtime_const(result)) return false;
	if (optional_return && (!result || !@is_optional(result))) return false;
	foreach (param : params)
	{
		// Skip raw vararg
		if (!param) continue;
		switch (param.var_decl.kind)
		{
			case PARAM_CT:
			case PARAM_CT_TYPE:
			case PARAM_EXPR:
				break;
			default:
				return false;
		}
	}
	if (!ast_is_compile_time(body)) return false;
	if (!result)
	{
		expr_rewrite_const_null(call_expr, type_void);
		return true;
	}
	expr_replace(call_expr, result);
	return true;
}

<* sema_expr_analyse_macro_call `EXIT_FAIL:` label. *>
fn bool macro_call_exit_fail(SemaContext* context, DynamicScope old_scope, SemaContext* macro_context) @local
{
	context.active_scope = old_scope;
	sema_context_destroy(macro_context);
	return scope_pop_error(context, old_scope);
}

// sema_expr.c:3669 (static)
fn bool sema_call_analyse_body_expansion(SemaContext* macro_context, Expr* call, bool* no_match_ref)
{
	Decl* macro_ = macro_context.current_macro;
	assert(macro_ && macro_.func_decl.body_param);
	Decl* body_decl = declptr(macro_.func_decl.body_param);
	ExprCall* call_expr = &call.call_expr;
	Expr* macro_body = exprptrzero(call_expr.macro_body);
	if (macro_body && macro_body.macro_body_expr.body_arguments.len)
	{
		@print_error_at(call.loc, "Nested expansion is not possible.");
		return false;
	}
	if (call_expr.va_is_splat)
	{
		@print_error_at(call.loc, "Expanding parameters is not allowed for macro invocations.");
	}
	// Theoretically we could support named arguments, but that's unnecessary.
	int expressions = (int)call_expr.arguments.len;
	Decl*[] body_parameters = body_decl.body_params;
	if (expressions != body_parameters.len)
	{
		@print_error_at(call.loc, "Expected %d parameter(s) to %s.", body_parameters.len, body_decl.name);
		return false;
	}
	Expr*[] args = call_expr.arguments;

	Decl*[] params = macro_context.yield_params;

	bool has_optional_arg = false;

	// Evaluate the expressions.
	for (int i = 0; i < expressions; i++)
	{
		Decl* param = params[i];
		Expr* expr = args[i];
		if (!sema_analyse_parameter(macro_context, expr, param, body_decl, &has_optional_arg, no_match_ref, true, false))
		{
			return false;
		}
		if (has_optional_arg)
		{
			@sema_error_at(macro_context, expr.loc, "Optional arguments are not permitted in a body invocation.");
			return false;
		}
		switch (param.var_decl.kind)
		{
			case PARAM_EXPR:
			case PARAM_CT:
			case PARAM_CT_TYPE:
				param.var_decl.init_expr = args[i];
				args[i] = null;
			default:
				break;
		}
	}

	AstId macro_defer = macro_context.active_scope.defer_last;
	Ast* first_defer = null;
	SemaContext* context = macro_context.yield_context;
	Expr* func_expr = exprptr(call_expr.function);
	assert(func_expr.expr_kind == MACRO_BODY_EXPANSION);
	expr_replace(call, func_expr);
	call.body_expansion_expr.values = args;
	call.body_expansion_expr.declarations = macro_context.yield_params;
	AstId last_defer = context.active_scope.defer_last;
	DynamicScope old_scope = scope_start(context, call.loc);
	int ct_context = sema_context_push_ct_stack(context);
	if (macro_defer)
	{
		Ast* macro_defer_ast = astptr(macro_defer);
		first_defer = macro_defer_ast;
		while (first_defer.defer_stmt.prev_defer)
		{
			first_defer = astptr(first_defer.defer_stmt.prev_defer);
		}
		first_defer.defer_stmt.prev_defer = context.active_scope.defer_last;
		context.active_scope.defer_last = macro_defer;
	}
	foreach (param : params)
	{
		if (!sema_add_local(context, param))
		{
			sema_context_pop_ct_stack(context, ct_context);
			return scope_pop_error(context, old_scope);
		}
	}
	Ast* ast = copy_ast_single(macro_context.yield_body);
	call.body_expansion_expr.first_stmt = astid(ast);
	bool body_ok;
	Ast* macro_in_defer = macro_context.active_scope.in_defer;
	if (macro_in_defer)
	{
		context.active_scope.in_defer = macro_in_defer;
		BreakContState old_bc = push_breakcont(context, null);
		NextJumpState old_next = push_next(context, null, null);
		body_ok = sema_analyse_statement(context, ast);
		pop_next(context, old_next);
		pop_breakcont(context, old_bc);
	}
	else
	{
		body_ok = sema_analyse_statement(context, ast);
	}
	if (!body_ok)
	{
		sema_context_pop_ct_stack(context, ct_context);
		return scope_pop_error(context, old_scope);
	}
	assert(ast.ast_kind == COMPOUND_STMT);
	if (context.active_scope.end_jump.active)
	{
		macro_context.active_scope.end_jump = context.active_scope.end_jump;
	}
	if (first_defer)
	{
		first_defer.defer_stmt.prev_defer = 0;
		context.active_scope.defer_last = last_defer;
	}
	sema_context_pop_ct_stack(context, ct_context);
	if (!scope_end_check(context, old_scope)) return false;

	return true;
}

// sema_expr.c:3798
<* Conversion MyEnum.FOO -> MyEnum.ordinal, will change the type. *>
fn void sema_expr_convert_enum_to_int(Expr* expr)
{
	assert(type_flatten(expr.type).type_kind == ENUM);
	Type* underlying_type = type_base(expr.type);
	if (sema_cast_const(expr))
	{
		assert(expr_is_const_enum(expr));
		expr_rewrite_const_int(expr, underlying_type, (ulong)expr.const_expr.enum_val.enum_constant.inner_ordinal);
	}
	if (expr.expr_kind == ENUM_FROM_ORD)
	{
		*expr = *expr.inner_expr;
	}
	expr.type = type_add_optional(underlying_type, @is_optional(expr));
}

// sema_expr.c:3814
fn bool sema_expr_analyse_general_call(SemaContext* context, Expr* expr, Decl* decl, Expr* struct_var, bool optional, bool* no_match_ref)
{
	expr.call_expr.is_type_method = struct_var != null;
	if (decl == null)
	{
		Expr* var_ = exprptr(expr.call_expr.function);
		return sema_expr_analyse_var_call(context, expr, var_, type_flatten(var_.type),
										  optional, no_match_ref);
	}
	if (!sema_analyse_decl(context, decl)) return false;
	switch (decl.decl_kind)
	{
		case MACRO:
			expr.call_expr.func_ref = declid(decl);
			expr.call_expr.is_func_ref = true;
			return sema_expr_analyse_macro_call(context, expr, struct_var, decl, optional, no_match_ref);
		case VAR:
		{
			assert(struct_var == null);
			Expr* var_ = exprptr(expr.call_expr.function);
			assert(var_);
			return sema_expr_analyse_var_call(context, expr, var_, type_no_optional(decl.type).canonical,
											  optional || @is_optional(decl), no_match_ref);
		}
		case FUNC:
			if (decl.func_decl.attr_interface_method && !struct_var)
			{
				return @sema_error_at(context, expr.loc, "An interface method must be called as a method, it can't be used as a free function.");
			}
			expr.call_expr.func_ref = declid(decl);
			expr.call_expr.is_func_ref = true;
			return sema_expr_analyse_func_call(context, expr, decl, struct_var, optional, no_match_ref);
		case POISONED:
			return false;
		default:
			if (no_match_ref)
			{
				*no_match_ref = true;
				return false;
			}
			return @sema_error_at(context, expr.loc, "This expression cannot be called.");
	}
}

// sema_expr.c:3860 (static)
fn bool sema_expr_analyse_from_ordinal(SemaContext* context, Expr* expr, Expr* tag)
{
	Expr*[] args = expr.call_expr.arguments;
	int arg_count = (int)args.len;
	Decl* decl = tag.type_call_expr.type;
	if (arg_count != 1) return @sema_error_at(context, expr.loc, "Expected a single integer argument to 'from_ordinal'.");
	Expr* key = args[0];
	if (!sema_analyse_expr_rvalue(context, key)) return false;
	if (!type_is_integer(key.type))
	{
		return @sema_error_at(context, key.loc, "The ordinal should be an integer.");
	}
	bool is_const_enum = decl.decl_kind == CONSTSET;
	if (sema_cast_const(key))
	{
		Int to_convert = key.const_expr.ixx;
		if (int_is_neg(to_convert))
		{
			return @sema_error_at(context, key.loc, "'from_ordinal' doesn't work on negative numbers.");
		}
		int max_enums = (int)decl.enums.values.len;
		Int max = { .i = (uint128)max_enums, .type = U32 };
		if (int_comp(to_convert, max, GE))
		{
			return @sema_error_at(context, key.loc, "The ordinal '%s' exceeds the max ordinal '%d'.", int_to_str(to_convert, 10, false), max_enums - 1);
		}
		ulong index = (ulong)to_convert.i;
		if (is_const_enum)
		{
			Expr* val = decl.enums.values[index].enum_constant.value;
			*expr = *copy_expr_single(val);
			return true;
		}
		expr.expr_kind = CONST;
		expr.const_expr = {
			.enum_val = decl.enums.values[index],
			.const_kind = ENUM
		};
		expr.type = decl.type;
		return true;
	}
	if (is_const_enum)
	{
		return @sema_error_at(context, key.loc, ".from_ordinal on constsets is only valid with compile time constant arguments, maybe you want to use enums instead?");
	}
	expr.expr_kind = ENUM_FROM_ORD;
	expr.inner_expr = key;
	expr.type = decl.type;
	return true;
}

// sema_expr.c:3910 (static)
fn bool sema_expr_analyse_lookup(SemaContext* context, Expr* expr, Expr* tag)
{
	Expr*[] args = expr.call_expr.arguments;
	int arg_count = (int)args.len;
	Decl* decl = tag.type_call_expr.type;
	if (arg_count != 2) return @sema_error_at(context, expr.loc, "'lookup_field' requires two arguments: the name of the field and the value to search for.");
	Expr* key = args[1];
	if (!sema_analyse_expr_rvalue(context, key)) return false;
	ArrayIndex index = -1;

	Expr* ident = sema_expr_resolve_access_child(context, args[0], null, null);
	if (!ident) return false;
	if (ident.expr_kind != UNRESOLVED_IDENTIFIER) return @sema_error_at(context, expr.loc, "This is not a field.");
	String child = ident.unresolved_ident_expr.ident;
	foreach (i, param : decl.enums.parameters)
	{
		if (param.name.ptr && param.name.ptr == child.ptr)
		{
			index = (ArrayIndex)i;
			break;
		}
	}
	if (index < 0)
	{
		return @sema_error_at(context, args[0].loc, "There is no associated value of %s with the name '%s'.", type_quoted_error_string(decl.type), child);
	}
	// FOUND:
	Decl* match = decl.enums.parameters[index];
	if (!cast_implicit(context, key, match.type, false)) return false;
	Decl* d = sema_find_symbol(context, kw_at_enum_lookup);
	if (!d || d.unit.mod.name.module_name.ptr != kw_std__core__runtime.ptr)
	{
		return @sema_error_at(context, expr.loc, "Missing main enum lookup macro '%s' in '%s'.", kw_at_enum_lookup, kw_std__core__runtime);
	}
	Expr* type = expr_new_expr(TYPEINFO, expr);
	type.type_expr = type_info_new_base(decl.type, tag.loc);
	expr.expr_kind = CALL;
	while (args.len < 3) @vec_add(&args, null);
	args[0] = type;
	args[1] = expr_new_const_string(expr.loc, match.name);
	args[2] = key;
	Expr* call = expr_new_expr(UNRESOLVED_IDENTIFIER, expr);
	ModulePath* new_path = (ModulePath*)calloc_arena(ModulePath::size);
	new_path.module_name = kw_std__core__runtime;
	new_path.loc = expr.loc;
	new_path.len = (uint)kw_std__core__runtime.len;
	call.unresolved_ident_expr = { .ident = kw_at_enum_lookup, .path = new_path, .is_const = false };
	ExprCall call_expr = { .arguments = args, .function = exprid(call) };
	expr.call_expr = call_expr;
	expr.resolve_status = NOT_DONE;
	return sema_analyse_expr_rvalue(context, expr);
}

// sema_expr.c:3960 (static)
fn bool sema_expr_analyse_is_generic(SemaContext* context, Expr* expr, Expr* tag)
{
	Expr*[] args = expr.call_expr.arguments;
	int arg_count = (int)args.len;
	Decl* decl = tag.type_call_expr.type;
	if (arg_count != 1) return @sema_error_at(context, expr.loc, "'is_generic' requires an argument.");
	Expr* type_expr = args[0];
	if (type_expr.expr_kind != TYPEINFO)
	{
		return @sema_error_at(context, type_expr.loc, "'is_generic' requires a generic type name.");
	}
	TypeInfo* info = type_expr.type_expr;
	if (info.kind != INFO_IDENTIFIER || info.optional || info.subtype != TYPE_COMPRESSED_NONE || info.resolve_status == DONE)
	{
		return @sema_error_at(context, type_expr.loc, "'is_generic' requires a generic type name.");
	}
	bool match = false;
	Decl* inf = sema_resolve_generic_symbol(context, info.unresolved.name, info.unresolved.path, type_expr.loc);
	if (!inf) return false;
	// The c3c NO_MATCH gotos are the nested ifs.
	if (decl && decl.is_templated)
	{
		Decl* generic = declptr(inf.generic_id);
		Decl* instance = declptr(decl.instance_id);
		if (decl.unit.mod == inf.unit.mod && inf.decl_kind == decl.decl_kind && generic.generic_decl.id == instance.instance_decl.id)
		{
			// VERY hacky solution, but saves storing the parent.
			usz len = inf.name.len;
			if (decl.name.len >= len && decl.name[:len] == inf.name)
			{
				// c3c reads decl->name[len]; names are NUL terminated.
				match = decl.name.ptr[len] == '{';
			}
		}
	}
	// NO_MATCH:
	expr_rewrite_const_bool(expr, type_bool, match);
	return true;
}

// sema_expr.c:3994 (static)
fn bool sema_expr_analyse_typecall(SemaContext* context, Expr* expr)
{
	Expr* tag = exprptr(expr.call_expr.function);
	if (!sema_expand_vasplat_exprs(context, &expr.call_expr.arguments, null)) return false;
	foreach (arg : expr.call_expr.arguments)
	{
		if (expr_is_named_param(arg)) return @sema_error_at(context, arg.loc, "Named arguments are not allowed in builtin calls.");
	}
	Decl* decl = tag.type_call_expr.type;
	if (decl && !sema_analyse_decl(context, decl)) return false;
	switch (tag.type_call_expr.property)
	{
		case PROPERTY_FROM_ORDINAL:
			return sema_expr_analyse_from_ordinal(context, expr, tag);
		case PROPERTY_LOOKUP_FIELD:
			return sema_expr_analyse_lookup(context, expr, tag);
		case PROPERTY_IS_GENERIC:
			return sema_expr_analyse_is_generic(context, expr, tag);
		default:
			break;
	}
	Expr*[] args = expr.call_expr.arguments;
	int arg_count = (int)args.len;
	bool is_has = tag.type_call_expr.property == PROPERTY_HAS_TAG;
	String name = is_has ? "has_tag" : "get_tag";
	if (arg_count != 1) return @sema_error_at(context, expr.loc, "Expected a single string argument to '%s'.", name);
	Expr* key = args[0];
	if (!sema_analyse_expr_rvalue(context, key)) return false;
	if (!sema_cast_const(key) || !expr_is_const_string(key))
	{
		return @sema_error_at(context, key.loc, "The tag name should be a string constant.");
	}
	String tagname = (String)key.const_expr.bytes.ptr[:key.const_expr.bytes.len];
	Expr* value = null;
	if (decl)
	{
		assert(decl.resolved_attributes);
		ResolvedAttrData* attrs = decl.attrs_resolved;
		if (attrs && attrs.tags.len)
		{
			foreach (attr : attrs.tags)
			{
				ExprConstBytes* bytes = &attr.exprs[0].const_expr.bytes;
				if ((String)bytes.ptr[:bytes.len] == tagname) value = attr.exprs[1];
			}
		}
	}
	if (value)
	{
		if (is_has)
		{
			expr_rewrite_const_bool(expr, type_bool, true);
			return true;
		}
		expr_replace(expr, copy_expr_single(value));
		return true;
	}
	// NOT_FOUND:
	if (is_has)
	{
		expr_rewrite_const_bool(expr, type_bool, false);
		return true;
	}
	return @sema_error_at(context, expr.loc, "The tag '%s' is not defined, always check with '.has_tag(...)'.", tagname);
}

// sema_expr.c:4053 (static)
fn bool sema_call_may_not_have_attributes(SemaContext* context, Expr* expr)
{
	// c3c tests attr_force_inline all three times.
	if (expr.call_expr.attr_force_inline)
	{
		return @sema_error_at(context, expr.loc, "'@inline' is not allowed here.");
	}
	if (expr.call_expr.attr_force_inline)
	{
		return @sema_error_at(context, expr.loc, "'@noinline' is not allowed here.");
	}
	if (expr.call_expr.attr_force_inline)
	{
		return @sema_error_at(context, expr.loc, "'@pure' is not allowed here.");
	}
	return true;
}

// sema_expr.c:4070 (static)
fn bool sema_analyse_member_in_type(SemaContext* context, Decl* decl, Expr* inner, TypeKind* target_kind, ArrayIndex* index_ref)
{
	Type* type = type_flatten(inner.type);
	Decl*[] members;
	switch ((*target_kind = type.type_kind))
	{
		case BITSTRUCT:
		case STRUCT:
		case UNION:
			members = type.decl.strukt.members;
		case ENUM:
			members = type.decl.enums.parameters;
		default:
			return @sema_error_at(context, inner.loc, "The member does not belong to the type %s.", type_quoted_error_string(inner.type));
	}
	ArrayIndex index = -1;
	foreach (i, member : members)
	{
		if (member == decl)
		{
			*index_ref = index = (ArrayIndex)i;
			break;
		}
	}
	if (index == -1)
	{
		return @sema_error_at(context, inner.loc, "The member does not belong to the type %s.", type_quoted_error_string(inner.type));
	}
	return true;
}

// sema_expr.c:4102 (static)
fn bool sema_analyse_member_get_set_common(SemaContext* context, Decl* decl, Expr* inner, TypeKind* target_kind, ArrayIndex* index_ref)
{
	if (!sema_analyse_expr_rvalue(context, inner)) return false;
	return sema_analyse_member_in_type(context, decl, inner, target_kind, index_ref);
}

// sema_expr.c:4108 (static)
fn bool sema_call_analyse_member_set(SemaContext* context, Expr* expr)
{
	if (expr.call_expr.arguments.len != 2)
	{
		return @sema_error_at(context, expr.loc, "Expected two arguments to '.set'.");
	}
	if (!sema_call_may_not_have_attributes(context, expr)) return false;
	Expr* get = exprptr(expr.call_expr.function);
	Decl* decl = get.member_get_expr;
	Expr* inner = expr.call_expr.arguments[0];
	TypeKind target_kind;
	ArrayIndex index;
	if (!sema_analyse_member_get_set_common(context, decl, inner, &target_kind, &index)) return false;
	Expr* arg = expr.call_expr.arguments[1];
	if (target_kind == ENUM)
	{
		return @sema_error_at(context, arg.loc, "Enum associated values cannot be set.");
	}
	Expr* access = expr_new_expr(target_kind == BITSTRUCT ? ExprKind.BITACCESS : ExprKind.ACCESS_RESOLVED, expr);
	access.access_resolved_expr = { .parent = inner, .ref = decl };
	access.type = type_add_optional(decl.type, @is_optional(inner));
	access.resolve_status = DONE;
	expr.expr_kind = BINARY;
	expr.resolve_status = RUNNING;
	expr.binary_expr = { .left = exprid(access), .right = exprid(arg), .operator = ASSIGN };
	return sema_expr_analyse_binary(context, null, expr, null);
}

// sema_expr.c:4136 (static)
fn bool sema_call_analyse_member_get(SemaContext* context, Expr* expr)
{
	if (expr.call_expr.arguments.len != 1)
	{
		return @sema_error_at(context, expr.loc, "Expected a single argument to '.get'.");
	}
	if (!sema_call_may_not_have_attributes(context, expr)) return false;
	Expr* get = exprptr(expr.call_expr.function);
	Decl* decl = get.member_get_expr;
	Expr* inner = expr.call_expr.arguments[0];
	TypeKind target_kind;
	ArrayIndex index;
	if (!sema_analyse_member_get_set_common(context, decl, inner, &target_kind, &index)) return false;
	// Constant fold the get
	if (target_kind == ENUM && sema_cast_const(inner) && expr_is_const_enum(inner))
	{
		Decl* enum_val = inner.const_expr.enum_val;
		expr_replace(expr, copy_expr_single(enum_val.enum_constant.associated[index]));
		return true;
	}
	expr.expr_kind = target_kind == BITSTRUCT ? ExprKind.BITACCESS : ExprKind.ACCESS_RESOLVED;
	expr.access_resolved_expr = { .parent = inner, .ref = decl };
	expr.type = type_add_optional(decl.type, @is_optional(inner));
	return true;
}

// sema_expr.c:4162 (static)
fn bool sema_expr_analyse_call_expr_dispatch(SemaContext* context, Expr* expr, bool* no_match_ref)
{
	switch (expr.expr_kind)
	{
		case UNRESOLVED_IDENTIFIER:
			return sema_expr_analyse_identifier(context, null, expr, no_match_ref);
		case ACCESS_UNRESOLVED:
			return sema_expr_analyse_access(context, expr, no_match_ref);
		default:
			return sema_analyse_expr_dispatch(context, expr);
	}
}

// sema_expr.c:4174 (static)
fn bool sema_expr_analyse_call_expr(SemaContext* context, Expr* expr, bool* no_match_ref)
{
	// c3c RESOLVE(expr, check)
	switch (expr.resolve_status)
	{
		case NOT_DONE:
			expr.resolve_status = RUNNING;
			if (!sema_expr_analyse_call_expr_dispatch(context, expr, no_match_ref)) return expr_poison(expr);
			expr.resolve_status = DONE;
			return true;
		case RUNNING:
			@sema_error_at(context, expr.loc, "Recursive resolution of expression.");
			return expr_poison(expr);
		case DONE:
			return expr_ok(expr);
	}
}

// sema_expr.c:4179 (static)
fn bool sema_expr_analyse_call(SemaContext* context, Expr* expr, bool* no_match_ref)
{
	Expr* func_expr = exprptr(expr.call_expr.function);
	if (!sema_expr_analyse_call_expr(context, func_expr, no_match_ref)) return false;
	bool optional = func_expr.type && @is_optional(func_expr);
	Decl* decl;
	Expr* struct_var = null;
	switch (func_expr.expr_kind)
	{
		case MACRO_BODY_EXPANSION:
			return sema_call_analyse_body_expansion(context, expr, no_match_ref);
		case MEMBER_GET:
			return sema_call_analyse_member_get(context, expr);
		case MEMBER_SET:
			return sema_call_analyse_member_set(context, expr);
		case TYPECALL:
			return sema_expr_analyse_typecall(context, expr);
		case BUILTIN:
			return sema_expr_analyse_builtin_call(context, expr);
		case IDENTIFIER:
			decl = func_expr.ident_expr;
			if (!sema_analyse_decl(context, decl)) return false;
		case ACCESS_RESOLVED:
			decl = func_expr.access_resolved_expr.ref;
			if (!sema_analyse_decl(context, decl)) return false;
			switch (decl.decl_kind)
			{
				case MACRO:
					struct_var = func_expr.access_resolved_expr.parent;
					if (decl.func_decl.signature.params[0].type.canonical != struct_var.type.canonical
						&& decl.func_decl.signature.params[0].type.type_kind == POINTER)
					{
						expr_insert_addr(struct_var);
					}
				case FUNC:
					struct_var = func_expr.access_resolved_expr.parent;
					if (decl.func_decl.signature.params[0].type.type_kind == POINTER)
					{
						if (decl.func_decl.signature.params[0].type.canonical != struct_var.type.canonical
							&& !decl.func_decl.attr_interface_method)
						{
							expr_insert_addr(struct_var);
						}
					}
				default:
					break;
			}
		case TYPEINFO:
			if (func_expr.type_expr.resolve_status == DONE)
			{
				@sema_error_at(context, expr.loc, "A type cannot be followed by (), if you intended a cast, use '(type) expression'.");
			}
			else
			{
				@sema_error_at(context, expr.loc, "A type cannot be followed by (), did you mean to use 'type {}'?");
			}
			return false;
		default:
		{
			Type* type = type_flatten(func_expr.type);
			if (type.type_kind == FUNC_PTR)
			{
				decl = null;
				break;
			}
			if (no_match_ref)
			{
				*no_match_ref = true;
				return false;
			}
			return @sema_error_at(context, expr.loc, "This value cannot be invoked, did you accidentally add ()?");
		}
	}
	decl = decl ? decl_flatten(decl) : null;
	return sema_expr_analyse_general_call(context, expr, decl, struct_var, optional, no_match_ref);
}

// sema_expr.c:4260 (static)
fn bool sema_slice_index_is_in_range(SemaContext* context, Type* type, Expr* index_expr, bool end_index, bool from_end, bool* remove_from_end, bool* missing_ref)
{
	assert(type == type.canonical);
	if (!sema_cast_const(index_expr)) return true;
	if (!sema_check_array_index(context, index_expr, false)) return false;
	Int index = index_expr.const_expr.ixx;
	if (from_end && int_is_neg(index))
	{
		return @sema_error_at(context, index_expr.loc, "Negative numbers are not allowed when indexing from the end.");
	}
	ArrayIndex idx = (ArrayIndex)(ulong)index.i;
	while (true)
	{
		switch (type.type_kind)
		{
			case POINTER:
				assert(!from_end);
				return true;
			case FLEXIBLE_ARRAY:
				assert(!from_end);
			case UNTYPEDLIST:
			case ARRAY:
			case VECTOR:
			case SIMD_VECTOR:
			{
				ArrayIndex len = (ArrayIndex)type.array.len;
				if (from_end)
				{
					idx = len - idx;
					// c3c sets only the low 64 bits.
					index_expr.const_expr.ixx.i = (index_expr.const_expr.ixx.i & ~(uint128)ulong::max) | (uint128)(ulong)idx;
					*remove_from_end = true;
				}
				// Checking end can only be done for arrays.
				if (end_index && idx >= len)
				{
					if (missing_ref) return lvalue_failed_ref(missing_ref);
					return @sema_error_at(context, index_expr.loc, "End index out of bounds, was %d, exceeding %d.", idx, len);
				}
				if (!end_index && idx >= len)
				{
					if (len == 0)
					{
						if (missing_ref) return lvalue_failed_ref(missing_ref);
						return @sema_error_at(context, index_expr.loc, "Cannot index into a zero size list.");
					}
					if (missing_ref) return lvalue_failed_ref(missing_ref);
					return @sema_error_at(context, index_expr.loc, "Index out of bounds, was %d, exceeding maximum (%d).", idx, len - 1);
				}
			}
			case SLICE:
				// If not from end, just check the negative values.
				if (!from_end) break;
				// From end we can only do sanity checks ^0 is invalid for non-end index. ^-1 and less is invalid for all.
				if (idx == 0 && !end_index)
				{
					if (missing_ref) return lvalue_failed_ref(missing_ref);
					return @sema_error_at(context, index_expr.loc,
										  "Array index out of bounds, index from end (%d) must be greater than zero or it will exceed the max array index.",
										  idx);
				}
				return true;
			case STRUCT:
			{
				Decl* decl = type.decl;
				assert(decl.is_substruct);
				type = decl.strukt.members[0].type.canonical;
				continue;
			}
			default:
				unreachable();
		}
		break;
	}
	if (idx < 0)
	{
		return @sema_error_at(context, index_expr.loc, "Index out of bounds, using a negative index is only allowed for pointers.");
	}
	return true;
}

// sema_expr.c:4339 (static)
fn Type* sema_subscript_find_indexable_type_recursively(Type** type, Expr** parent)
{
	while (true)
	{
		Type* inner_type = type_get_indexed_type(*type);
		if (!inner_type && type_is_substruct(*type))
		{
			Expr* embedded_struct = expr_access_inline_member(*parent, (*type).decl);
			*type = embedded_struct.type.canonical;
			*parent = embedded_struct;
			continue;
		}
		return inner_type;
	}
}

// sema_expr.c:4355 (static)
fn bool sema_subscript_rewrite_index_const_list(Expr* const_list, ArrayIndex index, bool from_back, Expr* result)
{
	if (const_list.const_expr.const_kind == SLICE)
	{
		assert(const_list.const_expr.slice_init);
		return expr_rewrite_to_const_initializer_index(const_list.type, const_list.const_expr.slice_init, result, (int)index, from_back);
	}
	assert(const_list.const_expr.const_kind == INITIALIZER);
	return expr_rewrite_to_const_initializer_index(const_list.type, const_list.const_expr.initializer, result, (int)index, from_back);
}

// sema_expr.c:4381 (static)
<* Find subscript type or overload for subscript. *>
fn bool sema_expr_find_subscript_type_or_overload_for_subscript(SemaContext* context, SubscriptLookup* lookup)
{
	Decl* overload = null;
	OperatorOverload overload_type = lookup.operator_overload;
	overload = sema_find_untyped_operator(lookup.subscripted.type, lookup.try_get_ref ? OVERLOAD_ELEMENT_REF : overload_type, null);
	if (overload)
	{
		lookup.overload_method = overload;
		// Overload for []=
		if (overload_type == OVERLOAD_ELEMENT_SET)
		{
			assert(overload.func_decl.signature.params.len == 3);
			lookup.subscript_value_type = overload.func_decl.signature.params[2].type;
			return true;
		}
		// Overload found for [] and &[]
		if (lookup.try_get_ref) lookup.ref_succeded = true;
		assert(overload.func_decl.signature.rtype);
		lookup.subscript_value_type = type_infoptr(overload.func_decl.signature.rtype).type;
		return true;
	}
	// &[] -> []
	if (lookup.try_get_ref)
	{
		// c3c: assert(overload_type == OVERLOAD_ELEMENT_AT); -- C assert, compiled out in c3c release builds
		overload = sema_find_untyped_operator(lookup.subscripted.type, OVERLOAD_ELEMENT_AT, null);
		if (overload)
		{
			lookup.overload_method = overload;
			assert(overload.func_decl.signature.rtype);
			lookup.subscript_value_type = type_infoptr(overload.func_decl.signature.rtype).type;
			return true;
		}
	}
	// Otherwise, see if we have an indexed type.
	Expr* subscripted = lookup.subscripted;
	Type* no_optional = type_no_optional(subscripted.type).canonical;

	// If there is a subscript overload it blocks further overloads.
	if (sema_type_has_subscript_overloads(no_optional))
	{
		return false;
	}
	Type* inner_type = type_get_indexed_type(subscripted.type);
	if (inner_type)
	{
		lookup.subscript_value_type = inner_type;
		lookup.overload_method = null;
		return true;
	}
	if (type_is_substruct(no_optional))
	{
		Expr* embedded_struct = expr_access_inline_member(subscripted, no_optional.decl);
		lookup.subscripted = embedded_struct;
		return sema_expr_find_subscript_type_or_overload_for_subscript(context, lookup);
	}
	return false;
}

// sema_expr.c:4440 (static)
fn bool sema_expr_resolve_subscript_index(SemaContext* context, SubscriptLookup* lookup, Expr* expr, Expr* index, long* index_ref, bool* missing_ref)
{
	Expr* starting_subscripted = lookup.subscripted;
	Type* current_type = starting_subscripted.type.canonical;
	if (current_type != type_untypedlist)
	{
		bool ok = sema_expr_find_subscript_type_or_overload_for_subscript(context, lookup);
		if (!ok && lookup.is_ref)
		{
			// Maybe there is a [] overload?
			lookup.operator_overload = OVERLOAD_ELEMENT_AT;
			lookup.subscripted = starting_subscripted;
			if (sema_expr_find_subscript_type_or_overload_for_subscript(context, lookup))
			{
				if (missing_ref) return lvalue_failed_ref(missing_ref);
				return @sema_error_at(context, expr.loc, "A function or macro with '@operator(&[])' is not defined for %s, "
									  "so you need && to take the address of the temporary.",
									  type_quoted_error_string(starting_subscripted.type));
			}
		}
		if (!lookup.subscript_value_type)
		{
			if (missing_ref) return lvalue_failed_ref(missing_ref);
			switch (lookup.operator_overload)
			{
				case OVERLOAD_ELEMENT_REF:
					return @sema_error_at(context, expr.loc, "Getting a reference to a subscript of %s is not possible.", type_quoted_error_string(starting_subscripted.type));
				case OVERLOAD_ELEMENT_SET:
					return @sema_error_at(context, expr.loc, "Assigning to a subscript of %s is not possible.", type_quoted_error_string(starting_subscripted.type));
				default:
					return @sema_error_at(context, expr.loc, "Indexing a value of type %s is not possible.", type_quoted_error_string(starting_subscripted.type));
			}
		}
		if (!lookup.overload_method) current_type = type_flatten(lookup.subscripted.type);
	}
	Expr* current_expr = lookup.subscripted;
	assert(current_type == current_type.canonical);
	Type* index_type = null;
	if (lookup.overload_method)
	{
		index_type = lookup.overload_method.func_decl.signature.params[1].type;
		if (!sema_analyse_inferred_expr(context, index_type, index, null))
		{
			expr_poison(index);
			return false;
		}
	}
	else
	{
		if (!sema_analyse_expr_rvalue(context, index))
		{
			expr_poison(index);
			return false;
		}
	}

	// Analyse the index.
	long index_value = -1;
	bool start_from_end = expr.subscript_expr.index.start_from_end;
	if (start_from_end && (current_type.type_kind == POINTER || current_type.type_kind == FLEXIBLE_ARRAY))
	{
		if (missing_ref) return lvalue_failed_ref(missing_ref);
		return @sema_error_at(context, index.loc, "Indexing from the end is not allowed for pointers "
							  "and flexible array members.");
	}
	ArrayIndex size;
	bool check_len = !context.call_env.in_no_eval || current_type == type_untypedlist;
	Expr* len_expr = expr_is_ct_ident(current_expr) ? current_expr.ident_expr.var_decl.init_expr : current_expr;
	// The c3c `goto SKIP` paths leave the block with index_value = -1.
	if (sema_cast_const(index) && expr_is_const_int(index) && (size = sema_len_from_expr(len_expr)) >= 0)
	{
		do
		{
			// 4c. And that it's in range.
			if (int_is_neg(index.const_expr.ixx))
			{
				if (missing_ref) return lvalue_failed_ref(missing_ref);
				return @sema_error_at(context, index.loc, "The index may not be negative.");
			}
			if (!sema_check_array_index(context, index, false)) return false;
			if (!size)
			{
				if (!check_len)
				{
					index_value = -1;
					break;
				}
				if (missing_ref) return lvalue_failed_ref(missing_ref);
				// c3c passes an unused size argument here.
				return @sema_error_at(context, index.loc, "The index is out of range.");
			}
			index_value = int_to_i64(index.const_expr.ixx);
			if (start_from_end)
			{
				index_value = size - index_value;
			}
			if (index_value < 0 || index_value >= size)
			{
				if (!check_len)
				{
					index_value = -1;
					break;
				}
				if (missing_ref) return lvalue_failed_ref(missing_ref);
				if (start_from_end)
				{
					if (size > 1)
					{
						return @sema_error_at(context, index.loc, "An index of '%d' from the end is out of range, a value between 1 and %d was expected.",
											  size - index_value, size);
					}
					return @sema_error_at(context, index.loc, "An index of '%d' from the end is out of range, a value of %d was expected.",
										  size - index_value, size);
				}
				if (size > 1)
				{
					return @sema_error_at(context, index.loc, "An index of '%d' is out of range, a value between 0 and %d was expected.",
										  index_value, size - 1);
				}
				return @sema_error_at(context, index.loc, "An index of '%d' is out of range, a value of %d was expected.",
									  index_value, size - 1);
			}
		};
	}
	// SKIP:
	*index_ref = index_value;
	lookup.subscripted_type = current_type;
	return true;
}

// sema_expr.c:4563 (static)
fn bool sema_expr_analyse_subscript_lvalue(SemaContext* context, Expr* expr, bool* failed_ref)
{
	// Evaluate the expression to index.
	Expr* subscripted = exprptr(expr.subscript_expr.expr);
	switch (subscripted.expr_kind)
	{
		case CT_IDENT:
			if (!sema_analyse_expr_lvalue(context, subscripted, null)) return false;
		case MAYBE_DEREF:
		{
			Expr* inner = subscripted.inner_expr;
			if (!sema_analyse_expr_rvalue(context, inner)) return false;
			if (type_is_pointer(inner.type))
			{
				subscripted.expr_kind = UNARY;
				subscripted.unary_expr = { .expr = inner, .operator = DEREF, .no_read = true };
				// goto DEFAULT
				if (!sema_analyse_expr(context, subscripted)) return false;
				break;
			}
			expr_replace(subscripted, inner);
		}
		case UNARY:
			subscripted.unary_expr.no_read = true;
			nextcase default;
		case SUBSCRIPT:
		{
			// Becomes `*(&subscript)`. The new nodes are copies, so if the subscript is already
			// resolved, they are too and are never analysed: set their types here.
			bool resolved = subscripted.resolve_status == DONE;
			Type* type = subscripted.type;
			Expr* inner = expr_copy(subscripted);
			subscripted.expr_kind = UNARY;
			subscripted.unary_expr = { .operator = ADDR, .expr = inner };
			if (resolved) subscripted.type = type_add_optional(type_get_ptr(type_no_optional(type)), type_is_optional(type));

			inner = expr_copy(subscripted);
			subscripted.expr_kind = UNARY;
			subscripted.unary_expr = { .operator = DEREF, .expr = inner, .no_read = true };
			if (resolved) subscripted.type = type;
			nextcase default;
		}
		default:
			// DEFAULT:
			if (!sema_analyse_expr(context, subscripted)) return false;
	}

	if (!sema_expr_check_assign(context, expr, failed_ref)) return false;
	if (!sema_may_subscript_or_access(context, subscripted, "cannot be subscripted", failed_ref)) return false;

	Expr* index = exprptr(expr.subscript_expr.index.expr);

	// 3. Check failability due to value.
	bool optional = @is_optional(subscripted);

	long index_value;
	SubscriptLookup lookup = {
		.operator_overload = OVERLOAD_ELEMENT_SET,
		.subscripted = subscripted
	};
	if (!sema_expr_resolve_subscript_index(context, &lookup, expr, index, &index_value, failed_ref)) return false;
	Expr* current_expr = lookup.subscripted;
	Type* current_type = lookup.subscripted_type;

	// 4. If we are indexing into a complist
	if (expr_is_ct_ident(current_expr))
	{
		if (index_value == -1)
		{
			if (failed_ref) return lvalue_failed_ref(failed_ref);
			return @sema_error_at(context, index.loc, "Assigning to a compile time constant requires a constant index.");
		}
		expr.expr_kind = CT_SUBSCRIPT;
		expr.ct_subscript_expr = { .ct_var = current_expr.ident_expr, .index = (ArrayIndex)index_value };
		expr.type = null;
		return true;
	}

	bool start_from_end = expr.subscript_expr.index.start_from_end;
	if (lookup.overload_method)
	{
		if (start_from_end)
		{
			Decl* len = sema_find_untyped_operator(current_expr.type, OVERLOAD_LEN, null);
			if (!len)
			{
				if (failed_ref) return lvalue_failed_ref(failed_ref);
				return @sema_error_at(context, subscripted.loc, "Cannot index '%s' from the end, since there is no 'len' overload.", type_to_error_string(subscripted.type));
			}
			if (!type_is_pointer_type(current_expr.type)) expr_insert_addr(current_expr);
			Decl* temp = decl_new_generated_var(current_expr.type, LOCAL, current_expr.loc);
			Expr* decl = expr_generate_decl(temp, expr_copy(current_expr));
			expr_rewrite_two(current_expr, decl, expr_variable(temp));
			if (!sema_analyse_expr_rvalue(context, current_expr)) return false;
			Expr* var_for_len = expr_variable(temp);
			Expr* len_expr = expr_new(CALL, expr.loc);
			if (!sema_insert_method_call(context, len_expr, len, var_for_len, {}, false)) return false;
			if (!sema_analyse_expr_rvalue(context, len_expr)) return false;
			Expr* index_copy = expr_copy(index);
			if (!sema_analyse_expr_rvalue(context, index_copy)) return false;
			if (!cast_explicit(context, index_copy, len_expr.type)) return false;
			expr_rewrite_to_binary(index, len_expr, index_copy, SUB);
			index.resolve_status = NOT_DONE;
			if (!sema_analyse_expr_rvalue(context, index)) return false;
		}
		expr.expr_kind = SUBSCRIPT_ASSIGN;
		expr.type = lookup.subscript_value_type;
		expr.subscript_assign_expr.expr = exprid(current_expr);
		expr.subscript_assign_expr.index = exprid(index);
		expr.subscript_assign_expr.method = declid(lookup.overload_method);
		return true;
	}

	// Cast to an appropriate type for index.
	if (!cast_to_index_len(context, index, false)) return false;

	optional |= @is_optional(index);
	// Check range
	bool remove_from_back = false;
	if (!sema_slice_index_is_in_range(context, current_type, index, false, start_from_end, &remove_from_back,
									  failed_ref))
	{
		return false;
	}
	if (remove_from_back)
	{
		expr.subscript_expr.index.start_from_end = false;
	}

	expr.subscript_expr.expr = exprid(current_expr);
	expr.type = type_add_optional(lookup.subscript_value_type, optional);
	return true;
}

// sema_expr.c:4701 (static)
fn bool sema_may_subscript_or_access(SemaContext* context, Expr* expr, String fail_reason, bool* failed_ref)
{
	switch (expr.expr_kind)
	{
		case BUILTIN:
			if (failed_ref) return lvalue_failed_ref(failed_ref);
			return @sema_error_at(context, expr.loc, "Builtin functions %s.", fail_reason);
		case TYPECALL:
			if (failed_ref) return lvalue_failed_ref(failed_ref);
			return @sema_error_at(context, expr.loc, "Type functions %s.", fail_reason);
		case IDENTIFIER:
			if (expr.ident_expr.decl_kind == MACRO)
			{
				if (failed_ref) return lvalue_failed_ref(failed_ref);
				return @sema_error_at(context, expr.loc, "Macros %s.", fail_reason);
			}
		case ACCESS_RESOLVED:
			if (expr.access_resolved_expr.ref.decl_kind == MACRO)
			{
				if (failed_ref) return lvalue_failed_ref(failed_ref);
				return @sema_error_at(context, expr.loc, "Macros %s.", fail_reason);
			}
		default:
			break;
	}
	assert(expr.type != null);
	return true;
}

// sema_expr.c:4733 (static)
fn bool sema_expr_analyse_subscript(SemaContext* context, Expr* expr, bool* failed_ref)
{
	assert(expr.expr_kind == SUBSCRIPT || expr.expr_kind == SUBSCRIPT_ADDR);
	bool is_eval_ref = expr.expr_kind == SUBSCRIPT_ADDR;

	// Evaluate the expression to index.
	Expr* subscripted = exprptr(expr.subscript_expr.expr);
	bool deref = false;
	if (subscripted.expr_kind == SUBSCRIPT)
	{
		if (is_eval_ref)
		{
			deref = true;
			subscripted.expr_kind = SUBSCRIPT_ADDR;
		}
		else
		{
			subscripted.subscript_expr.prefer_ref = true;
		}
	}
	if (!sema_analyse_expr(context, subscripted)) return false;
	if (deref)
	{
		if (!sema_expr_rewrite_insert_deref(context, subscripted)) return false;
	}
	if (!sema_may_subscript_or_access(context, subscripted, "cannot be subscripted", failed_ref)) return false;

	// 3. Check failability due to value.
	bool optional = @is_optional(subscripted);

	// 2. Evaluate the index.
	Expr* index = exprptr(expr.subscript_expr.index.expr);

	long index_value;
	OperatorOverload overload_type = (is_eval_ref || expr.subscript_expr.ref) ? OVERLOAD_ELEMENT_REF : OVERLOAD_ELEMENT_AT;

	SubscriptLookup lookup = {
		.operator_overload = overload_type,
		.subscripted = subscripted,
		.is_ref = is_eval_ref,
		.try_get_ref = !is_eval_ref && expr.subscript_expr.prefer_ref,
	};
	if (!sema_expr_resolve_subscript_index(context, &lookup, expr, index, &index_value, failed_ref)) return false;
	bool should_deref = lookup.ref_succeded;
	Expr* current_expr = lookup.subscripted;
	Type* current_type = lookup.subscripted_type;

	// 4. If we are indexing into a complist
	if (current_type == type_untypedlist)
	{
		if (is_eval_ref)
		{
			if (failed_ref) return lvalue_failed_ref(failed_ref);
			return @sema_error_at(context, subscripted.loc, "You need to use && to take the address of a temporary.");
		}
		// 4a. This may either be an initializer list or a CT value
		while (expr_is_ct_ident(current_expr)) current_expr = current_expr.ident_expr.var_decl.init_expr;

		// 4b. Now we need to check that we actually have a valid type.
		if (index_value < 0)
		{
			if (failed_ref) return lvalue_failed_ref(failed_ref);
			return @sema_error_at(context, index.loc, "To subscript an untyped list a compile time integer index is needed.");
		}
		expr_replace(expr, current_expr.const_expr.untyped_list[index_value]);
		return true;
	}
	if (!sema_cast_rvalue(context, subscripted, true)) return false;

	bool start_from_end = expr.subscript_expr.index.start_from_end;
	if (lookup.overload_method)
	{
		if (start_from_end)
		{
			Decl* len = sema_find_untyped_operator(current_expr.type, OVERLOAD_LEN, null);
			if (!len)
			{
				if (failed_ref) return lvalue_failed_ref(failed_ref);
				return @sema_error_at(context, subscripted.loc, "Cannot index '%s' from the end, since there is no 'len' overload.", type_to_error_string(subscripted.type));
			}
			bool addr = expr_may_ref(current_expr);
			if (addr)
			{
				expr_insert_addr(current_expr);
			}
			if (!sema_analyse_expr_rvalue(context, current_expr)) return false;
			Decl* temp = decl_new_generated_var(current_expr.type, LOCAL, current_expr.loc);
			Expr* decl = expr_generate_decl(temp, expr_copy(current_expr));
			expr_rewrite_two(current_expr, decl, expr_variable(temp));
			if (!sema_analyse_expr_rvalue(context, current_expr)) return false;
			if (addr)
			{
				if (!sema_expr_rewrite_insert_deref(context, current_expr)) return false;
			}
			Expr* var_for_len = expr_variable(temp);
			Expr* len_expr = expr_new(CALL, expr.loc);
			if (!sema_insert_method_call(context, len_expr, len, var_for_len, {}, false)) return false;
			if (!sema_analyse_expr_rvalue(context, len_expr)) return false;
			Expr* index_copy = expr_copy(index);
			if (!sema_analyse_expr_rvalue(context, index_copy)) return false;
			if (!cast_explicit(context, index_copy, len_expr.type)) return false;
			expr_rewrite_to_binary(index, len_expr, index_copy, SUB);
			index.resolve_status = NOT_DONE;
			if (!sema_analyse_expr_rvalue(context, index)) return false;
		}
		Expr*[] args = {};
		@vec_add(&args, index);
		if (!sema_insert_method_call(context, expr, lookup.overload_method, current_expr, args, false)) return false;
		if (should_deref && !sema_expr_rewrite_insert_deref(context, expr)) return false;
		return true;
	}

	// Cast to an appropriate type for index.
	if (!cast_to_index_len(context, index, false)) return false;

	optional |= @is_optional(index);
	// Check range
	bool remove_from_back = false;
	if (!sema_slice_index_is_in_range(context, current_type, index, false, start_from_end, &remove_from_back,
									  failed_ref))
	{
		return false;
	}
	if (remove_from_back)
	{
		start_from_end = expr.subscript_expr.index.start_from_end = false;
	}

	Type* subscript_type = lookup.subscript_value_type;
	if (is_eval_ref)
	{
		subscript_type = type_get_ptr(subscript_type);
	}
	else
	{
		if (sema_cast_const(index))
		{
			if (!sema_check_array_index(context, index, false)) return false;
			assert(expr_is_const_int(index));
			sema_cast_const(current_expr);
			bool is_const_initializer = expr_is_const_initializer(current_expr) || (expr_is_const_slice(current_expr) && current_expr.const_expr.slice_init);
			if (is_const_initializer || expr_is_const_string(current_expr) || expr_is_const_bytes(current_expr))
			{
				ArrayIndex idx = (ArrayIndex)(ulong)index.const_expr.ixx.i;
				ArrayIndex len = sema_len_from_const(current_expr);
				if (idx > len || (idx == len && !start_from_end) || (idx == 0 && start_from_end))
				{
					if (failed_ref) return lvalue_failed_ref(failed_ref);
					return @sema_error_at(context, index.loc, "The index (%s%d) is out of range, the length is just %d.",
										  start_from_end ? "^" : "",
										  (ulong)idx,
										  (ulong)len);
				}
				if (!is_const_initializer)
				{
					// Handle bytes / String
					if (start_from_end) idx = len - idx;
					expr_rewrite_const_byte(expr, lookup.subscript_value_type, (char)current_expr.const_expr.bytes.ptr[idx]);
					return true;
				}

				if (sema_subscript_rewrite_index_const_list(current_expr, idx, start_from_end, expr)) return true;
			}
		}
	}
	expr.subscript_expr.expr = exprid(current_expr);
	if (is_eval_ref && type_flatten(subscripted.type).type_kind == POINTER)
	{
		expr.type = type_add_optional(subscripted.type, optional);
	}
	else
	{
		expr.type = type_add_optional(subscript_type, optional);
	}
	return true;
}

// sema_expr.c:4911 (static)
fn bool sema_expr_analyse_pointer_offset(SemaContext* context, Expr* expr)
{
	assert(expr.expr_kind == POINTER_OFFSET);

	// 1. Evaluate the pointer
	Expr* pointer = exprptr(expr.pointer_offset_expr.ptr);
	if (!sema_analyse_expr_rvalue(context, pointer)) return false;

	// 2. Evaluate the offset.
	Expr* offset = exprptr(expr.pointer_offset_expr.offset);
	if (!sema_analyse_expr_rvalue(context, offset)) return false;
	Type* flat = type_flatten(pointer.type);
	int vec_len = type_kind_is_real_vector(flat.type_kind) ? (int)flat.array.len : 0;

	if (!cast_implicit_binary(context, offset, vec_len ? type_get_vector(type_sz, flat.type_kind, vec_len) : type_sz, null)) return false;

	// 3. Store optionality
	bool is_optional = @is_optional(pointer) || @is_optional(offset);

	// 4. Possibly constant fold
	if (!vec_len && sema_cast_const(pointer) && expr_is_const_pointer(pointer) && sema_cast_const(offset))
	{
		assert(!is_optional);
		Int mul = { .i = (uint128)type_size(type_flatten(pointer.type).pointer), .type = offset.const_expr.ixx.type };
		Int offset_val = int_mul(mul, offset.const_expr.ixx);
		Int res = int_add64(offset_val, pointer.const_expr.ptr);
		pointer.const_expr.ptr = (ulong)res.i;
		expr_replace(expr, pointer);
		return true;
	}
	expr.type = type_add_optional(pointer.type, is_optional);
	return true;
}

// sema_expr.c:4953 (static)
fn bool sema_expr_analyse_range_internal(SemaContext* context, ExprRange* range, ArrayIndex len, RangeEnv env, FlatType* indexed_type)
{
	Expr* start = exprptr(range.start);
	assert(start);
	Expr* end = exprptrzero(range.end);

	if (!sema_analyse_expr_rvalue(context, start)) return false;
	if (end && !sema_analyse_expr_rvalue(context, end)) return false;

	ArrayIndex lowest = range.is_len ? 0 : -1;
	if (!cast_to_index_len(context, start, false)) return false;
	if (end && !cast_to_index_len(context, end, range.is_len)) return false;
	Type* end_type = end ? type_no_optional(end.type) : null;
	Type* start_type = type_no_optional(start.type);
	if (end && @is_optional(end)) range.is_optional = true;
	if (@is_optional(start)) range.is_optional = true;
	if (end && end_type != start_type)
	{
		Type* common = type_find_max_type(context, start_type, end_type, null, null);
		if (!common)
		{
			return @sema_error_at(context, make_loc(extend_loc_with_token(sourcelocptr(start.loc), sourcelocptr(end.loc))), "No common type can be found between start and end index.");
		}
		// Resolution might have failed.
		if (common == poisoned_type) return false;

		if (!cast_implicit(context, start, common, false) || !cast_implicit(context, end, common, false)) return false;
	}
	// Check range
	if (env != ARRAY && env != SLICE)
	{
		if (range.start_from_end)
		{
			if (indexed_type.type_kind == POINTER && type_is_any_arraylike(indexed_type.pointer))
			{
				return @sema_error_at(context, start.loc, "Indexing from the end is not allowed for pointers, did you perhaps forget to dereference the pointer before []?");
			}
			return @sema_error_at(context, start.loc, "Indexing from the end is not allowed for pointers or flexible array members.");
		}
		if (!end)
		{
			if (indexed_type.type_kind == POINTER && type_is_any_arraylike(indexed_type.pointer))
			{
				return @sema_error_at(context, start.loc, "Omitting the end index is not allowed for pointers, did you perhaps forget to dereference the pointer before slicing with []? E.g. you wrote '*foo[..]' instead '(*foo)[..]'.");
			}
			return @sema_error_at(context, start.loc, "Omitting end index is not allowed for pointers or flexible array members.");
		}
		if (end && range.end_from_end)
		{
			if (indexed_type.type_kind == POINTER && type_is_any_arraylike(indexed_type.pointer))
			{
				return @sema_error_at(context, start.loc, "Indexing from the end is not allowed for pointers, did you perhaps forget to dereference the pointer before []?");
			}
			return @sema_error_at(context, end.loc, "Indexing from the end is not allowed for pointers or flexible array members.");
		}
	}
	if (end && sema_cast_const(end))
	{
		// Only ArrayIndex sized
		if (!sema_check_array_index(context, end, range.is_len)) return false;

		ArrayIndex end_index = int_to_i64(end.const_expr.ixx);
		if (range.end_from_end)
		{
			if (end_index < 0) return @sema_error_at(context, end.loc, "Negative numbers are not allowed when indexing from the end.");
			// Something like  1 .. ^4 with an unknown length.
			if (len < 0) return true;
			// Otherwise we fold the "from end"
			if (end_index + lowest > len)
			{
				return @sema_error_at(context, end.loc, "An index may only be negative for pointers (it was: %d).", len - end_index);
			}
			end_index = len - end_index;
			range.end_from_end = false;
		}
		if (end_index < lowest && env != PTR)
		{
			return @sema_error_at(context, end.loc, "An index may only be negative for pointers (it was: %d).", end_index);
		}
		// No more analysis
		range.const_end = end_index;
		range.range_type = range.is_len ? RangeType.CONST_LEN : RangeType.CONST_END;
	}
	else if (!end && len > 0)
	{
		range.is_len = false;
		range.const_end = len - 1;
		range.range_type = CONST_END;
	}

	if (sema_cast_const(start))
	{
		if (!sema_check_array_index(context, start, false)) return false;
		// Only ArrayIndex sized
		ArrayIndex start_index = int_to_i64(start.const_expr.ixx);
		if (range.start_from_end)
		{
			if (start_index < 0) return @sema_error_at(context, start.loc, "Negative numbers are not allowed when indexing from the end.");
			// Something like  ^1 .. 4 with an unknown length.
			if (len < 0) return true;
			// Otherwise we fold the "from end"
			if (len < start_index)
			{
				return @sema_error_at(context, start.loc, "An index may only be negative for pointers (it was: %d).", len - start_index);
			}
			start_index = len - start_index;
			range.start_from_end = false;
		}
		if (start_index < 0 && env != PTR)
		{
			return @sema_error_at(context, start.loc, "An index may only be negative for pointers (it was: %d).", start_index);
		}
		if (len > -1 && start_index >= len)
		{
			return @sema_error_at(context, start.loc, "Index out of bounds: the start index was %d, exceeding the maximum (%d)",
								  start_index, len - 1);
		}
		if (range.range_type == CONST_END)
		{
			ArrayIndex end_index = range.const_end;
			if (end_index - lowest < start_index) return @sema_error_at(context, start.loc, "The start index (%d) should not be greater than the end index (%d).",
																		  start_index, end_index);
			range.const_end = end_index + 1 - start_index;
			range.range_type = CONST_LEN;
			range.is_len = true;
		}
		if (range.range_type == CONST_LEN)
		{
			ArrayIndex end_index = range.const_end;
			range.range_type = CONST_RANGE;
			range.start_index = start_index;
			range.len_index = end_index;
		}
	}
	if (len > -1)
	{
		switch (range.range_type)
		{
			case CONST_END:
				if (range.const_end >= len)
				{
					return @sema_error_at(context, (end ? end : start).loc, "End index out of bounds, was %d, exceeding max index %d.", range.const_end, len - 1);
				}
			case CONST_LEN:
				if (range.const_end > len)
				{
					return @sema_error_at(context, (end ? end : start).loc, "Length out of bounds, was %d, exceeding max length %d.", range.const_end, len);
				}
			case CONST_RANGE:
				if (range.len_index > len - range.start_index)
				{
					return @sema_error_at(context, (end ? end : start).loc, "End index out of bounds, was %d, exceeding max index %d.", (ulong)range.start_index + (ulong)range.len_index - 1, len - 1);
				}
			default:
				break;
		}
	}
	return true;
}

// sema_expr.c:5117 (static)
fn bool sema_expr_analyse_range(SemaContext* context, ExprRange* range, ArrayIndex len, RangeEnv env, FlatType* indexed_type)
{
	switch (range.status)
	{
		case DONE:
			return true;
		case NOT_DONE:
			range.status = RUNNING;
			if (!sema_expr_analyse_range_internal(context, range, len, env, indexed_type))
			{
				range.status = NOT_DONE;
				return false;
			}
			range.status = DONE;
			return true;
		case RUNNING:
		{
			SourceLoc loc = *sourcelocptr(exprptr(range.start).loc);
			if (range.end) loc = extend_loc_with_token(&loc, sourcelocptr(exprptr(range.end).loc));
			@sema_error_at(context, make_loc(loc), "Recursive definition of range.");
			range.status = NOT_DONE;
			return false;
		}
	}
}

// sema_expr.c:5145 (static)
fn bool sema_slice_initializer(SemaContext* context, Expr* expr, Expr* subscripted, ExprRange* range)
{
	ConstInitializer* initializer = subscripted.const_expr.initializer;
	if (!type_is_arraylike(initializer.type))
	{
		return @sema_error_at(context, expr.loc, "It's not possible to slice an expression of type %s.", type_quoted_error_string(subscripted.type));
	}
	Type* new_type = type_get_slice(type_get_indexed_type(subscripted.type));
	// Turn zero length into an untyped list.
	if (range.len_index == 0)
	{
		expr_rewrite_const_empty_slice(expr, new_type);
		return true;
	}
	Type* inner_type;
	TypeKind kind = initializer.type.type_kind;
	switch (kind)
	{
		case VECTOR:
		case SIMD_VECTOR:
			inner_type = type_get_vector(new_type.array.base, kind, (int)range.len_index);
		case ARRAY:
			inner_type = type_get_array(new_type.array.base, range.len_index);
		default:
			unreachable();
	}
	const_init_set_type(initializer, inner_type);
	switch (initializer.kind)
	{
		case INIT_ZERO:
			break;
		case INIT_ARRAY_FULL:
			@vec_erase_front(&initializer.init_array_full, (usz)range.start_index);
			@vec_resize(&initializer.init_array_full, (usz)range.len_index);
		case INIT_ARRAY:
		{
			int elements = (int)initializer.init_array.elements.len;
			for (int i = 0; i < elements; i++)
			{
				ConstInitializer* element = initializer.init_array.elements[i];
				ArrayIndex index = element.init_array_value.index;
				if (index < range.start_index || index >= range.start_index + range.len_index)
				{
					@vec_erase_at(&initializer.init_array.elements, (usz)i);
					elements--;
					i--;
				}
				element.init_array_value.index -= range.start_index;
			}
			if (initializer.init_array.elements.len == 0)
			{
				initializer.kind = INIT_ZERO;
				break;
			}
		}
		case INIT_STRUCT:
		case INIT_UNION:
		case INIT_VALUE:
		case INIT_ARRAY_VALUE:
			unreachable();
	}
	subscripted.const_expr.const_kind = SLICE;
	expr_replace(expr, subscripted);
	expr.type = new_type;
	return true;
}

// sema_expr.c:5215 (static)
fn bool sema_expr_analyse_slice(SemaContext* context, Expr* expr)
{
	assert(expr.expr_kind == SLICE);
	Expr* subscripted = exprptr(expr.slice_expr.expr);
	if (!sema_analyse_expr(context, subscripted)) return false;
	if (!sema_may_subscript_or_access(context, subscripted, "cannot be sliced", null)) return false;

	bool optional = @is_optional(subscripted);
	Type* type = type_flatten(subscripted.type);
	Type* original_type = type_no_optional(subscripted.type);
	RangeEnv env;
	switch (type.type_kind)
	{
		case POINTER:
			env = PTR;
		case FLEXIBLE_ARRAY:
			env = FLEXIBLE;
		case SLICE:
			env = SLICE;
		default:
			env = ARRAY;
	}
	ArrayIndex length = sema_len_from_expr(subscripted);
	ExprRange* range = &expr.slice_expr.range;
	if (!sema_expr_analyse_range(context, range, length, env, type)) return false;
	if (range.is_optional) optional = true;
	if (range.range_type == CONST_RANGE && sema_cast_const(subscripted))
	{
		switch (subscripted.const_expr.const_kind)
		{
			case STRING:
			{
				String data = str_copy((String)(subscripted.const_expr.bytes.ptr + range.start_index)[:range.len_index]);
				expr_rewrite_const_string(expr, data, range.len_index);
				return true;
			}
			case BYTES:
			{
				char* data = range.len_index ? (char*)calloc_arena((usz)range.len_index) : null;
				if (data)
				{
					mem::copy(data, subscripted.const_expr.bytes.ptr + range.start_index, (usz)range.len_index);
				}
				subscripted.const_expr.bytes.ptr = data;
				subscripted.const_expr.bytes.len = range.len_index;
				if (type.type_kind != SLICE)
				{
					Type* index = type_get_indexed_type(type);
					assert(index);
					original_type = type_get_slice(index);
				}
				subscripted.type = original_type;
				expr_replace(expr, subscripted);
				return true;
			}
			case UNTYPED_LIST:
				assert(!type_is_arraylike(subscripted.type));
				@vec_erase_front(&subscripted.const_expr.untyped_list, (usz)range.start_index);
				@vec_resize(&subscripted.const_expr.untyped_list, (usz)range.len_index);
				expr_replace(expr, subscripted);
				return true;
			case INITIALIZER:
				return sema_slice_initializer(context, expr, subscripted, range);
			case SLICE:
				if (!subscripted.const_expr.slice_init)
				{
					assert(range.len_index == 0);
					expr_replace(expr, subscripted);
					return true;
				}
				return sema_slice_initializer(context, expr, subscripted, range);
			case POINTER:
			case FLOAT:
			case INTEGER:
			case BOOL:
			case ENUM:
			case FAULT:
			case TYPEID:
			case REF:
			case MEMBER:
			case REFLECTION:
				break;
		}
	}
	Expr* current_expr = subscripted;
	Type* inner_type = sema_subscript_find_indexable_type_recursively(&type, &current_expr);
	if (type == type_voidptr) inner_type = type_char;

	if (!inner_type || !type_is_valid_for_array(inner_type))
	{
		return @sema_error_at(context, subscripted.loc, "You cannot slice %s.", type_quoted_error_string(subscripted.type));
	}
	if (current_expr != subscripted)
	{
		expr.slice_expr.expr = exprid(current_expr);
	}
	// Retain the original type when doing distinct slices.
	Type* result_type = type_get_slice(inner_type);
	Type* original_type_canonical = original_type.canonical;
	if (original_type_canonical.type_kind == TYPEDEF && type_base(original_type_canonical) == result_type)
	{
		result_type = original_type;
	}
	expr.type = type_add_optional(result_type, optional);
	return true;
}

// sema_expr.c:5335
<*
 1. .A -> It is an enum constant.
 2. .foo -> It is a function.
 3. .@foo -> It is a macro.
 4. .$eval(...) -> resolve the eval and retry.
 5. .$ident -> resolve as `$eval($ident)`
 6. .$Type -> It is a child to resolve as CT type param
 (The c3c RETRY label is the `while (true)` loop.)
*>
fn Expr* sema_expr_resolve_access_child(SemaContext* context, Expr* child, bool* missing, bool* was_reflect)
{
	SourceLocId loc = child.loc;
	bool in_hash = false;
	while (true)
	{
		switch (child.expr_kind)
		{
			case OTHER_CONTEXT:
			{
				Expr* inner = child.expr_other_context.inner;
				context = child.expr_other_context.context;
				child = inner;
				continue;
			}
			case IDENTIFIER:
				// ALREADY_RESOLVED:
				if (in_hash)
				{
					@sema_error_at(context, loc, "An expression cannot already be resolved when used as '.foo'. "
								   "One way this might happen is if you pass a '#foo' style "
								   "parameter that is already assigned a type when declared: 'macro @test(int #foo) { ... }'.");
					return null;
				}
				@sema_error_at(context, loc, "This expression was already resolved to an identifier before it was used.");
				return null;
			case UNRESOLVED_IDENTIFIER:
				// A path is not allowed.
				if (child.unresolved_ident_expr.path) break;
				return child;
			case CT_IDENT:
			{
				Expr* result = sema_ct_eval_expr(context, EVAL_IMPLICIT_IDENTIFIER, child, missing == null, was_reflect);
				if (!expr_ok(result)) return null;
				if (!result)
				{
					if (missing) *missing = true;
					return null;
				}
				expr_replace(child, result);
				if (was_reflect && *was_reflect) return child;
				continue;
			}
			case TYPEINFO:
				if (child.type_expr.kind == INFO_CT_IDENTIFIER) return child;
			case CT_EVAL:
			{
				assert(child.resolve_status != DONE);
				// Only report missing if missing var is NULL
				Expr* result = sema_ct_eval_expr(context, EVAL_IDENTIFIER, child.inner_expr, missing == null, was_reflect);
				if (!expr_ok(result)) return null;
				if (!result)
				{
					if (missing) *missing = true;
					return null;
				}
				expr_replace(child, result);
				if (was_reflect && *was_reflect) return child;
				continue;
			}
			default:
				break;
		}
		break;
	}
	@sema_error_at(context, loc, "Expected an identifier here.");
	return null;
}

// sema_expr.c:5404 (static)
fn bool sema_expr_replace_with_enum_array(SemaContext* context, Expr* enum_array_expr, Decl* enum_decl)
{
	if (!sema_analyse_decl(context, enum_decl)) return false;
	Decl*[] values = enum_decl.enums.values;
	SourceLocId loc = enum_array_expr.loc;
	Expr* initializer = expr_new(INITIALIZER_LIST, loc);
	ArrayIndex elements = values.len;
	Expr*[] element_values = {};
	Type* kind = enum_decl.type;
	ConstKind const_kind = ENUM;
	for (ArrayIndex i = 0; i < elements; i++)
	{
		Decl* decl = values[i];
		Expr* expr = expr_new(CONST, loc);
		expr.const_expr.const_kind = const_kind;
		assert(enum_decl.resolve_status == DONE);
		expr.const_expr.enum_val = decl;
		assert(decl_ok(decl));
		expr.type = kind;
		expr.resolve_status = DONE;
		@vec_add(&element_values, expr);
	}
	initializer.initializer_list = element_values;
	enum_array_expr.expr_kind = COMPOUND_LITERAL;
	enum_array_expr.expr_compound_literal.initializer = initializer;
	enum_array_expr.expr_compound_literal.type_info = type_info_new_base(type_get_slice(kind), loc);
	enum_array_expr.resolve_status = NOT_DONE;
	return sema_analyse_expr_rvalue(context, enum_array_expr);
}

// sema_expr.c:5434 (static)
fn bool sema_expr_replace_with_const_enum_array(SemaContext* context, Expr* enum_array_expr, Decl* enum_decl)
{
	if (!sema_analyse_decl(context, enum_decl)) return false;
	Decl*[] values = enum_decl.enums.values;
	SourceLocId loc = enum_array_expr.loc;
	Expr* initializer = expr_new(INITIALIZER_LIST, loc);
	ArrayIndex elements = values.len;
	Expr*[] element_values = {};
	Type* kind = enum_decl.type;
	for (ArrayIndex i = 0; i < elements; i++)
	{
		Decl* decl = values[i];
		Expr* expr = copy_expr_single(decl.enum_constant.value);
		@vec_add(&element_values, expr);
	}
	initializer.initializer_list = element_values;
	enum_array_expr.expr_kind = COMPOUND_LITERAL;
	enum_array_expr.expr_compound_literal.initializer = initializer;
	enum_array_expr.expr_compound_literal.type_info = type_info_new_base(type_get_slice(kind), loc);
	enum_array_expr.resolve_status = NOT_DONE;
	return sema_analyse_expr_rvalue(context, enum_array_expr);
}

// sema_expr.c:5457 (static)
fn bool sema_expr_replace_with_enum_name_array(SemaContext* context, Expr* enum_array_expr, Decl* enum_decl)
{
	if (!sema_analyse_decl(context, enum_decl)) return false;
	Decl*[] values = enum_decl.enums.values;
	SourceLocId loc = enum_array_expr.loc;
	Expr* initializer = expr_new(INITIALIZER_LIST, loc);
	ArrayIndex elements = values.len;
	Expr*[] element_values = {};
	for (ArrayIndex i = 0; i < elements; i++)
	{
		Decl* decl = values[i];
		Expr* expr = expr_new(CONST, loc);
		expr_rewrite_const_string(expr, decl.name, decl.name.len);
		@vec_add(&element_values, expr);
	}
	initializer.initializer_list = element_values;
	enum_array_expr.expr_kind = COMPOUND_LITERAL;
	enum_array_expr.expr_compound_literal.initializer = initializer;
	enum_array_expr.expr_compound_literal.type_info = type_info_new_base(type_get_slice(type_string), loc);
	enum_array_expr.resolve_status = NOT_DONE;
	return sema_analyse_expr_rvalue(context, enum_array_expr);
}

// sema_expr.c:5480 (static)
fn bool sema_analyse_macro_func_access(SemaContext* context, Expr* expr, Decl* parent, Expr* identifier, String kw, bool* missing_ref)
{
	if (kw.ptr == type_property_list[TypeProperty.PROPERTY_HAS_TAG.ordinal].ptr)
	{
		expr.expr_kind = TYPECALL;
		expr.type_call_expr = { .type = parent, .property = PROPERTY_HAS_TAG };
		return true;
	}
	if (kw.ptr == type_property_list[TypeProperty.PROPERTY_GET_TAG.ordinal].ptr)
	{
		expr.expr_kind = TYPECALL;
		expr.type_call_expr = { .type = parent, .property = PROPERTY_GET_TAG };
		return true;
	}
	if (parent.decl_kind == MACRO)
	{
		if (missing_ref)
		{
			*missing_ref = true;
			return false;
		}
		return @sema_error_at(context, identifier.loc, "The property '%s' is not valid on the macro '%s'.", kw, parent.name);
	}
	return sema_expr_analyse_type_access(context, expr, parent.type, identifier, missing_ref);
}

// sema_expr.c:5506 (static)
fn bool sema_expr_analyse_type_access(SemaContext* context, Expr* expr, Type* parent_type, Expr* identifier, bool* missing_ref)
{
	assert(identifier.expr_kind == UNRESOLVED_IDENTIFIER);
	Type* canonical = parent_type.canonical;
	String name = identifier.unresolved_ident_expr.ident;
	bool is_const = identifier.unresolved_ident_expr.is_const;

	if (!type_may_have_sub_elements(canonical))
	{
		Decl* member = sema_resolve_type_method(context, parent_type.canonical, name);
		if (!decl_ok(member)) return false;
		if (!member)
		{
			if (missing_ref)
			{
				@vec_add(&compiler.context.types_with_failed_methods, parent_type);
				return lvalue_failed_ref(missing_ref);
			}
			return @sema_error_at(context, expr.loc, "'%s' does not have a member or method '%s'.", type_to_error_string(parent_type), name);
		}
		expr_resolve_ident(expr, member);
		return true;
	}
	Decl* decl = canonical.decl;
	if (!decl_ok(decl)) return false;
	switch (decl.decl_kind)
	{
		case ENUM:
		case CONSTSET:
			if (is_const)
			{
				if (!sema_expr_analyse_enum_constant(context, expr, name, decl))
				{
					if (missing_ref) return lvalue_failed_ref(missing_ref);
					if (!decl_ok(decl)) return false;
					if (decl.decl_kind != ENUM)
					{
						return @sema_error_at(context, expr.loc, "'%s' has no value '%s'.", decl.name, name);
					}
					return @sema_error_at(context, expr.loc, "'%s' has no enumeration value '%s'.", decl.name, name);
				}
				return expr_ok(expr);
			}
		case UNION:
		case STRUCT:
		case TYPEDEF:
		case BITSTRUCT:
		case INTERFACE:
			break;
		default:
			unreachable();
	}

	Decl* member = sema_decl_stack_find_decl_member(context, decl, name, FIELDS_ONLY);
	if (!decl_ok(member)) return false;
	if (!member)
	{
		member = sema_resolve_type_method(context, decl.type, name);
		if (!decl_ok(member)) return false;
	}
	if (!member)
	{
		if (missing_ref)
		{
			if (decl.unit.mod.stage < POST_REGISTER)
			{
				decl.is_method_checked = true;
			}
			return lvalue_failed_ref(missing_ref);
		}
		return @sema_error_at(context, expr.loc, "No method or inner struct/union '%s.%s' found.", type_to_error_string(decl.type), name);
	}
	if (!member.unit)
	{
		if (!sema_analyse_decl(context, decl)) return false;
	}
	if (member.decl_kind == MACRO || member.decl_kind == FUNC)
	{
		if (!sema_analyse_decl(context, member)) return false;
	}
	if (member.decl_kind == VAR || member.decl_kind == UNION || member.decl_kind == STRUCT || member.decl_kind == BITSTRUCT)
	{
		expr.expr_kind = CONST;
		expr.resolve_status = DONE;
		AlignSize align;
		if (!sema_set_alignment(context, decl.type, &align, false)) return false;
		expr.const_expr = {
			.member.decl = member,
			.member.align = align,
			.member.offset = decl_find_member_offset(decl, member),
			.const_kind = MEMBER
		};
		expr.type = type_member;
		return true;
	}
	expr_resolve_ident(expr, member);
	return true;
}

// sema_expr.c:5609 (static)
fn bool sema_expr_analyse_member_access(SemaContext* context, Expr* expr, Expr* parent, Expr* identifier, bool* missing_ref)
{
	assert(identifier.expr_kind == UNRESOLVED_IDENTIFIER);

	Decl* decl = parent.const_expr.member.decl;
	String name = identifier.unresolved_ident_expr.ident;
	bool is_const = identifier.unresolved_ident_expr.is_const;

	if (is_const)
	{
		if (missing_ref) return member_access_missing_ref(missing_ref, decl);
		return @sema_error_at(context, expr.loc, "There is no member '%s' for %s.", name, type_to_error_string(decl.type));
	}

	AlignSize offset = parent.const_expr.member.offset;

	Type* underlying_type = type_flatten(decl.type);

	if (!type_is_union_or_strukt(underlying_type) && underlying_type.type_kind != BITSTRUCT)
	{
		if (missing_ref) return member_access_missing_ref(missing_ref, decl);
		return @sema_error_at(context, parent.loc, "No member or property '%s' was found.", name);
	}

	Decl* underlying_type_decl = decl.type.decl;
	Decl* member = sema_decl_stack_find_decl_member(context, underlying_type_decl, name, METHODS_AND_FIELDS);
	if (!decl_ok(member)) return false;
	if (!member || !(decl_is_struct_type(member) || member.decl_kind == VAR || member.decl_kind == BITSTRUCT))
	{
		if (missing_ref) return member_access_missing_ref(missing_ref, decl);
		return @sema_error_at(context, expr.loc, "No member '%s' found.", name);
	}

	assert(member.unit);

	expr.expr_kind = CONST;
	expr.resolve_status = DONE;
	expr.const_expr = {
		.member.decl = member,
		.member.align = parent.const_expr.member.align,
		.member.offset = offset == ~(AlignSize)0 ? offset : offset + decl_find_member_offset(decl, member),
		.const_kind = MEMBER
	};
	expr.type = type_member;
	return true;
}

<* sema_expr_analyse_member_access `MISSING_REF:` label. *>
fn bool member_access_missing_ref(bool* missing_ref, Decl* decl) @local
{
	*missing_ref = true;
	decl.is_method_checked = true;
	return false;
}

// sema_expr.c:5660 (static)
fn bool sema_expr_analyse_reflection_cname(SemaContext* context, Expr* expr, Decl* decl)
{
	switch (decl.decl_kind)
	{
		case VAR:
			switch (decl.var_decl.kind)
			{
				case CONST:
				case GLOBAL:
					break; // goto RETURN_CT
				case PARAM_EXPR:
				case PARAM_CT:
				case PARAM_CT_TYPE:
				case PARAM:
				case MEMBER:
				case BITMEMBER:
				case UNWRAPPED:
				case ERASE:
				case REWRAPPED:
				case LOCAL_CT:
				case LOCAL_CT_TYPE:
				case LOCAL:
					return false;
			}
		case ALIAS:
		case ALIAS_PATH:
		case ATTRIBUTE:
		case BODYPARAM:
		case CT_ASSERT:
		case CT_ECHO:
		case CT_EXEC:
		case CT_EXPAND:
		case CT_INCLUDE:
		case DECLARRAY:
		case ERASED:
		case GROUP:
		case IMPORT:
		case LABEL:
		case MACRO:
		case POISONED:
		case GENERIC:
		case GENERIC_INSTANCE:
		case CONTRACT:
			return false;
		case FAULT:
			break; // goto RETURN_CT
		case BITSTRUCT:
		case TYPEDEF:
		case ENUM:
		case CONSTSET:
		case ENUM_CONSTANT:
		case FNTYPE:
		case FUNC:
		case INTERFACE:
		case STRUCT:
		case TYPE_ALIAS:
		case UNION:
			// TODO verify that all of these are correct
			break; // goto RETURN_CT
	}
	// RETURN_CT:
	scratch_buffer_set_extern_decl_name(decl, true);
	expr_rewrite_const_string_from_scratch(expr);
	return true;
}

// sema_expr.c:5727 (static)
fn void sema_expr_analyse_reflection_name(SemaContext* context, Expr* expr, Decl* decl, bool is_qualified)
{
	if (!decl.unit || !is_qualified || decl_is_var_local(decl))
	{
		expr_rewrite_const_string(expr, decl.name, decl.name.len);
		return;
	}
	scratch_buffer_clear();
	scratch_buffer_append(decl.unit.mod.name.module_name);
	scratch_buffer_append("::");
	scratch_buffer_append(decl.name);
	expr_rewrite_const_string_from_scratch(expr);
}

// sema_expr.c:5741 (static)
fn ArrayIndex sema_recursive_analyse_alignment_offset(Expr* access, AlignSize* alignment_ref)
{
	switch (access.expr_kind)
	{
		case IDENTIFIER:
		{
			AlignSize align_size = access.ident_expr.alignment;
			if (!align_size) return -1;
			if (alignment_ref) *alignment_ref = align_size;
			return 0;
		}
		case ACCESS_RESOLVED:
		{
			ArrayIndex offset = sema_recursive_analyse_alignment_offset(access.access_resolved_expr.parent, alignment_ref);
			if (offset < 0) return -1;
			return offset + access.access_resolved_expr.ref.offset;
		}
		default:
			return 0;
	}
}

// sema_expr.c:5762 (static)
fn BoolErr sema_expr_analyse_reflection_alignment(SemaContext* context, Expr* expr, Expr* reflect, Decl* member)
{
	if (member)
	{
		expr_rewrite_const_int(expr, type_sz, (ulong)(reflect.const_expr.member.offset == -1 ? member.alignment : type_min_alignment(reflect.const_expr.member.offset, reflect.const_expr.member.align)));
		return BOOL_TRUE;
	}
	Type* type = reflect.type;
	if (sema_resolve_storage_type(context, type) != STORAGE_NORMAL) return BOOL_FALSE;
	AlignSize align;
	if (!sema_set_alignment(context, type, &align, false)) return BOOL_ERR;
	switch (reflect.expr_kind)
	{
		case IDENTIFIER:
			align = reflect.ident_expr.alignment;
		case ACCESS_RESOLVED:
		{
			ArrayIndex offset = sema_recursive_analyse_alignment_offset(reflect, &align);
			if (offset < 0) return BOOL_FALSE;
			align = type_min_alignment(align, (AlignSize)offset);
		}
		default:
			break;
	}
	if (!align) return BOOL_FALSE;
	expr_rewrite_const_int(expr, type_sz, (ulong)align);
	return BOOL_TRUE;
}

// sema_expr.c:5793 (static)
fn bool sema_expr_analyse_reflection_offset(Expr* expr, Expr* reflect)
{
	if (expr_is_const_member(reflect))
	{
		if (reflect.const_expr.member.decl.var_decl.kind == BITMEMBER) return false;
		AlignSize offset = reflect.const_expr.member.offset;
		if (offset != ~(AlignSize)0)
		{
			expr_rewrite_const_int(expr, type_sz, (ulong)offset);
			return true;
		}
		return false;
	}

	if (reflect.expr_kind != ACCESS_RESOLVED) return false;
	ArrayIndex offset = sema_recursive_analyse_alignment_offset(reflect, null);
	if (offset < 0) return false;
	expr_rewrite_const_int(expr, type_sz, (ulong)offset);
	return true;
}

// sema_expr.c:5814 (static)
fn bool sema_expr_rewrite_to_is_ordered(SemaContext* context, Expr* expr, Type* type)
{
	switch (sema_type_can_order_with_overload(context, type))
	{
		case BOOL_ERR:
			return false;
		case BOOL_TRUE:
			expr_rewrite_const_bool(expr, type_bool, true);
			return true;
		case BOOL_FALSE:
			expr_rewrite_const_bool(expr, type_bool, false);
			return true;
	}
	unreachable();
}

// sema_expr.c:5830 (static)
fn bool sema_expr_rewrite_to_generic_args(SemaContext* context, Expr* expr, Type* type)
{
	type = type.canonical;
	Expr*[] exprs = {};
	// The c3c EMPTY_GENERICS gotos are the nested ifs.
	if (type_is_user_defined(type))
	{
		if (!sema_resolve_type_decl(context, type)) return false;
		if (type.decl.is_templated)
		{
			Decl* generic_ptr = declptr(type.decl.instance_id);
			assert(generic_ptr.decl_kind == GENERIC_INSTANCE);
			Decl*[] params = generic_ptr.instance_decl.params;

			foreach (gen_param : params)
			{
				Expr* copy = expr_copy(gen_param.var_decl.init_expr);
				@vec_add(&exprs, copy);
			}
		}
	}
	// EMPTY_GENERICS:
	expr_rewrite_const_untyped_list(expr, exprs);
	return true;
}

// sema_expr.c:5851 (static)
fn bool sema_expr_rewrite_to_generic_qname(SemaContext* context, Expr* expr, Type* type)
{
	type = type.canonical;
	if (type_is_user_defined(type))
	{
		if (!sema_resolve_type_decl(context, type)) return false;
		if (type.decl.is_templated)
		{
			scratch_buffer_clear();
			Module* mod = type_base_module(type);
			if (mod)
			{
				scratch_buffer_append(mod.name.module_name);
				scratch_buffer_append("::");
			}
			int len = (int)scratch_buffer_len() + 1;
			scratch_buffer_append(type.name);
			while (scratch_buffer_ptr()[len] != '{') len++;
			scratch_buffer_set_len(len);
			expr_rewrite_const_string_from_scratch(expr);
			return true;
		}
	}
	// EMPTY_GENERICS:
	expr_rewrite_const_string(expr, "", 0);
	return true;
}

// sema_expr.c:5875 (static)
fn bool sema_expr_rewrite_to_has_equals(SemaContext* context, Expr* expr, Type* type)
{
	switch (sema_type_can_check_equality_with_overload(context, type))
	{
		case BOOL_ERR:
			return false;
		case BOOL_TRUE:
			expr_rewrite_const_bool(expr, type_bool, true);
			return true;
		case BOOL_FALSE:
			expr_rewrite_const_bool(expr, type_bool, false);
			return true;
	}
	unreachable();
}

// sema_expr.c:5891
fn bool type_is_ct_only(Type* type)
{
	switch (type.canonical.type_kind)
	{
		case TYPEINFO:
		case INFERRED_ARRAY:
		case INFERRED_VECTOR:
		case POISONED:
		case MEMBER:
		case WILDCARD:
		case REFLECTION:
			return true;
		default:
			return false;
	}
}

// sema_expr.c:5902 (static)
<* c3c FAILED / MISSING_REF labels: `reflection_access_failed` / `lvalue_failed_ref`. *>
fn bool sema_expr_analyse_reflection_access(SemaContext* context, Expr* expr, Expr* parent, Expr* identifier, bool* missing_ref)
{
	assert(identifier.expr_kind == UNRESOLVED_IDENTIFIER);

	Expr* reflect = parent.const_expr.reflection;
	String name = identifier.unresolved_ident_expr.ident;
	bool is_const = identifier.unresolved_ident_expr.is_const;
	if (is_const)
	{
		if (missing_ref) return lvalue_failed_ref(missing_ref);
		return @sema_error_at(context, expr.loc, "There is no reflection property '%s'.", name);
	}
	Decl* member = expr_is_const_member(reflect) ? reflect.const_expr.member.decl : null;
	if (member && !sema_analyse_decl(context, member)) return false;
	bool is_param = member && reflect.const_expr.member.offset == MEMBER_IS_PARAM;
	Type* type = member ? member.type : reflect.type;
	if (!type) return reflection_access_failed(context, expr, name, missing_ref);
	if (type.type_kind == FUNC_RAW) type = type_get_func_ptr(type);
	if (name.ptr == kw_is_const.ptr)
	{
		expr_rewrite_const_bool(expr, type_bool, expr_is_runtime_const(reflect));
		return true;
	}
	if (name.ptr == kw_default_value.ptr)
	{
		if (!is_param)
		{
			if (missing_ref) return lvalue_failed_ref(missing_ref);
			return @sema_error_at(context, expr.loc, "'.default_value' is only valid for parameters.");
		}
		if (!member.var_decl.init_expr)
		{
			if (missing_ref) return lvalue_failed_ref(missing_ref);
			return @sema_error_at(context, expr.loc, "The parameter does not have a default value, check this with `$defined(foo.default_value)` before usage.");
		}
		Expr* init_expr = copy_expr_single(member.var_decl.init_expr);
		expr_replace(expr, init_expr);
		return true;
	}
	bool normal_storage = sema_resolve_storage_type(context, type) == STORAGE_NORMAL;
	if (normal_storage && name.ptr == kw_is_ordered.ptr) return sema_expr_rewrite_to_is_ordered(context, expr, type);
	if (normal_storage && name.ptr == kw_has_equals.ptr) return sema_expr_rewrite_to_has_equals(context, expr, type);
	if (name.ptr == kw_size.ptr)
	{
		if (!normal_storage) return reflection_access_failed(context, expr, name, missing_ref);
		expr_rewrite_const_int(expr, type_sz, (ulong)type_size(type));
		return true;
	}
	if (name.ptr == kw_param_struct.ptr && reflect.expr_kind == IDENTIFIER && reflect.ident_expr.decl_kind == FUNC)
	{
		return sema_create_type_param_struct(context, expr, reflect.ident_expr);
	}

	if (name.ptr == kw_alignment.ptr)
	{
		switch (sema_expr_analyse_reflection_alignment(context, expr, reflect, member))
		{
			case BOOL_ERR: return false;
			case BOOL_TRUE: return true;
			case BOOL_FALSE: return reflection_access_failed(context, expr, name, missing_ref);
		}
		unreachable();
	}
	if (name.ptr == kw_type.ptr)
	{
		if (type_is_ct_only(type)) return reflection_access_failed(context, expr, name, missing_ref);
		expr_rewrite_const_typeid(expr, type);
		return true;
	}
	if (name.ptr == kw_offset.ptr)
	{
		if (is_param) return reflection_access_failed(context, expr, name, missing_ref);
		if (!sema_expr_analyse_reflection_offset(expr, reflect)) return reflection_access_failed(context, expr, name, missing_ref);
		return true;
	}
	if (member)
	{
		if (name.ptr == kw_is_anonymous.ptr && !is_param)
		{
			expr_rewrite_const_bool(expr, type_bool, member.name.ptr == null || member.name == "");
			return true;
		}
		if (name.ptr == kw_is_nested.ptr && !is_param)
		{
			expr_rewrite_const_bool(expr, type_bool, decl_has_members(member));
			return true;
		}
		if (name.ptr == kw_get_tag.ptr)
		{
			expr.expr_kind = TYPECALL;
			expr.type_call_expr = { .type = member, .property = PROPERTY_GET_TAG };
			return true;
		}
		if (name.ptr == kw_has_tag.ptr)
		{
			expr.expr_kind = TYPECALL;
			expr.type_call_expr = { .type = member, .property = PROPERTY_HAS_TAG };
			return true;
		}
		if (name.ptr == kw_tags.ptr)
		{
			return sema_create_const_tags(context, expr, member.attrs_resolved);
		}
		if (name.ptr == kw_set.ptr && !is_param)
		{
			if (compiler.build.warnings.deprecation == ERROR) return @sema_error_at(context, expr.loc, "Use of deprecated $field.set(...), use a.$field instead");
			@sema_deprecated(expr.loc, "Use of deprecated $field.set(...), use a.$field instead");
			expr.expr_kind = MEMBER_SET;
			expr.member_get_expr = member;
			expr.type = type_void;
			return true;
		}
		if (name.ptr == kw_get.ptr && !is_param)
		{
			if (compiler.build.warnings.deprecation == ERROR) return @sema_error_at(context, expr.loc, "Use of deprecated $field.get(...), use a.$field instead.");
			@sema_deprecated(expr.loc, "Use of deprecated $field.get(...), use a.$field instead.");
			expr.expr_kind = MEMBER_GET;
			expr.member_get_expr = member;
			expr.type = type_void;
			return true;
		}
		if (name.ptr == kw_name.ptr)
		{
			if (!member.name.ptr)
			{
				expr_rewrite_const_string(expr, "", 0);
				return true;
			}
			expr_rewrite_const_string(expr, member.name, member.name.len);
			return true;
		}
		if (name.ptr == kw_members.ptr && !is_param)
		{
			sema_create_const_membersof(expr, type.canonical, reflect.const_expr.member.align, reflect.const_expr.member.offset);
			return true;
		}
		if (name.ptr == kw_bitoffset.ptr)
		{
			if (member.decl_kind != VAR || member.var_decl.kind != BITMEMBER) return reflection_access_failed(context, expr, name, missing_ref);
			AlignSize base_offset = reflect.const_expr.member.offset;
			if (base_offset == ~(AlignSize)0) base_offset = 0;
			expr_rewrite_const_int(expr, type_sz, (ulong)(member.var_decl.start_bit + base_offset * 8));
			return true;
		}
		if (name.ptr == kw_bitsize.ptr)
		{
			if (member.decl_kind != VAR || member.var_decl.kind != BITMEMBER) return reflection_access_failed(context, expr, name, missing_ref);
			expr_rewrite_const_int(expr, type_sz, (ulong)(member.var_decl.end_bit - member.var_decl.start_bit + 1));
			return true;
		}
	}

	if (reflect.expr_kind != IDENTIFIER) return reflection_access_failed(context, expr, name, missing_ref);
	Decl* decl = reflect.ident_expr;
	if (name.ptr == kw_name.ptr)
	{
		sema_expr_analyse_reflection_name(context, expr, decl, false);
		return true;
	}
	if (name.ptr == kw_qname.ptr)
	{
		sema_expr_analyse_reflection_name(context, expr, decl, true);
		return true;
	}
	if (name.ptr == kw_cname.ptr)
	{
		if (!sema_expr_analyse_reflection_cname(context, expr, decl)) return reflection_access_failed(context, expr, name, missing_ref);
		return true;
	}
	if (name.ptr == kw_get_tag.ptr)
	{
		expr.expr_kind = TYPECALL;
		expr.type_call_expr = { .type = decl, .property = PROPERTY_GET_TAG };
		return true;
	}
	if (name.ptr == kw_has_tag.ptr)
	{
		expr.expr_kind = TYPECALL;
		expr.type_call_expr = { .type = decl, .property = PROPERTY_HAS_TAG };
		return true;
	}
	if (name.ptr == kw_tags.ptr)
	{
		return sema_create_const_tags(context, expr, decl.attrs_resolved);
	}
	return reflection_access_failed(context, expr, name, missing_ref);
}

<* sema_expr_analyse_reflection_access `FAILED:` label. *>
fn bool reflection_access_failed(SemaContext* context, Expr* expr, String name, bool* missing_ref) @local
{
	if (missing_ref) return lvalue_failed_ref(missing_ref);
	if (name.ptr == kw_param_struct.ptr) return @sema_error_at(context, expr.loc, "'param_struct' is only a property for functions.");
	return @sema_error_at(context, expr.loc, "There is no property '%s' available for the reflected expression.", name);
}

// sema_expr.c:6090 (static)
fn void sema_expr_rewrite_typeid_kind(Expr* expr, Expr* parent)
{
	Module* mod = global_context_find_module(kw_std__core__types);
	Decl* type_kind = mod ? module_find_symbol(mod, kw_typekind) : null;
	Type* type_for_kind = type_kind ? type_kind.type : type_char;
	expr.expr_kind = TYPEID_INFO;
	expr.typeid_info_expr.parent = exprid(parent);
	expr.typeid_info_expr.kind = INFO_KIND;
	expr.type = type_add_optional(type_for_kind, @is_optional(parent));
}

// sema_expr.c:6102 (static)
fn bool sema_create_const_kind(SemaContext* context, Expr* expr, Type* type)
{
	Module* mod = global_context_find_module(kw_std__core__types);
	Decl* type_kind = mod ? module_find_symbol(mod, kw_typekind) : null;
	int val = type_get_introspection_kind(type.type_kind);
	if (!type_kind)
	{
		// No TypeKind defined, fallback to char.
		expr_rewrite_const_int(expr, type_char, (ulong)val);
		return true;
	}
	if (type_kind.resolve_status == NOT_DONE && !sema_analyse_decl(context, type_kind)) return false;
	Decl*[] values = type_kind.enums.values;
	assert(values.len > val);
	expr.type = type_kind.type;
	expr.expr_kind = CONST;
	expr.resolve_status = DONE;
	assert(type_kind.resolve_status == DONE);
	expr.const_expr = {
		.const_kind = ENUM,
		.enum_val = values[val]
	};
	return true;
}

// sema_expr.c:6127 (static)
fn bool sema_create_const_len(Expr* expr, Type* type, Type* flat)
{
	assert(flat == type_flatten(flat), "Should be flattened already.");

	usz len;
	if (type.type_kind == CONSTSET)
	{
		len = type.decl.enums.values.len;
		expr_rewrite_const_int(expr, type_sz, len);
		return true;
	}
	switch (flat.type_kind)
	{
		case ARRAY:
		case VECTOR:
		case SIMD_VECTOR:
			len = (usz)flat.array.len;
		case ENUM:
			len = flat.decl.enums.values.len;
		case INFERRED_ARRAY:
		case FLEXIBLE_ARRAY:
		case SLICE:
		default:
			unreachable();
	}
	expr_rewrite_const_int(expr, type_sz, len);
	return true;
}

// sema_expr.c:6157 (static)
fn bool sema_create_const_inner(SemaContext* context, Expr* expr, Type* type)
{
	if (!sema_resolve_type_decl(context, type)) return false;
	Type* inner = null;
	switch (type.type_kind)
	{
		case POINTER:
			inner = type.pointer;
		case OPTIONAL:
			inner = type.optional;
		case TYPEDEF:
			inner = type.decl.distinct.type.canonical;
		case CONSTSET:
		case ENUM:
			inner = enum_inner_type(type).canonical;
		case BITSTRUCT:
			inner = type.decl.strukt.container_type.type.canonical;
		case ARRAY:
		case FLEXIBLE_ARRAY:
		case SLICE:
		case INFERRED_ARRAY:
		case VECTOR:
		case INFERRED_VECTOR:
		case SIMD_VECTOR:
			inner = type.array.base;
		default:
			unreachable();
	}
	expr_rewrite_const_typeid(expr, inner);
	return true;
}

// sema_expr.c:6193 (static)
fn bool sema_create_const_parent(SemaContext* context, Expr* expr, Type* type)
{
	if (!sema_resolve_type_decl(context, type)) return false;
	Type* parent = type_find_parent_type(type.canonical);
	if (!parent) parent = type_void;
	expr_rewrite_const_typeid(expr, parent);
	return true;
}

// sema_expr.c:6202 (static)
fn bool sema_create_const_min(Expr* expr, Type* type, Type* flat)
{
	if (type_is_float(flat))
	{
		expr.expr_kind = CONST;
		expr.const_expr.const_kind = FLOAT;
		expr.type = type;
		expr.resolve_status = DONE;
		expr.const_expr.fxx.type = flat.type_kind;
		switch (flat.type_kind)
		{
			case BF16:
				expr.const_expr.fxx.f = -338953138925153547590470800371487866880.0;
			case F16:
				expr.const_expr.fxx.f = -65504.0;
			case F32:
				expr.const_expr.fxx.f = -(double)float::max;
			case F64:
				expr.const_expr.fxx.f = -double::max;
			case F128:
				// c3c REMINDER("Float 128 not complete")
				expr.const_expr.fxx.f = -double::max;
			default:
				unreachable();
		}
		return true;
	}
	if (type_is_integer(flat))
	{
		expr.expr_kind = CONST;
		expr.const_expr.const_kind = INTEGER;
		expr.const_expr.is_character = false;
		expr.const_expr.is_hex = false;
		expr.type = type;
		expr.resolve_status = DONE;
		expr.const_expr.ixx.type = flat.type_kind;
		switch (flat.type_kind)
		{
			case I8:
				expr.const_expr.ixx.i = (uint128)(int128)ichar::min;
			case I16:
				expr.const_expr.ixx.i = (uint128)(int128)short::min;
			case I32:
				expr.const_expr.ixx.i = (uint128)(int128)int::min;
			case I64:
				expr.const_expr.ixx.i = (uint128)(int128)long::min;
				expr.const_expr.is_hex = true;
			case I128:
				expr.const_expr.ixx.i = (uint128)int128::min;
				expr.const_expr.is_hex = true;
			default:
				expr.const_expr.ixx.i = 0;
		}
		return true;
	}
	unreachable();
}

// sema_expr.c:6272 (static)
fn bool sema_create_const_type_params(Expr* expr, Type* type)
{
	assert(type.type_kind == FUNC_PTR);
	type = type.pointer;
	Signature* sig = type.function.signature;
	int params = (int)sig.params.len;
	Expr*[] param_exprs = {};
	SourceLocId loc = expr.loc;
	for (int i = 0; i < params; i++)
	{
		Decl* decl = sig.params[i];
		Expr* expr_inner = expr_calloc();
		expr_inner.expr_kind = CONST;
		expr_inner.loc = loc;
		expr_inner.const_expr.const_kind = MEMBER;
		expr_inner.const_expr.member.decl = decl;
		expr_inner.const_expr.member.offset = MEMBER_IS_PARAM;
		expr_inner.const_expr.member.align = decl.alignment ? decl.alignment : type_abi_alignment(decl.type);
		expr_inner.resolve_status = DONE;
		expr_inner.type = type_member;
		Expr* expr_ref = expr_calloc();
		expr_ref.loc = loc;
		expr_rewrite_const_reflect(expr_ref, expr_inner);
		@vec_add(&param_exprs, expr_ref);
	}
	expr_rewrite_const_untyped_list(expr, param_exprs);
	return true;
}

// sema_expr.c:6301 (static)
fn bool sema_create_type_param_struct(SemaContext* context, Expr* expr, Decl* fn_decl)
{
	assert(fn_decl.resolve_status == DONE);
	DeclId* ref = fn_decl.decl_kind == FNTYPE ? &fn_decl.fntype_decl.param_struct : &fn_decl.func_decl.param_struct;
	if (*ref)
	{
		expr_rewrite_const_typeid(expr, declptr(*ref).type);
		return true;
	}
	Signature* sig = fn_decl.type.function.signature;
	if (sig.params.len == 0)
	{
		expr_rewrite_const_typeid(expr, type_void);
		return true;
	}
	scratch_buffer_clear();
	scratch_buffer_append("ReflectParamStruct$");
	scratch_buffer_append(fn_decl.type.name);
	Decl* strukt = decl_new_with_type(scratch_buffer_interned(), sourcelocptr(expr.loc), STRUCT);
	strukt.unit = fn_decl.type.function.decl.unit;
	Decl*[] members = {};
	foreach (i, decl : sig.params)
	{
		String name = decl.name;
		if (!name.ptr)
		{
			scratch_buffer_clear();
			scratch_buffer_append("__anon_");
			scratch_buffer_append_unsigned_int((ulong)i);
			name = scratch_buffer_interned();
		}
		Decl* member = decl_new_var_loc(name, sourcelocptr(decl.loc), type_info_new_base(decl.type, decl.loc), MEMBER);
		@vec_add(&members, member);
	}
	strukt.strukt.members = members;
	if (!sema_analyse_decl(context, strukt)) return false;
	*ref = declid(strukt);
	expr_rewrite_const_typeid(expr, strukt.type);
	return true;
}

// sema_expr.c:6342 (static)
fn bool sema_create_const_tags(SemaContext* context, Expr* expr_tags, ResolvedAttrData* resolved_attr)
{
	SourceLocId loc = expr_tags.loc;
	Expr* initializer = expr_new(INITIALIZER_LIST, loc);
	int values = resolved_attr ? (int)resolved_attr.tags.len : 0;
	Expr*[] element_values = {};
	for (ArrayIndex i = 0; i < values; i++)
	{
		Attr* attr = resolved_attr.tags[i];
		Expr* expr = expr_new(CONST, loc);
		ExprConstBytes* bytes = &attr.exprs[0].const_expr.bytes;
		expr_rewrite_const_string_from_raw(expr, (String)bytes.ptr[:bytes.len]);
		@vec_add(&element_values, expr);
	}
	initializer.initializer_list = element_values;
	expr_tags.expr_kind = COMPOUND_LITERAL;
	expr_tags.expr_compound_literal.initializer = initializer;
	expr_tags.expr_compound_literal.type_info = type_info_new_base(type_get_slice(type_string), loc);
	expr_tags.resolve_status = NOT_DONE;
	return sema_analyse_expr_rvalue(context, expr_tags);
}

// sema_expr.c:6363 (static)
fn void sema_create_const_membersof(Expr* expr, Type* type, AlignSize alignment, AlignSize offset)
{
	Decl*[] members = {};
	// c3c: assert(type.canonical == type); -- C assert, compiled out in c3c release builds
	bool no_offset = false;
	switch (type.type_kind)
	{
		case UNION:
		case STRUCT:
		case BITSTRUCT:
			members = type.decl.strukt.members;
		case ENUM:
			members = type.decl.enums.parameters;
			no_offset = true;
		default:
			expr_rewrite_const_untyped_list(expr, {});
			return;
	}
	int count = (int)members.len;
	Expr*[] member_exprs = {};
	for (int i = 0; i < count; i++)
	{
		Decl* decl = members[i];
		Expr* reflect = expr_new(CONST, expr.loc);
		Expr* expr_element = expr_new(CONST, expr.loc);
		expr_element.resolve_status = DONE;
		expr_element.type = type_member;
		expr_element.const_expr = {
			.const_kind = MEMBER,
			.member.decl = decl,
			.member.offset = no_offset ? ~(AlignSize)0 : offset + decl.offset,
			.member.align = alignment
		};
		expr_rewrite_const_reflect(reflect, expr_element);
		@vec_add(&member_exprs, reflect);
	}
	expr_rewrite_const_untyped_list(expr, member_exprs);
}

// sema_expr.c:6404 (static)
fn Expr* create_method_copy(Decl* method, SourceLocId loc)
{
	usz namestr_len = method.name.len;
	String namestr = str_copy(method.name);
	Expr* expr_element = expr_new(CONST, loc);
	expr_element.resolve_status = DONE;
	expr_element.type = type_string;
	expr_element.const_expr = {
		.const_kind = STRING,
		.bytes.ptr = namestr.ptr,
		.bytes.len = (ArrayIndex)namestr_len,
	};
	return expr_element;
}

// sema_expr.c:6419 (static)
fn void append_to_method_list(Decl*[] methods, Expr*[]* method_exprs_ref, SourceLocId loc)
{
	foreach (method : methods)
	{
		if (method.decl_kind == FUNC)
		{
			@vec_add(method_exprs_ref, create_method_copy(method, loc));
		}
	}
}

// sema_expr.c:6430 (static)
fn void sema_append_interface_methods(Decl* interface_, Expr*[]* method_exprs_ref, SourceLocId loc)
{
	append_to_method_list(interface_.interface_methods, method_exprs_ref, loc);
	foreach (type_info : interface_.interfaces)
	{
		sema_append_interface_methods(type_info.type.decl, method_exprs_ref, loc);
	}
}

// sema_expr.c:6438 (static)
fn void append_extension_methods(Type* type, Decl*[] extensions, Expr*[]* method_exprs_ref, SourceLocId loc)
{
	foreach (method : extensions)
	{
		if (method.decl_kind == FUNC && decl_find_method_target(method).type.canonical == type)
		{
			@vec_add(method_exprs_ref, create_method_copy(method, loc));
		}
	}
}

// sema_expr.c:6449 (static)
fn bool sema_create_const_methodsof(SemaContext* context, Expr* expr, Type* type)
{
	Expr*[] method_exprs = {};
	// CONTINUE:
	do
	{
		if (type_is_user_defined(type))
		{
			Decl* decl = type.decl;
			if (!decl.unit || decl.unit.mod.stage < POST_REGISTER)
			{
				bool warn = @sema_warn_at(context, expr.loc, compiler.build.warnings.methods_not_resolved, "Methods are not fully determined for %s at this point.", decl.name);
				if (!warn) return false;
			}
			// Interface, prefer interface methods.
			if (decl.decl_kind == INTERFACE)
			{
				sema_append_interface_methods(decl, &method_exprs, expr.loc);
			}
			// Look through natively defined methods.
			Methods* methods = decl.method_table;
			if (methods) append_to_method_list(methods.methods, &method_exprs, expr.loc);
		}
		else
		{
			append_extension_methods(type, compiler.context.method_extension_list, &method_exprs, expr.loc);
		}
		type = type_find_parent_type(type);
	} while (type);
	expr_rewrite_const_untyped_list(expr, method_exprs);
	return true;
}

// sema_expr.c:6481 (static)
fn bool sema_create_const_max(Expr* expr, Type* type, Type* flat)
{
	if (type_is_integer(flat))
	{
		expr.expr_kind = CONST;
		expr.const_expr.const_kind = INTEGER;
		expr.const_expr.is_character = false;
		expr.type = type;
		expr.const_expr.is_hex = false;
		expr.resolve_status = DONE;
		expr.const_expr.ixx.type = flat.type_kind;
		switch (flat.type_kind)
		{
			case I8:
				expr.const_expr.ixx.i = 0x7F;
			case I16:
				expr.const_expr.ixx.i = 0x7FFF;
			case I32:
				expr.const_expr.ixx.i = 0x7FFFFFFF;
			case I64:
				expr.const_expr.ixx.i = 0x7FFFFFFFFFFFFFFF;
				expr.const_expr.is_hex = true;
			case I128:
				expr.const_expr.ixx.i = (uint128)int128::max;
				expr.const_expr.is_hex = true;
			case U8:
				expr.const_expr.ixx.i = 0xFF;
			case U16:
				expr.const_expr.ixx.i = 0xFFFF;
			case U32:
				expr.const_expr.ixx.i = 0xFFFFFFFF;
			case U64:
				expr.const_expr.ixx.i = 0xFFFFFFFFFFFFFFFF;
				expr.const_expr.is_hex = true;
			case U128:
				expr.const_expr.ixx.i = uint128::max;
				expr.const_expr.is_hex = true;
			default:
				unreachable();
		}
		return true;
	}
	if (type_is_float(flat))
	{
		expr.expr_kind = CONST;
		expr.const_expr.const_kind = FLOAT;
		expr.type = type;
		expr.resolve_status = DONE;
		expr.const_expr.fxx.type = flat.type_kind;
		switch (flat.type_kind)
		{
			case BF16:
				expr.const_expr.fxx.f = 338953138925153547590470800371487866880.0;
			case F16:
				expr.const_expr.fxx.f = 65504.0;
			case F32:
				expr.const_expr.fxx.f = (double)float::max;
			case F64:
				expr.const_expr.fxx.f = double::max;
			case F128:
				// c3c REMINDER("Float 128 not complete")
				expr.const_expr.fxx.f = double::max;
			default:
				unreachable();
		}
		return true;
	}
	unreachable();
}

// sema_expr.c:6566 (static)
fn bool sema_expr_rewrite_typeid_call(Expr* expr, Expr* typeid_, TypeIdInfoKind kind, Type* result_type)
{
	expr.expr_kind = TYPEID_INFO;
	expr.typeid_info_expr.parent = exprid(typeid_);
	expr.typeid_info_expr.kind = kind;
	expr.type = type_add_optional(result_type, @is_optional(typeid_));
	return true;
}

// sema_expr.c:6575 (static)
fn bool sema_expr_rewrite_to_typeid_property(SemaContext* context, Expr* expr, Expr* typeid_, String kw, bool* was_error)
{
	TypeProperty property = type_property_by_name(kw);

	if (sema_cast_const(typeid_))
	{
		Type* type = typeid_.const_expr.typeid_type;
		if (type == null) return false;
		if (!sema_type_property_is_valid_for_type(type, property)) return false;
		*was_error = !sema_expr_rewrite_to_type_property(context, expr, type, property, type);
		return true;
	}
	switch (property)
	{
		case PROPERTY_SIZE:
			return sema_expr_rewrite_typeid_call(expr, typeid_, INFO_SIZEOF, type_sz);
		case PROPERTY_LEN:
			return sema_expr_rewrite_typeid_call(expr, typeid_, INFO_LEN, type_sz);
		case PROPERTY_INNER:
			return sema_expr_rewrite_typeid_call(expr, typeid_, INFO_INNER, type_typeid);
		case PROPERTY_KIND:
			sema_expr_rewrite_typeid_kind(expr, typeid_);
			return true;
		case PROPERTY_PARENT:
			return sema_expr_rewrite_typeid_call(expr, typeid_, INFO_PARENTOF, type_typeid);
		case PROPERTY_NAMES:
			return sema_expr_rewrite_typeid_call(expr, typeid_, INFO_NAMES, type_get_slice(type_string));
		case PROPERTY_ALIGNMENT:
		case PROPERTY_CNAME:
		case PROPERTY_FROM_ORDINAL:
		case PROPERTY_HAS_TAG:
		case PROPERTY_INF:
		case PROPERTY_HAS_EQUALS:
		case PROPERTY_IS_ORDERED:
		case PROPERTY_IS_ANONYMOUS:
		case PROPERTY_IS_NESTED:
		case PROPERTY_IS_SUBSTRUCT:
		case PROPERTY_IS_GENERIC:
		case PROPERTY_LOOKUP_FIELD:
		case PROPERTY_MEMBERS:
		case PROPERTY_METHODS:
		case PROPERTY_MAX:
		case PROPERTY_MIN:
		case PROPERTY_NAME:
		case PROPERTY_NAN:
		case PROPERTY_PARAMS:
		case PROPERTY_PARAM_STRUCT:
		case PROPERTY_QNAME:
		case PROPERTY_RETURNS:
		case PROPERTY_GET_TAG:
		case PROPERTY_VALUES:
		case PROPERTY_TAGS:
		case PROPERTY_GENERIC_ARGS:
		case PROPERTY_GENERIC_QNAME:
		case PROPERTY_NONE:
			// Not supported by dynamic typeid (PROPERTY_NONE included)
			return false;
	}
}

// sema_expr.c:6637 (static)
fn bool sema_expr_fold_to_index(Expr* expr, Expr* parent, SubscriptIndex index_expr)
{
	ConstInitializer* init = parent.const_expr.initializer;
	ConstInitializer* result = (ConstInitializer*)INVALID_PTR;
	assert(!index_expr.start_from_end);
	uint128 i = exprptr(index_expr.expr).const_expr.ixx.i;
	if ((i >> 64) != 0 || (ulong)i > (ulong)max_array_index()) return false;
	ArrayIndex index = (ArrayIndex)(ulong)i;
	switch (init.kind)
	{
		case INIT_ZERO:
			expr_rewrite_to_const_zero(expr, expr.type);
			return true;
		case INIT_STRUCT:
		case INIT_UNION:
		case INIT_VALUE:
		case INIT_ARRAY_VALUE:
			unreachable();
		case INIT_ARRAY:
			result = null;
			foreach (e : init.init_array.elements)
			{
				ArrayIndex idx = e.init_array_value.index;
				if (index != idx) continue;
				result = e.init_array_value.element;
				break;
			}
			if (!result)
			{
				expr_rewrite_to_const_zero(expr, expr.type);
				return true;
			}
		case INIT_ARRAY_FULL:
			result = init.init_array_full[index];
	}
	switch (result.kind)
	{
		case INIT_ZERO:
			expr_rewrite_to_const_zero(expr, expr.type);
		case INIT_ARRAY:
		case INIT_ARRAY_FULL:
		case INIT_STRUCT:
		case INIT_UNION:
			expr.expr_kind = CONST;
			expr.const_expr.const_kind = INITIALIZER;
			expr.const_expr.initializer = result;
			expr.type = type_get_indexed_type(parent.type);
		case INIT_ARRAY_VALUE:
			unreachable();
		case INIT_VALUE:
			expr_replace(expr, result.init_value);
	}
	return true;
}

// sema_expr.c:6697 (static)
fn ConstInitializer* sema_expr_fold_to_struct_member(ConstInitializer* init, Type* parent_type, Decl* member)
{
	Decl* struct_union_decl = type_flatten(parent_type).decl;
	switch (init.kind)
	{
		case INIT_UNION:
			if (struct_union_decl.strukt.members[init.init_union.index] != member) return null;
			return init.init_union.element;
		case INIT_ZERO:
		{
			ConstInitializer* result = (ConstInitializer*)calloc_arena(ConstInitializer::size);
			result.kind = INIT_ZERO;
			result.type = member.type;
			return result;
		}
		case INIT_STRUCT:
			break;
		case INIT_VALUE:
		case INIT_ARRAY:
		case INIT_ARRAY_FULL:
		case INIT_ARRAY_VALUE:
			unreachable();
	}
	assert(init.kind == INIT_STRUCT);
	foreach (i, other_member : struct_union_decl.strukt.members)
	{
		if (other_member == member)
		{
			return init.init_struct[i];
		}
		if (!other_member.name.ptr)
		{
			ConstInitializer* init_other = sema_expr_fold_to_struct_member(init.init_struct[i], other_member.type, member);
			if (init_other) return init_other;
		}
	}
	return null;
}

// sema_expr.c:6737 (static)
fn bool sema_expr_fold_to_member(Expr* expr, Expr* parent, Decl* member)
{
	ConstInitializer* init = parent.const_expr.initializer;
	ConstInitializer* result;
	switch (init.kind)
	{
		case INIT_ZERO:
			result = init;
		case INIT_STRUCT:
		case INIT_UNION:
			result = sema_expr_fold_to_struct_member(init, parent.type, member);
			if (!result) return false;
		case INIT_VALUE:
		case INIT_ARRAY:
		case INIT_ARRAY_FULL:
		case INIT_ARRAY_VALUE:
			unreachable();
	}
	// EVAL:
	switch (result.kind)
	{
		case INIT_ZERO:
			if (member.type.type_kind == FLEXIBLE_ARRAY) return false;
			expr_rewrite_to_const_zero(expr, member.type);
		case INIT_STRUCT:
		case INIT_UNION:
		case INIT_ARRAY:
		case INIT_ARRAY_FULL:
			expr.expr_kind = CONST;
			expr.const_expr.const_kind = INITIALIZER;
			expr.const_expr.initializer = result;
			expr.type = member.type;
		case INIT_ARRAY_VALUE:
			unreachable();
		case INIT_VALUE:
			expr_replace(expr, result.init_value);
	}
	return true;
}

// sema_expr.c:6784 (static)
fn bool sema_type_property_is_valid_for_type(CanonicalType* original_type, TypeProperty property)
{
	switch (original_type.type_kind)
	{
		case TYPEINFO:
		case INFERRED_ARRAY:
		case INFERRED_VECTOR:
		case POISONED:
		case MEMBER:
		case WILDCARD:
		case REFLECTION:
			return false;
		default:
			break;
	}
	CanonicalType* type = type_flatten(original_type);
	switch (property)
	{
		case PROPERTY_NONE:
			return false;
		case PROPERTY_INF:
		case PROPERTY_NAN:
			return type_is_float(type);
		case PROPERTY_INNER:
			switch (original_type.type_kind)
			{
				case POINTER:
				case OPTIONAL:
				case TYPEDEF:
				case ENUM:
				case CONSTSET:
				case BITSTRUCT:
				case ARRAY:
				case FLEXIBLE_ARRAY:
				case SLICE:
				case INFERRED_ARRAY:
				case VECTOR:
				case INFERRED_VECTOR:
				case SIMD_VECTOR:
					return true;
				default:
					return false;
			}
		case PROPERTY_SIZE:
		case PROPERTY_ALIGNMENT:
			return type.type_kind != UNTYPEDLIST;
		case PROPERTY_KIND:
		case PROPERTY_NAME:
		case PROPERTY_QNAME:
		case PROPERTY_PARENT:
		case PROPERTY_IS_ORDERED:
		case PROPERTY_HAS_EQUALS:
			return true;
		case PROPERTY_IS_SUBSTRUCT:
			return type.type_kind == STRUCT;
		case PROPERTY_LEN:
			if (original_type.type_kind == CONSTSET) return true;
			switch (type.type_kind)
			{
				case ARRAY:
				case VECTOR:
				case SIMD_VECTOR:
				case ENUM:
					return true;
				default:
					return false;
			}
		case PROPERTY_LOOKUP_FIELD:
			return type.type_kind == ENUM;
		case PROPERTY_MIN:
		case PROPERTY_MAX:
			return type_is_float(type) || type_is_integer(type);
		case PROPERTY_FROM_ORDINAL:
		case PROPERTY_NAMES:
		case PROPERTY_VALUES:
			return type.type_kind == ENUM || original_type.canonical.type_kind == CONSTSET;
		case PROPERTY_IS_ANONYMOUS:
		case PROPERTY_IS_NESTED:
			switch (type.type_kind)
			{
				case STRUCT:
				case UNION:
				case BITSTRUCT:
					return true;
				default:
					return false;
			}
		case PROPERTY_MEMBERS:
			switch (type.type_kind)
			{
				case STRUCT:
				case UNION:
				case BITSTRUCT:
				case ENUM:
					return true;
				default:
					return false;
			}
		case PROPERTY_METHODS:
			switch (type.type_kind)
			{
				case VOID:
				case FUNC_RAW:
				case ALIAS:
				case TYPEINFO:
				case INFERRED_ARRAY:
				case INFERRED_VECTOR:
				case POISONED:
				case MEMBER:
				case WILDCARD:
				case REFLECTION:
				case OPTIONAL:
					return false;
				default:
					return true;
			}
		case PROPERTY_PARAMS:
		case PROPERTY_PARAM_STRUCT:
		case PROPERTY_RETURNS:
			return type_is_func_ptr(type);
		case PROPERTY_GET_TAG:
		case PROPERTY_HAS_TAG:
		case PROPERTY_TAGS:
		case PROPERTY_GENERIC_ARGS:
		case PROPERTY_GENERIC_QNAME:
		case PROPERTY_IS_GENERIC:
			return true;
		case PROPERTY_CNAME:
			return !type_is_builtin(original_type.canonical.type_kind);
	}
}

// sema_expr.c:6902 (static)
fn bool sema_expr_rewrite_to_type_property(SemaContext* context, Expr* expr, Type* type, TypeProperty property, Type* parent_type)
{
	assert(type == type.canonical);
	assert(sema_type_property_is_valid_for_type(type, property));
	Type* flat = type_flatten(type);
	if (type.type_kind == FUNC_RAW) type = type_get_func_ptr(type);
	switch (property)
	{
		case PROPERTY_INF:
			assert(type_is_float(flat));
			expr.expr_kind = CONST;
			expr.const_expr.const_kind = FLOAT;
			expr.const_expr.fxx = { double::inf, flat.type_kind };
			expr.type = type;
			expr.resolve_status = DONE;
			return true;
		case PROPERTY_IS_ANONYMOUS:
			expr_rewrite_const_bool(expr, type_bool, flat.decl.strukt.parent != 0);
			return true;
		case PROPERTY_IS_NESTED:
			expr_rewrite_const_bool(expr, type_bool, flat == null);
			return true;
		case PROPERTY_IS_ORDERED:
			return sema_expr_rewrite_to_is_ordered(context, expr, type);
		case PROPERTY_HAS_EQUALS:
			return sema_expr_rewrite_to_has_equals(context, expr, type);
		case PROPERTY_IS_SUBSTRUCT:
			expr_rewrite_const_bool(expr, type_bool, type_is_substruct(flat));
			return true;
		case PROPERTY_GENERIC_QNAME:
			return sema_expr_rewrite_to_generic_qname(context, expr, type);
		case PROPERTY_GENERIC_ARGS:
			return sema_expr_rewrite_to_generic_args(context, expr, type);
		case PROPERTY_INNER:
			return sema_create_const_inner(context, expr, type);
		case PROPERTY_PARENT:
			return sema_create_const_parent(context, expr, type);
		case PROPERTY_KIND:
			return sema_create_const_kind(context, expr, type);
		case PROPERTY_LEN:
			return sema_create_const_len(expr, type, flat);
		case PROPERTY_MIN:
			return sema_create_const_min(expr, type, flat);
		case PROPERTY_MAX:
			return sema_create_const_max(expr, type, flat);
		case PROPERTY_NAMES:
			if (type.type_kind == CONSTSET)
			{
				return sema_expr_replace_with_enum_name_array(context, expr, type.decl);
			}
			assert(flat.type_kind == ENUM);
			return sema_expr_replace_with_enum_name_array(context, expr, flat.decl);
		case PROPERTY_VALUES:
			if (type.type_kind == CONSTSET)
			{
				return sema_expr_replace_with_const_enum_array(context, expr, type.decl);
			}
			assert(flat.type_kind == ENUM);
			return sema_expr_replace_with_enum_array(context, expr, flat.decl);
		case PROPERTY_NAN:
			assert(type_is_float(flat));
			expr.expr_kind = CONST;
			expr.const_expr.const_kind = FLOAT;
			expr.const_expr.fxx = { double::nan, flat.type_kind };
			expr.type = type;
			expr.resolve_status = DONE;
			return true;
		case PROPERTY_MEMBERS:
		{
			AlignSize align;
			if (!sema_set_alignment(context, parent_type, &align, false)) return false;
			sema_create_const_membersof(expr, flat, align, 0);
			return true;
		}
		case PROPERTY_METHODS:
			return sema_create_const_methodsof(context, expr, type);
		case PROPERTY_PARAMS:
			return sema_create_const_type_params(expr, flat);
		case PROPERTY_PARAM_STRUCT:
			assert(type.type_kind == FUNC_PTR);
			return sema_create_type_param_struct(context, expr, flat.pointer.decl);
		case PROPERTY_RETURNS:
			expr_rewrite_const_typeid(expr, type_infoptr(flat.pointer.function.signature.rtype).type);
			return true;
		case PROPERTY_SIZE:
			if (!sema_resolve_type_decl(context, type)) return false;
			expr_rewrite_const_int(expr, type_sz, (ulong)type_size(type));
			return true;
		case PROPERTY_NAME:
			return sema_expr_rewrite_to_type_nameof(context, expr, type, 0);
		case PROPERTY_QNAME:
			return sema_expr_rewrite_to_type_nameof(context, expr, type, 1);
		case PROPERTY_ALIGNMENT:
		{
			AlignSize align;
			if (!sema_set_alignment(context, type, &align, false)) return false;
			expr_rewrite_const_int(expr, type_sz, (ulong)align);
			return true;
		}
		case PROPERTY_CNAME:
			assert(!type_is_builtin(type.type_kind));
			return sema_expr_rewrite_to_type_nameof(context, expr, type, 2);
		case PROPERTY_TAGS:
			if (!type_is_user_defined(type))
			{
				return @sema_error_at(context, expr.loc, "'tags' is not defined for builtin types like %s.", type_quoted_error_string(type));
			}
			if (!sema_resolve_type_decl(context, type)) return false;
			return sema_create_const_tags(context, expr, type.decl.attrs_resolved);
		case PROPERTY_GET_TAG:
			if (!type_is_user_defined(type))
			{
				return @sema_error_at(context, expr.loc, "'get_tag' is not defined for builtin types like %s.", type_quoted_error_string(type));
			}
			nextcase PROPERTY_HAS_TAG;
		case PROPERTY_HAS_TAG:
		case PROPERTY_IS_GENERIC:
			if (!type_is_user_defined(type))
			{
				expr.expr_kind = TYPECALL;
				expr.type_call_expr = {
					.type = null,
					.property = property };
				return true;
			}
			nextcase PROPERTY_FROM_ORDINAL;
		case PROPERTY_FROM_ORDINAL:
		case PROPERTY_LOOKUP_FIELD:
			// TYPE_CALL:
			expr.expr_kind = TYPECALL;
			expr.type_call_expr = {
				.type = type.type_kind == FUNC_PTR
						? type.pointer.function.decl
						: type.decl,
				.property = property };
			return true;
		case PROPERTY_NONE:
			return false;
	}
}


