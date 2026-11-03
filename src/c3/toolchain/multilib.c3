// Port of src/aro/Toolchain/Multilib.zig.
// STAGE 0 CONTRACT: types and signatures are fixed; bodies are stubs (agent 23.4).
module aro::toolchain::multilib;
import aro::toolchain::discovery;

<* Detected.select found more than one matching multilib (Zig error.TooManyMultilibs). *>
excuse TOO_MANY_MULTILIBS;

<* Large enough for GCCDetector for Linux. *>
const usz MAX_MULTILIBS = 4;
const usz MAX_FLAGS = 6;

<*
 One multilib variant. Strings (suffixes and flags) borrow static or
 caller-owned memory. Flags are "+name" / "-name".
*>
struct Multilib
{
	String gcc_suffix;
	String os_suffix;
	String include_suffix;
	String[MAX_FLAGS] flag_buf;
	char flag_count;
	uint priority;
}

<*
 Multilib.init.
 @require init_flags.len <= MAX_FLAGS
*>
fn Multilib init(String gcc_suffix, String os_suffix, String[] init_flags)
{
	return {}; // STUB
}

fn String[] Multilib.flags(&self)
{
	return self.flag_buf[:self.flag_count];
}

<* Multilib.Filter: a multilib exists when base[0]/base[1]/gcc_suffix/file exists. *>
struct Filter
{
	String[2] base;
	String file;
}

fn bool Filter.exists(&self, Multilib* m, Env* env)
{
	return false; // STUB
}

<* Multilib.Detected. *>
struct Detected
{
	Multilib[MAX_MULTILIBS] multilib_buf;
	char multilib_count;
	Multilib selected;
	<* Zig `?Multilib biarch_sibling` *>
	bool has_biarch_sibling;
	Multilib biarch_sibling;
}

<*
 Appends `m`.
 @require self.multilib_count < MAX_MULTILIBS
*>
fn void Detected.push(&self, Multilib m)
{
	// STUB
}

fn Multilib[] Detected.multilibs(&self)
{
	return self.multilib_buf[:self.multilib_count];
}

<* Keeps only the multilibs for which `filter.exists` holds (order preserved). *>
fn void Detected.filter(&self, Filter filter, Env* env)
{
	// STUB
}

<*
 Selects the unique multilib whose flags all agree in sign with `check_flags`
 (flags absent from check_flags match themselves). Returns false when none
 matches; TOO_MANY_MULTILIBS when several do.
*>
fn bool? Detected.select(&self, String[] check_flags)
{
	return aro::UNSUPPORTED~; // STUB
}
