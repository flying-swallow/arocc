void foo(int x) {
    int arr[x];
    _Static_assert(sizeof(arr) > 0, "sizeof VLA"); // #error@20: static assertion expression is not an integral constant expression
    int (*pointer)[x] = &arr;
    _Static_assert(sizeof(pointer) == sizeof(int *), "pointer size");
    _Static_assert(sizeof(*pointer) > 0, "sizeof variably-modified type"); // #error@20: static assertion expression is not an integral constant expression
}

