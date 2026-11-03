// Plan 12 stage 2 acceptance tests over the real generated builtin tables
// (//:builtin_defs, one aro::builtin_defs::<group> module per .def file).
//
// Sources of expected values (no Zig executable was run; no differential
// parity is claimed):
// - Per-group counts and the uppercase-collision counts were taken from the
//   .def files themselves (name lines; names whose ASCII-uppercased form
//   repeats in the same file).
// - def_cross_check re-reads every .def file at test time (Bazel data) with a
//   small independent line scanner (names, param_str, header, language,
//   features) and compares each entry with the generated table.
// - Expected signature dumps are source-derived from Builtins.zig
//   createType/createBuiltin, TypeStore.initNamedTypes and Target.zig, in the
//   QualType.dump spelling of the AST goldens; param strings are quoted from
//   the cited .def lines.
// - Attribute bits are computed by hand from the Attributes bit table in
//   tools/builtins_schema.md (eval_args 0x10000 is the default).
module builtins_tests;
import aro::builtins, aro::builtin_properties, aro::builtin_type_description;
import aro::builtin_defs::common, aro::builtin_defs::ve, aro::builtin_defs::x86;
import aro::target, aro::compilation, aro::type_store;
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

<* Run the body with a compilation for `triple` (named types set up) on a tracking allocator; checks nothing leaks. *>
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

fn char upper(char c) => c >= 'a' && c <= 'z' ? c - 32 : c;

fn bool upper_eq(String a, String b)
{
	if (a.len != b.len) return false;
	foreach (i, c : a) if (upper(c) != upper(b[i])) return false;
	return true;
}

// ---------------------------------------------------------------------------
// Table shape and round trips
// ---------------------------------------------------------------------------

struct GroupCount
{
	BuiltinGroup group;
	uint count;
	uint upper_collisions; // names whose uppercased form equals another name's
}

<* Source-derived from the .def files (name lines; see module comment). *>
const GroupCount[] COUNTS = {
	{ AARCH64, 241, 0 },
	{ AARCH64_NEON, 36, 0 },
	{ AMDGCN, 844, 0 },
	{ ARM, 260, 0 },
	{ BPF, 4, 0 },
	{ COMMON, 1503, 2 },   // _Exit / _exit
	{ HEXAGON, 2040, 0 },
	{ LOONGARCH, 1517, 0 },
	{ MIPS, 669, 0 },
	{ NEON, 1084, 0 },
	{ NVPTX, 877, 0 },
	{ POWERPC, 545, 0 },
	{ RISCV, 161, 0 },
	{ S390X, 291, 0 },
	{ VE, 1263, 16 },      // 8 pairs such as __builtin_ve_vl_andm_MMM / _mmm
	{ WASM, 132, 0 },
	{ X86_64, 165, 0 },
	{ X86, 1916, 0 },
	{ XCORE, 4, 0 },
};

fn void counts_and_collisions() @test
{
	check(COUNTS.len, BuiltinGroup::len);
	usz total = 0;
	foreach (i, c : COUNTS)
	{
		assert(c.group.ordinal == i);
		String[] names = builtins::group_names(c.group);
		check(names.len, c.count);
		check(builtins::group_records(c.group).len, c.count);
		total += names.len;
		// Equal uppercased forms need not be adjacent in bytewise order: compare all pairs.
		uint collisions = 0;
		foreach (a, name : names)
		{
			foreach (b, other : names)
			{
				if (a != b && upper_eq(name, other))
				{
					collisions++;
					break;
				}
			}
		}
		check(collisions, c.upper_collisions);
	}
	check(total, 13552);
	check(common::COUNT, 1503);
	check(ve::COUNT, 1263);
}

<* Every definition in every group: name -> tag -> name / record, sortedness and length bounds. *>
fn void round_trip_every_definition() @test
{
	foreach (g : BuiltinGroup::values)
	{
		String[] names = builtins::group_names(g);
		BuiltinRecord[] records = builtins::group_records(g);
		assert(names.len > 0);
		usz shortest = usz::max;
		usz longest = 0;
		foreach (i, name : names)
		{
			if (i) assert(builtins::compare_bytes(names[i - 1], name) < 0, "%s: not sorted at %d", g.def_name, i);
			if (name.len < shortest) shortest = name.len;
			if (name.len > longest) longest = name.len;
			BuiltinTag tag = builtins::tag_from_name(g, name)!!;
			assert(tag.group == g);
			check(tag.index, i);
			assert(builtins::name_from_tag(tag).ptr == name.ptr);
			BuiltinRecord rec = builtins::record_from_tag(tag);
			BuiltinRecord want = records[i];
			assert(rec.param_str == want.param_str && rec.features == want.features);
			assert(rec.header == want.header && rec.language == want.language);
			check((uint)rec.attributes, (uint)want.attributes);
			assert(rec.param_str.len > 0, "%s: empty param_str", name);
			if (!g.has_features) assert(rec.features == "");
			FromName f = builtins::from_name_in_group(g, name)!!;
			assert(f.tag == tag && f.param_str == rec.param_str && f.header == rec.header);
			// A copy of the name (not the static table string) finds the same tag.
			String copy = name.tcopy();
			assert(builtins::tag_from_name(g, copy)!! == tag);
		}
		check(builtins::group_shortest_name(g), shortest);
		check(builtins::group_longest_name(g), longest);
	}
}

<* TAG_ constants agree with lookup; colliding names have none. *>
fn void tag_constants() @test
{
	BuiltinTag t = common::TAG___BUILTIN_VA_START;
	assert(builtins::tag_from_name(COMMON, "__builtin_va_start")!! == t);
	t = common::TAG_PRINTF;
	assert(builtins::name_from_tag(t) == "printf");
	t = x86::TAG___BUILTIN_IA32_RDTSC;
	assert(builtins::tag_from_name(X86, "__builtin_ia32_rdtsc")!! == t);
	t = ve::TAG___BUILTIN_VE_VL_PACK_F32P;
	assert(builtins::name_from_tag(t) == "__builtin_ve_vl_pack_f32p");
	// Collision pairs: both names exist, neither gets a TAG_ constant.
	assert(!$defined(common::TAG__EXIT));
	assert(!$defined(ve::TAG___BUILTIN_VE_VL_ANDM_MMM));
	BuiltinTag lo = builtins::tag_from_name(COMMON, "_exit")!!;
	BuiltinTag hi = builtins::tag_from_name(COMMON, "_Exit")!!;
	assert(lo != hi);
	lo = builtins::tag_from_name(VE, "__builtin_ve_vl_andm_mmm")!!;
	hi = builtins::tag_from_name(VE, "__builtin_ve_vl_andm_MMM")!!;
	assert(lo != hi);
	assert(builtins::record_from_tag(lo).param_str == "V256bV256bV256b"); // ve.def:6
	assert(builtins::record_from_tag(hi).param_str == "V512bV512bV512b"); // ve.def:3
}

<* Records with every property kind, source-derived from common.def. *>
fn void record_properties() @test
{
	// common.def:2385 _Exit: "vi", header stdlib, lib_function_without_prefix
	BuiltinRecord r = builtins::record_from_tag(builtins::tag_from_name(COMMON, "_Exit")!!);
	assert(r.param_str == "vi" && r.header == STDLIB && r.language == ALL_LANGUAGES);
	check((uint)r.attributes, 0x10040);
	// common.def:3003 _exit: header unistd, all_gnu_languages
	r = builtins::record_from_tag(builtins::tag_from_name(COMMON, "_exit")!!);
	assert(r.header == UNISTD && r.language == ALL_GNU_LANGUAGES);
	check((uint)r.attributes, 0x10040);
	// common.def:491 abs: lib_function_without_prefix + const
	r = builtins::record_from_tag(builtins::tag_from_name(COMMON, "abs")!!);
	assert(r.param_str == "ii" && r.header == STDLIB);
	check((uint)r.attributes, 0x10044);
	assert(r.attributes.is_const && r.attributes.lib_function_without_prefix && r.attributes.eval_args);
	// common.def:992 __builtin_c23_va_start: c23_lang, custom_typecheck
	r = builtins::record_from_tag(builtins::tag_from_name(COMMON, "__builtin_c23_va_start")!!);
	assert(r.param_str == "vA." && r.language == C23_LANG);
	check((uint)r.attributes, 0x10008);
	// aarch64.def:925 __builtin_arm_crc32d: features "crc", const
	r = builtins::record_from_tag(builtins::tag_from_name(AARCH64, "__builtin_arm_crc32d")!!);
	assert(r.param_str == "UiUiUWi" && r.features == "crc");
	check((uint)r.attributes, 0x10004);
	// riscv.def:183 __builtin_riscv_clz_64: compound feature expression kept raw
	r = builtins::record_from_tag(builtins::tag_from_name(RISCV, "__builtin_riscv_clz_64")!!);
	assert(r.features == "zbb|xtheadbb,64bit");
}

// ---------------------------------------------------------------------------
// Cross-check against the .def sources (Bazel data, runfiles-relative)
// ---------------------------------------------------------------------------

fn String prop_string(String rest)
{
	// rest is `= "..."` (spaces optional)
	sz q1 = rest.index_of_char('"')!!;
	String tail = rest[q1 + 1..];
	sz q2 = tail.index_of_char('"')!!;
	return tail[:q2];
}

fn String prop_enum(String rest)
{
	sz dot = rest.index_of_char('.')!!;
	return rest[dot + 1..].trim();
}

struct Pending
{
	String name;
	BuiltinRecord rec;
	bool active;
}

fn void flush(BuiltinGroup g, Pending* p, uint* seen)
{
	if (!p.active) return;
	BuiltinTag? tag = builtins::tag_from_name(g, p.name);
	if (catch tag)
	{
		io::eprintfn("%s: '%s' missing from the generated table", g.def_name, p.name);
		unreachable();
	}
	BuiltinRecord got = builtins::record_from_tag(tag);
	if (got.param_str != p.rec.param_str || got.header != p.rec.header
		|| got.language != p.rec.language || got.features != p.rec.features)
	{
		io::eprintfn("%s: '%s' record mismatch: got {%s,%s,%s,%s} want {%s,%s,%s,%s}", g.def_name, p.name,
			got.param_str, got.header, got.language, got.features,
			p.rec.param_str, p.rec.header, p.rec.language, p.rec.features);
		unreachable();
	}
	(*seen)++;
	p.active = false;
}

<* Every .def entry is in its generated table with the same record, and nothing else is. *>
fn void def_cross_check() @test
{
	foreach (g : BuiltinGroup::values)
	{
		String path = string::tformat("src/aro/Builtins/%s.def", g.def_name);
		String text = (String)file::load(tmem, path)!!;
		Pending p;
		uint seen = 0;
		foreach (raw : text.tsplit("\n"))
		{
			String line = raw.trim(" \t\r");
			if (!line.len || line[0] == '#') continue;
			if (line[0] != '.')
			{
				flush(g, &p, &seen);
				p = { .name = line, .rec = builtin_properties::RECORD_DEFAULT, .active = true };
				continue;
			}
			if (line.starts_with(".param_str"))
			{
				p.rec.param_str = prop_string(line[10..]);
			}
			else if (line.starts_with(".features"))
			{
				p.rec.features = prop_string(line[9..]);
			}
			else if (line.starts_with(".header"))
			{
				p.rec.header = builtin_properties::header_from_name(prop_enum(line[7..]))!!;
			}
			else if (line.starts_with(".language"))
			{
				p.rec.language = builtin_properties::language_from_name(prop_enum(line[9..]))!!;
			}
		}
		flush(g, &p, &seen);
		check(seen, builtins::group_names(g).len);
	}
}

// ---------------------------------------------------------------------------
// create_builtin over every definition
// ---------------------------------------------------------------------------

<* Specs that create_type maps to INVALID by design (unsupported, or parser-provided typedefs). *>
fn bool may_be_invalid(String param_str)
{
	TypeIterator it = builtin_type_description::type_iterator(param_str);
	bool hit = false;
	while (true)
	{
		TypeDescription? d = it.next();
		if (catch f = d)
		{
			assert(f == builtin_type_description::END, "MALFORMED param_str '%s'", param_str);
			break;
		}
		switch (d.spec.tag)
		{
			case SCALABLE_VECTOR:
			case TARGET_TYPE:
			case EXT_VECTOR:
			case FILE:
			case JMP_BUF:
			case SIGJMP_BUF:
			case UCONTEXT: hit = true;
			default: break;
		}
	}
	return hit;
}

struct GroupTarget
{
	BuiltinGroup group;
	String triple;
}

<* Representative targets per group (every group at least once; shared groups on several). *>
const GroupTarget[] GROUP_TARGETS = {
	{ COMMON, "x86_64-linux-gnu" },
	{ COMMON, "i386-linux-gnu" },
	{ COMMON, "aarch64-linux-gnu" },
	{ COMMON, "x86_64-windows-msvc" },
	{ COMMON, "riscv32-linux-gnu" },
	{ AARCH64, "aarch64-linux-gnu" },
	{ AARCH64_NEON, "aarch64-linux-gnu" },
	{ NEON, "aarch64-linux-gnu" },
	{ NEON, "arm-linux-gnueabihf" },
	{ ARM, "arm-linux-gnueabihf" },
	{ AMDGCN, "amdgcn-amdhsa" },
	{ BPF, "bpfel-freestanding" },
	{ HEXAGON, "hexagon-linux-musl" },
	{ LOONGARCH, "loongarch64-linux-gnu" },
	{ MIPS, "mipsel-linux-gnu" },
	{ NVPTX, "nvptx64-cuda" },
	{ POWERPC, "powerpc64le-linux-gnu" },
	{ RISCV, "riscv64-linux-gnu" },
	{ S390X, "s390x-linux-gnu" },
	{ VE, "ve-linux-gnu" },
	{ WASM, "wasm32-wasi" },
	{ X86_64, "x86_64-linux-gnu" },
	{ X86, "x86_64-linux-gnu" },
	{ X86, "i386-linux-gnu" },
	{ XCORE, "xcore-freestanding" },
};

<*
 create_builtin yields a function type for every definition on a target of its
 group; an INVALID return or parameter only appears when the param_str uses a
 spec that is INVALID by design. get_or_create on that target finds the name.
*>
fn void create_every_builtin() @test
{
	BuiltinGroup[BuiltinGroup::len] covered_list;
	usz covered = 0;
	foreach (gt : GROUP_TARGETS)
	{
		@with_target(gt.triple; Compilation* comp)
		{
			uint unexpected = 0;
			foreach (name : builtins::group_names(gt.group))
			{
				FromName fr = builtins::from_name_in_group(gt.group, name)!!;
				Expanded e = comp.builtins.create_from(comp, name, fr);
				assert(!e.qt.is_invalid(), "%s: %s '%s' gave an invalid type", gt.triple, name, fr.param_str);
				Func? fn_ty = e.qt.get_func(comp);
				if (catch fn_ty)
				{
					io::eprintfn("%s: %s is not a function type", gt.triple, name);
					unreachable();
				}
				check(fn_ty.kind == VARIADIC, builtin_properties::is_var_args(fr.param_str));
				bool has_invalid = fn_ty.return_type.is_invalid();
				foreach (param : fn_ty.params) if (param.qt.is_invalid()) has_invalid = true;
				if (has_invalid && !may_be_invalid(fr.param_str))
				{
					io::eprintfn("%s: %s '%s' -> %s", gt.triple, name, fr.param_str, dmp(comp, e.qt));
					unexpected++;
				}
				// Target gating: the name resolves on this target (possibly from an earlier group).
				FromName found = builtins::from_name(comp, name)!!;
				assert(builtins::name_from_tag(found.tag) == name);
			}
			check(unexpected, 0);
			check(comp.builtins.len(), builtins::group_names(gt.group).len);
		};
		bool dup = false;
		foreach (c : covered_list[:covered]) if (c == gt.group) dup = true;
		if (!dup) covered_list[covered++] = gt.group;
	}
	check(covered, BuiltinGroup::len);
}

// ---------------------------------------------------------------------------
// Representative signatures per architecture (by name, through get_or_create)
// ---------------------------------------------------------------------------

struct NamedSig
{
	String name;
	BuiltinGroup group; // the group the name must resolve to on this target
	String dump;
}

fn void check_named(String triple, NamedSig[] sigs)
{
	@with_target(triple; Compilation* comp)
	{
		foreach (s : sigs)
		{
			Expanded? e = comp.builtins.get_or_create(comp, s.name);
			if (catch e)
			{
				io::eprintfn("%s: %s not found", triple, s.name);
				unreachable();
			}
			String got = dmp(comp, e.qt);
			if (got != s.dump || e.tag.group != s.group)
			{
				io::eprintfn("%s: %s: got '%s' (%s), expected '%s' (%s)", triple, s.name, got, e.tag.group, s.dump, s.group);
			}
			test::eq(got, s.dump);
			assert(e.tag.group == s.group);
			assert(builtins::name_from_tag(e.tag) == s.name);
			// Second call hits the cache.
			Expanded again = comp.builtins.get_or_create(comp, s.name)!!;
			assert(again.qt == e.qt && again.tag == e.tag);
		}
		check(comp.builtins.len(), sigs.len);
	};
}

fn void signatures_per_arch() @test
{
	check_named("x86_64-linux-gnu", {
		{ "__builtin_strlen", COMMON, "fn (*const char) unsigned long" },                 // common.def:5807 "zcC*"
		{ "__builtin_printf", COMMON, "fn (restrict *const char, ...) int" },             // common.def:1080 "icC*R."
		{ "__builtin_ia32_rdtsc", X86, "fn () unsigned long long" },                      // x86.def:5104 "UOi"
		{ "__builtin_ia32_readeflags_u64", X86_64, "fn () unsigned long long" },          // x86_64.def:246 "UOi"
		{ "__builtin_ia32_xsave64", X86_64, "fn (*void, unsigned long long) void" },      // x86_64.def:697 "vv*UOi"
		{ "__builtin_ia32_aesdec128", X86, "fn (vector(2, long long), vector(2, long long)) vector(2, long long)" }, // x86.def:278
	});
	check_named("i386-linux-gnu", {
		{ "__builtin_strlen", COMMON, "fn (*const char) unsigned int" },
		{ "__builtin_ia32_readeflags_u32", X86, "fn () unsigned int" },                   // x86.def:5110 "Ui"
	});
	check_named("aarch64-linux-gnu", {
		{ "__builtin_arm_crc32d", AARCH64, "fn (unsigned int, unsigned long) unsigned int" }, // aarch64.def:925 "UiUiUWi"
		{ "_InterlockedAdd", AARCH64, "fn (*volatile int, int) int" },                    // aarch64.def:98 "NiNiD*Ni"
		{ "__builtin_neon_vaddq_v", NEON, "fn (vector(16, signed char), vector(16, signed char), int) vector(16, signed char)" }, // neon.def:135
		{ "__builtin_sve_svdup_neonq_s8", AARCH64_NEON, "fn (signed char, vector(16, signed char)) invalid" }, // aarch64_neon.def:31 "q16ScV16Sc"
		{ "__builtin_va_copy", COMMON, "fn (struct __va_list, struct __va_list) void" },  // common.def:6737 "vAA"
	});
	check_named("arm-linux-gnueabihf", {
		{ "__builtin_arm_crc32d", ARM, "fn (unsigned int, unsigned long long) unsigned int" }, // arm.def:616 "UiUiLLUi"
		{ "__builtin_arm_mcrr", ARM, "fn (unsigned int, unsigned int, unsigned long long, unsigned int) void" }, // arm.def:680
		{ "__builtin_neon_vaddq_v", NEON, "fn (vector(16, signed char), vector(16, signed char), int) vector(16, signed char)" },
		{ "__builtin_strlen", COMMON, "fn (*const char) unsigned int" },
	});
	check_named("amdgcn-amdhsa", {
		{ "__builtin_amdgcn_s_getpc", AMDGCN, "fn () unsigned long" },                    // amdgcn.def:2781 "UWi"
	});
	check_named("bpfel-freestanding", {
		{ "__builtin_btf_type_id", BPF, "fn (...) unsigned long" },                       // bpf.def:3 "LUi."
	});
	check_named("hexagon-linux-musl", {
		{ "__builtin_HEXAGON_A2_abs", HEXAGON, "fn (int) int" },                          // hexagon.def:95 "ii"
	});
	check_named("loongarch64-linux-gnu", {
		{ "__builtin_loongarch_crc_w_d_w", LOONGARCH, "fn (long, int) int" },             // loongarch.def:3826 "iWii"
		{ "__builtin_lsx_vadd_b", LOONGARCH, "fn (vector(16, signed char), vector(16, signed char)) vector(16, signed char)" }, // loongarch.def:4064
	});
	check_named("mipsel-linux-gnu", {
		{ "__builtin_mips_addu_qb", MIPS, "fn (vector(4, signed char), vector(4, signed char)) vector(4, signed char)" }, // mips.def:43
	});
	check_named("nvptx64-cuda", {
		{ "__nvvm_ldg_l", NVPTX, "fn (*const long) long" },                               // nvptx.def:2179 "LiLiC*"
	});
	check_named("powerpc64le-linux-gnu", {
		{ "__builtin_ppc_get_timebase", POWERPC, "fn () unsigned long long" },            // powerpc.def:1327 "ULLi"
		{ "__builtin_altivec_vaddcuw", POWERPC, "fn (vector(4, unsigned int), vector(4, unsigned int)) vector(4, unsigned int)" }, // powerpc.def:119
	});
	check_named("riscv64-linux-gnu", {
		{ "__builtin_riscv_clz_64", RISCV, "fn (unsigned long) unsigned int" },           // riscv.def:183 "UiUWi"
	});
	check_named("s390x-linux-gnu", {
		{ "__builtin_s390_vupllh", S390X, "fn (vector(8, unsigned short)) vector(4, unsigned int)" }, // s390x.def:1444 "V4UiV8Us"
		{ "__builtin_non_tx_store", S390X, "fn (*unsigned long, unsigned long) void" },   // s390x.def:3 "vULi*ULi"
	});
	check_named("ve-linux-gnu", {
		{ "__builtin_ve_vl_vld2d_vssl", VE, "fn (unsigned long, *const void, unsigned int) vector(256, double)" }, // ve.def:2778
		{ "__builtin_ve_vl_pack_f32p", VE, "fn (*const float, *const float) unsigned long" }, // ve.def:84 "ULifC*fC*"
	});
	check_named("wasm32-wasi", {
		{ "__builtin_wasm_memory_size", WASM, "fn (int) unsigned long" },                 // wasm.def:201 "zIi"
	});
	check_named("xcore-freestanding", {
		{ "__builtin_bitrev", XCORE, "fn (unsigned int) unsigned int" },                  // xcore.def:3 "UiUi"
	});
}

// ---------------------------------------------------------------------------
// Target gating and unknown names
// ---------------------------------------------------------------------------

fn bool in_arch_groups(Arch arch, BuiltinGroup g)
{
	foreach (ag : builtins::groups_for_arch(arch)) if (ag == g) return true;
	return false;
}

<*
 For every name of every group and every arch: from_name_for_arch finds it iff
 COMMON or one of groups_for_arch(arch) has it, and the first such group wins.
*>
fn void gating_every_name_every_arch() @test
{
	foreach (g : BuiltinGroup::values)
	{
		foreach (name : builtins::group_names(g))
		{
			foreach (arch : Arch::values)
			{
				BuiltinGroup first;
				bool hit = false;
				if (try builtins::tag_from_name(COMMON, name))
				{
					first = COMMON;
					hit = true;
				}
				else
				{
					foreach (ag : builtins::groups_for_arch(arch))
					{
						if (try builtins::tag_from_name(ag, name))
						{
							first = ag;
							hit = true;
							break;
						}
					}
				}
				FromName? f = builtins::from_name_for_arch(arch, name);
				if (try f)
				{
					assert(hit && f.tag.group == first);
				}
				else
				{
					assert(!hit && g != COMMON && !in_arch_groups(arch, g));
				}
			}
		}
	}
}

struct Gate
{
	String name;
	Arch arch;
	bool found;
}

const Gate[] GATES = {
	{ "__builtin_ia32_rdtsc", X86_64, true },
	{ "__builtin_ia32_rdtsc", X86, true },
	{ "__builtin_ia32_rdtsc", AARCH64, false },
	{ "__builtin_ia32_readeflags_u64", X86_64, true },
	{ "__builtin_ia32_readeflags_u64", X86, false },
	{ "__builtin_sve_svdup_neonq_s8", AARCH64, true },
	{ "__builtin_sve_svdup_neonq_s8", AARCH64_BE, true },
	{ "__builtin_sve_svdup_neonq_s8", ARM, false },
	{ "__builtin_neon_vaddq_v", ARM, true },
	{ "__builtin_neon_vaddq_v", THUMBEB, true },
	{ "__builtin_neon_vaddq_v", AARCH64, true },
	{ "__builtin_neon_vaddq_v", X86_64, false },
	{ "__builtin_btf_type_id", BPFEB, true },
	{ "__builtin_btf_type_id", X86_64, false },
	{ "__builtin_amdgcn_s_getpc", AMDGCN, true },
	{ "__builtin_amdgcn_s_getpc", NVPTX64, false },
	{ "__nvvm_ldg_l", NVPTX, true },
	{ "__builtin_ve_vl_pack_f32p", VE, true },
	{ "__builtin_ve_vl_pack_f32p", SPARC64, false },
	{ "__builtin_bitrev", XCORE, true },
	{ "__builtin_bitrev", MIPS, false },
	{ "__builtin_mips_addu_qb", MIPS64EL, true },
	{ "__builtin_riscv_clz_64", RISCV32, true },
	{ "__builtin_riscv_clz_64", LOONGARCH64, false },
	{ "__builtin_HEXAGON_A2_abs", HEXAGON, true },
	{ "__builtin_s390_vupllh", S390X, true },
	{ "__builtin_wasm_memory_size", WASM64, true },
	{ "__builtin_wasm_memory_size", X86_64, false },
	{ "__builtin_strlen", SPARC64, true },
	{ "__builtin_strlen", MSP430, true },
};

fn void gating_examples() @test
{
	foreach (gate : GATES)
	{
		bool found = @ok(builtins::from_name_for_arch(gate.arch, gate.name));
		if (found != gate.found) io::eprintfn("%s on %s: found=%s", gate.name, gate.arch, found);
		assert(found == gate.found);
	}
	// Through a Compilation: get_or_create is gated by comp.target and caches nothing on a miss.
	@with_target("aarch64-linux-gnu"; Compilation* comp)
	{
		assert(@catch(comp.builtins.get_or_create(comp, "__builtin_ia32_rdtsc")) == builtins::UNKNOWN_BUILTIN);
		check(comp.builtins.len(), 0);
		Expanded e = comp.builtins.get_or_create(comp, "_BitScanForward64")!!;
		assert(e.tag.group == AARCH64);
	};
	@with_target("x86_64-linux-gnu"; Compilation* comp)
	{
		Expanded e = comp.builtins.get_or_create(comp, "_BitScanForward64")!!;
		assert(e.tag.group == X86_64);
	};
}

fn void unknown_names() @test
{
	String[] unknown = {
		"", "_", "__builtin_", "__builtin_strle", "__builtin_strlenx", "__BUILTIN_STRLEN",
		"_EXIT", "__builtin_ve_vl_andm_Mmm", "__builtin_strlen\0", " __builtin_strlen",
		"__builtin_this_name_is_much_longer_than_any_real_builtin_name_in_any_group_of_the_tables",
	};
	foreach (name : unknown)
	{
		foreach (arch : Arch::values)
		{
			assert(@catch(builtins::from_name_for_arch(arch, name)) == builtins::UNKNOWN_BUILTIN, "'%s' found", name);
		}
		foreach (g : BuiltinGroup::values)
		{
			assert(@catch(builtins::tag_from_name(g, name)) == builtins::UNKNOWN_BUILTIN);
		}
	}
	@with_target("x86_64-linux-gnu"; Compilation* comp)
	{
		foreach (name : unknown)
		{
			assert(@catch(comp.builtins.get_or_create(comp, name)) == builtins::UNKNOWN_BUILTIN);
		}
		check(comp.builtins.len(), 0);
	};
}
