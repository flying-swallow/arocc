// Port of src/aro/Toolchain/GCCDetector.zig: finding the GCC installation
// (prefixes, triple aliases, lib/gcc{,-cross}/<triple>/<version> scanning,
// biarch multilib selection) for env.target, through env.fs only.
// STAGE 0 CONTRACT: types and signatures are fixed; bodies are stubs (agent 23.2).
module aro::toolchain::gcc_detector;
import aro::toolchain::discovery, aro::toolchain::gcc_version, aro::toolchain::multilib;
import aro::target;
import std::collections::list;

<* Capacity of every candidate list (Zig uses [16]/[20] stack buffers). *>
const usz MAX_CANDIDATES = 20;

<* A fixed-capacity list of borrowed strings (Zig ArrayList.initBuffer). *>
struct CandidateList
{
	String[MAX_CANDIDATES] items;
	usz len;
}

<* @require self.len < MAX_CANDIDATES *>
fn void CandidateList.push(&self, String s)
{
	self.items[self.len++] = s;
}

fn String[] CandidateList.slice(&self) => self.items[:self.len];

<* The four lists collectLibDirsAndTriples fills. Strings are static. *>
struct Candidates
{
	CandidateList lib_dirs;
	CandidateList triple_aliases;
	CandidateList biarch_lib_dirs;
	CandidateList biarch_triple_aliases;
}

<*
 GCCDetector. Every string it stores (install_path, parent_lib_path,
 gcc_triple, the version text `version` borrows from, and the "/usr"+sysroot
 prefix) is allocated with `a` and released by `free`. Multilib suffixes and
 flags are static strings.
*>
struct GccDetector
{
	Allocator a;
	bool is_valid;
	String install_path;
	String parent_lib_path;
	GccVersion version;
	String gcc_triple;
	Multilib selected;
	<* Zig `?Multilib biarch_sibling` *>
	bool has_biarch_sibling;
	Multilib biarch_sibling;
	<* Allocations owned by the detector. *>
	List{String} owned;
}

fn void GccDetector.init(&self, Allocator a)
{
	*self = { .a = a, .version = gcc_version::DEFAULT };
	self.owned.init(a);
}

fn void GccDetector.free(&self)
{
	foreach (s : self.owned) alloc::free(self.a, s.ptr);
	self.owned.free();
	*self = {};
}

<*
 appendToolPath: when valid, appends join(parent_lib_path, "..", gcc_triple,
 "bin") (allocated with `a`, owned by the caller) to `program_paths`.
*>
fn void GccDetector.append_tool_path(&self, Allocator a, List{String}* program_paths)
{
	// STUB
}

<* addDefaultGCCPrefixes (the /opt/rh list, then "/usr" or "/usr" ++ sysroot). *>
fn void GccDetector.add_default_gcc_prefixes(&self, Env* env, CandidateList* prefixes)
{
	// STUB
}

<* collectLibDirsAndTriples for env.target. *>
fn void collect_lib_dirs_and_triples(Env* env, Candidates* out)
{
	// STUB
}

<* gccToolchainDir: "" when a sysroot is set, else env.gcc_install_prefix. *>
fn String gcc_toolchain_dir(Env* env)
{
	return ""; // STUB
}

<*
 GCCDetector.discover. Fails only with multilib::TOO_MANY_MULTILIBS
 (out-of-memory panics, see CONVENTIONS.md).
*>
fn void? GccDetector.discover(&self, Env* env)
{
	return aro::UNSUPPORTED~; // STUB
}

<* scanLibDirForGCCTriple. *>
fn void? GccDetector.scan_lib_dir_for_gcc_triple(&self, Env* env, String lib_dir, String candidate_triple, bool needs_biarch_suffix, bool gcc_dir_exists, bool gcc_cross_dir_exists)
{
	return aro::UNSUPPORTED~; // STUB
}

<* scanGCCForMultilibs; path = { dir_name, version_text }. *>
fn bool? GccDetector.scan_gcc_for_multilibs(&self, Env* env, String[2] path, bool needs_biarch_suffix)
{
	return aro::UNSUPPORTED~; // STUB
}

<* findBiarchMultilibs. *>
fn bool? find_biarch_multilibs(Env* env, Detected* result, String[2] path, bool needs_biarch_suffix)
{
	return aro::UNSUPPORTED~; // STUB
}
