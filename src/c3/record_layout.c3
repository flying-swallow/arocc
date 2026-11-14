// Record layout code adapted from https://github.com/mahkoh/repr-c
// Licensed under MIT: https://github.com/mahkoh/repr-c/tree/master/repc/facade
// Port of src/aro/record_layout.zig. Record sizes and alignments are kept in
// bits and come from the explicit Compilation target, never the host ABI.
module aro::type_store;
import aro::compilation, aro::attribute_map, aro::target, aro::lang_opts, std::math;

const ulong BITS_PER_BYTE = 8;

struct OngoingBitfield
{
	ulong size_bits; ulong unused_size_bits;
}

<*
@require alignment != 0 && (alignment & (alignment - 1)) == 0: `alignment must be a power of two.`
*>
fn ulong? record_align_forward(ulong value, ulong alignment)
{
	if (value > ulong::max - (alignment - 1)) return math::OVERFLOW~;
	return (value + alignment - 1) & ~(alignment - 1);
}

fn RecordLayout? compute_layout(QualType qt, Compilation* comp)
{
	uint requested = 0;
	if (comp.langopts.emulate == MSVC)
	{
		uint? a = msvc_required_alignment(qt, comp); if (try v = a) requested = v.overflow_mul(8)!;
	}
	else
	{
		uint? a = qt.requested_alignment(comp); if (try v = a) requested = v.overflow_mul(8)!;
	}
	Type ty = qt.base(comp).ty;
	if (ty.tag == STRUCT || ty.tag == UNION)
	{
		RecordLayout r = ty.record.layout;
		return { .size_bits = r.size_bits, .pointer_alignment_bits = max(requested, r.pointer_alignment_bits), .field_alignment_bits = max(requested, r.field_alignment_bits), .required_alignment_bits = max(requested, r.required_alignment_bits) };
	}
	uint bits = qt.alignof(comp).overflow_mul(8)!;
	ulong size = 0;
	ulong? optional_size = qt.sizeof_or_null(comp);
	if (try s = optional_size) size = s;
	return { .size_bits = size.overflow_mul(8)!, .pointer_alignment_bits = bits, .field_alignment_bits = bits, .required_alignment_bits = max(requested, (uint)8) };
}

fn uint? msvc_required_alignment(QualType qt, Compilation* comp)
{
	Type ty = qt.get_type(comp);
	uint? child;
	switch (ty.tag)
	{
		case ARRAY: child = msvc_required_alignment(ty.array.elem, comp);
		case TYPEDEF: child = msvc_required_alignment(ty.type_def.base, comp);
		case TYPEOF: child = msvc_required_alignment(ty.type_of.base, comp);
		case STRUCT:
		case UNION: if (ty.record.has_layout) child = ty.record.layout.required_alignment_bits / 8;
		default: break;
	}
	uint? own = qt.requested_alignment(comp);
	if (try o = own)
	{
		if (try c = child) return max(o, c); return o;
	}
	return child;
}

// The target-specific default caps for MSVC #pragma pack.
fn uint msvc_pragma_pack(Compilation* comp, uint pack, bool* has_cap)
{
	*has_cap = true;
	switch (pack)
	{
		case 8: return 8;
		case 16: return 16;
		case 32: return 32;
		case 64: if (comp.target.cpu.arch != X86) return 64; *has_cap = false; return 0;
		case 128: if (comp.target.cpu.arch == THUMB) return 128; *has_cap = false; return 0;
		default:
			if (comp.target.cpu.arch == THUMB || comp.target.cpu.arch == AARCH64) return 64;
			*has_cap = false; return 0;
	}
}

// Compute and store each field layout. A field with an invalid type is an
// incomplete declaration and is skipped, matching the parser's record model.
fn RecordLayout? compute(RecordField[] fields, NodeOptIndex opt_decl, bool is_union, Compilation* comp, AttributeMap* am, uint pragma_pack)
{
	bool packed = am.has_attribute(opt_decl, PACKED);
	uint requested = 1; uint? opt_requested = am.requested_alignment(opt_decl, comp); if (try r = opt_requested) requested = r;
	bool sysv = comp.langopts.emulate != MSVC && (comp.langopts.emulate == GCC || comp.target.abi != MSVC);
	if (sysv)
	{
		ulong size_bits = 0;
		uint aligned_bits = requested.overflow_mul(8)!;
		uint max_bits = pragma_pack.overflow_mul(8)!;
		OngoingBitfield ongoing = {};
		bool has_ongoing = false;
		foreach (&field : fields)
		{
			if (field.qt.is_invalid()) continue;
			RecordLayout layout = compute_layout(field.qt, comp)!;
			bool bitfield = field.bit_width != BIT_WIDTH_NULL;
			bool named = field.name_tok != (TokenIndex)0;
			bool field_packed = packed || am.has_attribute(field.field_decl, PACKED);
			uint anno = 0; uint? oa = am.requested_alignment(field.field_decl, comp); if (try a = oa) anno = a.overflow_mul(8)!;
			ulong field_align = layout.field_alignment_bits;
			ulong offset;
			ulong field_size = layout.size_bits;
			if (comp.target.is_mingw())
			{
				bool ignore_type_alignment = field_packed || (bitfield && has_ongoing && ongoing.size_bits == layout.size_bits) || (bitfield && field.bit_width == 0 && !has_ongoing);
				if (ignore_type_alignment) field_align = 8;
				field_align = max(field_align, max((ulong)8, anno));
				if (max_bits != 0) field_align = min(field_align, max_bits);
				bool affects_record_alignment = !bitfield || (field.bit_width == 0 && has_ongoing) || (field.bit_width != 0 && !field_packed);
				if (affects_record_alignment)
				{
					ulong ty_alignment = layout.field_alignment_bits;
					if (field_packed && (!bitfield || field.bit_width != 0)) ty_alignment = 8;
					ty_alignment = max(ty_alignment, max((ulong)8, anno));
					if (max_bits != 0) ty_alignment = min(ty_alignment, max_bits);
					aligned_bits = max(aligned_bits, (uint)ty_alignment);
				}
				if (bitfield)
				{
					uint width = field.bit_width;
					assert(width <= layout.size_bits, "validated bitfield width exceeds its type size");
					if (is_union)
					{
						size_bits = max(size_bits, width);
						offset = 0; field_size = width;
					}
					else if (width == 0)
					{
						has_ongoing = false;
						offset = record_align_forward(size_bits, field_align)!;
						size_bits = offset; field_size = 0;
					}
					else if (has_ongoing && ongoing.size_bits == layout.size_bits && ongoing.unused_size_bits >= width)
					{
						offset = size_bits - ongoing.unused_size_bits;
						ongoing.unused_size_bits -= width; field_size = width;
					}
					else
					{
						ongoing = { .size_bits = layout.size_bits, .unused_size_bits = layout.size_bits - width };
						has_ongoing = true;
						offset = record_align_forward(size_bits, field_align)!;
						size_bits = offset.overflow_add(layout.size_bits)!; field_size = width;
					}
				}
				else
				{
					has_ongoing = false;
					offset = 0; if (!is_union) offset = record_align_forward(size_bits, field_align)!;
					size_bits = max(size_bits, offset.overflow_add(field_size)!);
				}
				// The Zig implementation returns an empty FieldLayout for unnamed
				// bitfields after using their internal offset for subsequent fields.
				if (named || !bitfield)
				{
					field.layout = { .offset_bits = offset, .size_bits = field_size };
				}
				else
				{
					field.layout = {};
				}
				continue;
			}
			if (!bitfield)
			{
				if (field_packed) field_align = 8;
				field_align = max(field_align, anno);
				if (max_bits != 0) field_align = min(field_align, max_bits);
				offset = 0; if (!is_union) offset = record_align_forward(size_bits, field_align)!;
				size_bits = max(size_bits, offset.overflow_add(field_size)!);
				has_ongoing = false;
				aligned_bits = max(aligned_bits, (uint)field_align);
			}
			else
			{
				uint width = field.bit_width;
				assert(width <= layout.size_bits, "validated bitfield width exceeds its type size");
				ulong ty_align = layout.field_alignment_bits;
				if (width > 0 && comp.target.ignore_non_zero_sized_bitfield_type_alignment()) ty_align = 1;
				if (width == 0)
				{
					if (comp.target.ignore_zero_sized_bitfield_type_alignment()) ty_align = 1;
					ty_align = max(ty_align, comp.target.min_zero_width_bitfield_alignment());
				}
				ulong annotation = 1; if (anno != 0) annotation = anno;
				ulong bit_align = 1;
				if (width == 0)
				{
					bit_align = max(ty_align, annotation);
				}
				else
				{
					ulong first = size_bits; if (is_union) first = 0;
					bool has_pack = field_packed || max_bits != 0;
					if (comp.langopts.emulate == GCC)
					{
						bit_align = annotation;
						if (max_bits != 0) bit_align = min(bit_align, max_bits);
						ulong start = record_align_forward(first, bit_align)!;
						bool cross = start % ty_align + width > layout.size_bits;
						if (!has_pack && (ty_align > layout.size_bits || cross)) bit_align = max(bit_align, ty_align);
					}
					else
					{
						if (max_bits == 0 || annotation <= max_bits) bit_align = annotation;
						if (!has_pack && first % ty_align + width > layout.size_bits) bit_align = max(bit_align, ty_align);
					}
				}
				ulong first = size_bits; if (is_union) first = 0;
				offset = record_align_forward(first, bit_align)!;
				size_bits = max(size_bits, offset.overflow_add(width)!);
				if (named || comp.target.unnamed_field_affects_alignment())
				{
					ulong inherited = max(ty_align, annotation);
					if (width == 0)
					{
						inherited = max(ty_align, annotation);
					}
					else if (max_bits != 0)
					{
						inherited = min(inherited, max_bits);
					}
					else if (field_packed)
					{
						inherited = annotation;
					}
					aligned_bits = max(aligned_bits, (uint)inherited);
				}
				field_size = width;
			}
			if (named || !bitfield)
			{
				field.layout = { .offset_bits = offset, .size_bits = field_size };
			}
			else
			{
				field.layout = {};
			}
		}
		size_bits = record_align_forward(size_bits, aligned_bits)!;
		return { .size_bits = size_bits, .field_alignment_bits = aligned_bits, .pointer_alignment_bits = aligned_bits, .required_alignment_bits = 8 };
	}
	return compute_msvc(fields, opt_decl, is_union, comp, am, packed, requested, pragma_pack);
}

fn RecordLayout? compute_msvc(RecordField[] fields, NodeOptIndex decl, bool is_union, Compilation* comp, AttributeMap* am, bool packed, uint requested, uint pragma_pack)
{
	// MSVC distinguishes the record's required, pointer, and field alignment.
	uint req = requested.overflow_mul(8)!;
	uint ptr_align = req;
	uint field_align = req;
	uint input_cap = 0;
	if (packed)
	{
		input_cap = 8;
	}
	else if (pragma_pack != 0)
	{
		input_cap = pragma_pack.overflow_mul(8)!;
	}
	bool has_cap;
	uint cap = msvc_pragma_pack(comp, input_cap, &has_cap);
	ulong size = 0;
	bool has_regular = false;
	bool has_ongoing = false;
	OngoingBitfield ongoing = {};
	foreach (&field : fields)
	{
		if (field.qt.is_invalid()) continue;
		RecordLayout layout = compute_layout(field.qt, comp)!;
		uint annotation = 0; uint? oa = am.requested_alignment(field.field_decl, comp); if (try a = oa) annotation = a.overflow_mul(8)!;
		uint required = max(layout.required_alignment_bits, annotation);
		bool bitfield = field.bit_width != BIT_WIDTH_NULL;
		if (!bitfield) req = max(req, required);
		ulong fa = layout.field_alignment_bits;
		if (has_cap) fa = min(fa, cap);
		uint? type_alignment = field.qt.requested_alignment(comp); if (try a = type_alignment) fa = max(fa, a.overflow_mul(8)!);
		if (am.has_attribute(field.field_decl, PACKED)) fa = 8;
		fa = max(fa, required);
		ulong offset;
		ulong fsize = layout.size_bits;
		if (bitfield)
		{
			uint width = field.bit_width;
			assert(width <= layout.size_bits, "validated bitfield width exceeds its type size");
			if (width > 0 && !is_union && has_ongoing && ongoing.size_bits == layout.size_bits && ongoing.unused_size_bits >= width)
			{
				offset = size - ongoing.unused_size_bits;
				ongoing.unused_size_bits -= width;
				field.layout = { .offset_bits = offset, .size_bits = width };
				continue;
			}
			if (width == 0 && !has_ongoing)
			{
				field.layout = { .offset_bits = size, .size_bits = 0 }; continue;
			}
			if (width == 0)
			{
				has_ongoing = false;
			}
			else
			{
				ongoing = { .size_bits = layout.size_bits, .unused_size_bits = layout.size_bits - width }; has_ongoing = true;
			}
			if (is_union)
			{
				offset = 0; size = max(size, layout.size_bits);
			}
			else
			{
				uint p_align = (uint)fa; if (has_cap) p_align = min(cap, (uint)fa);
				ptr_align = max(ptr_align, p_align);
				field_align = max(field_align, (uint)fa);
				offset = record_align_forward(size, fa)!;
				if (width == 0)
				{
					size = offset;
				}
				else
				{
					size = offset.overflow_add(layout.size_bits)!;
				}
			}
			field.layout = { .offset_bits = offset, .size_bits = width };
		}
		else
		{
			has_regular = true; has_ongoing = false;
			ptr_align = max(ptr_align, (uint)fa); field_align = max(field_align, (uint)fa);
			offset = 0; if (!is_union) offset = record_align_forward(size, fa)!;
			size = max(size, offset.overflow_add(fsize)!);
			field.layout = { .offset_bits = offset, .size_bits = fsize };
		}
	}
	if (size == 0)
	{
		if (is_union)
		{
			if (has_regular)
			{
				size = field_align;
			} else
			{
				size = 32;
			}
		}
		else
		{
			size = max(req, (uint)32); ptr_align = min(ptr_align, (uint)size);
		}
	}
	size = record_align_forward(size, ptr_align)!;
	return { .size_bits = size, .field_alignment_bits = field_align, .pointer_alignment_bits = ptr_align, .required_alignment_bits = req };
}
