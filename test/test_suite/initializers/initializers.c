// #skip: diagnostics differ (aro_cc gap)
// #todo: TODO missing uninitialized in own initializer warning
void foo(void) {
    int a, b[a] = {}; // #error@17: variable-sized object may not be initialized
    (int(int)){}; // #error@15: illegal initializer type
    int *c = 1.f; // #error@14: initializing 'int *' from incompatible type 'float'
    int d = {};
    int e = {1, 2}; // #warning@17: excess elements in scalar initializer [-Wexcess-initializers]
    const char f[] = {"foo", "bar"}; // #warning@30: excess elements in string initializer [-Wexcess-initializers]
    const char g[2] = "foo"; // #warning@23: initializer-string for char array is too long [-Wexcess-initializers]
    int h[2] = (int []){1,2,3}; // #error@16: cannot initialize type 'int [2]' with array of type 'int [3]'
    int i[] = "foo"; // #error@15: cannot initialize array of type 'int []' with array of type 'char [4]'
    int j = { [0] = 1 }; // #error@15: array designator used for non-array type 'int'
    int k[2] = { [-1] = 1 }; // #error@19: array designator value -1 is negative
    int l[2] = { [2] = 1 }; // #error@19: array designator index 2 exceeds array bounds
    #define N 1000000000
    int m[] = { [N] = 1, [N] = 2 }; // #warning@32: initializer overrides previous initialization [-Winitializer-overrides] // #note@23: previous initialization
    int n = { .foo = 1 }; // #error@15: field designator used for non-record type 'int'
    struct Foo {
        int a, b, c;
    } o = { .b = 1, 2 }, p = { .d = 0 }; // #error@32: record type has no field named 'd'
    struct Foo q = { .c = 1, .b = 2, 3, 4, 5}, r = { .c = 1, 2}; // #warning@38: initializer overrides previous initialization [-Winitializer-overrides] // #note@27: previous initialization // #warning@41: excess elements in struct initializer [-Wexcess-initializers] // #warning@62: excess elements in struct initializer [-Wexcess-initializers]
    int s[2] = {1, 2, 3}, t[2] = {[1] = 1, 2, 3}; // #warning@23: excess elements in array initializer [-Wexcess-initializers] // #warning@44: excess elements in array initializer [-Wexcess-initializers]

    int arr[2][2] = {1, [1] = 3, 4, 5, 6}; // #warning@37: excess elements in array initializer [-Wexcess-initializers]
    struct {
        int a, b;
        union {
            int a;
            float b;
        } c;
    } arr2[2] = {1, [0].c.b = 2, 3, 4, 5, 6, 7, 8}; // #warning@43: excess elements in array initializer [-Wexcess-initializers]
    struct {} empty[2] = {1}; // #error@27: initializer for aggregate with no elements requires explicit braces
    int j[] = c; // #error@15: array initializer must be an initializer list or wide string literal

    struct S s = {}; // #error@14: variable has incomplete type 'struct S'
    enum E e1 = 1, e2 = 2 + e1; // #error@12: variable has incomplete type 'enum E' // #error@20: variable has incomplete type 'enum E'
    union U u = {.x = 1}; // #error@13: variable has incomplete type 'union U'
    void v[1] = {1}; // #error@11: array has incomplete element type 'void'
    (void){}; // #error@11: variable has incomplete type 'void'
}
void bar(void) {
    int x = 1;
    int arr[] = {[x] = 2}; // #error@19: expression is not an integer constant expression
}

void baz(void) {
    char arr1[] = "arr";
    signed char arr2[] = ("arr");
    unsigned char arr3[] = ((("arr")));
    char arr4[] = arr1; // #error@19: array initializer must be an initializer list or wide string literal
    signed char h[2] = (char []){1,2}; // #error@24: cannot initialize array of type 'signed char [2]' with array of type 'char [2]'
}

void qux(void) {
    struct S {
        int a;
        char b[2];
        float c;
    } s = {1, {'a', 'b'}, 2.5};

    union U {
        int a;
        char b[2];
        float c;
    } u = {{'a', 'b'}}; // #warning@18: excess elements in scalar initializer [-Wexcess-initializers]

    int a = {{1}}; // #warning@14: too many braces around scalar initializer [-Wmany-braces-around-scalar-init]
    int arr[][3] = {{0, 1, 2}, {3, 4, 5}, {6, 7, 8}};
}

#pragma GCC diagnostic warning "-Wuninitialized"
struct S {
    int val;
};
struct node { struct node *prev, *next; int value; };

void self_referential(void) {
    int x = x;
    int y = y + 1; // should warn -Wuninitialized -- warning: variable 'y' is uninitialized when used within its own initialization
    struct S s1 = { .val = s1.val }; // should warn -Wuninitialized -- warning: variable 's1' is uninitialized when used within its own initialization
    struct S s2 = (struct S){ s2.val }; // should warn -Wuninitialized -- warning: variable 's2' is uninitialized when used within its own initialization
    struct S s3 = (struct S){ .val = s3.val }; // should warn -Wuninitialized -- warning: variable 's3' is uninitialized when used within its own initialization
    struct node ll[] = {{0, ll + 1, 42}, {ll, ll + 2, 5}, {ll, 0, 99}};
}

struct Foo {
    struct {
        int z;
        union {
            float b;
            int x;
        };
        double z1;
    };
    float c;
} a = { .x  = 1 };

static const unsigned char halfrate[2][3][1] = {
    { { 0, }, { 0 }, { 0, } },
    { { 0, }, { 0 }, { 0, } },
};

struct{
    int a, b;
} b[2][2] = { [1] = {1,2,3,4}, 1}; // #warning@32: excess elements in array initializer [-Wexcess-initializers]

struct {
    int :0;
    struct {
        int b;
    };
} c[2] = { [0].b = 1 };

union {

} empty = {{'a', 'b'}}; // #warning@12: excess elements in union initializer [-Wexcess-initializers]

int invalid_init[] = (int){1}; // #error@22: array initializer must be an initializer list or wide string literal
int array_2d[3][2] = { 1, 2, [2] = 3, [1][1] = 1, 4}; // #warning@51: initializer overrides previous initialization [-Winitializer-overrides] // #note@36: previous initialization

void quux(void) {
    struct Foo {
        int a;
    } a, aa[2] = { a, a };
    struct Bar {
        struct Foo a;
    } b = {a};

    void *vp1 = 1.0; // #error@17: initializing 'void *' from incompatible type 'double'
    void *vp2 = a; // #error@17: initializing 'void *' from incompatible type 'struct Foo'
    int x;
    long *y = &x; // #warning@15: incompatible pointer types initializing 'long *' from incompatible type 'int *' [-Wincompatible-pointer-types]
    unsigned int *z = &x; // #warning@23: incompatible pointer types initializing 'unsigned int *' from incompatible type 'int *' converts between pointers to integer types with different sign [-Wpointer-sign]
}
struct S2 {
    char bytes[32];
};
union U {
    char bytes[32];
};
union U2 {
    int a;
    char bytes[32];
};

void array_members(void) {
    struct S2 s = (struct S2){"ABC"};
    struct S2 s2 = {.bytes = "abc"};
    struct S2 s3 = (struct S){'h',[1]='i'}; // #error@35: array designator used for non-array type 'struct S'
    union U u = (union U){"ABC"};
    union U2 u2 = (union U2){"ABC"}; // #warning@30: implicit pointer to integer conversion from 'char [4]' to 'int' [-Wint-conversion]
    char b[32] = (char[32]){"ABC"};
}

struct {
    int sec, min, hour, day;
} s1 = {.day = 3, .sec = 0, 1, 2};

void string_initializers(void) {
    char str1[] = {"fo", "ba"}; // #warning@26: excess elements in string initializer [-Wexcess-initializers]
    char str2[] = {"fo", 1}; // #warning@26: excess elements in string initializer [-Wexcess-initializers]
    char str3[] = {1, "fo"}; // #warning@23: implicit pointer to integer conversion from 'char [3]' to 'char' [-Wint-conversion]
    char str4[1] = {1, 2}; // #warning@24: excess elements in array initializer [-Wexcess-initializers]
    char str5[4] = { (char [4]){"foo"} }; // #warning@22: implicit pointer to integer conversion from 'char [4]' to 'char' [-Wint-conversion]
    char str6[] = {"foo", {1}, {3}}; // #warning@27: excess elements in string initializer [-Wexcess-initializers]
    int arr2[2] = { (int [2]){ 1, 2 } }; // #warning@21: implicit pointer to integer conversion from 'int [2]' to 'int' [-Wint-conversion]
}
void union_excess(void) {
    union U2 u1 = { 1, 2 }; // #warning@24: excess elements in union initializer [-Wexcess-initializers]
    union U2 u2 = { .a = 1, .a = 2 }; // #warning@34: initializer overrides previous initialization [-Winitializer-overrides] // #note@26: previous initialization
}
void struct_excess(void) {
    struct A {
        int a;
        int b;
    } a, b = { 1, a }; // #error@19: initializing 'int' from incompatible type 'struct A'
}
void vector_excess(void) {
    typedef int vec __attribute__((vector_size(4 * 4)));
    vec v1 = { 1, 2, 3, 4, 5 }; // #warning@28: excess elements in vector initializer [-Wexcess-initializers]
    vec v2 = v1;
    vec v3 = { v2 };
    vec v4 = { 1, v3 }; // #error@19: initializing 'int' from incompatible type 'vec' (vector of 4 'int' values)
}

#pragma GCC diagnostic warning "-Wc23-extensions"
int empty_initializer[2] = {}; // #warning@28: use of an empty initializer is a C23 extension [-Wc23-extensions]

void braced_init_overrides(void) {
    struct {
        int a;
    } aa, a[2] = {aa, aa, [0] = {2}, {3}}; // #warning@33: initializer overrides previous initialization [-Winitializer-overrides] // #note@19: previous initialization // #warning@38: initializer overrides previous initialization [-Winitializer-overrides] // #note@23: previous initialization
}

union { int x; char c[4]; }
  ua = {1},
  ub = {.c={'a','b','b','a'}};

