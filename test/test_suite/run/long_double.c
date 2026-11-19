// #kind: run
// #exit: 0
long double global_value = 3.125L;
struct LongDoubleCell
{
	long double value;
};
struct LongDoubleCell value_table[] = { { 0.5L }, { 1.25L }, { 2.75L } };

int main(void)
{
	int failures = 0;

	/* The low bit of the x87 significand is observable at 1.0L. */
	volatile long double one = 1.0L;
	volatile long double one_ulp = 0x1p-63L;
	long double next = one + one_ulp;
	if (!((1.0L + 0x1p-60L) != 1.0L)) failures++;
	if (next == one) failures++;
	if (next - one != one_ulp) failures++;
	if ((double)next != 1.0) failures++;

	volatile long double a = 7.5L;
	volatile long double b = 2.0L;
	if (a + b != 9.5L) failures++;
	if (a - b != 5.5L) failures++;
	if (a * b != 15.0L) failures++;
	if (a / b != 3.75L) failures++;
	if (-a != -7.5L) failures++;
	if (!(a > b && a >= b && b < a && b <= a)) failures++;
	if (!(a != b && a == 7.5L)) failures++;

	volatile long double zero = 0.0L;
	long double nan_value = zero / zero;
	if (!(nan_value != nan_value)) failures++;
	if (nan_value == 1.0L || nan_value < 1.0L || nan_value <= 1.0L ||
		nan_value > 1.0L || nan_value >= 1.0L) failures++;

	signed char signed_char_value = -101;
	unsigned char unsigned_char_value = 201U;
	short short_value = -12345;
	unsigned short unsigned_short_value = 54321U;
	int int_value = -1234567;
	unsigned int unsigned_int_value = 2345678U;
	long long long_long_value = -123456789012345LL;
	unsigned long long unsigned_long_long_value = 0x1fffffffffffffffULL;
	long double from_signed_char = (long double)signed_char_value;
	long double from_unsigned_char = (long double)unsigned_char_value;
	long double from_short = (long double)short_value;
	long double from_unsigned_short = (long double)unsigned_short_value;
	long double from_int = (long double)int_value;
	long double from_unsigned_int = (long double)unsigned_int_value;
	long double from_long = (long double)-123456789L;
	long double from_unsigned_long = (long double)4000000000UL;
	long double from_long_long = (long double)long_long_value;
	long double from_unsigned_long_long = (long double)unsigned_long_long_value;
	long double from_double = (long double)12.5;
	long double from_float = (long double)1.25f;
	if (from_signed_char != -101.0L || from_unsigned_char != 201.0L) failures++;
	if (from_short != -12345.0L || from_unsigned_short != 54321.0L) failures++;
	if (from_int != -1234567.0L || from_unsigned_int != 2345678.0L) failures++;
	if (from_long != -123456789.0L) failures++;
	if (from_unsigned_long != 4000000000.0L) failures++;
	if (from_long_long != -123456789012345.0L) failures++;
	if (from_unsigned_long_long != 2305843009213693951.0L) failures++;
	if (from_double != 12.5L || from_float != 1.25L) failures++;
	if ((signed char)-101.75L != signed_char_value) failures++;
	if ((unsigned char)201.75L != unsigned_char_value) failures++;
	if ((short)-12345.75L != short_value) failures++;
	if ((unsigned short)54321.75L != unsigned_short_value) failures++;
	if ((int)-1234567.75L != int_value) failures++;
	if ((unsigned int)2345678.75L != unsigned_int_value) failures++;
	if ((long)-123456789.75L != -123456789L) failures++;
	if ((unsigned long)4000000000.75L != 4000000000UL) failures++;
	if ((long long)-123456789012345.75L != long_long_value) failures++;
	if ((unsigned long long)2305843009213693951.75L != unsigned_long_long_value) failures++;
	if ((double)12.5L != 12.5 || (float)1.25L != 1.25f) failures++;

	if (global_value != 3.125L) failures++;
	if (value_table[0].value != 0.5L || value_table[1].value != 1.25L ||
		value_table[2].value != 2.75L) failures++;
	return failures;
}
