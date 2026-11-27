// #opt: -target x86_64-linux
enum E {
    A = 2147483647,
    B, // #warning@5: overflow in enumeration value
    C = 4294967295UL,
    D,
    F = 9223372036854775807LL,
    G, // #warning@5: incremented enumerator value 9223372036854775808 is not representable in the largest integer type
    H = 18446744073709551615ULL,
    I // #warning@5: incremented enumerator value 18446744073709551616 is not representable in the largest integer type
};
_Static_assert(G == 9223372036854775808ULL, "G keeps the full value past signed long long");
_Static_assert(I == 0, "I wraps to zero past unsigned long long");
