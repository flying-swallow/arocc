// A small typed-IR probe for the current backend boundary. Builder scenarios
// isolate backend IR behavior; ast-* scenarios hand-build Tree nodes and call
// CodeGen directly because the parser's declaration grammar is not connected
// to code generation. Scenarios are source-derived and do not claim parity
// with a compatible reference executable.
module ir_probe;
import aro::backend::ir, aro::backend::object, aro::codegen, aro::compilation, aro::diagnostics;
import aro::preprocessor, aro::source, aro::target, aro::tokens, aro::tokenizer, aro::tree;
import aro::type_store, aro::value, aro::value_interner, std::io;

struct AstFixture
{
	TrackingAllocator ta;
	Diagnostics diagnostics;
	Compilation comp;
	tokens::TreeToken[1] tokens;
	Tree tree;
	Preprocessor pp;
}

fn void AstFixture.init(&self)
{
	self.ta.init(mem);
	self.diagnostics.init_list(&self.ta);
	self.comp.init(&self.ta, null, &self.diagnostics);
	Source src = self.comp.add_source_from_buffer("ir_probe.c", "answer")!!;
	self.tokens[0] = { .id = tokenizer::TokenId.IDENTIFIER,
		.loc = { .id = src.id, .byte_offset = 0, .line = 1 } };
	self.tree.init(&self.comp, self.tokens[..]);
	self.pp.init(&self.comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
}

fn void AstFixture.free(&self)
{
	self.pp.free();
	self.tree.free();
	self.comp.free();
	self.diagnostics.free();
	assert(self.ta.allocation_count() == 0, "AST-to-IR probe leaked allocations");
	self.ta.free();
}

fn NodeIndex AstFixture.int_literal(&self, long number)
{
	NodeIndex literal = self.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
		.literal = { .literal_tok = 0, .qt = type_store::INT } });
	self.tree.set_value(literal, value::int_i64(number, &self.comp));
	return literal;
}

fn void AstFixture.function(&self, NodeIndex body)
{
	type_store::QualType function_type = self.comp.type_store.put(
		type_store::type_func(type_store::INT, type_store::FuncKind.NORMAL, {}));
	NodeIndex function = self.tree.add_node({ .kind = tree::NodeKind.FUNCTION,
		.function = { .name_tok = 0, .qt = function_type, .body = body.pack(),
			.definition = type_store::NODE_NULL } });
	self.tree.root_decls.push(function);
}

fn Ir scalar_ir(Allocator allocator, value_interner::Interner* interner)
{
	ir::Builder builder;
	builder.init(allocator, interner);
	builder.start_fn();
	Ref input = builder.add_arg(value_interner::REF_I32);
	Ref one = builder.add_constant(interner.put({ .tag = INT, .int_val = { .tag = I64, .i64 = 1 } }), value_interner::REF_I32);
	Ref result = builder.add_inst(ADD, { .bin = { input, one } }, value_interner::REF_I32);
	builder.add_return(result);
	builder.finish_fn("increment");
	Ir graph = builder.finish();
	builder.free();
	return graph;
}

fn Ir control_flow_ir(Allocator allocator, value_interner::Interner* interner)
{
	ir::Builder builder;
	builder.init(allocator, interner);
	builder.start_fn();
	Ref condition = builder.add_arg(value_interner::REF_I1);
	Ref then_label = builder.make_label("then");
	Ref else_label = builder.make_label("else");
	Ref join_label = builder.make_label("join");
	builder.add_branch(condition, then_label, else_label);

	builder.start_block(then_label);
	Ref then_value = builder.add_constant(interner.put({ .tag = INT, .int_val = { .tag = I64, .i64 = 1 } }), value_interner::REF_I32);
	builder.add_jump(join_label);

	builder.start_block(else_label);
	Ref else_value = builder.add_constant(interner.put({ .tag = INT, .int_val = { .tag = I64, .i64 = 0 } }), value_interner::REF_I32);
	builder.add_jump(join_label);

	builder.start_block(join_label);
	PhiInput[2] incoming = {
		{ .label = then_label, .value = then_value },
		{ .label = else_label, .value = else_value },
	};
	Ref result = builder.add_phi(incoming[..], value_interner::REF_I32);
	builder.add_return(result);
	builder.finish_fn("choose");
	Ir graph = builder.finish();
	builder.free();
	return graph;
}

fn Ir ast_scalar_ir(AstFixture* fixture)
{
	NodeIndex lhs = fixture.int_literal(20);
	NodeIndex rhs = fixture.int_literal(22);
	NodeIndex sum = fixture.tree.add_node({ .kind = tree::NodeKind.ADD_EXPR,
		.binary = { .qt = type_store::INT, .lhs = lhs, .op_tok = 0, .rhs = rhs } });
	NodeIndex ret = fixture.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::INT, .operand = tree::ReturnOperandKind.EXPR,
			.expr = sum } });
	NodeIndex[1] statements = { ret };
	NodeIndex body = fixture.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	fixture.function(body);
	return codegen::gen_ir(&fixture.tree, &fixture.pp)!!;
}

fn Ir ast_control_flow_ir(AstFixture* fixture)
{
	NodeIndex three = fixture.int_literal(3);
	NodeIndex five = fixture.int_literal(5);
	NodeIndex condition = fixture.tree.add_node({ .kind = tree::NodeKind.LESS_THAN_EXPR,
		.binary = { .qt = type_store::BOOL, .lhs = three, .op_tok = 0, .rhs = five } });
	NodeIndex yes_value = fixture.int_literal(11);
	NodeIndex no_value = fixture.int_literal(29);
	NodeIndex yes_return = fixture.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::INT, .operand = tree::ReturnOperandKind.EXPR,
			.expr = yes_value } });
	NodeIndex no_return = fixture.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::INT, .operand = tree::ReturnOperandKind.EXPR,
			.expr = no_value } });
	NodeIndex branch = fixture.tree.add_node({ .kind = tree::NodeKind.IF_STMT,
		.if_stmt = { .if_tok = 0, .init = type_store::NODE_NULL, .cond = condition,
			.then_body = yes_return, .else_body = no_return.pack() } });
	NodeIndex[1] statements = { branch };
	NodeIndex body = fixture.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	fixture.function(body);
	return codegen::gen_ir(&fixture.tree, &fixture.pp)!!;
}

fn Ir unsupported_complex_type_ir(Allocator allocator, value_interner::Interner* interner)
{
	ir::Builder builder;
	builder.init(allocator, interner);
	builder.start_fn();
	Ref input = builder.add_arg(value_interner::REF_CF64);
	builder.add_return(input);
	builder.finish_fn("complex_identity");
	Ir graph = builder.finish();
	builder.free();
	return graph;
}

fn Ir invalid_symbol_body_ir(Allocator allocator, value_interner::Interner* interner)
{
	ir::Builder builder;
	builder.init(allocator, interner);
	builder.start_fn();
	Ref result = builder.add_inst(SYMBOL, { .label = "callee" }, value_interner::REF_FUNC);
	builder.add_return(result);
	builder.finish_fn("symbol_as_body_instruction");
	Ir graph = builder.finish();
	builder.free();
	return graph;
}

fn void dump_graph(Ir* graph)
{
	Terminal term = { .writer = io::stdout(), .mode = diagnostics::ColorMode.NO_COLOR };
	graph.dump(term)!!;
}

fn int main(String[] args)
{
	if (args.len != 2)
	{
		io::eprintfn("usage: ir_probe <scalar|control-flow|ast-scalar|ast-control-flow|renderer-fail|unsupported-complex-type|invalid-symbol-body>");
		return 2;
	}

	value_interner::Interner interner;
	interner.init(mem);
	if (args[1] == "scalar")
	{
		Ir graph = scalar_ir(mem, &interner);
		dump_graph(&graph);
		graph.free();
		interner.free();
		return 0;
	}
	if (args[1] == "control-flow")
	{
		Ir graph = control_flow_ir(mem, &interner);
		dump_graph(&graph);
		graph.free();
		interner.free();
		return 0;
	}
	if (args[1] == "ast-scalar")
	{
		AstFixture fixture;
		fixture.init();
		Ir graph = ast_scalar_ir(&fixture);
		dump_graph(&graph);
		graph.free();
		fixture.free();
		interner.free();
		return 0;
	}
	if (args[1] == "ast-control-flow")
	{
		AstFixture fixture;
		fixture.init();
		Ir graph = ast_control_flow_ir(&fixture);
		dump_graph(&graph);
		graph.free();
		fixture.free();
		interner.free();
		return 0;
	}
	if (args[1] == "renderer-fail")
	{
		Ir graph = scalar_ir(mem, &interner);
		dump_graph(&graph);
		ir::ErrorList errors;
		errors.init(mem);
		object::Object*? rendered = ir::render(&graph, mem, target::native()!!, &errors);
		fault render_fault = @catch(rendered);
		if (render_fault != ir::LOWER_FAIL || errors.len() != 1 ||
			errors.name_at(0) != "increment" || errors.message_at(0) != "TODO implement lowering functions")
		{
			if (!render_fault)
			{
				object::Object* unexpected = rendered!!;
				unexpected.deinit();
			}
			errors.free();
			graph.free();
			interner.free();
			io::eprintfn("ir_probe: unexpected x86 renderer failure result");
			return 1;
		}
		io::printfn("x86 renderer: LOWER_FAIL (%s: %s)", errors.name_at(0), errors.message_at(0));
		errors.free();
		graph.free();
		interner.free();
		return 0;
	}
	if (args[1] == "unsupported-complex-type")
	{
		Ir graph = unsupported_complex_type_ir(mem, &interner);
		// Current Ir.write_type has no COMPLEX_TY arm. The source-derived
		// expectation is a fatal unsupported-type boundary here.
		dump_graph(&graph);
		graph.free();
		interner.free();
		return 0;
	}
	if (args[1] == "invalid-symbol-body")
	{
		Ir graph = invalid_symbol_body_ir(mem, &interner);
		// Symbols are valid references, not body instructions. The IR dumper's
		// unreachable arm makes this malformed node placement fatal.
		dump_graph(&graph);
		graph.free();
		interner.free();
		return 0;
	}

	interner.free();
	io::eprintfn("ir_probe: unknown scenario '%s'", args[1]);
	return 2;
}
