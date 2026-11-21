// Source-aware expression rendering and typed AST dumps (Tree.zig).
module aro::frontend::c::tree;
import std::core::string::ansi, aro::frontend::c::tokens, aro::frontend::c::tokenizer, aro::frontend::c::type_store, aro::frontend::c::value, aro::frontend::c::attribute, aro::frontend::c::attribute_map, aro::frontend::c::diagnostics, aro::frontend::c::compilation;
import std::io, std::core::dstring;

<* `w` is a pointer so appends that grow the buffer reach the caller. *>
fn void Tree.write(&self, NodeIndex index, DString* w)
{
	Node n = index.get(self);
	switch (n.kind)
	{
		case CAST:
			if (!n.cast.implicit)
			{
				w.append_char('('); n.cast.qt.print_desugared(self.comp, w)!!; w.append_char(')');
			}
			self.write(n.cast.operand, w);
		case PAREN_EXPR: w.append_char('('); self.write(n.unary.operand, w); w.append_char(')');
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
		case MOD_EXPR:
			if (n.kind == COMMA_EXPR)
			{
				self.write(n.binary.lhs, w); w.append_string(", "); self.write(n.binary.rhs, w);
			} else
			{
				self.write(n.binary.lhs, w); w.append_char(' '); w.append_string(self.tok_slice(n.binary.op_tok)); w.append_char(' '); self.write(n.binary.rhs, w);
			}
		case ADDR_OF_EXPR:
		case DEREF_EXPR:
		case PLUS_EXPR:
		case NEGATE_EXPR:
		case BIT_NOT_EXPR:
		case BOOL_NOT_EXPR:
		case PRE_INC_EXPR:
		case PRE_DEC_EXPR:
			w.append_string(self.tok_slice(n.unary.op_tok)); self.write(n.unary.operand, w);
		case IMAG_EXPR:
		case REAL_EXPR:
			w.append_string(self.tok_slice(n.unary.op_tok)); w.append_char(' '); self.write(n.unary.operand, w);
		case POST_INC_EXPR:
		case POST_DEC_EXPR:
			self.write(n.unary.operand, w); w.append_string(self.tok_slice(n.unary.op_tok));
		case BOOL_LITERAL:
		case NULLPTR_LITERAL:
		case INT_LITERAL:
		case FLOAT_LITERAL:
			w.append_string(self.tok_slice(n.literal.literal_tok));
		case CHAR_LITERAL: w.append_string(self.tok_slice(n.char_literal.literal_tok));
		case STRING_LITERAL_EXPR:
			if (try string_value = self.value_of(index))
			{
				string_value.print(n.char_literal.qt, self.comp, w)!!;
			}
			else
			{
				w.append_string(self.tok_slice(n.char_literal.literal_tok));
			}
		case IMAGINARY_LITERAL: self.write(n.unary.operand, w);
		case SIZEOF_EXPR:
		case ALIGNOF_EXPR:
		case COUNTOF_EXPR:
			w.append_string(self.tok_slice(n.type_info.op_tok));
			if (!n.type_info.expr.is_null())
			{
				w.append_char(' '); self.write(n.type_info.expr.unwrap(), w);
			}
			else
			{
				w.append_char('('); n.type_info.operand_qt.print_desugared(self.comp, w)!!; w.append_char(')');
			}
		case DECL_REF_EXPR:
		case ENUMERATION_REF: w.append_string(self.tok_slice(n.decl_ref.name_tok));
		case BUILTIN_REF: w.append_string(self.tok_slice(n.builtin_ref.name_tok));
		case ARRAY_ACCESS_EXPR:
			self.write(n.array_access.base, w); w.append_char('['); self.write(n.array_access.index, w); w.append_char(']');
		case CALL_EXPR:
			self.write(n.call.callee, w); w.append_char('(');
			foreach (i, arg : n.call.args)
			{
				if (i != 0) w.append_string(", "); self.write(arg, w);
			}
			w.append_char(')');
		case BUILTIN_CALL_EXPR:
			w.append_string(self.tok_slice(n.builtin_call.builtin_tok)); w.append_char('(');
			foreach (i, arg : n.builtin_call.args)
			{
				if (i != 0) w.append_string(", "); self.write(arg, w);
			}
			w.append_char(')');
		case BUILTIN_TYPES_COMPATIBLE_P:
			w.append_string(self.tok_slice(n.types_compatible.builtin_tok)); w.append_char('(');
			n.types_compatible.lhs.print_desugared(self.comp, w)!!; w.append_string(", "); n.types_compatible.rhs.print_desugared(self.comp, w)!!; w.append_char(')');
		case GENERIC_EXPR:
			w.append_string(self.tok_slice(n.generic.generic_tok)); w.append_char('('); self.write(n.generic.controlling, w);
			foreach (arg : n.generic.rest)
			{
				w.append_string(", "); self.write(arg, w);
			}
			w.append_string(", "); self.write(n.generic.chosen, w); w.append_char(')');
		case GENERIC_ASSOCIATION_EXPR: n.generic_association.association_qt.print_desugared(self.comp, w)!!; w.append_string(": "); self.write(n.generic_association.expr, w);
		case GENERIC_DEFAULT_EXPR: w.append_string(self.tok_slice(n.generic_default.default_tok)); w.append_string(": "); self.write(n.generic_default.expr, w);
		case BINARY_COND_EXPR:
			self.write(n.conditional.cond, w); w.append_string(" ?: "); self.write(n.conditional.else_expr, w);
		case COND_EXPR:
			self.write(n.conditional.cond, w); w.append_string(" ? "); self.write(n.conditional.then_expr, w); w.append_string(" : "); self.write(n.conditional.else_expr, w);
		case BUILTIN_CHOOSE_EXPR:
			w.append_string("__builtin_choose_expr("); self.write(n.conditional.cond, w); w.append_string(", "); self.write(n.conditional.then_expr, w); w.append_string(", "); self.write(n.conditional.else_expr, w); w.append_char(')');
		case BUILTIN_VA_ARG_PACK:
		case BUILTIN_VA_ARG_PACK_LEN: w.append_string(self.tok_slice(n.va_arg_pack.builtin_tok)); w.append_string("()");
		case MEMBER_ACCESS_EXPR:
		case MEMBER_ACCESS_PTR_EXPR:
			self.write(n.member_access.base, w);
			QualType bqt = n.member_access.base.qt(self);
			if (try pointer_type = bqt.get(self.comp, POINTER)) bqt = pointer_type.pointer.child;
			if (try record_type = bqt.get_record(self.comp))
			{
				String name = record_type.fields[n.member_access.member_index].name.lookup(self.comp);
				if (name.len != 0 && name[0] != '(')
				{
					w.append_string(self.tok_slice(n.member_access.access_tok)); w.append_string(name);
				}
			}
		default: w.append_string("<node>");
	}
}

fn void? Tree.dump(&self, Terminal term)
{
	foreach (i : self.root_decls)
	{
		self.dump_node(i, 0, term)!; term.writer.write_byte('\n')!;
	}
	if (&term.writer.flush) term.writer.flush()!;
}

fn void? Tree.dump_attribute(&self, AttrRef ref, OutStream w)
{
	Attribute a = self.attr_map.get(ref);
	String attr_name = namespaced_name(a.name);
	if (a.syntax == STANDARD)
	{
		io::fprintf(w, "%s::", a.name.ns.name)!;
	}
	if (a.name.ns != ARO) io::write_all(w, attr_name)!;
	switch (a.args.tag)
	{
		case VISIBILITY: io::fprintf(w, ": %s", a.args.visibility.name)!;
		case ALIGNMENT:
			if (a.args.alignment.has_alignment)
			{
				io::fprintf(w, ": %d", a.args.alignment.alignment)!;
			}
			else
			{
				io::write_all(w, ": null")!;
			}
		case WARNING: io::fprintf(w, ": %s", a.args.warning)!;
		case ERROR: io::fprintf(w, ": %s", a.args.error_msg)!;
		case SECTION: io::fprintf(w, ": %s", a.args.section)!;
		case DEPRECATED:
			io::write_all(w, ": { ")!;
			bool wrote_field = false;
			if (a.args.deprecated.has_msg)
			{
				io::fprintf(w, "msg: %s", a.args.deprecated.msg)!; wrote_field = true;
			}
			if (a.args.deprecated.has_replacement)
			{
				if (wrote_field) io::write_all(w, ", ")!; io::fprintf(w, "replacement: %s", a.args.deprecated.replacement)!;
			}
			io::write_all(w, " }")!;
		case UNAVAILABLE:
			if (a.args.unavailable.has_msg)
			{
				io::fprintf(w, ": %s", a.args.unavailable.msg)!;
			}
			else
			{
				io::write_all(w, ": null")!;
			}
		case WARN_UNUSED_RESULT:
			if (a.args.warn_unused_result.has_msg)
			{
				io::fprintf(w, ": %s", a.args.warn_unused_result.msg)!;
			}
			else
			{
				io::write_all(w, ": null")!;
			}
		case NONNULL:
			io::write_all(w, ": {")!;
			foreach (i, pos : a.args.nonnull)
			{
				if (i != 0) io::write_all(w, ", ")!; io::fprintf(w, "%d", pos)!;
			}
			io::write_all(w, " }")!;
		default:
			switch (a.args.tag)
			{
			case ALLOCATOR:
			case ALWAYS_INLINE:
			case APPDOMAIN:
			case ARTIFICIAL:
			case COLD:
			case COMMON:
			case CONST:
			case DESIGNATED_INIT:
			case DLLEXPORT:
			case DLLIMPORT:
			case EXTERNALLY_VISIBLE:
			case FALLTHROUGH:
			case FLATTEN:
			case GNU_INLINE:
			case HOT:
			case INTERRUPT:
			case INTERRUPT_HANDLER:
			case JITINTRINSIC:
			case LEAF:
			case MALLOC:
			case MAY_ALIAS:
			case NAKED:
			case NO_ADDRESS_SAFETY_ANALYSIS:
			case NO_ICF:
			case NO_INSTRUMENT_FUNCTION:
			case NO_PROFILE_INSTRUMENT_FUNCTION:
			case NO_REORDER:
			case NO_SANITIZE_ADDRESS:
			case NO_SANITIZE_COVERAGE:
			case NO_SANITIZE_THREAD:
			case NO_SANITIZE_UNDEFINED:
			case NO_SPLIT_STACK:
			case NO_STACK_LIMIT:
			case NO_STACK_PROTECTOR:
			case NOALIAS:
			case NOCLONE:
			case NOCOMMON:
			case NOINIT:
			case NOINLINE:
			case NOIPA:
			case NONSTRING:
			case NOPLT:
			case NORETURN:
			case NOTHROW:
			case PATCHABLE_FUNCTION_ENTRY:
			case PACKED:
			case PERSISTENT:
			case PURE:
			case REPRODUCIBLE:
			case RETAIN:
			case RETURNS_NONNULL:
			case RETURNS_TWICE:
			case SELECTANY:
			case SINGLE:
			case STACK_PROTECT:
			case TRANSPARENT_UNION:
			case UNSEQUENCED:
			case UNUSED:
			case USED:
			case WEAK: {}
			default: io::write_all(w, ": <any>")!;
		}
	}
	w.write_byte('\n')!;
}

fn String namespaced_name(Namespaced n)
{
	switch (n.ns)
	{
		case STANDARD: return n.standard.name;
		case GNU: return n.gnu.name;
		case CLANG: return n.clang.name;
		case DECLSPEC: return n.declspec.name;
		case MSVC: return n.msvc.name;
		case RISCV: return n.riscv.name;
		case KEYWORD: return n.keyword.name;
		case ARO: return "";
	}
}

fn void? Tree.dump_node(&self, NodeIndex index, uint level, Terminal term)
{
	Node n = index.get(self);
	OutStream w = term.writer;
	for (uint j = 0; j < level; j++) w.write_byte(' ')!;
	if (term.mode == diagnostics::ColorMode.NO_COLOR)
	{
		if (n.is_implicit()) io::write_all(w, "implicit ")!;
	}
	else if (n.is_implicit())
	{
		set_bright_blue(term)!;
	}
	else
	{
		term.set_color(ansi::Ansi.BRIGHT_CYAN)!;
	}
	io::fprintf(w, "%s", n.kind.name)!;
	if (try qt = index.qt_or_null(self))
	{
		io::write_all(w, ": ")!;
		if (n.kind == CAST)
		{
			term.set_color(ansi::Ansi.WHITE)!; io::fprintf(w, "(%s) ", n.cast.kind.name)!;
		}
		term.set_color(ansi::Ansi.BRIGHT_MAGENTA)!;
		w.write_byte('\'')!; qt.dump(self.comp, w)!; w.write_byte('\'')!;
	}
	if (self.is_lval(index))
	{
		set_bright_yellow(term)!; io::write_all(w, " lvalue")!;
	}
	if (self.is_bitfield(index))
	{
		set_bright_yellow(term)!; io::write_all(w, " bitfield")!;
	}
	if (n.kind == ASM_STMT)
	{
		set_bright_yellow(term)!;
		if (n.asm_stmt.quals.is_inline) io::write_all(w, " inline")!;
		if (n.asm_stmt.quals.is_volatile) io::write_all(w, " volatile")!;
		if (n.asm_stmt.quals.is_goto) io::write_all(w, " goto")!;
	}
	if (try value = self.value_of(index))
	{
		term.set_color(ansi::Ansi.BRIGHT_GREEN)!; io::write_all(w, " (value: ")!;
		NestedPrint nested;
		if (value.print(index.qt(self), self.comp, w, &nested)!)
		{
			if (((NodeIndex)nested.node).kind(self) == COMPOUND_LITERAL_EXPR)
			{
				io::write_all(w, "(compound literal) ")!;
				nested.offset.print(self.comp.type_store.ptrdiff, self.comp, w)!;
			} else
			{
				value::print_pointer(nested.offset, self.tok_slice(((NodeIndex)nested.node).tok(self)), self.comp, w)!;
			}
		}
		w.write_byte(')')!;
	}
	if (n.kind == RETURN_STMT && n.return_stmt.operand == IMPLICIT && n.return_stmt.implicit_value)
	{
		set_bright_blue(term)!; io::write_all(w, " (value: 0)")!;
	}
	w.write_byte('\n')!;
	AttrRef[] attrs = self.attr_map.attrs(index.pack());
	if (attrs.len != 0)
	{
		set_bright_yellow(term)!; foreach (attr : attrs)
		{
			for (uint j = 0; j < level + 1; j++) w.write_byte(' ')!; self.dump_attribute(attr, w)!;
		}
	}
	term.set_color(ansi::Ansi.RESET)!;
	self.dump_children(n, level, term)!;
}

fn void? Tree.dump_children(&self, Node n, uint level, Terminal term)
{
	switch (n.kind)
	{
		case EMPTY_DECL:
		case STRUCT_FORWARD_DECL:
		case UNION_FORWARD_DECL:
		case ENUM_FORWARD_DECL:
		case NULL_STMT:
		case BUILTIN_VA_ARG_PACK:
		case BUILTIN_VA_ARG_PACK_LEN:
		case BOOL_LITERAL:
		case NULLPTR_LITERAL:
		case INT_LITERAL:
		case CHAR_LITERAL:
		case FLOAT_LITERAL:
		case STRING_LITERAL_EXPR:
		case DEFAULT_INIT_EXPR:
		case COND_DUMMY_EXPR:
		case COMPOUND_ASSIGN_DUMMY_EXPR: {}
		case STATIC_ASSERT:
			self.dump_child(term, level + 1, "condition:", n.static_assert.cond)!;
			if (!n.static_assert.message.is_null()) self.dump_child(term, level + 1, "diagnostic:", n.static_assert.message.unwrap())!;
		case GLOBAL_ASM: self.dump_node(n.global_asm.asm_str, level + 2, term)!;
		case FUNCTION:
			dump_function_header(term, level + 1, n.function.is_static, n.function.is_inline, self.tok_slice(n.function.name_tok))!;
			if (!n.function.body.is_null()) self.dump_child(term, level + 1, "body:", n.function.body.unwrap())!;
			if (!n.function.definition.is_null()) dump_index_line(term, level + 1, "definition: ", (uint)n.function.definition.unwrap())!;
		case TYPEDEF: dump_named_field(term, level + 1, "name: ", self.tok_slice(n.type_def.name_tok))!;
		case PARAM:
			if (n.param.storage_class == ParamStorageClass.REGISTER)
			{
				dump_prefix_named_field(term, level + 1, "register ", "name: ", self.tok_slice(n.param.name_tok))!;
			}
			else
			{
				dump_named_field(term, level + 1, "name: ", self.tok_slice(n.param.name_tok))!;
			}
		case VARIABLE:
			dump_variable_header(term, level + 1, n.variable.storage_class, n.variable.thread_local, self.tok_slice(n.variable.name_tok))!;
			if (!n.variable.initializer.is_null()) self.dump_child(term, level + 1, "init:", n.variable.initializer.unwrap())!;
			if (!n.variable.definition.is_null()) dump_index_line(term, level + 1, "definition: ", (uint)n.variable.definition.unwrap())!;
		case ENUM_FIELD:
			dump_named_field(term, level + 1, "name: ", self.tok_slice(n.enum_field.name_tok))!;
			if (!n.enum_field.init.is_null()) self.dump_child(term, level + 1, "init:", n.enum_field.init.unwrap())!;
		case RECORD_FIELD:
			tokenizer::TokenId id = self.tokens[n.record_field.name_or_first_tok].id;
			if (id.is_identifier()) dump_named_field(term, level + 1, "name: ", self.tok_slice(n.record_field.name_or_first_tok))!;
			if (!n.record_field.bit_width.is_null()) self.dump_child(term, level + 1, "bits:", n.record_field.bit_width.unwrap())!;
		case COMPOUND_STMT:
			foreach (i, child : n.compound_stmt.body)
			{
				if (i != 0) term.writer.write_byte('\n')!; self.dump_node(child, level + 2, term)!;
			}
		case STRUCT_DECL:
		case UNION_DECL:
		case ENUM_DECL:
			foreach (i, child : n.container_decl.fields)
			{
				if (i != 0) term.writer.write_byte('\n')!; self.dump_node(child, level + 2, term)!;
			}
		case ARRAY_INIT_EXPR:
		case STRUCT_INIT_EXPR:
			foreach (i, child : n.container_init.items)
			{
				if (i != 0) term.writer.write_byte('\n')!; self.dump_node(child, level + 2, term)!;
			}
		case UNION_INIT_EXPR:
			dump_number_line(term, level + 1, "field index: ", n.union_init.field_index)!;
			if (!n.union_init.initializer.is_null()) self.dump_node(n.union_init.initializer.unwrap(), level + 2, term)!;
		case COMPOUND_LITERAL_EXPR:
			if (n.compound_literal.storage_class != CompoundLiteralStorageClass.AUTO || n.compound_literal.thread_local)
			{
				for (uint j = 0; j < level; j++) term.writer.write_byte(' ')!;
				term.set_color(ansi::Ansi.BRIGHT_GREEN)!;
				if (n.compound_literal.storage_class == CompoundLiteralStorageClass.STATIC) io::write_all(term.writer, " static")!;
				if (n.compound_literal.storage_class == CompoundLiteralStorageClass.REGISTER) io::write_all(term.writer, " register")!;
				if (n.compound_literal.thread_local) io::write_all(term.writer, " thread_local")!;
				term.writer.write_byte('\n')!; term.set_color(ansi::Ansi.RESET)!;
			}
			self.dump_node(n.compound_literal.initializer, level + 1, term)!;
		case LABELED_STMT:
			dump_named_color_field(term, level + 1, "label: ", self.tok_slice(n.labeled_stmt.label_tok), ansi::Ansi.BRIGHT_GREEN)!;
			self.dump_child(term, level + 1, "stmt:", n.labeled_stmt.body)!;
		case CASE_STMT:
			if (!n.case_stmt.end.is_null())
			{
				self.dump_child(term, level + 1, "range start:", n.case_stmt.start)!;
				self.dump_child(term, level + 1, "range end:", n.case_stmt.end.unwrap())!;
			} else
			{
				self.dump_child(term, level + 1, "value:", n.case_stmt.start)!;
			}
			self.dump_child(term, level + 1, "stmt:", n.case_stmt.body)!;
		case DEFAULT_STMT: self.dump_child(term, level + 1, "stmt:", n.default_stmt.body)!;
		case BINARY_COND_EXPR:
		case COND_EXPR:
		case BUILTIN_CHOOSE_EXPR:
			self.dump_child(term, level + 1, "cond:", n.conditional.cond)!;
			self.dump_child(term, level + 1, "then:", n.conditional.then_expr)!;
			self.dump_child(term, level + 1, "else:", n.conditional.else_expr)!;
		case BUILTIN_TYPES_COMPATIBLE_P:
			dump_type_line(term, level + 1, "lhs: ", n.types_compatible.lhs, self.comp)!;
			dump_type_line(term, level + 1, "rhs: ", n.types_compatible.rhs, self.comp)!;
		case BUILTIN_CONVERTVECTOR: self.dump_child(term, level + 1, "operand:", n.convertvector.operand)!;
		case BUILTIN_SHUFFLEVECTOR:
			self.dump_child(term, level + 1, "lhs:", n.shufflevector.lhs)!;
			self.dump_child(term, level + 1, "rhs:", n.shufflevector.rhs)!;
			if (n.shufflevector.indexes.len != 0)
			{
				dump_text_line(term, level + 1, "indexes:")!;
				foreach (child : n.shufflevector.indexes) self.dump_node(child, level + 2, term)!;
			}
		case IF_STMT:
			if (!n.if_stmt.init.is_null()) self.dump_child(term, level + 1, "init:", n.if_stmt.init.unwrap())!;
			self.dump_child(term, level + 1, "cond:", n.if_stmt.cond)!;
			self.dump_child(term, level + 1, "then:", n.if_stmt.then_body)!;
			if (!n.if_stmt.else_body.is_null()) self.dump_child(term, level + 1, "else:", n.if_stmt.else_body.unwrap())!;
		case SWITCH_STMT:
			if (!n.switch_stmt.init.is_null()) self.dump_child(term, level + 1, "init:", n.switch_stmt.init.unwrap())!;
			self.dump_child(term, level + 1, "cond:", n.switch_stmt.cond)!;
			self.dump_child(term, level + 1, "body:", n.switch_stmt.body)!;
		case WHILE_STMT:
			self.dump_child(term, level + 1, "cond:", n.while_stmt.cond)!;
			self.dump_child(term, level + 1, "body:", n.while_stmt.body)!;
		case DO_WHILE_STMT:
			self.dump_child(term, level + 1, "cond:", n.do_while_stmt.cond)!;
			self.dump_child(term, level + 1, "body:", n.do_while_stmt.body)!;
		case FOR_STMT:
			if (!n.for_stmt.init.is_null()) self.dump_child(term, level + 1, "init:", n.for_stmt.init.unwrap())!;
			if (!n.for_stmt.cond.is_null()) self.dump_child(term, level + 1, "cond:", n.for_stmt.cond.unwrap())!;
			if (!n.for_stmt.incr.is_null()) self.dump_child(term, level + 1, "incr:", n.for_stmt.incr.unwrap())!;
			self.dump_child(term, level + 1, "body:", n.for_stmt.body)!;
		case ADDR_OF_LABEL:
			dump_named_color_field(term, level + 1, "label: ", self.tok_slice(n.addr_of_label.label_tok), ansi::Ansi.BRIGHT_GREEN)!;
		case GOTO_STMT:
			dump_named_color_field(term, level + 1, "label: ", self.tok_slice(n.goto_stmt.label_tok), ansi::Ansi.BRIGHT_GREEN)!;
		case COMPUTED_GOTO_STMT: self.dump_child(term, level + 1, "expr:", n.computed_goto_stmt.expr)!;
		case CONTINUE_STMT:
			if (n.continue_stmt.has_label) dump_named_color_field(term, level + 1, "label: ", self.tok_slice(n.continue_stmt.label), ansi::Ansi.BRIGHT_GREEN)!;
		case BREAK_STMT:
			if (n.break_stmt.has_label) dump_named_color_field(term, level + 1, "label: ", self.tok_slice(n.break_stmt.label), ansi::Ansi.BRIGHT_GREEN)!;
		case RETURN_STMT:
			if (n.return_stmt.operand == EXPR) self.dump_child(term, level + 1, "expr:", n.return_stmt.expr)!;
		case ASM_STMT: self.dump_asm_children(n.asm_stmt, level, term)!;
		case DECL_STMT: foreach (child : n.decl_stmt.decls) self.dump_node(child, level + 2, term)!;
		case CALL_EXPR:
			self.dump_child(term, level + 1, "callee:", n.call.callee)!;
			if (n.call.args.len != 0)
			{
				dump_text_line(term, level + 1, "args:")!; foreach (child : n.call.args) self.dump_node(child, level + 2, term)!;
			}
		case BUILTIN_CALL_EXPR:
			dump_named_field(term, level + 1, "name: ", self.tok_slice(n.builtin_call.builtin_tok))!;
			if (n.builtin_call.args.len != 0)
			{
				dump_text_line(term, level + 1, "args:")!; foreach (child : n.builtin_call.args) self.dump_node(child, level + 2, term)!;
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
			self.dump_child(term, level + 1, "lhs:", n.binary.lhs)!;
			self.dump_child(term, level + 1, "rhs:", n.binary.rhs)!;
		case CAST: self.dump_node(n.cast.operand, level + 2, term)!;
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
		case IMAGINARY_LITERAL: self.dump_child(term, level + 1, "operand:", n.unary.operand)!;
		case DECL_REF_EXPR:
		case ENUMERATION_REF: dump_named_field(term, level + 1, "name: ", self.tok_slice(n.decl_ref.name_tok))!;
		case BUILTIN_REF: dump_named_field(term, level + 1, "name: ", self.tok_slice(n.builtin_ref.name_tok))!;
		case MEMBER_ACCESS_EXPR:
		case MEMBER_ACCESS_PTR_EXPR:
			self.dump_child(term, level + 1, "lhs:", n.member_access.base)!;
			QualType base_qt = n.member_access.base.qt(self);
			if (try pointer_type = base_qt.get(self.comp, POINTER)) base_qt = pointer_type.pointer.child;
			if (try record_type = base_qt.get_record(self.comp))
			{
				String name = record_type.fields[n.member_access.member_index].name.lookup(self.comp);
				dump_named_field(term, level + 1, "name: ", name)!;
			}
		case ARRAY_ACCESS_EXPR:
			self.dump_child(term, level + 1, "base:", n.array_access.base)!;
			self.dump_child(term, level + 1, "index:", n.array_access.index)!;
		case SIZEOF_EXPR:
		case ALIGNOF_EXPR:
		case COUNTOF_EXPR:
			if (!n.type_info.expr.is_null())
			{
				self.dump_child(term, level + 1, "expr:", n.type_info.expr.unwrap())!;
			}
			else
			{
				dump_type_line(term, level + 1, "operand type: ", n.type_info.operand_qt, self.comp)!;
			}
		case GENERIC_EXPR:
			self.dump_child(term, level + 1, "controlling:", n.generic.controlling)!;
			self.dump_child(term, level + 1, "chosen:", n.generic.chosen)!;
			if (n.generic.rest.len != 0)
			{
				dump_text_line(term, level + 1, "rest:")!; foreach (child : n.generic.rest) self.dump_node(child, level + 2, term)!;
			}
		case GENERIC_ASSOCIATION_EXPR: self.dump_node(n.generic_association.expr, level + 2, term)!;
		case GENERIC_DEFAULT_EXPR: self.dump_node(n.generic_default.expr, level + 2, term)!;
		case ARRAY_FILLER_EXPR: dump_number_line(term, level + 1, "count: ", n.array_filler.count)!;
		case CODEGEN_DIAGNOSTIC: self.dump_codegen_diagnostic(n.codegen_diagnostic, level + 1, term)!;
		case ALIGNAS_TYPE:
		case IDENTIFIER_ARG: unreachable("invalid node in AST dump");
		default: {}
	}
}

fn void? Tree.dump_child(&self, Terminal term, uint indent, String label, NodeIndex child)
{
	dump_text_line(term, indent, label)!;
	self.dump_node(child, indent + 1, term)!;
}

fn void? Tree.dump_asm_children(&self, NodeAsmStmt asm_node, uint level, Terminal term)
{
	self.dump_node(asm_node.asm_str, level + 2, term)!;
	if (asm_node.outputs.len != 0)
	{
		dump_text_line(term, level + 1, "ouputs:")!; self.dump_asm_operands(asm_node.outputs, level, term)!;
	}
	if (asm_node.inputs.len != 0)
	{
		dump_text_line(term, level + 1, "inputs:")!; self.dump_asm_operands(asm_node.inputs, level, term)!;
	}
	if (asm_node.clobbers.len != 0)
	{
		dump_text_line(term, level + 1, "clobbers:")!;
		foreach (clobber : asm_node.clobbers) self.dump_value_node(clobber, level + 2, term)!;
	}
	if (asm_node.labels.len != 0)
	{
		dump_text_line(term, level + 1, "labels:")!; foreach (label : asm_node.labels) self.dump_node(label, level + 2, term)!;
	}
}

fn void? Tree.dump_asm_operands(&self, AsmOperand[] operands, uint level, Terminal term)
{
	foreach (operand : operands)
	{
		if (operand.name != 0) dump_named_field(term, level + 2, "asm name: ", self.tok_slice(operand.name))!;
		self.dump_value_line(operand.constraint, level + 2, "constraint: ", term)!;
		self.dump_node(operand.expr, level + 2, term)!;
	}
}

fn void? Tree.dump_value_node(&self, NodeIndex index, uint indent, Terminal term)
{
	if (try value = self.value_of(index))
	{
		for (uint j = 0; j < indent; j++) term.writer.write_byte(' ')!;
		term.set_color(ansi::Ansi.BRIGHT_GREEN)!;
		value.print(index.qt(self), self.comp, term.writer)!;
		term.writer.write_byte('\n')!;
		term.set_color(ansi::Ansi.RESET)!;
	}
}

fn void? Tree.dump_value_line(&self, NodeIndex index, uint indent, String label, Terminal term)
{
	if (try value = self.value_of(index))
	{
		for (uint j = 0; j < indent; j++) term.writer.write_byte(' ')!;
		io::write_all(term.writer, label)!;
		term.set_color(ansi::Ansi.BRIGHT_GREEN)!;
		value.print(index.qt(self), self.comp, term.writer)!;
		term.writer.write_byte('\n')!;
		term.set_color(ansi::Ansi.RESET)!;
	}
}

fn void? Tree.dump_codegen_diagnostic(&self, NodeCodegenDiagnostic diagnostic, uint indent, Terminal term)
{
	for (uint j = 0; j < indent; j++) term.writer.write_byte(' ')!;
	io::fprintf(term.writer, "%s: ", diagnostic.kind.label)!;
	char* message = (char*)diagnostic.text.ptr;
	usz message_len = diagnostic.text.len * 4;
	for (usz i = 0; i < message_len; i++) if (message[i] == 0)
	{
		message_len = i; break;
	}
	io::write_all(term.writer, message[:message_len])!;
	if (diagnostic.has_opt) io::fprintf(term.writer, " [-W%s]", diagnostic.opt.flag)!;
}

fn void? dump_function_header(Terminal term, uint indent, bool is_static, bool is_inline, String name)
{
	for (uint j = 0; j < indent; j++) term.writer.write_byte(' ')!;
	term.set_color(ansi::Ansi.BRIGHT_GREEN)!;
	if (is_static) io::write_all(term.writer, "static ")!;
	if (is_inline) io::write_all(term.writer, "inline ")!;
	term.set_color(ansi::Ansi.RESET)!;
	io::write_all(term.writer, "name: ")!;
	term.set_color(ansi::Ansi.BRIGHT_RED)!;
	io::write_all(term.writer, name)!;
	term.set_color(ansi::Ansi.RESET)!;
	term.writer.write_byte('\n')!;
}

fn void? dump_variable_header(Terminal term, uint indent, VariableStorageClass storage_class, bool thread_local, String name)
{
	for (uint j = 0; j < indent; j++) term.writer.write_byte(' ')!;
	term.set_color(ansi::Ansi.BRIGHT_GREEN)!;
	switch (storage_class)
	{
		case AUTO: {}
		case STATIC: io::write_all(term.writer, "static ")!;
		case EXTERN: io::write_all(term.writer, "extern ")!;
		case REGISTER: io::write_all(term.writer, "register ")!;
	}
	if (thread_local) io::write_all(term.writer, "thread_local ")!;
	term.set_color(ansi::Ansi.RESET)!;
	io::write_all(term.writer, "name: ")!;
	term.set_color(ansi::Ansi.BRIGHT_RED)!;
	io::write_all(term.writer, name)!;
	term.set_color(ansi::Ansi.RESET)!;
	term.writer.write_byte('\n')!;
}

fn void? dump_prefix_named_field(Terminal term, uint indent, String prefix, String label, String name)
{
	for (uint j = 0; j < indent; j++) term.writer.write_byte(' ')!;
	term.set_color(ansi::Ansi.BRIGHT_GREEN)!;
	io::write_all(term.writer, prefix)!;
	term.set_color(ansi::Ansi.RESET)!;
	io::write_all(term.writer, label)!;
	term.set_color(ansi::Ansi.BRIGHT_RED)!;
	io::write_all(term.writer, name)!;
	term.set_color(ansi::Ansi.RESET)!;
	term.writer.write_byte('\n')!;
}

fn void? dump_named_color_field(Terminal term, uint indent, String label, String name, String color)
{
	for (uint j = 0; j < indent; j++) term.writer.write_byte(' ')!;
	io::write_all(term.writer, label)!;
	term.set_color(color)!;
	io::write_all(term.writer, name)!;
	term.set_color(ansi::Ansi.RESET)!;
	term.writer.write_byte('\n')!;
}

fn void? dump_index_line(Terminal term, uint indent, String label, uint index)
{
	for (uint j = 0; j < indent; j++) term.writer.write_byte(' ')!;
	io::write_all(term.writer, label)!;
	term.set_color(ansi::Ansi.BRIGHT_RED)!;
	io::fprintf(term.writer, "0x%X", index)!;
	term.set_color(ansi::Ansi.RESET)!;
	term.writer.write_byte('\n')!;
}

fn void? dump_number_line(Terminal term, uint indent, String label, ulong value)
{
	for (uint j = 0; j < indent; j++) term.writer.write_byte(' ')!;
	io::write_all(term.writer, label)!;
	term.set_color(ansi::Ansi.BRIGHT_GREEN)!;
	io::fprintf(term.writer, "%d", value)!;
	term.set_color(ansi::Ansi.RESET)!;
	term.writer.write_byte('\n')!;
}

fn void? dump_type_line(Terminal term, uint indent, String label, QualType qt, Compilation* comp)
{
	for (uint j = 0; j < indent; j++) term.writer.write_byte(' ')!;
	io::write_all(term.writer, label)!;
	term.set_color(ansi::Ansi.BRIGHT_MAGENTA)!;
	qt.dump(comp, term.writer)!;
	term.set_color(ansi::Ansi.RESET)!;
	term.writer.write_byte('\n')!;
}

fn void? dump_text_line(Terminal term, uint indent, String value)
{
	for (uint j = 0; j < indent; j++) term.writer.write_byte(' ')!;
	io::write_all(term.writer, value)!;
	term.writer.write_byte('\n')!;
}

fn void? dump_named_field(Terminal term, uint indent, String label, String name)
{
	for (uint j = 0; j < indent; j++) term.writer.write_byte(' ')!;
	io::write_all(term.writer, label)!;
	term.set_color(ansi::Ansi.BRIGHT_RED)!;
	io::write_all(term.writer, name)!;
	term.set_color(ansi::Ansi.RESET)!;
	term.writer.write_byte('\n')!;
}

fn void? set_bright_yellow(Terminal term)
{
	if (term.mode != diagnostics::ColorMode.NO_COLOR) io::write_all(term.writer, "\e[93m")!;
}

fn void? set_bright_blue(Terminal term)
{
	if (term.mode != diagnostics::ColorMode.NO_COLOR) io::write_all(term.writer, "\e[94m")!;
}
