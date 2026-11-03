// Port of src/aro/Toolchain/GCCVersion.zig.
// STAGE 0 CONTRACT: types and signatures are fixed; bodies are stubs (agent 23.1).
module aro::toolchain::gcc_version;

<* std.math.Order. *>
enum Order : char
{
	LT,
	EQ,
	GT,
}

<*
 A parsed GCC version directory name. Strings borrow from the parsed text.
 -1 in major/minor/patch means "not present".
*>
struct GccVersion
{
	<* Raw version number text (Zig's parse never sets it; kept for parity). *>
	String raw;
	int major;
	int minor;
	int patch;
	<* Text of parsed major version number *>
	String major_str;
	<* Text of parsed minor version number *>
	String minor_str;
	<* Patch number suffix *>
	String suffix;
}

<* Zig `GCCVersion{}` defaults: every number -1, every string "". *>
const GccVersion DEFAULT = { .major = -1, .minor = -1, .patch = -1 };

<*
 Preferred-usage ordering: higher numbers are preferred, but a missing
 minor/patch/suffix is preferred to a present one.
*>
fn bool GccVersion.is_less_than(&self, int rhs_major, int rhs_minor, int rhs_patch, String rhs_suffix)
{
	return false; // STUB
}

<* GCCVersion.parse. Strings in the result borrow from `text`. *>
fn GccVersion parse(String text)
{
	return DEFAULT; // STUB
}

fn Order GccVersion.order(&self, GccVersion b)
{
	return EQ; // STUB
}

<* toUnsigned: __GNUC__-style value, wrapping like clang. *>
fn uint GccVersion.to_unsigned(&self)
{
	return 0; // STUB
}
