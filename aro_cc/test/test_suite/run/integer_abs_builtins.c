// #kind: run
// #exit: 0
/* Direct hosted calls use builtin abs semantics even with replacement
   definitions; function pointers must still call the actual function. */
int abs(int);
long labs(long);
long long llabs(long long);
volatile int count;
long long next(void) { ++count; return -0x100000001LL; }
int main(void)
{
  volatile int i = -123;
  volatile long l = -1234567L;
  volatile long long n = -0x100000001LL;
  if (abs(i) != 123 || labs(l) != 1234567L || llabs(n) != 0x100000001LL) return 1;
  if (__builtin_abs(i) != 123 || __builtin_labs(l) != 1234567L ||
      __builtin_llabs(n) != 0x100000001LL) return 2;
  if (llabs(next()) != 0x100000001LL || count != 1) return 3;
  if (abs(0) != 0 || llabs(7) != 7) return 4;
  long long (*fp)(long long) = llabs;
  if (fp(n) != 99) return 5;
  return 0;
}
int abs(int x) { return 99; }
long labs(long x) { return 99; }
long long llabs(long long x) { return 99; }
