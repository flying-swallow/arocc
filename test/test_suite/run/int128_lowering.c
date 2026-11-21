// #kind: run
// #exit: 0
// 128-bit integer arithmetic, shifts, compares, selects, memory and calls in
// the x86_64 lowering (16-byte slots, lo/hi register pairs). Expected text
// was produced by GCC from the same program.
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static char buffer[8192];
static size_t used;
static void out(const char *format, ...) {
    va_list ap;
    va_start(ap, format);
    used += (size_t)vsnprintf(buffer + used, sizeof buffer - used, format, ap);
    va_end(ap);
}

static const char expected[] =
    "add 0123456789abcdef7edcba9876543211\n"
    "sub 0123456789abcdf07edcba987654320f\n"
    "sub2 fedcba987654320f8123456789abcdf1\n"
    "mul 01b4e81b4e81b4e7fedcba9876543210\n"
    "mulc 79be0246864e30738641fdb9796dfe70\n"
    "n=0 shl 0123456789abcdeffedcba9876543210\n"
    "lshr ffffffffffffffff8000000000000001\n"
    "ashr ffffffffffffffff8000000000000001\n"
    "ashr+ 0123456789abcdeffedcba9876543210\n"
    "n=1 shl 02468acf13579bdffdb97530eca86420\n"
    "lshr 7fffffffffffffffc000000000000000\n"
    "ashr ffffffffffffffffc000000000000000\n"
    "ashr+ 0091a2b3c4d5e6f7ff6e5d4c3b2a1908\n"
    "n=31 shl c4d5e6f7ff6e5d4c3b2a190800000000\n"
    "lshr 00000001ffffffffffffffff00000000\n"
    "ashr ffffffffffffffffffffffff00000000\n"
    "ashr+ 0000000002468acf13579bdffdb97530\n"
    "n=32 shl 89abcdeffedcba987654321000000000\n"
    "lshr 00000000ffffffffffffffff80000000\n"
    "ashr ffffffffffffffffffffffff80000000\n"
    "ashr+ 000000000123456789abcdeffedcba98\n"
    "n=63 shl ff6e5d4c3b2a19080000000000000000\n"
    "lshr 0000000000000001ffffffffffffffff\n"
    "ashr ffffffffffffffffffffffffffffffff\n"
    "ashr+ 000000000000000002468acf13579bdf\n"
    "n=64 shl fedcba98765432100000000000000000\n"
    "lshr 0000000000000000ffffffffffffffff\n"
    "ashr ffffffffffffffffffffffffffffffff\n"
    "ashr+ 00000000000000000123456789abcdef\n"
    "n=65 shl fdb97530eca864200000000000000000\n"
    "lshr 00000000000000007fffffffffffffff\n"
    "ashr ffffffffffffffffffffffffffffffff\n"
    "ashr+ 00000000000000000091a2b3c4d5e6f7\n"
    "n=100 shl 65432100000000000000000000000000\n"
    "lshr 0000000000000000000000000fffffff\n"
    "ashr ffffffffffffffffffffffffffffffff\n"
    "ashr+ 00000000000000000000000000123456\n"
    "n=127 shl 00000000000000000000000000000000\n"
    "lshr 00000000000000000000000000000001\n"
    "ashr ffffffffffffffffffffffffffffffff\n"
    "ashr+ 00000000000000000000000000000000\n"
    "mulhi fffffffffffffff0 f\n"
    "mulhi 1 0\n"
    "neg fedcba98765432100123456789abcdf0\n"
    "neg0 00000000000000000000000000000000\n"
    "inv fedcba98765432100123456789abcdef\n"
    "sx fffffffffffffffffffffffffffffffb\n"
    "sx2 00000000000000000000000000000005\n"
    "00 1a 1a\n"
    "01 23 23\n"
    "02 2c 23\n"
    "03 23 23\n"
    "04 2c 23\n"
    "05 2c 23\n"
    "06 2c 23\n"
    "10 2c 2c\n"
    "11 1a 1a\n"
    "12 2c 23\n"
    "13 23 23\n"
    "14 2c 23\n"
    "15 2c 23\n"
    "16 2c 23\n"
    "20 23 2c\n"
    "21 23 2c\n"
    "22 1a 1a\n"
    "23 23 2c\n"
    "24 2c 2c\n"
    "25 2c 2c\n"
    "26 2c 2c\n"
    "30 2c 2c\n"
    "31 2c 2c\n"
    "32 2c 23\n"
    "33 1a 1a\n"
    "34 2c 23\n"
    "35 2c 23\n"
    "36 2c 23\n"
    "40 23 2c\n"
    "41 23 2c\n"
    "42 23 23\n"
    "43 23 2c\n"
    "44 1a 1a\n"
    "45 2c 2c\n"
    "46 2c 2c\n"
    "50 23 2c\n"
    "51 23 2c\n"
    "52 23 23\n"
    "53 23 2c\n"
    "54 23 23\n"
    "55 1a 1a\n"
    "56 2c 2c\n"
    "60 23 2c\n"
    "61 23 2c\n"
    "62 23 23\n"
    "63 23 2c\n"
    "64 23 23\n"
    "65 23 23\n"
    "66 1a 1a\n"
    "many 0369d0369d0369cf7c962fc962fc9635\n"
    "sel1 0123456789abcdeffedcba9876543210\n"
    "sel0 ffffffffffffffff8000000000000001\n"
    "mem ffffffffffffffff8000000000000002\n"
    "memv ffffffffffffffff8000000000000001\n"
    "loop 0000000000000000d2e6e166b367e215\n"
    "trunc 1985229328 18436495882557490754\n";
typedef unsigned __int128 u128;
typedef __int128 i128;
typedef unsigned long long u64;
static void p(const char *n, u128 v) { out("%s %016llx%016llx\n", n, (u64)(v >> 64), (u64)v); }
static u128 mk(u64 hi, u64 lo) { return ((u128)hi << 64) | lo; }
static u128 add(u128 a, u128 b) { return a + b; }
static u128 sub(u128 a, u128 b) { return a - b; }
static u128 mul(u128 a, u128 b) { return a * b; }
static u128 shl(u128 a, int n) { return a << n; }
static u128 lshr(u128 a, int n) { return a >> n; }
static i128 ashr(i128 a, int n) { return a >> n; }
static u64 mulhi(u64 a, u64 b, u64 *lo) { u128 r = (u128)a * b; *lo = (u64)r; return (u64)(r >> 64); }
static i128 neg(i128 a) { return -a; }
static u128 inv(u128 a) { return ~a; }
static i128 sx(long long v) { return v; }
static int cmps(i128 a, i128 b) { return (a < b) | (a <= b) << 1 | (a > b) << 2 | (a >= b) << 3 | (a == b) << 4 | (a != b) << 5; }
static int cmpu(u128 a, u128 b) { return (a < b) | (a <= b) << 1 | (a > b) << 2 | (a >= b) << 3 | (a == b) << 4 | (a != b) << 5; }
static u128 many(int a, u128 x, int b, u128 y) { return x * (u64)a + y + (u64)b; }
static u128 sel(int c, u128 a, u128 b) { return c ? a : b; }
struct S { int k; u128 v; };
static u128 viamem(struct S *s, u128 v) { s->v = v; return s->v + 1; }
int main(void) {
  u128 a = mk(0x0123456789abcdefULL, 0xfedcba9876543210ULL);
  u128 b = mk(0xffffffffffffffffULL, 0x8000000000000001ULL);
  p("add", add(a, b)); p("sub", sub(a, b)); p("sub2", sub(b, a)); p("mul", mul(a, b));
  p("mulc", mul(a, 1000000007));
  int counts[] = {0, 1, 31, 32, 63, 64, 65, 100, 127};
  for (int i = 0; i < 9; i++) { int n = counts[i]; out("n=%d ", n); p("shl", shl(a, n)); p("lshr", lshr(b, n)); p("ashr", (u128)ashr((i128)b, n)); p("ashr+", (u128)ashr((i128)a, n)); }
  u64 lo, hi = mulhi(0xffffffffffffffffULL, 0xfffffffffffffff1ULL, &lo); out("mulhi %llx %llx\n", hi, lo);
  hi = mulhi(0x8000000000000000ULL, 2, &lo); out("mulhi %llx %llx\n", hi, lo);
  p("neg", (u128)neg((i128)a)); p("neg0", (u128)neg(0)); p("inv", inv(a)); p("sx", (u128)sx(-5)); p("sx2", (u128)sx(5));
  i128 vals[] = {0, 1, -1, (i128)a, (i128)b, -(i128)a, (i128)mk(0x8000000000000000ULL, 0)};
  for (int i = 0; i < 7; i++) for (int j = 0; j < 7; j++) out("%d%d %02x %02x\n", i, j, cmps(vals[i], vals[j]), cmpu((u128)vals[i], (u128)vals[j]));
  p("many", many(3, a, 4, b)); p("sel1", sel(1, a, b)); p("sel0", sel(0, a, b));
  struct S s; p("mem", viamem(&s, b)); p("memv", s.v);
  u128 acc = 1; for (int i = 0; i < 40; i++) acc = acc * 3 + (u128)i; p("loop", acc);
  out("trunc %u %llu\n", (unsigned)a, (u64)(a >> 3));
  if (strcmp(buffer, expected) != 0) { fputs(buffer, stdout); return 1; }
  return 0;
}
