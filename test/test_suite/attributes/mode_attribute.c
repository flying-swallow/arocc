// #kind: syntax
// #opt: --target=x86_64-linux-gnu
// GCC machine-mode attribute: picks the integer/float type of that width and
// keeps the original signedness.
typedef int qi __attribute__((mode(QI)));
typedef unsigned int uhi __attribute__((mode(HI)));
typedef int __attribute__((mode(DI))) di;
typedef unsigned uti __attribute__((mode(__TI__)));
typedef float df __attribute__((mode(DF)));
typedef float xf __attribute__((mode(XF)));
typedef int wd __attribute__((mode(word)));
typedef int *pp __attribute__((mode(pointer)));
_Static_assert(sizeof(qi) == 1 && (qi)-1 < 0, "QI");
_Static_assert(sizeof(uhi) == 2 && (uhi)-1 > 0, "HI");
_Static_assert(sizeof(di) == 8, "DI");
_Static_assert(sizeof(uti) == 16 && (uti)-1 > 0, "TI");
_Static_assert(sizeof(df) == 8 && _Generic((df)0, double: 1, default: 0), "DF");
_Static_assert(_Generic((xf)0, long double: 1, default: 0), "XF");
_Static_assert(sizeof(wd) == 8, "word");
_Static_assert(sizeof(pp) == 8, "pointer");
struct S { int narrow __attribute__((mode(QI))); };
_Static_assert(sizeof(struct S) == 1, "mode on a member");
typedef int bad __attribute__((mode(V4SI))); // #warning: TODO: implement 'mode' attribute
