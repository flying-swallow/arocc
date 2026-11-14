// Direct ABI contract tests for aro::type_store.record_layout.compute.
// Inputs are hand-built; source-derived cases below model fixtures but do not
// parse or execute those C sources and do not claim compiler parity.
module record_layout_tests;
import aro::type_store, aro::target, aro::compilation, aro::lang_opts;
import aro::attribute, aro::attribute_map, aro::tokens;
import std::io, std::core::mem::allocators;

const Host HOST = { X86_64, LINUX, GNU };
const NodeOptIndex DECL = (NodeOptIndex)1;

fn Target tgt(String triple)
{
	Target? t = target::parse_triple(triple, HOST);
	if (catch f = t) { io::eprintfn("failed to parse target '%s': %s", triple, f); unreachable("target parse failed"); }
	return t;
}

macro check(left, right) { test::eq((long)left, (long)right); }

macro @with_target(String triple; @body(Compilation* comp, AttributeMap* am))
{
	TrackingAllocator ta;
	ta.init(mem);
	{
		Compilation comp;
		comp.init(&ta);
		comp.target = tgt(triple);
		comp.langopts.set_target_options(&comp.target);
		AttributeMap am;
		am.init(&ta);
		@body(&comp, &am);
		am.free();
		comp.free();
	}
	check(ta.allocation_count(), 0);
	ta.free();
}

fn RecordField rf(Compilation* comp, String name, QualType qt, uint width = type_store::BIT_WIDTH_NULL, NodeOptIndex decl = type_store::NODE_NULL)
{
	RecordField f = type_store::record_field(comp.intern_string(name), qt);
	f.name_tok = name.len == 0 ? (type_store::TokenIndex)0 : (type_store::TokenIndex)1;
	f.bit_width = width;
	f.field_decl = decl;
	return f;
}

fn Attribute attr(AttributeArgs args)
	=> { .args = args, .syntax = GNU, .name = { .ns = GNU, .gnu = PACKED }, .tok = (tokens::TokenIndex)17 };

fn void set_attr(AttributeMap* am, NodeIndex node, Attribute a)
{
	AttrRef[1] refs = { am.put(a) };
	am.set_decl_attrs(node, refs[..]);
}

fn void check_layout(RecordLayout r, ulong size, uint field_align, uint ptr_align, uint required)
{
	check(r.size_bits, size);
	check(r.field_alignment_bits, field_align);
	check(r.pointer_alignment_bits, ptr_align);
	check(r.required_alignment_bits, required);
}

fn void sysv_padding_and_union() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp, AttributeMap* am)
	{
		RecordField[3] fs = { rf(comp, "c", type_store::CHAR), rf(comp, "i", type_store::INT), rf(comp, "s", type_store::SHORT) };
		RecordLayout? maybe = type_store::compute(fs[..], DECL, false, comp, am, 0);
		RecordLayout r = maybe!!;
		check_layout(r, 96, 32, 32, 8);
		check(fs[0].layout.offset_bits, 0); check(fs[1].layout.offset_bits, 32); check(fs[2].layout.offset_bits, 64);
		check(fs[0].layout.size_bits, 8); check(fs[1].layout.size_bits, 32); check(fs[2].layout.size_bits, 16);

		RecordField[2] us = { rf(comp, "c", type_store::CHAR), rf(comp, "d", type_store::DOUBLE) };
		r = type_store::compute(us[..], DECL, true, comp, am, 0)!!;
		check_layout(r, 64, 64, 64, 8);
		check(us[0].layout.offset_bits, 0); check(us[1].layout.offset_bits, 0);
	};
}

fn void packed_aligned_and_pack_caps() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp, AttributeMap* am)
	{
		set_attr(am, (NodeIndex)1, attr({ .tag = PACKED }));
		RecordField[2] fs = { rf(comp, "c", type_store::CHAR), rf(comp, "i", type_store::INT) };
		RecordLayout r = type_store::compute(fs[..], DECL, false, comp, am, 0)!!;
		check_layout(r, 40, 8, 8, 8);
		check(fs[1].layout.offset_bits, 8);
	};
	@with_target("x86_64-linux-gnu"; Compilation* comp, AttributeMap* am)
	{
		set_attr(am, (NodeIndex)1, attr({ .tag = ALIGNMENT, .alignment = { .has_alignment = true, .alignment = 16 } }));
		RecordField[1] fs = { rf(comp, "c", type_store::CHAR) };
		RecordLayout r = type_store::compute(fs[..], DECL, false, comp, am, 0)!!;
		check_layout(r, 128, 128, 128, 8);
		check(fs[0].layout.offset_bits, 0);
	};
	@with_target("x86_64-windows-gnu"; Compilation* comp, AttributeMap* am)
	{
		RecordField[2] fs = { rf(comp, "c", type_store::CHAR), rf(comp, "i", type_store::INT) };
		RecordLayout r = type_store::compute(fs[..], DECL, false, comp, am, 2)!!;
		check_layout(r, 48, 16, 16, 8);
		check(fs[1].layout.offset_bits, 16);
	};
}

fn void mingw_and_msvc_policies() @test
{
	@with_target("x86_64-windows-gnu"; Compilation* comp, AttributeMap* am)
	{
		RecordField[2] fs = { rf(comp, "c", type_store::CHAR), rf(comp, "i", type_store::INT) };
		RecordLayout r = type_store::compute(fs[..], DECL, false, comp, am, 0)!!;
		check_layout(r, 64, 32, 32, 8); check(fs[1].layout.offset_bits, 32);
		RecordField[3] bits = { rf(comp, "a", type_store::UINT, 3), rf(comp, "", type_store::UINT, 0), rf(comp, "c", type_store::CHAR) };
		r = type_store::compute(bits[..], DECL, false, comp, am, 0)!!;
		check_layout(r, 64, 32, 32, 8);
		check(bits[0].layout.offset_bits, 0); check(bits[1].layout.offset_bits, 0); check(bits[1].layout.size_bits, 0); check(bits[2].layout.offset_bits, 32);
	};
	@with_target("x86_64-windows-msvc"; Compilation* comp, AttributeMap* am)
	{
		comp.langopts.set_emulated_compiler(MSVC);
		RecordField[2] fs = { rf(comp, "c", type_store::CHAR), rf(comp, "i", type_store::INT) };
		RecordLayout r = type_store::compute(fs[..], DECL, false, comp, am, 2)!!;
		check_layout(r, 48, 16, 16, 8); check(fs[1].layout.offset_bits, 16);
	};
	@with_target("x86_64-windows-msvc"; Compilation* comp, AttributeMap* am)
	{
		comp.langopts.set_emulated_compiler(MSVC);
		set_attr(am, (NodeIndex)1, attr({ .tag = ALIGNMENT, .alignment = { .has_alignment = true, .alignment = 16 } }));
		RecordField[1] fs = { rf(comp, "c", type_store::CHAR) };
		RecordLayout r = type_store::compute(fs[..], DECL, false, comp, am, 0)!!;
		check_layout(r, 128, 128, 128, 128);
	};
}

fn void bitfields_zero_width_and_union() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp, AttributeMap* am)
	{
		RecordField[3] fs = { rf(comp, "a", type_store::UINT, 3), rf(comp, "b", type_store::UINT, 5), rf(comp, "c", type_store::CHAR) };
		RecordLayout r = type_store::compute(fs[..], DECL, false, comp, am, 0)!!;
		// GCC/SysV: c packs into the bitfield unit's next byte (sizeof == 4, offsetof(c) == 1).
		check_layout(r, 32, 32, 32, 8);
		check(fs[0].layout.offset_bits, 0); check(fs[1].layout.offset_bits, 3); check(fs[2].layout.offset_bits, 8);
		RecordField[2] z = { rf(comp, "", type_store::UINT, 0), rf(comp, "x", type_store::CHAR) };
		r = type_store::compute(z[..], DECL, false, comp, am, 0)!!;
		// GCC: struct { unsigned :0; char x; } has sizeof == _Alignof == 1.
		check_layout(r, 8, 8, 8, 8);
		check(z[0].layout.offset_bits, 0); check(z[0].layout.size_bits, 0); check(z[1].layout.offset_bits, 0);
		RecordField[1] uf = { rf(comp, "bits", type_store::UINT, 3) };
		r = type_store::compute(uf[..], DECL, true, comp, am, 0)!!;
		check_layout(r, 32, 32, 32, 8); check(uf[0].layout.offset_bits, 0); check(uf[0].layout.size_bits, 3);
	};
}

fn void empty_flexible_nested_and_overflow() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp, AttributeMap* am)
	{
		RecordField[] empty;
		RecordLayout r = type_store::compute(empty, DECL, false, comp, am, 0)!!;
		check_layout(r, 0, 8, 8, 8);
		RecordField[2] uf = { rf(comp, "a", type_store::CHAR), rf(comp, "b", type_store::DOUBLE) };
		RecordLayout ur = type_store::compute(uf[..], DECL, true, comp, am, 0)!!;
		QualType uq = comp.type_store.put(type_store::type_record(comp.intern_string("U"), uf[..], ur, true));
		QualType flex = comp.type_store.put(type_store::type_array(type_store::CHAR, INCOMPLETE));
		RecordField[2] fs = { rf(comp, "u", uq), rf(comp, "tail", flex) };
		r = type_store::compute(fs[..], DECL, false, comp, am, 0)!!;
		check_layout(r, 64, 64, 64, 8); check(fs[0].layout.offset_bits, 0); check(fs[1].layout.offset_bits, 64);
		ulong? overflow = type_store::record_align_forward(ulong::max, 8);
		if (catch f = overflow) { assert(f == type_store::OVERFLOW); } else { assert(false, "alignment overflow must be reported"); }
		ulong? add_overflow = type_store::checked_add(ulong::max, 1);
		if (catch add_fault = add_overflow) { assert(add_fault == type_store::OVERFLOW); } else { assert(false, "addition overflow must be reported"); }
		ulong? mul_overflow = type_store::checked_mul(ulong::max, 8);
		if (catch mul_fault = mul_overflow) { assert(mul_fault == type_store::OVERFLOW); } else { assert(false, "multiplication overflow must be reported"); }
		uint? align_overflow = type_store::alignment_bits(0x2000_0000);
		if (catch align_fault = align_overflow) { assert(align_fault == type_store::OVERFLOW); } else { assert(false, "alignment conversion overflow must be reported"); }
	};
}

// Source-derived record models. These hand-built API inputs mirror declarations
// in the named C fixtures; they exercise record_layout.compute and do not
// execute the C fixtures or claim executable parity with their compilers.
fn void source_0023_aligned_record_and_nested_use() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp, AttributeMap* am)
	{
		set_attr(am, (NodeIndex)1, attr({ .tag = ALIGNMENT, .alignment = { .has_alignment = true, .alignment = 8 } }));
		// 0023: typedef struct { char c; } __attribute__((aligned(8))) A;
		RecordField[1] a_fields = { rf(comp, "c", type_store::CHAR) };
		RecordLayout a = type_store::compute(a_fields[..], DECL, false, comp, am, 0)!!;
		check_layout(a, 64, 64, 64, 8);
		check(a_fields[0].layout.offset_bits, 0); check(a_fields[0].layout.size_bits, 8);
		QualType aq = comp.type_store.put(type_store::type_record(comp.intern_string("A_0023"), a_fields[..], a));
		// A_extra_alignment contains char a; A b; its own record is unannotated.
		RecordField[2] outer = { rf(comp, "a", type_store::CHAR), rf(comp, "b", aq) };
		RecordLayout r = type_store::compute(outer[..], (NodeOptIndex)2, false, comp, am, 0)!!;
		check_layout(r, 128, 64, 64, 8);
		check(outer[0].layout.offset_bits, 0); check(outer[0].layout.size_bits, 8);
		check(outer[1].layout.offset_bits, 64); check(outer[1].layout.size_bits, 64);
	};
}

fn void source_0028_aligned_character_under_pack() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp, AttributeMap* am)
	{
		// 0028: aligned typedef Char, used after char c in A under #pragma pack(1).
		QualType aligned_char = comp.type_store.put(type_store::type_typedef(type_store::CHAR, comp.intern_string("Char_0028"), (NodeIndex)2));
		comp.type_store.set_requested_alignment(aligned_char, 4);
		RecordField[2] fs = { rf(comp, "c", type_store::CHAR), rf(comp, "a", aligned_char) };
		RecordLayout r = type_store::compute(fs[..], DECL, false, comp, am, 1)!!;
		check_layout(r, 16, 8, 8, 8);
		check(fs[0].layout.offset_bits, 0); check(fs[0].layout.size_bits, 8);
		check(fs[1].layout.offset_bits, 8); check(fs[1].layout.size_bits, 8);
	};
}

fn void source_0029_aligned_typedef_field() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp, AttributeMap* am)
	{
		// 0029: A is a one-field struct containing Char, aligned(4) typedef char.
		QualType aligned_char = comp.type_store.put(type_store::type_typedef(type_store::CHAR, comp.intern_string("Char_0029"), (NodeIndex)2));
		comp.type_store.set_requested_alignment(aligned_char, 4);
		RecordField[1] fs = { rf(comp, "a", aligned_char) };
		RecordLayout r = type_store::compute(fs[..], DECL, false, comp, am, 0)!!;
		check_layout(r, 32, 32, 32, 8);
		check(fs[0].layout.offset_bits, 0); check(fs[0].layout.size_bits, 8);
	};
}

fn void source_0056_packed_attribute_record() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp, AttributeMap* am)
	{
		set_attr(am, (NodeIndex)1, attr({ .tag = PACKED }));
		// 0056 defines both a packed struct { int i; } A and packed union { int i; } B.
		RecordField[1] fs = { rf(comp, "i", type_store::INT) };
		RecordLayout r = type_store::compute(fs[..], DECL, false, comp, am, 0)!!;
		check_layout(r, 32, 8, 8, 8);
		check(fs[0].layout.offset_bits, 0); check(fs[0].layout.size_bits, 32);
		RecordLayout u = type_store::compute(fs[..], DECL, true, comp, am, 0)!!;
		check_layout(u, 32, 8, 8, 8);
		check(fs[0].layout.offset_bits, 0); check(fs[0].layout.size_bits, 32);
	};
}

fn void source_0057_pragma_packed_aligned_field_model() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp, AttributeMap* am)
	{
		// 0057 A: #pragma pack(2), char c, then packed int i.
		set_attr(am, (NodeIndex)2, attr({ .tag = PACKED }));
		RecordField[2] fs = { rf(comp, "c", type_store::CHAR), rf(comp, "i", type_store::INT, type_store::BIT_WIDTH_NULL, (NodeOptIndex)2) };
		RecordLayout r = type_store::compute(fs[..], DECL, false, comp, am, 2)!!;
		check_layout(r, 40, 8, 8, 8);
		check(fs[0].layout.offset_bits, 0); check(fs[0].layout.size_bits, 8);
		check(fs[1].layout.offset_bits, 8); check(fs[1].layout.size_bits, 32);
	};
}

fn void source_0068_aligned_zero_width_character_fields() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp, AttributeMap* am)
	{
		// 0068 A and A_: an aligned zero-width char bitfield, with A_ also
		// carrying a preceding char. The unnamed field's alignment affects its
		// offset but not the record alignment on this target.
		set_attr(am, (NodeIndex)2, attr({ .tag = ALIGNMENT, .alignment = { .has_alignment = true, .alignment = 4 } }));
		RecordField[2] fs = { rf(comp, "", type_store::CHAR, 0, (NodeOptIndex)2), rf(comp, "d", type_store::CHAR) };
		RecordLayout r = type_store::compute(fs[..], DECL, false, comp, am, 0)!!;
		check_layout(r, 8, 8, 8, 8);
		check(fs[0].layout.offset_bits, 0); check(fs[0].layout.size_bits, 0);
		check(fs[1].layout.offset_bits, 0); check(fs[1].layout.size_bits, 8);
		// 0068 A_ inserts char c before the same zero-width field.
		RecordField[3] with_prefix = { rf(comp, "c", type_store::CHAR), rf(comp, "", type_store::CHAR, 0, (NodeOptIndex)2), rf(comp, "d", type_store::CHAR) };
		r = type_store::compute(with_prefix[..], (NodeOptIndex)3, false, comp, am, 0)!!;
		check_layout(r, 40, 8, 8, 8);
		check(with_prefix[0].layout.offset_bits, 0); check(with_prefix[0].layout.size_bits, 8);
		check(with_prefix[1].layout.offset_bits, 0); check(with_prefix[1].layout.size_bits, 0);
		check(with_prefix[2].layout.offset_bits, 32); check(with_prefix[2].layout.size_bits, 8);
	};
}

fn void msvc_pragma_pack_arch_policies() @test
{
	// x86 rejects the 64/128 pack modes; ordinary 8/16/32 overrides cap field
	// alignment. The eight-byte long long keeps the capped offsets observable.
	@with_target("i686-windows-msvc"; Compilation* comp, AttributeMap* am)
	{
		comp.langopts.set_emulated_compiler(MSVC);
		RecordField[2] fs = { rf(comp, "c", type_store::CHAR), rf(comp, "ll", type_store::LONG_LONG) };
		RecordLayout r = type_store::compute(fs[..], DECL, false, comp, am, 1)!!;
		check_layout(r, 72, 8, 8, 8); check(fs[1].layout.offset_bits, 8); check(fs[1].layout.size_bits, 64);
		check(fs[0].layout.offset_bits, 0); check(fs[0].layout.size_bits, 8);
		fs[0] = rf(comp, "c", type_store::CHAR); fs[1] = rf(comp, "ll", type_store::LONG_LONG);
		r = type_store::compute(fs[..], DECL, false, comp, am, 2)!!;
		check_layout(r, 80, 16, 16, 8); check(fs[1].layout.offset_bits, 16); check(fs[1].layout.size_bits, 64);
		check(fs[0].layout.offset_bits, 0); check(fs[0].layout.size_bits, 8);
		fs[0] = rf(comp, "c", type_store::CHAR); fs[1] = rf(comp, "ll", type_store::LONG_LONG);
		r = type_store::compute(fs[..], DECL, false, comp, am, 4)!!;
		check_layout(r, 96, 32, 32, 8); check(fs[1].layout.offset_bits, 32); check(fs[1].layout.size_bits, 64);
		check(fs[0].layout.offset_bits, 0); check(fs[0].layout.size_bits, 8);
		foreach (uint pack : { 0, 8, 16 })
		{
			fs[0] = rf(comp, "c", type_store::CHAR); fs[1] = rf(comp, "ll", type_store::LONG_LONG);
			r = type_store::compute(fs[..], DECL, false, comp, am, pack)!!;
			check_layout(r, 128, 64, 64, 8); check(fs[1].layout.offset_bits, 64); check(fs[1].layout.size_bits, 64);
			check(fs[0].layout.offset_bits, 0); check(fs[0].layout.size_bits, 8);
		}
	};

	@with_target("x86_64-windows-msvc"; Compilation* comp, AttributeMap* am)
	{
		comp.langopts.set_emulated_compiler(MSVC);
		// AArch64-style 128-bit long double is not available here; 8/16/32/64
		// modes still assert the x64 policy's natural and explicit caps.
		foreach (uint pack : { 0, 1, 2, 4, 8, 16 })
		{
			RecordField[2] fs = { rf(comp, "c", type_store::CHAR), rf(comp, "d", type_store::DOUBLE) };
			RecordLayout r = type_store::compute(fs[..], DECL, false, comp, am, pack)!!;
			ulong expected_offset = pack == 1 ? 8 : pack == 2 ? 16 : pack == 4 ? 32 : 64;
			ulong expected_size = expected_offset + 64;
			uint expected_align = pack == 1 ? 8 : pack == 2 ? 16 : pack == 4 ? 32 : 64;
			check_layout(r, expected_size, expected_align, expected_align, 8);
			check(fs[0].layout.offset_bits, 0); check(fs[0].layout.size_bits, 8);
			check(fs[1].layout.offset_bits, expected_offset); check(fs[1].layout.size_bits, 64);
		}
	};

	@with_target("armv7-windows-msvc"; Compilation* comp, AttributeMap* am)
	{
		comp.langopts.set_emulated_compiler(MSVC);
		RecordField[2] fs = { rf(comp, "c", type_store::CHAR), rf(comp, "d", type_store::DOUBLE) };
		foreach (uint pack : { 0, 1, 2, 4, 8, 16 })
		{
			fs[0] = rf(comp, "c", type_store::CHAR); fs[1] = rf(comp, "d", type_store::DOUBLE);
			RecordLayout r = type_store::compute(fs[..], DECL, false, comp, am, pack)!!;
			ulong expected_offset = pack == 1 ? 8 : pack == 2 ? 16 : pack == 4 ? 32 : 64;
			uint expected_align = pack == 1 ? 8 : pack == 2 ? 16 : pack == 4 ? 32 : 64;
			check_layout(r, expected_offset + 64, expected_align, expected_align, 8);
			check(fs[0].layout.offset_bits, 0); check(fs[0].layout.size_bits, 8);
			check(fs[1].layout.offset_bits, expected_offset); check(fs[1].layout.size_bits, 64);
		}
	};

	@with_target("thumbv7a-windows-msvc"; Compilation* comp, AttributeMap* am)
	{
		comp.langopts.set_emulated_compiler(MSVC);
		foreach (uint pack : { 0, 1, 2, 4, 8, 16 })
		{
			RecordField[2] fs = { rf(comp, "c", type_store::CHAR), rf(comp, "ld", type_store::LONG_DOUBLE) };
			RecordLayout r = type_store::compute(fs[..], DECL, false, comp, am, pack)!!;
			// Zig msvcPragmaPack keeps explicit 8/16/32-bit caps on every arch.
			ulong expected_offset = pack == 1 ? 8 : pack == 2 ? 16 : pack == 4 ? 32 : 64;
			uint expected_align = pack == 1 ? 8 : pack == 2 ? 16 : pack == 4 ? 32 : 64;
			check_layout(r, expected_offset + 64, expected_align, expected_align, 8);
			check(fs[0].layout.offset_bits, 0); check(fs[0].layout.size_bits, 8);
			check(fs[1].layout.offset_bits, expected_offset); check(fs[1].layout.size_bits, 64);
		}
	};

	@with_target("aarch64-windows-msvc"; Compilation* comp, AttributeMap* am)
	{
		comp.langopts.set_emulated_compiler(MSVC);
		foreach (uint pack : { 0, 1, 2, 4, 8, 16 })
		{
			RecordField[2] fs = { rf(comp, "c", type_store::CHAR), rf(comp, "ld", type_store::LONG_DOUBLE) };
			RecordLayout r = type_store::compute(fs[..], DECL, false, comp, am, pack)!!;
			// Windows long double is 64-bit (std.Target.cTypeBitSize), and a 128-bit
			// pack is not a valid cap off thumb (Zig msvcPragmaPack), so 64 is the ceiling.
			ulong expected_offset = pack == 1 ? 8 : pack == 2 ? 16 : pack == 4 ? 32 : 64;
			uint expected_align = pack == 1 ? 8 : pack == 2 ? 16 : pack == 4 ? 32 : 64;
			check_layout(r, expected_offset + 64, expected_align, expected_align, 8);
			check(fs[0].layout.offset_bits, 0); check(fs[0].layout.size_bits, 8);
			check(fs[1].layout.offset_bits, expected_offset); check(fs[1].layout.size_bits, 64);
		}
	};
}
