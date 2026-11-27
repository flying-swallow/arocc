// Tests for aro::bitset (used by x86_64 register liveness).
module bitset_tests;
import std, aro::bitset;

fn void word_count_rounds_up() @test
{
	@pool()
	{
		assert(bitset::temp(0).words.len == 0);
		assert(bitset::temp(1).words.len == 1);
		assert(bitset::temp(64).words.len == 1);
		assert(bitset::temp(65).words.len == 2);
	};
}

fn void set_get_unset_across_words() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	bitset::BitSet set = bitset::new(&ta, 130);
	foreach (word : set.words) assert(word == 0);
	set.set(0);
	set.set(63);
	set.set(64);
	set.set(129);
	assert(set.get(0) && set.get(63) && set.get(64) && set.get(129));
	assert(!set.get(1) && !set.get(65) && !set.get(128));
	set.unset(63);
	assert(!set.get(63));
	List{usz} seen;
	seen.init(&ta);
	set.@each_set(; usz bit) { seen.push(bit); };
	assert(seen.len() == 3);
	assert(seen[0] == 0);
	assert(seen[1] == 64);
	assert(seen[2] == 129);
	seen.free();
	set.free(&ta);
	assert(ta.allocation_count() == 0);
}

fn void union_assign_and_matrix_rows() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	bitset::BitMatrix matrix = bitset::new_matrix(&ta, 3, 70);
	matrix.row(1).set(69);
	matrix.row(2).set(5);
	assert(!matrix.row(0).get(69) && matrix.row(1).get(69) && !matrix.row(2).get(69));
	bitset::BitSet scratch = bitset::new(&ta, 70);
	scratch.union_with(matrix.row(1));
	scratch.union_with(matrix.row(2));
	assert(scratch.get(5) && scratch.get(69));
	assert(matrix.row(0).assign(scratch));
	assert(!matrix.row(0).assign(scratch));
	assert(matrix.row(0).get(5) && matrix.row(0).get(69));
	scratch.clear_all();
	assert(!scratch.get(5) && !scratch.get(69));
	scratch.free(&ta);
	matrix.free(&ta);
	assert(ta.allocation_count() == 0);
}
