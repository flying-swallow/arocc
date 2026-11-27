// Fixed-size bit sets over 64-bit words, and row-major matrices of them.
// A BitSet is a view over its words: `BitMatrix.row` returns one sharing the
// matrix storage, so writes through a row update the matrix.
module aro::bitset;


<* Words needed to hold `bits` bits. *>
fn usz word_count(usz bits) @inline @local => (bits + (ulong::size * 8) - 1) / (ulong::size * 8);

struct BitSet
{
	ulong[] words;
}

<* A zeroed set of `bits` bits from `allocator`; release with `free`. *>
fn BitSet new(Allocator allocator, usz bits)
{
	return { .words = alloc::new_array(allocator, ulong, (sz)word_count(bits)) };
}

<* A zeroed set of `bits` bits in the temp allocator. *>
fn BitSet temp(usz bits) => new(tmem, bits);

fn void BitSet.free(&self, Allocator allocator)
{
	if (self.words.len) alloc::free(allocator, self.words.ptr);
	self.words = {};
}

fn void BitSet.set(self, usz bit) @inline
{
	self.words[bit / (ulong::size * 8)] |= 1UL << (bit % (ulong::size * 8));
}

fn void BitSet.unset(self, usz bit) @inline
{
	self.words[bit / (ulong::size * 8)] &= ~(1UL << (bit % (ulong::size * 8)));
}

fn bool BitSet.get(self, usz bit) @inline
{
	return (self.words[bit / (ulong::size * 8)] & (1UL << (bit % (ulong::size * 8)))) != 0;
}

fn void BitSet.clear_all(self)
{
	foreach (&word : self.words) *word = 0;
}

<* self |= other. Sets must have the same word count. *>
fn void BitSet.union_with(self, BitSet other)
{
	foreach (i, word : other.words) self.words[i] |= word;
}

<* Copy `other` into self; true when any bit changed. *>
fn bool BitSet.assign(self, BitSet other)
{
	bool changed = false;
	foreach (i, word : other.words)
	{
		if (self.words[i] != word)
		{
			self.words[i] = word;
			changed = true;
		}
	}
	return changed;
}

<* Run `body` with the index of every set bit, in ascending order. *>
macro void BitSet.@each_set(self; @body(usz bit))
{
	foreach (i, word : self.words)
	{
		ulong rest = word;
		while (rest)
		{
			usz bit = (usz)i * (ulong::size * 8) + (usz)rest.ctz();
			rest &= rest - 1;
			@body(bit);
		}
	}
}

<* `rows` sets of `bits` bits each, stored contiguously. *>
struct BitMatrix
{
	ulong[] words;
	usz stride;
}

<* A zeroed matrix from `allocator`; release with `free`. *>
fn BitMatrix new_matrix(Allocator allocator, usz rows, usz bits)
{
	usz stride = word_count(bits);
	return { .words = alloc::new_array(allocator, ulong, (sz)(rows * stride)), .stride = stride };
}

<* A zeroed matrix in the temp allocator. *>
fn BitMatrix temp_matrix(usz rows, usz bits) => new_matrix(tmem, rows, bits);

fn void BitMatrix.free(&self, Allocator allocator)
{
	if (self.words.len) alloc::free(allocator, self.words.ptr);
	*self = {};
}

<* Row `index` as a view sharing the matrix storage. *>
fn BitSet BitMatrix.row(self, usz index) @inline
{
	return { .words = self.words[(sz)(index * self.stride) : (sz)self.stride] };
}
