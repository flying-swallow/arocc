module fuzz_temp_tests;
import aro::fuzz_lib;

const usz EXPECTED_FUZZ_CAP = 20 * 1024 * 1024;

fn void assert_fuzz_state_cleared()
{
	assert(!fuzz_lib::fuzz_active, "fuzz input remained active after return");
	assert(!fuzz_lib::fuzz_arena_exhausted, "fuzz exhaustion state was not cleared");
	assert(fuzz_lib::fuzz_allocator.arena.used == 0, "fuzz arena retained bytes after return");
	assert(fuzz_lib::fuzz_allocator.arena.data.len == EXPECTED_FUZZ_CAP, "fuzz arena capacity changed");
}

fn void shared_temp_allocations_obey_twenty_mib_cap() @test
{
	assert(fuzz_lib::MAX_FUZZ_BYTES == EXPECTED_FUZZ_CAP, "fuzz arena is not configured for 20 MiB");
	assert(fuzz_lib::force_oom_for_test(), "ordinary and tmem allocations did not share the 20 MiB cap");
	assert_fuzz_state_cleared();
}

fn void valid_input_succeeds_after_exhaustion() @test
{
	assert(fuzz_lib::force_oom_for_test(), "test input did not exhaust the shared arena");
	assert_fuzz_state_cleared();
	assert(fuzz_lib::compile_succeeds_for_test("int main(void) { return 0; }"),
		"valid input failed after an exhausted input");
	assert_fuzz_state_cleared();
}
