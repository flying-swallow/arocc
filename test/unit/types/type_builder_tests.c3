module type_builder_tests;
import aro::frontend::c::type_store, aro::target, aro::frontend::c::compilation, aro::frontend::c::parser;
import aro::frontend::c::diagnostics, aro::frontend::c::preprocessor, aro::frontend::c::lang_opts;
import std::core::mem::allocators;

const Host HOST = { X86_64, LINUX, GNU };

macro @with_comp(; @body(Compilation* comp))
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	Compilation comp;
	comp.init(&ta);
	comp.target = target::parse_triple("x86_64-linux-gnu", HOST)!!;
	comp.langopts.set_target_options(&comp.target);
	@body(&comp);
	comp.free();
	test::eq((long)ta.allocation_count(), 0);
}

macro @with_parser(; @body(Compilation* comp, Parser* p, Diagnostics* d))
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		comp.target = target::parse_triple("x86_64-linux-gnu", HOST)!!;
		comp.langopts.set_target_options(&comp.target);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		Parser p;
		p.init(&pp, {});
		@body(&comp, &p, &d);
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	test::eq((long)ta.allocation_count(), 0);
}

fn void typedef_adoption_requires_an_empty_type() @test
{
	@with_comp(; Compilation* comp)
	{
		QualType alias_type = comp.type_store.put(type_store::type_typedef(
			type_store::INT, comp.intern_string("my_int"), (NodeIndex)0));
		Builder b;
		assert(b.combine_typedef(alias_type));
		assert(b.is_typedef);
		assert(b.type.tag == OTHER && b.type.other == alias_type);
		assert(!b.combine_typedef(type_store::UINT));
		assert(b.type.other == alias_type);
	};
}

fn void bit_int_type_mapping_preserves_width_and_signedness() @test
{
	@with_comp(; Compilation* comp)
	{
		foreach (bits : (ushort[]){ 1, 8, 65, 65535 })
		{
			foreach (sign : (Signedness[]){ SIGNED, UNSIGNED })
			{
				QualType qt = comp.type_store.put(type_store::type_bit_int(bits, sign));
				BuilderSpecifier spec = type_store::builder_from_type(comp, qt);
				assert(spec.bits == bits);
				assert(spec.tag == (sign == UNSIGNED ? UBIT_INT : BIT_INT));
			};
		};
	};
}

fn void complex_mapping_and_qualifier_state_are_explicit() @test
{
	@with_comp(; Compilation* comp)
	{
		BuilderSpecifier mapped = type_store::builder_from_type(comp, type_store::INT);
		BuilderSpecifier complex = type_store::builder_as_complex(mapped);
		assert(complex.tag == COMPLEX_INT);
		parser::Parser p = { .comp = comp };
		Builder b = { .parser = &p, .has_const = true, .has_volatile = true };
		QualType qualified = b.finish_quals(type_store::INT)!!;
		assert(qualified.is_const && qualified.is_volatile);
		assert(!qualified.is_restrict);
	};
}

fn void combine_and_finish_integer_and_complex_specs() @test
{
	@with_comp(; Compilation* comp)
	{
		parser::Parser p = { .comp = comp };
		Builder integer = { .parser = &p };
		integer.combine({ .tag = SIGNED }, 0)!!;
		integer.combine({ .tag = LONG }, 0)!!;
		integer.combine({ .tag = INT }, 0)!!;
		assert(integer.type.tag == SLONG_INT);
		assert(integer.finish()!!.eql(type_store::LONG, comp));

		Builder complex = { .parser = &p };
		complex.combine({ .tag = COMPLEX }, 0)!!;
		complex.combine({ .tag = FLOAT }, 0)!!;
		assert(complex.type.tag == COMPLEX_FLOAT);
		assert(complex.finish()!!.eql(type_store::FLOAT.to_complex(comp), comp));
	};
}

fn void finish_validates_bit_int_and_restrict_qualifier_targets() @test
{
	@with_comp(; Compilation* comp)
	{
		parser::Parser p = { .comp = comp };
		Builder bitint = { .parser = &p };
		bitint.combine({ .tag = BIT_INT, .bits = 65 }, 0)!!;
		QualType bitint_qt = bitint.finish()!!;
		assert(bitint_qt.is(comp, TypeTag.BIT_INT));
		assert(bitint_qt.get_type(comp).bit_int.bits == 65);

		Builder restrict_ptr = { .parser = &p, .has_restrict = true };
		QualType pointer_qt = restrict_ptr.finish_quals(comp.type_store.put(type_store::type_pointer(type_store::INT)))!!;
		assert(pointer_qt.is_restrict);
	};
}

fn void combine_reports_duplicate_conflict_typedef_and_typeof_combinations() @test
{
	@with_parser(; Compilation* comp, Parser* p, Diagnostics* d)
	{
		Builder duplicate = { .parser = p };
		duplicate.combine({ .tag = SIGNED }, 0)!!;
		duplicate.combine({ .tag = SIGNED }, 0)!!;
		assert(d.messages.len() == 1);
		assert(d.messages[0].text == "duplicate 'signed' declaration specifier");

		Builder conflict = { .parser = p };
		conflict.combine({ .tag = INT }, 0)!!;
		conflict.combine({ .tag = DOUBLE }, 0)!!;
		assert(d.messages.len() == 2);
		assert(d.messages[1].text == "cannot combine with previous 'int' specifier");

		Builder typedef_builder = { .parser = p };
		assert(typedef_builder.combine_typedef(type_store::INT));
		typedef_builder.combine({ .tag = INT }, 0)!!;
		assert(d.messages.len() == 3);

		Builder typeof_builder = { .parser = p };
		typeof_builder.combine_from_typeof(type_store::INT, 0)!!;
		typeof_builder.combine({ .tag = INT }, 0)!!;
		assert(d.messages.len() == 4);
		assert(d.messages[3].text == "'int typeof' is invalid");

		Builder ll_typeof = { .parser = p };
		ll_typeof.combine({ .tag = LONG_LONG }, 0)!!;
		ll_typeof.combine_from_typeof(type_store::INT, 0)!!;
		assert(d.messages.len() == 5);
		assert(d.messages[4].text == "'long_long typeof' is invalid");

		Builder complex_ll_typeof = { .parser = p };
		complex_ll_typeof.combine({ .tag = COMPLEX_LONG_LONG }, 0)!!;
		complex_ll_typeof.combine_from_typeof(type_store::INT, 0)!!;
		assert(d.messages.len() == 6);
		assert(d.messages[5].text == "'complex_long_long typeof' is invalid");
	};
}

fn void cannot_combine_other_preserves_const_qualifier() @test
{
	@with_parser(; Compilation* comp, Parser* p, Diagnostics* d)
	{
		Builder b = { .parser = p, .has_const = true };
		b.combine({ .tag = OTHER, .other = type_store::INT }, 0)!!;
		b.combine({ .tag = INT }, 0)!!;
		assert(d.messages.len() == 1);
		assert(d.messages[0].text == "cannot combine with previous 'const int' specifier");
	};
}

fn void cannot_combine_other_reports_restrict_target_and_base_type() @test
{
	@with_parser(; Compilation* comp, Parser* p, Diagnostics* d)
	{
		Builder b = { .parser = p, .has_restrict = true, .restrict_tok = 0 };
		b.combine({ .tag = OTHER, .other = type_store::INT }, 0)!!;
		b.combine({ .tag = INT }, 0)!!;
		assert(d.messages.len() == 2);
		assert(d.messages[0].text == "restrict requires a pointer or reference ('int' is invalid)");
		assert(d.messages[1].text == "cannot combine with previous 'int' specifier");
	};
}

fn void cannot_combine_other_reports_atomic_incomplete_and_invalid_type() @test
{
	@with_parser(; Compilation* comp, Parser* p, Diagnostics* d)
	{
		Builder b = { .parser = p, .has_atomic = true, .atomic_tok = 0 };
		b.combine({ .tag = OTHER, .other = type_store::VOID }, 0)!!;
		b.combine({ .tag = INT }, 0)!!;
		assert(d.messages.len() == 2);
		assert(d.messages[0].text == "_Atomic cannot be applied to incomplete type 'void'");
		assert(d.messages[1].text == "cannot combine with previous 'invalid' specifier");
	};
}

fn void finish_checks_bit_int_limits_atomic_completeness_and_restrict_targets() @test
{
	@with_parser(; Compilation* comp, Parser* p, Diagnostics* d)
	{
		Builder small = { .parser = p };
		small.combine({ .tag = BIT_INT, .bits = 1 }, 0)!!;
		assert(small.finish()!!.is_invalid());
		assert(d.messages.len() == 1);

		Builder large = { .parser = p };
		large.combine({ .tag = UNSIGNED }, 0)!!;
		large.combine({ .tag = BIT_INT, .bits = 65536 }, 0)!!;
		assert(large.finish()!!.is_invalid());
		assert(d.messages.len() == 2);

		QualType incomplete = comp.type_store.put(type_store::type_record_incomplete(comp.intern_string("Incomplete")));
		Builder atomic_incomplete = { .parser = p, .has_atomic = true, .atomic_tok = 0 };
		assert(atomic_incomplete.finish_quals(incomplete)!!.is_invalid());
		assert(d.messages.len() == 3);

		Builder bad_restrict = { .parser = p, .has_restrict = true, .restrict_tok = 0 };
		QualType still_int = bad_restrict.finish_quals(type_store::INT)!!;
		assert(still_int == type_store::INT);
		assert(d.messages.len() == 4);

		Builder atomic = { .parser = p };
		atomic.combine_atomic(type_store::INT, 0)!!;
		assert(atomic.has_atomic_type_tok);
		assert(atomic.finish()!!.get_type(comp).tag == ATOMIC);

		Builder complex_bitint = { .parser = p };
		complex_bitint.combine({ .tag = COMPLEX }, 0)!!;
		complex_bitint.combine({ .tag = BIT_INT, .bits = 8 }, 0)!!;
		assert(complex_bitint.finish()!!.is_invalid());
		assert(d.messages.len() == 5);
	};
}

fn void finish_restrict_on_auto_type_is_todo_fault() @test
{
	@with_parser(; Compilation* comp, Parser* p, Diagnostics* d)
	{
		Builder auto_restrict = { .parser = p, .has_restrict = true, .restrict_tok = 0 };
		assert(@catch(auto_restrict.finish_quals(type_store::AUTO_TYPE)) == parser::PARSING_FAILED);
		assert(d.messages.len() == 1);
		assert(d.messages[0].text == "TODO: restrict __auto_type");
	};
}

fn void finish_restrict_on_c23_auto_reports_invalid_qualifier() @test
{
	@with_parser(; Compilation* comp, Parser* p, Diagnostics* d)
	{
		Builder auto_restrict = { .parser = p, .has_restrict = true, .restrict_tok = 0 };
		QualType qualified_auto = auto_restrict.finish_quals(type_store::C23_AUTO)!!;
		assert(qualified_auto == type_store::C23_AUTO || qualified_auto.is_c23_auto());
		assert(d.messages.len() == 1);
		assert(d.messages[0].text == "restrict requires a pointer or reference ('auto' is invalid)");
	};
}

fn void combine_tags(Builder* b, BuilderSpecifierTag... tags)
{
	foreach (tag : tags)
	{
		b.combine({ .tag = tag }, 0)!!;
	}
}

fn void expect_seeded_transition_error(Parser* p, Diagnostics* d, BuilderSpecifierTag previous,
		BuilderSpecifierTag incoming, String diagnostic)
{
	Builder b = { .parser = p, .type = { .tag = previous } };
	long diagnostic_index = d.messages.len();
	b.combine({ .tag = incoming }, 0)!!;
	assert(b.type.tag == previous);
	assert(d.messages.len() == diagnostic_index + 1);
	assert(d.messages[(usz)diagnostic_index].text == diagnostic);
}

fn void char_combines_after_complex_signedness() @test
{
	@with_parser(; Compilation* comp, Parser* p, Diagnostics* d)
	{
		Builder signed_char = { .parser = p };
		combine_tags(&signed_char, COMPLEX, SIGNED);
		signed_char.combine({ .tag = CHAR }, 0)!!;
		assert(signed_char.type.tag == SCHAR);

		Builder unsigned_char = { .parser = p };
		combine_tags(&unsigned_char, COMPLEX, UNSIGNED);
		unsigned_char.combine({ .tag = CHAR }, 0)!!;
		assert(unsigned_char.type.tag == UCHAR);

		assert(d.messages.len() == 0);
	};
}

fn void long_long_combines_after_signed_unsigned_int_and_long() @test
{
	@with_parser(; Compilation* comp, Parser* p, Diagnostics* d)
	{
		Builder signed_ll = { .parser = p };
		combine_tags(&signed_ll, SIGNED, LONG_LONG);
		assert(signed_ll.type.tag == SLONG_LONG);

		Builder unsigned_ll = { .parser = p };
		combine_tags(&unsigned_ll, UNSIGNED, LONG_LONG);
		assert(unsigned_ll.type.tag == ULONG_LONG);

		Builder int_ll = { .parser = p };
		combine_tags(&int_ll, INT, LONG_LONG);
		assert(int_ll.type.tag == LONG_LONG_INT);

		Builder sint_ll = { .parser = p };
		combine_tags(&sint_ll, SIGNED, INT, LONG_LONG);
		assert(sint_ll.type.tag == SLONG_LONG_INT);

		Builder long_ll = { .parser = p };
		combine_tags(&long_ll, LONG, LONG_LONG);
		assert(long_ll.type.tag == LONG_LONG);

		Builder slong_ll = { .parser = p };
		combine_tags(&slong_ll, LONG, SIGNED, LONG_LONG);
		assert(slong_ll.type.tag == SLONG_LONG);

		Builder ll_signed = { .parser = p };
		combine_tags(&ll_signed, LONG_LONG, SIGNED);
		assert(ll_signed.type.tag == SLONG_LONG);

		Builder ll_unsigned = { .parser = p };
		combine_tags(&ll_unsigned, LONG_LONG, UNSIGNED);
		assert(ll_unsigned.type.tag == ULONG_LONG);

		Builder ll_int = { .parser = p };
		combine_tags(&ll_int, LONG_LONG, INT);
		assert(ll_int.type.tag == LONG_LONG_INT);

		assert(d.messages.len() == 0);
	};
}

fn void long_long_combines_after_complex_integer_forms() @test
{
	@with_parser(; Compilation* comp, Parser* p, Diagnostics* d)
	{
		Builder c_signed = { .parser = p };
		combine_tags(&c_signed, COMPLEX, SIGNED, LONG_LONG);
		assert(c_signed.type.tag == COMPLEX_SLONG_LONG);

		Builder c_unsigned = { .parser = p };
		combine_tags(&c_unsigned, COMPLEX, UNSIGNED, LONG_LONG);
		assert(c_unsigned.type.tag == COMPLEX_ULONG_LONG);

		Builder c_long = { .parser = p };
		combine_tags(&c_long, COMPLEX, LONG, LONG_LONG);
		assert(c_long.type.tag == COMPLEX_LONG_LONG);

		Builder c_slong = { .parser = p };
		combine_tags(&c_slong, COMPLEX, SIGNED, LONG);
		assert(c_slong.type.tag == COMPLEX_SLONG);
		c_slong.combine({ .tag = LONG_LONG }, 0)!!;
		assert(c_slong.type.tag == COMPLEX_SLONG_LONG);

		Builder c_ulong = { .parser = p };
		combine_tags(&c_ulong, COMPLEX, UNSIGNED, LONG);
		assert(c_ulong.type.tag == COMPLEX_ULONG);
		c_ulong.combine({ .tag = LONG_LONG }, 0)!!;
		assert(c_ulong.type.tag == COMPLEX_ULONG_LONG);

		Builder ll_complex = { .parser = p };
		combine_tags(&ll_complex, LONG_LONG, COMPLEX);
		assert(ll_complex.type.tag == COMPLEX_LONG_LONG);

		assert(d.messages.len() == 0);
	};
}

// Preserve TypeStore.zig's current mapping: COMPLEX + LONG_LONG produces
// COMPLEX_LONG rather than COMPLEX_LONG_LONG.
fn void complex_then_long_long_mirrors_zig_complex_long() @test
{
	@with_parser(; Compilation* comp, Parser* p, Diagnostics* d)
	{
		Builder b = { .parser = p };
		combine_tags(&b, COMPLEX, LONG_LONG);
		assert(b.type.tag == COMPLEX_LONG);
		assert(d.messages.len() == 0);
	};
}

fn void long_and_long_long_duplicate_versus_cannot_combine() @test
{
	@with_parser(; Compilation* comp, Parser* p, Diagnostics* d)
	{
		// LONG_LONG after LONG_LONG is a repeated 'long': duplicate.
		Builder dup_ll = { .parser = p };
		combine_tags(&dup_ll, LONG_LONG);
		dup_ll.combine({ .tag = LONG_LONG }, 0)!!;
		assert(dup_ll.type.tag == LONG_LONG);
		assert(d.messages.len() == 1);
		assert(d.messages[0].text == "duplicate 'long' declaration specifier");

		// LONG after LONG_LONG: Zig's `.long` switch has no duplicate arm, so cannot-combine.
		Builder ll_then_long = { .parser = p };
		combine_tags(&ll_then_long, LONG_LONG);
		ll_then_long.combine({ .tag = LONG }, 0)!!;
		assert(ll_then_long.type.tag == LONG_LONG);
		assert(d.messages.len() == 2);
		assert(d.messages[1].text == "cannot combine with previous 'long long' specifier");

		// Two LONGs make LONG_LONG; a third LONG is cannot-combine, not duplicate.
		Builder triple = { .parser = p };
		combine_tags(&triple, LONG, LONG);
		assert(triple.type.tag == LONG_LONG);
		assert(d.messages.len() == 2);
		triple.combine({ .tag = LONG }, 0)!!;
		assert(triple.type.tag == LONG_LONG);
		assert(d.messages.len() == 3);
		assert(d.messages[2].text == "cannot combine with previous 'long long' specifier");

		// ULONG_LONG is in Zig's duplicate arm for LONG_LONG.
		Builder ull_dup = { .parser = p };
		combine_tags(&ull_dup, UNSIGNED, LONG, LONG);
		assert(ull_dup.type.tag == ULONG_LONG);
		ull_dup.combine({ .tag = LONG_LONG }, 0)!!;
		assert(ull_dup.type.tag == ULONG_LONG);
		assert(d.messages.len() == 4);
		assert(d.messages[3].text == "duplicate 'long' declaration specifier");

		// _Complex long long then LONG: cannot-combine, spelled with _Complex.
		Builder complex_ll = { .parser = p };
		combine_tags(&complex_ll, COMPLEX, LONG, LONG);
		assert(complex_ll.type.tag == COMPLEX_LONG_LONG);
		complex_ll.combine({ .tag = LONG }, 0)!!;
		assert(complex_ll.type.tag == COMPLEX_LONG_LONG);
		assert(d.messages.len() == 5);
		assert(d.messages[4].text == "cannot combine with previous '_Complex long long' specifier");
	};
}

fn void remaining_long_long_transitions_match_zig_switch_arms() @test
{
	@with_parser(; Compilation* comp, Parser* p, Diagnostics* d)
	{
		// UNSIGNED + LONG produces ULONG, which LONG_LONG then promotes to ULONG_LONG.
		Builder ulong_long = { .parser = p };
		combine_tags(&ulong_long, UNSIGNED, LONG);
		assert(ulong_long.type.tag == ULONG);
		ulong_long.combine({ .tag = LONG_LONG }, 0)!!;
		assert(ulong_long.type.tag == ULONG_LONG);
		assert(d.messages.len() == 0);

		// LONG_LONG and ULONG_LONG are covered by the preceding duplicate test.
		foreach (prior : (BuilderSpecifierTag[]){
			ULONG_LONG_INT,
			COMPLEX_LONG_LONG,
			COMPLEX_ULONG_LONG,
			COMPLEX_ULONG_LONG_INT,
		})
		{
			expect_seeded_transition_error(p, d, prior, LONG_LONG,
				"duplicate 'long' declaration specifier");
		}

		// The old C3 duplicate group is a cannot-combine result for incoming LONG in Zig.
		// LONG_LONG and COMPLEX_LONG_LONG are already covered above.
		expect_seeded_transition_error(p, d, SLONG_LONG, LONG,
			"cannot combine with previous 'signed long long' specifier");
		expect_seeded_transition_error(p, d, ULONG_LONG, LONG,
			"cannot combine with previous 'unsigned long long' specifier");
		expect_seeded_transition_error(p, d, LONG_LONG_INT, LONG,
			"cannot combine with previous 'long long int' specifier");
		expect_seeded_transition_error(p, d, SLONG_LONG_INT, LONG,
			"cannot combine with previous 'signed long long int' specifier");
		expect_seeded_transition_error(p, d, ULONG_LONG_INT, LONG,
			"cannot combine with previous 'unsigned long long int' specifier");
		expect_seeded_transition_error(p, d, COMPLEX_SLONG_LONG, LONG,
			"cannot combine with previous '_Complex signed long long' specifier");
		expect_seeded_transition_error(p, d, COMPLEX_ULONG_LONG, LONG,
			"cannot combine with previous '_Complex unsigned long long' specifier");
	};
}

fn void repeated_complex_on_bit_int_forms_reports_duplicate() @test
{
	@with_parser(; Compilation* comp, Parser* p, Diagnostics* d)
	{
		Builder plain = { .parser = p };
		combine_tags(&plain, COMPLEX);
		plain.combine({ .tag = BIT_INT, .bits = 8 }, 0)!!;
		assert(plain.type.tag == COMPLEX_BIT_INT && plain.type.bits == 8);
		plain.combine({ .tag = COMPLEX }, 0)!!;
		assert(plain.type.tag == COMPLEX_BIT_INT && plain.type.bits == 8);
		assert(d.messages.len() == 1);
		assert(d.messages[0].text == "duplicate '_Complex' declaration specifier");

		Builder signed_c = { .parser = p };
		combine_tags(&signed_c, COMPLEX, SIGNED);
		signed_c.combine({ .tag = BIT_INT, .bits = 12 }, 0)!!;
		assert(signed_c.type.tag == COMPLEX_SBIT_INT && signed_c.type.bits == 12);
		signed_c.combine({ .tag = COMPLEX }, 0)!!;
		assert(signed_c.type.tag == COMPLEX_SBIT_INT && signed_c.type.bits == 12);
		assert(d.messages.len() == 2);
		assert(d.messages[1].text == "duplicate '_Complex' declaration specifier");

		Builder unsigned_c = { .parser = p };
		combine_tags(&unsigned_c, COMPLEX, UNSIGNED);
		unsigned_c.combine({ .tag = BIT_INT, .bits = 20 }, 0)!!;
		assert(unsigned_c.type.tag == COMPLEX_UBIT_INT && unsigned_c.type.bits == 20);
		unsigned_c.combine({ .tag = COMPLEX }, 0)!!;
		assert(unsigned_c.type.tag == COMPLEX_UBIT_INT && unsigned_c.type.bits == 20);
		assert(d.messages.len() == 3);
		assert(d.messages[2].text == "duplicate '_Complex' declaration specifier");
	};
}

fn void complex_int128_then_signed_reduces_to_sint128() @test
{
	@with_parser(; Compilation* comp, Parser* p, Diagnostics* d)
	{
		Builder b = { .parser = p };
		combine_tags(&b, COMPLEX, INT128, SIGNED);
		assert(b.type.tag == SINT128);
		assert(d.messages.len() == 0);
		assert(b.finish()!!.eql(type_store::INT128, comp));

		// Contrast: UNSIGNED keeps the _Complex spelling in Zig.
		Builder u = { .parser = p };
		combine_tags(&u, COMPLEX, INT128, UNSIGNED);
		assert(u.type.tag == COMPLEX_UINT128);

		// Reverse order keeps _Complex: Zig `.int128` switch maps `.complex_signed`.
		Builder ordered = { .parser = p };
		combine_tags(&ordered, COMPLEX, SIGNED, INT128);
		assert(ordered.type.tag == COMPLEX_SINT128);
		assert(d.messages.len() == 0);
	};
}

fn void bit_int_combinations_preserve_width_and_signedness() @test
{
	@with_parser(; Compilation* comp, Parser* p, Diagnostics* d)
	{
		Builder signed_bit = { .parser = p };
		combine_tags(&signed_bit, SIGNED);
		signed_bit.combine({ .tag = BIT_INT, .bits = 65 }, 0)!!;
		assert(signed_bit.type.tag == SBIT_INT && signed_bit.type.bits == 65);
		QualType signed_qt = signed_bit.finish()!!;
		assert(signed_qt.get_type(comp).bit_int.bits == 65);
		assert(signed_qt.get_type(comp).bit_int.signedness == SIGNED);

		Builder unsigned_bit = { .parser = p };
		combine_tags(&unsigned_bit, UNSIGNED);
		unsigned_bit.combine({ .tag = BIT_INT, .bits = 65535 }, 0)!!;
		assert(unsigned_bit.type.tag == UBIT_INT && unsigned_bit.type.bits == 65535);
		QualType unsigned_qt = unsigned_bit.finish()!!;
		assert(unsigned_qt.get_type(comp).bit_int.bits == 65535);
		assert(unsigned_qt.get_type(comp).bit_int.signedness == UNSIGNED);

		// Width from the BIT_INT survives a later signedness specifier.
		Builder bit_then_signed = { .parser = p };
		bit_then_signed.combine({ .tag = BIT_INT, .bits = 8 }, 0)!!;
		assert(bit_then_signed.type.tag == BIT_INT && bit_then_signed.type.bits == 8);
		bit_then_signed.combine({ .tag = SIGNED }, 0)!!;
		assert(bit_then_signed.type.tag == SBIT_INT && bit_then_signed.type.bits == 8);

		Builder bit_then_unsigned = { .parser = p };
		bit_then_unsigned.combine({ .tag = BIT_INT, .bits = 8 }, 0)!!;
		bit_then_unsigned.combine({ .tag = UNSIGNED }, 0)!!;
		assert(bit_then_unsigned.type.tag == UBIT_INT && bit_then_unsigned.type.bits == 8);

		Builder complex_signed_bit = { .parser = p };
		combine_tags(&complex_signed_bit, COMPLEX, SIGNED);
		complex_signed_bit.combine({ .tag = BIT_INT, .bits = 16 }, 0)!!;
		assert(complex_signed_bit.type.tag == COMPLEX_SBIT_INT && complex_signed_bit.type.bits == 16);

		Builder complex_unsigned_bit = { .parser = p };
		combine_tags(&complex_unsigned_bit, COMPLEX, UNSIGNED);
		complex_unsigned_bit.combine({ .tag = BIT_INT, .bits = 16 }, 0)!!;
		assert(complex_unsigned_bit.type.tag == COMPLEX_UBIT_INT && complex_unsigned_bit.type.bits == 16);

		Builder complex_bit_then_sign = { .parser = p };
		combine_tags(&complex_bit_then_sign, COMPLEX);
		complex_bit_then_sign.combine({ .tag = BIT_INT, .bits = 16 }, 0)!!;
		assert(complex_bit_then_sign.type.tag == COMPLEX_BIT_INT && complex_bit_then_sign.type.bits == 16);
		combine_tags(&complex_bit_then_sign, SIGNED);
		assert(complex_bit_then_sign.type.tag == COMPLEX_SBIT_INT && complex_bit_then_sign.type.bits == 16);

		Builder bit_then_complex = { .parser = p };
		bit_then_complex.combine({ .tag = BIT_INT, .bits = 8 }, 0)!!;
		combine_tags(&bit_then_complex, COMPLEX);
		assert(bit_then_complex.type.tag == COMPLEX_BIT_INT && bit_then_complex.type.bits == 8);

		assert(d.messages.len() == 0);
	};
}

fn void complex_signedness_order_and_repeated_complex_transitions() @test
{
	@with_parser(; Compilation* comp, Parser* p, Diagnostics* d)
	{
		Builder signed_then_complex = { .parser = p };
		combine_tags(&signed_then_complex, SIGNED, COMPLEX);
		assert(signed_then_complex.type.tag == COMPLEX_SIGNED);
		assert(d.messages.len() == 0);

		Builder unsigned_then_complex = { .parser = p };
		combine_tags(&unsigned_then_complex, UNSIGNED, COMPLEX);
		assert(unsigned_then_complex.type.tag == COMPLEX_UNSIGNED);
		assert(d.messages.len() == 0);

		signed_then_complex.combine({ .tag = COMPLEX }, 0)!!;
		assert(signed_then_complex.type.tag == COMPLEX_SIGNED);
		assert(d.messages.len() == 1);
		assert(d.messages[0].text == "duplicate '_Complex' declaration specifier");

		unsigned_then_complex.combine({ .tag = COMPLEX }, 0)!!;
		assert(unsigned_then_complex.type.tag == COMPLEX_UNSIGNED);
		assert(d.messages.len() == 2);
		assert(d.messages[1].text == "duplicate '_Complex' declaration specifier");

		Builder float16_complex = { .parser = p };
		combine_tags(&float16_complex, COMPLEX, FLOAT16);
		assert(float16_complex.type.tag == COMPLEX_FLOAT16);
		assert(d.messages.len() == 2);
		float16_complex.combine({ .tag = COMPLEX }, 0)!!;
		assert(float16_complex.type.tag == COMPLEX_FLOAT16);
		assert(d.messages.len() == 3);
		assert(d.messages[2].text == "cannot combine with previous '_Complex _Float16' specifier");
	};
}
