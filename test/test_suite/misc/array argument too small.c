// #skip: diagnostics differ (aro_c3 gap)
void foo(int x[static 10]) { // #note@14: callee declares array parameter as static here

}

void bar(void) {
    int x[5];
    foo(x); // #warning@9: array argument is too small; contains 5 elements, callee requires at least 10 [-Warray-bounds]
}

