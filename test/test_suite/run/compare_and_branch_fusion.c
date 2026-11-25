// #kind: run
// #exit: 0
// Compares fused into branches and selects (CMP/UCOMIS + Jcc/CMOVcc): every
// predicate, both operand orders, immediates, NaN, unsigned and narrow widths.
#include <stdio.h>

__attribute__((noinline)) static int br_lt(long a, long b) { if (a < b) return 1; return 0; }
__attribute__((noinline)) static int br_le(long a, long b) { if (a <= b) return 1; return 0; }
__attribute__((noinline)) static int br_gt(long a, long b) { if (a > b) return 1; return 0; }
__attribute__((noinline)) static int br_ge(long a, long b) { if (a >= b) return 1; return 0; }
__attribute__((noinline)) static int br_ult(unsigned a, unsigned b) { if (a < b) return 1; return 0; }
__attribute__((noinline)) static int br_uge(unsigned a, unsigned b) { if (a >= b) return 1; return 0; }
__attribute__((noinline)) static int br_imm_left(long a) { if (5 < a) return 1; return 0; }
__attribute__((noinline)) static int br_imm_big(long a) { if (a == 0x100000000L) return 1; return 0; }
__attribute__((noinline)) static int br_char(signed char a, signed char b) { if (a < b) return 1; return 0; }
__attribute__((noinline)) static int br_uchar(unsigned char a, unsigned char b) { if (a < b) return 1; return 0; }
__attribute__((noinline)) static int br_ptr(int *p) { if (p) return 1; return 0; }
__attribute__((noinline)) static int fbr_eq(double a, double b) { if (a == b) return 1; return 0; }
__attribute__((noinline)) static int fbr_ne(double a, double b) { if (a != b) return 1; return 0; }
__attribute__((noinline)) static int fbr_lt(double a, double b) { if (a < b) return 1; return 0; }
__attribute__((noinline)) static int fbr_le(float a, float b) { if (a <= b) return 1; return 0; }
__attribute__((noinline)) static int fbr_gt(double a, double b) { if (a > b) return 1; return 0; }
__attribute__((noinline)) static int fbr_ge(float a, float b) { if (a >= b) return 1; return 0; }
__attribute__((noinline)) static long sel_min(long a, long b) { return a < b ? a : b; }
__attribute__((noinline)) static unsigned sel_umax(unsigned a, unsigned b) { return a > b ? a : b; }
__attribute__((noinline)) static int fsel_lt(double a, double b) { return a < b ? 7 : 9; }
__attribute__((noinline)) static int fsel_eq(double a, double b) { return a == b ? 7 : 9; }

__attribute__((noinline)) static long loop_sum(const long *a, long n)
{
	long s = 0;
	for (long i = 0; i < n; i++)
		if (a[i] > 3) s += a[i];
	return s;
}

int main(void)
{
	double nan = __builtin_nan("");
	int fails = 0;
#define CHECK(e, want) do { if ((e) != (want)) { printf("fail line %d\n", __LINE__); fails++; } } while (0)
	long vals[] = { -3, 0, 2, 5 };
	for (int i = 0; i < 4; i++)
		for (int j = 0; j < 4; j++)
		{
			long a = vals[i], b = vals[j];
			CHECK(br_lt(a, b), a < b);
			CHECK(br_le(a, b), a <= b);
			CHECK(br_gt(a, b), a > b);
			CHECK(br_ge(a, b), a >= b);
			CHECK(br_ult((unsigned)a, (unsigned)b), (unsigned)a < (unsigned)b);
			CHECK(br_uge((unsigned)a, (unsigned)b), (unsigned)a >= (unsigned)b);
			CHECK(br_char((signed char)a, (signed char)b), a < b);
			CHECK(fbr_eq((double)a, (double)b), a == b);
			CHECK(fbr_ne((double)a, (double)b), a != b);
			CHECK(fbr_lt((double)a, (double)b), a < b);
			CHECK(fbr_le((float)a, (float)b), a <= b);
			CHECK(fbr_gt((double)a, (double)b), a > b);
			CHECK(fbr_ge((float)a, (float)b), a >= b);
			CHECK(sel_min(a, b), a < b ? a : b);
			CHECK(sel_umax((unsigned)a, (unsigned)b), (unsigned)a > (unsigned)b ? (unsigned)a : (unsigned)b);
			CHECK(fsel_lt((double)a, (double)b), a < b ? 7 : 9);
			CHECK(fsel_eq((double)a, (double)b), a == b ? 7 : 9);
		}
	CHECK(br_uchar(200, 3), 0);
	CHECK(br_uchar(3, 200), 1);
	CHECK(br_char(-56, 3), 1);
	CHECK(br_imm_left(6), 1);
	CHECK(br_imm_left(5), 0);
	CHECK(br_imm_big(0x100000000L), 1);
	CHECK(br_imm_big(0), 0);
	CHECK(br_ptr(0), 0);
	CHECK(br_ptr(&fails), 1);
	// Every ordered predicate is false on NaN; != is true.
	CHECK(fbr_eq(nan, nan), 0);
	CHECK(fbr_ne(nan, 1.0), 1);
	CHECK(fbr_lt(nan, 1.0), 0);
	CHECK(fbr_lt(1.0, nan), 0);
	CHECK(fbr_le((float)nan, 1.0f), 0);
	CHECK(fbr_gt(nan, 1.0), 0);
	CHECK(fbr_ge(1.0f, (float)nan), 0);
	CHECK(fsel_lt(nan, 1.0), 9);
	CHECK(fsel_eq(nan, nan), 9);
	long arr[] = { 1, 4, 9, 3, 5 };
	CHECK(loop_sum(arr, 5), 18);
	return fails;
}
