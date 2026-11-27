// Build and verify increment(i32) without importing a language frontend.
module ir_increment;
import aro::backend::ir, aro::backend::ir_opt, aro::value_interner, aro::primitive_value, std::io;

fn void main()
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
	Ref result = builder.add_inst(ADD, { .bin = { input, one } }, value_interner::REF_I32);
	builder.add_return(result);
	builder.finish_fn("increment");
	Ir graph = builder.finish();
	builder.free();

	ErrorList errors;
	errors.init(&allocator);
	assert(ir_opt::verify(&graph, &errors), "increment failed verification");
	ir_opt::run(&graph, { .level = O1, .verify = true }, &errors)!!;
	assert(errors.len() == 0, "optimizer reported errors");
	io::printn("Built, verified, and optimized increment(i32)");
	errors.free();
	graph.free();
	interner.free();
	assert(allocator.allocation_count() == 0, "IR example leaked allocations");
	allocator.free();
}
