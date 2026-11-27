// #kind: run
// #exit: 32
#include <limits.h>

/* Exercise signed and unsigned integer conversions, float widening and
   narrowing, round-to-nearest integer conversion, and truncation toward zero. */
int main(void)
{
	volatile int signed_input = -123456;
	volatile unsigned int unsigned_input = 4000000000u;
	volatile int precision_input = 16777217;
	volatile long long wide_input = 9007199254740993LL;
	volatile float float_input = -17.875f;
	volatile double double_input = 12345.875;
	volatile double round_input = 16777217.0;
	volatile double unsigned_double_input = 4000000000.75;
	volatile double wide_double_input = -123456789012.75;
	volatile float byte_input = 250.75f;
	volatile double minimum_int_input = -2147483648.0;
	volatile char char_input = -42;
	volatile unsigned char unsigned_char_input = 250;
	volatile short short_input = -12345;
	volatile unsigned short unsigned_short_input = 54321;
	volatile long long_input = -123456789L;
	volatile unsigned long unsigned_long_input = 4000000000UL;
	volatile double narrow_signed_input = -123.875;
	volatile double narrow_short_input = -30000.75;
	volatile double narrow_unsigned_short_input = 60000.75;
	volatile double narrow_long_input = -123456.75;
	volatile double narrow_unsigned_long_input = 4000000000.75;
	volatile double exact_double_input = 123.5;
	int score = 0;

	float signed_to_float = (float)signed_input;
	double unsigned_to_double = (double)unsigned_input;
	float unsigned_to_float = (float)unsigned_input;
	float rounded_int_to_float = (float)precision_input;
	double rounded_wide_to_double = (double)wide_input;
	double widened_float = (double)float_input;
	float narrowed_double = (float)round_input;
	int negative_float_to_int = (int)float_input;
	int positive_double_to_int = (int)double_input;
	long long double_to_long_long = (long long)wide_double_input;
	unsigned int double_to_unsigned = (unsigned int)unsigned_double_input;
	unsigned char float_to_byte = (unsigned char)byte_input;
	int negative_zero_to_int = (int)-0.0;
	int double_to_int_min = (int)minimum_int_input;
	double char_to_double = (double)char_input;
	double unsigned_char_to_double = (double)unsigned_char_input;
	double short_to_double = (double)short_input;
	double unsigned_short_to_double = (double)unsigned_short_input;
	double long_to_double = (double)long_input;
	double unsigned_long_to_double = (double)unsigned_long_input;
	char double_to_char = (char)narrow_signed_input;
	short double_to_short = (short)narrow_short_input;
	unsigned short double_to_unsigned_short = (unsigned short)narrow_unsigned_short_input;
	long double_to_long = (long)narrow_long_input;
	unsigned long double_to_unsigned_long = (unsigned long)narrow_unsigned_long_input;
	float float_round_trip = (float)(double)float_input;
	double double_round_trip = (double)(float)exact_double_input;
	_Bool bool_from_half = (_Bool)0.5;

	if (signed_to_float == -123456.0f) score++;
	if (unsigned_to_double == 4000000000.0) score++;
	if (unsigned_to_float == 4000000000.0f) score++;
	if (rounded_int_to_float == 16777216.0f) score++;
	if (rounded_wide_to_double == 9007199254740992.0) score++;
	if (widened_float == -17.875) score++;
	if (narrowed_double == 16777216.0f) score++;
	if (negative_float_to_int == -17) score++;
	if (positive_double_to_int == 12345) score++;
	if (double_to_long_long == -123456789012LL) score++;
	if (double_to_unsigned == 4000000000u) score++;
	if (float_to_byte == 250) score++;
	if (negative_zero_to_int == 0) score++;
	if (double_to_int_min == (-2147483647 - 1)) score++;
	if (char_to_double == -42.0) score++;
	if (unsigned_char_to_double == 250.0) score++;
	if (short_to_double == -12345.0) score++;
	if (unsigned_short_to_double == 54321.0) score++;
	if (long_to_double == -123456789.0) score++;
	if (unsigned_long_to_double == 4000000000.0) score++;
	if (double_to_char == -123) score++;
	if (double_to_short == -30000) score++;
	if (double_to_unsigned_short == 60000) score++;
	if (double_to_long == -123456L) score++;
	if (double_to_unsigned_long == 4000000000UL) score++;
	if (float_round_trip == -17.875f) score++;
	if (double_round_trip == 123.5) score++;
	if (bool_from_half == 1) score++;

#if ULONG_MAX > 0xffffffffUL
	volatile unsigned long high_unsigned_long = 1UL << 63;
	volatile unsigned long above_two_to_63 = (1UL << 63) + 4096UL;
	double high_unsigned_long_as_double = (double)high_unsigned_long;
	unsigned long high_unsigned_long_round_trip = (unsigned long)high_unsigned_long_as_double;
	double above_two_to_63_as_double = (double)above_two_to_63;
	unsigned long above_two_to_63_round_trip = (unsigned long)above_two_to_63_as_double;
	if (high_unsigned_long_as_double == 9223372036854775808.0) score++;
	if (high_unsigned_long_round_trip == high_unsigned_long) score++;
	if (above_two_to_63_as_double == 9223372036854779904.0) score++;
	if (above_two_to_63_round_trip == above_two_to_63) score++;
#endif

	return score;
}
