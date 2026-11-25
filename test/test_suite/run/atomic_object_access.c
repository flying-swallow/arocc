// #kind: run
// #exit: 0
// Reading an `_Atomic` object is a seq_cst load and assigning it a seq_cst store
// (chibicc test/atomic.c). Compound assignment is load + op + store.
#include <stdatomic.h>
_Atomic int g = 5;
static int read_it(_Atomic int *p) { return *p; }
int main(void)
{
  _Atomic int x = 0;
  x = 3;
  x += 2;
  int y = x;
  atomic_int z = 7;
  if (y != 5 || read_it(&g) != 5 || atomic_load(&z) != 7) return 1;
  _Atomic long l = 1L << 40;
  if (l != (1L << 40)) return 2;
  return 0;
}
