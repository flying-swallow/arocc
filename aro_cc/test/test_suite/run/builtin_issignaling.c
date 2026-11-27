// #kind: run
// #exit: 0
// __builtin_issignaling on float / double / x87 long double, both constant-folded
// and lowered at runtime (gcc.c-torture/execute/ieee/builtin-issignaling-1.c).
// The float argument must reach the builtin unpromoted: float -> double would
// quiet the NaN. Also covers the _FloatN nan/nans/inf builtins and an
// operand-free `asm volatile ("" ::: "memory")` barrier.
__attribute__((noinline)) int sf(float x) { return __builtin_issignaling(x); }
__attribute__((noinline)) int sd(double x) { return __builtin_issignaling(x); }
__attribute__((noinline)) int sl(long double x) { return __builtin_issignaling(x); }

_Static_assert(__builtin_issignaling(__builtin_nansf("")), "nansf folds signaling");
_Static_assert(!__builtin_issignaling(__builtin_nan("")), "nan folds quiet");
_Static_assert(__builtin_issignaling(__builtin_nansl("0x1")), "nansl folds signaling");
_Static_assert(!__builtin_issignaling(0.0L), "zero is not signaling");

int main(void)
{
  asm volatile ("" : : : "memory");
  if (!sf(__builtin_nansf("")) || sf(__builtin_nanf("")) || sf(__builtin_inff()) || sf(-0.0f) || sf(1.0f))
    return 1;
  if (!sd(__builtin_nans("")) || sd(__builtin_nan("")) || sd(-__builtin_inf()) || sd(42.0))
    return 2;
  if (!sl(__builtin_nansl("")) || sl(__builtin_nanl("")) || sl(__builtin_infl()) || sl(0.0L))
    return 3;
  if (!sf(-__builtin_nansf("")) || !sd(-__builtin_nans("")) || !sl(-__builtin_nansl("")))
    return 4;
  if (!sf(__builtin_nansf32("")) || sf(__builtin_nanf32("")) || sf(__builtin_inff32()))
    return 5;
  if (!sd(__builtin_nansf64("")) || !sd(__builtin_nansf32x("")) || sd(__builtin_inff64()))
    return 6;
  volatile float vf = __builtin_nansf("");
  volatile double vd = __builtin_nans("");
  if (!__builtin_issignaling(vf) || !__builtin_issignaling(vd))
    return 7;
  return 0;
}
