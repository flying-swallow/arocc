// #opt: -target x86_64-linux-gnu
enum E1 {
    A = 2147483647,
    B, // #warning@5: overflow in enumeration value
    C = 4294967295UL,
    D,
    F = 9223372036854775807,
    G, // #warning@5: incremented enumerator value 9223372036854775808 is not representable in the largest integer type [-Wenum-too-large]
    H = 18446744073709551615ULL,
    I // #warning@5: incremented enumerator value 18446744073709551616 is not representable in the largest integer type [-Wenum-too-large]
};

_Static_assert(A == 2147483647, "A");
_Static_assert(B == 2147483648, "B");
_Static_assert(C == 4294967295UL, "C");
_Static_assert(D == 4294967296UL, "D");
_Static_assert(F == 9223372036854775807LL, "F");
_Static_assert(G == 9223372036854775808ULL, "G");
_Static_assert(H == 18446744073709551615ULL, "H");

_Static_assert(H != C, "enumerator value was not truncated");

