// #kind: run
// #exit: 51
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

/* Volatile function pointers keep the ABI calls out of line at higher optimization levels. */

static long f9(int a, int b, int c, int d, int e, int f, int g, int h, int i)
{
	return (long)a + 2L * b + 3L * c + 4L * d + 5L * e + 6L * f +
		7L * g + 8L * h + 9L * i;
}

static int f8(int a, int b, int c, int d, int e, int f, int g, int h)
{
	return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h;
}

static int narrow_args(int a, int b, int c, int d, int e, int f,
		 signed char g, short h)
{
	return a + b + c + d + e + f + 10 * (int)g + (int)h;
}

static int narrow_register_args(signed char a, unsigned char b,
			short c, unsigned short d)
{
	return ((int)a == -117 ? 1 : 0) |
		((unsigned int)b == 231U ? 2 : 0) |
		((int)c == -30001 ? 4 : 0) |
		((unsigned int)d == 48879U ? 8 : 0);
}

static volatile int boundary_expected_g;
static volatile int boundary_expected_h;

static int int_boundary_args(int a, int b, int c, int d, int e, int f,
			int g, int h)
{
	return a == -117 && b == 231 && c == -30001 && d == 48879 &&
		e == 5 && f == 6 && g == boundary_expected_g &&
		h == boundary_expected_h;
}

static int unsigned_narrow_args(int a, int b, int c, int d, int e, int f,
			unsigned char g, unsigned short h)
{
	return a + b + c + d + e + f + 10 * (int)(unsigned int)g +
		(int)(unsigned int)h;
}

static int pointer_seventh(int a, int b, int c, int d, int e, int f, int *p)
{
	return a + b + c + d + e + f + *p;
}

static long nested_calls(void)
{
	int (* volatile call_f8)(int, int, int, int, int, int, int, int) = f8;
	long (* volatile call_f9)(int, int, int, int, int, int, int, int, int) = f9;
	return call_f9(call_f8(1, 1, 1, 1, 1, 1, 1, 1) % 5,
		1, 0, 1, 0, 1, 0, 1, 0);
}

static long relay9(int a, int b, int c, int d, int e, int f, int g, int h, int i)
{
	long (* volatile call_f9)(int, int, int, int, int, int, int, int, int) = f9;
	return call_f9(a, b, c, d, e, f, g, h, i);
}

static int recursive7(int depth, int a, int b, int c, int d, int e, int f)
{
	if (depth == 0)
		return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f;
	int (* volatile recur)(int, int, int, int, int, int, int) = recursive7;
	return recur(depth - 1, a + 1, b + 1, c + 1, d + 1, e + 1, f + 1) + depth;
}

static int after_vla(int n)
{
	volatile int bound = n;
	int scratch[bound];
	for (int i = 0; i < bound; i++) scratch[i] = i + 1;
	int (* volatile call_f8)(int, int, int, int, int, int, int, int) = f8;
	return call_f8(1, 1, 1, 1, 1, 1, 1, 1) + scratch[0] + scratch[bound - 1];
}

static int vsum(int n, ...)
{
	va_list ap;
	va_start(ap, n);
	int sum = 0;
	for (int i = 0; i < n; i++) sum += va_arg(ap, int);
	va_end(ap);
	return sum;
}

static int fmt(char *buf, size_t n, const char *f, ...)
{
	va_list ap;
	va_start(ap, f);
	int length = vsnprintf(buf, n, f, ap);
	va_end(ap);
	return length + (strcmp(buf, "10:20:30:40") == 0 ? 13 : 0);
}

static void add_checksum(int *checksum, int value)
{
	*checksum = (*checksum + value) % 251;
	if (*checksum < 0) *checksum += 251;
}

int main(void)
{
	long (* volatile call_f9)(int, int, int, int, int, int, int, int, int) = f9;
	int (* volatile call_f8)(int, int, int, int, int, int, int, int) = f8;
	int (* volatile call_narrow)(int, int, int, int, int, int, signed char, short) = narrow_args;
	int (* volatile call_narrow_register)(signed char, unsigned char, short, unsigned short) = narrow_register_args;
	int (* volatile call_unsigned_narrow)(int, int, int, int, int, int, unsigned char, unsigned short) = unsigned_narrow_args;
	int (* volatile call_boundary_register_stack)(signed char, unsigned char,
		short, unsigned short, int, int, signed char, unsigned short) =
		(int (*)(signed char, unsigned char, short, unsigned short,
			int, int, signed char, unsigned short))int_boundary_args;
	int (* volatile call_boundary_stack)(int, int, int, int, int, int,
		unsigned char, short) =
		(int (*)(int, int, int, int, int, int, unsigned char, short))int_boundary_args;
	int (* volatile call_pointer)(int, int, int, int, int, int, int *) = pointer_seventh;
	long (* volatile call_relay)(int, int, int, int, int, int, int, int, int) = relay9;
	int (* volatile call_recursive)(int, int, int, int, int, int, int) = recursive7;
	int (* volatile call_after_vla)(int) = after_vla;
	int (* volatile call_vsum)(int, ...) = vsum;
	int (* volatile call_fmt)(char *, size_t, const char *, ...) = fmt;
	long r_f9 = call_f9(1, 1, 2, 1, 3, 2, 1, 2, 3);
	int r_f8 = call_f8(1, 2, 1, 0, 1, 0, 1, 1);
	int r_narrow = call_narrow(0, 0, 0, 0, 0, 0, (signed char)-117, (short)-30001);
	int r_narrow_register = call_narrow_register((signed char)-117,
		(unsigned char)231, (short)-30001, (unsigned short)48879);
	int r_unsigned_narrow = call_unsigned_narrow(0, 0, 0, 0, 0, 0,
		(unsigned char)231, (unsigned short)48879);
	boundary_expected_g = -117;
	boundary_expected_h = 48879;
	int r_boundary = call_boundary_register_stack((signed char)-117,
		(unsigned char)231, (short)-30001, (unsigned short)48879,
		5, 6, (signed char)-117, (unsigned short)48879);
	boundary_expected_g = 231;
	boundary_expected_h = -30001;
	r_boundary += call_boundary_stack(-117, 231, -30001, 48879, 5, 6,
		(unsigned char)231, (short)-30001);
	int pointed = 7;
	int r_pointer = call_pointer(1, 2, 3, 4, 5, 6, &pointed);
	int (* volatile indirect)(int, int, int, int, int, int, int, int) = f8;
	int r_indirect = indirect(1, 1, 1, 1, 1, 1, 1, 1);
	long r_nested = nested_calls();
	long r_relay = call_relay(1, 1, 2, 1, 3, 2, 1, 2, 3);
	int r_recursive = call_recursive(3, 1, 2, 3, 4, 5, 6);
	int r_vla = call_after_vla(4);
	int r_vsum = call_vsum(10, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
	char buf[64];
	int r_fmt = call_fmt(buf, sizeof buf, "%d:%d:%d:%d", 10, 20, 30, 40);
	int printed = snprintf(buf, sizeof buf, "%d:%d:%d:%d", 3, 4, 5, 6);
	int r_snprintf = printed + (strcmp(buf, "3:4:5:6") == 0 ? 20 : 0);
	int failures = 0;
	int checksum = 0;

	if (r_f9 != 90) failures++;
	if (r_f8 != 28) failures++;
	if (r_narrow != -31171) failures++;
	if (r_narrow_register != 15) failures++;
	if (r_unsigned_narrow != 51189) failures++;
	if (r_boundary != 2) failures++;
	if (r_pointer != 28) failures++;
	if (r_indirect != 36) failures++;
	if (r_nested != 21) failures++;
	if (r_relay != 90) failures++;
	if (r_recursive != 160) failures++;
	if (r_vla != 41) failures++;
	if (r_vsum != 55) failures++;
	if (r_fmt != 24) failures++;
	if (r_snprintf != 27) failures++;

	add_checksum(&checksum, (int)r_f9);
	add_checksum(&checksum, r_f8);
	add_checksum(&checksum, r_narrow);
	add_checksum(&checksum, r_narrow_register);
	add_checksum(&checksum, r_unsigned_narrow);
	add_checksum(&checksum, r_pointer);
	add_checksum(&checksum, r_indirect);
	add_checksum(&checksum, (int)r_nested);
	add_checksum(&checksum, (int)r_relay);
	add_checksum(&checksum, r_recursive);
	add_checksum(&checksum, r_vla);
	add_checksum(&checksum, r_vsum);
	add_checksum(&checksum, r_fmt);
	add_checksum(&checksum, r_snprintf);
	return failures ? 250 : checksum;
}
