// Port of src/aro/Toolchain/GCCVersion.zig.
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
 minor/patch/suffix is preferred to a present one
 (e.g. `4.1` is preferred over `4.0` but `4` is preferred over both).
*>
fn bool GccVersion.is_less_than(&self, int rhs_major, int rhs_minor, int rhs_patch, String rhs_suffix)
{
	if (self.major != rhs_major) return self.major < rhs_major;
	if (self.minor != rhs_minor)
	{
		if (rhs_minor == -1) return true;
		if (self.minor == -1) return false;
		return self.minor < rhs_minor;
	}
	if (self.patch != rhs_patch)
	{
		if (rhs_patch == -1) return true;
		if (self.patch == -1) return false;
		return self.patch < rhs_patch;
	}
	if (self.suffix != rhs_suffix)
	{
		if (rhs_suffix.len == 0) return true;
		if (self.suffix.len == 0) return false;
		return bytes_less(self.suffix, rhs_suffix);
	}
	return false;
}

<* std.mem.order(u8, a, b) == .lt *>
fn bool bytes_less(String a, String b)
{
	usz n = a.len < b.len ? a.len : b.len;
	for (usz i = 0; i < n; i++)
	{
		if (a[i] != b[i]) return a[i] < b[i];
	}
	return a.len < b.len;
}

<*
 std.fmt.parseInt(i32, s, 10): optional leading '+'/'-', decimal digits and
 '_' separators between digits; false on empty text, bad characters or
 overflow.
*>
fn bool parse_i32(String s, int* out)
{
	if (s.len == 0) return false;
	usz i = 0;
	bool neg = false;
	if (s[0] == '+' || s[0] == '-')
	{
		neg = s[0] == '-';
		i = 1;
		if (s.len == 1) return false;
	}
	long v = 0;
	bool prev_underscore = true; // no leading '_'
	for (; i < s.len; i++)
	{
		char c = s[i];
		if (c == '_')
		{
			if (prev_underscore) return false;
			prev_underscore = true;
			continue;
		}
		if (c < '0' || c > '9') return false;
		prev_underscore = false;
		v = v * 10 + (long)(c - '0');
		if (v > 2147483648) return false;
	}
	if (prev_underscore) return false; // trailing '_'
	if (neg) v = -v;
	if (v > 2147483647 || v < -2147483648) return false;
	*out = (int)v;
	return true;
}

<* mem.findNone(u8, s, "0123456789") orelse s.len *>
fn sz first_non_digit(String s)
{
	foreach (i, c : s)
	{
		if (c < '0' || c > '9') return i;
	}
	return s.len;
}

<* GCCVersion.parse. Strings in the result borrow from `text`. *>
fn GccVersion parse(String text)
{
	GccVersion bad = DEFAULT;
	GccVersion good = bad;

	// mem.splitScalar(text, '.'): first, second (or ""), third (or ""); the
	// rest after a third '.' is ignored by Zig (it only reads three pieces).
	String first = text;
	String second = "";
	String rest = "";
	sz? dot1 = text.index_of_char('.');
	if (try dot1)
	{
		first = text[:dot1];
		String after = text[dot1 + 1..];
		second = after;
		sz? dot2 = after.index_of_char('.');
		if (try dot2)
		{
			second = after[:dot2];
			String after2 = after[dot2 + 1..];
			rest = after2;
			sz? dot3 = after2.index_of_char('.');
			if (try dot3) rest = after2[:dot3];
		}
	}

	if (!parse_i32(first, &good.major)) return bad;
	if (good.major < 0) return bad;
	good.major_str = first;

	if (second.len == 0) return good;
	String minor_str = second;

	if (rest.len == 0)
	{
		sz end = first_non_digit(minor_str);
		if (end > 0)
		{
			good.suffix = minor_str[end..];
			minor_str = minor_str[:end];
		}
	}
	if (!parse_i32(minor_str, &good.minor)) return bad;
	if (good.minor < 0) return bad;
	good.minor_str = minor_str;

	if (rest.len > 0)
	{
		sz end = first_non_digit(rest);
		if (end > 0)
		{
			String patch_num_text = rest[:end];
			if (!parse_i32(patch_num_text, &good.patch)) return bad;
			if (good.patch < 0) return bad;
			good.suffix = rest[end..];
		}
	}
	return good;
}

fn Order GccVersion.order(&self, GccVersion b)
{
	if (self.is_less_than(b.major, b.minor, b.patch, b.suffix)) return LT;
	if (b.is_less_than(self.major, self.minor, self.patch, self.suffix)) return GT;
	return EQ;
}

<* toUnsigned: used for __GNUC__ values; wraps like clang. *>
fn uint GccVersion.to_unsigned(&self)
{
	uint result = 0;
	if (self.major > 0) result = (uint)self.major * 10_000;
	if (self.minor > 0) result += (uint)self.minor * 100;
	if (self.patch > 0) result += (uint)self.patch;
	return result;
}
