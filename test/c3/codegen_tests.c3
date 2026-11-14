// Focused checks for AST-to-IR lowering and typed IR construction. Expected IR
// shapes are source-derived from src/c3/codegen.c3, codegen_nodes.c3, and
// backend/ir.c3; this is not executable differential coverage against Zig.
module codegen_tests;
import std, aro::backend::ir, aro::backend::object, aro::builtins, aro::codegen, aro::compilation, aro::diagnostics, aro::preprocessor, aro::target;
import aro::source, aro::tokens, aro::tokenizer, aro::tree, aro::type_store;
import aro::value, aro::value_interner;
import std::core::string;

struct CodeGenFixture
{
	TrackingAllocator ta;
	Diagnostics diagnostics;
	Compilation comp;
	tokens::TreeToken[2] tokens;
	Tree tree;
	Preprocessor pp;
}

fn void CodeGenFixture.init(&self)
{
	self.ta.init(mem);
	self.diagnostics.init_list(&self.ta);
	self.comp.init(&self.ta, null, &self.diagnostics);
	Source src = self.comp.add_source_from_buffer("codegen.c", "answer __builtin_trap")!!;
	self.tokens[0] = { .id = tokenizer::TokenId.IDENTIFIER,
		.loc = { .id = src.id, .byte_offset = 0, .line = 1 } };
	self.tokens[1] = { .id = tokenizer::TokenId.IDENTIFIER,
		.loc = { .id = src.id, .byte_offset = 7, .line = 1 } };
	self.tree.init(&self.comp, self.tokens[..]);
	self.pp.init(&self.comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
}

fn void CodeGenFixture.free(&self)
{
	self.pp.free();
	self.tree.free();
	self.comp.free();
	self.diagnostics.free();
	assert(self.ta.allocation_count() == 0, "AST-to-IR lowering leaked allocations");
	self.ta.free();
}

fn NodeIndex CodeGenFixture.int_literal(&self, long number)
	=> self.typed_int_literal(number, type_store::INT);

fn NodeIndex CodeGenFixture.typed_int_literal(&self, long number, type_store::QualType qt)
{
	NodeIndex literal = self.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
		.literal = { .literal_tok = 0, .qt = qt } });
	self.tree.set_value(literal, value::int_i64(number, &self.comp));
	return literal;
}

fn NodeIndex CodeGenFixture.function(&self, NodeIndex body)
	=> self.function_with_return_type(body, type_store::INT);

fn NodeIndex CodeGenFixture.function_with_return_type(&self, NodeIndex body, type_store::QualType return_type)
{
	type_store::QualType function_type = self.comp.type_store.put(
		type_store::type_func(return_type, type_store::FuncKind.NORMAL, {}));
	NodeIndex function = self.tree.add_node({ .kind = tree::NodeKind.FUNCTION,
		.function = { .name_tok = 0, .qt = function_type, .body = body.pack(),
			.definition = type_store::NODE_NULL } });
	self.tree.root_decls.push(function);
	return function;
}

fn void CodeGenFixture.expect_fatal(&self, String expected_text)
{
	fault fatal = @catch(codegen::gen_ir(&self.tree, &self.pp));
	assert(fatal == compilation::FATAL_ERROR, "gen_ir should return FATAL_ERROR");
	assert(self.diagnostics.messages.len() == 1, "gen_ir should report exactly one diagnostic");
	test::eq(self.diagnostics.messages[0].kind, diagnostics::MessageKind.FATAL_ERROR);
	test::eq(self.diagnostics.messages[0].text, expected_text);
}

// These direct Tree/TypeStore fixtures put each retained type boundary on a
// typed literal to enter gen_type; they do not claim parser-valid C syntax.
fn void CodeGenFixture.expect_typed_return_fatal(&self, type_store::QualType qt, String expected_text)
{
	NodeIndex result = self.typed_int_literal(1, qt);
	NodeIndex ret = self.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = qt, .operand = tree::ReturnOperandKind.EXPR, .expr = result } });
	NodeIndex[1] statements = { ret };
	NodeIndex body = self.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	self.function_with_return_type(body, qt);
	self.expect_fatal(expected_text);
}

fn void CodeGenFixture.expect_statement_fatal(&self, NodeIndex statement, String expected_text)
{
	NodeIndex[1] statements = { statement };
	NodeIndex body = self.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	self.function(body);
	self.expect_fatal(expected_text);
}

fn void CodeGenFixture.expect_expression_fatal(&self, NodeIndex expression, String expected_text)
{
	NodeIndex ret = self.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::INT, .operand = tree::ReturnOperandKind.EXPR,
			.expr = expression } });
	self.expect_statement_fatal(ret, expected_text);
}

fn void CodeGenFixture.expect_local_initializer_fatal(&self, NodeIndex initializer,
	type_store::QualType variable_type, String expected_text)
{
	NodeIndex variable = self.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 0, .qt = variable_type, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = initializer.pack(), .definition = type_store::NODE_NULL } });
	self.expect_statement_fatal(variable, expected_text);
}

fn void gen_ir_rejects_union_type() @test
{
	CodeGenFixture f;
	f.init();
	type_store::QualType union_type = f.comp.type_store.put(type_store::type_record_incomplete(
		f.comp.intern_string("UnsupportedUnion"), true));
	f.expect_typed_return_fatal(union_type, "TODO lower union types");
	f.free();
}

fn void gen_ir_rejects_complex_type() @test
{
	CodeGenFixture f;
	f.init();
	type_store::QualType complex_type = f.comp.type_store.put(type_store::type_complex(type_store::INT));
	f.expect_typed_return_fatal(complex_type, "TODO lower complex types");
	f.free();
}

fn void gen_ir_rejects_atomic_type() @test
{
	CodeGenFixture f;
	f.init();
	type_store::QualType atomic_type = f.comp.type_store.put(type_store::type_atomic(type_store::INT));
	f.expect_typed_return_fatal(atomic_type, "TODO lower atomic types");
	f.free();
}

fn void gen_ir_rejects_block_type() @test
{
	CodeGenFixture f;
	f.init();
	type_store::QualType function_type = f.comp.type_store.put(
		type_store::type_func(type_store::INT, type_store::FuncKind.NORMAL, {}));
	type_store::QualType block_type = f.comp.type_store.put(type_store::type_block(function_type));
	f.expect_typed_return_fatal(block_type, "TODO lower blocks");
	f.free();
}

fn void gen_ir_rejects_vla_type() @test
{
	CodeGenFixture f;
	f.init();
	NodeIndex length = f.int_literal(4);
	type_store::QualType vla_type = f.comp.type_store.put(type_store::type_vla(type_store::INT, length));
	f.expect_typed_return_fatal(vla_type, "TODO VLAs");
	f.free();
}

fn void gen_ir_rejects_struct_bitfield_type() @test
{
	CodeGenFixture f;
	f.init();
	type_store::RecordField[1] fields = {
		type_store::record_field(f.comp.intern_string("bits"), type_store::INT),
	};
	fields[0].bit_width = 1;
	type_store::QualType bitfield_type = f.comp.type_store.put(type_store::type_record(
		f.comp.intern_string("UnsupportedBitfield"), fields[..], {}, false));
	f.expect_typed_return_fatal(bitfield_type, "TODO lower struct bitfields");
	f.free();
}

fn void gen_ir_rejects_top_level_variable_node() @test
{
	CodeGenFixture f;
	f.init();
	NodeIndex variable = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 0, .qt = type_store::INT,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	f.tree.root_decls.push(variable);
	f.expect_fatal("TODO CodeGen.genVar\n");
	f.free();
}

fn void gen_ir_rejects_nullptr_type() @test
{
	CodeGenFixture f;
	f.init();
	f.expect_typed_return_fatal(type_store::NULLPTR_T, "TODO lower nullptr_t");
	f.free();
}

fn void gen_ir_rejects_global_assembly() @test
{
	CodeGenFixture f;
	f.init();
	NodeIndex asm_string = f.int_literal(0);
	NodeIndex global_asm = f.tree.add_node({ .kind = tree::NodeKind.GLOBAL_ASM,
		.global_asm = { .asm_tok = 0, .asm_str = asm_string } });
	f.tree.root_decls.push(global_asm);
	f.expect_fatal("TODO global assembly");
	f.free();
}

fn void gen_ir_rejects_switch_case_range() @test
{
	CodeGenFixture f;
	f.init();
	NodeIndex condition = f.int_literal(1);
	NodeIndex start = f.int_literal(2);
	NodeIndex end = f.int_literal(4);
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.NULL_STMT });
	NodeIndex case_stmt = f.tree.add_node({ .kind = tree::NodeKind.CASE_STMT,
		.case_stmt = { .case_tok = 0, .start = start, .end = end.pack(), .body = body } });
	NodeIndex switch_stmt = f.tree.add_node({ .kind = tree::NodeKind.SWITCH_STMT,
		.switch_stmt = { .switch_tok = 0, .cond = condition, .body = case_stmt } });
	f.expect_statement_fatal(switch_stmt, "TODO CodeGen.genStmt case range\n");
	f.free();
}

fn void gen_ir_rejects_unimplemented_statement_nodes() @test
{
	tree::NodeKind[4] kinds = { tree::NodeKind.GOTO_STMT, tree::NodeKind.COMPUTED_GOTO_STMT,
		tree::NodeKind.ASM_STMT, tree::NodeKind.NULLPTR_LITERAL };
	foreach (kind : kinds)
	{
		CodeGenFixture f;
		f.init();
		NodeIndex expression = f.int_literal(0);
		NodeIndex statement;
		switch (kind)
		{
			case GOTO_STMT:
				statement = f.tree.add_node({ .kind = kind,
					.goto_stmt = { .label_tok = 0 } });
			case COMPUTED_GOTO_STMT:
				statement = f.tree.add_node({ .kind = kind,
					.computed_goto_stmt = { .goto_tok = 0, .expr = expression } });
			case ASM_STMT:
				statement = f.tree.add_node({ .kind = kind,
					.asm_stmt = { .asm_tok = 0, .asm_str = expression } });
			case NULLPTR_LITERAL:
				statement = f.tree.add_node({ .kind = kind,
					.literal = { .literal_tok = 0, .qt = type_store::NULLPTR_T } });
			default: unreachable();
		}
		f.expect_statement_fatal(statement, string::tformat("TODO CodeGen.genStmt %s\n", kind.name));
		f.free();
	}
}

fn void gen_ir_rejects_unimplemented_expression_nodes() @test
{
	tree::NodeKind[6] kinds = { tree::NodeKind.ADDR_OF_LABEL, tree::NodeKind.IMAG_EXPR,
		tree::NodeKind.REAL_EXPR, tree::NodeKind.SIZEOF_EXPR, tree::NodeKind.BUILTIN_VA_ARG_PACK,
		tree::NodeKind.BUILTIN_VA_ARG_PACK_LEN };
	foreach (kind : kinds)
	{
		CodeGenFixture f;
		f.init();
		NodeIndex operand = f.int_literal(1);
		NodeIndex expression;
		switch (kind)
		{
			case ADDR_OF_LABEL:
				expression = f.tree.add_node({ .kind = kind,
					.addr_of_label = { .label_tok = 0, .qt = type_store::INT_POINTER } });
			case IMAG_EXPR: case REAL_EXPR:
				expression = f.tree.add_node({ .kind = kind,
					.unary = { .qt = type_store::INT, .operand = operand } });
			case SIZEOF_EXPR:
				expression = f.tree.add_node({ .kind = kind,
					.type_info = { .qt = type_store::INT, .op_tok = 0,
						.expr = operand.pack(), .operand_qt = type_store::INT } });
			case BUILTIN_VA_ARG_PACK: case BUILTIN_VA_ARG_PACK_LEN:
				expression = f.tree.add_node({ .kind = kind,
					.va_arg_pack = { .builtin_tok = 0 } });
			default: unreachable();
		}
		f.expect_expression_fatal(expression, string::tformat("TODO CodeGen.genExpr %s\n", kind.name));
		f.free();
	}
}

fn void gen_ir_rejects_unimplemented_cast_kinds() @test
{
	tree::CastKind[21] kinds = {
		tree::CastKind.BITCAST, tree::CastKind.POINTER_TO_INT, tree::CastKind.BOOL_TO_FLOAT,
		tree::CastKind.BOOL_TO_POINTER, tree::CastKind.INT_TO_FLOAT,
		tree::CastKind.COMPLEX_INT_TO_COMPLEX_FLOAT, tree::CastKind.INT_TO_POINTER,
		tree::CastKind.FLOAT_TO_INT, tree::CastKind.COMPLEX_FLOAT_TO_COMPLEX_INT,
		tree::CastKind.COMPLEX_INT_CAST, tree::CastKind.COMPLEX_INT_TO_REAL,
		tree::CastKind.REAL_TO_COMPLEX_INT, tree::CastKind.FLOAT_CAST, tree::CastKind.COMPLEX_FLOAT_CAST,
		tree::CastKind.COMPLEX_FLOAT_TO_REAL, tree::CastKind.REAL_TO_COMPLEX_FLOAT,
		tree::CastKind.NULL_TO_POINTER, tree::CastKind.UNION_CAST, tree::CastKind.VECTOR_SPLAT,
		tree::CastKind.ATOMIC_TO_NON_ATOMIC, tree::CastKind.NON_ATOMIC_TO_ATOMIC,
	};
	foreach (kind : kinds)
	{
		CodeGenFixture f;
		f.init();
		NodeIndex operand = f.int_literal(1);
		NodeIndex cast = f.tree.add_node({ .kind = tree::NodeKind.CAST,
			.cast = { .qt = type_store::INT, .kind = kind, .operand = operand } });
		f.expect_expression_fatal(cast, string::tformat("TODO CodeGen gen CastKind %s\n", kind.name));
		f.free();
	}
}

fn void gen_ir_rejects_unimplemented_lvalue_nodes() @test
{
	tree::NodeKind[5] kinds = { tree::NodeKind.MEMBER_ACCESS_EXPR, tree::NodeKind.MEMBER_ACCESS_PTR_EXPR,
		tree::NodeKind.ARRAY_ACCESS_EXPR, tree::NodeKind.COMPOUND_LITERAL_EXPR, tree::NodeKind.COMPOUND_LITERAL_EXPR };
	foreach (i, kind : kinds)
	{
		CodeGenFixture f;
		f.init();
		NodeIndex base = f.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
			.decl_ref = { .name_tok = 0, .qt = type_store::INT, .decl = (NodeIndex)(uint)type_store::NODE_NULL } });
		NodeIndex lvalue;
		if (i < 2)
		{
			lvalue = f.tree.add_node({ .kind = kind,
				.member_access = { .qt = type_store::INT, .base = base, .access_tok = 0 } });
		}
		else if (i == 2)
		{
			NodeIndex index = f.int_literal(0);
			lvalue = f.tree.add_node({ .kind = kind,
				.array_access = { .l_bracket_tok = 0, .qt = type_store::INT, .base = base, .index = index } });
		}
		else
		{
			NodeIndex initializer = f.int_literal(1);
			lvalue = f.tree.add_node({ .kind = kind,
				.compound_literal = { .qt = type_store::INT, .thread_local = i == 4,
					.storage_class = i == 3 ? tree::CompoundLiteralStorageClass.STATIC : tree::CompoundLiteralStorageClass.AUTO,
					.initializer = initializer } });
		}
		NodeIndex rhs = f.int_literal(1);
		NodeIndex assignment = f.tree.add_node({ .kind = tree::NodeKind.ASSIGN_EXPR,
			.binary = { .qt = type_store::INT, .lhs = lvalue, .rhs = rhs } });
		String expected = i < 3
			? string::tformat("TODO CodeGen.genLval %s\n", kind.name)
			: "TODO CodeGen.compound_literal_expr static or thread_local\n";
		f.expect_expression_fatal(assignment, expected);
		f.free();
	}
}

fn void gen_ir_rejects_unimplemented_initializer_nodes() @test
{
	tree::NodeKind[5] kinds = { tree::NodeKind.ARRAY_INIT_EXPR, tree::NodeKind.STRUCT_INIT_EXPR,
		tree::NodeKind.UNION_INIT_EXPR, tree::NodeKind.ARRAY_FILLER_EXPR, tree::NodeKind.DEFAULT_INIT_EXPR };
	foreach (kind : kinds)
	{
		CodeGenFixture f;
		f.init();
		NodeIndex initializer;
		switch (kind)
		{
			case ARRAY_INIT_EXPR: case STRUCT_INIT_EXPR:
				initializer = f.tree.add_node({ .kind = kind,
					.container_init = { .container_qt = type_store::INT } });
			case UNION_INIT_EXPR:
				initializer = f.tree.add_node({ .kind = kind,
					.union_init = { .union_qt = type_store::INT } });
			case ARRAY_FILLER_EXPR:
				initializer = f.tree.add_node({ .kind = kind,
					.array_filler = { .qt = type_store::INT, .count = 1 } });
			case DEFAULT_INIT_EXPR:
				initializer = f.tree.add_node({ .kind = kind,
					.default_init = { .qt = type_store::INT } });
			default: unreachable();
		}
		f.expect_local_initializer_fatal(initializer, type_store::INT,
			string::tformat("TODO CodeGen.genInitializer %s\n", kind.name));
		f.free();
	}
}

fn void gen_ir_rejects_string_array_initializer_memcpy() @test
{
	CodeGenFixture f;
	f.init();
	NodeIndex initializer = f.tree.add_node({ .kind = tree::NodeKind.STRING_LITERAL_EXPR,
		.char_literal = { .qt = type_store::CHAR } });
	f.tree.set_value(initializer, value::intern(&f.comp, { .tag = BYTES, .bytes = "abc" }));
	type_store::QualType array_type = f.comp.type_store.put(
		type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 4));
	f.expect_local_initializer_fatal(initializer, array_type, "TODO memcpy\n");
	f.free();
}

fn void gen_ir_rejects_builtin_call() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.builtins.get_or_create(&f.comp, "__builtin_trap")!!;
	NodeIndex call = f.tree.add_node({ .kind = tree::NodeKind.BUILTIN_CALL_EXPR,
		.builtin_call = { .builtin_tok = 1, .qt = type_store::VOID, .args = {} } });
	f.expect_expression_fatal(call, "TODO CodeGen.genBuiltinCall __builtin_trap\n");
	f.free();
}

struct Fixture
{
	TrackingAllocator ta;
	Interner interner;
	Ir graph;
	ir::Builder builder;
}

// These hand-built trees exercise the public gen_ir entry point directly;
// Parser.parse is intentionally not part of this fixture.
fn void gen_ir_lowers_scalar_expression_return() @test
{
	CodeGenFixture f;
	f.init();
	NodeIndex lhs = f.int_literal(20);
	NodeIndex rhs = f.int_literal(22);
	NodeIndex sum = f.tree.add_node({ .kind = tree::NodeKind.ADD_EXPR,
		.binary = { .qt = type_store::INT, .lhs = lhs, .op_tok = 0, .rhs = rhs } });
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::INT, .operand = tree::ReturnOperandKind.EXPR,
			.expr = sum } });
	NodeIndex[1] statements = { ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function(body);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	assert(graph.decls.len() == 1);
	ir::Decl* decl = &graph.decls[0];
	test::eq(decl.name, "answer");
	ir::Ref add_ref = ir::NONE;
	ir::Ref returned_ref = ir::NONE;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.ADD) add_ref = (ir::Ref)i;
		if (inst.tag == ir::InstTag.RET) returned_ref = inst.data.ref;
	}
	assert(add_ref != ir::NONE, "the AST addition should lower to an ADD instruction");
	assert(returned_ref == add_ref, "the scalar return should return the lowered expression");
	ir::Inst add = decl.instructions[(usz)add_ref];
	assert(add.ty == value_interner::REF_I32);
	ir::Inst lhs_constant = decl.instructions[(usz)add.data.bin.lhs];
	ir::Inst rhs_constant = decl.instructions[(usz)add.data.bin.rhs];
	assert(lhs_constant.tag == ir::InstTag.CONSTANT && rhs_constant.tag == ir::InstTag.CONSTANT);
	assert(lhs_constant.data.constant == value::int_i64(20, &f.comp).ref());
	assert(rhs_constant.data.constant == value::int_i64(22, &f.comp).ref());
	graph.free();
	f.free();
}

fn void gen_ir_lowers_if_branch_and_return_phi() @test
{
	CodeGenFixture f;
	f.init();
	NodeIndex three = f.int_literal(3);
	NodeIndex five = f.int_literal(5);
	NodeIndex condition = f.tree.add_node({ .kind = tree::NodeKind.LESS_THAN_EXPR,
		.binary = { .qt = type_store::BOOL, .lhs = three, .op_tok = 0, .rhs = five } });
	NodeIndex yes_value = f.int_literal(11);
	NodeIndex no_value = f.int_literal(29);
	NodeIndex yes_return = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::INT, .operand = tree::ReturnOperandKind.EXPR,
			.expr = yes_value } });
	NodeIndex no_return = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::INT, .operand = tree::ReturnOperandKind.EXPR,
			.expr = no_value } });
	NodeIndex branch = f.tree.add_node({ .kind = tree::NodeKind.IF_STMT,
		.if_stmt = { .if_tok = 0, .init = type_store::NODE_NULL, .cond = condition,
			.then_body = yes_return, .else_body = no_return.pack() } });
	NodeIndex[1] statements = { branch };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function(body);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	assert(graph.decls.len() == 1);
	ir::Decl* decl = &graph.decls[0];
	ir::Ref comparison = ir::NONE;
	ir::Ref branch_condition = ir::NONE;
	bool saw_jump = false;
	ir::Ref return_phi = ir::NONE;
	ir::Ref returned_ref = ir::NONE;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.CMP_LT) comparison = (ir::Ref)i;
		if (inst.tag == ir::InstTag.BRANCH) branch_condition = inst.data.branch.cond;
		if (inst.tag == ir::InstTag.JMP) saw_jump = true;
		if (inst.tag == ir::InstTag.PHI)
		{
			return_phi = (ir::Ref)i;
			assert(inst.ty == value_interner::REF_I32);
			assert(inst.data.phi.len == 2, "both return paths should feed the return phi");
			foreach (input : inst.data.phi)
			{
				assert(decl.instructions[(usz)input.label].tag == ir::InstTag.LABEL);
				assert(decl.instructions[(usz)input.value].tag == ir::InstTag.CONSTANT);
			}
		}
		if (inst.tag == ir::InstTag.RET) returned_ref = inst.data.ref;
	}
	assert(comparison != ir::NONE, "the comparison expression should lower to CMP_LT");
	assert(branch_condition == comparison, "the if branch should use its lowered comparison");
	assert(saw_jump, "each return path should jump to the shared return block");
	assert(return_phi != ir::NONE && returned_ref == return_phi,
		"the two scalar returns should join in a typed phi returned by the function");
	graph.free();
	f.free();
}

fn void Fixture.init(&self)
{
	self.ta.init(mem);
	self.interner.init(&self.ta);
	self.builder.init(&self.ta, &self.interner);
}

fn void Fixture.free(&self)
{
	self.graph.free();
	self.builder.free();
	self.interner.free();
	assert(self.ta.allocation_count() == 0, "typed IR ownership leaked allocations");
	self.ta.free();
}

fn void declarations_and_scalar_expressions_keep_their_types() @test
{
	Fixture f;
	f.init();
	ir::Builder* b = &f.builder;

	b.start_fn();
	Ref narrow = b.add_arg(value_interner::REF_I8);
	Ref addend = b.add_arg(value_interner::REF_I32);
	Ref widened = b.add_inst(ZEXT, { .ref = narrow }, value_interner::REF_I32);
	Ref sum = b.add_inst(ADD, { .bin = { widened, addend } }, value_interner::REF_I32);
	b.add_return(sum);
	b.finish_fn("extend_and_add");

	f.graph = b.finish();
	assert(f.graph.decls.len() == 1);
	Decl* decl = &f.graph.decls[0];
	test::eq(decl.name, "extend_and_add");
	assert(decl.instructions[(sz)narrow].tag == InstTag.ARG);
	assert(decl.instructions[(sz)narrow].ty == value_interner::REF_I8);
	assert(decl.instructions[(sz)addend].ty == value_interner::REF_I32);
	assert(decl.instructions[(sz)widened].tag == InstTag.ZEXT);
	assert(decl.instructions[(sz)widened].data.ref == narrow);
	assert(decl.instructions[(sz)widened].ty == value_interner::REF_I32);
	assert(decl.instructions[(sz)sum].tag == InstTag.ADD);
	assert(decl.instructions[(sz)sum].data.bin.lhs == widened);
	assert(decl.instructions[(sz)sum].data.bin.rhs == addend);
	assert(decl.instructions[(sz)sum].ty == value_interner::REF_I32);
	f.free();
}

fn void branch_and_phi_form_typed_control_flow() @test
{
	Fixture f;
	f.init();
	ir::Builder* b = &f.builder;

	b.start_fn();
	Ref condition = b.add_arg(value_interner::REF_I1);
	Ref yes_label = b.make_label("yes");
	Ref no_label = b.make_label("no");
	Ref join_label = b.make_label("join");
	b.add_branch(condition, yes_label, no_label);

	b.start_block(yes_label);
	Ref yes_value = b.add_constant(f.interner.put({ .tag = INT, .int_val = { .tag = I64, .i64 = 17 } }), value_interner::REF_I32);
	b.add_jump(join_label);

	b.start_block(no_label);
	Ref no_value = b.add_constant(f.interner.put({ .tag = INT, .int_val = { .tag = I64, .i64 = 29 } }), value_interner::REF_I32);
	b.add_jump(join_label);

	b.start_block(join_label);
	PhiInput[2] incoming = {
		{ .label = yes_label, .value = yes_value },
		{ .label = no_label, .value = no_value },
	};
	Ref merged = b.add_phi(incoming[..], value_interner::REF_I32);
	b.add_return(merged);
	b.finish_fn("choose_value");

	f.graph = b.finish();
	Decl* decl = &f.graph.decls[0];
	assert(decl.instructions[(sz)condition].ty == value_interner::REF_I1);
	assert(decl.instructions[(sz)yes_label].tag == InstTag.LABEL);
	assert(decl.instructions[(sz)no_label].tag == InstTag.LABEL);
	assert(decl.instructions[(sz)join_label].tag == InstTag.LABEL);
	Ref branch = decl.body[2];
	assert(decl.instructions[(sz)branch].tag == InstTag.BRANCH);
	assert(decl.instructions[(sz)branch].data.branch.cond == condition);
	assert(decl.instructions[(sz)branch].data.branch.then_label == yes_label);
	assert(decl.instructions[(sz)branch].data.branch.else_label == no_label);
	assert(decl.instructions[(sz)merged].tag == InstTag.PHI);
	assert(decl.instructions[(sz)merged].ty == value_interner::REF_I32);
	assert(decl.instructions[(sz)merged].data.phi.len == 2);
	assert(decl.instructions[(sz)merged].data.phi[0].label == yes_label);
	assert(decl.instructions[(sz)merged].data.phi[0].value == yes_value);
	assert(decl.instructions[(sz)merged].data.phi[1].label == no_label);
	assert(decl.instructions[(sz)merged].data.phi[1].value == no_value);
	f.free();
}

fn void replacing_a_declaration_releases_its_owned_payloads() @test
{
	Fixture f;
	f.init();
	ir::Builder* b = &f.builder;

	b.start_fn();
	Ref old_arg = b.add_arg(value_interner::REF_I32);
	Ref callee = b.add_symbol("callee", value_interner::REF_FUNC);
	Ref[1] call_args = { old_arg };
	Ref call = b.add_call(callee, call_args[..], value_interner::REF_I32);
	b.add_return(call);
	b.finish_fn("replace_me");

	// The replacement must own fresh instruction/body slices and must not keep
	// the previous declaration's call-argument arena alive.
	b.start_fn();
	Ref new_arg = b.add_arg(value_interner::REF_I64);
	b.add_return(new_arg);
	b.finish_fn("replace_me");
	f.graph = b.finish();

	assert(f.graph.decls.len() == 1, "a repeated declaration name should replace the old IR declaration");
	Decl* decl = &f.graph.decls[0];
	test::eq(decl.name, "replace_me");
	assert(decl.instructions[(sz)new_arg].tag == InstTag.ARG);
	assert(decl.instructions[(sz)new_arg].ty == value_interner::REF_I64);
	assert(decl.instructions.len == 3);
	f.free();
}

fn void typed_ir_build_reports_per_decl_renderer_failure() @test
{
	Fixture f;
	f.init();
	f.builder.start_fn();
	Ref value = f.builder.add_arg(value_interner::REF_I32);
	f.builder.add_return(value);
	f.builder.finish_fn("identity");
	f.graph = f.builder.finish();
	assert(f.graph.decls.len() == 1, "IR construction should complete before target rendering");

	target::Target? target = target::parse_triple("x86_64-linux-gnu", target::host()!!);
	if (catch err = target) unreachable("renderer test target must parse");
	ir::ErrorList errors;
	errors.init(&f.ta);
	object::Object*? rendered = ir::render(&f.graph, &f.ta, target, &errors);
	fault render_fault = @catch(rendered);
	assert(render_fault == ir::LOWER_FAIL, "a typed function should report LOWER_FAIL");
	assert(errors.len() == 1, "renderer should report one failure for the typed declaration");
	test::eq(errors.name_at(0), "identity");
	test::eq(errors.message_at(0), "TODO implement lowering functions");
	errors.free();
	f.free();
}
