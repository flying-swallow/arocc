// #kind: run
// #exit: 0
// c-testsuite 00216/00219 and Lua's HUGE_VAL:
// - `_Generic` associations for `int` and `const int` are distinct types, and a
//   selected function designator can be called (the selection is an lvalue).
// - A compound literal is a constant initializer value at file scope (GNU).
// - `__builtin_huge_val*` folds to +inf.
#include <math.h>
static int a_f(void) { return 20; }
static int b_f(void) { return 10; }
struct S { int x, y; };
static struct S g_single = ((struct S){ 1, 2 });
static struct S garr[] = { (struct S){ 3, 4 }, { 5, 6 } };
int main(void)
{
  const int c = 0;
  int v = 0;
  if (_Generic(c, int: a_f, const int: b_f)() != 20) return 1; // #warning@29: generic association with qualifiers cannot be matched with
  if (_Generic(v, int: a_f, const int: b_f)() != 20) return 2; // #warning@29: generic association with qualifiers cannot be matched with
  _Generic(v, int: v) = 7;
  if (v != 7) return 3;
  if (g_single.x != 1 || g_single.y != 2 || garr[0].y != 4 || garr[1].x != 5) return 4;
  double h = HUGE_VAL; float f = HUGE_VALF; long double l = HUGE_VALL;
  if (!(h > 1e308 && f > 3e38f && l > 1e308L)) return 5;
  _Static_assert(__builtin_huge_val() == __builtin_inf(), "folds");
  return 0;
}
