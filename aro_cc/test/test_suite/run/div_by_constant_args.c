// #kind: run
// #exit: 0
#include <stdarg.h>

static long f(long a, long b, long c, long d, long e, long g) {
	long q = a / 7 + b % 10;
	return q + e * 3 + g;
}

static long f_runtime(long a, long b, long c, long d, long e, long g) {
	volatile long divisor7 = 7;
	volatile long divisor10 = 10;
	long q = a / divisor7 + b % divisor10;
	return q + e * 3 + g;
}

static long v(int n, ...) {
	va_list args;
	va_start(args, n);
	long q = va_arg(args, long) / 7;
	long e = va_arg(args, long);
	long g = va_arg(args, long);
	va_end(args);
	return q + e * 3 + g;
}

int main(void) {
	long a = 123456789;
	long b = -12345;
	long c = 23;
	long d = 47;
	long e = 1763;
	long g = 1371;
	/* Volatile function pointers keep the ABI calls out of line at higher optimization levels. */
	long (* volatile constant_call)(long, long, long, long, long, long) = f;
	long (* volatile runtime_call)(long, long, long, long, long, long) = f_runtime;
	long (* volatile variadic_call)(int, ...) = v;

	if (constant_call(a, b, c, d, e, g) != runtime_call(a, b, c, d, e, g)) return 1;
	if (variadic_call(3, a, e, g) != constant_call(a, 0, c, d, e, g)) return 1;
	return 0;
}
