// Tests for aro::builtin_type_description (src/c3/builtin_type_description.c3).
//
// Sources of expected values (no Zig executable was run; no differential
// parity is claimed):
// - Signature strings are copied verbatim from src/aro/Builtins/*.def; the
//   builtin each one belongs to is named next to it.
// - Every expected type spelling is source-derived: it follows from reading
//   Builtins.zig createType/createBuiltin/specForSize, TypeDescription.zig,
//   TypeStore.Builder.combine/finish, TypeStore.initNamedTypes (size_t,
//   ptrdiff_t, wchar_t, pid_t, va_list per target) and Target.zig
//   (isLP64, long/long double widths), and is printed with QualType.dump,
//   the spelling used by the AST goldens in test/cases/ast.
module builtin_type_description_tests;
import aro::builtin_type_description, aro::type_store, aro::target, aro::compilation;
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

<*
 Run the body with a compilation for `triple` whose named types are set up
 (type_store::init_named_types), on a tracking allocator; checks nothing leaks.
*>
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
		type_store::init_named_types(&comp);
		@body(&comp);
		comp.free();
	}
	check(ta.allocation_count(), 0);
}

fn String dmp(Compilation* comp, QualType qt)
{
	DString w;
	w.init(tmem);
	qt.dump(comp, w);
	return w.str_view();
}

fn String pr(Compilation* comp, QualType qt)
{
	DString w;
	w.init(tmem);
	qt.print(comp, w);
	return w.str_view();
}

<* A builtin signature and the dump of the function type create_builtin builds. *>
struct Sig
{
	String param_str;
	String dump;
}

fn void check_sigs(Compilation* comp, String triple, Sig[] sigs)
{
	foreach (s : sigs)
	{
		String got = dmp(comp, builtin_type_description::create_builtin(comp, s.param_str));
		if (got != s.dump)
		{
			io::eprintfn("%s: \"%s\": got '%s', expected '%s'", triple, s.param_str, got, s.dump);
		}
		test::eq(got, s.dump);
	}
}

<* Every type description of `param_str`, rendered as prefixes|spec|suffixes. *>
fn String describe(String param_str)
{
	DString w;
	w.init(tmem);
	TypeIterator it = builtin_type_description::type_iterator(param_str);
	while (true)
	{
		TypeDescription? d = it.next();
		if (catch f = d)
		{
			if (f != builtin_type_description::END) w.append_string(w.len() ? " MALFORMED" : "MALFORMED");
			break;
		}
		if (w.len()) w.append_char(' ');
		foreach (p : d.prefixes()) w.appendf("%s", p);
		w.append_char('|');
		w.append_string(d.spec.tag.code);
		switch (d.spec.tag)
		{
			case VECTOR:
			case SCALABLE_VECTOR:
			case EXT_VECTOR: w.appendf("%d", d.spec.count);
			case COMPLEX: w.appendf("%s", d.spec.complex_base);
			case TARGET_TYPE: w.append_char(d.spec.target_type.code);
			default: break;
		}
		w.append_char('|');
		foreach (s : d.suffixes())
		{
			switch (s.tag)
			{
				case POINTER:
					w.append_char('*');
					if (s.has_addr_space) w.appendf("%d", s.addr_space);
				case CONST: w.append_char('C');
				case VOLATILE: w.append_char('D');
				case RESTRICT: w.append_char('R');
			}
		}
	}
	return w.str_view();
}

<* Components of `str` as a compact string, or "MALFORMED" when iteration fails. *>
fn String components(String str)
{
	DString w;
	w.init(tmem);
	ComponentIterator it = builtin_type_description::component_iterator(str);
	while (true)
	{
		Component? c = it.next();
		if (catch f = c)
		{
			if (f != builtin_type_description::END) w.append_string(" MALFORMED");
			break;
		}
		if (w.len()) w.append_char(' ');
		switch (c.kind)
		{
			case PREFIX: w.appendf("P:%s", c.prefix);
			case SPEC: w.appendf("S:%s", c.spec.tag.code);
			case SUFFIX: w.appendf("X:%s", c.suffix.tag);
		}
	}
	return w.str_view();
}

// ---------------------------------------------------------------------------
// Iterators
// ---------------------------------------------------------------------------

fn void component_iterator_basics() @test
{
	// __builtin_addcll "ULLiULLiCULLiCULLiCULLi*" (first two types)
	test::eq(components("ULLiULLiC"), "P:U P:LL S:i P:U P:LL S:i X:CONST");
	// LLL / LL / L greedy prefix split.
	test::eq(components("LLLiLLdLd"), "P:LLL S:i P:LL S:d P:L S:d");
	// SJ is a spec (sigsetjmp "iSJi"); S alone is a prefix.
	test::eq(components("iSJiSc"), "S:i S:SJ S:i P:S S:c");
	// Trailing '.' ends iteration (__builtin_printf "icC*R.").
	test::eq(components("icC*R."), "S:i S:c X:CONST X:POINTER X:RESTRICT");
	// '.' in the middle is malformed (Zig asserts).
	test::eq(components("i.i"), "S:i MALFORMED");
	// Unknown characters, a missing vector count, a bad X / Q payload.
	test::eq(components("i!"), "S:i MALFORMED");
	test::eq(components("Vf"), " MALFORMED");
	test::eq(components("Xi"), " MALFORMED");
	test::eq(components("X"), " MALFORMED");
	test::eq(components("Qz"), " MALFORMED");
	test::eq(components("V99999999999f"), " MALFORMED");
	test::eq(components(""), "");

	// Payloads.
	ComponentIterator it = builtin_type_description::component_iterator("V256dXLdXfQtE16*3*");
	Component c = it.next()!!;
	check(c.kind, ComponentKind.SPEC);
	check(c.spec.tag, SpecTag.VECTOR);
	check(c.spec.count, 256);
	c = it.next()!!;
	check(c.spec.tag, SpecTag.DOUBLE);
	c = it.next()!!;
	check(c.spec.tag, SpecTag.COMPLEX);
	check(c.spec.complex_base, ComplexBase.LONG_DOUBLE);
	c = it.next()!!;
	check(c.spec.complex_base, ComplexBase.FLOAT);
	c = it.next()!!;
	check(c.spec.tag, SpecTag.TARGET_TYPE);
	check(c.spec.target_type, TargetType.AMDGPU_TEXTURE_T);
	// peek does not advance.
	Component p = it.peek()!!;
	check(p.spec.tag, SpecTag.EXT_VECTOR);
	c = it.next()!!;
	check(c.spec.tag, SpecTag.EXT_VECTOR);
	check(c.spec.count, 16);
	c = it.next()!!;
	check(c.kind, ComponentKind.SUFFIX);
	check(c.suffix.tag, SuffixTag.POINTER);
	test::eq(c.suffix.has_addr_space, true);
	check(c.suffix.addr_space, 3);
	c = it.next()!!;
	test::eq(c.suffix.has_addr_space, false);
	test::eq(@catch(it.next()) == builtin_type_description::END, true);
	test::eq(@catch(it.peek()) == builtin_type_description::END, true);

	// Q payloads: a, b, c, t.
	it = builtin_type_description::component_iterator("QaQbQcQt");
	check(it.next()!!.spec.target_type, TargetType.AARCH64_SVCOUNT_T);
	check(it.next()!!.spec.target_type, TargetType.AMDGPU_BUFFER_RSRC_T);
	check(it.next()!!.spec.target_type, TargetType.AMDGPU_FEATURE_PREDICATE_T);
	check(it.next()!!.spec.target_type, TargetType.AMDGPU_TEXTURE_T);
}

fn void type_iterator_splits_types() @test
{
	// __builtin_printf
	test::eq(describe("icC*R."), "|i| |c|C*R");
	// __builtin_va_copy
	test::eq(describe("vAA"), "|v| |A| |A|");
	// __builtin_addcll
	test::eq(describe("ULLiULLiCULLiCULLiCULLi*"), "ULL|i| ULL|i|C ULL|i|C ULL|i|C ULL|i|*");
	// __builtin_cabsl
	test::eq(describe("LdXLd"), "L|d| |XLONG_DOUBLE|");
	// __builtin_neon_vaddq_v: a vector spec and its element are separate descriptions.
	test::eq(describe("V16ScV16ScV16Sci"), "|V16| S|c| |V16| S|c| |V16| S|c| |i|");
	// __builtin_amdgcn_global_load_lds: address spaces.
	test::eq(describe("vv*1v*3IUiIiIUi"), "|v| |v|*1 |v|*3 IU|i| I|i| IU|i|");
	// __builtin_amdgcn_image_load_1d_v4f32_i32: E4 and Qt are specs on their own.
	test::eq(describe("E4fiiQtii"), "|E4| |f| |i| |i| |Qt| |i| |i|");
	// __builtin_ia32_aesdec128kl_u8
	test::eq(describe("UcV2Oi*V2OivC*"), "U|c| |V2| O|i|* |V2| O|i| |v|C*");
	// sigsetjmp
	test::eq(describe("iSJi"), "|i| |SJ| |i|");
	// _m_prefetchw: suffix order is kept.
	test::eq(describe("vvDC*"), "|v| |v|DC*");
	// __builtin_va_arg: only the return type.
	test::eq(describe("v."), "|v|");
	// Malformed: suffix before a spec, prefix with no spec, too many suffixes.
	test::eq(describe("*i"), "MALFORMED");
	test::eq(describe("iU"), "|i| MALFORMED");
	test::eq(describe("i*****"), "MALFORMED");
	test::eq(describe("SLLUIZi"), "MALFORMED");
	test::eq(describe(""), "");

	// A TypeDescription is a value: it stays valid after next() runs again.
	TypeIterator it = builtin_type_description::type_iterator("ULLiCi*");
	TypeDescription first = it.next()!!;
	TypeDescription second = it.next()!!;
	check(first.prefixes().len, 2);
	check(first.prefixes()[0], Prefix.U);
	check(first.prefixes()[1], Prefix.LL);
	check(first.suffixes().len, 1);
	check(first.suffixes()[0].tag, SuffixTag.CONST);
	check(second.prefixes().len, 0);
	check(second.suffixes()[0].tag, SuffixTag.POINTER);
	test::eq(@catch(it.next()) == builtin_type_description::END, true);
}

// ---------------------------------------------------------------------------
// create_builtin per target
// ---------------------------------------------------------------------------

fn void common_builtins_x86_64_linux() @test
{
	String triple = "x86_64-linux-gnu";
	@with_target(triple; Compilation* comp)
	{
		Sig[] sigs = {
			{ "icC*R.", "fn (restrict *const char, ...) int" },                  // __builtin_printf
			{ "v.", "fn (...) void" },                                            // __builtin_va_arg
			{ "b.", "fn (...) _Bool" },                                           // __builtin_add_overflow
			{ "LdLd", "fn (long double) long double" },                           // __builtin_fabsl
			{ "LdXLd", "fn (_Complex long double) long double" },                 // __builtin_cabsl
			{ "XfXf", "fn (_Complex float) _Complex float" },                     // __builtin_csqrtf
			{ "LLd", "fn () __float128" },                                        // __builtin_huge_valf128
			{ "zcC*", "fn (*const char) unsigned long" },                         // __builtin_strlen
			{ "zwC*", "fn (*const int) unsigned long" },                          // __builtin_wcslen
			{ "w*w*wC*z", "fn (*int, *const int, unsigned long) *int" },          // __builtin_wmemcpy
			{ "iv**", "fn (**void) int" },                                        // __builtin_setjmp
			{ "vv**i", "fn (**void, int) void" },                                 // __builtin_longjmp
			{ "ULLiULLiCULLiCULLiCULLi*", "fn (const unsigned long long, const unsigned long long, const unsigned long long, *unsigned long long) unsigned long long" }, // __builtin_addcll
			{ "UWiUWi", "fn (unsigned long) unsigned long" },                    // __builtin_bswap64
			{ "iULi", "fn (unsigned long) int" },                                 // __builtin_clzl
			{ "v*z", "fn (unsigned long) *void" },                                // __builtin_alloca
			{ "v*vC*z.", "fn (*const void, unsigned long, ...) *void" },          // __builtin_assume_aligned
			{ "LLiLLiD*LLi.", "fn (*volatile long long, long long, ...) long long" }, // __sync_fetch_and_add_8
			{ "LLLiLLLiD*LLLi", "fn (*volatile __int128, __int128) __int128" },   // __sync_fetch_and_add_16
			{ "vvCD*vCD*", "fn (*const volatile void, *const volatile void) void" }, // __builtin_assume_separate_storage
			{ "ssCD*", "fn (*const volatile short) short" },                      // __iso_volatile_load16
			{ "p", "fn () int" },                                                 // vfork
			{ "v*v*iv*iv*Y", "fn (*void, int, *void, int, *void, long) *void" },         // __builtin_ptrauth_auth_load_relative_and_sign
			{ "dXd", "fn (_Complex double) double" },                             // __builtin_cabs
			{ "fXf", "fn (_Complex float) float" },                               // __builtin_cabsf
			{ "NiNiD*Ni", "fn (*volatile int, int) int" },                        // _InterlockedAdd (LP64: N is int)
		};
		check_sigs(comp, triple, sigs);
	};
}

fn void x86_builtins() @test
{
	String triple = "x86_64-linux-gnu";
	@with_target(triple; Compilation* comp)
	{
		Sig[] sigs = {
			{ "UOi", "fn () unsigned long long" },                                // __builtin_ia32_rdtsc
			{ "UcUcUOiUOiUOi*", "fn (unsigned char, unsigned long long, unsigned long long, *unsigned long long) unsigned char" }, // __builtin_ia32_addcarryx_u64
			{ "V2OiV2OiV2Oi", "fn (vector(2, long long), vector(2, long long)) vector(2, long long)" }, // __builtin_ia32_aesdec128
			{ "UcV2Oi*V2OivC*", "fn (*vector(2, long long), vector(2, long long), *const void) unsigned char" }, // __builtin_ia32_aesdec128kl_u8
			{ "V16fV16sV16fUsIi", "fn (vector(16, short), vector(16, float), unsigned short, int) vector(16, float)" }, // __builtin_ia32_vcvtph2ps512_mask
			{ "V8yUcV8yV8y", "fn (unsigned char, vector(8, __bf16), vector(8, __bf16)) vector(8, __bf16)" }, // __builtin_ia32_selectpbf_128
			{ "vV8x*V8xUc", "fn (*vector(8, _Float16), vector(8, _Float16), unsigned char) void" }, // __builtin_ia32_storesh128_mask
			{ "vvDC*", "fn (*const volatile void) void" },                        // _m_prefetchw
			{ "SOiSOi*SOiSOiIi", "fn (*long long, long long, long long, int) long long" }, // __builtin_ia32_cmpccxadd64
			{ "UOiUOiIUOi", "fn (unsigned long long, unsigned long long) unsigned long long" }, // __builtin_ia32_bextri_u64
			{ "vv*UOi", "fn (*void, unsigned long long) void" },                  // __builtin_ia32_xsave
		};
		check_sigs(comp, triple, sigs);
	};
	// i386: size_t is unsigned int, long double is still x87 long double.
	triple = "i386-linux-gnu";
	@with_target(triple; Compilation* comp)
	{
		Sig[] sigs = {
			{ "zcC*", "fn (*const char) unsigned int" },                          // __builtin_strlen
			{ "UWiUWi", "fn (unsigned long long) unsigned long long" },          // __builtin_bswap64
			{ "NiNiD*Ni", "fn (*volatile long, long) long" },                     // _InterlockedAdd (not LP64: N is long)
			{ "v*v*iv*iv*Y", "fn (*void, int, *void, int, *void, int) *void" },          // __builtin_ptrauth_auth_load_relative_and_sign
			{ "UOi", "fn () unsigned long long" },                                // __builtin_ia32_rdtsc
		};
		check_sigs(comp, triple, sigs);
	};
}

fn void windows_spellings() @test
{
	// LLP64: long is 32 bits, wchar_t is unsigned short (long double keeps its spelling),
	// size_t is unsigned long long, va_list is char *.
	String triple = "x86_64-windows-msvc";
	@with_target(triple; Compilation* comp)
	{
		Sig[] sigs = {
			{ "zcC*", "fn (*const char) unsigned long long" },                    // __builtin_strlen
			{ "zwC*", "fn (*const unsigned short) unsigned long long" },          // __builtin_wcslen
			{ "LdLd", "fn (long double) long double" },                           // __builtin_fabsl
			{ "UWiUWi", "fn (unsigned long long) unsigned long long" },          // __builtin_bswap64
			{ "NiNiD*Ni", "fn (*volatile int, int) int" },                        // _InterlockedAdd (Target.isLP64 only checks int and pointer widths)
			{ "UiZUi", "fn (unsigned int) unsigned int" },                        // __builtin_arm_cls
			{ "v*v*iv*iv*Y", "fn (*void, int, *void, int, *void, long long) *void" },    // __builtin_ptrauth_auth_load_relative_and_sign
			{ "vAA", "fn (*char, *char) void" },                                  // __builtin_va_copy
			{ "iP*RicC*Ra", "fn (invalid, int, restrict *const char, *char) int" }, // __builtin___vfprintf_chk
		};
		check_sigs(comp, triple, sigs);
	};
}

fn void arm_and_aarch64_builtins() @test
{
	String triple = "aarch64-linux-gnu";
	@with_target(triple; Compilation* comp)
	{
		Sig[] sigs = {
			{ "zwC*", "fn (*const unsigned int) unsigned long" },                 // __builtin_wcslen (wchar_t is unsigned int)
			{ "LdLd", "fn (long double) long double" },                           // __builtin_fabsl
			{ "UWicC*", "fn (*const char) unsigned long" },                       // __builtin_arm_rsr64
			{ "ULLLicC*", "fn (*const char) unsigned __int128" },                 // __builtin_arm_rsr128
			{ "UiUiUWi", "fn (unsigned int, unsigned long) unsigned int" },      // __builtin_arm_crc32d
			{ "Zid", "fn (double) int" },                                         // __builtin_arm_jcvt
			{ "UiSNi", "fn (int) unsigned int" },                                 // _CountLeadingSigns
			{ "vUWi*UWi*", "fn (*unsigned long, *unsigned long) void" },          // __builtin_arm_get_sme_state
			{ "V16ScV16ScV16Sci", "fn (vector(16, signed char), vector(16, signed char), int) vector(16, signed char)" }, // __builtin_neon_vaddq_v
			{ "V8yV8mUWi", "fn (vector(8, __mfp8), unsigned long) vector(8, __bf16)" }, // __builtin_neon_vcvt1_bf16_mf8_fpm
			// Scalable vectors are unsupported: INVALID, and the element becomes a parameter.
			{ "q16ScV16Sc", "fn (signed char, vector(16, signed char)) invalid" }, // __builtin_sve_svdup_neonq_s8
			{ "q8hV8h", "fn (__fp16, vector(8, __fp16)) invalid" },               // __builtin_sve_svdup_neonq_f16
			{ "vAA", "fn (struct __va_list, struct __va_list) void" },            // __builtin_va_copy
		};
		check_sigs(comp, triple, sigs);
	};
	triple = "aarch64-macos";
	@with_target(triple; Compilation* comp)
	{
		Sig[] sigs = {
			{ "zwC*", "fn (*const int) unsigned long" },                          // __builtin_wcslen (Darwin wchar_t is int)
			{ "LdLd", "fn (long double) long double" },                           // __builtin_fabsl
			{ "vAA", "fn (*char, *char) void" },                                  // __builtin_va_copy
		};
		check_sigs(comp, triple, sigs);
	};
	triple = "arm-linux-gnueabihf";
	@with_target(triple; Compilation* comp)
	{
		Sig[] sigs = {
			{ "vUIiUIiLLUiUIi", "fn (unsigned int, unsigned int, unsigned long long, unsigned int) void" }, // __builtin_arm_mcrr
			{ "UiZUi", "fn (unsigned int) unsigned int" },                        // __builtin_arm_cls
			{ "UiWUi", "fn (unsigned long long) unsigned int" },                  // __builtin_arm_cls64
			{ "vIUiC", "fn (const unsigned int) void" },                          // __emit
			{ "zcC*", "fn (*const char) unsigned int" },                          // __builtin_strlen
			{ "zwC*", "fn (*const unsigned int) unsigned int" },                  // __builtin_wcslen
			{ "NiNiD*Ni", "fn (*volatile long, long) long" },                     // _InterlockedAdd
			{ "LLLiLLLiD*LLLi", "fn (*volatile __int128, __int128) __int128" },   // __sync_fetch_and_add_16 (no __int128 on arm; Zig would diagnose)
		};
		check_sigs(comp, triple, sigs);
	};
}

fn void other_architectures() @test
{
	String triple = "powerpc64le-linux-gnu";
	@with_target(triple; Compilation* comp)
	{
		Sig[] sigs = {
			{ "ULLi", "fn () unsigned long long" },                               // __builtin_ppc_get_timebase
			{ "V4UiV4UiV4Ui", "fn (vector(4, unsigned int), vector(4, unsigned int)) vector(4, unsigned int)" }, // __builtin_altivec_vaddcuw
			{ "vCc*IiV16Uc", "fn (*char, int, vector(16, unsigned char)) const void" }, // __builtin_vsx_strmb
			{ "vAA", "fn (*char, *char) void" },                                  // __builtin_va_copy
			{ "LdLd", "fn (long double) long double" },                           // __builtin_fabsl
		};
		check_sigs(comp, triple, sigs);
	};
	triple = "amdgcn-amdhsa";
	@with_target(triple; Compilation* comp)
	{
		Sig[] sigs = {
			{ "UWi", "fn () unsigned long" },                                     // __builtin_amdgcn_s_getpc
			{ "vv*1v*3IUiIiIUi", "fn (*void, *void, unsigned int, int, unsigned int) void" }, // __builtin_amdgcn_global_load_lds
			{ "v*4", "fn () *void" },                                             // __builtin_amdgcn_dispatch_ptr
			{ "LiLi*3Li", "fn (*long, long) long" },                              // __builtin_amdgcn_ds_atomic_barrier_arrive_rtn_b64
			{ "UZiUZiIZi", "fn (unsigned int, int) unsigned int" },               // __builtin_amdgcn_wave_reduce_add_u32
			// Ext vectors and target types are unsupported (INVALID); E's element becomes a parameter.
			{ "E4fiiQtii", "fn (float, int, int, invalid, int, int) invalid" },   // __builtin_amdgcn_image_load_1d_v4f32_i32
			{ "Qbv*sWii", "fn (*void, short, long, int) invalid" },               // __builtin_amdgcn_make_buffer_rsrc
			{ "E4UiE4Ui*i", "fn (unsigned int, invalid, *unsigned int, int) invalid" }, // __builtin_amdgcn_av_load_b128
		};
		check_sigs(comp, triple, sigs);
	};
	triple = "nvptx64-cuda";
	@with_target(triple; Compilation* comp)
	{
		Sig[] sigs = {
			{ "ULLiULLiC*", "fn (*const unsigned long long) unsigned long long" }, // __nvvm_ldg_ull
			{ "LiLiC*", "fn (*const long) long" },                                // __nvvm_ldg_l
			{ "hhC*", "fn (*const __fp16) __fp16" },                              // __nvvm_ldg_h
		};
		check_sigs(comp, triple, sigs);
	};
	triple = "riscv32-linux-gnu";
	@with_target(triple; Compilation* comp)
	{
		Sig[] sigs = {
			{ "UiUi", "fn (unsigned int) unsigned int" },                         // __builtin_riscv_clz_32
			{ "zcC*", "fn (*const char) unsigned int" },                          // __builtin_strlen
			{ "LdLd", "fn (long double) long double" },                           // __builtin_fabsl
			{ "vAA", "fn (*void, *void) void" },                                  // __builtin_va_copy
		};
		check_sigs(comp, triple, sigs);
	};
	triple = "wasm32-wasi";
	@with_target(triple; Compilation* comp)
	{
		Sig[] sigs = {
			{ "zIi", "fn (int) unsigned long" },                                  // __builtin_wasm_memory_size
			{ "LLLiLLLiD*LLLi", "fn (*volatile __int128, __int128) __int128" },   // __sync_fetch_and_add_16
		};
		check_sigs(comp, triple, sigs);
	};
	triple = "loongarch64-linux-gnu";
	@with_target(triple; Compilation* comp)
	{
		Sig[] sigs = {
			{ "iWii", "fn (long, int) int" },                                     // __builtin_loongarch_crc_w_d_w
			{ "WiWiIUWi", "fn (long, unsigned long) long" },                      // __builtin_loongarch_lddir_d
			{ "V16ScV16ScV16Sc", "fn (vector(16, signed char), vector(16, signed char)) vector(16, signed char)" }, // __builtin_lsx_vadd_b
		};
		check_sigs(comp, triple, sigs);
	};
	triple = "mipsel-linux-gnu";
	@with_target(triple; Compilation* comp)
	{
		Sig[] sigs = {
			{ "V4ScV4ScV4Sc", "fn (vector(4, signed char), vector(4, signed char)) vector(4, signed char)" }, // __builtin_mips_addu_qb
		};
		check_sigs(comp, triple, sigs);
	};
	triple = "ve-linux-gnu";
	@with_target(triple; Compilation* comp)
	{
		Sig[] sigs = {
			{ "V256dLUivC*Ui", "fn (unsigned long, *const void, unsigned int) vector(256, double)" }, // __builtin_ve_vl_vld2d_vssl
		};
		check_sigs(comp, triple, sigs);
	};
	triple = "hexagon-linux-musl";
	@with_target(triple; Compilation* comp)
	{
		Sig[] sigs = {
			{ "ii", "fn (int) int" },                                             // __builtin_HEXAGON_A2_abs
			{ "v*LLi*CLLi*iC", "fn (const *long long, *long long, const int) *void" },              // __builtin_brev_ldd
		};
		check_sigs(comp, triple, sigs);
	};
	// xcore: wchar_t is unsigned char.
	triple = "xcore-freestanding";
	@with_target(triple; Compilation* comp)
	{
		Sig[] sigs = {
			{ "zwC*", "fn (*const unsigned char) unsigned int" },                 // __builtin_wcslen
		};
		check_sigs(comp, triple, sigs);
	};
}

// ---------------------------------------------------------------------------
// Named types, va_list and the parser-provided types
// ---------------------------------------------------------------------------

fn void va_list_and_parser_types() @test
{
	String triple = "x86_64-linux-gnu";
	@with_target(triple; Compilation* comp)
	{
		TypeStore* ts = &comp.type_store;
		// Before the Parser runs va_list is the array itself; 'A' uses its decay.
		Sig[] before = {
			{ "vA.", "fn (decayed *[1]struct __va_list_tag, ...) void" },        // __builtin_va_start
			{ "vAA", "fn (decayed *[1]struct __va_list_tag, decayed *[1]struct __va_list_tag) void" }, // __builtin_va_copy
			{ "iP*RicC*Ra", "fn (invalid, int, restrict *const char, [1]struct __va_list_tag) int" }, // __builtin___vfprintf_chk
		};
		check_sigs(comp, triple, before);

		// Parser.init decays va_list (Parser.zig): 'a' then sees the pointer too.
		ts.va_list = ts.va_list.decay(comp);
		Sig[] after = {
			{ "vAA", "fn (decayed *[1]struct __va_list_tag, decayed *[1]struct __va_list_tag) void" }, // __builtin_va_copy
			{ "iP*RicC*Ra", "fn (invalid, int, restrict *const char, decayed *[1]struct __va_list_tag) int" }, // __builtin___vfprintf_chk
		};
		check_sigs(comp, triple, after);

		// FILE / jmp_buf / sigjmp_buf / ucontext_t are INVALID until the parser
		// sees their typedefs; suffixes do not apply then.
		Sig[] missing = {
			{ "iP*RcC*R.", "fn (invalid, restrict *const char, ...) int" },       // fprintf
			{ "iJ", "fn (invalid) int" },                                         // setjmp
			{ "iSJi", "fn (invalid, int) int" },                                  // sigsetjmp
			{ "iK*", "fn (invalid) int" },                                        // getcontext
		};
		check_sigs(comp, triple, missing);

		// Once known, they are used as they are (typedefs kept, pointers applied).
		RecordField[1] fields = { type_store::record_field(comp.intern_string("x"), type_store::INT) };
		QualType file_struct = ts.put(type_store::type_record(comp.intern_string("_IO_FILE"), &fields, type_store::natural_record_layout(comp, &fields)));
		ts.file = ts.put(type_store::type_typedef(file_struct, comp.intern_string("FILE"), (NodeIndex)0));
		ts.jmp_buf = ts.put(type_store::type_typedef(ts.put(type_store::type_array(type_store::LONG, FIXED, 8)), comp.intern_string("jmp_buf"), (NodeIndex)0));
		ts.ucontext_t = ts.put(type_store::type_typedef(file_struct, comp.intern_string("ucontext_t"), (NodeIndex)0));
		Sig[] known = {
			{ "iP*RcC*R.", "fn (restrict *FILE: struct _IO_FILE, restrict *const char, ...) int" }, // fprintf
			{ "iJ", "fn (jmp_buf: [8]long) int" },                                // setjmp
			{ "iK*", "fn (*ucontext_t: struct _IO_FILE) int" },                   // getcontext
		};
		check_sigs(comp, triple, known);

		// CFString (FC*): the NSConstantString record.
		test::eq(dmp(comp, builtin_type_description::create_builtin(comp, "FC*cC*")),
			"fn (*const char) *const struct __NSConstantString_tag"); // __builtin___CFStringMakeConstantString
	};
}

fn void create_type_direct() @test
{
	@with_target("x86_64-linux-gnu"; Compilation* comp)
	{
		// Individual descriptions, printed with QualType.print.
		TypeIterator it = builtin_type_description::type_iterator("ULLiC*RcC*DLLdSJ");
		QualType t1 = builtin_type_description::create_type(comp, it.next()!!, &it);
		test::eq(pr(comp, t1), "const unsigned long long *restrict");
		QualType t2 = builtin_type_description::create_type(comp, it.next()!!, &it);
		test::eq(pr(comp, t2), "const char *volatile");
		QualType t3 = builtin_type_description::create_type(comp, it.next()!!, &it);
		test::eq(t3 == type_store::FLOAT128, true);
		QualType t4 = builtin_type_description::create_type(comp, it.next()!!, &it);
		test::eq(t4.is_invalid(), true); // sigjmp_buf unknown before the parser

		// A vector element's suffixes apply to the vector (V2Oi*).
		it = builtin_type_description::type_iterator("V2Oi*C");
		QualType v = builtin_type_description::create_type(comp, it.next()!!, &it);
		test::eq(dmp(comp, v), "const *vector(2, long long)");
		test::eq(@catch(it.next()) == builtin_type_description::END, true);

		// Inconsistent descriptions Zig asserts on / cannot combine: INVALID.
		test::eq(builtin_type_description::create_builtin(comp, "Nd").is_invalid(), false);
		test::eq(dmp(comp, builtin_type_description::create_builtin(comp, "Nd")), "fn () invalid");
		test::eq(dmp(comp, builtin_type_description::create_builtin(comp, "Uf")), "fn () invalid");
		test::eq(dmp(comp, builtin_type_description::create_builtin(comp, "Sz")), "fn () invalid");
		test::eq(dmp(comp, builtin_type_description::create_builtin(comp, "iY*")), "fn (invalid) int");
		// 'R' on a non-pointer is dropped (Zig: restrict_non_pointer).
		test::eq(dmp(comp, builtin_type_description::create_builtin(comp, "iiR")), "fn (int) int");
		// Malformed param strings give INVALID.
		test::eq(builtin_type_description::create_builtin(comp, "").is_invalid(), true);
		test::eq(builtin_type_description::create_builtin(comp, "i*i!").is_invalid(), true);
		// 32 parameters fit (Zig's buffer); 33 do not.
		test::eq(builtin_type_description::create_builtin(comp, "vii" "iiiiiiiiii" "iiiiiiiiii" "iiiiiiiiii").is_invalid(), false);
		test::eq(builtin_type_description::create_builtin(comp, "viii" "iiiiiiiiii" "iiiiiiiiii" "iiiiiiiiii").is_invalid(), true);
	};
	// OpenCL: O means long, not long long.
	@with_target("spirv64-opencl"; Compilation* comp)
	{
		test::eq(dmp(comp, builtin_type_description::create_builtin(comp, "UOiOi")), "fn (long) unsigned long");
	};
}
