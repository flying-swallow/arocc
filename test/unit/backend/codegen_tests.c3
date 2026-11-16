// Focused checks for AST-to-IR lowering and typed IR construction. Expected IR
// shapes are source-derived from src/codegen.c3, codegen_nodes.c3, and
// backend/ir.c3; this is not executable differential coverage against Zig.
module codegen_tests;
import aro::primitive_value;
import std, aro::backend::ir, aro::backend::ir_opt, aro::backend::object, aro::builtins, aro::codegen, aro::compilation, aro::diagnostics, aro::preprocessor, aro::target;
import aro::source, aro::tokens, aro::tokenizer, aro::tree, aro::type_store;
import aro::value, aro::value_interner;
import std::core::dstring, std::core::string;

struct CodeGenFixture
{
	TrackingAllocator ta;
	Diagnostics diagnostics;
	Compilation comp;
	tokens::TreeToken[4] tokens;
	Tree tree;
	Preprocessor pp;
}

fn void CodeGenFixture.init(&self)
{
	self.ta.init(mem);
	self.diagnostics.init_list(&self.ta);
	self.comp.init(&self.ta, null, &self.diagnostics);
	Source src = self.comp.add_source_from_buffer("codegen.c", "answer __builtin_longjmp target ptr")!!;
	self.tokens[0] = { .id = tokenizer::TokenId.IDENTIFIER,
		.loc = { .id = src.id, .byte_offset = 0, .line = 1 } };
	self.tokens[1] = { .id = tokenizer::TokenId.IDENTIFIER,
		.loc = { .id = src.id, .byte_offset = 7, .line = 1 } };
	self.tokens[2] = { .id = tokenizer::TokenId.IDENTIFIER,
		.loc = { .id = src.id, .byte_offset = 25, .line = 1 } };
	self.tokens[3] = { .id = tokenizer::TokenId.IDENTIFIER,
		.loc = { .id = src.id, .byte_offset = 32, .line = 1 } };
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

fn NodeIndex CodeGenFixture.function_with_return_type(&self, NodeIndex body, type_store::QualType return_type,
	bool is_static = false)
{
	type_store::QualType function_type = self.comp.type_store.put(
		type_store::type_func(return_type, type_store::FuncKind.NORMAL, {}));
	NodeIndex function = self.tree.add_node({ .kind = tree::NodeKind.FUNCTION,
		.function = { .name_tok = 0, .qt = function_type, .is_static = is_static, .body = body.pack(),
			.definition = type_store::NODE_NULL } });
	self.tree.root_decls.push(function);
	return function;
}

fn NodeIndex CodeGenFixture.add_global(&self, tokens::TokenIndex name_tok, type_store::QualType qt,
	tree::VariableStorageClass storage_class = tree::VariableStorageClass.AUTO,
	type_store::NodeOptIndex initializer = type_store::NODE_NULL, bool thread_local = false)
{
	NodeIndex variable = self.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = name_tok, .qt = qt, .storage_class = storage_class,
			.thread_local = thread_local, .initializer = initializer, .definition = type_store::NODE_NULL } });
	self.tree.root_decls.push(variable);
	return variable;
}

fn String dump_to_string(ir::Ir* graph, Allocator allocator)
{
	DString output;
	output.init(allocator);
	defer output.free();
	Terminal term = { .writer = &output, .mode = diagnostics::ColorMode.NO_COLOR };
	graph.dump(term)!!;
	return output.copy_str(allocator);
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

fn void gen_ir_lowers_tentative_global() @test
{
	CodeGenFixture f;
	f.init();
	f.add_global(0, type_store::INT);
	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	assert(graph.decls.len() == 1);
	assert(graph.decls[0].kind == ir::DeclKind.GLOBAL);
	test::eq(graph.decls[0].name, "answer");
	assert(graph.decls[0].global.section == ir::DataSection.BSS);
	assert(graph.decls[0].global.tentative);
	assert(graph.decls[0].global.size == 4 && graph.decls[0].global.align == 4);
	assert(graph.decls[0].global.bytes.len == 0);
	graph.free();
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
	tree::NodeKind[3] kinds = { tree::NodeKind.COMPUTED_GOTO_STMT,
		tree::NodeKind.ASM_STMT, tree::NodeKind.NULLPTR_LITERAL };
	foreach (kind : kinds)
	{
		CodeGenFixture f;
		f.init();
		NodeIndex expression = f.int_literal(0);
		NodeIndex statement;
		switch (kind)
		{
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
	tree::NodeKind[4] kinds = { tree::NodeKind.MEMBER_ACCESS_EXPR, tree::NodeKind.MEMBER_ACCESS_PTR_EXPR,
		tree::NodeKind.COMPOUND_LITERAL_EXPR, tree::NodeKind.COMPOUND_LITERAL_EXPR };
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
		else
		{
			NodeIndex initializer = f.int_literal(1);
			lvalue = f.tree.add_node({ .kind = kind,
				.compound_literal = { .qt = type_store::INT, .thread_local = i == 3,
					.storage_class = i == 2 ? tree::CompoundLiteralStorageClass.STATIC : tree::CompoundLiteralStorageClass.AUTO,
					.initializer = initializer } });
		}
		NodeIndex rhs = f.int_literal(1);
		NodeIndex assignment = f.tree.add_node({ .kind = tree::NodeKind.ASSIGN_EXPR,
			.binary = { .qt = type_store::INT, .lhs = lvalue, .rhs = rhs } });
		String expected = i < 2
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
	// __builtin_trap now lowers to abort(); __builtin_longjmp is still unsupported.
	f.comp.builtins.get_or_create(&f.comp, "__builtin_longjmp")!!;
	NodeIndex call = f.tree.add_node({ .kind = tree::NodeKind.BUILTIN_CALL_EXPR,
		.builtin_call = { .builtin_tok = 1, .qt = type_store::VOID, .args = {} } });
	f.expect_expression_fatal(call, "TODO CodeGen.genBuiltinCall __builtin_longjmp\n");
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
		if (inst.tag == ir::InstTag.CMP_SLT) comparison = (ir::Ref)i;
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
	assert(comparison != ir::NONE, "the comparison expression should lower to CMP_SLT");
	assert(branch_condition == comparison, "the if branch should use its lowered comparison");
	assert(saw_jump, "each return path should jump to the shared return block");
	assert(return_phi != ir::NONE && returned_ref == return_phi,
		"the two scalar returns should join in a typed phi returned by the function");
	graph.free();
	f.free();
}

fn void gen_ir_lowers_array_decay_return_through_address_path() @test
{
	CodeGenFixture f;
	f.init();
	type_store::QualType array_qt = f.comp.type_store.put(
		type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 4));
	type_store::QualType pointer_qt = f.comp.type_store.put(type_store::type_pointer(type_store::CHAR));
	NodeIndex buf = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 0, .qt = array_qt, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex buf_ref = f.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
		.decl_ref = { .name_tok = 0, .qt = array_qt, .decl = buf } });
	NodeIndex decay = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.ARRAY_TO_POINTER, .operand = buf_ref, .qt = pointer_qt,
			.implicit = true } });
	f.tree.set_value(decay, value::pointer({ .node = (uint)buf, .offset = value::ZERO.ref() }, &f.comp));
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = pointer_qt, .operand = tree::ReturnOperandKind.EXPR, .expr = decay } });
	NodeIndex[2] statements = { buf, ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, pointer_qt);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	assert(graph.decls.len() == 1);
	ir::Decl* decl = &graph.decls[0];
	ir::Ref buf_alloc = ir::NONE;
	ir::Ref returned_ref = ir::NONE;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.ALLOC) buf_alloc = (ir::Ref)i;
		if (inst.tag == ir::InstTag.RET) returned_ref = inst.data.ref;
		if (inst.tag == ir::InstTag.CONSTANT)
		{
			assert(f.comp.interner.get(inst.data.constant).tag != primitive_value::PrimitiveType.POINTER,
				"array decay should not lower as a pointer constant");
		}
	}
	assert(buf_alloc != ir::NONE, "the local array should lower to an ALLOC instruction");
	assert(returned_ref == buf_alloc, "the decayed array return should use the array address");
	graph.free();
	f.free();
}

fn void gen_ir_lowers_string_array_decay_return_as_pointer_constant() @test
{
	CodeGenFixture f;
	f.init();
	type_store::QualType array_qt = f.comp.type_store.put(
		type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 4));
	type_store::QualType pointer_qt = f.comp.type_store.put(type_store::type_pointer(type_store::CHAR));
	NodeIndex literal = f.tree.add_node({ .kind = tree::NodeKind.STRING_LITERAL_EXPR,
		.char_literal = { .qt = array_qt } });
	value::Value bytes = value::intern(&f.comp, { .tag = primitive_value::PrimitiveType.BYTES,
		.bytes = "abc" });
	f.tree.set_value(literal, bytes);
	NodeIndex decay = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.ARRAY_TO_POINTER, .operand = literal, .qt = pointer_qt,
			.implicit = true } });
	f.tree.set_value(decay, bytes);
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = pointer_qt, .operand = tree::ReturnOperandKind.EXPR, .expr = decay } });
	NodeIndex[1] statements = { ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, pointer_qt);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	assert(graph.decls.len() == 1);
	ir::Decl* decl = &graph.decls[0];
	ir::Ref string_address = ir::NONE;
	ir::Ref returned_ref = ir::NONE;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.CONSTANT)
		{
			assert(inst.ty == value_interner::REF_PTR,
				"string array decay constants should use the pointer IR type");
			primitive_value::PrimitiveValue key = f.comp.interner.get(inst.data.constant);
			if (key.tag == primitive_value::PrimitiveType.BYTES)
			{
				assert(inst.ty == value_interner::REF_PTR,
					"a BYTES constant must not have a non-pointer IR type");
				string_address = (ir::Ref)i;
			}
		}
		if (inst.tag == ir::InstTag.RET) returned_ref = inst.data.ref;
	}
	assert(string_address != ir::NONE, "string array decay should produce its BYTES address constant");
	assert(returned_ref == string_address,
		"the char* return should use the address produced for the string decay cast");
	graph.free();
	f.free();
}

fn void gen_ir_lowers_array_decay_initializer_through_address_path() @test
{
	CodeGenFixture f;
	f.init();
	type_store::QualType array_qt = f.comp.type_store.put(
		type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 4));
	type_store::QualType pointer_qt = f.comp.type_store.put(type_store::type_pointer(type_store::CHAR));
	NodeIndex buf = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 0, .qt = array_qt, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex buf_ref = f.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
		.decl_ref = { .name_tok = 0, .qt = array_qt, .decl = buf } });
	NodeIndex decay = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.ARRAY_TO_POINTER, .operand = buf_ref, .qt = pointer_qt,
			.implicit = true } });
	f.tree.set_value(decay, value::pointer({ .node = (uint)buf, .offset = value::ZERO.ref() }, &f.comp));
	NodeIndex ptr = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 1, .qt = pointer_qt, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = decay.pack(), .definition = type_store::NODE_NULL } });
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::VOID, .operand = tree::ReturnOperandKind.NONE } });
	NodeIndex[3] statements = { buf, ptr, ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, type_store::VOID);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	assert(graph.decls.len() == 1);
	ir::Decl* decl = &graph.decls[0];
	ir::Ref buf_alloc = ir::NONE;
	bool stored_buf_address = false;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.ALLOC && buf_alloc == ir::NONE) buf_alloc = (ir::Ref)i;
		if (inst.tag == ir::InstTag.STORE && inst.data.bin.rhs == buf_alloc) stored_buf_address = true;
		if (inst.tag == ir::InstTag.CONSTANT)
		{
			assert(f.comp.interner.get(inst.data.constant).tag != primitive_value::PrimitiveType.POINTER,
				"array decay initializer should not lower as a pointer constant");
		}
	}
	assert(buf_alloc != ir::NONE, "the local array should lower to an ALLOC instruction");
	assert(stored_buf_address, "the pointer initializer should store the local array address");
	graph.free();
	f.free();
}

fn void gen_ir_lowers_folded_pointer_add_through_address_path() @test
{
	CodeGenFixture f;
	f.init();
	type_store::QualType array_qt = f.comp.type_store.put(
		type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 4));
	type_store::QualType pointer_qt = f.comp.type_store.put(type_store::type_pointer(type_store::CHAR));
	NodeIndex buf = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 0, .qt = array_qt, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex buf_ref = f.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
		.decl_ref = { .name_tok = 0, .qt = array_qt, .decl = buf } });
	NodeIndex decay = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.ARRAY_TO_POINTER, .operand = buf_ref, .qt = pointer_qt,
			.implicit = true } });
	f.tree.set_value(decay, value::pointer({ .node = (uint)buf, .offset = value::ZERO.ref() }, &f.comp));
	NodeIndex one = f.int_literal(1);
	NodeIndex add = f.tree.add_node({ .kind = tree::NodeKind.ADD_EXPR,
		.binary = { .qt = pointer_qt, .lhs = decay, .op_tok = 0, .rhs = one } });
	f.tree.set_value(add, value::pointer({ .node = (uint)buf, .offset = value::ZERO.ref() }, &f.comp));
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = pointer_qt, .operand = tree::ReturnOperandKind.EXPR, .expr = add } });
	NodeIndex[2] statements = { buf, ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, pointer_qt);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	assert(graph.decls.len() == 1);
	ir::Decl* decl = &graph.decls[0];
	bool saw_pointer_add = false;
	foreach (inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.ADD) saw_pointer_add = true;
		if (inst.tag == ir::InstTag.CONSTANT)
		{
			assert(f.comp.interner.get(inst.data.constant).tag != primitive_value::PrimitiveType.POINTER,
				"folded pointer addition should not lower as a pointer constant");
		}
	}
	assert(saw_pointer_add, "folded pointer addition should lower through pointer arithmetic");
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
	Ref yes_value = b.add_constant(f.interner.put(primitive_value::int_key(17)), value_interner::REF_I32);
	b.add_jump(join_label);

	b.start_block(no_label);
	Ref no_value = b.add_constant(f.interner.put(primitive_value::int_key(29)), value_interner::REF_I32);
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

fn void gen_ir_lowers_tentative_globals_to_bss_and_common() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.code_gen_options.common = true;
	f.add_global(0, type_store::INT, tree::VariableStorageClass.STATIC);
	f.add_global(2, type_store::INT);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	assert(graph.decls.len() == 2);
	assert(graph.decls[0].kind == ir::DeclKind.GLOBAL);
	test::eq(graph.decls[0].name, "answer");
	assert(graph.decls[0].linkage == ir::Linkage.INTERNAL);
	assert(graph.decls[0].global.section == ir::DataSection.BSS);
	assert(graph.decls[0].global.tentative);
	assert(graph.decls[0].global.size == 4 && graph.decls[0].global.align == 4);
	assert(graph.decls[0].global.bytes.len == 0);
	assert(graph.decls[1].kind == ir::DeclKind.GLOBAL);
	test::eq(graph.decls[1].name, "target");
	assert(graph.decls[1].linkage == ir::Linkage.EXTERNAL);
	assert(graph.decls[1].global.section == ir::DataSection.COMMON);
	assert(graph.decls[1].global.tentative);
	assert(graph.decls[1].global.size == 4 && graph.decls[1].global.align == 4);
	assert(graph.decls[1].global.bytes.len == 0);
	String dump = dump_to_string(&graph, &f.ta);
	test::eq(dump,
		"global @answer size 4 align 4 bss internal tentative\n\n"
		"global @target size 4 align 4 common tentative\n\n");
	alloc::free(&f.ta, dump.ptr);
	graph.free();
	f.free();
}

fn void gen_ir_dumps_extern_global_exactly() @test
{
	CodeGenFixture f;
	f.init();
	f.add_global(3, type_store::INT, tree::VariableStorageClass.EXTERN);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	assert(graph.decls.len() == 1);
	assert(graph.decls[0].kind == ir::DeclKind.GLOBAL);
	assert(graph.decls[0].global.section == ir::DataSection.EXTERN);
	String dump = dump_to_string(&graph, &f.ta);
	test::eq(dump, "extern @ptr\n\n");
	alloc::free(&f.ta, dump.ptr);
	graph.free();
	f.free();
}

fn void gen_ir_lowers_static_int_initializer() @test
{
	CodeGenFixture f;
	f.init();
	NodeIndex initial_value = f.int_literal(5);
	f.add_global(0, type_store::INT, tree::VariableStorageClass.STATIC, initial_value.pack());

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	assert(graph.decls.len() == 1);
	ir::Decl* global = &graph.decls[0];
	assert(global.kind == ir::DeclKind.GLOBAL);
	test::eq(global.name, "answer");
	assert(global.linkage == ir::Linkage.INTERNAL);
	assert(global.global.section == ir::DataSection.DATA);
	assert(!global.global.tentative);
	assert(global.global.size == 4 && global.global.align == 4);
	assert(global.global.bytes.len == 4);
	assert(global.global.bytes[0] == 5 && global.global.bytes[1] == 0 &&
		global.global.bytes[2] == 0 && global.global.bytes[3] == 0);
	String dump = dump_to_string(&graph, &f.ta);
	test::eq(dump, "global @answer size 4 align 4 data internal {\n"
		"    bytes \"\\x05\\x00\\x00\\x00\"\n"
		"}\n\n");
	alloc::free(&f.ta, dump.ptr);
	graph.free();
	f.free();
}

fn void gen_ir_lowers_address_initializer_to_relocation() @test
{
	CodeGenFixture f;
	f.init();
	NodeIndex target = f.add_global(0, type_store::INT);
	NodeIndex target_ref = f.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
		.decl_ref = { .name_tok = 0, .qt = type_store::INT, .decl = target } });
	NodeIndex pointer_value = f.tree.add_node({ .kind = tree::NodeKind.ADDR_OF_EXPR,
		.unary = { .qt = type_store::INT_POINTER, .operand = target_ref } });
	f.tree.set_value(pointer_value, value::pointer({ .node = (uint)target, .offset = value::int_i64(4, &f.comp).ref() }, &f.comp));
	f.add_global(3, type_store::INT_POINTER, tree::VariableStorageClass.AUTO, pointer_value.pack());

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	assert(graph.decls.len() == 2);
	ir::Decl* pointer_global = &graph.decls[1];
	assert(pointer_global.kind == ir::DeclKind.GLOBAL);
	test::eq(pointer_global.name, "ptr");
	assert(pointer_global.global.section == ir::DataSection.DATA);
	assert(pointer_global.global.relocs.len == 1);
	ir::DataReloc relocation = pointer_global.global.relocs[0];
	assert(relocation.offset == 0);
	test::eq(relocation.symbol, "answer");
	assert(relocation.addend == 4);
	String dump = dump_to_string(&graph, &f.ta);
	test::eq(dump,
		"global @answer size 4 align 4 bss tentative\n\n"
		"global @ptr size 8 align 8 data {\n"
		"    bytes \"\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\"\n"
		"    reloc 0 @answer + 4\n"
		"}\n\n");
	alloc::free(&f.ta, dump.ptr);
	graph.free();
	f.free();
}

fn void gen_ir_lowers_string_pointer_initializer_to_rodata_relocation() @test
{
	CodeGenFixture f;
	f.init();
	type_store::QualType string_type = f.comp.type_store.put(
		type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 4));
	type_store::QualType pointer_type = f.comp.type_store.put(type_store::type_pointer(type_store::CHAR));
	char[4] literal_bytes = { 'a', 'b', 'c', 0 };
	NodeIndex literal = f.tree.add_node({ .kind = tree::NodeKind.STRING_LITERAL_EXPR,
		.char_literal = { .qt = string_type } });
	value::Value bytes = value::intern(&f.comp,
		{ .tag = primitive_value::PrimitiveType.BYTES, .bytes = literal_bytes[..] });
	f.tree.set_value(literal, bytes);
	NodeIndex decay = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.ARRAY_TO_POINTER, .operand = literal,
			.qt = pointer_type, .implicit = true } });
	f.add_global(3, pointer_type, tree::VariableStorageClass.AUTO, decay.pack());

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	assert(graph.decls.len() == 2);
	ir::Decl* string_data = &graph.decls[0];
	test::eq(string_data.name, ".str..0");
	assert(string_data.kind == ir::DeclKind.GLOBAL);
	assert(string_data.linkage == ir::Linkage.INTERNAL);
	assert(string_data.global.section == ir::DataSection.RODATA);
	assert(string_data.global.bytes.len == 4);
	ir::Decl* pointer_data = &graph.decls[1];
	assert(pointer_data.global.relocs.len == 1);
	test::eq(pointer_data.global.relocs[0].symbol, ".str..0");
	String dump = dump_to_string(&graph, &f.ta);
	test::eq(dump,
		"global @.str..0 size 4 align 1 rodata internal {\n"
		"    bytes \"abc\\x00\"\n"
		"}\n\n"
		"global @ptr size 8 align 8 data {\n"
		"    bytes \"\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\"\n"
		"    reloc 0 @.str..0\n"
		"}\n\n");
	alloc::free(&f.ta, dump.ptr);
	graph.free();
	f.free();
}

fn void gen_ir_merges_tentative_global_with_definition() @test
{
	CodeGenFixture f;
	f.init();
	f.add_global(0, type_store::INT);
	NodeIndex initial_value = f.int_literal(9);
	f.add_global(0, type_store::INT, tree::VariableStorageClass.AUTO, initial_value.pack());

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	assert(graph.decls.len() == 1);
	ir::Decl* global = &graph.decls[0];
	assert(global.kind == ir::DeclKind.GLOBAL);
	test::eq(global.name, "answer");
	assert(global.global.section == ir::DataSection.DATA);
	assert(!global.global.tentative);
	assert(global.global.bytes.len == 4 && global.global.bytes[0] == 9);
	graph.free();
	f.free();
}

fn void gen_ir_lowers_block_static_and_reference() @test
{
	CodeGenFixture f;
	f.init();
	NodeIndex initial_value = f.int_literal(7);
	NodeIndex local_static = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 0, .qt = type_store::INT,
			.storage_class = tree::VariableStorageClass.STATIC,
			.initializer = initial_value.pack(), .definition = type_store::NODE_NULL } });
	NodeIndex reference = f.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
		.decl_ref = { .name_tok = 0, .qt = type_store::INT, .decl = local_static } });
	NodeIndex load = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .qt = type_store::INT, .kind = tree::CastKind.LVAL_TO_RVAL, .operand = reference } });
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::INT, .operand = tree::ReturnOperandKind.EXPR, .expr = load } });
	NodeIndex[2] statements = { local_static, ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function(body);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	assert(graph.decls.len() == 2);
	ir::Decl* global = &graph.decls[0];
	assert(global.kind == ir::DeclKind.GLOBAL);
	test::eq(global.name, "answer.answer.0");
	assert(global.linkage == ir::Linkage.INTERNAL);
	assert(global.global.section == ir::DataSection.DATA);
	assert(global.global.bytes.len == 4 && global.global.bytes[0] == 7);
	ir::Decl* function = &graph.decls[1];
	assert(function.kind == ir::DeclKind.FUNCTION);
	ir::Ref symbol = ir::NONE;
	ir::Ref loaded_address = ir::NONE;
	foreach (i, inst : function.instructions)
	{
		if (inst.tag == ir::InstTag.SYMBOL && inst.data.label == global.name) symbol = (ir::Ref)i;
		if (inst.tag == ir::InstTag.LOAD) loaded_address = inst.data.ref;
	}
	assert(symbol != ir::NONE, "the block static reference should use its emitted symbol");
	assert(loaded_address == symbol, "the return should load from the block static symbol");
	String dump = dump_to_string(&graph, &f.ta);
	assert(dump.contains("load ptr_ty @answer.answer.0"),
		"the function dump should load through the mangled block static symbol");
	alloc::free(&f.ta, dump.ptr);
	graph.free();
	f.free();
}

fn void gen_ir_dumps_internal_function() @test
{
	CodeGenFixture f;
	f.init();
	NodeIndex result = f.int_literal(17);
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::INT, .operand = tree::ReturnOperandKind.EXPR, .expr = result } });
	NodeIndex[1] statements = { ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, type_store::INT, true);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	assert(graph.decls.len() == 1);
	assert(graph.decls[0].kind == ir::DeclKind.FUNCTION);
	assert(graph.decls[0].linkage == ir::Linkage.INTERNAL);
	String dump = dump_to_string(&graph, &f.ta);
	test::eq(dump,
		"internal i32 @answer() {\n"
		"entry.0:\n"
		"    ret i32 17\n"
		"}\n\n");
	alloc::free(&f.ta, dump.ptr);
	graph.free();
	f.free();
}

fn void gen_ir_sign_extends_signed_integer_casts() @test
{
	CodeGenFixture f;
	f.init();
	NodeIndex narrow = f.typed_int_literal(-3, type_store::SCHAR);
	NodeIndex widen = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.INT_CAST, .operand = narrow, .qt = type_store::LONG } });
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::LONG, .operand = tree::ReturnOperandKind.EXPR, .expr = widen } });
	NodeIndex[1] statements = { ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, type_store::LONG);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	ir::Decl* decl = &graph.decls[0];
	ir::Ref extension = ir::NONE;
	ir::Ref returned = ir::NONE;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.SEXT) extension = (ir::Ref)i;
		if (inst.tag == ir::InstTag.RET) returned = inst.data.ref;
	}
	assert(extension != ir::NONE, "a signed narrow-to-wide cast should use SEXT");
	assert(decl.instructions[(usz)extension].ty == value_interner::REF_I64);
	assert(decl.instructions[(usz)returned].tag == ir::InstTag.SEXT);
	graph.free();
	f.free();
}

fn void gen_ir_keeps_scaled_pointer_add_result_pointer_typed() @test
{
	CodeGenFixture f;
	f.init();
	type_store::QualType array_qt = f.comp.type_store.put(
		type_store::type_array(type_store::INT, type_store::ArrayLenKind.FIXED, 6));
	type_store::QualType pointer_qt = f.comp.type_store.put(type_store::type_pointer(type_store::INT));
	NodeIndex array = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 0, .qt = array_qt, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex array_ref = f.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
		.decl_ref = { .name_tok = 0, .qt = array_qt, .decl = array } });
	NodeIndex decay = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.ARRAY_TO_POINTER, .operand = array_ref, .qt = pointer_qt, .implicit = true } });
	NodeIndex two = f.int_literal(2);
	NodeIndex add = f.tree.add_node({ .kind = tree::NodeKind.ADD_EXPR,
		.binary = { .qt = pointer_qt, .lhs = decay, .op_tok = 0, .rhs = two } });
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = pointer_qt, .operand = tree::ReturnOperandKind.EXPR, .expr = add } });
	NodeIndex[2] statements = { array, ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, pointer_qt);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	ir::Decl* decl = &graph.decls[0];
	ir::Ref widened_offset = ir::NONE;
	ir::Ref scaled_offset = ir::NONE;
	ir::Ref pointer_add = ir::NONE;
	ir::Ref returned = ir::NONE;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.SEXT && inst.ty == value_interner::REF_I64) widened_offset = (ir::Ref)i;
		if (inst.tag == ir::InstTag.MUL) scaled_offset = (ir::Ref)i;
		if (inst.tag == ir::InstTag.ADD && inst.ty == value_interner::REF_PTR) pointer_add = (ir::Ref)i;
		if (inst.tag == ir::InstTag.RET) returned = inst.data.ref;
	}
	assert(widened_offset != ir::NONE && scaled_offset != ir::NONE,
		"signed int pointer offsets should be sign-extended before scaling");
	assert(widened_offset < scaled_offset && scaled_offset < pointer_add,
		"signed offset extension and scaling should precede the pointer addition");
	assert(pointer_add != ir::NONE && returned == pointer_add,
		"scaled pointer arithmetic should retain the pointer result type");
	assert(decl.instructions[(usz)widened_offset].ty == value_interner::REF_I64);
	assert(decl.instructions[(usz)decl.instructions[(usz)widened_offset].data.ref].ty == value_interner::REF_I32,
		"the SEXT should widen the original signed i32 offset");
	assert(decl.instructions[(usz)scaled_offset].data.bin.lhs == widened_offset,
		"the scaled offset should use the signed widened value");
	ir::Inst scale = decl.instructions[(usz)scaled_offset];
	assert(scale.ty == value_interner::REF_I64,
		"pointer offsets should be widened to ptrdiff_t width before scaling");
	assert(decl.instructions[(usz)scale.data.bin.rhs].data.constant == value::int_i64(4, &f.comp).ref(),
		"int pointer offsets should be scaled by sizeof(int)");
	ir::Inst add_inst = decl.instructions[(usz)pointer_add];
	assert(add_inst.ty == value_interner::REF_PTR && add_inst.data.bin.rhs == scaled_offset,
		"the final ADD should combine the pointer with its scaled offset and remain pointer-typed");
	graph.free();
	f.free();
}

fn void gen_ir_scales_pointer_minus_integer_with_negated_offset() @test
{
	CodeGenFixture f;
	f.init();
	type_store::QualType array_qt = f.comp.type_store.put(
		type_store::type_array(type_store::INT, type_store::ArrayLenKind.FIXED, 6));
	type_store::QualType pointer_qt = f.comp.type_store.put(type_store::type_pointer(type_store::INT));
	NodeIndex array = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 0, .qt = array_qt, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex array_ref = f.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
		.decl_ref = { .name_tok = 0, .qt = array_qt, .decl = array } });
	NodeIndex decay = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.ARRAY_TO_POINTER, .operand = array_ref, .qt = pointer_qt, .implicit = true } });
	NodeIndex two = f.int_literal(2);
	NodeIndex sub = f.tree.add_node({ .kind = tree::NodeKind.SUB_EXPR,
		.binary = { .qt = pointer_qt, .lhs = decay, .op_tok = 0, .rhs = two } });
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = pointer_qt, .operand = tree::ReturnOperandKind.EXPR, .expr = sub } });
	NodeIndex[2] statements = { array, ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, pointer_qt);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	ir::Decl* decl = &graph.decls[0];
	ir::Ref widened_offset = ir::NONE;
	ir::Ref negated_offset = ir::NONE;
	ir::Ref scaled_offset = ir::NONE;
	ir::Ref pointer_add = ir::NONE;
	ir::Ref returned = ir::NONE;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.SEXT && inst.ty == value_interner::REF_I64) widened_offset = (ir::Ref)i;
		if (inst.tag == ir::InstTag.NEGATE && inst.ty == value_interner::REF_I64) negated_offset = (ir::Ref)i;
		if (inst.tag == ir::InstTag.MUL && inst.ty == value_interner::REF_I64) scaled_offset = (ir::Ref)i;
		if (inst.tag == ir::InstTag.ADD)
		{
			assert(inst.ty != value_interner::REF_I32,
				"pointer subtraction must not add the raw i32 offset to the pointer");
			if (inst.ty == value_interner::REF_PTR) pointer_add = (ir::Ref)i;
		}
		if (inst.tag == ir::InstTag.RET) returned = inst.data.ref;
	}
	assert(widened_offset != ir::NONE && negated_offset != ir::NONE && scaled_offset != ir::NONE,
		"pointer subtraction should sign-extend, negate, and scale its integer offset");
	assert(decl.instructions[(usz)decl.instructions[(usz)widened_offset].data.ref].ty == value_interner::REF_I32,
		"the SEXT should widen the original signed i32 offset");
	assert(widened_offset < negated_offset && negated_offset < scaled_offset && scaled_offset < pointer_add,
		"offset widening, negation, and scaling should precede pointer addition");
	assert(decl.instructions[(usz)negated_offset].data.ref == widened_offset,
		"the subtraction should negate the signed widened offset");
	assert(decl.instructions[(usz)scaled_offset].data.bin.lhs == negated_offset,
		"the scaled offset should use the negated value");
	assert(pointer_add != ir::NONE && returned == pointer_add,
		"pointer-minus-integer should return the pointer-typed ADD result");
	ir::Inst add_inst = decl.instructions[(usz)pointer_add];
	assert(add_inst.ty == value_interner::REF_PTR && add_inst.data.bin.rhs == scaled_offset);
	assert(decl.instructions[(usz)scaled_offset].data.bin.rhs != ir::NONE);
	assert(decl.instructions[(usz)decl.instructions[(usz)scaled_offset].data.bin.rhs].data.constant == value::int_i64(4, &f.comp).ref(),
		"pointer offsets should be scaled by sizeof(int)");
	graph.free();
	f.free();
}

fn void gen_ir_scales_pointer_subtraction_to_ptrdiff_elements() @test
{
	CodeGenFixture f;
	f.init();
	type_store::QualType array_qt = f.comp.type_store.put(
		type_store::type_array(type_store::INT, type_store::ArrayLenKind.FIXED, 6));
	type_store::QualType pointer_qt = f.comp.type_store.put(type_store::type_pointer(type_store::INT));
	NodeIndex array = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 0, .qt = array_qt, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex array_ref = f.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
		.decl_ref = { .name_tok = 0, .qt = array_qt, .decl = array } });
	NodeIndex decay = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.ARRAY_TO_POINTER, .operand = array_ref, .qt = pointer_qt, .implicit = true } });
	NodeIndex two = f.int_literal(2);
	NodeIndex advanced = f.tree.add_node({ .kind = tree::NodeKind.ADD_EXPR,
		.binary = { .qt = pointer_qt, .lhs = decay, .op_tok = 0, .rhs = two } });
	NodeIndex difference = f.tree.add_node({ .kind = tree::NodeKind.SUB_EXPR,
		.binary = { .qt = type_store::LONG, .lhs = advanced, .op_tok = 0, .rhs = decay } });
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::LONG, .operand = tree::ReturnOperandKind.EXPR, .expr = difference } });
	NodeIndex[2] statements = { array, ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, type_store::LONG);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	ir::Decl* decl = &graph.decls[0];
	ir::Ref pointer_bytes = ir::NONE;
	ir::Ref element_difference = ir::NONE;
	ir::Ref returned = ir::NONE;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.SUB && inst.ty == value_interner::REF_I64) pointer_bytes = (ir::Ref)i;
		if (inst.tag == ir::InstTag.SDIV && inst.ty == value_interner::REF_I64) element_difference = (ir::Ref)i;
		if (inst.tag == ir::InstTag.RET) returned = inst.data.ref;
	}
	assert(pointer_bytes != ir::NONE, "pointer subtraction should first compute the byte difference");
	assert(element_difference != ir::NONE && returned == element_difference,
		"pointer subtraction should return a signed ptrdiff_t element count");
	ir::Inst divide = decl.instructions[(usz)element_difference];
	assert(divide.data.bin.lhs == pointer_bytes);
	assert(decl.instructions[(usz)divide.data.bin.rhs].data.constant == value::int_i64(4, &f.comp).ref(),
		"pointer differences should be divided by the pointed-to element size");
	graph.free();
	f.free();
}

fn void gen_ir_accepts_pointer_to_pointer_bitcast() @test
{
	CodeGenFixture f;
	f.init();
	type_store::QualType int_pointer = f.comp.type_store.put(type_store::type_pointer(type_store::INT));
	type_store::QualType char_pointer = f.comp.type_store.put(type_store::type_pointer(type_store::CHAR));
	NodeIndex local = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 0, .qt = type_store::INT, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex local_ref = f.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
		.decl_ref = { .name_tok = 0, .qt = type_store::INT, .decl = local } });
	NodeIndex address = f.tree.add_node({ .kind = tree::NodeKind.ADDR_OF_EXPR,
		.unary = { .qt = int_pointer, .operand = local_ref } });
	NodeIndex cast = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.BITCAST, .operand = address, .qt = char_pointer } });
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = char_pointer, .operand = tree::ReturnOperandKind.EXPR, .expr = cast } });
	NodeIndex[2] statements = { local, ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, char_pointer);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	ir::Decl* decl = &graph.decls[0];
	ir::Ref local_address = ir::NONE;
	ir::Ref returned = ir::NONE;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.ALLOC) local_address = (ir::Ref)i;
		if (inst.tag == ir::InstTag.RET) returned = inst.data.ref;
	}
	assert(local_address != ir::NONE && returned == local_address,
		"a pointer-to-pointer BITCAST should preserve the pointer value without a scalar cast");
	graph.free();
	f.free();
}

fn void gen_ir_rejects_thread_local_global() @test
{
	CodeGenFixture f;
	f.init();
	f.add_global(2, type_store::INT, tree::VariableStorageClass.AUTO, type_store::NODE_NULL, true);
	f.expect_fatal("TODO CodeGen.genVar thread_local\n");
	f.free();
}

fn void gen_ir_rejects_aggregate_global_initializer() @test
{
	CodeGenFixture f;
	f.init();
	type_store::QualType array_type = f.comp.type_store.put(
		type_store::type_array(type_store::INT, type_store::ArrayLenKind.FIXED, 1));
	NodeIndex initializer = f.tree.add_node({ .kind = tree::NodeKind.ARRAY_INIT_EXPR,
		.container_init = { .container_qt = array_type, .items = {} } });
	f.add_global(2, array_type, tree::VariableStorageClass.AUTO, initializer.pack());
	f.expect_fatal("TODO CodeGen.genVar initializer array_init_expr\n");
	f.free();
}

fn void render_asm_emits_globals_and_omits_externs() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.target = target::parse_triple("x86_64-linux-gnu", target::host()!!)!!;
	NodeIndex initial_value = f.int_literal(9);
	f.add_global(0, type_store::INT, tree::VariableStorageClass.AUTO, initial_value.pack());
	f.add_global(3, type_store::INT, tree::VariableStorageClass.EXTERN);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	ir::ErrorList errors;
	errors.init(&f.ta);
	String assembly = ir::render_asm(&graph, &f.ta, f.comp.target, &errors)!!;
	test::eq(assembly,
		"\t.intel_syntax noprefix\n"
		"\t.globl answer\n"
		"\t.section .data\n"
		"\t.type answer, @object\n"
		"\t.size answer, 4\n"
		"\t.align 4\n"
		"answer:\n"
		"\t.byte 9, 0, 0, 0\n"
		"\n"
		"\t.section .note.GNU-stack,\"\",@progbits\n");
	assert(errors.len() == 0);
	alloc::free(&f.ta, assembly.ptr);
	errors.free();
	graph.free();
	f.free();
}

fn bool codegen_test_is_terminator(ir::InstTag tag)
{
	switch (tag)
	{
		case JMP: case BRANCH: case SWITCH: case RET: case JMP_VAL: return true;
		default: return false;
	}
}

fn void assert_decl_blocks_terminated(ir::Decl* decl)
{
	bool saw_label = false;
	bool terminated = false;
	uint terminator_count = 0;
	foreach (ref : decl.body)
	{
		ir::Inst inst = decl.instructions[(usz)ref];
		if (inst.tag == ir::InstTag.LABEL)
		{
			if (saw_label) assert(terminator_count == 1, "each basic block must end in exactly one terminator");
			saw_label = true;
			terminated = false;
			terminator_count = 0;
			continue;
		}
		if (!saw_label) continue; // Function arguments precede the entry label.
		assert(!terminated, "an instruction must not follow a block terminator");
		if (codegen_test_is_terminator(inst.tag))
		{
			terminator_count++;
			terminated = true;
		}
	}
	assert(saw_label && terminator_count == 1, "the final basic block must end in exactly one terminator");
}

fn void CodeGenFixture.expect_verifier_success(&self)
{
	ir::Ir graph = codegen::gen_ir(&self.tree, &self.pp)!!;
	defer graph.free();
	assert(graph.decls.len() == 1, "the fixture should lower exactly one function");
	assert_decl_blocks_terminated(&graph.decls[0]);
	ir::ErrorList errors;
	errors.init(&self.ta);
	defer errors.free();
	assert(ir_opt::verify(&graph, &errors), "the IR verifier should accept this control-flow shape");
	assert(errors.len() == 0, "accepted IR should not include verifier errors");
}

fn void gen_ir_verifier_accepts_switch_case_fall_through() @test
{
	CodeGenFixture f;
	f.init();
	NodeIndex condition = f.int_literal(0);
	NodeIndex first_value = f.int_literal(1);
	NodeIndex first_body = f.tree.add_node({ .kind = tree::NodeKind.NULL_STMT });
	NodeIndex first_case = f.tree.add_node({ .kind = tree::NodeKind.CASE_STMT,
		.case_stmt = { .case_tok = 0, .start = first_value, .end = type_store::NODE_NULL,
			.body = first_body } });
	NodeIndex second_value = f.int_literal(2);
	NodeIndex break_stmt = f.tree.add_node({ .kind = tree::NodeKind.BREAK_STMT,
		.break_stmt = { .break_tok = 0 } });
	NodeIndex second_case = f.tree.add_node({ .kind = tree::NodeKind.CASE_STMT,
		.case_stmt = { .case_tok = 0, .start = second_value, .end = type_store::NODE_NULL,
			.body = break_stmt } });
	NodeIndex[2] cases = { first_case, second_case };
	NodeIndex switch_body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = cases[..] } });
	NodeIndex switch_stmt = f.tree.add_node({ .kind = tree::NodeKind.SWITCH_STMT,
		.switch_stmt = { .switch_tok = 0, .init = type_store::NODE_NULL,
			.cond = condition, .body = switch_body } });
	NodeIndex[1] statements = { switch_stmt };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function(body);
	f.expect_verifier_success();
	f.free();
}

fn void gen_ir_verifier_accepts_if_without_else() @test
{
	CodeGenFixture f;
	f.init();
	NodeIndex lhs = f.int_literal(0);
	NodeIndex rhs = f.int_literal(1);
	NodeIndex condition = f.tree.add_node({ .kind = tree::NodeKind.LESS_THAN_EXPR,
		.binary = { .qt = type_store::BOOL, .lhs = lhs, .op_tok = 0, .rhs = rhs } });
	NodeIndex then_body = f.tree.add_node({ .kind = tree::NodeKind.NULL_STMT });
	NodeIndex branch = f.tree.add_node({ .kind = tree::NodeKind.IF_STMT,
		.if_stmt = { .if_tok = 0, .init = type_store::NODE_NULL, .cond = condition,
			.then_body = then_body, .else_body = type_store::NODE_NULL } });
	NodeIndex[1] statements = { branch };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function(body);
	f.expect_verifier_success();
	f.free();
}

fn void gen_ir_verifier_accepts_if_else_with_both_arms_returning() @test
{
	CodeGenFixture f;
	f.init();
	NodeIndex lhs = f.int_literal(0);
	NodeIndex rhs = f.int_literal(1);
	NodeIndex condition = f.tree.add_node({ .kind = tree::NodeKind.LESS_THAN_EXPR,
		.binary = { .qt = type_store::BOOL, .lhs = lhs, .op_tok = 0, .rhs = rhs } });
	NodeIndex then_value = f.int_literal(11);
	NodeIndex then_return = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::INT, .operand = tree::ReturnOperandKind.EXPR,
			.expr = then_value } });
	NodeIndex else_value = f.int_literal(29);
	NodeIndex else_return = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::INT, .operand = tree::ReturnOperandKind.EXPR,
			.expr = else_value } });
	NodeIndex branch = f.tree.add_node({ .kind = tree::NodeKind.IF_STMT,
		.if_stmt = { .if_tok = 0, .init = type_store::NODE_NULL, .cond = condition,
			.then_body = then_return, .else_body = else_return.pack() } });
	NodeIndex[1] statements = { branch };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function(body);
	f.expect_verifier_success();
	f.free();
}

fn void gen_ir_verifier_accepts_while_body_break() @test
{
	CodeGenFixture f;
	f.init();
	NodeIndex lhs = f.int_literal(0);
	NodeIndex rhs = f.int_literal(1);
	NodeIndex condition = f.tree.add_node({ .kind = tree::NodeKind.LESS_THAN_EXPR,
		.binary = { .qt = type_store::BOOL, .lhs = lhs, .op_tok = 0, .rhs = rhs } });
	NodeIndex break_stmt = f.tree.add_node({ .kind = tree::NodeKind.BREAK_STMT,
		.break_stmt = { .break_tok = 0 } });
	NodeIndex loop = f.tree.add_node({ .kind = tree::NodeKind.WHILE_STMT,
		.while_stmt = { .while_tok = 0, .cond = condition, .body = break_stmt } });
	NodeIndex[1] statements = { loop };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function(body);
	f.expect_verifier_success();
	f.free();
}

fn void gen_ir_verifier_accepts_function_with_two_returns() @test
{
	CodeGenFixture f;
	f.init();
	NodeIndex lhs = f.int_literal(0);
	NodeIndex rhs = f.int_literal(1);
	NodeIndex condition = f.tree.add_node({ .kind = tree::NodeKind.LESS_THAN_EXPR,
		.binary = { .qt = type_store::BOOL, .lhs = lhs, .op_tok = 0, .rhs = rhs } });
	NodeIndex then_value = f.int_literal(11);
	NodeIndex then_return = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::INT, .operand = tree::ReturnOperandKind.EXPR,
			.expr = then_value } });
	NodeIndex branch = f.tree.add_node({ .kind = tree::NodeKind.IF_STMT,
		.if_stmt = { .if_tok = 0, .init = type_store::NODE_NULL, .cond = condition,
			.then_body = then_return, .else_body = type_store::NODE_NULL } });
	NodeIndex fallthrough_value = f.int_literal(29);
	NodeIndex fallthrough_return = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::INT, .operand = tree::ReturnOperandKind.EXPR,
			.expr = fallthrough_value } });
	NodeIndex[2] statements = { branch, fallthrough_return };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function(body);
	f.expect_verifier_success();
	f.free();
}
