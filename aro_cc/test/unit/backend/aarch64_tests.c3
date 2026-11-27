module aarch64_tests;
import std, aro::backend::ir, aro::backend::ir_opt, aro::target, aro::value_interner;

const target::Host HOST = { target::Arch.AARCH64, target::OsTag.MACOS, target::Abi.NONE };

fn target::Target darwin_target() => target::parse_triple("aarch64-macos-none", HOST)!!;

fn void darwin_stack_arguments_and_large_frames_verify() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	value_interner::Interner interner;
	interner.init(&ta);
	defer interner.free();
	ir::Builder builder;
	builder.init(&ta, &interner);
	defer builder.free();
	builder.start_fn();
	ir::Ref byte = builder.add_arg_at(value_interner::REF_I8, GP_REGISTER, 7, 0);
	ir::Ref packed = builder.add_arg_at(value_interner::REF_I16, STACK, 2, 2);
	builder.add_alloc(20000, 16);
	ir::Ref result = builder.add_inst(SEXT, { .ref = byte }, value_interner::REF_I64);
	builder.add_return(result);
	builder.finish_fn("packed");
	builder.find_decl("packed").darwin = true;
	ir::Ir graph = builder.finish();
	defer graph.free();
	ir::ErrorList errors;
	errors.init(&ta);
	defer errors.free();
	assert(ir_opt::verify(&graph, &errors));
	String text = ir::render_asm(&graph, &ta, darwin_target(), &errors)!!;
	defer alloc::free(&ta, text.ptr);
	assert(text.contains(".build_version macos") && text.contains("_packed"));
	assert(text.contains("ldrh w9, [x9]") && text.contains("str xzr, [sp]"));
	assert(!text.contains("x18"));
	// The same packed slot and GP register index are invalid for SysV.
	graph.decls.entries[0].darwin = false;
	assert(!ir_opt::verify(&graph, &errors));
}

fn void darwin_call_metadata_is_verified_and_preserved_by_compaction() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	value_interner::Interner interner;
	interner.init(&ta);
	defer interner.free();
	ir::Builder builder;
	builder.init(&ta, &interner);
	defer builder.free();
	builder.start_fn();
	ir::Ref buffer = builder.add_alloc(32, 8);
	ir::Ref callee = builder.add_symbol("four_doubles", value_interner::REF_PTR);
	ir::Ref call = builder.add_call(callee, { buffer }, value_interner::REF_VOID);
	builder.instructions[(sz)call].data.call.darwin = true;
	ir::ArgData[] locations = alloc::new_array(&builder.arena, ir::ArgData, 1);
	locations[0] = { .location_kind = GP_REGISTER, .location = 8 };
	builder.instructions[(sz)call].data.call.locations = locations;
	builder.instructions[(sz)call].data.call.result = { .size = 32, .hfa_bits = 64, .hfa_count = 4 };
	builder.add_return(ir::NONE);
	builder.finish_fn("caller");
	builder.find_decl("caller").darwin = true;
	ir::Ir graph = builder.finish();
	defer graph.free();
	ir::ErrorList errors;
	errors.init(&ta);
	defer errors.free();
	assert(ir_opt::verify(&graph, &errors));
	ir_opt::compact(&graph);
	assert(ir_opt::verify(&graph, &errors));
	String text = ir::render_asm(&graph, &ta, darwin_target(), &errors)!!;
	defer alloc::free(&ta, text.ptr);
	assert(text.contains("str d3, [x14, #24]"));
	foreach (&inst : graph.decls.entries[0].instructions)
	{
		if (inst.tag != CALL) continue;
		inst.data.call.locations[0].location = 9;
	}
	assert(!ir_opt::verify(&graph, &errors));
}

fn void arm64_integrated_object_output_reports_an_actionable_error() @test
{
	value_interner::Interner interner;
	interner.init(mem);
	defer interner.free();
	ir::Builder builder;
	builder.init(mem, &interner);
	defer builder.free();
	ir::Ir graph = builder.finish();
	defer graph.free();
	ir::ErrorList errors;
	errors.init(mem);
	defer errors.free();
	assert(@catch(ir::render_object(&graph, mem, darwin_target(), &errors)) == ir::LOWER_FAIL);
	assert(errors.message_at(0).contains("-fno-integrated-as"));
}

fn void darwin_aggregate_shapes_reject_invalid_hfas() @test
{
	ir::DarwinAggregate hfa = { .size = 32, .hfa_bits = 64, .hfa_count = 4 };
	assert(hfa.valid() && !hfa.indirect());
	hfa.hfa_count = 5;
	assert(!hfa.valid());
	ir::DarwinAggregate large = { .size = 40 };
	assert(large.valid() && large.indirect());
}
