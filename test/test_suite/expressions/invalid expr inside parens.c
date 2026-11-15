void foo(void) {
    int a = (while (1) 1); // #error@14: expected expression
    int b = sizeof(while (1) 1); // #error@20: expected expression
    int c = _Alignof(while (1) 1); // #error@22: expected expression
}

