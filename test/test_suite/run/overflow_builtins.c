// #kind: run
// #exit: 0
// __builtin_{add,sub,mul}_overflow lowered through exact i128 arithmetic, with
// mixed operand/result signedness and widths. Expected text from GCC.
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
static char buffer[4096];
static size_t used;
static void out(const char *format, ...) {
    va_list ap;
    va_start(ap, format);
    used += (size_t)vsnprintf(buffer + used, sizeof buffer - used, format, ap);
    va_end(ap);
}
static const char expected[] =
    "add ll 1 -9223372036854775808/9223372036854775808\n"
    "add ll 0 9223372036854775806/9223372036854775806\n"
    "sub ll 1 9223372036854775807/9223372036854775807\n"
    "sub ll 1 -9223372036854775808/9223372036854775808\n"
    "mul ll 1 -2/18446744073709551614\n"
    "mul ll 1 -9223372036854775808/9223372036854775808\n"
    "mul ll 0 9223372030926249001/9223372030926249001\n"
    "mul ll 1 -9223372036709301616/9223372037000250000\n"
    "add ull 1 0/0\n"
    "sub ull 1 -1/18446744073709551615\n"
    "mul ull 1 0/0\n"
    "mul ull 0 -9223372036854775808/9223372036854775808\n"
    "add int 1 -2147483648/18446744071562067968\n"
    "add unsigned 1 4294967295/4294967295\n"
    "sub unsigned char 0 2/2\n"
    "mul short 1 -25536/18446744073709526080\n"
    "add ll 1 -2/18446744073709551614\n"
    "add ull 0 5/5\n"
    "mul int 1 1/1\n";
typedef long long ll; typedef unsigned long long ull;
#define T(op, ty, a, b) do { ty r = 0; int o = __builtin_##op##_overflow(a, b, &r); out(#op " " #ty " %d %lld/%llu\n", o, (ll)r, (ull)r); } while (0)
static ll v(ll x) { return x; }
static ull uv(ull x) { return x; }
int main(void) {
  T(add, ll, v(LLONG_MAX), v(1)); T(add, ll, v(LLONG_MAX), v(-1)); T(sub, ll, v(LLONG_MIN), v(1)); T(sub, ll, v(0), v(LLONG_MIN));
  T(mul, ll, v(LLONG_MAX), v(2)); T(mul, ll, v(-1), v(LLONG_MIN)); T(mul, ll, v(3037000499), v(3037000499)); T(mul, ll, v(3037000500), v(3037000500));
  T(add, ull, uv(ULLONG_MAX), uv(1)); T(sub, ull, uv(0), uv(1)); T(mul, ull, uv(1ULL<<32), uv(1ULL<<32)); T(mul, ull, uv(1ULL<<31), uv(1ULL<<32));
  T(add, int, v(INT_MAX), v(1)); T(add, unsigned, v(-1), v(0)); T(sub, unsigned char, v(5), v(3)); T(mul, short, v(200), v(200));
  T(add, ll, uv(ULLONG_MAX), v(-1)); T(add, ull, v(-5), v(10)); T(mul, int, uv(ULLONG_MAX), v(-1));
  if (strcmp(buffer, expected) != 0) { fputs(buffer, stdout); return 1; }
  return 0;
}
