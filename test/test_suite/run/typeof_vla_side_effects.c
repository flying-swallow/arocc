// #kind: run
// #exit: 0
// #opt: --emulate=gcc -std=gnu99
/* Test for modifying and taking addresses of compound literals whose
   variably modified types involve typeof.  */
/* Origin: Joseph Myers <joseph@codesourcery.com> */
/* { dg-do run } */
/* { dg-options "-std=gnu99" } */

#include <stdarg.h>

extern void exit (int);
extern void abort (void);

int a[1];

void
f1 (void)
{
  int i = 0;
  int (**p)[1] = &(typeof (++i, (int (*)[i])a)){&a};
  if (*p != &a)
    abort ();
  if (i != 1)
    abort ();
}

void
f2 (void)
{
  int i = 0;
  (typeof (++i, (int (*)[i])a)){&a} = 0;
  if (i != 1)
    abort ();
}

void
f3 (void)
{
  int i = 0;
  (typeof (++i, (int (*)[i])a)){&a} += 1;
  if (i != 1)
    abort ();
}

void
f4 (void)
{
  int i = 0;
  --(typeof (++i, (int (*)[i])a)){&a + 1};
  if (i != 1)
    abort ();
}

void
f5 (void)
{
  int i = 0;
  (typeof (++i, (int (*)[i])a)){&a}++;
  if (i != 1)
    abort ();
}

int
original_main (void)
{
  f1 ();
  f2 ();
  f3 ();
  f4 ();
  f5 ();
  return 0;
}

int main(void) {
  original_main();
  int i = 0;
  typeof(++i) unevaluated = 3;
  if (i != 0 || unevaluated != 3) return 1;
  int n = 2;
  typedef int Arr[n++];
  Arr first;
  Arr second;
  if (n != 3) return 2;
  first[1] = 5; second[1] = first[1];
  if (second[1] != 5) return 8;
  for (int j = 0; j < 3; ++j) {
    int k = 0;
    int (*p)[1] = (typeof(++k, (int (*)[k])a)){&a};
    if (k != 1 || p != &a) return 3;
  }
  int bound = 2;
  int storage[32];
  int (*p)[bound++] = (void *)storage;
  if (bound != 3) return 4;
  if ((char *)(p + 1) - (char *)p != 2 * sizeof(int)) return 5;
  int casts = 2;
  (void)(int (*)[casts++])a;
  if (casts != 3) return 6;
  int t = 0;
  typeof(++t, (int (*)[t])a) q = &a;
  if (t != 1 || q != &a) return 7;
  return 0;
}
