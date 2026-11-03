// Tests for aro::type_store (src/c3/type_store*.c3, src/c3/type_print.c3).
//
// Sources of expected values (no Zig executable was run; no differential
// parity is claimed):
// - DUMP goldens: type spellings copied from the AST goldens in
//   test/cases/ast/*.c (QualType.dump output), e.g. 'decayed *[4]char',
//   'fn (_Nullable *fn (int) void) void', 'block (int) double',
//   'neon_polyvector(2, unsigned long)', 'kr (...) cc(stdcall) *int'.
// - PRINT goldens: type spellings copied from expected diagnostics in
//   test/cases/*.c (QualType.print output), e.g. 'int (*)(int)',
//   '_Atomic(int) (*)[3]', 'void *const*', 'const int *(void)',
//   '__attribute__((__vector_size__(2 * sizeof(int)))) int'.
// - Named types / va_list: the implicit typedefs at the top of the AST goldens
//   (x86_64-linux, aarch64-linux, aarch64-macos, x86-windows-msvc,
//   x86_64-windows-msvc), and the msp430/avr builtin-type fixtures
//   (test/cases/msp430 builtin types.c, avr sizeof long.c), intmax_t.c and
//   intptr_t.c.
// - _BitInt sizes: test/cases/_BitInt.c. sizeof(void)/_Alignof of an incomplete
//   struct: test/cases/sizeof alignof.c.
// - Everything marked "source-derived" comes from reading TypeStore.zig,
//   Compilation.zig and record_layout.zig (va_list record sizes for
//   powerpc/s390x/aarch64/arm/hexagon, promotions, ranks, equality rules).
module type_store_tests;
import aro::type_store, aro::target, aro::lang_opts, aro::compilation, aro::string_interner;
import std::io, std::core::mem::allocators, std::core::dstring;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

const Host HOST = { X86_64, LINUX, GNU };

fn Target tgt(String triple)
{
	Target? t = target::parse_triple(triple, HOST);
	if (catch f = t)
	{
		io::eprintfn("failed to parse target '%s': %s", triple, f);
		unreachable("target parse failed");
	}
	return t;
}

<* Run the body with a compilation for `triple` on a tracking allocator; checks nothing leaks. *>
macro @with_target(String triple; @body(Compilation* comp))
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		comp.target = tgt(triple);
		comp.langopts.set_target_options(&comp.target);
		@body(&comp);
		comp.free();
	}
	check(ta.allocation_count(), 0);
}

fn String pr(Compilation* comp, QualType qt)
{
	DString w;
	w.init(tmem);
	qt.print(comp, w);
	return w.str_view();
}

fn String dmp(Compilation* comp, QualType qt)
{
	DString w;
	w.init(tmem);
	qt.dump(comp, w);
	return w.str_view();
}

fn String named(Compilation* comp, QualType qt, String name)
{
	DString w;
	w.init(tmem);
	qt.print_named(name, comp, w);
	return w.str_view();
}

fn String desugared(Compilation* comp, QualType qt)
{
	DString w;
	w.init(tmem);
	qt.print_desugared(comp, w);
	return w.str_view();
}

fn QualType cq(QualType qt) { qt.is_const = true; return qt; }
fn QualType vq(QualType qt) { qt.is_volatile = true; return qt; }
fn QualType rq(QualType qt) { qt.is_restrict = true; return qt; }

fn QualType ptr(Compilation* comp, QualType child) => comp.type_store.put(type_store::type_pointer(child));
fn QualType arr(Compilation* comp, QualType elem, ulong len) => comp.type_store.put(type_store::type_array(elem, FIXED, len));
fn QualType tdef(Compilation* comp, String name, QualType base) => comp.type_store.put(type_store::type_typedef(base, comp.intern_string(name), (NodeIndex)0));

fn QualType fn1(Compilation* comp, QualType ret, QualType param, FuncKind kind = NORMAL, CallingConvention cc = DEFAULT)
{
	FuncParam[1] params = { type_store::func_param(param) };
	return comp.type_store.put(type_store::type_func(ret, kind, &params, cc));
}

fn QualType fn0(Compilation* comp, QualType ret, FuncKind kind = NORMAL, CallingConvention cc = DEFAULT)
	=> comp.type_store.put(type_store::type_func(ret, kind, {}, cc));

<* A complete struct with natural layout (at most 4 fields). *>
fn QualType mk_struct(Compilation* comp, String name, QualType[] field_types)
{
	String[4] names = { "f0", "f1", "f2", "f3" };
	RecordField[4] buf;
	RecordField[] fields = buf[:field_types.len];
	foreach (i, ft : field_types) fields[i] = type_store::record_field(comp.intern_string(names[i]), ft);
	RecordLayout layout = type_store::natural_record_layout(comp, fields);
	return comp.type_store.put(type_store::type_record(comp.intern_string(name), fields, layout));
}

fn void canonical_builtins() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp)
	{
		TypeStore* ts = &comp.type_store;
		foreach (k : TypeInt::values)
		{
			QualType qt = ts.put(type_store::type_int(k));
			Type t = qt.get_type(comp);
			assert(t.tag == INT && t.int_ty == k);
			assert(ts.put(type_store::type_int(k)) == qt, "builtins are canonical");
		}
		foreach (k : TypeFloat::values)
		{
			QualType qt = ts.put(type_store::type_float(k));
			Type t = qt.get_type(comp);
			assert(t.tag == FLOAT && t.float_ty == k);
		}
		assert(ts.put({ .tag = VOID }) == type_store::VOID);
		assert(ts.put({ .tag = BOOL }) == type_store::BOOL);
		assert(ts.put({ .tag = NULLPTR_T }) == type_store::NULLPTR_T);
		assert(ts.put({ .tag = STORAGE_FLOAT, .storage_float = MFP8 }) == type_store::MFP8);
		assert(ts.put(type_store::type_int(LONG)) == type_store::LONG);
		assert(ts.put(type_store::type_float(LONG_DOUBLE)) == type_store::LONG_DOUBLE);
		check(ts.len(), 0); // builtins never allocate a slot

		// The builtin pointer handles decode to pointers of their child.
		assert(type_store::VOID_POINTER.get_type(comp).pointer.child == type_store::VOID);
		assert(type_store::CHAR_POINTER.get_type(comp).pointer.child == type_store::CHAR);
		assert(type_store::INT_POINTER.get_type(comp).pointer.child == type_store::INT);
		assert(type_store::INT_POINTER.eql(ptr(comp, type_store::INT), comp));
		assert(type_store::INT_POINTER != ptr(comp, type_store::INT), "derived types get new handles");

		// invalid / auto placeholders
		assert(type_store::INVALID.is_invalid() && !type_store::INVALID.eql(type_store::INVALID, comp));
		assert(type_store::AUTO_TYPE.is_auto() && type_store::C23_AUTO.is_auto() && !type_store::INT.is_auto());
		assert(!@ok(type_store::INVALID.get(comp, INT)));
		assert(!@ok(type_store::AUTO_TYPE.get_record(comp)));
		assert(!type_store::INVALID.has_incomplete_size(comp));
		assert(!@ok(type_store::INVALID.sizeof_or_null(comp)));
		assert(type_store::INVALID.child_type(comp).is_invalid());
		assert(type_store::INVALID.decay(comp).is_invalid());
		assert(type_store::INVALID.alignable(comp));
		test::eq(pr(comp, type_store::AUTO_TYPE), "__auto_type");
		test::eq(pr(comp, type_store::C23_AUTO), "auto");
		test::eq(named(comp, type_store::C23_AUTO, "x"), "auto x");
		test::eq(dmp(comp, type_store::INVALID), "invalid");
		test::eq(dmp(comp, cq(type_store::INVALID)), "const invalid");

		// Qualifier bits are independent of the index.
		QualType ci = cq(type_store::INT);
		assert(ci.is_qualified() && ci.unqualified() == type_store::INT);
		assert(type_store::LONG.with_qualifiers(ci) == cq(type_store::LONG));
		check((uint)type_store::INVALID >> 3, type_store::MAX_INDEX);
	};
}

fn void qualified_equality() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp)
	{
		QualType i = type_store::INT;
		assert(i.eql(cq(i), comp) && !i.eql_qualified(cq(i), comp));
		assert(cq(vq(i)).eql_qualified(vq(cq(i)), comp));
		assert(!i.eql(type_store::UINT, comp));
		assert(!i.eql(type_store::LONG, comp)); // alignment/size differ
		assert(!type_store::LONG.eql(type_store::LONG_LONG, comp)); // same size, different kind

		// Pointers compare their children with qualifiers.
		assert(!ptr(comp, i).eql(ptr(comp, cq(i)), comp));
		assert(ptr(comp, cq(i)).eql(ptr(comp, cq(i)), comp));
		assert(ptr(comp, i).eql(cq(ptr(comp, i)), comp));
		assert(!ptr(comp, i).eql_qualified(cq(ptr(comp, i)), comp));

		// Arrays: known lengths must match; otherwise element types decide, ignoring element qualifiers.
		assert(arr(comp, i, 2).eql(arr(comp, i, 2), comp));
		assert(!arr(comp, i, 2).eql(arr(comp, i, 3), comp));
		QualType inc = comp.type_store.put(type_store::type_array(i, INCOMPLETE));
		assert(inc.eql(arr(comp, i, 3), comp));
		assert(inc.eql(comp.type_store.put(type_store::type_array(cq(i), INCOMPLETE)), comp));
		QualType vla = comp.type_store.put(type_store::type_vla(i, (NodeIndex)7));
		assert(vla.eql(arr(comp, i, 5), comp));

		// Typedefs are transparent.
		QualType my_int = tdef(comp, "MyInt", i);
		assert(my_int.eql(i, comp) && i.eql(my_int, comp));
		assert(tdef(comp, "Other", my_int).eql(my_int, comp));

		// Functions.
		assert(fn1(comp, i, i).eql(fn1(comp, i, i), comp));
		assert(!fn1(comp, i, i).eql(fn1(comp, i, type_store::LONG), comp));
		assert(!fn0(comp, i).eql(fn0(comp, i, VARIADIC), comp));
		assert(fn0(comp, i).eql(fn0(comp, i, OLD_STYLE), comp)); // both empty, neither variadic
		// Old-style vs prototype: equal unless a parameter undergoes default argument promotion.
		assert(fn0(comp, i, OLD_STYLE).eql(fn1(comp, i, i), comp));
		assert(fn1(comp, i, type_store::DOUBLE).eql(fn0(comp, i, OLD_STYLE), comp));
		assert(!fn0(comp, i, OLD_STYLE).eql(fn1(comp, i, type_store::CHAR), comp));
		assert(!fn0(comp, i, OLD_STYLE).eql(fn1(comp, i, type_store::FLOAT), comp));
		assert(!fn0(comp, i, OLD_STYLE).eql(fn1(comp, i, type_store::BOOL), comp));
		assert(!fn1(comp, i, i, VARIADIC).eql(fn1(comp, i, i), comp));

		// Records compare by handle; enums compare to their tag type.
		QualType s1 = mk_struct(comp, "S", { i });
		QualType s2 = mk_struct(comp, "S", { i });
		assert(s1.eql(s1, comp) && s1.eql(cq(s1), comp) && !s1.eql(s2, comp));
		assert(tdef(comp, "TS", s1).eql(s1, comp));
		QualType e = comp.type_store.put({ .tag = ENUM, .enum_ty = { .has_tag = true, .tag = type_store::UINT, .name = comp.intern_string("E") } });
		assert(e.eql(type_store::UINT, comp) && type_store::UINT.eql(e, comp));
		assert(!e.eql(type_store::INT, comp));

		// Complex / atomic / _BitInt / vectors.
		QualType cd = comp.type_store.put(type_store::type_complex(type_store::DOUBLE));
		assert(cd.eql(comp.type_store.put(type_store::type_complex(type_store::DOUBLE)), comp));
		assert(!cd.eql(comp.type_store.put(type_store::type_complex(type_store::FLOAT)), comp));
		QualType ai = comp.type_store.put(type_store::type_atomic(i));
		assert(ai.eql(comp.type_store.put(type_store::type_atomic(i)), comp) && !ai.eql(i, comp));
		QualType b10 = comp.type_store.put(type_store::type_bit_int(10, SIGNED));
		assert(b10.eql(comp.type_store.put(type_store::type_bit_int(10, SIGNED)), comp));
		assert(!b10.eql(comp.type_store.put(type_store::type_bit_int(10, UNSIGNED)), comp));
		QualType v4 = comp.type_store.put(type_store::type_vector(i, 4));
		QualType n4 = comp.type_store.put(type_store::type_vector(i, 4, NEON));
		assert(v4.eql(n4, comp), "eql ignores the vector kind");
		assert(!v4.get_type(comp).vector.eql(n4.get_type(comp).vector, comp, true));
		assert(!v4.eql(comp.type_store.put(type_store::type_vector(i, 2)), comp));
		assert(!v4.eql(comp.type_store.put(type_store::type_vector(cq(i), 4)), comp));

		// Blocks compare their function types.
		QualType f = fn1(comp, i, i);
		assert(comp.type_store.put(type_store::type_block(f)).eql(comp.type_store.put(type_store::type_block(fn1(comp, i, i))), comp));
	};
}

fn void recursive_declarations() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp)
	{
		TypeStore* ts = &comp.type_store;
		StringId name = comp.intern_string("node");
		// struct node; struct node *p;
		QualType s = ts.put(type_store::type_record_incomplete(name));
		QualType p = ptr(comp, s);
		assert(s.has_incomplete_size(comp) && !@ok(s.sizeof_or_null(comp)));
		check(s.alignof(comp), 0);
		assert(!s.alignable(comp));
		test::eq(pr(comp, p), "struct node *");
		Record before = s.get_record(comp)!!;
		assert(!before.has_layout && before.fields.len == 0);

		// struct node { int value; struct node *next; }; completed in place.
		RecordField[2] fields = {
			type_store::record_field(comp.intern_string("value"), type_store::INT),
			type_store::record_field(comp.intern_string("next"), p),
		};
		RecordLayout layout = type_store::natural_record_layout(comp, &fields);
		ts.set(type_store::type_record(name, &fields, layout), s.index);

		assert(!s.has_incomplete_size(comp));
		check(s.sizeof(comp), 16);
		check(s.alignof(comp), 8);
		Record rec = s.get_record(comp)!!;
		check(rec.fields.len, 2);
		check(rec.fields[1].layout.offset_bits, 64);
		assert(rec.has_field(comp, comp.intern_string("next")));
		assert(!rec.has_field(comp, comp.intern_string("prev")));
		// The pointer created before completion sees the completed record.
		QualType next = p.child_type(comp);
		assert(next == s);
		check(next.get_record(comp)!!.fields.len, 2);
		assert(rec.fields[1].qt.eql(p, comp));
		test::eq(dmp(comp, rec.fields[1].qt), "*struct node");

		// union forward declaration.
		QualType u = ts.put(type_store::type_record_incomplete(comp.intern_string("U"), true));
		assert(u.is(comp, UNION) && !u.is(comp, STRUCT));
		test::eq(pr(comp, u), "union U");

		// enum E; then enum E { A } with tag int.
		StringId ename = comp.intern_string("E");
		QualType e = ts.put({ .tag = ENUM, .enum_ty = { .incomplete = true, .name = ename } });
		assert(e.has_incomplete_size(comp) && !@ok(e.sizeof_or_null(comp)));
		check(e.alignof(comp), 0);
		test::eq(dmp(comp, e), "enum E: <incomplete>");
		EnumField[1] efields = { { .qt = type_store::INT, .name = comp.intern_string("A") } };
		ts.set({ .tag = ENUM, .enum_ty = { .has_tag = true, .tag = type_store::INT, .name = ename, .fields = &efields } }, e.index);
		assert(!e.has_incomplete_size(comp));
		check(e.sizeof(comp), 4);
		check(e.get(comp, ENUM)!!.enum_ty.fields.len, 1);
		test::eq(dmp(comp, e), "enum E: int");

		// Fixed incomplete enum: enum F : unsigned char;
		QualType f = ts.put({ .tag = ENUM, .enum_ty = { .has_tag = true, .tag = type_store::UCHAR, .fixed = true, .incomplete = true, .name = comp.intern_string("F") } });
		assert(!f.has_incomplete_size(comp));
		check(f.sizeof(comp), 1);
		test::eq(pr(comp, f), "enum F: unsigned char");

		// Function return types can be patched in place.
		QualType func = fn1(comp, type_store::INT, type_store::INT);
		ts.set_func_return_type(func, type_store::DOUBLE);
		assert(func.get_func(comp)!!.return_type == type_store::DOUBLE);
	};
}

fn void decay_and_children() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp)
	{
		QualType i = type_store::INT;
		// int[4] -> decayed pointer remembering the array.
		QualType a4 = arr(comp, type_store::CHAR, 4);
		QualType d = a4.decay(comp);
		test::eq(dmp(comp, d), "decayed *[4]char");
		test::eq(pr(comp, d), "char *");
		check(d.array_len(comp)!!, 4);
		assert(d.child_type(comp) == type_store::CHAR);
		check(d.sizeof(comp), 8);
		assert(!@ok(i.array_len(comp)));
		assert(!@ok(ptr(comp, i).array_len(comp)));

		// const I a[2] where `typedef int I[2]`: const moves to the element (fixture
		// 'decayed *const I: [2]int' dumps the decayed array type).
		QualType ia = tdef(comp, "I", arr(comp, i, 2));
		QualType cd = cq(ia).decay(comp);
		test::eq(dmp(comp, cd), "decayed *const I: [2]int");
		assert(cd.child_type(comp) == cq(i));
		test::eq(pr(comp, cd), "const int *");

		// restrict on the array goes to the pointer; incomplete/VLA arrays decay too.
		QualType rd = rq(comp.type_store.put(type_store::type_array(i, INCOMPLETE))).decay(comp);
		assert(rd.is_restrict);
		test::eq(dmp(comp, rd), "restrict decayed *restrict []int");
		QualType vd = comp.type_store.put(type_store::type_vla(i, (NodeIndex)3)).decay(comp);
		test::eq(dmp(comp, vd), "decayed *[<expr>]int");
		assert(!@ok(vd.array_len(comp)));

		// Functions decay to pointers to themselves.
		QualType f = fn1(comp, i, i);
		QualType fp = f.decay(comp);
		test::eq(dmp(comp, fp), "*fn (int) int");
		test::eq(pr(comp, fp), "int (*)(int)");
		assert(fp.get_func(comp)!!.return_type == i);
		assert(f.get_func(comp)!!.params.len == 1);
		assert(!@ok(i.get_func(comp)));
		// A function with an invalid part decays to invalid.
		assert(fn1(comp, i, type_store::INVALID).decay(comp).is_invalid());
		assert(fn0(comp, type_store::INVALID).decay(comp).is_invalid());
		// Other types are unchanged.
		assert(i.decay(comp) == i);

		// childType of complex/vector/block.
		QualType cf = comp.type_store.put(type_store::type_complex(type_store::FLOAT));
		assert(cf.child_type(comp) == type_store::FLOAT);
		assert(cf.to_real(comp) == type_store::FLOAT && i.to_real(comp) == i);
		assert(type_store::FLOAT.to_complex(comp).eql(cf, comp));
		QualType v = comp.type_store.put(type_store::type_vector(i, 4));
		assert(v.child_type(comp) == i);
		QualType blk = comp.type_store.put(type_store::type_block(f));
		assert(blk.child_type(comp) == blk);
		QualType at = comp.type_store.put(type_store::type_atomic(i));
		assert(at.non_atomic(comp) == i && i.non_atomic(comp) == i);
		// base() strips typeof/typedef but keeps the innermost handle.
		QualType to = comp.type_store.put(type_store::type_typeof(tdef(comp, "T", ptr(comp, i))));
		BaseType b = to.base(comp);
		assert(b.ty.tag == POINTER && b.ty.pointer.child == i);
		assert(to.is(comp, POINTER) && !to.is(comp, ARRAY));
	};
}

fn void promotions_and_ranks() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp)
	{
		assert(type_store::CHAR.promote_int(comp) == type_store::INT);
		assert(type_store::SCHAR.promote_int(comp) == type_store::INT);
		assert(type_store::UCHAR.promote_int(comp) == type_store::INT);
		assert(type_store::SHORT.promote_int(comp) == type_store::INT);
		assert(type_store::USHORT.promote_int(comp) == type_store::INT); // char bits != int bits
		assert(type_store::BOOL.promote_int(comp) == type_store::INT);
		assert(type_store::UINT.promote_int(comp) == type_store::UINT);
		assert(type_store::LONG.promote_int(comp) == type_store::LONG);
		QualType b7 = comp.type_store.put(type_store::type_bit_int(7, UNSIGNED));
		assert(b7.promote_int(comp) == b7, "_BitInt does not promote");
		QualType e_inc = comp.type_store.put({ .tag = ENUM, .enum_ty = { .incomplete = true, .name = comp.intern_string("E") } });
		assert(e_inc.promote_int(comp) == type_store::INT);
		QualType e_uc = comp.type_store.put({ .tag = ENUM, .enum_ty = { .has_tag = true, .tag = type_store::UCHAR, .name = comp.intern_string("U") } });
		assert(e_uc.promote_int(comp) == type_store::INT);
		QualType at = comp.type_store.put(type_store::type_atomic(type_store::SHORT));
		assert(at.promote_int(comp) == type_store::INT);
		assert(tdef(comp, "S", type_store::SHORT).promote_int(comp) == type_store::INT);

		// Bitfields.
		assert(type_store::LONG.promote_bitfield(comp, 3)!! == type_store::INT);
		assert(type_store::UINT.promote_bitfield(comp, 32)!! == type_store::UINT);
		assert(type_store::INT.promote_bitfield(comp, 32)!! == type_store::INT);
		assert(type_store::LONG.promote_bitfield(comp, 64)!! == type_store::INT);
		assert(!@ok(type_store::UCHAR.promote_bitfield(comp, 9)));

		// Ranks (source-derived: kind offset + 8 * bits).
		check(type_store::BOOL.int_rank(comp), 9);
		check(type_store::CHAR.int_rank(comp), 66);
		check(type_store::SHORT.int_rank(comp), 131);
		check(type_store::INT.int_rank(comp), 260);
		check(type_store::LONG.int_rank(comp), 518);
		check(type_store::LONG_LONG.int_rank(comp), 519);
		check(type_store::INT128.int_rank(comp), 1032);
		check(b7.int_rank(comp), 56);
		assert(type_store::INT.int_rank_order(type_store::UINT, comp) == LT);
		assert(type_store::UINT.int_rank_order(type_store::INT, comp) == GT);
		assert(type_store::LONG.int_rank_order(type_store::UINT, comp) == GT);
		assert(type_store::INT.int_rank_order(type_store::INT, comp) == EQ);
		assert(type_store::INT.int_rank_order(type_store::LONG, comp) == LT);
		assert(type_store::INT.same_rank_different_sign(type_store::UINT, comp));
		assert(!type_store::INT.same_rank_different_sign(type_store::LONG, comp));
		assert(!type_store::INT.same_rank_different_sign(type_store::FLOAT, comp));

		check(type_store::BF16.float_rank(comp), 0);
		check(type_store::FLOAT.float_rank(comp), 3);
		check(type_store::DOUBLE.float_rank(comp), 6);
		check(type_store::LONG_DOUBLE.float_rank(comp), 9);
		check(type_store::DFLOAT128.float_rank(comp), 93);
		check(comp.type_store.put(type_store::type_complex(type_store::DOUBLE)).float_rank(comp), 6);

		// Signedness: plain char follows the target, enums/pointers are signed.
		assert(type_store::CHAR.signedness(comp) == SIGNED);
		assert(type_store::BOOL.signedness(comp) == UNSIGNED);
		assert(type_store::INT_POINTER.signedness(comp) == SIGNED);
		assert(e_uc.signedness(comp) == SIGNED);
		comp.langopts.has_char_signedness_override = true;
		comp.langopts.char_signedness_override = UNSIGNED;
		assert(type_store::CHAR.signedness(comp) == UNSIGNED);
		comp.langopts.has_char_signedness_override = false;

		// Scalar kinds.
		assert(type_store::BOOL.scalar_kind(comp) == BOOL);
		assert(b7.scalar_kind(comp) == INT);
		assert(type_store::VOID_POINTER.scalar_kind(comp) == VOID_POINTER);
		assert(type_store::INT_POINTER.scalar_kind(comp) == POINTER);
		assert(comp.type_store.put(type_store::type_complex(type_store::INT)).scalar_kind(comp) == COMPLEX_INT);
		assert(comp.type_store.put(type_store::type_complex(type_store::FLOAT)).scalar_kind(comp) == COMPLEX_FLOAT);
		assert(at.scalar_kind(comp) == INT);
		assert(e_uc.scalar_kind(comp) == ENUM);
		assert(type_store::NULLPTR_T.scalar_kind(comp) == NULLPTR_T);
		assert(arr(comp, type_store::INT, 2).scalar_kind(comp) == NONE);
		assert(type_store::INT.is_real_int(comp) && !comp.type_store.put(type_store::type_complex(type_store::INT)).is_real_int(comp));
		assert(type_store::FLOAT.is_float(comp) && type_store::CHAR_POINTER.is_pointer(comp));

		// makeIntUnsigned / suffixes / format modifiers.
		assert(type_store::CHAR.make_int_unsigned(comp) == type_store::UCHAR);
		assert(type_store::LONG.make_int_unsigned(comp) == type_store::ULONG);
		assert(type_store::INT24.make_int_unsigned(comp) == type_store::UINT24);
		QualType sb = comp.type_store.put(type_store::type_bit_int(12, SIGNED));
		Type ub = sb.make_int_unsigned(comp).get_type(comp);
		assert(ub.tag == BIT_INT && ub.bit_int.bits == 12 && ub.bit_int.signedness == UNSIGNED);
		test::eq(type_store::LONG.int_value_suffix(comp), "L");
		test::eq(type_store::ULONG_LONG.int_value_suffix(comp), "ULL");
		test::eq(type_store::USHORT.int_value_suffix(comp), "");
		test::eq(type_store::UINT.int_value_suffix(comp), "U");
		test::eq(type_store::SCHAR.format_modifier(comp), "hh");
		test::eq(type_store::LONG_LONG.format_modifier(comp), "ll");
	};
	// 16-bit int: unsigned short promotes to int (UCHAR bits 8 != INT bits 16).
	@with_target("msp430-other-none"; Compilation* comp)
	{
		assert(type_store::USHORT.promote_int(comp) == type_store::INT);
		test::eq(type_store::USHORT.int_value_suffix(comp), "U");
		assert(type_store::CHAR.signedness(comp) == UNSIGNED); // fixture: (char)-1 >= 0
	};
}

struct NamedCase
{
	String triple;
	String va_list_dump;
	ulong va_list_size;
	QualType wchar;
	QualType wint;
	QualType size;
	QualType ptrdiff;
	QualType intmax;
	QualType intptr;
}

fn void named_types_and_va_list() @test
{
	NamedCase[] cases = {
		// va_list spellings: AST goldens (x86_64-linux, aarch64-linux, aarch64-macos,
		// *-windows-msvc). intmax/intptr on x86_64-linux-gnu: intmax_t.c / intptr_t.c.
		// Everything else source-derived.
		{ "x86_64-linux-gnu", "[1]struct __va_list_tag", 24, type_store::INT, type_store::UINT, type_store::ULONG, type_store::LONG, type_store::LONG, type_store::LONG },
		{ "aarch64-linux-gnu", "struct __va_list", 32, type_store::UINT, type_store::UINT, type_store::ULONG, type_store::LONG, type_store::LONG, type_store::LONG },
		{ "aarch64-macos", "*char", 8, type_store::INT, type_store::INT, type_store::ULONG, type_store::LONG, type_store::LONG, type_store::LONG },
		{ "x86-windows-msvc", "*char", 4, type_store::USHORT, type_store::USHORT, type_store::UINT, type_store::INT, type_store::LONG_LONG, type_store::INT },
		{ "x86_64-windows-msvc", "*char", 8, type_store::USHORT, type_store::USHORT, type_store::ULONG_LONG, type_store::LONG_LONG, type_store::LONG_LONG, type_store::LONG_LONG },
		{ "arm-linux-gnueabihf", "struct __va_list", 4, type_store::UINT, type_store::UINT, type_store::UINT, type_store::INT, type_store::LONG_LONG, type_store::LONG },
		{ "powerpc-linux-gnu", "[1]struct __va_list_tag", 12, type_store::INT, type_store::UINT, type_store::UINT, type_store::INT, type_store::LONG_LONG, type_store::INT },
		{ "s390x-linux-gnu", "[1]struct __va_list_tag", 32, type_store::INT, type_store::UINT, type_store::ULONG, type_store::LONG, type_store::LONG_LONG, type_store::LONG },
		{ "hexagon-linux-musl", "[1]struct __va_list_tag", 12, type_store::INT, type_store::UINT, type_store::UINT, type_store::INT, type_store::LONG_LONG, type_store::INT },
		{ "riscv64-linux-gnu", "*void", 8, type_store::INT, type_store::UINT, type_store::ULONG, type_store::LONG, type_store::LONG, type_store::LONG },
		{ "powerpc64le-linux-gnu", "*char", 8, type_store::INT, type_store::UINT, type_store::ULONG, type_store::LONG, type_store::LONG, type_store::LONG },
		{ "msp430-other-none", "*char", 2, type_store::UINT, type_store::INT, type_store::UINT, type_store::INT, type_store::LONG_LONG, type_store::INT },
	};
	foreach (c : cases)
	{
		@with_target(c.triple; Compilation* comp)
		{
			type_store::init_named_types(comp);
			TypeStore* ts = &comp.type_store;
			test::eq(dmp(comp, ts.va_list), c.va_list_dump);
			check(ts.va_list.sizeof(comp), c.va_list_size);
			test::eq(dmp(comp, ts.ns_constant_string), "struct __NSConstantString_tag");
			assert(ts.wchar == c.wchar, "%s", c.triple);
			assert(ts.wint == c.wint, "%s", c.triple);
			assert(ts.size == c.size, "%s", c.triple);
			assert(ts.ptrdiff == c.ptrdiff, "%s", c.triple);
			assert(ts.intmax.eql(c.intmax, comp), "%s", c.triple);
			assert(ts.intptr == c.intptr, "%s", c.triple);
			assert(ts.pid_t == type_store::INT);
			assert(ts.size.signedness(comp) == UNSIGNED && ts.ptrdiff.signedness(comp) == SIGNED);
			check(ts.size.sizeof(comp), comp.target.ptr_bit_width() / 8);
		};
	}

	@with_target("x86_64-linux-gnu"; Compilation* comp)
	{
		type_store::init_named_types(comp);
		TypeStore* ts = &comp.type_store;
		// AST golden: 'va_list: __builtin_va_list: [1]struct __va_list_tag'.
		QualType builtin = tdef(comp, "__builtin_va_list", ts.va_list);
		test::eq(dmp(comp, tdef(comp, "va_list", builtin)), "va_list: __builtin_va_list: [1]struct __va_list_tag");
		test::eq(dmp(comp, tdef(comp, "va_list", builtin).decay(comp)), "decayed *va_list: __builtin_va_list: [1]struct __va_list_tag");
		Record tag = ts.va_list.child_type(comp).get_record(comp)!!;
		check(tag.fields.len, 4);
		check(tag.fields[2].layout.offset_bits, 64);
		check(tag.layout.field_alignment_bits, 64);
		Record ns = ts.ns_constant_string.get_record(comp)!!;
		check(ns.layout.size_bits, 256);
		check(ns.fields[3].layout.offset_bits, 192);
		// Zig names it `const_int_ptr` but builds `.{ .@"const" = true, ._index = .int_pointer }`: a const pointer.
		test::eq(pr(comp, ns.fields[0].qt), "int *const");
		assert(ts.uint_least16_t == type_store::USHORT && ts.uint_least32_t == type_store::UINT);
		assert(ts.int16 == type_store::SHORT && ts.int64 == type_store::LONG);
	};
	@with_target("avr-freestanding-none"; Compilation* comp)
	{
		type_store::init_named_types(comp);
		TypeStore* ts = &comp.type_store;
		assert(ts.va_list == type_store::VOID_POINTER);
		assert(ts.uint_least16_t == type_store::UINT); // AVR uses int for int_least16_t
		assert(ts.int16 == type_store::INT);
		check(ts.size.sizeof(comp), 2);
		check(ts.va_list.alignof(comp), 1); // pointers are byte aligned on AVR
		// int24 exists on AVR and is the least type for 17..24 bits.
		assert(type_store::int_least_n(comp, 24, SIGNED) == type_store::INT24);
	};
	@with_target("x86_64-macos"; Compilation* comp)
	{
		assert(type_store::int_least_n(comp, 64, SIGNED) == type_store::LONG_LONG);
		assert(type_store::int_least_n(comp, 64, UNSIGNED) == type_store::ULONG_LONG);
		type_store::init_named_types(comp);
		test::eq(dmp(comp, comp.type_store.va_list), "[1]struct __va_list_tag");
	};
}

fn void sizes_and_incomplete_types() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp)
	{
		TypeStore* ts = &comp.type_store;
		// sizeof alignof.c: sizeof(void) == 1, _Alignof(void) == 1, _Alignof(incomplete struct) == 0.
		check(type_store::VOID.sizeof(comp), 1);
		check(type_store::VOID.alignof(comp), 1);
		assert(type_store::VOID.has_incomplete_size(comp));
		assert(!type_store::VOID.alignable(comp));
		// _BitInt.c
		QualType b65 = ts.put(type_store::type_bit_int(65, SIGNED));
		QualType b66 = ts.put(type_store::type_bit_int(66, SIGNED));
		QualType b8 = ts.put(type_store::type_bit_int(8, SIGNED));
		check(b65.sizeof(comp), b66.sizeof(comp));
		assert(b8.sizeof(comp) != b66.sizeof(comp));
		check(ts.put(type_store::type_bit_int(65535, SIGNED)).sizeof(comp), 8192);
		// source-derived: _BitInt(N <= 64) aligns like intLeastN, larger to 8.
		check(b8.alignof(comp), 1);
		check(b65.alignof(comp), 8);
		check(b65.sizeof(comp), 16);
		check(ts.put(type_store::type_bit_int(17, UNSIGNED)).sizeof(comp), 4);
		check(b65.bit_sizeof(comp), 65);

		check(type_store::BOOL.bit_sizeof(comp), 1);
		// Source-derived: sizeof is Float.bits / 8 and cTypeBitSize(.longdouble) is 80 on
		// x86_64 (target_data.c3), so this is 10, not the padded cTypeByteSize of 16.
		// No fixture pins sizeof(long double) on x86_64; see the plan 08 report.
		check(type_store::LONG_DOUBLE.sizeof(comp), 10);
		check(type_store::LONG_DOUBLE.alignof(comp), 16);
		check(type_store::INT128.alignof(comp), 16);
		check(type_store::FLOAT16.alignof(comp), 2);
		check(type_store::MFP8.sizeof(comp), 1);
		check(type_store::NULLPTR_T.sizeof(comp), 8);
		check(ts.put(type_store::type_complex(type_store::DOUBLE)).sizeof(comp), 16);
		check(ts.put(type_store::type_complex(type_store::DOUBLE)).alignof(comp), 8);
		check(ts.put(type_store::type_atomic(type_store::INT)).sizeof(comp), 4);
		check(ts.put(type_store::type_vector(type_store::INT, 4)).sizeof(comp), 16);
		check(ts.put(type_store::type_vector(type_store::INT, 4)).alignof(comp), 4);
		QualType f = fn0(comp, type_store::VOID);
		check(f.sizeof(comp), 1);
		check(f.alignof(comp), 16); // Target.defaultFunctionAlignment on x86_64
		check(ts.put(type_store::type_block(f)).sizeof(comp), 8);
		check(arr(comp, type_store::INT, 10).sizeof(comp), 40);
		check(arr(comp, arr(comp, type_store::SHORT, 3), 2).sizeof(comp), 12);
		check(arr(comp, type_store::INT, 10).alignof(comp), 4);

		// Incomplete and variable arrays have no size.
		QualType inc = ts.put(type_store::type_array(type_store::INT, INCOMPLETE));
		assert(inc.has_incomplete_size(comp) && !@ok(inc.sizeof_or_null(comp)));
		QualType vla = ts.put(type_store::type_vla(type_store::INT, (NodeIndex)1));
		assert(!vla.has_incomplete_size(comp) && !@ok(vla.sizeof_or_null(comp)));
		assert(!@ok(ts.put(type_store::type_array(type_store::INT, UNSPECIFIED_VARIABLE)).sizeof_or_null(comp)));
		assert(!@ok(arr(comp, inc, 2).sizeof_or_null(comp)), "array of incomplete");
		assert(ts.put(type_store::type_complex(type_store::DOUBLE)).size_compare(type_store::LONG, comp) == GT);
		assert(type_store::INT.size_compare(type_store::UINT, comp) == EQ);
		assert(inc.size_compare(type_store::INT, comp) == INDETERMINATE);
		// MSVC emulation: an incomplete array has size 0, arrays ignore alignment.
		comp.langopts.emulate = MSVC;
		check(inc.sizeof(comp), 0);
		check(type_store::BOOL.bit_sizeof(comp), 8);
		comp.langopts.emulate = NO;

		// Requested alignment through typedefs.
		QualType aligned = tdef(comp, "aligned_int", type_store::INT);
		ts.set_requested_alignment(aligned, 16);
		check(aligned.alignof(comp), 16);
		check(aligned.requested_alignment(comp)!!, 16);
		QualType outer = tdef(comp, "outer", aligned);
		check(outer.alignof(comp), 16);
		check(type_store::INT.alignof(comp), 4);
		check(arr(comp, aligned, 2).alignof(comp), 16);
		check(arr(comp, aligned, 2).sizeof(comp), 16);
		assert(!@ok(type_store::INT.requested_alignment(comp)));
		// gcc ignores requested alignment on enums.
		QualType e = ts.put({ .tag = ENUM, .enum_ty = { .has_tag = true, .tag = type_store::INT, .name = comp.intern_string("E") } });
		ts.set_requested_alignment(e, 8);
		check(e.alignof(comp), 8);
		comp.langopts.emulate = GCC;
		check(e.alignof(comp), 4);
		comp.langopts.emulate = NO;
	};
	@with_target("avr-freestanding-none"; Compilation* comp)
	{
		// avr sizeof long.c
		check(type_store::INT.sizeof(comp), 2);
		check(type_store::SHORT.sizeof(comp), 2);
		check(type_store::LONG.sizeof(comp), 4);
		check(type_store::LONG_DOUBLE.sizeof(comp), 4);
		check(type_store::LONG_LONG.sizeof(comp), 8);
		check(type_store::INT24.sizeof(comp), 3);
	};
	@with_target("msp430-other-none"; Compilation* comp)
	{
		// msp430 builtin types.c
		check(type_store::INT.sizeof(comp), 2);
		check(type_store::LONG_DOUBLE.sizeof(comp), 8);
		check(type_store::CHAR_POINTER.sizeof(comp), 2);
		check(type_store::CHAR_POINTER.alignof(comp), 2);
		check(type_store::INT.alignof(comp), 2);
		check(type_store::LONG.alignof(comp), 2);
		check(type_store::LONG_LONG.alignof(comp), 2);
		check(type_store::FLOAT.alignof(comp), 2);
		check(type_store::DOUBLE.alignof(comp), 2);
		check(type_store::LONG_DOUBLE.alignof(comp), 2);
		type_store::init_named_types(comp);
		check(comp.type_store.ptrdiff.sizeof(comp), 2);
		check(comp.type_store.size.sizeof(comp), 2);
		check(comp.type_store.wchar.sizeof(comp), 2);
	};
	@with_target("s390x-linux-gnu"; Compilation* comp)
	{
		check(type_store::INT128.alignof(comp), 8); // source-derived special case
	};
}

fn void print_goldens() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp)
	{
		TypeStore* ts = &comp.type_store;
		QualType i = type_store::INT;
		QualType pi = ptr(comp, i);
		// Expected diagnostics in test/cases/*.c
		test::eq(pr(comp, fn1(comp, i, i).decay(comp)), "int (*)(int)");
		test::eq(pr(comp, ptr(comp, fn1(comp, type_store::DOUBLE, i))), "double (*)(int)");
		test::eq(pr(comp, ts.put(type_store::type_block(fn1(comp, i, i)))), "int (^)(int)");
		test::eq(pr(comp, ts.put(type_store::type_block(fn1(comp, type_store::DOUBLE, i)))), "double (^)(int)");
		QualType my_int = tdef(comp, "MyInt", i);
		test::eq(pr(comp, ptr(comp, fn1(comp, my_int, my_int))), "MyInt (*)(MyInt)");
		test::eq(pr(comp, ts.put(type_store::type_block(fn1(comp, my_int, my_int)))), "MyInt (^)(MyInt)");
		QualType ai = ts.put(type_store::type_atomic(i));
		test::eq(pr(comp, ai), "_Atomic(int)");
		test::eq(pr(comp, ptr(comp, ai)), "_Atomic(int) *");
		test::eq(pr(comp, ptr(comp, arr(comp, ai, 3))), "_Atomic(int) (*)[3]");
		test::eq(pr(comp, cq(vq(ai))), "const volatile _Atomic(int)");
		QualType sb = ts.put(type_store::type_record_incomplete(comp.intern_string("B")));
		test::eq(pr(comp, ts.put(type_store::type_atomic(ptr(comp, sb)))), "_Atomic(struct B *)");
		test::eq(pr(comp, ptr(comp, ts.put(type_store::type_atomic(sb)))), "_Atomic(struct B) *");
		test::eq(pr(comp, cq(type_store::CHAR_POINTER)), "char *const");
		test::eq(pr(comp, cq(pi)), "int *const");
		test::eq(pr(comp, ptr(comp, cq(type_store::VOID_POINTER))), "void *const*");
		test::eq(pr(comp, arr(comp, type_store::CHAR, 10)), "char [10]");
		test::eq(pr(comp, arr(comp, type_store::SCHAR, 2)), "signed char [2]");
		test::eq(pr(comp, arr(comp, cq(i), 2)), "const int [2]");
		test::eq(pr(comp, arr(comp, arr(comp, cq(i), 2), 2)), "const int [2][2]");
		test::eq(pr(comp, ts.put(type_store::type_array(cq(i), INCOMPLETE))), "const int []");
		test::eq(pr(comp, ts.put(type_store::type_vla(i, (NodeIndex)0))), "int [<expr>]");
		test::eq(pr(comp, fn0(comp, ptr(comp, cq(i)))), "const int *(void)");
		test::eq(pr(comp, fn0(comp, type_store::VOID)), "void (void)");
		test::eq(pr(comp, ptr(comp, cq(type_store::UINT))), "const unsigned int *");
		test::eq(pr(comp, ptr(comp, cq(vq(type_store::CHAR)))), "const volatile char *");
		test::eq(pr(comp, cq(vq(type_store::FLOAT))), "const volatile float");
		test::eq(pr(comp, ts.put(type_store::type_vector(i, 2))), "__attribute__((__vector_size__(2 * sizeof(int)))) int");
		test::eq(pr(comp, ts.put(type_store::type_bit_int(10, SIGNED))), "signed _BitInt(10)");
		test::eq(pr(comp, ts.put(type_store::type_complex(type_store::DOUBLE))), "_Complex double");
		test::eq(pr(comp, ts.put(type_store::type_complex(i))), "_Complex int");
		test::eq(pr(comp, cq(type_store::MFP8)), "const __mfp8");
		QualType es = ts.put({ .tag = ENUM, .enum_ty = { .has_tag = true, .tag = i, .fixed = true, .name = comp.intern_string("Signed") } });
		test::eq(pr(comp, ptr(comp, es)), "enum Signed: int *");
		QualType ee = ts.put({ .tag = ENUM, .enum_ty = { .incomplete = true, .name = comp.intern_string("E") } });
		test::eq(pr(comp, ptr(comp, ee)), "enum E *");
		// typeof
		QualType t_ci = ts.put(type_store::type_typeof(cq(i)));
		test::eq(pr(comp, t_ci), "typeof(const int)");
		test::eq(pr(comp, ptr(comp, t_ci)), "typeof(const int) *");
		test::eq(pr(comp, arr(comp, t_ci, 2)), "typeof(const int) [2]");
		test::eq(pr(comp, cq(ts.put(type_store::type_typeof(arr(comp, i, 2))))), "const typeof(int [2])");
		test::eq(pr(comp, cq(ts.put(type_store::type_typeof(pi)))), "const typeof(int *)");
		QualType tti = ts.put(type_store::type_typeof(ts.put(type_store::type_typeof(ts.put(type_store::type_typeof(i))))));
		test::eq(pr(comp, cq(tti)), "const typeof(typeof(typeof(int)))");
		test::eq(pr(comp, ts.put(type_store::type_typeof(type_store::BOOL))), "typeof(_Bool)");
		comp.langopts.standard = C23;
		test::eq(pr(comp, type_store::BOOL), "bool");
		test::eq(pr(comp, fn0(comp, type_store::VOID)), "void ()");
		comp.langopts.standard = lang_opts::DEFAULT.standard;
		// Calling convention, variadic, nullability (source-derived spellings).
		test::eq(pr(comp, fn1(comp, i, i, VARIADIC)), "int (int, ...)");
		test::eq(pr(comp, fn0(comp, i, OLD_STYLE, STDCALL)), "int (...) __attribute__((stdcall))");
		Type np = type_store::type_pointer(i);
		np.pointer.nullability = NULLABLE;
		test::eq(pr(comp, ts.put(np)), "int * _Nullable");
		test::eq(pr(comp, rq(pi)), "int *restrict");
		test::eq(pr(comp, ts.put(type_store::type_array(rq(i), STATIC, 3))), "int [3static]");
		test::eq(pr(comp, rq(ts.put(type_store::type_array(i, STATIC, 3)))), "int [3static restrict]");
		// printNamed / printDesugared
		test::eq(named(comp, i, "x"), "int x");
		test::eq(named(comp, pi, "p"), "int *p");
		test::eq(named(comp, fn1(comp, i, i).decay(comp), "fp"), "int (*fp)(int)");
		test::eq(named(comp, arr(comp, i, 3), "a"), "int a[3]");
		test::eq(pr(comp, ptr(comp, my_int)), "MyInt *");
		test::eq(desugared(comp, ptr(comp, my_int)), "int *");
		test::eq(desugared(comp, cq(my_int)), "const int");
		test::eq(desugared(comp, t_ci), "int"); // desugaring keeps only the outer qualifiers
		// shouldDesugar: typedef names that differ from their keyword spelling.
		assert(my_int.should_desugar(comp));
		assert(ptr(comp, my_int).should_desugar(comp));
		assert(!tdef(comp, "int", i).should_desugar(comp));
		assert(!pi.should_desugar(comp));
		assert(t_ci.should_desugar(comp));
		assert(fn1(comp, i, my_int).should_desugar(comp));
		QualType s = mk_struct(comp, "S", { i });
		assert(tdef(comp, "S", s).should_desugar(comp), "struct is not a keyword specifier");
	};
}

fn void dump_goldens() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp)
	{
		TypeStore* ts = &comp.type_store;
		QualType i = type_store::INT;
		// AST goldens in test/cases/ast/*.c
		test::eq(dmp(comp, type_store::INT_POINTER), "*int");
		test::eq(dmp(comp, type_store::CHAR_POINTER), "*char");
		test::eq(dmp(comp, type_store::VOID_POINTER), "*void");
		test::eq(dmp(comp, ptr(comp, cq(i))), "*const int");
		test::eq(dmp(comp, ptr(comp, vq(i))), "*volatile int");
		test::eq(dmp(comp, ptr(comp, cq(vq(i)))), "*const volatile int");
		test::eq(dmp(comp, cq(vq(i))), "const volatile int");
		test::eq(dmp(comp, rq(type_store::INT_POINTER)), "restrict *int");
		test::eq(dmp(comp, type_store::BOOL), "_Bool");
		test::eq(dmp(comp, type_store::UINT128), "unsigned __int128");
		test::eq(dmp(comp, type_store::DFLOAT64X), "_Decimal64x");
		test::eq(dmp(comp, type_store::FLOAT32X), "_Float32x");
		test::eq(dmp(comp, type_store::BF16), "__bf16");
		test::eq(dmp(comp, type_store::MFP8), "__mfp8");
		test::eq(dmp(comp, fn0(comp, type_store::VOID)), "fn () void");
		test::eq(dmp(comp, fn1(comp, i, i)), "fn (int) int");
		test::eq(dmp(comp, ptr(comp, fn1(comp, type_store::DOUBLE, i))), "*fn (int) double");
		test::eq(dmp(comp, arr(comp, i, 2)), "[2]int");
		test::eq(dmp(comp, arr(comp, type_store::CHAR, 64)), "[64]char");
		test::eq(dmp(comp, ts.put(type_store::type_array(i, STATIC, 2))), "[static 2]int");
		test::eq(dmp(comp, ts.put(type_store::type_array(i, UNSPECIFIED_VARIABLE))), "[*]int");
		test::eq(dmp(comp, ts.put(type_store::type_atomic(type_store::FLOAT))), "_Atomic(float)");
		QualType sb = ts.put(type_store::type_record_incomplete(comp.intern_string("B")));
		test::eq(dmp(comp, ts.put(type_store::type_atomic(ptr(comp, sb)))), "_Atomic(struct B *)");
		test::eq(dmp(comp, ptr(comp, ts.put(type_store::type_atomic(sb)))), "*_Atomic(struct B)");
		test::eq(dmp(comp, ptr(comp, cq(ts.put(type_store::type_atomic(i))))), "*const _Atomic(int)");
		test::eq(dmp(comp, ts.put(type_store::type_complex(type_store::LONG_DOUBLE))), "_Complex long double");
		test::eq(dmp(comp, ts.put(type_store::type_vector(type_store::CHAR, 8))), "vector(8, char)");
		test::eq(dmp(comp, tdef(comp, "vec_a", ts.put(type_store::type_vector(type_store::CHAR, 8)))), "vec_a: vector(8, char)");
		test::eq(dmp(comp, ts.put(type_store::type_vector(type_store::FLOAT, 4, NEON))), "neon_vector(4, float)");
		test::eq(dmp(comp, ts.put(type_store::type_vector(type_store::ULONG, 2, NEON_POLY))), "neon_polyvector(2, unsigned long)");
		QualType my_int = tdef(comp, "MyInt", i);
		test::eq(dmp(comp, my_int), "MyInt: int");
		FuncParam[1] named_param = { type_store::func_param(my_int, comp.intern_string("i")) };
		test::eq(dmp(comp, ts.put(type_store::type_func(my_int, NORMAL, &named_param))), "fn (i: MyInt: int) MyInt: int");
		test::eq(dmp(comp, ptr(comp, ts.put(type_store::type_func(my_int, NORMAL, &named_param)))), "*fn (i: MyInt: int) MyInt: int");
		FuncParam[1] x_param = { type_store::func_param(i, comp.intern_string("x")) };
		test::eq(dmp(comp, ts.put(type_store::type_func(type_store::VOID, VARIADIC, &x_param))), "fn (x: int, ...) void");
		test::eq(dmp(comp, fn0(comp, type_store::INT_POINTER, OLD_STYLE, STDCALL)), "kr (...) cc(stdcall) *int");
		test::eq(dmp(comp, fn0(comp, i, OLD_STYLE, CDECL)), "kr (...) cc(cdecl) int");
		FuncParam[1] fp_param = { type_store::func_param(ptr(comp, fn0(comp, type_store::VOID, NORMAL, CDECL)), comp.intern_string("fn_ptr")) };
		test::eq(dmp(comp, ts.put(type_store::type_func(type_store::VOID, NORMAL, &fp_param))), "fn (fn_ptr: *fn () cc(cdecl) void) void");
		// Blocks
		test::eq(dmp(comp, ts.put(type_store::type_block(fn1(comp, i, i)))), "block (int) int");
		test::eq(dmp(comp, ts.put(type_store::type_block(fn1(comp, type_store::DOUBLE, i)))), "block (int) double");
		FuncParam[1] mi_param = { type_store::func_param(my_int) };
		test::eq(dmp(comp, ts.put(type_store::type_block(ts.put(type_store::type_func(my_int, NORMAL, &mi_param))))), "block (MyInt: int) MyInt: int");
		// Nullability ('fn (_Nullable *fn (int) void) void', 'fn () _Null_unspecified *int')
		Type nfp = type_store::type_pointer(fn1(comp, type_store::VOID, i));
		nfp.pointer.nullability = NULLABLE;
		FuncParam[1] n_param = { type_store::func_param(ts.put(nfp)) };
		test::eq(dmp(comp, ts.put(type_store::type_func(type_store::VOID, NORMAL, &n_param))), "fn (_Nullable *fn (int) void) void");
		Type nu = type_store::type_pointer(i);
		nu.pointer.nullability = UNSPECIFIED;
		test::eq(dmp(comp, fn0(comp, ts.put(nu))), "fn () _Null_unspecified *int");
		// 'fn (_Nullable decayed *[2]int) void': an attributed decayed pointer.
		Type nd = type_store::type_decayed_pointer(i, arr(comp, i, 2));
		nd.pointer.nullability = NULLABLE;
		QualType ndq = ts.put(nd);
		test::eq(dmp(comp, ndq), "_Nullable decayed *[2]int");
		assert(ndq.get_type(comp).pointer.has_decayed && ndq.child_type(comp) == i);
		Type bp = type_store::type_pointer(i);
		bp.pointer.bounds = SINGLE;
		test::eq(dmp(comp, ts.put(bp)), "*single int");
		// typeof
		test::eq(dmp(comp, ts.put(type_store::type_typeof_expr(i, (NodeIndex)1))), "typeof(<expr>: int)");
		test::eq(dmp(comp, cq(ts.put(type_store::type_typeof_expr(cq(i), (NodeIndex)1)))), "const typeof(<expr>: const int)");
		test::eq(dmp(comp, ts.put(type_store::type_typeof(tdef(comp, "aligned_int", i)))), "typeof(aligned_int: int)");
		test::eq(dmp(comp, ts.put(type_store::type_typeof_expr(ts.put(type_store::type_atomic(i)), (NodeIndex)1))), "typeof(<expr>: _Atomic(int))");
		// enums ('enum Small: unsigned char', 'enum Large: long')
		test::eq(dmp(comp, ts.put({ .tag = ENUM, .enum_ty = { .has_tag = true, .tag = type_store::UCHAR, .name = comp.intern_string("Small") } })), "enum Small: unsigned char");
		test::eq(dmp(comp, ts.put({ .tag = ENUM, .enum_ty = { .has_tag = true, .tag = type_store::LONG, .name = comp.intern_string("Large") } })), "enum Large: long");
		test::eq(dmp(comp, mk_struct(comp, "S", { i })), "struct S");
		test::eq(dmp(comp, ts.put(type_store::type_record_incomplete(comp.intern_string("U"), true))), "union U");
	};
}

fn void handle_stability_under_growth() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp)
	{
		TypeStore* ts = &comp.type_store;
		QualType my_int = tdef(comp, "MyInt", type_store::INT);
		FuncParam[2] params = { type_store::func_param(my_int, comp.intern_string("a")), type_store::func_param(type_store::LONG, comp.intern_string("b")) };
		QualType f = ts.put(type_store::type_func(type_store::VOID, VARIADIC, &params));
		// Mutating the caller's array afterwards must not affect the stored type.
		params[0].qt = type_store::DOUBLE;
		Func held = f.get_func(comp)!!;
		QualType s = mk_struct(comp, "S", { type_store::INT, type_store::CHAR });
		Record held_rec = s.get_record(comp)!!;
		QualType a = arr(comp, my_int, 0x1_0000_0001);
		String f_dump = dmp(comp, f);
		test::eq(f_dump, "fn (a: MyInt: int, b: long, ...) void");

		// Force many reallocations of every backing list.
		const uint N = 50_000;
		QualType prev = type_store::INT;
		QualType[] chain = mem::new_array(QualType, N);
		defer mem::free(chain);
		for (uint n = 0; n < N; n++)
		{
			prev = ptr(comp, prev);
			chain[n] = prev;
			if (n % 7 == 0) fn1(comp, prev, my_int);
			if (n % 11 == 0) mk_struct(comp, "T", { prev });
			if (n % 13 == 0) tdef(comp, "X", prev);
		}
		assert(ts.len() > N);

		// Handles still decode to the same types; held slices still read correctly.
		test::eq(dmp(comp, f), f_dump);
		check(held.params.len, 2);
		assert(held.params[0].qt == my_int && held.params[1].qt == type_store::LONG);
		check(held_rec.fields.len, 2);
		assert(held_rec.fields[1].qt == type_store::CHAR);
		check(held_rec.fields[1].layout.offset_bits, 32);
		check(a.array_len(comp)!!, 0x1_0000_0001);
		test::eq(dmp(comp, chain[2]), "***int");
		for (uint n = 1; n < N; n += 997)
		{
			assert(chain[n].child_type(comp) == chain[n - 1]);
		}
		assert(chain[N - 1].eql(ptr(comp, chain[N - 2]), comp));
	};
}
