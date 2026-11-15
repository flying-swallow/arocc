_Static_assert(5 % -2 == 1, "failed");
_Static_assert(-10 % -4 == -2, "failed");
_Static_assert(10 % -1 == 0, "failed");
_Static_assert(-10 % -1 == 0, "failed");
_Static_assert(10U % -1 == 10, "failed");
_Static_assert(10U % -1 == 10, "failed");
_Static_assert((-9223372036854775807LL - 1LL) % -1 != 0, "failed"); // #error@16: static assertion expression is not an integral constant expression

#if (-9223372036854775807LL - 1LL) % -1 != 0
#error Should not get here
#endif

