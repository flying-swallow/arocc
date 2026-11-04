// End-to-end tests of number_value::parse_number_token, which runs
// number_literal's NumberLiteralParser (plan 11 agent 11.1) first. Tagged
// "manual" until 11.1's syntax parser is merged; the integrator should drop
// the tag then. Expected values: see number_value_tests.c3 for the labels.
module number_value_manual_tests;
import aro::number_value, aro::number_literal, aro::value, aro::value_interner, aro::float_value;
import aro::compilation, aro::diagnostics, aro::source, aro::target, aro::type_store, aro::lang_opts;
import std::io, std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

const Host HOST = { X86_64, LINUX, GNU };

macro @with_comp(String triple, Compiler emu = NO; @body(Compilation* comp, Diagnostics* d))
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		comp.target = target::parse_triple(triple, HOST)!!;
		comp.langopts.set_target_options(&comp.target);
		comp.langopts.set_emulated_compiler(emu);
		type_store::init_named_types(&comp);
		@body(&comp, &d);
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn NumberValue tok(Compilation* comp, String text)
{
	Source src = comp.add_source_from_buffer("lit.c", text)!!;
	Location loc = { .id = src.id, .byte_offset = 0, .line = 1 };
	return number_value::parse_number_token(comp, text, loc, {})!!;
}

fn void end_to_end() @test
{
	// [fixture integer literal promotion warning gcc 64.c]
	@with_comp("x86_64-linux-gnu", GCC; Compilation* comp, Diagnostics* d)
	{
		NumberValue v = tok(comp, "18446744073709550592");
		assert(v.qt == type_store::INT128);
		check(v.diags.len, 1);
		assert(v.diags.items[0] == IMPLICITLY_UNSIGNED_LITERAL);
	};
	@with_comp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		// [fixture implicitly unsigned literal.c] / [fixture enum sizes linux.c]
		assert(tok(comp, "0xFFFFFFFFFFFFFFFF").qt == type_store::ULONG);
		assert(tok(comp, "18446744073709551615ULL").qt == type_store::ULONG_LONG);
		assert(tok(comp, "2147483648").qt == type_store::LONG);
		// [fixture __float80.c]
		NumberValue v = tok(comp, "1.0iW");
		assert(v.is_imaginary && v.literal_qt == type_store::LONG_DOUBLE);
		v = tok(comp, "1.0w");
		assert(v.qt == type_store::LONG_DOUBLE && !v.is_imaginary);
		// [fixture imaginary constants.c]
		v = tok(comp, "1uli");
		assert(v.is_imaginary && v.literal_qt == type_store::ULONG);
		// [fixture c23 digit separators.c]
		v = tok(comp, "0b1001'0110");
		check(v.val.to_u64(comp)!!, 150);
		v = tok(comp, "0x1.ep-1");
		InternerKey k = comp.interner.get(v.val.ref());
		check(k.float_val.f64, 0x3FEE_0000_0000_0000);
		// [fixture float types.c]
		assert(tok(comp, "1.0bf16").qt == type_store::BF16);
		assert(tok(comp, "1.0f32x").qt == type_store::FLOAT32X);
		check(d.messages.len(), 0);
	};
	// [fixture _BitInt.c]: 2wb
	@with_comp("x86_64-linux-gnu"; Compilation* comp, Diagnostics* d)
	{
		comp.langopts.standard = C23;
		NumberValue v = tok(comp, "2wb");
		Type ty = v.qt.base(comp).ty;
		assert(ty.tag == BIT_INT);
		check(ty.bit_int.bits, 3);
	};
}
