// #skip: diagnostics differ (aro_cc gap)
void foo(void) {
    int x = 5;
    void *y = &&baz;
    bar:
    y = &&bar;
    baz:
    x = 0;
    goto *y;
    goto *&&baz;
}

void no_address_of_label(void *arg) {
    label:
    goto *arg; // #error@5: computed goto in function with no address-of-label expressions
}

void implicit_conversion(void) {
    int x = 0;
    void *y = &&label;
    label:
    goto *0;
    goto *x; // #warning@11: implicit integer to pointer conversion from 'int' to 'const void *' [-Wint-conversion]
}

void invalid_param(void) {
    void *p = &&label;
    float f = 0.0f;
    label:
    goto *f; // #error@11: passing 'float' to parameter of incompatible type 'const void *'
}

