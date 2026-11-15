_Bool b(void) {
    return; // #error@5: non-void function 'b' should return a value [-Wreturn-type]
    return 1; // #warning@5: unreachable code [-Wunreachable-code]
    return 1.;
    return (int *)1l;
    return (void)1; // #error@12: returning 'void' from a function with incompatible result type '_Bool'
}

int i(void) {
    return 1;
    return 1.f; // #warning@5: unreachable code [-Wunreachable-code]
    return (int*)1L; // #warning@12: implicit pointer to integer conversion from 'int *' to 'int' [-Wint-conversion]
}

float f(void) {
    return 1;
    return 1.f; // #warning@5: unreachable code [-Wunreachable-code]
    return (int*)1L; // #error@12: returning 'int *' from a function with incompatible result type 'float'
}

int *ip(void) {
    return 1; // #warning@12: implicit integer to pointer conversion from 'int' to 'int *' [-Wint-conversion]
    return (int*)1L; // #warning@5: unreachable code [-Wunreachable-code]
    return (float*)2L; // #error@12: returning 'float *' from a function with incompatible result type 'int *'
    _Atomic int a[3];
    return &a; // #error@12: returning '_Atomic(int) (*)[3]' from a function with incompatible result type 'int *'
}

int foo(void) {
} // #warning@1: non-void function 'foo' does not return a value [-Wreturn-type]
int bar(void) {
    return; // #error@5: non-void function 'bar' should return a value [-Wreturn-type]
}
void baz(void) {
    return 1; // #error@12: void function 'baz' should not return a value [-Wreturn-type]
}

int *return_func(void)(void) { // #error@17: function cannot return a function
    return 0;
}

char return_char(void) {
    return 1;
}
short return_short(void) {
    return 2;
}

int func1(int arg) {
    switch (arg) {
    case 1:
        return 1;
    case 2:
        return 2;
    default:
        return 3;
    } // no warning expected
}

int func2(int arg) {
    switch (arg) {
    case 1:
        func1(1);
    case 2:
        func1(2);
    default:
        func1(3);
    }
    return 1; // this is reachable
}

int func3(int arg) {
    switch (arg) return arg;
    return 1; // this is reachable
}

int then_noreturn(int arg) {
    if (arg) {
        return 2;
    } else {
        // do nothing
    }
    return 1; // reachable; no warning
}

int else_noreturn(int arg) {
    if (arg) {
        // do nothing
    } else {
        return 2;
    }
    return 1; // reachable; no warning
}

void *void_star_return(void) {
    return 4.2; // #error@12: returning 'double' from a function with incompatible result type 'void *'
}

int *return_signed(unsigned int *x) {
    return x; // #warning@12: returning 'unsigned int *' from a function with incompatible result type 'int *' converts between pointers to integer types with different sign [-Wpointer-sign]
}

void call_return_signed(void) {
    unsigned int x = 0;
    int *y = return_signed(&x);
}

