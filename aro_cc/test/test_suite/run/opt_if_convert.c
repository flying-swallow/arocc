// #kind: run
// #exit: 0
// #opt: -O1
/* Exercise if-converted diamonds and triangles across scalar and pointer types.
   Each failure group sets one bit so the input grid identifies regressions. */
#define NULL ((void *)0)

static int ternary_int(int choose, int yes, int no)
{
	return choose ? yes : no;
}

static int ifelse_int(int choose, int yes, int no)
{
	int result;
	if (choose) result = yes;
	else result = no;
	return result;
}

static unsigned char ternary_uchar(int choose, unsigned char yes, unsigned char no)
{
	return choose ? yes : no;
}

static unsigned char ifelse_uchar(int choose, unsigned char value)
{
	if (choose) value = (unsigned char)(value + 3);
	return value;
}

static long ternary_long(int choose, long yes, long no)
{
	return choose ? yes : no;
}

static long ifelse_long(int choose, long value)
{
	if (choose) value = value + 5L;
	return value;
}

static int *ternary_pointer(int choose, int *value)
{
	return choose ? value : NULL;
}

static int *ifelse_pointer(int choose, int *value)
{
	int *result = NULL;
	if (choose) result = value;
	return result;
}

/* For nonnegative x the left arm is selected. At INT_MAX, evaluating the
   untaken x << 3 would be undefined even though the shift count is in range. */
static int guarded_shift(int x)
{
	return x >= 0 ? x : (x << 3);
}

/* The division must stay control dependent on d != 0. */
static int guarded_division(int d)
{
	return d != 0 ? 100 / d : 0;
}

int main(void)
{
	int failures = 0;
	int value = 17;
	int other = 23;
	for (int choose = 0; choose <= 1; ++choose) {
		for (int a = -4; a <= 4; ++a) {
			for (int b = -4; b <= 4; ++b) {
				if (ternary_int(choose, a, b) != (choose ? a : b) ||
					ifelse_int(choose, a, b) != (choose ? a : b)) failures |= 1;
				if (ternary_uchar(choose, (unsigned char)a, (unsigned char)b) !=
					(unsigned char)(choose ? a : b)) failures |= 2;
				if (ifelse_uchar(choose, (unsigned char)a) !=
					(unsigned char)(choose ? (unsigned char)(a + 3) : (unsigned char)a)) failures |= 4;
				if (ternary_long(choose, (long)a, (long)b) != (long)(choose ? a : b)) failures |= 8;
				if (ifelse_long(choose, (long)a) != (long)(choose ? a + 5 : a)) failures |= 16;
			}
		}
		if (ternary_pointer(choose, &value) != (choose ? &value : NULL) ||
			ifelse_pointer(choose, &value) != (choose ? &value : NULL)) failures |= 32;
	}
	if (ternary_pointer(0, &value) != NULL || ifelse_pointer(0, &value) != NULL) failures |= 32;
	if (guarded_shift(0) != 0 || guarded_shift(7) != 7 || guarded_shift(2147483647) != 2147483647) failures |= 64;
	for (int d = -9; d <= 9; ++d) {
		int expected = d ? 100 / d : 0;
		if (guarded_division(d) != expected) failures |= 128;
	}
	if (value != 17 || other != 23) failures |= 256;
	return failures;
}
