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
//    `Tree.nodes`. Instead of Zig's `Repr.Tag` (kind x storage variant) it
//    stores the `NodeKind` plus `NodeForm` bits selecting the variant.
//  - Slices in a decoded `Node` (fields, body, args, ...) point into
//    `Tree.extra` or into the node's own `NodeRepr.data` (the "_two"/"_three"
//    packed forms, Zig `unPackElems`). Exactly as in Zig they stay valid only
//    until the next `add_node`/`set_node`/`add_extra` grows those lists.
//  - Ownership: `tokens` are borrowed (owned by the Preprocessor/Compilation);
//    `nodes`, `extra`, `root_decls`, `value_map` and `attr_map` are owned and
//    released by `Tree.free` (Zig `deinit`).
//  - Running out of memory panics, so Zig's `!T` (OOM only) is plain `T`.
//  - Zig leaves unused `Repr.data` words `undefined`; C3 zero-initializes
//    them. `qt_or_null` reads data[0] for every non-listed kind (including
//    IDENTIFIER_ARG and CODEGEN_DIAGNOSTIC), as Zig does.
//
// Storage and node dispatch live here; declaration and expression codecs,
// source-aware writing, and dumping are split into the companion files.
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
	DECL,  // tree_decl.c3
	STMT,  // tree_expr.c3
	EXPR,  // tree_expr.c3
}

<*
 Zig `std.meta.Tag(Tree.Node)`, in Zig declaration order. `name` is the Zig
 tag name (`{t}` in `dumpNode`), `family` the owning encoder/decoder.
*>
enum NodeKind : char(String name, NodeFamily family)
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

<*
 Storage-variant bits of a `NodeRepr`; which bits apply depends on `kind`.
 Replaces Zig `Node.Repr.Tag`'s per-kind variants (FN_PROTO/FN_DEF,
 FOR_INIT_COND, *_TWO/_THREE, IMPLICIT_CAST, ASM_STMT_INLINE, ...); see
 docs/c3-tree-tags.md section 2.
*>
bitstruct NodeForm : ushort
{
	bool packed: 0;       // elements inline in data[] (Zig *_two/*_three/_one/_zero, asm_stmt_simple)
	bool defined: 1;      // FUNCTION/VARIABLE: data[2] is body/initializer, else definition
	bool implicit: 2;     // CAST: implicit cast; RETURN_STMT: implicit return
	bool has_init: 3;     // IF_STMT, FOR_STMT
	bool has_cond: 4;     // FOR_STMT
	bool has_incr: 5;     // FOR_STMT
	bool has_else: 6;     // IF_STMT with init (Zig if_full)
	bool asm_inline: 7;   // ASM_STMT (non-simple)
	bool asm_volatile: 8; // ASM_STMT (non-simple)
	bool return_none: 9;  // RETURN_STMT without operand
}

<* Zig `Node.Cast.Kind`; `name` is the Zig tag name (printed by dump). *>
enum CastKind : char(String name)
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
enum CharLiteralKind : char(String name)
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
	bool is_volatile: 0;
	bool is_inline: 1;
	bool is_goto: 2;
}

<* Zig `Node.Repr.DeclAttr` (packed struct(u32)). *>
bitstruct DeclAttr : uint
{
	bool is_extern: 0;
	bool is_static: 1;
	bool is_inline: 2;
	bool thread_local: 3;
	bool implicit: 4;
	bool register: 5;
}

<*
 Zig `Node.Repr.DiagnosticPack` (packed struct(u32)): bit 0 is `kind`
 (0 = error, 1 = warning), bit 1 is `opt` (0 = none, 1 = attribute-warning).
*>
bitstruct DiagnosticPack : uint
{
	bool is_warning: 0;
	bool attribute_warning: 1;
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

<* FUNCTION (form.defined when body is set; Zig fn_proto / fn_def). *>
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

<* VARIABLE (form.defined when initializer is set; Zig variable / variable_def). *>
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

<* CAST (form.implicit mirrors `implicit`; Zig explicit_cast / implicit_cast). *>
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
		case ARRAY_FILLER_EXPR:
		case DEFAULT_INIT_EXPR:
		case COND_DUMMY_EXPR:
		case COMPOUND_ASSIGN_DUMMY_EXPR: return true;
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
 Zig `Node.Repr.data`: three 32-bit words, with one named view per payload
 layout (docs/c3-tree-tags.md section 2). Every field is a 32-bit word, so
 views never pad; a typed node's QualType is always the first word. Which
 view applies is fixed by the node's kind and form bits.
*>
union NodeData
{
	uint[3] words;
	<* Packed node lists (compound/decl_stmt; NODE_NULL ends the list). *>
	NodeIndex[3] elems;
	<* Typed node with no other data (forward decls, literals, alignas, ...). *>
	struct typed { QualType qt; }
	<* Typed packed list (form.packed container decls, builtin calls, init exprs). *>
	struct typed_list { QualType qt; NodeIndex[2] elems; }
	<* Typed list in `extra` (container decls, builtin calls, init exprs). *>
	struct typed_span { QualType qt; uint start; uint len; }
	<* Untyped list in `extra` (compound/decl_stmt). *>
	struct span { uint start; uint len; }
	<* FUNCTION / VARIABLE / PARAM: `link` is body/initializer (form.defined) or definition. *>
	struct decl { QualType qt; DeclAttr attr; NodeOptIndex link; }
	struct static_assert { NodeIndex cond; NodeOptIndex message; }
	struct type_def { QualType qt; uint implicit; }
	struct global_asm { NodeIndex asm_str; }
	<* ENUM_FIELD init / RECORD_FIELD bit_width. *>
	struct field { QualType qt; NodeOptIndex opt; }
	struct diagnostic { DiagnosticPack pack; uint start; uint len; }
	<* LABELED_STMT / DEFAULT_STMT. *>
	struct body { NodeIndex body; }
	<* IF_STMT without init. *>
	struct if_stmt { NodeIndex cond; NodeIndex then_body; NodeOptIndex else_body; }
	<* IF_STMT with init: `then_or_extra` is then_body, or (form.has_else) extra start of [then, else]. *>
	struct if_init { NodeIndex cond; NodeOptIndex init; uint then_or_extra; }
	struct switch_stmt { NodeIndex cond; NodeOptIndex init; NodeIndex body; }
	struct case_stmt { NodeIndex start; NodeOptIndex end; NodeIndex body; }
	<* WHILE_STMT / DO_WHILE_STMT. *>
	struct loop { NodeIndex cond; NodeIndex body; }
	<* FOR_STMT: present clauses in init, cond, incr order; with all three, [init, extra start of [cond, incr]]. *>
	struct for_stmt { uint[2] clauses; NodeIndex body; }
	<* COMPUTED_GOTO_STMT / GENERIC_DEFAULT_EXPR. *>
	struct expr { NodeIndex expr; }
	<* CONTINUE_STMT / BREAK_STMT. *>
	struct jump { uint has_label; tokens::TokenIndex label; }
	<* RETURN_STMT: `value` is the expr node, or implicit_value with form.implicit. *>
	struct return_stmt { QualType qt; uint value; }
	<* ASM_STMT: form.packed -> quals bits; else labels.len and extra start of the operand block. *>
	struct asm_stmt { NodeIndex asm_str; uint quals_or_labels; uint extra; }
	struct binary { QualType qt; NodeIndex lhs; NodeIndex rhs; }
	struct unary { QualType qt; NodeIndex operand; }
	struct cast { QualType qt; uint kind; NodeIndex operand; }
	struct array_access { QualType qt; NodeIndex base; NodeIndex index; }
	struct member_access { QualType qt; NodeIndex base; uint member_index; }
	struct decl_ref { QualType qt; NodeIndex decl; }
	<* CHAR_LITERAL / STRING_LITERAL_EXPR. *>
	struct char_literal { QualType qt; uint kind; }
	<* SIZEOF / ALIGNOF / COUNTOF_EXPR. *>
	struct type_info { QualType qt; NodeOptIndex expr; QualType operand_qt; }
	<* BINARY_COND / COND / BUILTIN_CHOOSE_EXPR: extra start of [then, else]. *>
	struct conditional { QualType qt; NodeIndex cond; uint extra; }
	<* CALL_EXPR (form.packed). *>
	struct call_one { QualType qt; NodeIndex callee; NodeOptIndex arg; }
	<* CALL_EXPR / GENERIC_EXPR in extra: [callee or controlling+chosen, rest...]. *>
	struct extra_list { QualType qt; uint start; uint len; }
	<* GENERIC_EXPR (form.packed). *>
	struct generic_zero { QualType qt; NodeIndex controlling; NodeIndex chosen; }
	struct generic_association { QualType qt; NodeIndex expr; }
	struct types_compatible { QualType lhs; QualType rhs; }
	struct convertvector { QualType dest_qt; NodeIndex operand; }
	<* BUILTIN_SHUFFLEVECTOR: extra [lhs, rhs, indexes...]. *>
	struct shufflevector { QualType qt; uint start; uint index_count; }
	struct union_init { QualType qt; uint field_index; NodeOptIndex initializer; }
	struct array_filler { QualType qt; uint count_lo; uint count_hi; }
	struct compound_literal { QualType qt; DeclAttr attr; NodeIndex initializer; }
}

<*
 Zig `Node.Repr`: kind + form bits (Zig `tag`), the three data words and the
 node's main token. Layout per kind/form: `NodeData` and docs/c3-tree-tags.md
 section 2.
*>
struct NodeRepr
{
	NodeKind kind;
	NodeForm form;
	NodeData data;
	tokens::TokenIndex tok;
}

<*
 Return the packed node-index prefix from a node's backing representation.
 Unlike unpack_elems, this slice aliases Tree.nodes and remains valid until
 that list grows.
*>
fn NodeIndex[] unpack_node_elems(NodeRepr* repr, usz start, usz length)
{
	uint[] data = ((uint*)&repr.data.words[start])[:length];
	return unpack_elems(data);
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
	sz index = self.nodes.len() - 1;
	self.set_node(node, index);
	return (NodeIndex)index;
}

<*
 Zig `setNode`: encode `node` into `nodes[index]`, picking the compact
 storage tag and appending to `extra` as needed. Dispatches on
 `node.kind.family`: DECL -> `encode_decl` (tree_decl.c3), STMT/EXPR ->
 `encode_expr_stmt` (tree_expr.c3).
 @require index < self.nodes.len()
*>
fn void Tree.set_node(&self, Node node, sz index)
{
	assert(index < self.nodes.len());
	NodeRepr repr = {};
	repr.tok = 0;
	switch (node.kind.family)
	{
		case DECL: self.encode_decl(node, &repr);
		case STMT:
		case EXPR: self.encode_expr_stmt(node, &repr);
	}
	self.nodes[index] = repr;
}

<*
 Zig `Node.Index.get`: decode `nodes[index]` into a `Node`. Dispatches on
 `kind.family`: DECL -> `decode_decl`, STMT/EXPR -> `decode_expr_stmt`.
 Returned slices alias tree storage (see the module comment).
*>
fn Node NodeIndex.get(self, Tree* tree)
{
	switch (tree.nodes[(usz)self].kind.family)
	{
		case DECL: return tree.decode_decl(self);
		case STMT:
		case EXPR: return tree.decode_expr_stmt(self);
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
 Zig `Node.Index.qtOrNull`: NO_QT for statements (except RETURN_STMT),
 EMPTY_DECL, STATIC_ASSERT, GLOBAL_ASM, GENERIC_ASSOCIATION_EXPR,
 GENERIC_DEFAULT_EXPR and BUILTIN_VA_ARG_PACK; `type_store::INT` for
 BUILTIN_VA_ARG_PACK_LEN and BUILTIN_TYPES_COMPATIBLE_P; otherwise the
 QualType bits in data[0].
*>
fn QualType? NodeIndex.qt_or_null(self, Tree* tree)
{
	switch (self.kind(tree))
	{
		case EMPTY_DECL:
		case STATIC_ASSERT:
		case COMPOUND_STMT:
		case IF_STMT:
		case SWITCH_STMT:
		case CASE_STMT:
		case DEFAULT_STMT:
		case WHILE_STMT:
		case DO_WHILE_STMT:
		case FOR_STMT:
		case GOTO_STMT:
		case COMPUTED_GOTO_STMT:
		case CONTINUE_STMT:
		case BREAK_STMT:
		case ASM_STMT:
		case DECL_STMT:
		case NULL_STMT:
		case LABELED_STMT:
		case GLOBAL_ASM:
		case GENERIC_ASSOCIATION_EXPR:
		case GENERIC_DEFAULT_EXPR:
		case BUILTIN_VA_ARG_PACK: return NO_QT~;
		case BUILTIN_VA_ARG_PACK_LEN:
		case BUILTIN_TYPES_COMPATIBLE_P: return type_store::INT;
		default: return tree.nodes[(usz)self].data.typed.qt;
	}
}

<* The node's kind without decoding it (Zig `tree.nodes.items(.tag)[index]`, minus the variant). *>
fn NodeKind NodeIndex.kind(self, Tree* tree) => tree.nodes[(usz)self].kind;

<* The node's storage-variant bits. *>
fn NodeForm NodeIndex.form(self, Tree* tree) => tree.nodes[(usz)self].form;

<* `len` node indices stored in `extra` from `start` (aliases `extra`; valid until it grows). *>
fn NodeIndex[] Tree.extra_nodes(&self, uint start, uint len) => ((NodeIndex*)self.extra.array_view().ptr)[(usz)start : (usz)len];

<* Zig `addExtra`: append `data` to `extra`; returns its start index and length. *>
fn ExtraSpan Tree.add_extra(&self, NodeIndex[] data)
{
	uint start = (uint)self.extra.len();
	foreach (item : data) self.extra.push((uint)item);
	return { .index = start, .len = (uint)data.len };
}

<* Zig `tokSlice`: the token's fixed lexeme, else its source text (`comp.loc_slice`). *>
fn String Tree.tok_slice(&self, tokens::TokenIndex tok_i)
{
	TreeToken tok = self.tokens[(usz)tok_i];
	if (try fixed = tok.id.lexeme()) return fixed;
	Source src = self.comp.get_source(tok.loc.id);
	Tokenizer scanner;
	scanner.init(src.buf, source::GENERATED_ID, self.comp.langopts, src.splice_locs);
	scanner.index = tok.loc.byte_offset;
	Token span = scanner.next();
	return src.buf[(usz)span.start :(usz)(span.end - span.start)];
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
