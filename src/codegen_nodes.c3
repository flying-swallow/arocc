// Port of AST statement/expression lowering from src/aro/CodeGen.zig.
module aro::codegen;
import aro::backend::ir, aro::builtins, aro::compilation, aro::diagnostics;
import aro::bigint;
import aro::tree, aro::type_store, aro::value, aro::value_interner, aro::lang_opts;
import aro::target;
import aro::string_interner;
import std::core::dstring, std::core::string;

fn void? CodeGen.gen_stmt(&self, type_store::NodeIndex node)
{
	self.gen_expr(node)!;
}

fn ir::Ref? CodeGen.gen_expr(&self, type_store::NodeIndex node_index)
{
	tree::Node node = node_index.get(self.tree);
	// Array/function decay casts and saved pointer values lower through their operands,
	// not as IR constants.
	if (try val = self.tree.value_of(node_index))
	{
		bool decay_cast = node.kind == tree::NodeKind.CAST &&
			(node.cast.kind == tree::CastKind.ARRAY_TO_POINTER || node.cast.kind == tree::CastKind.FUNCTION_TO_POINTER);
		bool implicit_variable = node.kind == tree::NodeKind.VARIABLE && node.variable.implicit;
		if (node.kind == tree::NodeKind.DECL_REF_EXPR)
		{
			tree::Node referenced = node.decl_ref.decl.get(self.tree);
			implicit_variable = referenced.kind == tree::NodeKind.VARIABLE && referenced.variable.implicit;
		}
		if (!decay_cast && !implicit_variable && !val.is_pointer(self.comp))
		{
			return self.builder.add_constant(val.ref(), self.gen_type(node_index.qt(self.tree))!);
		}
	}

	switch (node.kind)
	{
		case ENUMERATION_REF: case BOOL_LITERAL: case INT_LITERAL: case CHAR_LITERAL:
		case FLOAT_LITERAL: case IMAGINARY_LITERAL: case STRING_LITERAL_EXPR: case ALIGNOF_EXPR:
			unreachable("constant expression missing value map entry");
		case EMPTY_DECL: case STATIC_ASSERT: case FUNCTION: case TYPEDEF:
		case STRUCT_DECL: case UNION_DECL: case ENUM_DECL: case ENUM_FIELD: case RECORD_FIELD:
		case STRUCT_FORWARD_DECL: case UNION_FORWARD_DECL: case ENUM_FORWARD_DECL: case NULL_STMT:
			break;
		case VARIABLE:
			if (node.variable.storage_class == tree::VariableStorageClass.EXTERN || node.variable.storage_class == tree::VariableStorageClass.STATIC)
			{
				self.gen_var(node.variable, node_index)!;
				return ir::NONE;
			}
			uint size = (uint)node.variable.qt.sizeof(self.comp);
			uint alignment = (uint)node.variable.qt.alignof(self.comp);
			ir::Ref alloc = self.builder.add_alloc(size, alignment, node.variable.qt.is_volatile);
			string_interner::StringId name = self.comp.intern_string(self.tree.tok_slice(node.variable.name_tok));
			self.symbols.push({ .name = name, .value = alloc });
			if (!node.variable.initializer.is_null())
			{
				self.gen_initializer(alloc, node.variable.qt, node.variable.initializer.unwrap())!;
			}
		case LABELED_STMT:
			ir::Ref label = self.builder.make_label("label");
			self.builder.start_block(label);
			self.gen_stmt(node.labeled_stmt.body)!;
		case COMPOUND_STMT:
			// Preserve the Zig implementation's current (no-op) scope-length reset.
			sz old_symbol_count = self.symbols.len();
			while (self.symbols.len() > old_symbol_count) self.symbols.pop()!!;
			foreach (stmt : node.compound_stmt.body) self.gen_stmt(stmt)!;
		case IF_STMT:
			ir::Ref then_label = self.builder.make_label("if.then");
			if (node.if_stmt.else_body.is_null())
			{
				ir::Ref end_label = self.builder.make_label("if.end");
				self.gen_bool_expr(node.if_stmt.cond, then_label, end_label)!;
				self.builder.start_block(then_label);
				self.gen_stmt(node.if_stmt.then_body)!;
				self.builder.start_block(end_label);
				return ir::NONE;
			}
			ir::Ref else_label = self.builder.make_label("if.else");
			ir::Ref end_label = self.builder.make_label("if.end");
			self.gen_bool_expr(node.if_stmt.cond, then_label, else_label)!;
			self.builder.start_block(then_label);
			self.gen_stmt(node.if_stmt.then_body)!;
			self.builder.add_jump(end_label);
			self.builder.start_block(else_label);
			self.gen_stmt(node.if_stmt.else_body.unwrap())!;
			self.builder.start_block(end_label);
		case SWITCH_STMT:
			WipSwitch wip_switch = {
				.cases = { },
				.size = node.switch_stmt.cond.qt(self.tree).sizeof(self.comp),
			};
			wip_switch.cases.init(self.comp.gpa);
			defer wip_switch.cases.free();
			WipSwitch* old_wip_switch = self.wip_switch;
			defer self.wip_switch = old_wip_switch;
			self.wip_switch = &wip_switch;
			ir::Ref old_break_label = self.break_label;
			defer self.break_label = old_break_label;
			ir::Ref end_label = self.builder.make_label("switch.end");
			self.break_label = end_label;
			ir::Ref cond = self.gen_expr(node.switch_stmt.cond)!;
			ir::Ref switch_ref = self.builder.add_inst(ir::InstTag.SWITCH, { .none = 0 }, value_interner::REF_NORETURN);
			self.gen_stmt(node.switch_stmt.body)!;
			ir::Ref default_label = wip_switch.has_default ? wip_switch.default_label : end_label;
			self.builder.start_block(end_label);
			sz case_count = wip_switch.cases.len();
			value_interner::InternerRef[] case_values = alloc::new_array(&self.builder.arena, value_interner::InternerRef, case_count);
			ir::Ref[] case_labels = alloc::new_array(&self.builder.arena, ir::Ref, case_count);
			foreach (i, switch_case : wip_switch.cases)
			{
				case_values[i] = switch_case.value;
				case_labels[i] = switch_case.label;
			}
			ir::Inst* switch_inst = self.builder.instructions.get_ref((sz)switch_ref);
			switch_inst.data.switch_data = { .target = cond, .values = case_values, .labels = case_labels, .default_label = default_label };
		case CASE_STMT:
			if (!node.case_stmt.end.is_null())
			{
				self.fail("TODO CodeGen.genStmt case range\n")!;
				return ir::NONE;
			}
			value::Value case_value = self.tree.value_of(node.case_stmt.start)!!;
			ir::Ref case_label = self.builder.make_label("case");
			self.builder.start_block(case_label);
			self.wip_switch.cases.push({ .value = case_value.ref(), .label = case_label });
			self.gen_stmt(node.case_stmt.body)!;
		case DEFAULT_STMT:
			ir::Ref default_label = self.builder.make_label("default");
			self.builder.start_block(default_label);
			self.wip_switch.has_default = true;
			self.wip_switch.default_label = default_label;
			self.gen_stmt(node.default_stmt.body)!;
		case WHILE_STMT:
			ir::Ref old_break_label = self.break_label;
			defer self.break_label = old_break_label;
			ir::Ref old_continue_label = self.continue_label;
			defer self.continue_label = old_continue_label;
			ir::Ref cond_label = self.builder.make_label("while.cond");
			ir::Ref body_label = self.builder.make_label("while.then");
			ir::Ref end_label = self.builder.make_label("while.end");
			self.continue_label = cond_label;
			self.break_label = end_label;
			self.builder.start_block(cond_label);
			self.gen_bool_expr(node.while_stmt.cond, body_label, end_label)!;
			self.builder.start_block(body_label);
			self.gen_stmt(node.while_stmt.body)!;
			self.builder.add_jump(cond_label);
			self.builder.start_block(end_label);
		case DO_WHILE_STMT:
			ir::Ref old_break_label = self.break_label;
			defer self.break_label = old_break_label;
			ir::Ref old_continue_label = self.continue_label;
			defer self.continue_label = old_continue_label;
			ir::Ref body_label = self.builder.make_label("do.then");
			ir::Ref cond_label = self.builder.make_label("do.cond");
			ir::Ref end_label = self.builder.make_label("do.end");
			self.continue_label = cond_label;
			self.break_label = end_label;
			self.builder.start_block(body_label);
			self.gen_stmt(node.do_while_stmt.body)!;
			self.builder.start_block(cond_label);
			self.gen_bool_expr(node.do_while_stmt.cond, body_label, end_label)!;
			self.builder.start_block(end_label);
		case FOR_STMT:
			ir::Ref old_break_label = self.break_label;
			defer self.break_label = old_break_label;
			ir::Ref old_continue_label = self.continue_label;
			defer self.continue_label = old_continue_label;
			if (!node.for_stmt.init.is_null()) self.gen_stmt(node.for_stmt.init.unwrap())!;
			if (node.for_stmt.cond.is_null())
			{
				ir::Ref body_label = self.builder.make_label("for.then");
				ir::Ref end_label = self.builder.make_label("for.end");
				self.continue_label = body_label;
				self.break_label = end_label;
				self.builder.start_block(body_label);
				self.gen_stmt(node.for_stmt.body)!;
				if (!node.for_stmt.incr.is_null()) self.gen_expr(node.for_stmt.incr.unwrap())!;
				self.builder.add_jump(body_label);
				self.builder.start_block(end_label);
				return ir::NONE;
			}
			ir::Ref body_label = self.builder.make_label("for.then");
			ir::Ref continue_label = self.builder.make_label("for.cont");
			ir::Ref end_label = self.builder.make_label("for.end");
			self.continue_label = continue_label;
			self.break_label = end_label;
			ir::Ref cond_label = self.builder.make_label("for.cond");
			self.builder.start_block(cond_label);
			self.gen_bool_expr(node.for_stmt.cond.unwrap(), body_label, end_label)!;
			self.builder.start_block(body_label);
			self.gen_stmt(node.for_stmt.body)!;
			if (!node.for_stmt.incr.is_null()) self.gen_expr(node.for_stmt.incr.unwrap())!;
			self.builder.add_jump(cond_label);
			self.builder.start_block(end_label);
		case CONTINUE_STMT:
			self.builder.add_jump(self.continue_label);
		case BREAK_STMT:
			self.builder.add_jump(self.break_label);
		case RETURN_STMT:
			switch (node.return_stmt.operand)
			{
				case EXPR:
					ir::Ref result = self.gen_expr(node.return_stmt.expr)!;
					self.ret_nodes.push({ .value = result, .label = self.builder.current_label });
				case NONE:
					break;
				case IMPLICIT:
					if (node.return_stmt.implicit_value)
					{
						ir::Ref zero = self.builder.add_constant(value::ZERO.ref(), self.gen_type(node.return_stmt.return_qt)!);
						self.ret_nodes.push({ .value = zero, .label = self.builder.current_label });
					}
					return ir::NONE;
			}
			self.builder.add_jump(self.return_label);
		case GOTO_STMT: case COMPUTED_GOTO_STMT: case NULLPTR_LITERAL: case ASM_STMT:
			self.fail(string::tformat("TODO CodeGen.genStmt %s\n", node.kind.name))!;
			return ir::NONE;
		case DECL_STMT:
			foreach (decl : node.decl_stmt.decls) self.gen_stmt(decl)!;
		case COMMA_EXPR:
			self.gen_expr(node.binary.lhs)!;
			return self.gen_expr(node.binary.rhs);
		case ASSIGN_EXPR:
			ir::Ref rhs = self.gen_expr(node.binary.rhs)!;
			ir::Ref lhs = self.gen_lval(node.binary.lhs)!;
			self.builder.add_store(lhs, rhs);
			return rhs;
		case MUL_ASSIGN_EXPR: case DIV_ASSIGN_EXPR: case MOD_ASSIGN_EXPR: case ADD_ASSIGN_EXPR:
		case SUB_ASSIGN_EXPR: case SHL_ASSIGN_EXPR: case SHR_ASSIGN_EXPR: case BIT_AND_ASSIGN_EXPR:
		case BIT_XOR_ASSIGN_EXPR: case BIT_OR_ASSIGN_EXPR:
			return self.gen_compound_assign(node.binary);
		case BIT_OR_EXPR: return self.gen_bin_op(node.binary, ir::InstTag.BIT_OR);
		case BIT_XOR_EXPR: return self.gen_bin_op(node.binary, ir::InstTag.BIT_XOR);
		case BIT_AND_EXPR: return self.gen_bin_op(node.binary, ir::InstTag.BIT_AND);
		case EQUAL_EXPR: return self.add_un(ir::InstTag.ZEXT, self.gen_comparison(node.binary, ir::InstTag.CMP_EQ)!, node.binary.qt);
		case NOT_EQUAL_EXPR: return self.add_un(ir::InstTag.ZEXT, self.gen_comparison(node.binary, ir::InstTag.CMP_NE)!, node.binary.qt);
		case LESS_THAN_EXPR:
		case LESS_THAN_EQUAL_EXPR:
		case GREATER_THAN_EXPR:
		case GREATER_THAN_EQUAL_EXPR:
			return self.add_un(ir::InstTag.ZEXT, self.gen_comparison(node.binary, self.ordered_compare_tag(node.kind, node.binary))!, node.binary.qt);
		case SHL_EXPR: return self.gen_bin_op(node.binary, ir::InstTag.BIT_SHL);
		case SHR_EXPR: return self.gen_bin_op(node.binary, self.signed_tag(node.binary.qt, ir::InstTag.BIT_ASHR, ir::InstTag.BIT_LSHR));
		case ADD_EXPR:
			if (node.binary.qt.is(self.comp, type_store::TypeTag.POINTER))
			{
				type_store::QualType lhs_type = node.binary.lhs.qt(self.tree);
				if (lhs_type.is(self.comp, type_store::TypeTag.POINTER))
				{
					return self.gen_ptr_arithmetic(self.gen_expr(node.binary.lhs)!, self.gen_expr(node.binary.rhs)!, node.binary.rhs.qt(self.tree), node.binary.qt, false);
				}
				ir::Ref offset = self.gen_expr(node.binary.lhs)!;
				ir::Ref ptr = self.gen_expr(node.binary.rhs)!;
				return self.gen_ptr_arithmetic(ptr, offset, lhs_type, node.binary.qt, false);
			}
			return self.gen_bin_op(node.binary, ir::InstTag.ADD);
		case SUB_EXPR:
			{
				type_store::QualType lhs_type = node.binary.lhs.qt(self.tree);
				type_store::QualType rhs_type = node.binary.rhs.qt(self.tree);
				if (lhs_type.is_pointer(self.comp) && rhs_type.is_pointer(self.comp))
				{
					return self.gen_ptr_difference(self.gen_expr(node.binary.lhs)!, self.gen_expr(node.binary.rhs)!, lhs_type, node.binary.qt);
				}
				if (lhs_type.is_pointer(self.comp))
				{
					return self.gen_ptr_arithmetic(self.gen_expr(node.binary.lhs)!, self.gen_expr(node.binary.rhs)!, rhs_type, lhs_type, true);
				}
			}
			return self.gen_bin_op(node.binary, ir::InstTag.SUB);
		case MUL_EXPR: return self.gen_bin_op(node.binary, ir::InstTag.MUL);
		case DIV_EXPR: return self.gen_bin_op(node.binary, self.signed_tag(node.binary.qt, ir::InstTag.SDIV, ir::InstTag.UDIV));
		case MOD_EXPR: return self.gen_bin_op(node.binary, self.signed_tag(node.binary.qt, ir::InstTag.SREM, ir::InstTag.UREM));
		case ADDR_OF_EXPR: return self.gen_lval(node.unary.operand);
		case DEREF_EXPR:
			tree::Node operand_node = node.unary.operand.get(self.tree);
			if (operand_node.kind == tree::NodeKind.CAST && operand_node.cast.kind == tree::CastKind.FUNCTION_TO_POINTER)
			{
				return self.gen_expr(node.unary.operand);
			}
			return self.add_un(ir::InstTag.LOAD, self.gen_lval(node.unary.operand)!, node.unary.qt);
		case PLUS_EXPR: return self.gen_expr(node.unary.operand);
		case NEGATE_EXPR:
			ir::Ref zero = self.builder.add_constant(value::ZERO.ref(), self.gen_type(node.unary.qt)!);
			return self.add_bin(ir::InstTag.SUB, zero, self.gen_expr(node.unary.operand)!, node.unary.qt);
		case BIT_NOT_EXPR: return self.add_un(ir::InstTag.BIT_NOT, self.gen_expr(node.unary.operand)!, node.unary.qt);
		case BOOL_NOT_EXPR:
			// C3 deviation: Zig emits `cmp_ne 0, x` typed int, which inverts the result.
			// `!x` is `x == 0` as an i1, widened to the int result.
			ir::Ref operand = self.gen_expr(node.unary.operand)!;
			ir::Ref zero = self.builder.add_constant(value::ZERO.ref(), self.gen_type(node.unary.operand.qt(self.tree))!);
			ir::Ref is_zero = self.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { .lhs = operand, .rhs = zero } }, value_interner::REF_I1);
			return self.add_un(ir::InstTag.ZEXT, is_zero, node.unary.qt);
		case PRE_INC_EXPR: case PRE_DEC_EXPR: case POST_INC_EXPR: case POST_DEC_EXPR:
			ir::Ref addr = self.gen_lval(node.unary.operand)!;
			ir::Ref val = self.add_un(ir::InstTag.LOAD, addr, node.unary.qt)!;
			ir::Ref one = self.builder.add_constant(value::ONE.ref(), self.gen_type(node.unary.qt)!);
			bool decrement = node.kind == tree::NodeKind.PRE_DEC_EXPR || node.kind == tree::NodeKind.POST_DEC_EXPR;
			ir::Ref updated = self.add_bin(decrement ? ir::InstTag.SUB : ir::InstTag.ADD, val, one, node.unary.qt)!;
			self.builder.add_store(addr, updated);
			return (node.kind == tree::NodeKind.POST_INC_EXPR || node.kind == tree::NodeKind.POST_DEC_EXPR) ? val : updated;
		case PAREN_EXPR: return self.gen_expr(node.unary.operand);
		case DECL_REF_EXPR:
			unreachable("declaration reference must be lowered as an lvalue");
		case CAST:
			switch (node.cast.kind)
			{
				case NO_OP: return self.gen_expr(node.cast.operand);
				case BITCAST:
					if (node.cast.operand.qt(self.tree).is_pointer(self.comp) && node.cast.qt.is_pointer(self.comp))
					{
						return self.gen_expr(node.cast.operand);
					}
					self.fail("TODO CodeGen gen CastKind bitcast\n")!;
					return ir::NONE;
				case TO_VOID:
				self.gen_expr(node.cast.operand)!;
					return ir::NONE;
				case LVAL_TO_RVAL: return self.add_un(ir::InstTag.LOAD, self.gen_lval(node.cast.operand)!, node.cast.qt);
				case FUNCTION_TO_POINTER: case ARRAY_TO_POINTER: return self.gen_lval(node.cast.operand);
				case INT_CAST:
					ir::Ref operand = self.gen_expr(node.cast.operand)!;
					type_store::QualType src_type = node.cast.operand.qt(self.tree);
					ulong src_bits = src_type.bit_sizeof(self.comp);
					ulong dest_bits = node.cast.qt.bit_sizeof(self.comp);
					if (src_bits == dest_bits) return operand;
					if (src_bits < dest_bits)
					{
						return self.add_un(src_type.signedness(self.comp) == lang_opts::Signedness.UNSIGNED ? ir::InstTag.ZEXT : ir::InstTag.SEXT, operand, node.cast.qt);
					}
					return self.add_un(ir::InstTag.TRUNC, operand, node.cast.qt);
				case BOOL_TO_INT: return self.add_un(ir::InstTag.ZEXT, self.gen_expr(node.cast.operand)!, node.cast.qt);
				case POINTER_TO_BOOL: case INT_TO_BOOL: case FLOAT_TO_BOOL:
					ir::Ref lhs = self.gen_expr(node.cast.operand)!;
					ir::Ref rhs = self.builder.add_constant(value::ZERO.ref(), self.gen_type(node.cast.qt)!);
					return self.builder.add_inst(ir::InstTag.CMP_NE, { .bin = { .lhs = lhs, .rhs = rhs } }, value_interner::REF_I1);
				case POINTER_TO_INT: case BOOL_TO_FLOAT: case BOOL_TO_POINTER: case INT_TO_FLOAT:
				case COMPLEX_INT_TO_COMPLEX_FLOAT: case INT_TO_POINTER: case FLOAT_TO_INT:
				case COMPLEX_FLOAT_TO_COMPLEX_INT: case COMPLEX_INT_CAST: case COMPLEX_INT_TO_REAL:
				case REAL_TO_COMPLEX_INT: case FLOAT_CAST: case COMPLEX_FLOAT_CAST:
				case COMPLEX_FLOAT_TO_REAL: case REAL_TO_COMPLEX_FLOAT: case NULL_TO_POINTER:
				case UNION_CAST: case VECTOR_SPLAT: case ATOMIC_TO_NON_ATOMIC: case NON_ATOMIC_TO_ATOMIC:
					self.fail(string::tformat("TODO CodeGen gen CastKind %s\n", node.cast.kind.name))!;
					return ir::NONE;
			}
		case BINARY_COND_EXPR:
			if (try cond = self.tree.value_of(node.conditional.cond))
			{
				if (cond.to_bool(self.comp))
				{
					self.cond_dummy_ref = self.gen_expr(node.conditional.cond)!;
					return self.gen_expr(node.conditional.then_expr);
				}
				return self.gen_expr(node.conditional.else_expr);
			}
			ir::Ref then_label = self.builder.make_label("ternary.then");
			ir::Ref else_label = self.builder.make_label("ternary.else");
			ir::Ref end_label = self.builder.make_label("ternary.end");
			type_store::QualType cond_type = node.conditional.cond.qt(self.tree);
			{
				bool old_has_cond_dummy_ty = self.has_cond_dummy_ty;
				value_interner::InternerRef old_cond_dummy_ty = self.cond_dummy_ty;
				defer { self.has_cond_dummy_ty = old_has_cond_dummy_ty; self.cond_dummy_ty = old_cond_dummy_ty; }
				self.has_cond_dummy_ty = true;
				self.cond_dummy_ty = self.gen_type(cond_type)!;
				self.gen_bool_expr(node.conditional.cond, then_label, else_label)!;
			}
			self.builder.start_block(then_label);
			ir::Inst* dummy_inst = self.builder.instructions.get_ref((sz)self.cond_dummy_ref);
			if (dummy_inst.ty == value_interner::REF_I1)
			{
				self.cond_dummy_ref = self.add_un(ir::InstTag.ZEXT, self.cond_dummy_ref, cond_type)!;
			}
			ir::Ref then_val = self.gen_expr(node.conditional.then_expr)!;
			self.builder.add_jump(end_label);
			ir::Ref then_exit = self.builder.current_label;
			self.builder.start_block(else_label);
			ir::Ref else_val = self.gen_expr(node.conditional.else_expr)!;
			ir::Ref else_exit = self.builder.current_label;
			self.builder.start_block(end_label);
			ir::PhiInput[2] conditional_inputs = {
				{ .value = then_val, .label = then_exit }, { .value = else_val, .label = else_exit },
			};
			return self.builder.add_phi(conditional_inputs[..], self.gen_type(node.conditional.qt)!);
		case COND_DUMMY_EXPR:
			return self.cond_dummy_ref;
		case COND_EXPR:
			if (try cond = self.tree.value_of(node.conditional.cond))
			{
				return self.gen_expr(cond.to_bool(self.comp) ? node.conditional.then_expr : node.conditional.else_expr);
			}
			ir::Ref then_label = self.builder.make_label("ternary.then");
			ir::Ref else_label = self.builder.make_label("ternary.else");
			ir::Ref end_label = self.builder.make_label("ternary.end");
			self.gen_bool_expr(node.conditional.cond, then_label, else_label)!;
			self.builder.start_block(then_label);
			ir::Ref then_val = self.gen_expr(node.conditional.then_expr)!;
			self.builder.add_jump(end_label);
			ir::Ref then_exit = self.builder.current_label;
			self.builder.start_block(else_label);
			ir::Ref else_val = self.gen_expr(node.conditional.else_expr)!;
			ir::Ref else_exit = self.builder.current_label;
			self.builder.start_block(end_label);
			ir::PhiInput[2] conditional_inputs = {
				{ .value = then_val, .label = then_exit }, { .value = else_val, .label = else_exit },
			};
			return self.builder.add_phi(conditional_inputs[..], self.gen_type(node.conditional.qt)!);
		case CALL_EXPR:
			return self.gen_call(node.call);
		case BOOL_OR_EXPR:
			if (try lhs = self.tree.value_of(node.binary.lhs))
			{
				if (!lhs.to_bool(self.comp)) return self.builder.add_constant(value::ONE.ref(), self.gen_type(node.binary.qt)!);
				return self.gen_expr(node.binary.rhs);
			}
			ir::Ref false_label = self.builder.make_label("bool_false");
			ir::Ref bool_exit_label = self.builder.make_label("bool_exit");
			ir::Ref old_bool_end_label = self.bool_end_label;
			defer self.bool_end_label = old_bool_end_label;
			self.bool_end_label = bool_exit_label;
			sz phi_top = self.phi_nodes.len();
			defer { while (self.phi_nodes.len() > phi_top) self.phi_nodes.pop()!!; }
			self.gen_bool_expr(node.binary.lhs, bool_exit_label, false_label)!;
			self.builder.start_block(false_label);
			self.gen_bool_expr(node.binary.rhs, bool_exit_label, bool_exit_label)!;
			self.builder.start_block(bool_exit_label);
			ir::PhiInput[] phi_inputs = self.phi_nodes.array_view()[phi_top..];
			ir::Ref phi = self.builder.add_phi(phi_inputs, value_interner::REF_I1);
			return self.add_un(ir::InstTag.ZEXT, phi, node.binary.qt);
		case BOOL_AND_EXPR:
			if (try lhs = self.tree.value_of(node.binary.lhs))
			{
				if (!lhs.to_bool(self.comp)) return self.builder.add_constant(value::ZERO.ref(), self.gen_type(node.binary.qt)!);
				return self.gen_expr(node.binary.rhs);
			}
			ir::Ref true_label = self.builder.make_label("bool_true");
			ir::Ref bool_exit_label = self.builder.make_label("bool_exit");
			ir::Ref old_bool_end_label = self.bool_end_label;
			defer self.bool_end_label = old_bool_end_label;
			self.bool_end_label = bool_exit_label;
			sz phi_top = self.phi_nodes.len();
			defer { while (self.phi_nodes.len() > phi_top) self.phi_nodes.pop()!!; }
			self.gen_bool_expr(node.binary.lhs, true_label, bool_exit_label)!;
			self.builder.start_block(true_label);
			self.gen_bool_expr(node.binary.rhs, bool_exit_label, bool_exit_label)!;
			self.builder.start_block(bool_exit_label);
			ir::PhiInput[] phi_inputs = self.phi_nodes.array_view()[phi_top..];
			ir::Ref phi = self.builder.add_phi(phi_inputs, value_interner::REF_I1);
			return self.add_un(ir::InstTag.ZEXT, phi, node.binary.qt);
		case BUILTIN_CHOOSE_EXPR:
			value::Value cond = self.tree.value_of(node.conditional.cond)!!;
			return self.gen_expr(cond.to_bool(self.comp) ? node.conditional.then_expr : node.conditional.else_expr);
		case GENERIC_EXPR:
			tree::Node chosen = node.generic.chosen.get(self.tree);
			if (chosen.kind == tree::NodeKind.GENERIC_ASSOCIATION_EXPR) return self.gen_expr(chosen.generic_association.expr);
			if (chosen.kind == tree::NodeKind.GENERIC_DEFAULT_EXPR) return self.gen_expr(chosen.generic_default.expr);
			unreachable("unexpected node selected by generic expression");
		case GENERIC_ASSOCIATION_EXPR: case GENERIC_DEFAULT_EXPR:
			unreachable("generic association/default is not directly evaluated");
		case STMT_EXPR:
			tree::Node compound = node.unary.operand.get(self.tree);
			sz old_symbol_count = self.symbols.len();
			while (self.symbols.len() > old_symbol_count) self.symbols.pop()!!;
			usz body_end = compound.compound_stmt.body.len > 0 ? compound.compound_stmt.body.len - 1 : 0;
			for (usz i = 0; i < body_end; i++) self.gen_stmt(compound.compound_stmt.body[i])!;
			return self.gen_expr(compound.compound_stmt.body[compound.compound_stmt.body.len - 1]);
		case BUILTIN_CALL_EXPR:
			builtins::Expanded builtin = self.comp.builtins.lookup(self.tree.tok_slice(node.builtin_call.builtin_tok));
			return self.gen_builtin_call(builtin, node.builtin_call.args, node.builtin_call.qt);
		case ADDR_OF_LABEL: case IMAG_EXPR: case REAL_EXPR: case SIZEOF_EXPR:
		case BUILTIN_VA_ARG_PACK: case BUILTIN_VA_ARG_PACK_LEN:
			self.fail(string::tformat("TODO CodeGen.genExpr %s\n", node.kind.name))!;
			return ir::NONE;
		case CODEGEN_DIAGNOSTIC:
			String diagnostic_text = words_as_string(node.codegen_diagnostic.text);
			self.comp.diagnostics.add_with_location(self.comp, {
				.kind = node.codegen_diagnostic.kind,
				.text = diagnostic_text,
				.has_opt = node.codegen_diagnostic.has_opt,
				.opt = node.codegen_diagnostic.opt,
				.has_location = true,
				.location = node_index.loc(self.tree).expand(self.comp),
			}, self.pp.expansion_slice(node.codegen_diagnostic.tok), true)!;
		default:
			unreachable("non-expression node in CodeGen.gen_expr");
	}
	return ir::NONE;
}

fn String words_as_string(uint[] words)
{
	char* bytes = (char*)words.ptr;
	usz length = 0;
	while (bytes[length] != 0) length++;
	return (String)bytes[:length];
}

fn ir::Ref? CodeGen.gen_lval(&self, type_store::NodeIndex node_index)
{
	assert(self.tree.is_lval(node_index));
	tree::Node node = node_index.get(self.tree);
	switch (node.kind)
	{
		case STRING_LITERAL_EXPR:
			value::Value val = self.tree.value_of(node_index)!!;
			return self.builder.add_constant(val.ref(), value_interner::REF_PTR);
		case PAREN_EXPR:
			return self.gen_lval(node.unary.operand);
		case DECL_REF_EXPR:
			String name_text = self.tree.tok_slice(node.decl_ref.name_tok);
			tree::Node declaration = node.decl_ref.decl.get(self.tree);
			if (declaration.kind == tree::NodeKind.VARIABLE && declaration.variable.implicit)
			{
				self.gen_var(declaration.variable, node.decl_ref.decl)!;
				return self.builder.add_symbol(self.implicit_var_name(node.decl_ref.decl), value_interner::REF_PTR);
			}
			string_interner::StringId name = self.comp.intern_string(name_text);
			sz i = self.symbols.len();
			while (i > 0)
			{
				i--;
				if (self.symbols[i].name == name) return self.symbols[i].value;
			}
			return self.builder.add_symbol(self.symbol_name(name_text, self.has_internal_linkage(node.decl_ref.decl)), value_interner::REF_PTR);
		case DEREF_EXPR:
			return self.gen_expr(node.unary.operand);
		case COMPOUND_LITERAL_EXPR:
			if (node.compound_literal.storage_class == tree::CompoundLiteralStorageClass.STATIC || node.compound_literal.thread_local)
			{
				self.fail("TODO CodeGen.compound_literal_expr static or thread_local\n")!;
				return ir::NONE;
			}
			uint size = (uint)node.compound_literal.qt.sizeof(self.comp);
			uint alignment = (uint)node.compound_literal.qt.alignof(self.comp);
			ir::Ref alloc = self.builder.add_alloc(size, alignment, node.compound_literal.qt.is_volatile);
			self.gen_initializer(alloc, node.compound_literal.qt, node.compound_literal.initializer)!;
			return alloc;
		case BUILTIN_CHOOSE_EXPR:
			value::Value cond = self.tree.value_of(node.conditional.cond)!!;
			return self.gen_lval(cond.to_bool(self.comp) ? node.conditional.then_expr : node.conditional.else_expr);
		case COMPOUND_ASSIGN_DUMMY_EXPR:
			return self.compound_assign_dummy;
		case MEMBER_ACCESS_EXPR: case MEMBER_ACCESS_PTR_EXPR: case ARRAY_ACCESS_EXPR:
			self.fail(string::tformat("TODO CodeGen.genLval %s\n", node.kind.name))!;
			return ir::NONE;
		default:
			unreachable("non-lvalue node in CodeGen.gen_lval");
	}
}

fn void? CodeGen.gen_bool_expr(&self, type_store::NodeIndex base, ir::Ref true_label, ir::Ref false_label)
{
	type_store::NodeIndex node = base;
	while (node.get(self.tree).kind == tree::NodeKind.PAREN_EXPR) node = node.get(self.tree).unary.operand;
	tree::Node n = node.get(self.tree);
	switch (n.kind)
	{
		case BOOL_OR_EXPR:
			if (try lhs = self.tree.value_of(n.binary.lhs))
			{
				if (lhs.to_bool(self.comp))
				{
					if (true_label == self.bool_end_label) return self.add_bool_phi(!self.bool_invert);
					self.builder.add_jump(true_label);
					return;
				}
				return self.gen_bool_expr(n.binary.rhs, true_label, false_label);
			}
			ir::Ref new_false_label = self.builder.make_label("bool_false");
			self.gen_bool_expr(n.binary.lhs, true_label, new_false_label)!;
			self.builder.start_block(new_false_label);
			if (self.has_cond_dummy_ty) self.cond_dummy_ref = self.builder.add_constant(value_interner::REF_ONE, self.cond_dummy_ty);
			return self.gen_bool_expr(n.binary.rhs, true_label, false_label);
		case BOOL_AND_EXPR:
			if (try lhs = self.tree.value_of(n.binary.lhs))
			{
				if (!lhs.to_bool(self.comp))
				{
					if (false_label == self.bool_end_label) return self.add_bool_phi(self.bool_invert);
					self.builder.add_jump(false_label);
					return;
				}
				return self.gen_bool_expr(n.binary.rhs, true_label, false_label);
			}
			ir::Ref new_true_label = self.builder.make_label("bool_true");
			self.gen_bool_expr(n.binary.lhs, new_true_label, false_label)!;
			self.builder.start_block(new_true_label);
			if (self.has_cond_dummy_ty) self.cond_dummy_ref = self.builder.add_constant(value_interner::REF_ONE, self.cond_dummy_ty);
			return self.gen_bool_expr(n.binary.rhs, true_label, false_label);
		case BOOL_NOT_EXPR:
			self.bool_invert = !self.bool_invert;
			defer self.bool_invert = !self.bool_invert;
			if (self.has_cond_dummy_ty) self.cond_dummy_ref = self.builder.add_constant(value_interner::REF_ZERO, self.cond_dummy_ty);
			return self.gen_bool_expr(n.unary.operand, false_label, true_label);
		case EQUAL_EXPR: case NOT_EQUAL_EXPR: case LESS_THAN_EXPR: case LESS_THAN_EQUAL_EXPR:
		case GREATER_THAN_EXPR: case GREATER_THAN_EQUAL_EXPR:
			ir::InstTag tag = ir::InstTag.CMP_EQ;
			switch (n.kind)
			{
				case EQUAL_EXPR: tag = ir::InstTag.CMP_EQ;
				case NOT_EQUAL_EXPR: tag = ir::InstTag.CMP_NE;
				case LESS_THAN_EXPR:
				case LESS_THAN_EQUAL_EXPR:
				case GREATER_THAN_EXPR:
				case GREATER_THAN_EQUAL_EXPR: tag = self.ordered_compare_tag(n.kind, n.binary);
				default: unreachable();
			}
			ir::Ref cmp = self.gen_comparison(n.binary, tag)!;
			if (self.has_cond_dummy_ty) self.cond_dummy_ref = cmp;
			return self.add_branch(cmp, true_label, false_label);
		case CAST:
			if (n.cast.kind == tree::CastKind.BOOL_TO_INT)
			{
				ir::Ref operand = self.gen_expr(n.cast.operand)!;
				if (self.has_cond_dummy_ty) self.cond_dummy_ref = operand;
				return self.add_branch(operand, true_label, false_label);
			}
		case BINARY_COND_EXPR:
			if (try cond = self.tree.value_of(n.conditional.cond))
			{
				return self.gen_bool_expr(cond.to_bool(self.comp) ? n.conditional.then_expr : n.conditional.else_expr, true_label, false_label);
			}
			ir::Ref new_false_label = self.builder.make_label("ternary.else");
			self.gen_bool_expr(n.conditional.cond, true_label, new_false_label)!;
			self.builder.start_block(new_false_label);
			if (self.has_cond_dummy_ty) self.cond_dummy_ref = self.builder.add_constant(value_interner::REF_ONE, self.cond_dummy_ty);
			return self.gen_bool_expr(n.conditional.else_expr, true_label, false_label);
		case COND_EXPR:
			if (try cond = self.tree.value_of(n.conditional.cond))
			{
				return self.gen_bool_expr(cond.to_bool(self.comp) ? n.conditional.then_expr : n.conditional.else_expr, true_label, false_label);
			}
			ir::Ref new_true_label = self.builder.make_label("ternary.then");
			ir::Ref new_false_label = self.builder.make_label("ternary.else");
			self.gen_bool_expr(n.conditional.cond, new_true_label, new_false_label)!;
			self.builder.start_block(new_true_label);
			self.gen_bool_expr(n.conditional.then_expr, true_label, false_label)!;
			self.builder.start_block(new_false_label);
			if (self.has_cond_dummy_ty) self.cond_dummy_ref = self.builder.add_constant(value_interner::REF_ONE, self.cond_dummy_ty);
			return self.gen_bool_expr(n.conditional.else_expr, true_label, false_label);
		default:
			break;
	}
	if (try val = self.tree.value_of(node))
	{
		if (!val.is_pointer(self.comp))
		{
			if (val.to_bool(self.comp))
			{
				if (true_label == self.bool_end_label) return self.add_bool_phi(!self.bool_invert);
				self.builder.add_jump(true_label);
			}
			else
			{
				if (false_label == self.bool_end_label) return self.add_bool_phi(self.bool_invert);
				self.builder.add_jump(false_label);
			}
			return;
		}
	}
	ir::Ref lhs = self.gen_expr(node)!;
	ir::Ref rhs = self.builder.add_constant(value::ZERO.ref(), self.gen_type(node.qt(self.tree))!);
	ir::Ref cmp = self.builder.add_inst(ir::InstTag.CMP_NE, { .bin = { .lhs = lhs, .rhs = rhs } }, value_interner::REF_I1);
	if (self.has_cond_dummy_ty) self.cond_dummy_ref = cmp;
	self.add_branch(cmp, true_label, false_label)!;
}

fn ir::Ref? CodeGen.gen_builtin_call(&self, builtins::Expanded builtin, type_store::NodeIndex[] arg_nodes, type_store::QualType qt)
{
	self.fail(string::tformat("TODO CodeGen.genBuiltinCall %s\n", builtins::name_from_tag(builtin.tag)))!;
	return ir::NONE;
}

fn ir::Ref? CodeGen.gen_call(&self, tree::NodeCall call)
{
	ir::Ref fn_ref;
	tree::Node callee = call.callee.get(self.tree);
	if (callee.kind != tree::NodeKind.CAST || callee.cast.kind != tree::CastKind.FUNCTION_TO_POINTER)
	{
		fn_ref = self.gen_expr(call.callee)!;
	}
	else
	{
		type_store::NodeIndex cur = callee.cast.operand;
		bool direct = false;
		while (true)
		{
			tree::Node current = cur.get(self.tree);
			switch (current.kind)
			{
				case PAREN_EXPR: case ADDR_OF_EXPR: case DEREF_EXPR:
					cur = current.unary.operand;
				case CAST:
					if (current.cast.kind != tree::CastKind.FUNCTION_TO_POINTER)
					{
						fn_ref = self.gen_expr(call.callee)!;
						direct = true;
						break;
					}
					cur = current.cast.operand;
				case DECL_REF_EXPR:
					String name_text = self.tree.tok_slice(current.decl_ref.name_tok);
					string_interner::StringId name = self.comp.intern_string(name_text);
					bool local = false;
					for (sz i = self.symbols.len(); i > 0; i--)
					{
						if (self.symbols[i - 1].name == name) { local = true; break; }
					}
					if (local)
					{
						fn_ref = self.gen_expr(call.callee)!;
					}
					else
					{
						fn_ref = self.builder.add_symbol(self.symbol_name(name_text, self.has_internal_linkage(current.decl_ref.decl)), value_interner::REF_PTR);
					}
					direct = true;
					break;
				default:
					fn_ref = self.gen_expr(call.callee)!;
					direct = true;
					break;
			}
			if (direct) break;
		}
	}
	ir::Ref[] args = alloc::new_array(&self.builder.arena, ir::Ref, call.args.len);
	foreach (i, arg_node : call.args) args[i] = self.gen_expr(arg_node)!;
	return self.builder.add_call(fn_ref, args, self.gen_type(call.qt)!);
}

fn ir::Ref? CodeGen.gen_compound_assign(&self, tree::NodeBinary bin)
{
	ir::Ref lhs = self.gen_lval(bin.lhs)!;
	bool old_has_dummy = self.has_compound_assign_dummy;
	ir::Ref old_dummy = self.compound_assign_dummy;
	defer { self.has_compound_assign_dummy = old_has_dummy; self.compound_assign_dummy = old_dummy; }
	self.has_compound_assign_dummy = true;
	self.compound_assign_dummy = lhs;
	ir::Ref rhs = self.gen_expr(bin.rhs)!;
	self.builder.add_store(lhs, rhs);
	return rhs;
}

<* `signed_tag` for a signed integer `qt`, else `unsigned_tag` (pointers compare unsigned). *>
fn ir::InstTag CodeGen.signed_tag(&self, type_store::QualType qt, ir::InstTag signed_tag, ir::InstTag unsigned_tag)
{
	if (qt.is_pointer(self.comp)) return unsigned_tag;
	if (!qt.is_int(self.comp)) return signed_tag;
	return qt.signedness(self.comp) == SIGNED ? signed_tag : unsigned_tag;
}

<* The signed or unsigned CMP_* tag for an ordered comparison, from its (converted) operand type. *>
fn ir::InstTag CodeGen.ordered_compare_tag(&self, tree::NodeKind kind, tree::NodeBinary bin)
{
	type_store::QualType qt = bin.lhs.qt(self.tree);
	switch (kind)
	{
		case LESS_THAN_EXPR: return self.signed_tag(qt, ir::InstTag.CMP_SLT, ir::InstTag.CMP_ULT);
		case LESS_THAN_EQUAL_EXPR: return self.signed_tag(qt, ir::InstTag.CMP_SLTE, ir::InstTag.CMP_ULTE);
		case GREATER_THAN_EXPR: return self.signed_tag(qt, ir::InstTag.CMP_SGT, ir::InstTag.CMP_UGT);
		case GREATER_THAN_EQUAL_EXPR: return self.signed_tag(qt, ir::InstTag.CMP_SGTE, ir::InstTag.CMP_UGTE);
		default: unreachable("not an ordered comparison");
	}
}

fn ir::Ref? CodeGen.gen_bin_op(&self, tree::NodeBinary bin, ir::InstTag tag)
{
	ir::Ref lhs = self.gen_expr(bin.lhs)!;
	ir::Ref rhs = self.gen_expr(bin.rhs)!;
	return self.add_bin(tag, lhs, rhs, bin.qt);
}

fn ir::Ref? CodeGen.gen_comparison(&self, tree::NodeBinary bin, ir::InstTag tag)
{
	ir::Ref lhs = self.gen_expr(bin.lhs)!;
	ir::Ref rhs = self.gen_expr(bin.rhs)!;
	return self.builder.add_inst(tag, { .bin = { .lhs = lhs, .rhs = rhs } }, value_interner::REF_I1);
}

fn ir::Ref? CodeGen.gen_ptr_arithmetic(&self, ir::Ref ptr, ir::Ref offset, type_store::QualType offset_type,
	type_store::QualType pointer_type, bool subtract)
{
	ulong size = pointer_type.child_type(self.comp).sizeof_or_null(self.comp) ?? 1;
	ulong offset_bits = offset_type.bit_sizeof(self.comp);
	ir::Ref wide_offset = offset;
	if (offset_bits < 64)
	{
		ir::InstTag extend = offset_type.signedness(self.comp) == SIGNED ? ir::InstTag.SEXT : ir::InstTag.ZEXT;
		wide_offset = self.builder.add_inst(extend, { .ref = offset }, value_interner::REF_I64);
	}
	else if (offset_bits > 64)
	{
		wide_offset = self.builder.add_inst(ir::InstTag.TRUNC, { .ref = offset }, value_interner::REF_I64);
	}
	if (subtract) wide_offset = self.builder.add_inst(ir::InstTag.NEGATE, { .ref = wide_offset }, value_interner::REF_I64);
	if (size != 1)
	{
		ir::Ref size_inst = self.builder.add_constant(value::int_u64(size, self.comp).ref(), value_interner::REF_I64);
		wide_offset = self.builder.add_inst(ir::InstTag.MUL,
			{ .bin = { .lhs = wide_offset, .rhs = size_inst } }, value_interner::REF_I64);
	}
	return self.builder.add_inst(ir::InstTag.ADD,
		{ .bin = { .lhs = ptr, .rhs = wide_offset } }, value_interner::REF_PTR);
}

fn ir::Ref? CodeGen.gen_ptr_difference(&self, ir::Ref lhs, ir::Ref rhs, type_store::QualType pointer_type,
	type_store::QualType result_type)
{
	ulong size = pointer_type.child_type(self.comp).sizeof_or_null(self.comp) ?? 1;
	ir::Ref difference = self.builder.add_inst(ir::InstTag.SUB,
		{ .bin = { .lhs = lhs, .rhs = rhs } }, value_interner::REF_I64);
	if (size != 1)
	{
		ir::Ref size_inst = self.builder.add_constant(value::int_u64(size, self.comp).ref(), value_interner::REF_I64);
		difference = self.builder.add_inst(ir::InstTag.SDIV,
			{ .bin = { .lhs = difference, .rhs = size_inst } }, value_interner::REF_I64);
	}
	value_interner::InternerRef result_ir_type = self.gen_type(result_type)!;
	if (result_ir_type == value_interner::REF_I64) return difference;
	if (result_type.bit_sizeof(self.comp) < 64)
	{
		return self.builder.add_inst(ir::InstTag.TRUNC, { .ref = difference }, result_ir_type);
	}
	return self.builder.add_inst(ir::InstTag.SEXT, { .ref = difference }, result_ir_type);
}

fn void? CodeGen.gen_initializer(&self, ir::Ref ptr, type_store::QualType dest_type, type_store::NodeIndex initializer)
{
	tree::Node node = initializer.get(self.tree);
	switch (node.kind)
	{
		case ARRAY_INIT_EXPR: case STRUCT_INIT_EXPR: case UNION_INIT_EXPR:
		case ARRAY_FILLER_EXPR: case DEFAULT_INIT_EXPR:
			return self.fail(string::tformat("TODO CodeGen.genInitializer %s\n", node.kind.name));
		case STRING_LITERAL_EXPR:
			value::Value val = self.tree.value_of(initializer)!!;
			ir::Ref string_ptr = self.builder.add_constant(val.ref(), value_interner::REF_PTR);
			if (dest_type.is(self.comp, type_store::TypeTag.ARRAY)) return self.fail("TODO memcpy\n");
			self.builder.add_store(ptr, string_ptr);
		default:
			ir::Ref result = self.gen_expr(initializer)!;
			self.builder.add_store(ptr, result);
	}
}

fn void? CodeGen.gen_var(&self, tree::NodeVariable decl, type_store::NodeIndex declaration = type_store::NODE_NULL)
{
	if (decl.thread_local) return self.fail("TODO CodeGen.genVar thread_local\n");
	if (decl.qt.is(self.comp, type_store::TypeTag.UNION)) return self.fail("TODO lower union types");

	bool has_declaration = ((type_store::NodeOptIndex)declaration) != type_store::NODE_NULL;
	bool file_scope = has_declaration && self.is_root_declaration(declaration);
	bool block_static = !file_scope && decl.storage_class == tree::VariableStorageClass.STATIC && !decl.implicit;
	bool block_extern = !file_scope && decl.storage_class == tree::VariableStorageClass.EXTERN && decl.initializer.is_null();
	bool implicit_var = decl.implicit;
	bool has_initializer = !decl.initializer.is_null();
	bool extern_declaration = decl.storage_class == tree::VariableStorageClass.EXTERN && !has_initializer;
	bool tentative = file_scope && !has_initializer && !extern_declaration;

	String source_name = self.tree.tok_slice(decl.name_tok);
	String name;
	bool already_emitted = false;
	if (implicit_var)
	{
		already_emitted = self.find_implicit_var(declaration).len != 0;
		name = self.implicit_var_name(declaration);
	}
	else if (block_static)
	{
		already_emitted = self.find_emitted_static(declaration).len != 0;
		name = self.block_static_name(declaration, source_name);
	}
	else if (block_extern && has_declaration)
	{
		name = self.symbol_name(source_name, self.has_internal_linkage(declaration));
	}
	else if (has_declaration)
	{
		name = self.symbol_name(source_name, self.has_internal_linkage(declaration));
	}
	else
	{
		name = source_name;
	}

	// __func__ is requested at each lvalue use, but denotes one function-local
	// static object. Static block declarations likewise emit once per AST node.
	if (already_emitted)
	{
		if (block_static)
		{
			string_interner::StringId local_name = self.comp.intern_string(source_name);
			self.symbols.push({ .name = local_name, .value = self.builder.add_symbol(name, value_interner::REF_PTR) });
		}
		return;
	}

	ulong size = 0;
	uint alignment = 0;
	if (!extern_declaration)
	{
		if (try resolved_size = decl.qt.sizeof_or_null(self.comp)) { size = resolved_size; }
		else if (tentative && decl.qt.is(self.comp, type_store::TypeTag.ARRAY))
		{
			size = decl.qt.child_type(self.comp).sizeof(self.comp);
		}
		else { return self.fail("TODO CodeGen.genVar incomplete object type\n"); }
		alignment = (uint)decl.qt.alignof(self.comp);
		if (decl.qt.is(self.comp, type_store::TypeTag.ARRAY) && size >= 16 && alignment < 16) alignment = 16;
	}

	bool common = tentative && !decl.implicit && decl.storage_class != tree::VariableStorageClass.STATIC &&
		self.comp.code_gen_options.common;
	ir::DataSection section = extern_declaration ? ir::DataSection.EXTERN :
		common ? ir::DataSection.COMMON :
		!has_initializer ? ir::DataSection.BSS : ir::DataSection.DATA;
	char[] data;
	if (section == ir::DataSection.DATA)
	{
		data = alloc::new_array(&self.builder.arena, char, (sz)size);
		for (usz i = 0; i < data.len; i++) data[i] = 0;
	}
	else
	{
		data = alloc::new_array(&self.builder.arena, char, 0);
	}

	ir::DataReloc[] relocations = alloc::new_array(&self.builder.arena, ir::DataReloc, 1);
	bool has_relocation = false;
	if (has_initializer)
	{
		self.write_global_initializer(decl.qt, decl.initializer.unwrap(), data, &relocations[0], &has_relocation)!;
	}
	ir::DataReloc[] used_relocations = has_relocation ? relocations[:1] : relocations[:0];
	ir::GlobalData global = {
		.size = size,
		.align = alignment,
		.bytes = data,
		.relocs = used_relocations,
		.section = section,
		.tentative = tentative,
		.own_section = self.comp.code_gen_options.data_sections,
	};
	ir::Linkage linkage = (block_static || implicit_var ||
		(has_declaration && self.has_internal_linkage(declaration))) ?
		ir::Linkage.INTERNAL : ir::Linkage.EXTERNAL;
	self.builder.add_global(name, linkage, global);

	if (block_static || block_extern)
	{
		string_interner::StringId local_name = self.comp.intern_string(source_name);
		self.symbols.push({ .name = local_name, .value = self.builder.add_symbol(name, value_interner::REF_PTR) });
	}
}

<* Write an unsigned machine value into target-endian bytes, zero extending. *>
fn void CodeGen.write_unsigned_bytes(&self, char[] data, usz start, usz count, ulong value)
{
	bool big_endian = self.comp.target.cpu.arch.big;
	for (usz i = 0; i < count; i++)
	{
		usz source_byte = big_endian ? count - 1 - i : i;
		data[start + i] = source_byte < ulong::size ? (char)(value >> (source_byte * 8)) : 0;
	}
}

<* Serialize an integer's low `bit_count` bits into target-endian storage. *>
fn void CodeGen.write_integer_bytes(&self, char[] data, usz start, usz byte_count, usz bit_count, value::Value val)
{
	char[] little = alloc::new_array(&self.builder.arena, char, (sz)byte_count);
	for (usz i = 0; i < little.len; i++) little[i] = 0;
	if (!val.is_zero(self.comp))
	{
		value_interner::BigIntSpace space;
		bigint::BigIntConst integer = val.to_big_int(&space, self.comp);
		for (usz i = 0; i < byte_count; i++)
		{
			usz limb_index = i / 8;
			if (limb_index >= integer.limbs.len) break;
			little[i] = (char)(integer.limbs[limb_index] >> ((i % 8) * 8));
		}
		if (!integer.positive)
		{
			for (usz i = 0; i < byte_count; i++) little[i] = ~little[i];
			usz i = 0;
			while (i < byte_count)
			{
				uint sum = ((uint)(char)little[i] & 0xFF) + 1;
				little[i] = (char)sum;
				if (sum <= 0xFF) break;
				i++;
			}
		}
	}
	if (bit_count % 8 != 0 && byte_count > 0)
	{
		little[byte_count - 1] &= (char)((1 << (bit_count % 8)) - 1);
	}
	bool big_endian = self.comp.target.cpu.arch.big;
	for (usz i = 0; i < byte_count; i++)
	{
		usz dest_byte = big_endian ? byte_count - 1 - i : i;
		data[start + i] = little[dest_byte];
	}
}

<* Serialize a floating constant's raw target-format bits, including ABI padding. *>
fn void CodeGen.write_float_bytes(&self, char[] data, usz start, usz byte_count, ulong bit_count, value::Value val)
{
	value_interner::KeyFloatTag tag;
	switch (bit_count)
	{
		case 16: tag = value_interner::KeyFloatTag.F16;
		case 32: tag = value_interner::KeyFloatTag.F32;
		case 64: tag = value_interner::KeyFloatTag.F64;
		case 80: tag = value_interner::KeyFloatTag.F80;
		case 128: tag = value_interner::KeyFloatTag.F128;
		default: unreachable("unsupported floating storage width");
	}
	value_interner::KeyFloat bits = val.to_float(tag, self.comp);
	ulong low = 0;
	ulong high = 0;
	switch (bits.tag)
	{
		case F16: low = bits.f16;
		case F32: low = bits.f32;
		case F64: low = bits.f64;
		case F80: low = bits.f80.lo; high = bits.f80.hi;
		case F128: low = bits.f128.lo; high = bits.f128.hi;
	}
	usz repr_bytes = (usz)((bit_count + 7) / 8);
	assert(repr_bytes <= byte_count);
	usz padding = byte_count - repr_bytes;
	bool big_endian = self.comp.target.cpu.arch.big;
	usz bits_start = big_endian ? start + padding : start;
	for (usz i = 0; i < repr_bytes; i++)
	{
		usz source_byte = big_endian ? repr_bytes - 1 - i : i;
		ulong word = source_byte < 8 ? low : high;
		usz shift = (source_byte < 8 ? source_byte : source_byte - 8) * 8;
		data[bits_start + i] = (char)(word >> shift);
	}
}

<* Materialize a string literal as an internal byte global and return its symbol. *>
fn String? CodeGen.string_global(&self, type_store::NodeIndex node)
{
	String existing = self.find_emitted_string(node);
	if (existing.len != 0) return existing;
	value::Value val;
	if (try found = self.tree.value_of(node))
	{
		val = found;
	}
	else
	{
		self.fail("TODO CodeGen.genVar string value\n")!;
		return compilation::FATAL_ERROR~;
	}
	value_interner::InternerKey key = self.comp.interner.get(val.ref());
	if (key.tag != value_interner::InternerKeyTag.BYTES)
	{
		self.fail("TODO CodeGen.genVar string value\n")!;
		return compilation::FATAL_ERROR~;
	}
	String bytes = (String)val.to_bytes(self.comp);
	DString generated;
	generated.init(&self.builder.arena);
	generated.appendf(".str.%s.%d", self.current_fn, self.string_counter);
	self.string_counter++;
	if (self.tu_id >= 0) generated.appendf(".tu%d", self.tu_id);
	String name = generated.str_view();
	ir::GlobalData global = {
		.size = (ulong)bytes.len,
		.align = 1,
		.bytes = (char[])bytes,
		.relocs = alloc::new_array(&self.builder.arena, ir::DataReloc, 0),
		.section = ir::DataSection.RODATA,
		.tentative = false,
		.own_section = false,
	};
	self.builder.add_global(name, ir::Linkage.INTERNAL, global);
	self.emitted_strings.push({ .node = node, .name = name });
	return name;
}

<* Serialize a supported constant initializer for a global object. *>
fn void? CodeGen.write_global_initializer(&self, type_store::QualType qt, type_store::NodeIndex initializer,
	char[] data, ir::DataReloc* relocation, bool* has_relocation)
{
	assert(self.comp.target.cpu.arch == target::Arch.X86_64 && !self.comp.target.cpu.arch.big,
		"global initializer serialization requires x86_64 little-endian");
	tree::Node init_node = initializer.get(self.tree);
	if (init_node.kind == tree::NodeKind.COMPOUND_LITERAL_EXPR)
	{
		return self.fail("TODO CodeGen.genVar compound literal\n");
	}
	if (qt.scalar_kind(self.comp) == type_store::ScalarKind.COMPLEX_INT ||
		qt.scalar_kind(self.comp) == type_store::ScalarKind.COMPLEX_FLOAT)
	{
		return self.fail("TODO CodeGen.genVar complex initializer\n");
	}

	if (qt.is(self.comp, type_store::TypeTag.ARRAY))
	{
		value::Value val;
		if (try found = self.tree.value_of(initializer))
		{
			val = found;
		}
		else
		{
			return self.fail(string::tformat("TODO CodeGen.genVar initializer %s\n", init_node.kind.name));
		}
		value_interner::InternerKey key = self.comp.interner.get(val.ref());
		if (key.tag != value_interner::InternerKeyTag.BYTES)
		{
			return self.fail(string::tformat("TODO CodeGen.genVar initializer %s\n", init_node.kind.name));
		}
		char[] bytes = val.to_bytes(self.comp);
		usz copy_count = bytes.len < data.len ? bytes.len : data.len;
		data[:copy_count] = bytes[:copy_count];
		return;
	}

	if (init_node.kind == tree::NodeKind.ARRAY_INIT_EXPR || init_node.kind == tree::NodeKind.STRUCT_INIT_EXPR ||
		init_node.kind == tree::NodeKind.UNION_INIT_EXPR || init_node.kind == tree::NodeKind.ARRAY_FILLER_EXPR ||
		init_node.kind == tree::NodeKind.DEFAULT_INIT_EXPR)
	{
		return self.fail(string::tformat("TODO CodeGen.genVar initializer %s\n", init_node.kind.name));
	}
	type_store::NodeIndex string_node = initializer;
	while (true)
	{
		tree::Node string_expr = string_node.get(self.tree);
		if (string_expr.kind == tree::NodeKind.CAST && string_expr.cast.kind == tree::CastKind.ARRAY_TO_POINTER && string_expr.cast.implicit)
		{
			string_node = string_expr.cast.operand;
			continue;
		}
		if (string_expr.kind == tree::NodeKind.PAREN_EXPR)
		{
			string_node = string_expr.unary.operand;
			continue;
		}
		break;
	}
	value::Value val;
	if (try found = self.tree.value_of(initializer))
	{
		val = found;
	}
	else if (qt.is(self.comp, type_store::TypeTag.POINTER) && string_node.get(self.tree).kind == tree::NodeKind.STRING_LITERAL_EXPR)
	{
		if (try string_value = self.tree.value_of(string_node))
		{
			val = string_value;
		}
		else
		{
			return self.fail(string::tformat("TODO CodeGen.genVar initializer %s\n", init_node.kind.name));
		}
	}
	else
	{
		return self.fail(string::tformat("TODO CodeGen.genVar initializer %s\n", init_node.kind.name));
	}
	if (data.len == 0) return self.fail("TODO CodeGen.genVar zero-sized initializer\n");
	value_interner::InternerKey key = self.comp.interner.get(val.ref());

	if (qt.is(self.comp, type_store::TypeTag.POINTER))
	{
		if (key.tag == value_interner::InternerKeyTag.BYTES)
		{
			if (string_node.get(self.tree).kind != tree::NodeKind.STRING_LITERAL_EXPR)
			{
				return self.fail("TODO CodeGen.genVar bytes pointer initializer\n");
			}
			*relocation = { .offset = 0, .symbol = self.string_global(string_node)!, .addend = 0 };
			*has_relocation = true;
			return;
		}
		if (key.tag == value_interner::InternerKeyTag.NULL ||
			(key.tag == value_interner::InternerKeyTag.INT && val.is_zero(self.comp)))
		{
			self.write_unsigned_bytes(data, 0, data.len, self.comp.target.null_repr());
			return;
		}
		if (key.tag != value_interner::InternerKeyTag.POINTER)
		{
			return self.fail("TODO CodeGen.genVar pointer initializer\n");
		}
		type_store::NodeIndex target_node = (type_store::NodeIndex)key.pointer.node;
		tree::Node target = target_node.get(self.tree);
		String symbol;
		switch (target.kind)
		{
			case VARIABLE:
				if (target.variable.implicit)
				{
					symbol = self.find_implicit_var(target_node);
					if (symbol.len == 0) return self.fail("TODO CodeGen.genVar address of implicit variable\n");
				}
				else if (self.find_emitted_static(target_node).len != 0)
				{
					symbol = self.find_emitted_static(target_node);
				}
				else if (!self.is_root_declaration(target_node) &&
					target.variable.storage_class != tree::VariableStorageClass.EXTERN)
				{
					return self.fail("TODO CodeGen.genVar address of block static\n");
				}
				else
				{
					symbol = self.symbol_name(self.tree.tok_slice(target.variable.name_tok), self.has_internal_linkage(target_node));
				}
			case FUNCTION:
				symbol = self.symbol_name(self.tree.tok_slice(target.function.name_tok), self.has_internal_linkage(target_node));
			case STRING_LITERAL_EXPR:
				symbol = self.string_global(target_node)!;
			default:
				return self.fail("TODO CodeGen.genVar address initializer target\n");
		}
		value::Value offset_value = value::from_ref(key.pointer.offset);
		long addend;
		if (try resolved_offset = offset_value.to_i64(self.comp))
		{
			addend = resolved_offset;
		}
		else
		{
			return self.fail("TODO CodeGen.genVar address initializer offset\n");
		}
		*relocation = { .offset = 0, .symbol = symbol, .addend = addend };
		*has_relocation = true;
		return;
	}

	type_store::ScalarKind scalar = qt.scalar_kind(self.comp);
	if (scalar == type_store::ScalarKind.BOOL || scalar == type_store::ScalarKind.ENUM ||
		scalar == type_store::ScalarKind.INT)
	{
		if (key.tag == value_interner::InternerKeyTag.INT && key.int_val.tag == value_interner::KeyIntTag.BIG_INT)
		{
			return self.fail("TODO CodeGen.genVar big integer initializer\n");
		}
		if (qt.is(self.comp, type_store::TypeTag.BOOL))
		{
			self.write_unsigned_bytes(data, 0, data.len, val.is_zero(self.comp) ? 0 : 1);
		}
		else
		{
			usz bit_count = (usz)qt.bit_sizeof(self.comp);
			usz byte_count = (bit_count + 7) / 8;
			if (byte_count > data.len) return self.fail("TODO CodeGen.genVar integer storage size\n");
			self.write_integer_bytes(data, 0, byte_count, bit_count, val);
		}
		return;
	}
	if (scalar == type_store::ScalarKind.FLOAT)
	{
		ulong bit_count = qt.bit_sizeof(self.comp);
		if (bit_count == 80 || bit_count == 128) return self.fail("TODO CodeGen.genVar long double initializer\n");
		if (bit_count != 16 && bit_count != 32 && bit_count != 64)
		{
			return self.fail("TODO CodeGen.genVar unsupported float width\n");
		}
		usz repr_bytes = (usz)((bit_count + 7) / 8);
		if (repr_bytes > data.len) return self.fail("TODO CodeGen.genVar float storage size\n");
		usz start = self.comp.target.cpu.arch.big ? data.len - repr_bytes : 0;
		self.write_float_bytes(data, start, data.len - start, bit_count, val);
		return;
	}
	return self.fail(string::tformat("TODO CodeGen.genVar initializer %s\n", init_node.kind.name));
}
