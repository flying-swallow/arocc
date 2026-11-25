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
	foreach (&decl : self.graph.decls) ir_opt::mem2reg(&self.graph, decl);
	self.verify_graph();
}

fn void OptFixture.run_sroa_mem2reg(&self)
{
	foreach (&decl : self.graph.decls)
	{
		ir_opt::sroa(&self.graph, decl);
		ir_opt::mem2reg(&self.graph, decl);
	}
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
		"    i32 %4 = add nsw i32 %3, i32 1\n"
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
		"    i32 %4 = add nsw i32 %3, i32 1\n"
		"    store ptr_ty %2, i32 %4\n"
		"    i32 %5 = load ptr_ty %2\n"
		"    ret i32 %5\n"
		"}\n\n";
	String optimized =
		"i32 @f(i32 %0) {\n"
		"entry.0:\n"
		"    i32 %1 = add nsw i32 %0, i32 1\n"
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

fn void dead_decl_elim_ignores_declaration_only_main() @test
{
	HandIrFixture f;
	f.init();
	// A merged IR can contain an unused declaration even if source lowering omits it.
	f.builder.finish_fn("main");
	f.builder.start_fn();
	Ref visible_value = f.builder.add_constant(value_interner::REF_ZERO, value_interner::REF_I32);
	f.builder.add_return(visible_value);
	f.builder.finish_fn("visible");
	f.builder.start_fn();
	Ref unused_value = f.builder.add_constant(value_interner::REF_ZERO, value_interner::REF_I32);
	f.builder.add_return(unused_value);
	f.builder.finish_fn("unused", ir::Linkage.INTERNAL);
	f.finish();
	ir_opt::dead_function_elim(&f.graph, true, false);
	bool kept_main_decl = false;
	bool kept_visible = false;
	bool removed_unused = true;
	foreach (decl : f.graph.decls)
	{
		if (decl.name == "main") kept_main_decl = decl.kind == ir::DeclKind.FUNCTION && decl.body.len == 0;
		if (decl.name == "visible") kept_visible = true;
		if (decl.name == "unused") removed_unused = false;
	}
	assert(kept_main_decl, "the declaration-only main should remain as an external declaration");
	assert(kept_visible, "a declaration-only main must not hide externally visible definitions");
	assert(removed_unused, "unreferenced internal definitions should still be removed");
	f.free();
}

fn void dead_decl_elim_keeps_function_reached_through_global_table() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int cb(void) { return 1; }\n"
		"static int (*const tbl[])(void) = { cb };\n"
		"int main(void) { return tbl[0](); }\n");
	ir_opt::dead_function_elim(&f.graph, true, false);
	bool kept_callback = false;
	bool kept_table = false;
	foreach (decl : f.graph.decls)
	{
		if (decl.name == "cb") kept_callback = true;
		if (decl.name == "tbl") kept_table = true;
	}
	assert(kept_callback && kept_table,
		"main's reachable function-pointer table must retain both the table and its callback");
	f.free();
}

fn void dead_decl_elim_removes_global_reached_only_from_dead_global() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int leaf = 7;\n"
		"static int *dead_root = &leaf;\n"
		"int main(void) { return 0; }\n");
	ir_opt::dead_function_elim(&f.graph, true, false);
	foreach (decl : f.graph.decls)
		assert(decl.name != "leaf" && decl.name != "dead_root",
			"a global reached only from a dead global's relocation must also be removed");
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
		"int if_without_else(int c, int x, int *out) { if (c) { *out = x; x += 1; } return x; }\n");
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

<* entry: jmp_val select(cond, &&a, &&b); a: phi {entry, b}; b: jmp a; dead: ret 9. *>
fn void build_computed_goto_fixture(HandIrFixture* f, bool with_jump)
{
	Ref cond = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref entry = f.builder.current_label;
	Ref a = f.builder.make_label("a");
	Ref b = f.builder.make_label("b");
	Ref dead = f.builder.make_label("dead");
	Ref one = f.add_int_constant(1, value_interner::REF_I32);
	Ref two = f.add_int_constant(2, value_interner::REF_I32);
	Ref addr_a = f.builder.add_inst(ir::InstTag.LABEL_ADDR, { .ref = a }, value_interner::REF_PTR);
	Ref addr_b = f.builder.add_inst(ir::InstTag.LABEL_ADDR, { .ref = b }, value_interner::REF_PTR);
	Ref target = f.builder.add_select(cond, addr_a, addr_b, value_interner::REF_PTR);
	if (with_jump)
	{
		f.builder.add_inst(ir::InstTag.JMP_VAL, { .ref = target }, value_interner::REF_VOID);
	}
	else
	{
		f.builder.add_return(one);
	}
	f.builder.start_block(a);
	if (with_jump)
	{
		ir::PhiInput[2] inputs = { { .label = entry, .value = one }, { .label = b, .value = two } };
		Ref merged = f.builder.add_phi(inputs[..], value_interner::REF_I32);
		f.builder.add_return(merged);
	}
	else
	{
		f.builder.add_return(one);
	}
	f.builder.start_block(b);
	f.builder.add_jump(a);
	f.builder.start_block(dead);
	f.builder.add_return(f.add_int_constant(9, value_interner::REF_I32));
	f.builder.finish_fn("computed_goto");
	f.finish();
}

fn void cfg_computed_goto_reaches_every_address_taken_block() @test
{
	HandIrFixture f;
	f.init();
	build_computed_goto_fixture(&f, true);
	ir::Decl* decl = &f.graph.decls[0];
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "computed goto with a PHI over its edge verifies: %s",
		errors.len() == 0 ? "no message" : errors.message_at(0));
	ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
	assert(cfg.blocks[0].succs.len() == 2, "JMP_VAL has one edge per address-taken block");
	assert(cfg.reachable[1] && cfg.reachable[2] && !cfg.reachable[3],
		"both label targets are reachable; the untaken block is not");
	assert(has_uint_index(cfg.blocks[1].preds.array_view(), 0) && has_uint_index(cfg.blocks[1].preds.array_view(), 2),
		"the PHI block's predecessors are the indirect jump and the direct jump");
	cfg.free();
	assert(ir_opt::remove_unreachable_blocks(decl), "the dead block is removed");
	assert(count_body_tag(decl, ir::InstTag.LABEL) == 3 && count_body_tag(decl, ir::InstTag.LABEL_ADDR) == 2,
		"possible indirect targets and their addresses survive cleanup");
	errors.free();
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "cleaned computed goto verifies: %s",
		errors.len() == 0 ? "no message" : errors.message_at(0));
	errors.free();
	f.free();
}

fn void cfg_unreachable_address_taken_block_nulls_its_address() @test
{
	HandIrFixture f;
	f.init();
	build_computed_goto_fixture(&f, false);
	ir::Decl* decl = &f.graph.decls[0];
	assert(ir_opt::remove_unreachable_blocks(decl), "blocks with no computed goto are unreachable");
	assert(count_body_tag(decl, ir::InstTag.LABEL_ADDR) == 0 && count_body_tag(decl, ir::InstTag.LABEL) == 1,
		"with no computed goto every taken block is removed and its address becomes null");
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "no LABEL_ADDR names a removed block: %s",
		errors.len() == 0 ? "no message" : errors.message_at(0));
	errors.free();
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
	foreach (&decl : self.graph.decls) ir_opt::mem2reg(&self.graph, decl);
	ir::ErrorList errors;
	errors.init(&self.ta);
	bool valid = ir_opt::verify(&self.graph, &errors);
	assert(valid, "mem2reg produced invalid IR: %s", errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	assert(errors.len() == 0, "valid IR reported verifier errors after mem2reg");
	errors.free();
}

fn void HandIrFixture.run_mem_opt(&self)
{
	self.finish();
	foreach (&decl : self.graph.decls) ir_opt::mem_opt(&self.graph, decl);
	ir::ErrorList errors;
	errors.init(&self.ta);
	bool valid = ir_opt::verify(&self.graph, &errors);
	assert(valid, "mem_opt produced invalid IR: %s", errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	assert(errors.len() == 0, "valid IR reported verifier errors after mem_opt");
	errors.free();
}

fn void HandIrFixture.run_gvn(&self)
{
	if (!self.has_graph) self.finish();
	foreach (&decl : self.graph.decls) ir_opt::gvn(&self.graph, decl);
	ir::ErrorList errors;
	errors.init(&self.ta);
	bool valid = ir_opt::verify(&self.graph, &errors);
	assert(valid, "gvn produced invalid IR: %s", errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	assert(errors.len() == 0, "valid IR reported verifier errors after gvn");
	errors.free();
}

fn void HandIrFixture.run_cfg_hoist_sink(&self)
{
	self.finish();
	foreach (&decl : self.graph.decls)
	{
		ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &self.ta);
		ir_opt::cfg_hoist_sink(&self.graph, decl, &cfg);
		cfg.free();
	}
	ir::ErrorList errors;
	errors.init(&self.ta);
	bool valid = ir_opt::verify(&self.graph, &errors);
	assert(valid, "cfg_hoist_sink produced invalid IR: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	assert(errors.len() == 0, "valid IR reported verifier errors after cfg_hoist_sink");
	errors.free();
}

fn Ref HandIrFixture.add_int_constant(&self, long value, value_interner::InternerRef ty)
{
	value_interner::InternerRef constant = self.interner.put(primitive_value::int_key(value));
	return self.builder.add_constant(constant, ty);
}

fn Ref HandIrFixture.add_f64_constant(&self, ulong bits)
{
	value_interner::InternerRef constant = self.interner.put(primitive_value::f64_value(bits));
	return self.builder.add_constant(constant, value_interner::REF_F64);
}

fn bool is_f64_constant(ir::Decl* decl, ir::Ref ref, value_interner::Interner* interner, ulong bits)
{
	if ((usz)ref >= (usz)decl.instructions.len) return false;
	ir::Inst* value = &decl.instructions[(sz)ref];
	if (value.tag != ir::InstTag.CONSTANT || value.ty != value_interner::REF_F64) return false;
	value_interner::InternerRef expected = interner.put(primitive_value::f64_value(bits));
	return value.data.constant == expected;
}

fn Ref HandIrFixture.add_f32_constant(&self, uint bits)
{
	value_interner::InternerRef constant = self.interner.put(primitive_value::f32_value(bits));
	return self.builder.add_constant(constant, value_interner::REF_F32);
}

fn bool is_f32_constant(ir::Decl* decl, ir::Ref ref, value_interner::Interner* interner, uint bits)
{
	if ((usz)ref >= (usz)decl.instructions.len) return false;
	ir::Inst* value = &decl.instructions[(sz)ref];
	if (value.tag != ir::InstTag.CONSTANT || value.ty != value_interner::REF_F32) return false;
	value_interner::InternerRef expected = interner.put(primitive_value::f32_value(bits));
	return value.data.constant == expected;
}

fn bool is_bool_constant(ir::Decl* decl, ir::Ref ref, value_interner::InternerRef expected)
{
	return (usz)ref < (usz)decl.instructions.len &&
		decl.instructions[(sz)ref].tag == ir::InstTag.CONSTANT &&
		decl.instructions[(sz)ref].data.constant == expected;
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

fn void remove_unreachable_blocks_multi_input_trim() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref kept_value = f.builder.add_arg(value_interner::REF_I32);
	Ref dead_value_a = f.builder.add_arg(value_interner::REF_I32);
	Ref dead_value_b = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref entry = f.builder.current_label;
	Ref dead_a = f.builder.make_label("dead_a");
	Ref dead_b = f.builder.make_label("dead_b");
	Ref join = f.builder.make_label("join");
	Ref exit = f.builder.make_label("exit");
	f.builder.add_branch(condition, join, exit);
	f.builder.start_block(dead_a);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(dead_b);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(join);
	ir::PhiInput[3] inputs = {
		{ .label = entry, .value = kept_value },
		{ .label = dead_a, .value = dead_value_a },
		{ .label = dead_b, .value = dead_value_b },
	};
	Ref phi = f.builder.add_phi(inputs[..], value_interner::REF_I32);
	f.builder.add_return(phi);
	f.builder.start_block(exit);
	f.builder.add_return(kept_value);
	f.builder.finish_fn("multi_input_unreachable_phi");
	f.finish();
	assert(ir_opt::remove_unreachable_blocks(&f.graph.decls[0]),
		"the pass should remove dead blocks and trim their PHI edges");
	assert(!has_index(f.graph.decls[0].body, phi), "the single remaining PHI input should collapse");
	assert(return_value(&f.graph.decls[0]) == kept_value, "the join should return the surviving incoming value");
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "trimmed multi-input PHI should verify: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	errors.free();
	f.free();
}

fn void remove_unreachable_blocks_collapses_phi_chain() @test
{
	HandIrFixture f;
	f.init();
	Ref input = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref entry = f.builder.current_label;
	Ref first_block = f.builder.make_label("first");
	Ref second_block = f.builder.make_label("second");
	f.builder.add_inst(ir::InstTag.JMP, { .ref = first_block }, value_interner::REF_NORETURN);
	f.builder.start_block(first_block);
	ir::PhiInput[1] first_input = { { .label = entry, .value = input } };
	Ref first_phi = f.builder.add_phi(first_input[..], value_interner::REF_I32);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = second_block }, value_interner::REF_NORETURN);
	f.builder.start_block(second_block);
	ir::PhiInput[1] second_input = { { .label = first_block, .value = first_phi } };
	Ref second_phi = f.builder.add_phi(second_input[..], value_interner::REF_I32);
	f.builder.add_return(second_phi);
	f.builder.finish_fn("single_phi_chain");
	f.finish();
	assert(ir_opt::remove_unreachable_blocks(&f.graph.decls[0]), "the pass should collapse single-input PHIs");
	assert(!has_index(f.graph.decls[0].body, first_phi) && !has_index(f.graph.decls[0].body, second_phi),
		"both PHIs in consecutive blocks should collapse in one pass call");
	assert(return_value(&f.graph.decls[0]) == input, "the PHI chain should forward its original input");
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "collapsed PHI chain should verify: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	errors.free();
	f.free();
}

fn void remove_unreachable_blocks_drops_unreachable_cycle() @test
{
	HandIrFixture f;
	f.init();
	f.builder.start_fn();
	Ref dead_loop = f.builder.make_label("dead_loop");
	f.builder.add_return(f.add_int_constant(0, value_interner::REF_I32));
	f.builder.start_block(dead_loop);
	Ref backedge = f.builder.add_inst(ir::InstTag.JMP, { .ref = dead_loop }, value_interner::REF_NORETURN);
	f.builder.finish_fn("dead_cycle");
	f.finish();
	assert(ir_opt::remove_unreachable_blocks(&f.graph.decls[0]), "an unreachable self-cycle should be removed");
	assert(!has_index(f.graph.decls[0].body, dead_loop) && !has_index(f.graph.decls[0].body, backedge),
		"all placements in the unreachable cycle should disappear");
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "IR after removing an unreachable cycle should verify: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	errors.free();
	f.free();
}

fn void remove_unreachable_blocks_drops_unplaced_phi_label() @test
{
	HandIrFixture f;
	f.init();
	Ref input = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref entry = f.builder.current_label;
	Ref join = f.builder.make_label("join");
	Ref unplaced = f.builder.make_label("unplaced");
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(join);
	ir::PhiInput[2] inputs = {
		{ .label = entry, .value = input },
		{ .label = unplaced, .value = input },
	};
	Ref phi = f.builder.add_phi(inputs[..], value_interner::REF_I32);
	f.builder.add_return(phi);
	f.builder.finish_fn("unplaced_phi_label");
	f.finish();
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(!ir_opt::verify(&f.graph, &errors), "an unplaced PHI predecessor label must be rejected before cleanup");
	errors.free();
	errors.init(&f.ta);
	assert(ir_opt::remove_unreachable_blocks(&f.graph.decls[0]), "the cleanup should discard the unplaced label input");
	assert(!has_index(f.graph.decls[0].body, phi), "the repaired one-input PHI should collapse");
	assert(return_value(&f.graph.decls[0]) == input, "the return should use the remaining input");
	assert(ir_opt::verify(&f.graph, &errors), "IR after dropping the unplaced PHI label should verify: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	errors.free();
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

fn void dead_instruction_elim_keeps_unknown_and_arity_mismatched_calls() @test
{
	HandIrFixture f;
	f.init();
	Ref zero = f.add_int_constant(0, value_interner::REF_I32);
	Ref one = f.add_int_constant(1, value_interner::REF_I32);
	f.builder.start_fn();
	Ref known = f.builder.add_symbol("known", value_interner::REF_PTR);
	Ref unknown = f.builder.add_symbol("unknown", value_interner::REF_PTR);
	Ref[1] one_arg = { one };
	Ref mismatch = f.builder.add_call(known, one_arg[..], value_interner::REF_I32);
	Ref external_call = f.builder.add_call(unknown, one_arg[0..0], value_interner::REF_I32);
	f.builder.add_return(zero);
	f.builder.finish_fn("caller");
	f.builder.finish_fn("unknown"); // External declaration: no body.
	f.builder.start_fn();
	Ref callee_zero = f.add_int_constant(0, value_interner::REF_I32);
	f.builder.add_return(callee_zero);
	f.builder.finish_fn("known", ir::Linkage.INTERNAL);
	f.finish();
	ir::Decl* callee = null;
	ir::Decl* caller = null;
	foreach (&decl : f.graph.decls)
	{
		if (decl.name == "known") callee = decl;
		if (decl.name == "caller") caller = decl;
	}
	assert(callee != null && caller != null, "the call fixture should contain caller and known callee");
	callee.attrs = { .computed = true, .readnone = true, .will_return = true };
	assert(!ir_opt::dead_instruction_elim(caller, &f.graph),
		"neither an unknown external call nor a mismatched call may be considered removable");
	assert(has_index(caller.body, mismatch) && has_index(caller.body, external_call),
		"DIE must preserve both the mismatched and declaration-only calls");
	f.free();
}

fn void dead_instruction_elim_division_policy() @test
{
	HandIrFixture f;
	f.init();
	Ref zero = f.add_int_constant(0, value_interner::REF_I32);
	Ref three = f.add_int_constant(3, value_interner::REF_I32);
	Ref arg0 = f.builder.add_arg(value_interner::REF_I32);
	Ref arg1 = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref variable_div = f.builder.add_inst(ir::InstTag.SDIV, { .bin = { arg0, arg1 } }, value_interner::REF_I32);
	Ref const_div = f.builder.add_inst(ir::InstTag.SDIV, { .bin = { arg0, three } }, value_interner::REF_I32);
	Ref zero_mod = f.builder.add_inst(ir::InstTag.SREM, { .bin = { arg0, zero } }, value_interner::REF_I32);
	f.builder.add_return(zero);
	f.builder.finish_fn("division_policy");
	f.finish();
	ir::Decl* decl = &f.graph.decls[0];
	assert(ir_opt::dead_instruction_elim(decl), "constant nonzero division should be removed");
	assert(has_index(decl.body, variable_div), "division by a variable divisor remains conservatively live");
	assert(!has_index(decl.body, const_div), "division by a constant nonzero divisor is removable");
	assert(has_index(decl.body, zero_mod), "remainder by zero remains conservatively live");
	f.free();
}

fn void dead_instruction_elim_keeps_atomics_and_fence() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"int f(int *p, unsigned value) { (void)__atomic_load_n(p, 5); "
		"__atomic_store_n(p, 1, 5); __atomic_thread_fence(5); "
		"(void)__builtin_clz(value); return 0; }\n");
	ir::Decl* decl = find_function(&f.graph, "f");
	assert(ir_opt::dead_instruction_elim(decl, &f.graph),
		"DIE should remove the unused pure CLZ");
	assert(count_body_tag(decl, ir::InstTag.ATOMIC_LOAD) == 1 &&
		count_body_tag(decl, ir::InstTag.ATOMIC_STORE) == 1 &&
		count_body_tag(decl, ir::InstTag.FENCE) == 1,
		"unused atomic loads, atomic stores, and fences must remain observable");
	assert(count_body_tag(decl, ir::InstTag.CLZ) == 0, "an unused pure CLZ should be removed");
	f.free();
}

fn void dead_instruction_elim_keeps_volatile_global_load() @test
{
	HandIrFixture f;
	f.init();
	char[] no_bytes = alloc::new_array(&f.ta, char, 0);
	ir::DataReloc[] no_relocs = alloc::new_array(&f.ta, ir::DataReloc, 0);
	f.builder.add_global("volatile_global", ir::Linkage.EXTERNAL, {
		.size = 4,
		.align = 4,
		.bytes = no_bytes,
		.relocs = no_relocs,
		.section = ir::DataSection.BSS,
		.is_volatile = true,
	});
	alloc::free(&f.ta, no_bytes.ptr);
	alloc::free(&f.ta, no_relocs.ptr);
	f.builder.start_fn();
	Ref global_ptr = f.builder.add_symbol("volatile_global", value_interner::REF_PTR);
	Ref load = f.builder.add_inst(ir::InstTag.LOAD, { .ref = global_ptr }, value_interner::REF_I32);
	Ref zero = f.builder.add_constant(value_interner::REF_ZERO, value_interner::REF_I32);
	f.builder.add_return(zero);
	f.builder.finish_fn("volatile_load");
	f.finish();
	ir::Decl* decl = find_function(&f.graph, "volatile_load");
	ir_opt::dead_instruction_elim(decl, &f.graph);
	assert(has_index(decl.body, load), "an unused volatile global load must remain observable");
	assert(f.graph.decls[0].kind == ir::DeclKind.GLOBAL && f.graph.decls[0].global.is_volatile,
		"the referenced global should carry its volatile marker");
	f.free();
}

fn void dead_instruction_elim_keeps_volatile_member_store() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"struct S { volatile int value; };\n"
		"void f(void) { struct S local; local.value = 1; }\n");
	ir::Decl* decl = find_function(&f.graph, "f");
	assert(count_body_tag(decl, ir::InstTag.ALLOC) == 1 && count_body_tag(decl, ir::InstTag.STORE) == 1,
		"the volatile-member local should lower to an allocation and store");
	Ref alloc_ref = ir::NONE;
	foreach (ref : decl.body)
	{
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.ALLOC) alloc_ref = ref;
	}
	assert(alloc_ref != ir::NONE && decl.instructions[(sz)alloc_ref].data.alloc.is_volatile,
		"codegen must mark an allocation volatile when a member is volatile");
	assert(!ir_opt::dead_instruction_elim(decl, &f.graph),
		"DIE must preserve the unused volatile-member store and its allocation");
	assert(count_body_tag(decl, ir::InstTag.ALLOC) == 1 && count_body_tag(decl, ir::InstTag.STORE) == 1,
		"the volatile-member allocation and store must remain after DIE");
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
		Ref lhs = f.add_int_constant(1, value_interner::REF_I32);
		Ref rhs = f.add_int_constant(1, value_interner::REF_I32);
		f.builder.start_fn();
		Ref yes = f.builder.make_label("yes");
		Ref no = f.builder.make_label("no");
		f.builder.add_branch(condition, yes, no);
		Ref branch = f.builder.body[f.builder.body.len() - 1];
		// A terminator ends its block. A condition created in the dead tail after
		// it cannot be used to justify SCCP's branch rewrite.
		Ref dead_tail_condition = f.builder.add_inst(ir::InstTag.CMP_EQ,
			{ .bin = { lhs, rhs } }, value_interner::REF_I1);
		f.builder.instructions[(sz)branch].data.branch.cond = dead_tail_condition;
		f.builder.start_block(yes);
		f.builder.add_return(lhs);
		f.builder.start_block(no);
		f.builder.add_return(rhs);
		f.builder.finish_fn("branch_uses_dead_tail_condition");
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

fn void HandIrFixture.run_if_convert(&self)
{
	self.run_o1();
}

fn void if_convert_converts_diamond_phi_to_select() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref yes = f.add_int_constant(11, value_interner::REF_I32);
	Ref no = f.add_int_constant(29, value_interner::REF_I32);
	f.builder.start_fn();
	Ref left = f.builder.make_label("left");
	Ref right = f.builder.make_label("right");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(condition, left, right);
	f.builder.start_block(left);
	f.builder.add_jump(join);
	f.builder.start_block(right);
	f.builder.add_jump(join);
	f.builder.start_block(join);
	ir::PhiInput[2] inputs = { { .label = left, .value = yes }, { .label = right, .value = no } };
	Ref result = f.builder.add_phi(inputs[..], value_interner::REF_I32);
	f.builder.add_return(result);
	f.builder.finish_fn("if_convert_diamond", ir::Linkage.EXTERNAL);
	f.run_if_convert();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.SELECT) == 1 && count_body_tag(decl, ir::InstTag.PHI) == 0,
		"a diamond with one join PHI should become one SELECT and lose its PHI");
	assert(count_body_tag(decl, ir::InstTag.BRANCH) == 0,
		"the converted diamond should not retain its conditional branch");
	f.free();
}

fn void if_convert_accepts_non_builtin_integer_width() @test
{
	HandIrFixture f;
	f.init();
	value_interner::InternerRef i24 = f.interner.put({ .tag = primitive_value::PrimitiveType.INT_TY, .ty_bits = 24 });
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref yes = f.add_int_constant(11, i24);
	Ref no = f.add_int_constant(29, i24);
	f.builder.start_fn();
	Ref left = f.builder.make_label("left");
	Ref right = f.builder.make_label("right");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(condition, left, right);
	f.builder.start_block(left);
	f.builder.add_jump(join);
	f.builder.start_block(right);
	f.builder.add_jump(join);
	f.builder.start_block(join);
	ir::PhiInput[2] inputs = { { .label = left, .value = yes }, { .label = right, .value = no } };
	Ref result = f.builder.add_phi(inputs[..], i24);
	f.builder.add_return(result);
	f.builder.finish_fn("if_convert_i24_diamond", ir::Linkage.EXTERNAL);
	f.run_if_convert();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.SELECT) == 1 && count_body_tag(decl, ir::InstTag.PHI) == 0,
		"a 24-bit integer diamond should become one SELECT and lose its PHI");
	f.free();
}

fn void if_convert_converts_triangle_with_one_fallthrough_arm() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref value = f.builder.add_arg(value_interner::REF_I32);
	Ref fallback = f.add_int_constant(7, value_interner::REF_I32);
	f.builder.start_fn();
	Ref entry = f.builder.current_label;
	Ref then_block = f.builder.make_label("then");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(condition, then_block, join);
	f.builder.start_block(then_block);
	Ref incremented = f.builder.add_inst(ir::InstTag.ADD,
		{ .bin = { value, fallback } }, value_interner::REF_I32);
	f.builder.add_jump(join);
	f.builder.start_block(join);
	ir::PhiInput[2] inputs = {
		{ .label = then_block, .value = incremented },
		{ .label = entry, .value = fallback },
	};
	Ref result = f.builder.add_phi(inputs[..], value_interner::REF_I32);
	f.builder.add_return(result);
	f.builder.finish_fn("if_convert_triangle", ir::Linkage.EXTERNAL);
	f.run_if_convert();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.SELECT) == 1 && count_body_tag(decl, ir::InstTag.PHI) == 0,
		"a one-arm triangle should become a SELECT without a join PHI");
	f.free();
}

fn void if_convert_rejects_more_than_four_join_phis() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref[10] values;
	for (sz i = 0; i < values.len; i++) values[i] = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref left = f.builder.make_label("left");
	Ref right = f.builder.make_label("right");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(condition, left, right);
	f.builder.start_block(left);
	f.builder.add_jump(join);
	f.builder.start_block(right);
	f.builder.add_jump(join);
	f.builder.start_block(join);
	Ref[5] phis;
	for (sz i = 0; i < phis.len; i++)
	{
		ir::PhiInput[2] inputs = {
			{ .label = left, .value = values[i * 2] },
			{ .label = right, .value = values[i * 2 + 1] },
		};
		phis[i] = f.builder.add_phi(inputs[..], value_interner::REF_I32);
	}
	Ref sum = phis[0];
	for (sz i = 1; i < phis.len; i++)
	{
		sum = f.builder.add_inst(ir::InstTag.ADD, { .bin = { sum, phis[i] } }, value_interner::REF_I32);
	}
	f.builder.add_return(sum);
	f.builder.finish_fn("if_convert_many_phis", ir::Linkage.EXTERNAL);
	f.run_if_convert();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.SELECT) == 0 && count_body_tag(decl, ir::InstTag.PHI) == 5,
		"a join with more than four PHIs should remain a branch diamond");
	f.free();
}

fn void if_convert_rejects_unsafe_op(ir::InstTag tag)
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref dividend = f.builder.add_arg(value_interner::REF_I32);
	Ref divisor = f.builder.add_arg(value_interner::REF_I32);
	Ref pointer = f.builder.add_arg(value_interner::REF_PTR);
	Ref callee = f.builder.add_symbol("side_effect", value_interner::REF_FUNC);
	f.builder.start_fn();
	Ref left = f.builder.make_label("left");
	Ref right = f.builder.make_label("right");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(condition, left, right);
	f.builder.start_block(left);
	Ref left_value;
	switch (tag)
	{
		case CALL: left_value = f.builder.add_call(callee, {}, value_interner::REF_I32);
		case LOAD: left_value = f.builder.add_load(pointer, value_interner::REF_I32);
		case SDIV: left_value = f.builder.add_inst(tag,
			{ .bin = { dividend, divisor } }, value_interner::REF_I32);
		default: unreachable("unexpected unsafe operation");
	}
	f.builder.add_jump(join);
	f.builder.start_block(right);
	Ref right_value;
	switch (tag)
	{
		case CALL: right_value = f.builder.add_call(callee, {}, value_interner::REF_I32);
		case LOAD: right_value = f.builder.add_load(pointer, value_interner::REF_I32);
		case SDIV: right_value = f.builder.add_inst(tag,
			{ .bin = { dividend, divisor } }, value_interner::REF_I32);
		default: unreachable("unexpected unsafe operation");
	}
	f.builder.add_jump(join);
	f.builder.start_block(join);
	ir::PhiInput[2] inputs = { { .label = left, .value = left_value }, { .label = right, .value = right_value } };
	Ref result = f.builder.add_phi(inputs[..], value_interner::REF_I32);
	f.builder.add_return(result);
	f.builder.finish_fn("if_convert_unsafe", ir::Linkage.EXTERNAL);
	f.run_if_convert();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.SELECT) == 0 && count_body_tag(decl, ir::InstTag.BRANCH) == 1,
		"calls, loads, and potentially trapping divisions must prevent if-conversion");
	assert(count_body_tag(decl, tag) == 2, "unsafe operation instances must remain in their original arms");
	f.free();
}

fn void if_convert_rejects_calls_loads_and_sdiv() @test
{
	if_convert_rejects_unsafe_op(ir::InstTag.CALL);
	if_convert_rejects_unsafe_op(ir::InstTag.LOAD);
	if_convert_rejects_unsafe_op(ir::InstTag.SDIV);
}

fn void if_convert_rejects_arms_over_instruction_limit() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref value = f.builder.add_arg(value_interner::REF_I32);
	Ref one = f.add_int_constant(1, value_interner::REF_I32);
	f.builder.start_fn();
	Ref left = f.builder.make_label("left");
	Ref right = f.builder.make_label("right");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(condition, left, right);
	f.builder.start_block(left);
	Ref l1 = f.builder.add_inst(ir::InstTag.ADD, { .bin = { value, one } }, value_interner::REF_I32);
	Ref l2 = f.builder.add_inst(ir::InstTag.ADD, { .bin = { l1, one } }, value_interner::REF_I32);
	Ref l3 = f.builder.add_inst(ir::InstTag.ADD, { .bin = { l2, one } }, value_interner::REF_I32);
	f.builder.add_jump(join);
	f.builder.start_block(right);
	Ref r1 = f.builder.add_inst(ir::InstTag.SUB, { .bin = { value, one } }, value_interner::REF_I32);
	Ref r2 = f.builder.add_inst(ir::InstTag.SUB, { .bin = { r1, one } }, value_interner::REF_I32);
	Ref r3 = f.builder.add_inst(ir::InstTag.SUB, { .bin = { r2, one } }, value_interner::REF_I32);
	f.builder.add_jump(join);
	f.builder.start_block(join);
	ir::PhiInput[2] inputs = { { .label = left, .value = l3 }, { .label = right, .value = r3 } };
	Ref result = f.builder.add_phi(inputs[..], value_interner::REF_I32);
	f.builder.add_return(result);
	f.builder.finish_fn("if_convert_large_arms", ir::Linkage.EXTERNAL);
	f.run_if_convert();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.SELECT) == 0 && count_body_tag(decl, ir::InstTag.PHI) == 1,
		"arms exceeding the conversion size limit should retain their join PHI");
	assert(count_body_tag(decl, ir::InstTag.BRANCH) != 0,
		"the oversized arm diamond should retain its conditional control flow");
	f.free();
}

fn void if_convert_diamond_of_constants_to_select() @test
{
	OptFixture f;
	f.init();
	f.lower("int if_convert_diamond_of_constants(int condition) { return condition ? 11 : 29; }");
	f.run_o1();
	ir::Decl* decl = find_function(&f.graph, "if_convert_diamond_of_constants");
	assert(count_body_tag(decl, ir::InstTag.SELECT) == 1,
		"O1 should lower a constant-valued conditional diamond to a SELECT");
	assert(count_body_tag(decl, ir::InstTag.BRANCH) == 0 && count_body_tag(decl, ir::InstTag.PHI) == 0,
		"the O1 constant diamond should no longer contain a branch or PHI");
	f.free();
}

fn void if_convert_triangle_with_add() @test
{
	OptFixture f;
	f.init();
	f.lower("int if_convert_triangle_with_add(int condition, int value) { if (condition) value = value + 3; return value; }");
	f.run_o1();
	ir::Decl* decl = find_function(&f.graph, "if_convert_triangle_with_add");
	assert(count_body_tag(decl, ir::InstTag.SELECT) == 1,
		"O1 should lower the one-arm addition triangle to a SELECT");
	assert(count_body_tag(decl, ir::InstTag.BRANCH) == 0 && count_body_tag(decl, ir::InstTag.PHI) == 0,
		"the O1 addition triangle should no longer contain a branch or PHI");
	f.free();
}

fn void if_convert_keeps_guarded_division_conditional() @test
{
	OptFixture f;
	f.init();
	f.lower("int if_convert_guarded_division(int d) { return d != 0 ? 100 / d : 0; }");
	f.run_o1();
	ir::Decl* decl = find_function(&f.graph, "if_convert_guarded_division");
	assert(count_body_tag(decl, ir::InstTag.SDIV) == 1,
		"O1 should retain the guarded potentially trapping signed division");
	assert(count_body_tag(decl, ir::InstTag.BRANCH) != 0,
		"the zero check must remain conditional instead of speculating the division");
	f.free();
}

fn Ref first_body_tag(ir::Decl* decl, ir::InstTag tag)
{
	foreach (ref : decl.body) if (decl.instructions[(sz)ref].tag == tag) return ref;
	return ir::NONE;
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

fn void cfg_hoist_sink_merges_identical_adds_from_diamond_arms() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref lhs = f.builder.add_arg(value_interner::REF_I32);
	Ref rhs = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref entry = f.builder.current_label;
	Ref left = f.builder.make_label("left");
	Ref right = f.builder.make_label("right");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(condition, left, right);
	f.builder.start_block(left);
	Ref left_add = f.builder.add_inst(ir::InstTag.ADD, { .bin = { lhs, rhs } }, value_interner::REF_I32);
	f.builder.add_jump(join);
	f.builder.start_block(right);
	Ref right_add = f.builder.add_inst(ir::InstTag.ADD, { .bin = { lhs, rhs } }, value_interner::REF_I32);
	f.builder.add_jump(join);
	f.builder.start_block(join);
	ir::PhiInput[2] inputs = {
		{ .label = left, .value = left_add },
		{ .label = right, .value = right_add },
	};
	Ref result = f.builder.add_phi(inputs[..], value_interner::REF_I32);
	f.builder.add_return(result);
	f.builder.finish_fn("cfg_hoist_identical_add");
	f.run_cfg_hoist_sink();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.ADD) == 1,
		"identical ADDs in both diamond arms should be hoisted and merged");
	Ref merged_add = first_body_tag(decl, ir::InstTag.ADD);
	ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
	assert(cfg.block_of_ref[(sz)merged_add] == block_for_label(&cfg, entry),
		"the merged ADD should be placed in the common predecessor block");
	cfg.free();
	f.free();
}

fn void cfg_hoist_sink_does_not_hoist_sdiv_or_load() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref dividend = f.builder.add_arg(value_interner::REF_I32);
	Ref divisor = f.builder.add_arg(value_interner::REF_I32);
	Ref pointer = f.builder.add_arg(value_interner::REF_PTR);
	f.builder.start_fn();
	Ref left = f.builder.make_label("left");
	Ref right = f.builder.make_label("right");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(condition, left, right);
	f.builder.start_block(left);
	Ref left_div = f.builder.add_inst(ir::InstTag.SDIV, { .bin = { dividend, divisor } }, value_interner::REF_I32);
	Ref left_load = f.builder.add_load(pointer, value_interner::REF_I32);
	f.builder.add_jump(join);
	f.builder.start_block(right);
	Ref right_div = f.builder.add_inst(ir::InstTag.SDIV, { .bin = { dividend, divisor } }, value_interner::REF_I32);
	Ref right_load = f.builder.add_load(pointer, value_interner::REF_I32);
	f.builder.add_jump(join);
	f.builder.start_block(join);
	ir::PhiInput[2] div_inputs = {
		{ .label = left, .value = left_div },
		{ .label = right, .value = right_div },
	};
	ir::PhiInput[2] load_inputs = {
		{ .label = left, .value = left_load },
		{ .label = right, .value = right_load },
	};
	Ref div_result = f.builder.add_phi(div_inputs[..], value_interner::REF_I32);
	f.builder.add_phi(load_inputs[..], value_interner::REF_I32);
	f.builder.add_return(div_result);
	f.builder.finish_fn("cfg_hoist_sdiv");
	f.run_cfg_hoist_sink();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.SDIV) == 2 && has_index(decl.body, left_div) &&
		has_index(decl.body, right_div), "potentially trapping SDIVs must remain in their original arms");
	assert(count_body_tag(decl, ir::InstTag.LOAD) == 2 && has_index(decl.body, left_load) &&
		has_index(decl.body, right_load), "LOADs must remain in their original arms");
	f.free();
}

fn void cfg_hoist_sink_hoists_trailing_adds_through_phi() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref left_value = f.builder.add_arg(value_interner::REF_I32);
	Ref right_value = f.builder.add_arg(value_interner::REF_I32);
	Ref one = f.add_int_constant(1, value_interner::REF_I32);
	f.builder.start_fn();
	Ref entry = f.builder.current_label;
	Ref left = f.builder.make_label("left");
	Ref right = f.builder.make_label("right");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(condition, left, right);
	f.builder.start_block(left);
	Ref left_add = f.builder.add_inst(ir::InstTag.ADD, { .bin = { left_value, one } }, value_interner::REF_I32);
	f.builder.add_jump(join);
	f.builder.start_block(right);
	Ref right_add = f.builder.add_inst(ir::InstTag.ADD, { .bin = { right_value, one } }, value_interner::REF_I32);
	f.builder.add_jump(join);
	f.builder.start_block(join);
	ir::PhiInput[2] inputs = {
		{ .label = left, .value = left_add },
		{ .label = right, .value = right_add },
	};
	Ref result = f.builder.add_phi(inputs[..], value_interner::REF_I32);
	f.builder.add_return(result);
	f.builder.finish_fn("cfg_sink_add");
	f.run_cfg_hoist_sink();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.ADD) == 1,
		"the trailing ADDs should be hoisted and merged at the join");
	Ref merged_add = first_body_tag(decl, ir::InstTag.ADD);
	ir::Inst add = decl.instructions[(sz)merged_add];
	Ref phi_operand = decl.instructions[(sz)add.data.bin.lhs].tag == ir::InstTag.PHI ? add.data.bin.lhs : add.data.bin.rhs;
	assert(decl.instructions[(sz)phi_operand].tag == ir::InstTag.PHI,
		"the single merged ADD should use a PHI operand for the differing arm values");
	ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
	assert(cfg.block_of_ref[(sz)merged_add] == block_for_label(&cfg, join) &&
		cfg.block_of_ref[(sz)phi_operand] == block_for_label(&cfg, join) &&
		cfg.block_of_ref[(sz)phi_operand] != block_for_label(&cfg, entry),
		"the merged ADD and operand PHI should live at the join");
	cfg.free();
	f.free();
}

fn void cfg_hoist_sink_keeps_add_with_an_extra_use_at_join() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref left_value = f.builder.add_arg(value_interner::REF_I32);
	Ref right_value = f.builder.add_arg(value_interner::REF_I32);
	Ref one = f.add_int_constant(1, value_interner::REF_I32);
	f.builder.start_fn();
	Ref left = f.builder.make_label("left");
	Ref right = f.builder.make_label("right");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(condition, left, right);
	f.builder.start_block(left);
	Ref left_add = f.builder.add_inst(ir::InstTag.ADD, { .bin = { left_value, one } }, value_interner::REF_I32);
	f.builder.add_jump(join);
	f.builder.start_block(right);
	Ref right_add = f.builder.add_inst(ir::InstTag.ADD, { .bin = { right_value, one } }, value_interner::REF_I32);
	f.builder.add_jump(join);
	f.builder.start_block(join);
	ir::PhiInput[2] inputs = {
		{ .label = left, .value = left_add },
		{ .label = right, .value = right_add },
	};
	Ref result = f.builder.add_phi(inputs[..], value_interner::REF_I32);
	Ref extra_result = f.builder.add_phi(inputs[..], value_interner::REF_I32);
	Ref combined = f.builder.add_inst(ir::InstTag.ADD, { .bin = { result, extra_result } }, value_interner::REF_I32);
	f.builder.add_return(combined);
	f.builder.finish_fn("cfg_keep_add_extra_use");
	f.run_cfg_hoist_sink();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.ADD) == 3 && has_index(decl.body, left_add) && has_index(decl.body, right_add),
		"arm ADDs with an additional PHI use must remain in their original blocks");
	f.free();
}

fn void gvn_numbers_scalar_expressions_with_exact_float_order() @test
{
	HandIrFixture f;
	f.init();
	Ref a = f.builder.add_arg(value_interner::REF_I32);
	Ref b = f.builder.add_arg(value_interner::REF_I32);
	Ref pointer = f.builder.add_arg(value_interner::REF_PTR);
	Ref fa = f.builder.add_arg(value_interner::REF_F64);
	Ref fb = f.builder.add_arg(value_interner::REF_F64);
	Ref eight = f.add_int_constant(8, value_interner::REF_I64);
	f.builder.start_fn();
	Ref sum_ab = f.builder.add_inst(ir::InstTag.ADD, { .bin = { a, b } }, value_interner::REF_I32);
	Ref sum_ba = f.builder.add_inst(ir::InstTag.ADD, { .bin = { b, a } }, value_interner::REF_I32);
	Ref ptr_a = f.builder.add_inst(ir::InstTag.ADD, { .bin = { pointer, eight } }, value_interner::REF_PTR);
	Ref ptr_b = f.builder.add_inst(ir::InstTag.ADD, { .bin = { pointer, eight } }, value_interner::REF_PTR);
	Ref pointer_equal = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { ptr_a, ptr_b } }, value_interner::REF_I1);
	Ref greater = f.builder.add_inst(ir::InstTag.CMP_SGT, { .bin = { a, b } }, value_interner::REF_I1);
	Ref inverse_less = f.builder.add_inst(ir::InstTag.CMP_SLT, { .bin = { b, a } }, value_interner::REF_I1);
	Ref equal_ab = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { a, b } }, value_interner::REF_I1);
	Ref equal_ab_again = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { a, b } }, value_interner::REF_I1);
	Ref float_ab = f.builder.add_inst(ir::InstTag.FADD, { .bin = { fa, fb } }, value_interner::REF_F64);
	Ref float_ab_again = f.builder.add_inst(ir::InstTag.FADD, { .bin = { fa, fb } }, value_interner::REF_F64);
	Ref float_ba = f.builder.add_inst(ir::InstTag.FADD, { .bin = { fb, fa } }, value_interner::REF_F64);
	Ref float_same = f.builder.add_inst(ir::InstTag.FCMP_OEQ, { .bin = { float_ab, float_ab_again } }, value_interner::REF_I1);
	Ref float_swapped = f.builder.add_inst(ir::InstTag.FCMP_OLT, { .bin = { float_ab, float_ba } }, value_interner::REF_I1);
	Ref compare = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { greater, inverse_less } }, value_interner::REF_I1);
	Ref result = f.builder.add_inst(ir::InstTag.BIT_XOR, { .bin = { pointer_equal, compare } }, value_interner::REF_I1);
	result = f.builder.add_inst(ir::InstTag.BIT_XOR, { .bin = { result, float_same } }, value_interner::REF_I1);
	result = f.builder.add_inst(ir::InstTag.BIT_XOR, { .bin = { result, float_swapped } }, value_interner::REF_I1);
	result = f.builder.add_inst(ir::InstTag.BIT_XOR, { .bin = { result, equal_ab } }, value_interner::REF_I1);
	result = f.builder.add_inst(ir::InstTag.BIT_XOR, { .bin = { result, equal_ab_again } }, value_interner::REF_I1);
	f.builder.add_return(result);
	f.builder.finish_fn("gvn_scalar_exactness");
	f.run_gvn();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.ADD) == 2,
		"GVN should merge commuted integer ADD and duplicate pointer ADD expressions");
	assert(has_index(decl.body, sum_ab) && !has_index(decl.body, sum_ba),
		"commuted ADDs in one dominating block should share a value number");
	assert(count_body_tag(decl, ir::InstTag.CMP_SGT) + count_body_tag(decl, ir::InstTag.CMP_SLT) == 1,
		"swapping operands and predicate should canonicalize signed greater-than and less-than");
	assert(count_body_tag(decl, ir::InstTag.CMP_EQ) == 3 && has_index(decl.body, equal_ab) &&
		!has_index(decl.body, equal_ab_again), "identical comparisons should share a value number");
	assert(count_body_tag(decl, ir::InstTag.FADD) == 2,
		"same-order FADD should merge while reversed operands remain distinct");
	assert(has_index(decl.body, float_ba), "reversed FADD must remain available as a distinct result");
	f.free();
}

fn void gvn_merges_congruent_phis_in_one_block() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref a = f.builder.add_arg(value_interner::REF_I32);
	Ref b = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref left = f.builder.make_label("left");
	Ref right = f.builder.make_label("right");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(condition, left, right);
	f.builder.start_block(left);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(right);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(join);
	ir::PhiInput[2] inputs = {
		{ .label = left, .value = a },
		{ .label = right, .value = b },
	};
	Ref first_phi = f.builder.add_phi(inputs[..], value_interner::REF_I32);
	Ref second_phi = f.builder.add_phi(inputs[..], value_interner::REF_I32);
	Ref difference = f.builder.add_inst(ir::InstTag.SUB, { .bin = { first_phi, second_phi } }, value_interner::REF_I32);
	f.builder.add_return(difference);
	f.builder.finish_fn("gvn_parallel_phis");
	f.run_gvn();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.PHI) == 1, "equivalent PHIs in one block should share a value number");
	Ref result = return_value(decl);
	assert(result != ir::NONE && decl.instructions[(sz)result].tag == ir::InstTag.SUB &&
		decl.instructions[(sz)result].data.bin.lhs == decl.instructions[(sz)result].data.bin.rhs,
		"uses of the removed congruent PHI should be rewritten to the surviving PHI");
	f.free();
}

fn void gvn_keeps_sibling_diamond_phis_without_a_dominating_leader() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref a = f.builder.add_arg(value_interner::REF_I32);
	Ref b = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref left = f.builder.make_label("left");
	Ref right = f.builder.make_label("right");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(condition, left, right);
	f.builder.start_block(left);
	Ref left_sum = f.builder.add_inst(ir::InstTag.ADD, { .bin = { b, a } }, value_interner::REF_I32);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(right);
	Ref right_sum = f.builder.add_inst(ir::InstTag.ADD, { .bin = { a, b } }, value_interner::REF_I32);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(join);
	ir::PhiInput[2] inputs = {
		{ .label = left, .value = left_sum },
		{ .label = right, .value = right_sum },
	};
	Ref merged = f.builder.add_phi(inputs[..], value_interner::REF_I32);
	Ref recomputed = f.builder.add_inst(ir::InstTag.ADD, { .bin = { a, b } }, value_interner::REF_I32);
	Ref result = f.builder.add_inst(ir::InstTag.SUB, { .bin = { merged, recomputed } }, value_interner::REF_I32);
	f.builder.add_return(result);
	f.builder.finish_fn("gvn_diamond");
	f.run_gvn();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.ADD) == 2 && count_body_tag(decl, ir::InstTag.PHI) == 1,
		"sibling ADDs need a join PHI because neither ADD dominates the join");
	assert(has_index(decl.body, left_sum) && has_index(decl.body, right_sum) &&
		has_index(decl.body, merged) && !has_index(decl.body, recomputed),
		"the edge-specific PHI stays while the post-join recomputation reuses its value");
	ir::Inst phi = decl.instructions[(sz)merged];
	assert(phi.tag == ir::InstTag.PHI && phi.data.phi[0].label == left &&
		phi.data.phi[0].value == left_sum && phi.data.phi[1].label == right &&
		phi.data.phi[1].value == right_sum,
		"the surviving PHI must preserve the value selected on each incoming edge");
	Ref returned = return_value(decl);
	assert(returned == result && decl.instructions[(sz)result].tag == ir::InstTag.SUB &&
		decl.instructions[(sz)result].data.bin.lhs == merged &&
		decl.instructions[(sz)result].data.bin.rhs == merged,
		"uses of the join recomputation should resolve to the dominating PHI");
	f.free();
}

fn void gvn_tracks_only_safe_loads_across_joins() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref external_pointer = f.builder.add_arg(value_interner::REF_PTR);
	f.builder.start_fn();
	Ref slot = f.builder.add_alloc(4, 4);
	Ref before = f.builder.add_load(slot, value_interner::REF_I32);
	Ref left = f.builder.make_label("left");
	Ref right = f.builder.make_label("right");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(condition, left, right);
	f.builder.start_block(left);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(right);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(join);
	Ref after_join = f.builder.add_load(slot, value_interner::REF_I32);
	Ref external_a = f.builder.add_load(external_pointer, value_interner::REF_I32);
	Ref external_b = f.builder.add_load(external_pointer, value_interner::REF_I32);
	Ref sum0 = f.builder.add_inst(ir::InstTag.ADD, { .bin = { before, after_join } }, value_interner::REF_I32);
	Ref sum1 = f.builder.add_inst(ir::InstTag.ADD, { .bin = { external_a, external_b } }, value_interner::REF_I32);
	Ref result = f.builder.add_inst(ir::InstTag.ADD, { .bin = { sum0, sum1 } }, value_interner::REF_I32);
	f.builder.add_return(result);
	f.builder.finish_fn("gvn_load_join");
	f.run_gvn();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.LOAD) == 3,
		"a safe alloca load should be CSE'd at the join while ARG pointer loads remain distinct");
	assert(return_value(decl) == result && decl.instructions[(sz)result].tag == ir::InstTag.ADD,
		"load CSE should rewrite operands without removing the returned expression");
	f.free();
}

fn void gvn_forwards_loads_from_the_current_store_version() @test
{
	HandIrFixture f;
	f.init();
	Ref first_value = f.builder.add_arg(value_interner::REF_I32);
	Ref last_value = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref slot = f.builder.add_alloc(4, 4);
	f.builder.add_store(slot, first_value);
	Ref first_load = f.builder.add_load(slot, value_interner::REF_I32);
	Ref second_load = f.builder.add_load(slot, value_interner::REF_I32);
	f.builder.add_store(slot, last_value);
	Ref after_store = f.builder.add_load(slot, value_interner::REF_I32);
	Ref first_sum = f.builder.add_inst(ir::InstTag.ADD, { .bin = { first_load, second_load } }, value_interner::REF_I32);
	Ref result = f.builder.add_inst(ir::InstTag.ADD, { .bin = { first_sum, after_store } }, value_interner::REF_I32);
	f.builder.add_return(result);
	f.builder.finish_fn("gvn_store_versions");
	f.run_gvn();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.LOAD) == 0,
		"loads should forward from the latest store to their tracked alloca");
	assert(decl.instructions[(sz)first_sum].data.bin.lhs == first_value &&
		decl.instructions[(sz)first_sum].data.bin.rhs == first_value,
		"repeated loads before a store should share the first stored value");
	assert(decl.instructions[(sz)result].data.bin.rhs == last_value,
		"a later store must give following loads a distinct memory version");
	f.free();
}

fn void gvn_preserves_loads_after_a_conflicting_store_and_volatile_accesses() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref first = f.builder.add_arg(value_interner::REF_I32);
	Ref second = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref slot = f.builder.add_alloc(8, 8);
	Ref before = f.builder.add_load(slot, value_interner::REF_I32);
	Ref left = f.builder.make_label("left");
	Ref right = f.builder.make_label("right");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(condition, left, right);
	f.builder.start_block(left);
	f.builder.add_store(slot, first);
	Ref left_div = f.builder.add_inst(ir::InstTag.SDIV, { .bin = { first, second } }, value_interner::REF_I32);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(right);
	Ref right_div = f.builder.add_inst(ir::InstTag.SDIV, { .bin = { first, second } }, value_interner::REF_I32);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(join);
	ir::PhiInput[2] div_inputs = {
		{ .label = left, .value = left_div },
		{ .label = right, .value = right_div },
	};
	Ref div_phi = f.builder.add_phi(div_inputs[..], value_interner::REF_I32);
	Ref joined = f.builder.add_load(slot, value_interner::REF_I32);
	Ref wrong_type = f.builder.add_load(slot, value_interner::REF_I64);
	Ref sum = f.builder.add_inst(ir::InstTag.ADD, { .bin = { before, joined } }, value_interner::REF_I32);
	Ref result = f.builder.add_inst(ir::InstTag.ADD, { .bin = { sum, div_phi } }, value_interner::REF_I32);
	f.builder.add_return(result);
	f.builder.finish_fn("gvn_load_conflicting_store");
	f.run_gvn();
	ir::Decl* decl = &f.graph.decls[0];
	assert(has_index(decl.body, before) && has_index(decl.body, joined) && has_index(decl.body, wrong_type),
		"a join memory phi and a type-mismatched load must not be replaced by an earlier load");
	assert(count_body_tag(decl, ir::InstTag.LOAD) == 3, "conflicting and type-mismatched loads must remain");
	assert(count_body_tag(decl, ir::InstTag.SDIV) == 2,
		"identical divisions in sibling arms must not merge without a dominating leader");
	f.free();

	HandIrFixture g;
	g.init();
	Ref volatile_value = g.builder.add_arg(value_interner::REF_I32);
	g.builder.start_fn();
	Ref volatile_slot = g.builder.add_alloc(4, 4, true);
	g.builder.add_store(volatile_slot, volatile_value);
	Ref volatile_a = g.builder.add_load(volatile_slot, value_interner::REF_I32, true);
	Ref volatile_b = g.builder.add_load(volatile_slot, value_interner::REF_I32, true);
	Ref volatile_sum = g.builder.add_inst(ir::InstTag.ADD, { .bin = { volatile_a, volatile_b } }, value_interner::REF_I32);
	g.builder.add_return(volatile_sum);
	g.builder.finish_fn("gvn_volatile_load");
	g.run_gvn();
	assert(count_body_tag(&g.graph.decls[0], ir::InstTag.LOAD) == 2,
		"volatile allocation accesses must not enter load value numbering");
	g.free();
}

fn void gvn_invalidates_load_facts_for_summarized_call_effects() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int read_pointer(const int *p) { return *p; }\n"
		"static void write_pointer(int *p) { *p = 9; }\n"
		"int reader_call(int seed) { int value = seed; int before = value; "
		"(void)read_pointer(&value); int after = value; return before + after; }\n"
		"int writer_call(int seed) { int value = seed; int before = value; "
		"write_pointer(&value); int after = value; return before + after; }\n");
	f.run_mem2reg();
	ir_opt::infer_function_attrs(&f.graph);
	ir::Decl* reader = find_function(&f.graph, "read_pointer");
	ir::Decl* writer = find_function(&f.graph, "write_pointer");
	assert((reader.attrs.arg_nocapture & 1) != 0 && (reader.attrs.arg_noread & 1) == 0 &&
		(reader.attrs.arg_nowrite & 1) != 0,
		"the reader call must expose a noncapturing read effect for its argument");
	assert((writer.attrs.arg_nocapture & 1) != 0 && (writer.attrs.arg_noread & 1) != 0 &&
		(writer.attrs.arg_nowrite & 1) == 0,
		"the writer call must expose a noncapturing write effect for its argument");
	foreach (&decl : f.graph.decls) ir_opt::gvn(&f.graph, decl);
	f.verify_graph();
	ir::Decl* reader_caller = find_function(&f.graph, "reader_call");
	ir::Decl* writer_caller = find_function(&f.graph, "writer_call");
	assert(count_body_tag(reader_caller, ir::InstTag.LOAD) == 1,
		"a summarized read effect must invalidate the passed root's earlier load fact");
	assert(count_body_tag(writer_caller, ir::InstTag.LOAD) == 1,
		"a summarized write effect must invalidate the passed root's earlier load fact");
	f.free();
}

fn void gvn_merges_congruent_loop_induction_phis() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref zero = f.add_int_constant(0, value_interner::REF_I32);
	Ref one = f.add_int_constant(1, value_interner::REF_I32);
	f.builder.start_fn();
	Ref entry = f.builder.current_label;
	Ref header = f.builder.make_label("header");
	Ref body = f.builder.make_label("body");
	Ref exit = f.builder.make_label("exit");
	f.builder.add_inst(ir::InstTag.JMP, { .ref = header }, value_interner::REF_NORETURN);
	f.builder.start_block(header);
	ir::PhiInput[2] i_inputs = {
		{ .label = entry, .value = zero },
		{ .label = body, .value = zero },
	};
	ir::PhiInput[2] j_inputs = {
		{ .label = entry, .value = zero },
		{ .label = body, .value = zero },
	};
	Ref i_phi = f.builder.add_phi(i_inputs[..], value_interner::REF_I32);
	Ref j_phi = f.builder.add_phi(j_inputs[..], value_interner::REF_I32);
	f.builder.add_branch(condition, body, exit);
	f.builder.start_block(body);
	Ref i_next = f.builder.add_inst(ir::InstTag.ADD, { .bin = { i_phi, one } }, value_interner::REF_I32);
	Ref j_next = f.builder.add_inst(ir::InstTag.ADD, { .bin = { j_phi, one } }, value_interner::REF_I32);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = header }, value_interner::REF_NORETURN);
	f.builder.start_block(exit);
	Ref result = f.builder.add_inst(ir::InstTag.ADD, { .bin = { i_phi, j_phi } }, value_interner::REF_I32);
	f.builder.add_return(result);
	f.builder.finish_fn("gvn_loop_inductions");
	f.finish();
	ir_opt::DeclEditor editor;
	editor.begin(&f.graph.decls[0]);
	editor.insts.entries[(sz)i_phi].data.phi[1].value = i_next;
	editor.insts.entries[(sz)j_phi].data.phi[1].value = j_next;
	editor.commit();
	f.run_gvn();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.PHI) == 1,
		"congruent induction PHIs should converge to one value number across RPO iterations");
	assert(count_body_tag(decl, ir::InstTag.ADD) == 2,
		"the two induction updates should share one ADD while the exit sum remains");
	f.free();
}

fn void gvn_reuses_loads_through_a_loop_without_stores() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref slot = f.builder.add_alloc(4, 4);
	Ref before = f.builder.add_load(slot, value_interner::REF_I32);
	Ref entry = f.builder.current_label;
	Ref header = f.builder.make_label("header");
	Ref body = f.builder.make_label("body");
	Ref exit = f.builder.make_label("exit");
	f.builder.add_inst(ir::InstTag.JMP, { .ref = header }, value_interner::REF_NORETURN);
	f.builder.start_block(header);
	f.builder.add_branch(condition, body, exit);
	f.builder.start_block(body);
	Ref inside = f.builder.add_load(slot, value_interner::REF_I32);
	Ref use = f.builder.add_inst(ir::InstTag.ADD, { .bin = { before, inside } }, value_interner::REF_I32);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = header }, value_interner::REF_NORETURN);
	f.builder.start_block(exit);
	f.builder.add_return(before);
	f.builder.finish_fn("gvn_loop_load");
	f.run_gvn();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.LOAD) == 1 && !has_index(decl.body, inside),
		"a loop with no store to the tracked alloca should reuse the dominating load");
	assert(has_index(decl.body, use), "the loop's load consumer should remain after operand rewriting");
	f.free();
}

fn void mem_opt_forwards_stores_cses_loads_and_removes_dead_accesses() @test
{
	HandIrFixture f;
	f.init();
	Ref value = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref slot = f.builder.add_alloc(4, 4);
	f.builder.add_store(slot, value);
	Ref first_load = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
	Ref second_load = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
	Ref sum = f.builder.add_inst(ir::InstTag.ADD, { .bin = { first_load, second_load } }, value_interner::REF_I32);
	f.builder.add_return(sum);
	f.builder.finish_fn("mem_opt_forward_cse");
	f.run_mem_opt();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.LOAD) == 0, "both loads should forward from the store");
	assert(count_body_tag(decl, ir::InstTag.STORE) == 0, "the forwarded store should become dead");
	Ref result = return_value(decl);
	assert(result != ir::NONE && decl.instructions[(sz)result].tag == ir::InstTag.ADD,
		"the use of both forwarded loads should remain as an addition");
	assert(decl.instructions[(sz)result].data.bin.lhs == value && decl.instructions[(sz)result].data.bin.rhs == value,
		"loads of one unchanged location should both use the stored value");
	f.free();
}

fn void mem_opt_removes_overwritten_store() @test
{
	HandIrFixture f;
	f.init();
	Ref first_value = f.builder.add_arg(value_interner::REF_I32);
	Ref last_value = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref slot = f.builder.add_alloc(4, 4);
	f.builder.add_store(slot, first_value);
	f.builder.add_store(slot, last_value);
	Ref loaded = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
	f.builder.add_return(loaded);
	f.builder.finish_fn("mem_opt_dead_store");
	f.run_mem_opt();
	ir::Decl* decl = &f.graph.decls[0];
	assert(return_value(decl) == last_value, "the load should forward the most recent stored value");
	assert(count_body_tag(decl, ir::InstTag.LOAD) == 0, "the forwarded load should be removed");
	assert(count_body_tag(decl, ir::InstTag.STORE) == 0, "stores to the now-unobserved local should be removed");
	f.free();
}

fn void mem_opt_invalidates_arg_loads_after_store() @test
{
	HandIrFixture f;
	f.init();
	Ref pointer = f.builder.add_arg(value_interner::REF_PTR);
	Ref new_value = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref before = f.builder.add_inst(ir::InstTag.LOAD, { .ref = pointer }, value_interner::REF_I32);
	f.builder.add_store(pointer, new_value);
	Ref after = f.builder.add_inst(ir::InstTag.LOAD, { .ref = pointer }, value_interner::REF_I32);
	Ref sum = f.builder.add_inst(ir::InstTag.ADD, { .bin = { before, after } }, value_interner::REF_I32);
	f.builder.add_return(sum);
	f.builder.finish_fn("mem_opt_arg_store_invalidation");
	f.run_mem_opt();
	ir::Decl* decl = &f.graph.decls[0];
	Ref result = return_value(decl);
	assert(result != ir::NONE && decl.instructions[(sz)result].tag == ir::InstTag.ADD,
		"both observations around the store should remain distinct operands");
	Ref after_value = decl.instructions[(sz)result].data.bin.rhs;
	assert(decl.instructions[(sz)after_value].tag == ir::InstTag.LOAD,
		"a store through an ARG pointer must invalidate a cached load");
	assert(count_body_tag(decl, ir::InstTag.LOAD) == 2,
		"loads across a potentially aliasing ARG store must not be commoned");
	f.free();
}

fn void mem_opt_preserves_repeated_arg_loads_without_intervening_writes() @test
{
	HandIrFixture f;
	f.init();
	Ref pointer = f.builder.add_arg(value_interner::REF_PTR);
	f.builder.start_fn();
	Ref first = f.builder.add_inst(ir::InstTag.LOAD, { .ref = pointer }, value_interner::REF_I32);
	Ref second = f.builder.add_inst(ir::InstTag.LOAD, { .ref = pointer }, value_interner::REF_I32);
	Ref sum = f.builder.add_inst(ir::InstTag.ADD, { .bin = { first, second } }, value_interner::REF_I32);
	f.builder.add_return(sum);
	f.builder.finish_fn("mem_opt_arg_load_cse");
	f.run_mem_opt();
	ir::Decl* decl = &f.graph.decls[0];
	Ref result = return_value(decl);
	assert(result != ir::NONE && decl.instructions[(sz)result].tag == ir::InstTag.ADD,
		"the repeated-load use should remain as an addition");
	assert(decl.instructions[(sz)result].data.bin.lhs == first &&
		decl.instructions[(sz)result].data.bin.rhs == second && first != second,
		"loads through an ARG pointer may be volatile and must remain distinct");
	assert(count_body_tag(decl, ir::InstTag.LOAD) == 2, "loads through an ARG pointer must not be commoned");
	f.free();
}

fn void mem_opt_keeps_disjoint_allocation_facts() @test
{
	HandIrFixture f;
	f.init();
	Ref left_value = f.builder.add_arg(value_interner::REF_I32);
	Ref right_value = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref left = f.builder.add_alloc(4, 4);
	Ref right = f.builder.add_alloc(4, 4);
	f.builder.add_store(left, left_value);
	f.builder.add_store(right, right_value);
	Ref loaded = f.builder.add_inst(ir::InstTag.LOAD, { .ref = left }, value_interner::REF_I32);
	f.builder.add_return(loaded);
	f.builder.finish_fn("mem_opt_disjoint_allocations");
	f.run_mem_opt();
	assert(return_value(&f.graph.decls[0]) == left_value,
		"a store to a distinct nonescaping allocation must not invalidate the left allocation's value");
	f.free();
}

fn void mem_opt_inherits_stored_value_through_cfg_and_keeps_join_conflict() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref value_a = f.builder.add_arg(value_interner::REF_I32);
	Ref value_b = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref slot = f.builder.add_alloc(4, 4);
	f.builder.add_store(slot, value_a);
	Ref left = f.builder.make_label("left");
	Ref right = f.builder.make_label("right");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(condition, left, right);
	f.builder.start_block(left);
	f.builder.add_jump(join);
	f.builder.start_block(right);
	f.builder.add_jump(join);
	f.builder.start_block(join);
	Ref inherited_load = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
	f.builder.add_return(inherited_load);
	f.builder.finish_fn("mem_opt_cfg_inherit");
	f.run_mem_opt();
	assert(return_value(&f.graph.decls[0]) == inherited_load && has_index(f.graph.decls[0].body, inherited_load),
		"a join with multiple predecessors must start with empty memory state");
	f.free();

	HandIrFixture g;
	g.init();
	condition = g.builder.add_arg(value_interner::REF_I1);
	value_a = g.builder.add_arg(value_interner::REF_I32);
	value_b = g.builder.add_arg(value_interner::REF_I32);
	g.builder.start_fn();
	slot = g.builder.add_alloc(4, 4);
	left = g.builder.make_label("left");
	right = g.builder.make_label("right");
	join = g.builder.make_label("join");
	g.builder.add_branch(condition, left, right);
	g.builder.start_block(left);
	g.builder.add_store(slot, value_a);
	g.builder.add_jump(join);
	g.builder.start_block(right);
	g.builder.add_store(slot, value_b);
	g.builder.add_jump(join);
	g.builder.start_block(join);
	Ref joined_load = g.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
	g.builder.add_return(joined_load);
	g.builder.finish_fn("mem_opt_cfg_join");
	g.run_mem_opt();
	ir::Decl* joined = &g.graph.decls[0];
	assert(return_value(joined) == joined_load && has_index(joined.body, joined_load),
		"different values stored on incoming paths must not be replaced by one path's value");
	g.free();
}

fn void mem_opt_preserves_volatile_escaped_and_mismatched_accesses() @test
{
	HandIrFixture f;
	f.init();
	Ref value = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref slot = f.builder.add_alloc(4, 4, true);
	f.builder.add_store(slot, value);
	Ref volatile_load = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
	f.builder.add_return(volatile_load);
	f.builder.finish_fn("mem_opt_volatile");
	f.run_mem_opt();
	ir::Decl* decl = &f.graph.decls[0];
	assert(has_index(decl.body, slot) && has_index(decl.body, volatile_load),
		"volatile accesses must not be forwarded or removed");
	assert(count_body_tag(decl, ir::InstTag.STORE) == 1 && count_body_tag(decl, ir::InstTag.LOAD) == 1,
		"volatile loads and stores remain observable");
	f.free();

	HandIrFixture g;
	g.init();
	value = g.builder.add_arg(value_interner::REF_I32);
	g.builder.start_fn();
	slot = g.builder.add_alloc(4, 4);
	g.builder.add_store(slot, value);
	Ref observer = g.builder.add_symbol("observe", value_interner::REF_PTR);
	Ref[1] args = { slot };
	g.builder.add_call(observer, args[..], value_interner::REF_VOID);
	Ref escaped_load = g.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
	g.builder.add_return(escaped_load);
	g.builder.finish_fn("mem_opt_escaped");
	g.run_mem_opt();
	decl = &g.graph.decls[0];
	assert(has_index(decl.body, escaped_load) && return_value(decl) == escaped_load,
		"an unknown call receiving an allocation address must invalidate its stored value");
	g.free();

	HandIrFixture h;
	h.init();
	Ref narrow_value = h.builder.add_arg(value_interner::REF_I32);
	h.builder.start_fn();
	slot = h.builder.add_alloc(8, 8);
	h.builder.add_store(slot, narrow_value);
	Ref mismatched_load = h.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I64);
	h.builder.add_return(mismatched_load);
	h.builder.finish_fn("mem_opt_type_mismatch");
	h.run_mem_opt();
	decl = &h.graph.decls[0];
	assert(has_index(decl.body, slot) && has_index(decl.body, mismatched_load),
		"an access with a different type must not forward an incompatible stored value");
	assert(count_body_tag(decl, ir::InstTag.STORE) == 1 && count_body_tag(decl, ir::InstTag.LOAD) == 1,
		"type-mismatched memory operations should remain intact");
	h.free();
}

fn ir::Decl* find_function(ir::Ir* graph, String name)
{
	foreach (&decl : graph.decls) if (decl.name == name) return decl;
	unreachable("missing IR test function '%s'", name);
}

fn ir::Decl* find_decl(ir::Ir* graph, String name)
{
	foreach (&decl : graph.decls) if (decl.name == name) return decl;
	return null;
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
	bool matches = value.tag == ir::InstTag.CONSTANT && value.data.constant == expected_ref;
	if (value.tag == ir::InstTag.CONSTANT && value.ty == value_interner::REF_I1)
	{
		if (expected == 0) matches |= value.data.constant == value_interner::REF_ZERO;
		if (expected == 1) matches |= value.data.constant == value_interner::REF_ONE;
	}
	assert(matches,
		"%s should return integer constant %d", context, expected);
}

fn bool returns_argument(ir::Decl* decl)
{
	ir::Ref returned = return_value(decl);
	return returned != ir::NONE && decl.instructions[(sz)returned].tag == ir::InstTag.ARG;
}

fn void assert_returns_bin_with_constant(ir::Decl* decl, ir::InstTag tag,
	value_interner::Interner* interner, long expected, String context)
{
	ir::Ref returned = return_value(decl);
	assert(returned != ir::NONE && decl.instructions[(sz)returned].tag == tag,
		"%s should return a %s, found %s", context, tag.name,
		returned == ir::NONE ? "NONE" : decl.instructions[(sz)returned].tag.name);
	ir::Inst value = decl.instructions[(sz)returned];
	assert(is_int_constant(decl, value.data.bin.lhs, interner, expected) ||
		is_int_constant(decl, value.data.bin.rhs, interner, expected),
		"%s should have reassociated constant %d", context, expected);
}

fn void inst_combine_reassociates_integer_cast_chains_and_offsets() @test
{
	HandIrFixture f;
	f.init();
	Ref zext_arg = f.builder.add_arg(value_interner::REF_I8);
	f.builder.start_fn();
	Ref zext_mid = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = zext_arg }, value_interner::REF_I16);
	Ref zext_outer = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = zext_mid }, value_interner::REF_I32);
	f.builder.add_return(zext_outer);
	f.builder.finish_fn("zext_chain");

	Ref sext_arg = f.builder.add_arg(value_interner::REF_I8);
	f.builder.start_fn();
	Ref sext_mid = f.builder.add_inst(ir::InstTag.SEXT, { .ref = sext_arg }, value_interner::REF_I16);
	Ref sext_outer = f.builder.add_inst(ir::InstTag.SEXT, { .ref = sext_mid }, value_interner::REF_I32);
	f.builder.add_return(sext_outer);
	f.builder.finish_fn("sext_chain");

	Ref trunc_arg = f.builder.add_arg(value_interner::REF_I64);
	f.builder.start_fn();
	Ref trunc_mid = f.builder.add_inst(ir::InstTag.TRUNC, { .ref = trunc_arg }, value_interner::REF_I32);
	Ref trunc_outer = f.builder.add_inst(ir::InstTag.TRUNC, { .ref = trunc_mid }, value_interner::REF_I8);
	f.builder.add_return(trunc_outer);
	f.builder.finish_fn("trunc_chain");

	Ref trunc_zext_arg = f.builder.add_arg(value_interner::REF_I8);
	f.builder.start_fn();
	Ref widened = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = trunc_zext_arg }, value_interner::REF_I32);
	Ref narrowed = f.builder.add_inst(ir::InstTag.TRUNC, { .ref = widened }, value_interner::REF_I8);
	f.builder.add_return(narrowed);
	f.builder.finish_fn("trunc_zext_roundtrip");

	Ref trunc_sext_arg = f.builder.add_arg(value_interner::REF_I8);
	f.builder.start_fn();
	Ref signed_widened = f.builder.add_inst(ir::InstTag.SEXT, { .ref = trunc_sext_arg }, value_interner::REF_I32);
	Ref signed_narrowed = f.builder.add_inst(ir::InstTag.TRUNC, { .ref = signed_widened }, value_interner::REF_I8);
	f.builder.add_return(signed_narrowed);
	f.builder.finish_fn("trunc_sext_roundtrip");

	Ref trunc_zext_narrow_arg = f.builder.add_arg(value_interner::REF_I16);
	f.builder.start_fn();
	Ref trunc_zext_narrow_wide = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = trunc_zext_narrow_arg }, value_interner::REF_I32);
	Ref trunc_zext_narrow = f.builder.add_inst(ir::InstTag.TRUNC, { .ref = trunc_zext_narrow_wide }, value_interner::REF_I8);
	f.builder.add_return(trunc_zext_narrow);
	f.builder.finish_fn("trunc_zext_narrow");

	Ref trunc_zext_widen_arg = f.builder.add_arg(value_interner::REF_I8);
	f.builder.start_fn();
	Ref trunc_zext_widen_wide = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = trunc_zext_widen_arg }, value_interner::REF_I32);
	Ref trunc_zext_widen = f.builder.add_inst(ir::InstTag.TRUNC, { .ref = trunc_zext_widen_wide }, value_interner::REF_I16);
	f.builder.add_return(trunc_zext_widen);
	f.builder.finish_fn("trunc_zext_widen");

	Ref trunc_sext_narrow_arg = f.builder.add_arg(value_interner::REF_I16);
	f.builder.start_fn();
	Ref trunc_sext_narrow_wide = f.builder.add_inst(ir::InstTag.SEXT, { .ref = trunc_sext_narrow_arg }, value_interner::REF_I32);
	Ref trunc_sext_narrow = f.builder.add_inst(ir::InstTag.TRUNC, { .ref = trunc_sext_narrow_wide }, value_interner::REF_I8);
	f.builder.add_return(trunc_sext_narrow);
	f.builder.finish_fn("trunc_sext_narrow");

	Ref trunc_sext_widen_arg = f.builder.add_arg(value_interner::REF_I8);
	f.builder.start_fn();
	Ref trunc_sext_widen_wide = f.builder.add_inst(ir::InstTag.SEXT, { .ref = trunc_sext_widen_arg }, value_interner::REF_I32);
	Ref trunc_sext_widen = f.builder.add_inst(ir::InstTag.TRUNC, { .ref = trunc_sext_widen_wide }, value_interner::REF_I16);
	f.builder.add_return(trunc_sext_widen);
	f.builder.finish_fn("trunc_sext_widen");

	Ref one_bit_arg = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref one_bit_zext = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = one_bit_arg }, value_interner::REF_I16);
	Ref one_bit_sext = f.builder.add_inst(ir::InstTag.SEXT, { .ref = one_bit_zext }, value_interner::REF_I32);
	f.builder.add_return(one_bit_sext);
	f.builder.finish_fn("sext_zext_i1");

	Ref add_arg = f.builder.add_arg(value_interner::REF_I8);
	Ref add_a = f.add_int_constant(200, value_interner::REF_I8);
	Ref add_b = f.add_int_constant(100, value_interner::REF_I8);
	f.builder.start_fn();
	Ref add_inner = f.builder.add_inst(ir::InstTag.ADD, { .bin = { add_arg, add_a } }, value_interner::REF_I8);
	Ref add_outer = f.builder.add_inst(ir::InstTag.ADD, { .bin = { add_inner, add_b } }, value_interner::REF_I8);
	f.builder.add_return(add_outer);
	f.builder.finish_fn("add_wrap_reassociate");

	Ref sub_arg = f.builder.add_arg(value_interner::REF_I32);
	Ref sub_a = f.add_int_constant(3, value_interner::REF_I32);
	Ref sub_b = f.add_int_constant(5, value_interner::REF_I32);
	f.builder.start_fn();
	Ref sub_inner = f.builder.add_inst(ir::InstTag.SUB, { .bin = { sub_arg, sub_a } }, value_interner::REF_I32);
	Ref sub_outer = f.builder.add_inst(ir::InstTag.SUB, { .bin = { sub_inner, sub_b } }, value_interner::REF_I32);
	f.builder.add_return(sub_outer);
	f.builder.finish_fn("sub_reassociate");
	f.run_o1();

	ir::Ref returned = return_value(&f.graph.decls[0]);
	assert(f.graph.decls[0].instructions[(sz)returned].tag == ir::InstTag.ZEXT &&
		f.graph.decls[0].instructions[(sz)returned].data.ref == zext_arg &&
		f.graph.decls[0].instructions[(sz)returned].ty == value_interner::REF_I32,
		"zext(zext(i8)) should become one zext from i8 to i32");
	returned = return_value(&f.graph.decls[1]);
	assert(f.graph.decls[1].instructions[(sz)returned].tag == ir::InstTag.SEXT &&
		f.graph.decls[1].instructions[(sz)returned].data.ref == sext_arg &&
		f.graph.decls[1].instructions[(sz)returned].ty == value_interner::REF_I32,
		"sext(sext(i8)) should become one sext from i8 to i32");
	returned = return_value(&f.graph.decls[2]);
	assert(f.graph.decls[2].instructions[(sz)returned].tag == ir::InstTag.TRUNC &&
		f.graph.decls[2].instructions[(sz)returned].data.ref == trunc_arg &&
		f.graph.decls[2].instructions[(sz)returned].ty == value_interner::REF_I8,
		"trunc(trunc(i64)) should become one trunc from i64 to i8");
	assert(return_value(&f.graph.decls[3]) == trunc_zext_arg, "trunc(zext(x)) roundtrip should become x");
	assert(return_value(&f.graph.decls[4]) == trunc_sext_arg, "trunc(sext(x)) roundtrip should become x");
	returned = return_value(&f.graph.decls[5]);
	assert(f.graph.decls[5].instructions[(sz)returned].tag == ir::InstTag.TRUNC &&
		f.graph.decls[5].instructions[(sz)returned].data.ref == trunc_zext_narrow_arg &&
		f.graph.decls[5].instructions[(sz)returned].ty == value_interner::REF_I8,
		"trunc(zext(i16 to i32), i8) should become trunc(i16 to i8)");
	returned = return_value(&f.graph.decls[6]);
	assert(f.graph.decls[6].instructions[(sz)returned].tag == ir::InstTag.ZEXT &&
		f.graph.decls[6].instructions[(sz)returned].data.ref == trunc_zext_widen_arg &&
		f.graph.decls[6].instructions[(sz)returned].ty == value_interner::REF_I16,
		"trunc(zext(i8 to i32), i16) should become zext(i8 to i16)");
	returned = return_value(&f.graph.decls[7]);
	assert(f.graph.decls[7].instructions[(sz)returned].tag == ir::InstTag.TRUNC &&
		f.graph.decls[7].instructions[(sz)returned].data.ref == trunc_sext_narrow_arg &&
		f.graph.decls[7].instructions[(sz)returned].ty == value_interner::REF_I8,
		"trunc(sext(i16 to i32), i8) should become trunc(i16 to i8)");
	returned = return_value(&f.graph.decls[8]);
	assert(f.graph.decls[8].instructions[(sz)returned].tag == ir::InstTag.SEXT &&
		f.graph.decls[8].instructions[(sz)returned].data.ref == trunc_sext_widen_arg &&
		f.graph.decls[8].instructions[(sz)returned].ty == value_interner::REF_I16,
		"trunc(sext(i8 to i32), i16) should become sext(i8 to i16)");
	returned = return_value(&f.graph.decls[9]);
	assert(f.graph.decls[9].instructions[(sz)returned].tag == ir::InstTag.ZEXT &&
		f.graph.decls[9].instructions[(sz)returned].data.ref == one_bit_arg &&
		f.graph.decls[9].instructions[(sz)returned].ty == value_interner::REF_I32,
		"sext(zext(i1)) should become zext(i1)");
	assert_returns_bin_with_constant(&f.graph.decls[10], ir::InstTag.ADD, &f.interner, 44,
		"i8 addition wrapping during reassociation");
	assert_returns_bin_with_constant(&f.graph.decls[11], ir::InstTag.ADD, &f.interner, -8,
		"subtraction chain canonicalization and reassociation");
	f.free();
}

fn void inst_combine_reassociates_mul_and_bitwise_constants() @test
{
	HandIrFixture f;
	f.init();
	Ref mul_arg = f.builder.add_arg(value_interner::REF_I32);
	Ref mul_a = f.add_int_constant(3, value_interner::REF_I32);
	Ref mul_b = f.add_int_constant(5, value_interner::REF_I32);
	f.builder.start_fn();
	Ref mul_inner = f.builder.add_inst(ir::InstTag.MUL, { .bin = { mul_arg, mul_a } }, value_interner::REF_I32);
	Ref mul_outer = f.builder.add_inst(ir::InstTag.MUL, { .bin = { mul_inner, mul_b } }, value_interner::REF_I32);
	f.builder.add_return(mul_outer);
	f.builder.finish_fn("mul_reassociate");

	Ref and_arg = f.builder.add_arg(value_interner::REF_I32);
	Ref and_a = f.add_int_constant(12, value_interner::REF_I32);
	Ref and_b = f.add_int_constant(10, value_interner::REF_I32);
	f.builder.start_fn();
	Ref and_inner = f.builder.add_inst(ir::InstTag.BIT_AND, { .bin = { and_arg, and_a } }, value_interner::REF_I32);
	Ref and_outer = f.builder.add_inst(ir::InstTag.BIT_AND, { .bin = { and_inner, and_b } }, value_interner::REF_I32);
	f.builder.add_return(and_outer);
	f.builder.finish_fn("and_reassociate");

	Ref xor_arg = f.builder.add_arg(value_interner::REF_I32);
	Ref xor_a = f.add_int_constant(5, value_interner::REF_I32);
	Ref xor_b = f.add_int_constant(5, value_interner::REF_I32);
	f.builder.start_fn();
	Ref xor_inner = f.builder.add_inst(ir::InstTag.BIT_XOR, { .bin = { xor_arg, xor_a } }, value_interner::REF_I32);
	Ref xor_outer = f.builder.add_inst(ir::InstTag.BIT_XOR, { .bin = { xor_inner, xor_b } }, value_interner::REF_I32);
	f.builder.add_return(xor_outer);
	f.builder.finish_fn("xor_reassociate");
	f.run_o1();

	assert_returns_bin_with_constant(&f.graph.decls[0], ir::InstTag.MUL, &f.interner, 15, "mul reassociation");
	assert_returns_bin_with_constant(&f.graph.decls[1], ir::InstTag.BIT_AND, &f.interner, 8, "and reassociation");
	assert(return_value(&f.graph.decls[2]) == xor_arg, "(x ^ 5) ^ 5 should fold to x");
	f.free();
}

fn void inst_combine_keeps_unsafe_cast_shift_and_mixed_op_chains() @test
{
	HandIrFixture f;
	f.init();
	Ref cast_arg = f.builder.add_arg(value_interner::REF_I8);
	f.builder.start_fn();
	Ref signed_extended = f.builder.add_inst(ir::InstTag.SEXT, { .ref = cast_arg }, value_interner::REF_I16);
	Ref zero_extended = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = signed_extended }, value_interner::REF_I32);
	f.builder.add_return(zero_extended);
	f.builder.finish_fn("zext_of_sext");

	Ref shift_arg = f.builder.add_arg(value_interner::REF_I32);
	Ref shift_a = f.add_int_constant(2, value_interner::REF_I32);
	Ref shift_b = f.add_int_constant(3, value_interner::REF_I32);
	f.builder.start_fn();
	Ref shift_inner = f.builder.add_inst(ir::InstTag.BIT_SHL, { .bin = { shift_arg, shift_a } }, value_interner::REF_I32);
	Ref shift_outer = f.builder.add_inst(ir::InstTag.BIT_SHL, { .bin = { shift_inner, shift_b } }, value_interner::REF_I32);
	f.builder.add_return(shift_outer);
	f.builder.finish_fn("shift_chain");

	Ref mixed_arg = f.builder.add_arg(value_interner::REF_I32);
	Ref mixed_a = f.add_int_constant(2, value_interner::REF_I32);
	Ref mixed_b = f.add_int_constant(3, value_interner::REF_I32);
	f.builder.start_fn();
	Ref mixed_inner = f.builder.add_inst(ir::InstTag.ADD, { .bin = { mixed_arg, mixed_a } }, value_interner::REF_I32);
	Ref mixed_outer = f.builder.add_inst(ir::InstTag.MUL, { .bin = { mixed_inner, mixed_b } }, value_interner::REF_I32);
	f.builder.add_return(mixed_outer);
	f.builder.finish_fn("mixed_ops");

	Ref positive_arg = f.builder.add_arg(value_interner::REF_I8);
	f.builder.start_fn();
	Ref positive_zext = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = positive_arg }, value_interner::REF_I16);
	Ref positive_sext = f.builder.add_inst(ir::InstTag.SEXT, { .ref = positive_zext }, value_interner::REF_I32);
	f.builder.add_return(positive_sext);
	f.builder.finish_fn("sext_of_zext");

	Ref typed_arg = f.builder.add_arg(value_interner::REF_I8);
	Ref typed_inner_constant = f.add_int_constant(3, value_interner::REF_I8);
	Ref typed_outer_constant = f.add_int_constant(4, value_interner::REF_I16);
	f.builder.start_fn();
	Ref typed_inner = f.builder.add_inst(ir::InstTag.ADD, { .bin = { typed_arg, typed_inner_constant } }, value_interner::REF_I8);
	Ref typed_cast = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = typed_inner }, value_interner::REF_I16);
	Ref typed_outer = f.builder.add_inst(ir::InstTag.ADD, { .bin = { typed_cast, typed_outer_constant } }, value_interner::REF_I16);
	f.builder.add_return(typed_outer);
	f.builder.finish_fn("different_inner_type");
	f.run_o1();

	assert(return_value(&f.graph.decls[0]) == zero_extended &&
		f.graph.decls[0].instructions[(sz)signed_extended].tag == ir::InstTag.SEXT &&
		f.graph.decls[0].instructions[(sz)signed_extended].data.ref == cast_arg &&
		f.graph.decls[0].instructions[(sz)zero_extended].tag == ir::InstTag.ZEXT &&
		f.graph.decls[0].instructions[(sz)zero_extended].data.ref == signed_extended,
		"zext(sext(i8)) must retain both casts");
	assert(return_value(&f.graph.decls[1]) == shift_outer &&
		f.graph.decls[1].instructions[(sz)shift_outer].tag == ir::InstTag.BIT_SHL &&
		f.graph.decls[1].instructions[(sz)shift_outer].data.bin.lhs == shift_inner &&
		f.graph.decls[1].instructions[(sz)shift_outer].data.bin.rhs == shift_b &&
		f.graph.decls[1].instructions[(sz)shift_inner].tag == ir::InstTag.BIT_SHL &&
		f.graph.decls[1].instructions[(sz)shift_inner].data.bin.lhs == shift_arg &&
		f.graph.decls[1].instructions[(sz)shift_inner].data.bin.rhs == shift_a,
		"shift chains must not be reassociated as modular multiplication");
	assert(return_value(&f.graph.decls[2]) == mixed_outer &&
		f.graph.decls[2].instructions[(sz)mixed_outer].tag == ir::InstTag.MUL &&
		f.graph.decls[2].instructions[(sz)mixed_outer].data.bin.lhs == mixed_inner &&
		f.graph.decls[2].instructions[(sz)mixed_inner].tag == ir::InstTag.ADD &&
		f.graph.decls[2].instructions[(sz)mixed_inner].data.bin.lhs == mixed_arg &&
		f.graph.decls[2].instructions[(sz)mixed_inner].data.bin.rhs == mixed_a,
		"constant reassociation must not cross a different arithmetic operator");
	assert(f.graph.decls[3].instructions[(sz)return_value(&f.graph.decls[3])].tag == ir::InstTag.ZEXT &&
		f.graph.decls[3].instructions[(sz)return_value(&f.graph.decls[3])].data.ref == positive_arg,
		"sext(zext(i8 to i16), i32) should become zext(i8 to i32)");
	assert(return_value(&f.graph.decls[4]) == typed_outer &&
		f.graph.decls[4].instructions[(sz)typed_outer].tag == ir::InstTag.ADD &&
		f.graph.decls[4].instructions[(sz)typed_outer].data.bin.lhs == typed_cast &&
		f.graph.decls[4].instructions[(sz)typed_cast].tag == ir::InstTag.ZEXT &&
		f.graph.decls[4].instructions[(sz)typed_cast].data.ref == typed_inner,
		"constant reassociation must not cross a cast between integer widths");
	f.free();
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
		"static int choose(int condition, int *out) { if (condition) { *out = 1; return 11; } return 13; }\n"
		"int caller(int condition, int *out) { return choose(condition, out); }\n");
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

fn void o2_inlines_unused_multi_return_void_typed_call_without_void_phi() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref returned_ptr = f.builder.add_arg(value_interner::REF_PTR);
	f.builder.start_fn();
	Ref left = f.builder.make_label("ptr_left");
	Ref right = f.builder.make_label("ptr_right");
	f.builder.add_branch(condition, left, right);
	f.builder.start_block(left);
	f.builder.add_return(returned_ptr);
	f.builder.start_block(right);
	f.builder.add_return(returned_ptr);
	f.builder.finish_fn("ptr_multi_return", ir::Linkage.INTERNAL);

	Ref caller_condition = f.builder.add_arg(value_interner::REF_I1);
	Ref caller_ptr = f.builder.add_arg(value_interner::REF_PTR);
	f.builder.start_fn();
	Ref callee = f.builder.add_symbol("ptr_multi_return", value_interner::REF_PTR);
	Ref[2] args = { caller_condition, caller_ptr };
	Ref call = f.builder.add_call(callee, args[..], value_interner::REF_VOID);
	f.builder.add_return(ir::NONE);
	f.builder.finish_fn("unused_void_call");
	f.finish();

	assert(ir_opt::inline_calls(&f.graph, { .level = code_gen_options::OptimizationLevel.O2 }),
		"the eligible pointer-return call should inline");
	ir::Decl* caller = find_function(&f.graph, "unused_void_call");
	assert(!has_index(caller.body, call), "inlined call should be removed");
	assert(count_body_tag(caller, ir::InstTag.CALL) == 0, "caller should contain no calls");
	assert(count_body_tag(caller, ir::InstTag.PHI) == 0,
		"unused void-typed call must not create a VOID PHI");
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "inlined graph should verify: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	assert(errors.len() == 0, "valid inlined graph should not report verifier errors");
	errors.free();
	f.free();
}

fn void o2_keeps_used_i32_call_to_i64_multi_return_callee() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref value = f.builder.add_arg(value_interner::REF_I64);
	f.builder.start_fn();
	Ref left = f.builder.make_label("i64_left");
	Ref right = f.builder.make_label("i64_right");
	f.builder.add_branch(condition, left, right);
	f.builder.start_block(left);
	f.builder.add_return(value);
	f.builder.start_block(right);
	f.builder.add_return(value);
	f.builder.finish_fn("i64_multi_return", ir::Linkage.INTERNAL);

	Ref caller_condition = f.builder.add_arg(value_interner::REF_I1);
	Ref caller_value = f.builder.add_arg(value_interner::REF_I64);
	f.builder.start_fn();
	Ref callee = f.builder.add_symbol("i64_multi_return", value_interner::REF_PTR);
	Ref[2] args = { caller_condition, caller_value };
	Ref call = f.builder.add_call(callee, args[..], value_interner::REF_I32);
	Ref one = f.add_int_constant(1, value_interner::REF_I32);
	Ref used_result = f.builder.add_inst(ir::InstTag.ADD, { .bin = { call, one } }, value_interner::REF_I32);
	f.builder.add_return(used_result);
	f.builder.finish_fn("used_i32_call");
	f.finish();

	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "hand-built graph should verify: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	assert(errors.len() == 0, "valid hand-built graph should not report verifier errors");
	errors.free();
	assert(!ir_opt::inline_calls(&f.graph, { .level = code_gen_options::OptimizationLevel.O2 }),
		"type-mismatched used call should remain uninlined");
	assert(count_calls_to(find_function(&f.graph, "used_i32_call"), "i64_multi_return") == 1,
		"used i32 call to an i64 callee should remain in the caller");
	f.free();
}

fn void o2_leaves_call_when_callee_return_type_disagrees() @test
{
	HandIrFixture f;
	f.init();
	Ref one = f.add_int_constant(1, value_interner::REF_I32);
	f.builder.start_fn();
	f.builder.add_return(one);
	f.builder.finish_fn("callee", ir::Linkage.INTERNAL);

	f.builder.start_fn();
	Ref symbol = f.builder.add_symbol("callee", value_interner::REF_PTR);
	Ref[1] no_args = { ir::NONE };
	Ref call = f.builder.add_call(symbol, no_args[0..0], value_interner::REF_I64);
	f.builder.add_return(call);
	f.builder.finish_fn("caller");
	f.finish();
	assert(!ir_opt::inline_calls(&f.graph, { .level = code_gen_options::OptimizationLevel.O2 }),
		"a call with a mismatched declared result type should remain uninlined");
	assert(count_calls_to(find_function(&f.graph, "caller"), "callee") == 1,
		"type mismatch guard should preserve the original call");
	f.free();
}

fn void o2_noinline_keeps_cheap_calls() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int __attribute__((noinline)) tiny(int x) { return x + 1; }\n"
		"static int proto(int x) __attribute__((noinline));\n"
		"static int proto(int x) { return x * 2; }\n"
		"static int __attribute__((noinline, always_inline)) both(int x) { return x - 1; }\n"
		"int caller(int y) { return tiny(y) + tiny(y + 1) + proto(y) + both(y); }\n");
	f.run_o2();
	f.verify_graph();
	ir::Decl* caller = find_function(&f.graph, "caller");
	assert(count_calls_to(caller, "tiny") == 2, "noinline keeps both calls to a cheap callee");
	assert(count_calls_to(caller, "proto") == 1, "noinline on a prototype reaches the definition");
	assert(count_calls_to(caller, "both") == 1, "noinline wins over always_inline");
	f.free();
}

fn void o2_always_inline_ignores_cost_threshold() @test
{
	String heavy_body =
		"	x = ext(x + 0);\n"
		"	x = ext(x + 1);\n"
		"	x = ext(x + 2);\n"
		"	x = ext(x + 3);\n"
		"	x = ext(x + 4);\n"
		"	x = ext(x + 5);\n"
		"	x = ext(x + 6);\n"
		"	x = ext(x + 7);\n"
		"	x = ext(x + 8);\n"
		"	x = ext(x + 9);\n"
		"	x = ext(x + 10);\n"
		"	x = ext(x + 11);\n"
		"	x = ext(x + 12);\n"
		"	x = ext(x + 13);\n"
		"	x = ext(x + 14);\n"
		"	x = ext(x + 15);\n"
		"	x = ext(x + 16);\n"
		"	x = ext(x + 17);\n"
		"	x = ext(x + 18);\n"
		"	x = ext(x + 19);\n"
		"	x = ext(x + 20);\n"
		"	x = ext(x + 21);\n"
		"	x = ext(x + 22);\n"
		"	x = ext(x + 23);\n"
		"	return x; }\n";
	OptFixture f;
	f.init();
	f.lower(string::tformat(
		"int ext(int);\n"
		"int __attribute__((always_inline)) forced(int x) {\n%s"
		"int plain(int x) {\n%s"
		"int caller(int y) { return forced(y) + forced(y + 1) + plain(y) + plain(y + 1); }\n",
		heavy_body, heavy_body));
	f.run_o2();
	f.verify_graph();
	ir::Decl* caller = find_function(&f.graph, "caller");
	assert(count_calls_to(caller, "plain") == 2, "the control callee is above the O2 cost threshold");
	assert(count_calls_to(caller, "forced") == 0, "always_inline inlines a callee above the cost threshold");
	f.free();
}

fn void o2_weak_definitions_are_not_exact() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"int __attribute__((weak)) get(void) { return 1; }\n"
		"int __attribute__((weak)) id(int x) { return x; }\n"
		"int caller(void) { id(3); return get() + get(); }\n");
	f.run_o2();
	f.verify_graph();
	assert(find_function(&f.graph, "get").is_weak, "the weak attribute reaches the IR decl");
	ir::Decl* caller = find_function(&f.graph, "caller");
	assert(count_calls_to(caller, "get") == 2,
		"a weak callee is neither inlined nor return-constant folded");
	assert(count_calls_to(caller, "id") == 1,
		"an unused call to a weak pure-looking function is not deleted");
	assert(!find_function(&f.graph, "id").attrs.computed, "no attributes are inferred for a weak body");
	f.free();
}

fn void o2_dce_keeps_used_and_static_init_roots() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int used_global __attribute__((used)) = 1;\n"
		"static int dead_global = 2;\n"
		"static void __attribute__((used)) used_fn(void) {}\n"
		"static void __attribute__((constructor(101))) ctor(void) {}\n"
		"static void __attribute__((destructor)) dtor(void) {}\n"
		"static void dead_fn(void) {}\n"
		"int main(void) { return 0; }\n");
	ir_opt::dead_function_elim(&f.graph, true, false);
	assert(find_decl(&f.graph, "used_global") != null, "an internal used global is a DCE root");
	assert(find_decl(&f.graph, "used_fn") != null, "an internal used function is a DCE root");
	ir::Decl* ctor = find_decl(&f.graph, "ctor");
	assert(ctor != null && ctor.static_init == ir::StaticInit.CONSTRUCTOR && ctor.init_priority == 101,
		"a constructor keeps its priority and stays live");
	ir::Decl* dtor = find_decl(&f.graph, "dtor");
	assert(dtor != null && dtor.static_init == ir::StaticInit.DESTRUCTOR &&
		dtor.init_priority == ir::DEFAULT_INIT_PRIORITY, "a destructor stays live");
	assert(find_decl(&f.graph, "dead_global") == null && find_decl(&f.graph, "dead_fn") == null,
		"unmarked unreferenced internal symbols are still removed");
	f.free();
}

fn void o1_keeps_volatile_cast_accesses_of_plain_local() @test
{
	OptFixture f;
	f.init();
	f.lower("int f(void) { int x; *(volatile int *)&x = 1; return *(volatile int *)&x; }\n");
	f.run_o1();
	f.verify_graph();
	ir::Decl* decl = find_function(&f.graph, "f");
	assert(count_body_tag(decl, ir::InstTag.ALLOC) == 1, "the local stays in memory");
	assert(count_body_tag(decl, ir::InstTag.STORE) == 1 && count_body_tag(decl, ir::InstTag.LOAD) == 1,
		"the volatile store and load both remain");
	foreach (ref : decl.body)
	{
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.LOAD || inst.tag == ir::InstTag.STORE)
		{
			assert(inst.is_volatile, "codegen marks accesses through a volatile lvalue");
		}
	}
	f.free();
}

fn void o2_inlined_volatile_stores_survive() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static void poke(volatile int *p) { *p = 1; *p = 2; }\n"
		"int g(void) { int x = 0; poke((volatile int *)&x); return 0; }\n"
		"int global_value;\n"
		"static int peek(void) { return *(volatile int *)&global_value; }\n"
		"int h(void) { peek(); return 0; }\n");
	f.run_o2();
	f.verify_graph();
	ir::Decl* g = find_function(&f.graph, "g");
	assert(count_calls_to(g, "poke") == 0, "poke is inlined");
	uint volatile_stores = 0;
	foreach (ref : g.body)
	{
		if (g.instructions[(sz)ref].tag == ir::InstTag.STORE && g.instructions[(sz)ref].is_volatile) volatile_stores++;
	}
	assert(volatile_stores == 2, "both volatile stores survive inlining, DSE and mem2reg");
	ir::Decl* h = find_function(&f.graph, "h");
	assert(count_body_tag(h, ir::InstTag.LOAD) + count_calls_to(h, "peek") == 1,
		"an unused volatile read (inlined or via call) is not deleted");
	f.free();
}

fn void o2_converts_gcd_tail_recursion_to_loop() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"int gcd(int a, int b) { if (b == 0) return a; return gcd(b, a % b); }\n");
	f.run_o2();
	f.verify_graph();
	ir::Decl* gcd = find_function(&f.graph, "gcd");
	assert(count_calls_to(gcd, "gcd") == 0, "tail-recursive gcd call should be converted to a loop");
	assert(count_body_tag(gcd, ir::InstTag.PHI) != 0 && count_body_tag(gcd, ir::InstTag.BRANCH) != 0,
		"the converted gcd should have loop-carried PHIs and a header branch");
	ir_opt::Cfg cfg = ir_opt::build_cfg(gcd, &f.ta);
	assert(cfg.blocks.len > 1, "tail-call conversion should create a distinct loop header");
	assert(ir_opt::block_terminator_position(gcd, &cfg.blocks[0]) < cfg.blocks[0].end &&
		gcd.instructions[(sz)gcd.body[ir_opt::block_terminator_position(gcd, &cfg.blocks[0])]].tag == ir::InstTag.JMP,
		"the entry preheader should jump to the loop header");
	bool phi_in_loop_header = false;
	foreach (bi, block : cfg.blocks)
	{
		if (bi == 0) continue;
		for (sz pos = block.start + 1; pos < block.end; pos++)
		{
			if (gcd.instructions[(sz)gcd.body[pos]].tag == ir::InstTag.PHI) phi_in_loop_header = true;
		}
	}
	assert(phi_in_loop_header, "a non-entry block should contain the loop-carried PHIs");
	cfg.free();
	String output = f.dump();
	assert(!output.contains("call ptr_ty @gcd"), "optimized dump should not retain the tail call");
	assert(output.contains("@gcd") && output.contains("loop"), "the converted function should retain its loop header");
	alloc::free(&f.ta, output.ptr);
	f.free();
}

fn void o2_converts_void_tail_recursion_to_loop() @test
{
	OptFixture f;
	f.init();
	f.lower("void count(volatile int *p, int n) { if (n <= 0) return; *p += 1; count(p, n - 1); }\n");
	f.run_o2();
	f.verify_graph();
	assert(count_calls_to(find_function(&f.graph, "count"), "count") == 0,
		"void tail recursion should be converted to a loop");
	f.free();
}

fn void o2_converts_narrow_tail_recursion_with_truncation() @test
{
	OptFixture f;
	f.init();
	f.lower("unsigned char narrow(unsigned char n) { if (n == 0) return 0; return narrow(n - 1); }\n");
	f.run_o2();
	f.verify_graph();
	assert(count_calls_to(find_function(&f.graph, "narrow"), "narrow") == 0,
		"narrow recursive arguments with TRUNC should still form a loop");
	// The backedge value stays 8-bit: a TRUNC of the promoted `n - 1`, or (after
	// narrow_truncated_arith) the `sub i8` itself.
	ir::Decl* narrow = find_function(&f.graph, "narrow");
	bool i8_phi = false;
	foreach (ref : narrow.body)
	{
		ir::Inst inst = narrow.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.PHI && inst.ty == value_interner::REF_I8) i8_phi = true;
	}
	assert(i8_phi, "the converted loop should carry the narrow argument as an i8 PHI");
	f.free();
}

fn void o2_inlines_tail_recursive_loop_into_caller_and_eliminates_helper() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int sum_to(int n, int acc) { return n <= 0 ? acc : sum_to(n - 1, acc + n); }\n"
		"int caller(int n) { return sum_to(n, 0); }\n");
	f.run_o2();
	f.verify_graph();
	assert(!has_function(&f.graph, "sum_to"),
		"the inlined internal recursive helper should be removed by DFE");
	ir::Decl* caller = find_function(&f.graph, "caller");
	assert(caller != null && count_calls_to(caller, "sum_to") == 0 && count_body_tag(caller, ir::InstTag.BRANCH) != 0,
		"the caller should contain the inlined loop control flow");
	ir_opt::Cfg caller_cfg = ir_opt::build_cfg(caller, &f.ta);
	assert(cfg_has_back_edge(&caller_cfg), "the inlined recursive helper should create a loop in its caller");
	caller_cfg.free();
	f.free();
}

fn void o2_converts_accumulator_tail_recursion_to_loop() @test
{
	OptFixture f;
	f.init();
	f.lower("int recursive(int value, int total) { if (value <= 0) return total; return recursive(value - 1, total + value); }\n");
	f.run_o2();
	f.verify_graph();
	ir::Decl* recursive = find_function(&f.graph, "recursive");
	assert(count_calls_to(recursive, "recursive") == 0 && count_body_tag(recursive, ir::InstTag.PHI) != 0,
		"accumulator tail recursion should become a loop with carried state");
	f.free();
}

fn void o2_leaves_recursive_call_intact() @test
{
	OptFixture f;
	f.init();
	f.lower(// `-` is not associative, so tail recursion with an accumulator does not apply.
		"int recursive(int value) { if (value <= 0) return 0; return 1 - recursive(value - 1); }\n");
	f.run_o2();
	f.verify_graph();
	ir::Decl* recursive = find_function(&f.graph, "recursive");
	assert(count_calls_to(recursive, "recursive") == 1,
		"a recursive call with pending addition must remain instead of expanding into itself");
	String output = f.dump();
	assert(output.contains("call ptr_ty @recursive"), "optimized dump should retain the non-tail recursive call");
	alloc::free(&f.ta, output.ptr);
	f.free();
}

fn void o2_keeps_non_tail_recursive_call() @test
{
	OptFixture f;
	f.init();
	f.lower(// `-` is not associative, so tail recursion with an accumulator does not apply.
		"int recursive(int value) { if (value <= 0) return 0; return 1 - recursive(value - 1); }\n");
	f.run_o2();
	f.verify_graph();
	assert(count_calls_to(find_function(&f.graph, "recursive"), "recursive") == 1,
		"a recursive call with pending addition after the call must remain non-tail");
	f.free();
}

fn void o2_keeps_tail_recursion_with_escaping_alloca() @test
{
	OptFixture f;
	f.init();
	f.lower("extern void capture(int *); int recursive(int n) { int local = n; capture(&local); return n ? recursive(n - 1) : local; }\n");
	f.run_o2();
	f.verify_graph();
	assert(count_calls_to(find_function(&f.graph, "recursive"), "recursive") == 1,
		"escaping stack storage should prevent tail-recursion conversion");
	f.free();
}

fn void o2_keeps_variadic_tail_recursion() @test
{
	OptFixture f;
	f.init();
	f.lower("int recursive(int n, ...) { __builtin_va_list ap; __builtin_va_start(ap, n); "
		"return n ? recursive(n - 1, 7) : 0; }\n");
	f.run_o2();
	f.verify_graph();
	assert(count_calls_to(find_function(&f.graph, "recursive"), "recursive") == 1,
		"variadic tail recursion should remain a call");
	f.free();
}

fn void o2_keeps_computed_goto_tail_recursion() @test
{
	HandIrFixture f;
	f.init();
	Ref n = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref again = f.builder.make_label("again");
	Ref target = f.builder.add_inst(ir::InstTag.LABEL_ADDR, { .ref = again }, value_interner::REF_PTR);
	f.builder.add_inst(ir::InstTag.JMP_VAL, { .ref = target }, value_interner::REF_NORETURN);
	f.builder.start_block(again);
	Ref recursive_symbol = f.builder.add_symbol("recursive", value_interner::REF_PTR);
	ir::Ref[1] args = { n };
	Ref call = f.builder.add_call(recursive_symbol, args[..], value_interner::REF_I32);
	f.builder.add_return(call);
	f.builder.finish_fn("recursive");
	f.run_o2();
	assert(count_calls_to(find_function(&f.graph, "recursive"), "recursive") == 1,
		"computed-goto control flow should prevent tail-recursion conversion");
	f.free();
}

fn void o2_keeps_indirect_self_recursive_call() @test
{
	OptFixture f;
	f.init();
	f.lower("int recursive(int); int (*next)(int) = recursive; int recursive(int n) { return n ? next(n - 1) : 0; }\n");
	f.run_o2();
	f.verify_graph();
	ir::Decl* recursive = find_function(&f.graph, "recursive");
	assert(count_body_tag(recursive, ir::InstTag.CALL) == 1,
		"a function-pointer call is indirect and must remain in the function body");
	String output = f.dump();
	assert(output.contains("call"), "the indirect recursive call should remain in the IR");
	alloc::free(&f.ta, output.ptr);
	f.free();
}

fn void o1_leaves_recursive_call_unchanged() @test
{
	OptFixture f;
	f.init();
	f.lower("int recursive(int n) { return n ? recursive(n - 1) : 0; }\n");
	f.run_o1();
	f.verify_graph();
	assert(count_calls_to(find_function(&f.graph, "recursive"), "recursive") == 1,
		"O1 should leave self-recursive calls intact");
	f.free();
}

fn void o2_self_recursive_callee_into_outer_caller() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int r(int n) { return n <= 0 ? 0 : 1 - r(n - 1); }\n"
		"int g(int n) { return r(n); }\n");
	f.run_o2();
	f.verify_graph();
	ir::Decl* caller = find_function(&f.graph, "g");
	assert(count_calls_to(caller, "r") == 1,
		"the outer caller may inline r once, but the recursive edge must remain bounded");
	f.free();
}

fn void o2_skips_large_alloca_callee_in_recursive_caller_but_inlines_nonrecursive() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int large_helper(int value) { volatile unsigned char scratch[2048]; "
		"scratch[0] = (unsigned char)value; scratch[sizeof(scratch) - 1] = (unsigned char)(value >> 8); "
		"return value + scratch[0] + scratch[sizeof(scratch) - 1] - "
		"(unsigned char)value - (unsigned char)(value >> 8); }\n"
		"int recursive_caller(int depth) { if (depth <= 0) return 0; "
		"return large_helper(depth) - recursive_caller(depth - 1); }\n"
		"int ordinary_caller(int value) { return large_helper(value); }\n");
	f.run_o2();
	f.verify_graph();
	ir::Decl* recursive = find_function(&f.graph, "recursive_caller");
	ir::Decl* ordinary = find_function(&f.graph, "ordinary_caller");
	assert(count_calls_to(recursive, "large_helper") == 1,
		"a recursive caller should retain its call to a callee with a large alloca");
	assert(count_calls_to(ordinary, "large_helper") == 0,
		"a nonrecursive caller should inline the same large-alloca callee");
	ir_opt::Cfg cfg = ir_opt::build_cfg(ordinary, &f.ta);
	uint entry = block_for_label(&cfg, cfg.blocks[0].label);
	bool saw_entry_alloc = false;
	foreach (ref : ordinary.body)
	{
		if (ordinary.instructions[(sz)ref].tag != ir::InstTag.ALLOC) continue;
		if (cfg.block_of_ref[(sz)ref] == entry) saw_entry_alloc = true;
	}
	assert(saw_entry_alloc, "the inlined callee's ALLOC should be placed in the caller entry block");
	cfg.free();
	f.free();
}

fn void o2_leaves_mutually_recursive_calls_intact() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int odd(int value);\n"
		"static int even(int value) { if (value == 0) return 1; return odd(value - 1); }\n"
		"static int odd(int value) { if (value == 0) return 0; return even(value - 1); }\n"
		"int caller(int value) { return even(value); }\n");
	f.run_o2();
	f.verify_graph();
	assert(count_calls_to(find_function(&f.graph, "even"), "odd") == 1,
		"the even-to-odd recursive edge should remain");
	assert(count_calls_to(find_function(&f.graph, "odd"), "even") == 1,
		"the odd-to-even recursive edge should remain");
	f.free();
}

fn void o2_preserves_volatile_alloc_when_inlining_callee() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int read_volatile_local(void) { volatile int value = 9; return value; }\n"
		"int caller(void) { return read_volatile_local(); }\n");
	f.run_o2();
	f.verify_graph();
	ir::Decl* caller = find_function(&f.graph, "caller");
	assert(count_calls_to(caller, "read_volatile_local") == 0,
		"the volatile local callee should inline into caller");
	bool saw_volatile_alloc = false;
	foreach (ref : caller.body)
	{
		ir::Inst* inst = &caller.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.ALLOC && inst.data.alloc.is_volatile) saw_volatile_alloc = true;
	}
	assert(saw_volatile_alloc, "inlining should preserve the volatile flag on the cloned ALLOC");
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
	Ref callee_out = f.builder.add_arg(value_interner::REF_PTR);
	f.builder.start_fn();
	Ref callee_then = f.builder.make_label("callee_then");
	Ref callee_else = f.builder.make_label("callee_else");
	Ref one = f.add_int_constant(1, value_interner::REF_I32);
	Ref two = f.add_int_constant(2, value_interner::REF_I32);
	f.builder.add_branch(callee_condition, callee_then, callee_else);
	f.builder.start_block(callee_then);
	f.builder.add_store(callee_out, one);
	f.builder.add_return(one);
	f.builder.start_block(callee_else);
	f.builder.add_return(two);
	f.builder.finish_fn("multi_return", ir::Linkage.INTERNAL);

	Ref caller_condition = f.builder.add_arg(value_interner::REF_I1);
	Ref fallback_value = f.builder.add_arg(value_interner::REF_I32);
	Ref caller_out = f.builder.add_arg(value_interner::REF_PTR);
	f.builder.start_fn();
	Ref call_block = f.builder.make_label("call");
	Ref fallback_block = f.builder.make_label("fallback");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(caller_condition, call_block, fallback_block);
	f.builder.start_block(call_block);
	Ref callee_symbol = f.builder.add_symbol("multi_return", value_interner::REF_PTR);
	Ref[2] call_args = { caller_condition, caller_out };
	Ref call_result = f.builder.add_call(callee_symbol, call_args[..], value_interner::REF_I32);
	f.builder.add_jump(join);
	f.builder.start_block(fallback_block);
	f.builder.add_store(caller_out, fallback_value);
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
	// The fallback block stores through caller_out, so it is neither folded nor
	// if-converted; the fallback edge's label is still checked against the join's real predecessors below.
	bool saw_fallback = false;
	bool saw_relabelled_call_edge = false;
	foreach (input : successor_inputs)
	{
		if (input.value == fallback_value)
		{
			saw_fallback = true;
		}
		else
		{
			saw_relabelled_call_edge = input.label != call_block;
		}
	}
	assert(saw_fallback, "successor PHI should retain its fallback edge");
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

fn void sccp_select_waits_for_late_loop_phi_value() @test
{
	HandIrFixture f;
	f.init();
	Ref zero = f.add_int_constant(0, value_interner::REF_I32);
	Ref one = f.add_int_constant(1, value_interner::REF_I32);
	Ref then_value = f.add_int_constant(17, value_interner::REF_I32);
	Ref else_value = f.add_int_constant(29, value_interner::REF_I32);
	f.builder.start_fn();
	Ref entry = f.builder.current_label;
	Ref header = f.builder.make_label("header");
	Ref body = f.builder.make_label("body");
	Ref exit = f.builder.make_label("exit");
	f.builder.add_jump(header);
	f.builder.start_block(header);
	// The back-edge is discovered after the entry edge. The PHI starts at zero,
	// then becomes overdefined when the body contributes one.
	ir::PhiInput[2] incoming = {
		{ .label = entry, .value = zero },
		{ .label = body, .value = one },
	};
	Ref late_condition = f.builder.add_phi(incoming[..], value_interner::REF_I32);
	Ref is_zero = f.builder.add_inst(ir::InstTag.CMP_EQ,
		{ .bin = { late_condition, zero } }, value_interner::REF_I1);
	Ref selected = f.builder.add_select(is_zero, then_value, else_value, value_interner::REF_I32);
	f.builder.add_branch(is_zero, body, exit);
	f.builder.start_block(body);
	f.builder.add_jump(header);
	f.builder.start_block(exit);
	f.builder.add_return(selected);
	f.builder.finish_fn("select_late_condition");
	f.finish();
	ir_opt::const_prop(&f.graph, &f.graph.decls[0]);
	ir::Decl* decl = &f.graph.decls[0];
	assert(return_value(decl) == selected,
		"SELECT must not be replaced using the PHI's initial constant before its back-edge arrives");
	assert(has_index(decl.body, selected), "the uncertain SELECT should remain in the body");
	assert(count_body_tag(decl, ir::InstTag.BRANCH) == 1,
		"the branch must remain after the PHI becomes overdefined on its late back-edge");
	f.free();
}

fn void sccp_folds_select_with_constant_cmp_ne_condition() @test
{
	HandIrFixture f;
	f.init();
	Ref one = f.add_int_constant(1, value_interner::REF_I32);
	Ref zero = f.add_int_constant(0, value_interner::REF_I32);
	Ref five = f.add_int_constant(5, value_interner::REF_I32);
	Ref seven = f.add_int_constant(7, value_interner::REF_I32);
	f.builder.start_fn();
	Ref condition = f.builder.add_inst(ir::InstTag.CMP_NE,
		{ .bin = { one, zero } }, value_interner::REF_I1);
	Ref selected = f.builder.add_select(condition, five, seven, value_interner::REF_I32);
	f.builder.add_return(selected);
	f.builder.finish_fn("constant_cmp_ne_select");
	f.finish();
	assert(ir_opt::const_prop(&f.graph, &f.graph.decls[0]),
		"const_prop should fold the constant comparison and SELECT");
	assert_returns_int(&f.graph.decls[0], &f.interner, 5,
		"SELECT with cmp_ne i32 1, 0");
	assert(f.graph.decls[0].instructions[(sz)return_value(&f.graph.decls[0])].tag == ir::InstTag.CONSTANT,
		"the selected return value should be a CONSTANT instruction");
	f.free();
}

fn void sccp_preserves_unknown_branch_and_verifies_cfg() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref then_value = f.add_int_constant(5, value_interner::REF_I32);
	Ref else_value = f.add_int_constant(7, value_interner::REF_I32);
	f.builder.start_fn();
	Ref then_label = f.builder.make_label("then");
	Ref else_label = f.builder.make_label("else");
	Ref join = f.builder.make_label("join");
	f.builder.add_branch(condition, then_label, else_label);
	f.builder.start_block(then_label);
	f.builder.add_jump(join);
	f.builder.start_block(else_label);
	f.builder.add_jump(join);
	f.builder.start_block(join);
	ir::PhiInput[2] incoming = {
		{ .label = then_label, .value = then_value },
		{ .label = else_label, .value = else_value },
	};
	f.builder.add_return(f.builder.add_phi(incoming[..], value_interner::REF_I32));
	f.builder.finish_fn("unknown_branch");
	f.finish();
	ir_opt::const_prop(&f.graph, &f.graph.decls[0]);
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.BRANCH) == 1,
		"an unknown executable branch condition must remain a BRANCH");
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "SCCP output should verify: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	errors.free();
	f.free();
}

fn void sccp_keeps_undefined_integer_operations_unfolded() @test
{
	HandIrFixture f;
	f.init();
	Ref min_i8 = f.add_int_constant(-128, value_interner::REF_I8);
	Ref minus_one_i8 = f.add_int_constant(-1, value_interner::REF_I8);
	Ref zero_i8 = f.add_int_constant(0, value_interner::REF_I8);
	Ref one_i8 = f.add_int_constant(1, value_interner::REF_I8);
	Ref width_i8 = f.add_int_constant(8, value_interner::REF_I8);
	f.builder.start_fn();
	Ref sdiv = f.builder.add_inst(ir::InstTag.SDIV, { .bin = { min_i8, minus_one_i8 } }, value_interner::REF_I8);
	Ref srem = f.builder.add_inst(ir::InstTag.SREM, { .bin = { min_i8, minus_one_i8 } }, value_interner::REF_I8);
	Ref udiv = f.builder.add_inst(ir::InstTag.UDIV, { .bin = { one_i8, zero_i8 } }, value_interner::REF_I8);
	Ref urem = f.builder.add_inst(ir::InstTag.UREM, { .bin = { one_i8, zero_i8 } }, value_interner::REF_I8);
	Ref shift = f.builder.add_inst(ir::InstTag.BIT_SHL, { .bin = { one_i8, width_i8 } }, value_interner::REF_I8);
	Ref combined = f.builder.add_inst(ir::InstTag.ADD, { .bin = { sdiv, srem } }, value_interner::REF_I8);
	Ref combined2 = f.builder.add_inst(ir::InstTag.ADD, { .bin = { udiv, urem } }, value_interner::REF_I8);
	Ref combined3 = f.builder.add_inst(ir::InstTag.ADD, { .bin = { combined, combined2 } }, value_interner::REF_I8);
	Ref result = f.builder.add_inst(ir::InstTag.ADD, { .bin = { combined3, shift } }, value_interner::REF_I8);
	f.builder.add_return(result);
	f.builder.finish_fn("undefined_integer_ops");
	f.run_o1();
	ir::Decl* decl = &f.graph.decls[0];
	assert(has_index(decl.body, sdiv) && has_index(decl.body, srem),
		"signed minimum divided or remaindered by minus one must not be evaluated");
	assert(has_index(decl.body, udiv) && has_index(decl.body, urem),
		"unsigned division and remainder by zero must not be evaluated");
	assert(has_index(decl.body, shift), "a shift by the operand width must not be evaluated");
	f.free();
}

fn void sccp_keeps_additional_undefined_integer_operations_unfolded() @test
{
	HandIrFixture f;
	f.init();
	Ref min_i64 = f.add_int_constant(long::min, value_interner::REF_I64);
	Ref min_i32 = f.add_int_constant(-2147483648, value_interner::REF_I32);
	Ref minus_one_i64 = f.add_int_constant(-1, value_interner::REF_I64);
	Ref minus_one_i32 = f.add_int_constant(-1, value_interner::REF_I32);
	Ref width_i32 = f.add_int_constant(32, value_interner::REF_I32);
	f.builder.start_fn();
	Ref sdiv_i64 = f.builder.add_inst(ir::InstTag.SDIV,
		{ .bin = { min_i64, minus_one_i64 } }, value_interner::REF_I64);
	Ref srem_i32 = f.builder.add_inst(ir::InstTag.SREM,
		{ .bin = { min_i32, minus_one_i32 } }, value_interner::REF_I32);
	Ref lshr_i32 = f.builder.add_inst(ir::InstTag.BIT_LSHR,
		{ .bin = { min_i32, width_i32 } }, value_interner::REF_I32);
	Ref ashr_i32 = f.builder.add_inst(ir::InstTag.BIT_ASHR,
		{ .bin = { min_i32, width_i32 } }, value_interner::REF_I32);
	Ref shl_negative_i32 = f.builder.add_inst(ir::InstTag.BIT_SHL,
		{ .bin = { min_i32, minus_one_i32 } }, value_interner::REF_I32);
	Ref combine = f.builder.add_inst(ir::InstTag.ADD,
		{ .bin = { srem_i32, lshr_i32 } }, value_interner::REF_I32);
	Ref combine2 = f.builder.add_inst(ir::InstTag.ADD,
		{ .bin = { combine, ashr_i32 } }, value_interner::REF_I32);
	Ref combine3 = f.builder.add_inst(ir::InstTag.ADD,
		{ .bin = { combine2, shl_negative_i32 } }, value_interner::REF_I32);
	Ref combine3_i64 = f.builder.add_inst(ir::InstTag.SEXT,
		{ .ref = combine3 }, value_interner::REF_I64);
	Ref result = f.builder.add_inst(ir::InstTag.ADD,
		{ .bin = { combine3_i64, sdiv_i64 } }, value_interner::REF_I64);
	f.builder.add_return(result);
	f.builder.finish_fn("additional_undefined_integer_ops");
	f.finish();
	ir_opt::const_prop(&f.graph, &f.graph.decls[0]);
	ir::Decl* decl = &f.graph.decls[0];
	assert(has_index(decl.body, sdiv_i64),
		"i64 INT64_MIN / -1 must remain unevaluated");
	assert(has_index(decl.body, srem_i32),
		"i32 INT_MIN % -1 must remain unevaluated");
	assert(has_index(decl.body, lshr_i32) && has_index(decl.body, ashr_i32),
		"i32 logical and arithmetic right shifts by 32 must remain unevaluated");
	assert(has_index(decl.body, shl_negative_i32),
		"an i32 shift by -1 must remain unevaluated");
	f.free();
}

fn void sccp_keeps_late_back_edge_phi_overdefined() @test
{
	HandIrFixture f;
	f.init();
	Ref runtime = f.builder.add_arg(value_interner::REF_I1);
	Ref zero = f.add_int_constant(0, value_interner::REF_I32);
	Ref one = f.add_int_constant(1, value_interner::REF_I32);
	f.builder.start_fn();
	Ref entry = f.builder.current_label;
	Ref header = f.builder.make_label("header");
	Ref latch = f.builder.make_label("latch");
	Ref exit = f.builder.make_label("exit");
	f.builder.add_jump(header);
	f.builder.start_block(header);
	ir::PhiInput[2] incoming = {
		{ .label = entry, .value = zero },
		{ .label = latch, .value = one },
	};
	Ref phi = f.builder.add_phi(incoming[..], value_interner::REF_I32);
	f.builder.add_branch(runtime, latch, exit);
	f.builder.start_block(latch);
	f.builder.add_jump(header);
	f.builder.start_block(exit);
	f.builder.add_return(phi);
	f.builder.finish_fn("late_back_edge_phi");
	f.run_o1();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.BRANCH) != 0,
		"the loop branch must remain after the back-edge changes the PHI value");
	assert(!is_int_constant(decl, return_value(decl), f.graph.interner, 0),
		"the late back-edge must prevent the PHI result from being folded to its entry value");
	f.free();
}

fn void sccp_bails_out_on_computed_goto() @test
{
	HandIrFixture f;
	f.init();
	Ref value = f.add_int_constant(4, value_interner::REF_I32);
	f.builder.start_fn();
	Ref destination = f.builder.make_label("destination");
	Ref address = f.builder.add_inst(ir::InstTag.LABEL_ADDR, { .ref = destination }, value_interner::REF_PTR);
	f.builder.add_inst(ir::InstTag.JMP_VAL, { .ref = address }, value_interner::REF_NORETURN);
	f.builder.start_block(destination);
	f.builder.add_return(value);
	f.builder.finish_fn("computed_goto_guard");
	f.finish();
	assert(!ir_opt::const_prop(&f.graph, &f.graph.decls[0]),
		"SCCP must bail out because the CFG does not model computed-goto successors");
	assert(count_body_tag(&f.graph.decls[0], ir::InstTag.JMP_VAL) == 1,
		"the computed jump should remain intact");
	f.free();
}

fn void o1_removes_call_from_constant_dead_arm() @test
{
	OptFixture f;
	f.init();
	f.lower("extern void observe(void);\n"
		"int dead_arm_call(void) { if (1) return 5; observe(); return 0; }\n");
	f.run_o1();
	assert(count_body_tag(find_function(&f.graph, "dead_arm_call"), ir::InstTag.CALL) == 0,
		"O1 should remove the call placed only in the constant-dead arm");
	f.free();
}

fn void ipsccp_propagates_common_constant_arguments_and_returns() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int multiply(int value, int factor) { return value * factor; }\n"
		"static int constant_value(void) { return 37; }\n"
		"int constant_argument_caller(int value) { return multiply(value, 3); }\n"
		"int constant_argument_caller_two(int value) { return multiply(value + 1, 3); }\n"
		"int constant_return_caller(void) { return constant_value(); }\n");
	f.run_mem2reg();
	ir_opt::ipsccp(&f.graph, {
		.level = code_gen_options::OptimizationLevel.O2,
		.whole_program = false,
		.verify = true,
	});
	f.verify_graph();
	ir::Decl* multiply = find_function(&f.graph, "multiply");
	assert(multiply.body.len >= 2, "multiply should retain both parameter ARGs");
	ir::Ref factor_arg = multiply.body[1];
	assert(multiply.instructions[(sz)factor_arg].tag == ir::InstTag.ARG,
		"the specialized parameter should remain placed for DeadArgElim");
	ir_opt::Uses arg_uses = ir_opt::compute_uses(multiply, f.graph.allocator);
	assert(arg_uses.of(factor_arg).len == 0,
		"the second ARG should be unused after common constant propagation");
	arg_uses.free();
	ir::Inst* product = &multiply.instructions[(sz)return_value(multiply)];
	assert(product.tag == ir::InstTag.MUL &&
		(is_int_constant(multiply, product.data.bin.lhs, f.graph.interner, 3) ||
		 is_int_constant(multiply, product.data.bin.rhs, f.graph.interner, 3)),
		"multiply should use the shared constant 3");
	assert_returns_int(find_function(&f.graph, "constant_return_caller"), f.graph.interner, 37,
		"constant return call site");
	f.free();
}

fn void ipsccp_preserves_ineligible_or_conflicting_call_sites() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int differing(int value) { return value; }\n"
		"int differing_sites(void) { return differing(3) + differing(4); }\n"
		"int externally_visible(int value) { return value; }\n"
		"int external_site(void) { return externally_visible(5); }\n"
		"static int address_taken(int value) { return value; }\n"
		"int (*address_taken_pointer)(int) = address_taken;\n"
		"int address_taken_site(void) { return address_taken(6); }\n"
		"static int variadic(int value, ...) { __builtin_va_list ap; __builtin_va_start(ap, value); return value; }\n"
		"int variadic_site(void) { return variadic(7, 8); }\n"
		"static int mixed_sites(int value) { return value; }\n"
		"int mixed_site_caller(int runtime) { return mixed_sites(9) + mixed_sites(runtime); }\n");
	f.run_mem2reg();
	ir_opt::ipsccp(&f.graph, {
		.level = code_gen_options::OptimizationLevel.O2,
		.whole_program = false,
		.verify = true,
	});
	f.verify_graph();
	assert(returns_argument(find_function(&f.graph, "differing")),
		"different constants at call sites must not specialize the callee");
	assert(returns_argument(find_function(&f.graph, "externally_visible")),
		"externally visible functions must not be specialized from local callers");
	assert(returns_argument(find_function(&f.graph, "address_taken")),
		"address-taken functions must not be specialized");
	assert(returns_argument(find_function(&f.graph, "variadic")),
		"variadic functions must not be specialized");
	assert(returns_argument(find_function(&f.graph, "mixed_sites")),
		"one nonconstant call site must prevent argument specialization");
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

fn void sccp_folds_signed_i1_comparison_truth_table() @test
{
	HandIrFixture f;
	f.init();
	ir::InstTag[4] tags = {
		ir::InstTag.CMP_SLT,
		ir::InstTag.CMP_SLTE,
		ir::InstTag.CMP_SGT,
		ir::InstTag.CMP_SGTE,
	};
	String[16] function_names = {
		"slt_00", "slt_01", "slt_10", "slt_11",
		"slte_00", "slte_01", "slte_10", "slte_11",
		"sgt_00", "sgt_01", "sgt_10", "sgt_11",
		"sgte_00", "sgte_01", "sgte_10", "sgte_11",
	};
	long[2] bit_values = { 0, 1 };
	long[2] signed_values = { 0, -1 };
	for (sz op = 0; op < 4; op++)
	{
		for (sz lhs_bit = 0; lhs_bit < 2; lhs_bit++)
		{
			for (sz rhs_bit = 0; rhs_bit < 2; rhs_bit++)
			{
				Ref lhs = f.add_int_constant(bit_values[lhs_bit], value_interner::REF_I1);
				Ref rhs = f.add_int_constant(bit_values[rhs_bit], value_interner::REF_I1);
				f.builder.start_fn();
				Ref comparison = f.builder.add_inst(tags[op], { .bin = { lhs, rhs } }, value_interner::REF_I1);
				f.builder.add_return(comparison);
				f.builder.finish_fn(function_names[op * 4 + lhs_bit * 2 + rhs_bit]);
			}
		}
	}
	f.run_o1();

	sz function_index = 0;
	for (sz op = 0; op < 4; op++)
	{
		for (sz lhs_bit = 0; lhs_bit < 2; lhs_bit++)
		{
			for (sz rhs_bit = 0; rhs_bit < 2; rhs_bit++)
			{
				long lhs = signed_values[lhs_bit];
				long rhs = signed_values[rhs_bit];
				bool expected;
				if (tags[op] == ir::InstTag.CMP_SLT) { expected = lhs < rhs; }
				else if (tags[op] == ir::InstTag.CMP_SLTE) { expected = lhs <= rhs; }
				else if (tags[op] == ir::InstTag.CMP_SGT) { expected = lhs > rhs; }
				else { expected = lhs >= rhs; }
				assert_returns_int(&f.graph.decls[function_index], &f.interner, expected ? 1 : 0,
					"signed i1 comparison truth table");
				function_index++;
			}
		}
	}
	f.free();
}

fn void inst_combine_equal_arg_compare_folds_branch_and_select() @test
{
	HandIrFixture f;
	f.init();
	Ref value = f.builder.add_arg(value_interner::REF_I32);
	Ref other = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref same = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { value, value } }, value_interner::REF_I1);
	Ref selected = f.builder.add_select(same, value, other, value_interner::REF_I32);
	Ref yes = f.builder.make_label("yes");
	Ref no = f.builder.make_label("no");
	Ref done = f.builder.make_label("done");
	f.builder.add_branch(same, yes, no);
	f.builder.start_block(yes);
	f.builder.add_jump(done);
	f.builder.start_block(no);
	f.builder.add_jump(done);
	f.builder.start_block(done);
	f.builder.add_return(selected);
	f.builder.finish_fn("same_arg_compare");
	f.run_o1();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.CMP_EQ) == 0,
		"equal ARG operands should fold their integer comparison");
	assert(count_body_tag(decl, ir::InstTag.SELECT) == 0,
		"a folded comparison should select the true ARG directly");
	assert(count_body_tag(decl, ir::InstTag.BRANCH) == 0,
		"a folded comparison should remove the conditional branch");
	assert(return_value(decl) == value,
		"the return should use the selected true ARG");
	f.free();
}

fn void inst_combine_keeps_nontrivial_arg_compare_branch_and_select() @test
{
	HandIrFixture f;
	f.init();
	Ref lhs = f.builder.add_arg(value_interner::REF_I32);
	Ref rhs = f.builder.add_arg(value_interner::REF_I32);
	Ref fallback = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref less = f.builder.add_inst(ir::InstTag.CMP_SLT, { .bin = { lhs, rhs } }, value_interner::REF_I1);
	Ref selected = f.builder.add_select(less, lhs, fallback, value_interner::REF_I32);
	Ref yes = f.builder.make_label("yes");
	Ref no = f.builder.make_label("no");
	f.builder.add_branch(less, yes, no);
	f.builder.start_block(yes);
	f.builder.add_return(selected);
	f.builder.start_block(no);
	f.builder.add_return(fallback);
	f.builder.finish_fn("ordered_arg_compare");
	f.run_o1();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.CMP_SLT) == 1,
		"an ordered comparison of distinct ARGs must remain");
	assert(count_body_tag(decl, ir::InstTag.SELECT) == 1,
		"the select driven by a nonconstant comparison must remain");
	assert(count_body_tag(decl, ir::InstTag.BRANCH) == 1,
		"the branch driven by a nonconstant comparison must remain");
	assert(return_value(decl) == fallback || return_value(decl) == selected,
		"a return should still consume one of the original ARG values");
	f.free();
}

fn void inst_combine_inverts_boolean_branch_and_select_arms() @test
{
	HandIrFixture f;
	f.init();
	Ref predicate = f.builder.add_arg(value_interner::REF_I1);
	Ref zero = f.add_int_constant(0, value_interner::REF_I1);
	Ref yes_value = f.builder.add_arg(value_interner::REF_I32);
	Ref no_value = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref inverted = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { predicate, zero } }, value_interner::REF_I1);
	Ref yes = f.builder.make_label("yes");
	Ref no = f.builder.make_label("no");
	f.builder.add_branch(inverted, yes, no);
	f.builder.start_block(yes);
	f.builder.add_return(yes_value);
	f.builder.start_block(no);
	f.builder.add_return(no_value);
	f.builder.finish_fn("inverted_branch");

	Ref predicate2 = f.builder.add_arg(value_interner::REF_I1);
	Ref zero2 = f.add_int_constant(0, value_interner::REF_I1);
	Ref then_value = f.builder.add_arg(value_interner::REF_I32);
	Ref else_value = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref inverted_select_cond = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { predicate2, zero2 } }, value_interner::REF_I1);
	Ref selected = f.builder.add_select(inverted_select_cond, then_value, else_value, value_interner::REF_I32);
	f.builder.add_return(selected);
	f.builder.finish_fn("inverted_select");
	f.run_o1();

	ir::Decl* branch_decl = &f.graph.decls[0];
	bool saw_swapped_branch = false;
	foreach (ref : branch_decl.body)
	{
		ir::Inst* inst = &branch_decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.BRANCH && inst.data.branch.cond == predicate &&
			inst.data.branch.then_label == no && inst.data.branch.else_label == yes) saw_swapped_branch = true;
	}
	assert(saw_swapped_branch, "an inverted comparison branch should use the original condition and swapped labels");

	ir::Decl* select_decl = &f.graph.decls[1];
	bool saw_swapped_select = false;
	foreach (ref : select_decl.body)
	{
		ir::Inst* inst = &select_decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.SELECT && inst.data.branch.cond == predicate2 &&
			inst.data.branch.then_label == else_value && inst.data.branch.else_label == then_value) saw_swapped_select = true;
	}
	assert(saw_swapped_select, "an inverted select condition should swap the selected arms");
	f.free();
}

fn void inst_combine_inverts_integer_compare_for_branch() @test
{
	HandIrFixture f;
	f.init();
	Ref a = f.builder.add_arg(value_interner::REF_I32);
	Ref b = f.builder.add_arg(value_interner::REF_I32);
	Ref zero = f.add_int_constant(0, value_interner::REF_I1);
	f.builder.start_fn();
	Ref inner = f.builder.add_inst(ir::InstTag.CMP_SLT, { .bin = { a, b } }, value_interner::REF_I1);
	Ref negated = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { inner, zero } }, value_interner::REF_I1);
	Ref yes = f.builder.make_label("yes");
	Ref no = f.builder.make_label("no");
	f.builder.add_branch(negated, yes, no);
	f.builder.start_block(yes);
	f.builder.add_return(a);
	f.builder.start_block(no);
	f.builder.add_return(b);
	f.builder.finish_fn("inverted_integer_compare_branch");
	f.run_o1();

	ir::Decl* decl = &f.graph.decls[0];
	bool saw_inverse_compare = false;
	foreach (ref : decl.body)
	{
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag != ir::InstTag.BRANCH) continue;
		ir::Ref cond_ref = inst.data.branch.cond;
		ir::Inst* cond = &decl.instructions[(sz)cond_ref];
		if (cond.tag == ir::InstTag.CMP_SGTE && cond.data.bin.lhs == a && cond.data.bin.rhs == b &&
			inst.data.branch.then_label == yes && inst.data.branch.else_label == no) saw_inverse_compare = true;
	}
	assert(saw_inverse_compare,
		"branching on equality-to-zero of signed less-than should use signed greater-or-equal with the original operands");
	f.free();
}

fn void inst_combine_simplifies_integer_boolean_and_extended_comparisons() @test
{
	HandIrFixture f;
	f.init();
	Ref p = f.builder.add_arg(value_interner::REF_I1);
	Ref bool_zero = f.add_int_constant(0, value_interner::REF_I1);
	f.builder.start_fn();
	Ref not_p = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { p, bool_zero } }, value_interner::REF_I1);
	Ref twice_not_p = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { not_p, bool_zero } }, value_interner::REF_I1);
	f.builder.add_return(twice_not_p);
	f.builder.finish_fn("nested_bool_not");

	Ref less_lhs = f.builder.add_arg(value_interner::REF_I32);
	Ref less_rhs = f.builder.add_arg(value_interner::REF_I32);
	Ref int_zero = f.add_int_constant(0, value_interner::REF_I32);
	f.builder.start_fn();
	Ref less = f.builder.add_inst(ir::InstTag.CMP_ULT, { .bin = { less_lhs, less_rhs } }, value_interner::REF_I1);
	Ref less_wide = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = less }, value_interner::REF_I32);
	Ref not_less_wide = f.builder.add_inst(ir::InstTag.CMP_NE, { .bin = { less_wide, int_zero } }, value_interner::REF_I1);
	f.builder.add_return(not_less_wide);
	f.builder.finish_fn("returned_extended_bool");

	Ref eq_arg = f.builder.add_arg(value_interner::REF_I8);
	Ref eq_300 = f.add_int_constant(300, value_interner::REF_I32);
	f.builder.start_fn();
	Ref eq_wide = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = eq_arg }, value_interner::REF_I32);
	Ref impossible_eq = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { eq_wide, eq_300 } }, value_interner::REF_I1);
	f.builder.add_return(impossible_eq);
	f.builder.finish_fn("eq_zext_out_of_range");

	Ref ult_arg = f.builder.add_arg(value_interner::REF_I8);
	Ref ten = f.add_int_constant(10, value_interner::REF_I32);
	f.builder.start_fn();
	Ref ult_wide = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = ult_arg }, value_interner::REF_I32);
	Ref ult = f.builder.add_inst(ir::InstTag.CMP_ULT, { .bin = { ult_wide, ten } }, value_interner::REF_I1);
	f.builder.add_return(ult);
	f.builder.finish_fn("ult_zext_narrow_compare");

	Ref neg_eq_arg = f.builder.add_arg(value_interner::REF_I8);
	Ref max = f.add_int_constant(255, value_interner::REF_I32);
	f.builder.start_fn();
	Ref neg_eq_wide = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = neg_eq_arg }, value_interner::REF_I32);
	Ref eq_255 = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { neg_eq_wide, max } }, value_interner::REF_I1);
	f.builder.add_return(eq_255);
	f.builder.finish_fn("eq_zext_max");

	Ref signed_lhs = f.builder.add_arg(value_interner::REF_I8);
	Ref signed_out_of_range = f.add_int_constant(300, value_interner::REF_I32);
	f.builder.start_fn();
	Ref signed_wide_lhs = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = signed_lhs }, value_interner::REF_I32);
	Ref signed_compare = f.builder.add_inst(ir::InstTag.CMP_SLT,
		{ .bin = { signed_wide_lhs, signed_out_of_range } }, value_interner::REF_I1);
	f.builder.add_return(signed_compare);
	f.builder.finish_fn("signed_compare_of_zext");

	Ref ordinary_int = f.builder.add_arg(value_interner::REF_I32);
	Ref ordinary_zero = f.add_int_constant(0, value_interner::REF_I32);
	f.builder.start_fn();
	Ref ordinary_eq_zero = f.builder.add_inst(ir::InstTag.CMP_EQ,
		{ .bin = { ordinary_int, ordinary_zero } }, value_interner::REF_I1);
	f.builder.add_return(ordinary_eq_zero);
	f.builder.finish_fn("integer_eq_zero");
	f.run_o1();

	assert(return_value(&f.graph.decls[0]) == p, "nested boolean negation should return the original predicate");
	ir::Inst returned_bool = f.graph.decls[1].instructions[(sz)return_value(&f.graph.decls[1])];
	assert(returned_bool.tag == ir::InstTag.CMP_ULT && returned_bool.data.bin.lhs == less_lhs && returned_bool.data.bin.rhs == less_rhs,
		"cmp_ne(zext(cmp_ult), 0) should return the original unsigned comparison");
	assert_returns_int(&f.graph.decls[2], &f.interner, 0, "equality against an out-of-range zero extension constant");
	ir::Inst narrowed_ult = f.graph.decls[3].instructions[(sz)return_value(&f.graph.decls[3])];
	assert(narrowed_ult.tag == ir::InstTag.CMP_ULT && narrowed_ult.data.bin.lhs == ult_arg,
		"unsigned comparison after zero extension should compare the original narrow operand");
	assert(narrowed_ult.data.bin.rhs != ten && f.graph.decls[3].instructions[(sz)narrowed_ult.data.bin.rhs].ty == value_interner::REF_I8,
		"the narrow unsigned comparison should use an i8 constant");
	ir::Inst retained_eq = f.graph.decls[4].instructions[(sz)return_value(&f.graph.decls[4])];
	assert(retained_eq.tag == ir::InstTag.CMP_EQ && retained_eq.data.bin.lhs == neg_eq_arg,
		"equality against zero-extended 255 should retain an equality comparison");
	ir::Inst retained_signed = f.graph.decls[5].instructions[(sz)return_value(&f.graph.decls[5])];
	assert(retained_signed.tag == ir::InstTag.CMP_SLT && retained_signed.data.bin.lhs == signed_wide_lhs &&
		retained_signed.data.bin.rhs == signed_out_of_range,
		"signed comparison of a zero-extended operand against an out-of-range constant must remain wide");
	ir::Inst ordinary_compare = f.graph.decls[6].instructions[(sz)return_value(&f.graph.decls[6])];
	assert(ordinary_compare.tag == ir::InstTag.CMP_EQ,
		"integer cmp_eq(x, 0) must remain an integer equality, not boolean negation");
	f.free();
}

fn void inst_combine_narrows_extended_integer_comparisons_safely() @test
{
	HandIrFixture f;
	f.init();
	Ref zext_lhs = f.builder.add_arg(value_interner::REF_I8);
	Ref zext_rhs = f.builder.add_arg(value_interner::REF_I8);
	f.builder.start_fn();
	Ref left_extended = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = zext_lhs }, value_interner::REF_I32);
	Ref right_extended = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = zext_rhs }, value_interner::REF_I32);
	Ref paired_unsigned = f.builder.add_inst(ir::InstTag.CMP_ULT,
		{ .bin = { left_extended, right_extended } }, value_interner::REF_I1);
	f.builder.add_return(paired_unsigned);
	f.builder.finish_fn("paired_zext_compare");

	Ref narrow = f.builder.add_arg(value_interner::REF_I8);
	Ref threshold = f.add_int_constant(10, value_interner::REF_I32);
	f.builder.start_fn();
	Ref extended = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = narrow }, value_interner::REF_I32);
	Ref reversed = f.builder.add_inst(ir::InstTag.CMP_ULT,
		{ .bin = { threshold, extended } }, value_interner::REF_I1);
	f.builder.add_return(reversed);
	f.builder.finish_fn("zext_on_compare_rhs");

	Ref signed_narrow = f.builder.add_arg(value_interner::REF_I8);
	Ref signed_rhs = f.builder.add_arg(value_interner::REF_I8);
	f.builder.start_fn();
	Ref signed_left = f.builder.add_inst(ir::InstTag.SEXT, { .ref = signed_narrow }, value_interner::REF_I32);
	Ref signed_right = f.builder.add_inst(ir::InstTag.SEXT, { .ref = signed_rhs }, value_interner::REF_I32);
	Ref paired_signed = f.builder.add_inst(ir::InstTag.CMP_SLT,
		{ .bin = { signed_left, signed_right } }, value_interner::REF_I1);
	f.builder.add_return(paired_signed);
	f.builder.finish_fn("paired_sext_compare");

	Ref mixed_lhs = f.builder.add_arg(value_interner::REF_I8);
	Ref mixed_rhs = f.builder.add_arg(value_interner::REF_I8);
	f.builder.start_fn();
	Ref mixed_zext = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = mixed_lhs }, value_interner::REF_I32);
	Ref mixed_sext = f.builder.add_inst(ir::InstTag.SEXT, { .ref = mixed_rhs }, value_interner::REF_I32);
	Ref mixed_compare = f.builder.add_inst(ir::InstTag.CMP_ULT,
		{ .bin = { mixed_zext, mixed_sext } }, value_interner::REF_I1);
	f.builder.add_return(mixed_compare);
	f.builder.finish_fn("mixed_extensions_compare");
	f.run_o1();

	ir::Decl* paired_zext_decl = &f.graph.decls[0];
	ir::Inst narrowed_unsigned = paired_zext_decl.instructions[(sz)return_value(paired_zext_decl)];
	assert(narrowed_unsigned.tag == ir::InstTag.CMP_ULT &&
		narrowed_unsigned.data.bin.lhs == zext_lhs && narrowed_unsigned.data.bin.rhs == zext_rhs,
		"paired zero extensions should compare their original operands with an unsigned predicate");
	ir::Decl* rhs_decl = &f.graph.decls[1];
	ir::Inst normalized_rhs = rhs_decl.instructions[(sz)return_value(rhs_decl)];
	value_interner::InternerRef expected_ten = f.interner.put(primitive_value::int_key(10));
	assert(normalized_rhs.tag == ir::InstTag.CMP_UGT && normalized_rhs.data.bin.lhs == narrow &&
		normalized_rhs.data.bin.rhs != threshold && rhs_decl.instructions[(sz)normalized_rhs.data.bin.rhs].tag == ir::InstTag.CONSTANT &&
		rhs_decl.instructions[(sz)normalized_rhs.data.bin.rhs].data.constant == expected_ten &&
		rhs_decl.instructions[(sz)normalized_rhs.data.bin.rhs].ty == value_interner::REF_I8,
		"a comparison against a zero extension on the right should reverse and narrow the predicate and constant");
	ir::Inst narrowed_signed = f.graph.decls[2].instructions[(sz)return_value(&f.graph.decls[2])];
	assert(narrowed_signed.tag == ir::InstTag.CMP_SLT &&
		narrowed_signed.data.bin.lhs == signed_narrow && narrowed_signed.data.bin.rhs == signed_rhs,
		"paired sign extensions should compare their original operands with a signed predicate");
	ir::Decl* mixed_decl = &f.graph.decls[3];
	ir::Inst retained_mixed = mixed_decl.instructions[(sz)return_value(mixed_decl)];
	assert(retained_mixed.tag == ir::InstTag.CMP_ULT && retained_mixed.data.bin.lhs == mixed_zext &&
		retained_mixed.data.bin.rhs == mixed_sext,
		"mixed zero and sign extensions must retain the original wide comparison");
	f.free();
}

fn void inst_combine_preserves_extended_compare_edge_cases() @test
{
	HandIrFixture f;
	f.init();
	Ref rhs = f.builder.add_arg(value_interner::REF_I8);
	Ref ten = f.add_int_constant(10, value_interner::REF_I32);
	f.builder.start_fn();
	Ref extended_rhs = f.builder.add_inst(ir::InstTag.SEXT, { .ref = rhs }, value_interner::REF_I32);
	Ref rhs_compare = f.builder.add_inst(ir::InstTag.CMP_SLT, { .bin = { ten, extended_rhs } }, value_interner::REF_I1);
	f.builder.add_return(rhs_compare);
	f.builder.finish_fn("sext_compare_rhs");

	Ref rhs_not_fit = f.builder.add_arg(value_interner::REF_I8);
	Ref two_hundred = f.add_int_constant(200, value_interner::REF_I32);
	f.builder.start_fn();
	Ref extended_not_fit = f.builder.add_inst(ir::InstTag.SEXT, { .ref = rhs_not_fit }, value_interner::REF_I32);
	Ref impossible_signed = f.builder.add_inst(ir::InstTag.CMP_SLT,
		{ .bin = { two_hundred, extended_not_fit } }, value_interner::REF_I1);
	f.builder.add_return(impossible_signed);
	f.builder.finish_fn("sext_rhs_out_of_range");

	Ref zero_extended = f.builder.add_arg(value_interner::REF_I8);
	Ref negative = f.add_int_constant(-1, value_interner::REF_I32);
	f.builder.start_fn();
	Ref zext = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = zero_extended }, value_interner::REF_I32);
	Ref signed_gt = f.builder.add_inst(ir::InstTag.CMP_SGT, { .bin = { zext, negative } }, value_interner::REF_I1);
	f.builder.add_return(signed_gt);
	f.builder.finish_fn("zext_signed_gt_negative");

	Ref bit = f.builder.add_arg(value_interner::REF_I1);
	Ref minus_one = f.add_int_constant(-1, value_interner::REF_I32);
	f.builder.start_fn();
	Ref bit_wide = f.builder.add_inst(ir::InstTag.SEXT, { .ref = bit }, value_interner::REF_I32);
	Ref bit_signed = f.builder.add_inst(ir::InstTag.CMP_SLT, { .bin = { bit_wide, minus_one } }, value_interner::REF_I1);
	f.builder.add_return(bit_signed);
	f.builder.finish_fn("sext_i1_signed_constant_compare");

	Ref bit_a = f.builder.add_arg(value_interner::REF_I1);
	Ref bit_b = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref bit_a_wide = f.builder.add_inst(ir::InstTag.SEXT, { .ref = bit_a }, value_interner::REF_I32);
	Ref bit_b_wide = f.builder.add_inst(ir::InstTag.SEXT, { .ref = bit_b }, value_interner::REF_I32);
	Ref paired_bit_signed = f.builder.add_inst(ir::InstTag.CMP_SLT,
		{ .bin = { bit_a_wide, bit_b_wide } }, value_interner::REF_I1);
	f.builder.add_return(paired_bit_signed);
	f.builder.finish_fn("paired_sext_i1_signed_compare");

	Ref signed_rhs = f.builder.add_arg(value_interner::REF_I8);
	Ref unsigned_constant = f.add_int_constant(10, value_interner::REF_I32);
	f.builder.start_fn();
	Ref signed_rhs_wide = f.builder.add_inst(ir::InstTag.SEXT, { .ref = signed_rhs }, value_interner::REF_I32);
	Ref unsigned_compare = f.builder.add_inst(ir::InstTag.CMP_ULT,
		{ .bin = { unsigned_constant, signed_rhs_wide } }, value_interner::REF_I1);
	f.builder.add_return(unsigned_compare);
	f.builder.finish_fn("sext_rhs_unsigned_compare");

	Ref unsigned_a = f.builder.add_arg(value_interner::REF_I8);
	Ref unsigned_b = f.builder.add_arg(value_interner::REF_I8);
	f.builder.start_fn();
	Ref unsigned_a_wide = f.builder.add_inst(ir::InstTag.SEXT, { .ref = unsigned_a }, value_interner::REF_I32);
	Ref unsigned_b_wide = f.builder.add_inst(ir::InstTag.SEXT, { .ref = unsigned_b }, value_interner::REF_I32);
	Ref paired_unsigned_compare = f.builder.add_inst(ir::InstTag.CMP_ULT,
		{ .bin = { unsigned_a_wide, unsigned_b_wide } }, value_interner::REF_I1);
	f.builder.add_return(paired_unsigned_compare);
	f.builder.finish_fn("paired_sext_unsigned_compare");

	Ref max_boundary_arg = f.builder.add_arg(value_interner::REF_I8);
	Ref max_boundary = f.add_int_constant(127, value_interner::REF_I32);
	f.builder.start_fn();
	Ref max_boundary_wide = f.builder.add_inst(ir::InstTag.SEXT, { .ref = max_boundary_arg }, value_interner::REF_I32);
	Ref below_max = f.builder.add_inst(ir::InstTag.CMP_SLT,
		{ .bin = { max_boundary_wide, max_boundary } }, value_interner::REF_I1);
	f.builder.add_return(below_max);
	f.builder.finish_fn("sext_compare_max_boundary");

	Ref min_boundary_arg = f.builder.add_arg(value_interner::REF_I8);
	Ref min_boundary = f.add_int_constant(-128, value_interner::REF_I32);
	f.builder.start_fn();
	Ref min_boundary_wide = f.builder.add_inst(ir::InstTag.SEXT, { .ref = min_boundary_arg }, value_interner::REF_I32);
	Ref above_min = f.builder.add_inst(ir::InstTag.CMP_SGT,
		{ .bin = { min_boundary_wide, min_boundary } }, value_interner::REF_I1);
	f.builder.add_return(above_min);
	f.builder.finish_fn("sext_compare_min_boundary");
	f.run_o1();

	ir::Inst rhs_result = f.graph.decls[0].instructions[(sz)return_value(&f.graph.decls[0])];
	assert(rhs_result.tag == ir::InstTag.CMP_SGT && rhs_result.data.bin.lhs == rhs &&
		rhs_result.data.bin.rhs != ten && f.graph.decls[0].instructions[(sz)rhs_result.data.bin.rhs].ty == value_interner::REF_I8,
		"a fitting signed comparison with an extension on the RHS should reverse and narrow safely");
	assert_returns_int(&f.graph.decls[1], &f.interner, 0, "signed comparison with an out-of-range RHS sign extension");
	ir::Inst signed_gt_result = f.graph.decls[2].instructions[(sz)return_value(&f.graph.decls[2])];
	assert(signed_gt_result.tag == ir::InstTag.CMP_SGT && signed_gt_result.data.bin.lhs == zext &&
		signed_gt_result.data.bin.rhs == negative,
		"signed greater-than against a negative constant must remain wide for a zero-extended operand");
	ir::Inst bit_result = f.graph.decls[3].instructions[(sz)return_value(&f.graph.decls[3])];
	assert(bit_result.tag == ir::InstTag.CMP_SLT && bit_result.data.bin.lhs == bit_wide && bit_result.data.bin.rhs == minus_one,
		"signed compares of a sign-extended i1 must remain wide");
	ir::Inst paired_result = f.graph.decls[4].instructions[(sz)return_value(&f.graph.decls[4])];
	assert(paired_result.tag == ir::InstTag.CMP_SLT && paired_result.data.bin.lhs == bit_a_wide && paired_result.data.bin.rhs == bit_b_wide,
		"paired sign-extended i1 signed compares must remain wide");
	ir::Inst unsigned_result = f.graph.decls[5].instructions[(sz)return_value(&f.graph.decls[5])];
	assert(unsigned_result.tag == ir::InstTag.CMP_UGT && unsigned_result.data.bin.lhs == signed_rhs &&
		is_int_constant(&f.graph.decls[5], unsigned_result.data.bin.rhs, &f.interner, 10),
		"unsigned comparisons against a fitting sign-extended value should narrow safely");
	ir::Inst paired_unsigned_result = f.graph.decls[6].instructions[(sz)return_value(&f.graph.decls[6])];
	assert(paired_unsigned_result.tag == ir::InstTag.CMP_ULT && paired_unsigned_result.data.bin.lhs == unsigned_a &&
		paired_unsigned_result.data.bin.rhs == unsigned_b,
		"paired sign-extended values should preserve unsigned ordering when narrowed");
	ir::Inst max_boundary_result = f.graph.decls[7].instructions[(sz)return_value(&f.graph.decls[7])];
	assert(max_boundary_result.tag == ir::InstTag.CMP_SLT && max_boundary_result.data.bin.lhs == max_boundary_arg &&
		f.graph.decls[7].instructions[(sz)max_boundary_result.data.bin.rhs].ty == value_interner::REF_I8,
		"the maximum signed source value should be accepted at the narrowing boundary");
	ir::Inst min_boundary_result = f.graph.decls[8].instructions[(sz)return_value(&f.graph.decls[8])];
	assert(min_boundary_result.tag == ir::InstTag.CMP_SGT && min_boundary_result.data.bin.lhs == min_boundary_arg &&
		f.graph.decls[8].instructions[(sz)min_boundary_result.data.bin.rhs].ty == value_interner::REF_I8,
		"the minimum signed source value should be accepted at the narrowing boundary");
	f.free();
}

fn void inst_combine_reassociates_boolean_wide_and_odd_width_integers() @test
{
	HandIrFixture f;
	f.init();
	Ref bool_arg = f.builder.add_arg(value_interner::REF_I1);
	Ref bool_one_a = f.add_int_constant(1, value_interner::REF_I1);
	Ref bool_one_b = f.add_int_constant(1, value_interner::REF_I1);
	f.builder.start_fn();
	Ref bool_sub = f.builder.add_inst(ir::InstTag.SUB, { .bin = { bool_arg, bool_one_a } }, value_interner::REF_I1);
	Ref bool_sub_again = f.builder.add_inst(ir::InstTag.SUB, { .bin = { bool_sub, bool_one_b } }, value_interner::REF_I1);
	f.builder.add_return(bool_sub_again);
	f.builder.finish_fn("i1_sub_reassociate");

	Ref wide_arg = f.builder.add_arg(value_interner::REF_I64);
	Ref wide_max_a = f.add_int_constant(long::max, value_interner::REF_I64);
	Ref wide_one = f.add_int_constant(1, value_interner::REF_I64);
	f.builder.start_fn();
	Ref wide_add = f.builder.add_inst(ir::InstTag.ADD, { .bin = { wide_arg, wide_max_a } }, value_interner::REF_I64);
	Ref wide_add_again = f.builder.add_inst(ir::InstTag.ADD, { .bin = { wide_add, wide_one } }, value_interner::REF_I64);
	f.builder.add_return(wide_add_again);
	f.builder.finish_fn("i64_add_boundary_reassociate");

	value_interner::InternerRef i17 = f.interner.put({ .tag = primitive_value::PrimitiveType.INT_TY, .ty_bits = 17 });
	Ref exact_i17_add_a = f.add_int_constant(0x1ffff, i17);
	Ref exact_i17_add_b = f.add_int_constant(2, i17);
	Ref exact_i17_add_arg = f.builder.add_arg(i17);
	f.builder.start_fn();
	Ref exact_i17_add = f.builder.add_inst(ir::InstTag.ADD, { .bin = { exact_i17_add_arg, exact_i17_add_a } }, i17);
	Ref exact_i17_add_again = f.builder.add_inst(ir::InstTag.ADD, { .bin = { exact_i17_add, exact_i17_add_b } }, i17);
	f.builder.add_return(exact_i17_add_again);
	f.builder.finish_fn("i17_add_requested_boundaries");
	Ref exact_i17_mask_a = f.add_int_constant(0x1f0f0, i17);
	Ref exact_i17_mask_b = f.add_int_constant(0x0ffff, i17);
	Ref exact_i17_mask_arg = f.builder.add_arg(i17);
	f.builder.start_fn();
	Ref exact_i17_and = f.builder.add_inst(ir::InstTag.BIT_AND, { .bin = { exact_i17_mask_arg, exact_i17_mask_a } }, i17);
	Ref exact_i17_and_again = f.builder.add_inst(ir::InstTag.BIT_AND, { .bin = { exact_i17_and, exact_i17_mask_b } }, i17);
	f.builder.add_return(exact_i17_and_again);
	f.builder.finish_fn("i17_and_requested_masks");
	value_interner::InternerRef i3 = f.interner.put({ .tag = primitive_value::PrimitiveType.INT_TY, .ty_bits = 3 });
	Ref exact_i3_mul_arg = f.builder.add_arg(i3);
	Ref exact_i3_mul_a = f.add_int_constant(3, i3);
	Ref exact_i3_mul_b = f.add_int_constant(3, i3);
	f.builder.start_fn();
	Ref exact_i3_mul = f.builder.add_inst(ir::InstTag.MUL, { .bin = { exact_i3_mul_arg, exact_i3_mul_a } }, i3);
	Ref exact_i3_mul_again = f.builder.add_inst(ir::InstTag.MUL, { .bin = { exact_i3_mul, exact_i3_mul_b } }, i3);
	f.builder.add_return(exact_i3_mul_again);
	f.builder.finish_fn("i3_mul_requested_boundary");
	Ref exact_i17_sub_one = f.add_int_constant(1, i17);
	Ref exact_i17_sub_arg = f.builder.add_arg(i17);
	f.builder.start_fn();
	Ref exact_i17_sub = f.builder.add_inst(ir::InstTag.SUB, { .bin = { exact_i17_sub_arg, exact_i17_sub_one } }, i17);
	f.builder.add_return(exact_i17_sub);
	f.builder.finish_fn("i17_sub_requested_boundary");
	Ref exact_i3_add_a = f.add_int_constant(5, i3);
	Ref exact_i3_add_b = f.add_int_constant(6, i3);
	Ref exact_i3_add_arg = f.builder.add_arg(i3);
	f.builder.start_fn();
	Ref exact_i3_add = f.builder.add_inst(ir::InstTag.ADD, { .bin = { exact_i3_add_arg, exact_i3_add_a } }, i3);
	Ref exact_i3_add_again = f.builder.add_inst(ir::InstTag.ADD, { .bin = { exact_i3_add, exact_i3_add_b } }, i3);
	f.builder.add_return(exact_i3_add_again);
	f.builder.finish_fn("i3_add_requested_boundary");
	f.run_o1();

	ir::Decl* bool_decl = &f.graph.decls[0];
	ir::Ref bool_return = return_value(bool_decl);
	assert(bool_return == bool_arg || (bool_decl.instructions[(sz)bool_return].tag == ir::InstTag.ADD &&
		(is_int_constant(bool_decl, bool_decl.instructions[(sz)bool_return].data.bin.lhs, &f.interner, 0) ||
		is_int_constant(bool_decl, bool_decl.instructions[(sz)bool_return].data.bin.rhs, &f.interner, 0))),
		"i1 subtraction reassociation should wrap its combined constant to zero");
	assert_returns_bin_with_constant(&f.graph.decls[1], ir::InstTag.ADD, &f.interner, long::min, "i64 wrapping addition boundary");
	assert_returns_bin_with_constant(&f.graph.decls[2], ir::InstTag.ADD, &f.interner, 1, "i17 addition of 0x1ffff and 2");
	assert_returns_bin_with_constant(&f.graph.decls[3], ir::InstTag.BIT_AND, &f.interner, 0xf0f0, "i17 masks 0x1f0f0 and 0x0ffff");
	assert(return_value(&f.graph.decls[4]) == exact_i3_mul_arg,
		"(a * 3) * 3 in i3 should reduce to a modulo eight");
	ir::Inst reduced_sub_one = f.graph.decls[5].instructions[(sz)return_value(&f.graph.decls[5])];
	assert(reduced_sub_one.tag == ir::InstTag.ADD && reduced_sub_one.data.bin.lhs == exact_i17_sub_arg &&
		is_int_constant(&f.graph.decls[5], reduced_sub_one.data.bin.rhs, &f.interner, -1),
		"sub a, 1 at i17 should become add a with the interned int_key(-1) constant");
	ir::Inst reduced_add_i3 = f.graph.decls[6].instructions[(sz)return_value(&f.graph.decls[6])];
	assert(reduced_add_i3.tag == ir::InstTag.ADD && reduced_add_i3.data.bin.lhs == exact_i3_add_arg &&
		is_int_constant(&f.graph.decls[6], reduced_add_i3.data.bin.rhs, &f.interner, 3),
		"(a + 5) + 6 at i3 should wrap to add a, 3");
	f.free();
}

fn void inst_combine_keeps_ordered_float_compare_semantics() @test
{
	HandIrFixture f;
	f.init();
	Ref lhs = f.builder.add_arg(value_interner::REF_F64);
	Ref rhs = f.builder.add_arg(value_interner::REF_F64);
	Ref zero = f.add_int_constant(0, value_interner::REF_I1);
	f.builder.start_fn();
	Ref ordered = f.builder.add_inst(ir::InstTag.FCMP_OLT, { .bin = { lhs, rhs } }, value_interner::REF_I1);
	Ref inverted = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { ordered, zero } }, value_interner::REF_I1);
	f.builder.add_return(inverted);
	f.builder.finish_fn("ordered_float_not");

	Ref branch_lhs = f.builder.add_arg(value_interner::REF_F64);
	Ref branch_rhs = f.builder.add_arg(value_interner::REF_F64);
	Ref branch_zero = f.add_int_constant(0, value_interner::REF_I1);
	f.builder.start_fn();
	Ref branch_ordered = f.builder.add_inst(ir::InstTag.FCMP_OLT, { .bin = { branch_lhs, branch_rhs } }, value_interner::REF_I1);
	Ref branch_inverted = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { branch_ordered, branch_zero } }, value_interner::REF_I1);
	Ref yes = f.builder.make_label("yes");
	Ref no = f.builder.make_label("no");
	f.builder.add_branch(branch_inverted, yes, no);
	f.builder.start_block(yes);
	f.builder.add_return(branch_lhs);
	f.builder.start_block(no);
	f.builder.add_return(branch_rhs);
	f.builder.finish_fn("ordered_float_branch");

	Ref select_lhs = f.builder.add_arg(value_interner::REF_F64);
	Ref select_rhs = f.builder.add_arg(value_interner::REF_F64);
	Ref select_zero = f.add_int_constant(0, value_interner::REF_I1);
	f.builder.start_fn();
	Ref select_ordered = f.builder.add_inst(ir::InstTag.FCMP_OLT,
		{ .bin = { select_lhs, select_rhs } }, value_interner::REF_I1);
	Ref select_inverted = f.builder.add_inst(ir::InstTag.CMP_EQ,
		{ .bin = { select_ordered, select_zero } }, value_interner::REF_I1);
	Ref selected = f.builder.add_select(select_inverted, select_lhs, select_rhs, value_interner::REF_F64);
	f.builder.add_return(selected);
	f.builder.finish_fn("ordered_float_select");
	f.run_o1();
	ir::Decl* bool_decl = &f.graph.decls[0];
	ir::Inst returned_bool = bool_decl.instructions[(sz)return_value(bool_decl)];
	assert(returned_bool.tag == ir::InstTag.CMP_EQ,
		"ordered float comparison under integer equality-to-zero must not become an unordered float comparison");
	ir::Decl* decl = &f.graph.decls[1];
	bool saw_swapped_branch = false;
	foreach (ref : decl.body)
	{
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.BRANCH && inst.data.branch.cond == branch_ordered &&
			inst.data.branch.then_label == no && inst.data.branch.else_label == yes) saw_swapped_branch = true;
	}
	assert(saw_swapped_branch, "branching on ordered comparison inversion should swap successors while preserving the ordered compare");
	ir::Decl* select_decl = &f.graph.decls[2];
	ir::Inst selected_value = select_decl.instructions[(sz)return_value(select_decl)];
	assert(selected_value.tag == ir::InstTag.SELECT && selected_value.data.branch.cond == select_ordered &&
		selected_value.data.branch.then_label == select_rhs && selected_value.data.branch.else_label == select_lhs,
		"an inverted ordered float select should swap its arms while retaining the ordered predicate for NaN behavior");
	f.free();
}

fn void inst_combine_covers_boolean_and_float_compare_edges() @test
{
	HandIrFixture f;
	f.init();
	Ref bit = f.builder.add_arg(value_interner::REF_I1);
	Ref one = f.add_int_constant(1, value_interner::REF_I32);
	f.builder.start_fn();
	Ref widened = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = bit }, value_interner::REF_I32);
	Ref eq_one = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { widened, one } }, value_interner::REF_I1);
	f.builder.add_return(eq_one);
	f.builder.finish_fn("zext_i1_eq_one");

	Ref bit2 = f.builder.add_arg(value_interner::REF_I1);
	Ref two = f.add_int_constant(2, value_interner::REF_I32);
	f.builder.start_fn();
	Ref widened2 = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = bit2 }, value_interner::REF_I32);
	Ref ugt_two = f.builder.add_inst(ir::InstTag.CMP_UGT, { .bin = { widened2, two } }, value_interner::REF_I1);
	f.builder.add_return(ugt_two);
	f.builder.finish_fn("zext_i1_ugt_two");

	Ref bit3 = f.builder.add_arg(value_interner::REF_I1);
	Ref minus_one = f.add_int_constant(-1, value_interner::REF_I32);
	f.builder.start_fn();
	Ref signed_wide = f.builder.add_inst(ir::InstTag.SEXT, { .ref = bit3 }, value_interner::REF_I32);
	Ref eq_minus_one = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { signed_wide, minus_one } }, value_interner::REF_I1);
	f.builder.add_return(eq_minus_one);
	f.builder.finish_fn("sext_i1_eq_minus_one");

	Ref bit4 = f.builder.add_arg(value_interner::REF_I1);
	Ref xor_one_a = f.add_int_constant(1, value_interner::REF_I1);
	Ref xor_one_b = f.add_int_constant(1, value_interner::REF_I1);
	f.builder.start_fn();
	Ref xor_once = f.builder.add_inst(ir::InstTag.BIT_XOR, { .bin = { bit4, xor_one_a } }, value_interner::REF_I1);
	Ref xor_twice = f.builder.add_inst(ir::InstTag.BIT_XOR, { .bin = { xor_once, xor_one_b } }, value_interner::REF_I1);
	f.builder.add_return(xor_twice);
	f.builder.finish_fn("bool_xor_one_twice");

	Ref float_a = f.builder.add_arg(value_interner::REF_F64);
	Ref float_b = f.builder.add_arg(value_interner::REF_F64);
	Ref bool_zero = f.add_int_constant(0, value_interner::REF_I1);
	f.builder.start_fn();
	Ref une = f.builder.add_inst(ir::InstTag.FCMP_UNE, { .bin = { float_a, float_b } }, value_interner::REF_I1);
	Ref une_not = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { une, bool_zero } }, value_interner::REF_I1);
	f.builder.add_return(une_not);
	f.builder.finish_fn("invert_float_une");

	Ref float_same = f.builder.add_arg(value_interner::REF_F64);
	f.builder.start_fn();
	Ref same_oeq = f.builder.add_inst(ir::InstTag.FCMP_OEQ, { .bin = { float_same, float_same } }, value_interner::REF_I1);
	f.builder.add_return(same_oeq);
	f.builder.finish_fn("fcmp_oeq_same_operand");

	Ref bit_eq_two = f.builder.add_arg(value_interner::REF_I1);
	Ref two_for_eq = f.add_int_constant(2, value_interner::REF_I32);
	f.builder.start_fn();
	Ref eq_two_wide = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = bit_eq_two }, value_interner::REF_I32);
	Ref eq_two = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { eq_two_wide, two_for_eq } }, value_interner::REF_I1);
	f.builder.add_return(eq_two);
	f.builder.finish_fn("zext_i1_eq_two");

	Ref float_ne_a = f.builder.add_arg(value_interner::REF_F64);
	Ref float_ne_b = f.builder.add_arg(value_interner::REF_F64);
	Ref bool_one = f.add_int_constant(1, value_interner::REF_I1);
	f.builder.start_fn();
	Ref equal_ordered = f.builder.add_inst(ir::InstTag.FCMP_OEQ, { .bin = { float_ne_a, float_ne_b } }, value_interner::REF_I1);
	Ref not_equal_ordered = f.builder.add_inst(ir::InstTag.CMP_NE,
		{ .bin = { equal_ordered, bool_one } }, value_interner::REF_I1);
	f.builder.add_return(not_equal_ordered);
	f.builder.finish_fn("cmp_ne_fcmp_oeq_one");

	Ref select_a = f.builder.add_arg(value_interner::REF_F64);
	Ref select_b = f.builder.add_arg(value_interner::REF_F64);
	Ref select_zero = f.add_int_constant(0, value_interner::REF_I1);
	Ref select_one = f.add_int_constant(1, value_interner::REF_I1);
	f.builder.start_fn();
	Ref select_equal = f.builder.add_inst(ir::InstTag.FCMP_OEQ, { .bin = { select_a, select_b } }, value_interner::REF_I1);
	Ref select = f.builder.add_select(select_equal, select_zero, select_one, value_interner::REF_I1);
	f.builder.add_return(select);
	f.builder.finish_fn("select_fcmp_oeq_zero_one");
	f.run_o1();

	assert(return_value(&f.graph.decls[0]) == bit, "zext i1 equality with one should return the source bit");
	ir::Inst folded_ugt_two = f.graph.decls[1].instructions[(sz)return_value(&f.graph.decls[1])];
	assert(folded_ugt_two.tag == ir::InstTag.CONSTANT &&
		folded_ugt_two.data.constant == value_interner::REF_ZERO,
		"zext i1 unsigned greater-than two should use the canonical zero constant");
	assert(return_value(&f.graph.decls[2]) == bit3, "sext i1 equality with minus one should return the source bit");
	assert(return_value(&f.graph.decls[3]) == bit4, "two XORs with one should return the original bit");
	ir::Inst inverted_une = f.graph.decls[4].instructions[(sz)return_value(&f.graph.decls[4])];
	assert(inverted_une.tag == ir::InstTag.FCMP_OEQ && inverted_une.data.bin.lhs == float_a && inverted_une.data.bin.rhs == float_b,
		"integer negation of fcmp_une should become its exact fcmp_oeq inverse");
	ir::Inst same_result = f.graph.decls[5].instructions[(sz)return_value(&f.graph.decls[5])];
	assert(same_result.tag == ir::InstTag.FCMP_OEQ && same_result.data.bin.lhs == float_same && same_result.data.bin.rhs == float_same,
		"fcmp_oeq(x, x) should remain unfurled to preserve NaN behavior");
	ir::Inst folded_eq_two = f.graph.decls[6].instructions[(sz)return_value(&f.graph.decls[6])];
	assert(folded_eq_two.tag == ir::InstTag.CONSTANT && folded_eq_two.data.constant == value_interner::REF_ZERO,
		"zext i1 equality with two should fold to false");
	ir::Inst inverted_oeq = f.graph.decls[7].instructions[(sz)return_value(&f.graph.decls[7])];
	assert(inverted_oeq.tag == ir::InstTag.FCMP_UNE && inverted_oeq.data.bin.lhs == float_ne_a &&
		inverted_oeq.data.bin.rhs == float_ne_b,
		"cmp_ne(fcmp_oeq, 1) should become fcmp_une");
	ir::Inst select_une = f.graph.decls[8].instructions[(sz)return_value(&f.graph.decls[8])];
	assert(select_une.tag == ir::InstTag.FCMP_UNE && select_une.data.bin.lhs == select_a &&
		select_une.data.bin.rhs == select_b,
		"select(fcmp_oeq, 0, 1) should become fcmp_une");
	f.free();
}

fn void inst_combine_preserves_cast_and_integer_wrap_edges() @test
{
	HandIrFixture f;
	f.init();
	Ref negative = f.add_int_constant(-1, value_interner::REF_I16);
	f.builder.start_fn();
	Ref truncated = f.builder.add_inst(ir::InstTag.TRUNC, { .ref = negative }, value_interner::REF_I8);
	Ref widened = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = truncated }, value_interner::REF_I32);
	f.builder.add_return(widened);
	f.builder.finish_fn("zext_negative_trunc");

	Ref roundtrip_arg = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref roundtrip_trunc = f.builder.add_inst(ir::InstTag.TRUNC, { .ref = roundtrip_arg }, value_interner::REF_I8);
	Ref roundtrip_zext = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = roundtrip_trunc }, value_interner::REF_I32);
	f.builder.add_return(roundtrip_zext);
	f.builder.finish_fn("zext_trunc_i32_i8_i32");

	Ref wide_arg = f.builder.add_arg(value_interner::REF_I64);
	value_interner::InternerRef i128 = f.interner.put({ .tag = primitive_value::PrimitiveType.INT_TY, .ty_bits = 128 });
	f.builder.start_fn();
	Ref wide_zext = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = wide_arg }, i128);
	Ref wide_trunc = f.builder.add_inst(ir::InstTag.TRUNC, { .ref = wide_zext }, value_interner::REF_I64);
	f.builder.add_return(wide_trunc);
	f.builder.finish_fn("zext_i64_i128_trunc_i64");

	Ref mul_arg = f.builder.add_arg(value_interner::REF_I64);
	Ref mul_max = f.add_int_constant(long::max, value_interner::REF_I64);
	Ref mul_two = f.add_int_constant(2, value_interner::REF_I64);
	f.builder.start_fn();
	Ref mul_inner = f.builder.add_inst(ir::InstTag.MUL, { .bin = { mul_arg, mul_max } }, value_interner::REF_I64);
	Ref mul_again = f.builder.add_inst(ir::InstTag.MUL, { .bin = { mul_inner, mul_two } }, value_interner::REF_I64);
	f.builder.add_return(mul_again);
	f.builder.finish_fn("i64_mul_wrap_reassociate");

	Ref negative_i64 = f.add_int_constant(-1, value_interner::REF_I64);
	f.builder.start_fn();
	Ref negative_wide = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = negative_i64 }, i128);
	Ref negative_narrow = f.builder.add_inst(ir::InstTag.TRUNC, { .ref = negative_wide }, value_interner::REF_I64);
	f.builder.add_return(negative_narrow);
	f.builder.finish_fn("zext_negative_i64_to_i128_trunc");

	Ref negative_i32 = f.add_int_constant(-1, value_interner::REF_I32);
	f.builder.start_fn();
	Ref negative_i32_trunc = f.builder.add_inst(ir::InstTag.TRUNC, { .ref = negative_i32 }, value_interner::REF_I8);
	Ref negative_i32_zext = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = negative_i32_trunc }, value_interner::REF_I32);
	f.builder.add_return(negative_i32_zext);
	f.builder.finish_fn("zext_negative_i32_trunc_i8");

	Ref i32_arg = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref i128_zext = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = i32_arg }, i128);
	Ref i8_trunc = f.builder.add_inst(ir::InstTag.TRUNC, { .ref = i128_zext }, value_interner::REF_I8);
	f.builder.add_return(i8_trunc);
	f.builder.finish_fn("trunc_zext_i32_i128_i8");

	Ref mul_edge_arg = f.builder.add_arg(value_interner::REF_I64);
	Ref mul_edge_a = f.add_int_constant(0x1_0000_0001, value_interner::REF_I64);
	Ref mul_edge_b = f.add_int_constant(0xFFFF_FFFF, value_interner::REF_I64);
	f.builder.start_fn();
	Ref mul_edge_inner = f.builder.add_inst(ir::InstTag.MUL,
		{ .bin = { mul_edge_arg, mul_edge_a } }, value_interner::REF_I64);
	Ref mul_edge_again = f.builder.add_inst(ir::InstTag.MUL,
		{ .bin = { mul_edge_inner, mul_edge_b } }, value_interner::REF_I64);
	f.builder.add_return(mul_edge_again);
	f.builder.finish_fn("i64_mul_modular_product");
	f.run_o1();

	assert_returns_int(&f.graph.decls[0], &f.interner, 255, "zext of a negative value truncated to i8");
	ir::Decl* roundtrip_decl = &f.graph.decls[1];
	ir::Inst retained_roundtrip = roundtrip_decl.instructions[(sz)return_value(roundtrip_decl)];
	assert(retained_roundtrip.tag == ir::InstTag.ZEXT &&
		roundtrip_decl.instructions[(sz)retained_roundtrip.data.ref].tag == ir::InstTag.TRUNC &&
		roundtrip_decl.instructions[(sz)retained_roundtrip.data.ref].data.ref == roundtrip_arg,
		"zext(trunc(i32 to i8)) back to i32 must remain unchanged");
	assert(return_value(&f.graph.decls[2]) == wide_arg,
		"zext to i128 followed by truncation back to i64 should return the original value");
	ir::Inst wrapped_mul = f.graph.decls[3].instructions[(sz)return_value(&f.graph.decls[3])];
	assert(wrapped_mul.tag == ir::InstTag.MUL &&
		((wrapped_mul.data.bin.lhs == mul_arg && is_int_constant(&f.graph.decls[3], wrapped_mul.data.bin.rhs, &f.interner, -2)) ||
		(wrapped_mul.data.bin.rhs == mul_arg && is_int_constant(&f.graph.decls[3], wrapped_mul.data.bin.lhs, &f.interner, -2))),
		"i64 multiplication by INT64_MAX and 2 should wrap to the exact coefficient -2");
	assert_returns_int(&f.graph.decls[4], &f.interner, -1, "zext of negative i64 to i128 followed by truncation");
	assert_returns_int(&f.graph.decls[5], &f.interner, 255,
		"zext(trunc(-1:i32 to i8)) should produce the zero-extended i8 value");
	ir::Inst narrow_trunc = f.graph.decls[6].instructions[(sz)return_value(&f.graph.decls[6])];
	assert(narrow_trunc.tag == ir::InstTag.TRUNC &&
		f.graph.decls[6].instructions[(sz)narrow_trunc.data.ref].tag == ir::InstTag.ZEXT &&
		f.graph.decls[6].instructions[(sz)narrow_trunc.data.ref].data.ref == i32_arg,
		"trunc(zext(i32 to i128), i8) must remain an explicit cast pair");
	ir::Inst wrapped_edge_mul = f.graph.decls[7].instructions[(sz)return_value(&f.graph.decls[7])];
	assert(wrapped_edge_mul.tag == ir::InstTag.MUL &&
		((wrapped_edge_mul.data.bin.lhs == mul_edge_arg &&
			is_int_constant(&f.graph.decls[7], wrapped_edge_mul.data.bin.rhs, &f.interner, -1)) ||
		(wrapped_edge_mul.data.bin.rhs == mul_edge_arg &&
			is_int_constant(&f.graph.decls[7], wrapped_edge_mul.data.bin.lhs, &f.interner, -1))),
		"(a * 0x1_0000_0001) * 0xFFFF_FFFF should wrap to a * -1");
	f.free();
}

fn void inst_combine_keeps_nonfitting_reversed_zero_extension_compare() @test
{
	HandIrFixture f;
	f.init();
	Ref narrow = f.builder.add_arg(value_interner::REF_I8);
	Ref three_hundred = f.add_int_constant(300, value_interner::REF_I32);
	f.builder.start_fn();
	Ref extended = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = narrow }, value_interner::REF_I32);
	Ref impossible = f.builder.add_inst(ir::InstTag.CMP_ULTE,
		{ .bin = { three_hundred, extended } }, value_interner::REF_I1);
	f.builder.add_return(impossible);
	f.builder.finish_fn("cmp_ulte_300_zext_i8");

	Ref narrow_upper = f.builder.add_arg(value_interner::REF_I8);
	Ref two_fifty_six = f.add_int_constant(256, value_interner::REF_I32);
	f.builder.start_fn();
	Ref upper_extended = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = narrow_upper }, value_interner::REF_I32);
	Ref always_less = f.builder.add_inst(ir::InstTag.CMP_ULT,
		{ .bin = { upper_extended, two_fifty_six } }, value_interner::REF_I1);
	f.builder.add_return(always_less);
	f.builder.finish_fn("cmp_ult_zext_i8_upper_boundary");
	f.run_o1();
	assert_returns_int(&f.graph.decls[0], &f.interner, 0, "nonfitting reversed unsigned comparison against zext i8");
	assert_returns_int(&f.graph.decls[1], &f.interner, 1, "unsigned comparison at the first constant above the zext i8 range");
	f.free();
}

fn void inst_combine_preserves_signed_i1_compare_with_zero() @test
{
	HandIrFixture f;
	f.init();
	Ref bit = f.builder.add_arg(value_interner::REF_I1);
	Ref zero = f.add_int_constant(0, value_interner::REF_I32);
	f.builder.start_fn();
	Ref extended = f.builder.add_inst(ir::InstTag.SEXT, { .ref = bit }, value_interner::REF_I32);
	Ref compare = f.builder.add_inst(ir::InstTag.CMP_SLT, { .bin = { extended, zero } }, value_interner::REF_I1);
	f.builder.add_return(compare);
	f.builder.finish_fn("sext_i1_slt_zero");
	f.run_o1();
	ir::Inst result = f.graph.decls[0].instructions[(sz)return_value(&f.graph.decls[0])];
	assert(result.tag == ir::InstTag.CMP_SLT && result.data.bin.lhs == extended && result.data.bin.rhs == zero,
		"signed less-than of sign-extended i1 against zero must remain wide");
	f.free();
}

fn void inst_combine_covers_i1_unsigned_greater_than_zero_and_subtraction() @test
{
	HandIrFixture f;
	f.init();
	Ref bit = f.builder.add_arg(value_interner::REF_I1);
	Ref zero = f.builder.add_constant(value_interner::REF_ZERO, value_interner::REF_I32);
	f.builder.start_fn();
	Ref extended = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = bit }, value_interner::REF_I32);
	Ref compare = f.builder.add_inst(ir::InstTag.CMP_UGT, { .bin = { extended, zero } }, value_interner::REF_I1);
	f.builder.add_return(compare);
	f.builder.finish_fn("zext_i1_ugt_zero");

	Ref sub_arg = f.builder.add_arg(value_interner::REF_I1);
	Ref one = f.builder.add_constant(value_interner::REF_ONE, value_interner::REF_I1);
	f.builder.start_fn();
	Ref sub = f.builder.add_inst(ir::InstTag.SUB, { .bin = { sub_arg, one } }, value_interner::REF_I1);
	f.builder.add_return(sub);
	f.builder.finish_fn("i1_sub_one");
	f.run_o1();

	ir::Inst narrowed = f.graph.decls[0].instructions[(sz)return_value(&f.graph.decls[0])];
	assert(narrowed.tag == ir::InstTag.CMP_UGT && narrowed.data.bin.lhs == bit &&
		f.graph.decls[0].instructions[(sz)narrowed.data.bin.rhs].tag == ir::InstTag.CONSTANT &&
		f.graph.decls[0].instructions[(sz)narrowed.data.bin.rhs].data.constant == value_interner::REF_ZERO,
		"cmp_ugt(zext i1, 0) should narrow with the canonical zero constant");
	ir::Inst reassociated = f.graph.decls[1].instructions[(sz)return_value(&f.graph.decls[1])];
	assert(reassociated.tag == ir::InstTag.ADD && reassociated.data.bin.lhs == sub_arg &&
		f.graph.decls[1].instructions[(sz)reassociated.data.bin.rhs].tag == ir::InstTag.CONSTANT &&
		f.graph.decls[1].instructions[(sz)reassociated.data.bin.rhs].data.constant == value_interner::REF_ONE,
		"sub b:i1, 1 should become ADD with canonical REF_ONE");
	f.free();
}

fn void inst_combine_covers_i64_extension_compare_boundaries() @test
{
	HandIrFixture f;
	f.init();
	Ref zext_arg = f.builder.add_arg(value_interner::REF_I32);
	Ref zext_max = f.add_int_constant(4294967295, value_interner::REF_I64);
	f.builder.start_fn();
	Ref zext = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = zext_arg }, value_interner::REF_I64);
	Ref zext_eq = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { zext, zext_max } }, value_interner::REF_I1);
	f.builder.add_return(zext_eq);
	f.builder.finish_fn("zext_i32_i64_eq_uint_max");

	Ref zext_out_arg = f.builder.add_arg(value_interner::REF_I32);
	Ref beyond_uint = f.add_int_constant(4294967296, value_interner::REF_I64);
	f.builder.start_fn();
	Ref zext_out = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = zext_out_arg }, value_interner::REF_I64);
	Ref zext_out_eq = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { zext_out, beyond_uint } }, value_interner::REF_I1);
	f.builder.add_return(zext_out_eq);
	f.builder.finish_fn("zext_i32_i64_eq_out_of_range");

	Ref sext_arg = f.builder.add_arg(value_interner::REF_I32);
	Ref signed_min = f.add_int_constant(-2147483648, value_interner::REF_I64);
	f.builder.start_fn();
	Ref sext = f.builder.add_inst(ir::InstTag.SEXT, { .ref = sext_arg }, value_interner::REF_I64);
	Ref sext_eq = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { sext, signed_min } }, value_interner::REF_I1);
	f.builder.add_return(sext_eq);
	f.builder.finish_fn("sext_i32_i64_eq_int_min");

	Ref sext_out_arg = f.builder.add_arg(value_interner::REF_I32);
	Ref beyond_signed = f.add_int_constant(2147483648, value_interner::REF_I64);
	f.builder.start_fn();
	Ref sext_out = f.builder.add_inst(ir::InstTag.SEXT, { .ref = sext_out_arg }, value_interner::REF_I64);
	Ref sext_out_eq = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { sext_out, beyond_signed } }, value_interner::REF_I1);
	f.builder.add_return(sext_out_eq);
	f.builder.finish_fn("sext_i32_i64_eq_out_of_range");

	Ref slt_min_arg = f.builder.add_arg(value_interner::REF_I32);
	Ref slt_min = f.add_int_constant(-2147483648, value_interner::REF_I64);
	f.builder.start_fn();
	Ref slt_min_wide = f.builder.add_inst(ir::InstTag.SEXT, { .ref = slt_min_arg }, value_interner::REF_I64);
	Ref slt_min_compare = f.builder.add_inst(ir::InstTag.CMP_SLT,
		{ .bin = { slt_min_wide, slt_min } }, value_interner::REF_I1);
	f.builder.add_return(slt_min_compare);
	f.builder.finish_fn("sext_i32_i64_slt_int_min");
	f.run_o1();

	ir::Inst zext_result = f.graph.decls[0].instructions[(sz)return_value(&f.graph.decls[0])];
	assert(zext_result.tag == ir::InstTag.CMP_EQ && zext_result.data.bin.lhs == zext_arg &&
		is_int_constant(&f.graph.decls[0], zext_result.data.bin.rhs, &f.interner, -1),
		"zext i32 compared with i64 0xffffffff should narrow to equality with i32 -1");
	assert_returns_int(&f.graph.decls[1], &f.interner, 0, "zext i32 compared with i64 0x1_0000_0000");
	ir::Inst sext_result = f.graph.decls[2].instructions[(sz)return_value(&f.graph.decls[2])];
	assert(sext_result.tag == ir::InstTag.CMP_EQ && sext_result.data.bin.lhs == sext_arg &&
		is_int_constant(&f.graph.decls[2], sext_result.data.bin.rhs, &f.interner, -2147483648),
		"sext i32 compared with INT32_MIN should narrow to an i32 comparison");
	assert_returns_int(&f.graph.decls[3], &f.interner, 0, "sext i32 compared with 2147483648");
	ir::Inst slt_min_result = f.graph.decls[4].instructions[(sz)return_value(&f.graph.decls[4])];
	assert(slt_min_result.tag == ir::InstTag.CMP_SLT && slt_min_result.data.bin.lhs == slt_min_arg &&
		is_int_constant(&f.graph.decls[4], slt_min_result.data.bin.rhs, &f.interner, -2147483648),
		"cmp_slt(sext i32 to i64, INT32_MIN) should narrow to the signed i32 comparison");
	f.free();
}

fn void inst_combine_covers_requested_sext_compare_boundaries() @test
{
	HandIrFixture f;
	f.init();
	Ref eq_arg = f.builder.add_arg(value_interner::REF_I8);
	Ref two_hundred = f.add_int_constant(200, value_interner::REF_I32);
	f.builder.start_fn();
	Ref eq_wide = f.builder.add_inst(ir::InstTag.SEXT, { .ref = eq_arg }, value_interner::REF_I32);
	Ref eq_compare = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { eq_wide, two_hundred } }, value_interner::REF_I1);
	f.builder.add_return(eq_compare);
	f.builder.finish_fn("sext_eq_200_i8");

	Ref ne_arg = f.builder.add_arg(value_interner::REF_I8);
	Ref minus_129 = f.add_int_constant(-129, value_interner::REF_I32);
	f.builder.start_fn();
	Ref ne_wide = f.builder.add_inst(ir::InstTag.SEXT, { .ref = ne_arg }, value_interner::REF_I32);
	Ref ne_compare = f.builder.add_inst(ir::InstTag.CMP_NE, { .bin = { ne_wide, minus_129 } }, value_interner::REF_I1);
	f.builder.add_return(ne_compare);
	f.builder.finish_fn("sext_ne_minus_129_i8");

	Ref min_arg = f.builder.add_arg(value_interner::REF_I8);
	Ref minus_128 = f.add_int_constant(-128, value_interner::REF_I32);
	f.builder.start_fn();
	Ref min_wide = f.builder.add_inst(ir::InstTag.SEXT, { .ref = min_arg }, value_interner::REF_I32);
	Ref min_compare = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { min_wide, minus_128 } }, value_interner::REF_I1);
	f.builder.add_return(min_compare);
	f.builder.finish_fn("sext_eq_minus_128_i8");

	Ref slt_arg = f.builder.add_arg(value_interner::REF_I8);
	Ref three_hundred = f.add_int_constant(300, value_interner::REF_I32);
	f.builder.start_fn();
	Ref slt_wide = f.builder.add_inst(ir::InstTag.SEXT, { .ref = slt_arg }, value_interner::REF_I32);
	Ref slt_compare = f.builder.add_inst(ir::InstTag.CMP_SLT, { .bin = { slt_wide, three_hundred } }, value_interner::REF_I1);
	f.builder.add_return(slt_compare);
	f.builder.finish_fn("sext_slt_300_i8");
	f.run_o1();

	assert_returns_int(&f.graph.decls[0], &f.interner, 0, "sext i8 equality against 200");
	assert_returns_int(&f.graph.decls[1], &f.interner, 1, "sext i8 inequality against -129");
	ir::Inst narrowed_min = f.graph.decls[2].instructions[(sz)return_value(&f.graph.decls[2])];
	assert(narrowed_min.tag == ir::InstTag.CMP_EQ && narrowed_min.data.bin.lhs == min_arg &&
		is_int_constant(&f.graph.decls[2], narrowed_min.data.bin.rhs, &f.interner, -128),
		"sext i8 equality against -128 should narrow at the signed boundary");
	ir::Inst retained_slt = f.graph.decls[3].instructions[(sz)return_value(&f.graph.decls[3])];
	assert(retained_slt.tag == ir::InstTag.CMP_SLT && retained_slt.data.bin.lhs == slt_wide &&
		retained_slt.data.bin.rhs == three_hundred,
		"signed less-than against 300 must retain the wide comparison");
	f.free();
}

fn void inst_combine_covers_sext_unsigned_and_mixed_width_zext_compares() @test
{
	HandIrFixture f;
	f.init();
	Ref signed_arg = f.builder.add_arg(value_interner::REF_I8);
	// The i32 bit pattern 0xFFFFFF80 is represented by the signed constant -128.
	Ref unsigned_constant = f.add_int_constant(-128, value_interner::REF_I32);
	f.builder.start_fn();
	Ref signed_wide = f.builder.add_inst(ir::InstTag.SEXT, { .ref = signed_arg }, value_interner::REF_I32);
	Ref unsigned_compare = f.builder.add_inst(ir::InstTag.CMP_ULT,
		{ .bin = { signed_wide, unsigned_constant } }, value_interner::REF_I1);
	f.builder.add_return(unsigned_compare);
	f.builder.finish_fn("cmp_ult_sext_i8_ffffff80");

	Ref signed_a = f.builder.add_arg(value_interner::REF_I8);
	Ref signed_b = f.builder.add_arg(value_interner::REF_I8);
	f.builder.start_fn();
	Ref wide_a = f.builder.add_inst(ir::InstTag.SEXT, { .ref = signed_a }, value_interner::REF_I32);
	Ref wide_b = f.builder.add_inst(ir::InstTag.SEXT, { .ref = signed_b }, value_interner::REF_I32);
	Ref paired_compare = f.builder.add_inst(ir::InstTag.CMP_UGT, { .bin = { wide_a, wide_b } }, value_interner::REF_I1);
	f.builder.add_return(paired_compare);
	f.builder.finish_fn("cmp_ugt_paired_sext_i8");

	Ref narrow8 = f.builder.add_arg(value_interner::REF_I8);
	Ref narrow16 = f.builder.add_arg(value_interner::REF_I16);
	f.builder.start_fn();
	Ref wide8 = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = narrow8 }, value_interner::REF_I32);
	Ref wide16 = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = narrow16 }, value_interner::REF_I32);
	Ref mixed_width_compare = f.builder.add_inst(ir::InstTag.CMP_ULT,
		{ .bin = { wide8, wide16 } }, value_interner::REF_I1);
	f.builder.add_return(mixed_width_compare);
	f.builder.finish_fn("cmp_ult_mixed_width_zext");
	f.run_o1();

	ir::Inst unsigned_result = f.graph.decls[0].instructions[(sz)return_value(&f.graph.decls[0])];
	assert(unsigned_result.tag == ir::InstTag.CMP_ULT && unsigned_result.data.bin.lhs == signed_arg &&
		is_int_constant(&f.graph.decls[0], unsigned_result.data.bin.rhs, &f.interner, -128) &&
		f.graph.decls[0].instructions[(sz)unsigned_result.data.bin.rhs].ty == value_interner::REF_I8,
		"cmp_ult(sext i8, 0xFFFFFF80) should narrow to ULT i8 0x80");
	ir::Inst paired_result = f.graph.decls[1].instructions[(sz)return_value(&f.graph.decls[1])];
	assert(paired_result.tag == ir::InstTag.CMP_UGT && paired_result.data.bin.lhs == signed_a &&
		paired_result.data.bin.rhs == signed_b,
		"paired sign extensions should narrow for unsigned greater-than");
	ir::Inst mixed_result = f.graph.decls[2].instructions[(sz)return_value(&f.graph.decls[2])];
	assert(mixed_result.tag == ir::InstTag.CMP_ULT && mixed_result.data.bin.lhs == wide8 &&
		mixed_result.data.bin.rhs == wide16,
		"zero extensions from different source widths must retain their wide comparison");
	f.free();
}

fn void inst_simplify_reports_changes_directly() @test
{
	HandIrFixture f;
	f.init();
	Ref arg = f.builder.add_arg(value_interner::REF_I32);
	Ref zero = f.add_int_constant(0, value_interner::REF_I32);
	f.builder.start_fn();
	Ref add = f.builder.add_inst(ir::InstTag.ADD, { .bin = { arg, zero } }, value_interner::REF_I32);
	f.builder.add_return(add);
	f.builder.finish_fn("inst_simplify_return_value");
	f.finish();
	assert(ir_opt::inst_simplify(&f.graph, &f.graph.decls[0]),
		"inst_simplify should report a changed declaration when it removes an additive zero");
	assert(return_value(&f.graph.decls[0]) == arg, "direct inst_simplify should replace x + 0 with x");
	assert(!ir_opt::inst_simplify(&f.graph, &f.graph.decls[0]),
		"inst_simplify should report no change on an already simplified declaration");
	f.free();
}

fn void inst_simplify_terminates_on_cyclic_values_without_predecessors() @test
{
	HandIrFixture f;
	f.init();
	Ref add_arg = f.builder.add_arg(value_interner::REF_I32);
	Ref one = f.add_int_constant(1, value_interner::REF_I32);
	Ref two = f.add_int_constant(2, value_interner::REF_I32);
	f.builder.start_fn();
	Ref add_x = f.builder.add_inst(ir::InstTag.ADD, { .bin = { add_arg, one } }, value_interner::REF_I32);
	Ref add_y = f.builder.add_inst(ir::InstTag.ADD, { .bin = { add_x, two } }, value_interner::REF_I32);
	f.builder.add_return(add_x);
	f.builder.finish_fn("cyclic_reassociation");

	Ref bool_arg = f.builder.add_arg(value_interner::REF_I1);
	Ref bool_one = f.builder.add_constant(value_interner::REF_ONE, value_interner::REF_I1);
	f.builder.start_fn();
	Ref not_a = f.builder.add_inst(ir::InstTag.BIT_XOR, { .bin = { bool_arg, bool_one } }, value_interner::REF_I1);
	Ref not_b = f.builder.add_inst(ir::InstTag.BIT_XOR, { .bin = { not_a, bool_one } }, value_interner::REF_I1);
	f.builder.add_return(not_a);
	f.builder.finish_fn("cyclic_boolean_negation");
	f.finish();

	// These value cycles need no CFG predecessor edges; they are deliberately malformed
	// value graphs used to verify that the simplify worklist makes no progress forever.
	f.graph.decls[0].instructions[(sz)add_x].data.bin.lhs = add_y;
	f.graph.decls[0].instructions[(sz)add_y].data.bin.lhs = add_x;
	f.graph.decls[1].instructions[(sz)not_a].data.bin.lhs = not_b;
	f.graph.decls[1].instructions[(sz)not_b].data.bin.lhs = not_a;
	assert(!ir_opt::inst_simplify(&f.graph, &f.graph.decls[0]),
		"inst_simplify should leave mutually recursive reassociation unchanged");
	assert(!ir_opt::inst_simplify(&f.graph, &f.graph.decls[1]),
		"inst_simplify should leave mutually recursive boolean negation unchanged");
	f.free();
}

fn void ipo_infers_conservative_function_and_argument_attributes() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"int global_value; volatile int volatile_global;\n"
		"int puts(const char *);\n"
		"int pure_value(int x) { return x + 1; }\n"
		"int pointer_read(const int *p) { return *p; }\n"
		"void pointer_write(int *p) { *p = 1; }\n"
		"int global_read(void) { return global_value; }\n"
		"int local_array(void) { int a[2]; a[0] = 4; return a[0]; }\n"
		"void global_write(void) { global_value = 3; }\n"
		"int loop_forever(void) { for (;;) { } }\n"
		"int recursive(int n) { return n ? recursive(n - 1) : 0; }\n"
		"int external_call(void) { return puts(\"x\"); }\n"
		"int volatile_local(void) { volatile int x; x = 1; return x; }\n"
		"int *return_pointer(int *p) { return p; }\n"
		"int indirect_call(int (*fn)(void)) { return fn(); }\n"
		"void call_global_write(void) { global_write(); }\n"
		"void call_global_read(void) { global_read(); }\n"
		"void call_loop(void) { loop_forever(); }\n"
		"void call_external(void) { external_call(); }\n"
		"void call_recursive(void) { recursive(1); }\n"
		"void call_volatile(void) { volatile_local(); }\n"
		"static int pure_helper(void) { return 4; }\n"
		"int unused_pure_call(void) { pure_helper(); return 0; }\n");
	f.run_mem2reg();
	ir_opt::infer_function_attrs(&f.graph);
	ir::Decl* pure = find_function(&f.graph, "pure_value");
	assert(pure.attrs.computed && pure.attrs.readnone && pure.attrs.readonly && pure.attrs.will_return,
		"a straight-line arithmetic function should be readnone and willreturn");
	assert((pure.attrs.arg_nocapture & 1) == 0,
		"integer arithmetic conservatively clears nocapture because pointer-integer casts are IR no-ops");
	// Per-argument access bits are masked by nocapture (a captured value may be
	// reloaded and dereferenced without provenance), so they drop together.
	assert((pure.attrs.arg_noread & 1) == 0 && (pure.attrs.arg_nowrite & 1) == 0,
		"a possibly captured argument gets no per-argument access guarantee");
	ir::Decl* pointer_read = find_function(&f.graph, "pointer_read");
	assert(pointer_read.attrs.readonly && !pointer_read.attrs.readnone && pointer_read.attrs.will_return,
		"a pointer load should be readonly and willreturn");
	assert((pointer_read.attrs.arg_noread & 1) == 0 && (pointer_read.attrs.arg_nowrite & 1) != 0 &&
		(pointer_read.attrs.arg_nocapture & 1) != 0, "loading through an argument should only read that argument");
	ir::Decl* pointer_write = find_function(&f.graph, "pointer_write");
	assert(!pointer_write.attrs.readonly && !pointer_write.attrs.readnone &&
		(pointer_write.attrs.arg_noread & 1) != 0 && (pointer_write.attrs.arg_nowrite & 1) == 0 &&
		(pointer_write.attrs.arg_nocapture & 1) != 0, "storing through an argument should write without reading or capturing it");
	ir::Decl* global_read = find_function(&f.graph, "global_read");
	assert(global_read.attrs.readonly && !global_read.attrs.readnone && global_read.attrs.will_return,
		"a global load should be readonly");
	ir::Decl* local_array = find_function(&f.graph, "local_array");
	assert(local_array.attrs.readnone && local_array.attrs.will_return,
		"writes and reads confined to a local array should be readnone");
	ir::Decl* global_write = find_function(&f.graph, "global_write");
	assert(!global_write.attrs.readonly && !global_write.attrs.readnone,
		"a global write must prevent readonly and readnone");
	assert(!find_function(&f.graph, "loop_forever").attrs.will_return,
		"a function with a backward loop edge must not be willreturn");
	assert(!find_function(&f.graph, "recursive").attrs.will_return,
		"a recursive function must not be willreturn");
	assert(!find_function(&f.graph, "external_call").attrs.readnone &&
		!find_function(&f.graph, "external_call").attrs.will_return,
		"an unknown external call must conservatively retain effects and may-not-return");
	assert(!find_function(&f.graph, "volatile_local").attrs.readnone,
		"volatile local accesses must remain observable");
	assert((find_function(&f.graph, "return_pointer").attrs.arg_nocapture & 1) == 0,
		"returning an argument pointer must clear nocapture");
	assert(!find_function(&f.graph, "indirect_call").attrs.readnone &&
		!find_function(&f.graph, "indirect_call").attrs.will_return,
		"an indirect call must conservatively read, write, and possibly not return");
	String[6] effectful_callers = { "call_global_write", "call_global_read", "call_loop",
		"call_external", "call_recursive", "call_volatile" };
	foreach (name : effectful_callers)
	{
		ir::Decl* effectful_caller = find_function(&f.graph, name);
		ir_opt::dead_instruction_elim(effectful_caller, &f.graph);
		assert(count_body_tag(effectful_caller, ir::InstTag.CALL) == 1,
			"DIE must keep calls with global, volatile, unknown, or non-willreturn effects");
	}

	ir::Decl* caller = find_function(&f.graph, "unused_pure_call");
	assert(caller.attrs.readnone && caller.attrs.will_return,
		"a caller of a known pure helper should inherit its properties");
	ir::Ref call_ref = ir::NONE;
	ir::Ref symbol_ref = ir::NONE;
	foreach (ref : caller.body)
	{
		ir::Inst* inst = &caller.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.CALL) call_ref = ref;
	}
	foreach (i, inst : caller.instructions)
		if (inst.tag == ir::InstTag.SYMBOL && inst.data.label == "pure_helper") symbol_ref = (ir::Ref)i;
	assert(call_ref != ir::NONE && symbol_ref != ir::NONE, "test fixture should contain the unused pure call and its symbol");
	assert(ir_opt::dead_instruction_elim(caller, &f.graph), "DIE should remove the unused pure call");
	assert(!has_index(caller.body, call_ref) && caller.instructions[(sz)symbol_ref].tag == ir::InstTag.ARG,
		"DIE should tombstone the unused pure call and its now-unused callee symbol");
	f.free();
}

fn void ipo_o2_drops_unused_pure_helper() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int sq(int x) { return x * x; }\n"
		"int g(int a) { sq(a); return a; }\n");
	f.run_o2();
	foreach (decl : f.graph.decls)
		assert(decl.name != "sq", "O2 should remove the helper after deleting its unused pure call");
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

fn void mem2reg_promotes_c_bool_local() @test
{
	OptFixture f;
	f.init();
	f.lower("_Bool bool_local(_Bool input) { _Bool value; value = input; return value; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "bool_local");
	assert(count_body_tag(decl, ir::InstTag.ALLOC) == 0 && count_body_tag(decl, ir::InstTag.LOAD) == 0 &&
		count_body_tag(decl, ir::InstTag.STORE) == 0,
		"a C _Bool local accessed with matching loads and stores should be promoted");
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
	editor.begin(&f.graph.decls[0]);
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

fn void mem2reg_places_loop_local_phi_at_if_join() @test
{
	OptFixture f;
	f.init();
	f.lower("int loop_local(int n) { int sum = 0; for (int i = 0; i < n; i++) { int t; if (i & 1) t = i; else t = -i; sum += t; } return sum; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "loop_local");
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
	assert(header != ir_opt::NONE_BLOCK, "loop-local fixture should retain a loop header");
	bool has_join_phi = false;
	foreach (i, block : cfg.blocks)
	{
		if (i == header) continue;
		for (sz pos = block.start; pos < block.end; pos++)
		{
			ir::Inst* inst = &decl.instructions[(sz)decl.body[pos]];
			if (inst.tag == ir::InstTag.PHI && inst.data.phi.len == 2) has_join_phi = true;
		}
	}
	assert(has_join_phi, "the conditional loop-local value should merge at its if-join, not at the loop header");
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

fn void sroa_promotes_struct_fields_and_fixed_array_elements() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"struct Pair { int first; int second; };\n"
		"int struct_fields(int a, int b) { struct Pair pair; pair.first = a; pair.second = b; return pair.first + pair.second; }\n"
		"int independent_roots(int a, int b) { struct Pair left; struct Pair right; left.first = a; left.second = b; right.first = b; right.second = a; return left.first + left.second + right.first + right.second; }\n"
		"int fixed_array(void) { int values[3]; values[0] = 11; values[0] = 12; values[1] = 22; values[2] = 33; return values[0] + values[1] + values[2]; }\n");
	f.run_sroa_mem2reg();
	String[3] functions = { "struct_fields", "independent_roots", "fixed_array" };
	foreach (name : functions)
	{
		ir::Decl* decl = find_function(&f.graph, name);
		assert(count_body_tag(decl, ir::InstTag.ALLOC) == 0,
			"SROA should split and promote the fields/elements of %s", name);
		assert(count_body_tag(decl, ir::InstTag.LOAD) == 0 && count_body_tag(decl, ir::InstTag.STORE) == 0,
			"promoted aggregate %s should have no remaining memory accesses", name);
	}
	f.free();
}

fn void sroa_keeps_overlapping_hand_built_byte_ranges_in_memory() @test
{
	HandIrFixture f;
	f.init();
	Ref wide_value = f.builder.add_arg(value_interner::REF_I64);
	Ref narrow_value = f.builder.add_arg(value_interner::REF_I32);
	Ref four = f.add_int_constant(4, value_interner::REF_I64);
	f.builder.start_fn();
	Ref root = f.builder.add_alloc(12, 8);
	Ref offset_four = f.builder.add_inst(ir::InstTag.ADD, { .bin = { root, four } }, value_interner::REF_PTR);
	f.builder.add_store(root, wide_value);
	f.builder.add_store(offset_four, narrow_value);
	Ref wide_read = f.builder.add_inst(ir::InstTag.LOAD, { .ref = root }, value_interner::REF_I64);
	f.builder.add_return(wide_read);
	f.builder.finish_fn("overlapping_ranges");
	f.finish();
	ir::Decl* decl = &f.graph.decls[0];
	assert(!ir_opt::sroa(&f.graph, decl),
		"an i64 access at byte 0 overlapping an i32 access at byte 4 must reject SROA");
	ir_opt::mem2reg(&f.graph, decl);
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "overlapping-range fixture should verify after mem2reg: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	errors.free();
	assert(has_index(decl.body, root) && has_index(decl.body, offset_four) &&
		count_body_tag(decl, ir::InstTag.LOAD) == 1 && count_body_tag(decl, ir::InstTag.STORE) == 2,
		"overlapping byte ranges must remain attached to their original allocation");
	f.free();
}

fn void mem_may_alias_distinguishes_roots_ranges_and_unknown_offsets() @test
{
	ir_opt::MemAddr root_a = { .root = (Ref)1, .offset = 0, .known_offset = true };
	ir_opt::MemAddr root_b = { .root = (Ref)2, .offset = 0, .known_offset = true };
	ir_opt::MemAddr escaped_a = { .root = (Ref)3, .offset = 0, .known_offset = true };
	ir_opt::MemAddr escaped_b = { .root = (Ref)4, .offset = 0, .known_offset = true };
	ir_opt::MemAddr adjacent = { .root = (Ref)1, .offset = 4, .known_offset = true };
	ir_opt::MemAddr unknown = { .root = (Ref)1, .known_offset = false };
	ir_opt::MemAddr unknown_root = { .root = ir::NONE, .known_offset = false };
	bool[5] non_escaping = { false, true, true, false, false };
	assert(!ir_opt::mem_may_alias(root_a, 4, root_b, 4, non_escaping[..]),
		"different nonescaping allocation roots cannot alias");
	assert(ir_opt::mem_may_alias(escaped_a, 4, escaped_b, 4, non_escaping[..]),
		"distinct roots may alias when both can escape");
	assert(!ir_opt::mem_may_alias(root_a, 4, unknown_root, 4, non_escaping[..]),
		"an unknown pointer cannot reach a nonescaping allocation");
	assert(!ir_opt::mem_may_alias(root_a, 4, adjacent, 4, non_escaping[..]),
		"disjoint ranges within one allocation cannot alias");
	assert(ir_opt::mem_may_alias(root_a, 8, adjacent, 4, non_escaping[..]),
		"an i64 range at byte 0 overlaps an i32 range at byte 4");
	assert(ir_opt::mem_may_alias(root_a, 4, unknown, 4, non_escaping[..]),
		"an unknown offset within the same root must conservatively alias");
}

fn void sroa_bails_on_escape_variable_index_volatile_and_overlap() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"void observe(int *ptr);\n"
		"int escaped_struct(void) { struct Pair { int first; int second; } pair; pair.first = 1; observe(&pair.first); return pair.second; }\n"
		"int variable_array_index(int index) { int values[3]; values[0] = 1; values[1] = 2; return values[index]; }\n"
		"int volatile_field(void) { struct V { volatile int value; } item; item.value = 4; return item.value; }\n");
	f.run_o1();
	String[3] functions = { "escaped_struct", "variable_array_index", "volatile_field" };
	foreach (name : functions)
	{
		ir::Decl* decl = find_function(&f.graph, name);
		assert(count_body_tag(decl, ir::InstTag.ALLOC) != 0,
			"SROA must keep aggregate storage for %s", name);
	}
	ir::Decl* volatile_decl = find_function(&f.graph, "volatile_field");
	assert(count_body_tag(volatile_decl, ir::InstTag.LOAD) != 0 &&
		count_body_tag(volatile_decl, ir::InstTag.STORE) != 0,
		"volatile field accesses must remain observable");
	f.free();
}

fn void mem_opt_cses_loads_forwards_stores_and_inherits_single_pred_state() @test
{
	{
		HandIrFixture f;
		f.init();
		f.builder.start_fn();
		Ref slot = f.builder.add_alloc(4, 4);
		Ref first = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
		Ref second = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
		Ref sum = f.builder.add_inst(ir::InstTag.ADD, { .bin = { first, second } }, value_interner::REF_I32);
		f.builder.add_return(sum);
		f.builder.finish_fn("mem_load_cse");
		f.run_mem_opt();
		ir::Decl* decl = &f.graph.decls[0];
		assert(count_body_tag(decl, ir::InstTag.LOAD) == 1,
			"repeated loads from the same nonvolatile stack slot should CSE");
		assert(return_value(decl) == sum,
			"the return should retain its sum expression after load CSE");
		assert(decl.instructions[(sz)sum].data.bin.lhs == first && decl.instructions[(sz)sum].data.bin.rhs == first,
			"the second load operand should resolve to the first load");
		f.free();
	}
	{
		HandIrFixture f;
		f.init();
		Ref value = f.builder.add_arg(value_interner::REF_I32);
		f.builder.start_fn();
		Ref slot = f.builder.add_alloc(4, 4);
		f.builder.add_store(slot, value);
		Ref loaded = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
		f.builder.add_return(loaded);
		f.builder.finish_fn("mem_store_forward");
		f.run_mem_opt();
		ir::Decl* decl = &f.graph.decls[0];
		assert(count_body_tag(decl, ir::InstTag.LOAD) == 0 && return_value(decl) == value,
			"a load after a same-slot store should forward the stored argument");
		f.free();
	}
	{
		HandIrFixture f;
		f.init();
		f.builder.start_fn();
		Ref slot = f.builder.add_alloc(4, 4);
		Ref value = f.builder.add_arg(value_interner::REF_I32);
		f.builder.add_store(slot, value);
		Ref child = f.builder.make_label("child");
		f.builder.add_jump(child);
		f.builder.start_block(child);
		Ref loaded = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
		f.builder.add_return(loaded);
		f.builder.finish_fn("mem_single_pred_child");
		f.run_mem_opt();
		ir::Decl* decl = &f.graph.decls[0];
		assert(count_body_tag(decl, ir::InstTag.LOAD) == 0 && return_value(decl) == value,
			"a sole-predecessor dominator child should inherit the parent's store fact");
		f.free();
	}
}

fn void mem_opt_invalidates_aliasing_stores_and_unknown_offsets() @test
{
	{
		HandIrFixture f;
		f.init();
		Ref new_value = f.builder.add_arg(value_interner::REF_I32);
		Ref four = f.add_int_constant(4, value_interner::REF_I64);
		f.builder.start_fn();
		Ref slot = f.builder.add_alloc(12, 8);
		Ref overlap = f.builder.add_inst(ir::InstTag.ADD, { .bin = { slot, four } }, value_interner::REF_PTR);
		Ref first = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I64);
		f.builder.add_store(overlap, new_value);
		Ref second = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I64);
		Ref sum = f.builder.add_inst(ir::InstTag.ADD, { .bin = { first, second } }, value_interner::REF_I64);
		f.builder.add_return(sum);
		f.builder.finish_fn("mem_overlap_invalidation");
		f.run_mem_opt();
		assert(count_body_tag(&f.graph.decls[0], ir::InstTag.LOAD) == 2,
			"a store to an overlapping byte range must invalidate a prior load fact");
		f.free();
	}
	{
		HandIrFixture f;
		f.init();
		Ref index = f.builder.add_arg(value_interner::REF_I64);
		Ref value = f.builder.add_arg(value_interner::REF_I32);
		f.builder.start_fn();
		Ref slot = f.builder.add_alloc(16, 8);
		Ref dynamic = f.builder.add_inst(ir::InstTag.ADD, { .bin = { slot, index } }, value_interner::REF_PTR);
		Ref first = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
		f.builder.add_store(dynamic, value);
		Ref second = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
		Ref sum = f.builder.add_inst(ir::InstTag.ADD, { .bin = { first, second } }, value_interner::REF_I32);
		f.builder.add_return(sum);
		f.builder.finish_fn("mem_dynamic_store_invalidation");
		f.run_mem_opt();
		assert(count_body_tag(&f.graph.decls[0], ir::InstTag.LOAD) == 2,
			"a variable-index store to the same root must invalidate known-offset facts");
		f.free();
	}
}

fn void mem_opt_preserves_load_fact_across_disjoint_store() @test
{
	HandIrFixture f;
	f.init();
	Ref value = f.builder.add_arg(value_interner::REF_I32);
	Ref four = f.add_int_constant(4, value_interner::REF_I64);
	f.builder.start_fn();
	Ref slot = f.builder.add_alloc(8, 4);
	Ref adjacent = f.builder.add_inst(ir::InstTag.ADD, { .bin = { slot, four } }, value_interner::REF_PTR);
	Ref first = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
	f.builder.add_store(adjacent, value);
	Ref second = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
	Ref sum = f.builder.add_inst(ir::InstTag.ADD, { .bin = { first, second } }, value_interner::REF_I32);
	f.builder.add_return(sum);
	f.builder.finish_fn("mem_disjoint_store_keeps_load_fact");
	f.run_mem_opt();
	ir::Decl* decl = &f.graph.decls[0];
	assert(count_body_tag(decl, ir::InstTag.LOAD) == 1 && count_body_tag(decl, ir::InstTag.STORE) == 1,
		"a store to a disjoint byte range must preserve the available load and remain observable");
	assert(decl.instructions[(sz)sum].data.bin.rhs == first,
		"the repeated load should resolve to the load before the disjoint store");
	f.free();
}

fn void mem_opt_dse_removes_overwrites_and_never_loaded_roots() @test
{
	{
		HandIrFixture f;
		f.init();
		Ref first_value = f.builder.add_arg(value_interner::REF_I32);
		Ref final_value = f.builder.add_arg(value_interner::REF_I32);
		Ref dynamic_offset = f.builder.add_arg(value_interner::REF_I64);
		f.builder.start_fn();
		Ref slot = f.builder.add_alloc(4, 4);
		f.builder.add_store(slot, first_value);
		f.builder.add_store(slot, final_value);
		Ref dynamic_slot = f.builder.add_inst(ir::InstTag.ADD, { .bin = { slot, dynamic_offset } }, value_interner::REF_PTR);
		Ref loaded = f.builder.add_inst(ir::InstTag.LOAD, { .ref = dynamic_slot }, value_interner::REF_I32);
		f.builder.add_return(loaded);
		f.builder.finish_fn("mem_overwrite_dse");
		f.run_mem_opt();
		assert(count_body_tag(&f.graph.decls[0], ir::InstTag.STORE) == 1,
			"an unobserved store should be removed when a same-size store overwrites it");
		f.free();
	}
	{
		HandIrFixture f;
		f.init();
		Ref value = f.builder.add_arg(value_interner::REF_I32);
		Ref four = f.add_int_constant(4, value_interner::REF_I64);
		f.builder.start_fn();
		Ref slot = f.builder.add_alloc(8, 4);
		Ref element = f.builder.add_inst(ir::InstTag.ADD, { .bin = { slot, four } }, value_interner::REF_PTR);
		f.builder.add_store(element, value);
		f.builder.add_store(slot, value);
		Ref zero = f.add_int_constant(0, value_interner::REF_I32);
		f.builder.add_return(zero);
		f.builder.finish_fn("mem_never_loaded_root");
		f.run_mem_opt();
		assert(count_body_tag(&f.graph.decls[0], ir::InstTag.STORE) == 0 &&
			count_body_tag(&f.graph.decls[0], ir::InstTag.ALLOC) == 0,
			"stores through fixed pointer ADDs and their never-loaded allocation should be removed");
		f.free();
	}
	{
		HandIrFixture f;
		f.init();
		Ref value = f.builder.add_arg(value_interner::REF_I64);
		Ref four = f.add_int_constant(4, value_interner::REF_I64);
		f.builder.start_fn();
		Ref slot = f.builder.add_alloc(8, 8);
		Ref part = f.builder.add_inst(ir::InstTag.ADD, { .bin = { slot, four } }, value_interner::REF_PTR);
		f.builder.add_store(slot, value);
		Ref observed = f.builder.add_inst(ir::InstTag.LOAD, { .ref = part }, value_interner::REF_I32);
		f.builder.add_store(slot, value);
		Ref final = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I64);
		Ref sum = f.builder.add_inst(ir::InstTag.ADD, { .bin = { observed, final } }, value_interner::REF_I64);
		f.builder.add_return(sum);
		f.builder.finish_fn("mem_dse_aliasing_read");
		f.run_mem_opt();
		assert(count_body_tag(&f.graph.decls[0], ir::InstTag.STORE) == 2,
			"a may-aliasing load must keep an earlier pending store live for DSE");
		f.free();
	}
}

fn void mem_opt_uses_inferred_call_argument_effects() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int read_pointer(const int *p) { return *p; }\n"
		"static void write_pointer(int *p) { *p = 9; }\n"
		"static int *captured_pointer;\n"
		"static void capture_pointer(int *p) { captured_pointer = p; }\n"
		"extern void external_pointer(int *p);\n"
		"int reader_call(void) { int value; value = 17; return read_pointer(&value) + value; }\n"
		"int writer_call(void) { int first, second; first = 1; second = 2; "
		"read_pointer(&second); int before = first + second; write_pointer(&first); "
		"return before + first + second; }\n"
		"int capture_call(void) { int value; value = 3; capture_pointer(&value); return value; }\n"
		"int external_call(void) { int value; value = 4; external_pointer(&value); return value; }\n");
	f.run_mem2reg();
	ir_opt::infer_function_attrs(&f.graph);
	foreach (&decl : f.graph.decls) ir_opt::mem_opt(&f.graph, decl);
	f.verify_graph();

	ir::Decl* reader = find_function(&f.graph, "read_pointer");
	assert((reader.attrs.arg_noread & 1) == 0 && (reader.attrs.arg_nowrite & 1) != 0 &&
		(reader.attrs.arg_nocapture & 1) != 0, "reader helper should only read its pointer argument");
	ir::Decl* reader_caller = find_function(&f.graph, "reader_call");
	assert(count_body_tag(reader_caller, ir::InstTag.LOAD) == 0 &&
		count_body_tag(reader_caller, ir::InstTag.STORE) == 1,
		"a summarized reader should preserve store-to-load forwarding while making the store observable");

	ir::Decl* writer = find_function(&f.graph, "write_pointer");
	assert((writer.attrs.arg_noread & 1) != 0 && (writer.attrs.arg_nowrite & 1) == 0 &&
		(writer.attrs.arg_nocapture & 1) != 0, "writer helper should only write its pointer argument");
	ir::Decl* writer_caller = find_function(&f.graph, "writer_call");
	assert(count_body_tag(writer_caller, ir::InstTag.LOAD) == 1,
		"the writer should invalidate the passed root while the other root's repeated load forwards");

	ir::Decl* capture = find_function(&f.graph, "capture_pointer");
	assert((capture.attrs.arg_nocapture & 1) == 0,
		"a helper that stores its pointer globally must not promise nocapture");
	assert(count_body_tag(find_function(&f.graph, "capture_call"), ir::InstTag.LOAD) == 1,
		"a captured allocation must remain opaque to memory forwarding");
	assert(count_body_tag(find_function(&f.graph, "external_call"), ir::InstTag.LOAD) == 1,
		"an external call without a summary must conservatively clobber an allocation");
	f.free();
}

fn void mem_opt_keeps_byval_call_memory_conservative() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"struct LargeMemArg { long a, b, c; };\n"
		"static long read_large(struct LargeMemArg value) { return value.a; }\n"
		"long byval_reader_call(void) { struct LargeMemArg value; value.a = 11; "
		"value.b = 12; value.c = 13; return read_large(value) + value.a; }\n");
	f.run_mem2reg();
	ir_opt::infer_function_attrs(&f.graph);
	foreach (&decl : f.graph.decls) ir_opt::mem_opt(&f.graph, decl);
	f.verify_graph();
	ir::Decl* caller = find_function(&f.graph, "byval_reader_call");
	bool saw_byval_copy = false;
	foreach (ref : caller.body)
	{
		ir::Inst* inst = &caller.instructions[(sz)ref];
		if (inst.tag != ir::InstTag.CALL) continue;
		foreach (bytes : inst.data.call.memory_copy_bytes) if (bytes != 0) saw_byval_copy = true;
	}
	assert(saw_byval_copy, "the by-value aggregate call should carry copy metadata");
	assert(count_body_tag(caller, ir::InstTag.ALLOC) != 0 && count_body_tag(caller, ir::InstTag.STORE) != 0,
		"by-value copy metadata must keep the caller's aggregate storage conservative");
	f.free();
}

fn void mem_opt_does_not_inherit_state_across_joins_or_loops() @test
{
	{
		HandIrFixture f;
		f.init();
		Ref condition = f.builder.add_arg(value_interner::REF_I1);
		Ref initial = f.builder.add_arg(value_interner::REF_I32);
		Ref changed = f.builder.add_arg(value_interner::REF_I32);
		f.builder.start_fn();
		Ref slot = f.builder.add_alloc(4, 4);
		f.builder.add_store(slot, initial);
		Ref left = f.builder.make_label("left");
		Ref right = f.builder.make_label("right");
		Ref join = f.builder.make_label("join");
		f.builder.add_branch(condition, left, right);
		f.builder.start_block(left);
		f.builder.add_store(slot, changed);
		f.builder.add_jump(join);
		f.builder.start_block(right);
		f.builder.add_jump(join);
		f.builder.start_block(join);
		Ref loaded = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
		f.builder.add_return(loaded);
		f.builder.finish_fn("mem_join_without_inheritance");
		f.run_mem_opt();
		assert(count_body_tag(&f.graph.decls[0], ir::InstTag.LOAD) == 1 &&
			return_value(&f.graph.decls[0]) == loaded,
			"a join with multiple predecessors must start with empty memory state");
		f.free();
	}
	{
		HandIrFixture f;
		f.init();
		Ref condition = f.builder.add_arg(value_interner::REF_I1);
		Ref initial = f.builder.add_arg(value_interner::REF_I32);
		f.builder.start_fn();
		Ref slot = f.builder.add_alloc(4, 4);
		f.builder.add_store(slot, initial);
		Ref header = f.builder.make_label("header");
		Ref body = f.builder.make_label("body");
		Ref exit = f.builder.make_label("exit");
		f.builder.add_jump(header);
		f.builder.start_block(header);
		Ref loaded = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
		f.builder.add_branch(condition, body, exit);
		f.builder.start_block(body);
		f.builder.add_jump(header);
		f.builder.start_block(exit);
		f.builder.add_return(loaded);
		f.builder.finish_fn("mem_loop_header_without_inheritance");
		f.run_mem_opt();
		assert(count_body_tag(&f.graph.decls[0], ir::InstTag.LOAD) == 1 &&
			return_value(&f.graph.decls[0]) == loaded,
			"a loop header must start with empty memory state even when entered from a store");
		f.free();
	}
}

fn void mem_opt_leaves_volatile_escaped_untracked_and_mismatched_accesses() @test
{
	{
		HandIrFixture f;
		f.init();
		Ref value = f.builder.add_arg(value_interner::REF_I32);
		f.builder.start_fn();
		Ref volatile_load_slot = f.builder.add_alloc(4, 4, true);
		Ref first = f.builder.add_inst(ir::InstTag.LOAD, { .ref = volatile_load_slot }, value_interner::REF_I32);
		Ref second = f.builder.add_inst(ir::InstTag.LOAD, { .ref = volatile_load_slot }, value_interner::REF_I32);
		Ref sum = f.builder.add_inst(ir::InstTag.ADD, { .bin = { first, second } }, value_interner::REF_I32);
		f.builder.add_return(sum);
		Ref write_only = f.builder.add_alloc(4, 4, true);
		f.builder.add_store(write_only, value);
		f.builder.finish_fn("mem_volatile_access");
		f.run_mem_opt();
		assert(count_body_tag(&f.graph.decls[0], ir::InstTag.LOAD) == 2 &&
			count_body_tag(&f.graph.decls[0], ir::InstTag.STORE) == 1 &&
			count_body_tag(&f.graph.decls[0], ir::InstTag.ALLOC) == 2,
			"volatile allocation loads and stores must not be CSE'd or removed");
		f.free();
	}
	{
		HandIrFixture f;
		f.init();
		Ref callee = f.builder.add_symbol("observe", value_interner::REF_FUNC);
		f.builder.start_fn();
		Ref slot = f.builder.add_alloc(4, 4);
		Ref value = f.builder.add_arg(value_interner::REF_I32);
		f.builder.add_store(slot, value);
		Ref[1] args = { slot };
		f.builder.add_call(callee, args[..], value_interner::REF_VOID);
		Ref first = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
		Ref second = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
		Ref sum = f.builder.add_inst(ir::InstTag.ADD, { .bin = { first, second } }, value_interner::REF_I32);
		f.builder.add_return(sum);
		f.builder.finish_fn("mem_escaped_access");
		f.run_mem_opt();
		assert(count_body_tag(&f.graph.decls[0], ir::InstTag.LOAD) == 2 &&
			count_body_tag(&f.graph.decls[0], ir::InstTag.STORE) == 1,
			"an alloca passed to CALL must be treated as escaping");
		f.free();
	}
	{
		HandIrFixture f;
		f.init();
		Ref address = f.builder.add_arg(value_interner::REF_PTR);
		Ref value = f.builder.add_arg(value_interner::REF_I32);
		f.builder.start_fn();
		Ref first = f.builder.add_inst(ir::InstTag.LOAD, { .ref = address }, value_interner::REF_I32);
		f.builder.add_store(address, value);
		Ref second = f.builder.add_inst(ir::InstTag.LOAD, { .ref = address }, value_interner::REF_I32);
		Ref sum = f.builder.add_inst(ir::InstTag.ADD, { .bin = { first, second } }, value_interner::REF_I32);
		f.builder.add_return(sum);
		f.builder.finish_fn("mem_arg_pointer_access");
		f.run_mem_opt();
		assert(count_body_tag(&f.graph.decls[0], ir::InstTag.LOAD) == 2 &&
			count_body_tag(&f.graph.decls[0], ir::InstTag.STORE) == 1,
			"loads and stores through an ARG pointer must remain untracked");
		f.free();
	}
	{
		HandIrFixture f;
		f.init();
		Ref value = f.builder.add_arg(value_interner::REF_I32);
		f.builder.start_fn();
		Ref slot = f.builder.add_alloc(8, 8);
		f.builder.add_store(slot, value);
		Ref loaded = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I64);
		f.builder.add_return(loaded);
		f.builder.finish_fn("mem_type_mismatch");
		f.run_mem_opt();
		assert(count_body_tag(&f.graph.decls[0], ir::InstTag.LOAD) == 1 &&
			count_body_tag(&f.graph.decls[0], ir::InstTag.STORE) == 1,
			"a load with a different type from the stored value must not forward");
		f.free();
	}
}

fn void o1_mem_opt_preserves_variable_index_aliasing_and_drops_unread_pointer_add_stores() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"int alias_after_variable_store(int i) { int a[4]; a[1] = i; a[i & 3] = 0; return a[1]; }\n"
		"void write_only_variable_index(int i, int value) { int a[4]; a[i] = value; }\n");
	f.run_o1();
	ir::Decl* alias_decl = find_function(&f.graph, "alias_after_variable_store");
	assert(count_body_tag(alias_decl, ir::InstTag.LOAD) == 1,
		"O1 must keep the load after a variable-index store that may alias the fixed element");
	ir::Decl* write_only = find_function(&f.graph, "write_only_variable_index");
	assert(count_body_tag(write_only, ir::InstTag.ALLOC) == 0 &&
		count_body_tag(write_only, ir::InstTag.STORE) == 0 &&
		count_body_tag(write_only, ir::InstTag.LOAD) == 0,
		"O1 should remove stores through ptr ADDs when the nonescaping root is never loaded");
	f.free();
}

fn void o1_preserves_volatile_struct_members_and_array_elements() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"struct S { volatile int member; };\n"
		"int volatile_member(void) { struct S s; s.member = 4; return s.member; }\n"
		"int volatile_element(void) { volatile int values[1]; values[0] = 7; return values[0]; }\n");
	f.run_o1();
	String[2] volatile_functions = { "volatile_member", "volatile_element" };
	foreach (name : volatile_functions)
	{
		ir::Decl* decl = find_function(&f.graph, name);
		assert(count_body_tag(decl, ir::InstTag.ALLOC) == 1, "%s allocation should remain", name);
		assert(count_body_tag(decl, ir::InstTag.LOAD) == 1 && count_body_tag(decl, ir::InstTag.STORE) == 1,
			"%s volatile loads and stores should remain", name);
		bool is_volatile = false;
		foreach (ref : decl.body)
		{
			if (decl.instructions[(sz)ref].tag == ir::InstTag.ALLOC)
			{
				is_volatile = decl.instructions[(sz)ref].data.alloc.is_volatile;
			}
		}
		assert(is_volatile, "%s allocation should be marked volatile", name);
	}
	f.free();
}

fn void dce_preserves_volatile_member_store() @test
{
	OptFixture f;
	f.init();
	f.lower("struct S { volatile int member; }; void write_member(void) { struct S s; s.member = 4; }");
	f.run_o1();
	ir::Decl* decl = find_function(&f.graph, "write_member");
	assert(count_body_tag(decl, ir::InstTag.STORE) == 1,
		"DCE must retain a store through a volatile struct member");
	f.free();
}

fn void mem2reg_declines_candidate_with_unreachable_load() @test
{
	HandIrFixture f;
	f.init();
	f.builder.start_fn();
	Ref slot = f.builder.add_alloc(4, 4);
	Ref initial = f.add_int_constant(1, value_interner::REF_I32);
	f.builder.add_store(slot, initial);
	Ref dead = f.builder.make_label("dead");
	Ref exit = f.builder.make_label("exit");
	f.builder.add_jump(exit);
	f.builder.start_block(dead);
	Ref dead_load = f.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I32);
	Ref dead_use = f.builder.add_inst(ir::InstTag.ADD, { .bin = { dead_load, initial } }, value_interner::REF_I32);
	f.builder.add_inst(ir::InstTag.RET, { .ref = dead_use }, value_interner::REF_NORETURN);
	f.builder.start_block(exit);
	Ref zero = f.add_int_constant(0, value_interner::REF_I32);
	f.builder.add_return(zero);
	f.builder.finish_fn("unreachable_candidate");
	f.run_mem2reg();
	ir::Decl* decl = &f.graph.decls[0];
	assert(has_index(decl.body, slot) && has_index(decl.body, dead_load),
		"mem2reg should leave the candidate allocation and unreachable load intact");
	f.free();
}

fn void mem2reg_replaces_uninitialized_double_and_pointer_with_typed_zero() @test
{
	OptFixture f;
	f.init();
	f.lower("double uninitialized_double(void) { double value; return value; }\n"
		"int *uninitialized_pointer(void) { int *value; return value; }");
	f.run_mem2reg();
	String[2] functions = { "uninitialized_double", "uninitialized_pointer" };
	foreach (name : functions)
	{
		ir::Decl* decl = find_function(&f.graph, name);
		Ref returned = return_value(decl);
		value_interner::InternerRef expected_type = name == "uninitialized_double" ? value_interner::REF_F64 : value_interner::REF_PTR;
		assert(returned != ir::NONE && decl.instructions[(sz)returned].tag == ir::InstTag.CONSTANT &&
			decl.instructions[(sz)returned].data.constant == value_interner::REF_ZERO &&
			decl.instructions[(sz)returned].ty == expected_type,
			"%s should return canonical typed zero", name);
	}
	f.free();
}

fn void mem2reg_keeps_pointer_cast_type_pun_allocated() @test
{
	OptFixture f;
	f.init();
	f.lower("float pun(int bits) { int value = bits; return *(float *)&value; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "pun");
	assert(count_body_tag(decl, ir::InstTag.ALLOC) == 1 && count_body_tag(decl, ir::InstTag.STORE) == 1 &&
		count_body_tag(decl, ir::InstTag.LOAD) == 1,
		"a pointer-cast type pun must retain its allocation and mismatched accesses");
	f.free();
}

fn void mem2reg_keeps_long_slot_with_int_cast_access() @test
{
	OptFixture f;
	f.init();
	f.lower("int long_to_int_pun(long bits) { long value = bits; return *(int *)&value; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "long_to_int_pun");
	assert(count_body_tag(decl, ir::InstTag.ALLOC) == 1 && count_body_tag(decl, ir::InstTag.STORE) == 1 &&
		count_body_tag(decl, ir::InstTag.LOAD) == 1,
		"an int access through a cast must not promote its long allocation");
	f.free();
}

fn void mem2reg_keeps_union_type_pun_allocated() @test
{
	OptFixture f;
	f.init();
	f.lower("float union_pun(int bits) { union IntFloat { int i; float f; } value; value.i = bits; return value.f; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "union_pun");
	assert(count_body_tag(decl, ir::InstTag.ALLOC) == 1 && count_body_tag(decl, ir::InstTag.STORE) == 1 &&
		count_body_tag(decl, ir::InstTag.LOAD) == 1,
		"a union type pun must remain in memory in the IR");
	f.free();
}

fn void mem2reg_rejects_address_plus_zero_use() @test
{
	OptFixture f;
	f.init();
	f.lower("int address_plus_zero(void) { int value = 9; return *(&value + 0); }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "address_plus_zero");
	assert(count_body_tag(decl, ir::InstTag.ALLOC) == 1 && count_body_tag(decl, ir::InstTag.STORE) == 1 &&
		count_body_tag(decl, ir::InstTag.LOAD) == 1,
		"using the local address in pointer arithmetic, even with offset zero, must reject promotion");
	f.free();
}

fn void o1_forwarded_address_store_returns_latest_value() @test
{
	OptFixture f;
	f.init();
	f.lower("int forwarded_store(void) { int x = 1; int *p = &x; *p = 3; return x; }");
	f.run_o1();
	ir::Decl* decl = find_function(&f.graph, "forwarded_store");
	Ref returned = return_value(decl);
	assert(returned != ir::NONE && !is_int_constant(decl, returned, f.graph.interner, 1),
		"O1 must not fold the value after a forwarded address store to the stale value 1");
	assert(is_int_constant(decl, returned, f.graph.interner, 3) || count_body_tag(decl, ir::InstTag.ALLOC) != 0,
		"O1 should return the forwarded stored value or leave its local in memory");
	f.free();
}

fn void o2_verifies_irreducible_loop() @test
{
	OptFixture f;
	f.init();
	f.lower("int irreducible(int n) { if (n) goto left; goto right; left: n--; if (n) goto right; return n; right: n--; if (n) goto left; return n; }");
	f.run_o2();
	f.verify_graph();
	f.free();
}

fn void mem2reg_tracks_address_store_and_comparison() @test
{
	OptFixture f;
	f.init();
	f.lower("int address_store_compare(void) { int value = 1; int *saved = &value; int *other = saved; return other == &value; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "address_store_compare");
	assert(count_body_tag(decl, ir::InstTag.ALLOC) != 0,
		"a local whose address is stored and compared should remain allocated");
	f.free();
}

fn void o1_shared_target_switch_phis_match_distinct_predecessors() @test
{
	OptFixture f;
	f.init();
	f.lower("int shared_switch(int x) { int value; switch (x) { case 0: case 1: value = x + 10; break; case 2: value = x + 20; break; default: value = x + 30; } return value; }");
	f.run_o1();
	ir::Decl* decl = find_function(&f.graph, "shared_switch");
	ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
	bool checked_join = false;
	foreach (block : cfg.blocks)
	{
		for (sz i = block.start; i < block.end; i++)
		{
			ir::Ref ref = decl.body[i];
			ir::Inst* inst = &decl.instructions[(sz)ref];
			if (inst.tag != ir::InstTag.PHI) continue;
			checked_join = true;
			assert(inst.data.phi.len == block.preds.len(),
				"switch join PHI should have exactly one input per predecessor");
			foreach (input_index, input : inst.data.phi)
			{
				foreach (prior_index, prior : inst.data.phi)
				{
					if (prior_index >= input_index) break;
					assert(prior.label != input.label, "switch join PHI must not duplicate predecessor labels");
				}
				assert(has_uint_index(block.preds.array_view(), cfg.block_of_ref[(sz)input.label]),
					"switch join PHI inputs must name actual predecessors");
			}
		}
	}
	assert(checked_join, "shared-target switch should retain a join PHI");
	cfg.free();
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

fn void licm_hoists_loop_invariant_expression_to_preheader() @test
{
	OptFixture f;
	f.init();
	f.lower("int invariant(int n) { int sum = 0; for (int i = 0; i < 10; i++) sum += n * 7; return sum; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "invariant");
	ir_opt::loop_invariant_code_motion(&f.graph, decl);
	f.verify_graph();

	Ref multiply = ir::NONE;
	foreach (ref : decl.body)
	{
		if (decl.instructions[(sz)ref].tag == ir::InstTag.MUL)
		{
			assert(multiply == ir::NONE, "fixture should contain only one multiplication");
			multiply = ref;
		}
	}
	assert(multiply != ir::NONE, "invariant multiplication should remain in the IR");

	ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
	cfg.compute_dominators();
	uint multiply_block = cfg.block_of_ref[(sz)multiply];
	assert(multiply_block != ir_opt::NONE_BLOCK, "multiplication should belong to a CFG block");
	bool checked_loop_header = false;
	foreach (block_index, block : cfg.blocks)
	{
		foreach (successor : block.succs)
		{
			if (cfg.dominates(successor, (uint)block_index))
			{
				checked_loop_header = true;
				assert(!cfg.dominates(successor, multiply_block),
					"the invariant multiplication should be outside the natural loop");
			}
		}
	}
	assert(checked_loop_header, "fixture should retain a detectable loop back edge");
	assert(count_body_tag(decl, ir::InstTag.MUL) == 1,
		"LICM should preserve exactly one multiplication while moving it out of the loop");
	cfg.free();
	f.free();
}

fn void licm_nested_preheader_tails_keep_def_before_use() @test
{
	// The innermost preheader tail holds 1-a, a*b, 1-a*b; the b-loop later moves
	// 1-a outward. The remaining tail entries must keep their dependency order.
	OptFixture f;
	f.init();
	f.lower("int g(int);\n"
		"int f(int n) { int s = 0; for (int a = 0; a < n; a++) for (int b = 0; b < n; b++) "
		"for (int c = 0; c < n; c++) s += g(c) + (1 - a) + (1 - a * b); return s; }\n");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "f");
	assert(ir_opt::loop_invariant_code_motion(&f.graph, decl), "LICM should hoist the invariants");
	f.verify_graph();
	sz mul_pos = -1;
	sz sub_pos = -1;
	foreach (pos, ref : decl.body)
	{
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.MUL) mul_pos = (sz)pos;
		if (inst.tag == ir::InstTag.SUB && decl.instructions[(sz)inst.data.bin.rhs].tag == ir::InstTag.MUL) sub_pos = (sz)pos;
	}
	assert(mul_pos >= 0 && sub_pos >= 0, "fixture should keep a*b and 1 - a*b");
	assert(mul_pos < sub_pos, "a*b must be placed before 1 - a*b");
	f.free();
}

fn void licm_keeps_load_from_nocapture_writable_call_argument_in_loop() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static void write_pointer(int *p) { *p = 9; }\n"
		"int writable_call_load(int n) { int value = 1; int i = 0; int sum = 0; "
		"while (i < n) { int observed = value; write_pointer(&value); sum += observed; i++; } "
		"return sum; }\n");
	f.run_mem2reg();
	ir_opt::infer_function_attrs(&f.graph);
	ir::Decl* writer = find_function(&f.graph, "write_pointer");
	assert((writer.attrs.arg_nocapture & 1) != 0 && (writer.attrs.arg_nowrite & 1) == 0,
		"the callee should be summarized as non-capturing but writable through its argument");

	ir::Decl* decl = find_function(&f.graph, "writable_call_load");
	ir_opt::loop_invariant_code_motion(&f.graph, decl);
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "IR verifier rejected LICM result: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	assert(errors.len() == 0, "valid LICM result reported verifier errors");
	errors.free();

	Ref writer_call = ir::NONE;
	foreach (ref : decl.body)
	{
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.CALL) writer_call = ref;
	}
	assert(writer_call != ir::NONE, "writer call should remain in the caller");
	ir::Inst* call = &decl.instructions[(sz)writer_call];
	assert(call.data.call.args.len == 1, "writer call should pass exactly one pointer argument");
	Ref passed_alloca = call.data.call.args[0];
	Ref observed_load = ir::NONE;
	foreach (ref : decl.body)
	{
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.LOAD && inst.data.ref == passed_alloca) observed_load = ref;
	}
	assert(observed_load != ir::NONE, "load from the alloca passed to the writer should remain");

	ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
	cfg.compute_dominators();
	uint load_block = cfg.block_of_ref[(sz)observed_load];
	assert(load_block != ir_opt::NONE_BLOCK, "load should belong to a CFG block");
	bool load_is_in_loop = false;
	foreach (block_index, block : cfg.blocks)
	{
		foreach (successor : block.succs)
		{
			if (cfg.dominates(successor, (uint)block_index) && cfg.dominates(successor, load_block))
			{
				load_is_in_loop = true;
			}
		}
	}
	assert(load_is_in_loop, "the load must stay in the loop because the call can write through its argument");
	cfg.free();
	f.free();
}

fn void licm_preserves_induction_value_at_loop_exit() @test
{
	OptFixture f;
	f.init();
	f.lower("int induction_exit(int limit, int stop) { int i = 0; for (; i < limit; i++) { if (i == stop) break; } return i; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "induction_exit");
	ir_opt::loop_invariant_code_motion(&f.graph, decl);
	f.verify_graph();

	Ref exit_value = return_value(decl);
	assert(exit_value != ir::NONE && decl.instructions[(sz)exit_value].tag == ir::InstTag.PHI,
		"the value returned after the loop should remain the loop-carried induction PHI");
	bool has_increment_input = false;
	ir::Inst* induction = &decl.instructions[(sz)exit_value];
	foreach (input : induction.data.phi)
	{
		if (decl.instructions[(sz)input.value].tag == ir::InstTag.ADD) has_increment_input = true;
	}
	assert(has_increment_input, "the induction PHI should retain its increment as a back-edge input");

	ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
	assert(cfg_has_back_edge(&cfg), "the induction loop should retain its back edge after LICM");
	cfg.free();
	f.free();
}

fn void indvar_simplifies_up_counter_exit_without_removing_loop() @test
{
	OptFixture f;
	f.init();
	f.lower("int up_lt(void) { int i = 0; while (i < 5) i++; return i; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "up_lt");
	assert(ir_opt::indvar_simplify(&f.graph, decl), "the constant up-counter exit should be simplified");
	f.verify_graph();
	assert(is_int_constant(decl, return_value(decl), f.graph.interner, 5),
		"the up-counter exit should be the constant bound 5");
	assert(count_body_tag(decl, ir::InstTag.BRANCH) != 0,
		"folding the up-counter exit must preserve its loop branch");
	f.free();
}

fn void unroll_removes_back_edge_small_loop() @test
{
	OptFixture f;
	f.init();
	f.lower("int f(int a) { int s = 0; for (int i = 0; i < 4; i++) s += a; return s; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "f");
	assert(ir_opt::loop_full_unroll(&f.graph, decl, 128), "small constant loop should unroll");
	f.verify_graph();
	ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
	assert(!cfg_has_back_edge(&cfg), "fully unrolled loop should have no back edge");
	cfg.free();
	f.free();

	OptFixture optimized;
	optimized.init();
	optimized.lower("int f(int a) { int s = 0; for (int i = 0; i < 4; i++) s += a; return s; }");
	optimized.run_o2();
	decl = find_function(&optimized.graph, "f");
	cfg = ir_opt::build_cfg(decl, &optimized.ta);
	assert(!cfg_has_back_edge(&cfg) && count_body_tag(decl, ir::InstTag.BRANCH) == 0,
		"O2 should unroll the small loop and leave no back edge or branch");
	cfg.free();
	optimized.free();
}

fn void loop_deletion_removes_unused_counter_and_nested_loops() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"void unused_counter(void) { int i = 0; while (i < 8) i++; }\n"
		"void unused_nested_counters(void) { int i = 0; while (i < 4) { int j = 0; while (j < 3) j++; i++; } }\n"
		"int f(void) { int i = 0; while (i < 10) i += 3; return i; }\n");
	f.run_mem2reg();
	ir::Decl* stepped = find_function(&f.graph, "f");
	assert(ir_opt::indvar_simplify(&f.graph, stepped),
		"the constant stepped exit should be simplified before loop deletion");
	assert(ir_opt::loop_deletion(&f.graph, stepped),
		"loop deletion should remove the stepped counter loop");
	f.verify_graph();
	ir_opt::Cfg stepped_cfg = ir_opt::build_cfg(stepped, &f.ta);
	assert(!cfg_has_back_edge(&stepped_cfg), "the stepped counter should have no back edge after deletion");
	assert(count_body_tag(stepped, ir::InstTag.BRANCH) == 0,
		"the stepped counter should have no branch after deletion");
	assert(is_int_constant(stepped, return_value(stepped), f.graph.interner, 12),
		"the stepped counter should return the constant 12 after deletion");
	stepped_cfg.free();
	foreach (name : (String[]){"unused_counter", "unused_nested_counters"})
	{
		ir::Decl* decl = find_function(&f.graph, name);
		if (name == "unused_nested_counters")
		{
			ir_opt::indvar_simplify(&f.graph, decl);
		}
		assert(ir_opt::loop_deletion(&f.graph, decl),
			"loop deletion should remove unused counter loop(s) in %s", name);
		f.verify_graph();
		ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
		assert(!cfg_has_back_edge(&cfg), "unused counter loop(s) should have no back edge in %s", name);
		cfg.free();
	}
	f.free();
}

fn void loop_deletion_preserves_effectful_or_unproven_loops() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"void store_through_arg(int *p) { int i = 0; while (i < 8) { *p = i; i++; } }\n"
		"extern void observe(int); void call_in_loop(void) { int i = 0; while (i < 8) { observe(i); i++; } }\n"
		"void unknown_bound(int n) { int i = 0; while (i < n) i++; }\n"
		"int observable_accumulator(void) { int i = 0, sum = 0; while (i < 8) { sum += i; i++; } return sum; }\n"
		"void variable_division(int divisor) { int i = 1; while (i < 8) { int quotient = i / divisor; i++; } }\n");
	f.run_mem2reg();
	foreach (name : (String[]){"store_through_arg", "call_in_loop", "unknown_bound", "observable_accumulator", "variable_division"})
	{
		ir::Decl* decl = find_function(&f.graph, name);
		ir_opt::loop_deletion(&f.graph, decl);
		f.verify_graph();
		ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
		assert(cfg_has_back_edge(&cfg), "loop deletion must preserve the loop in %s", name);
		cfg.free();
	}
	f.free();
}

fn void loop_deletion_is_reached_by_o2_pipeline() @test
{
	OptFixture f;
	f.init();
	f.lower("int o2_dead_loop(void) { int i = 0; while (i < 3) i++; return i; }");
	f.run_o2();
	ir::Decl* decl = find_function(&f.graph, "o2_dead_loop");
	ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
	assert(!cfg_has_back_edge(&cfg), "O2 should delete an unused constant-bound loop");
	cfg.free();
	assert(count_body_tag(decl, ir::InstTag.BRANCH) == 0,
		"O2 should remove the branch from the deleted loop");
	assert_returns_int(decl, f.graph.interner, 3, "O2 dead-loop result");
	f.free();
}

fn void unroll_do_while_latch_exit() @test
{
	OptFixture f;
	f.init();
	f.lower("int f(int a) { int i = 0, s = 0; do { s ^= a + i; i++; } while (i < 3); return s; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "f");
	ir_opt::loop_full_unroll(&f.graph, decl, 128);
	f.verify_graph();
	ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
	assert(!cfg_has_back_edge(&cfg), "do/while loop should have no back edge after unrolling");
	cfg.free();
	f.free();
}

fn void unroll_skips_over_threshold_and_unknown_trip_count() @test
{
	OptFixture f;
	f.init();
	f.lower("int large(void) { int i = 0; while (i < 1000) i++; return i; } int unknown(int n) { int i = 0; while (i < n) i++; return i; }");
	f.run_mem2reg();
	ir::Decl* large = find_function(&f.graph, "large");
	ir::Decl* unknown = find_function(&f.graph, "unknown");
	ir_opt::loop_full_unroll(&f.graph, large, 128);
	ir_opt::loop_full_unroll(&f.graph, unknown, 128);
	f.verify_graph();
	ir_opt::Cfg large_cfg = ir_opt::build_cfg(large, &f.ta);
	ir_opt::Cfg unknown_cfg = ir_opt::build_cfg(unknown, &f.ta);
	assert(cfg_has_back_edge(&large_cfg), "large loop should retain its back edge");
	assert(cfg_has_back_edge(&unknown_cfg), "unknown-trip loop should retain its back edge");
	large_cfg.free();
	unknown_cfg.free();
	f.free();
}

fn void unroll_body_with_internal_branch() @test
{
	OptFixture f;
	f.init();
	f.lower("int f(int a) { int s = 0; for (int i = 0; i < 3; i++) { if (a & i) s += i; else s -= a; } return s; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "f");
	ir_opt::loop_full_unroll(&f.graph, decl, 128);
	f.verify_graph();
	ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
	assert(!cfg_has_back_edge(&cfg), "loop with an internal branch should fully unroll");
	cfg.free();
	f.free();
}

fn void unroll_skips_outer_loop_until_inner_loop_is_gone() @test
{
	OptFixture f;
	f.init();
	f.lower("int f(int a) { int s = 0; for (int i = 0; i < 3; i++) for (int j = 0; j < 2; j++) s += a + i + j; return s; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "f");
	ir_opt::loop_full_unroll(&f.graph, decl, 128);
	f.verify_graph();
	ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
	assert(!cfg_has_back_edge(&cfg), "inner then outer counted loops should unroll to a fixpoint");
	cfg.free();
	f.free();
}

fn void indvar_simplifies_down_counter_ge_exit_without_removing_loop() @test
{
	OptFixture f;
	f.init();
	f.lower("int down_ge(void) { int i = 10; while (i >= 4) i--; return i; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "down_ge");
	assert(ir_opt::indvar_simplify(&f.graph, decl), "the constant down-counter exit should be simplified");
	f.verify_graph();
	assert(is_int_constant(decl, return_value(decl), f.graph.interner, 3),
		"the down-counter should exit at 3 after the >= test becomes false");
	assert(count_body_tag(decl, ir::InstTag.BRANCH) != 0,
		"folding the down-counter exit must preserve its loop branch");
	f.free();
}

fn void indvar_trip_count_down_counter() @test
{
	OptFixture f;
	f.init();
	f.lower("int down_counter(void) { int i = 10; for (; i > 0; i--) {} return i; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "down_counter");
	assert(ir_opt::indvar_simplify(&f.graph, decl), "the for-loop down-counter exit should be simplified");
	f.verify_graph();
	assert(is_int_constant(decl, return_value(decl), f.graph.interner, 0),
		"the down-counter should exit at 0 after the > test becomes false");
	f.free();
}

fn void indvar_simplifies_stepped_exit_without_removing_loop() @test
{
	OptFixture f;
	f.init();
	f.lower("int step_three(void) { int i = 0; while (i < 10) i += 3; return i; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "step_three");
	assert(ir_opt::indvar_simplify(&f.graph, decl), "the constant stepped exit should be simplified");
	f.verify_graph();
	assert(is_int_constant(decl, return_value(decl), f.graph.interner, 12),
		"the step-3 loop should exit at the first value not below 10");
	assert(count_body_tag(decl, ir::InstTag.BRANCH) != 0,
		"folding the stepped exit must preserve its loop branch");
	f.free();
}

fn void indvar_do_while_latch_exit() @test
{
	OptFixture f;
	f.init();
	f.lower("int do_while_exit(void) { int i = 0; do { i++; } while (i < 5); return i; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "do_while_exit");
	ir_opt::indvar_simplify(&f.graph, decl);
	f.verify_graph();
	assert(is_int_constant(decl, return_value(decl), f.graph.interner, 5),
		"the do/while latch exit should be the constant bound 5");
	f.free();
}

fn void indvar_unknown_bound_untouched() @test
{
	OptFixture f;
	f.init();
	f.lower("int unknown_bound(int bound) { int i = 0; while (i < bound) i++; return i; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "unknown_bound");
	ir_opt::indvar_simplify(&f.graph, decl);
	f.verify_graph();
	Ref exit_value = return_value(decl);
	assert(exit_value != ir::NONE && decl.instructions[(sz)exit_value].tag != ir::InstTag.CONSTANT,
		"the unknown-bound exit must not be replaced with a constant");
	f.free();
}

fn void indvar_does_not_fold_unreachable_odd_unsigned_exit() @test
{
	OptFixture f;
	f.init();
	// This loop never reaches 7; exercise the pass only and never execute this fixture.
	f.lower("unsigned int unreachable_exit(void) { unsigned int i = 0; while (i != 7) i += 2; return i; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "unreachable_exit");
	ir_opt::indvar_simplify(&f.graph, decl);
	f.verify_graph();
	Ref exit_value = return_value(decl);
	assert(!is_int_constant(decl, exit_value, f.graph.interner, 7),
		"the unreachable odd exit value must not be substituted");
	assert(count_body_tag(decl, ir::InstTag.BRANCH) != 0,
		"the nonterminating unsigned loop must retain its control branch");
	f.free();
}

fn void indvar_simplifies_unsigned_char_for_exit_without_removing_loop() @test
{
	OptFixture f;
	f.init();
	f.lower("unsigned char wrap_cap(void) { unsigned char c = 250; for (; c != 4; c++) {} return c; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "wrap_cap");
	assert(ir_opt::indvar_simplify(&f.graph, decl), "the unsigned-char exit should be simplified");
	f.verify_graph();
	assert(is_int_constant(decl, return_value(decl), f.graph.interner, 4),
		"the unsigned-char loop should exit after wrapping to 4");
	assert(count_body_tag(decl, ir::InstTag.BRANCH) != 0,
		"folding the unsigned-char exit must preserve its loop branch");
	f.free();
}

fn void indvar_simplifies_signed_char_sext_exit() @test
{
	OptFixture f;
	f.init();
	f.lower("signed char count_up(void) { signed char c = -3; while (c != 2) c++; return c; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "count_up");
	assert(count_body_tag(decl, ir::InstTag.SEXT) != 0, "the signed-char compare should be promoted with SEXT");
	assert(ir_opt::indvar_simplify(&f.graph, decl), "the signed-char exit should be simplified");
	f.verify_graph();
	assert(is_int_constant(decl, return_value(decl), f.graph.interner, 2),
		"the signed-char loop should exit at 2");
	assert(count_body_tag(decl, ir::InstTag.BRANCH) != 0,
		"folding the signed-char exit must preserve its loop branch");
	f.free();
}

fn void compact_drops_tombstones_and_keeps_ir_valid() @test
{
	// After -O2, passes leave replaced instructions unplaced; compaction drops
	// them, renumbers operands/labels/PHI edges, and must keep the IR valid.
	OptFixture f;
	f.init();
	f.lower("static int sq(int x) { return x * x; }\n"
		"int sum(int n, int *p) { int s = 0; for (int i = 0; i < n; i++) { if (p[i] > 3) s += sq(p[i]); else s -= i; } return s; }\n"
		"int pick(int c) { switch (c) { case 1: return 10; case 2: return 20; default: return sum(c, &c); } }");
	f.run_o2();
	usz before = 0;
	foreach (&decl : f.graph.decls) before += decl.instructions.len;
	ir_opt::compact(&f.graph);
	f.verify_graph();
	usz after = 0;
	foreach (&decl : f.graph.decls)
	{
		after += decl.instructions.len;
		foreach (ref : decl.body) assert((usz)ref < (usz)decl.instructions.len, "body refs must be renumbered into range");
	}
	assert(after < before, "compaction should drop the optimizer's unplaced instructions");
	f.free();
}

fn void codegen_dead_return_adds_no_return_phi_input() @test
{
	// sqlite numericType: `return f(p); return 0;` must not give the return
	// PHI a second input from the same, already terminated block.
	OptFixture f;
	f.init();
	f.lower("short g(int *p);\nshort numeric(int *p) { if (*p & 45) return *p & 45; return g(p); return 0; }");
	f.verify_graph();
	f.free();
}

fn void codegen_int_pointer_casts_keep_ir_types() @test
{
	// `c ? (void*)(long)i : p` must give the PHI ptr-typed inputs on both arms.
	OptFixture f;
	f.init();
	f.lower("void *pick(int c, int i, void *p) { return c ? (void *)(long)i : p; }\n"
		"long back(int c, void *p, long v) { return c ? (long)p : v; }");
	f.verify_graph();
	f.free();
}

fn void o1_sink_keeps_differently_typed_extension_operands_apart() @test
{
	// sqlite VdbeExec: `x += f8(t)` / `x += f32(t)` on two arms are zext from
	// i8 and from i32; sinking the zext would build an i8/i32 operand PHI.
	OptFixture f;
	f.init();
	f.lower("unsigned char one(unsigned char);\nunsigned two(unsigned);\n"
		"unsigned long long add_len(int c, unsigned t, unsigned long long off) { if (c) off += one((unsigned char)t); else off += two(t); return off; }");
	f.run_o1();
	f.free();
}

fn void mem_opt_keeps_write_only_alloc_passed_to_call() @test
{
	// sqlite powerOfTen(p, &lo) with lo never read: the alloc is a dead store
	// target, but the call still needs its address.
	OptFixture f;
	f.init();
	f.lower("__attribute__((noinline)) static unsigned long long power(int p, unsigned *lo) { *lo = (unsigned)p; return (unsigned long long)p * 3; }\n"
		"unsigned long long use_power(int p) { unsigned lo; return power(p, &lo); }");
	f.run_o2();
	ir::Decl* decl = find_function(&f.graph, "use_power");
	bool saw_call = false;
	foreach (ref : decl.body)
	{
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag != ir::InstTag.CALL || inst.data.call.args.len != 2) continue;
		saw_call = true;
		ir::Ref lo = inst.data.call.args[1];
		bool placed = false;
		foreach (other : decl.body) if (other == lo) placed = true;
		assert(placed, "the alloc passed to the write-only call argument must stay in the body");
	}
	assert(saw_call, "power should stay a call (noinline)");
	f.free();
}

fn void codegen_bool_ternary_arm_jumps_to_short_circuit_exit() @test
{
	// The then-arm of `b ? a : b` under `!` feeds the && exit directly; it must
	// jump there instead of falling through into the else block.
	OptFixture f;
	f.init();
	f.lower("int f5(int a, int b) { return a && !(b ? a : b); }");
	f.verify_graph();
	f.free();
}

fn void compute_loops_links_nested_loop_parents() @test
{
	OptFixture f;
	f.init();
	f.lower("int nest(int n) { int c = 0; for (int k = 0; k < n; k++) for (int m = 0; m < n; m++) c += m != k; return c; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "nest");
	ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
	cfg.compute_dominators();
	ir_opt::LoopInfo loops = ir_opt::compute_loops(&cfg, &f.ta);
	assert(loops.loops.len() == 2, "fixture should have an outer and an inner loop");
	ir_opt::Loop* inner = &loops.loops.entries[0];
	ir_opt::Loop* outer = &loops.loops.entries[1];
	assert(inner.blocks.len() < outer.blocks.len(), "loops are sorted innermost first");
	assert(inner.parent == 1 && outer.parent == ir_opt::NONE_BLOCK, "the inner loop's parent must be the outer loop");
	assert(inner.depth == 2 && outer.depth == 1, "loop depths should follow the nest");
	assert(outer.contains(&loops, inner.header), "the outer loop contains the inner loop's blocks");
	loops.free();
	cfg.free();
	f.free();
}

fn void indvar_keeps_outer_iv_used_inside_inner_loop() @test
{
	// k's exit value is 4, but the use of k inside the inner loop is still in
	// k's loop and must not be replaced by it.
	OptFixture f;
	f.init();
	f.lower("int nest(void) { int c = 0; for (int k = 0; k < 4; k++) for (int m = 0; m < 4; m++) { if (m == k) continue; c++; } return c; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "nest");
	ir_opt::indvar_simplify(&f.graph, decl);
	f.verify_graph();
	foreach (ref : decl.body)
	{
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag != ir::InstTag.CMP_EQ) continue;
		assert(!is_int_constant(decl, inst.data.bin.lhs, f.graph.interner, 4) &&
			!is_int_constant(decl, inst.data.bin.rhs, f.graph.interner, 4),
			"m == k inside the inner loop must keep using k, not its exit value");
	}
	f.free();
}

fn void licm_hoists_to_the_outermost_valid_nested_preheader() @test
{
	HandIrFixture f;
	f.init();
	Ref outer_condition = f.builder.add_arg(value_interner::REF_I1);
	Ref inner_condition = f.builder.add_arg(value_interner::REF_I1);
	Ref initial_outer = f.builder.add_arg(value_interner::REF_I32);
	Ref initial_inner = f.builder.add_arg(value_interner::REF_I32);
	Ref left = f.builder.add_arg(value_interner::REF_I32);
	Ref right = f.builder.add_arg(value_interner::REF_I32);
	Ref one = f.add_int_constant(1, value_interner::REF_I32);
	f.builder.start_fn();
	Ref entry = f.builder.current_label;
	Ref outer_header = f.builder.make_label("outer_header");
	Ref outer_body = f.builder.make_label("outer_body");
	Ref inner_header = f.builder.make_label("inner_header");
	Ref inner_body = f.builder.make_label("inner_body");
	Ref outer_latch = f.builder.make_label("outer_latch");
	Ref exit = f.builder.make_label("exit");
	f.builder.add_jump(outer_header);
	f.builder.start_block(outer_header);
	ir::PhiInput[2] outer_inputs = {
		{ .label = entry, .value = initial_outer },
		{ .label = outer_latch, .value = initial_outer },
	};
	Ref outer_phi = f.builder.add_phi(outer_inputs[..], value_interner::REF_I32);
	f.builder.add_branch(outer_condition, outer_body, exit);
	f.builder.start_block(outer_body);
	f.builder.add_jump(inner_header);
	f.builder.start_block(inner_header);
	ir::PhiInput[2] inner_inputs = {
		{ .label = outer_body, .value = initial_inner },
		{ .label = inner_body, .value = initial_inner },
	};
	Ref inner_phi = f.builder.add_phi(inner_inputs[..], value_interner::REF_I32);
	f.builder.add_branch(inner_condition, inner_body, outer_latch);
	f.builder.start_block(inner_body);
	Ref args_only = f.builder.add_inst(ir::InstTag.ADD, { .bin = { left, right } }, value_interner::REF_I32);
	Ref uses_outer_phi = f.builder.add_inst(ir::InstTag.ADD, { .bin = { outer_phi, right } }, value_interner::REF_I32);
	Ref inner_next = f.builder.add_inst(ir::InstTag.ADD, { .bin = { inner_phi, one } }, value_interner::REF_I32);
	f.builder.add_jump(inner_header);
	f.builder.start_block(outer_latch);
	Ref outer_next = f.builder.add_inst(ir::InstTag.ADD, { .bin = { outer_phi, one } }, value_interner::REF_I32);
	f.builder.add_jump(outer_header);
	f.builder.start_block(exit);
	f.builder.add_return(outer_phi);
	f.builder.finish_fn("nested_licm_preheaders");
	f.finish();
	// Patch each loop-carried PHI to its update after all instruction refs exist.
	ir_opt::DeclEditor editor;
	editor.begin(&f.graph.decls[0]);
	editor.insts.entries[(sz)outer_phi].data.phi[1].value = outer_next;
	editor.insts.entries[(sz)inner_phi].data.phi[1].value = inner_next;
	editor.commit();
	ir::Decl* decl = &f.graph.decls[0];
	ir_opt::loop_invariant_code_motion(&f.graph, decl);
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "LICM produced invalid nested-loop IR: %s", errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	errors.free();

	ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
	cfg.compute_dominators();
	uint outer_header_block = block_for_label(&cfg, outer_header);
	uint inner_header_block = block_for_label(&cfg, inner_header);
	uint args_only_block = ir_opt::NONE_BLOCK;
	uint uses_outer_phi_block = ir_opt::NONE_BLOCK;
	foreach (block_index, block : cfg.blocks)
	{
		for (sz pos = block.start; pos < block.end; pos++)
		{
			if (decl.body[pos] == args_only) args_only_block = (uint)block_index;
			if (decl.body[pos] == uses_outer_phi) uses_outer_phi_block = (uint)block_index;
		}
	}
	assert(args_only_block != ir_opt::NONE_BLOCK && uses_outer_phi_block != ir_opt::NONE_BLOCK,
		"both invariant expressions should remain in the CFG");
	assert(!cfg.dominates(outer_header_block, args_only_block),
		"an expression of two ARGs should hoist outside both nested loops");
	assert(cfg.dominates(outer_header_block, uses_outer_phi_block) && !cfg.dominates(inner_header_block, uses_outer_phi_block),
		"an expression using the outer induction PHI should hoist to the inner preheader inside the outer loop");
	cfg.free();
	f.free();
}

fn void licm_keeps_loop_variant_add_in_loop() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref left = f.builder.add_arg(value_interner::REF_I32);
	Ref one = f.add_int_constant(1, value_interner::REF_I32);
	f.builder.start_fn();
	Ref entry = f.builder.current_label;
	Ref header = f.builder.make_label("header");
	Ref body = f.builder.make_label("body");
	Ref exit = f.builder.make_label("exit");
	f.builder.add_jump(header);
	f.builder.start_block(header);
	ir::PhiInput[2] inputs = {
		{ .label = entry, .value = left },
		{ .label = body, .value = left },
	};
	Ref phi = f.builder.add_phi(inputs[..], value_interner::REF_I32);
	f.builder.add_branch(condition, body, exit);
	f.builder.start_block(body);
	Ref variant = f.builder.add_inst(ir::InstTag.ADD, { .bin = { phi, one } }, value_interner::REF_I32);
	f.builder.add_jump(header);
	f.builder.start_block(exit);
	f.builder.add_return(left);
	f.builder.finish_fn("variant_add");
	f.finish();
	ir_opt::DeclEditor editor;
	editor.begin(&f.graph.decls[0]);
	editor.insts.entries[(sz)phi].data.phi[1].value = variant;
	editor.commit();
	ir::Decl* decl = &f.graph.decls[0];
	ir_opt::loop_invariant_code_motion(&f.graph, decl);
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "LICM produced invalid IR: %s", errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	errors.free();
	ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
	cfg.compute_dominators();
	uint variant_block = ir_opt::NONE_BLOCK;
	foreach (block_index, block : cfg.blocks)
	{
		for (sz pos = block.start; pos < block.end; pos++)
		{
			if (decl.body[pos] == variant) variant_block = (uint)block_index;
		}
	}
	assert(variant_block != ir_opt::NONE_BLOCK && cfg.dominates(block_for_label(&cfg, header), variant_block),
		"an ADD with loop-variant operands must remain inside the loop");
	cfg.free();
	f.free();
}

fn void licm_only_hoists_division_with_safe_constant_divisor() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref dividend = f.builder.add_arg(value_interner::REF_I32);
	Ref variable_divisor = f.builder.add_arg(value_interner::REF_I32);
	Ref zero = f.add_int_constant(0, value_interner::REF_I32);
	Ref negative_one = f.add_int_constant(-1, value_interner::REF_I32);
	Ref two = f.add_int_constant(2, value_interner::REF_I32);
	f.builder.start_fn();
	Ref header = f.builder.make_label("header");
	Ref body = f.builder.make_label("body");
	Ref exit = f.builder.make_label("exit");
	f.builder.add_jump(header);
	f.builder.start_block(header);
	f.builder.add_branch(condition, body, exit);
	f.builder.start_block(body);
	Ref variable = f.builder.add_inst(ir::InstTag.SDIV, { .bin = { dividend, variable_divisor } }, value_interner::REF_I32);
	Ref zero_divisor = f.builder.add_inst(ir::InstTag.SDIV, { .bin = { dividend, zero } }, value_interner::REF_I32);
	Ref negative_one_divisor = f.builder.add_inst(ir::InstTag.SDIV, { .bin = { dividend, negative_one } }, value_interner::REF_I32);
	Ref safe = f.builder.add_inst(ir::InstTag.SDIV, { .bin = { dividend, two } }, value_interner::REF_I32);
	f.builder.add_jump(header);
	f.builder.start_block(exit);
	f.builder.add_return(dividend);
	f.builder.finish_fn("division_policy");
	f.finish();
	ir::Decl* decl = &f.graph.decls[0];
	ir_opt::loop_invariant_code_motion(&f.graph, decl);
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "LICM produced invalid IR: %s", errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	errors.free();
	ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
	cfg.compute_dominators();
	uint header_block = block_for_label(&cfg, header);
	uint variable_block = ir_opt::NONE_BLOCK;
	uint zero_block = ir_opt::NONE_BLOCK;
	uint negative_one_block = ir_opt::NONE_BLOCK;
	uint safe_block = ir_opt::NONE_BLOCK;
	foreach (block_index, block : cfg.blocks)
	{
		for (sz pos = block.start; pos < block.end; pos++)
		{
			Ref ref = decl.body[pos];
			if (ref == variable) variable_block = (uint)block_index;
			if (ref == zero_divisor) zero_block = (uint)block_index;
			if (ref == negative_one_divisor) negative_one_block = (uint)block_index;
			if (ref == safe) safe_block = (uint)block_index;
		}
	}
	assert(cfg.dominates(header_block, variable_block) && cfg.dominates(header_block, zero_block) &&
		cfg.dominates(header_block, negative_one_block),
		"variable, zero, and signed negative-one divisors must stay in the loop");
	assert(!cfg.dominates(header_block, safe_block), "a safe constant divisor should allow the division to hoist");
	cfg.free();
	f.free();
}

fn void check_licm_load_case(uint scenario, bool should_hoist)
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref dynamic_offset = f.builder.add_arg(value_interner::REF_I64);
	Ref external_pointer = f.builder.add_arg(value_interner::REF_PTR);
	Ref value = f.add_int_constant(1, value_interner::REF_I32);
	f.builder.start_fn();
	Ref slot = f.builder.add_alloc(16, 8, scenario == 5);
	Ref other_slot = f.builder.add_alloc(16, 8);
	Ref zero = f.add_int_constant(0, value_interner::REF_I64);
	Ref sixteen = f.add_int_constant(16, value_interner::REF_I64);
	Ref load_offset = scenario == 7 ? dynamic_offset : (scenario == 8 ? sixteen : zero);
	Ref load_pointer = scenario == 6 ? external_pointer :
		f.builder.add_inst(ir::InstTag.ADD, { .bin = { slot, load_offset } }, value_interner::REF_PTR);
	Ref header = f.builder.make_label("header");
	Ref body = f.builder.make_label("body");
	Ref exit = f.builder.make_label("exit");
	f.builder.add_jump(header);
	f.builder.start_block(header);
	f.builder.add_branch(condition, body, exit);
	f.builder.start_block(body);
	if (scenario == 0)
	{
		Ref variable_pointer = f.builder.add_inst(ir::InstTag.ADD, { .bin = { other_slot, dynamic_offset } }, value_interner::REF_PTR);
		f.builder.add_store(variable_pointer, value);
	}
	if (scenario == 2 || scenario == 3)
	{
		Ref store_offset = scenario == 2 ? zero : dynamic_offset;
		Ref store_pointer = f.builder.add_inst(ir::InstTag.ADD, { .bin = { slot, store_offset } }, value_interner::REF_PTR);
		f.builder.add_store(store_pointer, value);
	}
	if (scenario == 1 || scenario == 4)
	{
		Ref callee = f.builder.add_symbol("external_effect", value_interner::REF_PTR);
		Ref[1] args = { scenario == 4 ? slot : value };
		f.builder.add_call(callee, args[..], value_interner::REF_VOID);
	}
	Ref load = f.builder.add_load(load_pointer, value_interner::REF_I32);
	f.builder.add_inst(ir::InstTag.ADD, { .bin = { load, value } }, value_interner::REF_I32);
	f.builder.add_jump(header);
	f.builder.start_block(exit);
	f.builder.add_return(value);
	f.builder.finish_fn("licm_load_case");
	f.finish();
	ir::Decl* decl = &f.graph.decls[0];
	ir_opt::loop_invariant_code_motion(&f.graph, decl);
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "LICM load fixture produced invalid IR: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	assert(errors.len() == 0, "valid LICM load fixture reported verifier errors");
	errors.free();
	ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
	cfg.compute_dominators();
	uint header_block = block_for_label(&cfg, header);
	uint load_block = cfg.block_of_ref[(sz)load];
	assert(load_block != ir_opt::NONE_BLOCK, "load must remain in the function CFG");
	if (should_hoist)
	{
		assert(!cfg.dominates(header_block, load_block), "safe invariant load should move before the loop header");
	}
	else
	{
		assert(cfg.dominates(header_block, load_block), "unsafe load must stay inside the loop");
	}
	cfg.free();
	f.free();
}

fn void licm_hoists_load_across_unrelated_store() @test
{
	check_licm_load_case(0, true);
}

fn void licm_hoists_load_across_call_when_alloca_does_not_escape() @test
{
	check_licm_load_case(1, true);
}

fn void licm_keeps_unsafe_loads_in_loop() @test
{
	check_licm_load_case(2, false); // Overlapping store to the same allocation.
	check_licm_load_case(3, false); // Unknown store offset to the same allocation.
	check_licm_load_case(4, false); // Passing the allocation to a call makes it escape.
	check_licm_load_case(5, false); // Volatile allocations are never hoisted.
	check_licm_load_case(6, false); // An argument pointer may be volatile MMIO.
	check_licm_load_case(7, false); // Unknown load offset cannot prove dereferenceability.
	check_licm_load_case(8, false); // Out-of-bounds load cannot be speculated.
}

fn void licm_preheader_merges_distinct_outside_phi_values() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref first_value = f.builder.add_arg(value_interner::REF_I32);
	Ref second_value = f.builder.add_arg(value_interner::REF_I32);
	Ref one = f.add_int_constant(1, value_interner::REF_I32);
	f.builder.start_fn();
	Ref first = f.builder.make_label("first");
	Ref second = f.builder.make_label("second");
	Ref header = f.builder.make_label("header");
	Ref body = f.builder.make_label("body");
	Ref exit = f.builder.make_label("exit");
	f.builder.add_branch(condition, first, second);
	f.builder.start_block(first);
	f.builder.add_jump(header);
	f.builder.start_block(second);
	f.builder.add_jump(header);
	f.builder.start_block(header);
	ir::PhiInput[3] inputs = {
		{ .label = first, .value = first_value },
		{ .label = second, .value = second_value },
		{ .label = body, .value = first_value },
	};
	Ref phi = f.builder.add_phi(inputs[..], value_interner::REF_I32);
	f.builder.add_branch(condition, body, exit);
	f.builder.start_block(body);
	Ref updated = f.builder.add_inst(ir::InstTag.ADD, { .bin = { phi, one } }, value_interner::REF_I32);
	f.builder.add_jump(header);
	// The back-edge PHI value comes from the loop update.
	f.builder.start_block(exit);
	f.builder.add_return(phi);
	f.builder.finish_fn("distinct_preheader_phi");
	f.finish();
	ir_opt::DeclEditor editor;
	editor.begin(&f.graph.decls[0]);
	editor.insts.entries[(sz)phi].data.phi[2].value = updated;
	editor.commit();
	ir::Decl* decl = &f.graph.decls[0];
	ir_opt::loop_invariant_code_motion(&f.graph, decl);
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "LICM produced invalid IR: %s", errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	errors.free();
	ir_opt::Cfg cfg = ir_opt::build_cfg(decl, &f.ta);
	uint header_block = block_for_label(&cfg, header);
	assert(cfg.blocks[(sz)header_block].preds.len() == 2,
		"the header should have one inserted preheader and its loop back edge");
	bool has_backedge = false;
	foreach (pred : cfg.blocks[(sz)header_block].preds)
		if (cfg.blocks[(sz)pred].label == body) has_backedge = true;
	assert(has_backedge, "preheader insertion should preserve the loop back edge");
	Ref preheader_label = cfg.blocks[(sz)cfg.blocks[(sz)header_block].preds[0]].label;
	Ref backedge_label = cfg.blocks[(sz)cfg.blocks[(sz)header_block].preds[1]].label;
	if (preheader_label == body) preheader_label = backedge_label;
	assert(preheader_label != body, "an inserted preheader should replace both outside predecessors");
	ir::Inst header_phi = decl.instructions[(sz)phi];
	assert(header_phi.tag == ir::InstTag.PHI && header_phi.data.phi.len == 2,
		"header PHI should merge the preheader and back-edge inputs");
	Ref preheader_value = ir::NONE;
	foreach (input : header_phi.data.phi) if (input.label == preheader_label) preheader_value = input.value;
	assert(preheader_value != ir::NONE, "header PHI should receive its outside value from the preheader");
	ir::Inst merged = decl.instructions[(sz)preheader_value];
	assert(merged.tag == ir::InstTag.PHI && merged.data.phi.len == 2,
		"distinct outside values should be merged by a PHI in the preheader");
	bool saw_first = false;
	bool saw_second = false;
	foreach (input : merged.data.phi)
	{
		if (input.label == first && input.value == first_value) saw_first = true;
		if (input.label == second && input.value == second_value) saw_second = true;
	}
	assert(saw_first && saw_second, "preheader PHI should preserve each outside predecessor's distinct value");
	cfg.free();
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
	assert(uses.of(old_value).len == 2,
		"the SELECT and PHI should both use the old value");
	assert(has_index(uses.of(old_value), select));
	assert(has_index(uses.of(old_value), phi));
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
		"    i32 %3 = load ptr_ty %1\n"
		"    i64 %4 = sext i32 %3\n"
		"    i64 %5 = mul i64 %4, i64 4\n"
		"    ptr_ty %6 = stack_save\n"
		"    ptr_ty %7 = dyn_alloc i64 %5 align 4\n"
		"    i32 %8 = load ptr_ty %1\n"
		"    i32 %9 = sub nsw i32 %8, i32 1\n"
		"    i64 %10 = sext i32 %9\n"
		"    i64 %11 = mul i64 %10, i64 4\n"
		"    ptr_ty %12 = add ptr_ty %7, i64 %11\n"
		"    store ptr_ty %12, i32 7\n"
		"    i32 %13 = load ptr_ty %1\n"
		"    i32 %14 = sub nsw i32 %13, i32 1\n"
		"    i64 %15 = sext i32 %14\n"
		"    i64 %16 = mul i64 %15, i64 4\n"
		"    ptr_ty %17 = add ptr_ty %7, i64 %16\n"
		"    i32 %18 = load ptr_ty %17\n"
		"    store ptr_ty %2, i32 %18\n"
		"    stack_restore ptr_ty %6\n"
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
		"    jmp user.top.1\n"
		"user.top.1:\n"
		"    i32 %3 = load ptr_ty %1\n"
		"    i64 %4 = sext i32 %3\n"
		"    i64 %5 = mul i64 %4, i64 4\n"
		"    ptr_ty %6 = stack_save\n"
		"    ptr_ty %7 = dyn_alloc i64 %5 align 4\n"
		"    i32 %8 = load ptr_ty %2\n"
		"    i64 %9 = sext i32 0\n"
		"    i64 %10 = mul i64 %9, i64 4\n"
		"    ptr_ty %11 = add ptr_ty %7, i64 %10\n"
		"    store ptr_ty %11, i32 %8\n"
		"    i32 %12 = load ptr_ty %2\n"
		"    i32 %13 = add nsw i32 %12, i32 1\n"
		"    store ptr_ty %2, i32 %13\n"
		"    i32 %14 = load ptr_ty %2\n"
		"    i1 %15 = cmp_slt i32 %14, i32 3\n"
		"    branch i1 %15, if.then.2, if.end.4\n"
		"if.then.2:\n"
		"    stack_restore ptr_ty %6\n"
		"    jmp user.top.1\n"
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
		"    stack_restore ptr_ty %6\n"
		"    jmp user.out.8\n"
		"user.out.8:\n"
		"    i32 %18 = load ptr_ty %2\n"
		"    ret i32 %18\n"
		"goto.vla.9:\n"
		"    stack_restore ptr_ty %6\n"
		"    jmp user.out.8\n"
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

fn void o1_folds_constant_float_arithmetic_and_ieee_comparisons() @test
{
	HandIrFixture f;
	f.init();
	f.builder.start_fn();
	Ref one_point_five = f.add_f64_constant(0x3FF8_0000_0000_0000);
	Ref two_point_two_five = f.add_f64_constant(0x4002_0000_0000_0000);
	Ref sum = f.builder.add_inst(ir::InstTag.FADD, { .bin = { one_point_five, two_point_two_five } }, value_interner::REF_F64);
	f.builder.add_return(sum);
	f.builder.finish_fn("fold_fadd");
	f.builder.start_fn();
	Ref five_point_five = f.add_f64_constant(0x4016_0000_0000_0000);
	Ref two = f.add_f64_constant(0x4000_0000_0000_0000);
	Ref difference = f.builder.add_inst(ir::InstTag.FSUB, { .bin = { five_point_five, two } }, value_interner::REF_F64);
	f.builder.add_return(difference);
	f.builder.finish_fn("fold_fsub");
	f.builder.start_fn();
	one_point_five = f.add_f64_constant(0x3FF8_0000_0000_0000);
	two = f.add_f64_constant(0x4000_0000_0000_0000);
	Ref product = f.builder.add_inst(ir::InstTag.FMUL, { .bin = { one_point_five, two } }, value_interner::REF_F64);
	f.builder.add_return(product);
	f.builder.finish_fn("fold_fmul");
	f.builder.start_fn();
	Ref nine = f.add_f64_constant(0x4022_0000_0000_0000);
	Ref four = f.add_f64_constant(0x4010_0000_0000_0000);
	Ref quotient = f.builder.add_inst(ir::InstTag.FDIV, { .bin = { nine, four } }, value_interner::REF_F64);
	f.builder.add_return(quotient);
	f.builder.finish_fn("fold_fdiv");
	f.builder.start_fn();
	Ref positive_zero = f.add_f64_constant(0);
	Ref fneg_zero_operand = positive_zero;
	Ref negated_zero = f.builder.add_inst(ir::InstTag.FNEG, { .ref = fneg_zero_operand }, value_interner::REF_F64);
	f.builder.add_return(negated_zero);
	f.builder.finish_fn("fold_fneg_zero");
	f.builder.start_fn();
	Ref zero_dividend = f.add_f64_constant(0);
	Ref zero_divisor = f.add_f64_constant(0);
	Ref zero_over_zero = f.builder.add_inst(ir::InstTag.FDIV,
		{ .bin = { zero_dividend, zero_divisor } }, value_interner::REF_F64);
	f.builder.add_return(zero_over_zero);
	f.builder.finish_fn("keep_zero_over_zero_fdiv");
	f.builder.start_fn();
	Ref positive_infinity = f.add_f64_constant(0x7FF0_0000_0000_0000);
	Ref infinity_minus_infinity = f.builder.add_inst(ir::InstTag.FSUB,
		{ .bin = { positive_infinity, positive_infinity } }, value_interner::REF_F64);
	f.builder.add_return(infinity_minus_infinity);
	f.builder.finish_fn("keep_infinity_minus_infinity_fsub");
	f.builder.start_fn();
	Ref nan = f.add_f64_constant(0x7FF8_0000_0000_0000);
	Ref nan_eq = f.builder.add_inst(ir::InstTag.FCMP_OEQ, { .bin = { nan, nan } }, value_interner::REF_I1);
	f.builder.add_return(nan_eq);
	f.builder.finish_fn("fold_nan_oeq");
	f.builder.start_fn();
	nan = f.add_f64_constant(0x7FF8_0000_0000_0000);
	Ref nan_ne = f.builder.add_inst(ir::InstTag.FCMP_UNE, { .bin = { nan, nan } }, value_interner::REF_I1);
	f.builder.add_return(nan_ne);
	f.builder.finish_fn("fold_nan_une");
	f.builder.start_fn();
	nan = f.add_f64_constant(0x7FF8_0000_0000_0000);
	one_point_five = f.add_f64_constant(0x3FF8_0000_0000_0000);
	Ref nan_lt = f.builder.add_inst(ir::InstTag.FCMP_OLT, { .bin = { nan, one_point_five } }, value_interner::REF_I1);
	f.builder.add_return(nan_lt);
	f.builder.finish_fn("fold_nan_olt");
	f.builder.start_fn();
	nan = f.add_f64_constant(0x7FF8_0000_0000_0000);
	one_point_five = f.add_f64_constant(0x3FF8_0000_0000_0000);
	Ref nan_le = f.builder.add_inst(ir::InstTag.FCMP_OLE, { .bin = { nan, one_point_five } }, value_interner::REF_I1);
	f.builder.add_return(nan_le);
	f.builder.finish_fn("fold_nan_ole");
	f.builder.start_fn();
	nan = f.add_f64_constant(0x7FF8_0000_0000_0000);
	one_point_five = f.add_f64_constant(0x3FF8_0000_0000_0000);
	Ref nan_gt = f.builder.add_inst(ir::InstTag.FCMP_OGT, { .bin = { nan, one_point_five } }, value_interner::REF_I1);
	f.builder.add_return(nan_gt);
	f.builder.finish_fn("fold_nan_ogt");
	f.builder.start_fn();
	nan = f.add_f64_constant(0x7FF8_0000_0000_0000);
	one_point_five = f.add_f64_constant(0x3FF8_0000_0000_0000);
	Ref nan_ge = f.builder.add_inst(ir::InstTag.FCMP_OGE, { .bin = { nan, one_point_five } }, value_interner::REF_I1);
	f.builder.add_return(nan_ge);
	f.builder.finish_fn("fold_nan_oge");
	f.builder.start_fn();
	one_point_five = f.add_f64_constant(0x3FF8_0000_0000_0000);
	Ref finite_une = f.builder.add_inst(ir::InstTag.FCMP_UNE,
		{ .bin = { one_point_five, one_point_five } }, value_interner::REF_I1);
	f.builder.add_return(finite_une);
	f.builder.finish_fn("fold_equal_une");
	f.builder.start_fn();
	positive_zero = f.add_f64_constant(0);
	Ref negative_zero = f.add_f64_constant(0x8000_0000_0000_0000);
	Ref zero_eq = f.builder.add_inst(ir::InstTag.FCMP_OEQ,
		{ .bin = { positive_zero, negative_zero } }, value_interner::REF_I1);
	f.builder.add_return(zero_eq);
	f.builder.finish_fn("fold_signed_zero_oeq");
	f.run_o1();

	assert(is_f64_constant(find_function(&f.graph, "fold_fadd"),
		return_value(find_function(&f.graph, "fold_fadd")), &f.interner, 0x400E_0000_0000_0000),
		"constant FADD should fold to 3.75");
	assert(is_f64_constant(find_function(&f.graph, "fold_fsub"),
		return_value(find_function(&f.graph, "fold_fsub")), &f.interner, 0x400C_0000_0000_0000),
		"constant FSUB should fold to 3.5");
	assert(is_f64_constant(find_function(&f.graph, "fold_fmul"),
		return_value(find_function(&f.graph, "fold_fmul")), &f.interner, 0x4008_0000_0000_0000),
		"constant FMUL should fold to 3.0");
	assert(is_f64_constant(find_function(&f.graph, "fold_fdiv"),
		return_value(find_function(&f.graph, "fold_fdiv")), &f.interner, 0x4002_0000_0000_0000),
		"constant FDIV should fold to 2.25");
	ir::Decl* fneg_decl = find_function(&f.graph, "fold_fneg_zero");
	Ref fneg_result = return_value(fneg_decl);
	assert((usz)fneg_result < (usz)fneg_decl.instructions.len &&
		fneg_decl.instructions[(sz)fneg_result].tag == ir::InstTag.FNEG &&
		fneg_decl.instructions[(sz)fneg_result].data.ref == fneg_zero_operand,
		"constant FNEG must remain in IR");
	ir::Decl* zero_division_decl = find_function(&f.graph, "keep_zero_over_zero_fdiv");
	Ref zero_division_result = return_value(zero_division_decl);
	assert((usz)zero_division_result < (usz)zero_division_decl.instructions.len &&
		zero_division_decl.instructions[(sz)zero_division_result].tag == ir::InstTag.FDIV,
		"0.0 / 0.0 must remain as FDIV");
	ir::Decl* infinity_subtraction_decl = find_function(&f.graph, "keep_infinity_minus_infinity_fsub");
	Ref infinity_subtraction_result = return_value(infinity_subtraction_decl);
	assert((usz)infinity_subtraction_result < (usz)infinity_subtraction_decl.instructions.len &&
		infinity_subtraction_decl.instructions[(sz)infinity_subtraction_result].tag == ir::InstTag.FSUB,
		"infinity - infinity must remain as FSUB");
	assert(is_bool_constant(find_function(&f.graph, "fold_nan_oeq"),
		return_value(find_function(&f.graph, "fold_nan_oeq")), value_interner::REF_ZERO),
		"ordered equality of NaN must fold to false");
	assert(is_bool_constant(find_function(&f.graph, "fold_nan_une"),
		return_value(find_function(&f.graph, "fold_nan_une")), value_interner::REF_ONE),
		"unordered inequality of NaN must fold to true");
	assert(is_bool_constant(find_function(&f.graph, "fold_nan_olt"),
		return_value(find_function(&f.graph, "fold_nan_olt")), value_interner::REF_ZERO),
		"ordered less-than with NaN must fold to false");
	assert(is_bool_constant(find_function(&f.graph, "fold_nan_ole"),
		return_value(find_function(&f.graph, "fold_nan_ole")), value_interner::REF_ZERO),
		"ordered less-than-or-equal with NaN must fold to false");
	assert(is_bool_constant(find_function(&f.graph, "fold_nan_ogt"),
		return_value(find_function(&f.graph, "fold_nan_ogt")), value_interner::REF_ZERO),
		"ordered greater-than with NaN must fold to false");
	assert(is_bool_constant(find_function(&f.graph, "fold_nan_oge"),
		return_value(find_function(&f.graph, "fold_nan_oge")), value_interner::REF_ZERO),
		"ordered greater-than-or-equal with NaN must fold to false");
	assert(is_bool_constant(find_function(&f.graph, "fold_equal_une"),
		return_value(find_function(&f.graph, "fold_equal_une")), value_interner::REF_ZERO),
		"unordered inequality must fold to false for equal finite operands");
	assert(is_bool_constant(find_function(&f.graph, "fold_signed_zero_oeq"),
		return_value(find_function(&f.graph, "fold_signed_zero_oeq")), value_interner::REF_ONE),
		"ordered equality must treat positive and negative zero as equal");
	f.free();
}

fn void o1_folds_promoted_float_locals_conversions_and_branch_conditions() @test
{
	OptFixture source;
	source.init();
	source.lower(
		"float promoted_product(void) { float a = 1.5f; float b = 2.0f; return a * b; }\n"
		"int float_compare_branch(void) { double n = 1.0 / 0.0; if (n < 0.0) return 1; return 2; }\n");
	source.run_o1();
	ir::Decl* product = find_function(&source.graph, "promoted_product");
	assert(count_body_tag(product, ir::InstTag.ALLOC) == 0 && count_body_tag(product, ir::InstTag.LOAD) == 0 &&
		count_body_tag(product, ir::InstTag.STORE) == 0, "constant float locals should be promoted before FMUL folding");
	Ref product_result = return_value(product);
	assert(is_f32_constant(product, product_result, source.graph.interner, 0x40400000),
		"promoted-local FMUL should fold to the exact F32 bits for 3.0");
	ir::Decl* branch = find_function(&source.graph, "float_compare_branch");
	assert(count_body_tag(branch, ir::InstTag.FCMP_OLT) == 0,
		"a folded float comparison feeding a branch should be removed");
	assert(is_bool_constant(branch, return_value(branch), source.comp.interner.put(primitive_value::int_key(2))),
		"the infinity comparison should select the false branch result");
	source.free();

	HandIrFixture f;
	f.init();
	f.builder.start_fn();
	Ref negative_seventeen_million = f.add_int_constant(-16777217, value_interner::REF_I32);
	Ref sitofp = f.builder.add_inst(ir::InstTag.SITOFP, { .ref = negative_seventeen_million }, value_interner::REF_F32);
	f.builder.add_return(sitofp);
	f.builder.finish_fn("fold_sitofp");
	f.builder.start_fn();
	Ref one_point_five_f32 = f.add_f32_constant(0x3FC00000);
	Ref fpext = f.builder.add_inst(ir::InstTag.FPEXT, { .ref = one_point_five_f32 }, value_interner::REF_F64);
	f.builder.add_return(fpext);
	f.builder.finish_fn("fold_fpext");
	f.builder.start_fn();
	Ref one_point_one_f64 = f.add_f64_constant(0x3FF1_9999_9999_999A);
	Ref fptrunc = f.builder.add_inst(ir::InstTag.FPTRUNC, { .ref = one_point_one_f64 }, value_interner::REF_F32);
	f.builder.add_return(fptrunc);
	f.builder.finish_fn("fold_fptrunc");
	f.builder.start_fn();
	// The i64 IR operand stores UINT64_MAX as its two's-complement bit pattern.
	Ref uint64_max = f.builder.add_constant(
		f.interner.put(primitive_value::int_key(-1)), value_interner::REF_I64);
	Ref uitofp = f.builder.add_inst(ir::InstTag.UITOFP, { .ref = uint64_max }, value_interner::REF_F64);
	f.builder.add_return(uitofp);
	f.builder.finish_fn("fold_uitofp");
	f.builder.start_fn();
	Ref minus_123_point_5 = f.add_f32_constant(0xC2F70000);
	Ref fptosi = f.builder.add_inst(ir::InstTag.FPTOSI, { .ref = minus_123_point_5 }, value_interner::REF_I32);
	f.builder.add_return(fptosi);
	f.builder.finish_fn("fold_fptosi");
	f.builder.start_fn();
	Ref one = f.builder.add_constant(value_interner::REF_ONE, value_interner::REF_F32);
	Ref half_ulp = f.add_f32_constant(0x33800000);
	Ref ties_even = f.builder.add_inst(ir::InstTag.FADD, { .bin = { one, half_ulp } }, value_interner::REF_F32);
	f.builder.add_return(ties_even);
	f.builder.finish_fn("fold_f32_ties_even");
	f.builder.start_fn();
	one = f.builder.add_constant(value_interner::REF_ONE, value_interner::REF_F32);
	Ref two = f.builder.add_inst(ir::InstTag.FADD, { .bin = { one, one } }, value_interner::REF_F32);
	f.builder.add_return(two);
	f.builder.finish_fn("fold_ref_one_float");
	f.builder.start_fn();
	Ref nan = f.add_f32_constant(0x7FC00001);
	Ref negative_two = f.add_f32_constant(0xC0000000);
	Ref nan_sum = f.builder.add_inst(ir::InstTag.FADD, { .bin = { nan, negative_two } }, value_interner::REF_F32);
	f.builder.add_return(nan_sum);
	f.builder.finish_fn("fold_negative_nan_arithmetic");
	f.run_o1();
	assert(is_f32_constant(&f.graph.decls[0], return_value(find_function(&f.graph, "fold_sitofp")), &f.interner, 0xCB800000),
		"SITOFP should round an inexact integer conversion to the nearest F32 value");
	assert(is_f64_constant(find_function(&f.graph, "fold_fpext"),
		return_value(find_function(&f.graph, "fold_fpext")), &f.interner, 0x3FF8_0000_0000_0000),
		"FPEXT of F32 1.5 should fold to the exact F64 bits");
	assert(is_f32_constant(find_function(&f.graph, "fold_fptrunc"),
		return_value(find_function(&f.graph, "fold_fptrunc")), &f.interner, 0x3F8C_CCCD),
		"FPTRUNC of F64 1.1 should fold to the exact F32 bits");
	assert(is_f64_constant(find_function(&f.graph, "fold_uitofp"),
		return_value(find_function(&f.graph, "fold_uitofp")), &f.interner, 0x43F0_0000_0000_0000),
		"UITOFP of uint64 max should fold to F64 2^64");
	assert(is_bool_constant(find_function(&f.graph, "fold_fptosi"), return_value(find_function(&f.graph, "fold_fptosi")),
		f.interner.put(primitive_value::int_key(-123))), "in-range FPTOSI should truncate toward zero");
	assert(is_f32_constant(find_function(&f.graph, "fold_f32_ties_even"),
		return_value(find_function(&f.graph, "fold_f32_ties_even")), &f.interner, 0x3F800000),
		"hand-built F32 halfway addition should round ties to even");
	assert(is_f32_constant(find_function(&f.graph, "fold_ref_one_float"),
		return_value(find_function(&f.graph, "fold_ref_one_float")), &f.interner, 0x40000000),
		"REF_ONE used as an F32 constant should decode as 1.0");
	ir::Decl* nan_decl = find_function(&f.graph, "fold_negative_nan_arithmetic");
	Ref nan_result = return_value(nan_decl);
	assert((usz)nan_result < (usz)nan_decl.instructions.len && nan_decl.instructions[(sz)nan_result].tag == ir::InstTag.FADD,
		"FADD with a NaN operand must remain in IR");
	f.free();
}

fn void o1_leaves_unsupported_float_casts_and_widths_unfolded() @test
{
	HandIrFixture f;
	f.init();
	primitive_value::F128Bits f128_one = { .lo = 0, .hi = 0x3FFF000000000000 };
	primitive_value::F128Bits f128_two = { .lo = 0, .hi = 0x4000000000000000 };
	f.builder.start_fn();
	Ref too_large = f.add_f64_constant(0x41E0000000000000); // 2^31
	Ref out_of_range = f.builder.add_inst(ir::InstTag.FPTOSI, { .ref = too_large }, value_interner::REF_I32);
	f.builder.add_return(out_of_range);
	f.builder.finish_fn("keep_out_of_range_fptosi");
	f.builder.start_fn();
	Ref negative_one = f.add_f64_constant(0xBFF0000000000000);
	Ref negative_unsigned = f.builder.add_inst(ir::InstTag.FPTOUI, { .ref = negative_one }, value_interner::REF_I32);
	f.builder.add_return(negative_unsigned);
	f.builder.finish_fn("keep_negative_fp_to_unsigned");
	f.builder.start_fn();
	Ref negative_half = f.add_f64_constant(0xBFE0000000000000);
	Ref negative_fraction_unsigned = f.builder.add_inst(ir::InstTag.FPTOUI, { .ref = negative_half }, value_interner::REF_I32);
	f.builder.add_return(negative_fraction_unsigned);
	f.builder.finish_fn("fold_negative_fraction_fp_to_unsigned");
	f.builder.start_fn();
	Ref f16_a = f.builder.add_constant(f.interner.put(primitive_value::f16_value(0x3C00)), value_interner::REF_F16);
	Ref f16_b = f.builder.add_constant(f.interner.put(primitive_value::f16_value(0x4000)), value_interner::REF_F16);
	Ref f16_sum = f.builder.add_inst(ir::InstTag.FADD, { .bin = { f16_a, f16_b } }, value_interner::REF_F16);
	f.builder.add_return(f16_sum);
	f.builder.finish_fn("keep_f16_arithmetic");
	f.builder.start_fn();
	Ref f128_a = f.builder.add_constant(f.interner.put(primitive_value::f128_value(f128_one)), value_interner::REF_F128);
	Ref f128_b = f.builder.add_constant(f.interner.put(primitive_value::f128_value(f128_two)), value_interner::REF_F128);
	Ref f128_sum = f.builder.add_inst(ir::InstTag.FADD, { .bin = { f128_a, f128_b } }, value_interner::REF_F128);
	f.builder.add_return(f128_sum);
	f.builder.finish_fn("keep_f128_arithmetic");
	f.run_o1();
	assert(count_body_tag(find_function(&f.graph, "keep_out_of_range_fptosi"), ir::InstTag.FPTOSI) == 1,
		"out-of-range float-to-signed-int conversion should remain in IR");
	assert(count_body_tag(find_function(&f.graph, "keep_negative_fp_to_unsigned"), ir::InstTag.FPTOUI) == 1,
		"negative one converted to unsigned should remain in IR");
	assert(is_bool_constant(find_function(&f.graph, "fold_negative_fraction_fp_to_unsigned"),
		return_value(find_function(&f.graph, "fold_negative_fraction_fp_to_unsigned")), value_interner::REF_ZERO),
		"a negative fraction greater than -1 should truncate to unsigned zero");
	assert(count_body_tag(find_function(&f.graph, "keep_f16_arithmetic"), ir::InstTag.FADD) == 1,
		"unsupported F16 arithmetic should remain in IR");
	assert(count_body_tag(find_function(&f.graph, "keep_f128_arithmetic"), ir::InstTag.FADD) == 1,
		"unsupported F128 arithmetic should remain in IR");
	f.free();
}

fn void jump_thread_skips_non_phi_repeated_condition() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"int repeated(int c) { if (c) { if (c) return 7; } return 9; }\n"
		"int independent(int c, int d) { if (c) { if (d) return 7; } return 9; }\n");
	f.run_mem2reg();
	ir::Decl* repeated = find_function(&f.graph, "repeated");
	ir::Decl* independent = find_function(&f.graph, "independent");
	uint repeated_branches = count_body_tag(repeated, ir::InstTag.BRANCH);
	uint independent_branches = count_body_tag(independent, ir::InstTag.BRANCH);
	assert(repeated_branches > 0 && independent_branches > 0,
		"the fixtures should lower to conditional branches before jump threading");
	foreach (&decl : f.graph.decls) ir_opt::jump_thread(&f.graph, decl);
	f.verify_graph();
	assert(count_body_tag(repeated, ir::InstTag.BRANCH) == repeated_branches,
		"a repeated condition without a PHI-fed branch chain is outside this threading pass");
	assert(count_body_tag(independent, ir::InstTag.BRANCH) == independent_branches,
		"an independent nested condition must not be guessed from its predecessor edge");
	f.free();
}

fn void jump_thread_evaluates_eq_phi_chain_and_if_else_zero() @test
{
	// Exercise the integer EQ form emitted by frontend conditions, along with
	// the common `if (x) return x; else return 0` source shape.
	OptFixture source;
	source.init();
	source.lower(
		"int eq_phi(int c) { int value = c ? 1 : 0; if (value == 1) return 7; return 0; }\n"
		"int if_else_zero(int x) { if (x) return x; else return 0; }\n");
	source.run_o1();
	source.verify_graph();
	assert(count_body_tag(find_function(&source.graph, "eq_phi"), ir::InstTag.BRANCH) <= 2,
		"O1 should fold the EQ-on-constant edge in a frontend conditional");
	assert(count_body_tag(find_function(&source.graph, "if_else_zero"), ir::InstTag.BRANCH) <= 1,
		"the if/else-zero idiom should lower without retaining redundant branches");
	source.free();

	HandIrFixture f;
	f.init();
	Ref choose = f.builder.add_arg(value_interner::REF_I1);
	Ref other_condition = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref pred = f.builder.make_label("pred");
	Ref other = f.builder.make_label("other");
	Ref join = f.builder.make_label("join");
	Ref yes = f.builder.make_label("yes");
	Ref no = f.builder.make_label("no");
	f.builder.add_branch(choose, pred, other);
	f.builder.start_block(pred);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(other);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(join);
	Ref one = f.add_int_constant(1, value_interner::REF_I1);
	Ref zero = f.add_int_constant(0, value_interner::REF_I1);
	ir::PhiInput[2] inputs = {
		{ .label = pred, .value = one },
		{ .label = other, .value = other_condition },
	};
	Ref condition = f.builder.add_phi(inputs[..], value_interner::REF_I1);
	Ref eq = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { condition, one } }, value_interner::REF_I1);
	Ref branch = f.builder.add_inst(ir::InstTag.BRANCH, { .branch = { eq, yes, no } }, value_interner::REF_NORETURN);
	f.builder.start_block(yes);
	f.builder.add_return(one);
	f.builder.start_block(no);
	f.builder.add_return(zero);
	f.builder.finish_fn("eq_phi_chain");
	f.finish();
	assert(ir_opt::jump_thread(&f.graph, &f.graph.decls[0]),
		"a PHI-fed integer EQ with a constant incoming edge should be threaded");
	assert(f.graph.decls[0].instructions[(sz)branch].data.branch.then_label == yes,
		"the EQ true edge should be selected for the predecessor carrying one");
	f.free();
}

fn void jump_thread_skips_join_after_branch_and_float_compare() @test
{
	HandIrFixture f;
	f.init();
	Ref choose = f.builder.add_arg(value_interner::REF_I1);
	Ref other_condition = f.builder.add_arg(value_interner::REF_I1);
	Ref joined_value = f.builder.add_arg(value_interner::REF_I32);
	f.builder.start_fn();
	Ref pred = f.builder.make_label("pred");
	Ref other = f.builder.make_label("other");
	Ref join = f.builder.make_label("join");
	Ref yes = f.builder.make_label("yes");
	Ref no = f.builder.make_label("no");
	f.builder.add_branch(choose, pred, other);
	f.builder.start_block(pred);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(other);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(join);
	Ref one = f.add_int_constant(1, value_interner::REF_I1);
	Ref zero = f.add_int_constant(0, value_interner::REF_I1);
	ir::PhiInput[2] inputs = {
		{ .label = pred, .value = one },
		{ .label = other, .value = other_condition },
	};
	Ref condition = f.builder.add_phi(inputs[..], value_interner::REF_I1);
	Ref eq = f.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { condition, one } }, value_interner::REF_I1);
	// A joined value computation between the PHI chain and branch is outside
	// the bounded branch-threading pattern.
	f.builder.add_inst(ir::InstTag.ADD, { .bin = { joined_value, joined_value } }, value_interner::REF_I32);
	f.builder.add_branch(eq, yes, no);
	f.builder.start_block(yes);
	f.builder.add_return(one);
	f.builder.start_block(no);
	f.builder.add_return(zero);
	f.builder.finish_fn("join_after_branch");

	Ref float_choose = f.builder.add_arg(value_interner::REF_I1);
	Ref float_other = f.builder.add_arg(value_interner::REF_F64);
	f.builder.start_fn();
	Ref float_pred = f.builder.make_label("float_pred");
	Ref float_alt = f.builder.make_label("float_alt");
	Ref float_join = f.builder.make_label("float_join");
	Ref float_yes = f.builder.make_label("float_yes");
	Ref float_no = f.builder.make_label("float_no");
	f.builder.add_branch(float_choose, float_pred, float_alt);
	f.builder.start_block(float_pred);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = float_join }, value_interner::REF_NORETURN);
	f.builder.start_block(float_alt);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = float_join }, value_interner::REF_NORETURN);
	f.builder.start_block(float_join);
	Ref f_one = f.add_f64_constant(0x3FF0_0000_0000_0000);
	ir::PhiInput[2] float_inputs = {
		{ .label = float_pred, .value = f_one },
		{ .label = float_alt, .value = float_other },
	};
	Ref float_phi = f.builder.add_phi(float_inputs[..], value_interner::REF_F64);
	Ref float_eq = f.builder.add_inst(ir::InstTag.FCMP_OEQ,
		{ .bin = { float_phi, f_one } }, value_interner::REF_I1);
	Ref float_branch = f.builder.add_inst(ir::InstTag.BRANCH,
		{ .branch = { float_eq, float_yes, float_no } }, value_interner::REF_NORETURN);
	f.builder.start_block(float_yes);
	f.builder.add_return(one);
	f.builder.start_block(float_no);
	f.builder.add_return(zero);
	f.builder.finish_fn("float_phi_compare");
	f.finish();
	assert(!ir_opt::jump_thread(&f.graph, &f.graph.decls[0]),
		"join-after-branch values must not be threaded through a PHI predecessor");
	assert(!ir_opt::jump_thread(&f.graph, &f.graph.decls[1]),
		"floating-point compares must not be evaluated by integer jump threading");
	f.free();
}

fn void jump_thread_requires_a_single_predecessor_edge() @test
{
	HandIrFixture f;
	f.init();
	Ref choose = f.builder.add_arg(value_interner::REF_I1);
	Ref other_condition = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref pred = f.builder.make_label("pred");
	Ref other = f.builder.make_label("other");
	Ref join = f.builder.make_label("join");
	Ref yes = f.builder.make_label("yes");
	Ref no = f.builder.make_label("no");
	// Both CFG edges from pred enter join. The PHI identifies a predecessor
	// block, not a particular edge, so threading must leave this shape alone.
	f.builder.add_branch(choose, pred, other);
	f.builder.start_block(pred);
	f.builder.add_branch(choose, join, join);
	f.builder.start_block(other);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(join);
	Ref one = f.add_int_constant(1, value_interner::REF_I1);
	Ref zero = f.add_int_constant(0, value_interner::REF_I1);
	ir::PhiInput[2] inputs = {
		{ .label = pred, .value = one },
		{ .label = other, .value = other_condition },
	};
	Ref condition = f.builder.add_phi(inputs[..], value_interner::REF_I1);
	Ref branch = f.builder.add_inst(ir::InstTag.BRANCH,
		{ .branch = { condition, yes, no } }, value_interner::REF_NORETURN);
	f.builder.start_block(yes);
	f.builder.add_return(one);
	f.builder.start_block(no);
	f.builder.add_return(zero);
	f.builder.finish_fn("multiple_predecessor_edges");
	f.finish();
	assert(!ir_opt::jump_thread(&f.graph, &f.graph.decls[0]),
		"jump threading must require a unique incoming edge from the predecessor");
	assert(f.graph.decls[0].instructions[(sz)branch].tag == ir::InstTag.BRANCH,
		"the branch with ambiguous predecessor edges should remain unchanged");
	f.free();
}

fn void jump_thread_simplifies_frontend_zext_cmp_ne_zero_shape() @test
{
	OptFixture f;
	f.init();
	f.lower("int f(int a, int b) { int t = a && b; if (t) return 3; return 4; }");
	f.run_o1();
	f.verify_graph();
	ir::Decl* decl = find_function(&f.graph, "f");
	assert(count_body_tag(decl, ir::InstTag.PHI) == 1,
		"O1 should remove the short-circuit PHI while preserving the return-value merge");
	assert(count_body_tag(decl, ir::InstTag.BRANCH) <= 2,
		"O1 should simplify at least one branch in the zext/cmp_ne-zero frontend shape");
	f.free();
}

<* entry: branch(choose, left, right); left/right jump to join, where
   phi(left: 1, right: c) drives branch(phi, yes, no). *>
fn void build_constant_phi_diamond(HandIrFixture* f)
{
	Ref choose = f.builder.add_arg(value_interner::REF_I1);
	Ref c = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref left = f.builder.make_label("left");
	Ref right = f.builder.make_label("right");
	Ref join = f.builder.make_label("join");
	Ref yes = f.builder.make_label("yes");
	Ref no = f.builder.make_label("no");
	f.builder.add_branch(choose, left, right);
	f.builder.start_block(left);
	f.builder.add_jump(join);
	f.builder.start_block(right);
	f.builder.add_jump(join);
	f.builder.start_block(join);
	ir::PhiInput[2] inputs = {
		{ .label = left, .value = f.add_int_constant(1, value_interner::REF_I1) },
		{ .label = right, .value = c },
	};
	f.builder.add_branch(f.builder.add_phi(inputs[..], value_interner::REF_I1), yes, no);
	f.builder.start_block(yes);
	f.builder.add_return(f.add_int_constant(1, value_interner::REF_I32));
	f.builder.start_block(no);
	f.builder.add_return(f.add_int_constant(2, value_interner::REF_I32));
	f.builder.finish_fn("diamond", ir::Linkage.EXTERNAL);
	f.finish();
}

fn void jump_thread_is_idempotent_after_convergence() @test
{
	HandIrFixture f;
	f.init();
	build_constant_phi_diamond(&f);
	ir::Decl* decl = &f.graph.decls[0];
	assert(ir_opt::jump_thread(&f.graph, decl), "the constant PHI edge should be threaded");
	assert(!ir_opt::jump_thread(&f.graph, decl), "a second jump_thread run should find nothing");
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "converged jump threading should verify: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	errors.free();
	f.free();
}

fn void correlated_value_prop_is_idempotent() @test
{
	OptFixture f;
	f.init();
	f.lower("int cvp_twice(int x) { if (x == 5) return x * 2; return 0; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "cvp_twice");
	assert(ir_opt::correlated_value_prop(&f.graph, decl), "x should be replaced by 5 on the equality edge");
	assert(!ir_opt::correlated_value_prop(&f.graph, decl), "a second CVP run should find nothing");
	f.verify_graph();
	f.free();
}

fn void jump_thread_many_short_circuit_blocks_is_bounded() @test
{
	// K sequential phi(i1 const, arg) -> branch diamonds, the shape && / ||
	// lowering produces, guard the bounded-rebuild driver.
	const int K = 200;
	HandIrFixture f;
	f.init();
	Ref choose = f.builder.add_arg(value_interner::REF_I1);
	Ref c = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref one = f.add_int_constant(1, value_interner::REF_I1);
	Ref head = f.builder.make_label(string::format(&f.builder.arena, "p0"));
	f.builder.add_jump(head);
	for (int k = 0; k < K; k++)
	{
		Ref left = f.builder.make_label(string::format(&f.builder.arena, "l%d", k));
		Ref right = f.builder.make_label(string::format(&f.builder.arena, "r%d", k));
		Ref join = f.builder.make_label(string::format(&f.builder.arena, "j%d", k));
		Ref side = f.builder.make_label(string::format(&f.builder.arena, "s%d", k));
		Ref next = f.builder.make_label(string::format(&f.builder.arena, "p%d", k + 1));
		f.builder.start_block(head);
		f.builder.add_branch(choose, left, right);
		f.builder.start_block(left);
		f.builder.add_jump(join);
		f.builder.start_block(right);
		f.builder.add_jump(join);
		f.builder.start_block(join);
		ir::PhiInput[2] inputs = { { .label = left, .value = one }, { .label = right, .value = c } };
		f.builder.add_branch(f.builder.add_phi(inputs[..], value_interner::REF_I1), next, side);
		f.builder.start_block(side);
		f.builder.add_jump(next);
		head = next;
	}
	f.builder.start_block(head);
	f.builder.add_return(f.add_int_constant(0, value_interner::REF_I32));
	f.builder.finish_fn("short_circuits", ir::Linkage.EXTERNAL);
	f.finish();
	ir::Decl* decl = &f.graph.decls[0];
	ir_opt::jump_thread(&f.graph, decl);
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "bounded jump threading should verify: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	errors.free();
	f.free();
}

fn void jump_thread_threads_constant_phi_edge_and_keeps_destination_phi_valid() @test
{
	HandIrFixture f;
	f.init();
	Ref choose_pred = f.builder.add_arg(value_interner::REF_I1);
	Ref route_to_join = f.builder.add_arg(value_interner::REF_I1);
	Ref payload = f.builder.add_arg(value_interner::REF_I32);
	Ref other_condition = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref pred = f.builder.make_label("pred");
	Ref other_pred = f.builder.make_label("other_pred");
	Ref join = f.builder.make_label("join");
	Ref fallback = f.builder.make_label("fallback");
	Ref selected = f.builder.make_label("selected");
	Ref rejected = f.builder.make_label("rejected");
	f.builder.add_branch(choose_pred, pred, other_pred);
	f.builder.start_block(pred);
	Ref pred_branch = f.builder.add_inst(ir::InstTag.BRANCH, { .branch = { route_to_join, join, fallback } }, value_interner::REF_NORETURN);
	f.builder.start_block(other_pred);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(join);
	Ref one = f.add_int_constant(1, value_interner::REF_I1);
	Ref zero = f.add_int_constant(0, value_interner::REF_I1);
	ir::PhiInput[2] condition_inputs = {
		{ .label = pred, .value = one },
		{ .label = other_pred, .value = other_condition },
	};
	Ref condition = f.builder.add_phi(condition_inputs[..], value_interner::REF_I1);
	Ref other_payload = f.add_int_constant(9, value_interner::REF_I32);
	ir::PhiInput[2] payload_inputs = {
		{ .label = pred, .value = payload },
		{ .label = other_pred, .value = other_payload },
	};
	Ref payload_phi = f.builder.add_phi(payload_inputs[..], value_interner::REF_I32);
	f.builder.add_branch(condition, selected, rejected);
	f.builder.start_block(selected);
	Ref result = f.add_int_constant(5, value_interner::REF_I32);
	ir::PhiInput[1] result_input = { { .label = join, .value = result } };
	Ref result_phi = f.builder.add_phi(result_input[..], value_interner::REF_I32);
	ir::PhiInput[1] condition_input = { { .label = join, .value = condition } };
	Ref condition_phi = f.builder.add_phi(condition_input[..], value_interner::REF_I1);
	ir::PhiInput[1] payload_input = { { .label = join, .value = payload_phi } };
	Ref selected_payload_phi = f.builder.add_phi(payload_input[..], value_interner::REF_I32);
	f.builder.add_return(result_phi);
	f.builder.start_block(rejected);
	f.builder.add_return(f.add_int_constant(6, value_interner::REF_I32));
	f.builder.start_block(fallback);
	f.builder.add_return(f.add_int_constant(7, value_interner::REF_I32));
	f.builder.finish_fn("constant_phi_edge", ir::Linkage.EXTERNAL);
	f.finish();

	ir::Decl* decl = &f.graph.decls[0];
	assert(ir_opt::jump_thread(&f.graph, decl),
		"a constant PHI value on pred's edge to join should enable threading");
	ir::Inst threaded_branch = decl.instructions[(sz)pred_branch];
	assert(threaded_branch.tag == ir::InstTag.BRANCH && threaded_branch.data.branch.then_label == selected,
		"the incoming branch should bypass join and select its known PHI destination");
	ir::Inst threaded_phi = decl.instructions[(sz)result_phi];
	assert(threaded_phi.tag == ir::InstTag.PHI && threaded_phi.data.phi.len == 2 &&
		threaded_phi.data.phi[1].label == pred && threaded_phi.data.phi[1].value == result,
		"threading into a PHI destination should copy the old join-edge value");
	ir::PhiInput threaded_condition_input = decl.instructions[(sz)condition_phi].data.phi[1];
	assert(threaded_condition_input.label == pred && threaded_condition_input.value == one,
		"a destination PHI input from B should map a B PHI to its P input");
	ir::PhiInput threaded_payload_input = decl.instructions[(sz)selected_payload_phi].data.phi[1];
	assert(threaded_payload_input.label == pred && threaded_payload_input.value == payload,
		"a nonconstant, non-driving B PHI input should pass through unchanged");
	assert(decl.instructions[(sz)condition].data.phi.len == 1 &&
		decl.instructions[(sz)condition].data.phi[0].label == other_pred &&
		decl.instructions[(sz)payload_phi].data.phi.len == 1 &&
		decl.instructions[(sz)payload_phi].data.phi[0].label == other_pred,
		"threading must remove P from every PHI in B");
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "threaded constant-PHI CFG should verify: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	assert(errors.len() == 0, "valid threaded CFG should have no verifier diagnostics");
	errors.free();
	f.free();
}

fn void jump_thread_supports_jmp_and_implicit_fallthrough_predecessors() @test
{
	HandIrFixture f;
	f.init();
	Ref choose_jmp = f.builder.add_arg(value_interner::REF_I1);
	Ref unknown_jmp = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref jmp_pred = f.builder.make_label("jmp_pred");
	Ref jmp_other = f.builder.make_label("jmp_other");
	Ref jmp_join = f.builder.make_label("jmp_join");
	Ref jmp_selected = f.builder.make_label("jmp_selected");
	Ref jmp_rejected = f.builder.make_label("jmp_rejected");
	f.builder.add_branch(choose_jmp, jmp_pred, jmp_other);
	f.builder.start_block(jmp_pred);
	Ref jmp_edge = f.builder.add_inst(ir::InstTag.JMP, { .ref = jmp_join }, value_interner::REF_NORETURN);
	f.builder.start_block(jmp_other);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = jmp_join }, value_interner::REF_NORETURN);
	f.builder.start_block(jmp_join);
	Ref one = f.add_int_constant(1, value_interner::REF_I1);
	Ref zero = f.add_int_constant(0, value_interner::REF_I1);
	ir::PhiInput[2] jmp_inputs = {
		{ .label = jmp_pred, .value = one },
		{ .label = jmp_other, .value = unknown_jmp },
	};
	Ref jmp_condition = f.builder.add_phi(jmp_inputs[..], value_interner::REF_I1);
	f.builder.add_branch(jmp_condition, jmp_selected, jmp_rejected);
	f.builder.start_block(jmp_selected);
	f.builder.add_return(one);
	f.builder.start_block(jmp_rejected);
	f.builder.add_return(zero);
	f.builder.finish_fn("jump_thread_jmp_predecessor");

	Ref choose_fallthrough = f.builder.add_arg(value_interner::REF_I1);
	Ref unknown_fallthrough = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref fall_pred = f.builder.make_label("fall_pred");
	Ref fall_other = f.builder.make_label("fall_other");
	Ref fall_join = f.builder.make_label("fall_join");
	Ref fall_selected = f.builder.make_label("fall_selected");
	Ref fall_rejected = f.builder.make_label("fall_rejected");
	f.builder.add_branch(choose_fallthrough, fall_pred, fall_other);
	f.builder.start_block(fall_other);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = fall_join }, value_interner::REF_NORETURN);
	// Keep fall_pred immediately before fall_join without Builder inserting a JMP.
	f.builder.body.push(fall_pred);
	f.builder.current_label = fall_pred;
	f.builder.body.push(fall_join);
	f.builder.current_label = fall_join;
	Ref fall_one = f.add_int_constant(1, value_interner::REF_I1);
	Ref fall_zero = f.add_int_constant(0, value_interner::REF_I1);
	ir::PhiInput[2] fall_inputs = {
		{ .label = fall_pred, .value = fall_one },
		{ .label = fall_other, .value = unknown_fallthrough },
	};
	Ref fall_condition = f.builder.add_phi(fall_inputs[..], value_interner::REF_I1);
	f.builder.add_branch(fall_condition, fall_selected, fall_rejected);
	f.builder.start_block(fall_selected);
	f.builder.add_return(fall_one);
	f.builder.start_block(fall_rejected);
	f.builder.add_return(fall_zero);
	f.builder.finish_fn("jump_thread_fallthrough_predecessor");
	f.finish();

	ir::Decl* jmp_decl = &f.graph.decls[0];
	ir::Decl* fall_decl = &f.graph.decls[1];
	assert(ir_opt::jump_thread(&f.graph, jmp_decl),
		"a JMP predecessor with a constant PHI input should be threaded");
	assert(jmp_decl.instructions[(sz)jmp_edge].data.ref == jmp_selected,
		"the JMP predecessor should be redirected to the selected successor");
	assert(jmp_decl.instructions[(sz)jmp_condition].data.phi.len == 1 &&
		jmp_decl.instructions[(sz)jmp_condition].data.phi[0].label == jmp_other,
		"threading a JMP predecessor should remove its input from every PHI in B");
	assert(ir_opt::jump_thread(&f.graph, fall_decl),
		"an implicit-fallthrough predecessor with a constant PHI input should be threaded");
	ir_opt::Cfg fall_cfg = ir_opt::build_cfg(fall_decl, &f.ta);
	uint fall_pred_index = block_for_label(&fall_cfg, fall_pred);
	uint fall_selected_index = block_for_label(&fall_cfg, fall_selected);
	uint fall_join_index = block_for_label(&fall_cfg, fall_join);
	assert(has_uint_index(fall_cfg.blocks[(sz)fall_pred_index].succs.array_view(), fall_selected_index) &&
		!has_uint_index(fall_cfg.blocks[(sz)fall_pred_index].succs.array_view(), fall_join_index),
		"an implicit predecessor should receive an explicit jump to the selected successor");
	fall_cfg.free();
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "threaded JMP/fallthrough CFGs should verify: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	assert(errors.len() == 0, "valid threaded JMP/fallthrough CFGs should have no verifier diagnostics");
	errors.free();
	f.free();
}

fn void jump_thread_skips_switch_shared_edges() @test
{
	HandIrFixture f;
	f.init();
	Ref choose_pred = f.builder.add_arg(value_interner::REF_I1);
	Ref selector = f.builder.add_arg(value_interner::REF_I32);
	Ref unknown_other = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref pred = f.builder.make_label("switch_pred");
	Ref other = f.builder.make_label("switch_other");
	Ref join = f.builder.make_label("switch_join");
	Ref selected = f.builder.make_label("switch_selected");
	Ref rejected = f.builder.make_label("switch_rejected");
	f.builder.add_branch(choose_pred, pred, other);
	f.builder.start_block(pred);
	value_interner::InternerRef[2] case_values = {
		f.interner.put(primitive_value::int_key(1)),
		f.interner.put(primitive_value::int_key(2)),
	};
	Ref[2] case_labels = { join, join };
	f.builder.add_switch(selector, case_values[..], case_labels[..], join);
	f.builder.start_block(other);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(join);
	Ref one = f.add_int_constant(1, value_interner::REF_I1);
	Ref zero = f.add_int_constant(0, value_interner::REF_I1);
	ir::PhiInput[2] inputs = {
		{ .label = pred, .value = one },
		{ .label = other, .value = unknown_other },
	};
	Ref condition = f.builder.add_phi(inputs[..], value_interner::REF_I1);
	f.builder.add_branch(condition, selected, rejected);
	f.builder.start_block(selected);
	f.builder.add_return(one);
	f.builder.start_block(rejected);
	f.builder.add_return(zero);
	f.builder.finish_fn("jump_thread_switch_shared_edge");
	f.finish();

	ir::Decl* decl = &f.graph.decls[0];
	assert(!ir_opt::jump_thread(&f.graph, decl),
		"a SWITCH predecessor with shared destinations must not be threaded");
	ir::Ref switch_ref = ir::NONE;
	foreach (ref : decl.body) if (decl.instructions[(sz)ref].tag == ir::InstTag.SWITCH) switch_ref = ref;
	assert(switch_ref != ir::NONE, "the shared-edge SWITCH should remain in the body");
	ir::Inst switch_inst = decl.instructions[(sz)switch_ref];
	assert(switch_inst.tag == ir::InstTag.SWITCH && switch_inst.data.switch_data.labels.len == 2 &&
		switch_inst.data.switch_data.labels[0] == join && switch_inst.data.switch_data.labels[1] == join &&
		switch_inst.data.switch_data.default_label == join,
		"the SWITCH shared edge should remain unchanged");
	assert(decl.instructions[(sz)condition].data.phi.len == 2,
		"the PHI input for the SWITCH predecessor should remain intact");
	f.free();
}

fn void jump_thread_evaluates_zext_cmp_ne_zero_phi_chain() @test
{
	HandIrFixture f;
	f.init();
	Ref choose_pred = f.builder.add_arg(value_interner::REF_I1);
	Ref route_to_join = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref pred = f.builder.make_label("pred");
	Ref other_pred = f.builder.make_label("other_pred");
	Ref join = f.builder.make_label("join");
	Ref fallback = f.builder.make_label("fallback");
	Ref selected = f.builder.make_label("selected");
	Ref rejected = f.builder.make_label("rejected");
	f.builder.add_branch(choose_pred, pred, other_pred);
	f.builder.start_block(pred);
	Ref pred_branch = f.builder.add_inst(ir::InstTag.BRANCH, { .branch = { route_to_join, join, fallback } }, value_interner::REF_NORETURN);
	f.builder.start_block(other_pred);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(join);
	Ref one = f.add_int_constant(1, value_interner::REF_I1);
	Ref zero_bit = f.add_int_constant(0, value_interner::REF_I1);
	ir::PhiInput[2] condition_inputs = {
		{ .label = pred, .value = one },
		{ .label = other_pred, .value = zero_bit },
	};
	Ref phi = f.builder.add_phi(condition_inputs[..], value_interner::REF_I1);
	Ref widened = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = phi }, value_interner::REF_I32);
	Ref zero = f.add_int_constant(0, value_interner::REF_I32);
	Ref condition = f.builder.add_inst(ir::InstTag.CMP_NE, { .bin = { widened, zero } }, value_interner::REF_I1);
	f.builder.add_branch(condition, selected, rejected);
	f.builder.start_block(selected);
	ir::PhiInput[1] selected_chain_input = { { .label = join, .value = condition } };
	Ref selected_chain_phi = f.builder.add_phi(selected_chain_input[..], value_interner::REF_I1);
	f.builder.add_return(f.add_int_constant(5, value_interner::REF_I32));
	f.builder.start_block(rejected);
	f.builder.add_return(f.add_int_constant(6, value_interner::REF_I32));
	f.builder.start_block(fallback);
	f.builder.add_return(f.add_int_constant(7, value_interner::REF_I32));
	f.builder.finish_fn("zext_cmp_ne_zero_chain", ir::Linkage.EXTERNAL);
	f.finish();

	ir::Decl* decl = &f.graph.decls[0];
	assert(ir_opt::jump_thread(&f.graph, decl),
		"zext(phi) compared against zero should be evaluated on the incoming edge");
	ir::Inst threaded_branch = decl.instructions[(sz)pred_branch];
	assert(threaded_branch.tag == ir::InstTag.BRANCH && threaded_branch.data.branch.then_label == selected,
		"the zext/cmp_ne-zero chain should select the known destination");
	ir::PhiInput threaded_chain_input = decl.instructions[(sz)selected_chain_phi].data.phi[1];
	assert(threaded_chain_input.label == pred && is_bool_constant(decl, threaded_chain_input.value, value_interner::REF_ONE),
		"a destination PHI input from B should map a chain value to a new constant");
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "threaded zext/cmp CFG should verify: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	assert(errors.len() == 0, "valid zext/cmp threaded CFG should have no verifier diagnostics");
	errors.free();
	f.free();
}

fn void jump_thread_skips_phi_branch_block_with_side_effect() @test
{
	HandIrFixture f;
	f.init();
	Ref choose_pred = f.builder.add_arg(value_interner::REF_I1);
	Ref route_to_join = f.builder.add_arg(value_interner::REF_I1);
	Ref callee = f.builder.add_symbol("side_effect", value_interner::REF_PTR);
	f.builder.start_fn();
	Ref pred = f.builder.make_label("pred");
	Ref other_pred = f.builder.make_label("other_pred");
	Ref join = f.builder.make_label("join");
	Ref fallback = f.builder.make_label("fallback");
	Ref selected = f.builder.make_label("selected");
	Ref rejected = f.builder.make_label("rejected");
	f.builder.add_branch(choose_pred, pred, other_pred);
	f.builder.start_block(pred);
	Ref pred_branch = f.builder.add_inst(ir::InstTag.BRANCH, { .branch = { route_to_join, join, fallback } }, value_interner::REF_NORETURN);
	f.builder.start_block(other_pred);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(join);
	Ref one = f.add_int_constant(1, value_interner::REF_I1);
	Ref zero = f.add_int_constant(0, value_interner::REF_I1);
	ir::PhiInput[2] inputs = {
		{ .label = pred, .value = one },
		{ .label = other_pred, .value = zero },
	};
	Ref condition = f.builder.add_phi(inputs[..], value_interner::REF_I1);
	Ref call = f.builder.add_call(callee, {}, value_interner::REF_VOID);
	f.builder.add_branch(condition, selected, rejected);
	f.builder.start_block(selected);
	f.builder.add_return(f.add_int_constant(5, value_interner::REF_I32));
	f.builder.start_block(rejected);
	f.builder.add_return(f.add_int_constant(6, value_interner::REF_I32));
	f.builder.start_block(fallback);
	f.builder.add_return(f.add_int_constant(7, value_interner::REF_I32));
	f.builder.finish_fn("side_effecting_join", ir::Linkage.EXTERNAL);
	f.finish();

	ir::Decl* decl = &f.graph.decls[0];
	assert(!ir_opt::jump_thread(&f.graph, decl),
		"jump threading must skip a PHI/branch block containing a side-effecting call");
	assert(has_index(decl.body, call) && decl.instructions[(sz)pred_branch].data.branch.then_label == join,
		"the call and original edge should remain when the block is skipped");
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "unchanged side-effecting CFG should verify: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	assert(errors.len() == 0, "valid side-effecting CFG should have no verifier diagnostics");
	errors.free();
	f.free();
}

fn void jump_thread_skips_phi_or_chain_with_external_use() @test
{
	HandIrFixture f;
	f.init();
	Ref choose_phi_pred = f.builder.add_arg(value_interner::REF_I1);
	Ref route_phi = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref phi_pred = f.builder.make_label("phi_pred");
	Ref phi_other = f.builder.make_label("phi_other");
	Ref phi_join = f.builder.make_label("phi_join");
	Ref phi_fallback = f.builder.make_label("phi_fallback");
	Ref phi_selected = f.builder.make_label("phi_selected");
	Ref phi_rejected = f.builder.make_label("phi_rejected");
	f.builder.add_branch(choose_phi_pred, phi_pred, phi_other);
	f.builder.start_block(phi_pred);
	Ref phi_edge = f.builder.add_inst(ir::InstTag.BRANCH, { .branch = { route_phi, phi_join, phi_fallback } }, value_interner::REF_NORETURN);
	f.builder.start_block(phi_other);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = phi_join }, value_interner::REF_NORETURN);
	f.builder.start_block(phi_join);
	Ref one = f.add_int_constant(1, value_interner::REF_I32);
	Ref zero = f.add_int_constant(0, value_interner::REF_I32);
	ir::PhiInput[2] phi_inputs = {
		{ .label = phi_pred, .value = one },
		{ .label = phi_other, .value = zero },
	};
	Ref phi = f.builder.add_phi(phi_inputs[..], value_interner::REF_I32);
	Ref bool_zero = f.add_int_constant(0, value_interner::REF_I32);
	Ref phi_condition = f.builder.add_inst(ir::InstTag.CMP_NE, { .bin = { phi, bool_zero } }, value_interner::REF_I1);
	f.builder.add_branch(phi_condition, phi_selected, phi_rejected);
	f.builder.start_block(phi_selected);
	Ref phi_use = f.builder.add_inst(ir::InstTag.ADD, { .bin = { phi, bool_zero } }, value_interner::REF_I32);
	f.builder.add_return(phi_use);
	f.builder.start_block(phi_rejected);
	f.builder.add_return(bool_zero);
	f.builder.start_block(phi_fallback);
	f.builder.add_return(bool_zero);
	f.builder.finish_fn("phi_external_use", ir::Linkage.EXTERNAL);

	Ref choose_chain_pred = f.builder.add_arg(value_interner::REF_I1);
	Ref route_chain = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref chain_pred = f.builder.make_label("chain_pred");
	Ref chain_other = f.builder.make_label("chain_other");
	Ref chain_join = f.builder.make_label("chain_join");
	Ref chain_fallback = f.builder.make_label("chain_fallback");
	Ref chain_selected = f.builder.make_label("chain_selected");
	Ref chain_rejected = f.builder.make_label("chain_rejected");
	f.builder.add_branch(choose_chain_pred, chain_pred, chain_other);
	f.builder.start_block(chain_pred);
	Ref chain_edge = f.builder.add_inst(ir::InstTag.BRANCH, { .branch = { route_chain, chain_join, chain_fallback } }, value_interner::REF_NORETURN);
	f.builder.start_block(chain_other);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = chain_join }, value_interner::REF_NORETURN);
	f.builder.start_block(chain_join);
	Ref bit_one = f.add_int_constant(1, value_interner::REF_I1);
	Ref bit_zero = f.add_int_constant(0, value_interner::REF_I1);
	ir::PhiInput[2] chain_inputs = {
		{ .label = chain_pred, .value = bit_one },
		{ .label = chain_other, .value = bit_zero },
	};
	Ref bit_phi = f.builder.add_phi(chain_inputs[..], value_interner::REF_I1);
	Ref widened = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = bit_phi }, value_interner::REF_I32);
	Ref chain_zero = f.add_int_constant(0, value_interner::REF_I32);
	Ref chain_value = f.builder.add_inst(ir::InstTag.CMP_NE, { .bin = { widened, chain_zero } }, value_interner::REF_I1);
	f.builder.add_branch(chain_value, chain_selected, chain_rejected);
	f.builder.start_block(chain_selected);
	Ref external_use = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = chain_value }, value_interner::REF_I32);
	f.builder.add_return(external_use);
	f.builder.start_block(chain_rejected);
	f.builder.add_return(chain_zero);
	f.builder.start_block(chain_fallback);
	f.builder.add_return(chain_zero);
	f.builder.finish_fn("chain_external_use", ir::Linkage.EXTERNAL);

	Ref choose_dead_chain_pred = f.builder.add_arg(value_interner::REF_I1);
	Ref route_dead_chain = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref dead_chain_pred = f.builder.make_label("dead_chain_pred");
	Ref dead_chain_other = f.builder.make_label("dead_chain_other");
	Ref dead_chain_join = f.builder.make_label("dead_chain_join");
	Ref dead_chain_fallback = f.builder.make_label("dead_chain_fallback");
	Ref dead_chain_selected = f.builder.make_label("dead_chain_selected");
	Ref dead_chain_rejected = f.builder.make_label("dead_chain_rejected");
	f.builder.add_branch(choose_dead_chain_pred, dead_chain_pred, dead_chain_other);
	f.builder.start_block(dead_chain_pred);
	Ref dead_chain_edge = f.builder.add_inst(ir::InstTag.BRANCH,
		{ .branch = { route_dead_chain, dead_chain_join, dead_chain_fallback } }, value_interner::REF_NORETURN);
	f.builder.start_block(dead_chain_other);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = dead_chain_join }, value_interner::REF_NORETURN);
	f.builder.start_block(dead_chain_join);
	Ref dead_one = f.add_int_constant(1, value_interner::REF_I1);
	Ref dead_zero = f.add_int_constant(0, value_interner::REF_I1);
	ir::PhiInput[2] dead_inputs = {
		{ .label = dead_chain_pred, .value = dead_one },
		{ .label = dead_chain_other, .value = dead_zero },
	};
	Ref dead_condition = f.builder.add_phi(dead_inputs[..], value_interner::REF_I1);
	Ref dead_chain_value = f.builder.add_inst(ir::InstTag.ZEXT, { .ref = dead_condition }, value_interner::REF_I32);
	f.builder.add_branch(dead_condition, dead_chain_selected, dead_chain_rejected);
	f.builder.start_block(dead_chain_selected);
	Ref dead_chain_zero_i32 = f.add_int_constant(0, value_interner::REF_I32);
	Ref dead_chain_use = f.builder.add_inst(ir::InstTag.ADD, { .bin = { dead_chain_value, dead_chain_zero_i32 } }, value_interner::REF_I32);
	f.builder.add_return(dead_chain_use);
	f.builder.start_block(dead_chain_rejected);
	f.builder.add_return(f.add_int_constant(2, value_interner::REF_I32));
	f.builder.start_block(dead_chain_fallback);
	f.builder.add_return(f.add_int_constant(3, value_interner::REF_I32));
	f.builder.finish_fn("dead_chain_external_use", ir::Linkage.EXTERNAL);
	f.finish();

	ir::Decl* phi_decl = &f.graph.decls[0];
	ir::Decl* chain_decl = &f.graph.decls[1];
	ir::Decl* dead_chain_decl = &f.graph.decls[2];
	assert(!ir_opt::jump_thread(&f.graph, phi_decl) &&
		!ir_opt::jump_thread(&f.graph, chain_decl) &&
		!ir_opt::jump_thread(&f.graph, dead_chain_decl),
		"a PHI or supported chain value, including a dead chain result, used outside its branch context must prevent threading");
	assert(phi_decl.instructions[(sz)phi_edge].data.branch.then_label == phi_join &&
		chain_decl.instructions[(sz)chain_edge].data.branch.then_label == chain_join &&
		dead_chain_decl.instructions[(sz)dead_chain_edge].data.branch.then_label == dead_chain_join,
		"candidate incoming edges should remain aimed at their original PHI blocks");
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "unchanged external-use CFGs should verify: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	assert(errors.len() == 0, "valid external-use CFGs should have no verifier diagnostics");
	errors.free();
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

// Atomic accesses on a local are not promoted or deleted, a fence with no users
// survives DCE, and an unused CLZ is removed.
fn void atomics_and_fences_survive_o1() @test
{
	OptFixture f;
	f.init();
	// The fixture has no predefined macros: 5 = __ATOMIC_SEQ_CST, 2 = __ATOMIC_ACQUIRE.
	f.lower("int f(int v) { int x; __atomic_store_n(&x, v, 5); __atomic_thread_fence(5);"
		" (void)__builtin_clz((unsigned)v); return __atomic_load_n(&x, 2); }");
	String actual = f.dump();
	test::eq(actual,
		"i32 @f(i32 %0) {\n"
		"entry.0:\n"
		"    ptr_ty %1 = alloc size 4 align 4\n"
		"    ptr_ty %2 = alloc size 4 align 4\n"
		"    store ptr_ty %1, i32 %0\n"
		"    i32 %3 = load ptr_ty %1\n"
		"    atomic_store ptr_ty %2, i32 %3 seq_cst\n"
		"    fence seq_cst\n"
		"    i32 %4 = load ptr_ty %1\n"
		"    i32 %5 = clz i32 %4\n"
		"    i32 %6 = atomic_load ptr_ty %2 acquire\n"
		"    ret i32 %6\n"
		"}\n\n");
	alloc::free(&f.ta, actual.ptr);
	f.run_o1();
	f.verify_graph();
	ir::Decl* func = find_function(&f.graph, "f");
	assert(count_body_tag(func, ir::InstTag.ALLOC) == 1, "O1 keeps the atomically accessed local");
	assert(count_body_tag(func, ir::InstTag.ATOMIC_STORE) == 1, "O1 keeps the atomic store");
	assert(count_body_tag(func, ir::InstTag.ATOMIC_LOAD) == 1, "O1 keeps the atomic load");
	assert(count_body_tag(func, ir::InstTag.FENCE) == 1, "O1 keeps the fence");
	assert(count_body_tag(func, ir::InstTag.CLZ) == 0, "O1 removes the unused clz");
	f.free();
}

fn bool run_dead_arg_elim(OptFixture* f, bool whole_program = false)
=> ir_opt::dead_arg_elim(&f.graph, {
	.level = code_gen_options::OptimizationLevel.O2,
	.whole_program = whole_program,
	.verify = true,
});

fn void dead_arg_elim_removes_unused_mixed_register_args_for_all_callers() @test
{
	OptFixture f;
	f.init();
	f.lower("static double target(int kept0, int gone0, double kept1, double gone1, int kept2) { return kept0 * kept1 + kept2; }\n"
		"int main(void) { return (int)target(3, 11, 2.0, 99.0, 4) + (int)target(5, 33, 4.0, 88.0, 6); }");
	f.run_mem2reg();
	assert(run_dead_arg_elim(&f), "dead register arguments should be removed");
	f.verify_graph();
	ir::Decl* target = find_function(&f.graph, "target");
	assert(count_body_tag(target, ir::InstTag.ARG) == 3, "only the used mixed GP/SSE arguments remain placed");
	uint gp = 0;
	uint sse = 0;
	foreach (ref : target.body)
	{
		ir::Inst* arg = &target.instructions[(sz)ref];
		if (arg.tag != ir::InstTag.ARG) break;
		if (arg.data.arg.location_kind == ir::ArgLocationKind.GP_REGISTER)
		{
			assert(arg.data.arg.location == gp++, "GP arguments should be renumbered after removal");
		}
		else if (arg.data.arg.location_kind == ir::ArgLocationKind.SSE_REGISTER)
		{
			assert(arg.data.arg.location == sse++, "SSE arguments should be renumbered after removal");
		}
	}
	ir::Decl* main_fn = find_function(&f.graph, "main");
	uint calls = 0;
	foreach (ref : main_fn.body)
	{
		ir::Inst* inst = &main_fn.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.CALL && main_fn.instructions[(sz)inst.data.call.func].tag == ir::InstTag.SYMBOL &&
			main_fn.instructions[(sz)inst.data.call.func].data.label == "target")
		{
			calls++;
			assert(inst.data.call.args.len == 3, "each caller should drop the unused integer and double operands");
		}
	}
	assert(calls == 2, "both direct callers should be rewritten");
	f.free();
}

fn void cvp_eq_five_phi_folds_multiply_to_ten() @test
{
	OptFixture f;
	f.init();
	f.lower("int cvp_eq_five(int x) { if (x == 5) return x * 2; return 0; }");
	f.run_o1();
	ir::Decl* decl = find_function(&f.graph, "cvp_eq_five");
	bool returned_ten = false;
	foreach (ref : decl.body)
	{
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag != ir::InstTag.RET || (usz)inst.data.ref >= (usz)decl.instructions.len) continue;
		ir::Inst* ret_value = &decl.instructions[(sz)inst.data.ref];
		if (is_int_constant(decl, inst.data.ref, f.graph.interner, 10)) returned_ten = true;
		if (ret_value.tag == ir::InstTag.PHI)
		{
			foreach (input : ret_value.data.phi)
			{
				if (is_int_constant(decl, input.value, f.graph.interner, 10)) returned_ten = true;
			}
		}
	}
	assert(returned_ten, "the then-arm return should fold to constant 10");
	assert(count_body_tag(decl, ir::InstTag.MUL) == 0,
		"the multiplication by two should be folded after CVP resolves x on the equality edge");
	f.free();
}

fn void cvp_if_nonzero_removes_add_on_zero_edge() @test
{
	OptFixture f;
	f.init();
	f.lower("int cvp_zero_edge(int x) { if (x) return 1; return x + 7; }");
	f.run_o1();
	ir::Decl* decl = find_function(&f.graph, "cvp_zero_edge");
	assert(count_body_tag(decl, ir::InstTag.ADD) == 0,
		"the false edge of if (x) makes x zero, so x + 7 should fold");
	f.free();
}

fn void cvp_keeps_add_at_join_after_branch() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	Ref value = f.builder.add_arg(value_interner::REF_I32);
	Ref seven = f.add_int_constant(7, value_interner::REF_I32);
	f.builder.start_fn();
	Ref left = f.builder.make_label("left");
	Ref join = f.builder.make_label("join");
	Ref right = f.builder.make_label("right");
	f.builder.add_branch(condition, left, right);
	f.builder.start_block(left);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(right);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = join }, value_interner::REF_NORETURN);
	f.builder.start_block(join);
	Ref sum = f.builder.add_inst(ir::InstTag.ADD, { .bin = { value, seven } }, value_interner::REF_I32);
	f.builder.add_return(sum);
	f.builder.finish_fn("cvp_join_keeps_add", ir::Linkage.EXTERNAL);
	f.finish();
	ir::Decl* decl = &f.graph.decls[0];
	assert(!ir_opt::correlated_value_prop(&f.graph, decl),
		"CVP should leave an ADD using an unconstrained value unchanged at a join");
	assert(count_body_tag(decl, ir::InstTag.ADD) == 1,
		"the join's ADD should remain when neither incoming edge constrains its operand");
	f.free();
}

fn void cvp_leaves_float_fcmp_unchanged() @test
{
	OptFixture f;
	f.init();
	f.lower("double cvp_float_compare(double x) { if (x == 0.0) return x; return 1.0; }");
	f.run_mem2reg();
	ir::Decl* decl = find_function(&f.graph, "cvp_float_compare");
	uint before = count_body_tag(decl, ir::InstTag.FCMP_OEQ);
	assert(before == 1, "the fixture should lower to one floating comparison");
	assert(!ir_opt::correlated_value_prop(&f.graph, decl),
		"CVP should not claim a rewrite for a floating comparison");
	assert(count_body_tag(decl, ir::InstTag.FCMP_OEQ) == before,
		"CVP must leave FCMP unchanged");
	f.free();
}

fn void cvp_does_not_rewrite_branch_at_two_predecessor_target() @test
{
	HandIrFixture f;
	f.init();
	Ref condition = f.builder.add_arg(value_interner::REF_I1);
	f.builder.start_fn();
	Ref entry = f.builder.current_label;
	Ref other = f.builder.make_label("other");
	Ref selected = f.builder.make_label("selected");
	f.builder.add_branch(condition, selected, other);
	f.builder.start_block(other);
	f.builder.add_inst(ir::InstTag.JMP, { .ref = selected }, value_interner::REF_NORETURN);
	f.builder.start_block(selected);
	f.builder.add_return(condition);
	f.builder.finish_fn("cvp_two_pred_target", ir::Linkage.EXTERNAL);
	f.finish();
	ir::Decl* decl = &f.graph.decls[0];
	assert(!ir_opt::correlated_value_prop(&f.graph, decl),
		"a branch edge into a two-predecessor target must not propagate its condition");
	assert(return_value(decl) == condition,
		"the target's use should remain unchanged because the branch edge does not dominate it");
	f.free();
}

fn void dead_arg_elim_keeps_store_when_call_result_is_unused() @test
{
	OptFixture f;
	f.init();
	f.lower("static int side; static int produce(void) { side = 9; return 42; }\n"
		"int main(void) { (void)produce(); return side; }");
	assert(run_dead_arg_elim(&f), "the ignored scalar result should become void");
	f.verify_graph();
	ir::Decl* produce = find_function(&f.graph, "produce");
	assert(return_value(produce) == ir::NONE, "the callee return should be void after all call results are ignored");
	assert(count_body_tag(produce, ir::InstTag.STORE) == 1, "the side effecting store must remain");
	ir::Decl* main_fn = find_function(&f.graph, "main");
	bool saw_void_call = false;
	foreach (ref : main_fn.body)
	{
		ir::Inst* inst = &main_fn.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.CALL && inst.ty == value_interner::REF_VOID &&
			main_fn.instructions[(sz)inst.data.call.func].data.label == "produce") saw_void_call = true;
	}
	assert(saw_void_call, "the call should remain with a void result");
	f.free();
}

fn void dead_arg_elim_skips_ineligible_parameters_and_live_results() @test
{
	OptFixture f;
	f.init();
	f.lower("typedef struct Big { long a, b, c; } Big;\n"
		"static int stack_arg(int a,int b,int c,int d,int e,int f,int dead) { return a; }\n"
		"static int address_arg(int dead,int kept) { return kept; }\n"
		"static int (*address_arg_pointer)(int,int)=address_arg;\n"
		"int exposed(int dead,int kept) { return kept; }\n"
		"static int variadic(int dead, ...) { __builtin_va_list ap; __builtin_va_start(ap, dead); __builtin_va_end(ap); return 1; }\n"
		"static int copy_arg(Big dead, int kept) { return kept; }\n"
		"static int live_result(void) { return 7; }\n"
		"int main(void) { Big big={0}; return stack_arg(1,2,3,4,5,6,7)+address_arg_pointer(8,9)+exposed(10,11)+variadic(12,13)+copy_arg(big,14)+live_result(); }");
	f.run_mem2reg();
	run_dead_arg_elim(&f);
	f.verify_graph();
	assert(count_body_tag(find_function(&f.graph, "stack_arg"), ir::InstTag.ARG) == 7, "STACK parameters should be retained");
	assert(count_body_tag(find_function(&f.graph, "address_arg"), ir::InstTag.ARG) == 2, "address-taken functions should be retained");
	assert(count_body_tag(find_function(&f.graph, "exposed"), ir::InstTag.ARG) == 2, "externally visible functions should remain unchanged per translation unit");
	assert(count_body_tag(find_function(&f.graph, "variadic"), ir::InstTag.ARG) == 1, "variadic functions should be retained");
	assert(count_body_tag(find_function(&f.graph, "copy_arg"), ir::InstTag.ARG) == 2, "memory-copy struct arguments should be retained");
	assert(return_value(find_function(&f.graph, "live_result")) != ir::NONE, "a result used at a call site must remain valued");
	f.free();
}

fn void o2_global_opt_replaces_unwritten_internal_global_but_keeps_mutable_and_volatile() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int never_written = 37;\n"
		"static int mutable_value = 5;\n"
		"static volatile int volatile_value = 9;\n"
		"int read_never_written(void) { return never_written; }\n"
		"int read_mutable(void) { return mutable_value; }\n"
		"void write_mutable(int value) { mutable_value = value; }\n"
		"int read_volatile(void) { return volatile_value; }\n");
	f.run_o2();
	f.verify_graph();
	assert_returns_int(find_function(&f.graph, "read_never_written"), f.graph.interner, 37,
		"load from an unwritten internal global");
	assert(count_body_tag(find_function(&f.graph, "read_mutable"), ir::InstTag.LOAD) == 1,
		"a global written by another function must remain loaded from memory");
	assert(count_body_tag(find_function(&f.graph, "read_volatile"), ir::InstTag.LOAD) == 1,
		"volatile global reads must remain observable loads");
	String output = f.dump();
	assert(!output.contains("@never_written"), "a replaced internal global should disappear from optimized IR");
	assert(output.contains("@mutable_value") && output.contains("@volatile_value"),
		"mutable and volatile globals should remain in optimized IR");
	alloc::free(&f.ta, output.ptr);
	f.free();
}

fn void o2_global_opt_sees_address_stored_into_local_pointer() @test
{
	// Regression (csmith seed 320): `&g` stored into a local pointer slot is the
	// second operand of the STORE; the escape scan used to skip it and fold `g`
	// to its initializer.
	OptFixture f;
	f.init();
	f.lower(
		"static int g = 7;\n"
		"int write_through_local_pointer(void) { int *p = &g; *p = 0; return g; }\n"
		"static int h = 3;\n"
		"static int k = 4;\n"
		"int write_through_select(int c) { int *p = c ? &h : &k; *p = 9; return h + k; }\n");
	f.run_o2();
	f.verify_graph();
	String output = f.dump();
	// Wrong folding yields 7 for both (g's initializer; h + k = 3 + 4).
	assert(!output.contains("ret i32 7"),
		"a global written through a local or selected pointer must not fold to its initializer");
	assert(output.contains("@h") && output.contains("@k"),
		"globals reachable through a selected pointer must stay in memory");
	alloc::free(&f.ta, output.ptr);
	f.free();
}

fn void global_opt_folds_initializer_in_target_byte_order() @test
{
	bool[2] orders = { false, true };
	foreach (big : orders)
	{
		HandIrFixture f;
		f.init();
		char[] bytes = alloc::new_array(&f.ta, char, 6);
		bytes[0] = 0x12; bytes[1] = 0x34; bytes[2] = 0x56; bytes[3] = 0x78; bytes[4] = 0x9a; bytes[5] = 0xbc;
		ir::DataReloc[] no_relocs = alloc::new_array(&f.ta, ir::DataReloc, 0);
		f.builder.add_global("table", ir::Linkage.INTERNAL, {
			.size = 6, .align = 4, .bytes = bytes, .relocs = no_relocs, .section = ir::DataSection.DATA,
		});
		alloc::free(&f.ta, bytes.ptr);
		alloc::free(&f.ta, no_relocs.ptr);
		f.builder.start_fn();
		Ref base = f.builder.add_symbol("table", value_interner::REF_PTR);
		Ref two = f.add_int_constant(2, value_interner::REF_I64);
		Ref at = f.builder.add_inst(ir::InstTag.ADD, { .bin = { base, two } }, value_interner::REF_PTR);
		Ref word = f.builder.add_inst(ir::InstTag.LOAD, { .ref = at }, value_interner::REF_I32);
		f.builder.add_return(word);
		f.builder.finish_fn("read_table");
		f.finish();
		f.graph.big_endian = big;
		ir::ErrorList errors;
		errors.init(&f.ta);
		fault failed = @catch(ir_opt::run(&f.graph, {
			.level = code_gen_options::OptimizationLevel.O2, .verify = true }, &errors));
		assert(!failed && errors.len() == 0, "O2 pipeline failed");
		errors.free();
		// Bytes 2..5 are 56 78 9a bc.
		assert_returns_int(find_function(&f.graph, "read_table"), f.graph.interner,
			big ? (long)(int)0x56789abc : (long)(int)0xbc9a7856, "GlobalOpt folds a load in the IR's byte order");
		f.free();
	}
}

fn void o2_global_opt_covers_constant_data_and_conservative_escapes() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static const int numbers[3] = { 10, 20, 30 };\n"
		"static int zero_bss;\n"
		"static int write_only;\n"
		"static int escaped;\n"
		"static volatile int volatile_value = 7;\n"
		"static int cross_function;\n"
		"static const int unknown_index[3] = { 1, 2, 3 };\n"
		"static int relocation_target = 13;\n"
		"static int *relocation = &relocation_target;\n"
		"int external_value = 17;\n"
		"struct VolatileMember { volatile int value; };\n"
		"static struct VolatileMember volatile_struct = { 19 };\n"
		"static const char *same_a = \"merged literal\";\n"
		"static const char *same_b = \"merged literal\";\n"
		"static const char *different = \"different literal\";\n"
		"int read_number(void) { return numbers[1]; }\n"
		"int read_zero(void) { return zero_bss; }\n"
		"void write_only_global(int value) { write_only = value; }\n"
		"int *escape_address(void) { return &escaped; }\n"
		"int read_escaped(void) { return escaped; }\n"
		"int read_volatile_global(void) { return volatile_value; }\n"
		"void write_cross_function(int value) { cross_function = value; }\n"
		"int read_cross_function(void) { return cross_function; }\n"
		"int read_unknown_index(int index) { return unknown_index[index]; }\n"
		"int read_relocation_target(void) { return relocation_target; }\n"
		"int read_external(void) { return external_value; }\n"
		"int read_volatile_member(void) { return volatile_struct.value; }\n"
		"int compare_same_literals(void) { return same_a == same_b; }\n"
		"int read_distinct_literal(void) { return different[0]; }\n");
	f.run_o2();
	f.verify_graph();
	assert_returns_int(find_function(&f.graph, "read_number"), f.graph.interner, 20,
		"a constant array element load should fold");
	assert_returns_int(find_function(&f.graph, "read_zero"), f.graph.interner, 0,
		"an unwritten BSS global should fold to zero");
	assert(count_body_tag(find_function(&f.graph, "write_only_global"), ir::InstTag.STORE) == 0,
		"stores to an unread internal global should be removed");
	assert(count_body_tag(find_function(&f.graph, "read_volatile_global"), ir::InstTag.LOAD) == 1,
		"volatile global loads must remain observable");
	assert(count_body_tag(find_function(&f.graph, "read_escaped"), ir::InstTag.LOAD) == 1,
		"a global whose address escapes must remain loaded from memory");
	assert(count_body_tag(find_function(&f.graph, "read_cross_function"), ir::InstTag.LOAD) == 1,
		"a global written in another function must remain loaded");
	assert(count_body_tag(find_function(&f.graph, "read_unknown_index"), ir::InstTag.LOAD) == 1,
		"a dynamically indexed array load must remain in memory");
	assert(count_body_tag(find_function(&f.graph, "read_relocation_target"), ir::InstTag.LOAD) == 1,
		"a global referenced by another global's relocation must be treated as escaped");
	assert(count_body_tag(find_function(&f.graph, "read_external"), ir::InstTag.LOAD) == 1,
		"an external-linkage global must remain loaded");
	assert(count_body_tag(find_function(&f.graph, "read_volatile_member"), ir::InstTag.LOAD) == 1,
		"a volatile struct member load must remain observable");
	String output = f.dump();
	assert(!output.contains("global @write_only "), "an unread internal global should be removed");
	assert(output.contains("@escaped") && output.contains("@relocation_target"),
		"address and relocation escapes should keep their globals");
	assert(output.contains("@external_value"), "an external-linkage global should remain");
	assert(output.contains("different literal"), "distinct string literal data must remain available");
	// The two equal literals should have one canonical backing object after O2.
	uint literal_count = 0;
	for (sz i = 0; i + 13 < output.len; i++)
	{
		if (output[i..i + 13] == "merged literal") literal_count++;
	}
	assert(literal_count == 1, "identical string literals should share one backing object");
	alloc::free(&f.ta, output.ptr);
	f.free();
}

fn void dead_arg_elim_keeps_variadic_parameters_without_va_start() @test
{
	OptFixture f;
	f.init();
	f.lower("static int variadic(int unused, ...) { return 7; }\n"
		"int main(void) { return variadic(11, 22); }");
	run_dead_arg_elim(&f);
	f.verify_graph();
	assert(count_body_tag(find_function(&f.graph, "variadic"), ir::InstTag.ARG) == 1,
		"a variadic function's fixed parameter should remain even without VA_START");
	ir::Decl* main_fn = find_function(&f.graph, "main");
	bool saw_original_variadic_call = false;
	foreach (ref : main_fn.body)
	{
		ir::Inst* inst = &main_fn.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.CALL && inst.data.call.args.len == 2 &&
			main_fn.instructions[(sz)inst.data.call.func].data.label == "variadic")
		{
			saw_original_variadic_call = true;
		}
	}
	assert(saw_original_variadic_call, "the fixed and variadic call operands should remain intact");
	f.free();
}

fn void dead_arg_elim_variadic_fixed_args_and_extra_args() @test
{
	OptFixture f;
	f.init();
	f.lower("static int v(int dead, int k, ...) { return k; }\n"
		"int main(void) { return v(1, 2) + v(1, 2, 3); }");
	run_dead_arg_elim(&f);
	f.verify_graph();
	assert(count_body_tag(find_function(&f.graph, "v"), ir::InstTag.ARG) == 2,
		"a variadic function called with extra arguments must keep its fixed ABI parameters");
	uint two_arg_calls = 0;
	uint three_arg_calls = 0;
	ir::Decl* main_fn = find_function(&f.graph, "main");
	foreach (ref : main_fn.body)
	{
		ir::Inst* inst = &main_fn.instructions[(sz)ref];
		if (inst.tag != ir::InstTag.CALL ||
			main_fn.instructions[(sz)inst.data.call.func].data.label != "v") continue;
		if (inst.data.call.args.len == 2) two_arg_calls++;
		if (inst.data.call.args.len == 3) three_arg_calls++;
	}
	assert(two_arg_calls == 1 && three_arg_calls == 1,
		"both fixed-only and extra-vararg call layouts must remain unchanged");
	f.free();
}

fn void dead_arg_elim_forwards_kept_arguments_in_source_order() @test
{
	OptFixture f;
	f.init();
	f.lower("static int target(int gone0, int kept0, int gone1, int kept1) { return kept0 + kept1; }\n"
		"int main(void) { return target(10, 20, 30, 40); }");
	// DeadArgElim runs after mem2reg in run(); parameters must not be alloca-backed.
	f.run_mem2reg();
	assert(run_dead_arg_elim(&f), "unused arguments should be removed");
	f.verify_graph();
	assert(count_body_tag(find_function(&f.graph, "target"), ir::InstTag.ARG) == 2,
		"the callee should retain its two used parameters");
	ir::Decl* main_fn = find_function(&f.graph, "main");
	bool saw_ordered_call = false;
	foreach (ref : main_fn.body)
	{
		ir::Inst* inst = &main_fn.instructions[(sz)ref];
		if (inst.tag != ir::InstTag.CALL || inst.data.call.args.len != 2 ||
			main_fn.instructions[(sz)inst.data.call.func].data.label != "target") continue;
		saw_ordered_call = is_int_constant(main_fn, inst.data.call.args[0], f.graph.interner, 20) &&
			is_int_constant(main_fn, inst.data.call.args[1], f.graph.interner, 40);
	}
	assert(saw_ordered_call, "remaining operands should be forwarded in their original order");
	f.free();
}

fn void dead_arg_elim_keeps_scalar_result_used_through_narrowing_cast() @test
{
	OptFixture f;
	f.init();
	f.lower("static unsigned long target(int unused) { return 0x100000001ul; }\n"
		"int main(void) { return (int)target(3); }");
	// DeadArgElim runs after mem2reg in run(); parameters must not be alloca-backed.
	f.run_mem2reg();
	assert(run_dead_arg_elim(&f), "the unused parameter should still be removable");
	f.verify_graph();
	ir::Decl* target = find_function(&f.graph, "target");
	assert(count_body_tag(target, ir::InstTag.ARG) == 0, "the unused parameter should be removed");
	ir::Decl* main_fn = find_function(&f.graph, "main");
	bool saw_live_result_call = false;
	foreach (ref : main_fn.body)
	{
		ir::Inst* inst = &main_fn.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.CALL &&
			main_fn.instructions[(sz)inst.data.call.func].data.label == "target")
		{
			saw_live_result_call = inst.ty != value_interner::REF_VOID;
		}
	}
	assert(saw_live_result_call, "a result consumed by a narrowing cast must remain valued");
	f.free();
}

fn void dead_arg_elim_preserves_partial_pair_results() @test
{
	OptFixture f;
	f.init();
	f.lower("struct Pair { long low, high; };\n"
		"static struct Pair target(int unused) { return (struct Pair){ 11, 22 }; }\n"
		"int main(void) { struct Pair pair = target(3); return (int)pair.low; }");
	// DeadArgElim runs after mem2reg in run(); parameters must not be alloca-backed.
	f.run_mem2reg();
	assert(run_dead_arg_elim(&f), "the unused parameter should be removable");
	f.verify_graph();
	assert(count_body_tag(find_function(&f.graph, "target"), ir::InstTag.RET_PAIR) == 1,
		"the callee's paired return should remain intact");
	assert(count_body_tag(find_function(&f.graph, "main"), ir::InstTag.CALL_HI) == 1,
		"the high half of the partially used pair call should remain available");
	ir::Decl* main_fn = find_function(&f.graph, "main");
	bool saw_pair_call = false;
	foreach (ref : main_fn.body)
	{
		ir::Inst* inst = &main_fn.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.CALL &&
			main_fn.instructions[(sz)inst.data.call.func].data.label == "target")
		{
			saw_pair_call = inst.ty != value_interner::REF_VOID && inst.data.call.args.len == 0;
		}
	}
	assert(saw_pair_call, "the pair call should retain its result while dropping its dead argument");
	f.free();
}

fn void dead_arg_elim_keeps_ignored_pair_return_shape() @test
{
	OptFixture f;
	f.init();
	f.lower("struct Pair { long low, high; };\n"
		"static struct Pair target(int unused) { return (struct Pair){ 11, 22 }; }\n"
		"int main(void) { target(3); return 0; }");
	run_dead_arg_elim(&f);
	f.verify_graph();
	assert(count_body_tag(find_function(&f.graph, "target"), ir::InstTag.RET_PAIR) == 1,
		"an ignored RET_PAIR result must remain unchanged");
	bool saw_pair_call = false;
	ir::Decl* main_fn = find_function(&f.graph, "main");
	foreach (ref : main_fn.body)
	{
		ir::Inst* inst = &main_fn.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.CALL &&
			main_fn.instructions[(sz)inst.data.call.func].data.label == "target")
		{
			saw_pair_call = inst.ty != value_interner::REF_VOID;
		}
	}
	assert(saw_pair_call, "an ignored paired return must retain its aggregate call shape");
	f.free();
}

fn void dead_arg_elim_keeps_cast_calls_conservative() @test
{
	OptFixture f;
	f.init();
	f.lower("static int target(int value) { return value; }\n"
		"int main(void) { return ((int (*)(int, int))target)(5, 9); }");
	run_dead_arg_elim(&f);
	f.verify_graph();
	assert(count_body_tag(find_function(&f.graph, "target"), ir::InstTag.ARG) == 1,
		"a symbol used directly as a mismatched-arity callee must keep its original parameter");
	bool saw_mismatched_call = false;
	ir::Decl* main_fn = find_function(&f.graph, "main");
	foreach (ref : main_fn.body)
	{
		ir::Inst* inst = &main_fn.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.CALL &&
			main_fn.instructions[(sz)inst.data.call.func].data.label == "target")
		{
			saw_mismatched_call = inst.data.call.args.len == 2;
		}
	}
	assert(saw_mismatched_call, "the direct SYMBOL call must retain both mismatched operands");
	f.free();
}

fn void dead_arg_elim_handles_recursive_helper() @test
{
	OptFixture f;
	f.init();
	f.lower("static int recurse(int unused, int n) { if (n == 0) return 0; return recurse(9, n - 1); }\n"
		"int main(void) { return recurse(8, 3); }");
	f.run_mem2reg();
	assert(run_dead_arg_elim(&f), "the unused recursive helper parameter should be removed");
	f.verify_graph();
	assert(count_body_tag(find_function(&f.graph, "recurse"), ir::InstTag.ARG) == 1,
		"dead-argument elimination should remove the unused recursive helper parameter");
	ir::Decl* recurse = find_function(&f.graph, "recurse");
	bool saw_reduced_recursive_call = false;
	foreach (ref : recurse.body)
	{
		ir::Inst* inst = &recurse.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.CALL && inst.data.call.args.len == 1 &&
			recurse.instructions[(sz)inst.data.call.func].data.label == "recurse")
		{
			saw_reduced_recursive_call = true;
		}
	}
	assert(saw_reduced_recursive_call, "the recursive edge should forward only the live parameter");
	f.free();
}

fn void dead_arg_elim_forwards_kept_arguments_when_caller_precedes_definition() @test
{
	OptFixture f;
	f.init();
	f.lower("static int target(int gone0, int kept0, int gone1, int kept1);\n"
		"int main(void) { return target(10, 20, 30, 40); }\n"
		"static int target(int gone0, int kept0, int gone1, int kept1) { return kept0 + kept1; }");
	// DeadArgElim runs after mem2reg in run(); parameters must not be alloca-backed.
	f.run_mem2reg();
	assert(run_dead_arg_elim(&f), "unused arguments should be removed regardless of declaration order");
	f.verify_graph();
	assert(count_body_tag(find_function(&f.graph, "target"), ir::InstTag.ARG) == 2,
		"the later definition should retain only its used parameters");
	ir::Decl* main_fn = find_function(&f.graph, "main");
	bool saw_ordered_call = false;
	foreach (ref : main_fn.body)
	{
		ir::Inst* inst = &main_fn.instructions[(sz)ref];
		if (inst.tag != ir::InstTag.CALL || inst.data.call.args.len != 2 ||
			main_fn.instructions[(sz)inst.data.call.func].data.label != "target") continue;
		saw_ordered_call = is_int_constant(main_fn, inst.data.call.args[0], f.graph.interner, 20) &&
			is_int_constant(main_fn, inst.data.call.args[1], f.graph.interner, 40);
	}
	assert(saw_ordered_call, "later-declared callee operands should remain in source order");
	f.free();
}

fn void dead_arg_elim_forwarder_after_callee_observes_pruned_parameter() @test
{
	OptFixture f;
	f.init();
	f.lower("static int target(int unused) { return 7; }\n"
		"static int forwarder(int value) { return target(value); }\n"
		"int main(void) { return forwarder(3); }");
	// DeadArgElim runs after mem2reg in run(); parameters must not be alloca-backed.
	f.run_mem2reg();
	assert(run_dead_arg_elim(&f), "dead parameters should be removed in declaration order");
	f.verify_graph();
	assert(count_body_tag(find_function(&f.graph, "target"), ir::InstTag.ARG) == 0,
		"the earlier target should lose its unused parameter");
	assert(count_body_tag(find_function(&f.graph, "forwarder"), ir::InstTag.ARG) == 0,
		"the later forwarder should lose its argument after the target operand is pruned");
	uint target_calls = 0;
	uint forwarder_calls = 0;
	foreach (&decl : f.graph.decls)
	{
		foreach (ref : decl.body)
		{
			ir::Inst* inst = &decl.instructions[(sz)ref];
			if (inst.tag != ir::InstTag.CALL) continue;
			ir::Inst* func = &decl.instructions[(sz)inst.data.call.func];
			if (func.tag != ir::InstTag.SYMBOL) continue;
			if (func.data.label == "target")
			{
				target_calls++;
				assert(inst.data.call.args.len == 0, "the call to target should have no operands");
			}
			else if (func.data.label == "forwarder")
			{
				forwarder_calls++;
				assert(inst.data.call.args.len == 0, "the call to forwarder should have no operands");
			}
		}
	}
	assert(target_calls == 1 && forwarder_calls == 1, "both direct calls should remain with zero operands");
	f.free();
}

fn void dead_arg_elim_forwarder_before_callee_keeps_argument_this_pass() @test
{
	OptFixture f;
	f.init();
	f.lower("static int target(int);\n"
		"static int forwarder(int value) { return target(value); }\n"
		"static int target(int unused) { return 7; }\n"
		"int main(void) { return forwarder(3); }");
	// DeadArgElim runs after mem2reg in run(); parameters must not be alloca-backed.
	f.run_mem2reg();
	assert(run_dead_arg_elim(&f), "the target's dead parameter should be removed");
	f.verify_graph();
	assert(count_body_tag(find_function(&f.graph, "target"), ir::InstTag.ARG) == 0,
		"the later target should lose its unused parameter");
	assert(count_body_tag(find_function(&f.graph, "forwarder"), ir::InstTag.ARG) == 1,
		"the earlier forwarder keeps its argument because it was live when visited");
	uint target_calls = 0;
	uint forwarder_calls = 0;
	foreach (&decl : f.graph.decls)
	{
		foreach (ref : decl.body)
		{
			ir::Inst* inst = &decl.instructions[(sz)ref];
			if (inst.tag != ir::InstTag.CALL) continue;
			ir::Inst* func = &decl.instructions[(sz)inst.data.call.func];
			if (func.tag != ir::InstTag.SYMBOL) continue;
			if (func.data.label == "target")
			{
				target_calls++;
				assert(inst.data.call.args.len == 0, "the call to target should lose its forwarded operand");
			}
			else if (func.data.label == "forwarder")
			{
				forwarder_calls++;
				assert(inst.data.call.args.len == 1, "the call to forwarder should retain its operand this pass");
			}
		}
	}
	assert(target_calls == 1 && forwarder_calls == 1, "both direct calls should remain with expected operand counts");
	f.free();
}

fn void dead_arg_elim_preserves_scalar_result_for_only_used_call() @test
{
	OptFixture f;
	f.init();
	f.lower("static int target(int unused, int value) { return value; }\n"
		"int main(void) { int used = target(3, 7); (void)target(4, 9); return used; }");
	// DeadArgElim runs after mem2reg in run(); parameters must not be alloca-backed.
	f.run_mem2reg();
	assert(run_dead_arg_elim(&f), "the unused argument and unused scalar return should be removable");
	f.verify_graph();
	assert(count_body_tag(find_function(&f.graph, "target"), ir::InstTag.ARG) == 1,
		"only the parameter used by the function should remain");
	assert(return_value(find_function(&f.graph, "target")) != ir::NONE,
		"the scalar return must remain because one call consumes it");
	ir::Decl* main_fn = find_function(&f.graph, "main");
	uint valued_calls = 0;
	uint void_calls = 0;
	foreach (ref : main_fn.body)
	{
		ir::Inst* inst = &main_fn.instructions[(sz)ref];
		if (inst.tag != ir::InstTag.CALL ||
			main_fn.instructions[(sz)inst.data.call.func].data.label != "target") continue;
		assert(inst.data.call.args.len == 1, "both callsites should drop the unused argument");
		if (inst.ty == value_interner::REF_VOID)
		{
			void_calls++;
		}
		else
		{
			valued_calls++;
		}
	}
	// LLVM DeadArgumentElimination keeps a return live for every call once any
	// call site uses it; the ignored call keeps its scalar type.
	assert(valued_calls == 2 && void_calls == 0,
		"a live scalar return keeps every call site's result type");
	f.free();
}

fn void dead_arg_elim_preserves_sret_and_removes_explicit_unused_argument() @test
{
	OptFixture f;
	f.init();
	f.lower("struct Big { long a, b, c; };\n"
		"static struct Big target(int unused) { return (struct Big){ 11, 22, 33 }; }\n"
		"int main(void) { struct Big result = target(3); return (int)result.a; }");
	// DeadArgElim runs after mem2reg in run(); parameters must not be alloca-backed.
	f.run_mem2reg();
	assert(run_dead_arg_elim(&f), "the unused explicit argument should be removable");
	f.verify_graph();
	ir::Decl* target = find_function(&f.graph, "target");
	uint arg_count = 0;
	bool saw_sret_arg = false;
	foreach (ref : target.body)
	{
		ir::Inst* inst = &target.instructions[(sz)ref];
		if (inst.tag != ir::InstTag.ARG) break;
		arg_count++;
		saw_sret_arg |= inst.ty == value_interner::REF_PTR;
	}
	assert(arg_count == 1 && saw_sret_arg,
		"the hidden sret pointer should remain after removing the explicit unused argument");
	f.free();
}

fn void dead_arg_elim_reduces_recursive_mixed_int_double_helper() @test
{
	OptFixture f;
	f.init();
	f.lower("static double recurse(int n, int dead, double s, int *p, double dead2) {\n"
		"  if (n == 0) return s + *p;\n"
		"  return recurse(n - 1, 0, s * 2, p, 0.0);\n"
	"}\n"
		"int main(void) { int value = 2; return (int)recurse(3, 8, 1.5, &value, 4.0); }");
	f.run_mem2reg();
	assert(run_dead_arg_elim(&f), "unused mixed integer and double parameters should be removed");
	f.verify_graph();
	ir::Decl* recurse = find_function(&f.graph, "recurse");
	assert(count_body_tag(recurse, ir::InstTag.ARG) == 3,
		"dead-argument elimination should remove the unused integer and double parameters from the mixed helper");
	bool saw_live_int = false;
	bool saw_live_double = false;
	foreach (ref : recurse.body)
	{
		ir::Inst* inst = &recurse.instructions[(sz)ref];
		if (inst.tag != ir::InstTag.ARG) break;
		if (inst.ty == value_interner::REF_I32) saw_live_int = true;
		if (inst.ty == value_interner::REF_F64) saw_live_double = true;
	}
	bool saw_live_pointer = false;
	foreach (ref : recurse.body)
	{
		ir::Inst* inst = &recurse.instructions[(sz)ref];
		if (inst.tag != ir::InstTag.ARG) break;
		if (inst.ty == value_interner::REF_PTR) saw_live_pointer = true;
	}
	assert(saw_live_int && saw_live_double && saw_live_pointer,
		"the reduced helper should retain its integer, floating-point, and pointer arguments");
	uint recursive_calls = 0;
	foreach (ref : recurse.body)
	{
		ir::Inst* inst = &recurse.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.CALL &&
			recurse.instructions[(sz)inst.data.call.func].data.label == "recurse")
		{
			assert(inst.data.call.args.len == 3,
				"the recursive mixed-type call should forward exactly the three live arguments");
			recursive_calls++;
		}
	}
	assert(recursive_calls == 1, "the recursive edge should remain after O2");
	f.free();
}
fn void ipo_attributes_cover_pointer_provenance_and_local_storage_edges() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"typedef unsigned long uintptr_t;\n"
		"void arg_nowrite_cast(long x) { *(int *)x = 1; }\n"
		"uintptr_t integer_mask(int *p) { return (uintptr_t)p & ~7UL; }\n"
		"uintptr_t integer_add(int *p) { return (uintptr_t)p + 3; }\n"
		"int *via(int *p) { int *slot[1]; slot[0] = p; return slot[0]; }\n"
		"void stored_pointer_slot(int *p) { int *slot[1]; slot[0] = p; *slot[0] = 1; }\n"
		"void phi_pointer_write(int *p, int *q, int choose) { int *r; "
		"if (choose) r = p; else r = q; *r = 1; }\n"
		"int volatile_cast_local(void) { int value; volatile int *p = (volatile int *)&value; "
		"*p = 3; return value; }\n"
		"int finite_constant_trip(void) { int n = 0; for (int i = 0; i < 3; i++) n++; return n; }\n");
	f.run_mem2reg();
	ir_opt::infer_function_attrs(&f.graph);
	assert((find_function(&f.graph, "arg_nowrite_cast").attrs.arg_nowrite & 1) == 0,
		"a store through a pointer cast from the long argument must clear arg_nowrite");
	assert((find_function(&f.graph, "integer_mask").attrs.arg_nocapture & 1) == 0,
		"integer AND arithmetic on a pointer argument must clear nocapture");
	assert((find_function(&f.graph, "integer_add").attrs.arg_nocapture & 1) == 0,
		"integer ADD arithmetic on a pointer argument must clear nocapture");
	assert((find_function(&f.graph, "via").attrs.arg_nocapture & 1) == 0,
		"returning a pointer argument reloaded from a local array slot must clear nocapture");
	assert((find_function(&f.graph, "stored_pointer_slot").attrs.arg_nowrite & 1) == 0,
		"storing a pointer argument in an array slot then writing through the reload must clear arg_nowrite");
	assert((find_function(&f.graph, "stored_pointer_slot").attrs.arg_nocapture & 1) == 0,
		"storing an argument pointer into a local array slot must clear nocapture");
	ir::FnAttrs phi_attrs = find_function(&f.graph, "phi_pointer_write").attrs;
	assert((phi_attrs.arg_nowrite & 3) == 0,
		"a PHI that merges two pointer arguments written through must clear both arg_nowrite bits");
	assert(!find_function(&f.graph, "volatile_cast_local").attrs.readnone &&
		!find_function(&f.graph, "volatile_cast_local").attrs.readonly,
		"a volatile-qualified access through a cast of a nonvolatile local is a side effect");
	assert(!find_function(&f.graph, "finite_constant_trip").attrs.will_return,
		"the current CFG backedge check conservatively rejects even a finite trip-count loop");
	f.free();
}

fn void ipo_attributes_keep_calls_without_proven_return_or_memory_safety() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int even(int n); static int odd(int n);\n"
		"static int even(int n) { return n ? odd(n - 1) : 1; }\n"
		"static int odd(int n) { return n ? even(n - 1) : 0; }\n"
		"int call_mutual_pair(void) { even(2); return 0; }\n"
		"static int fp_self(int n) { int (*fp)(int) = fp_self; return n ? fp(n - 1) : 0; }\n"
		"int call_fp_self(void) { fp_self(2); return 0; }\n"
		"static void trap_helper(void) { __builtin_trap(); }\n"
		"int call_trap_helper(void) { trap_helper(); return 0; }\n"
		"static int divide_helper(int n) { return 12 / n; }\n"
		"int call_ub_division_helper(void) { divide_helper(0); return 0; }\n");
	f.run_mem2reg();
	ir_opt::infer_function_attrs(&f.graph);
	assert(!find_function(&f.graph, "even").attrs.readnone && !find_function(&f.graph, "odd").attrs.readnone,
		"same-SCC calls are treated conservatively for memory effects");
	assert(!find_function(&f.graph, "fp_self").attrs.will_return,
		"an indirect self-recursive call cannot establish willreturn");
	String[3] retained_callers = { "call_mutual_pair", "call_fp_self", "call_trap_helper" };
	foreach (name : retained_callers)
	{
		ir::Decl* caller = find_function(&f.graph, name);
		// The return value reports changes; nothing else in these callers is dead.
		ir_opt::dead_instruction_elim(caller, &f.graph);
		assert(count_body_tag(caller, ir::InstTag.CALL) == 1,
			"DIE should keep an unused call without a proven safe return: %s", name);
	}
	ir::Decl* ub_caller = find_function(&f.graph, "call_ub_division_helper");
	assert(find_function(&f.graph, "divide_helper").attrs.readnone &&
		find_function(&f.graph, "divide_helper").attrs.will_return,
		"a division helper is summarized as pure and returning on defined executions");
	// LLVM's wouldInstructionBeTriviallyDead also permits deleting this call on its UB invocation.
	assert(ir_opt::dead_instruction_elim(ub_caller, &f.graph), "DIE should process UB helper caller");
	assert(count_body_tag(ub_caller, ir::InstTag.CALL) == 0,
		"DIE may remove an unused pure call even when this invocation has undefined behavior");
	f.free();
}

fn void ipsccp_rejects_address_taken_functions_across_escape_paths() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"extern void retain_callback(int (*callback)(int));\n"
		"static int global_callback(int value) { return value; }\n"
		"int (*callback_slot)(int) = global_callback;\n"
		"static int escaped_callback(int value) { return value; }\n"
		"void pass_callback(void) { retain_callback(escaped_callback); }\n"
		"int global_callback_site(void) { return global_callback(6); }\n"
		"int escaped_callback_site(void) { return escaped_callback(7); }\n"
		"static int stored_callback(int value) { return value; }\n"
		"int store_callback_escape(void) { int (*local)(int); local = stored_callback; "
		"return stored_callback(8) + (local(1) != 0); }\n"
		"static int compared_callback(int value) { return value; }\n"
		"int compare_callback_escape(int (*local)(int)) { "
		"int same = local == compared_callback; return compared_callback(9) + same; }\n");
	f.run_mem2reg();
	ir_opt::ipsccp(&f.graph, {
		.level = code_gen_options::OptimizationLevel.O2,
		.whole_program = false,
		.verify = true,
	});
	f.verify_graph();
	assert(returns_argument(find_function(&f.graph, "global_callback")),
		"a function address stored in global callback data must prevent argument specialization");
	assert(returns_argument(find_function(&f.graph, "escaped_callback")),
		"passing a function address to an external callback sink must prevent specialization");
	assert(returns_argument(find_function(&f.graph, "stored_callback")),
		"storing a function address through a local pointer variable must prevent specialization");
	assert(returns_argument(find_function(&f.graph, "compared_callback")),
		"comparing a function pointer with a function address must prevent specialization");
	f.free();
}

fn void ipsccp_handles_closed_world_variadic_and_recursive_calls() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"extern void qsort(void *base, unsigned long count, unsigned long size, int (*compare)(int));\n"
		"int closed_target(int value) { return value + 1; }\n"
		"int qsort_comparator(int value) { return value; }\n"
		"int (*callback_slot)(int);\n"
		"static int callback_target(int value) { return value + 2; }\n"
		"static int variadic_no_start(int value, ...) { return value; }\n"
		"static int recursive_passthrough(int depth, int value) {\n"
		"  return depth ? recursive_passthrough(depth - 1, value) : value;\n"
		"}\n"
		"int main(void) { callback_slot = callback_target; qsort(0, 0, 0, qsort_comparator);\n"
		"  return closed_target(8) + callback_target(9) + qsort_comparator(4) + variadic_no_start(10) +\n"
		"    recursive_passthrough(2, 11); }\n");
	f.run_mem2reg();
	ir_opt::ipsccp(&f.graph, {
		.level = code_gen_options::OptimizationLevel.O2,
		.whole_program = true,
		.verify = true,
	});
	f.verify_graph();
	assert_returns_bin_with_constant(find_function(&f.graph, "closed_target"), ir::InstTag.ADD,
		f.graph.interner, 8, "closed-world externally linked callee");
	assert_returns_arg_plus_int(find_function(&f.graph, "callback_target"), f.graph.interner, 2,
		"an address-taken callback remains ineligible even in the closed world");
	assert(returns_argument(find_function(&f.graph, "qsort_comparator")),
		"a non-static function passed as a qsort comparator must remain ineligible in closed-world mode");
	assert(is_int_constant(find_function(&f.graph, "variadic_no_start"),
		return_value(find_function(&f.graph, "variadic_no_start")), f.graph.interner, 10),
		"a variadic function that does not inspect varargs should specialize from its fixed argument");
	ir::Decl* recursive = find_function(&f.graph, "recursive_passthrough");
	ir::Ref recursive_return = return_value(recursive);
	assert(count_body_tag(recursive, ir::InstTag.CALL) == 1 && recursive_return != ir::NONE &&
		recursive.instructions[(sz)recursive_return].tag != ir::InstTag.CONSTANT,
		"a recursive passthrough callsite must remain conservative when its argument is only forwarded");
	f.free();
}

fn void ipsccp_preserves_external_function_return_under_o2() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"int externally_constant(void) { return 23; }\n"
		"int constant_call_site(void) { return externally_constant(); }\n");
	f.run_o2();
	f.verify_graph();
	ir::Decl* external = find_function(&f.graph, "externally_constant");
	assert(count_body_tag(external, ir::InstTag.RET) == 1,
		"O2 should retain the externally visible function's return instruction");
	assert_returns_int(find_function(&f.graph, "constant_call_site"), f.graph.interner, 23,
		"call to externally visible constant-return function");
	f.free();
}

fn void ipsccp_drops_static_constant_return_under_full_o2() @test
{
	OptFixture f;
	f.init();
	f.lower("static int private_constant(void) { return 29; }\n"
		"int private_constant_caller(void) { return private_constant(); }\n");
	f.run_o2();
	f.verify_graph();
	bool found_private_constant = false;
	foreach (decl : f.graph.decls)
		if (decl.name == "private_constant") found_private_constant = true;
	assert(!found_private_constant,
		"full O2 should remove a static constant-return function after its call is folded");
	assert_returns_int(find_function(&f.graph, "private_constant_caller"), f.graph.interner, 29,
		"full O2 static constant return caller");
	f.free();
}

fn void ipsccp_handles_variadic_agreement_and_stack_abi_constants() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"struct LargeByval { long a, b, c; };\n"
		"static int variadic_conflict(int value, ...) { return value; }\n"
		"int variadic_conflict_sites(void) { return variadic_conflict(3) + variadic_conflict(4); }\n"
		"static int variadic_arity(int value, ...) { return value; }\n"
		"int variadic_arity_sites(void) { return variadic_arity(3) + variadic_arity(3, 4); }\n"
		"static int variadic_agreed(int value, ...) { return value + 1; }\n"
		"int variadic_agreed_sites(void) { return variadic_agreed(5) + variadic_agreed(5); }\n"
		"static int stack_arguments(int a, int b, int c, int d, int e, int f, int g, int h) { return g + h; }\n"
		"int stack_argument_site(void) { return stack_arguments(1, 2, 3, 4, 5, 6, 7, 8); }\n"
		"static long byval_parameter(long value, struct LargeByval pair) { return value + pair.a; }\n"
		"long byval_site(void) { return byval_parameter(3, (struct LargeByval){ 4, 5, 6 }); }\n"
		"static long double long_double_argument(long double value) { return value; }\n"
		"long double long_double_site(void) { return long_double_argument(1.25L); }\n");
	f.run_mem2reg();
	bool saw_stack_only_seventh = false;
	bool saw_stack_only_eighth = false;
	foreach (ref : find_function(&f.graph, "stack_argument_site").body)
	{
		ir::Inst* inst = &find_function(&f.graph, "stack_argument_site").instructions[(sz)ref];
		if (inst.tag != ir::InstTag.CALL || inst.data.call.args.len != 8) continue;
		saw_stack_only_seventh = inst.data.call.stack_only.len == 8 && inst.data.call.stack_only[6];
		saw_stack_only_eighth = inst.data.call.stack_only.len == 8 && inst.data.call.stack_only[7];
	}
	assert(saw_stack_only_seventh && saw_stack_only_eighth,
		"the 7th and 8th integer arguments should carry stack_only ABI metadata");
	bool saw_stack_only_long_double = false;
	ir::Decl* long_double_site = find_function(&f.graph, "long_double_site");
	foreach (ref : long_double_site.body)
	{
		ir::Inst* inst = &long_double_site.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.CALL && inst.data.call.args.len == 1 &&
			inst.data.call.stack_only.len == 1 && inst.data.call.stack_only[0])
		{
			saw_stack_only_long_double = true;
		}
	}
	assert(saw_stack_only_long_double,
		"long double must carry its memory-passed stack_only ABI metadata");
	bool saw_byval_copy_metadata = false;
	foreach (ref : find_function(&f.graph, "byval_site").body)
	{
		ir::Inst* inst = &find_function(&f.graph, "byval_site").instructions[(sz)ref];
		if (inst.tag == ir::InstTag.CALL && inst.data.call.args.len == 2)
		{
			saw_byval_copy_metadata = inst.data.call.memory_copy_bytes[1] != 0;
		}
	}
	assert(saw_byval_copy_metadata, "the large by-value argument must carry memory-copy metadata");
	ir_opt::ipsccp(&f.graph, {
		.level = code_gen_options::OptimizationLevel.O2,
		.whole_program = false,
		.verify = true,
	});
	f.verify_graph();
	assert(returns_argument(find_function(&f.graph, "variadic_conflict")),
		"conflicting same-arity variadic sites without VA_START must block specialization");
	assert(returns_argument(find_function(&f.graph, "variadic_arity")),
		"different arities at no-VA_START variadic sites must block specialization");
	assert_returns_bin_with_constant(find_function(&f.graph, "variadic_agreed"), ir::InstTag.ADD,
		f.graph.interner, 5, "agreed variadic fixed argument");
	assert_returns_bin_with_constant(find_function(&f.graph, "stack_arguments"), ir::InstTag.ADD,
		f.graph.interner, 7, "7th stack-only argument");
	assert_returns_bin_with_constant(find_function(&f.graph, "stack_arguments"), ir::InstTag.ADD,
		f.graph.interner, 8, "8th stack-only argument");
	ir::Decl* long_double_callee = find_function(&f.graph, "long_double_argument");
	ir::Ref long_double_result = return_value(long_double_callee);
	assert(long_double_result != ir::NONE &&
		long_double_callee.instructions[(sz)long_double_result].tag == ir::InstTag.CONSTANT,
		"a literal long double argument must specialize despite memory ABI placement");
	assert(count_body_tag(find_function(&f.graph, "byval_parameter"), ir::InstTag.ARG) == 2,
		"the memory-copied aggregate parameter must remain unspecialized");
	assert_returns_bin_with_constant(find_function(&f.graph, "byval_parameter"), ir::InstTag.ADD,
		f.graph.interner, 3, "scalar argument beside memory-copy parameter");
	f.free();
}

fn void ipsccp_rejects_phi_and_select_function_address_escapes() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int phi_target(int value) { return value; }\n"
		"static int select_target(int value) { return value; }\n"
		"static int (*choose_phi(int condition))(int) { int (*local)(int); if (condition) local = phi_target; else local = 0; return local; }\n"
		"static int (*choose_select(int condition))(int) { return condition ? select_target : 0; }\n"
		"int phi_escape_site(void) { return phi_target(8) + (choose_phi(1) != 0); }\n"
		"int select_escape_site(void) { return select_target(9) + (choose_select(1) != 0); }\n");
	f.run_mem2reg();
	ir_opt::ipsccp(&f.graph, {
		.level = code_gen_options::OptimizationLevel.O2,
		.whole_program = false,
		.verify = true,
	});
	f.verify_graph();
	assert(returns_argument(find_function(&f.graph, "phi_target")),
		"a function address merged through a PHI and returned must block specialization");
	assert(returns_argument(find_function(&f.graph, "select_target")),
		"a function address merged through a SELECT and returned must block specialization");
	f.free();
}

fn void ipsccp_handles_unreachable_conflicting_return_conservatively() @test
{
	HandIrFixture f;
	f.init();
	Ref three = f.add_int_constant(3, value_interner::REF_I32);
	Ref four = f.add_int_constant(4, value_interner::REF_I32);
	f.builder.start_fn();
	f.builder.add_return(three);
	Ref dead_block = f.builder.make_label("dead_return");
	f.builder.start_block(dead_block);
	f.builder.add_return(four);
	f.builder.finish_fn("unreachable_conflict", ir::Linkage.INTERNAL);

	f.builder.start_fn();
	Ref callee_symbol = f.builder.add_symbol("unreachable_conflict", value_interner::REF_FUNC);
	Ref call = f.builder.add_call(callee_symbol, {}, value_interner::REF_I32);
	f.builder.add_return(call);
	f.builder.finish_fn("unreachable_call_site");
	f.finish();
	ir_opt::ipsccp(&f.graph, {
		.level = code_gen_options::OptimizationLevel.O2,
		.whole_program = false,
		.verify = true,
	});
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "hand-built IPSCCP graph should verify: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	errors.free();
	assert(count_body_tag(find_function(&f.graph, "unreachable_call_site"), ir::InstTag.CALL) == 1,
		"a conflicting unreachable return must conservatively prevent constant-return propagation");
	f.free();
}

fn void ipsccp_resets_function_attrs_when_specializing() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"static int attributed_target(int value) { return value + 1; }\n"
		"int attributed_caller(void) { return attributed_target(12); }\n");
	f.run_mem2reg();
	ir::Decl* target = find_function(&f.graph, "attributed_target");
	target.attrs = {
		.computed = true,
		.readnone = true,
		.readonly = true,
		.will_return = true,
		.arg_nocapture = 1,
		.arg_noread = 1,
		.arg_nowrite = 1,
	};
	ir_opt::ipsccp(&f.graph, {
		.level = code_gen_options::OptimizationLevel.O2,
		.whole_program = false,
		.verify = true,
	});
	f.verify_graph();
	assert(!target.attrs.computed && !target.attrs.readnone && !target.attrs.readonly &&
		!target.attrs.will_return && target.attrs.arg_nocapture == 0 &&
		target.attrs.arg_noread == 0 && target.attrs.arg_nowrite == 0,
		"editing a specialized function must reset all computed function and argument attributes");
	f.free();
}

fn void sysv_aggregate_classification_picks_eightbyte_registers() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"struct DL { double d; long l; };\n"
		"struct DL mixed(struct DL a) { return a; }\n"
		// INTEGER beats X87 when they share an eightbyte (GCC merge order).
		"union UL { long double x; long l[2]; };\n"
		"union UL long_double_union(union UL u) { return u; }\n"
		// The second eightbyte is padding only (NO_CLASS): one XMM register.
		"struct N { float b; long double c[0]; };\n"
		"struct N padding_word(struct N n) { return n; }\n"
		// A pointer at offset 4 is not aligned to its size: memory.
		"typedef char *P4 __attribute__((aligned(4)));\n"
		"struct M { int c; P4 p; int d; };\n"
		"struct M misaligned(struct M m) { return m; }\n");
	f.verify_graph();
	String output = f.dump();
	assert(output.contains("f64 @mixed(f64 %0, i64 %1)"), "{double, long} is SSE + INTEGER");
	assert(output.contains("i64 @long_double_union(i64 %0, i64 %1)"), "a long double/integer union is INTEGER + INTEGER");
	assert(output.contains("f64 @padding_word(f64 %0)"), "a NO_CLASS eightbyte takes no register");
	assert(output.contains("ptr_ty @misaligned(ptr_ty %0, ptr_ty %1)"), "a misaligned pointer member sends the record to memory");
	alloc::free(&f.ta, output.ptr);
	f.free();
}

fn void o2_tail_recursion_with_add_accumulator_becomes_a_loop() @test
{
	OptFixture f;
	f.init();
	f.lower(
		"long sum_to(long n) { if (n == 0) return 0; return n + sum_to(n - 1); }\n"
		"unsigned fact(unsigned n) { return n <= 1 ? 1 : fact(n - 1) * n; }\n"
		"int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }\n");
	f.run_o2();
	f.verify_graph();
	ir::Decl* sum = find_function(&f.graph, "sum_to");
	assert(count_calls_to(sum, "sum_to") == 0, "`n + f(n - 1)` accumulates in a loop");
	assert(count_body_tag(sum, ir::InstTag.PHI) >= 2, "the parameter and the accumulator are loop PHIs");
	ir::Decl* fact = find_function(&f.graph, "fact");
	assert(count_calls_to(fact, "fact") == 0, "`f(n - 1) * n` accumulates a product in a loop");
	ir::Decl* fib = find_function(&f.graph, "fib");
	assert(count_calls_to(fib, "fib") == 1, "fib keeps one call (fib(n - 1)) and loops on fib(n - 2)");
	f.free();
}

fn void o2_tail_recursion_mixed_accumulators_are_left_alone() @test
{
	// `+` and `*` accumulating sites cannot share one accumulator.
	OptFixture f;
	f.init();
	f.lower("int mix(int n) { if (n < 2) return 1; if (n & 1) return n + mix(n - 1); return mix(n - 1) * 3; }\n");
	f.run_o2();
	f.verify_graph();
	assert(count_calls_to(find_function(&f.graph, "mix"), "mix") == 2, "both recursive calls stay");
	f.free();
}

// ---- nsw (no signed wrap), sext widening and loop strength reduction ----

fn uint count_body_nsw(ir::Decl* decl, ir::InstTag tag, value_interner::InternerRef ty, bool nsw)
{
	uint count = 0;
	foreach (ref : decl.body)
	{
		ir::Inst inst = decl.instructions[(sz)ref];
		if (inst.tag == tag && inst.ty == ty && inst.nsw == nsw) count++;
	}
	return count;
}

fn uint count_body_phi_type(ir::Decl* decl, value_interner::InternerRef ty)
{
	uint count = 0;
	foreach (ref : decl.body)
	{
		ir::Inst inst = decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.PHI && inst.ty == ty) count++;
	}
	return count;
}

fn void nsw_marks_only_signed_int_rank_arithmetic() @test
{
	OptFixture f;
	f.init();
	f.lower("int f(int a, int b, unsigned u, unsigned v, short s) {\n"
		"  s++;\n"
		"  int x = a * b + 3;\n"
		"  int y = (int)(u * v);\n"
		"  return x - y + s + -a;\n"
		"}");
	ir::Decl* decl = find_function(&f.graph, "f");
	assert(count_body_nsw(decl, ir::InstTag.MUL, value_interner::REF_I32, true) == 1, "signed int a * b is nsw");
	assert(count_body_nsw(decl, ir::InstTag.MUL, value_interner::REF_I32, false) == 1, "unsigned u * v wraps");
	assert(count_body_nsw(decl, ir::InstTag.ADD, value_interner::REF_I16, true) == 0,
		"short ++ narrows by conversion, so it is not nsw");
	// a*b+3, x-y, +s, -a (0 - a), + -a
	assert(count_body_nsw(decl, ir::InstTag.SUB, value_interner::REF_I32, true) == 2, "x - y and -a are nsw");
	assert(count_body_nsw(decl, ir::InstTag.ADD, value_interner::REF_I32, true) == 3, "signed int adds are nsw");
	f.verify_graph();
	f.free();
}

fn void nsw_is_off_under_fwrapv() @test
{
	OptFixture f;
	f.init();
	f.comp.langopts.wrapv = true;
	f.lower("int f(int a, int b) { return a * b + a - 1; }");
	ir::Decl* decl = find_function(&f.graph, "f");
	foreach (ref : decl.body) assert(!decl.instructions[(sz)ref].nsw, "-fwrapv arithmetic must not be nsw");
	f.free();
}

fn void verifier_rejects_nsw_on_non_arithmetic() @test
{
	OptFixture f;
	f.init();
	f.lower("int f(int a) { return a & 3; }");
	ir::Decl* decl = find_function(&f.graph, "f");
	foreach (ref : decl.body)
	{
		if (decl.instructions[(sz)ref].tag == ir::InstTag.BIT_AND) decl.instructions[(sz)ref].nsw = true;
	}
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(!ir_opt::verify(&f.graph, &errors), "nsw on BIT_AND must not verify");
	errors.free();
	f.free();
}

fn void instcombine_keeps_nsw_only_when_folded_constant_fits() @test
{
	OptFixture f;
	f.init();
	f.lower("int keep(int x) { return (x + 1) + 2; }\n"
		"int drop(int x) { return (x + 2147483647) + 1; }\n"
		"int sub_min(int x) { return x - (-2147483647 - 1); }");
	f.run_o1();
	ir::Decl* keep = find_function(&f.graph, "keep");
	assert(count_body_nsw(keep, ir::InstTag.ADD, value_interner::REF_I32, true) == 1 &&
		count_body_tag(keep, ir::InstTag.ADD) == 1, "x + 3 stays nsw");
	ir::Decl* drop = find_function(&f.graph, "drop");
	assert(count_body_tag(drop, ir::InstTag.ADD) == 1 &&
		count_body_nsw(drop, ir::InstTag.ADD, value_interner::REF_I32, false) == 1,
		"x + INT_MIN (folded from INT_MAX + 1) is not nsw");
	ir::Decl* sub_min = find_function(&f.graph, "sub_min");
	foreach (ref : sub_min.body) assert(!sub_min.instructions[(sz)ref].nsw, "x - INT_MIN as x + INT_MIN is not nsw");
	f.free();
}

fn void indvar_widen_and_lsr_reduce_matmul_inner_loop() @test
{
	OptFixture f;
	f.init();
	f.lower("void mm(int *a, int *b, int *c, int n) {\n"
		"  for (int i = 0; i < n; i++)\n"
		"    for (int j = 0; j < n; j++) {\n"
		"      int sum = 0;\n"
		"      for (int k = 0; k < n; k++) sum += a[i * n + k] * b[k * n + j];\n"
		"      c[i * n + j] = sum;\n"
		"    }\n"
		"}");
	f.run_o2();
	ir::Decl* decl = find_function(&f.graph, "mm");
	// Only `sum` stays a narrow PHI: i, j and k are i64 twins.
	assert(count_body_phi_type(decl, value_interner::REF_I32) == 1, "narrow IVs should be widened away");
	assert(count_body_phi_type(decl, value_interner::REF_PTR) >= 3, "a, b and c addresses should be pointer PHIs");
	// The single remaining sext is of the invariant `n`.
	assert(count_body_tag(decl, ir::InstTag.SEXT) == 1, "index sign extensions should be gone");
	// LFTR: the k loop exits on its pointer IV, so its i64 counter is gone.
	uint pointer_exits = 0;
	foreach (ref : decl.body)
	{
		ir::Inst inst = decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.CMP_NE && decl.instructions[(sz)inst.data.bin.lhs].ty == value_interner::REF_PTR) pointer_exits++;
	}
	assert(pointer_exits >= 1, "the inner loop should exit on a pointer compare");
	assert(count_body_phi_type(decl, value_interner::REF_I64) == 2, "only the i and j counters stay i64 PHIs");
	f.free();
}

fn void indvar_widen_keeps_wrapping_unsigned_index() @test
{
	OptFixture f;
	f.init();
	f.lower("int g(int *a, unsigned u, int n) {\n"
		"  int s = 0;\n"
		"  for (int i = 0; i < n; i++) s += a[(int)(u * (unsigned)i)];\n"
		"  return s;\n"
		"}");
	f.run_o2();
	ir::Decl* decl = find_function(&f.graph, "g");
	// The index is wrapping unsigned arithmetic converted to int: its sext must stay.
	assert(count_body_nsw(decl, ir::InstTag.MUL, value_interner::REF_I32, false) == 1, "u * i stays i32 wrapping");
	assert(count_body_tag(decl, ir::InstTag.SEXT) >= 1, "the sext of the wrapped index must stay");
	f.free();
}

// ---- loop vectorizer ----

fn ir::Decl* lower_o2(OptFixture* f, String source, String name, bool no_vectorize = false)
{
	f.lower(source);
	ir::ErrorList errors;
	errors.init(&f.ta);
	fault fail = @catch(ir_opt::run(&f.graph, {
		.level = code_gen_options::OptimizationLevel.O2,
		.verify = true,
		.no_vectorize = no_vectorize,
	}, &errors));
	assert(!fail, "ir_opt::run failed: %s", errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	errors.free();
	return find_function(&f.graph, name);
}

fn uint count_vector_values(ir::Ir* graph, ir::Decl* decl)
{
	uint count = 0;
	foreach (ref : decl.body) if (graph.is_vector(decl.instructions[(sz)ref].ty)) count++;
	return count;
}

fn void loop_vectorize_int_sum_reduction() @test
{
	OptFixture f;
	f.init();
	ir::Decl* decl = lower_o2(&f, "int sum(const int *a, int n) { int s = 0; for (int i = 0; i < n; i++) s += a[i]; return s; }", "sum");
	assert(count_body_tag(decl, ir::InstTag.VREDUCE_ADD) == 1, "the sum should be reduced once after the vector loop");
	assert(count_vector_values(&f.graph, decl) >= 3, "vector load, accumulator PHI and add");
	// No stores, so no overlap checks.
	assert(count_body_tag(decl, ir::InstTag.CMP_ULT) == 0, "a pure reduction needs no runtime alias check");
	f.free();
}

fn void loop_vectorize_map_checks_overlap() @test
{
	OptFixture f;
	f.init();
	ir::Decl* decl = lower_o2(&f, "void add(int *c, const int *a, const int *b, int n) { for (int i = 0; i < n; i++) c[i] = a[i] + b[i]; }", "add");
	assert(count_vector_values(&f.graph, decl) >= 3, "the map should be vectorized");
	assert(count_body_tag(decl, ir::InstTag.CMP_ULT) == 4, "c is checked against a and b (two compares each)");
	f.free();
}

fn void loop_vectorize_respects_no_vectorize() @test
{
	OptFixture f;
	f.init();
	ir::Decl* decl = lower_o2(&f, "int sum(const int *a, int n) { int s = 0; for (int i = 0; i < n; i++) s += a[i]; return s; }", "sum", true);
	assert(count_vector_values(&f.graph, decl) == 0, "-fno-tree-vectorize keeps the loop scalar");
	f.free();
}

fn void loop_vectorize_rejects_float_reduction_and_iv_values() @test
{
	OptFixture f;
	f.init();
	f.lower("double fsum(const double *a, int n) { double s = 0; for (int i = 0; i < n; i++) s += a[i]; return s; }\n"
		"void iota(int *a, int n) { for (int i = 0; i < n; i++) a[i] = i; }\n"
		"void gather(int *a, const int *idx, const int *b, int n) { for (int i = 0; i < n; i++) a[i] = b[idx[i]]; }\n"
		"void vol(volatile int *a, int n) { for (int i = 0; i < n; i++) a[i] = 1; }");
	f.run_o2();
	foreach (name : (String[]){ "fsum", "iota", "gather", "vol" })
	{
		ir::Decl* decl = find_function(&f.graph, name);
		assert(count_vector_values(&f.graph, decl) == 0, "%s must stay scalar", name);
	}
	f.free();
}
