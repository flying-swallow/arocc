// #kind: run
// #exit: 0
// #opt: --emulate=gcc
struct S { unsigned long long a:33, b:40, c:41; signed long long d:33; unsigned int small:3; };
struct S x = { 0x100000, 0x100000, 0x100000, -3, 7 };
int calls;
unsigned long long once(void) { ++calls; return 2; }
int main(void) {
  if ((x.a) * (x.a) != 0 || x.a * x.b != 0 || x.a * x.c != 0x10000000000ULL) return 1;
  if ((unsigned long long)x.a * x.a != 0x10000000000ULL) return 2;
  x.a = 0x100000000ULL;
  if (x.a + x.a != 0 || x.a + x.b != 0x100100000ULL) return 3;
  if ((x.a + x.a) + 1 != 1 || x.a + 0x100000000ULL != 0x200000000ULL) return 4;
  x.a = 0x1ffffffffULL;
  if (++x.a != 0 || --x.b != 0xfffff || x.c-- != 0x100000) return 5;
  if (x.d * 2 != -6 || x.d + 1 != -2 || -x.d != 3) return 6;
  if (x.small + 1 != 8 || x.a + once() != 2 || calls != 1) return 7;
  return 0;
}
