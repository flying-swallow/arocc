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
// Compact node storage and lvalue/attribute queries follow Tree.zig.
module aro::tree;
import aro::tokens, aro::type_store, aro::attribute, aro::attribute_map, aro::compilation, aro::value;


fn NodeTag binary_tag(NodeKind kind)
{
	switch (kind)
	{
		case ASSIGN_EXPR: return ASSIGN_EXPR;
		case MUL_ASSIGN_EXPR: return MUL_ASSIGN_EXPR;
		case DIV_ASSIGN_EXPR: return DIV_ASSIGN_EXPR;
		case MOD_ASSIGN_EXPR: return MOD_ASSIGN_EXPR;
		case ADD_ASSIGN_EXPR: return ADD_ASSIGN_EXPR;
		case SUB_ASSIGN_EXPR: return SUB_ASSIGN_EXPR;
		case SHL_ASSIGN_EXPR: return SHL_ASSIGN_EXPR;
		case SHR_ASSIGN_EXPR: return SHR_ASSIGN_EXPR;
		case BIT_AND_ASSIGN_EXPR: return BIT_AND_ASSIGN_EXPR;
		case BIT_XOR_ASSIGN_EXPR: return BIT_XOR_ASSIGN_EXPR;
		case BIT_OR_ASSIGN_EXPR: return BIT_OR_ASSIGN_EXPR;
		case COMMA_EXPR: return COMMA_EXPR;
		case BOOL_OR_EXPR: return BOOL_OR_EXPR;
		case BOOL_AND_EXPR: return BOOL_AND_EXPR;
		case BIT_OR_EXPR: return BIT_OR_EXPR;
		case BIT_XOR_EXPR: return BIT_XOR_EXPR;
		case BIT_AND_EXPR: return BIT_AND_EXPR;
		case EQUAL_EXPR: return EQUAL_EXPR;
		case NOT_EQUAL_EXPR: return NOT_EQUAL_EXPR;
		case LESS_THAN_EXPR: return LESS_THAN_EXPR;
		case LESS_THAN_EQUAL_EXPR: return LESS_THAN_EQUAL_EXPR;
		case GREATER_THAN_EXPR: return GREATER_THAN_EXPR;
		case GREATER_THAN_EQUAL_EXPR: return GREATER_THAN_EQUAL_EXPR;
		case SHL_EXPR: return SHL_EXPR;
		case SHR_EXPR: return SHR_EXPR;
		case ADD_EXPR: return ADD_EXPR;
		case SUB_EXPR: return SUB_EXPR;
		case MUL_EXPR: return MUL_EXPR;
		case DIV_EXPR: return DIV_EXPR;
		case MOD_EXPR: return MOD_EXPR;
		default: unreachable("not a binary expression");
	}
}

fn NodeTag unary_tag(NodeKind kind)
{
	switch (kind)
	{
		case COMPOUND_ASSIGN_DUMMY_EXPR: return COMPOUND_ASSIGN_DUMMY_EXPR;
		case ADDR_OF_EXPR: return ADDR_OF_EXPR;
		case DEREF_EXPR: return DEREF_EXPR;
		case PLUS_EXPR: return PLUS_EXPR;
		case NEGATE_EXPR: return NEGATE_EXPR;
		case BIT_NOT_EXPR: return BIT_NOT_EXPR;
		case BOOL_NOT_EXPR: return BOOL_NOT_EXPR;
		case PRE_INC_EXPR: return PRE_INC_EXPR;
		case PRE_DEC_EXPR: return PRE_DEC_EXPR;
		case IMAG_EXPR: return IMAG_EXPR;
		case REAL_EXPR: return REAL_EXPR;
		case POST_INC_EXPR: return POST_INC_EXPR;
		case POST_DEC_EXPR: return POST_DEC_EXPR;
		case PAREN_EXPR: return PAREN_EXPR;
		case STMT_EXPR: return STMT_EXPR;
		case COND_DUMMY_EXPR: return COND_DUMMY_EXPR;
		case IMAGINARY_LITERAL: return IMAGINARY_LITERAL;
		default: unreachable("not a unary expression");
	}
}

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
	uint[3] d = repr.data;
	switch (node.kind)
	{
		case LABELED_STMT: repr.tag = LABELED_STMT; d[0] = (uint)node.labeled_stmt.body; repr.tok = node.labeled_stmt.label_tok;
		case COMPOUND_STMT:
			repr.tok = node.compound_stmt.l_brace_tok;
			if (node.compound_stmt.body.len > 3) { repr.tag = COMPOUND_STMT; ExtraSpan s = self.add_extra(node.compound_stmt.body); d[0] = s.index; d[1] = s.len; }
			else { repr.tag = COMPOUND_STMT_THREE; for (usz i = 0; i < 3; i++) d[i] = pack_elem(node.compound_stmt.body, i); }
		case IF_STMT:
			NodeIfStmt v = node.if_stmt; d[0] = (uint)v.cond; repr.tok = v.if_tok;
			if (!v.init.is_null()) { if (!v.else_body.is_null()) { repr.tag = IF_FULL; d[1] = (uint)v.init; NodeIndex[2] pair; pair[0] = v.then_body; pair[1] = v.else_body.unwrap(); ExtraSpan s = self.add_extra(pair[0:2]); d[2] = s.index; }
			else { repr.tag = IF_INIT; d[1] = (uint)v.init; d[2] = (uint)v.then_body; } }
			else { repr.tag = IF_STMT; d[1] = (uint)v.then_body; d[2] = pack_opt_index(v.else_body); }
		case SWITCH_STMT: repr.tag = SWITCH_STMT; d[0] = (uint)node.switch_stmt.cond; d[1] = pack_opt_index(node.switch_stmt.init); d[2] = (uint)node.switch_stmt.body; repr.tok = node.switch_stmt.switch_tok;
		case CASE_STMT: repr.tag = CASE_STMT; d[0] = (uint)node.case_stmt.start; d[1] = pack_opt_index(node.case_stmt.end); d[2] = (uint)node.case_stmt.body; repr.tok = node.case_stmt.case_tok;
		case DEFAULT_STMT: repr.tag = DEFAULT_STMT; d[0] = (uint)node.default_stmt.body; repr.tok = node.default_stmt.default_tok;
		case WHILE_STMT: repr.tag = WHILE_STMT; d[0] = (uint)node.while_stmt.cond; d[1] = (uint)node.while_stmt.body; repr.tok = node.while_stmt.while_tok;
		case DO_WHILE_STMT: repr.tag = DO_WHILE_STMT; d[0] = (uint)node.do_while_stmt.cond; d[1] = (uint)node.do_while_stmt.body; repr.tok = node.do_while_stmt.do_tok;
		case FOR_STMT:
			NodeForStmt v = node.for_stmt; bool hi = !v.init.is_null(); bool hc = !v.cond.is_null(); bool hn = !v.incr.is_null(); d[2] = (uint)v.body; repr.tok = v.for_tok;
			if (hi && hc && hn) { repr.tag = FOR_FULL; d[0] = (uint)v.init; NodeIndex[2] pair; pair[0] = (NodeIndex)v.cond; pair[1] = (NodeIndex)v.incr; ExtraSpan s = self.add_extra(pair[0:2]); d[1] = s.index; }
			else if (hi && hc) { repr.tag = FOR_INIT_COND; d[0] = (uint)v.init; d[1] = (uint)v.cond; }
			else if (hi && hn) { repr.tag = FOR_INIT_INCR; d[0] = (uint)v.init; d[1] = (uint)v.incr; }
			else if (hc && hn) { repr.tag = FOR_COND_INCR; d[0] = (uint)v.cond; d[1] = (uint)v.incr; }
			else if (hi) { repr.tag = FOR_INIT; d[0] = (uint)v.init; }
			else if (hc) { repr.tag = FOR_COND; d[0] = (uint)v.cond; }
			else if (hn) { repr.tag = FOR_INCR; d[0] = (uint)v.incr; }
			else repr.tag = FOR_EVER;
		case GOTO_STMT: repr.tag = GOTO_STMT; repr.tok = node.goto_stmt.label_tok;
		case COMPUTED_GOTO_STMT: repr.tag = COMPUTED_GOTO_STMT; d[0] = (uint)node.computed_goto_stmt.expr; repr.tok = node.computed_goto_stmt.goto_tok;
		case CONTINUE_STMT: repr.tag = CONTINUE_STMT; d[0] = node.continue_stmt.has_label; d[1] = (uint)node.continue_stmt.label; repr.tok = node.continue_stmt.continue_tok;
		case BREAK_STMT: repr.tag = BREAK_STMT; d[0] = node.break_stmt.has_label; d[1] = (uint)node.break_stmt.label; repr.tok = node.break_stmt.break_tok;
		case NULL_STMT: repr.tag = NULL_STMT; repr.tok = node.null_stmt.semicolon_or_r_brace_tok;
		case RETURN_STMT:
			repr.tok = node.return_stmt.return_tok; d[0] = (uint)node.return_stmt.return_qt;
			switch (node.return_stmt.operand) { case EXPR: repr.tag = RETURN_STMT; d[1] = (uint)node.return_stmt.expr; case NONE: repr.tag = RETURN_NONE_STMT; case IMPLICIT: repr.tag = IMPLICIT_RETURN; d[1] = node.return_stmt.implicit_value; }
		case DECL_STMT:
			repr.tok = node.decl_stmt.first_tok;
			if (node.decl_stmt.decls.len > 3) { repr.tag = DECL_STMT; ExtraSpan s = self.add_extra(node.decl_stmt.decls); d[0] = s.index; d[1] = s.len; }
			else { repr.tag = DECL_STMT_THREE; for (usz i = 0; i < 3; i++) d[i] = pack_elem(node.decl_stmt.decls, i); }
		case ASM_STMT:
			repr.tok = node.asm_stmt.asm_tok; d[0] = (uint)node.asm_stmt.asm_str;
			if (node.asm_stmt.outputs.len == 0 && node.asm_stmt.inputs.len == 0 && node.asm_stmt.clobbers.len == 0 && node.asm_stmt.labels.len == 0)
			{
				repr.tag = ASM_STMT_SIMPLE;
				d[1] = (uint)node.asm_stmt.quals;
			}
			else
			{
				repr.tag = node.asm_stmt.quals.is_inline ? (node.asm_stmt.quals.is_volatile ? ASM_STMT_INLINE_VOLATILE : ASM_STMT_INLINE) : (node.asm_stmt.quals.is_volatile ? ASM_STMT_VOLATILE : ASM_STMT);
				d[1] = (uint)node.asm_stmt.labels.len; d[2] = (uint)self.extra.len();
				self.extra.push((uint)node.asm_stmt.outputs.len); self.extra.push((uint)node.asm_stmt.inputs.len); self.extra.push((uint)node.asm_stmt.clobbers.len);
				foreach (op : node.asm_stmt.outputs) { self.extra.push((uint)op.name); self.extra.push((uint)op.constraint); self.extra.push((uint)op.expr); }
				foreach (op : node.asm_stmt.inputs) { self.extra.push((uint)op.name); self.extra.push((uint)op.constraint); self.extra.push((uint)op.expr); }
				foreach (op : node.asm_stmt.clobbers) self.extra.push((uint)op);
				foreach (label : node.asm_stmt.labels) self.extra.push((uint)label);
			}
		case ASSIGN_EXPR:
		case MUL_ASSIGN_EXPR:
		case DIV_ASSIGN_EXPR:
		case MOD_ASSIGN_EXPR:
		case ADD_ASSIGN_EXPR:
		case SUB_ASSIGN_EXPR:
		case SHL_ASSIGN_EXPR:
		case SHR_ASSIGN_EXPR:
		case BIT_AND_ASSIGN_EXPR:
		case BIT_XOR_ASSIGN_EXPR:
		case BIT_OR_ASSIGN_EXPR:
		case COMMA_EXPR:
		case BOOL_OR_EXPR:
		case BOOL_AND_EXPR:
		case BIT_OR_EXPR:
		case BIT_XOR_EXPR:
		case BIT_AND_EXPR:
		case EQUAL_EXPR:
		case NOT_EQUAL_EXPR:
		case LESS_THAN_EXPR:
		case LESS_THAN_EQUAL_EXPR:
		case GREATER_THAN_EXPR:
		case GREATER_THAN_EQUAL_EXPR:
		case SHL_EXPR:
		case SHR_EXPR:
		case ADD_EXPR:
		case SUB_EXPR:
		case MUL_EXPR:
		case DIV_EXPR:
		case MOD_EXPR:
			repr.tag = binary_tag(node.kind); d[0] = (uint)node.binary.qt; d[1] = (uint)node.binary.lhs; d[2] = (uint)node.binary.rhs; repr.tok = node.binary.op_tok;
		case COMPOUND_ASSIGN_DUMMY_EXPR:
		case ADDR_OF_EXPR:
		case DEREF_EXPR:
		case PLUS_EXPR:
		case NEGATE_EXPR:
		case BIT_NOT_EXPR:
		case BOOL_NOT_EXPR:
		case PRE_INC_EXPR:
		case PRE_DEC_EXPR:
		case IMAG_EXPR:
		case REAL_EXPR:
		case POST_INC_EXPR:
		case POST_DEC_EXPR:
		case PAREN_EXPR:
		case STMT_EXPR:
		case COND_DUMMY_EXPR:
		case IMAGINARY_LITERAL:
			repr.tag = unary_tag(node.kind); d[0] = (uint)node.unary.qt; d[1] = (uint)node.unary.operand; repr.tok = node.unary.op_tok;
		case CAST: repr.tag = node.cast.implicit ? IMPLICIT_CAST : EXPLICIT_CAST; d[0] = (uint)node.cast.qt; d[1] = (uint)node.cast.kind; d[2] = (uint)node.cast.operand; repr.tok = node.cast.l_paren;
		case ADDR_OF_LABEL: repr.tag = ADDR_OF_LABEL; d[0] = (uint)node.addr_of_label.qt; repr.tok = node.addr_of_label.label_tok;
		case ARRAY_ACCESS_EXPR: repr.tag = ARRAY_ACCESS_EXPR; d[0] = (uint)node.array_access.qt; d[1] = (uint)node.array_access.base; d[2] = (uint)node.array_access.index; repr.tok = node.array_access.l_bracket_tok;
		case MEMBER_ACCESS_EXPR:
		case MEMBER_ACCESS_PTR_EXPR: repr.tag = node.kind == MEMBER_ACCESS_EXPR ? MEMBER_ACCESS_EXPR : MEMBER_ACCESS_PTR_EXPR; d[0] = (uint)node.member_access.qt; d[1] = (uint)node.member_access.base; d[2] = node.member_access.member_index; repr.tok = node.member_access.access_tok;
		case DECL_REF_EXPR:
		case ENUMERATION_REF: repr.tag = node.kind == DECL_REF_EXPR ? DECL_REF_EXPR : ENUMERATION_REF; d[0] = (uint)node.decl_ref.qt; d[1] = (uint)node.decl_ref.decl; repr.tok = node.decl_ref.name_tok;
		case BOOL_LITERAL:
		case NULLPTR_LITERAL:
		case INT_LITERAL:
		case FLOAT_LITERAL: repr.tag = node.kind == BOOL_LITERAL ? BOOL_LITERAL : node.kind == NULLPTR_LITERAL ? NULLPTR_LITERAL : node.kind == INT_LITERAL ? INT_LITERAL : FLOAT_LITERAL; d[0] = (uint)node.literal.qt; repr.tok = node.literal.literal_tok;
		case CHAR_LITERAL:
		case STRING_LITERAL_EXPR: repr.tag = node.kind == CHAR_LITERAL ? CHAR_LITERAL : STRING_LITERAL_EXPR; d[0] = (uint)node.char_literal.qt; d[1] = (uint)node.char_literal.kind; repr.tok = node.char_literal.literal_tok;
		case CALL_EXPR:
			d[0] = (uint)node.call.qt; repr.tok = node.call.l_paren_tok;
			if (node.call.args.len > 1) { repr.tag = CALL_EXPR; d[1] = (uint)self.extra.len(); d[2] = (uint)node.call.args.len + 1; self.extra.push((uint)node.call.callee); foreach (arg : node.call.args) self.extra.push((uint)arg); }
			else { repr.tag = CALL_EXPR_ONE; d[1] = (uint)node.call.callee; d[2] = pack_elem(node.call.args, 0); }
		case BUILTIN_CALL_EXPR:
			d[0] = (uint)node.builtin_call.qt; repr.tok = node.builtin_call.builtin_tok;
			if (node.builtin_call.args.len > 2) { repr.tag = BUILTIN_CALL_EXPR; ExtraSpan s = self.add_extra(node.builtin_call.args); d[1] = s.index; d[2] = s.len; }
			else { repr.tag = BUILTIN_CALL_EXPR_TWO; d[1] = pack_elem(node.builtin_call.args, 0); d[2] = pack_elem(node.builtin_call.args, 1); }
		case BUILTIN_TYPES_COMPATIBLE_P: repr.tag = BUILTIN_TYPES_COMPATIBLE_P; d[0] = (uint)node.types_compatible.lhs; d[1] = (uint)node.types_compatible.rhs; repr.tok = node.types_compatible.builtin_tok;
		case BUILTIN_CONVERTVECTOR: repr.tag = BUILTIN_CONVERTVECTOR; d[0] = (uint)node.convertvector.dest_qt; d[1] = (uint)node.convertvector.operand; repr.tok = node.convertvector.builtin_tok;
		case BUILTIN_SHUFFLEVECTOR:
			repr.tag = BUILTIN_SHUFFLEVECTOR; d[0] = (uint)node.shufflevector.qt; d[1] = (uint)self.extra.len(); d[2] = (uint)node.shufflevector.indexes.len; repr.tok = node.shufflevector.builtin_tok;
			self.extra.push((uint)node.shufflevector.lhs); self.extra.push((uint)node.shufflevector.rhs); foreach (idx : node.shufflevector.indexes) self.extra.push((uint)idx);
		case SIZEOF_EXPR:
		case ALIGNOF_EXPR:
		case COUNTOF_EXPR:
			repr.tag = node.kind == SIZEOF_EXPR ? SIZEOF_EXPR : node.kind == ALIGNOF_EXPR ? ALIGNOF_EXPR : COUNTOF_EXPR;
			d[0] = (uint)node.type_info.qt; d[1] = pack_opt_index(node.type_info.expr); d[2] = (uint)node.type_info.operand_qt; repr.tok = node.type_info.op_tok;
		case GENERIC_EXPR:
			d[0] = (uint)node.generic.qt; repr.tok = node.generic.generic_tok;
			if (node.generic.rest.len > 0) { repr.tag = GENERIC_EXPR; d[1] = (uint)self.extra.len(); d[2] = (uint)node.generic.rest.len + 2; self.extra.push((uint)node.generic.controlling); self.extra.push((uint)node.generic.chosen); foreach (item : node.generic.rest) self.extra.push((uint)item); }
			else { repr.tag = GENERIC_EXPR_ZERO; d[1] = (uint)node.generic.controlling; d[2] = (uint)node.generic.chosen; }
		case GENERIC_ASSOCIATION_EXPR: repr.tag = GENERIC_ASSOCIATION_EXPR; d[0] = (uint)node.generic_association.association_qt; d[1] = (uint)node.generic_association.expr; repr.tok = node.generic_association.colon_tok;
		case GENERIC_DEFAULT_EXPR: repr.tag = GENERIC_DEFAULT_EXPR; d[0] = (uint)node.generic_default.expr; repr.tok = node.generic_default.default_tok;
		case BINARY_COND_EXPR:
		case COND_EXPR:
		case BUILTIN_CHOOSE_EXPR:
			repr.tag = node.kind == BINARY_COND_EXPR ? BINARY_COND_EXPR : node.kind == COND_EXPR ? COND_EXPR : BUILTIN_CHOOSE_EXPR;
			d[0] = (uint)node.conditional.qt; d[1] = (uint)node.conditional.cond; repr.tok = node.conditional.cond_tok;
			self.extra.push((uint)node.conditional.then_expr); self.extra.push((uint)node.conditional.else_expr); d[2] = (uint)(self.extra.len() - 2);
		case ARRAY_INIT_EXPR:
		case STRUCT_INIT_EXPR:
			d[0] = (uint)node.container_init.container_qt; repr.tok = node.container_init.l_brace_tok;
			if (node.container_init.items.len > 2) { repr.tag = node.kind == ARRAY_INIT_EXPR ? ARRAY_INIT_EXPR : STRUCT_INIT_EXPR; ExtraSpan s = self.add_extra(node.container_init.items); d[1] = s.index; d[2] = s.len; }
			else { repr.tag = node.kind == ARRAY_INIT_EXPR ? ARRAY_INIT_EXPR_TWO : STRUCT_INIT_EXPR_TWO; d[1] = pack_elem(node.container_init.items, 0); d[2] = pack_elem(node.container_init.items, 1); }
		case UNION_INIT_EXPR: repr.tag = UNION_INIT_EXPR; d[0] = (uint)node.union_init.union_qt; d[1] = node.union_init.field_index; d[2] = pack_opt_index(node.union_init.initializer); repr.tok = node.union_init.l_brace_tok;
		case ARRAY_FILLER_EXPR: repr.tag = ARRAY_FILLER_EXPR; d[0] = (uint)node.array_filler.qt; d[1] = (uint)node.array_filler.count; d[2] = (uint)(node.array_filler.count >> 32); repr.tok = node.array_filler.last_tok;
		case DEFAULT_INIT_EXPR: repr.tag = DEFAULT_INIT_EXPR; d[0] = (uint)node.default_init.qt; repr.tok = node.default_init.last_tok;
		case COMPOUND_LITERAL_EXPR:
			repr.tag = COMPOUND_LITERAL_EXPR; d[0] = (uint)node.compound_literal.qt;
			DeclAttr attr = { .is_static = node.compound_literal.storage_class == CompoundLiteralStorageClass.STATIC, .register = node.compound_literal.storage_class == CompoundLiteralStorageClass.REGISTER, .thread_local = node.compound_literal.thread_local }; d[1] = (uint)attr; d[2] = (uint)node.compound_literal.initializer; repr.tok = node.compound_literal.l_paren_tok;
		case BUILTIN_REF: repr.tag = BUILTIN_REF; d[0] = (uint)node.builtin_ref.qt; repr.tok = node.builtin_ref.name_tok;
		case BUILTIN_VA_ARG_PACK: repr.tag = BUILTIN_VA_ARG_PACK; repr.tok = node.va_arg_pack.builtin_tok;
		case BUILTIN_VA_ARG_PACK_LEN: repr.tag = BUILTIN_VA_ARG_PACK_LEN; repr.tok = node.va_arg_pack.builtin_tok;
		default: unreachable("unsupported expression encoding");
	}
	repr.data = d;
}

<*
 Zig `Node.Index.get` for a STMT/EXPR storage tag (inverse of
 `encode_expr_stmt`). ASM_STMT* quals come from the tag, with
 is_goto = labels.len > 0. Packed forms alias node storage.
 @require index.tag(self).kind.family != DECL
*>
fn Node Tree.decode_expr_stmt(&self, NodeIndex index)
{
	NodeRepr r = self.nodes[(usz)index];
	uint[3] d = r.data;
	switch (r.tag)
	{
		case LABELED_STMT: return { .kind = LABELED_STMT, .labeled_stmt = { .label_tok = r.tok, .body = (NodeIndex)d[0] } };
		case COMPOUND_STMT: return { .kind = COMPOUND_STMT, .compound_stmt = { .l_brace_tok = r.tok, .body = ((NodeIndex*)self.extra.data.ptr)[d[0]:d[0]+d[1]] } };
		case COMPOUND_STMT_THREE: return { .kind = COMPOUND_STMT, .compound_stmt = { .l_brace_tok = r.tok, .body = unpack_elems(d[0:3]) } };
		case IF_STMT: return { .kind = IF_STMT, .if_stmt = { .if_tok = r.tok, .cond = (NodeIndex)d[0], .then_body = (NodeIndex)d[1], .else_body = unpack_opt_index(d[2]) } };
		case IF_INIT: return { .kind = IF_STMT, .if_stmt = { .if_tok = r.tok, .cond = (NodeIndex)d[0], .init = unpack_opt_index(d[1]), .then_body = (NodeIndex)d[2] } };
		case IF_FULL: return { .kind = IF_STMT, .if_stmt = { .if_tok = r.tok, .cond = (NodeIndex)d[0], .init = unpack_opt_index(d[1]), .then_body = (NodeIndex)self.extra[(usz)d[2]], .else_body = (NodeIndex)self.extra[(usz)d[2]+1] } };
		case SWITCH_STMT: return { .kind = SWITCH_STMT, .switch_stmt = { .switch_tok = r.tok, .cond = (NodeIndex)d[0], .init = unpack_opt_index(d[1]), .body = (NodeIndex)d[2] } };
		case CASE_STMT: return { .kind = CASE_STMT, .case_stmt = { .case_tok = r.tok, .start = (NodeIndex)d[0], .end = unpack_opt_index(d[1]), .body = (NodeIndex)d[2] } };
		case DEFAULT_STMT: return { .kind = DEFAULT_STMT, .default_stmt = { .default_tok = r.tok, .body = (NodeIndex)d[0] } };
		case WHILE_STMT: return { .kind = WHILE_STMT, .while_stmt = { .while_tok = r.tok, .cond = (NodeIndex)d[0], .body = (NodeIndex)d[1] } };
		case DO_WHILE_STMT: return { .kind = DO_WHILE_STMT, .do_while_stmt = { .do_tok = r.tok, .cond = (NodeIndex)d[0], .body = (NodeIndex)d[1] } };
		case FOR_FULL: return { .kind = FOR_STMT, .for_stmt = { .for_tok = r.tok, .init = unpack_opt_index(d[0]), .cond = unpack_opt_index(self.extra[(usz)d[1]]), .incr = unpack_opt_index(self.extra[(usz)d[1]+1]), .body = (NodeIndex)d[2] } };
		case FOR_INIT_COND: return { .kind = FOR_STMT, .for_stmt = { .for_tok = r.tok, .init = unpack_opt_index(d[0]), .cond = unpack_opt_index(d[1]), .body = (NodeIndex)d[2] } };
		case FOR_INIT_INCR: return { .kind = FOR_STMT, .for_stmt = { .for_tok = r.tok, .init = unpack_opt_index(d[0]), .incr = unpack_opt_index(d[1]), .body = (NodeIndex)d[2] } };
		case FOR_COND_INCR: return { .kind = FOR_STMT, .for_stmt = { .for_tok = r.tok, .cond = unpack_opt_index(d[0]), .incr = unpack_opt_index(d[1]), .body = (NodeIndex)d[2] } };
		case FOR_INIT: return { .kind = FOR_STMT, .for_stmt = { .for_tok = r.tok, .init = unpack_opt_index(d[0]), .body = (NodeIndex)d[2] } };
		case FOR_COND: return { .kind = FOR_STMT, .for_stmt = { .for_tok = r.tok, .cond = unpack_opt_index(d[0]), .body = (NodeIndex)d[2] } };
		case FOR_INCR: return { .kind = FOR_STMT, .for_stmt = { .for_tok = r.tok, .incr = unpack_opt_index(d[0]), .body = (NodeIndex)d[2] } };
		case FOR_EVER: return { .kind = FOR_STMT, .for_stmt = { .for_tok = r.tok, .body = (NodeIndex)d[2] } };
		case GOTO_STMT: return { .kind = GOTO_STMT, .goto_stmt = { .label_tok = r.tok } };
		case COMPUTED_GOTO_STMT: return { .kind = COMPUTED_GOTO_STMT, .computed_goto_stmt = { .goto_tok = r.tok, .expr = (NodeIndex)d[0] } };
		case CONTINUE_STMT: return { .kind = CONTINUE_STMT, .continue_stmt = { .continue_tok = r.tok, .has_label = d[0] != 0, .label = (tokens::TokenIndex)d[1] } };
		case BREAK_STMT: return { .kind = BREAK_STMT, .break_stmt = { .break_tok = r.tok, .has_label = d[0] != 0, .label = (tokens::TokenIndex)d[1] } };
		case NULL_STMT: return { .kind = NULL_STMT, .null_stmt = { .semicolon_or_r_brace_tok = r.tok } };
		case RETURN_STMT: return { .kind = RETURN_STMT, .return_stmt = { .return_tok = r.tok, .return_qt = (QualType)d[0], .operand = EXPR, .expr = (NodeIndex)d[1] } };
		case RETURN_NONE_STMT: return { .kind = RETURN_STMT, .return_stmt = { .return_tok = r.tok, .return_qt = (QualType)d[0], .operand = NONE } };
		case IMPLICIT_RETURN: return { .kind = RETURN_STMT, .return_stmt = { .return_tok = r.tok, .return_qt = (QualType)d[0], .operand = IMPLICIT, .implicit_value = d[1] != 0 } };
		case DECL_STMT: return { .kind = DECL_STMT, .decl_stmt = { .first_tok = r.tok, .decls = ((NodeIndex*)self.extra.data.ptr)[d[0]:d[0]+d[1]] } };
		case DECL_STMT_THREE: return { .kind = DECL_STMT, .decl_stmt = { .first_tok = r.tok, .decls = unpack_elems(d[0:3]) } };
		case CALL_EXPR_ONE: return { .kind = CALL_EXPR, .call = { .l_paren_tok = r.tok, .qt = (QualType)d[0], .callee = (NodeIndex)d[1], .args = unpack_elems(d[2:3]) } };
		case CALL_EXPR: return { .kind = CALL_EXPR, .call = { .l_paren_tok = r.tok, .qt = (QualType)d[0], .callee = (NodeIndex)self.extra[(usz)d[1]], .args = ((NodeIndex*)self.extra.data.ptr)[(usz)d[1]+1:(usz)d[1]+d[2]] } };
		case BUILTIN_CALL_EXPR_TWO: return { .kind = BUILTIN_CALL_EXPR, .builtin_call = { .builtin_tok = r.tok, .qt = (QualType)d[0], .args = unpack_elems(d[1:3]) } };
		case BUILTIN_CALL_EXPR: return { .kind = BUILTIN_CALL_EXPR, .builtin_call = { .builtin_tok = r.tok, .qt = (QualType)d[0], .args = ((NodeIndex*)self.extra.data.ptr)[d[1]:d[1]+d[2]] } };
		case BUILTIN_TYPES_COMPATIBLE_P: return { .kind = BUILTIN_TYPES_COMPATIBLE_P, .types_compatible = { .builtin_tok = r.tok, .lhs = (QualType)d[0], .rhs = (QualType)d[1] } };
		case BUILTIN_CONVERTVECTOR: return { .kind = BUILTIN_CONVERTVECTOR, .convertvector = { .builtin_tok = r.tok, .dest_qt = (QualType)d[0], .operand = (NodeIndex)d[1] } };
		case BUILTIN_SHUFFLEVECTOR: return { .kind = BUILTIN_SHUFFLEVECTOR, .shufflevector = { .builtin_tok = r.tok, .qt = (QualType)d[0], .lhs = (NodeIndex)self.extra[(usz)d[1]], .rhs = (NodeIndex)self.extra[(usz)d[1]+1], .indexes = ((NodeIndex*)self.extra.data.ptr)[(usz)d[1]+2:(usz)d[1]+2+d[2]] } };
		case BUILTIN_REF: return { .kind = BUILTIN_REF, .builtin_ref = { .name_tok = r.tok, .qt = (QualType)d[0] } };
		case BUILTIN_VA_ARG_PACK: return { .kind = BUILTIN_VA_ARG_PACK, .va_arg_pack = { .builtin_tok = r.tok } };
		case BUILTIN_VA_ARG_PACK_LEN: return { .kind = BUILTIN_VA_ARG_PACK_LEN, .va_arg_pack = { .builtin_tok = r.tok } };
		case BOOL_LITERAL:
		case NULLPTR_LITERAL:
		case INT_LITERAL:
		case FLOAT_LITERAL: return { .kind = r.tag.kind, .literal = { .literal_tok = r.tok, .qt = (QualType)d[0] } };
		case CHAR_LITERAL:
		case STRING_LITERAL_EXPR: return { .kind = r.tag.kind, .char_literal = { .literal_tok = r.tok, .qt = (QualType)d[0], .kind = (CharLiteralKind)d[1] } };
		case SIZEOF_EXPR:
		case ALIGNOF_EXPR:
		case COUNTOF_EXPR: return { .kind = r.tag.kind, .type_info = { .qt = (QualType)d[0], .op_tok = r.tok, .expr = unpack_opt_index(d[1]), .operand_qt = (QualType)d[2] } };
		case GENERIC_EXPR: return { .kind = GENERIC_EXPR, .generic = { .generic_tok = r.tok, .qt = (QualType)d[0], .controlling = (NodeIndex)self.extra[(usz)d[1]], .chosen = (NodeIndex)self.extra[(usz)d[1]+1], .rest = ((NodeIndex*)self.extra.data.ptr)[(usz)d[1]+2:(usz)d[1]+d[2]] } };
		case GENERIC_EXPR_ZERO: return { .kind = GENERIC_EXPR, .generic = { .generic_tok = r.tok, .qt = (QualType)d[0], .controlling = (NodeIndex)d[1], .chosen = (NodeIndex)d[2] } };
		case GENERIC_ASSOCIATION_EXPR: return { .kind = GENERIC_ASSOCIATION_EXPR, .generic_association = { .colon_tok = r.tok, .association_qt = (QualType)d[0], .expr = (NodeIndex)d[1] } };
		case GENERIC_DEFAULT_EXPR: return { .kind = GENERIC_DEFAULT_EXPR, .generic_default = { .default_tok = r.tok, .expr = (NodeIndex)d[0] } };
		case BINARY_COND_EXPR:
		case COND_EXPR:
		case BUILTIN_CHOOSE_EXPR: return { .kind = r.tag.kind, .conditional = { .cond_tok = r.tok, .qt = (QualType)d[0], .cond = (NodeIndex)d[1], .then_expr = (NodeIndex)self.extra[(usz)d[2]], .else_expr = (NodeIndex)self.extra[(usz)d[2]+1] } };
		case ARRAY_INIT_EXPR_TWO:
		case STRUCT_INIT_EXPR_TWO: return { .kind = r.tag.kind, .container_init = { .l_brace_tok = r.tok, .container_qt = (QualType)d[0], .items = unpack_elems(d[1:3]) } };
		case ARRAY_INIT_EXPR:
		case STRUCT_INIT_EXPR: return { .kind = r.tag.kind, .container_init = { .l_brace_tok = r.tok, .container_qt = (QualType)d[0], .items = ((NodeIndex*)self.extra.data.ptr)[d[1]:d[1]+d[2]] } };
		case UNION_INIT_EXPR: return { .kind = UNION_INIT_EXPR, .union_init = { .l_brace_tok = r.tok, .union_qt = (QualType)d[0], .field_index = d[1], .initializer = unpack_opt_index(d[2]) } };
		case ARRAY_FILLER_EXPR: return { .kind = ARRAY_FILLER_EXPR, .array_filler = { .last_tok = r.tok, .qt = (QualType)d[0], .count = ((ulong)d[2] << 32) | d[1] } };
		case DEFAULT_INIT_EXPR: return { .kind = DEFAULT_INIT_EXPR, .default_init = { .last_tok = r.tok, .qt = (QualType)d[0] } };
		case COMPOUND_LITERAL_EXPR:
			DeclAttr attr = (DeclAttr)d[1];
			CompoundLiteralStorageClass storage = attr.is_static ? CompoundLiteralStorageClass.STATIC : attr.register ? CompoundLiteralStorageClass.REGISTER : CompoundLiteralStorageClass.AUTO;
			return { .kind = COMPOUND_LITERAL_EXPR, .compound_literal = { .l_paren_tok = r.tok, .qt = (QualType)d[0], .thread_local = attr.thread_local, .storage_class = storage, .initializer = (NodeIndex)d[2] } };
		case ASM_STMT:
		case ASM_STMT_INLINE:
		case ASM_STMT_VOLATILE:
		case ASM_STMT_INLINE_VOLATILE:
			uint start = d[2]; uint out_len = self.extra[(usz)start]; uint in_len = self.extra[(usz)start+1]; uint clobber_len = self.extra[(usz)start+2];
			uint out_start = start + 3; uint in_start = out_start + out_len * 3; uint clobber_start = in_start + in_len * 3; uint label_start = clobber_start + clobber_len;
			NodeIndex[] clobbers = ((NodeIndex*)self.extra.data.ptr)[clobber_start:label_start];
			NodeIndex[] labels = ((NodeIndex*)self.extra.data.ptr)[label_start:label_start+d[1]];
			GnuAsmQualifiers aq = { .is_inline = r.tag == ASM_STMT_INLINE || r.tag == ASM_STMT_INLINE_VOLATILE, .is_volatile = r.tag == ASM_STMT_VOLATILE || r.tag == ASM_STMT_INLINE_VOLATILE, .is_goto = d[1] > 0 };
			return { .kind = ASM_STMT, .asm_stmt = { .asm_tok = r.tok, .asm_str = (NodeIndex)d[0], .outputs = ((AsmOperand*)self.extra.data.ptr)[out_start:in_start], .inputs = ((AsmOperand*)self.extra.data.ptr)[in_start:clobber_start], .clobbers = clobbers, .labels = labels, .quals = aq } };
		case ASM_STMT_SIMPLE:
			GnuAsmQualifiers simple_q = (GnuAsmQualifiers)d[1];
			return { .kind = ASM_STMT, .asm_stmt = { .asm_tok = r.tok, .asm_str = (NodeIndex)d[0], .quals = simple_q } };
		case COMMA_EXPR:
		case ASSIGN_EXPR:
		case MUL_ASSIGN_EXPR:
		case DIV_ASSIGN_EXPR:
		case MOD_ASSIGN_EXPR:
		case ADD_ASSIGN_EXPR:
		case SUB_ASSIGN_EXPR:
		case SHL_ASSIGN_EXPR:
		case SHR_ASSIGN_EXPR:
		case BIT_AND_ASSIGN_EXPR:
		case BIT_XOR_ASSIGN_EXPR:
		case BIT_OR_ASSIGN_EXPR:
		case BOOL_OR_EXPR:
		case BOOL_AND_EXPR:
		case BIT_OR_EXPR:
		case BIT_XOR_EXPR:
		case BIT_AND_EXPR:
		case EQUAL_EXPR:
		case NOT_EQUAL_EXPR:
		case LESS_THAN_EXPR:
		case LESS_THAN_EQUAL_EXPR:
		case GREATER_THAN_EXPR:
		case GREATER_THAN_EQUAL_EXPR:
		case SHL_EXPR:
		case SHR_EXPR:
		case ADD_EXPR:
		case SUB_EXPR:
		case MUL_EXPR:
		case DIV_EXPR:
		case MOD_EXPR: return { .kind = r.tag.kind, .binary = { .qt = (QualType)d[0], .lhs = (NodeIndex)d[1], .op_tok = r.tok, .rhs = (NodeIndex)d[2] } };
		case COMPOUND_ASSIGN_DUMMY_EXPR:
		case ADDR_OF_EXPR:
		case DEREF_EXPR:
		case PLUS_EXPR:
		case NEGATE_EXPR:
		case BIT_NOT_EXPR:
		case BOOL_NOT_EXPR:
		case PRE_INC_EXPR:
		case PRE_DEC_EXPR:
		case IMAG_EXPR:
		case REAL_EXPR:
		case POST_INC_EXPR:
		case POST_DEC_EXPR:
		case PAREN_EXPR:
		case STMT_EXPR:
		case COND_DUMMY_EXPR:
		case IMAGINARY_LITERAL: return { .kind = r.tag.kind, .unary = { .qt = (QualType)d[0], .op_tok = r.tok, .operand = (NodeIndex)d[1] } };
		case EXPLICIT_CAST:
		case IMPLICIT_CAST: return { .kind = CAST, .cast = { .qt = (QualType)d[0], .l_paren = r.tok, .kind = (CastKind)d[1], .operand = (NodeIndex)d[2], .implicit = r.tag == IMPLICIT_CAST } };
		case ADDR_OF_LABEL: return { .kind = ADDR_OF_LABEL, .addr_of_label = { .label_tok = r.tok, .qt = (QualType)d[0] } };
		case ARRAY_ACCESS_EXPR: return { .kind = ARRAY_ACCESS_EXPR, .array_access = { .l_bracket_tok = r.tok, .qt = (QualType)d[0], .base = (NodeIndex)d[1], .index = (NodeIndex)d[2] } };
		case MEMBER_ACCESS_EXPR: return { .kind = MEMBER_ACCESS_EXPR, .member_access = { .qt = (QualType)d[0], .base = (NodeIndex)d[1], .access_tok = r.tok, .member_index = d[2] } };
		case MEMBER_ACCESS_PTR_EXPR: return { .kind = MEMBER_ACCESS_PTR_EXPR, .member_access = { .qt = (QualType)d[0], .base = (NodeIndex)d[1], .access_tok = r.tok, .member_index = d[2] } };
		case DECL_REF_EXPR: return { .kind = DECL_REF_EXPR, .decl_ref = { .name_tok = r.tok, .qt = (QualType)d[0], .decl = (NodeIndex)d[1] } };
		case ENUMERATION_REF: return { .kind = ENUMERATION_REF, .decl_ref = { .name_tok = r.tok, .qt = (QualType)d[0], .decl = (NodeIndex)d[1] } };
		default: unreachable("expression decoding not implemented");
	}
}

<*
 Zig `MemberAccess.isBitFieldWidth`: the bit width of the accessed record
 field, looking through one pointer level of `base`'s type. NOT_BITFIELD
 when the base type is invalid, not a struct/union, or the field has no
 bit width.
*>
fn uint? NodeMemberAccess.is_bit_field_width(self, Tree* tree)
{
	QualType qt = self.base.qt(tree);
	if (try ptr = qt.get(tree.comp, POINTER)) qt = ptr.pointer.child;
	if (try record_ty = qt.get_record(tree.comp))
	{
		uint width = record_ty.fields[self.member_index].bit_width;
		if (width != type_store::BIT_WIDTH_NULL) return width;
	}
	return NOT_BITFIELD~;
}

<* Zig `isBitfield`: `bitfield_width(node, false)` succeeds. *>
fn bool Tree.is_bitfield(&self, NodeIndex node)
{
	return @ok(self.bitfield_width(node, false));
}

<*
 Zig `bitfieldWidth`: MEMBER_ACCESS(_PTR)_EXPR -> is_bit_field_width; a
 CAST with kind LVAL_TO_RVAL recurses into its operand (inspect_lval
 false) only when `inspect_lval`; anything else NOT_BITFIELD.
*>
fn uint? Tree.bitfield_width(&self, NodeIndex node, bool inspect_lval)
{
	Node n = node.get(self);
	switch (n.kind)
	{
		case MEMBER_ACCESS_EXPR:
		case MEMBER_ACCESS_PTR_EXPR: return n.member_access.is_bit_field_width(self);
		case CAST:
			if (!inspect_lval || n.cast.kind != LVAL_TO_RVAL) return NOT_BITFIELD~;
			return self.bitfield_width(n.cast.operand, false);
		default: return NOT_BITFIELD~;
	}
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
	Node n = node.get(self);
	switch (n.kind)
	{
		case DECL_REF_EXPR:
			Attribute? attr = self.attr_map.get_attribute(n.decl_ref.decl.pack(), tag);
			if (!attr)
			{
				QualType base_qt = n.decl_ref.qt;
				if (try ptr = base_qt.get(self.comp, POINTER)) base_qt = ptr.pointer.child;
				if (try function_type = base_qt.get(self.comp, FUNC)) attr = function_type.func.return_type.get_attribute(self, tag);
			}
			return { .tok = n.decl_ref.name_tok, .has_attr = @ok(attr), .attr = attr ?? Attribute{} };
		case PAREN_EXPR:
		case ADDR_OF_EXPR:
		case DEREF_EXPR: return self.called_function_attr(n.unary.operand, tag);
		case COMMA_EXPR: return self.called_function_attr(n.binary.rhs, tag);
		case CAST: return self.called_function_attr(n.cast.operand, tag);
		case CALL_EXPR: return self.called_function_attr(n.call.callee, tag);
		case MEMBER_ACCESS_EXPR:
		case MEMBER_ACCESS_PTR_EXPR:
			QualType qt = n.member_access.base.qt(self);
			if (try ptr = qt.get(self.comp, POINTER)) qt = ptr.pointer.child;
			if (try rec = qt.get_record(self.comp))
			{
				RecordField field = rec.fields[n.member_access.member_index];
				Attribute? field_attr = self.attr_map.get_attribute(field.field_decl, tag);
				if (!field_attr)
				{
					QualType field_qt = field.qt;
					if (try ptr = field_qt.get(self.comp, POINTER)) field_qt = ptr.pointer.child;
					if (try function_type = field_qt.get(self.comp, FUNC)) field_attr = function_type.func.return_type.get_attribute(self, tag);
				}
				return { .tok = field.name_tok, .has_attr = @ok(field_attr), .attr = field_attr ?? Attribute{} };
			}
			return NO_CALLED_FUNCTION~;
		default: return NO_CALLED_FUNCTION~;
	}
}

<* Zig `isLval`. *>
fn bool Tree.is_lval(&self, NodeIndex node)
{
	bool is_const;
	return self.is_lval_extra(node, &is_const);
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
	*is_const = false;
	Node n = node.get(self);
	switch (n.kind)
	{
		case COMPOUND_LITERAL_EXPR: *is_const = n.compound_literal.qt.is_const; return true;
		case STRING_LITERAL_EXPR: return true;
		case MEMBER_ACCESS_PTR_EXPR:
			QualType base_qt = n.member_access.base.qt(self);
			if (try ptr = base_qt.get(self.comp, POINTER)) *is_const = ptr.pointer.child.is_const;
			return true;
		case MEMBER_ACCESS_EXPR: return self.is_lval_extra(n.member_access.base, is_const);
		case ARRAY_ACCESS_EXPR:
			QualType array_qt = n.array_access.base.qt(self);
			if (try ptr = array_qt.get(self.comp, POINTER)) *is_const = ptr.pointer.child.is_const;
			return true;
		case DECL_REF_EXPR: *is_const = n.decl_ref.qt.is_const; return true;
		case DEREF_EXPR:
			QualType operand_qt = n.unary.operand.qt(self);
			if (operand_qt.is_invalid()) return true;
			BaseType b = operand_qt.base(self.comp);
			if (b.ty.tag == FUNC) return false;
			if (b.ty.tag == POINTER) *is_const = b.ty.pointer.child.is_const;
			return true;
		case PAREN_EXPR: return self.is_lval_extra(n.unary.operand, is_const);
		case BUILTIN_CHOOSE_EXPR:
			if (try val = self.value_of(n.conditional.cond))
			{
				if (!val.is_zero(self.comp)) return self.is_lval_extra(n.conditional.then_expr, is_const);
				return self.is_lval_extra(n.conditional.else_expr, is_const);
			}
			return false;
		case COMPOUND_ASSIGN_DUMMY_EXPR: return true;
		default: return false;
	}
}
