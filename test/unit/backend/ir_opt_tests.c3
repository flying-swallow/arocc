// Source-to-IR optimization harness and structural analysis tests.
module ir_opt_tests;
import std, aro::backend::ir, aro::backend::ir_opt, aro::code_gen_options, aro::frontend::c::codegen, aro::frontend::c::compilation;
import aro::frontend::c::diagnostics, aro::frontend::c::lang_opts, aro::frontend::c::parser, aro::frontend::c::parser_declaration, aro::frontend::c::predefined_macros;
import aro::frontend::c::preprocessor, aro::source, aro::target, aro::frontend::c::tokens, aro::frontend::c::tree, aro::frontend::c::type_store;
import aro::value_interner, aro::primitive_value, std::core::dstring;

const target::Host HOST = { target::Arch.X86_64, target::OsTag.LINUX, target::Abi.GNU };

struct OptFixture
{
	TrackingAllocator ta;
	Diagnostics diagnostics;
	Compilation comp;
	Preprocessor pp;
	Tree tree;
	Ir graph;
	bool has_graph;
}

fn void OptFixture.init(&self)
{
	self.ta.init(mem);
	self.diagnostics.init_list(&self.ta);
	self.comp.init(&self.ta, null, &self.diagnostics);
	self.comp.target = target::parse_triple("x86_64-linux-gnu", HOST)!!;
	self.comp.langopts.set_target_options(&self.comp.target);
	type_store::init_named_types(&self.comp);
	self.pp.init(&self.comp, preprocessor::TESTING)!!;
}

fn void OptFixture.lower(&self, String c_source)
{
	assert(!self.has_graph, "an OptFixture lowers one translation unit");
	Source source = self.comp.add_source_from_buffer("ir-opt.c", c_source)!!;
	Source builtin_macros = predefined_macros::generate_builtin_macros(&self.comp,
		predefined_macros::SystemDefinesMode.NO_SYSTEM_DEFINES)!!;
	self.pp.add_builtin_macros();
	self.pp.preprocess(builtin_macros)!!;
	TokenWithExpansionLocs eof = self.pp.preprocess(source)!!;
	self.pp.add_token(eof)!!;

	parser::Parser p;
	p.init(&self.pp);
	parser_declaration::DeclarationParser handler;
	handler.bind(&p);
	self.tree = p.parse()!!;
	p.free();
	assert(self.diagnostics.errors == 0,
		"C source fixture should parse without errors, found %d", self.diagnostics.errors);
	self.graph = codegen::gen_ir(&self.tree, &self.pp)!!;
	self.has_graph = true;
	assert(self.diagnostics.errors == 0,
		"C source fixture should lower without errors, found %d", self.diagnostics.errors);
}

fn void OptFixture.free(&self)
{
	if (self.has_graph) self.graph.free();
	self.tree.free();
	self.pp.free();
	self.comp.free();
	self.diagnostics.free();
	assert(self.ta.allocation_count() == 0, "source-to-IR fixture leaked allocations");
	self.ta.free();
}

fn String OptFixture.dump(&self)
{
	DString output;
	output.init(&self.ta);
	defer output.free();
	Terminal term = { .writer = &output, .mode = diagnostics::ColorMode.NO_COLOR };
	self.graph.dump(term)!!;
	return output.copy_str(&self.ta);
}

fn void OptFixture.verify_graph(&self)
{
	ir::ErrorList errors;
	errors.init(&self.ta);
	defer errors.free();
	assert(ir_opt::verify(&self.graph, &errors), "IR verifier rejected codegen corpus: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	assert(errors.len() == 0, "valid codegen IR reported verifier errors");
}

fn void OptFixture.expect_pipeline(&self, ir_opt::OptOptions opts, String before, String after)
{
	String before_dump = self.dump();
	test::eq(before_dump, before);
	alloc::free(&self.ta, before_dump.ptr);

	ir::ErrorList errors;
	errors.init(&self.ta);
	fault f = @catch(ir_opt::run(&self.graph, opts, &errors));
	assert(!f, "ir_opt::run failed: %s", errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	assert(errors.len() == 0, "successful pipeline left errors");
	errors.free();

	String after_dump = self.dump();
	test::eq(after_dump, after);
	alloc::free(&self.ta, after_dump.ptr);
}

fn void OptFixture.run_o1(&self)
{
	ir::ErrorList errors;
	errors.init(&self.ta);
	fault f = @catch(ir_opt::run(&self.graph, {
		.level = code_gen_options::OptimizationLevel.O1,
		.whole_program = false,
		.verify = true,
	}, &errors));
	assert(!f, "O1 pipeline failed: %s", errors.len() == 0 ? "no diagnostic message" : errors.message_at(0));
	assert(errors.len() == 0, "successful O1 pipeline left errors");
	errors.free();
}

fn void OptFixture.run_o2(&self)
{
	ir::ErrorList errors;
	errors.init(&self.ta);
	fault f = @catch(ir_opt::run(&self.graph, {
		.level = code_gen_options::OptimizationLevel.O2,
		.whole_program = false,
		.verify = true,
	}, &errors));
	assert(!f, "O2 pipeline failed: %s", errors.len() == 0 ? "no diagnostic message" : errors.message_at(0));
	assert(errors.len() == 0, "successful O2 pipeline left errors");
	errors.free();
}

fn void OptFixture.run_mem2reg(&self)
{
	foreach (&decl : self.graph.decls) ir_opt::mem2reg(&self.graph, decl, &self.ta);
	self.verify_graph();
}

fn bool has_index(ir::Ref[] values, ir::Ref expected)
{
	foreach (value : values) if (value == expected) return true;
	return false;
}

fn bool has_uint_index(uint[] values, uint expected)
{
	foreach (value : values) if (value == expected) return true;
	return false;
}

fn uint block_for_label(ir_opt::Cfg* cfg, Ref label)
{
	foreach (i, block : cfg.blocks) if (block.label == label) return (uint)i;
	unreachable("CFG did not contain a placed label");
}

alias TestOptPass = fn void?(ir::Ir* graph, ir::ErrorList* errors);

fn void OptFixture.expect_single_pass(&self, String pass_name, TestOptPass pass, String before, String after)
{
	String before_dump = self.dump();
	test::eq(before_dump, before);
	alloc::free(&self.ta, before_dump.ptr);

	ir::ErrorList errors;
	errors.init(&self.ta);
	fault f = @catch(pass(&self.graph, &errors));
	assert(!f, "IR pass '%s' failed: %s", pass_name,
		errors.len() == 0 ? "no diagnostic message" : errors.message_at(0));
	assert(errors.len() == 0, "IR pass '%s' left errors", pass_name);
	errors.free();

	String after_dump = self.dump();
	test::eq(after_dump, after);
	alloc::free(&self.ta, after_dump.ptr);
}

fn void harness_lowers_c_source_to_expected_dump() @test
{
	OptFixture f;
	f.init();
	f.lower("int f(int a) { int b = a + 1; return b; }");
	String actual = f.dump();
	test::eq(actual,
		"i32 @f(i32 %0) {\n"
		"entry.0:\n"
		"    ptr_ty %1 = alloc size 4 align 4\n"
		"    ptr_ty %2 = alloc size 4 align 4\n"
		"    store ptr_ty %1, i32 %0\n"
		"    i32 %3 = load ptr_ty %1\n"
		"    i32 %4 = add i32 %3, i32 1\n"
		"    store ptr_ty %2, i32 %4\n"
		"    i32 %5 = load ptr_ty %2\n"
		"    ret i32 %5\n"
		"}\n\n");
	alloc::free(&f.ta, actual.ptr);
	f.free();
}

fn void run_at_o0_without_passes_is_identity_and_o1_promotes_locals() @test
{
	String source = "int f(int a) { int b = a + 1; return b; }";
	String unoptimized =
		"i32 @f(i32 %0) {\n"
		"entry.0:\n"
		"    ptr_ty %1 = alloc size 4 align 4\n"
		"    ptr_ty %2 = alloc size 4 align 4\n"
		"    store ptr_ty %1, i32 %0\n"
		"    i32 %3 = load ptr_ty %1\n"
		"    i32 %4 = add i32 %3, i32 1\n"
		"    store ptr_ty %2, i32 %4\n"
		"    i32 %5 = load ptr_ty %2\n"
		"    ret i32 %5\n"
		"}\n\n";
	String optimized =
		"i32 @f(i32 %0) {\n"
		"entry.0:\n"
		"    i32 %1 = add i32 %0, i32 1\n"
		"    ret i32 %1\n"
		"}\n\n";
	OptFixture f;
	f.init();
	f.lower(source);
	f.expect_pipeline({ .level = code_gen_options::OptimizationLevel.O0, .verify = true }, unoptimized, unoptimized);
	f.expect_pipeline({ .level = code_gen_options::OptimizationLevel.O1, .verify = true }, unoptimized, optimized);
	f.free();
}

fn void dead_function_elimination_removes_unreferenced_internal_only_per_tu() @test
{
	String before =
		"internal i32 @unused() {\n"
		"entry.0:\n"
		"    ret i32 1\n"
		"}\n\n"
		"i32 @visible() {\n"
		"entry.0:\n"
		"    ret i32 2\n"
		"}\n\n"
		"i32 @also_visible() {\n"
		"entry.0:\n"
		"    ret i32 3\n"
		"}\n\n";
	String after =
		"i32 @visible() {\n"
		"entry.0:\n"
		"    ret i32 2\n"
		"}\n\n"
		"i32 @also_visible() {\n"
		"entry.0:\n"
		"    ret i32 3\n"
		"}\n\n";
	OptFixture f;
	f.init();
	f.lower(
		"static int unused(void) { return 1; }\n"
		"int visible(void) { return 2; }\n"
		"int also_visible(void) { return 3; }\n");
	f.expect_pipeline(
		{ .level = code_gen_options::OptimizationLevel.O1, .whole_program = false, .verify = true },
		before, after);
	f.free();
}

fn void dead_function_elimination_removes_transitive_internal_chain() @test
{
	String before =
		"internal i32 @dead_child() {\n"
		"entry.0:\n"
		"    ret i32 1\n"
		"}\n\n"
		"internal i32 @dead_parent() {\n"
		"entry.0:\n"
		"    i32 %0 = call ptr_ty @dead_child()\n"
		"    ret i32 %0\n"
		"}\n\n"
		"i32 @keep() {\n"
		"entry.0:\n"
		"    ret i32 2\n"
		"}\n\n";
	String after =
		"i32 @keep() {\n"
		"entry.0:\n"
		"    ret i32 2\n"
		"}\n\n";
	OptFixture f;
	f.init();
	f.lower(
		"static int dead_child(void) { return 1; }\n"
		"static int dead_parent(void) { return dead_child(); }\n"
		"int keep(void) { return 2; }\n");
	f.expect_pipeline(
		{ .level = code_gen_options::OptimizationLevel.O1, .whole_program = false, .verify = true },
		before, after);
	f.free();
}

fn void dead_function_elimination_whole_program_roots_main_and_calls() @test
{
	String before =
		"internal i32 @leaf() {\n"
		"entry.0:\n"
		"    ret i32 3\n"
		"}\n\n"
		"internal i32 @middle() {\n"
		"entry.0:\n"
		"    i32 %0 = call ptr_ty @leaf()\n"
		"    ret i32 %0\n"
		"}\n\n"
		"internal i32 @unused() {\n"
		"entry.0:\n"
		"    ret i32 4\n"
		"}\n\n"
		"i32 @unreachable_external() {\n"
		"entry.0:\n"
		"    ret i32 5\n"
		"}\n\n"
		"i32 @main() {\n"
		"entry.0:\n"
		"    i32 %0 = call ptr_ty @middle()\n"
		"    ret i32 %0\n"
		"}\n\n";
	String after =
		"internal i32 @leaf() {\n"
		"entry.0:\n"
		"    ret i32 3\n"
		"}\n\n"
		"internal i32 @middle() {\n"
		"entry.0:\n"
		"    i32 %0 = call ptr_ty @leaf()\n"
		"    ret i32 %0\n"
		"}\n\n"
		"i32 @main() {\n"
		"entry.0:\n"
		"    i32 %0 = call ptr_ty @middle()\n"
		"    ret i32 %0\n"
		"}\n\n";
	OptFixture f;
	f.init();
	f.lower(
		"static int leaf(void) { return 3; }\n"
		"static int middle(void) { return leaf(); }\n"
		"static int unused(void) { return 4; }\n"
		"int unreachable_external(void) { return 5; }\n"
		"int main(void) { return middle(); }\n");
	f.expect_pipeline(
		{ .level = code_gen_options::OptimizationLevel.O1, .whole_program = true, .verify = true },
		before, after);
	f.free();
}

fn void dead_function_elimination_whole_program_keeps_external_definitions_at_o1() @test
{
	String before =
		"internal i32 @unused() {\n"
		"entry.0:\n"
		"    ret i32 1\n"
		"}\n\n"
		"i32 @visible() {\n"
		"entry.0:\n"
		"    ret i32 2\n"
		"}\n\n"
		"i32 @main() {\n"
		"entry.0:\n"
		"    ret i32 0\n"
		"}\n\n";
	String after =
		"i32 @visible() {\n"
		"entry.0:\n"
		"    ret i32 2\n"
		"}\n\n"
		"i32 @main() {\n"
		"entry.0:\n"
		"    ret i32 0\n"
		"}\n\n";
	OptFixture f;
	f.init();
	f.lower(
		"static int unused(void) { return 1; }\n"
		"int visible(void) { return 2; }\n"
		"int main(void) { return 0; }\n");
	f.expect_pipeline({
		.level = code_gen_options::OptimizationLevel.O1,
		.whole_program = true,
		.keep_external_definitions = true,
		.verify = true,
	}, before, after);
	f.free();
}

fn void dead_function_elimination_whole_program_keeps_external_definitions_at_o2() @test
{
	String before =
		"internal i32 @unused() {\n"
		"entry.0:\n"
		"    ret i32 1\n"
		"}\n\n"
		"i32 @visible() {\n"
		"entry.0:\n"
		"    ret i32 2\n"
		"}\n\n"
		"i32 @main() {\n"
		"entry.0:\n"
		"    ret i32 0\n"
		"}\n\n";
	String after =
		"i32 @visible() {\n"
		"entry.0:\n"
		"    ret i32 2\n"
		"}\n\n"
		"i32 @main() {\n"
		"entry.0:\n"
		"    ret i32 0\n"
		"}\n\n";
	OptFixture f;
	f.init();
	f.lower(
		"static int unused(void) { return 1; }\n"
		"int visible(void) { return 2; }\n"
		"int main(void) { return 0; }\n");
	f.expect_pipeline({
		.level = code_gen_options::OptimizationLevel.O2,
		.whole_program = true,
		.keep_external_definitions = true,
		.verify = true,
	}, before, after);
	f.free();
}

fn void dead_function_elimination_whole_program_without_main_roots_external_definitions() @test
{
	String before =
		"internal i32 @unused() {\n"
		"entry.0:\n"
		"    ret i32 1\n"
		"}\n\n"
		"i32 @visible() {\n"
		"entry.0:\n"
		"    ret i32 2\n"
		"}\n\n";
	String after =
		"i32 @visible() {\n"
		"entry.0:\n"
		"    ret i32 2\n"
		"}\n\n";
	OptFixture f;
	f.init();
	f.lower(
		"static int unused(void) { return 1; }\n"
		"int visible(void) { return 2; }\n");
	f.expect_pipeline({
		.level = code_gen_options::OptimizationLevel.O1,
		.whole_program = true,
		.verify = true,
	}, before, after);
	f.free();
}

fn void dead_global_elimination_whole_program_keeps_external_global_when_open() @test
{
	String before =
		"global @visible size 4 align 4 bss tentative\n\n"
		"global @unused size 4 align 4 bss internal tentative\n\n"
		"i32 @main() {\n"
		"entry.0:\n"
		"    ret i32 0\n"
		"}\n\n";
	String after =
		"global @visible size 4 align 4 bss tentative\n\n"
		"i32 @main() {\n"
		"entry.0:\n"
		"    ret i32 0\n"
		"}\n\n";
	OptFixture f;
	f.init();
	f.lower(
		"int visible;\n"
		"static int unused;\n"
		"int main(void) { return 0; }\n");
	f.expect_pipeline({
		.level = code_gen_options::OptimizationLevel.O1,
		.whole_program = true,
		.keep_external_definitions = true,
		.verify = true,
	}, before, after);
	f.free();
}

fn void dead_function_elimination_keeps_address_taken_internal_function() @test
{
	String before =
		"internal i32 @address_taken() {\n"
		"entry.0:\n"
		"    ret i32 6\n"
		"}\n\n"
		"internal i32 @unused() {\n"
		"entry.0:\n"
		"    ret i32 7\n"
		"}\n\n"
		"global @callback size 8 align 8 data {\n"
		"    bytes \"\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\"\n"
		"    reloc 0 @address_taken\n"
		"}\n\n";
	String after =
		"internal i32 @address_taken() {\n"
		"entry.0:\n"
		"    ret i32 6\n"
		"}\n\n"
		"global @callback size 8 align 8 data {\n"
		"    bytes \"\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\"\n"
		"    reloc 0 @address_taken\n"
		"}\n\n";
	OptFixture f;
	f.init();
	f.lower(
		"static int address_taken(void) { return 6; }\n"
		"static int unused(void) { return 7; }\n"
		"int (*callback)(void) = address_taken;\n");
	f.expect_pipeline(
		{ .level = code_gen_options::OptimizationLevel.O1, .whole_program = false, .verify = true },
		before, after);
	f.free();
}

fn void dead_global_elimination_removes_unreferenced_internal_per_tu() @test
{
	String before =
		"global @unused size 4 align 4 bss internal tentative\n\n";
	String after = "";
	OptFixture f;
	f.init();
	f.lower("static int unused;\n");
	f.expect_pipeline(
		{ .level = code_gen_options::OptimizationLevel.O1, .whole_program = false, .verify = true },
		before, after);
	f.free();
}

fn void dead_global_elimination_keeps_external_per_tu() @test
{
	String before =
		"global @visible size 4 align 4 bss tentative\n\n";
	String after = before;
	OptFixture f;
	f.init();
	f.lower("int visible;\n");
	f.expect_pipeline(
		{ .level = code_gen_options::OptimizationLevel.O1, .whole_program = false, .verify = true },
		before, after);
	f.free();
}

fn void dead_global_elimination_whole_program_roots_main() @test
{
	String before =
		"global @reached size 4 align 4 bss internal tentative\n\n"
		"global @unrelated size 4 align 4 bss internal tentative\n\n"
		"i32 @main() {\n"
		"entry.0:\n"
		"    i32 %0 = load ptr_ty @reached\n"
		"    ret i32 %0\n"
		"}\n\n";
	String after =
		"global @reached size 4 align 4 bss internal tentative\n\n"
		"i32 @main() {\n"
		"entry.0:\n"
		"    i32 %0 = load ptr_ty @reached\n"
		"    ret i32 %0\n"
		"}\n\n";
	OptFixture f;
	f.init();
	f.lower(
		"static int reached;\n"
		"static int unrelated;\n"
		"int main(void) { return reached; }\n");
	f.expect_pipeline(
		{ .level = code_gen_options::OptimizationLevel.O1, .whole_program = true, .verify = true },
		before, after);
	f.free();
}

fn void dead_global_elimination_follows_transitive_relocations() @test
{
	String before =
		"global @leaf size 4 align 4 data internal {\n"
		"    bytes \"\\x07\\x00\\x00\\x00\"\n"
		"}\n\n"
		"global @middle size 8 align 8 data internal {\n"
		"    bytes \"\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\"\n"
		"    reloc 0 @leaf\n"
		"}\n\n"
		"global @root size 8 align 8 data internal {\n"
		"    bytes \"\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\"\n"
		"    reloc 0 @middle\n"
		"}\n\n"
		"i32 @main() {\n"
		"entry.0:\n"
		"    ptr_ty %0 = load ptr_ty @root\n"
		"    ptr_ty %1 = load ptr_ty %0\n"
		"    i32 %2 = load ptr_ty %1\n"
		"    ret i32 %2\n"
		"}\n\n";
	String after = before;
	OptFixture f;
	f.init();
	f.lower(
		"static int leaf = 7;\n"
		"static int *middle = &leaf;\n"
		"static int **root = &middle;\n"
		"int main(void) { return **root; }\n");
	f.expect_pipeline(
		{ .level = code_gen_options::OptimizationLevel.O1, .whole_program = true, .verify = true },
		before, after);
	f.free();
}

fn void verifier_accepts_codegen_corpus() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"extern int ext(int);\n"
		"int logic(int a, int b) { if (a && b || a) return 1; return 0; }\n"
		"int caller(int x) { return ext(x); }\n"
		"void no_result(void) { }\n");
	f.verify_graph();
	f.free();
}

fn void verifier_accepts_codegen_control_flow() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"int choose(int c) { if (c) return 1; else return 2; }\n"
		"int loop(int n) { while (n) { break; } return 0; }\n"
		"int select_case(int n) { switch (n) { case 1: return 1; default: return 0; } }\n"
		"int multiple_returns(int c) { if (c) return 1; if (c > 1) return 2; return 3; }\n"
		"int if_without_else(int c) { if (c) return 1; return 0; }\n"
		"int switch_fallthrough(int n) { switch (n) { case 1: n++; case 2: return n; default: return 0; } }\n");
	f.verify_graph();
	f.free();
}

fn void o1_preserves_switch_fallthrough_and_if_without_else() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"int switch_fallthrough(int n) { switch (n) { case 1: n++; case 2: return n; default: return 0; } }\n"
		"int if_without_else(int c, int x) { if (c) x += 1; return x; }\n");
	f.run_o1();
	f.verify_graph();

	uint switch_decl_index = uint::max;
	uint if_decl_index = uint::max;
	foreach (i, decl : f.graph.decls)
	{
		if (decl.name == "switch_fallthrough") switch_decl_index = (uint)i;
		if (decl.name == "if_without_else") if_decl_index = (uint)i;
	}
	assert(switch_decl_index != uint::max, "O1 should retain switch_fallthrough");
	assert(if_decl_index != uint::max, "O1 should retain if_without_else");

	ir::Decl* switch_decl = &f.graph.decls[(sz)switch_decl_index];
	ir::Ref switch_ref = ir::NONE;
	foreach (ref : switch_decl.body)
	{
		if (switch_decl.instructions[(sz)ref].tag == ir::InstTag.SWITCH) switch_ref = ref;
	}
	assert(switch_ref != ir::NONE, "switch_fallthrough should retain its SWITCH terminator");
	ir::Inst* switch_inst = &switch_decl.instructions[(sz)switch_ref];
	assert(switch_inst.data.switch_data.labels.len == 2, "switch should retain both case labels");
	ir::Ref first_case_label = switch_inst.data.switch_data.labels[0];
	ir::Ref second_case_label = switch_inst.data.switch_data.labels[1];
	ir::Ref default_label = switch_inst.data.switch_data.default_label;
	ir_opt::Cfg switch_cfg = ir_opt::build_cfg(switch_decl, &f.ta);
	uint switch_block = switch_cfg.block_of_ref[(sz)switch_ref];
	uint first_case = block_for_label(&switch_cfg, first_case_label);
	uint second_case = block_for_label(&switch_cfg, second_case_label);
	uint default_case = block_for_label(&switch_cfg, default_label);
	assert(has_uint_index(switch_cfg.blocks[(sz)switch_block].succs.array_view(), first_case));
	assert(has_uint_index(switch_cfg.blocks[(sz)switch_block].succs.array_view(), second_case));
	assert(has_uint_index(switch_cfg.blocks[(sz)switch_block].succs.array_view(), default_case));
	assert(has_uint_index(switch_cfg.blocks[(sz)first_case].succs.array_view(), second_case),
		"case 1 must flow into case 2 to preserve switch fall-through");
	switch_cfg.free();

	ir::Decl* if_decl = &f.graph.decls[(sz)if_decl_index];
	ir::Ref branch_ref = ir::NONE;
	foreach (ref : if_decl.body)
	{
		if (if_decl.instructions[(sz)ref].tag == ir::InstTag.BRANCH) branch_ref = ref;
	}
	assert(branch_ref != ir::NONE, "if_without_else should retain its conditional branch");
	ir::Inst* branch = &if_decl.instructions[(sz)branch_ref];
	ir_opt::Cfg if_cfg = ir_opt::build_cfg(if_decl, &f.ta);
	uint branch_block = if_cfg.block_of_ref[(sz)branch_ref];
	uint then_block = block_for_label(&if_cfg, branch.data.branch.then_label);
	uint end_block = block_for_label(&if_cfg, branch.data.branch.else_label);
	assert(has_uint_index(if_cfg.blocks[(sz)branch_block].succs.array_view(), then_block));
	assert(has_uint_index(if_cfg.blocks[(sz)branch_block].succs.array_view(), end_block));
	assert(has_uint_index(if_cfg.blocks[(sz)then_block].succs.array_view(), end_block),
		"the no-else true arm must flow to the merge block");
	if_cfg.free();
	f.free();
}

fn void void_function_dumps_void_ty() @test
{
	OptFixture f;
	f.init();
	f.lower("void g(void) { }");
	String output = f.dump();
	assert(output.contains("void_ty @g() {\n"), "void function dump had an unexpected header: %s", output);
	alloc::free(&f.ta, output.ptr);
	f.free();
}

struct HandIrFixture
{
	TrackingAllocator ta;
	value_interner::Interner interner;
	ir::Builder builder;
	ir::Ir graph;
	bool has_graph;
}

fn void HandIrFixture.init(&self)
{
	self.ta.init(mem);
	self.interner.init(&self.ta);
	self.builder.init(&self.ta, &self.interner);
}

fn void HandIrFixture.finish(&self)
{
	assert(!self.has_graph);
	self.graph = self.builder.finish();
	self.has_graph = true;
}

fn void HandIrFixture.expect_verify_failure(&self)
{
	self.finish();
	ir::ErrorList errors;
	errors.init(&self.ta);
	bool valid = ir_opt::verify(&self.graph, &errors);
	assert(!valid, "malformed test IR unexpectedly passed verification");
	assert(errors.len() != 0, "invalid IR should report a diagnostic");
	assert(errors.message_at(0).len != 0, "invalid IR diagnostic should have a message");
	errors.free();
}

fn void HandIrFixture.free(&self)
{
	if (self.has_graph) self.graph.free();
	self.builder.free();
	self.interner.free();
	assert(self.ta.allocation_count() == 0, "hand-built IR fixture leaked allocations");
	self.ta.free();
}

fn void HandIrFixture.run_o1(&self)
{
	self.finish();
	ir::ErrorList errors;
	errors.init(&self.ta);
	fault f = @catch(ir_opt::run(&self.graph, {
		.level = code_gen_options::OptimizationLevel.O1,
		.whole_program = false,
		.verify = true,
	}, &errors));
	assert(!f, "O1 pipeline failed: %s", errors.len() == 0 ? "no diagnostic message" : errors.message_at(0));
	assert(errors.len() == 0, "successful O1 pipeline left errors");
	errors.free();
}

fn void HandIrFixture.run_o2(&self)
{
	self.finish();
	ir::ErrorList errors;
	errors.init(&self.ta);
	fault f = @catch(ir_opt::run(&self.graph, {
		.level = code_gen_options::OptimizationLevel.O2,
		.whole_program = false,
		.verify = true,
	}, &errors));
	assert(!f, "O2 pipeline failed: %s", errors.len() == 0 ? "no diagnostic message" : errors.message_at(0));
	assert(errors.len() == 0, "successful O2 pipeline left errors");
	errors.free();
}

fn void HandIrFixture.run_mem2reg(&self)
{
	self.finish();
	foreach (&decl : self.graph.decls) ir_opt::mem2reg(&self.graph, decl, &self.ta);
	ir::ErrorList errors;
	errors.init(&self.ta);
	bool valid = ir_opt::verify(&self.graph, &errors);
	assert(valid, "mem2reg produced invalid IR: %s", errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	assert(errors.len() == 0, "valid IR reported verifier errors after mem2reg");
	errors.free();
}

fn Ref HandIrFixture.add_int_constant(&self, long value, value_interner::InternerRef ty)
{
	value_interner::InternerRef constant = self.interner.put(primitive_value::int_key(value));
	return self.builder.add_constant(constant, ty);
}

fn void o1_removes_unreachable_block_and_collapses_phi() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref kept_value = f.builder.add_arg(value_interner::REF_I32);
	Ref unreachable_value = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref entry = f.builder.current_label;
	Ref orphan = f.builder.make_label("orphan");
	Ref join = f.builder.make_label("join");
	Ref exit = f.builder.make_label("exit");
	f.builder.add_branch(condition, join, exit);
	f.builder.start_block(orphan);
	Ref orphan_jump = f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(join);
	ir::PhiInput[2] incoming = {
		{ .label = entry, .value = kept_value },
		{ .label = orphan, .value = unreachable_value },
	};
	Ref phi = f.builder.add_phi(incoming[..], value_interner::REF_I32);
	f.builder.add_return(phi);
	f.builder.start_block(exit);
	f.builder.add_return(kept_value);
	f.builder.finish_fn("unreachable_phi", ir::Linkage.EXTERNAL);
	f.run_o1();

	assert(f.graph.decls.len() == 1, "O1 should keep the external test function");
	ir::Decl* decl = &f.graph.decls[0];
	assert(!has_index(decl.body, orphan), "O1 should remove the no-predecessor block label");
	assert(!has_index(decl.body, orphan_jump), "O1 should remove the unreachable block instructions");
	assert(!has_index(decl.body, phi), "O1 should remove the collapsed PHI instruction");
	bool in_join = false;
	bool saw_join_return = false;
	foreach (ref : decl.body)
	{
		if (ref == join)
		{
			in_join = true;
			continue;
		}
		if (!in_join) continue;
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.LABEL) break;
		if (inst.tag == ir::InstTag.RET)
		{
			assert(inst.data.ref == kept_value, "the join return should use the PHI's remaining value");
			saw_join_return = true;
		}
	}
	assert(saw_join_return, "the reachable join should retain its return instruction");
	f.free();
}

fn void o1_removes_dead_add_but_keeps_call_store_and_variable_sdiv() @test
{
	HandIrFixture f;
	f.init();
	Ref ptr = f.builder.add_arg(value_interner::REF_PTR);
	Ref value = f.builder.add_arg(value_interner::REF_I32);
	Ref lhs = f.builder.add_arg(value_interner::REF_I32);
	Ref rhs = f.builder.add_arg(value_interner::REF_I32);
	Ref divisor = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref callee = f.builder.add_symbol("side_effect", value_interner::REF_PTR);
	Ref dead_add = f.builder.add_inst(ir::InstTag.ADD, { .bin = { lhs, rhs } }, value_interner::REF_I32);
	Ref[1] call_args = { value };
	Ref unused_call = f.builder.add_call(callee, call_args[..], value_interner::REF_I32);
	Ref store = f.builder.add_inst(ir::InstTag.STORE, { .bin = { ptr, value } }, value_interner::REF_VOID);
	Ref variable_sdiv = f.builder.add_inst(ir::InstTag.SDIV, { .bin = { lhs, divisor } }, value_interner::REF_I32);
	f.builder.add_return(value);
	f.builder.finish_fn("dead_instructions", ir::Linkage.EXTERNAL);
	f.run_o1();

	assert(f.graph.decls.len() == 1, "O1 should keep the external test function");
	ir::Decl* decl = &f.graph.decls[0];
	assert(!has_index(decl.body, dead_add), "O1 should remove an unused ADD");
	assert(has_index(decl.body, unused_call), "O1 should keep an unused CALL for its side effects");
	assert(has_index(decl.body, store), "O1 should keep a STORE through an ARG pointer");
	assert(has_index(decl.body, variable_sdiv), "O1 should keep SDIV with a nonconstant divisor");
	f.free();
}

fn void verifier_rejects_malformed_ir() @test
{
	{
		HandIrFixture f;
		f.init();
		f.builder.start_fn();
		// The entry label is placed, but the block has no terminator.
		f.builder.finish_fn("missing_terminator");
		f.expect_verify_failure();
		f.free();
	}
	{
		HandIrFixture f;
		f.init();
		f.builder.start_fn();
		Ref zero = f.builder.add_constant(value_interner::REF_ZERO, value_interner::REF_I32);
		f.builder.body.push(zero);
		f.builder.add_return(zero);
		f.builder.finish_fn("constant_in_body");
		f.expect_verify_failure();
		f.free();
	}
	{
		HandIrFixture f;
		f.init();
		Ref condition = f.builder.add_arg(value_interner::REF_I1);
		f.builder.start_fn();
		Ref valid_target = f.builder.make_label("valid");
		Ref invalid_target = f.builder.add_constant(value_interner::REF_ZERO, value_interner::REF_I32);
		f.builder.add_branch(condition, invalid_target, valid_target);
		f.builder.start_block(valid_target);
		f.builder.add_return(ir::NONE);
		f.builder.finish_fn("bad_branch_target");
		f.expect_verify_failure();
		f.free();
	}
	{
		HandIrFixture f;
		f.init();
		Ref condition = f.builder.add_arg(value_interner::REF_I1);
		Ref value = f.builder.add_arg(value_interner::REF_I32);
		f.builder.start_fn();
		Ref left = f.builder.make_label("left");
		Ref right = f.builder.make_label("right");
		Ref join = f.builder.make_label("join");
		Ref other = f.builder.make_label("other");
		f.builder.add_branch(condition, left, right);
		f.builder.start_block(left);
		f.builder.add_jump(join);
		f.builder.start_block(right);
		f.builder.add_jump(join);
		f.builder.start_block(join);
		ir::PhiInput[2] inputs = {
			{ .label = left, .value = value },
			{ .label = other, .value = value },
		};
		f.builder.add_phi(inputs[..], value_interner::REF_I32);
		f.builder.add_return(value);
		f.builder.start_block(other);
		f.builder.add_return(value);
		f.builder.finish_fn("phi_non_predecessor");
		f.expect_verify_failure();
		f.free();
	}
	{
		HandIrFixture f;
		f.init();
		Ref condition = f.builder.add_arg(value_interner::REF_I1);
		Ref lhs = f.builder.add_arg(value_interner::REF_I32);
		Ref rhs = f.builder.add_arg(value_interner::REF_I32);
		f.builder.start_fn();
		Ref left = f.builder.make_label("left");
		Ref right = f.builder.make_label("right");
		Ref join = f.builder.make_label("join");
		f.builder.add_branch(condition, left, right);
		f.builder.start_block(left);
		Ref value = f.builder.add_inst(ir::InstTag.ADD, { .bin = { lhs, rhs } }, value_interner::REF_I32);
		f.builder.add_jump(join);
		f.builder.start_block(right);
		f.builder.add_jump(join);
		f.builder.start_block(join);
		f.builder.add_return(value);
		f.builder.finish_fn("use_not_dominated");
		f.expect_verify_failure();
		f.free();
	}
}

fn void verifier_rejects_call_hi_separated_from_referenced_call() @test
{
	HandIrFixture f;
	f.init();
	f.builder.start_fn();
	Ref callee = f.builder.add_symbol("pair_result", value_interner::REF_FUNC);
	Ref call = f.builder.add_call_abi(callee, {}, {}, {}, value_interner::REF_I64);
	Ref lhs = f.add_int_constant(1, value_interner::REF_I64);
	Ref rhs = f.add_int_constant(2, value_interner::REF_I64);
	f.builder.add_inst(ir::InstTag.ADD, { .bin = { .lhs = lhs, .rhs = rhs } }, value_interner::REF_I64);
	// Use add_inst to make malformed IR: add_call_hi correctly forbids this gap.
	f.builder.add_inst(ir::InstTag.CALL_HI, { .ref = call }, value_interner::REF_I64);
	f.builder.add_return(call);
	f.builder.finish_fn("call_hi_not_adjacent");
	f.expect_verify_failure();
	f.free();
}

fn bool cfg_has_back_edge(ir_opt::Cfg* cfg)
{
	cfg.compute_dominators();
	foreach (i, block : cfg.blocks)
	{
		foreach (successor : block.succs)
		{
			if (cfg.dominates(successor, (uint)i)) return true;
		}
	}
	return false;
}

fn uint count_body_tag(ir::Decl* decl, ir::InstTag tag)
{
	uint count = 0;
	foreach (ref : decl.body)
	{
		if ((usz)ref < (usz)decl.instructions.len && decl.instructions[(sz)ref].tag == tag) count++;
	}
	return count;
}

fn ir::Ref return_value(ir::Decl* decl)
{
	foreach (ref : decl.body)
	{
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.RET) return inst.data.ref;
	}
	return ir::NONE;
}

fn ir::Decl* find_function(ir::Ir* graph, String name)
{
	foreach (&decl : graph.decls) if (decl.name == name) return decl;
	unreachable("missing IR test function '%s'", name);
}

fn bool has_function(ir::Ir* graph, String name)
{
	foreach (decl : graph.decls) if (decl.name == name) return true;
	return false;
}

fn uint count_calls_to(ir::Decl* decl, String name)
{
	uint count = 0;
	foreach (ref : decl.body)
	{
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag != ir::InstTag.CALL) continue;
		ir::Ref target_ref = inst.data.call.func;
		if ((usz)target_ref >= (usz)decl.instructions.len) continue;
		ir::Inst* target = &decl.instructions[(sz)target_ref];
		if (target.tag == ir::InstTag.SYMBOL && target.data.label == name) count++;
	}
	return count;
}

fn bool is_int_constant(ir::Decl* decl, ir::Ref ref, value_interner::Interner* interner, long expected)
{
	if ((usz)ref >= (usz)decl.instructions.len) return false;
	ir::Inst* value = &decl.instructions[(sz)ref];
	if (value.tag != ir::InstTag.CONSTANT) return false;
	value_interner::InternerRef expected_ref = interner.put(primitive_value::int_key(expected));
	return value.data.constant == expected_ref;
}

fn ir::Ref other_add_operand(ir::Decl* decl, ir::Ref ref,
	value_interner::Interner* interner, long expected)
{
	if ((usz)ref >= (usz)decl.instructions.len) return ir::NONE;
	ir::Inst* inst = &decl.instructions[(sz)ref];
	if (inst.tag != ir::InstTag.ADD) return ir::NONE;
	if (is_int_constant(decl, inst.data.bin.lhs, interner, expected)) return inst.data.bin.rhs;
	if (is_int_constant(decl, inst.data.bin.rhs, interner, expected)) return inst.data.bin.lhs;
	return ir::NONE;
}

fn void assert_returns_arg_plus_int(ir::Decl* decl, value_interner::Interner* interner,
	long expected, String context)
{
	ir::Ref returned = return_value(decl);
	ir::Ref operand = other_add_operand(decl, returned, interner, expected);
	assert(operand != ir::NONE, "%s should return an ADD with constant %d", context, expected);
	assert(has_index(decl.body, operand) && decl.instructions[(sz)operand].tag == ir::InstTag.ARG,
		"%s should add the constant to its argument", context);
}

fn void assert_returns_int(ir::Decl* decl, value_interner::Interner* interner, long expected, String context)
{
	ir::Ref returned = return_value(decl);
	assert(returned != ir::NONE, "%s should have a return value", context);
	ir::Inst* value = &decl.instructions[(sz)returned];
	value_interner::InternerRef expected_ref = interner.put(primitive_value::int_key(expected));
	assert(value.tag == ir::InstTag.CONSTANT && value.data.constant == expected_ref,
		"%s should return integer constant %d", context, expected);
}

fn void o2_inlines_static_square_then_drops_definition() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int sq(int x) { return x * x; }\n"
		"int f(int a) { return sq(a) + 1; }\n");
	f.run_o2();
	f.verify_graph();
	assert(!has_function(&f.graph, "sq"), "inlined static square should be removed after its last call disappears");
	ir::Decl* caller = find_function(&f.graph, "f");
	assert(count_body_tag(caller, ir::InstTag.CALL) == 0, "inlined caller should contain no calls");
	assert(count_body_tag(caller, ir::InstTag.MUL) == 1,
		"caller should retain the multiplication from sq(a)");
	ir::Ref square_operand = other_add_operand(caller, return_value(caller), f.graph.interner, 1);
	assert(square_operand != ir::NONE && has_index(caller.body, square_operand),
		"caller should add 1 to the inlined square result");
	ir::Inst* square = &caller.instructions[(sz)square_operand];
	assert(square.tag == ir::InstTag.MUL && square.data.bin.lhs == square.data.bin.rhs &&
		has_index(caller.body, square.data.bin.lhs) &&
		caller.instructions[(sz)square.data.bin.lhs].tag == ir::InstTag.ARG,
		"inlined square should multiply the caller argument by itself");
	String output = f.dump();
	assert(!output.contains("@sq"), "optimized dump should not retain the static square symbol");
	alloc::free(&f.ta, output.ptr);
	f.free();
}

fn void o2_inlines_nonstatic_definition_but_retains_it_per_tu() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"int callee(int value) { return value + 1; }\n"
		"int caller(int value) { return callee(value); }\n");
	f.run_o2();
	f.verify_graph();
	assert(has_function(&f.graph, "callee"), "non-static callee definition should remain in this translation unit");
	ir::Decl* callee = find_function(&f.graph, "callee");
	assert(callee.linkage == ir::Linkage.EXTERNAL,
		"non-static callee should retain external linkage");
	ir::Decl* caller = find_function(&f.graph, "caller");
	assert(count_calls_to(caller, "callee") == 0, "caller should contain the inlined callee body");
	assert_returns_arg_plus_int(caller, f.graph.interner, 1, "inlined non-static caller");
	String output = f.dump();
	assert(output.contains("i32 @callee("), "optimized dump should retain the non-static definition");
	assert(!output.contains("call ptr_ty @callee"), "optimized dump should not retain the call");
	alloc::free(&f.ta, output.ptr);
	f.free();
}

fn void o2_inlines_multi_return_callee_with_valid_join_phi() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int choose(int condition) { if (condition) return 11; return 13; }\n"
		"int caller(int condition) { return choose(condition); }\n");
	f.run_o2();
	f.verify_graph();
	ir::Decl* caller = find_function(&f.graph, "caller");
	assert(count_calls_to(caller, "choose") == 0, "caller should contain the inlined multi-return body");
	assert(count_body_tag(caller, ir::InstTag.BRANCH) != 0,
		"inlined multi-return callee should retain its condition branch");
	ir::Ref result_ref = return_value(caller);
	assert(result_ref != ir::NONE && caller.instructions[(sz)result_ref].tag == ir::InstTag.PHI,
		"caller return should use the multi-return join PHI");
	ir::Inst* result_phi = &caller.instructions[(sz)result_ref];
	assert(result_phi.data.phi.len == 2, "multi-return join should have one PHI input per return arm");
	bool saw_eleven = false;
	bool saw_thirteen = false;
	foreach (input : result_phi.data.phi)
	{
		saw_eleven = saw_eleven || is_int_constant(caller, input.value, f.graph.interner, 11);
		saw_thirteen = saw_thirteen || is_int_constant(caller, input.value, f.graph.interner, 13);
	}
	assert(saw_eleven && saw_thirteen, "join PHI should preserve both callee return values");
	ir_opt::Cfg cfg = ir_opt::build_cfg(caller, &f.ta);
	uint join = cfg.block_of_ref[(sz)result_ref];
	assert(cfg.blocks[(sz)join].preds.len() == result_phi.data.phi.len,
		"join PHI should have exactly one input for each CFG predecessor");
	foreach (input : result_phi.data.phi)
	{
		uint predecessor = cfg.block_of_ref[(sz)input.label];
		assert(predecessor != uint::max &&
			has_uint_index(cfg.blocks[(sz)join].preds.array_view(), predecessor),
			"join PHI input label should name an actual predecessor");
	}
	cfg.free();
	String output = f.dump();
	assert(output.contains("phi {"), "optimized dump should show the multi-return join PHI");
	alloc::free(&f.ta, output.ptr);
	f.free();
}

fn void o2_leaves_recursive_call_intact() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"int recursive(int value) { if (value <= 0) return 0; return recursive(value - 1); }\n");
	f.run_o2();
	f.verify_graph();
	ir::Decl* recursive = find_function(&f.graph, "recursive");
	assert(count_calls_to(recursive, "recursive") == 1,
		"recursive call should remain instead of expanding into itself");
	String output = f.dump();
	assert(output.contains("call ptr_ty @recursive"), "optimized dump should retain the recursive call");
	alloc::free(&f.ta, output.ptr);
	f.free();
}

fn void o2_inlines_void_pointer_store_and_cleans_up_to_ret_two() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static void bump(int *p) { *p = *p + 1; }\n"
		"int f(void) { int x = 1; bump(&x); return x; }\n");
	f.run_o2();
	f.verify_graph();
	assert(!has_function(&f.graph, "bump"), "inlined static void callee should be removed");
	ir::Decl* caller = find_function(&f.graph, "f");
	assert(count_body_tag(caller, ir::InstTag.CALL) == 0, "void call should disappear after inlining");
	assert_returns_int(caller, f.graph.interner, 2, "void pointer-store caller after mem2reg");
	String output = f.dump();
	assert(output.contains("ret i32 2"), "post-pipeline cleanup should leave ret i32 2");
	assert(!output.contains("call ptr_ty @bump"), "optimized dump should not retain the void call");
	alloc::free(&f.ta, output.ptr);
	f.free();
}

fn void o1_does_not_inline_small_callee() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int leaf(int value) { return value + 1; }\n"
		"int caller(int value) { return leaf(value); }\n");
	f.run_o1();
	f.verify_graph();
	assert(has_function(&f.graph, "leaf"), "O1 should retain the called static leaf");
	assert(count_calls_to(find_function(&f.graph, "caller"), "leaf") == 1,
		"O1 should leave the call intact");
	String output = f.dump();
	assert(output.contains("call ptr_ty @leaf"), "O1 dump should retain the call");
	alloc::free(&f.ta, output.ptr);
	f.free();
}

fn void o2_relabels_successor_phi_after_inlining_call_block() @test
{
	HandIrFixture f;
	f.init();
	Ref callee_condition = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref callee_then = f.builder.make_label("callee_then");
	Ref callee_else = f.builder.make_label("callee_else");
	Ref one = f.add_int_constant(1, value_interner::REF_I32);
	Ref two = f.add_int_constant(2, value_interner::REF_I32);
	f.builder.add_branch(callee_condition, callee_then, callee_else);
	f.builder.start_block(callee_then);
	f.builder.add_return(one);
	f.builder.start_block(callee_else);
	f.builder.add_return(two);
	f.builder.finish_fn("multi_return", ir::Linkage.INTERNAL);

	Ref caller_condition = f.builder.add_arg(value_interner::REF_I1);
	Ref fallback_value = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref call_block = f.builder.make_label("call");
	Ref fallback_block = f.builder.make_label("fallback");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(caller_condition, call_block, fallback_block);
	f.builder.start_block(call_block);
	Ref callee_symbol = f.builder.add_symbol("multi_return", value_interner::REF_PTR);
	Ref[1] call_args = { caller_condition };
	Ref call_result = f.builder.add_call(callee_symbol, call_args[..], value_interner::REF_I32);
	f.builder.add_jump(join);
	f.builder.start_block(fallback_block);
	f.builder.add_jump(join);
	f.builder.start_block(join);
	ir::PhiInput[2] incoming = {
		{ .label = call_block, .value = call_result },
		{ .label = fallback_block, .value = fallback_value },
	};
	f.builder.add_return(f.builder.add_phi(incoming[..], value_interner::REF_I32));
	f.builder.finish_fn("caller");
	f.run_o2();

	ir::Decl* caller = find_function(&f.graph, "caller");
	assert(count_calls_to(caller, "multi_return") == 0, "hand-built call should be inlined");
	ir::Ref successor_phi_ref = ir::NONE;
	foreach (ref : caller.body)
	{
		ir::Inst* inst = &caller.instructions[(sz)ref];
		if (inst.tag != ir::InstTag.PHI) continue;
		foreach (input : inst.data.phi)
		{
			if (input.value == fallback_value) successor_phi_ref = ref;
		}
	}
	assert(successor_phi_ref != ir::NONE, "caller should retain its successor PHI");
	ir::PhiInput[] successor_inputs = caller.instructions[(sz)successor_phi_ref].data.phi;
	assert(successor_inputs.len == 2, "successor PHI should retain both incoming values");
	bool saw_fallback = false;
	bool saw_relabelled_call_edge = false;
	foreach (input : successor_inputs)
	{
		if (input.value == fallback_value)
		{
			saw_fallback = input.label == fallback_block;
		}
		else
		{
			saw_relabelled_call_edge = input.label != call_block;
		}
	}
	assert(saw_fallback, "untouched successor PHI edge should retain its fallback label");
	assert(saw_relabelled_call_edge,
		"successor PHI edge should be relabelled to the inline continuation block");
	ir_opt::Cfg cfg = ir_opt::build_cfg(caller, &f.ta);
	uint join_block = block_for_label(&cfg, join);
	foreach (input : successor_inputs)
	{
		uint predecessor = cfg.block_of_ref[(sz)input.label];
		assert(predecessor != uint::max &&
			has_uint_index(cfg.blocks[(sz)join_block].preds.array_view(), predecessor),
			"successor PHI labels should match the actual join predecessors");
	}
	cfg.free();
	f.free();
}

fn void sccp_folds_source_constants_and_constant_control_flow() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"int local_constant(void) { int first = 40; int second = first + 2; return second; }\n"
		"int constant_branch(void) { if (1) return 9; else return 7; }\n"
		"int constant_switch(void) { switch (2) { case 1: return 10; case 2: return 20; default: return 30; } }\n");
	f.run_o1();
	assert_returns_int(find_function(&f.graph, "local_constant"), f.graph.interner, 42, "local constant propagation");
	assert_returns_int(find_function(&f.graph, "constant_branch"), f.graph.interner, 9, "constant branch");
	ir::Decl* branch_decl = find_function(&f.graph, "constant_branch");
	assert(count_body_tag(branch_decl, ir::InstTag.BRANCH) == 0,
		"the constant branch should be removed");
	assert(count_body_tag(branch_decl, ir::InstTag.RET) == 1,
		"the unselected branch arm should not retain a return");
	assert_returns_int(find_function(&f.graph, "constant_switch"), f.graph.interner, 20, "constant switch");
	ir::Decl* switch_decl = find_function(&f.graph, "constant_switch");
	assert(count_body_tag(switch_decl, ir::InstTag.SWITCH) == 0,
		"the constant switch should be removed");
	assert(count_body_tag(switch_decl, ir::InstTag.RET) == 1,
		"unselected switch arms should not retain returns");
	f.free();
}

fn void sccp_keeps_loop_control_flow_overdefined() @test
{
	OptFixture f;
	f.init();
	f.lower("int loop_not_folded(void) { int n = 0; while (n < 3) n++; return n; }");
	f.run_o1();
	ir::Decl* decl = find_function(&f.graph, "loop_not_folded");
	assert(count_body_tag(decl, ir::InstTag.BRANCH) != 0,
		"the loop condition should remain when its PHI changes across iterations");
	ir::Ref returned = return_value(decl);
	assert(returned != ir::NONE && decl.instructions[(sz)returned].tag != ir::InstTag.CONSTANT,
		"the loop-carried result should not be folded to one constant");
	f.free();
}

fn void sccp_wraps_i8_add_before_signed_compare() @test
{
	HandIrFixture f;
	f.init();
	Ref lhs = f.add_int_constant(127, value_interner::REF_I8);
	Ref rhs = f.add_int_constant(1, value_interner::REF_I8);
	Ref zero = f.add_int_constant(0, value_interner::REF_I8);
	f.builder.start_fn();
	Ref sum = f.builder.add_inst(ir::InstTag.ADD, { .bin = { lhs, rhs } }, value_interner::REF_I8);
	Ref is_negative = f.builder.add_inst(ir::InstTag.CMP_SLT, { .bin = { sum, zero } }, value_interner::REF_I1);
	f.builder.add_return(is_negative);
	f.builder.finish_fn("i8_wrap");
	f.run_o1();
	assert_returns_int(&f.graph.decls[0], &f.interner, 1, "i8 addition wrapping to -128");
	f.free();
}

fn void sccp_preserves_divide_by_zero() @test
{
	HandIrFixture f;
	f.init();
	Ref lhs = f.add_int_constant(42, value_interner::REF_I32);
	Ref zero = f.add_int_constant(0, value_interner::REF_I32);
	f.builder.start_fn();
	Ref quotient = f.builder.add_inst(ir::InstTag.SDIV, { .bin = { lhs, zero } }, value_interner::REF_I32);
	f.builder.add_return(quotient);
	f.builder.finish_fn("divide_by_zero");
	f.run_o1();
	ir::Decl* decl = &f.graph.decls[0];
	assert(has_index(decl.body, quotient), "constant division by zero should remain unfurled");
	assert(return_value(decl) == quotient, "the return should still use the guarded division result");
	f.free();
}

fn void sccp_distinguishes_signed_and_unsigned_i8_comparisons() @test
{
	HandIrFixture f;
	f.init();
	Ref signed_lhs = f.add_int_constant(255, value_interner::REF_I8);
	Ref signed_rhs = f.add_int_constant(1, value_interner::REF_I8);
	f.builder.start_fn();
	Ref signed_less = f.builder.add_inst(ir::InstTag.CMP_SLT,
		{ .bin = { signed_lhs, signed_rhs } }, value_interner::REF_I1);
	f.builder.add_return(signed_less);
	f.builder.finish_fn("signed_less");

	Ref unsigned_lhs = f.add_int_constant(255, value_interner::REF_I8);
	Ref unsigned_rhs = f.add_int_constant(1, value_interner::REF_I8);
	f.builder.start_fn();
	Ref unsigned_less = f.builder.add_inst(ir::InstTag.CMP_ULT,
		{ .bin = { unsigned_lhs, unsigned_rhs } }, value_interner::REF_I1);
	f.builder.add_return(unsigned_less);
	f.builder.finish_fn("unsigned_less");
	f.run_o1();
	assert_returns_int(&f.graph.decls[0], &f.interner, 1, "signed i8 comparison");
	assert_returns_int(&f.graph.decls[1], &f.interner, 0, "unsigned i8 comparison");
	f.free();
}

fn void sccp_leaves_out_of_range_shift_unfolded() @test
{
	HandIrFixture f;
	f.init();
	Ref lhs = f.add_int_constant(1, value_interner::REF_I8);
	Ref amount = f.add_int_constant(8, value_interner::REF_I8);
	f.builder.start_fn();
	Ref shifted = f.builder.add_inst(ir::InstTag.BIT_SHL, { .bin = { lhs, amount } }, value_interner::REF_I8);
	f.builder.add_return(shifted);
	f.builder.finish_fn("out_of_range_shift");
	f.run_o1();
	ir::Decl* decl = &f.graph.decls[0];
	assert(has_index(decl.body, shifted), "a shift by the i8 width should not be evaluated as a host shift");
	assert(return_value(decl) == shifted, "the return should retain the out-of-range shift result");
	f.free();
}

fn void sccp_ignores_phi_input_from_non_executable_edge() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.add_int_constant(1, value_interner::REF_I1);
	Ref live_value = f.add_int_constant(37, value_interner::REF_I32);
	Ref dead_value = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref live = f.builder.make_label("live");
	Ref dead = f.builder.make_label("dead");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(condition, live, dead);
	f.builder.start_block(live);
	f.builder.add_jump(join);
	f.builder.start_block(dead);
	f.builder.add_jump(join);
	f.builder.start_block(join);
	ir::PhiInput[2] inputs = {
		{ .label = live, .value = live_value },
		{ .label = dead, .value = dead_value },
	};
	f.builder.add_return(f.builder.add_phi(inputs[..], value_interner::REF_I32));
	f.builder.finish_fn("phi_dead_edge");
	f.run_o1();
	ir::Decl* decl = &f.graph.decls[0];
	assert_returns_int(decl, &f.interner, 37, "PHI with a non-executable incoming edge");
	assert(count_body_tag(decl, ir::InstTag.PHI) == 0,
		"the PHI should collapse using only the executable incoming edge");
	f.free();
}

fn void mem2reg_promotes_straight_line_local() @test
{
	OptFixture f;
	f.init();
	f.lower("int straight_line(int input) { int local; local = input + 1; return local; }");
	f.run_mem2reg();
	assert(f.graph.decls.len() == 1);
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.ALLOC) == 0, "straight-line local should be promoted");
	assert(count_body_tag(decl, ir::InstTag.LOAD) == 0 && count_body_tag(decl, ir::InstTag.STORE) == 0,
		"promoted straight-line local should have no memory accesses");
	assert(count_body_tag(decl, ir::InstTag.ADD) == 1, "the local's computation should remain");
	Ref returned = ir::NONE;
	foreach (ref : decl.body)
	{
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.RET) returned = inst.data.ref;
	}
	assert(returned != ir::NONE && decl.instructions[(sz)returned].tag == ir::InstTag.ADD,
		"return should use the promoted local's computed value");
	f.free();
}

fn void mem2reg_builds_if_else_join_phi() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"int if_else(int condition, int left, int right) { int result; "
		"if (condition) result = left; else result = right; return result; }");
	f.run_mem2reg();
	assert(f.graph.decls.len() == 1);
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.ALLOC) == 0, "if/else local should be promoted");
	assert(count_body_tag(decl, ir::InstTag.LOAD) == 0 && count_body_tag(decl, ir::InstTag.STORE) == 0,
		"if/else local should have no memory accesses after promotion");
	uint join_phis = 0;
	Ref phi_ref = ir::NONE;
	foreach (ref : decl.body)
	{
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.PHI)
		{
			join_phis++;
			phi_ref = ref;
			assert(inst.data.phi.len == 2, "if/else join PHI should have one value per arm");
		}
	}
	assert(join_phis == 1, "if/else assignment should produce one join PHI");
	Ref returned = ir::NONE;
	foreach (ref : decl.body)
	{
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.RET) returned = inst.data.ref;
	}
	assert(returned == phi_ref, "return should use the if/else join PHI");
	f.free();
}

fn void mem2reg_removes_unused_inserted_phi() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"int dead_phi(int independent) { int value; "
		"if (value) value = 1; else value = 2; return independent; }");
	f.run_mem2reg();
	assert(f.graph.decls.len() == 1);
	assert(count_body_tag(&f.graph.decls[0], ir::InstTag.PHI) == 0,
		"mem2reg should remove the unused PHI for a local assigned in both arms");
	f.free();
}

fn void mem2reg_removes_dead_phi_cycles_and_keeps_live_phi_cycles() @test
{
	HandIrFixture f;
	f.init();
	Ref initial = f.builder.add_arg(value_interner::REF_I32);
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref entry = f.builder.current_label;
	Ref loop = f.builder.make_label("loop");
	Ref exit = f.builder.make_label("exit");
	f.builder.add_jump(loop);
	f.builder.start_block(loop);
	f.builder.add_branch(condition, loop, exit);
	f.builder.start_block(exit);
	f.builder.add_return(initial);
	f.builder.finish_fn("phi_cycles", ir::Linkage.EXTERNAL);
	f.finish();
	Ref returned = ir::NONE;
	foreach (ref : f.graph.decls[0].body)
	{
		if (f.graph.decls[0].instructions[(sz)ref].tag == ir::InstTag.RET) returned = ref;
	}
	assert(returned != ir::NONE, "function should contain its return instruction");

	ir_opt::DeclEditor editor;
	editor.begin(&f.graph.decls[0], &f.ta);
	Ref dead_a = editor.append({ .tag = ir::InstTag.PHI, .ty = value_interner::REF_I32 });
	Ref dead_b = editor.append({ .tag = ir::InstTag.PHI, .ty = value_interner::REF_I32 });
	Ref live_a = editor.append({ .tag = ir::InstTag.PHI, .ty = value_interner::REF_I32 });
	Ref live_b = editor.append({ .tag = ir::InstTag.PHI, .ty = value_interner::REF_I32 });
	ir::PhiInput[2] dead_a_inputs = {
		{ .label = entry, .value = initial }, { .label = loop, .value = dead_b },
	};
	ir::PhiInput[2] dead_b_inputs = {
		{ .label = entry, .value = initial }, { .label = loop, .value = dead_a },
	};
	ir::PhiInput[2] live_a_inputs = {
		{ .label = entry, .value = initial }, { .label = loop, .value = live_b },
	};
	ir::PhiInput[2] live_b_inputs = {
		{ .label = entry, .value = initial }, { .label = loop, .value = live_a },
	};
	editor.insts.entries[(sz)dead_a].data.phi = dead_a_inputs[..];
	editor.insts.entries[(sz)dead_b].data.phi = dead_b_inputs[..];
	editor.insts.entries[(sz)live_a].data.phi = live_a_inputs[..];
	editor.insts.entries[(sz)live_b].data.phi = live_b_inputs[..];

	sz loop_pos = 0;
	while (loop_pos < editor.body.len() && editor.body.entries[loop_pos] != loop) loop_pos++;
	assert(loop_pos < editor.body.len(), "loop label should be placed");
	Ref[4] phis = { dead_a, dead_b, live_a, live_b };
	foreach (i, phi_ref : phis) editor.insert_body(loop_pos + 1 + (sz)i, phi_ref);
	editor.insts.entries[(sz)returned].data.ref = live_a;

	bool[] remove = alloc::new_array(&f.ta, bool, (sz)editor.insts.len());
	for (sz i = 0; i < editor.insts.len(); i++) remove[i] = false;
	bool changed = ir_opt::editor_cleanup_unused_mem2reg_phis(&editor, phis[..], remove);
	assert(changed, "dead mutually-referential PHIs should be removed");
	assert(remove[(sz)dead_a] && remove[(sz)dead_b], "unrooted PHI cycles should be removed");
	assert(!remove[(sz)live_a] && !remove[(sz)live_b],
		"PHI cycles reachable from a non-PHI use should remain live");
	alloc::free(&f.ta, remove.ptr);
	editor.free();
	f.free();
}

fn void mem2reg_builds_loop_header_phis() @test
{
	OptFixture f;
	f.init();
	f.lower("int loop_phi(int n) { int sum = 0; while (n) { sum += n; n--; } return sum; }");
	f.run_mem2reg();
	assert(f.graph.decls.len() == 1);
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.ALLOC) == 0, "loop locals should be promoted");
	assert(count_body_tag(decl, ir::InstTag.LOAD) == 0 && count_body_tag(decl, ir::InstTag.STORE) == 0,
		"promoted loop locals should have no memory accesses");
	ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
	cfg.compute_dominators();
	uint header = ir_opt::NONE_BLOCK;
	foreach (i, block : cfg.blocks)
	{
		foreach (successor : block.succs)
		{
			if (cfg.dominates(successor, (uint)i)) header = successor;
		}
	}
	assert(header != ir_opt::NONE_BLOCK, "loop should retain a CFG back edge");
	uint header_phis = 0;
	ir_opt::CfgBlock* header_block = &cfg.blocks[(sz)header];
	for (sz i = header_block.start; i < header_block.end; i++)
	{
		Ref ref = decl.body[i];
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.PHI)
		{
			header_phis++;
			assert(inst.data.phi.len == 2, "loop header PHI should join entry and back-edge values");
		}
	}
	assert(header_phis >= 2, "loop-carried sum and condition values should each have a header PHI");
	cfg.free();
	f.free();
}

fn void mem2reg_skips_address_taken_local() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"void escape(int *ptr);\n"
		"int address_taken(int input) { int local = input; escape(&local); return local; }");
	f.run_mem2reg();
	ir::Decl* decl = null;
	foreach (&candidate : f.graph.decls)
	{
		if (candidate.name == "address_taken") decl = candidate;
	}
	assert(decl != null, "address-taken fixture function should remain in the graph");
	Ref escaped_alloc = ir::NONE;
	foreach (ref : decl.body)
	{
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.CALL)
		{
			foreach (arg : inst.data.call.args)
			{
				if ((usz)arg < (usz)decl.instructions.len && decl.instructions[(sz)arg].tag == ir::InstTag.ALLOC)
				{
					escaped_alloc = arg;
				}
			}
		}
	}
	assert(escaped_alloc != ir::NONE && has_index(decl.body, escaped_alloc),
		"the allocation whose address escapes to a call must remain in memory");
	assert(count_body_tag(decl, ir::InstTag.LOAD) != 0 && count_body_tag(decl, ir::InstTag.STORE) != 0,
		"address-taken local accesses should remain after the skip");
	f.free();
}

fn void mem2reg_preserves_volatile_local_accesses() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"int volatile_local(void) { volatile int value = 1; return value; }\n"
		"int ordinary_local(void) { int value = 1; return value; }\n");
	f.run_o1();
	ir::Decl* volatile_decl = null;
	ir::Decl* ordinary_decl = null;
	foreach (&candidate : f.graph.decls)
	{
		if (candidate.name == "volatile_local") volatile_decl = candidate;
		if (candidate.name == "ordinary_local") ordinary_decl = candidate;
	}
	assert(volatile_decl != null && ordinary_decl != null, "both local access fixtures should remain in the graph");
	assert(count_body_tag(volatile_decl, ir::InstTag.ALLOC) == 1,
		"volatile local allocation should remain after O1");
	assert(count_body_tag(volatile_decl, ir::InstTag.LOAD) == 1 && count_body_tag(volatile_decl, ir::InstTag.STORE) == 1,
		"volatile local loads and stores should remain after O1");
	bool saw_volatile_alloc = false;
	foreach (ref : volatile_decl.body)
	{
		ir::Inst* inst = &volatile_decl.instructions[(sz)ref];
		if (inst.tag != ir::InstTag.ALLOC) continue;
		saw_volatile_alloc = inst.data.alloc.is_volatile;
	}
	assert(saw_volatile_alloc, "codegen should mark the volatile local allocation");
	assert(count_body_tag(ordinary_decl, ir::InstTag.ALLOC) == 0 &&
		count_body_tag(ordinary_decl, ir::InstTag.LOAD) == 0 && count_body_tag(ordinary_decl, ir::InstTag.STORE) == 0,
		"the nonvolatile twin should still be promoted");
	String dump = f.dump();
	assert(dump.contains("alloc size 4 align 4 volatile"), "IR dump should identify volatile allocations");
	alloc::free(&f.ta, dump.ptr);
	f.free();
}

fn void mem2reg_replaces_uninitialized_read_with_zero() @test
{
	OptFixture f;
	f.init();
	f.lower("int uninitialized_read(void) { int value; return value; }");
	f.run_mem2reg();
	assert(f.graph.decls.len() == 1);
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.ALLOC) == 0 && count_body_tag(decl, ir::InstTag.LOAD) == 0 &&
		count_body_tag(decl, ir::InstTag.STORE) == 0,
		"uninitialized local should be replaced without memory accesses");
	Ref returned = ir::NONE;
	foreach (ref : decl.body)
	{
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.RET) returned = inst.data.ref;
	}
	assert(returned != ir::NONE && decl.instructions[(sz)returned].tag == ir::InstTag.CONSTANT &&
		decl.instructions[(sz)returned].data.constant == value_interner::REF_ZERO,
		"an uninitialized promoted read should become canonical integer zero");
	f.free();
}

fn void mem2reg_skips_hand_built_type_mismatch() @test
{
	HandIrFixture f;
	f.init();
	Ref stored_value = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref slot = f.builder.add_alloc(4, 4);
	f.builder.add_store(slot, stored_value);
	Ref mismatched_load = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I64);
	f.builder.add_return(mismatched_load);
	f.builder.finish_fn("mismatched_slot");
	f.run_mem2reg();
	ir::Decl* decl = &f.graph.decls[0];
	assert(has_index(decl.body, slot), "a slot with mismatched access types should not be promoted");
	assert(has_index(decl.body, mismatched_load), "mismatched load should remain in the skipped slot");
	assert(count_body_tag(decl, ir::InstTag.STORE) == 1 && count_body_tag(decl, ir::InstTag.LOAD) == 1,
		"all mismatched slot accesses should remain unchanged");
	f.free();
}

fn void mem2reg_skips_allocation_size_mismatch() @test
{
	HandIrFixture f;
	f.init();
	Ref stored_value = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref oversized_slot = f.builder.add_alloc(8, 8);
	f.builder.add_store(oversized_slot, stored_value);
	Ref loaded_value = f.builder.add_inst(ir::InstTag.LOAD, { .ref = oversized_slot }, value_interner::REF_I32);
	f.builder.add_return(loaded_value);
	f.builder.finish_fn("oversized_slot");
	f.run_mem2reg();
	ir::Decl* decl = &f.graph.decls[0];
	assert(has_index(decl.body, oversized_slot), "a slot whose size differs from its scalar type should remain");
	assert(has_index(decl.body, loaded_value), "the load from a size-mismatched slot should remain");
	assert(count_body_tag(decl, ir::InstTag.STORE) == 1 && count_body_tag(decl, ir::InstTag.LOAD) == 1,
		"all accesses to a size-mismatched slot should remain unchanged");
	f.free();
}

fn void o1_keeps_loop_sum_and_while_do_back_edges() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"int loop_sum(int n) { int sum = 0; while (n) { sum += n; n--; } return sum; }\n"
		"int while_do(int n) { do { n--; } while (n); return n; }\n");
	f.run_o1();
	f.verify_graph();
	foreach (decl : f.graph.decls)
	{
		assert(decl.name == "loop_sum" || decl.name == "while_do", "unexpected optimizer fixture function: %s", decl.name);
		ir_opt::Cfg cfg = ir_opt::build_cfg(&decl, &f.ta);
		assert(cfg_has_back_edge(&cfg), "O1 should preserve a loop back edge in %s", decl.name);
		cfg.free();
	}
	assert(f.graph.decls.len() == 2, "O1 should retain both externally visible loop functions");
	f.free();
}

fn void cfg_dominators_diamond_and_loop() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref left_value = f.builder.add_arg(value_interner::REF_I32);
	Ref right_value = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref diamond_entry = f.builder.current_label;
	Ref left = f.builder.make_label("left");
	Ref right = f.builder.make_label("right");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(condition, left, right);
	f.builder.start_block(left);
	f.builder.add_jump(join);
	f.builder.start_block(right);
	f.builder.add_jump(join);
	f.builder.start_block(join);
	ir::PhiInput[2] incoming = {
		{ .label = left, .value = left_value },
		{ .label = right, .value = right_value },
	};
	Ref result = f.builder.add_phi(incoming[..], value_interner::REF_I32);
	f.builder.add_return(result);
	f.builder.finish_fn("diamond");

	condition = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref loop_entry = f.builder.current_label;
	Ref header = f.builder.make_label("header");
	Ref body = f.builder.make_label("body");
	Ref exit = f.builder.make_label("exit");
	f.builder.add_jump(header);
	f.builder.start_block(header);
	f.builder.add_branch(condition, body, exit);
	f.builder.start_block(body);
	f.builder.add_jump(header);
	f.builder.start_block(exit);
	f.builder.add_return(condition);
	f.builder.finish_fn("loop");
	f.finish();

	{
		ir_opt::Cfg cfg = ir_opt::build_cfg(&f.graph.decls[0], &f.ta);
		defer cfg.free();
		assert(cfg.blocks.len == 4, "diamond should have entry, two arms, and join blocks");
		uint entry_i = block_for_label(&cfg, diamond_entry);
		uint left_i = block_for_label(&cfg, left);
		uint right_i = block_for_label(&cfg, right);
		uint join_i = block_for_label(&cfg, join);
		assert(cfg.rpo.len == 4 && cfg.rpo[0] == entry_i && cfg.rpo[3] == join_i,
			"diamond reverse postorder should start at entry and end at join");
		assert(cfg.blocks[(sz)entry_i].succs.len() == 2);
		assert(has_uint_index(cfg.blocks[(sz)entry_i].succs.array_view(), left_i));
		assert(has_uint_index(cfg.blocks[(sz)entry_i].succs.array_view(), right_i));
		assert(cfg.blocks[(sz)join_i].preds.len() == 2);
		assert(has_uint_index(cfg.blocks[(sz)join_i].preds.array_view(), left_i));
		assert(has_uint_index(cfg.blocks[(sz)join_i].preds.array_view(), right_i));

		cfg.compute_dominators();
		assert(cfg.idom[(sz)entry_i] == entry_i);
		assert(cfg.idom[(sz)left_i] == entry_i && cfg.idom[(sz)right_i] == entry_i);
		assert(cfg.idom[(sz)join_i] == entry_i);
		assert(cfg.dominates(entry_i, join_i));
		assert(!cfg.dominates(left_i, right_i));
		cfg.compute_frontiers();
		assert(has_uint_index(cfg.blocks[(sz)left_i].frontier.array_view(), join_i));
		assert(has_uint_index(cfg.blocks[(sz)right_i].frontier.array_view(), join_i));
	}
	{
		ir_opt::Cfg cfg = ir_opt::build_cfg(&f.graph.decls[1], &f.ta);
		defer cfg.free();
		assert(cfg.blocks.len == 4, "loop should have entry, header, body, and exit blocks");
		uint entry_i = block_for_label(&cfg, loop_entry);
		uint header_i = block_for_label(&cfg, header);
		uint body_i = block_for_label(&cfg, body);
		uint exit_i = block_for_label(&cfg, exit);
		assert(cfg.rpo.len == 4 && cfg.rpo[0] == entry_i,
			"loop reverse postorder should begin at entry");
		assert(has_uint_index(cfg.blocks[(sz)header_i].preds.array_view(), entry_i));
		assert(has_uint_index(cfg.blocks[(sz)header_i].preds.array_view(), body_i));
		assert(has_uint_index(cfg.blocks[(sz)header_i].succs.array_view(), body_i));
		assert(has_uint_index(cfg.blocks[(sz)header_i].succs.array_view(), exit_i));
		cfg.compute_dominators();
		assert(cfg.idom[(sz)header_i] == entry_i);
		assert(cfg.idom[(sz)body_i] == header_i && cfg.idom[(sz)exit_i] == header_i);
		cfg.compute_frontiers();
		assert(has_uint_index(cfg.blocks[(sz)header_i].frontier.array_view(), header_i),
			"loop header should be in its own dominance frontier");
	}
	f.free();
}

fn void uses_and_replace_all_uses_cover_select_and_phi() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref old_value = f.builder.add_arg(value_interner::REF_I32);
	Ref other_value = f.builder.add_arg(value_interner::REF_I32);
	Ref replacement = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref select = f.builder.add_select(condition, old_value, other_value, value_interner::REF_I32);
	Ref left = f.builder.make_label("left");
	Ref right = f.builder.make_label("right");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(condition, left, right);
	f.builder.start_block(left);
	f.builder.add_jump(join);
	f.builder.start_block(right);
	f.builder.add_jump(join);
	f.builder.start_block(join);
	ir::PhiInput[2] incoming = {
		{ .label = left, .value = old_value },
		{ .label = right, .value = other_value },
	};
	Ref phi = f.builder.add_phi(incoming[..], value_interner::REF_I32);
	f.builder.add_return(phi);
	f.builder.finish_fn("uses");
	f.finish();
	ir::Decl* decl = &f.graph.decls[0];
	ir_opt::Uses uses = ir_opt::compute_uses(decl, &f.ta);
	assert(uses.users[(sz)old_value].len() == 2,
		"the SELECT and PHI should both use the old value");
	assert(has_index(uses.users[(sz)old_value].array_view(), select));
	assert(has_index(uses.users[(sz)old_value].array_view(), phi));
	uses.free();

	ir_opt::replace_all_uses(decl, old_value, replacement);
	assert(decl.instructions[(sz)select].data.branch.then_label == replacement,
		"SELECT value operands should be replaced");
	assert(decl.instructions[(sz)phi].data.phi[0].value == replacement,
		"PHI value operands should be replaced");
	assert(decl.instructions[(sz)phi].data.phi[0].label == left,
		"PHI predecessor labels must not be replaced as value uses");
	Ref branch = ir::NONE;
	foreach (ref : decl.body)
	{
		if (decl.instructions[(sz)ref].tag == ir::InstTag.BRANCH) branch = ref;
	}
	assert(branch != ir::NONE, "test function should contain its control-flow branch");
	assert(decl.instructions[(sz)branch].data.branch.then_label == left &&
		decl.instructions[(sz)branch].data.branch.else_label == right,
		"branch label operands must remain unchanged");
	f.free();
}

// Reduced from gcc.c-torture/execute/pr43220.c: a block-scoped VLA is freed
// when its compound statement ends.
fn void lowers_block_vla_with_stack_save_and_restore() @test
{
	OptFixture f;
	f.init();
	f.lower("int f(int n) { int r; { int a[n]; a[n - 1] = 7; r = a[n - 1]; } return r; }");
	String actual = f.dump();
	test::eq(actual,
		"i32 @f(i32 %0) {\n"
		"entry.0:\n"
		"    ptr_ty %1 = alloc size 4 align 4\n"
		"    ptr_ty %2 = alloc size 4 align 4\n"
		"    store ptr_ty %1, i32 %0\n"
		"    ptr_ty %3 = stack_save\n"
		"    i32 %4 = load ptr_ty %1\n"
		"    i64 %5 = sext i32 %4\n"
		"    i64 %6 = mul i64 %5, i64 4\n"
		"    ptr_ty %7 = dyn_alloc i64 %6 align 4\n"
		"    i32 %8 = load ptr_ty %1\n"
		"    i32 %9 = sub i32 %8, i32 1\n"
		"    i64 %10 = sext i32 %9\n"
		"    i64 %11 = mul i64 %10, i64 4\n"
		"    ptr_ty %12 = add ptr_ty %7, i64 %11\n"
		"    store ptr_ty %12, i32 7\n"
		"    i32 %13 = load ptr_ty %1\n"
		"    i32 %14 = sub i32 %13, i32 1\n"
		"    i64 %15 = sext i32 %14\n"
		"    i64 %16 = mul i64 %15, i64 4\n"
		"    ptr_ty %17 = add ptr_ty %7, i64 %16\n"
		"    i32 %18 = load ptr_ty %17\n"
		"    store ptr_ty %2, i32 %18\n"
		"    stack_restore ptr_ty %3\n"
		"    i32 %19 = load ptr_ty %2\n"
		"    ret i32 %19\n"
		"}\n\n");
	alloc::free(&f.ta, actual.ptr);
	f.run_o1();
	f.verify_graph();
	ir::Decl* func = find_function(&f.graph, "f");
	assert(count_body_tag(func, ir::InstTag.STACK_SAVE) == 1, "O1 keeps the VLA scope's stack save");
	assert(count_body_tag(func, ir::InstTag.DYN_ALLOC) == 1, "O1 keeps the VLA allocation");
	assert(count_body_tag(func, ir::InstTag.STACK_RESTORE) == 1, "O1 keeps the VLA scope's stack restore");
	f.free();
}

// A backward goto out of a VLA scope restores in place; a forward one goes
// through a stub emitted once its label is known.
fn void lowers_goto_out_of_vla_scope() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"int g(int n) {\n"
		"  int k = 0;\n"
		"top:\n"
		"  { int a[n]; a[0] = k; k++; if (k < 3) goto top; if (k == 3) goto out; }\n"
		"out:\n"
		"  return k;\n"
		"}\n");
	String actual = f.dump();
	test::eq(actual,
		"i32 @g(i32 %0) {\n"
		"entry.0:\n"
		"    ptr_ty %1 = alloc size 4 align 4\n"
		"    ptr_ty %2 = alloc size 4 align 4\n"
		"    store ptr_ty %1, i32 %0\n"
		"    store ptr_ty %2, i32 0\n"
		"    jmp label.1\n"
		"label.1:\n"
		"    ptr_ty %3 = stack_save\n"
		"    i32 %4 = load ptr_ty %1\n"
		"    i64 %5 = sext i32 %4\n"
		"    i64 %6 = mul i64 %5, i64 4\n"
		"    ptr_ty %7 = dyn_alloc i64 %6 align 4\n"
		"    i32 %8 = load ptr_ty %2\n"
		"    i64 %9 = sext i32 0\n"
		"    i64 %10 = mul i64 %9, i64 4\n"
		"    ptr_ty %11 = add ptr_ty %7, i64 %10\n"
		"    store ptr_ty %11, i32 %8\n"
		"    i32 %12 = load ptr_ty %2\n"
		"    i32 %13 = add i32 %12, i32 1\n"
		"    store ptr_ty %2, i32 %13\n"
		"    i32 %14 = load ptr_ty %2\n"
		"    i1 %15 = cmp_slt i32 %14, i32 3\n"
		"    branch i1 %15, if.then.2, if.end.4\n"
		"if.then.2:\n"
		"    stack_restore ptr_ty %3\n"
		"    jmp label.1\n"
		"goto.after.3:\n"
		"    jmp if.end.4\n"
		"if.end.4:\n"
		"    i32 %16 = load ptr_ty %2\n"
		"    i1 %17 = cmp_eq i32 %16, i32 3\n"
		"    branch i1 %17, if.then.5, if.end.7\n"
		"if.then.5:\n"
		"    jmp goto.vla.9\n"
		"goto.after.6:\n"
		"    jmp if.end.7\n"
		"if.end.7:\n"
		"    stack_restore ptr_ty %3\n"
		"    jmp label.8\n"
		"label.8:\n"
		"    i32 %18 = load ptr_ty %2\n"
		"    ret i32 %18\n"
		"goto.vla.9:\n"
		"    stack_restore ptr_ty %3\n"
		"    jmp label.8\n"
		"}\n\n");
	alloc::free(&f.ta, actual.ptr);
	f.run_o1();
	f.verify_graph();
	f.free();
}

fn void break_out_of_loop_body_vla_restores_stack() @test
{
	OptFixture f;
	f.init();
	f.lower("void h(int n) { while (n) { int a[n]; a[0] = n; if (n == 2) break; n--; } }");
	ir::Decl* func = find_function(&f.graph, "h");
	// One restore at the body's end and one before the break.
	assert(count_body_tag(func, ir::InstTag.STACK_RESTORE) == 2, "break out of a VLA scope restores the stack");
	f.free();
}

fn void o2_does_not_inline_callee_with_vla() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int fill(int n) { int a[n]; a[0] = n; return a[0]; }\n"
		"int caller(int n) { return fill(n); }\n");
	f.run_o2();
	f.verify_graph();
	ir::Decl* func = find_function(&f.graph, "caller");
	assert(count_body_tag(func, ir::InstTag.CALL) == 1, "a callee with a VLA is not inlined");
	assert(count_body_tag(func, ir::InstTag.DYN_ALLOC) == 0, "the caller does not inherit the VLA");
	f.free();
}

fn void o1_preserves_va_start_and_its_storage_operand() @test
{
	HandIrFixture f;
	f.init();
	f.builder.start_fn();
	ir::Ref va_storage = f.builder.add_alloc(24, 8);
	f.builder.add_va_start(va_storage);
	f.builder.add_return(ir::NONE);
	f.builder.finish_fn("start_va_list");
	f.run_o1();

	ir::Decl* function = find_function(&f.graph, "start_va_list");
	assert(count_body_tag(function, ir::InstTag.VA_START) == 1,
		"O1 must preserve VA_START as an effectful instruction");
	assert(has_index(function.body, va_storage) &&
		function.instructions[(sz)va_storage].tag == ir::InstTag.ALLOC,
		"O1 must preserve the VA_START storage allocation it reads");
	bool saw_va_start_for_storage = false;
	foreach (ref : function.body)
	{
		ir::Inst* inst = &function.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.VA_START)
		{
			saw_va_start_for_storage = inst.data.ref == va_storage;
			break;
		}
	}
	assert(saw_va_start_for_storage, "VA_START must keep its original storage address through O1");
	f.free();
}

fn void o2_does_not_inline_callee_with_va_start() @test
{
	HandIrFixture f;
	f.init();
	f.builder.start_fn();
	ir::Ref callee_va_list = f.builder.add_arg(value_interner::REF_PTR);
	f.builder.add_va_start(callee_va_list);
	f.builder.add_return(ir::NONE);
	f.builder.finish_fn("start_va_list", ir::Linkage.INTERNAL);

	f.builder.start_fn();
	ir::Ref caller_va_list = f.builder.add_arg(value_interner::REF_PTR);
	ir::Ref callee = f.builder.add_symbol("start_va_list", value_interner::REF_FUNC);
	ir::Ref[1] args = { caller_va_list };
	f.builder.add_call(callee, args[..], value_interner::REF_VOID);
	f.builder.add_return(ir::NONE);
	f.builder.finish_fn("caller");
	f.run_o2();

	ir::Decl* start = find_function(&f.graph, "start_va_list");
	ir::Decl* caller = find_function(&f.graph, "caller");
	assert(count_body_tag(start, ir::InstTag.VA_START) == 1,
		"the variadic callee must retain its VA_START instruction");
	assert(count_calls_to(caller, "start_va_list") == 1,
		"O2 must leave calls to a callee containing VA_START intact");
	assert(count_body_tag(caller, ir::InstTag.VA_START) == 0,
		"the callee's VA_START must not be moved into its caller");
	f.free();
}

fn void o1_preserves_float_addition_of_zero() @test
{
	OptFixture f;
	f.init();
	f.lower("double add_zero(double x) { return x + 0.0; }\n");
	f.run_o1();

	ir::Decl* function = find_function(&f.graph, "add_zero");
	assert(count_body_tag(function, ir::InstTag.FADD) == 1,
		"O1 must preserve floating-point addition of zero because it can change signed zero");
	f.free();
}

fn void lowers_va_start_va_arg_va_end() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"int f(int n, ...) { __builtin_va_list ap; "
		"__builtin_va_start(ap,n); int x=__builtin_va_arg(ap,int); "
		"__builtin_va_end(ap); return x; }\n");

	String dump = f.dump();
	assert(dump.contains("    va_start ptr_ty "), "source lowering should emit va_start");
	assert(dump.contains("cmp_ult i32 ") && dump.contains(", i32 48"),
		"va_arg should compare gp_offset against the 48-byte register save limit");
	assert(dump.contains(" = phi {"), "va_arg should merge register and overflow addresses with a PHI");
	alloc::free(&f.ta, dump.ptr);

	f.run_o1();
	f.verify_graph();
	assert(count_body_tag(find_function(&f.graph, "f"), ir::InstTag.VA_START) == 1,
		"O1 should preserve the source-generated VA_START");
	f.free();
}
