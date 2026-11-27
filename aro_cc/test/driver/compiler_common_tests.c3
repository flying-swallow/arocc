module compiler_common_tests;
import aro::compiler::reporting;

fn void collector_owns_borrowed_tooling_reports() @test
{
	TrackingAllocator allocator;
	allocator.init(mem);
	Collector collector;
	collector.init(&allocator);
	@pool()
	{
		collector.tooling_sink().emit(ERROR, string::tformat("missing %s", "linker"), "fuse-ld-path")!!;
	};
	assert(collector.errors == 1);
	assert(collector.messages.len() == 1);
	assert(collector.messages[0].text == "missing linker");
	assert(collector.messages[0].option == "fuse-ld-path");
	collector.free();
	assert(allocator.allocation_count() == 0);
	allocator.free();
}

excuse REPORT_FAILED;
fn void? fail_report(void* context, Severity severity, String text, String option) => REPORT_FAILED~;

fn void sinks_discard_when_empty_and_propagate_receiver_failures() @test
{
	Sink empty = {};
	empty.emit(ERROR, "discarded")!!;
	Sink failing = { .report = &fail_report };
	assert(@catch(failing.emit(ERROR, "reported")) == REPORT_FAILED);
}
