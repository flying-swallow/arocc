// This target depends only on //ir.c3l:core: frontend/backend dependencies cannot hide here.
module ir_core_tests;
import std, aro::backend::ir, aro::value_interner, aro::primitive_value;

fn void standalone_builder_owns_finished_function() @test
{
	TrackingAllocator allocator;
	allocator.init(mem);
	Interner interner;
	interner.init(&allocator);
	Builder builder;
	builder.init(&allocator, &interner);
	builder.start_fn();
	Ref input = builder.add_arg(value_interner::REF_I32);
	Ref one = builder.add_constant(interner.put(primitive_value::int_key(1)), value_interner::REF_I32);
	Ref sum = builder.add_inst(ADD, { .bin = { input, one } }, value_interner::REF_I32);
	builder.add_return(sum);
	builder.finish_fn("increment");
	Ir graph = builder.finish();
	builder.free();
	assert(graph.decls.len() == 1);
	Decl* decl = &graph.decls.array_view()[0];
	assert(decl.name == "increment");
	assert(decl.instructions[(sz)sum].data.bin.lhs == input);
	assert(decl.instructions[(sz)sum].data.bin.rhs == one);
	assert(decl.instructions[(sz)decl.body[decl.body.len - 1]].data.ref == sum);
	graph.free();
	interner.free();
	assert(allocator.allocation_count() == 0);
	allocator.free();
}
