// Deterministic smoke coverage for the libFuzzer/AFL entry point. Inputs are
// intentionally small and live in the same corpus that can seed an AFL run.
module replay_test;
import aro::fuzz_lib;
import std::io, std::core::mem::allocators;

const usz MAX_REPLAY_BYTES = 16 * 1024;

const String CORPUS = "aro_cc/test/fuzz/corpus";

fn String corpus_path(String name)
{
	return string::format(mem, "%s/%s", CORPUS, name);
}

fn void check_bound(char[] bytes)
{
	assert(bytes.len > 0);
	assert(bytes.len <= MAX_REPLAY_BYTES);
	assert(bytes.len <= (usz)int::max);
}

fn PoolState current_temp_state()
{
	PoolState state = mem::temp_push();
	mem::temp_pop(state);
	return state;
}

fn void assert_call_state_reset(PoolState temp_state)
{
	assert(!fuzz_lib::fuzz_active, "fuzz call left active state set");
	assert(!fuzz_lib::fuzz_arena_exhausted, "fuzz call left OOM state set");
	assert(fuzz_lib::fuzz_allocator.arena.used == 0, "fuzz arena retained allocated bytes");
	assert(fuzz_lib::fuzz_allocator.arena.mark() == 0, "fuzz arena mark was not reset");
	assert(fuzz_lib::fuzz_allocator.arena.data.ptr == &fuzz_lib::fuzz_storage[0], "fuzz arena backing bytes changed");
	assert(fuzz_lib::fuzz_allocator.arena.data.len == fuzz_lib::MAX_FUZZ_BYTES, "fuzz arena backing size changed");

	PoolState after = mem::temp_push();
	defer mem::temp_pop(after);
	assert(after == temp_state, "fuzz call did not restore the temp allocator state");
}

fn void replay(char[] bytes)
{
	check_bound(bytes);
	PoolState temp_state = current_temp_state();
	fuzz_lib::compile_c_buf(&bytes[0], (int)bytes.len);
	assert_call_state_reset(temp_state);
}

fn void replay_fixture(String name)
{
	String path = corpus_path(name);
	defer free(path);
	char[] bytes = file::load(mem, path)!!;
	defer free(bytes);
	replay(bytes);
	// The ABI exposes no result to compare; repeating checks deterministic
	// completion and catches stale per-call state or allocator reuse failures.
	replay(bytes);
}

fn void valid_malformed_and_stress_corpus_replays() @test
{
	// Revisit a known-valid translation unit across every other input class.
	replay_fixture("valid.c");
	replay_fixture("malformed.c");
	replay_fixture("valid.c");
	replay_fixture("recursive_macro.c");
	replay_fixture("deep_declaration.c");
	replay_fixture("embedded_nul.bin");
	replay_fixture("valid.c");
}

fn void embedded_nul_fixture_contains_a_real_zero_byte() @test
{
	String path = corpus_path("embedded_nul.bin");
	defer free(path);
	char[] bytes = file::load(mem, path)!!;
	defer free(bytes);
	check_bound(bytes);

	bool has_nul = false;
	foreach (byte : bytes) if (byte == 0) has_nul = true;
	assert(has_nul);
	// Pass the exact byte length, including data after the embedded NUL.
	replay(bytes);
}

fn void invalid_abi_inputs_are_ignored() @test
{
	char byte = 0;
	PoolState temp_state = current_temp_state();
	// Establish the arena backing span before checking early-return paths.
	fuzz_lib::compile_c_buf(null, 0);
	assert_call_state_reset(temp_state);

	// The wrapper must reject each length before constructing a slice or reading
	// the supplied pointer. A one-byte pointer keeps the rejected calls bounded.
	fuzz_lib::compile_c_buf(&byte, -1);
	assert_call_state_reset(temp_state);

	fuzz_lib::compile_c_buf(&byte, (int)fuzz_lib::MAX_FUZZ_BYTES + 1);
	assert_call_state_reset(temp_state);

	fuzz_lib::compile_c_buf(null, 1);
	assert_call_state_reset(temp_state);
}

fn void null_empty_input_is_accepted_and_reset() @test
{
	PoolState temp_state = current_temp_state();
	fuzz_lib::compile_c_buf(null, 0);
	assert_call_state_reset(temp_state);
}

fn void exhausted_input_is_followed_by_successful_valid_input() @test
{
	PoolState temp_state = current_temp_state();
	assert(fuzz_lib::force_oom_for_test(), "test input did not exhaust the shared arena");
	assert_call_state_reset(temp_state);
	assert(fuzz_lib::compile_succeeds_for_test("int main(void) { return 0; }"),
		"valid input failed after an exhausted input");
	assert_call_state_reset(temp_state);
}
