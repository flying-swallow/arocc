// Port of the parser-facing part of c3c src/compiler/expr.c (expr_new*,
// expr_new_const_*, expr_new_binary, expr_is_runtime_const, expr_rewrite_*
// helpers that need no sema) plus the Expr inline helpers of
// compiler_internal.h (expr_ok, expr_poison, expr_new_expr, expr_is_const_*,
// expr_set_loc, expr_rewrite_const_*, ...).
//
// Not ported yet (sema): expr_is_zero, expr_is_pure, expr_is_simple,
// expr_rewrite_to_const_zero, expr_from_const_expr_at_index,
// expr_rewrite_to_const_initializer_index, the expr_const_* comparisons and
// expr_rewrite_int_to_bool (needs expr_is_zero).
//
// Deviations from c3c:
// - Integer constants are `Int { uint128 i; TypeKind type; }`: c3c's
//   `i.high` / `i.low` updates become uint128 operations.
// - c3c's ARENA_DEF `expr_copy` is `expr_copy` here, a wrapper over ast.c3's
//   `expr_copy_node` (copying.c's deep `copy_expr` is a separate port).
// - `goto RETRY` loops are `while (true)` loops.
module aro::frontend::c3::compiler;

fn Expr* expr_copy(Expr* source) => expr_copy_node(source);

fn String expr_kind_to_string(ExprKind kind)
{
	switch (kind)
	{
		case ACCESS_UNRESOLVED: return "access_unresolved";
		case ACCESS_RESOLVED: return "access_resolved";
		case ASM: return "asm";
		case BENCHMARK_HOOK: return "benchmark_hook";
		case BINARY: return "binary";
		case BITACCESS: return "bitaccess";
		case BITASSIGN: return "bitassign";
		case BUILTIN: return "builtin";
		case BUILTIN_ACCESS: return "builtin_access";
		case CALL: return "call";
		case CAST: return "cast";
		case CATCH: return "catch_unwrap";
		case CATCH_UNRESOLVED: return "catch_unresolved";
		case COMPILER_CONST: return "compiler_const";
		case COMPOUND_LITERAL: return "compound_litera";
		case COND: return "cond";
		case CONST: return "const";
		case TYPECALL: return "typecall";
		case VAARG: return "vaarg";
		case VACOUNT: return "vacount";
		case CT_FEATURE: return "ct_feature";
		case CT_DEFINED: return "ct_defined";
		case CT_EVAL: return "ct_eval";
		case CT_IDENT: return "ct_ident";
		case DECL: return "decl";
		case DEFAULT_ARG: return "default_arg";
		case DESIGNATED_INITIALIZER_LIST: return "designated_initializer_list";
		case DESIGNATOR: return "designator";
		case DISCARD: return "discard";
		case EMBED: return "embed";
		case VECTOR_TO_ARRAY: return "vector_to_array";
		case SLICE_TO_VEC_ARRAY: return "slice_to_vec_array";
		case SCALAR_TO_VECTOR: return "scalar_to_vector";
		case EXPRESSION_LIST: return "expression_list";
		case FORCE_UNWRAP: return "force_unwrap";
		case FLOAT_TO_INT: return "float_to_int";
		case GENERIC_IDENT: return "generic_ident";
		case HASH_IDENT: return "hash_ident";
		case IDENTIFIER: return "identifier";
		case UNRESOLVED_IDENTIFIER: return "unresolved_identifier";
		case INITIALIZER_LIST: return "initializer_list";
		case INT_TO_FLOAT: return "int_to_float";
		case INT_TO_PTR: return "int_to_ptr";
		case PTR_TO_INT: return "ptr_to_int";
		case LAMBDA: return "lambda";
		case LAST_FAULT: return "last_fault";
		case MACRO_BLOCK: return "macro_block";
		case MACRO_BODY: return "macro_body";
		case MACRO_BODY_EXPANSION: return "macro_body_expansion";
		case MAKE_ANY: return "make_any";
		case MAKE_SLICE: return "make_slice";
		case MEMBER_GET: return "member_get";
		case MEMBER_SET: return "member_set";
		case NAMED_ARGUMENT: return "named_argument";
		case NAMED_EVAL_ARGUMENT: return "named_eval_argument";
		case NOP: return "nop";
		case OPERATOR_CHARS: return "operator_chars";
		case OPTIONAL: return "optional";
		case ENUM_FROM_ORD: return "enum_from_ord";
		case OTHER_CONTEXT: return "other_context";
		case POINTER_OFFSET: return "pointer_offset";
		case ADDR_CONVERSION: return "addr_conversion";
		case POISONED: return "poisoned";
		case PTR_ACCESS: return "ptr_access";
		case POST_UNARY: return "post_unary";
		case RETHROW: return "rethrow";
		case RETVAL: return "retval";
		case RVALUE: return "rvalue";
		case RECAST: return "recast";
		case SLICE: return "slice";
		case SLICE_LEN: return "slice_len";
		case SLICE_ASSIGN: return "slice_assign";
		case SLICE_COPY: return "slice_copy";
		case SPLAT: return "splat";
		case STRINGIFY: return "stringify";
		case SUBSCRIPT: return "subscript";
		case SUBSCRIPT_ADDR: return "subscript_addr";
		case SUBSCRIPT_ASSIGN: return "subscript_assign";
		case SWIZZLE: return "swizzle";
		case TERNARY: return "ternary";
		case TEST_HOOK: return "test_hook";
		case TRY: return "try";
		case TRY_UNRESOLVED: return "try_unresolved";
		case TRY_UNWRAP_CHAIN: return "try_unwrap_chain";
		case TYPEID: return "typeid";
		case TYPEID_INFO: return "typeid_info";
		case TYPEINFO: return "typeinfo";
		case UNARY: return "unary";
		case VASPLAT: return "vasplat";
		case VECTOR_FROM_ARRAY: return "vector_from_array";
		case EXT_TRUNC: return "ext_trunc";
		case INT_TO_BOOL: return "int_to_bool";
		default: return "???";
	}
}

fn Expr* expr_negate_expr(Expr* expr)
{
	if (expr.expr_kind == UNARY && expr.unary_expr.operator == NEG)
	{
		return expr.inner_expr;
	}
	Expr* neg = expr_new_expr(UNARY, expr);
	neg.unary_expr = { .operator = NEG, .expr = expr };
	return neg;
}

fn bool expr_in_int_range(Expr* expr, long low, long high)
{
	assert(expr_is_const(expr) && expr.const_expr.const_kind == INTEGER);
	Int val = expr.const_expr.ixx;
	if (!int_fits(val, I64)) return false;
	long value = int_to_i64(val);
	return value >= low && value <= high;
}

fn bool expr_is_unwrapped_ident(Expr* expr)
{
	if (expr.expr_kind != IDENTIFIER) return false;
	Decl* decl = expr.ident_expr;
	if (decl.decl_kind != VAR) return false;
	return decl.var_decl.kind == UNWRAPPED && type_is_optional(decl.var_decl.alias_decl.type);
}

fn bool expr_is_runtime_const(Expr* expr)
{
	assert(expr.resolve_status == DONE);
	while (true)
	{
		switch (expr.expr_kind)
		{
			case POINTER_OFFSET:
				return exprid_is_runtime_const(expr.pointer_offset_expr.ptr) && exprid_is_runtime_const(expr.pointer_offset_expr.offset);
			case SWIZZLE:
			case RETVAL:
			case BUILTIN:
			case CT_EVAL:
			case BENCHMARK_HOOK:
			case TEST_HOOK:
			case BITASSIGN:
			case TYPECALL:
			case BINARY:
			case OPERATOR_CHARS:
			case STRINGIFY:
			case CT_DEFINED:
			case CT_REFLECT:
			case LAMBDA:
			case DECL:
			case CALL:
			case CATCH:
			case TRY:
			case TRY_UNWRAP_CHAIN:
			case POST_UNARY:
			case SLICE_ASSIGN:
			case SLICE_COPY:
			case SPLAT:
			case MACRO_BLOCK:
			case RETHROW:
			case MEMBER_GET:
			case MEMBER_SET:
			case BITACCESS:
			case COND:
			case PTR_ACCESS:
			case INT_TO_FLOAT:
			case FLOAT_TO_INT:
			case SLICE_LEN:
			case TWO:
				return false;
			case MACRO_BODY_EXPANSION:
				foreach (d : expr.body_expansion_expr.declarations)
				{
					switch (d.var_decl.kind)
					{
						case PARAM_CT:
						case PARAM_CT_TYPE:
						case PARAM_EXPR:
							break;
						default:
							return false;
					}
				}
				if (!expr.body_expansion_expr.first_stmt) return true;
				return ast_is_compile_time(astptr(expr.body_expansion_expr.first_stmt));
			case TRY_UNRESOLVED: case ACCESS_UNRESOLVED: case CATCH_UNRESOLVED: case UNRESOLVED_IDENTIFIER:
			case CAST: case TYPEID: case EMBED: case VASPLAT: case OTHER_CONTEXT: case VACOUNT: case VAARG:
			case IOTA_DECL: case LENGTHOF: case CT_IDENT: case TYPE_PROPERTY: case GENERIC_IDENT:
			case COMPOUND_LITERAL: case MACRO_BODY: case CT_SUBSCRIPT:
				unreachable();
			case VECTOR_FROM_ARRAY:
			case RVALUE:
			case RECAST:
			case ADDR_CONVERSION:
			case DISCARD:
			case INT_TO_PTR:
			case PTR_TO_INT:
			case ENUM_FROM_ORD:
			case VECTOR_TO_ARRAY:
			case SLICE_TO_VEC_ARRAY:
			case SCALAR_TO_VECTOR:
			case MAYBE_DEREF:
				return expr_is_runtime_const(expr.inner_expr);
			case MAKE_SLICE:
				expr = expr.make_slice_expr.ptr;
				if (!expr) return true;
			case MAKE_ANY:
				if (!expr_is_runtime_const(expr.make_any_expr.typeid_expr)) return false;
				expr = expr.make_any_expr.inner;
			case ACCESS_RESOLVED:
				expr = expr.access_resolved_expr.parent;
			case BUILTIN_ACCESS:
				return exprid_is_runtime_const(expr.builtin_access_expr.inner);
			case INT_TO_BOOL:
				return expr_is_const(expr.int_to_bool_expr.inner);
			case EXT_TRUNC:
				return expr_is_runtime_const(expr.ext_trunc_expr.inner);
			case CONST:
			case NOP:
				return true;
			case DESIGNATOR:
				expr = expr.designator_expr.value;
				if (!expr) return true;
			case IDENTIFIER:
				Decl* ident = decl_flatten(expr.ident_expr);
				if (ident.decl_kind != VAR) return true;
				switch (ident.var_decl.kind)
				{
					case CONST:
						if (ident.is_extern) return false;
						expr = ident.var_decl.init_expr;
					case PARAM_CT_TYPE:
					case LOCAL_CT_TYPE:
					case LOCAL_CT:
					case PARAM_CT:
						return true;
					default:
						return false;
				}
			case EXPRESSION_LIST:
				return expr_list_is_constant_eval(expr.expression_list);
			case TYPEID_INFO:
				expr = exprptr(expr.typeid_info_expr.parent);
			case OPTIONAL:
				expr = expr.inner_expr;
			case DEFAULT_ARG:
				expr = expr.default_arg_expr.inner;
			case INITIALIZER_LIST:
				return expr_list_is_constant_eval(expr.initializer_list);
			case DESIGNATED_INITIALIZER_LIST:
				return (!expr.designated_init.splat || expr_is_const(expr.designated_init.splat)) && expr_list_is_constant_eval(expr.designated_init.list);
			case SLICE:
				if (!exprid_is_runtime_const(expr.slice_expr.expr)) return false;
				return expr.slice_expr.range.range_type == CONST_RANGE;
			case SUBSCRIPT:
				if (!exprid_is_runtime_const(expr.subscript_expr.index.expr)) return false;
				expr = exprptr(expr.subscript_expr.expr);
			case SUBSCRIPT_ADDR:
				return expr_subscript_addr_is_constant_eval(expr);
			case TERNARY:
				assert(!exprid_is_runtime_const(expr.ternary_expr.cond) && !expr.ternary_expr.is_const);
				return false;
			case FORCE_UNWRAP:
			case LAST_FAULT:
				return false;
			case UNARY:
				switch (expr.unary_expr.operator)
				{
					case DEREF:
					case ERROR:
						return false;
					case ADDR:
						return expr_addr_is_constant_eval(expr.unary_expr.expr);
					case TADDR:
						expr = expr.unary_expr.expr;
					case PLUS:
					case NEG:
					case BITNEG:
					case NOT:
						expr = expr.unary_expr.expr;
					case INC:
					case DEC:
						return false;
				}
			case COMPILER_CONST:
				// Not foldable
				return false;
			case CT_FEATURE:
			case TYPEINFO:
			case HASH_IDENT:
			case POISONED:
			case ASM:
			case SUBSCRIPT_ASSIGN:
			case NAMED_ARGUMENT:
			case NAMED_EVAL_ARGUMENT:
			case CONTRACT:
				unreachable();
		}
	}
}

fn bool expr_list_is_constant_eval(Expr*[] exprs)
{
	foreach (expr : exprs)
	{
		if (!expr_is_runtime_const(expr) || type_is_optional(expr.type)) return false;
	}
	return true;
}

fn bool expr_subscript_addr_is_constant_eval(Expr* subscript)
{
	if (!exprid_is_runtime_const(subscript.subscript_expr.index.expr)) return false;
	Expr* parent = exprptr(subscript.subscript_expr.expr);
	switch (type_flatten(parent.type).type_kind)
	{
		case POINTER:
			return expr_is_runtime_const(parent);
		case SLICE:
			return false;
		default:
			return expr_addr_is_constant_eval(parent);
	}
}

fn bool expr_addr_is_constant_eval(Expr* inner)
{
	if (type_is_optional(inner.type)) return false;
	while (true)
	{
		switch (inner.expr_kind)
		{
			case TRY_UNRESOLVED: case ACCESS_UNRESOLVED: case CATCH_UNRESOLVED: case UNRESOLVED_IDENTIFIER:
			case CAST: case TYPEID: case EMBED: case VASPLAT: case OTHER_CONTEXT: case VACOUNT: case VAARG:
			case IOTA_DECL: case LENGTHOF: case CT_IDENT: case TYPE_PROPERTY: case GENERIC_IDENT:
			case COMPOUND_LITERAL: case MACRO_BODY: case CT_SUBSCRIPT:
				unreachable();
			case ACCESS_RESOLVED:
				inner = inner.access_resolved_expr.parent;
			case SUBSCRIPT:
				return expr_subscript_addr_is_constant_eval(inner);
			case UNARY:
				if (inner.unary_expr.operator != DEREF) return false;
				return expr_is_runtime_const(inner.unary_expr.expr);
			case CONST:
			case INITIALIZER_LIST:
			case DESIGNATED_INITIALIZER_LIST:
				// We can't create temporaries as const locally or making them into compile time constants.
				return expr_is_runtime_const(inner);
			case IDENTIFIER:
				// The address of an identifier is side effect free.
				Decl* decl = inner.ident_expr;
				return decl_is_global_ref(decl);
			default:
				return false;
		}
	}
}

fn void expr_rewrite_two(Expr* original, Expr* first, Expr* second)
{
	original.expr_kind = TWO;
	original.two_expr.first = first;
	original.two_expr.last = second;
	original.resolve_status = NOT_DONE;
}

fn Expr* expr_new_two(Expr* first, Expr* second)
{
	Expr* expr = expr_new_expr(TWO, first);
	expr.two_expr.first = first;
	expr.two_expr.last = second;
	return expr;
}

fn void expr_insert_addr(Expr* original)
{
	assert(original.resolve_status == DONE);
	Type* type = original.type;
	bool optional = type_is_optional(type);
	Type* new_type = type_add_optional(type_get_ptr(type_no_optional(type)), optional);
	if (original.expr_kind == UNARY && original.unary_expr.operator == DEREF)
	{
		*original = *original.unary_expr.expr;
		original.type = new_type;
		return;
	}
	Expr* inner = expr_copy(original);
	original.expr_kind = UNARY;
	original.type = new_type;
	original.unary_expr = { .operator = ADDR, .expr = inner, .no_wrap = false, .no_read = false };
}

fn Expr* expr_generate_decl(Decl* decl, Expr* assign)
{
	assert(decl.decl_kind == VAR);
	assert(decl.var_decl.init_expr == null);
	Expr* expr_decl = expr_new(DECL, decl.loc);
	expr_decl.decl_expr = decl;
	if (!assign) decl.var_decl.no_init = true;
	decl.var_decl.init_expr = assign;
	expr_decl.type = decl.type;
	assert(decl.type != null);
	assert(assign.type != null);
	return expr_decl;
}

fn Expr* expr_new_binary(SourceLocId loc, Expr* left, Expr* right, BinaryOp op)
{
	Expr* expr = expr_calloc();
	expr.expr_kind = BINARY;
	expr.loc = loc;
	expr.binary_expr.operator = op;
	expr.binary_expr.left = exprid(left);
	expr.binary_expr.right = exprid(right);
	return expr;
}

fn Expr* expr_new_cond(Expr* expr)
{
	Expr* cond = expr_new(COND, expr.loc);
	@vec_add(&cond.cond_expr, expr);
	return cond;
}

fn Expr* expr_new_loc(ExprKind kind, SourceLoc* start)
{
	Expr* expr = expr_calloc();
	expr.expr_kind = kind;
	expr.loc = make_loc(*start);
	return expr;
}

fn Expr* expr_new(ExprKind kind, SourceLocId start)
{
	Expr* expr = expr_calloc();
	expr.expr_kind = kind;
	expr.loc = start;
	return expr;
}

fn Expr* expr_new_const_int(SourceLocId loc, Type* type, ulong v)
{
	Expr* expr = expr_calloc();
	expr.expr_kind = CONST;
	expr.loc = loc;
	expr.type = type;
	TypeKind kind = type_flatten(type).type_kind;
	uint128 i = v;
	if (type_kind_is_signed(kind))
	{
		if (v > (ulong)long::max) i |= (uint128)ulong::max << 64;
	}
	expr.const_expr.ixx.i = i;
	expr.const_expr.ixx.type = kind;
	expr.const_expr.is_character = false;
	expr.const_expr.const_kind = INTEGER;
	expr.resolve_status = DONE;
	return expr;
}

fn Expr* expr_new_const_float(SourceLocId loc, Type* type, Real v)
{
	Expr* expr = expr_calloc();
	expr.expr_kind = CONST;
	expr.loc = loc;
	expr.type = type;
	TypeKind kind = type_flatten(type).type_kind;
	expr.const_expr.fxx.f = v;
	expr.const_expr.fxx.type = kind;
	expr.const_expr.const_kind = FLOAT;
	expr.resolve_status = DONE;
	return expr;
}

fn Expr* expr_new_const_typeid(SourceLocId loc, Type* type)
{
	Expr* expr = expr_calloc();
	expr.expr_kind = CONST;
	expr.loc = loc;
	expr.type = type_typeid;
	expr.const_expr.const_kind = TYPEID;
	expr.const_expr.typeid_type = type;
	expr.resolve_status = DONE;
	return expr;
}

fn Expr* expr_new_expr_list_resolved(SourceLocId loc, Type* type, Expr*[] expressions)
{
	Expr* expr = expr_calloc();
	expr.expr_kind = EXPRESSION_LIST;
	expr.loc = loc;
	expr.type = type;
	expr.resolve_status = DONE;
	expr.expression_list = expressions;
	return expr;
}

fn Expr* expr_new_const_initializer(SourceLocId loc, Type* type, ConstInitializer* initializer)
{
	Expr* expr = expr_calloc();
	expr.expr_kind = CONST;
	expr.loc = loc;
	expr.type = type;
	expr.const_expr.initializer = initializer;
	expr.const_expr.const_kind = INITIALIZER;
	expr.resolve_status = DONE;
	return expr;
}

fn Expr* expr_new_const_bool(SourceLocId loc, Type* type, bool value)
{
	Expr* expr = expr_calloc();
	expr.expr_kind = CONST;
	expr.loc = loc;
	expr.type = type;
	assert(type_flatten(type).type_kind == BOOL);
	expr.const_expr.b = value;
	expr.const_expr.const_kind = BOOL;
	expr.resolve_status = DONE;
	return expr;
}

fn Expr* expr_new_const_null(SourceLocId loc, Type* type)
{
	Expr* expr = expr_calloc();
	expr.expr_kind = CONST;
	expr.loc = loc;
	expr.type = type;
	assert(type_flatten(type).type_kind == POINTER);
	expr.const_expr.ptr = 0;
	expr.const_expr.const_kind = POINTER;
	expr.resolve_status = DONE;
	return expr;
}

fn Expr* expr_new_const_string(SourceLocId loc, String string)
{
	Expr* expr = expr_calloc();
	expr.expr_kind = CONST;
	expr.loc = loc;
	expr.type = type_string;
	expr.const_expr.const_kind = STRING;
	expr.const_expr.bytes.ptr = string.ptr;
	expr.const_expr.bytes.len = (ArrayIndex)string.len;
	expr.resolve_status = DONE;
	return expr;
}

fn void expr_rewrite_to_builtin_access(Expr* expr, Expr* parent, BuiltinAccessKind kind, Type* type)
{
	expr.expr_kind = BUILTIN_ACCESS;
	expr.builtin_access_expr.kind = kind;
	expr.builtin_access_expr.inner = exprid(parent);
	expr.type = type_add_optional(type, type_is_optional(parent.type));
	expr.resolve_status = DONE;
}

fn Expr* expr_variable(Decl* decl)
{
	if (decl.resolve_status == DONE)
	{
		Expr* expr = expr_new(IDENTIFIER, decl.loc);
		expr_resolve_ident(expr, decl);
		return expr;
	}
	Expr* expr = expr_new(UNRESOLVED_IDENTIFIER, decl.loc);
	expr.unresolved_ident_expr = { .ident = decl.name };
	expr.resolve_status = NOT_DONE;
	return expr;
}

fn void expr_rewrite_const_ref(Expr* expr_to_rewrite, Decl* decl)
{
	expr_to_rewrite.const_expr = { .global_ref = decl, .const_kind = REF };
	expr_to_rewrite.expr_kind = CONST;
}

fn void expr_rewrite_const_string(Expr* expr_to_rewrite, String string, ArrayIndex len)
{
	expr_to_rewrite.expr_kind = CONST;
	expr_to_rewrite.const_expr.const_kind = STRING;
	expr_to_rewrite.const_expr.bytes.ptr = string.ptr;
	expr_to_rewrite.const_expr.bytes.len = len;
	expr_to_rewrite.resolve_status = DONE;
	expr_to_rewrite.type = type_string;
}

fn void expr_rewrite_const_string_from_raw(Expr* expr_to_rewrite, String string)
{
	expr_rewrite_const_string(expr_to_rewrite, string, (ArrayIndex)string.len);
}

fn void expr_rewrite_to_binary(Expr* expr_to_rewrite, Expr* left, Expr* right, BinaryOp op)
{
	expr_to_rewrite.binary_expr = { .operator = op, .left = exprid(left), .right = exprid(right), .grouped = false };
	expr_to_rewrite.expr_kind = BINARY;
}

// ---------------------------------------------------------------------------
// Inline helpers (compiler_internal.h)

fn bool expr_is_deref(Expr* expr) => expr.expr_kind == UNARY && expr.unary_expr.operator == DEREF;

fn bool expr_is_named_param(Expr* expr) => expr.expr_kind == NAMED_ARGUMENT || expr.expr_kind == NAMED_EVAL_ARGUMENT;

fn bool expr_is_plain_identifier(Expr* expr)
{
	return expr.expr_kind == UNRESOLVED_IDENTIFIER
	       && !expr.unresolved_ident_expr.is_const
	       && !expr.unresolved_ident_expr.path;
}

fn bool expr_is_addr(Expr* expr) => expr.expr_kind == UNARY && expr.unary_expr.operator == ADDR;

fn bool expr_is_any_addr(Expr* expr)
{
	if (expr.expr_kind != UNARY) return false;
	switch (expr.unary_expr.operator)
	{
		case ADDR:
		case TADDR:
			return true;
		default:
			return false;
	}
}

fn bool expr_is_mult(Expr* expr) => expr.expr_kind == BINARY && expr.binary_expr.operator == MULT;

fn bool expr_is_neg(Expr* expr) => expr.expr_kind == UNARY && expr.unary_expr.operator == NEG;

fn bool expr_is_init_list(Expr* expr)
{
	ExprKind kind = expr.expr_kind;
	return kind == DESIGNATED_INITIALIZER_LIST || kind == INITIALIZER_LIST;
}

fn bool exprid_is_runtime_const(ExprId expr) => expr ? expr_is_runtime_const(exprptr(expr)) : true;

fn bool expr_poison(Expr* expr)
{
	expr.expr_kind = POISONED;
	expr.resolve_status = DONE;
	return false;
}

fn void const_init_set_span(ConstInitializer* init, SourceLocId loc)
{
	while (true)
	{
		switch (init.kind)
		{
			case INIT_ZERO:
				return;
			case INIT_STRUCT:
				foreach (init_val : init.init_struct) const_init_set_span(init_val, loc);
				return;
			case INIT_UNION:
				init = init.init_union.element;
			case INIT_VALUE:
				expr_set_loc(init.init_value, loc);
				return;
			case INIT_ARRAY:
				foreach (init2 : init.init_array.elements) const_init_set_span(init2, loc);
				return;
			case INIT_ARRAY_FULL:
				foreach (init2 : init.init_array_full) const_init_set_span(init2, loc);
				return;
			case INIT_ARRAY_VALUE:
				const_init_set_span(init.init_array_value.element, loc);
				return;
		}
	}
}

fn void expr_set_loc(Expr* expr, SourceLocId loc)
{
	if (!expr) return;
	expr.loc = loc;
	switch (expr.expr_kind)
	{
		case TWO:
			expr_set_loc(expr.two_expr.first, loc);
			expr_set_loc(expr.two_expr.last, loc);
		case INT_TO_BOOL:
			expr_set_loc(expr.int_to_bool_expr.inner, loc);
		case EXT_TRUNC:
			expr_set_loc(expr.ext_trunc_expr.inner, loc);
		case NAMED_ARGUMENT:
			expr.named_argument_expr.name_span = loc;
			expr_set_loc(expr.named_argument_expr.value, loc);
		case NAMED_EVAL_ARGUMENT:
			expr_set_loc(expr.eval_named_argument_expr.name, loc);
			expr_set_loc(expr.eval_named_argument_expr.value, loc);
		case TYPE_PROPERTY:
			expr_set_loc(expr.type_property_expr.type, loc);
			expr.type_property_expr.token_span = loc;
		case CONST:
			switch (expr.const_expr.const_kind)
			{
				case INITIALIZER:
					const_init_set_span(expr.const_expr.initializer, loc);
				case UNTYPED_LIST:
					expr_list_set_loc(expr.const_expr.untyped_list, loc);
				default:
					return;
			}
		case CAST:
			exprid_set_loc(expr.cast_expr.expr, loc);
		case INITIALIZER_LIST:
			expr_list_set_loc(expr.initializer_list, loc);
		case DESIGNATED_INITIALIZER_LIST:
			expr_set_loc(expr.designated_init.splat, loc);
			expr_list_set_loc(expr.designated_init.list, loc);
		case MAKE_ANY:
			expr_set_loc(expr.make_any_expr.inner, loc);
			expr_set_loc(expr.make_any_expr.typeid_expr, loc);
		case MAKE_SLICE:
			if (expr.make_slice_expr.ptr) expr_set_loc(expr.make_slice_expr.ptr, loc);
		case SPLAT:
		case PTR_ACCESS:
		case VECTOR_TO_ARRAY:
		case SLICE_TO_VEC_ARRAY:
		case SCALAR_TO_VECTOR:
		case ENUM_FROM_ORD:
		case INT_TO_FLOAT:
		case INT_TO_PTR:
		case PTR_TO_INT:
		case FLOAT_TO_INT:
		case SLICE_LEN:
		case DISCARD:
		case VECTOR_FROM_ARRAY:
		case ADDR_CONVERSION:
		case RECAST:
		case LENGTHOF:
		case MAYBE_DEREF:
		case CT_REFLECT:
			expr_set_loc(expr.inner_expr, loc);
		case VAARG:
			exprid_set_loc(expr.vaarg_index.expr, loc);
		case EXPRESSION_LIST:
		case ACCESS_RESOLVED:
		case ACCESS_UNRESOLVED:
		case BITACCESS:
		case POISONED:
		case ASM:
		case BUILTIN:
		case BINARY:
		case BITASSIGN:
		case BUILTIN_ACCESS:
		case CALL:
		case CATCH_UNRESOLVED:
		case CATCH:
		case COMPILER_CONST:
		case COMPOUND_LITERAL:
		case COND:
		case CT_FEATURE:
		case CT_DEFINED:
		case CT_EVAL:
		case CT_IDENT:
		case DECL:
		case DESIGNATOR:
		case EMBED:
		case OPTIONAL:
		case FORCE_UNWRAP:
		case GENERIC_IDENT:
		case HASH_IDENT:
		case IDENTIFIER:
		case LAMBDA:
		case LAST_FAULT:
		case MACRO_BLOCK:
		case MACRO_BODY_EXPANSION:
		case NOP:
		case OPERATOR_CHARS:
		case OTHER_CONTEXT:
		case POINTER_OFFSET:
		case POST_UNARY:
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
		case TERNARY:
		case BENCHMARK_HOOK:
		case TEST_HOOK:
		case TRY:
		case TRY_UNRESOLVED:
		case TRY_UNWRAP_CHAIN:
		case TYPEID:
		case TYPEID_INFO:
		case TYPEINFO:
		case UNARY:
		case UNRESOLVED_IDENTIFIER:
		case VASPLAT:
		case VACOUNT:
		case MACRO_BODY:
		case DEFAULT_ARG:
		case TYPECALL:
		case MEMBER_GET:
		case MEMBER_SET:
		case RVALUE:
		case CT_SUBSCRIPT:
		case IOTA_DECL:
		case CONTRACT:
			break;
	}
}

fn void exprid_set_loc(ExprId expr_id, SourceLocId loc)
{
	if (expr_id) expr_set_loc(exprptr(expr_id), loc);
}

fn void expr_list_set_loc(Expr*[] exprs, SourceLocId loc)
{
	foreach (expr : exprs) expr_set_loc(expr, loc);
}

fn void expr_replace(Expr* expr, Expr* replacement)
{
	SourceLocId loc = expr.loc;
	*expr = *replacement;
	expr_set_loc(expr, loc);
}

fn bool expr_ok(Expr* expr) => expr == null || expr.expr_kind != POISONED;

fn void expr_resolve_ident(Expr* expr, Decl* decl)
{
	expr.expr_kind = IDENTIFIER;
	expr.ident_expr = decl;
	expr.type = decl.type ? decl.type : type_void;
	expr.resolve_status = DONE;
}

fn Type* exprtype(ExprId expr_id)
{
	assert(expr_id != 0);
	return exprptr(expr_id).type;
}

fn Expr* expr_new_expr(ExprKind kind, Expr* expr) => expr_new(kind, expr.loc);

fn void expr_rewrite_recast(Expr* expr, Type* type)
{
	if (expr.expr_kind == RECAST || expr.expr_kind == ADDR_CONVERSION || expr.expr_kind == RVALUE)
	{
		expr.type = type;
		return;
	}
	Expr* inner = expr_copy(expr);
	expr.expr_kind = RECAST;
	expr.inner_expr = inner;
	expr.type = type;
}

fn void expr_rewrite_rvalue(Expr* expr, Type* type)
{
	switch (expr.expr_kind)
	{
		case RECAST:
			expr.expr_kind = RVALUE;
			expr.type = type;
			return;
		case RVALUE:
			expr.type = type;
			return;
		default:
			break;
	}
	Expr* inner = expr_copy(expr);
	expr.expr_kind = RVALUE;
	expr.inner_expr = inner;
	expr.type = type;
}

fn void expr_rewrite_addr_conversion(Expr* expr, Type* type)
{
	switch (expr.expr_kind)
	{
		case RECAST:
			expr.expr_kind = ADDR_CONVERSION;
			expr.type = type;
			return;
		case ADDR_CONVERSION:
			expr.type = type;
			return;
		default:
			break;
	}
	Expr* inner = expr_copy(expr);
	expr.expr_kind = ADDR_CONVERSION;
	expr.inner_expr = inner;
	expr.type = type;
}

fn void expr_rewrite_discard(Expr* expr)
{
	Expr* inner = expr_copy(expr);
	expr.expr_kind = DISCARD;
	expr.inner_expr = inner;
	expr.type = type_void;
}

fn void expr_rewrite_const_bool(Expr* expr, Type* type, bool b)
{
	expr.expr_kind = CONST;
	expr.type = type;
	expr.const_expr = { .b = b, .const_kind = BOOL };
	expr.resolve_status = DONE;
}

fn void expr_rewrite_const_fault(Expr* expr, Decl* fault_)
{
	expr.expr_kind = CONST;
	expr.type = type_fault;
	expr.const_expr = { .fault_val = fault_, .const_kind = FAULT };
	expr.resolve_status = DONE;
}

fn void expr_rewrite_const_reflect(Expr* expr, Expr* reflect)
{
	assert(reflect.resolve_status == DONE);
	expr.expr_kind = CONST;
	expr.type = type_reflection;
	expr.const_expr = { .reflection = reflect, .const_kind = REFLECTION };
	expr.resolve_status = DONE;
}

fn void expr_rewrite_const_null(Expr* expr, Type* type)
{
	expr.expr_kind = CONST;
	expr.type = type;
	expr.const_expr = { .ptr = 0, .const_kind = POINTER };
	expr.resolve_status = DONE;
}

fn void expr_rewrite_const_empty_slice(Expr* expr, Type* type)
{
	assert(type_flatten(type).type_kind == SLICE);
	expr.const_expr = { .const_kind = SLICE, .initializer = null };
	expr.expr_kind = CONST;
	expr.type = type;
	expr.resolve_status = DONE;
}

fn void expr_rewrite_const_untyped_list(Expr* expr, Expr*[] elements)
{
	expr.expr_kind = CONST;
	expr.type = type_untypedlist;
	expr.const_expr = { .untyped_list = elements, .const_kind = UNTYPED_LIST };
	expr.resolve_status = DONE;
}

fn void expr_rewrite_const_initializer(Expr* expr, Type* type, ConstInitializer* initializer)
{
	assert(type_flatten(type).type_kind != SLICE);
	assert(type != type_untypedlist);
	expr.expr_kind = CONST;
	expr.type = type;
	expr.const_expr = { .initializer = initializer, .const_kind = INITIALIZER };
	expr.resolve_status = DONE;
}

fn void expr_rewrite_const_slice(Expr* expr, Type* type, ConstInitializer* initializer)
{
	assert(type_flatten(type).type_kind == SLICE);
	assert(type != type_untypedlist);
	expr.expr_kind = CONST;
	expr.type = type;
	expr.const_expr = { .slice_init = initializer, .const_kind = SLICE };
	expr.resolve_status = DONE;
}

fn void expr_rewrite_const_typeid(Expr* expr, Type* type)
{
	expr.expr_kind = CONST;
	expr.const_expr.const_kind = TYPEID;
	expr.const_expr.typeid_type = type.canonical;
	expr.type = type_typeid;
	expr.resolve_status = DONE;
}

fn void expr_rewrite_ptr_access(Expr* expr, Expr* inner, Type* type)
{
	assert(inner.resolve_status == DONE);
	expr.expr_kind = PTR_ACCESS;
	expr.inner_expr = inner;
	expr.type = type_add_optional(type, type_is_optional(inner.type));
	expr.resolve_status = DONE;
}

fn void expr_rewrite_enum_from_ord(Expr* expr, Type* type)
{
	Expr* inner = expr_copy(expr);
	assert(inner.resolve_status == DONE);
	expr.expr_kind = ENUM_FROM_ORD;
	expr.inner_expr = inner;
	expr.type = type_add_optional(type, type_is_optional(expr.type));
	expr.resolve_status = DONE;
}

fn void expr_rewrite_slice_len(Expr* expr, Expr* inner, Type* type)
{
	assert(inner.resolve_status == DONE);
	expr.expr_kind = SLICE_LEN;
	expr.inner_expr = inner;
	expr.type = type_add_optional(type, type_is_optional(inner.type));
	expr.resolve_status = DONE;
}

fn void expr_rewrite_ext_trunc(Expr* expr, Type* type, bool is_signed)
{
	Expr* inner = expr_copy(expr);
	expr.expr_kind = EXT_TRUNC;
	expr.ext_trunc_expr = { .inner = inner, .is_signed = is_signed };
	expr.type = type_add_optional(type, type_is_optional(inner.type));
}

fn void expr_rewrite_const_integer(Expr* expr, Type* type, uint128 i)
{
	expr.expr_kind = CONST;
	expr.type = type;
	expr.resolve_status = DONE;
	expr.const_expr.ixx = { .i = i, .type = type_flatten_to_int(type).type_kind };
	assert(type_kind_is_any_integer(expr.const_expr.ixx.type));
	expr.const_expr.is_character = false;
	expr.const_expr.const_kind = INTEGER;
}

fn void expr_rewrite_const_byte(Expr* expr, Type* type, char c)
{
	expr_rewrite_const_int(expr, type, type_is_signed(type_flatten(type)) ? (ulong)(ichar)c : (ulong)c);
}

fn void expr_rewrite_const_int(Expr* expr, Type* type, ulong v)
{
	expr.expr_kind = CONST;
	expr.type = type;
	expr.resolve_status = DONE;
	TypeKind kind = type_flatten(type).type_kind;
	assert(type_kind_is_any_integer(kind));
	uint128 i = 0;
	if (type_kind_is_signed(kind))
	{
		if (v > (ulong)long::max) i = (uint128)ulong::max << 64;
	}
	else
	{
		switch (kind)
		{
			case U8:
				v &= 0xFF;
			case U16:
				v &= 0xFFFF;
			case U32:
				v &= 0xFFFFFFFF;
			default:
				break;
		}
	}
	expr.const_expr.ixx.i = i | v;
	expr.const_expr.ixx.type = kind;
	expr.const_expr.is_character = false;
	expr.const_expr.const_kind = INTEGER;
}

fn void expr_rewrite_to_int_to_float(Expr* expr, Type* type)
{
	Expr* inner = expr_copy(expr);
	expr.expr_kind = INT_TO_FLOAT;
	expr.inner_expr = inner;
	expr.type = type_add_optional(type, type_is_optional(inner.type));
}

fn void expr_rewrite_to_int_to_ptr(Expr* expr, Type* type)
{
	Expr* inner = expr_copy(expr);
	expr.expr_kind = INT_TO_PTR;
	expr.inner_expr = inner;
	expr.type = type_add_optional(type, type_is_optional(inner.type));
}

fn void expr_rewrite_to_ptr_to_int(Expr* expr, Type* type)
{
	Expr* inner = expr_copy(expr);
	expr.expr_kind = PTR_TO_INT;
	expr.inner_expr = inner;
	expr.type = type_add_optional(type, type_is_optional(inner.type));
}

fn void expr_rewrite_to_float_to_int(Expr* expr, Type* type)
{
	Expr* inner = expr_copy(expr);
	expr.expr_kind = FLOAT_TO_INT;
	expr.inner_expr = inner;
	expr.type = type_add_optional(type, type_is_optional(inner.type));
}

fn void expr_rewrite_const_float(Expr* expr, Type* type, Real d)
{
	expr.expr_kind = CONST;
	expr.type = type;
	TypeKind kind = type_flatten(type).type_kind;
	Real real;
	switch (kind)
	{
		case F16:
		case BF16:
			real = float_round_to_type(d, kind);
		case F32:
			real = (float)d;
		case F64:
			real = (double)d;
		default:
			// c3c REMINDER("Handling of float type may not be accurate")
			real = d;
	}
	expr.const_expr = { .fxx = { real, kind }, .const_kind = FLOAT };
	expr.resolve_status = DONE;
}

fn bool expr_is_empty_const_slice(Expr* expr)
{
	assert(expr.resolve_status == DONE);
	return expr.expr_kind == CONST && expr.const_expr.const_kind == SLICE && expr.const_expr.slice_init == null;
}

fn bool expr_is_const(Expr* expr) => expr.expr_kind == CONST;

macro bool expr_is_const_kind(Expr* expr, ConstKind kind) @local
{
	assert(expr.resolve_status == DONE);
	return expr.expr_kind == CONST && expr.const_expr.const_kind == kind;
}

fn bool expr_is_const_string(Expr* expr) => expr_is_const_kind(expr, STRING);
fn bool expr_is_const_enum(Expr* expr) => expr_is_const_kind(expr, ENUM);

fn bool expr_is_const_number(Expr* expr)
{
	assert(expr.resolve_status == DONE);
	return expr.expr_kind == CONST && (expr.const_expr.const_kind == INTEGER || expr.const_expr.const_kind == FLOAT);
}

fn bool expr_is_const_fault(Expr* expr) => expr_is_const_kind(expr, FAULT);
fn bool expr_is_const_ref(Expr* expr) => expr_is_const_kind(expr, REF);
fn bool expr_is_const_pointer(Expr* expr) => expr_is_const_kind(expr, POINTER);
fn bool expr_is_const_bool(Expr* expr) => expr_is_const_kind(expr, BOOL);
fn bool expr_is_const_initializer(Expr* expr) => expr_is_const_kind(expr, INITIALIZER);
fn bool expr_is_const_slice(Expr* expr) => expr_is_const_kind(expr, SLICE);
fn bool expr_is_const_bytes(Expr* expr) => expr_is_const_kind(expr, BYTES);
fn bool expr_is_const_untyped_list(Expr* expr) => expr_is_const_kind(expr, UNTYPED_LIST);
fn bool expr_is_const_int(Expr* expr) => expr_is_const_kind(expr, INTEGER);
fn bool expr_is_const_float(Expr* expr) => expr_is_const_kind(expr, FLOAT);
fn bool expr_is_const_typeid(Expr* expr) => expr_is_const_kind(expr, TYPEID);
fn bool expr_is_const_member(Expr* expr) => expr_is_const_kind(expr, MEMBER);
fn bool expr_is_const_reflection(Expr* expr) => expr_is_const_kind(expr, REFLECTION);

fn bool expr_is_ct_ident(Expr* expr)
{
	assert(expr.resolve_status == DONE);
	if (expr.expr_kind != IDENTIFIER) return false;
	Decl* decl = expr.ident_expr;
	if (decl.decl_kind != VAR) return false;
	switch (decl.var_decl.kind)
	{
		case CONST:
		case GLOBAL:
		case LOCAL:
		case PARAM:
		case MEMBER:
		case BITMEMBER:
		case PARAM_EXPR:
		case UNWRAPPED:
		case ERASE:
		case REWRAPPED:
			return false;
		case PARAM_CT:
		case PARAM_CT_TYPE:
		case LOCAL_CT:
		case LOCAL_CT_TYPE:
			return true;
	}
}

fn void expr_rewrite_const_string_from_scratch(Expr* expr_to_rewrite)
{
	expr_rewrite_const_string(expr_to_rewrite, scratch_buffer_copy(), (ArrayIndex)scratch_buffer_len());
}

fn void const_init_set_type(ConstInitializer* init, Type* type)
{
	init.type = type_flatten(type);
}
