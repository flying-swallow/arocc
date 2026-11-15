// #skip: diagnostics differ (aro_c3 gap)
// #opt: -std=c23
struct A {
    int x;
};
struct B {
    struct A a;
    int y;
};

int *p = (int []){2, 4};

void foo(struct A *a) {
    (void)a;
}
void bar(void) {
    int a = (struct B){
        .y = 1,
        .a = {.x = 2},
    }.a.x;
    int b = (int []){1,2,3,4,5}[4];
    int c = (int []){1,2,3,4,5}[10]; // #warning@32: array index 10 is past the end of the array [-Warray-bounds]
    foo(&(struct A){.x = 42});

    char *str1 = "string 1";
    char *str2 = (char []){"string 2"};
    const char *str3 = (const char []){"string 3"};
}

void baz() {
    &(register int){0}; // #error@5: address of register variable requested
    &(static thread_local int){0}; // #warning@5: expression result unused [-Wunused-value]
    &(extern int){0}; // #error@7: compound literal cannot have extern storage class
}

unsigned long qux(unsigned long x) {
    return ((union{unsigned long _x;}){x})._x;
}

_Static_assert(sizeof ((char [3]){"foo"}) == 3, "");

auto invalid_global = (register int){1}; // #error@37: file scope compound literal specifies 'register'

