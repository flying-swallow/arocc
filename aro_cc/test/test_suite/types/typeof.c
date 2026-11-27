// #skip: diagnostics differ (aro_c3 gap)
// #opt: -std=gnu17
// #todo: typeof type in error message missing const
int foo(void) {
    return 42.0;
}

typeof(int) g_i = 42;
typeof(foo()) f_i = 42.0;

struct S {
    typeof(int) x;
    typeof(foo()) y;
};

int bar(typeof(int *restrict) a, int y) {
    return 42;
}

void baz(void) {
    const typeof(int) a;
    const typeof(foo()) b;
    typeof(foo()) i = 4;
    typeof(float) f = 4.5;
    typeof(i)* p_i = &i;
    p_i = &f; // #warning@9: incompatible pointer types assigning to 'typeof(typeof(int)) *' (aka 'int *') from incompatible type 'typeof(float) *' (aka 'float *') [-Wincompatible-pointer-types]
    p_i = (typeof(i)*)&f;
    p_i = (typeof(p_i))&f;
    typeof(const int)x; // #note@22: variable 'x' declared const here
    x = 5; // #error@7: cannot assign to variable 'x' with const-qualified type 'typeof(const int)' (aka 'const int')
    const typeof(*p_i)y; // #note@23: variable 'y' declared const here
    y = 5; // #error@7: cannot assign to variable 'y' with const-qualified type 'const typeof(typeof(typeof(int)))' (aka 'const int')
    typeof(0/0) divzero = 0;
}

typeof((void)1, (int*)2) a = 2.f; // #error@30: initializing 'typeof(int *)' (aka 'int *') from incompatible type 'float'
typeof(); // #error@8: expected expression

void qux(int x) {
    char vla[x];
    char arr[10];
    typeof(arr) arr2;
    typeof(char[10]) arr3;

    typeof(vla) vla2;
    typeof(char[x]) vla3;
    char *p = arr2;
    p = arr3;
    p = vla2;
    p = vla3;

    typeof(_Bool) b = 10;
    b = 5;
    typeof(b) b2 = 5;
    b2 = 10;
    b = (typeof(b2))10;
}

void const_arrays(void) {
    const typeof(int[]) arr1 = {1,2}; // #note@25: variable 'arr1' declared const here
    arr1[0] = 1; // #error@13: cannot assign to variable 'arr1' with const-qualified type 'const int [2]'
    const typeof(int[2]) arr2 = {1,2}; // #note@26: variable 'arr2' declared const here
    arr2[0] = 1; // #error@13: cannot assign to variable 'arr2' with const-qualified type 'const typeof(int [2])' (aka 'const int [2]')

    typeof(const int[]) arr3 = {1,2}; // #note@25: variable 'arr3' declared const here
    arr3[0] = 1; // #error@13: cannot assign to variable 'arr3' with const-qualified type 'const int [2]'
    typeof(const int[2]) arr4 = {1,2}; // #note@26: variable 'arr4' declared const here
    arr4[0] = 1; // #error@13: cannot assign to variable 'arr4' with const-qualified type 'typeof(const int [2])' (aka 'const int [2]')

    const typeof(int) arr5[] = {1,2}; // #note@23: variable 'arr5' declared const here
    arr5[0] = 1; // #error@13: cannot assign to variable 'arr5' with const-qualified type 'const typeof(int) [2]'
    typeof(const int) arr6[] = {1,2}; // #note@23: variable 'arr6' declared const here
    arr6[0] = 1; // #error@13: cannot assign to variable 'arr6' with const-qualified type 'typeof(const int) [2]'

    const int arr7[] = {1,2}; // #note@15: variable 'arr7' declared const here
    arr7[0] = 1; // #error@13: cannot assign to variable 'arr7' with const-qualified type 'const int [2]'

    typeof(const typeof(typeof(int[2]))) arr8 = {1,2}; // #note@42: variable 'arr8' declared const here
    arr8[0] = 1; // #error@13: cannot assign to variable 'arr8' with const-qualified type 'typeof(const typeof(typeof(int [2])))' (aka 'const int [2]')

    const typeof(int[2]) arr9 = {1,2};
    const int *p = arr9;
    const typeof(int[]) arr10 = {1,2};
    p = arr10;
    typeof(const int[]) arr11 = {1,2};
    p = arr11;
    typeof(const int[2]) arr12 = {1,2};
    p = arr12;
    typeof(const int) arr13[2] = {1,2};
    p = arr13;
    typeof(const int) arr14[] = {1,2};
    p = arr14;
}

void pointers(void) {
    const int arr[2] = {1,2};
    typeof(const int) *p1 = arr;
    const typeof(int) *p2 = arr;
    typeof(const int *)p3 = arr;
    typeof(int *)const p4 = arr; // type listed in error message is incorrect // #warning@29: initializing 'const typeof(int *)' (aka 'int *const') from incompatible type 'const int [2]' discards qualifiers [-Wincompatible-pointer-types-discards-qualifiers]
}

float my_func(int x) {
    return 2.0f;
}
typeof(my_func) my_other_func;
void test_my_other_func(void) {
    float f = my_func(42);
    f = my_other_func(42);
}

void sizeof_decayed(int x) {
    char vla[x];
    typeof(vla) vla2;
    -vla2; // #error@5: invalid argument type 'char *' to unary expression
}

union U { int x; };
void empty_typeof_declaration(void) {
    typeof(union U) u = { 1 };
    typeof(u); // #warning@5: declaration does not declare anything [-Wmissing-declaration]
    union U;
}

void initializers(void) {
    typeof(union U) u = {.x = 1};
    typeof(u) u2 = {.x = 1};

    typeof(char[10]) arr1;
    typeof(int) arr2[] = arr1; // #error@26: array initializer must be an initializer list or wide string literal
}

