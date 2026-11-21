// #opt: -std=c23 -target x86_64-linux
#define IS(x, T) _Generic(&(x), T *: 1, default: 0)
const _BitInt(8) const_signed; volatile unsigned _BitInt(9) volatile_unsigned;
const volatile _BitInt(10) cv_signed; unsigned _BitInt(11) const volatile cv_unsigned;
unsigned _BitInt(12) *restrict bit_pointer;

_Static_assert(IS(const_signed, const signed _BitInt(8)), "");
_Static_assert(!IS(const_signed, signed _BitInt(8)), "");
_Static_assert(IS(volatile_unsigned, volatile unsigned _BitInt(9)), "");
_Static_assert(!IS(volatile_unsigned, unsigned _BitInt(9)), "");
_Static_assert(IS(cv_signed, const volatile signed _BitInt(10)), "");
_Static_assert(IS(cv_unsigned, const volatile unsigned _BitInt(11)), "");
_Static_assert(IS(bit_pointer, unsigned _BitInt(12) *restrict), "");
_Static_assert(!IS(bit_pointer, unsigned _BitInt(12) *), "");
_Static_assert(!IS(bit_pointer, const unsigned _BitInt(12) *restrict), "");
