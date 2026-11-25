// Port of c3c src/compiler/sema_liveness.c (revision 54bab366a): marks the
// declarations and types reachable from main / exports / tests as live.
//
// Deviations from c3c:
// - The `goto RETRY` loops are `while (true)` loops.
// - The NON_RUNTIME_EXPR / UNRESOLVED_EXPRS error group of
//   sema_trace_expr_liveness is the `default` arm; the `%d` of the node kind
//   prints its ordinal.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// sema_liveness.c:11 (static)
fn void sema_trace_type_liveness(Module* m, Type* type)
{
	if (!type) return;
	if (type.is_live && type.traced_module == m) return;
	while (true)
	{
		type.is_live = true;
		type.traced_module = m;
		switch (type.type_kind)
		{
			case POISONED:
			case VOID:
			case BOOL:
			case I8..I128:
			case U8..U128:
			case F16..F128:
			case ANY:
				return;
			case INTERFACE:
				break;
			case ANYFAULT:
			case TYPEID:
				return;
			case FUNC_PTR:
			case POINTER:
				type = type.pointer;
				continue;
			case TYPEDEF:
			case CONSTSET:
			case ENUM:
			case FUNC_RAW:
			case STRUCT:
			case UNION:
			case BITSTRUCT:
				break;
			case ALIAS:
				type = type.canonical;
				continue;
			case UNTYPEDLIST:
				return;
			case SLICE:
			case ARRAY:
			case FLEXIBLE_ARRAY:
			case INFERRED_ARRAY:
			case VECTOR:
			case SIMD_VECTOR:
			case INFERRED_VECTOR:
				type = type.array.base;
				continue;
			case OPTIONAL:
				type = type.optional;
				continue;
			case WILDCARD:
			case TYPEINFO:
			case MEMBER:
			case REFLECTION:
				return;
		}
		break;
	}
	sema_trace_decl_liveness(m, type.decl);
}

// sema_liveness.c:70 (static)
fn void sema_trace_exprid_liveness(Module* m, ExprId expr)
{
	if (expr) sema_trace_expr_liveness(m, exprptr(expr));
}

// sema_liveness.c:75 (static)
fn void sema_trace_astid_liveness(Module* m, AstId astid)
{
	if (astid) sema_trace_stmt_liveness(m, astptr(astid));
}

// sema_liveness.c:80 (static)
fn void sema_trace_decl_list_liveness(Module* m, Decl*[] decllist)
{
	foreach (arg : decllist) sema_trace_decl_liveness(m, arg);
}

// sema_liveness.c:85 (static)
fn void sema_trace_expr_list_liveness(Module* m, Expr*[] exprlist)
{
	foreach (arg : exprlist) sema_trace_expr_liveness(m, arg);
}

// sema_liveness.c:90 (static)
fn void sema_trace_stmt_chain_liveness(Module* m, AstId astid)
{
	AstId current = astid;
	while (current)
	{
		Ast* stmt = ast_next(&current);
		sema_trace_stmt_liveness(m, stmt);
		switch (stmt.ast_kind)
		{
			case RETURN_STMT:
			case BREAK_STMT:
			case CONTINUE_STMT:
			case NEXTCASE_STMT:
				return;
			default:
				break;
		}
	}
}

// sema_liveness.c:110 (static)
fn void sema_trace_expr_asm_arg(Module* m, ExprAsmArg* arg)
{
	switch (arg.kind)
	{
		case ARG_ADDR:
			sema_trace_exprid_liveness(m, arg.base);
			sema_trace_exprid_liveness(m, arg.idx);
			return;
		case ARG_REG:
		case ARG_INT:
			return;
		case ARG_MEMADDR:
		case ARG_MEMVAR:
		case ARG_REGVAR:
			sema_trace_decl_liveness(m, arg.ident.ident_decl);
			return;
		case ARG_VALUE:
			sema_trace_exprid_liveness(m, arg.expr_id);
			return;
	}
}

// sema_liveness.c:132 (static)
fn void sema_trace_asm_arg_list(Module* m, ExprAsmArg*[] list)
{
	foreach (asm_arg : list)
	{
		sema_trace_expr_asm_arg(m, asm_arg);
	}
}

// sema_liveness.c:140 (static)
fn void sema_trace_stmt_liveness(Module* m, Ast* ast)
{
	if (!ast) return;
	switch (ast.ast_kind)
	{
		case POISONED:
		case CT_ASSERT:
		case CT_ECHO_STMT:
		case CT_ELSE_STMT:
		case CT_FOREACH_STMT:
		case CT_FOR_STMT:
		case CT_EXPAND_STMT:
		case CT_IF_STMT:
		case CT_SWITCH_STMT:
		case CT_TYPE_ASSIGN_STMT:
		case FOREACH_STMT:
			assert_print_line(ast.loc);
			@error_exit("Unexpected liveness checking of AST node %d.", ast.ast_kind.ordinal);
		case ASM_STMT:
			sema_trace_expr_list_liveness(m, ast.asm_stmt.args);
			return;
		case DEFER_STMT:
			sema_trace_stmt_liveness(m, astptr(ast.defer_stmt.body));
			return;
		case NOP_STMT:
		case ASM_LABEL:
			return;
		case CT_COMPOUND_STMT:
			sema_trace_stmt_chain_liveness(m, ast.ct_compound_stmt);
			return;
		case COMPOUND_STMT:
			sema_trace_stmt_chain_liveness(m, ast.compound_stmt.first_stmt);
			return;
		case EXPR_STMT:
			sema_trace_expr_liveness(m, ast.expr_stmt);
			return;
		case DECLARE_STMT:
			sema_trace_decl_liveness(m, ast.declare_stmt);
			return;
		case RETURN_STMT:
		case BLOCK_EXIT_STMT:
			sema_trace_expr_liveness(m, ast.return_stmt.expr);
			sema_trace_stmt_chain_liveness(m, ast.return_stmt.cleanup);
			if (ast.return_stmt.cleanup != ast.return_stmt.cleanup_fail)
			{
				sema_trace_astid_liveness(m, ast.return_stmt.cleanup_fail);
			}
			return;
		case ASM_BLOCK_STMT:
			if (ast.asm_block_stmt.is_string)
			{
				sema_trace_exprid_liveness(m, ast.asm_block_stmt.asm_string);
				return;
			}
			sema_trace_stmt_chain_liveness(m, ast.asm_block_stmt.block.asm_stmt);
			sema_trace_asm_arg_list(m, ast.asm_block_stmt.block.input);
			sema_trace_asm_arg_list(m, ast.asm_block_stmt.block.output_vars);
			return;
		case ASSERT_STMT:
			Expr* e = exprptr(ast.assert_stmt.expr);
			if (compile_asserts() || expr_is_pure(e))
			{
				sema_trace_expr_liveness(m, e);
			}
			if (compile_asserts())
			{
				sema_trace_exprid_liveness(m, ast.assert_stmt.message);
				sema_trace_expr_list_liveness(m, ast.assert_stmt.args);
			}
			return;
		case DECLS_STMT:
			foreach (decl : ast.decls_stmt) sema_trace_decl_liveness(m, decl);
			return;
		case FOR_STMT:
			sema_trace_exprid_liveness(m, ast.for_stmt.cond);
			sema_trace_exprid_liveness(m, ast.for_stmt.init);
			sema_trace_exprid_liveness(m, ast.for_stmt.incr);
			sema_trace_astid_liveness(m, ast.for_stmt.body);
			return;
		case IF_STMT:
			sema_trace_exprid_liveness(m, ast.if_stmt.cond);
			sema_trace_astid_liveness(m, ast.if_stmt.then_body);
			sema_trace_astid_liveness(m, ast.if_stmt.else_body);
			return;
		case SWITCH_STMT:
			sema_trace_exprid_liveness(m, ast.switch_stmt.cond);
			foreach (casestm : ast.switch_stmt.cases) sema_trace_stmt_liveness(m, casestm);
			return;
		case CASE_STMT:
			sema_trace_exprid_liveness(m, ast.case_stmt.expr);
			sema_trace_exprid_liveness(m, ast.case_stmt.to_expr);
			sema_trace_stmt_liveness(m, ast.case_stmt.body);
			return;
		case DEFAULT_STMT:
			sema_trace_stmt_liveness(m, ast.case_stmt.body);
			return;
		case NEXTCASE_STMT:
			sema_trace_stmt_chain_liveness(m, ast.nextcase_stmt.defer_id);
			if (ast.nextcase_stmt.is_expr) sema_trace_expr_liveness(m, ast.nextcase_stmt.nextcase_value);
			return;
		case BREAK_STMT:
		case CONTINUE_STMT:
			sema_trace_stmt_chain_liveness(m, ast.contbreak_stmt.defers);
			return;
	}
}

// sema_liveness.c:246 (static)
fn void sema_trace_const_initializer_liveness(Module* m, ConstInitializer* const_init)
{
	if (!const_init) return;
	while (true)
	{
		switch (const_init.kind)
		{
			case INIT_ZERO:
				return;
			case INIT_ARRAY_VALUE:
				const_init = const_init.init_array_value.element;
				continue;
			case INIT_ARRAY_FULL:
				Type* array_type = const_init.type;
				ConstInitializer*[] elements = const_init.init_array_full;
				ArrayIndex size = array_type.array.len;
				for (ArrayIndex i = 0; i < (ArrayIndex)size; i++)
				{
					sema_trace_const_initializer_liveness(m, elements[i]);
				}
				return;
			case INIT_ARRAY:
				foreach (i : const_init.init_array.elements) sema_trace_const_initializer_liveness(m, i);
				return;
			case INIT_UNION:
				const_init = const_init.init_union.element;
				continue;
			case INIT_STRUCT:
				Decl* decl = const_init.type.decl;
				Decl*[] members = decl.strukt.members;
				int count = (int)members.len;
				if (decl.decl_kind == UNION && count) count = 1;
				for (int i = 0; i < count; i++)
				{
					sema_trace_const_initializer_liveness(m, const_init.init_struct[i]);
				}
				return;
			case INIT_VALUE:
				sema_trace_expr_liveness(m, const_init.init_value);
				return;
		}
	}
}

// sema_liveness.c:296 (static)
fn void sema_trace_expr_liveness(Module* m, Expr* expr)
{
	while (true)
	{
		if (!expr) return;
		sema_trace_type_liveness(m, expr.type);
		switch (expr.expr_kind)
		{
			case TWO:
				sema_trace_expr_liveness(m, expr.two_expr.first);
				sema_trace_expr_liveness(m, expr.two_expr.last);
				return;
			case DESIGNATOR:
				sema_trace_expr_liveness(m, expr.designator_expr.value);
				return;
			case BUILTIN:
				return;
			case MAKE_SLICE:
				expr = expr.make_slice_expr.ptr;
				continue;
			case MAKE_ANY:
				sema_trace_expr_liveness(m, expr.make_any_expr.typeid_expr);
				expr = expr.make_any_expr.inner;
				continue;
			case ACCESS_RESOLVED:
			case BITACCESS:
				sema_trace_decl_liveness(m, expr.access_resolved_expr.ref);
				expr = expr.access_resolved_expr.parent;
				continue;
			case ASM:
				sema_trace_expr_asm_arg(m, &expr.expr_asm_arg);
				return;
			case BINARY:
			case BITASSIGN:
				sema_trace_expr_liveness(m, exprptr(expr.binary_expr.left));
				sema_trace_expr_liveness(m, exprptr(expr.binary_expr.right));
				return;
			case CALL:
				sema_trace_expr_list_liveness(m, expr.call_expr.arguments);
				if (expr.call_expr.varargs.ptr)
				{
					if (expr.call_expr.va_is_splat)
					{
						sema_trace_expr_liveness(m, expr.call_expr.vasplat);
					}
					else
					{
						sema_trace_expr_list_liveness(m, expr.call_expr.varargs);
					}
				}
				if (expr.call_expr.is_builtin) return;
				if (!expr.call_expr.is_func_ref)
				{
					sema_trace_expr_liveness(m, exprptr(expr.call_expr.function));
					return;
				}
				sema_trace_stmt_chain_liveness(m, expr.call_expr.function_contracts);
				sema_trace_decl_liveness(m, declptr(expr.call_expr.func_ref));
				return;
			case FORCE_UNWRAP:
			case RETHROW:
			case OPTIONAL:
			case VECTOR_TO_ARRAY:
			case SLICE_TO_VEC_ARRAY:
			case SCALAR_TO_VECTOR:
			case PTR_ACCESS:
			case ENUM_FROM_ORD:
			case FLOAT_TO_INT:
			case INT_TO_FLOAT:
			case INT_TO_PTR:
			case PTR_TO_INT:
			case SLICE_LEN:
			case VECTOR_FROM_ARRAY:
			case RVALUE:
			case RECAST:
			case DISCARD:
			case ADDR_CONVERSION:
				expr = expr.inner_expr;
				continue;
			case DEFAULT_ARG:
				expr = expr.default_arg_expr.inner;
				continue;
			case BUILTIN_ACCESS:
				expr = exprptr(expr.builtin_access_expr.inner);
				continue;
			case CATCH:
				if (expr.catch_expr.decl)
				{
					sema_trace_decl_liveness(m, expr.catch_expr.decl);
				}
				foreach (e : expr.catch_expr.exprs) sema_trace_expr_liveness(m, e);
				return;
			case CONST:
				switch (expr.const_expr.const_kind)
				{
					case TYPEID:
						sema_trace_type_liveness(m, expr.const_expr.typeid_type);
						return;
					case FLOAT:
					case INTEGER:
					case BOOL:
					case BYTES:
					case STRING:
					case POINTER:
					case UNTYPED_LIST:
					case MEMBER:
					case REFLECTION:
						return;
					case FAULT:
						sema_trace_decl_liveness(m, expr.const_expr.fault_val);
						return;
					case ENUM:
						sema_trace_decl_liveness(m, expr.const_expr.enum_val);
						return;
					case REF:
						sema_trace_decl_liveness(m, expr.const_expr.global_ref);
						return;
					case SLICE:
						sema_trace_const_initializer_liveness(m, expr.const_expr.slice_init);
						return;
					case INITIALIZER:
						sema_trace_const_initializer_liveness(m, expr.const_expr.initializer);
						return;
				}
			case COND:
				foreach (e : expr.cond_expr) sema_trace_expr_liveness(m, e);
				return;
			case DECL:
				sema_trace_decl_liveness(m, expr.decl_expr);
				return;
			case EXPRESSION_LIST:
				sema_trace_expr_list_liveness(m, expr.expression_list);
				return;
			case DESIGNATED_INITIALIZER_LIST:
				sema_trace_expr_liveness(m, expr.designated_init.splat);
				sema_trace_expr_list_liveness(m, expr.designated_init.list);
				return;
			case IDENTIFIER:
				sema_trace_decl_liveness(m, expr.ident_expr);
				return;
			case INITIALIZER_LIST:
				sema_trace_expr_list_liveness(m, expr.initializer_list);
				return;
			case MACRO_BLOCK:
				sema_trace_decl_list_liveness(m, expr.macro_block.arguments);
				sema_trace_stmt_chain_liveness(m, expr.macro_block.first_stmt);
				return;
			case MACRO_BODY_EXPANSION:
				foreach (arg : expr.body_expansion_expr.declarations) sema_trace_decl_liveness(m, arg);
				foreach (arg : expr.body_expansion_expr.values) sema_trace_expr_liveness(m, arg);
				sema_trace_stmt_liveness(m, astptrzero(expr.body_expansion_expr.first_stmt));
				return;
			case NOP:
				return;
			case POINTER_OFFSET:
				sema_trace_expr_liveness(m, exprptr(expr.pointer_offset_expr.ptr));
				expr = exprptr(expr.pointer_offset_expr.offset);
				continue;
			case POST_UNARY:
			case UNARY:
				expr = expr.unary_expr.expr;
				continue;
			case RETVAL:
				return;
			case SLICE_ASSIGN:
			case SLICE_COPY:
				sema_trace_expr_liveness(m, exprptr(expr.slice_assign_expr.left));
				sema_trace_expr_liveness(m, exprptr(expr.slice_assign_expr.right));
				return;
			case SLICE:
				sema_trace_expr_liveness(m, exprptr(expr.slice_expr.expr));
				switch (expr.slice_expr.range.range_type)
				{
					case SINGLE_ELEMENT:
						unreachable();
					case CONST_RANGE:
						return;
					case DYNAMIC:
						sema_trace_expr_liveness(m, exprptr(expr.slice_expr.range.start));
						sema_trace_expr_liveness(m, exprptrzero(expr.slice_expr.range.end));
						return;
					case CONST_END:
					case CONST_LEN:
						sema_trace_expr_liveness(m, exprptr(expr.slice_expr.range.start));
						return;
				}
			case SUBSCRIPT:
			case SUBSCRIPT_ADDR:
				sema_trace_expr_liveness(m, exprptr(expr.subscript_expr.expr));
				sema_trace_expr_liveness(m, exprptr(expr.subscript_expr.index.expr));
				return;
			case SWIZZLE:
				sema_trace_expr_liveness(m, exprptr(expr.swizzle_expr.parent));
				return;
			case TERNARY:
				sema_trace_expr_liveness(m, exprptr(expr.ternary_expr.cond));
				if (expr.ternary_expr.then_expr)
				{
					sema_trace_expr_liveness(m, exprptr(expr.ternary_expr.then_expr));
				}
				expr = exprptr(expr.ternary_expr.else_expr);
				continue;
			case BENCHMARK_HOOK:
			case TEST_HOOK:
				return;
			case TYPEID_INFO:
				sema_trace_exprid_liveness(m, expr.typeid_info_expr.parent);
				return;
			case TRY:
				sema_trace_expr_liveness(m, expr.try_expr.optional);
				if (expr.try_expr.assign_existing)
				{
					sema_trace_expr_liveness(m, expr.try_expr.lhs);
				}
				else
				{
					sema_trace_decl_liveness(m, expr.try_expr.decl);
				}
				return;
			case TRY_UNWRAP_CHAIN:
				sema_trace_expr_list_liveness(m, expr.try_unwrap_chain_expr);
				return;
			case INT_TO_BOOL:
				sema_trace_expr_liveness(m, expr.int_to_bool_expr.inner);
				return;
			case EXT_TRUNC:
				sema_trace_expr_liveness(m, expr.ext_trunc_expr.inner);
				return;
			case LAST_FAULT:
				return;
			default:
				// NON_RUNTIME_EXPR, UNRESOLVED_EXPRS, SUBSCRIPT_ASSIGN, OPERATOR_CHARS,
				// MEMBER_GET, MEMBER_SET, NAMED_ARGUMENT, NAMED_EVAL_ARGUMENT, LAMBDA
				assert_print_line(expr.loc);
				@error_exit("Unexpected liveness checking of expr node %d.", expr.expr_kind.ordinal);
		}
	}
}

// sema_liveness.c:549
fn void sema_trace_liveness()
{
	if (compiler.context.main)
	{
		sema_trace_decl_liveness(null, compiler.context.main);
	}
	sema_trace_decl_liveness(null, compiler.context.panic_var);
	bool keep_all = !strip_unused();
	foreach (function : compiler.context.method_extension_list)
	{
		if (function.decl_kind == MACRO) continue;
		if (function.func_decl.attr_dynamic) function.no_strip = true;
		if (function.is_export || function.no_strip) sema_trace_decl_liveness(function.unit.mod, function);
	}
	foreach (m : compiler.context.module_list)
	{
		foreach (unit : m.units)
		{
			foreach (function : unit.functions)
			{
				if (decl_skip_benchtest_function(function)) continue;
				if (keep_all ||
					function.is_export ||
					function.no_strip ||
					m.is_compiler_rt ||
					function.func_decl.attr_finalizer ||
					function.func_decl.attr_init ||
					(function.func_decl.attr_test) ||
					(function.func_decl.attr_benchmark))
				{
					sema_trace_decl_liveness(m, function);
				}
			}
			foreach (method : unit.methods)
			{
				if (keep_all || method.is_export || method.no_strip || m.is_compiler_rt) sema_trace_decl_liveness(m, method);
			}
			foreach (var_ : unit.vars)
			{
				if (keep_all || var_.is_export || var_.no_strip) sema_trace_decl_liveness(m, var_);
			}
			if (!keep_all) continue;
			foreach (lambda : unit.lambdas) sema_trace_decl_liveness(m, lambda);
			foreach (type : unit.types) sema_trace_decl_liveness(m, type);
			foreach (enum_decl : unit.enums) sema_trace_decl_liveness(m, enum_decl);
		}
	}
}

// sema_liveness.c:598 (static)
fn void sema_trace_enum_associated(Module* m, Decl* decl)
{
	sema_trace_type_liveness(m, decl.enums.type_info.type);
	foreach (enum_constant : decl.enums.values)
	{
		sema_trace_decl_liveness(m, enum_constant);
	}
}

// sema_liveness.c:606 (static)
fn void sema_trace_decl_dynamic_methods(Module* m, Decl* decl)
{
	Methods* table = decl.method_table;
	if (!table) return;
	Decl*[] methods = table.methods;
	int method_count = (int)methods.len;
	if (!method_count) return;
	for (int i = 0; i < method_count; i++)
	{
		Decl* method = methods[i];
		if (method.decl_kind == MACRO) continue;
		if (method.func_decl.attr_dynamic)
		{
			sema_trace_decl_liveness(m, method);
		}
	}
}

// sema_liveness.c:623 (static)
fn void sema_trace_func_liveness(Module* m, Signature* sig)
{
	foreach (param : sig.params) sema_trace_decl_liveness(m, param);
	sema_trace_type_liveness(m, typeget(sig.rtype));
}

// sema_liveness.c:629 (static)
fn void sema_trace_decl_internal(Module* m, Decl* decl)
{
	switch (decl.decl_kind)
	{
		case ERASED:
			return;
		case TYPE_ALIAS:
			sema_trace_type_liveness(m, decl.type);
			return;
		case ENUM:
			sema_trace_decl_dynamic_methods(m, decl);
			sema_trace_enum_associated(m, decl);
			return;
		case TYPEDEF:
			sema_trace_type_liveness(m, decl.distinct.type);
			nextcase CONSTSET;
		case CONSTSET:
		case BITSTRUCT:
		case INTERFACE:
		case UNION:
			sema_trace_decl_dynamic_methods(m, decl);
			return;
		case STRUCT:
			if (decl.is_substruct)
			{
				sema_trace_type_liveness(m, decl.strukt.members[0].type);
			}
			sema_trace_decl_dynamic_methods(m, decl);
			return;
		case ENUM_CONSTANT:
			if (!decl.enum_constant.is_raw)
			{
				sema_trace_expr_list_liveness(m, decl.enum_constant.associated);
			}
			return;
		case POISONED:
		case ATTRIBUTE:
		case FAULT:
			return;
		case ALIAS:
		case ALIAS_PATH:
		case BODYPARAM:
		case CT_ASSERT:
		case CT_ECHO:
		case CT_EXEC:
		case CT_EXPAND:
		case CT_INCLUDE:
		case GROUP:
		case IMPORT:
		case LABEL:
		case MACRO:
		case GENERIC:
		case GENERIC_INSTANCE:
		case CONTRACT:
			unreachable();
		case DECLARRAY:
			foreach (d : decl.decls)
			{
				sema_trace_decl_liveness(m, d);
			}
			return;
		case FNTYPE:
			sema_trace_func_liveness(m, &decl.fntype_decl.signature);
			return;
		case FUNC:
			sema_trace_func_liveness(m, &decl.func_decl.signature);
			sema_trace_stmt_liveness(m, astptrzero(decl.func_decl.body));
			return;
		case VAR:
			switch (decl.var_decl.kind)
			{
				case PARAM_EXPR: // These are never traced, they are folded in use.
				case PARAM_CT_TYPE:
				case LOCAL_CT_TYPE:
				case REWRAPPED:
				case UNWRAPPED:
					break;
				case PARAM_CT:
				case PARAM:
					sema_trace_type_liveness(m, decl.type);
					if (decl.var_decl.init_expr && decl.var_decl.init_expr.resolve_status == DONE)
					{
						sema_trace_expr_liveness(m, decl.var_decl.init_expr);
					}
				default:
					sema_trace_type_liveness(m, decl.type);
					sema_trace_expr_liveness(m, decl.var_decl.init_expr);
			}
	}
}

// sema_liveness.c:725 (static)
fn bool decl_is_emitted_in_own_module(Decl* decl)
{
	if (decl.decl_kind != VAR) return true;
	return !decl.var_decl.is_static && (decl.var_decl.kind == GLOBAL || decl.var_decl.kind == CONST);
}

// sema_liveness.c:731 (static)
fn void sema_trace_decl_used_externally(Module* m, Decl* decl)
{
	switch (decl.decl_kind)
	{
		case ENUM:
			foreach (value : decl.enums.values)
			{
				if (!value.enum_constant.is_raw) sema_trace_expr_list_liveness(null, value.enum_constant.associated);
			}
		case TYPEDEF:
			sema_trace_type_liveness(m, decl.distinct.type);
		case STRUCT:
			if (decl.is_substruct) sema_trace_type_liveness(m, decl.strukt.members[0].type);
		default:
			break;
	}
}

// sema_liveness.c:754 (static)
fn void sema_trace_decl_liveness(Module* m, Decl* decl)
{
	if (!decl) return;
	if (decl.decl_kind == ALIAS)
	{
		sema_trace_decl_liveness(m, decl.define_decl.alias_decl);
		return;
	}
	Module* mod = decl.unit && decl_is_emitted_in_own_module(decl) ? decl.unit.mod : m;
	if (mod != m && !decl.is_external_visible)
	{
		decl.is_external_visible = true;
		sema_trace_decl_used_externally(m, decl);
	}
	if (decl.is_live) return;
	decl.is_live = true;
	sema_trace_decl_internal(mod, decl);
}
