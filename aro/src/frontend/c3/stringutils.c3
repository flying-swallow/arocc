// Port of c3c src/utils/stringutils.c (scratch buffers and the str_* helpers)
// plus the character helpers of utils/lib.h that the lexer module does not
// already export.
//
// Deviations from c3c:
// - `const char *` results are Strings; arena copies (`str_copy`, vmem.c3)
//   keep a trailing NUL like c3c's calloc_string.
// - `str_printf` / `scratch_buffer_printf` are format-checked macros
//   (`@str_printf`, `@scratch_buffer_printf`) over out-of-line `str_vprintf` /
//   `scratch_buffer_vprintf`, which take C3 variadic `args...` for `va_list`.
// - Scratch-buffer overflow aborts (c3c `error_exit`).
// - `scratch_buffer_str()` (a String view of the current contents) and
//   `scratch_buffer_reset()` (tests) are additions.
module aro::frontend::c3::compiler;
import aro::frontend::c3::lexer;
import std::core::mem::alloc;

<* c3c MAX_STRING_BUFFER. *>
const usz MAX_STRING_BUFFER = 1024 * 1024 * 4;
const int SCRATCH_BUFFERS = 8;

struct ScratchBuf
{
	char[MAX_STRING_BUFFER] str;
	int len;
}

ScratchBuf scratch_buffer_main;
ScratchBuf*[SCRATCH_BUFFERS] scratch_buffers;
int scratch_buffer_counter;
<* c3c `sb_current`. *>
ScratchBuf* sb_current;

fn ScratchBuf* sb() @inline
{
	if (!sb_current)
	{
		scratch_buffers[0] = &scratch_buffer_main;
		sb_current = &scratch_buffer_main;
	}
	return sb_current;
}

<* Reset to the first scratch buffer, empty (tests). *>
fn void scratch_buffer_reset()
{
	for (int i = 1; i < SCRATCH_BUFFERS; i++)
	{
		if (scratch_buffers[i]) alloc::free(mem, scratch_buffers[i]);
		scratch_buffers[i] = null;
	}
	scratch_buffer_counter = 0;
	scratch_buffers[0] = &scratch_buffer_main;
	sb_current = &scratch_buffer_main;
	sb_current.len = 0;
}

fn void scratch_buffer_push()
{
	sb();
	assert(scratch_buffer_counter + 1 < SCRATCH_BUFFERS, "TOO MANY BUFFERS");
	ScratchBuf* buf = scratch_buffers[++scratch_buffer_counter];
	if (!buf)
	{
		buf = scratch_buffers[scratch_buffer_counter] = alloc::malloc(mem, ScratchBuf::size);
	}
	buf.len = 0;
	sb_current = buf;
}

fn void scratch_buffer_pop()
{
	assert(scratch_buffer_counter > 0, "Unbalanced scratch buffer pop");
	sb_current = scratch_buffers[--scratch_buffer_counter];
}

fn void scratch_buffer_delete(usz len)
{
	assert((usz)sb().len >= len);
	sb_current.len -= (int)len;
}

fn void scratch_buffer_clear()
{
	sb().len = 0;
}

fn bool scratch_buffer_may_append(usz len)
{
	return len + (usz)sb().len < MAX_STRING_BUFFER - 1;
}

fn void scratch_buffer_append_len(char* string, usz len)
{
	if (!scratch_buffer_may_append(len))
	{
		@error_exit("Scratch buffer size (%d chars) exceeded", MAX_STRING_BUFFER - 1);
	}
	if (len) mem::copy(&sb_current.str[sb_current.len], string, (sz)len);
	sb_current.len += (int)len;
}

fn void scratch_buffer_append(String string)
{
	scratch_buffer_append_len(string.ptr, string.len);
}

fn void scratch_buffer_append_char(char c)
{
	if ((usz)sb().len + 1 > MAX_STRING_BUFFER - 1)
	{
		@error_exit("Scratch buffer size (%d chars) exceeded", MAX_STRING_BUFFER - 1);
	}
	sb_current.str[sb_current.len++] = c;
}

fn void scratch_buffer_append_char_repeat(char c, usz count)
{
	for (usz i = 0; i < count; i++) scratch_buffer_append_char(c);
}

fn void scratch_buffer_append_in_quote(String string)
{
	foreach (c : string)
	{
		switch (c)
		{
			case '"':
				scratch_buffer_append("\\\"");
				continue;
			case '\\':
				scratch_buffer_append("\\\\");
				continue;
		}
		scratch_buffer_append_char(c);
	}
}

fn void scratch_buffer_append_remove_space(char* start, int len)
{
	char clast = ' ';
	int printed = 0;
	for (int i = 0; i < len; i++)
	{
		char ch = start[i];
		if (ch == '\n' || ch == '\t') ch = ' ';
		if (ch == ' ' && clast == ch) continue;
		scratch_buffer_append_char(ch);
		clast = ch;
		printed++;
	}
	if (clast == ' ' && printed > 0) scratch_buffer_delete(1);
}

fn void scratch_buffer_append_signed_int(long i)
{
	@scratch_buffer_printf("%d", i);
}

fn void scratch_buffer_append_unsigned_int(ulong i)
{
	@scratch_buffer_printf("%d", i);
}

fn void scratch_buffer_append_double(double d)
{
	@scratch_buffer_printf("%f", d);
	// removing unused zeroes and dot
	while (sb_current.len > 0)
	{
		char last = sb_current.str[sb_current.len - 1];
		if (last != '0' && last != '.') return;
		sb_current.len--;
	}
}

<* c3c `scratch_buffer_printf`. *>
macro void @scratch_buffer_printf(String $fmt, ...)
{
	$assert $defined(string::tformat($fmt, ...$vaarg)) : "scratch_buffer_printf arguments do not match the format";
	scratch_buffer_vprintf($fmt, ...$vaarg);
}

fn void scratch_buffer_vprintf(String format, args...) @noinline => @pool()
{
	String s = string::tformat(format, ...args);
	scratch_buffer_append(s);
}

<* NUL terminates the buffer and returns it (valid until the next scratch write). *>
fn char* scratch_buffer_to_string()
{
	sb().str[sb_current.len] = '\0';
	return &sb_current.str;
}

<* The current contents as a String view (valid until the next scratch write). *>
fn String scratch_buffer_str()
{
	sb().str[sb_current.len] = '\0';
	return (String)sb_current.str[:sb_current.len];
}

fn char* scratch_buffer_end_ptr() => &sb().str[sb_current.len];

<* c3c `scratch_buffer_copy`: arena copy of the contents. *>
fn String scratch_buffer_copy() => str_copy((String)sb().str[:sb_current.len]);

fn void scratch_buffer_set_len(int len)
{
	sb().len = len;
}

fn int scratch_buffer_len() => sb().len;

fn char* scratch_buffer_ptr() => &sb().str;

// ---------------------------------------------------------------------------
// str_*

fn int str_findlist(String value, String[] elements)
{
	foreach (i, e : elements)
	{
		if (value == e) return (int)i;
	}
	return -1;
}

fn void str_list_add_all_unique(String[]* list, String[] items)
{
	foreach (item : items)
	{
		if (str_findlist(item, *list) == -1) @vec_add(list, item);
	}
}

fn bool str_is_valid_module_name(String name)
{
	if (!name.len) return true;
	char c = name[0];
	if (c == '_' || char_is_upper(c)) return false;
	for (usz i = 1; i < name.len; i++)
	{
		c = name[i];
		if (c == '_')
		{
			// Prevent trailing `_` and `__`
			if (name[i - 1] == ':' || i + 1 == name.len || name[i + 1] == '_' || name[i + 1] == ':') return false;
		}
		if (char_is_upper(c)) return false;
	}
	return true;
}

fn bool str_has_no_uppercase(String string)
{
	foreach (c : string)
	{
		if (char_is_upper(c)) return false;
	}
	return true;
}

fn bool str_is_valid_lowercase_name(String string)
{
	// Must start with a lower case
	if (!string.len || !char_is_lower(string[0])) return false;
	int length = 0;
	foreach (c : string)
	{
		if (!char_is_lower_alphanum_(c)) return false;
		if (++length > 127) return false;
	}
	return true;
}

<* c3c `scan_past_underscore`: index of the first non-'_', or -1 when only '_' remain. *>
fn sz scan_past_underscore(String string)
{
	usz i = 0;
	while (i < string.len && string[i] == '_') i++;
	if (i == string.len) return -1;
	return (sz)i;
}

fn bool str_is_type(String string)
{
	sz start = scan_past_underscore(string);
	if (start < 0) return false;
	if (!char_is_upper(string[start])) return false;
	bool found_lower = false;
	for (usz i = (usz)start + 1; i < string.len; i++)
	{
		char c = string[i];
		if (char_is_lower(c))
		{
			found_lower = true;
			continue;
		}
		if (!char_is_alphanum_(c)) return false;
	}
	return found_lower;
}

<* c3c `slice_is_type`. *>
fn bool slice_is_type(char* string, usz len) => str_is_type((String)string[:len]);

fn bool str_is_identifier(String string)
{
	sz start = scan_past_underscore(string);
	if (start < 0) return false;
	if (!char_is_lower(string[start])) return false;
	for (usz i = (usz)start + 1; i < string.len; i++)
	{
		if (!char_is_alphanum_(string[i])) return false;
	}
	return true;
}

<* c3c `str_eq`: identical pointers, or both non-null and equal. *>
fn bool str_eq(String str1, String str2)
{
	if (str1.ptr == str2.ptr && str1.len == str2.len) return true;
	if (!str1.ptr || !str2.ptr) return false;
	return str1 == str2;
}

fn bool str_ends_with(String str, String end)
{
	if (end.len > str.len) return false;
	return str[str.len - end.len..] == end;
}

fn bool str_is_integer(String string)
{
	usz i = 0;
	if (i < string.len && string[0] == '-') i++;
	if (i == string.len) return false;
	for (; i < string.len; i++)
	{
		if (!char_is_digit(string[i])) return false;
	}
	return true;
}

fn bool str_is_valid_constant(String string)
{
	sz start = scan_past_underscore(string);
	if (start < 0) return false;
	if (!char_is_upper(string[start])) return false;
	for (usz i = (usz)start + 1; i < string.len; i++)
	{
		if (!char_is_upper_alphanum_(string[i])) return false;
	}
	return true;
}

<* c3c `str_vprintf`: format into a new arena string. *>
fn String str_vprintf(String var_, args...) @noinline
{
	return string::format(ast_allocator(), var_, ...args);
}

<* c3c `str_printf`. *>
macro String @str_printf(String $fmt, ...)
{
	$assert $defined(string::tformat($fmt, ...$vaarg)) : "str_printf arguments do not match the format";
	return str_vprintf($fmt, ...$vaarg);
}

<* c3c `str_remove_suffix`: `name` without `suffix`, or a null String. *>
fn String str_remove_suffix(String name, String suffix)
{
	if (name.len <= suffix.len) return {};
	if (name[name.len - suffix.len..] != suffix) return {};
	return str_copy(name[:name.len - suffix.len]);
}

fn bool str_contains(String haystack, String needle) => haystack.contains(needle);

fn bool str_has_suffix(String name, String suffix)
{
	if (name.len <= suffix.len) return false;
	return name[name.len - suffix.len..] == suffix;
}

fn bool str_start_with(String name, String prefix)
{
	if (prefix.len > name.len) return false;
	return name[:prefix.len] == prefix;
}

fn String str_cat(String a, String b) => str_cat_len(a.ptr, a.len, b.ptr, b.len);

fn String str_cat_len(char* a, usz a_len, char* b, usz b_len)
{
	char* buffer = calloc_arena(a_len + b_len + 1);
	if (a_len) mem::copy(buffer, a, (sz)a_len);
	if (b_len) mem::copy(buffer + a_len, b, (sz)b_len);
	buffer[a_len + b_len] = '\0';
	return (String)buffer[:a_len + b_len];
}

fn String str_dup(String str) => str_copy(str);

// ---------------------------------------------------------------------------
// utils/lib.h character helpers (the lexer module has the rest)

fn bool char_is_lower(char c) @inline => lexer::char_is_lower(c);
fn bool char_is_upper(char c) @inline => lexer::char_is_upper(c);
fn bool char_is_digit(char c) @inline => lexer::char_is_digit(c);
fn bool char_is_letter(char c) @inline => lexer::char_is_letter(c);
fn bool char_is_letter_(char c) @inline => lexer::char_is_letter_(c);
fn bool char_is_alphanum_(char c) @inline => lexer::char_is_alphanum_(c);
fn bool char_is_hex(char c) @inline => lexer::char_is_hex(c);
fn int char_hex_to_nibble(char c) @inline => lexer::char_hex_to_nibble(c);
fn bool char_is_lower_alphanum_(char c) @inline => char_is_lower(c) || char_is_digit(c) || c == '_';
fn bool char_is_upper_alphanum_(char c) @inline => char_is_upper(c) || char_is_digit(c) || c == '_';
<* c3c `is_space`. *>
fn bool is_space(char c) @inline => c == ' ' || c == '\t';
