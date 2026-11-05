// Port of src/aro/Tree.zig: AST storage (plan 16).
//
// `aro::tree` is one module split over several files (plan 16 stage 1 owners):
//   tree.c3       core types, storage, add_node/set_node/get dispatch,
//                 type/value/attribute associations (16.1 tree-storage)
//   tree_decl.c3  declaration/type/record node families: encode/decode (16.2)
//   tree_expr.c3  expression/statement node families: encode/decode, lvalue
//                 and bitfield queries (16.3)
//   tree_dump.c3  source-aware `write` and `dump` (16.4)
// The Zig token part of Tree.zig (Token, TokenIndex, TokenWithExpansionLocs)
// lives in aro::tokens and is reused here; there is no second token model.
//
// The complete Zig -> C3 tag mapping (every Node variant, every Repr.Tag with
// its data/extra layout, every Cast.Kind) is docs/c3-tree-tags.md.
//
// Representation:
//  - `NodeIndex` / `NodeOptIndex` / `type_store::NODE_NULL` are the handles
//    plan 08 already declared in aro::type_store (Zig `Node.Index` /
//    `Node.OptIndex` / `.null`); this module adds their methods. Every Zig
//    `?Node.Index` field is a `NodeOptIndex` holding NODE_NULL for null.
//  - Zig `Node` (a `union(enum)`) is `Node`: a `NodeKind` plus an anonymous
//    union with one member per Zig payload *type* (all Binary variants share
//    `.binary`, all Unary variants `.unary`, ...). The kind -> member mapping
//    is in the docs table and in each payload struct's doc comment.
//  - Zig `Node.Repr` (MultiArrayList) is `NodeRepr` stored array-of-structs in
//    `Tree.nodes`. `NodeTag` is Zig `Repr.Tag`; `NodeTag.kind` is the
//    `NodeKind` that tag decodes to.
//  - Slices in a decoded `Node` (fields, body, args, ...) point into
//    `Tree.extra` or into the node's own `NodeRepr.data` (the "_two"/"_three"
//    packed forms, Zig `unPackElems`). Exactly as in Zig they stay valid only
//    until the next `add_node`/`set_node`/`add_extra` grows those lists.
//  - Ownership: `tokens` are borrowed (owned by the Preprocessor/Compilation);
//    `nodes`, `extra`, `root_decls`, `value_map` and `attr_map` are owned and
//    released by `Tree.free` (Zig `deinit`).
//  - Running out of memory panics, so Zig's `!T` (OOM only) is plain `T`.
//  - Zig leaves unused `Repr.data` words `undefined`; C3 zero-initializes
//    them. `qt_or_null` reads data[0] for every non-listed tag (including
//    IDENTIFIER_ARG and CODEGEN_DIAGNOSTIC), as Zig does.
//
// Stage 0 (contract): types and signatures only; bodies that are not trivial
// are `unreachable("stage 0 stub")`.
module aro::tree;
import aro::compilation, aro::tokens, aro::tokenizer, aro::source, aro::type_store, aro::value;
import aro::attribute, aro::attribute_map, aro::diagnostics;
import std::collections::list, std::collections::map;

<* Zig `null` from `Node.Index.qtOrNull`: the node is untyped. *>
excuse NO_QT;
<* Zig `null` from `OptIndex.unpack`. *>
excuse NULL_NODE;
<* Zig `null` from `bitfieldWidth` / `MemberAccess.isBitFieldWidth`: not a bitfield. *>
excuse NOT_BITFIELD;
<* Zig `null` from `calledFunctionAttr`. *>
excuse NO_CALLED_FUNCTION;

// ---------------------------------------------------------------------------
// Handles
// ---------------------------------------------------------------------------

<* Zig `Node.OptIndex.unpack` (null -> NULL_NODE). *>
fn NodeIndex? NodeOptIndex.unpack(self)
{
	if (self == type_store::NODE_NULL) return NULL_NODE~;
	return (NodeIndex)(uint)self;
}

fn bool NodeOptIndex.is_null(self) => self == type_store::NODE_NULL;

<* The index of a non-null optional index. @require !self.is_null() *>
fn NodeIndex NodeOptIndex.unwrap(self)
{
	assert(self != type_store::NODE_NULL);
	return (NodeIndex)(uint)self;
}

<* Zig `Node.OptIndex.pack`. *>
fn NodeOptIndex NodeIndex.pack(self) => (NodeOptIndex)(uint)self;

<* Zig `packOptIndex`: the backing u32 of an optional index. *>
fn uint pack_opt_index(NodeOptIndex opt) => (uint)opt;

<* Zig `unpackOptIndex`: reinterpret a data word as an optional index. *>
fn NodeOptIndex unpack_opt_index(uint idx) => (NodeOptIndex)idx;

<*
 Zig `packElem`: `nodes[index]`, or NODE_NULL's backing value when
 `index >= nodes.len` (used for the "_two"/"_three" packed forms).
*>
fn uint pack_elem(NodeIndex[] nodes, usz index) => nodes.len > index ? (uint)nodes[index] : (uint)type_store::NODE_NULL;

<*
 Zig `unPackElems`: the prefix of `data` before the first NODE_NULL word,
 reinterpreted as node indices (no copy; the slice aliases `data`).
*>
fn NodeIndex[] unpack_elems(uint[] data)
{
	foreach (i, item : data)
	{
		if (item == (uint)type_store::NODE_NULL) return ((NodeIndex*)data.ptr)[:i];
	}
	return ((NodeIndex*)data.ptr)[:data.len];
}

<* Zig `addExtra` result: index into `Tree.extra` and length of the data. *>
struct ExtraSpan
{
	uint index;
	uint len;
}

// ---------------------------------------------------------------------------
// Tags
// ---------------------------------------------------------------------------

<* Which stage-1 file encodes/decodes a node kind (see docs/c3-tree-tags.md). *>
enum NodeFamily : char
{
	DECL, // tree_decl.c3
	STMT, // tree_expr.c3
	EXPR, // tree_expr.c3
}

<*
 Zig `std.meta.Tag(Tree.Node)`, in Zig declaration order. `name` is the Zig
 tag name (`{t}` in `dumpNode`), `family` the owning encoder/decoder.
*>
enum NodeKind : char (String name, NodeFamily family)
{
	EMPTY_DECL { "empty_decl", DECL },
	STATIC_ASSERT { "static_assert", DECL },
	FUNCTION { "function", DECL },
	PARAM { "param", DECL },
	VARIABLE { "variable", DECL },
	TYPEDEF { "typedef", DECL },
	GLOBAL_ASM { "global_asm", DECL },
	STRUCT_DECL { "struct_decl", DECL },
	UNION_DECL { "union_decl", DECL },
	ENUM_DECL { "enum_decl", DECL },
	STRUCT_FORWARD_DECL { "struct_forward_decl", DECL },
	UNION_FORWARD_DECL { "union_forward_decl", DECL },
	ENUM_FORWARD_DECL { "enum_forward_decl", DECL },
	ENUM_FIELD { "enum_field", DECL },
	RECORD_FIELD { "record_field", DECL },
	LABELED_STMT { "labeled_stmt", STMT },
	COMPOUND_STMT { "compound_stmt", STMT },
	IF_STMT { "if_stmt", STMT },
	SWITCH_STMT { "switch_stmt", STMT },
	CASE_STMT { "case_stmt", STMT },
	DEFAULT_STMT { "default_stmt", STMT },
	WHILE_STMT { "while_stmt", STMT },
	DO_WHILE_STMT { "do_while_stmt", STMT },
	FOR_STMT { "for_stmt", STMT },
	GOTO_STMT { "goto_stmt", STMT },
	COMPUTED_GOTO_STMT { "computed_goto_stmt", STMT },
	CONTINUE_STMT { "continue_stmt", STMT },
	BREAK_STMT { "break_stmt", STMT },
	NULL_STMT { "null_stmt", STMT },
	RETURN_STMT { "return_stmt", STMT },
	ASM_STMT { "asm_stmt", STMT },
	DECL_STMT { "decl_stmt", STMT },
	ASSIGN_EXPR { "assign_expr", EXPR },
	MUL_ASSIGN_EXPR { "mul_assign_expr", EXPR },
	DIV_ASSIGN_EXPR { "div_assign_expr", EXPR },
	MOD_ASSIGN_EXPR { "mod_assign_expr", EXPR },
	ADD_ASSIGN_EXPR { "add_assign_expr", EXPR },
	SUB_ASSIGN_EXPR { "sub_assign_expr", EXPR },
	SHL_ASSIGN_EXPR { "shl_assign_expr", EXPR },
	SHR_ASSIGN_EXPR { "shr_assign_expr", EXPR },
	BIT_AND_ASSIGN_EXPR { "bit_and_assign_expr", EXPR },
	BIT_XOR_ASSIGN_EXPR { "bit_xor_assign_expr", EXPR },
	BIT_OR_ASSIGN_EXPR { "bit_or_assign_expr", EXPR },
	COMPOUND_ASSIGN_DUMMY_EXPR { "compound_assign_dummy_expr", EXPR },
	COMMA_EXPR { "comma_expr", EXPR },
	BOOL_OR_EXPR { "bool_or_expr", EXPR },
	BOOL_AND_EXPR { "bool_and_expr", EXPR },
	BIT_OR_EXPR { "bit_or_expr", EXPR },
	BIT_XOR_EXPR { "bit_xor_expr", EXPR },
	BIT_AND_EXPR { "bit_and_expr", EXPR },
	EQUAL_EXPR { "equal_expr", EXPR },
	NOT_EQUAL_EXPR { "not_equal_expr", EXPR },
	LESS_THAN_EXPR { "less_than_expr", EXPR },
	LESS_THAN_EQUAL_EXPR { "less_than_equal_expr", EXPR },
	GREATER_THAN_EXPR { "greater_than_expr", EXPR },
	GREATER_THAN_EQUAL_EXPR { "greater_than_equal_expr", EXPR },
	SHL_EXPR { "shl_expr", EXPR },
	SHR_EXPR { "shr_expr", EXPR },
	ADD_EXPR { "add_expr", EXPR },
	SUB_EXPR { "sub_expr", EXPR },
	MUL_EXPR { "mul_expr", EXPR },
	DIV_EXPR { "div_expr", EXPR },
	MOD_EXPR { "mod_expr", EXPR },
	CAST { "cast", EXPR },
	ADDR_OF_EXPR { "addr_of_expr", EXPR },
	DEREF_EXPR { "deref_expr", EXPR },
	PLUS_EXPR { "plus_expr", EXPR },
	NEGATE_EXPR { "negate_expr", EXPR },
	BIT_NOT_EXPR { "bit_not_expr", EXPR },
	BOOL_NOT_EXPR { "bool_not_expr", EXPR },
	PRE_INC_EXPR { "pre_inc_expr", EXPR },
	PRE_DEC_EXPR { "pre_dec_expr", EXPR },
	IMAG_EXPR { "imag_expr", EXPR },
	REAL_EXPR { "real_expr", EXPR },
	POST_INC_EXPR { "post_inc_expr", EXPR },
	POST_DEC_EXPR { "post_dec_expr", EXPR },
	PAREN_EXPR { "paren_expr", EXPR },
	STMT_EXPR { "stmt_expr", EXPR },
	ADDR_OF_LABEL { "addr_of_label", EXPR },
	ARRAY_ACCESS_EXPR { "array_access_expr", EXPR },
	MEMBER_ACCESS_EXPR { "member_access_expr", EXPR },
	MEMBER_ACCESS_PTR_EXPR { "member_access_ptr_expr", EXPR },
	CALL_EXPR { "call_expr", EXPR },
	DECL_REF_EXPR { "decl_ref_expr", EXPR },
	ENUMERATION_REF { "enumeration_ref", EXPR },
	BUILTIN_CALL_EXPR { "builtin_call_expr", EXPR },
	BUILTIN_REF { "builtin_ref", EXPR },
	BUILTIN_TYPES_COMPATIBLE_P { "builtin_types_compatible_p", EXPR },
	BUILTIN_CHOOSE_EXPR { "builtin_choose_expr", EXPR },
	BUILTIN_CONVERTVECTOR { "builtin_convertvector", EXPR },
	BUILTIN_SHUFFLEVECTOR { "builtin_shufflevector", EXPR },
	BUILTIN_VA_ARG_PACK { "builtin_va_arg_pack", EXPR },
	BUILTIN_VA_ARG_PACK_LEN { "builtin_va_arg_pack_len", EXPR },
	BOOL_LITERAL { "bool_literal", EXPR },
	NULLPTR_LITERAL { "nullptr_literal", EXPR },
	INT_LITERAL { "int_literal", EXPR },
	CHAR_LITERAL { "char_literal", EXPR },
	FLOAT_LITERAL { "float_literal", EXPR },
	STRING_LITERAL_EXPR { "string_literal_expr", EXPR },
	IMAGINARY_LITERAL { "imaginary_literal", EXPR },
	COMPOUND_LITERAL_EXPR { "compound_literal_expr", EXPR },
	SIZEOF_EXPR { "sizeof_expr", EXPR },
	ALIGNOF_EXPR { "alignof_expr", EXPR },
	COUNTOF_EXPR { "countof_expr", EXPR },
	GENERIC_EXPR { "generic_expr", EXPR },
	GENERIC_ASSOCIATION_EXPR { "generic_association_expr", EXPR },
	GENERIC_DEFAULT_EXPR { "generic_default_expr", EXPR },
	BINARY_COND_EXPR { "binary_cond_expr", EXPR },
	COND_DUMMY_EXPR { "cond_dummy_expr", EXPR },
	COND_EXPR { "cond_expr", EXPR },
	ARRAY_INIT_EXPR { "array_init_expr", EXPR },
	STRUCT_INIT_EXPR { "struct_init_expr", EXPR },
	UNION_INIT_EXPR { "union_init_expr", EXPR },
	ARRAY_FILLER_EXPR { "array_filler_expr", EXPR },
	DEFAULT_INIT_EXPR { "default_init_expr", EXPR },
	CODEGEN_DIAGNOSTIC { "codegen_diagnostic", DECL },
	ALIGNAS_TYPE { "alignas_type", DECL },
	IDENTIFIER_ARG { "identifier_arg", DECL },
}

<* Zig `Node.Repr.Tag` (enum(u8)), in Zig order. `kind` is the `NodeKind` it decodes to. *>
enum NodeTag : char (NodeKind kind)
{
	EMPTY_DECL { NodeKind.EMPTY_DECL },
	STATIC_ASSERT { NodeKind.STATIC_ASSERT },
	FN_PROTO { NodeKind.FUNCTION },
	FN_DEF { NodeKind.FUNCTION },
	PARAM { NodeKind.PARAM },
	VARIABLE { NodeKind.VARIABLE },
	VARIABLE_DEF { NodeKind.VARIABLE },
	TYPEDEF { NodeKind.TYPEDEF },
	GLOBAL_ASM { NodeKind.GLOBAL_ASM },
	STRUCT_DECL { NodeKind.STRUCT_DECL },
	UNION_DECL { NodeKind.UNION_DECL },
	ENUM_DECL { NodeKind.ENUM_DECL },
	STRUCT_DECL_TWO { NodeKind.STRUCT_DECL },
	UNION_DECL_TWO { NodeKind.UNION_DECL },
	ENUM_DECL_TWO { NodeKind.ENUM_DECL },
	STRUCT_FORWARD_DECL { NodeKind.STRUCT_FORWARD_DECL },
	UNION_FORWARD_DECL { NodeKind.UNION_FORWARD_DECL },
	ENUM_FORWARD_DECL { NodeKind.ENUM_FORWARD_DECL },
	ENUM_FIELD { NodeKind.ENUM_FIELD },
	RECORD_FIELD { NodeKind.RECORD_FIELD },
	LABELED_STMT { NodeKind.LABELED_STMT },
	COMPOUND_STMT { NodeKind.COMPOUND_STMT },
	COMPOUND_STMT_THREE { NodeKind.COMPOUND_STMT },
	IF_STMT { NodeKind.IF_STMT },
	IF_INIT { NodeKind.IF_STMT },
	IF_FULL { NodeKind.IF_STMT },
	SWITCH_STMT { NodeKind.SWITCH_STMT },
	CASE_STMT { NodeKind.CASE_STMT },
	DEFAULT_STMT { NodeKind.DEFAULT_STMT },
	WHILE_STMT { NodeKind.WHILE_STMT },
	DO_WHILE_STMT { NodeKind.DO_WHILE_STMT },
	FOR_FULL { NodeKind.FOR_STMT },
	FOR_INIT_COND { NodeKind.FOR_STMT },
	FOR_INIT_INCR { NodeKind.FOR_STMT },
	FOR_COND_INCR { NodeKind.FOR_STMT },
	FOR_INIT { NodeKind.FOR_STMT },
	FOR_COND { NodeKind.FOR_STMT },
	FOR_INCR { NodeKind.FOR_STMT },
	FOR_EVER { NodeKind.FOR_STMT },
	GOTO_STMT { NodeKind.GOTO_STMT },
	COMPUTED_GOTO_STMT { NodeKind.COMPUTED_GOTO_STMT },
	CONTINUE_STMT { NodeKind.CONTINUE_STMT },
	BREAK_STMT { NodeKind.BREAK_STMT },
	NULL_STMT { NodeKind.NULL_STMT },
	RETURN_STMT { NodeKind.RETURN_STMT },
	RETURN_NONE_STMT { NodeKind.RETURN_STMT },
	IMPLICIT_RETURN { NodeKind.RETURN_STMT },
	ASM_STMT { NodeKind.ASM_STMT },
	ASM_STMT_INLINE { NodeKind.ASM_STMT },
	ASM_STMT_VOLATILE { NodeKind.ASM_STMT },
	ASM_STMT_INLINE_VOLATILE { NodeKind.ASM_STMT },
	ASM_STMT_SIMPLE { NodeKind.ASM_STMT },
	DECL_STMT_THREE { NodeKind.DECL_STMT },
	DECL_STMT { NodeKind.DECL_STMT },
	COMMA_EXPR { NodeKind.COMMA_EXPR },
	ASSIGN_EXPR { NodeKind.ASSIGN_EXPR },
	MUL_ASSIGN_EXPR { NodeKind.MUL_ASSIGN_EXPR },
	DIV_ASSIGN_EXPR { NodeKind.DIV_ASSIGN_EXPR },
	MOD_ASSIGN_EXPR { NodeKind.MOD_ASSIGN_EXPR },
	ADD_ASSIGN_EXPR { NodeKind.ADD_ASSIGN_EXPR },
	SUB_ASSIGN_EXPR { NodeKind.SUB_ASSIGN_EXPR },
	SHL_ASSIGN_EXPR { NodeKind.SHL_ASSIGN_EXPR },
	SHR_ASSIGN_EXPR { NodeKind.SHR_ASSIGN_EXPR },
	BIT_AND_ASSIGN_EXPR { NodeKind.BIT_AND_ASSIGN_EXPR },
	BIT_XOR_ASSIGN_EXPR { NodeKind.BIT_XOR_ASSIGN_EXPR },
	BIT_OR_ASSIGN_EXPR { NodeKind.BIT_OR_ASSIGN_EXPR },
	COMPOUND_ASSIGN_DUMMY_EXPR { NodeKind.COMPOUND_ASSIGN_DUMMY_EXPR },
	BOOL_OR_EXPR { NodeKind.BOOL_OR_EXPR },
	BOOL_AND_EXPR { NodeKind.BOOL_AND_EXPR },
	BIT_OR_EXPR { NodeKind.BIT_OR_EXPR },
	BIT_XOR_EXPR { NodeKind.BIT_XOR_EXPR },
	BIT_AND_EXPR { NodeKind.BIT_AND_EXPR },
	EQUAL_EXPR { NodeKind.EQUAL_EXPR },
	NOT_EQUAL_EXPR { NodeKind.NOT_EQUAL_EXPR },
	LESS_THAN_EXPR { NodeKind.LESS_THAN_EXPR },
	LESS_THAN_EQUAL_EXPR { NodeKind.LESS_THAN_EQUAL_EXPR },
	GREATER_THAN_EXPR { NodeKind.GREATER_THAN_EXPR },
	GREATER_THAN_EQUAL_EXPR { NodeKind.GREATER_THAN_EQUAL_EXPR },
	SHL_EXPR { NodeKind.SHL_EXPR },
	SHR_EXPR { NodeKind.SHR_EXPR },
	ADD_EXPR { NodeKind.ADD_EXPR },
	SUB_EXPR { NodeKind.SUB_EXPR },
	MUL_EXPR { NodeKind.MUL_EXPR },
	DIV_EXPR { NodeKind.DIV_EXPR },
	MOD_EXPR { NodeKind.MOD_EXPR },
	EXPLICIT_CAST { NodeKind.CAST },
	IMPLICIT_CAST { NodeKind.CAST },
	ADDR_OF_EXPR { NodeKind.ADDR_OF_EXPR },
	DEREF_EXPR { NodeKind.DEREF_EXPR },
	PLUS_EXPR { NodeKind.PLUS_EXPR },
	NEGATE_EXPR { NodeKind.NEGATE_EXPR },
	BIT_NOT_EXPR { NodeKind.BIT_NOT_EXPR },
	BOOL_NOT_EXPR { NodeKind.BOOL_NOT_EXPR },
	PRE_INC_EXPR { NodeKind.PRE_INC_EXPR },
	PRE_DEC_EXPR { NodeKind.PRE_DEC_EXPR },
	IMAG_EXPR { NodeKind.IMAG_EXPR },
	REAL_EXPR { NodeKind.REAL_EXPR },
	POST_INC_EXPR { NodeKind.POST_INC_EXPR },
	POST_DEC_EXPR { NodeKind.POST_DEC_EXPR },
	PAREN_EXPR { NodeKind.PAREN_EXPR },
	STMT_EXPR { NodeKind.STMT_EXPR },
	ADDR_OF_LABEL { NodeKind.ADDR_OF_LABEL },
	ARRAY_ACCESS_EXPR { NodeKind.ARRAY_ACCESS_EXPR },
	CALL_EXPR_ONE { NodeKind.CALL_EXPR },
	CALL_EXPR { NodeKind.CALL_EXPR },
	BUILTIN_CALL_EXPR { NodeKind.BUILTIN_CALL_EXPR },
	BUILTIN_CALL_EXPR_TWO { NodeKind.BUILTIN_CALL_EXPR },
	MEMBER_ACCESS_EXPR { NodeKind.MEMBER_ACCESS_EXPR },
	MEMBER_ACCESS_PTR_EXPR { NodeKind.MEMBER_ACCESS_PTR_EXPR },
	DECL_REF_EXPR { NodeKind.DECL_REF_EXPR },
	ENUMERATION_REF { NodeKind.ENUMERATION_REF },
	BUILTIN_REF { NodeKind.BUILTIN_REF },
	BOOL_LITERAL { NodeKind.BOOL_LITERAL },
	NULLPTR_LITERAL { NodeKind.NULLPTR_LITERAL },
	INT_LITERAL { NodeKind.INT_LITERAL },
	CHAR_LITERAL { NodeKind.CHAR_LITERAL },
	FLOAT_LITERAL { NodeKind.FLOAT_LITERAL },
	STRING_LITERAL_EXPR { NodeKind.STRING_LITERAL_EXPR },
	IMAGINARY_LITERAL { NodeKind.IMAGINARY_LITERAL },
	SIZEOF_EXPR { NodeKind.SIZEOF_EXPR },
	ALIGNOF_EXPR { NodeKind.ALIGNOF_EXPR },
	COUNTOF_EXPR { NodeKind.COUNTOF_EXPR },
	GENERIC_EXPR { NodeKind.GENERIC_EXPR },
	GENERIC_EXPR_ZERO { NodeKind.GENERIC_EXPR },
	GENERIC_ASSOCIATION_EXPR { NodeKind.GENERIC_ASSOCIATION_EXPR },
	GENERIC_DEFAULT_EXPR { NodeKind.GENERIC_DEFAULT_EXPR },
	BINARY_COND_EXPR { NodeKind.BINARY_COND_EXPR },
	COND_DUMMY_EXPR { NodeKind.COND_DUMMY_EXPR },
	COND_EXPR { NodeKind.COND_EXPR },
	BUILTIN_CHOOSE_EXPR { NodeKind.BUILTIN_CHOOSE_EXPR },
	BUILTIN_TYPES_COMPATIBLE_P { NodeKind.BUILTIN_TYPES_COMPATIBLE_P },
	BUILTIN_CONVERTVECTOR { NodeKind.BUILTIN_CONVERTVECTOR },
	BUILTIN_SHUFFLEVECTOR { NodeKind.BUILTIN_SHUFFLEVECTOR },
	BUILTIN_VA_ARG_PACK { NodeKind.BUILTIN_VA_ARG_PACK },
	BUILTIN_VA_ARG_PACK_LEN { NodeKind.BUILTIN_VA_ARG_PACK_LEN },
	ARRAY_INIT_EXPR { NodeKind.ARRAY_INIT_EXPR },
	ARRAY_INIT_EXPR_TWO { NodeKind.ARRAY_INIT_EXPR },
	STRUCT_INIT_EXPR { NodeKind.STRUCT_INIT_EXPR },
	STRUCT_INIT_EXPR_TWO { NodeKind.STRUCT_INIT_EXPR },
	UNION_INIT_EXPR { NodeKind.UNION_INIT_EXPR },
	ARRAY_FILLER_EXPR { NodeKind.ARRAY_FILLER_EXPR },
	DEFAULT_INIT_EXPR { NodeKind.DEFAULT_INIT_EXPR },
	COMPOUND_LITERAL_EXPR { NodeKind.COMPOUND_LITERAL_EXPR },
	CODEGEN_DIAGNOSTIC { NodeKind.CODEGEN_DIAGNOSTIC },
	ALIGNAS_TYPE { NodeKind.ALIGNAS_TYPE },
	IDENTIFIER_ARG { NodeKind.IDENTIFIER_ARG },
}

<* Zig `Node.Cast.Kind`; `name` is the Zig tag name (printed by dump). *>
enum CastKind : char (String name)
{
	NO_OP { "no_op" },
	BITCAST { "bitcast" },
	ARRAY_TO_POINTER { "array_to_pointer" },
	LVAL_TO_RVAL { "lval_to_rval" },
	FUNCTION_TO_POINTER { "function_to_pointer" },
	POINTER_TO_BOOL { "pointer_to_bool" },
	POINTER_TO_INT { "pointer_to_int" },
	BOOL_TO_INT { "bool_to_int" },
	BOOL_TO_FLOAT { "bool_to_float" },
	BOOL_TO_POINTER { "bool_to_pointer" },
	INT_TO_BOOL { "int_to_bool" },
	INT_TO_FLOAT { "int_to_float" },
	COMPLEX_INT_TO_COMPLEX_FLOAT { "complex_int_to_complex_float" },
	INT_TO_POINTER { "int_to_pointer" },
	FLOAT_TO_BOOL { "float_to_bool" },
	FLOAT_TO_INT { "float_to_int" },
	COMPLEX_FLOAT_TO_COMPLEX_INT { "complex_float_to_complex_int" },
	INT_CAST { "int_cast" },
	COMPLEX_INT_CAST { "complex_int_cast" },
	COMPLEX_INT_TO_REAL { "complex_int_to_real" },
	REAL_TO_COMPLEX_INT { "real_to_complex_int" },
	FLOAT_CAST { "float_cast" },
	COMPLEX_FLOAT_CAST { "complex_float_cast" },
	COMPLEX_FLOAT_TO_REAL { "complex_float_to_real" },
	REAL_TO_COMPLEX_FLOAT { "real_to_complex_float" },
	TO_VOID { "to_void" },
	NULL_TO_POINTER { "null_to_pointer" },
	UNION_CAST { "union_cast" },
	VECTOR_SPLAT { "vector_splat" },
	ATOMIC_TO_NON_ATOMIC { "atomic_to_non_atomic" },
	NON_ATOMIC_TO_ATOMIC { "non_atomic_to_atomic" },
}

<* Zig `Node.CharLiteral.kind` (also used by string_literal_expr). *>
enum CharLiteralKind : char (String name)
{
	ASCII { "ascii" },
	WIDE { "wide" },
	UTF8 { "utf8" },
	UTF16 { "utf16" },
	UTF32 { "utf32" },
}

<* Zig `Node.Param.storage_class`. *>
enum ParamStorageClass : char
{
	AUTO,
	REGISTER,
}

<* Zig `Node.Variable.storage_class`. *>
enum VariableStorageClass : char
{
	AUTO,
	STATIC,
	EXTERN,
	REGISTER,
}

<* Zig `Node.CompoundLiteral.storage_class`. *>
enum CompoundLiteralStorageClass : char
{
	AUTO,
	STATIC,
	REGISTER,
}

<* Zig `Node.ReturnStmt.operand` union tag. *>
enum ReturnOperandKind : char
{
	EXPR,
	<* `implicit: bool`: true if the function is called "main" and return_qt is compatible with int. *>
	IMPLICIT,
	NONE,
}

<* Zig `Tree.GNUAssemblyQualifiers` (packed struct(u32)). *>
bitstruct GnuAsmQualifiers : uint
{
	bool is_volatile : 0;
	bool is_inline : 1;
	bool is_goto : 2;
}

<* Zig `Node.Repr.DeclAttr` (packed struct(u32)). *>
bitstruct DeclAttr : uint
{
	bool is_extern : 0;
	bool is_static : 1;
	bool is_inline : 2;
	bool thread_local : 3;
	bool implicit : 4;
	bool register : 5;
}

<*
 Zig `Node.Repr.DiagnosticPack` (packed struct(u32)): bit 0 is `kind`
 (0 = error, 1 = warning), bit 1 is `opt` (0 = none, 1 = attribute-warning).
*>
bitstruct DiagnosticPack : uint
{
	bool is_warning : 0;
	bool attribute_warning : 1;
}

// ---------------------------------------------------------------------------
// Node payloads (Zig `Node.*` structs). Field order and meaning follow Zig.
// ---------------------------------------------------------------------------

<* EMPTY_DECL *>
struct NodeEmptyDecl
{
	tokens::TokenIndex semicolon;
}

<* STATIC_ASSERT *>
struct NodeStaticAssert
{
	tokens::TokenIndex assert_tok;
	NodeIndex cond;
	NodeOptIndex message;
}

<* FUNCTION (tags FN_PROTO when body is null, FN_DEF otherwise). *>
struct NodeFunction
{
	tokens::TokenIndex name_tok;
	QualType qt;
	bool is_static;
	bool is_inline;
	NodeOptIndex body;
	<* Actual, non-tentative definition of this function. *>
	NodeOptIndex definition;
}

<* PARAM *>
struct NodeParam
{
	tokens::TokenIndex name_tok;
	QualType qt;
	ParamStorageClass storage_class;
}

<* VARIABLE (tags VARIABLE when initializer is null, VARIABLE_DEF otherwise). *>
struct NodeVariable
{
	tokens::TokenIndex name_tok;
	QualType qt;
	VariableStorageClass storage_class;
	bool thread_local;
	<* From predefined macro __func__, __FUNCTION__ or __PRETTY_FUNCTION__. Implies static. *>
	bool implicit;
	NodeOptIndex initializer;
	<* Actual, non-tentative definition of this variable. *>
	NodeOptIndex definition;
}

<* TYPEDEF (union member `.type_def`). *>
struct NodeTypedef
{
	tokens::TokenIndex name_tok;
	QualType qt;
	bool implicit;
}

<* GLOBAL_ASM *>
struct NodeGlobalAsm
{
	tokens::TokenIndex asm_tok;
	NodeIndex asm_str;
}

<* STRUCT_DECL, UNION_DECL, ENUM_DECL (union member `.container_decl`). *>
struct NodeContainerDecl
{
	tokens::TokenIndex name_or_kind_tok;
	QualType container_qt;
	NodeIndex[] fields;
}

<* STRUCT/UNION/ENUM_FORWARD_DECL (union member `.container_forward_decl`). *>
struct NodeContainerForwardDecl
{
	tokens::TokenIndex name_or_kind_tok;
	QualType container_qt;
	<* The definition for this forward declaration if one exists (never stored; decodes NODE_NULL). *>
	NodeOptIndex definition;
}

<* ENUM_FIELD *>
struct NodeEnumField
{
	tokens::TokenIndex name_tok;
	QualType qt;
	NodeOptIndex init;
}

<* RECORD_FIELD *>
struct NodeRecordField
{
	tokens::TokenIndex name_or_first_tok;
	QualType qt;
	NodeOptIndex bit_width;
}

<* LABELED_STMT *>
struct NodeLabeledStmt
{
	tokens::TokenIndex label_tok;
	NodeIndex body;
}

<* COMPOUND_STMT *>
struct NodeCompoundStmt
{
	tokens::TokenIndex l_brace_tok;
	NodeIndex[] body;
}

<* IF_STMT *>
struct NodeIfStmt
{
	tokens::TokenIndex if_tok;
	NodeOptIndex init;
	NodeIndex cond;
	NodeIndex then_body;
	NodeOptIndex else_body;
}

<* SWITCH_STMT *>
struct NodeSwitchStmt
{
	tokens::TokenIndex switch_tok;
	NodeOptIndex init;
	NodeIndex cond;
	NodeIndex body;
}

<* CASE_STMT *>
struct NodeCaseStmt
{
	tokens::TokenIndex case_tok;
	NodeIndex start;
	NodeOptIndex end;
	NodeIndex body;
}

<* DEFAULT_STMT *>
struct NodeDefaultStmt
{
	tokens::TokenIndex default_tok;
	NodeIndex body;
}

<* WHILE_STMT *>
struct NodeWhileStmt
{
	tokens::TokenIndex while_tok;
	NodeIndex cond;
	NodeIndex body;
}

<* DO_WHILE_STMT *>
struct NodeDoWhileStmt
{
	tokens::TokenIndex do_tok;
	NodeIndex cond;
	NodeIndex body;
}

<* FOR_STMT *>
struct NodeForStmt
{
	tokens::TokenIndex for_tok;
	NodeOptIndex init;
	NodeOptIndex cond;
	NodeOptIndex incr;
	NodeIndex body;
}

<* GOTO_STMT *>
struct NodeGotoStmt
{
	tokens::TokenIndex label_tok;
}

<* COMPUTED_GOTO_STMT *>
struct NodeComputedGotoStmt
{
	tokens::TokenIndex goto_tok;
	NodeIndex expr;
}

<* CONTINUE_STMT (Zig `label: ?tokens::TokenIndex` is has_label + label). *>
struct NodeContinueStmt
{
	tokens::TokenIndex continue_tok;
	bool has_label;
	tokens::TokenIndex label;
}

<* BREAK_STMT (Zig `label: ?tokens::TokenIndex` is has_label + label). *>
struct NodeBreakStmt
{
	tokens::TokenIndex break_tok;
	bool has_label;
	tokens::TokenIndex label;
}

<* NULL_STMT *>
struct NodeNullStmt
{
	tokens::TokenIndex semicolon_or_r_brace_tok;
}

<*
 RETURN_STMT. Zig `operand: union(enum) { expr, implicit: bool, none }` is
 `operand` + `expr` (for EXPR) + `implicit_value` (for IMPLICIT).
*>
struct NodeReturnStmt
{
	tokens::TokenIndex return_tok;
	QualType return_qt;
	ReturnOperandKind operand;
	NodeIndex expr;
	bool implicit_value;
}

<* Zig `AsmStmt.Operand`: three u32 words, stored inline in `Tree.extra`. *>
struct AsmOperand
{
	tokens::TokenIndex name;
	NodeIndex constraint;
	NodeIndex expr;
}

<* ASM_STMT *>
struct NodeAsmStmt
{
	tokens::TokenIndex asm_tok;
	NodeIndex asm_str;
	AsmOperand[] outputs;
	AsmOperand[] inputs;
	NodeIndex[] clobbers;
	NodeIndex[] labels;
	GnuAsmQualifiers quals;
}

<* DECL_STMT *>
struct NodeDeclStmt
{
	NodeIndex[] decls;
	tokens::TokenIndex first_tok;
}

<*
 Union member `.binary`: ASSIGN_EXPR, MUL/DIV/MOD/ADD/SUB/SHL/SHR/BIT_AND/
 BIT_XOR/BIT_OR_ASSIGN_EXPR, COMMA_EXPR, BOOL_OR/BOOL_AND/BIT_OR/BIT_XOR/
 BIT_AND_EXPR, EQUAL/NOT_EQUAL/LESS_THAN/LESS_THAN_EQUAL/GREATER_THAN/
 GREATER_THAN_EQUAL_EXPR, SHL/SHR/ADD/SUB/MUL/DIV/MOD_EXPR.
*>
struct NodeBinary
{
	QualType qt;
	NodeIndex lhs;
	tokens::TokenIndex op_tok;
	NodeIndex rhs;
}

<* CAST (tags EXPLICIT_CAST / IMPLICIT_CAST by `implicit`). *>
struct NodeCast
{
	QualType qt;
	tokens::TokenIndex l_paren;
	CastKind kind;
	NodeIndex operand;
	bool implicit;
}

<*
 Union member `.unary`: COMPOUND_ASSIGN_DUMMY_EXPR, ADDR_OF/DEREF/PLUS/NEGATE/
 BIT_NOT/BOOL_NOT/PRE_INC/PRE_DEC/IMAG/REAL/POST_INC/POST_DEC/PAREN_EXPR,
 STMT_EXPR, IMAGINARY_LITERAL, COND_DUMMY_EXPR.
*>
struct NodeUnary
{
	QualType qt;
	tokens::TokenIndex op_tok;
	NodeIndex operand;
}

<* ADDR_OF_LABEL *>
struct NodeAddrOfLabel
{
	tokens::TokenIndex label_tok;
	QualType qt;
}

<* ARRAY_ACCESS_EXPR (union member `.array_access`). *>
struct NodeArrayAccess
{
	tokens::TokenIndex l_bracket_tok;
	QualType qt;
	NodeIndex base;
	NodeIndex index;
}

<* MEMBER_ACCESS_EXPR, MEMBER_ACCESS_PTR_EXPR (union member `.member_access`). *>
struct NodeMemberAccess
{
	QualType qt;
	NodeIndex base;
	tokens::TokenIndex access_tok;
	uint member_index;
}

<* CALL_EXPR (union member `.call`). *>
struct NodeCall
{
	tokens::TokenIndex l_paren_tok;
	QualType qt;
	NodeIndex callee;
	NodeIndex[] args;
}

<* DECL_REF_EXPR, ENUMERATION_REF (union member `.decl_ref`). *>
struct NodeDeclRef
{
	tokens::TokenIndex name_tok;
	QualType qt;
	NodeIndex decl;
}

<* BUILTIN_CALL_EXPR (union member `.builtin_call`). *>
struct NodeBuiltinCall
{
	tokens::TokenIndex builtin_tok;
	QualType qt;
	NodeIndex[] args;
}

<* BUILTIN_REF *>
struct NodeBuiltinRef
{
	tokens::TokenIndex name_tok;
	QualType qt;
}

<* BUILTIN_TYPES_COMPATIBLE_P (union member `.types_compatible`). *>
struct NodeTypesCompatible
{
	tokens::TokenIndex builtin_tok;
	QualType lhs;
	QualType rhs;
}

<* BUILTIN_CONVERTVECTOR (union member `.convertvector`). *>
struct NodeConvertvector
{
	tokens::TokenIndex builtin_tok;
	QualType dest_qt;
	NodeIndex operand;
}

<* BUILTIN_SHUFFLEVECTOR (union member `.shufflevector`). *>
struct NodeShufflevector
{
	tokens::TokenIndex builtin_tok;
	QualType qt;
	NodeIndex lhs;
	NodeIndex rhs;
	NodeIndex[] indexes;
}

<* BUILTIN_VA_ARG_PACK, BUILTIN_VA_ARG_PACK_LEN (union member `.va_arg_pack`). *>
struct NodeVaArgPack
{
	tokens::TokenIndex builtin_tok;
}

<* BOOL_LITERAL, NULLPTR_LITERAL, INT_LITERAL, FLOAT_LITERAL (union member `.literal`). *>
struct NodeLiteral
{
	tokens::TokenIndex literal_tok;
	QualType qt;
}

<* CHAR_LITERAL, STRING_LITERAL_EXPR (union member `.char_literal`). *>
struct NodeCharLiteral
{
	tokens::TokenIndex literal_tok;
	QualType qt;
	CharLiteralKind kind;
}

<* COMPOUND_LITERAL_EXPR (union member `.compound_literal`). *>
struct NodeCompoundLiteral
{
	tokens::TokenIndex l_paren_tok;
	QualType qt;
	bool thread_local;
	CompoundLiteralStorageClass storage_class;
	NodeIndex initializer;
}

<* SIZEOF_EXPR, ALIGNOF_EXPR, COUNTOF_EXPR (union member `.type_info`). *>
struct NodeTypeInfo
{
	QualType qt;
	tokens::TokenIndex op_tok;
	NodeOptIndex expr;
	QualType operand_qt;
}

<* GENERIC_EXPR. Child nodes are GENERIC_ASSOCIATION_EXPR or GENERIC_DEFAULT_EXPR. *>
struct NodeGeneric
{
	tokens::TokenIndex generic_tok;
	QualType qt;
	NodeIndex controlling;
	NodeIndex chosen;
	NodeIndex[] rest;
}

<* GENERIC_ASSOCIATION_EXPR (Zig `Generic.Association`). *>
struct NodeGenericAssociation
{
	tokens::TokenIndex colon_tok;
	QualType association_qt;
	NodeIndex expr;
}

<* GENERIC_DEFAULT_EXPR (Zig `Generic.Default`). *>
struct NodeGenericDefault
{
	tokens::TokenIndex default_tok;
	NodeIndex expr;
}

<* BUILTIN_CHOOSE_EXPR, BINARY_COND_EXPR, COND_EXPR (union member `.conditional`). *>
struct NodeConditional
{
	tokens::TokenIndex cond_tok;
	QualType qt;
	NodeIndex cond;
	NodeIndex then_expr;
	NodeIndex else_expr;
}

<* ARRAY_INIT_EXPR, STRUCT_INIT_EXPR (union member `.container_init`). *>
struct NodeContainerInit
{
	tokens::TokenIndex l_brace_tok;
	QualType container_qt;
	NodeIndex[] items;
}

<* UNION_INIT_EXPR *>
struct NodeUnionInit
{
	tokens::TokenIndex l_brace_tok;
	QualType union_qt;
	uint field_index;
	NodeOptIndex initializer;
}

<* ARRAY_FILLER_EXPR: inserted in array_init_expr for unspecified elements. *>
struct NodeArrayFiller
{
	tokens::TokenIndex last_tok;
	QualType qt;
	ulong count;
}

<* DEFAULT_INIT_EXPR: inserted in record and scalar initializers for unspecified elements. *>
struct NodeDefaultInit
{
	tokens::TokenIndex last_tok;
	QualType qt;
}

<*
 CODEGEN_DIAGNOSTIC. `kind` is ERROR or WARNING; `opt` is only
 ATTRIBUTE_WARNING (when has_opt). `text` is the formatted message bytes
 NUL-padded to a multiple of 4 (at least one NUL), viewed as u32 words, as
 Parser.codegenDiagnostic builds it.
*>
struct NodeCodegenDiagnostic
{
	tokens::TokenIndex tok;
	MessageKind kind;
	bool has_opt;
	Option opt;
	uint[] text;
}

<* ALIGNAS_TYPE: _Alignas(<type>) used as argument of an alignas attribute. *>
struct NodeAlignasType
{
	tokens::TokenIndex alignas_tok;
	QualType qt;
}

<* IDENTIFIER_ARG: plain identifier argument of an attribute. *>
struct NodeIdentifierArg
{
	tokens::TokenIndex identifier_tok;
}

<*
 Zig `Tree.Node` (union(enum)). Read the member that `kind` selects (see
 the payload doc comments / docs/c3-tree-tags.md).
*>
struct Node
{
	NodeKind kind;
	union
	{
		NodeEmptyDecl empty_decl;
		NodeStaticAssert static_assert;
		NodeFunction function;
		NodeParam param;
		NodeVariable variable;
		NodeTypedef type_def;
		NodeGlobalAsm global_asm;
		NodeContainerDecl container_decl;
		NodeContainerForwardDecl container_forward_decl;
		NodeEnumField enum_field;
		NodeRecordField record_field;
		NodeLabeledStmt labeled_stmt;
		NodeCompoundStmt compound_stmt;
		NodeIfStmt if_stmt;
		NodeSwitchStmt switch_stmt;
		NodeCaseStmt case_stmt;
		NodeDefaultStmt default_stmt;
		NodeWhileStmt while_stmt;
		NodeDoWhileStmt do_while_stmt;
		NodeForStmt for_stmt;
		NodeGotoStmt goto_stmt;
		NodeComputedGotoStmt computed_goto_stmt;
		NodeContinueStmt continue_stmt;
		NodeBreakStmt break_stmt;
		NodeNullStmt null_stmt;
		NodeReturnStmt return_stmt;
		NodeAsmStmt asm_stmt;
		NodeDeclStmt decl_stmt;
		NodeBinary binary;
		NodeCast cast;
		NodeUnary unary;
		NodeAddrOfLabel addr_of_label;
		NodeArrayAccess array_access;
		NodeMemberAccess member_access;
		NodeCall call;
		NodeDeclRef decl_ref;
		NodeBuiltinCall builtin_call;
		NodeBuiltinRef builtin_ref;
		NodeTypesCompatible types_compatible;
		NodeConvertvector convertvector;
		NodeShufflevector shufflevector;
		NodeVaArgPack va_arg_pack;
		NodeLiteral literal;
		NodeCharLiteral char_literal;
		NodeCompoundLiteral compound_literal;
		NodeTypeInfo type_info;
		NodeGeneric generic;
		NodeGenericAssociation generic_association;
		NodeGenericDefault generic_default;
		NodeConditional conditional;
		NodeContainerInit container_init;
		NodeUnionInit union_init;
		NodeArrayFiller array_filler;
		NodeDefaultInit default_init;
		NodeCodegenDiagnostic codegen_diagnostic;
		NodeAlignasType alignas_type;
		NodeIdentifierArg identifier_arg;
	}
}

<*
 Zig `Node.isImplicit`: true for ARRAY_FILLER_EXPR, DEFAULT_INIT_EXPR,
 COND_DUMMY_EXPR, COMPOUND_ASSIGN_DUMMY_EXPR; a RETURN_STMT whose operand is
 IMPLICIT; a CAST with `implicit`; a VARIABLE or TYPEDEF with `implicit`.
*>
fn bool Node.is_implicit(&self)
{
	switch (self.kind)
	{
		case ARRAY_FILLER_EXPR: case DEFAULT_INIT_EXPR: case COND_DUMMY_EXPR: case COMPOUND_ASSIGN_DUMMY_EXPR: return true;
		case RETURN_STMT: return self.return_stmt.operand == IMPLICIT;
		case CAST: return self.cast.implicit;
		case VARIABLE: return self.variable.implicit;
		case TYPEDEF: return self.type_def.implicit;
		default: return false;
	}
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

<*
 Zig `Node.Repr`: `tag`, three data words (if a node is typed its QualType
 bits are in data[0]) and the node's main token. Layout per tag:
 docs/c3-tree-tags.md section 2.
*>
struct NodeRepr
{
	NodeTag tag;
	uint[3] data;
	tokens::TokenIndex tok;
}

<*
 Zig `Tree`. Create with `init`, release with `free`.
*>
struct Tree
{
	Compilation* comp;
	<* Values from the Preprocessor (Zig `Token.List.Slice`); borrowed. *>
	TreeToken[] tokens;

	// Values owned by this Tree (allocated from comp.gpa).
	List{NodeRepr} nodes;
	List{uint} extra;
	List{NodeIndex} root_decls;
	<* Zig `ValueMap` (AutoHashMap(Node.Index, Value)), keyed by `(uint)NodeIndex`. *>
	HashMap{uint, Value} value_map;
	AttributeMap attr_map;
}

<*
 Set up an empty tree over `tokens` (borrowed; must outlive the tree). All
 containers use `comp.gpa`.
*>
fn void Tree.init(&self, Compilation* comp, TreeToken[] tokens)
{
	*self = { .comp = comp, .tokens = tokens };
	self.nodes.init(comp.gpa);
	self.extra.init(comp.gpa);
	self.root_decls.init(comp.gpa);
	self.value_map.init(comp.gpa);
	self.attr_map.init(comp.gpa);
}

<* Zig `deinit`: frees nodes, extra, root_decls, value_map and attr_map; resets to `{}`. *>
fn void Tree.free(&self)
{
	self.nodes.free(); self.extra.free(); self.root_decls.free(); self.value_map.free(); self.attr_map.free();
	*self = {};
}

<* Zig `addNode`: append a new repr slot and `set_node` it; returns its index. *>
fn NodeIndex Tree.add_node(&self, Node node)
{
	NodeRepr repr = {};
	self.nodes.push(repr);
	usz index = self.nodes.len() - 1;
	self.set_node(node, index);
	return (NodeIndex)(uint)index;
}

<*
 Zig `setNode`: encode `node` into `nodes[index]`, picking the compact
 storage tag and appending to `extra` as needed. Dispatches on
 `node.kind.family`: DECL -> `encode_decl` (tree_decl.c3), STMT/EXPR ->
 `encode_expr_stmt` (tree_expr.c3).
 @require (sz)index < self.nodes.len()
*>
fn void Tree.set_node(&self, Node node, usz index)
{
	assert(index < self.nodes.len());
	NodeRepr repr = {};
	repr.tok = 0;
	switch (node.kind.family)
	{
		case DECL: self.encode_decl(node, &repr);
		case STMT: case EXPR: self.encode_expr_stmt(node, &repr);
	}
	self.nodes[index] = repr;
}

<*
 Zig `Node.Index.get`: decode `nodes[index]` into a `Node`. Dispatches on
 `tag.kind.family`: DECL -> `decode_decl`, STMT/EXPR -> `decode_expr_stmt`.
 Returned slices alias tree storage (see the module comment).
*>
fn Node NodeIndex.get(self, Tree* tree)
{
	NodeTag tag = tree.nodes[(usz)self].tag;
	switch (tag.kind.family)
	{
		case DECL: return tree.decode_decl(self);
		case STMT: case EXPR: return tree.decode_expr_stmt(self);
	}
}

<* Zig `Node.Index.tok`: the node's main token. *>
fn tokens::TokenIndex NodeIndex.tok(self, Tree* tree)
{
	return tree.nodes[(usz)self].tok;
}

<* Zig `Node.Index.loc`: `tree.tokens[index.tok(tree)].loc`. *>
fn Location NodeIndex.loc(self, Tree* tree)
{
	return tree.tokens[(usz)self.tok(tree)].loc;
}

<* Zig `Node.Index.qt`: `qt_or_null` or `type_store::VOID`. *>
fn QualType NodeIndex.qt(self, Tree* tree)
{
	return self.qt_or_null(tree) ?? type_store::VOID;
}

<*
 Zig `Node.Index.qtOrNull`: NO_QT for EMPTY_DECL, STATIC_ASSERT,
 COMPOUND_STMT(_THREE), IF_STMT/IF_INIT/IF_FULL, SWITCH/CASE/DEFAULT/WHILE/
 DO_WHILE_STMT, all FOR_* tags, GOTO/COMPUTED_GOTO/CONTINUE/BREAK_STMT, all
 ASM_STMT* tags, DECL_STMT(_THREE), NULL_STMT, LABELED_STMT, GLOBAL_ASM,
 GENERIC_ASSOCIATION_EXPR, GENERIC_DEFAULT_EXPR, BUILTIN_VA_ARG_PACK;
 `type_store::INT` for BUILTIN_VA_ARG_PACK_LEN and BUILTIN_TYPES_COMPATIBLE_P;
 otherwise the QualType bits in data[0].
*>
fn QualType? NodeIndex.qt_or_null(self, Tree* tree)
{
	NodeTag tag = self.tag(tree);
	switch (tag)
	{
		case EMPTY_DECL: case STATIC_ASSERT: case COMPOUND_STMT: case COMPOUND_STMT_THREE:
		case IF_STMT: case IF_INIT: case IF_FULL: case SWITCH_STMT: case CASE_STMT: case DEFAULT_STMT:
		case WHILE_STMT: case DO_WHILE_STMT: case FOR_FULL: case FOR_INIT_COND: case FOR_INIT_INCR:
		case FOR_COND_INCR: case FOR_INIT: case FOR_COND: case FOR_INCR: case FOR_EVER: case GOTO_STMT:
		case COMPUTED_GOTO_STMT: case CONTINUE_STMT: case BREAK_STMT: case ASM_STMT:
		case ASM_STMT_VOLATILE: case ASM_STMT_INLINE: case ASM_STMT_INLINE_VOLATILE:
		case ASM_STMT_SIMPLE: case DECL_STMT_THREE: case DECL_STMT: case NULL_STMT: case LABELED_STMT:
		case GLOBAL_ASM: case GENERIC_ASSOCIATION_EXPR: case GENERIC_DEFAULT_EXPR:
		case BUILTIN_VA_ARG_PACK: return NO_QT~;
		case BUILTIN_VA_ARG_PACK_LEN: case BUILTIN_TYPES_COMPATIBLE_P: return type_store::INT;
		default: return (QualType)tree.nodes[(usz)self].data[0];
	}
}

<* The storage tag of a node (Zig `tree.nodes.items(.tag)[index]`). *>
fn NodeTag NodeIndex.tag(self, Tree* tree)
{
	return tree.nodes[(usz)self].tag;
}

<* Zig `addExtra`: append `data` to `extra`; returns its start index and length. *>
fn ExtraSpan Tree.add_extra(&self, NodeIndex[] data)
{
	uint start = (uint)self.extra.len();
	foreach (item : data) self.extra.push(item);
	return { .index = start, .len = (uint)data.len };
}

<* Zig `tokSlice`: the token's fixed lexeme, else its source text (`comp.loc_slice`). *>
fn String Tree.tok_slice(&self, tokens::TokenIndex tok_i)
{
	TreeToken tok = self.tokens[(usz)tok_i];
	String? fixed = tok.id.lexeme();
	if (fixed != null) return fixed!;
	Source src = self.comp.get_source(tok.loc.id);
	Tokenizer scanner;
	scanner.init(src.buf, source::GENERATED_ID, self.comp.langopts, src.splice_locs);
	scanner.index = tok.loc.byte_offset;
	Token span = scanner.next();
	return src.buf[(usz)span.start..(usz)span.end];
}

<* Zig `tree.value_map.get(node)`: the constant value recorded for a node (fault NOT_FOUND). *>
fn Value? Tree.value_of(&self, NodeIndex node)
{
	return self.value_map.get((uint)node);
}

<* Zig `tree.value_map.put(gpa, node, val)`. *>
fn void Tree.set_value(&self, NodeIndex node, Value val)
{
	self.value_map.set((uint)node, val);
}
