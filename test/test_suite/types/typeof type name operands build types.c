// #opt: -std=c23 -target x86_64-linux
#define IS(x, T) _Generic(&(x), T *: 1, default: 0)
typeof(int) plain_int; typeof(const int) const_int; const typeof(int) const_outer;
typeof(unsigned _BitInt(8)) typed_width; typeof(long double) long_double_value;
typeof(int *) pointer_value; typeof(unsigned _BitInt(12)) *bit_pointer;

_Static_assert(IS(plain_int, int), "");
_Static_assert(IS(const_int, const int), "");
_Static_assert(IS(const_outer, const int), "");
_Static_assert(IS(typed_width, unsigned _BitInt(8)), "");
_Static_assert(IS(long_double_value, long double), "");
_Static_assert(IS(pointer_value, int *), "");
_Static_assert(IS(bit_pointer, unsigned _BitInt(12) *), "");
