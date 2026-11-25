// The compiler_internal.h inline helpers (and enums.h / common.h constants)
// that sema needs and that were not ported with the parser (the others live
// in ast_helpers.c3 / expr.c3 / types.c3).
//
// Deviations from c3c:
// - ARENA_DEF `decl_copy` / `type_info_copy` / `sourceloc_copy` wrap the
//   ast.c3 `*_copy_node` helpers like expr.c3's `expr_copy`. The `chars`
//   arena and the `*_arena_free` functions are not ported (Strings live in
//   the AST allocator; arenas are freed by `ast_memory_reset`).
// - `clobbers_make` / `clobbers_make_from` take typed varargs; a negative
//   index ends the list like c3c's `-1` sentinel (which may be omitted).
// - Case-group macros (ALL_FLOATS, VECTORS, SPECIAL_TYPES, ...) cannot be
//   macros in C3: spell them out (`case TYPEINFO: case MEMBER: case REFLECTION:`).
// - IS_OPTIONAL(x) -> @is_optional(x); IS_RESOLVED(x) -> @is_resolved(x).
module aro::frontend::c3::compiler;

alias CanonicalType = Type;
alias FlatType = Type;
alias LoweredType = Type;

const MAX_ALIGNMENT = (AlignSize)0x10000000;
const MAX_TYPE_SIZE = (ByteSize)0x40000000;
const MAX_STRUCT_SIZE = (ByteSize)0x40000000;
const int MAX_STRUCT_PADDING = 0xFFFF;
const int MAX_GENERIC_SUFFIX = 1024;
const int MAX_SCOPE_DEPTH = 0x100;
const StructIndex STRUCT_INDEX_MAX = short::max;
const void* INVALID_PTR = (void*)(uptr)0xAAAAAAAAAAAAAAAA;
const AbiType ABI_TYPE_EMPTY = { .type = null };
const int MAX_ASM_INSTRUCTION_PARAMS = 6;
const int MAX_CLOBBER_FLAGS = 64 * CLOBBER_FLAG_ELEMENTS;
const int ASM_INSTRUCTION_MAX = 0x1000;
const int ASM_INSTRUCTION_MASK = ASM_INSTRUCTION_MAX - 1;
const int ASM_REGISTER_MAX = 4096;
const int ASM_REGISTER_MASK = ASM_REGISTER_MAX - 1;

const AttributeDomain EXPORTED_USER_DEFINED_TYPES = ATTR_ENUM | ATTR_UNION | ATTR_STRUCT | ATTR_FAULT;
const AttributeDomain USER_DEFINED_TYPES = EXPORTED_USER_DEFINED_TYPES | ATTR_BITSTRUCT | ATTR_TYPEDEF;
const AttributeDomain CALLABLE_TYPE = ATTR_FUNC | ATTR_INTERFACE_METHOD | ATTR_MACRO | ATTR_FNTYPE;
const AttributeDomain LOCAL_VARIABLE_TYPES = ATTR_LOCAL | ATTR_LOCAL_STATIC;

<* compiler_internal.h IS_OPTIONAL. *>
macro bool @is_optional(element) => type_is_optional(element.type);

<* compiler_internal.h IS_RESOLVED. *>
macro bool @is_resolved(element) => element.resolve_status == DONE;

// ---------------------------------------------------------------------------
// ARENA_DEF copies

fn Decl* decl_copy(Decl* ptr) @inline => decl_copy_node(ptr);
fn TypeInfo* type_info_copy(TypeInfo* ptr) @inline => type_info_copy_node(ptr);
fn SourceLoc* sourceloc_copy(SourceLoc* ptr) @inline
{
	SourceLoc* x = sourceloc_calloc();
	*x = *ptr;
	return x;
}

// ---------------------------------------------------------------------------
// Build settings

fn bool no_panic() @inline
{
	return compiler.build.feature.panic_level == PANIC_OFF && compiler.build.show_backtrace == SHOW_BACKTRACE_OFF;
}

fn bool panic_use_format() @inline
{
	return compiler.build.feature.panic_level != PANIC_OFF && compiler.platform.os != OsType.EMSCRIPTEN;
}

fn int panic_fn_text_count(PanicFunction id) @inline
{
	return panic_use_format() || id == FN_MESSAGE ? panic_fn_desc[id.ordinal].text_count : 0;
}

fn int panic_fn_value_count(PanicFunction id) @inline
{
	return panic_use_format() ? panic_fn_desc[id.ordinal].value_count : 0;
}

fn bool panic_use_location() @inline
{
	return compiler.build.show_backtrace != SHOW_BACKTRACE_OFF;
}

fn bool safe_mode_enabled() @inline
{
	return compiler.build.feature.safe_mode != SAFETY_OFF;
}

fn bool link_libc() @inline
{
	return compiler.build.link_libc != LINK_LIBC_OFF;
}

fn bool custom_libc() @inline
{
	return compiler.build.custom_libc == CUSTOM_LIBC_ON;
}

fn bool strip_unused() @inline
{
	return compiler.build.strip_unused != STRIP_UNUSED_OFF;
}

fn bool no_stdlib() @inline
{
	return compiler.build.use_stdlib == USE_STDLIB_OFF;
}

fn bool compile_asserts() @inline
{
	return safe_mode_enabled() || compiler.build.build_test;
}

// ---------------------------------------------------------------------------
// Casts / types / exprs

fn bool cast_both_implicit(SemaContext* context, Expr* expr1, Expr* expr2, Type* to_type, bool is_binary, bool* failed_ref) @inline
{
	return cast_implicit_checked(context, expr1, to_type, is_binary, failed_ref) && cast_implicit_checked(context, expr2, to_type, is_binary, failed_ref);
}

fn bool type_flat_is_valid_for_arg_h(Type* type)
{
	type = type_flatten(type);
	if (type.type_kind == POINTER) return true;
	if (type.type_kind != ARRAY && type.type_kind != SLICE) return false;
	switch (type.array.base.type_kind)
	{
		case I8:
		case U8:
			return true;
		default:
			return false;
	}
}

fn bool exprid_is_simple(ExprId expr_id, bool to_float) @inline => expr_is_simple(exprptr(expr_id), to_float);

fn bool exprid_is_pure(ExprId expr_id) @inline
{
	return expr_id ? expr_is_pure(exprptr(expr_id)) : false;
}

fn void expr_rewrite_int_to_bool(Expr* expr, bool negate)
{
	if (expr_is_const(expr))
	{
		bool is_zero = expr_is_zero(expr);
		expr_rewrite_const_bool(expr, type_bool, negate ? is_zero : !is_zero);
		return;
	}
	Expr* inner = expr_copy(expr);
	expr.expr_kind = INT_TO_BOOL;
	expr.int_to_bool_expr = { .inner = inner, .negate = negate };
	expr.type = type_add_optional(type_bool, @is_optional(expr));
}

// ---------------------------------------------------------------------------
// Asm

fn String asm_clobber_by_index(int index) @inline
{
	return compiler.platform.clobber_name_list[index];
}

fn AsmRegister* asm_reg_by_index(int index) @inline
{
	return &compiler.platform.registers[index];
}

fn void clobbers_add(Clobbers* clobbers, int index) @inline
{
	assert(index < MAX_CLOBBER_FLAGS);
	int bit = index % 64;
	int element = index / 64;
	clobbers.mask[element] |= (1UL << bit);
}

fn Clobbers clobbers_make_from(Clobbers clobbers, int... indices)
{
	foreach (i : indices)
	{
		if (i < 0) break;
		clobbers_add(&clobbers, i);
	}
	return clobbers;
}

fn Clobbers clobbers_make(int index, int... indices)
{
	Clobbers clobbers = {};
	clobbers_add(&clobbers, index);
	return clobbers_make_from(clobbers, ...indices);
}

fn int arg_bits_max(AsmArgBits bits, int limit)
{
	if (limit == 0) limit = int::max;
	if (limit >= 128 && (bits & ARG_BITS_128)) return 128;
	if (limit >= 80 && (bits & ARG_BITS_80)) return 80;
	if (limit >= 64 && (bits & ARG_BITS_64)) return 64;
	if (limit >= 32 && (bits & ARG_BITS_32)) return 32;
	if (limit >= 20 && (bits & ARG_BITS_20)) return 20;
	if (limit >= 16 && (bits & ARG_BITS_16)) return 16;
	if (limit >= 12 && (bits & ARG_BITS_12)) return 12;
	if (limit >= 8 && (bits & ARG_BITS_8)) return 8;
	if (limit >= 5 && (bits & ARG_BITS_5)) return 5;
	return 0;
}
