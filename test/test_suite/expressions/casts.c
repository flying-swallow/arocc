// #skip: diagnostics differ (aro_c3 gap)
void foo(void) {
    struct Foo {
        int a;
    };
    (struct Foo)1; // #error@5: cannot cast to non arithmetic or pointer type 'struct Foo'
    (float)(int*)1l; // #error@5: pointer cannot be cast to type 'float'
    (int*)1.f; // #error@5: operand of type 'float' cannot be cast to a pointer type
    (const int)1; // #warning@5: cast to type 'const int' will not preserve qualifiers [-Wcast-qualifiers] // #warning@5: expression result unused [-Wunused-value]
    const int p_i[] = (typeof(p_i))0; // #error@23: cannot cast to non arithmetic or pointer type 'typeof(const int [])' (aka 'const int []')
    int a = (char)"foo"; // #warning@13: cast to smaller integer type 'char' from 'char *' [-Wpointer-to-int-cast]
    int b = (float)"foo"; // #error@13: pointer cannot be cast to type 'float'
    unsigned long long d = (unsigned long long)"foo";

    int x = 1;
    x ? (void)1 : 1;
    (enum E)1; // #error@5: cast to incomplete type 'enum E'
    int *ptr;
    ptr = (int *)(void)5; // #error@18: operand of type 'void' where arithmetic or pointer type is required
    (enum DoesNotExist)2.0; // #error@5: cast to incomplete type 'enum DoesNotExist'
}

void atomic_qualifiers(int value) {
    (void)(const _Atomic(int))value; // #warning@11: cast to type 'const _Atomic(int)' will not preserve qualifiers [-Wcast-qualifiers]
    (void)(volatile _Atomic(int))value; // #warning@11: cast to type 'volatile _Atomic(int)' will not preserve qualifiers [-Wcast-qualifiers]
    (void)(const volatile _Atomic(int))value; // #warning@11: cast to type 'const volatile _Atomic(int)' will not preserve qualifiers [-Wcast-qualifiers]
}

