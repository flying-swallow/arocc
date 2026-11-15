// #opt: -std=c17 -Wpedantic
_BitInt(17) a; // #warning@1: '_BitInt' in C17 and earlier is a Clang extension [-Wbit-int-extension]

#pragma GCC diagnostic ignored "-Wpedantic"

unsigned _BitInt(70) b;
signed _BitInt(99) c;

_Static_assert(sizeof(_BitInt(65)) == sizeof(_BitInt(66)), "failed");
_Static_assert(sizeof(_BitInt(8)) != sizeof(_BitInt(66)), "failed");

_BitInt(65536) f; // #error@1: signed _BitInt of bit sizes greater than 65535 not supported
signed _BitInt(1) e; // #error@8: signed _BitInt must have a bit size of at least 2
unsigned _BitInt(0) d; // #error@10: unsigned _BitInt must have a bit size of at least 1

_BitInt(5) g = 2wb; // #warning@16: '_BitInt' suffix for literals is a C23 extension [-Wc23-extensions]
unsigned _BitInt(5) h = 3Uwb; // #warning@25: '_BitInt' suffix for literals is a C23 extension [-Wc23-extensions]
#pragma GCC diagnostic ignored "-Wc23-extensions"
int y = 0wb;
int z = 0uwb;
int x = 1'2; // #warning@10: missing terminating ' character [-Winvalid-pp-token] // #error@10: expected ';', found 'a character literal'
_Static_assert(((int)-18446744073709551616WB) == 0);

_Static_assert(sizeof(_BitInt(65535)) == 8192, "");

_Complex _BitInt(34) complex_bitint; // #error@1: '_Complex _BitInt' is invalid

