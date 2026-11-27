// Port of c3c src/compiler/float.c (Real is double).
//
// Deviations from c3c:
// - `char **error` out-parameters are `String* error` (set to the c3c
//   message text; untouched on success).
// - libc `strtod` / `frexp` / `ldexp` / `nearbyint` are called through
//   libc and std::math.
module aro::frontend::c3::compiler;
import std::core::string, std::math, libc;

extern fn double frexp(double x, CInt* exp);
extern fn double ldexp(double x, CInt exp);

fn int precision_bits(TypeKind kind)
{
	switch (kind)
	{
		case F16: return 11;
		case BF16: return 8;
		case F32: return 24;
		case F64: return 53;
		case F128: return 113;
		default: unreachable();
	}
}

fn int max_exponent(TypeKind kind)
{
	switch (kind)
	{
		case F16: return 15;
		case BF16: return 127;
		case F32: return 127;
		case F64: return 1023;
		case F128: return 16383;
		default: unreachable();
	}
}

fn int min_exponent(TypeKind kind)
{
	switch (kind)
	{
		case F16: return -14;
		case BF16: return -126;
		case F32: return -126;
		case F64: return -1022;
		case F128: return -16382;
		default: unreachable();
	}
}

fn Real float_round_to_type(Real d, TypeKind kind)
{
	if (d == 0 || math::is_nan(d) || math::is_inf(d)) return d;
	CInt exp;
	frexp(d, &exp);
	int bits = precision_bits(kind);
	int quantum = exp - bits;
	int min_quantum = min_exponent(kind) - bits + 1;
	if (quantum < min_quantum) quantum = min_quantum;
	Real rounded = ldexp(math::nearbyint(ldexp(d, -quantum)), quantum);
	if (math::abs(rounded) >= ldexp(1.0, max_exponent(kind) + 1)) return math::copysign(double::inf, d);
	return rounded;
}

fn Float float_add(Float op1, Float op2)
{
	assert(op1.type == op2.type);
	return { op1.f + op2.f, op1.type };
}

fn Float float_sub(Float op1, Float op2)
{
	assert(op1.type == op2.type);
	return { op1.f - op2.f, op1.type };
}

fn Float float_mul(Float op1, Float op2)
{
	assert(op1.type == op2.type);
	return { op1.f * op2.f, op1.type };
}

fn Float float_div(Float op1, Float op2)
{
	assert(op1.type == op2.type);
	return { op1.f / op2.f, op1.type };
}

fn Float float_rem(Float op1, Float op2)
{
	assert(op1.type == op2.type);
	return { op1.f % op2.f, op1.type };
}

fn Float float_neg(Float op)
{
	op.f = -op.f;
	return op;
}

const String ERR_INVALID_FLOAT_WIDTH = "The float width is not valid, it must be one of 16, 32, 64 and 128.";
const String ERR_FLOAT_OUT_OF_RANGE = "The float value is out of range.";
const String ERR_FLOAT_FORMAT_INVALID = "The float format is invalid.";
const String ERR_HEX_FLOAT_FORMAT_INVALID = "Hex floating points must end with 'p' or 'P' and a valid exponent, e.g. 0x1.0p10 or 0x1.0P10.";

fn TypeKind float_suffix(char c)
{
	switch (c)
	{
		case 'd':
		case 'D':
			return F64;
		case 'f':
		case 'F':
			return F32;
		default:
			return F64;
	}
}

<* Character `i` of a NUL-terminated token spelling, 0 past the end (c3c reads the terminator). *>
fn char str_at(String s, usz i) @inline => i < s.len ? s[i] : 0;

<* strtod over the scratch buffer, with c3c's range / format checks. *>
fn Float float_strtod_scratch(TypeKind kind, String* error)
{
	char* str = scratch_buffer_to_string();
	char* end = null;
	libc::errno_set((Errno)0);
	double d = libc::strtod(str, &end);
	if (d == double::inf && libc::errno() == Errno.ERANGE)
	{
		if (error) *error = ERR_FLOAT_OUT_OF_RANGE;
		return { .type = POISONED };
	}
	char* expected_end = scratch_buffer_end_ptr();
	if (d == 0 && end != expected_end)
	{
		if (error) *error = ERR_FLOAT_FORMAT_INVALID;
		return { .type = POISONED };
	}
	return { d, kind };
}

<*
 This parses a float from a string. Unfortunately it is limited to parsing
 doubles as of now. Returns the Float, with type = POISONED on error.
*>
fn Float float_from_string(String string, String* error)
{
	usz index = 0;
	char c;
	scratch_buffer_clear();
	while ((c = str_at(string, index++)) && (c == '_' || (c >= '0' && c <= '9')))
	{
		if (c == '_') continue;
		scratch_buffer_append_char(c);
	}
	if (c == '.')
	{
		scratch_buffer_append_char(c);
		while ((c = str_at(string, index++)) && (c == '_' || (c >= '0' && c <= '9')))
		{
			if (c == '_') continue;
			scratch_buffer_append_char(c);
		}
	}
	if (c == 'e' || c == 'E')
	{
		scratch_buffer_append_char(c);
		if (str_at(string, index) == '-')
		{
			scratch_buffer_append_char('-');
			index++;
		}
		else if (str_at(string, index) == '+')
		{
			index++;
		}
		while ((c = str_at(string, index++)) && (c >= '0' && c <= '9'))
		{
			scratch_buffer_append_char(c);
		}
	}
	TypeKind kind = float_suffix(c);
	if (kind == POISONED) return { .type = POISONED };
	return float_strtod_scratch(kind, error);
}

<*
 This parses a float from hex. Unfortunately it is limited to parsing
 doubles as of now. Returns the Float, with type = POISONED on error.
*>
fn Float float_from_hex(String string, String* error)
{
	usz index = 2;
	char c;
	scratch_buffer_clear();
	scratch_buffer_append("0x");
	while ((c = str_at(string, index++)) && (c == '_' || char_is_hex(c)))
	{
		if (c == '_') continue;
		scratch_buffer_append_char(c);
	}
	if (c == '.')
	{
		scratch_buffer_append_char(c);
		while ((c = str_at(string, index++)) && (c == '_' || char_is_hex(c)))
		{
			if (c == '_') continue;
			scratch_buffer_append_char(c);
		}
	}
	if (c != 'p' && c != 'P')
	{
		*error = ERR_HEX_FLOAT_FORMAT_INVALID;
		return { .type = POISONED };
	}
	scratch_buffer_append_char(c);
	if (str_at(string, index) == '-')
	{
		scratch_buffer_append_char('-');
		index++;
	}
	else if (str_at(string, index) == '+')
	{
		index++;
	}
	while ((c = str_at(string, index++)) && (c >= '0' && c <= '9'))
	{
		scratch_buffer_append_char(c);
	}
	TypeKind kind = float_suffix(c);
	if (kind == POISONED) return { .type = POISONED };
	return float_strtod_scratch(kind, error);
}
