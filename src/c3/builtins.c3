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
	unreachable("stage-0 stub: builtins::Builtins.lookup");
}

<* Builtins.getOrCreate: UNKNOWN_BUILTIN when `name` is not a builtin for comp.target. *>
fn Expanded? Builtins.get_or_create(&self, Compilation* comp, String name)
{
	return aro::UNSUPPORTED~;
}

<* Builtins.fromName: COMMON, then the groups of comp.target.cpu.arch. *>
fn FromName? from_name(Compilation* comp, String name)
{
	return aro::UNSUPPORTED~;
}

<* Builtins.fromNameExtra for one group. *>
fn FromName? from_name_in_group(BuiltinGroup group, String name)
{
	return aro::UNSUPPORTED~;
}

<* The per-group tag of `name` (Zig `tagFromName`). *>
fn BuiltinTag? tag_from_name(BuiltinGroup group, String name)
{
	return aro::UNSUPPORTED~;
}

<* The canonical (static) name of a tag (Zig `nameFromTag`). @require tag.index < group_names(tag.group).len *>
fn String name_from_tag(BuiltinTag tag)
{
	unreachable("stage-0 stub: builtins::name_from_tag");
}

<* The record of a tag (Zig `fromTag`). @require tag.index < group_records(tag.group).len *>
fn BuiltinRecord record_from_tag(BuiltinTag tag)
{
	unreachable("stage-0 stub: builtins::record_from_tag");
}

<*
 Groups searched after COMMON for `arch`, in Zig fromName order (e.g.
 AARCH64 -> {AARCH64, AARCH64_NEON, NEON}; X86_64 -> {X86_64, X86}).
 Returns a static slice; empty for arches without target builtins.
*>
fn BuiltinGroup[] groups_for_arch(Arch arch)
{
	return {};
}

<* Whether `language` permits the builtin under `opts` (not applied by get_or_create; see module comment). *>
fn bool language_allows(Language language, LangOpts* opts)
{
	return true;
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
