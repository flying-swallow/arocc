// Focused checks for AST-to-assembly data emission. Expected output is
// source-derived from src/backend/assembly_x86_64.c3, not executable Zig
// parity.
module assembly_tests;
import aro::primitive_value;
import aro::backend::assembly, aro::frontend::c::compilation, aro::frontend::c::diagnostics;
import aro::code_gen_options, aro::source, aro::target, aro::frontend::c::tokens, aro::frontend::c::tokenizer, aro::frontend::c::tree, aro::frontend::c::type_store;
import aro::frontend::c::value, aro::value_interner;

const Host HOST = { X86_64, LINUX, GNU };

const String[21] NAMES = {
	"byte_value", "short_value", "int_value", "long_value", "half_value",
	"float_value", "double_value", "extended_value", "quad_value", "local_zero",
	"common_zero", "tls_value", "sectioned_value", "tls_zero", "string_value",
	"complex_value", "pointer_value", "false_value", "true_value",
	"zero_float_value", "one_float_value",
};

struct AssemblyFixture
{
	TrackingAllocator ta;
	Diagnostics diagnostics;
	Compilation comp;
	tokens::TreeToken[21] tokens;
	Tree tree;
}

fn void AssemblyFixture.init(&self)
{
	self.ta.init(mem);
	self.diagnostics.init_list(&self.ta);
	self.comp.init(&self.ta, null, &self.diagnostics);
	self.comp.target = target::parse_triple("x86_64-linux-gnu", HOST)!!;
	type_store::init_named_types(&self.comp);

	DString text;
	text.init(&self.ta);
	sz[21] offsets;
	foreach (i, name : NAMES)
	{
		offsets[i] = text.len();
		text.append_string(name);
		text.append_char(' ');
	}
	Source src = self.comp.add_source_from_buffer("assembly.c", text.str_view())!!;
	for (sz i = 0; i < 21; i++)
	{
		self.tokens[i] = { .id = tokenizer::TokenId.IDENTIFIER,
			.loc = { .id = src.id, .byte_offset = (uint)offsets[i], .line = 1 } };
	}
	text.free();
	self.tree.init(&self.comp, self.tokens[..]);
}

fn void AssemblyFixture.free(&self)
{
	self.tree.free();
	self.comp.free();
	self.diagnostics.free();
	assert(self.ta.allocation_count() == 0, "assembly AST fixture leaked allocations");
	self.ta.free();
}

fn NodeIndex AssemblyFixture.int_literal(&self, tokens::TokenIndex tok, type_store::QualType qt, long n)
{
	NodeIndex node = self.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
		.literal = { .literal_tok = tok, .qt = qt } });
	self.tree.set_value(node, value::int_i64(n, &self.comp));
	return node;
}

fn NodeIndex AssemblyFixture.float_literal(&self, tokens::TokenIndex tok, type_store::QualType qt,
	primitive_value::PrimitiveType tag, uint128 bits)
{
	NodeIndex node = self.tree.add_node({ .kind = tree::NodeKind.FLOAT_LITERAL,
		.literal = { .literal_tok = tok, .qt = qt } });
	self.tree.set_value(node, value::intern(&self.comp,
		primitive_value::float_key(tag, bits)));
	return node;
}

fn NodeIndex AssemblyFixture.string_literal(&self, tokens::TokenIndex tok, type_store::QualType qt,
	char[] bytes)
{
	NodeIndex node = self.tree.add_node({ .kind = tree::NodeKind.STRING_LITERAL_EXPR,
		.char_literal = { .literal_tok = tok, .qt = qt, .kind = tree::CharLiteralKind.ASCII } });
	self.tree.set_value(node, value::intern(&self.comp, { .tag = BYTES, .bytes = bytes }));
	return node;
}

fn void AssemblyFixture.global(&self, tokens::TokenIndex name_tok, type_store::QualType qt)
{
	self.insert_global(name_tok, qt, type_store::NODE_NULL, tree::VariableStorageClass.AUTO, false);
}

fn void AssemblyFixture.global_options(&self, tokens::TokenIndex name_tok, type_store::QualType qt,
	tree::VariableStorageClass storage, bool thread_local)
{
	self.insert_global(name_tok, qt, type_store::NODE_NULL, storage, thread_local);
}

fn void AssemblyFixture.global_value(&self, tokens::TokenIndex name_tok, type_store::QualType qt,
	NodeIndex initializer, tree::VariableStorageClass storage, bool thread_local)
{
	self.insert_global(name_tok, qt, initializer.pack(), storage, thread_local);
}

fn void AssemblyFixture.insert_global(&self, tokens::TokenIndex name_tok, type_store::QualType qt,
	NodeOptIndex init, tree::VariableStorageClass storage, bool thread_local)
{
	NodeIndex node = self.tree.add_node({ .kind = tree::NodeKind.VARIABLE,
		.variable = { .name_tok = name_tok, .qt = qt, .storage_class = storage,
			.thread_local = thread_local, .initializer = init,
			.definition = type_store::NODE_NULL } });
	self.tree.root_decls.push(node);
}

fn void check_output(AssemblyFixture* f, String expected_data)
{
	assembly::Assembly out = assembly::gen_asm(&f.tree)!!;
	test::eq(out.data.str_view(), expected_data);
	test::eq(out.text.str_view(), "  .section  .note.GNU-stack,\"\",@progbits\n");
	out.free();
}

fn void expect_fatal(AssemblyFixture* f, String expected_text)
{
	fault fatal = @catch(assembly::gen_asm(&f.tree));
	assert(fatal == compilation::FATAL_ERROR, "gen_asm should return FATAL_ERROR");
	assert(f.diagnostics.messages.len() == 1, "gen_asm should report exactly one diagnostic");
	test::eq(f.diagnostics.messages[0].kind, diagnostics::MessageKind.ERROR);
	test::eq(f.diagnostics.messages[0].text, expected_text);
}

fn void assembly_serializes_supported_integer_and_float_values() @test
{
	AssemblyFixture f;
	f.init();
	f.global_value(0, type_store::UCHAR, f.int_literal(0, type_store::UCHAR, 255), tree::VariableStorageClass.AUTO, false);
	f.global_value(1, type_store::SHORT, f.int_literal(1, type_store::SHORT, -123), tree::VariableStorageClass.AUTO, false);
	f.global_value(2, type_store::INT, f.int_literal(2, type_store::INT, 305419896), tree::VariableStorageClass.AUTO, false);
	f.global_value(3, type_store::ULONG_LONG, f.int_literal(3, type_store::ULONG_LONG, 123456789), tree::VariableStorageClass.AUTO, false);
	f.global_value(4, type_store::FLOAT16, f.float_literal(4, type_store::FLOAT16, F16, 0x3e00), tree::VariableStorageClass.AUTO, false);
	f.global_value(5, type_store::FLOAT, f.float_literal(5, type_store::FLOAT, F32, 0x3fc00000), tree::VariableStorageClass.AUTO, false);
	f.global_value(6, type_store::DOUBLE, f.float_literal(6, type_store::DOUBLE, F64, 0x3ff8000000000000), tree::VariableStorageClass.AUTO, false);
	f.global_value(7, type_store::LONG_DOUBLE, f.float_literal(7, type_store::LONG_DOUBLE,
		F80, (uint128)0x3fff << 64 | (uint128)0x8000000000000000), tree::VariableStorageClass.AUTO, false);
	f.global_value(8, type_store::FLOAT128, f.float_literal(8, type_store::FLOAT128,
		F128, (uint128)0x3fff000000000000 << 64), tree::VariableStorageClass.AUTO, false);
	check_output(&f,
		"  .globl \"byte_value\"\n  .data\n  .type \"byte_value\", @object\n  .size \"byte_value\", 1\n  .align 1\n\"byte_value\":\n  .byte 255\n"
		"  .globl \"short_value\"\n  .data\n  .type \"short_value\", @object\n  .size \"short_value\", 2\n  .align 2\n\"short_value\":\n  .short -123\n"
		"  .globl \"int_value\"\n  .data\n  .type \"int_value\", @object\n  .size \"int_value\", 4\n  .align 4\n\"int_value\":\n  .long 305419896\n"
		"  .globl \"long_value\"\n  .data\n  .type \"long_value\", @object\n  .size \"long_value\", 8\n  .align 8\n\"long_value\":\n  .quad 123456789\n"
		"  .globl \"half_value\"\n  .data\n  .type \"half_value\", @object\n  .size \"half_value\", 2\n  .align 2\n\"half_value\":\n  .short  0x3e00\n"
		"  .globl \"float_value\"\n  .data\n  .type \"float_value\", @object\n  .size \"float_value\", 4\n  .align 4\n\"float_value\":\n  .long  0x3fc00000\n"
		"  .globl \"double_value\"\n  .data\n  .type \"double_value\", @object\n  .size \"double_value\", 8\n  .align 8\n\"double_value\":\n  .quad  0x3ff8000000000000\n"
		"  .globl \"extended_value\"\n  .data\n  .type \"extended_value\", @object\n  .size \"extended_value\", 16\n  .align 16\n\"extended_value\":\n  .quad  0x8000000000000000\n  .short  0x3fff\n  .zero 6\n"
		"  .globl \"quad_value\"\n  .data\n  .type \"quad_value\", @object\n  .size \"quad_value\", 16\n  .align 16\n\"quad_value\":\n  .quad  0x0\n  .quad  0x3fff000000000000\n");
	f.free();
}

fn void assembly_serializes_canonical_float_zero_and_one() @test
{
	AssemblyFixture f;
	f.init();
	f.global_value(19, type_store::FLOAT, f.int_literal(19, type_store::FLOAT, 0), tree::VariableStorageClass.AUTO, false);
	f.global_value(20, type_store::FLOAT, f.int_literal(20, type_store::FLOAT, 1), tree::VariableStorageClass.AUTO, false);
	check_output(&f,
		"  .globl \"zero_float_value\"\n  .data\n  .type \"zero_float_value\", @object\n  .size \"zero_float_value\", 4\n  .align 4\n\"zero_float_value\":\n  .long  0x0\n"
		"  .globl \"one_float_value\"\n  .data\n  .type \"one_float_value\", @object\n  .size \"one_float_value\", 4\n  .align 4\n\"one_float_value\":\n  .long  0x3f800000\n");
	f.free();
}

fn void assembly_serializes_bool_values_as_assembler_literals() @test
{
	AssemblyFixture f;
	f.init();
	f.global_value(17, type_store::BOOL, f.int_literal(17, type_store::BOOL, 0), tree::VariableStorageClass.AUTO, false);
	f.global_value(18, type_store::BOOL, f.int_literal(18, type_store::BOOL, 1), tree::VariableStorageClass.AUTO, false);
	check_output(&f,
		"  .globl \"false_value\"\n  .data\n  .type \"false_value\", @object\n  .size \"false_value\", 1\n  .align 1\n\"false_value\":\n  .byte false\n"
		"  .globl \"true_value\"\n  .data\n  .type \"true_value\", @object\n  .size \"true_value\", 1\n  .align 1\n\"true_value\":\n  .byte true\n");
	f.free();
}

fn void assembly_emits_storage_classes_tls_sections_and_alignment() @test
{
	{
		AssemblyFixture f;
		f.init();
		f.global(9, type_store::INT);
		f.global_value(11, type_store::INT, f.int_literal(11, type_store::INT, 7), tree::VariableStorageClass.AUTO, true);
		check_output(&f,
		"  .globl \"local_zero\"\n  .bss\n  .align 4\n\"local_zero\":\n  .zero 4\n"
		"  .globl \"tls_value\"\n  .section .tdata,\"awT\",@progbits\n  .type \"tls_value\", @object\n  .size \"tls_value\", 4\n  .align 4\n\"tls_value\":\n  .long 7\n"
		);
		f.free();
	}
	{
		AssemblyFixture f;
		f.init();
		f.comp.code_gen_options.common = true;
		f.global(10, type_store::INT);
		check_output(&f, "  .globl \"common_zero\"\n  .comm \"common_zero\", 4, 4\n");
		f.free();
	}
	{
		AssemblyFixture f;
		f.init();
		f.comp.code_gen_options.data_sections = true;
		f.global_value(12, type_store::INT, f.int_literal(12, type_store::INT, 9), tree::VariableStorageClass.STATIC, false);
		f.global_options(13, type_store::INT, tree::VariableStorageClass.AUTO, true);
		check_output(&f,
			"  .local \"sectioned_value\"\n  .section .data.\"sectioned_value\",\"aw\",@progbits\n  .type \"sectioned_value\", @object\n  .size \"sectioned_value\", 4\n  .align 4\n\"sectioned_value\":\n  .long 9\n"
			"  .globl \"tls_zero\"\n  .section .tbss.\"tls_zero\",\"awT\",@nobits\n  .align 4\n\"tls_zero\":\n  .zero 4\n");
		f.free();
	}
}

fn void assembly_emits_supported_string_array() @test
{
	AssemblyFixture f;
	f.init();
	char[3] bytes = { 'h', 'i', 0 };
	type_store::Type array_type = type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 4);
	type_store::QualType array_qt = f.comp.type_store.put(array_type);
	f.global_value(14, array_qt, f.string_literal(14, array_qt, bytes[..]), tree::VariableStorageClass.AUTO, false);
	check_output(&f,
		"  .globl \"string_value\"\n  .data\n  .type \"string_value\", @object\n  .size \"string_value\", 4\n  .align 1\n\"string_value\":\n  .string \"hi\"\n");
	f.free();
}

fn void assembly_emits_character_array_without_terminator() @test
{
	AssemblyFixture f;
	f.init();
	char[3] bytes = { 'h', 'i', 0 };
	type_store::Type array_type = type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 2);
	type_store::QualType array_qt = f.comp.type_store.put(array_type);
	f.global_value(14, array_qt, f.string_literal(14, array_qt, bytes[..]), tree::VariableStorageClass.AUTO, false);
	check_output(&f,
		"  .globl \"string_value\"\n  .data\n  .type \"string_value\", @object\n  .size \"string_value\", 2\n  .align 1\n\"string_value\":\n  .ascii \"hi\"\n");
	f.free();
}

fn void assembly_applies_array_minimum_alignment() @test
{
	AssemblyFixture f;
	f.init();
	type_store::QualType qt = f.comp.type_store.put(
		type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 16));
	f.global(14, qt);
	check_output(&f,
		"  .globl \"string_value\"\n  .bss\n  .align 16\n\"string_value\":\n  .zero 16\n");
	f.free();
}

fn void assembly_emits_file_directives_when_debug_is_enabled() @test
{
	AssemblyFixture f;
	f.init();
	f.comp.code_gen_options.debug.kind = code_gen_options::DebugKind.DWARF;
	assembly::Assembly out = assembly::gen_asm(&f.tree)!!;
	test::eq(out.data.str_view(), "  .file 1 \"assembly.c\"\n");
	test::eq(out.text.str_view(), "  .section  .note.GNU-stack,\"\",@progbits\n");
	out.free();
	f.free();
}

fn void assembly_rejects_unsupported_initializers_and_values() @test
{
	{
		AssemblyFixture f;
		f.init();
		NodeIndex child = f.int_literal(0, type_store::INT, 1);
		NodeIndex[1] items = { child };
		NodeIndex init = f.tree.add_node({ .kind = tree::NodeKind.ARRAY_INIT_EXPR,
			.container_init = { .l_brace_tok = 0, .container_qt = type_store::INT, .items = items[..] } });
		f.global_value(0, type_store::INT, init, tree::VariableStorageClass.AUTO, false);
		expect_fatal(&f, "TODO: Codegen multiple inits");
		f.free();
	}
	{
		AssemblyFixture f;
		f.init();
		NodeIndex init = f.tree.add_node({ .kind = tree::NodeKind.STRUCT_INIT_EXPR,
			.container_init = { .l_brace_tok = 0, .container_qt = type_store::INT } });
		f.global_value(0, type_store::INT, init, tree::VariableStorageClass.AUTO, false);
		expect_fatal(&f, "TODO: Codegen multiple inits");
		f.free();
	}
	{
		AssemblyFixture f;
		f.init();
		NodeIndex init = f.tree.add_node({ .kind = tree::NodeKind.UNION_INIT_EXPR,
			.container_init = { .l_brace_tok = 0, .container_qt = type_store::INT } });
		f.global_value(0, type_store::INT, init, tree::VariableStorageClass.AUTO, false);
		expect_fatal(&f, "TODO: Codegen multiple inits");
		f.free();
	}
	{
		AssemblyFixture f;
		f.init();
		QualType bitint = f.comp.type_store.put(type_store::type_bit_int(7, SIGNED));
		f.global_value(0, bitint, f.int_literal(0, bitint, 1), tree::VariableStorageClass.AUTO, false);
		expect_fatal(&f, "TODO: Codegen _BitInt values");
		f.free();
	}
	{
		AssemblyFixture f;
		f.init();
		QualType complex = f.comp.type_store.put(type_store::type_complex(type_store::DOUBLE));
		f.global_value(15, complex, f.int_literal(15, complex, 1), tree::VariableStorageClass.AUTO, false);
		expect_fatal(&f, "TODO: Codegen _Complex values");
		f.free();
	}
	{
		AssemblyFixture f;
		f.init();
		QualType pointer = f.comp.type_store.put(type_store::type_pointer(type_store::INT));
		f.global_value(16, pointer, f.int_literal(16, pointer, 1), tree::VariableStorageClass.AUTO, false);
		expect_fatal(&f, "TODO: Codegen pointer");
		f.free();
	}
	{
		AssemblyFixture f;
		f.init();
		QualType function_type = f.comp.type_store.put(
			type_store::type_func(type_store::INT, type_store::FuncKind.NORMAL, {}));
		NodeIndex body = f.int_literal(0, type_store::INT, 0);
		NodeIndex function = f.tree.add_node({ .kind = tree::NodeKind.FUNCTION,
			.function = { .name_tok = 0, .qt = function_type, .body = body.pack(),
				.definition = type_store::NODE_NULL } });
		f.tree.root_decls.push(function);
		expect_fatal(&f, "TODO: Codegen functions");
		f.free();
	}
}

fn void assembly_rejects_unsupported_architecture_dispatch() @test
{
	AssemblyFixture f;
	f.init();
	f.comp.target.cpu.arch = target::Arch.AARCH64;
	fault unsupported = @catch(assembly::gen_asm(&f.tree));
	assert(unsupported == assembly::UNSUPPORTED_ARCHITECTURE,
		"gen_asm should return UNSUPPORTED_ARCHITECTURE for non-x86-64 targets");
	assert(f.diagnostics.messages.len() == 0, "architecture dispatch should not report a diagnostic");
	f.free();
}
