void foo(float f) {
    int bar[2.0] = {0}; // #error@13: size of array has non-integer type 'double'
    int baz[f]; // #error@13: size of array has non-integer type 'float'
}

