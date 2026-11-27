// #skip: diagnostics differ (aro_c3 gap)
// #opt: --target=x86_64-linux-gnu -Wno-unused
typedef int i2v __attribute__((__vector_size__(4 * 2)));
typedef int i4v __attribute__((__vector_size__(4 * 4)));

void foo(i2v a, i2v b, i4v c) {
    i4v d = __builtin_shufflevector(a, b, 0, 1, 2, 3);
    i2v e = __builtin_shufflevector(a, b, -1, 3);
    i4v f = __builtin_shufflevector(a, b, 1, 1); // #error@13: initializing 'i4v' (vector of 4 'int' values) from incompatible type '__attribute__((__vector_size__(2 * sizeof(int)))) int' (vector of 2 'int' values)
    __builtin_shufflevector(a, c); // #error@5: first two arguments to '__builtin_shufflevector' must have the same type
    __builtin_shufflevector(1, b); // #error@29: first argument to __builtin_shufflevector must be a vector type
    __builtin_shufflevector(a, 1); // #error@32: second argument to __builtin_shufflevector must be a vector type
    __builtin_shufflevector(a, b, -2, 5); // #error@35: index for __builtin_shufflevector must be positive or -1 // #error@39: index for __builtin_shufflevector must be less than the total number of vector elements
}

