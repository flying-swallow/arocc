// #opt: -target armv7a
// Adapted from LLVM: https://github.com/llvm/llvm-project/blob/5ddae7ae330fdd9880ad512c986cbfb2faa26e1f/clang/test/Sema/builtins-arm-exclusive.c

struct Simple {
  char a, b;
};

int test_ldrex(char *addr) {
  int sum = 0;
  sum += __builtin_arm_ldrex(addr);
  sum += __builtin_arm_ldrex((short *)addr);
  sum += __builtin_arm_ldrex((int *)addr);
  sum += __builtin_arm_ldrex((long long *)addr);
  sum += __builtin_arm_ldrex((float *)addr);
  sum += __builtin_arm_ldrex((double *)addr);
  sum += *__builtin_arm_ldrex((int **)addr);
  sum += __builtin_arm_ldrex((struct Simple **)addr)->a;
  sum += __builtin_arm_ldrex((volatile char *)addr);
  sum += __builtin_arm_ldrex((const volatile char *)addr);

  // In principle this might be valid, but stick to ints and floats for scalar
  // types at the moment.
  sum += __builtin_arm_ldrex((struct Simple *)addr).a; // #error@30: address argument to __builtin_arm_ldrex must be a pointer to integer, floating-point, or pointer ('struct Simple *' invalid)

  sum += __builtin_arm_ldrex((__int128 *)addr); // #error@31: __int128 is not supported on this target // #error@30: address argument to __builtin_arm_ldrex must be a pointer to 1, 2, 4 or 8 byte type ('__int128 *' invalid)

  __builtin_arm_ldrex(); // #error@23: expected 1 argument(s) got 0
  __builtin_arm_ldrex(1, 2); // #error@23: address argument to __builtin_arm_ldrex must be a pointer to integer, floating-point, or pointer ('int' invalid) // #error@26: expected 1 argument(s) got 2
  return sum;
}

int test_strex(char *addr) {
  int res = 0;
  struct Simple var = {0};
  res |= __builtin_arm_strex(4, addr);
  res |= __builtin_arm_strex(42, (short *)addr);
  res |= __builtin_arm_strex(42, (int *)addr);
  res |= __builtin_arm_strex(42, (long long *)addr);
  res |= __builtin_arm_strex(2.71828f, (float *)addr);
  res |= __builtin_arm_strex(3.14159, (double *)addr);
  res |= __builtin_arm_strex(&var, (struct Simple **)addr);

  res |= __builtin_arm_strex(42, (volatile char *)addr);
  res |= __builtin_arm_strex(42, (char *const)addr); // #warning@34: cast to type 'char *const' will not preserve qualifiers [-Wcast-qualifiers]
  res |= __builtin_arm_strex(42, (const char *)addr); // #warning@34: passing 'const char *' to parameter of incompatible type 'volatile char *' discards qualifiers [-Wincompatible-pointer-types-discards-qualifiers]


  res |= __builtin_arm_strex(var, (struct Simple *)addr); // #error@35: address argument to __builtin_arm_strex must be a pointer to integer, floating-point, or pointer ('struct Simple *' invalid)
  res |= __builtin_arm_strex(var, (struct Simple **)addr); // #error@30: passing 'struct Simple' to parameter of incompatible type 'struct Simple *'
  res |= __builtin_arm_strex(&var, (struct Simple **)addr).a; // #error@60: member reference base type 'int' is not a structure or union

  res |= __builtin_arm_strex(1, (__int128 *)addr); // #error@34: __int128 is not supported on this target // #error@33: address argument to __builtin_arm_strex must be a pointer to 1, 2, 4 or 8 byte type ('__int128 *' invalid)

  __builtin_arm_strex(1); // #error@24: expected 2 argument(s) got 1
  __builtin_arm_strex(1, 2, 3); // #error@26: address argument to __builtin_arm_strex must be a pointer to integer, floating-point, or pointer ('int' invalid) // #error@29: expected 2 argument(s) got 3
  return res;
}

int test_ldrexd(char *addr) {
  int sum = 0;
  sum += __builtin_arm_ldrexd(addr); // #error@31: address argument to __builtin_arm_ldrexd must be a pointer to 8 byte type ('char *' invalid)
  sum += __builtin_arm_ldrexd((short *)addr); // #error@31: address argument to __builtin_arm_ldrexd must be a pointer to 8 byte type ('short *' invalid)
  sum += __builtin_arm_ldrexd((int *)addr); // #error@31: address argument to __builtin_arm_ldrexd must be a pointer to 8 byte type ('int *' invalid)
  sum += __builtin_arm_ldrexd((long long *)addr);
  sum += __builtin_arm_ldrexd((float *)addr); // #error@31: address argument to __builtin_arm_ldrexd must be a pointer to 8 byte type ('float *' invalid)
  sum += __builtin_arm_ldrexd((double *)addr);
  sum += *__builtin_arm_ldrexd((int **)addr); // #error@32: address argument to __builtin_arm_ldrexd must be a pointer to 8 byte type ('int **' invalid)
  sum += __builtin_arm_ldrexd((struct Simple **)addr)->a; // #error@31: address argument to __builtin_arm_ldrexd must be a pointer to 8 byte type ('struct Simple **' invalid)
  sum += __builtin_arm_ldrexd((volatile char *)addr); // #error@31: address argument to __builtin_arm_ldrexd must be a pointer to 8 byte type ('volatile char *' invalid)
  sum += __builtin_arm_ldrexd((const volatile char *)addr); // #error@31: address argument to __builtin_arm_ldrexd must be a pointer to 8 byte type ('const volatile char *' invalid)

  // In principle this might be valid, but stick to ints and floats for scalar
  // types at the moment.
  sum += __builtin_arm_ldrexd((struct Simple *)addr).a; // #error@31: address argument to __builtin_arm_ldrexd must be a pointer to integer, floating-point, or pointer ('struct Simple *' invalid)

  sum += __builtin_arm_ldrexd((__int128 *)addr); // #error@32: __int128 is not supported on this target // #error@31: address argument to __builtin_arm_ldrexd must be a pointer to 8 byte type ('__int128 *' invalid)

  __builtin_arm_ldrexd(); // #error@24: expected 1 argument(s) got 0
  __builtin_arm_ldrexd(1, 2); // #error@24: address argument to __builtin_arm_ldrexd must be a pointer to integer, floating-point, or pointer ('int' invalid) // #error@27: expected 1 argument(s) got 2
  return sum;
}

int test_strexd(char *addr) {
  int res = 0;
  struct Simple var = {0};
  res |= __builtin_arm_strexd(4, addr); // #error@34: address argument to __builtin_arm_strexd must be a pointer to 8 byte type ('char *' invalid)
  res |= __builtin_arm_strexd(42, (short *)addr); // #error@35: address argument to __builtin_arm_strexd must be a pointer to 8 byte type ('short *' invalid)
  res |= __builtin_arm_strexd(42, (int *)addr); // #error@35: address argument to __builtin_arm_strexd must be a pointer to 8 byte type ('int *' invalid)
  res |= __builtin_arm_strexd(42, (long long *)addr);
  res |= __builtin_arm_strexd(2.71828f, (float *)addr); // #error@41: address argument to __builtin_arm_strexd must be a pointer to 8 byte type ('float *' invalid)
  res |= __builtin_arm_strexd(3.14159, (double *)addr);
  res |= __builtin_arm_strexd(&var, (struct Simple **)addr); // #error@37: address argument to __builtin_arm_strexd must be a pointer to 8 byte type ('struct Simple **' invalid)

  res |= __builtin_arm_strexd(42, (volatile char *)addr); // #error@35: address argument to __builtin_arm_strexd must be a pointer to 8 byte type ('volatile char *' invalid)
  res |= __builtin_arm_strexd(42, (char *const)addr); // #warning@35: cast to type 'char *const' will not preserve qualifiers [-Wcast-qualifiers] // #error@35: address argument to __builtin_arm_strexd must be a pointer to 8 byte type ('char *' invalid)
  res |= __builtin_arm_strexd(42, (const char *)addr); // #warning@35: passing 'const char *' to parameter of incompatible type 'volatile char *' discards qualifiers [-Wincompatible-pointer-types-discards-qualifiers] // #error@35: address argument to __builtin_arm_strexd must be a pointer to 8 byte type ('const char *' invalid)


  res |= __builtin_arm_strexd(var, (struct Simple *)addr); // #error@36: address argument to __builtin_arm_strexd must be a pointer to integer, floating-point, or pointer ('struct Simple *' invalid)
  res |= __builtin_arm_strexd(var, (struct Simple **)addr); // #error@36: address argument to __builtin_arm_strexd must be a pointer to 8 byte type ('struct Simple **' invalid) // #error@31: passing 'struct Simple' to parameter of incompatible type 'struct Simple *'
  res |= __builtin_arm_strexd(&var, (struct Simple **)addr).a; // #error@37: address argument to __builtin_arm_strexd must be a pointer to 8 byte type ('struct Simple **' invalid) // #error@61: member reference base type 'int' is not a structure or union

  res |= __builtin_arm_strexd(1, (__int128 *)addr); // #error@35: __int128 is not supported on this target // #error@34: address argument to __builtin_arm_strexd must be a pointer to 8 byte type ('__int128 *' invalid)

  __builtin_arm_strexd(1); // #error@25: expected 2 argument(s) got 1
  __builtin_arm_strexd(1, 2, 3); // #error@27: address argument to __builtin_arm_strexd must be a pointer to integer, floating-point, or pointer ('int' invalid) // #error@30: expected 2 argument(s) got 3
  return res;
}

int test_ldaex(char *addr) {
  int sum = 0;
  sum += __builtin_arm_ldaex(addr);
  sum += __builtin_arm_ldaex((short *)addr);
  sum += __builtin_arm_ldaex((int *)addr);
  sum += __builtin_arm_ldaex((long long *)addr);
  sum += __builtin_arm_ldaex((float *)addr);
  sum += __builtin_arm_ldaex((double *)addr);
  sum += *__builtin_arm_ldaex((int **)addr);
  sum += __builtin_arm_ldaex((struct Simple **)addr)->a;
  sum += __builtin_arm_ldaex((volatile char *)addr);
  sum += __builtin_arm_ldaex((const volatile char *)addr);

  // In principle this might be valid, but stick to ints and floats for scalar
  // types at the moment.
  sum += __builtin_arm_ldaex((struct Simple *)addr).a; // #error@30: address argument to __builtin_arm_ldaex must be a pointer to integer, floating-point, or pointer ('struct Simple *' invalid)

  sum += __builtin_arm_ldaex((__int128 *)addr); // #error@31: __int128 is not supported on this target // #error@30: address argument to __builtin_arm_ldaex must be a pointer to 1, 2, 4 or 8 byte type ('__int128 *' invalid)

  __builtin_arm_ldaex(); // #error@23: expected 1 argument(s) got 0
  __builtin_arm_ldaex(1, 2); // #error@23: address argument to __builtin_arm_ldaex must be a pointer to integer, floating-point, or pointer ('int' invalid) // #error@26: expected 1 argument(s) got 2
  return sum;
}

int test_stlex(char *addr) {
  int res = 0;
  struct Simple var = {0};
  res |= __builtin_arm_stlex(4, addr);
  res |= __builtin_arm_stlex(42, (short *)addr);
  res |= __builtin_arm_stlex(42, (int *)addr);
  res |= __builtin_arm_stlex(42, (long long *)addr);
  res |= __builtin_arm_stlex(2.71828f, (float *)addr);
  res |= __builtin_arm_stlex(3.14159, (double *)addr);
  res |= __builtin_arm_stlex(&var, (struct Simple **)addr);

  res |= __builtin_arm_stlex(42, (volatile char *)addr);
  res |= __builtin_arm_stlex(42, (char *const)addr); // #warning@34: cast to type 'char *const' will not preserve qualifiers [-Wcast-qualifiers]
  res |= __builtin_arm_stlex(42, (const char *)addr); // #warning@34: passing 'const char *' to parameter of incompatible type 'volatile char *' discards qualifiers [-Wincompatible-pointer-types-discards-qualifiers]


  res |= __builtin_arm_stlex(var, (struct Simple *)addr); // #error@35: address argument to __builtin_arm_stlex must be a pointer to integer, floating-point, or pointer ('struct Simple *' invalid)
  res |= __builtin_arm_stlex(var, (struct Simple **)addr); // #error@30: passing 'struct Simple' to parameter of incompatible type 'struct Simple *'
  res |= __builtin_arm_stlex(&var, (struct Simple **)addr).a; // #error@60: member reference base type 'int' is not a structure or union

  res |= __builtin_arm_stlex(1, (__int128 *)addr); // #error@34: __int128 is not supported on this target // #error@33: address argument to __builtin_arm_stlex must be a pointer to 1, 2, 4 or 8 byte type ('__int128 *' invalid)

  __builtin_arm_stlex(1); // #error@24: expected 2 argument(s) got 1
  __builtin_arm_stlex(1, 2, 3); // #error@26: address argument to __builtin_arm_stlex must be a pointer to integer, floating-point, or pointer ('int' invalid) // #error@29: expected 2 argument(s) got 3
  return res;
}

void test_clrex(void) {
  __builtin_arm_clrex();
  __builtin_arm_clrex(1); // #error@23: expected 0 argument(s) got 1
}

