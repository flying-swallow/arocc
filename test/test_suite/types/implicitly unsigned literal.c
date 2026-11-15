// #opt: --emulate=clang
_Static_assert(-9223372036854775808LL > 0, "lhs should be unsigned"); // #warning@17: integer literal is too large to be represented in a signed integer type, interpreting as unsigned [-Wimplicitly-unsigned-literal]
long long x = 9223372036854775808LL; // #warning@15: integer literal is too large to be represented in a signed integer type, interpreting as unsigned [-Wimplicitly-unsigned-literal]
_Static_assert(0xFFFFFFFFFFFFFFFF == 0xFFFFFFFFFFFFFFFE + 1, "");

