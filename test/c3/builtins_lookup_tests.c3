// Tests for aro::builtins lookup and aro::builtin_properties (plan 12, agent
// 12.4 lookup-props).
//
// Sources of expected values (no Zig executable was run; no differential
// parity is claimed):
// - test/c3/data/builtin_defs_sample.c3: a hand-written table in the
//   generated layout, entries copied from src/aro/Builtins/common.def
//   (source-derived attribute bits).
// - groups_for_arch: the switch in Builtins.zig fromName (source-derived).
// - language_allows: clang builtinIsSupported semantics (source-derived; Zig
//   never evaluates Language).
// - The tests over the real generated tables (round trip, sortedness, arch
//   gating) are generic; //test/c3:builtins_tests checks their contents.
module builtins_lookup_tests;
import aro::builtins, aro::builtin_properties, aro::builtin_defs::sample;
import aro::target, aro::lang_opts, aro::compilation, aro::type_store;
import std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

fn ushort? sample_index(String name)
{
	return builtins::search_names(sample::NAMES, sample::SHORTEST_NAME, sample::LONGEST_NAME, name);
}

<* from_name_in_group over the sample table (the body of Zig fromNameExtra). *>
fn FromName? sample_from_name(String name)
{
	ushort index = sample_index(name)!;
	BuiltinTag tag = { .index = index, .group = sample::GROUP };
	return builtins::from_record(tag, sample::RECORDS[index]);
}

fn bool is_unknown(String name)
{
	if (catch f = sample_index(name)) return f == builtins::UNKNOWN_BUILTIN;
	return false;
}

<* Whether `group` is searched for `arch` (COMMON always). *>
fn bool searched(Arch arch, BuiltinGroup group)
{
	if (group == COMMON) return true;
	foreach (g : builtins::groups_for_arch(arch)) if (g == group) return true;
	return false;
}

fn bool same_groups(BuiltinGroup[] got, BuiltinGroup[] want)
{
	if (got.len != want.len) return false;
	foreach (i, g : got) if (g != want[i]) return false;
	return true;
}

const BuiltinGroup[] EG_AARCH64_AARCH64_NEON_NEON = { AARCH64, AARCH64_NEON, NEON };
const BuiltinGroup[] EG_AMDGCN = { AMDGCN };
const BuiltinGroup[] EG_ARM_NEON = { ARM, NEON };
const BuiltinGroup[] EG_BPF = { BPF };
const BuiltinGroup[] EG_HEXAGON = { HEXAGON };
const BuiltinGroup[] EG_LOONGARCH = { LOONGARCH };
const BuiltinGroup[] EG_MIPS = { MIPS };
const BuiltinGroup[] EG_NVPTX = { NVPTX };
const BuiltinGroup[] EG_POWERPC = { POWERPC };
const BuiltinGroup[] EG_RISCV = { RISCV };
const BuiltinGroup[] EG_S390X = { S390X };
const BuiltinGroup[] EG_VE = { VE };
const BuiltinGroup[] EG_WASM = { WASM };
const BuiltinGroup[] EG_XCORE = { XCORE };
const BuiltinGroup[] EG_X86_64_X86 = { X86_64, X86 };
const BuiltinGroup[] EG_X86 = { X86 };
const BuiltinGroup[] EG_NONE = {};

fn BuiltinGroup[] expected_groups(Arch arch)
{
	switch (arch)
	{
		case AARCH64:
		case AARCH64_BE: return EG_AARCH64_AARCH64_NEON_NEON;
		case AMDGCN: return EG_AMDGCN;
		case ARM:
		case ARMEB:
		case THUMB:
		case THUMBEB: return EG_ARM_NEON;
		case BPFEB:
		case BPFEL: return EG_BPF;
		case HEXAGON: return EG_HEXAGON;
		case LOONGARCH32:
		case LOONGARCH64: return EG_LOONGARCH;
		case MIPS:
		case MIPSEL:
		case MIPS64:
		case MIPS64EL: return EG_MIPS;
		case NVPTX:
		case NVPTX64: return EG_NVPTX;
		case POWERPC:
		case POWERPCLE:
		case POWERPC64:
		case POWERPC64LE: return EG_POWERPC;
		case RISCV32:
		case RISCV32BE:
		case RISCV64:
		case RISCV64BE: return EG_RISCV;
		case S390X: return EG_S390X;
		case VE: return EG_VE;
		case WASM32:
		case WASM64: return EG_WASM;
		case XCORE: return EG_XCORE;
		case X86_64: return EG_X86_64_X86;
		case X86: return EG_X86;
		default: return EG_NONE;
	}
}

fn void sample_round_trip() @test
{
	check(sample::NAMES.len, sample::COUNT);
	check(sample::RECORDS.len, sample::COUNT);
	foreach (i, name : sample::NAMES)
	{
		ushort idx = sample_index(name)!!;
		check(idx, i);
		FromName f = sample_from_name(name)!!;
		check(f.tag.index, i);
		assert(f.tag.group == COMMON);
		assert(f.param_str == sample::RECORDS[i].param_str);
	}
	BuiltinTag t = sample::TAG_ABS;
	check(t.index, 6);
	assert(sample::NAMES[t.index] == "abs");
	t = sample::TAG___BUILTIN_VA_START;
	assert(sample::NAMES[t.index] == "__builtin_va_start");
	t = sample::TAG_PRINTF;
	FromName f = sample_from_name("printf")!!;
	assert(f.tag == t);
}

fn void sample_case_sensitive_and_unknown() @test
{
	check(sample_index("_Exit")!!, 0);
	check(sample_index("_exit")!!, 5);
	assert(is_unknown("_EXIT"));
	assert(is_unknown("ABS"));
	assert(is_unknown(""));
	assert(is_unknown("ab"));                         // shorter than SHORTEST_NAME
	assert(is_unknown("__builtin_c23_va_start_x"));   // longer than LONGEST_NAME
	assert(is_unknown("abt"));                        // in range, absent
	assert(is_unknown("__builtin_ab"));               // proper prefix of a name
	assert(is_unknown("__builtin_abss"));             // extension of a name
	assert(is_unknown("printf "));
	// Empty table: nothing is found, whatever the bounds.
	assert(@catch(builtins::search_names({}, 0, 0, "abs")) == builtins::UNKNOWN_BUILTIN);
}

fn void sample_properties() @test
{
	FromName abs = sample_from_name("abs")!!;
	assert(abs.header == STDLIB);
	assert(abs.header.file == "stdlib.h");
	assert(abs.language == ALL_LANGUAGES);
	assert(abs.attributes.lib_function_without_prefix);
	assert(abs.attributes.is_const);
	assert(abs.attributes.eval_args);
	assert(!abs.attributes.const_evaluable);
	assert(abs.features == "");

	FromName babs = sample_from_name("__builtin_abs")!!;
	Attributes want = builtin_properties::ATTRIBUTES_DEFAULT
		.with_field(LIB_FUNCTION_WITH_BUILTIN_PREFIX, 1)
		.with_field(CONST_EVALUABLE, 1)
		.with_field(CONST, 1);
	check((uint)babs.attributes, (uint)want);
	assert(babs.header == NONE);

	FromName ex = sample_from_name("_exit")!!;
	assert(ex.header == UNISTD);
	assert(ex.language == ALL_GNU_LANGUAGES);

	FromName c23 = sample_from_name("__builtin_c23_va_start")!!;
	assert(c23.language == C23_LANG);
	assert(c23.attributes.custom_typecheck);
	assert(builtin_properties::is_var_args(c23.param_str));
	assert(!builtin_properties::is_var_args(abs.param_str));
	FromName pf = sample_from_name("printf")!!;
	assert(builtin_properties::is_var_args(pf.param_str));
	assert(pf.header == STDIO);
}

fn void compare_bytes_order() @test
{
	assert(builtins::compare_bytes("", "") == 0);
	assert(builtins::compare_bytes("a", "b") < 0);
	assert(builtins::compare_bytes("b", "a") > 0);
	assert(builtins::compare_bytes("ab", "abc") < 0);
	assert(builtins::compare_bytes("_E", "__") < 0);   // 'E' < '_'
	assert(builtins::compare_bytes("_e", "__") > 0);   // 'e' > '_'
	assert(builtins::compare_bytes("\xff", "a") > 0);  // unsigned bytes
	for (usz i = 1; i < sample::NAMES.len; i++)
	{
		assert(builtins::compare_bytes(sample::NAMES[i - 1], sample::NAMES[i]) < 0);
	}
}

fn void groups_per_arch() @test
{
	foreach (arch : Arch::values)
	{
		BuiltinGroup[] got = builtins::groups_for_arch(arch);
		assert(same_groups(got, expected_groups(arch)), "groups for %s", arch.name);
		foreach (g : got) assert(g != COMMON);
	}
	assert(builtins::groups_for_arch(AVR).len == 0);
	assert(builtins::groups_for_arch(SPARC64).len == 0);
	assert(builtins::groups_for_arch(X86_16).len == 0);
	BuiltinGroup[] a64 = builtins::groups_for_arch(AARCH64_BE);
	assert(a64.len == 3 && a64[0] == AARCH64 && a64[1] == AARCH64_NEON && a64[2] == NEON);
}

fn void language_gating() @test
{
	LangOpts o = lang_opts::DEFAULT;
	// Default mode (GNU keywords on top of C17), no MS extensions.
	assert(builtins::language_allows(ALL_LANGUAGES, &o));
	assert(builtins::language_allows(ALL_GNU_LANGUAGES, &o));
	assert(builtins::language_allows(GNU_LANG, &o));
	assert(!builtins::language_allows(ALL_MS_LANGUAGES, &o));
	assert(!builtins::language_allows(C23_LANG, &o));

	o.standard = C11;
	assert(!builtins::language_allows(ALL_GNU_LANGUAGES, &o));
	assert(!builtins::language_allows(GNU_LANG, &o));
	assert(builtins::language_allows(ALL_LANGUAGES, &o));

	o.standard = C23;
	assert(builtins::language_allows(C23_LANG, &o));
	assert(!builtins::language_allows(GNU_LANG, &o));
	o.standard = GNU23;
	assert(builtins::language_allows(C23_LANG, &o));
	assert(builtins::language_allows(GNU_LANG, &o));
	o.standard = C2Y;
	assert(builtins::language_allows(C23_LANG, &o));

	o.set_ms_extensions(true);
	assert(builtins::language_allows(ALL_MS_LANGUAGES, &o));
}

<* The real generated tables: sorted, bounded, and every name round trips. *>
fn void real_tables_round_trip() @test
{
	foreach (g : BuiltinGroup::values)
	{
		String[] names = builtins::group_names(g);
		check(names.len, builtins::group_records(g).len);
		if (!names.len)
		{
			check(builtins::group_shortest_name(g), 0);
			check(builtins::group_longest_name(g), 0);
		}
		foreach (i, name : names)
		{
			if (i) assert(builtins::compare_bytes(names[i - 1], name) < 0, "%s not sorted", g.def_name);
			assert(name.len >= builtins::group_shortest_name(g) && name.len <= builtins::group_longest_name(g));
			BuiltinTag tag = builtins::tag_from_name(g, name)!!;
			check(tag.index, i);
			assert(tag.group == g);
			assert(builtins::name_from_tag(tag) == name);
			FromName f = builtins::from_name_in_group(g, name)!!;
			assert(f.tag == tag);
			BuiltinRecord rec = builtins::record_from_tag(tag);
			assert(f.param_str == rec.param_str && f.features == rec.features);
			assert(builtins::features_of(tag) == rec.features);
			if (!g.has_features) assert(rec.features == "");
		}
	}
}

<*
 Arch gating over the real tables: the first and last name of every group is
 found for an arch iff COMMON or one of its arch groups has it, and the match
 comes from the first such group in search order.
*>
fn void real_tables_arch_gating() @test
{
	foreach (g : BuiltinGroup::values)
	{
		String[] names = builtins::group_names(g);
		if (!names.len) continue;
		foreach (name : (String[]){ names[0], names[^1] })
		{
			foreach (arch : Arch::values)
			{
				BuiltinGroup first;
				bool found_any = false;
				if (try builtins::tag_from_name(COMMON, name))
				{
					first = COMMON;
					found_any = true;
				}
				if (!found_any)
				{
					foreach (ag : builtins::groups_for_arch(arch))
					{
						if (try builtins::tag_from_name(ag, name))
						{
							first = ag;
							found_any = true;
							break;
						}
					}
				}
				FromName? f = builtins::from_name_for_arch(arch, name);
				if (try f)
				{
					assert(found_any);
					assert(f.tag.group == first);
					assert(searched(arch, f.tag.group));
				}
				else
				{
					assert(!found_any);
					assert(!searched(arch, g));
				}
			}
		}
	}
}

fn void unknown_names() @test
{
	foreach (arch : Arch::values)
	{
		foreach (name : (String[]){ "", "not_a_builtin", "__builtin_definitely_not_a_builtin_xyz" })
		{
			assert(@catch(builtins::from_name_for_arch(arch, name)) == builtins::UNKNOWN_BUILTIN);
		}
	}
	foreach (g : BuiltinGroup::values)
	{
		assert(@catch(builtins::tag_from_name(g, "not_a_builtin")) == builtins::UNKNOWN_BUILTIN);
	}
}

fn void cache_and_compilation_field() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		check(comp.builtins.len(), 0);

		// Unknown name: no entry is created.
		assert(@catch(comp.builtins.get_or_create(&comp, "not_a_builtin")) == builtins::UNKNOWN_BUILTIN);
		check(comp.builtins.len(), 0);
		assert(@catch(comp.builtins.find("abs")) == builtins::UNKNOWN_BUILTIN);

		// Insert through the sample table (the real tables may be empty).
		foreach (i, name : sample::NAMES)
		{
			FromName fr = sample_from_name(name)!!;
			Expanded e = comp.builtins.create_from(&comp, sample::NAMES[i], fr);
			assert(e.tag == fr.tag);
			assert(e.header == fr.header && e.language == fr.language);
			check((uint)e.attributes, (uint)fr.attributes);
		}
		check(comp.builtins.len(), sample::NAMES.len);

		// Lookup with a non-static copy of the key.
		char[16] buf;
		buf[0:3] = "abs"[..];
		Expanded e = comp.builtins.lookup((String)buf[0:3]);
		BuiltinTag t = sample::TAG_ABS;
		assert(e.tag == t);
		assert(e.header == STDLIB);

		// Re-inserting returns the cached entry and does not grow the cache.
		FromName fr = sample_from_name("abs")!!;
		Expanded again = comp.builtins.create_from(&comp, "abs", fr);
		assert(again.tag == e.tag && again.qt == e.qt);
		check(comp.builtins.len(), sample::NAMES.len);

		// get_or_create returns a cached entry without consulting the target tables.
		Expanded cached = comp.builtins.get_or_create(&comp, "printf")!!;
		t = sample::TAG_PRINTF;
		assert(cached.tag == t);
		check(comp.builtins.len(), sample::NAMES.len);

		comp.free();
	}
	check(ta.allocation_count(), 0);
}

<* get_or_create over the real tables: every COMMON name is created once and cached. *>
fn void real_get_or_create() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		String[] names = builtins::group_names(COMMON);
		usz limit = names.len < 64 ? names.len : 64;
		foreach (name : names[:limit])
		{
			Expanded e = comp.builtins.get_or_create(&comp, name)!!;
			assert(builtins::name_from_tag(e.tag) == name);
			Expanded l = comp.builtins.lookup(name);
			assert(l.tag == e.tag);
		}
		check(comp.builtins.len(), limit);
		comp.free();
	}
	check(ta.allocation_count(), 0);
}
