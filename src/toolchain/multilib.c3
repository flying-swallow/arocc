// Port of src/aro/Toolchain/Multilib.zig.
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
	Multilib m = { .gcc_suffix = gcc_suffix, .os_suffix = os_suffix, .flag_count = (char)init_flags.len };
	foreach (i, f : init_flags) m.flag_buf[i] = f;
	return m;
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
	return env.joined_exists({ self.base[0], self.base[1], m.gcc_suffix, self.file });
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
	self.multilib_buf[self.multilib_count++] = m;
}

fn Multilib[] Detected.multilibs(&self)
{
	return self.multilib_buf[:self.multilib_count];
}

<* Keeps only the multilibs for which `filter.exists` holds (order preserved). *>
fn void Detected.filter(&self, Filter filter, Env* env)
{
	char found_count = 0;
	for (usz i = 0; i < self.multilib_count; i++)
	{
		Multilib m = self.multilib_buf[i];
		if (filter.exists(&m, env)) self.multilib_buf[found_count++] = m;
	}
	self.multilib_count = found_count;
}

<*
 Selects the unique multilib whose flags all agree in sign with `check_flags`
 (flags absent from check_flags match themselves). Returns false when none
 matches; TOO_MANY_MULTILIBS when several do.
*>
fn bool? Detected.select(&self, String[] check_flags)
{
	bool has_selected = false;
	Multilib selected;
	foreach (&m : self.multilibs())
	{
		bool all_match = true;
		foreach (multilib_flag : m.flags())
		{
			// The first check flag with the same name (sign ignored) wins;
			// a flag nobody asks about matches itself.
			String matched = multilib_flag;
			foreach (arg_flag : check_flags)
			{
				if (arg_flag[1..] == multilib_flag[1..])
				{
					matched = arg_flag;
					break;
				}
			}
			if (matched[0] != multilib_flag[0])
			{
				all_match = false;
				break;
			}
		}
		if (!all_match) continue;
		if (has_selected) return TOO_MANY_MULTILIBS~;
		selected = *m;
		has_selected = true;
	}
	if (has_selected)
	{
		self.selected = selected;
		return true;
	}
	return false;
}
