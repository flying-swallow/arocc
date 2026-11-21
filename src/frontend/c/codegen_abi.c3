// Aggregate ABI classification shared by code generation entry points.
module aro::frontend::c::codegen;
import aro::frontend::c::compilation, aro::frontend::c::type_store;

enum AggClass : char
{
	INTEGER,
	MEMORY,
	IGNORE,
}

struct AggClassResult
{
	AggClass kind;
	ulong eightbyte_count;
}

<*
 Classify a struct or union for the current aggregate ABI subset.
 Aggregates up to 16 bytes are INTEGER unless their fields are misaligned;
 floating-point leaves remain unsupported until SSE classes are implemented.
*>
fn AggClassResult? CodeGen.classify_record(&self, type_store::QualType qt)
{
	type_store::BaseType base = qt.base(self.comp);
	assert(base.ty.tag == type_store::TypeTag.STRUCT || base.ty.tag == type_store::TypeTag.UNION,
		"classify_record requires a struct or union type");

	ulong size = qt.sizeof(self.comp);
	ulong eightbytes = size / 8 + (size % 8 == 0 ? (ulong)0 : (ulong)1);
	if (size == 0) return { .kind = AggClass.IGNORE, .eightbyte_count = 0 };
	if (size > 16) return { .kind = AggClass.MEMORY, .eightbyte_count = eightbytes };

	if (!self.aggregate_layout_is_natural(qt, 0)!)
	{
		return { .kind = AggClass.MEMORY, .eightbyte_count = eightbytes };
	}
	return { .kind = AggClass.INTEGER, .eightbyte_count = eightbytes };
}

<* Recursively inspect aggregate contents and their byte alignment. *>
fn bool? CodeGen.aggregate_layout_is_natural(&self, type_store::QualType qt, ulong offset_bits)
{
	uint alignment = qt.alignof(self.comp);
	ulong alignment_bits = (ulong)alignment * 8;
	if (alignment_bits != 0 && offset_bits % alignment_bits != 0) return false;

	type_store::BaseType base = qt.base(self.comp);
	switch (base.ty.tag)
	{
		case type_store::TypeTag.STRUCT:
		case type_store::TypeTag.UNION:
			foreach (field : base.ty.record.fields)
			{
				// Keep bitfield handling in gen_type, which owns its existing diagnostic.
				if (field.bit_width != type_store::BIT_WIDTH_NULL || field.qt.is_invalid()) continue;
				if (field.layout.offset_bits == type_store::FIELD_LAYOUT_INVALID) continue;
				ulong field_offset = offset_bits + field.layout.offset_bits;
				if (!self.aggregate_layout_is_natural(field.qt, field_offset)!) return false;
			}
			return true;
		case type_store::TypeTag.ARRAY:
			ulong? maybe_elem_size = base.ty.array.elem.sizeof_or_null(self.comp);
			if (catch maybe_elem_size) return false;
			ulong elem_size = maybe_elem_size;
			if (elem_size == 0) return true;

			ulong count;
			switch (base.ty.array.len.kind)
			{
				case type_store::ArrayLenKind.FIXED:
				case type_store::ArrayLenKind.STATIC: count = base.ty.array.len.len;
				case type_store::ArrayLenKind.INCOMPLETE: return true; // Flexible array member.
				case type_store::ArrayLenKind.VARIABLE:
				case type_store::ArrayLenKind.UNSPECIFIED_VARIABLE: return false;
			}
			for (ulong i = 0; i < count; i++)
			{
				ulong elem_offset = offset_bits + i * elem_size * 8;
				if (!self.aggregate_layout_is_natural(base.ty.array.elem, elem_offset)!) return false;
			}
			return true;
		case type_store::TypeTag.FLOAT:
			self.fail("TODO pass and return struct/union by value: SSE class\n")!;
			return false;
		case type_store::TypeTag.ATOMIC:
			return self.aggregate_layout_is_natural(base.ty.atomic, offset_bits);
		case type_store::TypeTag.COMPLEX:
			return self.aggregate_layout_is_natural(base.ty.complex, offset_bits);
		default: return true;
	}
}
