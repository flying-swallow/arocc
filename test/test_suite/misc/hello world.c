// #skip: compare_output is not implemented
#if defined(__linux) || defined(__APPLE__)
#include <stdio.h>
#else
extern int printf(const char*, ...);
#endif

static int foo(void);

int main(int argc, char **argv) {
    return foo();
}

static int foo(void) {
    printf("Hello, world!\n");
    return 0;
}

