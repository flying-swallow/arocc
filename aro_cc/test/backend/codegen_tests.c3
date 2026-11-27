// Focused checks for AST-to-IR lowering and typed IR construction. Expected IR
// shapes are source-derived from src/frontend/c/codegen.c3, codegen_nodes.c3, and
// backend/ir.c3; this is not executable differential coverage against Zig.
module codegen_tests;
import aro::primitive_value;
import std, aro::backend::ir, aro::backend::ir_opt, aro::backend::object, aro::frontend::c::builtins, aro::frontend::c::codegen, aro::frontend::c::compilation, aro::frontend::c::diagnostics, aro::frontend::c::preprocessor, aro::target;
import aro::source, aro::frontend::c::tokens, aro::frontend::c::tokenizer, aro::frontend::c::tree, aro::frontend::c::type_store;
import aro::frontend::c::value, aro::value_interner;
import std::core::dstring, std::core::string;

struct CodeGenFixture
{
	TrackingAllocator ta;
	Diagnostics diagnostics;
	Compilation comp;
	tokens::TreeToken[11] tokens;
	Tree tree;
	Preprocessor pp;
}

fn void CodeGenFixture.init(&self)
{
	self.ta.init(mem);
	self.diagnostics.init_list(&self.ta);
	self.comp.init(&self.ta, null, &self.diagnostics);
	// These fixtures construct SysV-specific ASTs and expected IR explicitly.
	self.comp.target = target::parse_triple("x86_64-linux-gnu", target::host()!!)!!;
	type_store::init_named_types(&self.comp);
	String source_text = "answer __builtin_longjmp target ptr va_start va_end va_copy __builtin_va_start __builtin_va_end __builtin_va_copy __builtin_va_arg";
	Source src = self.comp.add_source_from_buffer("codegen.c", source_text)!!;
	self.tokens[0] = { .id = tokenizer::TokenId.IDENTIFIER,
		.loc = { .id = src.id, .byte_offset = 0, .line = 1 } };
	self.tokens[1] = { .id = tokenizer::TokenId.IDENTIFIER,
		.loc = { .id = src.id, .byte_offset = 7, .line = 1 } };
	self.tokens[2] = { .id = tokenizer::TokenId.IDENTIFIER,
		.loc = { .id = src.id, .byte_offset = 25, .line = 1 } };
	self.tokens[3] = { .id = tokenizer::TokenId.IDENTIFIER,
		.loc = { .id = src.id, .byte_offset = 32, .line = 1 } };
	self.tokens[4] = { .id = tokenizer::TokenId.IDENTIFIER,
		.loc = { .id = src.id, .byte_offset = (uint)source_text.index_of("__builtin_va_start")!!, .line = 1 } };
	self.tokens[5] = { .id = tokenizer::TokenId.IDENTIFIER,
		.loc = { .id = src.id, .byte_offset = (uint)source_text.index_of("__builtin_va_end")!!, .line = 1 } };
	self.tokens[6] = { .id = tokenizer::TokenId.IDENTIFIER,
		.loc = { .id = src.id, .byte_offset = (uint)source_text.index_of("__builtin_va_copy")!!, .line = 1 } };
	self.tokens[7] = { .id = tokenizer::TokenId.IDENTIFIER,
		.loc = { .id = src.id, .byte_offset = (uint)source_text.index_of("__builtin_va_arg")!!, .line = 1 } };
	self.tokens[8] = { .id = tokenizer::TokenId.IDENTIFIER,
		.loc = { .id = src.id, .byte_offset = (uint)source_text.index_of("va_start")!!, .line = 1 } };
	self.tokens[9] = { .id = tokenizer::TokenId.IDENTIFIER,
		.loc = { .id = src.id, .byte_offset = (uint)source_text.index_of("va_end")!!, .line = 1 } };
	self.tokens[10] = { .id = tokenizer::TokenId.IDENTIFIER,
		.loc = { .id = src.id, .byte_offset = (uint)source_text.index_of("va_copy")!!, .line = 1 } };
	self.tree.init(&self.comp, self.tokens[..]);
	self.pp.init(&self.comp, preprocessor::TESTING)!!;
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

fn NodeIndex CodeGenFixture.local_ref_value(&self, NodeIndex variable, type_store::QualType qt,
	tokens::TokenIndex name_tok)
{
	NodeIndex reference = self.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
		.decl_ref = { .name_tok = name_tok, .qt = qt, .decl = variable } });
	return self.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.LVAL_TO_RVAL, .operand = reference, .qt = qt, .implicit = true } });
}

fn NodeIndex CodeGenFixture.scalar_local(&self, type_store::QualType qt, tokens::TokenIndex name_tok)
{
	return self.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = name_tok, .qt = qt, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
}

fn type_store::QualType CodeGenFixture.va_list_pointer_type(&self)
{
	type_store::QualType tag = self.comp.type_store.put(type_store::type_record_incomplete(
		self.comp.intern_string("__va_list_tag")));
	return self.comp.type_store.put(type_store::type_pointer(tag));
}

fn type_store::QualType CodeGenFixture.long_record_type(&self, uint field_count)
{
	type_store::RecordField[9] fields;
	for (uint i = 0; i < field_count; i++)
	{
		fields[i] = type_store::record_field(self.comp.intern_string("field"), type_store::LONG_LONG);
		fields[i].layout = { .offset_bits = (ulong)i * 64, .size_bits = 64 };
	}
	type_store::RecordLayout layout = { .size_bits = (ulong)field_count * 64,
		.field_alignment_bits = 64, .pointer_alignment_bits = 64, .required_alignment_bits = 8 };
	return self.comp.type_store.put(type_store::type_record(self.comp.intern_string("LongRecord"),
		fields[0..field_count - 1], layout));
}

fn type_store::QualType CodeGenFixture.computed_record_type(&self, String name, type_store::RecordField[] fields)
{
	type_store::RecordLayout layout = type_store::compute(fields, type_store::NODE_NULL, false,
		&self.comp, &self.tree.attr_map, 0)!!;
	return self.comp.type_store.put(type_store::type_record(self.comp.intern_string(name), fields, layout));
}

fn NodeIndex CodeGenFixture.record_member_lvalue(&self, NodeIndex variable, type_store::QualType record_type,
	type_store::QualType field_type, uint member_index)
{
	NodeIndex base = self.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
		.decl_ref = { .name_tok = 3, .qt = record_type, .decl = variable } });
	return self.tree.add_node({ .kind = tree::NodeKind.MEMBER_ACCESS_EXPR,
		.member_access = { .qt = field_type, .base = base, .access_tok = 0, .member_index = member_index } });
}

fn uint count_dump_occurrences(String text, String needle)
{
	uint count = 0;
	while (try at = text.index_of(needle))
	{
		count++;
		text = text[(usz)at + needle.len..];
	}
	return count;
}

fn uint count_dump_loads_of_type(String text, String type)
{
	uint count = 0;
	usz line_start = 0;
	for (usz i = 0; i <= text.len; i++)
	{
		if (i < text.len && text[i] != '\n') continue;
		if (i > line_start)
		{
			String line = text[line_start..i - 1];
			if (line.contains(type) && line.contains(" = load ptr_ty ")) count++;
		}
		line_start = i + 1;
	}
	return count;
}

fn bool CodeGenFixture.ir_ptr_ref_is_at(&self, ir::Inst[] instructions, ir::Ref pointer, ir::Ref base, ulong offset)
{
	if (offset == 0) return pointer == base;
	if ((usz)pointer >= instructions.len) return false;
	ir::Inst address = instructions[(usz)pointer];
	if (address.tag != ir::InstTag.ADD || address.data.bin.lhs != base) return false;
	ir::Ref offset_ref = address.data.bin.rhs;
	if ((usz)offset_ref >= instructions.len) return false;
	ir::Inst offset_inst = instructions[(usz)offset_ref];
	return offset_inst.tag == ir::InstTag.CONSTANT && offset_inst.ty == value_interner::REF_I64 &&
		offset_inst.data.constant == value::int_u64(offset, &self.comp).ref();
}

fn bool CodeGenFixture.constant_is(&self, ir::Inst[] instructions, ir::Ref reference, ulong number,
	value_interner::InternerRef ty)
{
	if ((usz)reference >= instructions.len) return false;
	ir::Inst inst = instructions[(usz)reference];
	return inst.tag == ir::InstTag.CONSTANT && inst.ty == ty &&
		inst.data.constant == value::int_u64(number, &self.comp).ref();
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

fn NodeIndex CodeGenFixture.function_with_params(&self, NodeIndex body, type_store::QualType return_type,
	type_store::FuncParam[] params)
{
	type_store::QualType function_type = self.comp.type_store.put(
		type_store::type_func(return_type, type_store::FuncKind.NORMAL, params));
	NodeIndex function = self.tree.add_node({ .kind = tree::NodeKind.FUNCTION,
		.function = { .name_tok = 0, .qt = function_type, .body = body.pack(),
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

fn void gen_ir_lowers_union_local_assignment() @test
{
	CodeGenFixture f;
	f.init();
	type_store::RecordField[2] fields = {
		type_store::record_field(f.comp.intern_string("integer"), type_store::INT),
		type_store::record_field(f.comp.intern_string("character"), type_store::CHAR),
	};
	type_store::RecordLayout layout = { .size_bits = 32, .field_alignment_bits = 32,
		.pointer_alignment_bits = 32, .required_alignment_bits = 8 };
	type_store::QualType union_type = f.comp.type_store.put(type_store::type_record(
		f.comp.intern_string("AssignableUnion"), fields[..], layout, true));
	NodeIndex local = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 2, .qt = union_type, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex source = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 3, .qt = union_type, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex local_ref = f.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
		.decl_ref = { .name_tok = 2, .qt = union_type, .decl = local } });
	NodeIndex source_ref = f.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
		.decl_ref = { .name_tok = 3, .qt = union_type, .decl = source } });
	NodeIndex whole_assignment = f.tree.add_node({ .kind = tree::NodeKind.ASSIGN_EXPR,
		.binary = { .qt = union_type, .lhs = local_ref, .rhs = source_ref } });
	NodeIndex reference = f.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
		.decl_ref = { .name_tok = 2, .qt = union_type, .decl = local } });
	NodeIndex member = f.tree.add_node({ .kind = tree::NodeKind.MEMBER_ACCESS_EXPR,
		.member_access = { .qt = type_store::INT, .base = reference, .member_index = 0 } });
	NodeIndex assignment = f.tree.add_node({ .kind = tree::NodeKind.ASSIGN_EXPR,
		.binary = { .qt = type_store::INT, .lhs = member, .rhs = f.int_literal(42) } });
	NodeIndex[4] statements = { local, source, whole_assignment, assignment };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, type_store::VOID);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	ir::Decl* decl = &graph.decls[0];
	ir::Ref storage = ir::NONE;
	bool assigned = false;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.ALLOC && storage == ir::NONE)
		{
			assert(inst.data.alloc.size == 4, "the complete union local should allocate its 4-byte size");
			storage = (ir::Ref)i;
		}
		if (inst.tag == ir::InstTag.STORE && inst.data.bin.lhs == storage)
		{
			assigned = f.constant_is(decl.instructions, inst.data.bin.rhs, 42, value_interner::REF_I32);
		}
	}
	assert(storage != ir::NONE && assigned, "union field assignment should store its value at the local's offset 0");
	bool copied_union = false;
	foreach (inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.LOAD && inst.ty == value_interner::REF_I32) copied_union = true;
	}
	assert(copied_union, "whole-union assignment should copy its object representation");
	graph.free();
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
	// File-scope asm is emitted verbatim; its operand must be a string literal.
	f.expect_fatal("TODO CodeGen inline asm: operand is not a string literal\n");
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
	// COMPUTED_GOTO_STMT lowers to JMP_VAL (computed_goto_O0.c run test).
	tree::NodeKind[2] kinds = { tree::NodeKind.ASM_STMT, tree::NodeKind.NULLPTR_LITERAL };
	foreach (kind : kinds)
	{
		CodeGenFixture f;
		f.init();
		NodeIndex expression = f.int_literal(0);
		NodeIndex statement;
		switch (kind)
		{
			case ASM_STMT:
				statement = f.tree.add_node({ .kind = kind,
					.asm_stmt = { .asm_tok = 0, .asm_str = expression } });
			case NULLPTR_LITERAL:
				statement = f.tree.add_node({ .kind = kind,
					.literal = { .literal_tok = 0, .qt = type_store::NULLPTR_T } });
			default: unreachable();
		}
		// asm statements lower to inline asm calls; this one's template is not a string.
		String expected = kind == tree::NodeKind.ASM_STMT ? "TODO CodeGen inline asm: operand is not a string literal\n"
			: string::tformat("TODO CodeGen.genStmt %s\n", kind.name);
		f.expect_statement_fatal(statement, expected);
		f.free();
	}
}

fn void gen_ir_rejects_unimplemented_expression_nodes() @test
{
	// SIZEOF_EXPR/ALIGNOF_EXPR lower to constants (sizeof_unsaved_value.c run test);
	// ADDR_OF_LABEL lowers to LABEL_ADDR (computed_goto_O0.c).
	tree::NodeKind[4] kinds = { tree::NodeKind.IMAG_EXPR,
		tree::NodeKind.REAL_EXPR, tree::NodeKind.BUILTIN_VA_ARG_PACK,
		tree::NodeKind.BUILTIN_VA_ARG_PACK_LEN };
	foreach (kind : kinds)
	{
		CodeGenFixture f;
		f.init();
		NodeIndex operand = f.int_literal(1);
		NodeIndex expression;
		switch (kind)
		{
			case IMAG_EXPR: case REAL_EXPR:
				expression = f.tree.add_node({ .kind = kind,
					.unary = { .qt = type_store::INT, .operand = operand } });
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
	// POINTER_TO_INT, INT_TO_POINTER and NULL_TO_POINTER are implemented (pointer_casts_lower).
	tree::CastKind[12] kinds = {
		tree::CastKind.BITCAST, tree::CastKind.BOOL_TO_POINTER,
		tree::CastKind.COMPLEX_INT_TO_COMPLEX_FLOAT,
		tree::CastKind.COMPLEX_FLOAT_TO_COMPLEX_INT, tree::CastKind.COMPLEX_INT_CAST,
		tree::CastKind.COMPLEX_INT_TO_REAL,
		tree::CastKind.REAL_TO_COMPLEX_INT, tree::CastKind.COMPLEX_FLOAT_CAST,
		tree::CastKind.COMPLEX_FLOAT_TO_REAL, tree::CastKind.REAL_TO_COMPLEX_FLOAT,
		tree::CastKind.UNION_CAST, tree::CastKind.VECTOR_SPLAT,
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

fn void gen_ir_lowers_scalar_float_arithmetic_and_comparisons() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.target = target::parse_triple("x86_64-linux-gnu", target::host()!!)!!;
	NodeIndex x = f.scalar_local(type_store::DOUBLE, 3);
	NodeIndex y = f.scalar_local(type_store::DOUBLE, 4);
	NodeIndex x_lvalue = f.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
		.decl_ref = { .name_tok = 3, .qt = type_store::DOUBLE, .decl = x } });
	NodeIndex x_value = f.local_ref_value(x, type_store::DOUBLE, 3);
	NodeIndex y_value = f.local_ref_value(y, type_store::DOUBLE, 4);
	NodeIndex[18] statements;
	uint statement_count = 0;
	statements[statement_count++] = x;
	statements[statement_count++] = y;
	tree::NodeKind[4] arithmetic_kinds = { tree::NodeKind.ADD_EXPR, tree::NodeKind.SUB_EXPR,
		tree::NodeKind.MUL_EXPR, tree::NodeKind.DIV_EXPR };
	foreach (kind : arithmetic_kinds)
	{
		statements[statement_count++] = f.tree.add_node({ .kind = kind,
			.binary = { .qt = type_store::DOUBLE, .lhs = x_value, .op_tok = 0, .rhs = y_value } });
	}
	statements[statement_count++] = f.tree.add_node({ .kind = tree::NodeKind.NEGATE_EXPR,
		.unary = { .qt = type_store::DOUBLE, .operand = x_value } });
	tree::NodeKind[6] comparison_kinds = { tree::NodeKind.EQUAL_EXPR, tree::NodeKind.NOT_EQUAL_EXPR,
		tree::NodeKind.LESS_THAN_EXPR, tree::NodeKind.LESS_THAN_EQUAL_EXPR,
		tree::NodeKind.GREATER_THAN_EXPR, tree::NodeKind.GREATER_THAN_EQUAL_EXPR };
	foreach (kind : comparison_kinds)
	{
		statements[statement_count++] = f.tree.add_node({ .kind = kind,
			.binary = { .qt = type_store::INT, .lhs = x_value, .op_tok = 0, .rhs = y_value } });
	}
	tree::NodeKind[4] increment_kinds = { tree::NodeKind.PRE_INC_EXPR, tree::NodeKind.PRE_DEC_EXPR,
		tree::NodeKind.POST_INC_EXPR, tree::NodeKind.POST_DEC_EXPR };
	foreach (kind : increment_kinds)
	{
		statements[statement_count++] = f.tree.add_node({ .kind = kind,
			.unary = { .qt = type_store::DOUBLE, .operand = x_lvalue } });
	}
	NodeIndex dummy = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_ASSIGN_DUMMY_EXPR,
		.unary = { .qt = type_store::DOUBLE, .operand = x_lvalue } });
	NodeIndex dummy_value = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.LVAL_TO_RVAL, .operand = dummy,
			.qt = type_store::DOUBLE, .implicit = true } });
	NodeIndex add_rhs = f.tree.add_node({ .kind = tree::NodeKind.ADD_EXPR,
		.binary = { .qt = type_store::DOUBLE, .lhs = dummy_value, .op_tok = 0, .rhs = y_value } });
	statements[statement_count++] = f.tree.add_node({ .kind = tree::NodeKind.ADD_ASSIGN_EXPR,
		.binary = { .qt = type_store::DOUBLE, .lhs = x_lvalue, .op_tok = 0, .rhs = add_rhs } });
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, type_store::VOID);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	String dump = dump_to_string(&graph, &f.ta);
	assert(count_dump_occurrences(dump, "fadd ") == 4 && count_dump_occurrences(dump, "fsub ") == 3 &&
		count_dump_occurrences(dump, "fmul ") == 1 && count_dump_occurrences(dump, "fdiv ") == 1 &&
		count_dump_occurrences(dump, "fneg ") == 1,
		"float arithmetic, compound assignment and increments should use scalar float instructions:\n%s", dump);
	assert(count_dump_occurrences(dump, "fcmp_oeq ") == 1 && count_dump_occurrences(dump, "fcmp_une ") == 1 &&
		count_dump_occurrences(dump, "fcmp_olt ") == 1 && count_dump_occurrences(dump, "fcmp_ole ") == 1 &&
		count_dump_occurrences(dump, "fcmp_ogt ") == 1 && count_dump_occurrences(dump, "fcmp_oge ") == 1,
		"all float comparisons should select their ordered/unordered scalar compare tags:\n%s", dump);
	alloc::free(&f.ta, dump.ptr);
	graph.free();
	f.free();
}

fn void gen_ir_scales_pointer_increments_by_element_size() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.target = target::parse_triple("x86_64-linux-gnu", target::host()!!)!!;
	type_store::QualType pointer_type = f.comp.type_store.put(type_store::type_pointer(type_store::LONG));
	NodeIndex p = f.scalar_local(pointer_type, 3);
	NodeIndex p_lvalue = f.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
		.decl_ref = { .name_tok = 3, .qt = pointer_type, .decl = p } });
	NodeIndex[5] statements;
	uint statement_count = 0;
	statements[statement_count++] = p;
	tree::NodeKind[4] increment_kinds = { tree::NodeKind.PRE_INC_EXPR, tree::NodeKind.PRE_DEC_EXPR,
		tree::NodeKind.POST_INC_EXPR, tree::NodeKind.POST_DEC_EXPR };
	foreach (kind : increment_kinds)
	{
		statements[statement_count++] = f.tree.add_node({ .kind = kind,
			.unary = { .qt = pointer_type, .operand = p_lvalue } });
	}
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, type_store::VOID);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	ir::Decl* decl = &graph.decls[0];
	uint scaled_updates = 0;
	uint negated_steps = 0;
	uint pointer_subs = 0;
	foreach (inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.NEGATE) negated_steps++;
		if (inst.tag == ir::InstTag.SUB && inst.ty == value_interner::REF_PTR) pointer_subs++;
		if (inst.tag != ir::InstTag.ADD || inst.ty != value_interner::REF_PTR) continue;
		ir::Inst offset = decl.instructions[(usz)inst.data.bin.rhs];
		if (offset.tag == ir::InstTag.MUL &&
			f.constant_is(decl.instructions, offset.data.bin.rhs, 8, value_interner::REF_I64)) scaled_updates++;
	}
	assert(scaled_updates == 4, "pointer ++/-- should step by sizeof(long), got %d scaled updates", scaled_updates);
	assert(negated_steps == 2 && pointer_subs == 0, "pointer -- should add a negated scaled step");
	graph.free();
	f.free();
}

fn void gen_ir_lowers_scalar_float_conversions_and_truthiness() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.target = target::parse_triple("x86_64-linux-gnu", target::host()!!)!!;
	NodeIndex x = f.scalar_local(type_store::DOUBLE, 3);
	NodeIndex y = f.scalar_local(type_store::FLOAT, 4);
	NodeIndex x_value = f.local_ref_value(x, type_store::DOUBLE, 3);
	NodeIndex y_value = f.local_ref_value(y, type_store::FLOAT, 4);
	NodeIndex bool_to_float = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.BOOL_TO_FLOAT, .operand = f.typed_int_literal(1, type_store::BOOL),
			.qt = type_store::FLOAT } });
	NodeIndex signed_to_float = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.INT_TO_FLOAT, .operand = f.int_literal(-7), .qt = type_store::DOUBLE } });
	NodeIndex unsigned_to_float = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.INT_TO_FLOAT, .operand = f.typed_int_literal(7, type_store::UINT),
			.qt = type_store::DOUBLE } });
	NodeIndex float_to_signed = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.FLOAT_TO_INT, .operand = x_value, .qt = type_store::INT } });
	NodeIndex float_to_unsigned = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.FLOAT_TO_INT, .operand = x_value, .qt = type_store::UINT } });
	NodeIndex float_narrow = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.FLOAT_CAST, .operand = x_value, .qt = type_store::FLOAT } });
	NodeIndex float_widen = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.FLOAT_CAST, .operand = y_value, .qt = type_store::DOUBLE } });
	NodeIndex float_to_bool = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.FLOAT_TO_BOOL, .operand = x_value, .qt = type_store::BOOL } });
	NodeIndex float_to_bool_via_float_to_int = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.FLOAT_TO_INT, .operand = x_value, .qt = type_store::BOOL } });
	NodeIndex logical_not = f.tree.add_node({ .kind = tree::NodeKind.BOOL_NOT_EXPR,
		.unary = { .qt = type_store::INT, .operand = x_value } });
	NodeIndex null_stmt = f.tree.add_node({ .kind = tree::NodeKind.NULL_STMT });
	NodeIndex if_stmt = f.tree.add_node({ .kind = tree::NodeKind.IF_STMT,
		.if_stmt = { .init = type_store::NODE_NULL, .cond = x_value, .then_body = null_stmt,
			.else_body = type_store::NODE_NULL } });
	NodeIndex[13] statements = { x, y, bool_to_float, signed_to_float, unsigned_to_float,
		float_to_signed, float_to_unsigned, float_narrow, float_widen, float_to_bool,
		float_to_bool_via_float_to_int, logical_not, if_stmt };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, type_store::VOID);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	String dump = dump_to_string(&graph, &f.ta);
	assert(count_dump_occurrences(dump, "uitofp ") == 1 && count_dump_occurrences(dump, "sitofp ") == 2 &&
		count_dump_occurrences(dump, "fptosi ") == 1 && count_dump_occurrences(dump, "fptoui ") == 1 &&
		count_dump_occurrences(dump, "fptrunc ") == 1 && count_dump_occurrences(dump, "fpext ") == 1,
		"scalar float casts should choose signedness and width-specific conversion instructions:\n%s", dump);
	assert(count_dump_occurrences(dump, "fcmp_une ") == 3 && count_dump_occurrences(dump, "fcmp_oeq ") == 1,
		"float truthiness should be unordered-not-equal-zero, while logical not uses ordered-equal-zero:\n%s", dump);
	alloc::free(&f.ta, dump.ptr);
	graph.free();
	f.free();
}

fn void gen_ir_rejects_unimplemented_lvalue_nodes() @test
{
	// A `static` compound literal lowers to an internal global
	// (file_scope_compound_literal_address.c); thread_local ones do not yet.
	tree::NodeKind[3] kinds = { tree::NodeKind.MEMBER_ACCESS_EXPR, tree::NodeKind.MEMBER_ACCESS_PTR_EXPR,
		tree::NodeKind.COMPOUND_LITERAL_EXPR };
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
				.compound_literal = { .qt = type_store::INT, .thread_local = true,
					.storage_class = tree::CompoundLiteralStorageClass.AUTO, .initializer = initializer } });
		}
		NodeIndex rhs = f.int_literal(1);
		NodeIndex assignment = f.tree.add_node({ .kind = tree::NodeKind.ASSIGN_EXPR,
			.binary = { .qt = type_store::INT, .lhs = lvalue, .rhs = rhs } });
		String expected = i < 2
			? string::tformat("TODO CodeGen.genLval %s\n", kind.name)
			: "TODO CodeGen.compound_literal_expr thread_local\n";
		f.expect_expression_fatal(assignment, expected);
		f.free();
	}
}

<* Braced aggregate initializer nodes for a scalar destination are not lowered
   (`int x = {}` / DEFAULT_INIT_EXPR is: it stores zero). *>
fn void gen_ir_rejects_unimplemented_initializer_nodes() @test
{
	tree::NodeKind[4] kinds = { tree::NodeKind.ARRAY_INIT_EXPR, tree::NodeKind.STRUCT_INIT_EXPR,
		tree::NodeKind.UNION_INIT_EXPR, tree::NodeKind.ARRAY_FILLER_EXPR };
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
			default: unreachable();
		}
		f.expect_local_initializer_fatal(initializer, type_store::INT,
			string::tformat("TODO CodeGen.genInitializer %s\n", kind.name));
		f.free();
	}
}

<* Run gen_ir over a function whose body declares a local `variable_type x = initializer;`. *>
fn String CodeGenFixture.local_initializer_ir(&self, NodeIndex initializer, type_store::QualType variable_type,
	type_store::NodeOptIndex preceding_local = type_store::NODE_NULL)
{
	NodeIndex variable = self.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 0, .qt = variable_type, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = initializer.pack(), .definition = type_store::NODE_NULL } });
	NodeIndex[2] statements;
	usz statement_count = 0;
	if (!preceding_local.is_null()) statements[statement_count++] = preceding_local.unwrap();
	statements[statement_count++] = variable;
	NodeIndex body = self.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[0..statement_count - 1] } });
	self.function(body);
	ir::Ir graph = codegen::gen_ir(&self.tree, &self.pp)!!;
	defer graph.free();
	return dump_to_string(&graph, tmem);
}

fn void string_array_local_initializer_zero_fills_and_copies() @test
{
	CodeGenFixture f;
	f.init();
	NodeIndex initializer = f.tree.add_node({ .kind = tree::NodeKind.STRING_LITERAL_EXPR,
		.char_literal = { .qt = type_store::CHAR } });
	f.tree.set_value(initializer, value::intern(&f.comp, { .tag = BYTES, .bytes = "abc" }));
	type_store::QualType array_type = f.comp.type_store.put(
		type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 4));
	String ir_text = f.local_initializer_ir(initializer, array_type);
	assert(ir_text.contains("memcpy"), "string-initialized char array should copy with memcpy:\n%s", ir_text);
	assert(ir_text.contains("store"), "string-initialized char array should be zero-filled first:\n%s", ir_text);
	f.free();
}

fn void record_local_initializer_from_variable_copies_inline() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.target = target::parse_triple("x86_64-linux-gnu", target::host()!!)!!;
	type_store::QualType record_type = f.long_record_type(2);
	NodeIndex source = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 3, .qt = record_type, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex initializer = f.local_ref_value(source, record_type, 3);
	String ir_text = f.local_initializer_ir(initializer, record_type, (type_store::NodeOptIndex)source);
	assert(ir_text.contains("alloc size 16"), "both record locals should allocate 16 bytes:\n%s", ir_text);
	assert(ir_text.contains("load ptr_ty") && ir_text.contains("store ptr_ty"),
		"a 16-byte record copy should use inline loads and stores:\n%s", ir_text);
	assert(!ir_text.contains("memcpy"), "a 16-byte record copy should not call memcpy:\n%s", ir_text);
	assert(!ir_text.contains("load { i64, i64 }"), "record copies must not load RECORD_TY values:\n%s", ir_text);
	f.free();
}

fn void large_record_local_initializer_uses_memcpy() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.target = target::parse_triple("x86_64-linux-gnu", target::host()!!)!!;
	type_store::QualType record_type = f.long_record_type(9);
	NodeIndex source = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 3, .qt = record_type, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex initializer = f.local_ref_value(source, record_type, 3);
	String ir_text = f.local_initializer_ir(initializer, record_type, (type_store::NodeOptIndex)source);
	assert(ir_text.contains("alloc size 72"), "a nine-field record local should allocate 72 bytes:\n%s", ir_text);
	assert(ir_text.contains("call ptr_ty @memcpy"), "a record copy larger than 64 bytes should call memcpy:\n%s", ir_text);
	f.free();
}

fn void gen_ir_lowers_12_byte_record_parameter_into_two_i64_args() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.target = target::parse_triple("x86_64-linux-gnu", target::host()!!)!!;
	type_store::RecordField[3] fields = {
		type_store::record_field(f.comp.intern_string("a"), type_store::INT),
		type_store::record_field(f.comp.intern_string("b"), type_store::INT),
		type_store::record_field(f.comp.intern_string("c"), type_store::INT),
	};
	for (uint i = 0; i < fields.len; i++) fields[i].layout = { .offset_bits = (ulong)i * 32, .size_bits = 32 };
	type_store::RecordLayout layout = { .size_bits = 96, .field_alignment_bits = 32,
		.pointer_alignment_bits = 32, .required_alignment_bits = 8 };
	type_store::QualType record_type = f.comp.type_store.put(type_store::type_record(
		f.comp.intern_string("TwelveBytes"), fields[..], layout));
	type_store::FuncParam[1] params = { type_store::func_param(record_type, f.comp.intern_string("value")) };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT, .compound_stmt = { .body = {} } });
	f.function_with_params(body, type_store::VOID, params[..]);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	assert(graph.decls.len() == 1);
	ir::Decl* decl = &graph.decls[0];
	uint arg_count = 0;
	foreach (inst : decl.instructions)
	{
		if (inst.tag != ir::InstTag.ARG) continue;
		assert(inst.ty == value_interner::REF_I64, "each eightbyte of a 12-byte INTEGER-class parameter should be i64");
		assert(inst.data.arg.location_kind == ir::ArgLocationKind.GP_REGISTER,
			"the two-word record should use the first two GP argument registers");
		assert(inst.data.arg.stack_size == 0);
		arg_count++;
	}
	assert(arg_count == 2, "a 12-byte record parameter should lower to two i64 ARG instructions");
	graph.free();
	f.free();
}

fn void gen_ir_lowers_16_byte_record_call_and_return_as_pairs() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.target = target::parse_triple("x86_64-linux-gnu", target::host()!!)!!;
	type_store::QualType record_type = f.long_record_type(2);
	type_store::FuncParam[1] callee_params = {
		type_store::func_param(type_store::INT, f.comp.intern_string("seed")),
	};
	type_store::QualType callee_type = f.comp.type_store.put(
		type_store::type_func(record_type, type_store::FuncKind.NORMAL, callee_params[..]));
	NodeIndex callee_decl = f.tree.add_node({ .kind = tree::NodeKind.FUNCTION,
		.function = { .name_tok = 1, .qt = callee_type, .body = type_store::NODE_NULL,
			.definition = type_store::NODE_NULL } });
	NodeIndex callee_ref = f.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
		.decl_ref = { .name_tok = 1, .qt = callee_type, .decl = callee_decl } });
	type_store::QualType callee_pointer = f.comp.type_store.put(type_store::type_pointer(callee_type));
	NodeIndex callee = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.FUNCTION_TO_POINTER, .operand = callee_ref,
			.qt = callee_pointer, .implicit = true } });
	NodeIndex argument = f.int_literal(7);
	NodeIndex[1] arguments = { argument };
	NodeIndex call = f.tree.add_node({ .kind = tree::NodeKind.CALL_EXPR,
		.call = { .qt = record_type, .callee = callee, .args = arguments[..] } });
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = record_type, .operand = tree::ReturnOperandKind.EXPR, .expr = call } });
	NodeIndex[1] statements = { ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, record_type);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	assert(graph.decls.len() == 1);
	ir::Decl* decl = &graph.decls[0];
	ir::Ref call_ref = ir::NONE;
	ir::Ref call_hi_ref = ir::NONE;
	ir::Ref return_pair_ref = ir::NONE;
	foreach (i, ref : decl.body)
	{
		ir::Inst inst = decl.instructions[(usz)ref];
		if (inst.tag == ir::InstTag.CALL) call_ref = ref;
		if (inst.tag == ir::InstTag.CALL_HI)
		{
			call_hi_ref = ref;
			assert(i > 0 && decl.body[i - 1] == inst.data.ref,
				"CALL_HI must immediately follow the CALL whose high result it reads");
			assert(inst.ty == value_interner::REF_I64);
		}
		if (inst.tag == ir::InstTag.RET_PAIR) return_pair_ref = ref;
	}
	assert(call_ref != ir::NONE && call_hi_ref != ir::NONE && return_pair_ref != ir::NONE,
		"a 16-byte record call returned by its caller should use CALL/CALL_HI and RET_PAIR");
	assert(decl.instructions[(usz)call_ref].ty == value_interner::REF_I64,
		"the low word of an INTEGER-class 16-byte return should be i64");
	assert(decl.instructions[(usz)return_pair_ref].data.bin.lhs != ir::NONE &&
		decl.instructions[(usz)return_pair_ref].data.bin.rhs != ir::NONE,
		"RET_PAIR should carry both return words");
	assert(decl.instructions[(usz)decl.instructions[(usz)return_pair_ref].data.bin.lhs].ty == value_interner::REF_I64 &&
		decl.instructions[(usz)decl.instructions[(usz)return_pair_ref].data.bin.rhs].ty == value_interner::REF_I64,
		"both RET_PAIR values should be i64");
	graph.free();
	f.free();
}

fn void gen_ir_returns_sret_pointer_for_memory_class_record() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.target = target::parse_triple("x86_64-linux-gnu", target::host()!!)!!;
	type_store::QualType record_type = f.long_record_type(9);
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT, .compound_stmt = { .body = {} } });
	f.function_with_return_type(body, record_type);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	ir::Decl* decl = &graph.decls[0];
	ir::Ref sret_arg = ir::NONE;
	ir::Ref return_ref = ir::NONE;
	foreach (ref : decl.body)
	{
		ir::Inst inst = decl.instructions[(usz)ref];
		if (inst.tag == ir::InstTag.ARG)
		{
			assert(inst.ty == value_interner::REF_PTR);
			assert(inst.data.arg.location_kind == ir::ArgLocationKind.GP_REGISTER);
			assert(inst.data.arg.location == 0);
			sret_arg = ref;
		}
		if (inst.tag == ir::InstTag.RET) return_ref = inst.data.ref;
	}
	assert(sret_arg != ir::NONE, "a MEMORY-class return should receive the hidden sret pointer in RDI");
	assert(return_ref == sret_arg, "a MEMORY-class return should return its sret pointer in RAX");
	graph.free();
	f.free();
}

fn void classify_record_puts_double_field_in_sse_class() @test
{
	CodeGenFixture f;
	f.init();
	type_store::RecordField[1] fields = {
		type_store::record_field(f.comp.intern_string("value"), type_store::DOUBLE),
	};
	fields[0].layout = { .offset_bits = 0, .size_bits = 64 };
	type_store::RecordLayout layout = { .size_bits = 64, .field_alignment_bits = 64,
		.pointer_alignment_bits = 64, .required_alignment_bits = 8 };
	type_store::QualType record_type = f.comp.type_store.put(type_store::type_record(
		f.comp.intern_string("FloatingRecord"), fields[..], layout));
	codegen::CodeGen generator = { .comp = &f.comp };
	codegen::AggClassResult class = generator.classify_record(record_type)!!;
	assert(class.kind == codegen::AggClass.REGISTER, "a lone double field is passed in a register");
	assert(class.eightbyte_count == 1);
	assert(class.words[0] == codegen::WordClass.SSE, "a double-only eightbyte is SSE class");
	assert(f.diagnostics.messages.len() == 0);
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

fn void gen_ir_lowers_va_start_and_end_aliases() @test
{
	CodeGenFixture f;
	f.init();
	type_store::QualType va_list_type = f.va_list_pointer_type();
	f.comp.type_store.va_list = va_list_type;
	f.comp.builtins.get_or_create(&f.comp, "va_start")!!;
	f.comp.builtins.get_or_create(&f.comp, "va_end")!!;
	NodeIndex va_list = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 3, .qt = va_list_type, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex named_arg = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 0, .qt = type_store::INT, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex va_list_value = f.local_ref_value(va_list, va_list_type, 3);
	NodeIndex named_arg_value = f.local_ref_value(named_arg, type_store::INT, 0);
	NodeIndex[2] start_args = { va_list_value, named_arg_value };
	NodeIndex start = f.tree.add_node({ .kind = tree::NodeKind.BUILTIN_CALL_EXPR,
		.builtin_call = { .builtin_tok = 8, .qt = type_store::VOID, .args = start_args[..] } });
	NodeIndex[2] end_args = { va_list_value, named_arg_value };
	NodeIndex end = f.tree.add_node({ .kind = tree::NodeKind.BUILTIN_CALL_EXPR,
		.builtin_call = { .builtin_tok = 9, .qt = type_store::VOID, .args = end_args[..] } });
	NodeIndex[4] statements = { va_list, named_arg, start, end };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, type_store::VOID);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	ir::Decl* decl = &graph.decls[0];
	bool saw_va_start = false;
	bool saw_call = false;
	uint pointer_loads = 0;
	uint integer_loads = 0;
	ir::Ref va_storage = ir::NONE;
	ir::Ref named_arg_storage = ir::NONE;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.ALLOC)
		{
			if (va_storage == ir::NONE)
			{
				va_storage = (ir::Ref)i;
			}
			else
			{
				named_arg_storage = (ir::Ref)i;
			}
		}
		if (inst.tag == ir::InstTag.VA_START)
		{
			saw_va_start = true;
			assert(decl.instructions[(usz)inst.data.ref].tag == ir::InstTag.LOAD &&
				decl.instructions[(usz)inst.data.ref].data.ref == va_storage,
				"va_start should receive gen_expr's loaded va_list pointer");
		}
		if (inst.tag == ir::InstTag.CALL) saw_call = true;
		if (inst.tag == ir::InstTag.LOAD && inst.ty == value_interner::REF_PTR) pointer_loads++;
		if (inst.tag == ir::InstTag.LOAD && inst.ty == value_interner::REF_I32 &&
			inst.data.ref == named_arg_storage) integer_loads++;
	}
	assert(saw_va_start, "va_start alias should lower to the VA_START IR instruction");
	assert(!saw_call, "va_start and va_end aliases should not be forwarded as library calls");
	assert(pointer_loads == 2, "va_start and va_end should each evaluate only their va_list argument");
	assert(integer_loads == 0, "va_start must not evaluate its second argument");
	graph.free();
	f.free();
}

fn void gen_ir_lowers_va_copy_alias() @test
{
	CodeGenFixture f;
	f.init();
	type_store::QualType va_list_type = f.va_list_pointer_type();
	f.comp.type_store.va_list = va_list_type;
	f.comp.builtins.get_or_create(&f.comp, "va_copy")!!;
	NodeIndex destination = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 2, .qt = va_list_type, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex source = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 3, .qt = va_list_type, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex[2] copy_args = {
		f.local_ref_value(destination, va_list_type, 2), f.local_ref_value(source, va_list_type, 3),
	};
	NodeIndex copy = f.tree.add_node({ .kind = tree::NodeKind.BUILTIN_CALL_EXPR,
		.builtin_call = { .builtin_tok = 10, .qt = type_store::VOID, .args = copy_args[..] } });
	NodeIndex[3] statements = { destination, source, copy };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, type_store::VOID);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	ir::Decl* decl = &graph.decls[0];
	ir::Ref destination_storage = ir::NONE;
	ir::Ref source_storage = ir::NONE;
	ir::Ref destination_base = ir::NONE;
	ir::Ref source_base = ir::NONE;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.ALLOC)
		{
			if (destination_storage == ir::NONE)
			{
				destination_storage = (ir::Ref)i;
			}
			else
			{
				source_storage = (ir::Ref)i;
			}
		}
		if (inst.tag == ir::InstTag.LOAD && inst.ty == value_interner::REF_PTR)
		{
			if (inst.data.ref == destination_storage) destination_base = (ir::Ref)i;
			if (inst.data.ref == source_storage) source_base = (ir::Ref)i;
		}
	}
	assert(destination_base != ir::NONE && source_base != ir::NONE, "va_copy should evaluate both va_list pointers");
	uint i64_loads = 0;
	uint stores = 0;
	uint[3] load_offsets = {};
	uint[3] store_offsets = {};
	ulong[3] offsets = { 0, 8, 16 };
	foreach (inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.CALL) assert(false, "va_copy must not call memcpy or a library function");
		if (inst.tag == ir::InstTag.LOAD && inst.ty == value_interner::REF_I64)
		{
			i64_loads++;
			foreach (i, offset : offsets)
			{
				if (f.ir_ptr_ref_is_at(decl.instructions, inst.data.ref, source_base, offset)) load_offsets[i]++;
			}
		}
		if (inst.tag == ir::InstTag.STORE)
		{
			stores++;
			foreach (i, offset : offsets)
			{
				if (f.ir_ptr_ref_is_at(decl.instructions, inst.data.bin.lhs, destination_base, offset)) store_offsets[i]++;
			}
		}
	}
	assert(i64_loads == 3 && stores == 3, "va_copy should copy exactly three i64 fields");
	foreach (i, offset : offsets) assert(load_offsets[i] == 1 && store_offsets[i] == 1,
		"va_copy should load and store its i64 field at offset %d", offset);
	graph.free();
	f.free();
}

fn void gen_ir_lowers_integer_and_pointer_va_arg() @test
{
	CodeGenFixture f;
	f.init();
	type_store::QualType va_list_type = f.va_list_pointer_type();
	f.comp.type_store.va_list = va_list_type;
	f.comp.builtins.get_or_create(&f.comp, "__builtin_va_arg")!!;
	type_store::QualType pointer_type = f.comp.type_store.put(type_store::type_pointer(type_store::CHAR));
	NodeIndex va_list = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 3, .qt = va_list_type, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex[1] arg = { f.local_ref_value(va_list, va_list_type, 3) };
	NodeIndex int_value = f.tree.add_node({ .kind = tree::NodeKind.BUILTIN_CALL_EXPR,
		.builtin_call = { .builtin_tok = 7, .qt = type_store::INT, .args = arg[..] } });
	NodeIndex pointer_value = f.tree.add_node({ .kind = tree::NodeKind.BUILTIN_CALL_EXPR,
		.builtin_call = { .builtin_tok = 7, .qt = pointer_type, .args = arg[..] } });
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = pointer_type, .operand = tree::ReturnOperandKind.EXPR, .expr = pointer_value } });
	NodeIndex[3] statements = { va_list, int_value, ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, pointer_type);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	ir::Decl* decl = &graph.decls[0];
	ir::Ref list_storage = ir::NONE;
	ir::Ref[2] list_values = { ir::NONE, ir::NONE };
	uint list_value_count = 0;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.ALLOC && list_storage == ir::NONE) list_storage = (ir::Ref)i;
		if (inst.tag == ir::InstTag.LOAD && inst.ty == value_interner::REF_PTR && inst.data.ref == list_storage)
		{
			list_values[list_value_count++] = (ir::Ref)i;
		}
	}
	assert(list_value_count == 2, "each va_arg should evaluate its va_list pointer");
	uint branches = 0;
	uint comparisons = 0;
	uint gp_offset_loads = 0;
	uint overflow_pointer_loads = 0;
	uint register_save_area_loads = 0;
	uint gp_offset_stores = 0;
	uint overflow_pointer_stores = 0;
	uint integer_results = 0;
	uint pointer_results = 0;
	uint phis = 0;
	foreach (inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.BRANCH) branches++;
		if (inst.tag == ir::InstTag.CMP_ULT)
		{
			comparisons++;
			assert(f.constant_is(decl.instructions, inst.data.bin.rhs, 48, value_interner::REF_I32),
				"va_arg should compare gp_offset against 48");
		}
		if (inst.tag == ir::InstTag.PHI)
		{
			phis++;
			assert(inst.ty == value_interner::REF_PTR && inst.data.phi.len == 2,
				"va_arg should join register and overflow addresses with a pointer phi");
		}
		if (inst.tag == ir::InstTag.LOAD && inst.ty == value_interner::REF_I32)
		{
			foreach (list_value : list_values)
			{
				if (inst.data.ref == list_value) gp_offset_loads++;
			}
			if (decl.instructions[(usz)inst.data.ref].tag == ir::InstTag.PHI) integer_results++;
		}
		if (inst.tag == ir::InstTag.LOAD && inst.ty == value_interner::REF_PTR)
		{
			foreach (list_value : list_values)
			{
				if (f.ir_ptr_ref_is_at(decl.instructions, inst.data.ref, list_value, 8)) overflow_pointer_loads++;
				if (f.ir_ptr_ref_is_at(decl.instructions, inst.data.ref, list_value, 16)) register_save_area_loads++;
			}
			if (decl.instructions[(usz)inst.data.ref].tag == ir::InstTag.PHI) pointer_results++;
		}
		if (inst.tag == ir::InstTag.STORE)
		{
			foreach (list_value : list_values)
			{
				if (f.ir_ptr_ref_is_at(decl.instructions, inst.data.bin.lhs, list_value, 0)) gp_offset_stores++;
				if (f.ir_ptr_ref_is_at(decl.instructions, inst.data.bin.lhs, list_value, 8)) overflow_pointer_stores++;
			}
		}
	}
	assert(branches == 2 && comparisons == 2 && phis == 2,
		"each va_arg should branch on gp_offset and join both paths with a phi");
	assert(gp_offset_loads == 2 && gp_offset_stores == 2, "va_arg should read and advance gp_offset at offset 0");
	assert(overflow_pointer_loads == 2 && overflow_pointer_stores == 2,
		"va_arg should read and advance overflow_arg_area at offset 8");
	assert(register_save_area_loads == 2, "va_arg should load reg_save_area from offset 16");
	assert(integer_results == 1 && pointer_results == 1,
		"va_arg should load integer and pointer results through the joined address");
	graph.free();
	f.free();
}

fn void gen_ir_passes_f80_call_arguments_in_memory_without_using_sse() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.target = target::parse_triple("x86_64-linux-gnu", target::host()!!)!!;
	type_store::FuncParam[2] params = {
		type_store::func_param(type_store::LONG_DOUBLE, f.comp.intern_string("wide")),
		type_store::func_param(type_store::DOUBLE, f.comp.intern_string("narrow")),
	};
	type_store::QualType callee_type = f.comp.type_store.put(
		type_store::type_func(type_store::INT, type_store::FuncKind.NORMAL, params[..]));
	NodeIndex callee_decl = f.tree.add_node({ .kind = tree::NodeKind.FUNCTION,
		.function = { .name_tok = 0, .qt = callee_type, .body = type_store::NODE_NULL,
			.definition = type_store::NODE_NULL } });
	NodeIndex callee_ref = f.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
		.decl_ref = { .name_tok = 0, .qt = callee_type, .decl = callee_decl } });
	type_store::QualType callee_pointer = f.comp.type_store.put(type_store::type_pointer(callee_type));
	NodeIndex callee = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.FUNCTION_TO_POINTER, .operand = callee_ref,
			.qt = callee_pointer, .implicit = true } });
	NodeIndex wide = f.tree.add_node({ .kind = tree::NodeKind.FLOAT_LITERAL,
		.literal = { .literal_tok = 0, .qt = type_store::LONG_DOUBLE } });
	f.tree.set_value(wide, value::intern(&f.comp,
		primitive_value::f80_value((primitive_value::F80Bits)((uint128)0x3fff << 64 | 0x8000000000000000))));
	NodeIndex narrow = f.tree.add_node({ .kind = tree::NodeKind.FLOAT_LITERAL,
		.literal = { .literal_tok = 0, .qt = type_store::DOUBLE } });
	f.tree.set_value(narrow, value::intern(&f.comp, primitive_value::f64_value(0x3ff0_0000_0000_0000)));
	NodeIndex[2] arguments = { wide, narrow };
	NodeIndex call = f.tree.add_node({ .kind = tree::NodeKind.CALL_EXPR,
		.call = { .qt = type_store::INT, .callee = callee, .args = arguments[..] } });
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::INT, .operand = tree::ReturnOperandKind.EXPR, .expr = call } });
	NodeIndex[1] statements = { ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, type_store::INT);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	ir::Decl* decl = &graph.decls[0];
	ir::Ref call_ref = ir::NONE;
	foreach (i, inst : decl.instructions) if (inst.tag == ir::InstTag.CALL) call_ref = (ir::Ref)i;
	assert(call_ref != ir::NONE, "the function call should lower to CALL");
	ir::CallData call_data = decl.instructions[(usz)call_ref].data.call;
	assert(call_data.args.len == 2 && call_data.args[0] != ir::NONE && call_data.args[1] != ir::NONE);
	assert(decl.instructions[(usz)call_data.args[0]].ty == value_interner::REF_F80 &&
		decl.instructions[(usz)call_data.args[1]].ty == value_interner::REF_F64,
		"the call should retain its F80 and F64 argument types");
	assert(call_data.stack_only[0] && !call_data.stack_only[1],
		"F80 should use memory while the following F64 remains eligible for an SSE register");
	assert(call_data.memory_copy_bytes[0] == 0,
		"F80's typed memory argument should use the backend's 16-byte F80 stack slot");
	graph.free();
	f.free();
}

fn void gen_ir_loads_va_arg_long_double_from_aligned_overflow_area() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.target = target::parse_triple("x86_64-linux-gnu", target::host()!!)!!;
	type_store::QualType va_list_type = f.va_list_pointer_type();
	f.comp.type_store.va_list = va_list_type;
	f.comp.builtins.get_or_create(&f.comp, "__builtin_va_arg")!!;
	NodeIndex va_list = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 3, .qt = va_list_type, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex[1] arg = { f.local_ref_value(va_list, va_list_type, 3) };
	NodeIndex value = f.tree.add_node({ .kind = tree::NodeKind.BUILTIN_CALL_EXPR,
		.builtin_call = { .builtin_tok = 7, .qt = type_store::LONG_DOUBLE, .args = arg[..] } });
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::LONG_DOUBLE, .operand = tree::ReturnOperandKind.EXPR, .expr = value } });
	NodeIndex[2] statements = { va_list, ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, type_store::LONG_DOUBLE);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	ir::Decl* decl = &graph.decls[0];
	ir::Ref list_storage = ir::NONE;
	ir::Ref list_value = ir::NONE;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.ALLOC && list_storage == ir::NONE) list_storage = (ir::Ref)i;
		if (inst.tag == ir::InstTag.LOAD && inst.ty == value_interner::REF_PTR && inst.data.ref == list_storage)
		{
			list_value = (ir::Ref)i;
		}
	}
	assert(list_storage != ir::NONE && list_value != ir::NONE, "va_arg should load its va_list pointer");
	ir::Ref overflow_field = ir::NONE;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.ADD && f.ir_ptr_ref_is_at(decl.instructions, (ir::Ref)i, list_value, 8))
		{
			overflow_field = (ir::Ref)i;
		}
	}
	assert(overflow_field != ir::NONE, "long double va_arg should access overflow_arg_area at offset 8");
	ir::Ref overflow_address = ir::NONE;
	uint overflow_loads = 0;
	uint overflow_stores = 0;
	uint alignment_adds = 0;
	uint alignment_ands = 0;
	uint f80_loads = 0;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.LOAD && inst.ty == value_interner::REF_PTR && inst.data.ref == overflow_field)
		{
			overflow_address = (ir::Ref)i;
			overflow_loads++;
		}
	}
	assert(overflow_address != ir::NONE && overflow_loads == 1, "overflow_arg_area should be loaded once");
	ir::Ref unaligned_address = ir::NONE;
	ir::Ref aligned_address = ir::NONE;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.ADD && inst.data.bin.lhs == overflow_address &&
			f.constant_is(decl.instructions, inst.data.bin.rhs, 15, value_interner::REF_I64))
		{
			unaligned_address = (ir::Ref)i;
			alignment_adds++;
		}
		if (inst.tag == ir::InstTag.BIT_AND && inst.data.bin.lhs == unaligned_address &&
			f.constant_is(decl.instructions, inst.data.bin.rhs, ~(ulong)15, value_interner::REF_PTR))
		{
			aligned_address = (ir::Ref)i;
			alignment_ands++;
		}
		if (inst.tag == ir::InstTag.LOAD && inst.ty == value_interner::REF_F80 && inst.data.ref == aligned_address)
		{
			f80_loads++;
		}
		if (inst.tag == ir::InstTag.STORE && inst.data.bin.lhs == overflow_field)
		{
			overflow_stores++;
			ir::Ref updated = inst.data.bin.rhs;
			assert((usz)updated < decl.instructions.len && decl.instructions[(usz)updated].tag == ir::InstTag.ADD &&
				decl.instructions[(usz)updated].data.bin.lhs == aligned_address &&
				f.constant_is(decl.instructions, decl.instructions[(usz)updated].data.bin.rhs, 16, value_interner::REF_I64),
				"long double va_arg should advance overflow_arg_area by 16 bytes from the aligned address");
		}
	}
	assert(alignment_adds == 1 && alignment_ands == 1 && aligned_address != ir::NONE,
		"long double va_arg should align overflow_arg_area up to 16 bytes");
	assert(overflow_stores == 1 && f80_loads == 1,
		"long double va_arg should update overflow_arg_area and load its F80 value from the aligned address");
	graph.free();
	f.free();
}

fn void gen_ir_keeps_unsupported_va_arg_result_as_todo() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.type_store.va_list = f.va_list_pointer_type();
	f.comp.builtins.get_or_create(&f.comp, "__builtin_va_arg")!!;
	NodeIndex[1] args = { f.int_literal(0) };
	NodeIndex call = f.tree.add_node({ .kind = tree::NodeKind.BUILTIN_CALL_EXPR,
		.builtin_call = { .builtin_tok = 7, .qt = type_store::FLOAT128, .args = args[..] } });
	f.expect_expression_fatal(call, "TODO CodeGen.genBuiltinCall __builtin_va_arg <type>\n");
	f.free();
}

fn void gen_ir_allows_f16_f80_f128_only_on_x86_64() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.target = target::parse_triple("x86_64-linux-gnu", target::host()!!)!!;
	codegen::CodeGen generator = { .comp = &f.comp };
	// F80 is x87; F16 and F128 lower to libgcc calls (ir_soft_float.c3).
	type_store::QualType[3] widths = { type_store::LONG_DOUBLE, type_store::FLOAT16, type_store::FLOAT128 };
	foreach (qt : widths) generator.ensure_scalar_float_width(qt)!!;
	f.comp.target.cpu.arch = target::Arch.AARCH64;
	foreach (qt : widths)
	{
		fault fatal = @catch(generator.ensure_scalar_float_width(qt));
		assert(fatal == compilation::FATAL_ERROR, "only the x86_64 lowering handles non-f32/f64 floats");
		assert(f.diagnostics.messages[f.diagnostics.messages.len() - 1].text ==
			"TODO lower non-f32/f64 floating point\n");
	}
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

fn void gen_ir_serializes_long_double_initializer_and_padding() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.target = target::parse_triple("x86_64-linux-gnu", target::host()!!)!!;
	NodeIndex initial_value = f.tree.add_node({ .kind = tree::NodeKind.FLOAT_LITERAL,
		.literal = { .literal_tok = 0, .qt = type_store::LONG_DOUBLE } });
	f.tree.set_value(initial_value, value::intern(&f.comp,
		primitive_value::f80_value((primitive_value::F80Bits)((uint128)0x3fff << 64 | 0x8000000000000000))));
	f.add_global(0, type_store::LONG_DOUBLE, tree::VariableStorageClass.STATIC, initial_value.pack());

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	assert(graph.decls.len() == 1);
	ir::Decl* global = &graph.decls[0];
	assert(global.kind == ir::DeclKind.GLOBAL);
	assert(global.global.size == 16 && global.global.bytes.len == 16);
	char[16] expected = { 0, 0, 0, 0, 0, 0, 0, (char)0x80, (char)0xff, 0x3f,
		0, 0, 0, 0, 0, 0 };
	for (usz i = 0; i < expected.len; i++)
	{
		assert(global.global.bytes[i] == expected[i], "long double initializer byte %d: expected %x, got %x",
			i, (uint)(char)expected[i], (uint)(char)global.global.bytes[i]);
	}
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

fn void aggregate_global_initializer_serializes_elements() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.target = target::parse_triple("x86_64-linux-gnu", target::host()!!)!!;
	type_store::QualType array_type = f.comp.type_store.put(
		type_store::type_array(type_store::INT, type_store::ArrayLenKind.FIXED, 3));
	NodeIndex[3] items = { f.int_literal(1), f.int_literal(0), f.int_literal(258) };
	items[1] = f.tree.add_node({ .kind = tree::NodeKind.ARRAY_FILLER_EXPR,
		.array_filler = { .qt = type_store::INT, .count = 1 } });
	NodeIndex initializer = f.tree.add_node({ .kind = tree::NodeKind.ARRAY_INIT_EXPR,
		.container_init = { .container_qt = array_type, .items = items[..] } });
	f.add_global(2, array_type, tree::VariableStorageClass.AUTO, initializer.pack());
	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	bool found = false;
	foreach (&decl : graph.decls)
	{
		if (decl.kind != ir::DeclKind.GLOBAL) continue;
		char[] b = decl.global.bytes;
		assert(b.len == 12, "int[3] global should have 12 bytes, got %d", b.len);
		assert(b[0] == 1 && b[4] == 0 && b[8] == 2 && b[9] == 1, "array_init/filler bytes were not serialized");
		found = true;
	}
	assert(found, "no global emitted");
	graph.free();
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

fn void gen_ir_lowers_signed_bitfield_read_with_sign_extension() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.target = target::parse_triple("x86_64-linux-gnu", target::host()!!)!!;
	type_store::RecordField[2] fields = {
		type_store::record_field(f.comp.intern_string("a"), type_store::INT),
		type_store::record_field(f.comp.intern_string("b"), type_store::INT),
	};
	fields[0].name_tok = (type_store::TokenIndex)1;
	fields[1].name_tok = (type_store::TokenIndex)2;
	fields[0].bit_width = 3;
	fields[1].bit_width = 5;
	type_store::QualType record_type = f.computed_record_type("SignedBits", fields[..]);
	NodeIndex local = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 3, .qt = record_type, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex first_member = f.record_member_lvalue(local, record_type, type_store::INT, 0);
	NodeIndex first_value = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.LVAL_TO_RVAL, .operand = first_member,
			.qt = type_store::INT, .implicit = true } });
	NodeIndex second_member = f.record_member_lvalue(local, record_type, type_store::INT, 1);
	NodeIndex second_value = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.LVAL_TO_RVAL, .operand = second_member,
			.qt = type_store::INT, .implicit = true } });
	NodeIndex sum = f.tree.add_node({ .kind = tree::NodeKind.ADD_EXPR,
		.binary = { .qt = type_store::INT, .lhs = first_value, .op_tok = 0, .rhs = second_value } });
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::INT, .operand = tree::ReturnOperandKind.EXPR, .expr = sum } });
	NodeIndex[2] statements = { local, ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function(body);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	String dump = dump_to_string(&graph, &f.ta);
	assert(count_dump_loads_of_type(dump, "i32 ") == 2 &&
		count_dump_occurrences(dump, "bit_shl") == 2 &&
		count_dump_occurrences(dump, "bit_ashr") == 2,
		"signed bitfield reads at shifts 0 and 3 should load their int storage units, shift left, then arithmetic-shift right:\n%s", dump);
	assert(!dump.contains("bit_and"),
		"signed bitfield reads should not mask before sign extension:\n%s", dump);
	alloc::free(&f.ta, dump.ptr);
	graph.free();
	f.free();
}

fn void gen_ir_lowers_unsigned_bitfield_read_with_mask() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.target = target::parse_triple("x86_64-linux-gnu", target::host()!!)!!;
	type_store::RecordField[2] fields = {
		type_store::record_field(f.comp.intern_string("a"), type_store::UINT),
		type_store::record_field(f.comp.intern_string("b"), type_store::UINT),
	};
	fields[0].name_tok = (type_store::TokenIndex)1;
	fields[1].name_tok = (type_store::TokenIndex)2;
	fields[0].bit_width = 3;
	fields[1].bit_width = 5;
	type_store::QualType record_type = f.computed_record_type("UnsignedBits", fields[..]);
	NodeIndex local = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 3, .qt = record_type, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex member = f.record_member_lvalue(local, record_type, type_store::UINT, 1);
	NodeIndex value = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.LVAL_TO_RVAL, .operand = member,
			.qt = type_store::UINT, .implicit = true } });
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::UINT, .operand = tree::ReturnOperandKind.EXPR, .expr = value } });
	NodeIndex[2] statements = { local, ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function_with_return_type(body, type_store::UINT);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	String dump = dump_to_string(&graph, &f.ta);
	assert(count_dump_loads_of_type(dump, "i32 ") == 1 && dump.contains("bit_lshr") && dump.contains("bit_and"),
		"unsigned bitfield reads should load their int storage unit, shift right logically, and mask:\n%s", dump);
	assert(!dump.contains("bit_ashr"), "unsigned bitfield reads should not use arithmetic shift:\n%s", dump);
	alloc::free(&f.ta, dump.ptr);
	graph.free();
	f.free();
}

fn void gen_ir_lowers_bitfield_store_as_read_modify_write() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.target = target::parse_triple("x86_64-linux-gnu", target::host()!!)!!;
	type_store::RecordField[2] fields = {
		type_store::record_field(f.comp.intern_string("a"), type_store::INT),
		type_store::record_field(f.comp.intern_string("b"), type_store::INT),
	};
	fields[0].name_tok = (type_store::TokenIndex)1;
	fields[1].name_tok = (type_store::TokenIndex)2;
	fields[0].bit_width = 3;
	fields[1].bit_width = 5;
	type_store::QualType record_type = f.computed_record_type("WritableBits", fields[..]);
	NodeIndex local = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 3, .qt = record_type, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex member = f.record_member_lvalue(local, record_type, type_store::INT, 1);
	NodeIndex assignment = f.tree.add_node({ .kind = tree::NodeKind.ASSIGN_EXPR,
		.binary = { .qt = type_store::INT, .lhs = member, .rhs = f.int_literal(11) } });
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::INT, .operand = tree::ReturnOperandKind.EXPR, .expr = assignment } });
	NodeIndex[2] statements = { local, ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function(body);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	ir::Decl* decl = &graph.decls[0];
	String dump = dump_to_string(&graph, &f.ta);
	assert(count_dump_loads_of_type(dump, "i32 ") == 1 && dump.contains("bit_and") && dump.contains("bit_shl") &&
		dump.contains("bit_or") && dump.contains("store"),
		"bitfield assignment should load its int storage unit, clear and replace field bits, then store:\n%s", dump);
	ir::Ref storage = ir::NONE;
	uint loads_from_storage = 0;
	uint stores_to_storage = 0;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.ALLOC && storage == ir::NONE)
		{
			storage = (ir::Ref)i;
		}
		if (inst.tag == ir::InstTag.LOAD && inst.data.ref == storage)
		{
			loads_from_storage++;
		}
		if (inst.tag == ir::InstTag.STORE && inst.data.bin.lhs == storage)
		{
			stores_to_storage++;
		}
	}
	assert(storage != ir::NONE && loads_from_storage == 1 && stores_to_storage == 1,
		"bitfield read-modify-write should use the same storage-unit pointer for its load and store");
	alloc::free(&f.ta, dump.ptr);
	graph.free();
	f.free();
}

fn void gen_ir_lowers_bitfield_compound_assign_single_address() @test
{
	CodeGenFixture f;
	f.init();
	f.comp.target = target::parse_triple("x86_64-linux-gnu", target::host()!!)!!;
	type_store::RecordField[2] fields = {
		type_store::record_field(f.comp.intern_string("prefix"), type_store::INT),
		type_store::record_field(f.comp.intern_string("bits"), type_store::INT),
	};
	fields[1].name_tok = (type_store::TokenIndex)2;
	fields[1].bit_width = 3;
	type_store::QualType record_type = f.computed_record_type("CompoundBits", fields[..]);
	NodeIndex local = f.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = 3, .qt = record_type, .storage_class = tree::VariableStorageClass.AUTO,
			.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
	NodeIndex member = f.record_member_lvalue(local, record_type, type_store::INT, 1);
	NodeIndex dummy = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_ASSIGN_DUMMY_EXPR,
		.unary = { .qt = type_store::INT, .operand = member, .op_tok = 0 } });
	NodeIndex dummy_value = f.tree.add_node({ .kind = tree::NodeKind.CAST,
		.cast = { .kind = tree::CastKind.LVAL_TO_RVAL, .operand = dummy,
			.qt = type_store::INT, .implicit = true } });
	NodeIndex calculation = f.tree.add_node({ .kind = tree::NodeKind.ADD_EXPR,
		.binary = { .qt = type_store::INT, .lhs = dummy_value, .op_tok = 0, .rhs = f.int_literal(1) } });
	NodeIndex assignment = f.tree.add_node({ .kind = tree::NodeKind.ADD_ASSIGN_EXPR,
		.binary = { .qt = type_store::INT, .lhs = member, .rhs = calculation } });
	NodeIndex ret = f.tree.add_node({ .kind = tree::NodeKind.RETURN_STMT,
		.return_stmt = { .return_qt = type_store::INT, .operand = tree::ReturnOperandKind.EXPR, .expr = assignment } });
	NodeIndex[2] statements = { local, ret };
	NodeIndex body = f.tree.add_node({ .kind = tree::NodeKind.COMPOUND_STMT,
		.compound_stmt = { .body = statements[..] } });
	f.function(body);

	ir::Ir graph = codegen::gen_ir(&f.tree, &f.pp)!!;
	ir::Decl* decl = &graph.decls[0];
	String dump = dump_to_string(&graph, &f.ta);
	assert(count_dump_occurrences(dump, "add ptr_ty") == 1 && dump.contains("load") && dump.contains("store"),
		"compound assignment should compute one storage-unit address and load/store through it:\n%s", dump);
	ir::Ref base = ir::NONE;
	ir::Ref unit_ptr = ir::NONE;
	uint loads_from_unit = 0;
	uint stores_to_unit = 0;
	foreach (i, inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.ALLOC && base == ir::NONE)
		{
			base = (ir::Ref)i;
		}
		if (inst.tag == ir::InstTag.ADD && inst.ty == value_interner::REF_PTR &&
			f.ir_ptr_ref_is_at(decl.instructions, (ir::Ref)i, base, 4))
		{
			unit_ptr = (ir::Ref)i;
		}
		if (inst.tag == ir::InstTag.LOAD && unit_ptr != ir::NONE && inst.data.ref == unit_ptr)
		{
			loads_from_unit++;
		}
		if (inst.tag == ir::InstTag.STORE && unit_ptr != ir::NONE && inst.data.bin.lhs == unit_ptr)
		{
			stores_to_unit++;
		}
	}
	assert(base != ir::NONE && unit_ptr != ir::NONE && loads_from_unit >= 1 && stores_to_unit == 1,
		"compound assignment should reuse its byte-offset storage-unit pointer for its reads and store");
	alloc::free(&f.ta, dump.ptr);
	graph.free();
	f.free();
}
