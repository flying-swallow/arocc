void foo(void) {
    #pragma GCC diagnostic error "-Wint-conversion"
    int *x = 5; // #error@14: implicit integer to pointer conversion from 'int' to 'int *' [-Werror,-Wint-conversion]
    #pragma GCC diagnostic ignored "-Wint-conversion"
}

