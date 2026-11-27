// #kind: run
// #exit: 0
// #opt: -w
/* Keep comparisons observable across calls so the optimizer must preserve
   their integer and conditional-expression semantics. */
#define NOINLINE __attribute__((noinline))

static NOINLINE int equal_branch(int a, int b)
{
	int comparison = a == b;
	if (comparison)
		return 1;
	return 0;
}

static NOINLINE int less_branch(int a, int b)
{
	int comparison = a < b;
	if (comparison)
		return 1;
	return 0;
}

static NOINLINE int double_negation(int x)
{
	return !!x;
}

static NOINLINE int unsigned_char_eq_300(unsigned char c)
{
	int comparison = c == 300;
	if (comparison)
		return 1;
	return 0;
}

static NOINLINE int signed_char_lt_minus_one(signed char c)
{
	int comparison = c < -1;
	if (comparison)
		return 1;
	return 0;
}

static NOINLINE int ten_lt_unsigned_char(unsigned char c)
{
	int comparison = 10 < c;
	if (comparison)
		return 1;
	return 0;
}

static NOINLINE int minus_five_lt_signed_char(signed char c)
{
	int comparison = -5 < c;
	if (comparison)
		return 1;
	return 0;
}

static NOINLINE int unsigned_char_lt_ffffff80(signed char sc)
{
	int comparison = (unsigned)sc < 0xFFFFFF80u;
	if (comparison)
		return 1;
	return 0;
}

static NOINLINE int not_less_select(int a, int b)
{
	return !(a < b) ? 17 : 29;
}

static NOINLINE int not_equal_double(double x, double y)
{
	return !(x == y);
}

static NOINLINE int not_not_equal_double(double x, double y)
{
	return !(x != y);
}

static NOINLINE int equal_double_select_inverted(double x, double y)
{
	return (x == y) ? 0 : 1;
}

int main(void)
{
	int failures = 0;
	if (equal_branch(4, 4) != 1 || equal_branch(4, 5) != 0) failures |= 1;
	if (less_branch(-3, 2) != 1 || less_branch(2, -3) != 0) failures |= 2;
	if (double_negation(0) != 0 || double_negation(-7) != 1) failures |= 4;
	if (unsigned_char_eq_300(0) != 0 || unsigned_char_eq_300(1) != 0 ||
		unsigned_char_eq_300(255) != 0)
		failures |= 8;
	if (signed_char_lt_minus_one(-128) != 1 || signed_char_lt_minus_one(-2) != 1 ||
		signed_char_lt_minus_one(-1) != 0 || signed_char_lt_minus_one(0) != 0)
		failures |= 16;
	if (ten_lt_unsigned_char(5) != 0 || ten_lt_unsigned_char(10) != 0 ||
		ten_lt_unsigned_char(11) != 1 || ten_lt_unsigned_char(255) != 1)
		failures |= 128;
	if (minus_five_lt_signed_char(-6) != 0 || minus_five_lt_signed_char(-5) != 0 ||
		minus_five_lt_signed_char(-4) != 1 || minus_five_lt_signed_char(127) != 1)
		failures |= 256;
	if (unsigned_char_lt_ffffff80(-128) != 0 ||
		unsigned_char_lt_ffffff80(-127) != 0 ||
		unsigned_char_lt_ffffff80(0) != 1 || unsigned_char_lt_ffffff80(127) != 1)
		failures |= 512;
	if (not_less_select(1, 2) != 29 || not_less_select(2, 1) != 17 ||
		not_less_select(1, 1) != 17)
		failures |= 32;
	double nan = __builtin_nan("");
	if (not_equal_double(nan, nan) != 1 ||
		not_equal_double(nan, 3.0) != 1 || not_equal_double(3.0, nan) != 1 ||
		not_equal_double(3.0, 3.0) != 0 ||
		not_equal_double(3.0, 4.0) != 1)
		failures |= 64;
	if (not_not_equal_double(nan, nan) != 0 ||
		not_not_equal_double(3.0, 3.0) != 1 ||
		not_not_equal_double(nan, 3.0) != 0)
		failures |= 1024;
	if (equal_double_select_inverted(nan, nan) != 1 ||
		equal_double_select_inverted(3.0, 3.0) != 0 ||
		equal_double_select_inverted(nan, 3.0) != 1)
		failures |= 2048;
	return failures;
}
