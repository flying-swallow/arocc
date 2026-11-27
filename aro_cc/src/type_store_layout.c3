// Port of the size/alignment part of src/aro/TypeStore.zig: Type.Int.bits,
// Type.Float.bits, QualType.sizeofOrNull/sizeof/bitSizeofOrNull/bitSizeof,
// hasIncompleteSize, alignof, requestedAlignment, alignable, sizeCompare, plus
// Compilation.intLeastN / smallestNBitIntTargetIndependent / getCharSignedness.
//
// Every size and alignment comes from the explicit C target data in
// aro::target (`Target.c_type_bit_size`, `c_type_alignment`, `ptr_bit_width`,
// `default_function_alignment`), never from the host's sizeof. Record sizes
// and alignments come from the stored `RecordLayout`.
module aro::frontend::c::type_store;
import aro::bigint;
import aro::frontend::c::compilation, aro::frontend::c::lang_opts, aro::target;

<* std.mem.alignForward for a power-of-two (or 1) alignment. *>
fn ulong align_forward(ulong value, ulong alignment)
{
	assert(alignment != 0 && (alignment & (alignment - 1)) == 0, "alignment must be a power of two");
	return (value + alignment - 1) & ~(alignment - 1);
}

<*
 Natural layout of plain scalar fields (see the module comment); fills each
 field's `layout`.
 @require fields.len > 0
*>
fn RecordLayout natural_record_layout(Compilation* comp, RecordField[] fields, bool is_union = false)
{
	ulong size_bits = 0;
	uint align_bits = 8;
	foreach (&field : fields)
	{
		assert(field.bit_width == BIT_WIDTH_NULL, "bitfields need record_layout.compute");
		ulong fsize = field.qt.sizeof(comp) * 8;
		uint falign = field.qt.alignof(comp) * 8;
		ulong offset = is_union ? 0 : align_forward(size_bits, falign);
		size_bits = max(size_bits, offset + fsize);
		align_bits = max(align_bits, falign);
		field.layout = { .offset_bits = offset, .size_bits = fsize };
	}
	size_bits = align_forward(size_bits, align_bits);
	return { .size_bits = size_bits, .field_alignment_bits = align_bits, .pointer_alignment_bits = align_bits, .required_alignment_bits = 8 };
}

<* Type.Int.bits *>
fn ushort TypeInt.bits(self, Compilation* comp)
{
	if (self.fixed_bits) return self.fixed_bits;
	return comp.target.c_type_bit_size(self.ctype);
}

<*
 Type.Float.bits
 @require self != FLOAT128X : "_Float128x is not supported"
*>
fn ushort TypeFloat.bits(self, Compilation* comp)
{
	if (self == FLOAT128X) unreachable("_Float128x is not supported");
	if (self.fixed_bits) return self.fixed_bits;
	return comp.target.c_type_bit_size(self.ctype);
}

<* Compilation.getCharSignedness *>
fn Signedness char_signedness(Compilation* comp)
{
	if (comp.langopts.has_char_signedness_override) return comp.langopts.char_signedness_override;
	return comp.target.c_char_signedness();
}

<* Compilation.smallestNBitIntTargetIndependent *>
fn QualType smallest_n_bit_int_target_independent(Compilation* comp, ulong bits, Signedness signedness)
{
	QualType[6] signed_candidates = { SCHAR, SHORT, INT, LONG, LONG_LONG, INT128 };
	QualType[6] unsigned_candidates = { UCHAR, USHORT, UINT, ULONG, ULONG_LONG, UINT128 };
	QualType[6] candidates = signedness == SIGNED ? signed_candidates : unsigned_candidates;
	foreach (qt : candidates)
	{
		if (qt.bit_sizeof(comp) >= bits) return qt;
	}
	unreachable("no integer type is wide enough");
}

<* Compilation.intLeastN: lowest-rank integer type with at least N bits; subject to platform idiosyncrasies. *>
fn QualType int_least_n(Compilation* comp, ulong bits, Signedness signedness)
{
	return int_least_n_target(&comp.target, bits, signedness);
}

fn QualType int_least_n_target(Target* t, ulong bits, Signedness signedness)
{
	if (bits <= 24 && bits > t.c_type_bit_size(INT) && t.has_int24())
	{
		return signedness == SIGNED ? INT24 : UINT24;
	}
	if (bits == 64 && (t.os.tag.is_darwin() || t.cpu.arch.is_wasm()))
	{
		return signedness == SIGNED ? LONG_LONG : ULONG_LONG;
	}
	if (bits == 16 && t.cpu.arch == AVR) return signedness == SIGNED ? INT : UINT;
	TypeInt[6] candidates = { SCHAR, SHORT, INT, LONG, LONG_LONG, INT128 };
	foreach (k : candidates)
	{
		ulong width = k.fixed_bits ? k.fixed_bits : t.c_type_bit_size(k.ctype);
		if (width >= bits) return int_qt(signedness == SIGNED ? k : k.unsigned_of);
	}
	unreachable("no integer type is wide enough");
}

enum TypeSizeOrder : char
{
	LT,
	GT,
	EQ,
	INDETERMINATE,
}

fn TypeSizeOrder QualType.size_compare(self, QualType b, Compilation* comp)
{
	ulong? a_size = self.sizeof_or_null(comp);
	ulong? b_size = b.sizeof_or_null(comp);
	if (catch a_size) return INDETERMINATE;
	if (catch b_size) return INDETERMINATE;
	if (a_size < b_size) return LT;
	if (a_size > b_size) return GT;
	return EQ;
}

<* Size of a type as reported by the sizeof operator. @require !self.has_incomplete_size(comp) *>
fn ulong QualType.sizeof(self, Compilation* comp) => self.sizeof_or_null(comp)!!;

<* Size of a type as reported by the sizeof operator; NO_SIZE for incomplete types. *>
fn ulong? QualType.sizeof_or_null(self, Compilation* comp)
{
	if (self.is_invalid()) return NO_SIZE~;
	BaseType b = self.base(comp);
	Type ty = b.ty;
	while (true)
	{
		switch (ty.tag)
		{
			case VOID:
			case BOOL:
			case FUNC: return 1;
			case NULLPTR_T:
			case BLOCK:
			case POINTER: return (ulong)comp.target.ptr_bit_width() / 8;
			case STORAGE_FLOAT: return (ulong)ty.storage_float.bits / 8;
			case INT: return (ulong)ty.int_ty.bits(comp) / 8;
			// cTypeByteSize: an 80-bit x87 long double is padded to its alignment (16 on x86_64).
			case FLOAT: return align_forward(((ulong)ty.float_ty.bits(comp) + 7) / 8, b.qt.alignof(comp));
			case COMPLEX: return ty.complex.sizeof_or_null(comp)! * 2;
			case BIT_INT:
				return align_forward(((ulong)ty.bit_int.bits + 7) / 8, b.qt.alignof(comp));
			case ATOMIC: return ty.atomic.sizeof_or_null(comp);
			case VECTOR:
				ulong elem_size = ty.vector.elem.sizeof_or_null(comp)!;
				// clang: a non-power-of-two vector (ext_vector_type(3)) is padded to its alignment.
				return align_forward(elem_size * ty.vector.len, b.qt.alignof(comp));
			case ARRAY:
				bool msvc = comp.langopts.emulate == MSVC;
				ulong len;
				switch (ty.array.len.kind)
				{
					case VARIABLE:
					case UNSPECIFIED_VARIABLE: return NO_SIZE~;
					case INCOMPLETE:
						if (msvc) return 0;
						return NO_SIZE~;
					case FIXED:
					case STATIC: len = ty.array.len.len;
				}
				ulong elem_size = ty.array.elem.sizeof_or_null(comp)!;
				ulong arr_size = elem_size * len;
				// msvc ignores array type alignment. Since the size might not be a
				// multiple of the field alignment, the address of the second element
				// might not be properly aligned for the field alignment. A flexible
				// array has size 0. See test case 0018.
				if (msvc) return arr_size;
				return align_forward(arr_size, b.qt.alignof(comp));
			case STRUCT:
			case UNION:
				if (!ty.record.has_layout) return NO_SIZE~;
				ulong size = ty.record.layout.size_bits / 8;
				if (comp.langopts.emulate != MSVC) return size;
				Type own = self.get_type(comp);
				if (own.tag == TYPEDEF && !@ok(comp.type_store.get_requested_alignment(self)))
				{
					return own.type_def.base.sizeof_or_null(comp);
				}
				uint? alignment = self.requested_alignment(comp);
				if (catch alignment) return size;
				bool should_round_size = true;
				if (own.tag == TYPEDEF)
				{
					TypeTag base_tag = own.type_def.base.get_type(comp).tag;
					should_round_size = base_tag == STRUCT || base_tag == UNION;
				}
				if (!should_round_size) return size;
				return align_forward(size, alignment);
			case ENUM:
				if (!ty.enum_ty.has_tag) return NO_SIZE~;
				ty = ty.enum_ty.tag.base(comp).ty;
			case TYPEOF:
			case TYPEDEF: unreachable("base() never returns typeof/typedef");
		}
	}
}

<* Size of type in bits as it would have in a bitfield. @require !self.has_incomplete_size(comp) *>
fn ulong QualType.bit_sizeof(self, Compilation* comp) => self.bit_sizeof_or_null(comp)!!;

<* Size of type in bits as it would have in a bitfield; NO_SIZE for incomplete types. *>
fn ulong? QualType.bit_sizeof_or_null(self, Compilation* comp)
{
	if (self.is_invalid()) return NO_SIZE~;
	Type ty = self.base(comp).ty;
	switch (ty.tag)
	{
		case BOOL: return comp.langopts.emulate == MSVC ? 8 : 1;
		case BIT_INT: return ty.bit_int.bits;
		case STORAGE_FLOAT: return ty.storage_float.bits;
		case FLOAT: return ty.float_ty.bits(comp);
		case INT: return ty.int_ty.bits(comp);
		default: return 8 * self.sizeof_or_null(comp)!;
	}
}

fn bool QualType.has_incomplete_size(self, Compilation* comp)
{
	if (self.is_invalid()) return false;
	Type ty = self.base(comp).ty;
	switch (ty.tag)
	{
		case VOID: return true;
		case ARRAY: return ty.array.len.kind == INCOMPLETE;
		case ENUM: return ty.enum_ty.incomplete && !ty.enum_ty.fixed;
		case STRUCT:
		case UNION: return !ty.record.has_layout;
		default: return false;
	}
}

<* Size of a type as reported by the alignof operator. *>
fn uint QualType.alignof(self, Compilation* comp)
{
	if (try requested = self.requested_alignment(comp))
	{
		bool use_requested = true;
		if (self.is(comp, ENUM))
		{
			switch (comp.langopts.emulate)
			{
				case GCC:
					// gcc ignores `aligned` on the enum itself, but honours it on a typedef of one.
					use_requested = self.get_type(comp).tag == TYPEDEF && @ok(comp.type_store.get_requested_alignment(self));
				case MSVC:
					uint base_align = self.base(comp).qt.alignof(comp);
					return max(requested, base_align);
				case CLANG:
				case NO: break;
			}
		}
		else if (comp.langopts.emulate == MSVC)
		{
			Type own = self.get_type(comp);
			uint type_align = own.tag == TYPEDEF ? own.type_def.base.alignof(comp) : self.base(comp).qt.alignof(comp);
			return max(requested, type_align);
		}
		if (use_requested) return requested;
	}

	Target* t = &comp.target;
	Type ty = self.get_type(comp);
	while (true)
	{
		switch (ty.tag)
		{
			case VOID:
			case BOOL: return 1;
			case STORAGE_FLOAT: return ty.storage_float.alignment;
			case INT:
				switch (ty.int_ty)
				{
					case CHAR:
					case SCHAR:
					case UCHAR: return 1;
					case SHORT: return t.c_type_alignment(SHORT);
					case USHORT: return t.c_type_alignment(USHORT);
					case INT: return t.c_type_alignment(INT);
					case UINT: return t.c_type_alignment(UINT);
					case LONG: return t.c_type_alignment(LONG);
					case ULONG: return t.c_type_alignment(ULONG);
					case LONG_LONG: return t.c_type_alignment(LONGLONG);
					case ULONG_LONG: return t.c_type_alignment(ULONGLONG);
					case INT24:
					case UINT24: return 1;
					case INT128:
					case UINT128:
						if (t.cpu.arch == S390X && t.os.tag == LINUX && t.abi.is_gnu()) return 8;
						return 16;
				}
			case FLOAT:
				switch (ty.float_ty)
				{
					case FLOAT: return t.c_type_alignment(FLOAT);
					case DOUBLE: return t.c_type_alignment(DOUBLE);
					case LONG_DOUBLE: return t.c_type_alignment(LONGDOUBLE);
					case BF16:
					case FP16:
					case FLOAT16: return 2;
					case FLOAT128: return 16;
					case FLOAT32: return t.c_type_alignment(FLOAT);
					case FLOAT64: return t.c_type_alignment(DOUBLE);
					case FLOAT32X: return 8;
					case FLOAT64X: return 16;
					case FLOAT128X: unreachable("_Float128x is not supported");
					case DFLOAT32: return 4;
					case DFLOAT64: return 8;
					case DFLOAT128: return 16;
					case DFLOAT64X: return 16;
				}
			case BIT_INT:
				// https://www.open-std.org/jtc1/sc22/wg14/www/docs/n2709.pdf
				// _BitInt(N) types have the same size and alignment as the smallest
				// basic type that can contain them. Types larger than __int64_t are
				// treated as structs of register size chunks.
				if (ty.bit_int.bits > 64) return 8;
				return int_least_n(comp, ty.bit_int.bits, ty.bit_int.signedness).alignof(comp);
			case ATOMIC: ty = ty.atomic.base(comp).ty;
			case COMPLEX: ty = ty.complex.base(comp).ty;
			case POINTER:
			case NULLPTR_T:
			case BLOCK:
				if (t.cpu.arch == AVR) return 1;
				return (uint)(self.bit_sizeof(comp) / 8);
			case FUNC: return t.default_function_alignment();
			case ARRAY: return ty.array.elem.alignof(comp);
			case VECTOR:
				// gcc/clang: a vector aligns to its byte size rounded up to a power of two
				// (gcc caps x86 vectors at 16 without AVX); never below the element alignment.
				uint elem_align = ty.vector.elem.alignof(comp);
				ulong size = ty.vector.elem.sizeof_or_null(comp) ?? 0;
				size *= ty.vector.len;
				ulong align = 1;
				while (align < size) align <<= 1;
				if (comp.langopts.emulate == GCC && (t.cpu.arch == X86 || t.cpu.arch == X86_64) && align > 16) align = 16;
				return max((uint)align, elem_align);
			case STRUCT:
			case UNION:
				if (!ty.record.has_layout) return 0;
				return ty.record.layout.field_alignment_bits / 8;
			case ENUM:
				if (!ty.enum_ty.has_tag) return 0;
				ty = ty.enum_ty.tag.base(comp).ty;
			case TYPEOF: return ty.type_of.base.alignof(comp);
			case TYPEDEF: ty = ty.type_def.base.base(comp).ty;
		}
	}
}

<* The alignment requested for this handle or the types it wraps (Zig requestedAlignment). *>
fn uint? QualType.requested_alignment(self, Compilation* comp)
{
	if (self.is_invalid()) return NO_ALIGN~;
	uint? own = comp.type_store.get_requested_alignment(self);
	uint? base_alignment = NO_ALIGN~;
	Type ty = self.get_type(comp);
	switch (ty.tag)
	{
		case TYPEOF: base_alignment = ty.type_of.base.requested_alignment(comp);
		case TYPEDEF: base_alignment = ty.type_def.base.requested_alignment(comp);
		default: break;
	}
	if (try o = own)
	{
		if (comp.langopts.emulate == MSVC)
		{
			if (try ba = base_alignment) return max(o, ba);
		}
		return o;
	}
	return base_alignment;
}

fn bool QualType.alignable(self, Compilation* comp)
{
	if (self.is_invalid()) return true; // Avoid redundant error.
	BaseType b = self.base(comp);
	switch (b.ty.tag)
	{
		case ARRAY:
		case VOID: return false;
		default: return !b.qt.has_incomplete_size(comp);
	}
}
