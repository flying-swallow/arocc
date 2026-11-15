module profiling_tests;
import aro::tracy;
import std::core::mem::allocators;
import std::core::mem;

extern fn void tracy_test_reset();
extern fn uint tracy_test_event_count();
extern fn int tracy_test_event_at(uint index);
extern fn bool tracy_test_zone_source_ok();
extern fn bool tracy_test_zone_args_ok();
extern fn bool tracy_test_message_args_ok();
extern fn bool tracy_test_memory_args_ok();
extern fn void tracy_test_expect_callstack(int depth);
extern fn bool tracy_test_abi_sizes_ok();

const int ZONE_BEGIN = 1;
const int ZONE_BEGIN_CALLSTACK = 2;
const int ZONE_TEXT = 3;
const int ZONE_NAME = 4;
const int ZONE_COLOR = 5;
const int ZONE_VALUE = 6;
const int ZONE_END = 7;
const int ALLOC = 8;
const int ALLOC_CALLSTACK = 9;
const int FREE = 10;
const int FREE_CALLSTACK = 11;
const int ALLOC_NAMED = 12;
const int ALLOC_CALLSTACK_NAMED = 13;
const int FREE_NAMED = 14;
const int FREE_CALLSTACK_NAMED = 15;
const int MESSAGE = 16;
const int MESSAGE_L = 17;
const int MESSAGE_C = 18;
const int MESSAGE_LC = 19;
const int FRAME = 20;
const int FRAME_START = 21;
const int FRAME_END = 22;

fn void zones_messages_and_frames_follow_feature_mode() @test
{
	tracy_test_reset();
	$if $feat(TRACY_CALLSTACK): tracy_test_expect_callstack(10); $else tracy_test_expect_callstack(0); $endif
	tracy::Ctx zone = tracy::trace("worker", "worker.c3", 73);
	zone.add_text("payload");
	zone.set_name("named zone");
	zone.set_color(0x123456);
	zone.set_value(0x1122334455667788);
	zone.end();
	tracy::Ctx named = tracy::trace_named("worker", "worker.c3", 74, "named");
	named.end();
	tracy::message("literal message");
	tracy::message_color("colored message", 0xabcdef);
	tracy::message_copy("copied message");
	tracy::message_color_copy("copied colored message", 0x654321);
	tracy::frame_mark();
	tracy::frame_mark_named("frame");
	tracy::Frame frame = tracy::named_frame("scoped frame");
	frame.end();

	$if $feat(TRACY):
		$if $feat(TRACY_CALLSTACK):
			assert(tracy_test_event_at(0) == ZONE_BEGIN_CALLSTACK);
			assert(tracy_test_event_at(6) == ZONE_BEGIN_CALLSTACK);
		$else
			assert(tracy_test_event_at(0) == ZONE_BEGIN);
			assert(tracy_test_event_at(6) == ZONE_BEGIN);
		$endif
		assert(tracy_test_event_at(1) == ZONE_TEXT);
		assert(tracy_test_event_at(2) == ZONE_NAME);
		assert(tracy_test_event_at(3) == ZONE_COLOR);
		assert(tracy_test_event_at(4) == ZONE_VALUE);
		assert(tracy_test_event_at(5) == ZONE_END);
		assert(tracy_test_event_at(7) == ZONE_END);
		assert(tracy_test_event_at(8) == MESSAGE_L);
		assert(tracy_test_event_at(9) == MESSAGE_LC);
		assert(tracy_test_event_at(10) == MESSAGE);
		assert(tracy_test_event_at(11) == MESSAGE_C);
		assert(tracy_test_event_at(12) == FRAME);
		assert(tracy_test_event_at(13) == FRAME);
		assert(tracy_test_event_at(14) == FRAME_START);
		assert(tracy_test_event_at(15) == FRAME_END);
		assert(tracy_test_event_count() == 16);
		assert(tracy_test_zone_source_ok());
		assert(tracy_test_abi_sizes_ok());
		assert(tracy_test_zone_args_ok());
		assert(tracy_test_message_args_ok());
		assert(zone.id == 41 || zone.id == 42);
		assert(zone.active == 1 && named.active == 1);
	$else
		assert(tracy_test_event_count() == 0);
		assert(zone.id == 0 && zone.active == 0);
		assert(named.id == 0 && named.active == 0);
	$endif
}

struct TestParent { bool fail_alloc; bool fail_resize; }

fn void*? TestParent.acquire(&self, sz size, AllocInitType init_type, sz alignment) @dynamic
{
	if (self.fail_alloc) return mem::OUT_OF_MEMORY~;
	return allocators::LIBC_ALLOCATOR.acquire(size, init_type, alignment);
}

fn void*? TestParent.resize(&self, void* old_pointer, sz new_size, sz alignment) @dynamic
{
	if (self.fail_resize) return mem::OUT_OF_MEMORY~;
	return allocators::LIBC_ALLOCATOR.resize(old_pointer, new_size, alignment);
}

fn void TestParent.release(&self, void* pointer, bool aligned) @dynamic
{
	allocators::LIBC_ALLOCATOR.release(pointer, aligned);
}

fn void allocator_variants_and_failures_follow_feature_mode() @test
{
	tracy_test_reset();
	$if $feat(TRACY_CALLSTACK): tracy_test_expect_callstack(10); $else tracy_test_expect_callstack(0); $endif
	TestParent parent = {};
	TracyAllocator wrapper = tracy::tracy_allocator((Allocator)&parent);
	Allocator allocator = tracy::tracy_allocator_interface(&wrapper);
	// The Allocator interface contract rejects zero; exercise the wrapper
	// directly because the Tracy wrapper intentionally treats it as a no-op.
	void* zero = wrapper.acquire(0, NO_ZERO, 0)!!;
	assert(!zero);
	void* allocated = allocator.acquire(24, NO_ZERO, 0)!!;
	void* resized = allocator.resize(allocated, 48, 0)!!;
	allocator.release(resized, false);
	TracyAllocator named_wrapper = tracy::tracy_allocator_named((Allocator)&parent, "arena");
	Allocator named_allocator = tracy::tracy_allocator_interface(&named_wrapper);
	void* named_allocated = named_allocator.acquire(16, NO_ZERO, 0)!!;
	named_allocator.release(named_allocated, false);

	parent.fail_alloc = true;
	void*? failed = allocator.acquire(32, NO_ZERO, 0);
	if (catch err = failed) { assert(err == mem::OUT_OF_MEMORY); }
	else { assert(false); }
	parent.fail_alloc = false;
	void* resize_target = allocator.acquire(12, NO_ZERO, 0)!!;
	parent.fail_resize = true;
	void*? failed_resize = allocator.resize(resize_target, 64, 0);
	if (catch err = failed_resize) { assert(err == mem::OUT_OF_MEMORY); }
	else { assert(false); }
	parent.fail_resize = false;
	// The interface contract rejects zero; the wrapper's zero-size path frees
	// the old allocation and returns null, so call the method directly.
	void* zero_resize = wrapper.resize(resize_target, 0, 0)!!;
	assert(!zero_resize);

	$if $feat(TRACY) && $feat(TRACY_ALLOCATION):
		$if $feat(TRACY_CALLSTACK):
			assert(tracy_test_event_at(0) == ALLOC_CALLSTACK);
			assert(tracy_test_event_at(1) == FREE_CALLSTACK);
			assert(tracy_test_event_at(2) == ALLOC_CALLSTACK);
			assert(tracy_test_event_at(3) == FREE_CALLSTACK);
			assert(tracy_test_event_at(4) == ALLOC_CALLSTACK_NAMED);
			assert(tracy_test_event_at(5) == FREE_CALLSTACK_NAMED);
			assert(tracy_test_event_at(6) == MESSAGE_LC);
			assert(tracy_test_event_at(7) == ALLOC_CALLSTACK);
			assert(tracy_test_event_at(8) == FREE_CALLSTACK);
		$else
			assert(tracy_test_event_at(0) == ALLOC);
			assert(tracy_test_event_at(1) == FREE);
			assert(tracy_test_event_at(2) == ALLOC);
			assert(tracy_test_event_at(3) == FREE);
			assert(tracy_test_event_at(4) == ALLOC_NAMED);
			assert(tracy_test_event_at(5) == FREE_NAMED);
			assert(tracy_test_event_at(6) == MESSAGE_LC);
			assert(tracy_test_event_at(7) == ALLOC);
			assert(tracy_test_event_at(8) == FREE);
		$endif
		assert(tracy_test_event_count() == 9);
		assert(tracy_test_memory_args_ok());
	$else
		$if $feat(TRACY):
			assert(tracy_test_event_count() == 1);
			assert(tracy_test_event_at(0) == MESSAGE_LC);
			assert(tracy_test_message_args_ok());
		$else
			assert(tracy_test_event_count() == 0);
		$endif
	$endif
}
