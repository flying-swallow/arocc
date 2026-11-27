// #kind: run
// #exit: 0
// Loop-carried values that permute each iteration: PHI copies on the back edge
// form swaps and rotations that must behave as one parallel assignment.
#include <stdio.h>

__attribute__((noinline)) long swap2(long a, long b, int n)
{
	for (int i = 0; i < n; i++) { long t = a; a = b; b = t; }
	return a * 10 + b;
}

__attribute__((noinline)) long rotate3(long a, long b, long c, int n)
{
	for (int i = 0; i < n; i++) { long t = a; a = b; b = c; c = t; }
	return a * 100 + b * 10 + c;
}

__attribute__((noinline)) double fswap(double a, double b, int n)
{
	for (int i = 0; i < n; i++) { double t = a; a = b; b = t; }
	return a * 10 + b;
}

__attribute__((noinline)) long mixed(long a, double f, short s, char c, int n)
{
	double g = 0.5;
	for (int i = 0; i < n; i++)
	{
		double t = f; f = g; g = t;
		short u = s; s = (short)c; c = (char)u;
		a = a + s;
	}
	return a + (long)(f * 4) + (long)(g * 8) + s * 1000 + c;
}

__attribute__((noinline)) unsigned __int128 wide(unsigned __int128 a, unsigned __int128 b, int n)
{
	for (int i = 0; i < n; i++) { unsigned __int128 t = a; a = b; b = t; }
	return a - b;
}

__attribute__((noinline)) long fib(int n)
{
	long a = 0, b = 1;
	while (n-- > 0) { long t = a + b; a = b; b = t; }
	return a;
}

__attribute__((noinline)) long many(int n)
{
	// More loop-carried values than allocatable registers.
	long v0 = 0, v1 = 1, v2 = 2, v3 = 3, v4 = 4, v5 = 5, v6 = 6, v7 = 7, v8 = 8;
	for (int i = 0; i < n; i++)
	{
		long t = v0;
		v0 = v1; v1 = v2; v2 = v3; v3 = v4; v4 = v5; v5 = v6; v6 = v7; v7 = v8; v8 = t + i;
	}
	return v0 + 2 * v1 + 3 * v2 + 4 * v3 + 5 * v4 + 6 * v5 + 7 * v6 + 8 * v7 + 9 * v8;
}

int main(void)
{
	int fails = 0;
#define CHECK(e, want) do { if ((e) != (want)) { printf("line %d: %ld\n", __LINE__, (long)(e)); fails++; } } while (0)
	CHECK(swap2(1, 2, 0), 12);
	CHECK(swap2(1, 2, 3), 21);
	CHECK(swap2(1, 2, 4), 12);
	CHECK(rotate3(1, 2, 3, 1), 231);
	CHECK(rotate3(1, 2, 3, 2), 312);
	CHECK(rotate3(1, 2, 3, 3), 123);
	CHECK(fswap(1.0, 2.0, 3), 21.0);
	CHECK(mixed(0, 1.0, 7, 3, 3), 3030); /* gcc */
	CHECK(wide((unsigned __int128)5 << 64, 3, 1) == ((unsigned __int128)3 - ((unsigned __int128)5 << 64)), 1);
	CHECK(fib(50), 12586269025L);
	CHECK(many(5), 230); /* gcc */
	return fails;
}
