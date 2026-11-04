// Port of the expression and statement node families of src/aro/Tree.zig
// (`setNode` / `Node.Index.get` arms) plus the lvalue and bitfield queries
// (`isBitfield`, `bitfieldWidth`, `MemberAccess.isBitFieldWidth`,
// `calledFunctionAttr`, `isLval`, `isLvalExtra`) — plan 16 stage 1 agent
// 16.3 `expr-stmt-nodes`. Part of module aro::tree (see tree.c3).
//
// Families handled here: `NodeKind.family == STMT` (LABELED_STMT ..
// DECL_STMT) and `== EXPR` (every other expression kind).
// Storage tags and data layouts: docs/c3-tree-tags.md section 2.
//
// Stage 0 (contract): signatures only.
module aro::tree;
import aro::tokens, aro::type_store, aro::attribute, aro::attribute_map, aro::compilation, aro::value;

<*
 Zig `setNode` for a STMT- or EXPR-family node. Compact-tag choices:
  - COMPOUND_STMT / DECL_STMT: len > 3 -> extra (data[0] = start,
    data[1] = len); else *_THREE with pack_elem 0..2.
  - IF_STMT: init+else -> IF_FULL (data[2] = extra [then, else]);
    init only -> IF_INIT; else IF_STMT.
  - FOR_STMT: FOR_FULL (cond/incr in extra), FOR_INIT_COND, FOR_INIT_INCR,
    FOR_COND_INCR, FOR_INIT, FOR_COND, FOR_INCR, FOR_EVER by which of
    init/cond/incr are set; data[2] = body.
  - CONTINUE/BREAK_STMT: data[0] = has_label, data[1] = label.
  - RETURN_STMT: EXPR -> RETURN_STMT, NONE -> RETURN_NONE_STMT,
    IMPLICIT -> IMPLICIT_RETURN (data[1] = implicit_value).
  - ASM_STMT: no operands/clobbers/labels -> ASM_STMT_SIMPLE (data[1] =
    quals bits); else ASM_STMT[_INLINE][_VOLATILE] by quals with
    data[1] = labels.len, data[2] = extra start of [outputs.len, inputs.len,
    clobbers.len, outputs (3 words each), inputs, clobbers, labels].
  - CAST: EXPLICIT_CAST / IMPLICIT_CAST, data[1] = kind ordinal.
  - CALL_EXPR: args.len > 1 -> CALL_EXPR (extra [callee, args...],
    data[2] = args.len + 1); else CALL_EXPR_ONE.
  - BUILTIN_CALL_EXPR / ARRAY_INIT_EXPR / STRUCT_INIT_EXPR: len > 2 ->
    extra; else *_TWO packed.
  - GENERIC_EXPR: rest.len > 0 -> GENERIC_EXPR (extra [controlling, chosen,
    rest...], data[2] = rest.len + 2); else GENERIC_EXPR_ZERO.
  - BINARY_COND/COND/BUILTIN_CHOOSE_EXPR: data[2] = extra [then, else].
  - BUILTIN_SHUFFLEVECTOR: extra [lhs, rhs, indexes...], data[2] = indexes.len.
  - ARRAY_FILLER_EXPR: data[1] = low, data[2] = high 32 bits of count.
  - COMPOUND_LITERAL_EXPR: data[1] = DeclAttr{is_static, register, thread_local}.
  - CASE_STMT: data[2] = body (Zig writes it through packOptIndex).
 @require node.kind.family != DECL
*>
fn void Tree.encode_expr_stmt(&self, Node node, NodeRepr* repr)
{
	unreachable("stage 0 stub");
}

<*
 Zig `Node.Index.get` for a STMT/EXPR storage tag (inverse of
 `encode_expr_stmt`). ASM_STMT* quals come from the tag, with
 is_goto = labels.len > 0. Packed forms alias node storage.
 @require index.tag(self).kind.family != DECL
*>
fn Node Tree.decode_expr_stmt(&self, NodeIndex index)
{
	unreachable("stage 0 stub");
}

<*
 Zig `MemberAccess.isBitFieldWidth`: the bit width of the accessed record
 field, looking through one pointer level of `base`'s type. NOT_BITFIELD
 when the base type is invalid, not a struct/union, or the field has no
 bit width.
*>
fn uint? NodeMemberAccess.is_bit_field_width(self, Tree* tree)
{
	unreachable("stage 0 stub");
}

<* Zig `isBitfield`: `bitfield_width(node, false)` succeeds. *>
fn bool Tree.is_bitfield(&self, NodeIndex node)
{
	unreachable("stage 0 stub");
}

<*
 Zig `bitfieldWidth`: MEMBER_ACCESS(_PTR)_EXPR -> is_bit_field_width; a
 CAST with kind LVAL_TO_RVAL recurses into its operand (inspect_lval
 false) only when `inspect_lval`; anything else NOT_BITFIELD.
*>
fn uint? Tree.bitfield_width(&self, NodeIndex node, bool inspect_lval)
{
	unreachable("stage 0 stub");
}

<* Zig `CalledFunctionAttr`. *>
struct CalledFunctionAttr
{
	<* Name token of the thing being called, for diagnostics. *>
	tokens::TokenIndex tok;
	<* The requested attribute if present (Zig `attr: ?Attribute`). *>
	bool has_attr;
	Attribute attr;
}

<*
 Zig `calledFunctionAttr`: check for an attribute on the called function's
 declaration or on its return type. Walks PAREN/ADDR_OF/DEREF_EXPR operands,
 COMMA_EXPR rhs, CAST operands and CALL_EXPR callees; DECL_REF_EXPR uses
 `attr_map.get_attribute(decl)` falling back to the function type's return
 type (`QualType.get_attribute`); MEMBER_ACCESS(_PTR)_EXPR uses the record
 field's `field_decl` and type the same way (tok = field.name_tok).
 Anything else is NO_CALLED_FUNCTION.
*>
fn CalledFunctionAttr? Tree.called_function_attr(&self, NodeIndex node, AttributeTag tag)
{
	unreachable("stage 0 stub");
}

<* Zig `isLval`. *>
fn bool Tree.is_lval(&self, NodeIndex node)
{
	unreachable("stage 0 stub");
}

<*
 Zig `isLvalExtra`: sets `*is_const` (false first) and returns whether
 `node` is an lvalue: COMPOUND_LITERAL_EXPR (const from qt),
 STRING_LITERAL_EXPR, MEMBER_ACCESS_PTR_EXPR (const from pointee),
 MEMBER_ACCESS_EXPR (recurse into base), ARRAY_ACCESS_EXPR (const from the
 base pointer's pointee), DECL_REF_EXPR (const from qt), DEREF_EXPR (false
 for a function operand, true if the operand type is invalid, const from
 pointee), PAREN_EXPR (recurse), BUILTIN_CHOOSE_EXPR (recurse into the
 branch chosen by value_map[cond], false if no value),
 COMPOUND_ASSIGN_DUMMY_EXPR (true); else false.
*>
fn bool Tree.is_lval_extra(&self, NodeIndex node, bool* is_const)
{
	unreachable("stage 0 stub");
}
