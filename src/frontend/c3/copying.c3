// Port of c3c src/compiler/copying.c (revision 54bab366a): deep copies of
// AST / Expr / Decl / TypeInfo trees for macro expansion, defers, generics
// and lambdas, with pointer fix-ups so references into the copied tree are
// redirected to the copies.
//
// Mapping:
// - MACRO_COPY_X(x) -> `x = copy_x(c, x)` spelled out at each use.
// - SCOPE_FIXUP_START / SCOPE_FIXUP_END -> `CopyFixup* current = c.current_fixup;`
//   ... `c.current_fixup = current;`.
// - `goto RETRY` in ast_copy_deep -> a `while (true)` loop over `next`.
//
// Deviations from c3c:
// - `CopyStruct.fixups` is a slice; the first copy_begin points it at the
//   static `copy_fixup_storage` (MAX_FIXUPS entries, the c3c inline array).
// - `call_expr.varargs` NULL check: tests the slice pointer, which overlays
//   `vasplat` like the C union.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

<* c3c's static `copy_struct`. *>
CopyStruct copy_struct;
<* c3c's inline `CopyStruct.fixups` array (zero-initialized static storage, like c3c). *>
CopyFixup[MAX_FIXUPS] copy_fixup_storage @local;

// copying.c:23 (static)
fn void copy_reg_ref(CopyStruct* c, void* original, void* result) @inline
{
	c.current_fixup.new_ptr = result;
	c.current_fixup.original = original;
	c.current_fixup++;
	if (c.current_fixup == c.fixups.ptr + MAX_FIXUPS)
	{
		@error_exit("Too many fix-ups for macros.");
	}
}

// copying.c:34 (static)
fn void* fixup(CopyStruct* c, void* original) @inline
{
	CopyFixup* fixup_entry = c.current_fixup;
	CopyFixup* first = c.fixups.ptr;
	while (fixup_entry != first)
	{
		fixup_entry--;
		if (original == fixup_entry.original)
		{
			return fixup_entry.new_ptr;
		}
	}
	return null;
}

// copying.c:49 (static)
fn void fixup_decl(CopyStruct* c, Decl** decl_ref) @inline
{
	Decl* old = *decl_ref;
	if (!old) return;
	Decl* new_decl = fixup(c, old);
	if (new_decl) *decl_ref = new_decl;
}

// copying.c:57 (static)
fn void fixup_declid(CopyStruct* c, DeclId* declid_ref) @inline
{
	DeclId id = *declid_ref;
	if (!id) return;
	Decl* decl = declptr(id);
	decl = fixup(c, decl);
	if (decl) *declid_ref = declid(decl);
}

// copying.c:66 (static)
fn void fixup_astid(CopyStruct* c, AstId* astid_ref) @inline
{
	AstId id = *astid_ref;
	if (!id) return;
	Ast* ast = astptr(id);
	ast = fixup(c, ast);
	if (ast) *astid_ref = astid(ast);
}

// copying.c:75 (static)
fn Expr*[] copy_expr_list(CopyStruct* c, Expr*[] expr_list)
{
	Expr*[] result;
	foreach (expr : expr_list) @vec_add(&result, copy_expr(c, expr));
	return result;
}

// copying.c:82 (static)
fn DeclId decl_copy_label_from_macro(CopyStruct* c, DeclId to_copy, Ast* ast) @inline
{
	if (!to_copy) return (DeclId)0;
	Decl* copy = copy_decl(c, declptr(to_copy));
	copy.label.parent = astid(ast);
	return declid(copy);
}

// copying.c:91 (static)
fn void copy_flow(CopyStruct* c, Ast* ast) @inline
{
	ast.flow.label = decl_copy_label_from_macro(c, ast.flow.label, ast);
}

// copying.c:96 (static)
fn TypeInfo*[] type_info_copy_list_from_macro(CopyStruct* c, TypeInfo*[] to_copy)
{
	TypeInfo*[] result;
	foreach (type : to_copy) @vec_add(&result, copy_type_info(c, type));
	return result;
}

// copying.c:103 (static)
fn TypeInfoId type_info_id_copy_deep(CopyStruct* c, TypeInfoId source) @inline
{
	if (!source) return 0;
	return type_infoid(copy_type_info(c, type_infoptr(source)));
}

// copying.c:109 (static)
fn AstId astid_copy_deep(CopyStruct* c, AstId source) @inline
{
	if (!source) return 0;
	return astid(ast_copy_deep(c, astptr(source)));
}

// copying.c:115 (static)
fn ExprId exprid_copy_deep(CopyStruct* c, ExprId source) @inline
{
	if (!source) return 0;
	return exprid(copy_expr(c, exprptr(source)));
}

// copying.c:121 (static)
fn DeclId declid_copy_deep(CopyStruct* c, DeclId source) @inline
{
	if (!source) return 0;
	return declid(copy_decl(c, declptr(source)));
}

// copying.c:128 (static)
fn DesignatorElement*[] macro_copy_designator_list(CopyStruct* c, DesignatorElement*[] list)
{
	DesignatorElement*[] result;
	foreach (to_copy : list)
	{
		DesignatorElement* element = calloc_arena(DesignatorElement::size);
		*element = *to_copy;
		switch (to_copy.kind)
		{
			case FIELD:
				element.field_expr = copy_expr(c, element.field_expr);
				// Nothing needed
			case RANGE:
				element.index_end_expr = copy_expr(c, element.index_end_expr);
				element.index_expr = copy_expr(c, element.index_expr);
			case ARRAY:
				element.index_expr = copy_expr(c, element.index_expr);
		}
		@vec_add(&result, element);
	}
	return result;
}

// copying.c:157
fn Ast* copy_ast_single(Ast* source_ast)
{
	copy_begin();
	Ast* ast = ast_copy_deep(&copy_struct, source_ast);
	copy_end();
	return ast;
}

// copying.c:165
fn TypeInfo* copy_type_info_single(TypeInfo* type_info)
{
	copy_begin();
	TypeInfo* type_info_copy = copy_type_info(&copy_struct, type_info);
	copy_end();
	return type_info_copy;
}

// copying.c:173
fn Ast* copy_ast_macro(Ast* source_ast)
{
	assert(copy_struct.copy_in_use);
	return ast_copy_deep(&copy_struct, source_ast);
}

// copying.c:179
fn Ast* copy_ast_defer(Ast* source_ast)
{
	copy_begin();
	copy_struct.single_static = true;
	Ast* ast = copy_ast_macro(source_ast);
	copy_end();
	return ast;
}

// copying.c:188
fn Expr* copy_expr_single(Expr* source_expr)
{
	copy_begin();
	Expr* expr = copy_expr(&copy_struct, source_expr);
	copy_end();
	return expr;
}

// copying.c:196
fn Expr*[] copy_exprlist_macro(Expr*[] source_expr_list)
{
	assert(copy_struct.copy_in_use);
	Expr*[] list = copy_expr_list(&copy_struct, source_expr_list);
	return list;
}

// copying.c:203
fn void copy_range(CopyStruct* c, ExprRange* range)
{
	switch (range.range_type)
	{
		case SINGLE_ELEMENT:
			unreachable();
		case CONST_LEN:
		case CONST_END:
			range.start = exprid_copy_deep(c, range.start);
			return;
		case CONST_RANGE:
			return;
		case DYNAMIC:
			range.start = exprid_copy_deep(c, range.start);
			range.end = exprid_copy_deep(c, range.end);
			return;
	}
}

// copying.c:223 (static)
fn ConstInitializer*[] copy_const_initializer_list(CopyStruct* c, ConstInitializer*[] initializer_list) @inline
{
	ConstInitializer*[] initializer;
	foreach (element_orig : initializer_list)
	{
		ConstInitializer* element = element_orig;
		copy_const_initializer(c, &element);
		@vec_add(&initializer, element);
	}
	return initializer;
}

// copying.c:234 (static)
fn void copy_const_initializer(CopyStruct* c, ConstInitializer** initializer_ref)
{
	if (!*initializer_ref) return;
	ConstInitializer* copy = calloc_arena(ConstInitializer::size);
	*copy = **initializer_ref;
	*initializer_ref = copy;

	switch (copy.kind)
	{
		case INIT_ZERO:
			return;
		case INIT_STRUCT:
			copy.init_struct = copy_const_initializer_list(c, copy.init_struct);
			return;
		case INIT_UNION:
			copy_const_initializer(c, &copy.init_union.element);
			return;
		case INIT_VALUE:
			copy.init_value = copy_expr(c, copy.init_value);
			return;
		case INIT_ARRAY:
			copy.init_array.elements = copy_const_initializer_list(c, copy.init_array.elements);
			return;
		case INIT_ARRAY_FULL:
			copy.init_array_full = copy_const_initializer_list(c, copy.init_array_full);
			return;
		case INIT_ARRAY_VALUE:
			copy_const_initializer(c, &copy.init_array_value.element);
			return;
	}
}

// copying.c:267 (static)
fn Expr* copy_const_expr(CopyStruct* c, Expr* expr) @inline
{
	switch (expr.const_expr.const_kind)
	{
		case FLOAT:
		case INTEGER:
		case BOOL:
			break;
		case REF:
			fixup_decl(c, &expr.const_expr.global_ref);
		case FAULT:
			fixup_decl(c, &expr.const_expr.fault_val);
		case ENUM:
			fixup_decl(c, &expr.const_expr.enum_val);
		case BYTES:
		case STRING:
			// Assume this is never modified.
			break;
		case POINTER:
		case TYPEID:
			break;
		case SLICE:
			copy_const_initializer(c, &expr.const_expr.slice_init);
		case INITIALIZER:
			copy_const_initializer(c, &expr.const_expr.initializer);
		case UNTYPED_LIST:
			expr.const_expr.untyped_list = copy_expr_list(c, expr.const_expr.untyped_list);
		case REFLECTION:
			expr.const_expr.reflection = copy_expr(c, expr.const_expr.reflection);
		case MEMBER:
			fixup_decl(c, &expr.const_expr.member.decl);
	}
	return expr;
}

// copying.c:309 (static)
fn Expr* copy_expr(CopyStruct* c, Expr* source_expr)
{
	if (!source_expr) return null;
	Expr* expr = expr_copy(source_expr);
	switch (source_expr.expr_kind)
	{
		case TWO:
			expr.two_expr.first = copy_expr(c, expr.two_expr.first);
			expr.two_expr.last = copy_expr(c, expr.two_expr.last);
			return expr;
		case TYPE_PROPERTY:
			expr.type_property_expr.type = copy_expr(c, expr.type_property_expr.type);
			return expr;
		case CONTRACT:
			expr.contract_expr.decl_exprs = copy_expr(c, expr.contract_expr.decl_exprs);
			return expr;
		case TYPECALL:
		case CT_SUBSCRIPT:
			unreachable();
		case OTHER_CONTEXT:
			expr.expr_other_context.inner = copy_expr(c, expr.expr_other_context.inner);
			return expr;
		case NAMED_ARGUMENT:
			expr.named_argument_expr.value = copy_expr(c, expr.named_argument_expr.value);
			return expr;
		case NAMED_EVAL_ARGUMENT:
			expr.eval_named_argument_expr.name = copy_expr(c, expr.eval_named_argument_expr.name);
			expr.eval_named_argument_expr.value = copy_expr(c, expr.eval_named_argument_expr.value);
			return expr;
		case EMBED:
			expr.embed_expr.len = copy_expr(c, expr.embed_expr.len);
			expr.embed_expr.filename = copy_expr(c, expr.embed_expr.filename);
			return expr;
		case GENERIC_IDENT:
			expr.generic_ident_expr.parent = exprid_copy_deep(c, expr.generic_ident_expr.parent);
			expr.generic_ident_expr.parameters = copy_expr_list(c, expr.generic_ident_expr.parameters);
			return expr;
		case MACRO_BODY_EXPANSION:
			expr.body_expansion_expr.values = copy_expr_list(c, expr.body_expansion_expr.values);
			expr.body_expansion_expr.declarations = copy_decl_list(c, expr.body_expansion_expr.declarations);
			expr.body_expansion_expr.first_stmt = astid_copy_deep(c, expr.body_expansion_expr.first_stmt);
			return expr;
		case MACRO_BODY:
			expr.macro_body_expr.body = ast_copy_deep(c, expr.macro_body_expr.body);
			expr.macro_body_expr.body_arguments = copy_decl_list(c, expr.macro_body_expr.body_arguments);
			return expr;
		case LAMBDA:
			if (copy_struct.is_template)
			{
				expr.lambda_expr = copy_decl(c, expr.lambda_expr);
			}
			return expr;
		case MEMBER_GET:
		case MEMBER_SET:
			fixup_decl(c, &expr.member_get_expr);
			return expr;
		case SWIZZLE:
			expr.swizzle_expr.parent = exprid_copy_deep(c, expr.swizzle_expr.parent);
			return expr;
		case EXT_TRUNC:
			expr.ext_trunc_expr.inner = copy_expr(c, expr.ext_trunc_expr.inner);
			return expr;
		case INT_TO_BOOL:
			expr.int_to_bool_expr.inner = copy_expr(c, expr.int_to_bool_expr.inner);
			return expr;
		case NOP:
		case BUILTIN:
		case RETVAL:
		case OPERATOR_CHARS:
		case VACOUNT:
			return expr;
		case VASPLAT:
			copy_range(c, &expr.vasplat_expr);
			return expr;
		case POINTER_OFFSET:
			expr.pointer_offset_expr.offset = exprid_copy_deep(c, expr.pointer_offset_expr.offset);
			expr.pointer_offset_expr.ptr = exprid_copy_deep(c, expr.pointer_offset_expr.ptr);
			return expr;
		case BUILTIN_ACCESS:
			expr.builtin_access_expr.inner = exprid_copy_deep(c, expr.builtin_access_expr.inner);
			return expr;
		case DECL:
			expr.decl_expr = copy_decl(c, expr.decl_expr);
			return expr;
		case TRY:
			expr.try_expr.optional = copy_expr(c, expr.try_expr.optional);
			if (expr.try_expr.assign_existing)
			{
				expr.try_expr.lhs = copy_expr(c, expr.try_expr.lhs);
			}
			else
			{
				if (expr.try_expr.optional)
				{
					expr.try_expr.decl = copy_decl(c, expr.try_expr.decl);
				}
				else
				{
					fixup_decl(c, &expr.try_expr.decl);
				}
			}
			return expr;
		case TRY_UNRESOLVED:
			expr.unresolved_try_expr.variable = copy_expr(c, expr.unresolved_try_expr.variable);
			expr.unresolved_try_expr.init = copy_expr(c, expr.unresolved_try_expr.init);
			expr.unresolved_try_expr.type = copy_type_info(c, expr.unresolved_try_expr.type);
			return expr;
		case TRY_UNWRAP_CHAIN:
			expr.try_unwrap_chain_expr = copy_expr_list(c, expr.try_unwrap_chain_expr);
			return expr;
		case CATCH_UNRESOLVED:
			expr.unresolved_catch_expr.type = copy_type_info(c, expr.unresolved_catch_expr.type);
			expr.unresolved_catch_expr.variable = copy_expr(c, expr.unresolved_catch_expr.variable);
			expr.unresolved_catch_expr.exprs = copy_expr_list(c, expr.unresolved_catch_expr.exprs);
			return expr;
		case CATCH:
			expr.catch_expr.decl = copy_decl(c, expr.catch_expr.decl);
			expr.catch_expr.exprs = copy_expr_list(c, expr.catch_expr.exprs);
			return expr;
		case IOTA_DECL:
			fixup_decl(c, &expr.iota_decl_expr);
			return expr;
		case IDENTIFIER:
			Decl* var_ = expr.ident_expr;
			// In the case we have an unwrapped alias, we need to create it.
			if (var_.decl_kind == VAR)
			{
				switch (var_.var_decl.kind)
				{
					case UNWRAPPED:
					case REWRAPPED:
						expr.ident_expr = copy_decl(c, var_);
						return expr;
					default: break;
				}
			}
			fixup_decl(c, &expr.ident_expr);
			return expr;
		case UNRESOLVED_IDENTIFIER:
		case CT_IDENT:
		case HASH_IDENT:
			assert(expr.resolve_status != DONE);
			return expr;
		case BENCHMARK_HOOK:
		case TEST_HOOK:
		case COMPILER_CONST:
		case LAST_FAULT:
			return expr;
		case DESIGNATOR:
			expr.designator_expr.path = macro_copy_designator_list(c, expr.designator_expr.path);
			expr.designator_expr.value = copy_expr(c, expr.designator_expr.value);
			return expr;
		case TYPEINFO:
			expr.type_expr = copy_type_info(c, expr.type_expr);
			return expr;
		case SLICE_ASSIGN:
		case SLICE_COPY:
			expr.slice_assign_expr.left = exprid_copy_deep(c, expr.slice_assign_expr.left);
			expr.slice_assign_expr.right = exprid_copy_deep(c, expr.slice_assign_expr.right);
			return expr;
		case SUBSCRIPT_ASSIGN:
			unreachable();
		case SLICE:
			expr.slice_expr.expr = exprid_copy_deep(c, expr.slice_expr.expr);
			copy_range(c, &expr.slice_expr.range);
			return expr;
		case VAARG:
			expr.vaarg_index.expr = exprid_copy_deep(c, expr.vaarg_index.expr);
			return expr;
		case SUBSCRIPT_ADDR:
		case SUBSCRIPT:
			expr.subscript_expr.expr = exprid_copy_deep(c, expr.subscript_expr.expr);
			expr.subscript_expr.index.expr = exprid_copy_deep(c, expr.subscript_expr.index.expr);
			return expr;
		case ASM:
			copy_expr_asm_arg(c, &expr.expr_asm_arg);
			return expr;
		case CT_EVAL:
		case FORCE_UNWRAP:
		case OPTIONAL:
		case SPLAT:
		case STRINGIFY:
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
		case RVALUE:
		case RECAST:
		case ADDR_CONVERSION:
		case LENGTHOF:
		case MAYBE_DEREF:
		case CT_REFLECT:
		case CT_FEATURE:
			expr.inner_expr = copy_expr(c, expr.inner_expr);
			return expr;
		case MAKE_ANY:
			expr.make_any_expr.inner = copy_expr(c, expr.make_any_expr.inner);
			expr.make_any_expr.typeid_expr = copy_expr(c, expr.make_any_expr.typeid_expr);
			return expr;
		case MAKE_SLICE:
			expr.make_slice_expr.ptr = copy_expr(c, expr.make_slice_expr.ptr);
			return expr;
		case DEFAULT_ARG:
			expr.default_arg_expr.inner = copy_expr(c, expr.default_arg_expr.inner);
			return expr;
		case CT_DEFINED:
			expr.expression_list = copy_expr_list(c, expr.expression_list);
			return expr;
		case TYPEID_INFO:
			expr.typeid_info_expr.parent = exprid_copy_deep(c, expr.typeid_info_expr.parent);
			return expr;
		case COND:
			expr.cond_expr = copy_expr_list(c, expr.cond_expr);
			return expr;
		case MACRO_BLOCK:
			expr.macro_block.arguments = copy_decl_list(c, expr.macro_block.arguments);
			expr.macro_block.first_stmt = astid_copy_deep(c, expr.macro_block.first_stmt);
			fixup_decl(c, &expr.macro_block.macro_decl);
			return expr;
		case COMPOUND_LITERAL:
			expr.expr_compound_literal.initializer = copy_expr(c, expr.expr_compound_literal.initializer);
			expr.expr_compound_literal.type_info = copy_type_info(c, expr.expr_compound_literal.type_info);
			return expr;
		case POISONED:
			return expr;
		case RETHROW:
			expr.rethrow_expr.inner = copy_expr(c, expr.rethrow_expr.inner);
			expr.rethrow_expr.cleanup = astid_copy_deep(c, expr.rethrow_expr.cleanup);
			return expr;
		case CONST:
			return copy_const_expr(c, expr);
		case BINARY:
		case BITASSIGN:
			expr.binary_expr.left = exprid_copy_deep(c, expr.binary_expr.left);
			expr.binary_expr.right = exprid_copy_deep(c, expr.binary_expr.right);
			return expr;
		case TERNARY:
			expr.ternary_expr.cond = exprid_copy_deep(c, expr.ternary_expr.cond);
			expr.ternary_expr.then_expr = exprid_copy_deep(c, expr.ternary_expr.then_expr);
			expr.ternary_expr.else_expr = exprid_copy_deep(c, expr.ternary_expr.else_expr);
			return expr;
		case UNARY:
		case POST_UNARY:
			expr.unary_expr.expr = copy_expr(c, expr.unary_expr.expr);
			return expr;
		case TYPEID:
			expr.typeid_expr = copy_type_info(c, expr.typeid_expr);
			return expr;
		case CALL:
			if (expr.call_expr.is_func_ref)
			{
				fixup_declid(c, &expr.call_expr.func_ref);
			}
			else
			{
				expr.call_expr.function = exprid_copy_deep(c, expr.call_expr.function);
			}
			// Arguments must be copied before contracts are copied
			// or things will break.
			expr.call_expr.arguments = copy_expr_list(c, expr.call_expr.arguments);
			if (expr.resolve_status == DONE)
			{
				expr.call_expr.function_contracts = astid_copy_deep(c, expr.call_expr.function_contracts);
			}
			else
			{
				expr.call_expr.macro_body = exprid_copy_deep(c, expr.call_expr.macro_body);
			}
			if (expr.call_expr.varargs.ptr)
			{
				if (expr.call_expr.va_is_splat)
				{
					expr.call_expr.vasplat = copy_expr(c, expr.call_expr.vasplat);
				}
				else
				{
					expr.call_expr.varargs = copy_expr_list(c, expr.call_expr.varargs);
				}
			}
			return expr;
		case ACCESS_UNRESOLVED:
			expr.access_unresolved_expr.parent = copy_expr(c, expr.access_unresolved_expr.parent);
			expr.access_unresolved_expr.child = copy_expr(c, expr.access_unresolved_expr.child);
			return expr;
		case BITACCESS:
		case ACCESS_RESOLVED:
			expr.access_resolved_expr.parent = copy_expr(c, expr.access_resolved_expr.parent);
			fixup_decl(c, &expr.access_resolved_expr.ref);
			return expr;
		case INITIALIZER_LIST:
			expr.initializer_list = copy_expr_list(c, expr.initializer_list);
			return expr;
		case DESIGNATED_INITIALIZER_LIST:
			expr.designated_init.splat = copy_expr(c, expr.designated_init.splat);
			expr.designated_init.list = copy_expr_list(c, expr.designated_init.list);
			return expr;
		case EXPRESSION_LIST:
			expr.expression_list = copy_expr_list(c, expr.expression_list);
			return expr;
		case CAST:
			expr.cast_expr.expr = exprid_copy_deep(c, expr.cast_expr.expr);
			expr.cast_expr.type_info = type_info_id_copy_deep(c, expr.cast_expr.type_info);
			return expr;
	}
}

// copying.c:627 (static)
fn void copy_expr_asm_arg(CopyStruct* c, ExprAsmArg* arg)
{
	switch (arg.kind)
	{
		case ARG_MEMADDR:
		case ARG_REGVAR:
		case ARG_MEMVAR:
			if (arg.resolved) fixup_decl(c, &arg.ident.ident_decl);
			return;
		case ARG_REG:
		case ARG_INT:
			return;
		case ARG_ADDR:
			arg.base = exprid_copy_deep(c, arg.base);
			arg.idx = exprid_copy_deep(c, arg.idx);
			return;
		case ARG_VALUE:
			arg.expr_id = exprid_copy_deep(c, arg.expr_id);
			return;
	}
}

// copying.c:649 (static)
fn ExprAsmArg*[] copy_expr_asm_arg_list(CopyStruct* c, ExprAsmArg*[] args)
{
	ExprAsmArg*[] new_args;
	foreach (arg : args)
	{
		ExprAsmArg* new_arg = calloc_arena(ExprAsmArg::size);
		*new_arg = *arg;
		copy_expr_asm_arg(c, new_arg);
		@vec_add(&new_args, new_arg);
	}
	return new_args;
}

// copying.c:662 (static)
fn Ast* ast_copy_deep(CopyStruct* c, Ast* source)
{
	if (!source) return null;
	Ast* ast = ast_copy(source);
	Ast* first_return = ast;
	AstId* assign_to = null;
	while (true)
	{
		if (assign_to)
		{
			ast = ast_copy(source);
			*assign_to = astid(ast);
		}
		switch (source.ast_kind)
		{
			case POISONED:
				break;
			case CT_TYPE_ASSIGN_STMT:
				ast.ct_type_assign_stmt.type_expr = copy_expr(c, ast.ct_type_assign_stmt.type_expr);
			case DECLS_STMT:
				ast.decls_stmt = copy_decl_list(c, ast.decls_stmt);
			case CT_EXPAND_STMT:
				ast.expr_stmt = copy_expr(c, ast.expr_stmt);
			case ASM_BLOCK_STMT:
				if (ast.asm_block_stmt.is_string)
				{
					ast.asm_block_stmt.asm_string = exprid_copy_deep(c, ast.asm_block_stmt.asm_string);
				}
				else
				{
					AsmInlineBlock* block = calloc_arena(AsmInlineBlock::size);
					*block = *ast.asm_block_stmt.block;
					ast.asm_block_stmt.block = block;
					block.asm_stmt = astid_copy_deep(c, block.asm_stmt);
					block.labels = copy_ast_list(c, block.labels);
					block.input = copy_expr_asm_arg_list(c, block.input);
					block.output_vars = copy_expr_asm_arg_list(c, block.output_vars);
				}
			case ASM_STMT:
				ast.asm_stmt.args = copy_expr_list(c, ast.asm_stmt.args);
			case ASSERT_STMT:
			case CT_ASSERT:
				ast.assert_stmt.expr = exprid_copy_deep(c, ast.assert_stmt.expr);
				ast.assert_stmt.message = exprid_copy_deep(c, ast.assert_stmt.message);
				ast.assert_stmt.args = copy_expr_list(c, ast.assert_stmt.args);
			case BREAK_STMT:
			case CONTINUE_STMT:
				if (ast.contbreak_stmt.is_resolved)
				{
					fixup_astid(c, &ast.contbreak_stmt.ast);
					ast.contbreak_stmt.defers = astid_copy_deep(c, ast.contbreak_stmt.defers);
				}
			case CASE_STMT:
				copy_reg_ref(c, source, ast);
				ast.case_stmt.body = ast_copy_deep(c, ast.case_stmt.body);
				ast.case_stmt.expr = exprid_copy_deep(c, ast.case_stmt.expr);
				ast.case_stmt.to_expr = exprid_copy_deep(c, ast.case_stmt.to_expr);
			case COMPOUND_STMT:
				ast.compound_stmt.first_stmt = astid_copy_deep(c, ast.compound_stmt.first_stmt);
				fixup_astid(c, &ast.compound_stmt.parent_defer);
			case CT_IF_STMT:
				ast.ct_if_stmt.expr = copy_expr(c, ast.ct_if_stmt.expr);
				ast.ct_if_stmt.elif = astid_copy_deep(c, ast.ct_if_stmt.elif);
				ast.ct_if_stmt.then = astid_copy_deep(c, ast.ct_if_stmt.then);
			case CT_ELSE_STMT:
				ast.ct_else_stmt = astid_copy_deep(c, ast.ct_else_stmt);
			case CT_FOREACH_STMT:
				ast.ct_foreach_stmt.index = declid_copy_deep(c, ast.ct_foreach_stmt.index);
				ast.ct_foreach_stmt.value = declid_copy_deep(c, ast.ct_foreach_stmt.value);
				ast.ct_foreach_stmt.body = astid_copy_deep(c, ast.ct_foreach_stmt.body);
				ast.ct_foreach_stmt.expr = exprid_copy_deep(c, ast.ct_foreach_stmt.expr);
			case CT_SWITCH_STMT:
				ast.ct_switch_stmt.cond = exprid_copy_deep(c, ast.ct_switch_stmt.cond);
				ast.ct_switch_stmt.body = copy_ast_list(c, ast.ct_switch_stmt.body);
			case CT_COMPOUND_STMT:
				ast.ct_compound_stmt = astid_copy_deep(c, ast.ct_compound_stmt);
			case DECLARE_STMT:
				ast.declare_stmt = copy_decl(c, ast.declare_stmt);
			case DEFAULT_STMT:
				ast.case_stmt.body = ast_copy_deep(c, ast.case_stmt.body);
			case DEFER_STMT:
				copy_reg_ref(c, source, ast);
				ast.defer_stmt.body = astid_copy_deep(c, ast.defer_stmt.body);
				fixup_astid(c, &ast.defer_stmt.prev_defer);
			case CT_ECHO_STMT:
			case EXPR_STMT:
				ast.expr_stmt = copy_expr(c, ast.expr_stmt);
			case FOR_STMT:
			case CT_FOR_STMT:
				copy_reg_ref(c, source, ast);
				CopyFixup* current = c.current_fixup;
				copy_flow(c, ast);
				ast.for_stmt.init = exprid_copy_deep(c, ast.for_stmt.init);
				ast.for_stmt.cond = exprid_copy_deep(c, ast.for_stmt.cond);
				ast.for_stmt.body = astid_copy_deep(c, ast.for_stmt.body);
				ast.for_stmt.incr = exprid_copy_deep(c, ast.for_stmt.incr);
				c.current_fixup = current;
			case FOREACH_STMT:
				copy_reg_ref(c, source, ast);
				CopyFixup* current = c.current_fixup;
				copy_flow(c, ast);
				ast.foreach_stmt.enumeration = exprid_copy_deep(c, ast.foreach_stmt.enumeration);
				ast.foreach_stmt.index = declid_copy_deep(c, ast.foreach_stmt.index);
				ast.foreach_stmt.variable = declid_copy_deep(c, ast.foreach_stmt.variable);
				ast.foreach_stmt.body = astid_copy_deep(c, ast.foreach_stmt.body);
				c.current_fixup = current;
			case IF_STMT:
				// We don't scope "if" for the simple reason that it might introduce a wrapper alias.
				copy_reg_ref(c, source, ast);
				copy_flow(c, ast);
				ast.if_stmt.cond = exprid_copy_deep(c, ast.if_stmt.cond);
				ast.if_stmt.else_body = astid_copy_deep(c, ast.if_stmt.else_body);
				ast.if_stmt.then_body = astid_copy_deep(c, ast.if_stmt.then_body);
			case NEXTCASE_STMT:
				if (ast.nextcase_stmt.is_resolved)
				{
					ast.nextcase_stmt.defer_id = astid_copy_deep(c, ast.nextcase_stmt.defer_id);
					if (ast.nextcase_stmt.is_expr) ast.nextcase_stmt.nextcase_value = copy_expr(c, ast.nextcase_stmt.nextcase_value);
					fixup_astid(c, &ast.nextcase_stmt.switch_stmt);
				}
				else
				{
					ast.nextcase_stmt.expr = exprid_copy_deep(c, ast.nextcase_stmt.expr);
				}
			case NOP_STMT:
			case ASM_LABEL:
				break;
			case BLOCK_EXIT_STMT:
			case RETURN_STMT:
				ast.return_stmt.expr = copy_expr(c, ast.return_stmt.expr);
				ast.return_stmt.cleanup = astid_copy_deep(c, ast.return_stmt.cleanup);
				ast.return_stmt.cleanup_fail = astid_copy_deep(c, ast.return_stmt.cleanup_fail);
			case SWITCH_STMT:
				copy_reg_ref(c, source, ast);
				CopyFixup* current = c.current_fixup;
				copy_flow(c, ast);
				ast.switch_stmt.cond = exprid_copy_deep(c, ast.switch_stmt.cond);
				ast.switch_stmt.cases = copy_ast_list(c, ast.switch_stmt.cases);
				c.current_fixup = current;
		}
		assign_to = &ast.next;
		AstId next = *assign_to;
		if (!next) return first_return;
		source = astptr(next);
	}
}

// copying.c:833 (static)
fn Ast*[] copy_ast_list(CopyStruct* c, Ast*[] to_copy)
{
	Ast*[] result;
	foreach (ast : to_copy) @vec_add(&result, ast_copy_deep(c, ast));
	return result;
}

// copying.c:840
fn void copy_begin()
{
	if (!copy_struct.fixups.len)
	{
		copy_struct.fixups = &copy_fixup_storage;
	}
	copy_struct.current_fixup = copy_struct.fixups.ptr;
	assert(!copy_struct.copy_in_use);
	copy_struct.copy_in_use = true;
	copy_struct.single_static = false;
}

// copying.c:848
fn void copy_end()
{
	assert(copy_struct.copy_in_use);
	copy_struct.copy_in_use = false;
}

// copying.c:854
fn Decl*[] copy_decl_list_macro(Decl*[] decl_list)
{
	assert(copy_struct.copy_in_use);
	return copy_decl_list(&copy_struct, decl_list);
}

// copying.c:860
fn Decl*[] copy_decl_list_single(Decl*[] decl_list)
{
	copy_begin();
	Decl*[] result = copy_decl_list_macro(decl_list);
	copy_end();
	return result;
}

// copying.c:868 (static)
fn Attr* copy_attribute(CopyStruct* c, Attr* attr) @inline
{
	if (!attr) return null;
	Attr* copy = calloc_arena(Attr::size);
	*copy = *attr;
	copy.exprs = copy_expr_list(c, copy.exprs);
	return copy;
}

// copying.c:877 (static)
fn Attr*[] copy_attributes(CopyStruct* c, Attr*[] attr_list)
{
	if (!attr_list.len) return attr_list;
	Attr*[] list;
	foreach (attribute : attr_list)
	{
		@vec_add(&list, copy_attribute(c, attribute));
	}
	return list;
}

// copying.c:889 (static)
fn ResolvedAttrData* copy_attrs_resolved(CopyStruct* c, ResolvedAttrData* data)
{
	if (!data) return null;
	ResolvedAttrData* copy = calloc_arena(ResolvedAttrData::size);
	String[] new_links;
	foreach (link : data.links) @vec_add(&new_links, link);
	*copy = {
		.tags = copy_attributes(c, data.tags),
		.deprecated = data.deprecated,
		.links = new_links,
		.section = data.section,
		.wasm_module = data.wasm_module,
		.overload = data.overload,
	};
	return copy;
}

// copying.c:906
fn Attr*[] copy_attributes_single(Attr*[] attr_list)
{
	copy_begin();
	Attr*[] attrs = copy_attributes(&copy_struct, attr_list);
	copy_end();
	return attrs;
}

// copying.c:914 (static)
fn void copy_rename_inner_types(Decl* decl, String prefix, int old_len)
{
	foreach (member : decl.strukt.members)
	{
		switch (member.decl_kind)
		{
			case STRUCT:
			case UNION:
				copy_rename_inner_types(member, prefix, old_len);
				nextcase BITSTRUCT;
			case BITSTRUCT:
				scratch_buffer_clear();
				scratch_buffer_append(prefix);
				scratch_buffer_append(member.type.name[old_len..]);
				member.type.name = scratch_buffer_interned();
			default:
				break;
		}
	}
}

// copying.c:936
fn Decl*[] copy_decl_list_single_for_generic(Decl*[] decl_list, Decl* generic_instance)
{
	String name_suffix = generic_instance.instance_decl.name_suffix;
	bool old_is_template = copy_struct.is_template;
	DeclId old_instance = copy_struct.instance_id;
	copy_struct.is_template = true;
	copy_struct.instance_id = declid(generic_instance);
	copy_begin();
	Decl*[] result = copy_decl_list_macro(decl_list);
	foreach (decl : result)
	{
		// Only change the name if it's not a macro or a function.
		if ((decl.decl_kind != FUNC && decl.decl_kind != MACRO) || !decl.func_decl.type_parent)
		{
			int old_len = (int)decl.name.len;
			scratch_buffer_clear();
			scratch_buffer_append(decl.name);
			scratch_buffer_append(name_suffix);
			decl.name = scratch_buffer_interned();
			if (decl_is_user_defined_type(decl))
			{
				decl.type.name = decl.name;
				if (decl_is_struct_type(decl)) copy_rename_inner_types(decl, decl.name, old_len);
			}
		}
		decl.is_templated = true;
		decl.instance_id = declid(generic_instance);
	}
	copy_end();
	copy_struct.is_template = old_is_template;
	copy_struct.instance_id = old_instance;
	return result;
}

// copying.c:970
fn Decl* copy_lambda_deep(Decl* decl)
{
	bool old_is_template = copy_struct.is_template;
	DeclId old_instance = copy_struct.instance_id;
	copy_struct.is_template = true;
	copy_begin();
	Decl* result = copy_decl(&copy_struct, decl);
	copy_end();
	copy_struct.is_template = old_is_template;
	copy_struct.instance_id = old_instance;
	return result;
}

// copying.c:983 (static)
fn Decl*[] copy_decl_list(CopyStruct* c, Decl*[] decl_list)
{
	Decl*[] result;
	foreach (decl : decl_list) @vec_add(&result, copy_decl(c, decl));
	return result;
}

// copying.c:990 (static)
fn Methods* copy_decl_methods(CopyStruct* c, Methods* methods)
{
	if (!methods) return null;
	Methods* copy = calloc_arena(Methods::size);
	decltable_init(&copy.method_table, 64);

	foreach (method : methods.methods)
	{
		methods_add(copy, copy_decl(c, method));
	}
	return copy;
}

// copying.c:1003 (static)
fn TypeInfo* copy_type_info(CopyStruct* c, TypeInfo* source)
{
	if (!source) return null;
	TypeInfo* copy = type_info_copy(source);
	if (source.resolve_status == DONE) return copy;
	switch (source.kind)
	{
		case INFO_POISON:
			return copy;
		case INFO_CT_IDENTIFIER:
		case INFO_IDENTIFIER:
			return copy;
		case INFO_GENERIC:
			copy.generic.base = copy_type_info(c, copy.generic.base);
			copy.generic.params = copy_expr_list(c, copy.generic.params);
			return copy;
		case INFO_TYPEFROM:
		case INFO_TYPEOF:
			assert(source.resolve_status == NOT_DONE);
			copy.unresolved_type_expr = copy_expr(c, source.unresolved_type_expr);
			return copy;
		case INFO_VECTOR:
		case INFO_ARRAY:
			assert(source.resolve_status == NOT_DONE);
			copy.array.len = copy_expr(c, source.array.len);
			copy.array.base = copy_type_info(c, source.array.base);
			return copy;
		case INFO_INFERRED_ARRAY:
		case INFO_SLICE:
		case INFO_INFERRED_VECTOR:
			assert(source.resolve_status == NOT_DONE);
			copy.array.base = copy_type_info(c, source.array.base);
			return copy;
		case INFO_POINTER:
			copy.pointer = copy_type_info(c, source.pointer);
			return copy;
	}
}

// copying.c:1043 (static)
fn void copy_signature_deep(CopyStruct* c, Signature* signature)
{
	signature.params = copy_decl_list(c, signature.params);
	signature.rtype = type_info_id_copy_deep(c, signature.rtype);
}

// copying.c:1048
fn void copy_decl_type(Decl* decl)
{
	Type* type = decl.type;
	if (!type) return;
	Type* copy = type_new(type.type_kind, type.name);
	*copy = *type;
	copy.type_cache = {};
	copy.decl = decl;
	copy.canonical = copy;
	decl.type = copy;
}

// copying.c:1061 (static)
fn bool decl_is_resolved_static_var(Decl* decl) @inline
{
	if (decl.resolve_status != DONE) return false;
	if (decl.decl_kind != VAR) return false;
	if (decl.var_decl.kind != LOCAL) return false;
	return decl.var_decl.is_static;
}

// copying.c:1069 (static)
fn Decl* copy_decl(CopyStruct* c, Decl* decl)
{
	if (!decl) return null;
	if (c.single_static && decl_is_resolved_static_var(decl)) return decl;
	Decl* copy = decl_copy(decl);
	assert(!copy.is_template || c.instance_id);

	if (c.instance_id)
	{
		copy.is_template = false;
		copy.is_templated = true;
		copy.instance_id = c.instance_id;
	}

	copy_reg_ref(c, decl, copy);
	copy.docs = declid_copy_deep(c, copy.docs);
	if (decl.resolved_attributes)
	{
		copy.attrs_resolved = copy_attrs_resolved(c, copy.attrs_resolved);
	}
	else
	{
		copy.attributes = copy_attributes(c, copy.attributes);
	}
	switch (decl.decl_kind)
	{
		case POISONED:
			break;
		case ERASED:
			break;
		case GENERIC:
		case GENERIC_INSTANCE:
			unreachable();
		case CONTRACT:
			copy.contracts_decl.requires = copy_expr_list(c, copy.contracts_decl.requires);
			copy.contracts_decl.ensures = copy_expr_list(c, copy.contracts_decl.ensures);
			if (copy.resolve_status == DONE)
			{
				copy.contracts_decl.opt_returns_resolved = copy_decl_list(c, copy.contracts_decl.opt_returns_resolved);
			}
			else
			{
				copy.contracts_decl.opt_returns = copy_expr_list(c, copy.contracts_decl.opt_returns);
			}
		case INTERFACE:
			copy_decl_type(copy);
			copy.interfaces = type_info_copy_list_from_macro(c, copy.interfaces);
			copy.method_table = copy_decl_methods(c, copy.method_table);
			copy.interface_methods = copy_decl_list(c, copy.interface_methods);
		case CT_EXPAND:
			copy.expand_decl = copy_expr(c, copy.expand_decl);
		case CT_EXEC:
			copy.exec_decl.filename = copy_expr(c, copy.exec_decl.filename);
			copy.exec_decl.args = copy_expr_list(c, copy.exec_decl.args);
			copy.exec_decl.stdin_string = copy_expr(c, copy.exec_decl.stdin_string);
		case CT_INCLUDE:
			copy.include.filename = copy_expr(c, copy.include.filename);
		case BODYPARAM:
			copy.body_params = copy_decl_list(c, copy.body_params);
		case UNION:
		case STRUCT:
			copy_decl_type(copy);
			fixup_declid(c, &copy.strukt.parent);
			copy.interfaces = type_info_copy_list_from_macro(c, copy.interfaces);
			copy.strukt.members = copy_decl_list(c, copy.strukt.members);
			copy.strukt.padded_decl_id = declid_copy_deep(c, copy.strukt.padded_decl_id);
			copy.method_table = copy_decl_methods(c, copy.method_table);
		case DECLARRAY:
			copy.decls = copy_decl_list(c, copy.decls);
		case GROUP:
			unreachable();
		case BITSTRUCT:
			copy_decl_type(copy);
			fixup_declid(c, &copy.strukt.parent);
			copy.interfaces = type_info_copy_list_from_macro(c, copy.interfaces);
			copy.strukt.members = copy_decl_list(c, copy.strukt.members);
			copy.strukt.container_type = copy_type_info(c, copy.strukt.container_type);
			copy.method_table = copy_decl_methods(c, copy.method_table);
		case FAULT:
			break;
		case CONSTSET:
			copy_decl_type(copy);
			copy.interfaces = type_info_copy_list_from_macro(c, copy.interfaces);
			copy.method_table = copy_decl_methods(c, copy.method_table);
			copy.enums.type_info = copy_type_info(c, copy.enums.type_info);
			copy.enums.values = copy_decl_list(c, copy.enums.values);
		case ENUM:
			copy_decl_type(copy);
			copy.interfaces = type_info_copy_list_from_macro(c, copy.interfaces);
			copy.method_table = copy_decl_methods(c, copy.method_table);
			copy.enums.parameters = copy_decl_list(c, copy.enums.parameters);
			copy.enums.type_info = copy_type_info(c, copy.enums.type_info);
			copy.enums.values = copy_decl_list(c, copy.enums.values);
		case FNTYPE:
			copy_signature_deep(c, &copy.fntype_decl.signature);
		case FUNC:
			copy_decl_type(copy);
			copy.func_decl.type_parent = type_info_id_copy_deep(c, copy.func_decl.type_parent);
			copy_signature_deep(c, &copy.func_decl.signature);
			copy.func_decl.body = astid_copy_deep(c, copy.func_decl.body);
		case VAR:
			copy.var_decl.type_info = type_info_id_copy_deep(c, copy.var_decl.type_info);
			switch (copy.var_decl.kind)
			{
				case UNWRAPPED:
				case REWRAPPED:
					fixup_decl(c, &copy.var_decl.alias_decl);
				case BITMEMBER:
					if (copy.var_decl.bit_is_expr)
					{
						copy.var_decl.start = copy_expr(c, copy.var_decl.start);
						copy.var_decl.end = copy_expr(c, copy.var_decl.end);
					}
				default:
					copy.var_decl.init_expr = copy_expr(c, copy.var_decl.init_expr);
			}
		case LABEL:
			// Note that the ast id should be patched by the parent.
			return copy;
		case ENUM_CONSTANT:
			if (copy.enum_constant.is_raw)
			{
				if (copy.resolve_status != DONE)
				{
					copy.enum_constant.value = copy_expr(c, copy.enum_constant.value);
				}
			}
			else
			{
				copy.enum_constant.associated = copy_expr_list(c, copy.enum_constant.associated);
			}
		case TYPE_ALIAS:
			copy_decl_type(copy);
			if (copy.type_alias_decl.is_func)
			{
				copy.type_alias_decl.decl = copy_decl(c, copy.type_alias_decl.decl);
				break;
			}
			copy.type_alias_decl.type_expr = copy_expr(c, copy.type_alias_decl.type_expr);
		case TYPEDEF:
			copy_decl_type(copy);
			copy.interfaces = type_info_copy_list_from_macro(c, copy.interfaces);
			copy.method_table = copy_decl_methods(c, copy.method_table);
			copy.distinct = copy_type_info(c, copy.distinct);
			copy.distinct_align = copy_expr(c, copy.distinct_align);
		case CT_ECHO:
			copy.ct_echo_decl = ast_copy_deep(c, copy.ct_echo_decl);
		case CT_ASSERT:
			copy.ct_assert_decl = ast_copy_deep(c, copy.ct_assert_decl);
		case IMPORT:
		case ALIAS_PATH:
			break;
		case MACRO:
			copy.func_decl.type_parent = type_info_id_copy_deep(c, copy.func_decl.type_parent);
			copy_signature_deep(c, &copy.func_decl.signature);
			copy.func_decl.body = astid_copy_deep(c, copy.func_decl.body);
			copy.func_decl.body_param = declid_copy_deep(c, copy.func_decl.body_param);
		case ATTRIBUTE:
			copy.attr_decl.params = copy_decl_list(c, copy.attr_decl.params);
			copy.attr_decl.attrs = copy_attributes(c, copy.attr_decl.attrs);
		case ALIAS:
			if (copy.resolve_status == DONE)
			{
				fixup_decl(c, &copy.define_decl.alias_decl);
				break;
			}
			copy.define_decl.alias_expr = copy_expr(c, copy.define_decl.alias_expr);
	}
	return copy;
}
