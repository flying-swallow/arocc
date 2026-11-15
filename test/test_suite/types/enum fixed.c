// #skip: diagnostics differ (aro_c3 gap)
#pragma GCC diagnostic warning "-Wfixed-enum-extension"
enum E: int; // #warning@7: enumeration types with a fixed underlying type are a Clang extension [-Wfixed-enum-extension] // #note@6: previous definition is here
#pragma GCC diagnostic ignored "-Wfixed-enum-extension"
enum E; // #error@6: enumeration previously declared with fixed underlying type

enum E1; // #note@6: previous definition is here
enum E1: int; // #error@6: enumeration previously declared with nonfixed underlying type

enum E2: char; // #note@6: previous definition is here
enum E2: int; // #error@6: enumeration redeclared with different underlying type 'int' (was 'char')

enum E3: unsigned char {
    A = 255,
    B, // #error@5: enumerator value is not representable in the underlying type 'unsigned char'
};

enum E4: char {
    A = 256, // #error@5: enumerator value is not representable in the underlying type 'char'
};

enum E5: unsigned char {
    C,
    D,
};

_Static_assert(C == 0, "");
_Static_assert(D == 1, "");

enum E6: char {
    a = 0u,
};

enum E e;
enum E: int;
void fn(enum E);

enum Signed: int {
    S,
};

enum Signed2: int {
    S2,
};

enum Unsigned: unsigned {
    U,
};

enum Plain {
    P,
};

_Static_assert(!__builtin_types_compatible_p(enum Signed, enum Signed2), "");
_Static_assert(!__builtin_types_compatible_p(enum Signed, enum Unsigned), "");
_Static_assert(__builtin_types_compatible_p(enum Signed, int), "");
_Static_assert(__builtin_types_compatible_p(enum Unsigned, unsigned), "");

_Static_assert(!__builtin_types_compatible_p(enum Signed, enum Plain), "");
_Static_assert(!__builtin_types_compatible_p(enum Unsigned, enum Plain), "");

void pointers(void) {
    int x;
    unsigned y;

    enum Signed *e1 = &x;
    enum Signed *e2 = &y; // #warning@23: incompatible pointer types initializing 'enum Signed: int *' from incompatible type 'unsigned int *' converts between pointers to integer types with different sign [-Wpointer-sign]
    enum Unsigned *e3 = &x; // #warning@25: incompatible pointer types initializing 'enum Unsigned: unsigned int *' from incompatible type 'int *' [-Wincompatible-pointer-types]
    enum Unsigned *e4 = &y;

    enum Incomplete *i1 = &x; // #warning@27: incompatible pointer types initializing 'enum Incomplete *' from incompatible type 'int *' [-Wincompatible-pointer-types]
    enum Incomplete *i2 = &y; // #warning@27: incompatible pointer types initializing 'enum Incomplete *' from incompatible type 'unsigned int *' [-Wincompatible-pointer-types]
}

typedef struct BackingStruct {
   int x;
} BackingStruct;

typedef enum BackingEnum : int {
   B0,
} BackingEnum;

enum Bad1: BackingStruct { // #error@12: non-integral type 'BackingStruct' (aka 'struct BackingStruct') is an invalid underlying type
    B1,
};

enum Bad2: BackingEnum { // #error@12: non-integral type 'BackingEnum' (aka 'enum BackingEnum: int') is an invalid underlying type
    B2,
};

enum Bad3: unsigned * { // #error@23: expected identifier or '('
    B3,
};

void more_pointers(void) {
    unsigned y;

    enum SignedEnum: int *p = &y; // #warning@31: incompatible pointer types initializing 'enum SignedEnum: int *' from incompatible type 'unsigned int *' converts between pointers to integer types with different sign [-Wpointer-sign]
    enum UnsignedEnum: unsigned *p2 = &y;
    enum CharEnum: char signed *p3 = &y; // #warning@38: incompatible pointer types initializing 'enum CharEnum: signed char *' from incompatible type 'unsigned int *' [-Wincompatible-pointer-types]
}

enum EA: _Atomic(int) const { // #error@10: '_Atomic' qualifier ignored; operations involving the enumeration type will be non-atomic [-Wunderlying-atomic-qualifier-ignored] // #warning@10: qualifiers in enumeration underlying type ignored [-Wunderlying-cv-qualifier-ignored]
    EA
};

