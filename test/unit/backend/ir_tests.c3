// Tests for the concrete C3 IR builder in src/backend/ir.c3.
// Builder expectations follow the source-derived Zig IR builder: refs are
// instruction indexes, arguments precede the entry label in the body, and
// finish_fn transfers the current arena to the declaration.
module ir_tests;
import std, aro::backend::ir, aro::backend::ir_opt, aro::backend::object, aro::target, aro::value_interner;
import aro::diagnostics, std::core::dstring;

macro check(left, right)
{
	$if $defined((long)left):
		test::eq((long)left, (long)right);
	$else
		test::eq(left, right);
	$endif
}

struct Fixture
{
	TrackingAllocator ta;
	Interner interner;
	Ir graph;
	Builder builder;
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
	check(self.ta.allocation_count(), 0);
	self.ta.free();
}

fn void builder_transfers_blocks_and_owned_inputs() @test
{
	Fixture f;
	f.init();
	Builder* b = &f.builder;

	b.start_fn();
	Ref cond = b.add_arg(value_interner::REF_I1);
	Ref callee = b.add_symbol("callee", value_interner::REF_FUNC);
	Ref[1] call_args = { cond };
	Ref call = b.add_call(callee, call_args[..], value_interner::REF_I32);
	// The call payload also owns the argument slice supplied by its caller.
	call_args[0] = ir::NONE;
	Ref then_label = b.make_label("then");
	Ref else_label = b.make_label("else");
	Ref join_label = b.make_label("join");
	b.add_branch(cond, then_label, else_label);

	b.start_block(then_label);
	Ref then_value = b.add_constant(f.interner.put(value_interner::int_key(11)), value_interner::REF_I32);
	b.add_jump(join_label);

	b.start_block(else_label);
	Ref else_value = b.add_constant(f.interner.put(value_interner::int_key(22)), value_interner::REF_I32);
	b.add_jump(join_label);

	b.start_block(join_label);
	PhiInput[2] inputs = {
		{ .label = then_label, .value = then_value },
		{ .label = else_label, .value = else_value },
	};
	Ref phi = b.add_phi(inputs[..], value_interner::REF_I32);
	b.add_return(phi);
	// Mutating the caller's array must not change the builder's arena copy.
	inputs[0] = { .label = else_label, .value = else_value };
	b.finish_fn("choose");

	// The completed IR takes ownership of both declarations and their arenas.
	b.start_fn();
	Ref second_arg = b.add_arg(value_interner::REF_I32);
	b.add_return(second_arg);
	b.finish_fn("identity");

	b.start_fn();
	Ref alloc_arg0 = b.add_arg(value_interner::REF_I32);
	Ref alloc_arg1 = b.add_arg(value_interner::REF_I64);
	Ref alloc0 = b.add_alloc(8, 8);
	Ref alloc1 = b.add_alloc(16, 16);
	b.add_return(alloc_arg1);
	b.finish_fn("alloc_order");

	b.start_fn();
	Ref switch_target = b.add_arg(value_interner::REF_I32);
	Ref case_label = b.make_label("case");
	Ref default_label = b.make_label("default");
	value_interner::InternerRef[1] switch_values = { value_interner::REF_ONE };
	Ref[1] switch_labels = { case_label };
	Ref switch_inst = (Ref)b.instructions.len();
	b.add_switch(switch_target, switch_values[..], switch_labels[..], default_label);
	b.start_block(case_label);
	b.add_return(switch_target);
	b.start_block(default_label);
	b.add_return(switch_target);
	switch_values[0] = value_interner::REF_ZERO;
	switch_labels[0] = default_label;
	b.finish_fn("switcher");

	f.graph = b.finish();

	check(f.graph.decls.len(), 4);
	test::eq(f.graph.decls[0].name, "choose");
	test::eq(f.graph.decls[1].name, "identity");
	test::eq(f.graph.decls[2].name, "alloc_order");
	test::eq(f.graph.decls[3].name, "switcher");
	foreach (decl : f.graph.decls)
	{
		if (decl.name != "choose") continue;
		test::eq(decl.name, "choose");
		check(decl.instructions.len, 14);
		check(decl.body.len, 11);
		check(decl.instructions[(sz)cond].tag, InstTag.ARG);
		check(decl.instructions[(sz)cond].ty, value_interner::REF_I1);
		check(decl.instructions[(sz)callee].tag, InstTag.SYMBOL);
		check(decl.instructions[(sz)call].tag, InstTag.CALL);
		check(decl.instructions[(sz)call].data.call.func, callee);
		check(decl.instructions[(sz)call].data.call.args.len, 1);
		check(decl.instructions[(sz)call].data.call.args[0], cond);
		check(decl.instructions[(sz)then_label].data.label, "then");
		check(decl.instructions[(sz)else_label].data.label, "else");
		check(decl.instructions[(sz)join_label].data.label, "join");
		check(decl.instructions[(sz)phi].tag, InstTag.PHI);
		check(decl.instructions[(sz)phi].data.phi.len, 2);
		check(decl.instructions[(sz)phi].data.phi[0].label, then_label);
		check(decl.instructions[(sz)phi].data.phi[0].value, then_value);
		check(decl.instructions[(sz)phi].data.phi[1].label, else_label);
		check(decl.instructions[(sz)phi].data.phi[1].value, else_value);
		check(decl.instructions[(sz)decl.body[0]].tag, InstTag.ARG);
		check(decl.body[1], 0); // entry label follows arguments
		check(decl.instructions[(sz)decl.body[1]].data.label, "entry");
		check(decl.instructions[(sz)decl.body[3]].tag, InstTag.BRANCH);
		check(decl.instructions[(sz)decl.body[3]].data.branch.then_label, then_label);
		check(decl.instructions[(sz)decl.body[3]].data.branch.else_label, else_label);
		check(decl.instructions[(sz)decl.body[decl.body.len - 1]].tag, InstTag.RET);
	}
	Decl* identity = &f.graph.decls[1];
	check(identity.instructions[1].tag, InstTag.ARG);
	check(identity.instructions[1].ty, value_interner::REF_I32);
	check(identity.body[0], 1);
	check(identity.instructions[(sz)identity.body[0]].tag, InstTag.ARG);
	check(identity.body[1], 0); // entry label follows arguments
	Decl* alloc_decl = &f.graph.decls[2];
	check(alloc_decl.instructions.len, 6);
	check(alloc_decl.body.len, 6);
	check(alloc_decl.instructions[(sz)alloc_arg0].tag, InstTag.ARG);
	check(alloc_decl.instructions[(sz)alloc_arg0].ty, value_interner::REF_I32);
	check(alloc_decl.instructions[(sz)alloc_arg1].tag, InstTag.ARG);
	check(alloc_decl.instructions[(sz)alloc_arg1].ty, value_interner::REF_I64);
	check(alloc_decl.body[0], alloc_arg0);
	check(alloc_decl.body[1], alloc_arg1);
	check(alloc_decl.instructions[(sz)alloc_decl.body[0]].tag, InstTag.ARG);
	check(alloc_decl.instructions[(sz)alloc_decl.body[1]].tag, InstTag.ARG);
	check(alloc_decl.body[2], 0); // entry label follows arguments
	check(alloc_decl.body[3], alloc0);
	check(alloc_decl.body[4], alloc1);
	check(alloc_decl.instructions[(sz)alloc0].data.alloc.size, 8);
	check(alloc_decl.instructions[(sz)alloc0].data.alloc.align, 8);
	check(alloc_decl.instructions[(sz)alloc1].data.alloc.size, 16);
	check(alloc_decl.instructions[(sz)alloc1].data.alloc.align, 16);
	Decl* switch_decl = &f.graph.decls[3];
	check(switch_decl.instructions[(sz)switch_inst].tag, InstTag.SWITCH);
	check(switch_decl.instructions[(sz)switch_inst].data.switch_data.values[0], value_interner::REF_ONE);
	check(switch_decl.instructions[(sz)switch_inst].data.switch_data.labels[0], case_label);
	check(switch_decl.instructions[(sz)switch_inst].data.switch_data.default_label, default_label);
	// Source-derived from src/backend/Ir.zig dumpDecl and its write helpers.
	DString output;
	output.init(&f.ta);
	Terminal term = { .writer = &output, .mode = diagnostics::ColorMode.NO_COLOR };
	f.graph.dump(term)!!;
	check(output.str_view(),
		"i32 @choose(i1 %0) {\n"
		"entry.0:\n"
		"    i32 %1 = call func_ty @callee(i1 %0)\n"
		"    branch i1 %0, then.1, else.2\n"
		"then.1:\n"
		"    jmp join.3\n"
		"else.2:\n"
		"    jmp join.3\n"
		"join.3:\n"
		"    i32 %2 = phi {\n"
		"        then.1 => i32 11\n"
		"        else.2 => i32 22\n"
		"    }\n"
		"    ret i32 %2\n"
		"}\n\n"
		"i32 @identity(i32 %0) {\n"
		"entry.0:\n"
		"    ret i32 %0\n"
		"}\n\n"
		"i64 @alloc_order(i32 %0, i64 %1) {\n"
		"entry.0:\n"
		"    ptr_ty %2 = alloc size 8 align 8\n"
		"    ptr_ty %3 = alloc size 16 align 16\n"
		"    ret i64 %1\n"
		"}\n\n"
		"i32 @switcher(i32 %0) {\n"
		"entry.0:\n"
		"    switch i32 %0 {\n"
		"        1 => case.1\n"
		"        default => default.2\n"
		"    }\n"
		"case.1:\n"
		"    ret i32 %0\n"
		"default.2:\n"
		"    ret i32 %0\n"
		"}\n\n");
	output.free();
	f.free();
}

const target::Host HOST = { target::Arch.X86_64, target::OsTag.LINUX, target::Abi.GNU };

fn target::Target renderer_target()
{
	target::Target? parsed = target::parse_triple("x86_64-linux-gnu", HOST);
	if (catch err = parsed) unreachable("renderer test target must parse");
	return parsed;
}

fn void builder_merges_function_and_global_declarations() @test
{
	Fixture f;
	f.init();
	Builder* b = &f.builder;

	// Function declarations default to external linkage and yield to definitions.
	char[8] function_name = { 'm', 'e', 'r', 'g', 'e', '_', 'f', 'n' };
	b.finish_fn((String)function_name[..]);
	function_name[0] = 'X';
	check(b.decls.len(), 1);
	check(b.decls[0].kind, DeclKind.FUNCTION);
	check(b.decls[0].linkage, ir::Linkage.EXTERNAL);
	check(b.decls[0].is_definition(), true);
	test::eq(b.decls[0].name, "merge_fn");
	b.start_fn();
	Ref fn_arg = b.add_arg(value_interner::REF_I32);
	b.add_return(fn_arg);
	b.finish_fn("merge_fn", ir::Linkage.INTERNAL);
	check(b.decls.len(), 1);
	check(b.decls[0].is_definition(), true);
	check(b.decls[0].linkage, ir::Linkage.INTERNAL);

	// A later function definition replaces the previous body while retaining
	// internal linkage; a subsequent declaration does not discard that body.
	b.start_fn();
	b.add_return(ir::NONE);
	b.finish_fn("merge_fn", ir::Linkage.EXTERNAL);
	check(b.decls.len(), 1);
	check(b.decls[0].body.len, 2);
	check(b.decls[0].linkage, ir::Linkage.INTERNAL);
	b.finish_fn("merge_fn");
	check(b.decls.len(), 1);
	check(b.decls[0].is_definition(), true);
	check(b.decls[0].linkage, ir::Linkage.INTERNAL);

	char[6] global_name = { 'g', 'l', 'o', 'b', 'a', 'l' };
	char[4] bytes = { 1, 2, 3, 4 };
	char[6] reloc_name = { 't', 'a', 'r', 'g', 'e', 't' };
	DataReloc[1] relocs = {
		{ .offset = 1, .symbol = (String)reloc_name[..], .addend = -4 },
	};
	GlobalData declaration = { .size = 4, .align = 4, .section = DataSection.EXTERN };
	b.add_global((String)global_name[..], ir::Linkage.EXTERNAL, declaration);
	check(b.decls.len(), 2);
	check(b.decls[1].is_definition(), false);
	check(b.decls[1].global.section, DataSection.EXTERN);
	GlobalData definition = {
		.size = 4,
		.align = 4,
		.bytes = bytes[..],
		.relocs = relocs[..],
		.section = DataSection.DATA,
		.own_section = true,
	};
	b.add_global((String)global_name[..], ir::Linkage.EXTERNAL, definition);
	global_name[0] = 'X';
	bytes[0] = 99;
	reloc_name[0] = 'X';
	b.add_global("global", ir::Linkage.EXTERNAL, declaration);
	check(b.decls.len(), 2);
	Decl* global = &b.decls[1];
	check(global.kind, DeclKind.GLOBAL);
	check(global.linkage, ir::Linkage.EXTERNAL);
	check(global.is_definition(), true);
	test::eq(global.name, "global");
	check(global.global.section, DataSection.DATA);
	check(global.global.tentative, false);
	check(global.global.own_section, true);
	check(global.global.bytes.len, 4);
	check(global.global.bytes[0], 1);
	check(global.global.relocs.len, 1);
	check(global.global.relocs[0].offset, 1);
	test::eq(global.global.relocs[0].symbol, "target");
	check(global.global.relocs[0].addend, -4);

	// Tentative definitions merge into one entry, an internal linkage wins,
	// and a strong definition replaces the tentative data.
	char[9] tentative_name = { 't', 'e', 'n', 't', 'a', 't', 'i', 'v', 'e' };
	GlobalData tentative_first = {
		.size = 4,
		.align = 4,
		.section = DataSection.COMMON,
		.tentative = true,
	};
	GlobalData tentative_second = {
		.size = 8,
		.align = 8,
		.section = DataSection.COMMON,
		.tentative = true,
	};
	b.add_global((String)tentative_name[..], ir::Linkage.EXTERNAL, tentative_first);
	b.add_global((String)tentative_name[..], ir::Linkage.INTERNAL, tentative_second);
	check(b.decls.len(), 3);
	Decl* tentative = &b.decls[2];
	check(tentative.global.size, 4);
	check(tentative.global.tentative, true);
	check(tentative.is_definition(), true);
	check(tentative.linkage, ir::Linkage.INTERNAL);

	char[4] tentative_bytes = { 5, 6, 7, 8 };
	GlobalData strong_definition = {
		.size = 4,
		.align = 4,
		.bytes = tentative_bytes[..],
		.section = DataSection.DATA,
	};
	b.add_global((String)tentative_name[..], ir::Linkage.EXTERNAL, strong_definition);
	b.add_global((String)tentative_name[..], ir::Linkage.EXTERNAL, declaration);
	check(b.decls.len(), 3);
	check(tentative.global.section, DataSection.DATA);
	check(tentative.global.tentative, false);
	check(tentative.global.bytes[0], 5);
	check(tentative.linkage, ir::Linkage.INTERNAL);

	// Adding a global leaves a function currently being built, including its
	// arena-owned symbol name, untouched.
	b.start_fn();
	Ref pending_symbol = b.add_symbol("pending_symbol", value_interner::REF_FUNC);
	uint instructions_len = (uint)b.instructions.len();
	uint body_len = (uint)b.body.len();
	GlobalData state_probe = { .size = 1, .align = 1, .section = DataSection.BSS };
	b.add_global("state_probe", ir::Linkage.INTERNAL, state_probe);
	check(b.instructions.len(), instructions_len);
	check(b.body.len(), body_len);
	test::eq(b.instructions[(sz)pending_symbol].data.label, "pending_symbol");
	b.finish_fn("pending_function");

	f.free();
}

struct ObjectBuffer (OutStream)
{
	ByteWriter bytes;
}

fn void ObjectBuffer.init(&self) { self.bytes.init(mem); }
fn sz? ObjectBuffer.write(&self, char[] data) @dynamic => self.bytes.write(data);
fn void? ObjectBuffer.write_byte(&self, char byte) @dynamic => self.bytes.write_byte(byte);
fn void? ObjectBuffer.flush(&self) @dynamic {}
fn void ObjectBuffer.free(&self) { (void)self.bytes.destroy(); }

fn void empty_ir_renders_byte_identical_empty_object() @test
{
	Fixture f;
	f.init();
	f.graph = f.builder.finish();
	assert(f.graph.decls.len() == 0, "empty fixture should contain no declarations");

	ir::ErrorList errors;
	errors.init(&f.ta);
	object::Object* rendered = ir::render(&f.graph, &f.ta, renderer_target(), &errors)!!;
	assert(errors.len() == 0, "empty IR rendering should have no declaration failures");
	object::Object* expected = object::create(&f.ta, renderer_target())!!;

	ObjectBuffer rendered_bytes;
	rendered_bytes.init();
	ObjectBuffer expected_bytes;
	expected_bytes.init();
	object::finish(rendered, &rendered_bytes)!!;
	object::finish(expected, &expected_bytes)!!;
	test::eq(rendered_bytes.bytes.str_view(), expected_bytes.bytes.str_view());

	expected_bytes.free();
	rendered_bytes.free();
	expected.deinit();
	rendered.deinit();
	errors.free();
	f.free();
}

fn void renderer_records_every_decl_failure_in_order() @test
{
	Fixture f;
	f.init();
	f.builder.start_fn();
	Ref first = f.builder.add_arg(value_interner::REF_I32);
	f.builder.add_return(first);
	f.builder.finish_fn("a");
	f.builder.start_fn();
	Ref second = f.builder.add_arg(value_interner::REF_I32);
	f.builder.add_return(second);
	f.builder.finish_fn("b");
	f.graph = f.builder.finish();

	ir::ErrorList errors;
	errors.init(&f.ta);
	object::Object*? result = ir::render(&f.graph, &f.ta, renderer_target(), &errors);
	fault render_fault = @catch(result);
	assert(render_fault == ir::LOWER_FAIL, "rendering declarations should report LOWER_FAIL");
	check(errors.len(), 2);
	test::eq(errors.name_at(0), "a");
	test::eq(errors.message_at(0), "TODO implement lowering functions");
	test::eq(errors.name_at(1), "b");
	test::eq(errors.message_at(1), "TODO implement lowering functions");
	errors.free();
	f.free();
}

fn void renderer_fail_replaces_duplicate_name_in_place() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	ir::ErrorList errors;
	errors.init(&ta);
	ir::Renderer renderer = { .gpa = &ta, .errors = errors };
	fault first = @catch(renderer.fail("first", "first failure"));
	fault duplicate = @catch(renderer.fail("duplicate", "old failure"));
	fault third = @catch(renderer.fail("third", "third failure"));
	fault replaced = @catch(renderer.fail("duplicate", "TODO implement lowering functions"));
	assert(first == ir::LOWER_FAIL && duplicate == ir::LOWER_FAIL && third == ir::LOWER_FAIL && replaced == ir::LOWER_FAIL,
		"Renderer.fail should report LOWER_FAIL for each declaration");
	check(renderer.errors.len(), 3);
	test::eq(renderer.errors.name_at(0), "first");
	test::eq(renderer.errors.name_at(1), "duplicate");
	test::eq(renderer.errors.name_at(2), "third");
	test::eq(renderer.errors.message_at(1), "TODO implement lowering functions");
	renderer.errors.free();
	assert(ta.allocation_count() == 0, "renderer failure replacement leaked allocator-owned messages");
	ta.free();
}

fn void builder_materializes_fallthrough_and_skips_terminators() @test
{
	Fixture f;
	f.init();
	Builder* b = &f.builder;
	Ref open_label = b.make_label("open");
	Ref jump_probe = b.make_label("jump_probe");
	Ref branch_probe = b.make_label("branch_probe");
	Ref switch_probe = b.make_label("switch_probe");
	Ref return_probe = b.make_label("return_probe");
	Ref final_label = b.make_label("final");

	b.start_fn();
	Ref cond = b.add_arg(value_interner::REF_I1);
	Ref value = b.add_arg(value_interner::REF_I32);
	Ref target = b.add_arg(value_interner::REF_I32);
	Ref entry_label = b.current_label;
	uint entry_body_len = (uint)b.body.len();
	check(entry_body_len, 4);
	check(b.body[(sz)(entry_body_len - 1)], entry_label);
	b.start_block(open_label);
	check(b.body.len(), entry_body_len + 2);
	Ref entry_fallthrough = b.body[(sz)entry_body_len];
	check(b.instructions[(sz)entry_fallthrough].tag, ir::InstTag.JMP);
	check(b.instructions[(sz)entry_fallthrough].data.ref, open_label);
	check(b.body[(sz)entry_body_len + 1], open_label);

	b.add_inst(ir::InstTag.NEGATE, { .ref = value }, value_interner::REF_I32);
	uint open_body_len = (uint)b.body.len();
	b.start_block(jump_probe);
	check(b.body.len(), open_body_len + 2);
	Ref open_fallthrough = b.body[(sz)open_body_len];
	check(b.instructions[(sz)open_fallthrough].tag, ir::InstTag.JMP);
	check(b.instructions[(sz)open_fallthrough].data.ref, jump_probe);
	check(b.body[(sz)open_body_len + 1], jump_probe);

	// Each add_* call below follows an existing terminator and must be skipped.
	b.add_return(value);
	check(b.instructions[(sz)b.body[(sz)b.body.len() - 1]].tag, ir::InstTag.RET);
	uint after_return = (uint)b.body.len();
	b.add_jump(branch_probe);
	check(b.body.len(), after_return);
	uint before_branch_probe = (uint)b.body.len();
	b.start_block(branch_probe);
	check(b.body.len(), before_branch_probe + 1);

	b.add_jump(switch_probe);
	check(b.instructions[(sz)b.body[(sz)b.body.len() - 1]].tag, ir::InstTag.JMP);
	uint after_jump = (uint)b.body.len();
	b.add_branch(cond, switch_probe, switch_probe);
	check(b.body.len(), after_jump);
	uint before_switch_probe = (uint)b.body.len();
	b.start_block(switch_probe);
	check(b.body.len(), before_switch_probe + 1);

	b.add_branch(cond, return_probe, return_probe);
	check(b.instructions[(sz)b.body[(sz)b.body.len() - 1]].tag, ir::InstTag.BRANCH);
	value_interner::InternerRef[1] switch_values = { value_interner::REF_ONE };
	Ref[1] return_labels = { return_probe };
	uint after_branch = (uint)b.body.len();
	b.add_switch(target, switch_values[..], return_labels[..], return_probe);
	check(b.body.len(), after_branch);
	uint before_return_probe = (uint)b.body.len();
	b.start_block(return_probe);
	check(b.body.len(), before_return_probe + 1);

	Ref[1] final_labels = { final_label };
	b.add_switch(target, switch_values[..], final_labels[..], final_label);
	check(b.instructions[(sz)b.body[(sz)b.body.len() - 1]].tag, ir::InstTag.SWITCH);
	uint after_switch = (uint)b.body.len();
	b.add_return(value);
	check(b.body.len(), after_switch);
	uint before_final = (uint)b.body.len();
	b.start_block(final_label);
	check(b.body.len(), before_final + 1);
	b.add_return(value);

	// The entry block contains only its label after the ARG prefix. The verifier
	// checks every block has one final terminator and no instruction follows it.
	b.finish_fn("builder_blocks");
	f.graph = b.finish();
	ir::ErrorList errors;
	errors.init(&f.ta);
	assert(ir_opt::verify(&f.graph, &errors), "builder block contract failed verification: %s",
		errors.len() == 0 ? "no verifier message" : errors.message_at(0));
	check(errors.len(), 0);
	errors.free();
	f.free();
}
