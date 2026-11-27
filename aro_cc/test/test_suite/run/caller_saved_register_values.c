// #kind: run
// #exit: 0
// Values held in caller-saved registers (RSI, RDI, R8-R10): incoming
// parameters must be read before any of them is reused, values live across
// calls and divisions must not sit in them, and leaf code may use them freely.
#include <stdio.h>

__attribute__((noinline)) int ignore_first(int unused, int a, int b, int c, int d, int e)
{
	return a * 10000 + b * 1000 + c * 100 + d * 10 + e;
}

__attribute__((noinline)) long shuffle(long a, long b, long c, long d, long e, long f)
{
	return ignore_first(0, (int)f, (int)e, (int)d, (int)c, (int)b) + a;
}

__attribute__((noinline)) long opaque(long x) { return x * 3; }

__attribute__((noinline)) long across_calls(long x, long y)
{
	long kept = x + y, other = x - y;
	long r = opaque(kept);
	r += opaque(other);
	return r + kept * 100 + other;
}

__attribute__((noinline)) long across_division(long x, long y, long z)
{
	long t = x + 1, u = y + 2;
	long q = z / 7 + z % 7 + x / y;
	return q + t * 100 + u * 10000;
}

__attribute__((noinline)) long leaf(long n)
{
	long a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8, i = 9, j = 10;
	for (long k = 0; k < n; k++)
	{
		a += b; b += c; c += d; d += e; e += f; f += g; g += h; h += i; i += j; j += k;
	}
	return a + b + c + d + e + f + g + h + i + j;
}

int main(void)
{
	int fails = 0;
#define CHECK(e, want) do { if ((e) != (want)) { printf("line %d: %ld\n", __LINE__, (long)(e)); fails++; } } while (0)
	CHECK(ignore_first(9, 1, 2, 3, 4, 5), 12345);
	CHECK(shuffle(1000000, 1, 2, 3, 4, 5), 1054321);
	CHECK(across_calls(5, 2), 3 * 7 + 3 * 3 + 700 + 3);
	CHECK(across_division(20, 6, 100), 100 / 7 + 100 % 7 + 20 / 6 + 2100 + 80000);
	CHECK(leaf(6), 3145); /* gcc */
	return fails;
}
