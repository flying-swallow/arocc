// Owner: 12.4 lookup-props (contract frozen by plan 12 stage 0).
// Port of src/aro/Builtins.zig minus createType/createBuiltin (those live in
// builtin_type_description.c3): per-group name lookup over the generated
// tables, arch -> group search order, the Builtins name -> Expanded cache.
//
// Invariants:
// - The generated tables (aro::builtin_defs::<group>, produced from the .def
//   files by //:builtin_defs, see tools/builtins_schema.md) are the only data
//   source. NAMES is sorted bytewise ascending, so a tag index is the name's
//   rank and lookup is a binary search. No DAFSA.
// - Lookup is exact and case-sensitive; an unknown name is UNKNOWN_BUILTIN
//   (Zig `null`), never a crash.
// - from_name searches COMMON first, then the arch groups in Zig order
//   (groups_for_arch). The first match wins.
// - Zig does not check `features` or `language` in getOrCreate (TODO there).
//   The C3 port keeps that behavior in get_or_create; language_allows and
//   features_of expose the data for later gating in the parser.
// - Cache keys are the static names from NAMES, so cached entries never borrow
//   caller memory.
module aro::builtins;
import aro, aro::compilation, aro::target, aro::type_store, aro::lang_opts;
import aro::builtin_properties, aro::builtin_type_description, aro::string_interner;
import std::collections::list;
import aro::builtin_defs::aarch64, aro::builtin_defs::aarch64_neon, aro::builtin_defs::amdgcn;
import aro::builtin_defs::arm, aro::builtin_defs::bpf, aro::builtin_defs::common;
import aro::builtin_defs::hexagon, aro::builtin_defs::loongarch, aro::builtin_defs::mips;
import aro::builtin_defs::neon, aro::builtin_defs::nvptx, aro::builtin_defs::powerpc;
import aro::builtin_defs::riscv, aro::builtin_defs::s390x, aro::builtin_defs::ve;
import aro::builtin_defs::wasm, aro::builtin_defs::x86_64, aro::builtin_defs::x86;
import aro::builtin_defs::xcore;

<* The name is not a builtin for this target (Zig `null` from fromName / getOrCreate). *>
excuse UNKNOWN_BUILTIN;

<* Builtins.Expanded. *>
struct Expanded
{
	BuiltinTag tag;
	QualType qt;
	Language language;
	Attributes attributes;
	Header header;
}

<* Builtins.FromName. features is "" when the builtin has none (Zig `null`). *>
struct FromName
{
	BuiltinTag tag;
	String param_str;
	Language language;
	Attributes attributes;
	Header header;
	String features;
}

<* Builtins: cache of created builtins, keyed by name (Zig `_name_to_type_map`). *>
struct Builtins
{
	Allocator gpa;
	<* Keys are static names from the generated NAMES tables. *>
	StringTable names;
	<* Indexed by the StringTable index of the name. *>
	List{Expanded} expanded;
}

fn void Builtins.init(&self, Allocator gpa)
{
	*self = { .gpa = gpa };
	self.names.init(gpa);
	self.expanded.init(gpa);
}

fn void Builtins.free(&self)
{
	self.names.free();
	self.expanded.free();
	*self = {};
}

<*
 Builtins.lookup: an already created builtin. Asserts (Zig `.?`) that
 get_or_create has created `name`.
*>
fn Expanded Builtins.lookup(&self, String name)
{
	uint? idx = self.names.find(name);
	if (catch idx) unreachable("builtin '%s' was not created by get_or_create", name);
	return self.expanded[idx];
}

<* The cached entry for `name`, or UNKNOWN_BUILTIN when it has not been created yet. *>
fn Expanded? Builtins.find(&self, String name)
{
	uint? idx = self.names.find(name);
	if (catch idx) return UNKNOWN_BUILTIN~;
	return self.expanded[idx];
}

<* Builtins.getOrCreate: UNKNOWN_BUILTIN when `name` is not a builtin for comp.target. *>
fn Expanded? Builtins.get_or_create(&self, Compilation* comp, String name)
{
	if (try cached = self.find(name)) return cached;
	FromName builtin = from_name(comp, name)!;
	// Zig: `if (builtin.features) |_| { // TODO check features }`. Not gated here either.
	return self.create_from(comp, name_from_tag(builtin.tag), builtin);
}

<*
 The insertion half of getOrCreate: builds the function type of `builtin`
 and caches it under `key`. `key` must outlive the cache (get_or_create passes
 the static generated name). Returns the existing entry if `key` is cached.
*>
fn Expanded Builtins.create_from(&self, Compilation* comp, String key, FromName builtin)
{
	if (try cached = self.find(key)) return cached;
	Expanded expanded = {
		.tag = builtin.tag,
		.qt = builtin_type_description::create_builtin(comp, builtin.param_str),
		.attributes = builtin.attributes,
		.header = builtin.header,
		.language = builtin.language,
	};
	uint idx = self.names.get_or_put(key);
	assert(idx == self.expanded.len());
	self.expanded.push(expanded);
	return expanded;
}

<* Number of cached builtins. *>
fn sz Builtins.len(&self) => self.expanded.len();

<* Builtins.fromName: COMMON, then the groups of comp.target.cpu.arch. *>
fn FromName? from_name(Compilation* comp, String name)
{
	return from_name_for_arch(comp.target.cpu.arch, name);
}

<* from_name without a Compilation: COMMON, then groups_for_arch(arch); first match wins. *>
fn FromName? from_name_for_arch(Arch arch, String name)
{
	if (try found = from_name_in_group(COMMON, name)) return found;
	foreach (group : groups_for_arch(arch))
	{
		if (try found = from_name_in_group(group, name)) return found;
	}
	return UNKNOWN_BUILTIN~;
}

<* Builtins.fromNameExtra for one group. *>
fn FromName? from_name_in_group(BuiltinGroup group, String name)
{
	BuiltinTag tag = tag_from_name(group, name)!;
	return from_record(tag, record_from_tag(tag));
}

<* Builds the FromName of a tag and its record (the body of Zig fromNameExtra). *>
fn FromName from_record(BuiltinTag tag, BuiltinRecord rec)
{
	return {
		.tag = tag,
		.param_str = rec.param_str,
		.language = rec.language,
		.attributes = rec.attributes,
		.header = rec.header,
		.features = rec.features,
	};
}

<* The per-group tag of `name` (Zig `tagFromName`). *>
fn BuiltinTag? tag_from_name(BuiltinGroup group, String name)
{
	ushort index = search_names(group_names(group), group_shortest_name(group), group_longest_name(group), name)!;
	return { .index = index, .group = group };
}

<*
 Binary search of `name` in a bytewise-ascending name table (the generated
 NAMES layout). Lengths outside [shortest, longest] fail fast, as the Zig
 DAFSA lookup does. UNKNOWN_BUILTIN on a miss.
 @require names.len <= 0x10000 : "tag indices are 16 bits"
*>
fn ushort? search_names(String[] names, usz shortest, usz longest, String name)
{
	if (!names.len) return UNKNOWN_BUILTIN~;
	if (name.len < shortest || name.len > longest) return UNKNOWN_BUILTIN~;
	sz lo = 0;
	sz hi = names.len;
	while (lo < hi)
	{
		sz mid = lo + (hi - lo) / 2;
		int c = compare_bytes(names[mid], name);
		if (c == 0) return (ushort)mid;
		if (c < 0)
		{
			lo = mid + 1;
		}
		else
		{
			hi = mid;
		}
	}
	return UNKNOWN_BUILTIN~;
}

<* Bytewise (unsigned) comparison, like Zig std.mem.order(u8). *>
fn int compare_bytes(String a, String b)
{
	sz n = a.len < b.len ? a.len : b.len;
	for (sz i = 0; i < n; i++)
	{
		char x = a[i];
		char y = b[i];
		if (x != y) return x < y ? -1 : 1;
	}
	if (a.len == b.len) return 0;
	return a.len < b.len ? -1 : 1;
}

<* The canonical (static) name of a tag (Zig `nameFromTag`). @require tag.index < group_names(tag.group).len *>
fn String name_from_tag(BuiltinTag tag)
{
	return group_names(tag.group)[tag.index];
}

<* The record of a tag (Zig `fromTag`). @require tag.index < group_records(tag.group).len *>
fn BuiltinRecord record_from_tag(BuiltinTag tag)
{
	return group_records(tag.group)[tag.index];
}

<* The raw feature expression of a tag ("" when it has none). *>
fn String features_of(BuiltinTag tag) => record_from_tag(tag).features;

const BuiltinGroup[] GROUPS_NONE = {};
const BuiltinGroup[] GROUPS_AARCH64 = { AARCH64, AARCH64_NEON, NEON };
const BuiltinGroup[] GROUPS_AMDGCN = { AMDGCN };
const BuiltinGroup[] GROUPS_ARM = { ARM, NEON };
const BuiltinGroup[] GROUPS_BPF = { BPF };
const BuiltinGroup[] GROUPS_HEXAGON = { HEXAGON };
const BuiltinGroup[] GROUPS_LOONGARCH = { LOONGARCH };
const BuiltinGroup[] GROUPS_MIPS = { MIPS };
const BuiltinGroup[] GROUPS_NVPTX = { NVPTX };
const BuiltinGroup[] GROUPS_POWERPC = { POWERPC };
const BuiltinGroup[] GROUPS_RISCV = { RISCV };
const BuiltinGroup[] GROUPS_S390X = { S390X };
const BuiltinGroup[] GROUPS_VE = { VE };
const BuiltinGroup[] GROUPS_WASM = { WASM };
const BuiltinGroup[] GROUPS_XCORE = { XCORE };
const BuiltinGroup[] GROUPS_X86_64 = { X86_64, X86 };
const BuiltinGroup[] GROUPS_X86 = { X86 };

<*
 Groups searched after COMMON for `arch`, in Zig fromName order (e.g.
 AARCH64 -> {AARCH64, AARCH64_NEON, NEON}; X86_64 -> {X86_64, X86}).
 Returns a static slice; empty for arches without target builtins.
*>
fn BuiltinGroup[] groups_for_arch(Arch arch)
{
	switch (arch)
	{
		case AARCH64:
		case AARCH64_BE: return GROUPS_AARCH64;
		case AMDGCN: return GROUPS_AMDGCN;
		case ARM:
		case ARMEB:
		case THUMB:
		case THUMBEB: return GROUPS_ARM;
		case BPFEB:
		case BPFEL: return GROUPS_BPF;
		case HEXAGON: return GROUPS_HEXAGON;
		case LOONGARCH32:
		case LOONGARCH64: return GROUPS_LOONGARCH;
		case MIPS64:
		case MIPS64EL:
		case MIPS:
		case MIPSEL: return GROUPS_MIPS;
		case NVPTX:
		case NVPTX64: return GROUPS_NVPTX;
		case POWERPC64:
		case POWERPC64LE:
		case POWERPC:
		case POWERPCLE: return GROUPS_POWERPC;
		case RISCV32:
		case RISCV32BE:
		case RISCV64:
		case RISCV64BE: return GROUPS_RISCV;
		case S390X: return GROUPS_S390X;
		case VE: return GROUPS_VE;
		case WASM32:
		case WASM64: return GROUPS_WASM;
		case XCORE: return GROUPS_XCORE;
		case X86_64: return GROUPS_X86_64;
		case X86: return GROUPS_X86;
		default: return GROUPS_NONE;
	}
}

<*
 Whether `language` permits the builtin under `opts` (not applied by
 get_or_create; see module comment). Zig never evaluates Language, so the
 rule is source-derived from clang's builtinIsSupported, which the .def
 values come from: MS builtins need -fms-extensions, GNU builtins need a GNU
 standard (gnu*, or the default mode, which Aro treats as GNU), C23 builtins
 need C23 or later.
*>
fn bool language_allows(Language language, LangOpts* opts)
{
	switch (language)
	{
		case ALL_LANGUAGES: return true;
		case ALL_MS_LANGUAGES: return opts.ms_extensions;
		case ALL_GNU_LANGUAGES:
		case GNU_LANG: return opts.standard.is_gnu();
		case C23_LANG: return opts.standard.at_least(C23);
	}
}

// ---------------------------------------------------------------------------
// Generated table access (layout wiring, fixed by the stage-0 contract).
// ---------------------------------------------------------------------------

<* The sorted name table of a group; index == BuiltinTag.index. *>
fn String[] group_names(BuiltinGroup group)
{
	switch (group)
	{
		case AARCH64: return aarch64::NAMES;
		case AARCH64_NEON: return aarch64_neon::NAMES;
		case AMDGCN: return amdgcn::NAMES;
		case ARM: return arm::NAMES;
		case BPF: return bpf::NAMES;
		case COMMON: return common::NAMES;
		case HEXAGON: return hexagon::NAMES;
		case LOONGARCH: return loongarch::NAMES;
		case MIPS: return mips::NAMES;
		case NEON: return neon::NAMES;
		case NVPTX: return nvptx::NAMES;
		case POWERPC: return powerpc::NAMES;
		case RISCV: return riscv::NAMES;
		case S390X: return s390x::NAMES;
		case VE: return ve::NAMES;
		case WASM: return wasm::NAMES;
		case X86_64: return x86_64::NAMES;
		case X86: return x86::NAMES;
		case XCORE: return xcore::NAMES;
	}
}

<* The record table of a group, parallel to group_names. *>
fn BuiltinRecord[] group_records(BuiltinGroup group)
{
	switch (group)
	{
		case AARCH64: return aarch64::RECORDS;
		case AARCH64_NEON: return aarch64_neon::RECORDS;
		case AMDGCN: return amdgcn::RECORDS;
		case ARM: return arm::RECORDS;
		case BPF: return bpf::RECORDS;
		case COMMON: return common::RECORDS;
		case HEXAGON: return hexagon::RECORDS;
		case LOONGARCH: return loongarch::RECORDS;
		case MIPS: return mips::RECORDS;
		case NEON: return neon::RECORDS;
		case NVPTX: return nvptx::RECORDS;
		case POWERPC: return powerpc::RECORDS;
		case RISCV: return riscv::RECORDS;
		case S390X: return s390x::RECORDS;
		case VE: return ve::RECORDS;
		case WASM: return wasm::RECORDS;
		case X86_64: return x86_64::RECORDS;
		case X86: return x86::RECORDS;
		case XCORE: return xcore::RECORDS;
	}
}

<* Length bounds of a group's names (Zig shortest_name / longest_name; both 0 for an empty table). *>
fn usz group_shortest_name(BuiltinGroup group)
{
	switch (group)
	{
		case AARCH64: return aarch64::SHORTEST_NAME;
		case AARCH64_NEON: return aarch64_neon::SHORTEST_NAME;
		case AMDGCN: return amdgcn::SHORTEST_NAME;
		case ARM: return arm::SHORTEST_NAME;
		case BPF: return bpf::SHORTEST_NAME;
		case COMMON: return common::SHORTEST_NAME;
		case HEXAGON: return hexagon::SHORTEST_NAME;
		case LOONGARCH: return loongarch::SHORTEST_NAME;
		case MIPS: return mips::SHORTEST_NAME;
		case NEON: return neon::SHORTEST_NAME;
		case NVPTX: return nvptx::SHORTEST_NAME;
		case POWERPC: return powerpc::SHORTEST_NAME;
		case RISCV: return riscv::SHORTEST_NAME;
		case S390X: return s390x::SHORTEST_NAME;
		case VE: return ve::SHORTEST_NAME;
		case WASM: return wasm::SHORTEST_NAME;
		case X86_64: return x86_64::SHORTEST_NAME;
		case X86: return x86::SHORTEST_NAME;
		case XCORE: return xcore::SHORTEST_NAME;
	}
}

fn usz group_longest_name(BuiltinGroup group)
{
	switch (group)
	{
		case AARCH64: return aarch64::LONGEST_NAME;
		case AARCH64_NEON: return aarch64_neon::LONGEST_NAME;
		case AMDGCN: return amdgcn::LONGEST_NAME;
		case ARM: return arm::LONGEST_NAME;
		case BPF: return bpf::LONGEST_NAME;
		case COMMON: return common::LONGEST_NAME;
		case HEXAGON: return hexagon::LONGEST_NAME;
		case LOONGARCH: return loongarch::LONGEST_NAME;
		case MIPS: return mips::LONGEST_NAME;
		case NEON: return neon::LONGEST_NAME;
		case NVPTX: return nvptx::LONGEST_NAME;
		case POWERPC: return powerpc::LONGEST_NAME;
		case RISCV: return riscv::LONGEST_NAME;
		case S390X: return s390x::LONGEST_NAME;
		case VE: return ve::LONGEST_NAME;
		case WASM: return wasm::LONGEST_NAME;
		case X86_64: return x86_64::LONGEST_NAME;
		case X86: return x86::LONGEST_NAME;
		case XCORE: return xcore::LONGEST_NAME;
	}
}
