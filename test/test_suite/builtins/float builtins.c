_Static_assert(__builtin_isinf_sign(__builtin_inf()) == 1, "");
_Static_assert(__builtin_isinf_sign(2.0) == 0, "");
_Static_assert(__builtin_isinf_sign(-5.0 / 0.0) == -1, "");
double d = 10.0;
_Static_assert(__builtin_isinf_sign(d) == 0, ""); // #error@16: static assertion expression is not an integral constant expression
_Static_assert(!__builtin_isinf(d), ""); // #error@16: static assertion expression is not an integral constant expression

_Static_assert(__builtin_inf() == __builtin_inf(), "");
_Static_assert(100.0 < __builtin_inf(), "");
_Static_assert(__builtin_inf() > 0.0, "");

_Static_assert(__builtin_isinf(__builtin_inff()), "");
_Static_assert(__builtin_isinf(__builtin_inf()), "");
_Static_assert(__builtin_isinf(__builtin_infl()), "");
_Static_assert(__builtin_isinf(1.0 / 0.0), "");
_Static_assert(!__builtin_isinf(2.0 + 3.0), "");

