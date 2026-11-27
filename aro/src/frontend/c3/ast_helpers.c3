// Port of c3c src/compiler/ast.c plus the Ast / Decl / TypeInfo inline helpers
// of compiler_internal.h (ast_new, new_ast, ast_append, ast_ok, decl_ok,
// decl_poison, type_info_new, ...) and the `poisoned_*` globals.
// Type predicates live in types.c3, Expr helpers in expr.c3.
//
// Deviations from c3c:
// - The token -> operator tables (`binary_op`, `unary_op`, `assign_binop`)
//   are const arrays indexed by `.ordinal`.
// - Fields renamed in ast.c3 (`var` -> `var_decl`, `define_decl.alias` ->
//   `alias_decl`, `unit->module` -> `unit.mod`, ...).
// - `NON_TYPE_DECLS` and similar case-group macros are spelled out.
// - `poisoned_reset()` (tests) restores the poison nodes, which c3c never
//   resets.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

Type poison_type;
TypeInfo poison_type_info;
Decl poison_decl;
Expr poison_expr;
Ast poison_ast;

Type* poisoned_type = &poison_type;
TypeInfo* poisoned_type_info = &poison_type_info;
Decl* poisoned_decl = &poison_decl;
Expr* poisoned_expr = &poison_expr;
Ast* poisoned_ast = &poison_ast;

<* Restore the poison nodes to their c3c initial state. *>
fn void poisoned_reset()
{
	poison_type = { .type_kind = POISONED };
	poison_type_info = { .kind = INFO_POISON };
	poison_decl = { .decl_kind = POISONED, .resolve_status = DONE };
	poison_expr = { .expr_kind = POISONED, .resolve_status = DONE };
	poison_ast = { .ast_kind = POISONED };
}

// ---------------------------------------------------------------------------
// Inline helpers (compiler_internal.h)

fn Ast* ast_new(AstKind kind, SourceLocId loc)
{
	Ast* ast = ast_calloc();
	ast.ast_kind = kind;
	ast.loc = loc;
	return ast;
}

fn TypeInfo* vartype(Decl* var_) => type_infoptrzero(var_.var_decl.type_info);

fn Type* typeget(TypeInfoId id_) => id_ ? type_infoptr(id_).type : null;

fn void ast_append(AstId** succ, Ast* next)
{
	**succ = astid(next);
	*succ = &next.next;
}

fn bool ast_ok(Ast* ast) => ast == null || ast.ast_kind != POISONED;

fn bool ast_poison(Ast* ast)
{
	ast.ast_kind = POISONED;
	return false;
}

fn Ast* new_ast(AstKind kind, SourceLocId loc)
{
	Ast* ast = ast_calloc();
	ast.loc = loc;
	ast.ast_kind = kind;
	return ast;
}

fn Ast* new_ast_loc(AstKind kind, SourceLoc loc)
{
	Ast* ast = ast_calloc();
	ast.loc = make_loc(loc);
	ast.ast_kind = kind;
	return ast;
}

fn Ast* ast_last(Ast* ast)
{
	while (ast.next) ast = astptr(ast.next);
	return ast;
}

fn void ast_prepend(AstId* first, Ast* ast)
{
	Ast* end = ast;
	while (end.next)
	{
		end = astptr(end.next);
	}
	end.next = *first;
	*first = astid(ast);
}

fn Ast* ast_next(AstId* current_ptr)
{
	Ast* ast = astptr(*current_ptr);
	*current_ptr = ast.next;
	return ast;
}

fn TypeInfo* type_info_new(TypeInfoKind kind, SourceLocId loc)
{
	TypeInfo* type_info = type_info_calloc();
	type_info.kind = kind;
	type_info.loc = loc;
	type_info.resolve_status = NOT_DONE;
	return type_info;
}

fn TypeInfo* type_info_new_base(Type* type, SourceLocId loc)
{
	TypeInfo* type_info = type_info_calloc();
	type_info.kind = INFO_IDENTIFIER;
	type_info.resolve_status = DONE;
	type_info.type = type;
	type_info.loc = loc;
	return type_info;
}

fn TypeInfoId type_info_id_new_base(Type* type, SourceLocId span) => type_infoid(type_info_new_base(type, span));

fn bool type_info_ok(TypeInfo* type_info) => type_info == null || type_info.kind != INFO_POISON;

fn bool type_info_poison(TypeInfo* type)
{
	type.kind = INFO_POISON;
	type.type = poisoned_type;
	type.resolve_status = DONE;
	return false;
}

fn bool decl_ok(Decl* decl) => decl == null || decl.decl_kind != POISONED;

fn bool decl_poison(Decl* decl)
{
	decl.decl_kind = POISONED;
	decl.resolve_status = DONE;
	return false;
}

fn Decl* decl_raw(Decl* decl)
{
	while (decl.decl_kind == ALIAS)
	{
		decl = decl.define_decl.alias_decl;
	}
	if (decl.decl_kind != VAR || decl.var_decl.kind != UNWRAPPED) return decl;
	decl = decl.var_decl.alias_decl;
	assert(decl.decl_kind != VAR || decl.var_decl.kind != UNWRAPPED);
	return decl;
}

fn bool decl_is_struct_type(Decl* decl)
{
	DeclKind kind = decl.decl_kind;
	return kind == UNION || kind == STRUCT;
}

fn bool decl_has_interface(Decl* decl)
{
	switch (decl.decl_kind)
	{
		case UNION:
		case STRUCT:
		case ENUM:
		case CONSTSET:
		case TYPEDEF:
		case BITSTRUCT:
			return true;
		default:
			return false;
	}
}

fn bool decl_is_fn_macro(Decl* decl)
{
	DeclKind kind = decl.decl_kind;
	return kind == FUNC || kind == MACRO;
}

fn bool decl_has_members(Decl* decl)
{
	DeclKind kind = decl.decl_kind;
	return kind == UNION || kind == STRUCT || kind == BITSTRUCT;
}

fn bool decl_is_user_defined_type(Decl* decl)
{
	DeclKind kind = decl.decl_kind;
	return kind == UNION || kind == STRUCT || kind == BITSTRUCT || kind == ENUM || kind == TYPE_ALIAS
	       || kind == TYPEDEF || kind == INTERFACE;
}

fn void decl_used(Decl* decl)
{
	decl.is_used = true;
}

fn void decl_read(Decl* decl)
{
	decl.is_used = true;
	assert(decl.decl_kind == VAR);
	decl.var_decl.is_read = true;
}

fn void decl_write(Decl* decl)
{
	assert(decl.decl_kind == VAR);
	decl.is_used = true;
	decl.var_decl.is_written = true;
}

fn void decl_addr(Decl* decl)
{
	assert(decl.decl_kind == VAR);
	decl.is_used = true;
	decl.var_decl.is_addr = true;
}

fn Decl* decl_flatten(Decl* decl)
{
	if (decl.decl_kind == ALIAS) return decl.define_decl.alias_decl;
	return decl;
}

fn TypeInfo* decl_find_method_target(Decl* decl) => type_infoptr(decl.func_decl.type_parent);

fn TypeInfo* decl_find_target_if_method(Decl* decl) => type_infoptrzero(decl.func_decl.type_parent);

fn bool decl_skip_benchtest_function(Decl* decl)
{
	// Always added
	bool is_test = decl.func_decl.attr_test;
	bool is_bench = decl.func_decl.attr_benchmark;
	if (!is_test && !is_bench) return false;
	bool keep_bench = is_bench && compiler.build.build_benchmark;
	bool keep_test = is_test && compiler.build.build_test;
	return !keep_bench && !keep_test;
}

fn DeclKind decl_from_token(TokenType type)
{
	if (type == STRUCT) return STRUCT;
	if (type == UNION) return UNION;
	if (type == BITSTRUCT) return BITSTRUCT;
	unreachable();
}

fn bool decl_var_kind_is_ct(VarDeclKind kind) => kind >= VARDECL_FIRST_CT && kind <= VARDECL_LAST_CT;

fn bool decl_is_var_local(Decl* decl)
{
	if (decl.decl_kind != VAR) return false;
	VarDeclKind kind = decl.var_decl.kind;
	return kind == PARAM_CT_TYPE
	       || kind == PARAM
	       || kind == PARAM_CT
	       || kind == LOCAL
	       || kind == LOCAL_CT_TYPE
	       || kind == LOCAL_CT
	       || kind == PARAM_EXPR
	       || kind == BITMEMBER
	       || kind == MEMBER;
}

fn Decl* decl_new_loc(DeclKind decl_kind, String name, SourceLoc loc) => decl_new(decl_kind, name, make_loc(loc));

fn ResolvedAttrData* decl_get_resolved_attributes(Decl* decl)
{
	return decl.resolved_attributes ? decl.attrs_resolved : null;
}

fn ResolvedAttrData* decl_create_resolved_attributes(Decl* decl)
{
	assert(decl.resolved_attributes);
	return decl.attrs_resolved = calloc_arena(ResolvedAttrData::size);
}

fn void methods_add(Methods* methods, Decl* method)
{
	@vec_add(&methods.methods, method);
	OperatorOverload operator = method.func_decl.operator;
	if (operator)
	{
		if (operator >= OVERLOAD_SUBSCRIPTS_FIRST && operator <= OVERLOAD_SUBSCRIPTS_LAST)
		{
			methods.has_subscript_overloads = true;
		}
		usz len = method.func_decl.signature.params.len;
		if (operator == OVERLOAD_MINUS && len == 1)
		{
			method.func_decl.operator = operator = OVERLOAD_UNARY_MINUS;
		}
		if (len > 1 && !method.func_decl.signature.params[1].var_decl.type_info)
		{
			method.func_decl.is_wildcard_overload = true;
		}
		DeclId* decl = &methods.overloads[operator];
		if (!*decl)
		{
			*decl = declid(method);
		}
		else
		{
			Decl* current = declptr(*decl);
			if (current.decl_kind != DECLARRAY)
			{
				Decl* decl_array = decl_new(DECLARRAY, {}, 0);
				@vec_add(&decl_array.decls, declptr(*decl));
				@vec_add(&decl_array.decls, method);
				*decl = declid(decl_array);
			}
			else
			{
				@vec_add(&current.decls, method);
			}
		}
	}
	decltable_set(&methods.method_table, method);
}

<* c3c `token_type_to_string` (tokens.c). *>
fn String token_type_to_string(TokenType type) => type.text;

<* c3c `token_is_any_type` (tokens.c). *>
fn bool token_is_any_type(TokenType type) => type.is_any_type();

// ---------------------------------------------------------------------------
// ast.c

<* Standard decl creation, used by compile time constructs, since they have no need for neither type nor name. *>
fn Decl* decl_new_ct(DeclKind kind, SourceLocId span)
{
	Decl* decl = decl_calloc();
	decl.decl_kind = kind;
	decl.loc = span;
	return decl;
}

<* Named declaration without type. *>
fn Decl* decl_new(DeclKind decl_kind, String name, SourceLocId loc)
{
	Decl* decl = decl_calloc();
	decl.decl_kind = decl_kind;
	decl.loc = loc;
	decl.name = name;
	return decl;
}

fn bool decl_is_deprecated(Decl* decl)
{
	return decl.resolved_attributes && decl.attrs_resolved && decl.attrs_resolved.deprecated.ptr;
}

<* Check if local or parameter $foo/$Foo *>
fn bool decl_is_ct_var(Decl* decl)
{
	if (decl.decl_kind != VAR) return false;
	return decl_var_kind_is_ct(decl.var_decl.kind);
}

fn Decl* decl_new_with_type(String name, SourceLoc* loc, DeclKind decl_type)
{
	Decl* decl = decl_calloc();
	decl.decl_kind = decl_type;
	decl.name = name;
	decl.loc = loc ? make_loc(*loc) : 0;
	TypeKind kind = POISONED;
	switch (decl_type)
	{
		case INTERFACE:
			kind = INTERFACE;
		case UNION:
			kind = UNION;
		case STRUCT:
			kind = STRUCT;
		case ENUM:
			kind = ENUM;
		case CONSTSET:
			kind = CONSTSET;
		case TYPEDEF:
			kind = TYPEDEF;
		case TYPE_ALIAS:
			kind = ALIAS;
		case BITSTRUCT:
			kind = BITSTRUCT;
		case FNTYPE:
		case FUNC:
		case ERASED:
		case IMPORT: case MACRO: case DECLARRAY: case ATTRIBUTE: case LABEL: case ALIAS: case CT_ASSERT:
		case CT_EXEC: case FAULT: case CT_ECHO: case CT_INCLUDE: case GROUP: case CT_EXPAND: case BODYPARAM:
		case VAR: case ENUM_CONSTANT: case CONTRACT: case POISONED: case ALIAS_PATH: case GENERIC:
		case GENERIC_INSTANCE:
			unreachable();
	}
	Type* type = type_new(kind, name.ptr ? name : "$anon");
	type.canonical = type;
	type.decl = decl;
	decl.type = type;
	return decl;
}

fn String decl_safe_name(Decl* decl)
{
	if (!decl) return "<no decl>";
	if (decl.name.ptr) return decl.name;
	return decl_to_name(decl);
}

fn Decl* decl_template_get_generic(Decl* decl) => decl.is_template ? declptr(decl.generic_id) : null;

fn String decl_to_name(Decl* decl)
{
	String name = decl_to_a_name(decl);
	if (name[1] == 'n') return name[3..];
	return name[2..];
}

fn String decl_to_a_name(Decl* decl)
{
	switch (decl.decl_kind)
	{
		case ATTRIBUTE: return "an attribute";
		case BITSTRUCT: return "a bitstruct";
		case BODYPARAM: return "a body parameter";
		case CT_ASSERT: return "a compile time assert";
		case CT_ECHO: return "a compile time echo";
		case CT_EXEC: return "compile time exec include";
		case CT_EXPAND: return "compile time expand";
		case CT_INCLUDE: return "an include";
		case DECLARRAY: return "a declarray";
		case ALIAS: case ALIAS_PATH: case TYPE_ALIAS: return "an alias";
		case TYPEDEF: return "a distinct type";
		case ENUM: return "an enum";
		case CONSTSET: return "a constset";
		case ENUM_CONSTANT: return "an enum value";
		case ERASED: return "an erased declaration";
		case FAULT: return "a fault";
		case FNTYPE: return "a function type";
		case FUNC: return "a function";
		case GROUP: return "group";
		case GENERIC: return "a generic declaration";
		case GENERIC_INSTANCE: return "a generic instance";
		case IMPORT: return "an import";
		case LABEL: return "a label";
		case MACRO: return "a macro";
		case POISONED: return "a poisoned decl";
		case INTERFACE: return "an interface";
		case STRUCT: return "a struct";
		case UNION: return "a union";
		case CONTRACT: return "a contract";
		case VAR:
			switch (decl.var_decl.kind)
			{
				case BITMEMBER: return "a bitstruct member";
				case CONST: return "a constant";
				case ERASE: unreachable();
				case GLOBAL: return "a global variable";
				case LOCAL: return "a variable";
				case LOCAL_CT: return "a compile time variable";
				case LOCAL_CT_TYPE: return "a compile time type variable";
				case MEMBER: return "a member";
				case PARAM: return "a parameter";
				case PARAM_CT: return "a compile time parameter";
				case PARAM_CT_TYPE: return "a compile time type parameter";
				case PARAM_EXPR: return "a expression parameter";
				case REWRAPPED: unreachable();
				case UNWRAPPED: return "an unwrapped variable";
			}
	}
}

fn Decl* decl_new_var_loc(String name, SourceLoc* loc, TypeInfo* type, VarDeclKind kind)
{
	Decl* decl = decl_new(VAR, name, make_loc(*loc));
	decl.var_decl.kind = kind;
	decl.var_decl.type_info = type ? type_infoid(type) : 0;
	return decl;
}

fn Decl* decl_new_var(String name, SourceLocId loc, TypeInfo* type, VarDeclKind kind)
{
	Decl* decl = decl_new(VAR, name, loc);
	decl.var_decl.kind = kind;
	decl.var_decl.type_info = type ? type_infoid(type) : 0;
	return decl;
}

fn Decl* decl_new_generated_var(Type* type, VarDeclKind kind, SourceLocId loc)
{
	Decl* decl = decl_calloc();
	decl.decl_kind = VAR;
	decl.loc = loc;
	decl.is_used = true;
	decl.name = {};
	decl.var_decl.kind = kind;
	decl.var_decl.is_temp = true;
	decl.type = type;
	decl.alignment = type ? type_alloca_alignment(type) : 0;
	assert(!type || !type_is_user_defined(type) || type.decl.resolve_status == DONE);
	decl.var_decl.type_info = type_info_id_new_base(type, loc);
	decl.resolve_status = DONE;
	return decl;
}

const BinaryOp[TokenType::len] BINARY_OP = {
	[TokenType.STAR.ordinal] = MULT,
	[TokenType.DIV.ordinal] = DIV,
	[TokenType.PLUS.ordinal] = ADD,
	[TokenType.MINUS.ordinal] = SUB,
	[TokenType.MOD.ordinal] = MOD,
	[TokenType.SHL.ordinal] = SHL,
	[TokenType.SHR.ordinal] = SHR,
	[TokenType.AND.ordinal] = AND,
	[TokenType.OR.ordinal] = OR,
	[TokenType.CT_AND.ordinal] = CT_AND,
	[TokenType.CT_OR.ordinal] = CT_OR,
	[TokenType.CT_CONCAT.ordinal] = CT_CONCAT,
	[TokenType.CT_CONCAT_ASSIGN.ordinal] = CT_CONCAT_ASSIGN,
	[TokenType.QUESTQUEST.ordinal] = ELSE,
	[TokenType.AMP.ordinal] = BIT_AND,
	[TokenType.BIT_OR.ordinal] = BIT_OR,
	[TokenType.BIT_XOR.ordinal] = BIT_XOR,
	[TokenType.EQEQ.ordinal] = EQ,
	[TokenType.NOT_EQUAL.ordinal] = NE,
	[TokenType.LESS.ordinal] = LT,
	[TokenType.LESS_EQ.ordinal] = LE,
	[TokenType.GREATER.ordinal] = GT,
	[TokenType.GREATER_EQ.ordinal] = GE,
	[TokenType.EQ.ordinal] = ASSIGN,
	[TokenType.MULT_ASSIGN.ordinal] = MULT_ASSIGN,
	[TokenType.PLUS_ASSIGN.ordinal] = ADD_ASSIGN,
	[TokenType.MINUS_ASSIGN.ordinal] = SUB_ASSIGN,
	[TokenType.DIV_ASSIGN.ordinal] = DIV_ASSIGN,
	[TokenType.MOD_ASSIGN.ordinal] = MOD_ASSIGN,
	[TokenType.BIT_AND_ASSIGN.ordinal] = BIT_AND_ASSIGN,
	[TokenType.BIT_OR_ASSIGN.ordinal] = BIT_OR_ASSIGN,
	[TokenType.BIT_XOR_ASSIGN.ordinal] = BIT_XOR_ASSIGN,
	[TokenType.SHR_ASSIGN.ordinal] = SHR_ASSIGN,
	[TokenType.SHL_ASSIGN.ordinal] = SHL_ASSIGN,
};

const BinaryOp[BinaryOp::len] ASSIGN_BINOP = {
	[BinaryOp.MULT_ASSIGN.ordinal] = MULT,
	[BinaryOp.ADD_ASSIGN.ordinal] = ADD,
	[BinaryOp.SUB_ASSIGN.ordinal] = SUB,
	[BinaryOp.DIV_ASSIGN.ordinal] = DIV,
	[BinaryOp.MOD_ASSIGN.ordinal] = MOD,
	[BinaryOp.BIT_AND_ASSIGN.ordinal] = BIT_AND,
	[BinaryOp.BIT_OR_ASSIGN.ordinal] = BIT_OR,
	[BinaryOp.BIT_XOR_ASSIGN.ordinal] = BIT_XOR,
	[BinaryOp.SHR_ASSIGN.ordinal] = SHR,
	[BinaryOp.SHL_ASSIGN.ordinal] = SHL,
};

fn BinaryOp binaryop_assign_base_op(BinaryOp assign_binary_op) => ASSIGN_BINOP[assign_binary_op.ordinal];

const UnaryOp[TokenType::len] UNARY_OP = {
	[TokenType.STAR.ordinal] = DEREF,
	[TokenType.AMP.ordinal] = ADDR,
	[TokenType.AND.ordinal] = TADDR,
	[TokenType.BIT_NOT.ordinal] = BITNEG,
	[TokenType.BANG.ordinal] = NOT,
	[TokenType.BANGBANG.ordinal] = NOT,
	[TokenType.MINUS.ordinal] = NEG,
	[TokenType.PLUS.ordinal] = PLUS,
	[TokenType.PLUSPLUS.ordinal] = INC,
	[TokenType.MINUSMINUS.ordinal] = DEC,
};

fn BinaryOp binaryop_from_token(TokenType type) => BINARY_OP[type.ordinal];

fn TokenType binaryop_to_token(BinaryOp type)
{
	foreach (i, op : BINARY_OP)
	{
		if (op == type) return TokenType::values[i];
	}
	return INVALID_TOKEN;
}

fn UnaryOp unaryop_from_token(TokenType type) => UNARY_OP[type.ordinal];

fn bool ast_is_not_empty(Ast* ast)
{
	if (!ast) return false;
	if (ast.ast_kind != COMPOUND_STMT) return true;
	AstId first = ast.compound_stmt.first_stmt;
	if (first)
	{
		Ast* stmt = astptr(first);
		if (stmt.next) return true;
		return ast_is_not_empty(stmt);
	}
	return false;
}

fn AttributeType attribute_by_name(String name)
{
	for (usz i = 0; i < NUMBER_OF_ATTRIBUTES.ordinal; i++)
	{
		if (attribute_list[i].ptr == name.ptr) return AttributeType::values[i];
	}
	return AttributeType.NONE;
}

<* Look for the @link directive, if a decl is codegen then add it to the linking process. *>
fn void decl_append_links_to_global_during_codegen(Decl* decl)
{
	CompilationUnit* unit = decl.unit;
	if (unit && unit.links.len)
	{
		foreach (link : unit.links) linking_add_link(&compiler.linking, link);
		unit.links = {}; // Don't register twice
	}
	if (decl.attrs_resolved && decl.attrs_resolved.links.len)
	{
		foreach (link : decl.attrs_resolved.links)
		{
			linking_add_link(&compiler.linking, link);
		}
	}
}

fn bool decl_is_defaulted_var(Decl* decl)
{
	return decl.decl_kind == VAR && decl.var_decl.no_init && decl.var_decl.defaulted;
}

fn bool decl_inherits_module_generic(Decl* decl)
{
	switch (decl.decl_kind)
	{
		case POISONED:
		case BODYPARAM:
		case CT_ASSERT:
		case CT_ECHO:
		case CT_EXEC:
		case CT_INCLUDE:
		case ALIAS_PATH:
		case ENUM_CONSTANT:
		case ERASED:
		case FAULT:
		case GROUP:
		case GENERIC:
		case GENERIC_INSTANCE:
		case IMPORT:
		case LABEL:
		case CONTRACT:
		case CT_EXPAND:
			return false;
		case ATTRIBUTE:
		case BITSTRUCT:
		case DECLARRAY:
		case ALIAS:
		case CONSTSET:
		case TYPEDEF:
		case ENUM:
		case FNTYPE:
		case INTERFACE:
		case STRUCT:
		case TYPE_ALIAS:
		case UNION:
		case VAR:
			return true;
		case FUNC:
		case MACRO:
			// Only if it isn't a method
			return decl.func_decl.type_parent == 0;
	}
}

<*
 Count the expected number of elements needed for an initializer
 by folding any anonymous structs and unions.
*>
fn int decl_count_elements(Decl* structlike)
{
	int elements = 0;
	Decl*[] members = structlike.strukt.members;
	usz member_size = members.len;
	if (member_size == 0) return 0;
	// In the case we have a union, we only count the first element.
	if (structlike.decl_kind == UNION) member_size = 1;
	for (usz i = 0; i < member_size; i++)
	{
		Decl* member = members[i];
		// Recursively count the anonymous struct/unions
		if (member.decl_kind != VAR && !member.name.ptr)
		{
			elements += decl_count_elements(member);
			continue;
		}
		elements++;
	}
	return elements;
}

<* This is used to check if a macro folds to a single compile time value. *>
fn bool ast_is_compile_time(Ast* ast)
{
	switch (ast.ast_kind)
	{
		case NOP_STMT:
			return true;
		case DECLARE_STMT:
			switch (ast.declare_stmt.var_decl.kind)
			{
				case GLOBAL:
				case PARAM:
				case MEMBER:
				case BITMEMBER:
				case PARAM_EXPR:
				case UNWRAPPED:
				case ERASE:
				case REWRAPPED:
				case PARAM_CT:
				case PARAM_CT_TYPE:
					unreachable();
				case CONST:
					return !ast.declare_stmt.var_decl.type_info;
				case LOCAL:
					return false;
				case LOCAL_CT:
				case LOCAL_CT_TYPE:
					return true;
			}
		case RETURN_STMT:
		case BLOCK_EXIT_STMT:
			if (!ast.return_stmt.expr) return true;
			return expr_is_runtime_const(ast.return_stmt.expr);
		case EXPR_STMT:
			// $a; is fine
			return expr_is_runtime_const(ast.expr_stmt);
		case CT_COMPOUND_STMT:
			AstId current = ast.ct_compound_stmt;
			while (current)
			{
				if (!ast_is_compile_time(ast_next(&current))) return false;
			}
			return true;
		case COMPOUND_STMT:
			AstId current = ast.compound_stmt.first_stmt;
			while (current)
			{
				if (!ast_is_compile_time(ast_next(&current))) return false;
			}
			return true;
		default:
			return false;
	}
}

<* Should this declaration be linked externally *>
fn bool decl_is_externally_visible(Decl* decl)
{
	return decl.is_external_visible || decl.visibility == PUBLIC || decl.is_export;
}

<*
 Is this declaration a global ref of some sort?
 In other words a function, static, global constant or a global
*>
fn bool decl_is_global_ref(Decl* ident)
{
	switch (ident.decl_kind)
	{
		case FUNC: return true;
		case VAR: break;
		default: return false;
	}
	if (ident.var_decl.is_threadlocal) return false;
	switch (ident.var_decl.kind)
	{
		case LOCAL:
			return ident.var_decl.is_static;
		case CONST:
		case GLOBAL:
			return true;
		case PARAM:
		case MEMBER:
		case BITMEMBER:
		case PARAM_EXPR:
		case UNWRAPPED:
		case ERASE:
		case REWRAPPED:
		case PARAM_CT:
		case PARAM_CT_TYPE:
		case LOCAL_CT:
		case LOCAL_CT_TYPE:
			return false;
	}
}

<* Is is @local or is it @private but never imported in some other compilation unit (module) *>
fn bool decl_is_local(Decl* decl)
{
	return !decl.is_external_visible && decl.visibility != PUBLIC && !decl.is_export;
}

<* Does the decl need to be prefixed, or is it for some reason like a builtin. *>
fn bool decl_needs_prefix(Decl* decl)
{
	switch (decl.decl_kind)
	{
		case FUNC:
		case MACRO:
			if (decl.func_decl.type_parent) return false;
			nextcase VAR;
		case VAR:
		case ALIAS:
		case FAULT:
			return !decl.is_autoimport;
		default:
			return false;
	}
}

<* Find a particular enum by name. *>
fn Decl* decl_find_enum_constant(Decl* decl, String name)
{
	foreach (enum_constant : decl.enums.values)
	{
		if (enum_constant.name.ptr == name.ptr) return enum_constant;
	}
	return null;
}

fn AlignSize decl_find_member_offset(Decl* decl, Decl* member)
{
	const AlignSize NO_MATCH = ~(AlignSize)0;
	while (decl.decl_kind == TYPEDEF) decl = decl.distinct.type.decl;
	Decl*[] members;
	switch (decl.decl_kind)
	{
		case BITSTRUCT:
		case STRUCT:
		case UNION:
			members = decl.strukt.members;
		default:
			return NO_MATCH;
	}
	assert(members.ptr != null);
	foreach (m : members)
	{
		if (m == member)
		{
			return member.offset;
		}
		if (m.decl_kind != VAR)
		{
			AlignSize possible_offset = decl_find_member_offset(m, member);
			if (possible_offset != NO_MATCH) return possible_offset + m.offset;
		}
	}
	return NO_MATCH;
}

<* Is it a for statement, AST_FOREACH should not reach here. *>
fn bool ast_supports_continue(Ast* stmt)
{
	assert(stmt.ast_kind != FOREACH_STMT);
	if (stmt.ast_kind != FOR_STMT) return false;
	// We don't support `continue` in a `do { };` statement.
	return stmt.for_stmt.cond || !stmt.flow.skip_first;
}

<* `end` is an exclusive index into `name`, or `name.len` (c3c NULL end). *>
fn void scratch_buffer_append_but_mangle_underscore_dot(String name, usz end, String suffix)
{
	usz i = 0;
	while (i != end && i < name.len)
	{
		char c = name[i++];
		switch (c)
		{
			case ':':
				assert(name[i] == ':');
				scratch_buffer_append_char('_');
				i++;
			case '.':
				scratch_buffer_append("__");
			default:
				scratch_buffer_append_char(c);
		}
	}
	if (suffix.ptr) scratch_buffer_append(suffix);
}

<* Appends ".<file stem>.<row>.<col>". *>
fn void scratch_buffer_append_decl_pos(Decl* decl)
{
	if (!decl.loc) return;
	SourceLoc* loc = sourcelocptr(decl.loc);
	String stem = source_file_by_id(loc.file_id).name;
	foreach (i, ch : stem)
	{
		if (ch == '/' || ch == '\\') stem = stem[i + 1..];
	}
	usz len = stem.len;
	foreach (i, ch : stem)
	{
		if (ch == '.')
		{
			len = (usz)i;
			break;
		}
	}
	@scratch_buffer_printf(".%s.%d.%d", stem[:len], loc.row, loc.col);
}

fn void scratch_buffer_set_extern_decl_name(Decl* decl, bool clear)
{
	append_extern_decl_name(decl, clear, false);
}

fn bool scratch_buffer_set_stable_extern_decl_name(Decl* decl, bool clear)
{
	return append_extern_decl_name(decl, clear, true);
}

<*
 stable: suffix locals with their source position, not their declid.
 Returns true if it did; macro copies share that suffix.
*>
fn bool append_extern_decl_name(Decl* decl, bool clear, bool stable)
{
	if (clear) scratch_buffer_clear();
	if (decl.extname.ptr)
	{
		scratch_buffer_append(decl.extname);
		return false;
	}
	if (decl.is_extern)
	{
		scratch_buffer_append(decl.name);
		return false;
	}
	if (decl.decl_kind == FUNC && decl.func_decl.type_parent)
	{
		Type* parent = decl_find_method_target(decl).type.canonical;
		if (type_is_user_defined(parent))
		{
			bool pos = append_extern_decl_name(parent.decl, false, stable);
			scratch_buffer_append(decl.is_export ? "__" : ".");
			scratch_buffer_append(decl.name);
			return pos;
		}
		if (decl.unit && decl.unit.mod) scratch_buffer_append_module(decl.unit.mod, decl.is_export);
		scratch_buffer_append(decl.is_export ? "__" : ".");
		scratch_buffer_append(parent.name);
		scratch_buffer_append(decl.is_export ? "__" : ".");
		scratch_buffer_append(decl.name);
		return false;
	}
	Module* mod = decl.unit ? decl.unit.mod : null;
	if (mod) scratch_buffer_append_module(mod, decl.is_export);
	scratch_buffer_append(decl.is_export ? "__" : ".");
	String name = decl_is_user_defined_type(decl) ? decl.type.name : decl.name;
	// c3c `template_end` / `tail` as indices into `name` (`has_template_end` for non-NULL).
	bool has_template_end = false;
	usz template_end = name.len;
	String suffix;
	String tail;
	assert(name.ptr != null);
	if (decl.is_templated)
	{
		Decl* instance = declptr(decl.instance_id);
		if (try idx = name.index_of_char('{'))
		{
			has_template_end = true;
			template_end = (usz)idx;
		}
		suffix = instance.instance_decl.cname_suffix;
		if (has_template_end) tail = name[template_end + instance.instance_decl.name_suffix.len..];
	}
	if (decl.is_export)
	{
		scratch_buffer_append_but_mangle_underscore_dot(name, template_end, suffix);
		if (tail.ptr) scratch_buffer_append_but_mangle_underscore_dot(tail, tail.len, {});
	}
	else
	{
		if (has_template_end)
		{
			scratch_buffer_append_len(name.ptr, template_end);
		}
		else
		{
			scratch_buffer_append(name);
		}
		if (suffix.ptr) scratch_buffer_append(suffix);
		if (tail.ptr) scratch_buffer_append(tail);
	}
	if (decl.visibility != LOCAL) return false;
	assert(mod != null);
	if (stable)
	{
		scratch_buffer_append_decl_pos(decl);
		return true;
	}
	@scratch_buffer_printf(".%d", declid(decl));
	return false;
}
