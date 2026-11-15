// Port of the expression and statement node families of src/aro/Tree.zig
// (`setNode` / `Node.Index.get` arms) plus the lvalue and bitfield queries
// (`isBitfield`, `bitfieldWidth`, `MemberAccess.isBitFieldWidth`,
// `calledFunctionAttr`, `isLval`, `isLvalExtra`) — plan 16 stage 1 agent
// 16.3 `expr-stmt-nodes`. Part of module aro::tree (see tree.c3).
//
// Families handled here: `NodeKind.family == STMT` (LABELED_STMT ..
// DECL_STMT) and `== EXPR` (every other expression kind).
// Storage forms and data layouts: docs/c3-tree-tags.md section 2.
//
// Compact node storage and lvalue/attribute queries follow Tree.zig.
module aro::tree;
import aro::tokens, aro::type_store, aro::attribute, aro::attribute_map, aro::compilation, aro::value;


fn AsmOperand[] asm_operands(uint[] words, uint start, uint count)
{
	AsmOperand* first = (AsmOperand*)(words.ptr + (usz)start);
	return first[0:(usz)count];
}

<*
 Zig `setNode` for a STMT- or EXPR-family node. `repr.kind = node.kind`;
 the `NodeData` view is named per arm. Compact-form choices (`repr.form`
 bits, Zig tag in parentheses):
  - COMPOUND_STMT / DECL_STMT: len > 3 -> `span` over extra; else packed
    (*_three) with pack_elem 0..2 in `elems`.
  - IF_STMT: no init -> `if_stmt` (else may be null); has_init -> `if_init`
    with then_body, or (has_else, if_full) extra start of [then, else].
  - FOR_STMT: has_init/has_cond/has_incr record the present clauses; all
    three (for_full) store [init, extra start of [cond, incr]], otherwise the
    present clauses fill `clauses` in init, cond, incr order.
  - RETURN_STMT: EXPR -> no bits, NONE -> return_none, IMPLICIT -> implicit
    (`value` = implicit_value).
  - ASM_STMT: no operands/clobbers/labels -> packed (quals bits); else
    asm_inline/asm_volatile from quals, labels.len and extra start of
    [outputs.len, inputs.len, clobbers.len, outputs (3 words each), inputs,
    clobbers, labels].
  - CAST: implicit = cast.implicit.
  - CALL_EXPR: args.len > 1 -> `extra_list` [callee, args...] (len = args + 1);
    else packed `call_one`.
  - BUILTIN_CALL_EXPR / ARRAY_INIT_EXPR / STRUCT_INIT_EXPR: len > 2 ->
    `typed_span`; else packed `typed_list` (*_two).
  - GENERIC_EXPR: rest.len > 0 -> `extra_list` [controlling, chosen, rest...]
    (len = rest + 2); else packed `generic_zero`.
  - BINARY_COND/COND/BUILTIN_CHOOSE_EXPR: `conditional`, extra [then, else].
  - BUILTIN_SHUFFLEVECTOR: extra [lhs, rhs, indexes...].
 @require node.kind.family != DECL
*>
fn void Tree.encode_expr_stmt(&self, Node node, NodeRepr* repr)
{
	repr.kind = node.kind;
	NodeData* data = &repr.data;
	switch (node.kind)
	{
		case LABELED_STMT:
			repr.tok = node.labeled_stmt.label_tok;
			data.body.body = node.labeled_stmt.body;
		case COMPOUND_STMT:
			repr.tok = node.compound_stmt.l_brace_tok;
			self.encode_node_list(repr, node.compound_stmt.body);
		case IF_STMT:
			NodeIfStmt v = node.if_stmt;
			repr.tok = v.if_tok;
			repr.form.has_init = !v.init.is_null();
			repr.form.has_else = repr.form.has_init && !v.else_body.is_null();
			if (!repr.form.has_init)
			{
				data.if_stmt = { .cond = v.cond, .then_body = v.then_body, .else_body = v.else_body };
			}
			else if (repr.form.has_else)
			{
				NodeIndex[2] pair = { v.then_body, v.else_body.unwrap() };
				data.if_init = { .cond = v.cond, .init = v.init, .then_or_extra = self.add_extra(pair[..]).index };
			}
			else
			{
				data.if_init = { .cond = v.cond, .init = v.init, .then_or_extra = (uint)v.then_body };
			}
		case SWITCH_STMT:
			repr.tok = node.switch_stmt.switch_tok;
			data.switch_stmt = { .cond = node.switch_stmt.cond, .init = node.switch_stmt.init, .body = node.switch_stmt.body };
		case CASE_STMT:
			repr.tok = node.case_stmt.case_tok;
			data.case_stmt = { .start = node.case_stmt.start, .end = node.case_stmt.end, .body = node.case_stmt.body };
		case DEFAULT_STMT:
			repr.tok = node.default_stmt.default_tok;
			data.body.body = node.default_stmt.body;
		case WHILE_STMT:
			repr.tok = node.while_stmt.while_tok;
			data.loop = { .cond = node.while_stmt.cond, .body = node.while_stmt.body };
		case DO_WHILE_STMT:
			repr.tok = node.do_while_stmt.do_tok;
			data.loop = { .cond = node.do_while_stmt.cond, .body = node.do_while_stmt.body };
		case FOR_STMT:
			NodeForStmt v = node.for_stmt;
			repr.tok = v.for_tok;
			repr.form.has_init = !v.init.is_null(); repr.form.has_cond = !v.cond.is_null(); repr.form.has_incr = !v.incr.is_null();
			data.for_stmt.body = v.body;
			if (repr.form.has_init && repr.form.has_cond && repr.form.has_incr)
			{
				NodeIndex[2] pair = { v.cond.unwrap(), v.incr.unwrap() };
				data.for_stmt.clauses = { (uint)v.init, self.add_extra(pair[..]).index };
			}
			else
			{
				usz slot = 0;
				foreach (clause : (NodeOptIndex[3]){ v.init, v.cond, v.incr })
				{
					if (!clause.is_null()) data.for_stmt.clauses[slot++] = (uint)clause;
				}
			}
		case GOTO_STMT: repr.tok = node.goto_stmt.label_tok;
		case COMPUTED_GOTO_STMT:
			repr.tok = node.computed_goto_stmt.goto_tok;
			data.expr.expr = node.computed_goto_stmt.expr;
		case CONTINUE_STMT:
			repr.tok = node.continue_stmt.continue_tok;
			data.jump = { .has_label = (uint)node.continue_stmt.has_label, .label = node.continue_stmt.label };
		case BREAK_STMT:
			repr.tok = node.break_stmt.break_tok;
			data.jump = { .has_label = (uint)node.break_stmt.has_label, .label = node.break_stmt.label };
		case NULL_STMT: repr.tok = node.null_stmt.semicolon_or_r_brace_tok;
		case RETURN_STMT:
			NodeReturnStmt v = node.return_stmt;
			repr.tok = v.return_tok;
			data.return_stmt.qt = v.return_qt;
			switch (v.operand)
			{
				case EXPR: data.return_stmt.value = (uint)v.expr;
				case NONE: repr.form.return_none = true;
				case IMPLICIT: repr.form.implicit = true; data.return_stmt.value = (uint)v.implicit_value;
			}
		case DECL_STMT:
			repr.tok = node.decl_stmt.first_tok;
			self.encode_node_list(repr, node.decl_stmt.decls);
		case ASM_STMT:
			NodeAsmStmt v = node.asm_stmt;
			repr.tok = v.asm_tok;
			data.asm_stmt.asm_str = v.asm_str;
			if (v.outputs.len == 0 && v.inputs.len == 0 && v.clobbers.len == 0 && v.labels.len == 0)
			{
				repr.form.packed = true;
				data.asm_stmt.quals_or_labels = (uint)v.quals;
				break;
			}
			repr.form.asm_inline = v.quals.is_inline; repr.form.asm_volatile = v.quals.is_volatile;
			data.asm_stmt.quals_or_labels = (uint)v.labels.len;
			data.asm_stmt.extra = (uint)self.extra.len();
			self.extra.push((uint)v.outputs.len); self.extra.push((uint)v.inputs.len); self.extra.push((uint)v.clobbers.len);
			foreach (op : v.outputs) { self.extra.push((uint)op.name); self.extra.push((uint)op.constraint); self.extra.push((uint)op.expr); }
			foreach (op : v.inputs) { self.extra.push((uint)op.name); self.extra.push((uint)op.constraint); self.extra.push((uint)op.expr); }
			foreach (op : v.clobbers) self.extra.push((uint)op);
			foreach (label : v.labels) self.extra.push((uint)label);
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
			repr.tok = node.binary.op_tok;
			data.binary = { .qt = node.binary.qt, .lhs = node.binary.lhs, .rhs = node.binary.rhs };
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
			repr.tok = node.unary.op_tok;
			data.unary = { .qt = node.unary.qt, .operand = node.unary.operand };
		case CAST:
			repr.tok = node.cast.l_paren;
			repr.form.implicit = node.cast.implicit;
			data.cast = { .qt = node.cast.qt, .kind = (uint)node.cast.kind, .operand = node.cast.operand };
		case ADDR_OF_LABEL:
			repr.tok = node.addr_of_label.label_tok;
			data.typed.qt = node.addr_of_label.qt;
		case ARRAY_ACCESS_EXPR:
			repr.tok = node.array_access.l_bracket_tok;
			data.array_access = { .qt = node.array_access.qt, .base = node.array_access.base, .index = node.array_access.index };
		case MEMBER_ACCESS_EXPR:
		case MEMBER_ACCESS_PTR_EXPR:
			repr.tok = node.member_access.access_tok;
			data.member_access = { .qt = node.member_access.qt, .base = node.member_access.base, .member_index = node.member_access.member_index };
		case DECL_REF_EXPR:
		case ENUMERATION_REF:
			repr.tok = node.decl_ref.name_tok;
			data.decl_ref = { .qt = node.decl_ref.qt, .decl = node.decl_ref.decl };
		case BOOL_LITERAL:
		case NULLPTR_LITERAL:
		case INT_LITERAL:
		case FLOAT_LITERAL:
			repr.tok = node.literal.literal_tok;
			data.typed.qt = node.literal.qt;
		case CHAR_LITERAL:
		case STRING_LITERAL_EXPR:
			repr.tok = node.char_literal.literal_tok;
			data.char_literal = { .qt = node.char_literal.qt, .kind = (uint)node.char_literal.kind };
		case CALL_EXPR:
			NodeCall v = node.call;
			repr.tok = v.l_paren_tok;
			if (v.args.len > 1)
			{
				data.extra_list = { .qt = v.qt, .start = (uint)self.extra.len(), .len = (uint)v.args.len + 1 };
				self.extra.push((uint)v.callee);
				foreach (arg : v.args) self.extra.push((uint)arg);
			}
			else
			{
				repr.form.packed = true;
				data.call_one = { .qt = v.qt, .callee = v.callee, .arg = (NodeOptIndex)pack_elem(v.args, 0) };
			}
		case BUILTIN_CALL_EXPR:
			repr.tok = node.builtin_call.builtin_tok;
			self.encode_typed_list(repr, node.builtin_call.qt, node.builtin_call.args);
		case BUILTIN_TYPES_COMPATIBLE_P:
			repr.tok = node.types_compatible.builtin_tok;
			data.types_compatible = { .lhs = node.types_compatible.lhs, .rhs = node.types_compatible.rhs };
		case BUILTIN_CONVERTVECTOR:
			repr.tok = node.convertvector.builtin_tok;
			data.convertvector = { .dest_qt = node.convertvector.dest_qt, .operand = node.convertvector.operand };
		case BUILTIN_SHUFFLEVECTOR:
			NodeShufflevector v = node.shufflevector;
			repr.tok = v.builtin_tok;
			data.shufflevector = { .qt = v.qt, .start = (uint)self.extra.len(), .index_count = (uint)v.indexes.len };
			self.extra.push((uint)v.lhs); self.extra.push((uint)v.rhs);
			foreach (idx : v.indexes) self.extra.push((uint)idx);
		case SIZEOF_EXPR:
		case ALIGNOF_EXPR:
		case COUNTOF_EXPR:
			repr.tok = node.type_info.op_tok;
			data.type_info = { .qt = node.type_info.qt, .expr = node.type_info.expr, .operand_qt = node.type_info.operand_qt };
		case GENERIC_EXPR:
			NodeGeneric v = node.generic;
			repr.tok = v.generic_tok;
			if (v.rest.len > 0)
			{
				data.extra_list = { .qt = v.qt, .start = (uint)self.extra.len(), .len = (uint)v.rest.len + 2 };
				self.extra.push((uint)v.controlling); self.extra.push((uint)v.chosen);
				foreach (item : v.rest) self.extra.push((uint)item);
			}
			else
			{
				repr.form.packed = true;
				data.generic_zero = { .qt = v.qt, .controlling = v.controlling, .chosen = v.chosen };
			}
		case GENERIC_ASSOCIATION_EXPR:
			repr.tok = node.generic_association.colon_tok;
			data.generic_association = { .qt = node.generic_association.association_qt, .expr = node.generic_association.expr };
		case GENERIC_DEFAULT_EXPR:
			repr.tok = node.generic_default.default_tok;
			data.expr.expr = node.generic_default.expr;
		case BINARY_COND_EXPR:
		case COND_EXPR:
		case BUILTIN_CHOOSE_EXPR:
			repr.tok = node.conditional.cond_tok;
			NodeIndex[2] pair = { node.conditional.then_expr, node.conditional.else_expr };
			data.conditional = { .qt = node.conditional.qt, .cond = node.conditional.cond, .extra = self.add_extra(pair[..]).index };
		case ARRAY_INIT_EXPR:
		case STRUCT_INIT_EXPR:
			repr.tok = node.container_init.l_brace_tok;
			self.encode_typed_list(repr, node.container_init.container_qt, node.container_init.items);
		case UNION_INIT_EXPR:
			repr.tok = node.union_init.l_brace_tok;
			data.union_init = { .qt = node.union_init.union_qt, .field_index = node.union_init.field_index, .initializer = node.union_init.initializer };
		case ARRAY_FILLER_EXPR:
			repr.tok = node.array_filler.last_tok;
			data.array_filler = { .qt = node.array_filler.qt, .count_lo = (uint)node.array_filler.count, .count_hi = (uint)(node.array_filler.count >> 32) };
		case DEFAULT_INIT_EXPR:
			repr.tok = node.default_init.last_tok;
			data.typed.qt = node.default_init.qt;
		case COMPOUND_LITERAL_EXPR:
			NodeCompoundLiteral v = node.compound_literal;
			repr.tok = v.l_paren_tok;
			data.compound_literal = { .qt = v.qt, .initializer = v.initializer,
				.attr = { .is_static = v.storage_class == CompoundLiteralStorageClass.STATIC,
					.register = v.storage_class == CompoundLiteralStorageClass.REGISTER, .thread_local = v.thread_local } };
		case BUILTIN_REF:
			repr.tok = node.builtin_ref.name_tok;
			data.typed.qt = node.builtin_ref.qt;
		case BUILTIN_VA_ARG_PACK:
		case BUILTIN_VA_ARG_PACK_LEN: repr.tok = node.va_arg_pack.builtin_tok;
		default: unreachable("unsupported expression encoding");
	}
}

<* COMPOUND_STMT / DECL_STMT list: `span` over extra when longer than 3, else packed `elems`. *>
fn void Tree.encode_node_list(&self, NodeRepr* repr, NodeIndex[] items)
{
	if (items.len > 3)
	{
		ExtraSpan s = self.add_extra(items);
		repr.data.span = { .start = s.index, .len = s.len };
		return;
	}
	repr.form.packed = true;
	for (usz i = 0; i < 3; i++) repr.data.elems[i] = (NodeIndex)pack_elem(items, i);
}

<* BUILTIN_CALL / ARRAY_INIT / STRUCT_INIT list: `typed_span` when longer than 2, else packed `typed_list`. *>
fn void Tree.encode_typed_list(&self, NodeRepr* repr, QualType qt, NodeIndex[] items)
{
	if (items.len > 2)
	{
		ExtraSpan s = self.add_extra(items);
		repr.data.typed_span = { .qt = qt, .start = s.index, .len = s.len };
		return;
	}
	repr.form.packed = true;
	repr.data.typed_list = { .qt = qt, .elems = { (NodeIndex)pack_elem(items, 0), (NodeIndex)pack_elem(items, 1) } };
}

<* Decode an `encode_node_list` list (packed slices alias node storage). *>
fn NodeIndex[] Tree.decode_node_list(&self, NodeRepr* repr)
	=> repr.form.packed ? unpack_node_elems(repr, 0, 3) : self.extra_nodes(repr.data.span.start, repr.data.span.len);

<* Decode an `encode_typed_list` list (packed slices alias node storage). *>
fn NodeIndex[] Tree.decode_typed_list(&self, NodeRepr* repr)
	=> repr.form.packed ? unpack_node_elems(repr, 1, 2) : self.extra_nodes(repr.data.typed_span.start, repr.data.typed_span.len);

<*
 Zig `Node.Index.get` for a STMT/EXPR node (inverse of
 `encode_expr_stmt`). Non-packed ASM_STMT quals come from the form bits,
 with is_goto = labels.len > 0. Packed forms alias node storage.
 @require index.kind(self).family != DECL
*>
fn Node Tree.decode_expr_stmt(&self, NodeIndex index)
{
	NodeRepr* r = self.nodes.get_ref((sz)index);
	NodeData d = r.data;
	switch (r.kind)
	{
		case LABELED_STMT: return { .kind = LABELED_STMT, .labeled_stmt = { .label_tok = r.tok, .body = d.body.body } };
		case COMPOUND_STMT: return { .kind = COMPOUND_STMT, .compound_stmt = { .l_brace_tok = r.tok, .body = self.decode_node_list(r) } };
		case IF_STMT:
			if (!r.form.has_init) return { .kind = IF_STMT, .if_stmt = { .if_tok = r.tok, .init = type_store::NODE_NULL, .cond = d.if_stmt.cond, .then_body = d.if_stmt.then_body, .else_body = d.if_stmt.else_body } };
			if (!r.form.has_else) return { .kind = IF_STMT, .if_stmt = { .if_tok = r.tok, .init = d.if_init.init, .cond = d.if_init.cond, .then_body = (NodeIndex)d.if_init.then_or_extra, .else_body = type_store::NODE_NULL } };
			NodeIndex[] pair = self.extra_nodes(d.if_init.then_or_extra, 2);
			return { .kind = IF_STMT, .if_stmt = { .if_tok = r.tok, .cond = d.if_init.cond, .init = d.if_init.init, .then_body = pair[0], .else_body = pair[1].pack() } };
		case SWITCH_STMT: return { .kind = SWITCH_STMT, .switch_stmt = { .switch_tok = r.tok, .cond = d.switch_stmt.cond, .init = d.switch_stmt.init, .body = d.switch_stmt.body } };
		case CASE_STMT: return { .kind = CASE_STMT, .case_stmt = { .case_tok = r.tok, .start = d.case_stmt.start, .end = d.case_stmt.end, .body = d.case_stmt.body } };
		case DEFAULT_STMT: return { .kind = DEFAULT_STMT, .default_stmt = { .default_tok = r.tok, .body = d.body.body } };
		case WHILE_STMT: return { .kind = WHILE_STMT, .while_stmt = { .while_tok = r.tok, .cond = d.loop.cond, .body = d.loop.body } };
		case DO_WHILE_STMT: return { .kind = DO_WHILE_STMT, .do_while_stmt = { .do_tok = r.tok, .cond = d.loop.cond, .body = d.loop.body } };
		case FOR_STMT:
			NodeForStmt f = { .for_tok = r.tok, .init = type_store::NODE_NULL, .cond = type_store::NODE_NULL, .incr = type_store::NODE_NULL, .body = d.for_stmt.body };
			if (r.form.has_init && r.form.has_cond && r.form.has_incr)
			{
				NodeIndex[] pair = self.extra_nodes(d.for_stmt.clauses[1], 2);
				f.init = (NodeOptIndex)d.for_stmt.clauses[0]; f.cond = pair[0].pack(); f.incr = pair[1].pack();
			}
			else
			{
				usz slot = 0;
				if (r.form.has_init) f.init = (NodeOptIndex)d.for_stmt.clauses[slot++];
				if (r.form.has_cond) f.cond = (NodeOptIndex)d.for_stmt.clauses[slot++];
				if (r.form.has_incr) f.incr = (NodeOptIndex)d.for_stmt.clauses[slot++];
			}
			return { .kind = FOR_STMT, .for_stmt = f };
		case GOTO_STMT: return { .kind = GOTO_STMT, .goto_stmt = { .label_tok = r.tok } };
		case COMPUTED_GOTO_STMT: return { .kind = COMPUTED_GOTO_STMT, .computed_goto_stmt = { .goto_tok = r.tok, .expr = d.expr.expr } };
		case CONTINUE_STMT: return { .kind = CONTINUE_STMT, .continue_stmt = { .continue_tok = r.tok, .has_label = d.jump.has_label != 0, .label = d.jump.label } };
		case BREAK_STMT: return { .kind = BREAK_STMT, .break_stmt = { .break_tok = r.tok, .has_label = d.jump.has_label != 0, .label = d.jump.label } };
		case NULL_STMT: return { .kind = NULL_STMT, .null_stmt = { .semicolon_or_r_brace_tok = r.tok } };
		case RETURN_STMT:
			if (r.form.return_none) return { .kind = RETURN_STMT, .return_stmt = { .return_tok = r.tok, .return_qt = d.return_stmt.qt, .operand = NONE } };
			if (r.form.implicit) return { .kind = RETURN_STMT, .return_stmt = { .return_tok = r.tok, .return_qt = d.return_stmt.qt, .operand = IMPLICIT, .implicit_value = d.return_stmt.value != 0 } };
			return { .kind = RETURN_STMT, .return_stmt = { .return_tok = r.tok, .return_qt = d.return_stmt.qt, .operand = EXPR, .expr = (NodeIndex)d.return_stmt.value } };
		case DECL_STMT: return { .kind = DECL_STMT, .decl_stmt = { .first_tok = r.tok, .decls = self.decode_node_list(r) } };
		case CALL_EXPR:
			if (r.form.packed) return { .kind = CALL_EXPR, .call = { .l_paren_tok = r.tok, .qt = d.call_one.qt, .callee = d.call_one.callee, .args = unpack_node_elems(r, 2, 1) } };
			NodeIndex[] callee_args = self.extra_nodes(d.extra_list.start, d.extra_list.len);
			return { .kind = CALL_EXPR, .call = { .l_paren_tok = r.tok, .qt = d.extra_list.qt, .callee = callee_args[0], .args = callee_args[1..] } };
		case BUILTIN_CALL_EXPR: return { .kind = BUILTIN_CALL_EXPR, .builtin_call = { .builtin_tok = r.tok, .qt = d.typed_list.qt, .args = self.decode_typed_list(r) } };
		case BUILTIN_TYPES_COMPATIBLE_P: return { .kind = BUILTIN_TYPES_COMPATIBLE_P, .types_compatible = { .builtin_tok = r.tok, .lhs = d.types_compatible.lhs, .rhs = d.types_compatible.rhs } };
		case BUILTIN_CONVERTVECTOR: return { .kind = BUILTIN_CONVERTVECTOR, .convertvector = { .builtin_tok = r.tok, .dest_qt = d.convertvector.dest_qt, .operand = d.convertvector.operand } };
		case BUILTIN_SHUFFLEVECTOR:
			NodeIndex[] operands = self.extra_nodes(d.shufflevector.start, d.shufflevector.index_count + 2);
			return { .kind = BUILTIN_SHUFFLEVECTOR, .shufflevector = { .builtin_tok = r.tok, .qt = d.shufflevector.qt, .lhs = operands[0], .rhs = operands[1], .indexes = operands[2..] } };
		case BUILTIN_REF: return { .kind = BUILTIN_REF, .builtin_ref = { .name_tok = r.tok, .qt = d.typed.qt } };
		case BUILTIN_VA_ARG_PACK: return { .kind = BUILTIN_VA_ARG_PACK, .va_arg_pack = { .builtin_tok = r.tok } };
		case BUILTIN_VA_ARG_PACK_LEN: return { .kind = BUILTIN_VA_ARG_PACK_LEN, .va_arg_pack = { .builtin_tok = r.tok } };
		case BOOL_LITERAL:
		case NULLPTR_LITERAL:
		case INT_LITERAL:
		case FLOAT_LITERAL: return { .kind = r.kind, .literal = { .literal_tok = r.tok, .qt = d.typed.qt } };
		case CHAR_LITERAL:
		case STRING_LITERAL_EXPR: return { .kind = r.kind, .char_literal = { .literal_tok = r.tok, .qt = d.char_literal.qt, .kind = (CharLiteralKind)d.char_literal.kind } };
		case SIZEOF_EXPR:
		case ALIGNOF_EXPR:
		case COUNTOF_EXPR: return { .kind = r.kind, .type_info = { .qt = d.type_info.qt, .op_tok = r.tok, .expr = d.type_info.expr, .operand_qt = d.type_info.operand_qt } };
		case GENERIC_EXPR:
			if (r.form.packed) return { .kind = GENERIC_EXPR, .generic = { .generic_tok = r.tok, .qt = d.generic_zero.qt, .controlling = d.generic_zero.controlling, .chosen = d.generic_zero.chosen } };
			NodeIndex[] items = self.extra_nodes(d.extra_list.start, d.extra_list.len);
			return { .kind = GENERIC_EXPR, .generic = { .generic_tok = r.tok, .qt = d.extra_list.qt, .controlling = items[0], .chosen = items[1], .rest = items[2..] } };
		case GENERIC_ASSOCIATION_EXPR: return { .kind = GENERIC_ASSOCIATION_EXPR, .generic_association = { .colon_tok = r.tok, .association_qt = d.generic_association.qt, .expr = d.generic_association.expr } };
		case GENERIC_DEFAULT_EXPR: return { .kind = GENERIC_DEFAULT_EXPR, .generic_default = { .default_tok = r.tok, .expr = d.expr.expr } };
		case BINARY_COND_EXPR:
		case COND_EXPR:
		case BUILTIN_CHOOSE_EXPR:
			NodeIndex[] branches = self.extra_nodes(d.conditional.extra, 2);
			return { .kind = r.kind, .conditional = { .cond_tok = r.tok, .qt = d.conditional.qt, .cond = d.conditional.cond, .then_expr = branches[0], .else_expr = branches[1] } };
		case ARRAY_INIT_EXPR:
		case STRUCT_INIT_EXPR: return { .kind = r.kind, .container_init = { .l_brace_tok = r.tok, .container_qt = d.typed_list.qt, .items = self.decode_typed_list(r) } };
		case UNION_INIT_EXPR: return { .kind = UNION_INIT_EXPR, .union_init = { .l_brace_tok = r.tok, .union_qt = d.union_init.qt, .field_index = d.union_init.field_index, .initializer = d.union_init.initializer } };
		case ARRAY_FILLER_EXPR: return { .kind = ARRAY_FILLER_EXPR, .array_filler = { .last_tok = r.tok, .qt = d.array_filler.qt, .count = ((ulong)d.array_filler.count_hi << 32) | d.array_filler.count_lo } };
		case DEFAULT_INIT_EXPR: return { .kind = DEFAULT_INIT_EXPR, .default_init = { .last_tok = r.tok, .qt = d.typed.qt } };
		case COMPOUND_LITERAL_EXPR:
			DeclAttr attr = d.compound_literal.attr;
			CompoundLiteralStorageClass storage = attr.is_static ? CompoundLiteralStorageClass.STATIC : attr.register ? CompoundLiteralStorageClass.REGISTER : CompoundLiteralStorageClass.AUTO;
			return { .kind = COMPOUND_LITERAL_EXPR, .compound_literal = { .l_paren_tok = r.tok, .qt = d.compound_literal.qt, .thread_local = attr.thread_local, .storage_class = storage, .initializer = d.compound_literal.initializer } };
		case ASM_STMT:
			if (r.form.packed) return { .kind = ASM_STMT, .asm_stmt = { .asm_tok = r.tok, .asm_str = d.asm_stmt.asm_str, .quals = (GnuAsmQualifiers)d.asm_stmt.quals_or_labels } };
			uint label_len = d.asm_stmt.quals_or_labels;
			uint start = d.asm_stmt.extra; uint out_len = self.extra[(usz)start]; uint in_len = self.extra[(usz)start+1]; uint clobber_len = self.extra[(usz)start+2];
			uint out_start = start + 3; uint in_start = out_start + out_len * 3; uint clobber_start = in_start + in_len * 3; uint label_start = clobber_start + clobber_len;
			GnuAsmQualifiers aq = { .is_inline = r.form.asm_inline, .is_volatile = r.form.asm_volatile, .is_goto = label_len > 0 };
			// The operand records are serialized into `extra` as three words
			// each. Start each view at its word offset before interpreting it as
			// AsmOperand; the entire extra buffer need not be record-aligned.
			uint[] words = self.extra.array_view();
			return { .kind = ASM_STMT, .asm_stmt = { .asm_tok = r.tok, .asm_str = d.asm_stmt.asm_str, .outputs = asm_operands(words, out_start, out_len), .inputs = asm_operands(words, in_start, in_len), .clobbers = self.extra_nodes(clobber_start, clobber_len), .labels = self.extra_nodes(label_start, label_len), .quals = aq } };
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
		case MOD_EXPR: return { .kind = r.kind, .binary = { .qt = d.binary.qt, .lhs = d.binary.lhs, .op_tok = r.tok, .rhs = d.binary.rhs } };
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
		case IMAGINARY_LITERAL: return { .kind = r.kind, .unary = { .qt = d.unary.qt, .op_tok = r.tok, .operand = d.unary.operand } };
		case CAST: return { .kind = CAST, .cast = { .qt = d.cast.qt, .l_paren = r.tok, .kind = (CastKind)d.cast.kind, .operand = d.cast.operand, .implicit = r.form.implicit } };
		case ADDR_OF_LABEL: return { .kind = ADDR_OF_LABEL, .addr_of_label = { .label_tok = r.tok, .qt = d.typed.qt } };
		case ARRAY_ACCESS_EXPR: return { .kind = ARRAY_ACCESS_EXPR, .array_access = { .l_bracket_tok = r.tok, .qt = d.array_access.qt, .base = d.array_access.base, .index = d.array_access.index } };
		case MEMBER_ACCESS_EXPR:
		case MEMBER_ACCESS_PTR_EXPR: return { .kind = r.kind, .member_access = { .qt = d.member_access.qt, .base = d.member_access.base, .access_tok = r.tok, .member_index = d.member_access.member_index } };
		case DECL_REF_EXPR:
		case ENUMERATION_REF: return { .kind = r.kind, .decl_ref = { .name_tok = r.tok, .qt = d.decl_ref.qt, .decl = d.decl_ref.decl } };
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
			if (!@ok(attr))
			{
				QualType base_qt = n.decl_ref.qt;
				if (try ptr = base_qt.get(self.comp, POINTER)) base_qt = ptr.pointer.child;
				if (try function_type = base_qt.get(self.comp, FUNC)) attr = function_type.func.return_type.get_attribute(self, tag);
			}
			return { .tok = n.decl_ref.name_tok, .has_attr = @ok(attr), .attr = attr ?? (Attribute){} };
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
				if (!@ok(field_attr))
				{
					QualType field_qt = field.qt;
					if (try ptr = field_qt.get(self.comp, POINTER)) field_qt = ptr.pointer.child;
					if (try function_type = field_qt.get(self.comp, FUNC)) field_attr = function_type.func.return_type.get_attribute(self, tag);
				}
				return { .tok = (tokens::TokenIndex)field.name_tok, .has_attr = @ok(field_attr), .attr = field_attr ?? (Attribute){} };
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
