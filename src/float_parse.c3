// std.fmt.parseFloat(f128, s): port of Zig 0.17.0 lib/std/fmt/parse_float.zig and
// parse_float/{FloatStream,common,parse,convert_hex,convert_fast,convert_slow,
// decimal}.zig, specialised to f128 (u128 mantissa). Pure bit-level code: the
// only entry point is `parse_f128`; Parser.parseFloat is parse_f128 followed by
// PrimitiveValue.cast to the literal's width (number_value.c3).
// Uses f128_mul / f128_div (float_soft_wide.c3) for the fast path.
module aro::primitive_value;

<* Zig error.InvalidCharacter from std.fmt.parseFloat. *>
excuse INVALID_CHARACTER;

<* parse_float/FloatStream.zig *>
struct FloatStream
{
	String slice;
	sz offset;
	sz underscore_count;
}

fn sz FloatStream.offset_true(&self) => self.offset - self.underscore_count;

fn void FloatStream.reset(&self)
{
	self.offset = 0;
	self.underscore_count = 0;
}

fn bool FloatStream.has_len(&self, sz n) => self.offset + n <= self.slice.len;

fn bool FloatStream.first(&self, char* c)
{
	if (!self.has_len(1)) return false;
	*c = self.slice[self.offset];
	return true;
}

fn bool FloatStream.first_is(&self, String cs)
{
	char c;
	if (!self.first(&c)) return false;
	foreach (x : cs)
	{
		if (c == x) return true;
	}
	return false;
}

fn bool FloatStream.first_is_lower(&self, char lower)
{
	char c;
	if (!self.first(&c)) return false;
	return (c | 0x20) == lower;
}

fn bool FloatStream.first_is_digit(&self, int base)
{
	char c;
	if (!self.first(&c)) return false;
	return is_float_digit(c, base);
}

fn void FloatStream.advance(&self, sz n) => self.offset += n;

fn void FloatStream.skip_chars(&self, String cs)
{
	while (self.first_is(cs)) self.advance(1);
}

<* FloatStream.scanDigit: skips (and counts) '_' before a digit. *>
fn bool FloatStream.scan_digit(&self, int base, char* digit)
{
	while (true)
	{
		char c;
		if (!self.first(&c)) return false;
		if (c >= '0' && c <= '9')
		{
			self.advance(1);
			*digit = c - '0';
			return true;
		}
		if (base == 16 && c >= 'a' && c <= 'f')
		{
			self.advance(1);
			*digit = c - 'a' + 10;
			return true;
		}
		if (base == 16 && c >= 'A' && c <= 'F')
		{
			self.advance(1);
			*digit = c - 'A' + 10;
			return true;
		}
		if (c == '_')
		{
			self.advance(1);
			self.underscore_count++;
			continue;
		}
		return false;
	}
}

<* parse_float/common.zig isDigit *>
fn bool is_float_digit(char c, int base)
{
	if (base == 10) return c >= '0' && c <= '9';
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

<* parse_float/common.zig Number(f128) *>
struct ParsedNumber
{
	long exponent;
	uint128 mantissa;
	bool negative;
	<* More than max_mantissa digits were found during parse *>
	bool many_digits;
	<* The number was a hex-float (e.g. 0x1.234p567) *>
	bool hex;
}

<* parse.zig tryParseDigits (the 8-digit fast path is the same arithmetic mod 2^128). *>
fn void try_parse_digits(FloatStream* stream, uint128* x, int base)
{
	char digit;
	while (stream.scan_digit(base, &digit)) * x = *x * (uint128)base + (uint128)digit;
}

<* parse.zig min_n_digit_int: 10^(n-1). *>
fn uint128 min_n_digit_int(sz digit_count)
{
	uint128 n = 1;
	for (sz i = 1; i < digit_count; i++) n *= 10;
	return n;
}

<* parse.zig tryParseNDigits (base 16 also stops at 10^(n-1), as in Zig). *>
fn void try_parse_n_digits(FloatStream* stream, uint128* x, int base, sz n)
{
	uint128 limit = min_n_digit_int(n);
	char digit;
	while (*x < limit)
	{
		if (!stream.scan_digit(base, &digit)) break;
		*x = *x * (uint128)base + (uint128)digit;
	}
}

<* parse.zig parseScientific: false is Zig `null`. *>
fn bool parse_scientific(FloatStream* stream, long* out)
{
	long exponent = 0;
	bool negative = false;
	char c;
	if (stream.first(&c))
	{
		negative = c == '-';
		if (c == '-' || c == '+') stream.advance(1);
	}
	if (stream.first_is_digit(10))
	{
		char digit;
		while (stream.scan_digit(10, &digit))
		{
			// no overflows here, saturate well before overflow
			if (exponent < 0x1000_0000) exponent = 10 * exponent + digit;
		}
		* out = negative ? -exponent : exponent;
		return true;
	}
	return false;
}

<* parse.zig validUnderscores *>
fn bool valid_underscores(String s, int base)
{
	for (sz i = 0; i < s.len; i++)
	{
		if (s[i] == '_')
		{
			// underscore at start of end
			if (i == 0 || i + 1 == s.len) return false;
			// consecutive underscores
			if (!is_float_digit(s[i - 1], base) || !is_float_digit(s[i + 1], base)) return false;
			// next is guaranteed a digit, skip an extra
			i++;
		}
	}
	return true;
}

<* parse.zig parsePartialNumberBase for f128 (u128 mantissa). false is Zig `null`. *>
fn bool parse_partial_number_base(FloatStream* stream, bool negative, sz* n, int base, sz max_mantissa_digits, char exp_char_lower, ParsedNumber* out)
{
	// parse initial digits before dot
	uint128 mantissa = 0;
	try_parse_digits(stream, &mantissa, base);
	sz int_end = stream.offset_true();
	sz n_digits = stream.offset_true();

	// handle dot with the following digits
	long exponent = 0;
	if (stream.first_is("."))
	{
		stream.advance(1);
		sz marker = stream.offset_true();
		try_parse_digits(stream, &mantissa, base);
		sz n_after_dot = stream.offset_true() - marker;
		exponent = -(long)n_after_dot;
		n_digits += n_after_dot;
	}

	// adjust required shift to offset mantissa for base-16 (2^4)
	if (base == 16) exponent *= 4;

	if (n_digits == 0) return false;

	// handle scientific format
	long exp_number = 0;
	if (stream.first_is_lower(exp_char_lower))
	{
		stream.advance(1);
		if (!parse_scientific(stream, &exp_number)) return false;
		exponent += exp_number;
	}

	* n += stream.offset;  // length must be complete parsed length

	if (stream.underscore_count > 0 && !valid_underscores(stream.slice, base)) return false;

	// common case with not many digits
	if (n_digits <= max_mantissa_digits)
	{
		*out = { .exponent = exponent, .mantissa = mantissa, .negative = negative, .many_digits = false, .hex = base == 16 };
		return true;
	}

	n_digits -= max_mantissa_digits;
	bool many_digits = false;
	stream.reset();  // re-parse from beginning
	while (stream.first_is("0._"))
	{
		// '0' = '.' + 2
		char next = stream.slice[stream.offset];
		if (next != '_')
		{
			n_digits -= next > '/' ? (sz)(next - '/') : 0;  // next -| ('0' - 1)
		}
		else
		{
			stream.underscore_count++;
		}
		stream.advance(1);
	}
	if (n_digits > 0)
	{
		// at this point we have more than max_mantissa_digits significant digits, let's try again
		many_digits = true;
		mantissa = 0;
		stream.reset();
		try_parse_n_digits(stream, &mantissa, base, max_mantissa_digits);

		if (mantissa >= min_n_digit_int(max_mantissa_digits))
		{
			// big int
			exponent = (long)int_end - (long)stream.offset_true();
		}
		else
		{
			// the next byte must be present and be '.'
			stream.advance(1);
			sz marker = stream.offset_true();
			try_parse_n_digits(stream, &mantissa, base, max_mantissa_digits);
			exponent = (long)marker - (long)stream.offset_true();
		}
		if (base == 16) exponent *= 4;
		// add back the explicit part
		exponent += exp_number;
	}

	* out = { .exponent = exponent, .mantissa = mantissa, .negative = negative, .many_digits = many_digits, .hex = base == 16 };
	return true;
}

<* parse.zig parsePartialNumber *>
fn bool parse_partial_number(String s, bool negative, sz* n, ParsedNumber* out)
{
	assert(s.len != 0);
	*n = 0;
	if (s.len >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
	{
		FloatStream stream = { .slice = s[2..], .offset = 0, .underscore_count = 0 };
		*n += 2;
		return parse_partial_number_base(&stream, negative, n, 16, 32, 'p', out);
	}
	FloatStream stream = { .slice = s, .offset = 0, .underscore_count = 0 };
	return parse_partial_number_base(&stream, negative, n, 10, 38, 'e', out);
}

<* parse.zig parseNumber: the whole input must be consumed. *>
fn bool parse_number(String s, bool negative, ParsedNumber* out)
{
	sz consumed = 0;
	if (parse_partial_number(s, negative, &consumed, out)) return s.len == consumed;
	return false;
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

<* parse.zig parseInfOrNan: "inf"/"infinity" (signed), "nan" (always std.math.nan, positive). *>
fn bool parse_inf_or_nan(String s, bool negative, F128Bits* out)
{
	sz consumed;
	PrimitiveValue value;
	if (starts_with_ignore_case(s, "inf"))
	{
		consumed = 3;
		if (starts_with_ignore_case(s[3..], "inity")) consumed = 8;
		value = inf(F128, negative);
	}
	else if (starts_with_ignore_case(s, "nan"))
	{
		consumed = 3;
		value = std_nan(F128);
	}
	else
	{
		return false;
	}
	if (s.len != consumed) return false;
	*out = value.f128();
	return true;
}

<* convert_hex.zig convertHex for f128 (round to nearest even on two guard bits). *>
fn F128Bits convert_hex(ParsedNumber n)
{
	if (n.mantissa == 0) return zero(F128, n.negative).f128();

	const long MAX_EXP = 16383;
	const long MIN_EXP = -16382;
	const long EXP_BIAS = MIN_EXP - 1;
	uint128 m = n.mantissa;
	long e = n.exponent;

	// mantissa now implicitly divided by 2^fractional_bits
	e += 112;

	// Shift mantissa and exponent to bring representation into float range.
	while (m != 0 && m >> 114 == 0)
	{
		m <<= 1;
		e -= 1;
	}
	if (n.many_digits) m |= 1;
	while (m >> 115 != 0)
	{
		m = (m >> 1) | (m & 1);
		e += 1;
	}

	// If exponent is too negative, denormalize in hopes of making it representable.
	while (m > 1 && e < MIN_EXP - 2)
	{
		m = (m >> 1) | (m & 1);
		e += 1;
	}

	// Round using two bottom bits.
	uint128 round = m & 3;
	m >>= 2;
	round |= m & 1;  // round to even (round up if mantissa is odd)
	e += 2;
	if (round == 3)
	{
		m += 1;
		if (m == (uint128)1 << 113)
		{
			m >>= 1;
			e += 1;
		}
	}

	// Denormal or zero
	if (m >> 112 == 0) e = EXP_BIAS;

	// Infinity and range error
	if (e > MAX_EXP) return inf(F128, n.negative).f128();

	uint128 bits = m & (((uint128)1 << 112) - 1);
	bits |= (uint128)((e - EXP_BIAS) & 0x7FFF) << 112;
	if (n.negative) bits |= (uint128)1 << 127;
	return float_key(F128, bits).f128();
}

<* 10^i as an exact f128 (i <= 48: 5^i < 2^113). *>
fn F128Bits f128_pow10(long i)
{
	uint128 p5 = 1;
	for (long k = 0; k < i; k++) p5 *= 5;
	return round_pack(F128, false, (int)i, p5, false).f128();
}

<*
 convert_fast.zig convertFast for f128: exact mantissa and power of ten, one
 f128 multiplication or division (compiler-rt, through f128_mul / f128_div).
 false is Zig `null`.
*>
fn bool convert_fast(ParsedNumber n, F128Bits* out)
{
	const long MIN_EXPONENT_FAST_PATH = -48;
	const long MAX_EXPONENT_FAST_PATH = 48;
	const long MAX_EXPONENT_FAST_PATH_DISGUISED = 82;
	const uint128 MAX_MANTISSA_FAST_PATH = (uint128)2 << 112;

	if (!(MIN_EXPONENT_FAST_PATH <= n.exponent && n.exponent <= MAX_EXPONENT_FAST_PATH_DISGUISED
			&& n.mantissa <= MAX_MANTISSA_FAST_PATH && !n.many_digits)) return false;

	F128Bits value;
	if (n.exponent <= MAX_EXPONENT_FAST_PATH)
	{
		// normal fast path
		value = round_pack(F128, false, 0, n.mantissa, false).f128();
		if (n.exponent < 0)
		{
			value = f128_div(value, f128_pow10(-n.exponent));
		}
		else
		{
			value = f128_mul(value, f128_pow10(n.exponent));
		}
	}
	else
	{
		// disguised fast path
		long shift = n.exponent - MAX_EXPONENT_FAST_PATH;
		uint128 pow = 1;
		for (long k = 0; k < shift; k++) pow *= 10;
		// math.mul(u128, ...) catch return null
		if (n.mantissa != 0 && pow > ~(uint128)0 / n.mantissa) return false;
		uint128 mantissa = n.mantissa * pow;
		if (mantissa > MAX_MANTISSA_FAST_PATH) return false;
		value = f128_mul(round_pack(F128, false, 0, mantissa, false).f128(), f128_pow10(MAX_EXPONENT_FAST_PATH));
	}
	if (n.negative) value.hi ^= F128_SIGN_BIT;
	*out = value;
	return true;
}

<* decimal.zig Decimal(f128) constants. *>
const sz DECIMAL_MAX_DIGITS = 11564;
const sz DECIMAL_MAX_DIGITS_WITHOUT_OVERFLOW = 38;
const int DECIMAL_POINT_RANGE = 32767;
const int DECIMAL_MIN_EXPONENT = -4966;
const int DECIMAL_MAX_EXPONENT = 4934;
const int DECIMAL_MAX_DECIMAL_DIGITS = 37;

<* decimal.zig Decimal(f128): the "Simple Decimal Conversion" big decimal. *>
struct Decimal
{
	<* The number of significant digits in the decimal. *>
	sz num_digits;
	<* The offset of the decimal point in the significant digits. *>
	int decimal_point;
	<* If the number of significant digits stored in the decimal is truncated. *>
	bool truncated;
	<* buffer of the raw digits, in the range [0, 9]. *>
	char[DECIMAL_MAX_DIGITS] digits;
}

fn void Decimal.try_add_digit(&self, char digit)
{
	if (self.num_digits < DECIMAL_MAX_DIGITS) self.digits[self.num_digits] = digit;
	self.num_digits++;
}

fn void Decimal.trim(&self)
{
	assert(self.num_digits <= DECIMAL_MAX_DIGITS);
	while (self.num_digits != 0 && self.digits[self.num_digits - 1] == 0) self.num_digits--;
}

fn uint128 Decimal.round(&self)
{
	if (self.num_digits == 0 || self.decimal_point < 0) return 0;
	if (self.decimal_point > DECIMAL_MAX_DECIMAL_DIGITS) return ~(uint128)0;
	sz dp = (sz)self.decimal_point;
	uint128 n = 0;
	for (sz i = 0; i < dp; i++)
	{
		n *= 10;
		if (i < self.num_digits) n += (uint128)self.digits[i];
	}
	bool round_up = false;
	if (dp < self.num_digits)
	{
		round_up = self.digits[dp] >= 5;
		if (self.digits[dp] == 5 && dp + 1 == self.num_digits)
		{
			round_up = self.truncated || (dp != 0 && (self.digits[dp - 1] & 1) != 0);
		}
	}
	if (round_up) n += 1;
	return n;
}

<* Decimal digits of base^exp, most significant first, into `out`; returns the count. *>
fn sz pow_decimal_digits(uint base, usz exp, char[] out)
{
	// little-endian work buffer
	char[128] le;
	sz len = 1;
	le[0] = 1;
	for (usz k = 0; k < exp; k++)
	{
		uint carry = 0;
		for (sz i = 0; i < len; i++)
		{
			uint v = (uint)le[i] * base + carry;
			le[i] = (char)(v % 10);
			carry = v / 10;
		}
		while (carry != 0)
		{
			le[len++] = (char)(carry % 10);
			carry /= 10;
		}
	}
	for (sz i = 0; i < len; i++) out[i] = le[len - 1 - i];
	return len;
}

<*
 Decimal.numberOfDigitsLeftShift. Zig's pow2_to_pow5_table row `shift` is
 { .delta = digits of 2^shift, .cutoff = decimal digits of 5^shift } (row 0 is
 { 0, "" }); the row is computed here instead of copied.
 @require shift < 128
*>
fn sz Decimal.number_of_digits_left_shift(&self, usz shift)
{
	if (shift == 0) return 0;
	char[128] p5;
	char[128] p2;
	sz p5_len = pow_decimal_digits(5, shift, p5[..]);
	sz delta = pow_decimal_digits(2, shift, p2[..]);
	for (sz i = 0; i < p5_len; i++)
	{
		if (i >= self.num_digits) return delta - 1;
		if (self.digits[i] == p5[i]) continue;
		if (self.digits[i] < p5[i]) return delta - 1;
		return delta;
	}
	return delta;
}

<* Decimal.leftShift: decimal * 2^shift. *>
fn void Decimal.left_shift(&self, usz shift)
{
	if (self.num_digits == 0) return;
	sz num_new_digits = self.number_of_digits_left_shift(shift);
	sz read_index = self.num_digits;
	sz write_index = self.num_digits + num_new_digits;
	uint128 n = 0;
	while (read_index != 0)
	{
		read_index--;
		write_index--;
		n += (uint128)self.digits[read_index] << shift;
		uint128 quotient = n / 10;
		uint128 remainder = n - 10 * quotient;
		if (write_index < DECIMAL_MAX_DIGITS)
		{
			self.digits[write_index] = (char)remainder;
		}
		else if (remainder > 0)
		{
			self.truncated = true;
		}
		n = quotient;
	}
	while (n > 0)
	{
		write_index--;
		uint128 quotient = n / 10;
		uint128 remainder = n - 10 * quotient;
		if (write_index < DECIMAL_MAX_DIGITS)
		{
			self.digits[write_index] = (char)remainder;
		}
		else if (remainder > 0)
		{
			self.truncated = true;
		}
		n = quotient;
	}
	self.num_digits += num_new_digits;
	if (self.num_digits > DECIMAL_MAX_DIGITS) self.num_digits = DECIMAL_MAX_DIGITS;
	self.decimal_point += (int)num_new_digits;
	self.trim();
}

<* Decimal.rightShift: decimal * 2^-shift. *>
fn void Decimal.right_shift(&self, usz shift)
{
	sz read_index = 0;
	sz write_index = 0;
	uint128 n = 0;
	while (n >> shift == 0)
	{
		if (read_index < self.num_digits)
		{
			n = 10 * n + (uint128)self.digits[read_index];
			read_index++;
		}
		else if (n == 0)
		{
			return;
		}
		else
		{
			while (n >> shift == 0)
			{
				n *= 10;
				read_index++;
			}
			break;
		}
	}

	self.decimal_point -= (int)read_index - 1;
	if (self.decimal_point < -DECIMAL_POINT_RANGE)
	{
		self.num_digits = 0;
		self.decimal_point = 0;
		self.truncated = false;
		return;
	}

	uint128 mask = ((uint128)1 << shift) - 1;
	while (read_index < self.num_digits)
	{
		char new_digit = (char)(n >> shift);
		n = 10 * (n & mask) + (uint128)self.digits[read_index];
		read_index++;
		self.digits[write_index] = new_digit;
		write_index++;
	}
	while (n > 0)
	{
		char new_digit = (char)(n >> shift);
		n = 10 * (n & mask);
		if (write_index < DECIMAL_MAX_DIGITS)
		{
			self.digits[write_index] = new_digit;
			write_index++;
		}
		else if (new_digit > 0)
		{
			self.truncated = true;
		}
	}
	self.num_digits = write_index;
	self.trim();
}

<*
 Decimal.parse (decimal input only, already validated by parse_number). Kept
 quirks: leading '0'/'_' are skipped without counting underscores, and the
 trailing-zero scan indexes the raw string with an underscore-free offset.
*>
fn void Decimal.parse(&self, String s)
{
	*self = {};
	FloatStream stream = { .slice = s, .offset = 0, .underscore_count = 0 };
	char digit;

	stream.skip_chars("0_");
	while (stream.scan_digit(10, &digit)) self.try_add_digit(digit);

	if (stream.first_is("."))
	{
		stream.advance(1);
		sz marker = stream.offset_true();
		// Skip leading zeroes
		if (self.num_digits == 0) stream.skip_chars("0");
		while (stream.scan_digit(10, &digit)) self.try_add_digit(digit);
		self.decimal_point = (int)marker - (int)stream.offset_true();
	}
	if (self.num_digits != 0)
	{
		// Ignore trailing zeros if any
		sz n_trailing_zeros = 0;
		sz i = stream.offset_true() - 1;
		while (true)
		{
			if (s[i] == '0')
			{
				n_trailing_zeros++;
			}
			else if (s[i] != '.')
			{
				break;
			}
			i--;
			if (i == 0) break;
		}
		self.decimal_point += (int)n_trailing_zeros;
		self.num_digits -= n_trailing_zeros;
		self.decimal_point += (int)self.num_digits;
		if (self.num_digits > DECIMAL_MAX_DIGITS)
		{
			self.truncated = true;
			self.num_digits = DECIMAL_MAX_DIGITS;
		}
	}
	if (stream.first_is_lower('e'))
	{
		stream.advance(1);
		bool neg_exp = false;
		if (stream.first_is("-"))
		{
			neg_exp = true;
			stream.advance(1);
		}
		else if (stream.first_is("+"))
		{
			stream.advance(1);
		}
		int exp_num = 0;
		while (stream.scan_digit(10, &digit))
		{
			if (exp_num < 0x10000) exp_num = 10 * exp_num + digit;
		}
		self.decimal_point += neg_exp ? -exp_num : exp_num;
	}

	for (sz i = self.num_digits; i < DECIMAL_MAX_DIGITS_WITHOUT_OVERFLOW; i++) self.digits[i] = 0;
}

<* common.zig BiasedFp(f128): significand bits and biased exponent. *>
struct BiasedFp
{
	uint128 f;
	int e;
}

fn F128Bits BiasedFp.to_f128(self, bool negative)
{
	uint128 word = self.f | ((uint128)(uint)self.e << 112);
	F128Bits r = float_key(F128, word).f128();
	if (negative) r.hi ^= F128_SIGN_BIT;
	return r;
}

<* convert_slow.zig getShift *>
fn usz get_slow_shift(sz n)
{
	const char[19] POWERS = { 0, 3, 6, 9, 13, 16, 19, 23, 26, 29, 33, 36, 39, 43, 46, 49, 53, 56, 59 };
	return n < 19 ? (usz)POWERS[n] : 60;
}

<* convert_slow.zig convertSlow for f128 (`s` without the sign). *>
fn BiasedFp convert_slow(String s)
{
	const int MIN_EXPONENT = -16383;
	const int INFINITE_POWER = 0x7FFF;
	const BiasedFp ZERO_FP = { 0, 0 };
	const BiasedFp INF_FP = { 0, 0x7FFF };

	Decimal d;
	d.parse(s);  // no need to recheck underscores
	if (d.num_digits == 0 || d.decimal_point < DECIMAL_MIN_EXPONENT) return ZERO_FP;
	if (d.decimal_point >= DECIMAL_MAX_EXPONENT) return INF_FP;

	int exp2 = 0;
	// Shift right toward (1/2 .. 1]
	while (d.decimal_point > 0)
	{
		usz shift = get_slow_shift((sz)d.decimal_point);
		d.right_shift(shift);
		if (d.decimal_point < -DECIMAL_POINT_RANGE) return ZERO_FP;
		exp2 += (int)shift;
	}
	// Shift left toward (1/2 .. 1]
	while (d.decimal_point <= 0)
	{
		usz shift;
		if (d.decimal_point == 0)
		{
			char first = d.digits[0];
			if (first >= 5) break;
			shift = first <= 1 ? 2 : 1;
		}
		else
		{
			shift = get_slow_shift((sz)-d.decimal_point);
		}
		d.left_shift(shift);
		if (d.decimal_point > DECIMAL_POINT_RANGE) return INF_FP;
		exp2 -= (int)shift;
	}
	// We are now in the range [1/2 .. 1] but the binary format uses [1 .. 2]
	exp2 -= 1;
	while (MIN_EXPONENT + 1 > exp2)
	{
		int n = (MIN_EXPONENT + 1) - exp2;
		if (n > 60) n = 60;
		d.right_shift((usz)n);
		exp2 += n;
	}
	if (exp2 - MIN_EXPONENT >= INFINITE_POWER) return INF_FP;

	// Shift the decimal to the hidden bit, and then round the value
	// to get the high mantissa+1 bits.
	d.left_shift(113);
	uint128 mantissa = d.round();
	if (mantissa >= (uint128)1 << 113)
	{
		// Rounding up overflowed to the carry bit, need to
		// shift back to the hidden bit.
		d.right_shift(1);
		exp2 += 1;
		mantissa = d.round();
		if (exp2 - MIN_EXPONENT >= INFINITE_POWER) return INF_FP;
	}
	int power2 = exp2 - MIN_EXPONENT;
	if (mantissa < (uint128)1 << 112) power2 -= 1;
	// Zero out all the bits above the mantissa bits.
	mantissa &= ((uint128)1 << 112) - 1;
	return { mantissa, power2 };
}

<*
 std.fmt.parseFloat(f128, s) from Zig 0.17.0 lib/std/fmt/parse_float.zig, as
 Parser.parseFloat calls it (digit separators already removed, suffix already
 stripped). Port: optional sign, parseNumber (decimal and 0x hexadecimal with
 p exponent, '_' separators allowed by Zig), parseInfOrNan, then convertHex /
 convertFast / convertSlow (Decimal with max_digits 11564; Eisel-Lemire is NOT
 used for f128). Correctly rounded to nearest even within those rules;
 "1e5000" -> +inf, "1e-5000" -> +0, "-nan" -> +NaN (std.math.nan).
 @return? INVALID_CHARACTER
*>
fn F128Bits? parse_f128(String s)
{
	if (s.len == 0) return INVALID_CHARACTER~;
	sz i = 0;
	bool negative = s[i] == '-';
	if (s[i] == '-' || s[i] == '+') i++;
	if (s.len == i) return INVALID_CHARACTER~;
	String rest = s[i..];

	ParsedNumber n;
	if (!parse_number(rest, negative, &n))
	{
		F128Bits special;
		if (parse_inf_or_nan(rest, negative, &special)) return special;
		return INVALID_CHARACTER~;
	}
	if (n.hex) return convert_hex(n);
	F128Bits fast;
	if (convert_fast(n, &fast)) return fast;
	return convert_slow(rest).to_f128(negative);
}
