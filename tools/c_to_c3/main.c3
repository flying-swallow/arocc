module aro_c_to_c3;

import aro::frontend::c::compilation, aro::frontend::c::diagnostics;
import aro::frontend::c::parser, aro::frontend::c::preprocessor, aro::frontend::c::predefined_macros;
import aro::frontend::c::tree, aro::frontend::c::type_store, aro::frontend::c::attribute_map;
import aro::frontend::c::value, aro::source;
import std::core::dstring, std::io, std::io::file;

excuse UNSUPPORTED_C, INVALID_C, NO_SUPPORTED_FUNCTIONS;

struct Emitter
{
	Tree* tree;
	DString* out;
	uint indent;
	String isolated_function;
}

fn void? Emitter.unsupported(&self, NodeIndex index, String reason)
{
	ExpandedLocation loc = index.loc(self.tree).expand(self.tree.comp);
	io::eprintfn("%s:%d:%d: unsupported C %s (%s)", loc.path, loc.line_no, loc.col,
		index.kind(self.tree).name, reason);
	return UNSUPPORTED_C~;
}

fn void Emitter.line_start(&self)
{
	for (uint i = 0; i < self.indent; i++) self.out.append_string("    ");
}

fn String? Emitter.type_name(&self, QualType qt, NodeIndex index)
{
	BaseType base = qt.base(self.tree.comp);
	if (!qt.is_volatile && !base.qt.is_volatile)
	{
		switch (base.ty.tag)
		{
			case VOID: return "void";
			case BOOL: return "bool";
			case POINTER:
				return string::tformat("%s*", self.type_name(base.ty.pointer.child, index)!);
			case INT:
				bool signed = qt.signedness(self.tree.comp) == SIGNED;
				switch (base.ty.int_ty.bits(self.tree.comp))
				{
					case 8: return signed ? "ichar" : "char";
					case 16: return signed ? "short" : "ushort";
					case 32: return signed ? "int" : "uint";
					case 64: return signed ? "long" : "ulong";
					default: break;
				}
			default: break;
		}
	}
	self.unsupported(index, "expected an integer, bool, void, or a pointer to a supported type")!;
	return UNSUPPORTED_C~;
}

fn void? Emitter.name(&self, NodeIndex decl)
{
	String spelling = self.tree.tok_slice(decl.tok(self.tree));
	foreach (ch : spelling)
	{
		if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
			|| (ch >= '0' && ch <= '9') || ch == '_') continue;
		self.unsupported(decl, "expected an ASCII identifier")!;
	}
	if (spelling.len > 112) self.unsupported(decl, "identifier is too long to rename for C3")!;
	if (decl.kind(self.tree) == FUNCTION)
	{
		if (spelling != "main") self.out.append_string("c_fn_");
		self.out.append_string(spelling);
		return;
	}
	// Use declaration identity so a shadowing local gets its own name.
	io::fprintf(self.out, "c_var_%s_%d", spelling, (uint)decl)!;
}

fn String binary_operator(NodeKind kind)
{
	switch (kind)
	{
		case ADD_EXPR: return "+";
		case SUB_EXPR: return "-";
		case MUL_EXPR: return "*";
		case DIV_EXPR: return "/";
		case MOD_EXPR: return "%";
		case SHL_EXPR: return "<<";
		case SHR_EXPR: return ">>";
		case BIT_AND_EXPR: return "&";
		case BIT_OR_EXPR: return "|";
		case BIT_XOR_EXPR: return "^";
		case EQUAL_EXPR: return "==";
		case NOT_EQUAL_EXPR: return "!=";
		case LESS_THAN_EXPR: return "<";
		case LESS_THAN_EQUAL_EXPR: return "<=";
		case GREATER_THAN_EXPR: return ">";
		case GREATER_THAN_EQUAL_EXPR: return ">=";
		case BOOL_AND_EXPR: return "&&";
		case BOOL_OR_EXPR: return "||";
		default: unreachable();
	}
}

fn bool produces_c_int_truth(NodeKind kind) => kind.props.bool_result || kind == BOOL_NOT_EXPR;

fn void? Emitter.predicate(&self, Node node)
{
	if (node.kind == BOOL_NOT_EXPR)
	{
		self.out.append_char('!');
		self.condition(node.unary.operand)!;
		return;
	}
	bool logical = node.kind == BOOL_AND_EXPR || node.kind == BOOL_OR_EXPR;
	if (logical) { self.condition(node.binary.lhs)!; }
	else { self.expr(node.binary.lhs)!; }
	io::fprintf(self.out, " %s ", binary_operator(node.kind))!;
	if (logical) { self.condition(node.binary.rhs)!; }
	else { self.expr(node.binary.rhs)!; }
}

fn void? Emitter.condition(&self, NodeIndex index)
{
	String ty = self.type_name(index.qt(self.tree), index)!;
	self.out.append_char('(');
	Node node = index.get(self.tree);
	if (produces_c_int_truth(node.kind))
	{
		self.predicate(node)!;
	}
	else
	{
		self.expr(index)!;
		if (index.qt(self.tree).is_pointer(self.tree.comp)) { self.out.append_string(" != null"); }
		else if (ty != "bool") { self.out.append_string(" != 0"); }
	}
	self.out.append_char(')');
}

fn void? Emitter.cast(&self, NodeIndex index, NodeCast cast)
{
	switch (cast.kind)
	{
		case LVAL_TO_RVAL:
		case NO_OP:
			(void)self.type_name(cast.qt, index)!;
			self.expr(cast.operand)!;
		case INT_TO_BOOL:
		case POINTER_TO_BOOL:
			self.condition(cast.operand)!;
		case NULL_TO_POINTER:
			io::fprintf(self.out, "((%s)null)", self.type_name(cast.qt, index)!)!;
		case BITCAST:
			if (!cast.qt.is_pointer(self.tree.comp) || !cast.operand.qt(self.tree).is_pointer(self.tree.comp))
			{
				self.unsupported(index, "bitcast between non-pointer types")!;
			}
			io::fprintf(self.out, "((%s)", self.type_name(cast.qt, index)!)!;
			self.expr(cast.operand)!;
			self.out.append_char(')');
		case INT_CAST:
		case BOOL_TO_INT:
			self.out.append_string("((");
			self.out.append_string(self.type_name(cast.qt, index)!);
			self.out.append_char(')');
			if (cast.kind == BOOL_TO_INT)
			{
				self.out.append_char('(');
				self.condition(cast.operand)!;
				self.out.append_string(" ? 1 : 0)");
			}
			else { self.expr(cast.operand)!; }
			self.out.append_char(')');
		default: self.unsupported(index, cast.kind.name)!;
	}
}

fn void? Emitter.expr(&self, NodeIndex index)
{
	Node n = index.get(self.tree);
	// C relational and logical expressions produce int, while C3 produces bool.
	if (produces_c_int_truth(n.kind))
	{
		self.out.append_char('(');
		self.predicate(n)!;
		self.out.append_string(" ? 1 : 0)");
		return;
	}

	switch (n.kind)
	{
		case CAST: self.cast(index, n.cast)!;
		case INT_LITERAL:
		case CHAR_LITERAL:
		case BOOL_LITERAL:
			value::Value literal = self.tree.value_of(index)!;
			QualType qt = index.qt(self.tree);
			String ty = self.type_name(qt, index)!;
			if (ty == "bool")
			{
				self.out.append_string(literal.is_zero(self.tree.comp) ? "false" : "true");
				return;
			}
			self.out.append_string("((");
			self.out.append_string(ty);
			self.out.append_char(')');
			(void)literal.print(qt, self.tree.comp, self.out)!;
			if (ty == "ulong") self.out.append_string("uL");
			if (ty == "long") self.out.append_char('L');
			if (ty == "uint") self.out.append_char('u');
			self.out.append_char(')');
		case NULLPTR_LITERAL:
			self.out.append_string("null");
		case DECL_REF_EXPR:
			if (self.isolated_function.len && n.decl_ref.decl.kind(self.tree) == VARIABLE)
			{
				NodeVariable var_ = n.decl_ref.decl.get(self.tree).variable;
				if (var_.implicit || var_.storage_class == EXTERN || var_.storage_class == STATIC)
				{
					self.unsupported(index, "function depends on a non-local variable")!;
				}
				foreach (root : self.tree.root_decls)
				{
					if (root == n.decl_ref.decl) self.unsupported(index, "function depends on a file-scope variable")!;
				}
			}
			(void)self.type_name(n.decl_ref.qt, index)!;
			self.name(n.decl_ref.decl)!;
		case PAREN_EXPR:
			self.out.append_char('(');
			self.expr(n.unary.operand)!;
			self.out.append_char(')');
		case PLUS_EXPR:
			self.expr(n.unary.operand)!;
		case NEGATE_EXPR:
		case BIT_NOT_EXPR:
		case ADDR_OF_EXPR:
		case DEREF_EXPR:
		case PRE_INC_EXPR:
		case PRE_DEC_EXPR:
			(void)self.type_name(n.unary.qt, index)!;
			self.out.append_char('(');
			self.out.append_string(self.tree.tok_slice(n.unary.op_tok));
			self.expr(n.unary.operand)!;
			self.out.append_char(')');
		case POST_INC_EXPR:
		case POST_DEC_EXPR:
			(void)self.type_name(n.unary.qt, index)!;
			self.out.append_char('(');
			self.expr(n.unary.operand)!;
			self.out.append_string(self.tree.tok_slice(n.unary.op_tok));
			self.out.append_char(')');
		case ADD_EXPR:
		case SUB_EXPR:
		case MUL_EXPR:
		case DIV_EXPR:
		case MOD_EXPR:
		case SHL_EXPR:
		case SHR_EXPR:
		case BIT_AND_EXPR:
		case BIT_OR_EXPR:
		case BIT_XOR_EXPR:
			(void)self.type_name(n.binary.qt, index)!;
			self.out.append_char('(');
			self.expr(n.binary.lhs)!;
			io::fprintf(self.out, " %s ", binary_operator(n.kind))!;
			self.expr(n.binary.rhs)!;
			self.out.append_char(')');
		case ASSIGN_EXPR:
		case ADD_ASSIGN_EXPR:
		case SUB_ASSIGN_EXPR:
		case MUL_ASSIGN_EXPR:
		case DIV_ASSIGN_EXPR:
		case MOD_ASSIGN_EXPR:
		case SHL_ASSIGN_EXPR:
		case SHR_ASSIGN_EXPR:
		case BIT_AND_ASSIGN_EXPR:
		case BIT_OR_ASSIGN_EXPR:
		case BIT_XOR_ASSIGN_EXPR:
			self.out.append_char('(');
			self.expr(n.binary.lhs)!;
			self.out.append_string(" = ");
			self.expr(n.binary.rhs)!;
			self.out.append_char(')');
		case COMPOUND_ASSIGN_DUMMY_EXPR:
			// The translated calculation reads the left side again.
			NodeIndex target = n.unary.operand;
			while (target.kind(self.tree) == PAREN_EXPR) target = target.get(self.tree).unary.operand;
			if (target.kind(self.tree) != DECL_REF_EXPR)
			{
				self.unsupported(index, "compound assignment to a non-variable lvalue")!;
			}
			self.expr(target)!;
		case ARRAY_ACCESS_EXPR:
			(void)self.type_name(n.array_access.qt, index)!;
			self.out.append_char('(');
			self.expr(n.array_access.base)!;
			self.out.append_char('[');
			self.expr(n.array_access.index)!;
			self.out.append_string("])");
		case COND_EXPR:
			self.out.append_char('(');
			self.condition(n.conditional.cond)!;
			self.out.append_string(" ? ");
			self.expr(n.conditional.then_expr)!;
			self.out.append_string(" : ");
			self.expr(n.conditional.else_expr)!;
			self.out.append_char(')');
		case CALL_EXPR:
			NodeIndex callee = n.call.callee;
			while (true)
			{
				Node c = callee.get(self.tree);
				if (c.kind == PAREN_EXPR) { callee = c.unary.operand; }
				else if (c.kind == CAST && c.cast.kind == FUNCTION_TO_POINTER) { callee = c.cast.operand; }
				else { break; }
			}
			Node c = callee.get(self.tree);
			if (c.kind != DECL_REF_EXPR || c.decl_ref.decl.kind(self.tree) != FUNCTION)
			{
				self.unsupported(index, "expected a direct call to a C function")!;
			}
			if (self.isolated_function.len && self.tree.tok_slice(c.decl_ref.name_tok) != self.isolated_function)
			{
				self.unsupported(index, "function depends on another function")!;
			}
			self.name(c.decl_ref.decl)!;
			self.out.append_char('(');
			foreach (i, arg : n.call.args)
			{
				if (i) self.out.append_string(", ");
				self.expr(arg)!;
			}
			self.out.append_char(')');
		default: self.unsupported(index, "expression is outside the supported subset")!;
	}
}

fn void? Emitter.block(&self, NodeIndex index)
{
	self.out.append_string("{\n");
	self.indent++;
	Node node = index.get(self.tree);
	if (node.kind == COMPOUND_STMT)
	{
		foreach (child : node.compound_stmt.body) self.statement(child)!;
	}
	else { self.statement(index)!; }
	self.indent--;
	self.line_start();
	self.out.append_char('}');
}

fn void? Emitter.loop_for(&self, NodeForStmt loop_)
{
	// C allows multiple declarations in the initializer. Put them in a scope
	// enclosing the loop so C3 does not need a matching declaration syntax.
	bool scoped = false;
	if (try init = loop_.init.unpack())
	{
		scoped = init.kind(self.tree).family != EXPR;
		if (scoped)
		{
			self.out.append_string("{\n");
			self.indent++;
			self.statement(init)!;
			self.line_start();
		}
	}
	self.out.append_string("for (");
	if (!scoped && !loop_.init.is_null()) self.expr(loop_.init.unwrap())!;
	self.out.append_string("; ");
	if (try cond = loop_.cond.unpack()) self.condition(cond)!;
	self.out.append_string("; ");
	if (try incr = loop_.incr.unpack()) self.expr(incr)!;
	self.out.append_string(") ");
	self.block(loop_.body)!;
	if (scoped)
	{
		self.out.append_char('\n');
		self.indent--;
		self.line_start();
		self.out.append_char('}');
	}
}

fn void? Emitter.statement(&self, NodeIndex index)
{
	Node n = index.get(self.tree);
	if (n.kind == DECL_STMT)
	{
		foreach (decl : n.decl_stmt.decls) self.statement(decl)!;
		return;
	}
	self.line_start();
	switch (n.kind)
	{
		case COMPOUND_STMT:
			self.block(index)!;
		case VARIABLE:
			NodeVariable var_ = n.variable;
			if (var_.storage_class != AUTO && var_.storage_class != REGISTER)
			{
				self.unsupported(index, "expected an automatic local variable")!;
			}
			if (var_.thread_local || self.tree.attr_map.attrs(index.pack()).len)
			{
				self.unsupported(index, "thread-local or attributed variable")!;
			}
			self.out.append_string(self.type_name(var_.qt, index)!);
			self.out.append_char(' ');
			self.name(index)!;
			if (try init = var_.initializer.unpack())
			{
				self.out.append_string(" = ");
				self.expr(init)!;
			}
			else { self.out.append_string(" @noinit"); }
			self.out.append_char(';');
		case IF_STMT:
			if (!n.if_stmt.init.is_null()) self.unsupported(index, "if initializer")!;
			self.out.append_string("if ");
			self.condition(n.if_stmt.cond)!;
			self.out.append_char(' ');
			self.block(n.if_stmt.then_body)!;
			if (try other = n.if_stmt.else_body.unpack())
			{
				self.out.append_string(" else ");
				self.block(other)!;
			}
		case WHILE_STMT:
			self.out.append_string("while ");
			self.condition(n.while_stmt.cond)!;
			self.out.append_char(' ');
			self.block(n.while_stmt.body)!;
		case DO_WHILE_STMT:
			self.out.append_string("do ");
			self.block(n.do_while_stmt.body)!;
			self.out.append_string(" while ");
			self.condition(n.do_while_stmt.cond)!;
			self.out.append_char(';');
		case FOR_STMT: self.loop_for(n.for_stmt)!;
		case RETURN_STMT:
			self.out.append_string("return");
			if (n.return_stmt.operand == EXPR)
			{
				self.out.append_char(' ');
				self.expr(n.return_stmt.expr)!;
			}
			else if (n.return_stmt.operand == IMPLICIT && n.return_stmt.implicit_value)
			{
				self.out.append_string(" 0");
			}
			self.out.append_char(';');
		case BREAK_STMT: self.out.append_string("break;");
		case CONTINUE_STMT: self.out.append_string("continue;");
		case EMPTY_DECL:
		case NULL_STMT: self.out.append_char(';');
		default:
			if (n.kind.family != EXPR) self.unsupported(index, "statement is outside the supported subset")!;
			self.expr(index)!;
			self.out.append_char(';');
	}
	self.out.append_char('\n');
}

fn void? Emitter.function(&self, NodeIndex index, NodeFunction decl)
{
	Func signature = decl.qt.base(self.tree.comp).ty.func;
	NodeIndex? body = decl.body.unpack();
	if (catch body)
	{
		String name = self.tree.tok_slice(decl.name_tok);
		foreach (candidate : self.tree.root_decls)
		{
			if (candidate.kind(self.tree) != FUNCTION) continue;
			NodeFunction other = candidate.get(self.tree).function;
			if (!other.body.is_null() && self.tree.tok_slice(other.name_tok) == name) return;
		}
		self.unsupported(index, "function declaration has no definition in this translation unit")!;
	}
	if (signature.kind == VARIADIC || (signature.kind == OLD_STYLE && signature.params.len)
		|| signature.cc != DEFAULT || self.tree.attr_map.attrs(index.pack()).len)
	{
		self.unsupported(index, "variadic, old-style parameter list, or attributed function")!;
	}
	String result = self.type_name(signature.return_type, index)!;
	if (self.tree.tok_slice(decl.name_tok) == "main" && (result != "int" || signature.params.len))
	{
		self.unsupported(index, "expected int main(void)")!;
	}

	io::fprintf(self.out, "fn %s ", result)!;
	self.name(index)!;
	self.out.append_char('(');
	foreach (i, param : signature.params)
	{
		NodeIndex param_node = param.node.unpack() ?? index;
		if (param_node == index || self.tree.attr_map.attrs(param_node.pack()).len)
		{
			self.unsupported(index, "expected named parameters without attributes")!;
		}
		if (i) self.out.append_string(", ");
		io::fprintf(self.out, "%s ", self.type_name(param.qt, param_node)!)!;
		self.name(param_node)!;
	}
	self.out.append_char(')');
	if (decl.is_static) self.out.append_string(" @local");
	self.out.append_char(' ');
	self.block(body)!;
	self.out.append_string("\n\n");
}

fn void? Emitter.translation_unit(&self)
{
	self.out.append_string("module translated_c;\n\n");
	foreach (index : self.tree.root_decls)
	{
		Node node = index.get(self.tree);
		switch (node.kind)
		{
			case FUNCTION: self.function(index, node.function)!;
			case TYPEDEF:
				if (!node.type_def.implicit) self.unsupported(index, "typedef declaration")!;
			case EMPTY_DECL: break;
			default: self.unsupported(index, "only function definitions are supported at file scope")!;
		}
	}
}

fn void? Emitter.extract_functions(&self, String primary_path)
{
	self.out.append_string("module translated_c;\n\n");
	uint emitted = 0;
	foreach (index : self.tree.root_decls)
	{
		if (index.kind(self.tree) != FUNCTION) continue;
		NodeFunction decl = index.get(self.tree).function;
		if (decl.body.is_null()) continue;
		Location loc = index.loc(self.tree);
		if (self.tree.comp.get_source(loc.id).path != primary_path) continue;

		self.isolated_function = self.tree.tok_slice(decl.name_tok);
		sz checkpoint = self.out.str_view().len;
		fault result = @catch(self.function(index, decl));
		if (result == UNSUPPORTED_C)
		{
			self.out.chop(checkpoint);
			self.indent = 0;
			continue;
		}
		if (result) return result~;
		emitted++;
	}
	if (!emitted) return NO_SUPPORTED_FUNCTIONS~;
}

fn void? translate(String path, OutStream out, String primary_path = "")
{
	char[] bytes = file::load(mem, path)!;
	defer free(bytes);
	Diagnostics diags;
	diags.init_writer(io::stderr(), false);
	defer diags.free();
	Compilation comp;
	comp.init(mem, compilation::native_definition(), null, &diags);
	defer comp.free();
	Source src = comp.add_source_from_buffer(path, bytes)!;
	Source macros = predefined_macros::generate_builtin_macros(&comp, predefined_macros::SystemDefinesMode.INCLUDE_SYSTEM_DEFINES)!;

	Preprocessor pp;
	pp.init(&comp, { .base_file = src.id, .add_builtin_macros = true })!;
	defer pp.free();
	(void)pp.preprocess(macros)!;
	pp.add_token(pp.preprocess(src)!)!;

	Parser p;
	p.init(&pp);
	defer p.free();
	Tree syntax = p.parse()!;
	defer syntax.free();
	if (diags.errors) return INVALID_C~;

	DString output;
	output.init(mem);
	defer output.free();
	Emitter emit = { .tree = &syntax, .out = &output };
	if (primary_path.len) { emit.extract_functions(primary_path)!; }
	else { emit.translation_unit()!; }
	io::write_all(out, output.str_view())!;
}

fn void usage(OutStream out)
{
	(void)io::fprintn(out, "Usage: aro_c_to_c3 <input.c>");
	(void)io::fprintn(out, "       aro_c_to_c3 --extract-functions <original.c> <preprocessed.i>");
}

fn int main(String[] args)
{
	if (args.len == 2 && (args[1] == "--help" || args[1] == "-h"))
	{
		usage(io::stdout());
		return 0;
	}
	String input;
	String primary_path;
	if (args.len == 4 && args[1] == "--extract-functions")
	{
		primary_path = args[2];
		input = args[3];
	}
	else if (args.len == 2 && args[1] != "--extract-functions")
	{
		input = args[1];
	}
	else
	{
		usage(io::stderr());
		return 2;
	}
	if (catch err = translate(input, io::stdout(), primary_path))
	{
		if (err == NO_SUPPORTED_FUNCTIONS) { io::eprintfn("%s: no supported function definitions", primary_path); }
		else if (err != INVALID_C && err != UNSUPPORTED_C) { io::eprintfn("%s: %s", input, err); }
		return 1;
	}
	return 0;
}
