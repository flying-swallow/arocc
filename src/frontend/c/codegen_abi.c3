// Aggregate ABI classification (SysV x86_64) shared by code generation entry points.
module aro::frontend::c::codegen;
import aro::frontend::c::compilation, aro::frontend::c::type_store, aro::value_interner;

enum AggClass : char
{
	<* Passed and returned in registers, one eightbyte each (see `words`). *>
	REGISTER,
	MEMORY,
	IGNORE,
	<* A lone x87 long double: returned in st(0), passed in memory. *>
	X87,
	<* A 16-byte vector (or a record of exactly one): one whole XMM register,
	   moved as a 128-bit (f128-typed) IR value. *>
	VECTOR128,
}

<* SysV class of one eightbyte; NONE until a leaf lands in it. *>
enum WordClass : char
{
	NONE,
	INTEGER,
	SSE,
	X87,
	MEMORY,
	<* Upper half of a 16-byte vector. *>
	SSEUP,
}

struct AggClassResult
{
	AggClass kind;
	ulong eightbyte_count;
	<* For REGISTER: INTEGER or SSE per eightbyte. *>
	WordClass[2] words;
}

fn bool AggClassResult.is_sse(&self, uint word) => self.words[word] == WordClass.SSE;

fn uint AggClassResult.sse_words(&self)
{
	uint count;
	for (uint i = 0; i < (uint)self.eightbyte_count; i++) if (self.is_sse(i)) count++;
	return count;
}

<* The IR type that carries one register eightbyte of this class. *>
fn value_interner::InternerRef word_value_type(WordClass class)
	=> class == WordClass.SSE ? value_interner::REF_F64 : value_interner::REF_I64;

fn uint AggClassResult.gp_words(&self)
{
	uint count;
	for (uint i = 0; i < (uint)self.eightbyte_count; i++) if (self.words[i] == WordClass.INTEGER) count++;
	return count;
}

<* The eightbytes that travel in registers (INTEGER or SSE), in order; returns their count. *>
fn uint AggClassResult.active_words(&self, uint[2]* out)
{
	uint count;
	for (uint i = 0; i < (uint)self.eightbyte_count; i++)
	{
		if (self.words[i] == WordClass.INTEGER || self.words[i] == WordClass.SSE) (*out)[count++] = i;
	}
	return count;
}

<*
 Classify a struct or union under the SysV x86_64 rules: aggregates over 16 bytes
 or with a scalar not aligned to its size go in memory; otherwise each eightbyte is INTEGER when
 any integer data overlaps it and SSE when it holds only float/double data.
*>
fn AggClassResult? CodeGen.classify_record(&self, type_store::QualType qt)
{
	type_store::BaseType base = qt.base(self.comp);
	assert(base.ty.tag == type_store::TypeTag.STRUCT || base.ty.tag == type_store::TypeTag.UNION ||
		base.ty.tag == type_store::TypeTag.VECTOR, "classify_record requires a struct, union or vector type");

	ulong size = qt.sizeof(self.comp);
	ulong eightbytes = size / 8 + (size % 8 == 0 ? (ulong)0 : (ulong)1);
	if (size == 0) return { .kind = AggClass.IGNORE, .eightbyte_count = 0 };
	if (size > 16) return { .kind = AggClass.MEMORY, .eightbyte_count = eightbytes };
	if (base.ty.tag == type_store::TypeTag.VECTOR)
	{
		// Vector types are SSE class whatever their element type.
		if (size == 16) return { .kind = AggClass.VECTOR128, .eightbyte_count = 2 };
		if (size > 8) return { .kind = AggClass.MEMORY, .eightbyte_count = eightbytes };
		return { .kind = AggClass.REGISTER, .eightbyte_count = 1, .words = { WordClass.SSE, WordClass.NONE } };
	}

	WordClass[2] words;
	self.classify_into(qt, 0, &words)!;
	if (words[0] == WordClass.SSE && words[1] == WordClass.SSEUP) return { .kind = AggClass.VECTOR128, .eightbyte_count = 2 };
	for (uint i = 0; i < 2; i++) if (words[i] == WordClass.SSEUP) words[i] = WordClass.SSE;
	AggClassResult result = { .kind = AggClass.REGISTER, .eightbyte_count = eightbytes };
	for (uint i = 0; i < (uint)eightbytes; i++)
	{
		switch (words[i])
		{
			case MEMORY:
				return { .kind = AggClass.MEMORY, .eightbyte_count = eightbytes };
			case X87:
				// Only `struct { long double x; }` (X87 + X87UP) stays out of memory.
				if (eightbytes == 2 && i == 0 && words[1] == WordClass.X87) return { .kind = AggClass.X87, .eightbyte_count = eightbytes };
				return { .kind = AggClass.MEMORY, .eightbyte_count = eightbytes };
			default:
				// NONE (padding only, e.g. under a zero-length array) takes no register.
				result.words[i] = words[i];
		}
	}
	uint[2] active;
	if (result.active_words(&active) == 0) return { .kind = AggClass.IGNORE, .eightbyte_count = eightbytes };
	return result;
}

fn WordClass merge_word_class(WordClass a, WordClass b)
{
	if (a == b) return a;
	if (a == WordClass.NONE) return b;
	if (b == WordClass.NONE) return a;
	if (a == WordClass.SSEUP) a = WordClass.SSE;
	if (b == WordClass.SSEUP) b = WordClass.SSE;
	if (a == b) return a;
	// SysV rules 3-6 in GCC's order: INTEGER beats X87, so a union of a long
	// double and integers travels in GPRs.
	if (a == WordClass.MEMORY || b == WordClass.MEMORY) return WordClass.MEMORY;
	if (a == WordClass.INTEGER || b == WordClass.INTEGER) return WordClass.INTEGER;
	if (a == WordClass.X87 || b == WordClass.X87) return WordClass.MEMORY;
	return WordClass.SSE;
}

<* Merge `class` into every eightbyte the bit range [offset_bits, offset_bits + bits) overlaps. *>
fn void mark_word_class(WordClass[2]* words, ulong offset_bits, ulong bits, WordClass class)
{
	if (bits == 0) return;
	ulong first = offset_bits / 64;
	ulong last = (offset_bits + bits - 1) / 64;
	for (ulong i = first; i <= last && i < 2; i++) (*words)[i] = merge_word_class((*words)[i], class);
}

<* Merge the classes of the leaves of `qt`, placed at `offset_bits`, into `words`. *>
fn void? CodeGen.classify_into(&self, type_store::QualType qt, ulong offset_bits, WordClass[2]* words)
{
	type_store::BaseType base = qt.base(self.comp);
	switch (base.ty.tag)
	{
		case type_store::TypeTag.STRUCT:
		case type_store::TypeTag.UNION:
			foreach (field : base.ty.record.fields)
			{
				if (field.qt.is_invalid()) continue;
				if (field.layout.offset_bits == type_store::FIELD_LAYOUT_INVALID) continue;
				ulong field_offset = offset_bits + field.layout.offset_bits;
				if (field.bit_width != type_store::BIT_WIDTH_NULL)
				{
					mark_word_class(words, field_offset, (ulong)field.bit_width, WordClass.INTEGER);
					continue;
				}
				self.classify_into(field.qt, field_offset, words)!;
			}
		case type_store::TypeTag.ARRAY:
			ulong? maybe_elem_size = base.ty.array.elem.sizeof_or_null(self.comp);
			if (catch maybe_elem_size)
			{
				mark_word_class(words, offset_bits, 1, WordClass.MEMORY);
				return;
			}
			ulong elem_size = maybe_elem_size;
			if (elem_size == 0) return;

			ulong count;
			switch (base.ty.array.len.kind)
			{
				case type_store::ArrayLenKind.FIXED:
				case type_store::ArrayLenKind.STATIC: count = base.ty.array.len.len;
				case type_store::ArrayLenKind.INCOMPLETE: return; // Flexible array member.
				case type_store::ArrayLenKind.VARIABLE:
				case type_store::ArrayLenKind.UNSPECIFIED_VARIABLE:
					mark_word_class(words, offset_bits, 1, WordClass.MEMORY);
					return;
			}
			if (count == 0)
			{
				// GCC still classifies a zero-length array's element: a misaligned
				// leaf there sends the whole aggregate to memory.
				WordClass[2] scratch;
				self.classify_into(base.ty.array.elem, offset_bits, &scratch)!;
				if (scratch[0] == WordClass.MEMORY || scratch[1] == WordClass.MEMORY) mark_word_class(words, offset_bits, 1, WordClass.MEMORY);
				return;
			}
			for (ulong i = 0; i < count && offset_bits + i * elem_size * 8 < 128; i++)
			{
				self.classify_into(base.ty.array.elem, offset_bits + i * elem_size * 8, words)!;
			}
		case type_store::TypeTag.FLOAT:
			ulong bits = qt.bit_sizeof(self.comp);
			if (!leaf_is_aligned(offset_bits, bits == 80 ? 128 : bits, words)) return;
			switch (bits)
			{
				case 80:
					mark_word_class(words, offset_bits, 128, WordClass.X87);
				case 128:
					self.fail("TODO pass and return struct/union by value: __float128 member (SSEUP class)\n")!;
				default:
					mark_word_class(words, offset_bits, bits, WordClass.SSE);
			}
		case type_store::TypeTag.COMPLEX:
			ulong half = qt.sizeof(self.comp) * 4;
			self.classify_into(base.ty.complex, offset_bits, words)!;
			self.classify_into(base.ty.complex, offset_bits + half, words)!;
		case type_store::TypeTag.ATOMIC:
			self.classify_into(base.ty.atomic, offset_bits, words)!;
		case type_store::TypeTag.VECTOR:
			ulong vector_bits = qt.sizeof(self.comp) * 8;
			if (!leaf_is_aligned(offset_bits, vector_bits > 64 ? 128 : vector_bits, words)) return;
			if (vector_bits == 128 && offset_bits == 0)
			{
				mark_word_class(words, 0, 64, WordClass.SSE);
				mark_word_class(words, 64, 64, WordClass.SSEUP);
			}
			else
			{
				mark_word_class(words, offset_bits, vector_bits, WordClass.SSE);
			}
		default:
			ulong bits = qt.sizeof(self.comp) * 8;
			if (!leaf_is_aligned(offset_bits, bits, words)) return;
			mark_word_class(words, offset_bits, bits, WordClass.INTEGER);
	}
}

<* GCC: a scalar leaf not aligned to its own (power-of-two) size, as in packed
   records or under a typedef that lowers alignment, sends the aggregate to memory. *>
fn bool leaf_is_aligned(ulong offset_bits, ulong mode_bits, WordClass[2]* words)
{
	if (mode_bits == 0 || (mode_bits & (mode_bits - 1)) != 0) return true;
	if (offset_bits % mode_bits == 0) return true;
	mark_word_class(words, offset_bits, 1, WordClass.MEMORY);
	return false;
}
