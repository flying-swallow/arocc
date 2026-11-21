module aro::string_util;

<* Helpers for scanning characters at an explicit string offset. *>
fn bool first(String s, sz offset, char* c)
{
	if (offset >= s.len) return false;
	*c = s[offset];
	return true;
}
fn bool first_is(String s, sz offset, String cs)
{
	char c;
	if (!first(s, offset, &c)) return false;
	foreach (x : cs) if (c == x) return true;
	return false;
}
fn bool first_is_lower(String s, sz offset, char lower)
{
	char c;
	return first(s, offset, &c) && (c | 0x20) == lower;
}
fn bool first_is_digit(String s, sz offset, int base)
{
	char c;
	return first(s, offset, &c) && is_digit(c, base);
}
fn void skip_chars(String s, sz* offset, String cs)
{
	while (first_is(s, *offset, cs)) (*offset)++;
}
<* Returns a numeric digit or 255; consumes and counts underscores. *>
fn char scan_digit(String s, sz* offset, sz* underscore_count, int base)
{
	while (*offset < s.len)
	{
	 char c = s[*offset];
	 if (c >= '0' && c <= '9') { (*offset)++; return c - '0'; }
	 if (base == 16 && c >= 'a' && c <= 'f') { (*offset)++; return c - 'a' + 10; }
	 if (base == 16 && c >= 'A' && c <= 'F') { (*offset)++; return c - 'A' + 10; }
	 if (c != '_') break;
	 (*offset)++;
	 (*underscore_count)++;
	}
	return 255;
}

<* parse_float/common.zig isDigit *>
fn bool is_digit(char c, int base)
{
	if (base == 10) return c >= '0' && c <= '9';
	return digit_value(c, base) >= 0;
}


<* ASCII digit value for bases up to 36, or -1 when invalid. *>
fn int digit_value(char c, int base)
{
	int d;
	if (c >= '0' && c <= '9') { d = c - '0'; }
	else if (c >= 'a' && c <= 'z') { d = c - 'a' + 10; }
	else if (c >= 'A' && c <= 'Z') { d = c - 'A' + 10; }
	else { return -1; }
	return d < base ? d : -1;
}

fn bool starts_with_ignore_case(String s, String prefix)
{
	if (s.len < prefix.len) return false;
	for (sz i = 0; i < prefix.len; i++)
	{
		char a = s[i];
		char b = prefix[i];
		if (a >= 'A' && a <= 'Z') a += 32;
		if (b >= 'A' && b <= 'Z') b += 32;
		if (a != b) return false;
	}
	return true;
}

fn bool string_ieq(String a, String b)
{
	if (a.len != b.len) return false;
	foreach (i, c : a) if (c.to_lower() != b[i].to_lower()) return false;
	return true;
}
